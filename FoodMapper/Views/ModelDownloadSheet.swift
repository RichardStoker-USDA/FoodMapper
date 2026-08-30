import SwiftUI

/// Sheet shown when a user selects a pipeline that requires models not yet downloaded.
/// Presents the missing models with sizes and a single action to download all.
struct ModelDownloadSheet: View {
    let models: [RegisteredModel]
    @ObservedObject var modelManager: ModelManager
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var isDownloading = false
    @State private var isCancelling = false
    @State private var downloadError: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var cancellationTask: Task<Void, Never>?
    @State private var completedKeys: Set<String> = []

    private var totalDownloadSize: Int64 {
        models.compactMap(\.downloadSize).reduce(0, +)
    }

    private var allDownloaded: Bool {
        models.allSatisfy { modelManager.state(for: $0.key).isAvailable }
    }

    var body: some View {
        VStack(spacing: Spacing.xl) {
            // Header
            VStack(spacing: Spacing.md) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Models Required")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("This pipeline needs models that haven't been downloaded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Model list
            VStack(spacing: Spacing.xs) {
                ForEach(models) { model in
                    HStack {
                        Text(model.displayName)
                            .fontWeight(.medium)

                        Spacer()

                        if let size = model.downloadSize {
                            Text(formatBytes(size))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        modelStatusIcon(for: model.key)
                    }
                    .padding(.vertical, Spacing.xs)
                    .padding(.horizontal, Spacing.md)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .padding(.horizontal, Spacing.lg)

            // Total size
            Text("Total download: \(formatBytes(totalDownloadSize))")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Error
            if let error = downloadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.experimentalAmber)
            }

            // Actions
            HStack(spacing: Spacing.md) {
                Button("Cancel") {
                    cancelDownloads()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                if allDownloaded {
                    Button("Continue") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(isCancelling ? "Finishing cancellation..." : (isDownloading ? "Downloading..." : "Download & Match")) {
                        downloadAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading || isCancelling)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420)
        .onAppear {
            // If models finished downloading between sheet creation and display
            if allDownloaded {
                onComplete()
            }
        }
        .onDisappear {
            cancelDownloads()
        }
    }

    @ViewBuilder
    private func modelStatusIcon(for key: String) -> some View {
        let state = modelManager.state(for: key)
        switch state {
        case .downloaded, .loaded:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case .downloading(let progress):
            HStack(spacing: Spacing.xxs) {
                ProgressView(value: progress)
                    .frame(width: 40)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .notDownloaded:
            if modelManager.retryState(for: key) == .cancelling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func downloadAll() {
        guard downloadTask == nil, cancellationTask == nil else { return }
        isDownloading = true
        downloadError = nil

        downloadTask = Task {
            defer {
                Task { @MainActor in
                    downloadTask = nil
                    if !isCancelling {
                        isDownloading = false
                    }
                }
            }
            for model in models {
                guard !Task.isCancelled else { return }
                guard !modelManager.state(for: model.key).isAvailable else { continue }
                do {
                    try await modelManager.downloadModel(key: model.key)
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        downloadError = "Failed to download \(model.displayName): \(error.localizedDescription)"
                    }
                    return
                }
            }

            await MainActor.run {
                if !Task.isCancelled, allDownloaded {
                    onComplete()
                }
            }
        }
    }

    private func cancelDownloads() {
        guard !isCancelling else { return }
        guard isDownloading || models.contains(where: { modelManager.retryState(for: $0.key) == .cancelling }) else { return }
        isCancelling = true
        for model in models {
            modelManager.cancelDownload(key: model.key)
        }
        downloadTask?.cancel()
        cancellationTask = Task {
            for model in models {
                await modelManager.cancelDownloadAndWait(key: model.key)
            }
            await MainActor.run {
                downloadTask = nil
                cancellationTask = nil
                isDownloading = false
                isCancelling = false
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else {
            return String(format: "%d MB", bytes / 1_000_000)
        }
    }
}

#Preview("Download Sheet - Two Models") {
    ModelDownloadSheet(
        models: [
            RegisteredModel(
                key: "qwen3-emb-4b-4bit",
                displayName: "Qwen3-Embedding 4B",
                modelFamily: .qwen3Embedding,
                sizeCategory: .medium,
                repoId: "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
                downloadSize: 2_280_000_000,
                gpuMemoryUsage: 2_500_000_000,
                minimumProfile: .base
            ),
            RegisteredModel(
                key: "qwen3-reranker-0.6b",
                displayName: "Qwen3-Reranker 0.6B",
                modelFamily: .qwen3Reranker,
                sizeCategory: .small,
                repoId: "richtext/Qwen3-Reranker-0.6B-mlx-fp16",
                downloadSize: 1_200_000_000,
                gpuMemoryUsage: 1_200_000_000,
                minimumProfile: .base
            ),
        ],
        modelManager: ModelManager(hardwareConfig: .detect()),
        onComplete: {},
        onCancel: {}
    )
}

#Preview("Download Sheet - Dark") {
    ModelDownloadSheet(
        models: [
            RegisteredModel(
                key: "qwen3-emb-4b-4bit",
                displayName: "Qwen3-Embedding 4B",
                modelFamily: .qwen3Embedding,
                sizeCategory: .medium,
                repoId: "mlx-community/Qwen3-Embedding-4B-4bit-DWQ",
                downloadSize: 2_280_000_000,
                gpuMemoryUsage: 2_500_000_000,
                minimumProfile: .base
            ),
        ],
        modelManager: ModelManager(hardwareConfig: .detect()),
        onComplete: {},
        onCancel: {}
    )
    .preferredColorScheme(.dark)
}
