import CoreGraphics
import XCTest
@testable import JevVoice

@MainActor
final class FnInputMonitorReleaseTests: XCTestCase {
    func testCancelledHoldStillReportsItsPhysicalReleaseWithoutAnotherAction() {
        let monitor = held(interrupted: true)
        var physical: [Bool] = []
        var actions: [FnInputState.Action] = []
        monitor.onPhysicalFnChanged = { physical.append($0) }
        monitor.onAction = { actions.append($0) }
        monitor.reconcilePhysicalFn(isDown: true, now: 0.1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1)
        XCTAssertEqual(physical, [true])
        monitor.reconcilePhysicalFn(isDown: false, now: 1.2)
        XCTAssertEqual(physical, [true, false])
        XCTAssertTrue(actions.isEmpty)
    }

    private func held(latch: Bool = false, dictation: Bool = false, interrupted: Bool = false) -> FnInputMonitor {
        var state = FnInputState()
        state.latchMode = latch
        state.dictationEnabled = dictation
        _ = state.handle(.flagsChanged, key: 63, fn: true, dictationChord: dictation,
                         now: 0, canBegin: true, active: false)
        if interrupted { state.interrupt() }
        return FnInputMonitor(state: state)
    }

    private func release(_ monitor: FnInputMonitor) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: false))
        event.type = .flagsChanged
        event.flags = []
        _ = monitor.handle(.flagsChanged, event)
    }

    func testConfirmedPhysicalReleaseFinishesOnceWithoutDiscardingCapture() throws {
        let monitor = held()
        var actions: [FnInputState.Action] = []
        var failures: [String] = []
        monitor.onAction = { actions.append($0) }
        monitor.onInterruption = { failures.append($0) }
        monitor.reconcilePhysicalFn(isDown: true, now: 0.1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1)
        XCTAssertTrue(actions.isEmpty)
        monitor.reconcilePhysicalFn(isDown: false, now: 1.2)
        XCTAssertEqual(actions, [.finish])
        XCTAssertTrue(failures.isEmpty)
        try release(monitor)
        monitor.reconcilePhysicalFn(isDown: false, now: 1.4)
        XCTAssertEqual(actions, [.finish])
    }

    func testQueuedRealReleaseWinsWithoutSecondHealthTick() throws {
        let monitor = held()
        var actions: [FnInputState.Action] = []
        var failures: [String] = []
        monitor.onAction = { actions.append($0) }
        monitor.onInterruption = { failures.append($0) }
        monitor.reconcilePhysicalFn(isDown: true, now: 0.1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1)
        try release(monitor)
        XCTAssertEqual(actions, [.finish])
        monitor.reconcilePhysicalFn(isDown: false, now: 1.2)
        XCTAssertEqual(actions, [.finish])
        XCTAssertTrue(failures.isEmpty)
    }

    func testTransientPhysicalUpDoesNotFinishOrInterrupt() {
        let monitor = held()
        var actions: [FnInputState.Action] = []
        var failures: [String] = []
        monitor.onAction = { actions.append($0) }
        monitor.onInterruption = { failures.append($0) }
        monitor.reconcilePhysicalFn(isDown: true, now: 0.1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1)
        monitor.reconcilePhysicalFn(isDown: true, now: 1.2)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }

    func testUnobservedPhysicalHoldNeverSynthesizesRelease() {
        let monitor = held()
        var actions: [FnInputState.Action] = []
        monitor.onAction = { actions.append($0) }
        monitor.reconcilePhysicalFn(isDown: false, now: 1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1.2)
        XCTAssertTrue(actions.isEmpty)
    }

    func testInterruptedHoldCannotRearmOrFinish() {
        let monitor = held(interrupted: true)
        var actions: [FnInputState.Action] = []
        var failures: [String] = []
        monitor.onAction = { actions.append($0) }
        monitor.onInterruption = { failures.append($0) }
        monitor.reconcilePhysicalFn(isDown: true, now: 0.1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1.2)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }

    func testRecoveredDictationUsesNormalFinish() {
        let monitor = held(dictation: true)
        var actions: [FnInputState.Action] = []
        var converted = 0
        monitor.onAction = { actions.append($0) }
        monitor.onDictationConvert = { converted += 1 }
        monitor.reconcilePhysicalFn(isDown: true, now: 0.1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1)
        monitor.reconcilePhysicalFn(isDown: false, now: 1.2)
        XCTAssertEqual(actions, [.finish])
        XCTAssertEqual(converted, 0)
    }

    func testRecoveredTapLatchUsesFirstPhysicalUpTime() {
        let monitor = held(latch: true)
        var latches = 0
        var actions: [FnInputState.Action] = []
        monitor.onLatch = { latches += 1 }
        monitor.onAction = { actions.append($0) }
        monitor.reconcilePhysicalFn(isDown: true, now: 0.1)
        monitor.reconcilePhysicalFn(isDown: false, now: 0.3)
        monitor.reconcilePhysicalFn(isDown: false, now: 0.5)
        XCTAssertEqual(latches, 1)
        XCTAssertEqual(actions, [.finish])
    }
}
