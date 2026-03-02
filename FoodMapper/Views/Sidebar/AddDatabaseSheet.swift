import SwiftUI
import UniformTypeIdentifiers

/// Sheet for adding a custom database
struct AddDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let onAdd: (CustomDatabase) -> Void

    @State private var displayName = ""
    @State private var selectedFileURL: URL?
    @State private var columns: [String] = []
    @State private var textColumn = ""
    @State private var idColumn = ""
    @State private var itemCount = 0
    @State private var fileSize: Int64 = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isEmbedding = false  // Track if we started embedding
    @State private var showLargeDatabaseWarning = false
    @State private var showOversizedConfirmation = false

    private var canAdd: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty &&
        selectedFileURL != nil &&
        !textColumn.isEmpty &&
        itemCount > 0
    }

    /// Check if database exceeds recommended size for hardware
    private var exceedsRecommendedSize: Bool {
        itemCount > appState.hardwareConfig.recommendedMaxDatabaseItems
    }

    /// Check if database exceeds absolute maximum size
    private var exceedsAbsoluteMax: Bool {
        itemCount > appState.hardwareConfig.absoluteMaxDatabaseItems
    }

    /// Estimated embedding time based on hardware config
    private var estimatedEmbeddingTime: String {
        let estimate = appState.hardwareConfig.estimateEmbeddingTime(itemCount: itemCount)
        return HardwareConfig.formatDuration(estimate)
    }

    /// Whether to show size warning (respects allowLargeDatabases setting)
    private var shouldShowSizeWarning: Bool {
        exceedsRecommendedSize && !appState.advancedSettings.allowLargeDatabases
    }

    /// Whether the absolute max should block (only when toggle is OFF)
    private var isBlockedByAbsoluteMax: Bool {
        exceedsAbsoluteMax && !appState.advancedSettings.allowLargeDatabases
    }

    private var showEmbeddingProgress: Bool {
        isEmbedding && appState.databaseEmbeddingStatus.isEmbedding
    }

    private var embeddingCompleted: Bool {
        if case .completed = appState.databaseEmbeddingStatus, isEmbedding {
            return true
        }
        return false
    }

    private var completionStats: (itemCount: Int, duration: TimeInterval)? {
        if case .completed(_, let itemCount, let duration) = appState.databaseEmbeddingStatus {
            return (itemCount, duration)
        }
        return nil
    }

    private var embeddingError: String? {
        if case .error(let msg) = appState.databaseEmbeddingStatus {
            return isEmbedding ? msg : nil
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text("Add Custom Database")
                        .font(.headline)
                    Text("Import a CSV or TSV file as a target database")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Spacing.lg)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Content - either form or embedding progress
            if showEmbeddingProgress || embeddingCompleted || embeddingError != nil {
                // Embedding progress view
                embeddingProgressView
            } else {
                // Configuration form
                Form {
                    // Step 1: File
                    Section {
                        FileSelectionRow(
                            url: selectedFileURL,
                            isLoading: isLoading,
                            onSelect: selectFile
                        )
                    } header: {
                        Label("1. Select File", systemImage: "doc")
                    } footer: {
                        Text("Choose a CSV or TSV file with food descriptions")
                    }

                    // Import option (shown when no file loaded yet)
                    if columns.isEmpty && !isLoading {
                        Section {
                            Button {} label: {
                                Label("Import Database...", systemImage: "square.and.arrow.down")
                            }
                            .disabled(true)
                        } footer: {
                            Text("Import a pre-embedded database from another Mac. Coming in a future update.")
                        }
                    }

                    // Step 2: Configuration (shown after file loaded)
                    if !columns.isEmpty {
                        Section {
                            TextField("Name", text: $displayName, prompt: Text("e.g., My Food Database"))
                        } header: {
                            Label("2. Database Name", systemImage: "pencil")
                        }

                        Section {
                            Picker("Description Column", selection: $textColumn) {
                                Text("Select...").tag("")
                                ForEach(columns, id: \.self) { col in
                                    Text(col).tag(col)
                                }
                            }

                            Picker("ID Column (Optional)", selection: $idColumn) {
                                Text("None").tag("")
                                ForEach(columns, id: \.self) { col in
                                    Text(col).tag(col)
                                }
                            }
                        } header: {
                            Label("3. Map Columns", systemImage: "arrow.left.arrow.right")
                        } footer: {
                            Text("Description column contains the text to match against. ID column provides a unique identifier for each food.")
                        }

                        Section {
                            LabeledContent("Rows", value: "\(itemCount.formatted())")
                            LabeledContent("Columns", value: "\(columns.count)")
                            if fileSize > 0 {
                                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                            }
                            LabeledContent("Estimated embedding time", value: estimatedEmbeddingTime)

                            // Size warning
                            if exceedsAbsoluteMax && !appState.advancedSettings.allowLargeDatabases {
                                // Blocked: toggle is OFF and exceeds absolute max
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.red)
                                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                        Text("Database exceeds the warning threshold for your hardware")
                                            .foregroundStyle(.red)
                                        Text("Enable \"Allow large databases\" in Settings > Advanced to add this database.")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            } else if exceedsAbsoluteMax && appState.advancedSettings.allowLargeDatabases {
                                // Allowed but oversized: toggle is ON
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                        Text("Very large database")
                                            .foregroundStyle(.orange)
                                        Text("Estimated time: \(estimatedEmbeddingTime). You'll be asked to confirm before embedding.")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            } else if shouldShowSizeWarning {
                                // Exceeds recommended, toggle OFF
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                        Text("Large database")
                                            .foregroundStyle(.orange)
                                        Text("Recommended max: \(appState.hardwareConfig.recommendedMaxDatabaseItems.formatted()) items")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                            } else if exceedsRecommendedSize && appState.advancedSettings.allowLargeDatabases {
                                // Exceeds recommended but toggle is ON: info only
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.secondary)
                                    Text("Above recommended size (\(appState.hardwareConfig.recommendedMaxDatabaseItems.formatted()) items) for your hardware profile.")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }

                            // Embedding cache guidance
                            if itemCount > 0 {
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    HStack(spacing: Spacing.xs) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .foregroundStyle(.secondary)
                                        Text("Embeddings are generated once and cached for future use.")
                                            .foregroundStyle(.secondary)
                                    }
                                    if itemCount > 5000 {
                                        HStack(spacing: Spacing.xs) {
                                            Image(systemName: "clock")
                                                .foregroundStyle(.secondary)
                                            Text("Only your input files need processing for each new match.")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .font(.caption)
                                .padding(.top, Spacing.xxs)
                            }
                        } header: {
                            Label("File Info", systemImage: "info.circle")
                        }
                    }

                    // Error
                    if let error = errorMessage {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()

            // Footer
            HStack {
                if showEmbeddingProgress {
                    // Cancel embedding
                    Button("Cancel", role: .cancel) {
                        appState.cancelEmbedding()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                } else if embeddingCompleted {
                    // Done - embedding finished
                    Spacer()
                } else if embeddingError != nil {
                    // Error - allow dismiss
                    Button("Close", role: .cancel) {
                        appState.databaseEmbeddingStatus = .idle
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    // Normal cancel
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, Spacing.sm)
                }

                if embeddingCompleted {
                    Button("Done") {
                        appState.databaseEmbeddingStatus = .idle
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else if !showEmbeddingProgress && embeddingError == nil {
                    Button("Add Database") {
                        if exceedsAbsoluteMax && appState.advancedSettings.allowLargeDatabases {
                            showOversizedConfirmation = true
                        } else if shouldShowSizeWarning {
                            showLargeDatabaseWarning = true
                        } else {
                            addDatabase()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd || isLoading || isBlockedByAbsoluteMax)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.lg)
        }
        .frame(width: 480, height: 580)
        .alert(
            "Embed \(itemCount.formatted()) Items?",
            isPresented: $showLargeDatabaseWarning
        ) {
            Button("Cancel", role: .cancel) { }
            Button("Embed Database") { addDatabase() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This database is larger than the recommended \(appState.hardwareConfig.recommendedMaxDatabaseItems.formatted()) for your Mac (\(appState.hardwareConfig.shortDeviceName), \(appState.hardwareConfig.detectedMemoryGB)GB).\n\nEstimated time: \(estimatedEmbeddingTime)\nEmbeddings are computed once and cached for future use.")
        }
        .alert(
            "Embed \(itemCount.formatted()) Items?",
            isPresented: $showOversizedConfirmation
        ) {
            Button("Cancel", role: .cancel) { }
            Button("Embed Database") { addDatabase() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This database exceeds the recommended \(appState.hardwareConfig.recommendedMaxDatabaseItems.formatted()) items for your Mac (\(appState.hardwareConfig.shortDeviceName), \(appState.hardwareConfig.detectedMemoryGB)GB).\n\nEstimated time: \(estimatedEmbeddingTime)\nEmbeddings are computed once and cached for future use.\n\nOn Macs with limited memory, very large databases may cause the app to slow down or quit unexpectedly during embedding.")
        }
    }

    // MARK: - Embedding Progress View

    private var embeddingProgressView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            if embeddingCompleted, let stats = completionStats {
                // Success state with statistics
                Group {
                    if #available(macOS 15.0, *) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: embeddingCompleted)
                    } else {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                    }
                }

                Text("Database Ready")
                    .font(.title2)
                    .fontWeight(.semibold)

                // Statistics panel
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    statisticRow(label: "Items embedded", value: stats.itemCount.formatted())
                    statisticRow(label: "Completed in", value: formatDuration(stats.duration))
                    statisticRow(label: "Throughput", value: formatThroughput(stats.itemCount, stats.duration))
                }
                .padding(Spacing.lg)
                .background(Color.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            } else if let error = embeddingError {
                // Error state
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Embedding Failed")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

            } else {
                // Progress state
                Group {
                    if #available(macOS 26, *) {
                        Image(systemName: "square.stack.3d.up")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.accentColor, Color.accentColor.opacity(0.6))
                            .font(.system(size: 48))
                            .symbolEffect(
                                .drawOn,
                                options: .repeating.speed(0.7),
                                isActive: showEmbeddingProgress
                            )
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                            .font(.system(size: 48))
                    }
                }

                Text("Preparing Database")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Embedding \(displayName)...")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // Progress bar with stats
                if case .embedding(let completed, let total, _, let startTime) = appState.databaseEmbeddingStatus {
                    VStack(spacing: Spacing.sm) {
                        ProgressView(value: appState.databaseEmbeddingStatus.progress)
                            .frame(width: 280)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.databaseEmbeddingStatus.progress)

                        HStack {
                            Text("\(completed.formatted()) / \(total.formatted())")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(formatLiveRate(completed, startTime: startTime))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 280)
                    }
                    .padding(.top, Spacing.md)
                }
            }

            Spacer()
        }
        .padding(Spacing.xl)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DataFileFormat.allUTTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            loadFile(from: url)
        }
    }

    private func loadFile(from url: URL) {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let file = try await CSVParser.parse(url: url)
                selectedFileURL = url
                columns = file.columns
                itemCount = file.rowCount
                fileSize = CSVParser.getFileSize(url: url) ?? 0
                displayName = url.deletingPathExtension().lastPathComponent
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func addDatabase() {
        guard let url = selectedFileURL else { return }

        let database = CustomDatabase(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            csvPath: url.path,
            textColumn: textColumn,
            idColumn: idColumn.isEmpty ? nil : idColumn,
            itemCount: itemCount
        )

        // Start embedding - don't dismiss until complete
        isEmbedding = true
        onAdd(database)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func statisticRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .font(.system(.callout, design: .monospaced))
        }
    }

    // MARK: - Formatters

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        } else if duration < 60 {
            return String(format: "%.1f seconds", duration)
        } else if duration < 3600 {
            let minutes = Int(duration / 60)
            let seconds = Int(duration) % 60
            return "\(minutes)m \(seconds)s"
        } else {
            let hours = Int(duration / 3600)
            let minutes = Int(duration.truncatingRemainder(dividingBy: 3600) / 60)
            if minutes == 0 {
                return "\(hours)h 0m"
            }
            return "\(hours)h \(minutes)m"
        }
    }

    private func formatThroughput(_ items: Int, _ duration: TimeInterval) -> String {
        guard duration > 0 else { return "-" }
        let rate = Double(items) / duration
        if rate >= 1000 {
            return String(format: "%.1fk items/sec", rate / 1000)
        }
        return String(format: "%.0f items/sec", rate)
    }

    private func formatLiveRate(_ completed: Int, startTime: Date) -> String {
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 0.5, completed > 0 else { return "" }  // Wait for meaningful data
        let rate = Double(completed) / elapsed
        if rate >= 1000 {
            return String(format: "%.1fk/sec", rate / 1000)
        }
        return String(format: "%.0f/sec", rate)
    }
}

/// File selection row in the add database sheet
struct FileSelectionRow: View {
    let url: URL?
    let isLoading: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            if let url = url {
                Image(systemName: "doc")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(.secondary)
                Text("No file selected")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Choose...") {
                onSelect()
            }
            .disabled(isLoading)
        }
    }
}

#Preview("Add Database - Light") {
    AddDatabaseSheet { _ in }
        .environmentObject(PreviewHelpers.emptyState())
}

#Preview("Add Database - Dark") {
    AddDatabaseSheet { _ in }
        .environmentObject(PreviewHelpers.emptyState())
        .preferredColorScheme(.dark)
}
