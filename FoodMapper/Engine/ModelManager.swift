import Foundation
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "model-manager")

private final class GTELargeProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = minimumInterval
    }

    func shouldPublish(written: Int64, total: Int64) -> Bool {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard written >= total || now.timeIntervalSince(lastUpdate) >= minimumInterval else {
            return false
        }
        lastUpdate = now
        return true
    }
}

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

enum ModelDownloadRetryState: Equatable {
    case ready
    case cancelling
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
    /// Exact total of the approved artifacts in bytes.
    let downloadSize: Int64?
    let publisher: String
    let licenseName: String
    let purpose: ModelPurpose
    let admission: ModelAdmission

    var id: String { key }

    /// Whether this model is bundled with the app (no download needed)
    var isBundled: Bool { repoId == nil }

    var isInstallable: Bool {
        admission == .published || admission == .evaluation
    }

    init(
        key: String,
        displayName: String,
        modelFamily: ModelFamily,
        sizeCategory: ModelSizeCategory,
        repoId: String?,
        revision: String? = nil,
        downloadSize: Int64?,
        publisher: String,
        licenseName: String,
        purpose: ModelPurpose,
        admission: ModelAdmission
    ) {
        self.key = key
        self.displayName = displayName
        self.modelFamily = modelFamily
        self.sizeCategory = sizeCategory
        self.repoId = repoId
        self.revision = revision
        self.downloadSize = downloadSize
        self.publisher = publisher
        self.licenseName = licenseName
        self.purpose = purpose
        self.admission = admission
    }
}

enum ModelPurpose: String, CaseIterable {
    case embedding = "Embedding"
    case reranking = "Reranking"
    case candidateSelection = "Candidate selection"
}

enum ModelAdmission: String, CaseIterable {
    case published = "Published method"
    case evaluation = "Evaluation"
    case inventory = "Under review"
}

/// Model family grouping
enum ModelFamily: String, CaseIterable {
    case gteLarge = "GTE-Large"
}

/// Model size categories
enum ModelSizeCategory: String, CaseIterable {
    case legacy = "Legacy"
}

/// Model repositories that earlier FoodMapper versions offered in Advanced mode.
/// The model reset removed them; their downloads are deleted from the app's own
/// model folder at launch. GTE-Large, databases, sessions, and input files are
/// never part of this list.
enum LegacyModelDownloads {
    static let repositories: [String] = [
        "vqstudio/Qwen3-Reranker-0.6B-MLX-4bit",
        "mlx-community/Qwen3-Embedding-4B-mxfp8",
        "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
        "mlx-community/Qwen3-Embedding-8B-4bit-DWQ",
        "richtext/Qwen3-Reranker-0.6B-mlx-fp16",
        "richtext/Qwen3-Reranker-4B-mlx-4bit",
        "mlx-community/Qwen3-0.6B-4bit",
        "mlx-community/Qwen3-4B-4bit",
        "mlx-community/gemma-4-e2b-it-4bit",
        "mlx-community/gemma-4-e4b-it-4bit",
        "nomic-ai/nomic-embed-text-v1.5",
    ]

    /// Deletes downloads of the removed models from `snapshots`, the folder that
    /// holds `{organization}/{repository}` directories. Only the exact repository
    /// folders listed above are removed. An organization folder is removed when
    /// that leaves it empty. Symbolic links are never followed or removed.
    @discardableResult
    static func removeDownloads(in snapshots: URL, fileManager: FileManager = .default) -> [String] {
        var removed: [String] = []
        for repository in repositories {
            let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { continue }
            let organization = snapshots.appendingPathComponent(parts[0], isDirectory: true)
            let snapshot = organization.appendingPathComponent(parts[1], isDirectory: true)
            guard isRealDirectory(snapshots), isRealDirectory(organization), isRealDirectory(snapshot) else { continue }
            guard (try? fileManager.removeItem(at: snapshot)) != nil else { continue }
            removed.append(repository)
            let remaining = (try? fileManager.contentsOfDirectory(atPath: organization.path)) ?? [".unreadable"]
            if remaining.allSatisfy({ $0 == ".DS_Store" }) {
                try? fileManager.removeItem(at: organization)
            }
        }
        return removed
    }

    /// Embedding model keys whose cached database embeddings can no longer be used.
    static let removedEmbeddingModelKeys = ["qwen3-emb-0.6b-4bit", "qwen3-emb-4b-4bit", "qwen3-emb-8b-4bit"]

    /// Deletes cached database embeddings computed by the removed embedding models
    /// from `databases`, the folder that holds `{id}_embeddings_{modelKey}.bin` and
    /// `.json` files. Database CSVs, GTE-Large caches, and every other file stay.
    @discardableResult
    static func removeEmbeddingCaches(in databases: URL, fileManager: FileManager = .default) -> [String] {
        guard isRealDirectory(databases),
              let names = try? fileManager.contentsOfDirectory(atPath: databases.path) else { return [] }
        let suffixes = removedEmbeddingModelKeys.flatMap { ["_embeddings_\($0).bin", "_embeddings_\($0).json"] }
        var removed: [String] = []
        for name in names where suffixes.contains(where: { name.hasSuffix($0) && name.count > $0.count }) {
            let url = databases.appendingPathComponent(name, isDirectory: false)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed.append(name) }
        }
        return removed.sorted()
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}

/// Model registry + download/load/unload lifecycle.
@MainActor
final class ModelManager: ObservableObject {
    /// All registered models the app knows about
    @Published private(set) var registeredModels: [RegisteredModel] = []

    /// Current state of each model (keyed by model key)
    @Published private(set) var modelStates: [String: ModelState] = [:]

    /// Retry state is separate from model availability so UI can wait for the
    /// in-flight download lease to leave the install path before enabling retry.
    @Published private(set) var downloadRetryStates: [String: ModelDownloadRetryState] = [:]

    /// Currently loaded embedding model (only one at a time)
    private(set) var loadedEmbeddingModel: (any EmbeddingModelProtocol)?

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

    /// Startup recovery is completed once before any GTE availability, load,
    /// download, or deletion operation can touch the installation root.
    private var gteStartupRecoveryTask: Task<Void, Never>?
    private var gteStartupRecoveryFailure: String?
    private var gteStartupRecoveryReady = false

    init(hardwareConfig: HardwareConfig) {
        self.hardwareConfig = hardwareConfig
        registerKnownModels()
        cleanupLegacyModels()
        gteStartupRecoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await MLXEmbeddingModel.awaitStartupRecovery()
                try Task.checkCancellation()
                self.gteStartupRecoveryReady = true
                self.detectInstalledModels()
            } catch {
                self.gteStartupRecoveryFailure = error.localizedDescription
                self.modelStates["gte-large"] = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Legacy Cleanup

    /// Remove old model downloads that are no longer part of the registry.
    /// Runs once at init before detectInstalledModels().
    private func cleanupLegacyModels() {
        // Earlier versions could download optional models into the app's own
        // model folder. Only those exact repository folders are removed.
        let snapshots = downloader.modelsBase.appendingPathComponent("models", isDirectory: true)
        for repoId in LegacyModelDownloads.removeDownloads(in: snapshots) {
            logger.info("Removed download for a model the app no longer offers: \(repoId)")
        }
        let removedCaches = LegacyModelDownloads.removeEmbeddingCaches(
            in: FoodMapperStorage.privateDirectory(["CustomDBs"])
        )
        if !removedCaches.isEmpty {
            logger.info("Removed \(removedCaches.count) cached embedding files for models the app no longer offers")
        }

        // Clean up old double-nested "Models/models/" directory from previous downloadBase bug.
        // Hub library appends "models/" to downloadBase; the old code set downloadBase to
        // FoodMapper/Models/, producing FoodMapper/Models/models/{org}/{repo}/.
        let oldNestedModels = FoodMapperStorage.privateDirectory(["Models"])
            .appendingPathComponent("models", isDirectory: true)
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
                revision: GTELargeModelManifest.current.revision,
                downloadSize: GTELargeModelManifest.current.downloadSize,
                publisher: "Alibaba-NLP",
                licenseName: GTELargeModelManifest.current.upstreamLicense,
                purpose: .embedding,
                admission: .published
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

    func retryState(for key: String) -> ModelDownloadRetryState {
        downloadRetryStates[key] ?? .ready
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
        return .gteLargeEmbedding
    }

    // MARK: - Download

    /// Mark an in-flight download for cancellation.
    /// The download task should also be cancelled by the caller for fastest stop.
    func cancelDownload(key: String) {
        guard activeDownloads.contains(key) else { return }
        cancelledDownloadKeys.insert(key)
        downloadRetryStates[key] = .cancelling
        if key == "gte-large" {
            activeGTELargeInstallTask?.cancel()
        }
    }

    func cancelDownloadAndWait(key: String) async {
        cancelDownload(key: key)
        while activeDownloads.contains(key) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        downloadRetryStates[key] = .ready
    }

    func awaitStartupRecoveryForUserAction() async throws {
        await gteStartupRecoveryTask?.value
        if let gteStartupRecoveryFailure {
            throw GTELargeStartupRecoveryError.failed(gteStartupRecoveryFailure)
        }
        guard gteStartupRecoveryReady else {
            throw GTELargeStartupRecoveryError.failed("Recovery did not complete")
        }
    }

    /// Download a model by key with progress reporting
    func downloadModel(key: String) async throws {
        try await awaitStartupRecoveryForUserAction()
        guard let registration = registeredModel(for: key) else {
            throw ModelManagerError.unknownModel(key)
        }
        guard registration.isInstallable else {
            throw ModelManagerError.modelUnderReview(key)
        }

        // Prevent parallel download tasks for the same model key
        guard !activeDownloads.contains(key) else {
            logger.warning("Download already in progress for model: \(key)")
            if retryState(for: key) == .cancelling {
                throw ModelManagerError.retryAfterCancellation(key)
            }
            throw ModelManagerError.downloadInProgress(key)
        }
        activeDownloads.insert(key)
        defer {
            activeDownloads.remove(key)
            downloadRetryStates[key] = .ready
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
                // Optional models use pinned manifests under the Hub-compatible
                // {organization}/{repository} directory layout.
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
                cancelledDownloadKeys.remove(key)
                if key == "gte-large" {
                    modelStates[key] = MLXEmbeddingModel.isModelAvailable ? .downloaded : .notDownloaded
                } else if let repoId, let revision = registration.revision,
                          downloader.isDownloaded(repoId: repoId, revision: revision) {
                    // A cancellation may arrive after the verified snapshot was
                    // atomically installed. Keep that complete installation.
                    modelStates[key] = .downloaded
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
        try await awaitStartupRecoveryForUserAction()
        guard let registration = registeredModel(for: key),
              registration.repoId != nil else {
            throw ModelManagerError.unknownModel(key)
        }

        // Unload if currently loaded
        if loadedEmbeddingModel?.info.key == key {
            await unloadEmbeddingModel()
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
        let progressThrottle = GTELargeProgressThrottle()
        let updateProgress: @Sendable (Int64, Int64) -> Void = { [weak self] written, total in
            guard progressThrottle.shouldPublish(written: written, total: total) else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.shouldCancelDownload(for: modelKey) else { return }
                let progress = total == 0 ? 0 : Double(written) / Double(total)
                self.modelStates[modelKey] = .downloading(progress: progress)
                self.onGTELargeProgress?(progress, written, total)
            }
        }
        let task: Task<URL, Error> = Task.detached {
            try Task.checkCancellation()
            let directory = try await installer.install { written, total in
                updateProgress(written, total)
            }
            try Task.checkCancellation()
            return directory
        }
        activeGTELargeInstallTask = task
        defer { activeGTELargeInstallTask = nil }
        _ = try await withTaskCancellationHandler(operation: {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }, onCancel: {
            task.cancel()
        })
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
        try await awaitStartupRecoveryForUserAction()
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

    /// Refresh model availability (e.g., after download completes)
    func refreshModelStates() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.awaitStartupRecoveryForUserAction()
                try Task.checkCancellation()
                self.detectInstalledModels()
            } catch {
                self.gteStartupRecoveryFailure = error.localizedDescription
                self.modelStates["gte-large"] = .error(error.localizedDescription)
            }
        }
    }

    /// Disk usage for a downloaded model
    func diskUsage(for key: String) -> Int64? {
        if key == "gte-large" {
            guard gteStartupRecoveryReady else { return nil }
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
    case modelUnderReview(String)
    case modelNotAvailable(String)
    case insufficientMemory(required: Int64, available: Int64)
    case downloadFailed(String)
    case downloadInProgress(String)
    case retryAfterCancellation(String)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let key):
            return "Unknown model: \(key)"
        case .modelUnderReview(let key):
            return "Model '\(key)' is still under review and cannot be installed."
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
        case .retryAfterCancellation(let key):
            return "Finishing cancellation for '\(key)'; retry will be available shortly"
        }
    }
}
