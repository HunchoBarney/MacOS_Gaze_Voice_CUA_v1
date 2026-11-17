import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: the agent-facing describe() must never tell an agent "flip
/// the setting" for a refusal no setting fixes — a deny-list refusal, a
/// denied tool, and a task rule all classify differently from a missing
/// standing grant, and the classification rides `consentBlock`, never
/// reason-string sniffing.
final class CuaDriveServerTests: XCTestCase {

    /// A deny refusal reports itself — the agent relays "this is on the
    /// protected list", not the enable-the-grant remedy.
    func testDescribeDenyRefusalIsNotAGrantHint() {
        let result = DriveResult(
            status: .blockedByConsent("Refused: 'empty trash' is on the protected list — it requires the user's hands, not ours"),
            blockedReason: "Refused: 'empty trash' is on the protected list — it requires the user's hands, not ours",
            consentBlock: .permanent)
        let text = CuaDriveServer.describe(result)
        XCTAssertTrue(text.hasPrefix("Refused:"), text)
        XCTAssertTrue(text.contains("empty trash"), text)
        XCTAssertFalse(text.contains("standing grant"), text)
    }

    /// A denied tool ("'shell_command' is never dispatched") is a
    /// permanent refusal too — previously it fell through to the grant
    /// hint because its reason matched neither sniff.
    func testDescribeDeniedToolIsNotAGrantHint() {
        let result = DriveResult(
            status: .blockedByConsent("'shell_command' changes driver or session state — it is never dispatched through the policy path"),
            blockedReason: "'shell_command' changes driver or session state — it is never dispatched through the policy path",
            consentBlock: .permanent)
        let text = CuaDriveServer.describe(result)
        XCTAssertTrue(text.contains("shell_command"), text)
        XCTAssertTrue(text.contains("never dispatched"), text)
        XCTAssertFalse(text.contains("standing grant"), text)
    }

    /// A per-task deny rule is permanent for the task — the text scopes
    /// it ("blocked for this task") and must not claim the deny list
    /// refuses it on every path.
    func testDescribeTaskRuleRefusalScopesItself() {
        let result = DriveResult(
            status: .blockedByConsent("Refused: 'notes' is blocked for this task."),
            blockedReason: "Refused: 'notes' is blocked for this task.",
            consentBlock: .permanent)
        let text = CuaDriveServer.describe(result)
        XCTAssertTrue(text.contains("blocked for this task"), text)
        XCTAssertFalse(text.contains("every path"), text)
        XCTAssertFalse(text.contains("standing grant"), text)
    }

    /// A declined live confirm relays "not approved" — the user said no;
    /// pointing at the settings toggle misreads that.
    func testDescribeDeclinedRelaysTheRefusal() {
        let result = DriveResult(
            status: .blockedByConsent("The action was not approved."),
            blockedReason: "The action was not approved.",
            consentBlock: .declined)
        let text = CuaDriveServer.describe(result)
        XCTAssertTrue(text.contains("not approved"), text)
        XCTAssertFalse(text.contains("standing grant"), text)
    }

    /// No grant and no ask channel — the only consent block a setting
    /// actually fixes — keeps the grant hint.
    func testDescribeMissingGrantSuggestsTheSetting() {
        let result = DriveResult(
            status: .blockedByConsent("Computer use needs the standing grant"),
            blockedReason: "Computer use needs the standing grant",
            consentBlock: .missingGrant)
        let text = CuaDriveServer.describe(result)
        XCTAssertTrue(text.contains("standing grant"), text)
    }

    /// Done and blocked keep their plain forms — the consent split only
    /// rewords the consent class.
    func testDescribeOtherStatusesUnchanged() {
        XCTAssertTrue(CuaDriveServer.describe(
            DriveResult(status: .done, history: ["clicked Save"],
                        dispatchedEffect: true)).hasPrefix("Done."))
        XCTAssertTrue(CuaDriveServer.describe(
            DriveResult(status: .blocked("no such window"))).contains("no such window"))
    }

    func testBlockedReplyPreservesRecentActuationEvidence() {
        let text = CuaDriveServer.describe(DriveResult(
            status: .blocked("The screen stopped changing."),
            history: ["captured test window", "insert text", "driver refused window_not_key",
                      "re-observed unchanged body"]))
        XCTAssertTrue(text.hasPrefix("Blocked:"))
        XCTAssertTrue(text.contains("driver refused window_not_key"))
        XCTAssertTrue(text.contains("re-observed unchanged body"))
        XCTAssertFalse(text.contains("captured test window"))
        XCTAssertFalse(text.hasPrefix("Done."))
    }
}
