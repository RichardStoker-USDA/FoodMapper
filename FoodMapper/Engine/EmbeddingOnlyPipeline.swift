import Foundation
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "pipeline")

/// Pipeline that uses only embedding similarity for matching.
/// Wraps MatchingEngine's existing match() logic behind MatchingPipelineProtocol.
/// Used for both GTE-Large (paper validation) and Qwen3-Embedding (modern) pipelines.
final class EmbeddingOnlyPipeline: MatchingPipelineProtocol {
    let pipelineType: PipelineType
    private let engine: MatchingEngine

    var name: String { pipelineType.displayName }

    /// Create a pipeline backed by the given matching engine.
    /// - Parameters:
    ///   - type: The pipeline type (.gteLargeEmbedding or .qwen3Embedding)
    ///   - engine: The matching engine with the appropriate model loaded
    init(type: PipelineType, engine: MatchingEngine) {
        self.pipelineType = type
        self.engine = engine
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
        // Set custom instruction for asymmetric models (Qwen3-Embedding)
        await engine.setInstruction(instruction)

        logger.info("[Pipeline] \(self.pipelineType.displayName) | Stage: embedding | Instruction: \(instruction?.prefix(100) ?? "(model default)")")
        logger.info("[Pipeline] \(self.pipelineType.displayName) | Stage: reranker | Instruction: (none -- embedding-only pipeline)")

        onPhaseChange?(.loadingDatabase)

        // Use top-K retrieval to populate candidates for review workflow
        let topK = hardwareConfig.topKForReranking
        let topKResults = try await engine.matchTopK(
            inputs: inputs,
            database: database,
            k: topK,
            batchSize: hardwareConfig.matchingBatchSize,
            embeddingBatchSize: hardwareConfig.embeddingBatchSize,
            chunkSize: hardwareConfig.chunkSize,
            onProgress: { completed in
                // Switch to embeddingInputs phase on first input progress
                onPhaseChange?(.embeddingInputs)
                onProgress(completed)
            },
            onEmbedProgress: { completed, total in
                onPhaseChange?(.embeddingDatabase(completed: completed, total: total))
            }
        )

        // Build MatchResults with candidates
        return topKResults.enumerated().map { inputIndex, candidates in
            guard let best = candidates.first else {
                return MatchResult(
                    inputText: inputs[inputIndex],
                    inputRow: inputIndex,
                    score: 0,
                    status: .error,
                    scoreType: .noScore
                )
            }

            let score = Double(best.score)
            // Use fixed floor of 0.50 so items with candidates show as "Needs Review"
            // instead of "No Match". Triage system routes these to autoNeedsReview.
            let isMatch = score >= 0.50
            let matchCandidates = candidates.map { candidate in
                MatchCandidate(
                    matchText: candidate.entry.text,
                    matchID: candidate.entry.id,
                    score: Double(candidate.score),
                    additionalFields: candidate.entry.additionalFields
                )
            }

            if isMatch {
                return MatchResult(
                    inputText: inputs[inputIndex],
                    inputRow: inputIndex,
                    matchText: best.entry.text,
                    matchID: best.entry.id,
                    score: score,
                    status: .match,
                    scoreType: .cosineSimilarity,
                    matchAdditionalFields: best.entry.additionalFields,
                    candidates: matchCandidates
                )
            } else {
                return MatchResult(
                    inputText: inputs[inputIndex],
                    inputRow: inputIndex,
                    score: 0,
                    status: .noMatch,
                    scoreType: .cosineSimilarity,
                    candidates: matchCandidates
                )
            }
        }
    }

    func cancel() async {
        await engine.cancel()
    }
}
