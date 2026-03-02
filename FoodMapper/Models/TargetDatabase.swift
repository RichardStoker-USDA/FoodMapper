import Foundation

// MARK: - Food Database Protocol

/// Protocol for any food database (built-in or custom)
protocol FoodDatabase: Identifiable, Hashable {
    var id: String { get }
    var displayName: String { get }
    var itemCount: Int { get }
    var csvURL: URL? { get }
    var textColumn: String { get }
    var idColumn: String? { get }
    var embeddingsURL: URL? { get }
}

// MARK: - Built-in Databases

/// Built-in databases bundled with the app
enum BuiltInDatabase: String, CaseIterable, Identifiable, Codable, FoodDatabase {
    case fooDB = "FooDB"
    case dfg2 = "DFG2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fooDB: return "FooDB"
        case .dfg2: return "DFG2"
        }
    }

    var itemCount: Int {
        switch self {
        case .fooDB: return 9913
        case .dfg2: return 256
        }
    }

    var description: String {
        switch self {
        case .fooDB: return "Food constituent database (Wishart Lab, U of Alberta)"
        case .dfg2: return "Food glycan encyclopedia (UC Davis)"
        }
    }

    var csvFilename: String {
        switch self {
        case .fooDB: return "FooDB.csv"
        case .dfg2: return "DFG2.csv"
        }
    }

    var embeddingsFilename: String {
        switch self {
        case .fooDB: return "FooDB_embeddings.bin"
        case .dfg2: return "DFG2_embeddings.bin"
        }
    }

    var csvURL: URL? {
        // Built-in CSVs live in the Databases/ subdirectory within the bundle
        if let dbDir = ResourceBundle.databasesDirectory {
            let url = dbDir.appendingPathComponent(csvFilename)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        // Fallback: check bundle root
        return Bundle.main.url(
            forResource: csvFilename.replacingOccurrences(of: ".csv", with: ""),
            withExtension: "csv"
        )
    }

    var embeddingsURL: URL? {
        Bundle.main.url(
            forResource: embeddingsFilename.replacingOccurrences(of: ".bin", with: ""),
            withExtension: "bin"
        )
    }

    var textColumn: String {
        switch self {
        case .fooDB: return "orig_food_common_name"
        case .dfg2: return "simple_name"
        }
    }

    var idColumn: String? {
        switch self {
        case .fooDB: return "food_id"
        case .dfg2: return "sample_id"
        }
    }

    var columnNames: [String] {
        switch self {
        case .fooDB:
            return ["food_id", "food_name", "orig_food_id",
                    "orig_food_common_name_uncleaned", "orig_food_common_name",
                    "citation", "food_V2_ID"]
        case .dfg2:
            return ["sample_id", "simple_name"]
        }
    }

    var aboutDescription: String {
        switch self {
        case .fooDB:
            return "Food constituent database with 9,913 entries, maintained by the Wishart Research Group at the University of Alberta. Contains food names, identifiers, and chemical composition data."
        case .dfg2:
            return "Davis Food Glycopedia 2.0 -- an encyclopedia of carbohydrate structures (glycans) in 256 commonly consumed foods. Created by UC Davis researchers."
        }
    }
}

// MARK: - Built-in Database Preview Data

extension BuiltInDatabase {
    /// Actual values from bundled CSVs for instant preview (no file I/O needed)
    var sampleValues: [String] {
        switch self {
        case .fooDB:
            return [
                "kiwi", "cashew", "pineapple", "coffee", "avocado",
                "sweet potato", "watermelon", "black pepper", "rice",
                "olive"
            ]
        case .dfg2:
            return [
                "Whole Golden Del apple w/o seed", "Yellow banana flesh only",
                "Steamed Crown broccoli florets and stalk", "Creamy peanut butter (Skippy)",
                "Whole milk", "Brown rice (Mahatma)", "Chicken breast",
                "Roasted seaweed", "Cabernet Sauvignon wine", "Firm Tofu (Wildwood)"
            ]
        }
    }
}

// MARK: - Custom Database

/// User-defined custom database
struct CustomDatabase: Identifiable, Codable, Hashable, FoodDatabase {
    let id: String
    var displayName: String
    var csvPath: String
    var textColumn: String
    var idColumn: String?
    var itemCount: Int

    // Metadata fields
    var dateAdded: Date
    var embeddingDuration: TimeInterval?  // Seconds
    var cacheSize: Int64?                  // Bytes
    var fileFormat: DataFileFormat

    // Cached preview metadata (optional for backwards compatibility with existing JSON)
    var sampleValues: [String]?   // First 10 text column values for instant preview
    var columnNames: [String]?    // All column names from CSV header

    /// URL for the self-contained CSV copy stored in app support
    var storedCsvURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FoodMapper/CustomDBs/\(id)_data.csv")
    }

    var csvURL: URL? {
        // Prefer self-contained copy in app support
        let stored = storedCsvURL
        if FileManager.default.fileExists(atPath: stored.path) {
            return stored
        }
        // Fall back to original path (legacy databases before self-contained storage)
        return URL(fileURLWithPath: csvPath)
    }

    var embeddingsURL: URL? {
        // Custom databases use model-versioned cacheURL(for:) instead
        nil
    }

    /// Directory where embedding cache files are stored
    var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FoodMapper/CustomDBs")
    }

    /// Cache file URL for a specific model key (model-versioned path)
    func cacheURL(for modelKey: String) -> URL {
        cacheDirectory.appendingPathComponent("\(id)_embeddings_\(modelKey).bin")
    }

    /// Legacy unversioned cache URL (for migration/cleanup)
    var legacyCacheURL: URL {
        cacheDirectory.appendingPathComponent("\(id)_embeddings.bin")
    }

    /// Find all embedding cache files for this database (any model version)
    var allCacheFiles: [URL] {
        let dir = cacheDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let prefix = "\(id)_embeddings"
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "bin" }
    }

    /// Whether any embeddings exist (any model version)
    var hasEmbeddings: Bool {
        !allCacheFiles.isEmpty
    }

    /// Total size of all embedding cache files
    var totalCacheSize: Int64 {
        allCacheFiles.compactMap { url in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        }.reduce(0, +)
    }

    /// Model keys that have cached embeddings for this database.
    /// Extracted from file names matching pattern: {id}_embeddings_{modelKey}.bin
    var embeddedModelKeys: [String] {
        let prefix = "\(id)_embeddings_"
        return allCacheFiles.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(prefix) else { return nil }
            let modelKey = String(name.dropFirst(prefix.count))
            return modelKey.isEmpty ? nil : modelKey
        }
    }

    /// Whether embeddings exist for a specific model key
    func hasEmbeddings(for modelKey: String) -> Bool {
        FileManager.default.fileExists(atPath: cacheURL(for: modelKey).path)
    }

    /// Size of the embedding cache file for a specific model
    func cacheSize(for modelKey: String) -> Int64? {
        let url = cacheURL(for: modelKey)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    /// Delete embedding cache for a specific model
    func deleteEmbeddings(for modelKey: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: modelKey))
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, csvPath, textColumn, idColumn, itemCount
        case dateAdded, embeddingDuration, cacheSize, fileFormat
        case sampleValues, columnNames
    }

    init(
        id: String = UUID().uuidString,
        displayName: String,
        csvPath: String,
        textColumn: String,
        idColumn: String? = nil,
        itemCount: Int,
        dateAdded: Date = Date(),
        embeddingDuration: TimeInterval? = nil,
        cacheSize: Int64? = nil,
        fileFormat: DataFileFormat = .csv
    ) {
        self.id = id
        self.displayName = displayName
        self.csvPath = csvPath
        self.textColumn = textColumn
        self.idColumn = idColumn
        self.itemCount = itemCount
        self.dateAdded = dateAdded
        self.embeddingDuration = embeddingDuration
        self.cacheSize = cacheSize
        self.fileFormat = fileFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        csvPath = try container.decode(String.self, forKey: .csvPath)
        textColumn = try container.decode(String.self, forKey: .textColumn)
        idColumn = try container.decodeIfPresent(String.self, forKey: .idColumn)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        embeddingDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .embeddingDuration)
        cacheSize = try container.decodeIfPresent(Int64.self, forKey: .cacheSize)
        fileFormat = try container.decodeIfPresent(DataFileFormat.self, forKey: .fileFormat) ?? .csv
        sampleValues = try container.decodeIfPresent([String].self, forKey: .sampleValues)
        columnNames = try container.decodeIfPresent([String].self, forKey: .columnNames)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CustomDatabase, rhs: CustomDatabase) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Type-Erased Database Wrapper

/// Type-erased wrapper for any FoodDatabase
enum AnyDatabase: Identifiable, Hashable, Codable {
    case builtIn(BuiltInDatabase)
    case custom(CustomDatabase)

    var id: String {
        switch self {
        case .builtIn(let db): return "builtin_\(db.id)"
        case .custom(let db): return "custom_\(db.id)"
        }
    }

    var displayName: String {
        switch self {
        case .builtIn(let db): return db.displayName
        case .custom(let db): return db.displayName
        }
    }

    var itemCount: Int {
        switch self {
        case .builtIn(let db): return db.itemCount
        case .custom(let db): return db.itemCount
        }
    }

    var csvURL: URL? {
        switch self {
        case .builtIn(let db): return db.csvURL
        case .custom(let db): return db.csvURL
        }
    }

    var textColumn: String {
        switch self {
        case .builtIn(let db): return db.textColumn
        case .custom(let db): return db.textColumn
        }
    }

    var idColumn: String? {
        switch self {
        case .builtIn(let db): return db.idColumn
        case .custom(let db): return db.idColumn
        }
    }

    var columnNames: [String]? {
        switch self {
        case .builtIn(let db): return db.columnNames
        case .custom(let db): return db.columnNames
        }
    }

    var isBuiltIn: Bool {
        if case .builtIn = self { return true }
        return false
    }

    var asBuiltIn: BuiltInDatabase? {
        if case .builtIn(let db) = self { return db }
        return nil
    }

    var asCustom: CustomDatabase? {
        if case .custom(let db) = self { return db }
        return nil
    }

    /// Whether this database has cached embeddings for a specific model key.
    /// Checks bundle resources first (GTE-Large), then versioned cache in app support.
    func hasEmbeddings(for modelKey: String) -> Bool {
        switch self {
        case .builtIn(let db):
            if modelKey == "gte-large", db.embeddingsURL != nil {
                // Pre-computed embeddings bundled with app
                return true
            }
            // Check versioned cache in app support (covers all models including gte-large
            // when bundle embeddings aren't present)
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let versionedURL = appSupport.appendingPathComponent("FoodMapper/CustomDBs/\(db.id)_embeddings_\(modelKey).bin")
            return FileManager.default.fileExists(atPath: versionedURL.path)
        case .custom(let db):
            return db.hasEmbeddings(for: modelKey)
        }
    }

    /// Model keys with cached embeddings for this database
    var embeddedModelKeys: [String] {
        switch self {
        case .builtIn(let db):
            var keys: [String] = []
            if db.embeddingsURL != nil {
                keys.append("gte-large")
            }
            // Check versioned caches in app support
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("FoodMapper/CustomDBs")
            let prefix = "\(db.id)_embeddings_"
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "bin" {
                    let name = file.deletingPathExtension().lastPathComponent
                    if name.hasPrefix(prefix) {
                        let modelKey = String(name.dropFirst(prefix.count))
                        if !modelKey.isEmpty && modelKey != "gte-large" {
                            keys.append(modelKey)
                        }
                    }
                }
            }
            return keys
        case .custom(let db):
            return db.embeddedModelKeys
        }
    }
}

// MARK: - Legacy Type Alias

/// Type alias for backwards compatibility
typealias TargetDatabase = BuiltInDatabase

// MARK: - Database Entry

/// Entry from a target database
struct DatabaseEntry: Identifiable, Codable {
    let id: String
    let text: String
    let additionalFields: [String: String]

    init(id: String, text: String, additionalFields: [String: String] = [:]) {
        self.id = id
        self.text = text
        self.additionalFields = additionalFields
    }
}
