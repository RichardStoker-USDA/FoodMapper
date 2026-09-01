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
                            description: Text("Add OpenAI or a loopback OpenAI-compatible server.")
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
            "Test OpenAI connection?",
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
            Text("FoodMapper will send one synthetic food description and two synthetic candidates to OpenAI. No imported data is included.")
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

    private var profileList: some View {
        List(selection: $appState.selectedProviderProfileID) {
            ForEach(appState.providerProfiles) { profile in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: profile.kind == .openAI ? "globe" : "desktopcomputer")
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
                        detailCell("Output limit", "\(profile.maximumOutputTokens) tokens")
                        detailCell("Response", "Strict JSON schema")
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
                                if profile.kind == .openAI {
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

                Text("Remote profiles are stored without credentials. API keys stay in the macOS Keychain under the profile's random identifier. Local profiles are limited to loopback addresses.")
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
                Label("Passed \(receipt.completedAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Test expired", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        case let .failed(id, message) where id == profile.id:
            Label(message, systemImage: "exclamationmark.triangle.fill")
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
        if APIKeyStorage.hasProviderCredential(profileID: profile.id) {
            return "Stored in Keychain"
        }
        return profile.kind == .openAI ? "Missing" : "None"
    }

}

private struct ProviderEditorState: Identifiable {
    let id = UUID()
    let profile: ProviderProfile

    static func newProfile() -> ProviderEditorState {
        ProviderEditorState(profile: ProviderProfile(
            name: "",
            kind: .localOpenAICompatible,
            baseURL: "http://127.0.0.1:8000/v1",
            model: ""
        ))
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

                Picker("Type", selection: $profile.kind) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: profile.kind) { _, kind in
                    profile.baseURL = kind.fixedBaseURL?.absoluteString ?? "http://127.0.0.1:8000/v1"
                }

                if profile.kind == .openAI {
                    LabeledContent("Endpoint", value: ProviderKind.openAI.fixedBaseURL?.absoluteString ?? "")
                } else {
                    TextField("Endpoint", text: $profile.baseURL, prompt: Text("http://127.0.0.1:8000/v1"))
                }

                TextField("Model", text: $profile.model)
                SecureField(
                    profile.kind == .openAI ? "API key" : "Bearer token (optional)",
                    text: $credential
                )

                LabeledContent("Response", value: "Strict JSON schema · 128 tokens")

                Text("FoodMapper controls the messages, output schema, streaming mode, token limit, and credentials for automatic decisions.")
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
        .frame(width: 600, height: 590)
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
