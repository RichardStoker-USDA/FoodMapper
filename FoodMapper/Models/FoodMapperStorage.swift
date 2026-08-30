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
    private struct Configuration {
        let applicationSupportURL: URL
        let temporaryURL: URL
        let defaults: UserDefaults
        let credentialStore: CredentialStore
        let isIsolatedTestStorage: Bool
        let defaultsSuite: String?
    }

    private static let configuration = makeConfiguration()

    static var applicationSupportURL: URL { configuration.applicationSupportURL }
    static var temporaryURL: URL { configuration.temporaryURL }
    static var defaults: UserDefaults { configuration.defaults }
    static var credentialStore: CredentialStore { configuration.credentialStore }
    static var isIsolatedTestStorage: Bool { configuration.isIsolatedTestStorage }
    static var usesInMemoryCredentials: Bool { configuration.isIsolatedTestStorage }
    static var defaultsSuite: String? { configuration.defaultsSuite }

    static var liveApplicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FoodMapper", isDirectory: true)
            .standardizedFileURL
    }

    private static func makeConfiguration() -> Configuration {
        guard isRunningUnderXCTest else {
            let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("FoodMapper", isDirectory: true)
            createDirectoryIfNeeded(temporaryURL)
            return Configuration(
                applicationSupportURL: applicationSupportURL,
                temporaryURL: temporaryURL,
                defaults: .standard,
                credentialStore: KeychainCredentialStore(),
                isIsolatedTestStorage: false,
                defaultsSuite: nil
            )
        }

        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["FOODMAPPER_TEST_STORAGE_ROOT"],
              rootPath.hasPrefix("/") else {
            preconditionFailure("XCTest requires FOODMAPPER_TEST_STORAGE_ROOT before FoodMapper starts")
        }
        guard let suite = environment["FOODMAPPER_TEST_DEFAULTS_SUITE"],
              isUniqueTestSuite(suite),
              let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("XCTest requires a unique FOODMAPPER_TEST_DEFAULTS_SUITE before FoodMapper starts")
        }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        validateTestRoot(root)
        let temporaryURL = root.appendingPathComponent("Temporary", isDirectory: true)
        createDirectoryIfNeeded(temporaryURL)
        return Configuration(
            applicationSupportURL: root,
            temporaryURL: temporaryURL,
            defaults: defaults,
            credentialStore: InMemoryCredentialStore(),
            isIsolatedTestStorage: true,
            defaultsSuite: suite
        )
    }

    private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil
    }

    private static func isUniqueTestSuite(_ suite: String) -> Bool {
        suite.hasPrefix("app.foodmapper.FoodMapper.tests.") &&
            UUID(uuidString: String(suite.dropFirst("app.foodmapper.FoodMapper.tests.".count))) != nil
    }

    private static func validateTestRoot(_ root: URL) {
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
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else {
            preconditionFailure("FOODMAPPER_TEST_STORAGE_ROOT must be a pre-created mode-0700 directory owned by this user")
        }
    }

    private static func pathsOverlap(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func createDirectoryIfNeeded(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            preconditionFailure("Unable to prepare FoodMapper temporary storage: \(error.localizedDescription)")
        }
    }
}
