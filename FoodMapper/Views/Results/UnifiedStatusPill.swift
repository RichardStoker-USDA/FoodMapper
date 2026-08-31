import SwiftUI

/// Compact status label for the results table.
struct UnifiedStatusPill: View {
    let category: MatchCategory
    var reviewStatus: ReviewStatus?
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
        case .match, .confirmedMatch: return "checkmark.circle"
        case .needsReview: return "questionmark.circle"
        case .noMatch, .confirmedNoMatch: return "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch category {
        case .match, .confirmedMatch:
            return .green
        case .needsReview:
            return .accentColor
        case .noMatch, .confirmedNoMatch:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let badge = badgeIcon {
                Image(systemName: badge)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Image(systemName: displayIcon)
                .font(.system(size: 11, weight: .semibold))

            Text(displayText)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(statusColor)
        .accessibilityLabel("Status: \(displayText)")
    }

    /// Badge icon for human decisions, nil for auto/unreviewed
    private var badgeIcon: String? {
        guard let status = reviewStatus else { return nil }
        switch status {
        case .accepted, .rejected:
            return "person"
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
