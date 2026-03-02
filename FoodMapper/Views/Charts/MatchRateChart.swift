import SwiftUI

/// Stacked bar chart showing match rate breakdown by MatchCategory
struct MatchRateChart: View {
    let results: [MatchResult]
    let threshold: Double
    var reviewDecisions: [UUID: ReviewDecision] = [:]
    var cachedCategories: [UUID: MatchCategory] = [:]
    var scoreType: ScoreType = .cosineSimilarity

    @Environment(\.colorScheme) private var colorScheme

    /// Category counts computed from pre-cached categories (3 segments)
    private var categoryCounts: [(category: MatchCategory, count: Int, color: Color)] {
        var counts: [MatchCategory: Int] = [:]
        for result in results {
            let category = cachedCategories[result.id] ?? .noMatch
            counts[category, default: 0] += 1
        }

        return [
            (.match, counts[.match, default: 0] + counts[.confirmedMatch, default: 0], MatchCategory.match.color),
            (.needsReview, counts[.needsReview, default: 0], MatchCategory.needsReview.color),
            (.noMatch, counts[.noMatch, default: 0] + counts[.confirmedNoMatch, default: 0], Color(nsColor: .separatorColor))
        ].filter { $0.1 > 0 }
    }

    private var matchRate: Double {
        let matched = results.filter { result in
            let cat = cachedCategories[result.id] ?? .noMatch
            return cat == .match || cat == .confirmedMatch
        }.count
        return results.isEmpty ? 0 : Double(matched) / Double(results.count)
    }

    /// Segment fill opacity tuned per color scheme for vivid readability
    private var segmentOpacity: Double { colorScheme == .dark ? 0.8 : 0.9 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Match Rate")
                        .technicalLabel()
                }

                Spacer()

                Text(matchRate, format: .percent.precision(.fractionLength(1)))
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .foregroundStyle(Color.scoreColor(matchRate))
            }
            .padding(.horizontal, Spacing.md)

            // Stacked bar
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(categoryCounts, id: \.category) { item in
                        let width = geo.size.width * (Double(item.count) / Double(results.count))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(item.color.opacity(segmentOpacity))
                            .frame(width: max(width, item.count > 0 ? 4 : 0))
                    }
                }
            }
            .frame(height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.04))
            )
            .padding(.horizontal, Spacing.md)

            // Legend pills (tinted with each category's own color)
            HStack(spacing: Spacing.sm) {
                ForEach(categoryCounts, id: \.category) { item in
                    HStack(spacing: Spacing.xxs) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 6, height: 6)
                        Text("\(item.category.displayName)")
                            .font(.system(.caption2, weight: .medium))
                            .foregroundStyle(item.color)
                        Text("\(item.count)")
                            .font(.system(.caption2, design: .monospaced, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xxxs)
                    .background(
                        Capsule()
                            .fill(item.color.opacity(colorScheme == .light ? 0.12 : 0.15))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                item.color.opacity(colorScheme == .light ? 0.15 : 0.25),
                                lineWidth: 0.5
                            )
                    )
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .padding(.vertical, Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Match rate chart, \(Int(matchRate * 100)) percent matched")
    }
}

#Preview("Match Rate - Light") {
    MatchRateChart(results: PreviewHelpers.sampleResults, threshold: 0.85)
        .frame(width: 420)
        .padding(Spacing.xl)
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Match Rate - Dark") {
    MatchRateChart(results: PreviewHelpers.sampleResults, threshold: 0.85)
        .frame(width: 420)
        .padding(Spacing.xl)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}
