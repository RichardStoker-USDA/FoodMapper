import SwiftUI

/// Unified home screen shown when Home sidebar is selected.
/// Three action cards: New Match, Custom Database, Behind the Research.
struct WelcomeLandingView: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredCard: String?
    @State private var hoveredSession: MatchingSession.ID?
    @State private var showResearchGlow = true

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Hero section: fills remaining space above history
                heroSection
                    .frame(maxWidth: .infinity)
                    .frame(height: geo.size.height - historyHeight(for: geo.size.height))

                Divider()

                // History section: pinned to bottom with fixed height
                historySection
                    .frame(maxWidth: .infinity)
                    .frame(height: historyHeight(for: geo.size.height))
            }
        }
    }

    /// Compute history section height: compact empty state, or ~33% of window for sessions
    private func historyHeight(for totalHeight: CGFloat) -> CGFloat {
        if appState.sessions.isEmpty {
            return 120
        }
        // 33% of available height, clamped to a reasonable range
        return min(max(totalHeight * 0.32, 160), 255)
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            // App title and description
            VStack(spacing: Spacing.md) {
                Text("FoodMapper")
                    .font(.system(size: 32, weight: .semibold))

                Text("Match food descriptions to standardized databases using semantic similarity.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            // Action cards
            HStack(spacing: Spacing.lg) {
                ActionCard(
                    icon: "link.badge.plus",
                    title: "New Match",
                    subtitle: "Start matching food descriptions",
                    isHovered: hoveredCard == "new"
                ) {
                    guard !appState.showTutorial || appState.tutorialState.currentStep == 2 else { return }
                    appState.startNewMatch()
                }
                .onHover { hoveredCard = $0 ? "new" : nil }
                .disabled(appState.showTutorial && appState.tutorialState.currentStep > 2)
                .tutorialAnchor("welcomeNewMatchCard")

                ActionCard(
                    icon: "externaldrive.badge.plus",
                    title: "Custom Database",
                    subtitle: "Add your own database",
                    isHovered: hoveredCard == "custom"
                ) {
                    guard !appState.showTutorial else { return }
                    appState.sidebarSelection = .databases
                }
                .onHover { hoveredCard = $0 ? "custom" : nil }
                .disabled(appState.showTutorial && appState.tutorialState.currentStep > 1)

                ActionCard(
                    icon: "doc.text.magnifyingglass",
                    title: "Behind the Research",
                    subtitle: "Explore the methods",
                    isHovered: hoveredCard == "research"
                ) {
                    guard !appState.showTutorial else { return }
                    appState.startResearchShowcase()
                    appState.selectedPipelineMode = .researchValidation
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.5),
                                    Color.purple.opacity(0.3),
                                    Color.accentColor.opacity(0.4)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: Color.accentColor.opacity(0.12), radius: 8, x: 0, y: 0)
                .shadow(color: Color.purple.opacity(0.08), radius: 12, x: 0, y: 0)
                .onHover { hoveredCard = $0 ? "research" : nil }
                .disabled(appState.showTutorial && appState.tutorialState.currentStep > 1)
            }
            .tutorialAnchor("welcomeActionCards")

            // Hint text
            Text("Start a new match, import your own database, or explore the paper's methods.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Spacer()
        }
        .padding(Spacing.xxl)
    }

    // MARK: - History Section

    private var historySection: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("Recent Sessions")
                    .font(.headline)

                Spacer()

                if !appState.sessions.isEmpty {
                    Button {
                        appState.sidebarSelection = .history
                    } label: {
                        HStack(spacing: Spacing.xxs) {
                            Text("View All")
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.callout.weight(.semibold))
                    .disabled(appState.showTutorial)
                    .tutorialAnchor("viewAllSessions")
                }
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.md)

            Divider()
                .padding(.leading, Spacing.xxl)

            // Session list or empty state
            Group {
                if appState.sessions.isEmpty {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)

                        Text("No recent sessions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(appState.sessions.prefix(5)) { session in
                                CompactSessionRow(
                                    session: session,
                                    isHovered: hoveredSession == session.id
                                ) {
                                    appState.loadSession(session)
                                }
                                .onHover { hoveredSession = $0 ? session.id : nil }
                                .disabled(appState.showTutorial)

                                if session.id != appState.sessions.prefix(5).last?.id {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                }
            }
            .tutorialAnchor("recentSessionsArea")
            // Disable history interaction during tutorial step 17 (Session History) - force Next only
            .allowsHitTesting(!(appState.showTutorial && appState.tutorialState.currentStep == 17))
        }
    }
}

// MARK: - Action Card

struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isHovered: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    // Shadow depth scales with hover state for the "lift" effect
    private var shadowRadius: CGFloat {
        if isHovered {
            return colorScheme == .dark ? 16 : 10
        }
        return colorScheme == .dark ? 6 : 5
    }

    private var shadowY: CGFloat {
        if isHovered {
            return colorScheme == .dark ? 8 : 5
        }
        return colorScheme == .dark ? 3 : 2
    }

    private var shadowOpacity: Double {
        if isHovered {
            return colorScheme == .dark ? 0.5 : 0.14
        }
        return colorScheme == .dark ? 0.35 : 0.12
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)

                VStack(spacing: Spacing.xxs) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 175, height: 140)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark
                        ? Color(nsColor: .controlBackgroundColor)
                        : Color.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isHovered
                            ? Color.accentColor.opacity(colorScheme == .dark ? 0.3 : 0.2)
                            : Color.cardBorder(for: colorScheme),
                        lineWidth: isHovered ? 1.0 : (colorScheme == .dark ? 0.66 : 1.0)
                    )
            }
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: shadowRadius,
                y: shadowY
            )
            // Accent glow when hovered -- subtle colored halo
            .shadow(
                color: isHovered ? Color.accentColor.opacity(0.15) : Color.clear,
                radius: isHovered ? 12 : 0,
                y: 0
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Session Row

struct CompactSessionRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let session: MatchingSession
    let isHovered: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.md) {
                // Icon
                Image(systemName: "doc.text")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isHovered ? Color.accentColor : Color.accentColor.opacity(0.7))
                    .frame(width: 28)

                // File name
                Text(session.inputFileName)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Database badge
                Text(session.databaseName)
                    .font(.caption)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, 2)
                    .lineLimit(1)
                    .polishedBadge(tone: .accentStrong, cornerRadius: 4)

                // Threshold
                Text("@ \(session.threshold, format: .percent.precision(.fractionLength(0)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Relative time
                Text(session.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Match rate
                Text(session.matchRate, format: .percent.precision(.fractionLength(0)))
                    .font(.body)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(Color.scoreColor(session.matchRate))

                // Chevron hint on hover
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered
                    ? (colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.04))
                    : Color.clear)
                .padding(.horizontal, Spacing.sm)
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

#Preview("Welcome - Light") {
    WelcomeLandingView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 900, height: 650)
}

#Preview("Welcome - Dark") {
    WelcomeLandingView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 900, height: 650)
        .preferredColorScheme(.dark)
}
