import XCTest
import JevVoiceCore
@testable import JevVoice

/// Planner + per-app memory coverage: the advisory plan folds into the
/// DriveTask (previous_context + success_contains as seen by the judge),
/// every planner failure degrades to an unchanged task, the env kill
/// switch skips even an injected planner, and the memory store round-trips
/// with its caps and corrupt-file behavior intact. A scripted MCP driver
/// stands in for the Cua transport; a stub planner stands in for codex.
@MainActor
final class CuaPlannerTests: XCTestCase {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: T
        init(_ value: T) { raw = value }
        var value: T { lock.lock(); defer { lock.unlock() }; return raw }
        func update(_ body: (inout T) -> Void) { lock.lock(); body(&raw); lock.unlock() }
    }

    /// Injected instead of leaving `planner:` nil — nil falls through to the
    /// production `CuaPlanner.shared`, which would spawn a real codex mid-
    /// test. This keeps "no planner wanted" hermetic.
    private struct NullPlanner: CuaPlanning {
        func plan(goal: String, appName: String?, windowTitle: String?,
                  memoryContext: String?, previousContext: String?) async -> DrivePlan? { nil }
    }

    /// Scriptable planner stub — injected past the Config flag gate.
    private final class StubPlanner: CuaPlanning, @unchecked Sendable {
        private let calls = Box(0)
        var handler: @Sendable (String) async -> DrivePlan?
        init(handler: @escaping @Sendable (String) async -> DrivePlan?) { self.handler = handler }
        var callCount: Int { calls.value }
        func plan(goal: String, appName: String?, windowTitle: String?,
                  memoryContext: String?, previousContext: String?) async -> DrivePlan? {
            calls.update { $0 += 1 }
            return await handler(goal)
        }
    }

    private func driverScript(apps: String = "[]", windows: String = "[]",
                              elements: String = "[]") throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-tests-\(UUID().uuidString).py")
        try """
import json,sys
APPS=\(apps)
WINDOWS=\(windows)
ELEMENTS=\(elements)
for line in sys.stdin:
    r=json.loads(line)
    if 'id' not in r: continue
    if r['method']=='initialize':
        out={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
    elif r['method']=='tools/call':
        name=r['params']['name']; a=r['params'].get('arguments',{})
        if name=='list_apps': value={'apps':APPS}
        elif name=='launch_app': value={'pid':4242,'name':'FixAlpha','bundle_id':'test.fixalpha','windows':WINDOWS}
        elif name=='list_windows': value={'windows':WINDOWS}
        elif name=='bring_to_front': value={'activated':True,'verified':True,'exact_window_effect':{'verified':True}}
        elif name=='get_window_state': value={'window_id':a.get('window_id',7),'title':'Fixture','elements':ELEMENTS}
        elif name in ('start_session','end_session'): value={'active':name=='start_session'}
        elif name=='set_agent_cursor_enabled': value={'enabled':a.get('enabled',False)}
        else: value={'effect':'confirmed','status':'ok','summary':name+' dispatched'}
        out={'structuredContent':value}
    else:
        out={}
    print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':out}),flush=True)
""".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    private func makeRuntime(script: URL,
                             judge: @escaping CuaTaskAgent.Judge,
                             planner: (any CuaPlanning)? = nil,
                             appMemory: CuaAppMemory? = nil) -> CuaVoiceRuntime {
        let config = Config(defaults: UserDefaults(suiteName: "test.cua.planner.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(),
                            environment: [:])
        return CuaVoiceRuntime(config: config,
            makeConnection: { CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                            arguments: ["-u", script.path]) },
            judge: judge,
            fastLaneResolver: { _, _, _, _ in nil },
            screenLocked: { false },
            planner: planner ?? NullPlanner(),
            appMemory: appMemory ?? CuaAppMemory(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("app-memory-\(UUID().uuidString).json")))
    }

    private nonisolated func pick(_ choice: String) -> Answer {
        .choice(choice: choice, confidence: 0.95, probabilities: [choice: 0.95])
    }
    private nonisolated func answers(next: String) -> [String: Answer] {
        ["next": pick(next), "fill": pick("unavailable"),
         "doneEvidence": pick("proven"), "blockedReason": pick("other")]
    }
    private nonisolated func nextLaneID(_ questions: [String: Question], containing needle: String) -> String? {
        guard case let .choice(_, criteria)? = questions["next"] else { return nil }
        return criteria.first { ($0.value ?? "").localizedCaseInsensitiveContains(needle) }?.key
    }

    private func until(_ predicate: @MainActor () -> Bool,
                       _ timeout: TimeInterval = 15,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for the voice pipeline", file: file, line: line)
    }

    private func memoryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("app-memory-\(UUID().uuidString).json")
    }

    // MARK: - CuaAppMemory

    /// note → context round-trips, and a fresh instance on the same file
    /// reads what the first persisted.
    func testAppMemoryRoundTripAndPersistence() async {
        let file = memoryFile()
        let memory = CuaAppMemory(fileURL: file)
        await memory.note(bundleID: "test.alpha", appName: "Alpha",
                          record: .init(axSparse: true, prefersVisual: true,
                                        laneKinds: ["pixel", "click"],
                                        note: "User prefers the toolbar."))
        let context = await memory.context(forApp: "test.alpha")
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("accessibility tree is sparse") ?? false)
        XCTAssertTrue(context?.contains("prefers visual/pixel lanes") ?? false)
        XCTAssertTrue(context?.contains("lanes that worked: pixel, click") ?? false)
        XCTAssertTrue(context?.contains("User prefers the toolbar.") ?? false)
        // Name-spelled lookups hit the record via its stored app name.
        let byName = await memory.context(forApp: "Alpha")
        XCTAssertNotNil(byName)
        // A fresh instance on the same file sees the persisted record.
        let reloaded = CuaAppMemory(fileURL: file)
        let persisted = await reloaded.context(forApp: "test.alpha")
        XCTAssertNotNil(persisted)
    }

    /// Notes cap at 8/app and the app table prunes to 40 least-recently-used.
    func testAppMemoryCaps() async {
        let file = memoryFile()
        let memory = CuaAppMemory(fileURL: file)
        for index in 0..<10 {
            await memory.note(bundleID: "test.alpha", appName: "Alpha",
                              record: .init(note: "note \(index)"))
        }
        let context = await memory.context(forApp: "test.alpha") ?? ""
        XCTAssertFalse(context.contains("note 0"), "Oldest notes drop first: \(context)")
        XCTAssertFalse(context.contains("note 1"))
        XCTAssertTrue(context.contains("note 9"))
        // Each entry needs a payload so context(forApp:) can see it.
        for index in 0..<45 {
            await memory.note(bundleID: "test.app\(index)", appName: nil,
                              record: .init(note: "app \(index)"))
        }
        // 46 apps total → the 6 oldest evict: alpha plus test.app0-4.
        let evicted = await memory.context(forApp: "test.app0")
        XCTAssertNil(evicted, "The oldest app record is evicted past the LRU cap")
        let evictedAlpha = await memory.context(forApp: "test.alpha")
        XCTAssertNil(evictedAlpha)
        let keptMid = await memory.context(forApp: "test.app10")
        let keptLast = await memory.context(forApp: "test.app44")
        XCTAssertNotNil(keptMid)
        XCTAssertNotNil(keptLast)
        // A fresh note on an evicted app recreates it and bumps recency.
        await memory.note(bundleID: "test.app0", appName: nil,
                          record: .init(note: "app 0 again"))
        let recreated = await memory.context(forApp: "test.app0")
        let evictedNext = await memory.context(forApp: "test.app5")
        XCTAssertNotNil(recreated)
        XCTAssertNil(evictedNext, "The recreated app evicts the next-oldest entry")
    }

    /// An empty patch still stamps the app so an LRU prune knows it ran —
    /// but context stays nil while nothing observable was recorded.
    func testAppMemoryEmptyUpdateProducesNoContext() async {
        let memory = CuaAppMemory(fileURL: memoryFile())
        await memory.note(bundleID: "test.alpha", appName: "Alpha", record: .init())
        let empty = await memory.context(forApp: "test.alpha")
        XCTAssertNil(empty)
    }

    /// A corrupt file reads as an empty store and the next write replaces it.
    func testAppMemoryCorruptFileReadsEmpty() async {
        let file = memoryFile()
        try? "not json at all {{{".write(to: file, atomically: true, encoding: .utf8)
        let memory = CuaAppMemory(fileURL: file)
        let missing = await memory.context(forApp: "test.alpha")
        XCTAssertNil(missing)
        await memory.note(bundleID: "test.alpha", appName: nil,
                          record: .init(prefersVisual: true))
        let written = await memory.context(forApp: "test.alpha")
        XCTAssertNotNil(written)
    }

    // MARK: - Plan parsing

    /// Strict extraction: prose-only and malformed bodies parse to nil; a
    /// JSON object embedded in prose still yields a plan; a plan with no
    /// steps and no success strings is refused as useless.
    func testPlannerParsesDefensively() {
        XCTAssertNil(CuaPlanner.parse(""))
        XCTAssertNil(CuaPlanner.parse("no json here"))
        XCTAssertNil(CuaPlanner.parse("{broken"))
        XCTAssertNil(CuaPlanner.parse(#"{"steps":[],"success_contains":[]}"#))
        let embedded = CuaPlanner.parse("""
            Sure! Here is the plan:
            {"steps":["open the app","press Save"],"success_contains":["Saved"],"prefer_visual":true}
            hope that helps
            """)
        XCTAssertEqual(embedded?.steps, ["open the app", "press Save"])
        XCTAssertEqual(embedded?.successContains, ["Saved"])
        XCTAssertEqual(embedded?.hints.preferVisual, true)
    }

    /// No binary → nil, fast. The planner can never throw.
    func testPlannerNilWithoutBinary() async {
        let planner = CuaPlanner(codexBinary: URL(fileURLWithPath: "/definitely/not/codex"),
                                 codexHome: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("codex-home-\(UUID().uuidString)"))
        let plan = await planner.plan(goal: "press save", appName: "FixAlpha",
                                      windowTitle: nil, memoryContext: nil,
                                      previousContext: nil)
        XCTAssertNil(plan)
    }

    // MARK: - Runtime integration

    /// A stubbed plan folds into the DriveTask the judge sees: the step
    /// sketch and memory line ride previous_context, and the plan's success
    /// strings merge into success_contains.
    func testDriveTaskCarriesPlanAndMemory() async throws {
        let memory = CuaAppMemory(fileURL: memoryFile())
        await memory.note(bundleID: "test.fixalpha", appName: "FixAlpha",
                          record: .init(axSparse: true, note: "Toolbar Save is flaky."))
        let plan = DrivePlan(steps: ["focus the document", "press Save"],
                             successContains: ["Saved ✓"],
                             hints: .init(preferVisual: true, notes: "Watch the sheet."))
        let stub = StubPlanner { _ in plan }
        let contexts = Box<[String]>([])
        let claims = Box<[String]>([])
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True},{'element_index':1,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let runtime = makeRuntime(script: script, judge: { state, _ in
            contexts.update { $0.append(state["previous_context"]?.string ?? "") }
            claims.update { $0 = state["success_contains"]?.array?.compactMap(\.string) ?? [] }
            return self.answers(next: "done")
        }, planner: stub, appMemory: memory)
        _ = await runtime.beginVoiceTask("press Save in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertEqual(stub.callCount, 1)
        let context = try XCTUnwrap(contexts.value.last)
        XCTAssertTrue(context.hasPrefix("Plan: focus the document; press Save"), context)
        XCTAssertTrue(context.contains("Memory for FixAlpha"), context)
        XCTAssertTrue(context.contains("accessibility tree is sparse"), context)
        XCTAssertTrue(context.contains("Toolbar Save is flaky."), context)
        XCTAssertTrue(context.contains("visual or pixel lanes"), context)
        XCTAssertTrue(context.contains("Watch the sheet."), context)
        XCTAssertTrue(claims.value.contains("Saved ✓"), "\(claims.value)")
        // The honesty invariant: a plan-supplied success string that never
        // appears in the observed corpus must not let the done claim stand —
        // the loop blocks rather than claiming success.
        XCTAssertEqual(work.status, "Failed", work.message)
        XCTAssertTrue(work.message.contains("could not be proven"), work.message)
        await runtime.shutdown()
    }

    /// A nil plan leaves the task exactly as before — memory context still
    /// feeds previous_context but no Plan prefix or success strings appear.
    func testNilPlanLeavesTaskUnchanged() async throws {
        let memory = CuaAppMemory(fileURL: memoryFile())
        await memory.note(bundleID: "test.fixalpha", appName: "FixAlpha",
                          record: .init(note: "Toolbar Save is flaky."))
        let stub = StubPlanner { _ in nil }
        let contexts = Box<[String]>([])
        let claims = Box<[String]>([])
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True},{'element_index':1,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let runtime = makeRuntime(script: script, judge: { state, _ in
            contexts.update { $0.append(state["previous_context"]?.string ?? "") }
            claims.update { $0 = state["success_contains"]?.array?.compactMap(\.string) ?? [] }
            return self.answers(next: "done")
        }, planner: stub, appMemory: memory)
        _ = await runtime.beginVoiceTask("press Save in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        let context = try XCTUnwrap(contexts.value.last)
        XCTAssertFalse(context.contains("Plan:"), context)
        XCTAssertTrue(context.contains("Toolbar Save is flaky."), context)
        XCTAssertTrue(claims.value.isEmpty, "\(claims.value)")
        await runtime.shutdown()
    }

    /// A hung planner degrades inside its budget — the task still settles
    /// and previous_context carries no plan.
    func testPlannerTimeoutDegradesFast() async throws {
        let stub = StubPlanner { _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { return nil }
            return DrivePlan(steps: ["too late"])
        }
        let contexts = Box<[String]>([])
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True},{'element_index':1,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let runtime = makeRuntime(script: script, judge: { state, _ in
            contexts.update { $0.append(state["previous_context"]?.string ?? "") }
            return self.answers(next: "done")
        }, planner: stub)
        let started = ProcessInfo.processInfo.systemUptime
        _ = await runtime.beginVoiceTask("press Save in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 12,
                          "The 4s planner budget must bound the wait: \(elapsed)s")
        XCTAssertLessThan(work.timings["Planner"] ?? 0, 8000,
                          "The Planner timing bills the bounded wait")
        XCTAssertFalse(contexts.value.last?.contains("Plan:") ?? true,
                       contexts.value.last ?? "")
        XCTAssertEqual(work.status, "Completed", work.message)
        await runtime.shutdown()
    }

    /// JARVIS_PLANNER=0 skips the planner unconditionally — even an
    /// injected one — while memory still feeds previous_context.
    func testEnvKillSwitchSkipsPlanner() async throws {
        setenv("JARVIS_PLANNER", "0", 1)
        defer { unsetenv("JARVIS_PLANNER") }
        let memory = CuaAppMemory(fileURL: memoryFile())
        await memory.note(bundleID: "test.fixalpha", appName: "FixAlpha",
                          record: .init(note: "Toolbar Save is flaky."))
        let stub = StubPlanner { _ in DrivePlan(steps: ["should never run"]) }
        let contexts = Box<[String]>([])
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True},{'element_index':1,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let runtime = makeRuntime(script: script, judge: { state, _ in
            contexts.update { $0.append(state["previous_context"]?.string ?? "") }
            return self.answers(next: "done")
        }, planner: stub, appMemory: memory)
        _ = await runtime.beginVoiceTask("press Save in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertEqual(stub.callCount, 0, "The env kill switch must skip even an injected planner")
        XCTAssertTrue(contexts.value.last?.contains("Toolbar Save is flaky.") ?? false,
                      "Memory still feeds previous_context when the planner is off")
        await runtime.shutdown()
    }

    /// A settled drive feeds the ledger back into memory: a landed element
    /// click is recorded as a good lane for the app.
    func testSettledDriveWritesLaneMemory() async throws {
        let file = memoryFile()
        let memory = CuaAppMemory(fileURL: file)
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = true
        defer { CuaStandingGrants.computerUseInput = prior }
        let clicked = Box(false)
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True},{'element_index':1,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let runtime = makeRuntime(script: script, judge: { _, questions in
            if !clicked.value, let id = self.nextLaneID(questions, containing: "Save") {
                clicked.update { $0 = true }
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        }, appMemory: memory)
        _ = await runtime.beginVoiceTask("press Save in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertEqual(work.status, "Completed", work.message)
        // The memory write is fire-and-forget — poll for it.
        var context: String?
        for _ in 0..<200 {
            context = await memory.context(forApp: "test.fixalpha")
            if context != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(context?.contains("lanes that worked: click") ?? false,
                      context ?? "no memory recorded")
        await runtime.shutdown()
    }

    /// A drive that hands back noInteractiveElements marks the app
    /// AX-sparse in memory.
    func testSparseDriveWritesAxSparse() async throws {
        let file = memoryFile()
        let memory = CuaAppMemory(fileURL: file)
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[]")
        let runtime = makeRuntime(script: script, judge: { _, _ in self.answers(next: "done") },
                                  appMemory: memory)
        _ = await runtime.beginVoiceTask("insert a note in FixAlpha", app: "FixAlpha",
                                         literalText: "hello there")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        var context: String?
        for _ in 0..<200 {
            context = await memory.context(forApp: "test.fixalpha")
            if context != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(context?.contains("accessibility tree is sparse") ?? false,
                      context ?? "no memory recorded")
        await runtime.shutdown()
    }

    /// A cancelled cold plan must not strand the spawn — the session adopts
    /// its own result so the next call lands warm. Scripted app-server with
    /// a slow initialize stands in for codex.
    func testCancelledColdPlanStillWarmsSession() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-warm-\(UUID().uuidString)", isDirectory: true)
        let userHome = dir.appendingPathComponent("user-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        try "{}".write(to: userHome.appendingPathComponent("auth.json"),
                       atomically: true, encoding: .utf8)
        let server = dir.appendingPathComponent("fake-codex.py")
        try """
import json,sys,time
time.sleep(1.0)
for line in sys.stdin:
    r=json.loads(line); m=r.get('method')
    if 'id' not in r: continue
    if m=='initialize': res={'codexHome':'/tmp/x'}
    elif m=='thread/start': res={'thread':{'id':'t1'}}
    elif m=='turn/start':
        print(json.dumps({'id':r['id'],'result':{'turn':{'id':'u1'}}}),flush=True)
        plan='{"steps":["click it"],"success_contains":["done"]}'
        print(json.dumps({'method':'item/completed','params':{'threadId':'t1','turnId':'u1','item':{'type':'agentMessage','text':plan}}}),flush=True)
        print(json.dumps({'method':'turn/completed','params':{'threadId':'t1','turn':{'id':'u1','status':'completed'}}}),flush=True)
        continue
    else: res={}
    print(json.dumps({'id':r['id'],'result':res}),flush=True)
""".write(to: server, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // CuaPlanner spawns `binary app-server` — wrap python + script.
        // Binary arg support: pass the script via a shim executable.
        let shim = dir.appendingPathComponent("fake-codex.sh")
        try "#!/bin/sh\nexec /usr/bin/python3 \(server.path) app-server\n".write(
            to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: shim.path)
        let warmPlanner = CuaPlanner(codexBinary: shim,
                                     codexHome: dir.appendingPathComponent("spawn2", isDirectory: true),
                                     userHome: userHome, turnTimeout: 20)
        // Cold call cancelled mid-spawn → nil, but the session must adopt.
        let cold = Task { await warmPlanner.plan(goal: "g", appName: "A", windowTitle: nil,
                                                 memoryContext: nil, previousContext: nil) }
        try await Task.sleep(for: .milliseconds(250))
        cold.cancel()
        _ = await cold.value
        // Give the orphaned spawn a beat past its 1s delay to finish adopting.
        try await Task.sleep(for: .milliseconds(1200))
        let warm = await warmPlanner.plan(goal: "g2", appName: "A", windowTitle: nil,
                                          memoryContext: nil, previousContext: nil)
        let plan = try XCTUnwrap(warm, "cancelled cold spawn did not warm the session")
        XCTAssertEqual(plan.steps, ["click it"])
        await warmPlanner.close()
    }

    /// Live round-trip against the real codex binary + the user's ChatGPT
    /// login — skipped unless JARVIS_LIVE_PLANNER=1. Cold call pays the
    /// spawn; the second must reuse the warm session and return a plan.
    func testLivePlannerRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_LIVE_PLANNER"] == "1" else {
            throw XCTSkip("Opt-in live planner turn")
        }
        let binary = env["JEV_CODEX_BINARY"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath
                + "/build/vendor/CodexRuntime/bin/codex")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("No codex binary at \(binary.path)")
        }
        guard FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/auth.json").path) else {
            throw XCTSkip("No ChatGPT login at ~/.codex/auth.json")
        }
        let planner = CuaPlanner(codexBinary: binary,
                               codexHome: FileManager.default.temporaryDirectory
                                .appendingPathComponent("planner-home-\(UUID().uuidString)",
                                                        isDirectory: true),
                               turnTimeout: 45)
        let coldStart = ContinuousClock.now
        let cold = await planner.plan(goal: "open the Downloads folder in Finder",
                                      appName: "Finder", windowTitle: nil,
                                      memoryContext: nil, previousContext: nil)
        let coldMs = ContinuousClock.now - coldStart
        let plan = try XCTUnwrap(cold, "planner returned nil — auth or spawn failed")
        XCTAssertFalse(plan.steps.isEmpty, "plan arrived without steps")
        let warmStart = ContinuousClock.now
        let warm = await planner.plan(goal: "open the Recents window in Finder",
                                      appName: "Finder", windowTitle: nil,
                                      memoryContext: nil, previousContext: nil)
        let warmMs = ContinuousClock.now - warmStart
        XCTAssertNotNil(warm, "warm turn failed after cold succeeded")
        print("[live-planner] cold=\(coldMs) warm=\(warmMs) steps=\(plan.steps)")
        await planner.close()
    }
}

private final class MemoryKeyStore: APIKeyStore {
    private var value: String?
    func read() throws -> String? { value }
    func save(_ newValue: String) throws { value = newValue }
    func delete() throws { value = nil }
}
