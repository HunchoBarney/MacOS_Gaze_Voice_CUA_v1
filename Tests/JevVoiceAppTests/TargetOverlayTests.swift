import XCTest
@testable import JevVoice

/// Contract: Aim's overlay state — chip hit-testing and the 500ms dwell
/// clock are pure top-left-space math, and pendingCount always mirrors
/// what's actually drawn so a spoken index resolves honestly.
@MainActor
final class TargetOverlayTests: XCTestCase {

    private func chip(_ index: Int, x: Double, y: Double,
                      w: Double = 24, h: Double = 24) -> (index: Int, rect: CGRect) {
        (index, CGRect(x: x, y: y, width: w, height: h))
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
        let overlay = TargetOverlay(presentsPanels: false)
        XCTAssertEqual(overlay.pendingCount, 0)
        overlay.showRadial(labels: ["Save", "Open"], near: .zero, radius: 80) { _ in }
        XCTAssertEqual(overlay.pendingCount, 2)
        overlay.hideAll()
        XCTAssertEqual(overlay.pendingCount, 0)
    }

    /// A second show replaces the pending set — re-arm, never stack.
    func testRearmReplacesPendingSet() {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.showRadial(labels: ["a", "b", "c"], near: CGPoint(x: 400, y: 300),
                           radius: 80) { _ in }
        XCTAssertEqual(overlay.pendingCount, 3)
        overlay.showRadial(labels: ["x"], near: .zero, radius: 80) { _ in }
        XCTAssertEqual(overlay.pendingCount, 1)
        overlay.hideAll()
    }

    func testChoiceRadialLimitsDrawnOptions() {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.showRadial(labels: (0..<80).map { String($0) }, near: .zero, radius: 80) { _ in }
        XCTAssertEqual(overlay.pendingCount, TargetOverlay.maxRadialChips)
        overlay.hideAll()
    }

    func testHideAllFromEmptyStateIsSafe() {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.hideAll()
        overlay.hideAll()
        XCTAssertEqual(overlay.pendingCount, 0)
    }

    func testAgentChipsThenHideIsSafe() {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.agentChips([CGRect(x: 0, y: 0, width: 10, height: 10)])
        overlay.agentChips([])
        overlay.hideAll()
    }

    func testChoicePreviewDoesNotFirePickOrRetractRing() {
        let overlay = TargetOverlay(presentsPanels: false)
        var t: TimeInterval = 0
        overlay.now = { t }
        overlay.intentEvent(.acquire(intentCandidate(x: 0, y: 0, w: 40, h: 40)))
        XCTAssertTrue(overlay.ringArmed)
        var picked: [Int] = []
        overlay.showRadial(labels: ["A"], near: CGPoint(x: 100, y: 100), radius: 80) { picked.append($0) }
        let chipPoint = CGPoint(x: 100, y: 20)
        overlay.ingestGaze(chipPoint)
        t = 0.6
        overlay.ingestGaze(chipPoint)
        XCTAssertTrue(picked.isEmpty)
        XCTAssertEqual(overlay.previewedChip, 0)
        XCTAssertEqual(overlay.pendingCount, 1)
        XCTAssertTrue(overlay.ringArmed)   // ring survives the pick
        overlay.hideAll()
    }

    /// `hideChips` is the scoped teardown — chips + pick state only.
    func testHideChipsLeavesRingHaloAlone() {
        let overlay = TargetOverlay(presentsPanels: false)
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

    func testLookingAtChoicePreviewsWithoutAnsweringAndLeavingClearsPreview() {
        let overlay = TargetOverlay(presentsPanels: false)
        var t: TimeInterval = 0
        overlay.now = { t }
        var picked: [Int] = []
        overlay.showRadial(labels: ["A"], near: CGPoint(x: 100, y: 100), radius: 80) { picked.append($0) }
        let chipPoint = CGPoint(x: 100, y: 20)
        overlay.ingestGaze(chipPoint)          // t=0: enters, clock starts
        t = 0.3
        overlay.ingestGaze(chipPoint)          // still short of 500ms
        XCTAssertTrue(picked.isEmpty)
        t = 0.6
        overlay.ingestGaze(chipPoint)
        XCTAssertTrue(picked.isEmpty)
        XCTAssertEqual(overlay.previewedChip, 0)
        XCTAssertEqual(overlay.pendingCount, 1)
        t = 5
        overlay.ingestGaze(chipPoint)
        XCTAssertTrue(picked.isEmpty)
        overlay.ingestGaze(.zero)
        XCTAssertNil(overlay.previewedChip)
        XCTAssertEqual(overlay.pendingCount, 1)
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
        let overlay = TargetOverlay(presentsPanels: false)
        let c = intentCandidate(x: 100, y: 100, w: 120, h: 28)
        overlay.intentEvent(.acquire(c))
        overlay.intentEvent(.hold(c, progress: 0.4), dwellFeedback: true)
        XCTAssertEqual(overlay.ringProgress, 0.4, accuracy: 0.001)
        overlay.intentEvent(.hold(c, progress: 1), dwellFeedback: true)
        XCTAssertEqual(overlay.ringProgress, 1, accuracy: 0.001)
        overlay.hideAll()
    }

    /// The view maps progress straight onto the fill stroke's strokeEnd
    /// and the dwell-fade onto the container opacity.
    func testRingViewProgressMapsStrokeEndAndOpacity() {
        let view = TargetOverlay.IntentRingView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.setProgress(0.4)
        XCTAssertEqual(view.fill.strokeEnd, 0.4, accuracy: 0.001)
        XCTAssertEqual(view.container.opacity, 1, accuracy: 0.001)
        view.setProgress(1)
        XCTAssertEqual(view.fill.strokeEnd, 1, accuracy: 0.001)
        XCTAssertEqual(view.container.opacity,
                       Float(TargetOverlay.ringDwellFloor), accuracy: 0.01)
    }

    /// Paths land canvas-relative — the panel covers a union rect in
    /// top-left space, the ring draws inside it.
    func testRingMorphWritesCanvasRelativePaths() {
        let view = TargetOverlay.IntentRingView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let canvas = CGRect(x: 100, y: 100, width: 200, height: 200)
        let to = (rect: CGRect(x: 110, y: 120, width: 60, height: 40),
                  corner: CGFloat(8))
        view.morph(from: TargetOverlay.ringDotGeo(at: CGPoint(x: 140, y: 140)),
                   to: to, in: canvas, duration: 0.16)
        XCTAssertEqual(view.base.path?.boundingBox,
                       CGRect(x: 10, y: 20, width: 60, height: 40))
    }

    // MARK: - Conforming ring: interruptibility

    /// A retarget mid-morph starts from wherever the morph had reached —
    /// the model-side proof that reversals can't jump.
    func testMorphRetargetContinuesFromCurrentPosition() {
        var m = TargetOverlay.RingMorph(
            from: (CGRect(x: 0, y: 0, width: 8, height: 8), 4),
            to: (CGRect(x: 100, y: 100, width: 60, height: 40), 8),
            startedAt: 0, duration: 0.16, active: true)
        let mid = m.current(at: 0.08)
        XCTAssertNotEqual(mid.rect, m.to.rect)
        m.retarget(to: TargetOverlay.ringDotGeo(at: CGPoint(x: 4, y: 4)),
                   at: 0.08, duration: 0.16)
        XCTAssertEqual(m.from.rect, mid.rect)
        XCTAssertEqual(m.from.corner, mid.corner, accuracy: 0.001)
        // A second retarget mid-release continues again from the new leg.
        let rel = m.current(at: 0.12)
        m.retarget(to: (CGRect(x: 200, y: 0, width: 50, height: 30), 8),
                   at: 0.12, duration: 0.16)
        XCTAssertEqual(m.from.rect, rel.rect)
    }

    /// acquire → release mid-morph → acquire: the second acquire's `from`
    /// is exactly where the release morph had reached — no jump, no
    /// snap back to the dot.
    func testAcquireReleaseAcquireLeavesMorphConsistent() {
        let overlay = TargetOverlay(presentsPanels: false)
        var t: TimeInterval = 0
        overlay.now = { t }
        let a = intentCandidate(x: 100, y: 100, w: 120, h: 28, id: "a")
        overlay.intentEvent(.acquire(a))
        let target = TargetOverlay.ringTarget(for: a)
        let dot = TargetOverlay.ringDotGeo(
            at: CGPoint(x: target.rect.midX, y: target.rect.midY))
        XCTAssertEqual(overlay.ringMorph.from.rect, dot.rect)
        XCTAssertTrue(overlay.ringArmed)

        t = 0.08                                       // mid acquire-morph
        overlay.intentEvent(.release(a))
        XCTAssertFalse(overlay.ringArmed)              // fade = no claim
        let releaseFrom = overlay.ringMorph.from
        let expectedMid = TargetOverlay.lerpRing(
            from: dot, to: target, t: TargetOverlay.ringEase(0.5))
        XCTAssertEqual(releaseFrom.rect, expectedMid.rect)
        XCTAssertEqual(overlay.ringMorph.to.rect, dot.rect)

        t = 0.12                                       // mid release-morph
        let b = intentCandidate(x: 300, y: 100, w: 40, h: 40, id: "b")
        overlay.intentEvent(.acquire(b))
        let continued = TargetOverlay.lerpRing(
            from: releaseFrom, to: dot, t: TargetOverlay.ringEase(0.25))
        XCTAssertEqual(overlay.ringMorph.from.rect, continued.rect)
        XCTAssertEqual(overlay.ringMorph.to.rect,
                       TargetOverlay.ringTarget(for: b).rect)
        XCTAssertTrue(overlay.ringArmed)
        overlay.hideAll()
    }

    /// A hold carrying a moved frame retargets the morph at the faster
    /// retarget duration instead of snapping.
    func testHoldRetargetsWhenTheElementMoved() {
        let overlay = TargetOverlay(presentsPanels: false)
        var t: TimeInterval = 0
        overlay.now = { t }
        let a = intentCandidate(x: 100, y: 100, w: 120, h: 28, id: "a")
        overlay.intentEvent(.acquire(a))
        t = 0.5
        let moved = IntentCandidate(id: "a", kind: .axElement,
                                    frame: CGRect(x: 104, y: 100, width: 120, height: 28),
                                    motorRect: CGRect(x: 104, y: 100, width: 120, height: 28),
                                    role: "AXButton", label: "a")
        overlay.intentEvent(.hold(moved, progress: 0.5))
        XCTAssertEqual(overlay.ringMorph.to.rect,
                       TargetOverlay.ringTarget(for: moved).rect)
        XCTAssertEqual(overlay.ringMorph.duration,
                       TargetOverlay.ringRetargetSeconds, accuracy: 0.001)
        overlay.hideAll()
    }

    // MARK: - Conforming ring: lifecycle + ambiguity

    /// `.none` on a fresh overlay is a no-op; after an acquire it drops
    /// the ring's claim.
    func testNoneAndReleaseAreSafe() {
        let overlay = TargetOverlay(presentsPanels: false)
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

    func testAmbiguityReleasesHighlightWithoutArmingChoices() {
        let overlay = TargetOverlay(presentsPanels: false)
        let a = intentCandidate(x: 0, y: 0, w: 40, h: 40, id: "a")
        let b = intentCandidate(x: 50, y: 0, w: 40, h: 40, id: "b")
        overlay.intentEvent(.acquire(a))
        overlay.intentEvent(.ambiguous([a, b]))
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertFalse(overlay.ringArmed)
        overlay.hideAll()
    }

    func testPassiveHoverIsTransientAndDoesNotImplyDwellOrOutlineWholeWindows() {
        let overlay = TargetOverlay(presentsPanels: false)
        let control = intentCandidate(x: 20, y: 20, w: 40, h: 24)
        overlay.intentEvent(.acquire(control))
        overlay.intentEvent(.hold(control, progress: 0.4))
        XCTAssertTrue(overlay.ringArmed)
        XCTAssertEqual(overlay.ringProgress, 0)
        for progress in [0.55, 0.9, 1.0] {
            overlay.intentEvent(.hold(control, progress: progress))
            XCTAssertFalse(overlay.ringArmed)
        }
        overlay.intentEvent(.acquire(intentCandidate(.window, x: 0, y: 0, w: 800, h: 600)))
        XCTAssertFalse(overlay.ringArmed)
        overlay.hideAll()
    }

    func testHideAllDismissesRing() {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.intentEvent(.acquire(intentCandidate(x: 0, y: 0, w: 40, h: 40)))
        XCTAssertTrue(overlay.ringArmed)
        overlay.hideAll()
        XCTAssertFalse(overlay.ringArmed)
        XCTAssertEqual(overlay.ringProgress, 0, accuracy: 0.001)
    }

    /// Agent stand-down applies to the ring too — acquiring on a frame
    /// an agent is acting on must not fight the agent's cursor.
    func testRingAcquireUnderAgentActivityIsSafe() {
        let overlay = TargetOverlay(presentsPanels: false)
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        overlay.agentChips([frame])
        overlay.intentEvent(.acquire(intentCandidate(x: 0, y: 0, w: 40, h: 40)))
        XCTAssertTrue(overlay.ringArmed)
        overlay.agentChips([])
        overlay.hideAll()
    }
}
