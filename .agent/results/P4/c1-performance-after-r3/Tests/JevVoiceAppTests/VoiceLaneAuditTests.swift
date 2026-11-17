import XCTest
import AVFoundation
@testable import JevVoice

/// Contract tests for the voice-lane audit fixes: speechless Fn tap →
/// gaze click dispatch, mid-hold screenshot/context sends, the 200ms
/// transcript settle cap, say-suppression for every contract tool
/// result, the dictation editing vocabulary, voice-started dictation,
/// spoken failures, the universal-stop and local-speech seams — all
/// exercised without a socket or a microphone.
@MainActor
final class VoiceLaneAuditTests: XCTestCase {

    // MARK: - shared scaffolding

    private func lane() -> RealtimeVoiceLane { RealtimeVoiceLane(apiKey: { "test-key" }) }

    private func makeFeed() throws -> ConvertedAudioFeed {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: 48000, channels: 1, interleaved: false)!
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 24000, channels: 1, interleaved: true)!
        return try ConvertedAudioFeed(input: input, output: output)
    }

    private final class Flags: @unchecked Sendable {
        var value = 0
        var strings: [String] = []
        var ints: [Int] = []
        var bools: [String: Bool] = [:]
    }

    private final class StubCapture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var onReadiness: ((SpeechReadiness) -> Void)?
        private(set) var startedID: UUID?
        var finishCalls = 0
        var cancelCalls = 0
        func prepare(inputUID: String?) async throws -> String { "stub mic" }
        func suspend() async {}
        func start(session id: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
            startedID = id
            return "stub mic"
        }
        func finish() { finishCalls += 1 }
        func cancel() { cancelCalls += 1 }
    }

    private final class FakeSpeaker: SpeechSynthesizing, @unchecked Sendable {
        private(set) var spoken: [String] = []
        func speak(_ text: String) { spoken.append(text) }
        func stop() {}
    }

    private final class RecordingDictation: DictationDelivering, @unchecked Sendable {
        private(set) var delivered: [String] = []
        func deliver(_ text: String) async throws { delivered.append(text) }
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func testConfig() -> Config {
        let suite = "voice-lane-audit-\(UUID().uuidString)"
        return Config(defaults: UserDefaults(suiteName: suite)!,
                      keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                      environment: [:])
    }

    private func testCoordinator(_ config: Config) -> VoiceTaskCoordinator {
        VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: {
                AsyncThrowingStream { _ in }
            })))
    }

    private func poll(_ nanoseconds: UInt64 = 40, attempts: Int = 150,
                      until condition: () -> Bool) async {
        for _ in 0..<attempts where !condition() {
            try? await Task.sleep(nanoseconds: nanoseconds * 1_000_000)
        }
    }

    // MARK: - Task 1: speechless Fn tap → gaze click vs silent dismiss

    /// A tap under the 100ms audio floor fires the wired handler — true
    /// means the gaze side clicked; either way the turn cleans up and
    /// emits the silent `.final("")` dismiss.
    func testSpeechlessTapDispatchesGazeHandler() async throws {
        for handled in [true, false] {
            let owner = LocalSpeechSession { _ in XCTFail("a speechless gesture is not a voice command") }
            let lane = RealtimeVoiceLane(apiKey: { "test-key" }, admissionOwner: owner)
            var events: [SpeechEvent] = []
            let flags = Flags()
            lane.onEvent = { _, event in events.append(event) }
            lane.gazeTapHandler = { flags.value += 1; return handled }
            let id = UUID()
            let session = RealtimeVoiceLane.Session(name: "mic", feed: try makeFeed(), sendsAudio: true)
            session.localTurn = owner.begin(id: id, mode: .command, ready: true, now: 0)
            lane.active = (id, session)
            lane.turnID = id
            lane.finish()
            await poll(until: { lane.turnID == nil })
            XCTAssertEqual(flags.value, 1,
                           "a speechless tap must consult the gaze handler (handled=\(handled))")
            XCTAssertNil(lane.turnID)
            XCTAssertTrue(events.contains {
                if case .final(let text) = $0 { return text.isEmpty }
                return false
            }, "the tap ends in the silent .final dismiss (handled=\(handled))")
        }
    }

    /// No handler wired → today's silent dismiss, no dispatch at all.
    func testSpeechlessTapWithoutHandlerDismisses() async throws {
        let lane = lane()
        var events: [SpeechEvent] = []
        lane.onEvent = { _, event in events.append(event) }
        let id = UUID()
        lane.active = (id, RealtimeVoiceLane.Session(
            name: "mic", feed: try makeFeed(), sendsAudio: true))
        lane.turnID = id
        lane.finish()
        await poll(until: { lane.turnID == nil })
        XCTAssertTrue(events.contains {
            if case .final(let text) = $0 { return text.isEmpty }
            return false
        })
    }

    /// A metering session (mic test) never reaches the gaze gesture —
    /// sendsAudio=false means it was never a turn candidate.
    func testMeteringFinishNeverFiresGazeHandler() async throws {
        let lane = lane()
        let flags = Flags()
        lane.gazeTapHandler = { flags.value += 1; return true }
        let id = UUID()
        lane.active = (id, RealtimeVoiceLane.Session(
            name: "mic", feed: try makeFeed(), sendsAudio: false))
        lane.turnID = id
        lane.finish()
        await poll(until: { lane.turnID == nil })
        XCTAssertEqual(flags.value, 0, "a mic-test finish must not click")
    }

    func testShortDictationFinishNeverClicks() async throws {
        let lane = lane()
        let flags = Flags()
        lane.respondOnCommit = false
        lane.gazeTapHandler = { flags.value += 1; return true }
        let id = UUID()
        lane.active = (id, RealtimeVoiceLane.Session(name: "fixture", feed: try makeFeed(), sendsAudio: true))
        lane.turnID = id
        lane.finish()
        await poll(until: { lane.turnID == nil })
        XCTAssertEqual(flags.value, 0)
    }

    func testCancelledShortCaptureNeverClicks() async throws {
        let lane = lane()
        let flags = Flags()
        lane.gazeTapHandler = { flags.value += 1; return true }
        let id = UUID()
        lane.active = (id, RealtimeVoiceLane.Session(name: "fixture", feed: try makeFeed(), sendsAudio: true))
        lane.turnID = id
        lane.finish()
        lane.cancel()
        await Task.yield()
        XCTAssertEqual(flags.value, 0)
    }

    // MARK: - Task 2/4: mid-hold turn assets

    /// The hold-path asset send consults the context provider for a
    /// live command turn and skips EVERYTHING for a dictation hold —
    /// its commit is transcript-only and consumes neither.
    func testSendTurnAssetsSkipsDictationTurn() async throws {
        let lane = lane()
        let flags = Flags()
        lane.contextProvider = { flags.value += 1; return "[context] test" }
        let id = UUID()
        lane.active = (id, RealtimeVoiceLane.Session(
            name: "mic", feed: try makeFeed(), sendsAudio: true))
        lane.respondOnCommit = false
        await lane.sendTurnAssets(session: id)
        XCTAssertEqual(flags.value, 0,
                       "a dictation hold must not spend the context note")
        lane.respondOnCommit = true
        await lane.sendTurnAssets(session: id)
        XCTAssertEqual(flags.value, 0,
                       "no context is sent until a whole-final safe miss is admitted")
    }

    /// A stale/cancelled turn's assets must not send — the identity
    /// guard matches the finish() guards.
    func testSendTurnAssetsRejectsStaleTurn() async throws {
        let lane = lane()
        let flags = Flags()
        lane.contextProvider = { flags.value += 1; return "[context] test" }
        lane.active = (UUID(), RealtimeVoiceLane.Session(
            name: "mic", feed: try makeFeed(), sendsAudio: true))
        await lane.sendTurnAssets(session: UUID())
        XCTAssertEqual(flags.value, 0)
    }

    /// The dictation hold doesn't even spawn its screenshot — the
    /// capture is never consumed.
    func testDictationHoldSpendsNoScreenshot() {
        let lane = lane()
        XCTAssertFalse(lane.wantsTurnScreenshot)
        lane.respondOnCommit = false
        XCTAssertFalse(lane.wantsTurnScreenshot)
    }

    // MARK: - Task 3: transcript settle cap

    func testTranscriptSettleCapIs200ms() {
        XCTAssertEqual(RealtimeVoiceLane.transcriptSettleCap, 0.2, accuracy: 0.0001)
    }

    // MARK: - Task 5: say-suppression for every contract tool result

    /// The decode gate — every VoiceToolResult carrying a non-empty say
    /// suppresses; bare text and say-less/empty-say results still arm
    /// the model's answer.
    func testDeterministicSayDecodesContractResults() {
        XCTAssertEqual(RealtimeVoiceLane.deterministicSay(
            #"{"status":"ok","say":"Done."}"#), "Done.")
        XCTAssertEqual(RealtimeVoiceLane.deterministicSay(
            #"{"status":"started","say":"Opening Safari."}"#), "Opening Safari.")
        XCTAssertEqual(RealtimeVoiceLane.deterministicSay(
            #"{"status":"refused","say":"No."}"#), "No.")
        XCTAssertNil(RealtimeVoiceLane.deterministicSay("plain answer text"))
        XCTAssertNil(RealtimeVoiceLane.deterministicSay(#"{"status":"ok","say":"  "}"#))
        XCTAssertNil(RealtimeVoiceLane.deterministicSay(#"{"status":"ok"}"#))
        XCTAssertNil(RealtimeVoiceLane.deterministicSay("not json at all"))
    }

    /// A say result ends the turn without arming a second response —
    /// the second model RTT never happens.
    func testSettleToolCallSuppressesSayResult() {
        let lane = lane()
        var events: [SpeechEvent] = []
        let id = UUID()
        lane.onEvent = { _, event in events.append(event) }
        lane.turnID = id
        lane.awaitingTurnEnd = true

        lane.settleToolCall(output: #"{"status":"ok","say":"Done."}"#, session: id)

        XCTAssertNil(lane.turnID, "a say result ends the turn immediately")
        XCTAssertFalse(lane.awaitingTurnEnd)
        XCTAssertTrue(events.contains {
            if case .turnEnded = $0 { return true }
            return false
        })
    }

    /// Say-less results (web_lookup, higher-model answers) still arm the
    /// response gate so the model relays the content.
    func testSettleToolCallArmsResponseForSaylessResult() {
        let lane = lane()
        let id = UUID()
        lane.turnID = id
        lane.settleToolCall(output: "the web answer text", session: id)
        XCTAssertEqual(lane.turnID, id)
        XCTAssertTrue(lane.awaitingTurnEnd)
    }

    /// A stale turn's result books nothing on the live one.
    func testSettleToolCallIgnoresForeignTurn() {
        let lane = lane()
        var events: [SpeechEvent] = []
        let live = UUID()
        lane.onEvent = { _, event in events.append(event) }
        lane.turnID = live
        lane.settleToolCall(output: #"{"status":"ok","say":"Done."}"#, session: UUID())
        XCTAssertEqual(lane.turnID, live)
        XCTAssertTrue(events.isEmpty)
    }

    /// A response already in flight owns the voice — a say result
    /// arriving under it leaves the armed response alone.
    func testSettleToolCallRespectsInFlightResponse() {
        let lane = lane()
        var events: [SpeechEvent] = []
        let id = UUID()
        lane.onEvent = { _, event in events.append(event) }
        lane.turnID = id
        lane.responseInFlight = true

        lane.settleToolCall(output: #"{"status":"ok","say":"Done."}"#, session: id)

        XCTAssertEqual(lane.turnID, id, "the armed response still owns the turn end")
        XCTAssertFalse(events.contains {
            if case .turnEnded = $0 { return true }
            return false
        })
    }

    // MARK: - Cross-lane seam: local speech tee

    /// The converted feed hands every output chunk to the sink — the
    /// LocalTranscriber hears the same PCM the socket does.
    func testConvertedFeedTeesChunksToLocalSpeechSink() throws {
        let feed = try makeFeed()
        let flags = Flags()
        feed.localSpeechSink = { buffer in
            flags.value += 1
            flags.bools["rate24k"] = buffer.format.sampleRate == 24000
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        feed.append(buffer)
        XCTAssertEqual(flags.value, 1)
        XCTAssertEqual(flags.bools["rate24k"], true)
    }

    // MARK: - Task 7: dictation editing vocabulary

    func testEditTokensParsesVocabulary() {
        XCTAssertEqual(DictationDelivery.editTokens("hello world"),
                       [.insert("hello world")])
        XCTAssertEqual(DictationDelivery.editTokens("one new line two"),
                       [.insert("one"), .insert("\n"), .insert("two")])
        XCTAssertEqual(DictationDelivery.editTokens("Scratch That!"), [.scratch])
        XCTAssertEqual(DictationDelivery.editTokens("undo that"), [.undo])
        XCTAssertEqual(DictationDelivery.editTokens("delete last sentence"),
                       [.deleteSentence])
        XCTAssertEqual(DictationDelivery.editTokens("say newline"),
                       [.insert("say"), .insert("\n")])
        XCTAssertEqual(DictationDelivery.editTokens(""), [])
    }

    /// The editing vocabulary rides the same seams: inserts go through
    /// insertText, removals through the delete-keystroke seam, and the
    /// history tracks what a later command can take back.
    func testDictationEditsDeliverAndDelete() async throws {
        let flags = Flags()
        let delivery = DictationDelivery(
            insertText: { flags.strings.append($0); return true },
            pasteText: { _ in true },
            deleteBackward: { flags.ints.append($0); return true })

        try await delivery.deliver("hello world")
        XCTAssertEqual(flags.strings, ["hello world"])

        try await delivery.deliver("scratch that")
        XCTAssertEqual(flags.ints, [11], "scratch deletes the last inserted segment")

        try await delivery.deliver("one new line two")
        XCTAssertEqual(Array(flags.strings.suffix(3)), ["one", "\n", "two"])

        try await delivery.deliver("undo that")
        XCTAssertEqual(flags.ints.last, 7, "undo removes the whole last delivery")

        try await delivery.deliver("First. Second")
        try await delivery.deliver("delete last sentence")
        XCTAssertEqual(flags.ints.last, 7, "sentence cut removes ' Second'")

        try await delivery.deliver("scratch that")
        XCTAssertEqual(flags.ints.last, 6, "history kept 'First.' after the sentence cut")
    }

    /// A pure-command transcript with empty history is a no-op success,
    /// not a lost paste.
    func testDictationCommandOnEmptyHistoryIsNoOp() async throws {
        let delivery = DictationDelivery(
            insertText: { _ in false },
            pasteText: { _ in false },
            deleteBackward: { _ in false })
        try await delivery.deliver("scratch that")
        try await delivery.deliver("undo that")
        try await delivery.deliver("delete last sentence")
    }

    /// An uneditable field still throws for plain text — the insert
    /// contract is unchanged.
    func testDictationInsertFailureStillThrows() async {
        let delivery = DictationDelivery(
            insertText: { _ in false },
            pasteText: { _ in false },
            deleteBackward: { _ in true })
        do {
            try await delivery.deliver("hello")
            XCTFail("an uneditable field must throw")
        } catch { }
    }

    // MARK: - Task 7: voice-started dictation + universal stop seam

    /// "Start dictation" without Fn+Ctrl: the capture latches open,
    /// an Fn tap is converted to finish() through begin(), and the
    /// final transcript still delivers literally.
    func testStartDictationLatchesAndDelivers() async throws {
        let config = testConfig()
        config.dictationHotkey = true
        let capture = StubCapture()
        let dictation = RecordingDictation()
        let controller = VoiceController(config: config, speech: capture,
                                         authorize: { true },
                                         cuaRuntime: testCoordinator(config),
                                         dictation: dictation, speaker: FakeSpeaker())
        controller.startDictation()
        await poll(until: { capture.startedID != nil && controller.isListening })
        let id = try XCTUnwrap(capture.startedID)
        XCTAssertTrue(controller.captureActive)

        // The voice latch lets a press through canBegin and converts it
        // to the release that ends dictation — never a second capture.
        XCTAssertTrue(controller.canBegin)
        controller.begin()
        XCTAssertEqual(capture.finishCalls, 1)

        capture.onEvent?(id, .final("hello world"))
        await poll(until: { !dictation.delivered.isEmpty })
        XCTAssertEqual(dictation.delivered, ["hello world"])
    }

    /// The hotkey gate still applies — a disabled dictation feature
    /// refuses the verb silently.
    func testStartDictationRespectsHotkeyGate() async {
        let config = testConfig()
        config.dictationHotkey = false
        let capture = StubCapture()
        let controller = VoiceController(config: config, speech: capture,
                                         authorize: { true },
                                         cuaRuntime: testCoordinator(config),
                                         dictation: RecordingDictation(),
                                         speaker: FakeSpeaker())
        controller.startDictation()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(capture.startedID)
        XCTAssertFalse(controller.captureActive)
    }

    /// Escape routes to the coordinator's universal-cancel entry when
    /// wired; the capture-only dismiss path never fires it.
    func testCancelFiresUniversalStopSeam() async {
        let config = testConfig()
        let flags = Flags()
        let controller = VoiceController(config: config, speech: StubCapture(),
                                         authorize: { true },
                                         cuaRuntime: testCoordinator(config),
                                         speaker: FakeSpeaker())
        controller.cancelAllTasks = { flags.value += 1 }
        controller.cancel()
        await poll(until: { flags.value == 1 })
        XCTAssertEqual(flags.value, 1)

        controller.cancelCaptureAttempt()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(flags.value, 1, "capture dismiss is not a universal stop")
    }

    // MARK: - Task 5/6: toolSay presentation + spoken failures

    /// A pushed outcome whose payload already carries `say` is voiced
    /// verbatim through the TTS seam and reaches the model as context
    /// only — the taskEventSink / voiceAgentEvent path must not pay a
    /// second RTT to repeat a line we hold.
    func testDeterministicPushedOutcomeSpeaksLocally() {
        let config = testConfig()
        let speaker = FakeSpeaker()
        let controller = VoiceController(config: config, speech: StubCapture(),
                                         authorize: { true },
                                         cuaRuntime: testCoordinator(config),
                                         speaker: speaker)
        let handled = controller.voiceAgentEvent(
            #"{"kind":"task_outcome","status":"ok","say":"The reply is ready."}"#)
        XCTAssertTrue(handled)
        XCTAssertEqual(controller.detail, "The reply is ready.")
        XCTAssertEqual(speaker.spoken, ["The reply is ready."])
    }

    /// Plain speakable pushes keep the model-voice path — nothing
    /// deterministic to shortcut.
    func testPlainPushedOutcomeKeepsModelPath() {
        let config = testConfig()
        let speaker = FakeSpeaker()
        let controller = VoiceController(config: config, speech: StubCapture(),
                                         authorize: { true },
                                         cuaRuntime: testCoordinator(config),
                                         speaker: speaker)
        let handled = controller.voiceAgentEvent("The agent needs your approval.")
        XCTAssertTrue(handled)
        XCTAssertTrue(speaker.spoken.isEmpty,
                      "a plain push must not be pre-voiced locally")
        XCTAssertNotEqual(controller.detail, "The agent needs your approval.")
    }

    /// The card fills detail from the say directly and the TTS seam
    /// voices it — no assistantDone arrives on a suppressed turn.
    func testToolSayFillsDetailAndSpeaks() async throws {
        let config = testConfig()
        let capture = StubCapture()
        let speaker = FakeSpeaker()
        let controller = VoiceController(config: config, speech: capture,
                                         authorize: { true },
                                         cuaRuntime: testCoordinator(config),
                                         speaker: speaker)
        controller.begin()
        await poll(until: { capture.startedID != nil })
        let id = try XCTUnwrap(capture.startedID)

        capture.onEvent?(id, .toolSay("Opening Safari."))
        XCTAssertEqual(controller.detail, "Opening Safari.")
        XCTAssertEqual(speaker.spoken, ["Opening Safari."])
    }

    /// fail() paints the pill AND says a short non-punitive phrase —
    /// an authorization failure reaches the seam here.
    func testFailureSpeaksBriefPhrase() async {
        let config = testConfig()
        let speaker = FakeSpeaker()
        let controller = VoiceController(config: config, speech: StubCapture(),
                                         authorize: { false },
                                         cuaRuntime: testCoordinator(config),
                                         speaker: speaker)
        controller.begin()
        await poll(until: { !speaker.spoken.isEmpty })
        XCTAssertEqual(speaker.spoken, ["I need microphone access — check Voice settings."])
        guard case .error = controller.status else {
            return XCTFail("the failed capture must end on the error pill")
        }
    }

    /// The phrase mapper stays generic — categories resolve to short
    /// canned lines and never echo the error text.
    func testSpokenFailurePhrasing() {
        XCTAssertEqual(VoiceController.spokenFailure(
            for: "No editable field is focused for dictation."),
            "I couldn't insert that text.")
        XCTAssertEqual(VoiceController.spokenFailure(
            for: "The window server rejected the click."),
            "I couldn't reach the window server.")
        XCTAssertEqual(VoiceController.spokenFailure(
            for: "Microphone access is needed. Open Voice settings."),
            "I need microphone access — check Voice settings.")
        XCTAssertEqual(VoiceController.spokenFailure(
            for: "No speech was captured — hold Fn and dictate again."),
            "I didn't catch that.")
        XCTAssertEqual(VoiceController.spokenFailure(
            for: "The voice model is unavailable: connection dropped"),
            "I couldn't reach the voice server.")
        XCTAssertEqual(VoiceController.spokenFailure(
            for: "Something weird happened at /Users/x/secret"),
            "That didn't work.")
    }
}
