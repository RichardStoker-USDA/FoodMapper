import SwiftUI
import AppKit

/// Full-screen tutorial overlay
struct TutorialOverlay: View {
    @EnvironmentObject var appState: AppState
    @Binding var tutorialState: TutorialState
    @Binding var isShowing: Bool
    let anchors: [String: Anchor<CGRect>]

    @State private var showSkipConfirmation = false
    @State private var showCompletionModal = false
    @StateObject private var actionExecutor = TutorialActionExecutor()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// IDs that use toolbar frame reporting (above the overlay, can't spotlight)
    private static let toolbarIDs: Set<String> = ["homeButton", "matchButton"]

    /// Debounce: minimum time between auto-advances to prevent flash/skip bugs
    @State private var lastAdvanceTime: Date = .distantPast

    /// Whether to hide the overlay while the completion overlay is visible
    private var hideForCompletionOverlay: Bool {
        appState.showCompletionOverlay
    }

    var body: some View {
        GeometryReader { proxy in
            let currentStep = TutorialSteps.step(at: tutorialState.currentStep)

            ZStack {
                // Spotlight overlay (dims everything, cuts out highlighted areas)
                if let step = currentStep, !showCompletionModal, !hideForCompletionOverlay {
                    let spotlightRects = collectSpotlightRects(for: step, in: proxy)
                    SpotlightView(
                        highlightRects: spotlightRects,
                        padding: 12
                    )
                    .animation(Animate.smooth, value: spotlightRects.map { $0.origin.x + $0.origin.y })
                }

                // Coach mark positioned relative to highlight
                if let step = currentStep, !showCompletionModal, !hideForCompletionOverlay {
                    coachMarkView(for: step, in: proxy)
                        .animation(Animate.standard, value: tutorialState.currentStep)
                }

                // Debug: show all anchor frames with labels
                if DebugConfig.showTutorialAnchorFrames {
                    debugAnchorOverlay(in: proxy)
                }

                // Completion modal
                if showCompletionModal {
                    TutorialCompletionView(
                        onDismiss: {
                            showCompletionModal = false
                            tutorialState.complete()
                            isShowing = false
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .allowsHitTesting(!hideForCompletionOverlay)
        .onAppear {
            actionExecutor.appState = appState
            // If model already downloaded and we're on step 0, auto-advance after brief delay
            if appState.modelStatus.isReady && tutorialState.currentStep == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if tutorialState.currentStep == 0 {
                        advanceToNextStep()
                    }
                }
            }
        }
        .confirmationDialog(
            "Skip Tutorial?",
            isPresented: $showSkipConfirmation,
            titleVisibility: .visible
        ) {
            Button("Skip and Don't Show Again", role: .destructive) {
                tutorialState.showTutorialOnLaunch = false
                tutorialState.complete()
                isShowing = false
            }
            Button("Skip for Now") {
                tutorialState.skipForNow()
                isShowing = false
            }
            Button("Continue Tutorial", role: .cancel) {}
        } message: {
            Text("You can restart the tutorial anytime from Help.")
        }
        // Watch for model download completion (Step 0)
        .onChange(of: appState.modelStatus.isReady) { _, isReady in
            if isReady && tutorialState.currentStep == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if tutorialState.currentStep == 0 {
                        advanceToNextStep()
                    }
                }
            }
        }
        // Watch for completion overlay dismiss (Step 6 -> Step 7 transition).
        // Advance immediately to prevent step 6 from flashing briefly before step 7.
        .onChange(of: appState.showCompletionOverlay) { wasShowing, isShowing in
            if wasShowing && !isShowing && tutorialState.currentStep == 6 && !appState.results.isEmpty {
                advanceToNextStep()
            }
        }
        // Watch for manual column selection (Step 4) - auto-advance
        .onChange(of: appState.selectedColumn) { _, newColumn in
            if tutorialState.currentStep == 4 && newColumn == "Food_Description" {
                advanceToNextStep()
            }
        }
        // Watch for manual database selection (Step 5) - auto-advance on DFG2
        .onChange(of: appState.selectedDatabase) { _, newDB in
            if tutorialState.currentStep == 5 && newDB == .builtIn(.dfg2) {
                advanceToNextStep()
            }
        }
        // Watch for New Match card click (Step 2) - auto-advance when showMatchSetup becomes true
        .onChange(of: appState.showMatchSetup) { _, newValue in
            if newValue && tutorialState.currentStep == 2 {
                advanceToNextStep()
            }
            checkHomePageCondition()
        }
        // Watch for review decisions during steps 8-11 (match, reject, override, reset).
        // Uses reviewDecisionVersion (not .count) because in-place value replacements
        // don't change dictionary count, so .count-based watchers miss user actions.
        .onChange(of: appState.reviewDecisionVersion) { _, _ in
            guard appState.showTutorial else { return }
            let step = tutorialState.currentStep
            guard let selectedId = appState.selection.first else { return }

            if (8...10).contains(step) {
                if let decision = appState.reviewDecisions[selectedId],
                   decision.status != .pending {
                    // Check specific statuses per step
                    let shouldAdvance: Bool
                    switch step {
                    case 8: shouldAdvance = decision.status == .accepted
                    case 9: shouldAdvance = decision.status == .rejected
                    case 10: shouldAdvance = decision.status == .overridden
                    default: shouldAdvance = false
                    }
                    if shouldAdvance {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if tutorialState.currentStep == step {
                                advanceToNextStep()
                            }
                        }
                    }
                }
            }

            // Step 11 (Reset): decision removed means reset happened
            if step == 11 {
                if appState.reviewDecisions[selectedId] == nil
                    || appState.reviewDecisions[selectedId]?.status == .autoNeedsReview {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if tutorialState.currentStep == 11 {
                            advanceToNextStep()
                        }
                    }
                }
            }

            // Step 13 (Bulk Actions): auto-advance when a bulk action is performed
            if step == 13 && appState.selection.count > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if tutorialState.currentStep == 13 {
                        advanceToNextStep()
                    }
                }
            }
        }
        // Watch for filter pill changes (Step 12) - auto-advance
        .onChange(of: appState.resultsFilter) { _, _ in
            if appState.showTutorial && tutorialState.currentStep == 12 {
                advanceToNextStep()
            }
        }
        // Watch for returning home (Step 15)
        .onChange(of: appState.sidebarSelection) { _, _ in
            checkHomePageCondition()
        }
        .onChange(of: appState.viewingResults) { _, _ in
            checkHomePageCondition()
        }
        // Navigate to MatchSetupView for setup steps (3-5), handle review/home step transitions
        .onChange(of: tutorialState.currentStep) { oldStep, newStep in
            if newStep == 3 && !appState.showMatchSetup {
                appState.startNewMatch()
            }
            // Open inspector when entering review steps (8-11), bulk actions (13), or guided review (14)
            if (8...14).contains(newStep) && !appState.showInspector {
                appState.showInspector = true
            }
            // Step 7 (Your Results): auto-select first Needs Review row
            if newStep == 7 {
                appState.autoSelectFirstNeedsReview()
            }
            // Step 8 (Match): ensure a Needs Review row is selected
            if newStep == 8 {
                if let selectedId = appState.selection.first,
                   appState.cachedCategories[selectedId] != .needsReview {
                    appState.autoSelectFirstNeedsReview()
                }
            }
            // Step 9 (Reject): advance to next Needs Review row (skip the one just matched)
            if newStep == 9 && oldStep == 8 {
                appState.autoSelectFirstNeedsReview()
            }
            // Step 10 (Pick Alternative): stay on current row (just rejected in step 9)
            // No selection change needed

            // Step 11 (Reset): select a row that has a human decision
            if newStep == 11 {
                if let decidedId = appState.reviewDecisions.first(where: { $0.value.status.isHumanDecision })?.key {
                    appState.selection = [decidedId]
                }
            }
            // Announce step changes for VoiceOver
            if voiceOverEnabled, let step = TutorialSteps.step(at: newStep) {
                NSAccessibility.post(
                    element: NSApp.mainWindow as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: "Tutorial step \(newStep + 1) of \(TutorialSteps.count): \(step.title)",
                        .priority: NSAccessibilityPriorityLevel.high
                    ]
                )
            }
        }
    }

    /// Check if the on-home-page condition is met for Step 16
    private func checkHomePageCondition() {
        if tutorialState.currentStep == 16
            && appState.sidebarSelection == .home
            && !appState.showMatchSetup
            && !appState.viewingResults {
            advanceToNextStep()
        }
    }

    // MARK: - Frame Resolution

    /// Resolve a tutorial element's local frame within the overlay.
    private func resolveLocalFrame(for id: String, in proxy: GeometryProxy) -> CGRect? {
        let overlayGlobalOrigin = proxy.frame(in: .global).origin

        // Check frame-reported elements first (sidebar + toolbar)
        if let globalFrame = appState.tutorialElementFrames[id] {
            let localFrame = CGRect(
                x: globalFrame.origin.x - overlayGlobalOrigin.x,
                y: globalFrame.origin.y - overlayGlobalOrigin.y,
                width: globalFrame.width,
                height: globalFrame.height
            )
            return localFrame
        }

        // Fall back to preference key anchors (main content area elements)
        if let anchor = anchors[id] {
            return proxy[anchor]
        }

        // Last resort: estimate toolbar button positions
        if isToolbarElement(id) {
            return estimateToolbarButtonPosition(for: id, in: proxy)
        }

        return nil
    }

    /// Estimate toolbar button positions when GeometryReader doesn't report frames.
    private func estimateToolbarButtonPosition(for id: String, in proxy: GeometryProxy) -> CGRect {
        let buttonSize = CGSize(width: 36, height: 28)
        let topInset = proxy.safeAreaInsets.top

        switch id {
        case "homeButton":
            return CGRect(x: 8, y: -topInset + 6, width: buttonSize.width, height: buttonSize.height)
        case "matchButton":
            let overlayWidth = proxy.size.width
            return CGRect(x: overlayWidth - 80, y: -topInset + 6, width: 70, height: buttonSize.height)
        default:
            return .zero
        }
    }

    /// Check if an ID is a toolbar button (above the overlay, can't be spotlighted)
    private func isToolbarElement(_ id: String) -> Bool {
        Self.toolbarIDs.contains(id)
    }

    // MARK: - Spotlight Rect Collection

    /// Collect rects for the SpotlightView (only elements WITHIN the overlay bounds)
    private func collectSpotlightRects(for step: TutorialStep, in proxy: GeometryProxy) -> [CGRect] {
        var rects: [CGRect] = []

        for anchorID in step.highlightAnchors {
            if isToolbarElement(anchorID) { continue }

            if let localFrame = resolveLocalFrame(for: anchorID, in: proxy) {
                if localFrame.origin.y >= -localFrame.height && localFrame.origin.y < proxy.size.height {
                    rects.append(localFrame)
                }
            }
        }

        return rects
    }

    /// Get the target rect for positioning the coach mark.
    private func getCoachMarkTargetRect(for step: TutorialStep, in proxy: GeometryProxy) -> CGRect {
        var rects: [CGRect] = []

        for anchorID in step.highlightAnchors {
            if let localFrame = resolveLocalFrame(for: anchorID, in: proxy) {
                if isToolbarElement(anchorID) {
                    let clampedRect = CGRect(
                        x: localFrame.origin.x,
                        y: max(0, localFrame.origin.y),
                        width: localFrame.width,
                        height: localFrame.height
                    )
                    rects.append(clampedRect)
                } else {
                    rects.append(localFrame)
                }
            }
        }

        guard !rects.isEmpty else {
            return CGRect(
                x: proxy.size.width / 2 - 50,
                y: proxy.size.height / 2 - 25,
                width: 100,
                height: 50
            )
        }
        return rects.reduce(rects[0]) { $0.union($1) }
    }

    // MARK: - Coach Mark View

    @ViewBuilder
    private func coachMarkView(for step: TutorialStep, in proxy: GeometryProxy) -> some View {
        if step.toolbarButtonPreview != nil {
            let position = toolbarStepPosition(for: step.id, in: proxy)

            CoachMark(
                step: step,
                currentStepIndex: tutorialState.currentStep,
                totalSteps: TutorialSteps.count,
                actualPosition: .below,
                onNext: { handleNext(for: step) },
                onSkip: { showSkipConfirmation = true },
                onLoadSample: nil
            )
            .position(position)
        } else {
            let coachMarkSize = CGSize(width: 340, height: 220)
            let screenBounds = proxy.size

            let targetRect = getCoachMarkTargetRect(for: step, in: proxy)
            let (position, actualDirection) = CoachMarkPositioning.calculatePosition(
                targetRect: targetRect,
                coachMarkSize: coachMarkSize,
                screenSize: screenBounds,
                preferred: step.coachMarkPosition
            )

            CoachMark(
                step: step,
                currentStepIndex: tutorialState.currentStep,
                totalSteps: TutorialSteps.count,
                actualPosition: actualDirection,
                onNext: { handleNext(for: step) },
                onSkip: { showSkipConfirmation = true },
                onLoadSample: step.showsLoadSampleButton ? { handleLoadSample() } : nil
            )
            .position(position)
        }
    }

    /// Calculate manual position for toolbar tutorial steps.
    private func toolbarStepPosition(for stepId: Int, in proxy: GeometryProxy) -> CGPoint {
        let coachMarkHalfWidth: CGFloat = 170  // 340 / 2
        let margin: CGFloat = 24
        let topY: CGFloat = 135

        switch stepId {
        case 6:  // Match button - top right area
            return CGPoint(
                x: proxy.size.width - coachMarkHalfWidth - margin,
                y: topY
            )
        case 14, 15:  // Guided Review / Export button - top right
            return CGPoint(
                x: proxy.size.width - coachMarkHalfWidth - margin,
                y: topY
            )
        default: // Fallback - center below toolbar
            let sidebarWidth = Size.sidebarIdeal
            return CGPoint(
                x: sidebarWidth + coachMarkHalfWidth / 2 + margin,
                y: topY
            )
        }
    }

    // MARK: - Navigation Handlers

    private func handleNext(for step: TutorialStep) {
        // Step 0: start download if not yet downloading, advance if ready
        if step.id == 0 {
            if appState.modelStatus.isReady {
                advanceToNextStep()
            } else if case .downloading = appState.modelStatus {
                // Already downloading, just wait
            } else {
                handleDownloadModel()
            }
            return
        }

        // Step 3: If user clicks Next without loading sample data, auto-load it
        if step.id == 3 && appState.inputFile == nil {
            handleLoadSample()
            return
        }

        // Steps with actions that need execution
        if step.action != .none && step.action != .waitForUserModelDownload {
            Task {
                await actionExecutor.execute(step.action)
                if step.waitCondition == .none {
                    advanceToNextStep()
                } else {
                    // Check if action already satisfied the condition (e.g. accept/reject)
                    try? await Task.sleep(for: .milliseconds(200))
                    if actionExecutor.isWaitConditionSatisfied(step.waitCondition) {
                        advanceToNextStep()
                    }
                }
            }
        } else if step.waitCondition == .none {
            advanceToNextStep()
        }
    }

    private func handleLoadSample() {
        Task {
            await actionExecutor.execute(.loadSampleDataset)
            tutorialState.tutorialDataLoaded = true
            advanceToNextStep()
        }
    }

    private func handleDownloadModel() {
        Task {
            await appState.downloadModel()
        }
    }

    private func advanceToNextStep() {
        // Debounce: prevent double-advance within 0.4s (e.g. overlapping watchers)
        let now = Date()
        guard now.timeIntervalSince(lastAdvanceTime) > 0.4 else { return }
        lastAdvanceTime = now

        if tutorialState.isLastStep {
            withAnimation(Animate.bouncy) {
                showCompletionModal = true
            }
        } else {
            tutorialState.nextStep()
        }
    }

    // MARK: - Debug Anchor Overlay

    @ViewBuilder
    private func debugAnchorOverlay(in proxy: GeometryProxy) -> some View {
        let debugColors: [Color] = [.red, .green, .blue, .orange, .purple, .cyan, .pink, .yellow, .mint, .indigo]

        let frameIDs = Array(appState.tutorialElementFrames.keys).sorted()
        let anchorIDs = Array(anchors.keys).sorted()
        let allIDs = (frameIDs + anchorIDs.filter { !frameIDs.contains($0) })

        ForEach(Array(allIDs.enumerated()), id: \.element) { index, id in
            if let localFrame = resolveLocalFrame(for: id, in: proxy) {
                let color = debugColors[index % debugColors.count]
                let isFrameReported = appState.tutorialElementFrames[id] != nil
                let isToolbar = isToolbarElement(id)
                let currentStep = TutorialSteps.step(at: tutorialState.currentStep)
                let isActiveAnchor = currentStep?.highlightAnchors.contains(id) ?? false

                Rectangle()
                    .strokeBorder(color, lineWidth: isActiveAnchor ? 3 : 1)
                    .frame(width: localFrame.width, height: localFrame.height)
                    .position(x: localFrame.midX, y: localFrame.midY)

                Text("\(id)\(isFrameReported ? " [F]" : " [P]")\(isToolbar ? " [T]" : "")")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .position(x: localFrame.midX, y: localFrame.minY - 8)
            }
        }
    }
}

#Preview("Tutorial Overlay - Light") {
    ZStack {
        Color.white
        Text("App Content")
        TutorialOverlay(
            tutorialState: .constant(TutorialState()),
            isShowing: .constant(true),
            anchors: [:]
        )
        .environmentObject(PreviewHelpers.emptyState())
    }
    .frame(width: 900, height: 650)
}

#Preview("Tutorial Overlay - Dark") {
    ZStack {
        Color.black
        Text("App Content")
            .foregroundStyle(.white)
        TutorialOverlay(
            tutorialState: .constant(TutorialState()),
            isShowing: .constant(true),
            anchors: [:]
        )
        .environmentObject(PreviewHelpers.emptyState())
    }
    .frame(width: 900, height: 650)
    .preferredColorScheme(.dark)
}
