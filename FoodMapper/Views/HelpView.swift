import SwiftUI

/// Holds a requested Help topic until the Help window is ready to display it.
@MainActor
final class HelpRequestCoordinator: ObservableObject {
    @Published private(set) var requestID = 0
    private let notificationCenter: NotificationCenter
    private var notificationObserver: NSObjectProtocol?
    private var pendingSection: HelpSection?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        notificationObserver = notificationCenter.addObserver(
            forName: .showHelp,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.request(rawValue: notification.object as? String)
            }
        }
    }

    deinit {
        if let notificationObserver {
            notificationCenter.removeObserver(notificationObserver)
        }
    }

    func request(rawValue: String?) {
        pendingSection = rawValue.flatMap(HelpSection.init(rawValue:))
        requestID &+= 1
    }

    func consumePendingSection(isAdvancedMode: Bool) -> HelpSection? {
        defer { pendingSection = nil }
        return pendingSection?.resolved(isAdvancedMode: isAdvancedMode)
    }
}

/// In-app help and documentation view with a card-based design.
/// Uses the same design patterns as the Behind the Research showcase.
struct HelpView: View {
    @State private var selectedSection: HelpSection? = .gettingStarted
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var helpRequests: HelpRequestCoordinator

    @State private var navigation = HelpNavigationState()
    @State private var isProgrammaticNav = false

    private var canGoBack: Bool { navigation.canGoBack }
    private var canGoForward: Bool { navigation.canGoForward }

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
            let destination = navigation.select(
                section,
                isAdvancedMode: appState.isAdvancedMode
            )
            if destination != section {
                setSelectedSection(destination)
            }
        }
        .onChange(of: appState.isAdvancedMode) { _, isAdvancedMode in
            guard !isAdvancedMode else { return }
            setSelectedSection(navigation.resetForSimpleMode())
        }
        .onAppear(perform: applyPendingHelpRequest)
        .onChange(of: helpRequests.requestID) { _, _ in
            applyPendingHelpRequest()
        }
    }

    // MARK: - Sidebar

    private var helpSidebar: some View {
        List(selection: $selectedSection) {
            ForEach(HelpSidebarGroup.allCases, id: \.self) { group in
                let sections = group.sections(isAdvancedMode: appState.isAdvancedMode)
                if !sections.isEmpty {
                    Section {
                        ForEach(sections) { section in
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
                        Text(group.title(isAdvancedMode: appState.isAdvancedMode))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.5)
                    }
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
            if let section = selectedSection,
               section.isVisible(isAdvancedMode: appState.isAdvancedMode) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xxl) {
                        section.content(isAdvancedMode: appState.isAdvancedMode)
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
        guard let section = navigation.goBack() else { return }
        setSelectedSection(section)
    }

    private func goForward() {
        guard let section = navigation.goForward() else { return }
        setSelectedSection(section)
    }

    private func setSelectedSection(_ section: HelpSection) {
        isProgrammaticNav = true
        selectedSection = section
        isProgrammaticNav = false
    }

    private func applyPendingHelpRequest() {
        guard let section = helpRequests.consumePendingSection(
            isAdvancedMode: appState.isAdvancedMode
        ) else { return }
        setSelectedSection(
            navigation.select(section, isAdvancedMode: appState.isAdvancedMode)
        )
    }
}

/// Help-topic history detached from SwiftUI state so state transitions can be tested.
struct HelpNavigationState: Equatable {
    private(set) var history: [HelpSection]
    private(set) var historyIndex: Int

    init(initialSection: HelpSection = .gettingStarted) {
        history = [initialSection]
        historyIndex = 0
    }

    var currentSection: HelpSection {
        history[historyIndex]
    }

    var canGoBack: Bool {
        historyIndex > 0
    }

    var canGoForward: Bool {
        historyIndex < history.count - 1
    }

    @discardableResult
    mutating func select(_ requestedSection: HelpSection, isAdvancedMode: Bool) -> HelpSection {
        let section = requestedSection.resolved(isAdvancedMode: isAdvancedMode)
        guard section != currentSection else { return currentSection }

        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(section)
        if history.count > 20 {
            history.removeFirst()
        }
        historyIndex = history.count - 1
        return currentSection
    }

    mutating func goBack() -> HelpSection? {
        guard canGoBack else { return nil }
        historyIndex -= 1
        return currentSection
    }

    mutating func goForward() -> HelpSection? {
        guard canGoForward else { return nil }
        historyIndex += 1
        return currentSection
    }

    /// Reset navigation when Advanced Mode is disabled so Back and Forward
    /// cannot reach a hidden topic.
    @discardableResult
    mutating func resetForSimpleMode() -> HelpSection {
        let visibleSection = currentSection.resolved(isAdvancedMode: false)
        history = [visibleSection]
        historyIndex = 0
        return visibleSection
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

    var requiresAdvancedMode: Bool {
        self == .experimentalFeatures
    }

    func isVisible(isAdvancedMode: Bool) -> Bool {
        !requiresAdvancedMode || isAdvancedMode
    }

    func resolved(isAdvancedMode: Bool) -> HelpSection {
        isVisible(isAdvancedMode: isAdvancedMode) ? self : .gettingStarted
    }

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
    func content(isAdvancedMode: Bool) -> some View {
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
        case .experimentalFeatures:
            if isAdvancedMode {
                HelpExperimentalFeaturesContent()
            } else {
                HelpGettingStartedContent()
            }
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

    func title(isAdvancedMode: Bool) -> String {
        switch self {
        case .basics: return "BASICS"
        case .matching: return "MATCHING"
        case .data: return "DATA"
        case .settingsAdvanced: return isAdvancedMode ? "SETTINGS & ADVANCED" : "SETTINGS"
        case .reference: return "REFERENCE"
        }
    }

    func sections(isAdvancedMode: Bool) -> [HelpSection] {
        HelpSection.allCases.filter {
            $0.group == self && $0.isVisible(isAdvancedMode: isAdvancedMode)
        }
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

    // Render each space-separated key, such as "\u{2190} \u{2192}", as its own keycap.
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

/// Secondary label used where advanced-only material needs a short status marker.
private struct ExperimentalLabel: View {
    var body: some View {
        Text("Experimental")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Getting Started

private struct HelpGettingStartedContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HelpSectionTitle(
            "Getting Started",
            subtitle: "FoodMapper matches food descriptions in your data to standardized reference databases using semantic similarity. Standard embedding matching runs on your Mac's GPU."
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
                HelpStep(number: 1, title: "Download a model", description: appState.isAdvancedMode ? "FoodMapper prompts you to download GTE-Large (about 640 MiB) before default matching. Advanced mode may show optional experimental model downloads that have not been qualified for research use." : "FoodMapper prompts you to download GTE-Large (about 640 MiB) before default matching.")

                HelpStep(number: 2, title: "Load your data", description: "Drop a CSV or TSV file onto the drop zone, or click to browse. The file needs at least one column with food descriptions.")

                HelpStep(number: 3, title: "Select the description column", description: "Pick which column contains the food descriptions you want to match.")

                HelpStep(number: 4, title: "Choose a reference database", description: "FooDB has 9,913 individual food entries. DFG2 has 256 commonly consumed foods from the Davis Food Glycopedia 2.0. You can also add your own.")

                HelpStep(number: 5, title: "Run matching", description: "Click Run Match in the toolbar. FoodMapper retrieves candidate database entries for each description and selects a target when the leading result meets the eligibility floor.")

                HelpStep(number: 6, title: "Review results", description: "Results are categorized as Match, Needs Review, or No Match. Use the inspector panel to confirm, reject, or override matches.")

                HelpStep(number: 7, title: "Export", description: "Export your current session as CSV or TSV. When the input and target metadata remain available, FoodMapper includes original input columns, target columns, and fm_ match metadata.")
            }
        }

        HelpHint("The interactive tutorial walks you through all of this with included sample data. You can restart it anytime from Help > Restart Tutorial.")
    }
}

// MARK: - How It Works

private struct HelpHowItWorksContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HelpSectionTitle(
            "How It Works",
            subtitle: "FoodMapper uses embedding models to compare the meaning of food descriptions rather than relying on exact text matches."
        )

        HelpCard {
            HelpItem(title: "Semantic Embeddings", content: "Each food description is converted into a numerical vector called an embedding. Descriptions with similar language or meaning can produce nearby vectors even when their words differ. Review is still needed because semantic similarity does not establish that two foods are equivalent.")
        }

        HelpCard {
            HelpItem(title: "Local Embedding Matching", content: "The default GTE-Large path runs through Apple's MLX framework on Apple Silicon. FoodMapper compares input embeddings with candidate database entries. Runtime depends on the input, target database, and Mac configuration.")
        }

        if appState.isAdvancedMode {
            HelpCard {
                HelpItem(title: "Selected Targets and Candidates", content: "For default embedding matching, the fixed 0.50 eligibility floor decides whether the leading retrieval becomes the selected target. Retrieved candidate database entries remain available for review even when no target is selected. The Smart Auto-Match floor and gap are separate controls for selected GTE-Large results.")
            }
        }

        HelpHint("Abbreviations, misspellings, and preparation terms can change retrieval order. Review retained candidates before export.")
    }
}

// MARK: - Pipeline Modes

private struct HelpPipelineModesContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState

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

                Text("GTE-Large Embedding is the default local pipeline. GTE-Large + Haiku v2 sends the run's input text and candidate entries to Anthropic for optional verification.")
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

                Text("Presents the paper's methods and an NHANES-to-DFG2 demonstration. It uses GTE-Large retrieval with optional Claude Haiku verification when you configure and select that path.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("Use this mode when you need results that match the paper's methodology, or to explore how semantic food matching works.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
            }
        }

        if appState.isAdvancedMode {
            HelpCard {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("Simple and Advanced Mode")
                        .font(.headline)

                    Text("FoodMapper starts in Simple mode with the default local embedding path and the optional Anthropic verification path.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                    HStack(alignment: .top, spacing: Spacing.sm) {
                        ExperimentalLabel()
                        Text("Advanced mode can show experimental model downloads and related controls. These are not qualified for research use.")
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

            if appState.isAdvancedMode {
                Text("Experimental pipelines are described in the Experimental Features topic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, Spacing.xxs)
            }
        }
    }
}

// MARK: - Review Workflow

private struct HelpReviewWorkflowContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Review Workflow",
            subtitle: "Review results before export. Confirm a selected target, reject it, or choose another retained candidate."
        )

        // The completion overlay
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("After Matching")
                    .font(.headline)

                Text("A summary overlay shows match statistics: how many items matched, need review, or had no match. From here you can jump into Guided Review, view all results, or dismiss and browse freely.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("For a GTE-Large result with a selected target, Smart Auto-Match can promote the result when its score meets the configured floor and its gap to the next candidate exceeds the configured minimum. The 0.50 eligibility floor for selecting a target is separate.")
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

                Text("If the right match is not in the displayed alternatives, open Manual Override and type at least 2 characters. Sessions with a valid saved target snapshot search every row in that frozen database and show the source row and database name. Older sessions, or sessions whose snapshot cannot be opened, search the candidate entries retained for the session. Click a result to set it as the match.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("When you override a match, the inspector shows the selected alternative as the primary display. The pipeline's original match appears below as a secondary \"Original:\" label. Clicking the original match reverts the override.")
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
                Text("). If you accidentally confirm the wrong item, use Undo. The undo stack tracks every match, no-match, override, and reset action.")
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
    @EnvironmentObject private var appState: AppState

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

                Text("A row with an available score shows a colored dot and percentage. Rows without an available score show --:")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    scoreRow(color: .green, label: "Green", desc: "High similarity")
                    scoreRow(color: .orange, label: "Orange", desc: "Moderate similarity")
                    scoreRow(color: Color(nsColor: .secondaryLabelColor), label: "Gray", desc: "Low similarity")
                }

                Text("Compare scores within one run. A score is a retrieval signal, not a measure of scientific equivalence or a probability of a correct match.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.62 : 0.78))
                    .fixedSize(horizontal: false, vertical: true)

                if appState.isAdvancedMode {
                    Text("The default GTE-Large path uses a separate Smart Auto-Match floor and gap after a target is eligible for selection. Experimental artifacts do not share that qualification.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        HelpCard {
            HelpItem(title: "Fixed Eligibility Floor", content: "For default embedding matching, the leading retrieval must reach 0.50 before FoodMapper selects it as the target. Retrieved candidate database entries can still be present for rows without a selected target.")
        }

        if appState.isAdvancedMode {
            HelpCard {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(spacing: Spacing.sm) {
                        Text("Score Types Vary by Pipeline")
                            .font(.body.weight(.medium))
                        ExperimentalLabel()
                    }

                    Text("Experimental artifact scores and default GTE-Large retrieval scores are not interchangeable. Experimental artifacts have not been qualified for research use.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HelpCard {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HelpItem(title: "Review Experimental Output", content: "Review experimental output against the default GTE-Large path. Do not use an experimental result as research evidence without a separate qualification run.")

                    HelpWarningCard(text: "Experimental artifacts are not research-qualified. Review selected targets and no-match rows before use.")
                }
            }
        }

        HelpHint("Use the selected target, retrieved candidate database entries, and your review together. Do not use score color alone to make a scientific decision.")
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
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HelpSectionTitle(
            "Exporting Results",
            subtitle: "Export your match results as CSV or TSV. Original input columns are available only when the current or stored input file can be read."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Standard Export")
                    .font(.headline)

                Text("Click the Export button in the toolbar and choose Export CSV or Export TSV. You can also use File > Export as CSV (Cmd+E) or Export as TSV (Shift+Cmd+E). When the current input and target metadata are available, the file layout is:")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Text("[all your input columns] | fm_status | fm_score | fm_pipeline | fm_note | [all target database columns]")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text("With a readable current input file, row order matches the original input file regardless of table sorting. A reduced export contains saved mapping rows and metadata.")
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
                    fmColumn("fm_score", "Score when available, for example \"0.8723\".")
                    fmColumn("fm_pipeline", "Pipeline label when it was stored with the result.")
                    fmColumn("fm_note", "Your review note, or empty if none.")
                }
            }
        }

        if appState.isAdvancedMode {
            HelpCard {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("Detailed Export")
                        .font(.headline)

                    Text("The export menu can add stored reasoning and retrieved candidate database entries when they are available for the session.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Override Handling")
                    .font(.headline)

                Text("The export records override status, selected text, ID, and a score when the selected candidate was scored. A full-target manual selection keeps the complete selected target row and leaves its score empty. Older candidate-only overrides use the target fields retained with that candidate. No-match rows have empty target columns. If input and target databases share a column name, the target column gets a \" (target)\" suffix.")
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

        HelpHint("You can export one History session without loading it first. It restores original input columns only when the stored input file is available and readable. Bulk History exports use saved mapping rows and do not restore original input columns.")
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
    @EnvironmentObject private var appState: AppState

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
                HelpItem(title: "How Embedding Works", content: "When you first match against a custom database, FoodMapper runs the selected embedding model on your GPU to generate a vector representation of each item. FoodMapper can reuse the saved cache for later matches with the same database and model.")

                if appState.isAdvancedMode {
                    HelpItem(title: "Model-Specific Embeddings", content: "Embeddings are tied to the model that created them. If you switch models, the database needs to be re-embedded. Each model cache is stored separately, so switching back uses the existing cache.")
                }
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "Embedding Cache Size", content: "Embedding cache size depends on the target database and model. FoodMapper shows the available cache state for each database.")
            }
        }

        if appState.isAdvancedMode {
            HelpCard {
                HelpItem(title: "Size Limits", content: "Recommended database sizes depend on your Mac's memory. Settings > Advanced shows the hardware profile and recommended limit. Enable \"Allow large databases\" to bypass the warning threshold for larger databases.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "Managing Databases", content: "Go to Databases in the sidebar to see all databases (built-in and custom) with item counts and embedding status. Right-click a custom database for options: Get Info, Re-embed, or Remove. Removing a database deletes its stored data and all cached embeddings.")

                HelpItem(title: "Embedding Status Badges", content: "Each database shows a status badge. Built-in databases show \"Embeds on first use\" until their first match, then \"1 model\" or \"N models\" indicating how many model caches exist. Custom databases show \"Not embedded\" until first use. The badge updates automatically as you match with different models.")
            }
        }

        HelpHint("Abbreviations and omitted preparation terms can change retrieval order. Review retained candidates before export.")
    }
}

// MARK: - Sessions & History

private struct HelpSessionsContent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HelpSectionTitle(
            "Sessions & History",
            subtitle: "Match results and review decisions are automatically saved. Stored input files are separate from session records."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "Auto-Save", content: "When matching completes, results are automatically saved as a session. As you make review decisions, those are saved incrementally too. No manual save needed.")

                HelpItem(title: "What Gets Saved", content: "Results, review decisions, pipeline configuration, and timestamps are saved with the session. Retrieved candidate database entries are available only when that session stored them.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HelpItem(title: "History Page", content: "Go to History in the sidebar (or Cmd+Shift+H) to see all saved sessions. Each entry shows the input file name, database, match rate, date, and pipeline used.")

                HelpItem(title: "Loading a Session", content: "Click a session in History or on the home screen's Recent Sessions panel. All results and review decisions are restored, so you can continue reviewing where you left off.")

                HelpItem(title: "Deleting Sessions", content: "Right-click a session in History to delete it. The \"Clear All History\" button (with confirmation) removes everything.")

                HelpItem(title: "Exporting Sessions", content: "Right-click a session in History to export it. A single-session export can restore original input columns only when the stored input file is readable. Exporting all sessions creates reduced saved mapping rows.")
            }
        }

        HelpCard {
            HelpItem(title: "Recent Sessions on Home", content: "The home screen shows your 5 most recent sessions at the bottom for quick access. Click any session to load it directly.")
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Input Files")
                    .font(.headline)

                Text("The Input Files page in the sidebar shows all files you've loaded into FoodMapper. Files are stored locally so you can reuse them across sessions. Right-click a file to use it for a new match, get info, or remove it. Adding files here doesn't start a match -- it stores them for later.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
            }
        }
    }
}

// MARK: - Settings

private struct HelpSettingsContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState

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
                Text("Appearance theme (System, Light, Dark), results per page (200, 500, 1000, 2000), and automatic update checks. Lower page sizes keep sorting and scrolling responsive with large result sets. The Updates section controls automatic Sparkle update checks. You can also check manually from the FoodMapper menu > Check for Updates.")
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
                Text(appState.isAdvancedMode ? "Review installed models, exact download sizes, publishers, licenses, pinned revisions, and local status. Optional models are installed only after you confirm the reviewed file list." : "Download and manage the GTE-Large model used by the standard matching pipeline.")
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

        if appState.isAdvancedMode {
            HelpCard {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color.accentColor)
                        Text("Advanced")
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HelpItem(title: "Advanced Mode Toggle", content: "Shows optional experimental downloads and related controls when the app release provides them.")
                        HelpItem(title: "System Info", content: "Shows your Mac's detected hardware profile (Base/Standard/Pro/Max/Ultra), device name, and unified memory.")
                        HelpItem(title: "Performance Controls", content: "Available controls depend on the selected path and app release. Record the settings with an experimental comparison.")
                        HelpItem(title: "Database Limits", content: "Allow databases above the hardware-recommended size.")
                        HelpItem(title: "Reset", content: "Removes FoodMapper Application Support data, provider credentials, and preferences, then restarts the app. It does not remove the Anthropic API key stored in your Mac's Keychain. Two confirmations are required.")
                    }
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
            subtitle: "Optional runs, local model comparisons, and provider connections."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Separate from the Published Method")
                    .font(.headline)

                Text("The default GTE-Large and optional Anthropic path remain unchanged. Advanced mode adds evaluation tools beside that method. Turning Advanced mode off hides these topics, returns pipeline selection to GTE-Large, and cancels active experimental work.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Runs")
                    .font(.headline)

                HelpItem(title: "Choose a Pipeline", content: "Runs lists the published methods and the current evaluation pipelines. Select model sizes and matching context before opening a new match.")
                HelpItem(title: "Install from the Pipeline", content: "Review Install shows publisher, license, pinned revision, exact file size, and install state. A model is not downloaded until you confirm that sheet.")
                HelpItem(title: "Current Model Set", content: "Nomic Embed Text v1.5 and admitted Qwen3 artifacts are available for evaluation. Models marked Under review cannot be installed or used.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Benchmarks")
                    .font(.headline)

                HelpItem(title: "Pinned Fixture", content: "The built-in food-matching regression fixture contains 20 cases and 30 targets. It covers preparation, non-dairy foods, fermentation, canned foods, dry mixes, and related distinctions.")
                HelpItem(title: "Recorded Metrics", content: "Each run stores top-1, top-5, top-10, mean reciprocal rank, median per-case latency, the fixture revision, the model revision, and each expected target rank.")
                HelpItem(title: "Private Storage", content: "Benchmark records stay in FoodMapper Application Support and are not added to the project repository.")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Providers")
                    .font(.headline)
                HelpItem(title: "Supported Profiles", content: "Provider profiles support OpenAI and loopback OpenAI-compatible servers. Local profiles are limited to 127.0.0.1 or ::1.")
                HelpItem(title: "Credentials", content: "Profile metadata is stored in FoodMapper Application Support. API keys and bearer tokens are stored separately in the macOS Keychain.")
                HelpItem(title: "Request Format", content: "FoodMapper fixes the messages, strict response schema, streaming mode, token limit, and credential handling. Custom request fields are not available for automatic decisions.")
                HelpItem(title: "Connection Probe", content: "The probe sends a fixed broccoli example and checks for one candidate ID in JSON. OpenAI probes require a transfer confirmation. Imported data is not used by the probe.")
                HelpItem(title: "Provider Runs", content: "GTE-Large retrieves candidates locally. Each selected input description and its candidates are then sent to the chosen provider. Every provider-assisted run requires a confirmation and is limited to 250 inputs.")
            }
        }

        Text("Experimental output has not completed the published method's research qualification. Keep the run record and review selected targets before using a comparison in research.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

}

// MARK: - Under the Hood

private struct HelpUnderTheHoodContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HelpSectionTitle(
            "Under the Hood",
            subtitle: "A look at the technology behind FoodMapper, from the ML framework to GPU execution."
        )

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Why Apple MLX")
                    .font(.headline)

                HelpItem(title: "Built for Apple Silicon", content: "MLX is Apple's open-source machine learning framework for Apple Silicon. It runs transformer models through Metal without separate GPU drivers or CUDA.")

                HelpItem(title: "No Runtime Setup", content: "Metal is built into macOS. FoodMapper is a native app and does not use a Python environment, Docker, or a command-line runtime for normal use.")

                HelpLinkRow(title: "MLX Framework", url: "https://github.com/ml-explore")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("The Model Family")
                    .font(.headline)

                HelpItem(title: "GTE-Large", content: "A 335-million parameter BERT-based model that produces 1024-dimensional embeddings. FoodMapper uses the pinned MIT-licensed MLX conversion for default local matching.")

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

                HelpItem(title: "Similarity Search", content: "FoodMapper computes cosine similarity between input embeddings and candidate database embeddings. Runtime depends on database size, input length, batch settings, and the Mac.")

                HelpItem(title: "GPU-Resident Data", content: "All computation stays on the GPU until the final similarity scores are pulled back to the CPU. Intermediate tensors (token embeddings, attention outputs, pooled vectors) never leave GPU memory.")
            }
        }

        // Hardware Auto-Scaling
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Hardware Auto-Scaling")
                    .font(.headline)

                HelpItem(title: "Detection at Launch", content: "FoodMapper queries Metal at startup to detect your Mac's unified memory, GPU core count, and chip family. Based on this, it assigns a hardware profile (Base through Ultra).")

                HelpItem(title: "Adaptive Batch Sizes", content: "FoodMapper uses the detected hardware profile to choose initial batch and chunk settings. The selected settings can change with the model and workload.")

                HelpItem(title: "Unified Memory", content: "M-series chips use unified memory, so the CPU and GPU share the same memory pool.")
            }
        }

        // Large-Scale Embedding
        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Large-Scale Embedding")
                    .font(.headline)

                HelpItem(title: "Embed Once, Match Many", content: "FoodMapper caches custom-database embeddings for the model that created them. Reusing a cache avoids re-embedding that target database.")

                HelpItem(title: "Streaming to Disk", content: "FoodMapper processes embeddings in chunks and writes each chunk to disk immediately. This prevents memory exhaustion on large databases. GPU memory cache is cleared between chunks to prevent buffer accumulation.")

                HelpItem(title: "Large Targets", content: "Runtime, memory use, cache size, cancellation behavior, and free disk space must be checked for each large target database and Mac configuration.")
            }
        }

        if appState.isAdvancedMode {
            HelpHint("Settings > Advanced shows the detected hardware profile. Batch and chunk controls appear only for pipelines with an embedding stage.")
        }
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
                HelpItem(title: "Project Overview", content: "FoodMapper was developed at USDA Agricultural Research Service for nutrition research. It supports review of dietary descriptions against reference databases using semantic retrieval.")

                HelpItem(title: "Authors", content: "Lemay DG, Strohmeier MP, Stoker RB, Larke JA, Wilson SMG\nUSDA Agricultural Research Service")
            }
        }

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Behind the Research")
                    .font(.headline)

                Text("The app includes a Behind the Research showcase for the published methods. Food Matching defaults to local GTE-Large embedding. When selected, the optional Anthropic path sends input text and retrieved candidate database entries needed for the run.")
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

                Text("Lemay DG, Strohmeier MP, Stoker RB, Larke JA, Wilson SMG. Evaluation of Large Language Models for Mapping Dietary Data to Food Databases. J Nutr. 2026 Aug;156(8):101678.")
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                Link("doi:10.1016/j.tjnut.2026.101678", destination: AppLinks.publication)
                    .font(.callout)

                Link("PubMed PMID 42309308", destination: AppLinks.pubMed)
                    .font(.callout)
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
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HelpSectionTitle("Troubleshooting")

        HelpCard {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HelpTroubleshootItem(
                    problem: "App is slow or unresponsive",
                    solution: appState.isAdvancedMode ? "Large databases can use significant memory. Reduce batch sizes in Settings > Advanced, or use a smaller database. Input files over 200,000 rows can slow the interface, so split them into smaller batches." : "Large databases can use significant memory. Use a smaller database or split input files over 200,000 rows into smaller batches."
                )

                HelpTroubleshootItem(
                    problem: "Poor match quality",
                    solution: appState.isAdvancedMode ? "Check that input descriptions are clean and complete. Short or abbreviated descriptions match poorly. Compare an experimental pipeline after you review its output against the standard pipeline." : "Check that input descriptions are clean and complete. Short or abbreviated descriptions match poorly. Review the results before export."
                )

                HelpTroubleshootItem(
                    problem: "Model download fails",
                    solution: appState.isAdvancedMode ? "Check your internet connection and free disk space. If the download fails repeatedly, restart the app and try again." : "Check your internet connection and free disk space. GTE-Large is about 640 MiB. If the download fails repeatedly, restart the app and try again."
                )

                HelpTroubleshootItem(
                    problem: "Data file won't load",
                    solution: "Ensure the file is valid UTF-8 encoded CSV or TSV with a header row. Check for special characters or malformed rows. Try opening the file in a spreadsheet app first to verify formatting."
                )

                HelpTroubleshootItem(
                    problem: "Custom database embedding fails",
                    solution: appState.isAdvancedMode ? "The database may be too large for your Mac's memory. Check Settings > Advanced for size limits. Try splitting it into smaller databases or select a smaller embedding model." : "The database may be too large for your Mac's memory. Try splitting it into smaller databases."
                )

                HelpTroubleshootItem(
                    problem: "Custom database embedding is slow",
                    solution: "Embedding is a one-time cost per database per model. Speed depends on your hardware profile, chip generation, and text description length. A reusable cache avoids embedding the same target database again."
                )

                HelpTroubleshootItem(
                    problem: "\"Database needs re-embedding\" message",
                    solution: appState.isAdvancedMode ? "Embeddings are model-specific. If you switch models, the database needs new embeddings for that model. This happens automatically when you run a match. You can also re-embed from the Databases page (right-click > Re-embed)." : "The database needs new embeddings. This happens automatically when you run a match. You can also re-embed from the Databases page (right-click > Re-embed)."
                )

                HelpTroubleshootItem(
                    problem: "Haiku pipeline not available",
                    solution: "The GTE-Large + Haiku pipeline requires an Anthropic API key. Add one in Settings > API Keys. The key is validated on save. You'll need credits on your Anthropic account."
                )
            }
        }

        if appState.isAdvancedMode {
            HelpCard {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("Reset the App")
                        .font(.headline)

                    Text("If something is fundamentally broken, you can reset FoodMapper from Settings > Advanced > Reset FoodMapper. The reset removes FoodMapper Application Support data and preferences, then restarts the app. It does not remove the Anthropic API key stored in your Mac's Keychain.")
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(colorScheme == .dark ? 0.68 : 0.82))

                    HelpWarningCard(text: "Resetting permanently removes downloaded models, saved sessions and review decisions, benchmark records, custom databases and cached embeddings, stored input files, provider profiles and their Keychain credentials, and FoodMapper preferences. It does not remove the Anthropic API key stored in Keychain. This cannot be undone. Back up any session exports before resetting. Two confirmation steps are required to prevent accidental data loss.")
                }
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
        .environmentObject(PreviewHelpers.emptyState())
        .environmentObject(HelpRequestCoordinator())
        .frame(width: 760, height: 620)
}

#Preview("Help - Dark") {
    HelpView()
        .environmentObject(PreviewHelpers.emptyAdvancedState())
        .environmentObject(HelpRequestCoordinator())
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
