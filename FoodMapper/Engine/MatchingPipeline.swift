import Foundation

/// Matching pipelines available in FoodMapper.
///
/// Raw values are stable identifiers used in saved performance overrides.
/// The Qwen, Nomic, and Gemma experiments were removed in the model reset;
/// `LegacyPipeline` keeps their recorded names readable in old sessions.
enum PipelineType: String, Codable, CaseIterable, Identifiable {
    /// Published local method: GTE-Large cosine similarity.
    case gteLargeEmbedding = "gte-large-embedding"
    /// Published hybrid record: GTE-Large retrieval + Claude selection with the paper prompt.
    case gteLargeHaiku = "gte-large-haiku"
    /// GTE-Large retrieval + a configured provider profile that selects a candidate.
    case providerLLM = "provider-llm"
    /// GTE-Large retrieval + Claude with FoodMapper's cached-prompt revision.
    case gteLargeHaikuV2 = "gte-large-haiku-v2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gteLargeEmbedding: return "GTE-Large Embedding"
        case .gteLargeHaiku: return "GTE-Large + Haiku"
        case .gteLargeHaikuV2: return "GTE-Large + Claude (cached prompt)"
        case .providerLLM: return "GTE-Large + Provider"
        }
    }

    var shortDescription: String {
        switch self {
        case .gteLargeEmbedding:
            return "Cosine similarity with GTE-Large embeddings. Paper validation method."
        case .gteLargeHaiku:
            return "GTE-Large retrieval + Claude selection with the published prompt. Requires API key."
        case .gteLargeHaikuV2:
            return "GTE-Large retrieval + Claude selection with FoodMapper's cached prompt. Requires API key."
        case .providerLLM:
            return "GTE-Large retrieval followed by candidate selection from a configured provider profile."
        }
    }

    /// Models required for this pipeline
    var requiredModelKeys: [String] { ["gte-large"] }

    /// Embedding model key used by this pipeline
    var embeddingModelKey: String? { "gte-large" }

    /// Whether this pipeline accepts a matching instruction for its selection stage
    var supportsCustomInstruction: Bool {
        switch self {
        case .gteLargeEmbedding: return false
        case .gteLargeHaiku, .gteLargeHaikuV2, .providerLLM: return true
        }
    }

    var isImplemented: Bool { true }

    /// Whether this pipeline requires an Anthropic API key
    var requiresAPIKey: Bool {
        switch self {
        case .gteLargeHaiku, .gteLargeHaikuV2: return true
        case .gteLargeEmbedding, .providerLLM: return false
        }
    }

    /// The score type produced by this pipeline
    var defaultScoreType: ScoreType {
        switch self {
        case .gteLargeEmbedding: return .cosineSimilarity
        case .gteLargeHaiku, .gteLargeHaikuV2, .providerLLM: return .llmSelected
        }
    }

    /// Notice shown where the pipeline is selected
    var performanceWarning: String? {
        switch self {
        case .providerLLM:
            return "Each input sends its description and retrieved candidates to the selected provider."
        default:
            return nil
        }
    }

    /// Which user-facing pipeline mode this type belongs to
    var pipelineMode: PipelineMode {
        switch self {
        case .gteLargeEmbedding, .gteLargeHaiku: return .researchValidation
        case .gteLargeHaikuV2, .providerLLM: return .standard
        }
    }
}

/// Names recorded by pipelines that no longer exist. Old sessions keep their
/// recorded `pipelineName`; new work on such a session uses GTE-Large.
enum LegacyPipeline {
    static let removedDisplayNames: Set<String> = [
        "Qwen3-Embedding", "Nomic Embed Text v1.5", "Qwen3-Reranker (Benchmark)", "Qwen3 Two-Stage",
        "Smart Triage", "Qwen3 LLM Judge", "Embedding + LLM", "Gemma 4 LLM Judge", "Gemma 4 Two-Stage",
    ]

    static let removedRawValues: Set<String> = [
        "qwen3-embedding", "nomic-embedding", "qwen3-reranker", "qwen3-two-stage", "qwen3-smart-triage",
        "qwen3-llm-only", "embedding-llm", "gemma4-llm-only", "gemma4-two-stage",
    ]

    /// Display names used by earlier releases for pipelines that still exist.
    private static let renamedDisplayNames: [String: PipelineType] = [
        "GTE-Large + Haiku v2": .gteLargeHaikuV2,
    ]

    /// Pipeline to select when a saved session is reopened. A removed or
    /// unknown name resolves to the published GTE-Large pipeline.
    static func pipelineType(forRecordedName name: String) -> PipelineType {
        if let current = PipelineType.allCases.first(where: { $0.displayName == name }) { return current }
        if let renamed = renamedDisplayNames[name] { return renamed }
        return .gteLargeEmbedding
    }

    static func isRemoved(recordedName name: String) -> Bool {
        removedDisplayNames.contains(name)
    }

    /// Saved settings that belonged to the removed models.
    static let removedDefaultsKeys = ["selectedEmbeddingSize", "selectedRerankerSize", "selectedGenerativeSize"]

    /// Drops performance overrides saved for pipelines that no longer exist.
    static func prunedOverrides(_ overrides: [String: PipelinePerformanceConfig]) -> [String: PipelinePerformanceConfig] {
        overrides.filter { !removedRawValues.contains($0.key) }
    }

    /// Removes saved settings for the removed models and pipelines. Safe to
    /// run at every launch; it only rewrites a value that changes.
    static func migrateDefaults(_ defaults: UserDefaults) {
        for key in removedDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        guard let data = defaults.data(forKey: "pipelinePerformanceOverrides"),
              let saved = try? JSONDecoder().decode([String: PipelinePerformanceConfig].self, from: data) else {
            return
        }
        let pruned = prunedOverrides(saved)
        guard pruned.count != saved.count, let encoded = try? JSONEncoder().encode(pruned) else { return }
        defaults.set(encoded, forKey: "pipelinePerformanceOverrides")
    }
}

// MARK: - Per-Pipeline Performance Defaults

extension PipelineType {
    /// Default top-K for this pipeline type
    var defaultTopK: Int {
        switch self {
        case .gteLargeEmbedding: return 20
        case .gteLargeHaiku: return 5
        case .gteLargeHaikuV2: return 20
        case .providerLLM: return 5
        }
    }

    /// Default embedding batch size for this pipeline.
    func defaultEmbeddingBatchSize(modelKey: String?) -> Int { 32 }

    /// Default matching batch size (uniform across pipelines)
    var defaultMatchingBatchSize: Int { 128 }

    /// Default chunk size (uniform across pipelines)
    var defaultChunkSize: Int { 500 }

    /// Whether this pipeline has an embedding stage with configurable performance
    var hasEmbeddingStage: Bool { embeddingModelKey != nil }
}

/// User-facing pipeline modes. Each mode groups one or more PipelineTypes
/// that share a common purpose (production use vs paper replication).
enum PipelineMode: String, CaseIterable, Identifiable, Codable {
    case standard
    case researchValidation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Food Matching"
        case .researchValidation: return "Behind the Research"
        }
    }

    var defaultPipelineType: PipelineType { .gteLargeEmbedding }

    /// Pipeline types available under this mode.
    /// `.gteLargeHaiku` is in neither list; the Hybrid Matching switch controls it.
    var availablePipelineTypes: [PipelineType] {
        switch self {
        case .standard: return [.gteLargeEmbedding, .providerLLM, .gteLargeHaikuV2]
        case .researchValidation: return [.gteLargeEmbedding]
        }
    }
}

enum PipelineAdmission: String {
    case published = "Published method"
    case evaluation = "Evaluation"
}

extension PipelineType {
    var admission: PipelineAdmission {
        switch self {
        case .gteLargeEmbedding, .gteLargeHaiku: return .published
        case .gteLargeHaikuV2, .providerLLM: return .evaluation
        }
    }

    var isExperimental: Bool { admission == .evaluation }

    var requiresProviderProfile: Bool { self == .providerLLM }
}

/// Preset matching instructions for retrieval and selection stages.
/// Each preset provides three instruction tiers:
/// - embeddingInstruction: short, task-focused (positions query in vector space)
/// - rerankerInstruction: medium, reasoning-focused (for cross-encoder)
/// - haikuPrompt: rich domain-expert prompt (for Claude Haiku LLM)
enum InstructionPreset: String, CaseIterable, Identifiable, Codable {
    case bestMatch        // General food matching (default)
    case preparation      // Cooking/preparation method focus
    case ingredient       // Raw ingredient/commodity matching
    case nutritional      // Nutritional profile similarity
    case branded          // Commercial products -> generic
    case custom           // User-provided text

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bestMatch: return "Best Match"
        case .preparation: return "Preparation"
        case .ingredient: return "Ingredient"
        case .nutritional: return "Nutritional"
        case .branded: return "Branded"
        case .custom: return "Custom"
        }
    }

    /// Short instruction for embedding models. Positions the query in vector space.
    var embeddingInstruction: String {
        switch self {
        case .bestMatch:
            return "Given a food description, retrieve the most similar standardized food item"
        case .preparation:
            return "Given a food description, retrieve the food item matching the cooking method and preparation"
        case .ingredient:
            return "Given a food ingredient or product name, retrieve the closest matching standardized ingredient"
        case .nutritional:
            return "Given a food description, retrieve the food with the most similar nutritional composition"
        case .branded:
            return "Given a branded food product name, retrieve the closest matching standardized product"
        case .custom:
            return "" // resolved from customInstructionText in AppState
        }
    }

    /// Medium instruction for cross-encoder reranker. Guides relevance judgment.
    /// Uses "describes the same food item" phrasing for strict identity matching,
    /// not loose "matches the query food" which allows semantic relatives (grapes->wine).
    var rerankerInstruction: String {
        switch self {
        case .bestMatch:
            return "Determine if the document describes the same food item as the query. Consider exact food identity, form, and preparation. Related but different foods (e.g. grapes vs wine, chicken vs eggs) should score low."
        case .preparation:
            return "Determine if the document describes the same food item as the query with matching preparation method. Give strong weight to preparation (raw, cooked, baked, fried, steamed, grilled, canned, frozen, dried). The same food with a different preparation should score lower than the same food with matching preparation."
        case .ingredient:
            return "Determine if the document describes the same base ingredient as the query. Focus on commodity identity (e.g. wheat flour, chicken breast, olive oil) rather than brands, packaging, or preparation."
        case .nutritional:
            return "Determine if the document describes a food with a similar nutritional profile to the query. Prioritize same food group and similar macronutrient balance over exact name match, but the document must still describe a related food item."
        case .branded:
            return "Determine if the document is the generic equivalent of the query branded product. The document should describe the same underlying food, ignoring brand-specific modifiers, flavor variants, and sizes."
        case .custom:
            return "" // resolved from customInstructionText in AppState
        }
    }

    /// Rich prompt for Claude Haiku. Full domain-expert context for LLM reasoning.
    var haikuPrompt: String {
        switch self {
        case .bestMatch:
            return "You are a food science expert matching dietary survey responses to a standardized food reference database. The survey descriptions may be informal, abbreviated, or use regional terminology. Match to the most appropriate database entry considering food type, form, preparation, and common usage. Prefer exact food matches over broad category matches."
        case .preparation:
            return "You are a food science expert specializing in food preparation methods. Match the survey description to the database entry that best matches the cooking or preparation method described. Key distinctions: raw vs cooked, fresh vs frozen vs canned vs dried, baking vs frying vs grilling vs steaming. The preparation method takes priority over exact food variety."
        case .ingredient:
            return "You are a food science expert matching raw ingredients and commodities. The survey may describe branded products, recipe components, or colloquial food names. Match to the closest standardized raw ingredient, ignoring brand names, packaging, and preparation details. Focus on the base food commodity."
        case .nutritional:
            return "You are a nutritionist matching foods by their nutritional composition. Match the survey description to the database entry with the most similar nutritional profile. Consider food group, macronutrient balance (protein, fat, carbohydrate ratios), and caloric density. A nutritionally similar food from the same group is better than an exact name match from a different group."
        case .branded:
            return "You are a food science expert mapping branded commercial products to standardized generic equivalents. The survey description names a specific brand or product line. Match to the generic database entry that represents the same food without brand-specific modifiers. Ignore flavor variants, limited editions, size differences, and promotional naming."
        case .custom:
            return "" // resolved from customInstructionText in AppState
        }
    }

    /// Instruction for generative LLM judge. Contains matching criteria ONLY.
    /// Response format directives (letter/number/text) are added automatically
    /// by GenerativeJudgeModel.formatPrompt() based on the selected ResponseFormat.
    var judgeInstruction: String {
        switch self {
        case .bestMatch:
            return """
                Consider food type, form, preparation, and common usage. If the description \
                mentions a preparation (e.g. "grilled chicken"), prefer the entry closest in \
                preparation. Partial matches are acceptable. Only select no-match if the food \
                is fundamentally different from ALL candidates.
                """
        case .preparation:
            return """
                Prioritize cooking and preparation method. Focus on raw vs cooked, fresh vs \
                frozen vs canned, baking vs frying vs grilling. Only select no-match if ALL \
                candidates describe a fundamentally different food or preparation. When in \
                doubt, prefer the closest candidate.
                """
        case .ingredient:
            return """
                Match raw ingredients and commodities. Ignore brand names and packaging. \
                Match to the closest standardized raw ingredient. Only select no-match if ALL \
                candidates are fundamentally different ingredients. Prefer a partial match over \
                no match.
                """
        case .nutritional:
            return """
                Prioritize nutritional profile and food group similarity. A nutritionally similar \
                food is better than an exact name match from a different group. Only select \
                no-match if ALL candidates are from a completely unrelated food group. When in \
                doubt, prefer the closest match.
                """
        case .branded:
            return """
                Map branded products to generic equivalents. Ignore flavor variants, sizes, and \
                promotional naming. Match to the generic equivalent. Only select no-match if ALL \
                candidates are fundamentally different products. A similar product type is better \
                than no match.
                """
        case .custom:
            return "" // resolved from customInstructionText in AppState
        }
    }

    var helpText: String {
        switch self {
        case .bestMatch: return "General-purpose food matching considering type, form, and category"
        case .preparation: return "Prioritizes cooking/preparation method (raw, cooked, baked, fried, etc.)"
        case .ingredient: return "Matches raw ingredients and commodities, ignoring brands"
        case .nutritional: return "Matches by nutritional profile and food group similarity"
        case .branded: return "Maps branded products to generic database equivalents"
        case .custom: return "Provide your own instruction text"
        }
    }
}

/// Decides whether the Haiku pipelines have qualified work to submit.
/// Inputs with no qualified candidates are finalized before the batch stage.
enum HaikuBatchSubmission {
    static func shouldSubmit(taskCount: Int) -> Bool {
        taskCount > 0
    }
}

/// End-to-end matching pipeline protocol.
/// Each pipeline type trades off accuracy vs speed differently.
protocol MatchingPipelineProtocol {
    /// Pipeline display name for UI and session metadata
    var name: String { get }

    /// The pipeline type
    var pipelineType: PipelineType { get }

    /// Run matching on inputs against the loaded database.
    ///
    /// - Parameters:
    ///   - inputs: Text strings to match
    ///   - database: Target database to match against
    ///   - threshold: Minimum similarity score for a match
    ///   - hardwareConfig: Hardware-specific batch sizes and limits
    ///   - instruction: Optional custom matching instruction for asymmetric embedding models
    ///   - rerankerInstruction: Optional instruction for cross-encoder or Haiku reranking stage
    ///   - onProgress: Callback with number of items completed
    ///   - onPhaseChange: Optional callback for phase transitions (reranking progress, etc.)
    /// - Returns: Match results for each input
    func match(
        inputs: [String],
        database: AnyDatabase,
        threshold: Double,
        hardwareConfig: HardwareConfig,
        instruction: String?,
        rerankerInstruction: String?,
        onProgress: @Sendable @escaping (Int) -> Void,
        onPhaseChange: (@Sendable (MatchingPhase) -> Void)?
    ) async throws -> [MatchResult]

    /// Cancel any ongoing matching operation
    func cancel() async
}

// Default extension so existing pipelines that don't use all parameters can keep shorter signatures
extension MatchingPipelineProtocol {
    func match(
        inputs: [String],
        database: AnyDatabase,
        threshold: Double,
        hardwareConfig: HardwareConfig,
        instruction: String?,
        onProgress: @Sendable @escaping (Int) -> Void
    ) async throws -> [MatchResult] {
        try await match(
            inputs: inputs, database: database, threshold: threshold,
            hardwareConfig: hardwareConfig, instruction: instruction,
            rerankerInstruction: nil,
            onProgress: onProgress, onPhaseChange: nil
        )
    }
}
