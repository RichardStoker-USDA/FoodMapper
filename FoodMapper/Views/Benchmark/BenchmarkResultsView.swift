import SwiftUI

/// Displays results from benchmark runs -- summary cards, difficulty/category breakdowns,
/// timing info, and per-item drill-down.
struct BenchmarkResultsView: View {
    let results: [BenchmarkResult]
    var onDeleteResult: ((BenchmarkResult) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedResultId: UUID?
    @State private var itemFilter: ItemFilter = .all
    @State private var comparingRunA: BenchmarkResult?
    @State private var showComparisonPicker: Bool = false
    @State private var showAllItems: Bool = false
    @State private var resultToDelete: BenchmarkResult?
    @State private var visibleResultCount: Int = 3

    enum ItemFilter: String, CaseIterable {
        case all = "All"
        case correct = "Correct"
        case incorrect = "Incorrect"
        case noMatch = "No Match"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let runA = comparingRunA, let runB = results.first(where: { $0.id != runA.id }) {
                BenchmarkComparisonView(runA: runA, runB: runB) {
                    comparingRunA = nil
                }
            } else {
                HStack {
                    Text("RESULTS")
                        .technicalLabel()
                    Spacer()
                    if results.count >= 2 {
                        Button {
                            comparingRunA = results.sorted(by: { $0.timestamp > $1.timestamp }).first
                        } label: {
                            Label("Compare Latest", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                let sorted = results.sorted(by: { $0.timestamp > $1.timestamp })
                let visible = Array(sorted.prefix(visibleResultCount))

                ForEach(visible) { result in
                    resultCard(result)
                }

                if sorted.count > visibleResultCount {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            visibleResultCount = min(visibleResultCount + 5, sorted.count)
                        }
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Text("Show More")
                            Text("(\(sorted.count - visibleResultCount) remaining)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.xs)
                } else if sorted.count > 3 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            visibleResultCount = 3
                        }
                    } label: {
                        Text("Show Less")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.xs)
                }
            }
        }
        .onChange(of: results.count) { _, _ in
            visibleResultCount = 3
        }
    }

    // MARK: - Result Card

    private func resultCard(_ result: BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(result.pipelineName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    HStack(spacing: Spacing.sm) {
                        Text(result.timestamp, style: .date)
                        Text(result.databaseName)
                        Text("\(result.itemCount) items")
                        Text(result.config.instructionPreset.displayName)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, Spacing.xxxs)
                            .background(Color.badgeBackground(for: colorScheme))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        if let subset = result.config.subsetSize {
                            Text("(\(subset) subset)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: Spacing.sm) {
                    Text(String(format: "%.1fs", result.metrics.totalDurationSeconds))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Button {
                        exportResult(result)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        resultToDelete = result
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Delete this benchmark run result")
                }
            }
            .alert("Delete Benchmark Result?", isPresented: Binding(
                get: { resultToDelete?.id == result.id },
                set: { if !$0 { resultToDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { resultToDelete = nil }
                Button("Delete", role: .destructive) {
                    onDeleteResult?(result)
                    resultToDelete = nil
                }
            } message: {
                Text("This will permanently remove the result for \"\(result.pipelineName)\" from \(result.timestamp, style: .date). This cannot be undone.")
            }

            // Primary metrics row
            HStack(spacing: 0) {
                metricCard(
                    label: "TOP-1",
                    value: String(format: "%.1f%%", result.metrics.topOneAccuracy * 100),
                    color: metricColor(result.metrics.topOneAccuracy, thresholds: (0.80, 0.60)),
                    tooltip: "Percentage of items where the #1 result exactly matches the expected answer."
                )
                Spacer()
                metricCard(
                    label: "RECALL@5",
                    value: String(format: "%.1f%%", result.metrics.recallAt5 * 100),
                    color: metricColor(result.metrics.recallAt5, thresholds: (0.90, 0.80)),
                    tooltip: "Percentage of items where the expected answer appears somewhere in the top 5 results."
                )
                Spacer()
                metricCard(
                    label: "MRR",
                    value: String(format: "%.3f", result.metrics.meanReciprocalRank),
                    color: metricColor(result.metrics.meanReciprocalRank, thresholds: (0.85, 0.70)),
                    tooltip: "Mean Reciprocal Rank: average of 1/rank for each correct answer. Higher means correct answers rank closer to #1."
                )

                if result.metrics.noMatchF1 > 0 {
                    Spacer()
                    metricCard(
                        label: "NO-MATCH F1",
                        value: String(format: "%.2f", result.metrics.noMatchF1),
                        color: metricColor(result.metrics.noMatchF1, thresholds: (0.80, 0.60)),
                        tooltip: "F1 score for detecting items that have no correct match in the database. Balances precision and recall."
                    )
                }
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.cardBackground(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.5)
            )

            // Secondary recall + no-match metrics
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.lg) {
                    Label {
                        HStack(spacing: Spacing.sm) {
                            Text("Recall@3: \(String(format: "%.1f%%", result.metrics.recallAt3 * 100))")
                            Text("Recall@10: \(String(format: "%.1f%%", result.metrics.recallAt10 * 100))")
                        }
                    } icon: {
                        Image(systemName: "arrow.up.right.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                // No-match detection row (if applicable)
                if result.metrics.noMatchPrecision > 0 || result.metrics.noMatchRecall > 0 {
                    HStack(spacing: Spacing.lg) {
                        Label {
                            HStack(spacing: Spacing.sm) {
                                Text("Precision: \(String(format: "%.0f%%", result.metrics.noMatchPrecision * 100))")
                                Text("Recall: \(String(format: "%.0f%%", result.metrics.noMatchRecall * 100))")
                                Text("F1: \(String(format: "%.2f", result.metrics.noMatchF1))")
                            }
                        } icon: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }

            // Per-difficulty breakdown
            if !result.metrics.accuracyByDifficulty.isEmpty {
                difficultyBreakdown(result.metrics.accuracyByDifficulty)
            }

            // Per-category breakdown
            if !result.metrics.accuracyByCategory.isEmpty {
                categoryBreakdown(result.metrics.accuracyByCategory)
            }

            // Timing
            HStack(spacing: Spacing.lg) {
                Label(String(format: "%.1fs total", result.metrics.totalDurationSeconds), systemImage: "clock")
                Text(String(format: "%.3fs per item", result.metrics.averageSecondsPerItem))
                if !result.deviceName.isEmpty {
                    Text(result.deviceName)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Per-item results (collapsible)
            DisclosureGroup(isExpanded: Binding(
                get: { expandedResultId == result.id },
                set: {
                    expandedResultId = $0 ? result.id : nil
                    showAllItems = false
                }
            )) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Filter pills
                    HStack(spacing: Spacing.xs) {
                        ForEach(ItemFilter.allCases, id: \.self) { filter in
                            Button(filter.rawValue) {
                                itemFilter = filter
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(itemFilter == filter ? .accentColor : .secondary)
                        }
                    }

                    itemResultsTable(result.itemResults)
                }
            } label: {
                Text("Per-item results (\(result.itemResults.count) items)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 8)
    }

    // MARK: - Difficulty Breakdown

    private func difficultyBreakdown(_ byDifficulty: [String: DifficultyMetrics]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("BY DIFFICULTY")
                .technicalLabel()

            let sortOrder = ["easy", "medium", "hard", "no_match"]
            let sorted = byDifficulty.sorted { a, b in
                (sortOrder.firstIndex(of: a.key) ?? 99) < (sortOrder.firstIndex(of: b.key) ?? 99)
            }

            HStack(spacing: Spacing.md) {
                ForEach(sorted, id: \.key) { difficulty, metrics in
                    VStack(spacing: Spacing.xxs) {
                        Text(String(format: "%.0f%%", metrics.top1Accuracy * 100))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(metricColor(metrics.top1Accuracy, thresholds: (0.80, 0.60)))
                        Text(difficulty.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("(\(metrics.count))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minWidth: 60)
                    .padding(.vertical, Spacing.xs)
                    .padding(.horizontal, Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.cardBackground(for: colorScheme))
                    )
                }
            }
        }
    }

    // MARK: - Category Breakdown

    private func categoryBreakdown(_ byCategory: [String: Double]) -> some View {
        let sorted = byCategory.sorted { $0.value > $1.value }
        let visible = Array(sorted.prefix(8))

        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("BY CATEGORY")
                .technicalLabel()

            FlowLayout(spacing: Spacing.xs) {
                ForEach(visible, id: \.key) { category, accuracy in
                    HStack(spacing: Spacing.xxs) {
                        Text(category)
                            .font(.caption)
                        Text(String(format: "%.0f%%", accuracy * 100))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(metricColor(accuracy, thresholds: (0.80, 0.60)))
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxs)
                    .background(Color.badgeBackground(for: colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                if sorted.count > 8 {
                    Text("+\(sorted.count - 8) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Metric Card

    private func metricCard(label: String, value: String, color: Color, tooltip: String = "") -> some View {
        VStack(spacing: Spacing.xxs) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(color)
            HStack(spacing: Spacing.xxxs) {
                Text(label)
                    .technicalLabel()
                    .foregroundStyle(.secondary)
                if !tooltip.isEmpty {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .help(tooltip)
    }

    private func metricColor(_ value: Double, thresholds: (Double, Double)) -> Color {
        if value >= thresholds.0 { return .green }
        if value >= thresholds.1 { return .orange }
        return Color(nsColor: .secondaryLabelColor)
    }

    // MARK: - Export

    private func exportResult(_ result: BenchmarkResult) {
        let dateStr = ISO8601DateFormatter().string(from: result.timestamp)
            .replacingOccurrences(of: ":", with: "-")
            .prefix(16)
        let pipelineSlug = result.pipelineName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        let filename = "benchmark_\(result.datasetName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(pipelineSlug)_\(dateStr).csv"

        let panel = NSSavePanel()
        panel.allowedContentTypes = DataFileFormat.allUTTypes
        panel.nameFieldStringValue = filename
        panel.message = "Export benchmark results"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let format = DataFileFormat.from(url: url)
            let d = format.delimiterString
            var output = ""
            // Header comment block with aggregate metrics
            output += "#benchmark=\(result.datasetName)\n"
            output += "#pipeline=\(result.pipelineName)\n"
            output += "#database=\(result.databaseName)\n"
            output += "#date=\(dateStr)\n"
            output += "#items=\(result.itemCount)\n"
            output += String(format: "#top1_accuracy=%.4f\n", result.metrics.topOneAccuracy)
            output += String(format: "#recall_at_5=%.4f\n", result.metrics.recallAt5)
            output += String(format: "#mrr=%.4f\n", result.metrics.meanReciprocalRank)
            output += String(format: "#no_match_precision=%.4f\n", result.metrics.noMatchPrecision)
            output += String(format: "#no_match_recall=%.4f\n", result.metrics.noMatchRecall)
            output += String(format: "#no_match_f1=%.4f\n", result.metrics.noMatchF1)
            output += String(format: "#duration_seconds=%.2f\n", result.metrics.totalDurationSeconds)
            output += "#device=\(result.deviceName)\n"

            // Data header
            output += ["row", "input", "expected", "actual", "score", "rank_of_expected", "correct_top1", "correct_topk", "difficulty", "category"].joined(separator: d) + "\n"

            for (i, item) in result.itemResults.enumerated() {
                let expected = self.escapeField(item.expectedMatch ?? "NO_MATCH", delimiter: format.delimiter)
                let actual = self.escapeField(item.predictedMatch ?? "", delimiter: format.delimiter)
                let rank = item.rank.map { String($0) } ?? "--"
                let difficulty = item.difficulty?.rawValue ?? ""
                let category = item.category ?? ""
                let row = [
                    String(i + 1),
                    self.escapeField(item.inputText, delimiter: format.delimiter),
                    expected,
                    actual,
                    String(format: "%.4f", item.score),
                    rank,
                    String(item.isCorrect),
                    String(item.isInTopK),
                    difficulty,
                    category
                ]
                output += row.joined(separator: d) + "\n"
            }

            do {
                try output.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // Silently fail -- not critical
            }
        }
    }

    private func escapeField(_ value: String, delimiter: Character = ",") -> String {
        let delimStr = String(delimiter)
        let needsQuoting = value.contains(delimStr) || value.contains("\n") || value.contains("\"")
        if needsQuoting {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: - Item Results Table

    private func itemResultsTable(_ items: [BenchmarkItemResult]) -> some View {
        let filtered = items.filter { item in
            switch itemFilter {
            case .all: return true
            case .correct: return item.isCorrect
            case .incorrect: return !item.isCorrect && item.isNoMatchCorrect == nil
            case .noMatch: return item.isNoMatchCorrect != nil
            }
        }
        let limit = showAllItems ? filtered.count : 50
        let visibleItems = Array(filtered.prefix(limit))

        return VStack(spacing: 0) {
            // Column headers
            HStack(spacing: Spacing.sm) {
                Text("")
                    .frame(width: 18)
                Text("Input")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Expected")
                    .frame(width: 180, alignment: .leading)
                Text("Predicted")
                    .frame(width: 180, alignment: .leading)
                Text("Rank")
                    .help("Position of the expected match in the ranked results. #1 = top result.")
                    .frame(width: 36, alignment: .trailing)
                Text("Score")
                    .help("Confidence score from the pipeline (cosine similarity, reranker probability, etc.)")
                    .frame(width: 48, alignment: .trailing)
            }
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Spacing.xs)
            .background(Color.cardBackground(for: colorScheme))

            Divider()

            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: Spacing.sm) {
                    Image(systemName: item.isCorrect ? "checkmark.circle" : "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(item.isCorrect ? .green : .orange)
                        .frame(width: 18)
                        .help(item.isCorrect ? "Correct: predicted match equals expected" : "Incorrect: predicted match does not equal expected")

                    Text(item.inputText)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let expected = item.expectedMatch {
                        Text(expected)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 180, alignment: .leading)
                    } else {
                        Text("NO_MATCH")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                            .frame(width: 180, alignment: .leading)
                    }

                    if let predicted = item.predictedMatch {
                        Text(predicted)
                            .font(.callout)
                            .foregroundStyle(item.isCorrect ? Color.primary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 180, alignment: .leading)
                    } else {
                        Text("--")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .frame(width: 180, alignment: .leading)
                    }

                    if let rank = item.rank {
                        Text("#\(rank)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundStyle(rank == 1 ? .green : .secondary)
                            .frame(width: 36, alignment: .trailing)
                    } else {
                        Text("--")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 36, alignment: .trailing)
                    }

                    Text(String(format: "%.0f%%", item.score * 100))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.vertical, Spacing.xxs)
                .padding(.horizontal, Spacing.xs)
                .background(index % 2 == 1
                    ? (colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.02))
                    : Color.clear)

                if index < visibleItems.count - 1 {
                    Divider()
                        .opacity(0.5)
                }
            }

            if filtered.count > 50 && !showAllItems {
                Button {
                    showAllItems = true
                } label: {
                    Text("Show All \(filtered.count) Items")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, Spacing.sm)
                .frame(maxWidth: .infinity)
            } else if showAllItems && filtered.count > 50 {
                Button {
                    showAllItems = false
                } label: {
                    Text("Show First 50")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, Spacing.sm)
                .frame(maxWidth: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.5)
        )
    }
}

// FlowLayout is defined in BenchmarkView.swift (shared across benchmark views)

#Preview("Benchmark Results") {
    let easyMetrics = DifficultyMetrics(count: 20, top1Accuracy: 0.95, recallAt5: 1.0, mrr: 0.97)
    let medMetrics = DifficultyMetrics(count: 28, top1Accuracy: 0.82, recallAt5: 0.92, mrr: 0.88)
    let hardMetrics = DifficultyMetrics(count: 16, top1Accuracy: 0.65, recallAt5: 0.81, mrr: 0.74)

    let metrics = BenchmarkMetrics(
        topOneAccuracy: 0.85, recallAt3: 0.92, recallAt5: 0.96, recallAt10: 0.98,
        meanReciprocalRank: 0.91,
        noMatchPrecision: 0.75, noMatchRecall: 0.80, noMatchF1: 0.77,
        accuracyByDifficulty: ["easy": easyMetrics, "medium": medMetrics, "hard": hardMetrics],
        accuracyByCategory: ["fruits": 0.95, "dairy": 0.88, "protein": 0.78, "grains": 0.72],
        totalDurationSeconds: 12.4, averageSecondsPerItem: 0.05
    )
    let config = BenchmarkRunConfig(
        datasetId: UUID(), pipelineType: .gteLargeEmbedding, threshold: 0.85
    )
    let result = BenchmarkResult(
        id: UUID(), config: config, metrics: metrics,
        itemResults: [], datasetName: "DFG2 Test", pipelineName: "GTE-Large Embedding",
        databaseName: "DFG2", deviceName: "MacBook Pro", itemCount: 64
    )
    BenchmarkResultsView(results: [result])
        .padding()
        .frame(width: 800)
}

#Preview("Benchmark Results - Dark") {
    let easyMetrics = DifficultyMetrics(count: 20, top1Accuracy: 0.95, recallAt5: 1.0, mrr: 0.97)
    let medMetrics = DifficultyMetrics(count: 28, top1Accuracy: 0.82, recallAt5: 0.92, mrr: 0.88)
    let hardMetrics = DifficultyMetrics(count: 16, top1Accuracy: 0.65, recallAt5: 0.81, mrr: 0.74)

    let metrics = BenchmarkMetrics(
        topOneAccuracy: 0.85, recallAt3: 0.92, recallAt5: 0.96, recallAt10: 0.98,
        meanReciprocalRank: 0.91,
        noMatchPrecision: 0.75, noMatchRecall: 0.80, noMatchF1: 0.77,
        accuracyByDifficulty: ["easy": easyMetrics, "medium": medMetrics, "hard": hardMetrics],
        accuracyByCategory: ["fruits": 0.95, "dairy": 0.88, "protein": 0.78, "grains": 0.72],
        totalDurationSeconds: 12.4, averageSecondsPerItem: 0.05
    )
    let config = BenchmarkRunConfig(
        datasetId: UUID(), pipelineType: .gteLargeEmbedding, threshold: 0.85
    )
    let result = BenchmarkResult(
        id: UUID(), config: config, metrics: metrics,
        itemResults: [], datasetName: "DFG2 Test", pipelineName: "GTE-Large Embedding",
        databaseName: "DFG2", deviceName: "MacBook Pro", itemCount: 64
    )
    BenchmarkResultsView(results: [result])
        .padding()
        .frame(width: 800)
        .preferredColorScheme(.dark)
}
