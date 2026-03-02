import SwiftUI
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "tutorial")

/// Executes tutorial actions that perform automatic operations
@MainActor
class TutorialActionExecutor: ObservableObject {
    weak var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    /// Execute the given tutorial action
    func execute(_ action: TutorialAction) async {
        guard let appState = appState else { return }

        switch action {
        case .none:
            break

        case .waitForUserModelDownload:
            break

        case .loadSampleDataset:
            await loadTutorialDataset()

        case .selectColumn(let column):
            appState.selectedColumn = column

        case .selectDatabase(let name):
            selectDatabase(named: name)

        case .runMatching:
            appState.runMatching()

        case .navigateHome:
            appState.returnToWelcome()

        case .navigateToNewMatch:
            appState.startNewMatch()

        case .acceptCurrentMatch:
            if let resultId = appState.selection.first {
                appState.setReviewDecision(.accepted, for: resultId)
            }

        case .rejectCurrentMatch:
            if let resultId = appState.selection.first {
                appState.setReviewDecision(.rejected, for: resultId)
            }

        case .selectCandidate(let index):
            if let resultId = appState.selection.first,
               let result = appState.resultsByID[resultId],
               let candidates = result.candidates,
               index < candidates.count {
                let candidate = candidates[index]
                appState.setReviewDecision(
                    .overridden, for: resultId,
                    overrideText: candidate.matchText,
                    overrideID: candidate.matchID,
                    overrideScore: candidate.score,
                    candidateIndex: index
                )
            }

        case .resetCurrentDecision:
            if let resultId = appState.selection.first {
                appState.resetReviewDecisionForTutorial(for: resultId)
            }
        }
    }

    /// Load the bundled tutorial_foods.csv sample dataset
    private func loadTutorialDataset() async {
        guard let appState = appState else { return }

        // Find tutorial_foods.csv in the bundle
        guard let url = Bundle.main.url(
            forResource: "tutorial_foods",
            withExtension: "csv",
            subdirectory: "SampleData"
        ) else {
            // Fallback: try without subdirectory
            guard let url = Bundle.main.url(forResource: "tutorial_foods", withExtension: "csv") else {
                logger.error("Tutorial dataset not found in bundle")
                return
            }
            await appState.loadFile(from: url)
            return
        }

        await appState.loadFile(from: url)
    }

    /// Select a database by display name
    private func selectDatabase(named name: String) {
        guard let appState = appState else { return }

        // Check built-in databases first
        for db in BuiltInDatabase.allCases {
            if db.displayName == name {
                appState.selectedDatabase = .builtIn(db)
                return
            }
        }

        // Check custom databases
        if let customDb = appState.customDatabases.first(where: { $0.displayName == name }) {
            appState.selectedDatabase = .custom(customDb)
        }
    }

    /// Check if the current wait condition is satisfied
    func isWaitConditionSatisfied(_ condition: TutorialStep.WaitCondition) -> Bool {
        guard let appState = appState else { return true }

        switch condition {
        case .none:
            return true
        case .modelDownloaded:
            return appState.modelStatus.isReady
        case .matchingComplete:
            return !appState.isProcessing && !appState.results.isEmpty
        case .decisionMade:
            guard let selectedId = appState.selection.first else { return false }
            return appState.reviewDecisions[selectedId] != nil
                && appState.reviewDecisions[selectedId]?.status != .pending
        case .onHomePage:
            return appState.sidebarSelection == .home
                && !appState.showMatchSetup
                && !appState.viewingResults
        }
    }
}
