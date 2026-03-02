import SwiftUI

/// Lists all pipeline types with descriptions, required models, and availability.
struct PipelineOverviewView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Page header
            HStack {
                Label("Pipeline Overview", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
            }
            .frame(height: HeaderLayout.height)
            .padding(.horizontal, Spacing.lg)

            Divider()

            ScrollView {
                VStack(spacing: Spacing.xxl) {
                    // Group by pipeline mode
                    ForEach(PipelineMode.allCases) { mode in
                        modeSection(mode)
                    }
                }
                .padding(Spacing.lg)
            }
        }
    }

    @ViewBuilder
    private func modeSection(_ mode: PipelineMode) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Section header
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(mode == .standard ? "STANDARD PIPELINES" : "RESEARCH PIPELINES")
                    .technicalLabel()

                Text(modeDescription(mode))
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, Spacing.xxs)

            ForEach(mode.availablePipelineTypes) { pipeline in
                PipelineCard(
                    pipeline: pipeline,
                    isSelected: appState.selectedPipelineType == pipeline,
                    modelManager: appState.modelManager,
                    colorScheme: colorScheme
                )
            }

            // Haiku pipeline is special (not in availablePipelineTypes)
            if mode == .researchValidation {
                PipelineCard(
                    pipeline: .gteLargeHaiku,
                    isSelected: appState.selectedPipelineType == .gteLargeHaiku,
                    modelManager: appState.modelManager,
                    colorScheme: colorScheme
                )
            }
        }
    }

    private func modeDescription(_ mode: PipelineMode) -> String {
        switch mode {
        case .standard:
            return "Production matching pipelines using Qwen3 models. Run entirely on-device via MLX."
        case .researchValidation:
            return "Paper validation using GTE-Large embeddings with optional Claude API verification."
        }
    }
}

// MARK: - Pipeline Card

private struct PipelineCard: View {
    let pipeline: PipelineType
    let isSelected: Bool
    let modelManager: ModelManager
    let colorScheme: ColorScheme

    private var isAvailable: Bool {
        pipeline.requiredModelKeys.allSatisfy { key in
            modelManager.state(for: key).isAvailable
        }
    }

    /// SF Symbol icon per pipeline type for quick visual identification
    private var pipelineIcon: String {
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
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Title row
            HStack(spacing: Spacing.sm) {
                Image(systemName: pipelineIcon)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: Size.iconMedium)

                Text(pipeline.displayName)
                    .font(.headline)

                if isSelected {
                    Text("Active")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxxs)
                        .background(Color.badgeBackground(for: colorScheme))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }

                Spacer()

                // Availability indicator
                HStack(spacing: Spacing.xs) {
                    Circle()
                        .fill(isAvailable ? Color.green : Color.orange.opacity(0.6))
                        .frame(width: Size.statusDot, height: Size.statusDot)
                    Text(isAvailable ? "Ready" : "Models needed")
                        .font(.caption)
                        .foregroundStyle(isAvailable ? Color.secondary : Color.orange)
                }
            }

            // Description
            Text(pipeline.shortDescription)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            // Performance warning
            if let warning = pipeline.performanceWarning {
                HStack(alignment: .top, spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(width: Size.iconSmall)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Models and metadata container
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Required models row
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("REQUIRED MODELS")
                        .font(.system(.caption2, weight: .medium))
                        .tracking(1.0)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)

                    // Wrap model pills in a flowing layout
                    HStack(spacing: Spacing.xs) {
                        ForEach(pipeline.requiredModelKeys, id: \.self) { key in
                            modelPill(key: key)
                        }

                        if pipeline.requiresAPIKey {
                            HStack(spacing: Spacing.xxs) {
                                Image(systemName: "key")
                                    .font(.caption2)
                                Text("API Key")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.xxs)
                            .background(Color.purple.opacity(0.1))
                            .foregroundStyle(.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }

                Divider().opacity(0.5)

                // Score type and instruction support
                HStack(spacing: Spacing.lg) {
                    HStack(spacing: Spacing.xxs) {
                        Text("Score:")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(scoreTypeLabel(pipeline.defaultScoreType))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if pipeline.supportsCustomInstruction {
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "text.quote")
                                .font(.caption2)
                            Text("Custom instructions")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(Spacing.lg)
        .premiumMaterialStyle(cornerRadius: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.6) : Color.clear,
                    lineWidth: isSelected ? 1.5 : 0
                )
        )
    }

    private func modelPill(key: String) -> some View {
        let state = modelManager.state(for: key)
        let name = modelManager.registeredModel(for: key)?.displayName ?? key

        return HStack(spacing: Spacing.xxs) {
            Circle()
                .fill(state.isAvailable ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    state.isAvailable
                        ? Color.green.opacity(0.2)
                        : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
        )
    }

    private func scoreTypeLabel(_ scoreType: ScoreType) -> String {
        switch scoreType {
        case .cosineSimilarity: return "Cosine Similarity"
        case .rerankerProbability: return "Reranker Probability"
        case .llmSelected: return "LLM Selected"
        case .generativeSelection: return "Generative Selection"
        case .llmRejected: return "LLM Rejected"
        case .apiFallback: return "API Fallback"
        case .noScore: return "None"
        }
    }
}

// MARK: - Previews

#Preview("Pipeline Overview - Light") {
    PipelineOverviewView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 900, height: 700)
}

#Preview("Pipeline Overview - Dark") {
    PipelineOverviewView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 900, height: 700)
        .preferredColorScheme(.dark)
}
