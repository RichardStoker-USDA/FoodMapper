import Foundation
import SwiftUI

/// How the score was produced -- determines interpretation and thresholds
enum ScoreType: String, Codable, CaseIterable {
    case cosineSimilarity       // Embedding dot product (0..1)
    case rerankerProbability    // Cross-encoder softmax probability (0..1)
    case llmSelected            // Binary: API LLM chose this match (score is embedding score)
    case generativeSelection    // Local LLM logit-based selection (0..1)
    case llmRejected            // LLM explicitly rejected all candidates (Haiku returned "0"/"none")
    case apiFallback            // API call failed, using embedding score as fallback
    case noScore                // No numeric score (e.g. error rows)
}

/// Categorization of a match result based on pipeline decisions and human review.
/// Auto-categories (match/needsReview/noMatch) are assigned by the triage system.
/// Human categories (confirmedMatch/confirmedNoMatch) override auto-categories after review.
enum MatchCategory: String, Codable, CaseIterable, Identifiable {
    case match              // Pipeline confident this is correct (hybrid only)
    case needsReview        // Pipeline uncertain, user must verify
    case noMatch            // Pipeline confident there is no match
    case confirmedMatch     // Human confirmed as match (blue)
    case confirmedNoMatch   // Human rejected explicitly (red)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .match: return "Match"
        case .needsReview: return "Needs Review"
        case .noMatch: return "No Match"
        case .confirmedMatch: return "Confirmed"
        case .confirmedNoMatch: return "Rejected"
        }
    }

    var icon: String {
        switch self {
        case .match: return "checkmark.circle"
        case .needsReview: return "questionmark.circle"
        case .noMatch: return "minus.circle"
        case .confirmedMatch: return "person.crop.circle.badge.checkmark"
        case .confirmedNoMatch: return "person.crop.circle.badge.xmark"
        }
    }

    var color: Color {
        switch self {
        case .match: return .green
        case .needsReview: return Color.accentColor
        case .noMatch: return Color(nsColor: .tertiaryLabelColor)
        case .confirmedMatch: return .blue
        case .confirmedNoMatch: return .red
        }
    }

    /// Sort priority for display ordering (lower = shown first in review)
    var sortPriority: Int {
        switch self {
        case .needsReview: return 0
        case .match: return 1
        case .noMatch: return 2
        case .confirmedMatch: return 3
        case .confirmedNoMatch: return 4
        }
    }

    /// Whether this is a human-assigned category
    var isHumanDecision: Bool {
        self == .confirmedMatch || self == .confirmedNoMatch
    }

    /// Derive category from a MatchResult + optional ReviewDecision + ThresholdProfile.
    /// Priority: human decision > auto-triage status > pipeline-based fallback.
    /// profile parameter retained for API compatibility; not used in categorization logic.
    static func from(result: MatchResult, decision: ReviewDecision?, profile: ThresholdProfile) -> MatchCategory {
        // Human decisions always win
        if let decision = decision {
            switch decision.status {
            case .accepted, .overridden:
                return .confirmedMatch
            case .rejected:
                return .confirmedNoMatch
            case .skipped:
                break // Fall through to auto-categorization
            // Auto-triage statuses
            case .autoMatch, .autoAccepted:
                return .match
            case .autoNeedsReview, .autoLikelyMatch, .autoUnlikelyMatch, .pending:
                return .needsReview
            case .autoNoMatch, .autoRejected:
                return .noMatch
            }
        }

        // No match (nothing found above floor)
        if result.status == .noMatch && result.matchText == nil {
            return .noMatch
        }

        // Error results
        if result.status == .error {
            return .noMatch
        }

        // Pipeline-specific categorization
        switch result.scoreType {
        case .llmSelected:
            // Haiku made a decision
            if result.status == .llmMatch {
                return .match
            } else {
                return .needsReview
            }
        case .llmRejected:
            return .noMatch
        case .apiFallback:
            return .needsReview
        case .cosineSimilarity, .rerankerProbability, .generativeSelection:
            // Embedding-only: everything with a match is "needs review"
            return .needsReview
        case .noScore:
            return .noMatch
        }
    }
}

/// Threshold configuration for score bar coloring and backward-compatible session loading.
/// No longer used for categorization (pipeline decisions determine categories now).
struct ThresholdProfile: Codable, Equatable {
    let matchThreshold: Double         // Score bar color breakpoint (green >= this)
    let likelyMatchThreshold: Double   // Kept for Codable backward compat
    let unlikelyMatchThreshold: Double // Kept for Codable backward compat
    let minimumGap: Double             // Kept for Codable backward compat

    init(matchThreshold: Double, likelyMatchThreshold: Double = 0.85, unlikelyMatchThreshold: Double = 0.84, minimumGap: Double = 0.05) {
        self.matchThreshold = matchThreshold
        self.likelyMatchThreshold = likelyMatchThreshold
        self.unlikelyMatchThreshold = unlikelyMatchThreshold
        self.minimumGap = minimumGap
    }

    /// Default thresholds tuned per pipeline type
    static func defaults(for pipeline: PipelineType) -> ThresholdProfile {
        return defaults(for: pipeline.defaultScoreType)
    }

    /// Default thresholds by score type
    static func defaults(for scoreType: ScoreType) -> ThresholdProfile {
        switch scoreType {
        case .cosineSimilarity:
            return ThresholdProfile(matchThreshold: 0.90)
        case .rerankerProbability:
            return ThresholdProfile(matchThreshold: 0.75)
        case .llmSelected:
            return ThresholdProfile(matchThreshold: 0.90)
        case .generativeSelection:
            return ThresholdProfile(matchThreshold: 0.70)
        case .llmRejected:
            return ThresholdProfile(matchThreshold: 1.0)
        case .apiFallback:
            return ThresholdProfile(matchThreshold: 0.90)
        case .noScore:
            return ThresholdProfile(matchThreshold: 1.0)
        }
    }

    // MARK: - Codable backward compatibility

    enum CodingKeys: String, CodingKey {
        case matchThreshold, likelyMatchThreshold, unlikelyMatchThreshold, minimumGap
        // Legacy keys
        case acceptThreshold, rejectThreshold, gapThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minimumGap = try container.decodeIfPresent(Double.self, forKey: .minimumGap) ?? 0.05

        // Try new keys first, fall back to legacy keys
        if let match = try container.decodeIfPresent(Double.self, forKey: .matchThreshold) {
            matchThreshold = match
            likelyMatchThreshold = try container.decodeIfPresent(Double.self, forKey: .likelyMatchThreshold) ?? 0.85
            unlikelyMatchThreshold = try container.decodeIfPresent(Double.self, forKey: .unlikelyMatchThreshold) ?? 0.84
        } else {
            matchThreshold = try container.decodeIfPresent(Double.self, forKey: .acceptThreshold) ?? 0.90
            likelyMatchThreshold = try container.decodeIfPresent(Double.self, forKey: .gapThreshold) ?? 0.85
            unlikelyMatchThreshold = try container.decodeIfPresent(Double.self, forKey: .rejectThreshold) ?? 0.84
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(matchThreshold, forKey: .matchThreshold)
        try container.encode(likelyMatchThreshold, forKey: .likelyMatchThreshold)
        try container.encode(unlikelyMatchThreshold, forKey: .unlikelyMatchThreshold)
        try container.encode(minimumGap, forKey: .minimumGap)
    }
}

/// A single candidate match from top-N retrieval.
/// Stored alongside the top-1 match in MatchResult to support review workflow.
struct MatchCandidate: Codable, Identifiable, Hashable {
    let id: UUID
    let matchText: String
    let matchID: String?
    let score: Double
    let additionalFields: [String: String]?

    init(
        id: UUID = UUID(),
        matchText: String,
        matchID: String? = nil,
        score: Double,
        additionalFields: [String: String]? = nil
    ) {
        self.id = id
        self.matchText = matchText
        self.matchID = matchID
        self.score = score
        self.additionalFields = additionalFields
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Status classification for a match result
enum MatchStatus: String, Codable, CaseIterable, Identifiable {
    case match = "match"
    case llmMatch = "llm_match"
    case noMatch = "no_match"
    case error = "error"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .match: return "Matched"
        case .llmMatch: return "LLM"
        case .noMatch: return "None"
        case .error: return "Error"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .match: return "Matched"
        case .llmMatch: return "Matched by LLM"
        case .noMatch: return "No match found"
        case .error: return "Error occurred"
        }
    }
}

/// Result of matching a single input food description
struct MatchResult: Identifiable, Codable, Hashable {
    let id: UUID
    let inputText: String
    let inputRow: Int
    let matchText: String?
    let matchID: String?
    let score: Double
    let status: MatchStatus
    let scoreType: ScoreType
    let llmReasoning: String?
    /// Additional fields from the target database entry (e.g. common_name, citation)
    let matchAdditionalFields: [String: String]?
    /// Top-N candidates sorted by score descending. nil for sessions saved before this feature.
    let candidates: [MatchCandidate]?

    var isMatched: Bool {
        status == .match || status == .llmMatch
    }

    var scorePercentage: Int {
        Int(score * 100)
    }

    /// Compute effective status based on current threshold (legacy, for chart/stat compatibility)
    func effectiveStatus(threshold: Double) -> MatchStatus {
        if status == .error { return .error }
        if status == .llmMatch { return .llmMatch }
        return score >= threshold ? .match : .noMatch
    }

    /// Check if result matches at given threshold
    func isMatched(at threshold: Double) -> Bool {
        let effective = effectiveStatus(threshold: threshold)
        return effective == .match || effective == .llmMatch
    }

    init(
        id: UUID = UUID(),
        inputText: String,
        inputRow: Int,
        matchText: String? = nil,
        matchID: String? = nil,
        score: Double,
        status: MatchStatus,
        scoreType: ScoreType = .cosineSimilarity,
        llmReasoning: String? = nil,
        matchAdditionalFields: [String: String]? = nil,
        candidates: [MatchCandidate]? = nil
    ) {
        self.id = id
        self.inputText = inputText
        self.inputRow = inputRow
        self.matchText = matchText
        self.matchID = matchID
        self.score = score
        self.status = status
        self.scoreType = scoreType
        self.llmReasoning = llmReasoning
        self.matchAdditionalFields = matchAdditionalFields
        self.candidates = candidates
    }

    // Custom decoding for backward compatibility with sessions saved before scoreType/candidates
    enum CodingKeys: String, CodingKey {
        case id, inputText, inputRow, matchText, matchID, score, status, scoreType
        case llmReasoning, matchAdditionalFields, candidates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        inputText = try container.decode(String.self, forKey: .inputText)
        inputRow = try container.decode(Int.self, forKey: .inputRow)
        matchText = try container.decodeIfPresent(String.self, forKey: .matchText)
        matchID = try container.decodeIfPresent(String.self, forKey: .matchID)
        score = try container.decode(Double.self, forKey: .score)
        status = try container.decode(MatchStatus.self, forKey: .status)
        scoreType = try container.decodeIfPresent(ScoreType.self, forKey: .scoreType) ?? .cosineSimilarity
        llmReasoning = try container.decodeIfPresent(String.self, forKey: .llmReasoning)
        matchAdditionalFields = try container.decodeIfPresent([String: String].self, forKey: .matchAdditionalFields)
        candidates = try container.decodeIfPresent([MatchCandidate].self, forKey: .candidates)
    }

    /// Whether a candidate is the same item the pipeline chose as the top match.
    /// Uses matchID when available (reliable), falls back to matchText comparison.
    func isPipelineMatch(_ candidate: MatchCandidate) -> Bool {
        if let candidateID = candidate.matchID, let resultID = self.matchID {
            return candidateID == resultID
        }
        if let matchText = self.matchText {
            return candidate.matchText == matchText
        }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MatchResult, rhs: MatchResult) -> Bool {
        lhs.id == rhs.id
    }
}
