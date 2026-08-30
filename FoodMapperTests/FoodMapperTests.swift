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
    private func writeDatabase(_ content: String, extension fileExtension: String = "csv") throws -> URL {
        let url = FileManager.default.temporaryDirectory
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
