import Foundation
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "two-stage-pipeline")

/// Embedding retrieval (top-K) + cross-encoder reranking.
/// Stage 1: MatchingEngine cosine similarity over full DB (fast).
/// Stage 2: QwenRerankerModel scores K candidates per input (accurate).
final class TwoStagePipeline: MatchingPipelineProtocol {
    let pipelineType: PipelineType = .qwen3TwoStage
    var name: String { pipelineType.displayName }

    private let engine: MatchingEngine
    private let reranker: QwenRerankerModel
    private let hardwareConfig: HardwareConfig

    init(engine: MatchingEngine, reranker: QwenRerankerModel, hardwareConfig: HardwareConfig) {
        self.engine = engine
        self.reranker = reranker
        self.hardwareConfig = hardwareConfig
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
        let topK = hardwareConfig.topKForReranking

        // Set custom instruction for asymmetric embedding models
        await engine.setInstruction(instruction)

        logger.info("[Pipeline] TwoStage | Stage: embedding | Instruction: \(instruction?.prefix(100) ?? "(model default)")")
        logger.info("[Pipeline] TwoStage | Stage: reranker | Instruction: \(rerankerInstruction?.prefix(100) ?? "(model default)")")

        // Stage 1: Embedding retrieval (70% of progress)
        let stage1Start = Date()
        onPhaseChange?(.loadingDatabase)
        logger.info("Stage 1: Retrieving top-\(topK) candidates for \(totalInputs) inputs")

        let stage1Progress: @Sendable (Int) -> Void = { completed in
            onPhaseChange?(.embeddingInputs)
            let scaled = Int(Double(completed) * 0.7)
            onProgress(scaled)
        }

        let topKResults = try await engine.matchTopK(
            inputs: inputs,
            database: database,
            k: topK,
            batchSize: hardwareConfig.matchingBatchSize,
            embeddingBatchSize: hardwareConfig.embeddingBatchSize,
            chunkSize: hardwareConfig.chunkSize,
            onProgress: stage1Progress,
            onEmbedProgress: { completed, total in
                onPhaseChange?(.embeddingDatabase(completed: completed, total: total))
            }
        )

        let stage1Duration = Date().timeIntervalSince(stage1Start)
        logger.info("Stage 1 complete in \(String(format: "%.1f", stage1Duration))s")

        // Clear GPU memory between stages
        Memory.clearCache()

        // Stage 2: Reranker scoring (30% of progress)
        let stage2Start = Date()
        onPhaseChange?(.reranking(completed: 0, total: totalInputs))
        logger.info("Stage 2: Reranking \(totalInputs) inputs (top-\(topK) candidates each)")

        var results: [MatchResult] = []
        results.reserveCapacity(totalInputs)

        for (inputIndex, candidates) in topKResults.enumerated() {
            try Task.checkCancellation()

            let input = inputs[inputIndex]

            guard !candidates.isEmpty else {
                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    score: 0,
                    status: .error,
                    scoreType: .noScore
                ))
                continue
            }

            // Rerank this input's candidates via batch prefill (use rerankerInstruction for cross-encoder)
            let candidateTexts = candidates.map { $0.entry.text }
            let rerankerScores = try await reranker.batchRerank(
                query: input,
                candidates: candidateTexts,
                instruction: rerankerInstruction
            )

            // Find the best-scoring candidate from the reranker
            guard let bestScore = rerankerScores.max(by: { $0.score < $1.score }) else {
                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    score: 0,
                    status: .error,
                    scoreType: .noScore
                ))
                continue
            }

            let bestCandidate = candidates[bestScore.candidateIndex]
            let score = Double(bestScore.score)
            let isMatch = score >= threshold

            // Build candidates with reranker scores, sorted by reranker score descending
            let scoredCandidates: [MatchCandidate] = rerankerScores
                .sorted { $0.score > $1.score }
                .map { rerankerScore in
                    let candidate = candidates[rerankerScore.candidateIndex]
                    return MatchCandidate(
                        matchText: candidate.entry.text,
                        matchID: candidate.entry.id,
                        score: Double(rerankerScore.score),
                        additionalFields: candidate.entry.additionalFields
                    )
                }

            if isMatch {
                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    matchText: bestCandidate.entry.text,
                    matchID: bestCandidate.entry.id,
                    score: score,
                    status: .match,
                    scoreType: .rerankerProbability,
                    matchAdditionalFields: bestCandidate.entry.additionalFields,
                    candidates: scoredCandidates
                ))
            } else {
                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    score: 0,
                    status: .noMatch,
                    scoreType: .rerankerProbability,
                    candidates: scoredCandidates
                ))
            }

            // Report stage 2 progress (70% base + 30% scaled)
            let stage2Progress = Int(0.7 * Double(totalInputs)) + Int(0.3 * Double(inputIndex + 1))
            onProgress(stage2Progress)
            onPhaseChange?(.reranking(completed: inputIndex + 1, total: totalInputs))

            // Clear GPU memory periodically
            if (inputIndex + 1) % 20 == 0 {
                Memory.clearCache()
            }
        }

        let stage2Duration = Date().timeIntervalSince(stage2Start)
        let totalDuration = stage1Duration + stage2Duration
        logger.info("Stage 2 complete in \(String(format: "%.1f", stage2Duration))s (total: \(String(format: "%.1f", totalDuration))s)")

        return results
    }

    func cancel() async {
        await engine.cancel()
    }
}
