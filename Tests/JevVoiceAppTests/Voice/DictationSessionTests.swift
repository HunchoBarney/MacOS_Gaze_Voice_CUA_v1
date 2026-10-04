import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
private final class DictationFakeSpeech: SpeechCapturing {
    var onEvent: ((UUID, SpeechEvent) -> Void)?
    var sessions: [UUID] = []
    var finishes = 0
    func prepare(inputUID: String?) async throws -> String { "Test microphone" }
    func suspend() async {}
    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
        sessions.append(session)
        return "Test microphone"
    }
    func finish() { finishes += 1 }
    func cancel() {}
    func emit(_ event: SpeechEvent, session: UUID? = nil) { onEvent?(session ?? sessions.last!, event) }
}

private final class FakeDictation: DictationDelivering, @unchecked Sendable {
    var delivered: [String] = []
    var error: Error?
    func deliver(_ text: String) async throws {
        if let error { throw error }
        delivered.append(text)
    }
}

private final class FakeSpeaker: SpeechSynthesizing, @unchecked Sendable {
    var spoken: [String] = []
    var stops = 0
    func speak(_ text: String) { spoken.append(text) }
    func stop() { stops += 1 }
}

/// Dictation and consent exercise the capture state machine without a driver:
/// the runtime is fixture-backed but the dictation path must never reach it.
@MainActor
final class DictationSessionTests: XCTestCase {
    private func controller(_ speech: DictationFakeSpeech,
                            dictation: FakeDictation = FakeDictation(),
                            speaker: FakeSpeaker = FakeSpeaker(),
                            manual: Bool = false, latch: Bool = false,
                            judged: @escaping (String) -> Void = { _ in }) -> VoiceController {
        let config = Config(defaults: UserDefaults(suiteName: "test.dictation.\(UUID())")!,
                            keyStore: MemoryKeyStore(), environment: [:])
        config.autoExecute = !manual
        config.latchMode = latch
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("voice-dictation-\(UUID()).py")
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
  elif name=='set_agent_cursor_enabled': value={'enabled':r['params']['arguments'].get('enabled',False)}
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
                    case "relationship": value = "independent"
                    case "pendingQuestion": value = "none"
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
                               frontmost: { "Fixture" }, cuaRuntime: runtime,
                               dictation: dictation, speaker: speaker)
    }
    private func settle() async { for _ in 0..<50 { await Task.yield() } }
    private func settleUntil(_ c: VoiceController, _ status: VoiceController.Status) async {
        for _ in 0..<100 {
            if c.status == status { return }
            await Task.yield()
        }
    }

    func testDictationCaptureDeliversLiteralTextWithoutPlanner() async {
        let speech = DictationFakeSpeech()
        let dictation = FakeDictation()
        var judged = 0
        let c = controller(speech, dictation: dictation, judged: { _ in judged += 1 })
        c.beginDictation()
        await settle()
        XCTAssertEqual(c.status, .listening)
        speech.emit(.partial("hello field"))
        c.finish()
        speech.emit(.final("hello field"))
        await settleUntil(c, .done)
        XCTAssertEqual(dictation.delivered, ["hello field"])
        XCTAssertEqual(judged, 0)
        XCTAssertEqual(c.status, .done)
        await c.shutdown()
    }

    func testMidHoldCtrlConvertsCaptureToDictation() async {
        let speech = DictationFakeSpeech()
        let dictation = FakeDictation()
        var judged = 0
        let c = controller(speech, dictation: dictation, manual: true, judged: { _ in judged += 1 })
        c.begin()
        await settle()
        speech.emit(.partial("insert this"))
        c.dictate()
        c.finish()
        speech.emit(.final("insert this"))
        await settleUntil(c, .done)
        XCTAssertEqual(dictation.delivered, ["insert this"])
        XCTAssertEqual(judged, 0)
        await c.shutdown()
    }

    func testDictationEarlyFinalDeliversOnReleaseWithoutReview() async {
        let speech = DictationFakeSpeech()
        let dictation = FakeDictation()
        let c = controller(speech, dictation: dictation)
        c.beginDictation()
        await settle()
        speech.emit(.final("early words"))
        XCTAssertEqual(c.status, .awaitingRelease)
        c.finish()
        await settleUntil(c, .done)
        XCTAssertEqual(dictation.delivered, ["early words"])
        await c.shutdown()
    }

    func testDictationFailureSurfacesError() async {
        let speech = DictationFakeSpeech()
        let dictation = FakeDictation()
        dictation.error = VoiceError("No editable field is focused for dictation.")
        let c = controller(speech, dictation: dictation)
        c.beginDictation()
        await settle()
        c.finish()
        speech.emit(.final("lost text"))
        await settle()
        guard case .error(let message) = c.status else {
            XCTFail("A failed delivery must surface an error")
            await c.shutdown(); return
        }
        XCTAssertTrue(message.contains("editable"))
        await c.shutdown()
    }

    func testDictationHotkeyDisabledIgnoresBeginDictation() async {
        let speech = DictationFakeSpeech()
        let dictation = FakeDictation()
        let c = controller(speech, dictation: dictation)
        c.config.dictationHotkey = false
        c.beginDictation()
        await settle()
        XCTAssertEqual(c.status, .idle)
        XCTAssertTrue(dictation.delivered.isEmpty)
        await c.shutdown()
    }

    func testBareYesResolvesPendingConsentWithoutPlanner() async {
        let speech = DictationFakeSpeech()
        var judged = 0
        var resolved: (ConsentRequest, Bool)?
        let c = controller(speech, judged: { _ in judged += 1 })
        let request = ConsentRequest(summary: "Inbox Desk wants to click in Mail", reason: "send the reply")
        c.pendingConsent = { request }
        c.onConsentResolution = { resolved = ($0, $1) }
        c.begin()
        await settle()
        c.finish()
        speech.emit(.final("yes"))
        await settleUntil(c, .done)
        XCTAssertEqual(resolved?.0.id, request.id)
        XCTAssertEqual(resolved?.1, true)
        XCTAssertEqual(judged, 0)
        await c.shutdown()
    }

    func testBareNoDeniesPendingConsent() async {
        let speech = DictationFakeSpeech()
        var resolved: Bool?
        let c = controller(speech)
        let request = ConsentRequest(summary: "Agent wants input", reason: "test")
        c.pendingConsent = { request }
        c.onConsentResolution = { _, approved in resolved = approved }
        c.begin()
        await settle()
        c.finish()
        speech.emit(.final("no"))
        await settleUntil(c, .done)
        XCTAssertEqual(resolved, false)
        await c.shutdown()
    }

    func testYesWithoutPendingConsentStillPlans() async {
        let speech = DictationFakeSpeech()
        var received: [String] = []
        let c = controller(speech, judged: { received.append($0) })
        c.begin()
        await settle()
        c.finish()
        speech.emit(.final("yes"))
        await c.cua.speech.waitForPending()
        XCTAssertEqual(received, ["yes"])
        await c.shutdown()
    }

    func testConsentAnswerNormalization() {
        XCTAssertEqual(VoiceController.consentAnswer("Yes."), true)
        XCTAssertEqual(VoiceController.consentAnswer(" yeah "), true)
        XCTAssertEqual(VoiceController.consentAnswer("nope"), false)
        XCTAssertNil(VoiceController.consentAnswer("yes please"))
        XCTAssertNil(VoiceController.consentAnswer(""))
    }

    func testLatchReleaseKeepsListeningUntilSecondTap() async {
        let speech = DictationFakeSpeech()
        var received: [String] = []
        let c = controller(speech, latch: true, judged: { received.append($0) })
        c.begin()
        await settle()
        XCTAssertEqual(c.status, .listening)
        c.latchHold()
        c.finish()
        XCTAssertEqual(c.status, .listening)
        speech.emit(.partial("still going"))
        c.finish()
        XCTAssertEqual(c.status, .finishing)
        speech.emit(.final("still going"))
        await c.cua.speech.waitForPending()
        XCTAssertEqual(received, ["still going"])
        XCTAssertEqual(c.status, .done)
        await c.shutdown()
    }

    func testLatchHoldIgnoredWhenLatchModeOff() async {
        let speech = DictationFakeSpeech()
        let c = controller(speech)
        c.begin()
        await settle()
        c.latchHold()
        c.finish()
        XCTAssertEqual(c.status, .finishing)
        await c.shutdown()
    }

    func testSpokenReplyFiresOnCompletionButNotDictation() async {
        let speech = DictationFakeSpeech()
        let speaker = FakeSpeaker()
        let c = controller(speech, speaker: speaker)
        c.begin()
        await settle()
        c.finish()
        speech.emit(.final("a conversation"))
        await c.cua.speech.waitForPending()
        await settleUntil(c, .done)
        XCTAssertFalse(speaker.spoken.isEmpty)
        XCTAssertGreaterThanOrEqual(speaker.stops, 1)
        await c.shutdown()

        let dictatingSpeech = DictationFakeSpeech()
        let dictatingSpeaker = FakeSpeaker()
        let dictating = FakeDictation()
        let d = controller(dictatingSpeech, dictation: dictating, speaker: dictatingSpeaker)
        d.beginDictation()
        await settle()
        d.finish()
        dictatingSpeech.emit(.final("into the field"))
        await settleUntil(d, .done)
        XCTAssertEqual(dictating.delivered, ["into the field"])
        XCTAssertTrue(dictatingSpeaker.spoken.isEmpty)
        await d.shutdown()
    }

    func testTTSDisabledStaysSilent() async {
        let speech = DictationFakeSpeech()
        let speaker = FakeSpeaker()
        let c = controller(speech, speaker: speaker)
        c.config.ttsEnabled = false
        c.begin()
        await settle()
        c.finish()
        speech.emit(.final("a conversation"))
        await c.cua.speech.waitForPending()
        await settleUntil(c, .done)
        XCTAssertEqual(c.status, .done)
        XCTAssertTrue(speaker.spoken.isEmpty)
        await c.shutdown()
    }
}
private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}
