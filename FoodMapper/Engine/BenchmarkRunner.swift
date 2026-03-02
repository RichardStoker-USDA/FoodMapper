import Foundation
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "benchmark-runner")

/// Runs benchmark datasets against pipelines and computes accuracy metrics.
actor BenchmarkRunner {
    private var isCancelled = false

    func cancel() {
        isCancelled = true
    }

    /// Score pipeline results against ground truth and compute metrics.
    func evaluate(
        items: [BenchmarkItem],
        matchResults: [MatchResult],
        config: BenchmarkRunConfig,
        datasetName: String,
        databaseName: String,
        duration: Double
    ) -> BenchmarkResult {
        guard items.count == matchResults.count else {
            logger.error("Item count mismatch: \(items.count) items vs \(matchResults.count) results")
            return emptyResult(config: config, datasetName: datasetName, databaseName: databaseName)
        }

        let itemResults = scoreItems(items: items, matchResults: matchResults, config: config)
        let metrics = computeMetrics(itemResults: itemResults, items: items, duration: duration)

        let deviceName = Host.current().localizedName ?? "Unknown Mac"

        logger.info("Benchmark complete: top-1=\(String(format: "%.1f", metrics.topOneAccuracy * 100))%, recall@5=\(String(format: "%.1f", metrics.recallAt5 * 100))%, MRR=\(String(format: "%.3f", metrics.meanReciprocalRank))")

        return BenchmarkResult(
            id: UUID(),
            config: config,
            metrics: metrics,
            itemResults: itemResults,
            datasetName: datasetName,
            pipelineName: config.pipelineType.displayName,
            databaseName: databaseName,
            deviceName: deviceName,
            itemCount: items.count
        )
    }

    // MARK: - Per-Item Scoring

    private func scoreItems(
        items: [BenchmarkItem],
        matchResults: [MatchResult],
        config: BenchmarkRunConfig
    ) -> [BenchmarkItemResult] {
        var results: [BenchmarkItemResult] = []
        results.reserveCapacity(items.count)

        for (i, item) in items.enumerated() {
            let matchResult = matchResults[i]
            let predicted = matchResult.matchText
            let isNoMatchPredicted = matchResult.status == .noMatch || matchResult.status == .error

            // Build candidate scores for drill-down
            let candidateScores: [CandidateScore]? = matchResult.candidates?.enumerated().map { idx, c in
                CandidateScore(text: c.matchText, score: c.score, rank: idx + 1)
            }

            if item.isNoMatch {
                // Expected no-match: correct if pipeline also says no match
                let correct = isNoMatchPredicted
                results.append(BenchmarkItemResult(
                    id: UUID(),
                    itemId: item.id,
                    inputText: item.inputText,
                    expectedMatch: nil,
                    alternativeMatch: nil,
                    predictedMatch: predicted,
                    predictedMatchID: matchResult.matchID,
                    score: matchResult.score,
                    isCorrect: correct,
                    isInTopK: correct,
                    rank: nil,
                    isNoMatchCorrect: correct,
                    category: item.category,
                    difficulty: item.difficulty,
                    candidates: candidateScores
                ))
            } else {
                // Expected a match
                if isNoMatchPredicted {
                    // Pipeline said no match but we expected one
                    results.append(BenchmarkItemResult(
                        id: UUID(),
                        itemId: item.id,
                        inputText: item.inputText,
                        expectedMatch: item.expectedMatch,
                        alternativeMatch: item.alternativeMatch,
                        predictedMatch: predicted,
                        predictedMatchID: matchResult.matchID,
                        score: matchResult.score,
                        isCorrect: false,
                        isInTopK: false,
                        rank: nil,
                        isNoMatchCorrect: nil,
                        category: item.category,
                        difficulty: item.difficulty,
                        candidates: candidateScores
                    ))
                } else {
                    // Both expect a match -- check correctness
                    let isTop1 = fuzzyMatch(predicted: predicted, expected: item.expectedMatch) ||
                                 fuzzyMatch(predicted: predicted, expected: item.alternativeMatch)

                    // Find rank of expected match in candidates
                    var rank: Int? = nil
                    var isInTopK = false

                    if let candidates = matchResult.candidates {
                        for (r, candidate) in candidates.enumerated() {
                            if fuzzyMatch(predicted: candidate.matchText, expected: item.expectedMatch) ||
                               fuzzyMatch(predicted: candidate.matchText, expected: item.alternativeMatch) {
                                isInTopK = true
                                rank = r + 1  // 1-based
                                break
                            }
                        }
                    }
                    // Also check top-1
                    if !isInTopK && isTop1 {
                        isInTopK = true
                        rank = 1
                    }

                    results.append(BenchmarkItemResult(
                        id: UUID(),
                        itemId: item.id,
                        inputText: item.inputText,
                        expectedMatch: item.expectedMatch,
                        alternativeMatch: item.alternativeMatch,
                        predictedMatch: predicted,
                        predictedMatchID: matchResult.matchID,
                        score: matchResult.score,
                        isCorrect: isTop1,
                        isInTopK: isInTopK,
                        rank: rank,
                        isNoMatchCorrect: nil,
                        category: item.category,
                        difficulty: item.difficulty,
                        candidates: candidateScores
                    ))
                }
            }
        }

        return results
    }

    // MARK: - Aggregate Metrics

    private func computeMetrics(
        itemResults: [BenchmarkItemResult],
        items: [BenchmarkItem],
        duration: Double
    ) -> BenchmarkMetrics {
        let positiveItems = itemResults.filter { $0.expectedMatch != nil }
        let noMatchItems = itemResults.filter { $0.isNoMatchCorrect != nil }

        // Top-1 accuracy (positive items only)
        let top1 = positiveItems.isEmpty ? 0.0
            : Double(positiveItems.filter { $0.isCorrect }.count) / Double(positiveItems.count)

        // Recall@K helper
        func recallAtK(_ k: Int) -> Double {
            guard !positiveItems.isEmpty else { return 0 }
            let correct = positiveItems.filter {
                if let rank = $0.rank { return rank <= k }
                return false
            }.count
            return Double(correct) / Double(positiveItems.count)
        }

        // MRR
        let mrr: Double = positiveItems.isEmpty ? 0.0 : positiveItems.reduce(0.0) { sum, item in
            if let rank = item.rank {
                return sum + 1.0 / Double(rank)
            }
            return sum
        } / Double(positiveItems.count)

        // No-match metrics
        let truePositives = noMatchItems.filter { $0.isNoMatchCorrect == true }.count
        let falsePositives = positiveItems.filter { $0.predictedMatch == nil || $0.score < 0.01 }.count
        let falseNegatives = noMatchItems.filter { $0.isNoMatchCorrect == false }.count

        let noMatchPrecision = (truePositives + falsePositives) > 0
            ? Double(truePositives) / Double(truePositives + falsePositives) : 0
        let noMatchRecall = (truePositives + falseNegatives) > 0
            ? Double(truePositives) / Double(truePositives + falseNegatives) : 0
        let noMatchF1 = (noMatchPrecision + noMatchRecall) > 0
            ? 2.0 * noMatchPrecision * noMatchRecall / (noMatchPrecision + noMatchRecall) : 0

        // Per-difficulty breakdown
        var accuracyByDifficulty: [String: DifficultyMetrics] = [:]
        let grouped = Dictionary(grouping: itemResults) { $0.difficulty?.rawValue ?? "unknown" }
        for (diffKey, group) in grouped {
            let pos = group.filter { $0.expectedMatch != nil }
            let count = group.count
            let t1 = pos.isEmpty ? 0.0 : Double(pos.filter { $0.isCorrect }.count) / Double(pos.count)
            let r5: Double = pos.isEmpty ? 0.0 : {
                let c = pos.filter { if let r = $0.rank { return r <= 5 } else { return false } }.count
                return Double(c) / Double(pos.count)
            }()
            let m: Double = pos.isEmpty ? 0.0 : pos.reduce(0.0) { s, item in
                if let r = item.rank { return s + 1.0 / Double(r) } else { return s }
            } / Double(pos.count)

            accuracyByDifficulty[diffKey] = DifficultyMetrics(
                count: count, top1Accuracy: t1, recallAt5: r5, mrr: m
            )
        }

        // Per-category breakdown (top-1 accuracy)
        var accuracyByCategory: [String: Double] = [:]
        let catGrouped = Dictionary(grouping: itemResults) { $0.category ?? "uncategorized" }
        for (cat, group) in catGrouped {
            let pos = group.filter { $0.expectedMatch != nil }
            accuracyByCategory[cat] = pos.isEmpty ? 0.0
                : Double(pos.filter { $0.isCorrect }.count) / Double(pos.count)
        }

        let total = Double(itemResults.count)
        return BenchmarkMetrics(
            topOneAccuracy: top1,
            recallAt3: recallAtK(3),
            recallAt5: recallAtK(5),
            recallAt10: recallAtK(10),
            meanReciprocalRank: mrr,
            noMatchPrecision: noMatchPrecision,
            noMatchRecall: noMatchRecall,
            noMatchF1: noMatchF1,
            accuracyByDifficulty: accuracyByDifficulty,
            accuracyByCategory: accuracyByCategory,
            totalDurationSeconds: duration,
            averageSecondsPerItem: total > 0 ? duration / total : 0
        )
    }

    // MARK: - Fuzzy Text Matching

    /// Compare predicted and expected match texts with normalization.
    /// Handles case differences, extra whitespace, and contains matching
    /// for cases where DB has longer text than the ground truth label.
    private func fuzzyMatch(predicted: String?, expected: String?) -> Bool {
        guard let predicted = predicted, let expected = expected else { return false }
        let normP = normalize(predicted)
        let normE = normalize(expected)
        if normP == normE { return true }
        // Contains match for partial labels
        if normP.contains(normE) || normE.contains(normP) { return true }
        return false
    }

    /// Normalize text for comparison: lowercase, trim, collapse whitespace.
    private func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Helpers

    private func emptyResult(config: BenchmarkRunConfig, datasetName: String, databaseName: String) -> BenchmarkResult {
        BenchmarkResult(
            id: UUID(),
            config: config,
            metrics: BenchmarkMetrics(
                topOneAccuracy: 0, recallAt3: 0, recallAt5: 0, recallAt10: 0,
                meanReciprocalRank: 0,
                noMatchPrecision: 0, noMatchRecall: 0, noMatchF1: 0,
                accuracyByDifficulty: [:],
                accuracyByCategory: [:],
                totalDurationSeconds: 0, averageSecondsPerItem: 0
            ),
            itemResults: [],
            datasetName: datasetName,
            pipelineName: config.pipelineType.displayName,
            databaseName: databaseName,
            deviceName: Host.current().localizedName ?? "Unknown Mac",
            itemCount: 0
        )
    }
}
