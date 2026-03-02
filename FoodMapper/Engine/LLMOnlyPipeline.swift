import Foundation
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "llm-only-pipeline")

/// Single-stage matching pipeline using a generative LLM to select matches.
///
/// Loads all database entries, batches them into groups of 5 candidates,
/// and uses GenerativeJudgeModel to select the best match per input.
/// Best suited for small databases (up to ~500 entries) where exhaustive
/// evaluation by the LLM is feasible.
///
/// For each input:
/// 1. Present all DB entries in batches of 5 to the LLM
/// 2. Collect the winner from each batch with its confidence score
/// 3. If multiple batches, run a final round with batch winners
/// 4. Top result becomes the match
final class LLMOnlyPipeline: MatchingPipelineProtocol {
    let pipelineType: PipelineType = .qwen3LLMOnly
    var name: String { pipelineType.displayName }

    private let judge: GenerativeJudgeModel
    private let engine: MatchingEngine
    let responseFormat: JudgeResponseFormat
    let allowThinking: Bool

    /// Max candidates per LLM call (depends on response format)
    private var candidatesPerBatch: Int {
        switch responseFormat {
        case .letter: return min(26, 10)   // Use up to 10 per batch with letters
        case .number: return 10
        case .text: return 10
        }
    }

    /// Engine is used only for loading database entries (not for embedding)
    init(
        judge: GenerativeJudgeModel,
        engine: MatchingEngine,
        responseFormat: JudgeResponseFormat = .letter,
        allowThinking: Bool = false
    ) {
        self.judge = judge
        self.engine = engine
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
        // Load database entries (no embedding stage -- retrieval config not applicable)
        onPhaseChange?(.loadingDatabase)
        let entries = try await loadDatabaseEntries(database)

        guard !entries.isEmpty else {
            throw MatchingError.emptyDatabase
        }

        guard entries.count <= 500 else {
            throw MatchingError.databaseTooLarge(entries.count, 500)
        }

        let totalInputs = inputs.count
        let startTime = Date()

        // Use rerankerInstruction (which carries the judge instruction tier from AppState)
        // rather than instruction (which carries the embedding instruction)
        let judgeInst = rerankerInstruction

        let fmt = self.responseFormat
        let think = self.allowThinking
        let batchSz = self.candidatesPerBatch
        logger.info("[Pipeline] LLMOnly | Stage: embedding | Instruction: (none -- LLM-only pipeline)")
        logger.info("[Pipeline] LLMOnly | Stage: judge | Instruction: \(judgeInst?.prefix(100) ?? "(model default)")")
        logger.info("[Pipeline] LLMOnly | Format: \(fmt.rawValue) | Think: \(think) | BatchSize: \(batchSz)")
        if let instruction = instruction {
            logger.info("[Pipeline] LLMOnly | NOTE: embedding instruction was passed but IGNORED (no embedding stage): \(instruction.prefix(100))")
        }
        logger.info("[Pipeline] LLMOnly | judging \(totalInputs) inputs against \(entries.count) database entries")
        onPhaseChange?(.reranking(completed: 0, total: totalInputs))

        var results: [MatchResult] = []
        results.reserveCapacity(totalInputs)

        for (inputIndex, input) in inputs.enumerated() {
            try Task.checkCancellation()

            let result = try await judgeInputAgainstDatabase(
                input: input,
                inputIndex: inputIndex,
                entries: entries,
                threshold: threshold,
                instruction: judgeInst
            )
            results.append(result)

            onProgress(inputIndex + 1)
            onPhaseChange?(.reranking(completed: inputIndex + 1, total: totalInputs))

            // Clear GPU memory periodically
            if (inputIndex + 1) % 5 == 0 {
                Memory.clearCache()
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        logger.info("LLM-only complete in \(String(format: "%.1f", duration))s (\(totalInputs) inputs x \(entries.count) entries)")

        return results
    }

    func cancel() async {
        // Sequential processing; cancellation via Task.checkCancellation()
    }

    // MARK: - Private

    /// Judge a single input against the full database via batched LLM calls.
    ///
    /// Splits DB entries into batches of 5, runs each batch through the LLM,
    /// then runs a final round with batch winners if needed.
    private func judgeInputAgainstDatabase(
        input: String,
        inputIndex: Int,
        entries: [DatabaseEntry],
        threshold: Double,
        instruction: String?
    ) async throws -> MatchResult {
        // Split entries into batches of candidatesPerBatch
        let batches = stride(from: 0, to: entries.count, by: candidatesPerBatch).map { start in
            let end = min(start + candidatesPerBatch, entries.count)
            return Array(entries[start..<end])
        }

        // First round: judge each batch
        var batchWinners: [(entry: DatabaseEntry, confidence: Float)] = []

        for batch in batches {
            try Task.checkCancellation()

            let candidateTexts = batch.map { $0.text }
            let judgeResult = try await judge.judgeViaGeneration(
                query: input,
                candidates: candidateTexts,
                instruction: instruction,
                temperature: 0.0,
                responseFormat: responseFormat,
                allowThinking: allowThinking
            )

            if let selectedIdx = judgeResult.selectedIndex, selectedIdx < batch.count {
                batchWinners.append((entry: batch[selectedIdx], confidence: judgeResult.confidence))
            }

            Memory.clearCache()
        }

        // No winners from any batch
        guard !batchWinners.isEmpty else {
            return MatchResult(
                inputText: input,
                inputRow: inputIndex,
                score: 0,
                status: .noMatch,
                scoreType: .generativeSelection
            )
        }

        // If only one winner (or one batch), use it directly
        if batchWinners.count == 1 {
            let winner = batchWinners[0]
            let score = Double(winner.confidence)
            // LLM selected a candidate -- always mark as match.
            // Confidence score is preserved for triage thresholds.
            let status: MatchStatus = .match

            let candidates = batchWinners.map { w in
                MatchCandidate(
                    matchText: w.entry.text,
                    matchID: w.entry.id,
                    score: Double(w.confidence),
                    additionalFields: w.entry.additionalFields
                )
            }

            return MatchResult(
                inputText: input,
                inputRow: inputIndex,
                matchText: winner.entry.text,
                matchID: winner.entry.id,
                score: score,
                status: status,
                scoreType: .generativeSelection,
                matchAdditionalFields: winner.entry.additionalFields,
                candidates: candidates
            )
        }

        // Final round: judge batch winners against each other
        // If more than 5 winners, take the top 5 by confidence
        let topWinners = Array(batchWinners.sorted { $0.confidence > $1.confidence }.prefix(candidatesPerBatch))
        let finalCandidateTexts = topWinners.map { $0.entry.text }

        let finalResult = try await judge.judgeViaGeneration(
            query: input,
            candidates: finalCandidateTexts,
            instruction: instruction,
            temperature: 0.0,
            responseFormat: responseFormat,
            allowThinking: allowThinking
        )

        // Build candidates list sorted by final confidence
        let candidateList: [MatchCandidate] = topWinners.enumerated().map { i, w in
            let label: String
            switch responseFormat {
            case .letter:
                label = i < GenerativeJudgeModel.allLetterLabels.count ? GenerativeJudgeModel.allLetterLabels[i] : ""
            case .number:
                label = String(i + 1)
            case .text:
                label = String(i)
            }
            let prob = finalResult.labelProbabilities[label] ?? 0
            return MatchCandidate(
                matchText: w.entry.text,
                matchID: w.entry.id,
                score: Double(prob),
                additionalFields: w.entry.additionalFields
            )
        }.sorted { $0.score > $1.score }

        if let selectedIdx = finalResult.selectedIndex, selectedIdx < topWinners.count {
            let winner = topWinners[selectedIdx]
            let score = Double(finalResult.confidence)
            // LLM selected a candidate -- always mark as match.
            let status: MatchStatus = .match

            return MatchResult(
                inputText: input,
                inputRow: inputIndex,
                matchText: winner.entry.text,
                matchID: winner.entry.id,
                score: score,
                status: status,
                scoreType: .generativeSelection,
                matchAdditionalFields: winner.entry.additionalFields,
                candidates: candidateList
            )
        }

        // X (no match) selected in final round -- genuine no-match result
        return MatchResult(
            inputText: input,
            inputRow: inputIndex,
            score: 0,
            status: .noMatch,
            scoreType: .generativeSelection,
            candidates: candidateList
        )
    }

    /// Load database entries without computing embeddings.
    private func loadDatabaseEntries(_ database: AnyDatabase) async throws -> [DatabaseEntry] {
        return try await engine.loadDatabaseEntriesOnly(database)
    }
}
