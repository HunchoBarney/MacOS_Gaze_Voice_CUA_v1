import AppKit
import XCTest
@testable import Jarvis

/// The guide callout and the tab's step controls: placement beside the
/// target on whichever side has room, the same words Jarvis speaks, the
/// step counter, the buttons' controls, and Reduce Motion. Pure layout,
/// no window server.
@MainActor
final class GuideCalloutTests: XCTestCase {
    static let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
    static let size = CGSize(width: 260, height: 60)

    private func place(_ target: CGRect, screen: CGRect = screen,
                       size: CGSize = size) -> (frame: CGRect, side: GuideCallout.Side) {
        GuideCallout.placement(size: size, target: target, screen: screen)
    }

    private func assertBeside(_ frame: CGRect, _ target: CGRect, on screen: CGRect = screen,
                              file: StaticString = #filePath, line: UInt = #line) {
        let glow = target.insetBy(dx: -TargetOverlay.haloOutset, dy: -TargetOverlay.haloOutset)
        XCTAssertFalse(frame.intersects(glow), "callout \(frame) covers the target \(target)", file: file, line: line)
        XCTAssertTrue(screen.insetBy(dx: GuideCallout.margin, dy: GuideCallout.margin).contains(frame),
                      "callout \(frame) leaves the screen \(screen)", file: file, line: line)
    }

    private func element(_ label: String, role: String = "AXButton", frame: CGRect) -> GuideElement {
        GuideElement(role: role, label: label, frame: frame)
    }

    private func step(_ target: GuideElement, number: Int = 1, total: Int? = nil) -> GuideStep {
        StepPhrasing.step(number: number, total: total, action: .element(target),
                          window: CGRect(x: 0, y: 25, width: 900, height: 600), scene: [target], hint: nil)
    }

    // MARK: - Placement

    func testCalloutSitsBelowTheTargetWhenThereIsRoom() {
        let target = CGRect(x: 600, y: 300, width: 40, height: 30)
        let placed = place(target)
        XCTAssertEqual(placed.side, .below)
        XCTAssertEqual(placed.frame.minY, target.maxY + GuideCallout.gap)
        XCTAssertEqual(placed.frame.midX, target.midX)
        assertBeside(placed.frame, target)
    }

    func testCalloutMovesAboveNearTheBottomEdge() {
        let target = CGRect(x: 600, y: 820, width: 40, height: 30)
        let placed = place(target)
        XCTAssertEqual(placed.side, .above)
        XCTAssertEqual(placed.frame.maxY, target.minY - GuideCallout.gap)
        assertBeside(placed.frame, target)
    }

    func testCalloutMovesRightWhenAboveAndBelowAreTooShort() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let target = CGRect(x: 100, y: 60, width: 50, height: 80)
        let placed = place(target, screen: screen)
        XCTAssertEqual(placed.side, .right)
        XCTAssertEqual(placed.frame.minX, target.maxX + GuideCallout.gap)
        assertBeside(placed.frame, target, on: screen)
    }

    func testCalloutMovesLeftWhenOnlyTheLeftHasRoom() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 200)
        let target = CGRect(x: 880, y: 60, width: 50, height: 80)
        let placed = place(target, screen: screen)
        XCTAssertEqual(placed.side, .left)
        XCTAssertEqual(placed.frame.maxX, target.minX - GuideCallout.gap)
        assertBeside(placed.frame, target, on: screen)
    }

    func testCalloutStaysOnScreenAtTheLeftAndRightEdges() {
        let left = CGRect(x: 0, y: 400, width: 30, height: 30)
        let atLeft = place(left)
        XCTAssertEqual(atLeft.side, .below)
        XCTAssertEqual(atLeft.frame.minX, Self.screen.minX + GuideCallout.margin)
        assertBeside(atLeft.frame, left)

        let right = CGRect(x: 1410, y: 400, width: 30, height: 30)
        let atRight = place(right)
        XCTAssertEqual(atRight.frame.maxX, Self.screen.maxX - GuideCallout.margin)
        assertBeside(atRight.frame, right)
    }

    func testCalloutClearsTheMenuBarAndDockForTargetsInCorners() {
        let topLeft = CGRect(x: 2, y: 27, width: 30, height: 20)
        let a = place(topLeft)
        XCTAssertEqual(a.side, .below)
        assertBeside(a.frame, topLeft)

        let bottomRight = CGRect(x: 1405, y: 840, width: 30, height: 30)
        let b = place(bottomRight)
        XCTAssertEqual(b.side, .above)
        assertBeside(b.frame, bottomRight)

        let topRight = CGRect(x: 1405, y: 27, width: 30, height: 20)
        let c = place(topRight)
        XCTAssertEqual(c.side, .below)
        assertBeside(c.frame, topRight)
    }

    func testATargetFillingTheScreenTakesTheRoomiestSideOnScreen() {
        let target = CGRect(x: 40, y: 60, width: 1300, height: 800)
        let placed = place(target)
        XCTAssertEqual(placed.side, .right)
        XCTAssertTrue(Self.screen.insetBy(dx: GuideCallout.margin, dy: GuideCallout.margin).contains(placed.frame))
    }

    func testCalloutFollowsTheTargetToItsOwnScreen() {
        let main = Self.screen
        let right = CGRect(x: 1440, y: -200, width: 1920, height: 1055)
        let above = CGRect(x: 0, y: -1080, width: 1440, height: 1080)
        let screens = [main, right, above]

        let onRight = CGRect(x: 2000, y: 300, width: 40, height: 30)
        XCTAssertEqual(GuideCallout.screen(for: onRight, in: screens), right)
        let placedRight = place(onRight, screen: right)
        assertBeside(placedRight.frame, onRight, on: right)

        let nearRightBottom = CGRect(x: 3000, y: 830, width: 40, height: 20)
        XCTAssertEqual(GuideCallout.screen(for: nearRightBottom, in: screens), right)
        let placedLow = place(nearRightBottom, screen: right)
        XCTAssertEqual(placedLow.side, .above)
        assertBeside(placedLow.frame, nearRightBottom, on: right)

        let onAbove = CGRect(x: 700, y: -1060, width: 40, height: 30)
        XCTAssertEqual(GuideCallout.screen(for: onAbove, in: screens), above)
        assertBeside(place(onAbove, screen: above).frame, onAbove, on: above)

        let straddling = CGRect(x: 1420, y: 300, width: 100, height: 30)
        XCTAssertEqual(GuideCallout.screen(for: straddling, in: screens), right)
        let offScreen = CGRect(x: 5000, y: 300, width: 40, height: 30)
        XCTAssertEqual(GuideCallout.screen(for: offScreen, in: screens), right)
        XCTAssertNil(GuideCallout.screen(for: onRight, in: []))
    }

    // MARK: - Text

    func testCalloutShowsTheWordsJarvisSpeaks() {
        let attach = element("Attach", frame: CGRect(x: 800, y: 45, width: 40, height: 30))
        let first = step(attach)
        let text = GuideCallout.text(for: first)
        XCTAssertEqual(text, first.instruction)
        XCTAssertTrue(StepPhrasing.opening(first, slow: false).contains(StepPhrasing.lowercasedFirst(text)))
        let second = step(attach, number: 2)
        XCTAssertEqual(StepPhrasing.opening(second, slow: false), "Now " + StepPhrasing.lowercasedFirst(GuideCallout.text(for: second)))

        let opening = GuideMachine(step: second, at: 0).opening(slow: false)
        XCTAssertEqual(opening.first, .point(second))
        guard case .say(let spoken) = opening.last else { return XCTFail("no spoken line") }
        XCTAssertTrue(spoken.hasSuffix(StepPhrasing.lowercasedFirst(GuideCallout.text(for: second))))
    }

    func testConsequentialCalloutNamesTheEffectLikeTheSpokenLine() {
        let send = step(element("Send", frame: CGRect(x: 820, y: 45, width: 50, height: 30)), number: 5)
        XCTAssertNotNil(send.consequenceLine)
        XCTAssertEqual(GuideCallout.text(for: send), send.consequenceLine)
        XCTAssertEqual(GuideCallout.text(for: send), StepPhrasing.opening(send, slow: false))
    }

    func testTextIsNeverSmallerThanSeventeenPointsAndGrowsWithScale() {
        XCTAssertEqual(GuideCallout.pointSize(textScale: 1), 17)
        XCTAssertEqual(GuideCallout.pointSize(textScale: 0.5), 17)
        XCTAssertEqual(GuideCallout.pointSize(textScale: 1.5), 26)
        XCTAssertEqual(GuideCallout.pointSize(textScale: 2), 34)
        XCTAssertEqual(GuideCallout.maxWidth(textScale: 1, screenWidth: 1440), 300)
        XCTAssertEqual(GuideCallout.maxWidth(textScale: 2, screenWidth: 1440), 600)
        XCTAssertEqual(GuideCallout.maxWidth(textScale: 3, screenWidth: 500), 500 - 2 * GuideCallout.margin)
        XCTAssertEqual(GuideCallout.padding(textScale: 2), CGSize(width: 24, height: 18))
    }

    // MARK: - Motion

    func testMotionIsAShortFadeAndOnePulse() {
        let motion = GuideCallout.motion(reduceMotion: false)
        XCTAssertEqual(motion.fade, 0.15)
        XCTAssertEqual(motion.pulse, 0.7)
    }

    func testReduceMotionMakesTheFadeAndPulseInstant() {
        XCTAssertEqual(GuideCallout.motion(reduceMotion: true), GuideCallout.Motion(fade: 0, pulse: 0))
        let callout = GuideCalloutPanel()
        callout.reduceMotion = { true }
        callout.pulse()
        XCTAssertNil(callout.shown)
    }

    func testCalloutPanelStaysOutOfCapturesAndNeverTakesTheMouse() {
        let panel = GuideCalloutPanel.makePanel()
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
    }

    // MARK: - Tab controls

    func testStepCounterShowsTheTotalOnlyWhenKnown() {
        let attach = element("Attach", frame: CGRect(x: 800, y: 45, width: 40, height: 30))
        XCTAssertEqual(GuideTab.counter(step(attach, number: 2, total: 5)), "Step 2 of 5")
        XCTAssertEqual(GuideTab.counter(step(attach, number: 3)), "Step 3")
        XCTAssertEqual(GuideTab.counter(step(attach, number: 6, total: 5)), "Step 6")
    }

    func testButtonsDriveTheSameControlsAsTheSpokenWords() {
        XCTAssertEqual(GuideTab.buttons.map(\.title), ["Do it for me", "Repeat", "Stop"])
        XCTAssertEqual(GuideTab.buttons.map(\.control), [.justDoIt, .repeatIt, .stop])
        for button in GuideTab.buttons {
            XCTAssertEqual(GuideControl.parse(button.title), button.control, button.title)
        }
    }
}
