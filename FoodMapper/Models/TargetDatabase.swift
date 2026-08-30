import Foundation
import CryptoKit
import Darwin

enum SecureFileAccess {
    static let storageDirectoryPermissions: mode_t = 0o700
    static let privateFilePermissions: mode_t = 0o600

    /// Opens a regular file after checking every path component with lstat. The
    /// returned descriptor remains the authority for the subsequent read.
    static func openRegularFile(
        _ url: URL,
        under root: URL? = nil,
        maximumSize: Int64? = nil,
        requireOwner: Bool = true
    ) throws -> Int32 {
        let target = try pathComponents(for: url)
        let parent: [String]
        let leaf: String
        if let root {
            let rootComponents = try pathComponents(for: root)
            guard target.starts(with: rootComponents), target.count > rootComponents.count else {
                throw MatchingError.databaseNotFound
            }
            try validateStorageDirectory(root)
            parent = rootComponents + Array(target.dropFirst(rootComponents.count).dropLast())
            leaf = target.last!
        } else {
            guard target.count > 1 else { throw MatchingError.databaseNotFound }
            parent = Array(target.dropLast())
            leaf = target.last!
        }

        let parentDescriptor = try openDirectory(components: parent)
        defer { close(parentDescriptor) }
        let descriptor = openat(parentDescriptor, leaf, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MatchingError.databaseNotFound }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1,
              (!requireOwner || info.st_uid == getuid()),
              (info.st_mode & S_IWOTH) == 0 else {
            close(descriptor)
            throw MatchingError.databaseNotFound
        }
        if let maximumSize, info.st_size > off_t(maximumSize) {
            close(descriptor)
            throw CustomDatabaseValidationError.importTooLarge(actual: Int64(info.st_size), limit: Int(maximumSize))
        }
        return descriptor
    }

    static func readBounded(
        descriptor: Int32,
        maximumSize: Int,
        cancellation: () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              initial.st_size >= 0,
              initial.st_size <= off_t(maximumSize) else {
            throw CustomDatabaseValidationError.importTooLarge(
                actual: max(0, Int64(initial.st_size)), limit: maximumSize
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var result = Data()
        result.reserveCapacity(Int(initial.st_size))
        while true {
            if cancellation() { throw CustomDatabaseValidationError.cancelled }
            let remaining = maximumSize - result.count
            guard remaining > 0 else {
                let probe = try handle.read(upToCount: 1)
                guard probe?.isEmpty ?? true else {
                    throw CustomDatabaseValidationError.importTooLarge(actual: Int64(maximumSize) + 1, limit: maximumSize)
                }
                break
            }
            guard let chunk = try handle.read(upToCount: min(1_048_576, remaining)), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        if cancellation() { throw CustomDatabaseValidationError.cancelled }
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_size == off_t(result.count),
              final.st_size <= off_t(maximumSize) else {
            throw MatchingError.databaseNotFound
        }
        return result
    }

    static func synchronize(_ url: URL, directory: Bool = false) throws {
        let descriptor: Int32
        if directory {
            descriptor = try openDirectory(components: pathComponents(for: url))
        } else {
            descriptor = try openRegularFile(url, requireOwner: false)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw MatchingError.databaseNotFound }
    }

    static func validateStorageDirectory(_ directory: URL) throws {
        let descriptor = try openDirectory(components: pathComponents(for: directory))
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw MatchingError.databaseNotFound
        }
    }

    static func safeLeaf(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
        !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    /// Atomically rename one validated directory entry to another. Both parent
    /// directories remain open for the operation, preventing a replacement of
    /// either ancestor between validation and renameat.
    static func rename(
        _ source: String, from sourceDirectory: URL,
        to destination: String, in destinationDirectory: URL
    ) throws {
        guard safeLeaf(source), safeLeaf(destination) else { throw MatchingError.databaseNotFound }
        let sourceDescriptor = try openDirectory(components: pathComponents(for: sourceDirectory))
        defer { close(sourceDescriptor) }
        let destinationDescriptor = try openDirectory(components: pathComponents(for: destinationDirectory))
        defer { close(destinationDescriptor) }
        guard renameat(sourceDescriptor, source, destinationDescriptor, destination) == 0 else {
            throw MatchingError.databaseNotFound
        }
        try synchronize(sourceDirectory, directory: true)
        if sourceDirectory.path != destinationDirectory.path {
            try synchronize(destinationDirectory, directory: true)
        }
    }

    static func createPrivateFile(_ leaf: String, in directory: URL) throws -> Int32 {
        guard safeLeaf(leaf) else { throw MatchingError.databaseNotFound }
        try validateStorageDirectory(directory)
        let descriptor = try openDirectory(components: pathComponents(for: directory))
        let file = openat(descriptor, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, privateFilePermissions)
        close(descriptor)
        guard file >= 0 else { throw MatchingError.databaseNotFound }
        return file
    }

    static func remove(_ leaf: String, from directory: URL, directoryEntry: Bool = false) throws {
        guard safeLeaf(leaf) else { throw MatchingError.databaseNotFound }
        let descriptor = try openDirectory(components: pathComponents(for: directory))
        defer { close(descriptor) }
        let flags: Int32 = directoryEntry ? AT_REMOVEDIR : 0
        guard unlinkat(descriptor, leaf, flags) == 0 else { throw MatchingError.databaseNotFound }
        try synchronize(directory, directory: true)
    }

    private static func pathComponents(for url: URL) throws -> [String] {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw MatchingError.databaseNotFound }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ safeLeaf($0) }) else {
            throw MatchingError.databaseNotFound
        }
        return components
    }

    /// Traverses from the root directory using directory descriptors. Every
    /// component is opened with O_NOFOLLOW, so an attacker cannot swap an
    /// ancestor between a validation pass and the next path-based open.
    private static func openDirectory(components: [String]) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw MatchingError.databaseNotFound }
        for component in components {
            guard safeLeaf(component) else {
                close(descriptor)
                throw MatchingError.databaseNotFound
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(descriptor)
            guard next >= 0 else { throw MatchingError.databaseNotFound }
            var info = stat()
            guard fstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                close(next)
                throw MatchingError.databaseNotFound
            }
            descriptor = next
        }
        return descriptor
    }
}

enum FoodMapperStorage {
    private final class RootStore: @unchecked Sendable {
        let lock = NSLock()
        var override: URL?
    }

    private static let rootStore = RootStore()
    private static let testApplicationSupportURL: URL = {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-xctest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    static var applicationSupportOverride: URL? {
        get {
            rootStore.lock.lock()
            defer { rootStore.lock.unlock() }
            return rootStore.override
        }
        set {
            rootStore.lock.lock()
            rootStore.override = newValue
            rootStore.lock.unlock()
        }
    }

    static var applicationSupportURL: URL {
        if let override = applicationSupportOverride { return override }
        // XCTest launches the host application before individual test setup.
        // Direct all app-level storage to a per-process directory so startup
        // discovery and GTE checks cannot touch the user's Application Support.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return testApplicationSupportURL
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }
}

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

    var hasSafeStorageIdentifier: Bool {
        Self.isSafeStorageIdentifier(id)
    }

    static func isSafeStorageIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }

    static func isSafeModelKey(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }

    /// URL for the self-contained CSV copy stored in app support
    var storedCsvURL: URL {
        Self.storageURL(databaseID: id, leaf: "\(id)_data.csv") ?? Self.invalidStorageURL
    }

    var csvURL: URL? {
        let stored = storedCsvURL
        return FileManager.default.fileExists(atPath: stored.path) ? stored : nil
    }

    var embeddingsURL: URL? {
        // Custom databases use model-versioned cacheURL(for:) instead
        nil
    }

    /// Directory where embedding cache files are stored
    var cacheDirectory: URL {
        let appSupport = FoodMapperStorage.applicationSupportURL
        return appSupport.appendingPathComponent("FoodMapper/CustomDBs")
    }

    private static var invalidStorageURL: URL {
        cacheDirectoryURL.appendingPathComponent("invalid", isDirectory: false)
    }

    private static var cacheDirectoryURL: URL {
        FoodMapperStorage.applicationSupportURL
            .appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
    }

    /// The sole construction point for custom-database storage paths. Callers
    /// must validate the identifier before deriving a leaf name.
    static func storageURL(databaseID: String, leaf: String) -> URL? {
        guard isSafeStorageIdentifier(databaseID), SecureFileAccess.safeLeaf(leaf),
              leaf.hasPrefix("\(databaseID)_") else { return nil }
        return cacheDirectoryURL.appendingPathComponent(leaf, isDirectory: false)
    }

    /// Cache file URL for a specific model key (model-versioned path)
    func cacheURL(for modelKey: String) -> URL {
        guard Self.isSafeModelKey(modelKey) else { return Self.invalidStorageURL }
        return Self.storageURL(databaseID: id, leaf: "\(id)_embeddings_\(modelKey).bin") ?? Self.invalidStorageURL
    }

    func cacheMetadataURL(for modelKey: String) -> URL {
        guard Self.isSafeModelKey(modelKey) else { return Self.invalidStorageURL }
        return Self.storageURL(databaseID: id, leaf: "\(id)_embeddings_\(modelKey).json") ?? Self.invalidStorageURL
    }

    /// Legacy unversioned cache URL (for migration/cleanup)
    var legacyCacheURL: URL {
        Self.storageURL(databaseID: id, leaf: "\(id)_embeddings.bin") ?? Self.invalidStorageURL
    }

    /// Find all embedding cache files for this database (any model version)
    var allCacheFiles: [URL] {
        guard hasSafeStorageIdentifier else { return [] }
        let dir = cacheDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let prefix = "\(id)_embeddings"
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "bin" }
    }

    var allCacheMetadataFiles: [URL] {
        guard hasSafeStorageIdentifier else { return [] }
        let dir = cacheDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let prefix = "\(id)_embeddings"
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
    }

    /// Whether any embeddings exist (any model version)
    var hasEmbeddings: Bool {
        embeddedModelKeys.contains { hasEmbeddings(for: $0) }
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
        guard hasSafeStorageIdentifier, Self.isSafeModelKey(modelKey),
              let expectedDimensions = Self.embeddingDimensions(for: modelKey),
              let sourceURL = csvURL,
              let validated = try? CustomDatabaseValidator.load(
                url: sourceURL, textColumn: textColumn, idColumn: idColumn
              ) else { return false }
        do {
            let metadataURL = cacheMetadataURL(for: modelKey)
            let metadataDescriptor = try SecureFileAccess.openRegularFile(
                metadataURL, under: cacheDirectory, maximumSize: 1_048_576
            )
            defer { close(metadataDescriptor) }
            let metadataData = try SecureFileAccess.readBounded(descriptor: metadataDescriptor, maximumSize: 1_048_576)
            let metadata = try JSONDecoder().decode(CustomDatabaseCacheMetadata.self, from: metadataData)
            guard metadata.version == CustomDatabaseCacheMetadata.currentVersion,
                  metadata.databaseID == id,
                  metadata.modelKey == modelKey,
                  metadata.sourceHash == validated.sourceHash,
                  metadata.schemaHash == validated.schemaHash,
                  metadata.rowOrderHash == validated.rowOrderHash,
                  metadata.textColumn == textColumn.trimmingCharacters(in: .whitespacesAndNewlines),
                  metadata.idColumn == idColumn?.trimmingCharacters(in: .whitespacesAndNewlines),
                  metadata.entryCount == validated.entries.count,
                  metadata.embeddingDimensions == expectedDimensions,
                  metadata.modelArtifactFingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                return false
            }
            let expectedSize = try MatchingEngine.expectedEmbeddingByteCount(
                entries: metadata.entryCount, dimensions: metadata.embeddingDimensions
            )
            let cacheDescriptor = try SecureFileAccess.openRegularFile(
                cacheURL(for: modelKey), under: cacheDirectory, maximumSize: Int64(expectedSize)
            )
            defer { close(cacheDescriptor) }
            let data = try SecureFileAccess.readBounded(descriptor: cacheDescriptor, maximumSize: expectedSize)
            guard data.count == expectedSize,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.embeddingDigest else {
                return false
            }
            return data.withUnsafeBytes { buffer in
                buffer.bindMemory(to: Float.self).allSatisfy { $0.isFinite }
            }
        } catch {
            return false
        }
    }

    private static func embeddingDimensions(for modelKey: String) -> Int? {
        switch modelKey {
        case "gte-large", "qwen3-emb-0.6b-4bit": return 1024
        case "qwen3-emb-4b-4bit": return 2560
        case "qwen3-emb-8b-4bit": return 4096
        default: return nil
        }
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
        try? FileManager.default.removeItem(at: cacheMetadataURL(for: modelKey))
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
        guard Self.isSafeStorageIdentifier(id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid database identifier")
        }
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
            guard CustomDatabase.isSafeStorageIdentifier(db.id),
                  CustomDatabase.isSafeModelKey(modelKey),
                  let versionedURL = CustomDatabase.storageURL(
                    databaseID: db.id, leaf: "\(db.id)_embeddings_\(modelKey).bin"
                  ) else { return false }
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
            guard CustomDatabase.isSafeStorageIdentifier(db.id) else { return keys }
            let dir = FoodMapperStorage.applicationSupportURL
                .appendingPathComponent("FoodMapper/CustomDBs", isDirectory: true)
            let prefix = "\(db.id)_embeddings_"
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "bin" {
                    let name = file.deletingPathExtension().lastPathComponent
                    if name.hasPrefix(prefix) {
                        let modelKey = String(name.dropFirst(prefix.count))
                        if CustomDatabase.isSafeModelKey(modelKey), modelKey != "gte-large" {
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
