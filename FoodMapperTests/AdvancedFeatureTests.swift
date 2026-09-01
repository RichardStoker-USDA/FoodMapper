import XCTest
@testable import FoodMapper

final class AdvancedFeatureGateTests: XCTestCase {
    func testDisabledGateDoesNotIssueLease() {
        let gate = AdvancedFeatureGate()
        XCTAssertThrowsError(try gate.issueLease()) { error in
            XCTAssertEqual(error as? AdvancedFeatureError, .disabled)
        }
    }

    func testTurningAdvancedModeOffRevokesExistingLease() throws {
        let gate = AdvancedFeatureGate()
        gate.setEnabled(true)
        let lease = try gate.issueLease()
        try gate.validate(lease)

        gate.setEnabled(false)
        XCTAssertThrowsError(try gate.validate(lease)) { error in
            XCTAssertEqual(error as? AdvancedFeatureError, .disabled)
        }

        gate.setEnabled(true)
        XCTAssertThrowsError(try gate.validate(lease)) { error in
            XCTAssertEqual(error as? AdvancedFeatureError, .expiredLease)
        }
    }

    func testAdvancedLimitsRejectOversizedCandidateSet() {
        let limits = AdvancedRunLimits(
            inputRows: 1,
            inputBytes: 1,
            candidateCount: AdvancedRunLimits.maximum.candidateCount + 1,
            resultRecords: 1,
            fieldBytes: 1
        )
        XCTAssertThrowsError(try limits.validated())
    }
}

final class BenchmarkCoreTests: XCTestCase {
    func testBuiltInFixtureIsValidAndVersioned() throws {
        let fixture = FoodMatchingBenchmark.regression
        try fixture.validate()
        XCTAssertEqual(fixture.revision, 1)
        XCTAssertEqual(fixture.cases.count, 20)
        XCTAssertEqual(fixture.targets.count, 30)
        XCTAssertTrue(fixture.cases.contains { $0.input == "broccoli cheddar soup" })
    }

    func testMetricsUseExpectedRankAndMedianCaseLatency() throws {
        let fixture = BenchmarkFixture(
            id: "fixture",
            name: "Fixture",
            revision: 1,
            targets: [
                BenchmarkTarget(id: "a", description: "A"),
                BenchmarkTarget(id: "b", description: "B")
            ],
            cases: [
                BenchmarkCase(id: "one", input: "A", expectedTargetID: "a", context: nil),
                BenchmarkCase(id: "two", input: "B", expectedTargetID: "b", context: nil)
            ]
        )
        let rankings = [
            BenchmarkRanking(caseID: "one", rankedTargetIDs: ["a", "b"], latencyMilliseconds: 10),
            BenchmarkRanking(caseID: "two", rankedTargetIDs: ["a", "b"], latencyMilliseconds: 30)
        ]

        let metrics = try BenchmarkMetrics.calculate(fixture: fixture, rankings: rankings)
        XCTAssertEqual(metrics.top1Accuracy, 0.5, accuracy: 0.0001)
        XCTAssertEqual(metrics.top5Accuracy, 1, accuracy: 0.0001)
        XCTAssertEqual(metrics.top10Accuracy, 1, accuracy: 0.0001)
        XCTAssertEqual(metrics.meanReciprocalRank, 0.75, accuracy: 0.0001)
        XCTAssertEqual(metrics.medianLatencyMilliseconds, 20, accuracy: 0.0001)
    }

    func testMetricsRejectDuplicateCaseResults() {
        let fixture = FoodMatchingBenchmark.regression
        let duplicate = BenchmarkRanking(
            caseID: fixture.cases[0].id,
            rankedTargetIDs: [fixture.cases[0].expectedTargetID],
            latencyMilliseconds: 1
        )
        XCTAssertThrowsError(try BenchmarkMetrics.calculate(
            fixture: fixture,
            rankings: Array(repeating: duplicate, count: fixture.cases.count)
        ))
    }
}

final class ProviderProfileTests: XCTestCase {
    func testExactLoopbackIPv4EndpointIsAccepted() throws {
        let url = try ProviderEndpointPolicy.canonicalURL(
            kind: .localOpenAICompatible,
            value: "http://127.0.0.1:8080/v1"
        )
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8080/v1")
    }

    func testLoopbackIPv6EndpointIsAccepted() throws {
        let url = try ProviderEndpointPolicy.canonicalURL(
            kind: .localOpenAICompatible,
            value: "http://[::1]:8080/v1"
        )
        XCTAssertEqual(url.host, "::1")
        XCTAssertEqual(url.path, "/v1")
    }

    func testNonLoopbackAndEmbeddedCredentialsAreRejected() {
        for value in [
            "https://example.com/v1",
            "http://192.168.1.50:8000/v1",
            "http://user:password@127.0.0.1:8000/v1",
            "http://127.0.0.1:8000/custom/path",
            "http://127.0.0.1:8000/v1/",
            "http://127.0.0.1:8000/v1?model=other",
            "http://localhost:8000/v1",
            "HTTP://127.0.0.1:8000/v1",
            " http://127.0.0.1:8000/v1"
        ] {
            XCTAssertThrowsError(try ProviderEndpointPolicy.canonicalURL(
                kind: .localOpenAICompatible,
                value: value
            ), value)
        }
    }

    func testOpenAIEndpointCannotBeOverridden() throws {
        let url = try ProviderEndpointPolicy.canonicalURL(
            kind: .openAI,
            value: "http://127.0.0.1:8000/v1"
        )
        XCTAssertEqual(url.absoluteString, "https://api.openai.com/v1")
    }

    func testProviderRequestUsesFixedDecisionFields() throws {
        let profile = try ProviderProfile(
            name: "Local",
            kind: .localOpenAICompatible,
            baseURL: "http://127.0.0.1:8000/v1",
            model: "food-model"
        ).validated()
        XCTAssertEqual(profile.requestOptionsJSON, "{}")

        let data = try ProviderChatRequest.data(
            profile: profile,
            messages: [["role": "user", "content": "broccoli"]],
            maxTokens: 64,
            candidateIDs: ["c1", "c2"]
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "food-model")
        XCTAssertNil(body["authorization"])
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["max_tokens"] as? Int, 64)
        XCTAssertNotNil(body["response_format"] as? [String: Any])
    }

    func testRequestOptionsRejectEveryCustomField() {
        XCTAssertEqual(try ProviderRequestOptions.normalizedJSON("{}"), "{}")
        XCTAssertThrowsError(try ProviderRequestOptions.normalizedJSON("{\"model\":\"other\"}"))
        XCTAssertThrowsError(try ProviderRequestOptions.normalizedJSON("{\"response_format\":\"text\"}"))
        XCTAssertThrowsError(try ProviderRequestOptions.normalizedJSON("{\"api_key\":\"secret\"}"))
        XCTAssertThrowsError(try ProviderRequestOptions.normalizedJSON("{\"headers\":{\"Authorization\":\"secret\"}}"))
        XCTAssertThrowsError(try ProviderRequestOptions.normalizedJSON("{\"reasoning_effort\":\"none\"}"))
        XCTAssertThrowsError(try ProviderRequestOptions.normalizedJSON("[]"))
    }

    func testLegacyProviderProfileDecodesWithDefaultRequestOptions() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "name": "Legacy",
            "kind": "localOpenAICompatible",
            "baseURL": "http://127.0.0.1:8000/v1",
            "model": "legacy-model",
            "allowsReasoning": false,
            "maximumOutputTokens": 256
        ])
        let profile = try JSONDecoder().decode(ProviderProfile.self, from: data)
        XCTAssertEqual(profile.requestOptionsJSON, "{}")
        XCTAssertEqual(profile.maximumOutputTokens, 128)
        XCTAssertNoThrow(try profile.validated())
    }

    func testProbeFingerprintsBindTheModelAndSchema() throws {
        let first = try ProviderProfile(
            name: "Local",
            kind: .localOpenAICompatible,
            baseURL: "http://127.0.0.1:8000/v1",
            model: "model-a"
        ).validated()
        var second = first
        second.model = "model-b"

        XCTAssertNotEqual(try first.nonsecretFingerprint(), try second.nonsecretFingerprint())
        XCTAssertEqual(
            try ProviderChatRequest.schemaHash(candidateIDs: ["c1", "c2"]),
            try ProviderChatRequest.schemaHash(candidateIDs: ["c1", "c2"])
        )
        XCTAssertNotEqual(
            try ProviderChatRequest.schemaHash(candidateIDs: ["c1", "c2"]),
            try ProviderChatRequest.schemaHash(candidateIDs: ["c1", "c2", "c3"])
        )
    }

    func testStrictProviderDecisionAcceptsOneKnownCandidate() throws {
        XCTAssertEqual(
            try ProviderResponseParser.selection(
                content: "{\"candidate_id\":\"c2\",\"decision\":\"select\"}",
                candidateIDs: ["c1", "c2"]
            ),
            1
        )
        XCTAssertNil(try ProviderResponseParser.selection(
            content: "{\"candidate_id\":null,\"decision\":\"abstain\"}",
            candidateIDs: ["c1", "c2"]
        ))
    }

    func testStrictProviderDecisionRejectsAmbiguousOrUnknownOutput() {
        let invalid = [
            "{\"candidate_id\":\"c9\",\"decision\":\"select\"}",
            "{\"candidate_id\":null,\"decision\":\"select\"}",
            "{\"candidate_id\":\"c1\",\"decision\":\"abstain\"}",
            "{\"candidate_id\":\"c1\",\"decision\":\"select\",\"reason\":\"x\"}",
            "{\"decision\":\"select\",\"candidate_id\":\"c1\",\"decision\":\"abstain\"}"
        ]
        for content in invalid {
            XCTAssertThrowsError(try ProviderResponseParser.selection(
                content: content,
                candidateIDs: ["c1", "c2"]
            ), content)
        }
    }

    func testProviderEnvelopeRejectsToolsAndMultipleChoices() throws {
        let valid = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "{\"candidate_id\":null,\"decision\":\"abstain\"}"]]]
        ])
        XCTAssertNoThrow(try ProviderResponseParser.messageContent(from: valid))

        let toolCall = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "{}", "tool_calls": []]]]
        ])
        XCTAssertThrowsError(try ProviderResponseParser.messageContent(from: toolCall))

        let multiple = try JSONSerialization.data(withJSONObject: [
            "choices": [
                ["message": ["content": "{}"]],
                ["message": ["content": "{}"]]
            ]
        ])
        XCTAssertThrowsError(try ProviderResponseParser.messageContent(from: multiple))
    }
}

final class AdvancedCatalogTests: XCTestCase {
    func testSnapshotArtifactPathsStayRelative() {
        XCTAssertTrue(ModelDownloader.isSafeRelativePath("config.json"))
        XCTAssertTrue(ModelDownloader.isSafeRelativePath("1_Pooling/config.json"))
        for invalid in ["", "/config.json", "../config.json", "a/../config.json", "a//config.json", "./config.json"] {
            XCTAssertFalse(ModelDownloader.isSafeRelativePath(invalid), invalid)
        }
    }

    func testSnapshotLocationIgnoresDirectoryURLMarker() {
        let modelRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("models/nomic-ai", isDirectory: true)
        let directoryForm = modelRoot.appendingPathComponent("model", isDirectory: true)
        let fileForm = modelRoot.appendingPathComponent("model", isDirectory: false)
        let sibling = modelRoot.appendingPathComponent("other", isDirectory: true)

        XCTAssertTrue(ModelDownloader.sameSnapshotPath(directoryForm, fileForm))
        XCTAssertFalse(ModelDownloader.sameSnapshotPath(directoryForm, sibling))
    }

    func testTrustedModelSourceURLUsesThePinnedResolver() throws {
        let url = try XCTUnwrap(ModelDownloader.sourceURL(
            repository: "nomic-ai/nomic-embed-text-v1.5",
            revision: NomicEmbeddingModel.revision,
            artifactPath: "1_Pooling/config.json"
        ))
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5/resolve/\(NomicEmbeddingModel.revision)/1_Pooling/config.json"
        )
        XCTAssertNil(ModelDownloader.sourceURL(
            repository: "nomic-ai/nomic-embed-text-v1.5",
            revision: "main",
            artifactPath: "config.json"
        ))
        XCTAssertNil(ModelDownloader.sourceURL(
            repository: "nomic-ai/nomic-embed-text-v1.5",
            revision: NomicEmbeddingModel.revision,
            artifactPath: "../config.json"
        ))
    }

    func testSelectablePipelinesDoNotContainUnavailableGemmaEntries() {
        let pipelines = PipelineMode.standard.availablePipelineTypes
        XCTAssertTrue(pipelines.contains(.nomicEmbedding))
        XCTAssertTrue(pipelines.contains(.providerLLM))
        XCTAssertFalse(pipelines.contains(.gemma4LLMOnly))
        XCTAssertFalse(pipelines.contains(.gemma4TwoStage))
        XCTAssertTrue(pipelines.allSatisfy(\.isImplemented))
    }

    func testNomicManifestPinsExpectedSnapshotAndFileTotal() throws {
        let url = try XCTUnwrap(ResourceBundle.bundle.url(
            forResource: "nomic_snapshot_manifest",
            withExtension: "json",
            subdirectory: "Models"
        ))
        let manifest = try JSONDecoder().decode(
            TrustedModelSnapshotManifest.self,
            from: Data(contentsOf: url)
        )
        let model = try XCTUnwrap(manifest.models.first)
        XCTAssertEqual(model.repo, NomicEmbeddingModel.repository)
        XCTAssertEqual(model.revision, NomicEmbeddingModel.revision)
        XCTAssertEqual(model.artifacts.count, 10)
        XCTAssertEqual(model.artifacts.reduce(Int64.zero) { $0 + $1.byteSize }, 547_886_235)
        XCTAssertTrue(model.artifacts.allSatisfy { $0.sha256.count == 64 })
    }
}
