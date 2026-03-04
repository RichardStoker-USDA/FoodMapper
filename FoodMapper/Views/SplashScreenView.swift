import SwiftUI

/// First-launch splash screen following the Xcode Welcome Window pattern.
/// Shown once and version-aware for future "What's New" reuse.
/// Design quality matches the Behind the Research showcase.
struct SplashScreenView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool

    @State private var dontShowAgain = false
    @State private var iconScale: CGFloat = 0.7
    @State private var iconOffset: CGFloat = -10
    @State private var titleVisible = false
    @State private var featureRowsVisible = false
    @State private var ctaVisible = false
    @State private var footerVisible = false
    @State private var isResearchHovered = false
    @State private var isMatchingHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: Spacing.xxxl)

            // App icon with spring entrance and mode-aware glow
            iconSection

            Spacer()
                .frame(height: Spacing.lg)

            // Title
            Text("Welcome to FoodMapper")
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: true, vertical: true)
                .opacity(titleVisible ? 1 : 0)

            Spacer()
                .frame(height: Spacing.xxl)

            // Feature cards
            VStack(alignment: .leading, spacing: Spacing.md) {
                featureCard(
                    icon: "link",
                    title: "On-Device AI Matching",
                    description: "Match food descriptions to databases using models that run entirely on your Mac's M-Series GPU.",
                    index: 0
                )

                featureCard(
                    icon: "doc.text.magnifyingglass",
                    title: "Behind the Research",
                    description: "Explore the methods from the original research paper and try the matching pipelines yourself.",
                    index: 1
                )

                featureCard(
                    icon: "externaldrive.badge.plus",
                    title: "Custom Databases",
                    description: "Import your own CSV or TSV databases or use the built-in FooDB and DFG2 references.",
                    index: 2
                )

                featureCard(
                    icon: "checkmark.shield",
                    title: "Review & Validate",
                    description: "Confirm, reject, or override matches with guided review before exporting.",
                    index: 3
                )
            }
            .frame(maxWidth: 430, alignment: .leading)

            Spacer()
                .frame(height: Spacing.xl)

            // CTA buttons with hover effects
            ctaSection

            Spacer()
                .frame(height: Spacing.lg)

            // Footer with visual separation
            footerSection

            Spacer()
                .frame(height: Spacing.md)
        }
        .padding(.horizontal, Spacing.xxxl)
        .frame(width: 560, height: 690)
        .background { splashBackground }
        .onAppear {
            if reduceMotion {
                iconScale = 1.0
                iconOffset = 0
                titleVisible = true
                featureRowsVisible = true
                ctaVisible = true
                footerVisible = true
            } else {
                withAnimation(Animate.bouncy) {
                    iconScale = 1.0
                    iconOffset = 0
                }
                withAnimation(Animate.smooth.delay(0.2)) {
                    titleVisible = true
                }
                withAnimation(Animate.standard.delay(0.3)) {
                    featureRowsVisible = true
                }
                withAnimation(Animate.standard.delay(0.55)) {
                    ctaVisible = true
                }
                withAnimation(Animate.smooth.delay(0.7)) {
                    footerVisible = true
                }
            }
        }
    }

    // MARK: - Icon Section

    private var iconSection: some View {
        Group {
            if let appIcon = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .scaleEffect(iconScale)
                    .offset(y: iconOffset)
                    .shadow(
                        color: iconScale > 0.9
                            ? (colorScheme == .dark
                                ? Color.accentColor.opacity(0.25)
                                : Color.black.opacity(0.18))
                            : Color.clear,
                        radius: colorScheme == .dark ? 16 : 10,
                        y: colorScheme == .dark ? 4 : 5
                    )
            }
        }
    }

    // MARK: - Feature Cards

    private func featureCard(icon: String, title: String, description: String, index: Int) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: Size.iconLarge))
                .foregroundStyle(Color.accentColor)
                .frame(width: Size.iconLarge + Spacing.md, alignment: .center)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark
                    ? Color.cardBackground(for: colorScheme).opacity(0.75)
                    : Color.white)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: colorScheme == .dark ? 0.9 : 1.0)
        }
        // Primary lift shadow
        .shadow(
            color: colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.16),
            radius: colorScheme == .dark ? 10 : 7,
            y: colorScheme == .dark ? 5 : 3
        )
        // Contact shadow for grounding
        .shadow(
            color: colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.05),
            radius: 2,
            y: 1
        )
        .opacity(featureRowsVisible ? 1 : 0)
        .offset(y: featureRowsVisible ? 0 : 12)
        .animation(
            Animate.standard.delay(Double(index) * 0.12),
            value: featureRowsVisible
        )
    }

    // MARK: - CTA Buttons

    private var ctaSection: some View {
        VStack(spacing: Spacing.md) {
            // Primary: Behind the Research
            Button {
                dismiss()
                appState.selectPipelineMode(.researchValidation)
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Behind the Research")
                }
                .frame(maxWidth: 280)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .scaleEffect(isResearchHovered ? 1.03 : 1.0)
            .shadow(
                color: isResearchHovered ? Color.accentColor.opacity(0.25) : Color.clear,
                radius: isResearchHovered ? 8 : 0, y: 0
            )
            .animation(Animate.quick, value: isResearchHovered)
            .onHover { hovering in isResearchHovered = hovering }

            // Secondary: Start Matching
            Button {
                dismiss()
                appState.selectPipelineMode(.standard)
            } label: {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "sparkle.magnifyingglass")
                    Text("Start Matching")
                }
                .frame(maxWidth: 280)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .scaleEffect(isMatchingHovered ? 1.03 : 1.0)
            .animation(Animate.quick, value: isMatchingHovered)
            .onHover { hovering in isMatchingHovered = hovering }
        }
        .opacity(ctaVisible ? 1 : 0)
        .scaleEffect(ctaVisible ? 1 : 0.95)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: Spacing.sm) {
            // Visual separator
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, Spacing.xxl)

            VStack(spacing: Spacing.xxs) {
                Text("Evaluation of Large Language Models for Mapping Dietary Data to Food Databases")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.80))
                    .multilineTextAlignment(.center)

                Text("Lemay, Strohmeier, Stoker, Larke, Wilson")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("USDA Agricultural Research Service")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Spacing.xs)

            // Subtle text link instead of checkbox
            Button {
                dontShowAgain.toggle()
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: dontShowAgain ? "checkmark.circle" : "circle")
                        .font(.caption)
                        .foregroundStyle(dontShowAgain ? Color.accentColor : .secondary)
                    Text(dontShowAgain ? "Won't show on next launch" : "Show on next launch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .animation(Animate.quick, value: dontShowAgain)
        }
        .opacity(footerVisible ? 1 : 0)
    }

    // MARK: - Background

    @ViewBuilder
    private var splashBackground: some View {
        if #available(macOS 15, *) {
            splashMeshBackground
        } else {
            // Sonoma fallback: subtle radial gradient
            if colorScheme == .dark {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    RadialGradient(
                        colors: [Color.accentColor.opacity(0.04), Color.clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: 400
                    )
                }
            }
        }
    }

    @available(macOS 15, *)
    @ViewBuilder
    private var splashMeshBackground: some View {
        if reduceMotion {
            // Static gradient when reduce motion is on
            if colorScheme == .dark {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    RadialGradient(
                        colors: [Color.accentColor.opacity(0.04), Color.clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: 400
                    )
                }
            }
        } else {
            // Living mesh gradient, very subtle -- lighter than the showcase hero
            let baseOpacity = colorScheme == .dark ? 0.012 : 0.03
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                TimelineView(.animation(minimumInterval: 1.0 / 10)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let dx = Float(sin(t * 0.15)) * 0.025
                    let dy = Float(cos(t * 0.2)) * 0.025

                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: [
                            [0, 0], [0.5, 0], [1, 0],
                            [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
                            [0, 1], [0.5, 1], [1, 1]
                        ],
                        colors: [
                            Color.accentColor.opacity(baseOpacity * 0.4),
                            Color.purple.opacity(baseOpacity * 0.25),
                            Color.accentColor.opacity(baseOpacity * 0.3),
                            Color.blue.opacity(baseOpacity * 0.2),
                            Color.accentColor.opacity(baseOpacity * 0.5),
                            Color.purple.opacity(baseOpacity * 0.3),
                            Color.accentColor.opacity(baseOpacity * 0.3),
                            Color.blue.opacity(baseOpacity * 0.2),
                            Color.accentColor.opacity(baseOpacity * 0.25)
                        ],
                        smoothsColors: true
                    )
                }
                .drawingGroup()
            }
        }
    }

    // MARK: - Actions

    private func dismiss() {
        if dontShowAgain {
            SplashConfig.markSeen()
        }
        isPresented = false
    }
}

// MARK: - Previews

#Preview("Splash Screen - Light") {
    SplashScreenView(isPresented: .constant(true))
        .environmentObject(PreviewHelpers.emptyState())
        .preferredColorScheme(.light)
}

#Preview("Splash Screen - Dark") {
    SplashScreenView(isPresented: .constant(true))
        .environmentObject(PreviewHelpers.emptyState())
        .preferredColorScheme(.dark)
}
