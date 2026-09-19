import XCTest
@testable import JevVoice

final class FnInputTests: XCTestCase {
    func testHoldProducesOneBeginAndOneFinish() {
        var input = FnInputState()
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .begin)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: true).action, .none)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: false, canBegin: false, active: true).action, .finish)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: false, canBegin: true, active: false).action, .none)
    }

    func testIgnoredBusyHoldCannotStartWhenOperationFinishes() {
        var input = FnInputState()
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: false, active: true).action, .none)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .none)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: false, canBegin: true, active: false).action, .none)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .begin)
    }

    func testFnCombinationCancelsAndPassesThrough() {
        var input = FnInputState()
        _ = input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false)
        let arrow = input.handle(.keyDown, key: 123, fn: true, canBegin: false, active: true)
        XCTAssertEqual(arrow.action, .cancel)
        XCTAssertFalse(arrow.consume)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: false, canBegin: true, active: false).action, .none)
    }

    func testOtherModifierAndFunctionFlagOnArrowNeverStart() {
        var input = FnInputState()
        XCTAssertEqual(input.handle(.keyDown, key: 123, fn: true, canBegin: true, active: false).action, .none)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, otherModifiers: true, canBegin: true, active: false).action, .none)
    }

    func testEscapePairIsConsumedOnlyForActiveOperation() {
        var input = FnInputState()
        XCTAssertFalse(input.handle(.keyDown, key: 53, fn: false, canBegin: true, active: false).consume)
        let down = input.handle(.keyDown, key: 53, fn: false, canBegin: false, active: true)
        XCTAssertEqual(down.action, .cancel)
        XCTAssertTrue(down.consume)
        XCTAssertTrue(input.handle(.keyUp, key: 53, fn: false, canBegin: true, active: false).consume)
        XCTAssertFalse(input.handle(.keyUp, key: 53, fn: false, canBegin: true, active: false).consume)
    }

    func testEscapeRepeatsStayConsumedAfterCancellation() {
        var input = FnInputState()
        _ = input.handle(.keyDown, key: 53, fn: false, canBegin: false, active: true)
        let repeated = input.handle(.keyDown, key: 53, fn: false, canBegin: true, active: false)
        XCTAssertTrue(repeated.consume)
        XCTAssertEqual(repeated.action, .none)
        XCTAssertTrue(input.handle(.keyUp, key: 53, fn: false, canBegin: true, active: false).consume)
    }

    func testKeyHeldBeforeFnDoesNotArmRecording() {
        var input = FnInputState()
        _ = input.handle(.keyDown, key: 49, fn: false, canBegin: true, active: false)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .none)
        _ = input.handle(.keyUp, key: 49, fn: true, canBegin: true, active: false)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: false, canBegin: true, active: false).action, .none)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .begin)
    }

    func testInterruptionRequiresAReleaseBeforeNewHold() {
        var input = FnInputState()
        _ = input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false)
        input.interrupt()
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .none)
        _ = input.handle(.flagsChanged, key: 63, fn: false, canBegin: true, active: false)
        XCTAssertEqual(input.handle(.flagsChanged, key: 63, fn: true, canBegin: true, active: false).action, .begin)
    }
}
