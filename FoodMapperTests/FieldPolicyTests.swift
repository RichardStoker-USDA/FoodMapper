import XCTest
@testable import FoodMapper

/// Canned provider responses. No test in this file reaches a remote host.
private final class RecordingTransport: ProviderTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: Data
    private var recorded: [URLRequest] = []

    init(status: Int = 200, body: Data) {
        self.status = status
        self.body = body
    }

    /// A Responses event stream that ends with one completed decision.
    static func responses(_ json: String) -> RecordingTransport {
        let events: [[String: Any]] = [
            ["type": "response.output_text.delta", "delta": json],
            ["type": "response.completed", "response": [
                "status": "completed",
                "output": [["type": "message", "content": [["type": "output_text", "text": json]]]],
            ]],
        ]
        let text = events.map { "data: " + String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\n\n" }.joined()
        return RecordingTransport(body: Data(text.utf8))
    }

    static func chat(_ json: String) -> RecordingTransport {
        RecordingTransport(body: try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": json]]]]))
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    var lastBody: [String: Any] {
        guard let data = requests.last?.httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        lock.withLock { recorded.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        let body = self.body
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(body)
            continuation.finish()
        })
    }
}

final class FieldPolicyTests: XCTestCase {
    private let columns = ["category", "energy_kcal", "sodium_mg", "notes"]

    func testValidationChecksLimitsAndColumns() throws {
        XCTAssertFalse(TargetFieldPolicy().isActive)
        XCTAssertFalse(TargetFieldPolicy(retrievalContext: "  \n ").isActive)

        var policy = TargetFieldPolicy(
            retrievalContext: "  low sodium \n", judgeFields: ["category", "sodium_mg", "category"],
            numericRule: .init(column: "energy_kcal", goal: .lowest)
        )
        let checked = try policy.validated(availableColumns: columns)
        XCTAssertEqual(checked.retrievalContext, "low sodium")
        XCTAssertEqual(checked.judgeFields, ["category", "sodium_mg"])
        XCTAssertEqual(checked.referencedColumns, ["category", "sodium_mg", "energy_kcal"])
        XCTAssertTrue(checked.isActive)
        XCTAssertEqual(try checked.fingerprint(), try checked.fingerprint())
        var other = checked
        other.numericRule?.goal = .highest
        XCTAssertNotEqual(try checked.fingerprint(), try other.fingerprint())

        policy.judgeFields = ["category", "fiber_g"]
        policy.numericRule = .init(column: "protein_g", goal: .highest)
        XCTAssertThrowsError(try policy.validated(availableColumns: columns)) {
            XCTAssertEqual($0 as? TargetFieldPolicyError, .unknownColumns(["fiber_g", "protein_g"]))
        }
        XCTAssertThrowsError(try TargetFieldPolicy(judgeFields: (1...9).map { "c\($0)" }).validated(availableColumns: (1...9).map { "c\($0)" })) {
            XCTAssertEqual($0 as? TargetFieldPolicyError, .tooManyFields)
        }
        XCTAssertThrowsError(try TargetFieldPolicy(retrievalContext: String(repeating: "a", count: 201)).validated(availableColumns: [])) {
            XCTAssertEqual($0 as? TargetFieldPolicyError, .contextTooLong)
        }

        // A saved policy without a version or rule still decodes.
        let decoded = try JSONDecoder().decode(TargetFieldPolicy.self, from: Data(#"{"version":1,"retrievalContext":"raw","judgeFields":["category"]}"#.utf8))
        XCTAssertEqual(decoded, TargetFieldPolicy(retrievalContext: "raw", judgeFields: ["category"]))
    }

    func testRetrievalQueryAndJudgeValues() {
        XCTAssertEqual(TargetFieldPolicy().retrievalQuery(for: "tomato soup"), "tomato soup")
        XCTAssertEqual(TargetFieldPolicy(retrievalContext: " low sodium ").retrievalQuery(for: "tomato soup"), "tomato soup, low sodium")

        let policy = TargetFieldPolicy(judgeFields: ["category", "sodium_mg", "notes"])
        let long = String(repeating: "é", count: 80)   // 160 bytes
        let values = policy.judgeFieldValues(from: ["category": " Soups ", "sodium_mg": "", "notes": long, "energy_kcal": "30"])
        XCTAssertEqual(values["category"], "Soups")
        XCTAssertNil(values["sodium_mg"], "an empty value is not sent")
        XCTAssertNil(values["energy_kcal"], "an unselected column is not sent")
        XCTAssertEqual(values["notes"], String(repeating: "é", count: 60), "cut on a character boundary at 120 bytes")
    }

    func testNumericRuleChoosesAmongEquivalents() throws {
        let sodium = ["480", "12", "", "140", "n/a", "12"]
        func outcome(_ goal: TargetFieldPolicy.NumericRule.Goal, selection: Int, equivalents: [Int]) -> TargetFieldPolicy.RuleOutcome? {
            TargetFieldPolicy(numericRule: .init(column: "sodium_mg", goal: goal))
                .applyRule(selection: selection, equivalents: equivalents) { sodium[$0] }
        }
        XCTAssertNil(TargetFieldPolicy(judgeFields: ["sodium_mg"]).applyRule(selection: 0, equivalents: [1]) { sodium[$0] })

        let lower = try XCTUnwrap(outcome(.lowest, selection: 0, equivalents: [3, 1]))
        XCTAssertEqual(lower.selection, 1)
        XCTAssertEqual(lower.note, "Rule lowest sodium_mg: chose 12 over the provider's selection (480) among 3 same-food candidates. Check that it is the same food.")
        // A replaced selection is held for review; an unchanged one is accepted.
        XCTAssertEqual(ProviderRerankerPipeline.status(providerSelection: 0, finalSelection: lower.selection), .match)
        XCTAssertEqual(ProviderRerankerPipeline.status(providerSelection: 1, finalSelection: 1), .llmMatch)
        let held = MatchResult(inputText: "x", inputRow: 0, matchText: "y", matchID: "1", score: 0.9, status: .match, scoreType: .llmSelected)
        XCTAssertEqual(MatchCategory.from(result: held, decision: nil, profile: ThresholdProfile(matchThreshold: 0.86)), .needsReview)
        XCTAssertEqual(outcome(.highest, selection: 3, equivalents: [0, 1])?.selection, 0)

        // The provider's selection already satisfies the rule.
        let kept = try XCTUnwrap(outcome(.lowest, selection: 1, equivalents: [0, 3]))
        XCTAssertEqual(kept.selection, 1)
        XCTAssertTrue(kept.note.contains("the provider's selection (12) is the lowest of 3 same-food candidates"))
        // A tie keeps the provider's selection, even when an equal candidate ranks higher.
        XCTAssertEqual(outcome(.lowest, selection: 5, equivalents: [1, 0])?.selection, 5)
        // Without the selection in the tie, the better-ranked candidate wins.
        XCTAssertEqual(outcome(.lowest, selection: 0, equivalents: [5, 1])?.selection, 1)

        // Missing and non-numeric values cannot win and are never treated as zero.
        XCTAssertEqual(outcome(.lowest, selection: 3, equivalents: [2, 4])?.selection, 3)
        let fromMissing = try XCTUnwrap(outcome(.lowest, selection: 2, equivalents: [3]))
        XCTAssertEqual(fromMissing.selection, 3)
        XCTAssertTrue(fromMissing.note.contains("(not reported)"))
        let none = try XCTUnwrap(outcome(.lowest, selection: 2, equivalents: [4]))
        XCTAssertEqual(none.selection, 2)
        XCTAssertTrue(none.note.contains("no value reported"))
        let alone = try XCTUnwrap(outcome(.highest, selection: 0, equivalents: [0]))
        XCTAssertEqual(alone.selection, 0)
        XCTAssertTrue(alone.note.contains("of 1 candidate."))
    }

    func testPayloadCarriesFieldsOnlyWhenSet() throws {
        let plain = try ProviderDecisionPayload(input: "tomato soup", candidates: ["Soup, tomato", "Soup, tomato, low sodium"], instruction: "Match the form.")
        XCTAssertEqual(
            try plain.jsonText(),
            #"{"candidates":[{"candidate_id":"c1","description":"Soup, tomato"},{"candidate_id":"c2","description":"Soup, tomato, low sodium"}],"input":"tomato soup","matching_context":"Match the form."}"#,
            "a run without field settings sends the same text as before"
        )
        XCTAssertFalse(plain.wantsEquivalents)
        XCTAssertTrue(try ProviderDecisionPayload(input: "a", candidates: ["x", "y"], instruction: nil, fields: [[:], [:]]).fields.isEmpty)

        let withFields = try ProviderDecisionPayload(
            input: "tomato soup", candidates: ["Soup, tomato", "Soup, tomato, low sodium"], instruction: nil,
            fields: [["sodium_mg": "480"], [:]], wantsEquivalents: true
        )
        let candidates = try XCTUnwrap(withFields.jsonObject["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates[0]["fields"] as? [String: String], ["sodium_mg": "480"])
        XCTAssertNil(candidates[1]["fields"])
        XCTAssertEqual(withFields.fieldsByCandidateID, ["c1": ["sodium_mg": "480"]])

        XCTAssertThrowsError(try ProviderDecisionPayload(input: "a", candidates: ["x", "y"], instruction: nil, fields: [["k": "v"]]))
        XCTAssertThrowsError(try ProviderDecisionPayload(input: "a", candidates: ["x"], instruction: nil, fields: [["k": String(repeating: "v", count: 121)]]))
        XCTAssertThrowsError(try ProviderDecisionPayload(input: "a", candidates: ["x"], instruction: nil, fields: [["": "v"]]))
        let nine = Dictionary(uniqueKeysWithValues: (1...9).map { ("k\($0)", "v") })
        XCTAssertThrowsError(try ProviderDecisionPayload(input: "a", candidates: ["x"], instruction: nil, fields: [nine]))
    }

    func testSchemasAndRequestsForEquivalents() throws {
        let ids = ["c1", "c2", "c3"]
        XCTAssertEqual(
            try OpenAIResponsesRequest.schemaHash(candidateIDs: ids),
            try OpenAIResponsesRequest.schemaHash(candidateIDs: ids, wantsEquivalents: false)
        )
        XCTAssertNotEqual(
            try OpenAIResponsesRequest.schemaHash(candidateIDs: ids),
            try OpenAIResponsesRequest.schemaHash(candidateIDs: ids, wantsEquivalents: true)
        )
        XCTAssertNotEqual(
            try ProviderChatRequest.schemaHash(candidateIDs: ids),
            try ProviderChatRequest.schemaHash(candidateIDs: ids, wantsEquivalents: true)
        )
        let plain = OpenAIResponsesRequest.textFormat(candidateIDs: ids)
        XCTAssertEqual(plain["name"] as? String, "foodmapper_candidate_decision")
        XCTAssertEqual((plain["schema"] as? [String: Any])?["required"] as? [String], ["decision", "candidate_id"])

        let format = OpenAIResponsesRequest.textFormat(candidateIDs: ids, wantsEquivalents: true)
        XCTAssertEqual(format["name"] as? String, "foodmapper_candidate_set_decision")
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["decision", "candidate_id", "equivalent_ids"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let equivalents = try XCTUnwrap((schema["properties"] as? [String: Any])?["equivalent_ids"] as? [String: Any])
        XCTAssertEqual(equivalents["type"] as? String, "array")
        XCTAssertEqual((equivalents["items"] as? [String: Any])?["enum"] as? [String], ids)

        let payload = try ProviderDecisionPayload(
            input: "soup", candidates: ["a", "b", "c"], instruction: nil, fields: [["sodium_mg": "480"], [:], [:]], wantsEquivalents: true
        )
        let body = try JSONSerialization.jsonObject(with: OpenAIResponsesRequest.data(
            model: "gpt-6-luna", payload: payload, effort: .low, billing: .chatGPTPlan
        )) as! [String: Any]
        XCTAssertEqual(body["instructions"] as? String, OpenAIResponsesRequest.decisionInstructions + OpenAIResponsesRequest.equivalentsInstruction)
        XCTAssertEqual(((body["text"] as? [String: Any])?["format"] as? [String: Any])?["name"] as? String, "foodmapper_candidate_set_decision")

        // The Decisions route lists candidates as choices, so selected columns travel as data keyed by choice.
        let evidence = OpenAIDecisionsRequest.evidence(for: payload)
        XCTAssertEqual(evidence["candidate_fields"] as? [String: [String: String]], ["c1": ["sodium_mg": "480"]])
        XCTAssertNil(OpenAIDecisionsRequest.evidence(for: try ProviderDecisionPayload(input: "soup", candidates: ["a"], instruction: nil))["candidate_fields"])
    }

    func testDecisionParserValidatesEquivalents() throws {
        let ids = ["c1", "c2", "c3"]
        func parse(_ json: String, wants: Bool = true) throws -> (selection: Int?, equivalents: [Int]) {
            try ProviderResponseParser.decision(content: json, candidateIDs: ids, wantsEquivalents: wants)
        }
        let selected = try parse(#"{"decision":"select","candidate_id":"c2","equivalent_ids":["c3","c2","c3","c1"]}"#)
        XCTAssertEqual(selected.selection, 1)
        XCTAssertEqual(selected.equivalents, [2, 0], "the selection and repeats are dropped")
        let abstained = try parse(#"{"decision":"abstain","candidate_id":null,"equivalent_ids":[]}"#)
        XCTAssertNil(abstained.selection)
        XCTAssertEqual(abstained.equivalents, [])

        XCTAssertThrowsError(try parse(#"{"decision":"select","candidate_id":"c2","equivalent_ids":["c9"]}"#))
        XCTAssertThrowsError(try parse(#"{"decision":"abstain","candidate_id":null,"equivalent_ids":["c1"]}"#))
        XCTAssertThrowsError(try parse(#"{"decision":"select","candidate_id":"c2"}"#), "the list is required when asked for")
        XCTAssertThrowsError(try parse(#"{"decision":"select","candidate_id":"c2","equivalent_ids":"c1"}"#))
        XCTAssertThrowsError(try parse(#"{"decision":"select","candidate_id":"c2","equivalent_ids":[1]}"#))
        XCTAssertThrowsError(try parse(#"{"decision":"select","candidate_id":"c2","equivalent_ids":[]}"#, wants: false), "an unrequested key is rejected")
        XCTAssertEqual(try parse(#"{"decision":"select","candidate_id":"c3"}"#, wants: false).selection, 2)
        XCTAssertEqual(try ProviderResponseParser.selection(content: #"{"decision":"select","candidate_id":"c1"}"#, candidateIDs: ids), 0)
    }

    func testRowRequestCarriesFieldsAndReturnsEquivalents() async throws {
        let plan = ProviderProfile(name: "Plan", kind: .chatGPTPlan, model: "gpt-6-luna", interface: .responses, concurrency: 1, accountID: UUID())
        let transport = RecordingTransport.responses(#"{"decision":"select","candidate_id":"c1","equivalent_ids":["c2"]}"#)
        let decision = try await ProviderRerankerPipeline.decideWithRetry(
            input: "tomato soup", candidates: ["Soup, tomato", "Soup, tomato, low sodium", "Tomato juice"], instruction: nil,
            fields: [["sodium_mg": "480"], ["sodium_mg": "12"], [:]], wantsEquivalents: true,
            profile: plan, credentialSource: { "t" }, transport: transport, coordinator: ProviderRunCoordinator()
        )
        XCTAssertEqual(decision.selection, 0)
        XCTAssertEqual(decision.equivalents, [1])
        let sent = try XCTUnwrap((((transport.lastBody["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.first)?["text"] as? String)
        XCTAssertTrue(sent.contains(#""fields":{"sodium_mg":"12"}"#))
        XCTAssertFalse(sent.contains("low sodium,"), "the retrieval context is never part of the request")

        // The rule then picks the lower-sodium equivalent.
        let policy = TargetFieldPolicy(numericRule: .init(column: "sodium_mg", goal: .lowest))
        let sodium = ["480", "12", ""]
        XCTAssertEqual(policy.applyRule(selection: 0, equivalents: decision.equivalents) { sodium[$0] }?.selection, 1)

        let local = ProviderProfile(name: "Local", kind: .localOpenAICompatible, baseURL: "http://127.0.0.1:8000/v1", model: "m")
        let chat = RecordingTransport.chat(#"{"decision":"select","candidate_id":"c2","equivalent_ids":[]}"#)
        let chatPayload = try ProviderDecisionPayload(input: "soup", candidates: ["a", "b"], instruction: nil, wantsEquivalents: true)
        let chatDecision = try await ProviderDecisionClient.decide(payload: chatPayload, profile: local, credential: nil, transport: chat)
        XCTAssertEqual(chatDecision.selection, 1)
        XCTAssertEqual(chatDecision.equivalents, [])
        let format = try XCTUnwrap((chat.lastBody["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        XCTAssertEqual(format["name"] as? String, "foodmapper_candidate_set_decision")
        XCTAssertEqual((chat.lastBody["messages"] as? [[String: String]])?.first?["content"], OpenAIResponsesRequest.decisionInstructions + OpenAIResponsesRequest.equivalentsInstruction)

        // The Decisions route cannot list equivalents, so nothing is sent.
        let key = ProviderProfile(name: "Key", kind: .openAI, model: "gpt-6-luna", interface: .decisions, concurrency: 1)
        let unused = RecordingTransport(body: Data())
        do {
            _ = try await ProviderDecisionClient.decide(payload: chatPayload, profile: key, credential: "k", transport: unused)
            XCTFail("expected the route to be rejected")
        } catch {
            XCTAssertEqual(error as? TargetFieldPolicyError, .ruleNeedsDecisionJSON)
        }
        XCTAssertTrue(unused.requests.isEmpty)
    }

    func testSessionRecordsThePolicyAndOlderSessionsDecode() throws {
        let policy = TargetFieldPolicy(
            retrievalContext: "low sodium", judgeFields: ["sodium_mg"], numericRule: .init(column: "sodium_mg", goal: .lowest)
        )
        let session = MatchingSession(
            inputFileName: "in.csv", databaseName: "FDC SR Legacy 2018-04", threshold: 0.8, totalCount: 2, matchedCount: 1,
            resultsFilename: "results.json", pipelineName: "GTE-Large + Provider", fieldPolicy: policy
        )
        let encoded = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(MatchingSession.self, from: encoded).fieldPolicy, policy)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["fieldPolicy"] = nil
        let older = try JSONDecoder().decode(MatchingSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.fieldPolicy)
        XCTAssertEqual(older.pipelineName, "GTE-Large + Provider")
    }

    func testPolicyColumnsExcludeDescriptionAndID() {
        XCTAssertEqual(AppState.fieldPolicyColumns(for: .builtIn(.dfg2)), [])
        XCTAssertEqual(
            AppState.fieldPolicyColumns(for: .builtIn(.fooDB)),
            ["food_name", "orig_food_id", "orig_food_common_name_uncleaned", "citation", "food_V2_ID"]
        )
        var custom = CustomDatabase(
            displayName: "FDC SR Legacy 2018-04", csvPath: "/x/fdc.csv", textColumn: "description", idColumn: "fdc_id",
            itemCount: 1, fileFormat: .csv
        )
        custom.columnNames = FDCBundleImporter.outputColumns
        XCTAssertEqual(
            AppState.fieldPolicyColumns(for: .custom(custom)),
            ["data_type", "category", "energy_kcal", "protein_g", "fat_g", "carbohydrate_g", "fiber_g", "sugars_g", "sodium_mg"]
        )
    }
}
