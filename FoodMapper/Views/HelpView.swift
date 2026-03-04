import SwiftUI

/// In-app help and documentation view with premium card-based design.
/// Uses the same design patterns as the Behind the Research showcase.
struct HelpView: View {
    @State private var selectedSection: HelpSection? = .gettingStarted
    @Environment(\.colorScheme) private var colorScheme

    // Navigation history (plain @State, NOT @Published -- per freeze lesson)
    @State private var history: [HelpSection] = [.gettingStarted]
    @State private var historyIndex: Int = 0
    @State private var isProgrammaticNav = false

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    var body: some View {
        NavigationSplitView {
            helpSidebar
        } detail: {
            helpDetail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 0) {
                    Button {
                        goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(!canGoBack)
                    .help("Previous topic")

                    Divider()
                        .frame(height: 16)

                    Button {
                        goForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.forward")
                    }
                    .disabled(!canGoForward)
                    .help("Next topic")
                }
            }
        }
        .onChange(of: selectedSection) { _, newValue in
            guard !isProgrammaticNav, let section = newValue else { return }
            if historyIndex < history.count - 1 {
                history = Array(history.prefix(historyIndex + 1))
            }
            history.append(section)
            if history.count > 20 {
                history.removeFirst()
            } else {
                historyIndex = history.count - 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { notification in
            guard let rawValue = notification.object as? String,
                  let section = HelpSection(rawValue: rawValue) else { return }
            selectedSection = section
        }
    }

    // MARK: - Sidebar

    private var helpSidebar: some View {
        List(selection: $selectedSection) {
            ForEach(HelpSidebarGroup.allCases, id: \.self) { group in
                Section {
                    ForEach(group.sections) { section in
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: section.icon)
                                .font(.callout)
                                .foregroundStyle(selectedSection == section ? Color.accentColor : .secondary)
                                .frame(width: 20)
                            Text(section.title)
                        }
                        .tag(section)
                    }
                } header: {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        .navigationTitle("Help")
    }

    // MARK: - Detail

    private var helpDetail: some View {
        Group {
            if let section = selectedSection {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xxl) {
                        section.content
                    }
                    .padding(Spacing.xxl)
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                Text("Select a topic from the sidebar")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 530, minHeight: 520)
        .background {
            if colorScheme == .light {
                LinearGradient(
                    colors: [Color.white, Color.white, Color.accentColor.opacity(0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    // MARK: - Navigation

    private func goBack() {
        guard canGoBack else { return }
        isProgrammaticNav = true
        historyIndex -= 1
        selectedSection = history[historyIndex]
        isProgrammaticNav = false
    }

    private func goForward() {
        guard canGoForward else { return }
        isProgrammaticNav = true
        historyIndex += 1
        selectedSection = history[historyIndex]
        isProgrammaticNav = false
    }
}

// MARK: - Help Sections

enum HelpSection: String, CaseIterable, Identifiable {
    case gettingStarted
    case howItWorks
    case pipelineModes
    case reviewWorkflow
    case understandingScores
    case exporting
    case customDatabases
    case sessions
    case settings
    case experimentalFeatures
    case underTheHood
    case research
    case keyboardShortcuts
    case troubleshooting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .howItWorks: return "How It Works"
        case .pipelineModes: return "Pipeline Modes"
        case .reviewWorkflow: return "Review Workflow"
        case .understandingScores: return "Understanding Scores"
        case .exporting: return "Exporting Results"
        case .customDatabases: return "Custom Databases"
        case .sessions: return "Sessions & History"
        case .settings: return "Settings"
        case .experimentalFeatures: return "Experimental Features"
        case .underTheHood: return "Under the Hood"
        case .research: return "Research"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .troubleshooting: return "Troubleshooting"
        }
    }

    var icon: String {
        switch self {
        case .gettingStarted: return "play.circle"
        case .howItWorks: return "gearshape.2"
        case .pipelineModes: return "arrow.triangle.branch"
        case .reviewWorkflow: return "checkmark.circle"
        case .understandingScores: return "chart.bar"
        case .exporting: return "square.and.arrow.up"
        case .customDatabases: return "cylinder.split.1x2"
        case .sessions: return "clock.arrow.circlepath"
        case .settings: return "slider.horizontal.3"
        case .experimentalFeatures: return "testtube.2"
        case .underTheHood: return "cpu"
        case .research: return "doc.text.magnifyingglass"
        case .keyboardShortcuts: return "keyboard"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }

    /// Which sidebar group this section belongs to
    var group: HelpSidebarGroup {
        switch self {
        case .gettingStarted, .howItWorks: return .basics
        case .pipelineModes, .reviewWorkflow, .understandingScores: return .matching
        case .exporting, .customDatabases, .sessions: return .data
        case .settings, .experimentalFeatures: return .settingsAdvanced
        case .underTheHood, .research, .keyboardShortcuts, .troubleshooting: return .reference
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .gettingStarted: HelpGettingStartedContent()
        case .howItWorks: HelpHowItWorksContent()
        case .pipelineModes: HelpPipelineModesContent()
        case .reviewWorkflow: HelpReviewWorkflowContent()
        case .understandingScores: HelpUnderstandingScoresContent()
        case .exporting: HelpExportingContent()
        case .customDatabases: HelpCustomDatabasesContent()
        case .sessions: HelpSessionsContent()
        case .settings: HelpSettingsContent()
        case .experimentalFeatures: HelpExperimentalFeaturesContent()
        case .underTheHood: HelpUnderTheHoodContent()
        case .research: HelpResearchContent()
        case .keyboardShortcuts: HelpKeyboardShortcutsContent()
        case .troubleshooting: HelpTroubleshootingContent()
        }
    }
}

/// Sidebar groupings for collapsible sections
enum HelpSidebarGroup: String, CaseIterable {
    case basics
    case matching
    case data
    case settingsAdvanced
    case reference

    var title: String {
        switch self {
        case .basics: return "BASICS"
        case .matching: return "MATCHING"
        case .data: return "DATA"
        case .settingsAdvanced: return "SETTINGS & ADVANCED"
        case .reference: return "REFERENCE"
        }
    }

    var sections: [HelpSection] {
        HelpSection.allCases.filter { $0.group == self }
    }
}

// MARK: - Shared Help Components

/// Card container for help content sections
private struct HelpCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            content()
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: colorScheme == .dark ? 0.9 : 0.75)
        )
        .overlay {
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.66)
            }
        }
        .shadow(
            color: colorScheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.10),
            radius: colorScheme == .dark ? 8 : 5,
            y: colorScheme == .dark ? 4 : 2
        )
        .shadow(
            color: colorScheme == .dark ? Color.black.opacity(0.14) : Color.black.opacity(0.04),
            radius: 2,
            y: 1
        )
    }
}

/// Section title for help pages
private struct HelpSectionTitle: View {
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

            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Numbered step with accent circle
private struct HelpStep: View {
    let number: Int
    let title: String
    let description: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(colorScheme == .dark ? .black : .white)
                .frame(width: 22, height: 22)
                .background {
                    Circle()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.9) : Color.accentColor)
                }

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Item with title and body text
private struct HelpItem: View {
    let title: String
    let content: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.body.weight(.medium))
            Text(content)
                .font(.callout)
                .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Blockquote-style hint with thin accent-color left bar.
/// Matches TourInsight from the Behind the Research showcase.
private struct HelpHint: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.6 : 0.5))
                .frame(width: 3)

            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .italic()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Clickable link row
private struct HelpLinkRow: View {
    let title: String
    let url: String
    @State private var isHovered = false

    var body: some View {
        if let linkURL = URL(string: url) {
            Link(destination: linkURL) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.callout)
                    Text(title)
                        .font(.callout)
                }
                .foregroundStyle(Color.accentColor.opacity(isHovered ? 1.0 : 0.8))
            }
            .onHover { hovering in
                withAnimation(Animate.quick) { isHovered = hovering }
            }
        }
    }
}

/// Key-value row for keyboard shortcuts with keycap-styled key labels
private struct HelpShortcutRow: View {
    let action: String
    let keys: String
    let isAlternate: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Split combined keys like "\u{2318}E" into individual keycap segments.
    /// Recognizes modifier symbols, standalone words, and ranges.
    private var keySegments: [String] {
        parseKeySegments(keys)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(action)
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer(minLength: Spacing.lg)

            HStack(spacing: Spacing.xxxs) {
                ForEach(Array(keySegments.enumerated()), id: \.offset) { _, segment in
                    if segment == "+" {
                        Text("+")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        KeyCapView(key: segment)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(
            isAlternate
                ? Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03)
                : Color.clear
        )
    }
}

/// Parse a key string like "\u{2318}\u{21E7}R" or "\u{2318}+Click" into segments for keycaps.
/// Used by HelpShortcutRow and ReviewKeyboardHints for consistent multi-key rendering.
func parseKeySegments(_ keys: String) -> [String] {
    // Known modifier symbols (single Unicode codepoints)
    let modifiers: Set<Character> = [
        "\u{2318}", // Cmd
        "\u{21E7}", // Shift
        "\u{2325}", // Option
        "\u{2303}", // Control
    ]
    // Arrow symbols
    let arrows: Set<Character> = [
        "\u{2190}", // Left
        "\u{2192}", // Right
        "\u{2191}", // Up
        "\u{2193}", // Down
    ]

    // Handle special compound strings
    if keys.contains("+Click") {
        let parts = keys.components(separatedBy: "+Click")
        var segments: [String] = []
        for char in parts[0] {
            if modifiers.contains(char) || arrows.contains(char) {
                segments.append(String(char))
            }
        }
        segments.append("+")
        segments.append("Click")
        return segments
    }

    // Handle "R (press twice)" style
    if keys.contains("(") {
        return [keys]
    }

    // Handle key ranges like "1 - 5"
    if keys.contains(" - ") {
        return [keys]
    }

    // Handle space-separated keys like "\u{2190} \u{2192}" -- just render each as its own keycap
    if keys.contains(" ") && !keys.contains("(") && !keys.contains(" - ") {
        let parts = keys.components(separatedBy: " ").filter { !$0.isEmpty }
        var segments: [String] = []
        for part in parts {
            segments.append(contentsOf: parseKeySegments(part))
        }
        return segments
    }

    var segments: [String] = []
    var remaining = ""

    for char in keys {
        if modifiers.contains(char) || arrows.contains(char) {
            if !remaining.isEmpty {
                segments.append(remaining)
                remaining = ""
            }
            segments.append(String(char))
        } else {
            remaining.append(char)
        }
    }
    if !remaining.isEmpty {
        segments.append(remaining)
    }

    return segments
}

/// Troubleshoot item with warning icon -- uses a color visible in both light and dark mode
private struct HelpTroubleshootItem: View {
    let problem: String
    let solution: String
    @Environment(\.colorScheme) private var colorScheme

    private var cautionColor: Color { .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(cautionColor)
                Text(problem)
                    .font(.body.weight(.medium))
            }
            Text(solution)
                .font(.callout)
                .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                .padding(.leading, Spacing.xxl)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Neutral inline warning with icon. No colored background -- sits inside parent HelpCard.
private struct HelpWarningCard: View {
    let icon: String
    let title: String
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    init(icon: String = "exclamationmark.triangle", title: String = "", text: String) {
        self.icon = icon
        self.title = title
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if !title.isEmpty {
                    Text(title)
                        .font(.callout.weight(.semibold))
                }
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Capsule pill for experimental features. Warm amber to distinguish from stable features.
private struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxxs)
            .background(Color.experimentalAmber.opacity(0.85))
            .clipShape(Capsule())
    }
}

// MARK: - Getting Started

private struct HelpGettingStartedContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Getting Started",
            subtitle: "FoodMapper matches food descriptions in your data to standardized reference databases using semantic similarity. Everything runs on your Mac's GPU."
        )

        // Tutorial card
        HelpCard {
            HStack(spacing: Spacing.md) {
                Image(systemName: "play.circle")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("New to FoodMapper?")
                        .font(.callout.weight(.medium))
                    Text("Walk through the app with sample data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    NotificationCenter.default.post(name: .restartTutorial, object: nil)
                    dismiss()
                } label: {
                    Text("Start Tutorial")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }

        // Steps
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HelpStep(number: 1, title: "Download a model", description: "On first launch, FoodMapper prompts you to download GTE-Large (640 MB). Additional models are available in Settings > Models if you want to use Qwen3 pipelines.")

                HelpStep(number: 2, title: "Load your data", description: "Drop a CSV or TSV file onto the drop zone, or click to browse. The file needs at least one column with food descriptions.")

                HelpStep(number: 3, title: "Select the description column", description: "Pick which column contains the food descriptions you want to match.")

                HelpStep(number: 4, title: "Choose a reference database", description: "FooDB has 9,913 individual food entries. DFG2 has 256 commonly consumed foods from the Davis Food Glycopedia 2.0. You can also add your own.")

                HelpStep(number: 5, title: "Run matching", description: "Click Match in the toolbar. FoodMapper embeds your descriptions and finds the closest match in the reference database for each one.")

                HelpStep(number: 6, title: "Review results", description: "Results are categorized as Match, Needs Review, or No Match. Use the inspector panel to confirm, reject, or override matches.")

                HelpStep(number: 7, title: "Export", description: "Export your results as CSV or TSV with your original data plus match results. All input and target database columns are preserved, with four fm_ columns added for match metadata.")
            }
        }

        HelpHint("The interactive tutorial walks you through all of this with real sample data. You can restart it anytime from Help > Restart Tutorial.")
    }
}

// MARK: - How It Works

private struct HelpHowItWorksContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "How It Works",
            subtitle: "FoodMapper uses embedding models to understand the meaning of food descriptions, not just exact text matches."
        )

        HelpCard {
            HelpItem(title: "Semantic Embeddings", content: "Each food description is converted into a numerical vector (embedding) that captures its meaning. Similar foods have similar embeddings, even if they use different words. \"Grilled chicken breast\" matches \"roasted chicken\" because the model understands they describe similar foods.")
        }

        HelpCard {
            HelpItem(title: "GPU-Accelerated Matching", content: "FoodMapper runs embedding models directly on your Mac's GPU through Apple's MLX framework. Similarity between your inputs and every item in the database is computed as a single matrix multiplication, which is why matching thousands of items takes seconds.")
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Text("Multi-Stage Pipelines")
                        .font(.body.weight(.medium))
                    ExperimentalBadge()
                }

                Text("Beyond basic embedding, FoodMapper supports multi-stage matching. A cross-encoder reranker can rescore the top candidates for higher accuracy. A generative LLM can evaluate candidates and pick the best match. These stages refine the initial embedding results.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                    .fixedSize(horizontal: false, vertical: true)

                HelpWarningCard(text: "Multi-stage pipelines are under active development and require tuning. For scientific research, always review ALL results, including matches and no-matches. False negatives are possible and human review is essential for research-quality data.")
            }
        }

        HelpCard {
            HelpItem(title: "Pipeline-Based Categorization", content: "Results are categorized by the pipeline's decision, not by a fixed score threshold. Embedding-only pipelines mark everything as Needs Review (since cosine similarity ranks but doesn't confirm). Multi-stage pipelines (reranker, LLM, API) make match/no-match decisions, so their results include confirmed Matches. Multi-stage decisions should still be verified for research use.")
        }

        HelpHint("\"Grilled chicken breast\" matches well with \"roasted chicken\" because the model understands semantic meaning. But abbreviations like \"grld chkn brst\" will match poorly -- clean input data matters.")
    }
}

// MARK: - Pipeline Modes

private struct HelpPipelineModesContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Pipeline Modes",
            subtitle: "FoodMapper offers two operating modes. The choice is per-session, not a global toggle."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text("Food Matching (Standard)")
                        .font(.headline)
                }

                Text("Production matching for active research. GTE-Large Embedding is the default pipeline and is production-ready. GTE-Large + Haiku v2 adds Claude API verification and is also validated. Advanced pipelines using Qwen3 models are available but still experimental.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Available Pipelines:")
                        .font(.callout.weight(.medium))
                    pipelineList
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text("Behind the Research (Validation)")
                        .font(.headline)
                }

                Text("Replicates the exact methods from the research paper. Uses GTE-Large embeddings with optional Claude Haiku API verification. Includes a scrolling showcase explaining the paper's approach with interactive visualizations.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("Use this mode when you need results that match the paper's methodology, or to explore how semantic food matching works.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
            }
        }

        // Simple vs Advanced
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Simple vs. Advanced Mode")
                    .font(.headline)

                Text("FoodMapper starts in Simple mode: you see the hybrid matching toggle (embedding only vs. embedding + Claude Haiku) and essential options. These are the default, validated pipelines.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                HStack(alignment: .top, spacing: Spacing.sm) {
                    ExperimentalBadge()
                    Text("Enable Advanced mode in Settings > Advanced to access experimental pipelines, Qwen3 model size selection, instruction presets, and detailed export. These features are under active development and may not produce optimal results yet.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var pipelineList: some View {
        let pipelines: [(String, String)] = [
            ("GTE-Large Embedding", "The paper's embedding model. Symmetric, no instructions. Default pipeline."),
            ("GTE-Large + Haiku v2", "GTE-Large retrieval + Claude Haiku verification with prompt caching. Requires Anthropic API key."),
        ]

        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(pipelines, id: \.0) { name, desc in
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(name)
                        .font(.callout.weight(.medium))
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Additional experimental pipelines (Qwen3-Embedding, Two-Stage, Smart Triage, LLM Judge) are available in Advanced mode. See Experimental Features for details.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, Spacing.xxs)
        }
    }
}

// MARK: - Review Workflow

private struct HelpReviewWorkflowContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Review Workflow",
            subtitle: "After matching completes, review results to confirm, reject, or override matches. This is where you turn automated results into verified data."
        )

        // The completion overlay
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("After Matching")
                    .font(.headline)

                Text("A summary overlay shows match statistics: how many items matched, need review, or had no match. From here you can jump into Guided Review, view all results, or dismiss and browse freely.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("For GTE-Large pipelines, FoodMapper auto-matches high-confidence results where the top score is well above 95% and there's a clear gap to the second candidate. These go directly to Match status instead of Needs Review.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
            }
        }

        // Guided review
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "arrow.right.circle")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                    Text("Guided Review")
                        .font(.headline)
                }

                Text("Guided Review auto-advances to the next Needs Review item after each decision. It filters to show only items that need attention, so you work through them in sequence. The table automatically scrolls to keep the selected item visible, including across page boundaries.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    reviewStepWithKeys("Start:", keys: ["\u{2318}", "\u{21E7}", "R"], suffix: "or toolbar button")
                    reviewStepWithKeys("Navigate:", keys: ["N"], suffix: "next,") {
                        KeyCapView(key: "P")
                        Text("previous, or")
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                        KeyCapView(key: "\u{2190}")
                        KeyCapView(key: "\u{2192}")
                    }
                    reviewStepWithKeys("Decide:", keys: ["Return"], suffix: "match,") {
                        KeyCapView(key: "Delete")
                        Text("reject")
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                    }
                    reviewStepWithKeys("Override:", keys: ["1"], suffix: "-") {
                        KeyCapView(key: "5")
                        Text("or click candidate")
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                    }
                    reviewStepWithKeys("Undo:", keys: ["\u{2318}", "Z"], suffix: "(up to 50 actions)")
                    reviewStepWithKeys("Exit:", keys: ["Esc"], suffix: "or") {
                        KeyCapView(key: "\u{2318}")
                        KeyCapView(key: "\u{21E7}")
                        KeyCapView(key: "R")
                    }
                }
            }
        }

        // Match / No Match actions
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Making Decisions")
                    .font(.headline)

                decisionItem(title: "Match", key: "Return", description: "Confirms the current match is correct. The item's status changes to Match with a person badge indicating human verification. If the item is already accepted or overridden, Return is blocked to prevent accidentally reverting an override. With multiple rows selected, Return applies Match to all selected items.")

                decisionItem(title: "No Match", key: "Delete", description: "Rejects the suggested match. The item is marked No Match with a person badge. Target columns will be empty in the export. With multiple rows selected, Delete applies No Match to all selected items.")

                decisionItem(title: "Override", key: "1-5", description: "Pick a different candidate from the top-N list in the inspector, or click one directly. If you pick the same candidate the pipeline originally chose, it counts as a confirmation (Match), not an override. Otherwise the matched target updates immediately and the item shows a swap badge in the status column.")

                decisionItem(title: "Reset", key: "R \u{00D7}2", description: "Clears the human decision, restoring the item to its pipeline-assigned status. Press R twice within 1.5 seconds to confirm. Also clears any override and note. Works with multi-selection too -- same press-twice confirmation.")
            }
        }

        // Override search
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Override Search")
                    .font(.headline)

                Text("If the right match isn't in the top candidates, open the Manual Override section in the inspector and search across all database entries. Type at least 2 characters to search. Click a result to set it as the match.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("When you override a match, the inspector shows your chosen alternative as the primary display with an updated score. The pipeline's original match appears below as a secondary \"Original:\" pill. Clicking the original pill reverts the override.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
            }
        }

        // Multi-select and bulk
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Multi-Select and Bulk Actions")
                    .font(.headline)

                Text("Select multiple rows with Cmd+Click (toggle individual), Shift+Click (range), or Cmd+A (select all on page). The inspector shows bulk actions: Match All, No Match All, Reset All, and a shared notes field.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("Keyboard shortcuts work with multi-selection too: Return applies Match to all selected, Delete applies No Match to all selected, and R (press twice) resets all selected items.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
            }
        }

        // Notes
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Review Notes")
                    .font(.headline)

                Text("Add a text note to any item for context or explanation. Notes are included in the export as the fm_note column. Useful for flagging items for follow-up or documenting why you overrode a match.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }

        // Undo hint with inline keycap -- thin left bar style
        HStack(spacing: Spacing.sm) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.6 : 0.5))
                .frame(width: 3)

            HStack(spacing: Spacing.xxs) {
                Text("Undo is 50 levels deep (")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
                KeyCapView(key: "\u{2318}")
                KeyCapView(key: "Z")
                Text("). If you accidentally confirm the wrong item, just undo. The undo stack tracks every match, no-match, override, and reset action.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Review step row with inline keycap-styled keys and optional trailing content
    private func reviewStepWithKeys(
        _ label: String,
        keys: [String],
        suffix: String? = nil,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.xxs) {
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 5, height: 5)

            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                .padding(.trailing, Spacing.xxxs)

            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCapView(key: key)
            }

            if let suffix {
                Text(suffix)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }

            trailing()
        }
    }

    /// Decision item with keycap-styled shortcut key next to the title
    private func decisionItem(title: String, key: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
                Text(title)
                    .font(.body.weight(.medium))
                KeyCapView(key: key)
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Understanding Scores

private struct HelpUnderstandingScoresContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Understanding Scores",
            subtitle: "Similarity scores reflect how close a match is, but they mean different things depending on the pipeline."
        )

        // Score display
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Score Display")
                    .font(.headline)

                Text("Each result shows a colored dot and percentage in the Score column. The dot color gives a quick visual sense of similarity strength:")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    scoreRow(color: .green, label: "Green", desc: "High similarity")
                    scoreRow(color: .orange, label: "Orange", desc: "Moderate similarity")
                    scoreRow(color: Color(nsColor: .secondaryLabelColor), label: "Gray", desc: "Low similarity")
                }

                Text("GTE-Large tends to produce higher cosine similarity scores overall, so its thresholds are set accordingly. Other models like Qwen3-Embedding produce different score distributions. A 75% from one model can mean the same thing as 85% from another. Compare scores within a single run, not across models.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Per-pipeline threshold customization is available in Settings > Advanced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        HelpCard {
            HelpItem(title: "Scores Are Relative", content: "What counts as a good score depends on your data and reference database. A 90% against FooDB means something different than 90% against DFG2. Compare scores within a single run, not across different datasets or models.")
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Text("Score Types Vary by Pipeline")
                        .font(.body.weight(.medium))
                    ExperimentalBadge()
                }

                Text("Embedding pipelines produce cosine similarity scores. Reranker pipelines produce a probability score from the cross-encoder. Generative LLM pipelines produce a selection confidence score. These scales aren't directly comparable. Score threshold customization is available in advanced pipeline settings.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "Categorization Is Pipeline-Based", content: "Results aren't filtered by a score threshold. Instead, the pipeline itself decides what's a match, what needs review, and what's a clear miss. Embedding-only pipelines put everything above a 0.50 floor into Needs Review. Multi-stage pipelines use their second stage to make the call.")

                HelpWarningCard(text: "Multi-stage pipeline decisions are still experimental and should be verified. For scientific research, review both matches and no-matches to catch false negatives.")
            }
        }

        HelpHint("Focus on the Match/Needs Review/No Match categories rather than raw scores. The pipeline has already done the triage for you -- the scores are there for reference, not for manual filtering.")
    }

    private func scoreRow(color: Color, label: String, desc: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.callout.weight(.medium))
            Text("--")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Text(desc)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Exporting Results

private struct HelpExportingContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Exporting Results",
            subtitle: "Export your match results as CSV or TSV. The export preserves all your original data and adds match metadata."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Standard Export")
                    .font(.headline)

                Text("Click the Export button in the toolbar and choose Export CSV or Export TSV. You can also use File > Export as CSV (Cmd+E) or Export as TSV (Shift+Cmd+E). The file layout is:")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("[all your input columns] | fm_status | fm_score | fm_pipeline | fm_note | [all target database columns]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text("Row order matches your original input file, regardless of how you sorted the results table.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("fm_ Columns")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    fmColumn("fm_status", "Match outcome: \"Match\", \"No Match\", \"Needs Review\", \"Match (confirmed)\", \"Match (overridden)\", \"No Match (confirmed)\", or \"Match (LLM)\". Parenthetical suffixes indicate how the decision was made: confirmed/overridden = human review, LLM = generative model selection.")
                    fmColumn("fm_score", "Similarity score as a decimal, e.g. \"0.8723\".")
                    fmColumn("fm_pipeline", "Which pipeline produced the match, e.g. \"GTE-Large\", \"Qwen3 Two-Stage\".")
                    fmColumn("fm_note", "Your review note, or empty if none.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Detailed Export (Advanced Mode)")
                    .font(.headline)

                Text("When Advanced mode is enabled, the export dropdown in the toolbar adds \"Detailed Export (Pipeline Data)\". This includes additional columns: fm_reasoning (LLM reasoning if applicable), and the top-5 embedding candidates with their scores.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Override Handling")
                    .font(.headline)

                Text("When you override a match, all target database columns in the export reflect the override candidate's data, not the original auto-match. No-match rows have empty target columns. If your input and target databases have columns with the same name, the target column gets a \" (target)\" suffix.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Match Statistics")
                    .font(.headline)

                Text("Click the statistics button in the toolbar to open a summary sheet with charts and distribution data for your current results. This includes match rate, score distribution, and category breakdowns. Statistics are view-only and don't affect your data.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }

        HelpHint("You can also export from History without loading the session first: right-click a session and choose \"Export...\". To export all sessions at once, use the export icon at the top of the History page. Both CSV and TSV formats preserve all your data.")
    }

    private func fmColumn(_ name: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(name)
                .font(.system(.callout, design: .monospaced).weight(.medium))
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Custom Databases

private struct HelpCustomDatabasesContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Custom Databases",
            subtitle: "Add your own reference databases to match against. Useful for internal food lists, specialized databases, or any custom reference data."
        )

        HelpCard {
            HelpItem(title: "File Format", content: "UTF-8 encoded CSV or TSV with a header row. Needs at least one column with text descriptions to match against. An optional ID column provides unique identifiers for matched items.")
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "How Embedding Works", content: "When you first match against a custom database, FoodMapper runs the selected embedding model on your GPU to generate a vector representation of each item. This is a one-time operation per database per model. After embedding completes, the database loads instantly for all future matches with that model.")

                HelpItem(title: "Model-Specific Embeddings", content: "Embeddings are tied to the model that created them. If you switch from GTE-Large to Qwen3-Embedding 4B, the database needs to be re-embedded for the new model. Each model's embeddings are cached separately, so switching back is instant if the cache exists.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "Disk Space by Model", content: "Embedding size depends on the model's output dimensions. For a 100,000-item database:")

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    diskRow("GTE-Large (1024-dim)", "~400 MB")
                    diskRow("Qwen3-Embedding 0.6B (1024-dim)", "~400 MB")
                    diskRow("Qwen3-Embedding 4B (2560-dim)", "~1 GB")
                    diskRow("Qwen3-Embedding 8B (4096-dim)", "~1.6 GB")
                }
            }
        }

        HelpCard {
            HelpItem(title: "Size Limits", content: "Recommended database sizes depend on your Mac's memory. Settings > Advanced shows your hardware profile and the recommended limit. Enable \"Allow large databases\" in Settings > Advanced to bypass the warning threshold for larger databases.")
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "Managing Databases", content: "Go to Databases in the sidebar to see all databases (built-in and custom) with item counts and embedding status. Right-click a custom database for options: Get Info, Re-embed, or Remove. Removing a database deletes its stored data and all cached embeddings.")

                HelpItem(title: "Embedding Status Badges", content: "Each database shows a status badge. Built-in databases show \"Embeds on first use\" until their first match, then \"1 model\" or \"N models\" indicating how many model caches exist. Custom databases show \"Not embedded\" until first use. The badge updates automatically as you match with different models.")
            }
        }

        HelpHint("Clean, complete descriptions match better than abbreviations. \"Grilled chicken breast, skinless\" outperforms \"grld chkn brst\".")
    }

    private func diskRow(_ model: String, _ size: String) -> some View {
        HStack {
            Text(model)
                .font(.callout)
            Spacer()
            Text(size)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sessions & History

private struct HelpSessionsContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Sessions & History",
            subtitle: "Match results and review decisions are automatically saved. Pick up where you left off or re-export anytime."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "Auto-Save", content: "When matching completes, results are automatically saved as a session. As you make review decisions, those are saved incrementally too. No manual save needed.")

                HelpItem(title: "What Gets Saved", content: "All results, review decisions (match, no match, overrides, notes), pipeline configuration, and timestamps. Everything you need to continue reviewing or re-export later.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "History Page", content: "Go to History in the sidebar (or Cmd+Shift+H) to see all saved sessions. Each entry shows the input file name, database, match rate, date, and pipeline used.")

                HelpItem(title: "Loading a Session", content: "Click a session in History or on the home screen's Recent Sessions panel. All results and review decisions are restored, so you can continue reviewing where you left off.")

                HelpItem(title: "Deleting Sessions", content: "Right-click a session in History to delete it. The \"Clear All History\" button (with confirmation) removes everything.")

                HelpItem(title: "Exporting Sessions", content: "Right-click any session in History to export it. You can also hover a session row and click the export icon. To export everything at once, click the export icon at the top of the History page and choose \"Export as Zip\" or \"Export to Folder\".")
            }
        }

        HelpCard {
            HelpItem(title: "Recent Sessions on Home", content: "The home screen shows your 5 most recent sessions at the bottom for quick access. Click any session to load it directly.")
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Input Files")
                    .font(.headline)

                Text("The Input Files page in the sidebar shows all files you've loaded into FoodMapper. Files are stored locally so you can reuse them across sessions. Right-click a file to use it for a new match, get info, or remove it. Adding files here doesn't start a match -- it just stores them for later.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }
    }
}

// MARK: - Settings

private struct HelpSettingsContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Settings",
            subtitle: "FoodMapper settings are organized into four tabs. Open Settings with Cmd+Comma."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.accentColor)
                    Text("General")
                        .font(.headline)
                }
                Text("Appearance theme (System, Light, Dark), results per page (200, 500, 1000, 2000), and automatic update preferences. Lower page sizes keep sorting and scrolling responsive with large result sets. The Updates section lets you toggle automatic update checks and downloads via Sparkle. You can also check manually from the FoodMapper menu > Check for Updates.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(Color.accentColor)
                    Text("Models")
                        .font(.headline)
                }
                Text("Download and manage models. In Simple mode, you see just GTE-Large. In Advanced mode, all 8 models are listed by family (Embedding, Reranker, Generative) with download size, GPU memory estimate, and status.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "key")
                        .foregroundStyle(Color.accentColor)
                    Text("API Keys")
                        .font(.headline)
                }
                Text("Store your Anthropic API key for the Claude Haiku pipeline. The key is validated when you save it. Includes step-by-step instructions for getting a key from console.anthropic.com.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color.accentColor)
                    Text("Advanced")
                        .font(.headline)
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HelpItem(title: "Advanced Mode Toggle", content: "Unlocks all pipeline types, model size selection, instruction presets, detailed export, and the Pipelines sidebar section.")
                    HelpItem(title: "System Info", content: "Shows your Mac's detected hardware profile (Base/Standard/Pro/Max/Ultra), device name, and unified memory.")
                    HelpItem(title: "Performance Tuning", content: "Override batch sizes and chunk sizes if the defaults aren't right for your workload.")
                    HelpItem(title: "Database Limits", content: "Toggle to allow databases above the hardware-recommended size.")
                    HelpItem(title: "Reset", content: "Factory reset: deletes all models, sessions, custom databases, cached embeddings, and preferences. Two confirmations required.")
                }
            }
        }
    }
}

// MARK: - Experimental Features

private struct HelpExperimentalFeaturesContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Experimental Features",
            subtitle: "Features under active development. Available for testing but not yet validated for production research use."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("What Are Experimental Features?")
                    .font(.headline)

                Text("Experimental features are parts of FoodMapper that are still being tuned and validated. They work, but their accuracy and behavior may change between releases. For published research, stick with the default GTE-Large or GTE-Large + Haiku pipelines unless you're specifically evaluating these methods.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How to Enable")
                    .font(.headline)

                Text("Go to Settings > Advanced and turn on \"Show advanced options\". This unlocks the full set of pipelines, model size selection, instruction presets, detailed export columns, and performance tuning controls.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Experimental Pipelines")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    expPipelineRow("Qwen3-Embedding", "Instruction-following embedding model in 0.6B, 4B, and 8B sizes. Asymmetric queries with instruction prefix.")
                    expPipelineRow("Qwen3 Two-Stage", "Embedding retrieval followed by cross-encoder reranker rescoring of top candidates.")
                    expPipelineRow("Smart Triage", "Top-10 embedding retrieval + batch reranker. Designed for efficient review triage.")
                    expPipelineRow("Embedding + LLM", "Embedding retrieval + generative LLM selection from top-5 candidates.")
                    expPipelineRow("Qwen3 LLM Judge", "Single-stage generative matching. Practical only for small databases (under 500 items).")
                    expPipelineRow("Qwen3-Reranker (Benchmark)", "Cross-encoder scores every database entry. Very slow, for benchmarking only.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Other Advanced Options")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HelpItem(title: "Model Size Selection", content: "Choose between 0.6B, 4B, and 8B variants for Qwen3 models. Larger models are more accurate but use more memory and run slower.")
                    HelpItem(title: "Instruction Presets", content: "Qwen3-Embedding uses instruction prefixes that tell the model what kind of matching to do. Presets optimize for different scenarios.")
                    HelpItem(title: "Batch Size Tuning", content: "Override the auto-detected batch and chunk sizes for embedding and reranking. Useful if defaults don't match your workload.")
                    HelpItem(title: "Detailed Export", content: "Adds LLM reasoning and top-5 embedding candidates with scores to your export file.")
                }
            }
        }

        HelpWarningCard(
            icon: "info.circle",
            title: "Not Production-Ready",
            text: "These features may produce suboptimal results and their behavior can change between updates. For scientific research, always verify results with human review, regardless of pipeline."
        )
    }

    private func expPipelineRow(_ name: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            HStack(spacing: Spacing.xs) {
                Text(name)
                    .font(.callout.weight(.medium))
                ExperimentalBadge()
            }
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Under the Hood

private struct HelpUnderTheHoodContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Under the Hood",
            subtitle: "A look at the technology behind FoodMapper, from the ML framework to GPU execution."
        )

        // How This App Was Built
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How This App Was Built")
                    .font(.headline)

                HelpItem(title: "From Core ML to MLX", content: "FoodMapper was built from the ground up in Xcode over many hours of testing, tinkering, and trial and error. The backend pipeline originally used Core ML, but after discovering the performance gains MLX offers for transformer inference on Apple Silicon, I scrapped Core ML and started over with MLX.")

                HelpItem(title: "LLM-Assisted Development", content: "Once the MLX backend pipeline, model integration, embeddings conversion, and GPU performance tuning were dialed in, the SwiftUI frontend was built with the assistance of several coding-focused large language models, used directly within Xcode. This saved countless hours of development time on the interface you see now, especially on boilerplate code and UI scaffolding.")
            }
        }

        // Why Apple MLX
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Why Apple MLX")
                    .font(.headline)

                HelpItem(title: "Built for Apple Silicon", content: "MLX is Apple's open-source machine learning framework, designed from the ground up for M-series chips. It runs transformer models directly on the Mac's GPU through Metal, with no drivers, no CUDA, and no admin install required.")

                HelpItem(title: "No Setup Required", content: "Metal is built into macOS. Every Mac with Apple Silicon has GPU compute ready out of the box. FoodMapper is a native .app -- no Python environment, no Docker, no command-line setup.")

                HelpLinkRow(title: "MLX Framework", url: "https://github.com/ml-explore")
            }
        }

        // Models
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The Model Family")
                    .font(.headline)

                HelpItem(title: "GTE-Large", content: "A 335-million parameter BERT-based model with 24 transformer layers, producing 1024-dimensional embeddings. The paper's original model. Symmetric -- no instruction prefix.")

                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(spacing: Spacing.sm) {
                        Text("Qwen3-Embedding")
                            .font(.body.weight(.medium))
                        ExperimentalBadge()
                    }
                    Text("Instruction-following embedding models available in 0.6B, 4B, and 8B sizes (4-bit quantized). These are asymmetric: queries get an instruction prefix that positions them in vector space, while database documents are embedded plain. Higher dimensions (1024/2560/4096) capture more nuance.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(spacing: Spacing.sm) {
                        Text("Qwen3-Reranker")
                            .font(.body.weight(.medium))
                        ExperimentalBadge()
                    }
                    Text("Cross-encoder models (0.6B FP16 and 4B 4-bit) that score query-document pairs by extracting yes/no logits. More accurate than embedding similarity alone, but evaluates one pair at a time.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(spacing: Spacing.sm) {
                        Text("Qwen3-Judge")
                            .font(.body.weight(.medium))
                        ExperimentalBadge()
                    }
                    Text("Generative LLM models (0.6B and 4B, 4-bit) that pick the best match from candidates via single-token logit extraction. Candidates are shuffled before each judgment to eliminate positional bias.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HelpLinkRow(title: "MLX Community Model Hub", url: "https://huggingface.co/mlx-community")
            }
        }

        // How GPU Matching Works
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("How GPU Matching Works")
                    .font(.headline)

                HelpItem(title: "Lazy Evaluation", content: "MLX uses lazy evaluation: it builds a computation graph describing all the operations, then executes the entire graph at once on the GPU. This avoids round-trips between CPU and GPU for each step.")

                HelpItem(title: "Embedding Pipeline", content: "Each input goes through tokenization, transformer layers, pooling, and L2 normalization. The entire pipeline runs on the GPU in a single pass per batch.")

                HelpItem(title: "Similarity Search", content: "Matching is a single matrix multiplication that computes cosine similarity between your inputs and every item in the database at once. This is why matching thousands of items takes seconds, not minutes.")

                HelpItem(title: "GPU-Resident Data", content: "All computation stays on the GPU until the final similarity scores are pulled back to the CPU. Intermediate tensors (token embeddings, attention outputs, pooled vectors) never leave GPU memory.")
            }
        }

        // Hardware Auto-Scaling
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Hardware Auto-Scaling")
                    .font(.headline)

                HelpItem(title: "Detection at Launch", content: "FoodMapper queries Metal at startup to detect your Mac's unified memory, GPU core count, and chip family. Based on this, it assigns a hardware profile (Base through Ultra).")

                HelpItem(title: "Adaptive Batch Sizes", content: "Batch sizes, chunk sizes, and memory limits are tuned to your hardware. An 8GB Mac uses smaller batches and conservative memory limits. A 96GB+ Mac uses large batches with full GPU utilization.")

                HelpItem(title: "Unified Memory", content: "M-series chips share memory between CPU and GPU. The GPU can access system RAM directly without copying data back and forth. This is a significant advantage for ML workloads compared to discrete GPUs that require explicit memory transfers.")
            }
        }

        // Large-Scale Embedding
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Large-Scale Embedding")
                    .font(.headline)

                HelpItem(title: "Embed Once, Match Many", content: "Custom databases are embedded once and the results are cached to disk. After that initial cost, the database loads instantly for all future matches. Only your input files need fresh embedding each time.")

                HelpItem(title: "Streaming to Disk", content: "FoodMapper processes embeddings in chunks and writes each chunk to disk immediately. This prevents memory exhaustion on large databases. GPU memory cache is cleared between chunks to prevent buffer accumulation.")

                HelpItem(title: "Scale", content: "The FDC Branded Foods database (nearly 2 million rows in the December 2025 release) is an example of what's possible on high-end Apple Silicon. Embedding a database that size takes time, but it's a one-time operation.")
            }
        }

        HelpHint("Settings > Advanced shows your detected hardware profile and lets you override batch sizes if needed.")
    }
}

// MARK: - Research

private struct HelpResearchContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Research",
            subtitle: "About the research behind FoodMapper."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "Project Overview", content: "FoodMapper was developed at USDA Agricultural Research Service for nutrition research. It maps dietary intake data to standardized reference databases using semantic similarity, replacing manual lookup with GPU-accelerated embedding matching.")

                HelpItem(title: "Authors", content: "Lemay DG, Strohmeier MP, Stoker RB, Larke JA, Wilson SMG\nUSDA Agricultural Research Service")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Behind the Research")
                    .font(.headline)

                Text("The app includes an in-depth showcase called \"Behind the Research\" that walks through the paper's methodology with interactive visualizations. The showcase specifically covers the GTE-Large embedding model and Claude Haiku as the LLM judge, which are both the app's default pipeline and the exact methods used in the research paper.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("The showcase doesn't cover everything from the paper. It focuses on the core pipeline and results to give you a working understanding of the approach. For complete methodology, statistical analysis, and full results, refer to the published paper.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))

                Text("Access it from the home screen or the Window menu.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        // Citation card
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Publication")
                    .font(.headline)

                Text("A link to the published paper will be added here soon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Source & License")
                    .font(.headline)

                Text("License: CC0 1.0 Universal (Public Domain)")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("This is a U.S. Government work, not subject to U.S. copyright under 17 U.S.C. 105.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
            }
        }
    }
}

// MARK: - Keyboard Shortcuts

private struct HelpKeyboardShortcutsContent: View {
    @Environment(\.colorScheme) private var colorScheme

    private let sections: [(title: String, shortcuts: [(action: String, keys: String)])] = [
        ("File", [
            ("Open Input File", "\u{2318}O"),
            ("Add Reference Database", "\u{2318}\u{21E7}O"),
            ("Export as CSV", "\u{2318}E"),
            ("Export as TSV", "\u{2318}\u{21E7}E"),
        ]),
        ("Matching", [
            ("Run Matching", "\u{2318}R"),
            ("Cancel Matching", "\u{2318}."),
        ]),
        ("Navigation", [
            ("Back", "\u{2318}["),
            ("Forward", "\u{2318}]"),
            ("Show History", "\u{2318}\u{21E7}H"),
            ("Return to Welcome", "\u{2318}\u{21E7}W"),
        ]),
        ("Results Filtering", [
            ("Show All", "\u{2318}1"),
            ("Matches", "\u{2318}2"),
            ("Needs Review", "\u{2318}3"),
            ("No Matches", "\u{2318}4"),
            ("Find", "\u{2318}F"),
            ("Clear Search", "Escape"),
        ]),
        ("Results Pagination", [
            ("Previous Page", "\u{2318}\u{2190}"),
            ("Next Page", "\u{2318}\u{2192}"),
            ("First Page", "\u{2318}\u{21E7}\u{2190}"),
            ("Last Page", "\u{2318}\u{21E7}\u{2192}"),
        ]),
        ("Review", [
            ("Match (or bulk Match All)", "Return"),
            ("No Match (or bulk No Match All)", "Delete"),
            ("Reset Decision (or bulk Reset All)", "R (press twice)"),
            ("Undo", "\u{2318}Z"),
            ("Toggle Guided Review", "\u{2318}\u{21E7}R"),
            ("Exit Guided Review", "Escape"),
        ]),
        ("Review Navigation", [
            ("Next Needs Review", "N"),
            ("Previous Needs Review", "P"),
            ("Next Needs Review", "\u{2192}"),
            ("Previous Needs Review", "\u{2190}"),
            ("Select Candidate 1-5", "1 - 5"),
        ]),
        ("Multi-Select", [
            ("Toggle Row", "\u{2318}+Click"),
            ("Range Select", "\u{21E7}+Click"),
            ("Select All on Page", "\u{2318}A"),
        ]),
        ("Window", [
            ("Settings", "\u{2318},"),
            ("Help", "\u{2318}?"),
            ("Toggle Sidebar", "\u{2318}\u{2303}S"),
            ("Toggle Inspector", "\u{2318}\u{2303}I"),
        ]),
    ]

    var body: some View {
        HelpSectionTitle("Keyboard Shortcuts")

        ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, section in
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Text(section.title.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(1.0)
                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.xs)

                // Rows
                HelpCard {
                    VStack(spacing: 0) {
                        ForEach(Array(section.shortcuts.enumerated()), id: \.offset) { rowIndex, shortcut in
                            if rowIndex > 0 {
                                Divider()
                                    .opacity(colorScheme == .dark ? 0.3 : 0.5)
                            }
                            HelpShortcutRow(
                                action: shortcut.action,
                                keys: shortcut.keys,
                                isAlternate: rowIndex.isMultiple(of: 2)
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Troubleshooting

private struct HelpTroubleshootingContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle("Troubleshooting")

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HelpTroubleshootItem(
                    problem: "App is slow or unresponsive",
                    solution: "Large databases can use significant memory. Try reducing batch sizes in Settings > Advanced, or use a smaller database. Input files over 200,000 rows may cause the interface to slow down -- consider splitting into smaller batches."
                )

                HelpTroubleshootItem(
                    problem: "Poor match quality",
                    solution: "Check that your input descriptions are clean and complete. Short or abbreviated descriptions match poorly. Try a different pipeline -- Two-Stage or Smart Triage often produce better results than embedding-only. Instruction presets (Advanced mode) can help too."
                )

                HelpTroubleshootItem(
                    problem: "Model download fails",
                    solution: "Check your internet connection. Model sizes range from 351 MB (Qwen3-Embedding 0.6B) to 4.5 GB (Qwen3-Embedding 8B). GTE-Large is about 640 MB. If the download fails repeatedly, try restarting the app."
                )

                HelpTroubleshootItem(
                    problem: "Data file won't load",
                    solution: "Ensure the file is valid UTF-8 encoded CSV or TSV with a header row. Check for special characters or malformed rows. Try opening the file in a spreadsheet app first to verify formatting."
                )

                HelpTroubleshootItem(
                    problem: "Custom database embedding fails",
                    solution: "The database may be too large for your Mac's memory. Check Settings > Advanced for size limits. Try splitting into smaller databases, or use a model with smaller embedding dimensions."
                )

                HelpTroubleshootItem(
                    problem: "Custom database embedding is slow",
                    solution: "Embedding is a one-time cost per database per model. Speed depends on your hardware profile, chip generation, and text description length. After embedding completes, the database loads instantly for future matches."
                )

                HelpTroubleshootItem(
                    problem: "\"Database needs re-embedding\" message",
                    solution: "Embeddings are model-specific. If you switch models, the database needs new embeddings for that model. This happens automatically when you run a match. You can also re-embed manually from the Databases page (right-click > Re-embed)."
                )

                HelpTroubleshootItem(
                    problem: "Haiku pipeline not available",
                    solution: "The GTE-Large + Haiku pipeline requires an Anthropic API key. Add one in Settings > API Keys. The key is validated on save. You'll need credits on your Anthropic account."
                )
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Reset the App")
                    .font(.headline)

                Text("If something is fundamentally broken, you can factory-reset from Settings > Advanced > Reset FoodMapper. This is a last resort, not a routine action.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                HelpWarningCard(text: "Resetting will permanently delete ALL app data: downloaded models, saved sessions, review decisions, custom databases, cached embeddings, and preferences. This cannot be undone. Back up any session exports before resetting. Two confirmation steps are required to prevent accidental data loss.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Data Locations")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    locationRow("Models", "~/Library/Application Support/FoodMapper/Models/")
                    locationRow("Custom Databases", "~/Library/Application Support/FoodMapper/CustomDBs/")
                    locationRow("Sessions", "~/Library/Application Support/FoodMapper/Sessions/")
                    locationRow("Input Files", "~/Library/Application Support/FoodMapper/InputFiles/")
                }
            }
        }
    }

    private func locationRow(_ label: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(label)
                .font(.callout.weight(.medium))
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Previews

#Preview("Help - Light") {
    HelpView()
        .frame(width: 760, height: 620)
}

#Preview("Help - Dark") {
    HelpView()
        .frame(width: 760, height: 620)
        .preferredColorScheme(.dark)
}

#Preview("Help - Review Workflow") {
    ScrollView {
        HelpReviewWorkflowContent()
            .padding(Spacing.xxl)
            .frame(maxWidth: 640)
    }
    .frame(width: 600, height: 700)
}

#Preview("Help - Keyboard Shortcuts") {
    ScrollView {
        HelpKeyboardShortcutsContent()
            .padding(Spacing.xxl)
            .frame(maxWidth: 640)
    }
    .frame(width: 600, height: 700)
    .preferredColorScheme(.dark)
}
