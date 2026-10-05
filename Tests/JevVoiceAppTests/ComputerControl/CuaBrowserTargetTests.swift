import XCTest
import JevVoiceCore
@testable import JevVoice

/// Browser binding helpers: tab identity pinning, navigate re-anchoring,
/// and the blank-tab host check that decides whether a fresh signature is
/// really a new tab.
@MainActor
final class CuaBrowserTargetTests: XCTestCase {

    private func tab(_ id: String, url: String, title: String = "", active: Bool = false) -> JSONValue {
        .object(["tab_id": .string(id), "url": .string(url),
                 "title": .string(title), "active": .bool(active)])
    }

    // MARK: - Snapshot shapes

    func testTabsAndRefsAcrossSnapshotContracts() {
        let domRefsV1: JSONValue = .object([
            "target_id": .string("t1"), "tab_id": .string("a"),
            "url": .string("https://example.com"),
            "refs": .array([.object(["ref": .string("r1")])])])
        XCTAssertEqual(CuaBrowserTarget.targetID(domRefsV1), .string("t1"))
        XCTAssertEqual(CuaBrowserTarget.pageRefs(domRefsV1).count, 1)

        let semanticV2: JSONValue = .object([
            "target_id": .string("t1"), "tab_id": .string("a"),
            "page": .object(["url": .string("https://example.com"), "title": .string("Example")]),
            "refs": .array([.object(["ref": .string("r1"), "role": .string("link")])])])
        XCTAssertEqual(CuaBrowserTarget.pageRefs(semanticV2).count, 1)
        XCTAssertTrue(CuaBrowserTarget.pageRefs(.object([:])).isEmpty)
    }

    // MARK: - shownTab

    func testShownTabPrefersEchoedReadIdentity() {
        let state: JSONValue = .object(["tab_id": .string("bound")])
        let tabs = [tab("other", url: "https://a.example", active: true)]
        XCTAssertEqual(CuaBrowserTarget.shownTab(in: state, tabs: tabs, fallback: "stale"), "bound")
    }

    func testShownTabRequiresUniqueActive() {
        let tabs = [tab("a", url: "https://a.example", active: true),
                    tab("b", url: "https://b.example", active: true)]
        // Two active claims are ambiguous — fall back, never guess.
        XCTAssertEqual(CuaBrowserTarget.shownTab(in: .object([:]), tabs: tabs, fallback: "held"), "held")
        let one = [tab("a", url: "https://a.example", active: true),
                   tab("b", url: "https://b.example")]
        XCTAssertEqual(CuaBrowserTarget.shownTab(in: .object([:]), tabs: one, fallback: nil), "a")
        let single = [tab("only", url: "https://only.example")]
        XCTAssertEqual(CuaBrowserTarget.shownTab(in: .object([:]), tabs: single, fallback: nil), "only")
        let cold = [tab("a", url: "https://a.example"), tab("b", url: "https://b.example")]
        XCTAssertNil(CuaBrowserTarget.shownTab(in: .object([:]), tabs: cold, fallback: nil))
    }

    // MARK: - resolveNavigationTab

    func testNavigateWithoutNewTabUsesSingleOrUniqueActive() {
        let single = [tab("a", url: "https://a.example")]
        XCTAssertEqual(CuaBrowserTarget.resolveNavigationTab(tabs: single, baseline: nil, newTabRequested: false)?["tab_id"], .string("a"))
        let active = [tab("a", url: "https://a.example"),
                      tab("b", url: "https://b.example", active: true)]
        XCTAssertEqual(CuaBrowserTarget.resolveNavigationTab(tabs: active, baseline: nil, newTabRequested: false)?["tab_id"], .string("b"))
        let cold = [tab("a", url: "https://a.example"), tab("b", url: "https://b.example")]
        XCTAssertNil(CuaBrowserTarget.resolveNavigationTab(tabs: cold, baseline: nil, newTabRequested: false))
    }

    func testNewTabRequiresBaselineAndUniqueBlankAddition() {
        let fresh = [tab("old", url: "https://a.example"),
                     tab("new", url: "chrome://newtab", active: true)]
        // No baseline: the fresh tab cannot be told apart — refuse.
        XCTAssertNil(CuaBrowserTarget.resolveNavigationTab(tabs: fresh, baseline: nil, newTabRequested: true))

        let baseline = [CuaBrowserTarget.tabSignature(tab("old", url: "https://a.example"))]
        XCTAssertEqual(CuaBrowserTarget.resolveNavigationTab(tabs: fresh, baseline: baseline, newTabRequested: true)?["tab_id"], .string("new"))

        // The added tab already navigated away from blank — not the fresh tab.
        let loaded = [tab("old", url: "https://a.example"),
                      tab("new", url: "https://destination.example", active: true)]
        XCTAssertNil(CuaBrowserTarget.resolveNavigationTab(tabs: loaded, baseline: baseline, newTabRequested: true))

        // A baseline tab disappeared in the same window — ambiguous, refuse.
        let churned = [tab("new", url: "chrome://newtab", active: true)]
        XCTAssertNil(CuaBrowserTarget.resolveNavigationTab(tabs: churned, baseline: baseline, newTabRequested: true))
    }

    func testNewTabDuplicateBlankSignaturePrefersActive() {
        // The user already held a blank tab; the task's fresh one is active.
        let baseline = [CuaBrowserTarget.tabSignature(tab("old", url: "https://a.example")),
                        CuaBrowserTarget.tabSignature(tab("stale", url: "chrome://newtab"))]
        let tabs = [tab("old", url: "https://a.example"),
                    tab("stale", url: "chrome://newtab"),
                    tab("new", url: "chrome://newtab", active: true)]
        XCTAssertEqual(CuaBrowserTarget.resolveNavigationTab(tabs: tabs, baseline: baseline, newTabRequested: true)?["tab_id"], .string("new"))

        // Neither duplicate is marked active — ambiguous, refuse rather than
        // navigate the user's pre-existing tab.
        let inactive = [tab("old", url: "https://a.example"),
                        tab("stale", url: "chrome://newtab"),
                        tab("new", url: "chrome://newtab")]
        XCTAssertNil(CuaBrowserTarget.resolveNavigationTab(tabs: inactive, baseline: baseline, newTabRequested: true))
    }

    // MARK: - isBlankTabURL

    func testBlankTabURLHostEquality() {
        for blank in ["", "about:blank", "about:newtab", "chrome://newtab",
                      "chrome://newtab/", "edge://newtab", "brave://newtab/",
                      "chrome-search://local-ntp", "chrome-search://local-ntp/newtab.html"] {
            XCTAssertTrue(CuaBrowserTarget.isBlankTabURL(blank), blank)
        }
        for real in ["https://example.com", "https://evil.example/?next=chrome://newtab",
                     "https://newtab.example", "chrome://newtab2",
                     "https://example.com/newtab"] {
            XCTAssertFalse(CuaBrowserTarget.isBlankTabURL(real), real)
        }
    }

    // MARK: - Signatures

    func testTabSignatureDeltaIsAMultiset() {
        let (added, removed) = CuaBrowserTarget.tabSignatureDelta(
            from: ["a\u{1F}", "b\u{1F}", "b\u{1F}"], to: ["b\u{1F}", "c\u{1F}"])
        XCTAssertEqual(added, ["c\u{1F}"])
        XCTAssertEqual(removed, ["a\u{1F}", "b\u{1F}"])
        let (noChange, noneRemoved) = CuaBrowserTarget.tabSignatureDelta(from: ["a\u{1F}"], to: ["a\u{1F}"])
        XCTAssertTrue(noChange.isEmpty); XCTAssertTrue(noneRemoved.isEmpty)
    }

    func testCompactTabDropsIdentityFields() {
        let compact = CuaBrowserTarget.compactTab(tab("secret-id", url: "https://a.example", title: "A", active: true))
        XCTAssertNil(compact["tab_id"])
        XCTAssertEqual(compact["url"], .string("https://a.example"))
        XCTAssertEqual(compact["title"], .string("A"))
        XCTAssertEqual(compact["active"], .bool(true))
    }
}
