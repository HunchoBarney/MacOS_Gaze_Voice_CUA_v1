import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract for the expanded phrase list: consequential vocabulary that
/// previously only the dwell lane refused now walls every path — the
/// bare words match their inflections ("delete" covers "Delete Draft"),
/// and a security dialog's "Allow" refuses like any protected phrase.
final class PolicyDenyListTests: XCTestCase {

    private func decide(_ tool: String, elementText: String,
                        grant: Bool = true) -> CuaPolicy.Decision {
        CuaPolicy.decide(tool: tool, args: [:], elementText: elementText,
                         standingGrant: grant)
    }

    /// Each expansion phrase refuses even under the standing grant —
    /// deny ordering is unchanged, grant never precedes it.
    func testExpandedPhrasesDenyUnderGrant() {
        for text in [
            "Move to Trash", "Delete", "Send", "Reply", "Reply All",
            "Checkout", "Place your order", "Buy now", "Confirm purchase",
            "Sign out", "Erase", "Format", "Reset",
        ] {
            guard case .deny = decide("click", elementText: text) else {
                return XCTFail("'\(text)' must deny under the standing grant")
            }
        }
    }

    /// The security-dialog "Allow" — a privilege prompt must never be
    /// answered by the loop, whichever app drew it.
    func testAllowDialogRefuses() {
        guard case .deny = decide("click",
                                  elementText: "Allow — wants access to the microphone") else {
            return XCTFail("an Allow consent dialog must deny")
        }
        XCTAssertNotNil(CuaPolicy.deniedPhrase(in: "Allow"))
    }

    /// Bare entries deliberately cover their inflections — "deleted" and
    /// "resend" are the same effect spelled differently.
    func testBareWordsMatchInflections() {
        XCTAssertNotNil(CuaPolicy.deniedPhrase(in: "Delete Draft"))
        XCTAssertNotNil(CuaPolicy.deniedPhrase(in: "Resend message"))
        XCTAssertNotNil(CuaPolicy.deniedPhrase(in: "Replying all"))
    }

    /// Separator-normalized matching is preserved through the hoist:
    /// "Move-To-Trash" is the same phrase with hyphens for spaces.
    func testNormalizedMatchingSurvivesHoist() {
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: "the Move-To-Trash item"),
                       "move to trash")
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: "the Empty Trash menu item"),
                       "empty trash")
        XCTAssertNil(CuaPolicy.deniedPhrase(in: ""))
    }

    /// First hit in list order reports the fuller phrase — "empty trash"
    /// outranks the bare "delete" only when it actually appears; order in
    /// `deniedPatterns` is the order the hoist preserves.
    func testFirstHitReportsSpecificPhrase() {
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: "send payment now"),
                       "send payment")
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: "send it"),
                       "send")
    }

    /// The `[String]` corpus overload — the five-field IntentCandidate
    /// safety corpus a committed referent carries.
    func testCorpusOverloadScansEveryEntry() {
        XCTAssertNil(CuaPolicy.deniedPhrase(in: ["Save", "", "Notes"]))
        XCTAssertEqual(
            CuaPolicy.deniedPhrase(
                in: ["Buy", "AXButton", "https://shop.example/checkout",
                     "Shop", "Cart"]),
            "checkout")
        // Any field may carry the hit — app name as much as the label.
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: ["OK", "", "", "Factory Reset"]),
                       "factory reset")
    }

    /// A protected label inside `decide` still denies before the grant,
    /// and a clean label still flows.
    func testDecideOrderingUnchanged() {
        guard case .deny = decide("click", elementText: "Sign out",
                                  grant: true) else {
            return XCTFail("deny must precede the grant")
        }
        XCTAssertEqual(decide("click", elementText: "Save File", grant: true),
                       .allow)
    }
}
