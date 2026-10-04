import XCTest
@testable import JevVoice

final class FnDictationLatchTests: XCTestCase {
    func testControlFirstChordBeginsDictation() {
        var input = FnInputState()
        input.dictationEnabled = true
        _ = input.handle(.flagsChanged, key: 59, fn: false, dictationChord: true, canBegin: true, active: false)
        let down = input.handle(.flagsChanged, key: 63, fn: true, dictationChord: true,
                                canBegin: true, active: false)
        XCTAssertEqual(down.action, .begin)
        XCTAssertTrue(down.dictation)
        XCTAssertTrue(down.consume)
        let up = input.handle(.flagsChanged, key: 63, fn: false, canBegin: false, active: true)
        XCTAssertEqual(up.action, .finish)
        XCTAssertFalse(up.dictation)
    }

    func testFnThenCtrlConvertsHoldToDictation() {
        var input = FnInputState()
        input.dictationEnabled = true
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .begin)
        let ctrl = input.handle(.flagsChanged, key: 59, fn: true, otherModifiers: true,
                                dictationChord: true, canBegin: false, active: true)
        XCTAssertEqual(ctrl.action, .none)
        XCTAssertTrue(ctrl.dictation)
        XCTAssertTrue(ctrl.consume)
        // Once dictating, stray keys pass through instead of cancelling.
        XCTAssertEqual(input.handle(.keyDown, key: 0, fn: true, canBegin: false, active: true).action, .none)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: false, canBegin: false, active: true).action, .finish)
    }

    func testRightControlJoinsHoldAsDictation() {
        var input = FnInputState()
        input.dictationEnabled = true
        _ = input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false)
        let ctrl = input.handle(.flagsChanged, key: 62, fn: true, otherModifiers: true,
                                dictationChord: true, canBegin: false, active: true)
        XCTAssertTrue(ctrl.dictation)
    }

    func testChordWithExtraModifierIsNotDictation() {
        var input = FnInputState()
        // Ctrl+Option+Fn — dictationChord must be false; the hold stays plain.
        let down = input.handle(.flagsChanged, key: 63, fn: true, otherModifiers: true,
                                dictationChord: false, canBegin: true, active: false)
        XCTAssertEqual(down.action, .none)
        XCTAssertFalse(down.dictation)
    }

    func testDictationChordDisabledByDefault() {
        var input = FnInputState()
        _ = input.handle(.flagsChanged, key: 59, fn: false, dictationChord: true, canBegin: true, active: false)
        let down = input.handle(.flagsChanged, key: 63, fn: true, otherModifiers: true,
                                dictationChord: true, canBegin: true, active: false)
        XCTAssertEqual(down.action, .none)
        XCTAssertFalse(down.dictation)
        XCTAssertFalse(down.consume)
    }

    /// With the chord disabled a mid-hold Ctrl must behave exactly as it did
    /// before the chord existed: fall through to `.cancelCapture`, consumed
    /// by neither the dictation gate nor the tap.
    func testDisabledChordMidHoldCtrlFallsThroughToCancelCapture() {
        var input = FnInputState()
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .begin)
        let ctrl = input.handle(.flagsChanged, key: 59, fn: true, otherModifiers: true,
                                dictationChord: true, canBegin: false, active: true)
        XCTAssertEqual(ctrl.action, .cancelCapture)
        XCTAssertFalse(ctrl.dictation)
        XCTAssertFalse(ctrl.consume)
    }

    /// A dictation `.begin` may never surface through `onAction` — even with
    /// the dictation seams unbound the event is consumed as `.none` so
    /// dictated speech cannot reach the planner.
    @MainActor
    func testDictationBeginNeverReachesOnAction() {
        let monitor = FnInputMonitor()
        var actions: [FnInputState.Action] = []
        var began = 0
        monitor.onAction = { actions.append($0) }
        monitor.onDictationBegin = { began += 1 }
        monitor.dispatch(.init(action: .begin, consume: true, dictation: true))
        XCTAssertEqual(began, 1)
        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testUnwiredDictationBeginIsConsumedWithoutOnAction() {
        let monitor = FnInputMonitor()
        var actions: [FnInputState.Action] = []
        monitor.onAction = { actions.append($0) }
        monitor.dispatch(.init(action: .begin, consume: true, dictation: true))
        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testDictationConvertFiresOnlyTheConvertSeam() {
        let monitor = FnInputMonitor()
        var actions: [FnInputState.Action] = []
        var converted = 0
        monitor.onAction = { actions.append($0) }
        monitor.onDictationConvert = { converted += 1 }
        monitor.dispatch(.init(consume: true, dictation: true))
        XCTAssertEqual(converted, 1)
        XCTAssertTrue(actions.isEmpty)
    }

    func testDictationChordWhileBusyDoesNotBegin() {
        var input = FnInputState()
        input.dictationEnabled = true
        let down = input.handle(.flagsChanged, key: 63, fn: true, dictationChord: true,
                                canBegin: false, active: true)
        XCTAssertEqual(down.action, .none)
        XCTAssertFalse(down.dictation)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: false, canBegin: true, active: false).action, .none)
    }

    func testLatchTapKeepsCaptureUntilSecondTap() {
        var input = FnInputState()
        input.latchMode = true
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, now: 10,
                                    canBegin: true, active: false).action, .begin)
        let up = input.handle(.flagsChanged, key: 63, fn: false, now: 10.2,
                              canBegin: false, active: true)
        XCTAssertEqual(up.action, .finish)
        XCTAssertTrue(up.latch)
        XCTAssertTrue(input.latched)
        // The second tap stops the capture at Fn down.
        let tap = input.handle(.flagsChanged, key: 63, fn: true, now: 12,
                               canBegin: false, active: true)
        XCTAssertEqual(tap.action, .finish)
        XCTAssertFalse(tap.latch)
        XCTAssertFalse(input.latched)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: false, now: 12.1,
                                    canBegin: true, active: false).action, .none)
    }

    func testHoldBeyondThresholdStillFinishesOnRelease() {
        var input = FnInputState()
        input.latchMode = true
        _ = input.handle(.flagsChanged, key: 63, fn: true, now: 0, canBegin: true, active: false)
        let up = input.handle(.flagsChanged, key: 63, fn: false, now: 1.0,
                              canBegin: false, active: true)
        XCTAssertEqual(up.action, .finish)
        XCTAssertFalse(up.latch)
        XCTAssertFalse(input.latched)
    }

    func testLatchOffByDefault() {
        var input = FnInputState()
        _ = input.handle(.flagsChanged, key: 63, fn: true, now: 0, canBegin: true, active: false)
        let up = input.handle(.flagsChanged, key: 63, fn: false, now: 0.1,
                              canBegin: false, active: true)
        XCTAssertEqual(up.action, .finish)
        XCTAssertFalse(up.latch)
        XCTAssertFalse(input.latched)
    }

    func testDictationHoldNeverLatches() {
        var input = FnInputState()
        input.dictationEnabled = true
        input.latchMode = true
        _ = input.handle(.flagsChanged, key: 63, fn: true, dictationChord: true, now: 0,
                         canBegin: true, active: false)
        let up = input.handle(.flagsChanged, key: 63, fn: false, dictationChord: true, now: 0.1,
                              canBegin: false, active: true)
        XCTAssertEqual(up.action, .finish)
        XCTAssertFalse(up.latch)
        XCTAssertFalse(input.latched)
    }

    func testIgnoredHoldDoesNotLatch() {
        var input = FnInputState()
        input.latchMode = true
        _ = input.handle(.flagsChanged, key: 63, fn: true, now: 0, canBegin: false, active: true)
        let up = input.handle(.flagsChanged, key: 63, fn: false, now: 0.1,
                              canBegin: true, active: true)
        XCTAssertEqual(up.action, .none)
        XCTAssertFalse(input.latched)
    }

    func testEscapeCancelsLatchedCapture() {
        var input = FnInputState()
        input.latchMode = true
        _ = input.handle(.flagsChanged, key: 63, fn: true, now: 0, canBegin: true, active: false)
        _ = input.handle(.flagsChanged, key: 63, fn: false, now: 0.1, canBegin: false, active: true)
        let escape = input.handle(.keyDown, key: 53, fn: false, canBegin: false, active: true)
        XCTAssertEqual(escape.action, .cancel)
        XCTAssertTrue(escape.consume)
        XCTAssertFalse(input.latched)
    }

    func testInterruptClearsLatch() {
        var input = FnInputState()
        input.latchMode = true
        _ = input.handle(.flagsChanged, key: 63, fn: true, now: 0, canBegin: true, active: false)
        _ = input.handle(.flagsChanged, key: 63, fn: false, now: 0.1, canBegin: false, active: true)
        XCTAssertTrue(input.latched)
        input.interrupt()
        XCTAssertFalse(input.latched)
    }
}
