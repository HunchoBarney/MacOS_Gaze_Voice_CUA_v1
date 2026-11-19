import XCTest
@testable import Jarvis
import JarvisCore

/// Contract for the single-interaction consent radial: one `.choice`
/// ask carries "Yes", "No", and — once the loop knows which app it's
/// touching — "Always for <app>". `consentVerdict` maps every answer
/// shape (chip ordinal, spoken verdict, option name) and fails closed.
/// An "always" persists a (tool, bundle) scoped grant — never a blanket.
final class ConsentRadialTests: XCTestCase {

    private func makeLoop(ask: DriveLoop.AskFn? = nil,
                          grant: Bool = false) -> DriveLoop {
        DriveLoop(call: { _, _ in .object([:]) }, choose: { _, _ in nil },
                  ask: ask, granted: { grant })
    }

    // MARK: - Answer → verdict

    /// Chip ordinals index the radial: 0 Yes, 1 No, 2 Always.
    func testOrdinalAnswersMapToRadialSlots() {
        XCTAssertEqual(DriveLoop.consentVerdict("0", optionCount: 3), .yes)
        XCTAssertEqual(DriveLoop.consentVerdict("1", optionCount: 3), .no)
        XCTAssertEqual(DriveLoop.consentVerdict("2", optionCount: 3), .always)
        // A bare two-option ask has no "always" slot — index 2 is not one.
        XCTAssertEqual(DriveLoop.consentVerdict("2", optionCount: 2), .no)
        XCTAssertEqual(DriveLoop.consentVerdict("9", optionCount: 3), .no)
    }

    /// The literal vocabulary: "always …" persists, affirmatives confirm,
    /// and explicit negatives win over everything — "no, always ask" is
    /// a decline, not a grant.
    func testLiteralAnswersMapToVerdicts() {
        XCTAssertEqual(DriveLoop.consentVerdict("always", optionCount: 3), .always)
        XCTAssertEqual(DriveLoop.consentVerdict("always for Safari", optionCount: 3),
                       .always)
        XCTAssertEqual(DriveLoop.consentVerdict("yes", optionCount: 3), .yes)
        XCTAssertEqual(DriveLoop.consentVerdict("do it", optionCount: 3), .yes)
        XCTAssertEqual(DriveLoop.consentVerdict("no", optionCount: 3), .no)
        XCTAssertEqual(DriveLoop.consentVerdict("no, always ask", optionCount: 3),
                       .no)
        XCTAssertEqual(DriveLoop.consentVerdict("cancel", optionCount: 3), .no)
    }

    /// Anything unparseable — and silence — is a decline, not a yes.
    func testConsentFailsClosed() {
        XCTAssertEqual(DriveLoop.consentVerdict(nil, optionCount: 3), .no)
        XCTAssertEqual(DriveLoop.consentVerdict("flibberty", optionCount: 3), .no)
        XCTAssertEqual(DriveLoop.consentVerdict("", optionCount: 3), .no)
    }

    // MARK: - The ask's shape

    /// No bound app → exactly Yes/No; an "always" has nothing to scope to.
    func testChoiceAskWithoutBoundAppOffersYesNo() async throws {
        var asked: [DriveLoop.Ask] = []
        let loop = makeLoop(ask: { ask in asked.append(ask); return "yes" })
        var confirmed = false
        try await loop.consentGate(tool: "click", args: [:],
                                   elementText: "Save", denied: [],
                                   confirmed: &confirmed)
        XCTAssertEqual(asked, [.choice(prompt: "Allow computer control: click on 'Save'?",
                                      options: ["Yes", "No"])])
        XCTAssertTrue(confirmed)
    }

    /// A bound app adds the third slot, named for the app itself.
    func testChoiceAskWithBoundAppOffersAlwaysForApp() async throws {
        var asked: [DriveLoop.Ask] = []
        let loop = makeLoop(ask: { ask in asked.append(ask); return "yes" })
        // Set what bind would have set — post-resolution the loop knows
        // the target app, so the radial offers "Always for <app>".
        await loop.bindConsentIdentity(name: "Notes", bundleID: "com.apple.Notes")
        var confirmed = false
        try await loop.consentGate(tool: "click", args: [:],
                                   elementText: "Save", denied: [],
                                   confirmed: &confirmed)
        XCTAssertEqual(asked, [.choice(prompt: "Allow computer control: click on 'Save'?",
                                      options: ["Yes", "No", "Always for Notes"])])
        XCTAssertTrue(confirmed)
    }

    /// "Always" with a bound app persists the exact (tool, bundle) pair —
    /// the next same-pair dispatch never re-asks, a different tool still
    /// does, and the standing grant stays off.
    func testAlwaysAnswerPersistsScopedGrantOnly() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-\(UUID().uuidString).json")
        CuaPolicy.policyFileOverride = file
        defer { CuaPolicy.policyFileOverride = nil }

        var askCount = 0
        let loop = makeLoop(ask: { _ in askCount += 1; return "always" })
        // Set what bind would have set — post-resolution the loop knows
        // the target app, so the radial offers "Always for <app>".
        await loop.bindConsentIdentity(name: "Notes", bundleID: "com.apple.Notes")
        var confirmed = false
        try await loop.consentGate(tool: "click", args: [:],
                                   elementText: "Save", denied: [],
                                   confirmed: &confirmed)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(askCount, 1)
        XCTAssertTrue(CuaPolicy.scopedGrantAllows(actionKind: "click",
                                                  appBundleID: "com.apple.Notes"))
        XCTAssertFalse(CuaPolicy.scopedGrantAllows(actionKind: "click",
                                                   appBundleID: "com.apple.Mail"))
        XCTAssertFalse(CuaPolicy.scopedGrantAllows(actionKind: "type_text",
                                                   appBundleID: "com.apple.Notes"))

        // A fresh loop — the persisted grant, not the in-memory confirm —
        // is what skips the second ask.
        let next = makeLoop(ask: { _ in askCount += 1; return "no" })
        await next.bindConsentIdentity(name: "Notes", bundleID: "com.apple.Notes")
        var confirmedAgain = false
        try await next.consentGate(tool: "click", args: [:],
                                   elementText: "Save", denied: [],
                                   confirmed: &confirmedAgain)
        XCTAssertEqual(askCount, 1, "scoped grant must answer before the ask")
        XCTAssertFalse(confirmedAgain, "a scoped grant allows, it does not confirm the task")
    }

    /// "No" declines — the work refuses, no dispatch follows.
    func testNoAnswerDeclines() async {
        let loop = makeLoop(ask: { _ in "no" })
        var confirmed = false
        do {
            try await loop.consentGate(tool: "click", args: [:],
                                       elementText: "Save", denied: [],
                                       confirmed: &confirmed)
            XCTFail("a no must throw declined")
        } catch let error as DriveLoop.Abort {
            guard case .declined = error else {
                return XCTFail("expected .declined, got \(error)")
            }
        } catch {
            XCTFail("expected DriveLoop.Abort, got \(error)")
        }
        XCTAssertFalse(confirmed)
    }

    /// A deny-listed label refuses before any ask exists — the radial is
    /// never armed for protected text.
    func testDeniedLabelNeverAsks() async {
        var asked = 0
        let loop = makeLoop(ask: { _ in asked += 1; return "yes" })
        var confirmed = false
        do {
            try await loop.consentGate(tool: "click", args: [:],
                                       elementText: "Empty Trash", denied: [],
                                       confirmed: &confirmed)
            XCTFail("Empty Trash must refuse outright")
        } catch let error as DriveLoop.Abort {
            guard case .denied = error else {
                return XCTFail("expected .denied, got \(error)")
            }
        } catch {
            XCTFail("expected DriveLoop.Abort, got \(error)")
        }
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(confirmed)
    }
}
