import SwiftUI

/// Installed model inventory and the review point for optional downloads.
struct ModelsSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedModelKey: String?
    @State private var installRequest: ModelInstallRequest?
    @State private var modelPendingRemoval: RegisteredModel?
    @State private var removalError: String?

    private var visibleModels: [RegisteredModel] {
        if appState.isAdvancedMode {
            return appState.modelManager.registeredModels
        }
        return appState.modelManager.registeredModels.filter { $0.key == "gte-large" }
    }

    private var selectedModel: RegisteredModel? {
        visibleModels.first { $0.key == selectedModelKey } ?? visibleModels.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(visibleModels, selection: $selectedModelKey) {
                TableColumn("Model") { model in
                    HStack(spacing: Spacing.sm) {
                        modelStatusSymbol(model)
                        Text(model.displayName)
                            .lineLimit(1)
                    }
                }
                .width(min: 190, ideal: 250)

                TableColumn("Use") { model in
                    Text(model.purpose.rawValue)
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 130)

                TableColumn("Files") { model in
                    Text(model.downloadSize.map(formatBytes) ?? "Bundled")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(min: 80, ideal: 95)

                TableColumn("Status") { model in
                    Text(statusText(model))
                        .foregroundStyle(statusColor(model))
                }
                .width(min: 92, ideal: 110)
            }
            .frame(minHeight: 190)

            Divider()

            if let selectedModel {
                modelInspector(selectedModel)
            } else {
                ContentUnavailableView("No Models", systemImage: "shippingbox")
            }
        }
        .onAppear {
            if selectedModelKey == nil || !visibleModels.contains(where: { $0.key == selectedModelKey }) {
                selectedModelKey = visibleModels.first?.key
            }
        }
        .onChange(of: appState.isAdvancedMode) { _, _ in
            if !visibleModels.contains(where: { $0.key == selectedModelKey }) {
                selectedModelKey = visibleModels.first?.key
            }
        }
        .sheet(item: $installRequest) { request in
            ModelDownloadSheet(
                models: request.models,
                modelManager: appState.modelManager,
                onComplete: { installRequest = nil },
                onCancel: { installRequest = nil }
            )
        }
        .confirmationDialog(
            "Remove this model?",
            isPresented: Binding(
                get: { modelPendingRemoval != nil },
                set: { if !$0 { modelPendingRemoval = nil } }
            ),
            presenting: modelPendingRemoval
        ) { model in
            Button("Remove \(model.displayName)", role: .destructive) {
                remove(model)
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("The verified local files will be deleted. FoodMapper can install them again later.")
        }
        .alert(
            "Model Removal Failed",
            isPresented: Binding(
                get: { removalError != nil },
                set: { if !$0 { removalError = nil } }
            )
        ) {
            Button("OK") { removalError = nil }
        } message: {
            Text(removalError ?? "The model could not be removed.")
        }
    }

    private func modelInspector(_ model: RegisteredModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(model.displayName)
                        .font(.title3.weight(.semibold))
                    Text(model.admission.rawValue)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                modelAction(model)
            }

            Grid(alignment: .leading, horizontalSpacing: Spacing.xxl, verticalSpacing: Spacing.xs) {
                GridRow {
                    detailCell("Publisher", model.publisher)
                    detailCell("License", model.licenseName)
                    detailCell("Purpose", model.purpose.rawValue)
                }
                GridRow {
                    detailCell("Download", model.downloadSize.map(formatBytes) ?? "Bundled")
                    detailCell("On disk", appState.modelManager.diskUsage(for: model.key).map(formatBytes) ?? "Not installed")
                    detailCell("Revision", model.revision.map { String($0.prefix(12)) } ?? "Fixed app asset")
                }
            }

            if case let .error(message) = appState.modelManager.state(for: model.key) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.admission == .inventory {
                Text("This model remains in the reviewed inventory and cannot be installed until its runtime and food-matching results pass qualification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.admission == .evaluation {
                Text("Evaluation models are optional, disabled with Advanced mode, and do not replace the published GTE-Large method.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: Spacing.xs) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("~/Library/Application Support/FoodMapper/Models/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                Text("Installed: \(formatBytes(installedFootprint))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(Spacing.lg)
        .frame(minHeight: 215, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func modelAction(_ model: RegisteredModel) -> some View {
        switch appState.modelManager.state(for: model.key) {
        case .notDownloaded, .error:
            Button("Review Install") {
                installRequest = ModelInstallRequest(models: [model])
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.isInstallable)
        case .downloading:
            Button("Installing...") {}
                .disabled(true)
        case .loading:
            Button("Loading...") {}
                .disabled(true)
        case .downloaded, .loaded:
            Button("Remove Model") {
                modelPendingRemoval = model
            }
        }
    }

    @ViewBuilder
    private func modelStatusSymbol(_ model: RegisteredModel) -> some View {
        switch appState.modelManager.state(for: model.key) {
        case .downloaded, .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading, .loading:
            ProgressView()
                .controlSize(.mini)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .notDownloaded:
            Image(systemName: model.admission == .inventory ? "lock.circle" : "circle")
                .foregroundStyle(.tertiary)
        }
    }

    private func detailCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ model: RegisteredModel) -> String {
        switch appState.modelManager.state(for: model.key) {
        case .notDownloaded: return model.admission == .inventory ? "Under review" : "Not installed"
        case let .downloading(progress): return progress >= 0.995 ? "Verifying" : "Installing"
        case .downloaded: return "Installed"
        case .loading: return "Loading"
        case .loaded: return "In use"
        case .error: return "Error"
        }
    }

    private func statusColor(_ model: RegisteredModel) -> Color {
        switch appState.modelManager.state(for: model.key) {
        case .downloaded, .loaded: return .green
        case .error: return .red
        default: return .secondary
        }
    }

    private var installedFootprint: Int64 {
        visibleModels.reduce(0) { total, model in
            total + (appState.modelManager.diskUsage(for: model.key) ?? 0)
        }
    }

    private func remove(_ model: RegisteredModel) {
        modelPendingRemoval = nil
        Task {
            do {
                try await appState.modelManager.deleteModel(key: model.key)
                if model.key == "gte-large" {
                    appState.syncModelStatus()
                }
            } catch {
                removalError = error.localizedDescription
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview("Models") {
    ModelsSettingsTab()
        .environmentObject(PreviewHelpers.emptyAdvancedState())
        .frame(width: 760, height: 520)
}
