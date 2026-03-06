import SwiftUI

/// Scrolling showcase for the "Behind the Research" experience.
/// Replaces the paginated 8-stop tour with a single continuous ScrollView
/// containing 6 visually distinct sections. Each section fades in on scroll.
struct ResearchShowcaseView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var showExitConfirmation = false
    @State private var currentSectionIndex: Int = 0
    /// Height of the ScrollView viewport. Used as minimum height for middle sections
    /// so short sections never let the next section bleed into view.
    @State private var sectionMinHeight: CGFloat = 700

    private let sectionNames = [
        "Overview", "The Challenge", "Methods",
        "How It Works", "LLM Selection", "Try It", "Continue"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Compact exit bar with section dots
            showcaseTopBar

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("showcaseTop")

                        // Section 1: Hero (full viewport height)
                        ShowcaseSection(heroMode: true) {
                            HeroSection(scrollProxy: proxy)
                        }
                        .containerRelativeFrame(.vertical)
                        .id("hero")
                        .modifier(SectionTracker(index: 0, currentIndex: $currentSectionIndex))

                        // Section 2: The Challenge
                        ShowcaseSection(alternate: true, minHeight: sectionMinHeight) {
                            ChallengeSection(onScrollToNext: {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    proxy.scrollTo("methods", anchor: .top)
                                }
                            })
                        }
                        .id("challenge")
                        .scrollReveal()
                        .modifier(SectionTracker(index: 1, currentIndex: $currentSectionIndex))

                        // Section 3: Methods Compared
                        ShowcaseSection(minHeight: sectionMinHeight) {
                            MethodsComparedSection(onScrollToNext: {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    proxy.scrollTo("pipeline", anchor: .top)
                                }
                            })
                        }
                        .id("methods")
                        .scrollReveal()
                        .modifier(SectionTracker(index: 2, currentIndex: $currentSectionIndex))

                        // Section 4: How It Works (Stage 1: Embedding)
                        ShowcaseSection(alternate: true, minHeight: sectionMinHeight) {
                            PipelineSection(onScrollToNext: {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    proxy.scrollTo("llm", anchor: .top)
                                }
                            })
                        }
                        .id("pipeline")
                        .scrollReveal()
                        .modifier(SectionTracker(index: 3, threshold: 0.22, currentIndex: $currentSectionIndex))

                        // Section 5: LLM Match Selection (Stage 2)
                        ShowcaseSection(minHeight: sectionMinHeight) {
                            LLMStageSection(onScrollToNext: {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    proxy.scrollTo("tryit", anchor: .top)
                                }
                            })
                        }
                        .id("llm")
                        .scrollReveal()
                        .modifier(SectionTracker(index: 4, threshold: 0.3, currentIndex: $currentSectionIndex))

                        // Section 6: Try It Yourself
                        ShowcaseSection(alternate: true, minHeight: sectionMinHeight) {
                            TryItSection(onScrollToNext: {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    proxy.scrollTo("continue", anchor: .top)
                                }
                            })
                        }
                        .id("tryit")
                        .scrollReveal()
                        .modifier(SectionTracker(index: 5, currentIndex: $currentSectionIndex))

                        // Section 7: Continue Exploring (full viewport height)
                        ShowcaseSection {
                            ContinueSection(scrollToTop: {
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                    proxy.scrollTo("showcaseTop", anchor: .top)
                                }
                            })
                        }
                        .containerRelativeFrame(.vertical)
                        .id("continue")
                        .scrollReveal()
                        .modifier(SectionTracker(index: 6, currentIndex: $currentSectionIndex))
                    }
                }
                .coordinateSpace(name: "showcaseScroll")
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { sectionMinHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in sectionMinHeight = h }
                    }
                )
            }
        }
        .background {
            if colorScheme == .dark {
                Color(nsColor: .textBackgroundColor)
            } else {
                LinearGradient(
                    colors: [
                        Color.white,
                        Color.white,
                        Color.accentColor.opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(minWidth: 1357, minHeight: 812)
        .alert("Exit Behind the Research?", isPresented: $showExitConfirmation) {
            Button("Keep Reading", role: .cancel) {}
            Button("Exit") { appState.exitResearchShowcase() }
        } message: {
            Text("You can return anytime from the home screen.")
        }
        .onKeyPress(.escape) {
            showExitConfirmation = true
            return .handled
        }
    }

    // MARK: - Top Bar

    private var showcaseTopBar: some View {
        HStack {
            Button {
                showExitConfirmation = true
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "chevron.left")
                        .imageScale(.small)
                    Text("Home")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Return to mode selection (Esc)")

            Spacer()

            // Section progress dots
            HStack(spacing: Spacing.xs) {
                ForEach(0..<7, id: \.self) { index in
                    Circle()
                        .fill(index == currentSectionIndex ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: 5, height: 5)
                        .animation(Animate.quick, value: currentSectionIndex)
                        .help(sectionNames[index])
                }
            }

            Spacer()

            Text("Behind the Research")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background {
            Group {
                if #available(macOS 26, *) {
                    Color.clear.glassEffect(.regular.interactive())
                } else {
                    Color(nsColor: .windowBackgroundColor)
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                }
            }
        }
    }
}

// MARK: - Section Tracker

/// Tracks which section is currently visible for the progress dots.
/// Uses onScrollVisibilityChange on macOS 15+, falls back to onAppear on macOS 14.
private struct SectionTracker: ViewModifier {
    let index: Int
    let threshold: Double
    @Binding var currentIndex: Int

    init(index: Int, threshold: Double = 0.5, currentIndex: Binding<Int>) {
        self.index = index
        self.threshold = threshold
        self._currentIndex = currentIndex
    }

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollVisibilityChange(threshold: threshold) { visible in
                    if visible {
                        currentIndex = index
                    }
                }
        } else {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.frame(in: .named("showcaseScroll")).midY) { _, midY in
                                let viewportH = NSApp.mainWindow?.contentView?.bounds.height ?? 800
                                if midY > 0 && midY < viewportH {
                                    currentIndex = index
                                }
                            }
                    }
                )
        }
    }
}

// MARK: - Section Wrapper

/// Full-width section container with soft alternating background.
/// Uses MeshGradient on macOS 15+ for a liquid feel, with gradient-masked
/// tinting as fallback on Sonoma.
private struct ShowcaseSection<Content: View>: View {
    let alternate: Bool
    let heroMode: Bool
    /// Minimum height for this section. When > 0, the section background fills
    /// at least this height, preventing the next section from bleeding into view
    /// for sections shorter than the viewport.
    let minHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        alternate: Bool = false,
        heroMode: Bool = false,
        minHeight: CGFloat = 0,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.alternate = alternate
        self.heroMode = heroMode
        self.minHeight = minHeight
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: 760)
            .padding(.horizontal, Spacing.xxxl)
            .padding(.vertical, Spacing.xxxl)
            .frame(maxWidth: .infinity, minHeight: minHeight > 0 ? minHeight : nil)
            .background {
                if heroMode {
                    heroBackground
                } else if alternate {
                    alternateBackground
                } else if colorScheme == .light {
                    // Subtle warmth for non-alternate sections in light mode
                    RadialGradient(
                        colors: [Color.accentColor.opacity(0.05), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 500
                    )
                }
            }
    }

    @ViewBuilder
    private var heroBackground: some View {
        if #available(macOS 15, *), !reduceMotion {
            let baseOpacity = colorScheme == .dark ? 0.015 : 0.038
            TimelineView(.animation(minimumInterval: 1.0 / 12)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let dx = Float(sin(t * 0.2)) * 0.03
                let dy = Float(cos(t * 0.25)) * 0.03

                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        [0, 0], [0.5, 0], [1, 0],
                        [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
                        [0, 1], [0.5, 1], [1, 1]
                    ],
                    colors: [
                        Color.accentColor.opacity(baseOpacity * 0.5),
                        Color.purple.opacity(baseOpacity * 0.3),
                        Color.accentColor.opacity(baseOpacity * 0.4),
                        Color.blue.opacity(baseOpacity * 0.3),
                        Color.accentColor.opacity(baseOpacity * 0.6),
                        Color.purple.opacity(baseOpacity * 0.4),
                        Color.accentColor.opacity(baseOpacity * 0.4),
                        Color.blue.opacity(baseOpacity * 0.3),
                        Color.accentColor.opacity(baseOpacity * 0.3)
                    ],
                    smoothsColors: true
                )
            }
            .drawingGroup()
        } else {
            RadialGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.015 : 0.02), Color.clear],
                center: .center,
                startRadius: 0,
                endRadius: 500
            )
        }
    }

    @ViewBuilder
    private var alternateBackground: some View {
        if #available(macOS 15, *) {
            meshGradientBackground
                .mask {
                    gradientMask
                }
        } else {
            Color.primary
                .opacity(colorScheme == .dark ? 0.03 : 0.032)
                .mask {
                    gradientMask
                }
        }
    }

    @available(macOS 15, *)
    private var meshGradientBackground: some View {
        let baseOpacity = colorScheme == .dark ? 0.03 : 0.042
        return TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let dx = Float(sin(t * 0.3)) * 0.04
            let dy = Float(cos(t * 0.4)) * 0.04

            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ],
                colors: [
                    Color.accentColor.opacity(baseOpacity),
                    Color.purple.opacity(baseOpacity * 0.6),
                    Color.accentColor.opacity(baseOpacity * 0.8),
                    Color.blue.opacity(baseOpacity * 0.5),
                    Color.accentColor.opacity(baseOpacity),
                    Color.purple.opacity(baseOpacity * 0.7),
                    Color.accentColor.opacity(baseOpacity * 0.8),
                    Color.blue.opacity(baseOpacity * 0.6),
                    Color.accentColor.opacity(baseOpacity * 0.5)
                ],
                smoothsColors: true
            )
        }
        .drawingGroup()
    }

    private var gradientMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.05),
                .init(color: .white, location: 0.95),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Previews

#Preview("Showcase - Light") {
    ResearchShowcaseView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 1100, height: 750)
        .preferredColorScheme(.light)
}

#Preview("Showcase - Dark") {
    ResearchShowcaseView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 1100, height: 750)
        .preferredColorScheme(.dark)
}
