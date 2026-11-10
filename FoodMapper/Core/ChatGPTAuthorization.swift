import CryptoKit
import Foundation
import Security

/// Sign in with ChatGPT for open-source, locally hosted apps: constants and
/// the request and response handling that needs no network.
///
/// The flow is a public-client OAuth authorization-code grant with PKCE and a
/// loopback redirect. The first sign-in registers a client for the user; the
/// callback returns the issued client ID that every later request uses.
enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let authorizationEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let discoveryEndpoint = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    static let resource = "https://api.openai.com/v1"
    static let registrationClientID = "dynamic_agent_client"
    static let agentName = "FoodMapper"
    static let callbackHost = "127.0.0.1"
    static let callbackPath = "/auth/callback"
    static let planPermission = "chatgpt.tokens.use.direct"
    static let requestedScopes = [
        "openid", "profile", "email", "offline_access", "resource.invoke", planPermission,
    ]

    static func redirectURI(port: UInt16) -> String {
        "http://\(callbackHost):\(port)\(callbackPath)"
    }

    /// A new opaque host identifier. It names this installation; it is not a credential.
    static func makeHostID() -> String {
        "urn:uuid:\(UUID().uuidString.lowercased())"
    }

    static func isValidHostID(_ value: String) -> Bool {
        guard value.hasPrefix("urn:uuid:") else { return false }
        return UUID(uuidString: String(value.dropFirst("urn:uuid:".count))) != nil
    }

    static func isPlausibleClientID(_ value: String) -> Bool {
        value != registrationClientID
            && (1...200).contains(value.count)
            && value.unicodeScalars.allSatisfy { clientIDCharacters.contains($0) }
    }

    private static let clientIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    )
    fileprivate static let unreserved = clientIDCharacters
}

enum ChatGPTSignInError: LocalizedError, Equatable {
    case accessDenied
    case stateMismatch
    case missingCode
    case registrationIncomplete
    case clientMismatch
    case provider(String)
    case invalidToken(String)
    case identityMismatch
    case planNotGranted
    case listenerUnavailable
    case browserUnavailable
    case timedOut
    case tokenRequestFailed(String?)
    case refreshRejected(String?)
    case notSignedIn
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Sign-in was cancelled in the browser."
        case .stateMismatch: return "The sign-in response did not match this request. Start again."
        case .missingCode: return "The sign-in response was incomplete. Start again."
        case .registrationIncomplete: return "OpenAI did not return a client registration. Start again."
        case .clientMismatch: return "The sign-in response named a different registration. Start again."
        case let .provider(code): return "OpenAI returned a sign-in error (\(code))."
        case let .invalidToken(reason): return "The identity token from OpenAI could not be verified (\(reason))."
        case .identityMismatch: return "That browser session belongs to a different ChatGPT account than the one selected."
        case .planNotGranted: return "ChatGPT plan use was not granted. Sign in again and allow it, or use an API key."
        case .listenerUnavailable: return "FoodMapper could not open a local sign-in callback on this Mac."
        case .browserUnavailable: return "FoodMapper could not open your web browser. Check that a default browser is set, then try again."
        case .timedOut: return "Sign-in was not completed in time."
        case let .tokenRequestFailed(code): return "OpenAI did not issue credentials\(code.map { " (\($0))" } ?? "")."
        case let .refreshRejected(code): return "The saved ChatGPT sign-in is no longer valid\(code.map { " (\($0))" } ?? ""). Sign in again."
        case .notSignedIn: return "Sign in with ChatGPT first."
        case .storageFailed: return "The ChatGPT sign-in could not be stored in Keychain."
        }
    }
}

/// Values that belong to one authorization attempt and are discarded after it.
struct ChatGPTAuthorizationAttempt: Equatable, Sendable {
    let state: String
    let nonce: String
    let codeVerifier: String
    let redirectURI: String
    /// `dynamic_agent_client` for a first registration, otherwise the issued client ID.
    let clientID: String

    var isRegistration: Bool { clientID == ChatGPTOAuth.registrationClientID }

    var codeChallenge: String {
        Base64URL.encode(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
    }

    static func make(port: UInt16, issuedClientID: String?) throws -> ChatGPTAuthorizationAttempt {
        ChatGPTAuthorizationAttempt(
            state: try Base64URL.random(byteCount: 32),
            nonce: try Base64URL.random(byteCount: 32),
            codeVerifier: try Base64URL.random(byteCount: 48),
            redirectURI: ChatGPTOAuth.redirectURI(port: port),
            clientID: issuedClientID ?? ChatGPTOAuth.registrationClientID
        )
    }

    /// The browser URL for this attempt. The result may contain an ID token hint; never log it.
    func authorizationURL(hostID: String, idTokenHint: String? = nil, loginHint: String? = nil) -> URL {
        var items: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("scope", ChatGPTOAuth.requestedScopes.joined(separator: " ")),
            ("resource", ChatGPTOAuth.resource),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge_method", "S256"),
            ("code_challenge", codeChallenge),
            ("ext_agent_host_id", hostID),
        ]
        if isRegistration {
            items.append(("agent_name_hint", ChatGPTOAuth.agentName))
        } else {
            if let idTokenHint, !idTokenHint.isEmpty { items.append(("id_token_hint", idTokenHint)) }
            if let loginHint, !loginHint.isEmpty { items.append(("login_hint", loginHint)) }
        }
        var components = URLComponents(url: ChatGPTOAuth.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = FormEncoding.encode(items)
        return components.url!
    }

    func tokenRequestBody(code: String, clientID: String) -> Data {
        Data(FormEncoding.encode([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("redirect_uri", redirectURI),
            ("resource", ChatGPTOAuth.resource),
        ]).utf8)
    }
}

struct ChatGPTCallback: Equatable, Sendable {
    let code: String
    /// The client ID to use for the code exchange and to save with the account.
    let clientID: String

    /// Validates the request target the browser sent to the loopback listener,
    /// for example `/auth/callback?code=...&state=...`.
    static func parse(requestTarget: String, attempt: ChatGPTAuthorizationAttempt) throws -> ChatGPTCallback {
        guard requestTarget.count <= 8_192,
              let components = URLComponents(string: "http://\(ChatGPTOAuth.callbackHost)\(requestTarget)"),
              components.path == ChatGPTOAuth.callbackPath else {
            throw ChatGPTSignInError.missingCode
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { throw ChatGPTSignInError.missingCode }
            values[item.name] = item.value ?? ""
        }
        guard let state = values["state"], Base64URL.constantTimeEquals(state, attempt.state) else {
            throw ChatGPTSignInError.stateMismatch
        }
        if let error = values["error"] {
            throw error == "access_denied" ? ChatGPTSignInError.accessDenied : ChatGPTSignInError.provider(String(error.prefix(80)))
        }
        guard let code = values["code"], !code.isEmpty, code.count <= 4_096 else {
            throw ChatGPTSignInError.missingCode
        }
        let returnedClientID = values["client_id"]
        if attempt.isRegistration {
            guard let issued = returnedClientID, ChatGPTOAuth.isPlausibleClientID(issued) else {
                throw ChatGPTSignInError.registrationIncomplete
            }
            return ChatGPTCallback(code: code, clientID: issued)
        }
        if let returnedClientID, returnedClientID != attempt.clientID {
            throw ChatGPTSignInError.clientMismatch
        }
        return ChatGPTCallback(code: code, clientID: attempt.clientID)
    }
}

struct ChatGPTTokenResponse: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int
    let scopes: [String]

    var grantsPlanUse: Bool { scopes.contains(ChatGPTOAuth.planPermission) }

    init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = root["access_token"] as? String, !accessToken.isEmpty,
              ((root["token_type"] as? String) ?? "Bearer").caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw ChatGPTSignInError.tokenRequestFailed(nil)
        }
        self.accessToken = accessToken
        self.refreshToken = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.idToken = (root["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let lifetime = (root["expires_in"] as? NSNumber)?.intValue ?? 0
        self.expiresIn = min(max(lifetime, 0), 86_400)
        self.scopes = ((root["scope"] as? String) ?? "").split(separator: " ").map(String.init).sorted()
    }

    /// The OAuth error code from a failed token response, when the body has one.
    static func errorCode(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = root["error"] as? String { return String(code.prefix(80)) }
        if let error = root["error"] as? [String: Any], let code = error["code"] as? String { return String(code.prefix(80)) }
        return nil
    }

    static let unusableRefreshCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused",
    ]
}

struct ChatGPTIdentity: Equatable, Sendable {
    let subject: String
    let email: String?
    let name: String?
}

/// ID token checks: signature against the issuer's published keys, then issuer,
/// audience, expiry, and the nonce of the attempt that requested it.
enum ChatGPTIDToken {
    static func validate(
        _ token: String,
        jwks: Data,
        clientID: String,
        nonce: String?,
        now: Date = Date()
    ) throws -> ChatGPTIdentity {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, token.utf8.count <= 16_384,
              let headerData = Base64URL.decode(String(segments[0])),
              let payloadData = Base64URL.decode(String(segments[1])),
              let signature = Base64URL.decode(String(segments[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let algorithm = header["alg"] as? String else {
            throw ChatGPTSignInError.invalidToken("format")
        }
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        guard try verify(signingInput: signingInput, signature: signature, algorithm: algorithm,
                         keyID: header["kid"] as? String, jwks: jwks) else {
            throw ChatGPTSignInError.invalidToken("signature")
        }

        guard (payload["iss"] as? String) == ChatGPTOAuth.issuer else {
            throw ChatGPTSignInError.invalidToken("issuer")
        }
        let audiences = (payload["aud"] as? [String]) ?? (payload["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID) else { throw ChatGPTSignInError.invalidToken("audience") }
        guard let expiry = (payload["exp"] as? NSNumber)?.doubleValue, now.timeIntervalSince1970 < expiry + 60 else {
            throw ChatGPTSignInError.invalidToken("expired")
        }
        if let notBefore = (payload["nbf"] as? NSNumber)?.doubleValue, now.timeIntervalSince1970 + 60 < notBefore {
            throw ChatGPTSignInError.invalidToken("not yet valid")
        }
        if let nonce {
            guard let tokenNonce = payload["nonce"] as? String, Base64URL.constantTimeEquals(tokenNonce, nonce) else {
                throw ChatGPTSignInError.invalidToken("nonce")
            }
        }
        guard let subject = payload["sub"] as? String, !subject.isEmpty, subject.count <= 255 else {
            throw ChatGPTSignInError.invalidToken("subject")
        }
        return ChatGPTIdentity(
            subject: subject,
            email: (payload["email"] as? String).map { String($0.prefix(254)) },
            name: (payload["name"] as? String).map { String($0.prefix(120)) }
        )
    }

    private static func verify(
        signingInput: Data, signature: Data, algorithm: String, keyID: String?, jwks: Data
    ) throws -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = root["keys"] as? [[String: Any]] else {
            throw ChatGPTSignInError.invalidToken("keys")
        }
        let expectedType = algorithm == "RS256" ? "RSA" : algorithm == "ES256" ? "EC" : nil
        guard let expectedType else { throw ChatGPTSignInError.invalidToken("algorithm") }
        let candidates = keys.filter { key in
            (key["kty"] as? String) == expectedType
                && ((key["use"] as? String) ?? "sig") == "sig"
                && ((key["alg"] as? String) ?? algorithm) == algorithm
                && (keyID == nil || (key["kid"] as? String) == keyID)
        }
        guard !candidates.isEmpty, candidates.count <= 8 else { throw ChatGPTSignInError.invalidToken("key") }
        for key in candidates {
            if algorithm == "RS256", verifyRS256(key: key, signingInput: signingInput, signature: signature) { return true }
            if algorithm == "ES256", verifyES256(key: key, signingInput: signingInput, signature: signature) { return true }
        }
        return false
    }

    private static func verifyRS256(key: [String: Any], signingInput: Data, signature: Data) -> Bool {
        guard let modulus = (key["n"] as? String).flatMap(Base64URL.decode),
              let exponent = (key["e"] as? String).flatMap(Base64URL.decode),
              modulus.count >= 256, modulus.count <= 1_024, !exponent.isEmpty, exponent.count <= 8 else {
            return false
        }
        let der = DER.sequence(DER.unsignedInteger(modulus) + DER.unsignedInteger(exponent))
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: modulus.count * 8,
        ]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(
            publicKey, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData, signature as CFData, nil
        )
    }

    private static func verifyES256(key: [String: Any], signingInput: Data, signature: Data) -> Bool {
        guard (key["crv"] as? String) == "P-256",
              let x = (key["x"] as? String).flatMap(Base64URL.decode), x.count == 32,
              let y = (key["y"] as? String).flatMap(Base64URL.decode), y.count == 32,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y),
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            return false
        }
        return publicKey.isValidSignature(parsed, for: signingInput)
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        guard value.utf8.allSatisfy({ byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F
        }) else { return nil }
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }

    static func random(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw ChatGPTSignInError.listenerUnavailable
        }
        return encode(Data(bytes))
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

enum FormEncoding {
    /// `application/x-www-form-urlencoded` with every reserved character escaped.
    static func encode(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: ChatGPTOAuth.unreserved) ?? ""
    }
}

/// The two DER forms needed to hand an RSA public key from a JWK to Security.
enum DER {
    static func unsignedInteger(_ magnitude: Data) -> Data {
        var bytes = Data(magnitude.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return Data([0x02]) + length(bytes.count) + bytes
    }

    static func sequence(_ content: Data) -> Data {
        Data([0x30]) + length(content.count) + content
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}
