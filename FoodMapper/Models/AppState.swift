import SwiftUI
import Combine
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

/// Sidebar navigation destinations
enum NavigationItem: String, CaseIterable, Identifiable {
    case home
    case inputFiles
    case databases
    case history
    case pipelineOverview
    case pipelineConfig
    case benchmarks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .inputFiles: return "Input Files"
        case .databases: return "Databases"
        case .history: return "History"
        case .pipelineOverview: return "Overview"
        case .pipelineConfig: return "Configuration"
        case .benchmarks: return "Benchmarks"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .inputFiles: return "doc.on.doc"
        case .databases: return "internaldrive"
        case .history: return "clock"
        case .pipelineOverview: return "list.bullet.rectangle"
        case .pipelineConfig: return "slider.horizontal.3"
        case .benchmarks: return "chart.bar.xaxis"
        }
    }

    /// Whether this item is visible in simple mode
    var isVisibleInSimpleMode: Bool {
        switch self {
        case .benchmarks, .pipelineOverview, .pipelineConfig: return false
        default: return true
        }
    }

    /// Whether this item belongs to the Pipelines section
    var isPipelineItem: Bool {
        switch self {
        case .pipelineOverview, .pipelineConfig, .benchmarks: return true
        default: return false
        }
    }

    /// Items that appear in the main navigation section
    static var mainItems: [NavigationItem] {
        [.home, .inputFiles, .databases, .history]
    }

    /// Items that appear in the Pipelines section (advanced mode only)
    static var pipelineItems: [NavigationItem] {
        [.pipelineOverview, .pipelineConfig, .benchmarks]
    }
}

/// Captures navigation page state for back/forward history
struct NavigationSnapshot: Equatable {
    let sidebarSelection: NavigationItem?
    let showMatchSetup: Bool
    let viewingResults: Bool
    let selectedPipelineMode: PipelineMode?
}

@MainActor
final class AppState: ObservableObject {
    // Input state
    @Published var inputFile: InputFile?
    @Published var selectedColumn: String?

    // Stored input files
    @Published var storedInputFiles: [StoredInputFile] = []

    // Database state
    @Published var selectedDatabase: AnyDatabase? = nil {
        didSet { loadTargetDatabaseSample() }
    }
    @Published var customDatabases: [CustomDatabase] = []
    @Published var targetDatabaseSample: [String] = []

    // Configuration
    @Published var threshold: Double = 0.85 {
        didSet {
            if !suppressFilterUpdates {
                updateFilteredResults()
                autoSaveThreshold()
            }
        }
    }

    // Processing state
    @Published var isProcessing = false
    @Published var progress: Progress?
    @Published var matchingCompleted: Int = 0
    @Published var matchingPhase: MatchingPhase = .idle
    @Published var error: AppError?

    // Batch API tracking (for elapsed timer and resume after force-quit)
    @Published var batchStartTime: Date?
    @Published var activeBatchId: String?

    // Database embedding state (for pre-embedding custom databases)
    @Published var databaseEmbeddingStatus: DatabaseEmbeddingStatus = .idle

    /// Bumped whenever embedding cache files change on disk, forcing SwiftUI views
    /// that depend on `hasEmbeddings(for:)` to re-evaluate.
    @Published var embeddingCacheVersion: Int = 0

    // Results state
    /// When true, property didSet observers skip updateFilteredResults() calls.
    /// Used during batch property updates (match completion, session load) to avoid
    /// redundant O(N) filter+sort passes that cause UI hangs.
    var suppressFilterUpdates = false

    @Published var results: [MatchResult] = [] {
        didSet {
            rebuildResultsByID()
            if !suppressFilterUpdates { updateFilteredResults() }
        }
    }
    @Published var selection: Set<MatchResult.ID> = []

    /// Row ID to scroll to after guided review navigation. Set by advanceToNext/PreviousPending(),
    /// consumed by ResultsTableView's ScrollViewReader. Cleared after scroll completes.
    @Published var tableScrollTarget: UUID? = nil
    @Published var searchText: String = ""
    @Published var sortOrder: [KeyPathComparator<MatchResult>] = [
        .init(\.inputRow, order: .forward)
    ] {
        didSet {
            sortDebounceTask?.cancel()
            sortDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                self.applySortOrder()
            }
        }
    }

    // Cached filtered results (avoids re-filtering 50K items every render)
    @Published var cachedFilteredResults: [MatchResult] = []

    // Cached category for each result (avoids redundant MatchCategory.from() calls across renders)
    @Published var cachedCategories: [UUID: MatchCategory] = [:]

    // Pre-computed category counts -- rebuilt when cachedCategories changes.
    // Not @Published: changes always accompany cachedCategories updates which already fire objectWillChange.
    var cachedCategoryCounts: [MatchCategory: Int] = [:]

    // O(1) lookup index for results by ID (avoids linear scans in single-item cache updates)
    var resultsByID: [UUID: MatchResult] = [:]

    // Deduplicated candidate list for fast override search
    var allUniqueCandidates: [MatchCandidate] = []

    // Intermediate unsorted filtered results (avoids re-filtering on sort-only changes)
    var cachedUnsortedFilteredResults: [MatchResult] = []

    // Debounce task for sort order changes (prevents double-sort from double-click)
    var sortDebounceTask: Task<Void, Never>?

    // Monotonic version counters for background filter/sort tasks.
    // When overlapping requests race, only the most recent version's results
    // are applied -- older completions are silently discarded.
    var filterVersion: Int = 0
    var sortVersion: Int = 0

    // Whether a sort/filter operation is in progress (for large datasets).
    // Not @Published -- no view reads this, so avoid spurious objectWillChange fires.
    var isSorting: Bool = false

    // Review workflow state
    @Published var reviewDecisions: [UUID: ReviewDecision] = [:]
    /// Monotonic counter bumped on every review decision change.
    /// Watchers that need to detect in-place value changes (e.g. tutorial auto-advance)
    /// should use this instead of reviewDecisions.count, which doesn't change on replacement.
    @Published var reviewDecisionVersion: Int = 0
    @Published var isReviewMode: Bool = false
    @Published var showInspector: Bool = false
    @Published var resultsFilter: ResultsFilter = .all { didSet { if !suppressFilterUpdates { updateFilteredResults(resetPage: true) } } }
    var reviewUndoStack: [(UUID, ReviewDecision?)] = []
    let maxUndoStackSize = 50
    /// User override for match threshold (nil = use profile defaults).
    /// Uses a new key to avoid loading stale values from the old 3-zone system.
    @Published var userMatchThreshold: Double? = UserDefaults.standard.object(forKey: "userMatchThreshold_v2") as? Double {
        didSet {
            if let value = userMatchThreshold {
                UserDefaults.standard.set(value, forKey: "userMatchThreshold_v2")
            } else {
                UserDefaults.standard.removeObject(forKey: "userMatchThreshold_v2")
            }
        }
    }
    /// User override for the lowest threshold boundary (nil = use profile defaults).
    /// Uses a new key to avoid loading stale values from the old 3-zone system.
    @Published var userRejectThreshold: Double? = UserDefaults.standard.object(forKey: "userRejectThreshold_v2") as? Double {
        didSet {
            if let value = userRejectThreshold {
                UserDefaults.standard.set(value, forKey: "userRejectThreshold_v2")
            } else {
                UserDefaults.standard.removeObject(forKey: "userRejectThreshold_v2")
            }
        }
    }

    // Legacy accessor kept for backward compat
    var reviewAutoAcceptThreshold: Double {
        get { userMatchThreshold ?? ThresholdProfile.defaults(for: selectedPipelineType).matchThreshold }
        set { userMatchThreshold = newValue }
    }

    /// Number of items needing review (auto-needs-review + legacy statuses)
    var reviewPendingCount: Int {
        reviewDecisions.values.filter {
            $0.status == .autoNeedsReview || $0.status == .pending
            || $0.status == .autoLikelyMatch || $0.status == .autoUnlikelyMatch  // legacy sessions
        }.count
    }

    /// Number of items with a human review decision
    var reviewCompletedCount: Int {
        reviewDecisions.values.filter { $0.status.isHumanDecision }.count
    }

    /// Number of items that need review
    var reviewZoneCount: Int {
        cachedCategoryCounts[.needsReview, default: 0]
    }

    /// Counts by MatchCategory for the current results + decisions.
    /// Returns pre-computed cache -- O(1) instead of O(n) per call.
    func categoryCounts() -> [MatchCategory: Int] {
        return cachedCategoryCounts
    }

    /// Look up the cached category for a result. Falls back to .noMatch for unknown IDs.
    func category(for resultId: UUID) -> MatchCategory {
        cachedCategories[resultId] ?? .noMatch
    }

    /// Rebuild category cache for all results. Call after batch mutations.
    func rebuildAllCategories() {
        let profile = effectiveProfile()
        var cats: [UUID: MatchCategory] = Dictionary(minimumCapacity: results.count)
        for result in results {
            cats[result.id] = MatchCategory.from(result: result, decision: reviewDecisions[result.id], profile: profile)
        }
        cachedCategories = cats
        rebuildCategoryCounts()
    }

    /// Rebuild the category counts from cachedCategories. O(n) but only runs
    /// when categories actually change, not on every UI read.
    func rebuildCategoryCounts() {
        var counts: [MatchCategory: Int] = [:]
        for result in results {
            let cat = cachedCategories[result.id] ?? .noMatch
            counts[cat, default: 0] += 1
        }
        cachedCategoryCounts = counts
    }

    /// Incrementally update category counts when a single item's category changes.
    /// O(1) -- avoids full rebuild for individual review decisions.
    func updateCategoryCount(oldCategory: MatchCategory, newCategory: MatchCategory) {
        guard oldCategory != newCategory else { return }
        cachedCategoryCounts[oldCategory, default: 0] -= 1
        if cachedCategoryCounts[oldCategory, default: 0] <= 0 {
            cachedCategoryCounts.removeValue(forKey: oldCategory)
        }
        cachedCategoryCounts[newCategory, default: 0] += 1
    }

    /// Rebuild the resultsByID index. Call when results array changes.
    func rebuildResultsByID() {
        var index: [UUID: MatchResult] = Dictionary(minimumCapacity: results.count)
        for result in results {
            index[result.id] = result
        }
        resultsByID = index
    }

    /// Build deduplicated candidate list for fast override search.
    func buildCandidateIndex() {
        var seen = Set<String>()
        var unique: [MatchCandidate] = []
        for result in results {
            guard let candidates = result.candidates else { continue }
            for candidate in candidates {
                let key = candidate.matchText.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                unique.append(candidate)
            }
        }
        allUniqueCandidates = unique
    }

    /// Search deduplicated candidates by substring match.
    func searchCandidates(query: String, limit: Int = 10) -> [MatchCandidate] {
        guard query.count >= 2 else { return [] }
        let q = query.lowercased()
        var hits: [MatchCandidate] = []
        for candidate in allUniqueCandidates {
            if candidate.matchText.lowercased().contains(q) {
                hits.append(candidate)
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    // Pagination state
    @Published var currentPage: Int = 0
    @Published var pageSize: Int = UserDefaults.standard.integer(forKey: "pageSize").nonZeroOr(200)

    // Hardware configuration (detected at launch)
    @Published var hardwareConfig: HardwareConfig

    // Model management
    @Published var modelManager: ModelManager

    // Simple/Advanced toggle (persisted via UserDefaults)
    @Published var isAdvancedMode: Bool = UserDefaults.standard.bool(forKey: "isAdvancedMode") {
        didSet {
            UserDefaults.standard.set(isAdvancedMode, forKey: "isAdvancedMode")
            // Navigate away from advanced-only pages when switching to simple mode
            if !isAdvancedMode, let sel = sidebarSelection, !sel.isVisibleInSimpleMode {
                sidebarSelection = .home
            }
        }
    }

    // Smart auto-match thresholds for embedding-only pipelines (persisted via UserDefaults)
    // When the top candidate scores above the floor AND the gap to #2 exceeds minGap,
    // the result is auto-marked as Match instead of Needs Review. Tuned for GTE-Large.
    @Published var autoMatchScoreFloor: Double = UserDefaults.standard.object(forKey: "autoMatchScoreFloor") as? Double ?? 0.95 {
        didSet { UserDefaults.standard.set(autoMatchScoreFloor, forKey: "autoMatchScoreFloor") }
    }
    @Published var autoMatchMinGap: Double = UserDefaults.standard.object(forKey: "autoMatchMinGap") as? Double ?? 0.01 {
        didSet { UserDefaults.standard.set(autoMatchMinGap, forKey: "autoMatchMinGap") }
    }

    // Claude model version (persisted via UserDefaults)
    @Published var selectedClaudeModel: ClaudeModelVersion = {
        if let raw = UserDefaults.standard.string(forKey: "selectedHaikuModel"),
           let version = ClaudeModelVersion(rawValue: raw) {
            return version
        }
        return .haiku3
    }() {
        didSet { UserDefaults.standard.set(selectedClaudeModel.rawValue, forKey: "selectedHaikuModel") }
    }

    // Model size selection (persisted via UserDefaults)
    @Published var selectedEmbeddingSize: ModelSize = {
        if let raw = UserDefaults.standard.string(forKey: "selectedEmbeddingSize"),
           let size = ModelSize(rawValue: raw) { return size }
        return .medium
    }() {
        didSet { UserDefaults.standard.set(selectedEmbeddingSize.rawValue, forKey: "selectedEmbeddingSize") }
    }

    @Published var selectedRerankerSize: ModelSize = {
        if let raw = UserDefaults.standard.string(forKey: "selectedRerankerSize"),
           let size = ModelSize(rawValue: raw) { return size }
        return .small
    }() {
        didSet { UserDefaults.standard.set(selectedRerankerSize.rawValue, forKey: "selectedRerankerSize") }
    }

    @Published var selectedGenerativeSize: ModelSize = {
        if let raw = UserDefaults.standard.string(forKey: "selectedGenerativeSize"),
           let size = ModelSize(rawValue: raw) { return size }
        return .medium
    }() {
        didSet { UserDefaults.standard.set(selectedGenerativeSize.rawValue, forKey: "selectedGenerativeSize") }
    }

    /// Resolved embedding model key based on selected size
    var selectedEmbeddingModelKey: String {
        ModelFamily.qwen3Embedding.modelKey(for: selectedEmbeddingSize) ?? "qwen3-emb-4b-4bit"
    }

    /// Resolved reranker model key based on selected size
    var selectedRerankerModelKey: String {
        ModelFamily.qwen3Reranker.modelKey(for: selectedRerankerSize) ?? "qwen3-reranker-0.6b"
    }

    /// Resolved generative judge model key based on selected size
    var selectedGenerativeModelKey: String {
        ModelFamily.qwen3Generative.modelKey(for: selectedGenerativeSize) ?? "qwen3-judge-4b-4bit"
    }

    /// Required model keys for the current pipeline type + selected sizes.
    /// Unlike PipelineType.requiredModelKeys (which uses hardcoded defaults),
    /// this accounts for the user's model size selections.
    var requiredModelKeysForCurrentPipeline: [String] {
        switch selectedPipelineType {
        case .gteLargeEmbedding: return ["gte-large"]
        case .qwen3Embedding: return [selectedEmbeddingModelKey]
        case .qwen3Reranker: return [selectedRerankerModelKey]
        case .qwen3TwoStage: return [selectedEmbeddingModelKey, selectedRerankerModelKey]
        case .gteLargeHaiku, .gteLargeHaikuV2: return ["gte-large"]
        case .qwen3SmartTriage: return [selectedEmbeddingModelKey, selectedRerankerModelKey]
        case .qwen3LLMOnly: return [selectedGenerativeModelKey]
        case .embeddingLLM: return [selectedEmbeddingModelKey, selectedGenerativeModelKey]
        }
    }

    /// Embedding model key for the current pipeline + selected sizes
    var embeddingModelKeyForCurrentPipeline: String? {
        switch selectedPipelineType {
        case .gteLargeEmbedding, .gteLargeHaiku, .gteLargeHaikuV2: return "gte-large"
        case .qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM:
            return selectedEmbeddingModelKey
        case .qwen3Reranker, .qwen3LLMOnly: return nil
        }
    }

    // Pipeline selection
    @Published var selectedPipelineMode: PipelineMode? = .standard
    @Published var selectedPipelineType: PipelineType = .gteLargeEmbedding {
        didSet {
            guard !isSyncingPipeline else { return }
            isSyncingPipeline = true
            if selectedPipelineType == .gteLargeHaiku {
                enableHaikuVerification = true
            } else {
                enableHaikuVerification = false
            }
            isSyncingPipeline = false
        }
    }

    /// Haiku verification toggle (synced bidirectionally with selectedPipelineType)
    @Published var enableHaikuVerification: Bool = false {
        didSet {
            guard !isSyncingPipeline else { return }
            isSyncingPipeline = true
            if enableHaikuVerification {
                selectedPipelineType = .gteLargeHaiku
            } else if selectedPipelineType == .gteLargeHaiku {
                selectedPipelineType = .gteLargeEmbedding
            }
            isSyncingPipeline = false
        }
    }

    /// Prevents infinite didSet loops between selectedPipelineType and enableHaikuVerification
    var isSyncingPipeline = false

    // Model download sheet (contextual Qwen3 downloads)
    @Published var showModelDownloadSheet = false
    @Published var pendingDownloadModels: [RegisteredModel] = []

    // Custom matching instruction
    @Published var selectedInstructionPreset: InstructionPreset = .bestMatch
    @Published var customInstructionText: String = ""

    // API tier detection (session-only, not persisted)
    @Published var detectedAPITier: APITier = .unknown

    // API key presence (reads from UserDefaults, no system dialogs)
    @Published private(set) var cachedHasAPIKey: Bool = false

    /// Refresh the cached API key state. Call after save/delete.
    func refreshAPIKeyState() {
        cachedHasAPIKey = APIKeyStorage.hasAnthropicAPIKey()
    }

    /// Effective API tier: user override if set, otherwise auto-detected
    var effectiveAPITier: APITier {
        if let override = advancedSettings.apiTierOverride,
           let tier = APITier(rawValue: override) {
            return tier
        }
        return detectedAPITier
    }

    /// Resolved embedding instruction text based on preset selection and pipeline support
    var resolvedEmbeddingInstruction: String? {
        guard selectedPipelineType.supportsCustomInstruction else { return nil }
        if selectedInstructionPreset == .custom {
            return customInstructionText.isEmpty ? nil : customInstructionText
        }
        return selectedInstructionPreset.embeddingInstruction
    }

    /// Resolved reranker instruction for cross-encoder or Haiku reranking stage
    var resolvedRerankerInstruction: String? {
        if selectedInstructionPreset == .custom {
            return customInstructionText.isEmpty ? nil : customInstructionText
        }
        return selectedInstructionPreset.rerankerInstruction
    }

    /// Resolved judge instruction for on-device generative LLM selection
    var resolvedJudgeInstruction: String? {
        if selectedInstructionPreset == .custom {
            return customInstructionText.isEmpty ? nil : customInstructionText
        }
        return selectedInstructionPreset.judgeInstruction
    }

    /// Resolved Haiku prompt for Claude Haiku LLM reranking
    var resolvedHaikuPrompt: String? {
        if selectedInstructionPreset == .custom {
            return customInstructionText.isEmpty ? nil : customInstructionText
        }
        return selectedInstructionPreset.haikuPrompt
    }

    // Advanced settings (user overrides)
    @Published var advancedSettings: AdvancedSettings = .default

    /// Per-pipeline performance overrides, keyed by PipelineType.rawValue.
    /// nil values within each config fall back to pipeline+model defaults.
    @Published var pipelinePerformanceOverrides: [String: PipelinePerformanceConfig] = {
        guard let data = UserDefaults.standard.data(forKey: "pipelinePerformanceOverrides"),
              let decoded = try? JSONDecoder().decode([String: PipelinePerformanceConfig].self, from: data) else {
            return [:]
        }
        return decoded
    }() {
        didSet { savePipelinePerformanceOverrides() }
    }

    // Effective batch sizes (computed from hardware + user overrides)
    var effectiveMatchingBatchSize: Int {
        advancedSettings.effectiveMatchingBatchSize(hardwareDefault: hardwareConfig.matchingBatchSize)
    }

    var effectiveEmbeddingBatchSize: Int {
        advancedSettings.effectiveEmbeddingBatchSize(hardwareDefault: hardwareConfig.embeddingBatchSize)
    }

    var effectiveChunkSize: Int {
        advancedSettings.effectiveChunkSize(hardwareDefault: hardwareConfig.chunkSize)
    }

    /// Hardware config with user overrides applied (legacy fallback for tour/showcase)
    var effectiveHardwareConfig: HardwareConfig {
        hardwareConfig.withOverrides(
            embeddingBatchSize: advancedSettings.customEmbeddingBatchSize,
            matchingBatchSize: advancedSettings.customMatchingBatchSize,
            chunkSize: advancedSettings.customChunkSize,
            topKForReranking: advancedSettings.customTopKForReranking
        )
    }

    /// Build effective HardwareConfig for a specific pipeline, using per-pipeline
    /// overrides with smart defaults based on the pipeline type and model size.
    func effectiveHardwareConfig(for pipeline: PipelineType) -> HardwareConfig {
        let overrides = pipelinePerformanceOverrides[pipeline.rawValue]
        let modelKey = embeddingModelKeyForPipeline(pipeline)

        return hardwareConfig.withOverrides(
            embeddingBatchSize: overrides?.embeddingBatchSize ?? pipeline.defaultEmbeddingBatchSize(modelKey: modelKey),
            matchingBatchSize: overrides?.matchingBatchSize ?? pipeline.defaultMatchingBatchSize,
            chunkSize: overrides?.chunkSize ?? pipeline.defaultChunkSize,
            topKForReranking: overrides?.topK ?? pipeline.defaultTopK
        )
    }

    /// Embedding model key for a given pipeline type (accounts for selected model sizes)
    func embeddingModelKeyForPipeline(_ pipeline: PipelineType) -> String? {
        switch pipeline {
        case .gteLargeEmbedding, .gteLargeHaiku, .gteLargeHaikuV2: return "gte-large"
        case .qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM:
            return selectedEmbeddingModelKey
        case .qwen3Reranker, .qwen3LLMOnly: return nil
        }
    }

    func savePipelinePerformanceOverrides() {
        if let data = try? JSONEncoder().encode(pipelinePerformanceOverrides) {
            UserDefaults.standard.set(data, forKey: "pipelinePerformanceOverrides")
        }
    }

    // Model state
    @Published var modelStatus: ModelStatus = .notDownloaded

    // Navigation state
    @Published var sessions: [MatchingSession] = []
    @Published var sidebarSelection: NavigationItem? = .home {
        didSet {
            if !isProgrammaticNavigation && sidebarSelection != .home {
                viewingResults = false
            }
            if isProcessing && sidebarSelection != .home {
                userNavigatedAwayDuringMatching = true
            }
            recordNavigationSnapshot()
        }
    }
    @Published var showMatchSetup: Bool = false {
        didSet {
            recordNavigationSnapshot()
        }
    }
    @Published var viewingResults: Bool = false
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var currentSessionId: UUID?

    // Navigation history (back/forward)
    var navigationHistory: [NavigationSnapshot] = []
    var navigationHistoryIndex: Int = -1
    var isProgrammaticNavigation = false

    var canGoBack: Bool { navigationHistoryIndex > 0 }
    var canGoForward: Bool { navigationHistoryIndex < navigationHistory.count - 1 }

    /// Backwards-compatible computed property
    var showWelcome: Bool {
        sidebarSelection == .home && !showMatchSetup
    }

    /// Backwards-compatible computed property
    var showingFullHistory: Bool {
        sidebarSelection == .history
    }

    /// Whether pipeline selection is active (kept for compatibility, always false now)
    var showPipelineSelection: Bool { false }

    // Search focus state (set to true to programmatically focus the search field)
    @Published var searchFieldFocused = false

    // Inspector text field focus state -- suppresses review keyboard shortcuts while typing
    @Published var inspectorFieldFocused = false

    // Reset press-twice confirmation state (shared between keyboard handler and inspector button)
    @Published var resetPendingConfirmation = false
    var resetConfirmationWorkItem: DispatchWorkItem?

    // Bulk reset press-twice confirmation state (multi-select inspector)
    @Published var bulkResetPendingConfirmation = false
    var bulkResetConfirmationWorkItem: DispatchWorkItem?

    // Post-completion overlay (shown when user is on results page after match)
    @Published var showCompletionOverlay = false

    /// Whether post-match caches (categories, candidate index) and session save
    /// have completed. The completion overlay gates its action buttons on this
    /// so the user doesn't navigate to an unresponsive table.
    @Published var resultsReady = true

    // Notification state (matching completed while user was away)
    @Published var hasUnviewedResults = false
    @Published var showMatchCompleteBanner = false
    var matchCompleteBannerCount: Int = 0
    var bannerDismissTask: Task<Void, Never>?
    var userNavigatedAwayDuringMatching = false
    var pendingResults: [MatchResult]?
    var pendingSessionId: UUID?

    // Guided review banner (shown every time review mode is entered)
    @Published var showGuidedReviewBanner = false

    // Export toast
    @Published var showExportToast = false
    @Published var exportToastMessage: String?
    var exportToastDismissTask: Task<Void, Never>?

    // Behind the Research showcase state
    @Published var isInResearchShowcase: Bool = false
    @Published var tourDepth: TourDepth? = nil
    @Published var showSplashScreen: Bool = false
    @Published var tourEmbeddingResults: [MatchResult]? = nil
    @Published var tourEmbeddingProgress: Double = 0
    @Published var tourEmbeddingError: String? = nil

    // Tour hybrid matching state
    @Published var tourHybridResults: [MatchResult]? = nil
    @Published var tourHybridProgress: Double = 0
    @Published var tourHybridPhase: MatchingPhase = .idle
    @Published var tourHybridError: String? = nil

    // Benchmark state
    @Published var benchmarkDatasets: [BenchmarkDataset] = []
    @Published var benchmarkResults: [BenchmarkResult] = []
    @Published var isBenchmarkRunning: Bool = false
    @Published var benchmarkViewState: BenchmarkViewState = .empty
    @Published var benchmarkProgress: Double = 0
    @Published var benchmarkPhaseLabel: String = ""
    @Published var benchmarkRunningAccuracy: Double = 0
    @Published var benchmarkItemsCompleted: Int = 0
    @Published var benchmarkItemsTotal: Int = 0
    @Published var latestBenchmarkResult: BenchmarkResult?

    // Tutorial state
    @Published var tutorialState: TutorialState = TutorialState.load()
    @Published var showTutorial: Bool = false
    // NOT @Published -- writing frames from GeometryReaders must not trigger objectWillChange,
    // otherwise toolbar GeometryReaders cause infinite re-evaluation loops.
    // The TutorialOverlay reads this directly when it renders (triggered by showTutorial).
    var tutorialElementFrames: [String: CGRect] = [:]

    // Engine
    var matchingEngine: MatchingEngine?
    var tourEngine: MatchingEngine?
    var matchingTask: Task<Void, Never>?
    var embeddingTask: Task<Void, Never>?
    var tourHybridTask: Task<Void, Never>?
    var tourHybridApiClient: AnthropicAPIClient?
    var settingsObserver: NSObjectProtocol?
    var searchDebounce: AnyCancellable?
    var modelStateSubscription: AnyCancellable?
    var isVerifyingModelAfterDownload = false

    // Session storage
    var sessionsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FoodMapper/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var sessionsIndexURL: URL {
        sessionsDirectory.appendingPathComponent("sessions.json")
    }

    var benchmarksURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FoodMapper/benchmarks.json")
    }

    var benchmarkResultsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FoodMapper/BenchmarkResults", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Computed properties
    var canRun: Bool {
        inputFile != nil &&
        selectedColumn != nil &&
        selectedDatabase != nil &&
        !isProcessing &&
        !hasResults &&
        canRunSelectedPipeline
    }

    /// Whether results are currently displayed (prevents accidental re-run from results page)
    var hasResults: Bool { !results.isEmpty }

    /// Whether all models required by the selected pipeline (with current size selection) are available
    var canRunSelectedPipeline: Bool {
        let allAvailable = requiredModelKeysForCurrentPipeline.allSatisfy { key in
            modelManager.state(for: key).isAvailable
        }
        if selectedPipelineType == .gteLargeHaiku || selectedPipelineType == .gteLargeHaikuV2 {
            return allAvailable && hasAnthropicAPIKey
        }
        return allAvailable
    }

    /// Whether a valid Anthropic API key is stored
    var hasAnthropicAPIKey: Bool {
        cachedHasAPIKey
    }

    /// Toolbar match button state machine
    enum ToolbarMatchState: Equatable {
        case hidden, match, progress, matchComplete
    }

    var toolbarMatchState: ToolbarMatchState {
        if isProcessing { return .progress }
        if hasUnviewedResults { return .matchComplete }
        if sidebarSelection == .home && showMatchSetup && canRun { return .match }
        return .hidden
    }

    /// Count of matches at current threshold (updates in real-time as threshold changes)
    var matchedCount: Int {
        results.filter { $0.isMatched(at: threshold) }.count
    }

    var matchRate: Double {
        guard !results.isEmpty else { return 0 }
        return Double(matchedCount) / Double(results.count)
    }

    /// Count of matches in filtered results (for accurate stats across all pages)
    var totalFilteredMatchedCount: Int {
        filteredResults.filter { $0.isMatched(at: threshold) }.count
    }

    /// Count of items above threshold (for status bar)
    var aboveThresholdCount: Int {
        results.filter { $0.score >= threshold }.count
    }

    var statusMessage: String {
        if isProcessing {
            let phaseText = matchingPhase.displayText
            return phaseText.isEmpty ? "Processing..." : phaseText
        } else if results.isEmpty {
            return "Ready"
        } else {
            return "Complete"
        }
    }

    /// Alias for cached results (compatibility with existing call sites)
    var filteredResults: [MatchResult] { cachedFilteredResults }

    /// Paginated results for display
    var paginatedResults: [MatchResult] {
        let start = currentPage * pageSize
        let end = min(start + pageSize, cachedFilteredResults.count)
        guard start < cachedFilteredResults.count else { return [] }
        return Array(cachedFilteredResults[start..<end])
    }

    /// Total number of pages based on filtered results
    var totalPages: Int {
        max(1, (cachedFilteredResults.count + pageSize - 1) / pageSize)
    }

    /// Reset pagination when filter changes
    func resetPagination() {
        currentPage = 0
    }

    /// Recompute cached filtered results from source data.
    /// For large datasets (>2K), filtering runs on a background thread.
    /// `skipCategoryRebuild`: true when only search text changed (categories are stable).
    /// `resetPage`: true to reset pagination to page 0 atomically with the update (avoids extra objectWillChange).
    func updateFilteredResults(skipCategoryRebuild: Bool = false, resetPage: Bool = false) {
        let allResults = results
        let decisions = reviewDecisions
        let filter = resultsFilter
        let search = searchText
        let searchLower = search.lowercased()
        let order = sortOrder

        if allResults.count > 2_000 {
            isSorting = true
            filterVersion += 1
            let capturedVersion = filterVersion
            // For large datasets, compute categories + filter + sort entirely off main thread
            let needsCategoryRebuild = !skipCategoryRebuild
            let profile = effectiveProfile()
            Task.detached { [weak self] in
                // Build category dict on background thread
                var cats: [UUID: MatchCategory]
                if needsCategoryRebuild {
                    cats = Dictionary(minimumCapacity: allResults.count)
                    for result in allResults {
                        cats[result.id] = MatchCategory.from(result: result, decision: decisions[result.id], profile: profile)
                    }
                } else {
                    // Snapshot current cache (safe since we captured before detach)
                    cats = await MainActor.run { self?.cachedCategories ?? [:] }
                }

                let filtered = allResults.filter { result in
                    if filter != .all {
                        let isError = result.status == .error
                        let category = cats[result.id] ?? .noMatch
                        if !filter.matches(category: category, isError: isError) { return false }
                    }
                    if !search.isEmpty {
                        return result.inputText.lowercased().contains(searchLower) ||
                               (result.matchText?.lowercased().contains(searchLower) ?? false)
                    }
                    return true
                }
                let sorted = filtered.sorted(using: order)
                let shouldResetPage = resetPage
                await MainActor.run { [weak self] in
                    guard let self, self.filterVersion == capturedVersion else { return }
                    if needsCategoryRebuild {
                        self.cachedCategories = cats
                        self.rebuildCategoryCounts()
                    }
                    if shouldResetPage { self.currentPage = 0 }
                    self.cachedUnsortedFilteredResults = filtered
                    self.cachedFilteredResults = sorted
                    self.isSorting = false
                }
            }
        } else {
            // Small datasets: rebuild on main thread (fast enough).
            // Bump version to invalidate any in-flight background filter tasks
            // that were launched for a previously-larger dataset.
            filterVersion += 1
            isSorting = false
            if resetPage { currentPage = 0 }
            if !skipCategoryRebuild {
                rebuildAllCategories()
            }
            let cats = cachedCategories
            cachedUnsortedFilteredResults = allResults.filter { result in
                if filter != .all {
                    let isError = result.status == .error
                    let category = cats[result.id] ?? .noMatch
                    if !filter.matches(category: category, isError: isError) { return false }
                }
                if !search.isEmpty {
                    return result.inputText.lowercased().contains(searchLower) ||
                           (result.matchText?.lowercased().contains(searchLower) ?? false)
                }
                return true
            }
            applySortOrder()
        }
    }

    /// Apply sort order to the cached unsorted filtered results.
    /// For large datasets (>2K), runs sort on a background thread.
    func applySortOrder() {
        let unsorted = cachedUnsortedFilteredResults
        let order = sortOrder
        // Background sort for anything over 2K items to keep UI responsive.
        // Even 5K items can cause a noticeable hitch when sorting on main thread.
        if unsorted.count > 2_000 {
            isSorting = true
            sortVersion += 1
            let capturedVersion = sortVersion
            Task.detached { [weak self] in
                let sorted = unsorted.sorted(using: order)
                await MainActor.run { [weak self] in
                    guard let self, self.sortVersion == capturedVersion else { return }
                    self.cachedFilteredResults = sorted
                    self.isSorting = false
                }
            }
        } else {
            // Bump version to invalidate any in-flight background sort tasks
            // that were launched for a previously-larger dataset.
            sortVersion += 1
            cachedFilteredResults = unsorted.sorted(using: order)
            isSorting = false
        }
    }

    init() {
        // Detect hardware configuration at launch
        let hw = HardwareConfig.detect()
        hardwareConfig = hw
        hw.applyMLXCacheLimit()
        modelManager = ModelManager(hardwareConfig: hw)

        // One-time migration: clean up old 3-zone threshold keys
        // The old system used "reviewAutoAcceptThreshold" (default 0.78) and "reviewAutoRejectThreshold" (default 0.50).
        // These values would poison the new 4-zone system (0.78 < 0.85 likelyMatch threshold = broken hierarchy).
        if !UserDefaults.standard.bool(forKey: "thresholdMigration_v2_done") {
            UserDefaults.standard.removeObject(forKey: "reviewAutoAcceptThreshold")
            UserDefaults.standard.removeObject(forKey: "reviewAutoRejectThreshold")
            UserDefaults.standard.set(true, forKey: "thresholdMigration_v2_done")
        }

        // Load saved settings (including advanced settings)
        loadSettings()
        loadSessionsIndex()
        loadCustomDatabases()
        loadStoredInputFiles()
        loadTargetDatabaseSample()
        loadBenchmarkDatasets()
        loadBenchmarkResults()

        // Observe UserDefaults changes for settings synced via @AppStorage in SettingsView
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let newPageSize = UserDefaults.standard.integer(forKey: "pageSize").nonZeroOr(200)
                if self.pageSize != newPageSize {
                    self.pageSize = newPageSize
                    self.resetPagination()
                }
            }
        }

        // React to searchText changes -- the local @State in ResultsToolbar already
        // debounces keystrokes (150ms), so we just coalesce same-RunLoop updates here.
        searchDebounce = $searchText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateFilteredResults(skipCategoryRebuild: true, resetPage: true)
            }

        // Keep modelStatus in sync with ModelManager's GTE-Large state.
        // ModelManager updates modelStates during download via its progress callback,
        // but modelStatus (which the UI reads) was only set once at the start of downloadModel().
        modelStateSubscription = modelManager.$modelStates
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncModelStatus()
            }

        // Seed navigation history with initial state
        navigationHistory = [NavigationSnapshot(sidebarSelection: .home, showMatchSetup: false, viewingResults: false, selectedPipelineMode: .standard)]
        navigationHistoryIndex = 0

        // Migrate API key from Keychain if this is the first launch after the switch
        APIKeyStorage.migrateFromKeychainIfNeeded()

        // Cache API key presence
        refreshAPIKeyState()

        // Check model availability
        Task {
            await checkModelStatus()
        }
    }
}


// MARK: - Matching Phase

/// Phases of the matching process for progress feedback
enum MatchingPhase: Equatable {
    case idle
    case loadingDatabase
    case embeddingDatabase(completed: Int, total: Int)
    case embeddingInputs
    case computingSimilarity
    case reranking(completed: Int, total: Int)
    case batchSubmitting
    case batchSubmitted(taskCount: Int)
    case batchProcessing(succeeded: Int, total: Int)
    case batchReconnecting
    case savingResults

    var isActive: Bool { self != .idle }

    /// True when in any batch API waiting phase
    var isBatchWaiting: Bool {
        switch self {
        case .batchSubmitting, .batchSubmitted, .batchProcessing, .batchReconnecting:
            return true
        default:
            return false
        }
    }

    var displayText: String {
        switch self {
        case .idle: return ""
        case .loadingDatabase: return "Loading database..."
        case .embeddingDatabase(let completed, let total):
            return "Embedding database \(completed)/\(total)..."
        case .embeddingInputs: return "Embedding inputs..."
        case .computingSimilarity: return "Finding matches..."
        case .reranking(let completed, let total): return "Reranking \(completed)/\(total)..."
        case .batchSubmitting: return "Submitting to Anthropic..."
        case .batchSubmitted(let count): return "Sent \(count) items to Anthropic"
        case .batchProcessing(let succeeded, let total):
            return succeeded == 0 ? "Waiting on Anthropic..." : "\(succeeded)/\(total) processed"
        case .batchReconnecting: return "Reconnecting to Anthropic..."
        case .savingResults: return "Saving..."
        }
    }
}

// MARK: - Database Embedding Status

/// Status for pre-embedding custom databases when added
enum DatabaseEmbeddingStatus: Equatable {
    case idle
    case embedding(completed: Int, total: Int, databaseName: String, startTime: Date)
    case completed(databaseName: String, itemCount: Int, duration: TimeInterval)
    case error(String)

    var isEmbedding: Bool {
        if case .embedding = self { return true }
        return false
    }

    var progress: Double {
        switch self {
        case .embedding(let completed, let total, _, _):
            return total > 0 ? Double(completed) / Double(total) : 0
        case .completed:
            return 1.0
        default:
            return 0
        }
    }

    var displayText: String {
        switch self {
        case .idle:
            return ""
        case .embedding(let completed, let total, let name, _):
            return "Embedding \(name)... \(completed)/\(total)"
        case .completed(let name, _, _):
            return "\(name) ready"
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
}

// MARK: - Model Status

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case loading
    case ready(executionProvider: String)
    case error(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .notDownloaded: return "Model Required"
        case .downloading(let progress): return "Downloading \(Int(progress * 100))%"
        case .loading: return "Loading Model..."
        case .ready(let provider): return "Ready (\(provider))"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var shortText: String {
        switch self {
        case .notDownloaded: return "Model Missing"
        case .downloading: return "Downloading"
        case .loading: return "Loading"
        case .ready(let provider): return provider
        case .error: return "Error"
        }
    }
}

// MARK: - App Errors

enum AppError: LocalizedError, Identifiable {
    case fileLoadFailed(String)
    case matchingFailed(String)
    case exportFailed(String)
    case modelNotFound
    case modelLoadFailed(String)
    case apiKeyRequired

    var id: String {
        switch self {
        case .fileLoadFailed(let msg): return "file_\(msg)"
        case .matchingFailed(let msg): return "match_\(msg)"
        case .exportFailed(let msg): return "export_\(msg)"
        case .modelNotFound: return "model_not_found"
        case .modelLoadFailed(let msg): return "model_load_\(msg)"
        case .apiKeyRequired: return "api_key_required"
        }
    }

    var errorDescription: String? {
        switch self {
        case .fileLoadFailed(let msg): return "Failed to load file: \(msg)"
        case .matchingFailed(let msg): return "Matching failed: \(msg)"
        case .exportFailed(let msg): return "Export failed: \(msg)"
        case .modelNotFound: return "Embedding model not found"
        case .modelLoadFailed(let msg): return "Failed to load model: \(msg)"
        case .apiKeyRequired: return "Anthropic API key required. Add your key in Settings > API Keys."
        }
    }
}

// MARK: - Int Extension

extension Int {
    /// Returns self if non-zero, otherwise returns the default value
    func nonZeroOr(_ defaultValue: Int) -> Int {
        self != 0 ? self : defaultValue
    }
}

// MARK: - Download Progress Delegate

/// URLSession delegate for tracking download progress
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private var lastReportedProgress: Double = -1
    private let minimumProgressIncrement: Double = 0.01  // Report at least every 1%

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        // Only report if progress changed by at least minimumProgressIncrement
        // This prevents excessive UI updates while ensuring visibility
        if progress - lastReportedProgress >= minimumProgressIncrement || progress >= 1.0 {
            lastReportedProgress = progress
            DispatchQueue.main.async { [weak self] in
                self?.onProgress(progress)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Required delegate method - file handling done in async caller
    }
}
