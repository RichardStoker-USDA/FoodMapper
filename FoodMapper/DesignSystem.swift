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
    static let statusError = Color.red

    // Experimental/beta badge amber -- warm, muted, not system .orange
    static let experimentalAmber = Color(red: 0.85, green: 0.55, blue: 0.15)

    // Score color based on absolute thresholds (unified across table dots + inspector badges)
    static func scoreColor(_ score: Double) -> Color {
        switch score {
        case 0.86...:     return .green
        case 0.80..<0.86: return .experimentalAmber
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
        return .experimentalAmber
    }

    // Semantic surface colors
    static let surfacePrimary = Color(nsColor: .windowBackgroundColor)
    static let surfaceSecondary = Color(nsColor: .controlBackgroundColor)
    static let surfaceTertiary = Color(nsColor: .underPageBackgroundColor)

    // Card colors used by technical panels
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

    // Neutral badge background for compact status text.
    static func badgeBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.black.opacity(0.06)
    }

    static func appBadgeFill(_ tone: AppBadgeTone, for colorScheme: ColorScheme) -> Color {
        switch tone {
        case .accent:
            return badgeBackground(for: colorScheme)
        case .accentStrong:
            return badgeBackground(for: colorScheme)
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
        case .success:
            return colorScheme == .dark ? Color.green.opacity(0.18) : Color.green.opacity(0.14)
        case .warning:
            return colorScheme == .dark ? Color.experimentalAmber.opacity(0.22) : Color.experimentalAmber.opacity(0.16)
        case .danger:
            return colorScheme == .dark ? Color.red.opacity(0.20) : Color.red.opacity(0.14)
        }
    }

    static func appBadgeStroke(_ tone: AppBadgeTone, for colorScheme: ColorScheme) -> Color {
        switch tone {
        case .accent:
            return colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
        case .accentStrong:
            return colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
        case .success:
            return colorScheme == .dark ? Color.green.opacity(0.45) : Color.green.opacity(0.32)
        case .warning:
            return colorScheme == .dark ? Color.experimentalAmber.opacity(0.50) : Color.experimentalAmber.opacity(0.34)
        case .danger:
            return colorScheme == .dark ? Color.red.opacity(0.52) : Color.red.opacity(0.34)
        }
    }

    static func appBadgeForeground(_ tone: AppBadgeTone, for colorScheme: ColorScheme) -> Color {
        switch tone {
        case .accent:
            return colorScheme == .dark ? Color.white.opacity(0.88) : Color.primary.opacity(0.74)
        case .accentStrong:
            return colorScheme == .dark ? Color.white.opacity(0.88) : Color.primary.opacity(0.74)
        case .neutral:
            return colorScheme == .dark ? Color.white.opacity(0.88) : Color.primary.opacity(0.74)
        case .success:
            return colorScheme == .dark ? Color.green.opacity(0.96) : Color.green.opacity(0.90)
        case .warning:
            return colorScheme == .dark ? Color.experimentalAmber.opacity(0.98) : Color.experimentalAmber.opacity(0.88)
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
    /// SF Symbol hierarchical rendering.
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

    /// Background used by overlay panels
    func panelMaterialStyle(cornerRadius: CGFloat = 6) -> some View {
        modifier(PanelMaterialModifier(cornerRadius: cornerRadius))
    }

    /// Neutral action group background.
    func actionButtonsCard(colorScheme: ColorScheme) -> some View {
        modifier(ActionButtonsCardModifier(colorScheme: colorScheme))
    }

    /// Settings panel card styling with extra light-mode edge definition.
    func settingsCardStyle(cornerRadius: CGFloat = 10) -> some View {
        modifier(SettingsCardModifier(cornerRadius: cornerRadius))
    }

    /// Compact rounded badge styling with semantic color tone.
    func appBadgeStyle(
        tone: AppBadgeTone = .neutral,
        cornerRadius: CGFloat = 5
    ) -> some View {
        modifier(AppBadgeModifier(tone: tone, cornerRadius: cornerRadius))
    }

    /// Shared secondary action background.
    func liquidGlassButtonStyle(
        color: Color,
        cornerRadius: CGFloat = 8,
        isActive: Bool = true
    ) -> some View {
        modifier(LiquidGlassButtonModifier(color: color, cornerRadius: cornerRadius, isActive: isActive))
    }

}

// MARK: - Button Background Modifier

struct LiquidGlassButtonModifier: ViewModifier {
    let color: Color
    let cornerRadius: CGFloat
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .background(color.opacity(isActive ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(color.opacity(isActive ? 0.35 : 0.18), lineWidth: 0.66)
            }
    }
}

// MARK: - Panel Material Modifier

struct PanelMaterialModifier: ViewModifier {
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
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.66)
            )
    }
}

// MARK: - Action Buttons Card Modifier

/// Neutral action group container.
struct ActionButtonsCardModifier: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .padding(Spacing.sm)
            .background(Color.cardBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.66)
            )
    }
}

// MARK: - Settings Card Modifier

struct SettingsCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelMaterialStyle(cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.08)
                            : Color.white.opacity(0.52),
                        lineWidth: 0.66
                    )
            )
    }
}

struct AppBadgeModifier: ViewModifier {
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

/// Opacity-only feedback for text-style buttons.
struct InteractiveTextButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : (isHovering ? 0.85 : 1.0))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 1, y: 1)
    }
}
