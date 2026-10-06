import XCTest
import JevVoiceCore
@testable import JevVoice

/// Scripted sink: records writes but the test drives its counters — a write
/// that never reaches consumedMs/droppedMs simulates a failed convert.
private final class FakeRenderSink: RealtimeRenderSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _consumed = 0.0
    private var _dropped = 0.0
    var consumedMs: Double { lock.lock(); defer { lock.unlock() }; return _consumed }
    var droppedMs: Double { lock.lock(); defer { lock.unlock() }; return _dropped }
    var onDrained: (@Sendable () -> Void)?
    var received = 0
    func set(consumed: Double, dropped: Double) {
        lock.lock(); _consumed = consumed; _dropped = dropped; lock.unlock()
    }
    func enqueue(_ pcm: Data) { received += 1 }
    func flush() {}
}

private final class IdleSpeech: SpeechCapturing {
    var onEvent: ((UUID, SpeechEvent) -> Void)?
    func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
        "Test microphone"
    }
    func finish() {}
    func cancel() {}
}

/// Regression coverage for the realtime lane's barge-in/turn bookkeeping.
/// The socket is scripted by injecting decoded events into `handle` and the
/// turn/response bookkeeping is set directly — no hardware, no connection.
@MainActor
final class VoiceLaneHuntTests: XCTestCase {
    private func makeLane() -> RealtimeVoiceLane {
        RealtimeVoiceLane(apiKey: { "test-key" }, client: RealtimeVoiceClient())
    }
    private func settle() async { for _ in 0..<80 { await Task.yield() } }
    private func controller(_ speech: SpeechCapturing,
                            authorize: @escaping () async -> Bool) -> VoiceController {
        let config = Config(defaults: UserDefaults(suiteName: "test.hunt.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(),
                            environment: ["JARVIS_PLANNER": "0"])
        return VoiceController(config: config, speech: speech, authorize: authorize,
                               frontmost: { "Fixture" },
                               cuaRuntime: CuaVoiceRuntime(config: config, screenLocked: { false }))
    }

    /// A cancelled response's response.done still carries its function_call
    /// items, and a function_call_arguments.done can land after the cancel —
    /// neither may dispatch under the new hold, and the same call_id must
    /// never run commandHandler twice for the socket's lifetime.
    func testCancelledResponseCallsDoNotRedispatchUnderNewHold() async {
        let lane = makeLane()
        var commands: [String] = []
        lane.commandHandler = { instruction, _, _, _, _, _ in
            commands.append(instruction)
            return #"{"status":"started","say":"On it."}"#
        }
        lane.turnID = UUID()
        lane.handle(.functionCall(callID: "call_1", name: "computer_command",
                                  arguments: #"{"instruction":"send it"}"#))
        await settle()
        XCTAssertEqual(commands, ["send it"])

        // Barge-in: response.cancel goes out for the in-flight response.
        lane.responseInFlight = true
        lane.cancel()
        lane.turnID = UUID()
        // The cancelled done re-carries call_1, plus a call whose
        // arguments.done never arrived before the cancel.
        lane.handle(.functionCall(callID: "call_1", name: "computer_command",
                                  arguments: #"{"instruction":"send it"}"#))
        lane.handle(.functionCall(callID: "call_2", name: "computer_command",
                                  arguments: #"{"instruction":"late call"}"#))
        await settle()
        XCTAssertEqual(commands, ["send it"],
                       "a cancelled response's trailing calls must not execute under the new hold")

        // The cancelled response's done lifts the suppression — and call_1
        // still dedupes because handledCalls outlives the hold.
        lane.handle(.responseDone)
        lane.handle(.functionCall(callID: "call_1", name: "computer_command",
                                  arguments: #"{"instruction":"send it"}"#))
        lane.handle(.functionCall(callID: "call_2", name: "computer_command",
                                  arguments: #"{"instruction":"late call"}"#))
        await settle()
        XCTAssertEqual(commands, ["send it", "late call"])
        await lane.suspend()
    }

    /// Release-before-cancel-ack: this turn's response.create was still
    /// queued when the cancelled response's done arrived — the done must not
    /// emit .turnEnded and hide the card before the reply was requested.
    func testForeignResponseDoneDoesNotEndTurnEarly() async {
        let lane = makeLane()
        let id = UUID()
        var ended = 0
        lane.onEvent = { eid, event in
            if eid == id, case .turnEnded = event { ended += 1 }
        }
        lane.turnID = id
        lane.awaitingTurnEnd = true
        lane.handle(.responseDone)   // belongs to the cancelled response
        XCTAssertEqual(ended, 0, "a done for another response must not end the turn")
        XCTAssertEqual(lane.turnID, id)

        // Once THIS turn's response.create actually went out, its done ends it.
        lane.turnResponseOutstanding = true
        lane.handle(.responseDone)
        XCTAssertEqual(ended, 1)
        XCTAssertNil(lane.turnID, "turnID releases when the turn ends")
        await lane.suspend()
    }

    /// A queued outcome whose text landed but whose response.create never
    /// went out must move to the retry queue on socket death — not vanish.
    func testClosedSocketMigratesQueuedSpeaksToRetry() async {
        let lane = makeLane()
        lane.speakQueue = ["outcome one", "outcome two"]
        lane.handle(.closed)
        XCTAssertEqual(lane.retryOutcomePush.items, ["outcome one", "outcome two"])
        XCTAssertTrue(lane.speakQueue.isEmpty)
        await lane.suspend()
    }

    /// Dictation commits request no response — a failed transcription is the
    /// turn's terminal event, or the card sits .finishing until the deadline.
    /// Command mode still shrugs off a lost caption.
    func testTranscriptionFailureEndsNoResponseCommitOnly() async {
        let lane = makeLane()
        lane.respondOnCommit = false
        let id = UUID()
        var terminal: SpeechEvent?
        lane.onEvent = { eid, event in
            guard eid == id else { return }
            if case .failure = event { terminal = event }
            if case .final = event { terminal = event }
        }
        lane.turnID = id
        lane.transcriptPending = true   // the turn committed; a completion is owed
        lane.handle(.transcriptFailed("transcription unavailable"))
        guard case .failure = terminal else {
            XCTFail("a transcript-only commit must end with a terminal event, not wedge")
            await lane.suspend(); return
        }
        XCTAssertNil(lane.turnID)
        await lane.suspend()

        let quiet = makeLane()
        let quietID = UUID()
        var stray: [SpeechEvent] = []
        quiet.onEvent = { eid, event in if eid == quietID { stray.append(event) } }
        quiet.turnID = quietID
        quiet.transcriptPending = true   // command-mode turn, commit already out
        quiet.handle(.transcriptFailed("still listening"))
        XCTAssertTrue(stray.isEmpty, "the response path keeps the turn alive — caption only")
        await quiet.suspend()
    }

    /// Post-turn idle: a socket that dies after the turn ended must not
    /// fault the closed capture (and takes the auto-reconnect path instead).
    func testSocketDeathAfterTurnEndDoesNotFaultClosedCapture() async {
        let lane = makeLane()
        let id = UUID()
        var failures: [String] = []
        lane.onEvent = { eid, event in
            if eid == id, case .failure(let message) = event { failures.append(message) }
        }
        lane.turnID = id
        lane.awaitingTurnEnd = true
        lane.turnResponseOutstanding = true
        lane.handle(.responseDone)   // .turnEnded fires; turnID releases
        lane.handle(.closed)
        XCTAssertTrue(failures.isEmpty)
        await lane.suspend()
    }

    /// The truncate point is per-item heard audio — the previous item's
    /// unplayed remainder (ring-dropped or still buffered) must not count
    /// against the current item's played ms.
    func testTruncateReportsHeardAudioNotScheduledLedger() async throws {
        let player = RealtimePlayer()
        let sink = FakeRenderSink()
        player.attachSink(sink)
        try await Task.sleep(for: .milliseconds(60))
        player.enqueue(Data(count: 24000), itemID: "item-a")   // 500ms of audio
        try await Task.sleep(for: .milliseconds(60))
        // The user heard 300ms of item-a; its last 200ms died in the ring.
        sink.set(consumed: 300, dropped: 200)
        sink.onDrained?()
        try await Task.sleep(for: .milliseconds(60))
        player.enqueue(Data(count: 9600), itemID: "item-b")
        try await Task.sleep(for: .milliseconds(60))
        // 200ms of item-b actually rendered before the barge-in.
        sink.set(consumed: 500, dropped: 200)
        sink.onDrained?()
        try await Task.sleep(for: .milliseconds(60))
        let interrupted = player.interrupt()
        XCTAssertEqual(interrupted.itemID, "item-b")
        XCTAssertEqual(interrupted.playedMs, 200,
                       "audio_end_ms must report what item-b the user heard")
        player.stop()
    }

    /// A sink write that never reaches either ledger (failed convert) used to
    /// wedge playbackIdle behind the 25s drain deadline — the stall bound
    /// resolves it instead.
    func testUnledgeredSinkWriteStillResolvesTheDrainWait() async throws {
        let player = RealtimePlayer()
        let sink = FakeRenderSink()   // swallows every write: counters never move
        player.attachSink(sink)
        try await Task.sleep(for: .milliseconds(60))
        player.enqueue(Data(count: 4800), itemID: "item-a")   // 100ms of audio
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(player.playbackIdle)
        try await Task.sleep(for: .milliseconds(2500))
        XCTAssertTrue(player.playbackIdle,
                      "frozen sink counters must resolve the drain wait")
        player.stop()
    }

    /// An ignored permission prompt parks authorize() forever — the cancelled
    /// startup must still unwind so cleanupTask releases the capture slot and
    /// Fn isn't bricked until restart. The box resolves the parked authorize
    /// once cancellation has been proven to escape it.
    func testCancelledStartupAtPermissionPromptReleasesCaptureSlot() async {
        final class ParkedAuth { var pending: CheckedContinuation<Bool, Never>? }
        let parked = ParkedAuth()
        let c = controller(IdleSpeech()) {
            await withCheckedContinuation { parked.pending = $0 }
        }
        c.begin()
        await settle()
        XCTAssertEqual(c.status, .starting)
        c.cancel()
        for _ in 0..<200 where !c.canBegin { await Task.yield() }
        XCTAssertTrue(c.canBegin, "a parked startup must not keep cleanupTask — and Fn — stuck")
        parked.pending?.resume(returning: false)
        await c.shutdown()
    }
}

private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}
