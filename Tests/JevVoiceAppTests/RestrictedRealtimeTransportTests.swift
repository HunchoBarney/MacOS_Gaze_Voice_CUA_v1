import AVFoundation
import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class RestrictedRealtimeTransportTests: XCTestCase {
    private func refused(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected refusal", file: file, line: line) }
        catch {}
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw VoiceError("The expected fixture boundary was not reached.")
    }

    private func outputs(ready: @escaping @Sendable (VoicePlaybackChannel) -> Bool = { _ in true }) -> VoicePlaybackOutputs {
        func route(_ channel: VoicePlaybackChannel) -> VoicePlaybackRoute {
            .init(id: UUID(), isReady: { ready(channel) }, schedule: { _, _ in XCTFail("Playback scheduled") },
                  play: { XCTFail("Playback started") }, stop: {})
        }
        return .init(realtime: route(.realtime), system: route(.system), local: route(.local))
    }

    private func microphone(_ playback: VoicePlaybackOutputs?) throws -> RealtimeVoiceLane.Microphone {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        return .init(gate: MicrophoneAudioGate(), permissionGranted: { true },
                     resolve: { _ in .init(hardwareID: 1, uid: "fixture", name: "fixture") },
                     prepare: { _, duplex, _ in
                         XCTAssertTrue(duplex)
                         return .init(name: "fixture", format: format, firstFrames: 480, startupRecoveries: 0, playback: playback)
                     }, stop: {})
    }

    func testTranscriptionOnlyFramesAndReconnect() async throws {
        let first = RecordedVoiceWire(), second = RecordedVoiceWire()
        var wires = [first, second]
        let client = RealtimeVoiceClient(literalOnly: true, wireFactory: { request in
            XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
            return wires.removeFirst()
        })
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client, literalOnly: true,
                                     microphone: try microphone(outputs()))
        lane.restrictedConnectionPermitted = { true }
        lane.playbackRoutingReady = { true }
        lane.contextProvider = { XCTFail("Host context was requested"); return "fixture" }
        lane.admissionContextProvider = { XCTFail("Generic admission was entered"); return .init() }
        lane.commandHandler = { _, _, _, _, _, _ in XCTFail("Tool executed"); return "" }
        _ = try await lane.prepare(inputUID: nil)
        for (index, wire) in [first, second].enumerated() {
            try await lane.prepareRealtimeTransport(.conversation)
            let connection = client.connectionID
            try await client.configureInput(.conversation)
            await refused { try await client.configureInput(.manual) }
            await refused { try await client.configureInput(.localFinal) }
            await refused { try await lane.submitTyped("fixture", sessionID: UUID()) }
            await refused { _ = try await lane.start(session: UUID(), inputUID: nil, transcribe: true) }
            await refused { _ = try await lane.start(session: UUID(), inputUID: nil, transcribe: false) }
            await refused { _ = try await client.sendContextNote("fixture", replacing: "old") }
            await refused { _ = try await client.sendText("fixture") }
            await refused { try await client.requestResponse(allowTools: false) }
            await refused { try await client.sendFunctionOutput(callID: "one", output: "fixture") }
            await refused { try await client.commitAudio() }
            await refused { try await client.clearAudio() }
            await refused { try await client.cancelResponse() }
            await refused { try await client.truncate(itemID: "old", audioEndMs: 0) }
            await refused { try client.submitControl(.close, connection: connection, nonce: "x") { _ in XCTFail() } }
            lane.speakFeedback("fixture")
            lane.pushTaskEvent("fixture", speak: true)
            try await client.sendAudio(Data([1, 2]), connection: connection)
            if index == 0 {
                try await wire.push(["type": .string("response.function_call_arguments.done"), "call_id": .string("one"),
                                     "name": .string("computer_task"), "arguments": .string("{}")])
            } else {
                try await wire.push(["type": .string("session.updated"), "session": .object(["tool_choice": .string("auto")])])
            }
            try await waitUntil { !client.isReady }
            await refused { try await client.sendAudio(Data([3]), connection: connection) }
            let frames = await wire.frames()
            XCTAssertEqual(frames.compactMap { $0["type"]?.string }, ["session.update", "input_audio_buffer.append"])
            let session = try XCTUnwrap(frames.first?["session"])
            XCTAssertEqual(session["tools"], .array([]))
            XCTAssertEqual(session["tool_choice"], .string("none"))
            XCTAssertEqual(session["instructions"], .string(""))
            XCTAssertEqual(session["output_modalities"], .array([.string("text")]))
            XCTAssertNil(session["audio"]?["output"])
            XCTAssertTrue(RealtimeVoiceClient.InputMode.conversation.matches(session))
        }
        await lane.suspend()
    }

    func testWeakAcknowledgementsNeverOpenAudio() async throws {
        let seed = RecordedVoiceWire()
        let normal = RealtimeVoiceClient(wireFactory: { _ in seed })
        try await normal.connect(apiKey: "fixture")
        let normalFrames = await seed.frames()
        let normalSession = try XCTUnwrap(normalFrames.first?["session"]?.object)
        XCTAssertEqual(normalSession["tool_choice"], .string("auto"))
        XCTAssertEqual(normalSession["tools"]?.array?.count, VoiceToolCatalog.names.count)
        normal.teardown()
        var restricted = normalSession
        restricted["tools"] = .array([])
        restricted["tool_choice"] = .string("none")
        restricted["instructions"] = .string("")
        restricted["output_modalities"] = .array([.string("text")])
        for (key, value) in [("tools", normalSession["tools"]), ("tool_choice", .string("auto")),
                             ("tools", nil), ("output_modalities", .array([.string("audio")])),
                             ("instructions", .string("unexpected")), ("audio", nil)] {
            var weak = restricted
            weak[key] = value
            let wire = RecordedVoiceWire(sessionAcknowledgement: .object(weak))
            let client = RealtimeVoiceClient(literalOnly: true, wireFactory: { _ in wire })
            await refused { try await client.connect(apiKey: "fixture", restrictedPermission: { true }) }
            XCTAssertFalse(client.isReady)
            await refused { try await client.sendAudio(Data([1])) }
            let frames = await wire.frames()
            XCTAssertEqual(frames.compactMap { $0["type"]?.string }, ["session.update"])
        }
    }

    func testNoMicrophoneKeyOrConnectAfterPermissionLossAtEachBoundary() async throws {
        for loss in ["missing", "duringResolve", "duringPrepare", "duringKey"] {
            var allowed = true, starts = 0, keyReads = 0, connections = 0
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let playback = outputs()
            let mic = RealtimeVoiceLane.Microphone(gate: MicrophoneAudioGate(), permissionGranted: { true },
                resolve: { _ in
                    if loss == "duringResolve" { allowed = false }
                    return .init(hardwareID: 1, uid: "fixture", name: "fixture")
                }, prepare: { _, _, _ in
                    starts += 1
                    if loss == "duringPrepare" { allowed = false }
                    return .init(name: "fixture", format: format, firstFrames: 480, startupRecoveries: 0, playback: playback)
                }, stop: {})
            let client = RealtimeVoiceClient(literalOnly: true, wireFactory: { _ in
                connections += 1
                return RecordedVoiceWire()
            })
            let lane = RealtimeVoiceLane(apiKey: {
                keyReads += 1
                if loss == "duringKey" { allowed = false }
                return "fixture"
            }, client: client, literalOnly: true, microphone: mic)
            lane.playbackRoutingReady = { true }
            if loss != "missing" { lane.restrictedConnectionPermitted = { allowed } }
            await refused { _ = try await lane.prepare(inputUID: nil) }
            XCTAssertEqual(starts, ["duringPrepare", "duringKey"].contains(loss) ? 1 : 0, loss)
            XCTAssertEqual(keyReads, loss == "duringKey" ? 1 : 0, loss)
            XCTAssertEqual(connections, 0, loss)
            XCTAssertFalse(client.isReady, loss)
        }
    }

    func testMissingOrUnreadyPreparedDuplexNeverReadsKeyOrConnects() async throws {
        for failed: VoicePlaybackChannel? in [nil, .realtime, .system, .local] {
            var reads = 0, connections = 0
            let client = RealtimeVoiceClient(literalOnly: true, wireFactory: { _ in connections += 1; return RecordedVoiceWire() })
            let playback = failed.map { failed in outputs { $0 != failed } }
            let lane = RealtimeVoiceLane(apiKey: { reads += 1; return "fixture" }, client: client, literalOnly: true,
                                         microphone: try microphone(playback))
            lane.restrictedConnectionPermitted = { true }
            lane.playbackRoutingReady = { true }
            await refused { try await lane.prepareRealtimeTransport(.conversation) }
            await refused { _ = try await lane.prepare(inputUID: nil) }
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(connections, 0)
            XCTAssertFalse(client.isReady)
            await lane.suspend()
        }
    }

    func testDuplexDropImmediatelyBeforePCMCannotSendOrReconnect() async throws {
        for channel in VoicePlaybackChannel.allCases {
            let wire = RecordedVoiceWire()
            var reads = 0, connections = 0
            let client = RealtimeVoiceClient(literalOnly: true, wireFactory: { _ in connections += 1; return wire })
            let failed = LockedBox<VoicePlaybackChannel?>(nil)
            let lane = RealtimeVoiceLane(apiKey: { reads += 1; return "fixture" }, client: client, literalOnly: true,
                                         microphone: try microphone(outputs { failed.value != $0 }))
            lane.restrictedConnectionPermitted = { true }
            lane.playbackRoutingReady = { true }
            _ = try await lane.prepare(inputUID: nil)
            let connection = client.connectionID
            try await client.sendAudio(Data([1, 2]), connection: connection)
            let before = await wire.frames()
            XCTAssertEqual(before.compactMap { $0["type"]?.string }, ["session.update", "input_audio_buffer.append"])
            failed.set(channel)
            await refused { try await client.sendAudio(Data([3, 4]), connection: connection) }
            failed.set(nil)
            await refused { try await lane.prepareRealtimeTransport(.conversation) }
            let after = await wire.frames()
            XCTAssertEqual(before, after)
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(connections, 1)
            XCTAssertFalse(client.isReady)
            await lane.suspend()
        }
    }

    func testDuplexLossAtKeySocketOrAckCannotAdvanceTransport() async throws {
        for loss in ["key", "socket", "ack"] {
            let wire = RecordedVoiceWire(acknowledgeUpdates: false)
            let healthy = LockedBox(true)
            var connections = 0
            let client = RealtimeVoiceClient(literalOnly: true, wireFactory: { _ in
                connections += 1
                if loss == "socket" { healthy.set(false) }
                return wire
            })
            let lane = RealtimeVoiceLane(apiKey: {
                if loss == "key" { healthy.set(false) }
                return "fixture"
            }, client: client, literalOnly: true, microphone: try microphone(outputs { _ in healthy.value }))
            lane.restrictedConnectionPermitted = { true }
            lane.playbackRoutingReady = { true }
            let preparation = Task { try await lane.prepare(inputUID: nil) }
            if loss == "ack" {
                try await waitUntil { await wire.frames().first?["type"] == .string("session.update") }
                let frames = await wire.frames()
                let settings = try XCTUnwrap(frames.first?["session"])
                healthy.set(false)
                try await wire.push(["type": .string("session.updated"), "session": settings])
            }
            await refused { _ = try await preparation.value }
            let frames = await wire.frames()
            XCTAssertEqual(frames.compactMap { $0["type"]?.string }, loss == "ack" ? ["session.update"] : [], loss)
            XCTAssertEqual(connections, loss == "key" ? 0 : 1, loss)
            XCTAssertFalse(client.isReady, loss)
            await lane.suspend()
        }
    }

    func testRestrictedConversationUsesRealGateAndOnlyTheOnsetTextEditField() async throws {
        let wire = RecordedVoiceWire()
        let client = RealtimeVoiceClient(literalOnly: true, wireFactory: { _ in wire })
        let gate = MicrophoneAudioGate()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let route = VoicePlaybackRoute(id: UUID(), isReady: { true },
                                      schedule: { _, _ in XCTFail("Playback scheduled") },
                                      play: { XCTFail("Playback started") }, stop: {})
        var prepared = 0
        let mic = RealtimeVoiceLane.Microphone(gate: gate, permissionGranted: { true },
            resolve: { _ in MicrophoneDevice(hardwareID: 1, uid: "fixture", name: "fixture") },
            prepare: { _, duplex, _ in
                XCTAssertTrue(duplex); prepared += 1
                return .init(name: "fixture", format: format, firstFrames: 480, startupRecoveries: 0,
                             playback: .init(realtime: route, system: route, local: route))
            }, stop: {})
        let lane = RealtimeVoiceLane(apiKey: { "fixture" }, client: client, literalOnly: true, microphone: mic)
        var permitted = true
        lane.restrictedConnectionPermitted = { permitted }
        lane.playbackRoutingReady = { true }
        lane.gazeClickLease = { XCTFail("Gaze queried"); return nil }
        var context = VoiceAdmissionContext(targetID: "window:42:7", targetAppID: "com.apple.TextEdit",
                                           windowID: 7, editableTarget: true)
        let session = lane.conversation
        session.readContext = { context }
        let field = LiteralFixtureField()
        field.bind(session, app: "com.apple.TextEdit", window: 7)
        let bind = try XCTUnwrap(session.captureLiteralTarget)
        var captures = 0, messages: [String] = [], controls: [ConversationDecision.Kind] = []
        session.captureLiteralTarget = { app, window in captures += 1; return bind(app, window) }
        session.literalInputPermitted = { lane.ownsConversationInput($0) && lane.conversationAudioReady }
        session.onEvent = { event in
            if case .feedback(_, let message) = event { messages.append(message) }
            if case .literalRefusal(_, let message) = event { messages.append(message) }
            if case .final = event { XCTFail("Raw final was handed to presentation") }
        }
        session.onControl = { controls.append($0) }
        session.interpret = { _, _, _ in XCTFail("Interpreter called"); throw CancellationError() }
        session.execute = { _ in XCTFail("Generic executor called"); throw CancellationError() }
        session.remote = { _, _, _ in XCTFail("Remote reasoning called") }
        try await lane.startConversation(inputUID: nil)
        XCTAssertEqual(prepared, 1)
        XCTAssertTrue(lane.conversationAudioReady)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.update(repeating: 0.05, count: 4800)
        gate.append(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
        try await waitUntil { await wire.frames().contains { $0["type"] == .string("input_audio_buffer.append") } }
        for (index, phrase) in ["Type blue", "What can you see on the screen?", "Click", "Stop",
                                "Type red", "Pause listening"].enumerated() {
            if index == 4 { context.targetAppID = "fixture.other" }
            let item = JSONValue.string("fixture-" + String(index))
            let count = messages.count
            try await wire.push(["type": .string("input_audio_buffer.speech_started"), "item_id": item])
            try await wire.push(["type": .string("input_audio_buffer.speech_stopped"), "item_id": item])
            try await wire.push(["type": .string("input_audio_buffer.committed"), "item_id": item])
            try await wire.push(["type": .string("conversation.item.input_audio_transcription.completed"),
                                 "item_id": item, "transcript": .string(phrase)])
            try await waitUntil { messages.count > count }
        }
        XCTAssertEqual(captures, 4)
        XCTAssertEqual(field.writes, 1)
        XCTAssertEqual(field.value, "blue")
        XCTAssertEqual(controls, [.stop, .pause])
        XCTAssertEqual(messages.filter { $0 == "Typed the text." }.count, 1)
        let frames = await wire.frames()
        XCTAssertTrue(frames.allSatisfy { ["session.update", "input_audio_buffer.append"].contains($0["type"]?.string ?? "") })
        permitted = false
        gate.append(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
        try await waitUntil { lane.conversation.id == nil }
        let retiredFrames = await wire.frames()
        XCTAssertEqual(retiredFrames, frames)
        XCTAssertFalse(client.isReady)
        await lane.suspend()
    }
}
