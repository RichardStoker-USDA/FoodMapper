import Foundation
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "haiku-prompt")

/// Three-tier decision from Haiku response parsing.
/// Confident matches auto-accept, reviews go to human triage, no-matches auto-reject.
enum HaikuDecision {
    case match(Int)       // Confident match, 0-based candidate index
    case review(Int)      // Possible match but uncertain, needs human review
    case noMatch          // No suitable candidate
}

/// Prompt strategy for the Haiku reranking pipeline.
/// Paper replication uses the exact format from hybrid_semantic_haiku2.py.
/// Production uses a numbered-list format that eliminates paraphrasing errors.
enum HaikuPromptStrategy: String, Sendable {
    /// Paper's exact format: Python list of candidates, free-text response.
    /// Used by Behind the Research showcase to replicate published results.
    case paperReplication

    /// Numbered candidate list with number-only response.
    /// Eliminates paraphrasing ("whole milk" vs "milk, whole") by requiring
    /// the model to return only a candidate number or "0" for no match.
    case production

    /// V2: big system prompt (~2,200 tokens) w/ 5 worked examples, tiny user message.
    /// Built for prompt caching.
    case productionV2
}

/// Prompt construction + response parsing for Haiku pipelines.
/// AnthropicAPIClient is just the transport; all prompt logic lives here.
struct HaikuPromptBuilder {

    /// Default system prompt for a given strategy
    static func systemPrompt(for strategy: HaikuPromptStrategy) -> String {
        switch strategy {
        case .paperReplication:
            return "You are a strict food matching assistant. Return the best matching text from the provided list or 'none'. Do not include additional text."
        case .production:
            return """
            You are a strict food matching validator for nutritional research. Your role is to REJECT matches that do not meet strict criteria, not to find the closest option.

            RULES (non-negotiable):
            1. SAME ANIMAL OR PLANT SOURCE REQUIRED. If no candidate comes from the same biological source, respond "0".
            2. NUTRITIONAL SIMILARITY REQUIRED (80%+ similar in calories and macronutrients). If uncertain, use "R:N" to flag for review.
            3. When in doubt between a confident match and no match, use "R:N" to flag for human review. A review flag is better than a wrong match or a missed match.

            RESPONSE FORMAT (one of three):
            - A number (1-N): confident match. Same biological source AND strong nutritional similarity.
            - "R:N" where N is a candidate number: possible match but uncertain. Use this for ambiguous candidates, partial matches, or borderline cases.
            - "0": no match at all. No candidate shares the same biological source.

            Respond with ONLY one of these formats, nothing else.
            """
        case .productionV2:
            return """
            You are a food matching assistant for nutritional research. You evaluate whether a food description from a dietary study matches any candidate entry in a food composition database.

            CONTEXT:
            Researchers collect dietary recall data where participants describe what they ate. These descriptions use various vocabularies, from standardized USDA FNDDS terms (e.g., "Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw") to informal terms (e.g., "grilled chicken"), to branded product names (e.g., "Tyson Grilled & Ready Chicken Breast"). The target database may use entirely different naming conventions. Your job is to determine whether any candidate refers to the same underlying food as the input, despite differences in wording, specificity, or vocabulary.

            You receive an input food description and a numbered list of candidates with cosine similarity scores from an embedding model (GTE-Large). These scores indicate textual similarity but are NOT nutritional similarity. Score distributions vary depending on the datasets involved. A high score does not guarantee a correct match and a moderately lower score does not guarantee a wrong match. Use the scores as a rough reference; your food knowledge matters more.

            MATCHING RULES (in priority order):
            1. SAME BIOLOGICAL SOURCE REQUIRED. The input and candidate must come from the same animal, plant, or food product type. Beef does not match pork. Olive oil does not match canola oil. Wheat flour does not match rice flour. Cow's milk does not match oat milk or almond milk.
            2. SAME GENERAL FOOD FORM PREFERRED. Raw vs cooked, whole vs ground, fresh vs canned, liquid vs powdered are meaningful distinctions. However, if the biological source matches and no closer candidate exists, preparation differences alone are acceptable. "Raw chicken breast" can match "Chicken breast" when no raw-specific entry exists.
            3. BRANDED FOODS MATCH THEIR GENERIC EQUIVALENTS. "Kraft American Cheese" matches "American cheese." "Budweiser" matches "beer, lager." "Cheerios" matches "oat cereal, toasted." Match based on what the product IS, not the brand name.
            4. COMPOSITE FOODS AND MEALS. Multi-ingredient descriptions like "beef stew" or "chicken Caesar salad" should match database entries describing the same dish or a close equivalent. Do not match a composite food to a single raw ingredient unless no composite entry exists in the candidates.

            WHEN TO RETURN 0 (no match):
            - No candidate shares the same biological source as the input
            - The input is a spice, seasoning, oil, or condiment and no candidate is in that category
            - The input and all candidates are from fundamentally different food groups (e.g., input is a grain product, all candidates are dairy)
            - You are certain no candidate represents the same food

            WHEN TO RETURN R:N (flag for review):
            - A candidate shares the same biological source but you are unsure about the form, preparation, or nutritional equivalence
            - The best candidate is a reasonable proxy but not an exact match (e.g., "2% milk" matching "whole milk")
            - Two candidates seem equally valid and you cannot confidently choose
            - Use R:N rather than guessing. A review flag is better than a wrong match or a missed match.

            WHEN TO RETURN N (confident match):
            - A candidate clearly refers to the same food as the input, from the same biological source, in a similar form
            - You are confident a nutrition scientist would accept this as a valid match

            RESPONSE FORMAT (one of three options, nothing else):
            - N (a number 1 through the candidate count): confident match
            - R:N (e.g., R:2): possible match, flag candidate N for human review
            - 0: no match exists among the candidates

            EXAMPLES:

            Input: "Rice, white, long-grain, regular, raw, enriched"
            1. Enriched long white rice (Mahatma) (0.91)
            2. Brown rice (0.88)
            3. Rice flour (0.87)
            4. Wild rice (0.87)
            5. Rice noodles (0.85)
            Answer: 1
            Why: Candidate 1 is the same food (white long-grain rice, enriched). Brand name (Mahatma) does not change the match. Candidates 2-5 are different rice products.

            Input: "Oil, canola"
            1. Soy milk (0.86)
            2. Corn Starch (0.85)
            3. Sunflower seeds (0.85)
            4. All purpose flour (0.84)
            5. Table sugar (0.83)
            Answer: 0
            Why: Canola oil is a cooking oil. None of the candidates are oils. The embedding model found textually adjacent items but none are the same food category. This is a clear no-match.

            Input: "Beef, ground, 80% lean meat / 20% fat, raw"
            1. Beef round tip steak (0.89)
            2. Ground pork (0.88)
            3. Ground turkey (0.88)
            4. Chicken breast (0.85)
            5. Pork tenderloin (0.84)
            Answer: R:1
            Why: Candidate 1 is beef (same biological source) but a steak cut, not ground beef. The form differs significantly. Candidates 2-3 are ground meat but from different animals. Flag candidate 1 for a nutrition scientist to decide whether beef steak is an acceptable proxy for ground beef in their research context.

            Input: "Cheese, cottage, creamed, large or small curd"
            1. Cottage cheese (0.92)
            2. Cream cheese (0.89)
            3. Ricotta cheese (0.88)
            4. Sour cream (0.87)
            5. Sharp Chedder Cheese (0.85)
            Answer: 1
            Why: Candidate 1 is the same food. "Creamed, large or small curd" is a preparation detail; both refer to cottage cheese. Other candidates are different dairy products.

            Input: "Spices, pepper, black"
            1. Black tea (0.87)
            2. Dried apricots (0.84)
            3. Ground pork (0.84)
            4. Cocoa powder (0.83)
            5. Table sugar (0.83)
            Answer: 0
            Why: Black pepper is a spice. None of the candidates are spices or seasonings. "Black tea" shares the word "black" but is a beverage. This is a keyword overlap, not a food match.
            """
        }
    }

    /// Build the user message for a single matching task
    static func buildUserMessage(
        query: String,
        candidates: [String],
        strategy: HaikuPromptStrategy,
        scores: [Float]? = nil
    ) -> String {
        switch strategy {
        case .paperReplication:
            return buildPaperReplicationMessage(query: query, candidates: candidates)
        case .production:
            return buildProductionMessage(query: query, candidates: candidates, scores: scores)
        case .productionV2:
            return buildProductionV2Message(query: query, candidates: candidates, scores: scores)
        }
    }

    /// Parse the model's response into a HaikuDecision.
    /// Paper replication maps to .match/.noMatch only (no review tier).
    /// Production supports all three tiers: match, review, noMatch.
    static func parseResponse(
        _ response: String,
        candidates: [String],
        strategy: HaikuPromptStrategy
    ) -> HaikuDecision {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        switch strategy {
        case .paperReplication:
            if let index = parsePaperReplicationResponse(trimmed, candidates: candidates) {
                return .match(index)
            }
            return .noMatch
        case .production, .productionV2:
            return parseProductionResponseThreeTier(trimmed, candidateCount: candidates.count)
        }
    }

    // MARK: - Paper Replication (matches hybrid_semantic_haiku2.py)

    private static func buildPaperReplicationMessage(query: String, candidates: [String]) -> String {
        let candidateNames = candidates.map { "'\($0)'" }
        let candidateList = "[\(candidateNames.joined(separator: ", "))]"

        // Paper's exact prompt -- do not modify. Used by Behind the Research showcase.
        return """
        Given the food item: "\(query)"

        Find the most nutritionally similar match from this list:
        \(candidateList)

        Matching criteria (in order of priority):
        1. Same animal or plant source
        2. Nutritional profile similarity (macronutrients, micronutrients, calories per serving)
        3. Same preparation method
        4. Semantic/name similarity

        Rules:
        - Return ONLY the exact text of the best matching item from the list
        - Be STRICT: if there is not a match with the same animal or plant source, return "none"
        - Be STRICT: if there is not a match with strong nutritional similarity (80%+ similar nutritionally), return "none"
        - Your response must contain ONLY the matching text or "none" - no explanations

        Best food match:
        """
    }

    /// Match response text against candidate list (exact match, then substring).
    /// Returns 0-based index or nil for "none"/no match.
    private static func parsePaperReplicationResponse(_ trimmed: String, candidates: [String]) -> Int? {
        if trimmed.lowercased() == "none" {
            return nil
        }

        // Exact match (case-insensitive)
        for (i, candidate) in candidates.enumerated() {
            if candidate.lowercased() == trimmed.lowercased() {
                return i
            }
        }

        // Substring match (response contains candidate or vice versa)
        let responseLower = trimmed.lowercased()
        for (i, candidate) in candidates.enumerated() {
            let candidateLower = candidate.lowercased()
            if responseLower.contains(candidateLower) || candidateLower.contains(responseLower) {
                return i
            }
        }

        logger.debug("Paper response '\(trimmed.prefix(80))' didn't match any candidate")
        return nil
    }

    // MARK: - Production V2 (minimal user message, everything else in system prompt)

    private static func buildProductionV2Message(query: String, candidates: [String], scores: [Float]? = nil) -> String {
        let numberedList = candidates.enumerated().map { index, text in
            if let scores = scores, index < scores.count {
                return "\(index + 1). \(text) (\(String(format: "%.2f", scores[index])))"
            }
            return "\(index + 1). \(text)"
        }.joined(separator: "\n")

        return "\"\(query)\"\n\(numberedList)"
    }

    // MARK: - Production (numbered list, number-only response)

    private static func buildProductionMessage(query: String, candidates: [String], scores: [Float]? = nil) -> String {
        let numberedList = candidates.enumerated().map { index, text in
            if let scores = scores, index < scores.count {
                return "\(index + 1). \(text) (similarity: \(String(format: "%.2f", scores[index])))"
            }
            return "\(index + 1). \(text)"
        }.joined(separator: "\n")

        let scoreNote = scores != nil
            ? "\n\nSemantic similarity scores are provided for reference. Higher scores indicate closer textual meaning."
            : ""

        return """
        Given the food item: "\(query)"

        Find the most nutritionally similar match from this numbered list:
        \(numberedList)\(scoreNote)

        Matching criteria (in order of priority):
        1. Same animal or plant source (required)
        2. Same preparation method and form (wet vs dry, raw vs cooked)
        3. Nutritional profile similarity (80%+ similar)

        Examples:
        - "grilled chicken breast" with candidates ["roasted chicken breast", "chicken thigh"] -> "1" (confident match)
        - "whole milk" with candidates ["condensed milk", "oat milk", "heavy cream"] -> "0" (none match nutritionally)
        - "apple" with candidates ["apple juice", "pear", "dried apple slices"] -> "0" (different form/nutrition)
        - "turkey breast" with candidates ["turkey deli meat", "chicken breast"] -> "R:1" (same source but uncertain form)

        Rules:
        - Respond with the number of the best matching item (e.g. "3") if you are confident
        - Respond "R:N" (e.g. "R:2") if a candidate is a possible match but you are uncertain
        - Respond "0" if no candidate shares the same animal or plant source
        - When torn between match and no-match, prefer "R:N" over "0"
        - Your response must contain ONLY one of: a number, "R:N", or "0"
        """
    }

    /// Parse a three-tier production response.
    /// "0" = no match. "1"-"N" = confident match (0-based index). "R:N" = review (0-based index).
    /// Handles edge cases like "3 (closest match)" by extracting the first integer.
    private static func parseProductionResponseThreeTier(_ trimmed: String, candidateCount: Int) -> HaikuDecision {
        // Check for "R:N" review format first (case-insensitive)
        let upperTrimmed = trimmed.uppercased()
        if upperTrimmed.hasPrefix("R:") || upperTrimmed.hasPrefix("R :")  {
            let afterR = upperTrimmed.dropFirst(2)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(afterR), number >= 1 && number <= candidateCount {
                return .review(number - 1)
            }
            // Fallback: extract any number after R
            let digits = afterR.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .first(where: { !$0.isEmpty })
            if let digitStr = digits, let number = Int(digitStr), number >= 1 && number <= candidateCount {
                return .review(number - 1)
            }
            logger.debug("Review response '\(trimmed.prefix(80))' had invalid candidate number")
            return .noMatch
        }

        // Extract the first integer from the response
        let digits = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .first(where: { !$0.isEmpty })

        guard let numberString = digits, let number = Int(numberString) else {
            logger.debug("Production response '\(trimmed.prefix(80))' contained no number")
            return .noMatch
        }

        if number == 0 {
            return .noMatch
        }

        // Convert 1-based to 0-based, validate range
        let index = number - 1
        guard index >= 0 && index < candidateCount else {
            logger.debug("Production response number \(number) out of range (1-\(candidateCount))")
            return .noMatch
        }

        return .match(index)
    }
}
