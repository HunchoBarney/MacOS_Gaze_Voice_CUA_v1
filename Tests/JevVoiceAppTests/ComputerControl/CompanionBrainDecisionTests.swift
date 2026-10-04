import XCTest
import JevVoiceCore
@testable import JevVoice

/// The planner's decode contract: only documented shapes produce decisions —
/// anything else is malformed, never a guessed action.
@MainActor
final class CompanionBrainDecisionTests: XCTestCase {

    private let intentA = UUID()
    private let intentB = UUID()
    private let questionID = UUID()

    private func decode(_ json: String) throws -> PlannerDecision {
        try CompanionBrain.decodeDecision(json)
    }

    func testExecuteCarriesFullSpecAndBindings() throws {
        let decision = try decode("""
            {"type":"execute","goal":"type the reply","application":"Mail",
             "scope":"work","window":"Inbox","deny":["delete"],
             "values":{"to":"sam"},"literal_text":"hello there",
             "success_contains":["sent"],"resolves_question":true,
             "answers_question":"\(questionID.uuidString)",
             "relationship":"continuation","related_intent":"\(intentA.uuidString)",
             "requires_intent":"\(intentB.uuidString)","consumed_through":3}
            """)
        guard case .execute(let spec) = decision else {
            return XCTFail("expected execute, got \(decision)")
        }
        XCTAssertEqual(spec.goal, "type the reply")
        XCTAssertEqual(spec.application, "Mail")
        XCTAssertEqual(spec.scope, .work)
        XCTAssertEqual(spec.window, "Inbox")
        XCTAssertEqual(spec.deny, ["delete"])
        XCTAssertEqual(spec.values["to"], "sam")
        XCTAssertEqual(spec.literalText, "hello there")
        XCTAssertEqual(spec.successContains, ["sent"])
        XCTAssertTrue(spec.resolvesPendingQuestion)
        XCTAssertEqual(spec.answersQuestionID, questionID)
        XCTAssertEqual(spec.relationship, .continuation(of: intentA))
        XCTAssertEqual(spec.requiresIntentID, intentB)
        XCTAssertEqual(spec.consumedThrough, 3)
    }

    func testExecuteRejectsMissingGoalAndUnknownType() {
        XCTAssertThrowsError(try decode("{\"type\":\"execute\"}"))
        XCTAssertThrowsError(try decode("{\"type\":\"launch_app\"}"))
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode("{\"goal\":\"open Notes\"}"))
    }

    func testCancelTargetsNamedIntentOnly() throws {
        let targeted = try decode("""
            {"type":"cancel","target_intent":"\(intentA.uuidString)"}
            """)
        guard case .cancel(let cancel) = targeted else {
            return XCTFail("expected cancel, got \(targeted)")
        }
        XCTAssertEqual(cancel.targetIntentID, intentA)

        guard case .cancel(let all) = try decode("{\"type\":\"stop_all\"}") else {
            return XCTFail("expected cancel")
        }
        XCTAssertNil(all.targetIntentID)
    }

    func testCorrectRetractAndRevise() throws {
        guard case .correct(let retract) = try decode("""
            {"type":"correct","target_intent":"\(intentA.uuidString)","mode":"retract"}
            """) else { return XCTFail("expected correct") }
        XCTAssertEqual(retract.targetIntentID, intentA)
        XCTAssertEqual(retract.mode, .retract)
        XCTAssertNil(retract.replacement)

        guard case .correct(let revise) = try decode("""
            {"type":"correct","target_intent":"\(intentA.uuidString)","mode":"revise",
             "replacement_goal":"open Notes instead","application":"Notes"}
            """) else { return XCTFail("expected correct") }
        XCTAssertEqual(revise.mode, .revise)
        XCTAssertEqual(revise.replacement?.goal, "open Notes instead")
        XCTAssertEqual(revise.replacement?.application, "Notes")
    }

    func testRetryBindsTargetWhenNamed() throws {
        guard case .retry(let retry) = try decode("""
            {"type":"retry","target_intent":"\(intentB.uuidString)"}
            """) else { return XCTFail("expected retry") }
        XCTAssertEqual(retry.targetIntentID, intentB)

        guard case .retry(let implied) = try decode("{\"type\":\"retry\"}") else {
            return XCTFail("expected retry")
        }
        XCTAssertNil(implied.targetIntentID)
    }

    func testUnrelatedIntentFallsBackToIndependent() throws {
        guard case .execute(let spec) = try decode("""
            {"type":"execute","goal":"open Notes","relationship":"independent",
             "related_intent":"\(intentA.uuidString)"}
            """) else { return XCTFail("expected execute") }
        XCTAssertEqual(spec.relationship, .independent)
    }

    func testExistingKindsStillDecode() throws {
        guard case .clarify(let clarify) = try decode("""
            {"type":"clarify","question":"Which app?","options":["Notes","Mail"]}
            """) else { return XCTFail("expected clarify") }
        XCTAssertEqual(clarify.options, ["Notes", "Mail"])

        guard case .answer(let text, _) = try decode("""
            {"type":"answer","text":"Nothing is running."}
            """) else { return XCTFail("expected answer") }
        XCTAssertEqual(text, "Nothing is running.")

        guard case .refuse(let reason, _) = try decode("""
            {"type":"refuse","reason":"cannot do that"}
            """) else { return XCTFail("expected refuse") }
        XCTAssertEqual(reason, "cannot do that")
    }
}
