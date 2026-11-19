import XCTest
@testable import Jarvis

/// Contract: the first Jarvis launch carries over preferences, the old
/// Application Support folder and stored API keys, and never overwrites
/// anything Jarvis already has.
final class LegacyMigrationTests: XCTestCase {
    private final class Keys: APIKeyStore {
        var value: String?
        init(_ value: String?) { self.value = value }
        func read() throws -> String? { value }
        func save(_ apiKey: String) throws { value = apiKey }
        func delete() throws { value = nil }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func defaults() -> UserDefaults {
        let name = "legacy-migration-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testMovesFolderCopiesMissingPreferencesAndKeys() throws {
        let support = try temporaryDirectory()
        let legacy = support.appendingPathComponent(LegacyMigration.legacySupportFolder)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("calibration".utf8).write(to: legacy.appendingPathComponent("calibration.json"))
        let store = defaults()
        store.set(true, forKey: "handsFreeEnabled")
        let oldKey = Keys("sk-old"), newKey = Keys(nil), keptOld = Keys("old"), keptNew = Keys("new")

        LegacyMigration.run(defaults: store,
                            legacyDefaults: ["handsFreeEnabled": false, "trackerCameraFovDeg": 87],
                            applicationSupport: support,
                            keys: [(oldKey, newKey), (keptOld, keptNew)])

        let moved = support.appendingPathComponent(LegacyMigration.supportFolder)
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("calibration.json"), encoding: .utf8),
                       "calibration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(store.bool(forKey: "handsFreeEnabled"))
        XCTAssertEqual(store.integer(forKey: "trackerCameraFovDeg"), 87)
        XCTAssertEqual(newKey.value, "sk-old")
        XCTAssertEqual(oldKey.value, "sk-old")
        XCTAssertEqual(keptNew.value, "new")
    }

    func testExistingJarvisFolderIsNeverReplaced() throws {
        let support = try temporaryDirectory()
        let legacy = support.appendingPathComponent(LegacyMigration.legacySupportFolder)
        let current = support.appendingPathComponent(LegacyMigration.supportFolder)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: current.appendingPathComponent("marker"))

        LegacyMigration.run(defaults: defaults(), legacyDefaults: nil, applicationSupport: support, keys: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8), "new")
    }

    func testRunOnceIsRecordedAndNotRepeated() {
        let store = defaults()
        store.set(true, forKey: LegacyMigration.doneKey)
        LegacyMigration.runOnce(defaults: store)
        XCTAssertTrue(store.bool(forKey: LegacyMigration.doneKey))
    }
}
