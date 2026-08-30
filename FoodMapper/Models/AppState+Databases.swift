import SwiftUI
import MLX
import os
import Darwin

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
        recoverInterruptedDatabasePersistence()
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
                    let stagedURL = try stageDatabaseSource(customDatabases[i])
                    try commitStagedDatabaseSource(stagedURL, for: customDatabases[i])
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
        let directory = customDatabasesURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let stage = directory.appendingPathComponent(".\(customDatabasesURL.lastPathComponent).\(UUID().uuidString).stage")
        let journal = directory.appendingPathComponent(".\(customDatabasesURL.lastPathComponent).journal")
        try stage.lastPathComponent.data(using: .utf8)?.write(to: journal, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: journal) }
        FileManager.default.createFile(atPath: stage.path, contents: nil)
        let handle = try FileHandle(forWritingTo: stage)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.path)
            if FileManager.default.fileExists(atPath: customDatabasesURL.path) {
                _ = try FileManager.default.replaceItemAt(customDatabasesURL, withItemAt: stage)
            } else {
                try FileManager.default.moveItem(at: stage, to: customDatabasesURL)
            }
            try syncDirectory(directory)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    private func recoverInterruptedDatabasePersistence() {
        let directory = customDatabasesURL.deletingLastPathComponent()
        let journal = directory.appendingPathComponent(".\(customDatabasesURL.lastPathComponent).journal")
        guard let name = try? String(contentsOf: journal, encoding: .utf8),
              !name.contains("/"), !name.contains("..") else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: journal)
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw MatchingError.databaseNotFound }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw MatchingError.databaseNotFound }
    }

    private func validateSourcePath(_ url: URL) throws {
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/" else { throw MatchingError.databaseNotFound }
        var path = ""
        for component in components.dropFirst() {
            path += "/\(component)"
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
                throw MatchingError.databaseNotFound
            }
        }
    }

    private func stageDatabaseSource(_ database: CustomDatabase) throws -> URL {
        guard database.hasSafeStorageIdentifier else { throw MatchingError.databaseNotFound }
        let sourceURL = URL(fileURLWithPath: database.csvPath)
        let destinationURL = database.storedCsvURL
        let fileManager = FileManager.default
        try validateSourcePath(sourceURL)
        let descriptor = open(sourceURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MatchingError.databaseNotFound }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else { throw MatchingError.databaseNotFound }
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destinationURL.deletingLastPathComponent().path)
        let stagedURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).stage")
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.readToEnd() else { throw MatchingError.databaseNotFound }
        FileManager.default.createFile(atPath: stagedURL.path, contents: nil)
        let stagedHandle = try FileHandle(forWritingTo: stagedURL)
        try stagedHandle.write(contentsOf: data)
        try stagedHandle.synchronize()
        try stagedHandle.close()
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        try syncDirectory(destinationURL.deletingLastPathComponent())
        return stagedURL
    }

    private func commitStagedDatabaseSource(_ stagedURL: URL, for database: CustomDatabase) throws {
        let destinationURL = database.storedCsvURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
        try syncDirectory(destinationURL.deletingLastPathComponent())
    }

    /// Register a custom database first. Pre-embedding is optional and only starts
    /// after the selected embedding model has been explicitly downloaded.
    func addCustomDatabase(_ database: CustomDatabase) {
        guard canModifyDatabases else {
            databaseEmbeddingStatus = .error("Wait for the current matching or database operation to finish.")
            return
        }
        do {
            guard database.hasSafeStorageIdentifier else { throw MatchingError.databaseNotFound }
            let stagedSourceURL = try stageDatabaseSource(database)
            defer { try? FileManager.default.removeItem(at: stagedSourceURL) }
            let validated = try CustomDatabaseValidator.load(
                url: stagedSourceURL, textColumn: database.textColumn, idColumn: database.idColumn
            )
            let sourceContent = try String(contentsOf: stagedSourceURL, encoding: .utf8)
            var finalDatabase = database
            finalDatabase.fileFormat = DataFileFormat.detect(from: CSVParser.stripBOM(sourceContent))
            finalDatabase.itemCount = validated.entries.count
            finalDatabase.sampleValues = Array(validated.entries.prefix(10).map(\.text))
            finalDatabase.columnNames = try CSVParser.parseRecords(
                content: CSVParser.stripBOM(sourceContent),
                delimiter: finalDatabase.fileFormat.delimiter
            ).first?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            try commitStagedDatabaseSource(stagedSourceURL, for: finalDatabase)
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
        guard database.hasSafeStorageIdentifier,
              let files = try? FileManager.default.contentsOfDirectory(at: database.cacheDirectory, includingPropertiesForKeys: nil) else { return }
        let prefix = ".\(database.id)_embeddings_"
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.lastPathComponent.hasSuffix(".stage") {
            try? FileManager.default.removeItem(at: file)
        }
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
        guard database.hasSafeStorageIdentifier else { throw MatchingError.databaseNotFound }
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
