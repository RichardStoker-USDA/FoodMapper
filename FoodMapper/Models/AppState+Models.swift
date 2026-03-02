import SwiftUI
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

extension AppState {

    // MARK: - Model Management

    func checkModelStatus() async {
        // Sync from ModelManager's detection
        syncModelStatus()
    }

    func downloadModel() async {
        // Check if model already exists
        if MLXEmbeddingModel.isModelAvailable {
            isVerifyingModelAfterDownload = true
            modelStatus = .loading
            do {
                let engine = try await MatchingEngine()
                try await engine.loadModelIfNeeded()
                modelStatus = .ready(executionProvider: await engine.getExecutionProvider())
            } catch {
                modelStatus = .error(error.localizedDescription)
            }
            isVerifyingModelAfterDownload = false
            return
        }

        // Download via ModelManager (unified download path)
        modelStatus = .downloading(progress: 0)

        do {
            try await modelManager.downloadModel(key: "gte-large")
            isVerifyingModelAfterDownload = true
            modelStatus = .loading

            // Verify model loads correctly
            let engine = try await MatchingEngine()
            try await engine.loadModelIfNeeded()
            modelStatus = .ready(executionProvider: await engine.getExecutionProvider())
        } catch {
            modelStatus = .error(error.localizedDescription)
        }
        isVerifyingModelAfterDownload = false
    }

    /// Sync modelStatus from ModelManager's state for GTE-Large.
    /// Called automatically via Combine subscription on modelManager.$modelStates,
    /// and explicitly during checkModelStatus().
    func syncModelStatus() {
        let gteState = modelManager.state(for: "gte-large")
        switch gteState {
        case .downloaded, .loaded:
            // Skip sync only during post-download verification, where AppState
            // manages the .loading -> .ready transition itself.
            if isVerifyingModelAfterDownload { return }
            modelStatus = .ready(executionProvider: "MLX (GPU)")
        case .downloading(let p):
            modelStatus = .downloading(progress: p)
        case .loading:
            // Don't sync -- this fires briefly when model weights are loaded
            // into memory before matching. AppState manages .loading explicitly
            // during download verification via isVerifyingModelAfterDownload.
            break
        case .error(let msg):
            modelStatus = .error(msg)
        case .notDownloaded:
            modelStatus = .notDownloaded
        }
    }
}
