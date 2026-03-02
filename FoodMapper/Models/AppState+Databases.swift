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

        // Migrate legacy databases: generate metadata if missing
        var needsSave = false
        for i in customDatabases.indices {
            if customDatabases[i].sampleValues == nil {
                // Try stored copy first, then original path
                let csvPath: String
                if FileManager.default.fileExists(atPath: customDatabases[i].storedCsvURL.path) {
                    csvPath = customDatabases[i].storedCsvURL.path
                } else if FileManager.default.fileExists(atPath: customDatabases[i].csvPath) {
                    csvPath = customDatabases[i].csvPath
                    // Also copy the CSV to app support while we can
                    let storedURL = customDatabases[i].storedCsvURL
                    do {
                        try FileManager.default.createDirectory(
                            at: storedURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.copyItem(
                            at: URL(fileURLWithPath: customDatabases[i].csvPath),
                            to: storedURL
                        )
                    } catch {
                        logger.warning("Migration: failed to copy CSV for \(self.customDatabases[i].displayName): \(error)")
                    }
                } else {
                    logger.warning("Migration: CSV not found for \(self.customDatabases[i].displayName) -- database may be stale")
                    continue
                }

                let metadata = generateDatabaseMetadata(from: csvPath, textColumn: customDatabases[i].textColumn)
                customDatabases[i].sampleValues = metadata.sampleValues
                customDatabases[i].columnNames = metadata.columnNames
                needsSave = true
            }
        }

        // Fix corrupted metadata from \r\n line ending bug
        for i in customDatabases.indices {
            guard let columnNames = customDatabases[i].columnNames else { continue }
            let isCorrupted = columnNames.contains { $0.contains("\r") || $0.contains("\n") }
            guard isCorrupted else { continue }

            let csvPath: String
            if FileManager.default.fileExists(atPath: customDatabases[i].storedCsvURL.path) {
                csvPath = customDatabases[i].storedCsvURL.path
            } else if FileManager.default.fileExists(atPath: customDatabases[i].csvPath) {
                csvPath = customDatabases[i].csvPath
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
            let data = try JSONEncoder().encode(customDatabases)
            try data.write(to: customDatabasesURL)
        } catch {
            logger.error("Failed to save custom databases: \(error)")
        }
    }

    // MARK: - Benchmark Persistence

    func loadBenchmarkDatasets() {
        // Load user-persisted datasets first
        if FileManager.default.fileExists(atPath: benchmarksURL.path) {
            do {
                let data = try Data(contentsOf: benchmarksURL)
                benchmarkDatasets = try JSONDecoder().decode([BenchmarkDataset].self, from: data)
            } catch {
                logger.error("Failed to load benchmark datasets: \(error)")
            }
        }

        // Auto-discover bundled benchmark CSVs from Resources/Benchmarks/
        let bundleDir = Bundle.main.url(forResource: "Benchmarks", withExtension: nil)
        if let bundleDir {
            let fm = FileManager.default

            // Prune stale bundled datasets whose files no longer exist in the bundle
            let beforeCount = benchmarkDatasets.count
            benchmarkDatasets.removeAll { dataset in
                guard case .bundled(let filename) = dataset.source else { return false }
                let fileURL = bundleDir.appendingPathComponent(filename)
                let exists = fm.fileExists(atPath: fileURL.path)
                if !exists {
                    logger.info("Removing stale bundled benchmark: \(filename)")
                }
                return !exists
            }
            if benchmarkDatasets.count != beforeCount {
                saveBenchmarkDatasets()
            }

            if let files = try? fm.contentsOfDirectory(at: bundleDir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "csv" {
                    let filename = file.lastPathComponent
                    // Skip if already loaded (match by source filename)
                    let alreadyLoaded = benchmarkDatasets.contains { dataset in
                        if case .bundled(let name) = dataset.source { return name == filename }
                        return false
                    }
                    if alreadyLoaded { continue }

                    do {
                        let result = try BenchmarkCSVParser.parse(
                            url: file,
                            source: .bundled(filename: filename)
                        )
                        benchmarkDatasets.append(result.dataset)
                        logger.info("Auto-loaded bundled benchmark: \(result.dataset.name)")
                    } catch {
                        logger.warning("Skipping bundled benchmark \(filename): \(error)")
                    }
                }
                // Persist so bundled datasets get lastRunDate updates
                if !benchmarkDatasets.isEmpty {
                    saveBenchmarkDatasets()
                }
            }
        }

        logger.info("Loaded \(self.benchmarkDatasets.count) benchmark datasets")
    }

    func saveBenchmarkDatasets() {
        do {
            let dir = benchmarksURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(benchmarkDatasets)
            try data.write(to: benchmarksURL)
        } catch {
            logger.error("Failed to save benchmark datasets: \(error)")
        }
    }

    func saveBenchmarkResult(_ result: BenchmarkResult) {
        let url = benchmarkResultsDirectory.appendingPathComponent("\(result.id.uuidString).json")
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            try data.write(to: url, options: .atomic)
            benchmarkResults.append(result)

            // Update dataset's last run info
            if let idx = benchmarkDatasets.firstIndex(where: { $0.id == result.config.datasetId }) {
                benchmarkDatasets[idx].lastRunDate = result.timestamp
                benchmarkDatasets[idx].lastRunTopOneAccuracy = result.metrics.topOneAccuracy
                saveBenchmarkDatasets()
            }

            logger.info("Saved benchmark result \(result.id.uuidString)")
        } catch {
            logger.error("Failed to save benchmark result: \(error)")
        }
    }

    func loadBenchmarkResults() {
        let dir = benchmarkResultsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [BenchmarkResult] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let result = try decoder.decode(BenchmarkResult.self, from: data)
                results.append(result)
            } catch {
                logger.warning("Skipping benchmark result file \(file.lastPathComponent): \(error)")
            }
        }
        benchmarkResults = results.sorted { $0.timestamp > $1.timestamp }
        logger.info("Loaded \(results.count) benchmark results")
    }

    func deleteBenchmarkResult(_ result: BenchmarkResult) {
        let url = benchmarkResultsDirectory.appendingPathComponent("\(result.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        benchmarkResults.removeAll { $0.id == result.id }
    }

    /// Add a custom database and pre-embed it
    /// The database is only persisted after embedding completes successfully
    /// The embedding happens asynchronously with progress reported via databaseEmbeddingStatus
    func addCustomDatabase(_ database: CustomDatabase) {
        // Don't add to list yet - only after embedding succeeds
        embedDatabaseAsync(database)
    }

    /// Embed a custom database with progress reporting
    /// Database is only added to the list after successful embedding
    func embedDatabaseAsync(_ database: CustomDatabase) {
        embeddingTask = Task {
            do {
                let engine = try await getOrCreateEngine()
                let startTime = Date()

                await MainActor.run {
                    self.databaseEmbeddingStatus = .embedding(
                        completed: 0,
                        total: database.itemCount,
                        databaseName: database.displayName,
                        startTime: startTime
                    )
                }

                try await engine.embedCustomDatabase(
                    database,
                    batchSize: self.effectiveEmbeddingBatchSize,
                    chunkSize: self.effectiveChunkSize
                ) { [weak self] completed, total in
                    Task { @MainActor in
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

                // Copy source CSV into app support for self-contained storage
                let sourceURL = URL(fileURLWithPath: database.csvPath)
                let storedURL = database.storedCsvURL
                do {
                    // Ensure directory exists
                    try FileManager.default.createDirectory(
                        at: storedURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    // Remove existing copy if present (re-embedding)
                    if FileManager.default.fileExists(atPath: storedURL.path) {
                        try FileManager.default.removeItem(at: storedURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: storedURL)
                } catch {
                    logger.warning("Failed to copy CSV to app support: \(error). Original path will be used.")
                }

                // Generate preview metadata from the CSV
                let metadata = self.generateDatabaseMetadata(from: storedURL.path, textColumn: database.textColumn)

                await MainActor.run {
                    // NOW add the database - embedding succeeded
                    var finalDatabase = database
                    finalDatabase.embeddingDuration = duration
                    finalDatabase.cacheSize = cacheSize
                    finalDatabase.sampleValues = metadata.sampleValues
                    finalDatabase.columnNames = metadata.columnNames
                    self.customDatabases.append(finalDatabase)
                    self.saveCustomDatabases()

                    self.databaseEmbeddingStatus = .completed(
                        databaseName: database.displayName,
                        itemCount: database.itemCount,
                        duration: duration
                    )
                    self.embeddingCacheVersion += 1
                    // Auto-select the newly added database
                    self.selectedDatabase = .custom(finalDatabase)
                    // Completion screen stays visible until user clicks "Done"
                }
            } catch is CancellationError {
                await MainActor.run {
                    // Cancelled - don't add database, clean up any partial cache file
                    self.cleanupPartialEmbeddings(for: database)
                    self.databaseEmbeddingStatus = .idle
                }
            } catch {
                await MainActor.run {
                    // Error - don't add database, clean up any partial cache file
                    self.cleanupPartialEmbeddings(for: database)
                    self.databaseEmbeddingStatus = .error(error.localizedDescription)
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
        databaseEmbeddingStatus = .idle
    }

    /// Re-embed an existing custom database with the current pipeline's embedding model.
    /// Does not remove existing embeddings from other models -- adds alongside them.
    func reembedCustomDatabase(_ database: CustomDatabase) {
        guard let embeddingKey = selectedPipelineType.embeddingModelKey else { return }
        guard !databaseEmbeddingStatus.isEmbedding else { return }

        embeddingTask = Task {
            do {
                let engine = try await getOrCreateEngine()
                let startTime = Date()

                // Load the embedding model for the selected pipeline
                let model = try await self.modelManager.loadEmbeddingModel(key: embeddingKey)
                await engine.setEmbeddingModel(model)

                await MainActor.run {
                    self.databaseEmbeddingStatus = .embedding(
                        completed: 0,
                        total: database.itemCount,
                        databaseName: database.displayName,
                        startTime: startTime
                    )
                }

                try await engine.embedCustomDatabase(
                    database,
                    batchSize: self.effectiveEmbeddingBatchSize,
                    chunkSize: self.effectiveChunkSize
                ) { [weak self] completed, total in
                    Task { @MainActor in
                        self?.databaseEmbeddingStatus = .embedding(
                            completed: completed,
                            total: total,
                            databaseName: database.displayName,
                            startTime: startTime
                        )
                    }
                }

                let duration = Date().timeIntervalSince(startTime)

                await MainActor.run {
                    // Update the database metadata
                    if let idx = self.customDatabases.firstIndex(where: { $0.id == database.id }) {
                        self.customDatabases[idx].cacheSize = self.getCacheFileSize(for: database)
                        self.saveCustomDatabases()
                    }
                    self.databaseEmbeddingStatus = .completed(
                        databaseName: database.displayName,
                        itemCount: database.itemCount,
                        duration: duration
                    )
                    self.embeddingCacheVersion += 1
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.databaseEmbeddingStatus = .idle
                }
            } catch {
                await MainActor.run {
                    self.databaseEmbeddingStatus = .error(error.localizedDescription)
                }
            }
        }
    }

    /// Get total cache file size for a database (all model versions)
    func getCacheFileSize(for database: CustomDatabase) -> Int64? {
        let total = database.totalCacheSize
        return total > 0 ? total : nil
    }

    func deleteCustomDatabase(_ database: CustomDatabase) {
        // Delete all cached embedding files (all model versions + legacy)
        for file in database.allCacheFiles {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: database.legacyCacheURL)

        // Delete self-contained CSV copy
        try? FileManager.default.removeItem(at: database.storedCsvURL)

        customDatabases.removeAll { $0.id == database.id }
        saveCustomDatabases()

        if case .custom(let selected) = selectedDatabase, selected.id == database.id {
            selectedDatabase = nil
        }
    }
}
