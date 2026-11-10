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
            .appendingPathComponent("models/example-org", isDirectory: true)
        let directoryForm = modelRoot.appendingPathComponent("model", isDirectory: true)
        let fileForm = modelRoot.appendingPathComponent("model", isDirectory: false)
        let sibling = modelRoot.appendingPathComponent("other", isDirectory: true)

        XCTAssertTrue(ModelDownloader.sameSnapshotPath(directoryForm, fileForm))
        XCTAssertFalse(ModelDownloader.sameSnapshotPath(directoryForm, sibling))
    }

    func testTrustedModelSourceURLUsesThePinnedResolver() throws {
        let revision = String(repeating: "0123456789abcdef", count: 3).prefix(40).description
        let url = try XCTUnwrap(ModelDownloader.sourceURL(
            repository: "example-org/example-model",
            revision: revision,
            artifactPath: "1_Pooling/config.json"
        ))
        XCTAssertEqual(
            url.absoluteString,
            "https://huggingface.co/example-org/example-model/resolve/\(revision)/1_Pooling/config.json"
        )
        XCTAssertNil(ModelDownloader.sourceURL(
            repository: "example-org/example-model",
            revision: "main",
            artifactPath: "config.json"
        ))
        XCTAssertNil(ModelDownloader.sourceURL(
            repository: "example-org/example-model",
            revision: revision,
            artifactPath: "../config.json"
        ))
    }

    func testNoOptionalLocalModelIsTrusted() {
        XCTAssertTrue(ModelDownloader.trustedManifestResources.isEmpty)
        XCTAssertTrue(ModelDownloader.admittedModelTypePrefixes.isEmpty)
        let bundled = ResourceBundle.bundle.urls(forResourcesWithExtension: "json", subdirectory: "Models") ?? []
        XCTAssertFalse(bundled.contains { $0.lastPathComponent.hasSuffix("_snapshot_manifest.json") })
    }
}

/// The model reset removed the Qwen, Nomic, and Gemma experiments. These tests
/// cover what a user of an earlier version still has on disk and in settings.
final class ModelResetTests: XCTestCase {
    func testSelectablePipelinesAreTheReducedSet() {
        XCTAssertEqual(
            Set(PipelineType.allCases),
            [.gteLargeEmbedding, .gteLargeHaiku, .gteLargeHaikuV2, .providerLLM]
        )
        XCTAssertEqual(PipelineMode.standard.availablePipelineTypes, [.gteLargeEmbedding, .providerLLM, .gteLargeHaikuV2])
        XCTAssertEqual(PipelineMode.researchValidation.availablePipelineTypes, [.gteLargeEmbedding])
        XCTAssertTrue(PipelineType.allCases.allSatisfy { $0.requiredModelKeys == ["gte-large"] })
        for rawValue in LegacyPipeline.removedRawValues {
            XCTAssertNil(PipelineType(rawValue: rawValue), rawValue)
        }
    }

    func testPublishedIdentifiersAndDefaultsAreUnchanged() {
        XCTAssertEqual(PipelineType.gteLargeEmbedding.rawValue, "gte-large-embedding")
        XCTAssertEqual(PipelineType.gteLargeHaiku.rawValue, "gte-large-haiku")
        XCTAssertEqual(PipelineType.gteLargeEmbedding.displayName, "GTE-Large Embedding")
        XCTAssertEqual(PipelineType.gteLargeHaiku.displayName, "GTE-Large + Haiku")
        XCTAssertEqual(PipelineType.gteLargeEmbedding.defaultTopK, 20)
        XCTAssertEqual(PipelineType.gteLargeHaiku.defaultTopK, 5)
        XCTAssertEqual(PipelineType.gteLargeEmbedding.admission, .published)
        XCTAssertEqual(PipelineType.gteLargeHaiku.admission, .published)
        XCTAssertFalse(PipelineType.gteLargeEmbedding.isExperimental)
        XCTAssertTrue(PipelineType.providerLLM.isExperimental)
        XCTAssertTrue(PipelineType.gteLargeHaikuV2.isExperimental)
    }

    func testSessionsRecordedByRemovedPipelinesReopenOnGTELarge() {
        XCTAssertEqual(LegacyPipeline.removedDisplayNames.count, 9)
        for name in LegacyPipeline.removedDisplayNames {
            XCTAssertTrue(LegacyPipeline.isRemoved(recordedName: name))
            XCTAssertEqual(LegacyPipeline.pipelineType(forRecordedName: name), .gteLargeEmbedding, name)
        }
        for pipeline in PipelineType.allCases {
            XCTAssertFalse(LegacyPipeline.isRemoved(recordedName: pipeline.displayName))
            XCTAssertEqual(LegacyPipeline.pipelineType(forRecordedName: pipeline.displayName), pipeline)
        }
        XCTAssertEqual(LegacyPipeline.pipelineType(forRecordedName: "GTE-Large + Haiku v2"), .gteLargeHaikuV2)
        XCTAssertEqual(LegacyPipeline.pipelineType(forRecordedName: "A method from a future version"), .gteLargeEmbedding)
        XCTAssertEqual(LegacyPipeline.pipelineType(forRecordedName: ""), .gteLargeEmbedding)
    }

    func testDefaultsMigrationDropsRemovedModelSettingsOnly() throws {
        let defaults = FoodMapperStorage.defaults
        let touched = LegacyPipeline.removedDefaultsKeys + ["pipelinePerformanceOverrides", "modelResetTestMarker"]
        let saved = touched.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        for key in LegacyPipeline.removedDefaultsKeys { defaults.set("4B", forKey: key) }
        defaults.set("kept", forKey: "modelResetTestMarker")
        let overrides: [String: PipelinePerformanceConfig] = [
            "qwen3-two-stage": PipelinePerformanceConfig(embeddingBatchSize: 8, matchingBatchSize: nil, chunkSize: nil, topK: 30),
            "gemma4-llm-only": PipelinePerformanceConfig(embeddingBatchSize: nil, matchingBatchSize: nil, chunkSize: nil, topK: 3),
            "gte-large-embedding": PipelinePerformanceConfig(embeddingBatchSize: 48, matchingBatchSize: 256, chunkSize: nil, topK: nil),
            "provider-llm": PipelinePerformanceConfig(embeddingBatchSize: nil, matchingBatchSize: nil, chunkSize: nil, topK: 5),
        ]
        defaults.set(try JSONEncoder().encode(overrides), forKey: "pipelinePerformanceOverrides")

        LegacyPipeline.migrateDefaults(defaults)

        for key in LegacyPipeline.removedDefaultsKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(defaults.string(forKey: "modelResetTestMarker"), "kept")
        let data = try XCTUnwrap(defaults.data(forKey: "pipelinePerformanceOverrides"))
        let migrated = try JSONDecoder().decode([String: PipelinePerformanceConfig].self, from: data)
        XCTAssertEqual(Set(migrated.keys), ["gte-large-embedding", "provider-llm"])
        XCTAssertEqual(migrated["gte-large-embedding"], overrides["gte-large-embedding"])

        // A second run changes nothing.
        LegacyPipeline.migrateDefaults(defaults)
        XCTAssertEqual(defaults.data(forKey: "pipelinePerformanceOverrides"), data)
    }

    func testLegacyDownloadCleanupRemovesOnlyListedRepositories() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("foodmapper-reset-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let snapshots = root.appendingPathComponent("models", isDirectory: true)

        func write(_ relativePath: String, under base: URL) throws -> URL {
            let url = base.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
            return url
        }

        let qwenJudge = try write("mlx-community/Qwen3-4B-4bit/model.safetensors", under: snapshots)
        let gemma = try write("mlx-community/gemma-4-e2b-it-4bit/config.json", under: snapshots)
        let unlisted = try write("mlx-community/some-other-model/config.json", under: snapshots)
        let reranker = try write("richtext/Qwen3-Reranker-0.6B-mlx-fp16/model.safetensors", under: snapshots)
        let gteWeights = try write("gte-large-0b7a78872ae6fd502fe2db3273b1b3e065a3d9db/model.safetensors", under: snapshots)
        let pointer = try write("current.json", under: snapshots)
        let session = try write("Sessions/session.json", under: root)

        // A symbolic link in place of an organization folder must not lead the cleanup elsewhere.
        let outside = try write("elsewhere/nomic-embed-text-v1.5/model.safetensors", under: root)
        try fileManager.createSymbolicLink(
            at: snapshots.appendingPathComponent("nomic-ai", isDirectory: true),
            withDestinationURL: root.appendingPathComponent("elsewhere", isDirectory: true)
        )

        let removed = LegacyModelDownloads.removeDownloads(in: snapshots)

        XCTAssertEqual(Set(removed), [
            "mlx-community/Qwen3-4B-4bit", "mlx-community/gemma-4-e2b-it-4bit", "richtext/Qwen3-Reranker-0.6B-mlx-fp16",
        ])
        XCTAssertFalse(fileManager.fileExists(atPath: qwenJudge.path))
        XCTAssertFalse(fileManager.fileExists(atPath: gemma.path))
        XCTAssertFalse(fileManager.fileExists(atPath: reranker.path))
        XCTAssertFalse(fileManager.fileExists(atPath: snapshots.appendingPathComponent("richtext").path))
        XCTAssertTrue(fileManager.fileExists(atPath: unlisted.path))
        XCTAssertTrue(fileManager.fileExists(atPath: gteWeights.path))
        XCTAssertTrue(fileManager.fileExists(atPath: pointer.path))
        XCTAssertTrue(fileManager.fileExists(atPath: session.path))
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))

        XCTAssertEqual(LegacyModelDownloads.removeDownloads(in: snapshots), [])
        XCTAssertEqual(LegacyModelDownloads.removeDownloads(in: root.appendingPathComponent("missing")), [])
    }

    func testLegacyRepositoryListNeverNamesGTELarge() {
        XCTAssertEqual(LegacyModelDownloads.repositories.count, 12)
        XCTAssertEqual(Set(LegacyModelDownloads.repositories).count, 12)
        for repository in LegacyModelDownloads.repositories {
            XCTAssertEqual(repository.split(separator: "/").count, 2, repository)
            XCTAssertFalse(repository.lowercased().contains("gte"), repository)
        }
        XCTAssertFalse(LegacyModelDownloads.removedEmbeddingModelKeys.contains("gte-large"))
    }

    func testEmbeddingCacheCleanupRemovesOnlyRemovedModelCaches() throws {
        let fileManager = FileManager.default
        let databases = fileManager.temporaryDirectory.appendingPathComponent("foodmapper-reset-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: databases) }
        try fileManager.createDirectory(at: databases, withIntermediateDirectories: true)

        let removedNames = [
            "abc_embeddings_qwen3-emb-4b-4bit.bin", "abc_embeddings_qwen3-emb-4b-4bit.json",
            "foodb_embeddings_qwen3-emb-0.6b-4bit.bin", "xyz_embeddings_qwen3-emb-8b-4bit.json",
        ]
        let keptNames = [
            "abc_embeddings_gte-large.bin", "abc_embeddings_gte-large.json", "abc_data.csv",
            "abc_embeddings.bin", "_embeddings_qwen3-emb-4b-4bit.bin", "abc_embeddings_qwen3-emb-4b-4bit.bin.note",
        ]
        for name in removedNames + keptNames {
            try Data("x".utf8).write(to: databases.appendingPathComponent(name))
        }
        let directoryNamedLikeCache = databases.appendingPathComponent("dir_embeddings_qwen3-emb-8b-4bit.bin", isDirectory: true)
        try fileManager.createDirectory(at: directoryNamedLikeCache, withIntermediateDirectories: true)

        XCTAssertEqual(LegacyModelDownloads.removeEmbeddingCaches(in: databases), removedNames.sorted())
        for name in removedNames {
            XCTAssertFalse(fileManager.fileExists(atPath: databases.appendingPathComponent(name).path), name)
        }
        for name in keptNames {
            XCTAssertTrue(fileManager.fileExists(atPath: databases.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: directoryNamedLikeCache.path))
        XCTAssertEqual(LegacyModelDownloads.removeEmbeddingCaches(in: databases), [])
    }
}
