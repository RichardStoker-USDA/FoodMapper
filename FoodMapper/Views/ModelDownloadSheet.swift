import SwiftUI

struct ModelInstallRequest: Identifiable {
    let id = UUID()
    let models: [RegisteredModel]
}

/// Reviews and installs the exact model snapshots needed by an optional workflow.
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

    private var installableModels: [RegisteredModel] {
        models.filter(\.isInstallable)
    }

    private var totalDownloadSize: Int64 {
        installableModels
            .filter { !modelManager.state(for: $0.key).isAvailable }
            .compactMap(\.downloadSize)
            .reduce(0, +)
    }

    private var allDownloaded: Bool {
        !models.isEmpty && models.allSatisfy { modelManager.state(for: $0.key).isAvailable }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    modelList

                    if let downloadError {
                        Label(downloadError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Install error: \(downloadError)")
                    }

                    Text(storageNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Spacing.xl)
            }

            Divider()
            actionBar
        }
        .frame(width: 640, height: min(620, 250 + CGFloat(models.count) * 104))
        .onDisappear {
            cancelDownloads()
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(allDownloaded ? "Models Installed" : "Review Model Installation")
                    .font(.title3.weight(.semibold))

                Text(allDownloaded
                     ? "The selected models passed their local file checks."
                     : "FoodMapper will download the pinned files listed below and verify them before use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.md)

            if !allDownloaded, totalDownloadSize > 0 {
                VStack(alignment: .trailing, spacing: Spacing.xxxs) {
                    Text("DOWNLOAD")
                        .technicalLabel()
                    Text(formatBytes(totalDownloadSize))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
            }
        }
        .padding(Spacing.xl)
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                modelRow(model)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.md)

                if index < models.count - 1 {
                    Divider()
                        .padding(.leading, Spacing.md)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
        }
    }

    private func modelRow(_ model: RegisteredModel) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            modelStateSymbol(model)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.displayName)
                        .font(.headline)
                    Spacer()
                    Text(model.admission.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.xxs) {
                    GridRow {
                        metadata("Publisher", model.publisher)
                        metadata("Use", model.purpose.rawValue)
                    }
                    GridRow {
                        metadata("License", model.licenseName)
                        metadata("Files", model.downloadSize.map(formatBytes) ?? "Bundled")
                    }
                    if let revision = model.revision {
                        GridRow {
                            metadata("Revision", String(revision.prefix(12)))
                                .gridCellColumns(2)
                        }
                    }
                }

                if case let .downloading(progress) = modelManager.state(for: model.key) {
                    HStack(spacing: Spacing.sm) {
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                        Text(progress >= 0.995 ? "Verifying" : progress.formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 58, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func metadata(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func modelStateSymbol(_ model: RegisteredModel) -> some View {
        switch modelManager.state(for: model.key) {
        case .downloaded, .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading, .loading:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .notDownloaded:
            if model.admission == .inventory {
                Image(systemName: "lock.circle")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.md) {
            if isDownloading || isCancelling {
                Text(isCancelling ? "Stopping installation..." : "Keep FoodMapper open while the files are checked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isDownloading || isCancelling {
                Button("Cancel Install") {
                    cancelDownloads()
                }
                .disabled(isCancelling)
            } else if !allDownloaded {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }

            if allDownloaded {
                Button("Done") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Install Models") {
                    downloadAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloading || isCancelling || installableModels.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.lg)
    }

    private var storageNote: String {
        if allDownloaded {
            return "The verified files are ready in FoodMapper's application-support folder. The published matching method is unchanged."
        }
        if isDownloading || isCancelling {
            return "FoodMapper stores verified model files in its application-support folder. The published matching method remains unchanged."
        }
        return "Models are stored in FoodMapper's application-support folder. No download starts until you select Install Models."
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

            for model in installableModels {
                guard !Task.isCancelled else { return }
                guard !modelManager.state(for: model.key).isAvailable else { continue }
                do {
                    try await modelManager.downloadModel(key: model.key)
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        downloadError = "\(model.displayName): \(error.localizedDescription)"
                    }
                    return
                }
            }
        }
    }

    private func cancelDownloads() {
        guard !isCancelling else { return }
        guard isDownloading || installableModels.contains(where: {
            modelManager.retryState(for: $0.key) == .cancelling
        }) else { return }

        isCancelling = true
        downloadTask?.cancel()
        for model in installableModels {
            modelManager.cancelDownload(key: model.key)
        }

        cancellationTask = Task {
            for model in installableModels {
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
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview("Model Installation") {
    ModelDownloadSheet(
        models: [
            RegisteredModel(
                key: "nomic-embed-text-v1.5",
                displayName: "Nomic Embed Text v1.5",
                modelFamily: .nomicEmbedding,
                sizeCategory: .compact,
                repoId: NomicEmbeddingModel.repository,
                revision: NomicEmbeddingModel.revision,
                downloadSize: 547_886_235,
                publisher: "Nomic AI",
                licenseName: "Apache 2.0",
                purpose: .embedding,
                admission: .evaluation
            )
        ],
        modelManager: ModelManager(hardwareConfig: .detect()),
        onComplete: {},
        onCancel: {}
    )
}
