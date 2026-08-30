import XCTest
import CryptoKit
@testable import FoodMapper

private extension XCTestCase {
    var isolatedApplicationSupport: URL { FoodMapperStorage.applicationSupportURL }
}

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

final class TargetSnapshotTests: XCTestCase {
    override func setUpWithError() throws {
        try FoodMapperStorage.bootstrap()
    }

    private func sourceURL(_ content: String) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-snapshot-\(UUID().uuidString).csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func testFullTargetSearchFindsBroccoliRowsOutsideRetrievedCandidates() async throws {
        let source = try sourceURL(
            "code,description,energy\n" +
            "72302000,Broccoli soup,44\n" +
            "72302100,\"Broccoli cheese soup, prepared with milk\",61\n" +
            "72302100,\"Broccoli cheese soup, prepared with milk\",62\n"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source,
            databaseIdentity: "custom_fndds",
            displayName: "FNDDS",
            sourceKind: .custom,
            textColumn: "description",
            idColumn: "code",
            selectedFields: ["energy"],
            requireSourceOwner: true
        )

        let results = try await store.search(
            reference: snapshot.reference,
            query: "Broccoli cheese soup, prepared with milk"
        )
        XCTAssertEqual(results.map(\.kind), [.exactDescription, .exactDescription])
        XCTAssertEqual(results.prefix(2).map(\.matchID), ["72302100", "72302100"])
        XCTAssertEqual(results.first?.selection.fields["energy"], "61")
        XCTAssertEqual(results.first?.selection.snapshotDigest, snapshot.reference.digest)
    }

    func testSearchRankingNormalizesUnicodeAndKeepsSourceOrder() async throws {
        let source = try sourceURL(
            "id,description\n1,Café au lait\n2,cafe beans\n3,iced café au lait\n"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "custom_unicode", displayName: "Unicode",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let results = try await store.search(reference: snapshot.reference, query: "CAFE AU LAIT")
        XCTAssertEqual(results.first?.kind, .exactDescription)
        XCTAssertEqual(results.first?.matchID, "1")
        XCTAssertEqual(results.last?.kind, .allTokens)
        XCTAssertEqual(results.last?.matchID, "3")
    }

    func testCaptureDeduplicatesByExactSourceDigest() async throws {
        let source = try sourceURL("id,description\n1,Milk\n")
        defer { try? FileManager.default.removeItem(at: source) }
        let store = TargetSnapshotStore()
        let first = try await store.capture(
            sourceURL: source, databaseIdentity: "custom_same", displayName: "Same",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let second = try await store.capture(
            sourceURL: source, databaseIdentity: "custom_same", displayName: "Same",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        XCTAssertEqual(first.reference.digest, second.reference.digest)
        XCTAssertEqual(first.manifest.rowCount, 1)
    }

    func testSnapshotIdentityBindsSourceAndMatchingPolicy() async throws {
        let source = try sourceURL("id,description,alternate\n1,Milk,Whole milk\n")
        defer { try? FileManager.default.removeItem(at: source) }
        let store = TargetSnapshotStore()
        let first = try await store.capture(
            sourceURL: source, databaseIdentity: "target-a", displayName: "Target A",
            sourceKind: .custom, textColumn: "description", idColumn: "id",
            selectedFields: ["description"], requireSourceOwner: true
        )
        let second = try await store.capture(
            sourceURL: source, databaseIdentity: "target-b", displayName: "Target B",
            sourceKind: .custom, textColumn: "alternate", idColumn: "id",
            selectedFields: ["alternate"], requireSourceOwner: true
        )
        XCTAssertEqual(first.reference.sourceDigest, second.reference.sourceDigest)
        XCTAssertNotEqual(first.reference.digest, second.reference.digest)
    }

    func testSnapshotParserMatchesBlankAndPostQuoteWhitespaceRules() async throws {
        let source = try sourceURL("id,description\n\n1,\"Broccoli soup\"   \n \n2,\"Milk\" \n")
        defer { try? FileManager.default.removeItem(at: source) }
        let input = try CSVParser.parse(content: String(contentsOf: source), url: source)
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "parser", displayName: "Parser",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        XCTAssertEqual(snapshot.manifest.rowCount, input.rowCount)
        XCTAssertEqual(try await store.search(reference: snapshot.reference, query: "broccoli soup").first?.matchID, "1")
    }

    func testManualSelectionBindsDuplicateIDToExactSnapshotRow() async throws {
        let source = try sourceURL("id,description,energy\n9,Broccoli soup,44\n9,Broccoli soup,61\n")
        defer { try? FileManager.default.removeItem(at: source) }
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "duplicate-id", displayName: "Duplicate ID",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let rows = try await store.search(reference: snapshot.reference, query: "broccoli soup")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].matchID, rows[1].matchID)
        XCTAssertNotEqual(rows[0].selection.sourceRow, rows[1].selection.sourceRow)
        XCTAssertNotEqual(rows[0].selection.fields, rows[1].selection.fields)
        try await store.validate(selection: rows[1].selection, reference: snapshot.reference)

        var fabricated = rows[1].selection
        fabricated = TargetSnapshotSelection(
            snapshotDigest: fabricated.snapshotDigest,
            sourceRow: fabricated.sourceRow,
            matchText: fabricated.matchText,
            matchID: fabricated.matchID,
            fields: ["id": "9", "description": "Broccoli soup", "energy": "999"]
        )
        await XCTAssertThrowsErrorAsync {
            try await store.validate(selection: fabricated, reference: snapshot.reference)
        }

        let otherSnapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "duplicate-id-other", displayName: "Duplicate ID Other",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        await XCTAssertThrowsErrorAsync {
            try await store.validate(selection: rows[1].selection, reference: otherSnapshot.reference)
        }
    }

    func testExportUsesReviewedCandidateIndexForDuplicateIDs() {
        let first = MatchCandidate(matchText: "Broccoli soup", matchID: "9", score: 0.8, additionalFields: ["energy": "44"])
        let second = MatchCandidate(matchText: "Broccoli soup", matchID: "9", score: 0.7, additionalFields: ["energy": "61"])
        let result = MatchResult(
            inputText: "broccoli soup", inputRow: 0, matchText: first.matchText, matchID: first.matchID,
            score: first.score, status: .match, matchAdditionalFields: first.additionalFields,
            candidates: [first, second]
        )
        let decision = ReviewDecision(
            status: .overridden, overrideMatchText: second.matchText, overrideMatchID: second.matchID,
            overrideScore: second.score, note: nil, reviewedAt: nil, selectedCandidateIndex: 1
        )
        let csv = CSVExporter.export(
            results: [result], pipelineName: "Test", selectedColumn: "input",
            targetTextColumn: "description", targetIdColumn: "id",
            targetColumnNames: ["id", "description", "energy"], reviewDecisions: [result.id: decision]
        )
        XCTAssertTrue(csv.contains("9,Broccoli soup,61"))
        XCTAssertFalse(csv.contains("9,Broccoli soup,44"))
    }

    func testRetentionKeepsReferencedSnapshotsAndRemovesUnreferenced() async throws {
        let source = try sourceURL("id,description\n1,Milk\n")
        let root = FoodMapperStorage.privateDirectory(["TargetSnapshots", "retention-\(UUID().uuidString)"])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        let store = TargetSnapshotStore(root: root)
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "retention", displayName: "Retention",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        try await store.reconcile(retaining: [snapshot.reference])
        XCTAssertEqual(try await store.search(reference: snapshot.reference, query: "milk").count, 1)
        try await store.reconcile(retaining: [])
        await XCTAssertThrowsErrorAsync {
            _ = try await store.search(reference: snapshot.reference, query: "milk")
        }
    }

    func testSnapshotRejectsMalformedRowsAndSymbolicSources() async throws {
        let malformed = try sourceURL("id,description\n1,Milk,extra\n")
        let symbolic = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-snapshot-link-\(UUID().uuidString).csv")
        defer {
            try? FileManager.default.removeItem(at: malformed)
            try? FileManager.default.removeItem(at: symbolic)
        }
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: malformed)
        let store = TargetSnapshotStore()
        await XCTAssertThrowsErrorAsync {
            _ = try await store.capture(
                sourceURL: malformed, databaseIdentity: "bad", displayName: "Bad", sourceKind: .custom,
                textColumn: "description", idColumn: "id", requireSourceOwner: true
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await store.capture(
                sourceURL: symbolic, databaseIdentity: "link", displayName: "Link", sourceKind: .custom,
                textColumn: "description", idColumn: "id", requireSourceOwner: true
            )
        }
    }

    func testStaleAndCorruptSnapshotsDoNotReturnRows() async throws {
        let source = try sourceURL("id,description\n1,Milk\n")
        defer { try? FileManager.default.removeItem(at: source) }
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "custom_integrity", displayName: "Integrity",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let snapshotRoot = FoodMapperStorage.privateDirectory(["TargetSnapshots", snapshot.reference.digest])
        let snapshotSource = snapshotRoot.appendingPathComponent(TargetSnapshotStore.sourceFilename)
        try "id,description\n1,Changed\n".write(to: snapshotSource, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotSource.path)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.search(reference: snapshot.reference, query: "milk")
        }
        let stale = TargetSnapshotReference(
            digest: String(repeating: "a", count: 64), databaseIdentity: "missing",
            displayName: "Missing", sourceKind: .custom
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await store.search(reference: stale, query: "milk")
        }
    }

    func testLegacySessionDecodesWithoutSnapshot() throws {
        let payload = """
        {"id":"00000000-0000-0000-0000-000000000001","inputFileName":"input.csv","databaseName":"Target","threshold":0.5,"totalCount":1,"matchedCount":1,"resultsFilename":"00000000-0000-0000-0000-000000000001.json","date":0}
        """
        let session = try JSONDecoder().decode(MatchingSession.self, from: Data(payload.utf8))
        XCTAssertNil(session.targetSnapshot)
    }

    func testCancelledCaptureLeavesNoCommittedSnapshot() async throws {
        let source = try sourceURL("id,description\n1,Milk\n")
        defer { try? FileManager.default.removeItem(at: source) }
        let store = TargetSnapshotStore()
        let task = Task {
            try await store.capture(
                sourceURL: source, databaseIdentity: "cancelled", displayName: "Cancelled",
                sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
            )
        }
        task.cancel()
        await XCTAssertThrowsErrorAsync {
            _ = try await task.value
        }
    }

    func testCaptureEnforcesConfiguredByteLimit() async throws {
        let source = try sourceURL("id,description\n1,Milk\n")
        defer { try? FileManager.default.removeItem(at: source) }
        let root = FoodMapperStorage.privateDirectory(["TargetSnapshots", "limit-\(UUID().uuidString)"])
        let store = TargetSnapshotStore(root: root, maximumSourceBytes: 8)
        await XCTAssertThrowsErrorAsync {
            _ = try await store.capture(
                sourceURL: source, databaseIdentity: "limited", displayName: "Limited",
                sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
            )
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
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
    override func setUpWithError() throws {
        try FoodMapperStorage.bootstrap()
        _ = CacheRecoveryState.consumeFailure()
    }
    private func writeDatabase(_ content: String, extension fileExtension: String = "csv") throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-database-\(UUID().uuidString).\(fileExtension)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testExplicitStorageOverrideKeepsTestsOutOfUserSupport() {
        XCTAssertTrue(FoodMapperStorage.isIsolatedTestStorage)
        XCTAssertNotEqual(FoodMapperStorage.applicationSupportURL, FoodMapperStorage.liveApplicationSupportURL)
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

    func testCacheRecoveryKeepsCompletedNewPairAndRemovesBackups() async throws {
        let directory = isolatedApplicationSupport.appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let transaction = directory.appendingPathComponent(".cache-transaction-complete", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        let cacheName = "database_embeddings_model.bin"
        let metadataName = "database_embeddings_model.json"
        let newData = [Float(3), 4].withUnsafeBufferPointer { Data(buffer: $0) }
        let oldData = [Float(1), 2].withUnsafeBufferPointer { Data(buffer: $0) }
        let metadata = CustomDatabaseCacheMetadata(
            version: 1, databaseID: "database", sourceHash: String(repeating: "b", count: 64),
            schemaHash: String(repeating: "c", count: 64), rowOrderHash: String(repeating: "d", count: 64),
            textColumn: "description", idColumn: "id", modelKey: "model",
            modelArtifactFingerprint: String(repeating: "a", count: 64), entryCount: 1,
            embeddingDimensions: 2, embeddingDigest: CustomDatabaseValidator.digest(newData)
        )
        try newData.write(to: directory.appendingPathComponent(cacheName))
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent(metadataName))
        try oldData.write(to: transaction.appendingPathComponent("cache.backup"))
        try JSONEncoder().encode(metadata.withEmbeddingDigest(CustomDatabaseValidator.digest(oldData)))
            .write(to: transaction.appendingPathComponent("metadata.backup"))
        try JSONEncoder().encode(CacheCommitJournal(cacheName: cacheName, metadataName: metadataName, metadata: metadata))
            .write(to: transaction.appendingPathComponent("journal.json"))
        for url in [
            directory.appendingPathComponent(cacheName), directory.appendingPathComponent(metadataName),
            transaction.appendingPathComponent("cache.backup"), transaction.appendingPathComponent("metadata.backup"),
            transaction.appendingPathComponent("journal.json")
        ] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        _ = try await MatchingEngine()

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(cacheName)), newData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
        XCTAssertFalse(CacheRecoveryState.consumeFailure())
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

    func testDescriptorMoveRejectsSymlinkAndHardlinkSources() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-secure-moves-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let target = directory.appendingPathComponent("target.bin")
        let symlink = directory.appendingPathComponent("symlink.bin")
        let hardlink = directory.appendingPathComponent("hardlink.bin")
        try Data([1]).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        XCTAssertThrowsError(try SecureFileAccess.renameRegularFile(
            symlink.lastPathComponent, from: directory, to: "moved-symlink.bin", in: directory
        ))
        try FileManager.default.linkItem(at: target, to: hardlink)
        XCTAssertThrowsError(try SecureFileAccess.renameRegularFile(
            hardlink.lastPathComponent, from: directory, to: "moved-hardlink.bin", in: directory
        ))
    }

    func testDescriptorMoveRejectsPathSwapAfterIdentityCapture() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-path-swap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let source = directory.appendingPathComponent("source.bin")
        let replacement = directory.appendingPathComponent("replacement.bin")
        try Data([1]).write(to: source)
        try Data([2]).write(to: replacement)
        for url in [source, replacement] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        #if DEBUG
        SecureFileAccess.beforeRenameRegularFileForTesting = {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.createSymbolicLink(at: source, withDestinationURL: replacement)
        }
        defer { SecureFileAccess.beforeRenameRegularFileForTesting = nil }
        XCTAssertThrowsError(try SecureFileAccess.renameRegularFile(
            source.lastPathComponent, from: directory, to: "destination.bin", in: directory
        ))
        XCTAssertThrowsError(try SecureFileAccess.openRegularFile(
            directory.appendingPathComponent("destination.bin"), under: directory
        ))
        #endif
    }
}

@MainActor
final class DatabaseOperationAdmissionTests: XCTestCase {
    override func setUpWithError() throws {
        try FoodMapperStorage.bootstrap()
        _ = CacheRecoveryState.consumeFailure()
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

    func testInterruptedDeletionRestoresAllFilesBeforeRegistryReplacement() throws {
        let database = CustomDatabase(
            id: "recovery_database", displayName: "Recovery", csvPath: "",
            textColumn: "description", itemCount: 1
        )
        let registry = try JSONEncoder().encode([database])
        let root = isolatedApplicationSupport.appendingPathComponent("FoodMapper", isDirectory: true)
        let cache = root.appendingPathComponent("CustomDBs", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        try registry.write(to: root.appendingPathComponent("custom_databases.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("custom_databases.json").path)

        let stage = cache.appendingPathComponent(".delete-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        let files = ["recovery_database_data.csv", "recovery_database_embeddings_model.bin"]
        try "id,description\n1,Milk\n".data(using: .utf8)!.write(to: stage.appendingPathComponent(files[0]))
        try Data([1, 2, 3]).write(to: stage.appendingPathComponent(files[1]))
        for name in files {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(name).path)
        }
        try deletionJournalData(
            databaseID: database.id, files: files, priorRegistry: registry,
            replacementRegistry: try JSONEncoder().encode([CustomDatabase]())
        ).write(to: stage.appendingPathComponent("journal.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent("journal.json").path)

        let state = AppState()
        state.loadCustomDatabases()

        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(files[0])), "id,description\n1,Milk\n".data(using: .utf8))
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(files[1])), Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }

    func testInterruptedDeletionConflictDoesNotPartiallyRestoreFiles() throws {
        let database = CustomDatabase(
            id: "conflict_database", displayName: "Conflict", csvPath: "",
            textColumn: "description", itemCount: 1
        )
        let registry = try JSONEncoder().encode([database])
        let root = isolatedApplicationSupport.appendingPathComponent("FoodMapper", isDirectory: true)
        let cache = root.appendingPathComponent("CustomDBs", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        try registry.write(to: root.appendingPathComponent("custom_databases.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("custom_databases.json").path)

        let stage = cache.appendingPathComponent(".delete-conflict", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        let files = ["conflict_database_data.csv", "conflict_database_embeddings_model.bin"]
        try Data([1]).write(to: stage.appendingPathComponent(files[0]))
        try Data([2]).write(to: stage.appendingPathComponent(files[1]))
        try Data([9]).write(to: cache.appendingPathComponent(files[1]))
        for name in files {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(name).path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.appendingPathComponent(files[1]).path)
        try deletionJournalData(
            databaseID: database.id, files: files, priorRegistry: registry,
            replacementRegistry: try JSONEncoder().encode([CustomDatabase]())
        ).write(to: stage.appendingPathComponent("journal.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent("journal.json").path)

        let state = AppState()
        state.loadCustomDatabases()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(files[0]).path))
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(files[1])), Data([9]))
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        XCTAssertTrue(names.contains { $0.hasPrefix(".delete-quarantine-") })
    }

    func testQuarantinedCacheIsVisibleInDatabaseManagementState() async throws {
        let cache = isolatedApplicationSupport.appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        let interrupted = cache.appendingPathComponent(".cache-transaction-invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interrupted.path)

        let state = AppState()
        _ = try await state.getOrCreateEngine()

        XCTAssertEqual(state.databaseRecoveryIssue, .cache)
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        XCTAssertTrue(names.contains { $0.hasPrefix(".cache-quarantine-") })
    }

    private func deletionJournalData(
        databaseID: String, files: [String], priorRegistry: Data, replacementRegistry: Data
    ) throws -> Data {
        let digest = SHA256.hash(data: replacementRegistry).map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: [
            "version": 3,
            "databaseID": databaseID,
            "files": files,
            "priorRegistry": priorRegistry.base64EncodedString(),
            "replacementRegistryDigest": digest
        ])
    }
}
