import Foundation
import CryptoKit
import Hub
import os
import Darwin

private let logger = Logger(subsystem: "com.foodmapper", category: "model-downloader")

struct LocalModelSnapshotManifest: Codable {
    static let currentVersion = 1
    let version: Int
    let repository: String
    let revision: String
    let artifacts: [String: String]
}

/// A local model location issued only after the pinned artifact manifest has
/// been validated. Model loaders accept this value instead of an arbitrary URL.
struct VerifiedLocalModelSnapshot: @unchecked Sendable {
    let directory: URL
    let repository: String
    let revision: String
    let artifactPaths: Set<String>
    private let issuer: UUID
    private static let authority = UUID()

    fileprivate init(directory: URL, repository: String, revision: String, artifactPaths: Set<String>) {
        self.directory = directory
        self.repository = repository
        self.revision = revision
        self.artifactPaths = artifactPaths
        self.issuer = Self.authority
    }

    var isIssuedByDownloader: Bool { issuer == Self.authority }
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
    nonisolated let modelsBase: URL

    init() {
        let appSupport = FoodMapperStorage.applicationSupportURL
        // Set downloadBase to FoodMapper/ (not FoodMapper/Models/).
        // Hub library appends "models/" internally (repo.type.rawValue), which resolves
        // to the existing Models/ directory on case-insensitive APFS.
        let modelsBase = appSupport
            .appendingPathComponent("FoodMapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsBase, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: SecureFileAccess.storageDirectoryPermissions], ofItemAtPath: modelsBase.path)

        self.modelsBase = modelsBase
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
        let manifestURL = directory.appendingPathComponent("foodmapper_snapshot_manifest.json")
        guard let data = try? readVerifiedFile(manifestURL, under: directory, maximumSize: 1_048_576),
              let manifest = try? JSONDecoder().decode(LocalModelSnapshotManifest.self, from: data),
              manifest.version == LocalModelSnapshotManifest.currentVersion,
              repository.map({ $0 == manifest.repository }) ?? true,
              revision.map({ $0 == manifest.revision }) ?? true,
              let expected = trustedModel(repository: manifest.repository, revision: manifest.revision),
              !manifest.artifacts.isEmpty else {
            return false
        }
        let expectedArtifacts = Dictionary(uniqueKeysWithValues: expected.artifacts.map { ($0.path, $0) })
        guard Set(manifest.artifacts.keys) == Set(expectedArtifacts.keys),
              manifest.artifacts.allSatisfy({ expectedArtifacts[$0.key]?.sha256 == $0.value }) else {
            return false
        }
        guard containsOnlyDeclaredArtifacts(in: directory, declared: Set(manifest.artifacts.keys)) else {
            return false
        }
        var hasConfig = false
        var hasTokenizer = false
        var hasWeights = false
        for (path, expectedHash) in manifest.artifacts {
            guard let artifact = expectedArtifacts[path],
                  let artifactURL = safeArtifactURL(directory: directory, path: path),
                  (try? digestFile(artifactURL, under: directory)) == expectedHash else { return false }
            if path.hasSuffix("config.json") { hasConfig = isReadableJSON(at: artifactURL, under: directory) }
            if path.hasSuffix("tokenizer.json") { hasTokenizer = isReadableJSON(at: artifactURL, under: directory) }
            if path.hasSuffix(".safetensors") { hasWeights = artifact.byteSize > 1024 }
        }
        return hasConfig && hasTokenizer && hasWeights
    }

    nonisolated private static func isReadableJSON(at url: URL, under directory: URL) -> Bool {
        guard let data = try? readVerifiedFile(url, under: directory, maximumSize: 32 * 1_048_576), !data.isEmpty else { return false }
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
        let stagingBase = modelsBase.appendingPathComponent(".qwen-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingBase, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: SecureFileAccess.storageDirectoryPermissions], ofItemAtPath: stagingBase.path)
        defer { try? FileManager.default.removeItem(at: stagingBase) }

        let stagingHub = HubApi(downloadBase: stagingBase)
        let stagedURL = try await stagingHub.snapshot(from: repo, revision: revision) { progress in
            onProgress(progress.fractionCompleted)
        }
        try writeManifest(repository: repoId, revision: revision, directory: stagedURL)
        try replaceSnapshot(stagedURL, at: localPath(for: repoId))
        let localURL = localPath(for: repoId)
        guard Self.isCompleteSnapshot(at: localURL, repository: repoId, revision: revision) else {
            throw ModelDownloaderError.invalidSnapshot
        }
        logger.info("Model downloaded to: \(localURL.path)")
        return localURL
    }

    /// Get the local cache path for a HuggingFace model (may not exist yet)
    nonisolated func localPath(for repoId: String) -> URL {
        let repo = Hub.Repo(id: repoId)
        return hubApi.localRepoLocation(repo)
    }

    func validatedLocalSnapshot(for repoId: String, revision: String) throws -> VerifiedLocalModelSnapshot {
        let path = localPath(for: repoId)
        guard Self.isCompleteSnapshot(at: path, repository: repoId, revision: revision) else {
            throw ModelDownloaderError.invalidSnapshot
        }
        let manifestURL = path.appendingPathComponent("foodmapper_snapshot_manifest.json")
        let data = try Self.readVerifiedFile(manifestURL, under: path, maximumSize: 1_048_576)
        let manifest = try JSONDecoder().decode(LocalModelSnapshotManifest.self, from: data)
        return VerifiedLocalModelSnapshot(
            directory: path, repository: repoId, revision: revision, artifactPaths: Set(manifest.artifacts.keys)
        )
    }

    private func replaceSnapshot(_ stagedURL: URL, at destination: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: SecureFileAccess.storageDirectoryPermissions], ofItemAtPath: parent.path)
        try SecureFileAccess.validateStorageDirectory(parent)
        let backup = parent.appendingPathComponent(".snapshot-backup-\(UUID().uuidString)", isDirectory: true)
        var movedExisting = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedExisting = true
                try SecureFileAccess.synchronize(parent, directory: true)
            }
            try fileManager.moveItem(at: stagedURL, to: destination)
            try SecureFileAccess.synchronize(parent, directory: true)
            if movedExisting {
                try fileManager.removeItem(at: backup)
                try SecureFileAccess.synchronize(parent, directory: true)
            }
        } catch {
            if fileManager.fileExists(atPath: destination.path) { try? fileManager.removeItem(at: destination) }
            if movedExisting, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            try? SecureFileAccess.synchronize(parent, directory: true)
            throw error
        }
    }

    private func writeManifest(repository: String, revision: String, directory: URL) throws {
        guard let expected = Self.trustedModel(repository: repository, revision: revision) else {
            throw ModelDownloaderError.untrustedRevision
        }
        let allowedPaths = Set(expected.artifacts.map(\.path))
        guard allowedPaths.count == expected.artifacts.count,
              allowedPaths.allSatisfy({ Self.isSafeRelativePath($0) }) else {
            throw ModelDownloaderError.invalidSnapshot
        }
        let artifacts = try Dictionary(uniqueKeysWithValues: expected.artifacts.map { artifact -> (String, String) in
            guard let url = Self.safeArtifactURL(directory: directory, path: artifact.path),
                  try Self.fileSize(url, under: directory) == artifact.byteSize,
                  try Self.digestFile(url, under: directory) == artifact.sha256 else {
                throw ModelDownloaderError.invalidSnapshot
            }
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

    nonisolated private static func trustedModel(repository: String, revision: String) -> TrustedQwenSnapshotManifest.Model? {
        guard let url = ResourceBundle.bundle.url(forResource: "qwen_snapshot_manifest", withExtension: "json", subdirectory: "Models"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(TrustedQwenSnapshotManifest.self, from: data),
              manifest.version == 1 else { return nil }
        return manifest.models.first { $0.repo == repository && $0.revision == revision }
    }

    nonisolated private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && URL(fileURLWithPath: path).pathComponents.allSatisfy {
            $0 != "." && $0 != ".." && $0 != "/"
        }
    }

    nonisolated private static func safeArtifactURL(directory: URL, path: String) -> URL? {
        guard isSafeRelativePath(path) else { return nil }
        let candidate = directory.appendingPathComponent(path)
        let rootPath = directory.standardizedFileURL.path + "/"
        guard candidate.standardizedFileURL.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    nonisolated private static func containsOnlyDeclaredArtifacts(in directory: URL, declared: Set<String>) -> Bool {
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: directory.path) else { return false }
        let permitted = declared.union(["foodmapper_snapshot_manifest.json"])
        for path in paths {
            let url = directory.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            if (info.st_mode & S_IFMT) == S_IFREG, !permitted.contains(path) {
                return false
            }
        }
        return true
    }

    nonisolated private static func readVerifiedFile(_ url: URL, under directory: URL, maximumSize: Int) throws -> Data {
        let descriptor = try verifiedDescriptor(url, under: directory)
        defer { close(descriptor) }
        var data = Data()
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        while let chunk = try handle.read(upToCount: min(1_048_576, maximumSize - data.count)), !chunk.isEmpty {
            data.append(chunk)
            if data.count > maximumSize { throw ModelDownloaderError.invalidSnapshot }
        }
        return data
    }

    nonisolated private static func digestFile(_ url: URL, under directory: URL) throws -> String {
        let descriptor = try verifiedDescriptor(url, under: directory)
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func fileSize(_ url: URL, under directory: URL) throws -> Int64 {
        let descriptor = try verifiedDescriptor(url, under: directory)
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ModelDownloaderError.invalidSnapshot }
        return Int64(info.st_size)
    }

    nonisolated private static func verifiedDescriptor(_ url: URL, under directory: URL) throws -> Int32 {
        guard url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw ModelDownloaderError.invalidSnapshot
        }
        var root = stat()
        guard lstat(directory.path, &root) == 0,
              (root.st_mode & S_IFMT) == S_IFDIR,
              root.st_uid == getuid(),
              (root.st_mode & S_IWOTH) == 0 else {
            throw ModelDownloaderError.invalidSnapshot
        }
        var path = directory.standardizedFileURL.path
        let relative = String(url.standardizedFileURL.path.dropFirst(path.count + 1))
        for component in relative.split(separator: "/").dropLast() {
            path += "/\(component)"
            var ancestor = stat()
            guard lstat(path, &ancestor) == 0,
                  (ancestor.st_mode & S_IFMT) == S_IFDIR,
                  ancestor.st_uid == getuid(),
                  (ancestor.st_mode & S_IWOTH) == 0 else {
                throw ModelDownloaderError.invalidSnapshot
            }
        }
        var before = stat()
        guard lstat(url.path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1 else {
            throw ModelDownloaderError.invalidSnapshot
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ModelDownloaderError.invalidSnapshot }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              (after.st_mode & S_IFMT) == S_IFREG, after.st_nlink == 1 else {
            close(descriptor)
            throw ModelDownloaderError.invalidSnapshot
        }
        return descriptor
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
