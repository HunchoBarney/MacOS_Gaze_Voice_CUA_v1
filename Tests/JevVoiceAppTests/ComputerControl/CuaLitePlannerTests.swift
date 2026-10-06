import XCTest
@testable import JevVoice

/// The stateless planner's contract: strict-shape JSON in, advisory plan
/// out — any deviation returns nil and the plain loop runs. Multi-clause
/// gating keeps single-verb goals off the wire entirely.
@MainActor
final class CuaLitePlannerTests: XCTestCase {

    func testParseWellFormedPlan() {
        let plan = CuaLitePlanner.parse(#"{"steps":["open Mail","reply to mom"],"success_contains":["Re:"],"prefer_visual":false,"notes":null}"#)
        XCTAssertEqual(plan?.steps, ["open Mail", "reply to mom"])
        XCTAssertEqual(plan?.successContains, ["Re:"])
        XCTAssertEqual(plan?.hints.preferVisual, false)
    }

    func testParseRejectsMalformedAndEmpty() {
        XCTAssertNil(CuaLitePlanner.parse(""))
        XCTAssertNil(CuaLitePlanner.parse("no json here"))
        XCTAssertNil(CuaLitePlanner.parse("{broken"))
        // A plan with neither steps nor success strings is no plan at all.
        XCTAssertNil(CuaLitePlanner.parse(#"{"steps":[],"success_contains":[]}"#))
        XCTAssertNil(CuaLitePlanner.parse(#"{"steps":["  ",""]}"#))
    }

    func testParseTrimsAndDropsBlankEntries() {
        let plan = CuaLitePlanner.parse(#"{"steps":[" open Safari ",""],"success_contains":[" Tab overview "],"prefer_visual":true,"notes":"reader view"}"#)
        XCTAssertEqual(plan?.steps, ["open Safari"])
        XCTAssertEqual(plan?.successContains, ["Tab overview"])
        XCTAssertEqual(plan?.hints.preferVisual, true)
        XCTAssertEqual(plan?.hints.notes, "reader view")
    }

    func testSuccessContainsAloneIsEnough() {
        let plan = CuaLitePlanner.parse(#"{"success_contains":["Inbox"],"prefer_visual":true}"#)
        XCTAssertEqual(plan?.steps, [])
        XCTAssertEqual(plan?.successContains, ["Inbox"])
        XCTAssertEqual(plan?.hints.preferVisual, true)
    }

    func testMissingClientReturnsNilPlan() async {
        let planner = CuaLitePlanner { nil }
        let plan = await planner.plan(goal: "open Mail then reply", appName: "Mail",
                                      windowTitle: nil, previousContext: nil)
        XCTAssertNil(plan)
    }
}
