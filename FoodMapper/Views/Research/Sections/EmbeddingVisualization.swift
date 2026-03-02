import SwiftUI

/// Interactive visualization of semantic embedding space.
/// Shows food descriptions as dots clustered by semantic similarity,
/// with animated connecting lines and cosine similarity scores.
/// Auto-cycles through 3 scenarios every 5 seconds; tap to select manually.
struct EmbeddingVisualization: View {
    @State private var currentScenario: Int
    @State private var isAutoPlaying = true
    @State private var showInfoPopover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let scenarios = EmbeddingScenarioData.all
    private let visualizationHelpText = "Illustrative example only. Dot positions and similarity values are simplified to explain semantic embedding behavior and are not exact benchmark outputs."

    init(initialScenario: Int = 0) {
        let maxIndex = max(EmbeddingScenarioData.all.count - 1, 0)
        let clamped = min(max(initialScenario, 0), maxIndex)
        _currentScenario = State(initialValue: clamped)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main visualization with picker inside card
            VStack(spacing: 0) {
                // Scenario selector at top of card
                HStack(spacing: Spacing.sm) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(0..<scenarios.count, id: \.self) { i in
                            let isSelected = currentScenario == i
                            Button {
                                advanceScenario(to: i)
                            } label: {
                                Text(scenarios[i].inputLabel)
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, Spacing.xs)
                                    .background(
                                        Capsule().fill(scenarioPillFill(isSelected))
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(scenarioPillStroke(isSelected), lineWidth: 0.66)
                                    )
                                    .foregroundStyle(scenarioPillForeground(isSelected))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: Spacing.sm)
                    infoButton
                }
                .animation(Animate.quick, value: currentScenario)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)

                // Canvas below
                GeometryReader { geo in
                    ZStack {
                        gridBackground(size: geo.size)
                        connectingLines(size: geo.size)
                        scoreLabels(size: geo.size)
                        foodDots(size: geo.size)
                    }
                }
                .frame(height: 180) // Reduced height to save space
                .padding(.horizontal, Spacing.sm)
                .padding(.bottom, Spacing.sm)
            }
            .showcaseCard(cornerRadius: 10, tone: .deep)
        }
        .task(id: isAutoPlaying) {
            guard isAutoPlaying, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                advanceScenario()
            }
        }
    }

    // MARK: - Computed Properties

    private var currentFoods: [EmbeddingFoodPoint] {
        scenarios[currentScenario].foods
    }

    private var inputFood: EmbeddingFoodPoint? {
        currentFoods.first { $0.isInput }
    }

    private var candidates: [EmbeddingFoodPoint] {
        currentFoods.filter { !$0.isInput }
    }

    // MARK: - Grid Background

    private func gridBackground(size: CGSize) -> some View {
        let dotOpacity = colorScheme == .dark ? 0.13 : 0.14
        return Canvas { context, canvasSize in
            let spacing: CGFloat = 40
            let dotRadius: CGFloat = 1.5
            let color = Color.primary.opacity(dotOpacity)

            for x in stride(from: spacing, to: canvasSize.width, by: spacing) {
                for y in stride(from: spacing, to: canvasSize.height, by: spacing) {
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: x - dotRadius, y: y - dotRadius,
                            width: dotRadius * 2, height: dotRadius * 2
                        )),
                        with: .color(color)
                    )
                }
            }
        }
    }

    // MARK: - Connecting Lines

    private func connectingLines(size: CGSize) -> some View {
        ForEach(candidates) { candidate in
            if let input = inputFood {
                AnimatedLine(
                    from: mapPoint(input.position, in: size),
                    to: mapPoint(candidate.position, in: size)
                )
                .stroke(
                    Color.accentColor.opacity(candidate.similarity > 0.85 ? 0.45 : 0.25),
                    style: StrokeStyle(
                        lineWidth: candidate.similarity > 0.85 ? 1.5 : 0.8,
                        dash: candidate.similarity < 0.85 ? [4, 4] : []
                    )
                )
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: currentScenario)
            }
        }
    }

    // MARK: - Score Labels

    private func scoreLabels(size: CGSize) -> some View {
        ForEach(candidates) { candidate in
            if let input = inputFood {
                let from = mapPoint(input.position, in: size)
                let to = mapPoint(candidate.position, in: size)
                let labelPoint = resolvedScorePosition(
                    from: from,
                    to: to,
                    requestedOffset: candidate.scoreOffset
                )

                Text(String(format: "%.2f", candidate.similarity))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                colorScheme == .dark
                                    ? Color(nsColor: .textBackgroundColor).opacity(0.90)
                                    : Color(nsColor: .windowBackgroundColor).opacity(0.96)
                            )
                    }
                    .position(labelPoint)
                    .zIndex(2)
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: currentScenario)
            }
        }
    }

    // MARK: - Food Dots

    private func foodDots(size: CGSize) -> some View {
        ForEach(currentFoods) { food in
            let pos = mapPoint(food.position, in: size)

            ZStack {
                Circle()
                    .fill(food.isInput ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(
                        width: food.isInput ? 14 : 10,
                        height: food.isInput ? 14 : 10
                    )
                    .overlay {
                        if food.isInput {
                            Circle()
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 3)
                                .frame(width: 22, height: 22)
                        }
                    }

                Text(food.shortLabel)
                    .font(.system(size: 9, weight: food.isInput ? .semibold : .regular))
                    .foregroundStyle(
                        food.isInput
                            ? .primary
                            : (colorScheme == .dark ? Color.secondary : Color.primary.opacity(0.78))
                    )
                    .lineLimit(1)
                    .frame(
                        width: food.labelPlacement == .left ? 120 : 100,
                        alignment: food.labelPlacement == .left ? .trailing : .center
                    )
                    .offset(
                        x: labelBaseOffset(for: food).width + food.labelOffset.width,
                        y: labelBaseOffset(for: food).height + food.labelOffset.height
                    )
            }
            .help(food.label)
            .position(pos)
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: currentScenario)
        }
    }

    private var infoButton: some View {
        Button {
            showInfoPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    colorScheme == .dark
                        ? Color.secondary.opacity(0.92)
                        : Color.primary.opacity(0.62)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(visualizationHelpText)
        .popover(isPresented: $showInfoPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Visualization Note")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(visualizationHelpText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 320, alignment: .leading)
            .padding(Spacing.lg)
            .presentationBackground {
                if colorScheme == .dark {
                    Rectangle().fill(.ultraThinMaterial)
                } else {
                    Color.white
                }
            }
        }
    }

    private func labelBaseOffset(for food: EmbeddingFoodPoint) -> CGSize {
        switch food.labelPlacement {
        case .left:
            return CGSize(width: -66, height: 0)
        case .above:
            return CGSize(width: 0, height: -16)
        case .below:
            return CGSize(width: 0, height: 16)
        }
    }

    private func resolvedScorePosition(
        from: CGPoint,
        to: CGPoint,
        requestedOffset: CGSize
    ) -> CGPoint {
        let line = CGPoint(x: to.x - from.x, y: to.y - from.y)
        let lengthSquared = line.x * line.x + line.y * line.y
        guard lengthSquared > 0.0001 else {
            return CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        }

        let requested = CGPoint(
            x: (from.x + to.x) / 2 + requestedOffset.width,
            y: (from.y + to.y) / 2 + requestedOffset.height
        )
        let vectorToRequested = CGPoint(x: requested.x - from.x, y: requested.y - from.y)

        // Keep the score box on the connector segment (not near endpoints).
        let rawT = (vectorToRequested.x * line.x + vectorToRequested.y * line.y) / lengthSquared
        let clampedT = min(max(rawT, 0.28), 0.72)
        let projectedOnLine = CGPoint(
            x: from.x + line.x * clampedT,
            y: from.y + line.y * clampedT
        )

        // Allow only a small perpendicular shift so labels stay readable on the line.
        let rawProjection = CGPoint(
            x: from.x + line.x * rawT,
            y: from.y + line.y * rawT
        )
        var perpendicular = CGPoint(
            x: requested.x - rawProjection.x,
            y: requested.y - rawProjection.y
        )
        let perpendicularLength = sqrt(
            perpendicular.x * perpendicular.x +
            perpendicular.y * perpendicular.y
        )
        let maxPerpendicular: CGFloat = 12
        if perpendicularLength > maxPerpendicular, perpendicularLength > 0 {
            let scale = maxPerpendicular / perpendicularLength
            perpendicular.x *= scale
            perpendicular.y *= scale
        }

        var candidate = CGPoint(
            x: projectedOnLine.x + perpendicular.x,
            y: projectedOnLine.y + perpendicular.y
        )

        // Guard against labels landing on top of either dot.
        let minDotDistance: CGFloat = 18
        if distance(candidate, from) < minDotDistance || distance(candidate, to) < minDotDistance {
            let safeT: CGFloat = 0.55
            let lineLength = sqrt(lengthSquared)
            let normal = CGPoint(x: -line.y / lineLength, y: line.x / lineLength)
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let side: CGFloat = (requested.y - mid.y) >= 0 ? 1 : -1
            candidate = CGPoint(
                x: from.x + line.x * safeT + normal.x * 8 * side,
                y: from.y + line.y * safeT + normal.y * 8 * side
            )
        }

        return candidate
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Helpers

    /// Maps a normalized (0-1) position to pixel coordinates with margins.
    private func mapPoint(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        let margin: CGFloat = 0.08
        let x = (margin + normalized.x * (1 - 2 * margin)) * size.width
        let y = (margin + normalized.y * (1 - 2 * margin)) * size.height
        return CGPoint(x: x, y: y)
    }

    private func scenarioPillFill(_ selected: Bool) -> Color {
        if selected {
            return colorScheme == .dark
                ? Color.accentColor.opacity(0.8) // High contrast
                : Color.accentColor.opacity(0.95)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.055)
    }

    private func scenarioPillStroke(_ selected: Bool) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(selected ? 0.22 : 0.12)
        }
        return Color.black.opacity(0.10)
    }

    private func scenarioPillForeground(_ selected: Bool) -> Color {
        if selected {
            return Color.white // Always white text when selected
        }
        return colorScheme == .dark
            ? Color.secondary
            : Color.primary.opacity(0.78)
    }

    private func advanceScenario(to index: Int? = nil) {
        isAutoPlaying = index == nil
        let next = index ?? (currentScenario + 1) % scenarios.count
        if reduceMotion {
            currentScenario = next
        } else {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                currentScenario = next
            }
        }
    }
}

// MARK: - Animated Line Shape

/// A line shape that smoothly animates between start/end points.
private struct AnimatedLine: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { .init(from.animatableData, to.animatableData) }
        set {
            from.animatableData = newValue.first
            to.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: from)
            p.addLine(to: to)
        }
    }
}

// MARK: - Data Model

enum EmbeddingLabelPlacement: Equatable {
    case left
    case above
    case below
}

struct EmbeddingFoodPoint: Identifiable {
    let id: Int
    let label: String
    let shortLabel: String
    let position: CGPoint
    let similarity: Double
    let isInput: Bool
    let labelPlacement: EmbeddingLabelPlacement
    let labelOffset: CGSize
    let scoreOffset: CGSize

    init(
        id: Int,
        label: String,
        shortLabel: String,
        position: CGPoint,
        similarity: Double,
        isInput: Bool,
        labelPlacement: EmbeddingLabelPlacement = .below,
        labelOffset: CGSize = .zero,
        scoreOffset: CGSize = .zero
    ) {
        self.id = id
        self.label = label
        self.shortLabel = shortLabel
        self.position = position
        self.similarity = similarity
        self.isInput = isInput
        self.labelPlacement = labelPlacement
        self.labelOffset = labelOffset
        self.scoreOffset = scoreOffset
    }
}

struct EmbeddingScenarioData {
    let inputLabel: String
    let foods: [EmbeddingFoodPoint]

    static let all: [EmbeddingScenarioData] = [
        // Scenario 1: Chicken
        // GTE-Large clusters food items tightly -- even dissimilar foods score 0.70+
        EmbeddingScenarioData(
            inputLabel: "Chicken breast",
            foods: [
                EmbeddingFoodPoint(id: 0, label: "Chicken breast, grilled", shortLabel: "Chicken breast", position: CGPoint(x: 0.20, y: 0.48), similarity: 1.0, isInput: true, labelPlacement: .left, labelOffset: CGSize(width: -6, height: -1)),
                EmbeddingFoodPoint(id: 1, label: "Broiled chicken", shortLabel: "Broiled chicken", position: CGPoint(x: 0.33, y: 0.35), similarity: 0.94, isInput: false, labelPlacement: .above, labelOffset: CGSize(width: 8, height: -2), scoreOffset: CGSize(width: -10, height: -14)),
                EmbeddingFoodPoint(id: 2, label: "Roasted chicken breast", shortLabel: "Roasted chicken", position: CGPoint(x: 0.30, y: 0.62), similarity: 0.91, isInput: false, labelOffset: CGSize(width: 10, height: 0), scoreOffset: CGSize(width: -8, height: 10)),
                EmbeddingFoodPoint(id: 3, label: "Chocolate cake", shortLabel: "Chocolate cake", position: CGPoint(x: 0.68, y: 0.26), similarity: 0.74, isInput: false, labelPlacement: .above, labelOffset: CGSize(width: 6, height: -2), scoreOffset: CGSize(width: 8, height: -8)),
                EmbeddingFoodPoint(id: 4, label: "Orange juice", shortLabel: "Orange juice", position: CGPoint(x: 0.72, y: 0.70), similarity: 0.71, isInput: false, scoreOffset: CGSize(width: 8, height: 10)),
            ]
        ),
        // Scenario 2: Milk
        EmbeddingScenarioData(
            inputLabel: "Whole milk",
            foods: [
                EmbeddingFoodPoint(id: 0, label: "Whole milk, 2%", shortLabel: "Whole milk", position: CGPoint(x: 0.20, y: 0.50), similarity: 1.0, isInput: true, labelPlacement: .left, labelOffset: CGSize(width: -6, height: -1)),
                EmbeddingFoodPoint(id: 1, label: "Reduced fat milk", shortLabel: "Reduced fat milk", position: CGPoint(x: 0.34, y: 0.36), similarity: 0.95, isInput: false, labelPlacement: .above, labelOffset: CGSize(width: 12, height: -1), scoreOffset: CGSize(width: -2, height: -8)),
                EmbeddingFoodPoint(id: 2, label: "Lowfat milk", shortLabel: "Lowfat milk", position: CGPoint(x: 0.36, y: 0.62), similarity: 0.92, isInput: false),
                EmbeddingFoodPoint(id: 3, label: "Apple, raw", shortLabel: "Apple", position: CGPoint(x: 0.68, y: 0.30), similarity: 0.76, isInput: false, labelPlacement: .above, labelOffset: CGSize(width: 0, height: -1), scoreOffset: CGSize(width: 10, height: -8)),
                EmbeddingFoodPoint(id: 4, label: "Beef steak", shortLabel: "Beef steak", position: CGPoint(x: 0.72, y: 0.68), similarity: 0.73, isInput: false),
            ]
        ),
        // Scenario 3: Rice
        EmbeddingScenarioData(
            inputLabel: "Brown rice",
            foods: [
                EmbeddingFoodPoint(id: 0, label: "Brown rice, cooked", shortLabel: "Brown rice", position: CGPoint(x: 0.22, y: 0.45), similarity: 1.0, isInput: true, labelPlacement: .left, labelOffset: CGSize(width: -6, height: -1)),
                EmbeddingFoodPoint(id: 1, label: "White rice, steamed", shortLabel: "White rice", position: CGPoint(x: 0.36, y: 0.32), similarity: 0.93, isInput: false, labelPlacement: .above, labelOffset: CGSize(width: 10, height: -1), scoreOffset: CGSize(width: -2, height: -8)),
                EmbeddingFoodPoint(id: 2, label: "Rice flour", shortLabel: "Rice flour", position: CGPoint(x: 0.38, y: 0.58), similarity: 0.88, isInput: false),
                EmbeddingFoodPoint(id: 3, label: "Butter, salted", shortLabel: "Butter", position: CGPoint(x: 0.66, y: 0.24), similarity: 0.72, isInput: false, labelPlacement: .above, labelOffset: CGSize(width: 0, height: -1), scoreOffset: CGSize(width: 8, height: -9)),
                EmbeddingFoodPoint(id: 4, label: "Black coffee", shortLabel: "Black coffee", position: CGPoint(x: 0.70, y: 0.72), similarity: 0.69, isInput: false),
            ]
        ),
    ]
}

// MARK: - Previews

#Preview("Embedding Viz - Light") {
    ScrollView {
        EmbeddingVisualization()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 600)
    .preferredColorScheme(.light)
}

#Preview("Embedding Viz - Dark") {
    ScrollView {
        EmbeddingVisualization()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 600)
    .preferredColorScheme(.dark)
}

#Preview("Embedding Viz - Whole Milk") {
    ScrollView {
        EmbeddingVisualization(initialScenario: 1)
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 600)
    .preferredColorScheme(.light)
}

#Preview("Embedding Viz - Brown Rice") {
    ScrollView {
        EmbeddingVisualization(initialScenario: 2)
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 600)
    .preferredColorScheme(.light)
}
