import XCTest
@testable import PastePal

final class AppStorageMigrationTests: XCTestCase {
    private var root: URL!
    private var oldDomain: String!
    private var newDomain: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PastePalMigrationTests-\(UUID().uuidString)", isDirectory: true)
        oldDomain = "PastePalMigrationTests.old.\(UUID().uuidString)"
        newDomain = "PastePalMigrationTests.new.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: oldDomain)
        UserDefaults.standard.removePersistentDomain(forName: newDomain)
        try? FileManager.default.removeItem(at: root)
    }

    private func migration(
        copyDirectory: @escaping (FileManager, URL, URL) throws -> Void = { manager, source, destination in
            try manager.copyItem(at: source, to: destination)
        }
    ) -> AppStorageMigration {
        AppStorageMigration(
            applicationSupportDirectory: root,
            oldPreferencesDomain: oldDomain,
            newPreferencesDomain: newDomain,
            copyDirectory: copyDirectory
        )
    }

    private func write(_ value: String, to directory: String, name: String = "history.sqlite") throws {
        let target = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: target.appendingPathComponent(name))
    }

    func testMigratesDataAndPreferencesWhileKeepingOldBackup() throws {
        try write("old-history", to: "MacClipboard")
        try write("old-image", to: "MacClipboard", name: "image.png")
        let settings: [String: Any] = ["historyLimit": 321, "paused": true]
        UserDefaults.standard.setPersistentDomain(settings, forName: oldDomain)

        let report = try migration().run()

        XCTAssertEqual(report, .init(data: .migrated, preferences: .migrated))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("PastePal/history.sqlite")), Data("old-history".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("PastePal/image.png")), Data("old-image".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("MacClipboard/history.sqlite").path))
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: newDomain)?["historyLimit"] as? Int, 321)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: newDomain)?["paused"] as? Bool, true)
        XCTAssertNotNil(UserDefaults.standard.persistentDomain(forName: oldDomain))
    }

    func testDoesNotOverwriteExistingNewDataOrPreferences() throws {
        try write("old-history", to: "MacClipboard")
        try write("new-history", to: "PastePal")
        UserDefaults.standard.setPersistentDomain(["historyLimit": 321, "paused": true], forName: oldDomain)
        UserDefaults.standard.setPersistentDomain(["historyLimit": 88], forName: newDomain)

        let report = try migration().run()

        XCTAssertEqual(report, .init(data: .destinationPreserved, preferences: .migrated))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("PastePal/history.sqlite")), Data("new-history".utf8))
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: newDomain)?["historyLimit"] as? Int, 88)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: newDomain)?["paused"] as? Bool, true)
    }

    func testRepeatedMigrationIsIdempotent() throws {
        try write("old-history", to: "MacClipboard")
        UserDefaults.standard.setPersistentDomain(["directPaste": true], forName: oldDomain)
        XCTAssertEqual(try migration().run(), .init(data: .migrated, preferences: .migrated))

        XCTAssertEqual(try migration().run(), .init(data: .destinationPreserved, preferences: .destinationPreserved))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("PastePal/history.sqlite")), Data("old-history".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("MacClipboard/history.sqlite").path))
    }

    func testCopyFailureLeavesOldDataAndCanRecover() throws {
        try write("old-history", to: "MacClipboard")
        struct SyntheticFailure: Error {}
        let failing = migration { manager, _, destination in
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("partial".utf8).write(to: destination.appendingPathComponent("history.sqlite"))
            throw SyntheticFailure()
        }

        XCTAssertThrowsError(try failing.run())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("MacClipboard/history.sqlite")), Data("old-history".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("PastePal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".PastePal.migration-staging").path))

        XCTAssertEqual(try migration().run().data, .migrated)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("PastePal/history.sqlite")), Data("old-history".utf8))
    }
}
