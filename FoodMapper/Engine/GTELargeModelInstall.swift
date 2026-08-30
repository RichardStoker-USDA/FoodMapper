import CryptoKit
import Darwin
import Foundation

/// Immutable source and byte-level requirements for FoodMapper's default
/// GTE-Large model. Keep this separate from the broader model registry: this
/// model is loaded directly by the MLX BERT implementation.
struct GTELargeModelManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }

    let formatVersion: Int
    let repositoryID: String
    let revision: String
    let files: [File]

    static let current = GTELargeModelManifest(
        formatVersion: 1,
        repositoryID: "richtext/foodmapper-gte-large",
        revision: "0b7a78872ae6fd502fe2db3273b1b3e065a3d9db",
        files: [
            File(name: "config.json", size: 619, sha256: "42a037b389d02db73d1d5bd0d049d3269e3617e368f86992474a32c42ffbd859"),
            File(name: "gte-large.safetensors", size: 670_326_040, sha256: "f917f334b6e38e966519983a6b567a5a86d90065932c780f6b4ad72e6bf3a90b"),
            File(name: "special_tokens_map.json", size: 125, sha256: "b6d346be366a7d1d48332dbc9fdf3bf8960b5d879522b7799ddba59e76237ee3"),
            File(name: "tokenizer.json", size: 711_661, sha256: "da0e79933b9ed51798a3ae27893d3c5fa4a201126cef75586296df9b4d2c62a0"),
            File(name: "tokenizer_config.json", size: 342, sha256: "c3fcc8144d538db689632ef6f0d273f19b511bdcb0d752411a29f387763e526c"),
            File(name: "vocab.txt", size: 231_508, sha256: "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3"),
        ]
    )

    var downloadSize: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    var installationDirectoryName: String {
        "gte-large-\(revision)"
    }

    func sourceURL(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repositoryID)/resolve/\(revision)/\(file.name)")!
    }
}

struct GTELargeModelInstallRecord: Codable, Equatable, Sendable {
    let formatVersion: Int
    let repositoryID: String
    let revision: String
    let files: [GTELargeModelManifest.File]

    init(manifest: GTELargeModelManifest) {
        formatVersion = manifest.formatVersion
        repositoryID = manifest.repositoryID
        revision = manifest.revision
        files = manifest.files
    }

    func matches(_ manifest: GTELargeModelManifest) -> Bool {
        formatVersion == manifest.formatVersion &&
            repositoryID == manifest.repositoryID &&
            revision == manifest.revision &&
            files == manifest.files
    }
}

struct GTELargeFileIdentity: Codable, Equatable, Sendable {
    let size: Int64
    let device: UInt64
    let inode: UInt64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let linkCount: UInt64
    let mode: UInt16
    let owner: UInt32
}

private enum GTELargeSecurePath {
    static let privateDirectoryMode: mode_t = 0o700
    static let privateFileMode: mode_t = 0o600

    static func validateAncestors(of url: URL, allowMissingLeaf: Bool = false) throws {
        // Do not standardize URL paths here. Foundation resolves /private/tmp
        // to /tmp on this platform, and /tmp is a symlink by design.
        let components = url.pathComponents
        guard components.first == "/" else { throw GTELargeModelInstallError.unsafePath }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        let remaining = Array(components.dropFirst())
        for (index, component) in remaining.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.dropFirst().count - 1)
            var status = stat()
            if lstat(current.path, &status) != 0 {
                if errno == ENOENT && allowMissingLeaf && index == remaining.count - 1 {
                    return
                }
                throw GTELargeModelInstallError.unsafePath
            }
            guard (status.st_mode & S_IFMT) == S_IFDIR, (status.st_mode & S_IFMT) != S_IFLNK else {
                throw GTELargeModelInstallError.unsafePath
            }
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else { throw GTELargeModelInstallError.unsafePath }
            var opened = stat()
            guard fstat(next, &opened) == 0,
                  sameObject(status, opened),
                  (opened.st_mode & S_IFMT) == S_IFDIR else {
                close(next)
                throw GTELargeModelInstallError.unsafePath
            }
            close(descriptor)
            descriptor = next
        }
    }

    static func directoryIdentity(at url: URL, requiredMode: mode_t? = nil) throws -> GTELargeFileIdentity {
        try validateAncestors(of: url)
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              (status.st_mode & S_IFMT) != S_IFLNK,
              status.st_uid == getuid(),
              requiredMode.map({ (status.st_mode & 0o777) == $0 }) ?? true else {
            throw GTELargeModelInstallError.unsafePath
        }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameObject(status, opened),
              (opened.st_mode & S_IFMT) == S_IFDIR,
              requiredMode.map({ (opened.st_mode & 0o777) == $0 }) ?? true else {
            throw GTELargeModelInstallError.unsafePath
        }
        return identity(from: opened)
    }

    static func fileIdentity(at url: URL, requiredMode: mode_t? = privateFileMode) throws -> GTELargeFileIdentity {
        try validateAncestors(of: url.deletingLastPathComponent())
        var before = stat()
        guard lstat(url.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              (before.st_mode & S_IFMT) != S_IFLNK,
              before.st_uid == getuid(),
              before.st_nlink == 1,
              requiredMode.map({ (before.st_mode & 0o777) == $0 }) ?? true else {
            throw GTELargeModelInstallError.unsafePath
        }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameObject(before, opened),
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1,
              requiredMode.map({ (opened.st_mode & 0o777) == $0 }) ?? true else {
            throw GTELargeModelInstallError.unsafePath
        }
        return identity(from: opened)
    }

    static func readPrivateFile(at url: URL) throws -> Data {
        let before = try fileIdentity(at: url)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameIdentity(before, identity(from: opened)) else {
            throw GTELargeModelInstallError.unsafePath
        }
        var chunks = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
            chunks.append(buffer, count: count)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameIdentity(before, identity(from: after)) else {
            throw GTELargeModelInstallError.unsafePath
        }
        return chunks
    }

    static func hashPrivateFile(at url: URL) throws -> (String, GTELargeFileIdentity) {
        try hashFile(at: url, requiredMode: privateFileMode)
    }

    static func hashFile(at url: URL, requiredMode: mode_t?) throws -> (String, GTELargeFileIdentity) {
        let before = try fileIdentity(at: url, requiredMode: requiredMode)
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameIdentity(before, identity(from: after)) else {
            throw GTELargeModelInstallError.unsafePath
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), before)
    }

    static func copyDownloadedPayload(from source: URL, to destination: URL) throws {
        try validateAncestors(of: destination.deletingLastPathComponent())
        let sourceDescriptor = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw GTELargeModelInstallError.unreadableInstall }
        defer { close(sourceDescriptor) }
        var sourceStatus = stat()
        guard fstat(sourceDescriptor, &sourceStatus) == 0,
              (sourceStatus.st_mode & S_IFMT) == S_IFREG,
              sourceStatus.st_nlink == 1 else { throw GTELargeModelInstallError.unreadableInstall }
        let destinationDescriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            privateFileMode
        )
        guard destinationDescriptor >= 0 else { throw GTELargeModelInstallError.unreadableInstall }
        defer { close(destinationDescriptor) }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(sourceDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
            var offset = 0
            while offset < count {
                let written = Darwin.write(destinationDescriptor, buffer.withUnsafeBytes { $0.baseAddress!.advanced(by: offset) }, count - offset)
                guard written > 0 else { throw GTELargeModelInstallError.unreadableInstall }
                offset += written
            }
        }
        guard fsync(destinationDescriptor) == 0 else { throw GTELargeModelInstallError.unreadableInstall }
    }

    static func identity(from status: stat) -> GTELargeFileIdentity {
        GTELargeFileIdentity(
            size: Int64(status.st_size),
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
            linkCount: UInt64(status.st_nlink),
            mode: UInt16(status.st_mode & 0o777),
            owner: UInt32(status.st_uid)
        )
    }

    static func sameObject(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    static func sameIdentity(_ left: GTELargeFileIdentity, _ right: GTELargeFileIdentity) -> Bool {
        left == right
    }
}

protocol GTELargeFileSystem: Sendable {
    func itemExists(at url: URL) -> Bool
    func createDirectory(at url: URL, permissions: Int) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func write(_ data: Data, to url: URL, permissions: Int) throws
    func read(from url: URL) throws -> Data
    func fileIdentity(at url: URL) throws -> GTELargeFileIdentity
    func directoryIdentity(at url: URL, requiredPermissions: Int?) throws -> GTELargeFileIdentity
    func setPermissions(_ permissions: Int, at url: URL) throws
    func syncFile(at url: URL) throws
    func syncDirectory(at url: URL) throws
}

struct LocalGTELargeFileSystem: GTELargeFileSystem {
    func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL, permissions: Int) throws {
        try GTELargeSecurePath.validateAncestors(of: url.deletingLastPathComponent())
        if mkdir(url.path, mode_t(permissions)) == 0 {
            _ = try GTELargeSecurePath.directoryIdentity(at: url)
            try setPermissions(permissions, at: url)
            return
        }
        guard errno == EEXIST else {
            throw GTELargeModelInstallError.unreadableInstall
        }
        _ = try GTELargeSecurePath.directoryIdentity(at: url)
    }

    func removeItem(at url: URL) throws {
        try GTELargeSecurePath.validateAncestors(of: url.deletingLastPathComponent())
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) != S_IFLNK else {
            throw GTELargeModelInstallError.unsafePath
        }
        try FileManager.default.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        _ = try GTELargeSecurePath.directoryIdentity(at: url)
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try GTELargeSecurePath.validateAncestors(of: source.deletingLastPathComponent())
        try GTELargeSecurePath.validateAncestors(of: destination.deletingLastPathComponent())
        if rename(source.path, destination.path) != 0 {
            throw GTELargeModelInstallError.unreadableInstall
        }
        try syncDirectory(at: destination.deletingLastPathComponent())
    }

    func copyItem(at source: URL, to destination: URL) throws {
        let expectedIdentity = try GTELargeSecurePath.fileIdentity(at: source, requiredMode: nil)
        let sourceDescriptor = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(sourceDescriptor) }
        var opened = stat()
        guard fstat(sourceDescriptor, &opened) == 0,
              GTELargeSecurePath.identity(from: opened) == expectedIdentity else {
            throw GTELargeModelInstallError.unsafePath
        }
        let destinationDescriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, GTELargeSecurePath.privateFileMode)
        guard destinationDescriptor >= 0 else { throw GTELargeModelInstallError.unreadableInstall }
        defer { close(destinationDescriptor) }
        try copyBytes(from: sourceDescriptor, to: destinationDescriptor)
        guard fsync(destinationDescriptor) == 0 else { throw GTELargeModelInstallError.unreadableInstall }
    }

    func write(_ data: Data, to url: URL, permissions: Int) throws {
        try GTELargeSecurePath.validateAncestors(of: url.deletingLastPathComponent())
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(permissions))
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unreadableInstall }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw GTELargeModelInstallError.unreadableInstall }
    }

    func read(from url: URL) throws -> Data {
        try GTELargeSecurePath.readPrivateFile(at: url)
    }

    func fileIdentity(at url: URL) throws -> GTELargeFileIdentity {
        try GTELargeSecurePath.fileIdentity(at: url)
    }

    func directoryIdentity(at url: URL, requiredPermissions: Int?) throws -> GTELargeFileIdentity {
        try GTELargeSecurePath.directoryIdentity(at: url, requiredMode: requiredPermissions.map { mode_t($0) })
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        try GTELargeSecurePath.validateAncestors(of: url.deletingLastPathComponent())
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) != S_IFLNK,
              ((status.st_mode & S_IFMT) == S_IFREG || (status.st_mode & S_IFMT) == S_IFDIR) else {
            throw GTELargeModelInstallError.unsafePath
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    func syncFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw GTELargeModelInstallError.unreadableInstall }
    }

    func syncDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw GTELargeModelInstallError.unreadableInstall }
    }

    private func copyBytes(from source: Int32, to destination: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 { return }
            guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
            var offset = 0
            while offset < count {
                let written = Darwin.write(destination, buffer.withUnsafeBytes { $0.baseAddress!.advanced(by: offset) }, count - offset)
                guard written > 0 else { throw GTELargeModelInstallError.unreadableInstall }
                offset += written
            }
        }
    }
}

protocol GTELargeHashing: Sendable {
    func sha256(of url: URL) throws -> String
}

struct SHA256GTELargeHashing: GTELargeHashing {
    func sha256(of url: URL) throws -> String {
        try GTELargeSecurePath.hashPrivateFile(at: url).0
    }
}

protocol GTELargeDownloadTransport: Sendable {
    func download(
        from source: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

/// URLSession transport used by the production installer. The caller controls
/// when it is created, so model availability checks never create a request.
struct URLSessionGTELargeDownloadTransport: GTELargeDownloadTransport {
    func download(
        from source: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard GTELargeDownloadURLPolicy.accepts(source) else {
            throw GTELargeModelInstallError.invalidRedirect
        }
        let state = GTELargeURLSessionDownloadState()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let delegate = GTELargeURLSessionDownloadDelegate(
                    destination: destination,
                    expectedSize: expectedSize,
                    continuation: continuation,
                    onProgress: onProgress
                )
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 25
                configuration.timeoutIntervalForResource = 3_600
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: source)
                state.set(task)
                task.resume()
            }
        }, onCancel: {
            state.cancel()
        })
    }
}

private final class GTELargeURLSessionDownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    func set(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

enum GTELargeDownloadURLPolicy {
    static let approvedHosts: Set<String> = [
        "huggingface.co",
        "cdn-lfs.huggingface.co",
        "cas-bridge.xethub.hf.co",
    ]

    static func accepts(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              approvedHosts.contains(host) else {
            return false
        }
        // URL.host is a hostname or numeric address. Keeping this explicit
        // prevents an allowlist entry from being widened later to an IP literal.
        return host.range(of: "^[0-9a-f:.]+$", options: .regularExpression) == nil
    }

    static func acceptsRedirect(_ url: URL, redirectCount: Int) -> Bool {
        redirectCount <= 4 && accepts(url)
    }
}

private final class GTELargeURLSessionDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private static let maximumRedirects = 4
    private let destination: URL
    private let expectedSize: Int64
    private let continuation: CheckedContinuation<Void, Error>
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var completed = false
    private var redirectCount = 0

    init(
        destination: URL,
        expectedSize: Int64,
        continuation: CheckedContinuation<Void, Error>,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.continuation = continuation
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= expectedSize,
              totalBytesExpectedToWrite <= 0 || totalBytesExpectedToWrite <= expectedSize else {
            downloadTask.cancel()
            finish(session: session, result: .failure(GTELargeModelInstallError.downloadTooLarge))
            return
        }
        onProgress(min(totalBytesWritten, expectedSize))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard response.statusCode >= 300, response.statusCode < 400,
              let url = request.url,
              GTELargeDownloadURLPolicy.accepts(url) else {
            completionHandler(nil)
            finish(session: session, result: .failure(GTELargeModelInstallError.invalidRedirect))
            return
        }
        lock.lock()
        redirectCount += 1
        let tooManyRedirects = redirectCount > Self.maximumRedirects
        lock.unlock()
        guard !tooManyRedirects, GTELargeDownloadURLPolicy.acceptsRedirect(url, redirectCount: redirectCount) else {
            completionHandler(nil)
            finish(session: session, result: .failure(GTELargeModelInstallError.invalidRedirect))
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
              response.statusCode == 200,
              let finalURL = response.url,
              GTELargeDownloadURLPolicy.accepts(finalURL) else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            finish(session: session, result: .failure(GTELargeModelInstallError.httpFailure(status)))
            return
        }

        do {
            try GTELargeSecurePath.copyDownloadedPayload(from: location, to: destination)
            finish(session: session, result: .success(()))
        } catch {
            finish(session: session, result: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(session: session, result: .failure(error))
        }
    }

    private func finish(session: URLSession, result: Result<Void, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        session.invalidateAndCancel()
        continuation.resume(with: result)
    }
}

/// The verification cache only avoids a repeated full hash while every file's
/// stat identity is unchanged. It does not make a network request.
private final class GTELargeVerificationCache: @unchecked Sendable {
    static let shared = GTELargeVerificationCache()

    private let lock = NSLock()
    private struct Key: Hashable {
        let url: URL
        let revision: String
        let expectedDigest: String
    }

    private var entries: [Key: GTELargeFileIdentity] = [:]

    func contains(_ url: URL, revision: String, expectedDigest: String, identity: GTELargeFileIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[Key(url: url, revision: revision, expectedDigest: expectedDigest)] == identity
    }

    func store(_ url: URL, revision: String, expectedDigest: String, identity: GTELargeFileIdentity) {
        lock.lock()
        entries[Key(url: url, revision: revision, expectedDigest: expectedDigest)] = identity
        lock.unlock()
    }

    func removeAll(in directory: URL) {
        lock.lock()
        entries = entries.filter { !$0.key.url.path.hasPrefix(directory.path + "/") }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

/// Serializes cancellation with the irreversible pointer promotion. A cancel
/// that arrives before promotion prevents it. A cancel that arrives after the
/// promotion lock is held observes the completed, verified installation.
private final class GTELargeInstallOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    func promote(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled || Task.isCancelled { throw CancellationError() }
        try body()
    }
}

private actor GTELargeOperationCoordinator {
    static let shared = GTELargeOperationCoordinator()
    private var activeRoots: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(root: String) async {
        if activeRoots.insert(root).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[root, default: []].append(continuation)
        }
    }

    func release(root: String) {
        if var queued = waiters[root], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[root] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            activeRoots.remove(root)
        }
    }
}

private struct GTELargeInstallPointer: Codable {
    let schema: Int
    let directoryName: String
    let record: GTELargeModelInstallRecord
}

private struct GTELargePromotionJournal: Codable {
    let schema: Int
    let revision: String
    let stagingDirectoryName: String
    let backupDirectoryName: String?
    let stagingIdentity: GTELargeFileIdentity?
    let backupIdentity: GTELargeFileIdentity?
}

/// Verifies, installs, and migrates the fixed GTE-Large model set. It has no
/// implicit download path; callers must invoke `install` after user approval.
struct GTELargeModelInstaller: Sendable {
    let rootDirectory: URL
    let manifest: GTELargeModelManifest
    let fileSystem: any GTELargeFileSystem
    let hashing: any GTELargeHashing
    let transport: (any GTELargeDownloadTransport)?

    init(
        rootDirectory: URL,
        manifest: GTELargeModelManifest = .current,
        fileSystem: any GTELargeFileSystem = LocalGTELargeFileSystem(),
        hashing: any GTELargeHashing = SHA256GTELargeHashing(),
        transport: (any GTELargeDownloadTransport)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.manifest = manifest
        self.fileSystem = fileSystem
        self.hashing = hashing
        self.transport = transport
    }

    var installedDirectory: URL {
        rootDirectory.appendingPathComponent(manifest.installationDirectoryName, isDirectory: true)
    }

    private var currentPointerURL: URL {
        rootDirectory.appendingPathComponent("current.json")
    }

    private var promotionJournalURL: URL {
        rootDirectory.appendingPathComponent(".gte-large-promotion.json")
    }

    private var recordURL: URL {
        installedDirectory.appendingPathComponent("install.json")
    }

    /// Returns a verified versioned install or a verified flat legacy install.
    /// It never downloads, repairs, deletes, or accepts a partial set.
    func availableDirectory() -> URL? {
        guard manifestIsValid() else { return nil }
        if verifyVersionedInstall(at: installedDirectory) {
            return installedDirectory
        }
        if isSafeLegacyDirectory(rootDirectory), verifyFiles(in: rootDirectory) {
            return rootDirectory
        }
        return nil
    }

    /// Migrates a verified flat install to the versioned location. A valid flat
    /// install remains usable when a filesystem failure prevents migration.
    func migrateLegacyInstallIfNeeded() async throws -> URL? {
        await GTELargeOperationCoordinator.shared.acquire(root: rootDirectory.path)
        defer { Task { await GTELargeOperationCoordinator.shared.release(root: rootDirectory.path) } }
        return try await migrateLegacyInstallIfNeeded(operation: nil)
    }

    /// Performs explicit startup repair before model state is published.
    /// Availability and model loading never invoke this operation.
    func recoverAtStartup() async throws {
        await GTELargeOperationCoordinator.shared.acquire(root: rootDirectory.path)
        defer { Task { await GTELargeOperationCoordinator.shared.release(root: rootDirectory.path) } }
        try Task.checkCancellation()
        guard manifestIsValid() else { throw GTELargeModelInstallError.unsafePath }
        try ensureRootDirectory()
        try Task.checkCancellation()
        if isPrivateDirectory(rootDirectory) {
            try recoverPromotionIfNeeded()
        }
        try Task.checkCancellation()
        if !verifyVersionedInstall(at: installedDirectory) {
            _ = try await migrateLegacyInstallIfNeeded(operation: nil)
        }
    }

    private func migrateLegacyInstallIfNeeded(operation: GTELargeInstallOperation?) async throws -> URL? {
        if verifyVersionedInstall(at: installedDirectory) {
            return installedDirectory
        }
        try operation?.checkCancellation()
        try Task.checkCancellation()
        // A private root may contain other model families. Inspect it only
        // when the complete legacy file set is present at its top level.
        if isPrivateDirectory(rootDirectory),
           !manifest.files.allSatisfy({ fileSystem.itemExists(at: rootDirectory.appendingPathComponent($0.name)) }) {
            return nil
        }
        guard try prepareLegacyInstallForMigration() else { return nil }
        guard verifyFiles(in: rootDirectory) else { return nil }

        let staging = makeStagingDirectory()
        do {
            try fileSystem.createDirectory(at: staging, permissions: 0o700)
            for file in manifest.files {
                try operation?.checkCancellation()
                try Task.checkCancellation()
                let source = rootDirectory.appendingPathComponent(file.name)
                let destination = staging.appendingPathComponent(file.name)
                try fileSystem.copyItem(at: source, to: destination)
                try fileSystem.setPermissions(0o600, at: destination)
                try fileSystem.syncFile(at: destination)
            }
            try writeRecord(in: staging)
            guard verifyFiles(in: staging), verifyRecord(in: staging) else {
                throw GTELargeModelInstallError.verificationFailed
            }
            try operation?.checkCancellation()
            try Task.checkCancellation()
            if let operation {
                try operation.promote { try commit(staging: staging) }
            } else {
                try commit(staging: staging)
            }

            for file in manifest.files {
                try operation?.checkCancellation()
                try Task.checkCancellation()
                let legacyFile = rootDirectory.appendingPathComponent(file.name)
                try fileSystem.removeItem(at: legacyFile)
            }
            GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
            return installedDirectory
        } catch is CancellationError {
            if fileSystem.itemExists(at: staging) {
                try? fileSystem.removeItem(at: staging)
            }
            throw CancellationError()
        } catch {
            if fileSystem.itemExists(at: staging) {
                try? fileSystem.removeItem(at: staging)
            }
            if verifyFiles(in: rootDirectory) {
                return rootDirectory
            }
            throw error
        }
    }

    /// Downloads into a private staging directory, verifies every file, writes
    /// the install record, then atomically replaces the versioned set.
    func install(
        onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        let operation = GTELargeInstallOperation()
        return try await withTaskCancellationHandler(operation: {
            await GTELargeOperationCoordinator.shared.acquire(root: rootDirectory.path)
            defer { Task { await GTELargeOperationCoordinator.shared.release(root: rootDirectory.path) } }
            try operation.checkCancellation()
            return try await install(onProgress: onProgress, operation: operation)
        }, onCancel: {
            operation.cancel()
        })
    }

    private func install(
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        operation: GTELargeInstallOperation
    ) async throws -> URL {
        try operation.checkCancellation()
        guard manifestIsValid() else { throw GTELargeModelInstallError.unsafePath }
        try ensureRootDirectory()
        if isPrivateDirectory(rootDirectory) {
            try recoverPromotionIfNeeded()
        }
        if verifyVersionedInstall(at: installedDirectory) {
            return installedDirectory
        }
        try operation.checkCancellation()
        if let migratedLegacy = try await migrateLegacyInstallIfNeeded(operation: operation) {
            return migratedLegacy
        }
        guard let transport else {
            throw GTELargeModelInstallError.transportUnavailable
        }

        try operation.checkCancellation()
        guard isPrivateDirectory(rootDirectory) else {
            throw GTELargeModelInstallError.unsafePath
        }
        let staging = makeStagingDirectory()
        var completed: Int64 = 0

        do {
            try fileSystem.createDirectory(at: staging, permissions: 0o700)
            for file in manifest.files {
                try operation.checkCancellation()
                let destination = staging.appendingPathComponent(file.name)
                let baseCompleted = completed
                try await transport.download(
                    from: manifest.sourceURL(for: file),
                    to: destination,
                    expectedSize: file.size
                ) { written in
                    onProgress(min(baseCompleted + max(0, written), self.manifest.downloadSize), self.manifest.downloadSize)
                }
                try operation.checkCancellation()
                try fileSystem.setPermissions(0o600, at: destination)
                try fileSystem.syncFile(at: destination)
                try operation.checkCancellation()
                guard verifyFile(file, at: destination, useCache: false) else {
                    throw GTELargeModelInstallError.verificationFailed
                }
                completed += file.size
                onProgress(completed, manifest.downloadSize)
            }

            try writeRecord(in: staging)
            guard verifyFiles(in: staging), verifyRecord(in: staging) else {
                throw GTELargeModelInstallError.verificationFailed
            }
            try fileSystem.syncDirectory(at: staging)
            try operation.promote {
                try commit(staging: staging)
            }
            return installedDirectory
        } catch {
            if fileSystem.itemExists(at: staging) {
                try? fileSystem.removeItem(at: staging)
            }
            throw error
        }
    }

    func verifyFiles(in directory: URL, useCache: Bool = true) -> Bool {
        manifest.files.allSatisfy { verifyFile($0, at: directory.appendingPathComponent($0.name), useCache: useCache) }
    }

    /// App-bundle resources are code-signed by the application package, not
    /// writable download state. They are checked against the same manifest but
    /// may use the bundle's read-only permissions.
    func verifyBundledFiles(in directory: URL) -> Bool {
        manifest.files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.name)
            guard let identity = try? GTELargeSecurePath.fileIdentity(at: url, requiredMode: nil),
                  identity.size == file.size,
                  let hash = try? GTELargeSecurePath.hashFile(at: url, requiredMode: nil).0 else {
                return false
            }
            return hash.caseInsensitiveCompare(file.sha256) == .orderedSame
        }
    }

    func invalidateVerificationCacheForTesting() {
        GTELargeVerificationCache.shared.clear()
    }

    /// Removes only artifacts owned by this manifest. This is an explicit user
    /// action; availability checks never clean interrupted work.
    func deleteInstallArtifacts() async throws {
        await GTELargeOperationCoordinator.shared.acquire(root: rootDirectory.path)
        defer { Task { await GTELargeOperationCoordinator.shared.release(root: rootDirectory.path) } }
        try Task.checkCancellation()
        guard fileSystem.itemExists(at: rootDirectory) else { return }
        _ = try fileSystem.directoryIdentity(at: rootDirectory, requiredPermissions: 0o700)
        let names = try fileSystem.contentsOfDirectory(at: rootDirectory).map(\.lastPathComponent)
        let legacyNames = Set(manifest.files.map(\.name) + ["install.json"])
        for name in names where name == manifest.installationDirectoryName ||
            isOwnedVersionDirectoryName(name) ||
            name == "current.json" ||
            name == ".gte-large-promotion.json" ||
            isOwnedStagingName(name) ||
            isOwnedBackupName(name) ||
            isOwnedCurrentTemporaryName(name) ||
            isOwnedJournalTemporaryName(name) ||
            legacyNames.contains(name) {
            let candidate = rootDirectory.appendingPathComponent(name)
            try fileSystem.removeItem(at: candidate)
            try Task.checkCancellation()
        }
        try fileSystem.syncDirectory(at: rootDirectory)
        GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
    }

    private func verifyVersionedInstall(at directory: URL) -> Bool {
        guard isPrivateDirectory(rootDirectory),
              isPrivateDirectory(directory),
              let pointerData = try? readSmallFile(at: currentPointerURL),
              let pointer = try? JSONDecoder().decode(GTELargeInstallPointer.self, from: pointerData),
              pointer.schema == 1,
              pointer.directoryName == manifest.installationDirectoryName,
              pointer.record.matches(manifest) else {
            return false
        }
        return verifyRecord(in: directory) && verifyFiles(in: directory)
    }

    private func verifyRecord(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("install.json")
        guard let data = try? readSmallFile(at: url),
              let record = try? JSONDecoder().decode(GTELargeModelInstallRecord.self, from: data) else {
            return false
        }
        return record.matches(manifest)
    }

    private func verifyFile(_ file: GTELargeModelManifest.File, at url: URL, useCache: Bool) -> Bool {
        guard let identity = try? fileSystem.fileIdentity(at: url), identity.size == file.size else {
            return false
        }
        if useCache && GTELargeVerificationCache.shared.contains(
            url,
            revision: manifest.revision,
            expectedDigest: file.sha256,
            identity: identity
        ) {
            return true
        }
        guard let hash = try? hashing.sha256(of: url),
              hash.caseInsensitiveCompare(file.sha256) == .orderedSame,
              let postHashIdentity = try? fileSystem.fileIdentity(at: url),
              postHashIdentity == identity else {
            return false
        }
        GTELargeVerificationCache.shared.store(
            url,
            revision: manifest.revision,
            expectedDigest: file.sha256,
            identity: identity
        )
        return true
    }

    private func writeRecord(in directory: URL) throws {
        let data = try JSONEncoder().encode(GTELargeModelInstallRecord(manifest: manifest))
        try fileSystem.write(data, to: directory.appendingPathComponent("install.json"), permissions: 0o600)
    }

    private func writeCurrentPointer() throws {
        let pointer = GTELargeInstallPointer(
            schema: 1,
            directoryName: manifest.installationDirectoryName,
            record: GTELargeModelInstallRecord(manifest: manifest)
        )
        let temporary = rootDirectory.appendingPathComponent(".gte-large-current-\(UUID().uuidString)")
        try fileSystem.write(try JSONEncoder().encode(pointer), to: temporary, permissions: 0o600)
        do {
            try fileSystem.moveItem(at: temporary, to: currentPointerURL)
            try fileSystem.syncDirectory(at: rootDirectory)
        } catch {
            if fileSystem.itemExists(at: temporary) { try? fileSystem.removeItem(at: temporary) }
            throw error
        }
    }

    private func writeJournal(staging: URL, backup: URL?) throws {
        let stagingIdentity = try fileSystem.directoryIdentity(at: staging, requiredPermissions: 0o700)
        let backupIdentity: GTELargeFileIdentity?
        if let backup {
            // The backup name is not present until commit renames the old
            // install. Record that directory's identity before the rename.
            backupIdentity = try fileSystem.itemExists(at: backup)
                ? fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700)
                : fileSystem.directoryIdentity(at: installedDirectory, requiredPermissions: 0o700)
        } else {
            backupIdentity = nil
        }
        let journal = GTELargePromotionJournal(
            schema: 1,
            revision: manifest.revision,
            stagingDirectoryName: staging.lastPathComponent,
            backupDirectoryName: backup?.lastPathComponent,
            stagingIdentity: stagingIdentity,
            backupIdentity: backupIdentity
        )
        let temporary = rootDirectory.appendingPathComponent(".gte-large-journal-\(UUID().uuidString)")
        try fileSystem.write(try JSONEncoder().encode(journal), to: temporary, permissions: 0o600)
        do {
            try fileSystem.moveItem(at: temporary, to: promotionJournalURL)
            try fileSystem.syncDirectory(at: rootDirectory)
        } catch {
            if fileSystem.itemExists(at: temporary) { try? fileSystem.removeItem(at: temporary) }
            throw error
        }
    }

    private func commit(staging: URL) throws {
        let backup = rootDirectory.appendingPathComponent(".gte-large-previous-\(UUID().uuidString)", isDirectory: true)
        var movedExisting = false

        do {
            if fileSystem.itemExists(at: installedDirectory) {
                try writeJournal(staging: staging, backup: backup)
                try fileSystem.moveItem(at: installedDirectory, to: backup)
                movedExisting = true
            } else {
                try writeJournal(staging: staging, backup: nil)
            }
            try fileSystem.moveItem(at: staging, to: installedDirectory)
            try writeCurrentPointer()
            if movedExisting, fileSystem.itemExists(at: backup) {
                try? fileSystem.removeItem(at: backup)
            }
            if fileSystem.itemExists(at: promotionJournalURL) {
                try fileSystem.removeItem(at: promotionJournalURL)
            }
            try fileSystem.syncDirectory(at: rootDirectory)
            GTELargeVerificationCache.shared.removeAll(in: installedDirectory)
        } catch {
            if movedExisting, !fileSystem.itemExists(at: installedDirectory), fileSystem.itemExists(at: backup) {
                try? fileSystem.moveItem(at: backup, to: installedDirectory)
            }
            throw error
        }
    }

    private func makeStagingDirectory() -> URL {
        rootDirectory.appendingPathComponent(".gte-large-staging-\(UUID().uuidString)", isDirectory: true)
    }

    private func ensureRootDirectory() throws {
        if fileSystem.itemExists(at: rootDirectory) {
            try fileSystem.createDirectory(at: rootDirectory, permissions: 0o700)
            return
        }
        var missing: [URL] = []
        var cursor = rootDirectory
        while !fileSystem.itemExists(at: cursor) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { throw GTELargeModelInstallError.unsafePath }
            cursor = parent
        }
        _ = try fileSystem.directoryIdentity(at: cursor, requiredPermissions: nil)
        for directory in missing.reversed() {
            try fileSystem.createDirectory(at: directory, permissions: 0o700)
        }
    }

    /// Legacy files predate the private install layout. Permission repair is
    /// limited to regular, single-link files owned by the current user and is
    /// performed only after the user requests an explicit installation action.
    private func prepareLegacyInstallForMigration() throws -> Bool {
        var rootStatus = stat()
        guard lstat(rootDirectory.path, &rootStatus) == 0 else {
            if errno == ENOENT { return false }
            throw GTELargeModelInstallError.unsafePath
        }
        try GTELargeSecurePath.validateAncestors(of: rootDirectory.deletingLastPathComponent())
        guard (rootStatus.st_mode & S_IFMT) == S_IFDIR,
              (rootStatus.st_mode & S_IFMT) != S_IFLNK,
              rootStatus.st_uid == getuid() else {
            throw GTELargeModelInstallError.unsafePath
        }
        let allowedNames = Set(manifest.files.map(\.name) + ["install.json"])
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard entries.allSatisfy({ allowedNames.contains($0.lastPathComponent) }) else {
            throw GTELargeModelInstallError.unsafePath
        }

        var presentFiles = Set<String>()
        for entry in entries {
            let url = rootDirectory.appendingPathComponent(entry.lastPathComponent)
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw GTELargeModelInstallError.unsafePath
            }
            guard (status.st_mode & S_IFMT) == S_IFREG,
                  (status.st_mode & S_IFMT) != S_IFLNK,
                  status.st_nlink == 1,
                  status.st_uid == getuid() else {
                throw GTELargeModelInstallError.unsafePath
            }
            presentFiles.insert(entry.lastPathComponent)
        }
        try fileSystem.setPermissions(0o700, at: rootDirectory)
        for name in presentFiles {
            try fileSystem.setPermissions(0o600, at: rootDirectory.appendingPathComponent(name))
        }
        try fileSystem.syncDirectory(at: rootDirectory)
        return Set(manifest.files.map(\.name)).isSubset(of: presentFiles)
    }

    private func recoverPromotionIfNeeded() throws {
        guard fileSystem.itemExists(at: promotionJournalURL) else {
            try removeOwnedOrphanStagingDirectories()
            return
        }
        guard let data = try? readSmallFile(at: promotionJournalURL),
              let journal = try? JSONDecoder().decode(GTELargePromotionJournal.self, from: data),
              journal.schema == 1,
              journal.revision == manifest.revision,
              isOwnedStagingName(journal.stagingDirectoryName),
              journal.backupDirectoryName.map(isOwnedBackupName) ?? true,
              let stagingIdentity = journal.stagingIdentity,
              (journal.backupDirectoryName == nil) == (journal.backupIdentity == nil),
              let staging = safeChild(named: journal.stagingDirectoryName) else {
            try quarantineInvalidRecoveryArtifacts()
            return
        }
        let backup = journal.backupDirectoryName.flatMap(safeChild(named:))

        if isPrivateDirectory(installedDirectory),
           (try? fileSystem.directoryIdentity(at: installedDirectory, requiredPermissions: 0o700)) == stagingIdentity,
           verifyRecord(in: installedDirectory), verifyFiles(in: installedDirectory) {
            try writeCurrentPointer()
        } else if let backup,
                  let backupIdentity = journal.backupIdentity,
                  (try? fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700)) == backupIdentity,
                  verifyRecord(in: backup), verifyFiles(in: backup) {
            if fileSystem.itemExists(at: installedDirectory) {
                // A name collision after an interrupted promotion is not safe
                // to remove. The journal proves only the recorded objects.
                throw GTELargeModelInstallError.unsafePath
            }
            try fileSystem.moveItem(at: backup, to: installedDirectory)
            try writeCurrentPointer()
        } else if isPrivateDirectory(staging),
                  (try? fileSystem.directoryIdentity(at: staging, requiredPermissions: 0o700)) == stagingIdentity,
                  verifyRecord(in: staging), verifyFiles(in: staging) {
            if fileSystem.itemExists(at: installedDirectory) {
                throw GTELargeModelInstallError.unsafePath
            }
            try fileSystem.moveItem(at: staging, to: installedDirectory)
            try writeCurrentPointer()
        } else {
            throw GTELargeModelInstallError.verificationFailed
        }
        if fileSystem.itemExists(at: staging),
           (try? fileSystem.directoryIdentity(at: staging, requiredPermissions: 0o700)) == stagingIdentity {
            try? fileSystem.removeItem(at: staging)
        }
        if let backup,
           let backupIdentity = journal.backupIdentity,
           fileSystem.itemExists(at: backup),
           (try? fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700)) == backupIdentity {
            try? fileSystem.removeItem(at: backup)
        }
        try fileSystem.removeItem(at: promotionJournalURL)
        try fileSystem.syncDirectory(at: rootDirectory)
        GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
    }

    private func isPrivateDirectory(_ url: URL) -> Bool {
        (try? fileSystem.directoryIdentity(at: url, requiredPermissions: 0o700)) != nil
    }

    private func isSafeLegacyDirectory(_ url: URL) -> Bool {
        guard isPrivateDirectory(url) else { return false }
        return manifest.files.allSatisfy { file in
            guard let identity = try? fileSystem.fileIdentity(at: url.appendingPathComponent(file.name)) else { return false }
            return identity.mode == 0o600 && identity.linkCount == 1
        }
    }

    private func readSmallFile(at url: URL, limit: Int64 = 65_536) throws -> Data {
        let identity = try fileSystem.fileIdentity(at: url)
        guard identity.size >= 0, identity.size <= limit else { throw GTELargeModelInstallError.unreadableInstall }
        let data = try fileSystem.read(from: url)
        guard data.count <= Int(limit) else { throw GTELargeModelInstallError.unreadableInstall }
        return data
    }

    private func manifestIsValid() -> Bool {
        guard manifest.formatVersion == 1,
              manifest.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              isSafePathComponent(manifest.installationDirectoryName),
              manifest.files.count == Set(manifest.files.map(\.name)).count else { return false }
        return manifest.files.allSatisfy {
            isSafePathComponent($0.name) && $0.size >= 0 &&
                $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        }
    }

    private func isSafePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.hasPrefix("~") &&
            URL(fileURLWithPath: name).lastPathComponent == name
    }

    private func safeChild(named name: String) -> URL? {
        guard isSafePathComponent(name) else { return nil }
        let child = rootDirectory.appendingPathComponent(name, isDirectory: true)
        guard child.path.hasPrefix(rootDirectory.path + "/") else { return nil }
        return child
    }

    private func isOwnedStagingName(_ name: String) -> Bool {
        let prefix = ".gte-large-staging-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedBackupName(_ name: String) -> Bool {
        let prefix = ".gte-large-previous-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedCurrentTemporaryName(_ name: String) -> Bool {
        let prefix = ".gte-large-current-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedJournalTemporaryName(_ name: String) -> Bool {
        let prefix = ".gte-large-journal-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedVersionDirectoryName(_ name: String) -> Bool {
        let prefix = "gte-large-"
        let revision = String(name.dropFirst(prefix.count))
        return name.hasPrefix(prefix) && revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    private func quarantineInvalidRecoveryArtifacts() throws {
        let entries = try fileSystem.contentsOfDirectory(at: rootDirectory)
        for entry in entries where entry.lastPathComponent == ".gte-large-promotion.json" ||
            isOwnedStagingName(entry.lastPathComponent) || isOwnedBackupName(entry.lastPathComponent) ||
            isOwnedJournalTemporaryName(entry.lastPathComponent) {
            try fileSystem.removeItem(at: entry)
        }
        try fileSystem.syncDirectory(at: rootDirectory)
        GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
    }

    private func removeOwnedOrphanStagingDirectories() throws {
        for entry in try fileSystem.contentsOfDirectory(at: rootDirectory) where isOwnedStagingName(entry.lastPathComponent) {
            guard let identity = try? fileSystem.directoryIdentity(at: entry, requiredPermissions: 0o700),
                  identity.owner == UInt32(getuid()) else { continue }
            try fileSystem.removeItem(at: entry)
        }
        try fileSystem.syncDirectory(at: rootDirectory)
    }
}

enum GTELargeModelInstallError: LocalizedError {
    case transportUnavailable
    case verificationFailed
    case unreadableInstall
    case unsafePath
    case downloadTooLarge
    case invalidRedirect
    case httpFailure(Int)

    var errorDescription: String? {
        switch self {
        case .transportUnavailable:
            return "GTE-Large download transport is unavailable"
        case .verificationFailed:
            return "GTE-Large download could not be verified"
        case .unreadableInstall:
            return "GTE-Large installation could not be read"
        case .unsafePath:
            return "GTE-Large installation could not be verified"
        case .downloadTooLarge:
            return "GTE-Large download exceeded its expected size"
        case .invalidRedirect:
            return "GTE-Large download redirect could not be verified"
        case .httpFailure:
            return "GTE-Large download request failed"
        }
    }
}
