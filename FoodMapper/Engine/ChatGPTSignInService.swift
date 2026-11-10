import Foundation
import Network
import os

private let signInLogger = Logger(subsystem: "com.foodmapper", category: "chatgpt-sign-in")

// MARK: - Loopback callback

/// Receives the OAuth redirect on `127.0.0.1`.
///
/// The listener accepts connections from this Mac only, reads one request head,
/// and hands back the request target of the first `GET /auth/callback`. It never
/// reads a request body and never serves anything except two fixed pages.
final class LoopbackCallbackListener: @unchecked Sendable {
    private static let maximumHeadBytes = 16 * 1_024
    private let queue = DispatchQueue(label: "com.foodmapper.chatgpt-callback")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var deliveredTarget: String?
    private var failure: Error?
    private var timeoutWork: DispatchWorkItem?

    /// Starts listening and returns the port the system assigned.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ChatGPTSignInError.listenerUnavailable)
                    return
                }
                do {
                    let parameters = NWParameters.tcp
                    parameters.acceptLocalOnly = true
                    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.startContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.listenerStateChanged(state)
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: ChatGPTSignInError.listenerUnavailable)
                }
            }
        }
    }

    /// Waits for the browser redirect. Cancelling the task or reaching `timeout` stops the listener.
    func waitForCallback(timeout: TimeInterval) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if let target = self.deliveredTarget {
                        continuation.resume(returning: target)
                        return
                    }
                    if let failure = self.failure {
                        continuation.resume(throwing: failure)
                        return
                    }
                    self.callbackContinuation = continuation
                    let work = DispatchWorkItem { [weak self] in
                        self?.finish(.failure(ChatGPTSignInError.timedOut))
                    }
                    self.timeoutWork = work
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let continuation = startContinuation else { return }
            startContinuation = nil
            if let port = listener?.port?.rawValue, port != 0 {
                continuation.resume(returning: port)
            } else {
                continuation.resume(throwing: ChatGPTSignInError.listenerUnavailable)
                finish(.failure(ChatGPTSignInError.listenerUnavailable))
            }
        case .failed, .cancelled:
            if let continuation = startContinuation {
                startContinuation = nil
                continuation.resume(throwing: ChatGPTSignInError.listenerUnavailable)
            }
            finish(.failure(ChatGPTSignInError.listenerUnavailable))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(on: connection, accumulated: Data())
    }

    private func receiveHead(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var head = accumulated
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: head[head.startIndex..<end.lowerBound], on: connection)
            } else if error != nil || isComplete || head.count > Self.maximumHeadBytes {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, accumulated: head)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let requestLine = String(decoding: head, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count == 3 && parts[0] == "GET" ? String(parts[1]) : nil
        let isCallback = target.map { $0 == ChatGPTOAuth.callbackPath || $0.hasPrefix(ChatGPTOAuth.callbackPath + "?") } ?? false

        if isCallback, deliveredTarget == nil, failure == nil, let target {
            send(status: "200 OK", body: Self.page(
                title: "FoodMapper received the sign-in response",
                message: "Return to FoodMapper to finish. You can close this window."
            ), on: connection)
            finish(.success(target))
        } else {
            send(status: "404 Not Found", body: Self.page(
                title: "Nothing here",
                message: "This address only receives the FoodMapper sign-in response."
            ), on: connection)
        }
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let payload = Data(body.utf8)
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(payload.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ result: Result<String, Error>) {
        timeoutWork?.cancel()
        timeoutWork = nil
        switch result {
        case let .success(target):
            guard deliveredTarget == nil else { return }
            deliveredTarget = target
        case let .failure(error):
            if failure == nil, deliveredTarget == nil { failure = error }
        }
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            continuation.resume(with: deliveredTarget.map { .success($0) } ?? .failure(failure ?? CancellationError()))
        }
        // Keep serving long enough for the response page to flush, then close.
        let listener = self.listener
        self.listener = nil
        queue.asyncAfter(deadline: .now() + 1) { listener?.cancel() }
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>FoodMapper</title>
        <style>body{font:16px -apple-system,sans-serif;margin:18vh auto;max-width:28rem;padding:0 1.5rem;color:#1d1d1f;background:#fff}
        h1{font-size:1.25rem;font-weight:600}p{color:#6e6e73}
        @media(prefers-color-scheme:dark){body{background:#000;color:#f5f5f7}p{color:#a1a1a6}}</style></head>
        <body><h1>\(title)</h1><p>\(message)</p></body></html>
        """
    }
}

// MARK: - Token and discovery requests

struct ChatGPTModel: Identifiable, Equatable, Sendable {
    let slug: String
    let displayName: String
    var id: String { slug }
}

/// Requests to OpenAI's authorization server and the model list. Every request
/// goes to a fixed HTTPS host; token values travel only in bodies and headers.
enum ChatGPTAuthClient {
    private static let maximumResponseBytes = 256 * 1_024
    private static let allowedKeyHosts: Set<String> = ["auth.openai.com", "api.openai.com"]

    static func exchangeCode(
        _ callback: ChatGPTCallback,
        attempt: ChatGPTAuthorizationAttempt,
        transport: ProviderTransport
    ) async throws -> ChatGPTTokenResponse {
        let (data, response) = try await transport.send(
            formRequest(ChatGPTOAuth.tokenEndpoint, body: attempt.tokenRequestBody(code: callback.code, clientID: callback.clientID)),
            maximumBytes: maximumResponseBytes
        )
        guard (200..<300).contains(response.statusCode) else {
            throw ChatGPTSignInError.tokenRequestFailed(ChatGPTTokenResponse.errorCode(in: data))
        }
        return try ChatGPTTokenResponse(data: data)
    }

    static func refresh(refreshToken: String, clientID: String, transport: ProviderTransport) async throws -> ChatGPTTokenResponse {
        let body = Data(FormEncoding.encode([
            ("grant_type", "refresh_token"),
            ("client_id", clientID),
            ("refresh_token", refreshToken),
            ("resource", ChatGPTOAuth.resource),
        ]).utf8)
        let (data, response) = try await transport.send(
            formRequest(ChatGPTOAuth.tokenEndpoint, body: body), maximumBytes: maximumResponseBytes
        )
        guard (200..<300).contains(response.statusCode) else {
            let code = ChatGPTTokenResponse.errorCode(in: data)
            if let code, ChatGPTTokenResponse.unusableRefreshCodes.contains(code) {
                throw ChatGPTSignInError.refreshRejected(code)
            }
            throw ChatGPTSignInError.tokenRequestFailed(code)
        }
        return try ChatGPTTokenResponse(data: data)
    }

    /// Ends the renewable session. Returns true when OpenAI confirmed the revocation.
    static func revoke(refreshToken: String, clientID: String, transport: ProviderTransport) async -> Bool {
        do {
            let discovery = try await discoveryDocument(transport: transport)
            guard let endpoint = (discovery["revocation_endpoint"] as? String).flatMap(URL.init(string:)),
                  isAllowedAuthURL(endpoint) else { return false }
            let body = Data(FormEncoding.encode([
                ("token", refreshToken),
                ("token_type_hint", "refresh_token"),
                ("client_id", clientID),
            ]).utf8)
            let (_, response) = try await transport.send(formRequest(endpoint, body: body), maximumBytes: maximumResponseBytes)
            return response.statusCode == 200
        } catch {
            return false
        }
    }

    /// The issuer's signing keys, located through its discovery document.
    static func signingKeys(transport: ProviderTransport) async throws -> Data {
        let discovery = try await discoveryDocument(transport: transport)
        guard (discovery["issuer"] as? String) == ChatGPTOAuth.issuer,
              let keysURL = (discovery["jwks_uri"] as? String).flatMap(URL.init(string:)),
              isAllowedAuthURL(keysURL) else {
            throw ChatGPTSignInError.invalidToken("keys")
        }
        let (data, response) = try await transport.send(getRequest(keysURL), maximumBytes: maximumResponseBytes)
        guard response.statusCode == 200 else { throw ChatGPTSignInError.invalidToken("keys") }
        return data
    }

    /// Models the signed-in account can use, in the server's order.
    static func models(accessToken: String, transport: ProviderTransport) async throws -> [ChatGPTModel] {
        var request = getRequest(URL(string: "\(ChatGPTOAuth.resource)/models")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request, maximumBytes: 1_048_576)
        guard response.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw ProviderPipelineError.requestFailed(response.statusCode)
        }
        return models.compactMap { model in
            guard (model["visibility"] as? String) == "list",
                  let slug = model["slug"] as? String, !slug.isEmpty, slug.count <= 160 else { return nil }
            let name = (model["display_name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            return ChatGPTModel(slug: slug, displayName: name ?? slug)
        }
    }

    private static func discoveryDocument(transport: ProviderTransport) async throws -> [String: Any] {
        let (data, response) = try await transport.send(getRequest(ChatGPTOAuth.discoveryEndpoint), maximumBytes: maximumResponseBytes)
        guard response.statusCode == 200,
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTSignInError.invalidToken("keys")
        }
        return document
    }

    private static func isAllowedAuthURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.port == nil
            && url.host.map { allowedKeyHosts.contains($0.lowercased()) } == true
    }

    private static func formRequest(_ url: URL, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private static func getRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

// MARK: - Accounts

/// The part of a ChatGPT registration that is not secret. Tokens live in Keychain.
struct ChatGPTAccount: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var clientID: String
    var subject: String
    var email: String?
    var name: String?
    var scopes: [String]
    var accessTokenExpiresAt: Date
    var signedInAt: Date
    var isSignedIn: Bool
    /// Set once the user has seen that requests use their ChatGPT plan.
    var planUseAcknowledged: Bool

    var planUseGranted: Bool { isSignedIn && scopes.contains(ChatGPTOAuth.planPermission) }
    var displayLabel: String { email ?? name ?? "ChatGPT account" }
}

struct ChatGPTTokenSet: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
}

/// Owns ChatGPT registrations for this Mac: the non-secret record file, the
/// Keychain token sets, and token refresh, which is serialized per account so a
/// rotating refresh token is never used twice.
actor ChatGPTAccountStore {
    static let shared = ChatGPTAccountStore()

    private struct Records: Codable {
        var hostID: String
        var accounts: [ChatGPTAccount]
    }

    private static let keychainService = "com.foodmapper.api-keys"
    private static let keychainAccountPrefix = "chatgpt-account-"
    private static let refreshMargin: TimeInterval = 5 * 60

    private let recordsURL: URL
    private let credentialStore: CredentialStore
    private let transport: ProviderTransport
    private var records: Records?
    private var refreshes: [UUID: Task<String, Error>] = [:]

    init(
        recordsURL: URL = FoodMapperStorage.privateDirectory(["Providers"]).appendingPathComponent("chatgpt_accounts.json"),
        credentialStore: CredentialStore = FoodMapperStorage.credentialStore,
        transport: ProviderTransport = URLSessionProviderTransport()
    ) {
        self.recordsURL = recordsURL
        self.credentialStore = credentialStore
        self.transport = transport
    }

    func accounts() -> [ChatGPTAccount] {
        loaded().accounts
    }

    func account(id: UUID) -> ChatGPTAccount? {
        loaded().accounts.first { $0.id == id }
    }

    /// The stable identifier of this installation, created on first use.
    func hostID() throws -> String {
        var current = loaded()
        if ChatGPTOAuth.isValidHostID(current.hostID) { return current.hostID }
        current.hostID = ChatGPTOAuth.makeHostID()
        try persist(current)
        return current.hostID
    }

    func idTokenHint(accountID: UUID) -> String? {
        tokens(accountID: accountID)?.idToken
    }

    /// Stores a validated sign-in. A returning account keeps its record ID.
    func completeSignIn(
        response: ChatGPTTokenResponse,
        identity: ChatGPTIdentity,
        clientID: String,
        existingAccountID: UUID?,
        now: Date = Date()
    ) throws -> ChatGPTAccount {
        var current = loaded()
        let existing = current.accounts.first { $0.id == existingAccountID }
            ?? current.accounts.first { $0.clientID == clientID && $0.subject == identity.subject }
        if let existing, existing.subject != identity.subject {
            throw ChatGPTSignInError.identityMismatch
        }
        let account = ChatGPTAccount(
            id: existing?.id ?? UUID(),
            clientID: clientID,
            subject: identity.subject,
            email: identity.email,
            name: identity.name,
            scopes: response.scopes,
            accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn)),
            signedInAt: now,
            isSignedIn: true,
            planUseAcknowledged: existing?.planUseAcknowledged ?? false
        )
        let tokenSet = ChatGPTTokenSet(
            accessToken: response.accessToken, refreshToken: response.refreshToken, idToken: response.idToken
        )
        guard save(tokenSet, accountID: account.id) else { throw ChatGPTSignInError.storageFailed }
        current.accounts.removeAll { $0.id == account.id }
        current.accounts.append(account)
        do {
            try persist(current)
        } catch {
            _ = credentialStore.remove(service: Self.keychainService, account: Self.keychainAccount(account.id))
            throw ChatGPTSignInError.storageFailed
        }
        return account
    }

    func acknowledgePlanUse(accountID: UUID) throws {
        var current = loaded()
        guard let index = current.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        current.accounts[index].planUseAcknowledged = true
        try persist(current)
    }

    /// A bearer token that is valid for at least five more minutes, refreshing first when needed.
    func accessToken(accountID: UUID, now: Date = Date()) async throws -> String {
        guard let account = account(id: accountID), account.isSignedIn,
              let current = tokens(accountID: accountID) else {
            throw ChatGPTSignInError.notSignedIn
        }
        guard account.planUseGranted else { throw ChatGPTSignInError.planNotGranted }
        if account.accessTokenExpiresAt.timeIntervalSince(now) > Self.refreshMargin {
            return current.accessToken
        }
        if let running = refreshes[accountID] { return try await running.value }
        guard let refreshToken = current.refreshToken else { throw ChatGPTSignInError.refreshRejected(nil) }

        let transport = self.transport
        let task = Task { () throws -> String in
            let response = try await ChatGPTAuthClient.refresh(
                refreshToken: refreshToken, clientID: account.clientID, transport: transport
            )
            return try self.storeRefreshed(response, accountID: accountID, previous: current)
        }
        refreshes[accountID] = task
        defer { refreshes[accountID] = nil }
        do {
            return try await task.value
        } catch let error as ChatGPTSignInError {
            if case .refreshRejected = error { markSignedOut(accountID: accountID) }
            throw error
        }
    }

    /// Signs out. Returns false when the remote session could not be confirmed revoked.
    @discardableResult
    func signOut(accountID: UUID) async -> Bool {
        guard let account = account(id: accountID) else { return true }
        var revoked = true
        if let refreshToken = tokens(accountID: accountID)?.refreshToken {
            revoked = await ChatGPTAuthClient.revoke(
                refreshToken: refreshToken, clientID: account.clientID, transport: transport
            )
        }
        markSignedOut(accountID: accountID)
        return revoked
    }

    /// Forgets a registration and its tokens on this Mac.
    func remove(accountID: UUID) throws {
        _ = credentialStore.remove(service: Self.keychainService, account: Self.keychainAccount(accountID))
        var current = loaded()
        current.accounts.removeAll { $0.id == accountID }
        try persist(current)
    }

    // MARK: Private

    private func storeRefreshed(
        _ response: ChatGPTTokenResponse, accountID: UUID, previous: ChatGPTTokenSet, now: Date = Date()
    ) throws -> String {
        var current = loaded()
        guard let index = current.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw ChatGPTSignInError.notSignedIn
        }
        let tokenSet = ChatGPTTokenSet(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? previous.refreshToken,
            idToken: response.idToken ?? previous.idToken
        )
        guard save(tokenSet, accountID: accountID) else { throw ChatGPTSignInError.storageFailed }
        current.accounts[index].accessTokenExpiresAt = now.addingTimeInterval(TimeInterval(response.expiresIn))
        if !response.scopes.isEmpty { current.accounts[index].scopes = response.scopes }
        try persist(current)
        return response.accessToken
    }

    private func markSignedOut(accountID: UUID) {
        _ = credentialStore.remove(service: Self.keychainService, account: Self.keychainAccount(accountID))
        var current = loaded()
        guard let index = current.accounts.firstIndex(where: { $0.id == accountID }) else { return }
        current.accounts[index].isSignedIn = false
        current.accounts[index].accessTokenExpiresAt = .distantPast
        do {
            try persist(current)
        } catch {
            signInLogger.error("Could not record ChatGPT sign-out")
        }
    }

    private func loaded() -> Records {
        if let records { return records }
        let value: Records
        if let data = try? Data(contentsOf: recordsURL),
           data.count <= 1_048_576,
           let decoded = try? Self.decoder.decode(Records.self, from: data) {
            value = decoded
        } else {
            value = Records(hostID: "", accounts: [])
        }
        records = value
        return value
    }

    private func persist(_ value: Records) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: recordsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: SecureFileAccess.privateFilePermissions], ofItemAtPath: recordsURL.path
        )
        records = value
    }

    private func tokens(accountID: UUID) -> ChatGPTTokenSet? {
        guard let data = credentialStore.value(service: Self.keychainService, account: Self.keychainAccount(accountID)) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatGPTTokenSet.self, from: data)
    }

    private func save(_ tokens: ChatGPTTokenSet, accountID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return credentialStore.set(
            data, service: Self.keychainService, account: Self.keychainAccount(accountID),
            label: "FoodMapper ChatGPT sign-in"
        )
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func keychainAccount(_ id: UUID) -> String {
        keychainAccountPrefix + id.uuidString.lowercased()
    }
}
