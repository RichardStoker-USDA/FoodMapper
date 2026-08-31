import Darwin
import XCTest
@testable import FoodMapper

@MainActor
final class StorageStartupTests: XCTestCase {
    override func setUpWithError() throws {
        try FoodMapperStorage.bootstrap()
    }

    private func makeScratchDirectory() throws -> URL {
        let directory = FoodMapperStorage.temporaryURL
            .appendingPathComponent("storage-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "app.foodmapper.FoodMapper.bootstrap.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    func testFailedBootstrapDoesNotInstallAndRepairCanRetry() throws {
        let root = try makeScratchDirectory()
        let temporaryRoot = root.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRoot.path)

        let blocked = root.appendingPathComponent("FoodMapper")
        XCTAssertEqual(blocked.path.withCString { mkfifo($0, 0o600) }, 0)

        let bootstrap = FoodMapperStorage.bootstrapForTesting(
            applicationSupportURL: root,
            processTemporaryRootURL: temporaryRoot,
            defaults: try makeDefaults()
        )

        XCTAssertThrowsError(try bootstrap.bootstrap())
        XCTAssertNil(bootstrap.valueIfReady)
        var before = stat()
        XCTAssertEqual(lstat(blocked.path, &before), 0)
        XCTAssertEqual(before.st_mode & S_IFMT, S_IFIFO)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Models").path))

        XCTAssertEqual(unlink(blocked.path), 0)
        let configuration = try bootstrap.bootstrap()
        XCTAssertEqual(configuration.applicationSupportURL, root)
        XCTAssertEqual(configuration.processTemporaryRootURL, temporaryRoot)
        XCTAssertEqual(configuration.temporaryURL, temporaryRoot.appendingPathComponent("FoodMapper"))
        XCTAssertNotNil(bootstrap.valueIfReady)
    }

    func testUnsafeTemporaryEntryRemainsUntouched() throws {
        let root = try makeScratchDirectory()
        let temporaryRoot = root.appendingPathComponent("temporary", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
        let blocked = temporaryRoot.appendingPathComponent("FoodMapper")
        try FileManager.default.createSymbolicLink(at: blocked, withDestinationURL: outside)

        let bootstrap = FoodMapperStorage.bootstrapForTesting(
            applicationSupportURL: root,
            processTemporaryRootURL: temporaryRoot,
            defaults: try makeDefaults()
        )

        XCTAssertThrowsError(try bootstrap.bootstrap())
        var after = stat()
        XCTAssertEqual(lstat(blocked.path, &after), 0)
        XCTAssertEqual(after.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: blocked.path), outside.path)
    }

    func testProcessTemporaryRootSymlinkRemainsUntouchedAndRetryRevalidates() throws {
        let root = try makeScratchDirectory()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let processRoot = root.appendingPathComponent("process", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: processRoot, withDestinationURL: outside)

        let bootstrap = FoodMapperStorage.bootstrapForTesting(
            applicationSupportURL: root,
            processTemporaryRootURL: processRoot,
            defaults: try makeDefaults()
        )

        XCTAssertThrowsError(try bootstrap.bootstrap())
        var before = stat()
        XCTAssertEqual(lstat(processRoot.path, &before), 0)
        XCTAssertEqual(before.st_mode & S_IFMT, S_IFLNK)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("FoodMapper").path))

        try FileManager.default.removeItem(at: processRoot)
        try FileManager.default.createDirectory(at: processRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: processRoot.path)
        let configuration = try bootstrap.bootstrap()
        XCTAssertEqual(configuration.processTemporaryRootURL, processRoot)
        XCTAssertEqual(configuration.temporaryURL, processRoot.appendingPathComponent("FoodMapper"))
    }

    func testOwnedLegacyDirectoriesMigrateWithoutChangingContents() throws {
        let root = try makeScratchDirectory()
        let temporaryRoot = root.appendingPathComponent("temporary", isDirectory: true)
        let sessions = root
            .appendingPathComponent("FoodMapper", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRoot.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessions.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sessions.deletingLastPathComponent().path
        )
        let file = sessions.appendingPathComponent("saved.json")
        let content = Data("saved session".utf8)
        try content.write(to: file)

        let bootstrap = FoodMapperStorage.bootstrapForTesting(
            applicationSupportURL: root,
            processTemporaryRootURL: temporaryRoot,
            defaults: try makeDefaults()
        )
        _ = try bootstrap.bootstrap()

        for directory in [sessions, sessions.deletingLastPathComponent()] {
            var info = stat()
            XCTAssertEqual(lstat(directory.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o700)
        }
        XCTAssertEqual(try Data(contentsOf: file), content)
    }

    func testRootReplacementFailsBeforeCreatingStorage() throws {
        let parent = try makeScratchDirectory()
        let root = parent.appendingPathComponent("support", isDirectory: true)
        let temporaryRoot = parent.appendingPathComponent("temporary", isDirectory: true)
        let displaced = parent.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporaryRoot.path)

        let bootstrap = FoodMapperStorage.bootstrapForTesting(
            applicationSupportURL: root,
            processTemporaryRootURL: temporaryRoot,
            defaults: try makeDefaults(),
            beforePrepare: {
                try FileManager.default.moveItem(at: root, to: displaced)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            }
        )

        XCTAssertThrowsError(try bootstrap.bootstrap())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("FoodMapper").path))
    }

    func testCoordinatorCanRetryAfterAFailedBootstrapClosure() {
        var attempts = 0
        let coordinator = FoodMapperStartupCoordinator {
            attempts += 1
            if attempts == 1 {
                throw FoodMapperStorage.StorageError.invalidPath
            }
        }

        XCTAssertEqual(coordinator.state, .checking)
        coordinator.start()
        XCTAssertEqual(coordinator.state, .failed)
        coordinator.retry()
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(attempts, 2)
    }
}
