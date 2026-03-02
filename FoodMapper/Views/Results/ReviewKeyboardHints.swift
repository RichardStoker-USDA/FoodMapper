import SwiftUI

/// Compact keyboard shortcut hint strip for the review inspector.
/// Shows different shortcuts depending on whether Guided Review is active.
struct ReviewKeyboardHints: View {
    let isGuidedReview: Bool

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.md),
        GridItem(.flexible(), spacing: Spacing.md)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if isGuidedReview {
                // Guided Review: structured grid (arrow nav hints removed, functionality still works)
                LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.sm) {
                    keyHint("Reset", key: "R \u{00D7}2")
                    keyHint("Undo", key: "\u{2318}Z")
                    keyHint("Candidate", key: "1-5")
                    keyHint("Exit Review", key: "Esc")
                }
            } else {
                // Normal mode: single row with essential shortcuts
                HStack(spacing: Spacing.xl) {
                    keyHint("Reset", key: "R \u{00D7}2")
                    keyHint("Undo", key: "\u{2318}Z")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isGuidedReview ? "Guided review keyboard shortcuts" : "Review keyboard shortcuts")
    }

    private func keyHint(_ label: String, key: String) -> some View {
        let segments = parseKeySegments(key)

        return HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.xxxs) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    KeyCapView(key: segment)
                }
            }
            .frame(minWidth: 44, alignment: .center)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }
}

/// Keycap label for keyboard shortcuts. Visual reference, not a button.
struct KeyCapView: View {
    let key: String
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.8) : Color.primary.opacity(0.7))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(minWidth: 20)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.1), lineWidth: 1.0)
            )
    }
}

// MARK: - Previews

#Preview("Normal Mode - Light") {
    ReviewKeyboardHints(isGuidedReview: false)
        .padding()
        .frame(width: 320)
        .background(Color.white)
}

#Preview("Normal Mode - Dark") {
    ReviewKeyboardHints(isGuidedReview: false)
        .padding()
        .frame(width: 320)
        .background(Color(white: 0.14))
        .preferredColorScheme(.dark)
}

#Preview("Guided Review - Light") {
    ReviewKeyboardHints(isGuidedReview: true)
        .padding()
        .frame(width: 320)
        .background(Color.white)
}

#Preview("Guided Review - Dark") {
    ReviewKeyboardHints(isGuidedReview: true)
        .padding()
        .frame(width: 320)
        .background(Color(white: 0.14))
        .preferredColorScheme(.dark)
}
