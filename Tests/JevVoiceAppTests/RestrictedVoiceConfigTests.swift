import XCTest
@testable import JevVoice

final class RestrictedVoiceConfigTests: XCTestCase {
    func testOnlyVoicePreferencesAreReadOrPersisted() {
        var reads: [Config.VoicePreference] = []
        var writes: [Config.VoicePreference] = []
        var values: [Config.VoicePreference: Any] = [
            .microphoneUID: "fixture-input", .handsFreeEnabled: false, .handsFreePaused: true
        ]
        let config = Config.restrictedVoice(
            readPreference: { reads.append($0); return values[$0] },
            writePreference: { writes.append($0); values[$0] = $1 },
            readRealtimeKey: { XCTFail("Unexpected credential read"); return nil }
        )
        XCTAssertEqual(reads, [.microphoneUID, .handsFreeEnabled, .handsFreePaused])
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(config.isRestrictedVoice)
        XCTAssertEqual(config.microphoneUID, "fixture-input")
        XCTAssertFalse(config.handsFreeEnabled)
        XCTAssertTrue(config.handsFreePaused)
        XCTAssertFalse(config.gazeTracking)
        XCTAssertFalse(config.alwaysAllowComputerUse)
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertFalse(config.codexAuth.binaryAvailable)
        XCTAssertFalse(config.canSaveAPIKey("fixture"))
        XCTAssertFalse(config.saveAPIKey("fixture"))
        XCTAssertFalse(config.saveOpenAIAPIKey(""))
        XCTAssertEqual(config.retryAPIKeyAccess(keeping: "draft"), "draft")
        config.gazeTracking = true
        config.launchAtLogin = true
        config.microphoneUID = "other-fixture-input"
        config.handsFreeEnabled = true
        config.handsFreePaused = false
        XCTAssertEqual(writes, [.microphoneUID, .handsFreeEnabled, .handsFreePaused])
        XCTAssertEqual(values[.microphoneUID] as? String, "other-fixture-input")
        XCTAssertEqual(values[.handsFreeEnabled] as? Bool, true)
        XCTAssertEqual(values[.handsFreePaused] as? Bool, false)
    }

    func testOnlyExplicitConnectionReadUsesTheCredentialWithoutPublishingOrCachingIt() {
        var reads = 0
        let config = Config.restrictedVoice(
            readPreference: { _ in nil },
            writePreference: { _, _ in XCTFail("Unexpected preference write") },
            readRealtimeKey: { reads += 1; return reads == 1 ? "fixture" : nil }
        )
        let connectionKey = config.restrictedRealtimeKey
        XCTAssertTrue(config.environment.isEmpty)
        XCTAssertTrue(config.handsFreeEnabled)
        XCTAssertFalse(config.handsFreePaused)
        XCTAssertTrue(config.apiKey.isEmpty)
        XCTAssertTrue(config.openAIAPIKey.isEmpty)
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(connectionKey() == "fixture")
        XCTAssertTrue(connectionKey().isEmpty)
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(config.openAIAPIKey.isEmpty)
    }

    func testMissingPermissionReaderChecksBothVoiceGrantsAndNothingElseOnEveryRead() {
        let cases: [[Permission]] = [[], [.microphone], [.accessibility], [.microphone, .accessibility]]
        for missing in cases {
            var checked: [Permission] = []
            let observed = Permission.restrictedVoiceMissing { permission in
                checked.append(permission)
                return !missing.contains(permission)
            }
            XCTAssertEqual(checked, [.microphone, .accessibility])
            XCTAssertEqual(observed, missing)
        }
    }
}
