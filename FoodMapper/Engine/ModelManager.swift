import Foundation
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "model-manager")

/// Lifecycle state of a model
enum ModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case loaded
    case error(String)

    var isAvailable: Bool {
        switch self {
        case .downloaded, .loaded: return true
        default: return false
        }
    }

    var isLoaded: Bool {
        self == .loaded
    }
}

/// Registration entry for a known model
struct RegisteredModel: Identifiable {
    let key: String
    let displayName: String
    let modelFamily: ModelFamily
    let sizeCategory: ModelSizeCategory
    /// HuggingFace repo ID for download (nil for bundled models)
    let repoId: String?
    /// Approximate download size in bytes
    let downloadSize: Int64?
    /// Approximate GPU memory usage in bytes
    let gpuMemoryUsage: Int64?
    /// Minimum hardware profile to use this model comfortably
    let minimumProfile: HardwareProfile

    var id: String { key }

    /// Whether this model is bundled with the app (no download needed)
    var isBundled: Bool { repoId == nil }
}

/// Model family grouping
enum ModelFamily: String, CaseIterable {
    case gteLarge = "GTE-Large"
    case qwen3Embedding = "Qwen3-Embedding"
    case qwen3Reranker = "Qwen3-Reranker"
    case qwen3Generative = "Qwen3-Generative"
}

/// Model size categories
enum ModelSizeCategory: String, CaseIterable {
    case small = "0.6B"
    case medium = "4B"
    case large = "8B"
    case legacy = "Legacy"
}

/// Model registry + download/load/unload lifecycle.
@MainActor
final class ModelManager: ObservableObject {
    /// All registered models the app knows about
    @Published private(set) var registeredModels: [RegisteredModel] = []

    /// Current state of each model (keyed by model key)
    @Published private(set) var modelStates: [String: ModelState] = [:]

    /// Currently loaded embedding model (only one at a time)
    private(set) var loadedEmbeddingModel: (any EmbeddingModelProtocol)?

    /// Currently loaded reranker model
    private(set) var loadedRerankerModel: QwenRerankerModel?

    /// Currently loaded generative judge model
    private(set) var loadedGenerativeModel: GenerativeJudgeModel?

    /// Hardware configuration for memory-aware decisions
    let hardwareConfig: HardwareConfig

    /// Shared downloader for HuggingFace Hub models
    let downloader = ModelDownloader()

    /// Model keys with a pending user cancel request.
    /// Checked at safe boundaries during download work.
    private var cancelledDownloadKeys: Set<String> = []

    init(hardwareConfig: HardwareConfig) {
        self.hardwareConfig = hardwareConfig
        registerKnownModels()
        cleanupLegacyModels()
        detectInstalledModels()
    }

    // MARK: - Legacy Cleanup

    /// Remove old model downloads that are no longer part of the registry.
    /// Runs once at init before detectInstalledModels().
    private func cleanupLegacyModels() {
        let legacyRepos = [
            "vqstudio/Qwen3-Reranker-0.6B-MLX-4bit",
            "mlx-community/Qwen3-Embedding-4B-mxfp8",
        ]
        for repoId in legacyRepos {
            if downloader.isDownloaded(repoId: repoId) {
                let path = downloader.localPath(for: repoId)
                try? FileManager.default.removeItem(at: path)
                logger.info("Cleaned up legacy model: \(repoId)")
            }
        }

        // Clean up old double-nested "Models/models/" directory from previous downloadBase bug.
        // Hub library appends "models/" to downloadBase; the old code set downloadBase to
        // FoodMapper/Models/, producing FoodMapper/Models/models/{org}/{repo}/.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldNestedModels = appSupport
            .appendingPathComponent("FoodMapper/Models/models", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldNestedModels.path) {
            try? FileManager.default.removeItem(at: oldNestedModels)
            logger.info("Cleaned up old nested Models/models/ directory")
        }
    }

    // MARK: - Model Registry

    private func registerKnownModels() {
        registeredModels = [
            RegisteredModel(
                key: "gte-large",
                displayName: "GTE-Large",
                modelFamily: .gteLarge,
                sizeCategory: .legacy,
                repoId: "richtext/foodmapper-gte-large",
                downloadSize: 640_000_000,
                gpuMemoryUsage: 700_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "qwen3-emb-0.6b-4bit",
                displayName: "Qwen3-Embedding 0.6B",
                modelFamily: .qwen3Embedding,
                sizeCategory: .small,
                repoId: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
                downloadSize: 351_000_000,
                gpuMemoryUsage: 500_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "qwen3-emb-4b-4bit",
                displayName: "Qwen3-Embedding 4B",
                modelFamily: .qwen3Embedding,
                sizeCategory: .medium,
                repoId: "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
                downloadSize: 2_280_000_000,
                gpuMemoryUsage: 2_500_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "qwen3-emb-8b-4bit",
                displayName: "Qwen3-Embedding 8B",
                modelFamily: .qwen3Embedding,
                sizeCategory: .large,
                repoId: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
                downloadSize: 4_500_000_000,
                gpuMemoryUsage: 5_000_000_000,
                minimumProfile: .standard
            ),
            RegisteredModel(
                key: "qwen3-reranker-0.6b",
                displayName: "Qwen3-Reranker 0.6B",
                modelFamily: .qwen3Reranker,
                sizeCategory: .small,
                repoId: "richtext/Qwen3-Reranker-0.6B-mlx-fp16",
                downloadSize: 1_200_000_000,
                gpuMemoryUsage: 1_200_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "qwen3-reranker-4b",
                displayName: "Qwen3-Reranker 4B",
                modelFamily: .qwen3Reranker,
                sizeCategory: .medium,
                repoId: "richtext/Qwen3-Reranker-4B-mlx-4bit",
                downloadSize: 2_300_000_000,
                gpuMemoryUsage: 2_500_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "qwen3-judge-0.6b-4bit",
                displayName: "Qwen3-Judge 0.6B",
                modelFamily: .qwen3Generative,
                sizeCategory: .small,
                repoId: "mlx-community/Qwen3-0.6B-4bit",
                downloadSize: 351_000_000,
                gpuMemoryUsage: 500_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "qwen3-judge-4b-4bit",
                displayName: "Qwen3-Judge 4B",
                modelFamily: .qwen3Generative,
                sizeCategory: .medium,
                repoId: "mlx-community/Qwen3-4B-4bit",
                downloadSize: 2_280_000_000,
                gpuMemoryUsage: 2_500_000_000,
                minimumProfile: .base
            ),
        ]
    }

    /// Check which models are already downloaded/available
    private func detectInstalledModels() {
        for model in registeredModels {
            switch model.key {
            case "gte-large":
                modelStates[model.key] = MLXEmbeddingModel.isModelAvailable ? .downloaded : .notDownloaded
            default:
                if let repoId = model.repoId, downloader.isDownloaded(repoId: repoId) {
                    modelStates[model.key] = .downloaded
                } else {
                    modelStates[model.key] = .notDownloaded
                }
            }
        }
    }

    // MARK: - Model Access

    /// Get the state of a specific model
    func state(for key: String) -> ModelState {
        modelStates[key] ?? .notDownloaded
    }

    /// Whether all models required by a pipeline are available (downloaded or loaded)
    func areModelsAvailable(for pipelineType: PipelineType) -> Bool {
        pipelineType.requiredModelKeys.allSatisfy { key in
            state(for: key).isAvailable
        }
    }

    /// Get the registered model info for a key
    func registeredModel(for key: String) -> RegisteredModel? {
        registeredModels.first(where: { $0.key == key })
    }

    /// Recommended pipeline based on hardware and available models
    var recommendedPipeline: PipelineType {
        // Prefer Qwen3 two-stage if both models available
        if areModelsAvailable(for: .qwen3TwoStage) {
            return .qwen3TwoStage
        }
        // Fall back to Qwen3 embedding-only
        if areModelsAvailable(for: .qwen3Embedding) {
            return .qwen3Embedding
        }
        // Default to GTE-Large
        return .gteLargeEmbedding
    }

    // MARK: - Download

    /// Mark an in-flight download for cancellation.
    /// The download task should also be cancelled by the caller for fastest stop.
    func cancelDownload(key: String) {
        cancelledDownloadKeys.insert(key)
    }

    /// Download a model by key with progress reporting
    func downloadModel(key: String) async throws {
        guard let registration = registeredModel(for: key),
              let repoId = registration.repoId else {
            throw ModelManagerError.unknownModel(key)
        }

        cancelledDownloadKeys.remove(key)
        modelStates[key] = .downloading(progress: 0)

        do {
            if key == "gte-large" {
                // GTE-Large uses flat file layout (individual files to Models/)
                try await downloadGTELarge(modelKey: key)
            } else {
                // Other models use Hub snapshot (nested {org}/{repo}/ directories)
                _ = try await downloader.download(repoId: repoId) { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        guard !self.shouldCancelDownload(for: key) else { return }
                        self.modelStates[key] = .downloading(progress: progress)
                    }
                }
                try throwIfDownloadCancelled(for: key)
            }
            cancelledDownloadKeys.remove(key)
            modelStates[key] = .downloaded
            logger.info("Downloaded model: \(key)")
        } catch is CancellationError {
            if key != "gte-large" {
                try? await downloader.deleteModel(repoId: repoId)
            }
            cancelledDownloadKeys.remove(key)
            modelStates[key] = .notDownloaded
            logger.info("Cancelled model download: \(key)")
        } catch {
            cancelledDownloadKeys.remove(key)
            modelStates[key] = .error(error.localizedDescription)
            throw error
        }
    }

    /// Delete a downloaded model
    func deleteModel(key: String) async throws {
        guard let registration = registeredModel(for: key),
              registration.repoId != nil else {
            throw ModelManagerError.unknownModel(key)
        }

        // Unload if currently loaded (embedding, reranker, or generative)
        if loadedEmbeddingModel?.info.key == key {
            await unloadEmbeddingModel()
        }
        if loadedRerankerModel?.info.key == key {
            await unloadRerankerModel()
        }
        if loadedGenerativeModel?.info.key == key {
            await unloadGenerativeModel()
        }

        if key == "gte-large" {
            // GTE-Large uses flat files in the Models directory
            try deleteGTELargeFiles()
        } else {
            try await downloader.deleteModel(repoId: registration.repoId!)
        }
        modelStates[key] = .notDownloaded
        logger.info("Deleted model: \(key)")
    }

    // MARK: - GTE-Large Flat File Download

    /// Files required for GTE-Large model with approximate sizes for progress weighting
    private static let gteLargeFiles: [(name: String, approximateSize: Int64)] = [
        ("config.json", 1_000),
        ("tokenizer.json", 500_000),
        ("vocab.txt", 250_000),
        ("tokenizer_config.json", 1_000),
        ("special_tokens_map.json", 1_000),
        ("gte-large.safetensors", 640_000_000),  // Large file downloaded last for smoother progress
    ]

    /// Download GTE-Large model files individually to flat Models/ directory.
    /// Tracks combined progress weighted by file size across all 6 files.
    private func downloadGTELarge(modelKey: String) async throws {
        let baseURL = "https://huggingface.co/richtext/foodmapper-gte-large/resolve/main/"
        let destDir = MLXEmbeddingModel.downloadDirectory

        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Calculate total weight for progress tracking
        let totalWeight = Double(Self.gteLargeFiles.reduce(0) { $0 + $1.approximateSize })
        var completedWeight: Double = 0

        for (filename, approximateSize) in Self.gteLargeFiles {
            try throwIfDownloadCancelled(for: modelKey)
            let sourceURL = URL(string: baseURL + filename)!
            let destURL = destDir.appendingPathComponent(filename)

            // Skip if already exists
            if FileManager.default.fileExists(atPath: destURL.path) {
                completedWeight += Double(approximateSize)
                modelStates[modelKey] = .downloading(progress: completedWeight / totalWeight)
                continue
            }

            let fileWeight = Double(approximateSize)
            let isLargeFile = approximateSize > 10_000_000  // >10MB gets per-byte tracking

            if isLargeFile {
                let baseProgress = completedWeight
                try await downloadLargeFile(from: sourceURL, to: destURL, modelKey: modelKey) { [weak self] fileProgress in
                    let overall = (baseProgress + fileProgress * fileWeight) / totalWeight
                    Task { @MainActor in
                        guard let self else { return }
                        guard !self.shouldCancelDownload(for: modelKey) else { return }
                        self.modelStates[modelKey] = .downloading(progress: overall)
                    }
                }
            } else {
                let (data, response) = try await URLSession.shared.data(from: sourceURL)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw ModelManagerError.downloadFailed("Failed to download \(filename)")
                }
                try data.write(to: destURL)
            }

            try throwIfDownloadCancelled(for: modelKey)
            completedWeight += fileWeight
            modelStates[modelKey] = .downloading(progress: completedWeight / totalWeight)
        }
    }

    /// Download large file with progress tracking using URLSession download task.
    /// Reports per-byte progress (0.0-1.0) for this individual file via the callback.
    private func downloadLargeFile(
        from sourceURL: URL,
        to destURL: URL,
        modelKey: String,
        onFileProgress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        let delegate = DownloadProgressDelegate { progress in
            onFileProgress(progress)
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, response) = try await session.download(from: sourceURL)
        try throwIfDownloadCancelled(for: modelKey)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelManagerError.downloadFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
    }

    private func shouldCancelDownload(for key: String) -> Bool {
        Task.isCancelled || cancelledDownloadKeys.contains(key)
    }

    private func throwIfDownloadCancelled(for key: String) throws {
        if shouldCancelDownload(for: key) {
            throw CancellationError()
        }
    }

    /// Delete GTE-Large flat model files
    private func deleteGTELargeFiles() throws {
        let destDir = MLXEmbeddingModel.downloadDirectory
        for (filename, _) in Self.gteLargeFiles {
            let fileURL = destDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    /// List of model keys that are currently missing (not downloaded) for a given set of required keys
    func missingModelKeys(for requiredKeys: [String]) -> [RegisteredModel] {
        requiredKeys.compactMap { key -> RegisteredModel? in
            guard !state(for: key).isAvailable else { return nil }
            return registeredModel(for: key)
        }
    }

    // MARK: - Model Loading

    /// Load an embedding model by key. Returns the loaded model.
    /// If a different embedding model is loaded, it will be unloaded first.
    func loadEmbeddingModel(key: String) async throws -> any EmbeddingModelProtocol {
        // Already loaded?
        if let loaded = loadedEmbeddingModel, loaded.info.key == key {
            return loaded
        }

        // Unload current model if different
        if loadedEmbeddingModel != nil {
            await unloadEmbeddingModel()
        }

        modelStates[key] = .loading

        do {
            let model: any EmbeddingModelProtocol

            let hub = downloader.hubApi

            switch key {
            case "gte-large":
                let gteModel = MLXEmbeddingModel()
                try await gteModel.load()
                model = gteModel

            case "qwen3-emb-0.6b-4bit":
                let qwenModel = QwenEmbeddingModel(
                    repoId: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
                    embeddingDimensions: 1024,
                    modelKey: "qwen3-emb-0.6b-4bit",
                    modelDisplayName: "Qwen3-Embedding 0.6B"
                )
                try await qwenModel.load(hub: hub)
                model = qwenModel

            case "qwen3-emb-4b-4bit":
                let qwenModel = QwenEmbeddingModel()
                try await qwenModel.load(hub: hub)
                model = qwenModel

            case "qwen3-emb-8b-4bit":
                let qwenModel = QwenEmbeddingModel(
                    repoId: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
                    embeddingDimensions: 4096,
                    modelKey: "qwen3-emb-8b-4bit",
                    modelDisplayName: "Qwen3-Embedding 8B"
                )
                try await qwenModel.load(hub: hub)
                model = qwenModel

            default:
                throw ModelManagerError.unknownModel(key)
            }

            loadedEmbeddingModel = model
            modelStates[key] = .loaded
            logger.info("Loaded embedding model: \(key)")
            return model
        } catch {
            modelStates[key] = .error(error.localizedDescription)
            throw error
        }
    }

    /// Unload the current embedding model to free memory
    func unloadEmbeddingModel() async {
        guard let model = loadedEmbeddingModel else { return }
        let key = model.info.key
        loadedEmbeddingModel = nil
        modelStates[key] = .downloaded
        Memory.clearCache()
        logger.info("Unloaded embedding model: \(key)")
    }

    // MARK: - Reranker Loading

    /// Load a reranker model by key. Returns the loaded model.
    func loadRerankerModel(key: String) async throws -> QwenRerankerModel {
        // Already loaded?
        if let loaded = loadedRerankerModel, loaded.info.key == key {
            return loaded
        }

        // Unload current reranker if different
        if loadedRerankerModel != nil {
            await unloadRerankerModel()
        }

        modelStates[key] = .loading

        do {
            let model: QwenRerankerModel

            let hub = downloader.hubApi

            switch key {
            case "qwen3-reranker-0.6b":
                model = QwenRerankerModel()
                try await model.load(hub: hub)
            case "qwen3-reranker-4b":
                model = QwenRerankerModel(
                    repoId: "richtext/Qwen3-Reranker-4B-mlx-4bit",
                    key: "qwen3-reranker-4b",
                    displayName: "Qwen3-Reranker 4B"
                )
                try await model.load(hub: hub)
            default:
                throw ModelManagerError.unknownModel(key)
            }

            loadedRerankerModel = model
            modelStates[key] = .loaded
            logger.info("Loaded reranker model: \(key)")
            return model
        } catch {
            modelStates[key] = .error(error.localizedDescription)
            throw error
        }
    }

    /// Unload the current reranker model to free memory
    func unloadRerankerModel() async {
        guard let model = loadedRerankerModel else { return }
        let key = model.info.key
        loadedRerankerModel = nil
        modelStates[key] = .downloaded
        Memory.clearCache()
        logger.info("Unloaded reranker model: \(key)")
    }

    // MARK: - Generative Model Loading

    /// Load a generative judge model by key. Returns the loaded model.
    func loadGenerativeModel(key: String) async throws -> GenerativeJudgeModel {
        // Already loaded?
        if let loaded = loadedGenerativeModel, loaded.info.key == key {
            return loaded
        }

        // Unload current generative model if different
        if loadedGenerativeModel != nil {
            await unloadGenerativeModel()
        }

        modelStates[key] = .loading

        do {
            guard let registration = registeredModel(for: key),
                  let repoId = registration.repoId else {
                throw ModelManagerError.unknownModel(key)
            }

            let model = GenerativeJudgeModel(
                repoId: repoId,
                key: key,
                displayName: registration.displayName
            )

            let hub = downloader.hubApi
            try await model.load(hub: hub)

            loadedGenerativeModel = model
            modelStates[key] = .loaded
            logger.info("Loaded generative model: \(key)")
            return model
        } catch {
            modelStates[key] = .error(error.localizedDescription)
            throw error
        }
    }

    /// Unload the current generative model to free memory
    func unloadGenerativeModel() async {
        guard let model = loadedGenerativeModel else { return }
        let key = model.info.key
        await model.unload()
        loadedGenerativeModel = nil
        modelStates[key] = .downloaded
        Memory.clearCache()
        logger.info("Unloaded generative model: \(key)")
    }

    /// Refresh model availability (e.g., after download completes)
    func refreshModelStates() {
        detectInstalledModels()
    }

    /// Disk usage for a downloaded model
    func diskUsage(for key: String) -> Int64? {
        if key == "gte-large" {
            return gteLargeDiskUsage()
        }
        guard let registration = registeredModel(for: key),
              let repoId = registration.repoId else { return nil }
        return downloader.diskUsage(for: repoId)
    }

    /// Calculate disk usage for GTE-Large flat files
    private func gteLargeDiskUsage() -> Int64? {
        let destDir = MLXEmbeddingModel.downloadDirectory
        var totalSize: Int64 = 0
        var found = false
        for (filename, _) in Self.gteLargeFiles {
            let fileURL = destDir.appendingPathComponent(filename)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? Int64 else { continue }
            totalSize += size
            found = true
        }
        return found ? totalSize : nil
    }
}

// MARK: - Errors

enum ModelManagerError: LocalizedError {
    case unknownModel(String)
    case modelNotAvailable(String)
    case insufficientMemory(required: Int64, available: Int64)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let key):
            return "Unknown model: \(key)"
        case .modelNotAvailable(let key):
            return "Model '\(key)' is not downloaded"
        case .insufficientMemory(let required, let available):
            let reqMB = required / 1_000_000
            let avaMB = available / 1_000_000
            return "Insufficient GPU memory: \(reqMB)MB required, \(avaMB)MB available"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        }
    }
}
