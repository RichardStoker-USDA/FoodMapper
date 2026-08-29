import Foundation
import UniformTypeIdentifiers

/// Supported delimited text file formats.
enum DataFileFormat: String, Codable, CaseIterable, Sendable {
    case csv
    case tsv

    var delimiter: Character { self == .csv ? "," : "\t" }
    var delimiterString: String { String(delimiter) }
    var fileExtension: String { rawValue }
    var displayName: String { rawValue.uppercased() }

    var utType: UTType {
        self == .csv ? .commaSeparatedText : .tabSeparatedText
    }

    static var allUTTypes: [UTType] {
        [.commaSeparatedText, .tabSeparatedText]
    }

    static func from(url: URL) -> DataFileFormat {
        url.pathExtension.lowercased() == "tsv" ? .tsv : .csv
    }

    /// Detect the delimiter from the first logical record, ignoring quoted text.
    static func detect(from content: String) -> DataFileFormat {
        var commaCount = 0
        var tabCount = 0
        var inQuotes = false
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]
            let nextIndex = content.index(after: index)

            if character == "\"" {
                if inQuotes, nextIndex < content.endIndex, content[nextIndex] == "\"" {
                    index = content.index(after: nextIndex)
                    continue
                }
                inQuotes.toggle()
            } else if !inQuotes {
                if character == "," {
                    commaCount += 1
                } else if character == "\t" {
                    tabCount += 1
                } else if character == "\n" || character == "\r" {
                    break
                }
            }

            index = nextIndex
        }

        return tabCount > 0 && tabCount >= commaCount ? .tsv : .csv
    }
}

enum CSVParser {
    static func parse(url: URL) async throws -> InputFile {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content: content, url: url)
    }

    /// Estimate rows from a sample. Quoted newlines can make large-file estimates less exact.
    static func estimateRowCount(url: URL, sampleLines: Int = 100) throws -> CSVEstimate {
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = fileAttributes[.size] as? Int64, fileSize > 0 else {
            throw CSVParseError.emptyFile
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let sampleData = fileHandle.readData(ofLength: 65_536)
        let sampleContent = try decodeUTF8Sample(sampleData, isCompleteFile: sampleData.count >= fileSize)

        if sampleData.count >= fileSize {
            let format = DataFileFormat.detect(from: sampleContent)
            let records = try parseRecords(content: stripBOM(sampleContent), delimiter: format.delimiter)
            return CSVEstimate(
                estimatedRowCount: max(0, records.count - 1),
                fileSize: fileSize,
                isExact: true
            )
        }

        let physicalLines = sampleContent.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard physicalLines.count > 1 else {
            return CSVEstimate(estimatedRowCount: 0, fileSize: fileSize, isExact: false)
        }

        let dataLines = Array(physicalLines.dropFirst().prefix(sampleLines))
        let totalLineLength = dataLines.reduce(0) { $0 + $1.utf8.count + 1 }
        let averageLineLength = Double(totalLineLength) / Double(dataLines.count)
        let headerLength = physicalLines[0].utf8.count + 1
        let dataSize = fileSize - Int64(headerLength)
        let estimatedRows = Int(Double(dataSize) / averageLineLength)

        return CSVEstimate(
            estimatedRowCount: max(1, estimatedRows),
            fileSize: fileSize,
            isExact: false
        )
    }

    static func getFileSize(url: URL) -> Int64? {
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return fileAttributes?[.size] as? Int64
    }

    static func parse(content: String, url: URL) throws -> InputFile {
        let strippedContent = stripBOM(content)
        guard !strippedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CSVParseError.emptyFile
        }

        let format = DataFileFormat.detect(from: strippedContent)
        let records = try parseRecords(content: strippedContent, delimiter: format.delimiter)
        guard let rawColumns = records.first, !rawColumns.isEmpty else {
            throw CSVParseError.noColumns
        }

        let columns = rawColumns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let emptyIndex = columns.firstIndex(where: { $0.isEmpty }) {
            throw CSVParseError.emptyColumnName(index: emptyIndex + 1)
        }

        let groupedColumns = Dictionary(grouping: columns, by: { $0.lowercased() })
        let duplicates = groupedColumns.values
            .filter { $0.count > 1 }
            .compactMap(\.first)
            .sorted()
        guard duplicates.isEmpty else {
            throw CSVParseError.duplicateColumns(duplicates)
        }

        var rows: [[String: String]] = []
        rows.reserveCapacity(max(0, records.count - 1))

        for (offset, values) in records.dropFirst().enumerated() {
            guard values.count <= columns.count else {
                throw CSVParseError.tooManyFields(
                    row: offset + 2,
                    expected: columns.count,
                    actual: values.count
                )
            }

            var row: [String: String] = [:]
            row.reserveCapacity(columns.count)
            for (index, column) in columns.enumerated() {
                row[column] = index < values.count ? values[index] : ""
            }
            rows.append(row)
        }

        return InputFile(
            url: url,
            columns: columns,
            rowCount: rows.count,
            rows: rows,
            format: format
        )
    }

    static func stripBOM(_ content: String) -> String {
        content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
    }

    /// Decode a fixed-size sample without rejecting a valid UTF-8 file when the
    /// byte boundary lands inside the sample's final scalar.
    static func decodeUTF8Sample(_ data: Data, isCompleteFile: Bool) throws -> String {
        if let content = String(data: data, encoding: .utf8) {
            return content
        }

        guard !isCompleteFile else {
            throw CSVParseError.invalidEncoding
        }

        var prefix = data
        for _ in 0..<3 where !prefix.isEmpty {
            prefix.removeLast()
            if let content = String(data: prefix, encoding: .utf8) {
                return content
            }
        }

        throw CSVParseError.invalidEncoding
    }

    /// Parse complete logical records, including escaped quotes and quoted newlines.
    static func parseRecords(content: String, delimiter: Character) throws -> [[String]] {
        // Swift can expose CRLF as one extended grapheme cluster during Character
        // iteration. Normalize line endings first so record boundaries are handled
        // the same for Unix, Windows, and legacy Mac files.
        let normalizedContent = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var afterClosingQuote = false
        var index = normalizedContent.startIndex

        func appendField() {
            record.append(fieldWasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
            field = ""
            fieldWasQuoted = false
            afterClosingQuote = false
        }

        func appendRecord() {
            appendField()
            if !record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                records.append(record)
            }
            record = []
        }

        while index < normalizedContent.endIndex {
            let character = normalizedContent[index]
            let nextIndex = normalizedContent.index(after: index)

            if inQuotes {
                if character == "\"" {
                    if nextIndex < normalizedContent.endIndex, normalizedContent[nextIndex] == "\"" {
                        field.append("\"")
                        index = normalizedContent.index(after: nextIndex)
                        continue
                    }
                    inQuotes = false
                    afterClosingQuote = true
                    index = nextIndex
                    continue
                }

                if character == "\r" {
                    field.append("\n")
                    if nextIndex < normalizedContent.endIndex, normalizedContent[nextIndex] == "\n" {
                        index = normalizedContent.index(after: nextIndex)
                    } else {
                        index = nextIndex
                    }
                    continue
                }

                field.append(character)
                index = nextIndex
                continue
            }

            if afterClosingQuote {
                if character == delimiter {
                    appendField()
                } else if character == "\n" || character == "\r" {
                    appendRecord()
                    if character == "\r", nextIndex < normalizedContent.endIndex, normalizedContent[nextIndex] == "\n" {
                        index = normalizedContent.index(after: nextIndex)
                        continue
                    }
                } else if !character.isWhitespace {
                    field.append(character)
                    afterClosingQuote = false
                }
                index = nextIndex
                continue
            }

            if character == "\"", field.trimmingCharacters(in: .whitespaces).isEmpty {
                field = ""
                inQuotes = true
                fieldWasQuoted = true
            } else if character == delimiter {
                appendField()
            } else if character == "\n" || character == "\r" {
                appendRecord()
                if character == "\r", nextIndex < normalizedContent.endIndex, normalizedContent[nextIndex] == "\n" {
                    index = normalizedContent.index(after: nextIndex)
                    continue
                }
            } else {
                field.append(character)
            }

            index = nextIndex
        }

        guard !inQuotes else {
            throw CSVParseError.unterminatedQuotedField
        }

        if !field.isEmpty || fieldWasQuoted || !record.isEmpty {
            appendRecord()
        }

        return records
    }

    /// Compatibility helper for callers that already hold one logical record.
    static func parseCSVLine(_ line: String, delimiter: Character = ",") -> [String] {
        (try? parseRecords(content: line, delimiter: delimiter).first) ?? []
    }
}

struct CSVEstimate {
    let estimatedRowCount: Int
    let fileSize: Int64
    let isExact: Bool

    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var formattedRowCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: estimatedRowCount)) ?? "\(estimatedRowCount)"
        return isExact ? count : "~\(count)"
    }
}

enum CSVParseError: LocalizedError, Equatable {
    case emptyFile
    case noColumns
    case invalidEncoding
    case emptyColumnName(index: Int)
    case duplicateColumns([String])
    case tooManyFields(row: Int, expected: Int, actual: Int)
    case unterminatedQuotedField

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "File is empty"
        case .noColumns:
            return "No columns found in header"
        case .invalidEncoding:
            return "File must use UTF-8 encoding"
        case .emptyColumnName(let index):
            return "Column \(index) has no name"
        case .duplicateColumns(let names):
            return "Duplicate column names: \(names.joined(separator: ", "))"
        case .tooManyFields(let row, let expected, let actual):
            return "Row \(row) has \(actual) fields; the header has \(expected)"
        case .unterminatedQuotedField:
            return "A quoted field is missing its closing quote"
        }
    }
}
