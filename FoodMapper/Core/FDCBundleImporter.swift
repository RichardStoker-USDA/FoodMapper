import Foundation

/// Reads CSV records from a file one at a time, so a multi-gigabyte table never sits in memory.
///
/// Field rules match `CSVParser.parseRecords`: a quote opens a field only at the field's
/// start, a doubled quote inside a quoted field is one quote, a quoted field may contain
/// commas and line breaks, an unquoted field is trimmed, and a blank line is skipped.
enum CSVRecordStream {
    static let maximumRecordBytes = 8 * 1_024 * 1_024

    fileprivate struct Field {
        let range: Range<Int>
        let quoted: Bool
    }

    /// One record. Valid only inside the `forEachRecord` callback that receives it.
    struct Record {
        fileprivate let bytes: UnsafeRawBufferPointer
        fileprivate let fields: [Field]

        var count: Int { fields.count }

        func string(_ index: Int?) throws -> String? {
            guard let index, fields.indices.contains(index) else { return nil }
            let field = fields[index]
            var range = field.range
            if !field.quoted {
                while range.lowerBound < range.upperBound, Self.isBlank(bytes[range.lowerBound]) {
                    range = (range.lowerBound + 1)..<range.upperBound
                }
                while range.lowerBound < range.upperBound, Self.isBlank(bytes[range.upperBound - 1]) {
                    range = range.lowerBound..<(range.upperBound - 1)
                }
            }
            let slice = UnsafeRawBufferPointer(rebasing: bytes[range])
            guard slice.contains(where: { $0 >= 0x80 }) else {
                let text = String(decoding: slice, as: UTF8.self)
                return field.quoted ? Self.unescaped(text) : text
            }
            guard let text = String(bytes: slice, encoding: .utf8) else { throw CSVParseError.invalidEncoding }
            return field.quoted ? Self.unescaped(text) : text.trimmingCharacters(in: .whitespaces)
        }

        func strings() throws -> [String] {
            try fields.indices.map { try string($0) ?? "" }
        }

        private static func isBlank(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

        private static func unescaped(_ text: String) -> String {
            var result = text
            if result.utf8.contains(0x22) { result = result.replacingOccurrences(of: "\"\"", with: "\"") }
            if result.utf8.contains(0x0D) {
                result = result.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            }
            return result
        }
    }

    static func forEachRecord(in url: URL, chunkBytes: Int = 1_048_576, _ body: (Record) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let readSize = max(16, chunkBytes)
        var carry: [UInt8] = []
        var fields: [Field] = []
        var checksBOM = true
        var reachedEnd = false
        while !reachedEnd {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: readSize) ?? Data()
            reachedEnd = chunk.isEmpty
            carry.append(contentsOf: chunk)
            if checksBOM {
                checksBOM = false
                if carry.starts(with: [0xEF, 0xBB, 0xBF]) { carry.removeFirst(3) }
            }
            let consumed = try carry.withUnsafeBytes { raw in
                try scan(raw, isFinal: reachedEnd, fields: &fields, body: body)
            }
            carry.removeFirst(consumed)
            guard carry.count <= maximumRecordBytes else { throw CSVParseError.unterminatedQuotedField }
        }
    }

    /// Emits every complete record in `raw` and returns how many bytes they used.
    /// A record cut off by the end of the buffer is left for the next call.
    private static func scan(
        _ raw: UnsafeRawBufferPointer, isFinal: Bool, fields: inout [Field], body: (Record) throws -> Void
    ) throws -> Int {
        let count = raw.count
        var recordStart = 0
        var index = 0
        while index < count {
            fields.removeAll(keepingCapacity: true)
            var fieldStart = index
            var contentStart = index
            var contentEnd = index
            var quoted = false
            var inQuotes = false
            var afterClosingQuote = false
            var onlyBlanks = true
            var hasContent = false
            var complete = false

            scanning: while index < count {
                let byte = raw[index]
                if inQuotes {
                    if byte == 0x22 {
                        if index + 1 < count {
                            if raw[index + 1] == 0x22 {
                                index += 2
                                continue
                            }
                        } else if !isFinal {
                            // The next byte decides whether this quote closes the field.
                            return recordStart
                        }
                        inQuotes = false
                        afterClosingQuote = true
                        contentEnd = index
                    }
                    index += 1
                    continue
                }
                switch byte {
                case 0x2C:
                    fields.append(quoted ? Field(range: contentStart..<contentEnd, quoted: true)
                                         : Field(range: fieldStart..<index, quoted: false))
                    index += 1
                    fieldStart = index
                    quoted = false
                    afterClosingQuote = false
                    onlyBlanks = true
                case 0x0A, 0x0D:
                    fields.append(quoted ? Field(range: contentStart..<contentEnd, quoted: true)
                                         : Field(range: fieldStart..<index, quoted: false))
                    index += 1
                    complete = true
                    break scanning
                case 0x22 where onlyBlanks && !afterClosingQuote:
                    quoted = true
                    inQuotes = true
                    hasContent = true
                    contentStart = index + 1
                    index += 1
                case 0x20, 0x09:
                    index += 1
                default:
                    if afterClosingQuote {
                        throw CSVParseError.unexpectedCharacterAfterClosingQuote(Character(UnicodeScalar(byte)))
                    }
                    onlyBlanks = false
                    hasContent = true
                    index += 1
                }
            }

            if !complete {
                guard isFinal else { return recordStart }
                guard !inQuotes else { throw CSVParseError.unterminatedQuotedField }
                fields.append(quoted ? Field(range: contentStart..<contentEnd, quoted: true)
                                     : Field(range: fieldStart..<count, quoted: false))
            }
            if hasContent {
                try body(Record(bytes: raw, fields: fields))
            }
            recordStart = index
        }
        return recordStart
    }
}

enum FDCBundleImportError: LocalizedError, Equatable {
    case missingFile(String)
    case missingColumn(file: String, column: String)
    case unreadableFile(name: String, reason: String)
    case noFoods
    case tooManyFoods(Int)

    var errorDescription: String? {
        switch self {
        case let .missingFile(name):
            return "This folder has no \(name). Choose the unzipped FoodData Central CSV folder."
        case let .missingColumn(file, column):
            return "\(file) has no \(column) column, so it is not a FoodData Central CSV file FoodMapper can read."
        case let .unreadableFile(name, reason):
            return "\(name) could not be read. \(reason)"
        case .noFoods:
            return "No foods of a supported FoodData Central data type were found in this folder."
        case let .tooManyFoods(limit):
            return "This folder has more than \(limit.formatted()) foods, which is over the database limit for this Mac."
        }
    }
}

struct FDCBundleImportSummary: Equatable, Sendable {
    let foods: Int
    /// Rows of `food.csv` left out: other data types, empty descriptions, and repeated identifiers.
    let excludedFoods: Int
    let foodsByDataType: [String: Int]
    let foodsWithoutNutrients: Int
    /// Nutrient IDs ignored because the bundle's `nutrient.csv` lists them in another unit.
    let skippedNutrientIDs: [String]
}

/// Turns an unzipped FoodData Central CSV download into one target table:
/// one row per food with its category and seven nutrients per 100 g.
///
/// Foundation, SR Legacy, FNDDS, and Branded downloads share these files, so one
/// reader covers all four. Nothing is downloaded; the user supplies the folder.
/// A nutrient the source does not report stays an empty cell. It is never zero.
enum FDCBundleImporter {
    static let maximumFoods = 2_500_000
    static let textColumn = "description"
    static let idColumn = "fdc_id"

    /// Output nutrient columns, the unit FoodData Central reports them in, and the
    /// nutrient IDs that fill them in order of preference.
    static let nutrientColumns: [(column: String, unit: String, nutrientIDs: [String])] = [
        ("energy_kcal", "KCAL", ["1008", "2047", "2048"]),
        ("protein_g", "G", ["1003"]),
        ("fat_g", "G", ["1004"]),
        ("carbohydrate_g", "G", ["1005"]),
        ("fiber_g", "G", ["1079"]),
        ("sugars_g", "G", ["2000", "1063"]),
        ("sodium_mg", "MG", ["1093"]),
    ]

    /// The legacy nutrient number for each nutrient ID. FNDDS downloads put this number in
    /// `food_nutrient.csv` where the other downloads put the ID, so both are accepted.
    static let nutrientNumbers: [String: String] = [
        "1008": "208", "2047": "957", "2048": "958", "1003": "203", "1004": "204",
        "1005": "205", "1079": "291", "2000": "269", "1063": "269.3", "1093": "307",
    ]

    static var outputColumns: [String] {
        [idColumn, textColumn, "data_type", "category"] + nutrientColumns.map(\.column)
    }

    /// Data types a researcher maps to, in display order. Foundation downloads also list
    /// laboratory samples and acquisitions, which are not mapping targets.
    static let includedDataTypes: [(dataType: String, label: String)] = [
        ("foundation_food", "Foundation"),
        ("sr_legacy_food", "SR Legacy"),
        ("survey_fndds_food", "FNDDS"),
        ("branded_food", "Branded"),
    ]

    /// Converts into a new owner-only folder under `temporaryRoot`. The caller removes the folder.
    static func convertToTemporaryFile(
        bundle folder: URL, temporaryRoot: URL, maximumFoods: Int = maximumFoods
    ) throws -> (output: URL, summary: FDCBundleImportSummary) {
        let directory = temporaryRoot.appendingPathComponent("fdc-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let output = directory.appendingPathComponent("fdc_foods.csv")
        do {
            return (output, try convert(bundle: folder, to: output, maximumFoods: maximumFoods))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func convert(
        bundle folder: URL, to output: URL, maximumFoods: Int = maximumFoods
    ) throws -> FDCBundleImportSummary {
        let foodURL = folder.appendingPathComponent("food.csv")
        let nutrientURL = folder.appendingPathComponent("food_nutrient.csv")
        for url in [foodURL, nutrientURL] where !FileManager.default.fileExists(atPath: url.path) {
            throw FDCBundleImportError.missingFile(url.lastPathComponent)
        }
        let included = Set(includedDataTypes.map(\.dataType))

        // Foods.
        var ids: [String] = []
        var descriptions: [String] = []
        var dataTypes: [String] = []
        var categoryIDs: [String] = []
        var indexByID: [String: Int] = [:]
        var byDataType: [String: Int] = [:]
        var excluded = 0
        try readTable(foodURL, required: ["fdc_id", "data_type", "description"]) { columns, record in
            guard let id = try record.string(columns["fdc_id"]), !id.isEmpty else { return }
            let dataType = try record.string(columns["data_type"]) ?? ""
            let description = try record.string(columns["description"]) ?? ""
            guard included.contains(dataType),
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  indexByID[id] == nil else {
                excluded += 1
                return
            }
            guard ids.count < maximumFoods else { throw FDCBundleImportError.tooManyFoods(maximumFoods) }
            indexByID[id] = ids.count
            ids.append(id)
            descriptions.append(description)
            dataTypes.append(dataType)
            categoryIDs.append(try record.string(columns["food_category_id"]) ?? "")
            byDataType[dataType, default: 0] += 1
        }
        guard !ids.isEmpty else { throw FDCBundleImportError.noFoods }
        let categories = try categoryNames(in: folder, categoryIDs: categoryIDs, indexByID: indexByID)

        // Nutrients. `rank` remembers which preferred ID filled a cell so a better one can replace it.
        let definitions = try nutrientDefinitions(in: folder)
        var slotByNutrient: [String: (slot: Int, rank: UInt8)] = [:]
        var skippedNutrientIDs: [String] = []
        for (slot, entry) in nutrientColumns.enumerated() {
            for (rank, id) in entry.nutrientIDs.enumerated() {
                let definition = definitions?[id]
                if let unit = definition?.unit, unit.uppercased() != entry.unit {
                    skippedNutrientIDs.append(id)
                    continue
                }
                slotByNutrient[id] = (slot, UInt8(rank))
                // Accept the nutrient number too, unless this bundle uses that value as another nutrient's ID.
                if let number = definition?.number ?? nutrientNumbers[id], !number.isEmpty,
                   definitions?[number] == nil, slotByNutrient[number] == nil {
                    slotByNutrient[number] = (slot, UInt8(rank))
                }
            }
        }
        let width = nutrientColumns.count
        var amounts = [String](repeating: "", count: ids.count * width)
        var ranks = [UInt8](repeating: UInt8.max, count: ids.count * width)
        try readTable(nutrientURL, required: ["fdc_id", "nutrient_id", "amount"]) { columns, record in
            guard let nutrientID = try record.string(columns["nutrient_id"]),
                  let target = slotByNutrient[nutrientID],
                  let foodID = try record.string(columns["fdc_id"]),
                  let row = indexByID[foodID],
                  let amount = try record.string(columns["amount"]),
                  let value = Double(amount), value.isFinite else { return }
            let cell = row * width + target.slot
            if target.rank < ranks[cell] {
                amounts[cell] = amount
                ranks[cell] = target.rank
            }
        }

        // Output.
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var buffer = Data((outputColumns.joined(separator: ",") + "\n").utf8)
        var withoutNutrients = 0
        for row in ids.indices {
            let nutrients = amounts[(row * width)..<((row + 1) * width)]
            if nutrients.allSatisfy(\.isEmpty) { withoutNutrients += 1 }
            let fields = [ids[row], descriptions[row], dataTypes[row], categories[row]] + nutrients
            buffer.append(Data((fields.map(csvField).joined(separator: ",") + "\n").utf8))
            if buffer.count >= 1_048_576 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try handle.write(contentsOf: buffer)
        return FDCBundleImportSummary(
            foods: ids.count, excludedFoods: excluded, foodsByDataType: byDataType,
            foodsWithoutNutrients: withoutNutrients, skippedNutrientIDs: skippedNutrientIDs
        )
    }

    /// A short database name such as "FDC SR Legacy 2018-04", from the foods found and the folder's release date.
    static func suggestedName(folder: URL, summary: FDCBundleImportSummary) -> String {
        let present = includedDataTypes.filter { summary.foodsByDataType[$0.dataType] != nil }
        var parts = ["FDC"]
        if present.count == 1 { parts.append(present[0].label) }
        let name = folder.lastPathComponent
        // A release date such as 2018-04 or 2024-10-31, standing apart from other letters and digits.
        let releaseDate = #"(?<![0-9A-Za-z])(19|20)\d{2}-(0[1-9]|1[0-2])(-(0[1-9]|[12]\d|3[01]))?(?![0-9A-Za-z])"#
        if let range = name.range(of: releaseDate, options: .regularExpression) {
            parts.append(String(name[range]))
        }
        return parts.joined(separator: " ")
    }

    /// Category text per food: `food_category.csv` for Foundation and SR Legacy, the WWEIA
    /// table for FNDDS, and the category recorded on each Branded food.
    private static func categoryNames(
        in folder: URL, categoryIDs: [String], indexByID: [String: Int]
    ) throws -> [String] {
        var names: [String: String] = [:]
        let sources: [(file: String, id: String, name: String)] = [
            ("food_category.csv", "id", "description"),
            ("wweia_food_category.csv", "wweia_food_category", "wweia_food_category_description"),
        ]
        for source in sources {
            try readOptionalTable(folder.appendingPathComponent(source.file), required: [source.id, source.name]) { columns, record in
                if let id = try record.string(columns[source.id]), names[id] == nil,
                   let name = try record.string(columns[source.name]) {
                    names[id] = name
                }
            }
        }
        var categories = categoryIDs.map { names[$0] ?? "" }
        if categories.contains(where: \.isEmpty) {
            try readOptionalTable(
                folder.appendingPathComponent("branded_food.csv"), required: ["fdc_id", "branded_food_category"]
            ) { columns, record in
                if let id = try record.string(columns["fdc_id"]), let row = indexByID[id], categories[row].isEmpty,
                   let name = try record.string(columns["branded_food_category"]) {
                    categories[row] = name
                }
            }
        }
        return categories
    }

    /// Unit and nutrient number per nutrient ID from the bundle's own `nutrient.csv`, or nil when it has none.
    private static func nutrientDefinitions(in folder: URL) throws -> [String: (unit: String, number: String?)]? {
        var definitions: [String: (unit: String, number: String?)] = [:]
        let found = try readOptionalTable(folder.appendingPathComponent("nutrient.csv"), required: ["id", "unit_name"]) { columns, record in
            if let id = try record.string(columns["id"]), let unit = try record.string(columns["unit_name"]) {
                definitions[id] = (unit, try record.string(columns["nutrient_nbr"]))
            }
        }
        return found ? definitions : nil
    }

    /// Reads a table the bundle may not include. Returns false when it is absent or lacks the columns.
    @discardableResult
    private static func readOptionalTable(
        _ url: URL, required: [String], row: (_ columns: [String: Int], _ record: CSVRecordStream.Record) throws -> Void
    ) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try readTable(url, required: required, row: row)
            return true
        } catch FDCBundleImportError.missingColumn {
            return false
        }
    }

    private static func readTable(
        _ url: URL, required: [String], row: (_ columns: [String: Int], _ record: CSVRecordStream.Record) throws -> Void
    ) throws {
        var columns: [String: Int]?
        do {
            try CSVRecordStream.forEachRecord(in: url) { record in
                if let columns {
                    try row(columns, record)
                    return
                }
                var names: [String: Int] = [:]
                for (index, name) in try record.strings().enumerated() where names[name] == nil {
                    names[name] = index
                }
                for name in required where names[name] == nil {
                    throw FDCBundleImportError.missingColumn(file: url.lastPathComponent, column: name)
                }
                columns = names
            }
        } catch let error as CSVParseError {
            throw FDCBundleImportError.unreadableFile(name: url.lastPathComponent, reason: error.localizedDescription)
        }
        if columns == nil {
            throw FDCBundleImportError.missingColumn(file: url.lastPathComponent, column: required.first ?? "")
        }
    }

    private static func csvField(_ value: String) -> String {
        let needsQuotes = value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
            || value.first?.isWhitespace == true || value.last?.isWhitespace == true
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
