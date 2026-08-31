import SwiftUI
import Sparkle

extension Notification.Name {
    static let showModelSettings = Notification.Name("showModelSettings")
}

/// Settings window content with tab-based navigation.
/// Always shows 4 tabs: General, Models, API Keys, Advanced.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    let updater: SPUUpdater
    @Binding var appearance: String

    enum SettingsTab: Hashable {
        case general, models, apiKeys, advanced
    }

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(updater: updater, appearance: $appearance)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            ModelsSettingsTab()
                .tabItem { Label("Models", systemImage: "square.and.arrow.down") }
                .tag(SettingsTab.models)

            APIKeysSettingsTab()
                .tabItem { Label("API Keys", systemImage: "key") }
                .tag(SettingsTab.apiKeys)

            AdvancedSettingsTab(
                hardwareConfig: appState.hardwareConfig,
                advancedSettings: Binding(
                    get: { appState.advancedSettings },
                    set: { appState.updateAdvancedSettings($0) }
                ),
                onResetAllData: { appState.resetAllData() }
            )
            .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            .tag(SettingsTab.advanced)
        }
        .frame(width: 505, height: 485)
        .onReceive(NotificationCenter.default.publisher(for: .showModelSettings)) { _ in
            selectedTab = .models
        }
    }
}

#Preview("Settings - Simple Mode") {
    SettingsView(updater: SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    ).updater, appearance: .constant("system"))
    .environmentObject(PreviewHelpers.emptyState())
}

#Preview("Settings - Advanced Mode") {
    SettingsView(updater: SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    ).updater, appearance: .constant("system"))
    .environmentObject(PreviewHelpers.emptyAdvancedState())
}

#Preview("Settings - Dark") {
    SettingsView(updater: SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    ).updater, appearance: .constant("dark"))
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}
