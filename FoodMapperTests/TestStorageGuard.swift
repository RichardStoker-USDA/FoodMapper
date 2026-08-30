import XCTest
import Darwin
@testable import FoodMapper

final class TestStorageGuard: XCTestCase {
    override func setUpWithError() throws {
        try FoodMapperStorage.bootstrap()
    }

    private func configurationSignature(_ configuration: (root: URL, suite: String)?) -> String? {
        configuration.map { "\($0.root.path)|\($0.suite)" }
    }

    func testStorageConfigurationUsesOnlyTheIsolatedRoot() throws {
        let environment = ProcessInfo.processInfo.environment
        let suppliedRoot = try XCTUnwrap(environment["FOODMAPPER_TEST_STORAGE_ROOT"])
        let rootName = URL(fileURLWithPath: suppliedRoot, isDirectory: true).lastPathComponent
        let storagePrefix = "foodmapper-xctest-"
        let identifier = try XCTUnwrap(
            rootName.hasPrefix(storagePrefix) ? String(rootName.dropFirst(storagePrefix.count)) : nil
        )
        let expectedRoot = URL(
            fileURLWithPath: "/private/tmp/foodmapper-xctest-\(identifier)",
            isDirectory: true
        )
        let expectedSuite = "app.foodmapper.FoodMapper.tests.\(identifier)"
        let canonicalRoot = expectedRoot

        XCTAssertTrue(FoodMapperStorage.isIsolatedTestStorage)
        XCTAssertTrue(FoodMapperStorage.usesInMemoryCredentials)
        XCTAssertEqual(suppliedRoot, expectedRoot.path)
        XCTAssertEqual(FoodMapperStorage.applicationSupportURL, canonicalRoot)
        XCTAssertEqual(
            FoodMapperStorage.temporaryURL.standardizedFileURL,
            canonicalRoot.appendingPathComponent("Temporary", isDirectory: true).standardizedFileURL
        )
        XCTAssertEqual(
            FoodMapperStorage.processTemporaryRootURL.standardizedFileURL,
            FoodMapperStorage.temporaryURL.standardizedFileURL
        )
        XCTAssertEqual(environment["FOODMAPPER_TEST_DEFAULTS_SUITE"], expectedSuite)
        XCTAssertEqual(FoodMapperStorage.defaultsSuite, expectedSuite)
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

    func testTestConfigurationParserRejectsAmbiguousInputs() {
        let identifier = UUID().uuidString.lowercased()
        let otherIdentifier = UUID().uuidString.lowercased()
        let root = "/private/tmp/foodmapper-xctest-\(identifier)"
        let derivedRoot = "/private/tmp/foodmapper-derived-data-\(identifier)"
        let otherDerivedRoot = "/private/tmp/foodmapper-derived-data-\(otherIdentifier)"
        let suite = "app.foodmapper.FoodMapper.tests.\(identifier)"
        let expected = "\(root)|\(suite)"
        let fileManager = FileManager.default
        let markerRoots = [
            URL(fileURLWithPath: root, isDirectory: true),
            URL(fileURLWithPath: derivedRoot, isDirectory: true),
            URL(fileURLWithPath: otherDerivedRoot, isDirectory: true),
        ]
        for markerRoot in markerRoots {
            guard !fileManager.fileExists(atPath: markerRoot.path) else {
                XCTFail("Parser test root already exists: \(markerRoot.path)")
                return
            }
            do {
                try fileManager.createDirectory(at: markerRoot, withIntermediateDirectories: false)
            } catch {
                XCTFail("Unable to create parser test root: \(error)")
                return
            }
        }
        defer {
            for markerRoot in markerRoots {
                try? fileManager.removeItem(at: markerRoot)
            }
        }
        let markerPaths = [
            "\(root)/Temporary/run.xctestconfiguration",
            "\(derivedRoot)/Temporary/run.xctestconfiguration",
            "\(root)/Symroot/Debug/FoodMapperTests.xctest",
            "\(derivedRoot)/Logs/Test/run.xctestconfiguration",
            "\(derivedRoot)/Build/Products/FoodMapperTests.xctest",
            "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/PlugIns/FoodMapperTests.xctest",
            "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/MacOS/FoodMapper",
            "\(otherDerivedRoot)/Build/Products/FoodMapperTests.xctest",
        ]
        for markerPath in markerPaths {
            do {
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: markerPath, isDirectory: true),
                    withIntermediateDirectories: true
                )
            } catch {
                XCTFail("Unable to create parser marker: \(error)")
                return
            }
        }
        let markerAlias = URL(fileURLWithPath: "\(derivedRoot)/Alias", isDirectory: true)
        do {
            try fileManager.createSymbolicLink(
                at: markerAlias,
                withDestinationURL: URL(fileURLWithPath: "\(derivedRoot)/Logs", isDirectory: true)
            )
        } catch {
            XCTFail("Unable to create parser marker alias: \(error)")
            return
        }
        let vectors: [(String, [String: String], String?)] = [
            ("absent", [:], nil),
            (
                "partial root",
                ["FOODMAPPER_TEST_STORAGE_ROOT": root],
                nil
            ),
            (
                "partial root with marker",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "XCTestConfigurationFilePath": "\(derivedRoot)/Logs/Test/run.xctestconfiguration",
                ],
                nil
            ),
            (
                "partial suite",
                ["FOODMAPPER_TEST_DEFAULTS_SUITE": suite],
                nil
            ),
            (
                "partial suite with marker",
                [
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestConfigurationFilePath": "\(derivedRoot)/Logs/Test/run.xctestconfiguration",
                ],
                nil
            ),
            (
                "relative explicit root",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": "foodmapper-xctest-\(identifier)",
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                ],
                nil
            ),
            (
                "malformed explicit suite",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": "app.foodmapper.FoodMapper.tests.invalid",
                ],
                nil
            ),
            (
                "malformed explicit suite with marker",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": "app.foodmapper.FoodMapper.tests.invalid",
                    "XCTestConfigurationFilePath": "\(derivedRoot)/Logs/Test/run.xctestconfiguration",
                ],
                nil
            ),
            (
                "mismatched explicit suite",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": "app.foodmapper.FoodMapper.tests.\(otherIdentifier)",
                ],
                nil
            ),
            (
                "valid explicit pair",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                ],
                expected
            ),
            (
                "Xcode relative markers require an explicit pair",
                [
                    "XCTestBundlePath": "Contents/PlugIns/FoodMapperTests.xctest",
                    "XCTestConfigurationFilePath": "",
                ],
                nil
            ),
            (
                "explicit pair with Xcode relative markers",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestBundlePath": "Contents/PlugIns/FoodMapperTests.xctest",
                    "XCTestConfigurationFilePath": "",
                ],
                expected
            ),
            (
                "explicit pair with unknown relative marker",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestBundlePath": "PlugIns/OtherTests.xctest",
                ],
                nil
            ),
            (
                "absolute marker with relative marker requires explicit pair",
                [
                    "XCTestBundlePath": "Contents/PlugIns/FoodMapperTests.xctest",
                    "XCInjectBundle": "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/MacOS/FoodMapper",
                ],
                nil
            ),
            (
                "absolute marker with empty marker requires explicit pair",
                [
                    "XCTestBundlePath": "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/PlugIns/FoodMapperTests.xctest",
                    "XCTestConfigurationFilePath": "",
                ],
                nil
            ),
            (
                "explicit pair accepts matching absolute and neutral markers",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestBundlePath": "Contents/PlugIns/FoodMapperTests.xctest",
                    "XCInjectBundle": "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/MacOS/FoodMapper",
                    "XCTestConfigurationFilePath": "",
                ],
                expected
            ),
            (
                "explicit pair with matching marker",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestConfigurationFilePath": "\(derivedRoot)/Logs/Test/run.xctestconfiguration",
                ],
                expected
            ),
            (
                "explicit pair with storage-root XCTest configuration",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestConfigurationFilePath": "\(root)/Temporary/run.xctestconfiguration",
                ],
                nil
            ),
            (
                "actual wrapper temporary marker combination",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestBundlePath": "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/PlugIns/FoodMapperTests.xctest",
                    "XCInjectBundle": "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/MacOS/FoodMapper",
                    "XCTestConfigurationFilePath": "\(derivedRoot)/Temporary/run.xctestconfiguration",
                ],
                expected
            ),
            (
                "actual wrapper marker combination",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestBundlePath": "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/PlugIns/FoodMapperTests.xctest",
                    "XCInjectBundle": "\(derivedRoot)/Symroot/Debug/FoodMapper.app/Contents/MacOS/FoodMapper",
                    "XCTestConfigurationFilePath": "\(derivedRoot)/Logs/Test/run.xctestconfiguration",
                ],
                expected
            ),
            (
                "explicit pair with conflicting marker",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestConfigurationFilePath": "\(otherDerivedRoot)/Build/Products/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "xctest storage marker rejected",
                [
                    "XCTestBundlePath": "\(root)/Symroot/Debug/FoodMapper.app/Contents/PlugIns/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "valid derived-data marker",
                [
                    "XCTestConfigurationFilePath": "/private/tmp/foodmapper-derived-data-\(identifier)/Logs/Test/run.xctestconfiguration",
                ],
                expected
            ),
            (
                "valid /tmp marker alias",
                [
                    "XCTestBundlePath": "/tmp/foodmapper-derived-data-\(identifier)/Build/Products/FoodMapperTests.xctest",
                ],
                expected
            ),
            (
                "actual wrapper combination through /tmp alias",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": root,
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                    "XCTestBundlePath": "/tmp/foodmapper-derived-data-\(identifier)/Symroot/Debug/FoodMapper.app/Contents/PlugIns/FoodMapperTests.xctest",
                    "XCInjectBundle": "/tmp/foodmapper-derived-data-\(identifier)/Symroot/Debug/FoodMapper.app/Contents/MacOS/FoodMapper",
                    "XCTestConfigurationFilePath": "/tmp/foodmapper-derived-data-\(identifier)/Logs/Test/run.xctestconfiguration",
                ],
                expected
            ),
            (
                "conflicting markers",
                [
                    "XCTestConfigurationFilePath": "\(derivedRoot)/Logs/Test/run.xctestconfiguration",
                    "XCInjectBundle": "/private/tmp/foodmapper-derived-data-\(otherIdentifier)/Build/Products/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "spoofed user path",
                [
                    "XCTestBundlePath": "/Applications/untrusted/foodmapper-xctest-\(identifier)/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "spoofed nested tmp path",
                [
                    "XCTestBundlePath": "/private/tmp/untrusted/foodmapper-derived-data-\(identifier)/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "repeated slash marker",
                [
                    "XCTestBundlePath": "/private/tmp//foodmapper-derived-data-\(identifier)/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "repeated slash explicit root",
                [
                    "FOODMAPPER_TEST_STORAGE_ROOT": "/private/tmp//foodmapper-xctest-\(identifier)",
                    "FOODMAPPER_TEST_DEFAULTS_SUITE": suite,
                ],
                nil
            ),
            (
                "spoofed nested /tmp path",
                [
                    "XCTestBundlePath": "/tmp/untrusted/foodmapper-derived-data-\(identifier)/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "other temporary alias",
                [
                    "XCTestBundlePath": "/var/tmp/foodmapper-derived-data-\(identifier)/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "tmp storage marker rejected",
                [
                    "XCTestBundlePath": "/tmp/foodmapper-xctest-\(identifier)/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "case aliased tmp path",
                [
                    "XCTestBundlePath": "/Private/tmp/foodmapper-derived-data-\(identifier)/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "parent traversal alias",
                [
                    "XCTestBundlePath": "/private/tmp/untrusted/../foodmapper-derived-data-\(identifier)/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "malformed marker UUID",
                [
                    "XCTestBundlePath": "/private/tmp/foodmapper-derived-data-not-a-uuid/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "marker suffix",
                [
                    "XCTestBundlePath": "/private/tmp/foodmapper-derived-data-\(identifier)-suffix/FoodMapperTests.xctest",
                ],
                nil
            ),
            (
                "marker symlink alias",
                [
                    "XCTestConfigurationFilePath": "\(derivedRoot)/Alias/Test/run.xctestconfiguration",
                ],
                nil
            ),
            (
                "unknown marker path",
                [
                    "XCTestConfigurationFilePath": "/private/var/folders/test/FoodMapperTests.xctestconfiguration",
                ],
                nil
            ),
        ]

        for (name, environment, expectedSignature) in vectors {
            XCTAssertEqual(
                configurationSignature(FoodMapperStorage.expectedTestConfiguration(environment: environment)),
                expectedSignature,
                name
            )
        }
    }

    func testDirectoryOwnershipValidatorRejectsNonOwnerAndSpecialType() {
        let currentUser = getuid()
        let otherUser: uid_t = currentUser == 0 ? 1 : 0
        let privateDirectoryMode = mode_t(S_IFDIR) | mode_t(0o755)
        let specialFileMode = mode_t(S_IFIFO) | mode_t(0o600)

        XCTAssertTrue(
            FoodMapperStorage.isOwnedDirectory(
                mode: privateDirectoryMode,
                owner: currentUser,
                currentUser: currentUser
            )
        )
        XCTAssertFalse(
            FoodMapperStorage.isOwnedDirectory(
                mode: privateDirectoryMode,
                owner: otherUser,
                currentUser: currentUser
            )
        )
        XCTAssertFalse(
            FoodMapperStorage.isOwnedDirectory(
                mode: specialFileMode,
                owner: currentUser,
                currentUser: currentUser
            )
        )
    }

    func testKnownDirectoriesNormalizePermissionsAndPreserveFiles() throws {
        let directory = try FoodMapperStorage.preparePrivateDirectory(["Sessions"])
        let file = directory.appendingPathComponent("legacy-preserved-\(UUID().uuidString).json")
        let original = Data("existing session data".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        try FoodMapperStorage.preparePrivateStorage()
        try FoodMapperStorage.preparePrivateStorage()

        let reopened = try FoodMapperStorage.preparePrivateDirectory(["Sessions"])
        var info = stat()
        XCTAssertEqual(lstat(reopened.path, &info), 0)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue, 0o644)
    }

    func testFixedDirectoryRefusesSpecialFileWithoutMutation() throws {
        let fileManager = FileManager.default
        let foodMapperDirectory = FoodMapperStorage.applicationSupportURL
            .appendingPathComponent("FoodMapper", isDirectory: true)
        let fixedDirectory = foodMapperDirectory
            .appendingPathComponent("CustomDBs", isDirectory: true)
        let savedDirectory = foodMapperDirectory
            .appendingPathComponent("CustomDBs-staged-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(fileManager.fileExists(atPath: savedDirectory.path))
        try fileManager.moveItem(at: fixedDirectory, to: savedDirectory)
        var specialCreated = false
        defer {
            if specialCreated {
                _ = fixedDirectory.path.withCString { unlink($0) }
            }
            try? fileManager.moveItem(at: savedDirectory, to: fixedDirectory)
        }

        guard fixedDirectory.path.withCString({ mkfifo($0, mode_t(0o600)) }) == 0 else {
            throw NSError(domain: "TestStorageGuard", code: Int(errno))
        }
        specialCreated = true
        var before = stat()
        XCTAssertEqual(lstat(fixedDirectory.path, &before), 0)
        XCTAssertEqual(before.st_mode & S_IFMT, S_IFIFO)

        XCTAssertThrowsError(try FoodMapperStorage.preparePrivateStorage())

        var after = stat()
        XCTAssertEqual(lstat(fixedDirectory.path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mode, before.st_mode)
        XCTAssertEqual(after.st_uid, before.st_uid)
        XCTAssertEqual(after.st_size, before.st_size)
    }

    func testPrivateDirectoryRefusesSymlinkAndRegularFile() throws {
        let directory = try FoodMapperStorage.preparePrivateDirectory(["Sessions", "Refusal"])
        let outside = FoodMapperStorage.temporaryURL.appendingPathComponent("refusal-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let marker = outside.appendingPathComponent("marker")
        let original = Data("outside".utf8)
        try original.write(to: marker)

        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(
            try FoodMapperStorage.preparePrivateDirectory(["Sessions", "Refusal", "link"])
        )
        var linkInfo = stat()
        XCTAssertEqual(lstat(link.path, &linkInfo), 0)
        XCTAssertEqual(linkInfo.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: marker), original)

        let regular = directory.appendingPathComponent("regular")
        try original.write(to: regular)
        XCTAssertThrowsError(
            try FoodMapperStorage.preparePrivateDirectory(["Sessions", "Refusal", "regular"])
        )
        XCTAssertEqual(try Data(contentsOf: regular), original)
    }
}
