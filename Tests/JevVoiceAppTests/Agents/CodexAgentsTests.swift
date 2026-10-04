import XCTest
import JevVoiceCore
@testable import JevVoice

final class CodexFramesTests: XCTestCase {
    func testResponsesAndNotificationsWithoutJSONRPCMemberAreAccepted() throws {
        var frames = CodexFrames()
        let bytes = Data("""
        {"id":1,"result":{"codexHome":"/x"}}
        {"method":"item/agentMessage/delta","params":{"delta":"猫"},"emittedAtMs":1}

        """.utf8)
        var values: [JSONValue] = []
        for byte in bytes { values += try frames.append(Data([byte])) }
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0]["result"]?["codexHome"], .string("/x"))
        XCTAssertEqual(values[1]["params"]?["delta"], .string("猫"))
    }

    func testNonObjectLinesAndOversizeFailClosed() throws {
        var frames = CodexFrames(limit: 32)
        XCTAssertThrowsError(try frames.append(Data(repeating: 65, count: 33)))
        frames = CodexFrames()
        XCTAssertThrowsError(try frames.append(Data("not-json\n".utf8)))
        frames = CodexFrames()
        XCTAssertThrowsError(try frames.append(Data("[1,2]\n".utf8)))
        frames = CodexFrames()
        XCTAssertThrowsError(try frames.append(Data("\"str\"\n".utf8)))
    }
}

final class CodexProtocolClientTests: XCTestCase {
    private func fixture() throws -> (CodexProtocolClient, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fixture-\(UUID().uuidString).py")
        try #"""
import json,sys
for line in sys.stdin:
    req=json.loads(line)
    method=req.get('method')
    if method is None:
        # A client→server answer to our requestApproval: echo it back as a
        # notification so the test can verify the client declined.
        print(json.dumps({'method':'fixture/clientAnswer','params':{'answer':req}}),flush=True)
        continue
    id=req.get('id')
    if method=='initialize':
        print(json.dumps({'id':id,'result':{'userAgent':'fixture','codexHome':'/tmp/mock','platformFamily':'unix','platformOs':'macos'}}),flush=True)
    elif method=='initialized':
        continue
    elif method=='thread/start':
        print(json.dumps({'id':id,'result':{'thread':{'id':'thr-1'}}}),flush=True)
        print(json.dumps({'method':'thread/started','params':{'thread':{'id':'thr-1'}}}),flush=True)
    elif method=='thread/resume':
        print(json.dumps({'id':id,'result':{'thread':{'id':req['params']['threadId']}}}),flush=True)
    elif method=='turn/start':
        print(json.dumps({'id':id,'result':{'turn':{'id':'turn-1','status':'inProgress'}}}),flush=True)
        print(json.dumps({'jsonrpc':'2.0','id':'srv-1','method':'item/commandExecution/requestApproval','params':{'command':'ls'}}),flush=True)
        # Block until the client answers the approval ask, echo it back as a
        # notification so the test can verify it declined, then finish the turn.
        answer=json.loads(sys.stdin.readline())
        print(json.dumps({'method':'fixture/clientAnswer','params':{'answer':answer}}),flush=True)
        print(json.dumps({'method':'turn/started','params':{'threadId':'thr-1','turn':{'id':'turn-1','status':'inProgress'}}}),flush=True)
        print(json.dumps({'method':'item/started','params':{'threadId':'thr-1','turnId':'turn-1','item':{'id':'it-1','type':'agentMessage'}}}),flush=True)
        print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':'thr-1','turnId':'turn-1','itemId':'it-1','delta':'Hel'}}),flush=True)
        print(json.dumps({'method':'item/agentMessage/delta','params':{'threadId':'thr-1','turnId':'turn-1','itemId':'it-1','delta':'lo'}}),flush=True)
        print(json.dumps({'method':'item/completed','params':{'threadId':'thr-1','turnId':'turn-1','item':{'id':'it-1','type':'agentMessage','text':'Hello'}}}),flush=True)
        print(json.dumps({'method':'turn/completed','params':{'threadId':'thr-1','turn':{'id':'turn-1','status':'completed','error':None}}}),flush=True)
    elif method=='turn/interrupt':
        print(json.dumps({'id':id,'result':{}}),flush=True)
    elif method=='bad':
        print('invalid-json',flush=True)
        continue
    else:
        print(json.dumps({'id':id,'result':{}}),flush=True)
"""#.write(to: path, atomically: true, encoding: .utf8)
        return (CodexProtocolClient(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                    arguments: ["-u", path.path]), path)
    }

    func testThreadTurnRoundTripAndServerRequestDecline() async throws {
        let (client, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        var events = client.events.makeAsyncIterator()
        try await client.start()
        let codexHome = await client.codexHome
        XCTAssertEqual(codexHome, "/tmp/mock")
        let threadID = try await client.startThread(cwd: "/tmp/ws", model: "m")
        XCTAssertEqual(threadID, "thr-1")
        let turnID = try await client.startTurn(threadID: threadID, text: "hi")
        XCTAssertEqual(turnID, "turn-1")
        var deltas = "", sawServerRequest = false, sawDecline = false
        var sawItem = false, completed: CodexTurnResult?
        while completed == nil {
            guard let event = await events.next() else { break }
            switch event {
            case .agentMessageDelta(_, _, _, let delta): deltas += delta
            case .itemStarted(_, _, let item): if item["type"] == .string("agentMessage") { sawItem = true }
            case .serverRequest(let method, _):
                XCTAssertEqual(method, "item/commandExecution/requestApproval")
                sawServerRequest = true
            case .turnCompleted(_, let turn): completed = turn
            case .other(_, let params):
                if params["answer"]?["result"]?["decision"] == .string("decline") { sawDecline = true }
            default: break
            }
        }
        XCTAssertEqual(deltas, "Hello")
        XCTAssertTrue(sawItem)
        XCTAssertTrue(sawServerRequest)
        XCTAssertTrue(sawDecline)
        XCTAssertEqual(completed, CodexTurnResult(id: "turn-1", status: "completed"))
        try await client.interruptTurn(threadID: threadID, turnID: turnID)
        await client.close()
    }

    func testResumeThreadEchoesID() async throws {
        let (client, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try await client.start()
        let threadID = try await client.resumeThread("thr-old", cwd: "/tmp/ws")
        XCTAssertEqual(threadID, "thr-old")
        await client.close()
    }

    func testMalformedStreamClosesTransport() async throws {
        let (client, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try await client.start()
        do { _ = try await client.call("bad"); XCTFail("Accepted broken stream") }
        catch { XCTAssertTrue(error is CodexConnectionError) }
        do { _ = try await client.call("echo"); XCTFail("Reconnected automatically") }
        catch { XCTAssertEqual(error as? CodexConnectionError, .closed) }
        await client.close()
    }

    /// Opt-in end-to-end check against the installed codex binary: real
    /// initialize → thread/start → turn/start → streamed events →
    /// turn/completed. Needs the user's own CODEX_HOME auth; the thread is
    /// ephemeral so nothing is persisted.
    func testLiveCodexAppServerRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Opt-in live codex app-server check")
        }
        let binary = environment["JEV_CODEX_BINARY"] ?? NSHomeDirectory() + "/.local/bin/codex"
        let client = CodexProtocolClient(executable: URL(fileURLWithPath: binary),
                                       onStderrLine: { print("[codex]", $0) })
        try await client.start()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("jev-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // Omit no model: an account may pin an incompatible default in
        // config.toml — JEV_CODEX_MODEL overrides, else the observed default.
        let threadID = try await client.startThread(
            cwd: workspace.path, model: environment["JEV_CODEX_MODEL"] ?? "gpt-6-astra",
            ephemeral: true)
        XCTAssertFalse(threadID.isEmpty)
        let turnID = try await client.startTurn(threadID: threadID,
                                                text: "Reply with exactly the word: ok")
        var sawDelta = false, result: CodexTurnResult?
        let deadline = Date().addingTimeInterval(120)
        for await event in client.events {
            if case .agentMessageDelta = event { sawDelta = true }
            if case .turnCompleted(_, let turn) = event { result = turn; break }
            if Date() > deadline { break }
        }
        XCTAssertTrue(sawDelta, "no agentMessage deltas streamed for turn \(turnID)")
        XCTAssertEqual(result?.status, "completed",
                       "turn did not complete: \(result?.errorMessage ?? "no turn/completed event")")
        await client.close()
    }
}

final class AgentMarkersTests: XCTestCase {
    func testRoutineMarkersDecodeBothKeyStyles() {
        let text = """
        Done. <ROUTINE>{"action":"create","every_minutes":60,"title":"Mail sweep","task":"Check inbox"}</ROUTINE>
        <ROUTINE>{"action":"pause","routine_id":"r-9"}</ROUTINE>
        <ROUTINE>{"action":"resume","routineId":"r-9"}</ROUTINE>
        """
        let markers = AgentMarkers.routines(in: text)
        XCTAssertEqual(markers, [
            AgentMarkers.RoutineMarker(action: "create", everyMinutes: 60,
                                       title: "Mail sweep", task: "Check inbox"),
            AgentMarkers.RoutineMarker(action: "pause", routineID: "r-9"),
            AgentMarkers.RoutineMarker(action: "resume", routineID: "r-9"),
        ])
    }

    func testMalformedRoutineJSONIsSkipped() {
        XCTAssertEqual(AgentMarkers.routines(in: "<ROUTINE>{oops</ROUTINE>").count, 0)
        XCTAssertEqual(AgentMarkers.routines(in: "no markers").count, 0)
    }

    func testComputerUseRequestBothCloseVariants() {
        let text = "I need to act. <COMPUTER_USE_REQUEST>Click Send in Mail?</COMPUTER_USE_REQUEST> and <COMPUTER_USE_REQUEST>Approve window focus</>"
        XCTAssertEqual(AgentMarkers.computerUseRequests(in: text),
                       ["Click Send in Mail?", "Approve window focus"])
    }

    func testStrippingMarkersLeavesVisibleReply() {
        let text = "All set. <ROUTINE>{\"action\":\"create\",\"every_minutes\":5,\"task\":\"t\"}</ROUTINE> <COMPUTER_USE_REQUEST>ok?</> Cheers."
        XCTAssertEqual(AgentMarkers.strippingMarkers(text), "All set.   Cheers.")
    }
}

final class AgentWorkspaceTests: XCTestCase {
    func testSlugify() {
        XCTAssertEqual(AgentWorkspace.slugify("Inbox Desk"), "inbox-desk")
        XCTAssertEqual(AgentWorkspace.slugify("  Pitch  Lab! "), "pitch-lab")
        XCTAssertEqual(AgentWorkspace.slugify("!!!"), "agent")
    }

    func testPrepareScaffoldsWorkspaceAndNeverOverwritesAgentsMD() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try AgentWorkspace.prepare(slug: "inbox-desk", name: "Inbox Desk",
                                                   role: "Mail Triage", description: "Triage mail.",
                                                   root: root)
        for sub in ["output", "tmp", "codex-home", "AGENTS.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(sub).path), sub)
        }
        var agentsMD = try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(agentsMD.contains("# Inbox Desk"))
        XCTAssertTrue(agentsMD.contains("## Standing preferences"))
        XCTAssertTrue(agentsMD.contains("## Notes"))
        try "custom".write(to: workspace.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        _ = try AgentWorkspace.prepare(slug: "inbox-desk", name: "Other", role: "r", description: "d", root: root)
        agentsMD = try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertEqual(agentsMD, "custom")
    }
}

final class AgentStoreTests: XCTestCase {
    func testFoundPersistReloadAndThreadTracking() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStore(directory: root)
        let agent = try await store.found(name: "Inbox Desk", role: "Mail Triage",
                                          description: "Triage mail.", root: root)
        XCTAssertEqual(agent.slug, "inbox-desk")
        let twin = try await store.found(name: "Inbox Desk", role: "x", description: "y", root: root)
        XCTAssertEqual(twin.slug, "inbox-desk-2")
        try await store.recordThread(slug: agent.slug, threadID: "t-1")
        try await store.recordThread(slug: agent.slug, threadID: "t-1")
        try await store.recordThread(slug: agent.slug, threadID: "t-2")
        try await store.setRoutine(slug: agent.slug,
                                   routine: Routine(id: "r", everyMinutes: 30, task: "sweep"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents.json").path))
        let reloaded = AgentStore(directory: root)
        let restoredAgent = await reloaded.agent(slug: "inbox-desk")
        let restored = try XCTUnwrap(restoredAgent)
        XCTAssertEqual(restored.threadIDs, ["t-1", "t-2"])
        XCTAssertEqual(restored.routines.count, 1)
        let roster = await reloaded.agents()
        XCTAssertEqual(roster.count, 2)
        try await reloaded.remove(slug: "inbox-desk-2")
        let removed = await reloaded.agent(slug: "inbox-desk-2")
        XCTAssertNil(removed)
    }
}

final class RoutineSchedulerTests: XCTestCase {
    private actor Counter {
        var fired: [String] = []
        func bump(_ entry: String) { fired.append(entry) }
    }

    func testTimerFiresRepeatsAndStopsOnSync() async throws {
        let counter = Counter()
        let scheduler = RoutineScheduler { slug, routine in
            await counter.bump("\(slug):\(routine.id)")
        }
        let routine = Routine(id: "r1", everyMinutes: 5, task: "sweep")
        await scheduler.schedule(key: "a\u{1F}r1", slug: "a", routine: routine,
                                 interval: 0.05, fireNow: false)
        for _ in 0..<60 where await counter.fired.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let firedCount = await counter.fired.count
        XCTAssertGreaterThanOrEqual(firedCount, 2)
        await scheduler.sync(agents: [])
        // Let the main-runloop invalidate land and any in-flight fire finish.
        try await Task.sleep(for: .milliseconds(300))
        let settled = await counter.fired.count
        try await Task.sleep(for: .milliseconds(250))
        let laterCount = await counter.fired.count
        XCTAssertEqual(laterCount, settled)
    }

    func testFirstRunImmediateAndDisabledFiltering() async throws {
        let counter = Counter()
        let scheduler = RoutineScheduler(firstRunImmediate: true) { slug, routine in
            await counter.bump("\(slug):\(routine.id)")
        }
        let agent = CompanionAgent(slug: "desk", name: "d", role: "r", description: "x",
                                   workspacePath: "/tmp", codexHomePath: "/tmp/h",
                                   routines: [
                                    Routine(id: "on", everyMinutes: 60, task: "t", enabled: true),
                                    Routine(id: "off", everyMinutes: 60, task: "t", enabled: false),
                                   ])
        await scheduler.sync(agents: [agent])
        for _ in 0..<20 where await counter.fired.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let fired = await counter.fired
        XCTAssertEqual(fired, ["desk:on"])
        await scheduler.stopAll()
    }
}

final class CodexRuntimeBridgeTests: XCTestCase {
    func testConfigTOMLWritesProviderAndMCPServersButNoSecrets() {
        let provider = CodexModelProvider(name: "jev-openai",
                                          baseURL: "https://api.openai.com/v1",
                                          envKey: "JEV_OPENAI_API_KEY", model: "gpt-6")
        let toml = CodexRuntimeBridge.configTOML(provider: provider, mcpServers: [
            CodexMCPServer(name: "computer-use", url: "http://127.0.0.1:7701/mcp",
                           bearerTokenEnvVar: "JEV_CU_TOKEN"),
            CodexMCPServer(name: "jev-use", url: "http://127.0.0.1:7702/mcp"),
        ])
        XCTAssertTrue(toml.contains("model_provider = \"jev-openai\""))
        XCTAssertTrue(toml.contains("approval_policy = \"never\""))
        XCTAssertTrue(toml.contains("sandbox_mode = \"workspace-write\""))
        XCTAssertTrue(toml.contains("env_key = \"JEV_OPENAI_API_KEY\""))
        XCTAssertTrue(toml.contains("wire_api = \"responses\""))
        XCTAssertTrue(toml.contains("[mcp_servers.\"computer-use\"]"))
        XCTAssertTrue(toml.contains("url = \"http://127.0.0.1:7701/mcp\""))
        XCTAssertTrue(toml.contains("bearer_token_env_var = \"JEV_CU_TOKEN\""))
        XCTAssertTrue(toml.contains("[mcp_servers.\"jev-use\"]"))
        // Secrets travel via process env only — never into the TOML.
        XCTAssertFalse(toml.contains("sk-"))
    }
}
