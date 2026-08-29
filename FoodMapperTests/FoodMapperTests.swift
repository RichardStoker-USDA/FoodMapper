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
