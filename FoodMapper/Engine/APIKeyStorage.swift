import Foundation
import Security
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "api-key-storage")

/// Stores the optional Anthropic API key in the macOS data-protection keychain.
enum APIKeyStorage {
    private static let service = "com.foodmapper.api-keys"
    private static let account = "anthropic-api-key"

    // FoodMapper 0.1.x stored this value in UserDefaults. Keep the name only
    // long enough to move an existing value into Keychain and remove it.
    private static let legacyUserDefaultsKey = "anthropic_api_key"
    private static let legacyMigrationFlag = "api_key_migrated_from_keychain"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    // MARK: - Anthropic API Key

    /// Store or replace an Anthropic API key.
    @discardableResult
    static func setAnthropicAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8), !data.isEmpty else { return false }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        let status: OSStatus
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecAttrLabel as String] = "FoodMapper Anthropic API key"
            status = SecItemAdd(addQuery as CFDictionary, nil)
        } else {
            status = updateStatus
        }

        guard status == errSecSuccess else {
            logger.error("Unable to store Anthropic API key (status: \(status, privacy: .public))")
            return false
        }

        removeLegacyUserDefaultsValue()
        logger.info("Anthropic API key saved in Keychain")
        return true
    }

    /// Retrieve the stored Anthropic API key, or nil if none exists.
    static func getAnthropicAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            if status != errSecItemNotFound {
                logger.error("Unable to read Anthropic API key (status: \(status, privacy: .public))")
            }
            return nil
        }
        return key
    }

    static func hasAnthropicAPIKey() -> Bool {
        getAnthropicAPIKey() != nil
    }

    @discardableResult
    static func deleteAnthropicAPIKey() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        removeLegacyUserDefaultsValue()

        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Unable to delete Anthropic API key (status: \(status, privacy: .public))")
            return false
        }

        logger.info("Anthropic API key deleted")
        return true
    }

    // MARK: - Migration

    /// Move keys saved by FoodMapper 0.1.x from UserDefaults into Keychain.
    /// The plaintext value is removed only after Keychain confirms the write.
    static func migrateToKeychainIfNeeded() {
        if hasAnthropicAPIKey() {
            removeLegacyUserDefaultsValue()
            return
        }

        guard let legacyKey = UserDefaults.standard.string(forKey: legacyUserDefaultsKey),
              !legacyKey.isEmpty else {
            UserDefaults.standard.removeObject(forKey: legacyMigrationFlag)
            return
        }

        if setAnthropicAPIKey(legacyKey) {
            logger.info("Migrated Anthropic API key from UserDefaults to Keychain")
        } else {
            logger.error("Anthropic API key migration to Keychain failed")
        }
    }

    private static func removeLegacyUserDefaultsValue() {
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: legacyMigrationFlag)
    }
}
