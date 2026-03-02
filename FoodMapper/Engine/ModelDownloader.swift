import Foundation
import Hub
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "model-downloader")

/// HuggingFace Hub model downloads.
/// Stored in ~/Library/Application Support/FoodMapper/Models/ (Hub cache layout).
actor ModelDownloader {
    /// HubApi pointed at ~/Library/Application Support/FoodMapper/
    /// instead of Hub's default ~/Documents/huggingface/.
    nonisolated let hubApi: HubApi

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        // Set downloadBase to FoodMapper/ (not FoodMapper/Models/).
        // Hub library appends "models/" internally (repo.type.rawValue), which resolves
        // to the existing Models/ directory on case-insensitive APFS.
        let modelsBase = appSupport
            .appendingPathComponent("FoodMapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsBase, withIntermediateDirectories: true)

        self.hubApi = HubApi(downloadBase: modelsBase)
        logger.info("Model download base: \(modelsBase.path)")
    }

    /// Check if a HuggingFace model is already cached locally
    nonisolated func isDownloaded(repoId: String) -> Bool {
        let repo = Hub.Repo(id: repoId)
        let cacheDir = hubApi.localRepoLocation(repo)
        let configPath = cacheDir.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: configPath.path)
    }

    /// Download a model from HuggingFace Hub with progress reporting.
    /// Returns the local cache directory URL.
    func download(
        repoId: String,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        logger.info("Downloading model: \(repoId)")

        let repo = Hub.Repo(id: repoId)

        let localURL = try await hubApi.snapshot(from: repo) { progress in
            onProgress(progress.fractionCompleted)
        }

        logger.info("Model downloaded to: \(localURL.path)")
        return localURL
    }

    /// Get the local cache path for a HuggingFace model (may not exist yet)
    nonisolated func localPath(for repoId: String) -> URL {
        let repo = Hub.Repo(id: repoId)
        return hubApi.localRepoLocation(repo)
    }

    /// Calculate the disk space used by a cached model (approximate)
    nonisolated func diskUsage(for repoId: String) -> Int64? {
        let path = localPath(for: repoId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        var totalSize: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: path,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize else { continue }
            totalSize += Int64(fileSize)
        }

        return totalSize
    }

    /// Delete a cached model from the Hub cache
    func deleteModel(repoId: String) throws {
        let path = localPath(for: repoId)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
        logger.info("Deleted cached model: \(repoId)")
    }
}
