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
    /// Immutable Hugging Face commit for models that are downloaded by the app.
    let revision: String?
    /// Approximate download size in bytes
    let downloadSize: Int64?
    /// Approximate GPU memory usage in bytes
    let gpuMemoryUsage: Int64?
    /// Minimum hardware profile to use this model comfortably
    let minimumProfile: HardwareProfile

    var id: String { key }

    /// Whether this model is bundled with the app (no download needed)
    var isBundled: Bool { repoId == nil }

    init(
        key: String,
        displayName: String,
        modelFamily: ModelFamily,
        sizeCategory: ModelSizeCategory,
        repoId: String?,
        revision: String? = nil,
        downloadSize: Int64?,
        gpuMemoryUsage: Int64?,
        minimumProfile: HardwareProfile
    ) {
        self.key = key
        self.displayName = displayName
        self.modelFamily = modelFamily
        self.sizeCategory = sizeCategory
        self.repoId = repoId
        self.revision = revision
        self.downloadSize = downloadSize
        self.gpuMemoryUsage = gpuMemoryUsage
        self.minimumProfile = minimumProfile
    }
}

/// Model family grouping
enum ModelFamily: String, CaseIterable {
    case gteLarge = "GTE-Large"
    case qwen3Embedding = "Qwen3-Embedding"
    case qwen3Reranker = "Qwen3-Reranker"
    case qwen3Generative = "Qwen3-Generative"
    case gemma4Generative = "Gemma 4 Generative"
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

    /// Model keys currently downloading (prevents concurrent task collisions)
    private var activeDownloads: Set<String> = []

    /// Callback for detailed GTE-Large progress updates (progress, written, total)
    var onGTELargeProgress: (@MainActor (_ progress: Double, _ written: Int64, _ total: Int64) -> Void)?

    /// The explicit GTE-Large installation task. Availability checks never
    /// create this task or make a network request.
    private var activeGTELargeInstallTask: Task<URL, Error>?

    init(hardwareConfig: HardwareConfig) {
        self.hardwareConfig = hardwareConfig
        registerKnownModels()
        cleanupLegacyModels()
        Task { [weak self] in
            guard let self else { return }
            let installer = GTELargeModelInstaller(rootDirectory: MLXEmbeddingModel.downloadDirectory)
            try? await installer.recoverAtStartup()
            self.detectInstalledModels()
        }
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
        let appSupport = FoodMapperStorage.applicationSupportURL
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
                downloadSize: GTELargeModelManifest.current.downloadSize,
                gpuMemoryUsage: 700_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "qwen3-emb-0.6b-4bit",
                displayName: "Qwen3-Embedding 0.6B",
                modelFamily: .qwen3Embedding,
                sizeCategory: .small,
                repoId: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
                revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a",
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
                revision: "b5d88f1fe49b50d2ac01b4692ca2d387f14f9c72",
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
                revision: "885642d6b98742ea03b77a1673579c92ca961efd",
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
                revision: "e8a94247380953b292660c992e41d94ac04df5f8",
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
                revision: "91f74cc6a280afc5f441479b850c8c7980f21ec1",
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
                revision: "73e3e38d981303bc594367cd910ea6eb48349da8",
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
                revision: "4dcb3d101c2a062e5c1d4bb173588c54ea6c4d25",
                downloadSize: 2_280_000_000,
                gpuMemoryUsage: 2_500_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "gemma4-e2b-it-4bit",
                displayName: "Gemma 4 E2B Instruct 4-bit",
                modelFamily: .gemma4Generative,
                sizeCategory: .small,
                repoId: "mlx-community/gemma-4-e2b-it-4bit",
                downloadSize: 1_200_000_000,
                gpuMemoryUsage: 1_500_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "gemma4-e4b-it-4bit",
                displayName: "Gemma 4 E4B Instruct 4-bit",
                modelFamily: .gemma4Generative,
                sizeCategory: .medium,
                repoId: "mlx-community/gemma-4-e4b-it-4bit",
                downloadSize: 2_400_000_000,
                gpuMemoryUsage: 2_800_000_000,
                minimumProfile: .base
            ),
        ]

        loadCustomRegisteredModels()
    }

    /// Loads custom user-registered models dynamically from a local JSON config
    private func loadCustomRegisteredModels() {
        let fileManager = FileManager.default
        let appSupport = FoodMapperStorage.applicationSupportURL

        // Ensure parent directories exist
        let modelsDir = appSupport.appendingPathComponent("FoodMapper/Models", isDirectory: true)
        try? fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let customModelsURL = modelsDir.appendingPathComponent("custom_models.json")

        guard fileManager.fileExists(atPath: customModelsURL.path) else { return }

        do {
            let data = try Data(contentsOf: customModelsURL)
            struct CustomModelDecodable: Decodable {
                let key: String
                let displayName: String
                let modelFamily: String
                let sizeCategory: String
                let repoId: String?
                let downloadSize: Int64?
                let gpuMemoryUsage: Int64?
                let minimumProfile: String
            }

            let decoded = try JSONDecoder().decode([CustomModelDecodable].self, from: data)

            for item in decoded {
                let family = ModelFamily(rawValue: item.modelFamily) ?? .gemma4Generative
                let size = ModelSizeCategory(rawValue: item.sizeCategory) ?? .medium
                let profile = HardwareProfile(rawValue: item.minimumProfile) ?? .base

                let customModel = RegisteredModel(
                    key: item.key,
                    displayName: item.displayName,
                    modelFamily: family,
                    sizeCategory: size,
                    repoId: item.repoId,
                    downloadSize: item.downloadSize,
                    gpuMemoryUsage: item.gpuMemoryUsage,
                    minimumProfile: profile
                )

                // Add to registeredModels if not already present
                if !registeredModels.contains(where: { $0.key == customModel.key }) {
                    registeredModels.append(customModel)
                    logger.info("Loaded custom model registration: \(customModel.key) (\(customModel.displayName))")
                }
            }
        } catch {
            logger.error("Failed to load custom models JSON: \(error.localizedDescription)")
        }
    }

    /// Check which models are already downloaded/available
    private func detectInstalledModels() {
        for model in registeredModels {
            switch model.key {
            case "gte-large":
                modelStates[model.key] = MLXEmbeddingModel.isModelAvailable ? .downloaded : .notDownloaded
            default:
                if let repoId = model.repoId, downloader.isDownloaded(repoId: repoId, revision: model.revision) {
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
        guard activeDownloads.contains(key) else { return }
        cancelledDownloadKeys.insert(key)
        if key == "gte-large" {
            activeGTELargeInstallTask?.cancel()
        }
    }

    /// Download a model by key with progress reporting
    func downloadModel(key: String) async throws {
        guard let registration = registeredModel(for: key) else {
            throw ModelManagerError.unknownModel(key)
        }

        // Prevent parallel download tasks for the same model key
        guard !activeDownloads.contains(key) else {
            logger.warning("Download already in progress for model: \(key)")
            throw ModelManagerError.downloadInProgress(key)
        }
        activeDownloads.insert(key)
        defer {
            activeDownloads.remove(key)
        }

        let repoId = registration.repoId
        cancelledDownloadKeys.remove(key)
        modelStates[key] = .downloading(progress: 0)

        do {
            if key == "gte-large" {
                // GTE-Large uses its immutable manifest installer.
                try await downloadGTELarge(modelKey: key)
            } else {
                guard let repoId = repoId, let revision = registration.revision else {
                    throw ModelManagerError.unknownModel(key)
                }
                // Other models use Hub snapshot (nested {org}/{repo}/ directories)
                _ = try await downloader.download(repoId: repoId, revision: revision) { [weak self] progress in
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
        } catch {
            let isCancelled = self.shouldCancelDownload(for: key) ||
                             error is CancellationError ||
                             (error as? URLError)?.code == .cancelled

            if isCancelled {
                if key != "gte-large", let repoId = repoId {
                    try? await downloader.deleteModel(repoId: repoId)
                }
                cancelledDownloadKeys.remove(key)
                if key == "gte-large" {
                    modelStates[key] = MLXEmbeddingModel.isModelAvailable ? .downloaded : .notDownloaded
                } else {
                    modelStates[key] = .notDownloaded
                }
                logger.info("Cancelled model download: \(key)")
                throw error
            } else {
                cancelledDownloadKeys.remove(key)
                if key == "gte-large" {
                    let message = "GTE-Large download could not be installed"
                    modelStates[key] = .error(message)
                    throw ModelManagerError.downloadFailed(message)
                }
                modelStates[key] = .error(error.localizedDescription)
                throw error
            }
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
            // GTE-Large keeps its verified files in a versioned private directory.
            try await deleteGTELargeFiles()
        } else {
            try await downloader.deleteModel(repoId: registration.repoId!)
        }
        modelStates[key] = .notDownloaded
        logger.info("Deleted model: \(key)")
    }

    // MARK: - GTE-Large Verified Download

    /// Downloads the immutable GTE-Large manifest into a private staging
    /// directory. The prior verified installation remains available until the
    /// full replacement is checked and committed.
    private func downloadGTELarge(modelKey: String) async throws {
        let root = MLXEmbeddingModel.downloadDirectory
        let installer = GTELargeModelInstaller(
            rootDirectory: root,
            transport: URLSessionGTELargeDownloadTransport()
        )
        let updateProgress: @Sendable (Int64, Int64) -> Void = { [weak self] written, total in
            Task { @MainActor [weak self] in
                guard let self, !self.shouldCancelDownload(for: modelKey) else { return }
                let progress = total == 0 ? 0 : Double(written) / Double(total)
                self.modelStates[modelKey] = .downloading(progress: progress)
                self.onGTELargeProgress?(progress, written, total)
            }
        }
        let task: Task<URL, Error> = Task.detached {
            try await installer.install { written, total in
                updateProgress(written, total)
            }
        }
        activeGTELargeInstallTask = task
        defer { activeGTELargeInstallTask = nil }
        _ = try await task.value
        try throwIfDownloadCancelled(for: modelKey)
    }

    private func shouldCancelDownload(for key: String) -> Bool {
        Task.isCancelled || cancelledDownloadKeys.contains(key)
    }

    private func throwIfDownloadCancelled(for key: String) throws {
        if shouldCancelDownload(for: key) {
            throw CancellationError()
        }
    }

    /// Delete the verified GTE-Large installation and owned recovery artifacts.
    private func deleteGTELargeFiles() async throws {
        let root = MLXEmbeddingModel.downloadDirectory
        let installer = GTELargeModelInstaller(rootDirectory: root)
        try await installer.deleteInstallArtifacts()
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
                let snapshot = try await downloader.validatedLocalSnapshot(for: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a")
                try await qwenModel.load(snapshot: snapshot)
                model = qwenModel

            case "qwen3-emb-4b-4bit":
                let qwenModel = QwenEmbeddingModel()
                let snapshot = try await downloader.validatedLocalSnapshot(for: "mlx-community/Qwen3-Embedding-4B-4bit-DWQ", revision: "b5d88f1fe49b50d2ac01b4692ca2d387f14f9c72")
                try await qwenModel.load(snapshot: snapshot)
                model = qwenModel

            case "qwen3-emb-8b-4bit":
                let qwenModel = QwenEmbeddingModel(
                    repoId: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
                    embeddingDimensions: 4096,
                    modelKey: "qwen3-emb-8b-4bit",
                    modelDisplayName: "Qwen3-Embedding 8B"
                )
                let snapshot = try await downloader.validatedLocalSnapshot(for: "mlx-community/Qwen3-Embedding-8B-4bit-DWQ", revision: "885642d6b98742ea03b77a1673579c92ca961efd")
                try await qwenModel.load(snapshot: snapshot)
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

            switch key {
            case "qwen3-reranker-0.6b":
                model = QwenRerankerModel()
                try await model.load(snapshot: try await downloader.validatedLocalSnapshot(
                    for: "richtext/Qwen3-Reranker-0.6B-mlx-fp16",
                    revision: "e8a94247380953b292660c992e41d94ac04df5f8"
                ))
            case "qwen3-reranker-4b":
                model = QwenRerankerModel(
                    repoId: "richtext/Qwen3-Reranker-4B-mlx-4bit",
                    key: "qwen3-reranker-4b",
                    displayName: "Qwen3-Reranker 4B"
                )
                try await model.load(snapshot: try await downloader.validatedLocalSnapshot(
                    for: "richtext/Qwen3-Reranker-4B-mlx-4bit",
                    revision: "91f74cc6a280afc5f441479b850c8c7980f21ec1"
                ))
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

            guard let revision = registration.revision else { throw ModelManagerError.unknownModel(key) }
            let snapshot = try await downloader.validatedLocalSnapshot(for: repoId, revision: revision)
            try await model.load(snapshot: snapshot)

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
        let installer = GTELargeModelInstaller(rootDirectory: MLXEmbeddingModel.downloadDirectory)
        return installer.availableDirectory() == nil ? nil : installer.manifest.downloadSize
    }
}

// MARK: - Errors

enum ModelManagerError: LocalizedError {
    case unknownModel(String)
    case modelNotAvailable(String)
    case insufficientMemory(required: Int64, available: Int64)
    case downloadFailed(String)
    case downloadInProgress(String)

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
        case .downloadInProgress(let key):
            return "A download is already in progress for '\(key)'"
        }
    }
}
