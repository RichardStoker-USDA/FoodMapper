import Foundation
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "haiku-v2-pipeline")

/// GTE-Large + Haiku v2: prompt caching with neutral framing and minimal user messages.
///
/// Stage 1: GTE-Large embedding retrieval (same as v1).
/// Stage 2: Anthropic Batch API with productionV2 prompt strategy.
///   - Long system prompt (~2,200 tokens) with 5 worked examples, cached via cache_control
///   - Minimal user message (~50 tokens): just the food description + numbered candidates
///   - max_tokens capped at 20 (response is always 1-3 tokens)
final class HaikuRerankerV2Pipeline: MatchingPipelineProtocol {
    let pipelineType: PipelineType = .gteLargeHaikuV2
    var name: String { pipelineType.displayName }

    private let engine: MatchingEngine
    private let apiClient: AnthropicAPIClient
    private let apiKey: String
    private let topK: Int
    private let embeddingScoreFloor: Double
    let modelVersion: ClaudeModelVersion

    private(set) var totalInputTokens: Int = 0
    private(set) var totalOutputTokens: Int = 0

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
        modelVersion: ClaudeModelVersion = .haiku45
    ) {
        self.engine = engine
        self.apiClient = apiClient
        self.apiKey = apiKey
        self.topK = topK
        self.embeddingScoreFloor = embeddingScoreFloor
        self.modelVersion = modelVersion
    }

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
        let promptStrategy: HaikuPromptStrategy = .productionV2

        // Build system prompt; append custom instruction if provided
        let basePrompt = HaikuPromptBuilder.systemPrompt(for: promptStrategy)
        let systemPrompt = rerankerInstruction != nil
            ? basePrompt + "\n\nAdditional matching context: " + rerankerInstruction!
            : basePrompt

        logger.info("[Pipeline] HaikuRerankerV2 | Stage: embedding | Instruction: (none -- GTE-Large is symmetric)")
        logger.info("[Pipeline] HaikuRerankerV2 | Stage: haiku | rerankerInstruction: \(rerankerInstruction?.prefix(100) ?? "(none)")")
        logger.info("[Pipeline] HaikuRerankerV2 | \(totalInputs) inputs, top-\(self.topK) candidates each")

        // Stage 1: GTE-Large embedding retrieval
        let stage1Start = Date()
        onPhaseChange?(.loadingDatabase)
        logger.info("Stage 1: GTE-Large embedding retrieval")

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
                let qualifiedCandidates = candidates.filter { Double($0.score) >= embeddingScoreFloor }

                if qualifiedCandidates.isEmpty {
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

        // Build batch request tasks using v2 prompt builder
        let batchTasks = tasks.map { task in
            let scores = task.rawCandidates.map { $0.score }
            let userMessage = HaikuPromptBuilder.buildUserMessage(
                query: task.query,
                candidates: task.candidateTexts,
                strategy: promptStrategy,
                scores: scores
            )
            return (customId: "task-\(task.originalIndex)", userMessage: userMessage)
        }

        // Submit batch with prompt caching enabled
        logger.info("Stage 2: Submitting \(batchTasks.count) tasks to Batches API (v2, prompt caching)")
        onPhaseChange?(.batchSubmitting)

        let batchId = try await apiClient.submitBatch(
            tasks: batchTasks,
            systemPrompt: systemPrompt,
            apiKey: apiKey,
            maxTokens: 20,
            usePromptCaching: true
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

        var resultMap: [String: BatchRequestResult] = [:]
        var totalCacheRead = 0
        var totalCacheCreation = 0
        for result in batchResults {
            resultMap[result.customId] = result
            totalInputTokens += result.inputTokens
            totalOutputTokens += result.outputTokens
            totalCacheRead += result.cacheReadInputTokens
            totalCacheCreation += result.cacheCreationInputTokens
        }

        // Map batch results to MatchResults
        for task in tasks {
            let customId = "task-\(task.originalIndex)"
            let batchResult = resultMap[customId]
            let candidates = task.rawCandidates

            if let batchResult = batchResult,
               batchResult.resultType == "succeeded",
               let responseText = batchResult.messageText {
                let decision = HaikuPromptBuilder.parseResponse(
                    responseText,
                    candidates: task.candidateTexts,
                    strategy: promptStrategy
                )

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
                    let reasoning = "Selected candidate \(matchedIndex + 1): \(bestCandidate.entry.text)"
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
        let cacheHitRate = batchResults.isEmpty ? 0 : Int(Double(totalCacheRead) / Double(max(totalCacheRead + self.totalInputTokens, 1)) * 100)
        logger.info("Cache: \(totalCacheRead) read tokens, \(totalCacheCreation) creation tokens (\(cacheHitRate)% hit rate)")
        logger.info("Batch results: \(finalStatus.requestCounts.succeeded) succeeded, \(finalStatus.requestCounts.errored) errored")

        onProgress(totalInputs)
        return results
    }

    func getActiveBatchId() async -> String? {
        await apiClient.getActiveBatchId()
    }

    func cancel() async {
        await engine.cancel()
        if let batchId = await apiClient.getActiveBatchId() {
            try? await apiClient.cancelBatch(batchId: batchId, apiKey: apiKey)
        }
        await apiClient.cancel()
    }
}
