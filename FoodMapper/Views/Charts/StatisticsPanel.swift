import SwiftUI

/// Statistics panel showing match metrics, review-decision-aware when available.
struct StatisticsPanel: View {
    let results: [MatchResult]
    let threshold: Double
    var reviewDecisions: [UUID: ReviewDecision] = [:]
    var cachedCategories: [UUID: MatchCategory] = [:]
    var scoreType: ScoreType = .cosineSimilarity

    @Environment(\.colorScheme) private var colorScheme

    private var hasReview: Bool { !reviewDecisions.isEmpty }

    /// Stats computed from review decisions / MatchCategory when available.
    private var stats: [(label: String, value: String, color: Color)] {
        let total = results.count
        guard total > 0 else { return [("Total Items", "0", .primary)] }

        let profile = ThresholdProfile.defaults(for: scoreType)
        var items: [(String, String, Color)] = [
            ("Total Items", "\(total)", .primary)
        ]

        // Category-based statistics (uses pre-computed cache)
        var counts: [MatchCategory: Int] = [:]
        for result in results {
            let cat = cachedCategories[result.id] ?? .noMatch
            counts[cat, default: 0] += 1
        }

        let matchCount = counts[.match, default: 0] + counts[.confirmedMatch, default: 0]
        let needsReviewCount = counts[.needsReview, default: 0]
        let noMatchCount = counts[.noMatch, default: 0] + counts[.confirmedNoMatch, default: 0]
        let humanReviewed = reviewDecisions.values.filter { $0.status.isHumanDecision }.count

        let matchRate = Double(matchCount) / Double(total) * 100
        items.append(("Match Rate", String(format: "%.1f%%", matchRate), .green))
        items.append(("Matched", "\(matchCount)", MatchCategory.match.color))
        items.append(("Needs Review", "\(needsReviewCount)", MatchCategory.needsReview.color))
        items.append(("No Match", "\(noMatchCount)", .secondary))
        if humanReviewed > 0 {
            items.append(("Reviewed", "\(humanReviewed)", Color.accentColor))
        }

        // Score statistics (always available)
        let avgScore = results.reduce(0.0) { $0 + $1.score } / Double(total)
        let matchedResults = results.filter { $0.score >= profile.matchThreshold }
        let avgMatched = matchedResults.isEmpty ? 0 : matchedResults.reduce(0.0) { $0 + $1.score } / Double(matchedResults.count)

        items.append(("Avg Score", String(format: "%.2f", avgScore), .primary))
        items.append(("Avg Match Score", String(format: "%.2f", avgMatched), .green))

        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Statistics")
                    .technicalLabel()
            }
            .padding(.horizontal, Spacing.md)

            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading)
            ], spacing: Spacing.md) {
                ForEach(stats, id: \.label) { stat in
                    StatRow(label: stat.label, value: stat.value, color: stat.color)
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .padding(.vertical, Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
    }
}

/// Individual stat row with premium technical styling
struct StatRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(label)
                .font(.system(.caption2, weight: .medium))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Text(value)
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.vertical, Spacing.xs)
    }
}

#Preview("Statistics - Light") {
    StatisticsPanel(results: PreviewHelpers.sampleResults, threshold: 0.85)
        .frame(width: 380)
        .padding(Spacing.xl)
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Statistics - Dark") {
    StatisticsPanel(results: PreviewHelpers.sampleResults, threshold: 0.85)
        .frame(width: 380)
        .padding(Spacing.xl)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

#Preview("Statistics - High Threshold") {
    StatisticsPanel(results: PreviewHelpers.sampleResults, threshold: 0.92)
        .frame(width: 380)
        .padding(Spacing.xl)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}
