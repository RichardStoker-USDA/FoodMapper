import SwiftUI

/// Model management tab. Content adapts based on Simple/Advanced mode.
/// Simple mode: focuses on the primary matching model.
/// Advanced mode: exposes all model families with storage and per-model actions.
struct ModelsSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]
    @State private var cancellingModels: Set<String> = []

    private var allModels: [RegisteredModel] {
        appState.modelManager.registeredModels
    }

    private var embeddingModels: [RegisteredModel] {
        allModels.filter { $0.modelFamily == .gteLarge || $0.modelFamily == .qwen3Embedding }
    }

    private var rerankerModels: [RegisteredModel] {
        allModels.filter { $0.modelFamily == .qwen3Reranker }
    }

    private var generativeModels: [RegisteredModel] {
        allModels.filter { $0.modelFamily == .qwen3Generative }
    }

    private var gteModel: RegisteredModel? {
        allModels.first { $0.key == "gte-large" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if appState.isAdvancedMode {
                    ModelStorageCard(models: allModels, modelManager: appState.modelManager)

                    modelSectionCard(
                        title: "Embedding Models",
                        subtitle: "Used to encode text similarity.",
                        models: embeddingModels,
                        showBetaBadge: true
                    )

                    modelSectionCard(
                        title: "Reranker Models",
                        subtitle: "Used to refine candidate ordering.",
                        models: rerankerModels,
                        showBetaBadge: true
                    )

                    modelSectionCard(
                        title: "Generative Models",
                        subtitle: "Used for LLM-based judging pipelines.",
                        models: generativeModels,
                        showBetaBadge: true
                    )
                } else if let gteModel {
                    modelSectionCard(
                        title: "Matching Model",
                        subtitle: "Standard mode uses this model for semantic matching.",
                        models: [gteModel],
                        showBetaBadge: false
                    )

                    ModelStorageCard(models: [gteModel], modelManager: appState.modelManager)
                }
            }
            .padding(Spacing.lg)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func modelSectionCard(
        title: String,
        subtitle: String,
        models: [RegisteredModel],
        showBetaBadge: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .technicalLabel()

                Spacer()

                let readyCount = models.filter { appState.modelManager.state(for: $0.key).isAvailable }.count
                Text("\(readyCount)/\(models.count) ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .opacity(0.6)

            VStack(spacing: 0) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    ModelRow(
                        model: model,
                        modelManager: appState.modelManager,
                        showExperimentalBadge: showBetaBadge && model.modelFamily != .gteLarge,
                        isCancelling: cancellingModels.contains(model.key),
                        onDownload: { downloadModel(model) },
                        onCancel: { cancelDownload(model) },
                        onDelete: { deleteModel(model) }
                    )

                    if index < models.count - 1 {
                        Divider()
                            .opacity(0.35)
                            .padding(.leading, 44)
                    }
                }
            }
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private func downloadModel(_ model: RegisteredModel) {
        let key = model.key
        guard downloadTasks[key] == nil else { return }
        cancellingModels.remove(key)

        let task = Task {
            defer {
                Task { @MainActor in
                    downloadTasks.removeValue(forKey: key)
                    cancellingModels.remove(key)
                }
            }

            do {
                try await appState.modelManager.downloadModel(key: key)
            } catch {
                // Model state is already handled by ModelManager.
            }

            if key == "gte-large" {
                await MainActor.run {
                    appState.syncModelStatus()
                }
            }
        }

        downloadTasks[key] = task
    }

    private func cancelDownload(_ model: RegisteredModel) {
        let key = model.key
        cancellingModels.insert(key)
        appState.modelManager.cancelDownload(key: key)
        downloadTasks[key]?.cancel()
    }

    private func deleteModel(_ model: RegisteredModel) {
        guard downloadTasks[model.key] == nil else { return }

        Task {
            try? await appState.modelManager.deleteModel(key: model.key)
            if model.key == "gte-large" {
                appState.syncModelStatus()
            }
        }
    }
}

// MARK: - Model Row

struct ModelRow: View {
    let model: RegisteredModel
    @ObservedObject var modelManager: ModelManager
    @Environment(\.colorScheme) private var colorScheme
    let showExperimentalBadge: Bool
    let isCancelling: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    private var state: ModelState {
        modelManager.state(for: model.key)
    }

    private var stateLabel: String? {
        switch state {
        case .loaded: return "Active"
        case .loading: return "Loading"
        case .downloading: return "Downloading"
        case .error: return "Error"
        case .downloaded: return "Ready"
        case .notDownloaded: return nil
        }
    }

    private var stateColor: Color {
        switch state {
        case .loaded: return .green
        case .loading, .downloading: return .secondary
        case .error: return .red
        case .downloaded: return .secondary
        case .notDownloaded: return .clear
        }
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            leadingModelMarker

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                HStack(spacing: Spacing.xs) {
                    Text(model.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    Spacer(minLength: Spacing.xs)

                    HStack(spacing: Spacing.xs) {
                        if let stateLabel {
                            Text(stateLabel)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(stateColor)
                                .background(stateColor.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                HStack(spacing: Spacing.sm) {
                    if let size = model.downloadSize {
                        Text(formatBytes(size))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let disk = modelManager.diskUsage(for: model.key), disk > 0 {
                        Text("On disk: \(formatBytes(disk))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let gpu = model.gpuMemoryUsage {
                        Text("GPU: ~\(formatBytes(gpu))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            statusView
                .frame(minWidth: 118, alignment: .trailing)
                .animation(Animate.standard, value: state)
                .animation(Animate.quick, value: isCancelling)
        }
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private var leadingModelMarker: some View {
        if showExperimentalBadge {
            let isDark = colorScheme == .dark
            let textColor: Color = isDark ? .white.opacity(0.86) : .primary.opacity(0.68)
            let fillColor: Color = isDark ? .white.opacity(0.12) : .black.opacity(0.07)
            let borderColor: Color = isDark ? .white.opacity(0.16) : .black.opacity(0.12)

            Text("BETA")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundStyle(textColor)
                .background(Capsule(style: .continuous).fill(fillColor))
                .overlay(Capsule(style: .continuous).strokeBorder(borderColor, lineWidth: 0.66))
                .frame(width: 40, alignment: .center)
        } else {
            Color.clear
                .frame(width: 40, height: 18)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .notDownloaded:
            ModelActionButton(
                systemImage: "arrow.down",
                style: .primary,
                helpText: "Download model",
                action: onDownload
            )

        case .downloading(let progress):
            HStack(spacing: Spacing.xs) {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 72)

                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)

                if isCancelling {
                    HStack(spacing: Spacing.xxxs) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Cancelling")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ModelActionButton(
                        systemImage: "xmark",
                        style: .secondary,
                        helpText: "Cancel download",
                        action: onCancel
                    )
                }
            }

        case .downloaded:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 20, height: 20)

                ModelActionButton(
                    systemImage: "trash",
                    style: .destructive,
                    helpText: "Delete downloaded model",
                    action: onDelete
                )
            }

        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)

        case .loaded:
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 20, height: 20)

                ModelActionButton(
                    systemImage: "trash",
                    style: .destructive,
                    helpText: "Unload and delete model",
                    action: onDelete
                )
            }

        case .error(let message):
            HStack(spacing: Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.red)
                    .help(message)

                ModelActionButton(
                    systemImage: "arrow.clockwise",
                    style: .primary,
                    helpText: "Retry download",
                    action: onDownload
                )
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

private struct ModelActionButton: View {
    enum Style {
        case primary
        case secondary
        case destructive
    }

    let systemImage: String
    let style: Style
    let helpText: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(backgroundColor)
                )
                .overlay(
                    Circle()
                        .strokeBorder(strokeColor, lineWidth: 0.66)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(helpText)
    }

    private var iconColor: Color {
        switch style {
        case .primary:
            return isHovering ? Color.accentColor : .secondary
        case .secondary:
            return .secondary
        case .destructive:
            return isHovering ? .red : .secondary
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:
            return isHovering
                ? (colorScheme == .dark ? Color.accentColor.opacity(0.22) : Color.accentColor.opacity(0.12))
                : Color.clear
        case .secondary:
            return isHovering
                ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                : Color.clear
        case .destructive:
            return isHovering
                ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08))
                : Color.clear
        }
    }

    private var strokeColor: Color {
        switch style {
        case .primary where isHovering:
            return Color.accentColor.opacity(colorScheme == .dark ? 0.45 : 0.3)
        case .secondary where isHovering:
            return Color.primary.opacity(colorScheme == .dark ? 0.28 : 0.14)
        case .destructive where isHovering:
            return Color.red.opacity(colorScheme == .dark ? 0.55 : 0.32)
        default:
            return Color.clear
        }
    }
}

// MARK: - Storage Card

private struct ModelStorageCard: View {
    let models: [RegisteredModel]
    @ObservedObject var modelManager: ModelManager
    @Environment(\.colorScheme) private var colorScheme

    private struct ModelUsage: Identifiable {
        let id: String
        let name: String
        let bytes: Int64
        let color: Color
    }

    private var usages: [ModelUsage] {
        models.compactMap { model in
            guard modelManager.state(for: model.key).isAvailable else { return nil }
            let bytes = modelManager.diskUsage(for: model.key) ?? model.downloadSize ?? 0
            guard bytes > 0 else { return nil }
            return ModelUsage(
                id: model.key,
                name: model.displayName,
                bytes: bytes,
                color: ModelVisuals.color(for: model.key)
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private var totalBytes: Int64 {
        usages.reduce(0) { $0 + $1.bytes }
    }

    private var pathForegroundColor: Color {
        colorScheme == .dark
            ? Color.secondary
            : Color.primary.opacity(0.72)
    }

    private var pathBackgroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("Installed Models")
                        .technicalLabel()

                    Text("\(usages.count) installed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer(minLength: Spacing.md)

                VStack(alignment: .trailing, spacing: Spacing.xxxs) {
                    Text("Total footprint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(formatBytes(totalBytes))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: Spacing.xxs) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(pathForegroundColor)
                Text("~/Library/Application Support/FoodMapper/Models/")
                    .font(.caption)
                    .foregroundStyle(pathForegroundColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pathBackgroundColor)
            )

            if usages.isEmpty {
                Text("No models downloaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(usages) { usage in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(usage.color.opacity(0.75))
                                .frame(width: max(4, geo.size.width * CGFloat(usage.bytes) / CGFloat(totalBytes)))
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                )

                LazyVGrid(
                    columns: [GridItem(.flexible(minimum: 180)), GridItem(.flexible(minimum: 180))],
                    spacing: Spacing.xs
                ) {
                    ForEach(usages) { usage in
                        usageChip(usage)
                    }
                }
            }
        }
        .padding(Spacing.md)
        .settingsCardStyle(cornerRadius: 10)
    }

    private func usageChip(_ usage: ModelUsage) -> some View {
        HStack(spacing: Spacing.xs) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(usage.color.opacity(0.8))
                .frame(width: 8, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(usage.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: Spacing.xxxs) {
                    Text(formatBytes(usage.bytes))
                    Text("•")
                    Text(shareText(for: usage.bytes))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.5)
        )
    }

    private func shareText(for bytes: Int64) -> String {
        guard totalBytes > 0 else { return "0%" }
        return (Double(bytes) / Double(totalBytes)).formatted(.percent.precision(.fractionLength(0)))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else {
            return String(format: "%d MB", bytes / 1_000_000)
        }
    }
}

private enum ModelVisuals {
    static func color(for key: String) -> Color {
        switch key {
        case "gte-large": return Color.blue
        case "qwen3-emb-0.6b-4bit": return Color.teal
        case "qwen3-emb-4b-4bit": return Color.indigo
        case "qwen3-emb-8b-4bit": return Color.purple
        case "qwen3-reranker-0.6b": return Color.orange
        case "qwen3-reranker-4b": return Color.red
        case "qwen3-judge-0.6b-4bit": return Color.green
        case "qwen3-judge-4b-4bit": return Color.mint
        default: return Color.accentColor
        }
    }

    static func symbol(for family: ModelFamily) -> String {
        switch family {
        case .gteLarge, .qwen3Embedding:
            return "square.stack.3d.up"
        case .qwen3Reranker:
            return "arrow.triangle.swap"
        case .qwen3Generative:
            return "sparkles"
        }
    }
}

#Preview("Models - Simple Mode") {
    ModelsSettingsTab()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 560, height: 520)
        .preferredColorScheme(.light)
}

#Preview("Models - Advanced Mode") {
    ModelsSettingsTab()
        .environmentObject(PreviewHelpers.emptyAdvancedState())
        .frame(width: 560, height: 520)
        .preferredColorScheme(.light)
}

#Preview("Models - Dark") {
    ModelsSettingsTab()
        .environmentObject(PreviewHelpers.emptyAdvancedState())
        .frame(width: 560, height: 520)
        .preferredColorScheme(.dark)
}
