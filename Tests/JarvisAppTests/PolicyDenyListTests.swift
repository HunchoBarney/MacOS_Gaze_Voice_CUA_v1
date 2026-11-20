import XCTest
@testable import Jarvis
import JarvisCore

/// Contract for the never list: what no grant, spoken command or yes
/// unlocks. Ordinary consequential words (Send, Reply, Delete, Allow)
/// are not on it; those press on the person's own words and ask first
/// otherwise (ConsequenceTests).
final class PolicyDenyListTests: XCTestCase {

    private func decide(_ tool: String, elementText: String,
                        grant: Bool = true) -> CuaPolicy.Decision {
        CuaPolicy.decide(tool: tool, args: [:], elementText: elementText,
                         standingGrant: grant)
    }

    /// Each never-list phrase refuses even under the standing grant.
    func testNeverListDeniesUnderGrant() {
        for text in [
            "Empty Trash", "Erase This Mac", "Factory Reset", "Wire Transfer",
            "Delete Account", "Allow Remote Access", "Download AnyDesk", "Buy gift card",
        ] {
            guard case .deny = decide("click", elementText: text) else {
                return XCTFail("'\(text)' must deny under the standing grant")
            }
        }
    }

    /// The flat refusal of everyday words is gone: one policy, not two.
    func testEverydayWordsAreNotOnTheList() {
        for text in ["Move to Trash", "Delete", "Send", "Reply", "Reply All", "Checkout",
                     "Place your order", "Buy now", "Sign out", "Allow", "Reset"] {
            XCTAssertNil(CuaPolicy.deniedPhrase(in: text), text)
        }
    }

    /// Separator-normalized matching: "Erase-This-Mac" is the same phrase
    /// with hyphens for spaces.
    func testNormalizedMatching() {
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: "the Erase-This-Mac item"), "erase this mac")
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: "the Empty Trash menu item"), "empty trash")
        XCTAssertNil(CuaPolicy.deniedPhrase(in: ""))
    }

    /// The `[String]` corpus overload — the five-field IntentCandidate
    /// safety corpus a committed referent carries.
    func testCorpusOverloadScansEveryEntry() {
        XCTAssertNil(CuaPolicy.deniedPhrase(in: ["Save", "", "Notes"]))
        XCTAssertEqual(
            CuaPolicy.deniedPhrase(
                in: ["Buy", "AXButton", "https://shop.example/gift-card", "Shop", "Cart"]),
            "gift card")
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: ["OK", "", "", "Factory Reset"]),
                       "factory reset")
    }

    /// A never-list label inside `decide` denies before the grant, and a
    /// clean label still flows.
    func testDecideOrderingUnchanged() {
        guard case .deny = decide("click", elementText: "Delete Account", grant: true) else {
            return XCTFail("deny must precede the grant")
        }
        XCTAssertEqual(decide("click", elementText: "Save File", grant: true), .allow)
    }
}
