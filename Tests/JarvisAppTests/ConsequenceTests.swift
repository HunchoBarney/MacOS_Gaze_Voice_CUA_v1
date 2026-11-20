import XCTest
@testable import Jarvis
import JarvisCore

/// Contract for piece 4 of JARA-36 under the owner's rule: the person's
/// own words press consequential controls straight away with a glow; a
/// consequential press Jarvis chose itself asks one question; the never
/// list (scams, wipes, passwords) refuses either way.
final class ConsequenceTests: XCTestCase {

    private func makeLoop(ask: DriveLoop.AskFn? = nil, grant: Bool = false,
                          overlay: ((FastAction.OverlayVerb, [(frame: CGRect, label: String)], CGPoint?) async -> DriveResult?)? = nil) -> DriveLoop {
        DriveLoop(call: { _, _ in .object([:]) }, choose: { _, _ in nil },
                  ask: ask, granted: { grant }, overlayDispatch: overlay)
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

    private func decide(_ label: String, tool: String = "click", grant: Bool = true,
                        spoken: Set<Consequence> = [], confirmed: Bool = false) -> CuaPolicy.Decision {
        CuaPolicy.decide(tool: tool, args: [:], elementText: label, standingGrant: grant,
                         spokenConsequences: spoken, consequenceConfirmed: confirmed)
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

    func testControlLabelIgnoresTheLinkAddress() {
        XCTAssertNil(Consequence.of(control: "aria-label=Weather href=https://x.example/share?id=1"))
        XCTAssertEqual(Consequence.of(control: "aria-label=Share href=https://x.example/a"), .send)
    }

    func testTheirWordsNameWhatTheyCover() {
        XCTAssertEqual(Consequence.named(in: "click Send"), [.send])
        XCTAssertEqual(Consequence.named(in: "reply to Mom saying I'm on my way and send it"), [.send])
        XCTAssertEqual(Consequence.named(in: "delete that email"), [.delete])
        XCTAssertEqual(Consequence.named(in: "open my email"), [])
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

    func testConfirmationExpiresAfterThirtySeconds() {
        let start = Date()
        let pending = ConsequenceConfirmation(consequence: .send, label: "Send", now: start)
        XCTAssertTrue(pending.question.contains("\u{201C}Send\u{201D}"))
        XCTAssertTrue(pending.accepts("yes", now: start.addingTimeInterval(29)))
        XCTAssertFalse(pending.accepts("yes", now: start.addingTimeInterval(31)))
        XCTAssertFalse(pending.accepts(nil, now: start))
    }

    // MARK: - Policy

    /// One policy: Send, Reply, Delete and Allow are no longer on the flat
    /// refusal list. What's left there is the never list.
    func testOrdinaryConsequentialWordsAreNotRefused() {
        for label in ["Send", "Reply", "Reply All", "Delete", "Allow", "Sign Out", "Pay Now", "Submit"] {
            XCTAssertNil(CuaPolicy.deniedPhrase(in: label), label)
            XCTAssertNil(CuaPolicy.neverReason(text: label), label)
        }
    }

    func testTheirWordsPressWithoutAQuestion() {
        XCTAssertEqual(decide("Send", spoken: [.send]), .allow)
        XCTAssertEqual(decide("Move to Trash", spoken: [.delete]), .allow)
        guard case .needsConfirm = decide("Send", grant: false, spoken: [.send]) else {
            return XCTFail("their words don't replace the computer-use grant on the model lane")
        }
    }

    func testAPressJarvisChoseAsksFirst() {
        XCTAssertEqual(decide("Send"), .askFirst(.send))
        XCTAssertEqual(decide("Delete", spoken: [.send]), .askFirst(.delete),
                       "\"send it\" doesn't cover a Delete")
        XCTAssertEqual(decide("Send", confirmed: true), .allow)
        XCTAssertEqual(decide("Save"), .allow)
        XCTAssertEqual(CuaPolicy.decide(tool: "type_text", args: ["text": .string("hi")], elementText: "Reply",
                                        standingGrant: true), .allow, "typing isn't pressing")
    }

    func testNeverListRefusesEvenWithAYes() {
        for label in ["Empty Trash", "Download AnyDesk", "Open TeamViewer", "Buy Gift Card",
                      "Erase This Mac", "Wire Transfer"] {
            guard case .deny(let why) = decide(label, spoken: Set(Consequence.allCases), confirmed: true) else {
                return XCTFail(label)
            }
            XCTAssertTrue(why.contains("never"), why)
        }
    }

    func testDwellWallCarriesTheNeverList() {
        for phrase in CuaPolicy.deniedPatterns {
            XCTAssertTrue(DwellPolicy.deniedTokens.contains(phrase), phrase)
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
        guard case .deny(let why) = decide("amazon.com href=https://amaz0n-refunds.top", tool: "browser_click") else {
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

    // MARK: - The loop

    func testAPressJarvisChoseAsksEveryTime() async throws {
        var asked: [DriveLoop.Ask] = []
        let loop = makeLoop(ask: { ask in asked.append(ask); return "yes, send it" })
        var confirmed = false
        try await loop.consentGate(tool: "click", args: [:], elementText: "Send",
                                   denied: [], confirmed: &confirmed)
        XCTAssertFalse(confirmed, "the yes covers one press, not the task")
        try await loop.consentGate(tool: "click", args: [:], elementText: "Send",
                                   denied: [], confirmed: &confirmed)
        XCTAssertEqual(asked, [.confirm(Consequence.send.question(target: "Send")),
                               .confirm(Consequence.send.question(target: "Send"))])
    }

    func testAHedgedAnswerDeclines() async {
        let loop = makeLoop(ask: { _ in "yes, but not yet" }, grant: true)
        var confirmed = false
        await expectAbort("declined") {
            try await loop.consentGate(tool: "click", args: [:], elementText: "Send",
                                       denied: [], confirmed: &confirmed)
        }
    }

    func testNobodyToAskRefuses() async {
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
            try await loop.consentGate(tool: "click", args: ["text": .string("rm -rf ~")],
                                       elementText: "Reply", denied: [], confirmed: &confirmed)
        }
        XCTAssertEqual(asked, 0)
    }

    func testTheButtonGlowsAsItIsPressed() async throws {
        let glows = LockedBox<[CGRect]>([])
        let loop = makeLoop(ask: { _ in "yes" }, grant: true, overlay: { verb, targets, _ in
            if verb == .pressGlow { glows.set(glows.value + targets.map(\.frame)) }
            return DriveResult(status: .done)
        })
        var confirmed = false
        let frame = CGRect(x: 40, y: 60, width: 80, height: 28)
        try await loop.consentGate(tool: "click", args: [:], elementText: "Send",
                                   denied: [], confirmed: &confirmed, pressFrame: frame)
        try await loop.consentGate(tool: "click", args: [:], elementText: "Save",
                                   denied: [], confirmed: &confirmed, pressFrame: frame)
        XCTAssertEqual(glows.value, [frame], "only the consequential press glows")
    }

    func testSpokenCommandPressesWithoutAsking() async throws {
        var asked = 0
        let loop = makeLoop(ask: { _ in asked += 1; return "no" })
        var confirmed = false
        try await loop.gateExplicit("click", corpus: "Send Mail", denied: [], confirmed: &confirmed)
        try await loop.gateExplicit("click", corpus: "Delete Inbox", denied: [], confirmed: &confirmed)
        XCTAssertEqual(asked, 0)
        await expectAbort("denied") {
            try await loop.gateExplicit("click", corpus: "Install AnyDesk", denied: [], confirmed: &confirmed)
        }
    }
}
