import CoreGraphics
import XCTest
@testable import JevVoice

final class RestrictedFnObservationTests: XCTestCase {
    private func tap(_ id: UInt32, pid: pid_t = 42, target: pid_t = 0,
                     point: CGEventTapLocation = .cgSessionEventTap, options: CGEventTapOptions = .defaultTap,
                     mask: CGEventMask = RestrictedFnTapInventory.keyboardMask,
                     enabled: Bool = true) -> CGEventTapInformation {
        var row = CGEventTapInformation()
        row.eventTapID = id
        row.tappingProcess = pid
        row.processBeingTapped = target
        row.tapPoint = point
        row.options = options
        row.eventsOfInterest = mask
        row.enabled = enabled
        return row
    }

    func testPinsOnlyTheNewOwnedEnabledDefaultSessionTap() {
        let old = tap(1), other = tap(2, pid: 55)
        let before = RestrictedFnTapInventory([old, other], owner: 42)
        func pin(_ rows: [CGEventTapInformation]) -> UInt32? {
            RestrictedFnTapInventory.installedID(before: before, after: RestrictedFnTapInventory(rows, owner: 42))
        }
        XCTAssertEqual(pin([tap(3), old, tap(4, pid: 56)]), 3)
        XCTAssertNil(pin([old, tap(3, pid: 56)]))
        XCTAssertNil(pin([old, tap(3), tap(4)]))
        XCTAssertNil(pin([old, tap(3), tap(3)]))
        XCTAssertNil(pin([tap(3)]))
        for row in [tap(3, target: 18), tap(3, point: .cghidEventTap), tap(3, options: .listenOnly),
                    tap(3, enabled: false)] {
            XCTAssertNil(pin([old, row]))
        }
        for type in [CGEventType.flagsChanged, .keyDown, .keyUp] {
            let partial = RestrictedFnTapInventory.keyboardMask & ~(CGEventMask(1) << type.rawValue)
            XCTAssertNil(pin([old, tap(3, mask: partial)]))
        }
    }

    func testUnavailableInventoryNeverPinsATap() {
        let empty = RestrictedFnTapInventory([CGEventTapInformation](), owner: 42)
        let full = RestrictedFnTapInventory([tap(1)], owner: 42)
        XCTAssertNil(RestrictedFnTapInventory.installedID(before: nil, after: full))
        XCTAssertNil(RestrictedFnTapInventory.installedID(before: empty, after: nil))
        XCTAssertNil(RestrictedFnTapInventory.installedID(before: nil, after: nil))
    }

    func testInitialHealthyUpNeedsNoPressButCannotBeInferredByAReader() throws {
        var observation = RestrictedFnObservation()
        let now = ContinuousClock.now
        observation.sample(fnDown: false, at: now, heartbeat: false)
        XCTAssertNil(observation.generation)
        observation.sample(fnDown: false, at: now, heartbeat: true)
        let token = try XCTUnwrap(observation.generation)
        observation.sample(fnDown: false, at: now.advanced(by: .milliseconds(200)), heartbeat: false)
        XCTAssertEqual(observation.generation, token)
    }

    func testAlreadyHeldAtStartupCannotAuthorize() {
        var observation = RestrictedFnObservation()
        observation.sample(fnDown: true, at: .now, heartbeat: true)
        XCTAssertNil(observation.generation)
    }

    func testLossOrTakeoverNeverRestoresAnOldTurn() throws {
        let now = ContinuousClock.now
        for loss: Bool? in [nil, true] {
            var observation = RestrictedFnObservation()
            observation.sample(fnDown: false, at: now, heartbeat: true)
            let onset = try XCTUnwrap(observation.generation)
            observation.sample(fnDown: loss, at: now, heartbeat: false)
            XCTAssertNil(observation.generation)
            observation.sample(fnDown: false, at: now, heartbeat: false)
            XCTAssertNil(observation.generation)
            observation.sample(fnDown: false, at: now, heartbeat: true)
            XCTAssertNotEqual(try XCTUnwrap(observation.generation), onset)
            observation.invalidate()
            XCTAssertNil(observation.generation)
        }
    }

    func testPreWriteReadsCannotRenewAnOverdueHeartbeat() throws {
        let now = ContinuousClock.now
        var observation = RestrictedFnObservation()
        observation.sample(fnDown: false, at: now, heartbeat: true)
        let onset = try XCTUnwrap(observation.generation)
        let deadline = now.advanced(by: RestrictedFnObservation.maximumGap)
        observation.sample(fnDown: false, at: deadline, heartbeat: false)
        XCTAssertEqual(observation.generation, onset)
        observation.sample(fnDown: false, at: deadline.advanced(by: .milliseconds(1)), heartbeat: false)
        XCTAssertNil(observation.generation)
        observation.sample(fnDown: false, at: deadline.advanced(by: .milliseconds(2)), heartbeat: true)
        XCTAssertNotEqual(try XCTUnwrap(observation.generation), onset)
    }

    func testRestrictedAdapterReturnsEveryEventAndEscapeCancelsAfterInvalidating() throws {
        for (type, key, flags, expected): (CGEventType, CGKeyCode, CGEventFlags, [String]) in [
            (.flagsChanged, 63, .maskSecondaryFn, ["invalidate"]),
            (.flagsChanged, 63, [], []), (.keyDown, 0, [], []),
            (.keyDown, 53, [], ["invalidate", "escape"]), (.keyUp, 53, [], []),
            (.tapDisabledByTimeout, 0, [], ["invalidate"]),
            (.tapDisabledByUserInput, 0, [], ["invalidate"])
        ] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type != .keyUp))
            event.flags = flags
            var callbacks: [String] = []
            let result = RestrictedFnObservation.passThrough(type, event, invalidate: {
                callbacks.append("invalidate")
            }, escape: { callbacks.append("escape") })
            XCTAssertTrue(result.takeUnretainedValue() === event)
            XCTAssertEqual(callbacks, expected)
        }
    }
}
