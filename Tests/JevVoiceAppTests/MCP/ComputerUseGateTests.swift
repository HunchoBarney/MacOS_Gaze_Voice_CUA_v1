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

    func testNestedDesktopTargetRefused() async throws {
        let (gate, driver) = fixture()
        gate.setActiveTurn("t1", agentSlug: "a")
        gate.approve(ConsentRequest(agentSlug: "a", turnID: "t1", summary: "allow", reason: "test"))
        let nested = await gate.callTool("click",
            arguments: .object(["target": .object(["kind": .string("desktop"), "x": .number(10), "y": .number(20)])]),
            agentSlug: "a")
        XCTAssertEqual(refusalCode(nested), "scope_refused")
        let inArray = await gate.callTool("click",
            arguments: .object(["targets": .array([
                .object(["kind": .string("window"), "window_id": .number(9)]),
                .object(["kind": .string("desktop")])
            ])]), agentSlug: "a")
        XCTAssertEqual(refusalCode(inArray), "scope_refused")
        let deep = await gate.callTool("click",
            arguments: .object(["target": .object(["kind": .string("element"),
                "fallback": .object(["kind": .string("desktop")])])]), agentSlug: "a")
        XCTAssertEqual(refusalCode(deep), "scope_refused")
        let calls = await driver.calls
        XCTAssertEqual(calls.count, 0)
        XCTAssertTrue(gate.pending().isEmpty, "a refused scope must not record a consent ask")
    }

    func testUnknownAndMutatorToolsAreConsentGated() async throws {
        let (gate, driver) = fixture()
        gate.setActiveTurn("t1", agentSlug: "a")
        for tool in ["kill_app", "move_cursor", "right_click", "clipboard_write",
                     "bring_to_front", "browser_download", "page", "replay_trajectory",
                     "install_helper", "set_config", "some_future_tool"] {
            let refused = await gate.callTool(tool, arguments: .object([:]), agentSlug: "a")
            XCTAssertEqual(refused["isError"], .bool(true), tool)
            XCTAssertEqual(refusalCode(refused), "blocked_by_consent", tool)
        }
        var calls = await driver.calls
        XCTAssertEqual(calls.count, 0)

        gate.approve(ConsentRequest(agentSlug: "a", turnID: "t1", summary: "allow", reason: "test"))
        let allowed = await gate.callTool("some_future_tool", arguments: .object([:]), agentSlug: "a")
        XCTAssertNil(allowed["isError"])
        calls = await driver.calls
        XCTAssertEqual(calls.map(\.name), ["some_future_tool"])
        XCTAssertEqual(calls[0].args["delivery_mode"], .string(ConsentContract.requiredDeliveryMode))
    }

    func testNilTurnApprovalIsOneShot() async throws {
        let (gate, driver) = fixture()
        gate.approve(ConsentRequest(agentSlug: "a", turnID: nil, summary: "allow", reason: "test"))
        let first = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertNil(first["isError"])
        let second = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertEqual(refusalCode(second), "blocked_by_consent")
        var calls = await driver.calls
        XCTAssertEqual(calls.count, 1, "one yes forwards exactly one input call")

        // The consumed approval produced a fresh ask; approving it re-arms once.
        let ask = try XCTUnwrap(gate.pending().first)
        gate.approve(ask)
        let third = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertNil(third["isError"])
        calls = await driver.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testNilTurnDenialExpiresAndReAsks() async throws {
        let clock = TestClock()
        let driver = StubDriverToolCaller()
        let gate = ComputerUseGate(driver: driver, nilTurnDenialTTL: 60, now: { clock.now })
        _ = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        let ask = try XCTUnwrap(gate.pending().first)
        gate.deny(ask)
        let refused = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertEqual(refusalCode(refused), "blocked_by_consent")
        XCTAssertTrue(gate.pending().isEmpty, "a fresh denial must not re-ask")

        clock.advance(61)
        _ = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertEqual(gate.pending().count, 1, "an expired nil-turn denial must re-ask")
    }

    func testTurnChangePrunesDeadAsksAndApprovals() async throws {
        let (gate, driver) = fixture()
        gate.setActiveTurn("t1", agentSlug: "a")
        _ = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertEqual(gate.pending().count, 1)
        gate.approve(ConsentRequest(agentSlug: "a", turnID: "t1", summary: "allow", reason: "test"))

        gate.setActiveTurn("t2", agentSlug: "a")
        XCTAssertTrue(gate.pending().isEmpty, "dead-turn asks must not poison pending()")

        // Returning to the old turn does not resurrect its approval.
        gate.setActiveTurn("t1", agentSlug: "a")
        let refused = await gate.callTool("click", arguments: .object([:]), agentSlug: "a")
        XCTAssertEqual(refusalCode(refused), "blocked_by_consent")
        let calls = await driver.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testPendingAsksAreCapped() async throws {
        let (gate, _) = fixture()
        for index in 0..<140 {
            gate.setActiveTurn("t-\(index)", agentSlug: "agent-\(index)")
            _ = await gate.callTool("click", arguments: .object([:]), agentSlug: "agent-\(index)")
        }
        XCTAssertLessThanOrEqual(gate.pending().count, 128)
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

    // MARK: Integration additions (assertPermittedNow + per-agent sessions)

    /// jev-use's drive_until asserts through the gate's live-turn resolution —
    /// the same key callTool builds internally, so one approval covers both
    /// tool surfaces.
    func testAssertPermittedNowUsesLiveTurn() async throws {
        let (gate, _) = fixture()
        gate.setActiveTurn("turn-9", agentSlug: "inbox")
        XCTAssertThrowsError(try gate.assertPermittedNow(tool: "drive_until", agentSlug: "inbox"))
        gate.approve(ConsentRequest(agentSlug: "inbox", turnID: "turn-9",
                                    summary: "ask", reason: "test"))
        XCTAssertNoThrow(try gate.assertPermittedNow(tool: "drive_until", agentSlug: "inbox"))
        // Approval is (agent, turn)-scoped — a different turn re-blocks.
        gate.setActiveTurn("turn-10", agentSlug: "inbox")
        XCTAssertThrowsError(try gate.assertPermittedNow(tool: "drive_until", agentSlug: "inbox"))
    }

    /// A stale assertPermittedNow call can never arm another agent's turn.
    func testAssertPermittedNowNeverCrossesAgents() async throws {
        let (gate, _) = fixture()
        gate.setActiveTurn("turn-1", agentSlug: "inbox")
        gate.approve(ConsentRequest(agentSlug: "inbox", turnID: "turn-1",
                                    summary: "ask", reason: "test"))
        gate.setActiveTurn("turn-2", agentSlug: "research")
        XCTAssertThrowsError(try gate.assertPermittedNow(tool: "drive_until", agentSlug: "research"))
        XCTAssertNoThrow(try gate.assertPermittedNow(tool: "drive_until", agentSlug: "inbox"))
    }

    /// Agent calls carry a per-agent driver session — the badge + session
    /// cursor the driver renders are this agent's visible identity.
    func testAgentCallsInjectPerAgentSession() async throws {
        let (gate, driver) = fixture()
        _ = await gate.callTool("list_windows", arguments: .object([:]), agentSlug: "inbox-desk")
        _ = await gate.callTool("list_windows", arguments: .object([:]), agentSlug: "research")
        let calls = await driver.calls
        XCTAssertEqual(calls[0].args["session"], .string("agent-inbox-desk"))
        XCTAssertEqual(calls[1].args["session"], .string("agent-research"))
    }

    /// The companion's direct path (nil agent) never gains a session rewrite —
    /// and a caller-supplied session is never clobbered.
    func testSessionInjectionLeavesDirectAndExplicitCallsAlone() async throws {
        let (gate, driver) = fixture()
        _ = await gate.callTool("list_windows", arguments: .object([:]), agentSlug: nil)
        _ = await gate.callTool("list_windows",
                                arguments: .object(["session": .string("caller")]),
                                agentSlug: "inbox")
        let calls = await driver.calls
        XCTAssertNil(calls[0].args["session"])
        XCTAssertEqual(calls[1].args["session"], .string("caller"))
    }
}
