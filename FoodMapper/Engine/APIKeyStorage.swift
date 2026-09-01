import Foundation
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "api-key-storage")

/// Stores the optional Anthropic API key in the macOS data-protection keychain.
enum APIKeyStorage {
    private static let service = "com.foodmapper.api-keys"
    private static let account = "anthropic-api-key"
    private static let providerAccountPrefix = "provider-profile-"

    // FoodMapper 0.1.x stored this value in UserDefaults. Keep the name only
    // long enough to move an existing value into Keychain and remove it.
    private static let legacyUserDefaultsKey = "anthropic_api_key"
    private static let legacyMigrationFlag = "api_key_migrated_from_keychain"

    // MARK: - Anthropic API Key

    /// Store or replace an Anthropic API key.
    @discardableResult
    static func setAnthropicAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8), !data.isEmpty else { return false }

        guard FoodMapperStorage.credentialStore.set(
            data,
            service: service,
            account: account,
            label: "FoodMapper Anthropic API key"
        ) else {
            logger.error("Unable to store Anthropic API key")
            return false
        }

        removeLegacyUserDefaultsValue()
        logger.info("Anthropic API key saved in Keychain")
        return true
    }

    /// Retrieve the stored Anthropic API key, or nil if none exists.
    static func getAnthropicAPIKey() -> String? {
        guard let data = FoodMapperStorage.credentialStore.value(service: service, account: account),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func hasAnthropicAPIKey() -> Bool {
        getAnthropicAPIKey() != nil
    }

    @discardableResult
    static func deleteAnthropicAPIKey() -> Bool {
        removeLegacyUserDefaultsValue()

        guard FoodMapperStorage.credentialStore.remove(service: service, account: account) else {
            logger.error("Unable to delete Anthropic API key")
            return false
        }

        logger.info("Anthropic API key deleted")
        return true
    }

    // MARK: - Advanced Provider Credentials

    @discardableResult
    static func setProviderCredential(_ credential: String, profileID: UUID) -> Bool {
        guard let data = credential.data(using: .utf8), !data.isEmpty else { return false }
        return FoodMapperStorage.credentialStore.set(
            data,
            service: service,
            account: providerAccountPrefix + profileID.uuidString.lowercased(),
            label: "FoodMapper provider credential"
        )
    }

    static func getProviderCredential(profileID: UUID) -> String? {
        guard let data = FoodMapperStorage.credentialStore.value(
            service: service,
            account: providerAccountPrefix + profileID.uuidString.lowercased()
        ), let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func hasProviderCredential(profileID: UUID) -> Bool {
        getProviderCredential(profileID: profileID) != nil
    }

    @discardableResult
    static func deleteProviderCredential(profileID: UUID) -> Bool {
        FoodMapperStorage.credentialStore.remove(
            service: service,
            account: providerAccountPrefix + profileID.uuidString.lowercased()
        )
    }

    // MARK: - Migration

    /// Move keys saved by FoodMapper 0.1.x from UserDefaults into Keychain.
    /// The plaintext value is removed only after Keychain confirms the write.
    static func migrateToKeychainIfNeeded() {
        if hasAnthropicAPIKey() {
            removeLegacyUserDefaultsValue()
            return
        }

        guard let legacyKey = FoodMapperStorage.defaults.string(forKey: legacyUserDefaultsKey),
              !legacyKey.isEmpty else {
            FoodMapperStorage.defaults.removeObject(forKey: legacyMigrationFlag)
            return
        }

        if setAnthropicAPIKey(legacyKey) {
            logger.info("Migrated Anthropic API key from UserDefaults to Keychain")
        } else {
            logger.error("Anthropic API key migration to Keychain failed")
        }
    }

    private static func removeLegacyUserDefaultsValue() {
        FoodMapperStorage.defaults.removeObject(forKey: legacyUserDefaultsKey)
        FoodMapperStorage.defaults.removeObject(forKey: legacyMigrationFlag)
    }
}
