import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaVoiceControllerTests: XCTestCase {
    private final class Capture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var id: UUID?
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String { id = session; return "Fixture microphone" }
        func finish() {}
        func cancel() {}
        func emit(_ event: SpeechEvent) { if let id { onEvent?(id, event) } }
    }
    private struct Keys: APIKeyStore {
        func read() throws -> String? { "fixture-key" }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }
    private func setup(automatic: Bool = true, delayedIntent: Bool = false, intentKind: String = "command") throws -> (VoiceController, Capture, URL, UserDefaults) {
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
        let runtime = CuaVoiceRuntime(config: config, makeConnection: { CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.path]) }, judge: { state, questions in
            if delayedIntent, questions["boundary"] != nil { try? await Task.sleep(for: .milliseconds(80)) }
            var answers: [String: Answer] = [:]
            for key in questions.keys {
                let value: String
                switch key {
                case "boundary": value = String(state["pending_speech"]!.string!.split(separator: " ").count)
                case "kind": value = intentKind
                case "start": value = "1"
                case "end": value = String(state["words"]!.array!.count)
                case "route":
                    XCTAssertGreaterThan(state["context"]?["tasks"]?.array?.count ?? 0, 1, "No routing judgment is needed without a prior task")
                    if intentKind == "dictate" { XCTAssertFalse(state["request"]?.string?.contains("open Notes") == true) }
                    value = "independent"
                case "app": value = "app_0"
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
    func testProductionPathActsBeforeReleaseAndDoesNotRepeatFinal() async throws {
        let (controller, capture, file, _) = try setup()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin()
        try await until { controller.status == .listening }
        capture.emit(.revision(SpeechRevision(start: 0, end: 1, text: "open Fixture", isFinal: false), transcript: "open Fixture"))
        try await until { controller.cuaTasks.first?.status == "Completed" }
        XCTAssertEqual(controller.status, .listening)
        XCTAssertEqual(controller.cuaTasks.count, 1)
        let provenance = try XCTUnwrap(controller.cuaTasks.first?.provenance)
        XCTAssertEqual(provenance.audioRanges.first?.start, 0)
        XCTAssertEqual(provenance.audioRanges.first?.end, 1)
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

    func testAmbiguousUnquotedTextEntryIsRefusedBeforeCuaExecution() async throws {
        let (controller, capture, file, _) = try setup(intentKind: "textEntry")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.begin(); try await until { controller.status == .listening }
        capture.emit(.partial("Type Open Messages into Notes"))
        controller.finish(); capture.emit(.final("Type Open Messages into Notes"))
        try await until { controller.cuaTasks.first?.active == false }
        let work = try XCTUnwrap(controller.cuaTasks.first)
        XCTAssertEqual(work.status, "Failed")
        XCTAssertTrue(work.message.contains("quoted span"))
        XCTAssertFalse(work.dispatchedEffect)
        await controller.shutdown()
    }

    func testCorrectionBeforeDispatchCancelsThenRunsReplacement() async throws {
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
                case "end": value = "3"
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
        runtime.update("actually open Fixture instead", final: true)
        try await until { runtime.tasks.count == 2 && runtime.tasks.allSatisfy { !$0.active } }
        XCTAssertEqual(runtime.tasks[0].status, "Cancelled")
        XCTAssertFalse(runtime.tasks[0].dispatchedEffect)
        XCTAssertEqual(runtime.tasks[1].status, "Completed", runtime.tasks[1].message)
        XCTAssertTrue(runtime.tasks[1].dispatchedEffect)
        await runtime.shutdown()
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
                case "boundary": value = String(state["pending_speech"]!.string!.split(separator: " ").count)
                case "kind": value = "command"
                case "app": value = "app_0"
                case "scope": value = "work"
                case "visibility": value = "background"
                case "next": value = "blocked"
                default: throw DriverConnectionError.malformed
                }
                answers[key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
            }
            return answers
        })

        runtime.begin(app: "Google Chrome")
        runtime.update("Inspect the current browser page", final: true)
        try await until { runtime.tasks.first?.active == false }

        let work = try XCTUnwrap(runtime.tasks.first)
        XCTAssertEqual(work.status, "Failed")
        XCTAssertTrue(work.message.contains("safe next action"), work.message)
        XCTAssertFalse(work.dispatchedEffect, "Dialog inspection is an observation, not a dispatched mutation")
        await runtime.shutdown()
    }

}
