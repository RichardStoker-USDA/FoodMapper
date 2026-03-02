import SwiftUI

/// Threshold slider with visual indicator
struct ThresholdControl: View {
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Header with value
            HStack {
                Text("Match Threshold")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                // Value display with visual indicator
                HStack(spacing: Spacing.xxs) {
                    Circle()
                        .fill(Color.thresholdColor(value))
                        .frame(width: 8, height: 8)

                    Text(value, format: .percent.precision(.fractionLength(0)))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Slider
            Slider(value: $value, in: 0.50...0.99, step: 0.01)
                .accessibilityValue("\(Int(value * 100)) percent")

            // Helper labels
            HStack {
                Text("More results")
                Spacer()
                Text("Higher precision")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
        .help("Minimum similarity score to consider a match. Higher values require closer matches.")
    }
}

#Preview("Threshold - 85% - Light") {
    ThresholdControl(value: .constant(0.85))
        .padding()
        .frame(width: 280)
}

#Preview("Threshold - Dark") {
    ThresholdControl(value: .constant(0.85))
        .padding()
        .frame(width: 280)
        .preferredColorScheme(.dark)
}

#Preview("Threshold - Low (60%)") {
    ThresholdControl(value: .constant(0.60))
        .padding()
        .frame(width: 280)
}

#Preview("Threshold - High (95%)") {
    ThresholdControl(value: .constant(0.95))
        .padding()
        .frame(width: 280)
}
