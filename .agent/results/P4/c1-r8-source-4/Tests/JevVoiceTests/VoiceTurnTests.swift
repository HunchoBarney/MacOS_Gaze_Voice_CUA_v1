import Foundation
import XCTest
@testable import JevVoiceCore

final class VoiceTurnTests: XCTestCase {
    func testInternalFinalCannotAdmitBeforeRelease() {
        var gate = VoiceTurnGate()
        let turn = gate.begin(mode: .command, ready: true, now: 0)
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
        XCTAssertTrue(gate.acceptPartial(turn))
        XCTAssertNil(gate.finalize(turn, text: "open Calculator", proposal: .local("open"),
                                   drainedFrames: 1, now: 0.5))
        XCTAssertTrue(gate.release(turn, now: 1))
        XCTAssertNotNil(gate.finalize(turn, text: "open Calculator", proposal: .local("open"),
                                      drainedFrames: 1, now: 1.1))
        XCTAssertNil(gate.finalize(turn, text: "open Calculator", proposal: .local("open"),
                                   drainedFrames: 1, now: 1.2))
    }

    func testQueuedFramesAndLossFailClosed() {
        var gate = VoiceTurnGate()
        let turn = gate.begin(mode: .command, ready: true, now: 0)
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 1))
        XCTAssertTrue(gate.release(turn, now: 1))
        XCTAssertNil(gate.finalize(turn, text: "scroll down", proposal: .local("scroll"),
                                   drainedFrames: 1, now: 1.1))
        XCTAssertEqual(gate.failureReason, "capture_loss")
        let next = gate.begin(mode: .command, ready: true, now: 2)
        XCTAssertFalse(gate.acceptFrame(next, sequence: 1))
        XCTAssertFalse(gate.release(next, now: 3))
    }

    func testCancelledGenerationCannotResetOrPublishIntoNextHold() {
        var gate = VoiceTurnGate()
        let first = gate.begin(mode: .command, ready: true, now: 0)
        gate.cancel(first)
        let next = gate.begin(mode: .command, ready: true, now: 1)
        XCTAssertTrue(gate.acceptFrame(next, sequence: 0))
        XCTAssertFalse(gate.acceptPartial(first))
        XCTAssertFalse(gate.release(first, now: 2))
        gate.cancel(first)
        XCTAssertTrue(gate.acceptPartial(next))
        XCTAssertTrue(gate.release(next, now: 2))
        XCTAssertNotNil(gate.finalize(next, text: "scroll up", proposal: .local("scroll"),
                                      drainedFrames: 1, now: 2.1))
    }

    func testFinalizeDeadlineStartsAtReleaseAndCannotBecomeRemoteMiss() {
        var gate = VoiceTurnGate()
        let turn = gate.begin(mode: .command, ready: true, now: 0)
        XCTAssertTrue(gate.release(turn, now: 2))
        XCTAssertNil(gate.finalize(turn, text: "what is this", proposal: .remote(),
                                   drainedFrames: 0, now: 3.01))
        XCTAssertEqual(gate.failureReason, "finalization_timeout")
        XCTAssertNil(gate.admission)
    }

    func testDictationLiteralCannotBecomeCommandAndMicTestCannotAdmit() {
        var gate = VoiceTurnGate()
        let literal = gate.begin(mode: .dictation, ready: true, now: 0)
        XCTAssertTrue(gate.acceptFrame(literal, sequence: 0))
        XCTAssertTrue(gate.release(literal, now: 1))
        let result = gate.finalize(literal, text: "delete this", proposal: .local("delete"),
                                   drainedFrames: 1, now: 1.1)
        XCTAssertEqual(result?.route, .dictation)
        XCTAssertEqual(result?.text, "delete this")
        let mic = gate.begin(mode: .microphoneTest, ready: true, now: 2)
        XCTAssertFalse(gate.acceptPartial(mic))
        XCTAssertTrue(gate.release(mic, now: 3))
        XCTAssertNil(gate.finalize(mic, text: "scroll", proposal: .local("scroll"),
                                   drainedFrames: 0, now: 3.1))
    }

    func testColdUnreadyTurnCannotAcceptFramesOrFallbackRemotely() {
        var gate = VoiceTurnGate()
        let turn = gate.begin(mode: .command, ready: false, now: 0)
        XCTAssertFalse(gate.acceptFrame(turn, sequence: 0))
        XCTAssertFalse(gate.acceptPartial(turn))
        XCTAssertFalse(gate.release(turn, now: 1))
        XCTAssertEqual(gate.failureReason, "provider_unavailable")
    }

    func testUnsafeProposalCannotBeDisguisedAsMiss() {
        var gate = VoiceTurnGate()
        let turn = gate.begin(mode: .command, ready: true, now: 0)
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
        XCTAssertTrue(gate.release(turn, now: 1))
        let proposal = VoiceProposal(route: .remote, intent: "cancel", risk: .negated)
        let result = gate.finalize(turn, text: "do not cancel", proposal: proposal,
                                   drainedFrames: 1, now: 1.1)
        XCTAssertEqual(result?.route, .refuse)
        XCTAssertEqual(result?.reason, "negated_request")
    }

    func testResponseIdentityAndOnePermitIndependentOfCallID() {
        var authority = VoiceResponseAuthority()
        let connection = UUID()
        authority.connect(connection)
        let admission = remoteAdmission()
        XCTAssertTrue(authority.request(admission: admission, purpose: .reasoning, inputItemID: "audio-1"))
        XCTAssertFalse(authority.takeExecutor(connection: connection, responseID: "unbound", callID: "c0"))
        XCTAssertTrue(authority.bindCreated(connection: connection, responseID: "r1"))
        XCTAssertTrue(authority.takeExecutor(connection: connection, responseID: "r1", callID: "c1"))
        XCTAssertFalse(authority.takeExecutor(connection: connection, responseID: "r1", callID: "c1"))
        XCTAssertFalse(authority.takeExecutor(connection: connection, responseID: "r1", callID: "fresh-call-id"))
    }

    func testRevokeUnboundResponseRequiresNewConnection() {
        var authority = VoiceResponseAuthority()
        let connection = UUID()
        authority.connect(connection)
        let admission = remoteAdmission()
        XCTAssertTrue(authority.request(admission: admission, purpose: .reasoning, inputItemID: "audio-1"))
        authority.revoke()
        let next = remoteAdmission(generation: 2)
        XCTAssertFalse(authority.request(admission: next, purpose: .reasoning, inputItemID: "audio-2"))
        authority.connect(UUID())
        XCTAssertTrue(authority.request(admission: next, purpose: .reasoning, inputItemID: "audio-2"))
        XCTAssertFalse(authority.bindCreated(connection: connection, responseID: "old-response"))
    }

    func testOutcomeNarrationNeverGetsExecutorAuthority() {
        var authority = VoiceResponseAuthority()
        let connection = UUID()
        authority.connect(connection)
        XCTAssertTrue(authority.request(admission: nil, purpose: .outcomeOnly, inputItemID: nil))
        XCTAssertTrue(authority.bindCreated(connection: connection, responseID: "outcome"))
        XCTAssertFalse(authority.takeExecutor(connection: connection, responseID: "outcome", callID: "model-ignored-tools-none"))
    }

    func testMidHoldDictationConversionKeepsIdentityButWithdrawsCommandAuthority() {
        var gate = VoiceTurnGate()
        let turn = gate.begin(mode: .command, ready: true, now: 0)
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
        XCTAssertTrue(gate.enterDictation(turn))
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 1))
        XCTAssertTrue(gate.release(turn, now: 1))
        let result = gate.finalize(turn, text: "open Calculator", proposal: .local("open"),
                                   drainedFrames: 2, now: 1.1)
        XCTAssertEqual(result?.route, .dictation)
        XCTAssertEqual(result?.text, "open Calculator")
        XCTAssertFalse(gate.enterDictation(turn), "a finalized turn cannot change mode")
    }

    func testReleaseSealsProducerBoundaryBeforeConsumerDrains() {
        var gate = VoiceTurnGate()
        let turn = gate.begin(mode: .command, ready: true, now: 0)
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 0))
        XCTAssertTrue(gate.release(turn, acceptedFrames: 3, now: 1))
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 1))
        XCTAssertTrue(gate.acceptFrame(turn, sequence: 2))
        XCTAssertFalse(gate.acceptFrame(turn, sequence: 3))
        XCTAssertNotNil(gate.finalize(turn, text: "scroll down", proposal: .local("scroll"),
                                      drainedFrames: 3, now: 1.1))
    }

    func testLocalAdmissionCannotRequestReasoningAndCompletedTurnCannotRequestAgain() {
        var gate = VoiceTurnGate()
        let turn = gate.begin(mode: .typed, ready: true, now: 0)
        _ = gate.release(turn, now: 0)
        let local = gate.finalize(turn, text: "scroll down", proposal: .local("scroll"), drainedFrames: 0, now: 0)
        var authority = VoiceResponseAuthority()
        let connection = UUID()
        authority.connect(connection)
        XCTAssertFalse(authority.request(admission: local, purpose: .typed, inputItemID: "typed-1"))
        let remote = remoteAdmission()
        XCTAssertTrue(authority.request(admission: remote, purpose: .reasoning, inputItemID: "audio-1"))
        XCTAssertTrue(authority.bindCreated(connection: connection, responseID: "r1"))
        authority.finish(connection: connection, responseID: "r1")
        XCTAssertFalse(authority.request(admission: remote, purpose: .reasoning, inputItemID: "audio-1"))
    }

    private func remoteAdmission(generation: Int = 1) -> VoiceAdmission {
        var gate = VoiceTurnGate()
        for _ in 1..<generation { _ = gate.begin(mode: .command, ready: true, now: 0) }
        let turn = gate.begin(mode: .command, ready: true, now: 0)
        _ = gate.acceptFrame(turn, sequence: 0)
        _ = gate.release(turn, now: 1)
        return gate.finalize(turn, text: "what is this", proposal: .remote(), drainedFrames: 1, now: 1.1)!
    }
}
