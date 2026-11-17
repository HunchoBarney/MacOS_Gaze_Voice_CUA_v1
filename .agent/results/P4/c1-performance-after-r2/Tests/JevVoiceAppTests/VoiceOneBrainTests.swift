import Foundation
import CryptoKit
import XCTest
import JevVoiceCore
@testable import JevVoice

/// Protocol fixtures replace only the remote wire. They are not ASR/acoustic evidence.
private actor RecordedVoiceWire: RealtimeVoiceWire {
    private var incoming: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private var written: [JSONValue] = []
    private var responses: [String] = []
    private let identity = UUID().uuidString

    func send(_ text: String) throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        written.append(frame)
        switch frame["type"]?.string {
        case "session.update":
            try push(["type": .string("session.updated")])
        case "conversation.item.create":
            if let id = frame["item"]?["id"]?.string {
                try push(["type": .string("conversation.item.created"), "item": .object(["id": .string(id)])])
            }
        case "input_audio_buffer.commit":
            try push(["type": .string("input_audio_buffer.committed"), "item_id": .string("audio-" + identity)])
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

    func testLocalHitDoesNotNeedAKeySocketOrScreenshot() async throws {
        var opens = 0, shots = 0, calls: [String] = []
        let client = RealtimeVoiceClient(wireFactory: { _ in opens += 1; return RecordedVoiceWire() })
        let lane = RealtimeVoiceLane(apiKey: { "" }, client: client)
        lane.admissionContextProvider = { self.context() }
        lane.screenShotProvider = { shots += 1; return Data() }
        lane.commandHandler = { goal, _, _, _, _, _ in
            calls.append(goal); return #"{"status":"started","say":"Accepted."}"#
        }
        try await lane.submitTyped("scroll down", sessionID: UUID())
        XCTAssertEqual(calls, ["scroll down"])
        XCTAssertEqual(opens, 0); XCTAssertEqual(shots, 0)
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

    func testMissUsesOneResponseWithoutCloudTranscriptionOrImages() async throws {
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
        XCTAssertNil(session["session"]?["audio"]?["input"]?["transcription"])
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

    override func tearDown() async throws {
        guard let run = ProcessInfo.processInfo.environment["JARVIS_P3_RUN_ID"],
              let directory = ProcessInfo.processInfo.environment["JARVIS_P3_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = URL(fileURLWithPath: directory).appendingPathComponent("voice-integration.json")
        guard path.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent(".agent/results/P3").standardizedFileURL else {
            XCTFail("evidence destination must be phase-owned"); return
        }
        var rows: [JSONValue] = []
        if let bytes = try? Data(contentsOf: path),
           let old = try? JSONDecoder().decode(JSONValue.self, from: bytes), old["run_id"]?.string == run {
            rows = old["cases"]?.array ?? []
        }
        rows.append(.object(["name": .string(name), "failures": .number(Double(testRun?.failureCount ?? 1))]))
        let source = try Data(contentsOf: root.appendingPathComponent("Sources/JevVoice/Voice/RealtimeVoiceLane.swift"))
        let hash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let evidence = JSONValue.object([
            "schema_version": .number(1), "run_id": .string(run), "source": .string("protocol-fixtures-not-live-server"),
            "production_decoder": .bool(true), "production_lane": .bool(true), "source_sha256": .string(hash),
            "cases": .array(rows), "failures": .number(Double(rows.reduce(0) { $0 + ($1["failures"]?.integer ?? 1) }))
        ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: path, options: .atomic)
    }
}
