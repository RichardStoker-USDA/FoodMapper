import Foundation
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "reranker-pipeline")

/// Reranker-only matching pipeline for benchmarking/research.
///
/// Scores EVERY database entry against each input using the cross-encoder.
/// This is O(N * M) where N = inputs and M = database size, so it's very slow
/// for large databases. The tradeoff is maximum accuracy since every possible
/// match is evaluated by the reranker.
///
/// Intended for:
/// - Benchmarking reranker quality against embedding-only pipelines
/// - Small databases where exhaustive scoring is feasible
/// - Research comparison of pipeline architectures
final class RerankerOnlyPipeline: MatchingPipelineProtocol {
    let pipelineType: PipelineType = .qwen3Reranker
    var name: String { pipelineType.displayName }

    private let reranker: QwenRerankerModel
    private let engine: MatchingEngine

    /// Engine is used only for loading database entries (not for embedding)
    init(reranker: QwenRerankerModel, engine: MatchingEngine) {
        self.reranker = reranker
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
        // Load database entries (we need the text and metadata, not embeddings)
        onPhaseChange?(.loadingDatabase)
        let entries = try await loadDatabaseEntries(database)

        guard !entries.isEmpty else {
            throw MatchingError.emptyDatabase
        }

        guard entries.count <= 500 else {
            throw MatchingError.databaseTooLarge(entries.count, 500)
        }

        let dbTexts = entries.map { $0.text }
        let totalInputs = inputs.count
        let startTime = Date()

        logger.info("[Pipeline] RerankerOnly | Stage: embedding | Instruction: (none -- reranker-only pipeline)")
        logger.info("[Pipeline] RerankerOnly | Stage: reranker | Instruction: \(rerankerInstruction?.prefix(100) ?? "(model default)")")
        logger.info("[Pipeline] RerankerOnly | scoring \(totalInputs) inputs against \(entries.count) database entries")
        onPhaseChange?(.reranking(completed: 0, total: totalInputs))

        var results: [MatchResult] = []
        results.reserveCapacity(totalInputs)

        for (inputIndex, input) in inputs.enumerated() {
            try Task.checkCancellation()

            // Score all database entries for this input (use rerankerInstruction for cross-encoder)
            let scores = try await reranker.rerank(
                query: input,
                candidates: dbTexts,
                instruction: rerankerInstruction
            )

            // Find highest-scoring entry
            guard let bestScore = scores.max(by: { $0.score < $1.score }) else {
                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    score: 0,
                    status: .error,
                    scoreType: .noScore
                ))
                continue
            }

            let bestEntry = entries[bestScore.candidateIndex]
            let score = Double(bestScore.score)
            let isMatch = score >= threshold

            // Build top-N candidates sorted by reranker score
            let topN = min(hardwareConfig.topKForReranking, scores.count)
            let topCandidates: [MatchCandidate] = scores
                .sorted { $0.score > $1.score }
                .prefix(topN)
                .map { rerankerScore in
                    let entry = entries[rerankerScore.candidateIndex]
                    return MatchCandidate(
                        matchText: entry.text,
                        matchID: entry.id,
                        score: Double(rerankerScore.score),
                        additionalFields: entry.additionalFields
                    )
                }

            if isMatch {
                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    matchText: bestEntry.text,
                    matchID: bestEntry.id,
                    score: score,
                    status: .match,
                    scoreType: .rerankerProbability,
                    matchAdditionalFields: bestEntry.additionalFields,
                    candidates: topCandidates
                ))
            } else {
                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    score: 0,
                    status: .noMatch,
                    scoreType: .rerankerProbability,
                    candidates: topCandidates
                ))
            }

            onProgress(inputIndex + 1)
            onPhaseChange?(.reranking(completed: inputIndex + 1, total: totalInputs))

            // Clear GPU memory periodically
            if (inputIndex + 1) % 10 == 0 {
                Memory.clearCache()
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        logger.info("Reranker-only complete in \(String(format: "%.1f", duration))s (\(totalInputs) inputs x \(entries.count) entries)")

        return results
    }

    func cancel() async {
        // Reranker processes sequentially; cancellation is via Task.checkCancellation()
    }

    /// Load database entries without computing embeddings.
    private func loadDatabaseEntries(_ database: AnyDatabase) async throws -> [DatabaseEntry] {
        return try await engine.loadDatabaseEntriesOnly(database)
    }
}
