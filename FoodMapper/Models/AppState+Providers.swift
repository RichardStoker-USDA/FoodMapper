import Foundation

enum ProviderProbeState: Equatable {
    case idle
    case testing(UUID)
    case passed(ProviderProbeReceipt)
    case failed(UUID, String)
}

struct ProviderProbeReceipt: Equatable {
    let profileID: UUID
    let profileFingerprint: String
    let adapterVersion: String
    let responseMode: String
    let requestSchemaHash: String
    let completedAt: Date
}

extension AppState {
    var providerProfilesURL: URL {
        FoodMapperStorage.privateDirectory(["Providers"])
            .appendingPathComponent("profiles.json")
    }

    func loadProviderProfiles() {
        guard let data = try? Data(contentsOf: providerProfilesURL),
              let decoded = try? JSONDecoder().decode([ProviderProfile].self, from: data) else {
            providerProfiles = []
            selectedProviderProfileID = nil
            return
        }
        providerProfiles = decoded.compactMap { try? $0.validated() }
        if selectedProviderProfileID == nil || !providerProfiles.contains(where: { $0.id == selectedProviderProfileID }) {
            selectedProviderProfileID = providerProfiles.first?.id
        }
    }

    func saveProviderProfile(_ profile: ProviderProfile, credential: String?) throws {
        let lease = try advancedFeatureGate.issueLease()
        let checked = try profile.validated()
        let priorProfiles = providerProfiles
        let priorCredential = APIKeyStorage.getProviderCredential(profileID: checked.id)
        if let index = providerProfiles.firstIndex(where: { $0.id == checked.id }) {
            providerProfiles[index] = checked
        } else {
            providerProfiles.append(checked)
        }

        do {
            if let credential, !credential.isEmpty,
               !APIKeyStorage.setProviderCredential(credential, profileID: checked.id) {
                throw ProviderProfileStoreError.credentialWriteFailed
            }
            try advancedFeatureGate.validate(lease)
            try persistProviderProfiles()
        } catch {
            providerProfiles = priorProfiles
            if let priorCredential {
                _ = APIKeyStorage.setProviderCredential(priorCredential, profileID: checked.id)
            } else if credential?.isEmpty == false {
                _ = APIKeyStorage.deleteProviderCredential(profileID: checked.id)
            }
            throw error
        }

        selectedProviderProfileID = checked.id
        providerProbeState = .idle
    }

    func deleteProviderProfile(_ profile: ProviderProfile) throws {
        let lease = try advancedFeatureGate.issueLease()
        let priorProfiles = providerProfiles
        let priorSelection = selectedProviderProfileID
        let priorCredential = APIKeyStorage.getProviderCredential(profileID: profile.id)
        if priorCredential != nil,
           !APIKeyStorage.deleteProviderCredential(profileID: profile.id) {
            throw ProviderProfileStoreError.credentialDeleteFailed
        }

        do {
            try advancedFeatureGate.validate(lease)
            providerProfiles.removeAll { $0.id == profile.id }
            if selectedProviderProfileID == profile.id {
                selectedProviderProfileID = providerProfiles.first?.id
            }
            try persistProviderProfiles()
        } catch {
            providerProfiles = priorProfiles
            selectedProviderProfileID = priorSelection
            if let priorCredential,
               !APIKeyStorage.setProviderCredential(priorCredential, profileID: profile.id) {
                throw ProviderProfileStoreError.credentialRollbackFailed
            }
            throw error
        }
        providerProbeState = .idle
    }

    func probeProvider(_ profile: ProviderProfile) {
        guard providerProbeTask == nil else { return }
        providerProbeState = .testing(profile.id)
        providerProbeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.providerProbeTask = nil }
            do {
                let lease = try self.advancedFeatureGate.issueLease()
                let checked = try profile.validated()
                let credential = APIKeyStorage.getProviderCredential(profileID: checked.id)
                if checked.kind == .openAI, credential == nil {
                    throw ProviderProfileStoreError.credentialMissing
                }
                let receipt = try await ProviderProbeClient.probe(profile: checked, credential: credential)
                try Task.checkCancellation()
                try self.advancedFeatureGate.validate(lease)
                self.providerProbeState = .passed(receipt)
            } catch is CancellationError {
                self.providerProbeState = .idle
            } catch AdvancedFeatureError.disabled {
                self.providerProbeState = .idle
            } catch AdvancedFeatureError.expiredLease {
                self.providerProbeState = .idle
            } catch {
                self.providerProbeState = .failed(profile.id, error.localizedDescription)
            }
        }
    }

    func cancelProviderProbe() {
        providerProbeTask?.cancel()
        providerProbeTask = nil
        providerProbeState = .idle
    }

    func hasCurrentProviderProbe(for profile: ProviderProfile, now: Date = Date()) -> Bool {
        guard case let .passed(receipt) = providerProbeState,
              receipt.profileID == profile.id,
              receipt.adapterVersion == ProviderAdapterMetadata.version,
              receipt.responseMode == ProviderAdapterMetadata.responseMode,
              receipt.requestSchemaHash == (try? ProviderChatRequest.schemaHash(candidateIDs: ["c1", "c2"])),
              receipt.profileFingerprint == (try? profile.nonsecretFingerprint()),
              now.timeIntervalSince(receipt.completedAt) >= 0,
              now.timeIntervalSince(receipt.completedAt) < 24 * 60 * 60 else {
            return false
        }
        return true
    }

    private func persistProviderProfiles() throws {
        let data = try JSONEncoder().encode(providerProfiles)
        try data.write(to: providerProfilesURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: SecureFileAccess.privateFilePermissions],
            ofItemAtPath: providerProfilesURL.path
        )
    }
}

enum ProviderProfileStoreError: LocalizedError {
    case credentialWriteFailed
    case credentialDeleteFailed
    case credentialRollbackFailed
    case credentialMissing

    var errorDescription: String? {
        switch self {
        case .credentialWriteFailed: return "The provider credential could not be stored in Keychain."
        case .credentialDeleteFailed: return "The provider credential could not be removed from Keychain."
        case .credentialRollbackFailed: return "The provider profile could not be removed, and its Keychain credential could not be restored."
        case .credentialMissing: return "Add an API key before testing this provider."
        }
    }
}

enum ProviderProbeClient {
    static func probe(profile: ProviderProfile, credential: String?) async throws -> ProviderProbeReceipt {
        let selection = try await ProviderDecisionClient.selectCandidate(
            input: "boiled broccoli",
            candidates: ["Broccoli, raw", "Broccoli, cooked, boiled"],
            instruction: "Preparation form must match.",
            profile: profile,
            credential: credential
        )
        guard selection == 1 else {
            throw ProviderProbeError.invalidDecision
        }
        return ProviderProbeReceipt(
            profileID: profile.id,
            profileFingerprint: try profile.nonsecretFingerprint(),
            adapterVersion: ProviderAdapterMetadata.version,
            responseMode: ProviderAdapterMetadata.responseMode,
            requestSchemaHash: try ProviderChatRequest.schemaHash(candidateIDs: ["c1", "c2"]),
            completedAt: Date()
        )
    }
}

enum ProviderProbeError: LocalizedError {
    case invalidDecision

    var errorDescription: String? {
        switch self {
        case .invalidDecision: return "The provider did not return the required candidate decision."
        }
    }
}
