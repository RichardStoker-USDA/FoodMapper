import SwiftUI
import UniformTypeIdentifiers

/// Match setup view shown in the detail pane when user clicks "New Match".
/// Layout: drop zone (no file) or compact file row + inline config bar + side-by-side preview (file loaded).
struct MatchSetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false
    @State private var isLoading = false
    @State private var showingAddDatabase = false
    @State private var inlineAPIKeyInput = ""
    @State private var inlineAPIKeyStatus: InlineAPIKeyStatus = .idle
    @State private var isValidatingInlineKey = false
    @State private var showHaikuInfo = false
    @State private var showAPIKeyHelp = false
    @State private var showInstructionInfo = false
    @State private var showCSVHelp = false
    @State private var inlineDownloadTasks: [String: Task<Void, Never>] = [:]
    @State private var inlineCancellingModels: Set<String> = []

    enum InlineAPIKeyStatus: Equatable {
        case idle, validating, valid, invalid(String)
    }

    private var hasFile: Bool { appState.inputFile != nil }
    private var hasColumn: Bool { appState.selectedColumn != nil }
    private var isResearchMode: Bool { appState.selectedPipelineMode == .researchValidation }

    private var inputSample: [String] {
        guard let file = appState.inputFile,
              let column = appState.selectedColumn else { return [] }
        return Array(file.values(for: column).prefix(10))
    }

    private var dbSample: [String] {
        appState.targetDatabaseSample
    }

    private var inputCount: Int {
        guard let file = appState.inputFile,
              let column = appState.selectedColumn else { return 0 }
        return file.values(for: column).count
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    Spacer(minLength: Spacing.xxl)

                    if hasFile {
                        fileLoadedContent
                    } else {
                        dropZoneContent
                    }

                    Spacer(minLength: Spacing.xxl)
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
                .animation(Animate.standard, value: hasFile)
                .animation(Animate.standard, value: hasColumn)
            }
        }
        .sheet(isPresented: $showingAddDatabase) {
            AddDatabaseSheet { database in
                appState.addCustomDatabase(database)
            }
        }
    }

    // MARK: - No File: Drop Zone

    private var dropZoneContent: some View {
        VStack(spacing: Spacing.lg) {
            // Title
            VStack(spacing: Spacing.xs) {
                Text("New Match")
                    .technicalHeader()
                    .foregroundStyle(.primary)

                Text("LOAD A DATA FILE TO GET STARTED")
                    .technicalLabel()
            }

            // Drop zone
            VStack(spacing: Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                }

                Text(isLoading ? "Loading..." : "Drop CSV or TSV here or click to browse")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
            .premiumMaterialStyle(cornerRadius: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(colorScheme == .dark ? 0.3 : 0.5),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isLoading else { return }
                openFilePicker()
            }
            .onDrop(of: [.fileURL], delegate: CSVDropDelegate(
                isTargeted: $isDropTargeted,
                onDrop: loadFile
            ))
            .tutorialAnchor("fileDropZone")

            Text("CSV or TSV with a header row. Include a food description column and an optional ID column.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            // CSV help disclosure
            csvHelpSection

            // Recent files
            if !appState.storedInputFiles.isEmpty {
                recentFilesSection
            }
        }
        .frame(maxWidth: 480)
    }

    // MARK: - File Loaded: Compact Row + Config + Preview

    private var fileLoadedContent: some View {
        VStack(spacing: Spacing.md) {
            // Title (matches "New Match" page pattern)
            VStack(spacing: Spacing.xs) {
                Text("Configure Match")
                    .technicalHeader()
                    .foregroundStyle(.primary)

                Text("SELECT COLUMN AND DATABASE")
                    .technicalLabel()
            }

            // Compact file info row
            compactFileRow
                .tutorialAnchor("fileDropZone")

            // Inline config bar
            inlineConfigBar

            // Embedding mismatch notice
            embeddingMismatchNotice

            // Matching options (always shown, content varies by mode)
            matchingOptionsCard

            // Side-by-side preview
            if hasColumn && !inputSample.isEmpty && !dbSample.isEmpty {
                previewTable
            } else if !hasColumn && !dbSample.isEmpty {
                partialPreviewTable
            }

            // Summary line
            if hasColumn, let db = appState.selectedDatabase {
                Text("\(inputCount.formatted()) input rows \u{2192} \(db.itemCount.formatted()) database items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Compact File Row

    private var compactFileRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "doc")
                .font(.body)
                .foregroundStyle(.green)

            if let file = appState.inputFile {
                Text(file.name)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("\(file.rowCount) rows, \(file.columns.count) columns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                appState.inputFile = nil
                appState.selectedColumn = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove file")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Inline Config Bar

    private var inlineConfigBar: some View {
        HStack(spacing: 0) {
            // Column picker
            HStack(spacing: Spacing.xs) {
                Text("Column:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let file = appState.inputFile {
                    Picker("Column", selection: $appState.selectedColumn) {
                        Text("Select...").tag(String?.none)
                        ForEach(file.columns, id: \.self) { col in
                            Text(col).tag(String?.some(col))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .flexiblePickerSizing()
                    .frame(minWidth: 120)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.sm)
            .tutorialAnchor("columnPicker")

            Divider()
                .frame(height: 24)

            // Database picker
            HStack(spacing: Spacing.xs) {
                Text("Database:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Database", selection: $appState.selectedDatabase) {
                    Text("Select...").tag(AnyDatabase?.none)
                    ForEach(BuiltInDatabase.allCases) { db in
                        Text(db.displayName).tag(AnyDatabase?.some(.builtIn(db)))
                    }
                    if !isResearchMode {
                        ForEach(appState.customDatabases) { db in
                            Text(db.displayName).tag(AnyDatabase?.some(.custom(db)))
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .flexiblePickerSizing()
                .frame(minWidth: 120)

                if !isResearchMode {
                    Button {
                        showingAddDatabase = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Add custom database")
                    .tutorialAnchor("addDatabaseButton")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.sm)
            .tutorialAnchor("setupDatabaseSection")
        }
        .padding(.vertical, Spacing.sm)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Embedding Mismatch Notice

    /// Shows a notice when the selected database needs embedding for the current model.
    /// This is informational, not blocking -- MatchingEngine will auto-embed on first run.
    /// Depends on embeddingCacheVersion to re-evaluate after embeddings are created.
    @ViewBuilder
    private var embeddingMismatchNotice: some View {
        let _ = appState.embeddingCacheVersion  // Force re-evaluation when cache changes
        if let db = appState.selectedDatabase,
           let embeddingKey = appState.embeddingModelKeyForCurrentPipeline,
           !db.hasEmbeddings(for: embeddingKey) {
            let modelName = appState.modelManager.registeredModel(for: embeddingKey)?.displayName ?? embeddingKey
            HStack(spacing: Spacing.sm) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: Size.iconSmall))
                Text("Database will be embedded with \(modelName) on first match. This may take a moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .dark
                        ? Color.white.opacity(0.03)
                        : Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Matching Options Card

    private var matchingOptionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Text(appState.isAdvancedMode ? "ADVANCED PIPELINE CONFIGURATION" : "MATCHING CONFIGURATION")
                    .technicalLabel()
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.bottom, Spacing.sm)

            Divider().padding(.bottom, Spacing.sm)

            if appState.isAdvancedMode {
                advancedMatchingOptions
            } else {
                simpleMatchingOptions
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Simple Matching Options

    private var simpleMatchingOptions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            haikuToggleRow
            haikuAPIKeySection
        }
    }

    // MARK: - Advanced Matching Options

    /// The "base" pipeline for display in the picker.
    /// Maps .gteLargeHaiku back to .gteLargeEmbedding since Haiku is controlled by the toggle.
    private var basePipelineType: PipelineType {
        appState.selectedPipelineType == .gteLargeHaiku ? .gteLargeEmbedding : appState.selectedPipelineType
    }

    /// Binding for the pipeline picker that keeps .gteLargeHaiku out of the picker.
    /// The Haiku aspect is handled by the toggle, not the dropdown.
    private var pipelinePickerBinding: Binding<PipelineType> {
        Binding(
            get: { basePipelineType },
            set: { newValue in
                appState.selectedPipelineType = newValue
                // didSet on selectedPipelineType resets enableHaikuVerification for non-GTE pipelines
            }
        )
    }

    /// Whether the selected pipeline has a model availability issue (not an API key issue)
    private var showModelsRequiredWarning: Bool {
        // Don't show "Models required" for .gteLargeHaiku -- the API key section handles that
        guard appState.selectedPipelineType != .gteLargeHaiku else { return false }
        return !appState.canRunSelectedPipeline
    }

    /// Models that need downloading for the current pipeline
    private var missingModels: [RegisteredModel] {
        appState.modelManager.missingModelKeys(for: appState.requiredModelKeysForCurrentPipeline)
    }

    /// Whether any missing model is currently being downloaded
    private var isAnyMissingModelDownloading: Bool {
        missingModels.contains { model in
            if case .downloading = appState.modelManager.state(for: model.key) { return true }
            return false
        }
    }

    /// Whether this view is actively managing any inline download tasks.
    private var hasInlineActiveDownloads: Bool {
        !inlineDownloadTasks.isEmpty
    }

    /// Whether at least one missing model can be started or retried now.
    private var canDownloadAnyMissingModel: Bool {
        missingModels.contains { model in
            switch appState.modelManager.state(for: model.key) {
            case .notDownloaded, .error:
                return true
            default:
                return false
            }
        }
    }

    private var advancedMatchingOptions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Pipeline picker
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Text("Pipeline:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Pipeline", selection: pipelinePickerBinding) {
                        ForEach(availablePipelinesForDropdown) { pipeline in
                            Text(pipeline.displayName).tag(pipeline)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(minWidth: 160)

                    if showModelsRequiredWarning {
                        HStack(spacing: Spacing.xxs) {
                            if isAnyMissingModelDownloading || hasInlineActiveDownloads {
                                ProgressView()
                                    .controlSize(.mini)
                            }

                            Label(
                                isAnyMissingModelDownloading || hasInlineActiveDownloads
                                    ? "Downloading..."
                                    : "Missing models",
                                systemImage: "arrow.down.circle"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary) // Cleaner than orange
                        }
                    }

                    Spacer()
                }

                // Combined pipeline info
                Group {
                    if let warning = basePipelineType.performanceWarning {
                        Text("\(basePipelineType.shortDescription)\n\(warning)")
                    } else {
                        Text(basePipelineType.shortDescription)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

                if let estimate = rerankingTimeEstimate {
                    Text(estimate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Inline model download
                if showModelsRequiredWarning {
                    inlineModelDownloadSection
                }
            }

            // Model size pickers (only for Qwen3-based pipelines)
            if pipelineUsesQwen3Embedding {
                Divider()
                modelSizePicker(
                    label: "Embedding Model",
                    family: .qwen3Embedding,
                    selection: $appState.selectedEmbeddingSize
                )
            }

            if pipelineUsesQwen3Reranker {
                if !pipelineUsesQwen3Embedding { Divider() }
                modelSizePicker(
                    label: "Reranker Model",
                    family: .qwen3Reranker,
                    selection: $appState.selectedRerankerSize
                )
            }

            if pipelineUsesGenerative {
                if !pipelineUsesQwen3Embedding && !pipelineUsesQwen3Reranker { Divider() }
                modelSizePicker(
                    label: "Judge Model",
                    family: .qwen3Generative,
                    selection: $appState.selectedGenerativeSize
                )
            }

            // Haiku toggle (only when GTE-Large is the base pipeline)
            if basePipelineType == .gteLargeEmbedding {
                Divider()
                haikuToggleRow
                haikuAPIKeySection
            }

            // API key section for pipelines that require it (e.g. Haiku v2) but aren't via the toggle
            if appState.selectedPipelineType.requiresAPIKey && basePipelineType != .gteLargeEmbedding {
                Divider()
                haikuAPIKeySection
            }

            // Instruction picker (only for pipelines that support it)
            if appState.selectedPipelineType.supportsCustomInstruction {
                Divider()

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        Text("Instruction:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Instruction", selection: $appState.selectedInstructionPreset) {
                            ForEach(InstructionPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(minWidth: 120)

                        Spacer()

                        Button {
                            showInstructionInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: Size.iconSmall))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showInstructionInfo, arrowEdge: .trailing) {
                            instructionInfoPopover
                        }
                    }

                    if appState.selectedInstructionPreset == .custom {
                        TextField(
                            "e.g., Match food descriptions to their closest generic equivalent",
                            text: $appState.customInstructionText,
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .font(.caption)

                        Text("This instruction guides the embedding model and reranker during matching.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(appState.selectedInstructionPreset.helpText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Haiku Toggle Row

    private var haikuToggleRow: some View {
        HStack(spacing: Spacing.xs) {
            Toggle(isOn: $appState.enableHaikuVerification) {
                HStack(spacing: Spacing.xs) {
                    Text("Hybrid Matching")
                        .font(.callout)

                    HStack(spacing: 4) {
                        Image(systemName: "cloud")
                            .font(.caption2)
                        Text("cloud")
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .polishedBadge(tone: .neutral, cornerRadius: 999)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: appState.enableHaikuVerification) { _, newValue in
                if newValue {
                    inlineAPIKeyStatus = .idle
                    inlineAPIKeyInput = ""
                }
            }

            Button {
                showHaikuInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: Size.iconSmall))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showHaikuInfo, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Hybrid Matching")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("**Off** -- On-device semantic matching only. An AI model on your Mac compares food descriptions to the database and returns the closest matches by meaning.")

                        Text("**On** -- Adds a cloud verification step. After on-device matching narrows it down to the top 5, Claude Haiku reviews those candidates and picks the best one.")

                        Text("Both approaches are from the research paper. The hybrid method achieved the highest accuracy.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)

                    Text("Hybrid mode requires an Anthropic API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Link("Get an API key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com")!)
                        .font(.caption)
                }
                .frame(width: 300)
                .padding(Spacing.md)
            }

            // Inline status label showing current matching mode
            Text(appState.enableHaikuVerification ? "Semantic + cloud verification" : "Semantic matching only")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .animation(Animate.standard, value: appState.enableHaikuVerification)

            Spacer()
        }
    }

    // MARK: - Haiku API Key Section

    @ViewBuilder
    private var haikuAPIKeySection: some View {
        if appState.enableHaikuVerification || appState.selectedPipelineType.requiresAPIKey {
            if appState.cachedHasAPIKey && inlineAPIKeyStatus != .invalid("Invalid key") && inlineAPIKeyStatus != .invalid("Validation failed") {
                // Key is stored and valid
                VStack(spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: Size.iconSmall))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))

                        Text("API key configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        SettingsLink {
                            Text("Manage")
                                .font(.caption)
                        }
                        .controlSize(.small)
                    }

                    if appState.isAdvancedMode {
                        HStack(spacing: Spacing.sm) {
                            Text("Model")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $appState.selectedClaudeModel) {
                                ForEach(ClaudeModelVersion.allCases) { version in
                                    Text(version.displayName).tag(version)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()

                            if appState.selectedClaudeModel.isPaperModel {
                                Text("Paper model")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, Spacing.xs)
                                    .padding(.vertical, Spacing.xxxs)
                                    .background(
                                        Capsule().fill(Color.badgeBackground(for: colorScheme))
                                    )
                            }

                            Spacer()
                        }
                    }
                }
                .animation(Animate.standard, value: appState.cachedHasAPIKey)
            } else {
                // Inline API key entry
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        // API key help button -- shows setup instructions
                        Button {
                            showAPIKeyHelp.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: Size.iconSmall))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showAPIKeyHelp, arrowEdge: .leading) {
                            apiKeyHelpPopover
                        }
                        .transition(.scale.combined(with: .opacity))

                        SecureField("sk-ant-...", text: $inlineAPIKeyInput)
                            .textFieldStyle(.roundedBorder)

                        Button("Save") {
                            saveInlineAPIKey()
                        }
                        .disabled(inlineAPIKeyInput.isEmpty || isValidatingInlineKey)
                        .controlSize(.small)
                    }

                    switch inlineAPIKeyStatus {
                    case .idle:
                        EmptyView()
                    case .validating:
                        HStack(spacing: Spacing.xs) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Validating...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    case .valid:
                        Label("Key saved", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    case .invalid(let reason):
                        Label(reason, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .animation(Animate.standard, value: appState.cachedHasAPIKey)
            }
        }
    }

    // MARK: - API Key Help Popover

    private var apiKeyHelpPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Anthropic API Key")
                .font(.headline)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("To use hybrid matching, you need an API key from Anthropic.")
                    .font(.callout)

                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("1. Create an account at console.anthropic.com")
                        .font(.callout)
                    Text("2. Go to Settings \u{2192} API Keys")
                        .font(.callout)
                    Text("3. Generate a new key and paste it above")
                        .font(.callout)
                }

                Text("The key starts with sk-ant- and is stored locally on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Hybrid matching uses Claude Haiku via the Batches API, which runs at 50% off standard pricing. Matching ~2,700 food items costs roughly $0.15\u{2013}0.20.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Link("console.anthropic.com", destination: URL(string: "https://console.anthropic.com")!)
                .font(.caption)
        }
        .frame(width: 300)
        .padding(Spacing.md)
    }

    // MARK: - Inline API Key Save

    private func saveInlineAPIKey() {
        let key = inlineAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isValidatingInlineKey = true
        inlineAPIKeyStatus = .validating

        Task {
            APIKeyStorage.setAnthropicAPIKey(key)
            appState.refreshAPIKeyState()

            do {
                let client = AnthropicAPIClient()
                let isValid = try await client.validateAPIKey(key)

                await MainActor.run {
                    isValidatingInlineKey = false
                    if isValid {
                        inlineAPIKeyStatus = .valid
                        inlineAPIKeyInput = ""
                    } else {
                        inlineAPIKeyStatus = .invalid("Invalid key")
                        APIKeyStorage.deleteAnthropicAPIKey()
                        appState.refreshAPIKeyState()
                    }
                }
            } catch {
                await MainActor.run {
                    isValidatingInlineKey = false
                    inlineAPIKeyStatus = .invalid("Validation failed")
                    APIKeyStorage.deleteAnthropicAPIKey()
                    appState.refreshAPIKeyState()
                }
            }
        }
    }

    // MARK: - Model Size Selection

    /// Whether the current pipeline uses a Qwen3 embedding model
    private var pipelineUsesQwen3Embedding: Bool {
        switch basePipelineType {
        case .qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM: return true
        default: return false
        }
    }

    /// Whether the current pipeline uses a Qwen3 reranker model
    private var pipelineUsesQwen3Reranker: Bool {
        switch basePipelineType {
        case .qwen3Reranker, .qwen3TwoStage, .qwen3SmartTriage: return true
        default: return false
        }
    }

    /// Whether the current pipeline uses a generative judge model
    private var pipelineUsesGenerative: Bool {
        switch basePipelineType {
        case .qwen3LLMOnly, .embeddingLLM: return true
        default: return false
        }
    }

    /// Segmented picker for model size within a family.
    /// Sizes whose models aren't downloaded are grayed out but still selectable
    /// (triggering the download sheet when the user tries to run).
    private func modelSizePicker(
        label: String,
        family: ModelFamily,
        selection: Binding<ModelSize>
    ) -> some View {
        HStack(spacing: Spacing.xs) {
            Text("\(label):")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(label, selection: selection) {
                ForEach(family.availableSizes) { size in
                    let key = family.modelKey(for: size)
                    let isAvailable = key.map { appState.modelManager.state(for: $0).isAvailable } ?? false
                    Text(size.displayName)
                        .tag(size)
                        .foregroundStyle(isAvailable ? .primary : .secondary)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            // Show download indicator if selected size isn't available
            if let key = family.modelKey(for: selection.wrappedValue),
               !appState.modelManager.state(for: key).isAvailable {
                Image(systemName: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Download required")
            }

            Spacer()
        }
    }

    // MARK: - Inline Model Download

    /// Compact inline download section shown when pipeline models aren't available.
    private var inlineModelDownloadSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: Spacing.sm) {
                Text("Required Models Missing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if missingModels.count > 1 {
                    if isAnyMissingModelDownloading || hasInlineActiveDownloads {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Downloading...")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                    } else {
                        Button {
                            downloadMissingModels()
                        } label: {
                            Text("Download All (\(missingModels.count))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Spacing.md)
            .background(Color.primary.opacity(0.03))

            Divider()

            // List
            VStack(spacing: 0) {
                ForEach(Array(missingModels.enumerated()), id: \.element.id) { index, model in
                    inlineModelDownloadRow(model)
                    if index < missingModels.count - 1 {
                        Divider()
                            .padding(.leading, Spacing.md)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.14).opacity(0.95) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04),
                    lineWidth: 1
                )
        )
        .shadow(
            color: colorScheme == .dark ? Color.black.opacity(0.3) : Color.black.opacity(0.08),
            radius: 4,
            y: 2
        )
    }

    private func inlineModelDownloadRow(_ model: RegisteredModel) -> some View {
        let state = appState.modelManager.state(for: model.key)

        return HStack(spacing: Spacing.md) {
            // Icon
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 32, height: 32)
                Image(systemName: "cube.box")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: Spacing.xs) {
                    if let size = model.downloadSize {
                        Text(formatDownloadSize(size))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if case .error(let message) = state {
                        Text("• \(message)")
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            InlineModelStatusView(
                model: model,
                state: state,
                onDownload: { startInlineDownload(model) },
                onCancel: { cancelInlineDownload(model) }
            )
        }
        .padding(Spacing.md)
    }

    /// Download all missing models for the current pipeline inline.
    private func downloadMissingModels() {
        for model in missingModels {
            switch appState.modelManager.state(for: model.key) {
            case .notDownloaded, .error:
                startInlineDownload(model)
            default:
                continue
            }
        }
    }

    private func startInlineDownload(_ model: RegisteredModel) {
        let key = model.key
        guard inlineDownloadTasks[key] == nil else { return }

        inlineCancellingModels.remove(key)

        let task = Task {
            defer {
                Task { @MainActor in
                    inlineDownloadTasks.removeValue(forKey: key)
                    inlineCancellingModels.remove(key)
                }
            }

            do {
                try await appState.modelManager.downloadModel(key: key)
                if key == "gte-large" {
                    await MainActor.run { appState.syncModelStatus() }
                }
            } catch {
                // Error state is already tracked in ModelManager.
            }
        }

        inlineDownloadTasks[key] = task
    }

    private func cancelInlineDownload(_ model: RegisteredModel) {
        let key = model.key
        inlineCancellingModels.insert(key)
        appState.modelManager.cancelDownload(key: key)
        inlineDownloadTasks[key]?.cancel()
    }

    private func formatDownloadSize(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else {
            return String(format: "%d MB", bytes / 1_000_000)
        }
    }

    /// Pipeline types available in the advanced dropdown (excludes .gteLargeHaiku, handled by toggle)
    private var availablePipelinesForDropdown: [PipelineType] {
        let modes = appState.selectedPipelineMode?.availablePipelineTypes ?? PipelineType.allCases
        return modes.filter { $0.isImplemented && $0 != .gteLargeHaiku }
    }

    /// Estimated reranking time for current pipeline and data size
    private var rerankingTimeEstimate: String? {
        let pipelineType = appState.selectedPipelineType
        let hwConfig = appState.effectiveHardwareConfig
        guard inputCount > 0 else { return nil }

        switch pipelineType {
        case .qwen3TwoStage:
            let topK = hwConfig.topKForReranking
            let rerankTime = hwConfig.estimateRerankingTime(inputCount: inputCount, candidatesPerInput: topK)
            guard rerankTime > 5 else { return nil }
            return "Estimated reranking: \(HardwareConfig.formatDuration(rerankTime)) (\(inputCount) inputs x \(topK) candidates)"
        case .qwen3Reranker:
            guard let db = appState.selectedDatabase else { return nil }
            let rerankTime = hwConfig.estimateRerankingTime(inputCount: inputCount, candidatesPerInput: db.itemCount)
            return "Estimated time: \(HardwareConfig.formatDuration(rerankTime)) (\(inputCount) inputs x \(db.itemCount.formatted()) entries)"
        default:
            return nil
        }
    }

    // MARK: - Instruction Info Popover

    private var instructionInfoPopover: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Matching Instructions")
                .font(.headline)

            Text("Instructions tell the model what kind of food matching to perform. Each preset optimizes for a different aspect of food description matching.")
                .font(.callout)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("How instructions apply:")
                    .font(.caption)
                    .fontWeight(.medium)

                instructionTierRow(icon: "cpu", label: "Embedding", active: appState.selectedPipelineType.supportsCustomInstruction)
                instructionTierRow(icon: "arrow.triangle.swap", label: "Reranker", active: appState.selectedPipelineType == .qwen3TwoStage || appState.selectedPipelineType == .qwen3SmartTriage || appState.selectedPipelineType == .qwen3Reranker)
                instructionTierRow(icon: "cloud", label: "Claude API", active: appState.selectedPipelineType == .gteLargeHaiku || appState.selectedPipelineType == .gteLargeHaikuV2)
            }

            Text("The default \"Best Match\" preset works well for most food matching tasks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 280)
        .padding(Spacing.md)
    }

    private func instructionTierRow(icon: String, label: String, active: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(active ? .primary : .tertiary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
                .foregroundStyle(active ? .primary : .tertiary)
            Spacer()
            if active {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - CSV Help Disclosure

    private var csvHelpSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Clickable header row (entire area toggles expand/collapse)
            Button {
                withAnimation(Animate.standard) {
                    showCSVHelp.toggle()
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showCSVHelp ? 90 : 0))
                        .animation(Animate.standard, value: showCSVHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Label("Need help preparing your data file?", systemImage: "questionmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Download a template or learn how to export from Excel, Sheets, or Numbers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if showCSVHelp {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    // Quick start card
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("QUICK START")
                            .technicalLabel()

                        Text("Download this CSV template, paste your food descriptions into it, then drag the file here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: downloadCSVTemplate) {
                            Label("Download Template", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardBackground(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
                    )

                    // Export instructions card
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("EXPORTING FROM A SPREADSHEET")
                            .technicalLabel()

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Microsoft Excel")
                                .font(.caption.weight(.semibold))
                            Text("File > Save As > choose \"CSV UTF-8\" from the format dropdown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Google Sheets")
                                .font(.caption.weight(.semibold))
                            Text("File > Download > Comma-separated values (.csv)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Apple Numbers")
                                .font(.caption.weight(.semibold))
                            Text("File > Export To > CSV")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("TSV Files")
                                .font(.caption.weight(.semibold))
                            Text("Tab-separated files (.tsv) are also supported. If your data is already in TSV format, you can import it directly without conversion.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardBackground(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
                    )

                }
                .padding(.top, Spacing.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Preview Table (both columns populated)

    private var previewTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DATA PREVIEW")
                .technicalLabel()
                .padding(.bottom, Spacing.xs)

            HStack(alignment: .top, spacing: 0) {
                previewColumn(
                    header: "Your Input",
                    values: inputSample,
                    totalCount: inputCount
                )

                Divider()

                if let db = appState.selectedDatabase {
                    previewColumn(
                        header: db.displayName,
                        values: dbSample,
                        totalCount: db.itemCount
                    )
                }
            }
            .premiumMaterialStyle(cornerRadius: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Partial Preview (no column yet, database side populated)

    private var partialPreviewTable: some View {
        let altRowColors = [Color.clear, Color.primary.opacity(0.02)]

        return VStack(alignment: .leading, spacing: 0) {
            Text("DATA PREVIEW")
                .technicalLabel()
                .padding(.bottom, Spacing.xs)

            HStack(alignment: .top, spacing: 0) {
                // Input placeholder
                VStack(alignment: .leading, spacing: 0) {
                    Text("YOUR INPUT")
                        .technicalLabel()
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05))

                    Divider()

                    ForEach(0..<min(dbSample.count, 10), id: \.self) { index in
                        HStack(spacing: Spacing.xs) {
                            Text("\(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .frame(width: 18, alignment: .trailing)

                            Text("--")
                                .font(.body)
                                .foregroundStyle(.quaternary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs)
                        .background(altRowColors[index % 2])
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                if let db = appState.selectedDatabase {
                    previewColumn(
                        header: db.displayName,
                        values: dbSample,
                        totalCount: db.itemCount
                    )
                }
            }
            .premiumMaterialStyle(cornerRadius: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Preview Column

    private func previewColumn(header: String, values: [String], totalCount: Int) -> some View {
        let altRowColors = [Color.clear, Color.primary.opacity(0.02)]

        return VStack(alignment: .leading, spacing: 0) {
            Text(header.uppercased())
                .technicalLabel()
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))

            Divider()

            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack(spacing: Spacing.xs) {
                    Text("\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .frame(width: 18, alignment: .trailing)

                    Text(value)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(altRowColors[index % 2])
            }

            if totalCount > values.count {
                Text("+ \((totalCount - values.count).formatted()) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recent Files

    private var recentFilesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("RECENT FILES")
                .technicalLabel()

            ForEach(appState.storedInputFiles.prefix(5)) { stored in
                Button {
                    loadStoredFile(stored)
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(stored.displayName)
                            .font(.callout)
                            .lineLimit(1)

                        Spacer()

                        Text("\(stored.rowCount) rows")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - File Operations

    private func downloadCSVTemplate() {
        guard let bundleURL = Bundle.main.url(
            forResource: "csv_template",
            withExtension: "csv",
            subdirectory: "Templates"
        ) else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "FoodMapper_template.csv"
        panel.message = "Save the CSV template"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(at: bundleURL, to: url)
            } catch {
                // File save failed silently -- user can retry
            }
        }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DataFileFormat.allUTTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            loadFile(from: url)
        }
    }

    private func loadFile(from url: URL) {
        isLoading = true
        Task { @MainActor in
            do {
                let loadedFile = try await CSVParser.parse(url: url)
                appState.inputFile = loadedFile
                appState.handleFileLoaded(loadedFile)
                // Store the input file
                appState.storeInputFile(loadedFile)
                isLoading = false
            } catch {
                isLoading = false
                appState.error = AppError.fileLoadFailed(error.localizedDescription)
            }
        }
    }

    private func loadStoredFile(_ stored: StoredInputFile) {
        isLoading = true
        Task { @MainActor in
            do {
                var loadedFile = try await CSVParser.parse(url: stored.csvURL)
                loadedFile.displayNameOverride = stored.displayName
                appState.inputFile = loadedFile
                appState.handleFileLoaded(loadedFile)
                appState.touchStoredInputFile(stored.id)
                isLoading = false
            } catch {
                isLoading = false
                appState.error = AppError.fileLoadFailed(error.localizedDescription)
            }
        }
    }
}

private struct InlineModelStatusView: View {
    let model: RegisteredModel
    let state: ModelState
    let onDownload: () -> Void
    let onCancel: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var indeterminateOffset: CGFloat = -100
    
    var body: some View {
        switch state {
        case .notDownloaded:
            Button(action: onDownload) {
                Text("Get")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.1))
                    )
            }
            .buttonStyle(.plain)
            .help("Download model")

        case .loading:
            // Indeterminate polished bar
            VStack(alignment: .leading, spacing: 4) {
                Text("Preparing...")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                        
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Color.accentColor.opacity(0.5), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * 0.4)
                            .offset(x: indeterminateOffset)
                            .onAppear {
                                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                                    indeterminateOffset = geo.size.width
                                }
                            }
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())
            }
            .frame(width: 100)

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Downloading")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                        
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 4)
            }
            .frame(width: 100)

        case .downloaded, .loaded:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                Text("Installed")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1))

        case .error:
            Button(action: onDownload) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.8)))
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview("Empty - No File") {
    MatchSetupView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 700, height: 600)
}

#Preview("Simple Mode - Ready to Match") {
    MatchSetupView()
        .environmentObject(PreviewHelpers.readyToMatchState())
        .frame(width: 700, height: 600)
}

#Preview("Advanced Mode - Ready to Match") {
    MatchSetupView()
        .environmentObject(PreviewHelpers.readyToMatchAdvancedState())
        .frame(width: 700, height: 600)
}

#Preview("File Loaded - No Selection") {
    MatchSetupView()
        .environmentObject(PreviewHelpers.fileLoadedState())
        .frame(width: 700, height: 600)
}

#Preview("Simple Mode - Light") {
    MatchSetupView()
        .environmentObject(PreviewHelpers.readyToMatchState())
        .frame(width: 700, height: 600)
        .preferredColorScheme(.light)
}

#Preview("Advanced Mode - Light") {
    MatchSetupView()
        .environmentObject(PreviewHelpers.readyToMatchAdvancedState())
        .frame(width: 700, height: 600)
        .preferredColorScheme(.light)
}
