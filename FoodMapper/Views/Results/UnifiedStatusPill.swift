import SwiftUI

/// Single unified status pill for the results table.
/// Displays 3 outcome labels: Match, Needs Review, No Match.
/// ConfirmedMatch displays as "Match", confirmedNoMatch as "No Match" (display-layer only).
/// Optional who-decided badge shows when a human has acted on the row.
struct UnifiedStatusPill: View {
    let category: MatchCategory
    var reviewStatus: ReviewStatus?
    @Environment(\.colorScheme) private var colorScheme

    // Display mapping: collapse 5 categories into 3 outcomes
    private var displayText: String {
        switch category {
        case .match, .confirmedMatch: return "Match"
        case .needsReview: return "Needs Review"
        case .noMatch, .confirmedNoMatch: return "No Match"
        }
    }

    private var displayIcon: String {
        switch category {
        case .match, .confirmedMatch: return "checkmark.circle.fill"
        case .needsReview: return "questionmark.circle"
        case .noMatch, .confirmedNoMatch: return "xmark.circle"
        }
    }

    private var pillBackground: Color {
        switch category {
        case .match, .confirmedMatch:
            return colorScheme == .dark ? Color.green.opacity(0.85) : Color.green
        case .needsReview:
            return colorScheme == .dark ? Color.accentColor.opacity(0.85) : Color.accentColor
        case .noMatch, .confirmedNoMatch:
            return colorScheme == .dark ? Color.gray.opacity(0.65) : Color.gray.opacity(0.75)
        }
    }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            // Who-decided badge (left of pill)
            if let badge = badgeIcon {
                Image(systemName: badge)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Status pill
            HStack(spacing: Spacing.xxs) {
                Image(systemName: displayIcon)
                    .font(.system(size: 11, weight: .semibold))

                Text(displayText)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxxs)
            .background(pillBackground)
            .clipShape(Capsule())
        }
        .accessibilityLabel("Status: \(displayText)")
    }

    /// Badge icon for human decisions, nil for auto/unreviewed
    private var badgeIcon: String? {
        guard let status = reviewStatus else { return nil }
        switch status {
        case .accepted, .rejected:
            return "person.fill"
        case .overridden:
            return "arrow.triangle.swap"
        default:
            return nil
        }
    }
}

// MARK: - Previews

#Preview("Status Pills - 3 Outcomes - Light") {
    VStack(spacing: Spacing.sm) {
        HStack {
            UnifiedStatusPill(category: .match)
            Spacer()
            Text("Auto match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            UnifiedStatusPill(category: .needsReview)
            Spacer()
            Text("Needs review")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            UnifiedStatusPill(category: .noMatch)
            Spacer()
            Text("No match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Divider()
        HStack {
            UnifiedStatusPill(category: .confirmedMatch, reviewStatus: .accepted)
            Spacer()
            Text("Human accepted -> Match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            UnifiedStatusPill(category: .confirmedNoMatch, reviewStatus: .rejected)
            Spacer()
            Text("Human rejected -> No Match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            UnifiedStatusPill(category: .confirmedMatch, reviewStatus: .overridden)
            Spacer()
            Text("Human overrode -> Match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
    .frame(width: 320)
}

#Preview("Status Pills - 3 Outcomes - Dark") {
    VStack(spacing: Spacing.sm) {
        HStack {
            UnifiedStatusPill(category: .match)
            Spacer()
            Text("Auto match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            UnifiedStatusPill(category: .needsReview)
            Spacer()
            Text("Needs review")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            UnifiedStatusPill(category: .noMatch)
            Spacer()
            Text("No match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Divider()
        HStack {
            UnifiedStatusPill(category: .confirmedMatch, reviewStatus: .accepted)
            Spacer()
            Text("Human accepted -> Match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            UnifiedStatusPill(category: .confirmedNoMatch, reviewStatus: .rejected)
            Spacer()
            Text("Human rejected -> No Match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            UnifiedStatusPill(category: .confirmedMatch, reviewStatus: .overridden)
            Spacer()
            Text("Human overrode -> Match")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
    .frame(width: 320)
    .preferredColorScheme(.dark)
}
