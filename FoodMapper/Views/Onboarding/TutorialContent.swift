import SwiftUI

/// Complete tutorial content - 18 steps (0-17) for the on-rails experience
enum TutorialSteps {
    /// All tutorial steps in order
    static let all: [TutorialStep] = [
        // Step 0: Download Model
        TutorialStep(
            id: 0,
            title: "Download the Embedding Model",
            body: "FoodMapper needs a 640MB embedding model to match food descriptions. Click \"Download Model\" to get started. This is a one-time download.",
            icon: "arrow.down.circle",
            highlightAnchors: ["modelDownloadArea"],
            coachMarkPosition: .below,
            action: .waitForUserModelDownload,
            waitCondition: .modelDownloaded
        ),

        // Step 1: Welcome to FoodMapper
        TutorialStep(
            id: 1,
            title: "Welcome to FoodMapper",
            body: "Welcome to FoodMapper. These three cards are your starting points. You can start a new match, add your own databases, or explore the research methods behind this app.",
            icon: "house",
            highlightAnchors: ["welcomeActionCards"],
            coachMarkPosition: .below
        ),

        // Step 2: Start a New Match
        TutorialStep(
            id: 2,
            title: "Start a New Match",
            body: "Click \"New Match\" to begin. This is where you'll load your data and configure a matching session.",
            icon: "link.badge.plus",
            highlightAnchors: ["welcomeNewMatchCard"],
            coachMarkPosition: .right,
            action: .navigateToNewMatch
        ),

        // Step 3: Load Your Data
        TutorialStep(
            id: 3,
            title: "Load Your Data",
            body: "Start by loading a CSV or TSV file with food descriptions. If you need help, expand \"Need help preparing your data file?\" on this page to download a template or learn how to export your spreadsheet. For now, click \"Load Sample Dataset\" below to try our example file.",
            icon: "doc.badge.plus",
            highlightAnchors: ["fileDropZone"],
            coachMarkPosition: .below,
            showsLoadSampleButton: true
        ),

        // Step 4: Select the Description Column
        TutorialStep(
            id: 4,
            title: "Select the Description Column",
            body: "Choose which column contains the food descriptions to match. Pick \"Food_Description\" from the dropdown.",
            icon: "text.alignleft",
            highlightAnchors: ["columnPicker"],
            coachMarkPosition: .below,
            action: .selectColumn("Food_Description")
        ),

        // Step 5: Choose a Target Database
        TutorialStep(
            id: 5,
            title: "Choose a Target Database",
            body: "Select DFG2 from the database list. It has 256 food items, a good fit for our sample data. The \"+\" button next to the dropdown lets you add your own target databases anytime.",
            icon: "cylinder",
            highlightAnchors: ["setupDatabaseSection", "addDatabaseButton"],
            coachMarkPosition: .below,
            action: .selectDatabase("DFG2")
        ),

        // Step 6: Start Matching
        TutorialStep(
            id: 6,
            title: "Start Matching",
            body: "Click the Match button in the toolbar and FoodMapper will match your food descriptions against DFG2 using semantic similarity. Everything runs on your GPU, no data leaves your Mac.",
            icon: "play.circle",
            highlightAnchors: [],
            coachMarkPosition: .below,
            action: .runMatching,
            waitCondition: .matchingComplete,
            toolbarButtonPreview: ToolbarButtonPreview(systemImage: "play", label: "Match")
        ),

        // Step 7: Your Results
        TutorialStep(
            id: 7,
            title: "Your Results",
            body: "Each row shows your input, its best database match, a similarity score, and the match status. FoodMapper auto-matches high-confidence results, but you should always verify matches for accuracy.",
            icon: "tablecells",
            highlightAnchors: ["resultsTable"],
            coachMarkPosition: .centerBottom
        ),

        // Step 8: Match a Result
        TutorialStep(
            id: 8,
            title: "Match a Result",
            body: "Click \"Match\" to confirm this result is correct.",
            icon: "checkmark.circle",
            highlightAnchors: ["inspectorMatchButton"],
            coachMarkPosition: .left,
            action: .acceptCurrentMatch,
            waitCondition: .decisionMade,
            keyboardHints: [KeyboardHint(label: "Match", keys: "Return")]
        ),

        // Step 9: Reject a Match
        TutorialStep(
            id: 9,
            title: "Reject a Match",
            body: "Click \"No Match\" to reject this result. Use this when the suggested match doesn't fit.",
            icon: "xmark.circle",
            highlightAnchors: ["inspectorNoMatchButton"],
            coachMarkPosition: .left,
            action: .rejectCurrentMatch,
            waitCondition: .decisionMade,
            keyboardHints: [KeyboardHint(label: "No Match", keys: "Delete")]
        ),

        // Step 10: Pick an Alternative
        TutorialStep(
            id: 10,
            title: "Pick an Alternative",
            body: "The candidate list shows other possible matches ranked by score. Click any candidate to select it. During Guided Review, press 1\u{2013}5 to quickly pick a candidate by rank. If you don't see the right option, scroll down to Manual Override to search the full database.",
            icon: "arrow.triangle.swap",
            highlightAnchors: ["inspectorCandidates"],
            coachMarkPosition: .left,
            action: .selectCandidate(2),
            waitCondition: .decisionMade,
            keyboardHints: [KeyboardHint(label: "Select Candidate (Guided Review)", keys: "1\u{2013}5")]
        ),

        // Step 11: Reset a Decision
        TutorialStep(
            id: 11,
            title: "Reset a Decision",
            body: "Changed your mind? Click \"Reset Decision\" to undo your choice and return the item to its original state.",
            icon: "arrow.counterclockwise",
            highlightAnchors: ["inspectorResetButton"],
            coachMarkPosition: .left,
            action: .resetCurrentDecision,
            keyboardHints: [KeyboardHint(label: "Reset", keys: "R \u{00D7}2")]
        ),

        // Step 12: Filter by Category
        TutorialStep(
            id: 12,
            title: "Filter by Category",
            body: "Use the filter buttons at the top to find results you're looking for. \"Match\" shows confirmed items, \"Needs Review\" shows items still needing attention, and \"No Match\" shows rejected items.",
            icon: "line.3.horizontal.decrease.circle",
            highlightAnchors: ["filterPills"],
            coachMarkPosition: .below
        ),

        // Step 13: Multi-Select & Bulk Actions
        TutorialStep(
            id: 13,
            title: "Bulk Actions for Multiple Items",
            body: "Need to update multiple items at once? Click and drag to select several rows. With multiple rows selected, you'll see bulk action buttons: Match All, No Match All, and Reset All. You can also add a note that applies to all selected items.",
            icon: "hand.tap",
            highlightAnchors: ["resultsTable", "bulkActionsSection"],
            coachMarkPosition: .centerBottom,
            keyboardHints: [KeyboardHint(label: "Add to selection", keys: "\u{2318}+Click"), KeyboardHint(label: "Range select", keys: "\u{21E7}+Click")]
        ),

        // Step 14: Guided Review Mode (NEW)
        TutorialStep(
            id: 14,
            title: "Guided Review Mode",
            body: "For a structured workflow, click Start Guided Review in the toolbar. It filters to items needing review and auto-advances through them as you make decisions. When you're done, end the session from the same button.",
            icon: "play.circle",
            highlightAnchors: ["guidedReviewButton"],
            coachMarkPosition: .below,
            toolbarButtonPreview: ToolbarButtonPreview(systemImage: "play.circle", label: "Start Guided Review")
        ),

        // Step 15: Export Your Results
        TutorialStep(
            id: 15,
            title: "Export Your Results",
            body: "Click Export in the toolbar to save your results as a CSV or TSV file. The export includes all your decisions, scores, and matched entries.",
            icon: "square.and.arrow.up",
            highlightAnchors: [],
            coachMarkPosition: .below,
            toolbarButtonPreview: ToolbarButtonPreview(systemImage: "square.and.arrow.up", label: "Export"),
            keyboardHints: [KeyboardHint(label: "Export", keys: "\u{2318}E")]
        ),

        // Step 16: Return Home
        TutorialStep(
            id: 16,
            title: "Return Home",
            body: "Click Next to return to the home screen. Your session is saved automatically.",
            icon: "house",
            highlightAnchors: [],
            coachMarkPosition: .below,
            action: .navigateHome,
            waitCondition: .onHomePage
        ),

        // Step 17: Your Session History
        TutorialStep(
            id: 17,
            title: "Your Session History",
            body: "Your recent sessions appear here. Click \"View All\" for your full history. Sessions persist even after closing the app, so you can always pick up where you left off.",
            icon: "clock.arrow.circlepath",
            highlightAnchors: ["recentSessionsArea", "viewAllSessions"],
            coachMarkPosition: .above
        )
    ]

    /// Get a specific step by index
    static func step(at index: Int) -> TutorialStep? {
        guard index >= 0 && index < all.count else { return nil }
        return all[index]
    }

    /// Total number of steps
    static var count: Int { all.count }
}
