import XCTest
@testable import JevVoice

/// Contract: the Fn state machine turns `flagsChanged` keycode-63 events
/// into begin/finish/cancel decisions. This is the unit-testable half of
/// physical Fn behavior — the event-tap half is `JARVIS_LIVE_INPUT` in
/// `LiveInputTests`.
final class FnInputStateTests: XCTestCase {

    private var state = FnInputState()

    /// The canonical PTT cycle: Fn down begins a capture, Fn up finishes it.
    func testFnDownUpBeginsAndFinishes() {
        let down = state.handle(.flagsChanged, key: 63, fn: true, now: 0,
                                canBegin: true, active: false)
        XCTAssertEqual(down.action, .begin)
        XCTAssertTrue(down.consume)

        let up = state.handle(.flagsChanged, key: 63, fn: false, now: 0.3,
                              canBegin: true, active: false)
        XCTAssertEqual(up.action, .finish)
        XCTAssertTrue(up.consume)
    }

    /// A Fn event with no capture consumer must not arm — the hold is
    /// consumed but nothing begins (fail closed, never half-capture).
    func testFnDownWithoutConsumerDoesNotArm() {
        let down = state.handle(.flagsChanged, key: 63, fn: true, now: 0,
                                canBegin: false, active: false)
        XCTAssertEqual(down.action, .none)
        let up = state.handle(.flagsChanged, key: 63, fn: false, now: 0.3,
                              canBegin: false, active: false)
        XCTAssertEqual(up.action, .none)
    }

    /// Fn+Ctrl begins a dictation capture when the seam is enabled.
    func testDictationChordBeginsDictation() {
        state.dictationEnabled = true
        let down = state.handle(.flagsChanged, key: 63, fn: true,
                                otherModifiers: true, dictationChord: true,
                                now: 0, canBegin: true, active: false)
        XCTAssertEqual(down.action, .begin)
        XCTAssertTrue(down.dictation)

        let up = state.handle(.flagsChanged, key: 63, fn: false, now: 0.5,
                              canBegin: true, active: false)
        XCTAssertEqual(up.action, .finish)
    }

    /// Ctrl joining an already-armed Fn hold converts it to dictation
    /// mid-hold — the Fn+Ctrl sequence users actually press.
    func testMidHoldCtrlConvertsToDictation() {
        state.dictationEnabled = true
        let down = state.handle(.flagsChanged, key: 63, fn: true, now: 0,
                                canBegin: true, active: false)
        XCTAssertEqual(down.action, .begin)
        XCTAssertFalse(down.dictation)

        let ctrl = state.handle(.flagsChanged, key: 59, fn: true,
                                otherModifiers: true, dictationChord: true,
                                now: 0.2, canBegin: true, active: false)
        XCTAssertTrue(ctrl.dictation)
    }

    /// An armed Fn+Ctrl chord with the dictation seam disabled falls back
    /// to a normal hold — never a planner capture.
    func testArmedChordWithoutSeamFailsClosed() {
        let down = state.handle(.flagsChanged, key: 63, fn: true,
                                otherModifiers: true, dictationChord: true,
                                now: 0, canBegin: true, active: false)
        XCTAssertEqual(down.action, .none)
        XCTAssertFalse(down.dictation)
    }

    /// A stray keydown during an armed Fn hold cancels the capture —
    /// "Fn then typed" is never a recording.
    func testKeyDuringHoldCancelsCapture() {
        let down = state.handle(.flagsChanged, key: 63, fn: true, now: 0,
                                canBegin: true, active: false)
        XCTAssertEqual(down.action, .begin)
        let key = state.handle(.keyDown, key: 0 /* A */, fn: true, now: 0.1,
                               canBegin: true, active: false)
        XCTAssertEqual(key.action, .cancelCapture)
        // And the release reports nothing — the capture was cancelled.
        let up = state.handle(.flagsChanged, key: 63, fn: false, now: 0.3,
                              canBegin: true, active: false)
        XCTAssertEqual(up.action, .none)
    }

    /// An Escape during an active capture cancels it — and the event is
    /// consumed so the frontmost app never sees it.
    func testEscapeCancelsActiveCapture() {
        _ = state.handle(.flagsChanged, key: 63, fn: true, now: 0,
                         canBegin: true, active: false)
        let esc = state.handle(.keyDown, key: 53, fn: true, now: 0.2,
                               canBegin: true, active: true)
        XCTAssertEqual(esc.action, .cancel)
        XCTAssertTrue(esc.consume)
    }

    /// A missed Fn release is the fail-closed case: `interrupt()` kills the
    /// armed state, and `held` survives so the same physical hold can't
    /// re-arm — the health check's synthesized release then finishes clean.
    func testInterruptKeepsHeldAndDisarms() {
        _ = state.handle(.flagsChanged, key: 63, fn: true, now: 0,
                         canBegin: true, active: false)
        state.interrupt()
        // A phantom re-press while physically held must not re-arm — the
        // tap synthesizes the missed release first.
        let replay = state.handle(.flagsChanged, key: 63, fn: true, now: 0.5,
                                  canBegin: true, active: false)
        XCTAssertEqual(replay.action, .none)
        let up = state.handle(.flagsChanged, key: 63, fn: false, now: 0.6,
                              canBegin: true, active: false)
        XCTAssertEqual(up.action, .none)
    }

    /// Latch mode: a tap shorter than the threshold latches on release;
    /// the next Fn down finishes the capture.
    func testLatchMode() {
        state.latchMode = true
        _ = state.handle(.flagsChanged, key: 63, fn: true, now: 0,
                         canBegin: true, active: false)
        let up = state.handle(.flagsChanged, key: 63, fn: false, now: 0.1,
                              canBegin: true, active: false)
        XCTAssertEqual(up.action, .finish)
        XCTAssertTrue(up.latch)

        let second = state.handle(.flagsChanged, key: 63, fn: true, now: 5,
                                  canBegin: true, active: false)
        XCTAssertEqual(second.action, .finish)
    }
}
