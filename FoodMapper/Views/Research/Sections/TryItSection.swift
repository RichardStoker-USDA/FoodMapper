import SwiftUI

/// Section 5: Try It Yourself -- live embedding match and hybrid match
/// with flowing vertical content (both stages visible simultaneously).
struct TryItSection: View {
    var onScrollToNext: (() -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    // Embedding matching state
    @State private var embeddingState: ShowcaseEmbeddingState = .ready

    // Hybrid matching state
    @State private var hybridState: ShowcaseHybridState = .ready
    @State private var hybridStartTime: Date? = nil

    // Tour input items for ground truth comparison
    @State private var tourInputItems: [TourFoodItem] = []

    // Tour-local model selection (defaults to paper model, independent of global setting)
    @State private var tourModelSelection: ClaudeModelVersion = .haiku3
    @State private var completedModelVersion: ClaudeModelVersion?

    // Embedding timing
    @State private var embeddingStartTime: Date? = nil
    @State private var embeddingEndTime: Date? = nil

    // Pipeline stage timing
    @State private var embeddingCompletedTime: Date? = nil
    @State private var hybridCompletedTime: Date? = nil

    // API key entry
    @State private var apiKeyInput = ""
    @State private var apiKeySaved = false
    @State private var apiKeyValidating = false
    @State private var apiKeyError: String? = nil

    /// Shared fixed width for both "Run" action buttons.
    private let runActionButtonWidth: CGFloat = 252

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxl) {
            TourSectionHeader(
                "Try It Yourself",
                subtitle: "Run the matching pipeline on the paper's benchmark data"
            )

            Text("Run the local and optional Anthropic stages on the bundled NHANES-to-DFG2 demonstration (1,304 items against 256 targets). The NHANES-to-DFG2 task includes descriptions with no valid DFG2 entry.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            // Stage 1: Embedding Matching
            embeddingStageContent

            // Stage 2: Hybrid Matching
            hybridStageContent

            // Technical notes
            TourTechnicalDetail(title: "Implementation Notes") {
                implementationNotesContent
            }

            if let onScrollToNext {
                HStack {
                    Spacer()
                    SectionChevronButton { onScrollToNext() }
                    Spacer()
                }
                .padding(.top, Spacing.md)
            }
        }
        .task {
            do {
                tourInputItems = try await TourDataLoader.shared.loadFullBenchmarkItems()
            } catch {}
        }
        .onAppear {
            if appState.tourEmbeddingError != nil {
                embeddingState = .error
            } else if appState.tourEmbeddingResults != nil {
                embeddingState = .complete
            }
            if appState.tourHybridError != nil {
                hybridState = .error
            } else if appState.tourHybridResults != nil {
                hybridState = .complete
            }
        }
        .onChange(of: appState.tourEmbeddingResults) { _, newValue in
            if newValue != nil {
                embeddingEndTime = Date()
                embeddingState = .complete
            }
        }
        .onChange(of: appState.tourHybridResults) { _, newValue in
            if newValue != nil {
                hybridCompletedTime = Date()
                completedModelVersion = tourModelSelection
                hybridState = .complete
            }
        }
        .onChange(of: appState.tourHybridPhase) { oldValue, newValue in
            if case .embeddingInputs = oldValue, embeddingCompletedTime == nil {
                embeddingCompletedTime = Date()
            }
        }
        .onChange(of: appState.tourEmbeddingError) { _, newValue in
            if newValue != nil {
                embeddingState = .error
            }
        }
        .onChange(of: appState.tourHybridError) { _, newValue in
            if newValue != nil {
                hybridState = .error
            }
        }
    }

    // MARK: - Stage 1: Embedding Matching

    private var embeddingStageContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ShowcaseSectionBreak(number: 1, title: "Embedding Matching", icon: "cpu")

            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Run GTE-Large on the bundled NHANES-to-DFG2 demonstration. The default embedding stage runs locally through MLX on Apple Silicon.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.84))
                    .fixedSize(horizontal: false, vertical: true)

                Group {
                    switch embeddingState {
                    case .ready:
                        HStack {
                            Spacer()
                            Button {
                                runEmbeddingMatch()
                            } label: {
                                runActionButtonLabel(title: "Run Embedding Matching")
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            Spacer()
                        }

                    case .running:
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            HStack(spacing: Spacing.md) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Embedding 1,304 items...")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(appState.tourEmbeddingProgress * 100))%")
                                    .font(.body.monospacedDigit().weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: appState.tourEmbeddingProgress)
                                .progressViewStyle(.linear)
                                .tint(.accentColor)
                        }

                    case .complete:
                        embeddingResultsContent

                    case .error:
                        embeddingErrorView
                    }
                }
                .animation(Animate.smooth, value: embeddingState)
            }
            .padding(Spacing.lg)
            .showcaseCard(cornerRadius: 10)
        }
    }

    // MARK: - Stage 2: Hybrid Matching

    private var hybridStageContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ShowcaseSectionBreak(number: 2, title: "Hybrid Matching", icon: "cloud")

            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("The optional Anthropic path sends each input description and its retrieved candidate database entries to Claude for selection. It requires an Anthropic API key and an explicit run.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.84))
                    .fixedSize(horizontal: false, vertical: true)

                if appState.cachedHasAPIKey || apiKeySaved {
                    hybridReadyContent
                } else {
                    apiKeyOnboardingContent
                }
            }
            .padding(Spacing.lg)
            .showcaseCard(cornerRadius: 10)
        }
    }

    // MARK: - Embedding Results

    @ViewBuilder
    private var embeddingResultsContent: some View {
        if let results = appState.tourEmbeddingResults, !results.isEmpty {
            let correctCount = countCorrectMatches(results: results)
            let totalWithTruth = tourInputItems.filter { $0.hasMatch }.count

            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Embedding matching complete")
                            .font(.body.weight(.medium))
                        HStack(spacing: Spacing.xs) {
                            Text("using GTE-Large")
                                .font(.subheadline)
                                .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.82))
                            Text("Paper model")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .appBadgeStyle(tone: .accentStrong, cornerRadius: 999)
                            if let start = embeddingStartTime, let end = embeddingEndTime {
                                Text(formatDuration(from: start, to: end))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                }

                // Results table
                VStack(spacing: 0) {
                    HStack {
                        Text("Input")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Best Match")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Score")
                            .frame(width: 50, alignment: .trailing)
                        Image(systemName: "checkmark")
                            .frame(width: 24)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.sm)

                    Divider()

                    ForEach(Array(results.prefix(10).enumerated()), id: \.element.id) { index, result in
                        let isCorrect = isResultCorrect(result: result, index: index)
                        HStack {
                            Text(result.inputText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(result.matchText ?? "none")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", result.score * 100))
                                .frame(width: 50, alignment: .trailing)
                                .monospacedDigit()
                            Image(systemName: isCorrect ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(isCorrect ? .green : .red)
                                .frame(width: 24)
                        }
                        .font(.callout)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)

                        if index < min(results.count, 10) - 1 {
                            Divider()
                                .padding(.horizontal, Spacing.sm)
                        }
                    }

                    if results.count > 10 {
                        Divider()
                        Text("+ \(results.count - 10) more results")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, Spacing.xs)
                    }
                }
                .showcaseCard(cornerRadius: 6)

                // Accuracy breakdown
                HStack(spacing: 0) {
                    accuracyMetric(
                        value: totalWithTruth > 0 ? Double(correctCount) / Double(totalWithTruth) : nil,
                        label: "Match",
                        detail: "\(correctCount)/\(totalWithTruth)",
                        thresholds: (green: 0.80, orange: 0.50)
                    )
                    Divider()
                        .frame(height: 50)
                        .padding(.horizontal, Spacing.lg)
                    accuracyMetric(
                        value: nil,
                        label: "No-Match",
                        detail: "",
                        thresholds: (green: 0.40, orange: 0.20)
                    )
                    Divider()
                        .frame(height: 50)
                        .padding(.horizontal, Spacing.lg)
                    accuracyMetric(
                        value: nil,
                        label: "Overall",
                        detail: "",
                        thresholds: (green: 0.60, orange: 0.40)
                    )
                    Spacer()
                }
                .padding(.vertical, Spacing.sm)

                Text("The default embedding path ranks candidate database entries. The NHANES-to-DFG2 task includes descriptions with no valid DFG2 match, so a top retrieval can still require review.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.80))

                Text("Results may vary slightly from the paper due to MLX vs PyTorch numerical differences.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.80))
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.experimentalAmber)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Matching could not complete")
                            .font(.body.weight(.medium))
                        Text("Make sure GTE-Large is downloaded. Check Settings > Models.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack {
                    Spacer()
                    Button("Try Again") {
                        embeddingState = .ready
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Spacer()
                }
            }
            .padding(Spacing.md)
            .showcaseCard(cornerRadius: 8)
        }
    }

    private var embeddingErrorView: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.experimentalAmber)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Embedding matching failed")
                        .font(.body.weight(.medium))
                    if let errorMessage = appState.tourEmbeddingError {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }

            HStack {
                Spacer()
                Button("Try Again") {
                    embeddingState = .ready
                    appState.tourEmbeddingError = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Spacer()
            }
        }
        .padding(Spacing.md)
        .showcaseCard(cornerRadius: 8)
    }

    // MARK: - Hybrid State Machine

    @ViewBuilder
    private var hybridReadyContent: some View {
        switch hybridState {
        case .ready:
            hybridReadyView

        case .running:
            hybridRunningView

        case .complete:
            hybridCompleteView

        case .error:
            hybridErrorView
        }
    }

    private var hybridReadyView: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("API key configured")
                    .font(.body.weight(.medium))
            }

            if appState.isAdvancedMode {
                LabeledContent("Claude Model") {
                    Picker("", selection: $tourModelSelection) {
                        Text("Haiku 3 (Paper)").tag(ClaudeModelVersion.haiku3)
                        Text("Haiku 4.5").tag(ClaudeModelVersion.haiku45)
                        Text("Sonnet 4.5").tag(ClaudeModelVersion.sonnet45)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                if tourModelSelection == .sonnet45 {
                    TourInfoLine(
                        icon: "dollarsign.circle",
                        text: "Model availability and charges are set by Anthropic. Check the provider before a run."
                    )
                }
            }

            HStack {
                Spacer()
                Button {
                    runHybridMatch()
                } label: {
                    runActionButtonLabel(title: "Run Hybrid Matching")
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                Spacer()
            }

            TourInfoLine(
                icon: "cloud",
                text: "Uses Anthropic's Batches API. Completion time is controlled by the service and is not estimated here."
            )
        }
    }

    private var hybridRunningView: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Two-stage pipeline tracker
            VStack(alignment: .leading, spacing: 0) {
                // Step 1: Embeddings
                pipelineStageRow(
                    step: 1,
                    label: "Embeddings",
                    isComplete: !isEmbeddingPhase,
                    isActive: isEmbeddingPhase,
                    startTime: hybridStartTime,
                    endTime: embeddingCompletedTime
                )

                // Embedding progress bar (only during embedding phase)
                if isEmbeddingPhase {
                    ProgressView(value: min(appState.tourHybridProgress, 0.5), total: 0.5)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.md)
                }

                Divider()

                // Step 2: Batches API
                pipelineStageRow(
                    step: 2,
                    label: "Anthropic Batches API",
                    isComplete: false,
                    isActive: isBatchPhase,
                    startTime: embeddingCompletedTime,
                    endTime: nil
                )

                // Phase status text
                if isBatchPhase {
                    Text(hybridPhaseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.md)
                }
            }
            .showcaseCard(cornerRadius: 8)

            // Batches API details (collapsible, shown during batch phases)
            if isBatchPhase {
                TourTechnicalDetail(title: "About the Batches API") {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Text("The Batches API submits all matching requests at once. Anthropic processes them on available compute capacity. Unlike synchronous API calls, completion time depends on current demand, so there's no progress bar for this stage.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("For details on pricing, rate limits, and how the Batches API works, see Implementation Notes below.")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Cancel button
            HStack {
                Spacer()
                Button {
                    cancelHybridMatch()
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "xmark.circle")
                        Text("Cancel")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var hybridCompleteView: some View {
        if let results = appState.tourHybridResults, !results.isEmpty {
            let matchItems = tourInputItems.filter { $0.hasMatch }
            let noMatchItems = tourInputItems.filter { !$0.hasMatch }
            let matchCorrect = countCorrectMatches(results: results)
            let noMatchCorrect = countCorrectNoMatches(results: results)
            let totalCorrect = matchCorrect + noMatchCorrect
            let totalItems = tourInputItems.count

            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hybrid matching complete")
                            .font(.body.weight(.medium))
                        if let model = completedModelVersion {
                            HStack(spacing: Spacing.xs) {
                                Text("using \(model.displayName)")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.82))
                                if model.isPaperModel {
                                    Text("Paper model")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .appBadgeStyle(tone: .accentStrong, cornerRadius: 999)
                                }
                            }
                        }
                    }
                    Spacer()
                }

                // Timing summary
                HStack(spacing: 0) {
                    timingSummaryItem(
                        label: "Embeddings",
                        start: hybridStartTime,
                        end: embeddingCompletedTime
                    )
                    Divider()
                        .frame(height: 36)
                        .padding(.horizontal, Spacing.lg)
                    timingSummaryItem(
                        label: "Batches API",
                        start: embeddingCompletedTime,
                        end: hybridCompletedTime
                    )
                    Divider()
                        .frame(height: 36)
                        .padding(.horizontal, Spacing.lg)
                    timingSummaryItem(
                        label: "Total",
                        start: hybridStartTime,
                        end: hybridCompletedTime
                    )
                    Spacer()
                }

                // Results table
                VStack(spacing: 0) {
                    HStack {
                        Text("Input")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(completedModelVersion?.shortName ?? "Hybrid")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Score")
                            .frame(width: 50, alignment: .trailing)
                        Image(systemName: "checkmark")
                            .frame(width: 24)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.sm)

                    Divider()

                    ForEach(Array(results.prefix(10).enumerated()), id: \.element.id) { index, result in
                        let isCorrect = isHybridResultCorrect(result: result, index: index)
                        HStack {
                            Text(result.inputText)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(result.matchText ?? "none")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f%%", result.score * 100))
                                .frame(width: 50, alignment: .trailing)
                                .monospacedDigit()
                            Image(systemName: isCorrect ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(isCorrect ? .green : .red)
                                .frame(width: 24)
                        }
                        .font(.callout)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)

                        if index < min(results.count, 10) - 1 {
                            Divider()
                                .padding(.horizontal, Spacing.sm)
                        }
                    }

                    if results.count > 10 {
                        Divider()
                        Text("+ \(results.count - 10) more results")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, Spacing.xs)
                    }
                }
                .showcaseCard(cornerRadius: 6)

                // Accuracy breakdown
                HStack(spacing: 0) {
                    accuracyMetric(
                        value: matchItems.isEmpty ? nil : Double(matchCorrect) / Double(matchItems.count),
                        label: "Match",
                        detail: "\(matchCorrect)/\(matchItems.count)",
                        thresholds: (green: 0.80, orange: 0.50)
                    )
                    Divider()
                        .frame(height: 50)
                        .padding(.horizontal, Spacing.lg)
                    accuracyMetric(
                        value: noMatchItems.isEmpty ? nil : Double(noMatchCorrect) / Double(noMatchItems.count),
                        label: "No-Match",
                        detail: "\(noMatchCorrect)/\(noMatchItems.count)",
                        thresholds: (green: 0.40, orange: 0.20)
                    )
                    Divider()
                        .frame(height: 50)
                        .padding(.horizontal, Spacing.lg)
                    accuracyMetric(
                        value: totalItems == 0 ? nil : Double(totalCorrect) / Double(totalItems),
                        label: "Overall",
                        detail: "\(totalCorrect)/\(totalItems)",
                        thresholds: (green: 0.60, orange: 0.40)
                    )
                    Spacer()
                }
                .padding(.vertical, Spacing.sm)

                Text("The paper reports 65.4% overall accuracy for the hybrid pipeline on NHANES-to-DFG2.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.80))

                Text("Results may vary from the paper due to model version differences and MLX vs PyTorch numerical differences.")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.80))
            }
        }
    }

    private var hybridErrorView: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.experimentalAmber)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hybrid matching failed")
                        .font(.body.weight(.medium))
                    if let errorMessage = appState.tourHybridError {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }

            HStack {
                Spacer()
                Button("Try Again") {
                    hybridState = .ready
                    appState.tourHybridError = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Spacer()
            }
        }
        .padding(Spacing.md)
        .showcaseCard(cornerRadius: 8)
    }

    // MARK: - Hybrid Helpers

    private var hybridPhaseText: String {
        switch appState.tourHybridPhase {
        case .embeddingInputs:
            return "Computing embeddings..."
        case .batchSubmitting:
            return "Submitting to Anthropic..."
        case .batchSubmitted(let count):
            return "Sent to Anthropic API (\(count) items)"
        case .batchProcessing(let succeeded, let total):
            return "Waiting for Anthropic... (\(succeeded)/\(total) received)"
        case .batchReconnecting:
            return "Reconnecting to Anthropic..."
        case .computingSimilarity:
            return "Finding top candidates..."
        case .loadingDatabase:
            return "Loading database..."
        case .savingResults:
            return "Finishing up..."
        default:
            return "Processing..."
        }
    }

    private var isBatchPhase: Bool {
        appState.tourHybridPhase.isBatchWaiting
    }

    private var isEmbeddingPhase: Bool {
        switch appState.tourHybridPhase {
        case .embeddingInputs, .loadingDatabase, .computingSimilarity:
            return true
        default:
            return false
        }
    }

    // MARK: - Pipeline Stage Views

    private func pipelineStageRow(
        step: Int,
        label: String,
        isComplete: Bool,
        isActive: Bool,
        startTime: Date?,
        endTime: Date?
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Text("Step \(step)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            if isComplete {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.body)
            } else if isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
                    .font(.body)
            }

            Text(label)
                .font(.body.weight(isActive ? .medium : .regular))
                .foregroundStyle(isActive || isComplete ? .primary : .tertiary)

            Spacer()

            // Timing
            if isComplete, let start = startTime, let end = endTime {
                Text(formatDuration(from: start, to: end))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if isActive, let start = startTime {
                TimelineView(.periodic(from: start, by: 1)) { timeline in
                    Text(formatDuration(from: start, to: timeline.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private func timingSummaryItem(label: String, start: Date?, end: Date?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let start, let end {
                Text(formatDuration(from: start, to: end))
                    .font(.body.monospacedDigit().weight(.medium))
            } else {
                Text("--")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func accuracyMetric(
        value: Double?,
        label: String,
        detail: String,
        thresholds: (green: Double, orange: Double)
    ) -> some View {
        VStack(spacing: 2) {
            if let value {
                Text("\(String(format: "%.1f", value * 100))%")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(accuracyColor(value: value, thresholds: thresholds))
            } else {
                Text("\u{2014}")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.50 : 0.68))
            }
        }
    }

    private func accuracyColor(value: Double, thresholds: (green: Double, orange: Double)) -> Color {
        if value >= thresholds.green { return .green }
        if value >= thresholds.orange { return .experimentalAmber }
        return .red
    }

    private func formatDuration(from start: Date, to end: Date) -> String {
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        if elapsed < 60 {
            return "\(elapsed)s"
        }
        return "\(elapsed / 60)m \(String(format: "%02d", elapsed % 60))s"
    }

    // MARK: - API Key Onboarding

    private var apiKeyOnboardingContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("The optional Anthropic path sends retrieved candidate database entries and the input description to Claude for selection. This requires an Anthropic API key.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            // Setup Instructions Card
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Setup Instructions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: Spacing.md) {
                    onboardingStep(number: 1, text: "Create a free account at console.anthropic.com")
                    onboardingStep(number: 2, text: "Add credits to your account ($5 minimum)")
                    onboardingStep(number: 3, text: "Generate an API key from Settings > API Keys")
                }

                Divider()
                    .overlay(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))

                Button {
                    if let url = URL(string: "https://console.anthropic.com") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("Open Anthropic Console")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.lg)
            .showcaseCard(cornerRadius: 10, tone: .deep)

            // Input Card
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Enter API Key")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: Spacing.sm) {
                    SecureField("sk-ant-...", text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.1), lineWidth: 1)
                        )

                    Button {
                        saveAPIKey()
                    } label: {
                        Text("Save Key")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || apiKeyValidating ? Color.gray.opacity(0.3) : Color.accentColor)
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || apiKeyValidating)
                }

                if apiKeyValidating {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Validating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = apiKeyError {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(Spacing.lg)
            .showcaseCard(cornerRadius: 10, tone: .deep)

            TourInfoLine(
                icon: "lock.shield",
                text: "Your API key is stored in your Mac's Keychain. When you run the optional Anthropic path, FoodMapper sends the input text and retrieved candidate database entries needed for that run to Anthropic."
            )
        }
    }

    private func onboardingStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(colorScheme == .dark ? .black : .white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(colorScheme == .dark ? Color.white.opacity(0.9) : Color.accentColor))

            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Technical Notes

    @ViewBuilder
    private var implementationNotesContent: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Group 1: Runtime
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Runtime Profile")
                    .font(.callout.weight(.semibold))

                Text("Local elapsed time is recorded for the run. Anthropic batch completion depends on the service and is shown as status rather than an estimate.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    timingRow("GTE-Large model load", value: "recorded for this run")
                    timingRow("Local embedding", value: "recorded for this run")
                    timingRow("Candidate retrieval", value: "recorded for this run")
                    HStack {
                        HStack(spacing: Spacing.xs) {
                            Text("Batches API (Haiku)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 4) {
                                Image(systemName: "cloud")
                                    .font(.caption2)
                                Text("cloud")
                                    .font(.caption2.weight(.medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .appBadgeStyle(tone: .neutral, cornerRadius: 999)
                        }
                        Spacer()
                        Text("service status")
                            .font(.callout)
                    }
                }
            }
            .padding(Spacing.md)
            .showcaseCard(cornerRadius: 8, tone: .deep)

            // Group 2: Models & API
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Model Specs")
                    .font(.callout.weight(.semibold))

                Text("GTE-Large is a 335M-parameter BERT-based model that produces 1,024-dimensional embeddings. FoodMapper uses its pinned MLX conversion for the default local path.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("LLM Match Selection")
                    .font(.callout.weight(.semibold))

                Text("The publication evaluates a GTE-Large plus Claude Haiku path. The optional Anthropic path transfers the input text and retrieved candidate database entries needed for the selected run.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("API Parameters")
                    .font(.callout.weight(.semibold))

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    parameterRow("Temperature", value: "0 (deterministic)")
                    parameterRow("Max tokens", value: "100")
                    parameterRow("Approach", value: "Hybrid (top-5 candidates only)")
                }
            }
            .padding(Spacing.md)
            .showcaseCard(cornerRadius: 8, tone: .deep)

            // Group 3: Infrastructure
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Batches API")
                    .font(.callout.weight(.semibold))

                Text("FoodMapper submits the selected optional run through Anthropic's Batches API. Provider availability, timing, and charges are external to FoodMapper.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if let url = URL(string: "https://platform.claude.com/docs/en/build-with-claude/batch-processing") {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Read more on Anthropic's documentation")
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Divider()

                Text("On-Device Processing")
                    .font(.callout.weight(.semibold))

                Text("The default embedding model runs through MLX on Apple Silicon. Its local runtime and memory use vary with the Mac, input, target database, and cache state.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.md)
            .showcaseCard(cornerRadius: 8, tone: .deep)

            // Group 4: Costs
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Costs")
                    .font(.callout.weight(.semibold))

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    parameterRow("Default local embedding", value: "no provider account")
                    parameterRow("Optional Anthropic path", value: "provider account and charges")
                }

                Text("Check Anthropic's current documentation and account pricing before an optional run. FoodMapper does not set provider pricing or availability.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

            }
            .padding(Spacing.md)
            .showcaseCard(cornerRadius: 8, tone: .deep)
        }
    }

    private func timingRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    private func parameterRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    private func runActionButtonLabel(title: String) -> some View {
        RunActionButtonSurface(title: title, width: runActionButtonWidth)
    }

    // MARK: - Actions

    private func runEmbeddingMatch() {
        embeddingState = .running
        embeddingStartTime = Date()
        embeddingEndTime = nil
        appState.runTourEmbeddingMatch()
    }

    private func runHybridMatch() {
        hybridState = .running
        hybridStartTime = Date()
        embeddingCompletedTime = nil
        hybridCompletedTime = nil
        completedModelVersion = nil
        appState.runTourHybridMatch(modelVersion: tourModelSelection)
    }

    private func cancelHybridMatch() {
        appState.cancelTourHybridMatch()
        hybridState = .ready
        hybridStartTime = nil
        embeddingCompletedTime = nil
        hybridCompletedTime = nil
    }

    private func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        apiKeyValidating = true
        apiKeyError = nil

        Task {
            guard APIKeyStorage.setAnthropicAPIKey(trimmed) else {
                await MainActor.run {
                    apiKeyValidating = false
                    apiKeyError = "Couldn't store key"
                }
                return
            }
            appState.refreshAPIKeyState()

            do {
                let client = AnthropicAPIClient()
                let isValid = try await client.validateAPIKey(trimmed)

                await MainActor.run {
                    apiKeyValidating = false
                    if isValid {
                        apiKeySaved = true
                        apiKeyInput = ""
                        apiKeyError = nil
                    } else {
                        let removed = APIKeyStorage.deleteAnthropicAPIKey()
                        apiKeyError = removed ? "Invalid key" : "Invalid key; couldn't remove it"
                        appState.refreshAPIKeyState()
                    }
                }
            } catch {
                await MainActor.run {
                    apiKeyValidating = false
                    apiKeyError = "Validation failed"
                    appState.refreshAPIKeyState()
                }
            }
        }
    }

    private func countCorrectMatches(results: [MatchResult]) -> Int {
        var correct = 0
        for (index, result) in results.enumerated() {
            guard index < tourInputItems.count else { break }
            let tourItem = tourInputItems[index]
            guard tourItem.hasMatch, let groundTruth = tourItem.groundTruth else { continue }
            if let matchText = result.matchText,
               matchText.lowercased() == groundTruth.lowercased() {
                correct += 1
            }
        }
        return correct
    }

    private func countCorrectNoMatches(results: [MatchResult]) -> Int {
        var correct = 0
        for (index, result) in results.enumerated() {
            guard index < tourInputItems.count else { break }
            let tourItem = tourInputItems[index]
            guard !tourItem.hasMatch else { continue }
            if result.status == .noMatch { correct += 1 }
        }
        return correct
    }

    private func isResultCorrect(result: MatchResult, index: Int) -> Bool {
        guard index < tourInputItems.count else { return false }
        let tourItem = tourInputItems[index]
        if !tourItem.hasMatch { return false }
        guard let groundTruth = tourItem.groundTruth else { return false }
        return result.matchText?.lowercased() == groundTruth.lowercased()
    }

    /// Hybrid-aware correctness: checks both match and no-match items
    private func isHybridResultCorrect(result: MatchResult, index: Int) -> Bool {
        guard index < tourInputItems.count else { return false }
        let tourItem = tourInputItems[index]
        if tourItem.hasMatch {
            guard let groundTruth = tourItem.groundTruth else { return false }
            return result.matchText?.lowercased() == groundTruth.lowercased()
        } else {
            return result.status == .noMatch
        }
    }
}

// MARK: - Supporting Types

private struct RunActionButtonSurface: View {
    let title: String
    let width: CGFloat

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "play.circle")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, Spacing.lg)
        .padding(.horizontal, Spacing.lg)
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.clear)
                .showcaseCard()
                .shadow(
                    color: isHovered ? Color.accentColor.opacity(0.2) : Color.clear,
                    radius: isHovered ? 8 : 0,
                    y: 0
                )
                .scaleEffect(isHovered ? 1.015 : 1.0)
                .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : tiltX),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.8
                )
                .rotation3DEffect(
                    .degrees(reduceMotion ? 0 : tiltY),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.8
                )
                .animation(Animate.standard, value: isHovered)
                .animation(Animate.quick, value: hoverLocation)
                .allowsHitTesting(false)
        }
        .scaleEffect(isHovered ? 1.004 : 1.0)
        .contentShape(Rectangle())
        .animation(Animate.standard, value: isHovered)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                isHovered = true
                hoverLocation = location
            case .ended:
                isHovered = false
            }
        }
    }

    private var tiltX: Double {
        let normalized = (hoverLocation.x / max(width, 1)) * 2 - 1
        return min(max(normalized * 2.5, -2.5), 2.5)
    }

    private var tiltY: Double {
        let normalized = (hoverLocation.y / 72.0) * 2 - 1
        return min(max(-normalized * 2.5, -2.5), 2.5)
    }
}

private enum ShowcaseEmbeddingState {
    case ready, running, complete, error
}

private enum ShowcaseHybridState {
    case ready, running, complete, error
}

// MARK: - Previews

#Preview("Try It - Light") {
    ScrollView {
        TryItSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 900)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.light)
}

#Preview("Try It - Dark") {
    ScrollView {
        TryItSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 900)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}
