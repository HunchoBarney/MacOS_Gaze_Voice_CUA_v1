import XCTest
import JevVoiceCore
@testable import JevVoice

/// Regression tests for the runtime hunt wave: the session bootstrap's
/// single-flight slot must outlive a cancelled waiter (otherwise the next
/// caller mints a second transport + daemon session under the same label
/// and leaks the loser), the ~4s planner budget must bound even a
/// cancellation-deaf plan() so a wedged app-server cannot hold the app
/// lease forever, and a parked task_question reads "Waiting" — never
/// "Failed" — without letting the stale park refuse a repeated
/// instruction after the ask resolves. A scripted MCP driver stands in
/// for the Cua transport; stub planners stand in for codex.
@MainActor
final class CuaRuntimeHuntTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return raw }
        @discardableResult func bump() -> Int { lock.lock(); raw += 1; defer { lock.unlock() }; return raw }
    }

    /// Per-request pick tracking — a judge that keeps picking the same lane
    /// after its dispatch re-parks the consent it just resolved, so scripted
    /// judges dispatch once per request then report done.
    private final class PickOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: Set<String> = []
        /// True the first time a request string is seen.
        func isFirst(_ request: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return raw.insert(request).inserted
        }
    }

    /// Holds a continuation forever — the wedged-planner stub's suspended
    /// task stays suspended (that's the fixture) without tripping the
    /// continuation-misuse diagnostic a dropped continuation fires.
    private final class HeldContinuations: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [CheckedContinuation<DrivePlan?, Never>] = []
        func hold(_ c: CheckedContinuation<DrivePlan?, Never>) {
            lock.lock(); held.append(c); lock.unlock()
        }
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return names }
        func count(_ name: String) -> Int { values.filter { $0 == name }.count }
    }

    /// Injected instead of leaving `planner:` nil — nil falls through to the
    /// production `CuaLitePlanner.shared`, which would make a real network
    /// call mid-test. This keeps "no planner wanted" hermetic.
    private struct NullPlanner: CuaPlanning {
        func plan(goal: String, appName: String?, windowTitle: String?,
                  previousContext: String?) async -> DrivePlan? { nil }
    }

    /// Scriptable planner stub — injected past the Config flag gate.
    private final class StubPlanner: CuaPlanning, @unchecked Sendable {
        private let calls = Counter()
        var handler: @Sendable (String) async -> DrivePlan?
        init(handler: @escaping @Sendable (String) async -> DrivePlan?) { self.handler = handler }
        var callCount: Int { calls.value }
        func plan(goal: String, appName: String?, windowTitle: String?,
                  previousContext: String?) async -> DrivePlan? {
            calls.bump()
            return await handler(goal)
        }
    }

    /// `initDelay` stalls the MCP initialize handshake — enough window for a
    /// caller's cancel and a second caller's join to land mid-bootstrap.
    private func driverScript(apps: String = "[]", windows: String = "[]",
                              elements: String = "[]",
                              initDelay: Double = 0) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-hunt-\(UUID().uuidString).py")
        try """
import json,sys,time
APPS=\(apps)
WINDOWS=\(windows)
ELEMENTS=\(elements)
for line in sys.stdin:
    r=json.loads(line)
    if 'id' not in r: continue
    if r['method']=='initialize':
        time.sleep(\(initDelay))
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

    /// `mints` counts connection factory calls — the single-flight seam the
    /// session bootstrap races share.
    private func makeRuntime(script: URL,
                             judge: @escaping CuaTaskAgent.Judge,
                             calls: CallLog? = nil,
                             mints: Counter? = nil,
                             planner: (any CuaPlanning)? = nil,
                             plannerEnabled: Bool = false) -> CuaVoiceRuntime {
        let config = Config(defaults: UserDefaults(suiteName: "test.cua.hunt.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(),
                            environment: ["JARVIS_PLANNER": plannerEnabled ? "1" : "0"])
        return CuaVoiceRuntime(config: config,
            makeConnection: {
                mints?.bump()
                return CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                     arguments: ["-u", script.path],
                                     onToolCall: { name, _ in calls?.record(name) })
            },
            judge: judge,
            fastLaneResolver: { _, _, _, _ in nil },
            screenLocked: { false },
            planner: planner ?? NullPlanner())
    }

    private nonisolated func pick(_ choice: String) -> Answer {
        .choice(choice: choice, confidence: 0.95, probabilities: [choice: 0.95])
    }
    private nonisolated func answers(next: String, fill: String = "unavailable",
                                     evidence: String = "proven", blocked: String = "other") -> [String: Answer] {
        ["next": pick(next), "fill": pick(fill),
         "doneEvidence": pick(evidence), "blockedReason": pick(blocked)]
    }
    /// Two consecutive sub-0.5 picks are what hand back a needsChoice — the
    /// probabilities carry the offered lane ids the parked ask re-lists.
    private nonisolated func hesitant(_ questions: [String: Question]) -> [String: Answer]? {
        guard case let .choice(_, criteria)? = questions["next"] else { return nil }
        let ids = criteria.keys.filter { $0 != "done" && $0 != "stuck" }.sorted()
        guard let first = ids.first else { return nil }
        let probabilities = Dictionary(uniqueKeysWithValues:
            ids.prefix(3).enumerated().map { ($0.element, 0.4 - Double($0.offset) * 0.1) })
        return ["next": .choice(choice: first, confidence: 0.3, probabilities: probabilities),
                "fill": pick("unavailable"), "doneEvidence": pick("unproven"),
                "blockedReason": pick("other")]
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

    private func decoded(_ json: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> VoiceToolResult {
        try XCTUnwrap(VoiceToolResult(jsonString: json),
                      "Expected a VoiceToolResult payload: \(json)", file: file, line: line)
    }

    // MARK: - Session bootstrap single-flight

    /// The bootstrap's in-flight marker lives inside the bootstrap task —
    /// a cancelled waiter must not clear it early and let a second caller
    /// mint a parallel transport + daemon session under the same label.
    func testCancelledWaiterAndJoinerShareOneBootstrap() async throws {
        let mints = Counter()
        let calls = CallLog()
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            initDelay: 1.0)
        let runtime = makeRuntime(script: script, judge: { _, _ in self.answers(next: "done") },
                                  calls: calls, mints: mints)
        _ = await runtime.beginVoiceTask("press Save in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        // The ~1s scripted initialize leaves a window where the bootstrap
        // is genuinely in flight — cancel the waiter inside it.
        try await until { mints.value >= 1 }
        runtime.cancel(work.id)
        // A second caller mid-bootstrap must join, never re-mint.
        runtime.wakeDriverSession()
        try await until { calls.count("start_session") == 1 }
        try await until { calls.count("check_permissions") >= 1 }
        XCTAssertEqual(mints.value, 1,
                       "A cancelled waiter must not leak a second transport: \(mints.value)")
        XCTAssertEqual(calls.count("start_session"), 1,
                       "One daemon-side session per runtime: \(calls.values)")
        await work.worker?.value
        await runtime.shutdown()
        XCTAssertEqual(calls.count("end_session"), 1, calls.values.joined(separator: " | "))
    }

    // MARK: - Planner budget

    /// A plan() that ignores cancellation and never returns — a wedged
    /// app-server — must still lose the budget race: planWithBudget answers
    /// nil in ~4s and the drive completes instead of hanging on the lease.
    func testHungPlannerYieldsInsideBudget() async throws {
        let held = HeldContinuations()
        let wedged = StubPlanner { _ in
            // Cancellation-deaf — a task group could never out-wait this;
            // the budget race abandons it instead of joining it. The
            // continuation is retained so the suspended task reads as a
            // wedge, not a leak warning.
            await withCheckedContinuation { (c: CheckedContinuation<DrivePlan?, Never>) in
                held.hold(c)
            }
        }
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True}]")
        // A first-turn "done" with no dispatch is refused outright now —
        // the judge clicks Save once, then reports done on the next pass.
        let once = PickOnce()
        let runtime = makeRuntime(script: script,
                                  judge: { state, questions in
            if once.isFirst(state["request"]?.string ?? ""),
               let id = self.nextLaneID(questions, containing: "Save") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        },
                                  planner: wedged, plannerEnabled: true)
        let started = ProcessInfo.processInfo.systemUptime
        // The goal is deliberately multi-clause — single-step requests
        // correctly skip the planner now.
        _ = await runtime.beginVoiceTask("press Save in FixAlpha and scroll down", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until({ !work.active }, 12)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(wedged.callCount, 1)
        XCTAssertLessThan(elapsed, 10,
                          "The ~4s planner budget must bound a cancellation-deaf plan: \(elapsed)s")
        XCTAssertEqual(work.status, "Completed", work.message)
        await runtime.shutdown()
    }

    // MARK: - Parked question lifecycle

    /// A parked task_question owns the row: no outcome, a "Waiting" label,
    /// and still dedupes a verbatim repeat. Once the user answers, the ask
    /// resolves, the stale park flag clears, and the identical instruction
    /// is a fresh task — never refused "already running" forever.
    func testParkedQuestionWaitsThenReleasesTheInstruction() async throws {
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Draft','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'body0','role':'AXTextArea','label':'Body','enabled':True}]")
        let runtime = makeRuntime(script: script, judge: { state, questions in
            let request = state["request"]?.string ?? ""
            if !request.contains("user answered"),
               let id = self.nextLaneID(questions, containing: "Type the supplied text") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("insert the reply in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertTrue(work.questionParked)
        XCTAssertNil(work.outcome, "A live ask records no outcome — it has not failed")
        XCTAssertEqual(work.status, "Waiting", "Parked reads Waiting, never Failed")
        XCTAssertEqual(runtime.dialogue.awaitingAnswerEntries.count, 1)
        // Retry of a question-parked intent refuses — revising it would
        // silently withdraw the live ask and route the spoken answer
        // nowhere.
        let count = runtime.tasks.count
        let retried = try decoded(await runtime.retryWork(work.id))
        XCTAssertEqual(retried.status, "refused", retried.say)
        XCTAssertEqual(runtime.tasks.count, count, "A refused retry spawns no noise row")
        XCTAssertEqual(runtime.dialogue.awaitingAnswerEntries.count, 1,
                       "A refused retry must not withdraw the live ask")
        // While parked, a verbatim repeat still dedupes as live work.
        let dupe = try decoded(await runtime.beginVoiceTask("insert the reply in FixAlpha", app: "FixAlpha"))
        XCTAssertEqual(dupe.status, "refused", dupe.say)
        // The answer resumes the intent on a fresh work and clears the flag.
        let replyRaw = await runtime.respondToTask("the taxis draft")
        let reply = try XCTUnwrap(replyRaw)
        XCTAssertEqual(try decoded(reply).status, "resumed", reply)
        XCTAssertFalse(work.questionParked, "A resolved ask clears the park flag")
        try await until { runtime.tasks.last?.active == false }
        // The identical instruction is a fresh task now — not "already running".
        let again = try decoded(await runtime.beginVoiceTask("insert the reply in FixAlpha", app: "FixAlpha"))
        XCTAssertEqual(again.status, "started", again.say)
        try await until { runtime.tasks.last?.active == false }
        await runtime.shutdown()
    }

    /// Denying a parked ask withdraws it: the cancelled work releases the
    /// instruction so a verbatim repeat is a fresh task, not a refusal.
    func testDeniedParkedQuestionReleasesTheInstruction() async throws {
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Draft','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'body0','role':'AXTextArea','label':'Body','enabled':True}]")
        let runtime = makeRuntime(script: script, judge: { state, questions in
            let request = state["request"]?.string ?? ""
            if !request.contains("user answered"),
               let id = self.nextLaneID(questions, containing: "Type the supplied text") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("insert the reply in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertTrue(work.questionParked)
        let replyRaw = await runtime.respondToTask("never mind")
        let reply = try XCTUnwrap(replyRaw)
        XCTAssertEqual(try decoded(reply).status, "cancelled", reply)
        XCTAssertFalse(work.questionParked, "A withdrawn ask clears the park flag")
        XCTAssertEqual(work.status, "Cancelled", work.message)
        XCTAssertTrue(runtime.dialogue.awaitingAnswerEntries.isEmpty)
        let again = try decoded(await runtime.beginVoiceTask("insert the reply in FixAlpha", app: "FixAlpha"))
        XCTAssertEqual(again.status, "started", again.say)
        try await until { runtime.tasks.last?.active == false }
        await runtime.shutdown()
    }

    /// An executing attempt is not retryable either — a consent-parked work
    /// sits mid-attempt, so retryWork refuses before spawning a work that
    /// would settle blocked instantly.
    func testRetryRefusesAnExecutingTarget() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let script = try driverScript(
            apps: "[{'name':'FixAlpha','bundle_id':'test.fixalpha','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'FixAlpha','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let once = PickOnce()
        let runtime = makeRuntime(script: script, judge: { state, questions in
            let request = state["request"]?.string ?? ""
            if once.isFirst(request), let id = self.nextLaneID(questions, containing: "Delete") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("press the Delete button in FixAlpha", app: "FixAlpha")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { work.approval != nil }
        let count = runtime.tasks.count
        let reply = try decoded(await runtime.retryWork(work.id))
        XCTAssertEqual(reply.status, "refused", reply.say)
        XCTAssertEqual(runtime.tasks.count, count, "A refused retry spawns no noise row")
        XCTAssertTrue(work.active, "The parked consent is untouched")
        let verdictRaw = await runtime.respondToTask("yes")
        let verdict = try XCTUnwrap(verdictRaw)
        XCTAssertEqual(try decoded(verdict).status, "resumed", verdict)
        try await until { !work.active }
        XCTAssertEqual(work.status, "Completed", work.message)
        await runtime.shutdown()
    }

}

private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}
