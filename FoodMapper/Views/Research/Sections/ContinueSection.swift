import SwiftUI

/// Section 7: Continue -- CTAs, paper citation, attribution.
struct ContinueSection: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    /// Closure to scroll back to top of the showcase.
    var scrollToTop: (() -> Void)?

    private let paperURL = AppLinks.publication
    private let githubURL = AppLinks.researchRepository

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            // Push content away from the very top
            Spacer(minLength: Spacing.xl)

            // Header + description, centered
            VStack(alignment: .center, spacing: Spacing.md) {
                Text("Continue Exploring")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("The research behind this app studied how LLMs perform at food database mapping. The hybrid embedding + LLM pipeline reached 90.7% accuracy on ASA24-to-FooDB and 65.4% on the harder NHANES-to-DFG2 benchmark. The paper and public repository cover the methods, prompts, and two benchmark datasets.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.84))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)

                Text("FoodMapper supports mapping dietary recall data to reference databases such as USDA FoodData Central, with results available for review before export.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.84))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
            }

            Spacer(minLength: Spacing.xl)
                .frame(maxHeight: Spacing.xxxl)

            // 2x2 action card grid
            actionCardGrid

            // Push attribution to bottom
            Spacer(minLength: Spacing.xl)

            // Attribution
            attributionSection
        }
    }

    // MARK: - Action Card Grid

    private var actionCardGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Spacing.lg),
            GridItem(.flexible(), spacing: Spacing.lg)
        ]

        return LazyVGrid(columns: columns, spacing: Spacing.lg) {
            actionCardView(
                icon: "doc.text",
                title: "Read the Paper",
                subtitle: "Full paper with methodology, benchmark results, and discussion"
            ) {
                openURL(paperURL)
            }
            .scrollRevealStaggered(index: 0)

            actionCardView(
                icon: "sparkle.magnifyingglass",
                title: "Start Matching",
                subtitle: "Match your own data to any reference database"
            ) {
                appState.exitShowcaseToFoodMatching()
            }
            .scrollRevealStaggered(index: 1)

            actionCardView(
                icon: "logo.github",
                isCustomSymbol: true,
                title: "View the Code",
                subtitle: "Scripts and public benchmark datasets on GitHub"
            ) {
                openURL(githubURL)
            }
            .scrollRevealStaggered(index: 2)

            actionCardView(
                icon: "arrow.up",
                title: "Back to Top",
                subtitle: "Return to the beginning of the showcase"
            ) {
                scrollToTop?()
            }
            .scrollRevealStaggered(index: 3)
        }
    }

    private func actionCardView(
        icon: String,
        isCustomSymbol: Bool = false,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: Spacing.md) {
                Group {
                    if isCustomSymbol {
                        Image(icon)
                    } else {
                        Image(systemName: icon)
                    }
                }
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .frame(height: 32)

                VStack(spacing: Spacing.xxs) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xxl)
            .padding(.horizontal, Spacing.lg)
            .contentShape(Rectangle())
            .showcaseCard()
            .showcaseHover()
        }
        .buttonStyle(.plain)
        .help(subtitle)
    }

    // MARK: - Attribution

    private var attributionSection: some View {
        VStack(spacing: Spacing.sm) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, Spacing.xxl)

            VStack(spacing: Spacing.xs) {
                Text("Evaluation of Large Language Models for Mapping Dietary Data to Food Databases")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.82 : 0.90))
                    .multilineTextAlignment(.center)

                Spacer()
                    .frame(height: Spacing.xxs)

                Text("Danielle G. Lemay, Michael P. Strohmeier, Richard B. Stoker, Jules A. Larke, Stephanie M.G. Wilson")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("USDA ARS, Western Human Nutrition Research Center")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
                    .frame(height: Spacing.xs)

                Link("J Nutr. 2026 Aug;156(8):101678", destination: paperURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link(destination: githubURL) {
                    HStack(spacing: Spacing.xxs) {
                        Image("logo.github")
                            .imageScale(.small)
                        Text("GitHub")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.md)
        }
    }
}

// MARK: - Previews

#Preview("Continue - Light") {
    ScrollViewReader { _ in
        ScrollView {
            ContinueSection(scrollToTop: {})
                .frame(maxWidth: 760)
                .padding(.horizontal, Spacing.xxxl)
                .padding(.vertical, Spacing.xxxl)
                .frame(maxWidth: .infinity)
        }
        .containerRelativeFrame(.vertical)
    }
    .frame(width: 1100, height: 740)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.light)
}

#Preview("Continue - Dark") {
    ScrollViewReader { _ in
        ScrollView {
            ContinueSection(scrollToTop: {})
                .frame(maxWidth: 760)
                .padding(.horizontal, Spacing.xxxl)
                .padding(.vertical, Spacing.xxxl)
                .frame(maxWidth: .infinity)
        }
        .containerRelativeFrame(.vertical)
    }
    .frame(width: 1100, height: 740)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}
