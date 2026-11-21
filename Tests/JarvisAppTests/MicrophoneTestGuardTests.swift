import XCTest
@testable import Jarvis

/// No unit test reaches the Mac's microphone, whatever the person has
/// granted the app that launched the tests (Capy, Terminal, launchd).
@MainActor
final class MicrophoneTestGuardTests: XCTestCase {
    func testUnitTestsNeverSeeOrOpenTheRealMicrophone() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JARVIS_LIVE_MIC"] == "1",
                      "a live run has opted in to the microphone")
        XCTAssertTrue(MicrophoneTestGuard.blocksRealMicrophone)
        XCTAssertFalse(Permission.microphone.isGranted)
        XCTAssertFalse(Permission.microphone.canPrompt)
        XCTAssertEqual(FirstRunModel.systemMicrophoneGrant(), .refused)
        let device = MicrophoneDevice(hardwareID: 0, uid: "", name: "Built-in")
        do {
            _ = try await MicrophoneInput().prepare(device: device, interrupted: {})
            XCTFail("a unit test opened the microphone")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("JARVIS_LIVE_MIC=1"))
        }
    }

    func testOnlyALiveRunOptsIn() {
        XCTAssertTrue(MicrophoneTestGuard.runningTests(hasXCTest: true, environment: [:]))
        XCTAssertTrue(MicrophoneTestGuard.runningTests(hasXCTest: true, environment: ["JARVIS_LIVE_MIC": "true"]))
        XCTAssertFalse(MicrophoneTestGuard.runningTests(hasXCTest: true, environment: ["JARVIS_LIVE_MIC": "1"]))
        XCTAssertFalse(MicrophoneTestGuard.runningTests(hasXCTest: false, environment: [:]))
    }
}
