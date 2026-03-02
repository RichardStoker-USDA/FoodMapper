import Foundation

/// Persistent state for the interactive tutorial
struct TutorialState: Codable, Equatable {
    var hasCompletedTutorial: Bool = false
    var currentStep: Int = 0
    var showTutorialOnLaunch: Bool = true
    var tutorialDataLoaded: Bool = false
    var awaitingAction: Bool = false

    /// Total number of tutorial steps (computed from TutorialSteps content)
    static var totalSteps: Int { TutorialSteps.count }

    /// Storage key for UserDefaults
    private static let storageKey = "tutorialState"

    /// Load tutorial state from UserDefaults.
    /// Only completion and launch-preference flags persist across app launches.
    /// Step progress resets to 0 every launch because the tutorial workflow (loaded CSV,
    /// selected column, etc.) doesn't survive app termination.
    static func load() -> TutorialState {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var state = try? JSONDecoder().decode(TutorialState.self, from: data) else {
            return TutorialState()
        }

        // If the tutorial wasn't completed, reset step progress so it starts clean.
        // The auto-action workflow (load sample, select column, pick DB) can't resume
        // mid-stream after an app relaunch.
        if !state.hasCompletedTutorial {
            state.currentStep = 0
            state.tutorialDataLoaded = false
            state.awaitingAction = false
        }

        return state
    }

    /// Save tutorial state to UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Reset tutorial to beginning (for replay)
    mutating func reset() {
        currentStep = 0
        hasCompletedTutorial = false
        showTutorialOnLaunch = true
        tutorialDataLoaded = false
        awaitingAction = false
        save()
    }

    /// Mark tutorial as completed
    mutating func complete() {
        hasCompletedTutorial = true
        awaitingAction = false
        save()
    }

    /// Skip tutorial without marking as completed (allows relaunch next time)
    mutating func skipForNow() {
        currentStep = 0
        awaitingAction = false
        // Do NOT set hasCompletedTutorial = true
        // Do NOT change showTutorialOnLaunch
        save()
    }

    /// Advance to next step
    mutating func nextStep() {
        if currentStep < Self.totalSteps - 1 {
            currentStep += 1
            awaitingAction = false
            save()
        }
    }

    /// Check if this is the last step
    var isLastStep: Bool {
        currentStep >= Self.totalSteps - 1
    }

    /// Set awaiting action state
    mutating func setAwaiting(_ awaiting: Bool) {
        awaitingAction = awaiting
        save()
    }
}
