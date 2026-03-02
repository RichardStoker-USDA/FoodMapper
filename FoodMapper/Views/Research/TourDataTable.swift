import SwiftUI

// MARK: - Tour Data Table

/// A clean data table following Activity Monitor / Numbers patterns.
/// No alternating row colors, no column dividers, promoted fonts.
struct TourDataTable<Row: Identifiable>: View {
    let columns: [TourTableColumn<Row>]
    let rows: [Row]
    let highlightRow: ((Row) -> TourRowHighlight)?
    let compact: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(
        columns: [TourTableColumn<Row>],
        rows: [Row],
        highlightRow: ((Row) -> TourRowHighlight)? = nil,
        compact: Bool = false
    ) {
        self.columns = columns
        self.rows = rows
        self.highlightRow = highlightRow
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            centeredTableContent {
                HStack(spacing: 0) {
                    ForEach(columns.indices, id: \.self) { index in
                        let col = columns[index]
                        Text(col.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: col.maxWidth, alignment: col.alignment)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, compact ? Spacing.xxs : Spacing.sm)
                    }
                }
            }
            .background(headerBackground)
            .overlay(alignment: .bottom) {
                Divider()
            }

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let highlight = highlightRow?(row) ?? .none
                centeredTableContent {
                    HStack(spacing: 0) {
                        ForEach(columns.indices, id: \.self) { colIndex in
                            let col = columns[colIndex]
                            col.content(row)
                                .font(compact ? .callout : .body)
                                .frame(maxWidth: col.maxWidth, alignment: col.alignment)
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, compact ? Spacing.xxs : Spacing.sm)
                        }
                    }
                }
                .background(rowBackground(highlight: highlight))

                if index < rows.count - 1 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .showcaseCard(cornerRadius: 8)
    }

    @ViewBuilder
    private var headerBackground: some View {
        if colorScheme == .dark {
            Color.white.opacity(0.06)
        } else {
            Color.black.opacity(0.035)
        }
    }

    private var centeredColumnsWidth: CGFloat? {
        let widths = columns.map { $0.maxWidth ?? .infinity }
        guard widths.allSatisfy(\.isFinite) else { return nil }
        let horizontalPadding = CGFloat(columns.count) * (Spacing.sm * 2)
        return widths.reduce(0, +) + horizontalPadding
    }

    @ViewBuilder
    private func centeredTableContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if let width = centeredColumnsWidth {
            content()
                .frame(width: width, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func rowBackground(highlight: TourRowHighlight) -> some View {
        switch highlight {
        case .correct:
            Color.green.opacity(colorScheme == .dark ? 0.06 : 0.10)
        case .incorrect:
            Color.red.opacity(colorScheme == .dark ? 0.06 : 0.12)
        case .none:
            Color.clear
        }
    }
}

// MARK: - Table Column Definition

struct TourTableColumn<Row> {
    let title: String
    let maxWidth: CGFloat?
    let alignment: Alignment
    let content: (Row) -> AnyView

    init(
        _ title: String,
        maxWidth: CGFloat? = .infinity,
        alignment: Alignment = .leading,
        @ViewBuilder content: @escaping (Row) -> some View
    ) {
        self.title = title
        self.maxWidth = maxWidth
        self.alignment = alignment
        self.content = { AnyView(content($0)) }
    }
}

// MARK: - Row Highlight

enum TourRowHighlight {
    case correct
    case incorrect
    case none
}

// MARK: - Match Example Row (convenience type for simple match display)

struct TourMatchExample: Identifiable {
    let id = UUID()
    let input: String
    let match: String
    let isCorrect: Bool
}

// MARK: - Accuracy Row (convenience type for method comparison)

struct TourAccuracyRow: Identifiable {
    let id = UUID()
    let method: String
    let overall: String
    let matchAcc: String
    let noMatchAcc: String
}

// MARK: - Previews

#Preview("Data Table - Match Examples") {
    let examples = [
        TourMatchExample(input: "Chickpeas, mature seeds, raw", match: "Canned garbanzo beans", isCorrect: true),
        TourMatchExample(input: "Butter, salted", match: "Unsalted butter", isCorrect: true),
        TourMatchExample(input: "Spices, pepper, black", match: "Ground cumin", isCorrect: false),
    ]

    TourDataTable(
        columns: [
            TourTableColumn("Input", maxWidth: 250) { row in
                Text(row.input).lineLimit(2)
            },
            TourTableColumn("Best Match", maxWidth: 200) { row in
                Text(row.match).lineLimit(2)
            },
            TourTableColumn("", maxWidth: 30, alignment: .center) { row in
                Image(systemName: row.isCorrect ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(row.isCorrect ? .green : .red)
            }
        ],
        rows: examples,
        highlightRow: { $0.isCorrect ? .correct : .incorrect }
    )
    .padding(Spacing.xxl)
    .frame(width: 680)
}

#Preview("Data Table - Dark") {
    let rows = [
        TourAccuracyRow(method: "Fuzzy Matching", overall: "25%", matchAcc: "28%", noMatchAcc: "22%"),
        TourAccuracyRow(method: "TF-IDF", overall: "40%", matchAcc: "45%", noMatchAcc: "34%"),
        TourAccuracyRow(method: "Hybrid Haiku", overall: "65.4%", matchAcc: "82.2%", noMatchAcc: "46.6%"),
    ]

    TourDataTable(
        columns: [
            TourTableColumn("Method", maxWidth: 150) { row in Text(row.method) },
            TourTableColumn("Overall", maxWidth: 80, alignment: .center) { row in Text(row.overall) },
            TourTableColumn("Match", maxWidth: 80, alignment: .center) { row in Text(row.matchAcc) },
            TourTableColumn("No-Match", maxWidth: 80, alignment: .center) { row in Text(row.noMatchAcc) },
        ],
        rows: rows
    )
    .padding(Spacing.xxl)
    .frame(width: 680)
    .preferredColorScheme(.dark)
}
