import SwiftUI

/// Section 2: The Challenge -- why automated food matching matters.
/// Shows dataset scale with animated counting, example matches, and benchmark details.
struct ChallengeSection: View {
    var onScrollToNext: (() -> Void)? = nil

    @State private var paperStats: TourPaperStats?
    @State private var loadError: String?
    @State private var inputCount: Double = 0
    @State private var targetCount: Double = 0
    @State private var hasAnimated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            TourSectionHeader(
                "The Challenge",
                subtitle: "Why nutrition researchers need automated food matching"
            )

            // Scale visualization with animated counting
            scaleVisualization

            Text("Diet studies collect food descriptions through surveys like NHANES (National Health and Nutrition Examination Survey), dietary recalls, and food frequency questionnaires. Each description must be matched to a standardized database entry before any nutrient analysis can begin. Doing this by hand can take 28 minutes per food item for a single nutrient, and scales dramatically when mapping across entire food composition databases.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            // Example cards
            exampleCards

            // No-match fact -- placed after examples for narrative flow
            TourKeyFact(
                icon: "xmark.circle",
                text: "46.9% of NHANES descriptions have no valid match in DFG2.",
                secondaryText: "Real-world databases rarely cover every food. A matching system must handle \"no match\" gracefully rather than forcing a bad result."
            )

            // Benchmark details
            TourTechnicalDetail(title: "About the Benchmark Datasets") {
                benchmarkDetails
            }

            if let onScrollToNext {
                HStack {
                    Spacer()
                    SectionChevronButton { onScrollToNext() }
                    Spacer()
                }
                .padding(.top, Spacing.md)
            }
        }
        .task {
            await loadData()
        }
    }

    // MARK: - Scale Visualization

    private var scaleVisualization: some View {
        HStack(spacing: Spacing.xl) {
            scaleCard(
                displayedValue: inputCount,
                useComma: true,
                label: "food descriptions",
                sublabel: "NHANES dietary recall",
                icon: "doc.text"
            )

            VStack(spacing: Spacing.xxs) {
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("match to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            scaleCard(
                displayedValue: targetCount,
                useComma: false,
                label: "database entries",
                sublabel: "DFG2 (Davis Food Glycopedia 2.0)",
                icon: "tray.full"
            )
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.lg)
        .showcaseCard()
        .modifier(ScaleCounterTrigger(
            hasAnimated: $hasAnimated,
            inputCount: $inputCount,
            targetCount: $targetCount,
            reduceMotion: reduceMotion
        ))
    }

    private func scaleCard(
        displayedValue: Double,
        useComma: Bool,
        label: String,
        sublabel: String,
        icon: String
    ) -> some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(formattedScaleValue(displayedValue, useComma: useComma))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .contentTransition(.numericText())

            VStack(spacing: Spacing.xxxs) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(sublabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func formattedScaleValue(_ value: Double, useComma: Bool) -> String {
        guard hasAnimated else { return " " }
        if useComma {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: Int(value))) ?? "\(Int(value))"
        }
        return "\(Int(value))"
    }

    // MARK: - Example Cards

    private var exampleCards: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("From the benchmark (Table 2)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(spacing: Spacing.sm) {
                matchExampleRow(
                    input: "Chickpeas (garbanzo beans, bengal gram), mature seeds, raw",
                    output: "Canned garbanzo beans",
                    matched: true
                )

                matchExampleRow(
                    input: "Sausage, pork, chorizo, link or ground, cooked, pan-fried",
                    output: "Ground pork",
                    matched: true
                )

                matchExampleRow(
                    input: "Spices, pepper, black",
                    output: "No match in database",
                    matched: false
                )
            }
        }
        .padding(Spacing.lg)
        .showcaseCard(cornerRadius: 8)
    }

    private func matchExampleRow(input: String, output: String, matched: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            Text(input)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            Image(systemName: "arrow.right")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: Spacing.xs) {
                Image(systemName: matched ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(matched ? .green : .red)

                Text(output)
                    .font(.body)
                    .foregroundStyle(matched ? .primary : .secondary)
                    .italic(!matched)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Benchmark Details

    @ViewBuilder
    private var benchmarkDetails: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let stats = paperStats {
                Text("The NHANES-to-DFG2 benchmark pairs \(stats.datasetStats.nhanesInputCount) NHANES food descriptions against \(stats.datasetStats.dfg2TargetCount) DFG2 target foods. Ground truth was established through expert manual matching, with ~\(String(format: "%.0f%%", stats.datasetStats.matchPercentage)) having a valid match and ~\(String(format: "%.0f%%", stats.datasetStats.noMatchPercentage)) deliberately having no match.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: Spacing.sm)

                Text("The paper also tested a larger benchmark: 1,199 ASA24 (Automated Self-Administered 24-Hour Dietary Assessment Tool) food descriptions against 9,913 FooDB entries. This app includes both DFG2 and FooDB as built-in databases.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: Spacing.sm)

                Text("NHANES: National Health and Nutrition Examination Survey (2003-2018). DFG2: Davis Food Glycopedia 2.0, an encyclopedia of carbohydrate structures (glycans) in commonly consumed foods. ASA24: Automated Self-Administered 24-Hour Dietary Assessment Tool.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Data Loading

    private func loadData() async {
        do {
            paperStats = try await TourDataLoader.shared.loadPaperStats()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Scale Counter Animation Trigger

/// Animates the scale card numbers counting up when scrolled into view.
private struct ScaleCounterTrigger: ViewModifier {
    @Binding var hasAnimated: Bool
    @Binding var inputCount: Double
    @Binding var targetCount: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollVisibilityChange(threshold: 0.3) { visible in
                    if visible && !hasAnimated {
                        triggerAnimation()
                    }
                }
        } else {
            content
                .onAppear {
                    if !hasAnimated {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            triggerAnimation()
                        }
                    }
                }
        }
    }

    private func triggerAnimation() {
        guard !hasAnimated else { return }
        hasAnimated = true

        guard !reduceMotion else {
            inputCount = 1304
            targetCount = 256
            return
        }

        let steps = 30
        let duration = 0.8
        let interval = duration / Double(steps)

        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let eased = 1.0 - pow(1.0 - fraction, 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(step)) {
                withAnimation(.linear(duration: interval)) {
                    inputCount = 1304.0 * eased
                    targetCount = 256.0 * eased
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Challenge - Light") {
    ScrollView {
        ChallengeSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 700)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.light)
}

#Preview("Challenge - Dark") {
    ScrollView {
        ChallengeSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 700)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}
