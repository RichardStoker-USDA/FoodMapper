import Foundation
import Security
import Darwin

protocol CredentialStore: AnyObject {
    @discardableResult
    func set(_ value: Data, service: String, account: String, label: String) -> Bool
    func value(service: String, account: String) -> Data?
    @discardableResult
    func remove(service: String, account: String) -> Bool
}

final class KeychainCredentialStore: CredentialStore {
    private func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func set(_ value: Data, service: String, account: String, label: String) -> Bool {
        let baseQuery = query(service: service, account: account)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        let status: OSStatus
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = value
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecAttrLabel as String] = label
            status = SecItemAdd(addQuery as CFDictionary, nil)
        } else {
            status = updateStatus
        }
        return status == errSecSuccess
    }

    func value(service: String, account: String) -> Data? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    func remove(service: String, account: String) -> Bool {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    private func key(service: String, account: String) -> String {
        service + "\u{0}" + account
    }

    func set(_ value: Data, service: String, account: String, label: String) -> Bool {
        lock.lock()
        values[key(service: service, account: account)] = value
        lock.unlock()
        return true
    }

    func value(service: String, account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key(service: service, account: account)]
    }

    func remove(service: String, account: String) -> Bool {
        lock.lock()
        values.removeValue(forKey: key(service: service, account: account))
        lock.unlock()
        return true
    }
}

enum FoodMapperStorage {
    private struct DirectoryIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Configuration {
        let applicationSupportURL: URL
        let applicationSupportIdentity: DirectoryIdentity
        let temporaryURL: URL
        let defaults: UserDefaults
        let credentialStore: CredentialStore
        let isIsolatedTestStorage: Bool
        let defaultsSuite: String?
    }

    private static let configuration = makeConfiguration()

    static var applicationSupportURL: URL { configuration.applicationSupportURL }
    static var temporaryURL: URL { configuration.temporaryURL }
    static var processTemporaryRootURL: URL {
        FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }
    static var defaults: UserDefaults { configuration.defaults }
    static var credentialStore: CredentialStore { configuration.credentialStore }
    static var isIsolatedTestStorage: Bool { configuration.isIsolatedTestStorage }
    static var usesInMemoryCredentials: Bool { configuration.credentialStore is InMemoryCredentialStore }
    static var defaultsSuite: String? { configuration.defaultsSuite }

    static func isOwnedDirectory(
        mode: mode_t,
        owner: uid_t,
        currentUser: uid_t
    ) -> Bool {
        (mode & S_IFMT) == S_IFDIR && owner == currentUser
    }

    static var liveApplicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FoodMapper", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    /// Creates an app-owned directory through descriptor-relative operations.
    /// Existing directories must be private, owned by the current user, and
    /// free of symlinks at every component below Application Support.
    static func privateDirectory(_ components: [String] = []) -> URL {
        do {
            return try preparePrivateDirectory(components)
        } catch {
            preconditionFailure("Unable to prepare FoodMapper storage: \(error.localizedDescription)")
        }
    }

    /// Prepare known app directories without changing files inside them.
    /// Existing directories are reduced to mode 0700 through their descriptors.
    static func preparePrivateStorage() throws {
        try preparePrivateStorage(
            under: configuration.applicationSupportURL,
            expectedRootIdentity: configuration.applicationSupportIdentity
        )
    }

    /// Throwing form used by tests and startup code that can present a recovery error.
    static func preparePrivateDirectory(_ components: [String]) throws -> URL {
        try createPrivateDirectory(
            ["FoodMapper"] + components,
            under: configuration.applicationSupportURL,
            expectedRootIdentity: configuration.applicationSupportIdentity
        )
    }

    private static func makeConfiguration() -> Configuration {
        guard testIsolationIsRequired else {
            let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.resolvingSymlinksInPath().standardizedFileURL
            guard let applicationSupportIdentity = directoryIdentity(at: applicationSupportURL) else {
                preconditionFailure("Application Support is unavailable")
            }
            do {
                try preparePrivateStorage(
                    under: applicationSupportURL,
                    expectedRootIdentity: applicationSupportIdentity
                )
            } catch {
                preconditionFailure("Unable to prepare FoodMapper storage: \(error.localizedDescription)")
            }
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FoodMapper", isDirectory: true)
            createDirectoryIfNeeded(temporaryURL)
            return Configuration(
                applicationSupportURL: applicationSupportURL,
                applicationSupportIdentity: applicationSupportIdentity,
                temporaryURL: temporaryURL,
                defaults: .standard,
                credentialStore: KeychainCredentialStore(),
                isIsolatedTestStorage: false,
                defaultsSuite: nil
            )
        }

        let environment = ProcessInfo.processInfo.environment
        guard let testConfiguration = testConfiguration(from: environment) else {
            preconditionFailure("XCTest requires a valid isolated storage configuration before FoodMapper starts")
        }
        guard let defaults = UserDefaults(suiteName: testConfiguration.suite) else {
            preconditionFailure("XCTest requires an isolated defaults suite before FoodMapper starts")
        }

        let suppliedRoot = testConfiguration.root.standardizedFileURL
        validateTestRoot(suppliedRoot, requireDirectPath: true)
        let root = suppliedRoot.resolvingSymlinksInPath().standardizedFileURL
        validateTestRoot(root, requireDirectPath: false)
        guard let applicationSupportIdentity = directoryIdentity(at: root) else {
            preconditionFailure("FOODMAPPER_TEST_STORAGE_ROOT changed during validation")
        }
        let temporaryURL: URL
        do {
            try preparePrivateStorage(
                under: root, expectedRootIdentity: applicationSupportIdentity
            )
            temporaryURL = try createPrivateDirectory(
                ["Temporary"], under: root, expectedRootIdentity: applicationSupportIdentity
            )
        } catch {
            preconditionFailure("Unable to prepare FoodMapper test temporary storage: \(error.localizedDescription)")
        }
        return Configuration(
            applicationSupportURL: root,
            applicationSupportIdentity: applicationSupportIdentity,
            temporaryURL: temporaryURL,
            defaults: defaults,
            credentialStore: InMemoryCredentialStore(),
            isIsolatedTestStorage: true,
            defaultsSuite: testConfiguration.suite
        )
    }

    private static var testIsolationIsRequired: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCInjectBundle"] != nil ||
            environment["XCTestSessionIdentifier"] != nil ||
            environment.keys.contains(where: { $0.hasPrefix("FOODMAPPER_TEST_") })
    }

    private static func testSuiteIdentifier(_ suite: String) -> String? {
        let prefix = "app.foodmapper.FoodMapper.tests."
        guard suite.hasPrefix(prefix) else { return nil }
        let identifier = String(suite.dropFirst(prefix.count))
        return isCanonicalUUID(identifier) ? identifier : nil
    }

    static func expectedTestConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (root: URL, suite: String)? {
        testConfiguration(from: environment)
    }

    private enum MarkerState {
        case absent
        case invalid
        case valid(String)
    }

    private static let testMarkerKeys = [
        "XCTestBundlePath",
        "XCInjectBundle",
        "XCTestConfigurationFilePath",
    ]

    private static let knownDirectoryNames = ["Models", "CustomDBs", "InputFiles", "Sessions"]
    private static let canonicalTemporaryPathPrefix = "/private/tmp/"
    private static let derivedDataDirectoryPrefix = "foodmapper-derived-data-"
    private static let testStorageDirectoryPrefix = "foodmapper-xctest-"

    private static func testConfiguration(
        from environment: [String: String]
    ) -> (root: URL, suite: String)? {
        let explicitRoot = environment["FOODMAPPER_TEST_STORAGE_ROOT"]
        let explicitSuite = environment["FOODMAPPER_TEST_DEFAULTS_SUITE"]
        let markerState = markerState(from: environment)

        switch (explicitRoot, explicitSuite) {
        case (nil, nil):
            guard case .valid(let identifier) = markerState else { return nil }
            return wrapperTestConfiguration(identifier: identifier)

        case let (rootPath?, suite?):
            guard rootPath.hasPrefix("/"),
                  let suiteIdentifier = testSuiteIdentifier(suite),
                  let rootIdentifier = wrapperTestIdentifier(from: rootPath),
                  rootIdentifier == suiteIdentifier else { return nil }
            switch markerState {
            case .absent:
                return (URL(fileURLWithPath: rootPath, isDirectory: true), suite)
            case .invalid:
                return nil
            case .valid(let identifier):
                guard rootIdentifier == identifier else { return nil }
                return (URL(fileURLWithPath: rootPath, isDirectory: true), suite)
            }

        default:
            return nil
        }
    }

    private static func markerState(from environment: [String: String]) -> MarkerState {
        var identifiers: [String] = []
        for key in testMarkerKeys {
            guard let markerPath = environment[key] else { continue }
            guard let identifier = markerIdentifier(in: markerPath) else { return .invalid }
            identifiers.append(identifier)
        }
        guard let first = identifiers.first else { return .absent }
        guard identifiers.allSatisfy({ $0 == first }) else { return .invalid }
        return .valid(first)
    }

    private static func markerIdentifier(in markerPath: String) -> String? {
        guard markerPath.hasPrefix(canonicalTemporaryPathPrefix) else { return nil }
        let standardized = URL(fileURLWithPath: markerPath).standardizedFileURL
        guard standardized.path == markerPath else { return nil }
        let rawComponents = String(markerPath.dropFirst(canonicalTemporaryPathPrefix.count))
            .split(separator: "/", omittingEmptySubsequences: true)
        guard rawComponents.count >= 2,
              let rawWrapper = derivedDataDirectory(String(rawComponents[0])) else { return nil }

        guard let canonicalPath = canonicalExistingPath(markerPath) else { return nil }
        guard canonicalPath == markerPath else { return nil }
        let canonicalComponents = String(canonicalPath.dropFirst(canonicalTemporaryPathPrefix.count))
            .split(separator: "/", omittingEmptySubsequences: true)
        guard canonicalComponents.count >= 2,
              let canonicalWrapper = derivedDataDirectory(String(canonicalComponents[0])),
              rawWrapper.name == canonicalWrapper.name,
              rawWrapper.identifier == canonicalWrapper.identifier else { return nil }
        return canonicalWrapper.identifier
    }

    private static func wrapperTestConfiguration(identifier: String) -> (root: URL, suite: String) {
        (
            URL(fileURLWithPath: "/private/tmp/foodmapper-xctest-\(identifier)", isDirectory: true),
            "app.foodmapper.FoodMapper.tests.\(identifier)"
        )
    }

    private static func wrapperTestIdentifier(from rootPath: String) -> String? {
        guard rootPath.hasPrefix(canonicalTemporaryPathPrefix) else { return nil }
        let standardized = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard standardized.path == rootPath else { return nil }
        let rawComponents = String(rootPath.dropFirst(canonicalTemporaryPathPrefix.count))
            .split(separator: "/", omittingEmptySubsequences: true)
        guard rawComponents.count == 1,
              let rawWrapper = testStorageDirectory(String(rawComponents[0])) else { return nil }

        guard let canonicalPath = canonicalExistingPath(rootPath) else { return nil }
        guard canonicalPath == rootPath else { return nil }
        let canonicalComponents = String(canonicalPath.dropFirst(canonicalTemporaryPathPrefix.count))
            .split(separator: "/", omittingEmptySubsequences: true)
        guard canonicalComponents.count == 1,
              let canonicalWrapper = testStorageDirectory(String(canonicalComponents[0])),
              rawWrapper.name == canonicalWrapper.name,
              rawWrapper.identifier == canonicalWrapper.identifier else { return nil }
        return canonicalWrapper.identifier
    }

    private static func derivedDataDirectory(_ component: String) -> (name: String, identifier: String)? {
        directory(named: component, prefix: derivedDataDirectoryPrefix)
    }

    private static func testStorageDirectory(_ component: String) -> (name: String, identifier: String)? {
        directory(named: component, prefix: testStorageDirectoryPrefix)
    }

    private static func directory(
        named component: String,
        prefix: String
    ) -> (name: String, identifier: String)? {
        guard component.hasPrefix(prefix) else { return nil }
        let identifier = String(component.dropFirst(prefix.count))
        guard isCanonicalUUID(identifier) else { return nil }
        return (component, identifier)
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36 else { return false }
        for (index, byte) in value.utf8.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == 45 else { return false }
            default:
                guard (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102) else {
                    return false
                }
            }
        }
        return UUID(uuidString: value) != nil
    }

    private static func canonicalExistingPath(_ path: String) -> String? {
        path.withCString { pointer in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(pointer, &buffer) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    private static func validateTestRoot(_ root: URL, requireDirectPath: Bool) {
        let path = root.path
        guard path.hasPrefix("/") else {
            preconditionFailure("FOODMAPPER_TEST_STORAGE_ROOT must be absolute")
        }
        let live = liveApplicationSupportURL.path
        let liveParent = liveApplicationSupportURL.deletingLastPathComponent().path
        guard !pathsOverlap(path, live), !pathsOverlap(path, liveParent) else {
            preconditionFailure("FOODMAPPER_TEST_STORAGE_ROOT must not overlap FoodMapper Application Support")
        }

        var info = stat()
        guard lstat(path, &info) == 0 else {
            preconditionFailure("FOODMAPPER_TEST_STORAGE_ROOT must be a pre-created mode-0700 directory owned by this user")
        }
        if requireDirectPath, (info.st_mode & S_IFMT) == S_IFLNK {
            preconditionFailure("FOODMAPPER_TEST_STORAGE_ROOT must not be a symbolic link")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else {
            preconditionFailure("FOODMAPPER_TEST_STORAGE_ROOT must be a pre-created mode-0700 directory owned by this user")
        }
    }

    private static func pathsOverlap(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func directoryIdentity(at url: URL) -> DirectoryIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private static func createDirectoryIfNeeded(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            preconditionFailure("Unable to prepare FoodMapper temporary storage: \(error.localizedDescription)")
        }
    }

    private static func preparePrivateStorage(
        under rootURL: URL,
        expectedRootIdentity: DirectoryIdentity
    ) throws {
        _ = try createPrivateDirectory(
            ["FoodMapper"], under: rootURL, expectedRootIdentity: expectedRootIdentity
        )
        for name in knownDirectoryNames {
            _ = try createPrivateDirectory(
                ["FoodMapper", name], under: rootURL, expectedRootIdentity: expectedRootIdentity
            )
        }
    }

    private static func createPrivateDirectory(
        _ components: [String],
        under rootURL: URL,
        expectedRootIdentity: DirectoryIdentity
    ) throws -> URL {
        guard components.allSatisfy(isSafeLeaf) else { throw StorageError.invalidPath }
        let rootDescriptor = try openDirectory(rootURL)
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              DirectoryIdentity(device: rootInfo.st_dev, inode: rootInfo.st_ino) ==
                expectedRootIdentity else {
            close(rootDescriptor)
            throw StorageError.invalidPath
        }
        var currentDescriptor = rootDescriptor
        defer { close(currentDescriptor) }
        var currentURL = rootURL
        for component in components {
            currentDescriptor = try openPrivateChildDirectory(
                component,
                parentDescriptor: currentDescriptor
            )
            currentURL.appendPathComponent(component, isDirectory: true)
        }
        return currentURL
    }

    private static func openPrivateChildDirectory(
        _ component: String,
        parentDescriptor: Int32
    ) throws -> Int32 {
        if mkdirat(parentDescriptor, component, 0o700) != 0, errno != EEXIST {
            throw StorageError.invalidPath
        }
        let childDescriptor = openat(
            parentDescriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard childDescriptor >= 0 else { throw StorageError.invalidPath }
        do {
            try makePrivateDirectory(childDescriptor)
            try synchronizeDirectory(childDescriptor)
            try synchronizeDirectory(parentDescriptor)
        } catch {
            close(childDescriptor)
            throw error
        }
        close(parentDescriptor)
        return childDescriptor
    }

    private static func makePrivateDirectory(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isOwnedDirectory(
                  mode: info.st_mode,
                  owner: info.st_uid,
                  currentUser: getuid()
              ) else {
            throw StorageError.invalidPath
        }
        guard fchmod(descriptor, 0o700) == 0 else {
            throw StorageError.invalidPath
        }
        guard fstat(descriptor, &info) == 0,
              isOwnedDirectory(
                  mode: info.st_mode,
                  owner: info.st_uid,
                  currentUser: getuid()
              ),
              (info.st_mode & 0o777) == 0o700 else {
                throw StorageError.invalidPath
        }
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw StorageError.invalidPath }
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw StorageError.invalidPath }
        for component in url.path.split(separator: "/").map(String.init) {
            guard isSafeLeaf(component) else {
                close(descriptor)
                throw StorageError.invalidPath
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(descriptor)
            guard next >= 0 else { throw StorageError.invalidPath }
            descriptor = next
        }
        return descriptor
    }

    private static func isSafeLeaf(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private enum StorageError: LocalizedError {
        case invalidPath

        var errorDescription: String? { "The storage path is not private and safe to use." }
    }
}
