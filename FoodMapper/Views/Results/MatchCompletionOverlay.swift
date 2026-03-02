import SwiftUI

/// Modal overlay shown after a match job completes.
/// Pipeline-aware: shows different content for embedding-only vs hybrid pipelines.
struct MatchCompletionOverlay: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    /// Dismiss the overlay without entering review mode.
    private func dismiss() {
        withAnimation(Animate.standard) {
            appState.showCompletionOverlay = false
        }
    }

    // MARK: - Pipeline Detection

    /// Whether this run includes hybrid (LLM) results
    private var isHybridPipeline: Bool {
        appState.results.contains { $0.scoreType == .llmSelected || $0.scoreType == .llmRejected }
    }

    // MARK: - Counts

    private var counts: [MatchCategory: Int] {
        appState.categoryCounts()
    }

    private var matchCount: Int { counts[.match, default: 0] }
    private var needsReviewCount: Int { counts[.needsReview, default: 0] }
    private var noMatchCount: Int { counts[.noMatch, default: 0] }
    private var matchedWithCandidates: Int {
        appState.results.filter { $0.matchText != nil }.count
    }
    private var noCandidates: Int {
        appState.results.filter { $0.matchText == nil && $0.status != .error }.count
    }

    private var isReady: Bool { appState.resultsReady }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Backdrop scrim
            Color.black.opacity(colorScheme == .dark ? 0.35 : 0.20)
                .ignoresSafeArea()
                .onTapGesture {
                    if isReady { dismiss() }
                }

            // Card
            VStack(spacing: 0) {
                headerSection
                Divider().opacity(0.5)
                if isHybridPipeline {
                    hybridStatsSection
                } else {
                    embeddingStatsSection
                }
                if !isReady {
                    preparingSection
                }
                Divider().opacity(0.5)
                actionsSection
            }
            .frame(width: 520)
            .premiumMaterialStyle(cornerRadius: 12)
            .shadow(
                color: Color.cardShadow(for: colorScheme),
                radius: colorScheme == .dark ? 24 : 12,
                y: colorScheme == .dark ? 8 : 4
            )
            .animation(Animate.standard, value: isReady)
        }
        // During exit animation, showCompletionOverlay is already false but SwiftUI
        // keeps rendering the view for the transition. Without this, the scrim's
        // onTapGesture intercepts all clicks on the results table underneath until a
        // scroll forces a layout pass. Disabling hit-testing immediately when the flag
        // flips lets the table receive clicks while the overlay fades out.
        .allowsHitTesting(appState.showCompletionOverlay)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.green)

            Text("Matching Complete")
                .font(.title3.weight(.semibold))

            Spacer()

            Text("\(appState.results.count) items")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Hybrid Stats (3 columns)

    private var hybridStatsSection: some View {
        HStack(spacing: 0) {
            statColumn(
                count: matchCount,
                label: "Matched",
                color: MatchCategory.match.color
            )

            verticalDivider

            statColumn(
                count: needsReviewCount,
                label: "Needs Review",
                color: MatchCategory.needsReview.color
            )

            verticalDivider

            statColumn(
                count: noMatchCount,
                label: "No Match",
                color: MatchCategory.noMatch.color
            )
        }
        .padding(.vertical, Spacing.xl)
    }

    // MARK: - Embedding Stats (summary text)

    private var embeddingStatsSection: some View {
        VStack(spacing: Spacing.sm) {
            Text("\(matchedWithCandidates) items matched with candidates.")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("All items, including high-confidence matches, should be verified before using results in your research.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.lg)

            if noCandidates > 0 {
                Text("\(noCandidates) items had no close candidates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    private func statColumn(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: Spacing.xs) {
            Text("\(count)")
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.cardBorder(for: colorScheme))
            .frame(width: 1, height: 40)
    }

    // MARK: - Preparing Indicator

    private var preparingSection: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Preparing results\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .transition(.opacity)
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "tablecells")
                Text("View Results")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!isReady)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }
}

// MARK: - Previews

#Preview("Completion Overlay - Dark") {
    ZStack {
        Color(nsColor: .textBackgroundColor)
            .ignoresSafeArea()
        Text("Results table content behind the overlay")
            .foregroundStyle(.secondary)

        MatchCompletionOverlay()
            .environmentObject(PreviewHelpers.completionOverlayState())
    }
    .frame(width: 900, height: 600)
    .preferredColorScheme(.dark)
}

#Preview("Completion Overlay - Light") {
    ZStack {
        Color(nsColor: .textBackgroundColor)
            .ignoresSafeArea()
        Text("Results table content behind the overlay")
            .foregroundStyle(.secondary)

        MatchCompletionOverlay()
            .environmentObject(PreviewHelpers.completionOverlayState())
    }
    .frame(width: 900, height: 600)
    .preferredColorScheme(.light)
}

#Preview("Completion Overlay - Preparing - Dark") {
    let state = PreviewHelpers.completionOverlayState()
    let _ = (state.resultsReady = false)
    ZStack {
        Color(nsColor: .textBackgroundColor)
            .ignoresSafeArea()
        Text("Results table content behind the overlay")
            .foregroundStyle(.secondary)

        MatchCompletionOverlay()
            .environmentObject(state)
    }
    .frame(width: 900, height: 600)
    .preferredColorScheme(.dark)
}
