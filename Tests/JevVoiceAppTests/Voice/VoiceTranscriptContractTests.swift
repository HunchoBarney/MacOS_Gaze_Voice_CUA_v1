import XCTest
import JevVoiceCore
@testable import JevVoice

/// Contract tests for the transcript→command plumbing. A real failure had
/// the model hear "open calculator" but call computer_command with
/// app:"Calendar" while the transcript was sampled as a mid-turn partial —
/// the dispatch must now carry THIS turn's completed transcript
/// (transcriptHint), waiting briefly when the tool call outraces
/// input_audio_transcription.completed, and never waiting for typed turns.
/// Turns are scripted by injecting decoded events into `handle` and setting
/// the turn bookkeeping directly — no hardware, no socket.
@MainActor
final class VoiceTranscriptContractTests: XCTestCase {
    private func makeLane() -> RealtimeVoiceLane {
        RealtimeVoiceLane(apiKey: { "test-key" }, client: RealtimeVoiceClient())
    }
    /// Polls a condition up to `limit` — proves arrival *within* a bound
    /// instead of sleeping past it.
    private func until(_ limit: Duration = .milliseconds(400),
                       _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The tool call outracing the transcript is the reported bug: dispatch
    /// must hold (bounded) until .transcriptDone lands, then carry the FINAL
    /// text — "calculator", not the misheard "Calendar" in the call's args.
    func testCommandDispatchWaitsForFinalTranscript() async {
        let lane = makeLane()
        var transcripts: [String?] = []
        lane.commandHandler = { _, _, _, transcript, _, _ in
            transcripts.append(transcript)
            return #"{"status":"started","say":"On it."}"#
        }
        lane.turnID = UUID()
        lane.transcriptPending = true   // committed this turn; completion hasn't landed
        lane.handle(.functionCall(callID: "call_1", name: "computer_command",
                                  arguments: #"{"instruction":"open Calendar","app":"Calendar"}"#))
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(transcripts.isEmpty,
                      "dispatch must hold for the turn's transcript, not fire on arrival")
        lane.handle(.transcriptDone("open calculator", languages: ["en"], itemID: "item-1"))
        let dispatched = await until { transcripts.count == 1 }
        XCTAssertTrue(dispatched)
        XCTAssertEqual(transcripts.first ?? nil, "open calculator",
                       "transcriptHint must be the FINAL transcript")
        await lane.suspend()
    }

    /// The common order — transcript completed before the function call —
    /// must dispatch immediately with the stored text.
    func testCommandUsesAlreadyLandedTranscript() async {
        let lane = makeLane()
        var transcripts: [String?] = []
        lane.commandHandler = { _, _, _, transcript, _, _ in
            transcripts.append(transcript)
            return #"{"status":"started","say":"On it."}"#
        }
        lane.turnID = UUID()
        lane.transcriptPending = true
        lane.handle(.transcriptDone("press save", languages: [], itemID: "item-1"))
        lane.handle(.functionCall(callID: "call_1", name: "computer_command",
                                  arguments: #"{"instruction":"press save"}"#))
        let dispatched = await until { transcripts.count == 1 }
        XCTAssertTrue(dispatched)
        XCTAssertEqual(transcripts.first ?? nil, "press save")
        await lane.suspend()
    }

    /// Typed turns produce no input transcript — the dispatch must not
    /// wait at all, and the hint stays nil.
    func testTypedTurnDispatchNeverWaits() async {
        let lane = makeLane()
        var transcripts: [String?] = []
        lane.commandHandler = { _, _, _, transcript, _, _ in
            transcripts.append(transcript)
            return #"{"status":"started","say":"On it."}"#
        }
        lane.turnID = UUID()   // no commit, no transcriptPending — the typed shape
        lane.handle(.functionCall(callID: "call_1", name: "computer_command",
                                  arguments: #"{"instruction":"open Notes"}"#))
        let dispatched = await until(.milliseconds(300)) { transcripts.count == 1 }
        XCTAssertTrue(dispatched,
                      "a typed turn has no transcript coming — nothing to wait for")
        XCTAssertNil(transcripts.first ?? "non-nil")
        await lane.suspend()
    }

    /// A transcript that never arrives must not wedge the tool — the wait
    /// is capped near 600ms and the command still dispatches.
    func testTranscriptWaitIsBounded() async {
        let lane = makeLane()
        var transcripts: [String?] = []
        lane.commandHandler = { _, _, _, transcript, _, _ in
            transcripts.append(transcript)
            return #"{"status":"started","say":"On it."}"#
        }
        lane.turnID = UUID()
        lane.transcriptPending = true   // completion never lands
        lane.handle(.functionCall(callID: "call_1", name: "computer_command",
                                  arguments: #"{"instruction":"open Notes"}"#))
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(transcripts.isEmpty, "the wait should actually wait")
        let dispatched = await until(.milliseconds(1500)) { transcripts.count == 1 }
        XCTAssertTrue(dispatched,
                      "the transcript wait must be bounded — dispatch proceeds without it")
        XCTAssertNil(transcripts.first ?? "non-nil")
        await lane.suspend()
    }

    /// Only computer_command waits — respond_to_task/cancel_task carry no
    /// transcript and must dispatch immediately even mid-wait-window.
    func testNonCommandToolsNeverWait() async {
        let lane = makeLane()
        var answered = 0
        var cancelled = 0
        lane.taskResponseHandler = { _, _, _ in answered += 1; return "{}" }
        lane.cancelHandler = { _ in cancelled += 1; return "{}" }
        lane.turnID = UUID()
        lane.transcriptPending = true
        lane.handle(.functionCall(callID: "call_1", name: "respond_to_task",
                                  arguments: #"{"answer":"yes"}"#))
        lane.handle(.functionCall(callID: "call_2", name: "cancel_task",
                                  arguments: #"{}"#))
        let fired = await until(.milliseconds(300)) { answered == 1 && cancelled == 1 }
        XCTAssertTrue(fired, "non-command tools must not wait on the transcript")
        await lane.suspend()
    }

    /// A failed transcription settles the wait — the command dispatches
    /// promptly with no hint instead of burning the bound.
    func testTranscriptFailedSettlesTheWait() async {
        let lane = makeLane()
        var transcripts: [String?] = []
        lane.commandHandler = { _, _, _, transcript, _, _ in
            transcripts.append(transcript)
            return #"{"status":"started","say":"On it."}"#
        }
        lane.turnID = UUID()
        lane.transcriptPending = true
        lane.handle(.functionCall(callID: "call_1", name: "computer_command",
                                  arguments: #"{"instruction":"open Notes"}"#))
        try? await Task.sleep(for: .milliseconds(120))
        lane.handle(.transcriptFailed("transcription lost", itemID: "item-1"))
        let dispatched = await until(.milliseconds(300)) { transcripts.count == 1 }
        XCTAssertTrue(dispatched,
                      "a failed transcript must release the waiting dispatch")
        XCTAssertNil(transcripts.first ?? "non-nil")
        await lane.suspend()
    }

    /// A completion from a dead turn — different item id, or arriving
    /// before this turn's commit even went out — must not be stored as
    /// this turn's transcript.
    func testStaleTranscriptCompletionIsRejected() async {
        let lane = makeLane()
        lane.turnID = UUID()
        lane.transcriptPending = true
        lane.turnAudioItemID = "item-b"
        lane.handle(.transcriptDone("old turn's words", languages: [], itemID: "item-a"))
        XCTAssertNil(lane.turnTranscript,
                     "a completion for another item belongs to a dead turn")
        XCTAssertTrue(lane.transcriptPending, "the real transcript is still owed")
        lane.handle(.transcriptDone("open calculator", languages: [], itemID: "item-b"))
        XCTAssertEqual(lane.turnTranscript, "open calculator")
        XCTAssertFalse(lane.transcriptPending)
        await lane.suspend()

        // Pre-commit arrival: our item can't exist yet — reject on sight.
        let early = makeLane()
        early.turnID = UUID()   // hold streaming, release hasn't hit: pending unarmed
        early.handle(.transcriptDone("stale", languages: [], itemID: "item-a"))
        XCTAssertNil(early.turnTranscript)
        XCTAssertFalse(early.transcriptPending)
        await early.suspend()
    }

    /// The tool contract itself: steps exists for multi-part requests,
    /// required stays instruction-only, and `app` no longer offers the
    /// screenshot-defaulting that substituted Calendar for calculator.
    func testToolSchemaCarriesStepsAndVerbatimApp() {
        guard let command = RealtimeVoiceClient.toolDefinitions.first(where: {
            $0["name"] as? String == "computer_command"
        }), let params = command["parameters"] as? [String: Any],
            let props = params["properties"] as? [String: Any] else {
            XCTFail("computer_command schema missing")
            return
        }
        XCTAssertEqual(params["required"] as? [String], ["instruction"])
        let steps = props["steps"] as? [String: Any]
        XCTAssertEqual(steps?["type"] as? String, "array")
        XCTAssertEqual((steps?["items"] as? [String: Any])?["type"] as? String, "string")
        let app = props["app"] as? [String: Any]
        XCTAssertEqual(app?["description"] as? String,
                       "The app the user named, transcribed exactly as spoken. Omit when the user didn't name an app.")
        XCTAssertFalse((app?["description"] as? String ?? "").contains("screenshot"),
                       "app must not default from the screenshot — that produced Calendar")
        XCTAssertTrue(RealtimeVoiceClient.instructions.contains("steps"),
                      "instructions must tell the model to fill steps")
    }

    /// The controller's wiring carries the lane-supplied transcript through
    /// to the runtime — the 5-arg path returns the tool's JSON ack.
    func testControllerCommandHandlerCarriesTranscript() async {
        let config = Config(defaults: UserDefaults(suiteName: "test.transcript.\(UUID())")!,
                            keyStore: MemoryKeyStore(), openAIKeyStore: MemoryKeyStore(),
                            environment: ["JARVIS_PLANNER": "0"])
        let lane = RealtimeVoiceLane(apiKey: { "test-key" }, client: RealtimeVoiceClient())
        let controller = VoiceController(config: config, speech: lane,
                                         authorize: { true },
                                         frontmost: { "Fixture" },
                                         cuaRuntime: CuaVoiceRuntime(config: config,
                                                                   screenLocked: { false }))
        let reply = await lane.commandHandler("open Fixture", "Fixture",
                                              nil, "open Fixture", [], UUID())
        XCTAssertTrue(reply.contains("\"status\""),
                      "the wired handler must reach the runtime and return its JSON ack")
        await controller.shutdown()
    }
}

private final class MemoryKeyStore: APIKeyStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}
