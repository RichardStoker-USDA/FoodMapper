import SwiftUI
import Sparkle

/// General settings: appearance, display, and update options
struct GeneralSettingsTab: View {
    let updater: SPUUpdater
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("pageSize") private var pageSize = 200

    private var automaticallyChecksForUpdates: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private var automaticallyDownloadsUpdates: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.automaticallyDownloadsUpdates = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                appearanceCard
                displayCard
                updatesCard
            }
            .padding(Spacing.lg)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Appearance")
                .technicalLabel()

            Text("Override your Mac's appearance for FoodMapper only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Theme", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Display")
                .technicalLabel()

            HStack(alignment: .center, spacing: Spacing.md) {
                Text("Results per page")
                    .font(.callout.weight(.medium))

                Spacer(minLength: Spacing.sm)

                Picker("Results per page", selection: $pageSize) {
                    Text("200").tag(200)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                    Text("2000").tag(2000)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            Text("Lower values keep sorting and paging responsive with large result sets.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private var updatesCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Updates")
                .technicalLabel()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Toggle("Automatically check for updates", isOn: automaticallyChecksForUpdates)
                Toggle("Automatically download updates", isOn: automaticallyDownloadsUpdates)
            }

            Text("FoodMapper checks for updates from foodmapper.app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }
}

#Preview("General - Light") {
    GeneralSettingsTab(updater: SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    ).updater)
    .frame(width: 520, height: 480)
    .preferredColorScheme(.light)
}

#Preview("General - Dark") {
    GeneralSettingsTab(updater: SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    ).updater)
    .frame(width: 520, height: 480)
    .preferredColorScheme(.dark)
}
