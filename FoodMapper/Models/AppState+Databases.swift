import SwiftUI
import MLX
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "state")

extension AppState {

    // MARK: - Target Database Sample

    /// Load first ~10 text values from the selected target database for preview display.
    /// Priority: cached sampleValues > file I/O fallback.
    func loadTargetDatabaseSample() {
        guard let selectedDatabase else {
            targetDatabaseSample = []
            return
        }

        // Built-in databases: use hardcoded sample values (no file I/O)
        if let builtIn = selectedDatabase.asBuiltIn {
            targetDatabaseSample = builtIn.sampleValues
            return
        }

        // Custom databases: check cached metadata first
        if let customDB = selectedDatabase.asCustom, let cached = customDB.sampleValues {
            targetDatabaseSample = cached
            return
        }

        // Fallback: read from CSV file (legacy databases without cached metadata)
        guard let url = selectedDatabase.csvURL else {
            targetDatabaseSample = []
            return
        }

        let textCol = selectedDatabase.textColumn

        // Get the first ~15 lines of CSV
        let lines: [String]
        if selectedDatabase.isBuiltIn {
            guard let rawLines = readFirstLinesFullLoad(from: url, maxLines: 15) else {
                targetDatabaseSample = []
                return
            }
            lines = rawLines
        } else {
            guard let rawLines = readFirstLinesStreaming(from: url, maxLines: 15) else {
                targetDatabaseSample = []
                return
            }
            lines = rawLines
        }

        guard lines.count > 1 else {
            targetDatabaseSample = []
            return
        }

        // Detect delimiter from header (custom DBs may be TSV)
        let strippedHeader = CSVParser.stripBOM(lines[0])
        let format = DataFileFormat.detect(from: strippedHeader)
        let delimiter = format.delimiter

        let header = CSVParser.parseCSVLine(strippedHeader, delimiter: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let colIdx = header.firstIndex(of: textCol.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            targetDatabaseSample = []
            return
        }

        var sample: [String] = []
        for i in 1..<lines.count {
            let values = CSVParser.parseCSVLine(lines[i], delimiter: delimiter)
            if colIdx < values.count && !values[colIdx].isEmpty {
                sample.append(values[colIdx])
            }
            if sample.count >= 10 { break }
        }
        targetDatabaseSample = sample
    }

    /// Read first N non-empty lines by loading the file fully (reliable for bundle resources).
    /// Only use for small/known files (built-in databases).
    func readFirstLinesFullLoad(from url: URL, maxLines: Int) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        var lines: [String] = []
        content.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lines.append(trimmed)
                if lines.count >= maxLines {
                    stop = true
                }
            }
        }
        return lines
    }

    /// Read first N non-empty lines by streaming only the first 8KB.
    /// Fast for any size file (critical for large custom CSVs).
    func readFirstLinesStreaming(from url: URL, maxLines: Int) -> [String]? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }

        guard let data = try? fileHandle.read(upToCount: 8192),
              let chunk = String(data: data, encoding: .utf8) else {
            return nil
        }

        var lines: [String] = []
        var current = ""
        var inQuotes = false

        for char in chunk {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char.isNewline && !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                    if lines.count >= maxLines { break }
                }
                current = ""
            } else {
                current.append(char)
            }
        }

        if lines.count < maxLines {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }

        return lines
    }

    // MARK: - Custom Database Management

    var customDatabasesURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FoodMapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_databases.json")
    }

    func loadCustomDatabases() {
        guard FileManager.default.fileExists(atPath: customDatabasesURL.path) else { return }
        do {
            let data = try Data(contentsOf: customDatabasesURL)
            customDatabases = try JSONDecoder().decode([CustomDatabase].self, from: data)
        } catch {
            logger.error("Failed to load custom databases: \(error)")
        }

        // Migrate legacy databases into app support before any runtime access.
        var needsSave = false
        for i in customDatabases.indices {
            let storedURL = customDatabases[i].storedCsvURL
            if !FileManager.default.fileExists(atPath: storedURL.path) {
                guard FileManager.default.fileExists(atPath: customDatabases[i].csvPath) else {
                    logger.warning("Migration: CSV not found for \(self.customDatabases[i].displayName) -- database may be stale")
                    continue
                }
                do {
                    try copyDatabaseSourceAtomically(customDatabases[i])
                } catch {
                    logger.warning("Migration: failed to copy CSV for \(self.customDatabases[i].displayName): \(error)")
                    continue
                }
            }
            if customDatabases[i].sampleValues == nil {
                // Legacy records are copied once into app support. Runtime access never
                // reads the original import location.
                let metadata = generateDatabaseMetadata(from: storedURL.path, textColumn: customDatabases[i].textColumn)
                customDatabases[i].sampleValues = metadata.sampleValues
                customDatabases[i].columnNames = metadata.columnNames
            }
            needsSave = true
        }

        // Fix corrupted metadata from \r\n line ending bug
        for i in customDatabases.indices {
            guard let columnNames = customDatabases[i].columnNames else { continue }
            let isCorrupted = columnNames.contains { $0.contains("\r") || $0.contains("\n") }
            guard isCorrupted else { continue }

            let csvPath: String
            if FileManager.default.fileExists(atPath: customDatabases[i].storedCsvURL.path) {
                csvPath = customDatabases[i].storedCsvURL.path
            } else {
                continue
            }

            let metadata = generateDatabaseMetadata(from: csvPath, textColumn: customDatabases[i].textColumn)
            customDatabases[i].sampleValues = metadata.sampleValues
            customDatabases[i].columnNames = metadata.columnNames
            needsSave = true
            logger.info("Migration: regenerated metadata for \(self.customDatabases[i].displayName) (fixed \\r\\n corruption)")
        }

        if needsSave {
            saveCustomDatabases()
        }
    }

    func saveCustomDatabases() {
        do {
            try persistCustomDatabases(customDatabases)
        } catch {
            logger.error("Failed to save custom databases: \(error)")
        }
    }

    private func persistCustomDatabases(_ databases: [CustomDatabase]) throws {
        let data = try JSONEncoder().encode(databases)
        try data.write(to: customDatabasesURL, options: [.atomic])
    }

    private func copyDatabaseSourceAtomically(_ database: CustomDatabase) throws {
        let sourceURL = URL(fileURLWithPath: database.csvPath)
        let destinationURL = database.storedCsvURL
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw MatchingError.databaseNotFound }
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stagedURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).stage")
        defer { try? fileManager.removeItem(at: stagedURL) }
        try fileManager.copyItem(at: sourceURL, to: stagedURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    /// Register a custom database first. Pre-embedding is optional and only starts
    /// after the selected embedding model has been explicitly downloaded.
    func addCustomDatabase(_ database: CustomDatabase) {
        guard canModifyDatabases else {
            databaseEmbeddingStatus = .error("Wait for the current matching or database operation to finish.")
            return
        }
        do {
            let sourceURL = URL(fileURLWithPath: database.csvPath)
            let validated = try CustomDatabaseValidator.load(
                url: sourceURL, textColumn: database.textColumn, idColumn: database.idColumn
            )
            let sourceContent = try String(contentsOf: sourceURL, encoding: .utf8)
            var finalDatabase = database
            finalDatabase.fileFormat = DataFileFormat.detect(from: CSVParser.stripBOM(sourceContent))
            finalDatabase.itemCount = validated.entries.count
            finalDatabase.sampleValues = Array(validated.entries.prefix(10).map(\.text))
            finalDatabase.columnNames = try CSVParser.parseRecords(
                content: CSVParser.stripBOM(sourceContent),
                delimiter: finalDatabase.fileFormat.delimiter
            ).first?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            try copyDatabaseSourceAtomically(finalDatabase)
            do {
                let updatedDatabases = customDatabases + [finalDatabase]
                try persistCustomDatabases(updatedDatabases)
                customDatabases = updatedDatabases
            } catch {
                try? FileManager.default.removeItem(at: finalDatabase.storedCsvURL)
                throw error
            }
            selectedDatabase = .custom(finalDatabase)
            databaseEmbeddingStatus = .registered(
                databaseName: finalDatabase.displayName,
                itemCount: finalDatabase.itemCount
            )
            if let embeddingKey = selectedPipelineType.embeddingModelKey,
               modelManager.state(for: embeddingKey).isAvailable {
                reembedCustomDatabase(finalDatabase)
            }
        } catch {
            databaseEmbeddingStatus = .error(error.localizedDescription)
        }
    }

    /// Request pre-embedding for an already registered database.
    func embedDatabaseAsync(_ database: CustomDatabase) {
        reembedCustomDatabase(database)
    }

    private func startEmbedding(_ database: CustomDatabase, embeddingKey: String, registersOnSuccess: Bool = false) {
        let operationID = UUID()
        guard beginEngineOperation(.databaseEmbedding(operationID, database.id)) else {
            databaseEmbeddingStatus = .error("Wait for the current matching or database operation to finish.")
            return
        }
        databaseEmbeddingStatus = .preparing(databaseName: database.displayName)
        embeddingTask = Task { [self] in
            do {
                let engine = try await getOrCreateEngine()
                let startTime = Date()
                let model = try await self.modelManager.loadEmbeddingModel(key: embeddingKey)
                guard self.isCurrentEngineOperation(operationID) else { return }
                self.databaseEmbeddingStatus = .embedding(
                    completed: 0,
                    total: database.itemCount,
                    databaseName: database.displayName,
                    startTime: startTime
                )
                await engine.invalidateLoadedDatabase()
                await engine.setEmbeddingModel(model)

                try await engine.embedCustomDatabase(
                    database,
                    batchSize: self.effectiveEmbeddingBatchSize,
                    chunkSize: self.effectiveChunkSize
                ) { [weak self] completed, total in
                    Task { @MainActor in
                        guard self?.isCurrentEngineOperation(operationID) == true else { return }
                        self?.databaseEmbeddingStatus = .embedding(
                            completed: completed,
                            total: total,
                            databaseName: database.displayName,
                            startTime: startTime
                        )
                    }
                }

                let duration = Date().timeIntervalSince(startTime)

                // Calculate cache file size
                let cacheSize = self.getCacheFileSize(for: database)

                await MainActor.run {
                    guard self.isCurrentEngineOperation(operationID) else { return }
                    var finalDatabase = database
                    finalDatabase.embeddingDuration = duration
                    finalDatabase.cacheSize = cacheSize
                    if let index = self.customDatabases.firstIndex(where: { $0.id == database.id }) {
                        self.customDatabases[index] = finalDatabase
                        self.saveCustomDatabases()
                    } else if registersOnSuccess {
                        self.customDatabases.append(finalDatabase)
                        self.saveCustomDatabases()
                    }

                    self.databaseEmbeddingStatus = .completed(
                        databaseName: database.displayName,
                        itemCount: database.itemCount,
                        duration: duration
                    )
                    self.embeddingCacheVersion += 1
                    // Auto-select the newly added database
                    self.selectedDatabase = .custom(finalDatabase)
                    self.embeddingTask = nil
                    self.finishEngineOperation(operationID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.isCurrentEngineOperation(operationID) else { return }
                    self.databaseEmbeddingStatus = .idle
                    self.embeddingTask = nil
                    self.finishEngineOperation(operationID)
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrentEngineOperation(operationID) else { return }
                    self.databaseEmbeddingStatus = .error(error.localizedDescription)
                    self.embeddingTask = nil
                    self.finishEngineOperation(operationID)
                }
            }
        }
    }

    /// Clean up partial embedding files after cancel or error
    func cleanupPartialEmbeddings(for database: CustomDatabase) {
        for file in database.allCacheFiles {
            try? FileManager.default.removeItem(at: file)
        }
        // Also clean legacy unversioned path
        try? FileManager.default.removeItem(at: database.legacyCacheURL)
    }

    /// Generate preview metadata (sampleValues + columnNames) from a CSV file path.
    /// Used during embedding and for migrating legacy databases.
    nonisolated func generateDatabaseMetadata(from csvPath: String, textColumn: String) -> (sampleValues: [String]?, columnNames: [String]?) {
        let url = URL(fileURLWithPath: csvPath)
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return (nil, nil)
        }
        defer { try? fileHandle.close() }

        guard let data = try? fileHandle.read(upToCount: 8192),
              let chunk = String(data: data, encoding: .utf8) else {
            return (nil, nil)
        }

        // Parse lines (handle quoted fields spanning newlines)
        var lines: [String] = []
        var current = ""
        var inQuotes = false
        for char in chunk {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char.isNewline && !inQuotes {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                    if lines.count >= 15 { break }
                }
                current = ""
            } else {
                current.append(char)
            }
        }
        if lines.count < 15 {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }

        guard !lines.isEmpty else { return (nil, nil) }

        // Detect delimiter from header (custom DBs may be TSV)
        let strippedHeader = CSVParser.stripBOM(lines[0])
        let format = DataFileFormat.detect(from: strippedHeader)
        let delimiter = format.delimiter

        let header = CSVParser.parseCSVLine(strippedHeader, delimiter: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let columnNames = header

        // Find text column index for sample values
        guard let colIdx = header.firstIndex(of: textColumn.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (nil, columnNames)
        }

        var sampleValues: [String] = []
        for i in 1..<lines.count {
            let values = CSVParser.parseCSVLine(lines[i], delimiter: delimiter)
            if colIdx < values.count && !values[colIdx].isEmpty {
                sampleValues.append(values[colIdx])
            }
            if sampleValues.count >= 10 { break }
        }

        return (sampleValues.isEmpty ? nil : sampleValues, columnNames)
    }

    /// Cancel ongoing embedding
    func cancelEmbedding() {
        Task {
            await matchingEngine?.cancel()
        }
        embeddingTask?.cancel()
    }

    /// Re-embed an existing custom database with the current pipeline's embedding model.
    /// Does not remove existing embeddings from other models -- adds alongside them.
    func reembedCustomDatabase(_ database: CustomDatabase) {
        guard let embeddingKey = selectedPipelineType.embeddingModelKey else {
            databaseEmbeddingStatus = .error("The selected pipeline does not use an embedding model.")
            return
        }
        guard modelManager.state(for: embeddingKey).isAvailable else {
            pendingDownloadModels = modelManager.registeredModel(for: embeddingKey).map { [$0] } ?? []
            showModelDownloadSheet = true
            return
        }
        startEmbedding(database, embeddingKey: embeddingKey)
    }

    /// Get total cache file size for a database (all model versions)
    func getCacheFileSize(for database: CustomDatabase) -> Int64? {
        let total = database.totalCacheSize
        return total > 0 ? total : nil
    }

    private func removeDatabaseStorageTransactionally(_ database: CustomDatabase) throws {
        let fileManager = FileManager.default
        let directory = database.cacheDirectory
        let stagingDirectory = directory.appendingPathComponent(".delete-\(database.id)-\(UUID().uuidString)")
        let files = database.allCacheFiles + database.allCacheMetadataFiles + [database.legacyCacheURL, database.storedCsvURL]
        let existingFiles = Array(Set(files)).filter { fileManager.fileExists(atPath: $0.path) }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var moved: [(from: URL, to: URL)] = []
        do {
            for source in existingFiles {
                let staged = stagingDirectory.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: staged)
                moved.append((source, staged))
            }
        } catch {
            for item in moved.reversed() where fileManager.fileExists(atPath: item.to.path) {
                try fileManager.moveItem(at: item.to, to: item.from)
            }
            try fileManager.removeItem(at: stagingDirectory)
            throw error
        }
        do {
            let updatedDatabases = customDatabases.filter { $0.id != database.id }
            try persistCustomDatabases(updatedDatabases)
            customDatabases = updatedDatabases
            do {
                try fileManager.removeItem(at: stagingDirectory)
            } catch {
                logger.error("Database removal completed but cleanup is pending at \(stagingDirectory.path): \(error)")
            }
        } catch {
            for item in moved.reversed() where fileManager.fileExists(atPath: item.to.path) {
                try fileManager.moveItem(at: item.to, to: item.from)
            }
            try fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    func deleteCustomDatabase(_ database: CustomDatabase) {
        if case let .databaseEmbedding(_, activeID)? = activeEngineOperation, activeID == database.id {
            let task = embeddingTask
            cancelEmbedding()
            Task { @MainActor [weak self] in
                await task?.value
                self?.deleteCustomDatabase(database)
            }
            return
        }
        guard canModifyDatabases else {
            databaseEmbeddingStatus = .error("Wait for matching to finish before removing a database.")
            return
        }
        let operationID = UUID()
        guard beginEngineOperation(.databaseRemoval(operationID, database.id)) else { return }
        do {
            try removeDatabaseStorageTransactionally(database)
            if case .custom(let selected) = selectedDatabase, selected.id == database.id { selectedDatabase = nil }
        } catch {
            databaseEmbeddingStatus = .error(error.localizedDescription)
        }
        finishEngineOperation(operationID)
    }
}
