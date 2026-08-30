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
        do {
            try await modelManager.awaitStartupRecoveryForUserAction()
        } catch {
            modelStatus = .error(error.localizedDescription)
            return
        }
        guard modelManager.retryState(for: "gte-large") != .cancelling else {
            modelStatus = .cancelling
            return
        }
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

        // Initialize progress variables
        downloadStartTime = Date()
        downloadBytesWritten = 0
        downloadBytesTotal = GTELargeModelManifest.current.downloadSize
        downloadSpeedBytesPerSecond = 0
        downloadTimeRemaining = nil

        // Download via ModelManager (unified download path)
        modelStatus = .downloading(progress: 0)

        do {
            try await modelManager.downloadModel(key: "gte-large")

            // Check if cancelled before embarking on verification
            if modelStatus == .notDownloaded {
                return
            }

            isVerifyingModelAfterDownload = true
            modelStatus = .loading

            // Verify model loads correctly
            let engine = try await MatchingEngine()
            try await engine.loadModelIfNeeded()
            modelStatus = .ready(executionProvider: await engine.getExecutionProvider())
        } catch {
            let isCancelled = error is CancellationError ||
                             (error as? URLError)?.code == .cancelled ||
                             error.localizedDescription.contains("cancelled") ||
                             error.localizedDescription.contains("Cancelled")

            if isCancelled || modelStatus == .notDownloaded {
                modelStatus = modelManager.retryState(for: "gte-large") == .cancelling
                    ? .cancelling
                    : .notDownloaded
            } else {
                modelStatus = .error(error.localizedDescription)
            }
        }
        isVerifyingModelAfterDownload = false
    }

    func cancelDownload() {
        modelStatus = .cancelling
        Task { [weak self] in
            guard let self else { return }
            await modelManager.cancelDownloadAndWait(key: "gte-large")
            syncModelStatus()
        }
    }

    /// Sync modelStatus from ModelManager's state for GTE-Large.
    /// Called automatically via Combine subscription on modelManager.$modelStates,
    /// and explicitly during checkModelStatus().
    func syncModelStatus() {
        if modelStatus == .cancelling,
           modelManager.retryState(for: "gte-large") == .cancelling {
            return
        }
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
