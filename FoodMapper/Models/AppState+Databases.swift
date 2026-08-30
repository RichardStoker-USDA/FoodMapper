import SwiftUI
import MLX
import os
import Darwin

private struct DatabaseDeletionJournal: Codable {
    static let currentVersion = 2

    let version: Int
    let databaseID: String
    let files: [String]

    init(databaseID: String, files: [String]) {
        self.version = Self.currentVersion
        self.databaseID = databaseID
        self.files = files
    }
}

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
        let appSupport = FoodMapperStorage.applicationSupportURL
        let dir = appSupport.appendingPathComponent("FoodMapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: SecureFileAccess.storageDirectoryPermissions], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("custom_databases.json")
    }

    func loadCustomDatabases() {
        recoverInterruptedDatabasePersistence()
        guard FileManager.default.fileExists(atPath: customDatabasesURL.path) else {
            recoverInterruptedDatabaseDeletions(registeredIDs: nil)
            return
        }
        do {
            let root = customDatabasesURL.deletingLastPathComponent()
            let descriptor = try SecureFileAccess.openRegularFile(
                customDatabasesURL, under: root, maximumSize: 8 * 1_024 * 1_024
            )
            defer { close(descriptor) }
            let data = try SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: 8 * 1_024 * 1_024)
            customDatabases = try JSONDecoder().decode([CustomDatabase].self, from: data)
        } catch {
            logger.error("Failed to load custom databases: \(error)")
            recoverInterruptedDatabaseDeletions(registeredIDs: nil)
            return
        }
        recoverInterruptedDatabaseDeletions(registeredIDs: Set(customDatabases.map(\.id)))

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
        try FileManager.default.setAttributes([.posixPermissions: SecureFileAccess.privateFilePermissions], ofItemAtPath: journal.path)
        try SecureFileAccess.synchronize(journal)
        try SecureFileAccess.synchronize(directory, directory: true)
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
            try FileManager.default.removeItem(at: journal)
            try SecureFileAccess.synchronize(directory, directory: true)
        } catch {
            try? handle.close()
            // Preserve the journal and staged record after a rename or sync error.
            // Startup recovery can then decide without discarding the last registry.
            throw error
        }
    }

    private func recoverInterruptedDatabasePersistence() {
        let directory = customDatabasesURL.deletingLastPathComponent()
        let journal = directory.appendingPathComponent(".\(customDatabasesURL.lastPathComponent).journal")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        guard let descriptor = try? SecureFileAccess.openRegularFile(journal, under: directory, maximumSize: 1_024),
              let data = try? SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: 1_024),
              let name = String(data: data, encoding: .utf8),
              name.hasPrefix(".\(customDatabasesURL.lastPathComponent)."),
              name.hasSuffix(".stage"),
              !name.contains("/"), !name.contains("..") else {
            quarantineRegistryJournal(journal, in: directory)
            return
        }
        close(descriptor)
        do {
            let stage = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: stage.path) { try FileManager.default.removeItem(at: stage) }
            try FileManager.default.removeItem(at: journal)
            try SecureFileAccess.synchronize(directory, directory: true)
        } catch {
            quarantineRegistryJournal(journal, in: directory)
        }
    }

    private func quarantineRegistryJournal(_ journal: URL, in directory: URL) {
        let quarantine = directory.appendingPathComponent(".registry-quarantine-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: journal, to: quarantine)
            try SecureFileAccess.synchronize(directory, directory: true)
        } catch {
            logger.error("Could not quarantine interrupted registry write: \(error.localizedDescription)")
        }
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw MatchingError.databaseNotFound }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw MatchingError.databaseNotFound }
    }

    private func stageDatabaseSource(_ database: CustomDatabase) throws -> URL {
        guard database.hasSafeStorageIdentifier else { throw MatchingError.databaseNotFound }
        let sourceURL = URL(fileURLWithPath: database.csvPath)
        let destinationURL = database.storedCsvURL
        let fileManager = FileManager.default
        let descriptor = try SecureFileAccess.openRegularFile(
            sourceURL, maximumSize: Int64(CustomDatabaseValidator.maximumImportBytes)
        )
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else { throw MatchingError.databaseNotFound }
        guard info.st_size <= off_t(CustomDatabaseValidator.maximumImportBytes) else {
            throw CustomDatabaseValidationError.importTooLarge(
                actual: Int64(info.st_size), limit: CustomDatabaseValidator.maximumImportBytes
            )
        }
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: SecureFileAccess.storageDirectoryPermissions], ofItemAtPath: directory.path)
        try SecureFileAccess.validateStorageDirectory(directory)
        let stagedURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).stage")
        let stagedDescriptor = open(stagedURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, SecureFileAccess.privateFilePermissions)
        guard stagedDescriptor >= 0 else { throw MatchingError.databaseNotFound }
        let stagedHandle = FileHandle(fileDescriptor: stagedDescriptor, closeOnDealloc: true)
        let sourceHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var copied = 0
        do {
            while let chunk = try sourceHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
                if Task.isCancelled { throw CustomDatabaseValidationError.cancelled }
                guard copied <= CustomDatabaseValidator.maximumImportBytes - chunk.count else {
                    throw CustomDatabaseValidationError.importTooLarge(
                        actual: Int64(copied) + Int64(chunk.count), limit: CustomDatabaseValidator.maximumImportBytes
                    )
                }
                try stagedHandle.write(contentsOf: chunk)
                copied += chunk.count
            }
            guard copied == Int(info.st_size) else { throw MatchingError.databaseNotFound }
            try stagedHandle.synchronize()
            try stagedHandle.close()
        } catch {
            try? stagedHandle.close()
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: SecureFileAccess.privateFilePermissions], ofItemAtPath: stagedURL.path)
        try SecureFileAccess.synchronize(directory, directory: true)
        return stagedURL
    }

    private func commitStagedDatabaseSource(_ stagedURL: URL, for database: CustomDatabase) throws {
        let destinationURL = database.storedCsvURL
        let fileManager = FileManager.default
        try SecureFileAccess.validateStorageDirectory(destinationURL.deletingLastPathComponent())
        let stagedDescriptor = try SecureFileAccess.openRegularFile(stagedURL, under: destinationURL.deletingLastPathComponent(), maximumSize: Int64(CustomDatabaseValidator.maximumImportBytes))
        defer { close(stagedDescriptor) }
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
        try SecureFileAccess.synchronize(destinationURL.deletingLastPathComponent(), directory: true)
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
            var finalDatabase = database
            finalDatabase.fileFormat = validated.fileFormat
            finalDatabase.itemCount = validated.entries.count
            finalDatabase.sampleValues = Array(validated.entries.prefix(10).map(\.text))
            finalDatabase.columnNames = validated.columnNames
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
                guard self.isCurrentEngineOperation(operationID) else { throw CancellationError() }
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
        let task = embeddingTask
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.matchingEngine?.cancel()
            task?.cancel()
            await task?.value
            guard case let .databaseEmbedding(operationID, _) = self.activeEngineOperation else { return }
            self.databaseEmbeddingStatus = .idle
            self.embeddingTask = nil
            self.finishEngineOperation(operationID)
        }
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
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory.path)
        let journal = DatabaseDeletionJournal(databaseID: database.id, files: existingFiles.map(\.lastPathComponent))
        let journalURL = stagingDirectory.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: SecureFileAccess.privateFilePermissions], ofItemAtPath: journalURL.path)
        try SecureFileAccess.synchronize(journalURL)
        try SecureFileAccess.synchronize(stagingDirectory, directory: true)
        var moved: [(from: URL, to: URL)] = []
        do {
            for source in existingFiles {
                let staged = stagingDirectory.appendingPathComponent(source.lastPathComponent)
                try fileManager.moveItem(at: source, to: staged)
                moved.append((source, staged))
                try SecureFileAccess.synchronize(directory, directory: true)
                try SecureFileAccess.synchronize(stagingDirectory, directory: true)
            }
        } catch {
            for item in moved.reversed() where fileManager.fileExists(atPath: item.to.path) {
                try fileManager.moveItem(at: item.to, to: item.from)
            }
            try fileManager.removeItem(at: stagingDirectory)
            try SecureFileAccess.synchronize(directory, directory: true)
            throw error
        }
        do {
            let updatedDatabases = customDatabases.filter { $0.id != database.id }
            try persistCustomDatabases(updatedDatabases)
            customDatabases = updatedDatabases
            do {
                try fileManager.removeItem(at: stagingDirectory)
                try SecureFileAccess.synchronize(directory, directory: true)
            } catch {
                logger.error("Database removal completed but cleanup is pending at \(stagingDirectory.path): \(error)")
            }
        } catch {
            for item in moved.reversed() where fileManager.fileExists(atPath: item.to.path) {
                try fileManager.moveItem(at: item.to, to: item.from)
            }
            try fileManager.removeItem(at: stagingDirectory)
            try SecureFileAccess.synchronize(directory, directory: true)
            throw error
        }
    }

    private func recoverInterruptedDatabaseDeletions(registeredIDs: Set<String>?) {
        let directory = FoodMapperStorage.applicationSupportURL
            .appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for stage in contents where stage.lastPathComponent.hasPrefix(".delete-") {
            let journalURL = stage.appendingPathComponent("journal.json")
            guard let descriptor = try? SecureFileAccess.openRegularFile(journalURL, under: stage, maximumSize: 1_048_576),
                  let data = try? SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: 1_048_576),
                  let journal = try? JSONDecoder().decode(DatabaseDeletionJournal.self, from: data),
                  journal.version == DatabaseDeletionJournal.currentVersion,
                  CustomDatabase.isSafeStorageIdentifier(journal.databaseID),
                  journal.files.allSatisfy({ Self.isValidDeletionLeaf($0, databaseID: journal.databaseID) }) else {
                quarantineDeletionStage(stage, in: directory)
                continue
            }
            close(descriptor)
            guard let registeredIDs else {
                quarantineDeletionStage(stage, in: directory)
                continue
            }
            do {
                if registeredIDs.contains(journal.databaseID) {
                    var conflict = false
                    for name in journal.files {
                        let staged = stage.appendingPathComponent(name)
                        let destination = directory.appendingPathComponent(name)
                        guard FileManager.default.fileExists(atPath: staged.path) else {
                            // Do not delete a journal whose promised rollback member
                            // vanished. It remains recoverable evidence for repair.
                            conflict = true
                            continue
                        }
                        if FileManager.default.fileExists(atPath: destination.path) {
                            conflict = true
                            continue
                        }
                        try FileManager.default.moveItem(at: staged, to: destination)
                        try SecureFileAccess.synchronize(directory, directory: true)
                    }
                    if conflict {
                        quarantineDeletionStage(stage, in: directory)
                        continue
                    }
                }
                try FileManager.default.removeItem(at: stage)
                try SecureFileAccess.synchronize(directory, directory: true)
            } catch {
                quarantineDeletionStage(stage, in: directory)
            }
        }
    }

    private static func isValidDeletionLeaf(_ name: String, databaseID: String) -> Bool {
        name == "\(databaseID)_data.csv" ||
        name == "\(databaseID)_embeddings.bin" ||
        name.range(of: "^\(NSRegularExpression.escapedPattern(for: databaseID))_embeddings_[A-Za-z0-9_-]{1,128}\\.(bin|json)$", options: .regularExpression) != nil
    }

    private func quarantineDeletionStage(_ stage: URL, in directory: URL) {
        let quarantine = directory.appendingPathComponent(".delete-quarantine-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: stage, to: quarantine)
            try SecureFileAccess.synchronize(directory, directory: true)
        } catch {
            logger.error("Could not quarantine interrupted database deletion: \(error.localizedDescription)")
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
