import XCTest
@testable import JevVoice

final class LaunchCorrectionTests: XCTestCase {
    func testNewLaunchQuitsNormallyButExistingSessionOnlyRestoresFocus() {
        XCTAssertEqual(LaunchReversalPolicy.effect(wasRunning: false, unchanged: true), .requestQuit)
        XCTAssertEqual(LaunchReversalPolicy.effect(wasRunning: true, unchanged: true), .restoreVisibility)
    }
    func testUserWorkOrDependentEditsPreventAutomaticReversal() {
        XCTAssertEqual(LaunchReversalPolicy.effect(wasRunning: false, unchanged: false), .unavailable)
        XCTAssertEqual(LaunchReversalPolicy.effect(wasRunning: true, unchanged: false), .unavailable)
    }
}
