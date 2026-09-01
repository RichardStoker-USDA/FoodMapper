import SwiftUI

/// Advanced settings: advanced mode toggle, hardware info, API tier, performance tuning, database limits, developer tools, reset.
struct AdvancedSettingsTab: View {
    let hardwareConfig: HardwareConfig
    @Binding var advancedSettings: AdvancedSettings
    let onResetAllData: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var showingAdvancedConfirmation = false
    @State private var showingResetConfirmation = false
    @State private var showingFinalConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                advancedModeCard
                systemCard
                apiCard
                databaseLimitsCard
                if appState.isAdvancedMode {
                    autoMatchCard
                }
                developerCard
                resetCard
            }
            .padding(Spacing.lg)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Enable Advanced Options?", isPresented: $showingAdvancedConfirmation) {
            Button("Enable") {
                appState.isAdvancedMode = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Advanced options are evaluation features. Keep the published GTE-Large result and review any comparison before research use.")
        }
        .alert("Reset FoodMapper?", isPresented: $showingResetConfirmation) {
            Button("Continue", role: .destructive) {
                showingFinalConfirmation = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently remove:\n\n- Downloaded models\n- Saved sessions, benchmark records, and review decisions\n- Custom databases and cached embeddings\n- Stored input files and FoodMapper preferences\n- Provider profiles and their Keychain credentials\n\nYour Anthropic API key stays in your Mac's Keychain. Export any results you want to keep before continuing.")
        }
        .alert("Are you sure?", isPresented: $showingFinalConfirmation) {
            Button("Reset and Restart", role: .destructive) {
                onResetAllData()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone. FoodMapper will restart with its Application Support data and preferences cleared. Your Anthropic API key stays in Keychain.")
        }
    }

    private var advancedModeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Advanced Mode")
                    .technicalLabel()
                Spacer()
                if appState.isAdvancedMode {
                    experimentalPill
                }
            }

            Toggle(isOn: Binding(
                get: { appState.isAdvancedMode },
                set: { newValue in
                    if newValue {
                        showingAdvancedConfirmation = true
                    } else {
                        appState.isAdvancedMode = false
                    }
                }
            )) {
                Text("Show advanced options (Beta)")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Text("Shows evaluation runs, benchmarks, provider profiles, optional models, and related help. Turning it off cancels experimental work and returns pipeline selection to GTE-Large.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("System")
                .technicalLabel()

            infoRow("Device", hardwareConfig.shortDeviceName)
            infoRow("Memory", "\(hardwareConfig.displayMemoryGB) GB")
            infoRow("Profile", hardwareConfig.profile.displayName)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var apiCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("API")
                .technicalLabel()

            HStack(alignment: .center, spacing: Spacing.md) {
                Text("Anthropic API Tier")
                    .font(.callout.weight(.medium))
                Spacer(minLength: Spacing.sm)

                Picker("", selection: Binding(
                    get: { advancedSettings.apiTierOverride ?? 0 },
                    set: {
                        advancedSettings.apiTierOverride = $0 == 0 ? nil : $0
                    }
                )) {
                    Text("Auto-detect").tag(0)
                    Text("Tier 1").tag(1)
                    Text("Tier 2").tag(2)
                    Text("Tier 3").tag(3)
                    Text("Tier 4").tag(4)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            if appState.detectedAPITier != .unknown {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text("Detected: \(appState.detectedAPITier.displayName)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Text("Controls concurrent API requests for the Haiku pipeline. Auto-detect reads rate-limit headers from the first API response.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var databaseLimitsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Database Limits")
                .technicalLabel()

            Toggle("Allow large databases", isOn: $advancedSettings.allowLargeDatabases)
                .toggleStyle(.switch)
                .controlSize(.small)

            infoRow("Recommended max", formatNumber(hardwareConfig.recommendedMaxDatabaseItems))
            infoRow("Warning threshold", formatNumber(hardwareConfig.absoluteMaxDatabaseItems))

            Text("When enabled, databases of any size can be added. Without this, databases above the warning threshold cannot be added.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var autoMatchCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Smart Auto-Match")
                .technicalLabel()

            Text("Automatically confirm embedding results with high scores and a clear gap to the next candidate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Score floor")
                    .font(.callout)
                Spacer()
                Text("\(Int(appState.autoMatchScoreFloor * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: Binding(
                get: { appState.autoMatchScoreFloor },
                set: { appState.autoMatchScoreFloor = $0 }
            ), in: 0.90...1.0, step: 0.01)

            HStack {
                Text("Minimum gap to next candidate")
                    .font(.callout)
                Spacer()
                Text("\(Int(appState.autoMatchMinGap * 100))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: Binding(
                get: { appState.autoMatchMinGap },
                set: { appState.autoMatchMinGap = $0 }
            ), in: 0.01...0.10, step: 0.01)

            Text("Results scoring above the floor with a gap exceeding the minimum are marked as Match instead of Needs Review. Currently tuned for GTE-Large cosine similarity scores.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var developerCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Developer")
                .technicalLabel()

            Toggle("Show debug info in status bar", isOn: $advancedSettings.showDebugInfo)
                .toggleStyle(.switch)
                .controlSize(.small)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Toggle("Log performance metrics", isOn: $advancedSettings.logPerformanceMetrics)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("Outputs timing data to Console.app for debugging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var resetCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Reset")
                .technicalLabel()

            Text("Removes FoodMapper Application Support data and preferences, then restarts the app. The Anthropic API key in Keychain stays in place.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                showingResetConfirmation = true
            } label: {
                Label("Reset FoodMapper", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.80, green: 0.15, blue: 0.15))
            .controlSize(.regular)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var experimentalPill: some View {
        Text("Experimental")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .tracking(0.1)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(Capsule(style: .continuous).fill(Color.experimentalAmber.opacity(0.85)))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: Spacing.md) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: Spacing.sm)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

#Preview("Advanced - Light") {
    AdvancedSettingsTab(
        hardwareConfig: .detect(),
        advancedSettings: .constant(.default),
        onResetAllData: {}
    )
    .environmentObject(PreviewHelpers.emptyAdvancedState())
    .frame(width: 520, height: 700)
    .preferredColorScheme(.light)
}

#Preview("Advanced - Dark") {
    AdvancedSettingsTab(
        hardwareConfig: .detect(),
        advancedSettings: .constant(.default),
        onResetAllData: {}
    )
    .environmentObject(PreviewHelpers.emptyAdvancedState())
    .frame(width: 520, height: 700)
    .preferredColorScheme(.dark)
}
