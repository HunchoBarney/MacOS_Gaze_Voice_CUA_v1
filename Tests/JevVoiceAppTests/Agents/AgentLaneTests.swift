import XCTest
import JevVoiceCore
@testable import JevVoice

/// Lane + per-agent-transport coverage: per-slug driver routing through the
/// gate's `driverFor`, lease ordering around `drive_until` and forwarded
/// input calls, session-spoof prevention, and the suggest_action candidate
/// projection.
@MainActor
final class AgentLaneTests: XCTestCase {

    /// Ordered event sink shared by the lane stub, the driver stub and the
    /// loop's call seam — lets a test assert acquire-before-dispatch and
    /// release-after-completion across actor boundaries.
    private actor OrderLog {
        private(set) var entries: [String] = []
        func add(_ entry: String) { entries.append(entry) }
    }

    private actor RecordingLanes: AgentLaneLeasing {
        let log: OrderLog
        init(log: OrderLog) { self.log = log }
        func acquire(app: String, pid: Int?, workID: String) async throws {
            await log.add("acquire:\(app):\(workID)")
        }
        func acquireFocus(workID: String) async throws {
            await log.add("focus:\(workID)")
        }
        func acquirePasteboard(workID: String) async throws {
            await log.add("pasteboard:\(workID)")
        }
        func releaseAll(workID: String) async {
            await log.add("releaseAll:\(workID)")
        }
    }

    /// Recording driver tagged with an id so per-slug routing is visible in
    /// the shared order log.
    private final class LoggingDriver: DriverToolCalling, @unchecked Sendable {
        let id: String
        let log: OrderLog
        var listApps: JSONValue = .object(["apps": .array([])])
        init(id: String, log: OrderLog) { self.id = id; self.log = log }
        func callResult(_ name: String, arguments: [String: JSONValue]) async throws -> CuaToolResult {
            await log.add("call:\(id):\(name)")
            if name == "list_apps" { return CuaToolResult(structured: listApps, content: []) }
            return CuaToolResult(structured: .object(["ok": .bool(true)]), content: [])
        }
        func tools() async throws -> [JSONValue] {
            [.object(["name": .string("tools-of-\(id)"),
                      "inputSchema": .object(["type": .string("object")])])]
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T; init(_ v: T) { value = v }
    }

    private nonisolated func pick(_ choice: String, _ confidence: Double = 0.9) -> Answer {
        .choice(choice: choice, confidence: confidence, probabilities: [choice: confidence])
    }

    private nonisolated func element(_ index: Int, role: String, label: String,
                         extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "element_index": .number(Double(index)),
            "element_token": .string("tok\(index)"),
            "role": .string(role), "label": .string(label)]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    // MARK: Per-agent driver routing

    /// Each agent's calls run on its own connection — the gate resolves the
    /// driver per request, not once at construction.
    func testDriverForRoutesCallsToTheAgentsOwnConnection() async throws {
        let log = OrderLog()
        let drivers: [String: LoggingDriver] = ["a": LoggingDriver(id: "a", log: log),
                                                "b": LoggingDriver(id: "b", log: log)]
        let gate = ComputerUseGate(driverFor: { drivers[$0 ?? ""] })
        _ = await gate.callTool("list_windows", arguments: .object([:]), agentSlug: "a")
        _ = await gate.callTool("list_windows", arguments: .object([:]), agentSlug: "b")
        let entries = await log.entries
        XCTAssertEqual(entries, ["call:a:list_windows", "call:b:list_windows"])
    }

    /// tools/list resolves the same way — a slug with no minted transport
    /// reads as a closed driver, not another agent's connection.
    func testUnknownSlugHasNoDriver() async throws {
        let gate = ComputerUseGate(driverFor: { _ in nil })
        let result = await gate.callTool("list_windows", arguments: .object([:]), agentSlug: "ghost")
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(result["structuredContent"]?["code"], .string("driver_unavailable"))
    }

    // MARK: Session identity

    /// A caller-supplied session label is rewritten, never trusted — agent A
    /// cannot drive under agent B's identity.
    func testCallerSuppliedSessionIsOverwritten() async throws {
        let driver = StubDriverToolCaller()
        let gate = ComputerUseGate(driver: driver)
        gate.setSessionLabel("agent-inbox-deadbeef", agentSlug: "inbox")
        _ = await gate.callTool("list_windows",
                                arguments: .object(["session": .string("agent-research-spoof")]),
                                agentSlug: "inbox")
        let calls = await driver.calls
        XCTAssertEqual(calls[0].args["session"], .string("agent-inbox-deadbeef"))
    }

    /// Session lifecycle is host-owned — an agent can never start, end or
    /// escalate a driver session even with consent armed; the direct
    /// (nil-slug) path is unaffected.
    func testAgentSessionLifecycleCallsAreDenied() async throws {
        let driver = StubDriverToolCaller()
        let gate = ComputerUseGate(driver: driver)
        gate.approve(ConsentRequest(agentSlug: "a", turnID: nil, summary: "allow", reason: "test"))
        for tool in ["start_session", "end_session", "escalate_session"] {
            let refused = await gate.callTool(tool,
                arguments: .object(["session": .string("agent-a-x")]), agentSlug: "a")
            XCTAssertEqual(refused["structuredContent"]?["refusal"]?["code"],
                           .string("host_owned_tool"), tool)
        }
        var calls = await driver.calls
        XCTAssertTrue(calls.isEmpty, "session lifecycle tools must never reach the driver for agents")
        gate.approve(ConsentRequest(agentSlug: nil, turnID: nil, summary: "allow", reason: "test"))
        _ = await gate.callTool("end_session", arguments: .object([:]), agentSlug: nil)
        calls = await driver.calls
        XCTAssertEqual(calls.map(\.name), ["end_session"])
    }

    // MARK: drive_until lease ordering

    /// The drive holds the target app's lane for the whole run: acquire
    /// precedes the loop's first driver call, release follows the last.
    func testDriveUntilHoldsAppLeaseForTheWholeRun() async throws {
        let log = OrderLog()
        let lanes = RecordingLanes(log: log)
        let call: CuaTaskAgent.Call = { name, _ in
            await log.add("drive-call:\(name)")
            switch name {
            case "list_apps":
                return .object(["apps": .array([.object([
                    "pid": .number(7), "name": .string("Mail"),
                    "bundle_id": .string("com.apple.mail")])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(9)])])])
            case "get_window_state":
                return .object(["elements": .array([.object([
                    "element_index": .number(0), "element_token": .string("tok0"),
                    "role": .string("AXButton"), "label": .string("Open")])]),
                                "title": .string("Inbox")])
            default:
                return .object(["effect": .string("confirmed")])
            }
        }
        var picks = 0
        let judge: CuaTaskAgent.Judge = { _, _ in
            picks += 1
            // A first-turn done with no dispatch is a fabrication — the
            // drive clicks once, then reports done honestly.
            return picks == 1
                ? ["next": self.pick("click_0"), "doneEvidence": self.pick("proven")]
                : ["next": self.pick("done"), "doneEvidence": self.pick("proven")]
        }
        let executor = AgentDriveExecutor(call: call, judge: judge,
                                          agentSlug: "inbox", turnID: { "turn-9" },
                                          leaseIdentity: { _ in "com.apple.mail" },
                                          lanes: lanes)
        let result = try await executor.drive(DriveTask(goal: "read it", pid: 7, windowID: 9))
        XCTAssertEqual(result.status, .done)
        let entries = await log.entries
        XCTAssertEqual(entries.first, "acquire:com.apple.mail:agent-inbox-turn-9")
        XCTAssertEqual(entries.last, "releaseAll:agent-inbox-turn-9")
        let acquireIndex = try XCTUnwrap(entries.firstIndex { $0.hasPrefix("acquire:") })
        let releaseIndex = try XCTUnwrap(entries.lastIndex { $0.hasPrefix("releaseAll:") })
        let firstCall = try XCTUnwrap(entries.firstIndex { $0.hasPrefix("drive-call:") })
        let lastCall = try XCTUnwrap(entries.lastIndex { $0.hasPrefix("drive-call:") })
        XCTAssertLessThan(acquireIndex, firstCall)
        XCTAssertGreaterThan(releaseIndex, lastCall)
    }

    /// A thrown drive still releases the lease — under the same workID.
    func testDriveUntilReleasesLeaseOnError() async throws {
        let log = OrderLog()
        let lanes = RecordingLanes(log: log)
        let executor = AgentDriveExecutor(
            call: { _, _ in throw DriverConnectionError.closed },
            judge: { _, _ in [:] },
            agentSlug: "inbox", turnID: { nil },
            leaseIdentity: { _ in "com.apple.mail" },
            lanes: lanes)
        _ = try? await executor.drive(DriveTask(goal: "x", pid: 7, windowID: 9))
        let entries = await log.entries
        let first = try XCTUnwrap(entries.first)
        let last = try XCTUnwrap(entries.last)
        XCTAssertTrue(first.hasPrefix("acquire:com.apple.mail:agent-inbox-"))
        XCTAssertTrue(last.hasPrefix("releaseAll:agent-inbox-"))
        XCTAssertEqual(String(first.dropFirst("acquire:com.apple.mail:".count)),
                       String(last.dropFirst("releaseAll:".count)),
                       "release must pair the acquire's workID")
    }

    // MARK: Gate leases

    /// An input call resolves its pid to the app identity via list_apps,
    /// takes the app lease, forwards, and releases — strictly in that order.
    func testInputCallTakesAppLeaseAroundForward() async throws {
        let log = OrderLog()
        let lanes = RecordingLanes(log: log)
        let driver = LoggingDriver(id: "a", log: log)
        driver.listApps = .object(["apps": .array([.object([
            "pid": .number(7), "bundle_id": .string("com.example.app"),
            "name": .string("Example")])])])
        let gate = ComputerUseGate(driver: driver, lanes: lanes)
        gate.approve(ConsentRequest(agentSlug: "a", turnID: nil, summary: "allow", reason: "test"))
        let result = await gate.callTool("click",
            arguments: .object(["pid": .number(7)]), agentSlug: "a")
        XCTAssertNil(result["isError"])
        let entries = await log.entries
        let acquireIndex = try XCTUnwrap(entries.firstIndex {
            $0.hasPrefix("acquire:com.example.app:agent-a-gate-") })
        let clickIndex = try XCTUnwrap(entries.firstIndex(of: "call:a:click"))
        let releaseIndex = try XCTUnwrap(entries.lastIndex {
            $0.hasPrefix("releaseAll:agent-a-gate-") })
        XCTAssertLessThan(acquireIndex, clickIndex)
        XCTAssertGreaterThan(releaseIndex, clickIndex)
    }

    /// Focus-class calls take the focus lane; clipboard tools and cmd-c/x/v
    /// hotkeys take the pasteboard lane; observation takes none.
    func testFocusAndPasteboardLeases() async throws {
        CuaStandingGrants.computerUseInput = true
        defer { CuaStandingGrants.computerUseInput = false }
        let log = OrderLog()
        let lanes = RecordingLanes(log: log)
        let gate = ComputerUseGate(driver: LoggingDriver(id: "a", log: log), lanes: lanes)
        _ = await gate.callTool("bring_to_front",
            arguments: .object(["pid": .number(7), "window_id": .number(9)]), agentSlug: "a")
        _ = await gate.callTool("hotkey",
            arguments: .object(["pid": .number(7),
                                "keys": .array([.string("cmd"), .string("v")])]), agentSlug: "a")
        _ = await gate.callTool("clipboard_read", arguments: .object([:]), agentSlug: "a")
        _ = await gate.callTool("list_windows",
            arguments: .object(["pid": .number(7)]), agentSlug: "a")
        let entries = await log.entries
        XCTAssertEqual(entries.filter { $0.hasPrefix("acquire:") }.count, 2,
                       "bring_to_front and hotkey take app leases")
        XCTAssertEqual(entries.filter { $0.hasPrefix("focus:") }.count, 1)
        XCTAssertEqual(entries.filter { $0.hasPrefix("pasteboard:") }.count, 2,
                       "hotkey cmd+v and clipboard_read each take the pasteboard lane")
        XCTAssertEqual(entries.filter { $0.hasPrefix("releaseAll:") }.count, 3)
    }

    /// A refused call takes no lease.
    func testConsentRefusalTakesNoLease() async throws {
        let log = OrderLog()
        let lanes = RecordingLanes(log: log)
        let gate = ComputerUseGate(driver: LoggingDriver(id: "a", log: log), lanes: lanes)
        gate.setActiveTurn("t1", agentSlug: "a")
        let refused = await gate.callTool("click",
            arguments: .object(["pid": .number(7)]), agentSlug: "a")
        XCTAssertEqual(refused["structuredContent"]?["refusal"]?["code"], .string("blocked_by_consent"))
        let entries = await log.entries
        XCTAssertTrue(entries.isEmpty, "a consent refusal must not touch the lanes or the driver")
    }

    // MARK: suggest_action

    /// The projection mirrors the drive loop's filter: enabled elements in
    /// click/text/value roles only, capped, plus the "none" sentinel — and
    /// nothing is ever dispatched.
    func testSuggestActionProjectsCandidates() async throws {
        let log = OrderLog()
        let snapshot: JSONValue = .object([
            "title": .string("Composer"),
            "elements": .array([
                element(0, role: "AXStaticText", label: "Read-only"),
                element(1, role: "AXButton", label: "Send"),
                element(2, role: "AXTextField", label: "Subject"),
                element(3, role: "AXButton", label: "Ghosted", extra: ["enabled": .bool(false)]),
                element(4, role: "AXSlider", label: "Volume")
            ])])
        let asked = Box<[[String: Question]]>([])
        let suggester = AgentActionSuggester(
            call: { name, args in
                await log.add("suggest-call:\(name)")
                return snapshot
            },
            judge: { _, questions in
                asked.value.append(questions)
                return ["next": self.pick("e1", 0.8)]
            })
        let judgment = try await suggester.suggestAction(pid: 7, windowID: 9)
        XCTAssertEqual(judgment.elementToken, "tok1")
        XCTAssertEqual(judgment.kind, .press)
        XCTAssertEqual(judgment.confidence, 0.8)
        guard let question = asked.value.first?["next"],
              case .choice(_, let criteria) = question else {
            return XCTFail("suggest_action must ask one choice question")
        }
        XCTAssertEqual(Set(criteria.keys), ["e1", "e2", "e4", "none"],
                       "disabled and non-interactive elements are never offered")
        XCTAssertEqual(criteria["e2"]??.hasPrefix("Type into"), true)
        // Advisory only: the snapshot read is the sole driver call.
        let entries = await log.entries
        XCTAssertEqual(entries, ["suggest-call:get_window_state"])
    }

    /// A "none" pick reports kind .none; an empty window reports
    /// no_interactive_elements without spending a judge call.
    func testSuggestActionNoneAndEmpty() async throws {
        var suggester = AgentActionSuggester(
            call: { _, _ in .object(["elements": .array([
                self.element(0, role: "AXButton", label: "OK")])]) },
            judge: { _, _ in ["next": self.pick("none", 0.6)] })
        var judgment = try await suggester.suggestAction(pid: 7, windowID: 9)
        XCTAssertEqual(judgment.kind, .none)
        XCTAssertNil(judgment.elementToken)
        XCTAssertEqual(judgment.confidence, 0.6)

        let judgeRan = Box(false)
        suggester = AgentActionSuggester(
            call: { _, _ in .object(["elements": .array([])]) },
            judge: { _, _ in judgeRan.value = true; return [:] })
        judgment = try await suggester.suggestAction(pid: 7, windowID: 9)
        XCTAssertEqual(judgment.kind, .none)
        XCTAssertEqual(judgment.blocked, "no_interactive_elements")
        XCTAssertFalse(judgeRan.value)
    }

    /// End to end through the jev-use surface: a wired server returns the
    /// judgment envelope.
    func testSuggestActionThroughJevUseServer() async throws {
        let suggester = AgentActionSuggester(
            call: { _, _ in .object(["elements": .array([
                self.element(0, role: "AXButton", label: "Save")])]) },
            judge: { _, _ in ["next": self.pick("e0", 0.9)] })
        let server = JevUseMCPServer(executor: RecordingDriveExecutor(), suggester: suggester)
        let result = try await server.callTool(JevUseTools.suggestAction,
            arguments: .object(["pid": .number(7), "window_id": .number(9)]))
        XCTAssertNil(result["isError"])
        XCTAssertEqual(result["structuredContent"]?["element_token"], .string("tok0"))
        XCTAssertEqual(result["structuredContent"]?["kind"], .string("press"))
    }
}
