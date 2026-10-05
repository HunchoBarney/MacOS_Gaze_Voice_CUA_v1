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
/// no work is spawned in these tests, so the runtime never connects.
@MainActor
final class DictationSessionTests: XCTestCase {
    private func controller(_ speech: DictationFakeSpeech,
                            dictation: FakeDictation = FakeDictation(),
                            speaker: FakeSpeaker = FakeSpeaker(),
                            manual: Bool = false, latch: Bool = false) -> VoiceController {
        let config = Config(defaults: UserDefaults(suiteName: "test.dictation.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(), environment: [:])
        config.autoExecute = !manual
        config.latchMode = latch
        let runtime = CuaVoiceRuntime(config: config, screenLocked: { false })
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

    /// Dictation delivers literal text to the focused field — the capture never
    /// becomes a runtime instruction or a task record.
    func testDictationCaptureDeliversLiteralTextWithoutSpawningWork() async {
        let speech = DictationFakeSpeech()
        let dictation = FakeDictation()
        let c = controller(speech, dictation: dictation)
        c.beginDictation()
        await settle()
        XCTAssertEqual(c.status, .listening)
        speech.emit(.partial("hello field"))
        c.finish()
        speech.emit(.final("hello field"))
        await settleUntil(c, .done)
        XCTAssertEqual(dictation.delivered, ["hello field"])
        XCTAssertEqual(c.status, .done)
        XCTAssertTrue(c.cuaTasks.isEmpty)
        await c.shutdown()
    }

    func testMidHoldCtrlConvertsCaptureToDictation() async {
        let speech = DictationFakeSpeech()
        let dictation = FakeDictation()
        let c = controller(speech, dictation: dictation, manual: true)
        c.begin()
        await settle()
        speech.emit(.partial("insert this"))
        c.dictate()
        c.finish()
        speech.emit(.final("insert this"))
        await settleUntil(c, .done)
        XCTAssertEqual(dictation.delivered, ["insert this"])
        XCTAssertTrue(c.cuaTasks.isEmpty)
        await c.shutdown()
    }

    /// A latch tap landing while startup is still resolving must not wedge
    /// `captureState` at `.starting`: the deferred latch rides the in-flight
    /// startup through to `.listening`, and the second tap still finishes.
    /// Without a realtime lane the routed command reports an honest error.
    func testLatchTapDuringStartupStillReachesListening() async {
        let speech = DictationFakeSpeech()
        let c = controller(speech, latch: true)
        c.begin()
        XCTAssertEqual(c.status, .starting)
        c.latchHold()
        c.finish()
        await settleUntil(c, .listening)
        XCTAssertEqual(c.status, .listening)
        c.finish()
        XCTAssertEqual(c.status, .finishing)
        speech.emit(.final("latched words"))
        await settle()
        XCTAssertEqual(c.status, .error("The realtime voice lane is not available."))
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

    /// A bare yes/no with exactly one pending consent ask resolves it through
    /// the gate's seam — it is never routed to the lane as an instruction.
    func testBareYesResolvesPendingConsent() async {
        let speech = DictationFakeSpeech()
        var resolved: (ConsentRequest, Bool)?
        let c = controller(speech)
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
        XCTAssertTrue(c.cuaTasks.isEmpty)
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

    /// "yes" with nothing pending is an ordinary command — routed to the lane,
    /// which reports honestly when absent instead of guessing.
    func testYesWithoutPendingConsentRoutesToTheLane() async {
        let speech = DictationFakeSpeech()
        var resolved = false
        let c = controller(speech)
        c.onConsentResolution = { _, _ in resolved = true }
        c.begin()
        await settle()
        c.finish()
        speech.emit(.final("yes"))
        await settle()
        XCTAssertFalse(resolved)
        XCTAssertEqual(c.status, .error("The realtime voice lane is not available."))
        await c.shutdown()
    }

    func testConsentAnswerNormalization() {
        XCTAssertEqual(VoiceController.consentAnswer("Yes."), true)
        XCTAssertEqual(VoiceController.consentAnswer(" yeah "), true)
        XCTAssertEqual(VoiceController.consentAnswer("nope"), false)
        XCTAssertNil(VoiceController.consentAnswer("yes please"))
        XCTAssertNil(VoiceController.consentAnswer(""))
    }

    /// Latch mode: a tap release keeps listening; the next finish ends the
    /// capture and routes the transcript like any command.
    func testLatchReleaseKeepsListeningUntilSecondTap() async {
        let speech = DictationFakeSpeech()
        let c = controller(speech, latch: true)
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
        await settle()
        XCTAssertEqual(c.status, .error("The realtime voice lane is not available."))
        XCTAssertEqual(c.transcript, "still going")
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

    /// A completed interaction speaks its result through the TTS seam;
    /// dictation completes silently since the text lands where the user looks.
    func testSpokenReplyFiresOnConsentCompletionButNotDictation() async {
        let speech = DictationFakeSpeech()
        let speaker = FakeSpeaker()
        let c = controller(speech, speaker: speaker)
        let request = ConsentRequest(summary: "Agent wants input", reason: "test")
        var resolved = false
        c.pendingConsent = { request }
        c.onConsentResolution = { _, _ in resolved = true }
        c.begin()
        await settle()
        c.finish()
        speech.emit(.final("yes"))
        await settleUntil(c, .done)
        XCTAssertTrue(resolved)
        XCTAssertEqual(speaker.spoken, ["Approved."])
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
        let request = ConsentRequest(summary: "Agent wants input", reason: "test")
        var resolved = false
        c.pendingConsent = { request }
        c.onConsentResolution = { _, _ in resolved = true }
        c.begin()
        await settle()
        c.finish()
        speech.emit(.final("yes"))
        await settleUntil(c, .done)
        XCTAssertTrue(resolved)
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
