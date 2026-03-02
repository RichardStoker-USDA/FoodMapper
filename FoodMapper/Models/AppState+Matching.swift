import SwiftUI
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

extension AppState {

    // MARK: - File Operations

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DataFileFormat.allUTTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await self?.loadFile(from: url)
            }
        }
    }

    func loadFile(from url: URL) async {
        do {
            let file = try await CSVParser.parse(url: url)
            inputFile = file
            selectedColumn = nil
            results = []
            error = nil
            showMatchSetup = true
            sidebarSelection = .home
        } catch {
            self.error = AppError.fileLoadFailed(error.localizedDescription)
        }
    }

    /// Called when file picker loads a file successfully (from MatchSetupView)
    func handleFileLoaded(_ file: InputFile) {
        selectedColumn = nil
        results = []
        error = nil
        showMatchSetup = true
        sidebarSelection = .home
    }

    // MARK: - Matching Operations

    func runMatching() {
        guard canRun,
              let file = inputFile,
              let column = selectedColumn,
              let database = selectedDatabase else { return }

        // Check if any required models (with selected sizes) are missing and prompt for download
        let requiredKeys = requiredModelKeysForCurrentPipeline
        let missing = requiredKeys.compactMap { key -> RegisteredModel? in
            let state = modelManager.state(for: key)
            guard !state.isAvailable else { return nil }
            return modelManager.registeredModel(for: key)
        }
        if !missing.isEmpty {
            pendingDownloadModels = missing
            showModelDownloadSheet = true
            return
        }

        isProcessing = true
        userNavigatedAwayDuringMatching = false
        matchingPhase = .loadingDatabase
        results = []
        error = nil

        let inputs = file.values(for: column)
        let totalCount = inputs.count
        progress = Progress(totalUnitCount: Int64(totalCount))
        matchingCompleted = 0

        // Capture pipeline type and model keys for this run (user could change selection during matching)
        let pipelineType = selectedPipelineType
        let embeddingKey = embeddingModelKeyForCurrentPipeline
        let rerankerKey = selectedRerankerModelKey
        let generativeKey = selectedGenerativeModelKey

        matchingTask = Task {
            do {
                let engine = try await getOrCreateEngine()

                // Load the correct embedding model via ModelManager (uses selected size)
                if let embeddingKey = embeddingKey {
                    let model = try await self.modelManager.loadEmbeddingModel(key: embeddingKey)
                    await engine.setEmbeddingModel(model)
                    logger.info("Using embedding model: \(embeddingKey) (\(model.info.displayName), \(model.info.dimensions)-dim)")
                }

                await MainActor.run {
                    self.matchingPhase = .embeddingInputs
                }

                let pipeline = try await self.createPipeline(
                    type: pipelineType, engine: engine,
                    rerankerKey: rerankerKey, generativeKey: generativeKey
                )

                let hwConfig = self.effectiveHardwareConfig(for: pipelineType)
                // Route the correct instruction tier per pipeline type
                let rerankerInst: String?
                switch pipelineType {
                case .gteLargeHaikuV2:
                    // V2 system prompt is self-contained. Only append user-provided custom text.
                    if self.selectedInstructionPreset == .custom {
                        let text = self.customInstructionText.trimmingCharacters(in: .whitespacesAndNewlines)
                        rerankerInst = text.isEmpty ? nil : text
                    } else {
                        rerankerInst = nil
                    }
                case .gteLargeHaiku:
                    rerankerInst = self.resolvedHaikuPrompt
                case .qwen3LLMOnly, .embeddingLLM:
                    rerankerInst = self.resolvedJudgeInstruction
                default:
                    rerankerInst = self.resolvedRerankerInstruction
                }

                // Log instruction routing at the AppState level
                logger.info("[AppState] runMatching | Pipeline: \(pipelineType.displayName) | Preset: \(self.selectedInstructionPreset.displayName)")
                logger.info("[AppState] runMatching | instruction (embedding): \(self.resolvedEmbeddingInstruction?.prefix(100) ?? "(nil)")")
                logger.info("[AppState] runMatching | rerankerInstruction (2nd stage): \(rerankerInst?.prefix(100) ?? "(nil)")")

                let matchResults = try await pipeline.match(
                    inputs: inputs,
                    database: database,
                    threshold: threshold,
                    hardwareConfig: hwConfig,
                    instruction: self.resolvedEmbeddingInstruction,
                    rerankerInstruction: rerankerInst,
                    onProgress: { [weak self] completed in
                        Task { @MainActor in
                            self?.progress?.completedUnitCount = Int64(completed)
                            self?.matchingCompleted = completed
                        }
                    },
                    onPhaseChange: { [weak self] phase in
                        Task { @MainActor in
                            self?.matchingPhase = phase
                            // Track batch start time when entering batch phase
                            if phase.isBatchWaiting && self?.batchStartTime == nil {
                                self?.batchStartTime = Date()
                            }
                            // Persist batchId when batch is submitted
                            if case .batchSubmitted = phase {
                                if let haikuPipeline = pipeline as? HaikuRerankerPipeline {
                                    Task {
                                        if let batchId = await haikuPipeline.getActiveBatchId() {
                                            await MainActor.run {
                                                self?.persistBatchState(batchId: batchId)
                                            }
                                        }
                                    }
                                }
                            }
                            // Clear batch tracking when leaving batch phase
                            if !phase.isBatchWaiting && phase != .idle {
                                self?.batchStartTime = nil
                                self?.activeBatchId = nil
                                self?.clearPersistedBatchState()
                            }
                        }
                    }
                )

                // Collect API tier + token usage from Haiku pipeline
                var apiTokensUsed: Int? = nil
                if let haikuPipeline = pipeline as? HaikuRerankerPipeline {
                    let detectedTier = await haikuPipeline.getDetectedTier()
                    let tokens = haikuPipeline.totalInputTokens + haikuPipeline.totalOutputTokens
                    apiTokensUsed = tokens > 0 ? tokens : nil
                    await MainActor.run {
                        if detectedTier != .unknown {
                            self.detectedAPITier = detectedTier
                        }
                    }
                }

                // Capture state needed for branching before modifying @Published properties
                let userWasAway = await MainActor.run { self.userNavigatedAwayDuringMatching }
                let pipelineType = await MainActor.run { self.selectedPipelineType }
                let userMatchThresh = await MainActor.run { self.userMatchThreshold }
                let userRejectThresh = await MainActor.run { self.userRejectThreshold }
                let autoMatchFloor = await MainActor.run { self.autoMatchScoreFloor }
                let autoMatchGap = await MainActor.run { self.autoMatchMinGap }

                // Clear non-UI matching metadata. Keep isProcessing, progress, and
                // matchingPhase intact so the progress view stays visible until
                // results are ready in Block 2.
                await MainActor.run {
                    self.matchingPhase = .savingResults
                    self.batchStartTime = nil
                    self.activeBatchId = nil
                    self.clearPersistedBatchState()
                    self.userNavigatedAwayDuringMatching = false
                }

                if userWasAway {
                    // User navigated away during matching: stash results, show banner, save to disk
                    await MainActor.run {
                        self.isProcessing = false
                        self.progress = nil
                        self.matchingPhase = .idle
                        self.pendingResults = matchResults
                        self.hasUnviewedResults = true
                        self.matchCompleteBannerCount = matchResults.count
                        self.showMatchCompleteBanner = true
                        self.scheduleBannerDismiss()
                        self.saveSessionFromResults(matchResults, apiTokensUsed: apiTokensUsed)
                        // Capture pendingSessionId AFTER saveSessionFromResults sets currentSessionId
                        self.pendingSessionId = self.currentSessionId
                        self.embeddingCacheVersion += 1

                        // Unload models to free GPU memory
                        Task {
                            await self.modelManager.unloadEmbeddingModel()
                            await self.modelManager.unloadRerankerModel()
                            await self.modelManager.unloadGenerativeModel()
                            MLX.Memory.clearCache()
                        }
                    }
                } else {
                    // Compute triage + filtering + sorting + categories on a background thread.
                    // This avoids blocking the main thread for large result sets (10K+).
                    let (triageDecisions, sortedFiltered, precomputedCategories) = await Task.detached(priority: .userInitiated) {
                        let profile = AppState.effectiveProfile(
                            userMatchThreshold: userMatchThresh,
                            userRejectThreshold: userRejectThresh,
                            pipelineType: pipelineType
                        )
                        let triage = AppState.computeTriageDecisions(
                            results: matchResults,
                            existingDecisions: [:],
                            pipelineType: pipelineType,
                            userMatchThreshold: userMatchThresh,
                            userRejectThreshold: userRejectThresh,
                            autoMatchScoreFloor: autoMatchFloor,
                            autoMatchMinGap: autoMatchGap
                        )
                        let filtered = AppState.computeFilteredSortedResults(
                            results: matchResults,
                            reviewDecisions: triage,
                            filter: .all,
                            searchText: "",
                            profile: profile
                        )
                        // Pre-compute categories off main thread (avoids rebuildAllCategories() blocking UI)
                        var cats: [UUID: MatchCategory] = Dictionary(minimumCapacity: matchResults.count)
                        for result in matchResults {
                            cats[result.id] = MatchCategory.from(result: result, decision: triage[result.id], profile: profile)
                        }
                        return (triage, filtered, cats)
                    }.value

                    // Apply everything atomically on main thread -- single @Published update batch.
                    // Keep this block lean: no file I/O, no expensive loops.
                    await MainActor.run {
                        self.suppressFilterUpdates = true
                        self.resultsReady = false

                        self.results = matchResults
                        self.reviewDecisions = triageDecisions
                        self.resultsFilter = .all
                        self.isReviewMode = false
                        self.currentPage = 0
                        self.sortOrder = [.init(\.score, order: .reverse)]
                        self.sortDebounceTask?.cancel()

                        // Set pre-computed cached results directly (skip redundant filter+sort)
                        self.cachedUnsortedFilteredResults = sortedFiltered
                        self.cachedFilteredResults = sortedFiltered

                        // Apply pre-computed categories (no main-thread loop needed)
                        self.cachedCategories = precomputedCategories
                        self.rebuildCategoryCounts()

                        self.isProcessing = false
                        self.progress = nil
                        self.matchingPhase = .idle
                        self.showMatchSetup = false
                        self.viewingResults = true
                        self.sidebarVisibility = .detailOnly
                        self.showInspector = true
                        self.showCompletionOverlay = true

                        self.suppressFilterUpdates = false

                        // Embeddings may have been created on disk during matching;
                        // bump version so embeddingMismatchNotice re-evaluates.
                        self.embeddingCacheVersion += 1
                    }

                    // Heavy post-completion work runs after the overlay is visible.
                    // Build candidate index + pre-encode JSON on background thread,
                    // then do lightweight save + flip resultsReady on main thread.
                    let readyStart = ContinuousClock.now

                    // Build candidate index and pre-encode results JSON off main thread.
                    // JSON encoding 2K+ MatchResult objects with candidates is expensive
                    // and would otherwise block the main thread for 1-2 seconds.
                    let (candidateIndex, preEncodedResults, preEncodedDecisions) = await Task.detached(priority: .userInitiated) {
                        var seen = Set<String>()
                        var unique: [MatchCandidate] = []
                        for result in matchResults {
                            guard let candidates = result.candidates else { continue }
                            for candidate in candidates {
                                let key = candidate.matchText.lowercased()
                                guard !seen.contains(key) else { continue }
                                seen.insert(key)
                                unique.append(candidate)
                            }
                        }
                        let resultsData = try? JSONEncoder().encode(matchResults)
                        let decisionsData = try? JSONEncoder().encode(triageDecisions)
                        return (unique, resultsData, decisionsData)
                    }.value

                    await MainActor.run {
                        self.allUniqueCandidates = candidateIndex

                        // Save session using pre-encoded data (avoids re-encoding on main thread)
                        self.saveSessionPreEncoded(
                            preEncodedResults: preEncodedResults,
                            resultCount: matchResults.count,
                            apiTokensUsed: apiTokensUsed
                        )
                        self.saveReviewDecisionsPreEncoded(preEncodedDecisions)
                    }

                    // Ensure a minimum "preparing" display of 0.3s so it doesn't flash
                    let elapsed = ContinuousClock.now - readyStart
                    if elapsed < .milliseconds(300) {
                        try? await Task.sleep(for: .milliseconds(300) - elapsed)
                    }

                    await MainActor.run {
                        self.resultsReady = true
                    }

                    // Unload models to free GPU memory (fire and forget)
                    Task {
                        await self.modelManager.unloadEmbeddingModel()
                        await self.modelManager.unloadRerankerModel()
                        await self.modelManager.unloadGenerativeModel()
                        MLX.Memory.clearCache()
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isProcessing = false
                    self.matchingPhase = .idle
                    self.progress = nil
                    self.batchStartTime = nil
                    self.activeBatchId = nil
                    self.clearPersistedBatchState()

                    // Unload models to free GPU memory
                    Task {
                        await self.modelManager.unloadEmbeddingModel()
                        await self.modelManager.unloadRerankerModel()
                        await self.modelManager.unloadGenerativeModel()
                        MLX.Memory.clearCache()
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = AppError.matchingFailed(error.localizedDescription)
                    self.isProcessing = false
                    self.matchingPhase = .idle
                    self.progress = nil
                    self.batchStartTime = nil
                    self.activeBatchId = nil
                    self.clearPersistedBatchState()

                    // Unload models to free GPU memory
                    Task {
                        await self.modelManager.unloadEmbeddingModel()
                        await self.modelManager.unloadRerankerModel()
                        await self.modelManager.unloadGenerativeModel()
                        MLX.Memory.clearCache()
                    }
                }
            }
        }
    }

    /// Create the appropriate pipeline for the selected type.
    /// Uses the provided model keys (captured at match start) to load the correct model sizes.
    func createPipeline(
        type: PipelineType,
        engine: MatchingEngine,
        rerankerKey: String = "qwen3-reranker-0.6b",
        generativeKey: String = "qwen3-judge-4b-4bit",
        judgeResponseFormat: JudgeResponseFormat = .letter,
        allowThinking: Bool = false
    ) async throws -> any MatchingPipelineProtocol {
        switch type {
        case .gteLargeEmbedding:
            return EmbeddingOnlyPipeline(type: .gteLargeEmbedding, engine: engine)
        case .qwen3Embedding:
            return EmbeddingOnlyPipeline(type: .qwen3Embedding, engine: engine)
        case .qwen3Reranker:
            let reranker = try await modelManager.loadRerankerModel(key: rerankerKey)
            return RerankerOnlyPipeline(reranker: reranker, engine: engine)
        case .qwen3TwoStage:
            let reranker = try await modelManager.loadRerankerModel(key: rerankerKey)
            return TwoStagePipeline(engine: engine, reranker: reranker, hardwareConfig: effectiveHardwareConfig(for: .qwen3TwoStage))
        case .qwen3SmartTriage:
            let reranker = try await modelManager.loadRerankerModel(key: rerankerKey)
            let triageConfig = effectiveHardwareConfig(for: .qwen3SmartTriage)
            return SmartTriagePipeline(engine: engine, reranker: reranker, topK: triageConfig.topKForReranking)
        case .gteLargeHaiku:
            guard let apiKey = APIKeyStorage.getAnthropicAPIKey(), !apiKey.isEmpty else {
                throw AppError.apiKeyRequired
            }
            let apiClient = AnthropicAPIClient(modelVersion: selectedClaudeModel)
            let haikuConfig = effectiveHardwareConfig(for: .gteLargeHaiku)
            return HaikuRerankerPipeline(
                engine: engine, apiClient: apiClient, apiKey: apiKey,
                topK: haikuConfig.topKForReranking, modelVersion: selectedClaudeModel,
                promptStrategy: .production
            )
        case .gteLargeHaikuV2:
            guard let apiKey = APIKeyStorage.getAnthropicAPIKey(), !apiKey.isEmpty else {
                throw AppError.apiKeyRequired
            }
            let apiClient = AnthropicAPIClient(modelVersion: selectedClaudeModel)
            let v2Config = effectiveHardwareConfig(for: .gteLargeHaikuV2)
            return HaikuRerankerV2Pipeline(
                engine: engine, apiClient: apiClient, apiKey: apiKey,
                topK: v2Config.topKForReranking, modelVersion: selectedClaudeModel
            )
        case .qwen3LLMOnly:
            let judge = try await modelManager.loadGenerativeModel(key: generativeKey)
            return LLMOnlyPipeline(
                judge: judge, engine: engine,
                responseFormat: judgeResponseFormat, allowThinking: allowThinking
            )
        case .embeddingLLM:
            let judge = try await modelManager.loadGenerativeModel(key: generativeKey)
            return EmbeddingLLMPipeline(
                engine: engine, judge: judge, hardwareConfig: effectiveHardwareConfig(for: .embeddingLLM),
                responseFormat: judgeResponseFormat, allowThinking: allowThinking
            )
        }
    }

    func cancelMatching() {
        Task {
            await matchingEngine?.cancel()
            // Free GPU intermediate buffers after cancellation
            MLX.Memory.clearCache()
        }
        matchingTask?.cancel()
        isProcessing = false
        matchingPhase = .idle
        progress = nil
        batchStartTime = nil
        activeBatchId = nil
        clearPersistedBatchState()
    }

    func getOrCreateEngine() async throws -> MatchingEngine {
        if let engine = matchingEngine {
            return engine
        }
        let engine = try await MatchingEngine()
        matchingEngine = engine
        return engine
    }

    /// Separate MatchingEngine for tour/showcase so it never interferes with production matching.
    func getOrCreateTourEngine() async throws -> MatchingEngine {
        if let engine = tourEngine {
            return engine
        }
        let engine = try await MatchingEngine()
        tourEngine = engine
        return engine
    }

    /// Current pipeline name for active matching (used in exports and sessions)
    var currentPipelineName: String {
        currentSession?.pipelineName ?? selectedPipelineType.displayName
    }

    /// Find current session by ID
    var currentSession: MatchingSession? {
        guard let id = currentSessionId else { return nil }
        return sessions.first(where: { $0.id == id })
    }
}
