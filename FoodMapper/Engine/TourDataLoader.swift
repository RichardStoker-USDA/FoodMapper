import Foundation
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "tour-data")

/// Loads pre-computed tour data from bundled JSON resources.
/// All data is loaded lazily and cached in memory after first access.
actor TourDataLoader {
    static let shared = TourDataLoader()

    private var cachedInputItems: [TourFoodItem]?
    private var cachedFullBenchmarkItems: [TourFoodItem]?
    private var cachedFuzzyResults: [TourMethodResult]?
    private var cachedTFIDFResults: [TourMethodResult]?
    private var cachedClaudeResults: [TourClaudeFullContextResult]?
    private var cachedHybridResults: [TourHybridResult]?
    private var cachedPaperStats: TourPaperStats?

    // MARK: - Public API

    func loadInputItems() throws -> [TourFoodItem] {
        if let cached = cachedInputItems { return cached }
        let items: [TourFoodItem] = try loadJSON("tour_nhanes_input")
        cachedInputItems = items
        logger.info("Loaded \(items.count) NHANES input items")
        return items
    }

    /// Load the full 1,304-item NHANES benchmark dataset for Stop 7 live matching.
    func loadFullBenchmarkItems() throws -> [TourFoodItem] {
        if let cached = cachedFullBenchmarkItems { return cached }
        let items: [TourFoodItem] = try loadJSON("nhanes_1304_input")
        cachedFullBenchmarkItems = items
        logger.info("Loaded \(items.count) full NHANES benchmark items")
        return items
    }

    func loadFuzzyResults() throws -> [TourMethodResult] {
        if let cached = cachedFuzzyResults { return cached }
        let results: [TourMethodResult] = try loadJSON("tour_fuzzy_results")
        cachedFuzzyResults = results
        logger.info("Loaded \(results.count) fuzzy matching results")
        return results
    }

    func loadTFIDFResults() throws -> [TourMethodResult] {
        if let cached = cachedTFIDFResults { return cached }
        let results: [TourMethodResult] = try loadJSON("tour_tfidf_results")
        cachedTFIDFResults = results
        logger.info("Loaded \(results.count) TF-IDF results")
        return results
    }

    func loadClaudeFullContextResults() throws -> [TourClaudeFullContextResult] {
        if let cached = cachedClaudeResults { return cached }
        let results: [TourClaudeFullContextResult] = try loadJSON("tour_claude_fullcontext_results")
        cachedClaudeResults = results
        logger.info("Loaded \(results.count) Claude full-context results")
        return results
    }

    func loadHybridResults() throws -> [TourHybridResult] {
        if let cached = cachedHybridResults { return cached }
        let results: [TourHybridResult] = try loadJSON("tour_hybrid_results")
        cachedHybridResults = results
        logger.info("Loaded \(results.count) hybrid results")
        return results
    }

    func loadPaperStats() throws -> TourPaperStats {
        if let cached = cachedPaperStats { return cached }
        let stats: TourPaperStats = try loadJSON("tour_paper_stats")
        cachedPaperStats = stats
        logger.info("Loaded paper statistics")
        return stats
    }

    /// Clear all cached data (for memory pressure)
    func clearCache() {
        cachedInputItems = nil
        cachedFullBenchmarkItems = nil
        cachedFuzzyResults = nil
        cachedTFIDFResults = nil
        cachedClaudeResults = nil
        cachedHybridResults = nil
        cachedPaperStats = nil
        logger.info("Tour data cache cleared")
    }

    // MARK: - Private

    private func loadJSON<T: Decodable>(_ resourceName: String) throws -> T {
        // Try subdirectory first (folder reference), then root (individual files)
        let url = Bundle.main.url(forResource: resourceName, withExtension: "json", subdirectory: "TourData")
            ?? Bundle.main.url(forResource: resourceName, withExtension: "json")
        guard let url else {
            logger.error("Tour data resource not found: \(resourceName).json")
            throw TourDataError.resourceNotFound(resourceName)
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("Failed to decode \(resourceName).json: \(error.localizedDescription)")
            throw TourDataError.decodingFailed(resourceName, error)
        }
    }
}

enum TourDataError: LocalizedError {
    case resourceNotFound(String)
    case decodingFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .resourceNotFound(let name):
            return "Tour data file '\(name).json' not found in app bundle."
        case .decodingFailed(let name, let error):
            return "Failed to read tour data '\(name).json': \(error.localizedDescription)"
        }
    }
}
