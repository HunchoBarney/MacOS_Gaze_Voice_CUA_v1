import Foundation
import XCTest
@testable import JevVoice

final class MicrophoneInputTests: XCTestCase {
    func testReadinessRequiresCurrentLivePCMAndCanResolveOnlyOnce() {
        let generation = UUID()
        var state = MicrophoneInput.PreparationState(generation: generation)
        let tap = state.tapID
        XCTAssertEqual(state.input(generation: UUID(), tap: tap, frames: 1024, validTime: true, running: true), .wait)
        XCTAssertEqual(state.input(generation: generation, tap: UUID(), frames: 1024, validTime: true, running: true), .wait)
        XCTAssertEqual(state.input(generation: generation, tap: tap, frames: 0, validTime: true, running: true), .wait)
        XCTAssertEqual(state.input(generation: generation, tap: tap, frames: 1024, validTime: false, running: true), .wait)
        XCTAssertEqual(state.input(generation: generation, tap: tap, frames: 1024, validTime: true, running: false), .wait)
        XCTAssertEqual(state.input(generation: generation, tap: tap, frames: 1024, validTime: true, running: true), .ready)
        XCTAssertEqual(state.input(generation: generation, tap: tap, frames: 1024, validTime: true, running: true), .wait)
        XCTAssertFalse(state.invalidate())
    }

    func testStartupRecoveryIsBoundedAndOldTapCannotMakeReplacementReady() {
        let generation = UUID()
        var state = MicrophoneInput.PreparationState(generation: generation)
        let oldTap = state.tapID
        XCTAssertEqual(state.configuration(sameDevice: true, sameFormat: true, running: false), .recover)
        XCTAssertNotEqual(state.tapID, oldTap)
        XCTAssertEqual(state.input(generation: generation, tap: oldTap, frames: 1024, validTime: true, running: true), .wait)
        XCTAssertEqual(state.configuration(sameDevice: true, sameFormat: true, running: true), .wait)
        XCTAssertEqual(state.configuration(sameDevice: true, sameFormat: true, running: false), .fail)
        XCTAssertEqual(state.input(generation: generation, tap: state.tapID, frames: 1024, validTime: true, running: true), .wait)
    }

    func testChangedDeviceOrFormatNeverRecoversIntoReady() {
        for change in [(false, true), (true, false)] {
            var state = MicrophoneInput.PreparationState(generation: UUID())
            XCTAssertEqual(state.configuration(sameDevice: change.0, sameFormat: change.1, running: false), .fail)
            XCTAssertEqual(state.configuration(sameDevice: true, sameFormat: true, running: false), .fail)
        }
    }

    func testCancellationOrTimeoutCannotPublishReadinessFromLateCallbacks() {
        let generation = UUID()
        var state = MicrophoneInput.PreparationState(generation: generation)
        XCTAssertTrue(state.invalidate())
        XCTAssertFalse(state.invalidate())
        XCTAssertEqual(state.input(generation: generation, tap: state.tapID, frames: 1024, validTime: true, running: true), .wait)
        XCTAssertEqual(state.configuration(sameDevice: true, sameFormat: true, running: false), .fail)
    }

    func testPostReadyStoppedEngineRemainsAnInterruption() {
        XCTAssertEqual(MicrophoneInput.configurationResponse(engineRunning: false, sameDevice: true, sameFormat: true), .interrupt)
        XCTAssertEqual(MicrophoneInput.configurationResponse(engineRunning: true, sameDevice: true, sameFormat: false), .interrupt)
        XCTAssertEqual(MicrophoneInput.configurationResponse(engineRunning: true, sameDevice: false, sameFormat: true), .interrupt)
        XCTAssertEqual(MicrophoneInput.configurationResponse(engineRunning: true, sameDevice: true, sameFormat: true), .restoreTap)
    }
}
