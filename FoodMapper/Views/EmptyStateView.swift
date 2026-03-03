import SwiftUI

/// Empty state content view for displaying centered messages in the detail pane.
///
/// ## NavigationSplitView Layout Pattern (IMPORTANT)
///
/// When creating views that display in NavigationSplitView's detail pane, avoid using
/// `.frame(maxWidth: .infinity, maxHeight: .infinity)` for centering content. This causes
/// the sidebar to lock at a fixed height and not resize with the window.
///
/// **WRONG - causes sidebar layout bugs:**
/// ```swift
/// VStack { content }
///     .frame(maxWidth: .infinity, maxHeight: .infinity)
/// ```
///
/// **CORRECT - use GeometryReader with .position():**
/// ```swift
/// GeometryReader { geo in
///     VStack { content }
///         .position(x: geo.size.width / 2, y: geo.size.height / 2)
/// }
/// ```
///
/// This pattern allows the view to fill available space without requesting infinite
/// dimensions, which preserves proper NavigationSplitView sidebar resizing behavior.
struct EmptyStateView: View {
    enum State {
        case noFile
        case noResults
        case processing(Progress, MatchingPhase, batchStartTime: Date?)
        case error(String)
        case modelRequired
    }

    @EnvironmentObject var appState: AppState

    let state: State
    let onOpenFile: () -> Void
    var onFileDrop: ((URL) -> Void)?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: Spacing.lg) {
                switch state {
                case .noFile:
                    NoFileDropZone(onOpenFile: onOpenFile, onFileDrop: onFileDrop)

                case .noResults:
                    PreMatchPreviewView()

                case .processing(let progress, let phase, let batchStartTime):
                    processingContent(progress: progress, phase: phase, batchStartTime: batchStartTime)

                case .error(let message):
                    EmptyStateContent(
                        icon: "exclamationmark.triangle",
                        iconColor: .orange,
                        title: "Error",
                        message: message
                    )

                case .modelRequired:
                    EmptyStateContent(
                        icon: "cpu",
                        title: "Model Required",
                        message: "The embedding model needs to be downloaded before matching can begin."
                    )
                }
            }
            .frame(maxWidth: state.maxWidth)
            .position(x: geo.size.width / 2, y: geo.size.height / 2 + Spacing.md)
        }
    }

    @ViewBuilder
    private func processingContent(progress: Progress, phase: MatchingPhase, batchStartTime: Date?) -> some View {
        VStack(spacing: Spacing.lg) {
            if phase.isBatchWaiting {
                batchProgressContent(phase: phase, batchStartTime: batchStartTime)
            } else {
                switch phase {
                case .embeddingDatabase(let completed, let total):
                    VStack(spacing: Spacing.md) {
                        ProgressView()
                            .controlSize(.large)

                        Text("Embedding database...")
                            .font(.headline)

                        Text("\(completed.formatted()) of \(total.formatted())")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if total > 0 {
                            ProgressView(value: Double(completed), total: Double(total))
                                .frame(width: 200)
                        }
                    }

                case .reranking(let completed, let total):
                    VStack(spacing: Spacing.md) {
                        ProgressView()
                            .controlSize(.large)

                        Text("Reranking \(completed.formatted())/\(total.formatted())...")
                            .font(.headline)

                        if total > 0 {
                            ProgressView(value: Double(completed), total: Double(total))
                                .frame(width: 200)
                        }
                    }

                default:
                    VStack(spacing: Spacing.md) {
                        ProgressView()
                            .controlSize(.large)

                        Text(phase.displayText.isEmpty ? "Matching..." : phase.displayText)
                            .font(.headline)

                        if progress.totalUnitCount > 0 {
                            Text("\(appState.matchingCompleted) of \(progress.totalUnitCount)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Batch API Progress

    @ViewBuilder
    private func batchProgressContent(phase: MatchingPhase, batchStartTime: Date?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            // Two-stage pipeline tracker
            VStack(alignment: .leading, spacing: 0) {
                // Stage 1: Embedding (complete)
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.body)
                    Text("Embedding complete")
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)

                Divider()

                // Stage 2: Anthropic Batches API
                HStack(spacing: Spacing.sm) {
                    if case .batchReconnecting = phase {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                            .font(.body)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(batchPhaseLabel(phase))
                            .font(.subheadline.weight(.medium))

                        Text(batchPhaseDetail(phase))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Elapsed timer
                    if let start = batchStartTime {
                        TimelineView(.periodic(from: start, by: 1)) { timeline in
                            Text(formatElapsed(from: start, to: timeline.date))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
            .premiumMaterialStyle(cornerRadius: 8)

            // Indeterminate progress bar
            ProgressView()
                .progressViewStyle(.linear)

            // Collapsible info about the Batches API
            BatchInfoDisclosure()
        }
    }

    private func batchPhaseLabel(_ phase: MatchingPhase) -> String {
        switch phase {
        case .batchSubmitting:
            return "Submitting to Anthropic..."
        case .batchSubmitted:
            return "Waiting for Anthropic"
        case .batchProcessing:
            return "Processing on Anthropic"
        case .batchReconnecting:
            return "Reconnecting..."
        default:
            return "Processing..."
        }
    }

    private func batchPhaseDetail(_ phase: MatchingPhase) -> String {
        switch phase {
        case .batchSubmitting:
            return "Uploading batch request"
        case .batchSubmitted(let count):
            return "\(count.formatted()) items queued, typically 5\u{2013}15 min"
        case .batchProcessing(let succeeded, let total):
            if succeeded == 0 {
                return "\(total.formatted()) items queued, typically 5\u{2013}15 min"
            }
            return "\(succeeded.formatted()) of \(total.formatted()) items processed"
        case .batchReconnecting:
            return "Connection interrupted, retrying automatically"
        default:
            return ""
        }
    }

    private func formatElapsed(from start: Date, to end: Date) -> String {
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension EmptyStateView.State {
    var maxWidth: CGFloat {
        switch self {
        case .noResults: return 680
        case .processing(_, let phase, _) where phase.isBatchWaiting: return 420
        default: return 360
        }
    }
}

/// Collapsible info section explaining Batches API behavior during wait.
/// Uses DisclosureGroup so it's compact by default, expandable for curious users.
struct BatchInfoDisclosure: View {
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("The Batches API sends all matching requests to Anthropic at once. Unlike real-time API calls, batches are processed on available compute capacity, so completion time depends on current demand.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.lg) {
                    infoItem(icon: "dollarsign.circle", text: "50% cheaper than real-time API")
                    infoItem(icon: "arrow.up.circle", text: "No rate limits (100K/batch)")
                }
                .padding(.top, Spacing.xxs)
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("Why is there a wait?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disclosureGroupStyle(.automatic)
    }

    private func infoItem(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Pre-match preview showing input column and target database side by side.
/// Adapts to current state: prompts for column selection if needed,
/// shows two-column comparison when ready.
struct PreMatchPreviewView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var hasColumn: Bool {
        appState.selectedColumn != nil
    }

    private var inputSample: [String] {
        guard let file = appState.inputFile,
              let column = appState.selectedColumn else { return [] }
        return Array(file.values(for: column).prefix(10))
    }

    private var dbSample: [String] {
        appState.targetDatabaseSample
    }

    private var inputCount: Int {
        guard let file = appState.inputFile,
              let column = appState.selectedColumn else { return 0 }
        return file.values(for: column).count
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            if !hasColumn {
                // State: file loaded but no column selected yet
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: Size.iconHero))
                    .foregroundStyle(.secondary)

                Text("Select a Match Column")
                    .font(.headline)

                Text("Choose which column contains the food descriptions you want to match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                inlineConfigBar

                if !dbSample.isEmpty {
                    partialPreviewTable
                }

            } else if appState.selectedDatabase == nil {
                // State: column selected but no database selected
                Image(systemName: "cylinder")
                    .font(.system(size: Size.iconHero))
                    .foregroundStyle(.secondary)

                Text("Select a Target Database")
                    .font(.headline)

                Text("Choose a database from the sidebar to match against.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                inlineConfigBar

            } else if inputSample.isEmpty || dbSample.isEmpty {
                // State: column and database selected but data not ready
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: Size.iconHero))
                    .foregroundStyle(.secondary)

                Text("Ready to Match")
                    .font(.headline)

                inlineConfigBar

                Text("Click Match to start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            } else {
                // State: full preview available
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: Size.iconLarge))
                    .foregroundStyle(.secondary)

                Text("Preview")
                    .font(.headline)

                Text("Verify the correct input column and target database are selected, then click Match to begin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                inlineConfigBar

                // Two-column preview
                previewTable

                // Summary line
                if let db = appState.selectedDatabase {
                    Text("\(inputCount.formatted()) input rows \u{2192} \(db.itemCount.formatted()) database items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Guidance
                Text("Large datasets with many rows may take longer to process.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var inlineConfigBar: some View {
        HStack(spacing: 0) {
            // Left: Column picker (above "Your Input" column)
            HStack(spacing: Spacing.xs) {
                Text("Column:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let file = appState.inputFile {
                    Picker("Column", selection: $appState.selectedColumn) {
                        Text("Select...").tag(String?.none)
                        ForEach(file.columns, id: \.self) { col in
                            Text(col).tag(String?.some(col))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .flexiblePickerSizing()
                    .frame(minWidth: 120)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.sm)

            Divider()
                .frame(height: 24)

            // Right: Database picker (above target database column)
            HStack(spacing: Spacing.xs) {
                Text("Database:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Database", selection: $appState.selectedDatabase) {
                    Text("Select...").tag(AnyDatabase?.none)
                    ForEach(BuiltInDatabase.allCases) { db in
                        Text(db.displayName).tag(AnyDatabase?.some(.builtIn(db)))
                    }
                    ForEach(appState.customDatabases) { db in
                        Text(db.displayName).tag(AnyDatabase?.some(.custom(db)))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .flexiblePickerSizing()
                .frame(minWidth: 120)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.sm)
        }
        .padding(.vertical, Spacing.sm)
        .premiumMaterialStyle(cornerRadius: 8)
    }

    private var previewTable: some View {
        HStack(alignment: .top, spacing: 0) {
            // Input column
            previewColumn(
                header: "Your Input",
                values: inputSample,
                totalCount: inputCount
            )

            Divider()

            // Target database column
            if let db = appState.selectedDatabase {
                previewColumn(
                    header: db.displayName,
                    values: dbSample,
                    totalCount: db.itemCount
                )
            } else {
                VStack {
                    Spacer()
                    Text("Select a database")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Preview table with target database populated but input side empty (no column selected yet)
    private var partialPreviewTable: some View {
        HStack(alignment: .top, spacing: 0) {
            // Input column -- placeholder
            VStack(alignment: .leading, spacing: 0) {
                Text("YOUR INPUT")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))

                ForEach(0..<min(dbSample.count, 10), id: \.self) { index in
                    HStack(spacing: Spacing.xs) {
                        Text("\(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .frame(width: 18, alignment: .trailing)

                        Text("--")
                            .font(.body)
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(index % 2 == 0 ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Target database column -- populated
            if let db = appState.selectedDatabase {
                previewColumn(
                    header: db.displayName,
                    values: dbSample,
                    totalCount: db.itemCount
                )
            } else {
                VStack {
                    Spacer()
                    Text("Select a database")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.cardBorder(for: colorScheme), lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func previewColumn(header: String, values: [String], totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            Text(header)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))

            // Rows with alternating backgrounds
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack(spacing: Spacing.xs) {
                    Text("\(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .frame(width: 18, alignment: .trailing)

                    Text(value)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(index % 2 == 0 ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }

            if totalCount > values.count {
                Text("+ \((totalCount - values.count).formatted()) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Content for empty states
struct EmptyStateContent<Actions: View>: View {
    let icon: String
    var iconColor: Color = .secondary
    let title: String
    let message: String
    var actions: (() -> Actions)?

    init(
        icon: String,
        iconColor: Color = .secondary,
        title: String,
        message: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.message = message
        self.actions = actions
    }

    init(
        icon: String,
        iconColor: Color = .secondary,
        title: String,
        message: String
    ) where Actions == EmptyView {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.message = message
        self.actions = nil
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: Size.iconHero))
                .foregroundStyle(iconColor)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actions = actions {
                actions()
                    .padding(.top, Spacing.sm)
            }
        }
    }
}

// MARK: - No File Drop Zone

/// Drop zone for when no file is selected
struct NoFileDropZone: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTargeted = false

    let onOpenFile: () -> Void
    let onFileDrop: ((URL) -> Void)?

    private var borderColor: Color {
        if isDropTargeted {
            return Color.accentColor
        }
        return Color.cardBorder(for: colorScheme)
    }

    private var backgroundColor: Color {
        if isDropTargeted {
            return Color.accentColor.opacity(0.05)
        }
        return .clear
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Drop zone card
            VStack(spacing: Spacing.md) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: Size.iconHero))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)

                Text("Drop File Here")
                    .font(.headline)

                Text("or click to browse")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 280, height: 160)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(backgroundColor)
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        borderColor,
                        style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenFile)
            .onDrop(of: [.fileURL], delegate: CSVDropDelegate(
                isTargeted: $isDropTargeted,
                onDrop: { url in onFileDrop?(url) }
            ))

            // Instructions
            VStack(spacing: Spacing.xs) {
                Text("Load your input file, then select a target database from the sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 320)
        }
    }
}

#Preview("No File - Light") {
    EmptyStateView(state: .noFile, onOpenFile: {}, onFileDrop: { _ in })
        .frame(width: 600, height: 400)
}

#Preview("No File - Dark") {
    EmptyStateView(state: .noFile, onOpenFile: {}, onFileDrop: { _ in })
        .frame(width: 600, height: 400)
        .preferredColorScheme(.dark)
}

#Preview("Processing - Embedding") {
    EmptyStateView(
        state: .processing({
            let p = Progress(totalUnitCount: 100)
            p.completedUnitCount = 42
            return p
        }(), .embeddingInputs, batchStartTime: nil),
        onOpenFile: {}
    )
    .frame(width: 600, height: 400)
}

#Preview("Processing - Batch") {
    EmptyStateView(
        state: .processing({
            let p = Progress(totalUnitCount: 10)
            p.completedUnitCount = 6
            return p
        }(), .batchProcessing(succeeded: 6, total: 10), batchStartTime: Date()),
        onOpenFile: {}
    )
    .frame(width: 600, height: 400)
}

#Preview("Batch - Submitted") {
    EmptyStateView(
        state: .processing(
            Progress(totalUnitCount: 100),
            .batchSubmitted(taskCount: 1304),
            batchStartTime: Date().addingTimeInterval(-45)
        ),
        onOpenFile: {}
    )
    .frame(width: 600, height: 500)
}

#Preview("Batch - Reconnecting") {
    EmptyStateView(
        state: .processing(
            Progress(totalUnitCount: 100),
            .batchReconnecting,
            batchStartTime: Date().addingTimeInterval(-180)
        ),
        onOpenFile: {}
    )
    .frame(width: 600, height: 500)
}

#Preview("Error") {
    EmptyStateView(
        state: .error("Connection to embedding model timed out."),
        onOpenFile: {}
    )
    .frame(width: 600, height: 400)
}

#Preview("No Results Preview") {
    EmptyStateView(state: .noResults, onOpenFile: {})
        .environmentObject(PreviewHelpers.readyToMatchState())
        .frame(width: 700, height: 500)
}
