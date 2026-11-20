import XCTest
@testable import Jarvis

/// Contract (L6): "this" binds to the fixation held when the word was
/// said, never a later one; with gaze off or unsure the selection, then
/// focus, then pointer answer, else "which one?"; the answer is an element
/// identity with no coordinates, and the D6 ring flashes on it once.
@MainActor
final class DeicticResolverTests: XCTestCase {

    private func candidate(_ id: String, _ label: String, x: CGFloat = 80) -> IntentCandidate {
        IntentCandidate(id: id, kind: .axElement,
                        frame: CGRect(x: x, y: 80, width: 60, height: 30),
                        motorRect: CGRect(x: x, y: 80, width: 60, height: 30),
                        role: "AXButton", label: label, pid: 42, windowID: 7,
                        appName: "Test", windowTitle: "Doc")
    }

    private lazy var save = candidate("ax:42:7:save", "Save")
    private lazy var cancel = candidate("ax:42:7:cancel", "Cancel", x: 300)

    private func focal(_ c: IntentCandidate, _ confidence: Double) -> GazeReferent {
        GazeReferent(c, confidence: confidence, at: Date())
    }

    /// Save held 10.0–10.8 s, then Cancel from 11.0 s.
    private func lookedAtSaveThenCancel() -> FixationRing {
        var ring = FixationRing()
        ring.record(.acquire(save), focal: nil, at: 10.0)
        ring.record(.hold(save, progress: 0.2), focal: focal(save, 0.8), at: 10.2)
        ring.record(.hold(save, progress: 0.8), focal: focal(save, 0.7), at: 10.8)
        ring.record(.release(save), focal: nil, at: 10.9)
        ring.record(.acquire(cancel), focal: nil, at: 11.0)
        ring.record(.hold(cancel, progress: 0.3), focal: focal(cancel, 0.9), at: 11.3)
        ring.record(.hold(cancel, progress: 0.9), focal: focal(cancel, 0.9), at: 11.9)
        return ring
    }

    // MARK: Fixation ring

    func testWordTimeFixationWinsOverLaterOne() {
        let ring = lookedAtSaveThenCancel()
        XCTAssertEqual(ring.fixation(at: 10.5)?.candidate.id, save.id)
        XCTAssertEqual(ring.fixation(at: 10.5)?.confidence, 0.8)
        XCTAssertEqual(ring.fixation(at: 10.5)?.start, 10.0)
        XCTAssertEqual(ring.fixation(at: 11.5)?.candidate.id, cancel.id)
    }

    func testGapAfterFixationStillBindsButNothingBeforeTheFirst() {
        let ring = lookedAtSaveThenCancel()
        XCTAssertEqual(ring.fixation(at: 10.95)?.candidate.id, save.id, "a blink after leaving Save")
        XCTAssertNil(ring.fixation(at: 9.9), "a fixation that began after the word never counts")
        XCTAssertNil(ring.fixation(at: 12.5), "no fresh tick covers a word this late")
    }

    func testGlanceBelowFocalGateNeverResolves() {
        var ring = FixationRing()
        ring.record(.acquire(save), focal: nil, at: 1.0)
        ring.record(.hold(save, progress: 0.1), focal: nil, at: 1.1)
        XCTAssertNil(ring.fixation(at: 1.05))
    }

    func testRingForgetsPastHorizonAndOnReset() {
        var ring = lookedAtSaveThenCancel()
        ring.record(.hold(cancel, progress: 1), focal: focal(cancel, 0.9), at: 10.8 + FixationRing.horizon + 0.1)
        XCTAssertNil(ring.fixation(at: 10.5))
        XCTAssertEqual(ring.fixation(at: 11.5)?.candidate.id, cancel.id)
        ring.reset()
        XCTAssertNil(ring.fixation(at: 11.5))
    }

    func testServiceAnswersNothingWhileGazeIsOff() {
        let service = GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } }),
                                  defaults: UserDefaults(suiteName: "DeicticResolverTests.\(UUID())")!)
        XCTAssertNil(service.fixation(at: 0))
    }

    // MARK: Resolver

    private func resolver(fixation: GazeFixation?, selection: DeicticResolver.Hit? = nil,
                          focus: DeicticResolver.Hit? = nil, pointer: DeicticResolver.Hit? = nil,
                          asked: @escaping (String) -> Void = { _ in },
                          flashed: @escaping (CGRect) -> Void = { _ in }) -> DeicticResolver {
        let r = DeicticResolver()
        r.fixation = { _ in fixation }
        r.selection = { asked("selection"); return selection }
        r.focus = { asked("focus"); return focus }
        r.pointer = { asked("pointer"); return pointer }
        r.flash = flashed
        return r
    }

    private func axHit(_ source: DeicticReferent.Source, _ label: String) -> DeicticResolver.Hit {
        DeicticResolver.Hit(referent: DeicticReferent(
            id: "axref:9:3:\(label)", source: source, role: "AXTextArea", label: label,
            appName: "Notes", windowTitle: nil, pid: 9, windowID: 3, confidence: nil, element: nil),
            frame: CGRect(x: 10, y: 10, width: 100, height: 20))
    }

    func testGazeAtWordTimeResolvesToIdentityAndFlashesOnce() async {
        var flashes: [CGRect] = []
        var asked: [String] = []
        let fix = lookedAtSaveThenCancel().fixation(at: 10.5)
        let r = resolver(fixation: fix, selection: axHit(.selection, "note"),
                         asked: { asked.append($0) }, flashed: { flashes.append($0) })
        guard case .resolved(let referent) = await r.resolve(wordTime: 10.5) else {
            return XCTFail("expected a referent")
        }
        XCTAssertEqual(referent.id, "ax:42:7:save")
        XCTAssertEqual(referent.source, .gaze)
        XCTAssertEqual(referent.label, "Save")
        XCTAssertEqual(asked, [], "gaze answered, no Accessibility probe runs")
        XCTAssertEqual(flashes, [save.motorRect])
    }

    func testReferentCarriesNoCoordinates() {
        let referent = DeicticResolver.gazeHit(
            GazeFixation(candidate: save, confidence: 0.9, start: 0, end: 1)).referent
        for child in Mirror(reflecting: referent).children {
            let kind = type(of: child.value)
            XCTAssertFalse(kind == CGRect.self || kind == CGPoint.self || kind == CGRect?.self
                           || kind == CGPoint?.self, "\(child.label ?? "?") is a coordinate")
        }
        XCTAssertFalse(referent.contextLine.contains("80"), referent.contextLine)
    }

    func testUnsureGazeFallsBackToSelection() async {
        let unsure = GazeFixation(candidate: save, confidence: 0.39, start: 0, end: 1)
        let r = resolver(fixation: unsure, selection: axHit(.selection, "note"), focus: axHit(.focus, "field"))
        let resolution = await r.resolve(wordTime: 0.5)
        XCTAssertEqual(resolution, .resolved(axHit(.selection, "note").referent))
    }

    func testGazeOffFallsBackSelectionThenFocusThenPointer() async {
        var asked: [String] = []
        let focusOnly = resolver(fixation: nil, focus: axHit(.focus, "field"),
                                 pointer: axHit(.pointer, "link"), asked: { asked.append($0) })
        let focused = await focusOnly.resolve(wordTime: 1)
        XCTAssertEqual(focused, .resolved(axHit(.focus, "field").referent))
        XCTAssertEqual(asked, ["selection", "focus"])

        let pointerOnly = resolver(fixation: nil, pointer: axHit(.pointer, "link"))
        let pointed = await pointerOnly.resolve(wordTime: 1)
        XCTAssertEqual(pointed, .resolved(axHit(.pointer, "link").referent))
    }

    func testNothingToPointAtAsksWhichOneWithoutFlashing() async {
        var flashes = 0
        let r = resolver(fixation: nil, flashed: { _ in flashes += 1 })
        let resolution = await r.resolve(wordTime: 1)
        XCTAssertEqual(resolution, .whichOne)
        XCTAssertEqual(flashes, 0)
    }

    // MARK: Flash ring

    func testFlashPanelIsHiddenFromCaptureAndMouse() {
        let panel = DeicticFlash.makePanel()
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey)
    }
}
