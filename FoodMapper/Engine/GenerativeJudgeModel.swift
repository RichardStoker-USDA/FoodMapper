import Foundation
import Hub
import MLX
import MLXLMCommon
import MLXLLM
import Tokenizers
import os

private let logger = Logger(subsystem: "com.foodmapper", category: "generative-judge")

/// Metadata describing a generative judge model
struct GenerativeModelInfo: Sendable {
    let key: String
    let displayName: String
}

/// How the LLM judge labels and selects candidates
enum JudgeResponseFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Candidates labeled A-Z, no-match = X. Max 26 candidates.
    case letter
    /// Candidates labeled 1-N, no-match = 0. Scales to any count.
    case number
    /// Candidates shown by full name, model responds with name. Needs fuzzy matching.
    case text

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .letter: return "Letter (A-Z)"
        case .number: return "Number (1-N)"
        case .text: return "Text (name)"
        }
    }

    /// Max candidates this format supports
    var maxCandidates: Int {
        switch self {
        case .letter: return 26
        case .number: return 999
        case .text: return 999
        }
    }
}

/// Result from generative LLM judging a single query against candidates
struct JudgeResult: Sendable {
    /// Index of the selected candidate (0-based in the ORIGINAL order), nil if X/NONE selected
    let selectedIndex: Int?
    /// Softmax probability for the selected choice
    let confidence: Float
    /// Label probabilities for all candidates + X
    let labelProbabilities: [String: Float]
    /// Raw generated text from the model (for debugging)
    let generatedText: String?

    init(selectedIndex: Int?, confidence: Float, labelProbabilities: [String: Float], generatedText: String? = nil) {
        self.selectedIndex = selectedIndex
        self.confidence = confidence
        self.labelProbabilities = labelProbabilities
        self.generatedText = generatedText
    }
}

/// Generative LLM judge for food matching. Presents labeled candidates,
/// extracts selection via text gen + logit confidence.
///
/// Formats: letter (A-Z/X), number (1-N/0), text (fuzzy name match).
/// judgeViaGeneration() preferred -- falls back to logit argmax if gen is ambiguous.
/// judge() is pure logit extraction (letter format only, faster).
///
/// Candidates shuffled each call to kill positional bias.
/// Qwen3-4B-4bit (2.28 GB) recommended; 0.6B works but weaker.
actor GenerativeJudgeModel {
    nonisolated let info: GenerativeModelInfo

    private let repoId: String
    private var container: ModelContainer?

    /// Token IDs for candidate labels A-Z and X
    private var labelTokenIds: [String: Int] = [:]

    /// All letter labels A-Z
    static let allLetterLabels = (0..<26).map { String(UnicodeScalar(65 + $0)) }  // A-Z
    /// Subset used for backward compat (original 5-candidate limit)
    static let candidateLabels = ["A", "B", "C", "D", "E"]
    /// "X" is single-token, giving it equal footing with A-E in logit extraction
    static let noneLabel = "X"

    /// Production system prompt for food matching judgment.
    /// Modeled after HaikuPromptBuilder's matching criteria with explicit food-science guidance.
    /// The response format instruction is NOT included here -- it's in the user message
    /// so it adapts to letter/number/text format.
    static let defaultSystemPrompt = """
        You are a food matching expert for nutrition research. Given a food description from a \
        dietary survey and labeled candidates from a food reference database, select the \
        single best match.

        Matching criteria (in order of priority):
        1. Same animal or plant source (chicken vs turkey, beef vs pork, apple vs pear, \
        wheat vs rice). A mismatch here means the candidate is wrong.
        2. Nutritional profile similarity. Same food group and similar macronutrient balance. \
        Whole milk matches reduced-fat milk better than cream.
        3. Preparation method. Grilled chicken matches roasted chicken better than raw chicken. \
        Fresh, frozen, canned, dried are meaningful distinctions but secondary to identity.
        4. Brand-to-generic mapping. Cheerios -> oat cereal, Coca-Cola -> cola soft drink. \
        Ignore brand names, flavor variants, and package sizes.
        5. Composite dishes match to the closest whole-dish entry, not individual ingredients. \
        "chicken stir fry" matches "stir-fried chicken with vegetables" not "chicken breast".

        Select "no match" ONLY when the food described is fundamentally different from ALL \
        candidates. Related foods from the same category are acceptable matches. A weak match \
        from the correct food group is better than no match. When in doubt, prefer the closest \
        candidate.
        """

    var isLoaded: Bool {
        container != nil
    }

    init(repoId: String, key: String, displayName: String) {
        self.repoId = repoId
        self.info = GenerativeModelInfo(key: key, displayName: displayName)
    }

    // MARK: - Loading

    func load() async throws {
        try await load(hub: HubApi())
    }

    func load(hub: HubApi) async throws {
        let configuration = MLXLMCommon.ModelConfiguration(id: repoId)

        logger.info("Loading generative judge from \(self.repoId)...")

        container = try await MLXLMCommon.loadModelContainer(
            hub: hub,
            configuration: configuration
        ) { progress in
            logger.debug("Download progress: \(Int(progress.fractionCompleted * 100))%")
        }

        try await resolveTokenIds()

        logger.info("Generative judge loaded (\(self.labelTokenIds.count) label tokens resolved)")
    }

    func unload() {
        container = nil
        labelTokenIds.removeAll()
        Memory.clearCache()
        logger.info("Generative judge unloaded")
    }

    /// Resolve token IDs for A-Z, X, and 0-9 labels
    private func resolveTokenIds() async throws {
        guard let container = container else {
            throw GenerativeJudgeError.modelNotLoaded
        }

        // Resolve all letter labels (A-Z), X, and number tokens (0-9)
        let allLabels = Self.allLetterLabels + [Self.noneLabel] + (0...9).map { String($0) }

        let resolved = await container.perform { context in
            let tokenizer = context.tokenizer
            var ids: [String: Int] = [:]
            for label in allLabels {
                if let tokenId = tokenizer.convertTokenToId(label) {
                    ids[label] = tokenId
                }
            }
            return ids
        }

        // Verify we got at least A and X
        guard resolved["A"] != nil, resolved[Self.noneLabel] != nil else {
            throw GenerativeJudgeError.tokenResolutionFailed
        }

        self.labelTokenIds = resolved
        logger.debug("Resolved \(resolved.count) label tokens (A-Z, X, 0-9)")
    }

    // MARK: - Judging

    /// Judge a single query against a set of candidates via logit extraction.
    ///
    /// Shuffles candidates to eliminate positional bias, runs a forward pass,
    /// and extracts logits for the label tokens. Softmax with optional temperature
    /// over those logits determines selection. Only works with letter format.
    ///
    /// - Parameters:
    ///   - query: The food description to match
    ///   - candidates: Candidate texts from the database
    ///   - instruction: Optional system prompt override
    ///   - temperature: Softmax temperature (lower = more confident). Default 0.3.
    ///   - responseFormat: Label format for candidates. Default .letter.
    ///   - allowThinking: If true, removes the empty think block so model can reason. Default false.
    /// - Returns: JudgeResult with selected candidate index (in original order) and confidence
    func judge(
        query: String,
        candidates: [String],
        instruction: String? = nil,
        temperature: Float = 0.3,
        responseFormat: JudgeResponseFormat = .letter,
        allowThinking: Bool = false
    ) async throws -> JudgeResult {
        guard let container = container else {
            throw GenerativeJudgeError.modelNotLoaded
        }

        let candidateCount = min(candidates.count, responseFormat.maxCandidates)
        guard candidateCount > 0 else {
            throw GenerativeJudgeError.noCandidates
        }

        // Shuffle candidates to eliminate positional bias
        let originalIndices = Array(0..<candidateCount)
        let shuffledMapping = originalIndices.shuffled()
        let shuffledCandidates = shuffledMapping.map { candidates[$0] }

        // Build labels based on response format
        let activeLabels = labelsForFormat(responseFormat, count: candidateCount)
        let noMatchLabel = noMatchLabelForFormat(responseFormat)
        let allActiveLabels = activeLabels + [noMatchLabel]

        // Collect token IDs for active labels
        let activeTokenIds: [(label: String, tokenId: Int)] = allActiveLabels.compactMap { label in
            guard let tokenId = labelTokenIds[label] else { return nil }
            return (label, tokenId)
        }

        guard !activeTokenIds.isEmpty else {
            throw GenerativeJudgeError.tokenResolutionFailed
        }

        let prompt = formatPrompt(
            query: query,
            candidates: shuffledCandidates,
            labels: activeLabels,
            instruction: instruction,
            responseFormat: responseFormat,
            allowThinking: allowThinking
        )

        logger.info("[Model] GenerativeJudge | judge() | Format: \(responseFormat.rawValue) | Think: \(allowThinking)")
        logger.info("[Model] GenerativeJudge | judge() | Query: \(query.prefix(80)) | Candidates: \(candidateCount)")
        logger.info("[Model] GenerativeJudge | judge() | Additional instruction: \(instruction?.prefix(100) ?? "(none -- using defaultSystemPrompt only)")")

        // Tokenize and run forward pass
        let tokenIdsCaptured = activeTokenIds
        let temp = max(temperature, 0.01)
        let noMatch = noMatchLabel
        let result: JudgeResult = try await container.perform { context in
            let tokenizer = context.tokenizer
            let model = context.model
            let tokens = tokenizer.encode(text: prompt)

            let inputArray = MLXArray(tokens).reshaped(1, tokens.count)
            let cache = model.newCache(parameters: nil)
            let input = LMInput.Text(tokens: inputArray, mask: nil)
            let output = model(input, cache: cache, state: nil)

            let logits = output.logits
            let seqLen = tokens.count

            let lastLogits: MLXArray
            if logits.ndim == 3 {
                lastLogits = logits[0, seqLen - 1]
            } else {
                lastLogits = logits[seqLen - 1]
            }

            // Extract logits for each label token
            var labelLogits: [(label: String, logit: Float)] = []
            for (label, tokenId) in tokenIdsCaptured {
                let logit = lastLogits[tokenId].item(Float.self)
                labelLogits.append((label, logit))
            }

            // Softmax with temperature over label logits
            let scaledLogits = labelLogits.map { $0.logit / temp }
            let maxLogit = scaledLogits.max() ?? 0
            let exps = scaledLogits.map { exp($0 - maxLogit) }
            let sumExp = exps.reduce(0, +)
            let probs = exps.map { $0 / sumExp }

            // Build probability map (using shuffled labels)
            var probMap: [String: Float] = [:]
            for (i, item) in labelLogits.enumerated() {
                probMap[item.label] = probs[i]
            }

            // Find best label
            guard let bestIdx = probs.enumerated().max(by: { $0.element < $1.element })?.offset else {
                return JudgeResult(selectedIndex: nil, confidence: 0, labelProbabilities: probMap)
            }

            let bestLabel = labelLogits[bestIdx].label
            let bestProb = probs[bestIdx]

            // Map label back to ORIGINAL candidate index via shuffle mapping
            let selectedIndex: Int?
            if bestLabel == noMatch {
                selectedIndex = nil
            } else if let labelIdx = activeLabels.firstIndex(of: bestLabel) {
                selectedIndex = shuffledMapping[labelIdx]
            } else {
                selectedIndex = nil
            }

            // Unshuffle the probability map so labels correspond to original positions
            var unshuffledProbMap: [String: Float] = [:]
            for (shuffledPos, originalIdx) in shuffledMapping.enumerated() {
                let shuffledLabel = activeLabels[shuffledPos]
                let originalLabel = activeLabels[originalIdx]
                if let prob = probMap[shuffledLabel] {
                    unshuffledProbMap[originalLabel] = prob
                }
            }
            unshuffledProbMap[noMatch] = probMap[noMatch]

            return JudgeResult(
                selectedIndex: selectedIndex,
                confidence: bestProb,
                labelProbabilities: unshuffledProbMap
            )
        }

        return result
    }

    /// Judge multiple queries against their respective candidate sets.
    ///
    /// Processes items sequentially with GPU memory cleanup between items.
    /// Reports progress via callback.
    func judgeAll(
        queries: [String],
        candidateSets: [[String]],
        instruction: String? = nil,
        temperature: Float = 0.3,
        responseFormat: JudgeResponseFormat = .letter,
        allowThinking: Bool = false,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> [JudgeResult] {
        guard queries.count == candidateSets.count else {
            throw GenerativeJudgeError.inputMismatch
        }

        let total = queries.count
        var results: [JudgeResult] = []
        results.reserveCapacity(total)

        for i in 0..<total {
            try Task.checkCancellation()

            let result = try await judgeViaGeneration(
                query: queries[i],
                candidates: candidateSets[i],
                instruction: instruction,
                temperature: temperature,
                responseFormat: responseFormat,
                allowThinking: allowThinking
            )
            results.append(result)
            onProgress?(i + 1, total)

            // Clear GPU memory periodically
            if (i + 1) % 10 == 0 {
                Memory.clearCache()
            }
        }

        return results
    }

    // MARK: - Text Generation Judge

    /// Judge via text generation, parsing for the selected candidate.
    /// Supports letter (A-Z/X), number (1-N/0), and text (fuzzy name match) formats.
    /// Falls back to logit extraction (letter/number) if generation doesn't produce a valid label.
    /// When allowThinking is true, the model generates a reasoning chain before answering.
    func judgeViaGeneration(
        query: String,
        candidates: [String],
        instruction: String? = nil,
        temperature: Float = 0.0,
        responseFormat: JudgeResponseFormat = .letter,
        allowThinking: Bool = false
    ) async throws -> JudgeResult {
        guard let container = container else {
            throw GenerativeJudgeError.modelNotLoaded
        }

        let candidateCount = min(candidates.count, responseFormat.maxCandidates)
        guard candidateCount > 0 else {
            throw GenerativeJudgeError.noCandidates
        }

        // Shuffle candidates to eliminate positional bias
        let originalIndices = Array(0..<candidateCount)
        let shuffledMapping = originalIndices.shuffled()
        let shuffledCandidates = shuffledMapping.map { candidates[$0] }

        let activeLabels = labelsForFormat(responseFormat, count: candidateCount)
        let noMatchLabel = noMatchLabelForFormat(responseFormat)
        let validLabels = Set(activeLabels + [noMatchLabel])

        let prompt = formatPrompt(
            query: query,
            candidates: shuffledCandidates,
            labels: activeLabels,
            instruction: instruction,
            responseFormat: responseFormat,
            allowThinking: allowThinking
        )

        logger.info("[Model] GenerativeJudge | judgeViaGeneration() | Format: \(responseFormat.rawValue) | Think: \(allowThinking)")
        logger.info("[Model] GenerativeJudge | judgeViaGeneration() | Query: \(query.prefix(80)) | Candidates: \(candidateCount)")
        logger.info("[Model] GenerativeJudge | judgeViaGeneration() | Additional instruction: \(instruction?.prefix(100) ?? "(none -- using defaultSystemPrompt only)")")

        // Capture label token IDs before entering the perform closure
        let capturedLabelTokenIds = self.labelTokenIds
        let shuffledCandidatesCopy = shuffledCandidates

        // Max tokens to generate: more if thinking is enabled, less otherwise
        // Official Qwen3 recommends 512+ for thinking mode reasoning chains
        let maxGenerateTokens = allowThinking ? 512 : 15

        let result: JudgeResult = try await container.perform { context in
            let tokenizer = context.tokenizer
            let model = context.model
            let tokens = tokenizer.encode(text: prompt)

            let inputArray = MLXArray(tokens).reshaped(1, tokens.count)
            let cache = model.newCache(parameters: nil)
            let input = LMInput.Text(tokens: inputArray, mask: nil)
            let output = model(input, cache: cache, state: nil)

            // Get first-token logits for confidence scoring
            let logits = output.logits
            let seqLen = tokens.count
            let lastLogits: MLXArray
            if logits.ndim == 3 {
                lastLogits = logits[0, seqLen - 1]
            } else {
                lastLogits = logits[seqLen - 1]
            }

            // Generate tokens
            var generatedTokens: [Int] = []
            var currentLogits = lastLogits
            var currentCache = cache

            // Qwen3 official: DO NOT use greedy for thinking mode. Use temp=0.6, TopP=0.95.
            // For no-think classification (single letter/number), greedy is fine.
            let useGreedy = !allowThinking

            for _ in 0..<maxGenerateTokens {
                let nextToken: Int
                if useGreedy {
                    nextToken = currentLogits.argMax().item(Int.self)
                } else {
                    // Temperature sampling (temp=0.6 per Qwen3 official thinking mode)
                    let temperature: Float = 0.6
                    let scaled = currentLogits / MLXArray(temperature)
                    let maxVal = scaled.max()
                    let exps = MLX.exp(scaled - maxVal)
                    let probs = exps / exps.sum()
                    let probsArray = probs.asArray(Float.self)
                    // Top-p sampling (0.95 per Qwen3 official)
                    let topP: Float = 0.95
                    let indexed = probsArray.enumerated().sorted { $0.element > $1.element }
                    var cumSum: Float = 0
                    var candidates: [(Int, Float)] = []
                    for (idx, prob) in indexed {
                        cumSum += prob
                        candidates.append((idx, prob))
                        if cumSum >= topP { break }
                    }
                    // Renormalize and sample
                    let totalProb = candidates.reduce(Float(0)) { $0 + $1.1 }
                    let r = Float.random(in: 0..<totalProb)
                    var runSum: Float = 0
                    var sampled = candidates[0].0
                    for (idx, prob) in candidates {
                        runSum += prob
                        if runSum >= r { sampled = idx; break }
                    }
                    nextToken = sampled
                }
                generatedTokens.append(nextToken)

                // Check for EOS
                if let eosId = tokenizer.convertTokenToId("<|im_end|>"), nextToken == eosId {
                    break
                }
                if let eosId = tokenizer.convertTokenToId("<|endoftext|>"), nextToken == eosId {
                    break
                }

                // Run next step
                let nextInput = LMInput.Text(tokens: MLXArray([nextToken]).reshaped(1, 1), mask: nil)
                let nextOutput = model(nextInput, cache: currentCache, state: nil)
                if nextOutput.logits.ndim == 3 {
                    currentLogits = nextOutput.logits[0, 0]
                } else {
                    currentLogits = nextOutput.logits[0]
                }
                currentCache = currentCache
            }

            // Decode generated text
            let generatedText = tokenizer.decode(tokens: generatedTokens).trimmingCharacters(in: .whitespacesAndNewlines)
            logger.debug("[Model] GenerativeJudge | Generated: \(generatedText.prefix(200))")

            // Parse the response based on format
            let parsedIndex: Int?
            switch responseFormat {
            case .letter:
                let parsed = generatedText.components(separatedBy: .whitespacesAndNewlines)
                    .first?
                    .trimmingCharacters(in: .punctuationCharacters)
                    .uppercased()
                if let p = parsed, validLabels.contains(p) {
                    if p == noMatchLabel {
                        parsedIndex = -1  // Sentinel for no-match
                    } else if let idx = activeLabels.firstIndex(of: p) {
                        parsedIndex = idx
                    } else {
                        parsedIndex = nil
                    }
                } else {
                    parsedIndex = nil
                }

            case .number:
                parsedIndex = Self.parseNumberResponse(generatedText, candidateCount: candidateCount)

            case .text:
                parsedIndex = Self.parseTextResponse(generatedText, candidates: shuffledCandidatesCopy)
            }

            // Compute confidence from first-token logits (letter/number formats only)
            var probMap: [String: Float] = [:]
            if responseFormat != .text {
                let allActive = activeLabels + [noMatchLabel]
                let tokenIdsCaptured: [(String, Int)] = allActive.compactMap { label in
                    guard let tokenId = capturedLabelTokenIds[label] else { return nil }
                    return (label, tokenId)
                }

                let temp: Float = 0.3  // Use fixed temperature for confidence normalization
                var labelLogits: [(label: String, logit: Float)] = []
                for (label, tokenId) in tokenIdsCaptured {
                    let logit = lastLogits[tokenId].item(Float.self)
                    labelLogits.append((label, logit))
                }
                let scaledProbs = labelLogits.map { $0.logit / temp }
                let maxL = scaledProbs.max() ?? 0
                let exps = scaledProbs.map { exp($0 - maxL) }
                let sumExp = exps.reduce(0, +)
                let probs = exps.map { $0 / sumExp }

                for (i, item) in labelLogits.enumerated() {
                    probMap[item.label] = probs[i]
                }
            }

            // Determine selected index in original order
            let selectedIndex: Int?
            let confidence: Float
            if let pi = parsedIndex {
                if pi == -1 {
                    // No-match sentinel
                    selectedIndex = nil
                    confidence = probMap[noMatchLabel] ?? 0.5
                } else {
                    selectedIndex = shuffledMapping[pi]
                    let label = activeLabels[pi]
                    confidence = probMap[label] ?? 0.5
                }
            } else {
                // Fallback to logit argmax (letter/number only)
                if responseFormat != .text, let bestIdx = probMap.max(by: { $0.value < $1.value }) {
                    let bestLabel = bestIdx.key
                    confidence = bestIdx.value
                    if bestLabel == noMatchLabel {
                        selectedIndex = nil
                    } else if let labelIdx = activeLabels.firstIndex(of: bestLabel) {
                        selectedIndex = shuffledMapping[labelIdx]
                    } else {
                        selectedIndex = nil
                    }
                } else {
                    selectedIndex = nil
                    confidence = 0
                }
            }

            // Unshuffle probability map
            var unshuffledProbMap: [String: Float] = [:]
            for (shuffledPos, originalIdx) in shuffledMapping.enumerated() {
                if shuffledPos < activeLabels.count && originalIdx < activeLabels.count {
                    let shuffledLabel = activeLabels[shuffledPos]
                    let originalLabel = activeLabels[originalIdx]
                    if let prob = probMap[shuffledLabel] {
                        unshuffledProbMap[originalLabel] = prob
                    }
                }
            }
            unshuffledProbMap[noMatchLabel] = probMap[noMatchLabel]

            return JudgeResult(
                selectedIndex: selectedIndex,
                confidence: confidence,
                labelProbabilities: unshuffledProbMap,
                generatedText: generatedText
            )
        }

        return result
    }

    // MARK: - Label Helpers

    /// Generate labels for the given response format and candidate count
    private nonisolated func labelsForFormat(_ format: JudgeResponseFormat, count: Int) -> [String] {
        switch format {
        case .letter:
            return Array(Self.allLetterLabels.prefix(count))
        case .number:
            return (1...count).map { String($0) }
        case .text:
            // Text format doesn't use separate labels
            return (0..<count).map { String($0) }
        }
    }

    /// The no-match label for the given format
    private nonisolated func noMatchLabelForFormat(_ format: JudgeResponseFormat) -> String {
        switch format {
        case .letter: return "X"
        case .number: return "0"
        case .text: return "NONE"
        }
    }

    // MARK: - Response Parsing

    /// Parse a number-format response. Returns index into shuffled candidates, or -1 for no-match.
    private nonisolated static func parseNumberResponse(_ text: String, candidateCount: Int) -> Int? {
        // Strip thinking tags if present
        let cleaned = stripThinkingTags(text)
        // Extract first integer
        let digits = cleaned.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .first(where: { !$0.isEmpty })
        guard let numberStr = digits, let number = Int(numberStr) else { return nil }
        if number == 0 { return -1 }  // No-match sentinel
        let index = number - 1
        guard index >= 0 && index < candidateCount else { return nil }
        return index
    }

    /// Parse a text-format response. Fuzzy matches against candidate names.
    /// Returns index into shuffled candidates, or -1 for no-match, nil if unparseable.
    private nonisolated static func parseTextResponse(_ text: String, candidates: [String]) -> Int? {
        let cleaned = stripThinkingTags(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        let lower = cleaned.lowercased()
        if lower == "none" || lower == "none of the above" || lower == "x" || lower == "0" {
            return -1
        }

        // Exact match (case-insensitive)
        for (i, candidate) in candidates.enumerated() {
            if candidate.lowercased() == lower {
                return i
            }
        }

        // Substring containment (either direction)
        for (i, candidate) in candidates.enumerated() {
            let candidateLower = candidate.lowercased()
            if lower.contains(candidateLower) || candidateLower.contains(lower) {
                return i
            }
        }

        // Levenshtein distance: accept if edit distance is <30% of candidate length
        var bestIdx: Int?
        var bestDistance = Int.max
        for (i, candidate) in candidates.enumerated() {
            let dist = levenshteinDistance(lower, candidate.lowercased())
            let threshold = max(candidate.count / 3, 3)
            if dist < threshold && dist < bestDistance {
                bestDistance = dist
                bestIdx = i
            }
        }

        return bestIdx
    }

    /// Strip <think>...</think> tags from model output
    private nonisolated static func stripThinkingTags(_ text: String) -> String {
        // Find </think> and return everything after it
        if let range = text.range(of: "</think>") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Compute Levenshtein edit distance between two strings
    private nonisolated static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,      // deletion
                    curr[j - 1] + 1,   // insertion
                    prev[j - 1] + cost // substitution
                )
            }
            prev = curr
        }
        return prev[n]
    }

    // MARK: - Prompt Formatting

    /// Strip trailing "Respond with ONLY..." instruction from preset judge instructions.
    /// These conflict with the format-aware response instruction in the user message.
    private nonisolated static func stripResponseDirective(_ text: String) -> String {
        // Remove trailing sentences starting with "Respond with ONLY"
        if let range = text.range(of: "Respond with ONLY", options: .backwards) {
            return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Format the generative judge prompt with labeled candidates.
    ///
    /// Uses Qwen3 chat template with system + user + assistant prefix.
    /// The defaultSystemPrompt is ALWAYS used as the base (matching criteria, priority ordering).
    /// When an instruction is provided (from presets or custom), it's appended as additional context.
    /// When allowThinking is false, includes an empty think block (no-think mode).
    /// When allowThinking is true, omits the think block so the model can reason.
    private nonisolated func formatPrompt(
        query: String,
        candidates: [String],
        labels: [String],
        instruction: String?,
        responseFormat: JudgeResponseFormat = .letter,
        allowThinking: Bool = false
    ) -> String {
        // Always start with the full default system prompt (matching criteria, priorities, X-selection guidance)
        var systemPrompt = Self.defaultSystemPrompt
        // Append preset/custom instruction as additional matching context if provided
        if let instruction = instruction, !instruction.isEmpty {
            let cleaned = Self.stripResponseDirective(instruction)
            if !cleaned.isEmpty {
                systemPrompt += "\n\nAdditional matching context: " + cleaned
            }
        }

        var candidateLines = ""
        switch responseFormat {
        case .letter:
            for (i, candidate) in candidates.enumerated() {
                candidateLines += "\(labels[i]). \(candidate)\n"
            }
            candidateLines += "X. None of the above"

        case .number:
            for (i, candidate) in candidates.enumerated() {
                candidateLines += "\(i + 1). \(candidate)\n"
            }
            candidateLines += "0. None of the above"

        case .text:
            for candidate in candidates {
                candidateLines += "- \(candidate)\n"
            }
        }

        let responseInstruction: String
        switch responseFormat {
        case .letter:
            let lastLabel = labels.last ?? "E"
            responseInstruction = "Select the best match (respond with a single letter A-\(lastLabel), or X for no match):"
        case .number:
            responseInstruction = "Select the best match (respond with the number of the best candidate, or 0 for no match):"
        case .text:
            responseInstruction = "Select the best match (respond with the exact name of the best candidate, or \"none\" for no match):"
        }

        let userMessage = """
            Food description: \(query)

            Candidates:
            \(candidateLines)

            \(responseInstruction)
            """

        // Build the assistant prefix based on thinking mode
        let assistantPrefix: String
        if allowThinking {
            // Let model think freely before answering
            assistantPrefix = "<|im_start|>assistant\n"
        } else {
            // Force no-think mode with empty think block
            assistantPrefix = "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        }

        return "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(userMessage)<|im_end|>\n\(assistantPrefix)"
    }
}

// MARK: - Errors

enum GenerativeJudgeError: LocalizedError {
    case modelNotLoaded
    case tokenResolutionFailed
    case noCandidates
    case inputMismatch

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Generative judge model not loaded"
        case .tokenResolutionFailed:
            return "Could not resolve label token IDs from tokenizer"
        case .noCandidates:
            return "No candidates provided for judging"
        case .inputMismatch:
            return "Number of queries does not match number of candidate sets"
        }
    }
}
