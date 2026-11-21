import XCTest
@testable import Jarvis

/// Contract: Aim's overlay state — chip hit-testing and the 500ms dwell
/// clock are pure top-left-space math, and pendingCount always mirrors
/// what's actually drawn so a spoken index resolves honestly.
@MainActor
final class TargetOverlayTests: XCTestCase {

    private func chip(_ index: Int, x: Double, y: Double,
                      w: Double = 24, h: Double = 24) -> (index: Int, rect: CGRect) {
        (index, CGRect(x: x, y: y, width: w, height: h))
    }

    func testOverlayPanelStaysOutOfCapturesAndNeverTakesTheMouse() {
        let panel = TargetOverlay.makePanel()
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
    }

    // MARK: - chipIndex

    func testChipIndexFindsTheChipUnderThePoint() {
        let chips = [chip(0, x: 10, y: 10), chip(1, x: 100, y: 10)]
        XCTAssertEqual(TargetOverlay.chipIndex(under: CGPoint(x: 20, y: 20), chips: chips), 0)
        XCTAssertEqual(TargetOverlay.chipIndex(under: CGPoint(x: 110, y: 20), chips: chips), 1)
    }

    func testChipIndexMissesEverywhereElse() {
        let chips = [chip(0, x: 10, y: 10)]
        XCTAssertNil(TargetOverlay.chipIndex(under: CGPoint(x: 60, y: 20), chips: chips))
        XCTAssertNil(TargetOverlay.chipIndex(under: CGPoint(x: 5, y: 500), chips: chips))
    }

    /// Overlapping chips resolve deterministically — first drawn wins.
    func testChipIndexPrefersTheFirstOverlap() {
        let chips = [chip(0, x: 0, y: 0, w: 40, h: 40), chip(1, x: 20, y: 20, w: 40, h: 40)]
        XCTAssertEqual(TargetOverlay.chipIndex(under: CGPoint(x: 30, y: 30), chips: chips), 0)
    }

    // MARK: - DwellTracker

    func testDwellUnderThresholdFiresNothing() {
        var dwell = TargetOverlay.DwellTracker()
        dwell.chips = [chip(0, x: 0, y: 0)]
        let inside = CGPoint(x: 12, y: 12)
        XCTAssertNil(dwell.advance(point: inside, now: 0))
        XCTAssertNil(dwell.advance(point: inside, now: 0.49))
    }

    func testDwellFiresAtThreshold() {
        var dwell = TargetOverlay.DwellTracker()
        dwell.chips = [chip(0, x: 0, y: 0)]
        let inside = CGPoint(x: 12, y: 12)
        XCTAssertNil(dwell.advance(point: inside, now: 0))
        XCTAssertEqual(dwell.advance(point: inside, now: 0.5), 0)
    }

    /// Leaving the chip — even for one sample — restarts its clock.
    func testLeavingTheChipResetsTheClock() {
        var dwell = TargetOverlay.DwellTracker()
        dwell.chips = [chip(0, x: 0, y: 0)]
        let inside = CGPoint(x: 12, y: 12), outside = CGPoint(x: 200, y: 200)
        XCTAssertNil(dwell.advance(point: inside, now: 0))
        XCTAssertNil(dwell.advance(point: inside, now: 0.4))
        XCTAssertNil(dwell.advance(point: outside, now: 0.45))
        XCTAssertNil(dwell.advance(point: inside, now: 0.9))   // re-entered
        XCTAssertNil(dwell.advance(point: inside, now: 1.39))
        XCTAssertEqual(dwell.advance(point: inside, now: 1.4), 0)
    }

    /// Moving between chips hands the clock to the new chip.
    func testMovingBetweenChipsRestartsTheClock() {
        var dwell = TargetOverlay.DwellTracker()
        dwell.chips = [chip(0, x: 0, y: 0), chip(1, x: 100, y: 0)]
        XCTAssertNil(dwell.advance(point: CGPoint(x: 12, y: 12), now: 0))
        XCTAssertNil(dwell.advance(point: CGPoint(x: 12, y: 12), now: 0.4))
        XCTAssertNil(dwell.advance(point: CGPoint(x: 112, y: 12), now: 0.45))
        XCTAssertNil(dwell.advance(point: CGPoint(x: 112, y: 12), now: 0.9))
        XCTAssertEqual(dwell.advance(point: CGPoint(x: 112, y: 12), now: 0.95), 1)
    }

    /// A fired chip can't refire while the gaze stays parked on it.
    func testFiredChipDoesNotRefireWithoutReentry() {
        var dwell = TargetOverlay.DwellTracker()
        dwell.chips = [chip(0, x: 0, y: 0)]
        let inside = CGPoint(x: 12, y: 12)
        XCTAssertNil(dwell.advance(point: inside, now: 0))
        XCTAssertEqual(dwell.advance(point: inside, now: 0.6), 0)
        XCTAssertNil(dwell.advance(point: inside, now: 1.2))
        XCTAssertNil(dwell.advance(point: inside, now: 3.0))
    }

    /// Re-arming a fresh chip set discards the old clock — a second
    /// show never inherits the first show's dwell progress.
    func testRearmResetsProgress() {
        var dwell = TargetOverlay.DwellTracker()
        dwell.chips = [chip(0, x: 0, y: 0)]
        let inside = CGPoint(x: 12, y: 12)
        XCTAssertNil(dwell.advance(point: inside, now: 0))
        XCTAssertNil(dwell.advance(point: inside, now: 0.4))
        dwell.chips = [chip(1, x: 0, y: 0)]                     // new set
        XCTAssertNil(dwell.advance(point: inside, now: 0.9))    // clock restarts
        XCTAssertEqual(dwell.advance(point: inside, now: 1.4), 1)
    }

    // MARK: - radialChipCenters

    /// Chips sit ON the error band — never inside it.
    func testRadialChipsLandOnTheRadius() {
        let point = CGPoint(x: 500, y: 400)
        for c in TargetOverlay.radialChipCenters(count: 4, near: point, radius: 90) {
            XCTAssertEqual(hypot(c.x - point.x, c.y - point.y), 90, accuracy: 0.001)
        }
    }

    /// A radius below the floor clamps up — chips can never cover the
    /// point the user is aiming at.
    func testRadialRadiusFloorsAtForty() {
        let point = CGPoint(x: 500, y: 400)
        for c in TargetOverlay.radialChipCenters(count: 3, near: point, radius: 10) {
            XCTAssertEqual(hypot(c.x - point.x, c.y - point.y), 40, accuracy: 0.001)
        }
    }

    func testRadialWithNoLabelsDrawsNothing() {
        XCTAssertTrue(TargetOverlay.radialChipCenters(count: 0, near: .zero, radius: 80).isEmpty)
    }

    // MARK: - pendingCount lifecycle

    /// pendingCount mirrors drawn chips: shown→N, hideAll→0.
    func testPendingCountLifecycle() {
        let overlay = TargetOverlay()
        XCTAssertEqual(overlay.pendingCount, 0)
        overlay.showNumbers(targets: [
            (frame: CGRect(x: 10, y: 10, width: 40, height: 20), label: "Save"),
            (frame: CGRect(x: 100, y: 10, width: 40, height: 20), label: "Open"),
        ]) { _ in }
        XCTAssertEqual(overlay.pendingCount, 2)
        overlay.hideAll()
        XCTAssertEqual(overlay.pendingCount, 0)
    }

    /// A second show replaces the pending set — re-arm, never stack.
    func testRearmReplacesPendingSet() {
        let overlay = TargetOverlay()
        overlay.showRadial(labels: ["a", "b", "c"], near: CGPoint(x: 400, y: 300),
                           radius: 80) { _ in }
        XCTAssertEqual(overlay.pendingCount, 3)
        overlay.showNumbers(targets: [
            (frame: CGRect(x: 0, y: 0, width: 20, height: 20), label: "x"),
        ]) { _ in }
        XCTAssertEqual(overlay.pendingCount, 1)
        overlay.hideAll()
    }

    /// More than the cap draws the cap, not the list — pendingCount is
    /// what a voice index can actually resolve against.
    func testNumbersCapAtSixty() {
        let overlay = TargetOverlay()
        let targets = (0..<80).map {
            (frame: CGRect(x: CGFloat($0) * 10, y: 0, width: 8, height: 8), label: "t\($0)")
        }
        overlay.showNumbers(targets: targets) { _ in }
        XCTAssertEqual(overlay.pendingCount, TargetOverlay.maxNumberChips)
        overlay.hideAll()
    }

    func testHideAllFromEmptyStateIsSafe() {
        let overlay = TargetOverlay()
        overlay.hideAll()
        overlay.hideAll()
        XCTAssertEqual(overlay.pendingCount, 0)
    }

    func testAgentChipsThenHideIsSafe() {
        let overlay = TargetOverlay()
        overlay.agentChips([CGRect(x: 0, y: 0, width: 10, height: 10)])
        overlay.agentChips([])
        overlay.hideAll()
    }

    /// A pick retires only its own chip set — the conforming ring the
    /// scorer owns survives it (disarm/hideAll confusion used to order
    /// the ring out under the same tick's acquire).
    func testPickClearsChipsButKeepsRing() {
        let overlay = TargetOverlay()
        var t: TimeInterval = 0
        overlay.now = { t }
        overlay.intentEvent(.acquire(intentCandidate(x: 0, y: 0, w: 40, h: 40)))
        XCTAssertTrue(overlay.ringArmed)
        let frame = CGRect(x: 100, y: 100, width: 50, height: 30)
        var picked: [Int] = []
        overlay.showNumbers(targets: [(frame: frame, label: "A")]) { picked.append($0) }
        let chipPoint = CGPoint(x: frame.minX + TargetOverlay.numberNudge.x,
                                y: frame.minY + TargetOverlay.numberNudge.y)
        overlay.ingestGaze(chipPoint)
        t = 0.6
        overlay.ingestGaze(chipPoint)
        XCTAssertEqual(picked, [0])
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertTrue(overlay.ringArmed)   // ring survives the pick
        overlay.hideAll()
    }

    /// `hideChips` is the scoped teardown — chips + pick state only.
    func testHideChipsLeavesRingHaloAlone() {
        let overlay = TargetOverlay()
        overlay.intentEvent(.acquire(intentCandidate(x: 0, y: 0, w: 40, h: 40)))
        overlay.showRadial(labels: ["a", "b"], near: CGPoint(x: 400, y: 300),
                           radius: 80) { _ in }
        XCTAssertTrue(overlay.ringArmed)
        XCTAssertEqual(overlay.pendingCount, 2)
        overlay.hideChips()
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertTrue(overlay.ringArmed)
        overlay.hideAll()
        XCTAssertFalse(overlay.ringArmed)
    }

    /// The whole ingest→dwell→pick→dismiss loop on a fake clock: the
    /// chip centers on the target corner + nudge, so the nudged corner
    /// is guaranteed inside its hit rect.
    func testIngestGazeFiresPickThenClears() {
        let overlay = TargetOverlay()
        var t: TimeInterval = 0
        overlay.now = { t }
        var picked: [Int] = []
        let frame = CGRect(x: 100, y: 100, width: 50, height: 30)
        overlay.showNumbers(targets: [(frame: frame, label: "A")]) { picked.append($0) }
        let chipPoint = CGPoint(x: frame.minX + TargetOverlay.numberNudge.x,
                                y: frame.minY + TargetOverlay.numberNudge.y)
        overlay.ingestGaze(chipPoint)          // t=0: enters, clock starts
        t = 0.3
        overlay.ingestGaze(chipPoint)          // still short of 500ms
        XCTAssertTrue(picked.isEmpty)
        t = 0.6
        overlay.ingestGaze(chipPoint)          // ≥500ms → pick + dismiss
        XCTAssertEqual(picked, [0])
        XCTAssertEqual(overlay.pendingCount, 0)
        overlay.hideAll()
    }

    // MARK: - Conforming ring: shape mapping

    private func intentCandidate(
        _ kind: IntentCandidate.Kind = .axElement,
        x: Double, y: Double, w: Double, h: Double,
        motor: CGRect? = nil, role: String = "AXButton", id: String = "c"
    ) -> IntentCandidate {
        let frame = CGRect(x: x, y: y, width: w, height: h)
        return IntentCandidate(id: id, kind: kind, frame: frame,
                               motorRect: motor ?? frame, role: role, label: id)
    }

    /// A small near-square target gets a circle centered on it.
    func testRingTargetSquareBecomesCircle() {
        let c = intentCandidate(x: 100, y: 100, w: 30, h: 30)
        let g = TargetOverlay.ringTarget(for: c)
        XCTAssertEqual(g.rect.width, g.rect.height, accuracy: 0.001)
        XCTAssertEqual(g.corner, g.rect.width / 2, accuracy: 0.001)
        XCTAssertEqual(g.rect.midX, 115, accuracy: 0.001)
        XCTAssertEqual(g.rect.midY, 115, accuracy: 0.001)
    }

    /// Wide and short → capsule (corner = half the height).
    func testRingTargetWideShortBecomesCapsule() {
        let c = intentCandidate(x: 0, y: 0, w: 140, h: 28)
        let g = TargetOverlay.ringTarget(for: c)
        XCTAssertEqual(g.rect, CGRect(x: -5, y: -5, width: 150, height: 38))
        XCTAssertEqual(g.corner, g.rect.height / 2, accuracy: 0.001)
    }

    /// A big element is no capsule — a rounded-rect hugging the frame.
    func testRingTargetLargeBecomesRoundedRect() {
        let c = intentCandidate(x: 0, y: 0, w: 300, h: 200)
        let g = TargetOverlay.ringTarget(for: c)
        XCTAssertEqual(g.rect, CGRect(x: -5, y: -5, width: 310, height: 210))
        XCTAssertEqual(g.corner, 8, accuracy: 0.001)
    }

    /// A thin tall sliver caps its corner at height/4 below the 8px max.
    func testRingTargetTallSliverClampsCorner() {
        let c = intentCandidate(x: 0, y: 0, w: 12, h: 20)
        let g = TargetOverlay.ringTarget(for: c)
        XCTAssertEqual(g.corner, min(8, g.rect.height / 4), accuracy: 0.001)
        XCTAssertLessThan(g.corner, 8)
    }

    /// Traffic lights circle the button (motorRect), not the window.
    func testRingTargetTrafficLightCirclesMotorRect() {
        let motor = CGRect(x: 20, y: 20, width: 12, height: 12)
        let c = intentCandidate(.trafficLight, x: 0, y: 0, w: 800, h: 600,
                                motor: motor)
        let g = TargetOverlay.ringTarget(for: c)
        XCTAssertEqual(g.rect.width, g.rect.height, accuracy: 0.001)
        XCTAssertEqual(g.corner, g.rect.width / 2, accuracy: 0.001)
        XCTAssertEqual(g.rect.midX, motor.midX, accuracy: 0.001)
        XCTAssertEqual(g.rect.midY, motor.midY, accuracy: 0.001)
        XCTAssertLessThan(g.rect.width, 40)
    }

    /// DOM candidates (links, buttons) read as capsules.
    func testRingTargetDOMBecomesCapsule() {
        let c = intentCandidate(.dom, x: 0, y: 0, w: 200, h: 20, role: "link")
        let g = TargetOverlay.ringTarget(for: c)
        XCTAssertEqual(g.corner, min(g.rect.width, g.rect.height) / 2,
                       accuracy: 0.001)
    }

    // MARK: - Conforming ring: progress + alpha

    /// Full brightness through the halfway point, then the Meta
    /// dwell-fade toward the floor — never a bright ring parked in the
    /// fovea for a long hold.
    func testRingAlphaFullThenFadesToFloor() {
        XCTAssertEqual(TargetOverlay.ringAlpha(progress: 0), 1, accuracy: 0.001)
        XCTAssertEqual(TargetOverlay.ringAlpha(progress: 0.5), 1, accuracy: 0.001)
        let mid = TargetOverlay.ringAlpha(progress: 0.75)
        XCTAssertGreaterThan(mid, TargetOverlay.ringDwellFloor)
        XCTAssertLessThan(mid, 1)
        XCTAssertEqual(TargetOverlay.ringAlpha(progress: 1),
                       TargetOverlay.ringDwellFloor, accuracy: 0.001)
    }

    /// hold progress is what the fill stroke sweeps — 0→1 verbatim.
    func testHoldProgressDrivesFillFraction() {
        let overlay = TargetOverlay()
        let c = intentCandidate(x: 100, y: 100, w: 120, h: 28)
        overlay.intentEvent(.acquire(c))
        overlay.intentEvent(.hold(c, progress: 0.4))
        XCTAssertEqual(overlay.ringProgress, 0.4, accuracy: 0.001)
        overlay.intentEvent(.hold(c, progress: 1))
        XCTAssertEqual(overlay.ringProgress, 1, accuracy: 0.001)
        overlay.hideAll()
    }

    /// Dwell off: the glow is a plain look-highlight — no sweep and no
    /// dwell-fade however long the look lasts; the sweep shows only while
    /// dwell can click.
    func testLookHighlightWithoutDwellHoldsSteady() {
        XCTAssertEqual(TargetOverlay.ringAlpha(progress: 1, dwell: false), 1, accuracy: 0.001)
        let overlay = TargetOverlay()
        overlay.intentEvent(.acquire(intentCandidate(x: 100, y: 100, w: 120, h: 28)))
        XCTAssertFalse(overlay.magnet.state.showsProgress)
        overlay.showsDwellProgress = true
        XCTAssertTrue(overlay.magnet.state.showsProgress)
        overlay.hideAll()
    }

    // MARK: - Magnet: one object

    /// The orb follows every fresh gaze point; a lock hugs the control's
    /// own shape; a release gathers the glow back into the orb, which
    /// never left — nothing blinks off.
    func testOrbFollowsGazeAndTheLockHugsTheControl() {
        let overlay = TargetOverlay()
        overlay.ingestGaze(CGPoint(x: 400, y: 300))
        XCTAssertEqual(overlay.magnet.state.orb, CGPoint(x: 400, y: 300))
        XCTAssertNil(overlay.magnet.state.lock)
        let a = intentCandidate(x: 380, y: 290, w: 120, h: 28, id: "a")
        overlay.intentEvent(.acquire(a))
        let target = TargetOverlay.ringTarget(for: a)
        XCTAssertEqual(overlay.magnet.state.lock?.rect, target.rect)
        XCTAssertEqual(overlay.magnet.state.lock?.corner, target.corner)
        XCTAssertEqual(overlay.ringRect, target.rect)
        overlay.ingestGaze(CGPoint(x: 410, y: 302))
        XCTAssertEqual(overlay.magnet.state.orb, CGPoint(x: 410, y: 302))
        overlay.intentEvent(.release(a))
        XCTAssertNil(overlay.magnet.state.lock)
        XCTAssertTrue(overlay.orbShown, "the glow shrinks back into the orb")
        overlay.hideAll()
        XCTAssertFalse(overlay.orbShown)
    }

    /// A lost feed fades the orb — it never sits on a dead tracker.
    func testGazeLostHidesTheOrb() {
        let overlay = TargetOverlay()
        overlay.ingestGaze(CGPoint(x: 200, y: 200))
        XCTAssertTrue(overlay.orbShown)
        overlay.gazeLost(true)
        XCTAssertFalse(overlay.orbShown)
        overlay.gazeLost(false)
        XCTAssertFalse(overlay.orbShown, "only a fresh point brings it back")
        overlay.hideAll()
    }

    /// A hold carrying a moved frame keeps the same glow and moves it; a
    /// different control is a new glow, grown out of the orb.
    func testSameControlGlidesAndANewControlIsANewGlow() {
        let overlay = TargetOverlay()
        let a = intentCandidate(x: 100, y: 100, w: 120, h: 28, id: "a")
        overlay.intentEvent(.acquire(a))
        let moved = intentCandidate(x: 104, y: 100, w: 120, h: 28, id: "a")
        overlay.intentEvent(.hold(moved, progress: 0.5))
        XCTAssertEqual(overlay.magnet.state.lock?.key, "a")
        XCTAssertEqual(overlay.magnet.state.lock?.rect, TargetOverlay.ringTarget(for: moved).rect)
        let b = intentCandidate(x: 300, y: 100, w: 40, h: 40, id: "b")
        overlay.intentEvent(.acquire(b))
        XCTAssertEqual(overlay.magnet.state.lock?.key, "b")
        XCTAssertEqual(overlay.ringProgress, 0, accuracy: 0.001)
        overlay.hideAll()
    }

    /// Reduce Motion reaches the state the view draws from, where the
    /// stretch becomes a crossfade and the orb stops travelling.
    func testReduceMotionReachesTheMagnet() {
        let overlay = TargetOverlay()
        overlay.reduceMotion = { true }
        overlay.ingestGaze(CGPoint(x: 200, y: 200))
        XCTAssertTrue(overlay.magnet.state.reduceMotion)
        overlay.reduceMotion = { false }
        overlay.ingestGaze(CGPoint(x: 210, y: 200))
        XCTAssertFalse(overlay.magnet.state.reduceMotion)
        overlay.hideAll()
    }

    // MARK: - Lock gate: error band, size, role (JARA-55)

    /// With the error band wider than 1.5× the control, the tracker can't
    /// single it out: only the orb shows, and a band that widens while
    /// locked lets go of the control.
    func testWideErrorBandShowsOnlyTheOrb() {
        let overlay = TargetOverlay()
        overlay.gazeSigmaPt = 384
        overlay.ingestGaze(CGPoint(x: 114, y: 114))
        let button = intentCandidate(x: 100, y: 100, w: 28, h: 28)
        overlay.intentEvent(.acquire(button))
        XCTAssertFalse(overlay.ringArmed)
        XCTAssertTrue(overlay.orbShown)
        overlay.gazeSigmaPt = 30
        overlay.intentEvent(.hold(button, progress: 0.3))
        XCTAssertTrue(overlay.ringArmed)
        overlay.gazeSigmaPt = 384
        overlay.intentEvent(.hold(button, progress: 0.5))
        XCTAssertFalse(overlay.ringArmed)
        overlay.hideAll()
    }

    func testLockRuleWeighsErrorBandSizeAndRole() {
        let button = intentCandidate(x: 0, y: 0, w: 28, h: 28)
        XCTAssertTrue(TargetOverlay.canLock(button, sigmaPt: 42))
        XCTAssertFalse(TargetOverlay.canLock(button, sigmaPt: 43))
        XCTAssertTrue(TargetOverlay.canLock(intentCandidate(x: 0, y: 0, w: 320, h: 200), sigmaPt: 40))
        XCTAssertFalse(TargetOverlay.canLock(intentCandidate(x: 0, y: 0, w: 321, h: 30), sigmaPt: 20))
        XCTAssertFalse(TargetOverlay.canLock(intentCandidate(x: 0, y: 0, w: 200, h: 201), sigmaPt: 20))
        XCTAssertFalse(TargetOverlay.canLock(intentCandidate(.window, x: 0, y: 0, w: 200, h: 100,
                                                             role: "window"), sigmaPt: 20))
        for role in ["AXGroup", "AXTable", "AXScrollArea"] {
            XCTAssertFalse(TargetOverlay.canLock(intentCandidate(x: 0, y: 0, w: 100, h: 40, role: role),
                                                 sigmaPt: 20), role)
        }
        let light = intentCandidate(.trafficLight, x: 0, y: 0, w: 800, h: 600,
                                    motor: CGRect(x: 8, y: 8, width: 14, height: 14))
        XCTAssertTrue(TargetOverlay.canLock(light, sigmaPt: 20))
        XCTAssertFalse(TargetOverlay.canLock(light, sigmaPt: 22))
    }

    /// Panes, tables and windows never light up, whatever the scorer says.
    func testOversizeAndContainerCandidatesNeverLock() {
        let overlay = TargetOverlay()
        for c in [intentCandidate(x: 0, y: 0, w: 900, h: 600, id: "pane"),
                  intentCandidate(x: 0, y: 0, w: 200, h: 120, role: "AXTable", id: "table"),
                  intentCandidate(.window, x: 0, y: 0, w: 300, h: 150, role: "window", id: "win")] {
            overlay.intentEvent(.acquire(c))
            XCTAssertFalse(overlay.ringArmed, c.id)
        }
        overlay.hideAll()
    }

    /// A tie lets go of the highlight — the old element no longer stays
    /// lit while the scorer says it can't tell.
    func testAmbiguityReleasesTheGlow() {
        let overlay = TargetOverlay()
        var got: [IntentCandidate] = []
        overlay.onAmbiguous = { got = $0 }
        let a = intentCandidate(x: 0, y: 0, w: 40, h: 40, id: "a")
        let b = intentCandidate(x: 50, y: 0, w: 40, h: 40, id: "b")
        overlay.intentEvent(.acquire(a))
        XCTAssertTrue(overlay.ringArmed)
        overlay.intentEvent(.ambiguous([a, b]))
        XCTAssertFalse(overlay.ringArmed)
        XCTAssertEqual(got, [a, b])
        overlay.hideAll()
    }

    /// Exactly one highlight: while a halo marks a control, the gaze glow
    /// stays gathered in the orb, and it comes back once the halo goes.
    func testHaloAndGazeGlowNeverShowTogether() {
        let overlay = TargetOverlay()
        let a = intentCandidate(x: 0, y: 0, w: 40, h: 40, id: "a")
        overlay.intentEvent(.acquire(a))
        XCTAssertTrue(overlay.ringArmed)
        overlay.showHalo(frame: CGRect(x: 200, y: 200, width: 80, height: 28))
        XCTAssertTrue(overlay.haloArmed)
        XCTAssertFalse(overlay.ringArmed)
        overlay.intentEvent(.hold(a, progress: 0.4))
        XCTAssertFalse(overlay.ringArmed)
        overlay.hideHalo()
        overlay.intentEvent(.hold(a, progress: 0.5))
        XCTAssertTrue(overlay.ringArmed)
        overlay.hideAll()
    }

    /// A press glow marks the control Jarvis presses by name — it is not a
    /// gaze guess, so the error band doesn't gate it.
    func testPressGlowIgnoresTheErrorBand() {
        let overlay = TargetOverlay()
        overlay.gazeSigmaPt = 384
        overlay.glowPress(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        XCTAssertTrue(overlay.ringArmed)
        overlay.hideAll()
    }

    /// A second press on the same control restarts its timeout, so the
    /// first press's timeout can't cut the second glow short.
    func testARepeatedPressGlowRestartsItsTimeout() async throws {
        let overlay = TargetOverlay()
        let frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        overlay.glowPress(frame: frame)
        try await Task.sleep(for: .milliseconds(800))
        overlay.glowPress(frame: frame)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(overlay.ringArmed)
        overlay.hideAll()
    }

    // MARK: - Conforming ring: lifecycle + ambiguity

    /// `.none` on a fresh overlay is a no-op; after an acquire it drops
    /// the ring's claim.
    func testNoneAndReleaseAreSafe() {
        let overlay = TargetOverlay()
        let c = intentCandidate(x: 0, y: 0, w: 40, h: 40)
        overlay.intentEvent(.none)
        overlay.intentEvent(.release(c))
        XCTAssertFalse(overlay.ringArmed)
        overlay.intentEvent(.acquire(c))
        XCTAssertTrue(overlay.ringArmed)
        overlay.intentEvent(.none)
        XCTAssertFalse(overlay.ringArmed)
        overlay.hideAll()
    }

    /// Ambiguity only signals upward — the coordinator owns the radial;
    /// the ring itself claims nothing.
    func testAmbiguousBubblesUpThroughHook() {
        let overlay = TargetOverlay()
        var got: [IntentCandidate] = []
        overlay.onAmbiguous = { got = $0 }
        let a = intentCandidate(x: 0, y: 0, w: 40, h: 40, id: "a")
        let b = intentCandidate(x: 50, y: 0, w: 40, h: 40, id: "b")
        overlay.intentEvent(.ambiguous([a, b]))
        XCTAssertEqual(got, [a, b])
        XCTAssertFalse(overlay.ringArmed)
    }

    func testHideAllDismissesRing() {
        let overlay = TargetOverlay()
        overlay.intentEvent(.acquire(intentCandidate(x: 0, y: 0, w: 40, h: 40)))
        XCTAssertTrue(overlay.ringArmed)
        overlay.hideAll()
        XCTAssertFalse(overlay.ringArmed)
        XCTAssertEqual(overlay.ringProgress, 0, accuracy: 0.001)
    }

    /// Agent stand-down applies to the ring too — acquiring on a frame
    /// an agent is acting on must not fight the agent's cursor.
    func testRingAcquireUnderAgentActivityIsSafe() {
        let overlay = TargetOverlay()
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        overlay.agentChips([frame])
        overlay.intentEvent(.acquire(intentCandidate(x: 0, y: 0, w: 40, h: 40)))
        XCTAssertTrue(overlay.ringArmed)
        overlay.agentChips([])
        overlay.hideAll()
    }
}
