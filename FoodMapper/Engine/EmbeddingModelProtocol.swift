import Foundation
import MLX

/// Metadata describing an embedding model's capabilities
struct EmbeddingModelInfo {
    /// Unique key for cache versioning (e.g., "gte-large", "qwen3-emb-4b-4bit")
    let key: String
    /// Human-readable name (e.g., "GTE-Large", "Qwen3-Embedding 0.6B")
    let displayName: String
    /// Output embedding dimensions (e.g., 1024)
    let dimensions: Int
    /// Whether the model uses different encoding for queries vs documents.
    /// Asymmetric models prepend an instruction prefix to queries but not to documents.
    let isAsymmetric: Bool
}

/// Embedding model protocol. Actors only (thread-safe model access).
/// `isQuery` lets asymmetric models (Qwen3) prepend instructions to queries.
/// Symmetric models (GTE-Large) ignore it.
protocol EmbeddingModelProtocol: Actor {
    /// Model metadata and capabilities (immutable, safe to access from any context)
    nonisolated var info: EmbeddingModelInfo { get }

    /// Whether the model is loaded and ready for inference
    var isLoaded: Bool { get }

    /// Load model weights and tokenizer into memory
    func load() async throws

    /// Embed a batch of texts, processing in sub-batches of `batchSize`.
    /// Returns an array of embedding vectors.
    ///
    /// - Parameters:
    ///   - texts: Input texts to embed
    ///   - batchSize: Maximum texts per GPU batch
    ///   - isQuery: If true and model is asymmetric, prepend instruction prefix
    func embedBatch(_ texts: [String], batchSize: Int, isQuery: Bool) async throws -> [[Float]]

    /// Embed a batch of texts, returning an MLXArray matrix [N, dimensions].
    /// Preferred for GPU-based similarity computation.
    ///
    /// - Parameters:
    ///   - texts: Input texts to embed
    ///   - batchSize: Maximum texts per GPU batch
    ///   - isQuery: If true and model is asymmetric, prepend instruction prefix
    func embedBatchAsMatrix(_ texts: [String], batchSize: Int, isQuery: Bool) async throws -> MLXArray

    /// Embed a single batch directly without internal accumulation.
    /// Used for streaming to disk one batch at a time.
    ///
    /// - Parameters:
    ///   - texts: Input texts (should be a single batch worth)
    ///   - isQuery: If true and model is asymmetric, prepend instruction prefix
    func embedBatchDirect(_ texts: [String], isQuery: Bool) async throws -> [[Float]]

    /// Set a custom matching instruction for asymmetric models.
    /// Symmetric models (like GTE-Large) ignore this.
    func setInstruction(_ instruction: String?) async
}

// MARK: - Default Implementations

extension EmbeddingModelProtocol {
    /// Default no-op for symmetric models that don't support instructions
    func setInstruction(_ instruction: String?) async { }
    /// Convenience: embed batch without isQuery (defaults to false for document embedding)
    func embedBatch(_ texts: [String], batchSize: Int) async throws -> [[Float]] {
        try await embedBatch(texts, batchSize: batchSize, isQuery: false)
    }

    /// Convenience: embed as matrix without isQuery (defaults to false)
    func embedBatchAsMatrix(_ texts: [String], batchSize: Int) async throws -> MLXArray {
        try await embedBatchAsMatrix(texts, batchSize: batchSize, isQuery: false)
    }

    /// Convenience: embed direct without isQuery (defaults to false)
    func embedBatchDirect(_ texts: [String]) async throws -> [[Float]] {
        try await embedBatchDirect(texts, isQuery: false)
    }
}
