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
            fieldPolicyChoices

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

            ForEach(requiredModels) { model in
                modelRow(model)
            }
        }
        .padding(Spacing.lg)
        .panelMaterialStyle(cornerRadius: 10)
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
                    .fixedSize()

                    if let profile = appState.selectedProviderProfile {
                        Text(profile.kind.sendsDataOffDevice
                             ? "A confirmation is shown before each run sends descriptions and candidates to OpenAI."
                             : "This profile is restricted to a loopback address on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                .fixedSize()

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)
            .panelMaterialStyle(cornerRadius: 10)
        }
    }

    /// Researcher field settings: local retrieval context, target columns for the provider, and a numeric rule.
    @ViewBuilder
    private var fieldPolicyChoices: some View {
        if selectedPipeline.requiresProviderProfile {
            let columns = appState.fieldPolicyColumns
            let policy = appState.targetFieldPolicy
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("TARGET FIELDS")
                    .technicalLabel()

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Retrieval context")
                        .font(.callout)
                    TextField(
                        "Retrieval context",
                        text: $appState.targetFieldPolicy.retrievalContext,
                        prompt: Text("For example: low sodium")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                    Text("Added to each description when FoodMapper searches the database. It stays on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if columns.isEmpty {
                    Text("The selected database has no columns besides its description and ID.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Columns sent with each candidate")
                            .font(.callout)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)],
                            alignment: .leading,
                            spacing: Spacing.xs
                        ) {
                            ForEach(columns, id: \.self) { column in
                                Toggle(column, isOn: judgeFieldBinding(column))
                                    .toggleStyle(.checkbox)
                                    .lineLimit(1)
                                    .disabled(
                                        !policy.judgeFields.contains(column)
                                            && policy.judgeFields.count >= TargetFieldPolicy.maximumJudgeFields
                                    )
                            }
                        }
                        Text("Up to \(TargetFieldPolicy.maximumJudgeFields) columns. Their values are sent to the provider with each candidate and are named in the confirmation before a run.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Spacing.md) {
                            Picker("Numeric rule", selection: ruleColumnBinding) {
                                Text("None").tag("")
                                ForEach(columns, id: \.self) { column in
                                    Text(column).tag(column)
                                }
                            }
                            .fixedSize()

                            if policy.numericRule != nil {
                                Picker("Goal", selection: ruleGoalBinding) {
                                    ForEach(TargetFieldPolicy.NumericRule.Goal.allCases) { goal in
                                        Text(goal.displayName).tag(goal)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 180)
                            }
                        }
                        Text("With a rule, the provider also lists the candidates that are the same food as its selection, and FoodMapper picks the lowest or highest value among them. A candidate with no value in that column cannot win. Needs the Responses or Chat Completions route.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)
            .panelMaterialStyle(cornerRadius: 10)
            .onAppear { appState.pruneTargetFieldPolicy() }
            .onChange(of: columns) { _, _ in appState.pruneTargetFieldPolicy() }
        }
    }

    private func judgeFieldBinding(_ column: String) -> Binding<Bool> {
        Binding(
            get: { appState.targetFieldPolicy.judgeFields.contains(column) },
            set: { isOn in
                var fields = appState.targetFieldPolicy.judgeFields
                fields.removeAll { $0 == column }
                if isOn, fields.count < TargetFieldPolicy.maximumJudgeFields { fields.append(column) }
                appState.targetFieldPolicy.judgeFields = fields
            }
        )
    }

    private var ruleColumnBinding: Binding<String> {
        Binding(
            get: { appState.targetFieldPolicy.numericRule?.column ?? "" },
            set: { column in
                if column.isEmpty {
                    appState.targetFieldPolicy.numericRule = nil
                } else {
                    let goal = appState.targetFieldPolicy.numericRule?.goal ?? .lowest
                    appState.targetFieldPolicy.numericRule = .init(column: column, goal: goal)
                }
            }
        )
    }

    private var ruleGoalBinding: Binding<TargetFieldPolicy.NumericRule.Goal> {
        Binding(
            get: { appState.targetFieldPolicy.numericRule?.goal ?? .lowest },
            set: { goal in appState.targetFieldPolicy.numericRule?.goal = goal }
        )
    }

    private var requiredModelKeys: [String] {
        requiredModelKeys(for: selectedPipeline)
    }

    private func requiredModelKeys(for pipeline: PipelineType) -> [String] {
        pipeline.requiredModelKeys
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

    private func icon(for pipeline: PipelineType) -> String {
        switch pipeline {
        case .gteLargeEmbedding: return "cube"
        case .gteLargeHaiku, .gteLargeHaikuV2: return "cloud"
        case .providerLLM: return "network"
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
        case .downloaded, .loaded: return "checkmark.circle"
        case .downloading, .loading: return "clock"
        case .error: return "exclamationmark.triangle"
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
