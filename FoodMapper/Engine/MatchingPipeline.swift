import Foundation

/// Types of matching pipelines available in FoodMapper.
/// Each pipeline represents a different strategy for matching food descriptions.
enum PipelineType: String, Codable, CaseIterable, Identifiable {
    /// Paper validation: GTE-Large cosine similarity (current/original method)
    case gteLargeEmbedding = "gte-large-embedding"
    /// Modern embedding-only: Qwen3-Embedding with instruction following
    case qwen3Embedding = "qwen3-embedding"
    /// Benchmark/research: Reranker scores every DB entry (slow, O(N*M))
    case qwen3Reranker = "qwen3-reranker"
    /// Best quality: Qwen3-Embedding top-K + Qwen3-Reranker refinement
    case qwen3TwoStage = "qwen3-two-stage"
    /// Paper hybrid: GTE-Large embedding + Claude Haiku API verification (future)
    case gteLargeHaiku = "gte-large-haiku"
    /// Review-optimized: Qwen3-Embedding top-10 + Qwen3-Reranker with review triage
    case qwen3SmartTriage = "qwen3-smart-triage"
    /// Single-stage: Qwen3 generative LLM processes candidates from entire DB
    case qwen3LLMOnly = "qwen3-llm-only"
    /// Two-stage: Qwen3-Embedding retrieval + Qwen3 generative selection
    case embeddingLLM = "embedding-llm"
    /// GTE-Large + Haiku v2: prompt caching, neutral framing, minimal user message
    case gteLargeHaikuV2 = "gte-large-haiku-v2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gteLargeEmbedding: return "GTE-Large Embedding"
        case .qwen3Embedding: return "Qwen3-Embedding"
        case .qwen3Reranker: return "Qwen3-Reranker (Benchmark)"
        case .qwen3TwoStage: return "Qwen3 Two-Stage"
        case .gteLargeHaiku: return "GTE-Large + Haiku"
        case .gteLargeHaikuV2: return "GTE-Large + Haiku v2"
        case .qwen3SmartTriage: return "Smart Triage"
        case .qwen3LLMOnly: return "Qwen3 LLM Judge"
        case .embeddingLLM: return "Embedding + LLM"
        }
    }

    var shortDescription: String {
        switch self {
        case .gteLargeEmbedding:
            return "Cosine similarity with GTE-Large embeddings. Paper validation method."
        case .qwen3Embedding:
            return "Instruction-following embedding model with custom matching context."
        case .qwen3Reranker:
            return "Cross-encoder scores every database entry. Highest accuracy potential but extremely slow."
        case .qwen3TwoStage:
            return "Embedding retrieval + cross-encoder reranking. Best accuracy."
        case .gteLargeHaiku:
            return "GTE-Large retrieval + Claude Haiku verification. Requires API key."
        case .gteLargeHaikuV2:
            return "GTE-Large retrieval + Claude Haiku v2 with prompt caching. Requires API key."
        case .qwen3SmartTriage:
            return "Embedding retrieval + reranker scoring with review triage. Optimized for review workflow."
        case .qwen3LLMOnly:
            return "Single-stage generative matching. Best for small databases (under 500 items)."
        case .embeddingLLM:
            return "Embedding retrieval + generative LLM selection. On-device reasoning over top candidates."
        }
    }

    /// Models required for this pipeline
    var requiredModelKeys: [String] {
        switch self {
        case .gteLargeEmbedding: return ["gte-large"]
        case .qwen3Embedding: return ["qwen3-emb-4b-4bit"]
        case .qwen3Reranker: return ["qwen3-reranker-0.6b"]
        case .qwen3TwoStage: return ["qwen3-emb-4b-4bit", "qwen3-reranker-0.6b"]
        case .gteLargeHaiku: return ["gte-large"]
        case .gteLargeHaikuV2: return ["gte-large"]
        case .qwen3SmartTriage: return ["qwen3-emb-4b-4bit", "qwen3-reranker-0.6b"]
        case .qwen3LLMOnly: return ["qwen3-judge-4b-4bit"]
        case .embeddingLLM: return ["qwen3-emb-4b-4bit", "qwen3-judge-4b-4bit"]
        }
    }

    /// Embedding model key used by this pipeline (nil if no embedding stage)
    var embeddingModelKey: String? {
        switch self {
        case .gteLargeEmbedding: return "gte-large"
        case .qwen3Embedding: return "qwen3-emb-4b-4bit"
        case .qwen3Reranker: return nil
        case .qwen3TwoStage: return "qwen3-emb-4b-4bit"
        case .gteLargeHaiku: return "gte-large"
        case .gteLargeHaikuV2: return "gte-large"
        case .qwen3SmartTriage: return "qwen3-emb-4b-4bit"
        case .qwen3LLMOnly: return nil
        case .embeddingLLM: return "qwen3-emb-4b-4bit"
        }
    }

    /// Whether this pipeline supports custom matching instructions
    var supportsCustomInstruction: Bool {
        switch self {
        case .gteLargeEmbedding: return false  // GTE-Large is symmetric, no instruction support
        case .qwen3Embedding: return true
        case .qwen3Reranker: return true
        case .qwen3TwoStage: return true
        case .gteLargeHaiku: return true   // Haiku uses rich haikuPrompt instructions
        case .gteLargeHaikuV2: return true
        case .qwen3SmartTriage: return true
        case .qwen3LLMOnly: return true
        case .embeddingLLM: return true
        }
    }

    /// Whether this pipeline is available now (vs future/deferred)
    var isImplemented: Bool {
        switch self {
        case .gteLargeEmbedding: return true
        case .qwen3Embedding: return true
        case .qwen3Reranker: return true
        case .qwen3TwoStage: return true
        case .gteLargeHaiku: return true
        case .gteLargeHaikuV2: return true
        case .qwen3SmartTriage: return true
        case .qwen3LLMOnly: return true
        case .embeddingLLM: return true
        }
    }

    /// Whether this pipeline requires an external API key
    var requiresAPIKey: Bool {
        switch self {
        case .gteLargeHaiku, .gteLargeHaikuV2: return true
        default: return false  // LLM pipelines run on-device, no API key needed
        }
    }

    /// The score type produced by this pipeline
    var defaultScoreType: ScoreType {
        switch self {
        case .gteLargeEmbedding, .qwen3Embedding: return .cosineSimilarity
        case .qwen3Reranker, .qwen3TwoStage, .qwen3SmartTriage: return .rerankerProbability
        case .gteLargeHaiku, .gteLargeHaikuV2: return .llmSelected
        case .qwen3LLMOnly, .embeddingLLM: return .generativeSelection
        }
    }

    /// Performance warning shown in the UI when this pipeline may be slow
    var performanceWarning: String? {
        switch self {
        case .qwen3Reranker:
            return "Runtime scales linearly with database size. Intended for benchmarking small datasets only."
        case .qwen3LLMOnly:
            return "Very slow for larger databases. Runtime scales linearly with database size."
        default:
            return nil
        }
    }

    /// Which user-facing pipeline mode this type belongs to
    var pipelineMode: PipelineMode {
        switch self {
        case .gteLargeEmbedding, .gteLargeHaiku: return .researchValidation
        case .gteLargeHaikuV2: return .standard
        case .qwen3Embedding, .qwen3Reranker, .qwen3TwoStage, .qwen3SmartTriage,
             .qwen3LLMOnly, .embeddingLLM: return .standard
        }
    }
}

// MARK: - Per-Pipeline Performance Defaults

extension PipelineType {
    /// Default top-K for this pipeline type
    var defaultTopK: Int {
        switch self {
        case .gteLargeEmbedding, .qwen3Embedding: return 20
        case .qwen3TwoStage: return 10
        case .qwen3SmartTriage: return 10
        case .gteLargeHaiku: return 5
        case .gteLargeHaikuV2: return 20
        case .embeddingLLM: return 5
        case .qwen3Reranker, .qwen3LLMOnly: return 5
        }
    }

    /// Default embedding batch size for this pipeline, scaled by model size.
    /// Larger models need smaller batches to stay within memory.
    func defaultEmbeddingBatchSize(modelKey: String?) -> Int {
        switch modelKey {
        case "qwen3-emb-8b-4bit": return 16
        case "qwen3-emb-4b-4bit": return 24
        default: return 32  // GTE-Large, 0.6B models
        }
    }

    /// Default matching batch size (uniform across pipelines)
    var defaultMatchingBatchSize: Int { 128 }

    /// Default chunk size (uniform across pipelines)
    var defaultChunkSize: Int { 500 }

    /// Whether this pipeline has an embedding stage with configurable performance
    var hasEmbeddingStage: Bool {
        embeddingModelKey != nil
    }
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

    var defaultPipelineType: PipelineType {
        switch self {
        case .standard: return .gteLargeEmbedding
        case .researchValidation: return .gteLargeEmbedding
        }
    }

    /// Pipeline types available under this mode.
    /// Note: .gteLargeHaiku is NOT in either list. It's controlled by the Haiku verification toggle.
    var availablePipelineTypes: [PipelineType] {
        switch self {
        case .standard: return [.gteLargeEmbedding, .qwen3Embedding, .qwen3TwoStage, .qwen3SmartTriage, .embeddingLLM, .qwen3LLMOnly, .qwen3Reranker, .gteLargeHaikuV2]
        case .researchValidation: return [.gteLargeEmbedding]
        }
    }
}

/// User-selectable model size within a model family
enum ModelSize: String, CaseIterable, Identifiable, Codable {
    case small = "0.6B"
    case medium = "4B"
    case large = "8B"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

extension ModelFamily {
    /// Available sizes for this model family
    var availableSizes: [ModelSize] {
        switch self {
        case .qwen3Embedding: return [.small, .medium, .large]
        case .qwen3Reranker: return [.small, .medium]
        case .gteLarge: return []
        case .qwen3Generative: return [.small, .medium]
        }
    }

    /// Get the model key for a specific size
    func modelKey(for size: ModelSize) -> String? {
        switch self {
        case .qwen3Embedding:
            switch size {
            case .small: return "qwen3-emb-0.6b-4bit"
            case .medium: return "qwen3-emb-4b-4bit"
            case .large: return "qwen3-emb-8b-4bit"
            }
        case .qwen3Reranker:
            switch size {
            case .small: return "qwen3-reranker-0.6b"
            case .medium: return "qwen3-reranker-4b"
            case .large: return nil
            }
        case .gteLarge: return "gte-large"
        case .qwen3Generative:
            switch size {
            case .small: return "qwen3-judge-0.6b-4bit"
            case .medium: return "qwen3-judge-4b-4bit"
            case .large: return nil
            }
        }
    }
}

/// Preset matching instructions for embedding, reranker, and Haiku models.
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
            return "You are a food science expert matching raw ingredients and commodities. The survey may describe branded products, recipe components, or colloquial food names. Match to the closest standardized raw ingredient, ignoring brand names, packaging, and preparation details. Focus on what the base food commodity actually is."
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
