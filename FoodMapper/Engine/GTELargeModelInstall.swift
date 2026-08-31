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
    /// Upstream source used to produce the fixed MLX artifact. These fields
    /// are source provenance, not alternate download locations.
    let upstreamRepositoryID: String
    let upstreamRevision: String
    let upstreamLicense: String
    let conversion: String
    let files: [File]

    static let current = GTELargeModelManifest(
        formatVersion: 1,
        repositoryID: "richtext/foodmapper-gte-large",
        // `200d1bf` changes the artifact card and license metadata only. The
        // six installed payload objects retain the hashes below from `0b7a788`.
        revision: "200d1bf79e6a152736fe1517703d0079a0bd16fa",
        upstreamRepositoryID: "thenlper/gte-large",
        upstreamRevision: "4bef63f39fcc5e2d6b0aae83089f307af4970164",
        upstreamLicense: "MIT",
        conversion: "MLX-Swift float16 BERT safetensors conversion",
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

/// An immutable descriptor-walk snapshot used to bind recovery removal to the
/// exact private descendants that were counted before removal starts.
indirect enum GTELargePrivateTreeEntry: Sendable {
    case file(name: String, identity: GTELargeFileIdentity)
    case directory(name: String, identity: GTELargeFileIdentity, children: [GTELargePrivateTreeEntry])

    var name: String {
        switch self {
        case .file(let name, _), .directory(let name, _, _):
            return name
        }
    }

    var identity: GTELargeFileIdentity {
        switch self {
        case .file(_, let identity), .directory(_, let identity, _):
            return identity
        }
    }

    var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }
}

/// A private recovery artifact observed through a held descriptor walk. Every
/// descendant identity is preserved so a later recovery pass cannot remove a
/// replacement that was not part of the accounting snapshot.
struct GTELargePrivateTree: Sendable {
    let identity: GTELargeFileIdentity
    let isDirectory: Bool
    let entries: Int
    let bytes: Int64
    let children: [GTELargePrivateTreeEntry]
}

enum GTELargeSecurePath {
    static let privateDirectoryMode: mode_t = 0o700
    static let privateFileMode: mode_t = 0o600

    static func isSafePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\u{0}") &&
            URL(fileURLWithPath: name).lastPathComponent == name
    }

    /// Opens the directory through already-open parent descriptors. Do not
    /// standardize the URL: `/private/tmp` and `/tmp` are distinct path walks
    /// on this platform, even though the latter is a symlink by design.
    static func openDirectoryDescriptor(at url: URL, allowMissingLeaf: Bool = false) throws -> Int32 {
        let components = url.pathComponents
        guard components.first == "/" else { throw GTELargeModelInstallError.unsafePath }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        let remaining = Array(components.dropFirst())
        for (index, component) in remaining.enumerated() {
            guard isSafePathComponent(component) else {
                close(descriptor)
                throw GTELargeModelInstallError.unsafePath
            }
            var expected = stat()
            let present = component.withCString {
                fstatat(descriptor, $0, &expected, AT_SYMLINK_NOFOLLOW)
            }
            if present != 0 {
                if errno == ENOENT && allowMissingLeaf && index == remaining.count - 1 {
                    return descriptor
                }
                close(descriptor)
                throw GTELargeModelInstallError.unsafePath
            }
            guard (expected.st_mode & S_IFMT) == S_IFDIR,
                  (expected.st_mode & S_IFMT) != S_IFLNK else {
                close(descriptor)
                throw GTELargeModelInstallError.unsafePath
            }
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                close(descriptor)
                throw GTELargeModelInstallError.unsafePath
            }
            var opened = stat()
            guard fstat(next, &opened) == 0,
                  sameObject(expected, opened),
                  (opened.st_mode & S_IFMT) == S_IFDIR else {
                close(next)
                close(descriptor)
                throw GTELargeModelInstallError.unsafePath
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    static func withParentDescriptor<T>(of url: URL, _ body: (Int32, String) throws -> T) throws -> T {
        let parent = try openDirectoryDescriptor(at: url.deletingLastPathComponent())
        defer { close(parent) }
        let name = url.lastPathComponent
        guard isSafePathComponent(name) else {
            throw GTELargeModelInstallError.unsafePath
        }
        return try body(parent, name)
    }

    static func itemExists(at url: URL) -> Bool {
        (try? withParentDescriptor(of: url) { parent, name in
            var status = stat()
            guard name.withCString({ fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0,
                  (status.st_mode & S_IFMT) != S_IFLNK else {
                return false
            }
            return true
        }) ?? false
    }

    static func directoryEntries(at url: URL, maximumEntries: Int) throws -> [URL] {
        guard maximumEntries > 0 else { throw GTELargeModelInstallError.unsafePath }
        let descriptor = try openDirectoryDescriptor(at: url)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid() else {
            throw GTELargeModelInstallError.unsafePath
        }
        guard let stream = fdopendir(dup(descriptor)) else {
            throw GTELargeModelInstallError.unreadableInstall
        }
        defer { closedir(stream) }
        var entries: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw GTELargeModelInstallError.unreadableInstall }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard isSafePathComponent(name) else {
                throw GTELargeModelInstallError.unsafePath
            }
            // Stop before growing the collection beyond the caller's recovery
            // budget. Recovery must not first allocate an attacker-controlled
            // directory listing and then decide that it was too large.
            guard entries.count < maximumEntries else {
                throw GTELargeModelInstallError.unsafePath
            }
            entries.append(url.appendingPathComponent(name, isDirectory: false))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameObject(status, after) else {
            throw GTELargeModelInstallError.unsafePath
        }
        return entries
    }

    static func legacyFileIdentity(at url: URL) throws -> GTELargeFileIdentity {
        try withParentDescriptor(of: url) { parent, name in
            var before = stat()
            guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_uid == getuid(), before.st_nlink == 1 else {
                throw GTELargeModelInstallError.unsafePath
            }
            let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, sameObject(before, opened) else {
                throw GTELargeModelInstallError.unsafePath
            }
            return identity(from: opened)
        }
    }

    static func removePrivateItem(at url: URL, expectedDirectoryIdentity: GTELargeFileIdentity? = nil) throws {
        let tree = try privateTree(
            at: url,
            maximumEntries: 4_096,
            maximumDepth: 16,
            maximumBytes: 2_147_483_648
        )
        if let expectedDirectoryIdentity {
            guard tree.isDirectory,
                  sameDirectoryIdentity(tree.identity, expectedDirectoryIdentity) else {
                throw GTELargeModelInstallError.unsafePath
            }
        }
        try removePrivateTree(at: url, tree: tree, maximumDepth: 16)
    }

    static func removePrivateItem(at url: URL, expectedFileIdentity: GTELargeFileIdentity) throws {
        let tree = try privateTree(
            at: url,
            maximumEntries: 1,
            maximumDepth: 0,
            maximumBytes: 2_147_483_648
        )
        guard !tree.isDirectory,
              sameFileIdentity(tree.identity, expectedFileIdentity) else {
            throw GTELargeModelInstallError.unsafePath
        }
        try removePrivateTree(at: url, tree: tree, maximumDepth: 0)
    }

    private struct PrivateTreeBudget {
        let maximumEntries: Int
        let maximumDepth: Int
        let maximumBytes: Int64
        var entries = 0
        var bytes: Int64 = 0

        mutating func consume(_ status: stat, depth: Int) throws {
            guard depth <= maximumDepth, entries < maximumEntries else {
                throw GTELargeModelInstallError.unsafePath
            }
            entries += 1
            guard (status.st_mode & S_IFMT) == S_IFREG else { return }
            let size = Int64(truncatingIfNeeded: status.st_size)
            guard size >= 0 else { throw GTELargeModelInstallError.unsafePath }
            let (next, overflow) = bytes.addingReportingOverflow(size)
            guard !overflow, next <= maximumBytes else {
                throw GTELargeModelInstallError.unsafePath
            }
            bytes = next
        }
    }

    private struct PrivateRemovalBudget {
        let maximumEntries: Int
        let maximumDepth: Int
        let maximumBytes: Int64
        var entries = 0
        var bytes: Int64 = 0

        init(maximumEntries: Int, maximumDepth: Int, maximumBytes: Int64) {
            self.maximumEntries = maximumEntries
            self.maximumDepth = maximumDepth
            self.maximumBytes = maximumBytes
        }

        mutating func consume(_ status: stat, depth: Int) throws {
            guard depth <= maximumDepth, entries < maximumEntries else {
                throw GTELargeModelInstallError.unsafePath
            }
            entries += 1
            guard (status.st_mode & S_IFMT) == S_IFREG else { return }
            let size = Int64(truncatingIfNeeded: status.st_size)
            guard size >= 0 else { throw GTELargeModelInstallError.unsafePath }
            let (next, overflow) = bytes.addingReportingOverflow(size)
            guard !overflow, next <= maximumBytes else {
                throw GTELargeModelInstallError.unsafePath
            }
            bytes = next
        }
    }

    /// Counts a private regular-file or directory tree before recovery acts on
    /// it. Traversal uses descriptor-relative operations and rejects symlinks,
    /// foreign owners, non-private modes, hard links, excess depth, and excess
    /// bytes before hashing, copying, or removal starts.
    static func privateTree(
        at url: URL,
        maximumEntries: Int,
        maximumDepth: Int,
        maximumBytes: Int64
    ) throws -> GTELargePrivateTree {
        guard maximumEntries > 0, maximumDepth >= 0, maximumBytes >= 0 else {
            throw GTELargeModelInstallError.unsafePath
        }
        return try withParentDescriptor(of: url) { parent, name in
            var root = stat()
            guard name.withCString({ fstatat(parent, $0, &root, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw GTELargeModelInstallError.unsafePath
            }
            let rootType = root.st_mode & S_IFMT
            guard root.st_uid == getuid(),
                  (rootType == S_IFREG && root.st_nlink == 1 && (root.st_mode & 0o777) == privateFileMode) ||
                    (rootType == S_IFDIR && (root.st_mode & 0o777) == privateDirectoryMode) else {
                throw GTELargeModelInstallError.unsafePath
            }
            let rootIdentity = identity(from: root)
            var budget = PrivateTreeBudget(
                maximumEntries: maximumEntries,
                maximumDepth: maximumDepth,
                maximumBytes: maximumBytes
            )
            let rootEntry = try snapshotPrivateTreeEntry(
                parent: parent,
                name: name,
                expected: root,
                budget: &budget
            )
            let children: [GTELargePrivateTreeEntry]
            if case .directory(_, _, let recordedChildren) = rootEntry {
                children = recordedChildren
            } else {
                children = []
            }
            return GTELargePrivateTree(
                identity: rootIdentity,
                isDirectory: rootType == S_IFDIR,
                entries: budget.entries,
                bytes: budget.bytes,
                children: children
            )
        }
    }

    private static func snapshotPrivateTreeEntry(
        parent: Int32,
        name: String,
        expected: stat,
        budget: inout PrivateTreeBudget,
        depth: Int = 0
    ) throws -> GTELargePrivateTreeEntry {
        let type = expected.st_mode & S_IFMT
        guard expected.st_uid == getuid(),
              (type == S_IFREG && expected.st_nlink == 1 && (expected.st_mode & 0o777) == privateFileMode) ||
              (type == S_IFDIR && (expected.st_mode & 0o777) == privateDirectoryMode) else {
            throw GTELargeModelInstallError.unsafePath
        }
        try budget.consume(expected, depth: depth)
        let recordedIdentity = identity(from: expected)
        guard type == S_IFDIR else {
            return .file(name: name, identity: recordedIdentity)
        }

        let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, sameObject(expected, opened) else {
            throw GTELargeModelInstallError.unsafePath
        }
        guard let stream = fdopendir(dup(descriptor)) else {
            throw GTELargeModelInstallError.unreadableInstall
        }
        defer { closedir(stream) }
        var children: [GTELargePrivateTreeEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw GTELargeModelInstallError.unreadableInstall }
                break
            }
            let child = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard child != ".", child != ".." else { continue }
            guard isSafePathComponent(child) else { throw GTELargeModelInstallError.unsafePath }
            var childStatus = stat()
            guard child.withCString({ fstatat(descriptor, $0, &childStatus, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw GTELargeModelInstallError.unsafePath
            }
            let childEntry = try snapshotPrivateTreeEntry(
                parent: descriptor,
                name: child,
                expected: childStatus,
                budget: &budget,
                depth: depth + 1
            )
            children.append(childEntry)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameIdentity(identity(from: expected), identity(from: after)) else {
            throw GTELargeModelInstallError.unsafePath
        }
        children.sort { $0.name < $1.name }
        return .directory(name: name, identity: recordedIdentity, children: children)
    }

    static func removePrivateTree(at url: URL, tree: GTELargePrivateTree, maximumDepth: Int) throws {
        try withParentDescriptor(of: url) { parent, name in
            var root = stat()
            guard name.withCString({ fstatat(parent, $0, &root, AT_SYMLINK_NOFOLLOW) }) == 0,
                  (root.st_mode & S_IFMT) == (tree.isDirectory ? S_IFDIR : S_IFREG),
                  (tree.isDirectory
                    ? sameDirectoryIdentity(identity(from: root), tree.identity)
                    : sameFileIdentity(identity(from: root), tree.identity)) else {
                throw GTELargeModelInstallError.unsafePath
            }
            let rootEntry: GTELargePrivateTreeEntry = tree.isDirectory
                ? .directory(name: name, identity: tree.identity, children: tree.children)
                : .file(name: name, identity: tree.identity)

            // Validate every recorded descendant before quarantining anything.
            // A changed byte count, replacement with equal accounting, or an
            // added descendant fails before this recovery action removes a
            // single object.
            try verifyPrivateTreeEntry(
                parent: parent,
                entry: rootEntry,
                maximumDepth: maximumDepth
            )
            var budget = PrivateRemovalBudget(
                maximumEntries: tree.entries,
                maximumDepth: maximumDepth,
                maximumBytes: tree.bytes
            )
            try removeSnapshotPrivateTreeEntry(
                parent: parent,
                entry: rootEntry,
                budget: &budget,
                depth: 0
            )
            guard budget.entries == tree.entries,
                  budget.bytes == tree.bytes,
                  fsync(parent) == 0 else {
                throw GTELargeModelInstallError.unsafePath
            }
        }
    }

    private static func verifyPrivateTreeEntry(
        parent: Int32,
        entry: GTELargePrivateTreeEntry,
        maximumDepth: Int,
        depth: Int = 0
    ) throws {
        try Task.checkCancellation()
        guard depth <= maximumDepth else { throw GTELargeModelInstallError.unsafePath }
        var current = stat()
        guard entry.name.withCString({ fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              matchesSnapshotIdentity(identity(from: current), entry: entry) else {
            throw GTELargeModelInstallError.unsafePath
        }
        guard case .directory(_, _, let children) = entry else { return }

        let descriptor = entry.name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameObject(current, opened) else {
            throw GTELargeModelInstallError.unsafePath
        }
        let expectedNames = Set(children.map(\.name))
        guard expectedNames.count == children.count,
              try directoryEntryNames(descriptor, maximumEntries: children.count) == expectedNames else {
            throw GTELargeModelInstallError.unsafePath
        }
        for child in children {
            try verifyPrivateTreeEntry(
                parent: descriptor,
                entry: child,
                maximumDepth: maximumDepth,
                depth: depth + 1
            )
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameIdentity(identity(from: opened), identity(from: after)) else {
            throw GTELargeModelInstallError.unsafePath
        }
    }

    private static func removeSnapshotPrivateTreeEntry(
        parent: Int32,
        entry: GTELargePrivateTreeEntry,
        budget: inout PrivateRemovalBudget,
        depth: Int
    ) throws {
        try Task.checkCancellation()
        var expected = stat()
        expected.st_size = off_t(truncatingIfNeeded: entry.identity.size)
        expected.st_dev = dev_t(truncatingIfNeeded: entry.identity.device)
        expected.st_ino = ino_t(truncatingIfNeeded: entry.identity.inode)
        expected.st_ctimespec.tv_sec = time_t(truncatingIfNeeded: entry.identity.changeSeconds)
        expected.st_ctimespec.tv_nsec = Int(truncatingIfNeeded: entry.identity.changeNanoseconds)
        expected.st_nlink = nlink_t(truncatingIfNeeded: entry.identity.linkCount)
        expected.st_mode = mode_t(truncatingIfNeeded: entry.identity.mode) |
            (entry.isDirectory ? S_IFDIR : S_IFREG)
        expected.st_uid = uid_t(truncatingIfNeeded: entry.identity.owner)
        try budget.consume(expected, depth: depth)

        let quarantinedName = try quarantinePrivateEntry(parent: parent, name: entry.name, expected: expected)
        guard case .directory(_, _, let children) = entry else {
            try removeQuarantinedPrivateEntry(parent: parent, name: quarantinedName, expected: expected, flags: 0)
            return
        }

        let descriptor = quarantinedName.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              sameObject(expected, opened),
              opened.st_uid == getuid(),
              (opened.st_mode & S_IFMT) == S_IFDIR,
              (opened.st_mode & 0o777) == privateDirectoryMode else {
            throw GTELargeModelInstallError.unsafePath
        }
        let expectedNames = Set(children.map(\.name))
        guard expectedNames.count == children.count,
              try directoryEntryNames(descriptor, maximumEntries: children.count) == expectedNames else {
            throw GTELargeModelInstallError.unsafePath
        }
        for child in children {
            try removeSnapshotPrivateTreeEntry(
                parent: descriptor,
                entry: child,
                budget: &budget,
                depth: depth + 1
            )
        }
        try removeQuarantinedPrivateEntry(
            parent: parent,
            name: quarantinedName,
            expected: expected,
            flags: AT_REMOVEDIR
        )
    }

    private static func matchesSnapshotIdentity(
        _ identity: GTELargeFileIdentity,
        entry: GTELargePrivateTreeEntry
    ) -> Bool {
        switch entry {
        case .file(_, let expected):
            return sameIdentity(identity, expected)
        case .directory(_, let expected, _):
            return sameIdentity(identity, expected)
        }
    }

    private static func directoryEntryNames(_ descriptor: Int32, maximumEntries: Int) throws -> Set<String> {
        try directoryEntryNames(descriptor, maximumEntries: maximumEntries, read: readdir)
    }

    private static func directoryEntryNames(
        _ descriptor: Int32,
        maximumEntries: Int,
        read: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?
    ) throws -> Set<String> {
        guard maximumEntries >= 0 else { throw GTELargeModelInstallError.unsafePath }
        guard let stream = fdopendir(dup(descriptor)) else {
            throw GTELargeModelInstallError.unreadableInstall
        }
        defer { closedir(stream) }
        var names = Set<String>()
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = read(stream) else {
                guard errno == 0 else { throw GTELargeModelInstallError.unreadableInstall }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard isSafePathComponent(name) else {
                throw GTELargeModelInstallError.unsafePath
            }
            guard names.count < maximumEntries,
                  names.insert(name).inserted else {
                throw GTELargeModelInstallError.unsafePath
            }
        }
        return names
    }

    #if DEBUG
    static func directoryEntryNamesForTesting(
        _ descriptor: Int32,
        maximumEntries: Int,
        read: (UnsafeMutablePointer<DIR>) -> UnsafeMutablePointer<dirent>?
    ) throws -> Set<String> {
        try directoryEntryNames(descriptor, maximumEntries: maximumEntries, read: read)
    }
    #endif

    private static func quarantinePrivateEntry(parent: Int32, name: String, expected: stat) throws -> String {
        let recordedIdentity = identity(from: expected)
        var current = stat()
        guard name.withCString({ fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              sameIdentity(recordedIdentity, identity(from: current)) else {
            throw GTELargeModelInstallError.unsafePath
        }

        let quarantinedName = ".gte-large-removing-\(UUID().uuidString)"
        let result = name.withCString { source in
            quarantinedName.withCString { destination in
                renameatx_np(parent, source, parent, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw GTELargeModelInstallError.unsafePath }

        var moved = stat()
        let type = expected.st_mode & S_IFMT
        guard quarantinedName.withCString({ fstatat(parent, $0, &moved, AT_SYMLINK_NOFOLLOW) }) == 0,
              sameObject(expected, moved),
              moved.st_uid == getuid(),
              moved.st_size == off_t(truncatingIfNeeded: recordedIdentity.size),
              moved.st_nlink == nlink_t(truncatingIfNeeded: recordedIdentity.linkCount),
              (type == S_IFREG && (moved.st_mode & S_IFMT) == S_IFREG && moved.st_nlink == 1 && (moved.st_mode & 0o777) == privateFileMode) ||
              (type == S_IFDIR && (moved.st_mode & S_IFMT) == S_IFDIR && (moved.st_mode & 0o777) == privateDirectoryMode),
              fsync(parent) == 0 else {
            throw GTELargeModelInstallError.unsafePath
        }
        return quarantinedName
    }

    private static func removeQuarantinedPrivateEntry(
        parent: Int32,
        name: String,
        expected: stat,
        flags: Int32
    ) throws {
        var current = stat()
        guard name.withCString({ fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0,
              sameObject(expected, current),
              current.st_uid == getuid(),
              (current.st_mode & S_IFMT) == (flags == AT_REMOVEDIR ? S_IFDIR : S_IFREG),
              flags == AT_REMOVEDIR || current.st_nlink == 1 else {
            throw GTELargeModelInstallError.unsafePath
        }
        // Darwin has no expected-inode removal call. The rename, descriptor
        // walk, and final identity check stop on observed mutation. A hostile
        // same-UID process can still replace this private name after the check;
        // that final kernel window is outside the supported threat boundary.
        guard name.withCString({ unlinkat(parent, $0, flags) }) == 0 else {
            throw GTELargeModelInstallError.unreadableInstall
        }
    }

    static func directoryIdentity(at url: URL, requiredMode: mode_t? = nil) throws -> GTELargeFileIdentity {
        let descriptor = try openDirectoryDescriptor(at: url)
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFDIR,
              opened.st_uid == getuid(),
              requiredMode.map({ (opened.st_mode & 0o777) == $0 }) ?? true else {
            throw GTELargeModelInstallError.unsafePath
        }
        return identity(from: opened)
    }

    static func fileIdentity(at url: URL, requiredMode: mode_t? = privateFileMode) throws -> GTELargeFileIdentity {
        try withParentDescriptor(of: url) { parent, name in
            var before = stat()
            guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  (before.st_mode & S_IFMT) != S_IFLNK,
                  before.st_uid == getuid(),
                  before.st_nlink == 1,
                  requiredMode.map({ (before.st_mode & 0o777) == $0 }) ?? true else {
                throw GTELargeModelInstallError.unsafePath
            }
            let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
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
    }

    static func readPrivateFile(at url: URL, maximumSize: Int64) throws -> (Data, GTELargeFileIdentity) {
        try withParentDescriptor(of: url) { parent, name in
            var before = stat()
            guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_uid == getuid(), before.st_nlink == 1,
                  (before.st_mode & 0o777) == privateFileMode else {
                throw GTELargeModelInstallError.unsafePath
            }
            let expectedIdentity = identity(from: before)
            let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  sameIdentity(expectedIdentity, identity(from: opened)) else {
                throw GTELargeModelInstallError.unsafePath
            }
            guard opened.st_size >= 0, opened.st_size <= maximumSize else {
                throw GTELargeModelInstallError.unreadableInstall
            }
            var chunks = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count == 0 { break }
                guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
                let (nextCount, overflow) = Int64(chunks.count).addingReportingOverflow(Int64(count))
                guard !overflow, nextCount <= maximumSize else {
                    throw GTELargeModelInstallError.unreadableInstall
                }
                chunks.append(buffer, count: count)
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  sameIdentity(expectedIdentity, identity(from: after)) else {
                throw GTELargeModelInstallError.unsafePath
            }
            return (chunks, expectedIdentity)
        }
    }

    static func hashPrivateFile(at url: URL, expectedSize: Int64) throws -> (String, GTELargeFileIdentity) {
        try hashFile(at: url, requiredMode: privateFileMode, expectedSize: expectedSize)
    }

    static func hashFile(
        at url: URL,
        requiredMode: mode_t?,
        expectedSize: Int64
    ) throws -> (String, GTELargeFileIdentity) {
        try withParentDescriptor(of: url) { parent, name in
            var before = stat()
            guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
                  (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_uid == getuid(), before.st_nlink == 1,
                  requiredMode.map({ (before.st_mode & 0o777) == $0 }) ?? true else {
                throw GTELargeModelInstallError.unsafePath
            }
            let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
            defer { close(descriptor) }
            var opened = stat()
            let expectedIdentity = identity(from: before)
            guard fstat(descriptor, &opened) == 0,
                  sameIdentity(expectedIdentity, identity(from: opened)),
                  opened.st_size == expectedSize else {
                throw GTELargeModelInstallError.unsafePath
            }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1_048_576)
            var hashed: Int64 = 0
            let deadline = Date().addingTimeInterval(300)
            while true {
                try Task.checkCancellation()
                guard Date() <= deadline else { throw GTELargeModelInstallError.unreadableInstall }
                let count = read(descriptor, &buffer, buffer.count)
                if count == 0 { break }
                guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
                let (next, overflow) = hashed.addingReportingOverflow(Int64(count))
                guard !overflow, next <= expectedSize else {
                    throw GTELargeModelInstallError.unreadableInstall
                }
                hashed = next
                hasher.update(data: Data(buffer[0..<count]))
            }
            var after = stat()
            guard hashed == expectedSize,
                  fstat(descriptor, &after) == 0,
                  sameIdentity(expectedIdentity, identity(from: after)) else {
                throw GTELargeModelInstallError.unsafePath
            }
            return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), expectedIdentity)
        }
    }

    static func copyDownloadedPayload(
        from source: URL,
        to destination: URL,
        expectedSourceIdentity: GTELargeFileIdentity,
        expectedSize: Int64
    ) throws {
        try withParentDescriptor(of: source) { sourceParent, sourceName in
            let sourceDescriptor = sourceName.withCString { openat(sourceParent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            guard sourceDescriptor >= 0 else { throw GTELargeModelInstallError.unreadableInstall }
            defer { close(sourceDescriptor) }
            var sourceStatus = stat()
            guard fstat(sourceDescriptor, &sourceStatus) == 0,
                  (sourceStatus.st_mode & S_IFMT) == S_IFREG,
                  sourceStatus.st_uid == getuid(), sourceStatus.st_nlink == 1,
                  sourceStatus.st_size == expectedSize,
                  sameIdentity(identity(from: sourceStatus), expectedSourceIdentity) else {
                throw GTELargeModelInstallError.unreadableInstall
            }
            try copyOpenFileDescriptor(
                sourceDescriptor,
                sourceStatus: sourceStatus,
                to: destination,
                maximumSize: expectedSize
            )
        }
    }

    /// URLSession owns its download temporary directory. Canonicalize the
    /// delegate location to the process temporary root before opening it, then
    /// copy only from the checked regular-file descriptor.
    static func copyURLSessionDownloadPayload(
        from source: URL,
        to destination: URL,
        expectedSize: Int64,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try cancellationCheck()
        let canonicalSource = try validatedURLSessionTemporaryFile(source)
        try withParentDescriptor(of: canonicalSource) { parent, name in
            let sourceDescriptor = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            guard sourceDescriptor >= 0 else { throw GTELargeModelInstallError.unreadableInstall }
            defer { close(sourceDescriptor) }
            var sourceStatus = stat()
            guard fstat(sourceDescriptor, &sourceStatus) == 0,
                  (sourceStatus.st_mode & S_IFMT) == S_IFREG,
                  sourceStatus.st_uid == getuid(), sourceStatus.st_nlink == 1 else {
                throw GTELargeModelInstallError.unsafePath
            }
            guard sourceStatus.st_size == expectedSize else { throw GTELargeModelInstallError.downloadTooLarge }
            try copyOpenFileDescriptor(
                sourceDescriptor,
                sourceStatus: sourceStatus,
                to: destination,
                maximumSize: expectedSize,
                cancellationCheck: cancellationCheck
            )
        }
    }

    static func validatedURLSessionTemporaryFile(_ source: URL) throws -> URL {
        guard source.isFileURL,
              source.host == nil || source.host?.isEmpty == true else {
            throw GTELargeModelInstallError.unsafePath
        }
        try validateURLSessionPathSpelling(source)

        // `/var` and `/tmp` are system-managed spellings of their `/private`
        // paths on macOS. Rewrite only those known prefixes before descriptor
        // traversal. Resolving arbitrary symlinks would turn an in-root leaf
        // link into an apparently safe regular file.
        let canonicalSource = try canonicalURLSessionTemporaryPath(source)
        let temporaryRoot = try canonicalURLSessionTemporaryPath(
            FoodMapperModelStorage.urlSessionTemporaryDirectory()
        )
        guard isStrictChild(canonicalSource, of: temporaryRoot) else {
            throw GTELargeModelInstallError.unsafePath
        }

        try withParentDescriptor(of: canonicalSource) { parent, name in
            var leaf = stat()
            guard name.withCString({ fstatat(parent, $0, &leaf, AT_SYMLINK_NOFOLLOW) }) == 0,
                  (leaf.st_mode & S_IFMT) == S_IFREG,
                  (leaf.st_mode & S_IFMT) != S_IFLNK else {
                throw GTELargeModelInstallError.unsafePath
            }
        }
        return canonicalSource
    }

    private static func validateURLSessionPathSpelling(_ source: URL) throws {
        guard let encodedPath = URLComponents(url: source, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              encodedPath.hasPrefix("/") else {
            throw GTELargeModelInstallError.unsafePath
        }
        let rawComponents = encodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard rawComponents.allSatisfy({ isSafeURLSessionPathComponent(String($0)) }) else {
            throw GTELargeModelInstallError.unsafePath
        }
    }

    private static func isSafeURLSessionPathComponent(_ raw: String) -> Bool {
        guard !raw.isEmpty, !raw.contains("\\") else { return false }
        var decoded = raw
        // Decode repeatedly so `%252e%252e`, `%252f`, and related variants
        // cannot become traversal or separators in a later URL conversion.
        for _ in 0..<4 {
            guard decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\"),
                  !decoded.contains("\u{0}") else {
                return false
            }
            guard decoded.contains("%") else { return true }
            guard let next = decoded.removingPercentEncoding, next != decoded else {
                return false
            }
            decoded = next
        }
        return false
    }

    private static func canonicalURLSessionTemporaryPath(_ url: URL) throws -> URL {
        guard url.isFileURL,
              url.host == nil || url.host?.isEmpty == true,
              url.path.hasPrefix("/") else {
            throw GTELargeModelInstallError.unsafePath
        }
        let path = url.path
        if path == "/var" {
            return URL(fileURLWithPath: "/private/var", isDirectory: true)
        }
        if path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: url.hasDirectoryPath)
        }
        if path == "/tmp" {
            return URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        }
        if path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: url.hasDirectoryPath)
        }
        return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
    }

    private static func isStrictChild(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path.hasPrefix(parentPath)
    }

    private static func copyOpenFileDescriptor(
        _ sourceDescriptor: Int32,
        sourceStatus: stat,
        to destination: URL,
        maximumSize: Int64 = .max,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try withParentDescriptor(of: destination) { destinationParent, destinationName in
            let destinationDescriptor = destinationName.withCString {
                openat(destinationParent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, privateFileMode)
            }
            guard destinationDescriptor >= 0 else { throw GTELargeModelInstallError.unreadableInstall }
            defer { close(destinationDescriptor) }
            do {
                var buffer = [UInt8](repeating: 0, count: 1_048_576)
                var copied: Int64 = 0
                while true {
                    try cancellationCheck()
                    let count = Darwin.read(sourceDescriptor, &buffer, buffer.count)
                    if count == 0 { break }
                    guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
                    let (next, overflow) = copied.addingReportingOverflow(Int64(count))
                    guard !overflow, next <= maximumSize else { throw GTELargeModelInstallError.downloadTooLarge }
                    copied = next
                    var offset = 0
                    while offset < count {
                        try cancellationCheck()
                        let written = Darwin.write(
                            destinationDescriptor,
                            buffer.withUnsafeBytes { $0.baseAddress!.advanced(by: offset) },
                            count - offset
                        )
                        guard written > 0 else { throw GTELargeModelInstallError.unreadableInstall }
                        offset += written
                    }
                }
                var sourceAfter = stat()
                var destinationStatus = stat()
                guard copied == maximumSize,
                      fstat(sourceDescriptor, &sourceAfter) == 0,
                      sameIdentity(identity(from: sourceStatus), identity(from: sourceAfter)),
                      fstat(destinationDescriptor, &destinationStatus) == 0,
                      (destinationStatus.st_mode & S_IFMT) == S_IFREG,
                      destinationStatus.st_uid == getuid(), destinationStatus.st_nlink == 1,
                      fchmod(destinationDescriptor, privateFileMode) == 0,
                      fsync(destinationDescriptor) == 0,
                      fsync(destinationParent) == 0 else {
                    throw GTELargeModelInstallError.unreadableInstall
                }
            } catch {
                var failed = stat()
                if fstat(destinationDescriptor, &failed) == 0,
                   (failed.st_mode & S_IFMT) == S_IFREG,
                   failed.st_uid == getuid(), failed.st_nlink == 1 {
                    try? removePrivateItem(
                        at: destination,
                        expectedFileIdentity: identity(from: failed)
                    )
                }
                throw error
            }
        }
    }

    private static func unsignedBits<T: FixedWidthInteger>(_ value: T) -> UInt64 {
        let bits = UInt64(truncatingIfNeeded: value)
        guard T.bitWidth < UInt64.bitWidth else { return bits }
        return bits & ((UInt64(1) << T.bitWidth) - 1)
    }

    static func identity(from status: stat) -> GTELargeFileIdentity {
        GTELargeFileIdentity(
            size: Int64(truncatingIfNeeded: status.st_size),
            device: unsignedBits(status.st_dev),
            inode: unsignedBits(status.st_ino),
            changeSeconds: Int64(truncatingIfNeeded: status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(truncatingIfNeeded: status.st_ctimespec.tv_nsec),
            linkCount: unsignedBits(status.st_nlink),
            mode: UInt16(truncatingIfNeeded: status.st_mode & 0o777),
            owner: UInt32(truncatingIfNeeded: unsignedBits(status.st_uid))
        )
    }

    static func sameObject(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    static func sameIdentity(_ left: GTELargeFileIdentity, _ right: GTELargeFileIdentity) -> Bool {
        left == right
    }

    static func sameDirectoryIdentity(_ left: GTELargeFileIdentity, _ right: GTELargeFileIdentity) -> Bool {
        left == right
    }

    static func sameFileIdentity(_ left: GTELargeFileIdentity, _ right: GTELargeFileIdentity) -> Bool {
        left == right
    }

    static func sameObjectIdentity(_ left: GTELargeFileIdentity, _ right: GTELargeFileIdentity) -> Bool {
        left.device == right.device && left.inode == right.inode
    }
}

protocol GTELargeFileSystem: Sendable {
    func itemExists(at url: URL) -> Bool
    func createDirectory(at url: URL, permissions: Int) throws
    func removeItem(at url: URL) throws
    func removeItem(at url: URL, expectedFileIdentity: GTELargeFileIdentity) throws
    func removeItem(at url: URL, expectedDirectoryIdentity: GTELargeFileIdentity) throws
    func removePrivateTree(at url: URL, tree: GTELargePrivateTree, maximumDepth: Int) throws
    func contentsOfDirectory(at url: URL, maximumEntries: Int) throws -> [URL]
    func moveItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws
    func moveItem(at source: URL, to destination: URL, expectedSourceDirectoryIdentity: GTELargeFileIdentity) throws
    func replaceFileAtomically(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws
    func copyItem(
        at source: URL,
        to destination: URL,
        expectedSourceIdentity: GTELargeFileIdentity,
        expectedSize: Int64
    ) throws
    func write(_ data: Data, to url: URL, permissions: Int) throws
    func read(from url: URL, maximumSize: Int64) throws -> (Data, GTELargeFileIdentity)
    func fileIdentity(at url: URL) throws -> GTELargeFileIdentity
    func directoryIdentity(at url: URL, requiredPermissions: Int?) throws -> GTELargeFileIdentity
    func privateTree(
        at url: URL,
        maximumEntries: Int,
        maximumDepth: Int,
        maximumBytes: Int64
    ) throws -> GTELargePrivateTree
    func setPermissions(_ permissions: Int, at url: URL) throws
    func syncFile(at url: URL) throws
    func syncDirectory(at url: URL) throws
}

struct LocalGTELargeFileSystem: GTELargeFileSystem {
    func itemExists(at url: URL) -> Bool {
        GTELargeSecurePath.itemExists(at: url)
    }

    func createDirectory(at url: URL, permissions: Int) throws {
        try GTELargeSecurePath.withParentDescriptor(of: url) { parent, name in
            if name.withCString({ mkdirat(parent, $0, mode_t(permissions)) }) == 0 {
                var before = stat()
                guard name.withCString({ fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW) }) == 0,
                      (before.st_mode & S_IFMT) == S_IFDIR,
                      before.st_uid == getuid() else {
                    throw GTELargeModelInstallError.unsafePath
                }
                let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
                guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
                defer { close(descriptor) }
                var opened = stat()
                guard fstat(descriptor, &opened) == 0,
                      GTELargeSecurePath.sameObject(before, opened),
                      fchmod(descriptor, mode_t(permissions)) == 0,
                      fsync(descriptor) == 0,
                      fsync(parent) == 0 else {
                    throw GTELargeModelInstallError.unsafePath
                }
                return
            }
            guard errno == EEXIST else {
                throw GTELargeModelInstallError.unreadableInstall
            }
            _ = try GTELargeSecurePath.directoryIdentity(at: url)
        }
    }

    func removeItem(at url: URL) throws {
        try GTELargeSecurePath.removePrivateItem(at: url)
    }

    func removeItem(at url: URL, expectedFileIdentity: GTELargeFileIdentity) throws {
        try GTELargeSecurePath.removePrivateItem(at: url, expectedFileIdentity: expectedFileIdentity)
    }

    func removeItem(at url: URL, expectedDirectoryIdentity: GTELargeFileIdentity) throws {
        try GTELargeSecurePath.removePrivateItem(at: url, expectedDirectoryIdentity: expectedDirectoryIdentity)
    }

    func removePrivateTree(at url: URL, tree: GTELargePrivateTree, maximumDepth: Int) throws {
        try GTELargeSecurePath.removePrivateTree(at: url, tree: tree, maximumDepth: maximumDepth)
    }

    func contentsOfDirectory(at url: URL, maximumEntries: Int) throws -> [URL] {
        try GTELargeSecurePath.directoryEntries(at: url, maximumEntries: maximumEntries)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try moveItem(at: source, to: destination, expectedSourceIdentity: Optional<GTELargeFileIdentity>.none)
    }

    func moveItem(at source: URL, to destination: URL, expectedSourceDirectoryIdentity: GTELargeFileIdentity) throws {
        try moveItem(at: source, to: destination, expectedSourceIdentity: expectedSourceDirectoryIdentity)
    }

    func moveItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws {
        try moveItem(at: source, to: destination, expectedSourceIdentity: Optional(expectedSourceIdentity))
    }

    func replaceFileAtomically(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws {
        try GTELargeSecurePath.withParentDescriptor(of: source) { sourceParent, sourceName in
            try GTELargeSecurePath.withParentDescriptor(of: destination) { destinationParent, destinationName in
                var sourceBefore = stat()
                guard sourceName.withCString({ fstatat(sourceParent, $0, &sourceBefore, AT_SYMLINK_NOFOLLOW) }) == 0,
                      (sourceBefore.st_mode & S_IFMT) == S_IFREG,
                      sourceBefore.st_uid == getuid(), sourceBefore.st_nlink == 1,
                      (sourceBefore.st_mode & 0o777) == GTELargeSecurePath.privateFileMode,
                      GTELargeSecurePath.sameFileIdentity(GTELargeSecurePath.identity(from: sourceBefore), expectedSourceIdentity) else {
                    throw GTELargeModelInstallError.unsafePath
                }
                let sourceDescriptor = sourceName.withCString { openat(sourceParent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
                guard sourceDescriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
                defer { close(sourceDescriptor) }
                var sourceOpened = stat()
                guard fstat(sourceDescriptor, &sourceOpened) == 0,
                      GTELargeSecurePath.sameIdentity(
                          GTELargeSecurePath.identity(from: sourceOpened),
                          expectedSourceIdentity
                      ) else {
                    throw GTELargeModelInstallError.unsafePath
                }
                var existing = stat()
                let destinationExists = destinationName.withCString {
                    fstatat(destinationParent, $0, &existing, AT_SYMLINK_NOFOLLOW)
                } == 0
                if destinationExists {
                    guard (existing.st_mode & S_IFMT) == S_IFREG,
                          existing.st_uid == getuid(), existing.st_nlink == 1,
                          (existing.st_mode & 0o777) == GTELargeSecurePath.privateFileMode else {
                        throw GTELargeModelInstallError.unsafePath
                    }
                } else {
                    guard errno == ENOENT else { throw GTELargeModelInstallError.unsafePath }
                }
                let result = sourceName.withCString { sourcePointer in
                    destinationName.withCString { destinationPointer in
                        renameatx_np(sourceParent, sourcePointer, destinationParent, destinationPointer, 0)
                    }
                }
                guard result == 0 else { throw GTELargeModelInstallError.unreadableInstall }
                var published = stat()
                guard destinationName.withCString({ fstatat(destinationParent, $0, &published, AT_SYMLINK_NOFOLLOW) }) == 0,
                      GTELargeSecurePath.sameObject(sourceOpened, published),
                      (published.st_mode & S_IFMT) == S_IFREG,
                      published.st_uid == getuid(), published.st_nlink == 1,
                      (published.st_mode & 0o777) == GTELargeSecurePath.privateFileMode,
                      fsync(sourceParent) == 0,
                      fsync(destinationParent) == 0 else {
                    throw GTELargeModelInstallError.unsafePath
                }
            }
        }
    }

    private func moveItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity?) throws {
        try GTELargeSecurePath.withParentDescriptor(of: source) { sourceParent, sourceName in
            try GTELargeSecurePath.withParentDescriptor(of: destination) { destinationParent, destinationName in
                var sourceStatus = stat()
                guard sourceName.withCString({ fstatat(sourceParent, $0, &sourceStatus, AT_SYMLINK_NOFOLLOW) }) == 0,
                      sourceStatus.st_uid == getuid(),
                      (sourceStatus.st_mode & S_IFMT) != S_IFLNK else {
                    throw GTELargeModelInstallError.unsafePath
                }
                let sourceType = sourceStatus.st_mode & S_IFMT
                let isPrivateFile = sourceType == S_IFREG && sourceStatus.st_nlink == 1 &&
                    (sourceStatus.st_mode & 0o777) == 0o600
                let isPrivateDirectory = sourceType == S_IFDIR &&
                    (sourceStatus.st_mode & 0o777) == 0o700
                guard isPrivateFile || isPrivateDirectory else {
                    throw GTELargeModelInstallError.unsafePath
                }
                guard sourceStatus.st_size >= 0,
                      sourceType != S_IFREG || sourceStatus.st_size <= 2_147_483_648 else {
                    throw GTELargeModelInstallError.unsafePath
                }
                if let expectedSourceIdentity {
                    let actualIdentity = GTELargeSecurePath.identity(from: sourceStatus)
                    let matches = isPrivateDirectory
                        ? GTELargeSecurePath.sameDirectoryIdentity(actualIdentity, expectedSourceIdentity)
                        : GTELargeSecurePath.sameFileIdentity(actualIdentity, expectedSourceIdentity)
                    guard matches else {
                        throw GTELargeModelInstallError.unsafePath
                    }
                }

                var destinationStatus = stat()
                let destinationExists = destinationName.withCString {
                    fstatat(destinationParent, $0, &destinationStatus, AT_SYMLINK_NOFOLLOW)
                } == 0
                guard !destinationExists else {
                    throw GTELargeModelInstallError.unsafePath
                }
                guard errno == ENOENT else {
                    throw GTELargeModelInstallError.unsafePath
                }

                if isPrivateFile {
                    let sourceDescriptor = sourceName.withCString {
                        openat(sourceParent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                    }
                    guard sourceDescriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
                    defer { close(sourceDescriptor) }
                    var openedSource = stat()
                    guard fstat(sourceDescriptor, &openedSource) == 0,
                          GTELargeSecurePath.sameObject(sourceStatus, openedSource),
                          openedSource.st_uid == getuid(), openedSource.st_nlink == 1,
                          (openedSource.st_mode & S_IFMT) == S_IFREG,
                          (openedSource.st_mode & 0o777) == GTELargeSecurePath.privateFileMode else {
                        throw GTELargeModelInstallError.unsafePath
                    }

                    guard fstat(sourceDescriptor, &openedSource) == 0,
                          GTELargeSecurePath.sameIdentity(
                              GTELargeSecurePath.identity(from: sourceStatus),
                              GTELargeSecurePath.identity(from: openedSource)
                          ),
                          expectedSourceIdentity.map({
                              GTELargeSecurePath.sameFileIdentity(GTELargeSecurePath.identity(from: openedSource), $0)
                          }) ?? true else {
                        throw GTELargeModelInstallError.unsafePath
                    }
                    let promoted = sourceName.withCString { sourcePointer in
                        destinationName.withCString { destinationPointer in
                            renameatx_np(sourceParent, sourcePointer, destinationParent, destinationPointer, UInt32(RENAME_EXCL))
                        }
                    }
                    guard promoted == 0 else { throw GTELargeModelInstallError.unreadableInstall }
                    var publishedStatus = stat()
                    guard destinationName.withCString({ fstatat(destinationParent, $0, &publishedStatus, AT_SYMLINK_NOFOLLOW) }) == 0,
                          GTELargeSecurePath.sameObject(openedSource, publishedStatus),
                          publishedStatus.st_uid == getuid(), publishedStatus.st_nlink == 1,
                          (publishedStatus.st_mode & S_IFMT) == S_IFREG,
                          (publishedStatus.st_mode & 0o777) == GTELargeSecurePath.privateFileMode,
                          fsync(sourceParent) == 0,
                          fsync(destinationParent) == 0 else {
                        throw GTELargeModelInstallError.unsafePath
                    }
                    return
                }

                guard isManagedDirectoryName(sourceName), isManagedDirectoryName(destinationName) else {
                    throw GTELargeModelInstallError.unsafePath
                }
                let sourceDescriptor = sourceName.withCString {
                    openat(sourceParent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard sourceDescriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
                defer { close(sourceDescriptor) }
                var openedSource = stat()
                guard fstat(sourceDescriptor, &openedSource) == 0,
                      GTELargeSecurePath.sameIdentity(
                          GTELargeSecurePath.identity(from: sourceStatus),
                          GTELargeSecurePath.identity(from: openedSource)
                      ),
                      expectedSourceIdentity.map({
                          GTELargeSecurePath.sameDirectoryIdentity(
                              GTELargeSecurePath.identity(from: openedSource),
                              $0
                          )
                      }) ?? true else {
                    throw GTELargeModelInstallError.unsafePath
                }
                let result: Int32 = sourceName.withCString { sourcePointer in
                    destinationName.withCString { destinationPointer in
                        renameatx_np(sourceParent, sourcePointer, destinationParent, destinationPointer, UInt32(RENAME_EXCL))
                    }
                }
                guard result == 0 else { throw GTELargeModelInstallError.unreadableInstall }
                var movedStatus = stat()
                let validDestination = destinationName.withCString({ fstatat(destinationParent, $0, &movedStatus, AT_SYMLINK_NOFOLLOW) }) == 0 &&
                    GTELargeSecurePath.sameObject(openedSource, movedStatus) &&
                    movedStatus.st_uid == getuid() &&
                    (movedStatus.st_mode & S_IFMT) == S_IFDIR &&
                    (movedStatus.st_mode & 0o777) == GTELargeSecurePath.privateDirectoryMode &&
                    (expectedSourceIdentity.map({
                        GTELargeSecurePath.sameObjectIdentity(GTELargeSecurePath.identity(from: movedStatus), $0)
                    }) ?? true)
                guard validDestination else {
                    // Do not clean this destination. A directory rename has
                    // no descriptor form on Darwin, so a replacement observed
                    // after the move must remain available for inspection.
                    throw GTELargeModelInstallError.unsafePath
                }
                guard fsync(sourceParent) == 0, fsync(destinationParent) == 0 else {
                    throw GTELargeModelInstallError.unreadableInstall
                }
            }
        }
    }

    private func isManagedDirectoryName(_ name: String) -> Bool {
        let stagingPrefix = ".gte-large-staging-"
        let backupPrefix = ".gte-large-previous-"
        let unverifiedPrefix = ".gte-large-unverified-"
        if name.hasPrefix(stagingPrefix) || name.hasPrefix(backupPrefix) || name.hasPrefix(unverifiedPrefix) {
            let prefix = name.hasPrefix(stagingPrefix)
                ? stagingPrefix
                : name.hasPrefix(backupPrefix) ? backupPrefix : unverifiedPrefix
            return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
        let revision = String(name.dropFirst("gte-large-".count))
        return name.hasPrefix("gte-large-") && revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    func copyItem(
        at source: URL,
        to destination: URL,
        expectedSourceIdentity: GTELargeFileIdentity,
        expectedSize: Int64
    ) throws {
        try GTELargeSecurePath.copyDownloadedPayload(
            from: source,
            to: destination,
            expectedSourceIdentity: expectedSourceIdentity,
            expectedSize: expectedSize
        )
    }

    func write(_ data: Data, to url: URL, permissions: Int) throws {
        try GTELargeSecurePath.withParentDescriptor(of: url) { parent, name in
            let descriptor = name.withCString {
                openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(permissions))
            }
            guard descriptor >= 0 else { throw GTELargeModelInstallError.unreadableInstall }
            defer { close(descriptor) }
            do {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(
                            descriptor,
                            bytes.baseAddress!.advanced(by: offset),
                            bytes.count - offset
                        )
                        guard count > 0 else { throw GTELargeModelInstallError.unreadableInstall }
                        offset += count
                    }
                }
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFREG,
                      status.st_uid == getuid(), status.st_nlink == 1,
                      fchmod(descriptor, mode_t(permissions)) == 0,
                      fsync(descriptor) == 0,
                      fsync(parent) == 0 else {
                    throw GTELargeModelInstallError.unreadableInstall
                }
            } catch {
                var failed = stat()
                if fstat(descriptor, &failed) == 0,
                   (failed.st_mode & S_IFMT) == S_IFREG,
                   failed.st_uid == getuid(), failed.st_nlink == 1 {
                    try? GTELargeSecurePath.removePrivateItem(
                        at: url,
                        expectedFileIdentity: GTELargeSecurePath.identity(from: failed)
                    )
                }
                throw error
            }
        }
    }

    func read(from url: URL, maximumSize: Int64) throws -> (Data, GTELargeFileIdentity) {
        try GTELargeSecurePath.readPrivateFile(at: url, maximumSize: maximumSize)
    }

    func fileIdentity(at url: URL) throws -> GTELargeFileIdentity {
        try GTELargeSecurePath.fileIdentity(at: url)
    }

    func directoryIdentity(at url: URL, requiredPermissions: Int?) throws -> GTELargeFileIdentity {
        try GTELargeSecurePath.directoryIdentity(at: url, requiredMode: requiredPermissions.map { mode_t($0) })
    }

    func privateTree(
        at url: URL,
        maximumEntries: Int,
        maximumDepth: Int,
        maximumBytes: Int64
    ) throws -> GTELargePrivateTree {
        try GTELargeSecurePath.privateTree(
            at: url,
            maximumEntries: maximumEntries,
            maximumDepth: maximumDepth,
            maximumBytes: maximumBytes
        )
    }

    func setPermissions(_ permissions: Int, at url: URL) throws {
        try GTELargeSecurePath.withParentDescriptor(of: url) { parent, name in
            let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  ((status.st_mode & S_IFMT) == S_IFREG || (status.st_mode & S_IFMT) == S_IFDIR),
                  status.st_uid == getuid(),
                  (status.st_mode & S_IFMT) != S_IFREG || status.st_nlink == 1,
                  fchmod(descriptor, mode_t(permissions)) == 0,
                  fsync(descriptor) == 0,
                  fsync(parent) == 0 else {
                throw GTELargeModelInstallError.unsafePath
            }
        }
    }

    func syncFile(at url: URL) throws {
        try GTELargeSecurePath.withParentDescriptor(of: url) { parent, name in
            let descriptor = name.withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw GTELargeModelInstallError.unsafePath }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_uid == getuid(), status.st_nlink == 1,
                  fsync(descriptor) == 0,
                  fsync(parent) == 0 else {
                throw GTELargeModelInstallError.unreadableInstall
            }
        }
    }

    func syncDirectory(at url: URL) throws {
        let descriptor = try GTELargeSecurePath.openDirectoryDescriptor(at: url)
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              fsync(descriptor) == 0 else {
            throw GTELargeModelInstallError.unreadableInstall
        }
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
    func sha256(of url: URL, expectedSize: Int64) throws -> String
}

struct SHA256GTELargeHashing: GTELargeHashing {
    func sha256(of url: URL, expectedSize: Int64) throws -> String {
        try GTELargeSecurePath.hashPrivateFile(at: url, expectedSize: expectedSize).0
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
                    state: state,
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

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
    }

    func clearTask() {
        lock.lock()
        task = nil
        lock.unlock()
    }
}

enum GTELargeDownloadURLPolicy {
    static let approvedHosts: Set<String> = [
        "huggingface.co",
        "cdn-lfs.huggingface.co",
        "cas-bridge.xethub.hf.co",
        // Hugging Face's current pinned resolver redirects LFS objects to
        // this regional CDN hostname. Keep this exact, not a wildcard.
        "us.aws.cdn.hf.co",
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
    private let state: GTELargeURLSessionDownloadState
    private let continuation: CheckedContinuation<Void, Error>
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private enum CompletionState { case pending, copying, completed }
    private var completionState: CompletionState = .pending
    private var redirectCount = 0

    init(
        destination: URL,
        expectedSize: Int64,
        state: GTELargeURLSessionDownloadState,
        continuation: CheckedContinuation<Void, Error>,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.state = state
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

        guard reservePayloadCopy() else { return }
        do {
            try GTELargeSecurePath.copyURLSessionDownloadPayload(
                from: location,
                to: destination,
                expectedSize: expectedSize,
                cancellationCheck: state.checkCancellation
            )
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
        guard completionState != .completed else {
            lock.unlock()
            return
        }
        completionState = .completed
        lock.unlock()
        state.clearTask()
        session.invalidateAndCancel()
        continuation.resume(with: result)
    }

    private func reservePayloadCopy() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard completionState == .pending else { return false }
        completionState = .copying
        return true
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
    private var promotionStarted = false

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
        let mayStart = !cancelled && !Task.isCancelled && !promotionStarted
        if mayStart { promotionStarted = true }
        lock.unlock()
        guard mayStart else { throw CancellationError() }
        try body()
    }
}

actor GTELargeOperationCoordinator {
    static let shared = GTELargeOperationCoordinator()
    private var activeRoots: Set<String> = []
    private var waiters: [String: [UUID: CheckedContinuation<Bool, Never>]] = [:]

    func acquire(root: String) async throws {
        try Task.checkCancellation()
        if activeRoots.insert(root).inserted { return }
        let token = UUID()
        let granted = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[root, default: [:]][token] = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancel(root: root, token: token) }
        })
        guard granted else { throw CancellationError() }
        do {
            try Task.checkCancellation()
        } catch {
            // A waiter can be resumed at the same instant its parent task is
            // cancelled. It owns the root at that point, so it must hand the
            // lease to the next waiter before returning the cancellation.
            release(root: root)
            throw error
        }
    }

    private func cancel(root: String, token: UUID) {
        guard let continuation = waiters[root]?[token] else { return }
        waiters[root]?[token] = nil
        if waiters[root]?.isEmpty == true { waiters[root] = nil }
        continuation.resume(returning: false)
    }

    func release(root: String) {
        if var queued = waiters[root], let token = queued.keys.sorted(by: { $0.uuidString < $1.uuidString }).first,
           let next = queued.removeValue(forKey: token) {
            waiters[root] = queued.isEmpty ? nil : queued
            next.resume(returning: true)
        } else {
            activeRoots.remove(root)
        }
    }
}

struct GTELargeInstallPointer: Codable {
    let schema: Int
    let directoryName: String
    let record: GTELargeModelInstallRecord
}

struct GTELargePromotionJournal: Codable {
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

    private func withOperationLease<T>(_ body: () async throws -> T) async throws -> T {
        try await GTELargeOperationCoordinator.shared.acquire(root: rootDirectory.path)
        do {
            try Task.checkCancellation()
            let value = try await body()
            await GTELargeOperationCoordinator.shared.release(root: rootDirectory.path)
            return value
        } catch {
            await GTELargeOperationCoordinator.shared.release(root: rootDirectory.path)
            throw error
        }
    }

    /// Returns a verified versioned install or a verified flat legacy install.
    /// It never downloads, repairs, deletes, or accepts a partial set.
    func availableDirectory() -> URL? {
        guard installConfigurationIsValid() else { return nil }
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
        try await withOperationLease {
            guard installConfigurationIsValid() else { throw GTELargeModelInstallError.unsafePath }
            return try await migrateLegacyInstallIfNeeded(operation: nil)
        }
    }

    /// Performs explicit startup repair before model state is published.
    /// Availability and model loading never invoke this operation.
    func recoverAtStartup() async throws {
        try await withOperationLease {
            try Task.checkCancellation()
            guard installConfigurationIsValid() else { throw GTELargeModelInstallError.unsafePath }
            try ensureRootDirectory()
            try Task.checkCancellation()
            if isPrivateDirectory(rootDirectory) { try recoverPromotionIfNeeded() }
            try Task.checkCancellation()
            if !verifyVersionedInstall(at: installedDirectory) {
                _ = try await migrateLegacyInstallIfNeeded(operation: nil)
            }
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
                let sourceIdentity = try fileSystem.fileIdentity(at: source)
                try fileSystem.copyItem(
                    at: source,
                    to: destination,
                    expectedSourceIdentity: sourceIdentity,
                    expectedSize: file.size
                )
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
                try removeVerifiedPrivateFile(at: legacyFile)
            }
            GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
            return installedDirectory
        } catch is CancellationError {
            if fileSystem.itemExists(at: staging),
               !fileSystem.itemExists(at: promotionJournalURL),
               !hasRecoverableJournalTemporary(for: staging) {
                try removeVerifiedPrivateDirectory(at: staging)
            }
            throw CancellationError()
        } catch {
            if fileSystem.itemExists(at: staging),
               !fileSystem.itemExists(at: promotionJournalURL),
               !hasRecoverableJournalTemporary(for: staging) {
                try removeVerifiedPrivateDirectory(at: staging)
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
            try await withOperationLease {
                try operation.checkCancellation()
                return try await install(onProgress: onProgress, operation: operation)
            }
        }, onCancel: {
            operation.cancel()
        })
    }

    private func install(
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        operation: GTELargeInstallOperation
    ) async throws -> URL {
        try operation.checkCancellation()
        guard installConfigurationIsValid() else { throw GTELargeModelInstallError.unsafePath }
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
            // Once a durable journal exists, its staging identity is recovery
            // input. Removing it after a failed first promotion would strand
            // the journal and block a later explicit install.
            if fileSystem.itemExists(at: staging),
               !fileSystem.itemExists(at: promotionJournalURL),
               !hasRecoverableJournalTemporary(for: staging) {
                try removeVerifiedPrivateDirectory(at: staging)
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
                  let hash = try? GTELargeSecurePath.hashFile(
                    at: url,
                    requiredMode: nil,
                    expectedSize: file.size
                  ).0 else {
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
        try await withOperationLease {
        try Task.checkCancellation()
        guard installConfigurationIsValid(), fileSystem.itemExists(at: rootDirectory) else { return }
        _ = try fileSystem.directoryIdentity(at: rootDirectory, requiredPermissions: 0o700)
        // A matching name is not proof of ownership. Delete only a verified
        // current install, verified flat legacy files, or objects named and
        // identified by the durable promotion journal. Unreferenced lookalikes
        // remain for manual inspection.
        if verifyVersionedInstall(at: installedDirectory) {
            try removeVerifiedPrivateDirectory(at: installedDirectory)
        }
        if let pointerData = try? readSmallFile(at: currentPointerURL),
           let pointer = try? JSONDecoder().decode(GTELargeInstallPointer.self, from: pointerData),
           pointer.schema == 1,
           pointer.directoryName == manifest.installationDirectoryName,
           pointer.record.matches(manifest) {
            try removeVerifiedPrivateFile(at: currentPointerURL)
        }
        if isSafeLegacyDirectory(rootDirectory), verifyFiles(in: rootDirectory) {
            for file in manifest.files {
                try removeVerifiedPrivateFile(at: rootDirectory.appendingPathComponent(file.name))
            }
            let legacyRecord = rootDirectory.appendingPathComponent("install.json")
            if fileSystem.itemExists(at: legacyRecord) {
                try removeVerifiedPrivateFile(at: legacyRecord)
            }
        }
        if let journal = verifiedPromotionJournal() {
            for artifact in journal {
                if fileSystem.itemExists(at: artifact.url),
                   (try? fileSystem.directoryIdentity(at: artifact.url, requiredPermissions: 0o700)).map({ GTELargeSecurePath.sameDirectoryIdentity($0, artifact.identity) }) == true {
                    try fileSystem.removeItem(at: artifact.url, expectedDirectoryIdentity: artifact.identity)
                }
            }
            try removeVerifiedPrivateFile(at: promotionJournalURL)
        }
        try fileSystem.syncDirectory(at: rootDirectory)
        GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
        }
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
        guard let hash = try? hashing.sha256(of: url, expectedSize: file.size),
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
        let previous = rootDirectory.appendingPathComponent(".gte-large-current-previous-\(UUID().uuidString)")
        var previousIdentity: GTELargeFileIdentity?
        var currentReplaced = false
        do {
            try fileSystem.write(try JSONEncoder().encode(pointer), to: temporary, permissions: 0o600)
            let temporaryIdentity = try fileSystem.fileIdentity(at: temporary)
            // Preserve the existing private pointer even when it describes an
            // older manifest. A failed replacement must restore the exact
            // prior bytes rather than infer an older manifest from this
            // installer's configuration.
            if fileSystem.itemExists(at: currentPointerURL) {
                let currentIdentity = try fileSystem.fileIdentity(at: currentPointerURL)
                try fileSystem.moveItem(
                    at: currentPointerURL,
                    to: previous,
                    expectedSourceIdentity: currentIdentity
                )
                previousIdentity = try fileSystem.fileIdentity(at: previous)
            }
            try fileSystem.moveItem(
                at: temporary,
                to: currentPointerURL,
                expectedSourceIdentity: temporaryIdentity
            )
            currentReplaced = true
            guard isCurrentPointerValid() else {
                throw GTELargeModelInstallError.verificationFailed
            }
            try fileSystem.syncDirectory(at: rootDirectory)
            if let previousIdentity, fileSystem.itemExists(at: previous) {
                try fileSystem.removeItem(at: previous, expectedFileIdentity: previousIdentity)
                try fileSystem.syncDirectory(at: rootDirectory)
            }
        } catch {
            if let previousIdentity,
               fileSystem.itemExists(at: previous),
               currentReplaced,
               fileSystem.itemExists(at: currentPointerURL) {
                let failed = rootDirectory.appendingPathComponent(".gte-large-current-invalid-\(UUID().uuidString)")
                let currentIdentity = try fileSystem.fileIdentity(at: currentPointerURL)
                try fileSystem.moveItem(at: currentPointerURL, to: failed, expectedSourceIdentity: currentIdentity)
                try fileSystem.moveItem(at: previous, to: currentPointerURL, expectedSourceIdentity: previousIdentity)
                guard currentPointerPayloadIsValid() else { throw GTELargeModelInstallError.unsafePath }
                try fileSystem.syncDirectory(at: rootDirectory)
            } else if let previousIdentity,
                      fileSystem.itemExists(at: previous),
                      !fileSystem.itemExists(at: currentPointerURL) {
                try fileSystem.moveItem(at: previous, to: currentPointerURL, expectedSourceIdentity: previousIdentity)
                guard currentPointerPayloadIsValid() else { throw GTELargeModelInstallError.unsafePath }
                try fileSystem.syncDirectory(at: rootDirectory)
            }
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
        do {
            try fileSystem.write(try JSONEncoder().encode(journal), to: temporary, permissions: 0o600)
            let temporaryIdentity = try fileSystem.fileIdentity(at: temporary)
            try fileSystem.moveItem(at: temporary, to: promotionJournalURL, expectedSourceIdentity: temporaryIdentity)
            try fileSystem.syncDirectory(at: rootDirectory)
        } catch {
            // A complete temporary is recovery input if publishing the
            // canonical journal was interrupted. Startup validates its bytes
            // and its recorded staging identity before using it.
            throw error
        }
    }

    private func hasRecoverableJournalTemporary(for staging: URL) -> Bool {
        guard let stagingIdentity = try? fileSystem.directoryIdentity(
            at: staging,
            requiredPermissions: 0o700
        ), verifyRecord(in: staging), verifyFiles(in: staging, useCache: false) else {
            return false
        }
        guard let entries = try? fileSystem.contentsOfDirectory(
            at: rootDirectory,
            maximumEntries: 128
        ) else { return true }
        let temporaries = entries.filter { isOwnedJournalTemporaryName($0.lastPathComponent) }
        guard temporaries.count <= 32 else { return true }
        return temporaries.contains { temporary in
            guard let data = try? readSmallFile(at: temporary),
                  let journal = try? JSONDecoder().decode(GTELargePromotionJournal.self, from: data),
                  isValidJournalPayload(journal),
                  journal.stagingDirectoryName == staging.lastPathComponent,
                  let recordedIdentity = journal.stagingIdentity else {
                return false
            }
            return GTELargeSecurePath.sameDirectoryIdentity(recordedIdentity, stagingIdentity)
        }
    }

    private func commit(staging: URL) throws {
        let backup = rootDirectory.appendingPathComponent(".gte-large-previous-\(UUID().uuidString)", isDirectory: true)
        let unverified = rootDirectory.appendingPathComponent(".gte-large-unverified-\(UUID().uuidString)", isDirectory: true)
        let stagingIdentity = try fileSystem.directoryIdentity(at: staging, requiredPermissions: 0o700)
        var movedExisting = false
        var backupIdentity: GTELargeFileIdentity?

        do {
            // Staging is writable user state. Re-hash from descriptor-bound
            // reads immediately before moving it into the published name.
            guard verifyRecord(in: staging), verifyFiles(in: staging, useCache: false) else {
                throw GTELargeModelInstallError.verificationFailed
            }
            if fileSystem.itemExists(at: installedDirectory) {
                let installedIdentity = try fileSystem.directoryIdentity(at: installedDirectory, requiredPermissions: 0o700)
                try writeJournal(staging: staging, backup: backup)
                try fileSystem.moveItem(at: installedDirectory, to: backup, expectedSourceDirectoryIdentity: installedIdentity)
                let movedIdentity = try fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700)
                guard GTELargeSecurePath.sameObjectIdentity(movedIdentity, installedIdentity) else {
                    throw GTELargeModelInstallError.unsafePath
                }
                backupIdentity = installedIdentity
                movedExisting = true
            } else {
                try writeJournal(staging: staging, backup: nil)
            }
            try fileSystem.moveItem(at: staging, to: installedDirectory, expectedSourceDirectoryIdentity: stagingIdentity)
            let promotedIdentity = try fileSystem.directoryIdentity(at: installedDirectory, requiredPermissions: 0o700)
            guard GTELargeSecurePath.sameObjectIdentity(promotedIdentity, stagingIdentity) else {
                throw GTELargeModelInstallError.unsafePath
            }
            // Directory rename changes ctime, so identity continuity is checked
            // by device/inode above. Content is then re-hashed at the final
            // destination before a pointer can publish it.
            guard verifyRecord(in: installedDirectory),
                  verifyFiles(in: installedDirectory, useCache: false) else {
                throw GTELargeModelInstallError.verificationFailed
            }
            try fileSystem.syncDirectory(at: installedDirectory)
            try writeCurrentPointer()
            if movedExisting, fileSystem.itemExists(at: backup) {
                guard backupIdentity != nil,
                      verifyRecord(in: backup), verifyFiles(in: backup, useCache: false) else {
                    throw GTELargeModelInstallError.unsafePath
                }
                let cleanupIdentity = try fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700)
                try fileSystem.removeItem(at: backup, expectedDirectoryIdentity: cleanupIdentity)
            }
            if fileSystem.itemExists(at: promotionJournalURL) {
                try removeVerifiedPrivateFile(at: promotionJournalURL)
            }
            try fileSystem.syncDirectory(at: rootDirectory)
            GTELargeVerificationCache.shared.removeAll(in: installedDirectory)
        } catch {
            if movedExisting,
               fileSystem.itemExists(at: installedDirectory),
               fileSystem.itemExists(at: backup) {
                guard let backupIdentity,
                      let currentBackup = try? fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700),
                      GTELargeSecurePath.sameObjectIdentity(currentBackup, backupIdentity),
                      verifyRecord(in: backup), verifyFiles(in: backup, useCache: false),
                      let unexpectedIdentity = try? fileSystem.directoryIdentity(at: installedDirectory, requiredPermissions: 0o700) else {
                    throw GTELargeModelInstallError.unsafePath
                }
                try fileSystem.moveItem(
                    at: installedDirectory,
                    to: unverified,
                    expectedSourceDirectoryIdentity: unexpectedIdentity
                )
                try fileSystem.moveItem(
                    at: backup,
                    to: installedDirectory,
                    expectedSourceDirectoryIdentity: backupIdentity
                )
                guard verifyVersionedInstall(at: installedDirectory) else {
                    throw GTELargeModelInstallError.unsafePath
                }
            } else if movedExisting, !fileSystem.itemExists(at: installedDirectory), fileSystem.itemExists(at: backup) {
                guard let backupIdentity,
                      let currentBackup = try? fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700),
                      GTELargeSecurePath.sameObjectIdentity(currentBackup, backupIdentity),
                      verifyRecord(in: backup), verifyFiles(in: backup, useCache: false) else {
                    throw GTELargeModelInstallError.unsafePath
                }
                try fileSystem.moveItem(at: backup, to: installedDirectory, expectedSourceDirectoryIdentity: backupIdentity)
                let restored = try fileSystem.directoryIdentity(at: installedDirectory, requiredPermissions: 0o700)
                guard GTELargeSecurePath.sameObjectIdentity(restored, backupIdentity) else {
                    throw GTELargeModelInstallError.unsafePath
                }
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
        guard fileSystem.itemExists(at: rootDirectory) else { return false }
        _ = try fileSystem.directoryIdentity(at: rootDirectory, requiredPermissions: nil)
        let allowedNames = Set(manifest.files.map(\.name) + ["install.json"])
        let entries = try fileSystem.contentsOfDirectory(at: rootDirectory, maximumEntries: 16)
        guard entries.allSatisfy({ allowedNames.contains($0.lastPathComponent) }) else {
            throw GTELargeModelInstallError.unsafePath
        }

        var presentFiles = Set<String>()
        for entry in entries {
            let url = rootDirectory.appendingPathComponent(entry.lastPathComponent)
            _ = try GTELargeSecurePath.legacyFileIdentity(at: url)
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
        try removeInterruptedPrivateRemovals()
        try validateQuarantinedArtifacts()
        try removeInterruptedFilePromotionTemporaries()
        try recoverJournalTemporaries()
        guard fileSystem.itemExists(at: promotionJournalURL) else {
            try recoverCurrentPointerTemporaries()
            try removeOwnedOrphanModelDirectories()
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
            try recoverCurrentPointerTemporaries()
            try removeOwnedOrphanModelDirectories()
            return
        }
        let backup = journal.backupDirectoryName.flatMap(safeChild(named:))

        // The journal is durable before the old install moves to its backup.
        // A power loss at that point leaves the verified old install and the
        // verified staging directory together. Keep the old install, discard
        // only the journal-recorded staging object, and publish its pointer.
        if let backup,
           let backupIdentity = journal.backupIdentity,
           !fileSystem.itemExists(at: backup),
           isPrivateDirectory(installedDirectory),
           (try? fileSystem.directoryIdentity(at: installedDirectory, requiredPermissions: 0o700)).map({ GTELargeSecurePath.sameDirectoryIdentity($0, backupIdentity) }) == true,
           verifyRecord(in: installedDirectory), verifyFiles(in: installedDirectory),
           isPrivateDirectory(staging),
           (try? fileSystem.directoryIdentity(at: staging, requiredPermissions: 0o700)).map({ GTELargeSecurePath.sameDirectoryIdentity($0, stagingIdentity) }) == true {
            try writeCurrentPointer()
            try fileSystem.removeItem(at: staging, expectedDirectoryIdentity: stagingIdentity)
            try removeVerifiedPrivateFile(at: promotionJournalURL)
            try recoverCurrentPointerTemporaries()
            try fileSystem.syncDirectory(at: rootDirectory)
            GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
            return
        }

        if isPrivateDirectory(installedDirectory),
           (try? fileSystem.directoryIdentity(at: installedDirectory, requiredPermissions: 0o700)).map({ GTELargeSecurePath.sameObjectIdentity($0, stagingIdentity) }) == true,
           verifyRecord(in: installedDirectory), verifyFiles(in: installedDirectory) {
            try writeCurrentPointer()
        } else if let backup,
                  let backupIdentity = journal.backupIdentity,
                  (try? fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700)).map({ GTELargeSecurePath.sameObjectIdentity($0, backupIdentity) }) == true,
                  verifyRecord(in: backup), verifyFiles(in: backup) {
            if fileSystem.itemExists(at: installedDirectory) {
                // A name collision after an interrupted promotion is not safe
                // to remove. The journal proves only the recorded objects.
                throw GTELargeModelInstallError.unsafePath
            }
            try fileSystem.moveItem(at: backup, to: installedDirectory, expectedSourceDirectoryIdentity: backupIdentity)
            try writeCurrentPointer()
        } else if isPrivateDirectory(staging),
                  (try? fileSystem.directoryIdentity(at: staging, requiredPermissions: 0o700)).map({ GTELargeSecurePath.sameDirectoryIdentity($0, stagingIdentity) }) == true,
                  verifyRecord(in: staging), verifyFiles(in: staging) {
            if fileSystem.itemExists(at: installedDirectory) {
                throw GTELargeModelInstallError.unsafePath
            }
            try fileSystem.moveItem(at: staging, to: installedDirectory, expectedSourceDirectoryIdentity: stagingIdentity)
            try writeCurrentPointer()
        } else {
            throw GTELargeModelInstallError.verificationFailed
        }
        if fileSystem.itemExists(at: staging),
           (try? fileSystem.directoryIdentity(at: staging, requiredPermissions: 0o700)).map({ GTELargeSecurePath.sameDirectoryIdentity($0, stagingIdentity) }) == true {
            try fileSystem.removeItem(at: staging, expectedDirectoryIdentity: stagingIdentity)
        }
        if let backup,
           let backupIdentity = journal.backupIdentity,
           fileSystem.itemExists(at: backup),
           (try? fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700)).map({ GTELargeSecurePath.sameObjectIdentity($0, backupIdentity) }) == true,
           verifyRecord(in: backup), verifyFiles(in: backup, useCache: false),
           let currentBackup = try? fileSystem.directoryIdentity(at: backup, requiredPermissions: 0o700) {
            try fileSystem.removeItem(at: backup, expectedDirectoryIdentity: currentBackup)
        }
        try removeVerifiedPrivateFile(at: promotionJournalURL)
        try recoverCurrentPointerTemporaries()
        try fileSystem.syncDirectory(at: rootDirectory)
        GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
    }

    private func recoverCurrentPointerTemporaries() throws {
        let entries = try fileSystem.contentsOfDirectory(at: rootDirectory, maximumEntries: 128)
        let backups = entries
            .filter { isOwnedCurrentBackupName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let invalidPointers = entries
            .filter { isOwnedInvalidCurrentName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let temporaries = entries
            .filter { isOwnedCurrentTemporaryName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard backups.count <= 1,
              invalidPointers.count <= 32,
              temporaries.count <= 32 else {
            throw GTELargeModelInstallError.unsafePath
        }

        var currentIsValid = isCurrentPointerValid()
        let installedPayloadIsValid = isPrivateDirectory(installedDirectory) &&
            verifyRecord(in: installedDirectory) && verifyFiles(in: installedDirectory)

        for backup in backups {
            try Task.checkCancellation()
            guard let data = try? readSmallFile(at: backup),
                  let pointer = try? JSONDecoder().decode(GTELargeInstallPointer.self, from: data),
                  pointerPayloadIsValid(pointer) else {
                // This name has no durable ownership record. Retain an
                // invalid or mutated replacement for manual inspection.
                continue
            }
            let identity = try fileSystem.fileIdentity(at: backup)
            if !currentIsValid {
                try fileSystem.replaceFileAtomically(
                    at: backup,
                    to: currentPointerURL,
                    expectedSourceIdentity: identity
                )
                currentIsValid = isCurrentPointerValid()
            } else {
                try fileSystem.removeItem(at: backup, expectedFileIdentity: identity)
            }
        }

        for temporary in temporaries {
            try Task.checkCancellation()
            guard let data = try? readSmallFile(at: temporary),
                  let pointer = try? JSONDecoder().decode(GTELargeInstallPointer.self, from: data),
                  pointer.schema == 1,
                  pointer.directoryName == manifest.installationDirectoryName,
                  pointer.record.matches(manifest),
                  installedPayloadIsValid else {
                let identity = try fileSystem.fileIdentity(at: temporary)
                try fileSystem.removeItem(at: temporary, expectedFileIdentity: identity)
                continue
            }
            if !currentIsValid {
                let identity = try fileSystem.fileIdentity(at: temporary)
                try fileSystem.replaceFileAtomically(
                    at: temporary,
                    to: currentPointerURL,
                    expectedSourceIdentity: identity
                )
                currentIsValid = true
            } else {
                let identity = try fileSystem.fileIdentity(at: temporary)
                try fileSystem.removeItem(at: temporary, expectedFileIdentity: identity)
            }
        }
        for invalidPointer in invalidPointers {
            try Task.checkCancellation()
            let identity = try fileSystem.fileIdentity(at: invalidPointer)
            try fileSystem.removeItem(at: invalidPointer, expectedFileIdentity: identity)
        }
        try fileSystem.syncDirectory(at: rootDirectory)
    }

    private func recoverJournalTemporaries() throws {
        let temporaries = try fileSystem.contentsOfDirectory(at: rootDirectory, maximumEntries: 128)
            .filter { isOwnedJournalTemporaryName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard temporaries.count <= 32 else { throw GTELargeModelInstallError.unsafePath }
        var journalPresent = fileSystem.itemExists(at: promotionJournalURL)
        if journalPresent {
            let canonicalIsValid = (try? readSmallFile(at: promotionJournalURL))
                .flatMap { try? JSONDecoder().decode(GTELargePromotionJournal.self, from: $0) }
                .map(isValidJournalPayload) ?? false
            if !canonicalIsValid {
                try quarantineInvalidRecoveryArtifacts()
                journalPresent = false
            }
        }
        for temporary in temporaries {
            guard let data = try? readSmallFile(at: temporary),
                  let journal = try? JSONDecoder().decode(GTELargePromotionJournal.self, from: data),
                  isValidJournalPayload(journal) else {
                let identity = try fileSystem.fileIdentity(at: temporary)
                try fileSystem.removeItem(at: temporary, expectedFileIdentity: identity)
                continue
            }
            if !journalPresent {
                let identity = try fileSystem.fileIdentity(at: temporary)
                try fileSystem.moveItem(at: temporary, to: promotionJournalURL, expectedSourceIdentity: identity)
                journalPresent = true
            } else {
                let identity = try fileSystem.fileIdentity(at: temporary)
                try fileSystem.removeItem(at: temporary, expectedFileIdentity: identity)
            }
        }
        try fileSystem.syncDirectory(at: rootDirectory)
    }

    private func verifiedPromotionJournal() -> [(url: URL, identity: GTELargeFileIdentity)]? {
        guard let data = try? readSmallFile(at: promotionJournalURL),
              let journal = try? JSONDecoder().decode(GTELargePromotionJournal.self, from: data),
              journal.schema == 1,
              journal.revision == manifest.revision,
              isOwnedStagingName(journal.stagingDirectoryName),
              let stagingIdentity = journal.stagingIdentity,
              let staging = safeChild(named: journal.stagingDirectoryName),
              (journal.backupDirectoryName == nil) == (journal.backupIdentity == nil) else {
            return nil
        }
        var artifacts: [(url: URL, identity: GTELargeFileIdentity)] = [(staging, stagingIdentity)]
        if let backupName = journal.backupDirectoryName,
           let backupIdentity = journal.backupIdentity,
           isOwnedBackupName(backupName),
           let backup = safeChild(named: backupName) {
            artifacts.append((backup, backupIdentity))
        } else if journal.backupDirectoryName != nil {
            return nil
        }
        return artifacts
    }

    private func isValidJournalPayload(_ journal: GTELargePromotionJournal) -> Bool {
        journal.schema == 1 &&
            journal.revision == manifest.revision &&
            isOwnedStagingName(journal.stagingDirectoryName) &&
            (journal.backupDirectoryName.map(isOwnedBackupName) ?? true) &&
            journal.stagingIdentity != nil &&
            (journal.backupDirectoryName == nil) == (journal.backupIdentity == nil)
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
        let (data, identity) = try fileSystem.read(from: url, maximumSize: limit)
        guard identity.size >= 0, identity.size <= limit,
              data.count == Int(identity.size) else { throw GTELargeModelInstallError.unreadableInstall }
        return data
    }

    private func removeVerifiedPrivateFile(at url: URL) throws {
        let identity = try fileSystem.fileIdentity(at: url)
        try fileSystem.removeItem(at: url, expectedFileIdentity: identity)
    }

    private func removeVerifiedPrivateDirectory(at url: URL) throws {
        let identity = try fileSystem.directoryIdentity(at: url, requiredPermissions: 0o700)
        try fileSystem.removeItem(at: url, expectedDirectoryIdentity: identity)
    }

    private func manifestIsValid() -> Bool {
        guard manifest.formatVersion == 1,
              manifest.repositoryID.range(of: "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              manifest.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              manifest.upstreamRepositoryID.range(of: "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              manifest.upstreamRevision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              manifest.upstreamLicense == "MIT",
              !manifest.conversion.isEmpty,
              isSafePathComponent(manifest.installationDirectoryName),
              manifest.files.count == Set(manifest.files.map(\.name)).count else { return false }
        return manifest.files.allSatisfy {
            isSafePathComponent($0.name) && $0.size >= 0 &&
                $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        }
    }

    private func installConfigurationIsValid() -> Bool {
        rootDirectory.isFileURL &&
            rootDirectory.pathComponents.first == "/" &&
            !rootDirectory.pathComponents.contains("..") &&
            manifestIsValid()
    }

    private func isSafePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\u{0}") && !name.hasPrefix("~") &&
            URL(fileURLWithPath: name).lastPathComponent == name
    }

    private func safeChild(named name: String) -> URL? {
        guard installConfigurationIsValid(), isSafePathComponent(name) else { return nil }
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

    private func isOwnedUnverifiedName(_ name: String) -> Bool {
        let prefix = ".gte-large-unverified-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedCurrentTemporaryName(_ name: String) -> Bool {
        let prefix = ".gte-large-current-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedCurrentBackupName(_ name: String) -> Bool {
        let prefix = ".gte-large-current-previous-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedInvalidCurrentName(_ name: String) -> Bool {
        let prefix = ".gte-large-current-invalid-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedJournalTemporaryName(_ name: String) -> Bool {
        let prefix = ".gte-large-journal-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedCopyTemporaryName(_ name: String) -> Bool {
        let prefix = ".gte-large-copy-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedInvalidJournalName(_ name: String) -> Bool {
        let prefix = ".gte-large-invalid-journal-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedRemovingName(_ name: String) -> Bool {
        let prefix = ".gte-large-removing-"
        return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func isOwnedVersionDirectoryName(_ name: String) -> Bool {
        let prefix = "gte-large-"
        let revision = String(name.dropFirst(prefix.count))
        return name.hasPrefix(prefix) && revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    private func quarantineInvalidRecoveryArtifacts() throws {
        // A UUID-shaped name is not an ownership record. An invalid journal
        // may name arbitrary sibling paths, so mark only the exact private
        // journal file and leave every referenced artifact intact.
        if (try? fileSystem.fileIdentity(at: promotionJournalURL)) != nil {
            let quarantine = rootDirectory.appendingPathComponent(".gte-large-invalid-journal-\(UUID().uuidString)")
            let identity = try fileSystem.fileIdentity(at: promotionJournalURL)
            try fileSystem.moveItem(at: promotionJournalURL, to: quarantine, expectedSourceIdentity: identity)
        }
        try fileSystem.syncDirectory(at: rootDirectory)
        GTELargeVerificationCache.shared.removeAll(in: rootDirectory)
    }

    private func isCurrentPointerValid() -> Bool {
        guard let data = try? readSmallFile(at: currentPointerURL),
              let pointer = try? JSONDecoder().decode(GTELargeInstallPointer.self, from: data),
              pointer.schema == 1,
              pointer.directoryName == manifest.installationDirectoryName,
              pointer.record.matches(manifest) else {
            return false
        }
        return isPrivateDirectory(installedDirectory) && verifyRecord(in: installedDirectory) && verifyFiles(in: installedDirectory)
    }

    private func currentPointerPayloadIsValid() -> Bool {
        guard let data = try? readSmallFile(at: currentPointerURL),
              let pointer = try? JSONDecoder().decode(GTELargeInstallPointer.self, from: data) else {
            return false
        }
        return pointerPayloadIsValid(pointer)
    }

    private func pointerPayloadIsValid(_ pointer: GTELargeInstallPointer) -> Bool {
        let record = pointer.record
        guard pointer.schema == 1,
              record.formatVersion == 1,
              record.repositoryID.range(of: "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              record.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              pointer.directoryName == "gte-large-\(record.revision)",
              isSafePathComponent(pointer.directoryName),
              !record.files.isEmpty,
              record.files.count <= 16,
              record.files.count == Set(record.files.map(\.name)).count,
              record.files.allSatisfy({
                  isSafePathComponent($0.name) && $0.size >= 0 &&
                      $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
              }),
              let directory = safeChild(named: pointer.directoryName),
              isPrivateDirectory(directory),
              let data = try? readSmallFile(at: directory.appendingPathComponent("install.json")),
              let installedRecord = try? JSONDecoder().decode(GTELargeModelInstallRecord.self, from: data),
              installedRecord == record else {
            return false
        }
        var totalBytes: Int64 = 0
        for file in record.files {
            let (next, overflow) = totalBytes.addingReportingOverflow(file.size)
            guard !overflow, next <= 2_147_483_648 else { return false }
            totalBytes = next
            guard let result = try? GTELargeSecurePath.hashPrivateFile(
                at: directory.appendingPathComponent(file.name),
                expectedSize: file.size
            ), result.0.caseInsensitiveCompare(file.sha256) == .orderedSame else {
                return false
            }
        }
        return true
    }

    private func removeInterruptedFilePromotionTemporaries() throws {
        let temporaries = try fileSystem.contentsOfDirectory(at: rootDirectory, maximumEntries: 128)
            .filter { isOwnedCopyTemporaryName($0.lastPathComponent) }
        guard temporaries.count <= 32 else { throw GTELargeModelInstallError.unsafePath }
        let maximumBytes = manifest.files.reduce(Int64(0)) { partial, file in
            let (next, overflow) = partial.addingReportingOverflow(file.size)
            return overflow ? Int64.max : next
        }
        var totalBytes: Int64 = 0
        for temporary in temporaries {
            let identity = try fileSystem.fileIdentity(at: temporary)
            let (next, overflow) = totalBytes.addingReportingOverflow(identity.size)
            guard !overflow, next <= maximumBytes else { throw GTELargeModelInstallError.unsafePath }
            totalBytes = next
            try fileSystem.removeItem(at: temporary, expectedFileIdentity: identity)
        }
        if !temporaries.isEmpty {
            try fileSystem.syncDirectory(at: rootDirectory)
        }
    }

    private func removeInterruptedPrivateRemovals() throws {
        let artifacts = try fileSystem.contentsOfDirectory(at: rootDirectory, maximumEntries: 128)
            .filter { isOwnedRemovingName($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard artifacts.count <= 32 else { throw GTELargeModelInstallError.unsafePath }

        let perInstallBudget = manifest.files.reduce(Int64(0)) { partial, file in
            let (next, overflow) = partial.addingReportingOverflow(file.size)
            return overflow ? Int64.max : next
        }
        let (maximumBytes, overflow) = perInstallBudget.multipliedReportingOverflow(by: 4)
        guard !overflow else { throw GTELargeModelInstallError.unsafePath }
        var totalBytes: Int64 = 0

        for artifact in artifacts {
            try Task.checkCancellation()
            let remaining = maximumBytes - totalBytes
            let tree = try fileSystem.privateTree(
                at: artifact,
                maximumEntries: 4_096,
                maximumDepth: 16,
                maximumBytes: remaining
            )
            let (next, additionOverflow) = totalBytes.addingReportingOverflow(tree.bytes)
            guard !additionOverflow, next <= maximumBytes else {
                throw GTELargeModelInstallError.unsafePath
            }
            totalBytes = next
            try fileSystem.removePrivateTree(at: artifact, tree: tree, maximumDepth: 16)
        }
        if !artifacts.isEmpty { try fileSystem.syncDirectory(at: rootDirectory) }
    }

    private func validateQuarantinedArtifacts() throws {
        let artifacts = try fileSystem.contentsOfDirectory(at: rootDirectory, maximumEntries: 128)
            .filter { isOwnedInvalidJournalName($0.lastPathComponent) }
        guard artifacts.count <= 8 else {
            throw GTELargeModelInstallError.unsafePath
        }
        var totalBytes: Int64 = 0
        for artifact in artifacts {
            let identity = try fileSystem.fileIdentity(at: artifact)
            let (next, overflow) = totalBytes.addingReportingOverflow(identity.size)
            guard !overflow, next <= 524_288 else { throw GTELargeModelInstallError.unsafePath }
            totalBytes = next
        }
    }

    private func removeOwnedOrphanModelDirectories() throws {
        // A complete staging or rollback directory binds itself to the fixed
        // manifest. The count and byte limits bound recovery work. Hitting a
        // limit fails closed instead of cleaning only part of the candidate set.
        let candidates = try fileSystem.contentsOfDirectory(at: rootDirectory, maximumEntries: 128)
            .filter {
                isOwnedStagingName($0.lastPathComponent) ||
                    isOwnedUnverifiedName($0.lastPathComponent)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let maximumCandidates = 32
        guard candidates.count <= maximumCandidates else {
            throw GTELargeModelInstallError.unsafePath
        }

        let perInstallBudget = manifest.files.reduce(Int64(0)) { partial, file in
            let (next, overflow) = partial.addingReportingOverflow(file.size)
            return overflow ? Int64.max : next
        }
        let (boundedFiles, filesOverflow) = perInstallBudget.multipliedReportingOverflow(by: 4)
        let (maximumBytes, bytesOverflow) = boundedFiles.addingReportingOverflow(262_144)
        guard !filesOverflow, !bytesOverflow else {
            throw GTELargeModelInstallError.unsafePath
        }

        var totalBytes: Int64 = 0
        for candidate in candidates {
            try Task.checkCancellation()
            guard let orphan = verifiedOrphanModelDirectory(candidate) else {
                continue
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(orphan.bytes)
            guard !overflow, nextTotal <= maximumBytes else {
                throw GTELargeModelInstallError.unsafePath
            }
            totalBytes = nextTotal
            try fileSystem.removeItem(at: candidate, expectedDirectoryIdentity: orphan.identity)
        }
        try fileSystem.syncDirectory(at: rootDirectory)
    }

    private func verifiedOrphanModelDirectory(_ directory: URL) -> (identity: GTELargeFileIdentity, bytes: Int64)? {
        guard let directoryIdentity = try? fileSystem.directoryIdentity(at: directory, requiredPermissions: 0o700),
              let entries = try? fileSystem.contentsOfDirectory(at: directory, maximumEntries: manifest.files.count + 1) else {
            return nil
        }
        let expectedNames = Set(manifest.files.map(\.name) + ["install.json"])
        guard Set(entries.map(\.lastPathComponent)) == expectedNames else { return nil }

        var bytes: Int64 = 0
        for name in expectedNames {
            guard let identity = try? fileSystem.fileIdentity(at: directory.appendingPathComponent(name)) else {
                return nil
            }
            let (next, overflow) = bytes.addingReportingOverflow(identity.size)
            guard !overflow else { return nil }
            bytes = next
        }
        guard verifyRecord(in: directory), verifyFiles(in: directory) else { return nil }
        return (directoryIdentity, bytes)
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
