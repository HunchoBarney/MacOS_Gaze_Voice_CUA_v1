import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaVoiceControllerTests: XCTestCase {
    private final class Capture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var id: UUID?
        var snapshot = RangedTranscript()
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String { id = session; snapshot = RangedTranscript(); return "Fixture microphone" }
        func finish() {}
        func cancel() {}
        func emitRevision(_ revision: SpeechRevision) {
            try! snapshot.apply(revision)
            emit(.transcript(snapshot))
        }
        func emit(_ event: SpeechEvent) { if let id { onEvent?(id, event) } }
    }
    private struct Keys: APIKeyStore {
        func read() throws -> String? { "fixture-key" }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }
    private func setup(automatic: Bool = true, delayedIntent: Bool = false, delayedAction: Bool = false,
                       sessionStartDelayMs: Int = 0, sessionEndDelayMs: Int = 0,
                       windowedFixture: Bool = false, runningFixture: Bool = false, textFixture: Bool = false,
                       persistFixture: Bool = false, intentKind: String = "command", laterFailure: String? = nil,
                       operations: [String] = [], spanEnds: [Int] = [], taskScopes: [String] = [],
                       correctionModes: [String] = [], observeJudge: ((JSONValue, [String: Question]) -> Void)? = nil) throws -> (VoiceController, Capture, URL, UserDefaults) {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-pipeline-\(UUID()).py")
        let script = #"""
import json,sys,time
persist=PERSIST
state_path='STATE_PATH'
running=START_RUNNING
session_delay=SESSION_DELAY_SECONDS
session_end_delay=SESSION_END_DELAY_SECONDS
if persist:
 try:
  with open(state_path) as f: running=json.load(f)['running']
 except FileNotFoundError: pass
windowed=WINDOWED
text_enabled=TEXT_ENABLED
typed=''
def save_state():
 if persist:
  with open(state_path,'w') as f: json.dump({'running':running},f)
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='initialize': out={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
 else:
  name=r['params']['name']
  with open(__file__+'.calls','a') as f: f.write(name+'\n')
  if name == 'get_browser_state':
   out={'isError':True,'structuredContent':{'refusal':{'code':'browser_route_unavailable'}}}
  else:
   if name in ('list_apps','get_accessibility_tree'): value={'apps':[{'name':'Fixture','bundle_id':'test.fixture','running':running,'pid':42 if running else 0}]}
   elif name=='launch_app': running=True; save_state(); value={'pid':42}
   elif name=='list_windows': value={'windows':[{'window_id':7,'title':'Fixture','is_on_screen':True,'z_index':1}]} if windowed else {'windows':[]}
   elif name=='bring_to_front': value={'activated':True,'exact_window_effect':{'verified':True}}
   elif name=='get_window_state':
    elements=[{'element_index':0,'role':'AXWindow','label':'Fixture'}]
    if windowed: elements += [{'element_index':1,'role':'AXMenuBarItem','label':'File'},{'element_index':2,'parent_index':1,'role':'AXMenuItem','label':'Quit'}]
    if text_enabled: elements += [{'element_index':3,'role':'AXTextArea','label':'Body','element_token':'body','value':typed}]
    value={'elements':elements}
   elif name=='type_text':
    typed=r['params']['arguments'].get('text','')
    with open(__file__+'.text','a') as f: f.write(json.dumps(typed)+'\n')
    value={'inserted':True}
   elif name=='invoke_menu':
    path=r['params']['arguments'].get('path',[])
    if path and path[-1]=='Quit': running=False; save_state()
    value={'status':'invoked','resolved_path':path}
   elif name in ('start_session','end_session'):
    if name=='start_session' and session_delay: time.sleep(session_delay)
    if name=='end_session' and session_end_delay: time.sleep(session_end_delay)
    value={'active':name=='start_session'}
   else: raise RuntimeError('Unexpected fixture tool '+name)
   out={'structuredContent':value}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':out}),flush=True)
"""#.replacingOccurrences(of: "WINDOWED", with: windowedFixture ? "True" : "False")
            .replacingOccurrences(of: "START_RUNNING", with: runningFixture ? "True" : "False")
            .replacingOccurrences(of: "SESSION_DELAY_SECONDS", with: String(Double(sessionStartDelayMs) / 1_000))
            .replacingOccurrences(of: "SESSION_END_DELAY_SECONDS", with: String(Double(sessionEndDelayMs) / 1_000))
            .replacingOccurrences(of: "TEXT_ENABLED", with: textFixture ? "True" : "False")
            .replacingOccurrences(of: "PERSIST", with: persistFixture ? "True" : "False")
            .replacingOccurrences(of: "STATE_PATH", with: fixture.path + ".state")
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.path + ".calls"))
        }
        let defaults = UserDefaults(suiteName: "CuaVoiceControllerTests-\(UUID())")!
        let config = Config(defaults: defaults, keyStore: Keys(), environment: [:])
        config.autoExecute = automatic
        var executorCalls = 0
        var actionDecisions = 0
        let runtime = CuaVoiceRuntime(config: config, makeConnection: { CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.path]) }, judge: { state, questions in
            observeJudge?(state, questions)
            let directDecision = questions["operation"] != nil
            if directDecision {
                executorCalls += 1
                if executorCalls == 1, laterFailure == "service" { throw URLError(.notConnectedToInternet) }
                if delayedIntent { try? await Task.sleep(for: .milliseconds(80)) }
            }
            if questions["next"] != nil, delayedAction {
                actionDecisions += 1
                if actionDecisions == 1 { try await Task.sleep(for: .milliseconds(600)) }
            }
            var answers: [String: Answer] = [:]
            for key in questions.keys {
                let value: String
                switch key {
                case "operation":
                    if laterFailure == "incomplete" { value = "wait" }
                    else if !operations.isEmpty { value = operations[min(executorCalls - 1, operations.count - 1)] }
                    else if intentKind == "stopAll" { value = "stopAll" }
                    else if intentKind == "stop" { value = "stop" }
                    else if intentKind == "correction" { value = "correction" }
                    else { value = "execute" }
                case "span":
                    if laterFailure == "incomplete" { value = "wait" }
                    else if !spanEnds.isEmpty { value = String(spanEnds[min(executorCalls - 1, spanEnds.count - 1)]) }
                    else { value = String(state["pending_word_range"]?["end"]?.integer ?? 0) }
                case "task":
                    if let tasks = state["task_context"]?["tasks"]?.array, let first = tasks.first, let id = first["id"]?.string { value = id }
                    else { value = "independent" }
                case "app":
                    value = "app_0"
                case "visibility": value = "background"
                case "scope": value = taskScopes.isEmpty ? "launch" : taskScopes[min(executorCalls - 1, taskScopes.count - 1)]
                case "contentMode": value = intentKind == "dictate" ? "dictate" : intentKind == "literal" ? "literal" : "control"
                case "literalStart": value = ["dictate", "literal"].contains(intentKind) ? "1" : "none"
                case "literalEnd": value = ["dictate", "literal"].contains(intentKind) ? String(state["pending_word_range"]?["end"]?.integer ?? 0) : "none"
                case "correctionMode": value = correctionModes.isEmpty ? "replace" : correctionModes[min(executorCalls - 1, correctionModes.count - 1)]
                case "replacementStart": value = "1"
                case "replacementEnd": value = String(state["pending_word_range"]?["end"]?.integer ?? 0)
                case "clarification": value = "none"
                case "next":
                    if ["dictate", "literal"].contains(intentKind), case let .choice(_, choices) = questions[key],
                       let action = choices.first(where: { $0.key.hasPrefix("action_") && ($0.value ?? "").contains("Insert supplied text") }) {
                        value = action.key
                    } else { value = "done" }
                case "risk": value = "ordinary"
                case "windowEffect": value = "same"
                case "quit": value = "0"
                default: throw DriverConnectionError.malformed
                }
                answers[key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
            }
            return answers
        })
        let capture = Capture()
        let controller = VoiceController(config: config, speech: capture, authorize: { true }, frontmost: { "Fixture" }, cuaRuntime: runtime)
        return (controller, capture, fixture, defaults)
    }
    private func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the production voice pipeline")
    }
    func testExecutorMustSelectAnOperationBeforeCreatingOrDispatchingWork() async throws {
        for failure in ["service", "incomplete"] {
            let (controller, capture, file, _) = try setup(laterFailure: failure)
            defer { try? FileManager.default.removeItem(at: file) }
            controller.begin(); try await until { controller.status == .listening }
            capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
            await controller.cua.speech.waitForPending()
            XCTAssertTrue(controller.cuaTasks.isEmpty, "A failed or incomplete first executor decision must not create work")
            await controller.shutdown()
        }
    }

    func testIncompleteNegatedAndConditionalSpeechSelectNoDispatch() async throws {
        for request in ["search for", "don't open Notes", "when I finish, open Notes"] {
            let (controller, capture, file, _) = try setup(laterFailure: "incomplete", observeJudge: { state, questions in
                guard questions["operation"] != nil else { return }
                XCTAssertEqual(state["transcript"], .string(request))
            })
            defer { try? FileManager.default.removeItem(at: file) }
            controller.begin(); try await until { controller.status == .listening }
            capture.emitRevision(.init(start: 0, end: 1, text: request, isFinal: true))
            await controller.cua.speech.waitForPending()

            XCTAssertTrue(controller.cuaTasks.isEmpty, "No task or CUA action may start for: \(request)")
            XCTAssertEqual(controller.cua.speech.outcome, "incomplete")
            await controller.shutdown()
        }
    }

    func testFinalIncompleteSuffixWinsOverCompletedSelectedTaskMessage() async throws {
        let (controller, capture, file, _) = try setup(
            operations: ["execute", "wait"], spanEnds: [2, 4]
        )
        defer { try? FileManager.default.removeItem(at: file) }
        let transcript = "open Fixture search for"
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: transcript, isFinal: true))
        try await until {
            controller.cuaTasks.first?.status == "Completed" && controller.cua.speech.outcome == "incomplete"
        }

        controller.finish()
        capture.emit(.final(transcript))
        try await until { controller.status == .done }

        XCTAssertEqual(controller.resultMessage, "The request is incomplete; no action was taken.")
        await controller.shutdown()
    }

    func testProductionPathActsBeforeReleaseAndDoesNotRepeatFinal() async throws {
        let (controller, capture, file, _) = try setup()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin()
        try await until { controller.status == .listening }
        capture.emitRevision(SpeechRevision(start: 0, end: 1, text: "open Fixture", isFinal: false))
        for _ in 0..<100 where controller.cua.speech.outcome != "candidate" { await Task.yield() }
        XCTAssertTrue(controller.cuaTasks.isEmpty, "Fresh volatile recognition is not ready")
        capture.emitRevision(SpeechRevision(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.status == "Completed" }
        XCTAssertEqual(controller.status, .listening)
        XCTAssertEqual(controller.cuaTasks.count, 1)
        let provenance = try XCTUnwrap(controller.cuaTasks.first?.provenance)
        XCTAssertEqual(provenance.audioRanges.first?.start, 0)
        XCTAssertEqual(provenance.audioRanges.first?.end, 1)
        XCTAssertEqual(provenance.captureID, capture.id)
        XCTAssertEqual(provenance.wordStart, 0)
        XCTAssertEqual(provenance.wordEnd, 2)
        controller.finish(); capture.emit(.final("open Fixture"))
        try await until { controller.status == .done }
        XCTAssertEqual(controller.cuaTasks.count, 1)
        await controller.shutdown()
    }

    func testLaunchedTaskRetainsItsEligibleCorrectionReceipt() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.status == "Completed" }

        XCTAssertNotNil(controller.cuaTasks.first?.launchReceipt,
            "A Cua-verified launch receipt must remain attached to its task for a later safe correction")
        await controller.shutdown()
    }

    func testCancelledTaskRetainsLaunchReceiptObservedBeforeNextDecision() async throws {
        var reachedActionChoice = false
        let (controller, capture, file, _) = try setup(delayedAction: true, windowedFixture: true,
            taskScopes: ["work"], observeJudge: { _, questions in
                if questions["next"] != nil { reachedActionChoice = true }
            })
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { reachedActionChoice || controller.cua.tasks.first.map { !$0.active } == true }
        XCTAssertTrue(reachedActionChoice, "The task ended before the later decision: \(controller.cua.tasks.first?.message ?? "no task message")")
        let launched = try XCTUnwrap(controller.cua.tasks.first)
        controller.cua.cancel(launched.id)
        try await until { !launched.active }

        XCTAssertEqual(launched.status, "Cancelled")
        XCTAssertNotNil(launched.launchReceipt, "Cancellation must retain the CUA-verified receipt captured before the later Jev await")
        let calls = try String(contentsOf: URL(fileURLWithPath: file.path + ".calls"), encoding: .utf8)
        XCTAssertTrue(calls.split(separator: "\n").contains("end_session"),
            "Cancellation must give the external session a chance to clean up")
        await controller.shutdown()
    }

    func testRuntimeShutdownAwaitsInflightFirstDecisionSessionCleanup() async throws {
        var deciding = false
        let (controller, capture, file, _) = try setup(delayedIntent: true, sessionEndDelayMs: 250,
            observeJudge: { _, questions in
                if questions["operation"] != nil { deciding = true }
            })
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin()
        try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { deciding }

        var returned = false
        let shutdown = Task {
            await controller.cua.shutdown()
            returned = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(returned, "Runtime shutdown must await cancellation cleanup for the in-flight decision")
        if returned { try await Task.sleep(for: .milliseconds(300)) }
        await shutdown.value

        let calls = try String(contentsOf: URL(fileURLWithPath: file.path + ".calls"), encoding: .utf8)
        XCTAssertTrue(calls.split(separator: "\n").contains("end_session"))
    }

    func testCorrectionUsesFreshRunningProcessEvidenceForSafeLaunchReversal() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true, persistFixture: true,
            operations: ["execute", "correction"], spanEnds: [2, 5], taskScopes: ["launch", "launch"],
            correctionModes: ["retract", "retract"])
        let stateFile = URL(fileURLWithPath: file.path + ".state")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: stateFile)
        }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture undo that launch", isFinal: true))
        try await until { controller.cuaTasks.count == 2 }
        guard controller.cuaTasks.count == 2 else {
            XCTFail("The executor did not schedule the correction request: \(controller.cua.speech.error ?? controller.cua.speech.message)")
            await controller.shutdown()
            return
        }
        try await until { controller.cuaTasks[1].approval != nil || !controller.cuaTasks[1].active }
        if controller.cuaTasks[1].approval != nil {
            controller.cua.resolveApproval(controller.cuaTasks[1].id, approved: true)
        }
        try await until { controller.cuaTasks.allSatisfy { !$0.active } }

        let stateData = try Data(contentsOf: stateFile)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Bool])
        XCTAssertEqual(state["running"], false, "A correction must inspect the live process and reverse only the unchanged task-owned launch")
        XCTAssertEqual(controller.cuaTasks[1].message, "Closed only the unchanged app launched by that task.")
        await controller.shutdown()
    }

    func testFirstJevDecisionReceivesVerbatimTranscriptAndTaskContext() async throws {
        var calls: [(state: JSONValue, questions: Set<String>)] = []
        let (controller, capture, file, _) = try setup(observeJudge: { state, questions in
            calls.append((state, Set(questions.keys)))
        })
        defer { try? FileManager.default.removeItem(at: file) }
        let transcript = "open Fixture"
        controller.begin()
        try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: transcript, isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let first = try XCTUnwrap(calls.first)
        XCTAssertEqual(first.state["transcript"], .string(transcript))
        XCTAssertEqual(first.state["task_context"]?["initial_app"], .string("Fixture"))
        XCTAssertNotNil(first.state["task_context"]?["tasks"])
        XCTAssertNil(first.state["pending_speech"], "A speech-classification request must not precede executor judgment")
        XCTAssertTrue(first.questions.contains("operation"), "The executor makes the first semantic decision")
        XCTAssertFalse(first.questions.contains("boundary"), "There is no speech-interpreter boundary call")
        await controller.shutdown()
    }

    func testNewerTranscriptRevisionDiscardsInflightDecisionAndReleaseDoesNotReplay() async throws {
        var calls: [(state: JSONValue, questions: Set<String>)] = []
        let (controller, capture, file, _) = try setup(delayedIntent: true, observeJudge: { state, questions in
            calls.append((state, Set(questions.keys)))
        })
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin()
        try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: false))
        try await until { calls.contains { $0.questions.contains("operation") } }
        XCTAssertTrue(controller.cuaTasks.isEmpty, "A model decision in flight has not selected a task yet")

        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture again", isFinal: true))
        try await until { controller.cuaTasks.first?.status == "Completed" }
        XCTAssertEqual(controller.cuaTasks.map(\.request), ["open Fixture again"])
        XCTAssertEqual(controller.cuaTasks.count, 1)

        controller.finish()
        capture.emit(.final("open Fixture again"))
        try await until { controller.status == .done }
        XCTAssertEqual(controller.cuaTasks.map(\.request), ["open Fixture again"], "Finalization must not replay the accepted source range")
        await controller.shutdown()
    }
    func testDiagnosticsFollowSelectedTaskWithoutMixingCaptureTimings() async throws {
        let (controller, capture, file, _) = try setup(operations: ["execute", "execute"], spanEnds: [2, 4])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 1 && !controller.cuaTasks[0].active }
        let first = controller.cuaTasks[0]
        capture.emitRevision(.init(start: 1, end: 2, text: " open Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && !controller.cuaTasks[1].active }
        let second = controller.cuaTasks[1]
        XCTAssertEqual(controller.diagnosticTask?.id, second.id)
        controller.selectTask(first.id)
        XCTAssertEqual(controller.diagnosticTask?.id, first.id)
        XCTAssertNotNil(second.timings["Cua list_apps"])
        XCTAssertNotNil(second.timings["Jev execution"])
        XCTAssertNotNil(second.timings["Queue wait"])
        XCTAssertNil(controller.measurements["Transcript to first dispatch"])
        XCTAssertNil(controller.measurements["Task elapsed"])
        XCTAssertNotNil(controller.measurements["Microphone ready"])
        await controller.shutdown()
    }

    func testTranscriptToFirstDecisionIncludesCuaSessionStartup() async throws {
        let (controller, capture, file, _) = try setup(sessionStartDelayMs: 400)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.status == "Completed" }

        let work = try XCTUnwrap(controller.cuaTasks.first)
        let toDecision = try XCTUnwrap(work.timings["Transcript to first Jev decision"])
        let toSubmission = try XCTUnwrap(work.timings["Transcript to submission"])
        XCTAssertGreaterThanOrEqual(toSubmission, toDecision)
        XCTAssertLessThan(toSubmission - toDecision, 150,
            "Session connection and startup belong inside transcript-to-decision latency")
        await controller.shutdown()
    }
    func testManualModeHasNoEarlyEffectsAndApprovalCannotReplay() async throws {
        let (controller, capture, file, _) = try setup(automatic: false)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emit(.partial("open Fixture"))
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        controller.finish(); capture.emit(.final("open Fixture"))
        XCTAssertEqual(controller.status, .awaitingConfirm)
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        controller.confirm(); controller.confirm()
        try await until { controller.cuaTasks.first?.status == "Completed" }
        XCTAssertEqual(controller.cuaTasks.count, 1)
        await controller.shutdown()
    }
    func testEarlyFinalAndRecognitionFailureInvalidatePendingIntent() async throws {
        for failure in [false, true] {
            let (controller, capture, file, _) = try setup(delayedIntent: true)
            defer { try? FileManager.default.removeItem(at: file) }
            controller.begin(); try await until { controller.status == .listening }
            capture.emit(.partial("open Fixture"))
            await Task.yield()
            capture.emit(failure ? .failure("microphone interrupted") : .final("open Fixture"))
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertEqual(controller.status, .awaitingRelease)
            XCTAssertTrue(controller.cuaTasks.isEmpty, "A stopped recognizer must invalidate late judgments")
            controller.finish()
            XCTAssertEqual(controller.status, .reviewTranscript)
            await controller.shutdown()
        }
    }
    func testOldCaptureCallbackCannotEnterNewProductionHold() async throws {
        let (controller, capture, file, _) = try setup()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        let old = try XCTUnwrap(capture.id)
        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        var stale = RangedTranscript()
        try stale.apply(.init(start: 0, end: 1, text: "open old app", isFinal: true))
        capture.onEvent?(old, .transcript(stale))
        await controller.cua.speech.waitForPending()
        XCTAssertEqual(controller.transcript, "")
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.status == "Completed" }
        XCTAssertEqual(controller.cuaTasks.count, 1)
        await controller.shutdown()
    }

    func testStopAllWithNoTasksFinishesFeedback() async throws {
        let (controller, capture, file, _) = try setup(intentKind: "stopAll")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        controller.finish(); capture.emit(.final("stop all"))
        await controller.cua.speech.waitForPending()
        XCTAssertEqual(controller.status, .done)
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        await controller.shutdown()
    }

    func testAmbiguousStopKeepsSpecificClarificationVisible() async throws {
        let (controller, capture, file, _) = try setup(intentKind: "stop")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin()
        try await until { controller.status == .listening }
        controller.finish()
        capture.emit(.final("stop it"))
        await controller.cua.speech.waitForPending()

        XCTAssertEqual(controller.status, .error("Which assistant task do you mean?"))
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        XCTAssertEqual(controller.resultMessage, "", "Clarification must not be treated as successful completion")
        await controller.shutdown()
    }

    func testJevSelectedStopCancelsTheSelectedTaskWithinTheSameHold() async throws {
        var selectedTask: String?
        let (controller, capture, file, _) = try setup(delayedAction: true, operations: ["execute", "stop"], spanEnds: [2, 4], taskScopes: ["work"], observeJudge: { state, questions in
            guard questions["operation"] != nil, state["pending_word_range"]?["start"]?.integer == 2 else { return }
            selectedTask = state["task_context"]?["tasks"]?.array?.first?["id"]?.string
        })
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture stop it", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        XCTAssertEqual(controller.cuaTasks.first?.status, "Cancelled")
        XCTAssertEqual(controller.cuaTasks.last?.status, "Completed")
        XCTAssertEqual(selectedTask, controller.cuaTasks.first?.id.uuidString)
        XCTAssertEqual(controller.cuaTasks.map(\.request), ["open Fixture", "stop it"])
        await controller.shutdown()
    }

    func testJevSelectedStopAllCancelsActiveAndQueuedTasks() async throws {
        var executorDecisions = 0
        let (controller, capture, file, _) = try setup(delayedAction: true,
            operations: ["execute", "execute", "stopAll"], spanEnds: [2, 4, 6], taskScopes: ["work", "work"],
            observeJudge: { _, questions in if questions["operation"] != nil { executorDecisions += 1 } })
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture open Fixture stop all", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        XCTAssertGreaterThanOrEqual(executorDecisions, 3, "Each completed source span reaches the executor")
        XCTAssertEqual(controller.cuaTasks.map(\.status), ["Cancelled", "Cancelled"])
        XCTAssertEqual(controller.cuaTasks.map(\.request), ["open Fixture", "open Fixture"])
        await controller.shutdown()
    }

    func testAutomaticEmptyFinalDismissesWithoutTask() async throws {
        let (controller, capture, file, _) = try setup()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        controller.finish(); capture.emit(.final(" "))
        XCTAssertEqual(controller.status, .idle)
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        await controller.shutdown()
    }

    func testSilenceDoesNotAskForManualApproval() async throws {
        let (controller, capture, file, _) = try setup(automatic: false)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        controller.finish(); capture.emit(.final("  "))
        XCTAssertEqual(controller.status, .idle)
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        await controller.shutdown()
    }

    func testManualEarlyFinalRetainsCompleteTranscriptForReview() async throws {
        let (controller, capture, file, _) = try setup(automatic: false)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emit(.partial("open"))
        capture.emit(.final("open Fixture"))
        controller.finish()
        XCTAssertEqual(controller.status, .reviewTranscript)
        XCTAssertEqual(controller.transcript, "open Fixture")
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        await controller.shutdown()
    }

    func testLiteralVoiceCannotLaunchAnAppNamedInsideTheContent() async throws {
        let (controller, capture, file, _) = try setup(intentKind: "dictate")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emit(.partial("dictate open Notes and stop all"))
        controller.finish(); capture.emit(.final("dictate open Notes and stop all"))
        try await until { controller.cuaTasks.first?.active == false }
        XCTAssertEqual(controller.cuaTasks.first?.status, "Failed")
        XCTAssertTrue(controller.cuaTasks.first?.message.contains("No app was launched") == true)
        XCTAssertEqual(controller.cuaTasks.count, 1)
        await controller.shutdown()
    }

    func testDictationWaitsForFinalTranscriptAndInsertsItsExactLiteralOnce() async throws {
        let request = "dictate open Notes and stop all"
        var finality: [Bool] = []
        let (controller, capture, file, _) = try setup(windowedFixture: true, runningFixture: true,
            textFixture: true, intentKind: "dictate", taskScopes: ["work"], observeJudge: { state, questions in
                if questions["operation"] != nil { finality.append(state["final"]?.bool ?? false) }
            })
        let insertionLog = URL(fileURLWithPath: file.path + ".text")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: insertionLog)
        }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: request, isFinal: false))
        await controller.cua.speech.waitForPending()

        XCTAssertTrue(controller.cuaTasks.isEmpty, "Provisional dictation stays revisable until release fallback")
        XCTAssertEqual(controller.cua.speech.message, "Dictation will be inserted after you finish speaking.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: insertionLog.path))
        XCTAssertEqual(finality, [false])

        controller.finish()
        capture.emitRevision(.init(start: 0, end: 1, text: request, isFinal: true))
        capture.emit(.final(request))
        try await until { controller.cuaTasks.first?.status == "Completed" }

        XCTAssertEqual(finality, [false, true])
        XCTAssertEqual(try String(contentsOf: insertionLog, encoding: .utf8), "\"open Notes and stop all\"\n")
        XCTAssertEqual(controller.cuaTasks.count, 1)
        await controller.shutdown()
    }

    func testNaturalLiteralWaitsForReleaseBeforeInserting() async throws {
        let request = "type open Notes and stop all"
        let (controller, capture, file, _) = try setup(windowedFixture: true, runningFixture: true,
            textFixture: true, intentKind: "literal", taskScopes: ["work"])
        let insertionLog = URL(fileURLWithPath: file.path + ".text")
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: insertionLog)
        }
        controller.begin()
        try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: request, isFinal: true))
        await controller.cua.speech.waitForPending()

        XCTAssertTrue(controller.cuaTasks.isEmpty, "Provisional literal insertion must remain revisable until release")
        XCTAssertFalse(FileManager.default.fileExists(atPath: insertionLog.path))

        controller.finish()
        capture.emit(.final(request))
        try await until { controller.cuaTasks.first?.status == "Completed" }

        XCTAssertEqual(try String(contentsOf: insertionLog, encoding: .utf8), "\"open Notes and stop all\"\n")
        XCTAssertEqual(controller.cuaTasks.count, 1)
        await controller.shutdown()
    }

}
