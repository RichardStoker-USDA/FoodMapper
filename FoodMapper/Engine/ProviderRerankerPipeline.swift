import CryptoKit
import Foundation
import os

private let providerPipelineLogger = Logger(subsystem: "com.foodmapper", category: "provider-pipeline")

/// Supplies the bearer credential for each request. An API key is constant; a
/// ChatGPT plan token is refreshed when it nears expiry during a long run.
typealias ProviderCredentialSource = @Sendable () async throws -> String?

/// What happened in the provider stage of one run.
struct ProviderRunSummary: Equatable, Sendable {
    var decided = 0
    var reviewFallbacks = 0
    var retries = 0
    var haltReason: ProviderHaltReason?
    var usage = ProviderTokenUsage()
    var decisionSeconds: TimeInterval = 0
}

/// Shared state for the workers of one run.
actor ProviderRunCoordinator {
    private(set) var haltReason: ProviderHaltReason?
    private(set) var usage = ProviderTokenUsage()
    private(set) var retries = 0
    private var resumeAt: Date?

    func halt(_ reason: ProviderHaltReason) {
        if haltReason == nil { haltReason = reason }
    }

    func add(_ value: ProviderTokenUsage?) {
        if let value { usage = usage + value }
    }

    /// Records a retry and makes every worker wait until the provider can take requests again.
    func noteRetry(resumeAfter delay: TimeInterval, now: Date = Date()) {
        retries += 1
        let candidate = now.addingTimeInterval(delay)
        if resumeAt.map({ candidate > $0 }) ?? true { resumeAt = candidate }
    }

    func backoffDelay(now: Date = Date()) -> TimeInterval {
        max(0, resumeAt?.timeIntervalSince(now) ?? 0)
    }
}

/// GTE-Large retrieval followed by candidate selection from a configured provider.
final class ProviderRerankerPipeline: MatchingPipelineProtocol, @unchecked Sendable {
    let pipelineType: PipelineType = .providerLLM
    var name: String { pipelineType.displayName }

    private let engine: MatchingEngine
    private let profile: ProviderProfile
    private let credentialSource: ProviderCredentialSource
    private let topK: Int
    private let authorizationGate: AdvancedFeatureGate
    private let authorizationLease: AdvancedFeatureLease
    private let transportOverride: ProviderTransport?
    private let summaryLock = NSLock()
    private var storedSummary: ProviderRunSummary?

    /// Set when `match` returns.
    var runSummary: ProviderRunSummary? {
        summaryLock.withLock { storedSummary }
    }

    init(
        engine: MatchingEngine,
        profile: ProviderProfile,
        credential: String?,
        topK: Int,
        authorizationGate: AdvancedFeatureGate,
        authorizationLease: AdvancedFeatureLease,
        credentialSource: ProviderCredentialSource? = nil,
        transport: ProviderTransport? = nil
    ) {
        self.engine = engine
        self.profile = profile
        self.credentialSource = credentialSource ?? { credential }
        self.topK = min(max(1, topK), AdvancedRunLimits.maximum.candidateCount)
        self.authorizationGate = authorizationGate
        self.authorizationLease = authorizationLease
        self.transportOverride = transport
    }

    func match(
        inputs: [String],
        database: AnyDatabase,
        threshold: Double,
        hardwareConfig: HardwareConfig,
        instruction: String?,
        rerankerInstruction: String?,
        onProgress: @Sendable @escaping (Int) -> Void,
        onPhaseChange: (@Sendable (MatchingPhase) -> Void)?
    ) async throws -> [MatchResult] {
        guard inputs.count <= AdvancedRunLimits.defaults.inputRows else { throw ProviderPipelineError.tooManyInputs }
        try authorizationGate.validate(authorizationLease)
        let checkedProfile = try profile.validated()

        await engine.setInstruction(instruction)
        try authorizationGate.validate(authorizationLease)
        onPhaseChange?(.loadingDatabase)
        let candidatesByInput = try await engine.matchTopK(
            inputs: inputs,
            database: database,
            k: topK,
            batchSize: hardwareConfig.matchingBatchSize,
            embeddingBatchSize: hardwareConfig.embeddingBatchSize,
            chunkSize: hardwareConfig.chunkSize,
            onProgress: { completed in
                onProgress(Int(Double(completed) * 0.55))
            },
            onEmbedProgress: { completed, total in
                onPhaseChange?(.embeddingDatabase(completed: completed, total: total))
            }
        )
        try authorizationGate.validate(authorizationLease)

        let total = inputs.count
        let workerCount = min(checkedProfile.concurrency, max(total, 1))
        let transport: ProviderTransport = transportOverride
            ?? URLSessionProviderTransport(maximumConnections: workerCount)
        defer {
            if transportOverride == nil { (transport as? URLSessionProviderTransport)?.invalidate() }
        }
        let coordinator = ProviderRunCoordinator()
        let credentialSource = self.credentialSource
        let started = Date()
        var decisions = [Result<ProviderDecision, Error>?](repeating: nil, count: total)
        var completed = 0
        onPhaseChange?(.reranking(completed: 0, total: total))

        try await withThrowingTaskGroup(of: (Int, Result<ProviderDecision, Error>).self) { group in
            var next = 0
            var running = 0

            func startAvailable() {
                while running < workerCount, next < total {
                    let index = next
                    next += 1
                    let candidates = candidatesByInput[index].map(\.entry.text)
                    guard !candidates.isEmpty else {
                        // No candidates: nothing to send. Resolved when results are built.
                        completed += 1
                        continue
                    }
                    let input = inputs[index]
                    running += 1
                    group.addTask {
                        do {
                            let decision = try await Self.decideWithRetry(
                                input: input, candidates: candidates, instruction: rerankerInstruction,
                                profile: checkedProfile, credentialSource: credentialSource,
                                transport: transport, coordinator: coordinator
                            )
                            return (index, .success(decision))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
            }

            startAvailable()
            while let (index, result) = try await group.next() {
                running -= 1
                decisions[index] = result
                completed += 1
                try Task.checkCancellation()
                try authorizationGate.validate(authorizationLease)
                onProgress(Int(0.55 * Double(total)) + Int(0.45 * Double(completed)))
                onPhaseChange?(.reranking(completed: completed, total: total))
                startAvailable()
            }
        }
        try authorizationGate.validate(authorizationLease)

        var summary = ProviderRunSummary()
        summary.haltReason = await coordinator.haltReason
        summary.usage = await coordinator.usage
        summary.retries = await coordinator.retries
        summary.decisionSeconds = Date().timeIntervalSince(started)
        let fallbackNote = summary.haltReason?.message ?? "Provider decision unavailable; review this row."

        var results: [MatchResult] = []
        results.reserveCapacity(total)
        for (index, candidates) in candidatesByInput.enumerated() {
            guard !candidates.isEmpty else {
                results.append(MatchResult(
                    inputText: inputs[index], inputRow: index, score: 0, status: .noMatch, scoreType: .noScore
                ))
                continue
            }
            let resultCandidates = candidates.map { candidate in
                MatchCandidate(
                    matchText: candidate.entry.text,
                    matchID: candidate.entry.id,
                    score: Double(candidate.score),
                    additionalFields: candidate.entry.additionalFields,
                    targetRowKey: candidate.entry.targetRowKey
                )
            }

            if case let .success(decision)? = decisions[index] {
                summary.decided += 1
                if let selection = decision.selection, candidates.indices.contains(selection) {
                    let candidate = candidates[selection]
                    results.append(MatchResult(
                        inputText: inputs[index],
                        inputRow: index,
                        matchText: candidate.entry.text,
                        matchID: candidate.entry.id,
                        score: Double(candidate.score),
                        status: .llmMatch,
                        scoreType: .llmSelected,
                        llmReasoning: Self.note(for: decision),
                        matchAdditionalFields: candidate.entry.additionalFields,
                        candidates: resultCandidates,
                        targetRowKey: candidate.entry.targetRowKey
                    ))
                } else {
                    results.append(MatchResult(
                        inputText: inputs[index],
                        inputRow: index,
                        score: 0,
                        status: .noMatch,
                        scoreType: .llmRejected,
                        llmReasoning: Self.note(for: decision),
                        candidates: resultCandidates
                    ))
                }
            } else {
                summary.reviewFallbacks += 1
                let candidate = candidates[0]
                results.append(MatchResult(
                    inputText: inputs[index],
                    inputRow: index,
                    matchText: candidate.entry.text,
                    matchID: candidate.entry.id,
                    score: Double(candidate.score),
                    status: .match,
                    scoreType: .apiFallback,
                    llmReasoning: fallbackNote,
                    matchAdditionalFields: candidate.entry.additionalFields,
                    candidates: resultCandidates,
                    targetRowKey: candidate.entry.targetRowKey
                ))
            }
        }

        let finalSummary = summary
        summaryLock.withLock { storedSummary = finalSummary }
        providerPipelineLogger.info(
            "Provider candidate selection completed for \(total) inputs with \(summary.reviewFallbacks) review fallbacks and \(summary.retries) retries"
        )
        return results
    }

    func cancel() async {
        await engine.cancel()
    }

    /// The Decisions route reports how sure the model was. The value is recorded
    /// for review and is not a calibrated probability.
    private static func note(for decision: ProviderDecision) -> String? {
        guard let confidence = decision.confidence else { return nil }
        return "Provider-reported confidence \(String(format: "%.2f", confidence)), not calibrated."
    }

    /// One row: waits out any shared backoff, sends the request, and retries a
    /// transient failure up to the policy's limit. A halt failure stops the run.
    static func decideWithRetry(
        input: String,
        candidates: [String],
        instruction: String?,
        profile: ProviderProfile,
        credentialSource: ProviderCredentialSource,
        transport: ProviderTransport,
        coordinator: ProviderRunCoordinator
    ) async throws -> ProviderDecision {
        let payload = try ProviderDecisionPayload(input: input, candidates: candidates, instruction: instruction)
        var attempt = 1
        while true {
            try Task.checkCancellation()
            if await coordinator.haltReason != nil { throw ProviderFailure.row(status: nil) }
            let wait = await coordinator.backoffDelay()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

            do {
                let credential: String?
                do {
                    credential = try await credentialSource()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ProviderFailure.halt(.signInRequired)
                }
                let decision = try await ProviderDecisionClient.decide(
                    payload: payload, profile: profile, credential: credential, transport: transport
                )
                await coordinator.add(decision.usage)
                return decision
            } catch let failure as ProviderFailure {
                switch failure {
                case let .halt(reason):
                    await coordinator.halt(reason)
                    throw failure
                case let .retry(after, _):
                    guard attempt < ProviderRetryPolicy.maximumAttempts else { throw failure }
                    await coordinator.noteRetry(resumeAfter: ProviderRetryPolicy.delay(attempt: attempt, hint: after))
                    attempt += 1
                case .row:
                    throw failure
                }
            } catch let error as URLError where Self.transientNetworkCodes.contains(error.code) {
                guard attempt < ProviderRetryPolicy.maximumAttempts else { throw error }
                await coordinator.noteRetry(resumeAfter: ProviderRetryPolicy.delay(attempt: attempt, hint: nil))
                attempt += 1
            }
        }
    }

    private static let transientNetworkCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
    ]
}

enum ProviderDecisionClient {
    private static let maximumRequestBytes = 16 * 1_024
    private static let maximumResponseBytes = 64 * 1_024
    private static let maximumStreamBytes = 512 * 1_024
    private static let maximumDecisionBytes = 16 * 1_024

    /// Sends one decision request on the profile's route and returns the validated decision.
    ///
    /// Throws `ProviderFailure` for a provider-side failure and `ProviderPipelineError`
    /// when the request or response breaks FoodMapper's own limits.
    static func decide(
        payload: ProviderDecisionPayload,
        profile: ProviderProfile,
        credential: String?,
        transport: ProviderTransport
    ) async throws -> ProviderDecision {
        let checked = try profile.validated()
        var endpoint = try ProviderEndpointPolicy.canonicalURL(kind: checked.kind, value: checked.baseURL)
        for component in checked.interface.pathComponents {
            endpoint.appendPathComponent(component)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = checked.interface == .responses ? 90 : 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            checked.interface == .responses ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        if let credential, !credential.isEmpty {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }

        switch checked.interface {
        case .chatCompletions:
            request.httpBody = try ProviderChatRequest.data(
                profile: checked,
                messages: [
                    ["role": "system", "content": OpenAIResponsesRequest.decisionInstructions],
                    ["role": "user", "content": try payload.jsonText()],
                ],
                maxTokens: min(checked.maximumOutputTokens, 128),
                candidateIDs: payload.candidateIDs
            )
        case .responses:
            request.httpBody = try OpenAIResponsesRequest.data(
                model: checked.model, payload: payload, effort: checked.reasoningEffort, billing: checked.kind.billing
            )
        case .decisions:
            request.httpBody = try OpenAIDecisionsRequest.data(model: checked.model, payload: payload)
        }
        guard request.httpBody?.count ?? 0 <= maximumRequestBytes else {
            throw ProviderPipelineError.requestTooLarge
        }

        switch checked.interface {
        case .chatCompletions:
            let data = try await sendJSON(request, transport: transport)
            let content = try ProviderResponseParser.messageContent(from: data)
            guard content.lengthOfBytes(using: .utf8) <= maximumDecisionBytes else {
                throw ProviderPipelineError.responseTooLarge
            }
            return ProviderDecision(
                selection: try ProviderResponseParser.selection(content: content, candidateIDs: payload.candidateIDs),
                usage: Self.chatUsage(in: data)
            )
        case .decisions:
            let data = try await sendJSON(request, transport: transport)
            return try OpenAIDecisionsParser.decision(from: data, candidateIDs: payload.candidateIDs)
        case .responses:
            return try await streamDecision(request, candidateIDs: payload.candidateIDs, transport: transport)
        }
    }

    /// The earlier single-request entry point, kept for the connection test.
    static func selectCandidate(
        input: String,
        candidates: [String],
        instruction: String?,
        profile: ProviderProfile,
        credential: String?,
        transport: ProviderTransport = URLSessionProviderTransport()
    ) async throws -> Int? {
        let payload = try ProviderDecisionPayload(input: input, candidates: candidates, instruction: instruction)
        defer { (transport as? URLSessionProviderTransport)?.invalidate() }
        return try await decide(payload: payload, profile: profile, credential: credential, transport: transport).selection
    }

    private static func sendJSON(_ request: URLRequest, transport: ProviderTransport) async throws -> Data {
        let (data, response) = try await transport.send(request, maximumBytes: maximumResponseBytes)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw failure(for: response, body: data)
        }
        return data
    }

    private static func streamDecision(
        _ request: URLRequest, candidateIDs: [String], transport: ProviderTransport
    ) async throws -> ProviderDecision {
        var reducer = ResponsesStreamReducer()
        let (response, errorBody) = try await transport.readLines(
            request,
            maximumBytes: maximumStreamBytes,
            onResponse: { (200..<300).contains($0.statusCode) },
            onLine: { line in
                try reducer.consume(line: line)
                return reducer.outcome == nil
            }
        )
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw failure(for: response, body: errorBody)
        }
        switch reducer.outcome {
        case .completed:
            guard let text = reducer.completedText else { throw ProviderPipelineError.invalidResponse }
            return ProviderDecision(
                selection: try ProviderResponseParser.selection(content: text, candidateIDs: candidateIDs),
                usage: reducer.usage
            )
        case let .failed(code, _):
            throw ProviderErrorClassifier.classify(status: nil, code: code)
        case .incomplete:
            throw ProviderFailure.row(status: nil)
        case nil:
            // The stream ended before a terminal event.
            throw ProviderFailure.retry(after: nil, status: nil)
        }
    }

    private static func failure(for response: HTTPURLResponse, body: Data) -> ProviderFailure {
        let fields = ProviderErrorClassifier.errorFields(in: body)
        return ProviderErrorClassifier.classify(
            status: response.statusCode,
            code: fields.code,
            parameter: fields.parameter,
            retryAfter: ProviderErrorClassifier.retryAfter(from: response)
        )
    }

    private static func chatUsage(in data: Data) -> ProviderTokenUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let completionDetails = usage["completion_tokens_details"] as? [String: Any]
        return ProviderTokenUsage(
            inputTokens: (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0,
            cachedInputTokens: (promptDetails?["cached_tokens"] as? NSNumber)?.intValue ?? 0,
            outputTokens: (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0,
            reasoningTokens: (completionDetails?["reasoning_tokens"] as? NSNumber)?.intValue ?? 0
        )
    }
}

enum ProviderChatRequest {
    static func data(
        profile: ProviderProfile,
        messages: [[String: String]],
        maxTokens: Int,
        candidateIDs: [String]
    ) throws -> Data {
        let checked = try profile.validated()
        let responseSchema = responseSchema(candidateIDs: candidateIDs)
        let body: [String: Any] = [
            "model": checked.model,
            "messages": messages,
            "stream": false,
            "max_tokens": min(max(32, maxTokens), 128),
            "response_format": responseSchema
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func schemaHash(candidateIDs: [String]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: responseSchema(candidateIDs: candidateIDs),
            options: [.sortedKeys]
        )
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func responseSchema(candidateIDs: [String]) -> [String: Any] {
        let identifierValues: [Any] = candidateIDs + [NSNull()]
        return [
            "type": "json_schema",
            "json_schema": [
                "name": "foodmapper_candidate_decision",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "decision": ["type": "string", "enum": ["select", "abstain"]],
                        "candidate_id": ["type": ["string", "null"], "enum": identifierValues]
                    ],
                    "required": ["decision", "candidate_id"],
                    "additionalProperties": false
                ]
            ]
        ]
    }
}

enum ProviderResponseParser {
    static func messageContent(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [Any],
              choices.count == 1,
              let choice = choices[0] as? [String: Any],
              let message = choice["message"] as? [String: Any],
              message["tool_calls"] == nil || message["tool_calls"] is NSNull,
              message["function_call"] == nil || message["function_call"] is NSNull,
              message["refusal"] == nil || message["refusal"] is NSNull,
              let content = message["content"] as? String else {
            throw ProviderPipelineError.invalidResponse
        }
        return content
    }

    static func selection(content: String, candidateIDs: [String]) throws -> Int? {
        guard let data = content.data(using: .utf8),
              exactKeyCount("decision", in: content) == 1,
              exactKeyCount("candidate_id", in: content) == 1,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["decision", "candidate_id"],
              let decision = object["decision"] as? String else {
            throw ProviderPipelineError.invalidResponse
        }

        switch decision {
        case "abstain":
            guard object["candidate_id"] is NSNull else {
                throw ProviderPipelineError.invalidResponse
            }
            return nil
        case "select":
            guard let candidateID = object["candidate_id"] as? String,
                  let index = candidateIDs.firstIndex(of: candidateID) else {
                throw ProviderPipelineError.invalidResponse
            }
            return index
        default:
            throw ProviderPipelineError.invalidResponse
        }
    }

    private static func exactKeyCount(_ key: String, in content: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:") else { return 0 }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return expression.numberOfMatches(in: content, range: range)
    }
}

enum ProviderPipelineError: LocalizedError {
    case tooManyInputs
    case fieldLimitExceeded
    case requestTooLarge
    case responseTooLarge
    case redirectNotAllowed
    case requestFailed(Int?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .tooManyInputs:
            return "Provider-assisted runs are limited to \(AdvancedRunLimits.defaults.inputRows) input rows."
        case .fieldLimitExceeded:
            return "A provider input, context, or candidate exceeds the evaluation limit."
        case .requestTooLarge:
            return "The provider request exceeds the 16 KB limit."
        case .responseTooLarge:
            return "The provider response exceeds the 64 KB limit."
        case .redirectNotAllowed:
            return "The provider tried to redirect the request."
        case let .requestFailed(status):
            return status.map { "The provider returned HTTP \($0)." } ?? "The provider request failed."
        case .invalidResponse:
            return "The provider response did not contain one valid candidate decision."
        }
    }
}
