import XCTest
import Darwin
@testable import FoodMapper

final class TestStorageGuard: XCTestCase {
    func testStorageConfigurationUsesOnlyTheIsolatedRoot() throws {
        let environment = ProcessInfo.processInfo.environment
        let expectedRoot = try XCTUnwrap(environment["FOODMAPPER_TEST_STORAGE_ROOT"])
        let expectedSuite = try XCTUnwrap(environment["FOODMAPPER_TEST_DEFAULTS_SUITE"])

        XCTAssertTrue(FoodMapperStorage.isIsolatedTestStorage)
        XCTAssertTrue(FoodMapperStorage.usesInMemoryCredentials)
        XCTAssertEqual(FoodMapperStorage.applicationSupportURL.path, expectedRoot)
        XCTAssertEqual(FoodMapperStorage.defaultsSuite, expectedSuite)
        XCTAssertNotEqual(FoodMapperStorage.applicationSupportURL, FoodMapperStorage.liveApplicationSupportURL)
        XCTAssertTrue(FoodMapperStorage.temporaryURL.path.hasPrefix(expectedRoot + "/"))

        var info = stat()
        XCTAssertEqual(lstat(expectedRoot, &info), 0)
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
