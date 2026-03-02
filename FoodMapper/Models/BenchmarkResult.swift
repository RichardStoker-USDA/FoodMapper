import Foundation

// MARK: - Benchmark Data Models

/// Which reference database a benchmark targets
enum BenchmarkTargetDB: String, Codable {
    case foodb
    case dfg2
    case both
    case custom
}

/// Where the benchmark dataset came from
enum BenchmarkSource: Codable {
    case bundled(filename: String)
    case imported(url: URL)
}

/// Difficulty tier for benchmark items
enum BenchmarkDifficulty: String, Codable, CaseIterable {
    case easy
    case medium
    case hard
    case noMatch = "no_match"

    var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        case .noMatch: return "No Match"
        }
    }
}

/// A loaded benchmark CSV with metadata parsed from its header comment block.
struct BenchmarkDataset: Identifiable, Codable {
    let id: UUID
    let name: String
    let version: String
    let targetDatabase: BenchmarkTargetDB
    let description: String?
    let itemCount: Int
    let noMatchCount: Int
    let categories: [String]
    let difficultyDistribution: [String: Int]
    let source: BenchmarkSource
    let fileChecksum: String
    var lastRunDate: Date?
    var lastRunTopOneAccuracy: Double?
}

/// A single row from a benchmark CSV.
struct BenchmarkItem: Identifiable, Codable {
    let id: UUID
    let inputText: String
    let expectedMatch: String?          // nil means no correct match exists
    let expectedMatchID: String?
    let alternativeMatch: String?       // acceptable alternative for debatable cases
    let category: String?
    let difficulty: BenchmarkDifficulty?
    let instructionPreset: String?      // for instruction sensitivity benchmarks
    let notes: String?

    var isNoMatch: Bool {
        expectedMatch == nil
    }
}

/// Configuration for a benchmark run.
struct BenchmarkRunConfig: Identifiable, Codable {
    let id: UUID
    let datasetId: UUID
    let pipelineType: PipelineType
    let instructionPreset: InstructionPreset
    let threshold: Double
    let subsetSize: Int?                // nil = run all items
    let timestamp: Date
    let topK: Int?                      // nil = use hardware default
    let embeddingSize: ModelSize?
    let rerankerSize: ModelSize?
    let generativeSize: ModelSize?
    let judgeResponseFormat: JudgeResponseFormat?
    let allowThinking: Bool?

    init(
        datasetId: UUID,
        pipelineType: PipelineType,
        instructionPreset: InstructionPreset = .bestMatch,
        threshold: Double,
        subsetSize: Int? = nil,
        topK: Int? = nil,
        embeddingSize: ModelSize? = nil,
        rerankerSize: ModelSize? = nil,
        generativeSize: ModelSize? = nil,
        judgeResponseFormat: JudgeResponseFormat? = nil,
        allowThinking: Bool? = nil
    ) {
        self.id = UUID()
        self.datasetId = datasetId
        self.pipelineType = pipelineType
        self.instructionPreset = instructionPreset
        self.threshold = threshold
        self.subsetSize = subsetSize
        self.timestamp = Date()
        self.topK = topK
        self.embeddingSize = embeddingSize
        self.rerankerSize = rerankerSize
        self.generativeSize = generativeSize
        self.judgeResponseFormat = judgeResponseFormat
        self.allowThinking = allowThinking
    }
}

/// Score info for a single candidate in the results drill-down
struct CandidateScore: Codable {
    let text: String
    let score: Double
    let rank: Int
}

/// Result of evaluating a single benchmark item.
struct BenchmarkItemResult: Identifiable, Codable {
    let id: UUID
    let itemId: UUID
    let inputText: String
    let expectedMatch: String?
    let alternativeMatch: String?
    let predictedMatch: String?
    let predictedMatchID: String?
    let score: Double
    let isCorrect: Bool
    let isInTopK: Bool                  // Expected match appears in top-K candidates
    let rank: Int?                      // 1-based rank of the expected match (nil if not found)
    let isNoMatchCorrect: Bool?         // nil if not a no-match item
    let category: String?
    let difficulty: BenchmarkDifficulty?
    let candidates: [CandidateScore]?
}

/// Per-difficulty accuracy detail
struct DifficultyMetrics: Codable {
    let count: Int
    let top1Accuracy: Double
    let recallAt5: Double
    let mrr: Double
}

/// Aggregate metrics for a benchmark run.
struct BenchmarkMetrics: Codable {
    // Retrieval metrics
    let topOneAccuracy: Double
    let recallAt3: Double
    let recallAt5: Double
    let recallAt10: Double
    let meanReciprocalRank: Double

    // No-match metrics
    let noMatchPrecision: Double
    let noMatchRecall: Double
    let noMatchF1: Double

    // Per-difficulty breakdown
    let accuracyByDifficulty: [String: DifficultyMetrics]

    // Per-category breakdown
    let accuracyByCategory: [String: Double]

    // Timing
    let totalDurationSeconds: Double
    let averageSecondsPerItem: Double
}

/// Complete results of a benchmark run.
struct BenchmarkResult: Identifiable, Codable {
    let id: UUID
    let config: BenchmarkRunConfig
    let metrics: BenchmarkMetrics
    let itemResults: [BenchmarkItemResult]
    let datasetName: String
    let pipelineName: String
    let databaseName: String
    let deviceName: String
    let itemCount: Int

    var timestamp: Date { config.timestamp }
}

/// State machine for the benchmark detail panel
enum BenchmarkViewState: Equatable {
    case empty
    case ready(UUID)
    case running(UUID)
    case complete(UUID)
    case failed(String)

    static func == (lhs: BenchmarkViewState, rhs: BenchmarkViewState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.ready(let a), .ready(let b)): return a == b
        case (.running(let a), .running(let b)): return a == b
        case (.complete(let a), .complete(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}
