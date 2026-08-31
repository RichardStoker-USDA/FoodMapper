import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import FoodMapper

final class GTELargeModelInstallTests: XCTestCase {

    func testCurrentManifestUsesCorrectedMITArtifactRevision() {
        XCTAssertEqual(GTELargeModelManifest.current.revision, "200d1bf79e6a152736fe1517703d0079a0bd16fa")
        XCTAssertEqual(GTELargeModelManifest.current.upstreamLicense, "MIT")
        XCTAssertEqual(GTELargeModelManifest.current.files.first(where: { $0.name == "gte-large.safetensors" })?.sha256, "f917f334b6e38e966519983a6b567a5a86d90065932c780f6b4ad72e6bf3a90b")
    }
    private var root: URL!

    override func setUpWithError() throws {
        try FoodMapperStorage.bootstrap()
        let root = FoodMapperStorage.temporaryURL
            .appendingPathComponent("foodmapper-gte-install-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    func testProductionManifestPinsRevisionSizesAndHashes() {
        let manifest = GTELargeModelManifest.current
        XCTAssertEqual(manifest.revision, "200d1bf79e6a152736fe1517703d0079a0bd16fa")
        XCTAssertEqual(manifest.upstreamRepositoryID, "thenlper/gte-large")
        XCTAssertEqual(manifest.upstreamRevision, "4bef63f39fcc5e2d6b0aae83089f307af4970164")
        XCTAssertEqual(manifest.upstreamLicense, "MIT")
        XCTAssertEqual(manifest.conversion, "MLX-Swift float16 BERT safetensors conversion")
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

    func testCancelledOperationWaiterDoesNotReceiveReleasedLease() async throws {
        let coordinator = GTELargeOperationCoordinator()
        let key = "foodmapper-gte-test-\(UUID().uuidString)"
        try await coordinator.acquire(root: key)
        let waiting = Task { try await coordinator.acquire(root: key) }
        await Task.yield()
        waiting.cancel()
        await Task.yield()
        await coordinator.release(root: key)

        do {
            try await waiting.value
            XCTFail("Cancelled waiter acquired a lease")
        } catch is CancellationError {
            // The continuation was removed before the held lease was released.
        }

        try await coordinator.acquire(root: key)
        await coordinator.release(root: key)
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
        let target = root.appendingPathComponent("symlink-target", isDirectory: true)
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
        let target = root.appendingPathComponent("ancestor-target", isDirectory: true)
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

    func testRecoveryRestoresValidPriorPointerBackup() async throws {
        let prior = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await prior.install()
        let pointer = root.appendingPathComponent("current.json")
        let backup = root.appendingPathComponent(".gte-large-current-previous-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: pointer, to: backup)

        let replacementManifest = GTELargeModelManifest(
            formatVersion: fixtureManifest.formatVersion,
            repositoryID: fixtureManifest.repositoryID,
            revision: "fedcba9876543210fedcba9876543210fedcba98",
            upstreamRepositoryID: fixtureManifest.upstreamRepositoryID,
            upstreamRevision: fixtureManifest.upstreamRevision,
            upstreamLicense: fixtureManifest.upstreamLicense,
            conversion: fixtureManifest.conversion,
            files: fixtureManifest.files
        )
        let replacement = GTELargeModelInstaller(
            rootDirectory: root,
            manifest: replacementManifest,
            transport: FixtureTransport(files: fixtureFiles)
        )

        try await replacement.recoverAtStartup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: pointer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(prior.availableDirectory(), prior.installedDirectory)
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

    func testRecoveryPromotesCurrentTemporaryOverMalformedPointer() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let pointer = root.appendingPathComponent("current.json")
        try Data("partial".utf8).write(to: pointer)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pointer.path)
        let temporary = root.appendingPathComponent(".gte-large-current-\(UUID().uuidString)")
        let value = GTELargeInstallPointer(
            schema: 1,
            directoryName: fixtureManifest.installationDirectoryName,
            record: GTELargeModelInstallRecord(manifest: fixtureManifest)
        )
        try JSONEncoder().encode(value).write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        try await installer.recoverAtStartup()

        let recovered = try JSONDecoder().decode(GTELargeInstallPointer.self, from: Data(contentsOf: pointer))
        XCTAssertEqual(recovered.schema, value.schema)
        XCTAssertEqual(recovered.directoryName, value.directoryName)
        XCTAssertTrue(recovered.record.matches(fixtureManifest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testRecoveryDoesNotPromotePointerWithoutVerifiedPayload() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let temporary = root.appendingPathComponent(".gte-large-current-\(UUID().uuidString)")
        let value = GTELargeInstallPointer(
            schema: 1,
            directoryName: fixtureManifest.installationDirectoryName,
            record: GTELargeModelInstallRecord(manifest: fixtureManifest)
        )
        try JSONEncoder().encode(value).write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.removeItem(at: installer.installedDirectory)

        try await installer.recoverAtStartup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertNil(installer.availableDirectory())
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

    func testRecoveryCleansVerifiedRollbackDirectoryAndLeavesUnknownContents() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        let verified = root.appendingPathComponent(
            ".gte-large-unverified-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: installer.installedDirectory, to: verified)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: verified.path)

        let unknown = root.appendingPathComponent(
            ".gte-large-unverified-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unknown.path)
        let unknownPayload = unknown.appendingPathComponent("unknown")
        try Data("keep".utf8).write(to: unknownPayload)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unknownPayload.path)

        try await installer.recoverAtStartup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: verified.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
    }

    func testRecoveryRemovesEveryBoundedOwnedStagingOrphan() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        var stagingDirectories: [URL] = []
        for _ in 0..<9 {
            let staging = root.appendingPathComponent(".gte-large-staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: installer.installedDirectory, to: staging)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            stagingDirectories.append(staging)
        }

        try await installer.recoverAtStartup()

        XCTAssertTrue(stagingDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testRecoveryRejectsExcessCurrentPointerTemporaries() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await installer.install()
        for _ in 0..<33 {
            let temporary = root.appendingPathComponent(".gte-large-current-\(UUID().uuidString)")
            try Data("partial".utf8).write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        }
        do {
            try await installer.recoverAtStartup()
            XCTFail("Expected bounded temporary recovery to fail")
        } catch {
            XCTAssertTrue(error is GTELargeModelInstallError)
        }
    }

    func testRecoveryRejectsExcessJournalCopyInvalidAndRemovingArtifacts() async throws {
        try await assertRecoveryRejectsExcessArtifacts(prefix: ".gte-large-journal-", count: 33)
        try await assertRecoveryRejectsExcessArtifacts(prefix: ".gte-large-copy-", count: 33)
        try await assertRecoveryRejectsExcessArtifacts(prefix: ".gte-large-invalid-journal-", count: 9)
        try await assertRecoveryRejectsExcessArtifacts(prefix: ".gte-large-removing-", count: 33)
    }

    func testRecoveryRemovesBoundedPrivateRemovalArtifact() async throws {
        let installer = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        let artifact = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)", isDirectory: true)
        let nested = artifact.appendingPathComponent("nested", isDirectory: true)
        let payload = nested.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifact.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
        try Data("partial".utf8).write(to: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)

        try await installer.recoverAtStartup()
        try await installer.recoverAtStartup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
    }

    func testPrivateTreeAccountsForNestedBytesBeforeRemoval() throws {
        let artifact = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)", isDirectory: true)
        let nested = artifact.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifact.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
        let payload = nested.appendingPathComponent("payload")
        try Data(repeating: 7, count: 31).write(to: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)

        let tree = try GTELargeSecurePath.privateTree(
            at: artifact,
            maximumEntries: 3,
            maximumDepth: 2,
            maximumBytes: 31
        )

        XCTAssertTrue(tree.isDirectory)
        XCTAssertEqual(tree.bytes, 31)
        XCTAssertThrowsError(try GTELargeSecurePath.privateTree(
            at: artifact,
            maximumEntries: 3,
            maximumDepth: 2,
            maximumBytes: 30
        ))
    }

    func testPrivateTreeRejectsExcessiveEntriesBeforeBuildingAnUnboundedSnapshot() throws {
        let artifact = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifact.path)
        let children = (0..<3).map { artifact.appendingPathComponent("entry-\($0)") }
        for child in children {
            try Data("x".utf8).write(to: child)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: child.path)
        }

        XCTAssertThrowsError(try GTELargeSecurePath.privateTree(
            at: artifact,
            maximumEntries: 3,
            maximumDepth: 1,
            maximumBytes: 3
        )) { error in
            XCTAssertTrue(error is GTELargeModelInstallError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertTrue(children.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    #if DEBUG
    func testDirectoryEntryNamesReportsReaddirError() throws {
        let descriptor = try GTELargeSecurePath.openDirectoryDescriptor(at: root)
        defer { close(descriptor) }

        XCTAssertThrowsError(try GTELargeSecurePath.directoryEntryNamesForTesting(
            descriptor,
            maximumEntries: 1,
            read: { _ in
                errno = EIO
                return nil
            }
        )) { error in
            guard case GTELargeModelInstallError.unreadableInstall = error else {
                return XCTFail("Expected unreadableInstall, got \(error)")
            }
        }
    }
    #endif

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

    func testFailedInitialPromotionRetainsJournaledStagingForRecovery() async throws {
        let failing = makeInstaller(
            transport: FixtureTransport(files: fixtureFiles),
            fileSystem: FailingCommitFileSystem()
        )
        do {
            _ = try await failing.install()
            XCTFail("Expected promotion failure")
        } catch {}

        let recovery = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        try await recovery.recoverAtStartup()

        XCTAssertEqual(recovery.availableDirectory(), recovery.installedDirectory)
    }

    func testJournalRenameFailurePreservesRecoverableTemporaryAndStaging() async throws {
        let installer = makeInstaller(
            transport: FixtureTransport(files: fixtureFiles),
            fileSystem: FailingPromotionWriteFileSystem(failure: .journal)
        )

        do {
            _ = try await installer.install()
            XCTFail("Expected journal write failure")
        } catch {
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            XCTAssertTrue(entries.contains { $0.lastPathComponent.hasPrefix(".gte-large-journal-") })
            XCTAssertTrue(entries.contains { $0.lastPathComponent.hasPrefix(".gte-large-staging-") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: installer.installedDirectory.path))
        }

        let recovery = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        try await recovery.recoverAtStartup()
        XCTAssertEqual(recovery.availableDirectory(), recovery.installedDirectory)
    }

    func testCurrentPointerRenameFailureRecoversVerifiedInstall() async throws {
        let installer = makeInstaller(
            transport: FixtureTransport(files: fixtureFiles),
            fileSystem: FailingPromotionWriteFileSystem(failure: .current)
        )

        do {
            _ = try await installer.install()
            XCTFail("Expected current-pointer write failure")
        } catch {
            let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            XCTAssertTrue(entries.contains { $0.lastPathComponent.hasPrefix(".gte-large-current-") })
            XCTAssertTrue(FileManager.default.fileExists(atPath: installer.installedDirectory.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gte-large-promotion.json").path))
        }

        let recovery = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        try await recovery.recoverAtStartup()
        XCTAssertEqual(recovery.availableDirectory(), recovery.installedDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gte-large-promotion.json").path))
    }

    func testCurrentPointerReplacementFailureKeepsPriorInstallAvailable() async throws {
        let prior = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await prior.install()
        XCTAssertEqual(prior.availableDirectory(), prior.installedDirectory)

        let replacementManifest = GTELargeModelManifest(
            formatVersion: fixtureManifest.formatVersion,
            repositoryID: fixtureManifest.repositoryID,
            revision: "fedcba9876543210fedcba9876543210fedcba98",
            upstreamRepositoryID: fixtureManifest.upstreamRepositoryID,
            upstreamRevision: fixtureManifest.upstreamRevision,
            upstreamLicense: fixtureManifest.upstreamLicense,
            conversion: fixtureManifest.conversion,
            files: fixtureManifest.files
        )
        let replacement = GTELargeModelInstaller(
            rootDirectory: root,
            manifest: replacementManifest,
            fileSystem: FailingPromotionWriteFileSystem(failure: .current),
            transport: FixtureTransport(files: fixtureFiles)
        )

        do {
            _ = try await replacement.install()
            XCTFail("Expected current-pointer replacement failure")
        } catch {}
        XCTAssertEqual(prior.availableDirectory(), prior.installedDirectory)
    }

    func testCurrentPointerSyncFailureRestoresPriorPointer() async throws {
        let prior = makeInstaller(transport: FixtureTransport(files: fixtureFiles))
        _ = try await prior.install()

        let replacementManifest = GTELargeModelManifest(
            formatVersion: fixtureManifest.formatVersion,
            repositoryID: fixtureManifest.repositoryID,
            revision: "fedcba9876543210fedcba9876543210fedcba98",
            upstreamRepositoryID: fixtureManifest.upstreamRepositoryID,
            upstreamRevision: fixtureManifest.upstreamRevision,
            upstreamLicense: fixtureManifest.upstreamLicense,
            conversion: fixtureManifest.conversion,
            files: fixtureManifest.files
        )
        let replacement = GTELargeModelInstaller(
            rootDirectory: root,
            manifest: replacementManifest,
            fileSystem: FailingPromotionWriteFileSystem(failure: .postPointerSync),
            transport: FixtureTransport(files: fixtureFiles)
        )

        do {
            _ = try await replacement.install()
            XCTFail("Expected current-pointer sync failure")
        } catch {}
        XCTAssertEqual(prior.availableDirectory(), prior.installedDirectory)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".gte-large-current-previous-") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testPromotionRejectsReplacementBeforeRename() async throws {
        let installer = makeInstaller(
            transport: FixtureTransport(files: fixtureFiles),
            fileSystem: ReplacingPromotionSourceFileSystem()
        )

        do {
            _ = try await installer.install()
            XCTFail("Expected replacement source rejection")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.installedDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("current.json").path))
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
        let source = FoodMapperStorage.processTemporaryRootURL
            .appendingPathComponent("foodmapper-urlsession-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("payload")
        let data = Data("download payload".utf8)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try GTELargeSecurePath.copyURLSessionDownloadPayload(from: source, to: destination, expectedSize: Int64(data.count))

        XCTAssertEqual(try Data(contentsOf: destination), data)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
    }

    func testURLSessionPayloadCopyRemovesPartialFileAfterCancellation() throws {
        let source = FoodMapperStorage.processTemporaryRootURL
            .appendingPathComponent("foodmapper-urlsession-cancel-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("cancelled-payload")
        let data = Data(repeating: 7, count: 2_097_152)
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var checks = 0

        XCTAssertThrowsError(try GTELargeSecurePath.copyURLSessionDownloadPayload(
            from: source,
            to: destination,
            expectedSize: Int64(data.count),
            cancellationCheck: {
                checks += 1
                if checks == 2 { throw CancellationError() }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testURLSessionTemporaryPathAcceptsSystemAliasSpelling() throws {
        let canonicalRoot = FoodMapperStorage.processTemporaryRootURL
        let components = canonicalRoot.pathComponents
        let aliasableDirectoryNames: Set<String> = ["tmp", "var"]
        let aliasPath: String
        if components.count >= 3,
           components[1] == "private",
           aliasableDirectoryNames.contains(components[2]) {
            aliasPath = String(canonicalRoot.path.dropFirst("/private".count))
        } else {
            aliasPath = canonicalRoot.path
        }
        let source = URL(fileURLWithPath: aliasPath, isDirectory: true)
            .appendingPathComponent("foodmapper-urlsession-root-\(UUID().uuidString)")
        try Data("payload".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let validated = try GTELargeSecurePath.validatedURLSessionTemporaryFile(source)
        XCTAssertEqual(validated.deletingLastPathComponent(), canonicalRoot)
        XCTAssertEqual(try Data(contentsOf: validated), Data("payload".utf8))
    }

    func testURLSessionTemporaryPathRejectsOversizedPayload() throws {
        let source = FoodMapperStorage.processTemporaryRootURL
            .appendingPathComponent("foodmapper-oversized-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(repeating: 1, count: 16).write(to: source)
        XCTAssertThrowsError(try GTELargeSecurePath.copyURLSessionDownloadPayload(
            from: source,
            to: root.appendingPathComponent("oversized"),
            expectedSize: 15
        ))
    }

    func testSmallPrivateReadRejectsPayloadBeyondChunkBudget() throws {
        let source = root.appendingPathComponent("small-read")
        try Data(repeating: 1, count: 65_537).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        XCTAssertThrowsError(try GTELargeSecurePath.readPrivateFile(at: source, maximumSize: 65_536))
    }

    func testDirectoryPromotionRejectsMismatchedRecordedIdentity() throws {
        let source = root.appendingPathComponent(".gte-large-staging-\(UUID().uuidString)", isDirectory: true)
        let unrelated = root.appendingPathComponent(".gte-large-previous-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("gte-large-\(fixtureManifest.revision)", isDirectory: true)
        for directory in [source, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let unrelatedIdentity = try LocalGTELargeFileSystem().directoryIdentity(at: unrelated, requiredPermissions: 0o700)

        XCTAssertThrowsError(try LocalGTELargeFileSystem().moveItem(
            at: source,
            to: destination,
            expectedSourceDirectoryIdentity: unrelatedIdentity
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testURLSessionTemporaryPathRejectsTraversalAliasesAndForeignRoots() throws {
        let temporaryRoot = FoodMapperStorage.processTemporaryRootURL
        let foreign = FoodMapperStorage.applicationSupportURL
            .appendingPathComponent("urlsession-cross-root-\(UUID().uuidString)")
        try Data("x".utf8).write(to: foreign)
        defer { try? FileManager.default.removeItem(at: foreign) }
        XCTAssertThrowsError(try GTELargeSecurePath.validatedURLSessionTemporaryFile(foreign))

        let traversal = URL(string: "file://\(temporaryRoot.path)/%2E%2E/foreign")!
        XCTAssertThrowsError(try GTELargeSecurePath.validatedURLSessionTemporaryFile(traversal))

        let outside = FoodMapperStorage.applicationSupportURL
            .appendingPathComponent("urlsession-symlink-target-\(UUID().uuidString)")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = temporaryRoot.appendingPathComponent("foodmapper-temp-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try GTELargeSecurePath.validatedURLSessionTemporaryFile(link))

        let localhost = URL(string: "file://localhost\(temporaryRoot.path)/payload")!
        XCTAssertThrowsError(try GTELargeSecurePath.validatedURLSessionTemporaryFile(localhost))
    }

    func testURLSessionTemporaryPathRejectsRepeatedDecodedTraversalAndSeparators() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
        let encodedComponents = [
            "%2E%2E", "%252E%252E", ".%2E", "%2E.",
            "%2F", "%252F", "%5C", "%255C"
        ]

        for component in encodedComponents {
            let url = URL(string: "file://\(temporaryRoot.path)/\(component)/payload")!
            XCTAssertThrowsError(
                try GTELargeSecurePath.validatedURLSessionTemporaryFile(url),
                "Expected \(component) to be rejected before descriptor traversal"
            )
        }
    }

    func testURLSessionTemporaryPathRejectsInRootLeafSymlink() throws {
        #if DEBUG
        let temporaryRoot = root.appendingPathComponent("urlsession-symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRoot.path)
        FoodMapperModelStorage.testingURLSessionTemporaryDirectory = temporaryRoot
        defer { FoodMapperModelStorage.testingURLSessionTemporaryDirectory = nil }

        let target = temporaryRoot.appendingPathComponent("target")
        try Data("payload".utf8).write(to: target)
        let link = temporaryRoot.appendingPathComponent("leaf-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try GTELargeSecurePath.validatedURLSessionTemporaryFile(link))
        #endif
    }

    func testLegacyCopyRejectsUnexpectedSourceLength() throws {
        let source = root.appendingPathComponent("legacy-source")
        try Data("more than expected".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let identity = try GTELargeSecurePath.fileIdentity(at: source)

        XCTAssertThrowsError(try GTELargeSecurePath.copyDownloadedPayload(
            from: source,
            to: root.appendingPathComponent("legacy-destination"),
            expectedSourceIdentity: identity,
            expectedSize: 1
        ))
    }

    func testBoundedHashRejectsUnexpectedGrowth() throws {
        let source = root.appendingPathComponent("growing-hash")
        try Data("two".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)

        XCTAssertThrowsError(try GTELargeSecurePath.hashPrivateFile(at: source, expectedSize: 1))
    }

    func testPrivateTreeRemovalRejectsChangedAccounting() throws {
        let artifact = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifact.path)
        let payload = artifact.appendingPathComponent("payload")
        try Data("one".utf8).write(to: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
        let tree = try GTELargeSecurePath.privateTree(at: artifact, maximumEntries: 2, maximumDepth: 1, maximumBytes: 3)

        try Data("longer".utf8).write(to: payload)
        XCTAssertThrowsError(try GTELargeSecurePath.removePrivateTree(at: artifact, tree: tree, maximumDepth: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertEqual(try Data(contentsOf: payload), Data("longer".utf8))
    }

    func testPrivateTreeRemovalRejectsEqualAccountingDescendantReplacement() throws {
        let artifact = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifact.path)
        let payload = artifact.appendingPathComponent("payload")
        let displaced = artifact.appendingPathComponent("displaced")
        try Data("one".utf8).write(to: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
        let tree = try GTELargeSecurePath.privateTree(at: artifact, maximumEntries: 2, maximumDepth: 1, maximumBytes: 3)

        try FileManager.default.moveItem(at: payload, to: displaced)
        try Data("two".utf8).write(to: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)

        XCTAssertThrowsError(try GTELargeSecurePath.removePrivateTree(at: artifact, tree: tree, maximumDepth: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertEqual(try Data(contentsOf: payload), Data("two".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
    }

    func testPrivateTreeRemovalRejectsAddedDescendantAfterSnapshot() throws {
        let artifact = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifact.path)
        let payload = artifact.appendingPathComponent("payload")
        try Data("one".utf8).write(to: payload)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
        let tree = try GTELargeSecurePath.privateTree(at: artifact, maximumEntries: 2, maximumDepth: 1, maximumBytes: 3)

        let added = artifact.appendingPathComponent("added")
        try Data("two".utf8).write(to: added)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: added.path)

        XCTAssertThrowsError(try GTELargeSecurePath.removePrivateTree(at: artifact, tree: tree, maximumDepth: 1)) { error in
            XCTAssertTrue(error is GTELargeModelInstallError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.path))
    }

    func testPrivateTreeRemovalRejectsRemovedDescendantAfterSnapshot() throws {
        let artifact = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: artifact.path)
        let children = [artifact.appendingPathComponent("first"), artifact.appendingPathComponent("second")]
        for child in children {
            try Data("x".utf8).write(to: child)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: child.path)
        }
        let tree = try GTELargeSecurePath.privateTree(at: artifact, maximumEntries: 3, maximumDepth: 1, maximumBytes: 2)

        try FileManager.default.removeItem(at: children[1])

        XCTAssertThrowsError(try GTELargeSecurePath.removePrivateTree(at: artifact, tree: tree, maximumDepth: 1)) { error in
            XCTAssertTrue(error is GTELargeModelInstallError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: children[0].path))
    }

    func testPrivateTreeRejectsFIFO() throws {
        let fifo = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        XCTAssertThrowsError(try GTELargeSecurePath.privateTree(
            at: fifo,
            maximumEntries: 1,
            maximumDepth: 0,
            maximumBytes: 0
        )) { error in
            XCTAssertTrue(error is GTELargeModelInstallError)
        }
    }

    func testPrivateTreeRejectsCharacterDevice() throws {
        XCTAssertThrowsError(try GTELargeSecurePath.privateTree(
            at: URL(fileURLWithPath: "/dev/null"),
            maximumEntries: 1,
            maximumDepth: 0,
            maximumBytes: 0
        )) { error in
            XCTAssertTrue(error is GTELargeModelInstallError)
        }
    }

    func testIdentityConvertsUnusualDarwinMetadataWithoutTrapping() {
        var status = stat()
        status.st_dev = -1
        status.st_ino = UInt64.max

        let identity = GTELargeSecurePath.identity(from: status)

        XCTAssertEqual(identity.device, UInt64(UInt32.max))
        XCTAssertEqual(identity.inode, UInt64.max)
    }

    func testIdentityRejectsInPlaceChangeNanosecondMutation() {
        var first = stat()
        first.st_dev = 7
        first.st_ino = 11
        first.st_size = 5
        first.st_ctimespec.tv_sec = 42
        first.st_ctimespec.tv_nsec = 1
        first.st_nlink = 1
        first.st_mode = S_IFREG | 0o600
        first.st_uid = getuid()
        var second = first
        second.st_ctimespec.tv_nsec = 2

        XCTAssertFalse(GTELargeSecurePath.sameFileIdentity(
            GTELargeSecurePath.identity(from: first),
            GTELargeSecurePath.identity(from: second)
        ))
    }

    func testDescriptorWalkRejectsParentTraversalComponent() throws {
        let protected = root.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let traversal = URL(fileURLWithPath: root.path + "/missing/../protected", isDirectory: true)

        XCTAssertThrowsError(try GTELargeSecurePath.openDirectoryDescriptor(at: traversal))
    }

    func testPrivateTreeRejectsBlockDeviceWhenTheHostAllowsCreation() throws {
        let device = root.appendingPathComponent("block-device")
        guard mknod(device.path, S_IFBLK | 0o600, 0) == 0 else {
            guard errno == EPERM || errno == EACCES else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            throw XCTSkip("Creating a block device requires privileges on this host")
        }
        defer { try? FileManager.default.removeItem(at: device) }

        XCTAssertThrowsError(try GTELargeSecurePath.privateTree(
            at: device,
            maximumEntries: 1,
            maximumDepth: 0,
            maximumBytes: 0
        ))
    }

    func testFileRemovalRejectsReplacementObservedBeforeFinalUnlink() throws {
        let file = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)")
        let displaced = root.appendingPathComponent("displaced-file")
        try Data("one".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let identity = try GTELargeSecurePath.fileIdentity(at: file)
        try FileManager.default.moveItem(at: file, to: displaced)
        try Data("two".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        XCTAssertThrowsError(try GTELargeSecurePath.removePrivateItem(at: file, expectedFileIdentity: identity))
        XCTAssertEqual(try Data(contentsOf: file), Data("two".utf8))
        XCTAssertEqual(try Data(contentsOf: displaced), Data("one".utf8))
    }

    func testDirectoryRemovalRejectsReplacementObservedBeforeUnlink() throws {
        let directory = root.appendingPathComponent(".gte-large-removing-\(UUID().uuidString)", isDirectory: true)
        let displaced = root.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let identity = try GTELargeSecurePath.directoryIdentity(at: directory, requiredMode: 0o700)
        try FileManager.default.moveItem(at: directory, to: displaced)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        XCTAssertThrowsError(try GTELargeSecurePath.removePrivateItem(at: directory, expectedDirectoryIdentity: identity))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testURLSessionTemporaryPathUsesInjectedStorageRoot() throws {
        #if DEBUG
        let temporaryRoot = root.appendingPathComponent("urlsession-temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRoot.path)
        FoodMapperModelStorage.testingURLSessionTemporaryDirectory = temporaryRoot
        defer { FoodMapperModelStorage.testingURLSessionTemporaryDirectory = nil }

        let source = temporaryRoot.appendingPathComponent("payload")
        try Data("payload".utf8).write(to: source)
        XCTAssertEqual(try GTELargeSecurePath.validatedURLSessionTemporaryFile(source), source)
        #endif
    }

    func testSecureMoveRefusesToReplaceExistingEntry() throws {
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try Data("source".utf8).write(to: source)
        try Data("destination".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        XCTAssertThrowsError(try LocalGTELargeFileSystem().moveItem(at: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("destination".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
    }

    func testLiveProductionManifestDownloadsAndVerifiesAnonymously() async throws {
        #if !FOODMAPPER_RUN_LIVE_GTE_TEST
        try XCTSkipUnless(
            false,
            "Build with -DFOODMAPPER_RUN_LIVE_GTE_TEST to run the live 640 MiB download."
        )
        #endif
        let liveRoot = root.appendingPathComponent("live-production", isDirectory: true)
        let installer = GTELargeModelInstaller(
            rootDirectory: liveRoot,
            transport: URLSessionGTELargeDownloadTransport()
        )

        let directory = try await installer.install()
        XCTAssertEqual(directory, installer.installedDirectory)
        XCTAssertEqual(installer.availableDirectory(), installer.installedDirectory)
        for file in GTELargeModelManifest.current.files {
            let path = directory.appendingPathComponent(file.name)
            let identity = try GTELargeSecurePath.fileIdentity(at: path)
            XCTAssertEqual(identity.size, file.size)
            XCTAssertEqual(try GTELargeSecurePath.hashPrivateFile(at: path, expectedSize: file.size).0, file.sha256)
        }

        try await installer.deleteInstallArtifacts()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.installedDirectory.path))
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

    private func assertRecoveryRejectsExcessArtifacts(prefix: String, count: Int) async throws {
        let isolatedRoot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: isolatedRoot.path)
        let installer = GTELargeModelInstaller(
            rootDirectory: isolatedRoot,
            manifest: fixtureManifest,
            transport: FixtureTransport(files: fixtureFiles)
        )
        for _ in 0..<count {
            let artifact = isolatedRoot.appendingPathComponent("\(prefix)\(UUID().uuidString)")
            try Data("partial".utf8).write(to: artifact)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.path)
        }
        do {
            try await installer.recoverAtStartup()
            XCTFail("Expected bounded recovery to fail")
        } catch {
            XCTAssertTrue(error is GTELargeModelInstallError)
        }
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
        return GTELargeSecurePath.identity(from: value)
    }

    private var fixtureManifest: GTELargeModelManifest {
        GTELargeModelManifest(
            formatVersion: 1,
            repositoryID: "example/fixture",
            revision: "0123456789abcdef0123456789abcdef01234567",
            upstreamRepositoryID: "example/upstream",
            upstreamRevision: "0123456789abcdef0123456789abcdef01234567",
            upstreamLicense: "MIT",
            conversion: "fixture",
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

    func sha256(of url: URL, expectedSize: Int64) throws -> String {
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

    func sha256(of url: URL, expectedSize: Int64) throws -> String {
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

private final class FailingPromotionWriteFileSystem: GTELargeFileSystem, @unchecked Sendable {
    enum Failure: Equatable {
        case journal
        case current
        case postPointerSync
    }

    private let local = LocalGTELargeFileSystem()
    private let failure: Failure
    private let lock = NSLock()
    private var didFail = false
    private var pointerPublished = false

    init(failure: Failure) {
        self.failure = failure
    }

    func itemExists(at url: URL) -> Bool { local.itemExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) throws { try local.createDirectory(at: url, permissions: permissions) }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
    func removeItem(at url: URL, expectedFileIdentity: GTELargeFileIdentity) throws {
        try local.removeItem(at: url, expectedFileIdentity: expectedFileIdentity)
    }
    func removeItem(at url: URL, expectedDirectoryIdentity: GTELargeFileIdentity) throws {
        try local.removeItem(at: url, expectedDirectoryIdentity: expectedDirectoryIdentity)
    }
    func removePrivateTree(at url: URL, tree: GTELargePrivateTree, maximumDepth: Int) throws {
        try local.removePrivateTree(at: url, tree: tree, maximumDepth: maximumDepth)
    }
    func contentsOfDirectory(at url: URL, maximumEntries: Int) throws -> [URL] {
        try local.contentsOfDirectory(at: url, maximumEntries: maximumEntries)
    }
    func moveItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws {
        try failIfNeeded(source: source, destination: destination)
        try local.moveItem(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity)
    }
    func replaceFileAtomically(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws {
        try failIfNeeded(source: source, destination: destination)
        try local.replaceFileAtomically(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity)
    }
    func copyItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity, expectedSize: Int64) throws {
        try local.copyItem(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity, expectedSize: expectedSize)
    }
    func write(_ data: Data, to url: URL, permissions: Int) throws { try local.write(data, to: url, permissions: permissions) }
    func read(from url: URL, maximumSize: Int64) throws -> (Data, GTELargeFileIdentity) {
        try local.read(from: url, maximumSize: maximumSize)
    }
    func fileIdentity(at url: URL) throws -> GTELargeFileIdentity { try local.fileIdentity(at: url) }
    func directoryIdentity(at url: URL, requiredPermissions: Int?) throws -> GTELargeFileIdentity {
        try local.directoryIdentity(at: url, requiredPermissions: requiredPermissions)
    }
    func privateTree(at url: URL, maximumEntries: Int, maximumDepth: Int, maximumBytes: Int64) throws -> GTELargePrivateTree {
        try local.privateTree(at: url, maximumEntries: maximumEntries, maximumDepth: maximumDepth, maximumBytes: maximumBytes)
    }
    func setPermissions(_ permissions: Int, at url: URL) throws { try local.setPermissions(permissions, at: url) }
    func syncFile(at url: URL) throws { try local.syncFile(at: url) }
    func syncDirectory(at url: URL) throws {
        lock.lock()
        let shouldFail = failure == .postPointerSync && pointerPublished && !didFail
        if shouldFail { didFail = true }
        lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try local.syncDirectory(at: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try failIfNeeded(source: source, destination: destination)
        try local.moveItem(at: source, to: destination)
    }

    func moveItem(at source: URL, to destination: URL, expectedSourceDirectoryIdentity: GTELargeFileIdentity) throws {
        try failIfNeeded(source: source, destination: destination)
        try local.moveItem(
            at: source,
            to: destination,
            expectedSourceDirectoryIdentity: expectedSourceDirectoryIdentity
        )
    }

    private func failIfNeeded(source: URL, destination: URL) throws {
        let shouldFail: Bool
        switch failure {
        case .journal:
            shouldFail = source.lastPathComponent.hasPrefix(".gte-large-journal-") &&
                destination.lastPathComponent == ".gte-large-promotion.json"
        case .current:
            shouldFail = source.lastPathComponent.hasPrefix(".gte-large-current-") &&
                destination.lastPathComponent == "current.json"
        case .postPointerSync:
            shouldFail = false
        }
        if !shouldFail,
           failure == .postPointerSync,
           source.lastPathComponent.hasPrefix(".gte-large-current-") &&
           destination.lastPathComponent == "current.json" {
            lock.lock()
            pointerPublished = true
            lock.unlock()
        }
        guard shouldFail else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !didFail else { return }
        didFail = true
        throw CocoaError(.fileWriteUnknown)
    }
}

private struct FailingCommitFileSystem: GTELargeFileSystem {
    private let local = LocalGTELargeFileSystem()

    func itemExists(at url: URL) -> Bool { local.itemExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) throws { try local.createDirectory(at: url, permissions: permissions) }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
    func removeItem(at url: URL, expectedFileIdentity: GTELargeFileIdentity) throws {
        try local.removeItem(at: url, expectedFileIdentity: expectedFileIdentity)
    }
    func removeItem(at url: URL, expectedDirectoryIdentity: GTELargeFileIdentity) throws {
        try local.removeItem(at: url, expectedDirectoryIdentity: expectedDirectoryIdentity)
    }
    func removePrivateTree(at url: URL, tree: GTELargePrivateTree, maximumDepth: Int) throws {
        try local.removePrivateTree(at: url, tree: tree, maximumDepth: maximumDepth)
    }
    func contentsOfDirectory(at url: URL, maximumEntries: Int) throws -> [URL] {
        try local.contentsOfDirectory(at: url, maximumEntries: maximumEntries)
    }
    func moveItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws {
        if source.lastPathComponent.hasPrefix(".gte-large-staging-") && destination.lastPathComponent.hasPrefix("gte-large-") {
            throw CocoaError(.fileWriteUnknown)
        }
        try local.moveItem(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity)
    }
    func replaceFileAtomically(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws {
        try local.replaceFileAtomically(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity)
    }
    func copyItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity, expectedSize: Int64) throws {
        try local.copyItem(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity, expectedSize: expectedSize)
    }
    func write(_ data: Data, to url: URL, permissions: Int) throws { try local.write(data, to: url, permissions: permissions) }
    func read(from url: URL, maximumSize: Int64) throws -> (Data, GTELargeFileIdentity) {
        try local.read(from: url, maximumSize: maximumSize)
    }
    func fileIdentity(at url: URL) throws -> GTELargeFileIdentity { try local.fileIdentity(at: url) }
    func directoryIdentity(at url: URL, requiredPermissions: Int?) throws -> GTELargeFileIdentity {
        try local.directoryIdentity(at: url, requiredPermissions: requiredPermissions)
    }
    func privateTree(at url: URL, maximumEntries: Int, maximumDepth: Int, maximumBytes: Int64) throws -> GTELargePrivateTree {
        try local.privateTree(at: url, maximumEntries: maximumEntries, maximumDepth: maximumDepth, maximumBytes: maximumBytes)
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

    func moveItem(at source: URL, to destination: URL, expectedSourceDirectoryIdentity: GTELargeFileIdentity) throws {
        if source.lastPathComponent.hasPrefix(".gte-large-staging-") && destination.lastPathComponent.hasPrefix("gte-large-") {
            throw CocoaError(.fileWriteUnknown)
        }
        try local.moveItem(
            at: source,
            to: destination,
            expectedSourceDirectoryIdentity: expectedSourceDirectoryIdentity
        )
    }
}

private final class ReplacingPromotionSourceFileSystem: GTELargeFileSystem, @unchecked Sendable {
    private let local = LocalGTELargeFileSystem()
    private let lock = NSLock()
    private var replaced = false

    func itemExists(at url: URL) -> Bool { local.itemExists(at: url) }
    func createDirectory(at url: URL, permissions: Int) throws { try local.createDirectory(at: url, permissions: permissions) }
    func removeItem(at url: URL) throws { try local.removeItem(at: url) }
    func removeItem(at url: URL, expectedFileIdentity: GTELargeFileIdentity) throws {
        try local.removeItem(at: url, expectedFileIdentity: expectedFileIdentity)
    }
    func removeItem(at url: URL, expectedDirectoryIdentity: GTELargeFileIdentity) throws {
        try local.removeItem(at: url, expectedDirectoryIdentity: expectedDirectoryIdentity)
    }
    func removePrivateTree(at url: URL, tree: GTELargePrivateTree, maximumDepth: Int) throws {
        try local.removePrivateTree(at: url, tree: tree, maximumDepth: maximumDepth)
    }
    func contentsOfDirectory(at url: URL, maximumEntries: Int) throws -> [URL] {
        try local.contentsOfDirectory(at: url, maximumEntries: maximumEntries)
    }
    func moveItem(at source: URL, to destination: URL) throws {
        try replaceStagingIfNeeded(source: source, destination: destination)
        try local.moveItem(at: source, to: destination)
    }
    func moveItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws {
        try replaceStagingIfNeeded(source: source, destination: destination)
        try local.moveItem(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity)
    }
    func moveItem(at source: URL, to destination: URL, expectedSourceDirectoryIdentity: GTELargeFileIdentity) throws {
        try replaceStagingIfNeeded(source: source, destination: destination)
        try local.moveItem(at: source, to: destination, expectedSourceDirectoryIdentity: expectedSourceDirectoryIdentity)
    }
    func replaceFileAtomically(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity) throws {
        try local.replaceFileAtomically(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity)
    }
    func copyItem(at source: URL, to destination: URL, expectedSourceIdentity: GTELargeFileIdentity, expectedSize: Int64) throws {
        try local.copyItem(at: source, to: destination, expectedSourceIdentity: expectedSourceIdentity, expectedSize: expectedSize)
    }
    func write(_ data: Data, to url: URL, permissions: Int) throws { try local.write(data, to: url, permissions: permissions) }
    func read(from url: URL, maximumSize: Int64) throws -> (Data, GTELargeFileIdentity) {
        try local.read(from: url, maximumSize: maximumSize)
    }
    func fileIdentity(at url: URL) throws -> GTELargeFileIdentity { try local.fileIdentity(at: url) }
    func directoryIdentity(at url: URL, requiredPermissions: Int?) throws -> GTELargeFileIdentity {
        try local.directoryIdentity(at: url, requiredPermissions: requiredPermissions)
    }
    func privateTree(at url: URL, maximumEntries: Int, maximumDepth: Int, maximumBytes: Int64) throws -> GTELargePrivateTree {
        try local.privateTree(at: url, maximumEntries: maximumEntries, maximumDepth: maximumDepth, maximumBytes: maximumBytes)
    }
    func setPermissions(_ permissions: Int, at url: URL) throws { try local.setPermissions(permissions, at: url) }
    func syncFile(at url: URL) throws { try local.syncFile(at: url) }
    func syncDirectory(at url: URL) throws { try local.syncDirectory(at: url) }

    private func replaceStagingIfNeeded(source: URL, destination: URL) throws {
        guard source.lastPathComponent.hasPrefix(".gte-large-staging-"),
              destination.lastPathComponent.hasPrefix("gte-large-") else {
            return
        }
        lock.lock()
        let shouldReplace = !replaced
        replaced = true
        lock.unlock()
        guard shouldReplace else { return }

        let held = source.deletingLastPathComponent()
            .appendingPathComponent(".gte-large-unverified-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: held)
        try FileManager.default.copyItem(at: held, to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
    }
}
