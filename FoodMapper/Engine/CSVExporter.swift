import Foundation

/// CSV export utilities
enum CSVExporter {

    // MARK: - Status Resolution

    /// fm_status column value: "Match", "No Match", "Needs Review",
    /// "Match (confirmed)", "Match (overridden)", "No Match (confirmed)", "Match (LLM)".
    private static func fmStatus(
        for result: MatchResult,
        decision: ReviewDecision?,
        profile: ThresholdProfile
    ) -> String {
        if result.status == .error { return "Error" }

        // Detect LLM override: LLM selected a different candidate than embedding's top-1
        if result.scoreType == .llmSelected,
           let firstCandidate = result.candidates?.first,
           result.matchID != nil,
           result.matchID != firstCandidate.matchID {
            if let decision = decision {
                switch decision.status {
                case .accepted: return "Match (confirmed)"
                case .overridden: return "Match (overridden)"
                case .rejected: return "No Match (confirmed)"
                default: return "Match (LLM)"
                }
            }
            return "Match (LLM)"
        }

        // Check human decisions first
        if let decision = decision {
            switch decision.status {
            case .accepted:
                return "Match (confirmed)"
            case .rejected:
                return "No Match (confirmed)"
            case .overridden:
                return "Match (overridden)"
            default:
                break // Fall through to auto-categorization
            }
        }

        // Auto-categorization from pipeline
        let category = MatchCategory.from(result: result, decision: decision, profile: profile)
        switch category {
        case .match, .confirmedMatch:
            return "Match"
        case .noMatch, .confirmedNoMatch:
            return "No Match"
        case .needsReview:
            return "Needs Review"
        }
    }

    /// Target column values for a result row. When overridden, all columns
    /// come from the override candidate's data (not the original match).
    private static func resolveTargetFields(
        for result: MatchResult,
        decision: ReviewDecision?,
        targetTextColumn: String,
        targetIdColumn: String?,
        targetColumnNames: [String],
        isNoMatch: Bool
    ) -> [String] {
        // No-match rows: all target columns empty
        if isNoMatch {
            return Array(repeating: "", count: targetColumnNames.count)
        }

        // Determine which candidate's data to use
        let useOverride = decision?.status == .overridden
        let overrideCandidate: MatchCandidate? = {
            guard useOverride, let overrideID = decision?.overrideMatchID else { return nil }
            return result.candidates?.first(where: { $0.matchID == overrideID })
        }()

        // Build field values from the resolved source
        return targetColumnNames.map { col in
            if col == targetTextColumn {
                if useOverride {
                    return decision?.overrideMatchText ?? result.matchText ?? ""
                }
                return result.matchText ?? ""
            } else if col == targetIdColumn {
                if useOverride {
                    return decision?.overrideMatchID ?? result.matchID ?? ""
                }
                return result.matchID ?? ""
            } else {
                // Additional fields: use override candidate's fields if available
                if let candidate = overrideCandidate {
                    return candidate.additionalFields?[col] ?? ""
                }
                return result.matchAdditionalFields?[col] ?? ""
            }
        }
    }

    // MARK: - Full Export (with original input data)

    /// Export results with original input data preserved.
    /// Layout: [all input cols] | fm_status | fm_score | fm_pipeline | fm_note | [detailed cols] | [all target DB cols]
    /// When `detailed` is true, adds fm_reasoning (if any results have it) and fm_embedding_candidate/score 1-5.
    static func exportWithOriginalData(
        results: [MatchResult],
        inputFile: InputFile,
        pipelineName: String,
        targetTextColumn: String,
        targetIdColumn: String?,
        targetColumnNames: [String],
        reviewDecisions: [UUID: ReviewDecision] = [:],
        detailed: Bool = false,
        format: DataFileFormat = .csv
    ) -> String {
        let profile = ThresholdProfile.defaults(for: results.first?.scoreType ?? .cosineSimilarity)
        let includeReasoning = detailed && results.contains { $0.llmReasoning?.isEmpty == false }
        let delim = format.delimiter
        let delimStr = format.delimiterString

        // Build result lookup by inputRow for O(1) access
        var resultsByRow: [Int: MatchResult] = [:]
        for result in results {
            resultsByRow[result.inputRow] = result
        }

        // Handle name collisions: if a target column name matches an input column name, suffix it
        let inputColumnSet = Set(inputFile.columns)
        let resolvedTargetColumns = targetColumnNames.map { col in
            inputColumnSet.contains(col) ? "\(col) (target)" : col
        }

        // Build header
        var header = inputFile.columns
        header.append(contentsOf: ["fm_status", "fm_score", "fm_pipeline", "fm_note"])
        if detailed {
            if includeReasoning { header.append("fm_reasoning") }
            header.append(contentsOf: detailedCandidateHeaders())
        }
        header.append(contentsOf: resolvedTargetColumns)

        var csv = header.map { escapeField($0, delimiter: delim) }.joined(separator: delimStr) + "\n"

        // Rows in original input order
        for (index, row) in inputFile.rows.enumerated() {
            var outputRow: [String] = []

            // Original input columns (unchanged from upload)
            for column in inputFile.columns {
                outputRow.append(escapeField(row[column] ?? "", delimiter: delim))
            }

            if let result = resultsByRow[index] {
                let decision = reviewDecisions[result.id]
                let status = fmStatus(for: result, decision: decision, profile: profile)
                let isNoMatch = status == "No Match" || status == "No Match (confirmed)"

                // fm_status
                outputRow.append(escapeField(status, delimiter: delim))
                // fm_score (use override candidate's score when overridden)
                let exportScore: Double = {
                    if let d = decision, d.status == .overridden, let s = d.overrideScore { return s }
                    return result.score
                }()
                outputRow.append(String(format: "%.4f", exportScore))
                // fm_pipeline
                outputRow.append(escapeField(pipelineName, delimiter: delim))
                // fm_note
                outputRow.append(escapeField(decision?.note ?? "", delimiter: delim))

                // Detailed columns
                if detailed {
                    if includeReasoning {
                        outputRow.append(escapeField(result.llmReasoning ?? "", delimiter: delim))
                    }
                    outputRow.append(contentsOf: detailedCandidateValues(for: result, delimiter: delim))
                }

                // Target DB columns
                let targetValues = resolveTargetFields(
                    for: result,
                    decision: decision,
                    targetTextColumn: targetTextColumn,
                    targetIdColumn: targetIdColumn,
                    targetColumnNames: targetColumnNames,
                    isNoMatch: isNoMatch
                )
                for value in targetValues {
                    outputRow.append(escapeField(value, delimiter: delim))
                }
            } else {
                // No result for this row (shouldn't happen, but fill with empties)
                var emptyCount = 4 + targetColumnNames.count
                if detailed {
                    emptyCount += (includeReasoning ? 1 : 0) + 10
                }
                outputRow.append(contentsOf: Array(repeating: "", count: emptyCount))
            }

            csv += outputRow.joined(separator: delimStr) + "\n"
        }

        return csv
    }

    // MARK: - Fallback Export (without original input file)

    /// Export results to CSV when the original input file is unavailable.
    /// Uses the same simplified column structure but input columns are limited
    /// to what was captured at match time.
    /// Filename should use: foodmapper_results_partial_{timestamp}.csv
    static func export(
        results: [MatchResult],
        pipelineName: String,
        selectedColumn: String? = nil,
        targetTextColumn: String? = nil,
        targetIdColumn: String? = nil,
        targetColumnNames: [String]? = nil,
        reviewDecisions: [UUID: ReviewDecision] = [:],
        detailed: Bool = false,
        format: DataFileFormat = .csv
    ) -> String {
        let profile = ThresholdProfile.defaults(for: results.first?.scoreType ?? .cosineSimilarity)
        let includeReasoning = detailed && results.contains { $0.llmReasoning?.isEmpty == false }
        let delim = format.delimiter
        let delimStr = format.delimiterString

        // Sort results by inputRow to preserve original input order
        let sortedResults = results.sorted { $0.inputRow < $1.inputRow }

        // If we have target metadata, use proper column layout
        if let targetColumns = targetColumnNames, !targetColumns.isEmpty {
            let inputHeader = selectedColumn ?? "input"

            // Build header: input col | fm_ columns | [detailed cols] | target cols
            var headerCols = [inputHeader, "fm_status", "fm_score", "fm_pipeline", "fm_note"]
            if detailed {
                if includeReasoning { headerCols.append("fm_reasoning") }
                headerCols.append(contentsOf: detailedCandidateHeaders())
            }
            headerCols.append(contentsOf: targetColumns)
            var csv = headerCols.map { escapeField($0, delimiter: delim) }.joined(separator: delimStr) + "\n"

            for result in sortedResults {
                let decision = reviewDecisions[result.id]
                let status = fmStatus(for: result, decision: decision, profile: profile)
                let isNoMatch = status == "No Match" || status == "No Match (confirmed)"

                // Use override candidate's score when overridden
                let exportScore: Double = {
                    if let d = decision, d.status == .overridden, let s = d.overrideScore { return s }
                    return result.score
                }()
                var row = [
                    escapeField(result.inputText, delimiter: delim),
                    escapeField(status, delimiter: delim),
                    String(format: "%.4f", exportScore),
                    escapeField(pipelineName, delimiter: delim),
                    escapeField(decision?.note ?? "", delimiter: delim)
                ]

                // Detailed columns
                if detailed {
                    if includeReasoning {
                        row.append(escapeField(result.llmReasoning ?? "", delimiter: delim))
                    }
                    row.append(contentsOf: detailedCandidateValues(for: result, delimiter: delim))
                }

                // Target DB columns
                let targetValues = resolveTargetFields(
                    for: result,
                    decision: decision,
                    targetTextColumn: targetTextColumn ?? "",
                    targetIdColumn: targetIdColumn,
                    targetColumnNames: targetColumns,
                    isNoMatch: isNoMatch
                )
                for value in targetValues {
                    row.append(escapeField(value, delimiter: delim))
                }

                csv += row.joined(separator: delimStr) + "\n"
            }
            return csv
        }

        // Fallback: generic column names for old sessions without target metadata
        let additionalKeys = collectAdditionalFieldKeys(from: results)
        var headerCols = ["row", "input", "match", "match_id", "fm_status", "fm_score", "fm_pipeline", "fm_note"]
        if detailed {
            if includeReasoning { headerCols.append("fm_reasoning") }
            headerCols.append(contentsOf: detailedCandidateHeaders())
        }
        headerCols.append(contentsOf: additionalKeys.map { "db_\($0)" })
        var csv = headerCols.map { escapeField($0, delimiter: delim) }.joined(separator: delimStr) + "\n"

        for result in sortedResults {
            let decision = reviewDecisions[result.id]
            let status = fmStatus(for: result, decision: decision, profile: profile)
            let isNoMatch = status == "No Match" || status == "No Match (confirmed)"

            let matchText: String
            let matchId: String
            if isNoMatch {
                matchText = ""
                matchId = ""
            } else if decision?.status == .overridden {
                matchText = decision?.overrideMatchText ?? result.matchText ?? ""
                matchId = decision?.overrideMatchID ?? result.matchID ?? ""
            } else {
                matchText = result.matchText ?? ""
                matchId = result.matchID ?? ""
            }

            // Use override candidate's score when overridden
            let exportScore: Double = {
                if let d = decision, d.status == .overridden, let s = d.overrideScore { return s }
                return result.score
            }()
            var row = [
                String(result.inputRow + 1),
                escapeField(result.inputText, delimiter: delim),
                escapeField(matchText, delimiter: delim),
                escapeField(matchId, delimiter: delim),
                escapeField(status, delimiter: delim),
                String(format: "%.4f", exportScore),
                escapeField(pipelineName, delimiter: delim),
                escapeField(decision?.note ?? "", delimiter: delim)
            ]

            // Detailed columns
            if detailed {
                if includeReasoning {
                    row.append(escapeField(result.llmReasoning ?? "", delimiter: delim))
                }
                row.append(contentsOf: detailedCandidateValues(for: result, delimiter: delim))
            }

            // Additional fields from the matched entry
            if isNoMatch {
                row.append(contentsOf: Array(repeating: "", count: additionalKeys.count))
            } else {
                // Use override candidate's fields if available
                let overrideCandidate: MatchCandidate? = {
                    guard decision?.status == .overridden,
                          let overrideID = decision?.overrideMatchID else { return nil }
                    return result.candidates?.first(where: { $0.matchID == overrideID })
                }()

                for key in additionalKeys {
                    if let candidate = overrideCandidate {
                        row.append(escapeField(candidate.additionalFields?[key] ?? "", delimiter: delim))
                    } else {
                        row.append(escapeField(result.matchAdditionalFields?[key] ?? "", delimiter: delim))
                    }
                }
            }

            csv += row.joined(separator: delimStr) + "\n"
        }

        return csv
    }

    // MARK: - Helpers

    /// Collect all unique additional field keys from results, sorted alphabetically
    private static func collectAdditionalFieldKeys(from results: [MatchResult]) -> [String] {
        var keySet = Set<String>()
        for result in results {
            if let fields = result.matchAdditionalFields {
                keySet.formUnion(fields.keys)
            }
        }
        return keySet.sorted()
    }

    // MARK: - Detailed Export Helpers

    /// Column headers for embedding candidate pairs (candidate text + score, 1-5)
    private static func detailedCandidateHeaders() -> [String] {
        (1...5).flatMap { i in
            ["fm_embedding_candidate_\(i)", "fm_embedding_score_\(i)"]
        }
    }

    /// Column values for embedding candidate pairs from a result's candidates array.
    /// Returns 10 escaped strings (5 candidate/score pairs). Missing candidates are empty.
    private static func detailedCandidateValues(for result: MatchResult, delimiter: Character = ",") -> [String] {
        let candidates = result.candidates ?? []
        return (0..<5).flatMap { i -> [String] in
            if i < candidates.count {
                return [escapeField(candidates[i].matchText, delimiter: delimiter), String(format: "%.4f", candidates[i].score)]
            }
            return ["", ""]
        }
    }

    /// Escape a field for delimited output (quote if contains delimiter, newline, or quote)
    private static func escapeField(_ value: String, delimiter: Character = ",") -> String {
        let delimStr = String(delimiter)
        let needsQuoting = value.contains(delimStr) || value.contains("\n") || value.contains("\"")
        if needsQuoting {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    /// Legacy wrapper -- calls escapeField with comma delimiter
    private static func escapeCSV(_ value: String) -> String {
        escapeField(value, delimiter: ",")
    }
}
