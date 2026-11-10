import CryptoKit
import Security
import XCTest
@testable import FoodMapper

/// Canned provider responses. No test in this file reaches a remote host.
private final class StubProviderTransport: ProviderTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers, chunks: [try! JSONSerialization.data(withJSONObject: object)])
        }

        static func events(_ events: [[String: Any]], split: Int = 37) -> Reply {
            let text = events.map { "data: " + String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\r\n\r\n" }.joined()
            let bytes = Array(text.utf8)
            let chunks = stride(from: 0, to: bytes.count, by: split).map { Data(bytes[$0..<min($0 + split, bytes.count)]) }
            return Reply(chunks: chunks)
        }
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let reply: Reply = lock.withLock {
            recorded.append(request)
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (response, AsyncThrowingStream { continuation in
            reply.chunks.forEach { continuation.yield($0) }
            continuation.finish()
        })
    }
}

private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func set(_ value: Data, service: String, account: String, label: String) -> Bool {
        lock.withLock { values[service + "|" + account] = value }
        return true
    }
    func value(service: String, account: String) -> Data? { lock.withLock { values[service + "|" + account] } }
    func remove(service: String, account: String) -> Bool {
        lock.withLock { values[service + "|" + account] = nil }
        return true
    }
    var count: Int { lock.withLock { values.count } }
}

private func decisionEvents(_ json: String, usage: [String: Any] = ["input_tokens": 120, "output_tokens": 9]) -> [[String: Any]] {
    let half = json.index(json.startIndex, offsetBy: json.count / 2)
    return [
        ["type": "response.created"],
        ["type": "response.output_text.delta", "delta": String(json[..<half])],
        ["type": "response.output_text.delta", "delta": String(json[half...])],
        ["type": "response.completed", "response": [
            "status": "completed",
            "usage": usage,
            "output": [["type": "message", "content": [["type": "output_text", "text": json]]]],
        ]],
    ]
}

final class OpenAIAdapterTests: XCTestCase {
    private func payload() throws -> ProviderDecisionPayload {
        try ProviderDecisionPayload(
            input: "boiled broccoli", candidates: ["Broccoli, raw", "Broccoli, cooked, boiled"], instruction: "Preparation must match."
        )
    }

    func testResponsesBodyFollowsTheBillingRoute() throws {
        let plan = try JSONSerialization.jsonObject(with: OpenAIResponsesRequest.data(
            model: "gpt-6-luna", payload: payload(), effort: .low, billing: .chatGPTPlan
        )) as! [String: Any]
        XCTAssertEqual(plan["store"] as? Bool, false)
        XCTAssertEqual(plan["stream"] as? Bool, true)
        XCTAssertEqual(plan["instructions"] as? String, OpenAIResponsesRequest.decisionInstructions)
        XCTAssertEqual((plan["reasoning"] as? [String: String])?["effort"], "low")
        for forbidden in ["max_output_tokens", "temperature", "metadata", "previous_response_id", "top_p", "user", "truncation"] {
            XCTAssertNil(plan[forbidden], forbidden)
        }
        let input = try XCTUnwrap(plan["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let text = try XCTUnwrap(((input[0]["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertTrue(text.contains("\"candidate_id\":\"c2\""))
        let format = try XCTUnwrap((plan["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)

        let key = try JSONSerialization.jsonObject(with: OpenAIResponsesRequest.data(
            model: "gpt-6-luna", payload: payload(), effort: nil, billing: .apiKey
        )) as! [String: Any]
        XCTAssertEqual(key["max_output_tokens"] as? Int, ProviderReasoningEffort.medium.outputTokenLimit)
        XCTAssertNil(key["reasoning"])
        XCTAssertNotEqual(
            try OpenAIResponsesRequest.schemaHash(candidateIDs: ["c1", "c2"]),
            try OpenAIResponsesRequest.schemaHash(candidateIDs: ["c1", "c2", "c3"])
        )
    }

    func testPayloadRejectsOversizedFields() {
        XCTAssertThrowsError(try ProviderDecisionPayload(input: String(repeating: "a", count: 1_025), candidates: ["x"], instruction: nil))
        XCTAssertThrowsError(try ProviderDecisionPayload(input: "a", candidates: [], instruction: nil))
        XCTAssertThrowsError(try ProviderDecisionPayload(input: "a", candidates: [String(repeating: "b", count: 513)], instruction: nil))
        XCTAssertThrowsError(try ProviderDecisionPayload(
            input: "a", candidates: Array(repeating: "x", count: AdvancedRunLimits.maximum.candidateCount + 1), instruction: nil
        ))
    }

    func testStreamReducerReadsACompletedDecision() throws {
        var reducer = ResponsesStreamReducer()
        for event in decisionEvents(#"{"decision":"select","candidate_id":"c2"}"#) {
            let line = "data: " + String(data: try JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
            try reducer.consume(line: "event: ignored")
            try reducer.consume(line: line)
        }
        XCTAssertEqual(reducer.outcome, .completed)
        XCTAssertEqual(reducer.completedText, #"{"decision":"select","candidate_id":"c2"}"#)
        XCTAssertEqual(reducer.usage?.inputTokens, 120)
        XCTAssertEqual(reducer.usage?.outputTokens, 9)
    }

    func testStreamReducerTerminalStatesAndRefusal() throws {
        var failed = ResponsesStreamReducer()
        try failed.consume(line: #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"x"}}}"#)
        XCTAssertEqual(failed.outcome, .failed(code: "subscription_sharing_usage_limit_exceeded", message: "x"))
        XCTAssertNil(failed.completedText)

        var incomplete = ResponsesStreamReducer()
        try incomplete.consume(line: #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#)
        XCTAssertEqual(incomplete.outcome, .incomplete(reason: "max_output_tokens"))

        var refused = ResponsesStreamReducer()
        try refused.consume(line: #"data: {"type":"response.refusal.delta","delta":"no"}"#)
        try refused.consume(line: #"data: {"type":"response.completed","response":{"output":[]}}"#)
        XCTAssertEqual(refused.outcome, .completed)
        XCTAssertNil(refused.completedText)

        var malformed = ResponsesStreamReducer()
        XCTAssertThrowsError(try malformed.consume(line: "data: not json"))
        var done = ResponsesStreamReducer()
        try done.consume(line: "data: [DONE]")
        XCTAssertNil(done.outcome)
    }

    func testLineSplitterKeepsLinesAcrossChunks() {
        var splitter = LineSplitter()
        var lines = splitter.append(Data("data: a\r\nda".utf8))
        lines += splitter.append(Data("ta: b\n\ndata".utf8))
        lines += splitter.append(Data(": c".utf8))
        XCTAssertEqual(lines, ["data: a", "data: b", ""])
        XCTAssertEqual(splitter.finish(), "data: c")
        XCTAssertNil(splitter.finish())
    }

    func testDecisionsRequestAndParser() throws {
        let body = try JSONSerialization.jsonObject(with: OpenAIDecisionsRequest.data(model: "gpt-6-luna", payload: payload())) as! [String: Any]
        let question = try XCTUnwrap((body["questions"] as? [[String: Any]])?.first)
        XCTAssertEqual(question["type"] as? String, "choice")
        XCTAssertEqual((question["choices"] as? [[String: String]])?.map { $0["value"] }, ["c1", "c2", "none"])
        XCTAssertNil(body["stream"])

        func answer(_ choice: String, _ probabilities: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["answers": [[
                "type": "choice", "name": "match", "choice": choice, "probabilities": probabilities, "confidence": 0.91,
            ]], "usage": ["input_tokens": 80]])
        }
        let full: [[String: Any]] = [
            ["value": "none", "probability": 0.03], ["value": "c2", "probability": 0.95], ["value": "c1", "probability": 0.02],
        ]
        let selected = try OpenAIDecisionsParser.decision(from: answer("c2", full), candidateIDs: ["c1", "c2"])
        XCTAssertEqual(selected.selection, 1)
        XCTAssertEqual(selected.probabilities, [0.02, 0.95, 0.03])
        XCTAssertEqual(selected.confidence, 0.91)
        XCTAssertEqual(selected.usage?.inputTokens, 80)
        XCTAssertNil(try OpenAIDecisionsParser.decision(from: answer("none", full), candidateIDs: ["c1", "c2"]).selection)

        XCTAssertThrowsError(try OpenAIDecisionsParser.decision(from: answer("c9", full), candidateIDs: ["c1", "c2"]))
        XCTAssertThrowsError(try OpenAIDecisionsParser.decision(from: answer("c2", Array(full.dropLast())), candidateIDs: ["c1", "c2"]))
        XCTAssertThrowsError(try OpenAIDecisionsParser.decision(
            from: answer("c2", [["value": "c1", "probability": 1.4], ["value": "c2", "probability": 0.1], ["value": "none", "probability": 0]]),
            candidateIDs: ["c1", "c2"]
        ))
        let refusal = try JSONSerialization.data(withJSONObject: ["answers": [["type": "refusal", "name": "match"]]])
        XCTAssertThrowsError(try OpenAIDecisionsParser.decision(from: refusal, candidateIDs: ["c1", "c2"]))
    }

    func testErrorClassificationAndRetryPolicy() {
        XCTAssertEqual(ProviderErrorClassifier.classify(status: 429, code: "subscription_sharing_usage_limit_exceeded"), .halt(.planLimitReached))
        XCTAssertEqual(ProviderErrorClassifier.classify(status: 403, code: "subscription_sharing_user_not_eligible"), .halt(.planNotAvailable))
        XCTAssertEqual(ProviderErrorClassifier.classify(status: 401, code: nil), .halt(.signInRequired))
        XCTAssertEqual(ProviderErrorClassifier.classify(status: 429, code: "insufficient_quota"), .halt(.quotaExhausted))
        XCTAssertEqual(ProviderErrorClassifier.classify(status: 400, code: "subscription_sharing_unsupported_capability", parameter: "temperature"), .halt(.unsupportedRequest("temperature")))
        XCTAssertEqual(ProviderErrorClassifier.classify(status: 429, code: nil, retryAfter: 2), .retry(after: 2, status: 429))
        XCTAssertEqual(ProviderErrorClassifier.classify(status: 503, code: "subscription_sharing_usage_unavailable"), .retry(after: nil, status: 503))
        XCTAssertEqual(ProviderErrorClassifier.classify(status: nil, code: "rate_limit_exceeded"), .retry(after: nil, status: nil))
        XCTAssertEqual(ProviderErrorClassifier.classify(status: 400, code: nil), .row(status: 400))
        XCTAssertEqual(ProviderErrorClassifier.errorFields(in: Data(#"{"detail":"not enabled"}"#.utf8)).code, nil)
        XCTAssertEqual(ProviderErrorClassifier.errorFields(in: Data(#"{"error":{"code":"x","param":"model"}}"#.utf8)).parameter, "model")

        XCTAssertEqual(ProviderRetryPolicy.delay(attempt: 1, hint: 0), 0.25)
        XCTAssertEqual(ProviderRetryPolicy.delay(attempt: 1, hint: 900), 120)
        XCTAssertEqual(ProviderRetryPolicy.delay(attempt: 1, hint: nil, jitter: 0), 0.5)
        XCTAssertEqual(ProviderRetryPolicy.delay(attempt: 3, hint: nil, jitter: 1), 4)
        XCTAssertEqual(ProviderRetryPolicy.delay(attempt: 30, hint: nil, jitter: 1), 16)
    }

    func testProfileFieldsValidateAndOldProfilesDecode() throws {
        let old = #"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Local","kind":"localOpenAICompatible","baseURL":"http://127.0.0.1:8000/v1","model":"m","maximumOutputTokens":128}"#
        let decoded = try JSONDecoder().decode(ProviderProfile.self, from: Data(old.utf8)).validated()
        XCTAssertEqual(decoded.interface, .chatCompletions)
        XCTAssertEqual(decoded.concurrency, 1)
        XCTAssertNil(decoded.accountID)

        var plan = ProviderProfile(name: "Plan", kind: .chatGPTPlan, model: "gpt-6-luna", interface: .responses, reasoningEffort: .low, concurrency: 4)
        XCTAssertThrowsError(try plan.validated()) { XCTAssertEqual($0 as? ProviderProfileError, .accountRequired) }
        plan.accountID = UUID()
        let checkedPlan = try plan.validated()
        XCTAssertEqual(checkedPlan.baseURL, "https://api.openai.com/v1")
        plan.interface = .decisions
        XCTAssertThrowsError(try plan.validated()) { XCTAssertEqual($0 as? ProviderProfileError, .interfaceNotAvailable) }
        plan.interface = .responses
        plan.concurrency = 9
        XCTAssertThrowsError(try plan.validated()) { XCTAssertEqual($0 as? ProviderProfileError, .invalidConcurrency(8)) }

        let responses = ProviderProfile(name: "Key", kind: .openAI, model: "gpt-6-luna", interface: .responses, reasoningEffort: .low, concurrency: 8)
        var decisions = responses
        decisions.interface = .decisions
        XCTAssertNil(try decisions.validated().reasoningEffort)
        XCTAssertNotEqual(try responses.nonsecretFingerprint(), try decisions.nonsecretFingerprint())
        var higher = responses
        higher.reasoningEffort = .high
        XCTAssertNotEqual(try responses.nonsecretFingerprint(), try higher.nonsecretFingerprint())
        var moreWorkers = responses
        moreWorkers.concurrency = 2
        XCTAssertEqual(try responses.nonsecretFingerprint(), try moreWorkers.nonsecretFingerprint())
        XCTAssertThrowsError(try ProviderProfile(name: "L", kind: .localOpenAICompatible, baseURL: "http://127.0.0.1:1/v1", model: "m", interface: .responses).validated())
        XCTAssertNotEqual(
            try ProviderProbeClient.requestSchemaHash(for: .responses), try ProviderProbeClient.requestSchemaHash(for: .decisions)
        )
    }

    func testDecisionClientUsesEachRoute() async throws {
        let payload = try payload()
        let plan = ProviderProfile(name: "Plan", kind: .chatGPTPlan, model: "gpt-6-luna", interface: .responses, reasoningEffort: .low, concurrency: 2, accountID: UUID())
        let stream = StubProviderTransport([.events(decisionEvents(#"{"decision":"select","candidate_id":"c2"}"#))])
        let streamed = try await ProviderDecisionClient.decide(payload: payload, profile: plan, credential: "token-value", transport: stream)
        XCTAssertEqual(streamed.selection, 1)
        XCTAssertEqual(stream.requests.first?.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(stream.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")

        let key = ProviderProfile(name: "Key", kind: .openAI, model: "gpt-6-luna", interface: .decisions, concurrency: 2)
        let decisions = StubProviderTransport([.json(["answers": [["type": "choice", "name": "match", "choice": "none", "confidence": 0.7]]])])
        let decided = try await ProviderDecisionClient.decide(payload: payload, profile: key, credential: "k", transport: decisions)
        XCTAssertNil(decided.selection)
        XCTAssertEqual(decisions.requests.first?.url?.absoluteString, "https://api.openai.com/v1/decisions")

        let local = ProviderProfile(name: "Local", kind: .localOpenAICompatible, baseURL: "http://127.0.0.1:8000/v1", model: "m")
        let chat = StubProviderTransport([.json(["choices": [["message": ["content": #"{"decision":"abstain","candidate_id":null}"#]]]])])
        let chatDecision = try await ProviderDecisionClient.decide(payload: payload, profile: local, credential: nil, transport: chat)
        XCTAssertNil(chatDecision.selection)
        XCTAssertNil(chat.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testDecisionClientMapsFailures() async throws {
        let payload = try payload()
        let plan = ProviderProfile(name: "Plan", kind: .chatGPTPlan, model: "gpt-6-luna", interface: .responses, concurrency: 1, accountID: UUID())
        func failure(_ reply: StubProviderTransport.Reply) async -> ProviderFailure? {
            do {
                _ = try await ProviderDecisionClient.decide(payload: payload, profile: plan, credential: "t", transport: StubProviderTransport([reply]))
                return nil
            } catch { return error as? ProviderFailure }
        }
        let limited = await failure(.json(["error": ["code": "subscription_sharing_usage_limit_exceeded"]], status: 429))
        XCTAssertEqual(limited, .halt(.planLimitReached))
        let throttled = await failure(.json(["error": ["code": "rate_limit_exceeded"]], status: 429, headers: ["Retry-After": "3"]))
        XCTAssertEqual(throttled, .retry(after: 3, status: 429))
        let admission = await failure(.json(["detail": "direct routing is not enabled"], status: 503))
        XCTAssertEqual(admission, .retry(after: nil, status: 503))
        let midStream = await failure(.events([["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]]]))
        XCTAssertEqual(midStream, .halt(.planLimitReached))
        let cutOff = await failure(.events([["type": "response.output_text.delta", "delta": "{"]]))
        XCTAssertEqual(cutOff, .retry(after: nil, status: nil))
        let truncated = await failure(.events([["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]]]))
        XCTAssertEqual(truncated, .row(status: nil))
    }

    func testRowRetriesThenSucceedsAndAHaltStopsLaterRows() async throws {
        let plan = ProviderProfile(name: "Plan", kind: .chatGPTPlan, model: "gpt-6-luna", interface: .responses, concurrency: 1, accountID: UUID())
        let coordinator = ProviderRunCoordinator()
        let recovering = StubProviderTransport([
            .json(["error": ["code": "rate_limit_exceeded"]], status: 429, headers: ["Retry-After": "0"]),
            .events(decisionEvents(#"{"decision":"select","candidate_id":"c1"}"#)),
        ])
        let decision = try await ProviderRerankerPipeline.decideWithRetry(
            input: "milk", candidates: ["Milk, whole", "Milk, nonfat"], instruction: nil, profile: plan,
            credentialSource: { "t" }, transport: recovering, coordinator: coordinator
        )
        XCTAssertEqual(decision.selection, 0)
        let retries = await coordinator.retries
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(recovering.requests.count, 2)
        let usage = await coordinator.usage
        XCTAssertEqual(usage.inputTokens, 120)

        let halting = StubProviderTransport([.json(["error": ["code": "subscription_sharing_usage_limit_exceeded"]], status: 429)])
        for _ in 0..<2 {
            do {
                _ = try await ProviderRerankerPipeline.decideWithRetry(
                    input: "milk", candidates: ["Milk, whole"], instruction: nil, profile: plan,
                    credentialSource: { "t" }, transport: halting, coordinator: coordinator
                )
                XCTFail("expected a failure")
            } catch {}
        }
        let reason = await coordinator.haltReason
        XCTAssertEqual(reason, .planLimitReached)
        XCTAssertEqual(halting.requests.count, 1, "no request is sent after the run halts")

        let expired = ProviderRunCoordinator()
        do {
            _ = try await ProviderRerankerPipeline.decideWithRetry(
                input: "milk", candidates: ["Milk, whole"], instruction: nil, profile: plan,
                credentialSource: { throw ChatGPTSignInError.refreshRejected("invalid_grant") },
                transport: halting, coordinator: expired
            )
            XCTFail("expected a failure")
        } catch {}
        let expiredReason = await expired.haltReason
        XCTAssertEqual(expiredReason, .signInRequired)
    }
}

final class ChatGPTAuthorizationTests: XCTestCase {
    private func attempt(clientID: String? = nil) throws -> ChatGPTAuthorizationAttempt {
        try ChatGPTAuthorizationAttempt.make(port: 54_321, issuedClientID: clientID)
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testRegistrationAndReturningAuthorizationURLs() throws {
        let first = try attempt()
        let hostID = ChatGPTOAuth.makeHostID()
        XCTAssertTrue(ChatGPTOAuth.isValidHostID(hostID))
        let url = first.authorizationURL(hostID: hostID, idTokenHint: "ignored", loginHint: "ignored")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        XCTAssertTrue(url.absoluteString.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fauth%2Fcallback"))
        let items = query(url)
        XCTAssertEqual(items["client_id"], "dynamic_agent_client")
        XCTAssertEqual(items["agent_name_hint"], "FoodMapper")
        XCTAssertEqual(items["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(items["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], Base64URL.encode(Data(SHA256.hash(data: Data(first.codeVerifier.utf8)))))
        XCTAssertEqual(items["ext_agent_host_id"], hostID)
        XCTAssertNil(items["id_token_hint"])
        XCTAssertNil(items["login_hint"])
        XCTAssertNotEqual(first.state, try attempt().state)
        XCTAssertGreaterThanOrEqual(first.codeVerifier.count, 43)

        let again = query(try attempt(clientID: "oaiapp_abc123").authorizationURL(hostID: hostID, idTokenHint: "a.b.c", loginHint: "person@example.org"))
        XCTAssertEqual(again["client_id"], "oaiapp_abc123")
        XCTAssertNil(again["agent_name_hint"])
        XCTAssertEqual(again["id_token_hint"], "a.b.c")
        XCTAssertEqual(again["login_hint"], "person@example.org")
    }

    func testCallbackValidation() throws {
        let first = try attempt()
        let good = try ChatGPTCallback.parse(requestTarget: "/auth/callback?code=abc&state=\(first.state)&client_id=oaiapp_abc123&scope=openid", attempt: first)
        XCTAssertEqual(good, ChatGPTCallback(code: "abc", clientID: "oaiapp_abc123"))

        func error(_ target: String, _ attempt: ChatGPTAuthorizationAttempt) -> ChatGPTSignInError? {
            do { _ = try ChatGPTCallback.parse(requestTarget: target, attempt: attempt); return nil } catch { return error as? ChatGPTSignInError }
        }
        XCTAssertEqual(error("/auth/callback?code=abc&state=wrong&client_id=oaiapp_abc123", first), .stateMismatch)
        XCTAssertEqual(error("/auth/callback?error=access_denied&state=wrong", first), .stateMismatch)
        XCTAssertEqual(error("/auth/callback?error=access_denied&state=\(first.state)", first), .accessDenied)
        XCTAssertEqual(error("/auth/callback?code=abc&state=\(first.state)", first), .registrationIncomplete)
        XCTAssertEqual(error("/auth/callback?code=abc&state=\(first.state)&client_id=dynamic_agent_client", first), .registrationIncomplete)
        XCTAssertEqual(error("/auth/callback?code=abc&code=def&state=\(first.state)&client_id=oaiapp_abc123", first), .missingCode)
        XCTAssertEqual(error("/callback?code=abc&state=\(first.state)&client_id=oaiapp_abc123", first), .missingCode)

        let returning = try attempt(clientID: "oaiapp_abc123")
        XCTAssertEqual(try ChatGPTCallback.parse(requestTarget: "/auth/callback?code=abc&state=\(returning.state)", attempt: returning).clientID, "oaiapp_abc123")
        XCTAssertEqual(error("/auth/callback?code=abc&state=\(returning.state)&client_id=oaiapp_other", returning), .clientMismatch)

        let body = String(decoding: returning.tokenRequestBody(code: "a+b/c", clientID: "oaiapp_abc123"), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=a%2Bb%2Fc"))
        XCTAssertTrue(body.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"))
    }

    func testTokenResponseParsing() throws {
        let response = try ChatGPTTokenResponse(data: Data(#"{"access_token":"a","refresh_token":"r","id_token":"i","token_type":"Bearer","expires_in":3600,"scope":"openid chatgpt.tokens.use.direct email"}"#.utf8))
        XCTAssertTrue(response.grantsPlanUse)
        XCTAssertEqual(response.expiresIn, 3_600)
        XCTAssertEqual(response.refreshToken, "r")
        let identityOnly = try ChatGPTTokenResponse(data: Data(#"{"access_token":"a","token_type":"bearer","expires_in":3600,"scope":"openid email"}"#.utf8))
        XCTAssertFalse(identityOnly.grantsPlanUse)
        XCTAssertThrowsError(try ChatGPTTokenResponse(data: Data(#"{"token_type":"Bearer"}"#.utf8)))
        XCTAssertThrowsError(try ChatGPTTokenResponse(data: Data(#"{"access_token":"a","token_type":"mac"}"#.utf8)))
        XCTAssertEqual(ChatGPTTokenResponse.errorCode(in: Data(#"{"error":"invalid_grant"}"#.utf8)), "invalid_grant")
        XCTAssertTrue(ChatGPTTokenResponse.unusableRefreshCodes.contains("refresh_token_reused"))
    }

    private func token(header: [String: Any], claims: [String: Any], sign: (Data) throws -> Data) throws -> String {
        let head = Base64URL.encode(try JSONSerialization.data(withJSONObject: header))
        let body = Base64URL.encode(try JSONSerialization.data(withJSONObject: claims))
        return "\(head).\(body).\(Base64URL.encode(try sign(Data("\(head).\(body)".utf8))))"
    }

    private func claims(clientID: String, nonce: String, expiresIn: TimeInterval = 600) -> [String: Any] {
        ["iss": "https://auth.openai.com", "aud": clientID, "sub": "subject-1", "email": "person@example.org",
         "nonce": nonce, "exp": Date().timeIntervalSince1970 + expiresIn, "iat": Date().timeIntervalSince1970]
    }

    func testIDTokenValidationWithES256() throws {
        let key = P256.Signing.PrivateKey()
        let point = key.publicKey.x963Representation
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "EC", "crv": "P-256", "kid": "k1", "use": "sig", "alg": "ES256",
            "x": Base64URL.encode(point[1..<33]), "y": Base64URL.encode(point[33..<65]),
        ]]])
        let sign: (Data) throws -> Data = { try key.signature(for: $0).rawRepresentation }
        let header: [String: Any] = ["alg": "ES256", "kid": "k1", "typ": "JWT"]
        let valid = try token(header: header, claims: claims(clientID: "oaiapp_1", nonce: "n1"), sign: sign)
        let identity = try ChatGPTIDToken.validate(valid, jwks: jwks, clientID: "oaiapp_1", nonce: "n1")
        XCTAssertEqual(identity, ChatGPTIdentity(subject: "subject-1", email: "person@example.org", name: nil))
        XCTAssertNoThrow(try ChatGPTIDToken.validate(valid, jwks: jwks, clientID: "oaiapp_1", nonce: nil))

        func reason(_ token: String, clientID: String = "oaiapp_1", nonce: String? = "n1") -> ChatGPTSignInError? {
            do { _ = try ChatGPTIDToken.validate(token, jwks: jwks, clientID: clientID, nonce: nonce); return nil } catch { return error as? ChatGPTSignInError }
        }
        XCTAssertEqual(reason(valid, nonce: "other"), .invalidToken("nonce"))
        XCTAssertEqual(reason(valid, clientID: "oaiapp_2"), .invalidToken("audience"))
        XCTAssertEqual(reason(try token(header: header, claims: claims(clientID: "oaiapp_1", nonce: "n1", expiresIn: -600), sign: sign)), .invalidToken("expired"))
        var wrongIssuer = claims(clientID: "oaiapp_1", nonce: "n1")
        wrongIssuer["iss"] = "https://auth.example.org"
        XCTAssertEqual(reason(try token(header: header, claims: wrongIssuer, sign: sign)), .invalidToken("issuer"))
        let parts = valid.split(separator: ".")
        var tampered = claims(clientID: "oaiapp_1", nonce: "n1")
        tampered["sub"] = "someone-else"
        let forged = "\(parts[0]).\(Base64URL.encode(try JSONSerialization.data(withJSONObject: tampered))).\(parts[2])"
        XCTAssertEqual(reason(forged), .invalidToken("signature"))
        XCTAssertEqual(reason(try token(header: ["alg": "none"], claims: claims(clientID: "oaiapp_1", nonce: "n1"), sign: { _ in Data() })), .invalidToken("algorithm"))
        XCTAssertEqual(reason(try token(header: ["alg": "ES256", "kid": "unknown"], claims: claims(clientID: "oaiapp_1", nonce: "n1"), sign: sign)), .invalidToken("key"))
        XCTAssertEqual(reason("not-a-token"), .invalidToken("format"))
    }

    func testIDTokenValidationWithRS256() throws {
        var failure: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2_048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &failure))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, &failure) as Data?)

        // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER exponent }.
        var offset = 0
        func readLength() -> Int {
            let first = Int(der[offset]); offset += 1
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7F) { value = value << 8 | Int(der[offset]); offset += 1 }
            return value
        }
        func readInteger() -> Data {
            XCTAssertEqual(der[offset], 0x02); offset += 1
            let length = readLength()
            defer { offset += length }
            return Data(der[offset..<(offset + length)].drop(while: { $0 == 0 }))
        }
        XCTAssertEqual(der[offset], 0x30); offset += 1
        _ = readLength()
        let modulus = readInteger(), exponent = readInteger()
        XCTAssertEqual(DER.sequence(DER.unsignedInteger(modulus) + DER.unsignedInteger(exponent)), der)

        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [
            ["kty": "RSA", "kid": "other", "n": Base64URL.encode(Data(repeating: 0xAB, count: 256)), "e": "AQAB"],
            ["kty": "RSA", "kid": "r1", "use": "sig", "n": Base64URL.encode(modulus), "e": Base64URL.encode(exponent)],
        ]])
        let sign: (Data) throws -> Data = { input in
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, &error) else {
                throw ChatGPTSignInError.invalidToken("test signing")
            }
            return signature as Data
        }
        let valid = try token(header: ["alg": "RS256", "kid": "r1"], claims: claims(clientID: "oaiapp_1", nonce: "n1"), sign: sign)
        XCTAssertEqual(try ChatGPTIDToken.validate(valid, jwks: jwks, clientID: "oaiapp_1", nonce: "n1").subject, "subject-1")
        let wrongKey = try token(header: ["alg": "RS256", "kid": "other"], claims: claims(clientID: "oaiapp_1", nonce: "n1"), sign: sign)
        XCTAssertThrowsError(try ChatGPTIDToken.validate(wrongKey, jwks: jwks, clientID: "oaiapp_1", nonce: "n1"))
    }

    func testAccountStoreRefreshesAndSignsOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foodmapper-chatgpt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = directory.appendingPathComponent("chatgpt_accounts.json")
        let credentials = MemoryCredentialStore()
        let transport = StubProviderTransport([
            .json(["access_token": "second", "refresh_token": "r2", "token_type": "Bearer", "expires_in": 3_600, "scope": "chatgpt.tokens.use.direct openid"]),
            .json(["error": "refresh_token_reused"], status: 400),
        ])
        let store = ChatGPTAccountStore(recordsURL: records, credentialStore: credentials, transport: transport)
        let hostID = try await store.hostID()
        let sameHostID = try await store.hostID()
        XCTAssertEqual(hostID, sameHostID)

        let response = try ChatGPTTokenResponse(data: Data(#"{"access_token":"first","refresh_token":"r1","id_token":"i1","token_type":"Bearer","expires_in":3600,"scope":"chatgpt.tokens.use.direct openid"}"#.utf8))
        let identity = ChatGPTIdentity(subject: "subject-1", email: "person@example.org", name: nil)
        let start = Date()
        let account = try await store.completeSignIn(response: response, identity: identity, clientID: "oaiapp_1", existingAccountID: nil, now: start)
        XCTAssertTrue(account.planUseGranted)
        XCTAssertFalse(String(decoding: try Data(contentsOf: records), as: UTF8.self).contains("first"), "tokens stay out of the record file")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: records.path)[.posixPermissions] as? Int, 0o600)

        let early = try await store.accessToken(accountID: account.id, now: start.addingTimeInterval(60))
        XCTAssertEqual(early, "first")
        XCTAssertTrue(transport.requests.isEmpty)
        let refreshed = try await store.accessToken(accountID: account.id, now: start.addingTimeInterval(3_500))
        XCTAssertEqual(refreshed, "second")
        let refreshBody = String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(refreshBody.contains("grant_type=refresh_token"))
        XCTAssertTrue(refreshBody.contains("client_id=oaiapp_1"))
        XCTAssertTrue(refreshBody.contains("refresh_token=r1"))

        let reopened = ChatGPTAccountStore(recordsURL: records, credentialStore: credentials, transport: transport)
        let persisted = await reopened.accounts()
        XCTAssertEqual(persisted.map(\.id), [account.id])
        let persistedHostID = try await reopened.hostID()
        XCTAssertEqual(persistedHostID, hostID)

        do {
            _ = try await store.accessToken(accountID: account.id, now: Date().addingTimeInterval(7_200))
            XCTFail("a reused refresh token must fail")
        } catch {
            XCTAssertEqual(error as? ChatGPTSignInError, .refreshRejected("refresh_token_reused"))
        }
        let after = await store.account(id: account.id)
        XCTAssertEqual(after?.isSignedIn, false)
        XCTAssertEqual(after?.clientID, "oaiapp_1", "the registration is kept for the next sign-in")
        XCTAssertEqual(credentials.count, 0)
        do {
            _ = try await store.accessToken(accountID: account.id)
            XCTFail("signed out")
        } catch {
            XCTAssertEqual(error as? ChatGPTSignInError, .notSignedIn)
        }

        let other = ChatGPTIdentity(subject: "subject-2", email: nil, name: nil)
        do {
            _ = try await store.completeSignIn(response: response, identity: other, clientID: "oaiapp_1", existingAccountID: account.id)
            XCTFail("a different identity must not replace a saved account")
        } catch {
            XCTAssertEqual(error as? ChatGPTSignInError, .identityMismatch)
        }
    }

    func testLoopbackListenerDeliversOnlyTheCallback() async throws {
        let listener = LoopbackCallbackListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (_, missing) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/other")!)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
        async let target = listener.waitForCallback(timeout: 10)
        let (page, found) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=abc&state=xyz")!)
        XCTAssertEqual((found as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((found as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Return to FoodMapper"))
        let received = try await target
        XCTAssertEqual(received, "/auth/callback?code=abc&state=xyz")
    }
}
