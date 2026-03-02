import SwiftUI

/// Score display with colored dot and plain percentage text.
/// Dot indicates notable score ranges; text is always default label color.
struct ScoreIndicator: View {
    let score: Double

    var body: some View {
        if score == 0 {
            Text("--")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text("\(Int(score * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
    }

    private var dotColor: Color {
        Color.scoreColor(score)
    }
}

#Preview("Score Cells - Light") {
    VStack(spacing: Spacing.lg) {
        ScoreIndicator(score: 0.95)
        ScoreIndicator(score: 0.87)
        ScoreIndicator(score: 0.75)
        ScoreIndicator(score: 0.60)
        ScoreIndicator(score: 0.0)
    }
    .padding()
    .frame(width: 100)
}

#Preview("Score Cells - Dark") {
    VStack(spacing: Spacing.lg) {
        ScoreIndicator(score: 0.95)
        ScoreIndicator(score: 0.87)
        ScoreIndicator(score: 0.75)
        ScoreIndicator(score: 0.60)
        ScoreIndicator(score: 0.0)
    }
    .padding()
    .frame(width: 100)
    .preferredColorScheme(.dark)
}
