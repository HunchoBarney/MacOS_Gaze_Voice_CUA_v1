import Foundation
import XCTest
@testable import Jarvis

/// Voice "stop" honesty: a bare stop resolves against agents with live
/// turns — never roster order — and an interrupt that fired nothing is
/// reported as nothing-running, not "stopped".
@MainActor
final class VoiceAgentBridgeTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicebridge-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func agent(_ slug: String, name: String? = nil) -> CompanionAgent {
        CompanionAgent(slug: slug, name: name ?? slug, role: "r", description: "d",
                       workspacePath: "/tmp/\(slug)",
                       codexHomePath: "/tmp/\(slug)/codex-home")
    }

    private func makeRuntime() -> (AgentRuntime, AgentStore) {
        let store = AgentStore(directory: root!)
        let bridge = CodexRuntimeBridge(configuration: .init(
            codexBinary: URL(fileURLWithPath: "/bin/false"),
            provider: CodexModelProvider(name: "openai", baseURL: "https://example.invalid",
                                       envKey: "OPENAI_API_KEY", model: "")))
        return (AgentRuntime(store: store, bridge: bridge), store)
    }

    // MARK: resolveStop (pure resolution)

    func testBareStopTargetsTheOnlyActiveTurn() {
        let agents = [agent("idle-a"), agent("busy-b")]
        let resolution = VoiceAgentBridge.resolveStop(hint: nil, agents: agents,
                                                      active: ["busy-b"])
        XCTAssertEqual(resolution, .target("busy-b"))
    }

    func testBareStopWithNoActiveTurnsIsNothingRunning() {
        let agents = [agent("idle-a"), agent("idle-b")]
        XCTAssertEqual(VoiceAgentBridge.resolveStop(hint: nil, agents: agents, active: []),
                       .nothingRunning)
    }

    func testBareStopWithSeveralActiveAsksWhich() {
        let agents = [agent("a", name: "Alpha"), agent("b", name: "Beta")]
        let resolution = VoiceAgentBridge.resolveStop(hint: nil, agents: agents,
                                                      active: ["a", "b"])
        XCTAssertEqual(resolution, .ambiguous(["Alpha", "Beta"]))
    }

    func testHintMatchesNameOrSlugRegardlessOfActivity() {
        let agents = [agent("inbox-desk", name: "Inbox Desk"),
                      agent("inbox-two", name: "Second Inbox")]
        XCTAssertEqual(VoiceAgentBridge.resolveStop(hint: "inbox desk", agents: agents, active: []),
                       .target("inbox-desk"))
        XCTAssertEqual(VoiceAgentBridge.resolveStop(hint: "nobody", agents: agents, active: []),
                       .noMatch)
        XCTAssertEqual(VoiceAgentBridge.resolveStop(hint: "inbox", agents: agents, active: []),
                       .ambiguous(["Inbox Desk", "Second Inbox"]))
    }

    // MARK: interruptAgent (payload level)

    func testNilRuntimeRefuses() async {
        let subject = VoiceAgentBridge(runtime: nil)
        let reply = VoiceToolResult(jsonString: await subject.interruptAgent(hint: nil))
        XCTAssertEqual(reply?.status, "refused")
    }

    func testBareStopWithNoTurnsAnswersNothingRunning() async throws {
        let (runtime, store) = makeRuntime()
        _ = try await store.found(name: "Idle", role: "r", description: "d", root: root)
        let subject = VoiceAgentBridge(runtime: runtime)
        let reply = VoiceToolResult(jsonString: await subject.interruptAgent(hint: nil))
        XCTAssertEqual(reply?.status, "nothing_running")
        XCTAssertEqual(reply?.say, "Nothing is running.")
    }

    func testHintForIdleAgentAnswersNotRunning() async throws {
        let (runtime, store) = makeRuntime()
        _ = try await store.found(name: "Idle", role: "r", description: "d", root: root)
        let subject = VoiceAgentBridge(runtime: runtime)
        let reply = VoiceToolResult(jsonString: await subject.interruptAgent(hint: "idle"))
        XCTAssertEqual(reply?.status, "nothing_running")
        XCTAssertTrue(reply?.say.contains("isn't running") ?? false)
    }

    func testHintForUnknownAgentAnswersNoMatch() async throws {
        let (runtime, store) = makeRuntime()
        _ = try await store.found(name: "Idle", role: "r", description: "d", root: root)
        let subject = VoiceAgentBridge(runtime: runtime)
        let reply = VoiceToolResult(jsonString: await subject.interruptAgent(hint: "ghost"))
        XCTAssertEqual(reply?.status, "nothing_running")
        XCTAssertEqual(reply?.say, "No running agent matches.")
    }

    // MARK: ensureRuntime lazy resolution

    func testEnsureRuntimeRevivesAgentsAfterBootNil() async throws {
        let (runtime, _) = makeRuntime()
        var calls = 0
        let subject = VoiceAgentBridge(runtime: nil, ensureRuntime: {
            calls += 1
            return runtime
        })
        // First call resolves through the hook; the runtime is then kept.
        _ = await subject.interruptAgent(hint: nil)
        _ = await subject.roster()
        XCTAssertEqual(calls, 1, "once resolved, the runtime stays bound")
    }

    func testEnsureRuntimeNilKeepsHonestRefusal() async {
        var calls = 0
        let subject = VoiceAgentBridge(runtime: nil, ensureRuntime: { calls += 1; return nil })
        let reply = VoiceToolResult(jsonString: await subject.interruptAgent(hint: nil))
        XCTAssertEqual(reply?.status, "refused")
        XCTAssertGreaterThanOrEqual(calls, 1)
    }
}
