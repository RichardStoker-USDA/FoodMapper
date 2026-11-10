import Foundation

enum PastedTableError: LocalizedError, Equatable {
    case empty
    case tooLarge
    case headerOnly
    case unreadable(String)
    case notStored

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The clipboard has no text. Copy cells from a spreadsheet or a list of descriptions, then paste again."
        case .tooLarge:
            return "The clipboard text is over \(PastedTable.maximumBytes / 1_048_576) MB. Save it as a CSV or TSV file and open that instead."
        case .headerOnly:
            return "The pasted table has a header row and no data rows."
        case let .unreadable(reason):
            return "The pasted table could not be read. \(reason)"
        case .notStored:
            return "The pasted data could not be saved."
        }
    }
}

/// Turns clipboard text into a CSV file the normal importer reads.
///
/// Spreadsheets copy cells as tab-separated rows, so text with a tab is a table whose
/// first row is the header. Text without a tab is a list: one description per line under
/// a `description` header that FoodMapper adds.
enum PastedTable {
    static let maximumBytes = 16 * 1_048_576
    static let listHeader = "description"

    struct Table: Equatable {
        let csv: String
        let columnCount: Int
        let rowCount: Int
        /// True for a list, where FoodMapper supplied the header.
        let addedHeader: Bool
    }

    static func table(from text: String) throws -> Table {
        guard text.lengthOfBytes(using: .utf8) <= maximumBytes else { throw PastedTableError.tooLarge }
        let normalized = CSVParser.stripBOM(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PastedTableError.empty }

        if normalized.contains("\t") {
            let records: [[String]]
            do {
                records = try CSVParser.parseRecords(content: normalized, delimiter: "\t")
            } catch {
                throw PastedTableError.unreadable(error.localizedDescription)
            }
            // A tab inside one quoted cell is part of a description, not a column break.
            // Only a record with more than one field makes this a table.
            if records.contains(where: { $0.count > 1 }) {
                guard records.count >= 2 else { throw PastedTableError.headerOnly }
                return Table(
                    csv: csv(records), columnCount: records[0].count, rowCount: records.count - 1, addedHeader: false
                )
            }
        }

        // A list. Spreadsheets quote a single cell that contains a line break, so try the
        // parser first and fall back to plain lines when a description has stray quotes.
        let lines: [String]
        if let records = try? CSVParser.parseRecords(content: normalized, delimiter: "\t") {
            lines = records.compactMap(\.first)
        } else {
            lines = normalized.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let descriptions = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !descriptions.isEmpty else { throw PastedTableError.empty }
        return Table(
            csv: csv([[listHeader]] + descriptions.map { [$0] }), columnCount: 1, rowCount: descriptions.count, addedHeader: true
        )
    }

    /// Writes the table into a new owner-only folder under `temporaryRoot`. The caller removes the folder.
    static func writeTemporaryFile(from text: String, temporaryRoot: URL, now: Date = Date()) throws -> URL {
        let table = try table(from: text)
        let directory = temporaryRoot.appendingPathComponent("paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let url = directory.appendingPathComponent("Pasted \(formatter.string(from: now)).csv")
        guard FileManager.default.createFile(
            atPath: url.path, contents: Data(table.csv.utf8), attributes: [.posixPermissions: 0o600]
        ) else {
            try? FileManager.default.removeItem(at: directory)
            throw PastedTableError.notStored
        }
        return url
    }

    /// Every field quoted, so commas, quotes, and line breaks in a cell survive and the delimiter is never ambiguous.
    private static func csv(_ records: [[String]]) -> String {
        records.map { record in
            record.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }
}
