import AppKit
import Foundation

enum ChatGPTSignInState: Equatable {
    case idle
    case waitingForBrowser
    case finishing
    case failed(String)
}

extension AppState {
    /// The signed-in ChatGPT registration that a plan profile can bill to.
    var activeChatGPTAccount: ChatGPTAccount? {
        chatGPTAccounts.first { $0.isSignedIn }
    }

    func loadChatGPTAccounts() {
        Task { [weak self] in
            let accounts = await ChatGPTAccountStore.shared.accounts()
            await MainActor.run { self?.chatGPTAccounts = accounts }
        }
    }

    /// Opens the browser for sign-in. `account` is a saved registration to sign back in to.
    func startChatGPTSignIn(reauthorizing account: ChatGPTAccount? = nil) {
        guard chatGPTSignInTask == nil else { return }
        let lease: AdvancedFeatureLease
        do {
            lease = try advancedFeatureGate.issueLease()
        } catch {
            chatGPTSignInState = .failed(error.localizedDescription)
            return
        }
        chatGPTSignInState = .waitingForBrowser
        let gate = advancedFeatureGate

        chatGPTSignInTask = Task { [weak self] in
            let listener = LoopbackCallbackListener()
            let transport = URLSessionProviderTransport()
            defer {
                listener.stop()
                transport.invalidate()
            }
            do {
                let store = ChatGPTAccountStore.shared
                let port = try await listener.start()
                let hostID = try await store.hostID()
                let attempt = try ChatGPTAuthorizationAttempt.make(port: port, issuedClientID: account?.clientID)
                var hint: String?
                if let account { hint = await store.idTokenHint(accountID: account.id) }
                let url = attempt.authorizationURL(hostID: hostID, idTokenHint: hint, loginHint: account?.email)
                // Without this check a browser that never opened looks like a five-minute wait.
                guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
                    throw ChatGPTSignInError.browserUnavailable
                }

                let target = try await listener.waitForCallback(timeout: 300)
                try gate.validate(lease)
                await MainActor.run { self?.chatGPTSignInState = .finishing }

                let callback = try ChatGPTCallback.parse(requestTarget: target, attempt: attempt)
                let response = try await ChatGPTAuthClient.exchangeCode(callback, attempt: attempt, transport: transport)
                guard let idToken = response.idToken else { throw ChatGPTSignInError.invalidToken("missing") }
                let keys = try await ChatGPTAuthClient.signingKeys(transport: transport)
                let identity = try ChatGPTIDToken.validate(
                    idToken, jwks: keys, clientID: callback.clientID, nonce: attempt.nonce
                )
                if let account, account.subject != identity.subject {
                    throw ChatGPTSignInError.identityMismatch
                }
                try gate.validate(lease)
                let saved = try await store.completeSignIn(
                    response: response, identity: identity, clientID: callback.clientID, existingAccountID: account?.id
                )
                var models: [ChatGPTModel] = []
                if saved.planUseGranted {
                    models = (try? await ChatGPTAuthClient.models(accessToken: response.accessToken, transport: transport)) ?? []
                }
                let accounts = await store.accounts()
                await MainActor.run {
                    guard let self else { return }
                    self.chatGPTAccounts = accounts
                    self.chatGPTModels = models
                    self.chatGPTSignInTask = nil
                    if saved.planUseGranted {
                        self.chatGPTSignInState = .idle
                        self.chatGPTPlanNoticeAccountID = saved.planUseAcknowledged ? nil : saved.id
                    } else {
                        self.chatGPTSignInState = .failed(ChatGPTSignInError.planNotGranted.localizedDescription)
                    }
                }
            } catch {
                let message: String?
                switch error {
                case is CancellationError: message = nil
                case AdvancedFeatureError.disabled, AdvancedFeatureError.expiredLease: message = nil
                default: message = error.localizedDescription
                }
                await MainActor.run {
                    self?.chatGPTSignInTask = nil
                    self?.chatGPTSignInState = message.map { .failed($0) } ?? .idle
                }
            }
        }
    }

    func cancelChatGPTSignIn() {
        chatGPTSignInTask?.cancel()
        chatGPTSignInTask = nil
        chatGPTSignInState = .idle
    }

    /// Records that the user saw the one-time plan-use notice.
    func acknowledgeChatGPTPlanUse() {
        guard let accountID = chatGPTPlanNoticeAccountID else { return }
        chatGPTPlanNoticeAccountID = nil
        Task { [weak self] in
            try? await ChatGPTAccountStore.shared.acknowledgePlanUse(accountID: accountID)
            let accounts = await ChatGPTAccountStore.shared.accounts()
            await MainActor.run { self?.chatGPTAccounts = accounts }
        }
    }

    /// Signs out of ChatGPT on this Mac and asks OpenAI to end the renewable session.
    func signOutChatGPT(_ account: ChatGPTAccount) {
        Task { [weak self] in
            let confirmed = await ChatGPTAccountStore.shared.signOut(accountID: account.id)
            let accounts = await ChatGPTAccountStore.shared.accounts()
            await MainActor.run {
                guard let self else { return }
                self.chatGPTAccounts = accounts
                self.chatGPTModels = []
                self.providerProbeState = .idle
                self.chatGPTSignInState = confirmed
                    ? .idle
                    : .failed("Signed out on this Mac. OpenAI did not confirm ending the session; you can disconnect FoodMapper in ChatGPT settings.")
            }
        }
    }

    /// Reloads the model list for the signed-in account.
    func refreshChatGPTModels() {
        guard let account = activeChatGPTAccount, account.planUseGranted else {
            chatGPTModels = []
            return
        }
        Task { [weak self] in
            let transport = URLSessionProviderTransport()
            defer { transport.invalidate() }
            guard let token = try? await ChatGPTAccountStore.shared.accessToken(accountID: account.id),
                  let models = try? await ChatGPTAuthClient.models(accessToken: token, transport: transport) else { return }
            await MainActor.run { self?.chatGPTModels = models }
        }
    }

    /// The credential source for a profile: its Keychain value, or the account's refreshed plan token.
    func credentialSource(for profile: ProviderProfile) -> ProviderCredentialSource {
        if profile.kind == .chatGPTPlan, let accountID = profile.accountID {
            return { try await ChatGPTAccountStore.shared.accessToken(accountID: accountID) }
        }
        let credential = APIKeyStorage.getProviderCredential(profileID: profile.id)
        return { credential }
    }

    /// Whether a run or connection test has the credential it needs.
    func hasCredential(for profile: ProviderProfile) -> Bool {
        switch profile.kind {
        case .openAI:
            return APIKeyStorage.hasProviderCredential(profileID: profile.id)
        case .chatGPTPlan:
            return chatGPTAccounts.contains { $0.id == profile.accountID && $0.planUseGranted }
        case .localOpenAICompatible:
            return true
        }
    }
}
