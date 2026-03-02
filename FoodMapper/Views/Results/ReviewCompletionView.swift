import SwiftUI

/// Shown in the review inspector when all pending items are reviewed.
/// Summary stats + export CTA.
struct ReviewCompletionView: View {
    let totalReviewed: Int
    let onDone: () -> Void
    let onExport: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.green)

            VStack(spacing: Spacing.xs) {
                Text("Review Complete")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("\(totalReviewed) items reviewed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: Spacing.sm) {
                Button {
                    onDone()
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onExport()
                } label: {
                    Label("Export Results", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review complete")
        .accessibilityValue("\(totalReviewed) items reviewed")
    }
}

// MARK: - Previews

#Preview("Review Complete - Light") {
    ReviewCompletionView(totalReviewed: 47, onDone: {}, onExport: {})
        .frame(width: 320, height: 400)
}

#Preview("Review Complete - Dark") {
    ReviewCompletionView(totalReviewed: 47, onDone: {}, onExport: {})
        .frame(width: 320, height: 400)
        .preferredColorScheme(.dark)
}

#Preview("Review Complete - Large Count") {
    ReviewCompletionView(totalReviewed: 2744, onDone: {}, onExport: {})
        .frame(width: 320, height: 400)
        .preferredColorScheme(.dark)
}
