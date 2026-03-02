import SwiftUI
import Charts

/// Histogram showing score distribution
struct ScoreDistributionChart: View {
    let results: [MatchResult]
    let threshold: Double

    @Environment(\.colorScheme) private var colorScheme

    private struct ScoreBin: Identifiable {
        let id = UUID()
        let range: String
        let count: Int
        let startScore: Double

        /// Midpoint of this bin, used for score threshold coloring
        var midpoint: Double { startScore + 0.025 }
    }

    private var histogramData: [ScoreBin] {
        let binCount = 10
        var bins: [Int] = Array(repeating: 0, count: binCount)

        for result in results {
            // Map 0.5-1.0 to bins 0-9
            let normalized = (result.score - 0.5) / 0.5
            let binIndex = min(max(Int(normalized * Double(binCount)), 0), binCount - 1)
            bins[binIndex] += 1
        }

        return bins.enumerated().map { index, count in
            let start = 0.5 + (Double(index) / Double(binCount)) * 0.5
            return ScoreBin(
                range: "\(Int(start * 100))%",
                count: count,
                startScore: start
            )
        }
    }

    /// Bar fill color based on which score threshold the bin midpoint falls in.
    /// Opacity tuned per color scheme for readability.
    private func barColor(for bin: ScoreBin) -> Color {
        let base = Color.scoreColor(bin.midpoint)
        return base.opacity(colorScheme == .dark ? 0.7 : 0.8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Score Distribution")
                        .technicalLabel()
                }

                Spacer()
            }
            .padding(.horizontal, Spacing.md)

            Chart(histogramData) { bin in
                BarMark(
                    x: .value("Score", bin.range),
                    y: .value("Count", bin.count)
                )
                .foregroundStyle(barColor(for: bin))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel()
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.quaternary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.quaternary)
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(
                        colorScheme == .dark
                            ? Color.white.opacity(0.02)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.3)
                    )
            }
            .frame(height: 160)
            .padding(.horizontal, Spacing.md)

            // Score threshold legend
            HStack(spacing: Spacing.sm) {
                LegendPill(color: .green, label: "High (\u{2265}86%)", colorScheme: colorScheme)
                LegendPill(color: .orange, label: "Medium (80-85%)", colorScheme: colorScheme)
                LegendPill(color: Color(nsColor: .secondaryLabelColor), label: "Low (<80%)", colorScheme: colorScheme)
            }
            .padding(.horizontal, Spacing.md)
        }
        .padding(.vertical, Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Score distribution chart showing how scores are spread across \(results.count) results")
    }
}

/// Legend pill for charts with tinted capsule background matching the pill's own color.
/// Follows the same pattern as ResultsSummaryBanner category filter pills.
struct LegendPill: View {
    let color: Color
    let label: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxxs)
        .background(
            Capsule()
                .fill(color.opacity(colorScheme == .light ? 0.12 : 0.15))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    color.opacity(colorScheme == .light ? 0.15 : 0.25),
                    lineWidth: 0.5
                )
        )
    }
}

#Preview("Score Distribution - Light") {
    ScoreDistributionChart(results: PreviewHelpers.sampleResults, threshold: 0.85)
        .frame(width: 420)
        .padding(Spacing.xl)
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Score Distribution - Dark") {
    ScoreDistributionChart(results: PreviewHelpers.sampleResults, threshold: 0.85)
        .frame(width: 420)
        .padding(Spacing.xl)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}
