import SwiftUI

// MARK: - Debug Configuration
// Developer-only flags. Set to true in code to enable debug features.
// These must NEVER ship as true in a release build.

enum DebugConfig {
    /// Shows colored borders and labels around all tutorial anchor frames.
    /// Edit this line to `true` to see exactly where the tutorial system
    /// thinks each highlighted element is positioned at runtime.
    static let showTutorialAnchorFrames = false
}

// MARK: - Animation Constants

enum Animate {
    /// Quick interactions like hover states
    static let quick = Animation.spring(response: 0.2, dampingFraction: 0.7)
    /// Standard UI transitions
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.75)
    /// Deliberate movements like panel reveals
    static let smooth = Animation.spring(response: 0.4, dampingFraction: 0.8)
    /// Bouncy emphasis for attention
    static let bouncy = Animation.spring(response: 0.3, dampingFraction: 0.6)
}

// MARK: - Spacing Constants

enum Spacing {
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

// MARK: - Size Constants

enum Size {
    static let sidebarMin: CGFloat = 220
    static let sidebarIdeal: CGFloat = 260
    static let sidebarMax: CGFloat = 350

    static let statusBarHeight: CGFloat = 24
    static let toolbarHeight: CGFloat = 38
    static let tableRowHeight: CGFloat = 28

    static let progressBarHeight: CGFloat = 6
    static let statusDot: CGFloat = 8
    static let iconSmall: CGFloat = 14
    static let iconMedium: CGFloat = 18
    static let iconLarge: CGFloat = 24
    static let iconHero: CGFloat = 40
}

/// Semantic tone presets for compact UI labels/badges.
enum AppBadgeTone {
    case accent
    case accentStrong
    case neutral
    case success
    case warning
    case danger
}

// MARK: - Color Extensions

extension Color {
    // Status colors
    static let statusMatch = Color.green
    static let statusLLM = Color.indigo
    static let statusNone = Color(nsColor: .tertiaryLabelColor)
    static let statusError = Color.orange

    // Experimental/beta badge amber -- warm, muted, not system .orange
    static let experimentalAmber = Color(red: 0.85, green: 0.55, blue: 0.15)

    // Score color based on absolute thresholds (unified across table dots + inspector badges)
    static func scoreColor(_ score: Double) -> Color {
        switch score {
        case 0.86...:     return .green
        case 0.80..<0.86: return .orange
        default:          return Color(nsColor: .secondaryLabelColor)
        }
    }

    // White text for all solid score badges (green/orange/gray backgrounds)
    static func scoreBadgeForeground(_ score: Double) -> Color {
        return .white
    }

    // Threshold indicator color (green when at recommended level)
    static func thresholdColor(_ value: Double) -> Color {
        if value >= 0.85 { return .green }
        if value >= 0.70 { return .yellow }
        return .orange
    }

    // Semantic surface colors
    static let surfacePrimary = Color(nsColor: .windowBackgroundColor)
    static let surfaceSecondary = Color(nsColor: .controlBackgroundColor)
    static let surfaceTertiary = Color(nsColor: .underPageBackgroundColor)

    // Card colors with premium technical contrast
    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(white: 0.14).opacity(0.95) // Elevated gray from Research Showcase
            : Color.white
    }

    static func cardBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.12)
    }

    static func cardShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.black.opacity(0.4)
            : Color.black.opacity(0.18)
    }

    // Badge background with better light mode visibility
    static func badgeBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.accentColor.opacity(0.15)
            : Color.accentColor.opacity(0.18)
    }

    static func appBadgeFill(_ tone: AppBadgeTone, for colorScheme: ColorScheme) -> Color {
        switch tone {
        case .accent:
            return colorScheme == .dark ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.14)
        case .accentStrong:
            return colorScheme == .dark ? Color.accentColor.opacity(0.90) : Color.accentColor.opacity(0.98)
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        case .success:
            return colorScheme == .dark ? Color.green.opacity(0.18) : Color.green.opacity(0.14)
        case .warning:
            return colorScheme == .dark ? Color.orange.opacity(0.22) : Color.orange.opacity(0.16)
        case .danger:
            return colorScheme == .dark ? Color.red.opacity(0.20) : Color.red.opacity(0.14)
        }
    }

    static func appBadgeStroke(_ tone: AppBadgeTone, for colorScheme: ColorScheme) -> Color {
        switch tone {
        case .accent:
            return colorScheme == .dark ? Color.accentColor.opacity(0.42) : Color.accentColor.opacity(0.30)
        case .accentStrong:
            return colorScheme == .dark ? Color.white.opacity(0.28) : Color.accentColor.opacity(0.45)
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
        case .success:
            return colorScheme == .dark ? Color.green.opacity(0.45) : Color.green.opacity(0.32)
        case .warning:
            return colorScheme == .dark ? Color.orange.opacity(0.50) : Color.orange.opacity(0.34)
        case .danger:
            return colorScheme == .dark ? Color.red.opacity(0.52) : Color.red.opacity(0.34)
        }
    }

    static func appBadgeForeground(_ tone: AppBadgeTone, for colorScheme: ColorScheme) -> Color {
        switch tone {
        case .accent:
            return Color.accentColor
        case .accentStrong:
            return colorScheme == .dark ? Color.white.opacity(0.96) : Color.white
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.88) : Color.primary.opacity(0.74)
        case .success:
            return colorScheme == .dark ? Color.green.opacity(0.96) : Color.green.opacity(0.90)
        case .warning:
            return colorScheme == .dark ? Color.orange.opacity(0.98) : Color.orange.opacity(0.88)
        case .danger:
            return colorScheme == .dark ? Color.red.opacity(0.98) : Color.red.opacity(0.88)
        }
    }

    // Indigo tone for "needs review" state, distinct from score colors and match green/gray
    @available(*, deprecated, message: "Use Color.accentColor or MatchCategory.needsReview.color instead")
    static let reviewIndigo = Color.accentColor

}

// MARK: - Tahoe Picker Sizing

/// macOS 26 changed menu-style Pickers to fitted (shrink-wrap) by default.
/// This restores flexible (fill-width) sizing where the layout expects it.
/// No-op on Sonoma/Sequoia where flexible was already the default.
struct FlexiblePickerSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonSizing(.flexible)
        } else {
            content
        }
    }
}

// MARK: - View Modifiers

extension View {
    /// SF Symbol hierarchical rendering (gradient depth)
    func symbolGradient() -> some View {
        self.symbolRenderingMode(.hierarchical)
    }

    /// Restores flexible (fill-width) sizing for menu Pickers on macOS 26 Tahoe.
    /// No-op on Sonoma/Sequoia where flexible is already the default.
    func flexiblePickerSizing() -> some View {
        modifier(FlexiblePickerSizing())
    }

    /// Technical header styling with wide tracking for system panels
    func technicalHeader() -> some View {
        self.font(.system(.title3, design: .monospaced, weight: .semibold))
            .tracking(2.0)
            .textCase(.uppercase)
    }

    /// Small uppercase technical labels
    func technicalLabel() -> some View {
        self.font(.system(.caption, weight: .bold))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(Color.secondary)
    }

    /// Technical monospace data values
    func technicalData() -> some View {
        self.font(.system(.body, design: .monospaced))
    }

    /// Standard card styling (border + shadow, works across OS versions)
    func cardStyle() -> some View {
        modifier(CardStyleModifier())
    }

    /// Glassmorphic background for overlays
    func premiumMaterialStyle(cornerRadius: CGFloat = 6) -> some View {
        modifier(PremiumMaterialModifier(cornerRadius: cornerRadius))
    }

    /// Frosted action buttons card for toolbar-adjacent panels.
    /// Pass colorScheme explicitly so SwiftUI tracks the dependency correctly
    /// (avoids lag when switching light/dark mode).
    func actionButtonsCard(colorScheme: ColorScheme) -> some View {
        modifier(ActionButtonsCardModifier(colorScheme: colorScheme))
    }

    /// Settings panel card styling with extra light-mode edge definition.
    func settingsCardStyle(cornerRadius: CGFloat = 10) -> some View {
        modifier(SettingsCardModifier(cornerRadius: cornerRadius))
    }

    /// Compact rounded badge styling with semantic color tone.
    func polishedBadge(
        tone: AppBadgeTone = .neutral,
        cornerRadius: CGFloat = 5
    ) -> some View {
        modifier(PolishedBadgeModifier(tone: tone, cornerRadius: cornerRadius))
    }

    /// Premium Liquid Glass button style for macOS 26 Tahoe.
    /// Resembles the primary toolbar actions with material layering and depth.
    func liquidGlassButtonStyle(
        color: Color,
        cornerRadius: CGFloat = 8,
        isActive: Bool = true
    ) -> some View {
        modifier(LiquidGlassButtonModifier(color: color, cornerRadius: cornerRadius, isActive: isActive))
    }

}

// MARK: - Liquid Glass Button Modifier

struct LiquidGlassButtonModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let color: Color
    let cornerRadius: CGFloat
    let isActive: Bool

    // Matched exactly to the primary MatchButton for perfect contrast
    private var accentOpacity: Double { colorScheme == .dark ? 0.65 : 0.85 }
    private var specularPeak: Double { colorScheme == .dark ? 0.4 : 0.12 }
    private var edgeGlowTop: Double { colorScheme == .dark ? 0.55 : 0.3 }
    private var edgeGlowBottom: Double { colorScheme == .dark ? 0.12 : 0.05 }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if #available(macOS 26, *) {
                        let buttonColor = (color == .secondary && colorScheme == .light) ? Color(white: 0.35) : color
                        
                        // Layer 0: Colored backlight for saturation
                        Capsule().fill(buttonColor.opacity(0.35))
                        // Layer 1: Material base
                        Capsule().fill(.ultraThinMaterial)
                        // Layer 2: Color tint
                        Capsule().fill(buttonColor.opacity(accentOpacity))
                        // Layer 3: Specular highlight (top curve)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(specularPeak), .white.opacity(0.06), .clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .padding(.horizontal, 2).padding(.top, 1)
                        // Layer 4: Inner refraction edge
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(edgeGlowTop), .white.opacity(edgeGlowBottom)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 0.7
                            )
                    } else {
                        // Sequoia/Sonoma fallback: rich solid capsule with shadow
                        let buttonColor = (color == .secondary && colorScheme == .light) ? Color(white: 0.4) : color
                        Capsule()
                            .fill(buttonColor.opacity(colorScheme == .dark ? 0.9 : 1.0))
                            .shadow(color: buttonColor.opacity(colorScheme == .dark ? 0.5 : 0.3), radius: 6, y: 3)
                    }
                }
            }
            .contentShape(Capsule())
    }
}

// MARK: - Premium Material Modifier

struct PremiumMaterialModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    if colorScheme == .dark {
                        if #available(macOS 15.0, *) {
                            Rectangle().fill(.ultraThinMaterial)
                        } else {
                            Color(nsColor: .windowBackgroundColor)
                        }
                    } else {
                        // No ultraThinMaterial in light mode -- it looks muddy
                        Color(nsColor: .controlBackgroundColor)
                    }
                }
            )
            .background(colorScheme == .dark ? Color.black.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.66)
            )
            .shadow(
                color: colorScheme == .dark ? Color.black.opacity(0.3) : Color.black.opacity(0.15),
                radius: colorScheme == .dark ? 12 : 10,
                y: colorScheme == .dark ? 8 : 6
            )
    }
}

// MARK: - Action Buttons Card Modifier

/// Liquid Glass on Tahoe, subtle card on Sequoia/Sonoma.
/// colorScheme passed explicitly to fix lag when switching light/dark.
struct ActionButtonsCardModifier: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .padding(Spacing.sm)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.cardBackground(for: colorScheme))
                            .glassEffect(.regular)
                    }
                    .shadow(color: Color.cardShadow(for: colorScheme), radius: 8, y: 4)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1.0)
                )
                .overlay {
                    if colorScheme == .light {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                            .padding(0.5)
                    }
                }
        } else {
            // macOS 15/14: subtle frosted card
            content
                .padding(Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.cardBackground(for: colorScheme))
                        .shadow(color: Color.cardShadow(for: colorScheme), radius: 8, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1.0)
                )
                .overlay {
                    if colorScheme == .light {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                            .padding(0.5)
                    }
                }
        }
    }
}

// MARK: - Settings Card Modifier

struct SettingsCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .premiumMaterialStyle(cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.08)
                            : Color.white.opacity(0.52),
                        lineWidth: 0.66
                    )
            )
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.18)
                    : Color.black.opacity(0.05),
                radius: 1.5,
                y: 1
            )
    }
}

struct PolishedBadgeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let tone: AppBadgeTone
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color.appBadgeForeground(tone, for: colorScheme))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.appBadgeFill(tone, for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.appBadgeStroke(tone, for: colorScheme),
                        lineWidth: 0.66
                    )
            )
    }
}

/// .symbolEffect(.appear) on macOS 15+, opacity fallback on older.
struct SymbolAppearTransition: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.transition(.symbolEffect(.appear))
        } else {
            content.transition(.opacity)
        }
    }
}

// MARK: - Interactive Text Button Style

/// Subtle scale + opacity on hover/press for text-style buttons.
struct InteractiveTextButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : (isHovering ? 0.85 : 1.0))
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovering ? 1.01 : 1.0))
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == InteractiveTextButtonStyle {
    static var interactiveText: InteractiveTextButtonStyle {
        InteractiveTextButtonStyle()
    }
}

/// Header icon button: rounded bg flash on press.
struct HeaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Fixed height for all page headers so dividers stay aligned across pages.
enum HeaderLayout {
    static let height: CGFloat = 40
}

struct CardStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(Spacing.lg)
            .background(Color.cardBackground(for: colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 1)
            )
            .shadow(
                color: Color.cardShadow(for: colorScheme),
                radius: colorScheme == .dark ? 12 : 6,
                y: colorScheme == .dark ? 6 : 2
            )
    }
}

// MARK: - Polished Shine Modifier

/// Rotating border shine for primary CTAs (Match button, Research card).
/// TimelineView(.animation) instead of withAnimation(.repeatForever) because
/// the latter leaks its animation into parent toolbar layout on macOS 14-15.
struct PolishedShineModifier: ViewModifier {
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let duration: Double
    let isActive: Bool
    let customColor: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(cornerRadius: CGFloat = 12, lineWidth: CGFloat = 2.0, duration: Double = 3.5, isActive: Bool = true, color: Color? = nil) {
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
        self.duration = duration
        self.isActive = isActive
        self.customColor = color
    }

    private var shineColor: Color {
        if let customColor { return customColor }
        return colorScheme == .dark ? .white : .accentColor
    }

    /// Whether to use Capsule shape (perfect semicircle ends) vs RoundedRectangle
    private var useCapsule: Bool { cornerRadius >= 100 }

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive && !reduceMotion {
                    TimelineView(.animation) { timeline in
                        let elapsed = timeline.date.timeIntervalSinceReferenceDate
                        let rotation = (elapsed / duration).truncatingRemainder(dividingBy: 1.0) * 360
                        let gradient = AngularGradient(
                            gradient: Gradient(colors: [
                                shineColor.opacity(0),
                                shineColor.opacity(0.2),
                                shineColor.opacity(0.9),
                                shineColor.opacity(0.2),
                                shineColor.opacity(0)
                            ]),
                            center: .center,
                            startAngle: .degrees(rotation),
                            endAngle: .degrees(rotation + 80)
                        )

                        if useCapsule {
                            Capsule(style: .continuous)
                                .strokeBorder(gradient, lineWidth: lineWidth)
                                .mask(Capsule(style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(gradient, lineWidth: lineWidth)
                                .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Adds a polished, rotating border shine animation.
    func polishedShine(cornerRadius: CGFloat = 12, lineWidth: CGFloat = 2.0, isActive: Bool = true, color: Color? = nil) -> some View {
        modifier(PolishedShineModifier(cornerRadius: cornerRadius, lineWidth: lineWidth, duration: 3.5, isActive: isActive, color: color))
    }
}

// MARK: - New Feature Glow Modifier (Deprecated/Replaced by PolishedShine)

struct NewFeatureGlowModifier: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat
    let duration: Double?

    func body(content: Content) -> some View {
        // Fallback or just pass through for now, as we migrate to PolishedShine
        content.polishedShine(cornerRadius: cornerRadius, isActive: isActive)
    }
}

extension View {
    func newFeatureGlow(isActive: Bool, cornerRadius: CGFloat = 12, duration: Double? = nil) -> some View {
        modifier(NewFeatureGlowModifier(isActive: isActive, cornerRadius: cornerRadius, duration: duration))
    }
}
