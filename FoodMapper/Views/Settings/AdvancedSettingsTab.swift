import SwiftUI

/// Advanced settings: advanced mode toggle, hardware info, API tier, performance tuning, database limits, developer tools, reset.
struct AdvancedSettingsTab: View {
    let hardwareConfig: HardwareConfig
    @Binding var advancedSettings: AdvancedSettings
    let onResetAllData: () -> Void

    @Environment(\.colorScheme) private var colorScheme
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
            Text("Advanced options are experimental features under active development. They may produce unexpected results.")
        }
        .alert("Reset FoodMapper?", isPresented: $showingResetConfirmation) {
            Button("Continue", role: .destructive) {
                showingFinalConfirmation = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete:\n\n- Downloaded embedding model (~640 MB)\n- All match history and saved sessions\n- Custom databases and cached embeddings\n- All preferences and settings\n\nExport any results you want to keep before continuing.")
        }
        .alert("Are you sure?", isPresented: $showingFinalConfirmation) {
            Button("Reset and Restart", role: .destructive) {
                onResetAllData()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone. FoodMapper will restart as if it were a fresh install.")
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

            Text("Enables additional models, pipeline configurations, and performance details. These features are under active development and may produce unexpected results.")
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

            infoRow("Device", hardwareConfig.deviceName)
            infoRow("Memory", "\(hardwareConfig.detectedMemoryGB) GB")
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

            Button {
                showingResetConfirmation = true
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Reset FoodMapper")
                        .font(.callout.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(destructiveTint)
            .controlSize(.regular)

            Text("Removes all data and restores FoodMapper to its original state. The app will restart automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var destructiveTint: Color {
        // >= 4.5:1 contrast against white label text in both appearances.
        if colorScheme == .dark {
            return Color(red: 0.78, green: 0.16, blue: 0.16) // C62828
        }
        return Color(red: 0.85, green: 0.18, blue: 0.13) // D92D20
    }

    private var experimentalPill: some View {
        let isDark = colorScheme == .dark
        let textColor: Color = isDark ? .white.opacity(0.86) : .primary.opacity(0.68)
        let fillColor: Color = isDark ? .white.opacity(0.08) : .black.opacity(0.045)
        let borderColor: Color = isDark ? .white.opacity(0.18) : .black.opacity(0.12)

        return Text("Experimental")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .tracking(0.1)
            .foregroundStyle(textColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(fillColor))
            .overlay(Capsule(style: .continuous).strokeBorder(borderColor, lineWidth: 0.66))
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
