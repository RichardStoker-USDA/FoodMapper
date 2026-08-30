import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import FoodMapper

final class GTELargeModelInstallTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-gte-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testProductionManifestPinsRevisionSizesAndHashes() {
        let manifest = GTELargeModelManifest.current
        XCTAssertEqual(manifest.revision, "0b7a78872ae6fd502fe2db3273b1b3e065a3d9db")
        XCTAssertEqual(manifest.downloadSize, 671_270_295)
        XCTAssertEqual(manifest.files.count, 6)
        XCTAssertTrue(manifest.files.allSatisfy { manifest.sourceURL(for: $0).path.contains(manifest.revision) })
        XCTAssertFalse(manifest.files.contains { manifest.sourceURL(for: $0).absoluteString.contains("/main/") })
    }

    func testInstallVerifiesAllFilesWritesRecordAndReportsExactProgress() async throws {
        let transport = FixtureTransport(files: fixtureFiles)
        let installer = makeInstaller(transport: transport)
        let updates = ProgressRecorder()

        let directory = try await installer.install { written, total in
            updates.append((written, total))
        }

        XCTAssertEqual(directory, installer.installedDirectory)
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("install.json").path))
        XCTAssertEqual(updates.last?.0, fixtureManifest.downloadSize)
        XCTAssertEqual(updates.last?.1, fixtureManifest.downloadSize)
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, fixtureManifest.files.count)
    }

    func testCorruptResponseIsNeverPublished() async {
        var corrupt = fixtureFiles
        corrupt["config.json"] = Data("broken".utf8)
        let installer = makeInstaller(transport: FixtureTransport(files: corrupt))

        do {
            _ = try await installer.install()
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertNil(installer.availableDirectory())
            XCTAssertFalse(FileManager.default.fileExists(atPath: installer.installedDirectory.path))
        }
    }

    func testTruncatedAndOversizedResponsesAreNeverPublished() async throws {
        var truncated = fixtureFiles
        truncated["weights.safetensors"] = Data("short".utf8)
        let truncatedInstaller = makeInstaller(transport: FixtureTransport(files: truncated))
        do {
            _ = try await truncatedInstaller.install()
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertNil(truncatedInstaller.availableDirectory())
        }

        var oversized = fixtureFiles
        oversized["config.json"] = Data("config-extra".utf8)
        let oversizedRoot = root.appendingPathComponent("oversized", isDirectory: true)
        try FileManager.default.createDirectory(at: oversizedRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oversizedRoot.path)
        let oversizedInstaller = GTELargeModelInstaller(
            rootDirectory: oversizedRoot,
            manifest: fixtureManifest,
            transport: FixtureTransport(files: oversized)
        )
        do {
            _ = try await oversizedInstaller.install()
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertNil(oversizedInstaller.availableDirectory())
        }
    }

    func testCancellationLeavesNoPartialInstallAvailable() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles, failure: CancellationError()))

        do {
            _ = try await installer.install()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertNil(installer.availableDirectory())
            let staging = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
                .filter { $0.lastPathComponent.hasPrefix(".gte-large-staging-") }
            XCTAssertTrue(staging.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPartialPriorInstallIsUnavailableWithoutStartingTransport() async {
        try? Data("config".utf8).write(to: root.appendingPathComponent("config.json"))
        let transport = FixtureTransport(files: fixtureFiles)
        let installer = makeInstaller(transport: transport)

        XCTAssertNil(installer.availableDirectory())
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testSameSizeCorruptionInvalidatesInstall() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let damaged = installer.installedDirectory.appendingPathComponent("config.json")
        try Data("broken".utf8).write(to: damaged)
        installer.invalidateVerificationCacheForTesting()

        XCTAssertNil(installer.availableDirectory())
    }

    func testSameSizeCorruptionWithRestoredModificationDateInvalidatesCachedInstall() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
        let damaged = installer.installedDirectory.appendingPathComponent("config.json")
        let original = try damaged.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try Data("broken".utf8).write(to: damaged)
        if let original {
            try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: damaged.path)
        }

        XCTAssertNil(installer.availableDirectory())
    }

    func testHardLinkedInstallFileIsUnavailable() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let installed = installer.installedDirectory.appendingPathComponent("config.json")
        let donor = root.appendingPathComponent("donor")
        try FileManager.default.copyItem(at: installed, to: donor)
        try FileManager.default.removeItem(at: installed)
        try FileManager.default.linkItem(at: donor, to: installed)

        XCTAssertNil(installer.availableDirectory())
    }

    func testPathSwapDuringHashIsNeverPublished() async throws {
        let transport = FixtureTransport(files: fixtureFiles)
        let installer = GTELargeModelInstaller(
            rootDirectory: root,
            manifest: fixtureManifest,
            hashing: SwappingHashing(replacement: fixtureFiles["config.json"]!),
            transport: transport
        )

        do {
            _ = try await installer.install()
            XCTFail("Expected path swap rejection")
        } catch {
            XCTAssertNil(installer.availableDirectory())
        }
    }

    func testAncestorSwapDuringDownloadIsNeverPublished() async throws {
        let live = root.appendingPathComponent("live", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: live.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
        let modelRoot = live.appendingPathComponent("models", isDirectory: true)
        let installer = GTELargeModelInstaller(
            rootDirectory: modelRoot,
            manifest: fixtureManifest,
            transport: AncestorSwappingTransport(files: fixtureFiles, ancestor: live, replacement: outside)
        )

        do {
            _ = try await installer.install()
            XCTFail("Expected ancestor swap rejection")
        } catch {
            XCTAssertNil(installer.availableDirectory())
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("models").path))
        }
    }

    func testDiskFullLeavesNoPublishedInstall() async {
        let installer = makeInstaller(
            transport: FixtureTransport(files: fixtureFiles, failure: CocoaError(.fileWriteOutOfSpace))
        )

        do {
            _ = try await installer.install()
            XCTFail("Expected write failure")
        } catch {
            XCTAssertNil(installer.availableDirectory())
        }
    }

    func testSymlinkedInstallRootAndFileAreUnavailable() async throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("foodmapper-gte-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let linkedRoot = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)
        let linkedInstaller = GTELargeModelInstaller(
            rootDirectory: linkedRoot,
            manifest: fixtureManifest,
            transport: FixtureTransport(files: fixtureFiles)
        )
        XCTAssertNil(linkedInstaller.availableDirectory())

        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let file = installer.installedDirectory.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertNil(installer.availableDirectory())
    }

    func testSymlinkedAncestorAndRelaxedPermissionsAreUnavailable() async throws {
        let target = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-gte-ancestor-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        let link = root.appendingPathComponent("ancestor")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let unsafe = GTELargeModelInstaller(
            rootDirectory: link.appendingPathComponent("models", isDirectory: true),
            manifest: fixtureManifest,
            transport: FixtureTransport(files: fixtureFiles)
        )
        XCTAssertNil(unsafe.availableDirectory())

        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.installedDirectory.path)
        XCTAssertNil(installer.availableDirectory())
    }

    func testDeleteLeavesUnrecordedRecoveryLookalikes() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let staging = root.appendingPathComponent(".gte-large-staging-\(UUID().uuidString)", isDirectory: true)
        let backup = root.appendingPathComponent(".gte-large-previous-\(UUID().uuidString)", isDirectory: true)
        let forged = root.appendingPathComponent(".gte-large-staging-looks-owned", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: forged, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: forged.path)

        try await installer.deleteInstallArtifacts()

        XCTAssertNil(installer.availableDirectory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.installedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: forged.path))
    }

    func testRecoveryClearsCorruptAndTraversalJournals() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        let journal = root.appendingPathComponent(".gte-large-promotion.json")
        try Data("not-json".utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        try await installer.recoverAtStartup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))

        let traversal = """
        {"schema":1,"revision":"0123456789abcdef0123456789abcdef01234567","stagingDirectoryName":"../outside","backupDirectoryName":null}
        """
        try Data(traversal.utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        try await installer.recoverAtStartup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testCorruptJournalPreservesUnboundUUIDArtifacts() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        let staging = root.appendingPathComponent(".gte-large-staging-\(UUID().uuidString)", isDirectory: true)
        let backup = root.appendingPathComponent(".gte-large-previous-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
        let journal = root.appendingPathComponent(".gte-large-promotion.json")
        try Data("invalid".utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)

        try await installer.recoverAtStartup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRecoveryKeepsOldInstallWhenPowerFailsBeforeBackupMove() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let oldIdentity = try directoryIdentity(installer.installedDirectory)
        let pointer = root.appendingPathComponent("current.json")
        try FileManager.default.removeItem(at: pointer)

        let stagingName = ".gte-large-staging-\(UUID().uuidString)"
        let backupName = ".gte-large-previous-\(UUID().uuidString)"
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        try FileManager.default.copyItem(at: installer.installedDirectory, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        let journal = GTELargePromotionJournal(
            schema: 1,
            revision: fixtureManifest.revision,
            stagingDirectoryName: stagingName,
            backupDirectoryName: backupName,
            stagingIdentity: try directoryIdentity(staging),
            backupIdentity: oldIdentity
        )
        let journalURL = root.appendingPathComponent(".gte-large-promotion.json")
        try JSONEncoder().encode(journal).write(to: journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)

        try await installer.recoverAtStartup()

        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRecoveryAcceptsJournalIdentityAfterPromotionRename() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let oldIdentity = try directoryIdentity(installer.installedDirectory)
        let stagingName = ".gte-large-staging-\(UUID().uuidString)"
        let backupName = ".gte-large-previous-\(UUID().uuidString)"
        let staging = root.appendingPathComponent(stagingName, isDirectory: true)
        let backup = root.appendingPathComponent(backupName, isDirectory: true)
        try FileManager.default.copyItem(at: installer.installedDirectory, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        let stagingIdentity = try directoryIdentity(staging)
        try FileManager.default.moveItem(at: installer.installedDirectory, to: backup)
        try FileManager.default.moveItem(at: staging, to: installer.installedDirectory)
        try FileManager.default.removeItem(at: root.appendingPathComponent("current.json"))
        let journal = GTELargePromotionJournal(
            schema: 1,
            revision: fixtureManifest.revision,
            stagingDirectoryName: stagingName,
            backupDirectoryName: backupName,
            stagingIdentity: stagingIdentity,
            backupIdentity: oldIdentity
        )
        let journalURL = root.appendingPathComponent(".gte-large-promotion.json")
        try JSONEncoder().encode(journal).write(to: journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)

        try await installer.recoverAtStartup()

        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testRecoveryPromotesExactCurrentPointerTemporary() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let pointer = root.appendingPathComponent("current.json")
        try FileManager.default.removeItem(at: pointer)
        let temporary = root.appendingPathComponent(".gte-large-current-\(UUID().uuidString)")
        let value = GTELargeInstallPointer(
            schema: 1,
            directoryName: fixtureManifest.installationDirectoryName,
            record: GTELargeModelInstallRecord(manifest: fixtureManifest)
        )
        try JSONEncoder().encode(value).write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        try await installer.recoverAtStartup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: pointer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
    }

    func testRecoveryRemovesInvalidCurrentPointerTemporary() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let temporary = root.appendingPathComponent(".gte-large-current-\(UUID().uuidString)")
        try Data("partial".utf8).write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        try await installer.recoverAtStartup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testRecoveryCleansBoundedCompleteStagingOrphan() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let staging = root.appendingPathComponent(".gte-large-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: installer.installedDirectory, to: staging)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)

        try await installer.recoverAtStartup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
    }

    func testLegacyDirectoryWith0755ModeIsUnavailableUntilRecovery() throws {
        try writeLegacyFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        XCTAssertNil(installer.availableDirectory())
    }

    func testInstallRepairsSafePartialLegacyDirectoryBeforeDownloading() async throws {
        let partial = root.appendingPathComponent("config.json")
        try fixtureFiles["config.json"]!.write(to: partial)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: partial.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))

        _ = try await installer.install()

        let rootMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((rootMode?.intValue ?? 0) & 0o777, 0o700)
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
    }

    func testDeleteLeavesOldRevisionLookalikes() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let old = root.appendingPathComponent("gte-large-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old.path)
        try await installer.deleteInstallArtifacts()
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testInstallUsesPrivatePermissions() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: installer.installedDirectory.path)
        let directoryMode = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(directoryMode.map { $0 & 0o777 }, 0o700)
        for file in fixtureManifest.files {
            let attributes = try FileManager.default.attributesOfItem(atPath: installer.installedDirectory.appendingPathComponent(file.name).path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600)
        }
    }

    func testVerifiedLegacyInstallMigratesWithoutNetwork() async throws {
        try writeLegacyFixture()
        let transport = FixtureTransport(files: fixtureFiles)
        let installer = makeInstaller(transport: transport)

        let directory = try await installer.install()
        XCTAssertEqual(directory, installer.installedDirectory)
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testConcurrentLegacyMigrationsPublishOneVerifiedInstall() async throws {
        try writeLegacyFixture()
        let transport = FixtureTransport(files: fixtureFiles)
        let installer = makeInstaller(transport: transport)

        async let first = installer.install()
        async let second = installer.install()
        let directories = try await [first, second]
        let requestCount = await transport.requestCount

        XCTAssertEqual(directories, [installer.installedDirectory, installer.installedDirectory])
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
        XCTAssertEqual(requestCount, 0)
    }

    func testFailedCommitRollsBackPreviousDirectory() async throws {
        let installer = makeInstaller(
            transport: FixtureTransport(files: fixtureFiles),
            fileSystem: FailingCommitFileSystem()
        )
        try FileManager.default.createDirectory(at: installer.installedDirectory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: installer.installedDirectory.appendingPathComponent("config.json"))

        do {
            _ = try await installer.install()
            XCTFail("Expected commit failure")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: installer.installedDirectory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: installer.installedDirectory.appendingPathComponent("config.json").path))
            XCTAssertNil(installer.availableDirectory())
        }
    }

    func testAvailabilityDoesNotMutateInterruptedInstall() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let backup = root.appendingPathComponent(".gte-large-previous-interrupted", isDirectory: true)
        try FileManager.default.moveItem(at: installer.installedDirectory, to: backup)

        XCTAssertNil(installer.availableDirectory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testNoNetworkAvailabilityCheckForValidInstall() async throws {
        try writeLegacyFixture()
        let transport = FixtureTransport(files: fixtureFiles)
        let installer = makeInstaller(transport: transport)

        XCTAssertEqual(installer.availableDirectory(), root)
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testVerificationUsesInjectedHasher() throws {
        try writeLegacyFixture()
        let hashing = FixtureHashing()
        let installer = GTELargeModelInstaller(
            rootDirectory: root,
            manifest: fixtureManifest,
            hashing: hashing,
            transport: FixtureTransport(files: fixtureFiles)
        )

        XCTAssertEqual(installer.availableDirectory(), root)
        XCTAssertEqual(hashing.callCount, fixtureManifest.files.count)
    }

    func testDownloadURLPolicyAllowsOnlyPinnedHTTPSHosts() {
        let accepted = [
            "https://huggingface.co/example/model/resolve/0123456789abcdef0123456789abcdef01234567/config.json",
            "https://cdn-lfs.huggingface.co/blob",
            "https://cas-bridge.xethub.hf.co/blob",
            "https://us.aws.cdn.hf.co/blob",
            "https://huggingface.co:443/blob",
        ]
        let rejected = [
            "http://huggingface.co/blob",
            "https://huggingface.co.evil.example/blob",
            "https://huggingface.co./blob",
            "https://user@huggingface.co/blob",
            "https://huggingface.co:444/blob",
            "https://127.0.0.1/blob",
            "https://[::1]/blob",
        ]

        for value in accepted {
            XCTAssertTrue(GTELargeDownloadURLPolicy.accepts(URL(string: value)!))
        }
        for value in rejected {
            XCTAssertFalse(GTELargeDownloadURLPolicy.accepts(URL(string: value)!))
        }
    }

    func testURLSessionTemporaryPathCopiesThroughRegularDescriptor() throws {
        let source = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("foodmapper-urlsession-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("payload")
        let data = Data("download payload".utf8)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try GTELargeSecurePath.copyURLSessionDownloadPayload(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), data)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
    }

    func testInjectedRootWithTraversalIsRejectedBeforeDelete() async throws {
        let protected = root.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let marker = protected.appendingPathComponent("marker")
        try Data("keep".utf8).write(to: marker)
        let unsafeRoot = root.appendingPathComponent("missing/../protected", isDirectory: true)
        let installer = GTELargeModelInstaller(
            rootDirectory: unsafeRoot,
            manifest: fixtureManifest,
            transport: FixtureTransport(files: fixtureFiles)
        )

        XCTAssertNil(installer.availableDirectory())
        try await installer.deleteInstallArtifacts()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDownloadURLPolicyRejectsRedirectLoopsAfterFourHops() {
        let url = URL(string: "https://cdn-lfs.huggingface.co/blob")!
        XCTAssertTrue(GTELargeDownloadURLPolicy.acceptsRedirect(url, redirectCount: 1))
        XCTAssertTrue(GTELargeDownloadURLPolicy.acceptsRedirect(url, redirectCount: 4))
        XCTAssertFalse(GTELargeDownloadURLPolicy.acceptsRedirect(url, redirectCount: 5))
    }

    private func makeInstaller(
        transport: any GTELargeDownloadTransport,
        fileSystem: any GTELargeFileSystem = LocalGTELargeFileSystem(),
        hashing: any GTELargeHashing = SHA256GTELargeHashing()
    ) -> GTELargeModelInstaller {
        GTELargeModelInstaller(
            rootDirectory: root,
            manifest: fixtureManifest,
            fileSystem: fileSystem,
            hashing: hashing,
            transport: transport
        )
    }

    private func writeLegacyFixture() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for (name, data) in fixtureFiles {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func directoryIdentity(_ url: URL) throws -> GTELargeFileIdentity {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return GTELargeFileIdentity(
            size: Int64(value.st_size),
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec),
            linkCount: UInt64(value.st_nlink),
            mode: UInt16(value.st_mode & 0o777),
            owner: UInt32(value.st_uid)
        )
    }

    private var fixtureManifest: GTELargeModelManifest {
        GTELargeModelManifest(
            formatVersion: 1,
            repositoryID: "example/fixture",
            revision: "0123456789abcdef0123456789abcdef01234567",
            files: [
                .init(name: "config.json", size: 6, sha256: "b79606fb3afea5bd1609ed40b622142f1c98125abcfe89a76a661b0e8e343910"),
                .init(name: "weights.safetensors", size: 7, sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c"),
            ]
        )
    }

    private var fixtureFiles: [String: Data] {
        [
            "config.json": Data("config".utf8),
            "weights.safetensors": Data("weights".utf8),
        ]
    }
}

private actor FixtureTransport: GTELargeDownloadTransport {
    private let files: [String: Data]
    private let failure: Error?
    private var requestedURLs: [URL] = []

    init(files: [String: Data], failure: Error? = nil) {
        self.files = files
        self.failure = failure
    }

    var requestCount: Int { requestedURLs.count }

    func download(
        from source: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        requestedURLs.append(source)
        if let failure { throw failure }
        guard let data = files[source.lastPathComponent] else {
            throw CocoaError(.fileNoSuchFile)
        }
        try data.write(to: destination)
        onProgress(Int64(data.count))
    }
}

private actor AncestorSwappingTransport: GTELargeDownloadTransport {
    private let files: [String: Data]
    private let ancestor: URL
    private let replacement: URL
    private var swapped = false

    init(files: [String: Data], ancestor: URL, replacement: URL) {
        self.files = files
        self.ancestor = ancestor
        self.replacement = replacement
    }

    func download(
        from source: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let data = files[source.lastPathComponent] else { throw CocoaError(.fileNoSuchFile) }
        try data.write(to: destination)
        onProgress(Int64(data.count))
        guard !swapped else { return }
        swapped = true
        let moved = ancestor.deletingLastPathComponent().appendingPathComponent("moved-live", isDirectory: true)
        try FileManager.default.moveItem(at: ancestor, to: moved)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: replacement)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64)] = []

    func append(_ value: (Int64, Int64)) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var last: (Int64, Int64)? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}

private final class FixtureHashing: GTELargeHashing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func sha256(of url: URL) throws -> String {
        lock.lock()
        calls += 1
        lock.unlock()
        switch url.lastPathComponent {
        case "config.json":
            return "b79606fb3afea5bd1609ed40b622142f1c98125abcfe89a76a661b0e8e343910"
        case "weights.safetensors":
            return "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c"
        default:
            throw CocoaError(.fileReadUnknown)
        }
    }
}

private final class SwappingHashing: GTELargeHashing, @unchecked Sendable {
    private let replacement: Data
    private let lock = NSLock()
    private var didSwap = false

    init(replacement: Data) {
        self.replacement = replacement
    }

    func sha256(of url: URL) throws -> String {
        lock.lock()
        let shouldSwap = !didSwap && url.lastPathComponent == "config.json"
        didSwap = true
        lock.unlock()
        if shouldSwap {
            try FileManager.default.removeItem(at: url)
            try replacement.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return SHA256.hash(data: replacement).map { String(format: "%02x", $0) }.joined()
    }
}

private struct FailingCommitFileSystem: GTELargeFileSystem {
    private let local = LocalGTELargeFileSystem()

    func itemExists(at url: URL) -> Bool { local.itemExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) throws { try local.createDirectory(at: url, permissions: permissions) }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try local.contentsOfDirectory(at: url) }
    func copyItem(at source: URL, to destination: URL) throws { try local.copyItem(at: source, to: destination) }
    func write(_ data: Data, to url: URL, permissions: Int) throws { try local.write(data, to: url, permissions: permissions) }
    func read(from url: URL) throws -> Data { try local.read(from: url) }
    func fileIdentity(at url: URL) throws -> GTELargeFileIdentity { try local.fileIdentity(at: url) }
    func directoryIdentity(at url: URL, requiredPermissions: Int?) throws -> GTELargeFileIdentity {
        try local.directoryIdentity(at: url, requiredPermissions: requiredPermissions)
    }
    func setPermissions(_ permissions: Int, at url: URL) throws { try local.setPermissions(permissions, at: url) }
    func syncFile(at url: URL) throws { try local.syncFile(at: url) }
    func syncDirectory(at url: URL) throws { try local.syncDirectory(at: url) }

    func moveItem(at source: URL, to destination: URL) throws {
        if source.lastPathComponent.hasPrefix(".gte-large-staging-") && destination.lastPathComponent.hasPrefix("gte-large-") {
            throw CocoaError(.fileWriteUnknown)
        }
        try local.moveItem(at: source, to: destination)
    }
}
