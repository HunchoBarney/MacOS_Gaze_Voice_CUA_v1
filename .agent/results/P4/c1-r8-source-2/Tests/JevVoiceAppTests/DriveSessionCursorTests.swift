import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: the session label a dispatch rides decides whether the
/// driver draws an agent cursor for it. Direct fast-lane actions —
/// user-initiated one-shots — run under `voice-direct`, the cursorless
/// session; model rounds keep the caller's session; gaze work is
/// `voice-gaze`. The predicate's hyphen boundary is what keeps a rotated
/// successor ("voice-gaze-3") cursorless and a coincidental prefix
/// ("voice-gazer") visible.
final class DriveSessionCursorTests: XCTestCase {

    func testDirectSessionLabelsFastLaneDispatch() async {
        let driver = DriveLoopTests.FakeDriver()
        driver.responses["list_windows"] = [.object(["windows": .array([
            .object(["window_id": .number(7), "pid": .number(42), "title": .string("Fixture")])
        ])])]
        driver.responses["list_apps"] = [
            .object(["apps": .array([
                .object(["name": .string("Safari"),
                         "bundle_id": .string("com.apple.Safari"),
                         "pid": .number(42)])])])
        ]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in XCTFail("An explicit key must not need inference"); return nil }, ask: nil,
                             granted: { true },
                             directSession: "voice-direct",
                             resolver: AppResolver(listApps: {
                                 [AppResolver.App(name: "Safari",
                                                  bundle: "com.apple.Safari", pid: 42)] }),
                             frontmostBundleID: { "com.apple.Safari" })
        _ = await loop.run(
            DriveTask(goal: "press escape", application: "com.apple.Safari", pid: 42, windowID: 7),
            session: "voice")
        let keys = driver.calls.filter { $0.tool == "hotkey" }
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.args["session"], .string("voice-direct"),
                       "a direct dispatch must not ride the model session")
    }

    /// No direct session wired → the caller's session label carries the
    /// dispatch, same as before the split existed.
    func testNoDirectSessionKeepsCallerLabel() async {
        let driver = DriveLoopTests.FakeDriver()
        driver.responses["list_windows"] = [.object(["windows": .array([
            .object(["window_id": .number(7), "pid": .number(42), "title": .string("Fixture")])
        ])])]
        driver.responses["list_apps"] = [
            .object(["apps": .array([
                .object(["name": .string("Safari"),
                         "bundle_id": .string("com.apple.Safari"),
                         "pid": .number(42)])])])
        ]
        let loop = DriveLoop(call: { t, a in try driver.call(t, a) },
                             choose: { _, _ in XCTFail("An explicit key must not need inference"); return nil }, ask: nil,
                             granted: { true },
                             resolver: AppResolver(listApps: {
                                 [AppResolver.App(name: "Safari",
                                                  bundle: "com.apple.Safari", pid: 42)] }),
                             frontmostBundleID: { "com.apple.Safari" })
        _ = await loop.run(
            DriveTask(goal: "press escape", application: "com.apple.Safari", pid: 42, windowID: 7),
            session: "agent-scout")
        let keys = driver.calls.filter { $0.tool == "hotkey" }
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.args["session"], .string("agent-scout"),
                       "agent loops keep their own session label")
    }
}
