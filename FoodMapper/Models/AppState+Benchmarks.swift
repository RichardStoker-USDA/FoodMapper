import Foundation
import MLX

extension AppState {
    var benchmarkRunsURL: URL {
        FoodMapperStorage.privateDirectory(["Benchmarks"])
            .appendingPathComponent("runs.json")
    }

    func loadBenchmarkRuns() {
        guard let data = try? Data(contentsOf: benchmarkRunsURL),
              let decoded = try? JSONDecoder().decode([BenchmarkRun].self, from: data) else {
            benchmarkRuns = []
            return
        }
        benchmarkRuns = decoded.sorted { $0.startedAt > $1.startedAt }
    }

    func runSelectedBenchmark() {
        guard benchmarkTask == nil else { return }
        let modelKey = selectedBenchmarkModelKey
        benchmarkError = nil
        benchmarkProgress = 0

        benchmarkTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.benchmarkTask = nil
                self.benchmarkProgress = nil
            }

            do {
                let lease = try self.advancedFeatureGate.issueLease()
                let limits = try AdvancedRunLimits.defaults.validated()
                let fixture = FoodMatchingBenchmark.regression
                try fixture.validate(limits: limits)
                guard let registration = self.modelManager.registeredModel(for: modelKey),
                      registration.purpose == .embedding,
                      registration.admission != .inventory else {
                    throw BenchmarkRunError.modelNotAdmitted
                }
                guard self.modelManager.state(for: modelKey).isAvailable else {
                    throw BenchmarkRunError.modelNotInstalled
                }

                try self.advancedFeatureGate.validate(lease)
                let startedAt = Date()
                let model = try await self.modelManager.loadEmbeddingModel(key: modelKey)
                await model.setInstruction(InstructionPreset.bestMatch.embeddingInstruction)
                self.benchmarkProgress = 0.12

                let targetTexts = fixture.targets.map(\.description)
                let targetVectors = try await model.embedBatch(
                    targetTexts,
                    batchSize: min(32, targetTexts.count),
                    isQuery: false
                )
                try self.advancedFeatureGate.validate(lease)
                self.benchmarkProgress = 0.48

                let targetIDs = fixture.targets.map(\.id)
                guard targetVectors.allSatisfy({ $0.count == model.info.dimensions }) else {
                    throw BenchmarkRunError.dimensionMismatch
                }
                var rankings: [BenchmarkRanking] = []
                rankings.reserveCapacity(fixture.cases.count)
                for (index, benchmarkCase) in fixture.cases.enumerated() {
                    try Task.checkCancellation()
                    try self.advancedFeatureGate.validate(lease)
                    let query = benchmarkCase.context.map {
                        "\(benchmarkCase.input). Matching context: \($0)."
                    } ?? benchmarkCase.input
                    let start = DispatchTime.now().uptimeNanoseconds
                    let queryVectors = try await model.embedBatch([query], batchSize: 1, isQuery: true)
                    guard let queryVector = queryVectors.first,
                          queryVector.count == model.info.dimensions else {
                        throw BenchmarkRunError.dimensionMismatch
                    }
                    let rankedTargetIDs = await Task.detached(priority: .userInitiated) {
                        let scored = zip(targetIDs, targetVectors).map { targetID, targetVector in
                            let score = zip(queryVector, targetVector).reduce(Float.zero) { partial, pair in
                                partial + pair.0 * pair.1
                            }
                            return (targetID, score)
                        }.sorted { lhs, rhs in
                            if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
                            return lhs.1 > rhs.1
                        }
                        return scored.prefix(AdvancedRunLimits.maximum.candidateCount).map(\.0)
                    }.value
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    rankings.append(BenchmarkRanking(
                        caseID: benchmarkCase.id,
                        rankedTargetIDs: rankedTargetIDs,
                        latencyMilliseconds: elapsed
                    ))
                    self.benchmarkProgress = 0.48 + (0.42 * Double(index + 1) / Double(fixture.cases.count))
                }

                try self.advancedFeatureGate.validate(lease)
                let metrics = try BenchmarkMetrics.calculate(fixture: fixture, rankings: rankings)
                let run = BenchmarkRun(
                    id: UUID(),
                    startedAt: startedAt,
                    completedAt: Date(),
                    fixtureID: fixture.id,
                    fixtureRevision: fixture.revision,
                    pipelineID: modelKey == "gte-large" ? PipelineType.gteLargeEmbedding.rawValue : "embedding-evaluation",
                    modelKey: modelKey,
                    modelRevision: registration.revision ?? "unversioned",
                    metrics: metrics,
                    rankings: rankings
                )
                self.benchmarkProgress = 0.94
                self.benchmarkRuns.insert(run, at: 0)
                if self.benchmarkRuns.count > 50 {
                    self.benchmarkRuns.removeLast(self.benchmarkRuns.count - 50)
                }
                try self.saveBenchmarkRuns()
                self.benchmarkProgress = 1
                await self.modelManager.unloadEmbeddingModel()
                MLX.Memory.clearCache()
            } catch is CancellationError {
                await self.modelManager.unloadEmbeddingModel()
                MLX.Memory.clearCache()
            } catch {
                self.benchmarkError = error.localizedDescription
                await self.modelManager.unloadEmbeddingModel()
                MLX.Memory.clearCache()
            }
        }
    }

    func cancelBenchmark() {
        benchmarkTask?.cancel()
        benchmarkTask = nil
        benchmarkProgress = nil
    }

    private func saveBenchmarkRuns() throws {
        let data = try JSONEncoder().encode(benchmarkRuns)
        try data.write(to: benchmarkRunsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: SecureFileAccess.privateFilePermissions],
            ofItemAtPath: benchmarkRunsURL.path
        )
    }
}

enum BenchmarkRunError: LocalizedError {
    case modelNotAdmitted
    case modelNotInstalled
    case dimensionMismatch

    var errorDescription: String? {
        switch self {
        case .modelNotAdmitted: return "This model is not admitted for benchmark runs."
        case .modelNotInstalled: return "Review and install the selected model before running the benchmark."
        case .dimensionMismatch: return "The model returned an unexpected embedding size."
        }
    }
}
