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
        let controller = VoiceController(config: config(), speech: speech, authorize: { true })
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
        let controller = VoiceController(config: config(), speech: speech, authorize: { true })
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
