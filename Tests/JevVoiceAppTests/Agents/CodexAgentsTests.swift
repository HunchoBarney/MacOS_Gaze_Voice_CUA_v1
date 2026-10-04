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

    func testStrippingMarkersCutsDanglingOpenTagToEnd() {
        XCTAssertEqual(AgentMarkers.strippingMarkers("Reply text. <ROUTINE>{\"action\":\"cre"),
                       "Reply text.")
        XCTAssertEqual(AgentMarkers.strippingMarkers("Done. <COMPUTER_USE_REQUEST>cl"),
                       "Done.")
        // A complete pair still strips; a later dangling tag cuts the tail.
        let text = "a <ROUTINE>{\"action\":\"pause\",\"routine_id\":\"r\"}</ROUTINE> b <COMPUTER_USE_REQUEST>leak"
        XCTAssertEqual(AgentMarkers.strippingMarkers(text), "a  b")
    }

    /// Agent text is untrusted: nested or overlapping markers must strip
    /// safely — merging two per-tag scans used to index backwards into the
    /// string and trap (Range requires lowerBound <= upperBound).
    func testStrippingNestedAndOverlappingMarkersNeverTraps() {
        // The `</>` inside the JSON string is payload, not a close — the
        // tagged close wins and the routine still decodes.
        let nested = "<ROUTINE>{\"task\":\"<COMPUTER_USE_REQUEST>x</>\"}</ROUTINE>"
        XCTAssertEqual(AgentMarkers.strippingMarkers("ok \(nested) done"), "ok  done")
        XCTAssertEqual(AgentMarkers.routines(in: nested),
                       [AgentMarkers.RoutineMarker(action: "create",
                                                   task: "<COMPUTER_USE_REQUEST>x</>")])
        // Cross-tag nesting — the inner marker is consumed as content.
        XCTAssertEqual(AgentMarkers.strippingMarkers(
            "a <COMPUTER_USE_REQUEST>please <ROUTINE>{\"action\":\"pause\"}</ROUTINE> now</COMPUTER_USE_REQUEST> b"),
            "a  b")
        // Same-tag nesting — the inner open is swallowed by the outer span.
        XCTAssertEqual(AgentMarkers.strippingMarkers(
            "a <ROUTINE>x<ROUTINE>y</ROUTINE>z</ROUTINE> b"), "a z</ROUTINE> b")
        // Unclosed outer containing a complete inner — dangling cuts the tail.
        XCTAssertEqual(AgentMarkers.strippingMarkers(
            "pre <COMPUTER_USE_REQUEST>…<ROUTINE>{\"action\":\"pause\"}</ROUTINE>"), "pre")
        // Unclosed inner — the outer's close still binds.
        XCTAssertEqual(AgentMarkers.strippingMarkers(
            "a <ROUTINE>x<COMPUTER_USE_REQUEST>y</ROUTINE> b"), "a  b")
        // Adversarial ordering — stray close, complete marker, dangling tail.
        XCTAssertEqual(AgentMarkers.strippingMarkers(
            "</ROUTINE> stray <ROUTINE>ok</ROUTINE> tail <COMPUTER_USE_REQUEST>"),
            "</ROUTINE> stray  tail")
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

    func testEveryMinutesBelowTwoIsRefused() async throws {
        let counter = Counter()
        let scheduler = RoutineScheduler(firstRunImmediate: true) { slug, routine in
            await counter.bump("\(slug):\(routine.id)")
        }
        let agent = CompanionAgent(slug: "desk", name: "d", role: "r", description: "x",
                                   workspacePath: "/tmp", codexHomePath: "/tmp/h",
                                   routines: [
                                    Routine(id: "too-fast", everyMinutes: 1, task: "t"),
                                    Routine(id: "zero", everyMinutes: 0, task: "t"),
                                    Routine(id: "ok", everyMinutes: 2, task: "t"),
                                   ])
        await scheduler.sync(agents: [agent])
        for _ in 0..<20 where await counter.fired.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let fired = await counter.fired
        XCTAssertEqual(fired, ["desk:ok"])
        await scheduler.stopAll()
    }

    /// Two schedule() calls on one key must not leave an orphaned repeater —
    /// a ghost second timer would roughly double the fire rate.
    func testRescheduleSameKeyLeavesNoGhostTimer() async throws {
        let counter = Counter()
        let scheduler = RoutineScheduler { slug, routine in
            await counter.bump("\(slug):\(routine.id)")
        }
        let routine = Routine(id: "r1", everyMinutes: 5, task: "sweep")
        await scheduler.schedule(key: "a\u{1F}r1", slug: "a", routine: routine,
                                 interval: 0.1, fireNow: false)
        // Re-attach within the same runloop hop — the first timer's attach
        // lands after its entry was replaced and must be invalidated.
        await scheduler.schedule(key: "a\u{1F}r1", slug: "a", routine: routine,
                                 interval: 0.1, fireNow: false)
        try await Task.sleep(for: .milliseconds(500))
        let first = await counter.fired.count
        try await Task.sleep(for: .milliseconds(400))
        let delta = await counter.fired.count - first
        // One 0.1s timer over 0.4s ≈ 4 fires; a ghost doubles it to ~8.
        XCTAssertGreaterThanOrEqual(delta, 2)
        XCTAssertLessThanOrEqual(delta, 6)
        await scheduler.stopAll()
    }

    /// Releasing the scheduler must invalidate attached timers — a ghost
    /// repeater would keep calling `fire` after the actor is gone.
    func testDeinitStopsAttachedTimers() async throws {
        let counter = Counter()
        var scheduler: RoutineScheduler? = RoutineScheduler { slug, routine in
            await counter.bump("\(slug):\(routine.id)")
        }
        let routine = Routine(id: "r1", everyMinutes: 5, task: "sweep")
        await scheduler?.schedule(key: "a\u{1F}r1", slug: "a", routine: routine,
                                  interval: 0.05, fireNow: false)
        // Let the main-runloop attach land and a couple of fires through.
        try await Task.sleep(for: .milliseconds(200))
        scheduler = nil
        // Let deinit's invalidate bounce onto the main runloop.
        try await Task.sleep(for: .milliseconds(200))
        let settled = await counter.fired.count
        try await Task.sleep(for: .milliseconds(250))
        let later = await counter.fired.count
        XCTAssertEqual(later, settled)
    }

    /// A release racing the main-runloop hop must not leak either: the hop
    /// skips timer creation entirely when self is already gone.
    func testReleaseBeforeTimerAttachLeavesNoGhost() async throws {
        let counter = Counter()
        do {
            let scheduler = RoutineScheduler { slug, routine in
                await counter.bump("\(slug):\(routine.id)")
            }
            let routine = Routine(id: "r1", everyMinutes: 5, task: "sweep")
            await scheduler.schedule(key: "a\u{1F}r1", slug: "a", routine: routine,
                                     interval: 0.05, fireNow: false)
        }   // Released here — possibly before the main-queue hop ran.
        try await Task.sleep(for: .milliseconds(300))
        let settled = await counter.fired.count
        try await Task.sleep(for: .milliseconds(250))
        let later = await counter.fired.count
        XCTAssertEqual(later, settled)
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

    func testChildEnvironmentIsAllowlisted() {
        let env = CodexProtocolClient.filteredEnvironment(
            parent: ["PATH": "/usr/bin", "HOME": "/u", "LANG": "en_US.UTF-8",
                     "LC_ALL": "C", "TMPDIR": "/tmp/x", "USER": "u", "SHELL": "/bin/zsh",
                     "XDG_CONFIG_HOME": "/c", "XDG_DATA_HOME": "/d",
                     "__CF_USER_TEXT_ENCODING": "0x0",
                     "AWS_SECRET_ACCESS_KEY": "leak", "OPENAI_API_KEY": "sk-host",
                     "GITHUB_TOKEN": "ghp_host"],
            injected: ["JEV_OPENAI_API_KEY": "sk-child", "JEV_CU_TOKEN": "t",
                       "CODEX_HOME": "/home"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["XDG_CONFIG_HOME"], "/c")
        XCTAssertEqual(env["__CF_USER_TEXT_ENCODING"], "0x0")
        XCTAssertEqual(env["JEV_OPENAI_API_KEY"], "sk-child")
        XCTAssertEqual(env["CODEX_HOME"], "/home")
        for leaked in ["AWS_SECRET_ACCESS_KEY", "OPENAI_API_KEY", "GITHUB_TOKEN"] {
            XCTAssertNil(env[leaked], leaked)
        }
    }

    /// Proxy/custom-CA vars are config, not secrets — the child needs them to
    /// reach the model API in managed networks (corporate proxy, custom CA).
    func testChildEnvironmentPassesProxyAndCAConfig() {
        let env = CodexProtocolClient.filteredEnvironment(
            parent: ["HTTPS_PROXY": "https://proxy:8443", "HTTP_PROXY": "http://proxy:8080",
                     "ALL_PROXY": "socks5://proxy:1080", "NO_PROXY": "localhost,127.0.0.1",
                     "SSL_CERT_FILE": "/etc/ssl/ca.pem", "NODE_EXTRA_CA_CERTS": "/corp/ca.pem",
                     "AWS_SECRET_ACCESS_KEY": "leak"],
            injected: [:])
        XCTAssertEqual(env["HTTPS_PROXY"], "https://proxy:8443")
        XCTAssertEqual(env["HTTP_PROXY"], "http://proxy:8080")
        XCTAssertEqual(env["ALL_PROXY"], "socks5://proxy:1080")
        XCTAssertEqual(env["NO_PROXY"], "localhost,127.0.0.1")
        XCTAssertEqual(env["SSL_CERT_FILE"], "/etc/ssl/ca.pem")
        XCTAssertEqual(env["NODE_EXTRA_CA_CERTS"], "/corp/ca.pem")
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
    }

    /// Executable python fixture standing in for `codex app-server` — one
    /// READY line per spawn lets tests count processes, and a slow
    /// initialize widens the cold-start race window.
    private func bridgeFixture() throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-bridge-fixture-\(UUID().uuidString)")
        try #"""
#!/usr/bin/python3
import json,sys,time
print('READY', file=sys.stderr, flush=True)
for line in sys.stdin:
    req=json.loads(line)
    m=req.get('method'); id=req.get('id')
    if m=='initialize':
        time.sleep(0.3)
        print(json.dumps({'id':id,'result':{'codexHome':'/tmp/mock'}}),flush=True)
    elif m=='initialized':
        continue
    elif m=='thread/start':
        print(json.dumps({'id':id,'result':{'thread':{'id':'thr-'+str(id)}}}),flush=True)
    elif m=='thread/resume':
        print(json.dumps({'id':id,'result':{'thread':{'id':req['params']['threadId']}}}),flush=True)
    elif m=='turn/start':
        print(json.dumps({'id':id,'result':{'turn':{'id':'turn-'+str(id),'status':'inProgress'}}}),flush=True)
    else:
        print(json.dumps({'id':id,'result':{}}),flush=True)
"""#.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private actor LineCounter {
        var lines: [String] = []
        func bump(_ line: String) { lines.append(line) }
    }

    private func bridge(script: URL, lines: LineCounter) -> CodexRuntimeBridge {
        CodexRuntimeBridge(configuration: .init(
            codexBinary: script,
            provider: CodexModelProvider(name: "p", baseURL: "http://127.0.0.1:1",
                                         envKey: "JEV_TEST_KEY", model: "m"),
            environment: ["JEV_TEST_KEY": "tok"],
            onStderrLine: { line in Task { await lines.bump(line) } }))
    }

    private func agent(root: URL) throws -> CompanionAgent {
        let workspace = root.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return CompanionAgent(slug: "desk", name: "d", role: "r", description: "x",
                              workspacePath: workspace.path,
                              codexHomePath: workspace.appendingPathComponent("codex-home").path)
    }

    /// Two concurrent sends on a cold agent must share one spawn — a second
    /// app-server bound to the same CODEX_HOME must never start.
    func testConcurrentColdStartSharesSingleSpawn() async throws {
        let script = try bridgeFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: root)
        }
        let lines = LineCounter()
        let bridge = bridge(script: script, lines: lines)
        let agent = try agent(root: root)
        async let first = bridge.send(to: agent, message: "one")
        async let second = bridge.send(to: agent, message: "two")
        _ = try await (first, second)
        let spawned = await lines.lines.filter { $0.contains("READY") }.count
        XCTAssertEqual(spawned, 1)
        let thread = await bridge.activeThread(slug: "desk")
        XCTAssertNotNil(thread)
        await bridge.stopAll()
    }

    /// A stop() landing mid-spawn cancels the cold start — the late session
    /// must never register.
    func testStopDuringInFlightSpawnLeavesNoSession() async throws {
        let script = try bridgeFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: root)
        }
        let lines = LineCounter()
        let bridge = bridge(script: script, lines: lines)
        let agent = try agent(root: root)
        let send = Task { try await bridge.send(to: agent, message: "hi") }
        // Fixture sleeps 0.3s inside initialize — 100ms lands mid-spawn.
        try await Task.sleep(for: .milliseconds(100))
        await bridge.stop(slug: "desk")
        do { _ = try await send.value; XCTFail("stopped spawn completed") }
        catch { /* expected — spawn was cancelled */ }
        let client = await bridge.client(slug: "desk")
        XCTAssertNil(client)
        await bridge.stopAll()
    }
}
