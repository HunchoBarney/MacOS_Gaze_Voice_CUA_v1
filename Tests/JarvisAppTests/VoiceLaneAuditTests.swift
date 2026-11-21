import XCTest
import AVFoundation
@testable import Jarvis

/// Contract tests for the voice-lane audit fixes: turn-end presentation,
/// mid-capture screenshot/context sends, the 200ms
/// transcript settle cap, say-suppression for every contract tool
/// result, the dictation editing vocabulary, voice-started dictation,
/// spoken failures, the universal-stop and local-speech seams — all
/// exercised without a socket or a microphone.
@MainActor
final class VoiceLaneAuditTests: XCTestCase {
    func testRealtimeFeedbackAndPauseNeverFallBackToLegacySpeech() async {
        for paused in [false, true] {
            let config = testConfig()
            config.ttsEnabled = true
            config.handsFreePaused = paused
            let speaker = FakeSpeaker()
            let realtime = RealtimeVoiceLane(apiKey: { "" })
            let controller = VoiceController.inert(config: config, speech: realtime, authorize: { true },
                cuaRuntime: testCoordinator(config), speaker: speaker)
            XCTAssertTrue(controller.voiceAgentEvent(
                #"{"status":"done","say":"The reply is ready."}"#))
            await Task.yield()
            XCTAssertTrue(speaker.spoken.isEmpty)
            await controller.shutdown()
        }
    }

    func testPersistedHandsFreePauseDoesNotWarmTheMicrophoneOnLaunch() async {
        let config = testConfig()
        config.handsFreeEnabled = true
        config.handsFreePaused = true
        let capture = StubCapture()
        let controller = VoiceController.inert(config: config, speech: capture, authorize: { true },
            cuaRuntime: testCoordinator(config))
        addTeardownBlock { await controller.shutdown() }
        controller.prepareMicrophone()
        await Task.yield()
        XCTAssertEqual(capture.prepareCalls, 0)
        XCTAssertEqual(controller.handsFreeState, .paused)
    }

    func testPauseDuringPreparationCannotReopenTheMicrophone() async {
        let config = testConfig()
        config.handsFreeEnabled = true
        let capture = StubCapture()
        capture.holdPreparation = true
        let controller = VoiceController.inert(config: config, speech: capture, authorize: { true },
            cuaRuntime: testCoordinator(config))
        addTeardownBlock { await controller.shutdown() }
        controller.prepareMicrophone()
        await poll { capture.preparationGate != nil }
        controller.pauseHandsFree()
        await poll { capture.suspendCalls > 0 }
        capture.preparationGate?.resume()
        capture.preparationGate = nil
        await poll { capture.preparationFinished && capture.suspendCalls > 1 }
        XCTAssertFalse(capture.active)
        XCTAssertTrue(config.handsFreePaused)
        XCTAssertEqual(controller.handsFreeState, .paused)
    }

    // MARK: - shared scaffolding

    private func lane() -> RealtimeVoiceLane {
        RealtimeVoiceLane(apiKey: { "test-key" })
    }

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
        var prepareCalls = 0
        var suspendCalls = 0
        var holdPreparation = false
        var preparationGate: CheckedContinuation<Void, Never>?
        var preparationFinished = false
        var active = false
        func prepare(inputUID: String?) async throws -> String {
            prepareCalls += 1
            if holdPreparation { await withCheckedContinuation { preparationGate = $0 } }
            active = true
            preparationFinished = true
            return "stub mic"
        }
        func suspend() async { active = false; suspendCalls += 1 }
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
        let config = Config(defaults: UserDefaults(suiteName: suite)!,
                      keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                      environment: [:])
        config.handsFreeEnabled = false
        return config
    }

    private func testCoordinator(_ config: Config) -> VoiceTaskCoordinator {
        VoiceTaskCoordinator(config: config, jevRoute: { nil },
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

    // MARK: - Task 1: turn-end presentation

    func testC1TurnEndWaitsForOwnedWorkAndShowsBlockedOutcome() async throws {
        let config = testConfig(), capture = StubCapture()
        let coordinator = testCoordinator(config)
        let controller = VoiceController.inert(config: config, speech: capture,
            authorize: { true }, cuaRuntime: coordinator, speaker: FakeSpeaker())
        addTeardownBlock { await controller.shutdown() }
        controller.beginCapture()
        await poll(until: { capture.startedID != nil && controller.isListening })
        let id = try XCTUnwrap(capture.startedID)
        controller.finish()
        capture.onEvent?(id, .heardFinal("Scroll down."))
        let work = VoiceTaskCoordinator.Work(label: "Scroll", request: "Scroll down.",
            spec: DriveTask(goal: "Scroll down.", application: "fixture.editor"))
        work.captureID = id
        work.message = "Scrolling"
        coordinator.tasks = [work]
        capture.onEvent?(id, .turnEnded)
        XCTAssertEqual(controller.status, .executing)

        work.outcome = .blocked("The captured viewport changed.")
        work.message = "The captured viewport changed."
        work.active = false
        coordinator.onChange()
        XCTAssertEqual(controller.status, .error("The captured viewport changed."))
        XCTAssertNotEqual(controller.status.title, "Finished")
    }

    /// A machine reason on the outcome never reaches the indicator: the
    /// status carries the sentence from the wording map.
    func testBlockedReasonCodeShowsASentence() async throws {
        let config = testConfig(), capture = StubCapture()
        let coordinator = testCoordinator(config)
        let controller = VoiceController.inert(config: config, speech: capture,
            authorize: { true }, cuaRuntime: coordinator, speaker: FakeSpeaker())
        addTeardownBlock { await controller.shutdown() }
        controller.beginCapture()
        await poll(until: { capture.startedID != nil && controller.isListening })
        let id = try XCTUnwrap(capture.startedID)
        controller.finish()
        capture.onEvent?(id, .heardFinal("Click it."))
        let work = VoiceTaskCoordinator.Work(label: "Click", request: "Click it.",
            spec: DriveTask(goal: "Click it."))
        work.captureID = id
        coordinator.tasks = [work]
        capture.onEvent?(id, .turnEnded)
        work.outcome = .blocked("low_confidence")
        work.message = ""
        work.active = false
        coordinator.onChange()
        guard case .error(let shown) = controller.status else {
            return XCTFail("expected an error status, got \(controller.status)")
        }
        XCTAssertFalse(shown.contains("low_confidence"), shown)
        XCTAssertEqual(shown, OutcomeWording.blocked("low_confidence"))
    }

    func testC1UnsuccessfulOwnedWorkNeverCompletesOnTurnEnd() async throws {
        let outcomes: [VoiceTaskCoordinator.Work.Outcome] = [
            .blocked("Wrong window"), .failed("Driver disconnected"),
            .uncertain("Effect could not be verified"), .cancelled,
        ]
        for outcome in outcomes {
            let config = testConfig(), capture = StubCapture()
            let coordinator = testCoordinator(config)
            let controller = VoiceController.inert(config: config, speech: capture,
                authorize: { true }, cuaRuntime: coordinator, speaker: FakeSpeaker())
            addTeardownBlock { await controller.shutdown() }
            controller.beginCapture()
            await poll(until: { capture.startedID != nil && controller.isListening })
            let id = try XCTUnwrap(capture.startedID)
            controller.finish()
            capture.onEvent?(id, .heardFinal("Scroll down."))
            let work = VoiceTaskCoordinator.Work(label: "Scroll", request: "Scroll down.",
                spec: DriveTask(goal: "Scroll down.", application: "fixture.editor"))
            work.captureID = id
            work.outcome = outcome
            work.active = false
            work.message = "No verified completion"
            coordinator.tasks = [work]
            capture.onEvent?(id, .turnEnded)
            XCTAssertNotEqual(controller.status, .done, "\(outcome)")
        }
    }

    func testC1OldWorkSettlementPreservesNewCapture() async throws {
        let config = testConfig(), capture = StubCapture()
        let coordinator = testCoordinator(config)
        let controller = VoiceController.inert(config: config, speech: capture,
            authorize: { true }, cuaRuntime: coordinator, speaker: FakeSpeaker())
        addTeardownBlock { await controller.shutdown() }
        controller.beginCapture()
        await poll(until: { capture.startedID != nil && controller.isListening })
        let oldID = try XCTUnwrap(capture.startedID)
        controller.finish()
        capture.onEvent?(oldID, .heardFinal("Scroll down."))
        let work = VoiceTaskCoordinator.Work(label: "Scroll", request: "Scroll down.",
            spec: DriveTask(goal: "Scroll down.", application: "fixture.editor"))
        work.captureID = oldID
        coordinator.tasks = [work]
        capture.onEvent?(oldID, .turnEnded)

        controller.beginCapture()
        await poll(until: { capture.startedID != oldID && controller.isListening })
        XCTAssertNotEqual(capture.startedID, oldID)
        let cancellations = capture.cancelCalls
        work.active = false
        work.outcome = .blocked("The old target disappeared.")
        work.message = "The old target disappeared."
        coordinator.onChange()
        XCTAssertEqual(controller.status, .listening)
        XCTAssertEqual(capture.cancelCalls, cancellations)
    }

    func testC1SuccessfulWorkCompletesAfterReplyButClarificationDoesNotClaimSuccess() async throws {
        for hasWork in [true, false] {
            let config = testConfig(), capture = StubCapture()
            let coordinator = testCoordinator(config)
            let controller = VoiceController.inert(config: config, speech: capture,
                authorize: { true }, cuaRuntime: coordinator, speaker: FakeSpeaker())
            addTeardownBlock { await controller.shutdown() }
            controller.beginCapture()
            await poll(until: { capture.startedID != nil && controller.isListening })
            let id = try XCTUnwrap(capture.startedID)
            controller.finish()
            capture.onEvent?(id, .heardFinal("Scroll down."))
            if hasWork {
                let work = VoiceTaskCoordinator.Work(label: "Scroll", request: "Scroll down.",
                    spec: DriveTask(goal: "Scroll down.", application: "fixture.editor"))
                work.captureID = id
                coordinator.tasks = [work]
                capture.onEvent?(id, .turnEnded)
                work.outcome = .done
                work.message = "The requested viewport moved down."
                work.active = false
                coordinator.onChange()
                XCTAssertEqual(controller.status, .done)
                XCTAssertEqual(controller.resultMessage, work.message)
            } else {
                capture.onEvent?(id, .toolSay("Which window do you mean?"))
                capture.onEvent?(id, .turnEnded)
                XCTAssertNotEqual(controller.status, .done)
                XCTAssertEqual(controller.detail, "Which window do you mean?")
            }
        }
    }

    /// A capture that sent almost no audio ends in the silent dismiss.
    func testSpeechlessCaptureDismisses() async throws {
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

    /// "Start dictation": the capture latches open, "stop dictating"
    /// finishes it, and the final transcript delivers literally.
    func testStartDictationLatchesAndDelivers() async throws {
        let config = testConfig()
        let capture = StubCapture()
        let dictation = RecordingDictation()
        let controller = VoiceController.inert(config: config, speech: capture,
                                         authorize: { true },
                                         cuaRuntime: testCoordinator(config),
                                         dictation: dictation, speaker: FakeSpeaker())
        controller.startDictation()
        await poll(until: { capture.startedID != nil && controller.isListening })
        let id = try XCTUnwrap(capture.startedID)
        XCTAssertTrue(controller.captureActive)

        XCTAssertTrue(controller.dictationRequest(false))
        XCTAssertEqual(capture.finishCalls, 1)

        capture.onEvent?(id, .final("hello world"))
        await poll(until: { !dictation.delivered.isEmpty })
        XCTAssertEqual(dictation.delivered, ["hello world"])
    }

    /// A cancel routes to the coordinator's universal-cancel entry when
    /// wired; the capture-only dismiss path never fires it.
    func testCancelFiresUniversalStopSeam() async {
        let config = testConfig()
        let flags = Flags()
        let controller = VoiceController.inert(config: config, speech: StubCapture(),
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

    /// Escape stops an in-flight task through the universal cancel, and
    /// does nothing while Jarvis is idle or for any other key.
    func testEscapeStopsAnInFlightTaskAndIgnoresIdle() async {
        let config = testConfig()
        let coordinator = testCoordinator(config)
        let flags = Flags()
        let controller = VoiceController.inert(config: config, speech: StubCapture(),
                                         authorize: { true }, cuaRuntime: coordinator,
                                         speaker: FakeSpeaker())
        addTeardownBlock { await controller.shutdown() }
        controller.cancelAllTasks = { flags.value += 1 }
        let escape = EscapeStop(isActive: { controller.stoppable }, stop: { controller.cancel() })

        XCTAssertFalse(controller.stoppable)
        XCTAssertFalse(escape.handle(keyCode: EscapeStop.escapeKeyCode), "an idle Escape belongs to the frontmost app")
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(flags.value, 0)

        coordinator.tasks = [VoiceTaskCoordinator.Work(label: "Scroll", request: "Scroll down.",
            spec: DriveTask(goal: "Scroll down.", application: "fixture.editor"))]
        XCTAssertTrue(controller.stoppable)
        XCTAssertFalse(escape.handle(keyCode: 0), "only Escape stops")
        XCTAssertFalse(escape.handle(keyCode: EscapeStop.escapeKeyCode, physical: false),
                       "an Escape the Cua driver posts inside the task doesn't stop it")
        XCTAssertTrue(escape.handle(keyCode: EscapeStop.escapeKeyCode))
        await poll(until: { flags.value == 1 })
        XCTAssertEqual(flags.value, 1)
    }

    // MARK: - Task 5/6: toolSay presentation + spoken failures

    /// A pushed outcome whose payload already carries `say` is voiced
    /// verbatim through the TTS seam and reaches the model as context
    /// only — the taskEventSink / voiceAgentEvent path must not pay a
    /// second RTT to repeat a line we hold.
    func testDeterministicPushedOutcomeSpeaksLocally() {
        let config = testConfig()
        let speaker = FakeSpeaker()
        let controller = VoiceController.inert(config: config, speech: StubCapture(),
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
        let controller = VoiceController.inert(config: config, speech: StubCapture(),
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
        let controller = VoiceController.inert(config: config, speech: capture,
                                         authorize: { true },
                                         cuaRuntime: testCoordinator(config),
                                         speaker: speaker)
        controller.beginCapture()
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
        let controller = VoiceController.inert(config: config, speech: StubCapture(),
                                         authorize: { false },
                                         cuaRuntime: testCoordinator(config),
                                         speaker: speaker)
        controller.beginCapture()
        await poll(until: { !speaker.spoken.isEmpty })
        XCTAssertEqual(speaker.spoken, ["I can't hear you, the mic's switched off for me. It's under Privacy & Security, then Microphone."])
        guard case .error = controller.status else {
            return XCTFail("the failed capture must end on the error pill")
        }
    }

    /// The phrase mapper stays generic — categories resolve to short
    /// canned lines and never echo the error text.
    func testSpokenFailurePhrasing() {
        XCTAssertEqual(OutcomeWording.spokenFailure(
            "No editable field is focused for dictation."),
            "I couldn't type that in. Click where you want it and try again.")
        XCTAssertEqual(OutcomeWording.spokenFailure(
            "The window server rejected the click."),
            "Your Mac didn't let me do that. Try again in a moment.")
        XCTAssertEqual(OutcomeWording.spokenFailure(
            "Microphone access is needed. It's under Privacy & Security, then Microphone."),
            "I can't hear you, the mic's switched off for me. It's under Privacy & Security, then Microphone.")
        XCTAssertEqual(OutcomeWording.spokenFailure(
            "No speech was captured. Say “start dictating” and try again."),
            "Sorry, I didn't catch that.")
        XCTAssertEqual(OutcomeWording.spokenFailure(
            "The voice model is unavailable: connection dropped"),
            "I can't connect right now. Give it a second and try again.")
        XCTAssertEqual(OutcomeWording.spokenFailure(
            "Something weird happened at /Users/x/secret"),
            "That didn't work, sorry.")
    }

    /// JARA-38: a missing key says so plainly and points at Settings, instead
    /// of "give it a second and try again", and the problem card offers
    /// Open Settings for it.
    func testMissingKeyIsNotADeadEnd() {
        let key = "I need my key set up first. It's in Settings, under Advanced."
        XCTAssertEqual(OutcomeWording.spokenFailure(OutcomeWording.missingVoiceKey), key)
        XCTAssertEqual(OutcomeWording.spokenFailure(
            "The voice model is unavailable: " + OutcomeWording.missingVoiceKey), key)
        XCTAssertEqual(OutcomeWording.spokenFailure(OutcomeWording.missingUnderstandingKey), key)
        XCTAssertEqual(OutcomeWording.readable(OutcomeWording.missingVoiceKey), OutcomeWording.missingVoiceKey)
        XCTAssertTrue(OutcomeWording.missingVoiceKey.contains("Settings"))

        let config = testConfig()
        XCTAssertTrue(config.needsKeys)
        XCTAssertTrue(config.saveOpenAIAPIKey("sk-test"))
        XCTAssertTrue(config.needsKeys, "the TypeSafe key is still missing")
        XCTAssertTrue(config.saveAPIKey("ts-test"))
        XCTAssertFalse(config.needsKeys)
    }

    /// JARA-38: Hands-free without its key puts the message on the card,
    /// not only in the menu-bar tooltip, and never opens the microphone.
    func testHandsFreeWithoutKeyShowsTheCard() async {
        let config = testConfig()
        config.listeningMode = .conversation
        let controller = VoiceController.inert(config: config, speech: RealtimeVoiceLane(apiKey: { "" }),
            authorize: { XCTFail("the microphone must stay closed"); return false },
            cuaRuntime: testCoordinator(config))
        addTeardownBlock { await controller.shutdown() }
        controller.resumeHandsFree()
        XCTAssertEqual(controller.status, .error(OutcomeWording.missingVoiceKey))
        XCTAssertEqual(controller.handsFreeState, .unavailable(OutcomeWording.missingVoiceKey))
    }
}
