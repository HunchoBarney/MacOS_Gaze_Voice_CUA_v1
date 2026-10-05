import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaVoiceControllerTests: XCTestCase {
    /// Simulated speech capture — the physical microphone is not part of this
    /// harness; events drive the controller's receive() directly.
    private final class Capture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var id: UUID?
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
            id = session; return "Fixture microphone"
        }
        func finish() {}
        func cancel() {}
        func emit(_ event: SpeechEvent) { if let id { onEvent?(id, event) } }
    }

    /// A cancellable hold inside the scripted judge — a work stays active until
    /// released, proving the spawn ack returns before execution settles.
    private final class JudgeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false
        func hold() async {
            lock.lock()
            entered = true
            if released { lock.unlock(); return }
            lock.unlock()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.lock.lock()
                    if self.released { continuation.resume() }
                    else { self.waiting = continuation }
                    self.lock.unlock()
                }
            } onCancel: { self.open() }
        }
        func open() {
            lock.lock()
            released = true
            let pending = waiting
            waiting = nil
            lock.unlock()
            pending?.resume()
        }
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return names }
        func count(_ name: String) -> Int { values.filter { $0 == name }.count }
    }

    /// A scripted MCP driver: enough of the tools/call surface for the runtime's
    /// session bootstrap, app resolution, drive-loop observations and the
    /// dispatch lanes these tests exercise. Unknown tools acknowledge honestly.
    private func driverScript(apps: String = "[]", treeApps: String = "[]",
                              windows: String = "[]", elements: String = "[]",
                              launchPID: Int = 4242) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-fixture-\(UUID().uuidString).py")
        try """
import json,sys
APPS=\(apps)
TREE=\(treeApps)
WINDOWS=\(windows)
ELEMENTS=\(elements)
PID=\(launchPID)
for line in sys.stdin:
    r=json.loads(line)
    if 'id' not in r: continue
    if r['method']=='initialize':
        out={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
    elif r['method']=='tools/call':
        name=r['params']['name']; a=r['params'].get('arguments',{})
        if name=='list_apps': value={'apps':APPS}
        elif name=='get_accessibility_tree': value={'apps':TREE}
        elif name=='launch_app': value={'pid':PID,'name':'Fixture','bundle_id':'test.fixture','windows':WINDOWS}
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

    private func makeRuntime(config: Config, script: URL,
                             judge: @escaping CuaTaskAgent.Judge,
                             calls: CallLog? = nil,
                             fastLaneResolver: (@MainActor (String, String?, [JSONValue]) -> CuaTaskAgent.FastResolution?)? = { _, _, _ in nil }) -> CuaVoiceRuntime {
        CuaVoiceRuntime(config: config,
            makeConnection: { CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                            arguments: ["-u", script.path],
                                            onToolCall: { name, _ in calls?.record(name) }) },
            judge: judge,
            fastLaneResolver: fastLaneResolver,
            screenLocked: { false })
    }

    private func makeConfig() -> Config {
        Config(defaults: UserDefaults(suiteName: "test.cua.voice.\(UUID())")!,
               keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(), environment: [:])
    }

    /// Judge/event closures run wherever the worker runs — the canned-answer
    /// helpers and shared flags stay nonisolated so they never hop.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return raw }
            set { lock.lock(); raw = newValue; lock.unlock() }
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return raw }
        func bump() { lock.lock(); raw += 1; lock.unlock() }
    }

    private nonisolated func pick(_ choice: String) -> Answer {
        .choice(choice: choice, confidence: 0.95, probabilities: [choice: 0.95])
    }
    private nonisolated func answers(next: String, fill: String = "unavailable",
                                     evidence: String = "proven", blocked: String = "other") -> [String: Answer] {
        ["next": pick(next), "fill": pick(fill),
         "doneEvidence": pick(evidence), "blockedReason": pick(blocked)]
    }
    /// The drive loop's action pick: choose the offered lane whose criteria text
    /// matches `needle`, else claim the request done once `settled` flips.
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

    // MARK: - Routing

    /// The deterministic fast lane: the resolver identifies the primitive; the
    /// drive loop never sees it and the judge is never called.
    func testFastLaneOpenNeedsNoJudgeCall() async throws {
        let config = makeConfig()
        let calls = CallLog()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            treeApps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]")
        let judged = Counter()
        let runtime = makeRuntime(config: config, script: script,
            judge: { _, _ in judged.bump(); return [:] },
            calls: calls,
            fastLaneResolver: { goal, _, _ in
                guard goal.lowercased().contains("fixture") else { return nil }
                return CuaTaskAgent.FastResolution(action: nil, openVerb: "open",
                                                   name: "Fixture", bundle: "test.fixture")
            })
        let ack = await runtime.beginVoiceTask("open Fixture", app: nil)
        XCTAssertTrue(ack.hasPrefix("STARTED"), ack)
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertEqual(work.status, "Completed", work.message)
        XCTAssertEqual(judged.value, 0, "The deterministic lane never spends a judgment")
        XCTAssertEqual(work.bundle, "test.fixture")
        await runtime.shutdown()
    }

    // MARK: - Pending questions

    /// A fill lane with no supplied value ends the attempt as a parked
    /// question; the spoken answer resumes the same intent in a fresh attempt.
    func testPendingQuestionSurfacesAndAnswerResumesOwner() async throws {
        let config = makeConfig()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Draft','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'body0','role':'AXTextArea','label':'Body','enabled':True}]")
        let answered = Flag()
        let filled = Flag()
        let runtime = makeRuntime(config: config, script: script, judge: { _, questions in
            if !filled.value, let id = self.nextLaneID(questions, containing: "Type the supplied text") {
                if answered.value { filled.value = true }
                return self.answers(next: id, fill: answered.value ? "answer" : "unavailable")
            }
            return self.answers(next: "done")
        })
        let controller = VoiceController(config: config, speech: Capture(), authorize: { true },
                                         cuaRuntime: runtime)
        _ = await runtime.beginVoiceTask("insert the reply in Fixture", app: "Fixture")
        let first = try XCTUnwrap(runtime.tasks.first)
        try await until { !first.active }
        XCTAssertEqual(first.status, "Failed", first.message)
        let pending = controller.pendingQuestions
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending[0].prompt.contains("Body"), pending[0].prompt)
        XCTAssertEqual(pending[0].owner, "insert the reply in Fixture")

        let reply = await runtime.respondToTask("hello draft", captureID: first.provenance?.captureID ?? UUID())
        XCTAssertTrue(reply?.hasPrefix("Resuming") ?? false, reply ?? "nil")
        answered.value = true
        let resumed = try XCTUnwrap(runtime.tasks.last)
        XCTAssertNotEqual(resumed.id, first.id)
        XCTAssertEqual(resumed.intentID, first.intentID, "The answer resumes the same dialogue intent")
        XCTAssertNotEqual(resumed.attemptID, first.attemptID, "A resumed intent gets a fresh attempt")
        try await until { !resumed.active }
        XCTAssertEqual(resumed.status, "Completed", resumed.message)
        XCTAssertTrue(controller.pendingQuestions.isEmpty)
        await controller.shutdown()
    }

    /// Withdrawing a parked question resolves the intent — a cancelled question
    /// does not wait for an answer that may never arrive.
    func testCancellingAParkedQuestionWithdrawsIt() async throws {
        let config = makeConfig()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Draft','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'body0','role':'AXTextArea','label':'Body','enabled':True}]")
        let runtime = makeRuntime(config: config, script: script, judge: { _, questions in
            if let id = self.nextLaneID(questions, containing: "Type the supplied text") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        _ = await runtime.beginVoiceTask("insert the reply in Fixture", app: "Fixture")
        let work = try XCTUnwrap(runtime.tasks.first)
        try await until { !work.active }
        XCTAssertNotNil(runtime.dialogue.pendingClarification)
        runtime.cancel(work.id)
        XCTAssertNil(runtime.dialogue.pendingClarification)
        XCTAssertEqual(work.status, "Cancelled")
        let lateReply = await runtime.respondToTask("late answer")
        XCTAssertNil(lateReply)
        await runtime.shutdown()
    }

    // MARK: - Cancel / retry

    func testCancelVoiceTaskMatchesHintAndBareNames() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let config = makeConfig()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let runtime = makeRuntime(config: config, script: script, judge: { _, questions in
            if let id = self.nextLaneID(questions, containing: "Delete") {
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        XCTAssertEqual(runtime.cancelVoiceTask("anything"), "Nothing is running.")
        _ = await runtime.beginVoiceTask("press Delete in Fixture", app: "Fixture")
        try await until { runtime.tasks.last?.approval != nil }
        let reply = runtime.cancelVoiceTask("delete")
        XCTAssertTrue(reply.hasPrefix("Stopping"), reply)
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertTrue(work.stopRequested)
        await runtime.shutdown()
    }

    /// Retry resumes the same intent with a fresh attempt — never a new intent,
    /// never a replayed tool call.
    func testRetryWorkResumesTheSameIntent() async throws {
        let config = makeConfig()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]")
        let judgeCalls = Counter()
        let runtime = makeRuntime(config: config, script: script, judge: { _, _ in
            judgeCalls.bump()
            if judgeCalls.value == 1 { throw DriverConnectionError.refused("judgment unavailable") }
            return self.answers(next: "done")
        })
        let controller = VoiceController(config: config, speech: Capture(),
                                         authorize: { true }, cuaRuntime: runtime)
        _ = await runtime.beginVoiceTask("press Save in Fixture", app: "Fixture")
        let first = try XCTUnwrap(runtime.tasks.first)
        try await until { !first.active }
        XCTAssertEqual(first.status, "Failed", first.message)
        XCTAssertTrue(controller.canRetryTask(first.id))
        let reply = await runtime.retryWork(first.id)
        XCTAssertTrue(reply.hasPrefix("Trying again"), reply)
        let retried = try XCTUnwrap(runtime.tasks.last)
        XCTAssertEqual(retried.intentID, first.intentID)
        XCTAssertNotEqual(retried.attemptID, first.attemptID)
        try await until { !retried.active }
        XCTAssertEqual(retried.status, "Completed", retried.message)
        await controller.shutdown()
    }

    // MARK: - Controller surface

    /// heardFinal is the model's own transcript — display only. The instruction
    /// reaches the runtime through the tool call, never through this text.
    func testHeardFinalIsDisplayOnlyAndSpawnsNoWork() async throws {
        let config = makeConfig()
        let script = try driverScript()
        let runtime = makeRuntime(config: config, script: script, judge: { _, _ in [:] })
        let speech = Capture()
        let controller = VoiceController(config: config, speech: speech,
                                         authorize: { true }, cuaRuntime: runtime)
        controller.begin()
        try await until { controller.status == .listening }
        speech.emit(.heardFinal("open Fixture"))
        try await until { controller.status == .executing }
        XCTAssertEqual(controller.transcript, "open Fixture")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.cuaTasks.isEmpty,
                      "A display-only transcript must never create work")
        await controller.shutdown()
    }

    /// A typed command with no realtime lane fails honestly — no fake success,
    /// no task record.
    func testTypedCommandWithoutALaneFailsHonestly() async throws {
        let config = makeConfig()
        let script = try driverScript()
        let runtime = makeRuntime(config: config, script: script, judge: { _, _ in [:] })
        let controller = VoiceController(config: config, speech: Capture(),
                                         authorize: { true }, cuaRuntime: runtime)
        controller.submitTypedCommand("open Fixture")
        try await until { controller.status == .error("The realtime voice lane is not available.") }
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        await controller.shutdown()
    }

    /// A finished capture routes through the same realtime lane as typing —
    /// without a lane the failure surfaces instead of pretending to run.
    func testFinalTranscriptWithoutALaneFailsHonestly() async throws {
        let config = makeConfig()
        let script = try driverScript()
        let runtime = makeRuntime(config: config, script: script, judge: { _, _ in [:] })
        let speech = Capture()
        let controller = VoiceController(config: config, speech: speech,
                                         authorize: { true }, cuaRuntime: runtime)
        controller.begin()
        try await until { controller.status == .listening }
        controller.finish()
        speech.emit(.final("open Fixture"))
        try await until { controller.status == .error("The realtime voice lane is not available.") }
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        await controller.shutdown()
    }

    /// A bare yes with exactly one pending consent resolves it — the agent
    /// gate's seam — and never reaches the lane.
    func testBareYesResolvesPendingConsent() async throws {
        let config = makeConfig()
        let script = try driverScript()
        let runtime = makeRuntime(config: config, script: script, judge: { _, _ in [:] })
        let speech = Capture()
        let controller = VoiceController(config: config, speech: speech,
                                         authorize: { true }, cuaRuntime: runtime)
        let request = ConsentRequest(summary: "Agent wants to click in Mail", reason: "send the reply")
        var resolved: (String, Bool)?
        controller.pendingConsent = { request }
        controller.onConsentResolution = { resolved = ($0.id, $1) }
        controller.begin()
        try await until { controller.status == .listening }
        controller.finish()
        speech.emit(.final("yes"))
        try await until { controller.status == .done }
        XCTAssertEqual(resolved?.0, request.id)
        XCTAssertEqual(resolved?.1, true)
        await controller.shutdown()
    }

    func testAutomaticEmptyFinalDismissesSilently() async throws {
        let config = makeConfig()
        let runtime = makeRuntime(config: config, script: try driverScript(), judge: { _, _ in [:] })
        let speech = Capture()
        let controller = VoiceController(config: config, speech: speech,
                                         authorize: { true }, cuaRuntime: runtime)
        controller.begin()
        try await until { controller.status == .listening }
        controller.finish()
        speech.emit(.final("   "))
        try await until { controller.status == .idle }
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        await controller.shutdown()
    }

    /// Events from a dead session id can never reach the new capture's state.
    func testEventsFromADeadSessionAreIgnored() async throws {
        let config = makeConfig()
        let runtime = makeRuntime(config: config, script: try driverScript(), judge: { _, _ in [:] })
        let speech = Capture()
        let controller = VoiceController(config: config, speech: speech,
                                         authorize: { true }, cuaRuntime: runtime)
        controller.begin()
        try await until { controller.status == .listening }
        let stale = speech.id!
        controller.cancel()
        controller.begin()
        try await until { controller.status == .listening }
        speech.onEvent?(stale, .final("stale words"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.transcript, "")
        XCTAssertEqual(controller.status, .listening)
        await controller.shutdown()
    }

    /// The diagnostics card follows the selected work — task ids, revisions and
    /// the measured stage timings, never the literal payload.
    func testDiagnosticsFollowTheSelectedTask() async throws {
        let config = makeConfig()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]")
        let runtime = makeRuntime(config: config, script: script, judge: { _, _ in
            self.answers(next: "done")
        })
        let controller = VoiceController(config: config, speech: Capture(),
                                         authorize: { true }, cuaRuntime: runtime)
        _ = await runtime.beginVoiceTask("press Save in Fixture", app: "Fixture")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        controller.selectTask(work.id)
        XCTAssertEqual(controller.diagnosticTask?.id, work.id)
        let lines = controller.taskDiagnostics(work)
        XCTAssertTrue(lines.contains { $0.hasPrefix("intent ") && $0.contains("attempt") }, lines.joined(separator: " | "))
        XCTAssertTrue(lines.contains { $0.contains("verified") }, lines.joined(separator: " | "))
        XCTAssertNotNil(work.timings["Transcript to submission"])
        XCTAssertNotNil(work.timings["Jev execution"])
        XCTAssertNotNil(work.timings["Transcript to observed result"])
        await controller.shutdown()
    }

    /// Shutdown ends the shared driver session exactly once — cancelled work
    /// cannot make a second end_session leak into the next run.
    func testShutdownEndsTheSharedSessionOnce() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let config = makeConfig()
        let calls = CallLog()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let runtime = makeRuntime(config: config, script: script,
            judge: { _, questions in
                if let id = self.nextLaneID(questions, containing: "Delete") {
                    return self.answers(next: id)
                }
                return self.answers(next: "done")
            },
            calls: calls)
        _ = await runtime.beginVoiceTask("press Delete in Fixture", app: "Fixture")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { work.approval != nil }
        runtime.cancel(work.id)
        try await until { !work.active }
        await runtime.shutdown()
        XCTAssertEqual(calls.count("start_session"), 1)
        XCTAssertEqual(calls.count("end_session"), 1)
    }
}

private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}
