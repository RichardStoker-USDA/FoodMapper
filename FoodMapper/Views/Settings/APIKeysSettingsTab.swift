import SwiftUI

/// API key management for Anthropic services.
/// Visible in both Simple and Advanced modes.
struct APIKeysSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var apiKeyInput = ""
    @State private var apiKeyStatus: APIKeyStatus = .unknown
    @State private var isValidating = false
    @State private var showAPIKey = false

    enum APIKeyStatus {
        case unknown, valid, invalid(String), saving
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                apiKeyCard
                gettingAKeyCard
            }
            .padding(Spacing.lg)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if appState.cachedHasAPIKey {
                apiKeyStatus = .valid
            }
        }
    }

    private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Anthropic")
                    .technicalLabel()
                Spacer()
                apiKeyStatusBadge
            }

            Text("Stored locally on your Mac. Only sent to Anthropic when verifying matches.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .opacity(0.55)

            if appState.cachedHasAPIKey && apiKeyInput.isEmpty {
                storedKeyRow
            } else {
                entryRow
            }
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var gettingAKeyCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Getting a Key")
                .technicalLabel()

            Text("To use hybrid matching, you need an Anthropic API key.")
                .font(.callout)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                guideRow(index: 1, text: "Create an account at console.anthropic.com")
                guideRow(index: 2, text: "Generate an API key in your dashboard")
                guideRow(index: 3, text: "Paste it above and click Save")
            }

            Link(destination: URL(string: "https://console.anthropic.com")!) {
                HStack(spacing: Spacing.xs) {
                    Text("Open Anthropic Console")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    // MARK: - Stored Key Display

    @ViewBuilder
    private var storedKeyRow: some View {
        HStack(spacing: Spacing.sm) {
            Group {
                if showAPIKey, let key = APIKeyStorage.getAnthropicAPIKey() {
                    Text(key)
                        .foregroundStyle(.primary)
                } else {
                    Text(maskedKeyDisplay)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
            )

            Button {
                showAPIKey.toggle()
            } label: {
                Image(systemName: showAPIKey ? "eye.slash" : "eye")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(showAPIKey ? "Hide API key" : "Show API key")

            Button("Change") {
                apiKeyInput = " "
                apiKeyInput = ""
                showAPIKey = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                APIKeyStorage.deleteAnthropicAPIKey()
                apiKeyInput = ""
                apiKeyStatus = .unknown
                showAPIKey = false
                appState.refreshAPIKeyState()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Remove stored API key")
        }
    }

    private var maskedKeyDisplay: String {
        guard let key = APIKeyStorage.getAnthropicAPIKey(), key.count > 8 else {
            return String(repeating: "\u{2022}", count: 20)
        }
        let prefix = String(key.prefix(7))
        let dots = String(repeating: "\u{2022}", count: 16)
        let suffix = String(key.suffix(4))
        return "\(prefix)\(dots)\(suffix)"
    }

    // MARK: - Entry Field

    @ViewBuilder
    private var entryRow: some View {
        HStack(spacing: Spacing.sm) {
            SecureField("sk-ant-...", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)

            Button("Save") {
                saveAndValidateAPIKey()
            }
            .disabled(apiKeyInput.isEmpty || isValidating)
            .buttonStyle(.bordered)
            .controlSize(.small)

            if appState.cachedHasAPIKey {
                Button("Cancel") {
                    apiKeyInput = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var apiKeyStatusBadge: some View {
        switch apiKeyStatus {
        case .unknown:
            if appState.cachedHasAPIKey {
                statusBadge("Stored", systemImage: "checkmark.circle", color: .green)
            } else {
                statusBadge("Not set", systemImage: "minus.circle", color: .secondary)
            }
        case .valid:
            statusBadge("Valid", systemImage: "checkmark.circle", color: .green)
        case .invalid(let reason):
            statusBadge(reason, systemImage: "xmark.circle", color: .red)
                .lineLimit(1)
                .truncationMode(.tail)
        case .saving:
            HStack(spacing: Spacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Validating")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusBadge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(colorScheme == .dark ? 0.22 : 0.14))
            )
    }

    private func guideRow(index: Int, text: String) -> some View {
        Label {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Text("\(index).")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
        }
    }

    // MARK: - Save & Validate

    private func saveAndValidateAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isValidating = true
        apiKeyStatus = .saving

        Task {
            APIKeyStorage.setAnthropicAPIKey(key)
            appState.refreshAPIKeyState()

            do {
                let client = AnthropicAPIClient()
                let isValid = try await client.validateAPIKey(key)

                await MainActor.run {
                    isValidating = false
                    if isValid {
                        apiKeyStatus = .valid
                        apiKeyInput = ""
                    } else {
                        apiKeyStatus = .invalid("Invalid key")
                        APIKeyStorage.deleteAnthropicAPIKey()
                        appState.refreshAPIKeyState()
                    }
                }
            } catch {
                await MainActor.run {
                    isValidating = false
                    apiKeyStatus = .invalid("Validation failed")
                }
            }
        }
    }
}

#Preview("API Keys - No Key") {
    APIKeysSettingsTab()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 520, height: 420)
        .preferredColorScheme(.light)
}

#Preview("API Keys - Dark") {
    APIKeysSettingsTab()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 520, height: 420)
        .preferredColorScheme(.dark)
}
