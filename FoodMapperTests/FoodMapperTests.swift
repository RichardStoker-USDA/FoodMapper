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
        let source = try sourceURL("id,description\n\n1,\"Broccoli soup\"   \n \n,\"\"\n2,\"Milk\" \n")
        defer { try? FileManager.default.removeItem(at: source) }
        let input = try CSVParser.parse(content: String(contentsOf: source), url: source)
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "parser", displayName: "Parser",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        XCTAssertEqual(snapshot.manifest.rowCount, input.rowCount)
        let broccoliID = try await store.search(reference: snapshot.reference, query: "broccoli soup").first?.matchID
        XCTAssertEqual(broccoliID, "1")
        let entries = try await store.loadEntries(for: snapshot)
        XCTAssertEqual(entries.compactMap { $0.targetRowKey?.sourceRow }, [2, 3])
    }

    func testSnapshotParserMatchesEscapedQuotesBOMAndMixedLineEndings() async throws {
        let source = try sourceURL(
            "\u{FEFF}id,description,note\r\n" +
            "1,\"Chef \"\"special\"\" soup\",\"Line one\rLine two\"\r" +
            "2,\"Broccoli soup\" \t,plain\r"
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let input = try CSVParser.parse(content: String(contentsOf: source), url: source)
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "parser-quote-cr", displayName: "Parser",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let entries = try await store.loadEntries(for: snapshot)

        XCTAssertEqual(input.rowCount, 2)
        XCTAssertEqual(snapshot.manifest.rowCount, input.rowCount)
        XCTAssertEqual(entries[0].text, "Chef \"special\" soup")
        XCTAssertEqual(entries[0].additionalFields["note"], "Line one\nLine two")
        XCTAssertEqual(entries[1].text, "Broccoli soup")
        XCTAssertEqual(entries[1].targetRowKey, TargetRowKey(targetDigest: snapshot.reference.digest, sourceRow: 3))
    }

    func testSnapshotParserMatchesUnicodeWhitespaceBeforeQuotedField() async throws {
        let source = try sourceURL(
            "id,description\n" +
            "1,\u{00A0}\"Broccoli\n soup\"\n" +
            "2,Milk\n"
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let input = try CSVParser.parse(content: String(contentsOf: source), url: source)
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "parser-unicode-whitespace", displayName: "Parser",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let entries = try await store.loadEntries(for: snapshot)

        XCTAssertEqual(input.rowCount, 2)
        XCTAssertEqual(input.rows.first?["description"], "Broccoli\n soup")
        XCTAssertEqual(entries.first?.text, "Broccoli\n soup")
        XCTAssertEqual(entries.count, input.rowCount)
    }

    func testSnapshotPadsMissingTrailingFieldsLikeCSVParser() async throws {
        let source = try sourceURL("id,description,note\n1,Milk\n")
        defer { try? FileManager.default.removeItem(at: source) }
        let parsed = try CSVParser.parse(content: String(contentsOf: source), url: source)
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "parser-missing-trailing", displayName: "Parser",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let entries = try await store.loadEntries(for: snapshot)

        XCTAssertEqual(parsed.rowCount, snapshot.manifest.rowCount)
        XCTAssertEqual(entries.first?.text, "Milk")
        XCTAssertTrue(entries.first?.additionalFields.isEmpty == true)
    }

    func testSnapshotPreservesADataBOMAfterTheHeader() async throws {
        let source = try sourceURL("id,description\n1,\"\u{FEFF}Milk\"\n")
        defer { try? FileManager.default.removeItem(at: source) }
        let parsed = try CSVParser.parse(content: String(contentsOf: source), url: source)
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "parser-data-bom", displayName: "Parser",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let entries = try await store.loadEntries(for: snapshot)

        XCTAssertEqual(parsed.rows.first?["description"], "\u{FEFF}Milk")
        XCTAssertEqual(entries.first?.text, "\u{FEFF}Milk")
    }

    func testTargetSearchUsesOneLimitAfterMatchTierOrdering() async throws {
        let source = try sourceURL(
            "id,description\n" +
            "1,broccoli soup\n" +
            "2,broccoli\n" +
            "3,broccoli\n"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let store = TargetSnapshotStore()
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "search-limit", displayName: "Search",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )

        let results = try await store.search(reference: snapshot.reference, query: "broccoli", limit: 2)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map(\.kind), [.exactDescription, .exactDescription])
        XCTAssertEqual(results.map(\.record.sourceRow), [3, 4])
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
        XCTAssertNotEqual(rows[0].targetRowKey, rows[1].targetRowKey)
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

    func testTypedFooDBDuplicateIDsStayOnTheSelectedRowDuringExport() {
        let digest = String(repeating: "a", count: TargetRowKey.digestLength)
        let firstKey = TargetRowKey(targetDigest: digest, sourceRow: 2)
        let secondKey = TargetRowKey(targetDigest: digest, sourceRow: 3)
        let first = MatchCandidate(
            matchText: "Broccoli soup", matchID: "9", score: 0.8,
            additionalFields: ["energy": "44"], targetRowKey: firstKey
        )
        let second = MatchCandidate(
            matchText: "Broccoli soup", matchID: "9", score: 0.7,
            additionalFields: ["energy": "61"], targetRowKey: secondKey
        )
        let result = MatchResult(
            inputText: "broccoli soup", inputRow: 0, matchText: first.matchText, matchID: first.matchID,
            score: first.score, status: .match, matchAdditionalFields: first.additionalFields,
            candidates: [first, second], targetRowKey: firstKey
        )
        let keyedDecision = ReviewDecision(
            status: .overridden, overrideMatchText: second.matchText, overrideMatchID: second.matchID,
            overrideScore: second.score, note: nil, reviewedAt: nil,
            selectedTargetRowKey: secondKey
        )
        let keyedCSV = CSVExporter.export(
            results: [result], pipelineName: "Test", selectedColumn: "input",
            targetTextColumn: "description", targetIdColumn: "id",
            targetColumnNames: ["id", "description", "energy"], reviewDecisions: [result.id: keyedDecision]
        )

        XCTAssertTrue(keyedCSV.contains("9,Broccoli soup,61"))
        XCTAssertFalse(keyedCSV.contains("9,Broccoli soup,44"))

        let partialCSV = CSVExporter.export(
            results: [result], pipelineName: "Test", selectedColumn: "input",
            reviewDecisions: [result.id: ReviewDecision(
                status: .overridden, overrideMatchText: second.matchText, overrideMatchID: second.matchID,
                overrideScore: nil, note: nil, reviewedAt: nil,
                manualTargetSelection: TargetSnapshotSelection(
                    targetRowKey: secondKey, matchText: second.matchText, matchID: second.matchID,
                    fields: ["id": "9", "description": "Broccoli soup", "energy": "61"]
                ), selectedTargetRowKey: secondKey
            )]
        )
        XCTAssertTrue(partialCSV.contains("db_energy"))
        XCTAssertTrue(partialCSV.contains("61"))

        let ambiguousDecision = ReviewDecision(
            status: .overridden, overrideMatchText: second.matchText, overrideMatchID: second.matchID,
            overrideScore: second.score, note: nil, reviewedAt: nil
        )
        let ambiguousCSV = CSVExporter.export(
            results: [result], pipelineName: "Test", selectedColumn: "input",
            targetTextColumn: "description", targetIdColumn: "id",
            targetColumnNames: ["id", "description", "energy"], reviewDecisions: [result.id: ambiguousDecision]
        )

        XCTAssertFalse(ambiguousCSV.contains("Broccoli soup,44"))
        XCTAssertFalse(ambiguousCSV.contains("Broccoli soup,61"))
    }

    func testCandidateDedupeKeyKeepsDistinctRowsWithTheSameID() {
        let digest = String(repeating: "c", count: TargetRowKey.digestLength)
        let firstCandidateID = UUID()
        let first = MatchCandidate(
            id: firstCandidateID, matchText: "Broccoli soup", matchID: "9", score: 0.8,
            additionalFields: ["energy": "44"],
            targetRowKey: TargetRowKey(targetDigest: digest, sourceRow: 2)
        )
        let second = MatchCandidate(
            matchText: "Broccoli soup", matchID: "9", score: 0.7,
            additionalFields: ["energy": "61"],
            targetRowKey: TargetRowKey(targetDigest: digest, sourceRow: 3)
        )
        let duplicate = MatchCandidate(
            id: firstCandidateID, matchText: "Broccoli soup", matchID: "9", score: 0.6,
            additionalFields: ["energy": "44"],
            targetRowKey: TargetRowKey(targetDigest: digest, sourceRow: 2)
        )

        XCTAssertNotEqual(first.deduplicationKey, second.deduplicationKey)
        XCTAssertEqual(first.deduplicationKey, duplicate.deduplicationKey)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, duplicate)
    }

    func testBundledFooDBDuplicateIDsKeepDistinctSnapshotKeys() async throws {
        guard BuiltInDatabase.fooDB.csvURL != nil else {
            throw XCTSkip("FooDB resource is not present")
        }
        let root = FoodMapperStorage.privateDirectory(["TargetSnapshots", "foodb-duplicates-\(UUID().uuidString)"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TargetSnapshotStore(root: root)
        let snapshot = try await store.capture(database: .builtIn(.fooDB))
        let entries = try await store.loadEntries(for: snapshot)
        let duplicateRows = try XCTUnwrap(
            Dictionary(grouping: entries, by: \.id).values.first(where: { $0.count > 1 })
        )
        let keys = try duplicateRows.map { try XCTUnwrap($0.targetRowKey) }

        XCTAssertGreaterThan(keys.count, 1)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(keys.map(\.sourceRow)).count, keys.count)
    }

    func testLegacySnapshotSchemasAndResultsDecodeWithoutRowKeys() throws {
        let digest = String(repeating: "b", count: TargetSnapshotReference.digestLength)
        let referenceData = try JSONSerialization.data(withJSONObject: [
            "digest": digest,
            "databaseIdentity": "legacy",
            "displayName": "Legacy",
            "sourceKind": "custom"
        ])
        let reference = try JSONDecoder().decode(TargetSnapshotReference.self, from: referenceData)
        XCTAssertEqual(reference.sourceDigest, digest)

        let manifestData = try JSONSerialization.data(withJSONObject: [
            "digest": digest,
            "databaseIdentity": "legacy",
            "displayName": "Legacy",
            "sourceKind": "custom",
            "delimiter": ",",
            "header": ["id", "description"],
            "idColumn": "id",
            "textColumn": "description",
            "rowCount": 1,
            "sourceOrder": "ascending-row",
            "sourceFilename": "target.csv",
            "recordsDigest": digest
        ])
        let manifest = try JSONDecoder().decode(TargetSnapshotManifest.self, from: manifestData)
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.sourceDigest, digest)
        XCTAssertEqual(manifest.selectedFields, ["id", "description"])

        let selectionData = try JSONSerialization.data(withJSONObject: [
            "snapshotDigest": digest,
            "sourceRow": 2,
            "matchText": "Milk",
            "matchID": "1",
            "fields": ["id": "1", "description": "Milk"]
        ])
        let selection = try JSONDecoder().decode(TargetSnapshotSelection.self, from: selectionData)
        XCTAssertEqual(selection.targetRowKey, TargetRowKey(targetDigest: digest, sourceRow: 2))

        let result = MatchResult(
            inputText: "milk", inputRow: 0, matchText: "Milk", matchID: "1", score: 0.9,
            status: .match, targetRowKey: TargetRowKey(targetDigest: digest, sourceRow: 2)
        )
        var resultObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        resultObject.removeValue(forKey: "targetRowKey")
        let legacyResultData = try JSONSerialization.data(withJSONObject: resultObject)
        let legacyResult = try JSONDecoder().decode(MatchResult.self, from: legacyResultData)
        XCTAssertNil(legacyResult.targetRowKey)

        let legacyDecisionData = Data(#"{"status":"overridden","overrideMatchText":"Milk","overrideMatchID":"1","overrideScore":0.9}"#.utf8)
        let legacyDecision = try JSONDecoder().decode(ReviewDecision.self, from: legacyDecisionData)
        XCTAssertNil(legacyDecision.selectedTargetRowKey)
    }

    func testSessionIndexSkipsOneInvalidLegacyRecord() throws {
        let valid = MatchingSession(
            inputFileName: "input.csv", databaseName: "Target", threshold: 0.5,
            totalCount: 1, matchedCount: 1, resultsFilename: "valid.json", date: Date(timeIntervalSince1970: 0)
        )
        let validObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        var invalidObject = validObject
        invalidObject["resultsFilename"] = "../outside.json"
        let data = try JSONSerialization.data(withJSONObject: [validObject, invalidObject])

        let decoded = try AppState.decodePersistedSessions(data)

        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions.first?.resultsFilename, "valid.json")
        XCTAssertEqual(decoded.skippedCount, 1)
    }

    func testTamperedSnapshotIsQuarantinedBeforeReuse() async throws {
        let source = try sourceURL("id,description\n1,Milk\n")
        let root = FoodMapperStorage.privateDirectory(["TargetSnapshots", "tampered-\(UUID().uuidString)"])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        let store = TargetSnapshotStore(root: root)
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "tampered", displayName: "Tampered",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let records = root.appendingPathComponent(snapshot.reference.digest, isDirectory: true)
            .appendingPathComponent(TargetSnapshotStore.recordsFilename)
        try Data("not-json\n".utf8).write(to: records, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: records.path)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.search(reference: snapshot.reference, query: "milk")
        }
        try await store.recover()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(snapshot.reference.digest).path))
        let quarantined = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".snapshot-quarantine-") }
        XCTAssertEqual(quarantined.count, 1)

        let repaired = try await store.capture(
            sourceURL: source, databaseIdentity: "tampered", displayName: "Tampered",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        XCTAssertEqual(repaired.reference.digest, snapshot.reference.digest)
        let repairedSearchCount = try await store.search(reference: repaired.reference, query: "milk").count
        XCTAssertEqual(repairedSearchCount, 1)
    }

    func testSnapshotDigestBindsRecordsDigest() async throws {
        let source = try sourceURL("id,description\n1,Milk\n")
        let root = FoodMapperStorage.privateDirectory(["TargetSnapshots", "bound-records-\(UUID().uuidString)"])
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        let store = TargetSnapshotStore(root: root)
        let snapshot = try await store.capture(
            sourceURL: source, databaseIdentity: "bound-records", displayName: "Bound Records",
            sourceKind: .custom, textColumn: "description", idColumn: "id", requireSourceOwner: true
        )
        let directory = root.appendingPathComponent(snapshot.reference.digest, isDirectory: true)
        let recordsURL = directory.appendingPathComponent(TargetSnapshotStore.recordsFilename)
        let originalRecords = try String(contentsOf: recordsURL, encoding: .utf8)
        let tamperedRecords = originalRecords.replacingOccurrences(of: "Milk", with: "Rice")
        try tamperedRecords.write(to: recordsURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordsURL.path)

        let manifestURL = directory.appendingPathComponent(TargetSnapshotStore.manifestFilename)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest["recordsDigest"] = CustomDatabaseValidator.digest(Data(tamperedRecords.utf8))
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

        await XCTAssertThrowsErrorAsync {
            _ = try await store.search(reference: snapshot.reference, query: "rice")
        }
        try await store.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSuppliedFoodFilesKeepTargetRowsAddressable() async throws {
        let environment = ProcessInfo.processInfo.environment
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let targetURL = environment["FOODMAPPER_TEST_TARGET_PATH"]
            .map(URL.init(fileURLWithPath:))
            ?? downloads.appendingPathComponent("fndds0304food.csv")
        let inputURL = environment["FOODMAPPER_TEST_INPUT_PATH"]
            .map(URL.init(fileURLWithPath:))
            ?? downloads.appendingPathComponent("ing0304_2or98_missing.csv")
        guard FileManager.default.fileExists(atPath: targetURL.path),
              FileManager.default.fileExists(atPath: inputURL.path) else {
            throw XCTSkip("Supplied food files are not present")
        }

        let target = try await CSVParser.parse(url: targetURL)
        let input = try await CSVParser.parse(url: inputURL)
        let root = FoodMapperStorage.privateDirectory(["TargetSnapshots", "supplied-\(UUID().uuidString)"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TargetSnapshotStore(root: root)
        let snapshot = try await store.capture(
            sourceURL: targetURL, databaseIdentity: "fndds0304food", displayName: "FNDDS",
            sourceKind: .custom, textColumn: "fooddesc0304", idColumn: "foodcode0304", requireSourceOwner: true
        )
        let reportedInput = "SOUP,BROCCOLI CHS,CND,COND,COMM"
        let reportedTarget = "Broccoli cheese soup, prepared with milk"
        let reportedInputRow = input.rows.first { $0["ingcode0304"] == "6584" }
        let hits = try await store.search(reference: snapshot.reference, query: reportedTarget)
        let entries = try await store.loadEntries(for: snapshot)

        XCTAssertTrue(input.columns.contains("ingdesc0304"))
        XCTAssertEqual(reportedInputRow?["ingdesc0304"], reportedInput)
        XCTAssertEqual(snapshot.manifest.rowCount, target.rowCount)
        XCTAssertEqual(hits.first?.matchText, reportedTarget)
        XCTAssertEqual(hits.first?.matchID, "72302100")
        XCTAssertEqual(hits.first?.record.sourceRow, 5238)
        XCTAssertEqual(entries.first?.targetRowKey, TargetRowKey(targetDigest: snapshot.reference.digest, sourceRow: 2))
    }

    func testExportUsesReviewedCandidateIndexForDuplicateIDs() {
        let first = MatchCandidate(matchText: "Broccoli soup", matchID: "9", score: 0.8, additionalFields: ["energy": "44"])
        let second = MatchCandidate(matchText: "Broccoli soup", matchID: "9", score: 0.7, additionalFields: ["energy": "61"])
        let result = MatchResult(
            inputText: "broccoli soup", inputRow: 0, matchText: first.matchText, matchID: first.matchID,
            score: first.score, status: .match, matchAdditionalFields: first.additionalFields,
            candidates: [first, second]
        )
        XCTAssertFalse(result.isPipelineMatch(second))
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
        let retainedSearchCount = try await store.search(reference: snapshot.reference, query: "milk").count
        XCTAssertEqual(retainedSearchCount, 1)
        try await store.reconcile(retaining: [])
        await XCTAssertThrowsErrorAsync {
            _ = try await store.search(reference: snapshot.reference, query: "milk")
        }
    }

    func testV1MatchingKeepsTheOriginalDatabaseIdentity() {
        let database = AnyDatabase.builtIn(.fooDB)
        XCTAssertEqual(AppState.v1MatchingDatabase(database).id, database.id)
        XCTAssertEqual(AppState.v1MatchingDatabase(database).csvURL, database.csvURL)
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
