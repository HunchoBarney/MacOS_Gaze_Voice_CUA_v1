import XCTest
import JevVoiceCore
@testable import JevVoice

/// Spawn-contract tests for `CuaVoiceRuntime.beginVoiceTask`: the realtime
/// `computer_command` tool call returns an acknowledgement at acceptance and
/// the work settles asynchronously; consent parks on the work and resolves
/// through `respondToTask`; settled outcomes push to the lane's sink keyed by
/// the originating capture id. A scripted MCP driver stands in for the Cua
/// transport so no desktop mutation or real model call happens.
@MainActor
final class CuaVoiceSpawnTests: XCTestCase {
    /// A cancellable hold inside the scripted judge — a work stays active
    /// until released, proving the ack returns before execution settles.
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

    /// A scripted MCP driver: enough of the tools/call surface for session
    /// bootstrap, app resolution, drive-loop observations and the dispatch
    /// lanes these tests exercise. Unknown tools acknowledge honestly.
    private func driverScript(apps: String = "[]", treeApps: String = "[]",
                              windows: String = "[]", elements: String = "[]",
                              launchPID: Int = 4242) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-spawn-\(UUID().uuidString).py")
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

    private func makeRuntime(script: URL,
                             judge: @escaping CuaTaskAgent.Judge,
                             calls: CallLog? = nil,
                             fastLaneResolver: (@MainActor (String, String?, String?, [JSONValue]) -> CuaTaskAgent.FastResolution?)? = { _, _, _, _ in nil }) -> CuaVoiceRuntime {
        let config = Config(defaults: UserDefaults(suiteName: "test.cua.spawn.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(), environment: [:])
        return CuaVoiceRuntime(config: config,
            makeConnection: { CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                            arguments: ["-u", script.path],
                                            onToolCall: { name, _ in calls?.record(name) }) },
            judge: judge,
            fastLaneResolver: fastLaneResolver,
            screenLocked: { false })
    }

    private nonisolated func pick(_ choice: String) -> Answer {
        .choice(choice: choice, confidence: 0.95, probabilities: [choice: 0.95])
    }
    private nonisolated func answers(next: String, fill: String = "unavailable",
                                     evidence: String = "proven", blocked: String = "other") -> [String: Answer] {
        ["next": pick(next), "fill": pick(fill),
         "doneEvidence": pick(evidence), "blockedReason": pick(blocked)]
    }
    private nonisolated func nextLaneID(_ questions: [String: Question], containing needle: String) -> String? {
        guard case let .choice(_, criteria)? = questions["next"] else { return nil }
        return criteria.first { ($0.value ?? "").localizedCaseInsensitiveContains(needle) }?.key
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raw = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return raw }
            set { lock.lock(); raw = newValue; lock.unlock() }
        }
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

    /// computer_command returns the moment the work is accepted — "STARTED"
    /// with an acknowledgement instruction — while the drive loop is still
    /// mid-judgment. The verified outcome settles later.
    func testVoiceCommandReturnsAcknowledgementWhileWorkSettles() async throws {
        let gate = JudgeGate()
        let calls = CallLog()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':0,'running':False}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'save0','role':'AXButton','label':'Save','enabled':True}]")
        let runtime = makeRuntime(script: script,
            judge: { _, _ in
                await gate.hold()
                return self.answers(next: "done")
            },
            calls: calls)
        let ack = await runtime.beginVoiceTask("press Save in Fixture", app: "Fixture")
        XCTAssertTrue(ack.hasPrefix("STARTED") || ack.lowercased().contains("acknowledge"), ack)
        try await until { gate.entered }
        let work = try XCTUnwrap(runtime.tasks.last)
        XCTAssertTrue(work.active, "The ack must return while work is still running")
        XCTAssertNil(work.outcome)
        gate.open()
        try await until { !work.active }
        XCTAssertEqual(work.status, "Completed", work.message)
        XCTAssertEqual(calls.count("start_session"), 1, "One shared driver session per runtime")
        await runtime.shutdown()
        XCTAssertEqual(calls.count("end_session"), 1)
    }

    /// A consequential dispatch parks on work.approval; a bare "yes" through
    /// respond_to_task resolves the waiter and the run continues to a
    /// verified outcome.
    func testRespondToTaskResolvesPendingConsent() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let clickSeen = Flag()
        let runtime = makeRuntime(script: script, judge: { _, questions in
            if !clickSeen.value, let id = self.nextLaneID(questions, containing: "Delete") {
                clickSeen.value = true
                return self.answers(next: id)
            }
            return self.answers(next: "done")
        })
        let captureID = UUID()
        _ = await runtime.beginVoiceTask("press the Delete button in Fixture",
                                         app: "Fixture", captureID: captureID)
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { work.approval != nil }
        XCTAssertEqual(work.status, "Needs confirmation")
        let reply = await runtime.respondToTask("yes", captureID: captureID)
        XCTAssertTrue(reply?.hasPrefix("Approved") ?? false, reply ?? "nil")
        try await until { !work.active }
        XCTAssertEqual(work.status, "Completed", work.message)
        await runtime.shutdown()
    }

    /// Denying the parked ask stops the dispatch — the refused click never
    /// reaches the driver.
    func testRespondToTaskDenialNeverDispatches() async throws {
        let prior = CuaStandingGrants.computerUseInput
        CuaStandingGrants.computerUseInput = false
        defer { CuaStandingGrants.computerUseInput = prior }
        let calls = CallLog()
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]",
            elements: "[{'element_index':0,'element_token':'del0','role':'AXButton','label':'Delete','enabled':True}]")
        let runtime = makeRuntime(script: script,
            judge: { _, questions in
                if let id = self.nextLaneID(questions, containing: "Delete") {
                    return self.answers(next: id)
                }
                return self.answers(next: "done")
            },
            calls: calls)
        _ = await runtime.beginVoiceTask("press the Delete button in Fixture", app: "Fixture")
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { work.approval != nil }
        let reply = await runtime.respondToTask("no")
        XCTAssertTrue(reply?.hasPrefix("Denied") ?? false, reply ?? "nil")
        try await until { !work.active }
        XCTAssertNotEqual(work.status, "Completed")
        XCTAssertEqual(calls.count("click"), 0, "A denied action must never dispatch")
        XCTAssertEqual(calls.count("press_key"), 0)
        await runtime.shutdown()
    }

    /// Settlement pushes `[task outcome]` to the lane's sink carrying the same
    /// capture id the command was submitted under — the model hears the verdict
    /// on the turn that spawned the work.
    func testOutcomeSettlesThroughTaskEventSinkWithCaptureID() async throws {
        let script = try driverScript(
            apps: "[{'name':'Fixture','bundle_id':'test.fixture','pid':4242,'running':True}]",
            windows: "[{'window_id':7,'title':'Fixture','is_on_screen':True}]")
        var events: [(UUID, String, Bool)] = []
        let runtime = makeRuntime(script: script, judge: { _, _ in
            self.answers(next: "done")
        })
        let captureID = UUID()
        runtime.taskEventSink = { id, text, speak in events.append((id, text, speak)) }
        _ = await runtime.beginVoiceTask("press Save in Fixture", app: "Fixture",
                                         captureID: captureID)
        let work = try XCTUnwrap(runtime.tasks.last)
        try await until { !work.active }
        XCTAssertEqual(work.status, "Completed", work.message)
        XCTAssertEqual(work.provenance?.captureID, captureID)
        let outcomes = events.filter { $0.0 == captureID && $0.1.hasPrefix("[task outcome]") }
        XCTAssertEqual(outcomes.count, 1, "Exactly one outcome push per settled work: \(events)")
        XCTAssertTrue(outcomes[0].1.contains("press Save in Fixture"))
        await runtime.shutdown()
    }

    func testEmptyInstructionRefusesWithoutWork() async throws {
        let runtime = makeRuntime(script: try driverScript(), judge: { _, _ in [:] })
        let ack = await runtime.beginVoiceTask("   ", app: nil)
        XCTAssertEqual(ack, "No instruction was provided.")
        XCTAssertTrue(runtime.tasks.isEmpty)
        await runtime.shutdown()
    }
}

private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}
