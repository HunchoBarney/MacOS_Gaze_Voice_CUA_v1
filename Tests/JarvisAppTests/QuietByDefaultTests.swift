import XCTest
@testable import Jarvis

/// Jarvis is always listening, so it is quiet by default: no chime unless
/// Settings → Replies → Sounds is turned on, and installs that had sounds
/// on are moved to off once.
@MainActor
final class QuietByDefaultTests: XCTestCase {
    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func config(_ defaults: UserDefaults) -> Config {
        Config(defaults: defaults, keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
    }

    private func suite() -> UserDefaults {
        let name = "quiet-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testFreshInstallIsSilent() {
        XCTAssertFalse(config(suite()).sounds)
    }

    func testInstallWithSoundsOnIsMovedToOffOnce() {
        let defaults = suite()
        defaults.set(true, forKey: "soundsEnabled")
        XCTAssertFalse(config(defaults).sounds)
        XCTAssertFalse(defaults.bool(forKey: "soundsEnabled"))

        config(defaults).sounds = true
        XCTAssertTrue(config(defaults).sounds, "turning Sounds back on sticks after the one-time move")
    }

    func testTurningSoundsOffSticks() {
        let defaults = suite()
        config(defaults).sounds = true
        config(defaults).sounds = false
        XCTAssertFalse(config(defaults).sounds)
    }
}
