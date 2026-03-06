import SwiftUI

// MARK: - Text Reveal Renderer (macOS 15+)

/// Reveals text line-by-line with a fade + slide-up animation.
/// Each line appears sequentially as `progress` advances from 0 to 1.
/// Used for the hero title entrance animation.
@available(macOS 15, *)
struct RevealTextRenderer: TextRenderer, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let totalLines = Array(layout).count
        guard totalLines > 0 else { return }

        for (lineIndex, line) in layout.enumerated() {
            // Stagger: each line starts revealing at a different point
            let lineThreshold = Double(lineIndex) * (0.5 / Double(max(totalLines - 1, 1)))
            let lineProgress = max(0, min(1, (progress - lineThreshold) / 0.5))

            // Ease-out curve for smooth deceleration
            let eased = 1.0 - pow(1.0 - lineProgress, 3)

            var lineContext = context
            lineContext.opacity = eased
            lineContext.translateBy(x: 0, y: CGFloat((1.0 - eased) * 25))

            for run in line {
                lineContext.draw(run)
            }
        }
    }
}

// MARK: - Scroll Reveal Modifier

/// Fades, slides up, and scales content as it enters the viewport via scrollTransition.
/// All animations are spring-based and respect accessibilityReduceMotion.
struct ScrollRevealModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .scrollTransition(
                    .animated(.spring(response: 0.45, dampingFraction: 0.8))
                    .threshold(.visible(0.15))
                ) { view, phase in
                    view
                        .opacity(phase.isIdentity ? 1 : 0)
                        .offset(y: phase.isIdentity ? 0 : 30)
                        .scaleEffect(phase.isIdentity ? 1.0 : 0.97)
                }
        }
    }
}

/// Same as ScrollReveal but with increasing visibility thresholds per index
/// so cards in a grid appear one after another as they scroll into view.
struct ScrollRevealStaggeredModifier: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var threshold: Double {
        let thresholds = [0.10, 0.15, 0.20, 0.25]
        return thresholds[min(index, thresholds.count - 1)]
    }

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .scrollTransition(
                    .animated(.spring(response: 0.5, dampingFraction: 0.8))
                    .threshold(.visible(threshold))
                ) { view, phase in
                    view
                        .opacity(phase.isIdentity ? 1 : 0)
                        .offset(y: phase.isIdentity ? 0 : 24)
                        .scaleEffect(phase.isIdentity ? 1.0 : 0.97)
                }
        }
    }
}

extension View {
    /// Fade/slide/scale in as the view scrolls into the viewport.
    func scrollReveal() -> some View {
        modifier(ScrollRevealModifier())
    }

    /// Staggered version: cards at higher indices appear slightly later.
    func scrollRevealStaggered(index: Int) -> some View {
        modifier(ScrollRevealStaggeredModifier(index: index))
    }
}

// MARK: - Showcase Card Modifier

/// Unified card styling for the research showcase. Replaces all inline
/// strokeBorder/fill patterns with consistent light/dark mode treatment.
///
/// - Dark mode: subtle white border (visible, not invisible)
/// - Light mode: softer separator border
/// - Highlighted variant: accent-colored border
/// - Shadow for depth
enum ShowcaseCardTone {
    /// Main research containers. Dark mode uses an elevated dark-gray surface.
    case standard
    /// Intentionally deeper panels for interactive focus areas.
    case deep
}

struct ShowcaseCardModifier: ViewModifier {
    let highlighted: Bool
    let cornerRadius: CGFloat
    let tone: ShowcaseCardTone
    @Environment(\.colorScheme) private var colorScheme

    private var borderColor: Color {
        if highlighted {
            return Color.accentColor.opacity(0.35)
        }
        // Subtle borders for elegance
        switch tone {
        case .standard:
            return colorScheme == .dark
                ? Color.white.opacity(0.12)
                : Color(nsColor: .separatorColor).opacity(0.58)
        case .deep:
            return colorScheme == .dark
                ? Color.white.opacity(0.06) // Very faint in dark mode
                : Color.black.opacity(0.04) // Very subtle in light mode
        }
    }

    private var borderWidth: CGFloat {
        if highlighted {
            return colorScheme == .light ? 1.5 : 1.35
        }
        return colorScheme == .dark ? 0.9 : 1.0
    }

    private var fillColor: Color {
        switch tone {
        case .standard:
            return colorScheme == .dark
                ? Color(nsColor: .controlBackgroundColor).opacity(0.90)
                : Color.white
        case .deep:
            return colorScheme == .dark
                ? Color(white: 0.14).opacity(0.95)
                : Color.white
        }
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
                    .allowsHitTesting(false)
            }
            .overlay {
                if colorScheme == .light {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.66)
                        .allowsHitTesting(false)
                }
            }
            .shadow(
                color: colorScheme == .dark ? Color.black.opacity(0.34) : Color.black.opacity(0.18), // Increased from 0.13
                radius: colorScheme == .dark ? 12 : 9,
                y: colorScheme == .dark ? 6 : 4
            )
            .shadow(
                color: colorScheme == .dark ? Color.black.opacity(0.20) : Color.black.opacity(0.06),
                radius: colorScheme == .dark ? 2 : 2,
                y: 1
            )
    }
}

extension View {
    /// Apply showcase card styling with background, border, and shadow.
    func showcaseCard(
        highlighted: Bool = false,
        cornerRadius: CGFloat = 10,
        tone: ShowcaseCardTone = .standard
    ) -> some View {
        modifier(ShowcaseCardModifier(highlighted: highlighted, cornerRadius: cornerRadius, tone: tone))
    }
}

// MARK: - Showcase Hover Modifier

/// Card lift effect on hover: accent shadow glow, slight scale, and subtle 3D tilt
/// that follows cursor position. Uses onContinuousHover for smooth tracking.
struct ShowcaseHoverModifier: ViewModifier {
    let enableTilt: Bool
    let maxTiltDegrees: Double
    let hoverScale: CGFloat

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .shadow(
                color: isHovered ? Color.accentColor.opacity(0.2) : Color.clear,
                radius: isHovered ? 8 : 0,
                y: 0
            )
            .scaleEffect(isHovered ? hoverScale : 1.0)
            .rotation3DEffect(
                .degrees(enableTilt && isHovered && !reduceMotion ? tiltX : 0),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.8
            )
            .rotation3DEffect(
                .degrees(enableTilt && isHovered && !reduceMotion ? tiltY : 0),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.8
            )
            .animation(Animate.standard, value: isHovered)
            .animation(Animate.quick, value: hoverLocation)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovered = true
                    hoverLocation = location
                case .ended:
                    isHovered = false
                }
            }
    }

    // Max 2.5 degrees tilt based on cursor position relative to card center
    private var tiltX: Double {
        let normalized = (hoverLocation.x / 300.0) * 2 - 1
        let maxTilt = max(maxTiltDegrees, 0)
        return min(max(normalized * maxTilt, -maxTilt), maxTilt)
    }

    private var tiltY: Double {
        let normalized = (hoverLocation.y / 180.0) * 2 - 1
        let maxTilt = max(maxTiltDegrees, 0)
        return min(max(-normalized * maxTilt, -maxTilt), maxTilt)
    }
}

extension View {
    /// Add hover lift effect with accent shadow glow.
    /// Set `tilt` to false for small cards where 3D perspective causes text blur.
    func showcaseHover(
        tilt: Bool = true,
        maxTilt: Double = 2.5,
        scale: CGFloat = 1.015
    ) -> some View {
        modifier(
            ShowcaseHoverModifier(
                enableTilt: tilt,
                maxTiltDegrees: maxTilt,
                hoverScale: scale
            )
        )
    }
}

// MARK: - Animated Counter

/// Animates a number counting from 0 to its target value when triggered.
/// Uses contentTransition(.numericText()) for smooth digit transitions.
struct AnimatedCounter: View {
    let targetValue: String
    let numericValue: Double?
    let label: String

    @State private var displayedValue: Double = 0
    @State private var hasAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Group {
                if let numericValue, hasAppeared {
                    Text(formatValue(displayedValue, target: targetValue))
                        .contentTransition(.numericText())
                } else {
                    Text(hasAppeared ? targetValue : " ")
                }
            }
            .font(.system(size: 36, weight: .bold, design: .rounded))
            .foregroundStyle(.primary)

            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(CounterTriggerModifier(
            hasAppeared: $hasAppeared,
            displayedValue: $displayedValue,
            numericValue: numericValue
        ))
    }

    private func formatValue(_ value: Double, target: String) -> String {
        if target.contains("%") {
            if target.contains(".") {
                return String(format: "%.1f%%", value)
            }
            return "\(Int(value))%"
        }
        if target.contains(",") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: Int(value))) ?? "\(Int(value))"
        }
        return "\(Int(value))"
    }
}

/// Triggers the counter animation when the view scrolls into visibility.
/// Uses onScrollVisibilityChange on macOS 15+, falls back to onAppear on macOS 14.
private struct CounterTriggerModifier: ViewModifier {
    @Binding var hasAppeared: Bool
    @Binding var displayedValue: Double
    let numericValue: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollVisibilityChange(threshold: 0.3) { visible in
                    if visible && !hasAppeared {
                        triggerAnimation()
                    }
                }
        } else {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onChange(of: geo.frame(in: .named("showcaseScroll")).midY) { _, midY in
                                let viewportH = NSApp.mainWindow?.contentView?.bounds.height ?? 800
                                if midY > 0 && midY < viewportH && !hasAppeared {
                                    triggerAnimation()
                                }
                            }
                    }
                )
        }
    }

    private func triggerAnimation() {
        guard !hasAppeared else { return }
        hasAppeared = true

        guard let target = numericValue, !reduceMotion else {
            if let target = numericValue {
                displayedValue = target
            }
            return
        }

        // Animate from 0 to target over ~0.8 seconds
        let steps = 30
        let duration = 0.8
        let interval = duration / Double(steps)

        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            // Ease-out curve
            let eased = 1.0 - pow(1.0 - fraction, 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(step)) {
                withAnimation(.linear(duration: interval)) {
                    displayedValue = target * eased
                }
            }
        }
    }
}

// MARK: - Section Chevron Button

/// Clickable scroll-to-next chevron. Mirrors the hero chevron bounce animation
/// but wraps in a Button with hover tracking. Used at the bottom of each section
/// (except the last) to guide the user to the next section.
struct SectionChevronButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.compact.down")
                .font(.title2)
                .foregroundStyle(foregroundColor)
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isHovered)
                .phaseAnimator([false, true]) { content, phase in
                    content.offset(y: (!reduceMotion && phase) ? 4 : 0)
                } animation: { _ in .easeInOut(duration: 1.5) }
                .padding(.horizontal, Spacing.xxxl)
                .padding(.vertical, Spacing.lg)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Continue")
        .onContinuousHover { phase in
            if case .active = phase { isHovered = true } else { isHovered = false }
        }
    }

    private var foregroundColor: Color {
        if isHovered {
            return colorScheme == .dark ? Color.primary.opacity(0.55) : Color.primary.opacity(0.45)
        }
        return colorScheme == .dark ? Color.secondary.opacity(0.44) : Color.primary.opacity(0.26)
    }
}

// MARK: - Pipeline Pill View

/// A single step in the pipeline diagram with icon and label.
struct PipelinePillView: View {
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.callout)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.xxs)
        .showcaseCard(cornerRadius: 6, tone: .deep)
    }
}

// MARK: - Showcase Section Break

/// Lightweight section divider for pipeline stages. Follows Apple's section header
/// pattern (Settings, Developer app): stroke circle with number, icon + title,
/// extending divider line. No colored accents -- uses .secondary/.tertiary only.
struct ShowcaseSectionBreak: View {
    let number: Int
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().strokeBorder(.tertiary, lineWidth: 1))

            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title3.weight(.semibold))

            VStack { Divider() }
        }
    }
}

// MARK: - Stage Connector

/// Three vertical dots connecting pipeline stages.
struct StageConnector: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: Spacing.xs) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.12))
                        .frame(width: 4, height: 4)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Previews

#Preview("Section Chevron Button - Light") {
    HStack {
        Spacer()
        SectionChevronButton { }
        Spacer()
    }
    .padding(Spacing.xxl)
    .frame(width: 400)
    .preferredColorScheme(.light)
}

#Preview("Section Chevron Button - Dark") {
    HStack {
        Spacer()
        SectionChevronButton { }
        Spacer()
    }
    .padding(Spacing.xxl)
    .frame(width: 400)
    .preferredColorScheme(.dark)
}

#Preview("Section Break + Connector - Light") {
    VStack(spacing: Spacing.xxl) {
        ShowcaseSectionBreak(number: 1, title: "Semantic Embedding", icon: "cpu")
        StageConnector()
        ShowcaseSectionBreak(number: 2, title: "LLM Match Selection", icon: "cloud")
    }
    .padding(Spacing.xxl)
    .frame(width: 600)
    .preferredColorScheme(.light)
}

#Preview("Section Break + Connector - Dark") {
    VStack(spacing: Spacing.xxl) {
        ShowcaseSectionBreak(number: 1, title: "Semantic Embedding", icon: "cpu")
        StageConnector()
        ShowcaseSectionBreak(number: 2, title: "LLM Match Selection", icon: "cloud")
    }
    .padding(Spacing.xxl)
    .frame(width: 600)
    .preferredColorScheme(.dark)
}

#Preview("Showcase Card - Light") {
    VStack(spacing: Spacing.lg) {
        Text("Standard card")
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .showcaseCard()

        Text("Highlighted card")
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .showcaseCard(highlighted: true)
    }
    .padding(Spacing.xxl)
    .frame(width: 400)
    .preferredColorScheme(.light)
}

#Preview("Showcase Card - Dark") {
    VStack(spacing: Spacing.lg) {
        Text("Standard card")
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .showcaseCard()

        Text("Highlighted card")
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .showcaseCard(highlighted: true)
    }
    .padding(Spacing.xxl)
    .frame(width: 400)
    .preferredColorScheme(.dark)
}

#Preview("Animated Counter") {
    HStack(spacing: Spacing.xxxl) {
        AnimatedCounter(
            targetValue: "1,304",
            numericValue: 1304,
            label: "Food descriptions"
        )
        AnimatedCounter(
            targetValue: "46.9%",
            numericValue: 46.9,
            label: "No valid match"
        )
    }
    .padding(Spacing.xxl)
    .frame(width: 500)
}

#Preview("Pipeline Pills") {
    HStack(spacing: Spacing.xs) {
        PipelinePillView(label: "1,304 inputs", icon: "doc.text")
        Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(.secondary)
        PipelinePillView(label: "GTE-Large", icon: "cpu")
        Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(.secondary)
        PipelinePillView(label: "Result", icon: "checkmark.circle")
    }
    .padding(Spacing.xxl)
    .frame(width: 500)
}
