import SwiftUI

/// Inspector panel for the review workflow.
/// Slides in from right via .inspector() modifier on the results view.
struct ReviewInspectorPanel: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var overrideSearchText = ""
    @State private var debouncedOverrideSearchText = ""
    @State private var localNoteText = ""
    @State private var hoveredCandidateId: UUID?
    @State private var hoveredOverrideId: UUID?
    @State private var showAllCandidates = false
    @State private var overrideExpanded = false
    @State private var notesExpanded = false
    @State private var reasoningExpanded = true
    @State private var bulkNoteText = ""
    @State private var showGuidedReviewInfo = false
    @State private var isMatchHovered = false
    @State private var isNoMatchHovered = false
    @FocusState private var isOverrideFieldFocused: Bool
    @FocusState private var isNoteFieldFocused: Bool
    @FocusState private var isBulkNoteFieldFocused: Bool

    private let maxVisibleCandidates = 5

    /// The currently selected result to inspect (from table selection, O(1) via index)
    var selectedResult: MatchResult? {
        guard let firstId = appState.selection.first else { return nil }
        return appState.resultsByID[firstId] ?? appState.results.first { $0.id == firstId }
    }

    /// Search results across all candidates in the session for override (uses pre-built index)
    private var overrideSearchResults: [MatchCandidate] {
        guard debouncedOverrideSearchText.count >= 2 else { return [] }
        return appState.searchCandidates(query: debouncedOverrideSearchText)
    }

    /// Whether all pending items are resolved (no more needsReview items)
    private var isReviewComplete: Bool {
        !appState.results.contains { appState.cachedCategories[$0.id] == .needsReview }
        && !appState.reviewDecisions.isEmpty
    }

    /// Whether the current selection is multi-select (more than one row)
    private var isMultiSelect: Bool {
        appState.selection.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable content area
            ScrollView {
                VStack(spacing: Spacing.md) {
                    headerSection

                    // Completion feedback (when all items reviewed)
                    if !appState.results.contains(where: { appState.cachedCategories[$0.id] == .needsReview })
                        && !appState.reviewDecisions.isEmpty
                        && !isMultiSelect {
                        VStack(spacing: Spacing.xs) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: Size.iconMedium))
                                .foregroundStyle(.green)
                            Text("All items reviewed")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                    }

                    if isMultiSelect {
                        multiSelectContent
                    } else if isReviewComplete && appState.isReviewMode {
                        ReviewCompletionView(
                            totalReviewed: appState.reviewCompletedCount,
                            onDone: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    appState.isReviewMode = false
                                    appState.resultsFilter = .all
                                }
                            },
                            onExport: { appState.exportResults() }
                        )
                    } else if let result = selectedResult {
                        inspectorContent(for: result)
                    } else {
                        emptySelection
                    }
                }
                .padding(Spacing.md)
            }

            // Pinned action buttons (single-select only, multi-select has inline buttons)
            if !isMultiSelect, let result = selectedResult, !appState.reviewDecisions.isEmpty {
                Divider()
                actionButtons(for: result, decision: appState.reviewDecisions[result.id])
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            // Keyboard hints (visible when inspector is open)
            if appState.showInspector {
                Divider()
                ReviewKeyboardHints(isGuidedReview: appState.isReviewMode)
                    .actionButtonsCard(colorScheme: colorScheme)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .task(id: overrideSearchText) {
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch { return }
            debouncedOverrideSearchText = overrideSearchText
        }
        .onChange(of: appState.selection) { _, _ in
            // Reset transient state when selection changes
            showAllCandidates = false
            bulkNoteText = ""
            appState.cancelResetConfirmation()
            appState.cancelBulkResetConfirmation()
            // Sync local note text for new selection
            if let result = selectedResult {
                localNoteText = appState.reviewDecisions[result.id]?.note ?? ""
            } else {
                localNoteText = ""
            }
        }
        .onChange(of: isOverrideFieldFocused) { _, focused in
            appState.inspectorFieldFocused = focused || isNoteFieldFocused || isBulkNoteFieldFocused
        }
        .onChange(of: isNoteFieldFocused) { _, focused in
            appState.inspectorFieldFocused = isOverrideFieldFocused || focused || isBulkNoteFieldFocused
        }
        .onChange(of: isBulkNoteFieldFocused) { _, focused in
            appState.inspectorFieldFocused = isOverrideFieldFocused || isNoteFieldFocused || focused
        }
        .onChange(of: appState.reviewDecisions.count) { _, _ in
            // Sync local note when decisions change externally (reset, undo, etc.)
            guard let resultId = selectedResult?.id, !isNoteFieldFocused else { return }
            let expected = appState.reviewDecisions[resultId]?.note ?? ""
            if localNoteText != expected {
                localNoteText = expected
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            if appState.isReviewMode {
                Label("Guided Review", systemImage: "play.circle")
                    .font(.headline)
                    .foregroundStyle(MatchCategory.match.color)
            } else {
                Label("Details", systemImage: "list.bullet.rectangle")
                    .font(.headline)
            }
            Spacer()
            if appState.isReviewMode {
                Button {
                    showGuidedReviewInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showGuidedReviewInfo, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Guided Review")
                            .font(.subheadline.weight(.semibold))
                        Text("Items advance automatically after each decision.\n\nReturn \u{2192} Match\nDelete \u{2192} No Match\nR (x2) \u{2192} Reset\n\u{2190} \u{2192} \u{2192} Navigate\n1-5 \u{2192} Select Candidate\nCmd+Z \u{2192} Undo\nEsc \u{2192} Exit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Spacing.lg)
                    .frame(width: 220)
                }

                Button {
                    if let undoneId = appState.undoLastReview() {
                        appState.selection = [undoneId]
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.interactiveText)
                .disabled(!appState.canUndoReview)
                .help("Undo last review (Cmd+Z)")

                Text("\(appState.reviewPendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - Empty State

    private var emptySelection: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "arrow.left.circle")
                .font(.system(size: Size.iconHero))
                .foregroundStyle(.secondary)
            Text("Select a row to review")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Use arrow keys to navigate")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }

    // MARK: - Multi-Select Content

    private var multiSelectContent: some View {
        let selectedIds = appState.selection
        let count = selectedIds.count
        let cats = appState.cachedCategories

        // Count breakdown by category
        let matchCount = selectedIds.filter { id in
            let c = cats[id] ?? .noMatch
            return c == .match || c == .confirmedMatch
        }.count
        let reviewCount = selectedIds.filter { cats[$0] == .needsReview }.count
        let noMatchCount = selectedIds.filter { id in
            let c = cats[id] ?? .noMatch
            return c == .noMatch || c == .confirmedNoMatch
        }.count

        return VStack(spacing: Spacing.md) {
            // Summary header
            inspectorCard {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Image(systemName: "square.stack")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("\(count) items selected")
                            .font(.headline)
                    }

                    // Category breakdown
                    HStack(spacing: Spacing.md) {
                        if reviewCount > 0 {
                            HStack(spacing: Spacing.xxxs) {
                                Circle()
                                    .fill(MatchCategory.needsReview.color)
                                    .frame(width: Size.statusDot, height: Size.statusDot)
                                Text("\(reviewCount) Needs Review")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if matchCount > 0 {
                            HStack(spacing: Spacing.xxxs) {
                                Circle()
                                    .fill(MatchCategory.match.color)
                                    .frame(width: Size.statusDot, height: Size.statusDot)
                                Text("\(matchCount) Match")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if noMatchCount > 0 {
                            HStack(spacing: Spacing.xxxs) {
                                Circle()
                                    .fill(Color(nsColor: .secondaryLabelColor))
                                    .frame(width: Size.statusDot, height: Size.statusDot)
                                Text("\(noMatchCount) No Match")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // Bulk action buttons
            VStack(spacing: Spacing.sm) {
                Text("BULK ACTIONS")
                    .technicalLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: Spacing.sm) {
                    Button {
                        appState.bulkSetMatch(ids: selectedIds)
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "checkmark.circle")
                            Text("Match All (\(count))")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .liquidGlassButtonStyle(color: .green)
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.bulkSetNoMatch(ids: selectedIds)
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "xmark.circle")
                            Text("No Match All (\(count))")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .liquidGlassButtonStyle(color: .secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    appState.handleBulkResetConfirmation(ids: selectedIds)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.counterclockwise")
                        Text(appState.bulkResetPendingConfirmation ? "Confirm Reset All" : "Reset All (\(count))")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appState.bulkResetPendingConfirmation ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        Capsule()
                            .fill(appState.bulkResetPendingConfirmation ? Color.red.opacity(0.8) : Color.primary.opacity(0.05))
                    }
                    .overlay {
                        Capsule()
                            .strokeBorder(appState.bulkResetPendingConfirmation ? Color.red : Color.primary.opacity(0.1), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help("Reset selected items to original state")
            }
            .actionButtonsCard(colorScheme: colorScheme)
            .tutorialAnchor("bulkActionsSection")

            // Bulk note field
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("RESEARCHER NOTE")
                    .technicalLabel()

                TextField("Add note to all selected...", text: $bulkNoteText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isBulkNoteFieldFocused)
                    .lineLimit(3)
                    .padding(Spacing.sm)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onSubmit {
                        if !bulkNoteText.isEmpty {
                            appState.bulkSetNote(ids: selectedIds, note: bulkNoteText)
                            bulkNoteText = ""
                        }
                    }

                if !bulkNoteText.isEmpty {
                    Button {
                        appState.bulkSetNote(ids: selectedIds, note: bulkNoteText)
                        bulkNoteText = ""
                    } label: {
                        Label("Apply Note", systemImage: "checkmark")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Inspector Content

    @ViewBuilder
    private func inspectorContent(for result: MatchResult) -> some View {
        let decision = appState.reviewDecisions[result.id]

        // Input section
        inspectorCard {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("INPUT")
                    .technicalLabel()

                Text(result.inputText)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }

        // Matched To / No Match section
        if let matchText = result.matchText {
            inspectorCard {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    // Header: label + score pill + status pill
                    // When overridden, score pill reflects the override score
                    let displayScore = decision?.overrideScore ?? result.score
                    let displayScorePercentage = Int(displayScore * 100)

                    HStack {
                        Text("MATCHED TO")
                            .technicalLabel()
                        Spacer()
                        HStack(spacing: Spacing.xxs) {
                            Text("\(displayScorePercentage)%")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.scoreBadgeForeground(displayScore))
                                .padding(.horizontal, Spacing.sm)
                                .padding(.vertical, 2)
                                .background(Color.scoreColor(displayScore).opacity(colorScheme == .dark ? 0.8 : 1.0))
                                .clipShape(Capsule())

                            UnifiedStatusPill(
                                category: appState.category(for: result.id)
                            )
                        }
                    }

                    // Body: show override as primary when present, otherwise pipeline match
                    if let overrideText = decision?.overrideMatchText {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            if decision?.status == .overridden {
                                Image(systemName: "arrow.triangle.swap")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.indigo)
                            }
                            Text(overrideText)
                                .font(.body)
                                .textSelection(.enabled)
                        }

                        // Subtle secondary pill showing the original pipeline match
                        HStack(spacing: Spacing.xxs) {
                            Text("Original:")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Text(matchText)
                                .font(.caption)
                                .foregroundStyle(colorScheme == .dark ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxxs + 1)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(colorScheme == .dark ? 0.16 : 0.10))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.secondary.opacity(colorScheme == .dark ? 0.2 : 0.12), lineWidth: 0.75)
                        )
                        .padding(.top, Spacing.xxxs)
                    } else {
                        Text(matchText)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                }
            }
        } else {
            // No match found
            inspectorCard {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        if decision?.overrideMatchText != nil {
                            Text("MATCHED TO")
                                .technicalLabel()
                        } else {
                            Text("NO MATCH")
                                .technicalLabel()
                        }
                        Spacer()
                        HStack(spacing: Spacing.xxs) {
                            // Show score pill when user has overridden with a score
                            if let overrideScore = decision?.overrideScore {
                                let overrideScorePercentage = Int(overrideScore * 100)
                                Text("\(overrideScorePercentage)%")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.scoreBadgeForeground(overrideScore))
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, 2)
                                    .background(Color.scoreColor(overrideScore).opacity(colorScheme == .dark ? 0.8 : 1.0))
                                    .clipShape(Capsule())
                            }

                            UnifiedStatusPill(
                                category: appState.category(for: result.id)
                            )
                        }
                    }

                    // Show override prominently if user selected a candidate
                    if let overrideText = decision?.overrideMatchText {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            if decision?.status == .overridden {
                                Image(systemName: "arrow.triangle.swap")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.indigo)
                            }
                            Text(overrideText)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("Select a candidate below to assign a match")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        // Candidates list
        if let candidates = result.candidates, !candidates.isEmpty {
            inspectorCard {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    let isNoMatch = result.matchText == nil
                    Text(isNoMatch ? "TOP CANDIDATES" : "ALTERNATIVES")
                        .technicalLabel()
                        .padding(.leading, Spacing.xxs)

                    if isNoMatch {
                        let profile = ThresholdProfile.defaults(for: result.scoreType)
                        Text("No match exceeded the \(Int(profile.matchThreshold * 100))% confidence threshold")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, Spacing.xxs)
                    }

                    let visibleCandidates = showAllCandidates
                        ? Array(candidates.enumerated())
                        : Array(candidates.prefix(maxVisibleCandidates).enumerated())

                    VStack(spacing: Spacing.xxxs) {
                        ForEach(visibleCandidates, id: \.element.id) { index, candidate in
                            candidateRow(candidate, index: index, resultId: result.id, decision: decision)
                        }
                    }

                    if candidates.count > maxVisibleCandidates && !showAllCandidates {
                        Button {
                            withAnimation(Animate.standard) {
                                showAllCandidates = true
                            }
                        } label: {
                            Text("Show all \(candidates.count) candidates")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.interactiveText)
                        .padding(.top, Spacing.xxs)
                        .padding(.leading, Spacing.xxs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .reportTutorialFrame("inspectorCandidates", to: appState)
        }

        // LLM reasoning
        if let reasoning = result.llmReasoning, reasoning.count > 5 {
            inspectorCard {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            reasoningExpanded.toggle()
                        }
                    }) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "cpu")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text("LLM REASONING")
                                .technicalLabel()

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(reasoningExpanded ? 90 : 0))
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if reasoningExpanded {
                        Text(reasoning)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .padding(Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .clipped()
                    }
                }
            }
        }

        // Override search
        inspectorCard {
            overrideSearchSection(for: result)
        }

        // Note field
        inspectorCard {
            noteField(for: result, decision: decision)
        }
    }

    // MARK: - Card Styling Helpers

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(white: 0.15).opacity(0.98) // More solid to hide underlying 'ovals'
            : Color.white
    }

    private var cardBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.15)
    }

    private var cardShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.6) : Color.black.opacity(0.15)
    }

    private var cardBorderWidth: CGFloat { 1.0 }

    private var cardShadowPrimary: (color: Color, radius: CGFloat, y: CGFloat) {
        colorScheme == .dark
            ? (Color.black.opacity(0.50), 14, 7)
            : (Color.black.opacity(0.15), 10, 5)
    }

    private var cardShadowSecondary: (color: Color, radius: CGFloat) {
        colorScheme == .dark
            ? (Color.black.opacity(0.25), 3)
            : (Color.black.opacity(0.08), 3)
    }

    // MARK: - Inspector Card

    /// Premium container for grouping related inspector content (matches Behind the Research theme).
    @ViewBuilder
    private func inspectorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let cornerRadius: CGFloat = 10
        let borderWidth: CGFloat = 1.0

        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.cardBackground(for: colorScheme))
                }
                .shadow(
                    color: Color.cardShadow(for: colorScheme),
                    radius: colorScheme == .dark ? 12 : 9,
                    y: colorScheme == .dark ? 6 : 4
                )
                .shadow(
                    color: colorScheme == .dark ? Color.black.opacity(0.20) : Color.black.opacity(0.06),
                    radius: 2,
                    y: 1
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: borderWidth)
            }
            .overlay {
                if colorScheme == .light {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                        .padding(0.5)
                }
            }
            .id(colorScheme) // Fixes lag when switching light/dark mode
    }

    // MARK: - Candidate Row

    private func candidateRow(_ candidate: MatchCandidate, index: Int, resultId: UUID,
                              decision: ReviewDecision?) -> some View {
        let isSelected = decision?.selectedCandidateIndex == index
        let isTopMatch = index == 0
        let isHovered = hoveredCandidateId == candidate.id

        return Button {
            if let result = appState.resultsByID[resultId], result.isPipelineMatch(candidate) {
                appState.setReviewDecision(.accepted, for: resultId, candidateIndex: index)
            } else {
                appState.setReviewDecision(
                    .overridden, for: resultId,
                    overrideText: candidate.matchText,
                    overrideID: candidate.matchID,
                    overrideScore: candidate.score,
                    candidateIndex: index
                )
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                // Rank number
                Text("\(index + 1)")
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .green : .secondary)
                    .frame(width: Spacing.lg)

                // Candidate text
                VStack(alignment: .leading, spacing: 0) {
                    Text(candidate.matchText)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                }

                Spacer(minLength: Spacing.xs)

                // Score dot + percentage
                HStack(spacing: Spacing.xxs) {
                    Circle()
                        .fill(Color.scoreColor(candidate.score))
                        .frame(width: 6, height: 6)
                    Text("\(Int(candidate.score * 100))%")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Color.scoreColor(candidate.score))
                }

                // Status icon
                if isSelected {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if isTopMatch {
                    Image(systemName: "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.green.opacity(0.12)
                            : (isHovered ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .animation(Animate.quick, value: hoveredCandidateId)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.green.opacity(0.25) : Color.clear,
                        lineWidth: 0.75
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredCandidateId = isHovering ? candidate.id : nil
        }
        .help("Cmd+\(index + 1) to select")
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private func actionButtons(for result: MatchResult, decision: ReviewDecision?) -> some View {
        let currentStatus = decision?.status ?? .pending

        let matchDisabled = currentStatus == .accepted || currentStatus == .overridden
        let noMatchDisabled = currentStatus == .rejected

        VStack(spacing: Spacing.sm) {
            // Reset button above main actions (visible only for items with human decisions)
            if appState.hasHumanDecision(for: result.id) {
                Button {
                    appState.handleResetConfirmation(for: result.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2.weight(.bold))
                        Text(appState.resetPendingConfirmation ? "Confirm Reset" : "Reset Decision")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(appState.resetPendingConfirmation ? Color.white : (colorScheme == .dark ? Color.white : Color.primary).opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(appState.resetPendingConfirmation ? Color.red.opacity(0.9) : Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.08))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                appState.resetPendingConfirmation ? Color.red : Color.primary.opacity(0.1),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 2)
                .help("Reset to original auto-triage state (R, press twice)")
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: appState.resetPendingConfirmation)
                .reportTutorialFrame("inspectorResetButton", to: appState)
            }

            HStack(spacing: Spacing.sm) {
                // Match button
                VStack(spacing: 0) {
                    Button {
                        appState.setReviewDecision(.accepted, for: result.id)
                        appState.advanceToNextPending()
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "checkmark.circle")
                                .font(.subheadline.weight(.semibold))
                            Text("Match")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .liquidGlassButtonStyle(
                            color: Color.green,
                            cornerRadius: 8,
                            isActive: isMatchHovered && !matchDisabled
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(matchDisabled)
                    .opacity(matchDisabled ? 0.5 : 1.0)
                    .scaleEffect(isMatchHovered && !matchDisabled ? 1.02 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isMatchHovered)
                    .onHover { isMatchHovered = $0 }
                    .help("Return")

                    KeyCapView(key: "Return")
                        .font(.system(size: 9))
                        .padding(.top, Spacing.xxs)
                        .opacity(0.8)
                }
                .reportTutorialFrame("inspectorMatchButton", to: appState)

                // No Match button
                VStack(spacing: 0) {
                    Button {
                        appState.setReviewDecision(.rejected, for: result.id)
                        appState.advanceToNextPending()
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: "xmark.circle")
                                .font(.subheadline.weight(.semibold))
                            Text("No Match")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .liquidGlassButtonStyle(
                            color: Color.secondary,
                            cornerRadius: 8,
                            isActive: isNoMatchHovered && !noMatchDisabled
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(noMatchDisabled)
                    .opacity(noMatchDisabled ? 0.5 : 1.0)
                    .scaleEffect(isNoMatchHovered && !noMatchDisabled ? 1.02 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isNoMatchHovered)
                    .onHover { isNoMatchHovered = $0 }
                    .help("Delete")

                    KeyCapView(key: "Delete")
                        .font(.system(size: 9))
                        .padding(.top, Spacing.xxs)
                        .opacity(0.8)
                }
                .reportTutorialFrame("inspectorNoMatchButton", to: appState)
            }
        }
        .actionButtonsCard(colorScheme: colorScheme)
        .id(colorScheme)
    }

    // MARK: - Override Search

    @ViewBuilder
    private func overrideSearchSection(for result: MatchResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    overrideExpanded.toggle()
                }
            }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    Text("MANUAL OVERRIDE")
                        .technicalLabel()
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(overrideExpanded ? 90 : 0))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if overrideExpanded {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    TextField("Search database entries...", text: $overrideSearchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .focused($isOverrideFieldFocused)
                        .padding(Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.black.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
                        )

                    if !overrideSearchResults.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(overrideSearchResults) { candidate in
                                Button {
                                    appState.setReviewDecision(
                                        .overridden, for: result.id,
                                        overrideText: candidate.matchText,
                                        overrideID: candidate.matchID,
                                        overrideScore: candidate.score
                                    )
                                    overrideSearchText = ""
                                    debouncedOverrideSearchText = ""
                                    overrideExpanded = false
                                    appState.advanceToNextPending()
                                } label: {
                                    HStack(spacing: Spacing.xs) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(candidate.matchText)
                                                .font(.caption)
                                                .lineLimit(2)
                                                .foregroundStyle(.primary)
                                        }
                                        Spacer()
                                        HStack(spacing: Spacing.xxs) {
                                            Circle()
                                                .fill(Color.scoreColor(candidate.score))
                                                .frame(width: 6, height: 6)
                                            Text("\(Int(candidate.score * 100))%")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Color.scoreColor(candidate.score))
                                        }
                                    }
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.vertical, Spacing.xs)
                                    .background {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(hoveredOverrideId == candidate.id ? Color.accentColor.opacity(0.10) : Color.clear)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { isHovering in
                                    hoveredOverrideId = isHovering ? candidate.id : nil
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))
                        .padding(.top, 4)
                    } else if debouncedOverrideSearchText.count >= 2 {
                        Text("No matches found in database")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .padding(.leading, 4)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .clipped()
            }
        }
    }

    // MARK: - Note Field

    @ViewBuilder
    private func noteField(for result: MatchResult, decision: ReviewDecision?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    notesExpanded.toggle()
                }
            }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "note.text")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    
                    Text("RESEARCHER NOTES")
                        .technicalLabel()
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(notesExpanded ? 90 : 0))
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if notesExpanded {
                VStack(spacing: 0) {
                    TextField("Type observation...", text: $localNoteText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .focused($isNoteFieldFocused)
                        .lineLimit(3...8)
                        .padding(Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.black.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75)
                        )
                        .task(id: localNoteText) {
                            do {
                                try await Task.sleep(for: .milliseconds(400))
                            } catch { return }
                            guard let resultId = selectedResult?.id else { return }
                            var updated = appState.reviewDecisions[resultId] ?? ReviewDecision(status: .pending)
                            updated.note = localNoteText.isEmpty ? nil : localNoteText
                            appState.reviewDecisions[resultId] = updated
                        }
                        .onAppear {
                            localNoteText = decision?.note ?? ""
                        }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .clipped()
            }
        }
    }

    // MARK: - Progress Section

    private var progressSection: some View {
        VStack(spacing: Spacing.sm) {
            HStack {
                Text("PROGRESS")
                    .technicalLabel()
                Spacer()
                Text("\(appState.reviewCompletedCount) of \(appState.results.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            // Segmented progress bar (3 segments)
            GeometryReader { geo in
                let total = max(appState.results.count, 1)
                let matchedWidth = geo.size.width * CGFloat(matchedCount) / CGFloat(total)
                let reviewWidth = geo.size.width * CGFloat(needsReviewCount) / CGFloat(total)

                HStack(spacing: 0) {
                    if matchedCount > 0 {
                        Rectangle().fill(Color.green)
                            .frame(width: matchedWidth)
                    }
                    if needsReviewCount > 0 {
                        Rectangle().fill(MatchCategory.needsReview.color)
                            .frame(width: reviewWidth)
                    }
                    if noMatchZoneCount > 0 {
                        Rectangle().fill(Color(nsColor: .secondaryLabelColor))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                )
            }
            .frame(height: Size.progressBarHeight)
            .animation(Animate.quick, value: appState.reviewCompletedCount)

            // Zone breakdown (3 zones)
            HStack(spacing: Spacing.md) {
                zoneStat(label: "Matched", count: matchedCount, color: MatchCategory.match.color)
                zoneStat(label: "Needs Review", count: needsReviewCount, color: MatchCategory.needsReview.color)
                zoneStat(label: "No Match", count: noMatchZoneCount, color: Color(nsColor: .secondaryLabelColor))
            }
            .font(.caption2)

            // Completion feedback
            if !appState.results.contains(where: { appState.cachedCategories[$0.id] == .needsReview })
                && !appState.reviewDecisions.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: Size.iconLarge))
                        .foregroundStyle(.green)
                    Text("All items reviewed")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("\(appState.reviewCompletedCount) decisions made")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: cardBorderWidth)
        )
        .overlay {
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.66)
            }
        }
        .shadow(
            color: cardShadowPrimary.color,
            radius: cardShadowPrimary.radius,
            y: cardShadowPrimary.y
        )
        .shadow(
            color: cardShadowSecondary.color,
            radius: cardShadowSecondary.radius,
            y: 1
        )
    }

    // MARK: - Helpers

    private var matchedCount: Int {
        let cats = appState.cachedCategories
        return appState.results.filter {
            let c = cats[$0.id] ?? .noMatch
            return c == .match || c == .confirmedMatch
        }.count
    }

    private var needsReviewCount: Int {
        appState.cachedCategories.values.filter { $0 == .needsReview }.count
    }

    private var noMatchZoneCount: Int {
        let cats = appState.cachedCategories
        return appState.results.filter {
            let c = cats[$0.id] ?? .noMatch
            return c == .noMatch || c == .confirmedNoMatch
        }.count
    }

    private func zoneStat(label: String, count: Int, color: Color) -> some View {
        HStack(spacing: Spacing.xxxs) {
            Circle()
                .fill(color)
                .frame(width: Size.statusDot, height: Size.statusDot)
            Text("\(count) \(label)")
                .foregroundStyle(.secondary)
        }
    }

}

#Preview("Review Inspector - Populated - Light") {
    ReviewInspectorPanel()
        .environmentObject(PreviewHelpers.reviewModeState())
        .frame(width: 320, height: 700)
        .preferredColorScheme(.light)
}

#Preview("Review Inspector - Populated - Dark") {
    ReviewInspectorPanel()
        .environmentObject(PreviewHelpers.reviewModeState())
        .frame(width: 320, height: 700)
        .preferredColorScheme(.dark)
}

#Preview("Review Inspector - Empty Selection") {
    let state = PreviewHelpers.reviewModeState()
    state.selection = []
    return ReviewInspectorPanel()
        .environmentObject(state)
        .frame(width: 320, height: 600)
        .preferredColorScheme(.dark)
}
