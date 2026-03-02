import SwiftUI

/// Side-by-side comparison of two benchmark runs on the same dataset.
struct BenchmarkComparisonView: View {
    let runA: BenchmarkResult
    let runB: BenchmarkResult
    var onDismiss: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("COMPARING RUNS")
                            .technicalLabel()
                        HStack(spacing: Spacing.lg) {
                            HStack(spacing: Spacing.xs) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                Text("A: \(runA.pipelineName)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            HStack(spacing: Spacing.xs) {
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 8, height: 8)
                                Text("B: \(runB.pipelineName)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let onDismiss {
                        Button {
                            onDismiss()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                // Metrics comparison table
                metricsComparisonTable

                // Difficulty comparison
                difficultyComparison

                // Changed items
                changedItemsSection
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: - Metrics Table

    private var metricsComparisonTable: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("METRICS")
                .technicalLabel()

            VStack(spacing: 0) {
                // Column header row
                HStack {
                    Text("Metric")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Run A")
                        .frame(width: 80, alignment: .trailing)
                    Text("Run B")
                        .frame(width: 80, alignment: .trailing)
                    Text("Delta")
                        .frame(width: 100, alignment: .trailing)
                }
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.vertical, Spacing.xs)
                .padding(.horizontal, Spacing.sm)
                .background(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))

                Divider()

                comparisonRow("Top-1 Accuracy",
                    a: runA.metrics.topOneAccuracy, b: runB.metrics.topOneAccuracy, isPercent: true)
                Divider().opacity(0.5)
                comparisonRow("Recall@3",
                    a: runA.metrics.recallAt3, b: runB.metrics.recallAt3, isPercent: true)
                Divider().opacity(0.5)
                comparisonRow("Recall@5",
                    a: runA.metrics.recallAt5, b: runB.metrics.recallAt5, isPercent: true)
                Divider().opacity(0.5)
                comparisonRow("Recall@10",
                    a: runA.metrics.recallAt10, b: runB.metrics.recallAt10, isPercent: true)
                Divider().opacity(0.5)
                comparisonRow("MRR",
                    a: runA.metrics.meanReciprocalRank, b: runB.metrics.meanReciprocalRank, isPercent: false)
                Divider().opacity(0.5)
                comparisonRow("No-Match Precision",
                    a: runA.metrics.noMatchPrecision, b: runB.metrics.noMatchPrecision, isPercent: true)
                Divider().opacity(0.5)
                comparisonRow("No-Match Recall",
                    a: runA.metrics.noMatchRecall, b: runB.metrics.noMatchRecall, isPercent: true)
                Divider().opacity(0.5)
                comparisonRow("No-Match F1",
                    a: runA.metrics.noMatchF1, b: runB.metrics.noMatchF1, isPercent: false)
                Divider().opacity(0.5)
                // Time comparison (lower is better)
                comparisonRow("Time (s)",
                    a: runA.metrics.totalDurationSeconds, b: runB.metrics.totalDurationSeconds,
                    isPercent: false, lowerIsBetter: true)
            }
        }
        .premiumMaterialStyle(cornerRadius: 8)
    }

    private func comparisonRow(_ label: String, a: Double, b: Double, isPercent: Bool, lowerIsBetter: Bool = false) -> some View {
        let delta = a - b
        let isImproved = lowerIsBetter ? delta < 0 : delta > 0

        return HStack {
            Text(label)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatValue(a, isPercent: isPercent))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 80, alignment: .trailing)

            Text(formatValue(b, isPercent: isPercent))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            HStack(spacing: Spacing.xxs) {
                Text(formatDelta(delta, isPercent: isPercent))
                    .font(.system(.callout, design: .monospaced))
                    .monospacedDigit()
                Image(systemName: isImproved ? "arrow.up" : delta == 0 ? "minus" : "arrow.down")
                    .font(.caption)
            }
            .foregroundColor(delta == 0 ? Color.secondary : isImproved ? Color.green : Color.red.opacity(0.8))
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
    }

    private func formatValue(_ value: Double, isPercent: Bool) -> String {
        if isPercent {
            return String(format: "%.1f%%", value * 100)
        }
        return String(format: "%.3f", value)
    }

    private func formatDelta(_ delta: Double, isPercent: Bool) -> String {
        let sign = delta >= 0 ? "+" : ""
        if isPercent {
            return String(format: "%@%.1f%%", sign, delta * 100)
        }
        return String(format: "%@%.3f", sign, delta)
    }

    // MARK: - Difficulty Comparison

    private var sortedDifficultyKeys: [String] {
        let allKeys = Set(runA.metrics.accuracyByDifficulty.keys)
            .union(runB.metrics.accuracyByDifficulty.keys)
        let sortOrder = ["easy", "medium", "hard", "no_match"]
        return allKeys.sorted { a, b in
            (sortOrder.firstIndex(of: a) ?? 99) < (sortOrder.firstIndex(of: b) ?? 99)
        }
    }

    private var difficultyComparison: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("BY DIFFICULTY")
                .technicalLabel()

            HStack(spacing: Spacing.md) {
                ForEach(sortedDifficultyKeys, id: \.self) { difficulty in
                    difficultyComparisonCell(difficulty)
                }
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 8)
    }

    private func difficultyComparisonCell(_ difficulty: String) -> some View {
        let aAcc = runA.metrics.accuracyByDifficulty[difficulty]?.top1Accuracy ?? 0
        let bAcc = runB.metrics.accuracyByDifficulty[difficulty]?.top1Accuracy ?? 0
        let delta = aAcc - bAcc

        return VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                VStack(spacing: Spacing.xxxs) {
                    Text("A")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.0f%%", aAcc * 100))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundColor(.accentColor)
                }
                VStack(spacing: Spacing.xxxs) {
                    Text("B")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(String(format: "%.0f%%", bAcc * 100))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            // Delta indicator
            if delta != 0 {
                Text(String(format: "%@%.0f%%", delta > 0 ? "+" : "", delta * 100))
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(delta > 0 ? .green : .red.opacity(0.8))
            }

            Text(difficulty.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 70)
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02))
        )
    }

    // MARK: - Changed Items

    private var changedItemsSection: some View {
        let improvements = findChanges(correctIn: runA, wrongIn: runB)
        let regressions = findChanges(correctIn: runB, wrongIn: runA)

        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("CHANGED ITEMS")
                .technicalLabel()

            if improvements.isEmpty && regressions.isEmpty {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("No items changed correctness between runs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.md)
                .premiumMaterialStyle(cornerRadius: 6)
            } else {
                if !improvements.isEmpty {
                    changedItemsList(
                        title: "Improvements",
                        count: improvements.count,
                        items: improvements,
                        color: .green,
                        icon: "arrow.up.circle"
                    )
                }
                if !regressions.isEmpty {
                    changedItemsList(
                        title: "Regressions",
                        count: regressions.count,
                        items: regressions,
                        color: .red.opacity(0.8),
                        icon: "arrow.down.circle"
                    )
                }
            }
        }
    }

    private func changedItemsList(title: String, count: Int, items: [BenchmarkItemResult], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text("\(title) (\(count))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
            }

            VStack(spacing: 0) {
                ForEach(Array(items.prefix(20).enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: Spacing.sm) {
                        Text(item.inputText)
                            .font(.callout)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let expected = item.expectedMatch {
                            Text(expected)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 180, alignment: .leading)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    .padding(.horizontal, Spacing.xs)
                    .background(index % 2 == 1
                        ? (colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.02))
                        : Color.clear)
                }
                if items.count > 20 {
                    Text("+\(items.count - 20) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, Spacing.xs)
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

    /// Find items that are correct in one run and wrong in the other.
    private func findChanges(correctIn: BenchmarkResult, wrongIn: BenchmarkResult) -> [BenchmarkItemResult] {
        let correctSet = Set(correctIn.itemResults.filter { $0.isCorrect }.map { $0.inputText })
        return wrongIn.itemResults.filter { !$0.isCorrect && correctSet.contains($0.inputText) }
    }
}

#Preview("Benchmark Comparison") {
    let easyM = DifficultyMetrics(count: 20, top1Accuracy: 0.95, recallAt5: 1.0, mrr: 0.97)
    let medM = DifficultyMetrics(count: 28, top1Accuracy: 0.82, recallAt5: 0.92, mrr: 0.88)

    let metricsA = BenchmarkMetrics(
        topOneAccuracy: 0.85, recallAt3: 0.92, recallAt5: 0.96, recallAt10: 0.98,
        meanReciprocalRank: 0.91,
        noMatchPrecision: 0.85, noMatchRecall: 0.80, noMatchF1: 0.82,
        accuracyByDifficulty: ["easy": easyM, "medium": medM],
        accuracyByCategory: [:],
        totalDurationSeconds: 12.4, averageSecondsPerItem: 0.05
    )
    let metricsB = BenchmarkMetrics(
        topOneAccuracy: 0.78, recallAt3: 0.88, recallAt5: 0.92, recallAt10: 0.95,
        meanReciprocalRank: 0.85,
        noMatchPrecision: 0.80, noMatchRecall: 0.75, noMatchF1: 0.77,
        accuracyByDifficulty: ["easy": easyM, "medium": DifficultyMetrics(count: 28, top1Accuracy: 0.71, recallAt5: 0.85, mrr: 0.80)],
        accuracyByCategory: [:],
        totalDurationSeconds: 8.2, averageSecondsPerItem: 0.03
    )
    let configA = BenchmarkRunConfig(datasetId: UUID(), pipelineType: .qwen3TwoStage, threshold: 0.85)
    let configB = BenchmarkRunConfig(datasetId: UUID(), pipelineType: .gteLargeEmbedding, threshold: 0.85)

    let runA = BenchmarkResult(
        id: UUID(), config: configA, metrics: metricsA, itemResults: [],
        datasetName: "Core Accuracy", pipelineName: "Qwen3 Two-Stage",
        databaseName: "FooDB", deviceName: "MacBook Pro", itemCount: 100
    )
    let runB = BenchmarkResult(
        id: UUID(), config: configB, metrics: metricsB, itemResults: [],
        datasetName: "Core Accuracy", pipelineName: "GTE-Large Embedding",
        databaseName: "FooDB", deviceName: "MacBook Pro", itemCount: 100
    )

    BenchmarkComparisonView(runA: runA, runB: runB)
        .frame(width: 700, height: 600)
}

#Preview("Benchmark Comparison - Dark") {
    let easyM = DifficultyMetrics(count: 20, top1Accuracy: 0.95, recallAt5: 1.0, mrr: 0.97)
    let medM = DifficultyMetrics(count: 28, top1Accuracy: 0.82, recallAt5: 0.92, mrr: 0.88)

    let metricsA = BenchmarkMetrics(
        topOneAccuracy: 0.85, recallAt3: 0.92, recallAt5: 0.96, recallAt10: 0.98,
        meanReciprocalRank: 0.91,
        noMatchPrecision: 0.85, noMatchRecall: 0.80, noMatchF1: 0.82,
        accuracyByDifficulty: ["easy": easyM, "medium": medM],
        accuracyByCategory: [:],
        totalDurationSeconds: 12.4, averageSecondsPerItem: 0.05
    )
    let metricsB = BenchmarkMetrics(
        topOneAccuracy: 0.78, recallAt3: 0.88, recallAt5: 0.92, recallAt10: 0.95,
        meanReciprocalRank: 0.85,
        noMatchPrecision: 0.80, noMatchRecall: 0.75, noMatchF1: 0.77,
        accuracyByDifficulty: ["easy": easyM, "medium": DifficultyMetrics(count: 28, top1Accuracy: 0.71, recallAt5: 0.85, mrr: 0.80)],
        accuracyByCategory: [:],
        totalDurationSeconds: 8.2, averageSecondsPerItem: 0.03
    )
    let configA = BenchmarkRunConfig(datasetId: UUID(), pipelineType: .qwen3TwoStage, threshold: 0.85)
    let configB = BenchmarkRunConfig(datasetId: UUID(), pipelineType: .gteLargeEmbedding, threshold: 0.85)

    let runA = BenchmarkResult(
        id: UUID(), config: configA, metrics: metricsA, itemResults: [],
        datasetName: "Core Accuracy", pipelineName: "Qwen3 Two-Stage",
        databaseName: "FooDB", deviceName: "MacBook Pro", itemCount: 100
    )
    let runB = BenchmarkResult(
        id: UUID(), config: configB, metrics: metricsB, itemResults: [],
        datasetName: "Core Accuracy", pipelineName: "GTE-Large Embedding",
        databaseName: "FooDB", deviceName: "MacBook Pro", itemCount: 100
    )

    BenchmarkComparisonView(runA: runA, runB: runB)
        .frame(width: 700, height: 600)
        .preferredColorScheme(.dark)
}
