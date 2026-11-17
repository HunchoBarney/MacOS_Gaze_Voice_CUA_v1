import XCTest
import JevVoiceCore
@testable import JevVoice

/// Migrated from speculative-router tests: partials are display-only and
/// the released whole hold, including corrections, owns one admission.
@MainActor
final class IntelligenceCommandRouterTests: XCTestCase {
    func testProvisionalPartialAndInternalFinalNeverDispatch() async {
        var calls: [String] = [], partials: [String] = []
        let session = LocalSpeechSession { calls.append($0.text) }
        session.context.targetID = "fixture.window"
        session.onPartial = { _, text in partials.append(text) }
        let turn = session.begin(mode: .command, ready: true, now: 0)
        XCTAssertTrue(session.acceptFrame(turn, sequence: 0))
        session.partial("scroll down", turn: turn)
        let provisional = await session.finalize("scroll down", turn: turn, drainedFrames: 1, now: 0.2)
        XCTAssertNil(provisional); XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(partials, ["scroll down"])
        XCTAssertTrue(session.release(turn, now: 1))
        let final = await session.finalize("scroll up", turn: turn, drainedFrames: 1, now: 1.1)
        XCTAssertEqual(final?.route, .local)
        XCTAssertEqual(calls, ["scroll up"])
        _ = await session.finalize("scroll up", turn: turn, drainedFrames: 1, now: 1.2)
        XCTAssertEqual(calls.count, 1)
    }

    func testLateCancelledPartialCannotUpdateNewTurn() {
        var partials: [String] = []
        let session = LocalSpeechSession { _ in XCTFail("no final was admitted") }
        session.onPartial = { _, text in partials.append(text) }
        let old = session.begin(mode: .command, ready: true, now: 0)
        session.cancel(old)
        let new = session.begin(mode: .command, ready: true, now: 1)
        session.partial("old words", turn: old)
        session.partial("new words", turn: new)
        XCTAssertEqual(partials, ["new words"])
    }

    func testMultiwordAnswerCannotSelectAmongUnownedAsks() {
        var context = VoiceAdmissionContext()
        context.capturedAsks = [.init(taskID: UUID(), askID: UUID(), kind: .choice, options: ["blue", "red"]),
                                .init(taskID: UUID(), askID: UUID(), kind: .question)]
        context.currentAsks = context.capturedAsks
        let proposal = VoiceAdmissionPolicy.propose("the blue one please", context: context)
        XCTAssertEqual(proposal.route, .clarify)
        XCTAssertEqual(proposal.reason, "ambiguous_ask")
    }
}
