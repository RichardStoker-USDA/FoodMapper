import Foundation
import MLX
import MLXNN
import Tokenizers
import Hub
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "engine")

/// Resource bundle helper -- SPM vs .app bundle resolution
enum ResourceBundle {
    /// Checks multiple locations for the resource bundle
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        // SPM-generated Bundle.module
        if let moduleURL = Bundle.module.resourceURL,
           FileManager.default.fileExists(atPath: moduleURL.appendingPathComponent("Models").path) {
            return Bundle.module
        }
        #endif

        // Try looking for the SPM bundle in main bundle's Resources
        if let bundleURL = Bundle.main.url(forResource: "FoodMapper_FoodMapper", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL) {
            return bundle
        }

        // Fall back to main bundle (Xcode builds)
        return Bundle.main
    }

    /// Models directory in bundle (for bundled tokenizer files)
    static var bundledModelsDirectory: URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("Models")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Application Support directory for downloaded models
    static var applicationSupportModelDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FoodMapper/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Models directory - checks Application Support first (downloaded), then bundle
    static var modelsDirectory: URL? {
        // 1. Check Application Support (downloaded models)
        let downloadedWeights = applicationSupportModelDir.appendingPathComponent("gte-large.safetensors")
        if FileManager.default.fileExists(atPath: downloadedWeights.path) {
            return applicationSupportModelDir
        }

        // 2. Check for bundled safetensors (development)
        if let bundled = bundledModelsDirectory {
            let bundledWeights = bundled.appendingPathComponent("gte-large.safetensors")
            if FileManager.default.fileExists(atPath: bundledWeights.path) {
                return bundled
            }
        }

        // 3. Return bundled directory (tokenizer files still there)
        return bundledModelsDirectory
    }

    /// Databases directory in bundle
    static var databasesDirectory: URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("Databases")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// MLX-based embedding model for GTE-Large
/// Uses GPU/ANE acceleration on Apple Silicon
actor MLXEmbeddingModel: EmbeddingModelProtocol {
    private var model: BertModel?
    private var tokenizer: BertTokenizer?

    let executionProvider: String = "MLX (GPU)"

    // MARK: - EmbeddingModelProtocol

    nonisolated let info = EmbeddingModelInfo(
        key: "gte-large",
        displayName: "GTE-Large",
        dimensions: 1024,
        isAsymmetric: false
    )

    var isLoaded: Bool {
        model != nil && tokenizer != nil
    }

    // MARK: - Model Directory

    static var modelDirectory: URL? {
        ResourceBundle.modelsDirectory
    }

    /// Check if model weights file exists (safetensors format)
    static var isModelAvailable: Bool {
        guard let dir = modelDirectory else { return false }
        let weightsURL = dir.appendingPathComponent("gte-large.safetensors")
        return FileManager.default.fileExists(atPath: weightsURL.path)
    }

    /// Application Support directory for downloaded models
    static var downloadDirectory: URL {
        ResourceBundle.applicationSupportModelDir
    }

    // MARK: - Loading

    /// Load model and tokenizer from bundle
    func load() async throws {
        guard let modelDir = Self.modelDirectory else {
            throw EmbeddingError.modelNotFound
        }

        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw EmbeddingError.modelNotFound
        }

        // 1. Load config - try model dir first, then bundled models
        var configURL = modelDir.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: configURL.path),
           let bundled = ResourceBundle.bundledModelsDirectory {
            configURL = bundled.appendingPathComponent("config.json")
        }

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw EmbeddingError.configNotFound
        }

        let config = try BertConfiguration.load(from: configURL)

        // 2. Initialize model
        model = BertModel(config: config)

        // 3. Load weights (safetensors format)
        let weightsURL = modelDir.appendingPathComponent("gte-large.safetensors")
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw EmbeddingError.weightsNotFound
        }
        try loadWeights(from: weightsURL)

        // 4. Load tokenizer - try model dir first, then bundled models
        var tokenizerDir = modelDir
        let tokenizerFile = modelDir.appendingPathComponent("tokenizer.json")
        if !FileManager.default.fileExists(atPath: tokenizerFile.path),
           let bundled = ResourceBundle.bundledModelsDirectory {
            tokenizerDir = bundled
        }

        tokenizer = try await BertTokenizer(modelFolder: tokenizerDir)

        logger.info("MLX GTE-Large model loaded successfully")
    }

    /// Load weights from safetensors file
    private func loadWeights(from url: URL) throws {
        guard let model = model else {
            throw EmbeddingError.modelNotLoaded
        }

        // Load weights using MLX (safetensors format)
        let weights = try loadArrays(url: url)

        // Remap snake_case keys to camelCase for MLX-Swift compatibility
        let remappedWeights = remapWeightKeys(weights)

        // Convert flat dictionary to ModuleParameters (NestedDictionary)
        let parameters = ModuleParameters.unflattened(remappedWeights)

        // Apply weights - use .noUnusedKeys to catch any remaining mismatches
        try model.update(parameters: parameters, verify: .noUnusedKeys)

        logger.info("Loaded \(weights.count) weight tensors")
    }

    /// snake_case -> camelCase key remapping for MLX-Swift
    private func remapWeightKeys(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var remapped: [String: MLXArray] = [:]

        for (key, value) in weights {
            var newKey = key

            // Embedding layer mappings
            newKey = newKey.replacingOccurrences(of: "word_embeddings", with: "wordEmbeddings")
            newKey = newKey.replacingOccurrences(of: "position_embeddings", with: "positionEmbeddings")
            newKey = newKey.replacingOccurrences(of: "token_type_embeddings", with: "tokenTypeEmbeddings")

            // Attention projection mappings
            newKey = newKey.replacingOccurrences(of: "query_proj", with: "queryProj")
            newKey = newKey.replacingOccurrences(of: "key_proj", with: "keyProj")
            newKey = newKey.replacingOccurrences(of: "value_proj", with: "valueProj")
            newKey = newKey.replacingOccurrences(of: "out_proj", with: "outProj")

            remapped[newKey] = value
        }

        return remapped
    }

    // MARK: - Embedding

    /// Generate embedding for single text
    func embed(_ text: String) async throws -> [Float] {
        guard let model = model, let tokenizer = tokenizer else {
            throw EmbeddingError.modelNotLoaded
        }

        // Tokenize
        let encoding = tokenizer.encode(text)
        let inputIds = MLXArray(encoding.ids.map { Int32($0) })
            .reshaped([1, encoding.ids.count])  // Add batch dimension
        let attentionMask = MLXArray(encoding.attentionMask.map { Int32($0) })
            .reshaped([1, encoding.attentionMask.count])

        // Forward pass
        let output = model(inputIds, attentionMask: attentionMask)

        // CRITICAL: GTE-Large uses Mean Pooling (NOT CLS token)
        let embedding = meanPooling(output.lastHiddenState, attentionMask: attentionMask)

        // L2 normalize
        let normalized = l2Normalize(embedding)

        // Evaluate and return
        eval(normalized)
        return normalized.squeezed().asArray(Float.self)
    }

    /// Protocol-conforming batch embedding. GTE-Large is symmetric; isQuery is ignored.
    func embedBatch(_ texts: [String], batchSize: Int, isQuery: Bool) async throws -> [[Float]] {
        try await embedBatch(texts, batchSize: batchSize)
    }

    /// Protocol-conforming matrix embedding. GTE-Large is symmetric; isQuery is ignored.
    func embedBatchAsMatrix(_ texts: [String], batchSize: Int, isQuery: Bool) async throws -> MLXArray {
        try await embedBatchAsMatrix(texts, batchSize: batchSize)
    }

    /// Protocol-conforming direct embedding. GTE-Large is symmetric; isQuery is ignored.
    func embedBatchDirect(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        try await embedBatchDirect(texts)
    }

    /// Batch embedding with true GPU batching for efficiency
    func embedBatch(_ texts: [String], batchSize: Int = 32) async throws -> [[Float]] {
        guard let model = model, let tokenizer = tokenizer else {
            throw EmbeddingError.modelNotLoaded
        }

        var allEmbeddings: [[Float]] = []
        allEmbeddings.reserveCapacity(texts.count)
        let embeddingDim = 1024  // GTE-Large hidden size

        for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
            // Check for cancellation between sub-batches
            try Task.checkCancellation()

            let batchEnd = min(batchStart + batchSize, texts.count)
            let batch = Array(texts[batchStart..<batchEnd])

            // Batch tokenization with padding
            let batchEncoding = tokenizer.encodeBatch(batch)

            // Single forward pass for entire batch
            let output = model(batchEncoding.ids, attentionMask: batchEncoding.attentionMask)

            // Mean pooling (handles [batch, seq, hidden] -> [batch, hidden])
            let pooled = meanPooling(output.lastHiddenState, attentionMask: batchEncoding.attentionMask)

            // L2 normalize
            let normalized = l2Normalize(pooled)

            // Evaluate and extract
            eval(normalized)
            let tensorArray = normalized.asArray(Float.self)

            // Split into individual embeddings
            for i in 0..<batch.count {
                let start = i * embeddingDim
                let end = start + embeddingDim
                allEmbeddings.append(Array(tensorArray[start..<end]))
            }
        }

        return allEmbeddings
    }

    /// Single-batch embed, no accumulation. For streaming to disk one batch at a time.
    func embedBatchDirect(_ texts: [String]) async throws -> [[Float]] {
        guard let model = model, let tokenizer = tokenizer else {
            throw EmbeddingError.modelNotLoaded
        }

        let embeddingDim = 1024

        // Single forward pass for entire batch
        let batchEncoding = tokenizer.encodeBatch(texts)
        let output = model(batchEncoding.ids, attentionMask: batchEncoding.attentionMask)
        let pooled = meanPooling(output.lastHiddenState, attentionMask: batchEncoding.attentionMask)
        let normalized = l2Normalize(pooled)

        // Evaluate and extract
        eval(normalized)
        let tensorArray = normalized.asArray(Float.self)

        // Split into individual embeddings
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(texts.count)
        for i in 0..<texts.count {
            let start = i * embeddingDim
            let end = start + embeddingDim
            embeddings.append(Array(tensorArray[start..<end]))
        }

        return embeddings
    }

    /// Batch embed -> MLXArray [N, 1024] for GPU matmul similarity.
    /// Single eval() at the end to keep MLX lazy evaluation happy.
    func embedBatchAsMatrix(_ texts: [String], batchSize: Int = 48) async throws -> MLXArray {
        guard let model = model, let tokenizer = tokenizer else {
            throw EmbeddingError.modelNotLoaded
        }

        // For small batches, process in single forward pass (most efficient)
        if texts.count <= batchSize {
            let batchEncoding = tokenizer.encodeBatch(texts)
            let output = model(batchEncoding.ids, attentionMask: batchEncoding.attentionMask)
            let pooled = meanPooling(output.lastHiddenState, attentionMask: batchEncoding.attentionMask)
            let normalized = l2Normalize(pooled)
            eval(normalized)  // Single eval for entire batch
            return normalized
        }

        // For larger batches, process in chunks but concatenate before eval
        var allEmbeddings: [MLXArray] = []
        allEmbeddings.reserveCapacity((texts.count + batchSize - 1) / batchSize)

        for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
            try Task.checkCancellation()

            let batchEnd = min(batchStart + batchSize, texts.count)
            let batch = Array(texts[batchStart..<batchEnd])

            let batchEncoding = tokenizer.encodeBatch(batch)
            let output = model(batchEncoding.ids, attentionMask: batchEncoding.attentionMask)
            let pooled = meanPooling(output.lastHiddenState, attentionMask: batchEncoding.attentionMask)
            let normalized = l2Normalize(pooled)

            // Don't eval() here - let MLX build the computation graph
            allEmbeddings.append(normalized)
        }

        // Concatenate all batches into single matrix [total_texts, 1024]
        let result = concatenated(allEmbeddings, axis: 0)

        // Single eval() call for entire operation - triggers optimized GPU execution
        eval(result)
        return result
    }

    // MARK: - Private Helpers

    /// Mean pooling over token embeddings (masked by attention)
    private func meanPooling(_ hiddenState: MLXArray, attentionMask: MLXArray) -> MLXArray {
        // hiddenState: [batch, seq_len, hidden_dim]
        // attentionMask: [batch, seq_len]

        // Expand attention mask to match hidden state dimensions
        let maskExpanded = attentionMask.expandedDimensions(axis: -1)
            .asType(hiddenState.dtype)

        // Masked sum
        let sumEmbeddings = (hiddenState * maskExpanded).sum(axis: 1)

        // Sum of mask (for averaging)
        let sumMask = MLX.maximum(maskExpanded.sum(axis: 1), MLXArray(1e-9))

        return sumEmbeddings / sumMask
    }

    /// L2 normalization
    private func l2Normalize(_ vector: MLXArray) -> MLXArray {
        let norm = MLX.maximum(sqrt((vector * vector).sum(axis: -1, keepDims: true)), MLXArray(1e-12))
        return vector / norm
    }
}

// MARK: - Errors

enum EmbeddingError: LocalizedError {
    case modelNotFound
    case modelNotLoaded
    case invalidOutput
    case configNotFound
    case weightsNotFound
    case tokenizerNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "MLX embedding model not found in bundle"
        case .modelNotLoaded: return "Model not loaded - call load() first"
        case .invalidOutput: return "Model returned invalid embedding dimensions"
        case .configNotFound: return "Model config.json not found"
        case .weightsNotFound: return "Model weights (gte-large.safetensors) not found"
        case .tokenizerNotFound: return "Tokenizer files not found"
        }
    }
}

// MARK: - BERT Model Implementation

/// BERT configuration loaded from config.json
struct BertConfiguration: Codable {
    let vocabSize: Int
    let hiddenSize: Int
    let numHiddenLayers: Int
    let numAttentionHeads: Int
    let intermediateSize: Int
    let hiddenDropoutProb: Double
    let attentionProbsDropoutProb: Double
    let maxPositionEmbeddings: Int
    let typeVocabSize: Int
    let layerNormEps: Double

    enum CodingKeys: String, CodingKey {
        case vocabSize = "vocab_size"
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case numAttentionHeads = "num_attention_heads"
        case intermediateSize = "intermediate_size"
        case hiddenDropoutProb = "hidden_dropout_prob"
        case attentionProbsDropoutProb = "attention_probs_dropout_prob"
        case maxPositionEmbeddings = "max_position_embeddings"
        case typeVocabSize = "type_vocab_size"
        case layerNormEps = "layer_norm_eps"
    }

    static func load(from url: URL) throws -> BertConfiguration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BertConfiguration.self, from: data)
    }
}

/// BERT Embeddings layer
class BertEmbeddings: Module {
    let wordEmbeddings: Embedding
    let positionEmbeddings: Embedding
    let tokenTypeEmbeddings: Embedding
    let norm: LayerNorm

    init(config: BertConfiguration) {
        wordEmbeddings = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        positionEmbeddings = Embedding(embeddingCount: config.maxPositionEmbeddings, dimensions: config.hiddenSize)
        tokenTypeEmbeddings = Embedding(embeddingCount: config.typeVocabSize, dimensions: config.hiddenSize)
        norm = LayerNorm(dimensions: config.hiddenSize, eps: Float(config.layerNormEps))
    }

    func callAsFunction(_ inputIds: MLXArray, tokenTypeIds: MLXArray? = nil, positionIds: MLXArray? = nil) -> MLXArray {
        let batchSize = inputIds.dim(0)
        let seqLength = inputIds.dim(1)

        // Position IDs - construct array properly for MLX-Swift
        let positions: MLXArray
        if let positionIds = positionIds {
            positions = positionIds
        } else {
            let posArray = Array(0..<seqLength).map { Int32($0) }
            let singlePos = MLXArray(posArray).reshaped([1, seqLength])
            // Broadcast to actual batch size
            positions = MLX.broadcast(singlePos, to: [batchSize, seqLength])
        }

        // Token type IDs (default to 0) - broadcast to batch size
        let tokenTypes = tokenTypeIds ?? MLXArray.zeros([batchSize, seqLength]).asType(.int32)

        // Embeddings
        var embeddings = wordEmbeddings(inputIds)
        embeddings = embeddings + positionEmbeddings(positions)
        embeddings = embeddings + tokenTypeEmbeddings(tokenTypes)

        return norm(embeddings)
    }
}

/// BERT Self-Attention
class BertSelfAttention: Module {
    let queryProj: Linear
    let keyProj: Linear
    let valueProj: Linear
    let outProj: Linear
    let numHeads: Int
    let headDim: Int

    init(config: BertConfiguration) {
        let hiddenSize = config.hiddenSize
        numHeads = config.numAttentionHeads
        headDim = hiddenSize / numHeads

        queryProj = Linear(hiddenSize, hiddenSize)
        keyProj = Linear(hiddenSize, hiddenSize)
        valueProj = Linear(hiddenSize, hiddenSize)
        outProj = Linear(hiddenSize, hiddenSize)
    }

    func callAsFunction(_ x: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        let batchSize = x.dim(0)
        let seqLen = x.dim(1)

        // QKV projections
        var q = queryProj(x)
        var k = keyProj(x)
        var v = valueProj(x)

        // Reshape for multi-head attention
        q = q.reshaped([batchSize, seqLen, numHeads, headDim]).transposed(0, 2, 1, 3)
        k = k.reshaped([batchSize, seqLen, numHeads, headDim]).transposed(0, 2, 1, 3)
        v = v.reshaped([batchSize, seqLen, numHeads, headDim]).transposed(0, 2, 1, 3)

        // Attention scores
        var scores = matmul(q, k.transposed(0, 1, 3, 2)) / sqrt(Float(headDim))

        // Apply mask if provided
        if let mask = attentionMask {
            // mask: [batch, seq_len] -> [batch, 1, 1, seq_len]
            let expandedMask = mask.reshaped([batchSize, 1, 1, seqLen])
            scores = scores + (1.0 - expandedMask.asType(.float32)) * -1e9
        }

        // Softmax and apply to values
        let attnWeights = softmax(scores, axis: -1)
        var attnOutput = matmul(attnWeights, v)

        // Reshape back
        attnOutput = attnOutput.transposed(0, 2, 1, 3).reshaped([batchSize, seqLen, -1])

        return outProj(attnOutput)
    }
}

/// BERT Encoder Layer
class BertEncoderLayer: Module {
    let attention: BertSelfAttention
    let ln1: LayerNorm
    let ln2: LayerNorm
    let linear1: Linear
    let linear2: Linear

    init(config: BertConfiguration) {
        attention = BertSelfAttention(config: config)
        ln1 = LayerNorm(dimensions: config.hiddenSize, eps: Float(config.layerNormEps))
        ln2 = LayerNorm(dimensions: config.hiddenSize, eps: Float(config.layerNormEps))
        linear1 = Linear(config.hiddenSize, config.intermediateSize)
        linear2 = Linear(config.intermediateSize, config.hiddenSize)
    }

    func callAsFunction(_ x: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        // Self-attention with residual
        var hidden = x + attention(x, attentionMask: attentionMask)
        hidden = ln1(hidden)

        // FFN with residual
        let ffn = linear2(gelu(linear1(hidden)))
        hidden = hidden + ffn
        hidden = ln2(hidden)

        return hidden
    }
}

/// BERT Encoder (stack of layers)
class BertEncoder: Module {
    let layers: [BertEncoderLayer]

    init(config: BertConfiguration) {
        layers = (0..<config.numHiddenLayers).map { _ in
            BertEncoderLayer(config: config)
        }
    }

    func callAsFunction(_ x: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        var hidden = x
        for layer in layers {
            hidden = layer(hidden, attentionMask: attentionMask)
        }
        return hidden
    }
}

/// BERT Model Output
struct BertModelOutput {
    let lastHiddenState: MLXArray
    let poolerOutput: MLXArray?
}

/// Full BERT Model
class BertModel: Module {
    let embeddings: BertEmbeddings
    let encoder: BertEncoder
    let pooler: Linear?

    init(config: BertConfiguration, addPoolingLayer: Bool = true) {
        embeddings = BertEmbeddings(config: config)
        encoder = BertEncoder(config: config)
        pooler = addPoolingLayer ? Linear(config.hiddenSize, config.hiddenSize) : nil
    }

    func callAsFunction(_ inputIds: MLXArray, attentionMask: MLXArray? = nil, tokenTypeIds: MLXArray? = nil) -> BertModelOutput {
        let embeddingOutput = embeddings(inputIds, tokenTypeIds: tokenTypeIds)
        let encoderOutput = encoder(embeddingOutput, attentionMask: attentionMask)

        var poolerOutput: MLXArray? = nil
        if let pooler = pooler {
            // Pool from [CLS] token (position 0)
            // encoderOutput: [batch, seq_len, hidden] -> extract [batch, hidden] at seq position 0
            let clsOutput = encoderOutput.take(MLXArray([0]), axis: 1).squeezed(axis: 1)
            poolerOutput = tanh(pooler(clsOutput))
        }

        return BertModelOutput(
            lastHiddenState: encoderOutput,
            poolerOutput: poolerOutput
        )
    }
}

// MARK: - BERT Tokenizer

/// Simple BERT tokenizer using swift-transformers
class BertTokenizer {
    private let tokenizer: Tokenizer

    struct Encoding {
        let ids: [Int]
        let attentionMask: [Int]
    }

    struct BatchEncoding {
        let ids: MLXArray           // [batch_size, max_seq_len]
        let attentionMask: MLXArray // [batch_size, max_seq_len]
    }

    init(modelFolder: URL) async throws {
        tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder)
    }

    func encode(_ text: String, maxLength: Int = 512) -> Encoding {
        let encoded = tokenizer.encode(text: text)

        // Truncate if needed
        var ids = encoded
        if ids.count > maxLength {
            ids = Array(ids.prefix(maxLength))
        }

        // Create attention mask
        let attentionMask = [Int](repeating: 1, count: ids.count)

        return Encoding(ids: ids, attentionMask: attentionMask)
    }

    /// Batch encode multiple texts with padding
    func encodeBatch(_ texts: [String], maxLength: Int = 512) -> BatchEncoding {
        // Encode each text individually
        let encodings = texts.map { encode($0, maxLength: maxLength) }

        // Find max length in this batch
        let maxLen = encodings.map { $0.ids.count }.max() ?? 1

        // Pad to max length
        var paddedIds: [[Int32]] = []
        var paddedMasks: [[Int32]] = []

        for encoding in encodings {
            var ids = encoding.ids.map { Int32($0) }
            var mask = encoding.attentionMask.map { Int32($0) }

            // Pad with zeros (PAD token = 0)
            while ids.count < maxLen {
                ids.append(0)
                mask.append(0)
            }

            paddedIds.append(ids)
            paddedMasks.append(mask)
        }

        // Create [batch_size, max_seq_len] tensors
        let flatIds = paddedIds.flatMap { $0 }
        let flatMasks = paddedMasks.flatMap { $0 }

        let idsArray = MLXArray(flatIds).reshaped([texts.count, maxLen])
        let maskArray = MLXArray(flatMasks).reshaped([texts.count, maxLen])

        return BatchEncoding(ids: idsArray, attentionMask: maskArray)
    }
}
