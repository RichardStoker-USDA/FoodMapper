import SwiftUI

/// Section 1: Hero area with paper title, authors, positioning, and CTAs.
/// Full-viewport height with parallax text, fade+scale title entrance,
/// living MeshGradient background, and scroll-driven chevron fade.
struct HeroSection: View {
    let scrollProxy: ScrollViewProxy
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var revealProgress: Double = 0
    @State private var hasAppeared = false

    // DOI pending publication
    private let paperURL: URL? = nil

    var body: some View {
        VStack(spacing: Spacing.xxl) {
            Spacer()

            // Paper title with text reveal and parallax
            heroTitleGroup

            Spacer()
                .frame(height: Spacing.sm)

            // Authors and institution -- staggered entrance
            VStack(spacing: Spacing.xs) {
                Text("Lemay, Strohmeier, Stoker, Larke, Wilson")
                    .font(.body.weight(.medium))
                    .foregroundStyle(heroSecondaryTextColor)
                    .opacity(revealProgress > 0.55 ? 1 : 0)
                    .offset(y: revealProgress > 0.55 ? 0 : 15)
                    .animation(.easeOut(duration: 0.5), value: revealProgress > 0.55)

                Text("USDA Agricultural Research Service")
                    .font(.callout)
                    .foregroundStyle(heroSecondaryTextColor)
                    .opacity(revealProgress > 0.6 ? 1 : 0)
                    .offset(y: revealProgress > 0.6 ? 0 : 15)
                    .animation(.easeOut(duration: 0.5), value: revealProgress > 0.6)

                Text("Western Human Nutrition Research Center")
                    .font(.callout)
                    .foregroundStyle(heroSecondaryTextColor)
                    .opacity(revealProgress > 0.65 ? 1 : 0)
                    .offset(y: revealProgress > 0.65 ? 0 : 15)
                    .animation(.easeOut(duration: 0.5), value: revealProgress > 0.65)
            }

            Spacer()
                .frame(height: Spacing.sm)

            // Positioning
            Text("The paper tested five categories of food-database matching, from edit-distance to LLM-powered hybrid pipelines, on 1,304 NHANES dietary recalls against a 256-food target database. Scroll through the methods, see how they compare, and run the pipeline yourself, right on your Mac.")
                .font(.body)
                .foregroundStyle(heroBodyTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .opacity(revealProgress > 0.7 ? 1 : 0)
                .offset(y: revealProgress > 0.7 ? 0 : 20)
                .animation(.easeOut(duration: 0.6), value: revealProgress > 0.7)

            Spacer()
                .frame(height: Spacing.md)

            // CTAs -- bounce entrance
            HStack(spacing: Spacing.lg) {
                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        scrollProxy.scrollTo("challenge", anchor: .top)
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "arrow.down.circle")
                        Text("Explore Methods")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    if let url = paperURL { openURL(url) }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "doc.text")
                        Text("Read the Paper")
                    }
                    .frame(minWidth: 160)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(paperURL == nil)
                .help(paperURL == nil ? "DOI pending publication" : "Open paper in browser")
            }
            .opacity(revealProgress > 0.8 ? 1 : 0)
            .scaleEffect(revealProgress > 0.8 ? 1 : 0.9)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: revealProgress > 0.8)

            if paperURL == nil {
                Text("DOI pending publication")
                    .font(.caption)
                    .foregroundStyle(doiTextColor)
            }

            Spacer()

            // Scroll indicator -- gentle bounce + fades out on scroll
            chevronIndicator

            Spacer()
                .frame(height: Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            if reduceMotion {
                revealProgress = 1.0
            } else {
                withAnimation(.spring(duration: 1.6, bounce: 0)) {
                    revealProgress = 1.0
                }
            }
        }
    }

    // MARK: - Hero Title Group

    private var heroTitleGroup: some View {
        Text("Evaluation of Large Language Models for Mapping Dietary Data to Food Databases")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 680)
            .opacity(revealProgress > 0.1 ? 1 : 0)
            .scaleEffect(revealProgress > 0.1 ? 1.0 : 0.92)
            .animation(.spring(response: 0.8, dampingFraction: 0.85), value: revealProgress > 0.1)
            .visualEffect { content, proxy in
                content.offset(y: reduceMotion ? 0 : parallaxOffset(proxy: proxy, rate: 0.15))
            }
    }

    // MARK: - Chevron Indicator

    private var chevronIndicator: some View {
        SectionChevronButton {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                scrollProxy.scrollTo("challenge", anchor: .top)
            }
        }
        .scrollTransition(
            .animated(.spring(response: 0.3, dampingFraction: 0.8))
            .threshold(.visible(0.9))
        ) { view, phase in
            view.opacity(phase.isIdentity ? 0.6 : 0)
        }
    }

    /// Calculate parallax offset based on scroll position.
    private func parallaxOffset(proxy: GeometryProxy, rate: CGFloat) -> CGFloat {
        let midY = proxy.frame(in: .global).midY
        let screenMidY = proxy.size.height / 2
        return (midY - screenMidY) * rate
    }

    private var heroSecondaryTextColor: Color {
        colorScheme == .dark
            ? .secondary
            : Color.primary.opacity(0.76)
    }

    private var heroBodyTextColor: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.72)
            : Color.primary.opacity(0.90)
    }

    private var doiTextColor: Color {
        colorScheme == .dark
            ? Color.secondary.opacity(0.58)
            : Color.primary.opacity(0.56)
    }

}


// MARK: - Previews

#Preview("Hero - Light") {
    ScrollViewReader { proxy in
        ScrollView {
            HeroSection(scrollProxy: proxy)
                .frame(maxWidth: 760)
                .padding(.horizontal, Spacing.xxxl)
                .containerRelativeFrame(.vertical)
        }
    }
    .frame(width: 900, height: 700)
    .preferredColorScheme(.light)
}

#Preview("Hero - Dark") {
    ScrollViewReader { proxy in
        ScrollView {
            HeroSection(scrollProxy: proxy)
                .frame(maxWidth: 760)
                .padding(.horizontal, Spacing.xxxl)
                .containerRelativeFrame(.vertical)
        }
    }
    .frame(width: 900, height: 700)
    .preferredColorScheme(.dark)
}
