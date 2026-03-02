import SwiftUI

/// Editable pipeline configuration: instructions per tier, thresholds, model sizes.
/// Changes are persisted to UserDefaults and apply to matching runs.
struct PipelineConfigurationView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPipeline: PipelineType = .qwen3TwoStage

    /// SF Symbol icon per pipeline type for the sidebar list
    private func pipelineIcon(for pipeline: PipelineType) -> String {
        switch pipeline {
        case .gteLargeEmbedding: return "cube"
        case .qwen3Embedding: return "arrow.triangle.branch"
        case .qwen3Reranker: return "arrow.triangle.swap"
        case .qwen3TwoStage: return "square.stack.3d.up"
        case .gteLargeHaiku: return "cloud"
        case .gteLargeHaikuV2: return "cloud.bolt"
        case .qwen3SmartTriage: return "checklist"
        case .qwen3LLMOnly: return "brain"
        case .embeddingLLM: return "cpu"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Page header
            HStack {
                Label("Pipeline Configuration", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
            }
            .frame(height: HeaderLayout.height)
            .padding(.horizontal, Spacing.lg)

            Divider()

            HSplitView {
                // Left: pipeline list
                pipelineList
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

                // Right: configuration detail
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        pipelineHeader
                        modelSizeSection
                        instructionSection
                        thresholdSection
                        if appState.isAdvancedMode {
                            performanceSection
                        }
                    }
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Pipeline List

    private var pipelineList: some View {
        List(selection: $selectedPipeline) {
            Section {
                ForEach(PipelineMode.standard.availablePipelineTypes) { pipeline in
                    pipelineRow(pipeline)
                }
            } header: {
                Text("FOOD MATCHING")
                    .technicalLabel()
            }

            Section {
                ForEach(PipelineMode.researchValidation.availablePipelineTypes) { pipeline in
                    pipelineRow(pipeline)
                }
                pipelineRow(.gteLargeHaiku)
            } header: {
                Text("RESEARCH METHODS")
                    .technicalLabel()
            }
        }
        .listStyle(.sidebar)
    }

    private func pipelineRow(_ pipeline: PipelineType) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: pipelineIcon(for: pipeline))
                .font(.caption)
                .foregroundStyle(selectedPipeline == pipeline ? .primary : .secondary)
                .frame(width: Size.iconSmall)

            Text(pipeline.displayName)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            if appState.selectedPipelineType == pipeline {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .tag(pipeline)
    }

    // MARK: - Pipeline Header

    private var pipelineHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: pipelineIcon(for: selectedPipeline))
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(selectedPipeline.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)

                if appState.selectedPipelineType == selectedPipeline {
                    Text("Active")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxxs)
                        .background(Color.badgeBackground(for: colorScheme))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
            }

            Text(selectedPipeline.shortDescription)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if let warning = selectedPipeline.performanceWarning {
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .frame(width: Size.iconSmall)
                    Text(warning)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - Model Size Section

    @ViewBuilder
    private var modelSizeSection: some View {
        let families = modelFamilies(for: selectedPipeline)

        if !families.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Section header
                HStack {
                    Text("MODEL SIZES")
                        .technicalLabel()
                    Spacer()
                    Image(systemName: "cpu")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.5)

                VStack(spacing: Spacing.md) {
                    ForEach(families, id: \.family) { entry in
                        modelSizeRow(entry)
                    }
                }
            }
            .padding(Spacing.md)
            .premiumMaterialStyle(cornerRadius: 8)
        }
    }

    private func modelSizeRow(_ entry: ModelFamilyEntry) -> some View {
        HStack(spacing: Spacing.md) {
            Text(entry.family.rawValue)
                .font(.subheadline)
                .fontWeight(.medium)
                .frame(minWidth: 140, alignment: .leading)

            Picker("", selection: entry.sizeBinding) {
                ForEach(entry.family.availableSizes) { size in
                    let key = entry.family.modelKey(for: size) ?? ""
                    let available = appState.modelManager.state(for: key).isAvailable
                    HStack {
                        Text(size.displayName)
                        if !available {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(size)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            let resolvedKey = entry.family.modelKey(for: entry.sizeBinding.wrappedValue) ?? ""
            let isAvailable = appState.modelManager.state(for: resolvedKey).isAvailable

            HStack(spacing: Spacing.xxs) {
                Circle()
                    .fill(isAvailable ? Color.green : Color.orange.opacity(0.6))
                    .frame(width: Size.statusDot, height: Size.statusDot)
                Text(isAvailable ? "Downloaded" : "Not downloaded")
                    .font(.caption)
                    .foregroundStyle(isAvailable ? Color.secondary : Color.orange)
            }

            Spacer()
        }
        .padding(.vertical, Spacing.xxs)
    }

    // MARK: - Instruction Section

    @ViewBuilder
    private var instructionSection: some View {
        if selectedPipeline.supportsCustomInstruction {
            VStack(alignment: .leading, spacing: Spacing.md) {
                // Section header
                HStack {
                    Text("MATCHING INSTRUCTIONS")
                        .technicalLabel()
                    Spacer()
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.5)

                // Preset picker
                HStack(spacing: Spacing.md) {
                    Text("Preset")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .frame(minWidth: 140, alignment: .leading)

                    Picker("", selection: $appState.selectedInstructionPreset) {
                        ForEach(InstructionPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .frame(maxWidth: 220)

                    Spacer()
                }

                // Show resolved instructions per tier
                if appState.selectedInstructionPreset != .custom {
                    instructionTiers
                } else {
                    // Custom instruction editor
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Custom instruction (applied to all tiers)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $appState.customInstructionText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120, maxHeight: 200)
                            .scrollContentBackground(.hidden)
                            .padding(Spacing.sm)
                            .background(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.5)
                            )
                    }
                }
            }
            .padding(Spacing.md)
            .premiumMaterialStyle(cornerRadius: 8)
        }
    }

    @ViewBuilder
    private var instructionTiers: some View {
        let tiers = activeTiers(for: selectedPipeline)

        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(tiers, id: \.name) { tier in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(tier.name.uppercased())
                        .font(.system(.caption2, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(.secondary)

                    Text(tier.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: - Threshold Section

    private var thresholdSection: some View {
        let profile = ThresholdProfile.defaults(for: selectedPipeline)

        return VStack(alignment: .leading, spacing: Spacing.md) {
            // Section header
            HStack {
                Text("TRIAGE THRESHOLDS")
                    .technicalLabel()
                Spacer()
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider().opacity(0.5)

            VStack(spacing: Spacing.md) {
                thresholdRow("Match", value: profile.matchThreshold, color: .green,
                             help: "Score bar color breakpoint for visual scoring")
            }

            Text("Score bar color breakpoint. Categories are determined by pipeline decisions, not thresholds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 8)
    }

    private func thresholdRow(_ label: String, value: Double, color: Color, help: String) -> some View {
        HStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(color)
                    .frame(width: Size.statusDot, height: Size.statusDot)
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .frame(width: 80, alignment: .leading)

            Text(String(format: "%.2f", value))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Visual bar representation
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.5))
                        .frame(width: geo.size.width * CGFloat(value), height: 4)
                }
                .frame(maxWidth: .infinity)
                .frame(height: geo.size.height)
            }
            .frame(maxWidth: 120, maxHeight: 20)

            Spacer()
        }
        .help(help)
    }

    // MARK: - Performance Section

    @ViewBuilder
    private var performanceSection: some View {
        if selectedPipeline.hasEmbeddingStage {
            let pipeline = selectedPipeline
            let modelKey = resolvedEmbeddingModelKey(for: pipeline)

            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Text("PERFORMANCE")
                        .technicalLabel()
                    Spacer()
                    Image(systemName: "gauge.with.needle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.5)

                VStack(spacing: Spacing.md) {
                    performancePicker(
                        label: "Candidates per Input (Top-K)",
                        options: HardwareConfig.topKOptions,
                        defaultValue: pipeline.defaultTopK,
                        keyPath: \.topK,
                        pipeline: pipeline,
                        help: "Number of candidates retrieved before reranking. Higher values improve accuracy but increase processing time."
                    )

                    performancePicker(
                        label: "Embedding Batch Size",
                        options: HardwareConfig.embeddingBatchSizeOptions,
                        defaultValue: pipeline.defaultEmbeddingBatchSize(modelKey: modelKey),
                        keyPath: \.embeddingBatchSize,
                        pipeline: pipeline,
                        help: "Embeddings computed per GPU pass. Lower values use less memory."
                    )

                    performancePicker(
                        label: "Matching Batch Size",
                        options: HardwareConfig.matchingBatchSizeOptions,
                        defaultValue: pipeline.defaultMatchingBatchSize,
                        keyPath: \.matchingBatchSize,
                        pipeline: pipeline,
                        help: "Cosine similarity comparisons per pass. Lower values use less memory."
                    )

                    performancePicker(
                        label: "Memory Chunk Size",
                        options: HardwareConfig.chunkSizeOptions,
                        defaultValue: pipeline.defaultChunkSize,
                        keyPath: \.chunkSize,
                        pipeline: pipeline,
                        help: "Database entries processed per chunk. Lower values use less memory."
                    )
                }

                let overrides = appState.pipelinePerformanceOverrides[pipeline.rawValue]
                if overrides?.hasOverrides == true {
                    Button("Reset to Defaults") {
                        appState.resetPipelinePerformance(for: pipeline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("Tune GPU batch sizes and candidate counts for this pipeline. Defaults are set based on your hardware and selected model size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.md)
            .premiumMaterialStyle(cornerRadius: 8)
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Text("PERFORMANCE")
                        .technicalLabel()
                    Spacer()
                    Image(systemName: "gauge.with.needle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider().opacity(0.5)

                Text("No configurable performance settings for this pipeline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.md)
            .premiumMaterialStyle(cornerRadius: 8)
        }
    }

    private func performancePicker(
        label: String,
        options: [Int],
        defaultValue: Int,
        keyPath: WritableKeyPath<PipelinePerformanceConfig, Int?>,
        pipeline: PipelineType,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.md) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .frame(minWidth: 140, alignment: .leading)

                Picker("", selection: Binding(
                    get: {
                        let overrides = appState.pipelinePerformanceOverrides[pipeline.rawValue]
                        return overrides?[keyPath: keyPath] ?? defaultValue
                    },
                    set: { newVal in
                        var overrides = appState.pipelinePerformanceOverrides[pipeline.rawValue] ?? PipelinePerformanceConfig()
                        if newVal == defaultValue {
                            overrides[keyPath: keyPath] = nil
                        } else {
                            overrides[keyPath: keyPath] = newVal
                        }
                        // Clean up if no overrides remain
                        if !overrides.hasOverrides {
                            appState.pipelinePerformanceOverrides.removeValue(forKey: pipeline.rawValue)
                        } else {
                            appState.pipelinePerformanceOverrides[pipeline.rawValue] = overrides
                        }
                    }
                )) {
                    ForEach(options, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 86)

                let isOverridden = appState.pipelinePerformanceOverrides[pipeline.rawValue]?[keyPath: keyPath] != nil
                if isOverridden {
                    Text("(default: \(defaultValue))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Resolve the embedding model key for the selected pipeline (for performance defaults)
    private func resolvedEmbeddingModelKey(for pipeline: PipelineType) -> String? {
        switch pipeline {
        case .gteLargeEmbedding, .gteLargeHaiku, .gteLargeHaikuV2: return "gte-large"
        case .qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM:
            return appState.selectedEmbeddingModelKey
        case .qwen3Reranker, .qwen3LLMOnly: return nil
        }
    }

    // MARK: - Helpers

    /// Determines which model families are configurable for a given pipeline.
    private func modelFamilies(for pipeline: PipelineType) -> [ModelFamilyEntry] {
        var entries: [ModelFamilyEntry] = []

        switch pipeline {
        case .qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM:
            entries.append(ModelFamilyEntry(
                family: .qwen3Embedding,
                sizeBinding: $appState.selectedEmbeddingSize
            ))
        default:
            break
        }

        switch pipeline {
        case .qwen3Reranker, .qwen3TwoStage, .qwen3SmartTriage:
            entries.append(ModelFamilyEntry(
                family: .qwen3Reranker,
                sizeBinding: $appState.selectedRerankerSize
            ))
        default:
            break
        }

        switch pipeline {
        case .qwen3LLMOnly, .embeddingLLM:
            entries.append(ModelFamilyEntry(
                family: .qwen3Generative,
                sizeBinding: $appState.selectedGenerativeSize
            ))
        default:
            break
        }

        return entries
    }

    /// Instruction tiers active for a given pipeline type.
    private func activeTiers(for pipeline: PipelineType) -> [InstructionTier] {
        let preset = appState.selectedInstructionPreset
        var tiers: [InstructionTier] = []

        switch pipeline {
        case .gteLargeEmbedding:
            break // GTE-Large has no instruction support
        case .qwen3Embedding:
            tiers.append(InstructionTier(name: "Embedding", text: preset.embeddingInstruction))
        case .qwen3Reranker:
            tiers.append(InstructionTier(name: "Reranker", text: preset.rerankerInstruction))
        case .qwen3TwoStage, .qwen3SmartTriage:
            tiers.append(InstructionTier(name: "Embedding", text: preset.embeddingInstruction))
            tiers.append(InstructionTier(name: "Reranker", text: preset.rerankerInstruction))
        case .gteLargeHaiku, .gteLargeHaikuV2:
            tiers.append(InstructionTier(name: "Haiku Prompt", text: preset.haikuPrompt))
        case .qwen3LLMOnly:
            tiers.append(InstructionTier(name: "Judge", text: preset.judgeInstruction))
        case .embeddingLLM:
            tiers.append(InstructionTier(name: "Embedding", text: preset.embeddingInstruction))
            tiers.append(InstructionTier(name: "Judge", text: preset.judgeInstruction))
        }

        return tiers
    }
}

// MARK: - Supporting Types

private struct ModelFamilyEntry {
    let family: ModelFamily
    let sizeBinding: Binding<ModelSize>
}

private struct InstructionTier {
    let name: String
    let text: String
}

// MARK: - Previews

#Preview("Pipeline Config - Light") {
    PipelineConfigurationView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 900, height: 700)
}

#Preview("Pipeline Config - Dark") {
    PipelineConfigurationView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 900, height: 700)
        .preferredColorScheme(.dark)
}
