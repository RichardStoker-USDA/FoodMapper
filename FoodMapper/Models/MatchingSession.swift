import Foundation

/// Saved matching session metadata
struct MatchingSession: Identifiable, Codable {
    let id: UUID
    let inputFileName: String
    let databaseName: String
    var threshold: Double
    let totalCount: Int
    var matchedCount: Int
    let resultsFilename: String
    let date: Date
    let pipelineName: String
    var inputFileId: UUID?

    // Matching instruction used (nil = model default)
    var matchingInstruction: String?

    // Target DB metadata for export reconstruction
    var selectedColumn: String?
    var targetTextColumn: String?
    var targetIdColumn: String?
    var targetColumnNames: [String]?

    // API usage tracking (for Haiku pipeline)
    var apiTokensUsed: Int?

    // Review workflow
    var reviewDecisionsFilename: String?
    var hasReviewData: Bool { reviewDecisionsFilename != nil }

    static func isSafePersistedFilename(_ value: String) -> Bool {
        SecureFileAccess.safeLeaf(value) &&
            value.pathExtension.lowercased() == "json" &&
            URL(fileURLWithPath: value).lastPathComponent == value
    }

    var matchRate: Double {
        guard totalCount > 0 else { return 0 }
        return Double(matchedCount) / Double(totalCount)
    }

    init(
        id: UUID = UUID(),
        inputFileName: String,
        databaseName: String,
        threshold: Double,
        totalCount: Int,
        matchedCount: Int,
        resultsFilename: String,
        date: Date = Date(),
        pipelineName: String = "GTE-Large Embedding",
        inputFileId: UUID? = nil,
        matchingInstruction: String? = nil,
        selectedColumn: String? = nil,
        targetTextColumn: String? = nil,
        targetIdColumn: String? = nil,
        targetColumnNames: [String]? = nil
    ) {
        self.id = id
        self.inputFileName = inputFileName
        self.databaseName = databaseName
        self.threshold = threshold
        self.totalCount = totalCount
        self.matchedCount = matchedCount
        self.resultsFilename = resultsFilename
        self.date = date
        self.pipelineName = pipelineName
        self.inputFileId = inputFileId
        self.matchingInstruction = matchingInstruction
        self.selectedColumn = selectedColumn
        self.targetTextColumn = targetTextColumn
        self.targetIdColumn = targetIdColumn
        self.targetColumnNames = targetColumnNames
    }

    // Coding keys for backwards compatibility (new fields may not exist in old sessions)
    enum CodingKeys: String, CodingKey {
        case id, inputFileName, databaseName, threshold, totalCount
        case matchedCount, resultsFilename, date, pipelineName, inputFileId
        case matchingInstruction
        case selectedColumn, targetTextColumn, targetIdColumn, targetColumnNames
        case apiTokensUsed
        case reviewDecisionsFilename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        inputFileName = try container.decode(String.self, forKey: .inputFileName)
        databaseName = try container.decode(String.self, forKey: .databaseName)
        threshold = try container.decode(Double.self, forKey: .threshold)
        totalCount = try container.decode(Int.self, forKey: .totalCount)
        matchedCount = try container.decode(Int.self, forKey: .matchedCount)
        let decodedResultsFilename = try container.decode(String.self, forKey: .resultsFilename)
        guard Self.isSafePersistedFilename(decodedResultsFilename) else {
            throw DecodingError.dataCorruptedError(
                forKey: .resultsFilename, in: container, debugDescription: "Invalid session results filename"
            )
        }
        resultsFilename = decodedResultsFilename
        date = try container.decode(Date.self, forKey: .date)
        pipelineName = try container.decodeIfPresent(String.self, forKey: .pipelineName) ?? "GTE-Large Embedding"
        inputFileId = try container.decodeIfPresent(UUID.self, forKey: .inputFileId)
        matchingInstruction = try container.decodeIfPresent(String.self, forKey: .matchingInstruction)
        selectedColumn = try container.decodeIfPresent(String.self, forKey: .selectedColumn)
        targetTextColumn = try container.decodeIfPresent(String.self, forKey: .targetTextColumn)
        targetIdColumn = try container.decodeIfPresent(String.self, forKey: .targetIdColumn)
        targetColumnNames = try container.decodeIfPresent([String].self, forKey: .targetColumnNames)
        apiTokensUsed = try container.decodeIfPresent(Int.self, forKey: .apiTokensUsed)
        let decodedReviewFilename = try container.decodeIfPresent(String.self, forKey: .reviewDecisionsFilename)
        if let decodedReviewFilename, !Self.isSafePersistedFilename(decodedReviewFilename) {
            throw DecodingError.dataCorruptedError(
                forKey: .reviewDecisionsFilename, in: container, debugDescription: "Invalid session review filename"
            )
        }
        reviewDecisionsFilename = decodedReviewFilename
    }
}
