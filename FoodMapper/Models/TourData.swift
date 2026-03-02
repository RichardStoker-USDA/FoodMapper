import Foundation

// MARK: - Tour Depth

enum TourDepth: String, CaseIterable, Identifiable {
    case walkthrough
    case technicalReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walkthrough: return "The Walkthrough"
        case .technicalReview: return "The Technical Review"
        }
    }

    var subtitle: String {
        switch self {
        case .walkthrough: return "What the methods do and why they matter"
        case .technicalReview: return "Full implementation details for peer reviewers"
        }
    }

    var duration: String {
        switch self {
        case .walkthrough: return "~10 minutes"
        case .technicalReview: return "~20 minutes"
        }
    }
}

// MARK: - Tour Food Item (NHANES input with ground truth)

struct TourFoodItem: Codable, Identifiable, Hashable {
    let id: Int
    let inputDescription: String
    let groundTruth: String?
    let hasMatch: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case inputDescription = "input_description"
        case groundTruth = "ground_truth"
        case hasMatch = "has_match"
    }
}

// MARK: - Tour Candidate (a single match candidate with score)

struct TourCandidate: Codable, Identifiable, Hashable {
    var id: String { description }
    let description: String
    let score: Double
    let isGroundTruth: Bool

    enum CodingKeys: String, CodingKey {
        case description
        case score
        case isGroundTruth = "is_ground_truth"
    }
}

// MARK: - Tour Method Result (result from a specific method for one item)

struct TourMethodResult: Codable, Identifiable, Hashable {
    var id: Int { inputId }
    let inputId: Int
    let inputDescription: String
    let bestMatch: String?
    let score: Double
    let isCorrect: Bool
    let candidates: [TourCandidate]?

    enum CodingKeys: String, CodingKey {
        case inputId = "input_id"
        case inputDescription = "input_description"
        case bestMatch = "best_match"
        case score
        case isCorrect = "is_correct"
        case candidates
    }
}

// MARK: - Tour Hybrid Result (embedding + Haiku selection)

struct TourHybridResult: Codable, Identifiable, Hashable {
    var id: Int { inputId }
    let inputId: Int
    let inputDescription: String
    let groundTruth: String?
    let embeddingCandidates: [TourCandidate]
    let haikuSelection: String?
    let haikuReasoning: String?
    let isCorrect: Bool

    enum CodingKeys: String, CodingKey {
        case inputId = "input_id"
        case inputDescription = "input_description"
        case groundTruth = "ground_truth"
        case embeddingCandidates = "embedding_candidates"
        case haikuSelection = "haiku_selection"
        case haikuReasoning = "haiku_reasoning"
        case isCorrect = "is_correct"
    }
}

// MARK: - Tour Claude Full-Context Result

struct TourClaudeFullContextResult: Codable, Identifiable, Hashable {
    var id: Int { inputId }
    let inputId: Int
    let inputDescription: String
    let groundTruth: String?
    let haikuSelection: String?
    let haikuCorrect: Bool
    let sonnetSelection: String?
    let sonnetCorrect: Bool

    enum CodingKeys: String, CodingKey {
        case inputId = "input_id"
        case inputDescription = "input_description"
        case groundTruth = "ground_truth"
        case haikuSelection = "haiku_selection"
        case haikuCorrect = "haiku_correct"
        case sonnetSelection = "sonnet_selection"
        case sonnetCorrect = "sonnet_correct"
    }
}

// MARK: - Paper Statistics

struct TourPaperStats: Codable {
    let datasetStats: DatasetStats
    let methodAccuracies: [MethodAccuracy]
    let topKAccuracies: [TopKAccuracy]
    let representativeErrors: [RepresentativeError]

    enum CodingKeys: String, CodingKey {
        case datasetStats = "dataset_stats"
        case methodAccuracies = "method_accuracies"
        case topKAccuracies = "top_k_accuracies"
        case representativeErrors = "representative_errors"
    }
}

struct DatasetStats: Codable {
    let nhanesInputCount: Int
    let dfg2TargetCount: Int
    let matchPercentage: Double
    let noMatchPercentage: Double
    let foodbItemCount: Int
    let asa24InputCount: Int

    enum CodingKeys: String, CodingKey {
        case nhanesInputCount = "nhanes_input_count"
        case dfg2TargetCount = "dfg2_target_count"
        case matchPercentage = "match_percentage"
        case noMatchPercentage = "no_match_percentage"
        case foodbItemCount = "foodb_item_count"
        case asa24InputCount = "asa24_input_count"
    }
}

struct MethodAccuracy: Codable, Identifiable {
    var id: String { method }
    let method: String
    let overallAccuracy: Double?
    let matchAccuracy: Double?
    let noMatchAccuracy: Double?
    let description: String

    enum CodingKeys: String, CodingKey {
        case method
        case overallAccuracy = "overall_accuracy"
        case matchAccuracy = "match_accuracy"
        case noMatchAccuracy = "no_match_accuracy"
        case description
    }
}

struct TopKAccuracy: Codable, Identifiable {
    var id: Int { k }
    let k: Int
    let accuracy: Double
    let dataset: String
}

struct RepresentativeError: Codable, Identifiable {
    var id: Int { inputId }
    let inputId: Int
    let input: String
    let predicted: String
    let groundTruth: String?
    let reasoning: String

    enum CodingKeys: String, CodingKey {
        case inputId = "input_id"
        case input
        case predicted
        case groundTruth = "ground_truth"
        case reasoning
    }
}

// MARK: - Splash Configuration

struct SplashConfig {
    static let currentSplashVersion = 1

    static var shouldShowSplash: Bool {
        let lastSeen = UserDefaults.standard.integer(forKey: "lastSeenSplashVersion")
        return lastSeen < currentSplashVersion
    }

    static func markSeen() {
        UserDefaults.standard.set(currentSplashVersion, forKey: "lastSeenSplashVersion")
    }

    static func resetForTesting() {
        UserDefaults.standard.set(0, forKey: "lastSeenSplashVersion")
    }
}
