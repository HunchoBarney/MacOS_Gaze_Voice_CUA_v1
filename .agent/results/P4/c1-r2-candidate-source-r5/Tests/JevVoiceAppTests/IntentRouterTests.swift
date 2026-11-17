import XCTest
@testable import JevVoice

/// The lane table is the product contract: on-screen is the default for
/// real work, background only on explicit request, confident referents
/// answer directly, and nothing is silently guessed.
final class IntentRouterTests: XCTestCase {

    private func referent(
        _ kind: IntentCandidate.Kind = .axElement,
        role: String = "AXButton",
        label: String = "Save",
        url: String? = nil
    ) -> GazeReferent {
        let frame = CGRect(x: 0, y: 0, width: 60, height: 24)
        let c = IntentCandidate(id: "t", kind: kind, frame: frame, motorRect: frame,
                                role: role, label: label, url: url,
                                appName: "Safari", windowTitle: "Docs")
        return GazeReferent(c, confidence: 0.9, at: Date())
    }

    // MARK: element verbs → instant

    func testClickVerbOnReferentIsInstant() {
        let r = IntentRouter.route(verb: .actuate, referent: referent(), modifiers: [])
        XCTAssertEqual(r?.lane, .instant)
    }

    func testClickVerbWithoutReferentDefersToModel() {
        XCTAssertNil(IntentRouter.route(verb: .actuate, referent: nil, modifiers: []))
    }

    func testScrollOnReferentIsInstant() {
        XCTAssertEqual(IntentRouter.route(verb: .scroll, referent: referent(), modifiers: [])?.lane, .instant)
    }

    // MARK: dictate → instant only into text-ish referents

    func testDictateIntoTextFieldIsInstant() {
        let field = referent(role: "AXTextField")
        XCTAssertEqual(IntentRouter.route(verb: .dictate, referent: field, modifiers: [])?.lane, .instant)
    }

    func testDictateOntoAButtonDefers() {
        // A button can't hold text — the model decides where it goes.
        XCTAssertNil(IntentRouter.route(verb: .dictate, referent: referent(), modifiers: []))
    }

    // MARK: knowledge → answer lane (never opens anything)

    func testExplainThisWithConfidentReferentAnswers() {
        let dom = referent(.dom, role: "link", label: "Tokyo video",
                           url: "https://youtube.com/watch?v=x")
        let r = IntentRouter.route(verb: .query, referent: dom, modifiers: [])
        XCTAssertEqual(r?.lane, .answer)
        // The url rides the referent so the answer path can fetch
        // instead of navigating.
        XCTAssertEqual(r?.referent?.url, "https://youtube.com/watch?v=x")
    }

    func testLookupAlwaysAnswers() {
        XCTAssertEqual(IntentRouter.route(verb: .lookup, referent: nil, modifiers: [])?.lane, .answer)
        XCTAssertEqual(IntentRouter.route(verb: .lookup, referent: referent(), modifiers: [])?.lane, .answer)
    }

    // MARK: work → on-screen default, background on request

    func testMultiStepWorkDefaultsToScreenAgent() {
        // "Fill this form" / "book the flight" — visible by default. The
        // user watches it happen unless they say otherwise.
        let r = IntentRouter.route(verb: .work, referent: referent(), modifiers: [])
        XCTAssertEqual(r?.lane, .screenAgent)
    }

    func testExplicitBackgroundModifierDelegates() {
        let r = IntentRouter.route(verb: .work, referent: nil, modifiers: [.background])
        XCTAssertEqual(r?.lane, .backgroundAgent)
    }

    func testAgentPhrasingDelegates() {
        let r = IntentRouter.route(verb: .work, referent: nil, modifiers: [.agent])
        XCTAssertEqual(r?.lane, .backgroundAgent)
    }

    func testForegroundModifierKeepsScreenDefault() {
        let r = IntentRouter.route(verb: .work, referent: nil, modifiers: [.foreground])
        XCTAssertEqual(r?.lane, .screenAgent)
    }

    func testConflictingModifiersResolveForeground() {
        // "On my screen" + "in the background" both present — visible wins.
        let r = IntentRouter.route(verb: .work, referent: nil, modifiers: [.foreground, .background])
        XCTAssertEqual(r?.lane, .screenAgent)
    }

    // MARK: meta — stop/address

    func testCancelIsMeta() {
        XCTAssertEqual(IntentRouter.route(verb: .cancel, referent: nil, modifiers: [])?.lane, .meta)
        XCTAssertEqual(IntentRouter.route(verb: .cancel, referent: referent(), modifiers: [])?.lane, .meta)
    }

    func testAddressingAnAgentChipIsMeta() {
        let chip = referent(.chip, role: "chip", label: "flight-researcher")
        let r = IntentRouter.route(verb: .address, referent: chip, modifiers: [])
        XCTAssertEqual(r?.lane, .meta)
        XCTAssertEqual(r?.reason, "addressing flight-researcher")
    }

    func testAddressingANonAgentReferentDefers() {
        XCTAssertNil(IntentRouter.route(verb: .address, referent: referent(), modifiers: []))
    }

    // MARK: provenance echo — ≤5 words, carries the referent

    func testProvenanceEchoIsShort() {
        let cases: [RoutedIntent] = [
            .init(lane: .instant, referent: referent(label: "the big red order button"), reason: "clicking"),
            .init(lane: .answer, referent: referent(), reason: "summarizing the video"),
            .init(lane: .screenAgent, referent: nil, reason: "on your screen"),
            .init(lane: .backgroundAgent, referent: nil, reason: "in the background"),
        ]
        for intent in cases {
            let echo = IntentRouter.provenanceEcho(intent)
            XCTAssertLessThanOrEqual(echo.split(separator: " ").count, 5,
                                     "echo too long: \(echo)")
        }
    }

    func testUnknownVerbNeverGuesses() {
        XCTAssertNil(IntentRouter.route(verb: .unknown, referent: referent(), modifiers: []))
    }

    // MARK: classify — whole-utterance verb/modifier mapping

    func testClassifyVerbFamilies() {
        XCTAssertEqual(IntentRouter.classify("click save").verb, .actuate)
        XCTAssertEqual(IntentRouter.classify("scroll down").verb, .scroll)
        XCTAssertEqual(IntentRouter.classify("type hello world").verb, .dictate)
        XCTAssertEqual(IntentRouter.classify("explain this video").verb, .query)
        XCTAssertEqual(IntentRouter.classify("look up the weather").verb, .lookup)
        XCTAssertEqual(IntentRouter.classify("book a flight").verb, .work)
        XCTAssertEqual(IntentRouter.classify("cancel that").verb, .cancel)
        XCTAssertEqual(IntentRouter.classify("hmm").verb, .unknown)
    }

    func testClassifyModifiers() {
        XCTAssertEqual(IntentRouter.classify("research flights in the background").modifiers,
                       [.background, .agent])
        XCTAssertEqual(IntentRouter.classify("do it on my screen").modifiers, [.foreground])
        // Foreground beats conflicting background phrasing downstream.
        let m = IntentRouter.classify("do it in the background on my screen").modifiers
        XCTAssertTrue(m.contains(.background) && m.contains(.foreground))
        XCTAssertEqual(IntentRouter.classify("click save").modifiers, [])
    }

    func testClassifyRequiresExplicitModifierPhrasing() {
        // "agent" mid-word or implied background never registers.
        XCTAssertEqual(IntentRouter.classify("manage the files").modifiers, [])
        XCTAssertEqual(IntentRouter.classify("run this while I wait").modifiers, [])
    }

    func testClassifyQueryNotConfusedByPrefix() {
        // "what's the save button for" is a query even though "save" appears.
        XCTAssertEqual(IntentRouter.classify("what's the save button for").verb, .query)
    }

    // MARK: classify — real ASR output has punctuation

    func testClassifyIgnoresPunctuation() {
        XCTAssertEqual(IntentRouter.classify("Click.").verb, .actuate)
        XCTAssertEqual(IntentRouter.classify("click save.").verb, .actuate)
        XCTAssertEqual(IntentRouter.classify("cancel that!").verb, .cancel)
        XCTAssertEqual(IntentRouter.classify("scroll down, please.").verb, .scroll)
        XCTAssertEqual(IntentRouter.classify("book a flight?").verb, .work)
        XCTAssertEqual(IntentRouter.classify("open Safari.").verb, .actuate)
    }

    // MARK: classify — a leading command verb makes it a command

    /// Cancel words inside a command are operands, not the intent —
    /// "click cancel" presses the Cancel button, it doesn't stop work.
    func testLeadingActuateBeatsTrailingCancel() {
        XCTAssertEqual(IntentRouter.classify("click cancel").verb, .actuate)
        XCTAssertEqual(IntentRouter.classify("click the cancel button").verb, .actuate)
        XCTAssertEqual(IntentRouter.classify("press stop on the player").verb, .actuate)
        XCTAssertEqual(IntentRouter.classify("type the word cancel").verb, .dictate)
    }

    /// "Report"/status words can't fire mid-command — "write a report"
    /// is work, not an address to a referent.
    func testLeadingWorkVerbBeatsReport() {
        XCTAssertEqual(IntentRouter.classify("write a report").verb, .work)
        XCTAssertEqual(IntentRouter.classify("draft a status report").verb, .work)
        XCTAssertEqual(IntentRouter.classify("report").verb, .address)
        XCTAssertEqual(IntentRouter.classify("status report").verb, .address)
        XCTAssertEqual(IntentRouter.classify("what are you doing").verb, .address)
    }

    /// A question form is never a cancel — asking about the cancel
    /// button must not stop the newest task.
    func testQuestionAboutCancelIsNotCancel() {
        XCTAssertEqual(IntentRouter.classify("what's the cancel button for").verb, .query)
        XCTAssertEqual(IntentRouter.classify("what does abort mean").verb, .query)
    }

    /// Bare cancel phrasing still cancels.
    func testBareCancelStillCancels() {
        XCTAssertEqual(IntentRouter.classify("cancel that").verb, .cancel)
        XCTAssertEqual(IntentRouter.classify("please cancel it").verb, .cancel)
        XCTAssertEqual(IntentRouter.classify("never mind").verb, .cancel)
        XCTAssertEqual(IntentRouter.classify("stop").verb, .cancel)
    }
}
