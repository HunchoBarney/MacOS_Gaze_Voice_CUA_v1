import AppKit
import XCTest
@testable import JevVoice

@MainActor
final class OverlayPlacementTests: XCTestCase {
    func testNegativeScreenCoordinatesAndGrowthPreserveBottomAnchor() {
        let visible = NSRect(x: -1440, y: -200, width: 1370, height: 850)
        let short = VoiceWindows.frame(contentSize: NSSize(width: 290, height: 70), visibleFrame: visible)
        let tall = VoiceWindows.frame(contentSize: NSSize(width: 380, height: 260), visibleFrame: visible)
        XCTAssertEqual(short.midX, visible.midX)
        XCTAssertEqual(tall.midX, visible.midX)
        XCTAssertEqual(short.minY, tall.minY)
        XCTAssertTrue(visible.contains(short))
        XCTAssertTrue(visible.contains(tall))
    }

    func testOversizedContentClampsInsideAvailableScreen() {
        let visible = NSRect(x: 70, y: 30, width: 300, height: 240)
        let frame = VoiceWindows.frame(contentSize: NSSize(width: 380, height: 500), visibleFrame: visible)
        XCTAssertTrue(visible.contains(frame))
    }
}
