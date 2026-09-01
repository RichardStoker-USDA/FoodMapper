import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXNN
import Tokenizers
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "nomic-embedding")

actor NomicEmbeddingModel: EmbeddingModelProtocol {
    static let repository = "nomic-ai/nomic-embed-text-v1.5"
    static let revision = "e9b6763023c676ca8431644204f50c2b100d9aab"

    nonisolated let info = EmbeddingModelInfo(
        key: "nomic-embed-text-v1.5",
        displayName: "Nomic Embed Text v1.5",
        dimensions: 768,
        isAsymmetric: true
    )

    private var container: MLXEmbedders.ModelContainer?
    private var matchingInstruction: String?

    var isLoaded: Bool { container != nil }

    func load() async throws {
        throw EmbeddingError.modelNotFound
    }

    func load(snapshot: VerifiedLocalModelSnapshot) async throws {
        guard snapshot.isIssuedByDownloader,
              snapshot.repository == Self.repository,
              snapshot.revision == Self.revision else {
            throw EmbeddingError.modelNotFound
        }
        try snapshot.revalidate()
        container = try await loadModelContainer(snapshot: snapshot)
        logger.info("Nomic Embed Text v1.5 loaded from a verified local snapshot")
    }

    /// Nomic v1.5 uses rotary position embeddings and ships no absolute-position
    /// weight. MLXEmbedders 2.30.6 builds both from the upstream config, so load
    /// the pinned snapshot with the absent absolute-position layer disabled.
    private nonisolated func loadModelContainer(
        snapshot: VerifiedLocalModelSnapshot
    ) async throws -> MLXEmbedders.ModelContainer {
        let directory = snapshot.directory
        let configuration = MLXEmbedders.ModelConfiguration(directory: directory)
        let configURL = directory.appendingPathComponent("config.json")
        let originalConfig = try Data(contentsOf: configURL)

        var weights: [String: MLXArray] = [:]
        for relativePath in snapshot.artifactPaths.sorted()
        where (relativePath as NSString).pathExtension == "safetensors" {
            for (key, value) in try loadArrays(url: directory.appendingPathComponent(relativePath)) {
                weights[key] = value
            }
        }

        guard var config = try JSONSerialization.jsonObject(with: originalConfig) as? [String: Any],
              config["model_type"] as? String == "nomic_bert",
              ((config["rotary_emb_fraction"] as? NSNumber)?.doubleValue ?? 0) > 0,
              !weights.keys.contains(where: { $0.hasSuffix("embeddings.position_embeddings.weight") }) else {
            throw EmbeddingError.modelNotFound
        }
        config["max_position_embeddings"] = 0
        let runtimeConfig = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])

        let baseConfig = try JSONDecoder().decode(MLXEmbedders.BaseConfiguration.self, from: runtimeConfig)
        let modelType = MLXEmbedders.ModelType(rawValue: baseConfig.modelType)
        let model = try modelType.createModel(configuration: runtimeConfig)
        weights = model.sanitize(weights: weights)
        let parameters = ModuleParameters.unflattened(weights)
        try model.update(parameters: parameters, verify: [.all])
        eval(model)

        let tokenizer = try await loadTokenizer(configuration: configuration, hub: HubApi())
        let poolingURL = directory.appendingPathComponent("1_Pooling/config.json")
        let poolingConfig = try JSONDecoder().decode(
            MLXEmbedders.PoolingConfiguration.self,
            from: Data(contentsOf: poolingURL)
        )
        return MLXEmbedders.ModelContainer(
            model: model,
            tokenizer: tokenizer,
            pooler: MLXEmbedders.Pooling(config: poolingConfig)
        )
    }

    func setInstruction(_ instruction: String?) async {
        let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        matchingInstruction = trimmed?.isEmpty == false ? trimmed : nil
    }

    func embedBatch(_ texts: [String], batchSize: Int, isQuery: Bool) async throws -> [[Float]] {
        guard let container else { throw EmbeddingError.modelNotLoaded }
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: max(1, batchSize)) {
            try Task.checkCancellation()
            let end = min(start + max(1, batchSize), texts.count)
            result.append(contentsOf: await embed(Array(texts[start..<end]), isQuery: isQuery, container: container))
        }
        return result
    }

    func embedBatchAsMatrix(_ texts: [String], batchSize: Int, isQuery: Bool) async throws -> MLXArray {
        guard let container else { throw EmbeddingError.modelNotLoaded }
        var matrices: [MLXArray] = []
        for start in stride(from: 0, to: texts.count, by: max(1, batchSize)) {
            try Task.checkCancellation()
            let end = min(start + max(1, batchSize), texts.count)
            matrices.append(await embedMatrix(Array(texts[start..<end]), isQuery: isQuery, container: container))
        }
        guard !matrices.isEmpty else { return MLXArray.zeros([0, info.dimensions]) }
        let value = matrices.count == 1 ? matrices[0] : concatenated(matrices, axis: 0)
        eval(value)
        return value
    }

    func embedBatchDirect(_ texts: [String], isQuery: Bool) async throws -> [[Float]] {
        guard let container else { throw EmbeddingError.modelNotLoaded }
        return await embed(texts, isQuery: isQuery, container: container)
    }

    private func formatted(_ text: String, isQuery: Bool) -> String {
        if isQuery {
            if let matchingInstruction {
                return "search_query: \(matchingInstruction). \(text)"
            }
            return "search_query: \(text)"
        }
        return "search_document: \(text)"
    }

    private func embed(
        _ texts: [String],
        isQuery: Bool,
        container: MLXEmbedders.ModelContainer
    ) async -> [[Float]] {
        let matrix = await embedMatrix(texts, isQuery: isQuery, container: container)
        eval(matrix)
        let values = matrix.asArray(Float.self)
        return texts.indices.map { index in
            let start = index * info.dimensions
            return Array(values[start..<(start + info.dimensions)])
        }
    }

    private func embedMatrix(
        _ texts: [String],
        isQuery: Bool,
        container: MLXEmbedders.ModelContainer
    ) async -> MLXArray {
        let formattedTexts = texts.map { formatted($0, isQuery: isQuery) }
        return await container.perform { model, tokenizer, pooling in
            let encoded = formattedTexts.map {
                tokenizer.encode(text: $0, addSpecialTokens: true)
            }
            let maximumLength = encoded.reduce(16) { max($0, $1.count) }
            let paddingToken = tokenizer.eosTokenId ?? 0
            let padded = stacked(encoded.map { tokens in
                MLXArray(tokens + Array(repeating: paddingToken, count: maximumLength - tokens.count))
            })
            let mask = padded .!= paddingToken
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = model(
                padded,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: mask
            )
            let value = pooling(output, mask: mask, normalize: true, applyLayerNorm: true)
            eval(value)
            return value
        }
    }
}
