import SwiftUI

/// Section 4: How It Works (Stage 1) -- semantic embedding candidate search.
/// Stage 2 (LLM selection) lives in LLMStageSection below.
struct PipelineSection: View {
    var onScrollToNext: (() -> Void)? = nil

    @State private var visiblePillCount: Int = 0
    @State private var showPulse = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            TourSectionHeader(
                "How It Works",
                subtitle: "Combining semantic search with LLM judgment"
            )

            Text("The best-performing approach uses two stages: semantic embedding finds the closest candidates, then an LLM evaluates whether any are a true match.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .scrollReveal()

            // Pipeline diagram -- has own PipelineRevealTrigger, no .scrollReveal()
            pipelineDiagram

            // Stage 1: Semantic Embedding
            stage1Content
                .scrollReveal()

            if let onScrollToNext {
                HStack {
                    Spacer()
                    SectionChevronButton { onScrollToNext() }
                    Spacer()
                }
                .padding(.top, 57)
            }
        }
    }

    // MARK: - Stage 1: Semantic Embedding

    private var stage1Content: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ShowcaseSectionBreak(number: 1, title: "Semantic Candidate Search", icon: "cpu")

            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("GTE-Large encodes both the input descriptions and target-database entries into 1,024-dimensional vectors in the same semantic space. The pipeline computes cosine similarity and ranks the nearest meanings as top candidates, even when phrasing differs. This stage narrows a large database down to the most relevant options for final review.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.84))
                    .fixedSize(horizontal: false, vertical: true)

                EmbeddingVisualization()

                Text("Embedding retrieval surfaces the most similar candidates, but it can't determine when no match exists in the database.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.lg)
            .showcaseCard(cornerRadius: 10)
        }
    }

    // MARK: - Pipeline Diagram (5-pill)

    private var pipelineDiagram: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.xs) {
                pipelinePill(label: "1,304 inputs", icon: "doc.text", index: 1)
                pipelineArrow(afterIndex: 1)
                pipelinePill(label: "GTE-Large", icon: "cpu", index: 2)
                pipelineArrow(afterIndex: 2)
                pipelinePill(label: "Top-5", icon: "list.number", index: 3)
                pipelineArrow(afterIndex: 3)
                pipelinePill(label: "Claude Haiku", icon: "cloud", index: 4)
                pipelineArrow(afterIndex: 4)
                pipelinePill(label: "Result", icon: "checkmark.circle", index: 5)
            }
            .frame(maxWidth: .infinity)
            .overlay {
                if showPulse {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 80)
                            .blur(radius: 16)
                            .offset(x: showPulse ? geo.size.width : -80)
                            .animation(.easeInOut(duration: 2.8), value: showPulse)
                    }
                    .allowsHitTesting(false)
                    .clipped()
                }
            }
            .modifier(PipelineRevealTrigger(
                visiblePillCount: $visiblePillCount,
                showPulse: $showPulse,
                reduceMotion: reduceMotion,
                totalPills: 5
            ))
        }
        .padding(Spacing.lg)
        .showcaseCard(cornerRadius: 8)
    }

    private func pipelinePill(label: String, icon: String, index: Int) -> some View {
        PipelinePillView(label: label, icon: icon)
            .opacity(visiblePillCount >= index ? 1 : 0)
            .offset(x: visiblePillCount >= index ? 0 : -16)
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: visiblePillCount)
    }

    private func pipelineArrow(afterIndex: Int) -> some View {
        Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .opacity(visiblePillCount > afterIndex ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: visiblePillCount)
    }
}

// MARK: - LLM Stage Section

/// Section 5: LLM Match Selection (Stage 2) -- how Claude reviews candidates
/// and selects the best match or rejects all. Includes interactive walkthrough examples.
struct LLMStageSection: View {
    var onScrollToNext: (() -> Void)? = nil

    @State private var selectedExample: HybridExampleId = .chorizo
    @State private var isExampleAutoPlaying = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        initialExample: HybridExampleId = .chorizo,
        autoPlayExamples: Bool = true,
        onScrollToNext: (() -> Void)? = nil
    ) {
        _selectedExample = State(initialValue: initialExample)
        _isExampleAutoPlaying = State(initialValue: autoPlayExamples)
        self.onScrollToNext = onScrollToNext
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxl) {
            stage2Content
                .scrollReveal()

            if let onScrollToNext {
                HStack {
                    Spacer()
                    SectionChevronButton { onScrollToNext() }
                    Spacer()
                }
                .padding(.top, -8)
            }
        }
        .task(id: isExampleAutoPlaying) {
            guard isExampleAutoPlaying, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                advanceExample()
            }
        }
    }

    // MARK: - Stage 2: LLM Match Selection

    private var stage2Content: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ShowcaseSectionBreak(number: 2, title: "LLM Match Selection", icon: "cloud")

            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("Claude reviews each set of top-5 candidates against the original food description, applying nutrition domain knowledge to select the best match or reject all candidates if none fit.")
                    .font(.body)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.72 : 0.84))
                    .fixedSize(horizontal: false, vertical: true)

                matchingCriteriaSection

                // Example picker
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Divider()
                        .padding(.vertical, Spacing.xs)

                    Text("See how it works with real examples from the paper:")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: Spacing.sm) {
                        ForEach(HybridExampleId.allCases) { example in
                            let isSelected = selectedExample == example
                            Button {
                                advanceExample(to: example)
                            } label: {
                                Text(example.label)
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, Spacing.xs)
                                    .background(
                                        Capsule().fill(walkthroughPillFill(isSelected))
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(walkthroughPillStroke(isSelected), lineWidth: 0.66)
                                    )
                                    .foregroundStyle(walkthroughPillForeground(isSelected))
                                    .shadow(
                                        color: isSelected && colorScheme == .light ? Color.black.opacity(0.08) : Color.clear,
                                        radius: isSelected ? 3 : 0,
                                        y: isSelected ? 1 : 0
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    exampleWalkthrough(for: HybridExample.all[selectedExample]!)
                        .animation(Animate.smooth, value: selectedExample)
                }

            }
            .padding(Spacing.lg)
            .showcaseCard(cornerRadius: 10)
        }
    }

    // MARK: - Matching Criteria (2x2 layout)

    private var matchingCriteriaSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Claude evaluates each candidate against four criteria:")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    criterionRow(icon: "leaf", text: "Same animal or plant source")
                    criterionRow(icon: "chart.bar", text: "Nutritional profile similarity")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    criterionRow(icon: "flame", text: "Same preparation method")
                    criterionRow(icon: "textformat.abc", text: "Semantic/name similarity")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)
        }
    }

    private func criterionRow(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.9))
                .lineLimit(1)
        }
    }

    // MARK: - Walkthrough Examples

    private func exampleWalkthrough(for example: HybridExample) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // NHANES Input
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("NHANES Input")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(example.inputDescription)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }

            stageDivider(icon: "cpu", label: "Stage 1: Embedding Candidates")

            candidateList(for: example)

            stageDivider(icon: "cloud", label: "Stage 2: LLM Match Selection")

            decisionView(for: example)

            Text(reasoningHeightTemplate)
                .font(.callout)
                .italic()
                .foregroundStyle(.clear)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    Text("\"\(example.reasoning)\"")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.80))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, Spacing.sm) // Added separation

            Text(annotationHeightTemplate)
                .font(.callout)
                .foregroundStyle(.clear)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    Text(example.annotation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
        }
    }

    private func candidateList(for example: HybridExample) -> some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: Spacing.sm) {
                Text("#")
                    .frame(width: 22, alignment: .trailing)
                Text("Candidate")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Score")
                    .frame(width: 60, alignment: .trailing)
                Color.clear
                    .frame(width: 60)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)

            Divider()

            ForEach(Array(example.candidates.enumerated()), id: \.offset) { index, candidate in
                candidateRow(candidate: candidate, example: example)

                if index < example.candidates.count - 1 {
                    Divider()
                        .padding(.horizontal, Spacing.sm)
                }
            }
        }
        .showcaseCard(cornerRadius: 6)
    }

    private func candidateRow(
        candidate: (rank: Int, description: String, score: Double),
        example: HybridExample
    ) -> some View {
        let isSelected = example.claudeSelection != nil &&
            candidate.description.lowercased() == (example.claudeSelection ?? "").lowercased()
        let isGroundTruth = example.groundTruth != nil &&
            candidate.description.lowercased() == (example.groundTruth ?? "").lowercased()
        let barFill: Color = isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.12)

        return HStack(spacing: Spacing.sm) {
            Text("\(candidate.rank).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Group {
                if isGroundTruth && !isSelected {
                    Circle()
                        .fill(.green.opacity(0.6))
                        .frame(width: 6, height: 6)
                } else {
                    Color.clear
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 6, height: 6)

            Text(candidate.description)
                .font(.callout)
                .foregroundStyle(
                    isSelected
                        ? Color.primary
                        : Color.primary.opacity(colorScheme == .dark ? 0.82 : 0.90)
                )
                .lineLimit(1)

            Spacer()

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barFill)
                    .frame(width: geo.size.width * candidate.score)
            }
            .frame(width: 60, height: 4)

            Text("\(Int(candidate.score * 100))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Group {
                if isSelected {
                    Text("Selected")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .polishedBadge(tone: .accentStrong, cornerRadius: 999)
                } else {
                    Color.clear
                        .frame(width: 58, height: 18)
                }
            }
            .frame(width: 58, alignment: .leading)
        }
        .padding(.vertical, Spacing.xxs)
        .padding(.horizontal, Spacing.sm)
        .frame(minHeight: 30, maxHeight: 30)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(isSelected ? 0.06 : 0))
        )
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, Spacing.xxs)
            }
        }
    }

    private var reasoningHeightTemplate: String {
        "\"Black pepper is a dried spice, none of the candidates are spices or seasonings.\""
    }

    private var annotationHeightTemplate: String {
        "Claude correctly identified the fat content difference but was overly strict. The benchmark counts this as a false negative. In practice, this is a conservative miss rather than a semantic retrieval failure."
    }

    private func decisionView(for example: HybridExample) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: example.isCorrect ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(example.isCorrect ? .green : .red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text("Selected:")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text(example.claudeSelection ?? "No match")
                        .font(.body.weight(.medium))
                }
                if let groundTruth = example.groundTruth {
                    HStack(spacing: Spacing.xs) {
                        Text("Ground truth:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(groundTruth)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No match exists in database")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func stageDivider(icon: String, label: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.primary.opacity(0.08))
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.primary.opacity(0.08))
        }
    }

    private func walkthroughPillFill(_ selected: Bool) -> Color {
        if selected {
            return colorScheme == .dark
                ? Color.accentColor.opacity(0.8) // High contrast against dark background
                : Color.accentColor.opacity(0.95)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.055)
    }

    private func walkthroughPillStroke(_ selected: Bool) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(selected ? 0.22 : 0.12)
        }
        return Color.black.opacity(0.10)
    }

    private func walkthroughPillForeground(_ selected: Bool) -> Color {
        if selected {
            return Color.white // Always white for selected pills for max contrast
        }
        return colorScheme == .dark
            ? Color.secondary
            : Color.primary.opacity(0.78)
    }

    // MARK: - Example Autoplay

    private func advanceExample(to target: HybridExampleId? = nil) {
        isExampleAutoPlaying = target == nil

        let all = HybridExampleId.allCases
        let next = target ?? {
            guard let current = all.firstIndex(of: selectedExample) else {
                return all.first ?? .chorizo
            }
            return all[(current + 1) % all.count]
        }()

        if reduceMotion {
            selectedExample = next
        } else {
            withAnimation(Animate.standard) {
                selectedExample = next
            }
        }
    }
}

// MARK: - Pipeline Reveal Animation

/// Reveals pipeline pills sequentially left-to-right when scrolled into view.
private struct PipelineRevealTrigger: ViewModifier {
    @Binding var visiblePillCount: Int
    @Binding var showPulse: Bool
    let reduceMotion: Bool
    var totalPills: Int = 5

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .onScrollVisibilityChange(threshold: 0.3) { visible in
                    if visible && visiblePillCount == 0 {
                        triggerSequence()
                    }
                }
        } else {
            content
                .onAppear {
                    if visiblePillCount == 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            triggerSequence()
                        }
                    }
                }
        }
    }

    private func triggerSequence() {
        guard !reduceMotion else {
            visiblePillCount = totalPills
            return
        }

        for i in 1...totalPills {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 * Double(i)) {
                withAnimation {
                    visiblePillCount = i
                }
            }
        }

        // Pulse sweep after all pills are visible
        let pulseDelay = 0.45 * Double(totalPills) + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + pulseDelay) {
            withAnimation {
                showPulse = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation {
                    showPulse = false
                }
            }
        }
    }
}

// MARK: - Walkthrough Example Types

enum HybridExampleId: String, CaseIterable, Identifiable {
    case chorizo, pepper, cheese, milk
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chorizo: return "Chorizo"
        case .pepper: return "Pepper"
        case .cheese: return "Cheese"
        case .milk: return "Milk"
        }
    }
}

struct HybridExample {
    let id: HybridExampleId
    let inputDescription: String
    let groundTruth: String?
    let candidates: [(rank: Int, description: String, score: Double)]
    let claudeSelection: String?
    let isCorrect: Bool
    let reasoning: String
    let annotation: String

    static let all: [HybridExampleId: HybridExample] = [
        .chorizo: HybridExample(
            id: .chorizo,
            inputDescription: "Sausage, pork, chorizo, link or ground, cooked, pan-fried",
            groundTruth: "ground pork",
            candidates: [
                (rank: 1, description: "ground pork", score: 0.84),
                (rank: 2, description: "Pork tenderloin", score: 0.79),
                (rank: 3, description: "ground beef", score: 0.75),
                (rank: 4, description: "Bacon", score: 0.68),
                (rank: 5, description: "Whole chicken", score: 0.52),
            ],
            claudeSelection: "ground pork",
            isCorrect: true,
            reasoning: "Chorizo sausage is made from ground pork, direct ingredient match.",
            annotation: "The embedding surfaces pork products by similarity. Claude understands that chorizo is made from ground pork and selects the correct match despite different food names."
        ),
        .pepper: HybridExample(
            id: .pepper,
            inputDescription: "Spices, pepper, black",
            groundTruth: nil,
            candidates: [
                (rank: 1, description: "Whole green bell pepper", score: 0.71),
                (rank: 2, description: "Red bell pepper", score: 0.65),
                (rank: 3, description: "Jalapeno pepper", score: 0.58),
                (rank: 4, description: "Ground ginger", score: 0.45),
                (rank: 5, description: "Garlic cloves", score: 0.42),
            ],
            claudeSelection: nil,
            isCorrect: true,
            reasoning: "Black pepper is a dried spice, none of the candidates are spices or seasonings.",
            annotation: "The word 'pepper' leads the embedding to surface bell peppers and jalapenos. Claude recognizes that black pepper is a dried spice (Piper nigrum), not a vegetable, and correctly rejects all candidates."
        ),
        .cheese: HybridExample(
            id: .cheese,
            inputDescription: "Cheese, monterey",
            groundTruth: "American cheese",
            candidates: [
                (rank: 1, description: "Cheddar cheese", score: 0.88),
                (rank: 2, description: "American cheese", score: 0.85),
                (rank: 3, description: "Mozzarella cheese", score: 0.82),
                (rank: 4, description: "Cream cheese", score: 0.71),
                (rank: 5, description: "Parmesan cheese", score: 0.68),
            ],
            claudeSelection: "American cheese",
            isCorrect: true,
            reasoning: "Monterey Jack and American are both mild, semi-soft cheeses.",
            annotation: "Five cheeses score highly in embedding similarity. Claude selects American cheese over the higher-scoring cheddar based on nutritional profile similarity, matching the ground truth."
        ),
        .milk: HybridExample(
            id: .milk,
            inputDescription: "Milk, reduced fat, fluid, 2% milkfat, with added vitamin A and vitamin D",
            groundTruth: "Whole milk",
            candidates: [
                (rank: 1, description: "Whole milk", score: 0.88),
                (rank: 2, description: "Almond milk", score: 0.65),
                (rank: 3, description: "Heavy cream", score: 0.61),
                (rank: 4, description: "Sour cream", score: 0.48),
                (rank: 5, description: "Unsalted butter", score: 0.40),
            ],
            claudeSelection: nil,
            isCorrect: false,
            reasoning: "2% reduced fat milk differs significantly from whole milk in fat content.",
            annotation: "Claude correctly identified the fat content difference but was overly strict. The benchmark counts this as a false negative. In practice, this is a conservative miss rather than a semantic retrieval failure."
        ),
    ]
}

// MARK: - PipelineSection Previews

#Preview("Pipeline Stage 1 - Light") {
    ScrollView {
        PipelineSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 700)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.light)
}

#Preview("Pipeline Stage 1 - Dark") {
    ScrollView {
        PipelineSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 700)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}

// MARK: - LLMStageSection Previews

#Preview("LLM Stage - Light") {
    ScrollView {
        LLMStageSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 900)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.light)
}

#Preview("LLM Stage - Dark") {
    ScrollView {
        LLMStageSection()
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 900)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}

#Preview("LLM Stage - Chorizo Static") {
    ScrollView {
        LLMStageSection(initialExample: .chorizo, autoPlayExamples: false)
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 900)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}

#Preview("LLM Stage - Milk Static") {
    ScrollView {
        LLMStageSection(initialExample: .milk, autoPlayExamples: false)
            .frame(maxWidth: 760)
            .padding(Spacing.xxl)
    }
    .frame(width: 900, height: 900)
    .environmentObject(PreviewHelpers.emptyState())
    .preferredColorScheme(.dark)
}
