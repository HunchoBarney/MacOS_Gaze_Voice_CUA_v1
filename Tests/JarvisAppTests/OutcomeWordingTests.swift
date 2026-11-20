import XCTest
@testable import Jarvis

/// Every outcome a person reads or hears passes through one map: machine
/// reasons and driver errors never reach the indicator or the speaker.
@MainActor
final class OutcomeWordingTests: XCTestCase {

    func testReasonCodesBecomeSentences() {
        for code in ["low_confidence", "scroll_unverified", "target_changed", "untrusted_answer",
                     "no_candidate", "needs_choice", DriveLoop.scrollUnverifiedReason] {
            let said = OutcomeWording.blocked(code)
            XCTAssertNotEqual(said, code)
            XCTAssertFalse(OutcomeWording.isInternal(said), "\(code) → \(said)")
        }
    }

    func testDriverErrorsAreNeverReadOut() {
        let lines = [
            "The driver connection dropped mid-task: The operation couldn’t be completed. (NSPOSIXErrorDomain error 32.)",
            "The driver refused (element_stale).",
            "The driver could not be reached: Error Domain=NSCocoaErrorDomain Code=4",
            "'set_driver_config' changes driver or session state — it is never dispatched through the policy path",
        ]
        for line in lines {
            let said = OutcomeWording.readable(line)
            XCTAssertFalse(said.lowercased().contains("driver"), said)
            XCTAssertFalse(OutcomeWording.isInternal(said), said)
        }
        XCTAssertEqual(OutcomeWording.readable(lines[0]),
                       "I lost touch with your Mac's controls for a moment. Try that again.")
    }

    /// An executor line that already reads like a person keeps its detail.
    func testPlainSentencesPassThrough() {
        let line = "I can see two things called Save. One or two?"
        XCTAssertEqual(OutcomeWording.blocked(line, reason: "ambiguous name"), line)
        XCTAssertEqual(OutcomeWording.blocked(DriveLoop.eyesOffReply(.click), reason: "eye tracking off"),
                       DriveLoop.eyesOffReply(.click))
    }

    /// A reason the table knows wins over an internal executor line.
    func testReasonTableBeatsInternalLine() {
        XCTAssertEqual(OutcomeWording.blocked("The driver connection dropped mid-task.", reason: "transport failure"),
                       "I lost touch with your Mac's controls for a moment. Try that again.")
    }

    func testProtectedWordsGetAPlainRefusal() {
        let said = OutcomeWording.readable("Refused: 'send' is on the protected list — it requires the user's hands, not ours")
        XCTAssertTrue(said.contains("yours to press"), said)
        XCTAssertFalse(said.contains("Refused:"))
    }

    func testDescribeSpeaksSentencesNotCodes() {
        let (outcome, say) = VoiceTaskCoordinator.describe(
            DriveResult(status: .handedBack(.lowConfidence)), request: "click it")
        XCTAssertEqual(outcome, .blocked("low_confidence"), "the machine reason stays on the outcome")
        XCTAssertTrue(say.contains("show names"), say)

        let (_, driverSay) = VoiceTaskCoordinator.describe(
            DriveResult(status: .blocked("The driver refused (element_stale)."), blockedReason: nil),
            request: "click save")
        XCTAssertEqual(driverSay, "Your Mac didn't let me do that.")
    }

    /// Say less, show more (JARA-41): the first sentence is spoken, the
    /// remedy after it is shown; a question is spoken whole.
    func testHeadlineSpeaksTheFirstSentence() {
        XCTAssertEqual(OutcomeWording.headline("I couldn't find that on screen. Say “show names” to see what's there."),
                       "I couldn't find that on screen.")
        XCTAssertEqual(OutcomeWording.headline("I lost touch with your Mac's controls for a moment. Try that again."),
                       "I lost touch with your Mac's controls for a moment.")
        XCTAssertEqual(OutcomeWording.headline("I can see two things called Save. One or two?"),
                       "I can see two things called Save. One or two?")
        XCTAssertEqual(OutcomeWording.headline("Opened Calculator"), "Opened Calculator.")
    }

    /// A clean success is the chime and the glow, not a spoken "Done";
    /// a caveat or a failure is still heard, as a headline.
    func testCleanSuccessIsSilent() {
        let (done, doneSay) = VoiceTaskCoordinator.describe(
            DriveResult(status: .done, history: ["pressed Reply"], dispatchedEffect: true), request: "click Reply")
        XCTAssertNil(VoiceTaskCoordinator.spokenOutcome(done, say: doneSay))

        let caveat = "Clicked Reply, but it was not independently confirmed."
        let (qualified, qualifiedSay) = VoiceTaskCoordinator.describe(
            DriveResult(status: .done, history: [caveat], dispatchedEffect: true), request: "click Reply")
        XCTAssertEqual(VoiceTaskCoordinator.spokenOutcome(qualified, say: qualifiedSay), caveat)

        let (failed, failedSay) = VoiceTaskCoordinator.describe(
            DriveResult(status: .handedBack(.noCandidate)), request: "click Reply")
        XCTAssertEqual(VoiceTaskCoordinator.spokenOutcome(failed, say: failedSay), "I couldn't find that on screen.")
        XCTAssertTrue(failedSay.contains("show names"), "the remedy stays in the shown line")
    }

    func testConsentQuestionsUseWords() {
        XCTAssertEqual(OutcomeWording.consentQuestion(tool: "click", target: "Save"), "Can I click “Save”?")
        XCTAssertEqual(OutcomeWording.consentQuestion(tool: "type_text", target: "Subject"), "Can I type in “Subject”?")
        XCTAssertEqual(OutcomeWording.consentQuestion(tool: "scroll", target: ""), "Can I scroll for you?")
        XCTAssertEqual(OutcomeWording.consentQuestion(tool: "press_key", target: ""), "Can I press those keys for you?")
        XCTAssertEqual(OutcomeWording.consentQuestion(tool: "mystery_tool", target: ""), "Can I do that for you?")
    }

    func testRecapSaysWhatYouAskedNotTheLedger() {
        let work = VoiceTaskCoordinator.Work(label: "Save", request: "click save",
                                            spec: DriveTask(goal: "click save"))
        work.history = ["Window inventory: rows=4", "click element_token=tok1"]
        work.message = "Clicked Save."
        let said = VoiceTaskCoordinator.recap(of: work)
        XCTAssertEqual(said, "You asked me to click save. Clicked Save.")
    }
}
