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
    private func setup(automatic: Bool = true, delayedIntent: Bool = false, intentKind: String = "command", laterFailure: String? = nil) throws -> (VoiceController, Capture, URL, UserDefaults) {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-pipeline-\(UUID()).py")
        try #"""
import json,sys
running=False
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='initialize': out={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
 else:
  name=r['params']['name']
  if name in ('list_apps','get_accessibility_tree'): value={'apps':[{'name':'Fixture','bundle_id':'test.fixture','running':running,'pid':42 if running else 0}]}
  elif name=='launch_app': running=True; value={'pid':42}
  elif name=='list_windows': value={'windows':[]}
  elif name in ('start_session','end_session'): value={'active':name=='start_session'}
  else: raise RuntimeError('Unexpected fixture tool '+name)
  out={'structuredContent':value}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':out}),flush=True)
"""#.write(to: fixture, atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "CuaVoiceControllerTests-\(UUID())")!
        let config = Config(defaults: defaults, keyStore: Keys(), environment: [:])
        config.autoExecute = automatic
        var intentCalls = 0
        let runtime = CuaVoiceRuntime(config: config, makeConnection: { CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.path]) }, judge: { state, questions in
            if questions["boundary"] != nil {
                intentCalls += 1
                if intentCalls > 1, laterFailure == "service" { throw URLError(.notConnectedToInternet) }
            }
            if delayedIntent, questions["boundary"] != nil { try? await Task.sleep(for: .milliseconds(80)) }
            var answers: [String: Answer] = [:]
            for key in questions.keys {
                let value: String
                switch key {
                case "boundary": value = intentCalls > 1 && laterFailure == "incomplete" ? "missingQuery" : String(state["pending_speech"]!.string!.split(separator: " ").count)
                case "extent": value = "refine"
                case "completeness": value = "complete"
                case "polarity": value = "notProhibited"
                case "purpose": value = "request"
                case "mode": value = ["dictate", "textEntry"].contains(intentKind) ? intentKind : "control"
                case "kind": value = intentKind
                case "start": value = "1"
                case "end": value = String(state["words"]!.array!.count - 1)
                case "route":
                    XCTAssertGreaterThan(state["context"]?["tasks"]?.array?.count ?? 0, 1, "No routing judgment is needed without a prior task")
                    if intentKind == "dictate" { XCTAssertFalse(state["request"]?.string?.contains("open Notes") == true) }
                    value = "independent"
                case "app":
                    if laterFailure != nil { try await Task.sleep(for: .seconds(30)) }
                    value = "app_0"
                case "visibility": value = "background"
                case "scope": value = "launch"
                case "next": value = "done"
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
    func testInterpretationFailureDoesNotCancelSelectedWork() async throws {
        for failure in ["service", "incomplete"] {
            let (controller, capture, file, _) = try setup(laterFailure: failure)
            defer { try? FileManager.default.removeItem(at: file) }
            controller.begin(); try await until { controller.status == .listening }
            capture.emitRevision(.init(start: 0, end: 1, text: "open Fixture", isFinal: true))
            try await until { controller.cuaTasks.first?.active == true }
            controller.finish(); capture.emit(.final("open Fixture search for"))
            await controller.cua.speech.waitForPending()
            let work = try XCTUnwrap(controller.cuaTasks.first)
            XCTAssertTrue(work.active)
            XCTAssertNotEqual(work.status, "Stopping")
            XCTAssertNotEqual(work.status, "Cancelled")
            XCTAssertEqual(controller.cua.speech.remainder, "search for")
            await controller.shutdown()
        }
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
    func testDiagnosticsFollowSelectedTaskWithoutMixingCaptureTimings() async throws {
        let (controller, capture, file, _) = try setup()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emit(.partial("open Fixture"))
        try await until { controller.cuaTasks.count == 1 && controller.cuaTasks[0].status == "Completed" }
        let first = controller.cuaTasks[0]
        capture.emit(.partial("open Fixture open Fixture"))
        try await until { controller.cuaTasks.count == 2 && controller.cuaTasks[1].status == "Completed" }
        let second = controller.cuaTasks[1]
        XCTAssertEqual(controller.diagnosticTask?.id, second.id)
        controller.selectTask(first.id)
        XCTAssertEqual(controller.diagnosticTask?.id, first.id)
        XCTAssertNil(controller.measurements["Transcript to first dispatch"])
        XCTAssertNil(controller.measurements["Task elapsed"])
        XCTAssertNotNil(controller.measurements["Microphone ready"])
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

    func testCorrectionBeforeDispatchCancelsThenRunsReplacement() async throws {
        try await verifyCorrectionBeforeDispatch(literal: false)
    }

    func testLiteralCorrectionCannotLaunchAnAppNamedInsideReplacement() async throws {
        try await verifyCorrectionBeforeDispatch(literal: true)
    }

    private func verifyCorrectionBeforeDispatch(literal: Bool) async throws {
        let (_, _, fixture, _) = try setup()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let config = Config(defaults: UserDefaults(suiteName: "CuaCorrection-\(UUID())")!, keyStore: Keys(), environment: [:])
        var firstAppDecision = true
        var waiting = false
        var targetID: UUID?
        let runtime = CuaVoiceRuntime(config: config, makeConnection: {
            CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.path])
        }, judge: { state, questions in
            var answers: [String: Answer] = [:]
            for key in questions.keys {
                let value: String
                switch key {
                case "extent": value = "refine"
                case "completeness": value = "complete"
                case "polarity": value = "notProhibited"
                case "purpose": value = "request"
                case "mode": value = literal && state["pending_speech"]?.string?.hasPrefix("actually") == true ? "dictate" : "control"
                case "kind": value = state["pending_speech"]?.string?.hasPrefix("actually") == true ? "correction" : "command"
                case "boundary": value = String(state["pending_speech"]!.string!.split(separator: " ").count)
                case "route": value = state["request"]?.string?.hasPrefix("actually") == true ? targetID!.uuidString : "independent"
                case "app":
                    if firstAppDecision {
                        firstAppDecision = false; waiting = true
                        try await Task.sleep(for: .seconds(30))
                    }
                    value = "app_0"
                case "visibility": value = "background"
                case "scope": value = "launch"
                case "replacement": value = "replace"
                case "start": value = "1"
                case "end": value = literal ? "6" : "2"
                default: throw DriverConnectionError.malformed
                }
                answers[key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
            }
            return answers
        })
        runtime.begin(app: "Fixture")
        runtime.update("open Fixture", final: true)
        try await until { waiting }
        targetID = try XCTUnwrap(runtime.tasks.first?.id)
        runtime.begin(app: "Fixture")
        runtime.update(literal ? "actually dictate open Notes and stop all instead" : "actually open Fixture instead", final: true)
        try await until { runtime.tasks.count == 2 && runtime.tasks.allSatisfy { !$0.active } }
        XCTAssertEqual(runtime.tasks[0].status, "Cancelled")
        XCTAssertFalse(runtime.tasks[0].dispatchedEffect)
        if literal {
            XCTAssertEqual(runtime.tasks[1].status, "Failed")
            XCTAssertTrue(runtime.tasks[1].message.contains("No app was launched"), runtime.tasks[1].message)
            XCTAssertFalse(runtime.tasks[1].dispatchedEffect)
        } else {
            XCTAssertEqual(runtime.tasks[1].status, "Completed", runtime.tasks[1].message)
            XCTAssertTrue(runtime.tasks[1].dispatchedEffect)
        }
        await runtime.shutdown()
    }

}
