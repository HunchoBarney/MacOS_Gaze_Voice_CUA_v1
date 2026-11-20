import XCTest
@testable import Jarvis
import JarvisCore

/// Contract for piece 4 of JARA-36: consequential controls ask first,
/// the never list refuses outright, passwords are never typed, and scam
/// links and popup phone numbers are refused on sight.
final class ConsequenceTests: XCTestCase {

    private func makeLoop(ask: DriveLoop.AskFn? = nil, grant: Bool = false) -> DriveLoop {
        DriveLoop(call: { _, _ in .object([:]) }, choose: { _, _ in nil },
                  ask: ask, granted: { grant })
    }

    private func expectAbort(_ expected: String, _ body: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as DriveLoop.Abort {
            let kind: String
            switch error {
            case .denied: kind = "denied"
            case .declined: kind = "declined"
            case .missingGrant: kind = "missingGrant"
            case .refused: kind = "refused"
            }
            XCTAssertEqual(kind, expected, "\(error)", file: file, line: line)
        } catch {
            XCTFail("expected DriveLoop.Abort, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Words

    func testClassifyNamesTheConsequence() {
        XCTAssertEqual(Consequence.classify("Send"), .send)
        XCTAssertEqual(Consequence.classify("Reply All"), .send)
        XCTAssertEqual(Consequence.classify("Send Payment"), .pay)
        XCTAssertEqual(Consequence.classify("Place your order"), .pay)
        XCTAssertEqual(Consequence.classify("Remove Device"), .account)
        XCTAssertEqual(Consequence.classify("Sign Out"), .account)
        XCTAssertEqual(Consequence.classify("Move to Trash"), .delete)
        XCTAssertEqual(Consequence.classify("Allow"), .permission)
        XCTAssertEqual(Consequence.classify("FaceTime"), .call)
        XCTAssertNil(Consequence.classify("Save"))
        XCTAssertNil(Consequence.classify("Sender"))
    }

    func testOnlyAClearYesCounts() {
        XCTAssertTrue(Consequence.send.isClearYes("yes"))
        XCTAssertTrue(Consequence.send.isClearYes("Yes, send it."))
        XCTAssertTrue(Consequence.send.isClearYes("send it"))
        XCTAssertTrue(Consequence.pay.isClearYes("okay"))
        XCTAssertFalse(Consequence.send.isClearYes("yes, but not yet"))
        XCTAssertFalse(Consequence.send.isClearYes("okay, wait"))
        XCTAssertFalse(Consequence.send.isClearYes("mm"))
        XCTAssertFalse(Consequence.send.isClearYes("yesterday"))
        XCTAssertFalse(Consequence.send.isClearYes("no"))
        XCTAssertFalse(Consequence.send.isClearYes(""))
        XCTAssertFalse(Consequence.delete.isClearYes("send it"))
    }

    /// The shared confirm parser no longer hears a yes inside a no.
    func testAffirmativeRejectsHedgedReplies() {
        XCTAssertTrue(DriveLoop.affirmative("yes please"))
        XCTAssertTrue(DriveLoop.affirmative("Go ahead."))
        XCTAssertFalse(DriveLoop.affirmative("yesterday"))
        XCTAssertFalse(DriveLoop.affirmative("okay, hold on"))
        XCTAssertFalse(DriveLoop.affirmative("yes, don't send it"))
    }

    func testConfirmationExpiresAfterThirtySeconds() throws {
        let start = Date()
        let pending = try XCTUnwrap(ConsequenceConfirmation(corpus: "send", label: "Send", now: start))
        XCTAssertEqual(pending.consequence, .send)
        XCTAssertTrue(pending.question.contains("\u{201C}Send\u{201D}"))
        XCTAssertTrue(pending.accepts("yes", now: start.addingTimeInterval(29)))
        XCTAssertFalse(pending.accepts("yes", now: start.addingTimeInterval(31)))
        XCTAssertFalse(pending.accepts(nil, now: start))
    }

    func testNoConfirmationForNeverListOrPlainControls() {
        XCTAssertNil(ConsequenceConfirmation(corpus: "empty trash", label: "Empty Trash"))
        XCTAssertNil(ConsequenceConfirmation(corpus: "buy a gift card", label: "Buy"))
        XCTAssertNil(ConsequenceConfirmation(corpus: "save", label: "Save"))
    }

    // MARK: - Policy

    func testNeverListIsInsideTheProtectedList() {
        for phrase in CuaPolicy.hardDeniedPatterns {
            XCTAssertTrue(CuaPolicy.deniedPatterns.contains(phrase), phrase)
        }
    }

    func testDwellWallCarriesTheScamTools() {
        for phrase in ["anydesk", "teamviewer", "quick assist", "gift card", "western union"] {
            XCTAssertTrue(DwellPolicy.deniedTokens.contains(phrase), phrase)
        }
    }

    func testNeverListRefusesEvenWithAYes() {
        for label in ["Empty Trash", "Download AnyDesk", "Open TeamViewer", "Buy Gift Card",
                      "Erase This Mac", "Wire Transfer"] {
            guard case .deny(let why) = CuaPolicy.decide(tool: "click", args: [:], elementText: label,
                                                         standingGrant: true, consequenceConfirmed: true) else {
                return XCTFail(label)
            }
            XCTAssertTrue(why.contains("never"), why)
        }
    }

    func testConsequenceYesUnlocksOnlyThePhraseScan() {
        guard case .deny = CuaPolicy.decide(tool: "click", args: [:], elementText: "Send",
                                            standingGrant: true) else {
            return XCTFail("an unconfirmed send stays refused")
        }
        XCTAssertEqual(CuaPolicy.decide(tool: "click", args: [:], elementText: "Send",
                                        standingGrant: true, consequenceConfirmed: true), .allow)
        guard case .needsConfirm = CuaPolicy.decide(tool: "click", args: [:], elementText: "Send",
                                                    standingGrant: false, consequenceConfirmed: true) else {
            return XCTFail("the consequence yes is passed as the grant by the caller, not implied")
        }
    }

    func testPasswordBoxesAreNeverTyped() {
        for label in ["Password", "Enter your password", "AXSecureTextField"] {
            guard case .deny(let why) = CuaPolicy.decide(tool: "type_text", args: ["text": .string("hunter2")],
                                                         elementText: label, standingGrant: true) else {
                return XCTFail(label)
            }
            XCTAssertTrue(why.contains("passwords"), why)
        }
        XCTAssertEqual(CuaPolicy.decide(tool: "type_text", args: ["text": .string("hello")],
                                        elementText: "Message", standingGrant: true), .allow)
    }

    // MARK: - Scam signals

    func testLinkWordsThatNameAnotherSiteAreRefused() {
        XCTAssertEqual(ScamSignals.linkMismatch(text: "paypal.com", url: "https://paypa1-secure.xyz/login")?.actual,
                       "paypa1-secure.xyz")
        XCTAssertEqual(ScamSignals.linkMismatch(
            text: "aria-label=Sign in at chase.com href=https://chase-verify.top/x", url: nil)?.shown, "chase.com")
        XCTAssertNil(ScamSignals.linkMismatch(text: "www.paypal.com", url: "https://www.paypal.com/signin"))
        XCTAssertNil(ScamSignals.linkMismatch(text: "google.com", url: "https://accounts.google.com"))
        XCTAssertNil(ScamSignals.linkMismatch(text: "Download report.pdf", url: "https://files.example.com/report.pdf"))
        XCTAssertNil(ScamSignals.linkMismatch(text: "Click here", url: "https://anything.example"))
        guard case .deny(let why) = CuaPolicy.decide(tool: "browser_click", args: [:],
                                                     elementText: "amazon.com href=https://amaz0n-refunds.top",
                                                     standingGrant: true) else {
            return XCTFail("mismatched link must refuse")
        }
        XCTAssertTrue(why.contains("amazon.com"), why)
    }

    func testSiteKeepsTheRegistrablePart() {
        XCTAssertEqual(ScamSignals.site("mail.google.com"), "google.com")
        XCTAssertEqual(ScamSignals.site("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(ScamSignals.site("apple.com"), "apple.com")
    }

    func testPopupNumbersAreNeverCalled() {
        let popup = "Your Mac is infected! Call Apple Support 1-800-555-0199"
        XCTAssertEqual(ScamSignals.alarmPhoneNumber(in: popup), "1-800-555-0199")
        XCTAssertNil(ScamSignals.alarmPhoneNumber(in: "Call Mom (555) 123-4567"))
        XCTAssertNotNil(CuaPolicy.neverReason(text: popup))
        XCTAssertNotNil(CuaPolicy.neverReason(text: "Virus alert 1-800-555-0199", url: "tel:18005550199"))
        XCTAssertNil(CuaPolicy.neverReason(text: "Virus alert 1-800-555-0199 Close"),
                     "closing the popup stays allowed")
    }

    // MARK: - The loop asks once, for one control

    func testConsentGateAsksTheConsequenceQuestionForEachSend() async throws {
        var asked: [DriveLoop.Ask] = []
        let loop = makeLoop(ask: { ask in asked.append(ask); return "yes, send it" })
        var confirmed = false
        try await loop.consentGate(tool: "click", args: [:], elementText: "Send",
                                   denied: [], confirmed: &confirmed)
        XCTAssertFalse(confirmed, "the yes covers one dispatch, not the task")
        try await loop.consentGate(tool: "click", args: [:], elementText: "Send",
                                   denied: [], confirmed: &confirmed)
        XCTAssertEqual(asked.count, 2)
        guard case .confirm(let question) = asked.first else { return XCTFail("\(asked)") }
        XCTAssertEqual(question, Consequence.send.question(target: "Send"))
    }

    func testConsentGateDeclinesAHedgedAnswer() async {
        let loop = makeLoop(ask: { _ in "yes, but not yet" }, grant: true)
        var confirmed = false
        await expectAbort("declined") {
            try await loop.consentGate(tool: "click", args: [:], elementText: "Send",
                                       denied: [], confirmed: &confirmed)
        }
    }

    func testConsentGateWithoutAskKeepsTheRefusal() async {
        let loop = makeLoop(ask: nil, grant: true)
        var confirmed = false
        await expectAbort("denied") {
            try await loop.consentGate(tool: "click", args: [:], elementText: "Send",
                                       denied: [], confirmed: &confirmed)
        }
    }

    func testRefusalComesBeforeTheQuestion() async {
        var asked = 0
        let loop = makeLoop(ask: { _ in asked += 1; return "yes" }, grant: true)
        var confirmed = false
        await expectAbort("denied") {
            try await loop.consentGate(tool: "click", args: [:], elementText: "Send gift card",
                                       denied: [], confirmed: &confirmed)
        }
        await expectAbort("denied") {
            try await loop.consentGate(tool: "type_text", args: ["text": .string("rm -rf ~")],
                                       elementText: "Reply", denied: [], confirmed: &confirmed)
        }
        XCTAssertEqual(asked, 0)
    }

    func testSpokenCommandAsksBeforeSending() async throws {
        var asked: [DriveLoop.Ask] = []
        let loop = makeLoop(ask: { ask in asked.append(ask); return "yes" })
        var confirmed = false
        try await loop.gateExplicit("click", corpus: "Send Mail", denied: [], confirmed: &confirmed)
        XCTAssertEqual(asked, [.confirm(Consequence.send.question(target: "send"))])

        let refusing = makeLoop(ask: { _ in "not yet" })
        await expectAbort("declined") {
            try await refusing.gateExplicit("click", corpus: "Send Mail", denied: [], confirmed: &confirmed)
        }
        await expectAbort("denied") {
            try await refusing.gateExplicit("click", corpus: "Install AnyDesk", denied: [], confirmed: &confirmed)
        }
    }
}
