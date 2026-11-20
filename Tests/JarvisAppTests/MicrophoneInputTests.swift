import AVFoundation
import Foundation
import XCTest
import os
@testable import Jarvis

final class MicrophoneInputTests: XCTestCase {
    func testTheFrameDeadlineStartsAfterASlowEngineStart() {
        let queue = DispatchQueue(label: "test.microphone")
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let fired = expectation(description: "deadline fired")
        let deadline = DispatchWorkItem {
            events.withLock { $0.append("deadline") }
            fired.fulfill()
        }
        queue.async {
            MicrophoneInput.start({
                Thread.sleep(forTimeInterval: 0.3)
                queue.async { events.withLock { $0.append("frame") } }
            }, thenArm: deadline, after: 0.05, on: queue)
        }
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(events.withLock { $0 }, ["frame", "deadline"])
    }

    func testDuplexReceiptExpiresWhenOutputStopsAdvancingDespiteLiveInput() {
        var state = MicrophoneInput.DuplexReadiness()
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 100, healthy: true, now: 10))
        XCTAssertTrue(state.observe(inputFrames: 1024, outputSample: 200, healthy: true, now: 10.1))
        XCTAssertTrue(state.observe(inputFrames: 1024, outputSample: 200, healthy: true, now: 10.2))
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 200, healthy: true, now: 10.7))
        XCTAssertNil(state.advancedAt)
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 300, healthy: true, now: 11))
        XCTAssertTrue(state.observe(inputFrames: 1024, outputSample: 400, healthy: true, now: 11.1))
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 1, healthy: true, now: 11.2))
        XCTAssertNil(state.advancedAt)
    }

    func testClosingAnOldFeedCannotCloseOrClearItsReplacement() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let old = try ConvertedAudioFeed(input: format, output: format)
        let current = try ConvertedAudioFeed(input: format, output: format)
        defer { old.finish(); current.finish() }
        let gate = MicrophoneAudioGate()
        gate.open(old)
        gate.open(current)
        XCTAssertNil(gate.close(ifCurrent: old))
        XCTAssertTrue(gate.close(ifCurrent: current) === current)
    }

    func testDuplexReadinessRequiresFreshInputAndAdvancingOutput() {
        var state = MicrophoneInput.DuplexReadiness()
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: nil, healthy: true))
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 100, healthy: true))
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 100, healthy: true))
        XCTAssertTrue(state.observe(inputFrames: 1024, outputSample: 200, healthy: true))
        XCTAssertFalse(state.observe(inputFrames: 0, outputSample: 300, healthy: true))
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 400, healthy: true))
        XCTAssertTrue(state.observe(inputFrames: 1024, outputSample: 500, healthy: true))
    }

    func testDuplexReadinessCannotReuseAnInvalidatedRoute() {
        var state = MicrophoneInput.DuplexReadiness()
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 100, healthy: true))
        XCTAssertTrue(state.observe(inputFrames: 1024, outputSample: 200, healthy: true))
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 300, healthy: false))
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 400, healthy: true))
        XCTAssertTrue(state.observe(inputFrames: 1024, outputSample: 500, healthy: true))
        XCTAssertFalse(state.observe(inputFrames: 1024, outputSample: 1, healthy: true))
    }

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
