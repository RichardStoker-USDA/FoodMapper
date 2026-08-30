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

struct TrustedQwenSnapshotManifest: Decodable {
    struct Model: Decodable {
        struct Artifact: Decodable {
            let path: String
            let byteSize: Int64
            let sha256: String
            let roles: [String]

            enum CodingKeys: String, CodingKey {
                case path, byteSize = "byte_size", sha256, roles
            }
        }
        let repo: String
        let revision: String
        let artifacts: [Artifact]
    }
    let version: Int
    let models: [Model]
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
        guard let expected = Self.trustedModel(repository: repository, revision: revision) else {
            throw ModelDownloaderError.untrustedRevision
        }
        let allowedPaths = Set(expected.artifacts.map(\.path))
        guard allowedPaths.allSatisfy({ Self.isSafeRelativePath($0) }) else {
            throw ModelDownloaderError.invalidSnapshot
        }
        let artifacts = try Dictionary(uniqueKeysWithValues: expected.artifacts.map { artifact -> (String, String) in
            let url = directory.appendingPathComponent(artifact.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == artifact.byteSize else {
                throw ModelDownloaderError.invalidSnapshot
            }
            let data = try Data(contentsOf: url)
            guard Self.digest(data) == artifact.sha256 else { throw ModelDownloaderError.invalidSnapshot }
            return (artifact.path, artifact.sha256)
        })
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

    nonisolated private static func trustedModel(repository: String, revision: String) -> TrustedQwenSnapshotManifest.Model? {
        guard let url = ResourceBundle.bundle.url(forResource: "qwen_snapshot_manifest", withExtension: "json", subdirectory: "Models"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(TrustedQwenSnapshotManifest.self, from: data),
              manifest.version == 1 else { return nil }
        return manifest.models.first { $0.repo == repository && $0.revision == revision }
    }

    nonisolated private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("..") && !path.contains("//")
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
    case untrustedRevision

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "Downloaded model files are incomplete or changed."
        case .untrustedRevision: return "This model revision is not approved for installation."
        }
    }
}
