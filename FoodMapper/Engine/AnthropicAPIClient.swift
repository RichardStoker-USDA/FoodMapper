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

    /// Standard API pricing per million tokens
    var inputPricePerMillion: Double {
        switch self {
        case .haiku3: return 0.25
        case .haiku45: return 1.00
        case .sonnet45: return 3.00
        }
    }
    var outputPricePerMillion: Double {
        switch self {
        case .haiku3: return 1.25
        case .haiku45: return 5.00
        case .sonnet45: return 15.00
        }
    }

    /// Batch API pricing (50% discount)
    var batchInputPricePerMillion: Double { inputPricePerMillion / 2 }
    var batchOutputPricePerMillion: Double { outputPricePerMillion / 2 }
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

    init(modelVersion: ClaudeModelVersion = .haiku3) {
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
            let body = String(data: data, encoding: .utf8) ?? ""
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

            results.append(BatchRequestResult(
                customId: customId,
                resultType: resultType,
                messageText: messageText,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadInputTokens: cacheReadInputTokens,
                cacheCreationInputTokens: cacheCreationInputTokens
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

    /// Validate an API key with a minimal request.
    func validateAPIKey(_ key: String) async throws -> Bool {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [
                ["role": "user", "content": "hi"]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: URL(string: "\(baseURL)/messages")!)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = requestTimeout

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            if httpResponse.statusCode == 401 { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
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
        }
    }
}
