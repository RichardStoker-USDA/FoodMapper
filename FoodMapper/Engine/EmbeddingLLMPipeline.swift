import Foundation
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "embedding-llm-pipeline")

/// Embedding retrieval (top-K) + generative LLM selection.
/// Stage 1: MatchingEngine cosine similarity over full DB.
/// Stage 2: GenerativeJudgeModel picks the best from top-K via text gen.
/// Supports letter (A-Z), number (1-N), and text (name) response formats.
final class EmbeddingLLMPipeline: MatchingPipelineProtocol {
    let pipelineType: PipelineType = .embeddingLLM
    var name: String { pipelineType.displayName }

    private let engine: MatchingEngine
    private let judge: GenerativeJudgeModel
    private let hardwareConfig: HardwareConfig
    let responseFormat: JudgeResponseFormat
    let allowThinking: Bool

    init(
        engine: MatchingEngine,
        judge: GenerativeJudgeModel,
        hardwareConfig: HardwareConfig,
        responseFormat: JudgeResponseFormat = .letter,
        allowThinking: Bool = false
    ) {
        self.engine = engine
        self.judge = judge
        self.hardwareConfig = hardwareConfig
        self.responseFormat = responseFormat
        self.allowThinking = allowThinking
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
        // Retrieve top-K for LLM judging (capped by response format limits)
        let topK = min(hardwareConfig.topKForReranking, responseFormat.maxCandidates)

        // Set custom instruction for asymmetric embedding models
        await engine.setInstruction(instruction)

        let fmt = self.responseFormat
        let think = self.allowThinking
        logger.info("[Pipeline] EmbeddingLLM | Stage: embedding | Instruction: \(instruction?.prefix(100) ?? "(model default)")")
        logger.info("[Pipeline] EmbeddingLLM | Stage: judge | Instruction: \(rerankerInstruction?.prefix(100) ?? "(model default)")")
        logger.info("[Pipeline] EmbeddingLLM | Format: \(fmt.rawValue) | Think: \(think) | TopK: \(topK)")

        // Stage 1: Embedding retrieval (60% of progress)
        let stage1Start = Date()
        onPhaseChange?(.loadingDatabase)
        logger.info("Stage 1: Retrieving top-\(topK) candidates for \(totalInputs) inputs")

        let stage1Progress: @Sendable (Int) -> Void = { completed in
            onPhaseChange?(.embeddingInputs)
            let scaled = Int(Double(completed) * 0.6)
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

        // Stage 2: Generative LLM selection (40% of progress)
        let stage2Start = Date()
        onPhaseChange?(.reranking(completed: 0, total: totalInputs))
        logger.info("Stage 2: LLM judging \(totalInputs) inputs (top-\(topK) candidates each)")

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

            // Judge this input's candidates via the generative model
            let candidateTexts = candidates.map { $0.entry.text }
            let judgeResult = try await judge.judgeViaGeneration(
                query: input,
                candidates: candidateTexts,
                instruction: rerankerInstruction,
                temperature: 0.0,
                responseFormat: fmt,
                allowThinking: think
            )

            // Build candidates list with LLM probabilities
            let scoredCandidates: [MatchCandidate] = candidates.enumerated().map { i, candidate in
                // labelProbabilities keys depend on format (letter: A,B,C; number: 1,2,3; text: indices)
                let label: String
                switch fmt {
                case .letter:
                    label = i < GenerativeJudgeModel.allLetterLabels.count ? GenerativeJudgeModel.allLetterLabels[i] : ""
                case .number:
                    label = String(i + 1)
                case .text:
                    label = String(i)
                }
                let prob = judgeResult.labelProbabilities[label] ?? 0
                return MatchCandidate(
                    matchText: candidate.entry.text,
                    matchID: candidate.entry.id,
                    score: Double(prob),
                    additionalFields: candidate.entry.additionalFields
                )
            }.sorted { $0.score > $1.score }

            if let selectedIdx = judgeResult.selectedIndex, selectedIdx < candidates.count {
                let selected = candidates[selectedIdx]
                let score = Double(judgeResult.confidence)
                // LLM selected a candidate -- always mark as match.
                // Confidence score is preserved for triage thresholds.
                let status: MatchStatus = .match

                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    matchText: selected.entry.text,
                    matchID: selected.entry.id,
                    score: score,
                    status: status,
                    scoreType: .generativeSelection,
                    matchAdditionalFields: selected.entry.additionalFields,
                    candidates: scoredCandidates
                ))
            } else {
                // X selected -- genuine no-match. Include candidates for review.
                results.append(MatchResult(
                    inputText: input,
                    inputRow: inputIndex,
                    score: 0,
                    status: .noMatch,
                    scoreType: .generativeSelection,
                    candidates: scoredCandidates
                ))
            }

            // Report stage 2 progress (60% base + 40% scaled)
            let stage2Progress = Int(0.6 * Double(totalInputs)) + Int(0.4 * Double(inputIndex + 1))
            onProgress(stage2Progress)
            onPhaseChange?(.reranking(completed: inputIndex + 1, total: totalInputs))

            // Clear GPU memory periodically
            if (inputIndex + 1) % 10 == 0 {
                Memory.clearCache()
            }
        }

        let stage2Duration = Date().timeIntervalSince(stage2Start)
        let totalDuration = stage1Duration + stage2Duration
        let xCount = results.filter { $0.matchText == nil && $0.status == .noMatch }.count
        logger.info("Stage 2 complete in \(String(format: "%.1f", stage2Duration))s (total: \(String(format: "%.1f", totalDuration))s)")
        logger.info("X-selection rate: \(xCount)/\(totalInputs) (\(String(format: "%.1f", Double(xCount) / max(Double(totalInputs), 1) * 100))%)")

        return results
    }

    func cancel() async {
        await engine.cancel()
    }
}
