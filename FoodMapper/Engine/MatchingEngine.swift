import Foundation
import CryptoKit
import Hub
import MLX
import os
import Darwin

private let logger = Logger(subsystem: "com.foodmapper", category: "engine")

struct CustomDatabaseCacheMetadata: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let databaseID: String
    let sourceHash: String
    let schemaHash: String
    let rowOrderHash: String
    let textColumn: String
    let idColumn: String?
    let modelKey: String
    let modelArtifactFingerprint: String
    let entryCount: Int
    let embeddingDimensions: Int
    let embeddingDigest: String

    func matchesIdentity(_ other: CustomDatabaseCacheMetadata) -> Bool {
        version == other.version &&
        databaseID == other.databaseID &&
        sourceHash == other.sourceHash &&
        schemaHash == other.schemaHash &&
        rowOrderHash == other.rowOrderHash &&
        textColumn == other.textColumn &&
        idColumn == other.idColumn &&
        modelKey == other.modelKey &&
        modelArtifactFingerprint == other.modelArtifactFingerprint &&
        entryCount == other.entryCount &&
        embeddingDimensions == other.embeddingDimensions
    }

    func withEmbeddingDigest(_ digest: String) -> CustomDatabaseCacheMetadata {
        CustomDatabaseCacheMetadata(
            version: version, databaseID: databaseID, sourceHash: sourceHash,
            schemaHash: schemaHash, rowOrderHash: rowOrderHash, textColumn: textColumn,
            idColumn: idColumn, modelKey: modelKey, modelArtifactFingerprint: modelArtifactFingerprint,
            entryCount: entryCount, embeddingDimensions: embeddingDimensions, embeddingDigest: digest
        )
    }
}

struct CacheCommitJournal: Codable {
    static let currentVersion = 3

    let version: Int
    let cacheName: String
    let metadataName: String
    let metadata: CustomDatabaseCacheMetadata

    init(cacheName: String, metadataName: String, metadata: CustomDatabaseCacheMetadata) {
        self.version = Self.currentVersion
        self.cacheName = cacheName
        self.metadataName = metadataName
        self.metadata = metadata
    }
}

struct ValidatedCustomDatabase {
    let entries: [DatabaseEntry]
    let sourceHash: String
    let schemaHash: String
    let rowOrderHash: String
    let fileFormat: DataFileFormat
    let columnNames: [String]
    let sourceIdentity: CustomDatabaseFileIdentity
}

/// The descriptor identity captured with the bytes that were parsed. It keeps a
/// cache write from being associated with a replacement CSV that reused the
/// same database ID.
struct CustomDatabaseFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let byteSize: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

enum CustomDatabaseValidationError: LocalizedError, Equatable {
    static let defaultMaximumImportBytes = 512 * 1_024 * 1_024

    case blankHeader(column: Int)
    case duplicateHeader(String)
    case malformedRow(row: Int, expected: Int, actual: Int)
    case blankText(row: Int, column: String)
    case blankID(row: Int, column: String)
    case duplicateID(id: String, firstRow: Int, duplicateRow: Int)
    case importTooLarge(actual: Int64, limit: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .blankHeader(column):
            return "Column \(column) has no header."
        case let .duplicateHeader(name):
            return "The \(name) column appears more than once."
        case let .malformedRow(row, expected, actual):
            return "Row \(row) has \(actual) values; expected \(expected)."
        case let .blankText(row, column):
            return "Row \(row) has no value in the \(column) column."
        case let .blankID(row, column):
            return "Row \(row) has no value in the \(column) ID column."
        case let .duplicateID(id, firstRow, duplicateRow):
            return "ID '\(id)' appears in rows \(firstRow) and \(duplicateRow)."
        case let .importTooLarge(actual, limit):
            return "This database is \(actual) bytes. The import limit is \(limit) bytes."
        case .cancelled:
            return "Database import was cancelled."
        }
    }
}

enum CustomDatabaseValidator {
    /// The CSV parser materializes a validated import. This limit bounds that allocation.
    /// Set FOODMAPPER_MAX_IMPORT_BYTES for managed deployments that need a lower limit.
    static var maximumImportBytes: Int {
        let configured = ProcessInfo.processInfo.environment["FOODMAPPER_MAX_IMPORT_BYTES"].flatMap(Int.init)
        return min(max(configured ?? CustomDatabaseValidationError.defaultMaximumImportBytes, 1_024 * 1_024), CustomDatabaseValidationError.defaultMaximumImportBytes)
    }

    static func load(url: URL, textColumn: String, idColumn: String?) throws -> ValidatedCustomDatabase {
        let descriptor = try SecureFileAccess.openRegularFile(
            url, maximumSize: Int64(maximumImportBytes)
        )
        defer { close(descriptor) }
        return try load(descriptor: descriptor, textColumn: textColumn, idColumn: idColumn)
    }

    static func load(descriptor: Int32, textColumn: String, idColumn: String?) throws -> ValidatedCustomDatabase {
        let before = try fileIdentity(descriptor)
        let data = try SecureFileAccess.readBounded(
            descriptor: descriptor, maximumSize: maximumImportBytes
        )
        guard try fileIdentity(descriptor) == before else {
            throw MatchingError.databaseNotFound
        }
        guard let rawContent = String(data: data, encoding: .utf8) else {
            throw MatchingError.databaseNotFound
        }
        let content = CSVParser.stripBOM(rawContent)
        let format = DataFileFormat.detect(from: content)
        let records = try CSVParser.parseRecords(content: content, delimiter: format.delimiter)
        guard records.count > 1 else { throw MatchingError.emptyDatabase }

        let header = records[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (index, name) in header.enumerated() where name.isEmpty {
            throw CustomDatabaseValidationError.blankHeader(column: index + 1)
        }
        var headerNames = Set<String>()
        for name in header {
            let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard headerNames.insert(normalized).inserted else {
                throw CustomDatabaseValidationError.duplicateHeader(name)
            }
        }
        let normalizedTextColumn = textColumn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let textIndex = header.firstIndex(of: normalizedTextColumn) else {
            throw MatchingError.columnNotFound(textColumn)
        }
        let normalizedIDColumn = idColumn?.trimmingCharacters(in: .whitespacesAndNewlines)
        let idIndex: Int?
        if let normalizedIDColumn, !normalizedIDColumn.isEmpty {
            guard let index = header.firstIndex(of: normalizedIDColumn) else {
                throw MatchingError.columnNotFound(normalizedIDColumn)
            }
            idIndex = index
        } else {
            idIndex = nil
        }

        var entries: [DatabaseEntry] = []
        entries.reserveCapacity(records.count - 1)
        var ids = [String: Int]()
        var generatedIDCounts = [String: Int]()
        var generatedIDByEntryIndex: [String] = []
        var normalizedRows: [String] = []
        normalizedRows.reserveCapacity(records.count - 1)

        for recordIndex in 1..<records.count {
            let rowNumber = recordIndex + 1
            let values = records[recordIndex]
            guard values.count == header.count else {
                throw CustomDatabaseValidationError.malformedRow(
                    row: rowNumber, expected: header.count, actual: values.count
                )
            }
            let text = values[textIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw CustomDatabaseValidationError.blankText(row: rowNumber, column: normalizedTextColumn)
            }
            let id: String
            if let idIndex, let normalizedIDColumn {
                id = values[idIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty else {
                    throw CustomDatabaseValidationError.blankID(row: rowNumber, column: normalizedIDColumn)
                }
                if let firstRow = ids[id] {
                    throw CustomDatabaseValidationError.duplicateID(id: id, firstRow: firstRow, duplicateRow: rowNumber)
                }
                ids[id] = rowNumber
            } else {
                // The content hash is the public identity. Byte-identical rows are
                // interchangeable, so their duplicate ordinal is metadata rather
                // than a fabricated stable identifier.
                let normalizedRow = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: "\u{1F}")
                let baseID = "row-\(digest(normalizedRow).prefix(24))"
                generatedIDCounts[baseID, default: 0] += 1
                generatedIDByEntryIndex.append(baseID)
                id = baseID
            }

            var additionalFields: [String: String] = [:]
            for (columnIndex, columnName) in header.enumerated() where columnIndex != textIndex && columnIndex != idIndex {
                let value = values[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { additionalFields[columnName] = value }
            }
            entries.append(DatabaseEntry(id: id, text: text, additionalFields: additionalFields))
            normalizedRows.append(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\u{1F}"))
        }

        for index in entries.indices {
            let baseID = generatedIDByEntryIndex.indices.contains(index) ? generatedIDByEntryIndex[index] : ""
            if generatedIDCounts[baseID, default: 0] > 1 {
                let ordinal = generatedIDByEntryIndex[0...index].filter { $0 == baseID }.count
                var fields = entries[index].additionalFields
                fields["FoodMapper duplicate ordinal"] = String(ordinal)
                entries[index] = DatabaseEntry(id: entries[index].id, text: entries[index].text, additionalFields: fields)
            }
        }

        return ValidatedCustomDatabase(
            entries: entries,
            sourceHash: digest(data),
            schemaHash: digest(header.joined(separator: "\u{1F}")),
            rowOrderHash: digest(normalizedRows.joined(separator: "\u{1E}")),
            fileFormat: format,
            columnNames: header,
            sourceIdentity: before
        )
    }

    static func currentIdentity(of url: URL) throws -> CustomDatabaseFileIdentity {
        let descriptor = try SecureFileAccess.openRegularFile(
            url, maximumSize: Int64(maximumImportBytes)
        )
        defer { close(descriptor) }
        return try fileIdentity(descriptor)
    }

    private static func fileIdentity(_ descriptor: Int32) throws -> CustomDatabaseFileIdentity {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else {
            throw MatchingError.databaseNotFound
        }
        return CustomDatabaseFileIdentity(
            device: UInt64(info.st_dev), inode: UInt64(info.st_ino), byteSize: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    static func digest(_ string: String) -> String { digest(Data(string.utf8)) }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Embedding + cosine similarity matching engine
actor MatchingEngine {
    private var embeddingModel: (any EmbeddingModelProtocol)?

    // GPU-optimized storage: contiguous MLXArray matrix for fast similarity
    private var targetEmbeddingMatrix: MLXArray?  // [N, embeddingDim]
    private var targetIDs: [String] = []          // Parallel array for ID lookup

    // Metadata lookup (keep for entry details)
    private var targetEntries: [String: DatabaseEntry] = [:]

    /// Current embedding model key (for cache versioning)
    private var currentModelKey: String?
    /// Identity of the rows presently held in memory. Never use a database ID
    /// alone here: an imported file can be replaced without its ID changing.
    private var currentDatabaseIdentity: String?
    private var activeRunID: UUID?
    private var cancelledRunIDs: Set<UUID> = []

    /// Directory for storing generated embeddings for custom databases
    private static var customEmbeddingsDir: URL {
        let appSupport = FoodMapperStorage.applicationSupportURL
        let dir = appSupport.appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: SecureFileAccess.storageDirectoryPermissions], ofItemAtPath: dir.path)
        return dir
    }

    init() async throws {
        Self.recoverInterruptedCacheTransactions()
    }

    private func beginRun() throws -> UUID {
        guard activeRunID == nil else { throw CancellationError() }
        let id = UUID()
        activeRunID = id
        return id
    }

    private func checkRun(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeRunID == id, !cancelledRunIDs.contains(id) else {
            throw CancellationError()
        }
    }

    private func finishRun(_ id: UUID) {
        guard activeRunID == id else { return }
        activeRunID = nil
        cancelledRunIDs.remove(id)
    }

    /// Ensure an embedding model is loaded. If a model was already set (via setEmbeddingModel
    /// or a previous loadModelIfNeeded(modelKey:) call), this is a no-op. Only falls back to
    /// GTE-Large when no model has been loaded at all.
    func loadModelIfNeeded() async throws {
        if embeddingModel != nil { return }
        try await loadModelIfNeeded(modelKey: "gte-large")
    }

    /// Load an embedding model by key. If a different model is loaded, invalidate the database cache.
    /// For Qwen3 models, prefer using setEmbeddingModel() with a model loaded via ModelManager,
    /// which uses the correct HubApi download base.
    func loadModelIfNeeded(modelKey: String) async throws {
        try await loadModelIfNeeded(modelKey: modelKey, hub: HubApi())
    }

    /// Load an embedding model by key with a specific HubApi for download location.
    func loadModelIfNeeded(modelKey: String, hub _: HubApi) async throws {
        // Already loaded with the right model?
        if let model = embeddingModel, model.info.key == modelKey {
            return
        }

        // Different model -- clear database cache (embeddings are model-specific)
        if currentModelKey != nil && currentModelKey != modelKey {
            targetEmbeddingMatrix = nil
            targetIDs.removeAll()
            targetEntries.removeAll()
            currentDatabaseIdentity = nil
        }

        switch modelKey {
        case "gte-large":
            let model = MLXEmbeddingModel()
            try await model.load()
            embeddingModel = model
        case "qwen3-emb-4b-4bit":
            // Qwen snapshots are loaded through ModelManager after manifest
            // validation. The engine must not invoke Hub while matching.
            throw MatchingError.modelNotLoaded
        default:
            throw MatchingError.unknownModel(modelKey)
        }

        currentModelKey = modelKey
    }

    /// Set an externally loaded embedding model (used by ModelManager)
    func setEmbeddingModel(_ model: any EmbeddingModelProtocol) {
        if currentModelKey != model.info.key {
            targetEmbeddingMatrix = nil
            targetIDs.removeAll()
            targetEntries.removeAll()
            currentDatabaseIdentity = nil
        }
        embeddingModel = model
        currentModelKey = model.info.key
    }

    /// Clear the in-memory target before writing a replacement cache, including when
    /// the selected model key has not changed.
    func invalidateLoadedDatabase() {
        targetEmbeddingMatrix = nil
        targetIDs.removeAll()
        targetEntries.removeAll()
        currentDatabaseIdentity = nil
    }

    /// Get the currently loaded database entries (for pipelines that need entries without embedding)
    func getLoadedEntries() throws -> [DatabaseEntry] {
        guard !targetIDs.isEmpty else {
            throw MatchingError.databaseNotFound
        }
        return targetIDs.compactMap { targetEntries[$0] }
    }

    /// Load database entries WITHOUT computing or loading embeddings.
    /// For pipelines that only need entry text/metadata (LLMOnly, RerankerOnly).
    func loadDatabaseEntriesOnly(_ database: AnyDatabase) async throws -> [DatabaseEntry] {
        switch database {
        case .builtIn(let builtIn):
            return try await loadBuiltInDatabaseEntries(for: builtIn)
        case .custom(let custom):
            return try await loadCustomDatabaseEntries(for: custom)
        }
    }

    /// Set a custom matching instruction on the embedding model
    func setInstruction(_ instruction: String?) async {
        let modelKey = currentModelKey ?? "(none)"
        let isAsymmetric = embeddingModel?.info.isAsymmetric ?? false
        if let instruction = instruction {
            if isAsymmetric {
                logger.info("[Engine] setInstruction | Model: \(modelKey) (asymmetric) | Forwarding instruction: \(instruction.prefix(100))")
            } else {
                logger.info("[Engine] setInstruction | Model: \(modelKey) (symmetric) | Instruction passed but model ignores it: \(instruction.prefix(100))")
            }
        } else {
            logger.info("[Engine] setInstruction | Model: \(modelKey) | Instruction: nil (model default will be used)")
        }
        await embeddingModel?.setInstruction(instruction)
    }

    /// Get the model's execution provider string
    func getExecutionProvider() async -> String {
        if let model = embeddingModel as? MLXEmbeddingModel {
            return model.executionProvider
        }
        return embeddingModel != nil ? "MLX (GPU)" : "Not loaded"
    }

    /// Load target database embeddings (supports both built-in and custom databases)
    /// - Parameter onEmbedProgress: Optional callback reporting (completed, total) when computing embeddings for the first time
    func loadDatabase(_ database: AnyDatabase, onEmbedProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        // Clear previous database
        targetEmbeddingMatrix = nil
        targetIDs.removeAll()
        targetEntries.removeAll()

        // Load based on database type
        let entries: [DatabaseEntry]
        let matrix: MLXArray?
        let embeddings: [[Float]]?

        switch database {
        case .builtIn(let builtIn):
            let result = try await loadBuiltInDatabase(builtIn, onEmbedProgress: onEmbedProgress)
            entries = result.entries
            matrix = result.matrix
            embeddings = result.embeddings
        case .custom(let custom):
            let result = try await loadCustomDatabase(custom, onEmbedProgress: onEmbedProgress)
            entries = result.entries
            matrix = result.matrix
            embeddings = result.embeddings
        }

        // Store entries and build ID array (preserving order)
        for (index, entry) in entries.enumerated() {
            let internalID = "\(entry.id)\u{1F}\(index)"
            targetEntries[internalID] = entry
            targetIDs.append(internalID)
        }

        // Set the embedding matrix -- prefer direct MLXArray if available
        if let matrix {
            targetEmbeddingMatrix = matrix
        } else if let embeddings {
            let embeddingDim = embeddingModel?.info.dimensions ?? 1024
            let flatData = embeddings.flatMap { $0 }
            targetEmbeddingMatrix = MLXArray(flatData).reshaped([entries.count, embeddingDim])
        }

        currentDatabaseIdentity = Self.databaseIdentity(for: entries, databaseID: database.id)
    }

    /// Result from database loading: entries plus embeddings as either direct MLXArray or [[Float]]
    private struct DatabaseLoadResult {
        let entries: [DatabaseEntry]
        let matrix: MLXArray?       // Direct binary -> MLXArray (fast path, no intermediate [[Float]])
        let embeddings: [[Float]]?  // Fallback for freshly computed embeddings
    }

    private nonisolated static func databaseIdentity(for entries: [DatabaseEntry], databaseID: String) -> String {
        let rows = entries.map { entry in
            let fields = entry.additionalFields.sorted { $0.key < $1.key }
                .map { "\($0.key)\u{1F}\($0.value)" }.joined(separator: "\u{1E}")
            return "\(entry.id)\u{1F}\(entry.text)\u{1F}\(fields)"
        }.joined(separator: "\u{1D}")
        return CustomDatabaseValidator.digest("\(databaseID)\u{1C}\(rows)")
    }

    /// Load built-in database with pre-computed or cached embeddings.
    /// Pre-computed bundle embeddings are GTE-Large only. Other models use versioned cache paths.
    private func loadBuiltInDatabase(_ database: BuiltInDatabase, onEmbedProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> DatabaseLoadResult {
        let entries = try await loadBuiltInDatabaseEntries(for: database)
        let modelKey = currentModelKey ?? "gte-large"
        let embeddingDim = embeddingModel?.info.dimensions ?? 1024

        // 1. Pre-computed embeddings in resource bundle (GTE-Large only)
        if modelKey == "gte-large", let dbDir = ResourceBundle.databasesDirectory {
            let embeddingsURL = dbDir.appendingPathComponent(database.embeddingsFilename)
            if FileManager.default.fileExists(atPath: embeddingsURL.path) {
                let matrix = try loadBinaryEmbeddingsAsMatrix(from: embeddingsURL, count: entries.count, embeddingDim: embeddingDim)
                return DatabaseLoadResult(entries: entries, matrix: matrix, embeddings: nil)
            }
        }

        // Built-in resources are immutable application assets. Do not reuse the
        // old metadata-free Application Support caches: they cannot prove their
        // rows, model artifact, or dimensions still match this load.
        let (finalEntries, embeddings) = try await computeAndCacheEmbeddings(for: entries, databaseId: database.id, onProgress: onEmbedProgress)
        return DatabaseLoadResult(entries: finalEntries, matrix: nil, embeddings: embeddings)
    }

    /// Load custom database, computing embeddings on first use.
    private func loadCustomDatabase(_ database: CustomDatabase, onEmbedProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> DatabaseLoadResult {
        let validated = try await validatedCustomDatabase(for: database)
        let entries = validated.entries
        let modelKey = currentModelKey ?? "gte-large"
        let embeddingDim = embeddingModel?.info.dimensions ?? 1024
        let metadata = try await customCacheMetadata(
            database: database,
            validated: validated,
            modelKey: modelKey,
            embeddingDimensions: embeddingDim
        )

        // 1. Check for model-versioned cached embeddings
        let versionedURL = Self.customEmbeddingsDir.appendingPathComponent("\(database.id)_embeddings_\(modelKey).bin")
        let metadataURL = database.cacheMetadataURL(for: modelKey)
        if FileManager.default.fileExists(atPath: versionedURL.path) {
            do {
                let cachedMetadata = try decodeCacheMetadata(at: metadataURL)
                if cachedMetadata.matchesIdentity(metadata) {
                    let expectedSize = try Self.expectedEmbeddingByteCount(
                        entries: entries.count, dimensions: embeddingDim
                    )
                    let cacheData = try readPrivateCache(versionedURL, maximumSize: expectedSize)
                    guard cachedMetadata.embeddingDigest == CustomDatabaseValidator.digest(cacheData) else {
                        throw MatchingError.invalidEmbeddingsFile
                    }
                    guard cacheData.withUnsafeBytes({ $0.bindMemory(to: Float.self).allSatisfy(\.isFinite) }) else {
                        throw MatchingError.invalidEmbeddingsFile
                    }
                    let matrix = MLXArray(cacheData, [entries.count, embeddingDim], type: Float.self)
                    try assertCurrentCustomDatabaseIdentity(database, validated: validated)
                    return DatabaseLoadResult(entries: entries, matrix: matrix, embeddings: nil)
                }
            } catch {
                logger.warning("Ignoring invalid custom embedding cache for \(database.displayName): \(error.localizedDescription)")
            }
        }

        // Caches without matching metadata are intentionally recomputed. Earlier cache
        // files did not describe their source rows or model artifact.
        let (finalEntries, embeddings) = try await computeAndCacheEmbeddings(for: entries, databaseId: database.id, onProgress: onEmbedProgress)
        try assertCurrentCustomDatabaseIdentity(database, validated: validated)
        try writeCustomCache(embeddings, to: versionedURL, metadata: metadata, metadataURL: metadataURL)
        try assertCurrentCustomDatabaseIdentity(database, validated: validated)

        return DatabaseLoadResult(entries: finalEntries, matrix: nil, embeddings: embeddings)
    }

    /// Compute embeddings for entries, report progress per batch
    private func computeAndCacheEmbeddings(
        for entries: [DatabaseEntry],
        databaseId: String,
        embeddingBatchSize: Int = 32,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ([DatabaseEntry], [[Float]]) {
        guard let model = embeddingModel else {
            throw MatchingError.modelNotLoaded
        }

        let texts = entries.map { $0.text }
        let total = texts.count

        // Report initial progress
        onProgress?(0, total)

        if onProgress != nil {
            // Batch manually so we can report progress after each chunk
            var allEmbeddings: [[Float]] = []
            allEmbeddings.reserveCapacity(total)

            for batchStart in stride(from: 0, to: total, by: embeddingBatchSize) {
                try Task.checkCancellation()
                let batchEnd = min(batchStart + embeddingBatchSize, total)
                let batch = Array(texts[batchStart..<batchEnd])
                // isQuery: false -- database entries are documents, not queries
                let batchEmbeddings = try await model.embedBatch(batch, batchSize: embeddingBatchSize, isQuery: false)
                allEmbeddings.append(contentsOf: batchEmbeddings)
                onProgress?(batchEnd, total)
            }

            return (entries, allEmbeddings)
        } else {
            // No progress callback -- single call for efficiency
            // isQuery: false -- database entries are documents, not queries
            let embeddings = try await model.embedBatch(texts, batchSize: embeddingBatchSize, isQuery: false)
            try Task.checkCancellation()
            return (entries, embeddings)
        }
    }

    private func customCacheMetadata(
        database: CustomDatabase,
        validated: ValidatedCustomDatabase,
        modelKey: String,
        embeddingDimensions: Int
    ) async throws -> CustomDatabaseCacheMetadata {
        let modelFingerprint = try await modelArtifactFingerprint(
            modelKey: modelKey, embeddingDimensions: embeddingDimensions
        )
        return CustomDatabaseCacheMetadata(
            version: CustomDatabaseCacheMetadata.currentVersion,
            databaseID: database.id,
            sourceHash: validated.sourceHash,
            schemaHash: validated.schemaHash,
            rowOrderHash: validated.rowOrderHash,
            textColumn: database.textColumn.trimmingCharacters(in: .whitespacesAndNewlines),
            idColumn: database.idColumn?.trimmingCharacters(in: .whitespacesAndNewlines),
            modelKey: modelKey,
            modelArtifactFingerprint: modelFingerprint,
            entryCount: validated.entries.count,
            embeddingDimensions: embeddingDimensions,
            embeddingDigest: ""
        )
    }

    private func assertCurrentCustomDatabaseIdentity(
        _ database: CustomDatabase, validated: ValidatedCustomDatabase
    ) throws {
        guard let url = database.csvURL,
              try CustomDatabaseValidator.currentIdentity(of: url) == validated.sourceIdentity else {
            throw MatchingError.databaseNotFound
        }
    }

    private func modelArtifactFingerprint(modelKey: String, embeddingDimensions: Int) async throws -> String {
        let directory: URL?
        if let model = embeddingModel as? QwenEmbeddingModel {
            let repoID = model.repoId
            let appSupport = FoodMapperStorage.applicationSupportURL
                .appendingPathComponent("FoodMapper", isDirectory: true)
            directory = HubApi(downloadBase: appSupport).localRepoLocation(Hub.Repo(id: repoID))
        } else {
            directory = MLXEmbeddingModel.modelDirectory
        }
        guard let directory else { throw MatchingError.modelNotLoaded }
        let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
        let artifacts = try paths.sorted().compactMap { path -> (String, URL)? in
            let url = directory.appendingPathComponent(path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw MatchingError.invalidEmbeddingsFile }
            guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return (path, url)
        }
        let descriptor = try artifacts.map { path, url in
            let digest = try Self.digestFile(url)
            return "\(path)|\(digest)"
        }.joined(separator: "\n")
        let fingerprint = CustomDatabaseValidator.digest("custom-cache-v2|\(modelKey)|\(embeddingDimensions)|\(descriptor)")
        return fingerprint
    }

    private nonisolated static func digestFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func decodeCacheMetadata(at url: URL) throws -> CustomDatabaseCacheMetadata {
        let data = try readPrivateCache(url, maximumSize: 1_048_576)
        let metadata = try JSONDecoder().decode(CustomDatabaseCacheMetadata.self, from: data)
        guard metadata.version == CustomDatabaseCacheMetadata.currentVersion else {
            throw MatchingError.invalidEmbeddingsFile
        }
        return metadata
    }

    private func readPrivateCache(_ url: URL, maximumSize: Int) throws -> Data {
        let descriptor = try SecureFileAccess.openRegularFile(
            url, under: Self.customEmbeddingsDir, maximumSize: Int64(maximumSize)
        )
        defer { close(descriptor) }
        return try SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: maximumSize)
    }

    private func writeCustomCache(
        _ embeddings: [[Float]],
        to cacheURL: URL,
        metadata: CustomDatabaseCacheMetadata,
        metadataURL: URL
    ) throws {
        try Task.checkCancellation()
        let dimensions = metadata.embeddingDimensions
        guard embeddings.count == metadata.entryCount,
              embeddings.allSatisfy({ $0.count == dimensions && $0.allSatisfy(\.isFinite) }) else {
            throw MatchingError.invalidEmbeddingsFile
        }
        var data = Data()
        data.reserveCapacity(embeddings.count * dimensions * MemoryLayout<Float>.size)
        for embedding in embeddings {
            try Task.checkCancellation()
            data.append(embedding.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        try commitCustomCache(
            data: data,
            metadata: metadata.withEmbeddingDigest(CustomDatabaseValidator.digest(data)),
            cacheURL: cacheURL,
            metadataURL: metadataURL
        )
    }

    private func commitCustomCache(
        data: Data,
        metadata: CustomDatabaseCacheMetadata,
        cacheURL: URL,
        metadataURL: URL
    ) throws {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheURL.deletingLastPathComponent().path)
        let stagingCacheURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent(".\(cacheURL.lastPathComponent).\(UUID().uuidString).stage")
        let stagingMetadataURL = metadataURL.deletingLastPathComponent()
            .appendingPathComponent(".\(metadataURL.lastPathComponent).\(UUID().uuidString).stage")
        defer {
            try? fileManager.removeItem(at: stagingCacheURL)
            try? fileManager.removeItem(at: stagingMetadataURL)
        }
        try data.write(to: stagingCacheURL, options: [.atomic])
        try Task.checkCancellation()
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingCacheURL.path)
        try synchronizeFile(stagingCacheURL)
        let expectedSize = try Self.expectedEmbeddingByteCount(
            entries: metadata.entryCount, dimensions: metadata.embeddingDimensions
        )
        let stagedSize = try stagingCacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard stagedSize == expectedSize else { throw MatchingError.invalidEmbeddingsFile }
        try JSONEncoder().encode(metadata).write(to: stagingMetadataURL, options: [.atomic])
        try Task.checkCancellation()
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingMetadataURL.path)
        try synchronizeFile(stagingMetadataURL)
        _ = try decodeCacheMetadata(at: stagingMetadataURL)

        try commitCacheTransaction(stagingCacheURL, stagingMetadataURL, cacheURL: cacheURL, metadataURL: metadataURL)
    }

    private func replaceAtomically(_ stagedURL: URL, at destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    private func synchronizeFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MatchingError.invalidEmbeddingsFile }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw MatchingError.invalidEmbeddingsFile }
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw MatchingError.invalidEmbeddingsFile }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw MatchingError.invalidEmbeddingsFile }
    }

    private func commitCacheTransaction(
        _ stagedCache: URL,
        _ stagedMetadata: URL,
        cacheURL: URL,
        metadataURL: URL,
        cancellationCheck: (() throws -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        let directory = cacheURL.deletingLastPathComponent()
        let transaction = directory.appendingPathComponent(".cache-transaction-\(UUID().uuidString)")
        let backupCache = transaction.appendingPathComponent("cache.backup")
        let backupMetadata = transaction.appendingPathComponent("metadata.backup")
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        let stagedMetadataValue = try decodeCacheMetadata(at: stagedMetadata)
        let journal = CacheCommitJournal(
            cacheName: cacheURL.lastPathComponent, metadataName: metadataURL.lastPathComponent,
            metadata: stagedMetadataValue
        )
        let journalURL = transaction.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: journalURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        try synchronizeDirectory(transaction)
        do {
            try Task.checkCancellation()
            try cancellationCheck?()
            if fileManager.fileExists(atPath: cacheURL.path) { try fileManager.moveItem(at: cacheURL, to: backupCache) }
            if fileManager.fileExists(atPath: metadataURL.path) { try fileManager.moveItem(at: metadataURL, to: backupMetadata) }
            try synchronizeDirectory(directory)
            try Task.checkCancellation()
            try cancellationCheck?()
            try fileManager.moveItem(at: stagedCache, to: cacheURL)
            try Task.checkCancellation()
            try cancellationCheck?()
            try fileManager.moveItem(at: stagedMetadata, to: metadataURL)
            try synchronizeDirectory(directory)
            try Task.checkCancellation()
            try cancellationCheck?()
            try fileManager.removeItem(at: transaction)
            try synchronizeDirectory(directory)
        } catch {
            do {
                if fileManager.fileExists(atPath: cacheURL.path) { try fileManager.removeItem(at: cacheURL) }
                if fileManager.fileExists(atPath: metadataURL.path) { try fileManager.removeItem(at: metadataURL) }
                if fileManager.fileExists(atPath: backupCache.path) { try fileManager.moveItem(at: backupCache, to: cacheURL) }
                if fileManager.fileExists(atPath: backupMetadata.path) { try fileManager.moveItem(at: backupMetadata, to: metadataURL) }
                try synchronizeDirectory(directory)
                try fileManager.removeItem(at: transaction)
                try synchronizeDirectory(directory)
            } catch {
                // Keep the journal and backups for launch recovery. Removing them
                // here could discard the last complete cache pair.
                logger.error("Cache rollback needs recovery: \(error.localizedDescription)")
            }
            throw error
        }
    }

    private nonisolated static func recoverInterruptedCacheTransactions() {
        let directory = customEmbeddingsDir
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for transaction in items where transaction.lastPathComponent.hasPrefix(".cache-transaction-") {
            let journalURL = transaction.appendingPathComponent("journal.json")
            let journal: CacheCommitJournal? = {
                do {
                    let descriptor = try SecureFileAccess.openRegularFile(
                        journalURL, maximumSize: 1_048_576
                    )
                    defer { close(descriptor) }
                    let data = try SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: 1_048_576)
                    return try JSONDecoder().decode(CacheCommitJournal.self, from: data)
                } catch {
                    return nil
                }
            }()
            guard let journal,
                  journal.version == CacheCommitJournal.currentVersion,
                  Self.isSafeCacheLeaf(journal.cacheName), Self.isSafeCacheLeaf(journal.metadataName),
                  Self.cacheLeafNamesMatch(journal) else {
                quarantine(transaction, in: directory)
                continue
            }
            let cacheURL = directory.appendingPathComponent(journal.cacheName)
            let metadataURL = directory.appendingPathComponent(journal.metadataName)
            let backupCache = transaction.appendingPathComponent("cache.backup")
            let backupMetadata = transaction.appendingPathComponent("metadata.backup")
            do {
                if Self.isValidCachePair(cacheURL, metadataURL, expected: journal.metadata) {
                    // The new pair reached durable storage. Nothing needs rollback.
                } else if Self.isValidCachePair(backupCache, backupMetadata) {
                    try Self.restoreCachePair(
                        cache: backupCache, metadata: backupMetadata,
                        atCache: cacheURL, metadataURL: metadataURL, in: directory
                    )
                } else if Self.isValidCachePair(backupCache, metadataURL) {
                    // The old cache was moved first; the old metadata is still live.
                    try Self.restoreCachePair(
                        cache: backupCache, metadata: metadataURL,
                        atCache: cacheURL, metadataURL: metadataURL, in: directory
                    )
                } else if Self.isValidCachePair(cacheURL, backupMetadata) {
                    // The old metadata was moved after an earlier cache operation.
                    try Self.restoreCachePair(
                        cache: cacheURL, metadata: backupMetadata,
                        atCache: cacheURL, metadataURL: metadataURL, in: directory
                    )
                } else {
                    // Do not remove an incomplete transaction. It can contain the
                    // only recoverable copy after an interrupted filesystem update.
                    throw MatchingError.invalidEmbeddingsFile
                }
                try SecureFileAccess.synchronize(directory, directory: true)
                try FileManager.default.removeItem(at: transaction)
                try SecureFileAccess.synchronize(directory, directory: true)
            } catch {
                quarantine(transaction, in: directory)
            }
        }
        for stage in items where stage.lastPathComponent.hasPrefix(".") && stage.lastPathComponent.hasSuffix(".stage") {
            try? FileManager.default.removeItem(at: stage)
        }
    }

    private nonisolated static func quarantine(_ transaction: URL, in directory: URL) {
        let destination = directory.appendingPathComponent(".cache-quarantine-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.moveItem(at: transaction, to: destination)
            try SecureFileAccess.synchronize(directory, directory: true)
        } catch {
            logger.error("Could not quarantine interrupted cache transaction: \(error.localizedDescription)")
        }
    }

    private nonisolated static func isSafeCacheLeaf(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("..")
    }

    private nonisolated static func cacheLeafNamesMatch(_ journal: CacheCommitJournal) -> Bool {
        journal.cacheName == "\(journal.metadata.databaseID)_embeddings_\(journal.metadata.modelKey).bin" &&
        journal.metadataName == "\(journal.metadata.databaseID)_embeddings_\(journal.metadata.modelKey).json" &&
        CustomDatabase.isSafeStorageIdentifier(journal.metadata.databaseID) &&
        CustomDatabase.isSafeModelKey(journal.metadata.modelKey) &&
        isPlausibleCacheMetadata(journal.metadata) &&
        journal.metadata.sourceHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
        journal.metadata.schemaHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
        journal.metadata.rowOrderHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
        journal.metadata.modelArtifactFingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
        journal.metadata.embeddingDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    nonisolated static func expectedEmbeddingByteCount(entries: Int, dimensions: Int) throws -> Int {
        // Cache metadata is untrusted until validated. These bounds apply before
        // capacity calculation and descriptor reads so a journal cannot request a
        // multi-gigabyte allocation merely by naming large dimensions or rows.
        guard entries > 0, entries <= 1_000_000,
              dimensions > 0, dimensions <= 8_192 else {
            throw MatchingError.invalidEmbeddingsFile
        }
        let (values, overflowValues) = entries.multipliedReportingOverflow(by: dimensions)
        let (bytes, overflowBytes) = values.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !overflowValues, !overflowBytes, bytes <= 2 * 1_024 * 1_024 * 1_024 else {
            throw MatchingError.invalidEmbeddingsFile
        }
        return bytes
    }

    private nonisolated static func isPlausibleCacheMetadata(_ metadata: CustomDatabaseCacheMetadata) -> Bool {
        guard metadata.entryCount > 0, metadata.entryCount <= 1_000_000,
              metadata.embeddingDimensions > 0, metadata.embeddingDimensions <= 8_192,
              (try? expectedEmbeddingByteCount(
                entries: metadata.entryCount, dimensions: metadata.embeddingDimensions
              )) != nil else { return false }
        return true
    }

    private nonisolated static func restoreCachePair(
        cache sourceCache: URL,
        metadata sourceMetadata: URL,
        atCache destinationCache: URL,
        metadataURL destinationMetadata: URL,
        in directory: URL
    ) throws {
        // A source and destination can be the same live file. Only remove a
        // destination when it is a different inode/path than the verified source.
        let manager = FileManager.default
        if sourceCache.path != destinationCache.path, manager.fileExists(atPath: destinationCache.path) {
            try manager.removeItem(at: destinationCache)
        }
        if sourceMetadata.path != destinationMetadata.path, manager.fileExists(atPath: destinationMetadata.path) {
            try manager.removeItem(at: destinationMetadata)
        }
        if sourceCache.path != destinationCache.path {
            try manager.moveItem(at: sourceCache, to: destinationCache)
        }
        if sourceMetadata.path != destinationMetadata.path {
            try manager.moveItem(at: sourceMetadata, to: destinationMetadata)
        }
        guard isValidCachePair(destinationCache, destinationMetadata) else {
            throw MatchingError.invalidEmbeddingsFile
        }
        try SecureFileAccess.synchronize(directory, directory: true)
    }

    nonisolated static func isValidCachePair(
        _ cacheURL: URL, _ metadataURL: URL, expected: CustomDatabaseCacheMetadata? = nil
    ) -> Bool {
        do {
            let metadataDescriptor = try SecureFileAccess.openRegularFile(
                metadataURL, maximumSize: 1_048_576
            )
            defer { close(metadataDescriptor) }
            let metadataData = try SecureFileAccess.readBounded(descriptor: metadataDescriptor, maximumSize: 1_048_576)
            let metadata = try JSONDecoder().decode(CustomDatabaseCacheMetadata.self, from: metadataData)
            guard metadata.version == CustomDatabaseCacheMetadata.currentVersion,
                  CustomDatabase.isSafeStorageIdentifier(metadata.databaseID),
                  CustomDatabase.isSafeModelKey(metadata.modelKey),
                  isPlausibleCacheMetadata(metadata),
                  metadata.modelArtifactFingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  metadata.embeddingDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  expected.map({ metadata == $0 }) ?? true else { return false }
            let expectedBytes = try expectedEmbeddingByteCount(entries: metadata.entryCount, dimensions: metadata.embeddingDimensions)
            let cacheDescriptor = try SecureFileAccess.openRegularFile(
                cacheURL, maximumSize: Int64(expectedBytes)
            )
            defer { close(cacheDescriptor) }
            let cacheData = try SecureFileAccess.readBounded(descriptor: cacheDescriptor, maximumSize: expectedBytes)
            guard metadata.embeddingDigest == CustomDatabaseValidator.digest(cacheData),
                  cacheData.count == expectedBytes else { return false }
            return cacheData.withUnsafeBytes { $0.bindMemory(to: Float.self).allSatisfy(\.isFinite) }
        } catch {
            return false
        }
    }

    /// Load binary embeddings file as [[Float]] for legacy resource compatibility.
    private func loadBinaryEmbeddings(from url: URL, count: Int) throws -> [[Float]] {
        let data = try Data(contentsOf: url)
        let embeddingDim = embeddingModel?.info.dimensions ?? 1024
        let expectedSize = try Self.expectedEmbeddingByteCount(entries: count, dimensions: embeddingDim)

        guard data.count == expectedSize else {
            throw MatchingError.invalidEmbeddingsFile
        }

        guard data.withUnsafeBytes({ buffer in buffer.bindMemory(to: Float.self).allSatisfy(\.isFinite) }) else {
            throw MatchingError.invalidEmbeddingsFile
        }

        var embeddings: [[Float]] = []
        data.withUnsafeBytes { buffer in
            let floats = buffer.bindMemory(to: Float.self)
            for i in 0..<count {
                let start = i * embeddingDim
                let embedding = Array(floats[start..<(start + embeddingDim)])
                embeddings.append(embedding)
            }
        }

        return embeddings
    }

    /// Load binary embeddings directly into an MLXArray matrix.
    /// Skips the intermediate [[Float]] allocation -- loads Data once, hands it to MLX.
    /// The binary file format is contiguous Float32 values, row-major (count * embeddingDim floats).
    private func loadBinaryEmbeddingsAsMatrix(from url: URL, count: Int, embeddingDim: Int) throws -> MLXArray {
        let data = try Data(contentsOf: url)
        let expectedSize = try Self.expectedEmbeddingByteCount(entries: count, dimensions: embeddingDim)
        guard data.count == expectedSize else {
            throw MatchingError.invalidEmbeddingsFile
        }
        guard data.withUnsafeBytes({ buffer in buffer.bindMemory(to: Float.self).allSatisfy(\.isFinite) }) else {
            throw MatchingError.invalidEmbeddingsFile
        }
        return MLXArray(data, [count, embeddingDim], type: Float.self)
    }

    /// Load built-in database entries from CSV
    private func loadBuiltInDatabaseEntries(for database: BuiltInDatabase) async throws -> [DatabaseEntry] {
        guard let dbDir = ResourceBundle.databasesDirectory else {
            throw MatchingError.databaseNotFound
        }

        let url = dbDir.appendingPathComponent(database.csvFilename)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MatchingError.databaseNotFound
        }

        let rawContent = try String(contentsOf: url, encoding: .utf8)
        let content = CSVParser.stripBOM(rawContent)
        let records = try CSVParser.parseRecords(content: content, delimiter: ",")

        guard records.count > 1 else {
            throw MatchingError.emptyDatabase
        }

        // Parse based on database type
        var entries: [DatabaseEntry] = []

        // Parse header and normalize column names (trim whitespace/BOM remnants)
        let header = records[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let idIdx: Int
        if let idCol = database.idColumn?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard let idx = header.firstIndex(of: idCol) else {
                throw MatchingError.columnNotFound(idCol)
            }
            idIdx = idx
        } else {
            idIdx = 0
        }
        guard let textIdx = header.firstIndex(of: database.textColumn.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MatchingError.columnNotFound(database.textColumn)
        }

        for i in 1..<records.count {
            let values = records[i]
            guard values.count > max(idIdx, textIdx) else { continue }

            var additionalFields: [String: String] = [:]
            for (colIdx, colName) in header.enumerated() {
                if colIdx != idIdx && colIdx != textIdx && colIdx < values.count && !values[colIdx].isEmpty {
                    additionalFields[colName] = values[colIdx]
                }
            }

            let entry = DatabaseEntry(
                id: values[idIdx],
                text: values[textIdx],
                additionalFields: additionalFields
            )
            entries.append(entry)
        }

        return entries
    }

    /// Load custom database entries from CSV/TSV
    private func loadCustomDatabaseEntries(for database: CustomDatabase) async throws -> [DatabaseEntry] {
        try await validatedCustomDatabase(for: database).entries
    }

    private func validatedCustomDatabase(for database: CustomDatabase) async throws -> ValidatedCustomDatabase {
        guard let url = database.csvURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw MatchingError.databaseNotFound
        }
        return try CustomDatabaseValidator.load(url: url, textColumn: database.textColumn, idColumn: database.idColumn)
    }

    /// GPU matmul matching: O(batch) not O(batch * DB). Chunked with Memory.clearCache()
    /// between chunks to prevent GPU buffer buildup on large inputs.
    func match(
        inputs: [String],
        database: AnyDatabase,
        threshold: Double,
        batchSize: Int,
        embeddingBatchSize: Int = 48,
        chunkSize: Int = 2000,
        onProgress: @Sendable @escaping (Int) -> Void,
        onEmbedProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [MatchResult] {
        let runID = try beginRun()
        defer { finishRun(runID) }
        try checkRun(runID)

        // Ensure model is loaded
        try await loadModelIfNeeded()

        // Load database if needed
        try await loadDatabase(database, onEmbedProgress: onEmbedProgress)
        try checkRun(runID)

        guard let model = embeddingModel,
              let targetMatrix = targetEmbeddingMatrix else {
            throw MatchingError.modelNotLoaded
        }

        var results: [MatchResult] = []
        results.reserveCapacity(inputs.count)

        // Process in chunks with memory clearing between each chunk
        for chunkStart in stride(from: 0, to: inputs.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, inputs.count)

            // Process chunk in GPU batches
            for batchStart in stride(from: chunkStart, to: chunkEnd, by: batchSize) {
                // Check cancellation between batches
                try checkRun(runID)

                let batchEnd = min(batchStart + batchSize, chunkEnd)
                let batchInputs = Array(inputs[batchStart..<batchEnd])

                // 1. Embed batch -> MLXArray [batch, embeddingDim]
                // isQuery: true -- asymmetric models prepend instruction to input queries
                let inputMatrix = try await model.embedBatchAsMatrix(
                    batchInputs,
                    batchSize: embeddingBatchSize,
                    isQuery: true
                )

                // 2. GPU matrix multiplication for ALL similarities at once
                // [batch, 1024] @ [1024, N] = [batch, N]
                let scores = matmul(inputMatrix, targetMatrix.transposed())

                // 3. Find best match per row - GPU operations
                let bestIndices = scores.argMax(axis: 1)
                let bestScores = MLX.max(scores, axis: 1)

                // 4. Single eval() for all GPU operations in this batch
                eval(bestIndices, bestScores)

                // 5. Pull minimal results to CPU
                let indicesArray = bestIndices.asArray(Int32.self)
                let scoresArray = bestScores.asArray(Float.self)

                // 6. Build MatchResults (CPU work, very fast)
                for (localIndex, (idx, score)) in zip(indicesArray, scoresArray).enumerated() {
                    let globalIndex = batchStart + localIndex
                    let input = batchInputs[localIndex]
                    let targetID = targetIDs[Int(idx)]

                    guard let entry = targetEntries[targetID] else {
                        results.append(MatchResult(
                            inputText: input,
                            inputRow: globalIndex,
                            score: 0,
                            status: .error
                        ))
                        continue
                    }

                    let status: MatchStatus = score >= Float(threshold) ? .match : .noMatch
                    results.append(MatchResult(
                        inputText: input,
                        inputRow: globalIndex,
                        matchText: entry.text,
                        matchID: entry.id,
                        score: Double(score),
                        status: status,
                        matchAdditionalFields: entry.additionalFields
                    ))
                }

                // Report progress after each batch
                onProgress(batchEnd)
            }

            // Clear MLX memory between chunks to prevent GPU buffer accumulation
            Memory.clearCache()
        }

        return results
    }

    // MARK: - Top-K Matching (for reranker pipelines)

    /// Top-K match candidate returned from embedding-based retrieval
    struct TopKCandidate {
        let entry: DatabaseEntry
        let score: Float
    }

    /// Top-K retrieval for two-stage pipelines. Returns K best candidates per input,
    /// sorted by score descending.
    func matchTopK(
        inputs: [String],
        database: AnyDatabase,
        k: Int,
        batchSize: Int,
        embeddingBatchSize: Int = 48,
        chunkSize: Int = 2000,
        onProgress: @Sendable @escaping (Int) -> Void,
        onEmbedProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [[TopKCandidate]] {
        let runID = try beginRun()
        defer { finishRun(runID) }
        try checkRun(runID)

        // Ensure model is loaded
        try await loadModelIfNeeded()

        // Load database if needed
        try await loadDatabase(database, onEmbedProgress: onEmbedProgress)
        try checkRun(runID)

        guard let model = embeddingModel,
              let targetMatrix = targetEmbeddingMatrix else {
            throw MatchingError.modelNotLoaded
        }

        let dbSize = targetIDs.count
        let effectiveK = min(k, dbSize)

        var results: [[TopKCandidate]] = []
        results.reserveCapacity(inputs.count)

        for chunkStart in stride(from: 0, to: inputs.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, inputs.count)

            for batchStart in stride(from: chunkStart, to: chunkEnd, by: batchSize) {
                try checkRun(runID)

                let batchEnd = min(batchStart + batchSize, chunkEnd)
                let batchInputs = Array(inputs[batchStart..<batchEnd])

                // Embed batch -> [batch, embeddingDim]
                let inputMatrix = try await model.embedBatchAsMatrix(
                    batchInputs, batchSize: embeddingBatchSize, isQuery: true
                )

                // Similarity: [batch, N]
                let scores = matmul(inputMatrix, targetMatrix.transposed())

                // Partial sort via argPartition: O(N) vs O(N log N) for full argSort.
                let negated = -scores
                let partitioned = argPartition(negated, kth: effectiveK - 1, axis: 1)

                // Take top-K partition
                let topKPartition = partitioned[0..., 0..<effectiveK]
                let topKScoresUnsorted = takeAlong(scores, topKPartition, axis: 1)

                // Sort within the partition by descending score
                let negTopK = -topKScoresUnsorted
                let sortOrder = argSort(negTopK, axis: 1)
                let topKIndices = takeAlong(topKPartition, sortOrder, axis: 1)
                let topKScores = takeAlong(topKScoresUnsorted, sortOrder, axis: 1)

                eval(topKIndices, topKScores)

                // Pull to CPU
                let indicesFlat = topKIndices.asArray(Int32.self)
                let scoresFlat = topKScores.asArray(Float.self)
                let currentBatchSize = batchInputs.count

                for i in 0..<currentBatchSize {
                    var candidates: [TopKCandidate] = []
                    for j in 0..<effectiveK {
                        let flatIdx = i * effectiveK + j
                        let dbIdx = Int(indicesFlat[flatIdx])
                        let score = scoresFlat[flatIdx]
                        let targetID = targetIDs[dbIdx]
                        if let entry = targetEntries[targetID] {
                            candidates.append(TopKCandidate(entry: entry, score: score))
                        }
                    }
                    results.append(candidates)
                }

                onProgress(batchEnd)
            }

            Memory.clearCache()
        }

        return results
    }

    // MARK: - Pre-embedding Custom Databases

    /// Pre-embed a custom DB and stream to disk. Chunked with memory clearing
    /// so throughput stays consistent. Avoids embedding delay on first match.
    func embedCustomDatabase(
        _ database: CustomDatabase,
        batchSize: Int = 48,
        chunkSize: Int = 2000,
        onProgress: @Sendable @escaping (Int, Int) -> Void  // (completed, total)
    ) async throws {
        let runID = try beginRun()
        defer { finishRun(runID) }
        try checkRun(runID)

        // Ensure model is loaded
        try await loadModelIfNeeded()

        guard let model = embeddingModel else {
            throw MatchingError.modelNotLoaded
        }

        // Validate every row before a cache file is opened. This keeps progress and
        // embedding counts aligned with the rows that can be matched.
        let validated = try await validatedCustomDatabase(for: database)
        let entries = validated.entries

        guard !entries.isEmpty else {
            throw MatchingError.emptyDatabase
        }

        let totalCount = entries.count

        // Set up streaming file write (model-versioned path)
        let modelKey = currentModelKey ?? "gte-large"
        let embeddingsURL = database.cacheURL(for: modelKey)
        let metadataURL = database.cacheMetadataURL(for: modelKey)
        let metadata = try await customCacheMetadata(
            database: database,
            validated: validated,
            modelKey: modelKey,
            embeddingDimensions: model.info.dimensions
        )
        let stagingURL = embeddingsURL.deletingLastPathComponent()
            .appendingPathComponent(".\(embeddingsURL.lastPathComponent).\(UUID().uuidString).stage")
        let stagingDirectory = stagingURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory.path)
        let stagingDescriptor = try SecureFileAccess.createPrivateFile(stagingURL.lastPathComponent, in: stagingDirectory)
        let fileHandle = FileHandle(fileDescriptor: stagingDescriptor, closeOnDealloc: false)

        do {
            // Process in chunks to maintain consistent throughput
            for chunkStart in stride(from: 0, to: totalCount, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, totalCount)

                // Extract texts for this chunk only (don't hold all 50k strings)
                let chunkTexts = entries[chunkStart..<chunkEnd].map { $0.text }

                // Process chunk in GPU batches
                for batchStart in stride(from: 0, to: chunkTexts.count, by: batchSize) {
                    try checkRun(runID)

                    let batchEnd = min(batchStart + batchSize, chunkTexts.count)
                    let batch = Array(chunkTexts[batchStart..<batchEnd])

                    // Single-batch embedding (no internal accumulation)
                    // isQuery: false -- database entries are documents
                    let batchEmbeddings = try await model.embedBatchDirect(batch, isQuery: false)

                    // Stream directly to disk
                    guard batchEmbeddings.allSatisfy({ $0.count == model.info.dimensions && $0.allSatisfy(\.isFinite) }) else {
                        throw MatchingError.invalidEmbeddingsFile
                    }
                    for embedding in batchEmbeddings {
                        try checkRun(runID)
                        let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
                        try fileHandle.write(contentsOf: data)
                    }

                    // Report progress
                    let globalProgress = chunkStart + batchEnd
                    onProgress(globalProgress, totalCount)
                }

                // Clear MLX memory between chunks for consistent performance
                Memory.clearCache()
            }

            try fileHandle.close()
            try synchronizeFile(stagingURL)
            let expectedSize = try Self.expectedEmbeddingByteCount(entries: totalCount, dimensions: model.info.dimensions)
            let stagedSize = try stagingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard stagedSize == expectedSize else { throw MatchingError.invalidEmbeddingsFile }
            try checkRun(runID)
            let descriptor = try SecureFileAccess.openRegularFile(
                stagingURL, under: stagingURL.deletingLastPathComponent(), maximumSize: Int64(expectedSize)
            )
            defer { close(descriptor) }
            let stagedData = try SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: expectedSize) {
                Task.isCancelled
            }
            try checkRun(runID)
            let digest = CustomDatabaseValidator.digest(stagedData)
            try commitStagedCustomCache(
                stagingURL,
                metadata: metadata.withEmbeddingDigest(digest),
                cacheURL: embeddingsURL, metadataURL: metadataURL, runID: runID
            )
        } catch {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private func commitStagedCustomCache(
        _ stagingURL: URL,
        metadata: CustomDatabaseCacheMetadata,
        cacheURL: URL,
        metadataURL: URL,
        runID: UUID
    ) throws {
        let metadataStage = metadataURL.deletingLastPathComponent()
            .appendingPathComponent(".\(metadataURL.lastPathComponent).\(UUID().uuidString).stage")
        defer {
            try? FileManager.default.removeItem(at: metadataStage)
            try? FileManager.default.removeItem(at: stagingURL)
        }
        try checkRun(runID)
        try JSONEncoder().encode(metadata).write(to: metadataStage, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataStage.path)
        try synchronizeFile(metadataStage)
        _ = try decodeCacheMetadata(at: metadataStage)

        try checkRun(runID)
        try commitCacheTransaction(
            stagingURL, metadataStage, cacheURL: cacheURL, metadataURL: metadataURL,
            cancellationCheck: { try self.checkRun(runID) }
        )
        try checkRun(runID)
    }

    /// Cancel ongoing embedding or matching
    func cancel() {
        if let activeRunID { cancelledRunIDs.insert(activeRunID) }
    }
}

// MARK: - Errors

enum MatchingError: LocalizedError {
    case modelNotLoaded
    case databaseNotFound
    case emptyDatabase
    case invalidEmbeddingsFile
    case columnNotFound(String)
    case unknownModel(String)
    case databaseTooLarge(Int, Int)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Embedding model not loaded"
        case .databaseNotFound: return "Target database file not found"
        case .emptyDatabase: return "Target database is empty"
        case .invalidEmbeddingsFile: return "Pre-computed embeddings file is invalid"
        case .columnNotFound(let column): return "Column '\(column)' not found in database CSV"
        case .unknownModel(let key): return "Unknown embedding model: \(key)"
        case .databaseTooLarge(let count, let limit): return "Database has \(count) entries, but this pipeline supports a maximum of \(limit). Use a hybrid pipeline with embedding pre-filtering for larger databases."
        }
    }
}
