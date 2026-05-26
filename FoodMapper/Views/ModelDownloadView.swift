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
                    VStack(spacing: Spacing.md) {
                        // Progress bar with rounded, premium native style
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(Color.accentColor)
                            .frame(width: 320)
                            .scaleEffect(x: 1, y: 1.2, anchor: .center) // Slight weight for visual premium feel
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)

                        // Real-time metadata grid
                        VStack(spacing: Spacing.xs) {
                            HStack {
                                Text("Downloading GTE-Large...")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(Int(progress * 100))%")
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                            
                            // Speed and Time remaining
                            HStack {
                                Label(formatDownloadSpeed(appState.downloadSpeedBytesPerSecond), systemImage: "arrow.down.circle")
                                Spacer()
                                Label(formatTimeRemaining(appState.downloadTimeRemaining), systemImage: "clock")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            
                            HStack {
                                Text("\(formatBytes(appState.downloadBytesWritten)) of \(formatBytes(appState.downloadBytesTotal))")
                                    .font(.caption.monospacedDigit())
                                Spacer()
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                        .frame(width: 320)
                        
                        // Cancel button for high-end control
                        Button(action: {
                            appState.cancelDownload()
                        }) {
                            Text("Cancel Download")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.top, Spacing.xs)
                    }
                    .padding(Spacing.lg)
                    .background(Color.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                } else if case .error(let message) = appState.modelStatus {
                    VStack(spacing: Spacing.sm) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.experimentalAmber)
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
                        Text("Verifying and loading GTE-Large...")
                            .font(.callout.weight(.medium))
                        Text("This happens once to compile Metal GPU kernels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 320)
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

    // MARK: - Premium UI Formatters

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDownloadSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond <= 0 { return "Connecting..." }
        let kb = bytesPerSecond / 1024
        if kb < 1024 {
            return String(format: "%.0f KB/s", kb)
        } else {
            let mb = kb / 1024
            return String(format: "%.1f MB/s", mb)
        }
    }

    private func formatTimeRemaining(_ seconds: Double?) -> String {
        guard let seconds = seconds else { return "Calculating..." }
        let rounded = Int(seconds)
        if rounded < 60 {
            return "\(rounded)s remaining"
        } else {
            let mins = rounded / 60
            let secs = rounded % 60
            return "\(mins)m \(secs)s remaining"
        }
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
