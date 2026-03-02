import Foundation
import SwiftUI

/// Review status for a single match result in the review workflow.
/// Auto-categories map to MatchCategory. Human decisions override auto-triage.
enum ReviewStatus: String, Codable, CaseIterable {
    // Auto-triage categories (pipeline-decision-based)
    case autoMatch           // Pipeline confident match (hybrid LLM only)
    case autoNeedsReview     // Pipeline uncertain, user should verify
    case autoNoMatch         // Pipeline: no match found

    // Human review decisions (unchanged)
    case accepted        // Human accepted the match
    case rejected        // Human rejected the match (marks as no match)
    case overridden      // Human selected a different candidate
    case skipped         // Human deferred review

    // Legacy cases (kept for backward compat decoding)
    case pending         // Legacy: maps to needsReview
    case autoAccepted    // Legacy: maps to match
    case autoRejected    // Legacy: maps to noMatch
    case autoLikelyMatch     // Legacy: maps to needsReview
    case autoUnlikelyMatch   // Legacy: maps to needsReview

    /// Whether this is a human-made decision (not auto-triaged)
    var isHumanDecision: Bool {
        switch self {
        case .accepted, .rejected, .overridden, .skipped:
            return true
        default:
            return false
        }
    }
}

/// A human review decision layered on top of a MatchResult.
/// Stored separately from MatchResult to keep original match data immutable.
struct ReviewDecision: Codable {
    var status: ReviewStatus
    /// If overridden, the text of the manually selected match
    var overrideMatchText: String?
    /// If overridden, the ID of the manually selected match
    var overrideMatchID: String?
    /// If overridden, the score of the manually selected match candidate
    var overrideScore: Double?
    /// Optional reviewer note
    var note: String?
    /// When this decision was made (nil for pending items)
    var reviewedAt: Date?
    /// Index of the selected candidate (0-based) if the user picked from the candidates list
    var selectedCandidateIndex: Int?
}

// MARK: - Unified Results Filter

/// Filter dimension for results table, based on MatchCategory.
enum ResultsFilter: String, CaseIterable, Identifiable {
    case all
    case match
    case needsReview
    case noMatch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .match: return "Match"
        case .needsReview: return "Needs Review"
        case .noMatch: return "No Match"
        }
    }

    /// Whether a result passes this filter given its MatchCategory.
    func matches(_ category: MatchCategory) -> Bool {
        switch self {
        case .all: return true
        case .match: return category == .match || category == .confirmedMatch
        case .needsReview: return category == .needsReview
        case .noMatch: return category == .noMatch || category == .confirmedNoMatch
        }
    }

    /// Whether a result passes this filter considering both category and error status.
    func matches(category: MatchCategory, isError: Bool) -> Bool {
        if isError { return self == .all || self == .noMatch }
        return matches(category)
    }
}
