import XCTest
@testable import Jarvis

/// `voice.live` gates the hands-free GPT-Live work until L11: off by
/// default, and a stored choice survives a reload.
final class VoiceLiveFlagTests: XCTestCase {
    private struct NoKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func config(_ defaults: UserDefaults) -> Config {
        Config(defaults: defaults, keyStore: NoKeys(), openAIKeyStore: NoKeys(), environment: [:])
    }

    func testVoiceLiveDefaultsOffAndPersistsUnderItsKey() {
        let defaults = UserDefaults(suiteName: "voice-live-\(UUID().uuidString)")!
        XCTAssertFalse(config(defaults).voiceLive)

        config(defaults).voiceLive = true
        XCTAssertTrue(defaults.bool(forKey: "voice.live"))
        XCTAssertTrue(config(defaults).voiceLive)

        config(defaults).voiceLive = false
        XCTAssertFalse(config(defaults).voiceLive)
    }
}
