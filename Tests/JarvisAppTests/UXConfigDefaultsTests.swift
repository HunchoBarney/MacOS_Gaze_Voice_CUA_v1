import XCTest
@testable import Jarvis

/// The UX lane's Config flags: defaults and persistence round-trips.
/// Matches the spec — tap-to-gaze-click and local STT on, the two
/// pending-pilot flags off.
final class UXConfigDefaultsTests: XCTestCase {

    /// In-memory key store — Config's init probes the store; tests never
    /// touch the real Keychain.
    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func config(defaults: UserDefaults) -> Config {
        Config(defaults: defaults, keyStore: MemoryKeys(),
               openAIKeyStore: MemoryKeys(), environment: [:])
    }

    func testHandsFreeDefaultsOffAndExplicitChoiceOrPauseSurvivesReload() {
        let defaults = UserDefaults(suiteName: "hands-free-default-\(UUID())")!
        let initial = config(defaults: defaults)
        XCTAssertFalse(initial.handsFreeEnabled)
        XCTAssertFalse(initial.handsFreePaused)
        initial.handsFreeEnabled = true
        initial.handsFreePaused = true
        XCTAssertTrue(config(defaults: defaults).handsFreePaused)
        XCTAssertTrue(config(defaults: defaults).handsFreeEnabled)
        initial.handsFreeEnabled = false
        XCTAssertFalse(config(defaults: defaults).handsFreeEnabled)
        initial.handsFreePaused = false
        XCTAssertFalse(config(defaults: defaults).handsFreePaused)
    }

    func testSemanticAssistIsEnabledWhenPreferenceIsUnset() {
        let defaults = UserDefaults(suiteName: "semantic-default-\(UUID())")!
        XCTAssertNil(defaults.object(forKey: "semanticAppSuggestions"))
        XCTAssertTrue(config(defaults: defaults).semanticAppSuggestions)
    }

    func testSemanticAssistExplicitOptOutPersistsAcrossReloads() {
        let defaults = UserDefaults(suiteName: "semantic-optout-\(UUID())")!
        defaults.set(false, forKey: "semanticAppSuggestions")
        let c = config(defaults: defaults)
        XCTAssertFalse(c.semanticAppSuggestions)
        c.semanticAppSuggestions = true
        XCTAssertTrue(config(defaults: defaults).semanticAppSuggestions)
        c.semanticAppSuggestions = false
        XCTAssertFalse(config(defaults: defaults).semanticAppSuggestions)
    }

    @MainActor
    func testRetiredFlagsCannotTurnOffFinalOnlyAdmission() async {
        let defaults = UserDefaults(suiteName: "retired-flags-\(UUID().uuidString)")!
        defaults.set(false, forKey: "localSTTEnabled")
        defaults.set(true, forKey: "commandSpottingEnabled")
        defaults.set(true, forKey: "localChooserEnabled")
        _ = config(defaults: defaults)
        var calls = 0
        let session = LocalSpeechSession { _ in calls += 1 }
        session.context.targetID = "fixture"
        let turn = session.begin(mode: .typed, ready: true, now: 0)
        session.partial("scroll down", turn: turn)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(session.release(turn, now: 1))
        _ = await session.finalize("scroll down", turn: turn, drainedFrames: 0, now: 1.1)
        XCTAssertEqual(calls, 1)
    }
}
