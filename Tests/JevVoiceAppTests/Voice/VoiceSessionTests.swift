import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
private final class FakeSpeech: SpeechCapturing {
    var onEvent: ((UUID, SpeechEvent) -> Void)?
    var sessions: [UUID] = []
    var finishes = 0
    var preparationGate: CheckedContinuation<Void, Never>?
    var delayPreparation = false
    var suspendReleasesPreparation = false
    var suspended = false
    func prepare(inputUID: String?) async throws -> String {
        if delayPreparation { await withCheckedContinuation { preparationGate = $0 } }
        try Task.checkCancellation()
        return "Test microphone"
    }
    func suspend() async {
        suspended = true
        if suspendReleasesPreparation {
            let gate = preparationGate
            preparationGate = nil
            gate?.resume()
        }
    }
    var startGate: CheckedContinuation<Void, Never>?
    var delayStart = false
    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
        sessions.append(session)
        if delayStart { await withCheckedContinuation { startGate = $0 } }
        try Task.checkCancellation()
        return "Test microphone"
    }
    func finish() { finishes += 1 }
    func cancel() {}
    func emit(_ event: SpeechEvent, session: UUID? = nil) { onEvent?(session ?? sessions.last!, event) }
}

/// Capture and the Cua transport are injected; the executor judge returns ignore
/// outcomes so these lifecycle tests cannot dispatch a desktop action.
@MainActor
final class VoiceSessionTests: XCTestCase {
    private func controller(_ speech: FakeSpeech, manual: Bool = false,
                            timings: VoiceTimings = VoiceTimings(),
                            judged: @escaping (String) -> Void = { _ in }) -> VoiceController {
        let config = Config(defaults: UserDefaults(suiteName: "test.voice.\(UUID())")!,
                            keyStore: MemoryKeyStore(), environment: [:])
        config.autoExecute = !manual
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("voice-session-\(UUID()).py")
        try! #"""
import json,sys
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if r['method']=='initialize': out={'protocolVersion':'2025-03-26','capabilities':{'tools':{}}}
 else:
  name=r['params']['name']
  if name=='list_apps': value={'apps':[]}
  elif name in ('start_session','end_session'): value={'active':name=='start_session'}
  else: raise RuntimeError('Unexpected fixture tool '+name)
  out={'structuredContent':value}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':out}),flush=True)
"""#.write(to: fixture, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let runtime = CuaVoiceRuntime(config: config,
            makeConnection: { CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", fixture.path]) },
            judge: { state, questions in
                if questions["operation"] != nil { judged(state["transcript"]?.string ?? "") }
                return questions.reduce(into: [:]) { result, item in
                    let value: String
                    switch item.key {
                    case "operation": value = "ignore"
                    case "span": value = String(state["pending_word_range"]?["end"]?.integer ?? 0)
                    case "task": value = "independent"
                    case "app": value = "none"
                    case "scope": value = "work"
                    case "visibility": value = "background"
                    case "contentMode": value = "control"
                    case "literalStart", "literalEnd": value = "none"
                    case "correctionMode": value = "retract"
                    case "replacementStart", "replacementEnd": value = "none"
                    case "clarification": value = "none"
                    default: fatalError("Unexpected executor question: \(item.key)")
                    }
                    result[item.key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
                }
            })
        return VoiceController(config: config, speech: speech, authorize: { true },
                               timings: timings, frontmost: { "Fixture" }, cuaRuntime: runtime)
    }
    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    func testSuspensionDoesNotWaitForPreparationToFinish() async {
        let speech = FakeSpeech(); speech.delayPreparation = true
        let c = controller(speech)
        c.prepareMicrophone(); await settle()
        XCTAssertNotNil(speech.preparationGate)
        c.suspendMicrophone("Sleep"); await settle()
        XCTAssertTrue(speech.suspended)
        XCTAssertFalse(c.canBegin)
        speech.preparationGate?.resume(); await settle()
        await c.shutdown()
    }
    func testShutdownSuspendsBeforeWaitingForPreparationToFinish() async {
        let speech = FakeSpeech()
        speech.delayPreparation = true
        speech.suspendReleasesPreparation = true
        let c = controller(speech)
        c.prepareMicrophone()
        await settle()
        XCTAssertNotNil(speech.preparationGate)

        let shutdown = Task { await c.shutdown() }
        await settle()
        XCTAssertTrue(speech.suspended, "Shutdown must stop the speech pipeline before awaiting preparation")

        if let gate = speech.preparationGate {
            speech.preparationGate = nil
            gate.resume()
        }
        await shutdown.value
    }
    func testSuspensionInterruptsFinalizationAndRejectsLateFinal() async {
        let speech = FakeSpeech(); var calls = 0
        let c = controller(speech, manual: true, judged: { _ in calls += 1 })
        c.begin(); await settle(); speech.emit(.partial("captured phrase")); c.finish()
        XCTAssertEqual(c.status, .finishing)
        c.suspendMicrophone("Sleep"); await settle()
        speech.emit(.final("late final")); await settle()
        XCTAssertEqual(c.status, .error("Sleep"))
        XCTAssertEqual(calls, 0); XCTAssertFalse(c.canBegin)
        await c.shutdown()
    }
    func testSpeechStageTimingRejectsStaleAndInvalidEvents() async {
        let speech = FakeSpeech()
        let current = controller(speech)
        current.begin(); await settle()
        speech.emit(.timing("Audio engine start", milliseconds: 42))
        speech.emit(.timing("Audio engine start", milliseconds: 500), session: UUID())
        speech.emit(.timing("Audio engine start", milliseconds: .nan))
        XCTAssertEqual(current.measurements["Audio engine start"], 42)
        await current.shutdown()
    }
    func testReleaseBeforeCaptureStartsCancelsWithoutLateListening() async {
        let speech = FakeSpeech(); speech.delayStart = true
        var calls = 0
        let c = controller(speech, judged: { _ in calls += 1 })
        c.begin(); await settle(); XCTAssertEqual(c.status, .starting)
        c.finish(); speech.startGate?.resume(); await settle()
        XCTAssertEqual(c.status, .idle); XCTAssertEqual(calls, 0)
        await c.shutdown()
    }
    func testInterruptionDuringStartupKeepsErrorAfterCleanup() async {
        let speech = FakeSpeech(); speech.delayStart = true
        let c = controller(speech)
        c.begin(); await settle(); c.interruptCapture("Keyboard interrupted")
        XCTAssertFalse(c.canBegin)
        speech.startGate?.resume(); await settle()
        XCTAssertEqual(c.status, .error("Keyboard interrupted")); XCTAssertTrue(c.canBegin)
        await c.shutdown()
    }
    func testFinalAfterReleaseSubmitsOnceAndIgnoresLateCallbacks() async {
        let speech = FakeSpeech(); var received: [String] = []
        let c = controller(speech, judged: { received.append($0) })
        c.begin(); await settle(); c.finish()
        XCTAssertEqual(speech.finishes, 1)
        speech.emit(.final("a conversation")); speech.emit(.final("duplicate"))
        await c.cua.speech.waitForPending()
        XCTAssertEqual(received, ["a conversation"]); XCTAssertEqual(c.status, .done)
        await c.shutdown()
    }
    func testEarlyFinalRequiresReleaseAndExplicitTranscriptReview() async {
        let speech = FakeSpeech(); var received: [String] = []
        let c = controller(speech, judged: { received.append($0) })
        c.begin(); await settle(); speech.emit(.final("a conversation"))
        XCTAssertEqual(c.status, .awaitingRelease)
        c.finish(); XCTAssertEqual(c.status, .reviewTranscript); XCTAssertTrue(received.isEmpty)
        c.acceptTranscript(); c.acceptTranscript()
        await c.cua.speech.waitForPending()
        XCTAssertEqual(received, ["a conversation"]); XCTAssertEqual(c.status, .done)
        await c.shutdown()
    }
    func testManualReviewConfirmsOnlyOnceAndDoesNotInterpretPartials() async {
        let speech = FakeSpeech(); var received: [String] = []
        let c = controller(speech, manual: true, judged: { received.append($0) })
        c.begin(); await settle(); speech.emit(.partial("a conversation")); await settle()
        c.finish(); speech.emit(.final("a conversation")); await settle()
        XCTAssertTrue(received.isEmpty); XCTAssertEqual(c.status, .awaitingConfirm)
        c.confirm(); c.confirm()
        await c.cua.speech.waitForPending()
        XCTAssertEqual(received, ["a conversation"])
        await c.shutdown()
    }
    func testTimeoutReviewsPartialAndRejectsLateFinal() async throws {
        let speech = FakeSpeech()
        let c = controller(speech, manual: true, timings: VoiceTimings(finalization: 0.01))
        c.begin(); await settle(); speech.emit(.partial("captured phrase")); c.finish()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(c.status, .reviewTranscript)
        speech.emit(.final("late replacement")); XCTAssertEqual(c.transcript, "captured phrase")
        await c.shutdown()
    }
    func testSilenceDismissesWithoutInterpretation() async {
        let speech = FakeSpeech(); var calls = 0
        let c = controller(speech, judged: { _ in calls += 1 })
        c.begin(); await settle(); c.finish(); speech.emit(.final("  ")); await settle()
        XCTAssertEqual(c.status, .idle)
        speech.emit(.final("late words")); await settle()
        XCTAssertEqual(c.status, .idle)
        XCTAssertEqual(calls, 0); XCTAssertTrue(c.canBegin)
        await c.shutdown()
    }
    func testRecognitionFailureWithoutSpeechStillReportsError() async {
        let speech = FakeSpeech()
        let c = controller(speech)
        c.begin(); await settle(); c.finish()
        speech.emit(.failure("Microphone disconnected")); await settle()
        guard case .error(let message) = c.status else {
            XCTFail("A real input failure must remain visible")
            await c.shutdown(); return
        }
        XCTAssertTrue(message.contains("Microphone disconnected"))
        await c.shutdown()
    }
    func testEmptyEarlyFinalShowsRetryableError() async {
        let speech = FakeSpeech()
        let current = controller(speech)
        current.begin(); await settle(); speech.emit(.final("")); current.finish()
        guard case .error = current.status else { return XCTFail("Interrupted silence needs feedback") }
        XCTAssertTrue(current.canBegin)
        await current.shutdown()
    }
    func testRecordingLimitStopsCaptureAndRequiresReview() async throws {
        let speech = FakeSpeech()
        let c = controller(speech, manual: true, timings: VoiceTimings(warning: 0.01, limit: 0.02))
        c.begin(); await settle(); speech.emit(.partial("captured"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(c.status, .awaitingRelease)
        c.finish(); XCTAssertEqual(c.status, .reviewTranscript)
        await c.shutdown()
    }
    func testOldCompletionTimerCannotHideNewCapture() async throws {
        let speech = FakeSpeech()
        let current = controller(speech, timings: VoiceTimings(dismissal: 0.03))
        current.begin(); await settle(); current.finish(); speech.emit(.final("conversation"))
        await current.cua.speech.waitForPending()
        XCTAssertEqual(current.status, .done)
        current.begin(); await settle(); try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(current.status, .listening)
        await current.shutdown()
    }
    func testPreviousSessionCannotOverwriteNewCapture() async {
        let speech = FakeSpeech(); let c = controller(speech, manual: true)
        c.begin(); await settle(); let old = speech.sessions.last!
        c.cancel(); await settle(); c.begin(); await settle()
        speech.emit(.partial("new")); speech.emit(.final("stale"), session: old)
        XCTAssertEqual(c.transcript, "new"); XCTAssertEqual(c.status, .listening)
        await c.shutdown()
    }
}
private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}
