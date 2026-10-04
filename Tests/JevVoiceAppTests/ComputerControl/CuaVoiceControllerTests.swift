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
                       driverUnavailableAfterFirstConnection: Bool = false,
                       operations: [String] = [], spanEnds: [Int] = [], taskScopes: [String] = [],
                       correctionModes: [String] = [], relationships: [String] = [],
                       answerPendingQuestion: Bool = false, dropAfterLaunchOnce: Bool = false,
                       dropAfterEveryLaunch: Bool = false, unresolvedLimit: Int? = nil,
                       resolvedHistoryLimit: Int? = nil,
                       selectedTasks: [String] = [], multiWindowedFixture: Bool = false,
                       appAnswers: [String] = [], windowAnswers: [String] = [],
                       pendingQuestionIndex: Int = 0, nextCandidateMatch: String? = nil,
                       contentModes: [String] = [],
                       partialAfterSecondNext: Bool = false, dropAfterTypeOnce: Bool = false,
                       observeJudge: ((JSONValue, [String: Question]) -> Void)? = nil) throws -> (VoiceController, Capture, URL, UserDefaults) {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-pipeline-\(UUID()).py")
        let script = #"""
import json,sys,time,os
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
multiwindow=MULTIWINDOW
text_enabled=TEXT_ENABLED
typed=''
def save_state():
 if persist:
  with open(state_path,'w') as f: json.dump({'running':running},f)
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 drop_now=False
 if r['method']=='initialize': out={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
 else:
  name=r['params']['name']
  with open(__file__+'.calls','a') as f: f.write(name+'\n')
  if name == 'get_browser_state':
   out={'isError':True,'structuredContent':{'refusal':{'code':'browser_route_unavailable'}}}
  else:
   if name in ('list_apps','get_accessibility_tree'): value={'apps':[{'name':'Fixture','bundle_id':'test.fixture','running':running,'pid':42 if running else 0}]}
   elif name=='launch_app':
    running=True; save_state(); value={'pid':42}
    if DROP_ALWAYS or (DROP_ONCE and not os.path.exists(__file__+'.dropped')): open(__file__+'.dropped','w').write('x'); drop_now=True
   elif name=='list_windows':
    if multiwindow: value={'windows':[{'window_id':7,'title':'Fixture','is_on_screen':True,'z_index':1},{'window_id':9,'title':'Other Fixture','is_on_screen':True,'z_index':0}]}
    elif windowed: value={'windows':[{'window_id':7,'title':'Fixture','is_on_screen':True,'z_index':1}]}
    else: value={'windows':[]}
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
    if DROP_TYPE and not os.path.exists(__file__+'.typedropped'): open(__file__+'.typedropped','w').write('x'); drop_now=True
   elif name=='invoke_menu':
    path=r['params']['arguments'].get('path',[])
    if path and path[-1]=='Quit': running=False; save_state()
    value={'status':'invoked','resolved_path':path}
   elif name=='hotkey': value={'status':'pressed'}
   elif name in ('start_session','end_session'):
    if name=='start_session' and session_delay: time.sleep(session_delay)
    if name=='end_session' and session_end_delay: time.sleep(session_end_delay)
    value={'active':name=='start_session'}
   elif name=='set_agent_cursor_enabled':
    with open(__file__+'.cursor','a') as f: f.write(str(r['params']['arguments'].get('enabled'))+'\n')
    value={'session':r['params']['arguments'].get('session',''),'enabled':r['params']['arguments'].get('enabled',False)}
   else: raise RuntimeError('Unexpected fixture tool '+name)
   out={'structuredContent':value}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':out}),flush=True)
 if drop_now: sys.exit(0)
"""#.replacingOccurrences(of: "WINDOWED", with: windowedFixture ? "True" : "False")
            .replacingOccurrences(of: "START_RUNNING", with: runningFixture ? "True" : "False")
            .replacingOccurrences(of: "SESSION_DELAY_SECONDS", with: String(Double(sessionStartDelayMs) / 1_000))
            .replacingOccurrences(of: "SESSION_END_DELAY_SECONDS", with: String(Double(sessionEndDelayMs) / 1_000))
            .replacingOccurrences(of: "TEXT_ENABLED", with: textFixture ? "True" : "False")
            .replacingOccurrences(of: "DROP_ONCE", with: dropAfterLaunchOnce ? "True" : "False")
            .replacingOccurrences(of: "DROP_ALWAYS", with: dropAfterEveryLaunch ? "True" : "False")
            .replacingOccurrences(of: "DROP_TYPE", with: dropAfterTypeOnce ? "True" : "False")
            .replacingOccurrences(of: "MULTIWINDOW", with: multiWindowedFixture ? "True" : "False")
            .replacingOccurrences(of: "PERSIST", with: persistFixture ? "True" : "False")
            .replacingOccurrences(of: "STATE_PATH", with: fixture.path + ".state")
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        let unavailableFixture = URL(fileURLWithPath: fixture.path + ".unavailable.py")
        if driverUnavailableAfterFirstConnection {
            try "open(__file__ + '.started', 'w').write('started')\n".write(
                to: unavailableFixture, atomically: true, encoding: .utf8)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.path + ".calls"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.path + ".cursor"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.path + ".dropped"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.path + ".typedropped"))
            try? FileManager.default.removeItem(at: unavailableFixture)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: unavailableFixture.path + ".started"))
        }
        let defaults = UserDefaults(suiteName: "CuaVoiceControllerTests-\(UUID())")!
        let config = Config(defaults: defaults, keyStore: Keys(), environment: [:])
        config.autoExecute = automatic
        var executorCalls = 0
        var actionDecisions = 0
        var nextCalls = 0
        var windowCalls = 0
        var connections = 0
        let runtime = CuaVoiceRuntime(config: config, makeConnection: {
            connections += 1
            if driverUnavailableAfterFirstConnection && connections > 1 {
                return CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-u", unavailableFixture.path])
            }
            return CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.path])
        }, judge: { state, questions in
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
            let chosenRelationship: String = {
                if !relationships.isEmpty {
                    return relationships[min(executorCalls - 1, relationships.count - 1)]
                }
                if let tasks = state["task_context"]?["tasks"]?.array, tasks.first?["id"]?.string != nil {
                    let op = operations.isEmpty
                        ? (intentKind == "correction" ? "correction" : "execute")
                        : operations[min(executorCalls - 1, operations.count - 1)]
                    return op == "correction" ? "revision" : "continuation"
                }
                return "independent"
            }()
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
                    if !selectedTasks.isEmpty {
                        value = selectedTasks[min(executorCalls - 1, selectedTasks.count - 1)]
                    } else if let tasks = state["task_context"]?["tasks"]?.array, let first = tasks.first, let id = first["id"]?.string { value = id }
                    else { value = "independent" }
                case "relationship":
                    value = chosenRelationship
                case "pendingQuestion":
                    let published = state["task_context"]?["questions"]?.array ?? []
                    if answerPendingQuestion, chosenRelationship == "answer", !published.isEmpty,
                       let qid = published[min(pendingQuestionIndex, published.count - 1)]["id"]?.string {
                        value = qid
                    } else { value = "none" }
                case "app":
                    value = appAnswers.isEmpty ? "app_0"
                        : appAnswers[min(executorCalls - 1, appAnswers.count - 1)]
                case "window":
                    windowCalls += 1
                    let raw = windowAnswers.isEmpty ? "none"
                        : windowAnswers[min(windowCalls - 1, windowAnswers.count - 1)]
                    value = raw == "none" ? raw : "w\(raw)"
                case "visibility": value = "background"
                case "scope": value = taskScopes.isEmpty ? "launch" : taskScopes[min(executorCalls - 1, taskScopes.count - 1)]
                case "contentMode":
                    if !contentModes.isEmpty {
                        value = contentModes[min(executorCalls - 1, contentModes.count - 1)]
                    } else {
                        value = intentKind == "dictate" ? "dictate" : intentKind == "literal" ? "literal" : "control"
                    }
                case "literalStart": value = ["dictate", "literal"].contains(intentKind) ? "1" : "none"
                case "literalEnd": value = ["dictate", "literal"].contains(intentKind) ? String(state["pending_word_range"]?["end"]?.integer ?? 0) : "none"
                case "correctionMode": value = correctionModes.isEmpty ? "replace" : correctionModes[min(executorCalls - 1, correctionModes.count - 1)]
                case "replacementStart": value = "1"
                case "replacementEnd": value = String(state["pending_word_range"]?["end"]?.integer ?? 0)
                case "clarification": value = "none"
                case "next":
                    nextCalls += 1
                    if partialAfterSecondNext && nextCalls == 2 {
                        throw DriverConnectionError.refused("Cua could not confirm the remaining requested change. The task is incomplete; no further action was dispatched.")
                    }
                    if let nextCandidateMatch, case let .choice(_, choices) = questions[key],
                       let action = choices.first(where: { ($0.value ?? "").contains(nextCandidateMatch) }) {
                        value = action.key
                    } else if ["dictate", "literal"].contains(intentKind), case let .choice(_, choices) = questions[key],
                       let action = choices.first(where: { ($0.value ?? "").contains("Type the supplied text") }) {
                        value = action.key
                    } else { value = "done" }
                case "risk": value = "ordinary"
                case "windowEffect": value = "same"
                case "quit": value = "0"
                case "doneEvidence": value = "proven"
                default: throw DriverConnectionError.malformed
                }
                answers[key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
            }
            return answers
        }, dialogue: CuaDialogueState(resolvedHistoryLimit: resolvedHistoryLimit ?? 32,
                                    unresolvedLimit: unresolvedLimit ?? 32),
            screenLocked: { false })
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
        await controller.shutdown()

        // The shared run-scoped session ends once at shutdown — never per task.
        let calls = try String(contentsOf: URL(fileURLWithPath: file.path + ".calls"), encoding: .utf8)
        XCTAssertTrue(calls.split(separator: "\n").contains("end_session"),
            "Shutdown must give the shared external session a chance to clean up")
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
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.status == "Completed" }
        capture.emitRevision(.init(start: 1, end: 2, text: " undo that launch", isFinal: true))
        try await until { controller.cuaTasks.count == 2 }
        guard controller.cuaTasks.count == 2 else {
            XCTFail("The executor did not schedule the correction request: \(controller.cua.speech.error ?? controller.cua.speech.message)")
            await controller.shutdown()
            return
        }
        try await until { controller.cuaTasks.count > 1 && (controller.cuaTasks[1].approval != nil || !controller.cuaTasks[1].active) }
        if controller.cuaTasks.count > 1, controller.cuaTasks[1].approval != nil {
            controller.cua.resolveApproval(controller.cuaTasks[1].id, approved: true)
        }
        try await until { controller.cuaTasks.allSatisfy { !$0.active } }

        let stateData = try Data(contentsOf: stateFile)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateData) as? [String: Bool])
        XCTAssertEqual(state["running"], false, "A correction must inspect the live process and reverse only the unchanged task-owned launch")
        XCTAssertEqual(controller.cuaTasks.dropFirst().first?.message, "Closed only the unchanged app launched by that task.")
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
    func testConflictingLaunchAndLiteralDecisionDoesNotDispatch() async throws {
        let (controller, capture, file, _) = try setup(intentKind: "literal")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        await controller.cua.speech.waitForPending()
        XCTAssertEqual(controller.status, .listening)
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        XCTAssertEqual(controller.cua.speech.outcome, "clarification")
        await controller.shutdown()
    }
    func testManualModeHasNoEarlyEffectsAndApprovalCannotReplay() async throws {
        let (controller, capture, file, _) = try setup(automatic: false, windowedFixture: true)
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

        // Clarification is a normal dialogue state — a pending question, not
        // an Open-settings error and not a fake completion.
        XCTAssertEqual(controller.status, .awaitingAnswer("Which assistant task do you mean?"))
        if case .error = controller.status {
            XCTFail("A pending clarification must never present as an error")
        }
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        XCTAssertEqual(controller.resultMessage, "", "Clarification must not be treated as successful completion")
        XCTAssertEqual(controller.pendingQuestions.map(\.prompt), ["Which assistant task do you mean?"])
        XCTAssertTrue(controller.canBegin, "A pending question stays answerable on the next hold")
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
        XCTAssertEqual(selectedTask, controller.cuaTasks.first?.intentID.uuidString,
            "Jev selects the published intent id, which resolves back to the task's attempt")
        XCTAssertEqual(controller.cuaTasks.map(\.request), ["open Fixture", "stop it"])
        await controller.shutdown()
    }

    func testJevSelectedStopCancelsTaskWhenDriverIsUnavailable() async throws {
        let (controller, capture, file, _) = try setup(delayedAction: true,
            driverUnavailableAfterFirstConnection: true,
            operations: ["execute", "stop"], spanEnds: [2, 4], taskScopes: ["work"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture stop it", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        XCTAssertEqual(controller.cuaTasks.first?.status, "Cancelled")
        XCTAssertEqual(controller.cuaTasks.last?.status, "Completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".unavailable.py.started"))
        await controller.shutdown()
    }

    func testJevSelectedStopAllCancelsTaskWhenDriverIsUnavailable() async throws {
        let (controller, capture, file, _) = try setup(delayedAction: true,
            driverUnavailableAfterFirstConnection: true,
            operations: ["execute", "stopAll"], spanEnds: [2, 4], taskScopes: ["work"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture stop all", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        XCTAssertEqual(controller.cuaTasks.count, 1)
        XCTAssertEqual(controller.cuaTasks.first?.status, "Cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".unavailable.py.started"))
        await controller.shutdown()
    }

    func testJevSelectedCorrectionRetractsPendingTaskWithoutDriver() async throws {
        let (controller, capture, file, _) = try setup(delayedAction: true,
            windowedFixture: true, runningFixture: true,
            driverUnavailableAfterFirstConnection: true,
            operations: ["execute", "correction"], spanEnds: [2, 5], taskScopes: ["work"],
            correctionModes: ["retract"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1,
            text: "open Fixture actually cancel that", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        XCTAssertEqual(controller.cuaTasks.first?.status, "Cancelled")
        XCTAssertEqual(controller.cuaTasks.last?.status, "Completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".unavailable.py.started"))
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

    func testDictationKeepsKeyboardCommandWordsAsLiteralContent() async throws {
        for request in ["dictate press the key \"Enter\"", "dictate do not press the key \"Enter\""] {
            let (controller, capture, file, _) = try setup(windowedFixture: true, runningFixture: true,
                textFixture: true, intentKind: "dictate", taskScopes: ["work"])
            let insertionLog = URL(fileURLWithPath: file.path + ".text")
            defer {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: insertionLog)
            }
            controller.begin(); try await until { controller.status == .listening }
            controller.finish(); capture.emit(.final(request))
            try await until { controller.cuaTasks.first?.active == false }

            XCTAssertEqual(controller.cuaTasks.first?.status, "Completed", request)
            let inserted = try Data(contentsOf: insertionLog)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: inserted), String(request.dropFirst(8)), request)
            await controller.shutdown()
        }
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

    /// A failed referenced task is conversational context, never an execution
    /// dependency: a continuation of it still runs on its own.
    func testFailedReferenceDoesNotBlockIndependentContinuation() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true,
            taskScopes: ["create", "launch"], relationships: ["independent", "continuation"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "create a document", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        XCTAssertEqual(controller.cuaTasks.first?.status, "Failed",
            "Creating a document with no new observed window must fail, not pretend to succeed")

        capture.emitRevision(.init(start: 1, end: 2, text: " open Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let later = try XCTUnwrap(controller.cuaTasks.last)
        let earlier = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(later.status, "Completed",
            "A follow-up that only refers to a failed task must still execute: \(later.message)")
        XCTAssertEqual(later.referencedIntentID, earlier.intentID,
            "The follow-up stays conversationally linked without inheriting any dependency")
        if case .continuation(let parent) = controller.cua.dialogue.entry(for: later.intentID)?.relationship {
            XCTAssertEqual(parent, earlier.intentID)
        } else {
            XCTFail("The follow-up must record a continuation relationship, not a blocking edge")
        }
        await controller.shutdown()
    }

    /// An explicit prerequisite is the only blocking edge: without the required
    /// verified fact the dependent intent refuses honestly instead of running.
    func testPrerequisiteBlocksWhenRequiredFactMissing() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true,
            taskScopes: ["create", "launch"], relationships: ["independent", "prerequisite"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "create a document", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        XCTAssertEqual(controller.cuaTasks.first?.status, "Failed")

        capture.emitRevision(.init(start: 1, end: 2, text: " then open Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let dependent = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(dependent.status, "Failed")
        XCTAssertTrue(dependent.message.contains("verified result"), dependent.message)
        XCTAssertFalse(dependent.dispatchedEffect,
            "A prerequisite missing its verified fact must not dispatch anything")
        await controller.shutdown()
    }

    /// A satisfied prerequisite discharges on the bound verified fact: the
    /// dependent intent waits for the in-flight predecessor, then executes.
    func testPrerequisiteExecutesAfterVerifiedFactObserved() async throws {
        let (controller, capture, file, _) = try setup(delayedAction: true, windowedFixture: true,
            taskScopes: ["work", "launch"], relationships: ["independent", "prerequisite"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 1 }
        capture.emitRevision(.init(start: 1, end: 2, text: " then switch", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let first = try XCTUnwrap(controller.cuaTasks.first)
        let dependent = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(first.status, "Completed", first.message)
        XCTAssertEqual(dependent.status, "Completed",
            "Once the required fact is observed, the dependent request executes: \(dependent.message)")
        XCTAssertNotNil(controller.cua.dialogue.entry(for: first.intentID)?.verifiedFacts
            .first { $0.kind == .resultObserved && $0.attemptID == first.attemptID },
            "The observed launch must be bound to the producing attempt and intent revision")
        await controller.shutdown()
    }

    /// A decide-level clarification records a pending question on the new intent;
    /// the next hold's answer binds that question and executes the owner intent.
    func testClarificationQuestionAnsweredOnNextHold() async throws {
        let (controller, capture, file, _) = try setup(
            operations: ["clarify", "execute"], taskScopes: ["launch", "launch"],
            relationships: ["independent", "answer"], answerPendingQuestion: true)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        await controller.cua.speech.waitForPending()

        XCTAssertEqual(controller.cua.speech.outcome, "clarification")
        XCTAssertTrue(controller.cuaTasks.isEmpty)
        let pending = try XCTUnwrap(controller.cua.dialogue.entries.first {
            if case .awaitingAnswer = $0.status { return true }
            return false
        }, "The ambiguous request must become an intent awaiting an answer")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let work = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(work.intentID, pending.intent.id,
            "The answer must resume the same intent, not create a new one")
        XCTAssertEqual(work.status, "Completed", work.message)
        XCTAssertFalse(controller.cua.dialogue.entries.contains {
            if case .awaitingAnswer = $0.status { return true }
            return false
        }, "The pending question must resolve once answered")
        await controller.shutdown()
    }

    /// A withdrawn question cannot be resurrected: a retry routed at a cancelled
    /// intent is rejected honestly, and the intent stays cancelled.
    func testRetryOfWithdrawnQuestionIntentIsRejected() async throws {
        let (controller, capture, file, _) = try setup(
            operations: ["clarify", "execute"], taskScopes: ["launch", "launch"],
            relationships: ["independent", "retry"], answerPendingQuestion: true)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        await controller.cua.speech.waitForPending()
        let pending = try XCTUnwrap(controller.cua.dialogue.entries.first {
            if case .awaitingAnswer = $0.status { return true }
            return false
        })

        controller.cua.stopAll()
        guard case .cancelled = controller.cua.dialogue.entry(for: pending.intent.id)?.status else {
            XCTFail("Stop All must withdraw the pending question's intent")
            await controller.shutdown()
            return
        }

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "try that again", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let retry = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(retry.status, "Failed")
        XCTAssertTrue(retry.message.contains("cancelled"), retry.message)
        XCTAssertFalse(retry.dispatchedEffect)
        guard case .cancelled = controller.cua.dialogue.entry(for: pending.intent.id)?.status else {
            XCTFail("A routed retry must not resurrect a cancelled intent")
            await controller.shutdown()
            return
        }
        XCTAssertTrue(controller.cua.dialogue.entry(for: pending.intent.id)?.answers.isEmpty ?? true)
        await controller.shutdown()
    }

    /// A decide-time clarification keeps the request's literal payload and
    /// scope: the next-hold answer resumes the intent and dispatches the
    /// original text — the reply's own "launch" classification can never
    /// narrow the original request into an early app-observed success.
    func testClarifiedLiteralRequestDispatchesOriginalPayloadAfterAnswer() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true, textFixture: true, intentKind: "literal",
            operations: ["execute", "execute"], taskScopes: ["work", "launch"],
            relationships: ["independent", "answer"], answerPendingQuestion: true,
            appAnswers: ["none", "app_0"], contentModes: ["literal", "control"])
        defer { try? FileManager.default.removeItem(at: file) }
        let insertionLog = URL(fileURLWithPath: file.path + ".text")
        defer { try? FileManager.default.removeItem(at: insertionLog) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 2, text: "type hello", isFinal: true))
        await controller.cua.speech.waitForPending()

        XCTAssertEqual(controller.cua.speech.outcome, "clarification")
        let pending = try XCTUnwrap(controller.cua.dialogue.entries.first {
            if case .awaitingAnswer = $0.status { return true }
            return false
        }, "The literal request must wait for an answer, not start a new intent")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        // A provisional answer revision must not dispatch the stored payload;
        // the retained literal was already finalized in its original hold.
        capture.emitRevision(.init(start: 0, end: 1, text: "Fixture", isFinal: false))
        await controller.cua.speech.waitForPending()
        XCTAssertTrue(controller.cuaTasks.isEmpty,
            "A non-final answer revision stays revisable and dispatches nothing")
        controller.finish()
        capture.emitRevision(.init(start: 0, end: 1, text: "Fixture", isFinal: true))
        capture.emit(.final("Fixture"))
        try await until { controller.cuaTasks.first?.active == false }

        let work = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(work.intentID, pending.intent.id,
            "The answer resumes the clarified intent in place")
        XCTAssertEqual(work.status, "Completed", work.message)
        XCTAssertFalse(work.message.contains("already running"),
            "The reply's launch classification must not early-succeed a work intent")
        let typed = try String(contentsOf: insertionLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(typed, ["\"hello\""],
            "The resumed attempt dispatches the original request's literal payload")
        await controller.shutdown()
    }

    /// An uncertain retry whose reply is classified "launch" keeps the intent's
    /// recorded "work" scope, so the fresh attempt re-executes the request
    /// instead of early-returning on an already-running app.
    func testRetryKeepsOriginalScopeWhenReplyClassifiesAsLaunch() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true, textFixture: true, intentKind: "literal",
            taskScopes: ["work", "launch"], relationships: ["independent", "retry"],
            contentModes: ["literal", "control"], dropAfterTypeOnce: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let insertionLog = URL(fileURLWithPath: file.path + ".text")
        defer { try? FileManager.default.removeItem(at: insertionLog) }
        controller.begin(); try await until { controller.status == .listening }
        controller.finish(); capture.emit(.final("type hello"))
        try await until { controller.cuaTasks.first?.active == false }
        XCTAssertEqual(controller.cuaTasks.first?.status, "Uncertain")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        controller.finish(); capture.emit(.final("try that again"))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let retry = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertFalse(retry.message.contains("already running"),
            "A launch-shaped reply must not narrow the intent's work scope")
        let typed = try String(contentsOf: insertionLog, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(typed.count, 2,
            "The retried attempt still executes the original request's payload")
        await controller.shutdown()
    }

    /// A revision relationship produces a correction-of intent linked to the
    /// selected task while remaining an independent execution attempt.
    func testDestinationChangeRecordsCorrectionOfSelectedIntent() async throws {
        let (controller, capture, file, _) = try setup(
            taskScopes: ["launch", "launch"], relationships: ["independent", "revision"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.status == "Completed" }

        capture.emitRevision(.init(start: 1, end: 2, text: " change that", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let first = try XCTUnwrap(controller.cuaTasks.first)
        let change = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(change.status, "Completed", change.message)
        if case .correction(let parent) = controller.cua.dialogue.entry(for: change.intentID)?.relationship {
            XCTAssertEqual(parent, first.intentID)
        } else {
            XCTFail("A revision must record a correction-of relationship to the selected intent")
        }
        await controller.shutdown()
    }

    /// An uncertain execution finishes the attempt as uncertain; a retry resumes
    /// the same intent in place with a fresh attempt id.
    func testUncertainOutcomeRetriesSameIntentInPlace() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            taskScopes: ["work", "launch"], relationships: ["independent", "retry"],
            dropAfterLaunchOnce: true)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let uncertain = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(uncertain.status, "Uncertain",
            "A driver that drops mid-run must surface an uncertain outcome, not success: \(uncertain.message)")
        let callsBeforeRetry = try String(contentsOf: URL(fileURLWithPath: file.path + ".calls"),
            encoding: .utf8).split(separator: "\n").filter { $0 == "launch_app" }
        XCTAssertEqual(callsBeforeRetry.count, 1,
            "The dropped launch is never blindly replayed; only an explicit retry may re-dispatch")

        capture.emitRevision(.init(start: 1, end: 2, text: " try that again", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let retry = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(retry.intentID, uncertain.intentID, "Retry resumes the same intent")
        XCTAssertNotEqual(retry.attemptID, uncertain.attemptID, "Each retry is a fresh attempt")
        XCTAssertEqual(retry.status, "Completed", retry.message)
        await controller.shutdown()
    }

    /// Terminal-ambiguous entries (uncertain, partial, blocked) drain
    /// oldest-first when unresolved capacity fills, so a later request is
    /// still accepted instead of wedging on the unresolved ledger.
    func testUncertainEntriesDrainToMakeRoomForNewIntent() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            taskScopes: ["launch", "launch", "launch"],
            relationships: ["independent", "independent", "independent"],
            dropAfterEveryLaunch: true, unresolvedLimit: 2,
            selectedTasks: ["independent", "independent", "independent"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        let firstID = try XCTUnwrap(controller.cuaTasks.first?.intentID)

        capture.emitRevision(.init(start: 1, end: 2, text: " open Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }
        XCTAssertEqual(controller.cua.dialogue.entries.filter { !$0.status.isResolved }.count, 2,
            "Both uncertain intents occupy unresolved capacity")

        capture.emitRevision(.init(start: 2, end: 3, text: " open Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 3 && controller.cuaTasks.allSatisfy { !$0.active } }

        let third = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(third.status, "Uncertain", third.message)
        XCTAssertTrue(third.dispatchedEffect,
            "Drained capacity must let the new request actually execute: \(third.message)")
        guard case .cancelled(let reason) = controller.cua.dialogue.entry(for: firstID)?.status else {
            XCTFail("The oldest uncertain entry must drain to make room for the new intent")
            return
        }
        XCTAssertTrue(reason.contains("make room"), reason)
        await controller.shutdown()
    }

    /// Pending questions and live intents are never drained: at capacity the
    /// runtime refuses the new utterance honestly and leaves them intact.
    func testPendingQuestionsAtCapacityRefuseHonestly() async throws {
        let (controller, capture, file, _) = try setup(
            operations: ["clarify", "clarify", "execute"],
            taskScopes: ["launch", "launch", "launch"], unresolvedLimit: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open something", isFinal: true))
        await controller.cua.speech.waitForPending()
        capture.emitRevision(.init(start: 1, end: 2, text: " open something else", isFinal: true))
        await controller.cua.speech.waitForPending()
        XCTAssertEqual(controller.cua.dialogue.entries.filter {
            if case .awaitingAnswer = $0.status { return true }
            return false
        }.count, 2, "Two pending questions fill unresolved capacity")

        capture.emitRevision(.init(start: 2, end: 3, text: " open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let refused = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(refused.status, "Failed")
        XCTAssertTrue(refused.message.contains("Too many unresolved"), refused.message)
        XCTAssertFalse(refused.dispatchedEffect)
        XCTAssertEqual(controller.cua.dialogue.entries.filter {
            if case .awaitingAnswer = $0.status { return true }
            return false
        }.count, 2, "Refusing must not destroy the pending questions")
        await controller.shutdown()
    }

    func testReadOnlyBrowserDialogInspectionDoesNotCountAsDispatchedEffect() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-browser-inspection-\(UUID()).py")
        try #"""
import json,sys
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='initialize': out={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
 else:
  name=r['params']['name']; args=r['params'].get('arguments',{})
  if name in ('list_apps','get_accessibility_tree'): value={'apps':[{'name':'Google Chrome','bundle_id':'com.google.Chrome','running':True,'pid':42}]}
  elif name=='list_windows': value={'windows':[{'window_id':7,'title':'Fixture page','is_on_screen':True}]}
  elif name=='get_window_state': value={'elements':[]}
  elif name=='get_browser_state' and 'target_id' not in args: value={'binding_quality':'exact','mutation_allowed':True,'target_id':'target','tabs':[{'tab_id':'tab','active':True}]}
  elif name=='get_browser_state': value={'target_id':'target','tab_id':'tab','page':{'url':'https://example.invalid/'},'refs':[]}
  elif name=='browser_dialog':
   if args.get('action')!='inspect': raise RuntimeError('Unexpected browser dialog mutation')
   value={'status':'ok','target_id':'target','tab_id':'tab','present':False}
  elif name in ('start_session','end_session'): value={'active':name=='start_session'}
  elif name=='set_agent_cursor_enabled': value={'session':args.get('session',''),'enabled':args.get('enabled',False)}
  else: raise RuntimeError('Unexpected fixture tool '+name)
  out={'structuredContent':value}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':out}),flush=True)
"""#.write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let defaults = UserDefaults(suiteName: "CuaBrowserInspection-\(UUID())")!
        let config = Config(defaults: defaults, keyStore: Keys(), environment: [:])
        let runtime = CuaVoiceRuntime(config: config, makeConnection: {
            CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.path])
        }, judge: { state, questions in
            var answers: [String: Answer] = [:]
            for key in questions.keys {
                let value: String
                switch key {
                case "operation": value = "execute"
                case "span": value = String(state["pending_word_range"]?["end"]?.integer ?? 0)
                case "task": value = "independent"
                case "relationship": value = "independent"
                case "pendingQuestion": value = "none"
                case "contentMode": value = "control"
                case "literalStart", "literalEnd", "replacementStart", "replacementEnd", "clarification": value = "none"
                case "correctionMode": value = "retract"
                case "app": value = "app_0"
                case "scope": value = "work"
                case "visibility": value = "background"
                case "next": value = "stuck"
                case "doneEvidence": value = "unproven"
                default: throw DriverConnectionError.malformed
                }
                answers[key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
            }
            return answers
        }, screenLocked: { false })

        runtime.begin(app: "Google Chrome")
        runtime.update("Inspect the current browser page", final: true)
        try await until { runtime.tasks.first?.active == false }

        let work = try XCTUnwrap(runtime.tasks.first)
        XCTAssertEqual(work.status, "Failed")
        XCTAssertTrue(work.message.contains("could not be completed"), work.message)
        XCTAssertFalse(work.dispatchedEffect, "Dialog inspection is an observation, not a dispatched mutation")
        await runtime.shutdown()
    }

    /// An intervening independent command neither answers nor discards a pending
    /// question: it completes on its own while the question stays bound to its
    /// owner, and the next hold's answer resumes that intent in place — original
    /// request and applied answer keep separate exact provenance.
    func testInterveningCommandLeavesPendingQuestionAnswerableByOwner() async throws {
        let (controller, capture, file, _) = try setup(
            operations: ["clarify", "execute", "execute"], taskScopes: ["launch", "launch", "launch"],
            relationships: ["independent", "independent", "answer"], answerPendingQuestion: true,
            selectedTasks: ["independent", "independent", "independent"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open something", isFinal: true))
        await controller.cua.speech.waitForPending()

        let pending = try XCTUnwrap(controller.cua.dialogue.entries.first {
            if case .awaitingAnswer = $0.status { return true }
            return false
        }, "The ambiguous request must become a pending question")

        capture.emitRevision(.init(start: 1, end: 2, text: " open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let intervening = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(intervening.status, "Completed", intervening.message)
        XCTAssertNotEqual(intervening.intentID, pending.intent.id)
        guard case .awaitingAnswer = controller.cua.dialogue.entry(for: pending.intent.id)?.status else {
            XCTFail("An independent command must not answer or discard the pending question")
            await controller.shutdown()
            return
        }

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let resumed = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(resumed.intentID, pending.intent.id,
            "The answer must resume the question's owner intent, not a new entry")
        XCTAssertEqual(resumed.status, "Completed", resumed.message)
        let owner = try XCTUnwrap(controller.cua.dialogue.entry(for: pending.intent.id))
        XCTAssertEqual(owner.intent.utterance, "open something",
            "The original request keeps its own exact provenance")
        XCTAssertEqual(owner.answers.last?.utterance, "Fixture",
            "The applied answer is stored separately, not synthesized into the request")
        XCTAssertNotEqual(owner.answers.last?.source, owner.intent.source)
        guard case .succeeded = owner.status else {
            XCTFail("The answered intent must finish through its own attempt")
            await controller.shutdown()
            return
        }
        await controller.shutdown()
    }

    /// With several pending questions an answer must name the one it resolves:
    /// only that question's owner resumes while the other question survives.
    func testAnswerBindsNamedQuestionWhileOtherPendingQuestionSurvives() async throws {
        let (controller, capture, file, _) = try setup(
            operations: ["clarify", "clarify", "execute"], taskScopes: ["launch", "launch", "launch"],
            relationships: ["independent", "independent", "answer"], answerPendingQuestion: true,
            selectedTasks: ["independent", "independent", "independent"], pendingQuestionIndex: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open something", isFinal: true))
        await controller.cua.speech.waitForPending()
        capture.emitRevision(.init(start: 1, end: 2, text: " open something else", isFinal: true))
        await controller.cua.speech.waitForPending()

        let awaiting = controller.cua.dialogue.entries.filter {
            if case .awaitingAnswer = $0.status { return true }
            return false
        }
        XCTAssertEqual(awaiting.count, 2, "Two ambiguous requests create two pending questions")
        let target = try XCTUnwrap(awaiting.last)

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "the second one", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let resumed = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(resumed.intentID, target.intent.id,
            "The answer resumes only the owner of the question it names")
        XCTAssertEqual(resumed.status, "Completed", resumed.message)
        guard case .awaitingAnswer = controller.cua.dialogue.entry(for: awaiting[0].intent.id)?.status else {
            XCTFail("The other pending question must remain unanswered")
            await controller.shutdown()
            return
        }
        await controller.shutdown()
    }

    /// Once its question is resolved, a repeated answer cannot resume the intent
    /// again: composition surfaces a task-identification clarification and the
    /// resolved entry keeps its single attempt untouched.
    func testStaleAnswerAfterResolutionClarifiesWithoutResuming() async throws {
        let (controller, capture, file, _) = try setup(
            operations: ["clarify", "execute", "execute"], taskScopes: ["launch", "launch", "launch"],
            relationships: ["independent", "answer", "answer"], answerPendingQuestion: true,
            selectedTasks: ["independent", "independent", "independent"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open something", isFinal: true))
        await controller.cua.speech.waitForPending()
        let pending = try XCTUnwrap(controller.cua.dialogue.entries.first {
            if case .awaitingAnswer = $0.status { return true }
            return false
        })

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        XCTAssertEqual(controller.cuaTasks.first?.status, "Completed")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "Fixture", isFinal: true))
        await controller.cua.speech.waitForPending()

        let owner = try XCTUnwrap(controller.cua.dialogue.entry(for: pending.intent.id))
        guard case .succeeded = owner.status else {
            XCTFail("The resolved intent must remain succeeded")
            await controller.shutdown()
            return
        }
        XCTAssertEqual(owner.attempts.count, 1,
            "A stale answer must never start a second attempt on the resolved intent")
        XCTAssertEqual(controller.cua.speech.outcome, "clarification",
            "The stale answer surfaces a question instead of silently resuming")
        XCTAssertTrue(controller.cuaTasks.allSatisfy { $0.intentID == pending.intent.id })
        await controller.shutdown()
    }

    /// A partially completed attempt keeps its independently observed facts: a
    /// later explicit prerequisite discharges on that evidence instead of
    /// demanding a clean success from the earlier task.
    func testPartialOutcomeRetainsVerifiedFactForPrerequisite() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true, textFixture: true, intentKind: "literal",
            taskScopes: ["work", "launch"], relationships: ["independent", "prerequisite"],
            contentModes: ["literal", "control"], partialAfterSecondNext: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let insertionLog = URL(fileURLWithPath: file.path + ".text")
        defer { try? FileManager.default.removeItem(at: insertionLog) }
        controller.begin(); try await until { controller.status == .listening }
        controller.finish(); capture.emit(.final("type hello"))
        try await until { controller.cuaTasks.first?.active == false }

        let first = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(first.status, "Partial", first.message)
        let firstEntry = try XCTUnwrap(controller.cua.dialogue.entry(for: first.intentID))
        XCTAssertTrue(firstEntry.verifiedFacts.contains {
            $0.kind == .resultObserved && $0.attemptID == first.attemptID && $0.revision == firstEntry.revision
        }, "The verified insertion must stay bound to its producing attempt and revision")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "then switch", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let dependent = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(dependent.status, "Completed",
            "The retained verified fact must discharge the explicit prerequisite: \(dependent.message)")
        XCTAssertEqual(controller.cua.dialogue.entry(for: dependent.intentID)?.prerequisite?.requiresIntentID,
                       first.intentID)
        await controller.shutdown()
    }

    /// A dispatched insertion whose verification dies mid-run is uncertain: an
    /// explicit retry resumes the same intent in place (revision and recorded
    /// facts preserved) and a fresh attempt re-observes before dispatching once.
    func testUncertainInsertionRetriesInPlaceWithFreshAttempt() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true, textFixture: true, intentKind: "literal",
            taskScopes: ["work", "work"], relationships: ["independent", "retry"],
            contentModes: ["literal", "control"], dropAfterTypeOnce: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let insertionLog = URL(fileURLWithPath: file.path + ".text")
        defer { try? FileManager.default.removeItem(at: insertionLog) }
        controller.begin(); try await until { controller.status == .listening }
        controller.finish(); capture.emit(.final("type hello"))
        try await until { controller.cuaTasks.first?.active == false }

        let uncertain = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(uncertain.status, "Uncertain",
            "A driver that drops during insertion verification must surface uncertainty: \(uncertain.message)")
        XCTAssertTrue(uncertain.dispatchedEffect, "The insertion was dispatched before the drop")
        guard case .uncertain = controller.cua.dialogue.entry(for: uncertain.intentID)?.status else {
            XCTFail("The intent must record the uncertain attempt")
            await controller.shutdown()
            return
        }
        let beforeRetry = try String(contentsOf: insertionLog, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(beforeRetry.count, 1,
            "An uncertain insertion is never blindly replayed; only an explicit retry may re-dispatch")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "try that again", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let retry = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(retry.intentID, uncertain.intentID, "Retry resumes the same intent in place")
        XCTAssertNotEqual(retry.attemptID, uncertain.attemptID, "The retry is a fresh attempt")
        XCTAssertEqual(retry.intentRevision, uncertain.intentRevision,
            "retryUncertain preserves the intent revision and its recorded facts")
        XCTAssertEqual(retry.status, "Completed", retry.message)
        let typed = try String(contentsOf: insertionLog, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(typed.count, 2,
            "Each attempt dispatched exactly one insertion after fresh observation")
        let entry = try XCTUnwrap(controller.cua.dialogue.entry(for: uncertain.intentID))
        XCTAssertEqual(entry.attempts.count, 2)
        guard case .uncertain = entry.evidence.first?.outcome else {
            XCTFail("The uncertain attempt must remain as immutable evidence")
            await controller.shutdown()
            return
        }
        await controller.shutdown()
    }

    /// An answer that names the missing detail rather than an app still resumes
    /// its owner: the intent's stored target supplies the app the deciding
    /// utterance did not select, so the question binding is never lost.
    func testAnswerWithoutNamedAppResumesOwnerStoredTarget() async throws {
        let (controller, capture, file, _) = try setup(runningFixture: true,
            taskScopes: ["work", "work"],
            relationships: ["independent", "answer"], answerPendingQuestion: true,
            selectedTasks: ["independent", "independent"], multiWindowedFixture: true,
            appAnswers: ["app_0", "none"], windowAnswers: ["none", "9"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture and type", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let ambiguous = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(ambiguous.status, "Failed")
        let ownerEntry = try XCTUnwrap(controller.cua.dialogue.entry(for: ambiguous.intentID))
        guard case .awaitingAnswer = ownerEntry.status else {
            XCTFail("Execution-stage ambiguity must become a pending question: \(ownerEntry.status)")
            await controller.shutdown()
            return
        }
        XCTAssertEqual(ambiguous.message, "Which window should I use?", ambiguous.message)
        XCTAssertEqual(ownerEntry.intent.target?.bundle?.bundleID, "test.fixture",
            "The question's owner retains the target verified at decision time")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "the front window", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let resumed = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(resumed.intentID, ambiguous.intentID,
            "The answer resumes the question's owner in place, never a new intent")
        XCTAssertEqual(resumed.status, "Completed",
            "The stored target supplies the app the answer did not name: \(resumed.message)")
        let entry = try XCTUnwrap(controller.cua.dialogue.entry(for: ambiguous.intentID))
        XCTAssertEqual(entry.answers.last?.utterance, "the front window")
        await controller.shutdown()
    }

    /// The answer must reach the re-asked execution question: the resumed
    /// attempt's window selection sees the reply in its context, so "the front
    /// window" can steer the fresh binding instead of looping the identical
    /// question. The pending question also retains the candidates it offered.
    func testAnswerReachesReaskedQuestionAndQuestionRetainsCandidates() async throws {
        var windowStates: [JSONValue] = []
        let (controller, capture, file, _) = try setup(runningFixture: true,
            taskScopes: ["work", "work"],
            relationships: ["independent", "answer"], answerPendingQuestion: true,
            selectedTasks: ["independent", "independent"], multiWindowedFixture: true,
            appAnswers: ["app_0", "none"], windowAnswers: ["none", "9"],
            observeJudge: { state, questions in
                if questions["window"] != nil { windowStates.append(state) }
            })
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture and type", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let ambiguous = try XCTUnwrap(controller.cuaTasks.first)
        let entry = try XCTUnwrap(controller.cua.dialogue.entry(for: ambiguous.intentID))
        guard case .awaitingAnswer = entry.status else {
            XCTFail("Execution-stage ambiguity must become a pending question: \(entry.status)")
            await controller.shutdown()
            return
        }
        XCTAssertEqual(entry.question?.options, ["Fixture", "Other Fixture"],
            "The question retains the candidate labels it was asked with")
        XCTAssertEqual(entry.question?.target?.bundle?.bundleID, "test.fixture",
            "The question binds the owner intent's stored target")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "the front window", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        XCTAssertEqual(windowStates.count, 2,
            "The resumed attempt re-asks the window question against fresh observation")
        XCTAssertTrue(windowStates.last?["previous_context"]?.string?.contains("the front window") == true,
            "The answer must reach the re-asked question so it can steer the choice")
        XCTAssertEqual(controller.cuaTasks.last?.intentID, ambiguous.intentID,
            "The answer resumes the question's owner in place")
        await controller.shutdown()
    }

    /// A task that already settled must not be re-cancelled afterward: a
    /// resolved intent is terminal, and rewriting it would bump the revision
    /// that bound its verified facts while flipping the task's honest status
    /// to Cancelled.
    func testResolvedIntentCannotBeRewrittenByTeardownWindowCancel() async throws {
        let (controller, capture, file, _) = try setup()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        let work = try XCTUnwrap(controller.cuaTasks.first)
        guard controller.cua.dialogue.entry(for: work.intentID)?.status.isResolved == true else {
            XCTFail("A completed task must leave a resolved intent")
            return
        }

        let revision = controller.cua.dialogue.entry(for: work.intentID)?.revision
        controller.cua.cancel(work.id)
        controller.stopAll()
        try await until { !work.active }

        let entry = try XCTUnwrap(controller.cua.dialogue.entry(for: work.intentID))
        XCTAssertEqual(entry.revision, revision,
            "A late cancel must not bump a resolved intent's revision")
        XCTAssertFalse(work.stopRequested,
            "A resolved work is not stoppable: its outcome was already recorded")
        XCTAssertEqual(work.status, "Completed", work.message)
        if case .succeeded = entry.status {} else {
            XCTFail("A resolved intent must not be rewritten to cancelled: \(entry.status)")
        }
        await controller.shutdown()
    }

    /// A retry of a resolved non-uncertain intent revises it forward and starts
    /// a fresh attempt on the same entry — the failed attempt's outcome stays
    /// as immutable evidence instead of being replayed or forgotten.
    func testFailedIntentRetriesInPlaceThroughRevise() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true,
            taskScopes: ["create", "launch"], relationships: ["independent", "retry"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "create a document", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let failed = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(failed.status, "Failed", failed.message)

        capture.emitRevision(.init(start: 1, end: 2, text: " try that again", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let retry = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(retry.intentID, failed.intentID, "Retry resumes the same intent, never a new entry")
        XCTAssertNotEqual(retry.attemptID, failed.attemptID, "The retry is a fresh attempt")
        XCTAssertEqual(retry.status, "Failed", retry.message)
        XCTAssertTrue(retry.message.contains("new document window was requested"),
            "The retry re-executes the intent's create scope — a launch-shaped reply must not narrow it into an early success: \(retry.message)")
        XCTAssertGreaterThan(retry.intentRevision, failed.intentRevision,
            "A non-uncertain retry revises the intent forward")
        let entry = try XCTUnwrap(controller.cua.dialogue.entry(for: failed.intentID))
        XCTAssertEqual(entry.attempts.count, 2)
        XCTAssertEqual(entry.evidence.count, 2,
            "The failed attempt's outcome remains as immutable evidence")
        await controller.shutdown()
    }

    /// Cancelling a task whose approval is still pending refuses the dispatch:
    /// the approval resolves negatively and nothing is sent to the driver.
    func testCancelDuringPendingApprovalDispatchesNothing() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true, taskScopes: ["work"], nextCandidateMatch: "Quit")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "quit Fixture", isFinal: true))
        try await until {
            controller.cuaTasks.first?.approval != nil || controller.cuaTasks.first?.active == false
        }

        let work = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertNotNil(work.approval, "The menu action must reach a pending approval before dispatch")
        controller.cua.cancel(work.id)
        try await until { !work.active }

        let calls = (try? String(contentsOf: URL(fileURLWithPath: file.path + ".calls"), encoding: .utf8)) ?? ""
        XCTAssertFalse(calls.split(separator: "\n").contains("invoke_menu"),
            "A cancelled pending approval must not dispatch the menu action")
        XCTAssertEqual(work.status, "Cancelled", work.message)
        await controller.shutdown()
    }

    /// A correction that retracts an awaiting-answer target must actually
    /// withdraw the pending question and resolve the intent — not merely claim
    /// it was cancelled. A later answer then cannot resurrect the retracted
    /// request.
    func testCorrectionWithdrawsPendingQuestionSoAnswerCannotResumeIt() async throws {
        let (controller, capture, file, _) = try setup(runningFixture: true,
            operations: ["execute", "correction", "execute"],
            taskScopes: ["work", "work", "work"],
            correctionModes: ["replace", "retract", "retract"],
            relationships: ["independent", "revision", "answer"],
            answerPendingQuestion: true, multiWindowedFixture: true,
            appAnswers: ["app_0", "none", "none"], windowAnswers: ["none"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture and type", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }

        let ambiguous = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(ambiguous.status, "Failed")
        guard case .awaitingAnswer = controller.cua.dialogue.entry(for: ambiguous.intentID)?.status else {
            XCTFail("Execution-stage ambiguity must leave a pending question")
            await controller.shutdown()
            return
        }

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "actually never mind that", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }

        let correction = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(correction.status, "Completed", correction.message)
        guard case .cancelled = controller.cua.dialogue.entry(for: ambiguous.intentID)?.status else {
            XCTFail("The retracted intent must actually be cancelled, not just reported cancelled")
            await controller.shutdown()
            return
        }
        let questions = controller.cua.context["questions"]?.array ?? []
        XCTAssertTrue(questions.isEmpty,
            "The withdrawn question must no longer be publishable to Jev")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "the front window", isFinal: true))
        await controller.cua.speech.waitForPending()

        guard case .cancelled = controller.cua.dialogue.entry(for: ambiguous.intentID)?.status else {
            XCTFail("A stray answer must not resurrect a retracted intent")
            await controller.shutdown()
            return
        }
        XCTAssertFalse(controller.cuaTasks.contains { $0.intentID == ambiguous.intentID && $0.active },
            "No new attempt may be dispatched for the retracted intent")
        await controller.shutdown()
    }

    /// A failed task from an earlier hold is historical evidence, not the
    /// current interaction's result. A new hold whose outcome produces no new
    /// task record must still present its own state — never the stale failure.
    func testStaleFailedTaskCannotContaminateNewCapture() async throws {
        let (controller, capture, file, _) = try setup(runningFixture: true,
            operations: ["execute", "clarify"], taskScopes: ["create"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "create a document", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        let failed = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(failed.status, "Failed", failed.message)
        let staleReason = failed.message

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "something unclear", isFinal: true))
        try await until { controller.pendingQuestions.isEmpty == false || !controller.cua.speech.busy }

        if case .error(let message) = controller.status {
            XCTFail("A new capture must never inherit the stale failure: \(message)")
        }
        XCTAssertFalse(controller.detail.contains(staleReason),
            "The previous hold's failure text must not surface on the new capture")
        XCTAssertFalse(controller.resultMessage.contains(staleReason))
        XCTAssertEqual(controller.cuaTasks.count, 1,
            "A clarification produces no new task record — and none is needed")
        await controller.shutdown()
    }

    /// Escape cancels only the current interaction's work: an unrelated task
    /// that is still running — even the one selected for inspection — must not
    /// be touched. UI selection grants no cancellation authority.
    func testEscapeCancelsInteractionWorkOnlyAndSelectionGrantsNoAuthority() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true, operations: ["execute", "execute"],
            taskScopes: ["work"], relationships: ["independent", "independent"],
            selectedTasks: ["independent", "independent"], nextCandidateMatch: "Quit")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "quit Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.approval != nil }
        let unrelated = try XCTUnwrap(controller.cuaTasks.first)

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "quit Fixture", isFinal: true))
        // The unrelated task still holds the app lease behind its pending
        // approval, so this attempt starts but cannot reach dispatch — it only
        // needs to be in-flight when Escape lands.
        try await until { controller.cuaTasks.count == 2
            && (controller.cuaTasks.last?.active ?? false) }
        let current = try XCTUnwrap(controller.cuaTasks.last)

        // Selecting the unrelated task for diagnostics must not make it the
        // cancellation target.
        controller.selectTask(unrelated.id)
        controller.cancel()

        try await until { !current.active }
        XCTAssertEqual(current.status, "Cancelled",
            "Escape stops the current interaction's in-flight work")
        XCTAssertTrue(unrelated.active,
            "The diagnostically selected unrelated task is untouched")
        XCTAssertNotNil(unrelated.approval,
            "Its pending approval is still waiting, not resolved by Escape")

        controller.cua.resolveApproval(unrelated.id, approved: false)
        try await until { !unrelated.active }
        await controller.shutdown()
    }

    /// Stop All is the only control that cancels everything: active work and
    /// pending questions alike — the boundary Escape deliberately preserves.
    func testStopAllCancelsActiveWorkAndWithdrawsPendingQuestions() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true, operations: ["execute", "execute"],
            taskScopes: ["work", "work"], relationships: ["independent", "independent"],
            selectedTasks: ["independent", "independent"],
            multiWindowedFixture: true, appAnswers: ["app_0", "app_0"],
            windowAnswers: ["none", "7"], nextCandidateMatch: "Quit")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture and type", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        let questioned = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(controller.pendingQuestions.count, 1,
            "Execution-stage ambiguity leaves a pending question")

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "quit Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 2
            && controller.cuaTasks.last?.approval != nil }
        let active = try XCTUnwrap(controller.cuaTasks.last)

        controller.stopAll()
        try await until { controller.cuaTasks.allSatisfy { !$0.active } }

        XCTAssertEqual(active.status, "Cancelled")
        XCTAssertTrue(controller.pendingQuestions.isEmpty,
            "Stop All withdraws pending questions that Escape preserves")
        guard case .cancelled = controller.cua.dialogue.entry(for: questioned.intentID)?.status
        else {
            XCTFail("Stop All must resolve the awaiting-answer intent")
            await controller.shutdown()
            return
        }
        await controller.shutdown()
    }

    /// The explicit retry affordance routes through the normal decision
    /// pipeline — the dialogue resumes the intent in place with a fresh
    /// attempt that re-executes the recorded payload — and task diagnostics
    /// expose identity/certainty without ever dumping the literal payload.
    func testExplicitRetryRoutesThroughPolicyAndDiagnosticsStayContentMinimized() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true, textFixture: true, intentKind: "literal",
            taskScopes: ["work"], relationships: ["independent", "retry"],
            contentModes: ["literal", "control"], dropAfterTypeOnce: true)
        defer { try? FileManager.default.removeItem(at: file) }
        let insertionLog = URL(fileURLWithPath: file.path + ".text")
        defer { try? FileManager.default.removeItem(at: insertionLog) }
        controller.begin(); try await until { controller.status == .listening }
        controller.finish(); capture.emit(.final("type hello"))
        try await until { controller.cuaTasks.first?.active == false }
        let uncertain = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(uncertain.status, "Uncertain", uncertain.message)

        // Diagnostics: intent/attempt identity + content-minimized certainty,
        // never the literal payload itself.
        let diagnostics = controller.taskDiagnostics(uncertain).joined(separator: "\n")
        XCTAssertTrue(diagnostics.contains("intent ") && diagnostics.contains("attempt "))
        XCTAssertTrue(diagnostics.contains("outcome uncertain"))
        XCTAssertTrue(diagnostics.contains("insert text (5 chars)"))
        XCTAssertFalse(diagnostics.contains("hello"),
            "A literal payload must render as a character count, not its text")

        XCTAssertTrue(controller.canRetryTask(uncertain.id),
            "An uncertain intent is retryable")
        XCTAssertFalse(controller.canRetryTask(UUID()),
            "An unknown task id is never retryable")

        // The affordance goes through decide/planRouting: the default task
        // selection binds the only published intent.
        controller.retryTask(uncertain.id)
        try await until { controller.cuaTasks.count == 2
            && controller.cuaTasks.allSatisfy { !$0.active } }

        let retry = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(retry.intentID, uncertain.intentID, "Retry resumes the intent in place")
        XCTAssertNotEqual(retry.attemptID, uncertain.attemptID, "A fresh attempt is created")
        XCTAssertEqual(retry.status, "Completed", retry.message)
        let typed = try String(contentsOf: insertionLog, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(typed.count, 2, "Original dispatch plus one retry dispatch")
        let entry = try XCTUnwrap(controller.cua.dialogue.entry(for: uncertain.intentID))
        XCTAssertEqual(entry.attempts.count, 2)
        await controller.shutdown()
    }

    /// A repeated request is a new intent — never an in-place resume — while an
    /// explicit retry relationship resumes the referenced intent in place:
    /// same intent id, a fresh attempt, and no additional intent entry.
    func testIntentionalRepeatCreatesNewIntentWhileRetryResumesInPlace() async throws {
        let (controller, capture, file, _) = try setup(runningFixture: true,
            taskScopes: ["launch", "launch", "launch"],
            relationships: ["independent", "continuation", "retry"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        let original = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(original.status, "Completed", original.message)

        capture.emitRevision(.init(start: 1, end: 2, text: " open Fixture", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }
        let repeated = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertNotEqual(repeated.intentID, original.intentID,
            "Saying the same request again is a distinct intent, not a retry")
        XCTAssertNotEqual(repeated.attemptID, original.attemptID)
        XCTAssertEqual(repeated.status, "Completed", repeated.message)
        XCTAssertEqual(controller.cua.dialogue.entries.count, 2)

        capture.emitRevision(.init(start: 2, end: 3, text: " try that again", isFinal: true))
        try await until { controller.cuaTasks.count == 3 && controller.cuaTasks.allSatisfy { !$0.active } }
        let retry = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(retry.intentID, original.intentID,
            "An explicit retry resumes the referenced intent in place")
        XCTAssertNotEqual(retry.attemptID, original.attemptID,
            "The retry records a fresh attempt on the same intent")
        XCTAssertEqual(retry.status, "Completed", retry.message)
        XCTAssertEqual(controller.cua.dialogue.entries.count, 2,
            "A retry relationship must never add an intent entry")
        XCTAssertEqual(controller.cua.dialogue.entry(for: original.intentID)?.attempts.count, 2)
        XCTAssertEqual(controller.cua.dialogue.entry(for: repeated.intentID)?.attempts.count, 1)
        await controller.shutdown()
    }

    /// An approval parked on a worker holds no veto over later input: when the
    /// user corrects the request mid-approval, the worker's lease unwinds and a
    /// stale approval resolution afterwards cannot dispatch the guarded action.
    func testStaleApprovalAfterRevisionCannotDispatch() async throws {
        let (controller, capture, file, _) = try setup(windowedFixture: true,
            runningFixture: true,
            operations: ["execute", "correction"],
            taskScopes: ["work", "work"],
            correctionModes: ["retract", "retract"],
            relationships: ["independent", "revision"],
            nextCandidateMatch: "Quit")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "quit Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.approval != nil }

        // The correction supersedes the intent whose approval is still open:
        // cancel resolves the pending approval negatively and unwinds the run.
        capture.emitRevision(.init(start: 1, end: 2, text: " actually cancel that", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }
        let cancelled = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(cancelled.status, "Cancelled", cancelled.message)
        XCTAssertNil(cancelled.approval)
        guard case .cancelled = controller.cua.dialogue.entry(for: cancelled.intentID)?.status else {
            XCTFail("The revised intent must be cancelled in dialogue state")
            await controller.shutdown()
            return
        }
        XCTAssertEqual(controller.cuaTasks.last?.status, "Completed",
            "The retracting correction completes once the target unwinds")

        // A stale approval for the superseded revision arrives after the fact.
        controller.cua.resolveApproval(cancelled.id, approved: true)
        let calls = (try? String(contentsOf: URL(fileURLWithPath: file.path + ".calls"),
            encoding: .utf8)) ?? ""
        XCTAssertFalse(calls.split(separator: "\n").contains("invoke_menu"),
            "A stale approval must never dispatch the guarded menu action")
        XCTAssertFalse(cancelled.dispatchedEffect)
        await controller.shutdown()
    }

    /// An intent still referenced by an unresolved intent is retained beyond
    /// twelve newer records: resolved-history trimming under capacity pressure
    /// evicts only unreferenced resolved entries, the published task context
    /// keeps the referenced intent, and the pending question still answers.
    func testReferencedIntentSurvivesBeyondTwelveNewerRecords() async throws {
        let repeats = 12
        let (controller, capture, file, _) = try setup(runningFixture: true,
            taskScopes: ["launch", "work"] + Array(repeating: "launch", count: repeats + 1),
            relationships: ["independent", "continuation"]
                + Array(repeating: "continuation", count: repeats) + ["answer"],
            answerPendingQuestion: true, resolvedHistoryLimit: 5,
            multiWindowedFixture: true, windowAnswers: ["none", "7"])
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
        try await until { controller.cuaTasks.first?.active == false }
        let anchor = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(anchor.status, "Completed", anchor.message)

        // The follow-up references the first intent, then stalls on window
        // ambiguity: its unresolved entry anchors the reference chain.
        capture.emitRevision(.init(start: 1, end: 2, text: " open it and type", isFinal: true))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { !$0.active } }
        let questioned = try XCTUnwrap(controller.cuaTasks.last)
        guard case .continuation(let parent) = controller.cua.dialogue.entry(for: questioned.intentID)?.relationship,
              parent == anchor.intentID,
              case .awaitingAnswer = controller.cua.dialogue.entry(for: questioned.intentID)?.status else {
            XCTFail("The ambiguous follow-up must stay an unresolved continuation of the first intent")
            await controller.shutdown()
            return
        }

        // More than twelve newer resolved records follow while the question
        // stays pending — the range the old context window would have dropped.
        for index in 0..<repeats {
            capture.emitRevision(.init(start: Double(index + 2), end: Double(index + 3), text: " open Fixture", isFinal: true))
            try await until { controller.cuaTasks.count == 3 + index
                && controller.cuaTasks.allSatisfy { !$0.active } }
        }

        XCTAssertNotNil(controller.cua.dialogue.entry(for: anchor.intentID),
            "An intent still referenced by an unresolved intent survives resolved-history trimming")
        XCTAssertNil(controller.cua.dialogue.entry(for: controller.cuaTasks[2].intentID),
            "Unreferenced resolved history must actually trim for this test to prove retention")
        let publishedIDs = controller.cua.context["tasks"]?.array?
            .compactMap { $0["id"]?.string } ?? []
        XCTAssertTrue(publishedIDs.contains(anchor.intentID.uuidString),
            "The published task context retains the referenced intent beyond twelve newer records")
        XCTAssertEqual(controller.cua.context["questions"]?.array?.count, 1)

        controller.cancelCaptureAttempt(); try await until { controller.canBegin }
        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "the front window", isFinal: true))
        try await until { controller.cuaTasks.count == 3 + repeats
            && controller.cuaTasks.allSatisfy { !$0.active } }
        let resumed = try XCTUnwrap(controller.cuaTasks.last)
        XCTAssertEqual(resumed.intentID, questioned.intentID,
            "The retained question still resolves its owner after the reference window passed")
        XCTAssertEqual(resumed.status, "Completed", resumed.message)
        await controller.shutdown()
    }

    /// A fresh runtime owns an empty dialogue: pending questions, intents and
    /// published task context do not survive an app restart, and a stray answer
    /// cannot resume an intent the restarted process never owned.
    func testAppRestartClearsDialogueAndPendingQuestions() async throws {
        var oldIntentID: UUID?
        do {
            let (controller, capture, file, _) = try setup(operations: ["clarify"])
            defer { try? FileManager.default.removeItem(at: file) }
            controller.begin(); try await until { controller.status == .listening }
            capture.emitRevision(.init(start: 0, end: 1, text: "open something", isFinal: true))
            await controller.cua.speech.waitForPending()
            let pending = try XCTUnwrap(controller.cua.dialogue.entries.first {
                if case .awaitingAnswer = $0.status { return true }
                return false
            })
            oldIntentID = pending.intent.id
            await controller.shutdown()
        }

        let (controller, capture, file, _) = try setup(operations: ["execute"],
            relationships: ["answer"], answerPendingQuestion: true)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(controller.cua.dialogue.entries.isEmpty,
            "A restarted app must not inherit the previous dialogue")
        XCTAssertTrue(controller.pendingQuestions.isEmpty)
        XCTAssertEqual(controller.cua.context["questions"]?.array?.count, 0)
        XCTAssertEqual(controller.cua.context["tasks"]?.array?.count, 0)

        controller.begin(); try await until { controller.status == .listening }
        capture.emitRevision(.init(start: 0, end: 1, text: "the front window", isFinal: true))
        await controller.cua.speech.waitForPending()

        XCTAssertEqual(controller.cua.speech.outcome, "clarification")
        XCTAssertFalse(controller.cua.dialogue.entries.contains { $0.intent.id == oldIntentID },
            "The restarted dialogue contains only intents this process owns")
        XCTAssertFalse(controller.cuaTasks.contains { $0.intentID == oldIntentID },
            "No work may be resumed for an intent from before the restart")
        await controller.shutdown()
    }

    // MARK: - Typed commands

    /// The settings-page command box is the same voice→Cua pipeline minus the
    /// microphone: a typed string is a final transcript — same decide/execute/
    /// verify route, no capture ever starts.
    func testTypedCommandExecutesWithoutMicrophone() async throws {
        // windowedFixture: an "open" request verifies a real window in front;
        // a windowless stub would stall the launch-window wait for seconds.
        let (controller, capture, file, _) = try setup(windowedFixture: true)
        defer { try? FileManager.default.removeItem(at: file) }

        controller.submitTypedCommand("open Fixture")
        try await until { controller.cuaTasks.first?.status == "Completed" }

        XCTAssertNil(capture.id, "A typed command must never start the microphone")
        XCTAssertEqual(controller.transcript, "open Fixture")
        let calls = try String(contentsOf: URL(fileURLWithPath: file.path + ".calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertTrue(calls.contains("start_session"))
        XCTAssertTrue(calls.contains("launch_app"))
        XCTAssertTrue(calls.contains("bring_to_front"))
        await controller.shutdown()
    }

    func testTypedCommandRejectsEmptyInput() async throws {
        let (controller, _, file, _) = try setup()
        defer { try? FileManager.default.removeItem(at: file) }

        controller.submitTypedCommand("   ")
        controller.submitTypedCommand("")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(controller.cuaTasks.isEmpty, "Whitespace is not a command")
        XCTAssertTrue(controller.status == .idle || controller.status == .done,
            "An empty typed command must not occupy the controller: \(controller.status)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".calls"),
            "An empty command must never reach the driver")
        await controller.shutdown()
    }

    /// With auto-confirm off, a typed command still obeys the same manual gate
    /// a finished capture would — nothing dispatches before Run.
    func testTypedCommandRespectsManualConfirmation() async throws {
        let (controller, _, file, _) = try setup(automatic: false, windowedFixture: true)
        defer { try? FileManager.default.removeItem(at: file) }

        controller.submitTypedCommand("open Fixture")
        try await until { controller.status == .awaitingConfirm }
        XCTAssertTrue(controller.cuaTasks.isEmpty, "Nothing may dispatch before confirmation")

        controller.confirm()
        try await until { controller.cuaTasks.first?.status == "Completed" }
        await controller.shutdown()
    }

    /// Regression: the driver keys protected-resource grants to (session,
    /// transport, resource). Two commands must share one session/transport —
    /// a per-task session re-ran the browser's visible consent setup every time.
    func testSequentialTypedCommandsShareOneDriverSession() async throws {
        let (controller, _, file, _) = try setup(windowedFixture: true)
        defer { try? FileManager.default.removeItem(at: file) }

        controller.submitTypedCommand("open Fixture")
        try await until { controller.cuaTasks.first?.status == "Completed" }
        controller.submitTypedCommand("open Fixture")
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks.allSatisfy { $0.status == "Completed" } }
        await controller.shutdown()

        let calls = try String(contentsOf: URL(fileURLWithPath: file.path + ".calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(calls.filter { $0 == "start_session" }.count, 1,
            "Two commands must ride one driver session, not two")
        XCTAssertEqual(calls.filter { $0 == "set_agent_cursor_enabled" }.count, 1,
            "The cursor policy is applied once when the session opens")
        XCTAssertEqual(calls.filter { $0 == "end_session" }.count, 1,
            "The shared session ends once at shutdown, not per task")
    }

    /// The session bootstrap races a worker path (applyCorrection) and the
    /// next receive — the cursor configuration is sent once for the run.
    func testCursorSettingPropagatesToSessionStart() async throws {
        let (controller, _, file, _) = try setup(windowedFixture: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + ".cursor"))
        }
        controller.config.agentCursorEnabled = true

        controller.submitTypedCommand("open Fixture")
        try await until { controller.cuaTasks.first?.status == "Completed" }
        await controller.shutdown()

        let raw = try String(contentsOf: URL(fileURLWithPath: file.path + ".calls"), encoding: .utf8)
        XCTAssertTrue(raw.contains("set_agent_cursor_enabled"),
            "Session start must configure the driver-side cursor mode")
        let cursor = try String(contentsOf: URL(fileURLWithPath: file.path + ".cursor"), encoding: .utf8)
        XCTAssertEqual(cursor.trimmingCharacters(in: .whitespacesAndNewlines), "True",
            "The enabled setting must reach the driver verbatim")
    }

    /// Default is silent direct dispatch: `enabled` reaches the driver false.
    func testCursorDisabledByDefaultReachesDriver() async throws {
        let (controller, _, file, _) = try setup(windowedFixture: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + ".cursor"))
        }

        controller.submitTypedCommand("open Fixture")
        try await until { controller.cuaTasks.first?.status == "Completed" }
        await controller.shutdown()

        let cursor = try String(contentsOf: URL(fileURLWithPath: file.path + ".cursor"), encoding: .utf8)
        XCTAssertEqual(cursor.trimmingCharacters(in: .whitespacesAndNewlines), "False",
            "Default dispatch must report cursor disabled to the driver")
    }
}
