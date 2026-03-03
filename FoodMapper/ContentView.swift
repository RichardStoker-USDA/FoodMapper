import SwiftUI

/// Main content view with navigation
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showExportFormatPicker = false

    var body: some View {
        if appState.isInResearchShowcase {
            ResearchShowcaseView()
                .environmentObject(appState)
                // Lock window to the default app size (sidebar + toolbar included).
                // Content was designed for this exact size.
                .frame(minWidth: 1357, maxWidth: 1357, minHeight: 812, maxHeight: 812)
        } else {
            mainNavigationView
        }
    }

    @ViewBuilder
    private var mainNavigationView: some View {
        NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
            Sidebar()
        } detail: {
            MainContent()
        }
        .onPreferenceChange(TutorialFramePreferenceKey.self) { frames in
            for (key, frame) in frames {
                appState.tutorialElementFrames[key] = frame
            }
        }
        .toolbar {
            // PILL 1: Back/Forward
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 0) {
                    Button {
                        appState.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .disabled(!appState.canGoBack || appState.showTutorial)
                    .help("Go back (Cmd+[)")

                    Divider()
                        .frame(height: 16)

                    Button {
                        appState.goForward()
                    } label: {
                        Label("Forward", systemImage: "chevron.forward")
                    }
                    .disabled(!appState.canGoForward || appState.showTutorial)
                    .help("Go forward (Cmd+])")
                }
            }

            // Home button
            ToolbarItem(placement: .navigation) {
                Button {
                    guard !isToolbarButtonDisabledForTutorial("homeButton") else { return }
                    appState.sidebarVisibility = .all
                    appState.returnToWelcome()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .disabled((appState.showWelcome && !appState.viewingResults) || isToolbarButtonDisabledForTutorial("homeButton"))
                .help("Return to welcome screen")
                .accessibilityHint("Clears current session and returns to start")
                .background {
                    if appState.showTutorial {
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: TutorialFramePreferenceKey.self, value: ["homeButton": geo.frame(in: .global)])
                        }
                    }
                }
            }

            // New Match button
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.startNewMatch()
                } label: {
                    Label("New Match", systemImage: "link.badge.plus")
                        .symbolRenderingMode(.multicolor)
                }
                .disabled(appState.isProcessing || appState.showTutorial)
                .help("Start a new matching session")
            }

            // Review button (visible when results are loaded)
            ToolbarItem(placement: .primaryAction) {
                Group {
                    if appState.viewingResults
                        && !appState.results.isEmpty
                        && !appState.isProcessing
                        && appState.sidebarSelection == .home
                        && !appState.showMatchSetup {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if appState.isReviewMode {
                                    appState.isReviewMode = false
                                    appState.resultsFilter = .all
                                } else {
                                    appState.enterReviewMode()
                                    appState.showGuidedReviewBanner = true
                                }
                            }
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: appState.isReviewMode ? "stop.circle" : "play.circle")
                                    .foregroundStyle(appState.isReviewMode ? .green : Color(nsColor: .controlAccentColor))
                                if appState.isReviewMode {
                                    let remaining = appState.cachedCategories.values.filter { $0 == .needsReview }.count
                                    Text(remaining > 0 ? "End Guided Review (\(remaining))" : "End Guided Review (Done)")
                                } else {
                                    Text("Start Guided Review")
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .help(appState.isReviewMode ? "End guided review" : "Start guided review (auto-advances through items needing review)")
                        .disabled(appState.showTutorial)
                        .background {
                            if appState.showTutorial {
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: TutorialFramePreferenceKey.self, value: ["guidedReviewButton": geo.frame(in: .global)])
                                }
                            }
                        }
                    }
                }
            }

            // Export button (always present, content hidden when not applicable)
            ToolbarItem(placement: .primaryAction) {
                Group {
                    if appState.viewingResults
                        && !appState.results.isEmpty
                        && !appState.isProcessing
                        && appState.sidebarSelection == .home
                        && !appState.showMatchSetup {
                        if appState.isAdvancedMode {
                            Menu {
                                Section("Standard") {
                                    Button {
                                        appState.exportResults()
                                    } label: {
                                        Label("Export CSV", systemImage: "doc.text")
                                    }
                                    Button {
                                        appState.exportResults(format: .tsv)
                                    } label: {
                                        Label("Export TSV", systemImage: "doc.text")
                                    }
                                }
                                Section("Detailed") {
                                    Button {
                                        appState.exportResults(isDetailed: true)
                                    } label: {
                                        Label("Detailed CSV", systemImage: "doc.text.magnifyingglass")
                                    }
                                    Button {
                                        appState.exportResults(isDetailed: true, format: .tsv)
                                    } label: {
                                        Label("Detailed TSV", systemImage: "doc.text.magnifyingglass")
                                    }
                                }
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                                    Text("Export")
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Export match results")
                            .disabled(appState.showTutorial)
                            .background {
                                if appState.showTutorial {
                                    GeometryReader { geo in
                                        Color.clear
                                            .preference(key: TutorialFramePreferenceKey.self, value: ["exportButton": geo.frame(in: .global)])
                                    }
                                }
                            }
                        } else {
                            Button {
                                showExportFormatPicker = true
                            } label: {
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                                    Text("Export")
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Export match results")
                            .disabled(appState.showTutorial)
                            .popover(isPresented: $showExportFormatPicker, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: Spacing.xxs) {
                                    ExportFormatRow(label: "Export CSV", icon: "doc.text") {
                                        showExportFormatPicker = false
                                        appState.exportResults()
                                    }
                                    ExportFormatRow(label: "Export TSV", icon: "doc.text") {
                                        showExportFormatPicker = false
                                        appState.exportResults(format: .tsv)
                                    }
                                }
                                .padding(Spacing.xs)
                                .frame(width: 168)
                            }
                            .background {
                                if appState.showTutorial {
                                    GeometryReader { geo in
                                        Color.clear
                                            .preference(key: TutorialFramePreferenceKey.self, value: ["exportButton": geo.frame(in: .global)])
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Match state machine (instant swap, no animation -- toolbar layout
            // fights SwiftUI transitions causing slide-off-screen artifacts).
            // On Tahoe, suppress the system Liquid Glass container so our custom
            // glass chrome is the only one visible.
            if #available(macOS 26, *) {
                ToolbarItem(placement: .primaryAction) {
                    matchToolbarContent
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    matchToolbarContent
                }
            }
        }
        .modifier(ForceToolbarSeparator())
        .sheet(isPresented: $appState.showModelDownloadSheet) {
            ModelDownloadSheet(
                models: appState.pendingDownloadModels,
                modelManager: appState.modelManager,
                onComplete: {
                    appState.showModelDownloadSheet = false
                    appState.pendingDownloadModels = []
                    appState.runMatching()
                },
                onCancel: {
                    appState.showModelDownloadSheet = false
                    appState.pendingDownloadModels = []
                }
            )
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { appState.error != nil },
                set: { if !$0 { appState.error = nil } }
            ),
            presenting: appState.error
        ) { _ in
            Button("OK") {
                appState.error = nil
            }
        } message: { error in
            Text(error.localizedDescription)
        }
        // Tutorial overlay
        .overlayPreferenceValue(TutorialAnchorKey.self) { anchors in
            if appState.showTutorial {
                TutorialOverlay(
                    tutorialState: $appState.tutorialState,
                    isShowing: $appState.showTutorial,
                    anchors: anchors
                )
            }
        }
        // Phase 2: Collapse sidebar when model missing
        .onAppear {
            if !appState.modelStatus.isReady {
                appState.sidebarVisibility = .detailOnly
            }

            // Start tutorial on first launch BEFORE model download
            if !appState.tutorialState.hasCompletedTutorial && appState.tutorialState.showTutorialOnLaunch {
                // Skip Step 0 if model already downloaded (no flash)
                if appState.tutorialState.currentStep == 0 && appState.modelManager.state(for: "gte-large").isAvailable {
                    appState.tutorialState.currentStep = 1
                    appState.tutorialState.save()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    appState.showTutorial = true
                }
            }
        }
        .onChange(of: appState.modelStatus.isReady) { _, isReady in
            if isReady {
                appState.ensureSidebarVisible()
                appState.checkSplashScreen()
            }
        }
        // Listen for restart tutorial notification
        .onReceive(NotificationCenter.default.publisher(for: .restartTutorial)) { _ in
            appState.restartTutorial()
        }
        // Listen for help window notification (from menu commands)
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
            openWindow(id: "help")
        }
        .sheet(isPresented: $appState.showSplashScreen) {
            SplashScreenView(isPresented: $appState.showSplashScreen)
                .environmentObject(appState)
        }
    }

    /// Match state toolbar content -- shared between Tahoe (with .sharedBackgroundVisibility)
    /// and older OS versions (without).
    @ViewBuilder
    private var matchToolbarContent: some View {
        Group {
            switch appState.toolbarMatchState {
            case .hidden:
                EmptyView()
            case .match:
                MatchButton(
                    action: {
                        if !appState.results.isEmpty { appState.clearResults() }
                        appState.runMatching()
                    },
                    disabled: appState.showTutorial && appState.tutorialState.currentStep != 6
                )
                .help("Match input items against the selected database")
                .background {
                    if appState.showTutorial {
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: TutorialFramePreferenceKey.self, value: ["matchButton": geo.frame(in: .global)])
                        }
                    }
                }
            case .progress:
                ProgressToolbarItem()
            case .matchComplete:
                MatchCompleteButton {
                    appState.viewCompletedResults()
                }
                .help("View completed matching results")
            }
        }
        .transaction { $0.animation = nil } // Strip inherited animations -- toolbar layout on Sequoia
    }

    /// Disable toolbar buttons during tutorial steps that don't feature them.
    /// Uses the native macOS disabled state (grayed out) instead of manual opacity,
    /// so buttons blend naturally with the rest of the toolbar.
    private func isToolbarButtonDisabledForTutorial(_ buttonID: String) -> Bool {
        guard appState.showTutorial else { return false }
        let step = appState.tutorialState.currentStep
        switch buttonID {
        case "homeButton":   return step != 16
        case "matchButton":  return step != 6
        default:             return false
        }
    }
}

/// Main content area -- routes based on sidebar selection
struct MainContent: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        VStack(spacing: 0) {
            // Manual separator line. macOS 26 Liquid Glass hides the system
            // toolbar separator during sidebar animation and on certain pages.
            // This Divider is always visible regardless of sidebar state.
            Divider()

            // Main content
            Group {
                if !appState.modelStatus.isReady {
                    ModelDownloadView()
                } else {
                    contentForSelection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .top) {
                VStack(spacing: Spacing.sm) {
                    if appState.showMatchCompleteBanner {
                        MatchCompleteBanner(
                            matchCount: appState.matchCompleteBannerCount,
                            onViewResults: {
                                appState.dismissMatchCompleteBanner()
                                appState.viewCompletedResults()
                            },
                            onDismiss: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    appState.dismissMatchCompleteBanner()
                                }
                            }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if appState.showGuidedReviewBanner && !appState.showTutorial {
                        GuidedReviewBanner(isShowing: $appState.showGuidedReviewBanner)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.showMatchCompleteBanner)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.showGuidedReviewBanner)

            // Status bar
            StatusBar(
                statusMessage: appState.statusMessage,
                isProcessing: appState.isProcessing,
                modelStatus: appState.modelStatus,
                hardwareConfig: appState.hardwareConfig,
                showDebugInfo: appState.advancedSettings.showDebugInfo,
                effectiveEmbeddingBatchSize: appState.effectiveEmbeddingBatchSize,
                effectiveMatchingBatchSize: appState.effectiveMatchingBatchSize
            )
        }
        // Minimum size for the detail column content. Combined with
        // .windowResizability(.contentSize) on the WindowGroup, this propagates
        // to the NSWindow level as an enforced minimum. Sidebar min (220) +
        // detail min (1130) = ~1350 window minimum width.
        // This constrains the detail NSSplitViewItem only, NOT the overall
        // NavigationSplitView, so sidebar animation stays smooth (P20 safe).
        .frame(minWidth: 1130, minHeight: 740)
    }

    @ViewBuilder
    private var contentForSelection: some View {
        // Show results only when explicitly viewing them
        if appState.viewingResults && !appState.results.isEmpty && appState.sidebarSelection == .home && !appState.showMatchSetup {
            ResultsView()
        } else if appState.isProcessing && appState.sidebarSelection == .home, let progress = appState.progress {
            EmptyStateView(
                state: .processing(progress, appState.matchingPhase, batchStartTime: appState.batchStartTime),
                onOpenFile: { appState.openFilePicker() }
            )
        } else {
            switch appState.sidebarSelection {
            case .home:
                if appState.showMatchSetup {
                    MatchSetupView()
                } else {
                    WelcomeLandingView()
                }
            case .databases:
                DatabaseManagementView()
            case .inputFiles:
                InputFileManagementView()
            case .history:
                HistoryView()
            case .pipelineOverview:
                PipelineOverviewView()
            case .pipelineConfig:
                PipelineConfigurationView()
            case .benchmarks:
                BenchmarkView()
            case nil:
                WelcomeLandingView()
            }
        }
    }
}

/// Progress indicator in toolbar
struct ProgressToolbarItem: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false
    @State private var hoverPoint: CGPoint = .zero

    private var progressText: String {
        let phase = appState.matchingPhase
        if phase.isActive && !phase.displayText.isEmpty {
            return phase.displayText
        }
        if let progress = appState.progress, progress.totalUnitCount > 0 {
            return "\(progress.completedUnitCount)/\(progress.totalUnitCount)"
        }
        return "Matching..."
    }

    private var progressContent: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                if #available(macOS 15.0, *) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, isActive: true)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.accentColor)
                }

                Text(progressText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Button {
                appState.cancelMatching()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel matching")
        }
    }

    var body: some View {
        if #available(macOS 26, *) {
            // Material-based glass with cursor-tracking glow + rotating shine
            progressContent
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 6)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.secondary.opacity(0.08))
                        // Subtle specular highlight
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.2), .clear, .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .padding(.horizontal, 2)
                            .padding(.top, 1)
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    }
                }
                .shadow(color: .black.opacity(0.1), radius: 1, y: 0.5)
                .overlay {
                    GeometryReader { _ in
                        if isHovering {
                            Circle()
                                .fill(RadialGradient(
                                    colors: [.white.opacity(0.25), .clear],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 25
                                ))
                                .frame(width: 50, height: 50)
                                .position(x: hoverPoint.x, y: hoverPoint.y)
                                .blur(radius: 3)
                        }
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
                .polishedShine(cornerRadius: 100)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        isHovering = true
                    case .ended:
                        isHovering = false
                    }
                }
        } else {
            // Subtle filled capsule with rotating shine
            progressContent
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                )
                .polishedShine(cornerRadius: 100)
        }
    }
}

/// Results view with table and inspector panel
struct ResultsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showStatistics = false

    var body: some View {
        VStack(spacing: 0) {
            // Summary banner (always visible with results)
            ResultsSummaryBanner(
                currentPage: $appState.currentPage,
                totalPages: appState.totalPages
            )

            // Results table (paginated for performance)
            ResultsTableView(
                results: appState.paginatedResults,
                totalFilteredCount: appState.filteredResults.count,
                threshold: appState.threshold,
                reviewDecisions: appState.reviewDecisions,
                cachedCategories: appState.cachedCategories,
                selection: $appState.selection,
                sortOrder: $appState.sortOrder,
                searchText: $appState.searchText,
                currentPage: $appState.currentPage,
                totalPages: appState.totalPages
            )
            .tutorialAnchor("resultsTable")
        }
        .blur(radius: appState.showCompletionOverlay ? 6 : 0)
        .animation(Animate.standard, value: appState.showCompletionOverlay)
        .overlay(alignment: .top) {
            if appState.showExportToast, let message = appState.exportToastMessage {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(message)
                        .font(.subheadline)
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .padding(.top, Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState.showExportToast)
        .animation(Animate.standard, value: appState.isReviewMode)
        .inspector(isPresented: $appState.showInspector) {
            ReviewInspectorPanel()
                .background(Color(nsColor: .textBackgroundColor))
                .blur(radius: appState.showCompletionOverlay ? 6 : 0)
                .inspectorColumnWidth(min: 360, ideal: 400, max: 520)
                .interactiveDismissDisabled(true)
        }
        .overlay {
            if appState.showCompletionOverlay {
                MatchCompletionOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
            }
        }
        .animation(Animate.standard, value: appState.showCompletionOverlay)
        .toolbar {
            // Statistics button (opens sheet with charts + analytics)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showStatistics = true
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                .help("View match statistics and charts")
            }
        }
        .sheet(isPresented: $showStatistics) {
            StatisticsSheet()
                .environmentObject(appState)
        }
        // MARK: - Review Mode Keyboard Shortcuts
        // All review shortcuts are suppressed while an inspector text field is focused
        // (override search, notes) so typed characters go to the field instead.
        .onKeyPress(characters: .init(charactersIn: "12345")) { keyPress in
            guard appState.isReviewMode, !appState.inspectorFieldFocused else { return .ignored }
            return handleCandidateSelection(keyPress)
        }
        .onKeyPress(.return) {
            guard !appState.inspectorFieldFocused else { return .ignored }
            return handleReviewAction(.accepted)
        }
        .onKeyPress(.delete) {
            guard !appState.inspectorFieldFocused else { return .ignored }
            return handleReviewAction(.rejected)
        }
        .onKeyPress(.escape) {
            if appState.inspectorFieldFocused {
                // Escape from text field: clear focus, return to review shortcuts
                appState.inspectorFieldFocused = false
                return .ignored  // Let SwiftUI handle defocusing the field
            }
            if appState.isReviewMode {
                // Exit guided review mode, reset filter to show all results
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    appState.isReviewMode = false
                    appState.resultsFilter = .all
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress("n") {
            guard appState.isReviewMode, !appState.inspectorFieldFocused else { return .ignored }
            appState.advanceToNextPending()
            return .handled
        }
        .onKeyPress("p") {
            guard appState.isReviewMode, !appState.inspectorFieldFocused else { return .ignored }
            appState.advanceToPreviousPending()
            return .handled
        }
        // Arrow keys for navigating pending items (Left/Right only; Up/Down stay as Table default)
        .onKeyPress(.leftArrow) {
            guard appState.isReviewMode, !appState.inspectorFieldFocused else { return .ignored }
            appState.advanceToPreviousPending()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard appState.isReviewMode, !appState.inspectorFieldFocused else { return .ignored }
            appState.advanceToNextPending()
            return .handled
        }
        // R key to reset: press twice within 1.5s to confirm (single or bulk)
        .onKeyPress("r") {
            guard !appState.inspectorFieldFocused else { return .ignored }
            let selected = appState.selection
            guard !selected.isEmpty else { return .ignored }

            if selected.count > 1 {
                // Bulk reset with same press-twice confirmation as inspector button
                appState.handleBulkResetConfirmation(ids: selected)
                return .handled
            }

            // Single reset
            guard let selectedId = selected.first,
                  appState.hasHumanDecision(for: selectedId) else { return .ignored }
            appState.handleResetConfirmation(for: selectedId)
            return .handled
        }
        .background {
            Group {
                // Hidden button for Cmd+Z undo
                Button("") {
                    guard appState.canUndoReview else { return }
                    if let undoneId = appState.undoLastReview() {
                        appState.selection = [undoneId]
                    }
                }
                .keyboardShortcut("z", modifiers: .command)

                // Hidden button for Cmd+Shift+R to toggle review mode
                Button("") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        if appState.isReviewMode {
                            appState.isReviewMode = false
                            appState.resultsFilter = .all
                        } else {
                            appState.enterReviewMode()
                            appState.showGuidedReviewBanner = true
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                // Hidden button for Delete key (higher priority than .onKeyPress for Table)
                Button("") {
                    guard !appState.inspectorFieldFocused else { return }
                    let selected = appState.selection
                    guard !selected.isEmpty else { return }
                    if selected.count > 1 {
                        appState.bulkSetNoMatch(ids: selected)
                    } else if let selectedId = selected.first {
                        appState.setReviewDecision(.rejected, for: selectedId)
                        appState.advanceToNextPending()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        // 1a: Collapse sidebar and show inspector when results page appears
        .onAppear {
            appState.sidebarVisibility = .detailOnly
            appState.showInspector = true
        }
        // Prevent inspector from being collapsed by dragging -- force it back open
        .onChange(of: appState.showInspector) { _, newValue in
            if !newValue {
                appState.showInspector = true
            }
        }
    }

    /// Handle a review keyboard action on selected result(s).
    /// Single selection: applies to one item and advances. Multi-selection: bulk action.
    private func handleReviewAction(_ status: ReviewStatus) -> KeyPress.Result {
        let selected = appState.selection
        guard !selected.isEmpty else { return .ignored }

        if selected.count > 1 {
            // Bulk action -- use the same functions as the inspector bulk buttons
            switch status {
            case .accepted: appState.bulkSetMatch(ids: selected)
            case .rejected: appState.bulkSetNoMatch(ids: selected)
            default: break
            }
            return .handled
        }

        // Single selection
        guard let selectedId = selected.first else { return .ignored }
        let currentDecision = appState.reviewDecisions[selectedId]
        // Block accepting if already accepted, and block accepting if overridden
        // (prevents accidentally reverting an override back to the original candidate)
        if status == .accepted {
            let currentStatus = currentDecision?.status
            if currentStatus == .accepted || currentStatus == .overridden { return .ignored }
        }
        // Block rejecting if already rejected
        if status == .rejected && currentDecision?.status == .rejected { return .ignored }
        appState.setReviewDecision(status, for: selectedId)
        appState.advanceToNextPending()
        return .handled
    }


    /// Handle number key 1-5 to select a candidate from the inspector panel.
    /// If the candidate matches the pipeline's top pick, treat as accepted (not override).
    private func handleCandidateSelection(_ keyPress: KeyPress) -> KeyPress.Result {
        guard let digit = keyPress.characters.first?.wholeNumberValue,
              digit >= 1, digit <= 5 else { return .ignored }
        let index = digit - 1

        guard let selectedId = appState.selection.first,
              let result = appState.resultsByID[selectedId],
              let candidates = result.candidates,
              index < candidates.count else { return .ignored }

        let candidate = candidates[index]

        if result.isPipelineMatch(candidate) {
            // Same candidate the pipeline chose -- confirmation, not override
            appState.setReviewDecision(.accepted, for: selectedId, candidateIndex: index)
        } else {
            appState.setReviewDecision(
                .overridden, for: selectedId,
                overrideText: candidate.matchText,
                overrideID: candidate.matchID,
                overrideScore: candidate.score,
                candidateIndex: index
            )
        }
        appState.advanceToNextPending()
        return .handled
    }
}

// MARK: - Statistics Sheet

/// Modal sheet containing charts, score distribution, and threshold/zone controls.
/// Accessible from a toolbar button. Not permanently visible -- analytics, not workflow.
struct StatisticsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("Match Statistics")
                        .technicalHeader()
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.lg)

            Divider()
                .opacity(0.5)

            ScrollView {
                VStack(spacing: Spacing.xl) {
                    // Charts
                    VStack(spacing: Spacing.lg) {
                        MatchRateChart(results: appState.results, threshold: appState.threshold, cachedCategories: appState.cachedCategories)
                        ScoreDistributionChart(
                            results: appState.results,
                            threshold: appState.threshold
                        )
                    }
                    .tutorialAnchor("matchRatePanel")

                    // Statistics
                    StatisticsPanel(
                        results: appState.results,
                        threshold: appState.threshold,
                        reviewDecisions: appState.reviewDecisions,
                        cachedCategories: appState.cachedCategories
                    )

                }
                .padding(Spacing.xl)
            }
        }
        .frame(width: 500, height: 720)
        .background(Color.cardBackground(for: colorScheme))
    }
}

/// Banner shown when matching completes while user is on another page
private struct MatchCompleteBanner: View {
    let matchCount: Int
    let onViewResults: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Match Complete")
                    .font(.headline)
                Text("\(matchCount) results")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("View Results") {
                onViewResults()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: .controlAccentColor))
            .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: .controlAccentColor))
                .frame(width: 3)
        }
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Forces a hard toolbar separator on macOS 26+ to prevent Liquid Glass
/// scroll-adaptive behavior from hiding the separator during sidebar animation.
/// On macOS 26, the system hides the toolbar separator when a ScrollView is at
/// scroll position 0. The .hard style forces a permanent dividing line.
private struct ForceToolbarSeparator: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

// MARK: - Toolbar Buttons

/// Polished "Match" button.
/// - Tahoe: Faux-glass capsule (material + accent tint + specular highlight + edge glow
///   + multi-layer shadow + cursor-tracking glow + polished shine). Uses .ultraThinMaterial
///   instead of .glassEffect because glass-on-glass (inside the Liquid Glass toolbar) can't
///   sample through to window content, making it look flat. Material CAN sample through.
/// - Sequoia/Sonoma: Solid accent capsule with shadow + polished shine border
private struct MatchButton: View {
    let action: () -> Void
    let disabled: Bool

    @State private var hasAppeared = false
    @State private var isHovering = false
    @State private var hoverPoint: CGPoint = .zero
    @Environment(\.colorScheme) private var colorScheme

    private var matchLabel: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "play")
                .font(.body.weight(.bold))
            Text("Match")
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 8)
    }

    var body: some View {
        buttonChrome
            .scaleEffect(hasAppeared ? (isHovering && !disabled ? 1.02 : 1.0) : 0.7)
            .opacity(disabled ? 0.5 : (hasAppeared ? 1.0 : 0.0))
            .animation(.spring(response: 0.4, dampingFraction: 0.55), value: hasAppeared)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
            .onAppear { hasAppeared = true }
            .onDisappear { hasAppeared = false }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    if !disabled { isHovering = true }
                case .ended:
                    isHovering = false
                }
            }
    }

    /// Accent color overlay opacity -- light mode needs higher saturation because
    /// ultraThinMaterial on a white toolbar creates a near-white base that washes out
    /// lower opacities. Dark mode has natural contrast so less opacity is needed.
    private var accentOpacity: Double { colorScheme == .dark ? 0.65 : 0.85 }
    /// Specular highlight strength -- in light mode, white-on-light washes out,
    /// so dial it back. Dark mode benefits from a brighter specular.
    private var specularPeak: Double { colorScheme == .dark ? 0.4 : 0.12 }
    /// Edge glow top opacity -- less visible needed in light mode.
    private var edgeGlowTop: Double { colorScheme == .dark ? 0.55 : 0.3 }
    private var edgeGlowBottom: Double { colorScheme == .dark ? 0.12 : 0.05 }

    @ViewBuilder
    private var buttonChrome: some View {
        if #available(macOS 26, *) {
            // Material-based glass: ultraThinMaterial samples actual window content
            // through the toolbar, giving real translucency. Layered with accent tint,
            // specular highlight, and edge glow for 3D glass depth.
            Button(action: action) {
                matchLabel
                    .background {
                        ZStack {
                            // Layer 0: Colored backlight -- gives the material
                            // something saturated to blur, preventing wash-out
                            // on Tahoe's bright Liquid Glass toolbar
                            Capsule().fill(Color.accentColor.opacity(0.35))
                            // Layer 1: Translucent base -- samples + blurs the backlight
                            Capsule().fill(.ultraThinMaterial)
                            // Layer 2: Accent color tint
                            Capsule().fill(Color.accentColor.opacity(accentOpacity))
                            // Layer 3: Specular highlight -- simulates light hitting
                            // the top of a curved glass surface
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(specularPeak),
                                            .white.opacity(0.06),
                                            .clear
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .padding(.horizontal, 2)
                                .padding(.top, 1)
                            // Layer 4: Inner edge highlight -- glass refraction at edges
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(edgeGlowTop),
                                            .white.opacity(edgeGlowBottom)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.7
                                )
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            // Multi-layer shadows for 3D depth -- light mode gets stronger shadows
            // since the white toolbar provides less natural contrast
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.25), radius: 1.5, y: 1)
            .shadow(
                color: Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.35),
                radius: 8, y: 4
            )
            // Cursor-tracking glow: soft light follows the mouse across the surface
            .overlay {
                GeometryReader { _ in
                    if isHovering && !disabled {
                        Circle()
                            .fill(RadialGradient(
                                colors: [.white.opacity(0.35), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 30
                            ))
                            .frame(width: 60, height: 60)
                            .position(x: hoverPoint.x, y: hoverPoint.y)
                            .blur(radius: 4)
                    }
                }
                .clipShape(Capsule())
                .allowsHitTesting(false)
            }
            .polishedShine(cornerRadius: 100, isActive: !disabled, color: .white)
        } else {
            // Solid accent capsule with shadow and rotating shine
            Button(action: action) {
                ZStack {
                    Capsule()
                        .fill(Color.accentColor)
                        .shadow(
                            color: Color.accentColor.opacity(colorScheme == .dark ? 0.5 : 0.3),
                            radius: isHovering ? 8 : 4,
                            y: isHovering ? 4 : 2
                        )
                        .polishedShine(cornerRadius: 100, isActive: !disabled, color: .white)
                    matchLabel
                }
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
    }
}

/// Polished "Match Complete" button.
/// - Tahoe: Material-based glass capsule with green tint + specular + edge glow
///   + cursor-tracking glow + polished shine + scale on appear/hover
/// - Sequoia/Sonoma: Solid green capsule with shadow + polished shine
private struct MatchCompleteButton: View {
    let action: () -> Void

    @State private var hasAppeared = false
    @State private var isHovering = false
    @State private var hoverPoint: CGPoint = .zero
    @Environment(\.colorScheme) private var colorScheme

    private var completeLabel: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.body.weight(.bold))
            Text("Matching Complete")
                .font(.body.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 8)
    }

    var body: some View {
        buttonChrome
            .scaleEffect(hasAppeared ? (isHovering ? 1.02 : 1.0) : 0.7)
            .opacity(hasAppeared ? 1.0 : 0.0)
            .animation(.spring(response: 0.4, dampingFraction: 0.55), value: hasAppeared)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovering)
            .onAppear { hasAppeared = true }
            .onDisappear { hasAppeared = false }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    isHovering = true
                case .ended:
                    isHovering = false
                }
            }
    }

    @ViewBuilder
    private var buttonChrome: some View {
        if #available(macOS 26, *) {
            Button(action: action) {
                completeLabel
                    .background {
                        ZStack {
                            Capsule().fill(Color.green.opacity(0.35))
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(Color.green.opacity(colorScheme == .dark ? 0.65 : 0.85))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(colorScheme == .dark ? 0.3 : 0.1),
                                            .white.opacity(0.04),
                                            .clear
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .padding(.horizontal, 2)
                                .padding(.top, 1)
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(colorScheme == .dark ? 0.5 : 0.25),
                                            .white.opacity(colorScheme == .dark ? 0.1 : 0.04)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.7
                                )
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.15 : 0.22), radius: 1.5, y: 1)
            .shadow(color: Color.green.opacity(0.3), radius: 6, y: 3)
            // Cursor-tracking glow
            .overlay {
                GeometryReader { _ in
                    if isHovering {
                        Circle()
                            .fill(RadialGradient(
                                colors: [.white.opacity(0.35), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 30
                            ))
                            .frame(width: 60, height: 60)
                            .position(x: hoverPoint.x, y: hoverPoint.y)
                            .blur(radius: 4)
                    }
                }
                .clipShape(Capsule())
                .allowsHitTesting(false)
            }
            .polishedShine(cornerRadius: 100, isActive: true, color: .white)
        } else {
            Button(action: action) {
                ZStack {
                    Capsule()
                        .fill(Color.green)
                        .shadow(
                            color: Color.green.opacity(colorScheme == .dark ? 0.5 : 0.3),
                            radius: isHovering ? 8 : 4,
                            y: isHovering ? 4 : 2
                        )
                        .polishedShine(cornerRadius: 100, isActive: true, color: .white)
                    completeLabel
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Guided Review Banner

/// Guided Review info banner -- shows every time review mode is entered.
/// Auto-dismisses after 6 seconds or on tap.
private struct GuidedReviewBanner: View {
    @Binding var isShowing: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Guided Review Started")
                    .font(.subheadline.weight(.semibold))
                Text("Items advance automatically after each decision. Use Return to match, Delete for no match. Press Esc or click End Guided Review to exit.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isShowing = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(Spacing.xs)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: 540)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .bannerCardStyle()
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isShowing = false
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isShowing = false
            }
        }
    }
}

// MARK: - Banner Card Style

extension View {
    @ViewBuilder
    func bannerCardStyle() -> some View {
        if #available(macOS 26, *) {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .glassEffect(.regular)
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Export Format Popover Row

private struct ExportFormatRow: View {
    let label: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                    .frame(width: 16)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
                Text(label)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

#Preview("Home - Light") {
    ContentView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 1200, height: 750)
}

#Preview("Home - Dark") {
    ContentView()
        .environmentObject(PreviewHelpers.emptyState())
        .frame(width: 1200, height: 750)
        .preferredColorScheme(.dark)
}

#Preview("Results") {
    ContentView()
        .environmentObject(PreviewHelpers.resultsState())
        .frame(width: 1200, height: 750)
}

#Preview("Processing") {
    ContentView()
        .environmentObject(PreviewHelpers.processingEmbeddingState())
        .frame(width: 1200, height: 750)
}
