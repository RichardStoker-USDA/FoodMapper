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

    /// All supported UTTypes for file pickers.
    static var allUTTypes: [UTType] {
        [.commaSeparatedText, .tabSeparatedText]
    }

    /// Detect format from file extension.
    static func from(url: URL) -> DataFileFormat {
        url.pathExtension.lowercased() == "tsv" ? .tsv : .csv
    }

    /// Detect format by sniffing the header line content.
    /// If header has tabs and no commas, it's TSV. Otherwise CSV.
    static func detect(from headerLine: String) -> DataFileFormat {
        let tabCount = headerLine.filter { $0 == "\t" }.count
        let commaCount = headerLine.filter { $0 == "," }.count
        // If tabs present and more tabs than commas, it's TSV
        if tabCount > 0 && tabCount >= commaCount {
            return .tsv
        }
        return .csv
    }
}

/// CSV/TSV parsing utilities
enum CSVParser {
    /// Parse a CSV file at the given URL
    static func parse(url: URL) async throws -> InputFile {
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parse(content: content, url: url)
    }

    /// Quick row count estimate from first N lines + file size. Avoids loading the whole file.
    static func estimateRowCount(url: URL, sampleLines: Int = 100) throws -> CSVEstimate {
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = fileAttributes[.size] as? Int64, fileSize > 0 else {
            throw CSVParseError.emptyFile
        }

        // Read just the beginning of the file to sample
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        // Read up to 64KB for sampling (enough for ~100 typical lines)
        let sampleData = fileHandle.readData(ofLength: 65536)
        guard let sampleContent = String(data: sampleData, encoding: .utf8) else {
            throw CSVParseError.invalidFormat
        }

        let lines = sampleContent.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard lines.count > 1 else {
            // File has header only or is very small
            return CSVEstimate(
                estimatedRowCount: max(0, lines.count - 1),
                fileSize: fileSize,
                isExact: true
            )
        }

        // Calculate average line length from sample (excluding header)
        let dataLines = Array(lines.dropFirst().prefix(sampleLines))
        let totalLineLength = dataLines.reduce(0) { $0 + $1.count + 1 }  // +1 for newline
        let avgLineLength = Double(totalLineLength) / Double(dataLines.count)

        // Check if we read the entire file
        if sampleData.count >= fileSize {
            return CSVEstimate(
                estimatedRowCount: lines.count - 1,  // Subtract header
                fileSize: fileSize,
                isExact: true
            )
        }

        // Estimate total rows from file size
        let headerLength = lines[0].count + 1
        let dataSize = Int64(fileSize) - Int64(headerLength)
        let estimatedRows = Int(Double(dataSize) / avgLineLength)

        return CSVEstimate(
            estimatedRowCount: max(1, estimatedRows),
            fileSize: fileSize,
            isExact: false
        )
    }

    /// Get file size in bytes
    static func getFileSize(url: URL) -> Int64? {
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return fileAttributes?[.size] as? Int64
    }

    /// Parse delimited text content (CSV or TSV, auto-detected from header)
    static func parse(content: String, url: URL) throws -> InputFile {
        let lines = stripBOM(content).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            throw CSVParseError.emptyFile
        }

        // Auto-detect format from header line
        let format = DataFileFormat.detect(from: lines[0])
        let delimiter = format.delimiter

        // Parse header
        let columns = parseCSVLine(lines[0], delimiter: delimiter)
        guard !columns.isEmpty else {
            throw CSVParseError.noColumns
        }

        // Parse rows
        var rows: [[String: String]] = []
        for i in 1..<lines.count {
            let values = parseCSVLine(lines[i], delimiter: delimiter)
            var row: [String: String] = [:]
            for (index, column) in columns.enumerated() {
                if index < values.count {
                    row[column] = values[index]
                }
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

    /// Strip UTF-8 BOM from the beginning of a string if present
    static func stripBOM(_ content: String) -> String {
        if content.hasPrefix("\u{FEFF}") {
            return String(content.dropFirst())
        }
        return content
    }

    /// Parse a single delimited line handling quoted fields
    static func parseCSVLine(_ line: String, delimiter: Character = ",") -> [String] {
        var result: [String] = []
        var currentField = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == delimiter && !inQuotes {
                result.append(currentField.trimmingCharacters(in: .whitespaces))
                currentField = ""
            } else {
                currentField.append(char)
            }
        }
        result.append(currentField.trimmingCharacters(in: .whitespaces))

        return result
    }
}

// MARK: - CSV Estimate

/// Result of CSV row count estimation
struct CSVEstimate {
    /// Estimated number of data rows (excluding header)
    let estimatedRowCount: Int

    /// File size in bytes
    let fileSize: Int64

    /// Whether the count is exact (file was fully read) or estimated
    let isExact: Bool

    /// Format file size for display
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    /// Format row count for display
    var formattedRowCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: estimatedRowCount)) ?? "\(estimatedRowCount)"
        return isExact ? count : "~\(count)"
    }
}

// MARK: - Errors

enum CSVParseError: LocalizedError {
    case emptyFile
    case noColumns
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .emptyFile: return "File is empty"
        case .noColumns: return "No columns found in header"
        case .invalidFormat: return "Invalid file format"
        }
    }
}
