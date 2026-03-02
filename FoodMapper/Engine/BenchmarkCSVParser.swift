import Foundation
import CryptoKit
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "benchmark-parser")

/// Parses benchmark CSV files with optional header comment blocks.
///
/// v2 format: Lines starting with `#` are metadata comments (key=value or key:value).
/// Required columns: input_text, expected_match
/// Optional columns: expected_match_id, alternative_match, category, difficulty, instruction, notes
enum BenchmarkCSVParser {

    struct ParseResult {
        let dataset: BenchmarkDataset
        let items: [BenchmarkItem]
    }

    /// Parse a benchmark CSV file from a URL.
    static func parse(url: URL, source: BenchmarkSource) throws -> ParseResult {
        let content = CSVParser.stripBOM(try String(contentsOf: url, encoding: .utf8))

        let checksum = SHA256.hash(data: Data(content.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()

        let lines = content.components(separatedBy: .newlines)

        // Parse header comments (supports both key=value and key:value)
        var metadata: [String: String] = [:]
        var dataLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let comment = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                // Try = separator first (v2 format), then : (v1 format)
                if let eqIdx = comment.firstIndex(of: "=") {
                    let key = String(comment[..<eqIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(comment[comment.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                    metadata[key] = value
                } else if let colonIdx = comment.firstIndex(of: ":") {
                    let key = String(comment[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(comment[comment.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    metadata[key] = value
                }
            } else if !trimmed.isEmpty {
                dataLines.append(trimmed)
            }
        }

        guard !dataLines.isEmpty else {
            throw BenchmarkParseError.emptyFile
        }

        // Detect delimiter from header (benchmark files can be CSV or TSV)
        let headerLine = dataLines[0]
        let format = DataFileFormat.detect(from: headerLine)
        let delimiter = format.delimiter

        // Parse header row
        let headers = CSVParser.parseCSVLine(headerLine, delimiter: delimiter).map {
            $0.lowercased().trimmingCharacters(in: .whitespaces)
        }

        // Support both "input_text" and "input_description" column names
        let inputIdx = headers.firstIndex(of: "input_text")
            ?? headers.firstIndex(of: "input_description")
        guard let inputIdx else {
            throw BenchmarkParseError.missingColumn("input_text")
        }

        let matchIdx = headers.firstIndex(of: "expected_match")
        guard let matchIdx else {
            throw BenchmarkParseError.missingColumn("expected_match")
        }

        let matchIdIdx = headers.firstIndex(of: "expected_match_id")
        let altMatchIdx = headers.firstIndex(of: "alternative_match")
        let categoryIdx = headers.firstIndex(of: "category")
        let difficultyIdx = headers.firstIndex(of: "difficulty")
        let instructionIdx = headers.firstIndex(of: "instruction")
        let notesIdx = headers.firstIndex(of: "notes")

        // Parse data rows
        var items: [BenchmarkItem] = []
        var categories = Set<String>()
        var difficultyDist: [String: Int] = [:]
        var noMatchCount = 0

        for i in 1..<dataLines.count {
            let row = CSVParser.parseCSVLine(dataLines[i], delimiter: delimiter)
            guard row.count > max(inputIdx, matchIdx) else { continue }

            let inputText = row[inputIdx].trimmingCharacters(in: .whitespaces)
            guard !inputText.isEmpty else { continue }

            let expectedRaw = row[matchIdx].trimmingCharacters(in: .whitespaces)
            let expectedMatch: String? = (expectedRaw.isEmpty || expectedRaw.uppercased() == "NO_MATCH")
                ? nil
                : expectedRaw

            let matchID = safeField(row, matchIdIdx)
            let altMatch = safeField(row, altMatchIdx)
            let category = safeField(row, categoryIdx)
            let difficultyStr = safeField(row, difficultyIdx)
            let instruction = safeField(row, instructionIdx)
            let notes = safeField(row, notesIdx)

            let difficulty = difficultyStr.flatMap { BenchmarkDifficulty(rawValue: $0.lowercased()) }

            if expectedMatch == nil { noMatchCount += 1 }
            if let cat = category { categories.insert(cat) }
            if let diff = difficultyStr { difficultyDist[diff.lowercased(), default: 0] += 1 }

            items.append(BenchmarkItem(
                id: UUID(),
                inputText: inputText,
                expectedMatch: expectedMatch,
                expectedMatchID: matchID,
                alternativeMatch: altMatch,
                category: category,
                difficulty: difficulty,
                instructionPreset: instruction,
                notes: notes
            ))
        }

        guard !items.isEmpty else {
            throw BenchmarkParseError.noDataRows
        }

        // Determine target database from metadata or filename
        let targetDB: BenchmarkTargetDB
        if let dbStr = (metadata["target_database"] ?? metadata["database"])?.lowercased() {
            targetDB = BenchmarkTargetDB(rawValue: dbStr) ?? .custom
        } else {
            let filename = url.lastPathComponent.lowercased()
            if filename.contains("dfg2") { targetDB = .dfg2 }
            else if filename.contains("foodb") { targetDB = .foodb }
            else { targetDB = .custom }
        }

        let dataset = BenchmarkDataset(
            id: UUID(),
            name: metadata["name"] ?? url.deletingPathExtension().lastPathComponent,
            version: metadata["benchmark_version"] ?? metadata["version"] ?? "1.0",
            targetDatabase: targetDB,
            description: metadata["description"],
            itemCount: items.count,
            noMatchCount: noMatchCount,
            categories: categories.sorted(),
            difficultyDistribution: difficultyDist,
            source: source,
            fileChecksum: checksum
        )

        logger.info("Parsed benchmark '\(dataset.name)': \(items.count) items, \(noMatchCount) no-match, target=\(targetDB.rawValue)")

        return ParseResult(dataset: dataset, items: items)
    }

    // MARK: - Helpers

    /// Safely extract and clean a field from a CSV row.
    private static func safeField(_ row: [String], _ index: Int?) -> String? {
        guard let idx = index, idx < row.count else { return nil }
        let value = row[idx].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

}

// MARK: - Errors

enum BenchmarkParseError: LocalizedError {
    case emptyFile
    case missingColumn(String)
    case noDataRows

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Benchmark CSV file is empty"
        case .missingColumn(let name):
            return "Required column '\(name)' not found in benchmark CSV"
        case .noDataRows:
            return "Benchmark CSV has no data rows"
        }
    }
}
