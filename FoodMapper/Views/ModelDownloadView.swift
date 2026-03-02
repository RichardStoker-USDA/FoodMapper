import SwiftUI

/// First-launch view shown when the GTE-Large model needs to be downloaded
struct ModelDownloadView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            Spacer()

            // App icon and welcome
            VStack(spacing: Spacing.md) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                }

                Text("Welcome to FoodMapper")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("FoodMapper needs to download a semantic matching model to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            // Action area
            VStack(spacing: Spacing.md) {
                if case .downloading(let progress) = appState.modelStatus {
                    VStack(spacing: Spacing.sm) {
                        ProgressView(value: progress)
                            .frame(width: 280)

                        HStack {
                            Text("Downloading GTE-Large...")
                                .font(.callout)
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.system(.callout, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 280)
                    }
                } else if case .error(let message) = appState.modelStatus {
                    VStack(spacing: Spacing.sm) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)

                        Button("Retry") {
                            Task { await appState.downloadModel() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if case .loading = appState.modelStatus {
                    VStack(spacing: Spacing.sm) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading model...")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Model info row
                    HStack(spacing: Spacing.lg) {
                        Label("GTE-Large", systemImage: "cpu")
                            .font(.callout)
                        Text("~640 MB")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        if #available(macOS 26, *) {
                            Button("Download Model") {
                                Task { await appState.downloadModel() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        } else {
                            Button {
                                Task { await appState.downloadModel() }
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                                    Text("Download Model")
                                        .fontWeight(.semibold)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(Color(nsColor: .controlAccentColor))
                        }
                    }
                    Text("About 2 minutes on a fast connection")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .tutorialAnchor("modelDownloadArea")

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xxl)
    }
}

#Preview("Model Download - Light") {
    ModelDownloadView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 700, height: 550)
}

#Preview("Model Download - Dark") {
    ModelDownloadView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 700, height: 550)
        .preferredColorScheme(.dark)
}
