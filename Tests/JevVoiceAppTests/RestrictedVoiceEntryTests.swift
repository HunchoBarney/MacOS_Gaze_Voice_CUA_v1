import AppKit
import XCTest
@testable import JevVoice

final class RestrictedVoiceEntryTests: XCTestCase {
    func testOnlyExactProfileWithoutAlternateEntriesOrOverridesIsAdmitted() {
        let marker = RestrictedVoiceEntry.marker
        XCTAssertTrue(RestrictedVoiceEntry.accepts(marker: marker, arguments: [], environmentKeys: ["PATH", "LANG"]))
        for wrong: Any? in [nil, true, "retinaface-v1", ""] {
            XCTAssertFalse(RestrictedVoiceEntry.accepts(marker: wrong, arguments: [], environmentKeys: []))
        }
        for argument in ["--settings", "--mcp-stdio", "--p3-live", "--c1-no-fn-trace", "-gazeTracking"] {
            XCTAssertFalse(RestrictedVoiceEntry.accepts(marker: marker, arguments: [argument], environmentKeys: []))
        }
        for key in ["JARVIS_EYE_TRACKER_DIR", "CUA_HOME", "OPENAI_API_KEY", "TYPESAFE_API_KEY",
                    "CODEX_HOME", "DYLD_INSERT_LIBRARIES", "http_proxy", "JEV_SPEECH_PACKAGE"] {
            XCTAssertFalse(RestrictedVoiceEntry.accepts(marker: marker, arguments: [], environmentKeys: [key]))
        }
    }

    func testUnobservedConsoleOrLockCannotAuthorizeInput() {
        var state: [String: Any] = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
        XCTAssertFalse(RestrictedVoiceEntry.consoleAvailable(nil, protectedDataAvailable: true))
        XCTAssertFalse(RestrictedVoiceEntry.consoleAvailable(state, protectedDataAvailable: true))
        for locked: Any in [true, "unknown"] {
            state["CGSSessionScreenIsLocked"] = locked
            XCTAssertFalse(RestrictedVoiceEntry.consoleAvailable(state, protectedDataAvailable: true))
        }
        state["CGSSessionScreenIsLocked"] = false
        XCTAssertTrue(RestrictedVoiceEntry.consoleAvailable(state, protectedDataAvailable: true))
        XCTAssertFalse(RestrictedVoiceEntry.consoleAvailable(state, protectedDataAvailable: false))
        state[kCGSessionOnConsoleKey as String] = false
        XCTAssertFalse(RestrictedVoiceEntry.consoleAvailable(state, protectedDataAvailable: true))
    }
}
