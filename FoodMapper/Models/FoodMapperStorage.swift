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
            return try createPrivateDirectory(components)
        } catch {
            preconditionFailure("Unable to prepare FoodMapper storage: \(error.localizedDescription)")
        }
    }

    private static func makeConfiguration() -> Configuration {
        guard testIsolationIsRequired else {
            let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!.resolvingSymlinksInPath().standardizedFileURL
            guard let applicationSupportIdentity = directoryIdentity(at: applicationSupportURL) else {
                preconditionFailure("Application Support is unavailable")
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
            preconditionFailure("XCTest requires FOODMAPPER_TEST_STORAGE_ROOT before FoodMapper starts")
        }
        guard let defaults = UserDefaults(suiteName: testConfiguration.suite) else {
            preconditionFailure("XCTest requires a unique FOODMAPPER_TEST_DEFAULTS_SUITE before FoodMapper starts")
        }

        let suppliedRoot = testConfiguration.root.standardizedFileURL
        validateTestRoot(suppliedRoot, requireDirectPath: true)
        let root = suppliedRoot.resolvingSymlinksInPath().standardizedFileURL
        validateTestRoot(root, requireDirectPath: false)
        guard let applicationSupportIdentity = directoryIdentity(at: root) else {
            preconditionFailure("FOODMAPPER_TEST_STORAGE_ROOT changed during validation")
        }
        let temporaryURL = root.appendingPathComponent("Temporary", isDirectory: true)
        createDirectoryIfNeeded(temporaryURL)
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

    private static func isUniqueTestSuite(_ suite: String) -> Bool {
        suite.hasPrefix("app.foodmapper.FoodMapper.tests.") &&
            UUID(uuidString: String(suite.dropFirst("app.foodmapper.FoodMapper.tests.".count))) != nil
    }

    static func expectedTestConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (root: URL, suite: String)? {
        testConfiguration(from: environment)
    }

    private static func testConfiguration(
        from environment: [String: String]
    ) -> (root: URL, suite: String)? {
        if let rootPath = environment["FOODMAPPER_TEST_STORAGE_ROOT"],
           rootPath.hasPrefix("/"),
           let suite = environment["FOODMAPPER_TEST_DEFAULTS_SUITE"],
           isUniqueTestSuite(suite) {
            return (URL(fileURLWithPath: rootPath, isDirectory: true), suite)
        }

        let markerKeys = ["XCTestBundlePath", "XCInjectBundle", "XCTestConfigurationFilePath"]
        for key in markerKeys {
            guard let markerPath = environment[key], markerPath.hasPrefix("/") else { continue }
            let components = URL(fileURLWithPath: markerPath).standardizedFileURL.pathComponents
            for component in components {
                let prefixes = ["foodmapper-xctest-", "foodmapper-derived-data-"]
                for prefix in prefixes where component.hasPrefix(prefix) {
                    let identifier = String(component.dropFirst(prefix.count))
                    guard UUID(uuidString: identifier) != nil else { continue }
                    let root = URL(
                        fileURLWithPath: "/private/tmp/foodmapper-xctest-\(identifier)",
                        isDirectory: true
                    )
                    let suite = "app.foodmapper.FoodMapper.tests.\(identifier)"
                    return (root, suite)
                }
            }
        }
        return nil
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

    private static func createPrivateDirectory(_ components: [String]) throws -> URL {
        guard components.allSatisfy(isSafeLeaf) else { throw StorageError.invalidPath }
        let applicationSupport = configuration.applicationSupportURL
        let rootDescriptor = try openDirectory(applicationSupport)
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0,
              DirectoryIdentity(device: rootInfo.st_dev, inode: rootInfo.st_ino) ==
                configuration.applicationSupportIdentity else {
            close(rootDescriptor)
            throw StorageError.invalidPath
        }
        var currentDescriptor = rootDescriptor
        defer { close(currentDescriptor) }
        var currentURL = applicationSupport
        for component in ["FoodMapper"] + components {
            if mkdirat(currentDescriptor, component, 0o700) != 0, errno != EEXIST {
                throw StorageError.invalidPath
            }
            let nextDescriptor = openat(currentDescriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard nextDescriptor >= 0 else { throw StorageError.invalidPath }
            close(currentDescriptor)
            currentDescriptor = nextDescriptor
            currentURL.appendPathComponent(component, isDirectory: true)

            var info = stat()
            guard fstat(currentDescriptor, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(),
                  (info.st_mode & 0o077) == 0 else {
                throw StorageError.invalidPath
            }
        }
        return currentURL
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
