import SwiftUI

/// A dark overlay with cutouts that highlight specific UI elements
/// Supports multiple highlight regions that combine into a unified spotlight
struct SpotlightView: View {
    let highlightRects: [CGRect]
    let padding: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    /// Dimming opacity adapts to color scheme. Light mode uses a gentler wash
    /// because the coach mark material blurs this layer -- heavier dimming makes
    /// the coach mark card appear dark and muddy.
    private var dimmingOpacity: Double {
        colorScheme == .dark ? 0.4 : 0.3
    }

    init(highlightRects: [CGRect], padding: CGFloat = 12) {
        self.highlightRects = highlightRects
        self.padding = padding
    }

    /// Convenience initializer for single rect
    init(highlightRect: CGRect, padding: CGFloat = 12) {
        self.highlightRects = [highlightRect]
        self.padding = padding
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Fill the content area with semi-transparent black
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(.black.opacity(dimmingOpacity))
                )

                // Cut out each highlight area
                // Rects are in overlay-local coords where (0,0) = top of content area.
                // The toolbar is above this area and remains untouched (no dimming).
                context.blendMode = .destinationOut

                for rect in highlightRects {
                    guard rect.width > 0 && rect.height > 0 else { continue }
                    let paddedRect = rect.insetBy(dx: -padding, dy: -padding)
                    let cutoutPath = Path(roundedRect: paddedRect, cornerRadius: 8)
                    context.fill(cutoutPath, with: .color(.white))
                }
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
    }

    /// Calculate combined bounding box of all highlight rects (for positioning coach marks)
    var combinedBounds: CGRect {
        guard !highlightRects.isEmpty else { return .zero }
        return highlightRects.reduce(highlightRects[0]) { $0.union($1) }
    }
}

/// Preference key for collecting anchor rects from tutorial targets
struct TutorialAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Preference key for collecting global frames (CGRect) safely to avoid layout loops.
struct TutorialFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// View modifier to mark a view as a tutorial target (preference key system).
/// Uses transformAnchorPreference so nested anchors (child inside parent) don't
/// overwrite each other -- anchorPreference replaces child values, this merges.
extension View {
    func tutorialAnchor(_ id: String) -> some View {
        self.transformAnchorPreference(key: TutorialAnchorKey.self, value: .bounds) { dict, anchor in
            dict[id] = anchor
        }
    }
}

/// View modifier that reports a view's global frame to AppState for precise tutorial highlighting.
/// Use this instead of .tutorialAnchor() for views inside sidebar List or toolbar items,
/// where preference key bounds are unreliable due to NSOutlineView/NSToolbar backing.
extension View {
    func reportTutorialFrame(_ id: String, to appState: AppState) -> some View {
        self.background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: TutorialFramePreferenceKey.self, value: [id: geo.frame(in: .global)])
            }
        }
    }
}

#Preview("Spotlight - Light") {
    ZStack {
        Color.white
        VStack(spacing: 100) {
            Button("First Button") {}
                .padding()
                .background(Color.blue)
                .cornerRadius(8)
            Button("Second Button") {}
                .padding()
                .background(Color.green)
                .cornerRadius(8)
        }
        SpotlightView(
            highlightRects: [
                CGRect(x: 150, y: 150, width: 120, height: 44),
                CGRect(x: 150, y: 294, width: 140, height: 44)
            ],
            padding: 8
        )
    }
    .frame(width: 500, height: 500)
}

#Preview("Spotlight - Dark") {
    ZStack {
        Color(nsColor: .windowBackgroundColor)
        VStack(spacing: 100) {
            Button("First Button") {}
                .padding()
                .background(Color.blue)
                .cornerRadius(8)
            Button("Second Button") {}
                .padding()
                .background(Color.green)
                .cornerRadius(8)
        }
        SpotlightView(
            highlightRects: [
                CGRect(x: 150, y: 150, width: 120, height: 44),
                CGRect(x: 150, y: 294, width: 140, height: 44)
            ],
            padding: 8
        )
    }
    .frame(width: 500, height: 500)
    .preferredColorScheme(.dark)
}
