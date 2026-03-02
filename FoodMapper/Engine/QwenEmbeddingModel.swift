import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXNN
import Tokenizers
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "qwen-embedding")

/// Qwen3-Embedding model using MLXEmbedders framework.
/// Uses 4-bit DWQ (Data-Aware Weighted Quantization) for efficient inference.
/// Supports instruction-following for asymmetric query/document embedding.
/// Parameterized for multiple model sizes (0.6B, 4B, 8B).
actor QwenEmbeddingModel: EmbeddingModelProtocol {
    let repoId: String
    let embeddingDimensions: Int
    let modelKey: String
    let modelDisplayName: String

    private var modelContainer: MLXEmbedders.ModelContainer?

    /// Custom matching instruction (set before embedding queries)
    var matchingInstruction: String = "Given a food description from a dietary survey, retrieve the most similar standardized food item from the reference database"

    nonisolated let info: EmbeddingModelInfo

    var isLoaded: Bool {
        modelContainer != nil
    }

    init(
        repoId: String = "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
        embeddingDimensions: Int = 2560,
        modelKey: String = "qwen3-emb-4b-4bit",
        modelDisplayName: String = "Qwen3-Embedding 4B"
    ) {
        self.repoId = repoId
        self.embeddingDimensions = embeddingDimensions
        self.modelKey = modelKey
        self.modelDisplayName = modelDisplayName
        self.info = EmbeddingModelInfo(
            key: modelKey,
            displayName: modelDisplayName,
            dimensions: embeddingDimensions,
            isAsymmetric: true
        )
    }

    // MARK: - Loading

    /// Protocol conformance: load with default Hub location.
    func load() async throws {
        try await load(hub: HubApi())
    }

    /// Load model using the provided HubApi for download/cache location.
    func load(hub: HubApi) async throws {
        let configuration = MLXEmbedders.ModelConfiguration(id: self.repoId)
        logger.info("Loading \(self.modelDisplayName) from \(self.repoId)...")
        modelContainer = try await loadModelContainer(hub: hub, configuration: configuration)
        logger.info("\(self.modelDisplayName) loaded successfully")
    }

    /// Load with external progress handler (for UI download progress)
    func load(hub: HubApi, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let configuration = MLXEmbedders.ModelConfiguration(id: self.repoId)
        modelContainer = try await loadModelContainer(
            hub: hub, configuration: configuration, onProgress: onProgress
        )
        logger.info("\(self.modelDisplayName) loaded successfully")
    }

    // MARK: - Custom Loader

    /// Custom loader for quantized Qwen3 embedding models.
    /// MLXEmbedders handles model creation, but we do quantization and weight
    /// loading ourselves. DWQ repos lack 1_Pooling/config.json so we set up
    /// manual last-token pooling here.
    private nonisolated func loadModelContainer(
        hub: HubApi,
        configuration: MLXEmbedders.ModelConfiguration,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> MLXEmbedders.ModelContainer {
        // Download model files
        let modelDirectory: URL
        switch configuration.id {
        case .id(let id):
            let repo = Hub.Repo(id: id)
            let modelFiles = ["*.safetensors", "config.json", "*/config.json"]
            modelDirectory = try await hub.snapshot(
                from: repo, matching: modelFiles
            ) { progress in
                onProgress?(progress.fractionCompleted)
            }
        case .directory(let directory):
            modelDirectory = directory
        }

        // Load config
        let configURL = modelDirectory.appending(component: "config.json")
        let configData = try Data(contentsOf: configURL)

        struct QuantConfig: Codable {
            let groupSize: Int
            let bits: Int
            let mode: String?

            enum CodingKeys: String, CodingKey {
                case groupSize = "group_size"
                case bits
                case mode
            }
        }
        struct MinimalConfig: Codable {
            let quantization: QuantConfig?
        }

        let minConfig = try JSONDecoder().decode(MinimalConfig.self, from: configData)
        let qConfig = minConfig.quantization

        // Create model using MLXEmbedders' type system
        let baseConfig = try JSONDecoder().decode(
            MLXEmbedders.BaseConfiguration.self, from: configData)
        let modelType = MLXEmbedders.ModelType(rawValue: baseConfig.modelType)
        let model = try modelType.createModel(configuration: configData)

        // Load weights from safetensors
        var weights = [String: MLXArray]()
        let enumerator = FileManager.default.enumerator(
            at: modelDirectory, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            if url.pathExtension == "safetensors" {
                let w = try loadArrays(url: url)
                for (key, value) in w {
                    weights[key] = value
                }
            }
        }

        // Per-model sanitize (adds "model." prefix for Qwen3)
        weights = model.sanitize(weights: weights)

        // Apply quantization (replace Linear -> QuantizedLinear) for layers
        // that have .scales in the weight dict (i.e., were quantized during conversion).
        if let perLayerQuantization = baseConfig.perLayerQuantization {
            // Per-layer quantization configs (different bits/groupSize per layer)
            quantize(model: model) { path, module in
                if weights["\(path).scales"] != nil {
                    return perLayerQuantization.quantization(layer: path)?.asTuple
                } else {
                    return nil
                }
            }
        } else if let qConfig = qConfig {
            // Global quantization (standard affine 4-bit DWQ, etc.)
            let groupSize = qConfig.groupSize
            let bits = qConfig.bits
            quantize(model: model) { path, module in
                if weights["\(path).scales"] != nil {
                    return (groupSize, bits)
                } else {
                    return nil
                }
            }
        }

        // Load weights into model (strict verification)
        let parameters = ModuleParameters.unflattened(weights)
        try model.update(parameters: parameters, verify: [.all])
        eval(model)

        // Load tokenizer
        let tokenizer = try await loadTokenizer(configuration: configuration, hub: hub)

        // DWQ repos lack pooling config -- we do manual last-token pooling anyway
        let pooler = MLXEmbedders.Pooling(strategy: .none)

        return MLXEmbedders.ModelContainer(
            model: model, tokenizer: tokenizer, pooler: pooler)
    }

    // MARK: - Instruction

    func setInstruction(_ instruction: String?) async {
        if let instruction = instruction, !instruction.isEmpty {
            matchingInstruction = instruction
            logger.info("[Model] QwenEmbedding | setInstruction: custom instruction set (\(instruction.prefix(100)))")
        } else {
            matchingInstruction = "Given a food description from a dietary survey, retrieve the most similar standardized food item from the reference database"
            logger.info("[Model] QwenEmbedding | setInstruction: using default instruction")
        }
    }

    // MARK: - Embedding

    func embedBatch(_ texts: [String], batchSize: Int, isQuery: Bool) async throws -> [[Float]] {
        guard let container = modelContainer else {
            throw EmbeddingError.modelNotLoaded
        }

        var allEmbeddings: [[Float]] = []
        allEmbeddings.reserveCapacity(texts.count)

        for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
            try Task.checkCancellation()

            let batchEnd = min(batchStart + batchSize, texts.count)
            let batch = Array(texts[batchStart..<batchEnd])

            let batchEmbeddings = try await embedBatchInternal(
                batch, isQuery: isQuery, container: container
            )
            allEmbeddings.append(contentsOf: batchEmbeddings)
        }

        return allEmbeddings
    }

    func embedBatchAsMatrix(_ texts: [String], batchSize: Int, isQuery: Bool) async throws -> MLXArray {
        guard let container = modelContainer else {
            throw EmbeddingError.modelNotLoaded
        }

        if texts.count <= batchSize {
            return try await embedBatchAsMatrixInternal(
                texts, isQuery: isQuery, container: container
            )
        }

        var matrices: [MLXArray] = []
        for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
            try Task.checkCancellation()

            let batchEnd = min(batchStart + batchSize, texts.count)
            let batch = Array(texts[batchStart..<batchEnd])

            let matrix = try await embedBatchAsMatrixInternal(
                batch, isQuery: isQuery, container: container
            )
            matrices.append(matrix)
        }

        let result = concatenated(matrices, axis: 0)
        eval(result)
        return result
    }

    func embedBatchDirect(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        guard let container = modelContainer else {
            throw EmbeddingError.modelNotLoaded
        }

        return try await embedBatchInternal(texts, isQuery: isQuery, container: container)
    }

    // MARK: - Internal

    /// Format text with instruction prefix for asymmetric embedding.
    /// Queries get: "Instruct: {instruction}\nQuery:{text}" (no space after Query: per official format)
    /// Documents get: plain text (no prefix)
    private func formatText(_ text: String, isQuery: Bool) -> String {
        if isQuery {
            return "Instruct: \(matchingInstruction)\nQuery:\(text)"
        } else {
            return text
        }
    }

    /// Internal batch embedding returning [[Float]]
    private func embedBatchInternal(
        _ texts: [String],
        isQuery: Bool,
        container: MLXEmbedders.ModelContainer
    ) async throws -> [[Float]] {
        let formattedTexts = texts.map { formatText($0, isQuery: isQuery) }

        return try await container.perform { model, tokenizer, pooling in
            let embeddings = self.runModel(
                texts: formattedTexts, model: model, tokenizer: tokenizer, pooling: pooling
            )
            eval(embeddings)

            let embeddingDim = self.info.dimensions
            let tensorArray = embeddings.asArray(Float.self)
            var result: [[Float]] = []
            result.reserveCapacity(texts.count)
            for i in 0..<texts.count {
                let start = i * embeddingDim
                let end = start + embeddingDim
                result.append(Array(tensorArray[start..<end]))
            }
            return result
        }
    }

    /// Internal batch embedding returning MLXArray [N, dimensions]
    private func embedBatchAsMatrixInternal(
        _ texts: [String],
        isQuery: Bool,
        container: MLXEmbedders.ModelContainer
    ) async throws -> MLXArray {
        let formattedTexts = texts.map { formatText($0, isQuery: isQuery) }

        return try await container.perform { model, tokenizer, pooling in
            let embeddings = self.runModel(
                texts: formattedTexts, model: model, tokenizer: tokenizer, pooling: pooling
            )
            eval(embeddings)
            return embeddings
        }
    }

    /// Run the model on tokenized texts and return pooled, normalized embeddings.
    ///
    /// Manual last-token pooling is required because the DWQ-quantized repos
    /// don't include 1_Pooling/config.json, so MLXEmbedders defaults to
    /// Pooling(strategy: .none) which returns raw 3D hidden states.
    /// We extract the last real token's hidden state per row, take the first
    /// `info.dimensions` (2560) values, and L2-normalize.
    private nonisolated func runModel(
        texts: [String],
        model: any MLXEmbedders.EmbeddingModel,
        tokenizer: Tokenizer,
        pooling: MLXEmbedders.Pooling
    ) -> MLXArray {
        // Tokenize all texts
        let tokenized = texts.map { text in
            tokenizer.encode(text: text, addSpecialTokens: true)
        }

        // Track real token lengths for last-token extraction
        let tokenLengths = tokenized.map { $0.count }

        // Find max length for padding
        let maxLen = tokenized.reduce(16) { max($0, $1.count) }
        let padTokenId = tokenizer.eosTokenId ?? 0

        // Pad and stack into [batch, maxLen]
        let padded = MLX.stacked(
            tokenized.map { tokens in
                MLXArray(
                    tokens + Array(repeating: padTokenId, count: maxLen - tokens.count)
                )
            }
        )

        // Attention mask: 1 for real tokens, 0 for padding
        let mask = (padded .!= padTokenId)
        let tokenTypes = MLXArray.zeros(like: padded)

        // Forward pass -- returns ModelOutput with hiddenStates [batch, seq_len, hidden_size]
        let output = model(
            padded,
            positionIds: nil,
            tokenTypeIds: tokenTypes,
            attentionMask: mask
        )

        // Manual last-token pooling:
        // The DWQ repos lack pooling config, so the framework defaults to .none strategy
        // which returns raw 3D hidden states [batch, seq_len, hidden_size].
        // We extract each row's last real token, truncate to 1024, and L2-normalize.
        let hiddenStates = pooling(output, mask: mask, normalize: false, applyLayerNorm: false)
        let batchSize = texts.count
        let outputDim = self.info.dimensions

        var pooledRows: [MLXArray] = []
        pooledRows.reserveCapacity(batchSize)

        for i in 0..<batchSize {
            let lastIdx = tokenLengths[i] - 1  // Index of last real token
            // Extract [hidden_size] for this row's last real token
            let rowHidden = hiddenStates[i, lastIdx]
            // Use native dimensions for the model size
            let truncated = rowHidden[0..<outputDim]
            pooledRows.append(truncated)
        }

        // Stack into [batch, outputDim]
        let pooled = MLX.stacked(pooledRows)

        // L2 normalize each row
        let norms = sqrt(sum(pooled * pooled, axis: -1, keepDims: true))
        let normalized = pooled / (norms + 1e-12)

        return normalized
    }
}
