import SwiftUI

extension AppState {

    // MARK: - Navigation History

    func recordNavigationSnapshot() {
        guard !isProgrammaticNavigation else { return }

        let snapshot = NavigationSnapshot(
            sidebarSelection: sidebarSelection,
            showMatchSetup: showMatchSetup,
            viewingResults: viewingResults,
            selectedPipelineMode: selectedPipelineMode
        )

        // Skip duplicates
        if navigationHistoryIndex >= 0,
           navigationHistoryIndex < navigationHistory.count,
           navigationHistory[navigationHistoryIndex] == snapshot {
            return
        }

        // Trim forward history on new navigation
        if navigationHistoryIndex < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((navigationHistoryIndex + 1)...)
        }

        navigationHistory.append(snapshot)

        // Cap at 50 entries
        if navigationHistory.count > 50 {
            navigationHistory.removeFirst()
        }

        navigationHistoryIndex = navigationHistory.count - 1
    }

    func goBack() {
        guard canGoBack else { return }
        isProgrammaticNavigation = true
        navigationHistoryIndex -= 1
        applyNavigationSnapshot(navigationHistory[navigationHistoryIndex])
        isProgrammaticNavigation = false
    }

    func goForward() {
        guard canGoForward else { return }
        isProgrammaticNavigation = true
        navigationHistoryIndex += 1
        applyNavigationSnapshot(navigationHistory[navigationHistoryIndex])
        isProgrammaticNavigation = false
    }

    func applyNavigationSnapshot(_ snapshot: NavigationSnapshot) {
        sidebarSelection = snapshot.sidebarSelection
        selectedPipelineMode = snapshot.selectedPipelineMode

        if snapshot.viewingResults && !results.isEmpty {
            viewingResults = true
            showMatchSetup = false
            sidebarVisibility = .detailOnly
            showInspector = true
        } else {
            viewingResults = false
            showMatchSetup = snapshot.showMatchSetup
            sidebarVisibility = .all
        }
    }

    func returnToWelcome() {
        // Save review decisions before clearing session context
        saveReviewDecisions()

        isProgrammaticNavigation = true
        viewingResults = false
        sidebarSelection = .home
        showMatchSetup = false
        currentSessionId = nil
        showInspector = false
        isReviewMode = false
        sidebarVisibility = .all
        if isProcessing {
            userNavigatedAwayDuringMatching = true
        }
        isProgrammaticNavigation = false
        recordNavigationSnapshot()
    }

    // MARK: - Pipeline Mode

    func selectPipelineMode(_ mode: PipelineMode) {
        selectedPipelineMode = mode
        isSyncingPipeline = true
        enableHaikuVerification = false
        isSyncingPipeline = false
        selectedPipelineType = autoSelectPipeline(for: mode)
        recordNavigationSnapshot()

        // Research mode goes directly to the scrolling showcase
        if mode == .researchValidation {
            startResearchShowcase()
        }
    }

    /// Auto-select the best available pipeline for the given mode.
    /// Prefers higher-quality pipelines when the required models are downloaded.
    func autoSelectPipeline(for mode: PipelineMode) -> PipelineType {
        if mode == .researchValidation {
            return .gteLargeEmbedding
        }

        // Check if any Qwen3 embedding model is available (any size)
        let hasQwenEmbedding = ModelFamily.qwen3Embedding.availableSizes.contains { size in
            guard let key = ModelFamily.qwen3Embedding.modelKey(for: size) else { return false }
            return modelManager.state(for: key).isAvailable
        }

        // Check if any Qwen3 reranker model is available (any size)
        let hasQwenReranker = ModelFamily.qwen3Reranker.availableSizes.contains { size in
            guard let key = ModelFamily.qwen3Reranker.modelKey(for: size) else { return false }
            return modelManager.state(for: key).isAvailable
        }

        // Prefer two-stage (embedding + reranker) if both families available
        if hasQwenEmbedding && hasQwenReranker {
            return .qwen3TwoStage
        }

        // Fall back to embedding-only if available
        if hasQwenEmbedding {
            return .qwen3Embedding
        }

        // Default to GTE-Large (always available once downloaded)
        return .gteLargeEmbedding
    }
}
