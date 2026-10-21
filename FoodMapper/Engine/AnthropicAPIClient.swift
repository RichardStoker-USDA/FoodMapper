import Foundation
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "anthropic-api")

/// Anthropic API tier based on rate limit headers
enum APITier: Int, Sendable, Codable {
    case unknown = 0
    case tier1 = 1   // 50 RPM
    case tier2 = 2   // 1,000 RPM
    case tier3 = 3   // 2,000 RPM
    case tier4 = 4   // 4,000 RPM

    static func from(requestsPerMinute: Int) -> APITier {
        if requestsPerMinute < 100 { return .tier1 }
        if requestsPerMinute < 1500 { return .tier2 }
        if requestsPerMinute < 3000 { return .tier3 }
        return .tier4
    }

    var maxConcurrentBatches: Int {
        switch self {
        case .unknown, .tier1: return 1
        case .tier2: return 5
        case .tier3: return 10
        case .tier4: return 20
        }
    }

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .tier1: return "Tier 1 (50 RPM)"
        case .tier2: return "Tier 2 (1,000 RPM)"
        case .tier3: return "Tier 3 (2,000 RPM)"
        case .tier4: return "Tier 4 (4,000 RPM)"
        }
    }
}

// MARK: - Batch Status

/// Status of a Message Batches API batch
struct BatchStatus: Sendable {
    let batchId: String
    let processingStatus: String  // "in_progress", "canceling", "ended"
    let requestCounts: RequestCounts

    struct RequestCounts: Sendable {
        let processing: Int
        let succeeded: Int
        let errored: Int
        let canceled: Int
        let expired: Int
    }

    var isComplete: Bool { processingStatus == "ended" }
    var totalProcessed: Int { requestCounts.succeeded + requestCounts.errored + requestCounts.canceled + requestCounts.expired }
    var total: Int { totalProcessed + requestCounts.processing }
}

/// Result from a single request within a batch
struct BatchRequestResult: Sendable {
    let customId: String
    let resultType: String  // "succeeded", "errored", "canceled", "expired"
    let messageText: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    /// Anthropic error type and message for an errored request, such as "not_found_error".
    var errorType: String? = nil
    var errorMessage: String? = nil
}

/// Result from a Haiku reranking call (kept for single-query mode)
struct HaikuRankResult: Sendable {
    let bestMatchIndex: Int?
    let confidence: String
    let reasoning: String
    let inputTokens: Int
    let outputTokens: Int
}

/// Claude model version for LLM verification step
enum ClaudeModelVersion: String, CaseIterable, Identifiable, Codable {
    case haiku3 = "claude-3-haiku-20240307"
    case haiku45 = "claude-haiku-4-5-20251001"
    case sonnet45 = "claude-sonnet-4-5-20250929"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .haiku3: return "Claude 3 Haiku"
        case .haiku45: return "Claude Haiku 4.5"
        case .sonnet45: return "Claude Sonnet 4.5"
        }
    }

    var shortName: String {
        switch self {
        case .haiku3: return "Haiku 3"
        case .haiku45: return "Haiku 4.5"
        case .sonnet45: return "Sonnet 4.5"
        }
    }

    /// Whether this is the model used in the published paper
    var isPaperModel: Bool { self == .haiku3 }

    /// Anthropic's retirement date for the Claude API, from
    /// https://platform.claude.com/docs/en/about-claude/model-deprecations (checked 2026-10-20).
    /// Requests to a retired model fail. Update this table when Anthropic announces a retirement.
    var retirementDate: Date? {
        switch self {
        case .haiku3: return Self.utcDay(year: 2026, month: 4, day: 20)
        case .haiku45: return nil
        case .sonnet45: return Self.utcDay(year: 2026, month: 11, day: 30)
        }
    }

    func isRetired(asOf date: Date = Date()) -> Bool {
        guard let retirementDate else { return false }
        return date >= retirementDate
    }

    /// Picker label that shows a retired or scheduled retirement state.
    func pickerLabel(asOf date: Date = Date()) -> String {
        guard let retirementDate else { return displayName }
        if isRetired(asOf: date) {
            return "\(displayName) (retired)"
        }
        return "\(displayName) (retires \(Self.formatted(retirementDate, style: .short)))"
    }

    /// Why this model can't run, or nil when Anthropic still serves it.
    func unavailableReason(asOf date: Date = Date()) -> String? {
        guard isRetired(asOf: date), let retirementDate else { return nil }
        return "Anthropic retired \(displayName) (\(rawValue)) on \(Self.formatted(retirementDate, style: .long))."
    }

    /// Scheduled retirement for a model that still runs, or nil.
    func upcomingRetirementNote(asOf date: Date = Date()) -> String? {
        guard !isRetired(asOf: date), let retirementDate else { return nil }
        return "Anthropic retires this model on \(Self.formatted(retirementDate, style: .long))."
    }

    private enum DateStyle { case short, long }

    private static func utcDay(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static func formatted(_ date: Date, style: DateStyle) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = style == .short ? "MMM d, yyyy" : "MMMM d, yyyy"
        return formatter.string(from: date)
    }
}

/// HTTP client for Anthropic Messages API + Message Batches API.
/// Each batch request is processed independently, matching the paper's 1-on-1 methodology.
actor AnthropicAPIClient {
    private let baseURL = "https://api.anthropic.com/v1"
    private let apiVersion = "2023-06-01"
    let modelVersion: ClaudeModelVersion
    private var model: String { modelVersion.rawValue }
    private let maxRetries = 3
    private let requestTimeout: TimeInterval = 30
    private let pollInterval: TimeInterval = 15

    private var isCancelled = false
    private var activeBatchId: String?
    private(set) var detectedTier: APITier = .unknown

    init(modelVersion: ClaudeModelVersion) {
        self.modelVersion = modelVersion
    }

    // MARK: - Message Batches API

    /// Submit tasks to the Message Batches API. Returns batch ID for polling.
    /// Prompt construction lives in HaikuPromptBuilder, not here.
    func submitBatch(
        tasks: [(customId: String, userMessage: String)],
        systemPrompt: String,
        apiKey: String,
        temperature: Double = 0,
        maxTokens: Int = 100,
        usePromptCaching: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        guard !isCancelled else { throw HaikuError.cancelled }
        guard !tasks.isEmpty else { throw HaikuError.invalidResponse }
        // A run can start before a retirement date and reach submission after it.
        // Check again here so no input leaves the Mac for a retired model.
        guard !modelVersion.isRetired() else { throw HaikuError.modelUnavailable(modelVersion) }

        // System field: plain string or array-with-cache-control for prompt caching
        let systemField: Any
        if usePromptCaching {
            systemField = [
                ["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral", "ttl": "1h"]]
            ]
        } else {
            systemField = systemPrompt
        }

        // Build the requests array for the Batches API
        var requests: [[String: Any]] = []
        for task in tasks {
            let requestEntry: [String: Any] = [
                "custom_id": task.customId,
                "params": [
                    "model": model,
                    "max_tokens": maxTokens,
                    "temperature": temperature,
                    "system": systemField,
                    "messages": [
                        ["role": "user", "content": task.userMessage]
                    ]
                ] as [String: Any]
            ]
            requests.append(requestEntry)
        }

        let body: [String: Any] = ["requests": requests]
        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "\(baseURL)/messages/batches")!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60  // Submission may take a moment for large batches

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HaikuError.invalidResponse
        }

        detectTier(from: httpResponse)

        switch httpResponse.statusCode {
        case 200:
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let batchId = json["id"] as? String else {
                throw HaikuError.invalidResponse
            }
            activeBatchId = batchId
            logger.info("Batch submitted: \(batchId) (\(tasks.count) tasks)")
            return batchId

        case 401:
            throw HaikuError.invalidAPIKey
        case 429:
            throw HaikuError.rateLimited
        case 500, 502, 503:
            throw HaikuError.serverError(httpResponse.statusCode)
        default:
            let detail = Self.apiErrorDetail(from: data)
            if httpResponse.statusCode == 404, detail?.type == "not_found_error" {
                throw HaikuError.modelUnavailable(modelVersion)
            }
            let body = detail?.message ?? String(data: data, encoding: .utf8) ?? ""
            throw HaikuError.unexpectedStatus(httpResponse.statusCode, body)
        }
    }

    /// Poll batch status until complete or cancelled.
    /// Calls onStatusUpdate with each poll result.
    /// Calls onPollError when a transient error occurs (for UI "Reconnecting..." state).
    func pollBatchStatus(
        batchId: String,
        apiKey: String,
        onStatusUpdate: @Sendable (BatchStatus) -> Void,
        onPollError: (@Sendable () -> Void)? = nil
    ) async throws -> BatchStatus {
        while true {
            try Task.checkCancellation()
            guard !isCancelled else { throw HaikuError.cancelled }

            var request = URLRequest(url: URL(string: "\(baseURL)/messages/batches/\(batchId)")!)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = requestTimeout

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    logger.error("Batch status poll failed: HTTP \(code)")
                    onPollError?()
                    try await Task.sleep(for: .seconds(pollInterval))
                    continue
                }

                let status = try parseBatchStatus(data, batchId: batchId)
                onStatusUpdate(status)

                if status.isComplete {
                    logger.info("Batch \(batchId) complete: \(status.requestCounts.succeeded) succeeded, \(status.requestCounts.errored) errored, \(status.requestCounts.canceled) canceled")
                    return status
                }

                logger.debug("Batch \(batchId): \(status.requestCounts.succeeded)/\(status.total) processed")
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HaikuError {
                throw error
            } catch {
                // Network errors during polling -- surface as reconnecting
                logger.error("Batch poll network error: \(error.localizedDescription)")
                onPollError?()
            }

            try await Task.sleep(for: .seconds(pollInterval))
        }
    }

    /// Fetch results for a completed batch. Returns JSONL parsed into individual results.
    func fetchBatchResults(
        batchId: String,
        apiKey: String
    ) async throws -> [BatchRequestResult] {
        try Task.checkCancellation()
        guard !isCancelled else { throw HaikuError.cancelled }

        var request = URLRequest(url: URL(string: "\(baseURL)/messages/batches/\(batchId)/results")!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120  // Results can be large

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw HaikuError.unexpectedStatus(code, "Failed to fetch batch results")
        }

        // Response is JSONL (one JSON object per line)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HaikuError.invalidResponse
        }

        var results: [BatchRequestResult] = []
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                logger.warning("Failed to parse JSONL line: \(trimmed.prefix(100))")
                continue
            }

            let customId = json["custom_id"] as? String ?? ""
            let result = json["result"] as? [String: Any]
            let resultType = result?["type"] as? String ?? "errored"

            var messageText: String?
            var errorType: String?
            var errorMessage: String?
            var inputTokens = 0
            var outputTokens = 0
            var cacheReadInputTokens = 0
            var cacheCreationInputTokens = 0

            if resultType == "succeeded", let message = result?["message"] as? [String: Any] {
                // Extract text from content blocks
                if let content = message["content"] as? [[String: Any]],
                   let firstBlock = content.first,
                   let text = firstBlock["text"] as? String {
                    messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Extract token usage
                if let usage = message["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                    outputTokens = usage["output_tokens"] as? Int ?? 0
                    cacheReadInputTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                    cacheCreationInputTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
                }
            }

            if resultType == "errored", let errorObject = result?["error"] as? [String: Any] {
                let detail = Self.apiErrorDetail(from: errorObject)
                errorType = detail?.type
                errorMessage = detail?.message
            }

            results.append(BatchRequestResult(
                customId: customId,
                resultType: resultType,
                messageText: messageText,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadInputTokens: cacheReadInputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens,
                errorType: errorType,
                errorMessage: errorMessage
            ))
        }

        logger.info("Fetched \(results.count) batch results for \(batchId)")
        return results
    }

    /// Cancel a batch in progress.
    func cancelBatch(
        batchId: String,
        apiKey: String
    ) async throws {
        var request = URLRequest(url: URL(string: "\(baseURL)/messages/batches/\(batchId)/cancel")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = requestTimeout

        let (_, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            logger.info("Batch cancel request: HTTP \(httpResponse.statusCode) for \(batchId)")
        }
    }

    // MARK: - Tier Detection

    func getDetectedTier() -> APITier {
        detectedTier
    }

    private func detectTier(from response: HTTPURLResponse) {
        guard detectedTier == .unknown else { return }

        if let limitStr = response.value(forHTTPHeaderField: "anthropic-ratelimit-requests-limit"),
           let limit = Int(limitStr) {
            detectedTier = APITier.from(requestsPerMinute: limit)
            logger.info("Detected API tier: \(self.detectedTier.displayName) (limit: \(limit) RPM)")
        }
    }

    // MARK: - Validation

    /// Check an API key by listing models. This depends on no model ID and uses no tokens.
    /// Returns false only for an authentication failure (401). A permission error (403),
    /// rate limit, server error, or network failure throws, so callers keep the stored key.
    static func validateAPIKey(_ key: String) async throws -> Bool {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HaikuError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200:
            return true
        case 401:
            return false
        case 429:
            throw HaikuError.rateLimited
        case 500...599:
            throw HaikuError.serverError(httpResponse.statusCode)
        default:
            let body = apiErrorDetail(from: data)?.message ?? ""
            throw HaikuError.unexpectedStatus(httpResponse.statusCode, body)
        }
    }

    // MARK: - Error Detail

    /// Reads Anthropic's error body: {"type":"error","error":{"type":"...","message":"..."}}.
    static func apiErrorDetail(from data: Data) -> (type: String, message: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return apiErrorDetail(from: json)
    }

    /// Accepts either the outer error envelope or the inner error object.
    static func apiErrorDetail(from json: [String: Any]) -> (type: String, message: String)? {
        if let inner = json["error"] as? [String: Any] {
            return apiErrorDetail(from: inner)
        }
        guard let type = json["type"] as? String, type != "error" else { return nil }
        return (type, json["message"] as? String ?? "")
    }

    /// A batch that returned no successful response cannot stand in for a Claude run.
    /// Returns the error to raise, or nil when at least one request succeeded.
    static func batchFailure(
        for results: [BatchRequestResult],
        model: ClaudeModelVersion
    ) -> HaikuError? {
        guard !results.contains(where: { $0.resultType == "succeeded" }) else { return nil }
        let errored = results.filter { $0.resultType == "errored" }
        guard !errored.isEmpty else { return nil }
        if errored.contains(where: { $0.errorType == "not_found_error" }) {
            return .modelUnavailable(model)
        }
        let detail = errored.lazy.compactMap { $0.errorMessage }.first(where: { !$0.isEmpty })
        return .allRequestsFailed(detail ?? "Anthropic returned no successful responses.")
    }

    // MARK: - Cancellation

    func cancel() {
        isCancelled = true
    }

    func resetCancellation() {
        isCancelled = false
    }

    /// Get the active batch ID (for cancellation from pipeline)
    func getActiveBatchId() -> String? {
        activeBatchId
    }

    // MARK: - Parsing

    private func parseBatchStatus(_ data: Data, batchId: String) throws -> BatchStatus {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HaikuError.invalidResponse
        }

        let processingStatus = json["processing_status"] as? String ?? "in_progress"
        let counts = json["request_counts"] as? [String: Any] ?? [:]

        return BatchStatus(
            batchId: batchId,
            processingStatus: processingStatus,
            requestCounts: BatchStatus.RequestCounts(
                processing: counts["processing"] as? Int ?? 0,
                succeeded: counts["succeeded"] as? Int ?? 0,
                errored: counts["errored"] as? Int ?? 0,
                canceled: counts["canceled"] as? Int ?? 0,
                expired: counts["expired"] as? Int ?? 0
            )
        )
    }
}

// MARK: - Errors

enum HaikuError: LocalizedError {
    case invalidAPIKey
    case rateLimited
    case serverError(Int)
    case unexpectedStatus(Int, String)
    case invalidResponse
    case cancelled
    case modelUnavailable(ClaudeModelVersion)
    case allRequestsFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid Anthropic API key. Check Settings > API Keys."
        case .rateLimited:
            return "Anthropic API rate limited. Wait a moment and try again."
        case .serverError(let code):
            return "Anthropic API server error (HTTP \(code))"
        case .unexpectedStatus(let code, let body):
            return "Unexpected API response (HTTP \(code)): \(body.prefix(200))"
        case .invalidResponse:
            return "Invalid response from Anthropic API"
        case .cancelled:
            return "API request cancelled"
        case .modelUnavailable(let model):
            let reason = model.unavailableReason() ?? "Anthropic no longer serves \(model.displayName) (\(model.rawValue))."
            return "\(reason) No Claude results were produced."
        case .allRequestsFailed(let detail):
            return "Anthropic returned an error for every item, so no Claude results were produced: \(detail)"
        }
    }
}
