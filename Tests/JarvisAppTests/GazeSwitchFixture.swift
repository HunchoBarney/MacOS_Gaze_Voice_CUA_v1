import XCTest
@testable import Jarvis

extension XCTestCase {
    /// Turns eye tracking on for this test only. The live switch reads
    /// `gazeTracking` from `UserDefaults.standard`, which every test
    /// process on the Mac shares and other tests flip, so a gaze test that
    /// relied on it would pass or fail with whatever another run left there.
    func useGazeTrackingOn() {
        let saved = DriveLoop.gazeEnabled
        DriveLoop.gazeEnabled = { true }
        addTeardownBlock { DriveLoop.gazeEnabled = saved }
    }
}
