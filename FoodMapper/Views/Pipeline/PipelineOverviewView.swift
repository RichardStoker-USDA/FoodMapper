import SwiftUI

/// Selects a reviewed pipeline and its local model set for a new matching run.
struct PipelineOverviewView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var selectedPipeline: PipelineType = .gteLargeEmbedding
    @State private var installRequest: ModelInstallRequest?

    private var publishedPipelines: [PipelineType] {
        [.gteLargeEmbedding, .gteLargeHaiku]
    }

    private var evaluationPipelines: [PipelineType] {
        PipelineMode.standard.availablePipelineTypes.filter {
            $0.isImplemented && $0.admission == .evaluation
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()

            HSplitView {
                pipelineList
                    .frame(minWidth: 255, idealWidth: 285, maxWidth: 340)

                ScrollView {
                    pipelineInspector
                        .padding(Spacing.xl)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .onAppear {
            let current = appState.selectedPipelineType
            selectedPipeline = (publishedPipelines + evaluationPipelines).contains(current)
                ? current
                : .gteLargeEmbedding
        }
        .sheet(item: $installRequest) { request in
            ModelDownloadSheet(
                models: request.models,
                modelManager: appState.modelManager,
                onComplete: { installRequest = nil },
                onCancel: { installRequest = nil }
            )
        }
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Label("Experimental Runs", systemImage: "play.rectangle")
                    .font(.headline)
                Text("Choose a method, review its models, then open a new matching run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: HeaderLayout.height)
        .padding(.horizontal, Spacing.lg)
    }

    private var pipelineList: some View {
        List(selection: $selectedPipeline) {
            Section("Published") {
                ForEach(publishedPipelines) { pipeline in
                    pipelineRow(pipeline)
                }
            }

            Section("Evaluation") {
                ForEach(evaluationPipelines) { pipeline in
                    pipelineRow(pipeline)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func pipelineRow(_ pipeline: PipelineType) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon(for: pipeline))
                .foregroundStyle(.secondary)
                .frame(width: Size.iconSmall)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(pipeline.displayName)
                    .lineLimit(1)
                Text(pipelineReady(pipeline) ? "Ready" : "Setup needed")
                    .font(.caption2)
                    .foregroundStyle(pipelineReady(pipeline) ? .green : .secondary)
            }
            Spacer()
        }
        .tag(pipeline)
    }

    private var pipelineInspector: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Label(selectedPipeline.displayName, systemImage: icon(for: selectedPipeline))
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text(selectedPipeline.admission.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(selectedPipeline.shortDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let warning = selectedPipeline.performanceWarning {
                    Label(warning, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            modelChoices
            providerChoices
            instructionChoices

            Divider()

            HStack(spacing: Spacing.md) {
                if selectedPipeline.requiresProviderProfile {
                    if appState.selectedProviderProfile == nil {
                        Button("Add Provider Profile") {
                            appState.sidebarSelection = .providerProfiles
                        }
                    } else if let profile = appState.selectedProviderProfile,
                              !appState.hasCurrentProviderProbe(for: profile) {
                        Button("Test Provider Connection") {
                            appState.sidebarSelection = .providerProfiles
                        }
                    }
                } else if selectedPipeline.requiresAPIKey && !appState.hasAnthropicAPIKey {
                    Button("Open API Key Settings") {
                        openSettings()
                    }
                }

                Spacer()

                Button("Use for New Match") {
                    appState.selectedPipelineMode = selectedPipeline.pipelineMode
                    appState.selectedPipelineType = selectedPipeline
                    appState.startNewMatch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !missingModels.isEmpty
                        || !modelsUnderReview.isEmpty
                        || (selectedPipeline.requiresAPIKey && !appState.hasAnthropicAPIKey)
                        || (selectedPipeline.requiresProviderProfile && appState.selectedProviderProfile == nil)
                        || (selectedPipeline.requiresProviderProfile
                            && appState.selectedProviderProfile.map {
                                !appState.hasCurrentProviderProbe(for: $0)
                            } == true)
                )
                .help(pipelineActionHelp)
            }
        }
    }

    private var modelChoices: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("MODELS")
                .technicalLabel()

            if usesQwenEmbedding(selectedPipeline) {
                modelSizePicker(
                    title: "Embedding",
                    family: .qwen3Embedding,
                    selection: $appState.selectedEmbeddingSize
                )
            }

            if usesQwenReranker(selectedPipeline) {
                modelSizePicker(
                    title: "Reranker",
                    family: .qwen3Reranker,
                    selection: $appState.selectedRerankerSize
                )
            }

            if usesQwenJudge(selectedPipeline) {
                modelSizePicker(
                    title: "Candidate selection",
                    family: .qwen3Generative,
                    selection: $appState.selectedGenerativeSize
                )
            }

            ForEach(requiredModels) { model in
                modelRow(model)
            }
        }
        .padding(Spacing.lg)
        .panelMaterialStyle(cornerRadius: 10)
    }

    private func modelSizePicker(
        title: String,
        family: ModelFamily,
        selection: Binding<ModelSize>
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(width: 145, alignment: .leading)
            Picker(title, selection: selection) {
                ForEach(family.availableSizes) { size in
                    let key = family.modelKey(for: size)
                    let admitted = key.flatMap(appState.modelManager.registeredModel(for:))?.isInstallable == true
                    Text(admitted ? size.displayName : "\(size.displayName) - review")
                        .tag(size)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            Spacer()
        }
    }

    private func modelRow(_ model: RegisteredModel) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: modelStateSymbol(model))
                .foregroundStyle(modelStateColor(model))
                .frame(width: Size.iconMedium)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(model.displayName)
                    .font(.callout.weight(.medium))
                Text("\(model.publisher) · \(model.licenseName) · \(model.downloadSize.map(formatBytes) ?? "Bundled")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(modelStateText(model))
                .font(.caption)
                .foregroundStyle(modelStateColor(model))

            if !appState.modelManager.state(for: model.key).isAvailable && model.isInstallable {
                Button("Review Install") {
                    installRequest = ModelInstallRequest(models: [model])
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    @ViewBuilder
    private var providerChoices: some View {
        if selectedPipeline.requiresProviderProfile {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("PROVIDER")
                    .technicalLabel()

                if appState.providerProfiles.isEmpty {
                    Text("Add a provider profile before using this pipeline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Provider profile", selection: $appState.selectedProviderProfileID) {
                        ForEach(appState.providerProfiles) { profile in
                            Text("\(profile.name) · \(profile.model)")
                                .tag(Optional(profile.id))
                        }
                    }
                    .frame(maxWidth: 420)

                    if let profile = appState.selectedProviderProfile {
                        Text(profile.kind == .openAI
                             ? "A confirmation is shown before each run sends descriptions and candidates to OpenAI."
                             : "This profile is restricted to a loopback address on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Spacing.lg)
            .panelMaterialStyle(cornerRadius: 10)
        }
    }

    @ViewBuilder
    private var instructionChoices: some View {
        if selectedPipeline.supportsCustomInstruction {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("MATCHING CONTEXT")
                    .technicalLabel()

                Picker("Preset", selection: $appState.selectedInstructionPreset) {
                    ForEach(InstructionPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .frame(maxWidth: 320)

                if appState.selectedInstructionPreset == .custom {
                    TextEditor(text: $appState.customInstructionText)
                        .font(.body)
                        .frame(minHeight: 90)
                        .padding(Spacing.xs)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        }
                } else {
                    Text(instructionPreview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.lg)
            .panelMaterialStyle(cornerRadius: 10)
        }
    }

    private var requiredModelKeys: [String] {
        requiredModelKeys(for: selectedPipeline)
    }

    private func requiredModelKeys(for pipeline: PipelineType) -> [String] {
        switch pipeline {
        case .gteLargeEmbedding, .gteLargeHaiku, .gteLargeHaikuV2, .providerLLM:
            return ["gte-large"]
        case .nomicEmbedding:
            return ["nomic-embed-text-v1.5"]
        case .qwen3Embedding:
            return [appState.selectedEmbeddingModelKey]
        case .qwen3Reranker:
            return [appState.selectedRerankerModelKey]
        case .qwen3TwoStage, .qwen3SmartTriage:
            return [appState.selectedEmbeddingModelKey, appState.selectedRerankerModelKey]
        case .qwen3LLMOnly:
            return [ModelFamily.qwen3Generative.modelKey(for: appState.selectedGenerativeSize) ?? "qwen3-judge-4b-4bit"]
        case .embeddingLLM:
            return [
                appState.selectedEmbeddingModelKey,
                ModelFamily.qwen3Generative.modelKey(for: appState.selectedGenerativeSize) ?? "qwen3-judge-4b-4bit"
            ]
        case .gemma4LLMOnly, .gemma4TwoStage:
            return []
        }
    }

    private var requiredModels: [RegisteredModel] {
        requiredModelKeys.compactMap(appState.modelManager.registeredModel(for:))
    }

    private var missingModels: [RegisteredModel] {
        requiredModels.filter {
            !appState.modelManager.state(for: $0.key).isAvailable && $0.isInstallable
        }
    }

    private var modelsUnderReview: [RegisteredModel] {
        requiredModels.filter {
            !appState.modelManager.state(for: $0.key).isAvailable && !$0.isInstallable
        }
    }

    private var pipelineActionHelp: String {
        if !modelsUnderReview.isEmpty { return "A required model has not been admitted for installation." }
        if !missingModels.isEmpty { return "Install the required model above first." }
        if selectedPipeline.requiresAPIKey && !appState.hasAnthropicAPIKey { return "Add an Anthropic API key first." }
        if selectedPipeline.requiresProviderProfile && appState.selectedProviderProfile == nil { return "Add a provider profile first." }
        if selectedPipeline.requiresProviderProfile,
           let profile = appState.selectedProviderProfile,
           !appState.hasCurrentProviderProbe(for: profile) {
            return "Test the provider connection first."
        }
        return "Open a new match with this method."
    }

    private var instructionPreview: String {
        let preset = appState.selectedInstructionPreset
        if selectedPipeline == .providerLLM { return preset.judgeInstruction }
        switch selectedPipeline.defaultScoreType {
        case .cosineSimilarity: return preset.embeddingInstruction
        case .rerankerProbability: return preset.rerankerInstruction
        case .llmSelected: return preset.haikuPrompt
        case .generativeSelection: return preset.judgeInstruction
        case .llmRejected: return preset.judgeInstruction
        case .apiFallback: return preset.haikuPrompt
        case .noScore: return ""
        }
    }

    private func pipelineReady(_ pipeline: PipelineType) -> Bool {
        let keys = requiredModelKeys(for: pipeline)
        let modelsReady = keys.allSatisfy { appState.modelManager.state(for: $0).isAvailable }
        let providerReady = !pipeline.requiresProviderProfile
            || appState.selectedProviderProfile.map { appState.hasCurrentProviderProbe(for: $0) } == true
        return modelsReady && (!pipeline.requiresAPIKey || appState.hasAnthropicAPIKey) && providerReady
    }

    private func usesQwenEmbedding(_ pipeline: PipelineType) -> Bool {
        [.qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM].contains(pipeline)
    }

    private func usesQwenReranker(_ pipeline: PipelineType) -> Bool {
        [.qwen3Reranker, .qwen3TwoStage, .qwen3SmartTriage].contains(pipeline)
    }

    private func usesQwenJudge(_ pipeline: PipelineType) -> Bool {
        [.qwen3LLMOnly, .embeddingLLM].contains(pipeline)
    }

    private func icon(for pipeline: PipelineType) -> String {
        switch pipeline {
        case .gteLargeEmbedding: return "cube"
        case .nomicEmbedding, .qwen3Embedding: return "square.stack.3d.up"
        case .qwen3Reranker: return "arrow.triangle.swap"
        case .qwen3TwoStage, .qwen3SmartTriage: return "point.3.connected.trianglepath.dotted"
        case .gteLargeHaiku, .gteLargeHaikuV2: return "cloud"
        case .qwen3LLMOnly, .gemma4LLMOnly: return "text.bubble"
        case .providerLLM: return "network"
        case .embeddingLLM, .gemma4TwoStage: return "cpu"
        }
    }

    private func modelStateText(_ model: RegisteredModel) -> String {
        switch appState.modelManager.state(for: model.key) {
        case .notDownloaded: return model.admission == .inventory ? "Under review" : "Not installed"
        case let .downloading(progress): return progress >= 0.995 ? "Verifying" : "Installing"
        case .downloaded: return "Installed"
        case .loading: return "Loading"
        case .loaded: return "In use"
        case .error: return "Error"
        }
    }

    private func modelStateSymbol(_ model: RegisteredModel) -> String {
        switch appState.modelManager.state(for: model.key) {
        case .downloaded, .loaded: return "checkmark.circle.fill"
        case .downloading, .loading: return "clock"
        case .error: return "exclamationmark.triangle.fill"
        case .notDownloaded: return model.admission == .inventory ? "lock.circle" : "circle"
        }
    }

    private func modelStateColor(_ model: RegisteredModel) -> Color {
        switch appState.modelManager.state(for: model.key) {
        case .downloaded, .loaded: return .green
        case .error: return .red
        default: return .secondary
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview("Experimental Runs") {
    PipelineOverviewView()
        .environmentObject(PreviewHelpers.emptyAdvancedState())
        .frame(width: 1000, height: 760)
}
