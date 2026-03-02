import SwiftUI
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

extension AppState {

    // MARK: - Off-Main-Thread Computation Helpers

    /// Compute the effective ThresholdProfile for score bar coloring.
    func effectiveProfile() -> ThresholdProfile {
        AppState.effectiveProfile(
            userMatchThreshold: userMatchThreshold,
            userRejectThreshold: userRejectThreshold,
            pipelineType: selectedPipelineType
        )
    }

    /// Static version for off-main-thread use.
    /// Returns a ThresholdProfile for score bar coloring (no longer used for categorization).
    nonisolated static func effectiveProfile(
        userMatchThreshold: Double?,
        userRejectThreshold: Double?,
        pipelineType: PipelineType
    ) -> ThresholdProfile {
        ThresholdProfile.defaults(for: pipelineType)
    }

    /// Compute the triage decision for a single result based on pipeline decisions.
    /// No longer uses score thresholds for categorization.
    ///
    /// Smart auto-match: for embedding-only results (cosineSimilarity), if the top score
    /// is above `autoMatchScoreFloor` and the gap to the second candidate exceeds
    /// `autoMatchMinGap`, the result is promoted to autoMatch. This avoids sending
    /// obvious high-confidence matches to the review queue. Tuned for GTE-Large.
    nonisolated static func triageDecision(
        for result: MatchResult,
        profile: ThresholdProfile,
        pipelineType: PipelineType,
        autoMatchScoreFloor: Double = 0.95,
        autoMatchMinGap: Double = 0.01
    ) -> ReviewDecision {
        // Error results
        if result.status == .error {
            return ReviewDecision(status: .skipped)
        }

        // No match (nil matchText means nothing was selected above floor)
        if result.status == .noMatch && result.matchText == nil {
            return ReviewDecision(status: .autoNoMatch, reviewedAt: Date())
        }

        // Pipeline-specific triage
        switch result.scoreType {
        case .llmSelected:
            if result.status == .llmMatch {
                return ReviewDecision(status: .autoMatch, reviewedAt: Date())
            } else {
                return ReviewDecision(status: .autoNeedsReview, reviewedAt: Date())
            }
        case .llmRejected:
            return ReviewDecision(status: .autoNoMatch, reviewedAt: Date())
        case .apiFallback:
            return ReviewDecision(status: .autoNeedsReview, reviewedAt: Date())
        case .cosineSimilarity:
            // Auto-match only for GTE-Large pipelines (tuned for their score distribution).
            // Qwen3-Embedding also produces cosineSimilarity but its scores aren't calibrated
            // for auto-match thresholds yet, so everything goes to review.
            let isGTEPipeline = (pipelineType == .gteLargeEmbedding ||
                                 pipelineType == .gteLargeHaiku ||
                                 pipelineType == .gteLargeHaikuV2)
            if isGTEPipeline,
               result.score >= autoMatchScoreFloor,
               let candidates = result.candidates,
               candidates.count >= 2 {
                let gap = candidates[0].score - candidates[1].score
                if gap > autoMatchMinGap {
                    return ReviewDecision(status: .autoMatch, reviewedAt: Date())
                }
            }
            return ReviewDecision(status: .autoNeedsReview, reviewedAt: Date())
        case .rerankerProbability, .generativeSelection:
            return ReviewDecision(status: .autoNeedsReview, reviewedAt: Date())
        case .noScore:
            return ReviewDecision(status: .autoNoMatch, reviewedAt: Date())
        }
    }

    /// Legacy bridge: resolve effective thresholds for code that still uses (accept, reject) tuple.
    nonisolated static func effectiveThresholds(
        userAccept: Double?,
        userReject: Double?,
        profile: ThresholdProfile
    ) -> (accept: Double, reject: Double) {
        let accept = userAccept ?? profile.matchThreshold
        let reject = userReject ?? profile.unlikelyMatchThreshold
        return (accept, reject)
    }

    /// Compute triage decisions without touching @Published state.
    /// Safe to call from any thread. Returns a new decisions dictionary.
    nonisolated static func computeTriageDecisions(
        results: [MatchResult],
        existingDecisions: [UUID: ReviewDecision],
        pipelineType: PipelineType,
        userMatchThreshold: Double?,
        userRejectThreshold: Double?,
        autoMatchScoreFloor: Double = 0.95,
        autoMatchMinGap: Double = 0.01
    ) -> [UUID: ReviewDecision] {
        var decisions = existingDecisions
        let profile = effectiveProfile(
            userMatchThreshold: userMatchThreshold,
            userRejectThreshold: userRejectThreshold,
            pipelineType: pipelineType
        )

        for result in results {
            if let existing = decisions[result.id], existing.status.isHumanDecision {
                continue
            }
            decisions[result.id] = triageDecision(
                for: result,
                profile: profile,
                pipelineType: pipelineType,
                autoMatchScoreFloor: autoMatchScoreFloor,
                autoMatchMinGap: autoMatchMinGap
            )
        }
        return decisions
    }

    /// Compute filtered + review-mode-sorted results without touching @Published state.
    /// Safe to call from any thread.
    nonisolated static func computeFilteredSortedResults(
        results: [MatchResult],
        reviewDecisions: [UUID: ReviewDecision],
        filter: ResultsFilter,
        searchText: String,
        profile: ThresholdProfile
    ) -> [MatchResult] {
        var filtered = results.filter { result in
            if filter != .all {
                let isError = result.status == .error
                let category = MatchCategory.from(result: result, decision: reviewDecisions[result.id], profile: profile)
                if !filter.matches(category: category, isError: isError) { return false }
            }
            if !searchText.isEmpty {
                let lower = searchText.lowercased()
                let trimmed = searchText.trimmingCharacters(in: .whitespaces)
                // Exact row number match (e.g. "42" matches row 42, not 142)
                if "\(result.inputRow + 1)" == trimmed { return true }
                return result.inputText.lowercased().contains(lower) ||
                       (result.matchText?.lowercased().contains(lower) ?? false)
            }
            return true
        }

        // Review-mode sort: uncertain items first, then confident, then no-match
        filtered.sort { a, b in
            let catA = MatchCategory.from(result: a, decision: reviewDecisions[a.id], profile: profile)
            let catB = MatchCategory.from(result: b, decision: reviewDecisions[b.id], profile: profile)
            if catA.sortPriority != catB.sortPriority { return catA.sortPriority < catB.sortPriority }
            return a.score > b.score
        }
        return filtered
    }

    /// Classify results into four zones after matching completes.
    /// Match (high), likely match (medium-high), unlikely match (medium-low), no match (low).
    /// Classify results into four zones. Optional completion block runs after decisions are assigned
    /// (needed because large datasets triage on a background thread).
    func triageResults(then completion: (() -> Void)? = nil) {
        let allResults = results
        let existing = reviewDecisions
        let pipelineType = selectedPipelineType
        let userMatch = userMatchThreshold
        let userReject = userRejectThreshold
        let scoreFloor = autoMatchScoreFloor
        let minGap = autoMatchMinGap

        if allResults.count > 2_000 {
            isSorting = true
            Task.detached { [weak self] in
                let decisions = AppState.computeTriageDecisions(
                    results: allResults,
                    existingDecisions: existing,
                    pipelineType: pipelineType,
                    userMatchThreshold: userMatch,
                    userRejectThreshold: userReject,
                    autoMatchScoreFloor: scoreFloor,
                    autoMatchMinGap: minGap
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.reviewDecisions = decisions
                    self.rebuildAllCategories()
                    self.isSorting = false
                    self.saveReviewDecisions()
                    completion?()
                    self.updateFilteredResults(skipCategoryRebuild: true)
                }
            }
        } else {
            let profile = effectiveProfile()
            for result in allResults {
                if let existing = reviewDecisions[result.id], existing.status.isHumanDecision {
                    continue
                }
                reviewDecisions[result.id] = AppState.triageDecision(
                    for: result,
                    profile: profile,
                    pipelineType: pipelineType,
                    autoMatchScoreFloor: scoreFloor,
                    autoMatchMinGap: minGap
                )
            }
            rebuildAllCategories()
            saveReviewDecisions()
            completion?()
        }
    }

    /// Save review decisions to a separate JSON file alongside the session results.
    func saveReviewDecisions() {
        guard let sessionId = currentSessionId else { return }

        let filename = "\(sessionId.uuidString)_reviews.json"
        let url = sessionsDirectory.appendingPathComponent(filename)

        do {
            let data = try JSONEncoder().encode(reviewDecisions)
            try data.write(to: url, options: .atomic)

            // Update the session to record the review filename
            if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].reviewDecisionsFilename = filename
                saveSessionsIndex()
            }
        } catch {
            logger.error("Failed to save review decisions: \(error)")
        }
    }

    /// Load review decisions for a session.
    func loadReviewDecisions(for session: MatchingSession) {
        guard let filename = session.reviewDecisionsFilename else {
            reviewDecisions.removeAll()
            rebuildAllCategories()
            return
        }

        let url = sessionsDirectory.appendingPathComponent(filename)
        do {
            let data = try Data(contentsOf: url)
            reviewDecisions = try JSONDecoder().decode([UUID: ReviewDecision].self, from: data)
        } catch {
            logger.error("Failed to load review decisions: \(error)")
            reviewDecisions.removeAll()
        }
        rebuildAllCategories()
    }

    /// Load review decisions from disk without modifying app state (for export).
    func loadReviewDecisionsFromDisk(for session: MatchingSession) -> [UUID: ReviewDecision] {
        guard let filename = session.reviewDecisionsFilename else { return [:] }
        let url = sessionsDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let decisions = try? JSONDecoder().decode([UUID: ReviewDecision].self, from: data) else { return [:] }
        return decisions
    }

    /// Record a review decision for a specific result (with undo support).
    func setReviewDecision(_ status: ReviewStatus, for resultId: UUID, note: String? = nil,
                           overrideText: String? = nil, overrideID: String? = nil,
                           overrideScore: Double? = nil,
                           candidateIndex: Int? = nil) {
        // Push previous state to undo stack
        let previous = reviewDecisions[resultId]
        reviewUndoStack.append((resultId, previous))
        if reviewUndoStack.count > maxUndoStackSize {
            reviewUndoStack.removeFirst()
        }

        // When accepting/rejecting, carry forward existing override fields if none explicitly provided.
        // This prevents accepting an overridden result from destroying the override data.
        let finalOverrideText: String?
        let finalOverrideID: String?
        let finalOverrideScore: Double?
        let finalNote: String?
        let finalCandidateIndex: Int?

        if overrideText == nil, overrideID == nil, let existing = previous {
            if status == .accepted {
                // Accepting the pipeline's original match -- clear override fields
                finalOverrideText = nil
                finalOverrideID = nil
                finalOverrideScore = nil
                finalNote = note ?? existing.note
                finalCandidateIndex = candidateIndex ?? existing.selectedCandidateIndex
            } else {
                // Non-accept statuses (rejected, skipped) -- carry forward existing overrides
                finalOverrideText = existing.overrideMatchText
                finalOverrideID = existing.overrideMatchID
                finalOverrideScore = overrideScore ?? existing.overrideScore
                finalNote = note ?? existing.note
                finalCandidateIndex = candidateIndex ?? existing.selectedCandidateIndex
            }
        } else {
            finalOverrideText = overrideText
            finalOverrideID = overrideID
            finalOverrideScore = overrideScore
            finalNote = note
            finalCandidateIndex = candidateIndex
        }

        let newDecision = ReviewDecision(
            status: status,
            overrideMatchText: finalOverrideText,
            overrideMatchID: finalOverrideID,
            overrideScore: finalOverrideScore,
            note: finalNote,
            reviewedAt: Date(),
            selectedCandidateIndex: finalCandidateIndex
        )
        reviewDecisions[resultId] = newDecision
        reviewDecisionVersion += 1

        // Update single cache entry (O(1) via resultsByID index) + incremental count update
        if let result = resultsByID[resultId] {
            let oldCategory = cachedCategories[resultId] ?? .noMatch
            let newCategory = MatchCategory.from(result: result, decision: newDecision, profile: effectiveProfile())
            cachedCategories[resultId] = newCategory
            updateCategoryCount(oldCategory: oldCategory, newCategory: newCategory)
        }

        saveReviewDecisions()
    }

    /// Undo the last review decision. Returns the result ID that was undone (for selection).
    @discardableResult
    func undoLastReview() -> UUID? {
        guard let (resultId, previous) = reviewUndoStack.popLast() else { return nil }
        if let previous {
            reviewDecisions[resultId] = previous
        } else {
            reviewDecisions.removeValue(forKey: resultId)
        }
        reviewDecisionVersion += 1

        // Update single cache entry + incremental count update
        if let result = resultsByID[resultId] {
            let oldCategory = cachedCategories[resultId] ?? .noMatch
            let newCategory = MatchCategory.from(result: result, decision: reviewDecisions[resultId], profile: effectiveProfile())
            cachedCategories[resultId] = newCategory
            updateCategoryCount(oldCategory: oldCategory, newCategory: newCategory)
        }

        saveReviewDecisions()
        return resultId
    }

    /// Whether there are review actions that can be undone.
    var canUndoReview: Bool {
        !reviewUndoStack.isEmpty
    }

    /// Reset a single result to its auto-triage state.
    /// Pushes the current decision onto the undo stack before re-triaging.
    func resetToOriginalTriage(for resultId: UUID) {
        guard let result = resultsByID[resultId] else { return }

        // Push current state to undo stack
        let previous = reviewDecisions[resultId]
        reviewUndoStack.append((resultId, previous))
        if reviewUndoStack.count > maxUndoStackSize {
            reviewUndoStack.removeFirst()
        }

        let profile = effectiveProfile()
        let newDecision = AppState.triageDecision(
            for: result,
            profile: profile,
            pipelineType: selectedPipelineType,
            autoMatchScoreFloor: autoMatchScoreFloor,
            autoMatchMinGap: autoMatchMinGap
        )
        reviewDecisions[resultId] = newDecision
        reviewDecisionVersion += 1

        // Update single cache entry + incremental count update
        let oldCategory = cachedCategories[resultId] ?? .noMatch
        let newCategory = MatchCategory.from(result: result, decision: newDecision, profile: profile)
        cachedCategories[resultId] = newCategory
        updateCategoryCount(oldCategory: oldCategory, newCategory: newCategory)

        saveReviewDecisions()
    }

    /// Begin or execute the press-twice reset confirmation flow.
    /// Returns true if the reset was executed (second press), false if first press (pending).
    @discardableResult
    func handleResetConfirmation(for resultId: UUID) -> Bool {
        if resetPendingConfirmation {
            cancelResetConfirmation()
            resetToOriginalTriage(for: resultId)
            return true
        } else {
            resetPendingConfirmation = true
            let workItem = DispatchWorkItem { [weak self] in
                self?.resetPendingConfirmation = false
            }
            resetConfirmationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
            return false
        }
    }

    /// Cancel any pending reset confirmation timer.
    func cancelResetConfirmation() {
        resetConfirmationWorkItem?.cancel()
        resetConfirmationWorkItem = nil
        resetPendingConfirmation = false
    }

    /// Whether a result has a human review decision (not auto-triaged or pending).
    func hasHumanDecision(for resultId: UUID) -> Bool {
        guard let decision = reviewDecisions[resultId] else { return false }
        let humanStatuses: Set<ReviewStatus> = [.accepted, .rejected, .overridden, .skipped]
        return humanStatuses.contains(decision.status)
    }

    // MARK: - Bulk Actions

    /// Set all specified items to Match (accepted). Rebuilds caches once at the end.
    func bulkSetMatch(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let profile = effectiveProfile()
        for id in ids {
            let previous = reviewDecisions[id]
            reviewUndoStack.append((id, previous))
            if reviewUndoStack.count > maxUndoStackSize {
                reviewUndoStack.removeFirst()
            }
            // Carry forward existing override fields
            let finalOverrideText = previous?.overrideMatchText
            let finalOverrideID = previous?.overrideMatchID
            let finalOverrideScore = previous?.overrideScore
            let finalNote = previous?.note
            let finalCandidateIndex = previous?.selectedCandidateIndex
            let newDecision = ReviewDecision(
                status: .accepted,
                overrideMatchText: finalOverrideText,
                overrideMatchID: finalOverrideID,
                overrideScore: finalOverrideScore,
                note: finalNote,
                reviewedAt: Date(),
                selectedCandidateIndex: finalCandidateIndex
            )
            reviewDecisions[id] = newDecision
            if let result = resultsByID[id] {
                cachedCategories[id] = MatchCategory.from(result: result, decision: newDecision, profile: profile)
            }
        }
        reviewDecisionVersion += 1
        rebuildCategoryCounts()
        saveReviewDecisions()
        updateFilteredResults(skipCategoryRebuild: true)
        if isReviewMode { autoSelectFirstNeedsReview() }
    }

    /// Set all specified items to No Match (rejected). Rebuilds caches once at the end.
    func bulkSetNoMatch(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let profile = effectiveProfile()
        for id in ids {
            let previous = reviewDecisions[id]
            reviewUndoStack.append((id, previous))
            if reviewUndoStack.count > maxUndoStackSize {
                reviewUndoStack.removeFirst()
            }
            let newDecision = ReviewDecision(
                status: .rejected,
                overrideMatchText: previous?.overrideMatchText,
                overrideMatchID: previous?.overrideMatchID,
                note: previous?.note,
                reviewedAt: Date(),
                selectedCandidateIndex: previous?.selectedCandidateIndex
            )
            reviewDecisions[id] = newDecision
            if let result = resultsByID[id] {
                cachedCategories[id] = MatchCategory.from(result: result, decision: newDecision, profile: profile)
            }
        }
        reviewDecisionVersion += 1
        rebuildCategoryCounts()
        saveReviewDecisions()
        updateFilteredResults(skipCategoryRebuild: true)
        if isReviewMode { autoSelectFirstNeedsReview() }
    }

    /// Reset all specified items to their original auto-triage state.
    func bulkReset(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let profile = effectiveProfile()
        for id in ids {
            guard let result = resultsByID[id] else { continue }
            let previous = reviewDecisions[id]
            reviewUndoStack.append((id, previous))
            if reviewUndoStack.count > maxUndoStackSize {
                reviewUndoStack.removeFirst()
            }
            let newDecision = AppState.triageDecision(
                for: result,
                profile: profile,
                pipelineType: selectedPipelineType,
                autoMatchScoreFloor: autoMatchScoreFloor,
                autoMatchMinGap: autoMatchMinGap
            )
            reviewDecisions[id] = newDecision
            cachedCategories[id] = MatchCategory.from(result: result, decision: newDecision, profile: profile)
        }
        reviewDecisionVersion += 1
        rebuildCategoryCounts()
        saveReviewDecisions()
        updateFilteredResults(skipCategoryRebuild: true)
        if isReviewMode { autoSelectFirstNeedsReview() }
    }

    /// Apply a note to all specified items. Creates a ReviewDecision if one doesn't exist.
    func bulkSetNote(ids: Set<UUID>, note: String) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if var decision = reviewDecisions[id] {
                decision.note = note.isEmpty ? nil : note
                reviewDecisions[id] = decision
            } else {
                // Create a pending decision just to hold the note
                reviewDecisions[id] = ReviewDecision(
                    status: .pending,
                    note: note.isEmpty ? nil : note
                )
            }
        }
        saveReviewDecisions()
    }

    /// Begin or execute the press-twice bulk reset confirmation flow.
    /// Returns true if the reset was executed (second press), false if first press (pending).
    @discardableResult
    func handleBulkResetConfirmation(ids: Set<UUID>) -> Bool {
        if bulkResetPendingConfirmation {
            cancelBulkResetConfirmation()
            bulkReset(ids: ids)
            return true
        } else {
            bulkResetPendingConfirmation = true
            let workItem = DispatchWorkItem { [weak self] in
                self?.bulkResetPendingConfirmation = false
            }
            bulkResetConfirmationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
            return false
        }
    }

    /// Cancel any pending bulk reset confirmation timer.
    func cancelBulkResetConfirmation() {
        bulkResetConfirmationWorkItem?.cancel()
        bulkResetConfirmationWorkItem = nil
        bulkResetPendingConfirmation = false
    }

    /// Move selection to the next item needing review in filtered results (wraps around).
    /// Only advances in Guided Review mode -- outside review, selection stays on current row.
    func advanceToNextPending() {
        guard isReviewMode else { return }
        let currentResults = cachedFilteredResults
        guard let currentId = selection.first,
              let currentIndex = currentResults.firstIndex(where: { $0.id == currentId }) else { return }

        // Search forward from current position
        for i in (currentIndex + 1)..<currentResults.count {
            let result = currentResults[i]
            if cachedCategories[result.id] == .needsReview {
                selection = [result.id]
                navigateToPageContaining(index: i)
                tableScrollTarget = result.id
                return
            }
        }

        // Wrap around from beginning
        for i in 0..<currentIndex {
            let result = currentResults[i]
            if cachedCategories[result.id] == .needsReview {
                selection = [result.id]
                navigateToPageContaining(index: i)
                tableScrollTarget = result.id
                return
            }
        }
    }

    /// Move selection to the previous item needing review in filtered results (wraps around).
    func advanceToPreviousPending() {
        let currentResults = cachedFilteredResults
        guard let currentId = selection.first,
              let currentIndex = currentResults.firstIndex(where: { $0.id == currentId }) else { return }

        // Search backward from current position
        for i in stride(from: currentIndex - 1, through: 0, by: -1) {
            let result = currentResults[i]
            if cachedCategories[result.id] == .needsReview {
                selection = [result.id]
                navigateToPageContaining(index: i)
                tableScrollTarget = result.id
                return
            }
        }

        // Wrap around from end
        for i in stride(from: currentResults.count - 1, through: currentIndex + 1, by: -1) {
            let result = currentResults[i]
            if cachedCategories[result.id] == .needsReview {
                selection = [result.id]
                navigateToPageContaining(index: i)
                tableScrollTarget = result.id
                return
            }
        }
    }

    /// Navigate to the page containing the given filtered results index.
    func navigateToPageContaining(index: Int) {
        let targetPage = index / pageSize
        if targetPage != currentPage {
            currentPage = targetPage
        }
    }
}
