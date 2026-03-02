import Foundation

/// Wrapper for an imported delimited text file (CSV or TSV)
struct InputFile: Identifiable {
    let id: UUID
    let url: URL
    let columns: [String]
    let rowCount: Int
    let rows: [[String: String]]
    var displayNameOverride: String?
    let format: DataFileFormat

    var name: String {
        displayNameOverride ?? url.lastPathComponent
    }

    init(id: UUID = UUID(), url: URL, columns: [String], rowCount: Int, rows: [[String: String]], displayNameOverride: String? = nil, format: DataFileFormat = .csv) {
        self.id = id
        self.url = url
        self.columns = columns
        self.rowCount = rowCount
        self.rows = rows
        self.displayNameOverride = displayNameOverride
        self.format = format
    }

    /// Extract values from a specific column
    func values(for column: String) -> [String] {
        rows.compactMap { $0[column] }
    }
}
