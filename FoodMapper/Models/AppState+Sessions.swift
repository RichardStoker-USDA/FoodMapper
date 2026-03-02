import SwiftUI
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

extension AppState {

    // MARK: - Selection

    func selectAllMatched() {
        selection = Set(results.filter(\.isMatched).map(\.id))
    }

    // MARK: - Clear Results

    func clearResults() {
        results = []
        viewingResults = false
        selection = []
        searchText = ""
        resultsFilter = .all
        hasUnviewedResults = false
        pendingResults = nil
        currentSessionId = nil
        reviewDecisions.removeAll()
        cachedCategories.removeAll()
        cachedCategoryCounts.removeAll()
        resultsByID.removeAll()
        allUniqueCandidates.removeAll()
        reviewUndoStack.removeAll()
        isReviewMode = false
        showInspector = false
        showCompletionOverlay = false
        resultsReady = true
        dismissMatchCompleteBanner()
    }

    // MARK: - Match Complete Banner

    func dismissMatchCompleteBanner() {
        bannerDismissTask?.cancel()
        showMatchCompleteBanner = false
    }

    func scheduleBannerDismiss() {
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showMatchCompleteBanner = false
            }
        }
    }

    /// Navigate to completed results after matching finished while user was away
    func viewCompletedResults() {
        dismissMatchCompleteBanner()
        guard let pending = pendingResults else {
            hasUnviewedResults = false
            return
        }

        // Compute triage + filtered results off main thread
        let pipelineType = selectedPipelineType
        let userMatchThresh = userMatchThreshold
        let userRejectThresh = userRejectThreshold
        let autoMatchFloor = autoMatchScoreFloor
        let autoMatchGap = autoMatchMinGap

        Task {
            // Compute triage + sort on a background thread
            let (triageDecisions, sortedFiltered) = await Task.detached(priority: .userInitiated) {
                let profile = AppState.effectiveProfile(
                    userMatchThreshold: userMatchThresh,
                    userRejectThreshold: userRejectThresh,
                    pipelineType: pipelineType
                )
                let triage = AppState.computeTriageDecisions(
                    results: pending,
                    existingDecisions: [:],
                    pipelineType: pipelineType,
                    userMatchThreshold: userMatchThresh,
                    userRejectThreshold: userRejectThresh,
                    autoMatchScoreFloor: autoMatchFloor,
                    autoMatchMinGap: autoMatchGap
                )
                let filtered = AppState.computeFilteredSortedResults(
                    results: pending,
                    reviewDecisions: triage,
                    filter: .all,
                    searchText: "",
                    profile: profile
                )
                return (triage, filtered)
            }.value

            await MainActor.run {
                self.suppressFilterUpdates = true
                self.resultsReady = false

                self.results = pending
                self.pendingResults = nil
                if let savedId = self.pendingSessionId {
                    self.currentSessionId = savedId
                    self.pendingSessionId = nil
                }
                self.reviewDecisions = triageDecisions
                self.cachedUnsortedFilteredResults = sortedFiltered
                self.cachedFilteredResults = sortedFiltered
                self.currentPage = 0

                // Rebuild category caches before re-enabling filter updates
                self.rebuildAllCategories()

                self.suppressFilterUpdates = false

                self.hasUnviewedResults = false
                self.isProgrammaticNavigation = true
                self.viewingResults = true
                self.sidebarSelection = .home
                self.showMatchSetup = false
                self.sidebarVisibility = .detailOnly
                self.showInspector = true
                self.showCompletionOverlay = true
                self.isProgrammaticNavigation = false
                self.recordNavigationSnapshot()
            }

            // Heavy post-completion work: build candidate index + save session
            // off main thread, then flip resultsReady.
            let readyStart = ContinuousClock.now

            let (candidateIndex, preEncodedDecisions) = await Task.detached(priority: .userInitiated) {
                var seen = Set<String>()
                var unique: [MatchCandidate] = []
                for result in pending {
                    guard let candidates = result.candidates else { continue }
                    for candidate in candidates {
                        let key = candidate.matchText.lowercased()
                        guard !seen.contains(key) else { continue }
                        seen.insert(key)
                        unique.append(candidate)
                    }
                }
                let decisionsData = try? JSONEncoder().encode(triageDecisions)
                return (unique, decisionsData)
            }.value

            await MainActor.run {
                self.allUniqueCandidates = candidateIndex
                self.saveReviewDecisionsPreEncoded(preEncodedDecisions)
            }

            // Minimum 300ms display time to prevent flash
            let elapsed = ContinuousClock.now - readyStart
            if elapsed < .milliseconds(300) {
                try? await Task.sleep(for: .milliseconds(300) - elapsed)
            }

            await MainActor.run {
                self.resultsReady = true
            }
        }
    }

    // MARK: - Session Management

    func loadSessionsIndex() {
        guard FileManager.default.fileExists(atPath: sessionsIndexURL.path) else { return }
        do {
            let data = try Data(contentsOf: sessionsIndexURL)
            sessions = try JSONDecoder().decode([MatchingSession].self, from: data)
            sessions.sort { $0.date > $1.date }
        } catch {
            logger.error("Failed to load sessions index: \(error)")
        }
    }

    func saveSessionsIndex() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: sessionsIndexURL, options: .atomic)
        } catch {
            logger.error("Failed to save sessions index: \(error)")
        }
    }

    func saveSession(apiTokensUsed: Int? = nil) {
        guard !results.isEmpty, let inputFile = inputFile else { return }

        let sessionId = UUID()
        let resultsFilename = "\(sessionId.uuidString).json"
        let resultsURL = sessionsDirectory.appendingPathComponent(resultsFilename)

        do {
            let data = try JSONEncoder().encode(results)
            try data.write(to: resultsURL)
        } catch {
            logger.error("Failed to save session results: \(error)")
            return
        }

        // Link to stored input file if available
        let storedFileId = storedInputFiles.first(where: {
            $0.originalFileName == inputFile.name && $0.rowCount == inputFile.rowCount
        })?.id

        var session = MatchingSession(
            id: sessionId,
            inputFileName: inputFile.name,
            databaseName: selectedDatabase?.displayName ?? "Unknown",
            threshold: threshold,
            totalCount: results.count,
            matchedCount: matchedCount,
            resultsFilename: resultsFilename,
            pipelineName: selectedPipelineType.displayName,
            inputFileId: storedFileId,
            matchingInstruction: resolvedEmbeddingInstruction,
            selectedColumn: selectedColumn,
            targetTextColumn: selectedDatabase?.textColumn,
            targetIdColumn: selectedDatabase?.idColumn,
            targetColumnNames: selectedDatabase?.columnNames
        )
        session.apiTokensUsed = apiTokensUsed

        sessions.insert(session, at: 0)
        currentSessionId = sessionId
        saveSessionsIndex()
    }

    /// Save session using pre-encoded results data (avoids JSON encoding on main thread).
    /// The heavy JSONEncoder work happens on a background thread before this is called.
    func saveSessionPreEncoded(preEncodedResults: Data?, resultCount: Int, apiTokensUsed: Int? = nil) {
        guard resultCount > 0, let inputFile = inputFile, let data = preEncodedResults else { return }

        let sessionId = UUID()
        let resultsFilename = "\(sessionId.uuidString).json"
        let resultsURL = sessionsDirectory.appendingPathComponent(resultsFilename)

        do {
            try data.write(to: resultsURL)
        } catch {
            logger.error("Failed to save session results: \(error)")
            return
        }

        let storedFileId = storedInputFiles.first(where: {
            $0.originalFileName == inputFile.name && $0.rowCount == inputFile.rowCount
        })?.id

        var session = MatchingSession(
            id: sessionId,
            inputFileName: inputFile.name,
            databaseName: selectedDatabase?.displayName ?? "Unknown",
            threshold: threshold,
            totalCount: resultCount,
            matchedCount: matchedCount,
            resultsFilename: resultsFilename,
            pipelineName: selectedPipelineType.displayName,
            inputFileId: storedFileId,
            matchingInstruction: resolvedEmbeddingInstruction,
            selectedColumn: selectedColumn,
            targetTextColumn: selectedDatabase?.textColumn,
            targetIdColumn: selectedDatabase?.idColumn,
            targetColumnNames: selectedDatabase?.columnNames
        )
        session.apiTokensUsed = apiTokensUsed

        sessions.insert(session, at: 0)
        currentSessionId = sessionId
        saveSessionsIndex()
    }

    /// Save review decisions using pre-encoded data (avoids JSON encoding on main thread).
    func saveReviewDecisionsPreEncoded(_ preEncodedData: Data?) {
        guard let sessionId = currentSessionId, let data = preEncodedData else { return }

        let filename = "\(sessionId.uuidString)_reviews.json"
        let url = sessionsDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)

            if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].reviewDecisionsFilename = filename
                saveSessionsIndex()
            }
        } catch {
            logger.error("Failed to save review decisions: \(error)")
        }
    }

    /// Save a session from explicit results without touching self.results.
    /// Used when matching completes while the user is viewing something else.
    func saveSessionFromResults(_ matchResults: [MatchResult], apiTokensUsed: Int? = nil) {
        guard !matchResults.isEmpty, let inputFile = inputFile else { return }

        let sessionId = UUID()
        let resultsFilename = "\(sessionId.uuidString).json"
        let resultsURL = sessionsDirectory.appendingPathComponent(resultsFilename)

        do {
            let data = try JSONEncoder().encode(matchResults)
            try data.write(to: resultsURL)
        } catch {
            logger.error("Failed to save session results: \(error)")
            return
        }

        let matched = matchResults.filter { $0.isMatched(at: threshold) }.count

        let storedFileId = storedInputFiles.first(where: {
            $0.originalFileName == inputFile.name && $0.rowCount == inputFile.rowCount
        })?.id

        var session = MatchingSession(
            id: sessionId,
            inputFileName: inputFile.name,
            databaseName: selectedDatabase?.displayName ?? "Unknown",
            threshold: threshold,
            totalCount: matchResults.count,
            matchedCount: matched,
            resultsFilename: resultsFilename,
            pipelineName: selectedPipelineType.displayName,
            inputFileId: storedFileId,
            matchingInstruction: resolvedEmbeddingInstruction,
            selectedColumn: selectedColumn,
            targetTextColumn: selectedDatabase?.textColumn,
            targetIdColumn: selectedDatabase?.idColumn,
            targetColumnNames: selectedDatabase?.columnNames
        )
        session.apiTokensUsed = apiTokensUsed

        sessions.insert(session, at: 0)
        currentSessionId = sessionId
        saveSessionsIndex()
    }

    func loadSession(_ session: MatchingSession) {
        let resultsURL = sessionsDirectory.appendingPathComponent(session.resultsFilename)
        let sessionsDir = sessionsDirectory

        // Try to reload the input file from stored files for full-column export
        var reloadedInputFile: InputFile? = nil
        if let storedFileId = session.inputFileId,
           let stored = storedInputFiles.first(where: { $0.id == storedFileId }),
           FileManager.default.fileExists(atPath: stored.csvURL.path) {
            reloadedInputFile = try? CSVParser.parse(content: String(contentsOf: stored.csvURL, encoding: .utf8), url: stored.csvURL)
        }

        // Load data, decode, and sort off the main thread
        Task {
            do {
                let (loadedResults, loadedDecisions, filtered) = try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: resultsURL)
                    let results = try JSONDecoder().decode([MatchResult].self, from: data)

                    var decisions: [UUID: ReviewDecision] = [:]
                    if let reviewFilename = session.reviewDecisionsFilename {
                        let reviewURL = sessionsDir.appendingPathComponent(reviewFilename)
                        if let reviewData = try? Data(contentsOf: reviewURL),
                           let decoded = try? JSONDecoder().decode([UUID: ReviewDecision].self, from: reviewData) {
                            decisions = decoded
                        }
                    }

                    let sorted = results.sorted { $0.inputRow < $1.inputRow }
                    return (results, decisions, sorted)
                }.value

                await MainActor.run {
                    self.suppressFilterUpdates = true

                    self.results = loadedResults
                    self.threshold = session.threshold
                    self.currentSessionId = session.id

                    // Restore input file and column selection from session
                    self.inputFile = reloadedInputFile
                    self.selectedColumn = session.selectedColumn

                    // Restore database selection from session metadata
                    self.restoreDatabaseFromSession(session)

                    // Infer pipeline mode from session
                    if let pipelineType = PipelineType.allCases.first(where: { $0.displayName == session.pipelineName }) {
                        self.selectedPipelineMode = pipelineType.pipelineMode
                        self.selectedPipelineType = pipelineType
                    } else {
                        self.selectedPipelineMode = .researchValidation
                        self.selectedPipelineType = .gteLargeEmbedding
                    }

                    self.reviewDecisions = loadedDecisions
                    self.isReviewMode = false
                    self.resultsFilter = .all
                    self.searchText = ""
                    self.currentPage = 0
                    self.sortOrder = [.init(\.score, order: .reverse)]
                    self.sortDebounceTask?.cancel()
                    self.cachedUnsortedFilteredResults = filtered
                    self.cachedFilteredResults = filtered

                    // Rebuild caches before re-enabling filter updates
                    self.rebuildAllCategories()
                    self.buildCandidateIndex()

                    self.suppressFilterUpdates = false

                    self.isProgrammaticNavigation = true
                    self.viewingResults = true
                    self.sidebarSelection = .home
                    self.showMatchSetup = false
                    self.sidebarVisibility = .detailOnly
                    self.showInspector = true
                    self.hasUnviewedResults = false
                    self.isProgrammaticNavigation = false
                    self.recordNavigationSnapshot()
                }
            } catch {
                await MainActor.run {
                    self.error = AppError.fileLoadFailed("Failed to load session: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Restore selectedDatabase from session metadata (best-effort match by name)
    func restoreDatabaseFromSession(_ session: MatchingSession) {
        // Try built-in databases first
        if let builtIn = BuiltInDatabase.allCases.first(where: { $0.displayName == session.databaseName }) {
            selectedDatabase = .builtIn(builtIn)
            return
        }
        // Try custom databases
        if let custom = customDatabases.first(where: { $0.displayName == session.databaseName }) {
            selectedDatabase = .custom(custom)
            return
        }
        // Database no longer exists -- leave nil
        selectedDatabase = nil
    }

    /// Auto-save threshold and recalculated match count when user adjusts threshold on a loaded session
    func autoSaveThreshold() {
        guard let sessionId = currentSessionId,
              let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].threshold = threshold
        sessions[index].matchedCount = results.filter { $0.isMatched(at: threshold) }.count
        saveSessionsIndex()
    }

    func deleteSession(_ session: MatchingSession) {
        let resultsURL = sessionsDirectory.appendingPathComponent(session.resultsFilename)
        try? FileManager.default.removeItem(at: resultsURL)
        // Clean up review decisions file if it exists
        if let reviewFilename = session.reviewDecisionsFilename {
            let reviewURL = sessionsDirectory.appendingPathComponent(reviewFilename)
            try? FileManager.default.removeItem(at: reviewURL)
        }
        sessions.removeAll { $0.id == session.id }
        saveSessionsIndex()
    }

    func clearAllHistory() {
        for session in sessions {
            let resultsURL = sessionsDirectory.appendingPathComponent(session.resultsFilename)
            try? FileManager.default.removeItem(at: resultsURL)
            if let reviewFilename = session.reviewDecisionsFilename {
                let reviewURL = sessionsDirectory.appendingPathComponent(reviewFilename)
                try? FileManager.default.removeItem(at: reviewURL)
            }
        }
        sessions.removeAll()
        saveSessionsIndex()
    }

    func startNewMatch() {
        if selectedPipelineMode == nil {
            selectedPipelineMode = .standard
            selectedPipelineType = autoSelectPipeline(for: .standard)
        }
        sidebarSelection = .home
        showMatchSetup = true
        inputFile = nil
        selectedColumn = nil
        selectedDatabase = nil
        currentSessionId = nil
        threshold = 0.85
        clearResults()
    }

    func ensureSidebarVisible() {
        if sidebarVisibility != .all {
            sidebarVisibility = .all
        }
    }

    func focusSearch() {
        searchFieldFocused = true
    }

    /// Enter review mode: triage if needed, set filter, auto-select first needs-review item.
    /// Review mode only controls auto-advance behavior -- sidebar and inspector are
    /// managed by the results page layout, not by review mode.
    func enterReviewMode(filter: ResultsFilter = .needsReview) {
        if reviewDecisions.isEmpty {
            triageResults { [weak self] in
                self?.resultsFilter = filter
                self?.autoSelectFirstNeedsReview()
            }
        } else {
            resultsFilter = filter
            autoSelectFirstNeedsReview()
        }
        isReviewMode = true
    }

    /// Select the first item that needs review in the current filtered results.
    func autoSelectFirstNeedsReview() {
        if let index = cachedFilteredResults.firstIndex(where: {
            cachedCategories[$0.id] == .needsReview
        }) {
            let result = cachedFilteredResults[index]
            selection = [result.id]
            navigateToPageContaining(index: index)
            tableScrollTarget = result.id
        }
    }
}
