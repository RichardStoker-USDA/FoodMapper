import SwiftUI
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

extension AppState {

    // MARK: - Stored Input Files

    func loadStoredInputFiles() {
        let url = StoredInputFile.indexURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            storedInputFiles = try JSONDecoder().decode([StoredInputFile].self, from: data)
            storedInputFiles.sort { $0.lastUsed > $1.lastUsed }
        } catch {
            logger.error("Failed to load stored input files: \(error)")
        }
    }

    func saveStoredInputFiles() {
        do {
            let data = try JSONEncoder().encode(storedInputFiles)
            try data.write(to: StoredInputFile.indexURL)
        } catch {
            logger.error("Failed to save stored input files: \(error)")
        }
    }

    /// Copy input file to app support and create metadata entry
    @discardableResult
    func storeInputFile(_ file: InputFile) -> StoredInputFile? {
        let stored = StoredInputFile(
            displayName: file.name,
            originalFileName: file.name,
            columnNames: file.columns,
            rowCount: file.rowCount,
            fileSize: (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int64) ?? 0,
            fileFormat: file.format
        )

        // Copy CSV to storage directory
        do {
            if FileManager.default.fileExists(atPath: stored.csvURL.path) {
                try FileManager.default.removeItem(at: stored.csvURL)
            }
            try FileManager.default.copyItem(at: file.url, to: stored.csvURL)
        } catch {
            logger.error("Failed to store input file: \(error)")
            return nil
        }

        storedInputFiles.insert(stored, at: 0)
        saveStoredInputFiles()
        return stored
    }

    /// Update last-used timestamp
    func touchStoredInputFile(_ id: UUID) {
        guard let index = storedInputFiles.firstIndex(where: { $0.id == id }) else { return }
        storedInputFiles[index].lastUsed = Date()
        storedInputFiles.sort { $0.lastUsed > $1.lastUsed }
        saveStoredInputFiles()
    }

    /// Remove a stored input file and its CSV copy
    func removeStoredInputFile(_ id: UUID) {
        guard let index = storedInputFiles.firstIndex(where: { $0.id == id }) else { return }
        let stored = storedInputFiles[index]
        try? FileManager.default.removeItem(at: stored.csvURL)
        storedInputFiles.remove(at: index)
        saveStoredInputFiles()
    }

    /// Update display name for a stored file
    func renameStoredInputFile(_ id: UUID, to newName: String) {
        guard let index = storedInputFiles.firstIndex(where: { $0.id == id }) else { return }
        storedInputFiles[index].displayName = newName
        saveStoredInputFiles()
    }

    // MARK: - Settings

    func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "appSettings"),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            threshold = settings.defaultThreshold
            advancedSettings = settings.advancedSettings
            // pageSize is now synced via @AppStorage in SettingsView
        }
    }

    func saveSettings() {
        let settings = AppSettings(
            defaultThreshold: threshold,
            appearance: UserDefaults.standard.string(forKey: "appearance") ?? "system",
            advancedSettings: advancedSettings
        )

        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "appSettings")
        }
    }

    /// Update advanced settings and save
    func updateAdvancedSettings(_ newSettings: AdvancedSettings) {
        advancedSettings = newSettings
        saveSettings()
    }

    /// Reset performance settings to hardware-detected defaults
    func resetPerformanceSettings() {
        advancedSettings.resetPerformanceOverrides()
        saveSettings()
    }

    /// Reset per-pipeline performance overrides for a specific pipeline
    func resetPipelinePerformance(for pipeline: PipelineType) {
        pipelinePerformanceOverrides.removeValue(forKey: pipeline.rawValue)
    }

    /// Reset all per-pipeline performance overrides
    func resetAllPipelinePerformance() {
        pipelinePerformanceOverrides.removeAll()
    }

    // MARK: - Batch State Persistence

    static let batchIdKey = "activeBatchId"
    static let batchStartTimeKey = "batchStartTime"

    /// Persist active batch ID and start time to disk for resume after force-quit
    func persistBatchState(batchId: String) {
        activeBatchId = batchId
        UserDefaults.standard.set(batchId, forKey: Self.batchIdKey)
        if let startTime = batchStartTime {
            UserDefaults.standard.set(startTime.timeIntervalSince1970, forKey: Self.batchStartTimeKey)
        }
    }

    /// Clear persisted batch state (on completion, cancellation, or error)
    func clearPersistedBatchState() {
        UserDefaults.standard.removeObject(forKey: Self.batchIdKey)
        UserDefaults.standard.removeObject(forKey: Self.batchStartTimeKey)
    }

    /// Load persisted batch state on launch (for resume after force-quit)
    func loadPersistedBatchState() -> (batchId: String, startTime: Date)? {
        guard let batchId = UserDefaults.standard.string(forKey: Self.batchIdKey) else {
            return nil
        }
        let startTimeInterval = UserDefaults.standard.double(forKey: Self.batchStartTimeKey)
        let startTime = startTimeInterval > 0 ? Date(timeIntervalSince1970: startTimeInterval) : Date()
        return (batchId, startTime)
    }

    // MARK: - Reset All Data

    /// Delete all app data (sessions, custom databases, model, preferences) and relaunch
    func resetAllData() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let foodMapperDir = appSupport.appendingPathComponent("FoodMapper", isDirectory: true)

        // Delete the entire FoodMapper application support directory
        // (Models, CustomDBs, Sessions, custom_databases.json)
        try? fm.removeItem(at: foodMapperDir)

        // Clear UserDefaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // Spawn a background shell script that waits for this process to exit,
        // then relaunches the app. No admin rights required.
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
        open "\(appPath)"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()

        // Terminate current instance
        NSApp.terminate(nil)
    }
}
