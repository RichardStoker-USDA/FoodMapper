import Foundation
import Hub
import MLX
import MLXLMCommon
import MLXLLM
import Tokenizers
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "qwen-reranker")

/// Metadata describing a reranker model
struct RerankerModelInfo: Sendable {
    let key: String
    let displayName: String
}

/// Relevance score from the reranker for a single candidate
struct RerankerScore: Sendable {
    let candidateIndex: Int
    /// P(yes) from the model, 0.0-1.0
    let score: Float
}

/// Cross-encoder reranker via MLXLLM. Scores (query, doc) pairs by extracting
/// P(yes) from the model's yes/no logits. Follows Qwen3-Reranker prompt spec.
/// FP16 MLX conversion: richtext/Qwen3-Reranker-0.6B-mlx-fp16
actor QwenRerankerModel {
    nonisolated let info: RerankerModelInfo

    private let repoId: String
    private var container: ModelContainer?
    private var yesTokenId: Int = -1
    private var noTokenId: Int = -1

    var isLoaded: Bool {
        container != nil
    }

    /// Default matching instruction for food-database reranking
    static let defaultInstruction = "Given a food description, determine if the document describes the same food item as the query. Consider the specific food type, preparation method, and form."

    init(
        repoId: String = "richtext/Qwen3-Reranker-0.6B-mlx-fp16",
        key: String = "qwen3-reranker-0.6b",
        displayName: String = "Qwen3-Reranker 0.6B"
    ) {
        self.repoId = repoId
        self.info = RerankerModelInfo(
            key: key,
            displayName: displayName
        )
    }

    // MARK: - Loading

    func load() async throws {
        try await load(hub: HubApi())
    }

    func load(hub: HubApi) async throws {
        let configuration = MLXLMCommon.ModelConfiguration(id: repoId)

        logger.info("Loading Qwen3-Reranker from \(self.repoId)...")

        container = try await MLXLMCommon.loadModelContainer(
            hub: hub,
            configuration: configuration
        ) { progress in
            logger.debug("Download progress: \(Int(progress.fractionCompleted * 100))%")
        }

        // Look up yes/no token IDs for scoring
        try await resolveTokenIds()

        logger.info("Qwen3-Reranker loaded (yes=\(self.yesTokenId), no=\(self.noTokenId))")
    }

    func load(hub: HubApi, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let configuration = MLXLMCommon.ModelConfiguration(id: repoId)

        container = try await MLXLMCommon.loadModelContainer(
            hub: hub,
            configuration: configuration
        ) { progress in
            onProgress(progress.fractionCompleted)
        }

        try await resolveTokenIds()

        logger.info("Qwen3-Reranker loaded (yes=\(self.yesTokenId), no=\(self.noTokenId))")
    }

    /// Resolve "yes" and "no" token IDs from the tokenizer.
    /// Uses direct vocab lookup (convertTokenToId) instead of full encoding pipeline
    /// to match the Python reference implementation's convert_tokens_to_ids behavior.
    private func resolveTokenIds() async throws {
        guard let container = container else {
            throw RerankerError.modelNotLoaded
        }

        let (yesId, noId) = await container.perform { context in
            let tokenizer = context.tokenizer
            let yesId = tokenizer.convertTokenToId("yes") ?? -1
            let noId = tokenizer.convertTokenToId("no") ?? -1
            return (yesId, noId)
        }

        guard yesId >= 0, noId >= 0 else {
            throw RerankerError.tokenResolutionFailed
        }

        self.yesTokenId = yesId
        self.noTokenId = noId
    }

    // MARK: - Reranking

    /// Score candidates against a query. Pre-tokenizes in one pass (~15-20% faster),
    /// then sequential forward passes with cancellation + periodic GPU cleanup.
    ///
    /// - Parameters:
    ///   - query: The input food description to match
    ///   - candidates: Array of database entry texts to score
    ///   - instruction: Optional custom instruction (defaults to food matching)
    ///   - onCandidateComplete: Optional progress callback (completedIndex, totalCount)
    /// - Returns: Array of scores sorted by candidateIndex (preserves input order)
    func rerank(
        query: String,
        candidates: [String],
        instruction: String? = nil,
        onCandidateComplete: ((Int, Int) -> Void)? = nil
    ) async throws -> [RerankerScore] {
        guard let container = container else {
            throw RerankerError.modelNotLoaded
        }

        let inst = instruction ?? Self.defaultInstruction

        logger.info("[Model] QwenReranker | rerank() | Instruction: \(inst.prefix(100))")
        logger.info("[Model] QwenReranker | rerank() | Query: \(query.prefix(80)) | Candidates: \(candidates.count)")

        // Capture token IDs locally to avoid actor isolation in @Sendable closures
        let yesId = self.yesTokenId
        let noId = self.noTokenId

        // Build all prompts
        let prompts = candidates.map { formatPrompt(query: query, document: $0, instruction: inst) }

        // Phase 1: Pre-tokenize all candidates in one container.perform call
        let allTokens: [[Int]] = try await container.perform { context in
            prompts.map { context.tokenizer.encode(text: $0) }
        }

        // Phase 2: Sequential forward passes with cancellation and memory cleanup
        var scores: [RerankerScore] = []
        scores.reserveCapacity(candidates.count)

        for (index, tokens) in allTokens.enumerated() {
            try Task.checkCancellation()

            let score: Float = try await container.perform { context in
                let model = context.model
                let inputArray = MLXArray(tokens).reshaped(1, tokens.count)

                let cache = model.newCache(parameters: nil)
                let input = LMInput.Text(tokens: inputArray, mask: nil)
                let output = model(input, cache: cache, state: nil)

                let logits = output.logits
                let seqLen = tokens.count

                let lastLogits: MLXArray
                if logits.ndim == 3 {
                    lastLogits = logits[0, seqLen - 1]
                } else {
                    lastLogits = logits[seqLen - 1]
                }

                let yesLogit = lastLogits[yesId].item(Float.self)
                let noLogit = lastLogits[noId].item(Float.self)

                let maxLogit = Swift.max(yesLogit, noLogit)
                let expYes = exp(yesLogit - maxLogit)
                let expNo = exp(noLogit - maxLogit)
                let pYes = expYes / (expYes + expNo)

                return pYes
            }

            scores.append(RerankerScore(candidateIndex: index, score: score))
            onCandidateComplete?(index + 1, candidates.count)

            // Clear GPU intermediate buffers every 5 candidates
            if (index + 1) % 5 == 0 {
                Memory.clearCache()
            }
        }

        return scores
    }

    // MARK: - Batch Reranking

    /// Batched rerank: pad + stack all candidates into [N, maxLen], single forward pass.
    /// 2-3x faster than sequential for typical batch sizes (5-10 candidates).
    /// Falls back to sequential for trivial (1) or huge (>20) batches.
    func batchRerank(
        query: String,
        candidates: [String],
        instruction: String? = nil
    ) async throws -> [RerankerScore] {
        guard let container = container else {
            throw RerankerError.modelNotLoaded
        }

        // Fall back to sequential for trivial or very large batches
        if candidates.count <= 1 || candidates.count > 20 {
            return try await rerank(query: query, candidates: candidates, instruction: instruction)
        }

        let inst = instruction ?? Self.defaultInstruction
        let yesId = self.yesTokenId
        let noId = self.noTokenId

        logger.info("[Model] QwenReranker | batchRerank() | Instruction: \(inst.prefix(100))")
        logger.info("[Model] QwenReranker | batchRerank() | Query: \(query.prefix(80)) | Candidates: \(candidates.count)")

        // Build all prompts
        let prompts = candidates.map { formatPrompt(query: query, document: $0, instruction: inst) }

        // Tokenize, pad, forward pass, and extract scores in one container.perform call
        let scores: [RerankerScore] = try await container.perform { context in
            let tokenizer = context.tokenizer
            let model = context.model

            // Tokenize all prompts
            let allTokens = prompts.map { tokenizer.encode(text: $0) }
            let tokenLengths = allTokens.map { $0.count }
            let maxLen = tokenLengths.max() ?? 0

            // Pad to maxLen with 0 (padding token) and build attention mask
            let padId = 0
            var paddedTokens: [[Int]] = []
            var maskValues: [[Float]] = []

            for tokens in allTokens {
                let padCount = maxLen - tokens.count
                paddedTokens.append(tokens + Array(repeating: padId, count: padCount))
                maskValues.append(Array(repeating: Float(1), count: tokens.count) +
                                  Array(repeating: Float(0), count: padCount))
            }

            let batchSize = candidates.count
            // Create [N, maxLen] token tensor and attention mask
            let tokenTensor = MLXArray(paddedTokens.flatMap { $0 })
                .reshaped(batchSize, maxLen)
            let maskTensor = MLXArray(maskValues.flatMap { $0 })
                .reshaped(batchSize, 1, 1, maxLen)

            // Single forward pass with no KV cache (prefill only).
            // cache must be nil, not [] -- an empty array causes index-out-of-bounds
            // when the model tries to access cache?[layerIndex].
            let input = LMInput.Text(tokens: tokenTensor, mask: maskTensor)
            let output = model(input, cache: nil, state: nil)

            // output.logits shape: [N, maxLen, vocabSize]
            let logits = output.logits
            eval(logits)

            // Extract per-sequence scores at each sequence's last real token
            var results: [RerankerScore] = []
            results.reserveCapacity(batchSize)

            for i in 0..<batchSize {
                let lastRealIdx = tokenLengths[i] - 1
                let lastLogits = logits[i, lastRealIdx]

                let yesLogit = lastLogits[yesId].item(Float.self)
                let noLogit = lastLogits[noId].item(Float.self)

                let maxLogit = Swift.max(yesLogit, noLogit)
                let expYes = exp(yesLogit - maxLogit)
                let expNo = exp(noLogit - maxLogit)
                let pYes = expYes / (expYes + expNo)

                results.append(RerankerScore(candidateIndex: i, score: pYes))
            }

            return results
        }

        Memory.clearCache()
        return scores
    }

    // MARK: - Prompt Formatting

    /// Format the reranker prompt per Qwen3-Reranker specification.
    ///
    /// The prompt structure:
    /// - System message: instructs binary yes/no judgment
    /// - User message: contains instruction, query, and document
    /// - Assistant prefix: includes empty think block (no-think mode)
    ///
    /// The model's logits at the final position predict "yes" or "no".
    private nonisolated func formatPrompt(
        query: String,
        document: String,
        instruction: String
    ) -> String {
        "<|im_start|>system\nJudge whether the Document meets the requirements based on the Query and the Instruct provided. Note that the answer can only be \"yes\" or \"no\".<|im_end|>\n<|im_start|>user\n<Instruct>: \(instruction)\n<Query>: \(query)\n<Document>: \(document)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }
}

// MARK: - Errors

enum RerankerError: LocalizedError {
    case modelNotLoaded
    case tokenResolutionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Reranker model not loaded"
        case .tokenResolutionFailed:
            return "Could not resolve yes/no token IDs from tokenizer"
        }
    }
}
