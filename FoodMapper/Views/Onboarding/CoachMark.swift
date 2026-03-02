import SwiftUI

/// A tooltip-style coach mark with navigation controls
struct CoachMark: View {
    let step: TutorialStep
    let currentStepIndex: Int
    let totalSteps: Int
    let actualPosition: CoachMarkPosition
    let onNext: () -> Void
    let onSkip: () -> Void
    let onLoadSample: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isAppearing = false

    /// Position relative to the target after smart positioning
    enum CoachMarkPosition {
        case above, below, left, right, centerBottom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header with icon and title
            HStack(spacing: Spacing.sm) {
                Image(systemName: step.icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                Text(step.title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            // Body text
            Text(step.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Keyboard shortcut hints (keycap styling)
            if let hints = step.keyboardHints, !hints.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Keyboard Shortcuts")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, Spacing.xs)

                    ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                        HStack(spacing: Spacing.xs) {
                            HStack(spacing: Spacing.xxxs) {
                                ForEach(Array(parseKeySegments(hint.keys).enumerated()), id: \.offset) { _, segment in
                                    KeyCapView(key: segment)
                                }
                            }
                            Text(hint.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Load Sample button (Step 1 only)
            if step.showsLoadSampleButton, let onLoadSample = onLoadSample {
                Button {
                    onLoadSample()
                } label: {
                    Label("Load Sample Dataset", systemImage: "doc.badge.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, Spacing.xs)
            }

            // Toolbar button preview (for steps referencing toolbar buttons)
            if let preview = step.toolbarButtonPreview {
                HStack {
                    Spacer()
                    ToolbarButtonReplicaView(systemImage: preview.systemImage, label: preview.label)
                    Spacer()
                }
                .padding(.top, Spacing.xs)
            }

            // Progress bar and navigation
            VStack(spacing: Spacing.sm) {
                // Progress bar
                HStack(spacing: Spacing.sm) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(width: geo.size.width * CGFloat(currentStepIndex + 1) / CGFloat(totalSteps))
                                    .animation(Animate.standard, value: currentStepIndex)
                            }
                    }
                    .frame(height: Spacing.xxxs)

                    Text("\(currentStepIndex + 1)/\(totalSteps)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // Navigation buttons
                HStack {
                    Spacer()

                    if currentStepIndex < totalSteps - 1 {
                        Button("Next") {
                            onNext()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("Go to next step")
                    } else {
                        Button("Finish") {
                            onNext()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityLabel("Finish tutorial")
                    }
                }
            }

            // Skip link
            HStack {
                Spacer()
                Button("Skip Tutorial") {
                    onSkip()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHint("Skip the tutorial and access the app directly")
            }
        }
        .padding(Spacing.lg)
        .frame(width: 340)
        .background {
            Group {
                if colorScheme == .dark {
                    // Dark mode: material blur works well (dark content behind = natural)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.thickMaterial)
                } else {
                    // Light mode: solid background so the dimming overlay doesn't
                    // bleed through the blur and make the card appear gray
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .windowBackgroundColor))
                }
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.25 : 0.12),
                radius: colorScheme == .dark ? 16 : 12,
                y: 4
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.3 : 0.5),
                        lineWidth: 0.5
                    )
            }
        }
        .overlay(alignment: arrowAlignment) {
            arrowIndicator
                .offset(arrowOffset)
        }
        .scaleEffect(isAppearing ? 1.0 : 0.95)
        .opacity(isAppearing ? 1.0 : 0)
        .onAppear {
            withAnimation(Animate.standard) {
                isAppearing = true
            }
        }
        .onChange(of: currentStepIndex) { _, _ in
            // Reset animation for step transitions
            isAppearing = false
            withAnimation(Animate.standard) {
                isAppearing = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tutorial step \(currentStepIndex + 1) of \(totalSteps): \(step.title)")
    }

    // MARK: - Arrow Indicator

    private var arrowAlignment: Alignment {
        switch actualPosition {
        case .above: return .bottom
        case .below: return .top
        case .left: return .trailing
        case .right: return .leading
        case .centerBottom: return .top
        }
    }

    private var arrowOffset: CGSize {
        switch actualPosition {
        case .above: return CGSize(width: 0, height: 6)
        case .below: return CGSize(width: 0, height: -6)
        case .left: return CGSize(width: 6, height: 0)
        case .right: return CGSize(width: -6, height: 0)
        case .centerBottom: return CGSize(width: 0, height: -6)
        }
    }

    @ViewBuilder
    private var arrowIndicator: some View {
        if actualPosition != .centerBottom {
            Triangle()
                .fill(colorScheme == .dark
                    ? AnyShapeStyle(.thickMaterial)
                    : AnyShapeStyle(Color(nsColor: .windowBackgroundColor)))
                .frame(width: 16, height: 10)
                .rotationEffect(arrowRotation)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        }
    }

    private var arrowRotation: Angle {
        switch actualPosition {
        case .above: return .degrees(180)
        case .below: return .degrees(0)
        case .left: return .degrees(90)
        case .right: return .degrees(-90)
        case .centerBottom: return .degrees(0)
        }
    }
}

/// Simple triangle shape for arrow indicator
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Toolbar Button Replica

/// Animated replica of a toolbar button shown inside coach marks for steps
/// that reference toolbar items (which can't be spotlighted from the overlay).
struct ToolbarButtonReplicaView: View {
    let systemImage: String
    let label: String

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
            Text(label)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(isAnimating ? Color.accentColor : .primary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isAnimating ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isAnimating ? Color.accentColor.opacity(0.4) : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - Smart Positioning Calculator

enum CoachMarkPositioning {
    /// Calculate optimal coach mark position that doesn't cover the target
    static func calculatePosition(
        targetRect: CGRect,
        coachMarkSize: CGSize,
        screenSize: CGSize,
        preferred: TutorialStep.CoachMarkPosition
    ) -> (position: CGPoint, actualDirection: CoachMark.CoachMarkPosition) {
        let gap: CGFloat = 24
        let margin: CGFloat = 24

        let preferredDirection = convertDirection(preferred)

        // Try preferred direction first
        if let result = tryPosition(
            direction: preferredDirection,
            targetRect: targetRect,
            coachMarkSize: coachMarkSize,
            screenSize: screenSize,
            gap: gap,
            margin: margin
        ) {
            return result
        }

        // Try opposite direction
        let opposite = oppositeDirection(preferredDirection)
        if let result = tryPosition(
            direction: opposite,
            targetRect: targetRect,
            coachMarkSize: coachMarkSize,
            screenSize: screenSize,
            gap: gap,
            margin: margin
        ) {
            return result
        }

        // Try perpendicular directions
        let perpendiculars = perpendicularDirections(preferredDirection)
        for perpendicular in perpendiculars {
            if let result = tryPosition(
                direction: perpendicular,
                targetRect: targetRect,
                coachMarkSize: coachMarkSize,
                screenSize: screenSize,
                gap: gap,
                margin: margin
            ) {
                return result
            }
        }

        // Fallback: center bottom of screen
        let centerX = screenSize.width / 2
        let bottomY = screenSize.height - coachMarkSize.height / 2 - margin
        return (CGPoint(x: centerX, y: bottomY), .centerBottom)
    }

    private static func convertDirection(_ direction: TutorialStep.CoachMarkPosition) -> CoachMark.CoachMarkPosition {
        switch direction {
        case .above: return .above
        case .below: return .below
        case .left: return .left
        case .right: return .right
        case .centerBottom: return .centerBottom
        }
    }

    private static func tryPosition(
        direction: CoachMark.CoachMarkPosition,
        targetRect: CGRect,
        coachMarkSize: CGSize,
        screenSize: CGSize,
        gap: CGFloat,
        margin: CGFloat
    ) -> (position: CGPoint, actualDirection: CoachMark.CoachMarkPosition)? {
        var x: CGFloat
        var y: CGFloat

        switch direction {
        case .above:
            x = targetRect.midX
            y = targetRect.minY - coachMarkSize.height / 2 - gap

        case .below:
            x = targetRect.midX
            y = targetRect.maxY + coachMarkSize.height / 2 + gap

        case .left:
            x = targetRect.minX - coachMarkSize.width / 2 - gap
            y = targetRect.midY

        case .right:
            x = targetRect.maxX + coachMarkSize.width / 2 + gap
            y = targetRect.midY

        case .centerBottom:
            x = screenSize.width / 2
            y = screenSize.height - coachMarkSize.height / 2 - margin
            return (CGPoint(x: x, y: y), direction)
        }

        // Check if position is valid (within screen bounds with margin)
        let halfWidth = coachMarkSize.width / 2
        let halfHeight = coachMarkSize.height / 2

        let minX = halfWidth + margin
        let maxX = screenSize.width - halfWidth - margin
        let minY = halfHeight + margin
        let maxY = screenSize.height - halfHeight - margin

        if x < minX || x > maxX || y < minY || y > maxY {
            let clampedX = max(minX, min(x, maxX))
            let clampedY = max(minY, min(y, maxY))

            let coachRect = CGRect(
                x: clampedX - halfWidth,
                y: clampedY - halfHeight,
                width: coachMarkSize.width,
                height: coachMarkSize.height
            )

            let paddedTarget = targetRect.insetBy(dx: -gap, dy: -gap)
            if coachRect.intersects(paddedTarget) {
                return nil
            }

            return (CGPoint(x: clampedX, y: clampedY), direction)
        }

        return (CGPoint(x: x, y: y), direction)
    }

    private static func oppositeDirection(_ direction: CoachMark.CoachMarkPosition) -> CoachMark.CoachMarkPosition {
        switch direction {
        case .above: return .below
        case .below: return .above
        case .left: return .right
        case .right: return .left
        case .centerBottom: return .above
        }
    }

    private static func perpendicularDirections(_ direction: CoachMark.CoachMarkPosition) -> [CoachMark.CoachMarkPosition] {
        switch direction {
        case .above, .below: return [.left, .right]
        case .left, .right: return [.above, .below]
        case .centerBottom: return [.left, .right]
        }
    }
}

#Preview("Coach Mark - Step 1 - Light") {
    ZStack {
        Color.gray.opacity(0.3)
        CoachMark(
            step: TutorialSteps.all[0],
            currentStepIndex: 0,
            totalSteps: TutorialSteps.count,
            actualPosition: .below,
            onNext: {},
            onSkip: {},
            onLoadSample: nil
        )
    }
    .frame(width: 600, height: 500)
}

#Preview("Coach Mark - Dark") {
    ZStack {
        Color.gray.opacity(0.3)
        CoachMark(
            step: TutorialSteps.all[0],
            currentStepIndex: 0,
            totalSteps: TutorialSteps.count,
            actualPosition: .below,
            onNext: {},
            onSkip: {},
            onLoadSample: nil
        )
    }
    .frame(width: 600, height: 500)
    .preferredColorScheme(.dark)
}

#Preview("Coach Mark - With Load Sample") {
    ZStack {
        Color.gray.opacity(0.3)
        CoachMark(
            step: TutorialSteps.all.first(where: { $0.showsLoadSampleButton }) ?? TutorialSteps.all[0],
            currentStepIndex: 1,
            totalSteps: TutorialSteps.count,
            actualPosition: .right,
            onNext: {},
            onSkip: {},
            onLoadSample: {}
        )
    }
    .frame(width: 600, height: 500)
}
