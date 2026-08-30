import XCTest
import Darwin
@testable import FoodMapper

final class TestStorageGuard: XCTestCase {
    func testStorageConfigurationUsesOnlyTheIsolatedRoot() throws {
        let environment = ProcessInfo.processInfo.environment
        let expected = try XCTUnwrap(FoodMapperStorage.expectedTestConfiguration(environment: environment))
        let canonicalRoot = expected.root
            .resolvingSymlinksInPath()
            .standardizedFileURL

        XCTAssertTrue(FoodMapperStorage.isIsolatedTestStorage)
        XCTAssertTrue(FoodMapperStorage.usesInMemoryCredentials)
        XCTAssertEqual(FoodMapperStorage.applicationSupportURL, canonicalRoot)
        XCTAssertEqual(
            FoodMapperStorage.temporaryURL.standardizedFileURL,
            canonicalRoot.appendingPathComponent("Temporary", isDirectory: true).standardizedFileURL
        )
        XCTAssertEqual(FoodMapperStorage.defaultsSuite, expected.suite)
        XCTAssertFalse(FoodMapperStorage.defaults === UserDefaults.standard)
        XCTAssertNotEqual(FoodMapperStorage.applicationSupportURL, FoodMapperStorage.liveApplicationSupportURL)
        XCTAssertTrue(FoodMapperStorage.temporaryURL.path.hasPrefix(canonicalRoot.path + "/"))

        var info = stat()
        XCTAssertEqual(lstat(canonicalRoot.path, &info), 0)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
    }

    func testDefaultsUseTheConfiguredSuite() throws {
        let key = "test-storage-guard-\(UUID().uuidString)"
        FoodMapperStorage.defaults.set(true, forKey: key)
        defer { FoodMapperStorage.defaults.removeObject(forKey: key) }
        XCTAssertTrue(FoodMapperStorage.defaults.bool(forKey: key))
    }
}
