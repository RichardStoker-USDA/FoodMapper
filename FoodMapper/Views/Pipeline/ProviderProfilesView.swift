import SwiftUI

/// Stores provider connection metadata while keeping credentials in Keychain.
struct ProviderProfilesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editor: ProviderEditorState?
    @State private var profilePendingDeletion: ProviderProfile?
    @State private var profilePendingRemoteProbe: ProviderProfile?
    @State private var operationError: String?

    private var selectedProfile: ProviderProfile? {
        appState.providerProfiles.first { $0.id == appState.selectedProviderProfileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()
            chatGPTPanel
            Divider()

            HSplitView {
                profileList
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

                Group {
                    if let selectedProfile {
                        profileInspector(selectedProfile)
                    } else {
                        ContentUnavailableView(
                            "No Provider Profiles",
                            systemImage: "network",
                            description: Text("Sign in with ChatGPT above, or add an OpenAI API key or a loopback OpenAI-compatible server.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $editor) { state in
            ProviderEditorSheet(
                state: state,
                onSave: { profile, credential in
                    do {
                        try appState.saveProviderProfile(profile, credential: credential)
                        editor = nil
                    } catch {
                        operationError = error.localizedDescription
                    }
                },
                onCancel: { editor = nil }
            )
        }
        .confirmationDialog(
            "Test this connection?",
            isPresented: Binding(
                get: { profilePendingRemoteProbe != nil },
                set: { if !$0 { profilePendingRemoteProbe = nil } }
            ),
            presenting: profilePendingRemoteProbe
        ) { profile in
            Button("Send Probe") {
                profilePendingRemoteProbe = nil
                appState.probeProvider(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("FoodMapper will send one synthetic food description and two synthetic candidates to OpenAI. No imported data is included. A ChatGPT plan profile counts this request against your plan.")
        }
        .confirmationDialog(
            "Delete this provider profile?",
            isPresented: Binding(
                get: { profilePendingDeletion != nil },
                set: { if !$0 { profilePendingDeletion = nil } }
            ),
            presenting: profilePendingDeletion
        ) { profile in
            Button("Delete \(profile.name)", role: .destructive) {
                do {
                    try appState.deleteProviderProfile(profile)
                } catch {
                    operationError = error.localizedDescription
                }
                profilePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The profile metadata and its Keychain credential will be removed.")
        }
        .alert(
            "You're using your ChatGPT plan",
            isPresented: Binding(
                get: { appState.chatGPTPlanNoticeAccountID != nil },
                set: { if !$0 { appState.acknowledgeChatGPTPlanUse() } }
            )
        ) {
            Button("Got it") { appState.acknowledgeChatGPTPlanUse() }
        } message: {
            Text("Provider runs that use a ChatGPT plan profile count against your ChatGPT plan, not an API key. You can review and limit FoodMapper's usage in ChatGPT settings.")
        }
        .alert(
            "Provider Error",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "The provider operation failed.")
        }
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Label("Providers", systemImage: "network")
                    .font(.headline)
                Text("Define optional model endpoints for evaluation workflows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Provider", systemImage: "plus") {
                editor = ProviderEditorState.newProfile()
            }
        }
        .frame(height: HeaderLayout.height)
        .padding(.horizontal, Spacing.lg)
    }

    /// ChatGPT sign-in state. Shown above the profiles because a plan profile needs it first.
    private var chatGPTPanel: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            if let account = appState.activeChatGPTAccount {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(account.displayLabel)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: Spacing.xs) {
                        Text(account.planUseGranted ? "Using ChatGPT plan" : "Signed in without plan use")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("Manage usage", destination: ChatGPTOAuth.usageURL)
                            .font(.caption)
                    }
                }
                Spacer()
                if account.planUseGranted, !appState.providerProfiles.contains(where: { $0.accountID == account.id }) {
                    Button("Add Plan Profile") {
                        editor = ProviderEditorState.planProfile(account: account, models: appState.chatGPTModels)
                    }
                }
                if !account.planUseGranted {
                    Button("Allow Plan Use") { appState.startChatGPTSignIn(reauthorizing: account) }
                }
                Button("Sign Out") { appState.signOutChatGPT(account) }
            } else {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("Use your ChatGPT plan")
                        .font(.callout.weight(.medium))
                    Text(chatGPTStatusText)
                        .font(.caption)
                        .foregroundStyle(chatGPTStatusIsError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch appState.chatGPTSignInState {
                case .waitingForBrowser, .finishing:
                    ProgressView().controlSize(.small)
                    Button("Cancel") { appState.cancelChatGPTSignIn() }
                case .idle, .failed:
                    Button("Continue with ChatGPT") {
                        appState.startChatGPTSignIn(
                            reauthorizing: appState.chatGPTAccounts.first
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private var chatGPTStatusText: String {
        switch appState.chatGPTSignInState {
        case .idle:
            return "Sign in to run provider decisions on your ChatGPT plan, with no API key. Your browser opens to OpenAI."
        case .waitingForBrowser:
            return "Finish signing in in your browser."
        case .finishing:
            return "Verifying the sign-in."
        case let .failed(message):
            return message
        }
    }

    private var chatGPTStatusIsError: Bool {
        if case .failed = appState.chatGPTSignInState { return true }
        return false
    }

    private func symbol(for kind: ProviderKind) -> String {
        switch kind {
        case .openAI: return "globe"
        case .chatGPTPlan: return "person.crop.circle"
        case .localOpenAICompatible: return "desktopcomputer"
        }
    }

    private var profileList: some View {
        List(selection: $appState.selectedProviderProfileID) {
            ForEach(appState.providerProfiles) { profile in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: symbol(for: profile.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: Size.iconSmall)
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(profile.name)
                            .lineLimit(1)
                        Text(profile.model)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .tag(profile.id)
            }
        }
        .listStyle(.sidebar)
    }

    private func profileInspector(_ profile: ProviderProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(profile.name)
                            .font(.title2.weight(.semibold))
                        Text(profile.kind.displayName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        editor = ProviderEditorState(profile: profile)
                    }
                    Button("Delete") {
                        profilePendingDeletion = profile
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: Spacing.xxl, verticalSpacing: Spacing.md) {
                    GridRow {
                        detailCell("Endpoint", profile.baseURL)
                            .gridCellColumns(2)
                    }
                    GridRow {
                        detailCell("Model", profile.model)
                        detailCell("Credential", credentialStatus(profile))
                    }
                    GridRow {
                        detailCell("Request route", profile.interface.displayName)
                        detailCell("Response", profile.interface == .decisions ? "Choice with probabilities" : "Strict JSON schema")
                    }
                    GridRow {
                        detailCell("Reasoning effort", profile.interface == .responses ? (profile.reasoningEffort?.displayName ?? "Model default") : "Not used")
                        detailCell("Simultaneous requests", "\(profile.concurrency)")
                    }
                }
                .padding(Spacing.lg)
                .panelMaterialStyle(cornerRadius: 10)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("CONNECTION PROBE")
                        .technicalLabel()
                    Text("The probe asks the endpoint to select boiled broccoli from two fixed candidates and checks its JSON response. Imported files are not read.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: Spacing.md) {
                        probeStatus(profile)
                        Spacer()
                        if isTesting(profile) {
                            Button("Cancel Probe") {
                                appState.cancelProviderProbe()
                            }
                        } else {
                            Button("Test Connection") {
                                if profile.kind.sendsDataOffDevice {
                                    profilePendingRemoteProbe = profile
                                } else {
                                    appState.probeProvider(profile)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(Spacing.lg)
                .panelMaterialStyle(cornerRadius: 10)

                Text("Profiles are stored without credentials. API keys and ChatGPT sign-in tokens stay in the macOS Keychain. Local profiles are limited to loopback addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 800, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func detailCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func probeStatus(_ profile: ProviderProfile) -> some View {
        switch appState.providerProbeState {
        case .idle:
            Label("Not tested", systemImage: "circle")
                .foregroundStyle(.secondary)
        case let .testing(id) where id == profile.id:
            HStack(spacing: Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Testing")
            }
            .foregroundStyle(.secondary)
        case let .passed(receipt) where receipt.profileID == profile.id:
            if appState.hasCurrentProviderProbe(for: profile) {
                Label("Passed \(receipt.completedAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("Test expired", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        case let .failed(id, message) where id == profile.id:
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Label("Not tested", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private func isTesting(_ profile: ProviderProfile) -> Bool {
        if case let .testing(id) = appState.providerProbeState {
            return id == profile.id
        }
        return false
    }

    private func credentialStatus(_ profile: ProviderProfile) -> String {
        switch profile.kind {
        case .chatGPTPlan:
            return appState.hasCredential(for: profile) ? "ChatGPT sign-in" : "Sign-in needed"
        case .openAI:
            return APIKeyStorage.hasProviderCredential(profileID: profile.id) ? "Stored in Keychain" : "Missing"
        case .localOpenAICompatible:
            return APIKeyStorage.hasProviderCredential(profileID: profile.id) ? "Stored in Keychain" : "None"
        }
    }

}

private struct ProviderEditorState: Identifiable {
    let id = UUID()
    let profile: ProviderProfile
    var models: [ChatGPTModel] = []

    static func newProfile() -> ProviderEditorState {
        ProviderEditorState(profile: ProviderProfile(
            name: "",
            kind: .localOpenAICompatible,
            baseURL: "http://127.0.0.1:8000/v1",
            model: ""
        ))
    }

    static func planProfile(account: ChatGPTAccount, models: [ChatGPTModel]) -> ProviderEditorState {
        ProviderEditorState(profile: ProviderProfile(
            name: "ChatGPT plan",
            kind: .chatGPTPlan,
            baseURL: ProviderKind.chatGPTPlan.fixedBaseURL?.absoluteString ?? "",
            model: models.first?.slug ?? "",
            interface: .responses,
            reasoningEffort: .low,
            concurrency: 4,
            accountID: account.id
        ), models: models)
    }
}

private struct ProviderEditorSheet: View {
    let state: ProviderEditorState
    let onSave: (ProviderProfile, String?) -> Void
    let onCancel: () -> Void

    @State private var profile: ProviderProfile
    @State private var credential = ""
    @State private var validationError: String?

    init(
        state: ProviderEditorState,
        onSave: @escaping (ProviderProfile, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.state = state
        self.onSave = onSave
        self.onCancel = onCancel
        _profile = State(initialValue: state.profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.profile.name.isEmpty ? "Add Provider" : "Edit Provider")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(Spacing.xl)

            Divider()

            Form {
                TextField("Name", text: $profile.name)

                if profile.kind == .chatGPTPlan {
                    LabeledContent("Type", value: ProviderKind.chatGPTPlan.displayName)
                } else {
                    Picker("Type", selection: $profile.kind) {
                        ForEach([ProviderKind.openAI, .localOpenAICompatible]) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .onChange(of: profile.kind) { _, kind in
                        profile.baseURL = kind.fixedBaseURL?.absoluteString ?? "http://127.0.0.1:8000/v1"
                        profile.interface = kind.allowedInterfaces[0]
                        profile.concurrency = min(profile.concurrency, kind.maximumConcurrency)
                    }
                }

                if profile.kind == .localOpenAICompatible {
                    TextField("Endpoint", text: $profile.baseURL, prompt: Text("http://127.0.0.1:8000/v1"))
                } else {
                    LabeledContent("Endpoint", value: profile.kind.fixedBaseURL?.absoluteString ?? "")
                }

                if profile.kind == .chatGPTPlan, !state.models.isEmpty {
                    Picker("Model", selection: $profile.model) {
                        ForEach(state.models) { model in
                            Text(model.displayName).tag(model.slug)
                        }
                    }
                } else {
                    TextField("Model", text: $profile.model)
                }

                if profile.kind == .openAI {
                    SecureField("API key", text: $credential)
                } else if profile.kind == .localOpenAICompatible {
                    SecureField("Bearer token (optional)", text: $credential)
                }

                if profile.kind.allowedInterfaces.count > 1 {
                    Picker("Request route", selection: $profile.interface) {
                        ForEach(profile.kind.allowedInterfaces) { interface in
                            Text(interface.displayName).tag(interface)
                        }
                    }
                }

                if profile.interface == .responses {
                    Picker("Reasoning effort", selection: $profile.reasoningEffort) {
                        Text("Model default").tag(ProviderReasoningEffort?.none)
                        ForEach(ProviderReasoningEffort.allCases) { effort in
                            Text(effort.displayName).tag(Optional(effort))
                        }
                    }
                }

                Stepper(
                    "Simultaneous requests: \(profile.concurrency)",
                    value: $profile.concurrency,
                    in: 1...profile.kind.maximumConcurrency
                )

                Text("FoodMapper controls the messages, output schema, streaming mode, token limit, and credentials for automatic decisions. Decisions returns a choice with a probability for each candidate; Responses and Chat Completions return a strict JSON decision.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, Spacing.lg)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.lg)
        }
        .frame(width: 600, height: 640)
    }

    private func save() {
        do {
            let checked = try profile.validated()
            if checked.kind == .openAI,
               credential.isEmpty,
               !APIKeyStorage.hasProviderCredential(profileID: checked.id) {
                throw ProviderProfileStoreError.credentialMissing
            }
            validationError = nil
            onSave(checked, credential.isEmpty ? nil : credential)
        } catch {
            validationError = error.localizedDescription
        }
    }
}

#Preview("Providers") {
    ProviderProfilesView()
        .environmentObject(PreviewHelpers.emptyAdvancedState())
        .frame(width: 1000, height: 720)
}
