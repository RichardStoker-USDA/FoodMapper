import Foundation

/// Metadata for a locally stored input file (CSV or TSV)
struct StoredInputFile: Identifiable, Codable {
    let id: UUID
    var displayName: String
    let originalFileName: String
    let dateAdded: Date
    var lastUsed: Date
    var columnNames: [String]
    var rowCount: Int
    var fileSize: Int64
    var fileFormat: DataFileFormat

    enum CodingKeys: String, CodingKey {
        case id, displayName, originalFileName, dateAdded, lastUsed
        case columnNames, rowCount, fileSize, fileFormat
    }

    /// Path to the stored data copy (always _data.csv for backward compat)
    var csvURL: URL {
        StoredInputFile.storageDirectory
            .appendingPathComponent("\(id.uuidString)_data.csv")
    }

    /// Directory where all stored input files live
    static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("FoodMapper/InputFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Index file path
    static var indexURL: URL {
        storageDirectory.appendingPathComponent("inputfiles.json")
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        originalFileName: String,
        dateAdded: Date = Date(),
        lastUsed: Date = Date(),
        columnNames: [String],
        rowCount: Int,
        fileSize: Int64,
        fileFormat: DataFileFormat = .csv
    ) {
        self.id = id
        self.displayName = displayName
        self.originalFileName = originalFileName
        self.dateAdded = dateAdded
        self.lastUsed = lastUsed
        self.columnNames = columnNames
        self.rowCount = rowCount
        self.fileSize = fileSize
        self.fileFormat = fileFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        originalFileName = try container.decode(String.self, forKey: .originalFileName)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        columnNames = try container.decode([String].self, forKey: .columnNames)
        rowCount = try container.decode(Int.self, forKey: .rowCount)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        fileFormat = try container.decodeIfPresent(DataFileFormat.self, forKey: .fileFormat) ?? .csv
    }
}
