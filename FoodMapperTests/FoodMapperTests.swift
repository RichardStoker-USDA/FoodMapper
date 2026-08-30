import XCTest
@testable import FoodMapper

final class CSVParserTests: XCTestCase {
    private let csvURL = URL(fileURLWithPath: "/tmp/foodmapper-parser.csv")
    private let tsvURL = URL(fileURLWithPath: "/tmp/foodmapper-parser.tsv")

    func testQuotedCommasAndEscapedQuotes() throws {
        let input = "id,description\n1,\"Bread, whole wheat\"\n2,\"Chef \"\"special\"\" soup\"\n"
        let file = try CSVParser.parse(content: input, url: csvURL)

        XCTAssertEqual(file.rowCount, 2)
        XCTAssertEqual(file.rows[0]["description"], "Bread, whole wheat")
        XCTAssertEqual(file.rows[1]["description"], "Chef \"special\" soup")
    }

    func testQuotedNewlineAndCRLF() throws {
        let input = "id,description\r\n1,\"Line one\r\nLine two\"\r\n2,Milk\r\n"
        let file = try CSVParser.parse(content: input, url: csvURL)

        XCTAssertEqual(file.rowCount, 2)
        XCTAssertEqual(file.rows[0]["description"], "Line one\nLine two")
        XCTAssertEqual(file.rows[1]["description"], "Milk")
    }

    func testTSVDetectionIgnoresCommaInsideQuotedField() throws {
        let input = "id\tdescription\n1\t\"Bread, whole wheat\"\n"
        let file = try CSVParser.parse(content: input, url: tsvURL)

        XCTAssertEqual(file.format, .tsv)
        XCTAssertEqual(file.rows[0]["description"], "Bread, whole wheat")
    }

    func testMissingTrailingFieldsBecomeEmptyValues() throws {
        let input = "id,description,note\n1,Milk\n"
        let file = try CSVParser.parse(content: input, url: csvURL)

        XCTAssertEqual(file.rows[0]["note"], "")
    }

    func testDuplicateHeadersAreRejectedCaseInsensitively() {
        let input = "id,Description,description\n1,Milk,Milk\n"

        XCTAssertThrowsError(try CSVParser.parse(content: input, url: csvURL)) { error in
            guard case CSVParseError.duplicateColumns(let names) = error else {
                return XCTFail("Expected duplicateColumns, got \(error)")
            }
            XCTAssertEqual(names, ["Description"])
        }
    }

    func testExtraFieldsAreRejected() {
        let input = "id,description\n1,Milk,unexpected\n"

        XCTAssertThrowsError(try CSVParser.parse(content: input, url: csvURL)) { error in
            XCTAssertEqual(
                error as? CSVParseError,
                .tooManyFields(row: 2, expected: 2, actual: 3)
            )
        }
    }

    func testUnterminatedQuoteIsRejected() {
        let input = "id,description\n1,\"Milk\n"

        XCTAssertThrowsError(try CSVParser.parse(content: input, url: csvURL)) { error in
            XCTAssertEqual(error as? CSVParseError, .unterminatedQuotedField)
        }
    }

    func testNonWhitespaceAfterClosingQuoteIsRejected() {
        let input = "id,description\n1,\"Milk\"unexpected\n"

        XCTAssertThrowsError(try CSVParser.parse(content: input, url: csvURL)) { error in
            XCTAssertEqual(error as? CSVParseError, .unexpectedCharacterAfterClosingQuote("u"))
        }
    }

    func testUTF8BOMIsRemovedFromHeader() throws {
        let input = "\u{FEFF}id,description\n1,Milk\n"
        let file = try CSVParser.parse(content: input, url: csvURL)

        XCTAssertEqual(file.columns, ["id", "description"])
    }

    func testRowEstimateHandlesUTF8ScalarSplitAtSampleBoundary() throws {
        let header = "id,description\n"
        let rowPrefix = "1,"
        let asciiCount = 65_535 - header.utf8.count - rowPrefix.utf8.count
        let input = header + rowPrefix + String(repeating: "a", count: asciiCount) + "🥕\n2,Milk\n"
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foodmapper-parser-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        try input.write(to: temporaryURL, atomically: true, encoding: .utf8)
        let estimate = try CSVParser.estimateRowCount(url: temporaryURL)

        XCTAssertFalse(estimate.isExact)
        XCTAssertGreaterThan(estimate.estimatedRowCount, 0)
    }
}

final class HaikuBatchSubmissionTests: XCTestCase {
    func testV1SkipsSubmissionWhenAllCandidatesAreBelowTheFloor() {
        XCTAssertFalse(HaikuBatchSubmission.shouldSubmit(taskCount: 0))
    }

    func testV2SkipsSubmissionWhenAllCandidatesAreBelowTheFloor() {
        XCTAssertFalse(HaikuBatchSubmission.shouldSubmit(taskCount: 0))
    }

    func testSubmitsQualifiedCandidates() {
        XCTAssertTrue(HaikuBatchSubmission.shouldSubmit(taskCount: 1))
    }
}

final class CustomDatabaseValidationTests: XCTestCase {
    private var isolatedApplicationSupport: URL!

    override func setUpWithError() throws {
        isolatedApplicationSupport = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-app-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedApplicationSupport, withIntermediateDirectories: true)
        FoodMapperStorage.applicationSupportOverride = isolatedApplicationSupport
    }

    override func tearDownWithError() throws {
        FoodMapperStorage.applicationSupportOverride = nil
        try? FileManager.default.removeItem(at: isolatedApplicationSupport)
    }
    private func writeDatabase(_ content: String, extension fileExtension: String = "csv") throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-database-\(UUID().uuidString).\(fileExtension)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRejectsDuplicateAndBlankIDs() throws {
        let duplicate = try writeDatabase("id,description\n1,Milk\n1,Cheese\n")
        defer { try? FileManager.default.removeItem(at: duplicate) }
        XCTAssertThrowsError(try CustomDatabaseValidator.load(url: duplicate, textColumn: "description", idColumn: "id")) { error in
            XCTAssertEqual(error as? CustomDatabaseValidationError, .duplicateID(id: "1", firstRow: 2, duplicateRow: 3))
        }

        let blank = try writeDatabase("id,description\n ,Milk\n")
        defer { try? FileManager.default.removeItem(at: blank) }
        XCTAssertThrowsError(try CustomDatabaseValidator.load(url: blank, textColumn: "description", idColumn: "id")) { error in
            XCTAssertEqual(error as? CustomDatabaseValidationError, .blankID(row: 2, column: "id"))
        }
    }

    func testValidatesTSVRowsAndGeneratesIDsWithoutAnIDColumn() throws {
        let url = try writeDatabase("description\tnote\nMilk\tfresh\nCheese\taged\n", extension: "tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        let validated = try CustomDatabaseValidator.load(url: url, textColumn: "description", idColumn: nil)
        XCTAssertEqual(validated.entries.map(\.id).count, 2)
        XCTAssertTrue(validated.entries.allSatisfy { $0.id.hasPrefix("row-") })
        XCTAssertEqual(validated.entries.map(\.text), ["Milk", "Cheese"])
    }

    func testContentDerivedIDsSurviveUnrelatedRowReordering() throws {
        let first = try writeDatabase("description,note\nMilk,fresh\nCheese,aged\nMilk,whole\n")
        let second = try writeDatabase("description,note\nMilk,whole\nMilk,fresh\nCheese,aged\n")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let left = try CustomDatabaseValidator.load(url: first, textColumn: "description", idColumn: nil)
        let right = try CustomDatabaseValidator.load(url: second, textColumn: "description", idColumn: nil)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: left.entries.map { ($0.additionalFields["note"]!, $0.id) }),
            Dictionary(uniqueKeysWithValues: right.entries.map { ($0.additionalFields["note"]!, $0.id) })
        )
    }

    func testIdenticalRowsUseContentIdentityAndDuplicateOrdinalMetadata() throws {
        let url = try writeDatabase("description,note\nMilk,whole\nMilk,whole\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let validated = try CustomDatabaseValidator.load(url: url, textColumn: "description", idColumn: nil)
        XCTAssertEqual(validated.entries.map(\.id), [validated.entries[0].id, validated.entries[0].id])
        XCTAssertEqual(validated.entries.map { $0.additionalFields["FoodMapper duplicate ordinal"] }, ["1", "2"])
    }

    func testRejectsSymbolicAndHardLinkedSources() throws {
        let source = try writeDatabase("id,description\n1,Milk\n")
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let symbolic = temporaryDirectory.appendingPathComponent("foodmapper-symbolic-\(UUID().uuidString).csv")
        let hard = temporaryDirectory.appendingPathComponent("foodmapper-hard-\(UUID().uuidString).csv")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: symbolic)
            try? FileManager.default.removeItem(at: hard)
        }
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: source)
        XCTAssertThrowsError(try CustomDatabaseValidator.load(url: symbolic, textColumn: "description", idColumn: "id"))
        XCTAssertEqual(link(source.path, hard.path), 0)
        XCTAssertThrowsError(try CustomDatabaseValidator.load(url: hard, textColumn: "description", idColumn: "id"))
    }

    func testBoundedDescriptorReadRejectsGrowthBeyondLimit() throws {
        let url = try writeDatabase("12345")
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = try SecureFileAccess.openRegularFile(url, maximumSize: 5)
        defer { close(descriptor) }
        XCTAssertThrowsError(try SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: 4))
    }

    func testRejectsSymlinkedStorageRoot() throws {
        let physicalRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-root-\(UUID().uuidString)", isDirectory: true)
        let linkedRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-link-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: linkedRoot)
            try? FileManager.default.removeItem(at: physicalRoot)
        }
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: physicalRoot.path)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: physicalRoot)
        let file = physicalRoot.appendingPathComponent("data.csv")
        try "id,description\n1,Milk\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        XCTAssertThrowsError(try SecureFileAccess.openRegularFile(
            linkedRoot.appendingPathComponent("data.csv"), under: linkedRoot
        ))
    }

    func testRejectsMalformedAndBlankTextRows() throws {
        let malformed = try writeDatabase("id,description\n1\n")
        defer { try? FileManager.default.removeItem(at: malformed) }
        XCTAssertThrowsError(try CustomDatabaseValidator.load(url: malformed, textColumn: "description", idColumn: "id")) { error in
            XCTAssertEqual(error as? CustomDatabaseValidationError, .malformedRow(row: 2, expected: 2, actual: 1))
        }

        let blank = try writeDatabase("id,description\n1,   \n")
        defer { try? FileManager.default.removeItem(at: blank) }
        XCTAssertThrowsError(try CustomDatabaseValidator.load(url: blank, textColumn: "description", idColumn: "id")) { error in
            XCTAssertEqual(error as? CustomDatabaseValidationError, .blankText(row: 2, column: "description"))
        }

        let duplicateHeaders = try writeDatabase("id,ID,description\n1,1,Milk\n")
        defer { try? FileManager.default.removeItem(at: duplicateHeaders) }
        XCTAssertThrowsError(try CustomDatabaseValidator.load(url: duplicateHeaders, textColumn: "description", idColumn: "id")) { error in
            XCTAssertEqual(error as? CustomDatabaseValidationError, .duplicateHeader("ID"))
        }
    }

    func testRowOrderChangesCacheFingerprint() throws {
        let first = try writeDatabase("id,description\n1,Milk\n2,Cheese\n")
        let second = try writeDatabase("id,description\n2,Cheese\n1,Milk\n")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let left = try CustomDatabaseValidator.load(url: first, textColumn: "description", idColumn: "id")
        let right = try CustomDatabaseValidator.load(url: second, textColumn: "description", idColumn: "id")
        XCTAssertNotEqual(left.sourceHash, right.sourceHash)
        XCTAssertNotEqual(left.rowOrderHash, right.rowOrderHash)
    }

    func testCacheRecoveryRestoresLastGoodPairAfterInterruptedCommit() async throws {
        let directory = isolatedApplicationSupport.appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let cacheName = "database_embeddings_model.bin"
        let metadataName = "database_embeddings_model.json"
        let transaction = directory.appendingPathComponent(".cache-transaction-test", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        let values: [Float] = [1, 2]
        let cacheData = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let metadata = CustomDatabaseCacheMetadata(
            version: 1, databaseID: "database", sourceHash: String(repeating: "b", count: 64),
            schemaHash: String(repeating: "c", count: 64), rowOrderHash: String(repeating: "d", count: 64),
            textColumn: "description", idColumn: "id", modelKey: "model", modelArtifactFingerprint: String(repeating: "a", count: 64),
            entryCount: 1, embeddingDimensions: 2, embeddingDigest: CustomDatabaseValidator.digest(cacheData)
        )
        try cacheData.write(to: transaction.appendingPathComponent("cache.backup"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.appendingPathComponent("cache.backup").path)
        try JSONEncoder().encode(metadata).write(to: transaction.appendingPathComponent("metadata.backup"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.appendingPathComponent("metadata.backup").path)
        try JSONEncoder().encode(CacheCommitJournal(cacheName: cacheName, metadataName: metadataName, metadata: metadata))
            .write(to: transaction.appendingPathComponent("journal.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.appendingPathComponent("journal.json").path)
        XCTAssertTrue(MatchingEngine.isValidCachePair(
            transaction.appendingPathComponent("cache.backup"),
            transaction.appendingPathComponent("metadata.backup"), expected: metadata
        ))
        try Data([0]).write(to: directory.appendingPathComponent(cacheName))

        _ = try await MatchingEngine()

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(cacheName)), cacheData)
        XCTAssertEqual(try JSONDecoder().decode(CustomDatabaseCacheMetadata.self, from: Data(contentsOf: directory.appendingPathComponent(metadataName))), metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testCacheRecoveryRestoresWhenOnlyCacheBackupRemains() async throws {
        let directory = isolatedApplicationSupport.appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let cacheName = "database_embeddings_model.bin"
        let metadataName = "database_embeddings_model.json"
        let transaction = directory.appendingPathComponent(".cache-transaction-cache-only", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        let data = [Float(1), 2].withUnsafeBufferPointer { Data(buffer: $0) }
        let metadata = CustomDatabaseCacheMetadata(
            version: 1, databaseID: "database", sourceHash: String(repeating: "b", count: 64),
            schemaHash: String(repeating: "c", count: 64), rowOrderHash: String(repeating: "d", count: 64),
            textColumn: "description", idColumn: "id", modelKey: "model",
            modelArtifactFingerprint: String(repeating: "a", count: 64), entryCount: 1,
            embeddingDimensions: 2, embeddingDigest: CustomDatabaseValidator.digest(data)
        )
        try data.write(to: transaction.appendingPathComponent("cache.backup"))
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent(metadataName))
        try Data([0]).write(to: directory.appendingPathComponent(cacheName))
        try JSONEncoder().encode(CacheCommitJournal(cacheName: cacheName, metadataName: metadataName, metadata: metadata))
            .write(to: transaction.appendingPathComponent("journal.json"))
        for url in [transaction.appendingPathComponent("cache.backup"), directory.appendingPathComponent(metadataName), directory.appendingPathComponent(cacheName), transaction.appendingPathComponent("journal.json")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        _ = try await MatchingEngine()

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(cacheName)), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testCacheRecoveryRestoresWhenOnlyMetadataBackupRemains() async throws {
        let directory = isolatedApplicationSupport.appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let cacheName = "database_embeddings_model.bin"
        let metadataName = "database_embeddings_model.json"
        let transaction = directory.appendingPathComponent(".cache-transaction-metadata-only", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        let data = [Float(1), 2].withUnsafeBufferPointer { Data(buffer: $0) }
        let metadata = CustomDatabaseCacheMetadata(
            version: 1, databaseID: "database", sourceHash: String(repeating: "b", count: 64),
            schemaHash: String(repeating: "c", count: 64), rowOrderHash: String(repeating: "d", count: 64),
            textColumn: "description", idColumn: "id", modelKey: "model",
            modelArtifactFingerprint: String(repeating: "a", count: 64), entryCount: 1,
            embeddingDimensions: 2, embeddingDigest: CustomDatabaseValidator.digest(data)
        )
        try data.write(to: directory.appendingPathComponent(cacheName))
        try JSONEncoder().encode(metadata).write(to: transaction.appendingPathComponent("metadata.backup"))
        try Data([0]).write(to: directory.appendingPathComponent(metadataName))
        try JSONEncoder().encode(CacheCommitJournal(cacheName: cacheName, metadataName: metadataName, metadata: metadata))
            .write(to: transaction.appendingPathComponent("journal.json"))
        for url in [directory.appendingPathComponent(cacheName), transaction.appendingPathComponent("metadata.backup"), directory.appendingPathComponent(metadataName), transaction.appendingPathComponent("journal.json")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        _ = try await MatchingEngine()

        XCTAssertEqual(try JSONDecoder().decode(
            CustomDatabaseCacheMetadata.self,
            from: Data(contentsOf: directory.appendingPathComponent(metadataName))
        ), metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testGiantCacheJournalIsQuarantinedBeforeReadingCache() async throws {
        let directory = isolatedApplicationSupport.appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let transaction = directory.appendingPathComponent(".cache-transaction-giant", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        let metadata = CustomDatabaseCacheMetadata(
            version: 1, databaseID: "database", sourceHash: String(repeating: "b", count: 64),
            schemaHash: String(repeating: "c", count: 64), rowOrderHash: String(repeating: "d", count: 64),
            textColumn: "description", idColumn: nil, modelKey: "model",
            modelArtifactFingerprint: String(repeating: "a", count: 64), entryCount: 1_000_001,
            embeddingDimensions: 8_192, embeddingDigest: String(repeating: "d", count: 64)
        )
        try JSONEncoder().encode(CacheCommitJournal(
            cacheName: "database_embeddings_model.bin", metadataName: "database_embeddings_model.json", metadata: metadata
        )).write(to: transaction.appendingPathComponent("journal.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transaction.appendingPathComponent("journal.json").path)

        _ = try await MatchingEngine()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix(".cache-quarantine-") })
    }

    func testCacheValidationRejectsNonFiniteValues() throws {
        let database = CustomDatabase(
            id: "database", displayName: "Database", csvPath: "", textColumn: "description",
            itemCount: 1
        )
        let directory = database.cacheDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try "id,description\n1,Milk\n".write(to: database.storedCsvURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.storedCsvURL.path)
        let floats = Array(repeating: Float.nan, count: 1024)
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: database.cacheURL(for: "gte-large"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.cacheURL(for: "gte-large").path)
        let validated = try CustomDatabaseValidator.load(url: database.storedCsvURL, textColumn: "description", idColumn: nil)
        let metadata = CustomDatabaseCacheMetadata(
            version: CustomDatabaseCacheMetadata.currentVersion, databaseID: database.id,
            sourceHash: validated.sourceHash, schemaHash: validated.schemaHash, rowOrderHash: validated.rowOrderHash,
            textColumn: "description", idColumn: nil, modelKey: "gte-large",
            modelArtifactFingerprint: String(repeating: "a", count: 64), entryCount: 1,
            embeddingDimensions: 1024, embeddingDigest: CustomDatabaseValidator.digest(data)
        )
        try JSONEncoder().encode(metadata).write(to: database.cacheMetadataURL(for: "gte-large"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.cacheMetadataURL(for: "gte-large").path)
        XCTAssertFalse(database.hasEmbeddings(for: "gte-large"))
    }
}

final class ModelSnapshotTests: XCTestCase {
    func testTrackedQwenTrustManifestIsBundledAndComplete() throws {
        let url = try XCTUnwrap(ResourceBundle.bundle.url(
            forResource: "qwen_snapshot_manifest", withExtension: "json", subdirectory: "Models"
        ))
        let manifest = try JSONDecoder().decode(TrustedQwenSnapshotManifest.self, from: Data(contentsOf: url))
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.models.count, 7)
        XCTAssertEqual(manifest.models.flatMap(\.artifacts).count, 63)
        XCTAssertTrue(manifest.models.allSatisfy { !$0.revision.contains("main") })
        XCTAssertTrue(manifest.models.flatMap(\.artifacts).allSatisfy {
            !$0.path.hasPrefix("/") && !$0.path.contains("..") && $0.byteSize > 0 &&
            $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && !$0.roles.isEmpty
        })
    }

    func testPartialSnapshotIsNotInstalled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foodmapper-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        XCTAssertFalse(ModelDownloader.isCompleteSnapshot(at: directory))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data(repeating: 0, count: 2048).write(to: directory.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(ModelDownloader.isCompleteSnapshot(at: directory))
        let artifacts = ["config.json", "tokenizer.json", "model.safetensors"].reduce(into: [String: String]()) { hashes, path in
            hashes[path] = CustomDatabaseValidator.digest(try! Data(contentsOf: directory.appendingPathComponent(path)))
        }
        let manifest = LocalModelSnapshotManifest(version: 1, repository: "test/model", revision: "main", artifacts: artifacts)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("foodmapper_snapshot_manifest.json"))
        XCTAssertFalse(ModelDownloader.isCompleteSnapshot(at: directory, repository: "test/model"))
        XCTAssertFalse(ModelDownloader.isCompleteSnapshot(at: directory, repository: "test/model", revision: "pinned-commit"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("config.json"))
        XCTAssertFalse(ModelDownloader.isCompleteSnapshot(at: directory))
    }

    func testStorageIdentifiersRejectTraversalAndAbsolutePaths() {
        XCTAssertTrue(CustomDatabase.isSafeStorageIdentifier("A1_b-c"))
        XCTAssertFalse(CustomDatabase.isSafeStorageIdentifier("../../outside"))
        XCTAssertFalse(CustomDatabase.isSafeStorageIdentifier("/tmp/outside"))
        XCTAssertFalse(CustomDatabase.isSafeModelKey("../../outside"))
        XCTAssertFalse(CustomDatabase.isSafeModelKey("model/key"))
    }
}

@MainActor
final class DatabaseOperationAdmissionTests: XCTestCase {
    private var isolatedApplicationSupport: URL!

    override func setUpWithError() throws {
        isolatedApplicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("foodmapper-operation-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedApplicationSupport, withIntermediateDirectories: true)
        FoodMapperStorage.applicationSupportOverride = isolatedApplicationSupport
    }

    override func tearDownWithError() throws {
        FoodMapperStorage.applicationSupportOverride = nil
        try? FileManager.default.removeItem(at: isolatedApplicationSupport)
    }

    func testMatchingAndDatabaseOperationsSerializeByGeneration() {
        let state = AppState()
        let matching = UUID()
        let embedding = UUID()
        XCTAssertTrue(state.beginEngineOperation(.matching(matching)))
        XCTAssertFalse(state.beginEngineOperation(.databaseEmbedding(embedding, "database")))
        state.finishEngineOperation(embedding)
        XCTAssertTrue(state.isCurrentEngineOperation(matching))
        state.finishEngineOperation(matching)
        XCTAssertTrue(state.beginEngineOperation(.databaseEmbedding(embedding, "database")))
        XCTAssertFalse(state.canModifyDatabases)
        state.finishEngineOperation(embedding)
        XCTAssertTrue(state.canModifyDatabases)
    }

    func testResearchAndSessionOperationsUseTheSameAdmissionGate() {
        let state = AppState()
        let tour = UUID()
        let restore = UUID()
        let removal = UUID()
        XCTAssertTrue(state.beginEngineOperation(.researchTour(tour)))
        XCTAssertFalse(state.beginEngineOperation(.sessionRestore(restore)))
        XCTAssertFalse(state.beginEngineOperation(.databaseRemoval(removal, "database")))
        state.finishEngineOperation(tour)
        XCTAssertTrue(state.beginEngineOperation(.sessionRestore(restore)))
        state.finishEngineOperation(restore)
    }

    func testCancellingEmbeddingReleasesTheOperationLease() async throws {
        let state = AppState()
        let operation = UUID()
        XCTAssertTrue(state.beginEngineOperation(.databaseEmbedding(operation, "database")))
        state.embeddingTask = Task {
            try? await Task.sleep(for: .seconds(5))
        }
        state.cancelEmbedding()
        for _ in 0..<20 where state.activeEngineOperation != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(state.activeEngineOperation)
        XCTAssertNil(state.embeddingTask)
    }
}
