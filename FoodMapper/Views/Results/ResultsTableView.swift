import SwiftUI

/// Results table with filtering and sorting
struct ResultsTableView: View {
    let results: [MatchResult]  // Paginated results for display
    let totalFilteredCount: Int  // Total count across all pages
    let threshold: Double
    let reviewDecisions: [UUID: ReviewDecision]
    let cachedCategories: [UUID: MatchCategory]
    @Binding var selection: Set<MatchResult.ID>
    @Binding var sortOrder: [KeyPathComparator<MatchResult>]
    @Binding var searchText: String
    @Binding var currentPage: Int
    let totalPages: Int
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            ResultsToolbar(
                searchText: $searchText,
                totalCount: totalFilteredCount
            )

            Divider()

            // Table
            ScrollViewReader { proxy in
                Table(results, selection: $selection, sortOrder: $sortOrder) {
                    // Row number (plain, no indicator dot)
                    TableColumn("#", value: \.inputRow) { result in
                        Text("\(result.inputRow + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .background(rowBackground(for: result.id))
                    }
                    .width(36)

                    // Input
                    TableColumn("Input", value: \.inputText) { result in
                        Text(result.inputText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(result.inputText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowBackground(for: result.id))
                    }
                    .width(min: 220, ideal: 300)

                    // Target -- pure data, shows override text when applicable
                    TableColumn("Target") { result in
                        let displayText: String? = {
                            if let decision = reviewDecisions[result.id],
                               decision.status == .overridden,
                               let overrideText = decision.overrideMatchText {
                                return overrideText
                            }
                            return result.matchText
                        }()

                        Group {
                            if let text = displayText {
                                Text(text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .help(text)
                            } else {
                                Text("No candidates")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rowBackground(for: result.id))
                    }
                    .width(min: 220, ideal: 340)

                    // Score -- colored dot + plain percentage (shows override score when overridden)
                    TableColumn("Score", value: \.score) { result in
                        let displayScore: Double = {
                            if let decision = reviewDecisions[result.id],
                               decision.status == .overridden,
                               let overrideScore = decision.overrideScore {
                                return overrideScore
                            }
                            return result.score
                        }()
                        ScoreIndicator(score: displayScore)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowBackground(for: result.id))
                    }
                    .width(52)

                    // Status -- 3 outcomes with who-decided badge
                    TableColumn("Status") { result in
                        UnifiedStatusPill(
                            category: cachedCategories[result.id] ?? .noMatch,
                            reviewStatus: reviewDecisions[result.id]?.status
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rowBackground(for: result.id))
                    }
                    .width(min: 84, ideal: 84)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .tutorialAnchor("resultsTable")
                .overlay {
                    if results.isEmpty {
                        ContentUnavailableView {
                            Label("No Results", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No items match the current filter.\nSelect \"All\" to see all results.")
                        }
                    }
                }
                .onChange(of: appState.tableScrollTarget) { _, target in
                    guard let target else { return }
                    // Small delay lets page change render new rows before scrolling
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        // Clear so the same ID can be re-triggered
                        DispatchQueue.main.async {
                            appState.tableScrollTarget = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Row Background

    /// Subtle row background tint for human-reviewed items
    func rowBackground(for resultId: UUID) -> Color {
        guard let decision = reviewDecisions[resultId] else { return .clear }
        let isDark = colorScheme == .dark
        switch decision.status {
        case .accepted:
            return Color.green.opacity(isDark ? 0.22 : 0.08)
        case .rejected:
            return Color.red.opacity(isDark ? 0.18 : 0.06)
        case .overridden:
            return Color.indigo.opacity(isDark ? 0.22 : 0.08)
        default:
            return .clear
        }
    }
}

/// Toolbar for results table -- search field on left, category filter pills on right
struct ResultsToolbar: View {
    @EnvironmentObject var appState: AppState
    @Binding var searchText: String
    let totalCount: Int
    @State private var localSearchText = ""
    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Compute counts once per render instead of 3 separate computed property evaluations
        let counts = appState.categoryCounts()
        let matchCount = counts[.match, default: 0] + counts[.confirmedMatch, default: 0]
        let needsReviewCount = counts[.needsReview, default: 0]
        let noMatchCount = counts[.noMatch, default: 0] + counts[.confirmedNoMatch, default: 0]

        HStack(spacing: Spacing.md) {
            // Search
            HStack(spacing: Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                TextField("Search", text: $localSearchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($isSearchFocused)
                    .onKeyPress(.escape) {
                        if !localSearchText.isEmpty {
                            localSearchText = ""
                            searchText = ""
                            return .handled
                        }
                        return .ignored
                    }

                if !localSearchText.isEmpty {
                    Button {
                        localSearchText = ""
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )
            .frame(maxWidth: 220)
            .task(id: localSearchText) {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch { return }
                searchText = localSearchText
            }
            .onAppear { localSearchText = searchText }
            .onChange(of: searchText) { _, newText in
                if localSearchText != newText {
                    localSearchText = newText
                }
            }
            .onChange(of: appState.searchFieldFocused) { _, shouldFocus in
                if shouldFocus {
                    isSearchFocused = true
                    appState.searchFieldFocused = false
                }
            }
            .onChange(of: isSearchFocused) { _, focused in
                appState.inspectorFieldFocused = focused
            }

            Spacer()

            // Progress bar (compact, only when reviewDecisions exist)
            if !appState.reviewDecisions.isEmpty {
                compactProgressBar(matchCount: matchCount, needsReviewCount: needsReviewCount, noMatchCount: noMatchCount)
            }

            // Category filter pills
            if !appState.reviewDecisions.isEmpty {
                reviewContent(matchCount: matchCount, needsReviewCount: needsReviewCount, noMatchCount: noMatchCount)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Review Mode Content

    @ViewBuilder
    private func reviewContent(matchCount: Int, needsReviewCount: Int, noMatchCount: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            allFilterPill

            categoryFilterPill(
                filter: .match,
                label: "Match",
                count: matchCount,
                dotColor: MatchCategory.match.color
            )

            categoryFilterPill(
                filter: .needsReview,
                label: "Needs Review",
                count: needsReviewCount,
                dotColor: MatchCategory.needsReview.color
            )
            categoryFilterPill(
                filter: .noMatch,
                label: "No Match",
                count: noMatchCount,
                dotColor: MatchCategory.noMatch.color
            )
        }
        .tutorialAnchor("filterPills")
    }

    // MARK: - Compact Progress Bar

    private func compactProgressBar(matchCount: Int, needsReviewCount: Int, noMatchCount: Int) -> some View {
        GeometryReader { geo in
            let total = max(appState.results.count, 1)
            let matchedWidth = geo.size.width * CGFloat(matchCount) / CGFloat(total)
            let reviewWidth = geo.size.width * CGFloat(needsReviewCount) / CGFloat(total)

            HStack(spacing: 0) {
                if matchCount > 0 {
                    Rectangle().fill(Color.green)
                        .frame(width: matchedWidth)
                }
                if needsReviewCount > 0 {
                    Rectangle().fill(MatchCategory.needsReview.color)
                        .frame(width: reviewWidth)
                }
                if noMatchCount > 0 {
                    Rectangle().fill(Color(nsColor: .secondaryLabelColor))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
            )
        }
        .frame(width: 120, height: 4)
        .animation(.easeInOut(duration: 0.3), value: matchCount)
    }

    // MARK: - All Filter Pill

    private var allFilterPill: some View {
        let isActive = appState.resultsFilter == .all

        return Button {
            withAnimation(Animate.quick) {
                appState.resultsFilter = .all
            }
        } label: {
            Text("All")
                .font(.caption)
                .fontWeight(isActive ? .semibold : .medium)
                .foregroundStyle(isActive ? .primary : .secondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(
                    Color.accentColor.opacity(isActive
                        ? (colorScheme == .light ? 0.12 : 0.14)
                        : (colorScheme == .light ? 0.04 : 0.03))
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isActive
                                ? Color.accentColor.opacity(colorScheme == .light ? 0.30 : 0.35)
                                : Color.accentColor.opacity(colorScheme == .light ? 0.10 : 0.08),
                            lineWidth: 0.75
                        )
                )
                .shadow(
                    color: isActive
                        ? (colorScheme == .light
                            ? Color.accentColor.opacity(0.18)
                            : Color.accentColor.opacity(0.25))
                        : Color.clear,
                    radius: isActive ? 4 : 0,
                    y: isActive ? 1.5 : 0
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category Filter Pill

    private func categoryFilterPill(
        filter: ResultsFilter,
        label: String,
        count: Int,
        dotColor: Color
    ) -> some View {
        let isActive = appState.resultsFilter == filter
        // noMatch uses tertiaryLabelColor which is too faint for selected state
        let selectedColor: Color = (filter == .noMatch)
            ? Color(nsColor: .secondaryLabelColor)
            : dotColor

        return Button {
            withAnimation(Animate.quick) {
                if isActive {
                    appState.resultsFilter = .all
                } else {
                    appState.resultsFilter = filter
                }
            }
        } label: {
            HStack(spacing: Spacing.xxs) {
                Circle()
                    .fill(dotColor)
                    .frame(width: Size.statusDot, height: Size.statusDot)

                Text("\(label): \(count)")
                    .font(.caption)
                    .fontWeight(isActive ? .semibold : .medium)
                    .monospacedDigit()
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(
                selectedColor.opacity(isActive
                    ? (colorScheme == .light ? 0.18 : 0.22)
                    : (colorScheme == .light ? 0.05 : 0.04))
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive
                            ? selectedColor.opacity(colorScheme == .light ? 0.45 : 0.55)
                            : Color.primary.opacity(colorScheme == .light ? 0.06 : 0.06),
                        lineWidth: 0.75
                    )
            )
            .shadow(
                color: isActive
                    ? (colorScheme == .light
                        ? selectedColor.opacity(0.35)
                        : selectedColor.opacity(0.30))
                    : Color.clear,
                radius: isActive ? 4 : 0,
                y: isActive ? 1.5 : 0
            )
        }
        .buttonStyle(.plain)
    }
}

/// Preview.app-style pagination with first/last buttons and editable page field
struct PaginationControls: View {
    @Binding var currentPage: Int
    let totalPages: Int

    @State private var pageText: String = ""
    @FocusState private var isPageFieldFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            // First page
            Button {
                currentPage = 0
            } label: {
                Image(systemName: "chevron.left.2")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(currentPage == 0)
            .accessibilityLabel("First page")

            // Previous page
            Button {
                currentPage = max(0, currentPage - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(currentPage == 0)
            .accessibilityLabel("Previous page")

            // Editable page number
            TextField("", text: $pageText)
                .textFieldStyle(.plain)
                .font(.caption)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 36)
                .padding(.horizontal, Spacing.xxs)
                .padding(.vertical, Spacing.xxxs)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
                )
                .focused($isPageFieldFocused)
                .onSubmit {
                    jumpToPage()
                }
                .onAppear {
                    pageText = "\(currentPage + 1)"
                }
                .onChange(of: currentPage) { _, newPage in
                    if !isPageFieldFocused {
                        pageText = "\(newPage + 1)"
                    }
                }
                .onChange(of: isPageFieldFocused) { _, focused in
                    if !focused {
                        // Reset to current page if user defocuses without submitting
                        pageText = "\(currentPage + 1)"
                    }
                }

            Text("of \(totalPages)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Next page
            Button {
                currentPage = min(totalPages - 1, currentPage + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(currentPage >= totalPages - 1)
            .accessibilityLabel("Next page")

            // Last page
            Button {
                currentPage = totalPages - 1
            } label: {
                Image(systemName: "chevron.right.2")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(currentPage >= totalPages - 1)
            .accessibilityLabel("Last page")
        }
    }

    private func jumpToPage() {
        guard let pageNum = Int(pageText) else {
            pageText = "\(currentPage + 1)"
            return
        }
        let clamped = max(1, min(pageNum, totalPages))
        currentPage = clamped - 1
        pageText = "\(clamped)"
    }
}

#Preview("Results Table - Simple Mode - Light") {
    ResultsTableView(
        results: PreviewHelpers.sampleResults,
        totalFilteredCount: PreviewHelpers.sampleResults.count,
        threshold: 0.85,
        reviewDecisions: [:],
        cachedCategories: [:],

        selection: .constant([]),
        sortOrder: .constant([]),
        searchText: .constant(""),
        currentPage: .constant(0),
        totalPages: 1
    )
    .environmentObject(PreviewHelpers.resultsState())
    .frame(width: 1000, height: 400)
}

#Preview("Results Table - Advanced Mode - Dark") {
    ResultsTableView(
        results: PreviewHelpers.sampleResults,
        totalFilteredCount: PreviewHelpers.sampleResults.count,
        threshold: 0.85,
        reviewDecisions: [:],
        cachedCategories: [:],

        selection: .constant([]),
        sortOrder: .constant([]),
        searchText: .constant(""),
        currentPage: .constant(0),
        totalPages: 1
    )
    .environmentObject(PreviewHelpers.resultsState())
    .frame(width: 1000, height: 400)
    .preferredColorScheme(.dark)
}

#Preview("Results Table with Reviews - Light") {
    let state = PreviewHelpers.reviewBannerState()
    ResultsTableView(
        results: state.paginatedResults,
        totalFilteredCount: state.results.count,
        threshold: 0.85,
        reviewDecisions: state.reviewDecisions,
        cachedCategories: state.cachedCategories,

        selection: .constant([]),
        sortOrder: .constant([]),
        searchText: .constant(""),
        currentPage: .constant(0),
        totalPages: 1
    )
    .environmentObject(state)
    .frame(width: 1000, height: 400)
}

#Preview("Results Table with Reviews - Dark") {
    let state = PreviewHelpers.reviewBannerState()
    ResultsTableView(
        results: state.paginatedResults,
        totalFilteredCount: state.results.count,
        threshold: 0.85,
        reviewDecisions: state.reviewDecisions,
        cachedCategories: state.cachedCategories,

        selection: .constant([]),
        sortOrder: .constant([]),
        searchText: .constant(""),
        currentPage: .constant(0),
        totalPages: 1
    )
    .environmentObject(state)
    .frame(width: 1000, height: 400)
    .preferredColorScheme(.dark)
}
