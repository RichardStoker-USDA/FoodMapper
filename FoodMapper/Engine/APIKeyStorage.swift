import Foundation
import Security
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "api-key-storage")

/// API key storage via UserDefaults. Replaced Keychain because it was triggering
/// macOS password dialogs on every access. User's own key, own machine -- fine.
enum APIKeyStorage {
    private static let anthropicKeyDefault = "anthropic_api_key"
    private static let migratedFromKeychainDefault = "api_key_migrated_from_keychain"

    // MARK: - Anthropic API Key

    /// Store an Anthropic API key.
    static func setAnthropicAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: anthropicKeyDefault)
        logger.info("Anthropic API key saved")
    }

    /// Retrieve the stored Anthropic API key, or nil if none exists.
    static func getAnthropicAPIKey() -> String? {
        guard let key = UserDefaults.standard.string(forKey: anthropicKeyDefault),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    /// Check if an API key exists.
    static func hasAnthropicAPIKey() -> Bool {
        getAnthropicAPIKey() != nil
    }

    /// Delete the stored Anthropic API key.
    @discardableResult
    static func deleteAnthropicAPIKey() -> Bool {
        UserDefaults.standard.removeObject(forKey: anthropicKeyDefault)
        logger.info("Anthropic API key deleted")
        return true
    }

    // MARK: - Migration

    /// One-time migration from Keychain to UserDefaults.
    /// If a key exists in the old Keychain storage, moves it here and removes from Keychain.
    /// Fails silently if Keychain triggers a password dialog (user can re-enter manually).
    static func migrateFromKeychainIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedFromKeychainDefault) else { return }

        // Mark as attempted regardless of outcome (don't retry on every launch)
        UserDefaults.standard.set(true, forKey: migratedFromKeychainDefault)

        // Try to read from old Keychain storage (may trigger password dialog, which is OK once)
        let service = "com.foodmapper.api-keys"
        let account = "anthropic-api-key"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data,
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            // Migrate to UserDefaults
            setAnthropicAPIKey(key)
            logger.info("Migrated API key from Keychain to UserDefaults")

            // Clean up Keychain entry
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            logger.info("Removed old Keychain entry")
        } else {
            logger.info("No Keychain API key to migrate (status: \(status))")
        }
    }
}
