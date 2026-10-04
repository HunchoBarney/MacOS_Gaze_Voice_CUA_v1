import XCTest
import JevVoiceCore
@testable import JevVoice

final class ComputerUseGateTests: XCTestCase {
    private func fixture() -> (ComputerUseGate, StubDriverToolCaller) {
        let driver = StubDriverToolCaller()
        return (ComputerUseGate(driver: driver), driver)
    }

    private func refusalCode(_ result: JSONValue) -> String? {
        result["structuredContent"]?["refusal"]?["code"]?.string
    }

    func testObservationPassesWithoutConsent() async throws {
        let (gate, driver) = fixture()
        let result = await gate.callTool("list_windows", arguments: .object([:]), agentSlug: "inbox")
        XCTAssertNil(result["isError"])
        XCTAssertEqual(result["structuredContent"]?["ok"], .bool(true))
        let calls = await driver.calls
        XCTAssertEqual(calls.map(\.name), ["list_windows"])
        XCTAssertTrue(gate.pending().isEmpty)
    }

    func testInputRefusedUntilApproved() async throws {
        let (gate, driver) = fixture()
        gate.setActiveTurn("turn-1", agentSlug: "inbox")
        for tool in ["click", "type_text", "press_key", "browser_click"] {
            let refused = await gate.callTool(tool, arguments: .object(["pid": .number(7)]), agentSlug: "inbox")
            XCTAssertEqual(refused["isError"], .bool(true), tool)
            XCTAssertEqual(refusalCode(refused), "blocked_by_consent", tool)
        }
        var calls = await driver.calls
        XCTAssertEqual(calls.count, 0)

        let pending = gate.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].agentSlug, "inbox")
        XCTAssertEqual(pending[0].turnID, "turn-1")
        XCTAssertEqual(pending[0].state, .pending)

        gate.approve(ConsentRequest(agentSlug: "inbox", turnID: "turn-1", summary: "allow", reason: "test"))
        XCTAssertTrue(gate.pending().isEmpty)

        let allowed = await gate.callTool("click", arguments: .object(["pid": .number(7)]), agentSlug: "inbox")
        XCTAssertNil(allowed["isError"])
        calls = await driver.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "click")
        XCTAssertEqual(calls[0].args["delivery_mode"], .string(ConsentContract.requiredDeliveryMode))
        XCTAssertEqual(calls[0].args["pid"], .number(7))
    }

    func testApprovalNeverCrossesAgentOrTurn() async throws {
        let (gate, driver) = fixture()
        gate.setActiveTurn("t1", agentSlug: "a")
        gate.setActiveTurn("t1", agentSlug: "b")
        gate.approve(ConsentRequest(agentSlug: "a", turnID: "t1", summary: "allow", reason: "test"))

        let other = await gate.callTool("click", arguments: .object([:]), agentSlug: "b")
        XCTAssertEqual(refusalCode(other), "blocked_by_consent")

        gate.setActiveTurn("t2", agentSlug: "a")
        let nextTurn = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertEqual(refusalCode(nextTurn), "blocked_by_consent")
        let calls = await driver.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testDenyListEnforcedCaseInsensitiveOnLabelArgs() async throws {
        let (gate, driver) = fixture()
        gate.setDenyList(["delete"], agentSlug: "a")
        gate.approve(ConsentRequest(agentSlug: "a", turnID: nil, summary: "allow", reason: "test"))
        for key in ["elementLabel", "label", "name"] {
            let refused = await gate.callTool("press_element",
                arguments: .object([key: .string("DELETE File permanently")]), agentSlug: "a")
            XCTAssertEqual(refusalCode(refused), "denied_label", key)
        }
        let clean = await gate.callTool("press_element",
            arguments: .object(["label": .string("Save")]), agentSlug: "a")
        XCTAssertNil(clean["isError"])
        // A caller without a deny list is not restricted by another's.
        gate.approve(ConsentRequest(agentSlug: "b", turnID: nil, summary: "allow", reason: "test"))
        let other = await gate.callTool("press_element",
            arguments: .object(["label": .string("DELETE File permanently")]), agentSlug: "b")
        XCTAssertNil(other["isError"])
        let calls = await driver.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testDesktopScopeRefusedEvenWhenApproved() async throws {
        let (gate, driver) = fixture()
        gate.approve(ConsentRequest(agentSlug: "a", turnID: nil, summary: "allow", reason: "test"))
        let refused = await gate.callTool("click",
            arguments: .object(["scope": .string("desktop"), "x": .number(10), "y": .number(20)]), agentSlug: "a")
        XCTAssertEqual(refusalCode(refused), "scope_refused")
        let read = await gate.callTool("get_desktop_state",
            arguments: .object(["scope": .string("desktop")]), agentSlug: "a")
        XCTAssertEqual(refusalCode(read), "scope_refused")
        let calls = await driver.calls
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(gate.pending().isEmpty)
    }

    func testForegroundDeliveryModeRefused() async throws {
        let (gate, driver) = fixture()
        gate.approve(ConsentRequest(agentSlug: "a", turnID: nil, summary: "allow", reason: "test"))
        let refused = await gate.callTool("type_text",
            arguments: .object(["delivery_mode": .string("foreground"), "text": .string("x")]), agentSlug: "a")
        XCTAssertEqual(refusalCode(refused), "delivery_mode_required")
        let calls = await driver.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testDenyBlocksPendingAndFutureCallsForThatTurn() async throws {
        let (gate, driver) = fixture()
        gate.setActiveTurn("t1", agentSlug: "a")
        _ = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        let ask = try XCTUnwrap(gate.pending().first)
        gate.deny(ask)
        XCTAssertTrue(gate.pending().isEmpty)
        let refused = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertEqual(refusalCode(refused), "blocked_by_consent")
        XCTAssertTrue(gate.pending().isEmpty, "a denied turn must not re-ask")
        let calls = await driver.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testDriverRefusalPropagatesAsToolError() async throws {
        let (gate, driver) = fixture()
        gate.approve(ConsentRequest(agentSlug: "a", turnID: nil, summary: "allow", reason: "test"))
        await driver.failWith(DriverConnectionError.toolRefused(tool: "click", code: "menu_path_unavailable"))
        let result = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(result["structuredContent"]?["refusal"]?["code"], .string("menu_path_unavailable"))
    }

    func testGateEndToEndOverLoopback() async throws {
        let (gate, driver) = fixture()
        gate.setActiveTurn("t1", agentSlug: "inbox")
        let server = gate.server(agentSlug: "inbox")
        let endpoint = try await server.start()

        let (_, refused) = try await mcpPost(endpoint, mcpRequest(1, "tools/call", .object([
            "name": .string("click"), "arguments": .object([:])
        ])))
        XCTAssertEqual(refused?["result"]?["structuredContent"]?["refusal"]?["code"], .string("blocked_by_consent"))

        gate.approve(ConsentRequest(agentSlug: "inbox", turnID: "t1", summary: "allow", reason: "test"))
        let (_, allowed) = try await mcpPost(endpoint, mcpRequest(2, "tools/call", .object([
            "name": .string("click"), "arguments": .object([:])
        ])))
        XCTAssertNil(allowed?["result"]?["isError"])
        XCTAssertEqual(allowed?["result"]?["structuredContent"]?["ok"], .bool(true))
        let calls = await driver.calls
        XCTAssertEqual(calls.first?.args["delivery_mode"], .string("background"))
        await server.stop()
    }
}
