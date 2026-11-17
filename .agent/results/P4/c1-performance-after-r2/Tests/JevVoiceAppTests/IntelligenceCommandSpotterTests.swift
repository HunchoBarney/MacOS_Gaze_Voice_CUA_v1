import XCTest
@testable import JevVoice

/// Migrated from fuzzy spotter tests: lexical near-misses are not
/// authority to actuate, and quoted command words stay literal data.
final class IntelligenceCommandSpotterTests: XCTestCase {
    func testNoSuffixJitterAutocorrection() {
        for text in ["clickk", "stopp", "cclick", "scrolll"] {
            let decision = VoiceAdmissionPolicy.propose(text, context: VoiceAdmissionContext())
            XCTAssertNotEqual(decision.route, .local, text)
        }
    }

    func testCancelMustBeACompleteOwnedRequest() {
        var context = VoiceAdmissionContext()
        context.tasks = [UUID()]
        XCTAssertEqual(VoiceAdmissionPolicy.propose("stop", context: context).intent, "cancel")
        XCTAssertEqual(VoiceAdmissionPolicy.propose("stop by the store", context: context).route, .clarify)
        XCTAssertEqual(VoiceAdmissionPolicy.propose("do not cancel", context: context).route, .refuse)
        context.targetID = "fixture"; context.editableTarget = true
        let literal = VoiceAdmissionPolicy.propose("type the word stop", context: context)
        XCTAssertEqual(literal.intent, "type"); XCTAssertEqual(literal.slots["text"], "stop")
    }

    func testUnquotedTypingCorrectionDoesNotActuate() {
        var context = VoiceAdmissionContext()
        context.targetID = "fixture"; context.editableTarget = true
        let result = VoiceAdmissionPolicy.propose("type hello actually do not type it", context: context)
        XCTAssertEqual(result.route, .clarify)
        XCTAssertEqual(VoiceAdmissionPolicy.propose("type hello, no, don't type that", context: context).route, .clarify)
        XCTAssertEqual(VoiceAdmissionPolicy.propose(#"type "hello, no, don't type that""#, context: context).route, .local)
    }

    func testSearchDateModifierIsNotAnInventedAppTarget() {
        var context = VoiceAdmissionContext()
        context.targetID = "fixture"
        context.entities = [.init(name: "Notes", id: "com.apple.Notes", canOpenLocally: true)]
        let proposal = VoiceAdmissionPolicy.propose("search for flights to new york on friday", context: context)
        XCTAssertEqual(proposal.route, .remote)
        XCTAssertEqual(proposal.intent, "browser_request")
    }

    func testNamedClickWithoutAnyGroundedTargetClarifiesBeforeRemote() {
        let proposal = VoiceAdmissionPolicy.propose("click the blue button", context: VoiceAdmissionContext())
        XCTAssertEqual(proposal.route, .clarify)
        XCTAssertEqual(proposal.reason, "ungrounded_target")
    }
}
