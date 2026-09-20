import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
private final class FakeSpeech: SpeechCapturing {
    var onEvent: ((UUID, SpeechEvent) -> Void)?
    var sessions: [UUID] = []
    var starts = 0
    var finishes = 0
    var cancellations = 0
    var startGate: CheckedContinuation<Void, Never>?
    var delayStart = false
    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
        sessions.append(session); starts += 1
        if delayStart { await withCheckedContinuation { startGate = $0 } }
        try Task.checkCancellation()
        return "Test microphone"
    }
    func finish() { finishes += 1 }
    func cancel() { cancellations += 1 }
    func emit(_ event: SpeechEvent, session: UUID? = nil) { onEvent?(session ?? sessions.last!, event) }
}

@MainActor
final class VoiceSessionTests: XCTestCase {
    private func config() -> Config {
        let defaults = UserDefaults(suiteName: "test.voice.\(UUID())")!
        return Config(defaults: defaults, keyStore: MemoryKeyStore(), environment: [:])
    }
    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    func testSpeechStageTimingRejectsStaleAndInvalidEvents() async throws {
        let speech = FakeSpeech()
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in [] }, execute: { _ in "" })
        controller.begin(); await settle()
        speech.emit(.timing("Audio engine start", milliseconds: 42))
        XCTAssertEqual(controller.measurements["Audio engine start"], 42)
        speech.emit(.timing("Audio engine start", milliseconds: 500), session: UUID())
        speech.emit(.timing("Audio engine start", milliseconds: .nan))
        XCTAssertEqual(controller.measurements["Audio engine start"], 42)
        await controller.shutdown()
    }

    func testLiveDictationRevisesDuringHoldAndFinalNeverPastesAgain() async throws {
        let speech = FakeSpeech()
        var updates: [String] = [], pastes = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in XCTFail("Live literal text requires no model"); return [] },
            execute: { _ in pastes += 1; return "Pasted" },
            frontmost: { "TextEdit" }, updateDictation: { updates.append($0.text ?? ""); return true })
        controller.begin(); await settle()
        speech.emit(.partial("type the red book")); await settle()
        XCTAssertEqual(updates, ["the red book"])
        XCTAssertEqual(controller.status, .listening)
        speech.emit(.partial("type the blue notebook and quit Spotify")); await settle()
        XCTAssertEqual(updates.last, "the blue notebook and quit Spotify")
        controller.finish(); speech.emit(.final("type the blue notebook and quit Spotify")); await settle()
        XCTAssertEqual(controller.status, .done)
        XCTAssertEqual(pastes, 0)
        XCTAssertEqual(controller.history.filter { $0.action == .dictate }.count, 1)
        await controller.shutdown()
    }

    func testLiveDictationFailureRetainsDraftWithoutReplayAndManualModeNeverStreams() async throws {
        for manual in [false, true] {
            let speech = FakeSpeech(), preferences = config()
            preferences.autoExecute = !manual
            var writes = 0, pastes = 0
            let controller = VoiceController(config: preferences, speech: speech, authorize: { true },
                interpret: { _, _ in [] }, execute: { _ in pastes += 1; return "Pasted" },
                updateDictation: { _ in writes += 1; return true })
            controller.begin(); await settle()
            speech.emit(.partial("type hello")); await settle()
            XCTAssertEqual(writes, manual ? 0 : 1)
            speech.emit(.failure("Interrupted")); controller.finish(); await settle()
            if !manual {
                guard case .error(let message) = controller.status else { return XCTFail("Inserted draft must not enter replayable review") }
                XCTAssertTrue(message.contains("kept"))
            }
            XCTAssertEqual(pastes, 0)
            await controller.shutdown()
        }
    }

    func testUnsupportedLiveFieldFallsBackOnlyOnceOnRelease() async throws {
        let speech = FakeSpeech()
        var probes = 0, pasted: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .dictate, text: SlotExtractor.dictationText(from: text))] },
            execute: { pasted.append($0.text ?? ""); return "Pasted" },
            updateDictation: { _ in probes += 1; return false })
        controller.begin(); await settle()
        speech.emit(.partial("type hello")); await settle()
        speech.emit(.partial("type hello world")); await settle()
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(pasted.isEmpty)
        controller.finish(); speech.emit(.final("type hello world")); await settle()
        XCTAssertEqual(pasted, ["hello world"])
        XCTAssertEqual(controller.status, .done)
        await controller.shutdown()
    }

    func testFinalWaitsForInFlightLiveEditAndAppliesLatestTextWithoutPaste() async throws {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<Bool, Never>?
        var updates: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            execute: { _ in XCTFail("Must not paste live text again"); return "" },
            updateDictation: { d in
                updates.append(d.text ?? "")
                if updates.count == 1 { return await withCheckedContinuation { gate = $0 } }
                return true
            })
        controller.begin(); await settle()
        speech.emit(.partial("type blue")); await settle()
        controller.finish(); speech.emit(.final("type blue notebook")); await settle()
        XCTAssertFalse(controller.canBegin)
        gate?.resume(returning: true); await settle()
        XCTAssertEqual(updates, ["blue", "blue notebook"])
        XCTAssertEqual(controller.status, .done)
        await controller.shutdown()
    }

    func testChangedLiveDictationIntentCannotLaunchAnAppOrReplayDraft() async throws {
        let speech = FakeSpeech()
        var updates = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in XCTFail("Cannot reinterpret inserted literal text as commands"); return [] },
            execute: { _ in XCTFail("Cannot dispatch changed intent"); return "" },
            updateDictation: { _ in updates += 1; return true })
        controller.begin(); await settle()
        speech.emit(.partial("type open calculator")); await settle()
        speech.emit(.partial("open Calculator")); await settle()
        guard case .error = controller.status else { return XCTFail("Changed intent must stop safely") }
        XCTAssertEqual(updates, 1)
        await controller.shutdown()
    }

    func testRecordedPhraseResetsUseRealInterpreterWithoutLosingOrReplayingActions() async throws {
        let speech = FakeSpeech()
        let apps = ["TextEdit", "Calculator"]
        let interpreter = CommandInterpreter(client: JevClient(apiKey: "", baseURL: URL(fileURLWithPath: "/dev/null")), installedApps: apps)
        var actions: [Decision] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { try await interpreter.interpret(transcript: $0, frontmostApp: $1) },
            execute: { actions.append($0); return "Observed fake executor" },
            timings: VoiceTimings(stabilization: 0.01), frontmost: { "Calculator" }, installedApps: apps)
        var transcript = SpeechTranscriptAccumulator()
        controller.begin(); await settle()
        // Actual on-device result shapes from the synthetic recording on macOS 26.2.
        speech.emit(.partial(transcript.update("Open text edit")))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(actions.map(\.action), [.openApp])
        speech.emit(.partial(transcript.update("Open TextEdit", start: 0, end: 1.14)))
        speech.emit(.partial(transcript.update("Create")))
        speech.emit(.partial(transcript.update("Create a new document")))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(actions.map(\.action), [.openApp, .createDocument])
        XCTAssertEqual(actions.map(\.targetApp), ["TextEdit", "TextEdit"])
        XCTAssertEqual(controller.status, .listening)
        speech.emit(.partial(transcript.update("Create a new document", start: 4.14, end: 5.61)))
        speech.emit(.partial(transcript.update("Type the blue notebook is on my")))
        controller.finish()
        speech.emit(.final(transcript.update("Type the blue notebook is on my desk", start: 8.64, end: 10.92, final: true)))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(actions.map(\.action), [.openApp, .createDocument, .dictate])
        XCTAssertEqual(actions.last?.text, "the blue notebook is on my desk")
        XCTAssertEqual(actions.last?.targetApp, "TextEdit")
        XCTAssertEqual(controller.status, .done)
        await controller.shutdown()
    }

    func testPartialExecutesWhileListeningAndFinalDoesNotRepeat() async throws {
        let speech = FakeSpeech()
        var actions: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .openApp, targetApp: "Calculator")] },
            execute: { action in actions.append(action.clause); return "Opened" })
        controller.begin(); await settle()
        speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(controller.status, .listening)
        XCTAssertEqual(speech.finishes, 0)
        controller.finish(); speech.emit(.final("open Calculator")); await settle()
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(controller.status, .done)
    }

    func testLiteralTextNeverRunsOnPartialAndManualModeHasNoEarlyEffects() async throws {
        for manual in [false, true] {
            let speech = FakeSpeech(), preferences = config()
            preferences.autoExecute = !manual
            var calls = 0
            let controller = VoiceController(config: preferences, speech: speech, authorize: { true },
                interpret: { _, _ in calls += 1; return [] }, execute: { _ in "ok" })
            controller.begin(); await settle()
            speech.emit(.partial(manual ? "open Calculator" : "type stop and quit Spotify"))
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(calls, 0)
            await controller.shutdown()
        }
    }

    func testCorrectionDuringLaunchWaitsForReceiptAndDoesNotRepeatOnRelease() async throws {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<String, Never>?
        var launched = 0, reversed = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .openApp, targetApp: "Calculator")] },
            execute: { _ in launched += 1; return await withCheckedContinuation { gate = $0 } },
            timings: VoiceTimings(stabilization: 0.01), undo: { reversed += 1; return "Closed Calculator" })
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(launched, 1)
        speech.emit(.partial("open Calculator actually don't")); await settle()
        XCTAssertEqual(reversed, 0)
        gate?.resume(returning: "Opened"); await settle()
        XCTAssertEqual(reversed, 1)
        controller.finish(); speech.emit(.final("open Calculator actually don't")); await settle()
        XCTAssertEqual(launched, 1); XCTAssertEqual(reversed, 1)
    }

    func testStopDiscardsDelayedInterpretationAndAllowsNextCommand() async throws {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<[Decision], Never>?
        var actions: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in
                if text == "open Calculator" { return await withCheckedContinuation { gate = $0 } }
                return [Decision(clause: text, action: .openApp, targetApp: "Spotify")]
            }, execute: { d in actions.append(d.targetApp ?? ""); return "Opened" }, timings: VoiceTimings(stabilization: 0.01))
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        speech.emit(.partial("open Calculator stop then open Spotify"))
        gate?.resume(returning: [Decision(clause: "open Calculator", action: .openApp, targetApp: "Calculator")])
        await settle()
        XCTAssertEqual(actions, ["Spotify"])
        XCTAssertEqual(controller.status, .listening)
        await controller.shutdown()
    }

    func testReleaseDuringEarlyExecutionStillAcceptsFinalContinuation() async throws {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<String, Never>?
        var actions: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .openApp, targetApp: text.contains("Spotify") ? "Spotify" : "Calculator")] },
            execute: { d in
                actions.append(d.targetApp ?? "")
                if actions.count == 1 { return await withCheckedContinuation { gate = $0 } }
                return "Opened"
            }, timings: VoiceTimings(stabilization: 0.01))
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.finish()
        gate?.resume(returning: "Opened"); await settle()
        XCTAssertEqual(controller.status, .finishing)
        speech.emit(.final("open Calculator and open Spotify")); await settle()
        XCTAssertEqual(actions, ["Calculator", "Spotify"])
        XCTAssertEqual(controller.status, .done)
    }

    func testEarlyFinalReviewWaitsForNativeActionToSettleBeforeNewHold() async throws {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<String, Never>?
        var count = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .openApp, targetApp: "Calculator")] },
            execute: { _ in
                count += 1
                if count == 2 { return await withCheckedContinuation { gate = $0 } }
                return "Opened"
            }, timings: VoiceTimings(stabilization: 0.01))
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        speech.emit(.partial("open Calculator and open Spotify"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(count, 2)
        speech.emit(.final("open Calculator and open Spotify")); controller.finish()
        XCTAssertEqual(controller.status, .stopping)
        XCTAssertFalse(controller.canBegin)
        controller.begin(); XCTAssertEqual(speech.starts, 1)
        gate?.resume(returning: "Opened"); await settle()
        XCTAssertEqual(controller.status, .done)
        XCTAssertTrue(controller.canBegin)
        controller.begin(); await settle()
        speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(count, 3)
        await controller.shutdown()
    }

    func testDefaultBrowserOutcomeAdvancesContinuationContext() async throws {
        let speech = FakeSpeech()
        var contexts: [String?] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, context in
                contexts.append(context)
                return [Decision(clause: text, action: text.hasPrefix("search") ? .webSearch : .scrollDown)]
            }, execute: { _ in "Navigated" }, timings: VoiceTimings(stabilization: 0.01),
            frontmost: { "TextEdit" }, resolvedTarget: { "Google Chrome" })
        controller.begin(); await settle()
        speech.emit(.partial("search for red pandas then scroll down"))
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(contexts, ["TextEdit", "Google Chrome"])
        await controller.shutdown()
    }

    func testMissingFinalAfterEarlyActionReviewsOnlyRemainingSpeech() async throws {
        let speech = FakeSpeech()
        var count = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .openApp, targetApp: "Calculator")] },
            execute: { _ in count += 1; return "Opened" },
            timings: VoiceTimings(finalization: 0.03, stabilization: 0.01))
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        speech.emit(.partial("open Calculator then type hello")); controller.finish()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(controller.status, .reviewTranscript)
        XCTAssertEqual(controller.transcript, "then type hello")
        XCTAssertEqual(count, 1)
        await controller.shutdown()
    }

    func testNewCorrectionDuringUndoDiscardsOlderReplacement() async throws {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<String, Never>?
        var actions: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .openApp, targetApp: text.contains("Spotify") ? "Spotify" : "Calculator")] },
            execute: { d in actions.append(d.targetApp ?? ""); return "Opened" },
            timings: VoiceTimings(stabilization: 0.01),
            undo: { await withCheckedContinuation { gate = $0 } })
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        speech.emit(.partial("open Calculator actually open Spotify instead")); await settle()
        speech.emit(.partial("open Calculator actually open Spotify instead then stop"))
        gate?.resume(returning: "Reversed"); await settle()
        XCTAssertEqual(actions, ["Calculator"])
        XCTAssertEqual(controller.status, .listening)
        await controller.shutdown()
    }

    func testChangingAutoExecuteDuringHoldCannotReplayCompletedAction() async throws {
        let speech = FakeSpeech(), preferences = config()
        var actions = 0, interpretations = 0
        let controller = VoiceController(config: preferences, speech: speech, authorize: { true },
            interpret: { text, _ in interpretations += 1; return [Decision(clause: text, action: .openApp, targetApp: "Calculator")] },
            execute: { _ in actions += 1; return "Opened" }, timings: VoiceTimings(stabilization: 0.01))
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        preferences.autoExecute = false
        controller.finish(); speech.emit(.final("open Calculator")); await settle()
        XCTAssertEqual(interpretations, 1)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(controller.status, .done)
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(actions, 1)
        controller.finish(); speech.emit(.final("open Calculator")); await settle()
        XCTAssertEqual(controller.status, .awaitingConfirm)
        await controller.shutdown()
    }

    func testNativeFailureDuringRecognitionRecoveryIsReported() async throws {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<Void, Never>?
        var count = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .openApp, targetApp: "Calculator")] },
            execute: { _ in
                count += 1
                if count == 2 {
                    await withCheckedContinuation { gate = $0 }
                    throw ExecutorError.controlFailed("Native launch failed")
                }
                return "Opened"
            }, timings: VoiceTimings(stabilization: 0.01))
        controller.begin(); await settle(); speech.emit(.partial("open Calculator"))
        try await Task.sleep(nanoseconds: 50_000_000)
        speech.emit(.partial("open Calculator and open Spotify"))
        try await Task.sleep(nanoseconds: 50_000_000)
        speech.emit(.failure("Microphone interrupted")); controller.finish()
        gate?.resume(); await settle()
        guard case .error(let message) = controller.status else { return XCTFail("A native failure must not become Done") }
        XCTAssertTrue(message.contains("Native launch failed"))
        XCTAssertTrue(controller.canBegin)
    }

    func testFollowingSpeechDoesNotPostponeAStableCompletedCommand() async throws {
        let speech = FakeSpeech()
        var actions: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in [Decision(clause: text, action: .openApp, targetApp: "TextEdit")] },
            execute: { d in actions.append(d.clause); return "Opened" },
            timings: VoiceTimings(stabilization: 0.12), installedApps: ["TextEdit"])
        controller.begin(); await settle()
        speech.emit(.partial("open text edit then type"))
        try await Task.sleep(nanoseconds: 50_000_000)
        speech.emit(.partial("open text edit then type the"))
        try await Task.sleep(nanoseconds: 50_000_000)
        speech.emit(.partial("open text edit then type the blue"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(actions, ["open text edit"], "Later words must not reset the completed command's stability window")
        XCTAssertEqual(controller.status, .listening)
        await controller.shutdown()
    }

    func testReleaseBeforeCaptureStartsCancelsWithoutLateListening() async {
        let speech = FakeSpeech(); speech.delayStart = true
        var interpretations = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in interpretations += 1; return [] }, execute: { _ in "ok" })
        controller.begin()
        await settle()
        XCTAssertEqual(controller.status, .starting)
        controller.finish()
        speech.startGate?.resume(); speech.startGate = nil
        await settle()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(interpretations, 0)
    }

    func testInterruptionDuringStartupKeepsErrorAfterCleanup() async {
        let speech = FakeSpeech(); speech.delayStart = true
        let controller = VoiceController(config: config(), speech: speech, authorize: { true }, interpret: { _, _ in [] }, execute: { _ in "fixture" })
        controller.begin(); await settle()
        controller.interruptCapture("Keyboard interrupted")
        XCTAssertEqual(controller.status, .stopping)
        speech.startGate?.resume(); speech.startGate = nil
        await settle()
        XCTAssertEqual(controller.status, .error("Keyboard interrupted"))
        XCTAssertTrue(controller.canBegin)
    }

    func testFinalAfterReleaseSubmitsOnceAndIgnoresLateCallbacks() async {
        let speech = FakeSpeech()
        var received: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in received.append(text); return [] }, execute: { _ in "ok" })
        controller.begin(); await settle()
        speech.emit(.partial("open"))
        XCTAssertEqual(controller.status, .listening)
        controller.finish()
        XCTAssertEqual(speech.finishes, 1)
        speech.emit(.final("open Calculator"))
        speech.emit(.final("duplicate"))
        await settle()
        XCTAssertEqual(received, ["open Calculator"])
        XCTAssertEqual(controller.status, .done)
    }

    func testEarlyFinalRequiresReleaseAndExplicitTranscriptReview() async {
        let speech = FakeSpeech()
        var executions = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in [Decision(clause: "open Calculator", action: .openApp, targetApp: "Calculator", confidence: 1)] },
            execute: { _ in executions += 1; return "Opened Calculator" })
        controller.begin(); await settle()
        speech.emit(.final("open Calculator"))
        XCTAssertEqual(controller.status, .awaitingRelease)
        controller.finish()
        XCTAssertEqual(controller.status, .reviewTranscript)
        XCTAssertEqual(executions, 0)
        controller.acceptTranscript(); controller.acceptTranscript(); await settle()
        XCTAssertEqual(controller.status, .done)
        XCTAssertEqual(executions, 1)
    }

    func testLowConfidenceOrdinaryCommandRunsWithoutConfirmation() async {
        let speech = FakeSpeech()
        var executions = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in [Decision(clause: "open Messages", action: .openApp, targetApp: "Messages", confidence: 0.31)] },
            execute: { _ in executions += 1; return "Opened Messages" })
        controller.begin(); await settle(); controller.finish(); speech.emit(.final("open Messages")); await settle()
        XCTAssertEqual(controller.status, .done)
        XCTAssertEqual(executions, 1)
    }

    func testExplicitManualReviewPreferenceStillConfirmsOnlyOnce() async {
        let speech = FakeSpeech(), preferences = config()
        preferences.autoExecute = false
        var executions = 0
        let controller = VoiceController(config: preferences, speech: speech, authorize: { true },
            interpret: { _, _ in [Decision(clause: "open Messages", action: .openApp, targetApp: "Messages", confidence: 1)] },
            execute: { _ in executions += 1; return "Opened Messages" })
        controller.begin(); await settle(); controller.finish(); speech.emit(.final("open Messages")); await settle()
        XCTAssertEqual(controller.status, .awaitingConfirm)
        XCTAssertEqual(executions, 0)
        controller.confirm(); controller.confirm(); await settle()
        XCTAssertEqual(executions, 1)
    }

    func testCancelRejectsLateModelResponseAndNewHoldDuringCleanup() async {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<[Decision], Never>?
        var executions = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in await withCheckedContinuation { gate = $0 } },
            execute: { _ in executions += 1; return "ok" })
        controller.begin(); await settle(); controller.finish(); speech.emit(.final("open Calculator")); await settle()
        controller.cancel(); controller.begin()
        XCTAssertEqual(controller.status, .stopping)
        XCTAssertEqual(speech.starts, 1)
        gate?.resume(returning: [Decision(clause: "open Calculator", action: .openApp, targetApp: "Calculator", confidence: 1)])
        await settle()
        XCTAssertEqual(executions, 0)
        XCTAssertEqual(controller.status, .idle)
    }

    func testTimeoutReviewsPartialAndCannotBeOverwrittenByLateFinal() async throws {
        let speech = FakeSpeech()
        var interpreted: [String] = []
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { text, _ in interpreted.append(text); return [] }, execute: { _ in "ok" },
            timings: VoiceTimings(finalization: 0.01, warning: 50, limit: 55, dismissal: 10))
        controller.begin(); await settle(); speech.emit(.partial("captured phrase")); controller.finish()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(controller.status, .reviewTranscript)
        speech.emit(.final("late replacement"))
        XCTAssertEqual(controller.transcript, "captured phrase")
        controller.acceptTranscript(); await settle()
        XCTAssertEqual(interpreted, ["captured phrase"])
    }

    func testSilenceDoesNotCallInterpreter() async throws {
        let speech = FakeSpeech()
        var calls = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in calls += 1; return [] }, execute: { _ in "ok" })
        controller.begin(); await settle(); controller.finish(); speech.emit(.final("  "))
        await settle()
        XCTAssertEqual(controller.status, .idle)
        XCTAssertEqual(calls, 0)
    }

    func testEmptyEarlyFinalShowsRetryableError() async {
        let speech = FakeSpeech()
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in XCTFail("Interrupted silence must not submit"); return [] })
        controller.begin(); await settle(); speech.emit(.final("")); controller.finish()
        guard case .error = controller.status else { return XCTFail("Expected retryable error") }
        XCTAssertTrue(controller.canBegin)
    }

    func testRecordingLimitStopsCaptureAndRequiresReview() async throws {
        let speech = FakeSpeech()
        var calls = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in calls += 1; return [] },
            timings: VoiceTimings(finalization: 2, warning: 0.01, limit: 0.02, dismissal: 10))
        controller.begin(); await settle(); speech.emit(.partial("captured"))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.status, .awaitingRelease)
        XCTAssertEqual(calls, 0)
        controller.finish()
        XCTAssertEqual(controller.status, .reviewTranscript)
        await controller.shutdown()
    }

    func testOldCompletionTimerCannotHideNewCapture() async throws {
        let speech = FakeSpeech()
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in [] }, timings: VoiceTimings(dismissal: 0.03))
        controller.begin(); await settle(); controller.finish(); speech.emit(.final("no action")); await settle()
        XCTAssertEqual(controller.status, .done)
        controller.begin(); await settle()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.status, .listening)
        await controller.shutdown()
    }

    func testPreviousSessionCannotOverwriteNewCapture() async {
        let speech = FakeSpeech()
        let controller = VoiceController(config: config(), speech: speech, authorize: { true }, interpret: { _, _ in [] }, execute: { _ in "fixture" })
        controller.begin(); await settle(); let old = speech.sessions.last!
        controller.cancel(); await settle(); controller.begin(); await settle()
        speech.emit(.partial("new")); speech.emit(.final("stale"), session: old)
        XCTAssertEqual(controller.transcript, "new")
        XCTAssertEqual(controller.status, .listening)
        await controller.shutdown()
    }

    func testCancellationBetweenActionsWaitsForCleanupAndSkipsNextAction() async {
        let speech = FakeSpeech()
        var gate: CheckedContinuation<String, Never>?
        var count = 0
        let controller = VoiceController(config: config(), speech: speech, authorize: { true },
            interpret: { _, _ in (1...2).map { Decision(clause: "step \($0)", action: .openApp, targetApp: "Calculator", confidence: 1) } },
            execute: { _ in count += 1; return await withCheckedContinuation { gate = $0 } })
        controller.begin(); await settle(); controller.finish(); speech.emit(.final("two steps")); await settle()
        XCTAssertEqual(count, 1)
        controller.cancel()
        XCTAssertEqual(controller.status, .stopping)
        gate?.resume(returning: "first dispatched"); await settle()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(controller.status, .idle)
    }
}

private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}
