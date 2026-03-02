import SwiftUI
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

extension AppState {

    // MARK: - Export

    func exportResults(isDetailed: Bool = false, format: DataFileFormat = .csv) {
        guard !results.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        let prefix = isDetailed ? "foodmapper_results_detailed" : "foodmapper_results"
        panel.nameFieldStringValue = "\(prefix)_\(formattedDate()).\(format.fileExtension)"

        // Snapshot all data needed for CSV generation while on main thread.
        // This avoids accessing @MainActor properties from the background task.
        let snapshotResults = results
        let snapshotDecisions = reviewDecisions
        let pipelineName = currentPipelineName
        let snapshotInputFile = inputFile
        let snapshotColumn = selectedColumn
        let snapshotDatabase = selectedDatabase
        let snapshotSessionId = currentSessionId
        let snapshotSessions = sessions

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let _ = self else { return }

            // CSV generation + file write off main thread
            Task.detached {
                let csv: String
                if let inputFile = snapshotInputFile,
                   let _ = snapshotColumn,
                   let database = snapshotDatabase {
                    csv = CSVExporter.exportWithOriginalData(
                        results: snapshotResults,
                        inputFile: inputFile,
                        pipelineName: pipelineName,
                        targetTextColumn: database.textColumn,
                        targetIdColumn: database.idColumn,
                        targetColumnNames: database.columnNames ?? [],
                        reviewDecisions: snapshotDecisions,
                        detailed: isDetailed,
                        format: format
                    )
                } else {
                    // Fallback: use session metadata for column names when inputFile is unavailable
                    let session = snapshotSessionId.flatMap { id in
                        snapshotSessions.first(where: { $0.id == id })
                    }
                    csv = CSVExporter.export(
                        results: snapshotResults,
                        pipelineName: pipelineName,
                        selectedColumn: session?.selectedColumn,
                        targetTextColumn: session?.targetTextColumn,
                        targetIdColumn: session?.targetIdColumn,
                        targetColumnNames: session?.targetColumnNames,
                        reviewDecisions: snapshotDecisions,
                        detailed: isDetailed,
                        format: format
                    )
                }

                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                    await MainActor.run { [weak self] in
                        self?.presentExportToast(filename: url.lastPathComponent)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.error = AppError.exportFailed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    func presentExportToast(filename: String) {
        exportToastMessage = "Exported to \(filename)"
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showExportToast = true
        }
        exportToastDismissTask?.cancel()
        exportToastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                showExportToast = false
            }
        }
    }

    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// Export a single historical session via save panel (CSV or TSV)
    func exportSession(_ session: MatchingSession) {
        // Validate session data exists before showing save panel.
        // Failing early avoids the confusing UX of picking a save location
        // only to get an error because the session JSON is corrupt/missing.
        let resultsURL = sessionsDirectory.appendingPathComponent(session.resultsFilename)
        let sessionsDir = sessionsDirectory
        let storedFiles = storedInputFiles

        guard FileManager.default.fileExists(atPath: resultsURL.path) else {
            self.error = AppError.exportFailed("Session results file not found.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = DataFileFormat.allUTTypes
        let safeName = session.inputFileName.replacingOccurrences(of: "/", with: "_")
        let safeDB = session.databaseName.replacingOccurrences(of: "/", with: "_")
        panel.nameFieldStringValue = "\(safeName)_\(safeDB)_\(formattedDate(session.date)).csv"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let _ = self else { return }

            let format = DataFileFormat.from(url: url)

            // All file I/O, JSON decode, and CSV generation off main thread
            Task.detached {
                // Load session results
                guard let data = try? Data(contentsOf: resultsURL),
                      let sessionResults = try? JSONDecoder().decode([MatchResult].self, from: data) else {
                    await MainActor.run { [weak self] in
                        self?.error = AppError.exportFailed("Could not load session results.")
                    }
                    return
                }

                // Load review decisions (inlined to avoid @MainActor call)
                var sessionReviewDecisions: [UUID: ReviewDecision] = [:]
                if let reviewFilename = session.reviewDecisionsFilename {
                    let reviewURL = sessionsDir.appendingPathComponent(reviewFilename)
                    if let reviewData = try? Data(contentsOf: reviewURL),
                       let decoded = try? JSONDecoder().decode([UUID: ReviewDecision].self, from: reviewData) {
                        sessionReviewDecisions = decoded
                    }
                }

                // Generate export in the chosen format
                let output: String
                if let storedFileId = session.inputFileId,
                   let stored = storedFiles.first(where: { $0.id == storedFileId }),
                   FileManager.default.fileExists(atPath: stored.csvURL.path),
                   let inputFile = try? CSVParser.parse(content: String(contentsOf: stored.csvURL, encoding: .utf8), url: stored.csvURL),
                   let _ = session.selectedColumn,
                   let targetTextColumn = session.targetTextColumn {
                    output = CSVExporter.exportWithOriginalData(
                        results: sessionResults,
                        inputFile: inputFile,
                        pipelineName: session.pipelineName,
                        targetTextColumn: targetTextColumn,
                        targetIdColumn: session.targetIdColumn,
                        targetColumnNames: session.targetColumnNames ?? [],
                        reviewDecisions: sessionReviewDecisions,
                        format: format
                    )
                } else {
                    output = CSVExporter.export(
                        results: sessionResults,
                        pipelineName: session.pipelineName,
                        selectedColumn: session.selectedColumn,
                        targetTextColumn: session.targetTextColumn,
                        targetIdColumn: session.targetIdColumn,
                        targetColumnNames: session.targetColumnNames,
                        reviewDecisions: sessionReviewDecisions,
                        format: format
                    )
                }

                do {
                    try output.write(to: url, atomically: true, encoding: .utf8)
                    await MainActor.run { [weak self] in
                        self?.presentExportToast(filename: url.lastPathComponent)
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.error = AppError.exportFailed(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Export all sessions as a zip archive
    func exportAllSessions() {
        guard !sessions.isEmpty else { return }

        // Capture state before showing panel
        let allSessions = sessions
        let sessionsDir = sessionsDirectory
        let sessionCount = sessions.count

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "FoodMapper_Sessions_\(formattedDate()).zip"
        panel.message = "Export all \(sessionCount) sessions as a zip archive."

        panel.begin { [weak self] response in
            guard response == .OK, let zipURL = panel.url else { return }
            // All heavy work off main thread
            Task.detached {
                let exported = Self.exportAllSessionsToZipBackground(
                    destination: zipURL,
                    sessions: allSessions,
                    sessionsDirectory: sessionsDir
                )
                await MainActor.run { [weak self] in
                    if exported > 0 {
                        self?.presentExportToast(
                            filename: "\(exported) of \(sessionCount) sessions to \(zipURL.lastPathComponent)"
                        )
                    } else {
                        self?.error = AppError.exportFailed("No sessions could be exported. Session data may be corrupted.")
                    }
                }
            }
        }
    }

    /// Export all sessions as loose CSVs into a folder
    func exportAllSessionsToFolder() {
        guard !sessions.isEmpty else { return }

        // Capture state before showing panel
        let allSessions = sessions
        let sessionsDir = sessionsDirectory
        let sessionCount = sessions.count

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to export \(sessionCount) session files."

        panel.begin { [weak self] response in
            guard response == .OK, let folderURL = panel.url else { return }
            // All file I/O, JSON decode, and CSV generation off main thread
            Task.detached {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd"
                var exported = 0
                for session in allSessions {
                    let resultsURL = sessionsDir.appendingPathComponent(session.resultsFilename)
                    guard let data = try? Data(contentsOf: resultsURL),
                          let sessionResults = try? JSONDecoder().decode([MatchResult].self, from: data) else { continue }

                    // Load review decisions (inlined to avoid @MainActor call)
                    var sessionReviewDecisions: [UUID: ReviewDecision] = [:]
                    if let reviewFilename = session.reviewDecisionsFilename {
                        let reviewURL = sessionsDir.appendingPathComponent(reviewFilename)
                        if let reviewData = try? Data(contentsOf: reviewURL),
                           let decoded = try? JSONDecoder().decode([UUID: ReviewDecision].self, from: reviewData) {
                            sessionReviewDecisions = decoded
                        }
                    }

                    let csv = CSVExporter.export(
                        results: sessionResults,
                        pipelineName: session.pipelineName,
                        selectedColumn: session.selectedColumn,
                        targetTextColumn: session.targetTextColumn,
                        targetIdColumn: session.targetIdColumn,
                        targetColumnNames: session.targetColumnNames,
                        reviewDecisions: sessionReviewDecisions
                    )
                    let safeName = session.inputFileName.replacingOccurrences(of: "/", with: "_")
                    let safeDB = session.databaseName.replacingOccurrences(of: "/", with: "_")
                    let dateStr = formatter.string(from: session.date)
                    let filename = "\(safeName)_\(safeDB)_\(dateStr).csv"
                    let fileURL = folderURL.appendingPathComponent(filename)
                    try? csv.write(to: fileURL, atomically: true, encoding: .utf8)
                    exported += 1
                }
                logger.info("Exported \(exported) of \(sessionCount) sessions to folder.")
                await MainActor.run { [weak self] in
                    if exported > 0 {
                        self?.presentExportToast(
                            filename: "\(exported) of \(sessionCount) sessions to \(folderURL.lastPathComponent)"
                        )
                    } else {
                        self?.error = AppError.exportFailed("No sessions could be exported. Session data may be corrupted.")
                    }
                }
            }
        }
    }

    /// Performs all zip export work on the calling thread (must NOT be main thread).
    /// nonisolated so it can run from Task.detached without hopping to MainActor.
    /// Returns the number of sessions successfully exported.
    private nonisolated static func exportAllSessionsToZipBackground(
        destination: URL,
        sessions: [MatchingSession],
        sessionsDirectory: URL
    ) -> Int {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"

        var exported = 0
        for session in sessions {
            let resultsURL = sessionsDirectory.appendingPathComponent(session.resultsFilename)
            guard let data = try? Data(contentsOf: resultsURL),
                  let sessionResults = try? JSONDecoder().decode([MatchResult].self, from: data) else { continue }

            // Load review decisions (inlined to avoid @MainActor call)
            var sessionReviewDecisions: [UUID: ReviewDecision] = [:]
            if let reviewFilename = session.reviewDecisionsFilename {
                let reviewURL = sessionsDirectory.appendingPathComponent(reviewFilename)
                if let reviewData = try? Data(contentsOf: reviewURL),
                   let decoded = try? JSONDecoder().decode([UUID: ReviewDecision].self, from: reviewData) {
                    sessionReviewDecisions = decoded
                }
            }

            let csv = CSVExporter.export(
                results: sessionResults,
                pipelineName: session.pipelineName,
                selectedColumn: session.selectedColumn,
                targetTextColumn: session.targetTextColumn,
                targetIdColumn: session.targetIdColumn,
                targetColumnNames: session.targetColumnNames,
                reviewDecisions: sessionReviewDecisions
            )
            let safeName = session.inputFileName.replacingOccurrences(of: "/", with: "_")
            let safeDB = session.databaseName.replacingOccurrences(of: "/", with: "_")
            let dateStr = formatter.string(from: session.date)
            let filename = "\(safeName)_\(safeDB)_\(dateStr).csv"
            try? csv.write(to: tempDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            exported += 1
        }

        // Create zip
        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.currentDirectoryURL = tempDir
        zipProcess.arguments = ["-j", destination.path] + ((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])
        try? zipProcess.run()
        zipProcess.waitUntilExit()

        try? FileManager.default.removeItem(at: tempDir)
        logger.info("Exported \(exported) of \(sessions.count) sessions to zip.")
        return exported
    }
}
