import XCTest
import MLX
import MLXNN
@testable import FoodMapper

/// Sanity checks for GTE-Large running on MLX.
/// Had to switch from CLS token to mean pooling -- was getting all rando
/// scores until that clicked. # ml-explore examples saved me here
final class EmbeddingTests: XCTestCase {

    /// 1024-dim vector, L2-normalized. If this breaks, model load or
    /// pooling step is wrong.
    func testEmbeddingDimensions() async throws {
        let model = MLXEmbeddingModel()
        try await model.load()

        let embedding = try await model.embed("red wine, table")

        XCTAssertEqual(embedding.count, 1024, "Expected 1024 dimensions")

        // Norm should be ~1.0 after L2 normalization
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.001, "Expected L2 norm ~1.0")
    }

    /// Batch embed -- make sure every vector in the batch has the right
    /// shape and normalization.
    func testBatchEmbedding() async throws {
        let model = MLXEmbeddingModel()
        try await model.load()

        let texts = [
            "apple, fresh, raw",
            "chicken breast, roasted",
            "milk, whole"
        ]

        let embeddings = try await model.embedBatch(texts)
        XCTAssertEqual(embeddings.count, texts.count)

        for emb in embeddings {
            XCTAssertEqual(emb.count, 1024)
            let norm = sqrt(emb.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(norm, 1.0, accuracy: 0.001)
        }
    }

    /// Obvious duh moment, but needed to verify: similar foods should score
    /// higher than unrelated ones. "red wine" vs "white wine" better beat
    /// "red wine" vs "chicken breast" or something is very wrong around here...
    func testSemanticSimilarity() async throws {
        let model = MLXEmbeddingModel()
        try await model.load()

        let redWine = try await model.embed("red wine")
        let whiteWine = try await model.embed("white wine")
        let chickenBreast = try await model.embed("chicken breast")

        let wineWineSim = cosineSimilarity(redWine, whiteWine)
        let wineChickenSim = cosineSimilarity(redWine, chickenBreast)

        print("Red wine vs White wine: \(wineWineSim)")
        print("Red wine vs Chicken: \(wineChickenSim)")

        XCTAssertGreaterThan(wineWineSim, wineChickenSim,
            "Wines should be more similar to each other than to chicken")
        XCTAssertGreaterThan(wineWineSim, 0.8, "Wine types should have high similarity")
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let normA = sqrt(a.reduce(0) { $0 + $1 * $1 })
        let normB = sqrt(b.reduce(0) { $0 + $1 * $1 })
        return dot / (normA * normB)
    }
}
