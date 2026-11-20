import XCTest
@testable import Jarvis

/// No unit test reaches the eye tracker of a Jarvis.app running on the Mac,
/// so none can see, adopt or quit it, and none fails because it is there.
final class TrackerTestGuardTests: XCTestCase {
    func testUnitTestsNeverTalkToTheRealTrackerPort() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JARVIS_LIVE_TRACKER"] == "1",
                      "a live run has opted in to the tracker")
        XCTAssertTrue(TrackerTestGuard.blocksRealTracker)
        XCTAssertNotEqual(TrackerHost.apiPort, TrackerHost.port)
        XCTAssertNotEqual(GazeClient.defaultBaseURL.port, TrackerHost.port)
    }
}
