import SwiftUI
import MLX
import os

private let benchmarkLogger = Logger(subsystem: "com.foodmapper", category: "benchmark-runner")

/// Run benchmark section: pipeline picker, model sizes, top-K, judge format, instruction,
/// threshold, quick test, run button, live progress.
struct BenchmarkRunnerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let datasetId: UUID
    let datasetSource: BenchmarkSource

    @State private var selectedPipeline: PipelineType = .gteLargeEmbedding
    @State private var threshold: Double = 0.85
    @State private var isRunning = false
    @State private var progress: Double = 0
    @State private var runError: String?
    @State private var itemsCompleted: Int = 0
    @State private var itemsTotal: Int = 0
    @State private var elapsedSeconds: Double = 0
    @State private var runStartTime: Date?
    @State private var timerTask: Task<Void, Never>?
    @State private var runningCorrect: Int = 0
    @State private var benchmarkTask: Task<Void, Never>?

    // Instruction -- 3 separate tier fields for custom mode
    @State private var selectedPreset: InstructionPreset = .bestMatch
    @State private var customEmbeddingInstruction: String = ""
    @State private var customRerankerInstruction: String = ""
    @State private var customJudgeInstruction: String = ""

    // Quick test
    @State private var quickTestEnabled: Bool = false
    @State private var quickTestSize: Int = 50

    // Model size overrides (benchmark-local, not persisted)
    @State private var embeddingSize: ModelSize = .medium
    @State private var rerankerSize: ModelSize = .small
    @State private var generativeSize: ModelSize = .medium

    // Top-K candidates for second stage
    @State private var topK: Int = 10

    // Judge response format
    @State private var judgeResponseFormat: JudgeResponseFormat = .letter

    // Think mode toggle
    @State private var allowThinking: Bool = false

    /// Which stages the selected pipeline uses
    private var pipelineUsesEmbedding: Bool {
        selectedPipeline.embeddingModelKey != nil
    }
    private var pipelineUsesQwen3Embedding: Bool {
        switch selectedPipeline {
        case .qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM: return true
        default: return false
        }
    }
    private var pipelineUsesReranker: Bool {
        switch selectedPipeline {
        case .qwen3Reranker, .qwen3TwoStage, .qwen3SmartTriage: return true
        default: return false
        }
    }
    private var pipelineUsesLocalJudge: Bool {
        switch selectedPipeline {
        case .qwen3LLMOnly, .embeddingLLM: return true
        default: return false
        }
    }
    private var pipelineUsesJudge: Bool {
        switch selectedPipeline {
        case .qwen3LLMOnly, .embeddingLLM, .gteLargeHaiku, .gteLargeHaikuV2: return true
        default: return false
        }
    }
    /// Whether a second stage exists that uses top-K from embedding
    private var pipelineUsesTopK: Bool {
        switch selectedPipeline {
        case .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM, .gteLargeHaiku, .gteLargeHaikuV2: return true
        default: return false
        }
    }
    /// Whether threshold applies (only embedding-based cosine similarity pipelines)
    private var thresholdApplies: Bool {
        switch selectedPipeline {
        case .gteLargeEmbedding, .qwen3Embedding: return true
        default: return false
        }
    }

    /// Check if the required models for current selections are downloaded
    private var requiredModelsAvailable: Bool {
        var keys: [String] = []
        // Embedding model
        if let embKey = resolvedEmbeddingKey {
            keys.append(embKey)
        }
        // Reranker model
        if pipelineUsesReranker {
            keys.append(resolvedRerankerKey)
        }
        // Generative judge model
        if pipelineUsesLocalJudge {
            keys.append(resolvedGenerativeKey)
        }
        // GTE-Large for Haiku pipelines
        if selectedPipeline == .gteLargeHaiku || selectedPipeline == .gteLargeHaikuV2 {
            keys.append("gte-large")
        }
        return keys.allSatisfy { appState.modelManager.state(for: $0).isAvailable }
    }

    /// Resolved model keys based on benchmark-local size selections
    private var resolvedEmbeddingKey: String? {
        switch selectedPipeline {
        case .gteLargeEmbedding, .gteLargeHaiku, .gteLargeHaikuV2: return "gte-large"
        case .qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM:
            return ModelFamily.qwen3Embedding.modelKey(for: embeddingSize)
        default: return nil
        }
    }
    private var resolvedRerankerKey: String {
        ModelFamily.qwen3Reranker.modelKey(for: rerankerSize) ?? "qwen3-reranker-0.6b"
    }
    private var resolvedGenerativeKey: String {
        ModelFamily.qwen3Generative.modelKey(for: generativeSize) ?? "qwen3-judge-4b-4bit"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Section header with run button
            HStack {
                Text("RUN BENCHMARK")
                    .technicalLabel()
                Spacer()
                if isRunning {
                    runProgressCompact
                } else {
                    Button {
                        runBenchmark()
                    } label: {
                        Label("Run", systemImage: "play")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!requiredModelsAvailable)
                }
            }

            // Section 1: Pipeline + Threshold
            pipelineSection

            // Section 2: Model Configuration
            if pipelineUsesQwen3Embedding || pipelineUsesReranker || pipelineUsesLocalJudge || pipelineUsesTopK {
                modelConfigSection
            }

            // Section 3: Instructions
            instructionSection

            // Section 4: Quick Test + Run Options
            quickTestSection

            // Progress (expanded, when running)
            if isRunning {
                runProgressExpanded
            }

            // Missing model warning
            if !requiredModelsAvailable {
                warningBanner(
                    icon: "exclamationmark.triangle",
                    message: "Required models not downloaded. Go to Settings > Models to download.",
                    color: .orange
                )
            }

            // Error display
            if let error = runError {
                warningBanner(
                    icon: "xmark.circle",
                    message: error,
                    color: .red
                )
            }
        }
    }

    // MARK: - Section 1: Pipeline Selection + Threshold

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.lg) {
                // Pipeline picker
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("PIPELINE")
                        .technicalLabel()
                    Picker("", selection: $selectedPipeline) {
                        ForEach(PipelineType.allCases.filter { $0.isImplemented }) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 200)
                }

                // Threshold
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("THRESHOLD")
                        .technicalLabel()
                        .opacity(thresholdApplies ? 1.0 : 0.4)
                    HStack(spacing: Spacing.xs) {
                        Slider(value: $threshold, in: 0.3...1.0, step: 0.05)
                            .frame(width: 120)
                            .disabled(!thresholdApplies)
                        Text(threshold, format: .percent.precision(.fractionLength(0)))
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                            .frame(width: 36)
                            .foregroundStyle(thresholdApplies ? .primary : .tertiary)
                    }
                }

                Spacer()
            }

            // Pipeline description
            Text(selectedPipeline.shortDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !thresholdApplies {
                Text("Threshold is not used by this pipeline type.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Section 2: Model Configuration

    private var modelConfigSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("MODEL CONFIGURATION")
                .technicalLabel()

            // Model size pickers
            if pipelineUsesQwen3Embedding {
                benchmarkModelSizePicker(
                    label: "Embedding",
                    family: .qwen3Embedding,
                    selection: $embeddingSize
                )
            }

            if pipelineUsesReranker {
                benchmarkModelSizePicker(
                    label: "Reranker",
                    family: .qwen3Reranker,
                    selection: $rerankerSize
                )
            }

            if pipelineUsesLocalJudge {
                benchmarkModelSizePicker(
                    label: "Judge",
                    family: .qwen3Generative,
                    selection: $generativeSize
                )
            }

            // Top-K + Judge format row
            if pipelineUsesTopK || pipelineUsesLocalJudge {
                Divider()
                    .padding(.vertical, Spacing.xxs)

                HStack(spacing: Spacing.xl) {
                    // Top-K candidates
                    if pipelineUsesTopK {
                        HStack(spacing: Spacing.xs) {
                            Text("Top-K")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Stepper(value: $topK, in: 3...50, step: 1) {
                                Text("\(topK)")
                                    .font(.system(.subheadline, design: .monospaced))
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .frame(width: 110)
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help("Number of candidates the embedding stage passes to the second stage (reranker, LLM, or Haiku). Higher = more thorough but slower.")
                        }
                    }

                    // Judge response format
                    if pipelineUsesLocalJudge {
                        HStack(spacing: Spacing.xs) {
                            Text("Format")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $judgeResponseFormat) {
                                ForEach(JudgeResponseFormat.allCases) { format in
                                    Text(format.displayName).tag(format)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 230)
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help("How the LLM labels and selects candidates. Letter (A-Z, max 26). Number (1-N, any count). Text (full name, needs fuzzy matching).")
                        }

                        // Think mode toggle
                        Toggle("Think", isOn: $allowThinking)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .help("Allow model to reason before answering. Slower but may improve accuracy, especially with 4B model.")
                    }

                    Spacer()
                }
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Model Size Picker (benchmark-local)

    private func benchmarkModelSizePicker(
        label: String,
        family: ModelFamily,
        selection: Binding<ModelSize>
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

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

            // Download indicator
            let key: String? = family.modelKey(for: selection.wrappedValue)
            if let k = key, !appState.modelManager.state(for: k).isAvailable {
                Label("Not downloaded", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
    }

    // MARK: - Section 3: Instructions

    private var instructionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Text("INSTRUCTIONS")
                    .technicalLabel()

                Spacer()

                Picker("", selection: $selectedPreset) {
                    ForEach(InstructionPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: selectedPreset) { _, newValue in
                    if newValue != .custom {
                        customEmbeddingInstruction = newValue.embeddingInstruction
                        customRerankerInstruction = newValue.rerankerInstruction
                        customJudgeInstruction = newValue.judgeInstruction
                    }
                }

                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Instructions tell each model what kind of matching to perform. Different presets optimize for food identity, preparation methods, ingredients, etc.")
            }

            if selectedPreset == .custom {
                // 3 separate instruction fields
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    instructionField(
                        label: "Embedding Instruction",
                        text: $customEmbeddingInstruction,
                        enabled: pipelineUsesEmbedding,
                        helpText: "Short task instruction for the embedding model. Positions the query in vector space for semantic search.",
                        placeholder: "e.g., Given a food description, retrieve the most similar standardized food item"
                    )

                    instructionField(
                        label: "Reranker Instruction",
                        text: $customRerankerInstruction,
                        enabled: pipelineUsesReranker,
                        helpText: "Instruction for the cross-encoder reranker. Guides how it judges relevance between query and candidate pairs.",
                        placeholder: "e.g., Determine if the document describes the same food item as the query..."
                    )

                    instructionField(
                        label: "Judge Instruction",
                        text: $customJudgeInstruction,
                        enabled: pipelineUsesJudge,
                        helpText: "Instruction for the LLM judge or Claude API. Provides domain context for final selection from candidates.",
                        placeholder: "e.g., You are a food science expert matching dietary survey responses..."
                    )

                    // Load from preset button
                    Menu {
                        ForEach(InstructionPreset.allCases.filter { $0 != .custom }) { preset in
                            Button(preset.displayName) {
                                customEmbeddingInstruction = preset.embeddingInstruction
                                customRerankerInstruction = preset.rerankerInstruction
                                customJudgeInstruction = preset.judgeInstruction
                            }
                        }
                    } label: {
                        Label("Load from Preset", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } else {
                Text(selectedPreset.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Section 4: Quick Test

    private var quickTestSection: some View {
        HStack(spacing: Spacing.md) {
            Toggle("Quick test", isOn: $quickTestEnabled)
                .font(.callout)
                .toggleStyle(.checkbox)

            if quickTestEnabled {
                Picker("", selection: $quickTestSize) {
                    Text("25 items").tag(25)
                    Text("50 items").tag(50)
                    Text("100 items").tag(100)
                }
                .labelsHidden()
                .frame(width: 100)
            }

            Spacer()

            if quickTestEnabled {
                Text("Runs first \(quickTestSize) items only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Instruction Field

    private func instructionField(
        label: String,
        text: Binding<String>,
        enabled: Bool,
        helpText: String,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(enabled ? .secondary : .tertiary)
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(helpText)
                if !enabled {
                    Text("(not used by this pipeline)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 56, maxHeight: 96)
                    .scrollContentBackground(.hidden)
                    .disabled(!enabled)
                    .opacity(enabled ? 1.0 : 0.4)
                if text.wrappedValue.isEmpty && enabled {
                    Text(placeholder)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(enabled ? 0.12 : 0.06), lineWidth: 1)
            )
        }
    }

    // MARK: - Warning Banner

    private func warningBanner(icon: String, message: String, color: Color) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(message)
                .font(.callout)
                .foregroundStyle(color == .red ? color : .secondary)
            Spacer()
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.cardBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(colorScheme == .dark ? 0.3 : 0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Compact Progress (in header)

    private var runProgressCompact: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView(value: progress)
                .frame(width: 80)
            Text("\(itemsCompleted)/\(itemsTotal)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Cancel") {
                cancelBenchmark()
            }
            .controlSize(.mini)
        }
    }

    // MARK: - Expanded Progress (when running)

    private var runProgressExpanded: some View {
        VStack(spacing: Spacing.sm) {
            ProgressView(value: progress)
                .frame(maxWidth: .infinity)

            HStack(spacing: Spacing.lg) {
                // Phase indicator
                HStack(spacing: Spacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing items...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Stats row
                HStack(spacing: Spacing.md) {
                    if elapsedSeconds > 0 {
                        Label(String(format: "%.0fs", elapsedSeconds), systemImage: "clock")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    Text("\(itemsCompleted) of \(itemsTotal)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    if itemsCompleted > 5 && itemsTotal > 0 {
                        let accuracy = Double(runningCorrect) / Double(itemsCompleted)
                        HStack(spacing: Spacing.xxxs) {
                            Text("Accuracy:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", accuracy * 100))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(accuracy >= 0.7 ? .green : .orange)
                        }
                    }
                }
            }

            // ETA
            if itemsCompleted > 3 && itemsTotal > itemsCompleted && elapsedSeconds > 0 {
                let rate = elapsedSeconds / Double(itemsCompleted)
                let remaining = rate * Double(itemsTotal - itemsCompleted)
                Text("Estimated \(String(format: "%.0fs", remaining)) remaining")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    // MARK: - Run Benchmark

    private func runBenchmark() {
        guard let dataset = appState.benchmarkDatasets.first(where: { $0.id == datasetId }) else { return }

        isRunning = true
        progress = 0
        runError = nil
        itemsCompleted = 0
        runningCorrect = 0
        elapsedSeconds = 0
        runStartTime = Date()

        // Capture benchmark-local settings
        let capturedTopK = topK
        let capturedEmbeddingKey = resolvedEmbeddingKey
        let capturedRerankerKey = resolvedRerankerKey
        let capturedGenerativeKey = resolvedGenerativeKey
        let capturedFormat = judgeResponseFormat
        let capturedThinking = allowThinking
        let capturedEmbSize = embeddingSize
        let capturedRerSize = rerankerSize
        let capturedGenSize = generativeSize

        benchmarkLogger.info("[Benchmark] Starting run: pipeline=\(selectedPipeline.rawValue) topK=\(capturedTopK) format=\(capturedFormat.rawValue) think=\(capturedThinking)")
        benchmarkLogger.info("[Benchmark] Models: embedding=\(capturedEmbeddingKey ?? "none") reranker=\(capturedRerankerKey) generative=\(capturedGenerativeKey)")

        // Start elapsed timer
        timerTask = Task { @MainActor in
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled && isRunning else { break }
                if let start = runStartTime {
                    elapsedSeconds = Date().timeIntervalSince(start)
                }
            }
        }

        benchmarkTask = Task { @MainActor in
            do {
                // Re-parse the dataset to get the items
                let parseResult: BenchmarkCSVParser.ParseResult
                switch datasetSource {
                case .bundled(let filename):
                    guard let benchDir = Bundle.main.url(forResource: "Benchmarks", withExtension: nil) else {
                        throw AppError.fileLoadFailed("Benchmarks folder not found in bundle")
                    }
                    let url = benchDir.appendingPathComponent(filename)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw AppError.fileLoadFailed("Bundled file not found: \(filename)")
                    }
                    parseResult = try BenchmarkCSVParser.parse(url: url, source: datasetSource)
                case .imported(let url):
                    parseResult = try BenchmarkCSVParser.parse(url: url, source: datasetSource)
                }

                var items = parseResult.items
                if quickTestEnabled {
                    items = Array(items.prefix(quickTestSize))
                }
                itemsTotal = items.count
                let inputTexts = items.map { $0.inputText }

                // Resolve the target database
                let database: AnyDatabase
                let databaseName: String
                switch dataset.targetDatabase {
                case .foodb:
                    database = .builtIn(.fooDB)
                    databaseName = "FooDB"
                case .dfg2:
                    database = .builtIn(.dfg2)
                    databaseName = "DFG2"
                case .both, .custom:
                    database = appState.selectedDatabase ?? .builtIn(.fooDB)
                    databaseName = appState.selectedDatabase?.displayName ?? "FooDB"
                }

                // Create pipeline engine with the benchmark-selected embedding model
                let engine = try await MatchingEngine()
                if let embeddingKey = capturedEmbeddingKey {
                    benchmarkLogger.info("[Benchmark] Loading embedding model: \(embeddingKey)")
                    let model = try await appState.modelManager.loadEmbeddingModel(key: embeddingKey)
                    await engine.setEmbeddingModel(model)
                }

                // Create pipeline with benchmark-local model keys and judge settings
                benchmarkLogger.info("[Benchmark] Creating pipeline: \(selectedPipeline.rawValue)")
                let pipeline = try await appState.createPipeline(
                    type: selectedPipeline,
                    engine: engine,
                    rerankerKey: capturedRerankerKey,
                    generativeKey: capturedGenerativeKey,
                    judgeResponseFormat: capturedFormat,
                    allowThinking: capturedThinking
                )

                // Apply top-K override via hardware config
                let hwConfig = appState.effectiveHardwareConfig.withOverrides(
                    topKForReranking: capturedTopK
                )

                // Resolve instructions per pipeline type
                let embeddingInstruction: String?
                let secondStageInstruction: String?
                if selectedPreset == .custom {
                    let embTrimmed = customEmbeddingInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rerTrimmed = customRerankerInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    let judgeTrimmed = customJudgeInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                    embeddingInstruction = embTrimmed.isEmpty ? nil : embTrimmed
                    switch selectedPipeline {
                    case .gteLargeHaikuV2:
                        // V2 prompt is self-contained; only honor explicit custom text
                        secondStageInstruction = judgeTrimmed.isEmpty ? nil : judgeTrimmed
                    case .gteLargeHaiku, .qwen3LLMOnly, .embeddingLLM:
                        secondStageInstruction = judgeTrimmed.isEmpty ? nil : judgeTrimmed
                    default:
                        secondStageInstruction = rerTrimmed.isEmpty ? nil : rerTrimmed
                    }
                } else {
                    embeddingInstruction = selectedPreset.embeddingInstruction
                    switch selectedPipeline {
                    case .gteLargeHaikuV2:
                        // V2 prompt is self-contained; presets don't inject additional text
                        secondStageInstruction = nil
                    case .gteLargeHaiku:
                        secondStageInstruction = selectedPreset.haikuPrompt
                    case .qwen3LLMOnly, .embeddingLLM:
                        secondStageInstruction = selectedPreset.judgeInstruction
                    default:
                        secondStageInstruction = selectedPreset.rerankerInstruction
                    }
                }

                benchmarkLogger.info("[Benchmark] Embedding instruction: \(embeddingInstruction?.prefix(80) ?? "(default)")")
                benchmarkLogger.info("[Benchmark] Second-stage instruction: \(secondStageInstruction?.prefix(80) ?? "(default)")")

                // Run the pipeline
                let startTime = Date()
                let totalItems = inputTexts.count
                let matchResults = try await pipeline.match(
                    inputs: inputTexts,
                    database: database,
                    threshold: threshold,
                    hardwareConfig: hwConfig,
                    instruction: embeddingInstruction,
                    rerankerInstruction: secondStageInstruction,
                    onProgress: { completed in
                        Task { @MainActor in
                            self.itemsCompleted = completed
                            self.progress = Double(completed) / Double(totalItems)
                        }
                    },
                    onPhaseChange: nil
                )
                let duration = Date().timeIntervalSince(startTime)

                benchmarkLogger.info("[Benchmark] Complete: \(totalItems) items in \(String(format: "%.1f", duration))s")

                // Evaluate results
                let config = BenchmarkRunConfig(
                    datasetId: datasetId,
                    pipelineType: selectedPipeline,
                    instructionPreset: selectedPreset,
                    threshold: threshold,
                    subsetSize: quickTestEnabled ? quickTestSize : nil,
                    topK: capturedTopK,
                    embeddingSize: capturedEmbSize,
                    rerankerSize: capturedRerSize,
                    generativeSize: capturedGenSize,
                    judgeResponseFormat: capturedFormat,
                    allowThinking: capturedThinking
                )
                let runner = BenchmarkRunner()
                let result = await runner.evaluate(
                    items: items,
                    matchResults: matchResults,
                    config: config,
                    datasetName: dataset.name,
                    databaseName: databaseName,
                    duration: duration
                )

                // Persist and update state
                appState.saveBenchmarkResult(result)
                appState.latestBenchmarkResult = result

                isRunning = false
                timerTask?.cancel()
                progress = 1.0

            } catch is CancellationError {
                await appState.modelManager.unloadGenerativeModel()
                MLX.Memory.clearCache()
                runError = nil
                isRunning = false
                timerTask?.cancel()
            } catch {
                benchmarkLogger.error("[Benchmark] Error: \(error.localizedDescription)")
                runError = error.localizedDescription
                isRunning = false
                timerTask?.cancel()
            }
        }
    }

    private func cancelBenchmark() {
        benchmarkTask?.cancel()
        benchmarkTask = nil
        timerTask?.cancel()
        timerTask = nil
        isRunning = false
    }

}

#Preview("Benchmark Runner") {
    BenchmarkRunnerView(datasetId: UUID(), datasetSource: .imported(url: URL(fileURLWithPath: "/tmp/test.csv")))
        .environmentObject(PreviewHelpers.emptyState())
        .padding()
        .frame(width: 700)
}

#Preview("Benchmark Runner - Dark") {
    BenchmarkRunnerView(datasetId: UUID(), datasetSource: .imported(url: URL(fileURLWithPath: "/tmp/test.csv")))
        .environmentObject(PreviewHelpers.emptyState())
        .padding()
        .frame(width: 700)
        .preferredColorScheme(.dark)
}
