import SwiftUI

/// Rendered inside the coach mark for steps that reference toolbar buttons
struct ToolbarButtonPreview: Equatable {
    let systemImage: String
    let label: String
}

/// Keyboard shortcut hint rendered below body text in coach marks
struct KeyboardHint: Equatable {
    let label: String
    let keys: String  // Parsed by parseKeySegments()
}

/// Defines the content and highlight targets for each tutorial step
struct TutorialStep: Identifiable, Equatable {
    let id: Int
    let title: String
    let body: String
    let icon: String
    let highlightAnchors: [String]
    let coachMarkPosition: CoachMarkPosition
    let action: TutorialAction
    let waitCondition: WaitCondition
    let showsLoadSampleButton: Bool
    let toolbarButtonPreview: ToolbarButtonPreview?
    let keyboardHints: [KeyboardHint]?

    /// Direction for coach mark positioning relative to highlighted element
    enum CoachMarkPosition: Equatable {
        case above
        case below
        case left
        case right
        case centerBottom
    }

    /// Conditions to wait for before allowing progression
    enum WaitCondition: Equatable {
        case none
        case modelDownloaded
        case matchingComplete
        case decisionMade
        case onHomePage
    }

    init(
        id: Int,
        title: String,
        body: String,
        icon: String,
        highlightAnchors: [String],
        coachMarkPosition: CoachMarkPosition,
        action: TutorialAction = .none,
        waitCondition: WaitCondition = .none,
        showsLoadSampleButton: Bool = false,
        toolbarButtonPreview: ToolbarButtonPreview? = nil,
        keyboardHints: [KeyboardHint]? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.icon = icon
        self.highlightAnchors = highlightAnchors
        self.coachMarkPosition = coachMarkPosition
        self.action = action
        self.waitCondition = waitCondition
        self.showsLoadSampleButton = showsLoadSampleButton
        self.toolbarButtonPreview = toolbarButtonPreview
        self.keyboardHints = keyboardHints
    }

    // Equatable conformance
    static func == (lhs: TutorialStep, rhs: TutorialStep) -> Bool {
        lhs.id == rhs.id
    }
}

/// Actions that can be performed automatically during the tutorial
enum TutorialAction: Equatable {
    case none
    case waitForUserModelDownload
    case loadSampleDataset
    case selectColumn(String)
    case selectDatabase(String)
    case runMatching
    case navigateHome
    case navigateToNewMatch
    case acceptCurrentMatch
    case rejectCurrentMatch
    case selectCandidate(Int)
    case resetCurrentDecision
}
