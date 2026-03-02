import Foundation
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "haiku-pipeline")

/// GTE-Large embedding retrieval + Claude Haiku API verification.
/// Stage 1: GTE-Large top-K cosine similarity.
/// Stage 2: Anthropic Batches API (1-on-1, 50% cheaper than standard).
/// Paper validation pipeline -- replicates the published methodology.
final class HaikuRerankerPipeline: MatchingPipelineProtocol {
    let pipelineType: PipelineType = .gteLargeHaiku
    var name: String { pipelineType.displayName }

    private let engine: MatchingEngine
    private let apiClient: AnthropicAPIClient
    private let apiKey: String
    /// Number of top embedding candidates to send to Haiku per input
    private let topK: Int
    /// Minimum embedding cosine similarity to send a candidate to Haiku.
    /// Candidates below this floor are filtered out before the API call.
    private let embeddingScoreFloor: Double
    /// Which Haiku model version to use
    let modelVersion: ClaudeModelVersion
    /// Prompt strategy: paper replication (free-text) vs production (numbered)
    let promptStrategy: HaikuPromptStrategy

    /// Accumulated API token usage for the session
    private(set) var totalInputTokens: Int = 0
    private(set) var totalOutputTokens: Int = 0

    /// Task info for building batch requests
    private struct TaskInfo {
        let originalIndex: Int
        let query: String
        let candidateTexts: [String]
        let rawCandidates: [MatchingEngine.TopKCandidate]
    }

    init(
        engine: MatchingEngine,
        apiClient: AnthropicAPIClient,
        apiKey: String,
        topK: Int = 20,
        embeddingScoreFloor: Double = 0.50,
        modelVersion: ClaudeModelVersion = .haiku45,
        promptStrategy: HaikuPromptStrategy = .production
    ) {
        self.engine = engine
        self.apiClient = apiClient
        self.apiKey = apiKey
        self.topK = topK
        self.embeddingScoreFloor = embeddingScoreFloor
        self.modelVersion = modelVersion
        self.promptStrategy = promptStrategy
    }

    /// Get detected tier from the API client (after at least one request)
    func getDetectedTier() async -> APITier {
        await apiClient.getDetectedTier()
    }

    func match(
        inputs: [String],
        database: AnyDatabase,
        threshold: Double,
        hardwareConfig: HardwareConfig,
        instruction: String?,
        rerankerInstruction: String? = nil,
        onProgress: @Sendable @escaping (Int) -> Void,
        onPhaseChange: (@Sendable (MatchingPhase) -> Void)? = nil
    ) async throws -> [MatchResult] {
        let totalInputs = inputs.count

        // Always use the structured system prompt as the base.
        // Append any custom reranker instruction as additional matching context.
        let basePrompt = HaikuPromptBuilder.systemPrompt(for: promptStrategy)
        let systemPrompt = rerankerInstruction != nil
            ? basePrompt + "\n\nAdditional matching context: " + rerankerInstruction!
            : basePrompt

        logger.info("[Pipeline] HaikuReranker | Stage: embedding | Instruction: (none -- GTE-Large is symmetric, instruction ignored)")
        logger.info("[Pipeline] HaikuReranker | Stage: haiku | rerankerInstruction param: \(rerankerInstruction?.prefix(100) ?? "(none)")")
        logger.info("[Pipeline] HaikuReranker | Stage: haiku | Final system prompt: \(systemPrompt.prefix(200))")
        logger.info("[Pipeline] HaikuReranker | \(totalInputs) inputs, top-\(self.topK) candidates each")

        // Stage 1: GTE-Large embedding retrieval
        let stage1Start = Date()
        onPhaseChange?(.loadingDatabase)
        logger.info("Stage 1: GTE-Large embedding retrieval")

        // GTE-Large is symmetric, instruction is not used
        await engine.setInstruction(nil)

        let topKResults = try await engine.matchTopK(
            inputs: inputs,
            database: database,
            k: topK,
            batchSize: hardwareConfig.matchingBatchSize,
            embeddingBatchSize: hardwareConfig.embeddingBatchSize,
            chunkSize: hardwareConfig.chunkSize,
            onProgress: { completed in
                onPhaseChange?(.embeddingInputs)
                onProgress(completed)
            },
            onEmbedProgress: { completed, total in
                onPhaseChange?(.embeddingDatabase(completed: completed, total: total))
            }
        )

        let stage1Duration = Date().timeIntervalSince(stage1Start)
        logger.info("Stage 1 complete in \(String(format: "%.1f", stage1Duration))s")

        // Stage 2: Submit to Message Batches API
        let stage2Start = Date()

        await apiClient.resetCancellation()

        // Build task list, separating empty-candidate inputs
        var finalResults = [MatchResult?](repeating: nil, count: totalInputs)
        var tasks: [TaskInfo] = []

        var filteredOutCount = 0
        for (inputIndex, candidates) in topKResults.enumerated() {
            let input = inputs[inputIndex]

            if candidates.isEmpty {
                finalResults[inputIndex] = MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    score: 0,
                    status: .error,
                    scoreType: .noScore
                )
            } else {
                // Filter out candidates below the embedding score floor
                let qualifiedCandidates = candidates.filter { Double($0.score) >= embeddingScoreFloor }

                if qualifiedCandidates.isEmpty {
                    // All candidates are below the score floor -- auto-reject without calling Haiku
                    let matchCandidates = candidates.map { candidate in
                        MatchCandidate(
                            matchText: candidate.entry.text,
                            matchID: candidate.entry.id,
                            score: Double(candidate.score),
                            additionalFields: candidate.entry.additionalFields
                        )
                    }
                    finalResults[inputIndex] = MatchResult(
                        inputText: input,
                        inputRow: inputIndex,
                        score: 0,
                        status: .noMatch,
                        scoreType: .llmRejected,
                        llmReasoning: "All candidates below embedding score floor (\(String(format: "%.2f", embeddingScoreFloor)))",
                        candidates: matchCandidates
                    )
                    filteredOutCount += 1
                } else {
                    let texts = qualifiedCandidates.map { $0.entry.text }
                    tasks.append(TaskInfo(
                        originalIndex: inputIndex,
                        query: input,
                        candidateTexts: texts,
                        rawCandidates: qualifiedCandidates
                    ))
                }
            }
        }

        if filteredOutCount > 0 {
            logger.info("\(filteredOutCount) inputs auto-rejected (all candidates below score floor \(self.embeddingScoreFloor))")
        }

        // Build batch request tasks using prompt builder
        let batchTasks = tasks.map { task in
            let scores = task.rawCandidates.map { $0.score }
            let userMessage = HaikuPromptBuilder.buildUserMessage(
                query: task.query,
                candidates: task.candidateTexts,
                strategy: promptStrategy,
                scores: promptStrategy == .production ? scores : nil
            )
            return (customId: "task-\(task.originalIndex)", userMessage: userMessage)
        }

        // Submit batch
        logger.info("Stage 2: Submitting \(batchTasks.count) tasks to Batches API")
        onPhaseChange?(.batchSubmitting)

        let batchId = try await apiClient.submitBatch(
            tasks: batchTasks,
            systemPrompt: systemPrompt,
            apiKey: apiKey
        )

        onPhaseChange?(.batchSubmitted(taskCount: batchTasks.count))

        // Poll for completion
        let finalStatus: BatchStatus
        do {
            finalStatus = try await apiClient.pollBatchStatus(
                batchId: batchId,
                apiKey: apiKey,
                onStatusUpdate: { [totalInputs] status in
                    onPhaseChange?(.batchProcessing(
                        succeeded: status.requestCounts.succeeded,
                        total: status.total
                    ))
                    let stage2Progress = Int(Double(status.totalProcessed) / Double(max(status.total, 1)) * Double(totalInputs))
                    onProgress(stage2Progress)
                },
                onPollError: {
                    onPhaseChange?(.batchReconnecting)
                }
            )
        } catch is CancellationError {
            // User cancelled -- try to cancel the batch
            try? await apiClient.cancelBatch(batchId: batchId, apiKey: apiKey)
            throw CancellationError()
        } catch HaikuError.cancelled {
            try? await apiClient.cancelBatch(batchId: batchId, apiKey: apiKey)
            throw CancellationError()
        }

        // Fetch results
        logger.info("Fetching batch results...")
        let batchResults = try await apiClient.fetchBatchResults(
            batchId: batchId,
            apiKey: apiKey
        )

        // Build a lookup map from custom_id to result
        var resultMap: [String: BatchRequestResult] = [:]
        for result in batchResults {
            resultMap[result.customId] = result
            totalInputTokens += result.inputTokens
            totalOutputTokens += result.outputTokens
        }

        // Map batch results to MatchResults
        for task in tasks {
            let customId = "task-\(task.originalIndex)"
            let batchResult = resultMap[customId]
            let candidates = task.rawCandidates

            if let batchResult = batchResult,
               batchResult.resultType == "succeeded",
               let responseText = batchResult.messageText {
                // Parse response using the appropriate strategy (returns HaikuDecision)
                let decision = HaikuPromptBuilder.parseResponse(
                    responseText,
                    candidates: task.candidateTexts,
                    strategy: promptStrategy
                )

                // Build candidates from embedding scores (for review workflow)
                let matchCandidates = candidates.map { candidate in
                    MatchCandidate(
                        matchText: candidate.entry.text,
                        matchID: candidate.entry.id,
                        score: Double(candidate.score),
                        additionalFields: candidate.entry.additionalFields
                    )
                }

                switch decision {
                case .match(let matchedIndex):
                    let bestCandidate = candidates[matchedIndex]
                    let score = Double(bestCandidate.score)
                    // Claude selected a candidate -- use .llmMatch so triage auto-accepts
                    let reasoning: String
                    if promptStrategy == .production {
                        reasoning = "Selected candidate \(matchedIndex + 1): \(bestCandidate.entry.text)"
                    } else {
                        reasoning = responseText
                    }
                    finalResults[task.originalIndex] = MatchResult(
                        inputText: task.query,
                        inputRow: task.originalIndex,
                        matchText: bestCandidate.entry.text,
                        matchID: bestCandidate.entry.id,
                        score: score,
                        status: .llmMatch,
                        scoreType: .llmSelected,
                        llmReasoning: reasoning,
                        matchAdditionalFields: bestCandidate.entry.additionalFields,
                        candidates: matchCandidates
                    )

                case .review(let reviewIndex):
                    // Haiku is uncertain -- use .match (not .llmMatch) so triage
                    // routes through threshold logic and likely marks as pending review
                    let reviewCandidate = candidates[reviewIndex]
                    let score = Double(reviewCandidate.score)
                    finalResults[task.originalIndex] = MatchResult(
                        inputText: task.query,
                        inputRow: task.originalIndex,
                        matchText: reviewCandidate.entry.text,
                        matchID: reviewCandidate.entry.id,
                        score: score,
                        status: .match,
                        scoreType: .llmSelected,
                        llmReasoning: "Flagged for review: candidate \(reviewIndex + 1) (\(reviewCandidate.entry.text)) is a possible but uncertain match",
                        matchAdditionalFields: reviewCandidate.entry.additionalFields,
                        candidates: matchCandidates
                    )

                case .noMatch:
                    // Haiku explicitly rejected all candidates
                    finalResults[task.originalIndex] = MatchResult(
                        inputText: task.query,
                        inputRow: task.originalIndex,
                        score: 0,
                        status: .noMatch,
                        scoreType: .llmRejected,
                        llmReasoning: responseText,
                        candidates: matchCandidates
                    )
                }
            } else {
                // Errored/canceled/expired -- fall back to top embedding candidate
                let topCandidate = candidates[0]
                let score = Double(topCandidate.score)
                let matchCandidates = candidates.map { candidate in
                    MatchCandidate(
                        matchText: candidate.entry.text,
                        matchID: candidate.entry.id,
                        score: Double(candidate.score),
                        additionalFields: candidate.entry.additionalFields
                    )
                }
                if score >= threshold {
                    finalResults[task.originalIndex] = MatchResult(
                        inputText: task.query,
                        inputRow: task.originalIndex,
                        matchText: topCandidate.entry.text,
                        matchID: topCandidate.entry.id,
                        score: score,
                        status: .match,
                        scoreType: .apiFallback,
                        matchAdditionalFields: topCandidate.entry.additionalFields,
                        candidates: matchCandidates
                    )
                } else {
                    finalResults[task.originalIndex] = MatchResult(
                        inputText: task.query,
                        inputRow: task.originalIndex,
                        score: 0,
                        status: .noMatch,
                        scoreType: .apiFallback,
                        candidates: matchCandidates
                    )
                }
            }
        }

        // Fill any remaining nil slots
        let results: [MatchResult] = finalResults.enumerated().map { index, result in
            result ?? MatchResult(
                inputText: inputs[index],
                inputRow: index,
                score: 0,
                status: .error,
                scoreType: .noScore
            )
        }

        let stage2Duration = Date().timeIntervalSince(stage2Start)
        let totalDuration = stage1Duration + stage2Duration
        logger.info("Stage 2 complete in \(String(format: "%.1f", stage2Duration))s (total: \(String(format: "%.1f", totalDuration))s)")
        logger.info("API token usage: \(self.totalInputTokens) input + \(self.totalOutputTokens) output")
        logger.info("Batch results: \(finalStatus.requestCounts.succeeded) succeeded, \(finalStatus.requestCounts.errored) errored")

        onProgress(totalInputs)
        return results
    }

    /// Get the active batch ID (for persistence/resume)
    func getActiveBatchId() async -> String? {
        await apiClient.getActiveBatchId()
    }

    func cancel() async {
        await engine.cancel()
        // Cancel the active batch if one exists
        if let batchId = await apiClient.getActiveBatchId() {
            try? await apiClient.cancelBatch(batchId: batchId, apiKey: apiKey)
        }
        await apiClient.cancel()
    }
}
