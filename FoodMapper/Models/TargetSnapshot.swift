import CryptoKit
import Darwin
import Foundation

/// Content-addressed target data retained with a matching session. The source
/// file is copied before matching starts, then the matching engine reads this
/// copy instead of a mutable custom-database file or app-bundle resource.
struct TargetSnapshotReference: Codable, Hashable, Sendable {
    static let digestLength = 64

    let digest: String
    let databaseIdentity: String
    let displayName: String
    let sourceKind: TargetSnapshotSourceKind

    var isValid: Bool {
        digest.count == Self.digestLength &&
        digest.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
    }
}

enum TargetSnapshotSourceKind: String, Codable, Hashable, Sendable {
    case builtIn
    case custom
}

/// Immutable metadata for an on-disk target snapshot. `digest` is the SHA-256
/// digest of `source.data`, not of a normalized representation.
struct TargetSnapshotManifest: Codable, Equatable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let digest: String
    let databaseIdentity: String
    let displayName: String
    let sourceKind: TargetSnapshotSourceKind
    let delimiter: String
    let header: [String]
    let idColumn: String?
    let textColumn: String
    let rowCount: Int
    let sourceOrder: String
    let selectedFields: [String]
    let sourceFilename: String
    let recordsDigest: String

    var format: DataFileFormat { delimiter == "\t" ? .tsv : .csv }
}

/// One source row. Values stay positional so duplicate headers cannot be
/// silently collapsed. Snapshot validation rejects duplicate headers before a
/// manifest is committed.
struct TargetSnapshotRecord: Codable, Hashable, Sendable {
    let sourceRow: Int
    let values: [String]

    func fields(header: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(header, values))
    }
}

enum TargetSnapshotMatchKind: Int, Codable, Comparable, Sendable {
    case exactID = 0
    case exactDescription = 1
    case prefix = 2
    case allTokens = 3
    case substring = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Search output has no similarity value. A manual selection records the row
/// and snapshot provenance rather than presenting a score that was never
/// computed for that choice.
struct TargetSnapshotSearchResult: Identifiable, Hashable, Sendable {
    let snapshot: TargetSnapshotReference
    let record: TargetSnapshotRecord
    let header: [String]
    let idColumn: String?
    let textColumn: String
    let kind: TargetSnapshotMatchKind

    var id: String { "\(snapshot.digest):\(record.sourceRow)" }

    var fields: [String: String] { record.fields(header: header) }
    var matchID: String? { idColumn.flatMap { fields[$0] } }
    var matchText: String { fields[textColumn] ?? "" }

    var selection: TargetSnapshotSelection {
        TargetSnapshotSelection(
            snapshotDigest: snapshot.digest,
            sourceRow: record.sourceRow,
            matchText: matchText,
            matchID: matchID,
            fields: fields
        )
    }
}

/// Persisted provenance for a manual full-target selection. No score belongs
/// here because this item may not have been retrieved or scored by the run.
struct TargetSnapshotSelection: Codable, Hashable, Sendable {
    let snapshotDigest: String
    let sourceRow: Int
    let matchText: String
    let matchID: String?
    let fields: [String: String]
}

struct TargetSnapshotDatabase: Hashable, Codable, FoodDatabase {
    let reference: TargetSnapshotReference
    let manifest: TargetSnapshotManifest

    var id: String { "snapshot_\(reference.digest)" }
    var displayName: String { manifest.displayName }
    var itemCount: Int { manifest.rowCount }
    // MatchingEngine reads snapshot records through TargetSnapshotStore. Do not
    // expose a path here because a generic FoodDatabase caller could bypass
    // manifest validation.
    var csvURL: URL? { nil }
    var textColumn: String { manifest.textColumn }
    var idColumn: String? { manifest.idColumn }
    var embeddingsURL: URL? { nil }
    var columnNames: [String] { manifest.header }
}

enum TargetSnapshotError: LocalizedError, Equatable {
    case sourceUnavailable
    case invalidReference
    case invalidManifest
    case malformedRow(row: Int, expected: Int, actual: Int)
    case duplicateHeader(String)
    case blankHeader(Int)
    case missingColumn(String)
    case oversizedRecord
    case sourceTooLarge(actual: Int64, limit: Int)
    case corruptSnapshot
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: return "Target database source is unavailable."
        case .invalidReference: return "Target snapshot reference is invalid."
        case .invalidManifest: return "Target snapshot manifest is invalid."
        case let .malformedRow(row, expected, actual): return "Target row \(row) has \(actual) values; expected \(expected)."
        case let .duplicateHeader(name): return "Target header \(name) appears more than once."
        case let .blankHeader(index): return "Target header \(index) is blank."
        case let .missingColumn(name): return "Target column \(name) is missing."
        case .oversizedRecord: return "A target row exceeds the snapshot record limit."
        case let .sourceTooLarge(actual, limit): return "Target database is \(actual) bytes; the snapshot limit is \(limit) bytes."
        case .corruptSnapshot: return "Target snapshot is incomplete or has changed on disk."
        case .cancelled: return "Target snapshot was cancelled."
        }
    }
}

/// Private storage for target rows used by a run. The on-disk source and the
/// JSON-lines row index are committed as one directory rename. Searches scan
/// the index off the main actor, retain only the requested result limit, and
/// preserve source order inside every search tier.
actor TargetSnapshotStore {
    static let sourceFilename = "source.data"
    static let recordsFilename = "records.ndjson"
    static let manifestFilename = "manifest.json"
    static let maxRecordBytes = 4 * 1_024 * 1_024
    static let maxManifestBytes = 1_024 * 1_024
    static let maxResults = 100

    static let shared = TargetSnapshotStore()

    private let root: URL
    private let maximumSourceBytes: Int

    init(
        root: URL = FoodMapperStorage.privateDirectory(["TargetSnapshots"]),
        maximumSourceBytes: Int = CustomDatabaseValidator.maximumImportBytes
    ) {
        self.root = root
        self.maximumSourceBytes = maximumSourceBytes
    }

    func capture(database: AnyDatabase, selectedFields: [String] = []) async throws -> TargetSnapshotDatabase {
        guard let sourceURL = database.csvURL else { throw TargetSnapshotError.sourceUnavailable }
        let sourceKind: TargetSnapshotSourceKind = database.isBuiltIn ? .builtIn : .custom
        return try await capture(
            sourceURL: sourceURL,
            databaseIdentity: database.id,
            displayName: database.displayName,
            sourceKind: sourceKind,
            textColumn: database.textColumn,
            idColumn: database.idColumn,
            selectedFields: selectedFields,
            requireSourceOwner: !database.isBuiltIn
        )
    }

    func capture(
        sourceURL: URL,
        databaseIdentity: String,
        displayName: String,
        sourceKind: TargetSnapshotSourceKind,
        textColumn: String,
        idColumn: String?,
        selectedFields: [String] = [],
        requireSourceOwner: Bool = true
    ) async throws -> TargetSnapshotDatabase {
        try Task.checkCancellation()
        try SecureFileAccess.validateStorageDirectory(root)
        try recover()

        let stageName = ".snapshot-stage-\(UUID().uuidString.lowercased())"
        try SecureFileAccess.createPrivateDirectory(stageName, in: root)
        let stage = root.appendingPathComponent(stageName, isDirectory: true)
        do {
            let digest = try await copySourceAndDigest(
                sourceURL: sourceURL,
                destination: stage,
                requireSourceOwner: requireSourceOwner
            )
            try Task.checkCancellation()
            let reference = TargetSnapshotReference(
                digest: digest,
                databaseIdentity: databaseIdentity,
                displayName: displayName,
                sourceKind: sourceKind
            )
            let destination = root.appendingPathComponent(reference.digest, isDirectory: true)
            if let existing = try? loadManifest(reference: reference), existing.digest == digest {
                try removeSnapshotDirectory(stageName)
                return TargetSnapshotDatabase(reference: reference, manifest: existing)
            }

            let manifest = try await index(
                stage: stage,
                reference: reference,
                textColumn: textColumn,
                idColumn: idColumn,
                selectedFields: selectedFields,
                sourceFilename: sourceURL.lastPathComponent
            )
            try writeManifest(manifest, in: stage)
            try validateSnapshot(reference: reference, directory: stage, expectedManifest: manifest)
            try Task.checkCancellation()
            try SecureFileAccess.rename(stageName, from: root, to: destination.lastPathComponent, in: root)
            return TargetSnapshotDatabase(reference: reference, manifest: manifest)
        } catch is CancellationError {
            try? removeSnapshotDirectory(stageName)
            throw TargetSnapshotError.cancelled
        } catch let error as TargetSnapshotError {
            try? removeSnapshotDirectory(stageName)
            throw error
        } catch {
            try? removeSnapshotDirectory(stageName)
            throw error
        }
    }

    func manifest(for reference: TargetSnapshotReference) throws -> TargetSnapshotManifest {
        try loadManifest(reference: reference)
    }

    func loadEntries(for database: TargetSnapshotDatabase) throws -> [DatabaseEntry] {
        let manifest = try loadManifest(reference: database.reference)
        guard manifest == database.manifest else { throw TargetSnapshotError.corruptSnapshot }
        let directory = try snapshotDirectory(for: database.reference)
        try verifySourceDigest(reference: database.reference, directory: directory)
        let recordsURL = directory.appendingPathComponent(Self.recordsFilename)
        let descriptor = try SecureFileAccess.openRegularFile(recordsURL, under: directory, maximumSize: Int64(maximumRecordsBytes(for: manifest)))
        defer { close(descriptor) }
        var reader = JSONLineReader(descriptor: descriptor, maximumLineBytes: Self.maxRecordBytes * 2)
        var entries: [DatabaseEntry] = []
        entries.reserveCapacity(manifest.rowCount)
        while let line = try reader.nextLine() {
            let record = try JSONDecoder().decode(TargetSnapshotRecord.self, from: line)
            guard record.values.count == manifest.header.count else { throw TargetSnapshotError.corruptSnapshot }
            let fields = record.fields(header: manifest.header)
            guard let text = fields[manifest.textColumn] else { throw TargetSnapshotError.corruptSnapshot }
            let id = manifest.idColumn.flatMap { fields[$0] } ?? generatedID(record: record)
            let additional = Dictionary(uniqueKeysWithValues: manifest.header.enumerated().compactMap { index, name in
                (name == manifest.textColumn || name == manifest.idColumn || record.values[index].isEmpty) ? nil : (name, record.values[index])
            })
            entries.append(DatabaseEntry(id: id, text: text, additionalFields: additional))
        }
        guard entries.count == manifest.rowCount else { throw TargetSnapshotError.corruptSnapshot }
        return entries
    }

    func search(
        reference: TargetSnapshotReference,
        query: String,
        limit: Int = TargetSnapshotStore.maxResults
    ) throws -> [TargetSnapshotSearchResult] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let resultLimit = min(max(1, limit), Self.maxResults)
        let manifest = try loadManifest(reference: reference)
        let directory = try snapshotDirectory(for: reference)
        try verifySourceDigest(reference: reference, directory: directory)
        let recordsURL = directory.appendingPathComponent(Self.recordsFilename)
        let descriptor = try SecureFileAccess.openRegularFile(recordsURL, under: directory, maximumSize: Int64(maximumRecordsBytes(for: manifest)))
        defer { close(descriptor) }
        var buckets = Dictionary(uniqueKeysWithValues: TargetSnapshotMatchKind.allCases.map { ($0, [TargetSnapshotSearchResult]()) })
        let tokens = Set(normalizedQuery.split(separator: " ").map(String.init))
        var reader = JSONLineReader(descriptor: descriptor, maximumLineBytes: Self.maxRecordBytes * 2)
        var scanned = 0
        while let line = try reader.nextLine() {
            if scanned & 0x3FF == 0, Task.isCancelled { throw TargetSnapshotError.cancelled }
            scanned += 1
            let record = try JSONDecoder().decode(TargetSnapshotRecord.self, from: line)
            guard record.values.count == manifest.header.count else { throw TargetSnapshotError.corruptSnapshot }
            let fields = record.fields(header: manifest.header)
            let description = Self.normalize(fields[manifest.textColumn] ?? "")
            let id = manifest.idColumn.flatMap { fields[$0] }.map(Self.normalize) ?? ""
            let kind: TargetSnapshotMatchKind?
            if id == normalizedQuery {
                kind = .exactID
            } else if description == normalizedQuery {
                kind = .exactDescription
            } else if description.hasPrefix(normalizedQuery) {
                kind = .prefix
            } else if !tokens.isEmpty && tokens.allSatisfy({ description.contains($0) }) {
                kind = .allTokens
            } else if description.contains(normalizedQuery) {
                kind = .substring
            } else {
                kind = nil
            }
            guard let kind, buckets[kind, default: []].count < resultLimit else { continue }
            buckets[kind, default: []].append(TargetSnapshotSearchResult(
                snapshot: reference, record: record, header: manifest.header,
                idColumn: manifest.idColumn, textColumn: manifest.textColumn, kind: kind
            ))
        }
        return TargetSnapshotMatchKind.allCases.flatMap { buckets[$0, default: []] }
    }

    func recover() throws {
        try SecureFileAccess.validateStorageDirectory(root)
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for child in children where child.lastPathComponent.hasPrefix(".snapshot-stage-") {
            try? removeSnapshotDirectory(child.lastPathComponent)
        }
        for child in children where !child.lastPathComponent.hasPrefix(".") {
            let digest = child.lastPathComponent
            guard TargetSnapshotReference(digest: digest, databaseIdentity: "", displayName: "", sourceKind: .custom).isValid else {
                try? removeSnapshotDirectory(digest)
                continue
            }
            let reference = TargetSnapshotReference(digest: digest, databaseIdentity: "", displayName: "", sourceKind: .custom)
            if (try? loadManifest(reference: reference)) == nil {
                try? removeSnapshotDirectory(digest)
            }
        }
    }

    private func copySourceAndDigest(sourceURL: URL, destination: URL, requireSourceOwner: Bool) async throws -> String {
        let source = try SecureFileAccess.openRegularFile(sourceURL, maximumSize: Int64(maximumSourceBytes), requireOwner: requireSourceOwner)
        defer { close(source) }
        var before = stat()
        guard fstat(source, &before) == 0 else { throw TargetSnapshotError.sourceUnavailable }
        let output = try SecureFileAccess.createPrivateFile(Self.sourceFilename, in: destination)
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        var hasher = SHA256()
        var copied = 0
        let reader = FileHandle(fileDescriptor: source, closeOnDealloc: false)
        do {
            while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
                if Task.isCancelled { throw TargetSnapshotError.cancelled }
                let next = copied + chunk.count
                guard next <= maximumSourceBytes else {
                    throw TargetSnapshotError.sourceTooLarge(actual: Int64(next), limit: maximumSourceBytes)
                }
                hasher.update(data: chunk)
                try writer.write(contentsOf: chunk)
                copied = next
            }
            try writer.synchronize()
        } catch {
            try? writer.close()
            throw error
        }
        try writer.close()
        var after = stat()
        guard fstat(source, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              copied == Int(after.st_size) else {
            throw TargetSnapshotError.sourceUnavailable
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func index(
        stage: URL,
        reference: TargetSnapshotReference,
        textColumn: String,
        idColumn: String?,
        selectedFields: [String],
        sourceFilename: String
    ) async throws -> TargetSnapshotManifest {
        let sourceURL = stage.appendingPathComponent(Self.sourceFilename)
        let source = try SecureFileAccess.openRegularFile(sourceURL, under: stage, maximumSize: Int64(maximumSourceBytes))
        defer { close(source) }
        var rawReader = LogicalRecordReader(descriptor: source, maximumRecordBytes: Self.maxRecordBytes)
        guard let headerData = try rawReader.nextRecord(),
              let headerText = String(data: headerData, encoding: .utf8) else {
            throw TargetSnapshotError.invalidManifest
        }
        let format = DataFileFormat.detect(from: CSVParser.stripBOM(headerText))
        let header = try parseRecord(headerData, delimiter: format.delimiter)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !header.isEmpty else { throw TargetSnapshotError.invalidManifest }
        for (index, field) in header.enumerated() where field.isEmpty {
            throw TargetSnapshotError.blankHeader(index + 1)
        }
        var names = Set<String>()
        for field in header {
            let key = Self.normalize(field)
            guard names.insert(key).inserted else { throw TargetSnapshotError.duplicateHeader(field) }
        }
        let cleanTextColumn = textColumn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard header.contains(cleanTextColumn) else { throw TargetSnapshotError.missingColumn(cleanTextColumn) }
        let cleanIDColumn = idColumn?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanIDColumn, !cleanIDColumn.isEmpty, !header.contains(cleanIDColumn) {
            throw TargetSnapshotError.missingColumn(cleanIDColumn)
        }
        let allSelected = selectedFields.isEmpty ? header : selectedFields
        guard allSelected.allSatisfy(header.contains) else {
            throw TargetSnapshotError.invalidManifest
        }

        let recordsDescriptor = try SecureFileAccess.createPrivateFile(Self.recordsFilename, in: stage)
        let records = FileHandle(fileDescriptor: recordsDescriptor, closeOnDealloc: true)
        var rowCount = 0
        var recordsHasher = SHA256()
        do {
            while let raw = try rawReader.nextRecord() {
                if Task.isCancelled { throw TargetSnapshotError.cancelled }
                let values = try parseRecord(raw, delimiter: format.delimiter)
                let sourceRow = rowCount + 2
                guard values.count == header.count else {
                    throw TargetSnapshotError.malformedRow(row: sourceRow, expected: header.count, actual: values.count)
                }
                let record = TargetSnapshotRecord(sourceRow: sourceRow, values: values)
                var encoded = try JSONEncoder().encode(record)
                encoded.append(0x0A)
                recordsHasher.update(data: encoded)
                try records.write(contentsOf: encoded)
                rowCount += 1
            }
            try records.synchronize()
            try records.close()
        } catch {
            try? records.close()
            throw error
        }
        guard rowCount > 0 else { throw TargetSnapshotError.invalidManifest }
        return TargetSnapshotManifest(
            version: TargetSnapshotManifest.currentVersion,
            digest: reference.digest,
            databaseIdentity: reference.databaseIdentity,
            displayName: reference.displayName,
            sourceKind: reference.sourceKind,
            delimiter: format.delimiterString,
            header: header,
            idColumn: cleanIDColumn?.isEmpty == true ? nil : cleanIDColumn,
            textColumn: cleanTextColumn,
            rowCount: rowCount,
            sourceOrder: "ascending-row",
            selectedFields: allSelected,
            sourceFilename: sourceFilename,
            recordsDigest: recordsHasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func parseRecord(_ data: Data, delimiter: Character) throws -> [String] {
        guard let string = String(data: data, encoding: .utf8) else { throw TargetSnapshotError.invalidManifest }
        let records = try CSVParser.parseRecords(content: CSVParser.stripBOM(string), delimiter: delimiter)
        guard records.count == 1, let values = records.first else { throw TargetSnapshotError.invalidManifest }
        return values
    }

    private func writeManifest(_ manifest: TargetSnapshotManifest, in directory: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= Self.maxManifestBytes else { throw TargetSnapshotError.invalidManifest }
        try SecureFileAccess.writePrivateFile(data, named: Self.manifestFilename, in: directory)
    }

    private func loadManifest(reference: TargetSnapshotReference) throws -> TargetSnapshotManifest {
        let directory = try snapshotDirectory(for: reference)
        let url = directory.appendingPathComponent(Self.manifestFilename)
        let descriptor = try SecureFileAccess.openRegularFile(url, under: directory, maximumSize: Int64(Self.maxManifestBytes))
        defer { close(descriptor) }
        let data = try SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: Self.maxManifestBytes)
        let manifest = try JSONDecoder().decode(TargetSnapshotManifest.self, from: data)
        guard manifest.version == TargetSnapshotManifest.currentVersion,
              manifest.digest == reference.digest,
              TargetSnapshotReference(digest: manifest.digest, databaseIdentity: manifest.databaseIdentity, displayName: manifest.displayName, sourceKind: manifest.sourceKind).isValid,
              manifest.rowCount > 0,
              manifest.rowCount <= 1_000_000,
              manifest.delimiter == "," || manifest.delimiter == "\t",
              !manifest.header.isEmpty,
              manifest.header.count <= 4_096,
              manifest.header.contains(manifest.textColumn),
              manifest.idColumn.map(manifest.header.contains) ?? true,
              manifest.sourceOrder == "ascending-row",
              manifest.recordsDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw TargetSnapshotError.invalidManifest
        }
        return manifest
    }

    private func validateSnapshot(reference: TargetSnapshotReference, directory: URL, expectedManifest: TargetSnapshotManifest) throws {
        try verifySourceDigest(reference: reference, directory: directory)
        let manifestDescriptor = try SecureFileAccess.openRegularFile(
            directory.appendingPathComponent(Self.manifestFilename),
            under: directory,
            maximumSize: Int64(Self.maxManifestBytes)
        )
        defer { close(manifestDescriptor) }
        let manifestData = try SecureFileAccess.readBounded(
            descriptor: manifestDescriptor,
            maximumSize: Self.maxManifestBytes
        )
        let manifest = try JSONDecoder().decode(TargetSnapshotManifest.self, from: manifestData)
        guard manifest == expectedManifest else { throw TargetSnapshotError.corruptSnapshot }
        let records = directory.appendingPathComponent(Self.recordsFilename)
        let recordsDescriptor = try SecureFileAccess.openRegularFile(records, under: directory, maximumSize: Int64(maximumRecordsBytes(for: manifest)))
        defer { close(recordsDescriptor) }
        let recordsDigest = try digest(descriptor: recordsDescriptor)
        guard recordsDigest == manifest.recordsDigest else { throw TargetSnapshotError.corruptSnapshot }
    }

    private func verifySourceDigest(reference: TargetSnapshotReference, directory: URL) throws {
        let source = directory.appendingPathComponent(Self.sourceFilename)
        let descriptor = try SecureFileAccess.openRegularFile(
            source,
            under: directory,
            maximumSize: Int64(maximumSourceBytes)
        )
        defer { close(descriptor) }
        guard try digest(descriptor: descriptor) == reference.digest else {
            throw TargetSnapshotError.corruptSnapshot
        }
    }

    private func digest(descriptor: Int32) throws -> String {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            if Task.isCancelled { throw TargetSnapshotError.cancelled }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func snapshotDirectory(for reference: TargetSnapshotReference) throws -> URL {
        guard reference.isValid else { throw TargetSnapshotError.invalidReference }
        let directory = root.appendingPathComponent(reference.digest, isDirectory: true)
        try SecureFileAccess.validateStorageDirectory(directory)
        return directory
    }

    private func maximumRecordsBytes(for manifest: TargetSnapshotManifest) -> Int {
        min(maximumSourceBytes * 3, 2 * 1_024 * 1_024 * 1_024)
    }

    private func removeSnapshotDirectory(_ leaf: String) throws {
        guard SecureFileAccess.safeLeaf(leaf), leaf.hasPrefix(".snapshot-stage-") || leaf.count == TargetSnapshotReference.digestLength else {
            throw TargetSnapshotError.invalidReference
        }
        let directory = root.appendingPathComponent(leaf, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try SecureFileAccess.removePrivateDirectoryTree(leaf, from: root)
    }

    private func generatedID(record: TargetSnapshotRecord) -> String {
        let payload = record.values.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return "row-\(digest.prefix(24))"
    }

    static func normalize(_ value: String) -> String {
        let folded = value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined().split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }
}

private struct LogicalRecordReader {
    private let descriptor: Int32
    private let maximumRecordBytes: Int
    private var buffer = Data()
    private var offset = 0
    private var record = Data()
    private var quoted = false
    private var afterQuote = false

    init(descriptor: Int32, maximumRecordBytes: Int) {
        self.descriptor = descriptor
        self.maximumRecordBytes = maximumRecordBytes
    }

    mutating func nextRecord() throws -> Data? {
        while true {
            if offset == buffer.count {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                guard let next = try handle.read(upToCount: 65_536), !next.isEmpty else {
                    guard !record.isEmpty else { return nil }
                    if afterQuote {
                        quoted = false
                        afterQuote = false
                    }
                    guard !quoted else { throw CSVParseError.unterminatedQuotedField }
                    defer { record.removeAll(keepingCapacity: true) }
                    return record
                }
                buffer = next
                offset = 0
            }
            let byte = buffer[offset]
            offset += 1
            if byte == 0x22 {
                if quoted && !afterQuote {
                    afterQuote = true
                } else if quoted && afterQuote {
                    afterQuote = false
                } else {
                    quoted = true
                }
                record.append(byte)
            } else if quoted && afterQuote {
                if byte == 0x2C || byte == 0x09 {
                    quoted = false
                    afterQuote = false
                    record.append(byte)
                } else if byte == 0x0A {
                    quoted = false
                    afterQuote = false
                    if record.last == 0x0D { record.removeLast() }
                    defer { record.removeAll(keepingCapacity: true) }
                    return record
                } else if byte == 0x0D {
                    quoted = false
                    afterQuote = false
                    record.append(byte)
                } else {
                    throw CSVParseError.unexpectedCharacterAfterClosingQuote(Character(UnicodeScalar(byte)))
                }
            } else if byte == 0x0A && !quoted {
                if record.last == 0x0D { record.removeLast() }
                defer { record.removeAll(keepingCapacity: true); afterQuote = false }
                return record
            } else {
                record.append(byte)
            }
            guard record.count <= maximumRecordBytes else { throw TargetSnapshotError.oversizedRecord }
        }
    }
}

private struct JSONLineReader {
    private let descriptor: Int32
    private let maximumLineBytes: Int
    private var buffer = Data()
    private var offset = 0
    private var line = Data()

    init(descriptor: Int32, maximumLineBytes: Int) {
        self.descriptor = descriptor
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func nextLine() throws -> Data? {
        while true {
            if offset == buffer.count {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                guard let next = try handle.read(upToCount: 65_536), !next.isEmpty else {
                    guard !line.isEmpty else { return nil }
                    defer { line.removeAll(keepingCapacity: true) }
                    return line
                }
                buffer = next
                offset = 0
            }
            let byte = buffer[offset]
            offset += 1
            if byte == 0x0A {
                defer { line.removeAll(keepingCapacity: true) }
                return line
            }
            line.append(byte)
            guard line.count <= maximumLineBytes else { throw TargetSnapshotError.corruptSnapshot }
        }
    }
}

private extension TargetSnapshotMatchKind {
    static var allCases: [TargetSnapshotMatchKind] { [.exactID, .exactDescription, .prefix, .allTokens, .substring] }
}
