import CryptoKit
import Darwin
import Foundation

/// Content-addressed target data retained with a matching session. The source
/// file is copied before matching starts, then the matching engine reads this
/// copy instead of a mutable custom-database file or app-bundle resource.
struct TargetSnapshotReference: Codable, Hashable, Sendable {
    static let digestLength = 64

    let digest: String
    /// Digest of the copied source bytes. `digest` also binds the matching
    /// policy, so callers can distinguish two snapshots of identical bytes.
    let sourceDigest: String
    let databaseIdentity: String
    let displayName: String
    let sourceKind: TargetSnapshotSourceKind

    init(
        digest: String,
        sourceDigest: String? = nil,
        databaseIdentity: String,
        displayName: String,
        sourceKind: TargetSnapshotSourceKind
    ) {
        self.digest = digest
        self.sourceDigest = sourceDigest ?? digest
        self.databaseIdentity = databaseIdentity
        self.displayName = displayName
        self.sourceKind = sourceKind
    }

    var isValid: Bool {
        [digest, sourceDigest].allSatisfy {
            $0.count == Self.digestLength &&
                $0.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
        }
    }
}

enum TargetSnapshotSourceKind: String, Codable, Hashable, Sendable {
    case builtIn
    case custom
}

/// Immutable metadata for an on-disk target snapshot. `sourceDigest` is the
/// SHA-256 digest of `source.data`; `digest` also binds that source to the
/// database and matching-column policy.
struct TargetSnapshotManifest: Codable, Equatable, Hashable, Sendable {
    static let currentVersion = 2

    let version: Int
    let digest: String
    let sourceDigest: String
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
    case tooManyRows(limit: Int)
    case invalidSelection
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
        case let .tooManyRows(limit): return "Target database exceeds the snapshot row limit of \(limit)."
        case .invalidSelection: return "The selected target row is not part of this snapshot."
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
    static let maxHeaderColumns = 4_096
    static let maxRows = 1_000_000
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
            let sourceDigest = try await copySourceAndDigest(
                sourceURL: sourceURL,
                destination: stage,
                requireSourceOwner: requireSourceOwner
            )
            try Task.checkCancellation()
            let manifest = try await index(
                stage: stage,
                sourceDigest: sourceDigest,
                databaseIdentity: databaseIdentity,
                displayName: displayName,
                sourceKind: sourceKind,
                textColumn: textColumn,
                idColumn: idColumn,
                selectedFields: selectedFields,
                sourceFilename: sourceURL.lastPathComponent
            )
            let reference = TargetSnapshotReference(
                digest: manifest.digest,
                sourceDigest: sourceDigest,
                databaseIdentity: databaseIdentity,
                displayName: displayName,
                sourceKind: sourceKind
            )
            let destination = root.appendingPathComponent(reference.digest, isDirectory: true)
            if let existing = try? loadManifest(reference: reference), existing == manifest {
                try removeSnapshotDirectory(stageName)
                return TargetSnapshotDatabase(reference: reference, manifest: existing)
            }
            try writeManifest(manifest, in: stage)
            try validateSnapshot(reference: reference, directory: stage, expectedManifest: manifest)
            // There is no suspension point between this check and rename. The
            // rename is the commit boundary: cancellation before it removes the
            // stage, cancellation after it returns a complete snapshot.
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
        let descriptor = try openVerifiedRecords(manifest: manifest, directory: directory)
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
        let descriptor = try openVerifiedRecords(manifest: manifest, directory: directory)
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
            let directory = root.appendingPathComponent(digest, isDirectory: true)
            let manifestURL = directory.appendingPathComponent(Self.manifestFilename)
            guard let descriptor = try? SecureFileAccess.openRegularFile(manifestURL, under: directory, maximumSize: Int64(Self.maxManifestBytes)) else {
                try? removeSnapshotDirectory(digest)
                continue
            }
            let manifestData = try? SecureFileAccess.readBounded(descriptor: descriptor, maximumSize: Self.maxManifestBytes)
            close(descriptor)
            guard let manifestData,
                  let manifest = try? JSONDecoder().decode(TargetSnapshotManifest.self, from: manifestData),
                  manifest.digest == digest else {
                try? removeSnapshotDirectory(digest)
                continue
            }
            let reference = TargetSnapshotReference(digest: digest, sourceDigest: manifest.sourceDigest, databaseIdentity: manifest.databaseIdentity, displayName: manifest.displayName, sourceKind: manifest.sourceKind)
            if (try? loadManifest(reference: reference)) == nil {
                try? removeSnapshotDirectory(digest)
            }
        }
    }

    /// Delete completed snapshots that no saved session or active operation can
    /// reference. Capture and reconciliation are actor-isolated, so a capture
    /// cannot be removed between its commit and the caller retaining it.
    func reconcile(retaining references: Set<TargetSnapshotReference>) throws {
        try recover()
        let retained = Set(references.map(\.digest))
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for child in children where !child.lastPathComponent.hasPrefix(".") {
            let leaf = child.lastPathComponent
            guard TargetSnapshotReference(digest: leaf, databaseIdentity: "", displayName: "", sourceKind: .custom).isValid else { continue }
            if !retained.contains(leaf) { try? removeSnapshotDirectory(leaf) }
        }
    }

    /// Validate a persisted manual selection against its immutable row before
    /// it is accepted by review storage or an exporter.
    func validate(selection: TargetSnapshotSelection, reference: TargetSnapshotReference) throws {
        guard selection.snapshotDigest == reference.digest else { throw TargetSnapshotError.invalidSelection }
        let manifest = try loadManifest(reference: reference)
        let directory = try snapshotDirectory(for: reference)
        try verifySourceDigest(reference: reference, directory: directory)
        let descriptor = try openVerifiedRecords(manifest: manifest, directory: directory)
        defer { close(descriptor) }
        var reader = JSONLineReader(descriptor: descriptor, maximumLineBytes: Self.maxRecordBytes * 2)
        while let line = try reader.nextLine() {
            let record = try JSONDecoder().decode(TargetSnapshotRecord.self, from: line)
            guard record.values.count == manifest.header.count else { throw TargetSnapshotError.corruptSnapshot }
            guard record.sourceRow != selection.sourceRow || record.fields(header: manifest.header) == selection.fields else {
                let fields = record.fields(header: manifest.header)
                guard selection.matchText == fields[manifest.textColumn],
                      selection.matchID == manifest.idColumn.flatMap({ fields[$0] }) else {
                    throw TargetSnapshotError.invalidSelection
                }
                return
            }
        }
        throw TargetSnapshotError.invalidSelection
    }

    func validate(selections: [TargetSnapshotSelection], reference: TargetSnapshotReference?) throws {
        guard !selections.isEmpty else { return }
        guard let reference else { throw TargetSnapshotError.invalidSelection }
        for selection in selections {
            try validate(selection: selection, reference: reference)
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
        sourceDigest: String,
        databaseIdentity: String,
        displayName: String,
        sourceKind: TargetSnapshotSourceKind,
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
        rawReader.setDelimiter(format.delimiter)
        let header = try parseRecord(headerData, delimiter: format.delimiter)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !header.isEmpty else { throw TargetSnapshotError.invalidManifest }
        guard header.count <= Self.maxHeaderColumns else { throw TargetSnapshotError.invalidManifest }
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
        guard allSelected.count <= Self.maxHeaderColumns,
              Set(allSelected).count == allSelected.count,
              allSelected.allSatisfy(header.contains) else {
            throw TargetSnapshotError.invalidManifest
        }

        let recordsDescriptor = try SecureFileAccess.createPrivateFile(Self.recordsFilename, in: stage)
        let records = FileHandle(fileDescriptor: recordsDescriptor, closeOnDealloc: true)
        var rowCount = 0
        var recordsBytes = 0
        var recordsHasher = SHA256()
        do {
            while let raw = try rawReader.nextRecord() {
                if Task.isCancelled { throw TargetSnapshotError.cancelled }
                // `CSVParser.parseRecords` discards blank records. Keep that
                // acceptance rule here so snapshot indexing and normal imports
                // describe the same target table.
                if raw.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
                let values = try parseRecord(raw, delimiter: format.delimiter)
                let sourceRow = rowCount + 2
                guard values.count == header.count else {
                    throw TargetSnapshotError.malformedRow(row: sourceRow, expected: header.count, actual: values.count)
                }
                let record = TargetSnapshotRecord(sourceRow: sourceRow, values: values)
                var encoded = try JSONEncoder().encode(record)
                encoded.append(0x0A)
                let nextBytes = recordsBytes + encoded.count
                guard nextBytes <= maximumRecordsBytes(forSourceBytes: maximumSourceBytes) else {
                    throw TargetSnapshotError.oversizedRecord
                }
                recordsHasher.update(data: encoded)
                try records.write(contentsOf: encoded)
                rowCount += 1
                recordsBytes = nextBytes
                guard rowCount <= Self.maxRows else { throw TargetSnapshotError.tooManyRows(limit: Self.maxRows) }
            }
            try records.synchronize()
            try records.close()
        } catch {
            try? records.close()
            throw error
        }
        guard rowCount > 0 else { throw TargetSnapshotError.invalidManifest }
        let digest = Self.snapshotDigest(
            sourceDigest: sourceDigest,
            databaseIdentity: databaseIdentity,
            displayName: displayName,
            sourceKind: sourceKind,
            delimiter: format.delimiterString,
            textColumn: cleanTextColumn,
            idColumn: cleanIDColumn?.isEmpty == true ? nil : cleanIDColumn,
            selectedFields: allSelected,
            header: header
        )
        return TargetSnapshotManifest(
            version: TargetSnapshotManifest.currentVersion,
            digest: digest,
            sourceDigest: sourceDigest,
            databaseIdentity: databaseIdentity,
            displayName: displayName,
            sourceKind: sourceKind,
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

    private struct SnapshotPolicy: Encodable {
        let sourceDigest: String
        let databaseIdentity: String
        let displayName: String
        let sourceKind: TargetSnapshotSourceKind
        let delimiter: String
        let textColumn: String
        let idColumn: String?
        let selectedFields: [String]
        let header: [String]
    }

    private static func snapshotDigest(
        sourceDigest: String,
        databaseIdentity: String,
        displayName: String,
        sourceKind: TargetSnapshotSourceKind,
        delimiter: String,
        textColumn: String,
        idColumn: String?,
        selectedFields: [String],
        header: [String]
    ) -> String {
        let policy = SnapshotPolicy(
            sourceDigest: sourceDigest,
            databaseIdentity: databaseIdentity,
            displayName: displayName,
            sourceKind: sourceKind,
            delimiter: delimiter,
            textColumn: textColumn,
            idColumn: idColumn,
            selectedFields: selectedFields,
            header: header
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(policy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
              manifest.sourceDigest == reference.sourceDigest,
              manifest.databaseIdentity == reference.databaseIdentity,
              manifest.displayName == reference.displayName,
              manifest.sourceKind == reference.sourceKind,
              TargetSnapshotReference(digest: manifest.digest, sourceDigest: manifest.sourceDigest, databaseIdentity: manifest.databaseIdentity, displayName: manifest.displayName, sourceKind: manifest.sourceKind).isValid,
              manifest.rowCount > 0,
              manifest.rowCount <= Self.maxRows,
              manifest.delimiter == "," || manifest.delimiter == "\t",
              !manifest.header.isEmpty,
              manifest.header.count <= Self.maxHeaderColumns,
              manifest.header.contains(manifest.textColumn),
              manifest.idColumn.map(manifest.header.contains) ?? true,
              manifest.selectedFields.count <= Self.maxHeaderColumns,
              Set(manifest.selectedFields).count == manifest.selectedFields.count,
              manifest.selectedFields.allSatisfy(manifest.header.contains),
              manifest.sourceOrder == "ascending-row",
              manifest.recordsDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw TargetSnapshotError.invalidManifest
        }
        guard Self.snapshotDigest(
            sourceDigest: manifest.sourceDigest,
            databaseIdentity: manifest.databaseIdentity,
            displayName: manifest.displayName,
            sourceKind: manifest.sourceKind,
            delimiter: manifest.delimiter,
            textColumn: manifest.textColumn,
            idColumn: manifest.idColumn,
            selectedFields: manifest.selectedFields,
            header: manifest.header
        ) == manifest.digest else { throw TargetSnapshotError.invalidManifest }
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
        try verifyRecords(manifest: manifest, directory: directory)
    }

    private func verifySourceDigest(reference: TargetSnapshotReference, directory: URL) throws {
        let source = directory.appendingPathComponent(Self.sourceFilename)
        let descriptor = try SecureFileAccess.openRegularFile(
            source,
            under: directory,
            maximumSize: Int64(maximumSourceBytes)
        )
        defer { close(descriptor) }
        guard try digest(descriptor: descriptor) == reference.sourceDigest else {
            throw TargetSnapshotError.corruptSnapshot
        }
    }

    /// Check the serialized index on every read. The records digest prevents a
    /// row substitution, and the source-row sequence prevents a reordered or
    /// gapped index from being presented as the captured target table.
    private func verifyRecords(manifest: TargetSnapshotManifest, directory: URL) throws {
        let recordsURL = directory.appendingPathComponent(Self.recordsFilename)
        let descriptor = try SecureFileAccess.openRegularFile(
            recordsURL,
            under: directory,
            maximumSize: Int64(maximumRecordsBytes(for: manifest))
        )
        defer { close(descriptor) }
        try verifyRecords(manifest: manifest, descriptor: descriptor)
    }

    private func openVerifiedRecords(manifest: TargetSnapshotManifest, directory: URL) throws -> Int32 {
        let recordsURL = directory.appendingPathComponent(Self.recordsFilename)
        let descriptor = try SecureFileAccess.openRegularFile(
            recordsURL,
            under: directory,
            maximumSize: Int64(maximumRecordsBytes(for: manifest))
        )
        do {
            try verifyRecords(manifest: manifest, descriptor: descriptor)
            guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw TargetSnapshotError.corruptSnapshot }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func verifyRecords(manifest: TargetSnapshotManifest, descriptor: Int32) throws {
        var reader = JSONLineReader(descriptor: descriptor, maximumLineBytes: Self.maxRecordBytes * 2)
        var hasher = SHA256()
        var expectedSourceRow = 2
        var count = 0
        while let line = try reader.nextLine() {
            if Task.isCancelled { throw TargetSnapshotError.cancelled }
            let record = try JSONDecoder().decode(TargetSnapshotRecord.self, from: line)
            guard record.sourceRow == expectedSourceRow,
                  record.values.count == manifest.header.count else {
                throw TargetSnapshotError.corruptSnapshot
            }
            hasher.update(data: line)
            hasher.update(data: Data([0x0A]))
            expectedSourceRow += 1
            count += 1
            guard count <= Self.maxRows else { throw TargetSnapshotError.corruptSnapshot }
        }
        guard count == manifest.rowCount,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.recordsDigest else {
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
        maximumRecordsBytes(forSourceBytes: maximumSourceBytes)
    }

    private func maximumRecordsBytes(forSourceBytes sourceBytes: Int) -> Int {
        min(sourceBytes * 3, 2 * 1_024 * 1_024 * 1_024)
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
    private var fieldOnlyWhitespace = true
    private var delimiter: UInt8?

    init(descriptor: Int32, maximumRecordBytes: Int) {
        self.descriptor = descriptor
        self.maximumRecordBytes = maximumRecordBytes
    }

    mutating func setDelimiter(_ delimiter: Character) {
        self.delimiter = delimiter == "\t" ? 0x09 : 0x2C
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
            if quoted && afterQuote {
                if byte == delimiter {
                    quoted = false
                    afterQuote = false
                    fieldOnlyWhitespace = true
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
                } else if byte == 0x20 || byte == 0x09 {
                    // CSVParser accepts whitespace after a quoted field. Keep
                    // the bytes so the shared parser makes the final decision.
                    record.append(byte)
                } else {
                    throw CSVParseError.unexpectedCharacterAfterClosingQuote(Character(UnicodeScalar(byte)))
                }
            } else if quoted {
                if byte == 0x22 {
                    afterQuote = true
                }
                record.append(byte)
            } else if byte == 0x0A && !quoted {
                if record.last == 0x0D { record.removeLast() }
                defer {
                    record.removeAll(keepingCapacity: true)
                    afterQuote = false
                    fieldOnlyWhitespace = true
                }
                return record
            } else {
                if byte == 0x22, fieldOnlyWhitespace {
                    quoted = true
                    afterQuote = false
                } else if byte == delimiter || (delimiter == nil && (byte == 0x2C || byte == 0x09)) {
                    fieldOnlyWhitespace = true
                } else if byte != 0x20 && byte != 0x09 && byte != 0x0D {
                    fieldOnlyWhitespace = false
                }
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
