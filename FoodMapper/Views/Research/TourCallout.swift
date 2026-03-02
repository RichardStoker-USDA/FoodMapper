import SwiftUI

// MARK: - Tour Statistic

/// Large number + label for key metrics. Replaces colored .stat callouts.
/// Reference: Apple Health stat cards, Activity rings.
///
/// When `numericValue` is provided, the number counts up from 0 when scrolling
/// into view (via AnimatedCounter). Otherwise displays the value string statically.
struct TourStatistic: View {
    let value: String
    let label: String
    var numericValue: Double? = nil

    var body: some View {
        if let numericValue {
            AnimatedCounter(
                targetValue: value,
                numericValue: numericValue,
                label: label
            )
        } else {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(value)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(label)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Tour Info Line

/// Icon + text inline. Replaces colored .info and .privacy callouts.
/// No background box. Just an SF Symbol and text.
struct TourInfoLine: View {
    let icon: String
    let text: String
    let secondaryText: String?

    init(icon: String, text: String, secondaryText: String? = nil) {
        self.icon = icon
        self.text = text
        self.secondaryText = secondaryText
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: secondaryText != nil ? Spacing.xxs : 0) {
                Text(verbatim: text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let secondaryText {
                    Text(verbatim: secondaryText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tour Insight

/// Blockquote-style emphasis with thin accent-color left bar.
/// Replaces colored .note callouts.
struct TourInsight: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3)

            Text(verbatim: text)
                .font(.body)
                .italic()
                .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.80))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tour Key Fact

/// Container for important callouts that need a visual boundary.
/// Neutral background, no color tint. Use sparingly.
struct TourKeyFact: View {
    let icon: String
    let text: String
    let secondaryText: String?

    init(icon: String, text: String, secondaryText: String? = nil) {
        self.icon = icon
        self.text = text
        self.secondaryText = secondaryText
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: secondaryText != nil ? Spacing.xxs : 0) {
                Text(verbatim: text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let secondaryText {
                    Text(verbatim: secondaryText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .showcaseCard(cornerRadius: 8)
    }
}

// MARK: - Tour Section Header

/// Reusable section header with title and optional subtitle.
struct TourSectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.title.weight(.bold))
                .scrollTransition(
                    .animated(.spring(response: 0.35, dampingFraction: 0.8))
                    .threshold(.visible(0.1))
                ) { view, phase in
                    view
                        .opacity(phase.isIdentity ? 1 : 0)
                        .offset(y: phase.isIdentity ? 0 : 16)
                }

            if let subtitle {
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .scrollTransition(
                        .animated(.spring(response: 0.4, dampingFraction: 0.8))
                        .threshold(.visible(0.12))
                    ) { view, phase in
                        view
                            .opacity(phase.isIdentity ? 1 : 0)
                            .offset(y: phase.isIdentity ? 0 : 12)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tour Technical Detail

/// Expandable section for technical content. Always present, starts collapsed.
struct TourTechnicalDetail<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded: Bool = false

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content()
                .padding(.top, Spacing.sm)
        } label: {
            Label(title, systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.md)
        .showcaseCard(cornerRadius: 8)
    }
}

#Preview("Statistic") {
    HStack(spacing: Spacing.xxxl) {
        TourStatistic(value: "76.9%", label: "Top-1 accuracy with GTE-Large embeddings")
        TourStatistic(value: "96.4%", label: "Top-5 recall on matchable items")
    }
    .padding(Spacing.xxl)
    .frame(width: 680)
}

#Preview("Info Lines - Light") {
    VStack(spacing: Spacing.md) {
        TourInfoLine(icon: "info.circle", text: "The tour uses the NHANES-to-DFG2 benchmark: 1,304 food descriptions matched to a database of 256 foods.")
        TourInfoLine(icon: "lock.shield", text: "All processing runs locally on your Mac. No data leaves your device.")
        TourInfoLine(icon: "dollarsign.circle", text: "Hybrid Haiku with Batches API: ~$0.72 for 1,304 items.", secondaryText: "About $0.0006 per item.")
    }
    .padding(Spacing.xxl)
    .frame(width: 680)
    .preferredColorScheme(.light)
}

#Preview("Insight + Key Fact - Light") {
    VStack(spacing: Spacing.lg) {
        TourInsight(text: "These methods compare surface-level text. What if we could compare meaning instead?")
        TourKeyFact(icon: "chart.bar.xaxis", text: "On NHANES-to-DFG2, fuzzy matching achieves ~25% accuracy. TF-IDF does better at ~40%.")
    }
    .padding(Spacing.xxl)
    .frame(width: 680)
    .preferredColorScheme(.light)
}

#Preview("Section Header") {
    VStack(spacing: Spacing.xl) {
        TourSectionHeader("The Challenge", subtitle: "Why nutrition researchers need automated food matching")
        TourSectionHeader("Technical Details")
    }
    .padding(Spacing.xxl)
    .frame(width: 680)
    .preferredColorScheme(.light)
}

#Preview("Technical Detail - Light") {
    TourTechnicalDetail(title: "Algorithm Details") {
        Text("Levenshtein distance counts the minimum number of single-character edits needed to transform one string into another.")
            .font(.body)
    }
    .padding(Spacing.xxl)
    .frame(width: 680)
    .preferredColorScheme(.light)
}

#Preview("Components - Dark") {
    VStack(spacing: Spacing.lg) {
        TourStatistic(value: "65.4%", label: "Overall hybrid accuracy")
        TourInfoLine(icon: "info.circle", text: "The hybrid approach combines embedding retrieval with LLM verification.")
        TourInsight(text: "No single model is best at everything.")
        TourKeyFact(icon: "lock.shield", text: "Your API key is stored locally only.")
        TourTechnicalDetail(title: "Implementation") {
            Text("Temperature: 0 (deterministic)")
                .font(.body)
        }
    }
    .padding(Spacing.xxl)
    .frame(width: 680)
    .preferredColorScheme(.dark)
}
