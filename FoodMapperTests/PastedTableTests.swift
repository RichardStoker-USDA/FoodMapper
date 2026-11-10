import XCTest
@testable import FoodMapper

final class PastedTableTests: XCTestCase {
    func testSpreadsheetCellsBecomeATableWithTheirHeader() throws {
        // Cells as a spreadsheet copies them: tab-separated, CRLF rows, a cell with a line break quoted.
        let text = "Food\tAmount, g\tNote\r\nSoup, \"hot\"\t250\t\"line one\nline two\"\r\n5\" pizza\t\t\r\n"
        let table = try PastedTable.table(from: text)
        XCTAssertEqual(table.columnCount, 3)
        XCTAssertEqual(table.rowCount, 2)
        XCTAssertFalse(table.addedHeader)
        let records = try CSVParser.parseRecords(content: table.csv, delimiter: ",")
        XCTAssertEqual(records, [
            ["Food", "Amount, g", "Note"],
            ["Soup, \"hot\"", "250", "line one\nline two"],
            ["5\" pizza", "", ""],
        ])
        XCTAssertEqual(DataFileFormat.detect(from: table.csv), .csv, "a comma inside a header cell must not confuse the delimiter")
    }

    func testAListGetsADescriptionHeader() throws {
        let table = try PastedTable.table(from: "\u{FEFF}boiled broccoli\n\n  \"Big\" burger, plain \nmilk, 2%\r\n")
        XCTAssertTrue(table.addedHeader)
        XCTAssertEqual(table.columnCount, 1)
        XCTAssertEqual(table.rowCount, 3)
        XCTAssertEqual(try CSVParser.parseRecords(content: table.csv, delimiter: ","), [
            ["description"], ["boiled broccoli"], ["\"Big\" burger, plain"], ["milk, 2%"],
        ])
        // A single quoted cell with a line break stays one description.
        let quoted = try PastedTable.table(from: "\"cheese\nsandwich\"\napple")
        XCTAssertEqual(try CSVParser.parseRecords(content: quoted.csv, delimiter: ","), [["description"], ["cheese\nsandwich"], ["apple"]])
    }

    func testRejectsEmptyHeaderOnlyAndOversizedText() {
        XCTAssertThrowsError(try PastedTable.table(from: " \n\t \n")) { XCTAssertEqual($0 as? PastedTableError, .empty) }
        XCTAssertThrowsError(try PastedTable.table(from: "")) { XCTAssertEqual($0 as? PastedTableError, .empty) }
        XCTAssertThrowsError(try PastedTable.table(from: "Food\tAmount\n")) { XCTAssertEqual($0 as? PastedTableError, .headerOnly) }
        XCTAssertThrowsError(try PastedTable.table(from: "Food\tAmount\n\"open\tcell\n")) {
            guard case .unreadable? = $0 as? PastedTableError else { return XCTFail("expected an unreadable table, got \($0)") }
        }
        XCTAssertThrowsError(try PastedTable.table(from: String(repeating: "a", count: PastedTable.maximumBytes + 1))) {
            XCTAssertEqual($0 as? PastedTableError, .tooLarge)
        }
    }

    func testTemporaryFileLoadsThroughTheNormalParser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foodmapper-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try PastedTable.writeTemporaryFile(
            from: "food\tgrams\nrice, white\t150\nblack beans\t90", temporaryRoot: root, now: Date(timeIntervalSince1970: 1_794_268_800)
        )
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Pasted 20"))
        XCTAssertEqual(url.pathExtension, "csv")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        let file = try await CSVParser.parse(url: url)
        XCTAssertEqual(file.columns, ["food", "grams"])
        XCTAssertEqual(file.rowCount, 2)
        XCTAssertEqual(file.values(for: "food"), ["rice, white", "black beans"])
        XCTAssertThrowsError(try PastedTable.writeTemporaryFile(from: "", temporaryRoot: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1, "a rejected paste leaves no folder behind")
    }
}
