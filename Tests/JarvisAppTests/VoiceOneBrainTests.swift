import Foundation
import XCTest
import JarvisCore
@testable import Jarvis

/// Protocol fixtures replace only the remote wire. They are not ASR/acoustic evidence.
private actor RecordedVoiceWire: RealtimeVoiceWire {
    private var incoming: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private var written: [JSONValue] = []
    private var responses: [String] = []
    private var failTextSends = false
    private var commits = 0
    private var holdCommits = false
    private var held: [(item: String, eventID: String?)] = []
    private let identity = UUID().uuidString
    private let acknowledgeUpdates: Bool
    private let sessionAcknowledgement: JSONValue?

    init(acknowledgeUpdates: Bool = true, sessionAcknowledgement: JSONValue? = nil) {
        self.acknowledgeUpdates = acknowledgeUpdates
        self.sessionAcknowledgement = sessionAcknowledgement
    }

    func send(_ text: String) throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        written.append(frame)
        if failTextSends, frame["type"]?.string == "conversation.item.create",
           frame["item"]?["role"]?.string == "user" {
            throw VoiceError("Fixture text send failed.")
        }
        switch frame["type"]?.string {
        case "session.update":
            if acknowledgeUpdates {
                try push(["type": .string("session.updated"),
                          "session": sessionAcknowledgement ?? frame["session"] ?? .null])
            }
        case "conversation.item.create":
            if let id = frame["item"]?["id"]?.string {
                try push(["type": .string("conversation.item.created"), "item": .object(["id": .string(id)])])
            }
        case "input_audio_buffer.commit":
            commits += 1
            if holdCommits {
                held.append((audioItemID(), frame["event_id"]?.string))
            } else {
                try push(["type": .string("input_audio_buffer.committed"), "item_id": .string(audioItemID())])
            }
        case "response.create":
            let id = identity + "-\(responses.count + 1)"
            responses.append(id)
            try push(["type": .string("response.created"), "response": .object(["id": .string(id)])])
        default: break
        }
    }

    func receive() async throws -> String {
        if !incoming.isEmpty { return incoming.removeFirst() }
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }

    func push(_ object: [String: JSONValue]) throws {
        let data = try JSONEncoder().encode(JSONValue.object(object))
        let text = String(decoding: data, as: UTF8.self)
        if let waiter { self.waiter = nil; waiter.resume(returning: text) }
        else { incoming.append(text) }
    }

    func responseIDs() -> [String] { responses }
    func frames() -> [JSONValue] { written }
    /// Each commit names a fresh input item, as the server does.
    func audioItemID() -> String { "audio-\(identity)-\(commits)" }
    func commitCount() -> Int { written.filter { $0["type"]?.string == "input_audio_buffer.commit" }.count }
    func setTextSendFailure(_ value: Bool) { failTextSends = value }
    /// Held commits wait for confirmHeld or rejectHeld, oldest first.
    func setHoldCommits(_ value: Bool) { holdCommits = value }
    @discardableResult
    func confirmHeld() throws -> String {
        let commit = held.removeFirst()
        try push(["type": .string("input_audio_buffer.committed"), "item_id": .string(commit.item)])
        return commit.item
    }
    func rejectHeld() throws {
        let commit = held.removeFirst()
        try push(["type": .string("error"), "error": .object([
            "type": .string("invalid_request_error"), "message": .string("Commit refused."),
            "event_id": .string(commit.eventID ?? "")])])
    }
}

@MainActor
final class VoiceOneBrainTests: XCTestCase {
    private func context() -> VoiceAdmissionContext {
        var value = VoiceAdmissionContext()
        value.targetID = "fixture.window"; value.windowID = 100; value.editableTarget = true
        value.entities = [.init(name: "Calculator", id: "com.apple.calculator", canOpenLocally: true),
                          .init(name: "GitHub", id: "site.github", canOpenLocally: false)]
        return value
    }

    private func waitFor(_ check: @MainActor () async -> Bool, file: StaticString = #filePath,
                         line: UInt = #line) async {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < until {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("production wire/lane condition timed out", file: file, line: line)
    }

    private func function(_ response: String, call: String, goal: String) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(JSONValue.object(["goal": .string(goal)]))
        return ["type": .string("response.function_call_arguments.done"), "response_id": .string(response),
                "call_id": .string(call), "name": .string("computer_task"),
                "arguments": .string(String(decoding: data, as: UTF8.self))]
    }

    func testC1RealtimeSessionLeavesTurnEndsToTheMacAndUsesAuthoritativeInputTranscription() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        defer { client.teardown() }
        try await client.connect(apiKey: "fixture-not-a-real-key")
        let frames = await wire.frames()
        let session = try XCTUnwrap(frames.first { $0["type"]?.string == "session.update" }?["session"])
        let input = try XCTUnwrap(session["audio"]?["input"])
        XCTAssertEqual(input["turn_detection"], .null, "hands-free turns end on the Mac, not by server VAD")
        XCTAssertEqual(input["transcription"]?["model"]?.string, "gpt-4o-transcribe")
        XCTAssertNil(input["transcription"]?["language"])
        XCTAssertEqual(input["format"]?["rate"]?.integer, 24_000)
        XCTAssertFalse(frames.contains { $0["type"]?.string == "response.create" })
        XCTAssertFalse(frames.contains { $0["type"]?.string == "input_audio_buffer.append" })
    }

    /// Hands-free turns end on the Mac: each local end sends one commit, the
    /// server's `committed` binds the oldest waiting turn to its fresh item,
    /// and that item's transcript finishes the turn once, in speaking order.
    func testC1RealtimeConversationCommitsEachLocalTurnOnceAndBindsTheServerItem() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        var context = self.context()
        context.targetAppID = "fixture.editor"
        var executed: [String] = [], began = 0
        lane.conversation.readContext = { context }
        lane.conversation.interpret = { _, _, _ in
            XCTFail("native scroll must not require remote reasoning")
            return .init(kind: .clarify)
        }
        lane.conversation.execute = { command in
            executed.append(command.text)
            return .init(verified: true, waitingForAnswer: false, message: "")
        }
        lane.conversation.onControl = { _ in }
        lane.conversation.onEvent = { if case .began = $0 { began += 1 } }
        try await lane.prepareRealtimeTransport(.conversation)
        try lane.beginRealtimeConversation(session: UUID())
        let connection = client.connectionID
        func final(_ item: String, _ text: String) -> [String: JSONValue] {
            ["type": .string("conversation.item.input_audio_transcription.completed"),
             "item_id": .string(item), "transcript": .string(text)]
        }

        lane.localTurnStarted(connection: connection)
        lane.localTurnStarted(connection: connection)
        XCTAssertEqual(began, 1, "one utterance is one turn")
        let commitsBefore = await wire.commitCount()
        XCTAssertEqual(commitsBefore, 0, "nothing is committed while the person is speaking")
        try await lane.localTurnEnded(connection: connection)
        try await lane.localTurnEnded(connection: connection)
        let first = await wire.audioItemID()
        lane.localTurnStarted(connection: connection)
        try await lane.localTurnEnded(connection: connection)
        let second = await wire.audioItemID()
        let commits = await wire.commitCount()
        XCTAssertEqual(commits, 2, "exactly one commit per turn")
        XCTAssertNotEqual(first, second)

        try await wire.push(final(second, "scroll up"))
        try await wire.push(final(first, "scroll down"))
        await waitFor { executed.count == 2 }
        try await wire.push(["type": .string("input_audio_buffer.committed"), "item_id": .string("stray")])
        try await wire.push(final("stray", "open Calculator"))
        try await wire.push(final(first, "scroll down"))
        try await wire.push(["type": .string("input_audio_buffer.committed"), "item_id": .string(first)])
        try await wire.push(final(second, "scroll up"))
        try await Task.sleep(for: .milliseconds(150))
        lane.stopConversation()
        XCTAssertEqual(executed, ["scroll down", "scroll up"], "turns finish in speaking order, each once")
        XCTAssertEqual(began, 2)
        client.teardown()
    }

    private func scriptedConversation(_ wire: RecordedVoiceWire) async throws
        -> (lane: RealtimeVoiceLane, client: RealtimeVoiceClient, executed: () -> [String]) {
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        var context = self.context()
        context.targetAppID = "fixture.editor"
        var executed: [String] = []
        lane.conversation.readContext = { context }
        lane.conversation.interpret = { _, _, _ in .init(kind: .clarify) }
        lane.conversation.execute = { command in
            executed.append(command.text)
            return .init(verified: true, waitingForAnswer: false, message: "")
        }
        lane.conversation.onControl = { _ in }
        try await lane.prepareRealtimeTransport(.conversation)
        try lane.beginRealtimeConversation(session: UUID())
        return (lane, client, { executed })
    }

    private func transcript(_ item: String, _ text: String) -> [String: JSONValue] {
        ["type": .string("conversation.item.input_audio_transcription.completed"),
         "item_id": .string(item), "transcript": .string(text)]
    }

    /// A turn whose commit is confirmed after it expired keeps its place in
    /// the queue: the late confirmation is dropped, never bound to the next
    /// turn, and that turn still gets its own item and transcript.
    func testALateCommitConfirmationNeverBindsTheNextTurn() async throws {
        let wire = RecordedVoiceWire()
        await wire.setHoldCommits(true)
        let (lane, client, executed) = try await scriptedConversation(wire)
        lane.commitConfirmationTimeout = .milliseconds(300)
        let connection = client.connectionID

        lane.localTurnStarted(connection: connection)
        try await lane.localTurnEnded(connection: connection)
        try await Task.sleep(for: .milliseconds(450))
        lane.localTurnStarted(connection: connection)
        try await lane.localTurnEnded(connection: connection)
        let late = try await wire.confirmHeld()
        let current = try await wire.confirmHeld()
        try await wire.push(transcript(late, "scroll down"))
        try await wire.push(transcript(current, "scroll up"))
        await waitFor { executed().count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        lane.stopConversation()
        XCTAssertEqual(executed(), ["scroll up"], "the expired turn's late confirmation and transcript are dropped")
        client.teardown()
    }

    /// A refused commit never gets a confirmation, so its slot must leave
    /// the queue; otherwise the next turn's confirmation would be eaten.
    func testARejectedCommitFreesItsPlaceForTheNextTurn() async throws {
        let wire = RecordedVoiceWire()
        await wire.setHoldCommits(true)
        let (lane, client, executed) = try await scriptedConversation(wire)
        let connection = client.connectionID

        lane.localTurnStarted(connection: connection)
        try await lane.localTurnEnded(connection: connection)
        let frames = await wire.frames()
        XCTAssertNotNil(frames.last { $0["type"]?.string == "input_audio_buffer.commit" }?["event_id"]?.string,
                        "each commit carries its turn's event id")
        try await wire.rejectHeld()
        lane.localTurnStarted(connection: connection)
        try await lane.localTurnEnded(connection: connection)
        let item = try await wire.confirmHeld()
        try await wire.push(transcript(item, "scroll up"))
        await waitFor { executed().count == 1 }
        lane.stopConversation()
        XCTAssertEqual(executed(), ["scroll up"])
        client.teardown()
    }

    func testC1RealtimeDictationUsesMatchingInputOnceWithoutCreatingResponseOrTool() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        var deliveries: [String] = []
        lane.onEvent = { _, event in if case .final(let text) = event { deliveries.append(text) } }
        lane.commandHandler = { _, _, _, _, _, _ in XCTFail("dictation must not execute"); return "{}" }
        try await lane.prepareRealtimeTransport(.manual)
        let turn = try lane.beginRemoteManualInput(id: UUID(), mode: .dictation, context: context(), at: 0)
        let finishing = Task { try await lane.finalizeRemoteManualInput(turn) }
        await waitFor { await wire.frames().contains { $0["type"]?.string == "input_audio_buffer.commit" } }
        let item = await wire.audioItemID()
        let final: [String: JSONValue] = ["type": .string("conversation.item.input_audio_transcription.completed"),
            "item_id": .string(item), "transcript": .string("Open Calculator. Keep forty-two and cedar.")]
        try await wire.push(["type": .string("conversation.item.input_audio_transcription.completed"),
                             "item_id": .string("wrong"), "transcript": .string("wrong")])
        try await wire.push(final)
        let admission = try await finishing.value
        XCTAssertEqual(admission?.route, .dictation)
        XCTAssertEqual(admission?.text, "Open Calculator. Keep forty-two and cedar.")
        if let admission { await lane.completeRemoteManualAdmission(admission) }
        try await wire.push(final)
        let frames = await wire.frames()
        XCTAssertFalse(frames.contains { $0["type"]?.string == "response.create" })
        XCTAssertEqual(deliveries, ["Open Calculator. Keep forty-two and cedar."])
        lane.cancel(); client.teardown()
    }

    func testC1RealtimeManualOwnershipRequiresConfirmedModeAndFreshConnection() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        XCTAssertThrowsError(try lane.beginRemoteManualInput(id: UUID(), mode: .dictation, context: context(), at: 0))
        try await lane.prepareRealtimeTransport(.conversation)
        XCTAssertThrowsError(try lane.beginRemoteManualInput(id: UUID(), mode: .dictation, context: context(), at: 1))
        try await lane.prepareRealtimeTransport(.manual)
        _ = try lane.beginRemoteManualInput(id: UUID(), mode: .dictation, context: context(), at: 2)
        lane.cancel()
        XCTAssertThrowsError(try lane.beginRemoteManualInput(id: UUID(), mode: .dictation, context: context(), at: 3))
        client.teardown()
    }

    func testC1RealtimeManualCancelRetiresUncommittedAudio() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        try await lane.prepareRealtimeTransport(.manual)
        let connection = client.connectionID
        _ = try lane.beginRemoteManualInput(id: UUID(), mode: .command, context: context(), at: 0)
        try await client.sendAudio(Data(repeating: 0, count: 480), connection: connection)
        lane.cancel()
        XCTAssertFalse(client.isReady, "cancelled audio cannot stay buffered on a reusable connection")
        XCTAssertNotEqual(client.connectionID, connection)
        let frames = await wire.frames()
        XCTAssertFalse(frames.contains { $0["type"]?.string == "input_audio_buffer.commit" })
        client.teardown()
    }

    func testC1RealtimeFeedbackSurvivesReconnectButNotExplicitPause() async throws {
        let peers = [RecordedVoiceWire(), RecordedVoiceWire(), RecordedVoiceWire()]
        var next = 0
        let client = RealtimeVoiceClient(wireFactory: { _ in
            defer { next += 1 }
            return peers[min(next, peers.count - 1)]
        })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        lane.conversation.readContext = { self.context() }
        lane.conversation.interpret = { _, _, _ in XCTFail("feedback cannot interpret"); return .init(kind: .clarify) }
        lane.conversation.execute = { _ in XCTFail("feedback cannot act"); return .init(verified: false, waitingForAnswer: false, message: "") }
        lane.conversation.onControl = { _ in }
        try await lane.prepareRealtimeTransport(.conversation)
        try lane.beginRealtimeConversation(session: UUID())
        await peers[0].setTextSendFailure(true)
        lane.speakFeedback("The first task finished.")
        await waitFor { lane.retryOutcomePush.items.count == 1 }
        lane.stopConversation(state: .unavailable("Fixture transport dropped."))
        XCTAssertEqual(lane.retryOutcomePush.items.count, 1)
        lane.speakFeedback("The second task finished.")
        await waitFor { lane.retryOutcomePush.items.count == 2 }
        try await lane.prepareRealtimeTransport(.conversation)
        try lane.beginRealtimeConversation(session: UUID())
        await waitFor { await peers[1].responseIDs().count == 1 }
        let firstIDs = await peers[1].responseIDs()
        let first = try XCTUnwrap(firstIDs.first)
        try await peers[1].push(["type": .string("response.done"),
                                "response": .object(["id": .string(first), "output": .array([])])])
        await waitFor { await peers[1].responseIDs().count == 2 }
        let ids = await peers[1].responseIDs()
        let second = try XCTUnwrap(ids.last)
        try await peers[1].push(["type": .string("response.done"),
                                "response": .object(["id": .string(second), "output": .array([])])])
        await waitFor { !lane.responseInFlight }
        XCTAssertTrue(lane.retryOutcomePush.isEmpty)
        let frames = await peers[1].frames()
        XCTAssertTrue(frames.filter { $0["type"]?.string == "response.create" }
            .allSatisfy { $0["response"]?["tool_choice"]?.string == "none" })
        await peers[1].setTextSendFailure(true)
        lane.speakFeedback("This queued reply must be dropped on pause.")
        await waitFor { lane.retryOutcomePush.items.count == 1 }
        lane.stopConversation()
        lane.speakFeedback("This reply must stay silent.")
        try await lane.prepareRealtimeTransport(.conversation)
        try lane.beginRealtimeConversation(session: UUID())
        await Task.yield()
        let resumed = await peers[2].frames()
        XCTAssertFalse(resumed.contains { $0["type"]?.string == "response.create" })
        XCTAssertTrue(lane.retryOutcomePush.isEmpty)
        lane.stopConversation()
    }

    func testC1RealtimeConversationKeepsListeningAfterCancelAndRejectsRetiredResponses() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        lane.conversation.readContext = { self.context() }
        lane.conversation.interpret = { _, _, _ in
            XCTFail("questions must use the conversation response"); return .init(kind: .clarify)
        }
        lane.conversation.execute = { _ in
            XCTFail("questions cannot actuate"); return .init(verified: false, waitingForAnswer: false, message: "")
        }
        lane.conversation.onControl = { _ in }
        var finals = 0, replies: [String] = []
        lane.onDiagnostic = { if $0.stage == "realtime.input.final" { finals += 1 } }
        lane.onEvent = { _, event in if case .assistant(let text) = event { replies.append(text) } }
        try await lane.prepareRealtimeTransport(.conversation)
        let session = UUID(), connection = client.connectionID
        try lane.beginRealtimeConversation(session: session)
        func say(_ turn: String) async throws {
            lane.localTurnStarted(connection: connection)
            try await lane.localTurnEnded(connection: connection)
            let item = await wire.audioItemID()
            try await wire.push(["type": .string("conversation.item.input_audio_transcription.completed"),
                                 "item_id": .string(item), "transcript": .string("What is two plus two?")])
        }
        try await say("first")
        await waitFor { await wire.responseIDs().count == 1 }
        let firstIDs = await wire.responseIDs()
        let first = try XCTUnwrap(firstIDs.first)
        lane.cancel()
        XCTAssertEqual(lane.conversation.id, session)
        XCTAssertEqual(client.connectionID, connection)
        XCTAssertTrue(client.isReady)
        try await say("second")
        await waitFor { finals == 2 }
        let beforeDone = await wire.responseIDs()
        XCTAssertEqual(beforeDone.count, 1)
        try await wire.push(function(first, call: "retired-tool", goal: "What is two plus two?"))
        try await wire.push(["type": .string("response.done"),
                             "response": .object(["id": .string(first), "output": .array([])])])
        await waitFor { await wire.responseIDs().count == 2 }
        let responseIDs = await wire.responseIDs()
        let second = try XCTUnwrap(responseIDs.last)
        try await wire.push(["type": .string("response.done"),
                             "response": .object(["id": .string(first), "output": .array([])])])
        try await wire.push(["type": .string("response.output_audio_transcript.done"),
                             "response_id": .string(second), "transcript": .string("Four.")])
        try await wire.push(["type": .string("response.done"),
                             "response": .object(["id": .string(second), "output": .array([])])])
        await waitFor { replies == ["Four."] && !lane.responseInFlight }
        XCTAssertEqual(lane.conversation.id, session)
        lane.stopConversation()
    }

    func testC1RealtimeRejectsAnAcknowledgementWithoutTheRequestedInputConfiguration() async throws {
        let wire = RecordedVoiceWire(sessionAcknowledgement: .object(["type": .string("realtime")]))
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        defer { client.teardown() }
        do {
            try await client.connect(apiKey: "fixture-not-a-real-key")
            XCTFail("a bare session.updated cannot confirm the requested input configuration")
        } catch {}
        XCTAssertFalse(client.isReady)
    }

    func testC1RealtimeDoesNotSendAudioBeforeConfigurationConfirmation() async throws {
        let wire = RecordedVoiceWire(acknowledgeUpdates: false)
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        defer { client.teardown() }
        let connecting = Task { try await client.connect(apiKey: "fixture-not-a-real-key") }
        await waitFor { await wire.frames().contains { $0["type"]?.string == "session.update" } }
        do {
            try await client.sendAudio(Data([0, 0, 0, 0]))
            XCTFail("unconfirmed input must not be sent")
        } catch {}
        let frames = await wire.frames()
        XCTAssertFalse(frames.contains { $0["type"]?.string == "input_audio_buffer.append" })
        let update = try XCTUnwrap(frames.first { $0["type"]?.string == "session.update" })
        try await wire.push(["type": .string("session.updated"), "session": update["session"] ?? .null])
        try await connecting.value
        XCTAssertTrue(client.isReady)
    }

    func testC1RealtimeManualTurnKeepsTranscriptionAndConnectionIdentity() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        defer { client.teardown() }
        try await client.connect(apiKey: "fixture-not-a-real-key")
        let connection = client.connectionID
        try await client.configureInput(.manual)
        var frames = await wire.frames()
        let manual = try XCTUnwrap(frames.last { $0["type"]?.string == "session.update" }?["session"])
        XCTAssertEqual(manual["audio"]?["input"]?["turn_detection"], .null)
        XCTAssertEqual(manual["audio"]?["input"]?["transcription"]?["model"]?.string, "gpt-4o-transcribe")
        XCTAssertEqual(client.connectionID, connection)
        try await client.configureInput(.conversation)
        frames = await wire.frames()
        XCTAssertEqual(frames.filter { $0["type"]?.string == "session.update" }.count, 3)
        XCTAssertEqual(client.connectionID, connection)
        XCTAssertFalse(frames.contains { $0["type"]?.string == "response.create" })
        do {
            try await client.sendAudio(Data([0, 0]), connection: UUID())
            XCTFail("a stale audio producer cannot send into a new conversation")
        } catch {}
    }

    func testLocalHitDoesNotNeedAKeyOrSocket() async throws {
        var opens = 0, calls: [String] = []
        let client = RealtimeVoiceClient(wireFactory: { _ in opens += 1; return RecordedVoiceWire() })
        let lane = RealtimeVoiceLane(apiKey: { "" }, client: client)
        lane.admissionContextProvider = { self.context() }
        lane.commandHandler = { goal, _, _, _, _, _ in
            calls.append(goal); return #"{"status":"started","say":"Accepted."}"#
        }
        try await lane.submitTyped("scroll down", sessionID: UUID())
        XCTAssertEqual(calls, ["scroll down"])
        XCTAssertEqual(opens, 0)
        client.teardown()
    }

    func testSemanticNoMatchContinuesOriginalRemoteOwnerOnce() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-key" }, client: client)
        lane.admissionContextProvider = { self.context() }
        lane.semanticContextProvider = { self.context() }
        lane.semanticEnabled = { true }
        var judgments = 0
        lane.semanticInterpretation = { _, _ in judgments += 1; return .noMatch }
        lane.semanticConfirmationHandler = { _ in XCTFail("no app proposal"); return false }
        try await lane.submitTyped("I need help with this workflow", sessionID: UUID())
        await waitFor { await wire.responseIDs().count == 1 }
        XCTAssertEqual(judgments, 1)
        let frames = await wire.frames()
        XCTAssertEqual(frames.filter { $0["type"]?.string == "response.create" }.count, 1)
        lane.cancel(); client.teardown()
    }

    func testNaturalAppRequestUsesCanonicalSurfaceAndCapturedIdentityOnce() async throws {
        var opens = 0
        let client = RealtimeVoiceClient(wireFactory: { _ in opens += 1; return RecordedVoiceWire() })
        let lane = RealtimeVoiceLane(apiKey: { "" }, client: client)
        var context = self.context()
        context.entities.append(.init(name: "Google Chrome", id: "com.google.Chrome", canOpenLocally: true))
        lane.admissionContextProvider = { context }
        lane.onEvent = { _, event in
            if case .heardFinal = event {
                context.entities = [.init(name: "Chrome", id: "fixture.replacement", canOpenLocally: true)]
            }
        }
        var calls: [(String, String?, String?)] = []
        lane.commandHandler = { goal, app, _, heard, _, _ in
            calls.append((goal, app, heard))
            return #"{"status":"started","say":"Accepted."}"#
        }
        let utterance = "Could you please show me Chrome?"
        try await lane.submitTyped(utterance, sessionID: UUID())
        await waitFor { calls.count == 1 }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "show Chrome?")
        XCTAssertEqual(calls.first?.1, "com.google.Chrome")
        XCTAssertEqual(calls.first?.2, utterance)
        XCTAssertEqual(opens, 0)
        client.teardown()
    }

    func testUnknownConfusableClarifiesWithoutReasoningOrExecution() async throws {
        var opens = 0, calls = 0
        let client = RealtimeVoiceClient(wireFactory: { _ in opens += 1; return RecordedVoiceWire() })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        lane.admissionContextProvider = { self.context() }
        lane.commandHandler = { _, _, _, _, _, _ in calls += 1; return "{}" }
        try await lane.submitTyped("open GateHub", sessionID: UUID())
        XCTAssertEqual(opens, 0); XCTAssertEqual(calls, 0)
        client.teardown()
    }

    func testTypedMissUsesOneResponseWithoutAudioOrImages() async throws {
        let peer = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in peer })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        lane.admissionContextProvider = { self.context() }
        try await lane.submitTyped("organize these files by date", sessionID: UUID())
        await waitFor { await peer.responseIDs().count == 1 }
        let frames = await peer.frames()
        XCTAssertEqual(frames.filter { $0["type"]?.string == "response.create" }.count, 1)
        XCTAssertEqual(frames.filter { $0["type"]?.string == "input_audio_buffer.commit" }.count, 0)
        let session = try XCTUnwrap(frames.first { $0["type"]?.string == "session.update" })
        XCTAssertEqual(session["session"]?["audio"]?["input"]?["transcription"]?["model"]?.string, "gpt-4o-transcribe")
        XCTAssertFalse(frames.contains { $0["type"]?.string == "input_audio_buffer.append" })
        XCTAssertEqual(session["session"]?["tools"]?.array?.count, 9)
        XCTAssertFalse(frames.contains { frame in
            frame["item"]?["content"]?.array?.contains { $0["type"]?.string == "input_image" } ?? false
        })
        lane.cancel(); client.teardown()
    }

    func testRawIncrementalAndDoneDuplicatesSpendOnlyOneExecutorPermit() async throws {
        let peer = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in peer })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        let goal = "organize these files by date"
        var calls = 0
        lane.commandHandler = { _, _, _, _, _, _ in calls += 1; return #"{"status":"started","say":"Accepted."}"# }
        lane.admissionContextProvider = { self.context() }
        try await lane.submitTyped(goal, sessionID: UUID())
        await waitFor { await peer.responseIDs().count == 1 }
        let responses = await peer.responseIDs()
        let response = try XCTUnwrap(responses.first)
        let frame = try function(response, call: "first", goal: goal)
        try await peer.push(frame)
        try await peer.push(frame)
        try await peer.push(function(response, call: "fresh-id-same-response", goal: goal))
        try await peer.push([
            "type": .string("response.done"),
            "response": .object(["id": .string(response), "status": .string("completed"),
                                 "output": .array([.object(["type": .string("function_call"), "call_id": .string("first"),
                                                            "name": .string("computer_task"), "arguments": frame["arguments"] ?? .string("{}")])])])
        ])
        await waitFor { calls == 1 }
        XCTAssertEqual(calls, 1)
        lane.cancel(); client.teardown()
    }

    func testOldResponseWithNewCallIDCannotActDuringNewMiss() async throws {
        var peers: [RecordedVoiceWire] = []
        let client = RealtimeVoiceClient(wireFactory: { _ in
            let peer = RecordedVoiceWire(); peers.append(peer); return peer
        })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        lane.admissionContextProvider = { self.context() }
        var calls: [String] = []
        lane.commandHandler = { goal, _, _, _, _, _ in calls.append(goal); return #"{"status":"started","say":"Accepted."}"# }
        try await lane.submitTyped("organize these files by date", sessionID: UUID())
        let first = try XCTUnwrap(peers.first)
        await waitFor { await first.responseIDs().count == 1 }
        let oldIDs = await first.responseIDs()
        let old = try XCTUnwrap(oldIDs.first)
        lane.cancel()
        let goal = "organize these notes by topic"
        try await lane.submitTyped(goal, sessionID: UUID())
        XCTAssertEqual(peers.count, 2)
        let next = try XCTUnwrap(peers.last)
        await waitFor { await next.responseIDs().count == 1 }
        let nextIDs = await next.responseIDs()
        let current = try XCTUnwrap(nextIDs.first)
        try await next.push(function(old, call: "fresh-id-from-dead-response", goal: goal))
        try await next.push(function(current, call: "current-response-call", goal: goal))
        await waitFor { calls.count == 1 }
        XCTAssertEqual(calls, [goal])
        lane.cancel(); client.teardown()
    }

    func testRemoteArgumentMutationIsBlockedWithoutExecutorCall() async throws {
        let peer = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in peer })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        lane.admissionContextProvider = { self.context() }
        var calls = 0
        lane.commandHandler = { _, _, _, _, _, _ in calls += 1; return "{}" }
        try await lane.submitTyped("organize these files by date", sessionID: UUID())
        await waitFor { await peer.responseIDs().count == 1 }
        let ids = await peer.responseIDs()
        let response = try XCTUnwrap(ids.first)
        try await peer.push(function(response, call: "mutated", goal: "delete these files"))
        await waitFor {
            await peer.frames().contains { $0["item"]?["type"]?.string == "function_call_output" }
        }
        XCTAssertEqual(calls, 0)
        let frames = await peer.frames()
        let output = try XCTUnwrap(frames.last { $0["item"]?["type"]?.string == "function_call_output" }?["item"]?["output"]?.string)
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(parsed["status"]?.string, "blocked")
        lane.cancel(); client.teardown()
    }

    func testOutcomeOnlyResponseHasToolsDisabledAndCannotAct() async throws {
        let peer = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in peer })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        lane.admissionContextProvider = { self.context() }
        var calls = 0
        lane.commandHandler = { _, _, _, _, _, _ in calls += 1; return "{}" }
        try await lane.submitTyped("what is two plus two", sessionID: UUID())
        await waitFor { await peer.responseIDs().count == 1 }
        let ids = await peer.responseIDs()
        let initial = try XCTUnwrap(ids.first)
        try await peer.push(["type": .string("response.done"), "response": .object([
            "id": .string(initial), "status": .string("completed"), "output": .array([])
        ])])
        await waitFor { !lane.responseInFlight }
        lane.conversation.readContext = { self.context() }
        lane.conversation.interpret = { _, _, _ in XCTFail("outcomes cannot request interpretation"); return .init(kind: .clarify) }
        lane.conversation.execute = { _ in XCTFail("outcomes cannot execute"); return .init(verified: false, waitingForAnswer: false, message: "") }
        lane.conversation.onControl = { _ in }
        try lane.beginRealtimeConversation(session: UUID())
        lane.pushTaskEvent(#"{"kind":"task_outcome","say":"Fixture completed."}"#, speak: true)
        await waitFor { await peer.responseIDs().count == 2 }
        let outcomeIDs = await peer.responseIDs()
        let outcome = try XCTUnwrap(outcomeIDs.last)
        try await peer.push(function(outcome, call: "tools-from-outcome", goal: "organize these files by date"))
        try await peer.push(["type": .string("response.done"), "response": .object([
            "id": .string(outcome), "status": .string("completed"), "output": .array([])
        ])])
        await waitFor { !lane.responseInFlight }
        XCTAssertEqual(calls, 0)
        let frames = await peer.frames().filter { $0["type"]?.string == "response.create" }
        XCTAssertEqual(frames.last?["response"]?["tool_choice"]?.string, "none")
        lane.stopConversation()
        lane.cancel(); client.teardown()
    }

    func testResolvedTargetCannotBeSilentlyDroppedByAnUnsupportedExecutor() async throws {
        let peer = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in peer })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-not-a-real-key" }, client: client)
        lane.admissionContextProvider = { self.context() }
        var calls = 0
        lane.commandHandler = { _, _, _, _, _, _ in calls += 1; return "{}" }
        try await lane.submitTyped("open GitHub", sessionID: UUID())
        await waitFor { await peer.responseIDs().count == 1 }
        let ids = await peer.responseIDs()
        let response = try XCTUnwrap(ids.first)
        let arguments = #"{"goal":"open GitHub","gaze_target":{"target_id":"site.github"}}"#
        try await peer.push([
            "type": .string("response.function_call_arguments.done"), "response_id": .string(response),
            "call_id": .string("bound-target"), "name": .string("computer_task"), "arguments": .string(arguments)
        ])
        await waitFor { await peer.frames().contains { $0["item"]?["type"]?.string == "function_call_output" } }
        XCTAssertEqual(calls, 0)
        let frames = await peer.frames()
        let text = try XCTUnwrap(frames.last { $0["item"]?["type"]?.string == "function_call_output" }?["item"]?["output"]?.string)
        let output = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(output["status"]?.string, "unavailable")
        XCTAssertEqual(output["error"]?.string, "unavailable:resolved_target")
        lane.cancel(); client.teardown()
    }

    func testAmbiguousMultiwordAskReplyNeverRequestsReasoning() async throws {
        var opens = 0, answers = 0
        let client = RealtimeVoiceClient(wireFactory: { _ in opens += 1; return RecordedVoiceWire() })
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client)
        var c = context()
        c.capturedAsks = [.init(taskID: UUID(), askID: UUID(), kind: .choice, options: ["blue", "red"]),
                          .init(taskID: UUID(), askID: UUID(), kind: .question)]
        c.currentAsks = c.capturedAsks
        lane.admissionContextProvider = { c }
        lane.exactTaskResponseHandler = { _, _, _, _ in answers += 1; return "{}" }
        try await lane.submitTyped("the blue one please", sessionID: UUID())
        XCTAssertEqual(opens, 0); XCTAssertEqual(answers, 0)
        lane.cancel(); client.teardown()
    }

    func testRawRemoteReplyCannotSelectBetweenUnselectedCurrentAsks() async throws {
        let peer = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in peer })
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client)
        var c = context()
        let first = VoiceAdmissionContext.Ask(taskID: UUID(), askID: UUID(), kind: .question)
        c.capturedAsks = [first, .init(taskID: UUID(), askID: UUID(), kind: .question)]
        c.currentAsks = c.capturedAsks
        lane.admissionContextProvider = { c }
        var answers = 0
        lane.exactTaskResponseHandler = { _, _, _, _ in answers += 1; return "{}" }
        let goal = "organize these files by date"
        try await lane.submitTyped(goal, sessionID: UUID())
        await waitFor { await peer.responseIDs().count == 1 }
        let ids = await peer.responseIDs()
        let response = try XCTUnwrap(ids.first)
        let fields: JSONValue = .object(["task_id": .string(first.taskID.uuidString),
                                        "ask_id": .string(first.askID.uuidString), "response": .string(goal)])
        let args = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        try await peer.push(["type": .string("response.function_call_arguments.done"),
                             "response_id": .string(response), "call_id": .string("model-selected-task"),
                             "name": .string("respond_to_task"), "arguments": .string(args)])
        await waitFor { await peer.frames().contains { $0["item"]?["type"]?.string == "function_call_output" } }
        XCTAssertEqual(answers, 0)
        lane.cancel(); client.teardown()
    }

    /// Production lane and production router; only the transport and the
    /// socket are fixtures. Stage telemetry may carry numbers and fixed
    /// category codes only — never utterance text, target identity,
    /// credentials or image data — and may not add a single wire turn.
    func testSemanticStageTelemetryIsNumericAndAddsNoTrafficOrTextLeak() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-key" }, client: client)
        var c = VoiceAdmissionContext()
        c.targetID = "fixture.window"; c.targetAppID = "fixture.editor"
        c.entities = [.init(name: "Google Chrome", id: "com.google.Chrome", canOpenLocally: true)]
        c.appRoles = ["https": "com.google.Chrome"]
        lane.admissionContextProvider = { c }
        lane.semanticContextProvider = { c }
        lane.semanticEnabled = { true }
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "protocol-fixture-not-calibrated",
            "answers": ["operation": ["type": "choice", "choice": "app_0", "confidence": 1,
                                      "probabilities": ["app_0": 1]] as [String: Any]],
            "usage": ["input_tokens": 1, "output_tokens": 1]
        ])
        let reply = try JSONDecoder().decode(SystemOneResponse.self, from: data)
        let router = VoiceSemanticRouter.live(apiKey: "fixture-key", transport: { _, _ in reply })
        lane.semanticInterpretation = { admission, context in
            try await router.interpret(admission, context: context)
        }
        var events: [VoiceSpeechDiagnostic] = []
        lane.onDiagnostic = { events.append($0) }
        var targets: [String] = []
        lane.semanticConfirmationHandler = { proposal in targets.append(proposal.target.id); return true }
        let utterance = "I need my web browser over here"
        try await lane.submitTyped(utterance, sessionID: UUID())
        XCTAssertEqual(targets, ["com.google.Chrome"], "telemetry does not change the chosen target")
        let semantic = events.filter { $0.stage.hasPrefix("semantic.") }
        XCTAssertFalse(semantic.isEmpty)
        let allowed: Set<String> = ["reserve_ms", "infer_ms", "fresh_context_ms", "interpret_ms",
                                    "failure", "action_confidence", "target_confidence"]
        let secrets = [utterance, "web browser", "com.google.Chrome", "Google Chrome",
                       "fixture-key", "com.apple.calculator"]
        for event in semantic {
            XCTAssertTrue(allowed.isSuperset(of: event.metrics.keys), "unexpected key in \(event.stage)")
            XCTAssertTrue(event.metrics.values.allSatisfy(\.isFinite))
            for secret in secrets {
                XCTAssertFalse(event.stage.contains(secret), "telemetry stage leaks input or identity")
                XCTAssertFalse(event.metrics.keys.contains { $0.contains(secret) },
                               "telemetry key leaks input or identity")
            }
        }
        let timed = semantic.filter { event in event.metrics.keys.contains { $0.hasSuffix("_ms") } }
        XCTAssertFalse(timed.isEmpty, "the semantic hop must record numeric stage durations")
        let ids = await wire.responseIDs(), frames = await wire.frames()
        XCTAssertTrue(ids.isEmpty, "stage telemetry spends no extra turn")
        XCTAssertFalse(frames.contains { $0["type"]?.string == "response.create" })
        lane.cancel(); client.teardown()
    }
}

/// The screen question end to end on the fixture wire: the tool result
/// carries the digest under its own item id, the model answers in a
/// tool-free follow-up, the named control glows, and the screen text is
/// deleted from the conversation once the answer settles.
extension VoiceOneBrainTests {
    func testScreenQuestionAnswersFromTextGlowsAndDeletesTheItem() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-key" }, client: client)
        let send = CGRect(x: 40, y: 60, width: 80, height: 28)
        var reads: [ScreenQuestion.Scope] = []
        lane.screenReader = { scope in
            reads.append(scope)
            let digest = ScreenContext.digest(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Draft",
                                              root: ScreenNode(role: "AXWindow", children: [
                ScreenNode(role: "AXStaticText", value: "Hi Linda, the photos are attached."),
                ScreenNode(role: "AXButton", description: "Send", frame: send),
            ]))
            return (digest, [])
        }
        var glows: [CGRect] = []
        lane.onScreenPoint = { glows.append($0) }
        let question = "what does this button do"
        try await lane.submitTyped(question, sessionID: UUID())
        await waitFor { await wire.responseIDs().count == 1 }
        let opened = await wire.responseIDs()
        let first = try XCTUnwrap(opened.first)
        let arguments = String(decoding: try JSONEncoder().encode(JSONValue.object(["question": .string(question)])),
                               as: UTF8.self)
        try await wire.push(["type": .string("response.function_call_arguments.done"), "response_id": .string(first),
                             "call_id": .string("screen-1"), "name": .string("ask_about_screen"),
                             "arguments": .string(arguments)])
        try await wire.push(["type": .string("response.done"), "response": .object([
            "id": .string(first), "status": .string("completed"), "output": .array([])])])

        await waitFor { await wire.responseIDs().count == 2 }
        let frames = await wire.frames()
        let output = try XCTUnwrap(frames.first { $0["item"]?["type"]?.string == "function_call_output" }?["item"])
        let itemID = try XCTUnwrap(output["id"]?.string)
        XCTAssertTrue(itemID.hasPrefix("scr-"))
        XCTAssertEqual(itemID.utf8.count, 32)
        let result = try JSONDecoder().decode(JSONValue.self, from: Data((output["output"]?.string ?? "").utf8))
        XCTAssertTrue(result["screen"]?.string?.contains(#"[e2] button "Send""#) == true)
        XCTAssertEqual(reads, [.window])
        let relay = try XCTUnwrap(frames.last { $0["type"]?.string == "response.create" })
        XCTAssertEqual(relay["response"]?["tool_choice"]?.string, "none", "the answer is spoken, not another tool")

        let responses = await wire.responseIDs()
        let second = try XCTUnwrap(responses.last)
        try await wire.push(["type": .string("response.output_audio_transcript.done"), "response_id": .string(second),
                             "transcript": .string("Press the Send button at the top.")])
        await waitFor { glows == [send] }
        let early = await wire.frames()
        XCTAssertFalse(early.contains { $0["type"]?.string == "conversation.item.delete" },
                       "the screen text stays until the answer settles")
        try await wire.push(["type": .string("response.done"), "response": .object([
            "id": .string(second), "status": .string("completed"), "output": .array([])])])
        await waitFor {
            await wire.frames().contains { $0["type"]?.string == "conversation.item.delete" && $0["item_id"]?.string == itemID }
        }
        XCTAssertTrue(lane.screenItems.isEmpty)
        XCTAssertNil(lane.screenAnswer)
        lane.cancel(); client.teardown()
    }

    func testScreenQuestionVaultIsRefusedWithoutReadingIt() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = RealtimeVoiceLane(apiKey: { "fixture-key" }, client: client)
        lane.screenReader = { _ in
            (ScreenContext.digest(app: "1Password", bundleID: "com.1password.1password", windowTitle: "Vault",
                                  root: ScreenNode(role: "AXWindow", children: [
                ScreenNode(role: "AXStaticText", value: "bank: rose / hunter2")])), [])
        }
        var said: [String] = []
        lane.onEvent = { _, event in if case .toolSay(let text) = event { said.append(text) } }
        let question = "what does this window say"
        try await lane.submitTyped(question, sessionID: UUID())
        await waitFor { await wire.responseIDs().count == 1 }
        let opened = await wire.responseIDs()
        let first = try XCTUnwrap(opened.first)
        let arguments = String(decoding: try JSONEncoder().encode(JSONValue.object(["question": .string(question)])),
                               as: UTF8.self)
        try await wire.push(["type": .string("response.function_call_arguments.done"), "response_id": .string(first),
                             "call_id": .string("screen-2"), "name": .string("ask_about_screen"),
                             "arguments": .string(arguments)])
        await waitFor { said == [ScreenQuestion.vaultRefusal] }
        let written = await wire.frames()
        let output = written.first { $0["item"]?["type"]?.string == "function_call_output" }?["item"]
        XCTAssertFalse(output?["output"]?.string?.contains("hunter2") ?? true)
        XCTAssertNil(output?["id"], "a fixed line leaves no screen text to delete")
        lane.cancel(); client.teardown()
    }
}

/// Codex P1/P2 on #538: the screen answer survives a tool result that
/// settles before the first response's done, and a hands-free
/// interruption deletes the screen text and the owed answer.
extension VoiceOneBrainTests {
    private func screenLane(_ wire: RecordedVoiceWire, client: RealtimeVoiceClient,
                            send: CGRect) -> RealtimeVoiceLane {
        let lane = RealtimeVoiceLane(apiKey: { "fixture-key" }, client: client)
        lane.screenReader = { _ in
            (ScreenContext.digest(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Draft",
                                  root: ScreenNode(role: "AXWindow", children: [
                ScreenNode(role: "AXStaticText", value: "Hi Linda, the photos are attached."),
                ScreenNode(role: "AXButton", description: "Send", frame: send),
            ])), [])
        }
        return lane
    }

    private func askAboutScreen(_ wire: RecordedVoiceWire, response: String, question: String) async throws {
        let arguments = String(decoding: try JSONEncoder().encode(JSONValue.object(["question": .string(question)])),
                               as: UTF8.self)
        try await wire.push(["type": .string("response.function_call_arguments.done"), "response_id": .string(response),
                             "call_id": .string("screen-" + response), "name": .string("ask_about_screen"),
                             "arguments": .string(arguments)])
    }

    private func screenItemID(_ wire: RecordedVoiceWire) async -> String? {
        await wire.frames().first { $0["item"]?["type"]?.string == "function_call_output" }?["item"]?["id"]?.string
    }

    func testScreenResultSettledBeforeFirstDoneStillGetsItsAnswer() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let send = CGRect(x: 40, y: 60, width: 80, height: 28)
        let lane = screenLane(wire, client: client, send: send)
        var glows: [CGRect] = []
        var ended = false
        lane.onScreenPoint = { glows.append($0) }
        lane.onEvent = { _, event in if case .turnEnded = event { ended = true } }
        let question = "what does this button do"
        try await lane.submitTyped(question, sessionID: UUID())
        await waitFor { await wire.responseIDs().count == 1 }
        let opened = await wire.responseIDs()
        let first = try XCTUnwrap(opened.first)
        try await askAboutScreen(wire, response: first, question: question)
        await waitFor { await self.screenItemID(wire) != nil }
        XCTAssertTrue(lane.toolRelayOwed, "the result settled while the first response is still open")
        try await wire.push(["type": .string("response.done"), "response": .object([
            "id": .string(first), "status": .string("completed"), "output": .array([])])])
        await waitFor { await wire.responseIDs().count == 2 }
        let afterFirst = await wire.frames()
        XCTAssertFalse(afterFirst.contains { $0["type"]?.string == "conversation.item.delete" },
                       "the first done must not delete the text the answer reads from")
        XCTAssertFalse(ended, "the first done must not end the turn")
        XCTAssertNotNil(lane.screenAnswer)

        let responses = await wire.responseIDs()
        let second = try XCTUnwrap(responses.last)
        try await wire.push(["type": .string("response.output_audio_transcript.done"), "response_id": .string(second),
                             "transcript": .string("Press the Send button.")])
        await waitFor { glows == [send] }
        try await wire.push(["type": .string("response.done"), "response": .object([
            "id": .string(second), "status": .string("completed"), "output": .array([])])])
        let itemID = await screenItemID(wire)
        await waitFor {
            await wire.frames().contains { $0["type"]?.string == "conversation.item.delete" && $0["item_id"]?.string == itemID }
        }
        lane.cancel(); client.teardown()
    }

    func testHandsFreeInterruptionDeletesScreenTextAndTheOwedAnswer() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        let lane = screenLane(wire, client: client, send: CGRect(x: 0, y: 0, width: 40, height: 20))
        let question = "what does this button do"
        try await lane.submitTyped(question, sessionID: UUID())
        await waitFor { await wire.responseIDs().count == 1 }
        let opened = await wire.responseIDs()
        let first = try XCTUnwrap(opened.first)
        try await askAboutScreen(wire, response: first, question: question)
        await waitFor { await self.screenItemID(wire) != nil }
        let written = await screenItemID(wire)
        let itemID = try XCTUnwrap(written)
        XCTAssertEqual(lane.screenItems, [itemID])

        lane.interruptConversationPlayback()

        XCTAssertTrue(lane.screenItems.isEmpty)
        XCTAssertNil(lane.screenAnswer)
        XCTAssertFalse(lane.toolRelayOwed, "an interrupted answer is no longer owed")
        await waitFor {
            await wire.frames().contains { $0["type"]?.string == "conversation.item.delete" && $0["item_id"]?.string == itemID }
        }
        lane.cancel(); client.teardown()
    }
}

/// #577: a turn that waits on the model says one short filler only when
/// the answer is slow. The clock is scripted: `tick` fires the delay.
extension VoiceOneBrainTests {
    private func fillerLane(_ wire: RecordedVoiceWire, client: RealtimeVoiceClient,
                            log: @escaping (String) -> Void) -> (RealtimeVoiceLane, () -> Void) {
        let lane = RealtimeVoiceLane(apiKey: { "fixture-key" }, client: client)
        lane.admissionContextProvider = { self.context() }
        var pending: [CheckedContinuation<Void, Never>] = []
        var delays: [Duration] = []
        lane.fillerClock = { delay in
            delays.append(delay)
            await withCheckedContinuation { pending.append($0) }
        }
        lane.onFiller = { _, line in log("filler " + line) }
        lane.onEvent = { _, event in if case .assistant(let text) = event { log("answer " + text) } }
        let tick = {
            XCTAssertEqual(delays, [RealtimeVoiceLane.fillerDelay])
            pending.forEach { $0.resume() }; pending = []
        }
        return (lane, tick)
    }

    private func answer(_ wire: RecordedVoiceWire, _ text: String) async throws {
        let ids = await wire.responseIDs()
        try await wire.push(["type": .string("response.output_audio_transcript.done"),
                             "response_id": .string(try XCTUnwrap(ids.last)), "transcript": .string(text)])
    }

    func testFastAnswerGetsNoFiller() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        var log: [String] = []
        let (lane, tick) = fillerLane(wire, client: client) { log.append($0) }
        try await lane.submitTyped("what is two plus two", sessionID: UUID())
        await waitFor { await wire.responseIDs().count == 1 }
        try await answer(wire, "Four.")
        await waitFor { log == ["answer Four."] }
        tick()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log, ["answer Four."])
        lane.cancel(); client.teardown()
    }

    func testSlowAnswerGetsOneFillerBeforeTheAnswer() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        var log: [String] = []
        let (lane, tick) = fillerLane(wire, client: client) { log.append($0) }
        try await lane.submitTyped("what is two plus two", sessionID: UUID())
        await waitFor { await wire.responseIDs().count == 1 }
        tick()
        await waitFor { log == ["filler " + RealtimeVoiceLane.fillerLine] }
        try await answer(wire, "Four.")
        await waitFor { log.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log, ["filler Looking…", "answer Four."])
        lane.cancel(); client.teardown()
    }

    func testCancelledTurnGetsNoFiller() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(wireFactory: { _ in wire })
        var log: [String] = []
        let (lane, tick) = fillerLane(wire, client: client) { log.append($0) }
        try await lane.submitTyped("what is two plus two", sessionID: UUID())
        await waitFor { await wire.responseIDs().count == 1 }
        lane.cancel()
        tick()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(log, [])
        client.teardown()
    }
}

