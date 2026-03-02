import SwiftUI

/// Section 3: Methods Compared -- 4 method cards in a 2x2 grid with accuracy overview.
struct MethodsComparedSection: View {
    var onScrollToNext: (() -> Void)? = nil

    @State private var paperStats: TourPaperStats?
    @State private var isLoading = true
    @State private var loadError: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            TourSectionHeader(
                "Methods Compared",
                subtitle: "Four approaches to automated food matching"
            )

            Text("The paper evaluated four categories of matching methods, from simple string comparison to AI-powered hybrid pipelines. Each builds on the limitations of the one before it.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            // 2x2 method card grid
            methodCardGrid

            VStack(spacing: Spacing.md) {
                // Collapsible detailed breakdown (preserves vertical space)
                TourTechnicalDetail(title: "Detailed Accuracy Breakdown") {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Text("Results from NHANES-to-DFG2 benchmark (1,304 items, 256 targets). Three metrics capture different aspects of matching quality:")
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            metricDefinition(
                                "Overall",
                                "Accuracy across all 1,304 items (both matches and no-matches)."
                            )
                            metricDefinition(
                                "Match Acc.",
                                "When a correct match exists, how often does the method find it?"
                            )
                            metricDefinition(
                                "No-Match Acc.",
                                "When no match exists, how often does the method correctly say 'none'?"
                            )
                        }
                    }
                }

                // Accuracy breakdown table
                accuracyBreakdown
            }

            if let onScrollToNext {
                HStack {
                    Spacer()
                    SectionChevronButton { onScrollToNext() }
                    Spacer()
                }
                .padding(.top, 26)
            }
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Method Card Grid

    private var methodCardGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Spacing.lg),
            GridItem(.flexible(), spacing: Spacing.lg)
        ]

        return LazyVGrid(columns: columns, spacing: Spacing.lg) {
            methodCard(
                icon: "textformat.abc",
                title: "Fuzzy Matching",
                accuracy: "~25%",
                description: "Measures character-level edit distance. Fails on word reordering and synonyms."
            )
            .scrollRevealStaggered(index: 0)

            methodCard(
                icon: "function",
                title: "TF-IDF",
                accuracy: "~40%",
                description: "Weights terms by document frequency. Better than fuzzy, but treats words as independent tokens."
            )
            .scrollRevealStaggered(index: 1)

            methodCard(
                icon: "cpu",
                title: "Semantic Embedding",
                accuracy: "48%",
                description: "GTE-Large encodes text as 1024-dimensional vectors. 96.4% top-5 accuracy."
            )
            .scrollRevealStaggered(index: 2)

            methodCard(
                icon: "arrow.triangle.branch",
                title: "Hybrid (Embedding + Claude)",
                accuracy: "65.4%",
                description: "Embedding retrieval narrows candidates; Claude Haiku selects the best match.",
                badge: "Best Overall",
                highlighted: true
            )
            .scrollRevealStaggered(index: 3)
        }
    }

    private func methodCard(
        icon: String,
        title: String,
        accuracy: String? = nil,
        description: String,
        badge: String? = nil,
        highlighted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }

                if let accuracy {
                    Text(accuracy)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(title)
                .font(.headline)

            Text(description)
                .font(.callout)
                .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .showcaseCard(highlighted: highlighted)
    }

    // MARK: - Accuracy Breakdown

    @ViewBuilder
    private var accuracyBreakdown: some View {
        if isLoading {
            HStack {
                Spacer()
                ProgressView("Loading results...")
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, Spacing.xl)
        } else if let error = loadError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.body)
                .foregroundStyle(.secondary)
        } else if let stats = paperStats {
            VStack(alignment: .leading, spacing: 0) {
                // Table content only - legend moved to header
                let rows = buildAccuracyRows(from: stats.methodAccuracies)
                if !rows.isEmpty {
                    TourDataTable(
                        columns: [
                            TourTableColumn("Method", maxWidth: 200) { row in
                                Text(row.method).lineLimit(1)
                            },
                            TourTableColumn("Overall", maxWidth: 80, alignment: .center) { row in
                                Text(row.overall)
                                    .monospacedDigit()
                                    .foregroundStyle(overallColor(row.overallValue))
                            },
                            TourTableColumn("Match", maxWidth: 80, alignment: .center) { row in
                                Text(row.matchAcc)
                                    .monospacedDigit()
                                    .foregroundStyle(matchColor(row.matchValue))
                            },
                            TourTableColumn("No-Match", maxWidth: 90, alignment: .center) { row in
                                Text(row.noMatchAcc)
                                    .monospacedDigit()
                                    .foregroundStyle(noMatchColor(row.noMatchValue))
                            }
                        ],
                        rows: rows,
                        highlightRow: { row in
                            row.method == "Hybrid Haiku K=5" ? .correct : .none
                        },
                        compact: true
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func metricDefinition(_ label: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 110, alignment: .leading)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func buildAccuracyRows(from methods: [MethodAccuracy]) -> [AccuracyDisplayRow] {
        methods
            .filter { !$0.method.lowercased().contains("gemma") }
            .map { method in
                AccuracyDisplayRow(
                    method: method.method,
                    overall: formatPercent(method.overallAccuracy),
                    overallValue: method.overallAccuracy ?? 0,
                    matchAcc: formatPercent(method.matchAccuracy),
                    matchValue: method.matchAccuracy ?? 0,
                    noMatchAcc: formatPercent(method.noMatchAccuracy),
                    noMatchValue: method.noMatchAccuracy ?? 0
                )
            }
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.1f%%", value)
    }

    private func overallColor(_ value: Double) -> Color {
        if value >= 60 { return .green }
        if value >= 40 { return .orange }
        return .red
    }

    private func matchColor(_ value: Double) -> Color {
        if value >= 80 { return .green }
        if value >= 50 { return .orange }
        return .red
    }

    private func noMatchColor(_ value: Double) -> Color {
        if value >= 40 { return .green }
        if value >= 20 { return .orange }
        return .red
    }

    // MARK: - Data Loading

    private func loadData() async {
        do {
            paperStats = try await TourDataLoader.shared.loadPaperStats()
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}

// MARK: - Display Row

private struct AccuracyDisplayRow: Identifiable {
    let id = UUID()
    let method: String
    let overall: String
    let overallValue: Double
    let matchAcc: String
    let matchValue: Double
    let noMatchAcc: String
    let noMatchValue: Double
}

// MARK: - Previews

#Preview("Methods Compared - Light") {
    ScrollView {
        MethodsComparedSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 800)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.light)
}

#Preview("Methods Compared - Dark") {
    ScrollView {
        MethodsComparedSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 800)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}
