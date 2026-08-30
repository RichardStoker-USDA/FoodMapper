import Foundation
import CryptoKit
import Hub
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "model-downloader")

struct LocalModelSnapshotManifest: Codable {
    static let currentVersion = 1
    let version: Int
    let repository: String
    let revision: String
    let artifacts: [String: String]
}

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
    nonisolated func isDownloaded(repoId: String, revision: String? = nil) -> Bool {
        let repo = Hub.Repo(id: repoId)
        let cacheDir = hubApi.localRepoLocation(repo)
        return Self.isCompleteSnapshot(at: cacheDir, repository: repoId, revision: revision)
    }

    /// A config file is written before Hub has finished a snapshot. Treating that
    /// directory as installed causes offline loads to fail after a partial download.
    nonisolated static func isCompleteSnapshot(at directory: URL, repository: String? = nil, revision: String? = nil) -> Bool {
        let fileManager = FileManager.default
        let manifestURL = directory.appendingPathComponent("foodmapper_snapshot_manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(LocalModelSnapshotManifest.self, from: data),
              manifest.version == LocalModelSnapshotManifest.currentVersion,
              repository.map({ $0 == manifest.repository }) ?? true,
              revision.map({ $0 == manifest.revision }) ?? true,
              !manifest.artifacts.isEmpty else {
            return false
        }
        var hasConfig = false
        var hasTokenizer = false
        var hasWeights = false
        for (path, expectedHash) in manifest.artifacts {
            let url = directory.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: url.path),
                  let artifactData = try? Data(contentsOf: url),
                  digest(artifactData) == expectedHash else { return false }
            if path.hasSuffix("config.json") { hasConfig = isReadableJSON(at: url) }
            if path.hasSuffix("tokenizer.json") { hasTokenizer = isReadableJSON(at: url) }
            if path.hasSuffix(".safetensors") { hasWeights = artifactData.count > 1024 }
        }
        return hasConfig && hasTokenizer && hasWeights
    }

    nonisolated private static func isReadableJSON(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Download a model from HuggingFace Hub with progress reporting.
    /// Returns the local cache directory URL.
    func download(
        repoId: String,
        revision: String,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        logger.info("Downloading model: \(repoId)")

        let repo = Hub.Repo(id: repoId)

        let localURL = try await hubApi.snapshot(from: repo, revision: revision) { progress in
            onProgress(progress.fractionCompleted)
        }

        try writeManifest(repository: repoId, revision: revision, directory: localURL)
        logger.info("Model downloaded to: \(localURL.path)")
        return localURL
    }

    /// Get the local cache path for a HuggingFace model (may not exist yet)
    nonisolated func localPath(for repoId: String) -> URL {
        let repo = Hub.Repo(id: repoId)
        return hubApi.localRepoLocation(repo)
    }

    func validatedLocalPath(for repoId: String, revision: String) throws -> URL {
        let path = localPath(for: repoId)
        guard Self.isCompleteSnapshot(at: path, repository: repoId, revision: revision) else {
            throw ModelDownloaderError.invalidSnapshot
        }
        return path
    }

    private func writeManifest(repository: String, revision: String, directory: URL) throws {
        let fileManager = FileManager.default
        guard let paths = try? fileManager.subpathsOfDirectory(atPath: directory.path) else {
            throw ModelDownloaderError.invalidSnapshot
        }
        let artifacts = try Dictionary(uniqueKeysWithValues: paths.compactMap { path -> (String, String)? in
            guard path != "foodmapper_snapshot_manifest.json",
                  path.hasSuffix(".json") || path.hasSuffix(".safetensors") else { return nil }
            let data = try Data(contentsOf: directory.appendingPathComponent(path))
            return (path, Self.digest(data))
        })
        guard !artifacts.isEmpty else { throw ModelDownloaderError.invalidSnapshot }
        let manifest = LocalModelSnapshotManifest(
            version: LocalModelSnapshotManifest.currentVersion,
            repository: repository,
            revision: revision,
            artifacts: artifacts
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("foodmapper_snapshot_manifest.json"), options: [.atomic]
        )
        guard Self.isCompleteSnapshot(at: directory, repository: repository, revision: revision) else {
            throw ModelDownloaderError.invalidSnapshot
        }
    }

    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

enum ModelDownloaderError: LocalizedError {
    case invalidSnapshot

    var errorDescription: String? { "Downloaded model files are incomplete or changed." }
}
