import SwiftUI
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

extension AppState {


    // clearPipelineMode() removed -- unified home no longer needs pipeline mode reset

    // MARK: - Behind the Research Showcase

    /// Enter the Behind the Research scrolling showcase.
    func startResearchShowcase() {
        tourDepth = .walkthrough
        isInResearchShowcase = true
        sidebarVisibility = .detailOnly
    }

    /// Exit the showcase and return to the unified home screen.
    func exitResearchShowcase() {
        isInResearchShowcase = false
        tourDepth = nil
        tourEmbeddingResults = nil
        tourEmbeddingProgress = 0
        tourHybridResults = nil
        tourHybridProgress = 0
        tourHybridPhase = .idle
        tourHybridError = nil
        tourHybridTask?.cancel()
        tourHybridTask = nil
        tourHybridApiClient = nil
        tourEngine = nil
        sidebarVisibility = .all
        selectedPipelineMode = .standard
    }

    /// Exit the showcase and switch to Food Matching mode.
    func exitShowcaseToFoodMatching() {
        isInResearchShowcase = false
        tourDepth = nil
        tourEmbeddingResults = nil
        tourEmbeddingProgress = 0
        tourHybridResults = nil
        tourHybridProgress = 0
        tourHybridPhase = .idle
        tourHybridError = nil
        tourHybridTask?.cancel()
        tourHybridTask = nil
        tourHybridApiClient = nil
        tourEngine = nil
        sidebarVisibility = .all
        selectPipelineMode(.standard)
    }

    /// Run the showcase embedding match (full 1,304 NHANES vs DFG2 using GTE-Large).
    func runTourEmbeddingMatch() {
        tourEmbeddingResults = nil
        tourEmbeddingProgress = 0
        tourEmbeddingError = nil

        Task {
            do {
                // Check model availability before attempting to load
                let modelState = self.modelManager.state(for: "gte-large")
                guard modelState.isAvailable else {
                    self.tourEmbeddingError = "GTE-Large is not downloaded. Go to Settings > Models to download it."
                    self.tourEmbeddingResults = []
                    return
                }

                let tourItems = try await TourDataLoader.shared.loadFullBenchmarkItems()
                let inputs = tourItems.map { $0.inputDescription }

                let engine = try await getOrCreateTourEngine()
                let model = try await self.modelManager.loadEmbeddingModel(key: "gte-large")
                await engine.setEmbeddingModel(model)

                let pipeline = EmbeddingOnlyPipeline(type: .gteLargeEmbedding, engine: engine)
                let database = AnyDatabase.builtIn(.dfg2)
                let hwConfig = self.effectiveHardwareConfig
                let totalCount = inputs.count

                let results = try await pipeline.match(
                    inputs: inputs,
                    database: database,
                    threshold: 0.0,
                    hardwareConfig: hwConfig,
                    instruction: nil,
                    rerankerInstruction: nil,
                    onProgress: { [weak self] completed in
                        Task { @MainActor in
                            self?.tourEmbeddingProgress = Double(completed) / Double(totalCount)
                        }
                    },
                    onPhaseChange: nil
                )

                await MainActor.run {
                    self.tourEmbeddingResults = results
                    self.tourEmbeddingProgress = 1.0
                }
            } catch {
                logger.error("Tour embedding match failed: \(error.localizedDescription)")
                await MainActor.run {
                    let desc = error.localizedDescription.lowercased()
                    if desc.contains("not downloaded") || desc.contains("model not found") {
                        self.tourEmbeddingError = "GTE-Large is not downloaded. Go to Settings > Models to download it."
                    } else if desc.contains("memory") || desc.contains("allocation") {
                        self.tourEmbeddingError = "Not enough memory to load GTE-Large. Close other apps and try again."
                    } else {
                        self.tourEmbeddingError = error.localizedDescription
                    }
                    self.tourEmbeddingResults = []
                    self.tourEmbeddingProgress = 0
                }
            }
        }
    }

    /// Run the showcase hybrid match (full NHANES vs DFG2 using GTE-Large + Claude verification).
    func runTourHybridMatch(modelVersion: ClaudeModelVersion = .haiku3) {
        tourHybridResults = nil
        tourHybridProgress = 0
        tourHybridPhase = .idle
        tourHybridError = nil

        tourHybridTask = Task {
            do {
                // Load tour items
                let tourItems = try await TourDataLoader.shared.loadFullBenchmarkItems()
                let inputs = tourItems.map { $0.inputDescription }

                // Get API key
                guard let apiKey = APIKeyStorage.getAnthropicAPIKey(), !apiKey.isEmpty else {
                    await MainActor.run {
                        self.tourHybridError = "API key not found. Check Settings > API Keys."
                    }
                    return
                }

                // Set up engine and model (tour uses its own engine, separate from production)
                let engine = try await getOrCreateTourEngine()
                let model = try await self.modelManager.loadEmbeddingModel(key: "gte-large")
                await engine.setEmbeddingModel(model)

                // Create pipeline -- paper replication: always K=5, paper prompt format
                let apiClient = AnthropicAPIClient(modelVersion: modelVersion)
                self.tourHybridApiClient = apiClient
                let pipeline = HaikuRerankerPipeline(
                    engine: engine, apiClient: apiClient, apiKey: apiKey,
                    topK: 5, modelVersion: modelVersion,
                    promptStrategy: .paperReplication
                )

                let hwConfig = self.effectiveHardwareConfig
                let totalCount = inputs.count

                await MainActor.run {
                    self.tourHybridPhase = .embeddingInputs
                }

                let results = try await pipeline.match(
                    inputs: inputs,
                    database: .builtIn(.dfg2),
                    threshold: 0.0,
                    hardwareConfig: hwConfig,
                    instruction: nil,
                    rerankerInstruction: nil,
                    onProgress: { [weak self] completed in
                        Task { @MainActor in
                            self?.tourHybridProgress = Double(completed) / Double(totalCount)
                        }
                    },
                    onPhaseChange: { [weak self] phase in
                        Task { @MainActor in
                            self?.tourHybridPhase = phase
                        }
                    }
                )

                await MainActor.run {
                    self.tourHybridResults = results
                    self.tourHybridProgress = 1.0
                    self.tourHybridPhase = .idle
                    self.tourHybridApiClient = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.tourHybridPhase = .idle
                    self.tourHybridProgress = 0
                    self.tourHybridApiClient = nil
                }
            } catch {
                logger.error("Tour hybrid match failed: \(error.localizedDescription)")
                await MainActor.run {
                    let message: String
                    let desc = error.localizedDescription.lowercased()
                    if desc.contains("401") || desc.contains("authentication") || desc.contains("invalid") {
                        message = "API key is invalid or expired. Check Settings > API Keys."
                    } else if desc.contains("429") || desc.contains("rate") {
                        message = "Rate limited by Anthropic. Try again in a few minutes."
                    } else if desc.contains("network") || desc.contains("internet") || desc.contains("offline") || desc.contains("not connected") {
                        message = "Could not reach the Anthropic API. Check your internet connection."
                    } else {
                        message = error.localizedDescription
                    }
                    self.tourHybridError = message
                    self.tourHybridPhase = .idle
                    self.tourHybridApiClient = nil
                }
            }
        }
    }

    /// Cancel the in-progress tour hybrid match.
    func cancelTourHybridMatch() {
        tourHybridTask?.cancel()
        tourHybridTask = nil
        if let apiClient = tourHybridApiClient {
            Task {
                // Cancel the active Anthropic batch before setting the cancelled flag
                if let batchId = await apiClient.getActiveBatchId(),
                   let apiKey = APIKeyStorage.getAnthropicAPIKey() {
                    try? await apiClient.cancelBatch(batchId: batchId, apiKey: apiKey)
                }
                await apiClient.cancel()
            }
        }
        tourHybridApiClient = nil
        tourEngine = nil
        tourHybridPhase = .idle
        tourHybridProgress = 0
        tourHybridError = nil
        tourHybridResults = nil
    }

    /// Check and trigger splash screen if needed. Called after model download completes.
    func checkSplashScreen() {
        if SplashConfig.shouldShowSplash {
            showSplashScreen = true
        }
    }

    // MARK: - Tutorial

    /// Restart the tutorial from the beginning
    func restartTutorial() {
        // Clean up any tutorial-loaded data so we start fresh
        if tutorialState.tutorialDataLoaded {
            inputFile = nil
            selectedColumn = nil
            results = []
            tutorialState.tutorialDataLoaded = false
        }
        // Clear review state from any prior session
        reviewDecisions.removeAll()
        isReviewMode = false
        showCompletionOverlay = false
        showInspector = false
        showGuidedReviewBanner = false
        resultsFilter = .all

        // Exit the Research Showcase if active -- it overlays the entire UI
        if isInResearchShowcase {
            exitResearchShowcase()
        }

        // Navigate back to home FIRST, before starting the tutorial.
        // returnToWelcome() clears viewingResults, showMatchSetup, sidebarSelection, etc.
        // Must also check viewingResults -- when on the results page, sidebarSelection
        // is still .home and showMatchSetup is false, so the old check missed it.
        if sidebarSelection != .home || showMatchSetup || viewingResults {
            returnToWelcome()
        }

        tutorialState.reset()

        // If GTE-Large is already downloaded, skip the download step entirely.
        // Avoids a visual flash where Step 0 appears then auto-advances.
        if modelManager.state(for: "gte-large").isAvailable {
            tutorialState.currentStep = 1
            tutorialState.save()
        }

        showTutorial = true
        // Tutorial uses GTE-Large (research validation mode)
        selectedPipelineMode = .researchValidation
        selectedPipelineType = .gteLargeEmbedding
    }

    /// Reset a single review decision without double-press confirmation (for tutorial use).
    func resetReviewDecisionForTutorial(for resultId: UUID) {
        // Push to undo stack
        let previous = reviewDecisions[resultId]
        reviewUndoStack.append((resultId, previous))
        if reviewUndoStack.count > maxUndoStackSize {
            reviewUndoStack.removeFirst()
        }
        reviewDecisions.removeValue(forKey: resultId)
        // Re-triage to auto state
        if let result = resultsByID[resultId] {
            let profile = effectiveProfile()
            let oldCategory = cachedCategories[resultId] ?? .noMatch
            reviewDecisions[resultId] = AppState.triageDecision(for: result, profile: profile, pipelineType: selectedPipelineType, autoMatchScoreFloor: autoMatchScoreFloor, autoMatchMinGap: autoMatchMinGap)
            let newCategory = MatchCategory.from(
                result: result, decision: reviewDecisions[resultId], profile: profile
            )
            cachedCategories[resultId] = newCategory
            updateCategoryCount(oldCategory: oldCategory, newCategory: newCategory)
        }
        reviewDecisionVersion += 1
        saveReviewDecisions()
    }
}
