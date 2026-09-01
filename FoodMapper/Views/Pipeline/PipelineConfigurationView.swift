import SwiftUI

/// Runs the built-in food-matching fixture against local embedding models.
struct PipelineConfigurationView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedRunID: UUID?
    @State private var installRequest: ModelInstallRequest?

    private let fixture = FoodMatchingBenchmark.regression

    private var benchmarkModels: [RegisteredModel] {
        appState.modelManager.registeredModels.filter {
            $0.purpose == .embedding && $0.admission != .inventory
        }
    }

    private var selectedModel: RegisteredModel? {
        appState.modelManager.registeredModel(for: appState.selectedBenchmarkModelKey)
    }

    private var selectedRun: BenchmarkRun? {
        appState.benchmarkRuns.first { $0.id == selectedRunID } ?? appState.benchmarkRuns.first
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    benchmarkSetup
                    runTable
                    if let selectedRun {
                        runInspector(selectedRun)
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            if !benchmarkModels.contains(where: { $0.key == appState.selectedBenchmarkModelKey }) {
                appState.selectedBenchmarkModelKey = benchmarkModels.first?.key ?? "gte-large"
            }
            selectedRunID = selectedRunID ?? appState.benchmarkRuns.first?.id
        }
        .onChange(of: appState.benchmarkRuns) { _, runs in
            if selectedRunID == nil || !runs.contains(where: { $0.id == selectedRunID }) {
                selectedRunID = runs.first?.id
            }
        }
        .sheet(item: $installRequest) { request in
            ModelDownloadSheet(
                models: request.models,
                modelManager: appState.modelManager,
                onComplete: { installRequest = nil },
                onCancel: { installRequest = nil }
            )
        }
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Label("Benchmarks", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Text("Run the same pinned fixture and metrics for each local embedding model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: HeaderLayout.height)
        .padding(.horizontal, Spacing.lg)
    }

    private var benchmarkSetup: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(fixture.name)
                        .font(.title3.weight(.semibold))
                    Text("Revision \(fixture.revision) · \(fixture.cases.count) cases · \(fixture.targets.count) targets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Text("Built in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: Spacing.md) {
                Picker("Embedding model", selection: $appState.selectedBenchmarkModelKey) {
                    ForEach(benchmarkModels) { model in
                        Text(model.displayName).tag(model.key)
                    }
                }
                .frame(maxWidth: 360)

                if let selectedModel {
                    Text(modelStatus(selectedModel))
                        .font(.caption)
                        .foregroundStyle(modelStatusColor(selectedModel))
                }

                Spacer()

                if appState.benchmarkProgress != nil {
                    Button("Cancel Benchmark") {
                        appState.cancelBenchmark()
                    }
                } else if let selectedModel,
                          !appState.modelManager.state(for: selectedModel.key).isAvailable {
                    Button("Review Model Install") {
                        installRequest = ModelInstallRequest(models: [selectedModel])
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Run Benchmark") {
                        appState.runSelectedBenchmark()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedModel == nil)
                }
            }

            if let progress = appState.benchmarkProgress {
                HStack(spacing: Spacing.md) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }

            if let error = appState.benchmarkError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Each case includes an expected target and a short matching context. FoodMapper records top-1, top-5, top-10, mean reciprocal rank, per-case latency, fixture revision, and model revision.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.lg)
        .panelMaterialStyle(cornerRadius: 10)
    }

    private var runTable: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("RESULTS")
                    .technicalLabel()
                Spacer()
                Text("\(appState.benchmarkRuns.count) saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if appState.benchmarkRuns.isEmpty {
                ContentUnavailableView(
                    "No Benchmark Results",
                    systemImage: "chart.bar.xaxis",
                    description: Text(emptyResultsDescription)
                )
                .frame(height: 190)
            } else {
                Table(appState.benchmarkRuns, selection: $selectedRunID) {
                    TableColumn("Completed") { run in
                        Text(run.completedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .width(min: 140, ideal: 175)

                    TableColumn("Model") { run in
                        Text(modelName(run.modelKey))
                            .lineLimit(1)
                    }
                    .width(min: 155, ideal: 220)

                    TableColumn("Top 1") { run in
                        metricPercent(run.metrics.top1Accuracy)
                    }
                    .width(70)

                    TableColumn("Top 5") { run in
                        metricPercent(run.metrics.top5Accuracy)
                    }
                    .width(70)

                    TableColumn("Top 10") { run in
                        metricPercent(run.metrics.top10Accuracy)
                    }
                    .width(74)

                    TableColumn("MRR") { run in
                        Text(run.metrics.meanReciprocalRank.formatted(.number.precision(.fractionLength(3))))
                            .monospacedDigit()
                    }
                    .width(65)

                    TableColumn("Median") { run in
                        Text(formatMilliseconds(run.metrics.medianLatencyMilliseconds))
                            .monospacedDigit()
                    }
                    .width(85)
                }
                .frame(height: min(220, max(100, 46 + CGFloat(appState.benchmarkRuns.count) * 28)))
            }
        }
    }

    private func runInspector(_ run: BenchmarkRun) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("CASE RESULTS")
                    .technicalLabel()
                Spacer()
                Text("Fixture r\(run.fixtureRevision) · \(String(run.modelRevision.prefix(12)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Table(caseRows(for: run)) {
                TableColumn("Input") { row in
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(row.input)
                            .lineLimit(1)
                        if let context = row.context {
                            Text(context)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .width(min: 220, ideal: 330)

                TableColumn("Expected") { row in
                    Text(row.expected)
                        .lineLimit(2)
                }
                .width(min: 220, ideal: 340)

                TableColumn("Rank") { row in
                    Text(row.rank.map(String.init) ?? "Not in top 10")
                        .foregroundStyle(row.rank == 1 ? .green : .secondary)
                        .monospacedDigit()
                }
                .width(min: 90, ideal: 110)

                TableColumn("Latency") { row in
                    Text(formatMilliseconds(row.latencyMilliseconds))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(85)
            }
            .frame(height: 300)
        }
        .padding(Spacing.lg)
        .panelMaterialStyle(cornerRadius: 10)
    }

    private func caseRows(for run: BenchmarkRun) -> [BenchmarkCaseResultRow] {
        let targets = Dictionary(uniqueKeysWithValues: fixture.targets.map { ($0.id, $0.description) })
        let rankings = Dictionary(uniqueKeysWithValues: run.rankings.map { ($0.caseID, $0) })
        return fixture.cases.compactMap { benchmarkCase in
            guard let ranking = rankings[benchmarkCase.id],
                  let expected = targets[benchmarkCase.expectedTargetID] else { return nil }
            return BenchmarkCaseResultRow(
                id: benchmarkCase.id,
                input: benchmarkCase.input,
                context: benchmarkCase.context,
                expected: expected,
                rank: ranking.rankedTargetIDs.firstIndex(of: benchmarkCase.expectedTargetID).map { $0 + 1 },
                latencyMilliseconds: ranking.latencyMilliseconds
            )
        }
    }

    private func metricPercent(_ value: Double) -> some View {
        Text(value.formatted(.percent.precision(.fractionLength(0))))
            .monospacedDigit()
    }

    private func modelName(_ key: String) -> String {
        appState.modelManager.registeredModel(for: key)?.displayName ?? key
    }

    private func modelStatus(_ model: RegisteredModel) -> String {
        switch appState.modelManager.state(for: model.key) {
        case .notDownloaded: return "Not installed"
        case let .downloading(progress): return progress >= 0.995 ? "Verifying" : "Installing"
        case .downloaded: return "Installed"
        case .loading: return "Loading"
        case .loaded: return "In use"
        case .error: return "Model error"
        }
    }

    private func modelStatusColor(_ model: RegisteredModel) -> Color {
        switch appState.modelManager.state(for: model.key) {
        case .downloaded, .loaded: return .green
        case .error: return .red
        default: return .secondary
        }
    }

    private func formatMilliseconds(_ value: Double) -> String {
        if value >= 1_000 {
            return "\((value / 1_000).formatted(.number.precision(.fractionLength(2)))) s"
        }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) ms"
    }

    private var emptyResultsDescription: String {
        guard let selectedModel else { return "Choose an embedding model." }
        return appState.modelManager.state(for: selectedModel.key).isAvailable
            ? "Run the built-in fixture to record a result."
            : "Install the selected model, then run the built-in fixture."
    }
}

private struct BenchmarkCaseResultRow: Identifiable {
    let id: String
    let input: String
    let context: String?
    let expected: String
    let rank: Int?
    let latencyMilliseconds: Double
}

#Preview("Benchmarks") {
    PipelineConfigurationView()
        .environmentObject(PreviewHelpers.emptyAdvancedState())
        .frame(width: 1100, height: 800)
}
