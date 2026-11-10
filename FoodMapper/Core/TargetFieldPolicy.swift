import CryptoKit
import Foundation

enum TargetFieldPolicyError: LocalizedError, Equatable {
    case contextTooLong
    case tooManyFields
    case unknownColumns([String])
    case ruleNeedsDecisionJSON

    var errorDescription: String? {
        switch self {
        case .contextTooLong:
            return "The retrieval context is longer than \(TargetFieldPolicy.maximumContextBytes) bytes."
        case .tooManyFields:
            return "Choose at most \(TargetFieldPolicy.maximumJudgeFields) target columns to send with each candidate."
        case let .unknownColumns(columns):
            return "This database has no column named \(columns.joined(separator: ", ")). Update the target field settings for this database."
        case .ruleNeedsDecisionJSON:
            return "A numeric rule needs the Responses or Chat Completions route. The Decisions route returns one choice and cannot list equivalent candidates."
        }
    }
}

/// What a researcher wants considered beyond the food description.
///
/// Used only by provider-assisted runs in Advanced mode. The published pipelines never read it.
/// Each part has one job:
/// - `retrievalContext` is added to every description when FoodMapper searches the
///   database. It stays on the Mac.
/// - `judgeFields` are target columns sent to the provider with each candidate.
/// - `numericRule` is applied in code, after the provider answers, among the candidate
///   it selected and the candidates it listed as the same food.
struct TargetFieldPolicy: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumJudgeFields = 8
    static let maximumContextBytes = 200
    static let maximumValueBytes = 120

    struct NumericRule: Codable, Equatable, Sendable {
        enum Goal: String, Codable, CaseIterable, Identifiable, Sendable {
            case lowest
            case highest

            var id: String { rawValue }
            var displayName: String { self == .lowest ? "Lowest" : "Highest" }
        }

        var column: String
        var goal: Goal
    }

    /// The result of applying a numeric rule to one row.
    struct RuleOutcome: Equatable, Sendable {
        /// Index into the row's candidates.
        let selection: Int
        let note: String
    }

    var version = TargetFieldPolicy.currentVersion
    var retrievalContext = ""
    var judgeFields: [String] = []
    var numericRule: NumericRule?

    var trimmedContext: String {
        retrievalContext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool {
        !trimmedContext.isEmpty || !judgeFields.isEmpty || numericRule != nil
    }

    /// Every target column this policy reads.
    var referencedColumns: [String] {
        var columns = judgeFields
        if let column = numericRule?.column, !columns.contains(column) { columns.append(column) }
        return columns
    }

    /// Checks limits and that every named column exists in the target database.
    func validated(availableColumns: [String]) throws -> TargetFieldPolicy {
        var checked = self
        checked.version = Self.currentVersion
        checked.retrievalContext = trimmedContext
        guard checked.retrievalContext.lengthOfBytes(using: .utf8) <= Self.maximumContextBytes else {
            throw TargetFieldPolicyError.contextTooLong
        }
        var seen = Set<String>()
        checked.judgeFields = judgeFields.filter { seen.insert($0).inserted }
        guard checked.judgeFields.count <= Self.maximumJudgeFields else { throw TargetFieldPolicyError.tooManyFields }
        let available = Set(availableColumns)
        let unknown = checked.referencedColumns.filter { !available.contains($0) }
        guard unknown.isEmpty else { throw TargetFieldPolicyError.unknownColumns(unknown) }
        return checked
    }

    /// The text embedded for retrieval. The steering comparison used this same form.
    func retrievalQuery(for input: String) -> String {
        let context = trimmedContext
        return context.isEmpty ? input : "\(input), \(context)"
    }

    /// The selected columns of one candidate row, each value cut at the byte limit on a character boundary.
    func judgeFieldValues(from row: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for column in judgeFields {
            guard let value = row[column]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            values[column] = Self.truncated(value, toBytes: Self.maximumValueBytes)
        }
        return values
    }

    /// Applies the numeric rule among the provider's selection and the candidates it called equivalent.
    ///
    /// A candidate with no number in the rule's column cannot win, and is never treated as zero.
    /// When no candidate in the set reports a number, the provider's selection stands.
    func applyRule(selection: Int, equivalents: [Int], value: (Int) -> String?) -> RuleOutcome? {
        guard let rule = numericRule else { return nil }
        var pool = [selection]
        for index in equivalents where !pool.contains(index) { pool.append(index) }
        let measured: [(index: Int, number: Double, text: String)] = pool.compactMap { index in
            guard let text = value(index)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let number = Double(text), number.isFinite else { return nil }
            return (index, number, text)
        }
        let goal = rule.goal.displayName.lowercased()
        let poolText = pool.count == 1 ? "1 candidate" : "\(pool.count) same-food candidates"
        guard let best = measured.min(by: { left, right in
            if left.number != right.number {
                return rule.goal == .lowest ? left.number < right.number : left.number > right.number
            }
            // Ties keep the provider's selection, then the better-ranked candidate.
            if (left.index == selection) != (right.index == selection) { return left.index == selection }
            return left.index < right.index
        }) else {
            return RuleOutcome(
                selection: selection,
                note: "Rule \(goal) \(rule.column): no value reported among \(poolText), so the provider's selection was kept."
            )
        }
        if best.index == selection {
            return RuleOutcome(
                selection: selection,
                note: "Rule \(goal) \(rule.column): the provider's selection (\(best.text)) is the \(goal) of \(poolText)."
            )
        }
        let selectedText = measured.first(where: { $0.index == selection })?.text ?? "not reported"
        return RuleOutcome(
            selection: best.index,
            note: "Rule \(goal) \(rule.column): chose \(best.text) over the provider's selection (\(selectedText)) among \(poolText)."
        )
    }

    /// A stable digest of the settings that can change a result.
    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(self))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func truncated(_ value: String, toBytes limit: Int) -> String {
        guard value.lengthOfBytes(using: .utf8) > limit else { return value }
        var result = ""
        var used = 0
        for character in value {
            let size = String(character).lengthOfBytes(using: .utf8)
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result
    }
}
