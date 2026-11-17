import AVFoundation
import Synchronization
import XCTest
@testable import JevVoice

/// Contract: the realtime lane's turn bookkeeping and tool-result wire
/// shape, exercised without a socket — `handle()` drives decoded events
/// directly, the internal-for-tests fields script the turn state, and the
/// static helpers pin the JSON contract.
@MainActor
final class RealtimeVoiceLaneTests: XCTestCase {

    private func recordedPCM() async throws -> Data {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".agent/results/P3/audio")
        let manifest = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw XCTSkip("Private confirmed recording unavailable")
        }
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let recordings = try XCTUnwrap(document["recordings"] as? [[String: Any]])
        let recording = try XCTUnwrap(recordings.last {
            $0["id"] as? String == "h15" && $0["confirmed"] as? Bool == true
        })
        let name = try XCTUnwrap(recording["wav"] as? String)
        XCTAssertEqual(URL(fileURLWithPath: name).lastPathComponent, name)
        let source = try AVAudioFile(forReading: directory.appendingPathComponent(name))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 24_000, channels: 1, interleaved: true))
        let feed = try ConvertedAudioFeed(input: source.processingFormat, output: format)
        let collected = Task { @MainActor in
            var bytes = Data()
            for try await buffer in feed.stream { bytes.append(try VoicePCMFrame(copying: buffer).bytes) }
            return bytes
        }
        defer { feed.finish(); collected.cancel() }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096))
        try source.read(into: buffer)
        feed.append(buffer)
        feed.finish()
        let pcm = try await collected.value
        XCTAssertGreaterThan(pcm.count, 48)
        return pcm
    }

    func testRoutedPlaybackRejectsOldCompletionsAndUnavailableOutput() async throws {
        let pcm = try await recordedPCM()
        typealias Completion = @Sendable () -> Void
        let callbacks = Mutex<[Completion]>([])
        let bytes = Mutex<[Data]>([])
        let first = expectation(description: "first routed buffer")
        let second = expectation(description: "second routed buffer")
        let unavailable = expectation(description: "unavailable route rejected")
        let alive = LockedBox(true)
        let output = RealtimePlayer()
        defer { output.stop() }
        output.onPlaybackUnavailable = { unavailable.fulfill() }
        output.setPlaybackRoute(VoicePlaybackRoute(id: UUID(), isReady: { alive.value },
            schedule: { data, completed in
                bytes.withLock { $0.append(data) }
                let count = callbacks.withLock { stored in stored.append(completed); return stored.count }
                if count == 1 { first.fulfill() }
                if count == 2 { second.fulfill() }
            }, play: {}, stop: {}))
        let priorOwner = output.generationToken
        output.enqueue(pcm, itemID: "prior")
        await fulfillment(of: [first], timeout: 2)
        XCTAssertFalse(output.playbackIdle)
        _ = output.interrupt()
        output.enqueue(pcm, itemID: "prior")
        output.enqueue(pcm, itemID: "current")
        await fulfillment(of: [second], timeout: 2)
        let completions = callbacks.withLock { $0 }
        XCTAssertEqual(completions.count, 2)
        guard completions.count == 2 else { return }
        _ = output.interrupt(owner: priorOwner)
        XCTAssertFalse(output.playbackIdle)
        completions[0]()
        XCTAssertFalse(output.playbackIdle)
        XCTAssertEqual(output.playedMilliseconds(), 0)
        completions[1]()
        XCTAssertTrue(output.playbackIdle)
        XCTAssertEqual(output.playedMilliseconds(), Int((Double(pcm.count) / 48).rounded(.down)))
        alive.set(false)
        output.enqueue(pcm, itemID: "unavailable")
        await fulfillment(of: [unavailable], timeout: 2)
        XCTAssertEqual(bytes.withLock { $0 }, [pcm, pcm])
    }

    private func lane() -> RealtimeVoiceLane { RealtimeVoiceLane(apiKey: { "test-key" }) }

    // MARK: - tool-result contract

    /// A started task suppresses the follow-up response — the check decodes
    /// the JSON contract, never substring-sniffs.
    func testStartedToolResultDecodesStatusProperly() {
        XCTAssertTrue(RealtimeVoiceLane.isStartedToolResult(
            #"{"status":"started","say":"Opening Safari."}"#))
        // A "say" that happens to quote 'started' must not false-positive.
        XCTAssertFalse(RealtimeVoiceLane.isStartedToolResult(
            #"{"status":"ok","say":"It already started."}"#))
        // The dead bare-STARTED prefix stays dead — no producer ships it.
        XCTAssertFalse(RealtimeVoiceLane.isStartedToolResult("STARTED — opening Safari"))
        XCTAssertFalse(RealtimeVoiceLane.isStartedToolResult("plain text"))
        XCTAssertFalse(RealtimeVoiceLane.isStartedToolResult(#"{"say":"no status"}"#))
    }

    /// Unknown tool names still answer on the wire contract — JSON with a
    /// verbatim `say`, never bare text.
    func testUnknownToolOutputIsContractJSON() {
        let output = RealtimeVoiceLane.unknownToolOutput("invented_tool")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(output.utf8)))
        let parsed = VoiceToolResult(jsonString: output)
        XCTAssertEqual(parsed?.status, VoiceToolResult.Status.refused)
        XCTAssertFalse((parsed?.say ?? "").isEmpty)
    }

    // MARK: - cancelled-response shield

    /// While a response.cancel is outstanding, its trailing calls must not
    /// dispatch — and once the done lands the next turn's calls must flow.
    func testUnenvelopedCallsStayBlockedEvenAfterLegacyShieldClears() async {
        let lane = lane()
        var dispatched: [String] = []
        lane.commandHandler = { _, _, _, _, _, _ in
            dispatched.append("call")
            return #"{"status":"refused","say":"No."}"#
        }
        lane.turnID = UUID()
        lane.cancelledResponsePending = true
        lane.handle(.functionCall(callID: "stale-1", name: "computer_command", arguments: "{}"))
        XCTAssertTrue(dispatched.isEmpty, "a cancelled response's call must not dispatch")

        lane.handle(.responseDone)
        XCTAssertFalse(lane.cancelledResponsePending)

        lane.handle(.functionCall(callID: "live-1", name: "computer_command",
                                  arguments: #"{"instruction":"open Safari"}"#))
        // dispatchTool's Task runs on this actor — yield for it.
        for _ in 0..<20 where dispatched.isEmpty { await Task.yield() }
        XCTAssertEqual(dispatched.count, 0, "clearing a timing shield is not response/turn authority")
    }

    // MARK: - dictation item cleanup

    /// A settled dictation turn emits `.final` for delivery AND drops the
    /// tracked audio item so it can be deleted from the conversation.
    func testUnscopedTranscriptCannotSupplyDictationAndLegacyFinalStaysLiteral() async {
        let lane = lane()
        var events: [SpeechEvent] = []
        let id = UUID()
        lane.onEvent = { _, event in events.append(event) }
        lane.respondOnCommit = false
        lane.turnID = id
        lane.transcriptPending = true
        lane.turnAudioItemID = "audio-item-1"

        lane.handle(.transcriptDone("hello there", languages: [], itemID: "audio-item-1"))

        XCTAssertTrue(events.isEmpty, "an unscoped event has no input-item or commit authority")
        XCTAssertNil(lane.turnTranscript)
        let session = LocalSpeechSession { _ in XCTFail("dictation must not execute a command") }
        let token = session.begin(mode: .dictation, ready: true, now: 0)
        XCTAssertTrue(session.acceptFrame(token, sequence: 0))
        XCTAssertTrue(session.release(token, now: 1))
        let final = await session.finalize("open Calculator", turn: token, drainedFrames: 1, now: 1.1)
        XCTAssertEqual(final?.route, .dictation)
        XCTAssertEqual(final?.text, "open Calculator")
    }

    /// A stale completion carrying a foreign item id belongs to a dead
    /// turn — it must not settle this turn's transcript (or delete).
    func testForeignTranscriptCompletionIsRejected() {
        let lane = lane()
        var events: [SpeechEvent] = []
        let id = UUID()
        lane.onEvent = { _, event in events.append(event) }
        lane.respondOnCommit = false
        lane.turnID = id
        lane.transcriptPending = true
        lane.turnAudioItemID = "this-turn"

        lane.handle(.transcriptDone("stale words", languages: [], itemID: "other-turn"))

        XCTAssertTrue(lane.transcriptPending, "a foreign item must not settle the pending transcript")
        XCTAssertNil(lane.turnTranscript)
        XCTAssertEqual(lane.turnAudioItemID, "this-turn")
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - turn end

    /// This turn's own response.done ends the interaction — a queued or
    /// cancelled response's done must not.
    func testResponseDoneEndsLiveTurn() {
        let lane = lane()
        var events: [SpeechEvent] = []
        let id = UUID()
        lane.onEvent = { _, event in events.append(event) }
        lane.turnID = id
        lane.awaitingTurnEnd = true
        lane.turnResponseOutstanding = true

        lane.handle(.responseDone)

        XCTAssertNil(lane.turnID)
        guard case .turnEnded = events.last else {
            return XCTFail("the turn's own done must emit .turnEnded, got \(events)")
        }
    }

    /// A done for a response this turn never sent (queued push, cancelled
    /// predecessor) keeps the interaction open.
    func testUnrelatedResponseDoneKeepsTurnOpen() {
        let lane = lane()
        var events: [SpeechEvent] = []
        let id = UUID()
        lane.onEvent = { _, event in events.append(event) }
        lane.turnID = id
        lane.awaitingTurnEnd = true
        lane.turnResponseOutstanding = false

        lane.handle(.responseDone)

        XCTAssertEqual(lane.turnID, id)
        XCTAssertFalse(events.contains { if case .turnEnded = $0 { return true }; return false })
    }

    // MARK: - dead-socket outcome migration

    /// A dead socket re-queues unsent outcome pushes for the next session —
    /// verified results must never silently vanish.
    func testClosedMigratesSpeakQueueToRetry() {
        let lane = lane()
        lane.speakQueue = [("outcome one", 0), ("outcome two", 2)]
        lane.handle(.closed)
        XCTAssertTrue(lane.speakQueue.isEmpty)
        XCTAssertEqual(lane.retryOutcomePush.items.map { $0.text }, ["outcome one", "outcome two"])
        XCTAssertEqual(lane.retryOutcomePush.items.map { $0.attempts }, [0, 2])
    }

    // MARK: - frame decode batching

    /// response.done carries its function calls in one frame — the decode
    /// emits calls before the done so pendingCalls is populated when the
    /// lane decides whether the turn ended.
    func testResponseDoneDecodesCallsBeforeDone() {
        let payload = #"{"type":"response.done","response":{"status":"completed","output":[{"type":"function_call","call_id":"c1","name":"computer_command","arguments":"{}"}]}}"#
        let events = RealtimeVoiceClient.decode(payload)
        XCTAssertEqual(events.count, 2)
        guard case .functionCall(let callID, let name, _) = events[0] else {
            return XCTFail("first event must be the call, got \(events)")
        }
        XCTAssertEqual(callID, "c1")
        XCTAssertEqual(name, "computer_command")
        guard case .responseDone = events[1] else {
            return XCTFail("responseDone must land last, got \(events)")
        }
    }

    // MARK: - schema honesty

    /// respond_to_task's `task` hint declares the ordinal direction —
    /// 'first' is the longest-waiting parked ask, 'last' the newest.
    func testRespondToTaskSchemaRequiresStableTaskAndAskIdentities() {
        guard let tool = RealtimeVoiceClient.toolDefinitions.first(where: {
            ($0["name"] as? String) == "respond_to_task"
        }), let parameters = tool["parameters"] as? [String: Any],
            let properties = parameters["properties"] as? [String: Any],
            let required = parameters["required"] as? [String]
        else { return XCTFail("respond_to_task schema changed shape") }
        XCTAssertNotNil(properties["task_id"])
        XCTAssertNotNil(properties["ask_id"])
        XCTAssertNil(properties["task"])
        XCTAssertEqual(Set(required), Set(["task_id", "ask_id", "response"]))
    }

    // MARK: - capture seam (Lane 4's dwell suppressor + Escape gate)

    /// In-memory key store — Config's init probes the store; tests never
    /// touch the real Keychain.
    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func testConfig() -> Config {
        let suite = "realtime-lane-\(UUID().uuidString)"
        return Config(defaults: UserDefaults(suiteName: suite)!,
                      keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                      environment: [:])
    }

    /// A bound lane turn makes the interaction live even when the card's
    /// status never entered a capture state (a typed turn in flight, or a
    /// committed turn sitting at .executing) — Escape reaches it and the
    /// dwell suppressor sees it.
    func testCaptureActiveTracksBoundTurn() {
        let config = testConfig()
        let coordinator = VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: {
                AsyncThrowingStream { _ in }
            })))
        let lane = lane()
        let controller = VoiceController(config: config, speech: lane,
                                         authorize: { true }, cuaRuntime: coordinator)
        XCTAssertFalse(controller.captureActive)
        XCTAssertFalse(controller.operationActive)

        lane.turnID = UUID()
        XCTAssertTrue(controller.captureActive,
                      "a bound lane turn is a live capture turn for dwell + Escape")
        XCTAssertTrue(controller.operationActive,
                      "Escape must be consumable while a turn is in flight")

        lane.turnID = nil
        XCTAssertFalse(controller.captureActive)
    }

    /// The dwell suppressor reaches the live capture through the shared
    /// seam — Lane 4 reads `VoiceController.shared?.captureActive`.
    func testSharedSeamExposesTheController() {
        let config = testConfig()
        let coordinator = VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: {
                AsyncThrowingStream { _ in }
            })))
        let lane = lane()
        let controller = VoiceController(config: config, speech: lane,
                                         authorize: { true }, cuaRuntime: coordinator)
        XCTAssertTrue(VoiceController.shared === controller)
    }
}
