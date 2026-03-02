import SwiftUI

// MARK: - Preview Mock State Factories
// Reusable AppState configurations for SwiftUI #Preview blocks.
// Stripped from release builds. See Xcode MCP preview workflow in memory.

@MainActor
enum PreviewHelpers {

    // MARK: - Mock Data Constants

    static let sampleColumns = ["food_description", "food_id", "quantity", "unit"]

    static let sampleRows: [[String: String]] = [
        ["food_description": "Grilled chicken breast", "food_id": "1001", "quantity": "1", "unit": "serving"],
        ["food_description": "Steamed brown rice", "food_id": "1002", "quantity": "0.5", "unit": "cup"],
        ["food_description": "Raw baby spinach", "food_id": "1003", "quantity": "2", "unit": "cups"],
        ["food_description": "Whole wheat bread", "food_id": "1004", "quantity": "2", "unit": "slices"],
        ["food_description": "Low-fat yogurt", "food_id": "1005", "quantity": "1", "unit": "container"],
        ["food_description": "Fresh orange juice", "food_id": "1006", "quantity": "8", "unit": "oz"],
        ["food_description": "Scrambled eggs", "food_id": "1007", "quantity": "2", "unit": "large"],
        ["food_description": "Baked salmon fillet", "food_id": "1008", "quantity": "6", "unit": "oz"],
        ["food_description": "Mixed green salad", "food_id": "1009", "quantity": "1", "unit": "bowl"],
        ["food_description": "Cheddar cheese slices", "food_id": "1010", "quantity": "2", "unit": "slices"],
    ]

    static let sampleResults: [MatchResult] = [
        MatchResult(inputText: "Grilled chicken breast", inputRow: 0, matchText: "Chicken, broilers or fryers, breast, meat only, cooked, roasted", matchID: "FDB001234", score: 0.94, status: .match, matchAdditionalFields: ["food_group": "Poultry Products"]),
        MatchResult(inputText: "Steamed brown rice", inputRow: 1, matchText: "Rice, brown, long-grain, cooked", matchID: "FDB002345", score: 0.91, status: .match, matchAdditionalFields: ["food_group": "Cereal Grains"]),
        MatchResult(inputText: "Raw baby spinach", inputRow: 2, matchText: "Spinach, raw", matchID: "FDB003456", score: 0.96, status: .match, matchAdditionalFields: ["food_group": "Vegetables"]),
        MatchResult(inputText: "Whole wheat bread", inputRow: 3, matchText: "Bread, whole-wheat, commercially prepared", matchID: "FDB004567", score: 0.89, status: .match, matchAdditionalFields: ["food_group": "Baked Products"]),
        MatchResult(inputText: "Low-fat yogurt", inputRow: 4, matchText: "Yogurt, fruit, low fat", matchID: "FDB005678", score: 0.87, status: .match, matchAdditionalFields: ["food_group": "Dairy"]),
        MatchResult(inputText: "Fresh orange juice", inputRow: 5, matchText: "Orange juice, raw", matchID: "FDB006789", score: 0.92, status: .match, matchAdditionalFields: ["food_group": "Fruits"]),
        MatchResult(inputText: "Scrambled eggs", inputRow: 6, matchText: "Egg, whole, cooked, scrambled", matchID: "FDB007890", score: 0.93, status: .match, matchAdditionalFields: ["food_group": "Dairy and Egg"]),
        MatchResult(inputText: "Baked salmon fillet", inputRow: 7, matchText: "Salmon, Atlantic, wild, cooked, dry heat", matchID: "FDB008901", score: 0.85, status: .match, matchAdditionalFields: ["food_group": "Finfish"]),
        MatchResult(inputText: "Mixed green salad", inputRow: 8, matchText: "Salad greens, mixed", matchID: "FDB009012", score: 0.78, status: .noMatch, matchAdditionalFields: ["food_group": "Vegetables"]),
        MatchResult(inputText: "Cheddar cheese slices", inputRow: 9, matchText: "Cheese, cheddar", matchID: "FDB010123", score: 0.90, status: .match, matchAdditionalFields: ["food_group": "Dairy"]),
    ]

    static let sampleSessions: [MatchingSession] = [
        MatchingSession(inputFileName: "fndds_all_ingredients.csv", databaseName: "FooDB", threshold: 0.85, totalCount: 2744, matchedCount: 2524, resultsFilename: "results_001.json", date: Date().addingTimeInterval(-72000), pipelineName: "GTE-Large Embedding"),
        MatchingSession(inputFileName: "asa24_input.csv", databaseName: "FooDB", threshold: 0.88, totalCount: 1198, matchedCount: 575, resultsFilename: "results_002.json", date: Date().addingTimeInterval(-86400), pipelineName: "Qwen3 Two-Stage"),
        MatchingSession(inputFileName: "asa24_input.csv", databaseName: "FooDB", threshold: 0.85, totalCount: 1198, matchedCount: 982, resultsFilename: "results_003.json", date: Date().addingTimeInterval(-86400), pipelineName: "GTE-Large Embedding"),
        MatchingSession(inputFileName: "fdc_id_description_50k.csv", databaseName: "FooDB", threshold: 0.85, totalCount: 49999, matchedCount: 36999, resultsFilename: "results_004.json", date: Date().addingTimeInterval(-172800), pipelineName: "GTE-Large Embedding"),
    ]

    static let sampleStoredFiles: [StoredInputFile] = [
        StoredInputFile(displayName: "fndds_all_ingredients.csv", originalFileName: "fndds_all_ingredients.csv", dateAdded: Date().addingTimeInterval(-172800), lastUsed: Date().addingTimeInterval(-72000), columnNames: ["food_description", "food_id", "food_group"], rowCount: 2744, fileSize: 245_000),
        StoredInputFile(displayName: "asa24_input.csv", originalFileName: "asa24_input.csv", dateAdded: Date().addingTimeInterval(-259200), lastUsed: Date().addingTimeInterval(-86400), columnNames: ["food_description", "recall_id", "meal_code"], rowCount: 1198, fileSize: 128_000),
        StoredInputFile(displayName: "fdc_id_description_50k.csv", originalFileName: "fdc_id_description_50k.csv", dateAdded: Date().addingTimeInterval(-345600), lastUsed: Date().addingTimeInterval(-172800), columnNames: ["food_description", "fdc_id"], rowCount: 49999, fileSize: 4_200_000),
        StoredInputFile(displayName: "sample_fndds_all_ingredients.csv", originalFileName: "sample_fndds_all_ingredients.csv", dateAdded: Date().addingTimeInterval(-432000), lastUsed: Date().addingTimeInterval(-345600), columnNames: ["food_description", "food_id"], rowCount: 15, fileSize: 1_800),
    ]

    static var sampleCustomDB: CustomDatabase {
        var db = CustomDatabase(
            displayName: "My Lab Foods",
            csvPath: "/Users/mock/lab_foods.csv",
            textColumn: "food_name",
            idColumn: "food_id",
            itemCount: 532,
            dateAdded: Date().addingTimeInterval(-604800)
        )
        db.sampleValues = ["Organic quinoa", "Greek yogurt, plain", "Tempeh, cooked"]
        return db
    }

    // MARK: - Mock InputFile

    static func mockInputFile() -> InputFile {
        InputFile(
            url: URL(fileURLWithPath: "/tmp/mock_survey_data.csv"),
            columns: sampleColumns,
            rowCount: sampleRows.count,
            rows: sampleRows,
            displayNameOverride: "survey_food_data.csv"
        )
    }

    // MARK: - State Factories

    /// Default empty state: Home page, no file loaded, simple mode
    static func emptyState() -> AppState {
        let state = AppState()
        state.sidebarSelection = .home
        state.showMatchSetup = false
        state.viewingResults = false
        state.isAdvancedMode = false
        state.threshold = 0.85
        state.sessions = sampleSessions
        state.storedInputFiles = sampleStoredFiles
        return state
    }

    /// Empty state in advanced mode
    static func emptyAdvancedState() -> AppState {
        let state = emptyState()
        state.isAdvancedMode = true
        return state
    }

    /// File loaded, column selected, database selected, ready to match (simple mode)
    static func readyToMatchState() -> AppState {
        let state = emptyState()
        state.showMatchSetup = true
        state.inputFile = mockInputFile()
        state.selectedColumn = "food_description"
        state.selectedDatabase = .builtIn(.fooDB)
        state.isAdvancedMode = false
        return state
    }

    /// File loaded, ready to match (advanced mode with pipeline visible)
    static func readyToMatchAdvancedState() -> AppState {
        let state = readyToMatchState()
        state.isAdvancedMode = true
        state.selectedPipelineType = .qwen3TwoStage
        state.selectedInstructionPreset = .bestMatch
        return state
    }

    /// File loaded but no column/database selected yet
    static func fileLoadedState() -> AppState {
        let state = emptyState()
        state.showMatchSetup = true
        state.inputFile = mockInputFile()
        state.selectedColumn = nil
        state.selectedDatabase = nil
        return state
    }

    /// Matching in progress: embedding phase
    static func processingEmbeddingState() -> AppState {
        let state = readyToMatchState()
        state.isProcessing = true
        state.matchingPhase = .embeddingInputs
        return state
    }

    /// Matching in progress: computing similarity
    static func processingSimilarityState() -> AppState {
        let state = readyToMatchState()
        state.isProcessing = true
        state.matchingPhase = .computingSimilarity
        return state
    }

    /// Matching in progress: reranking
    static func processingRerankingState() -> AppState {
        let state = readyToMatchState()
        state.isProcessing = true
        state.matchingPhase = .reranking(completed: 4, total: 10)
        return state
    }

    /// Matching in progress: batch API submitted
    static func processingBatchState() -> AppState {
        let state = readyToMatchState()
        state.isProcessing = true
        state.matchingPhase = .batchSubmitted(taskCount: 10)
        return state
    }

    /// Matching in progress: batch API processing
    static func processingBatchProgressState() -> AppState {
        let state = readyToMatchState()
        state.isProcessing = true
        state.matchingPhase = .batchProcessing(succeeded: 6, total: 10)
        return state
    }

    /// Results loaded, viewing results
    static func resultsState() -> AppState {
        let state = readyToMatchState()
        state.results = sampleResults
        state.viewingResults = true
        state.showMatchSetup = false
        state.isProcessing = false
        state.matchingPhase = .idle
        return state
    }

    /// Results loaded in advanced mode
    static func resultsAdvancedState() -> AppState {
        let state = resultsState()
        state.isAdvancedMode = true
        state.selectedPipelineType = .qwen3TwoStage
        return state
    }

    /// Database embedding in progress
    static func databaseEmbeddingState() -> AppState {
        let state = readyToMatchState()
        state.databaseEmbeddingStatus = .embedding(completed: 3500, total: 9912, databaseName: "FooDB", startTime: Date().addingTimeInterval(-45))
        return state
    }

    /// History page selected
    static func historyState() -> AppState {
        let state = emptyState()
        state.sidebarSelection = .history
        return state
    }

    /// Databases page selected
    static func databasesState() -> AppState {
        let state = emptyState()
        state.sidebarSelection = .databases
        state.customDatabases = [sampleCustomDB]
        return state
    }

    /// Input Files page selected
    static func inputFilesState() -> AppState {
        let state = emptyState()
        state.sidebarSelection = .inputFiles
        return state
    }

    /// Error state
    static func errorState() -> AppState {
        let state = readyToMatchState()
        state.error = .matchingFailed("Connection to embedding model timed out. Try reducing batch size in Settings > Advanced.")
        return state
    }

    /// Research validation mode
    static func researchModeState() -> AppState {
        let state = readyToMatchState()
        state.selectedPipelineMode = .researchValidation
        state.selectedPipelineType = .gteLargeEmbedding
        state.isAdvancedMode = true
        return state
    }

    /// Results with review decisions populated for banner preview.
    /// Simulates a triaged session: some auto-accepted, some pending, some auto-rejected.
    static func reviewBannerState() -> AppState {
        let state = resultsState()
        state.isReviewMode = true

        // Populate review decisions matching the sample results:
        // High scores -> autoAccepted, mid scores -> pending, low scores -> autoRejected
        for result in state.results {
            let decision: ReviewDecision
            if result.score >= 0.90 {
                decision = ReviewDecision(status: .autoMatch, reviewedAt: Date())
            } else if result.score < 0.80 {
                decision = ReviewDecision(status: .autoNoMatch, reviewedAt: Date())
            } else {
                decision = ReviewDecision(status: .autoNeedsReview, reviewedAt: Date())
            }
            state.reviewDecisions[result.id] = decision
        }
        return state
    }

    /// Completion overlay state: results with triage decisions and overlay visible.
    static func completionOverlayState() -> AppState {
        let state = resultsState()
        state.showCompletionOverlay = true
        for result in state.results {
            let decision: ReviewDecision
            if result.score >= 0.90 {
                decision = ReviewDecision(status: .autoMatch, reviewedAt: Date())
            } else if result.score < 0.80 {
                decision = ReviewDecision(status: .autoNoMatch, reviewedAt: Date())
            } else {
                decision = ReviewDecision(status: .autoNeedsReview, reviewedAt: Date())
            }
            state.reviewDecisions[result.id] = decision
        }
        return state
    }

    // MARK: - Candidate Data for Review Workflow

    /// Sample results with top-N candidate arrays for review inspector previews.
    static let sampleResultsWithCandidates: [MatchResult] = [
        MatchResult(
            inputText: "Grilled chicken breast", inputRow: 0,
            matchText: "Chicken, broilers or fryers, breast, meat only, cooked, roasted",
            matchID: "FDB001234", score: 0.94, status: .match,
            matchAdditionalFields: ["food_group": "Poultry Products"],
            candidates: [
                MatchCandidate(matchText: "Chicken, broilers or fryers, breast, meat only, cooked, roasted", matchID: "FDB001234", score: 0.94),
                MatchCandidate(matchText: "Chicken, broilers or fryers, thigh, meat only, cooked, roasted", matchID: "FDB001235", score: 0.89),
                MatchCandidate(matchText: "Chicken, broilers or fryers, leg, meat only, cooked, roasted", matchID: "FDB001236", score: 0.82),
                MatchCandidate(matchText: "Turkey, breast, meat only, roasted", matchID: "FDB001400", score: 0.71),
                MatchCandidate(matchText: "Duck, domesticated, breast, meat only, raw", matchID: "FDB001500", score: 0.65),
            ]
        ),
        MatchResult(
            inputText: "Steamed brown rice", inputRow: 1,
            matchText: "Rice, brown, long-grain, cooked",
            matchID: "FDB002345", score: 0.91, status: .match,
            matchAdditionalFields: ["food_group": "Cereal Grains"],
            candidates: [
                MatchCandidate(matchText: "Rice, brown, long-grain, cooked", matchID: "FDB002345", score: 0.91),
                MatchCandidate(matchText: "Rice, brown, medium-grain, cooked", matchID: "FDB002346", score: 0.88),
                MatchCandidate(matchText: "Rice, white, long-grain, regular, cooked", matchID: "FDB002400", score: 0.79),
                MatchCandidate(matchText: "Rice, wild, cooked", matchID: "FDB002500", score: 0.72),
                MatchCandidate(matchText: "Quinoa, cooked", matchID: "FDB002600", score: 0.61),
            ]
        ),
        MatchResult(
            inputText: "Raw baby spinach", inputRow: 2,
            matchText: "Spinach, raw",
            matchID: "FDB003456", score: 0.96, status: .match,
            matchAdditionalFields: ["food_group": "Vegetables"],
            candidates: [
                MatchCandidate(matchText: "Spinach, raw", matchID: "FDB003456", score: 0.96),
                MatchCandidate(matchText: "Spinach, frozen, chopped or leaf, unprepared", matchID: "FDB003457", score: 0.84),
                MatchCandidate(matchText: "Kale, raw", matchID: "FDB003500", score: 0.73),
            ]
        ),
        MatchResult(
            inputText: "Whole wheat bread", inputRow: 3,
            matchText: "Bread, whole-wheat, commercially prepared",
            matchID: "FDB004567", score: 0.89, status: .match,
            matchAdditionalFields: ["food_group": "Baked Products"],
            candidates: [
                MatchCandidate(matchText: "Bread, whole-wheat, commercially prepared", matchID: "FDB004567", score: 0.89),
                MatchCandidate(matchText: "Bread, wheat, toasted", matchID: "FDB004568", score: 0.83),
                MatchCandidate(matchText: "Bread, rye", matchID: "FDB004600", score: 0.68),
            ]
        ),
        MatchResult(
            inputText: "Low-fat yogurt", inputRow: 4,
            matchText: "Yogurt, fruit, low fat",
            matchID: "FDB005678", score: 0.87, status: .match,
            matchAdditionalFields: ["food_group": "Dairy"],
            candidates: [
                MatchCandidate(matchText: "Yogurt, fruit, low fat", matchID: "FDB005678", score: 0.87),
                MatchCandidate(matchText: "Yogurt, plain, low fat", matchID: "FDB005679", score: 0.85),
                MatchCandidate(matchText: "Yogurt, Greek, plain, nonfat", matchID: "FDB005700", score: 0.76),
            ]
        ),
        MatchResult(
            inputText: "Fresh orange juice", inputRow: 5,
            matchText: "Orange juice, raw",
            matchID: "FDB006789", score: 0.92, status: .match,
            matchAdditionalFields: ["food_group": "Fruits"]
        ),
        MatchResult(
            inputText: "Scrambled eggs", inputRow: 6,
            matchText: "Egg, whole, cooked, scrambled",
            matchID: "FDB007890", score: 0.93, status: .match,
            matchAdditionalFields: ["food_group": "Dairy and Egg"]
        ),
        MatchResult(
            inputText: "Baked salmon fillet", inputRow: 7,
            matchText: "Salmon, Atlantic, wild, cooked, dry heat",
            matchID: "FDB008901", score: 0.85, status: .match,
            matchAdditionalFields: ["food_group": "Finfish"]
        ),
        MatchResult(
            inputText: "Mixed green salad", inputRow: 8,
            matchText: "Salad greens, mixed",
            matchID: "FDB009012", score: 0.78, status: .noMatch,
            matchAdditionalFields: ["food_group": "Vegetables"]
        ),
        MatchResult(
            inputText: "Cheddar cheese slices", inputRow: 9,
            matchText: "Cheese, cheddar",
            matchID: "FDB010123", score: 0.90, status: .match,
            matchAdditionalFields: ["food_group": "Dairy"]
        ),
    ]

    /// Review mode state with candidates, decisions, and selection populated.
    /// Use for ReviewInspectorPanel and full review workflow previews.
    static func reviewModeState() -> AppState {
        let state = readyToMatchState()
        state.results = sampleResultsWithCandidates
        state.viewingResults = true
        state.showMatchSetup = false
        state.isProcessing = false
        state.matchingPhase = .idle
        state.isReviewMode = true

        // Set selection to first result so the inspector shows populated content
        if let firstId = state.results.first?.id {
            state.selection = [firstId]
        }

        // Populate review decisions with mixed statuses for realistic preview
        for result in state.results {
            let decision: ReviewDecision
            if result.score >= 0.92 {
                // High confidence -> auto-accepted
                decision = ReviewDecision(status: .autoMatch, reviewedAt: Date())
            } else if result.score < 0.80 {
                // Low confidence -> auto-rejected
                decision = ReviewDecision(status: .autoNoMatch, reviewedAt: Date())
            } else if result.inputText == "Whole wheat bread" {
                // One manually accepted example
                decision = ReviewDecision(status: .accepted, reviewedAt: Date())
            } else {
                // Remainder pending human review
                decision = ReviewDecision(status: .autoNeedsReview, reviewedAt: Date())
            }
            state.reviewDecisions[result.id] = decision
        }
        return state
    }
}
