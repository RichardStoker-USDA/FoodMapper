import SwiftUI
import UniformTypeIdentifiers

/// Main benchmark view -- master-detail layout.
/// Shows dataset list on left, detail/results on right.
/// Advanced mode only (filtered from sidebar in simple mode).
struct BenchmarkView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDatasetId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Page header
            HStack {
                Label("Benchmarks", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                Button {
                    importBenchmarkDataset()
                } label: {
                    Label("Import Dataset", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(height: HeaderLayout.height)
            .padding(.horizontal, Spacing.lg)

            Divider()

            if appState.benchmarkDatasets.isEmpty {
                emptyState
            } else {
                HSplitView {
                    datasetList
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 350)

                    if let datasetId = selectedDatasetId {
                        datasetDetail(for: datasetId)
                    } else {
                        noSelectionView
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.xl) {
            // Icon with subtle background circle
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.1 : 0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }

            VStack(spacing: Spacing.sm) {
                Text("No Benchmark Datasets")
                    .font(.title3)
                    .fontWeight(.medium)

                Text("Import a benchmark CSV to evaluate pipeline accuracy against known ground-truth matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: Spacing.md) {
                Button {
                    importBenchmarkDataset()
                } label: {
                    Label("Import Dataset", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    downloadTemplate()
                } label: {
                    Label("Download Template", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Dataset List

    private var datasetList: some View {
        List(appState.benchmarkDatasets, selection: $selectedDatasetId) { dataset in
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(dataset.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: Spacing.xs) {
                    Text("\(dataset.itemCount) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if dataset.noMatchCount > 0 {
                        Text("\(dataset.noMatchCount) no-match")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Last run info
                if let lastDate = dataset.lastRunDate {
                    HStack(spacing: Spacing.xs) {
                        if let accuracy = dataset.lastRunTopOneAccuracy {
                            Text(String(format: "%.1f%%", accuracy * 100))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(accuracy >= 0.8 ? .green : accuracy >= 0.6 ? .orange : .secondary)
                        }
                        Text(lastDate.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Not yet run")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, Spacing.xxxs)
            .tag(dataset.id)
            .contextMenu {
                if case .imported = dataset.source {
                    Button(role: .destructive) {
                        deleteDataset(dataset)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Dataset Detail

    @ViewBuilder
    private func datasetDetail(for datasetId: UUID) -> some View {
        if let dataset = appState.benchmarkDatasets.first(where: { $0.id == datasetId }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Dataset info header
                    datasetHeader(dataset)

                    // Difficulty breakdown
                    if !dataset.difficultyDistribution.isEmpty {
                        difficultySection(dataset)
                    }

                    // Categories
                    if !dataset.categories.isEmpty {
                        categoriesSection(dataset)
                    }

                    Divider()
                        .padding(.vertical, Spacing.xxs)

                    // Run benchmark section
                    BenchmarkRunnerView(datasetId: datasetId, datasetSource: dataset.source)

                    // Past results
                    let pastResults = appState.benchmarkResults.filter { $0.config.datasetId == datasetId }
                    if !pastResults.isEmpty {
                        Divider()
                            .padding(.vertical, Spacing.xxs)
                        BenchmarkResultsView(results: pastResults) { result in
                            appState.deleteBenchmarkResult(result)
                        }
                    }
                }
                .padding(Spacing.lg)
            }
        } else {
            noSelectionView
        }
    }

    // MARK: - Dataset Header

    private func datasetHeader(_ dataset: BenchmarkDataset) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(dataset.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("v\(dataset.version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxxs)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            if let description = dataset.description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.md) {
                datasetBadge(icon: "doc.text", text: "\(dataset.itemCount) items")
                if dataset.noMatchCount > 0 {
                    datasetBadge(icon: "xmark.circle", text: "\(dataset.noMatchCount) no-match")
                }
                datasetBadge(icon: "internaldrive", text: dataset.targetDatabase.rawValue.uppercased())
                if !dataset.categories.isEmpty {
                    datasetBadge(icon: "tag", text: "\(dataset.categories.count) categories")
                }
            }
        }
        .padding(Spacing.md)
        .premiumMaterialStyle(cornerRadius: 6)
    }

    private func datasetBadge(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Difficulty Section

    private func difficultySection(_ dataset: BenchmarkDataset) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Text("DIFFICULTY DISTRIBUTION")
                    .technicalLabel()
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("How items are distributed by matching difficulty. Easy: obvious matches. Medium: requires some interpretation. Hard: ambiguous, composite, or unusual items. No-match: items with no correct database entry.")
            }

            let sortOrder = ["easy", "medium", "hard", "no_match"]
            let sorted = dataset.difficultyDistribution.sorted { a, b in
                (sortOrder.firstIndex(of: a.key) ?? 99) < (sortOrder.firstIndex(of: b.key) ?? 99)
            }

            let total = sorted.reduce(0) { $0 + $1.value }

            VStack(spacing: Spacing.sm) {
                // Proportional bar
                if total > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(sorted, id: \.key) { difficulty, count in
                                let fraction = CGFloat(count) / CGFloat(total)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(difficultyColor(difficulty))
                                    .frame(width: max(fraction * geo.size.width - 1, 2))
                            }
                        }
                    }
                    .frame(height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                // Legend row
                HStack(spacing: Spacing.lg) {
                    ForEach(sorted, id: \.key) { difficulty, count in
                        HStack(spacing: Spacing.xxs) {
                            Circle()
                                .fill(difficultyColor(difficulty))
                                .frame(width: Size.statusDot, height: Size.statusDot)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(count)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                Text(difficulty.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.md)
            .premiumMaterialStyle(cornerRadius: 6)
        }
    }

    private func difficultyColor(_ key: String) -> Color {
        switch key {
        case "easy": return .green
        case "medium": return .orange
        case "hard": return .red
        case "no_match": return Color(nsColor: .tertiaryLabelColor)
        default: return .secondary
        }
    }

    // MARK: - Categories Section

    private func categoriesSection(_ dataset: BenchmarkDataset) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Text("CATEGORIES")
                    .technicalLabel()
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Food categories from the benchmark dataset. Used to break down accuracy by food group so you can see where the pipeline performs well or struggles.")
            }

            FlowLayout(spacing: Spacing.xs) {
                ForEach(dataset.categories, id: \.self) { cat in
                    Text(cat)
                        .font(.caption)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xxs)
                        .background(Color.badgeBackground(for: colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    // MARK: - No Selection

    private var noSelectionView: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "sidebar.left")
                .font(.system(size: Size.iconHero))
                .foregroundStyle(.secondary)
            Text("Select a dataset")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Import

    private func importBenchmarkDataset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DataFileFormat.allUTTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a benchmark data file"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let result = try BenchmarkCSVParser.parse(url: url, source: .imported(url: url))
                    appState.benchmarkDatasets.append(result.dataset)
                    appState.saveBenchmarkDatasets()
                    selectedDatasetId = result.dataset.id
                } catch {
                    appState.error = AppError.fileLoadFailed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Delete

    private func deleteDataset(_ dataset: BenchmarkDataset) {
        // Remove associated results
        let resultIds = appState.benchmarkResults.filter { $0.config.datasetId == dataset.id }
        for result in resultIds {
            appState.deleteBenchmarkResult(result)
        }
        // Remove dataset
        appState.benchmarkDatasets.removeAll { $0.id == dataset.id }
        appState.saveBenchmarkDatasets()
        if selectedDatasetId == dataset.id {
            selectedDatasetId = nil
        }
    }

    // MARK: - Template Download

    private func downloadTemplate() {
        let templateCSV = """
        #benchmark_version=2.0
        #name=My Benchmark Dataset
        #target_database=foodb
        #description=Ground truth benchmark for evaluating food matching pipelines
        input_text,expected_match,expected_match_id,alternative_match,category,difficulty,instruction,notes
        "Grilled chicken breast",Chicken breast raw,,,protein,easy,,Common protein item
        "2% milk",Milk reduced fat 2%,,,dairy,easy,,Standard dairy product
        "Cheerios cereal",Oat cereal,,,grain,medium,,Brand to generic mapping
        "Grandma's homemade apple pie",NO_MATCH,,,composite,hard,,No direct database entry
        """

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "benchmark_template.csv"
        panel.message = "Save benchmark template CSV"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try templateCSV.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor in
                    appState.error = AppError.fileLoadFailed("Failed to save template: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - FlowLayout (shared)

/// Simple flow layout for wrapping pills and tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}

#Preview("Benchmark - Empty") {
    BenchmarkView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 1000, height: 600)
}

#Preview("Benchmark - Empty - Dark") {
    BenchmarkView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 1000, height: 600)
        .preferredColorScheme(.dark)
}
