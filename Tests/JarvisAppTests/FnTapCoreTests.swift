import CoreGraphics
import XCTest
@testable import Jarvis

/// The tap thread asks the main actor for gates only on an Fn press or an
/// Escape; every other keystroke is decided from the tap's own state.
final class FnTapCoreTests: XCTestCase {
    private func event(_ key: CGKeyCode, type: CGEventType, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type != .keyUp))
        event.type = type
        event.flags = flags
        return event
    }

    func testOnlyFnPressAndEscapeWaitForMainActorGates() throws {
        let core = FnTapCore(state: FnInputState())
        var asked: [Bool] = []
        let gates: (Bool) -> FnTapCore.Gates = { needs in
            asked.append(needs)
            return FnTapCore.Gates(canBegin: true, active: false)
        }
        _ = core.decide(.keyDown, try event(0, type: .keyDown), gates: gates)
        _ = core.decide(.keyUp, try event(0, type: .keyUp), gates: gates)
        let press = core.decide(.flagsChanged, try event(63, type: .flagsChanged, flags: .maskSecondaryFn), gates: gates)
        let release = core.decide(.flagsChanged, try event(63, type: .flagsChanged), gates: gates)
        _ = core.decide(.keyDown, try event(53, type: .keyDown), gates: gates)
        XCTAssertEqual(asked, [false, false, true, false, true])
        XCTAssertTrue(press.fnKey)
        XCTAssertEqual(press.result.action, .begin)
        XCTAssertTrue(press.result.consume)
        XCTAssertEqual(release.result.action, .finish)
    }

    func testDisabledTapIsReportedAsAnInterruptionAndPassesThrough() throws {
        let core = FnTapCore(state: FnInputState())
        let decision = core.decide(.tapDisabledByTimeout, try event(0, type: .keyDown)) { _ in
            XCTFail("an interruption needs no gates")
            return FnTapCore.Gates()
        }
        XCTAssertTrue(decision.interrupted)
        XCTAssertFalse(decision.result.consume)
    }

    @MainActor
    func testBeginOvertakenByAnInterruptionOnMainNeverStartsCapture() throws {
        let monitor = FnInputMonitor()
        var actions: [FnInputState.Action] = []
        monitor.onAction = { actions.append($0) }
        monitor.canBegin = { true }
        let press = monitor.core.decide(.flagsChanged, try event(63, type: .flagsChanged, flags: .maskSecondaryFn)) { _ in
            FnTapCore.Gates(canBegin: true, active: false)
        }
        XCTAssertEqual(press.result.action, .begin)
        monitor.apply(FnTapCore.Decision(interrupted: true))
        monitor.apply(press)
        _ = monitor.handle(.flagsChanged, try event(63, type: .flagsChanged))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(monitor.core.state.withLock { $0.armed })
    }

    @MainActor
    func testBeginNoLongerAllowedOnMainNeverStartsCapture() throws {
        let monitor = FnInputMonitor()
        var actions: [FnInputState.Action] = []
        monitor.onAction = { actions.append($0) }
        monitor.canBegin = { false }
        let press = monitor.core.decide(.flagsChanged, try event(63, type: .flagsChanged, flags: .maskSecondaryFn)) { _ in
            FnTapCore.Gates(canBegin: true, active: false)
        }
        monitor.apply(press)
        _ = monitor.handle(.flagsChanged, try event(63, type: .flagsChanged))
        XCTAssertTrue(actions.isEmpty)
    }

    @MainActor
    func testBeginStillBackedOnMainStartsAndReleaseFinishes() throws {
        let monitor = FnInputMonitor()
        var actions: [FnInputState.Action] = []
        monitor.onAction = { actions.append($0) }
        monitor.canBegin = { true }
        let press = monitor.core.decide(.flagsChanged, try event(63, type: .flagsChanged, flags: .maskSecondaryFn)) { _ in
            FnTapCore.Gates(canBegin: true, active: false)
        }
        monitor.apply(press)
        _ = monitor.handle(.flagsChanged, try event(63, type: .flagsChanged))
        XCTAssertEqual(actions, [.begin, .finish])
    }
}
