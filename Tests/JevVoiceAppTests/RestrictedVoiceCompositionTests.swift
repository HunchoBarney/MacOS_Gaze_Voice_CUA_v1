import AVFoundation
import JevVoiceCore
import Synchronization
import XCTest
@testable import JevVoice

@MainActor
final class RestrictedVoiceCompositionTests: XCTestCase {
    private enum Focus { case original, neighbor, otherApp }

    @MainActor
    private final class Field {
        var value = "before sample"
        var range = NSRange(location: 7, length: 6)
        var reads = 0
        var writes = 0
        var postWriteReads = 0
        var discardWrite = false
        var beforeSetter: (() -> Void)?

        func bind(eligible: @escaping () -> Bool) -> SpokenLiteralTarget? {
            SpokenLiteralTarget(eligible: eligible, state: {
                self.reads += 1
                if self.writes > 0 { self.postWriteReads += 1 }
                return (self.value, self.range)
            }, write: { text, before, selection, permitted in
                self.beforeSetter?()
                guard eligible(), self.value == before, self.range == selection, permitted() else { return nil }
                self.writes += 1
                if !self.discardWrite {
                    self.value = (before as NSString).replacingCharacters(in: selection, with: text)
                    self.range = NSRange(location: selection.location + text.utf16.count, length: 0)
                }
                return .init(succeeded: true, issuedAt: 1, returnedAt: 2)
            })
        }
    }

    @MainActor
    private final class Endpoints {
        let original = Field(), neighbor = Field(), otherApp = Field()
        var focus: Focus = .original
        var captures = 0
        var contextReads = 0
        var wires: [RecordedVoiceWire] = []
        var fnDown: Bool? = false
        var now = ContinuousClock.now
        var observation = RestrictedFnObservation()
        var monitoring = false
        let missing = LockedBox<[Permission]>([])
        let statusReads = Mutex<[Permission]>([])
        let gate = MicrophoneAudioGate()
        let failedRoute = LockedBox<VoicePlaybackChannel?>(nil)
        let routeChecks = Mutex<Set<VoicePlaybackChannel>>([])
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        var micStarts = 0
        var keyReads = 0

        func output(_ channel: VoicePlaybackChannel) -> VoicePlaybackRoute {
            .init(id: UUID(), isReady: {
                self.routeChecks.withLock { _ = $0.insert(channel) }
                return self.failedRoute.value != channel
            }, schedule: { _, _ in XCTFail("Restricted lane scheduled audio on \(channel)") },
            play: { XCTFail("Restricted lane played audio on \(channel)") }, stop: {})
        }

        func heartbeat() {
            guard monitoring else { return }
            observation.sample(fnDown: fnDown, at: now, heartbeat: true)
        }

        func readUp() -> UUID? {
            guard monitoring else { return nil }
            observation.sample(fnDown: fnDown, at: now, heartbeat: false)
            return observation.generation
        }

        func context() -> VoiceAdmissionContext {
            contextReads += 1
            var context = VoiceAdmissionContext(targetAppID: focus == .otherApp ? "fixture.other" : "com.apple.TextEdit",
                                                windowID: focus == .otherApp ? 8 : 7)
            context.targetID = focus == .otherApp ? "window:52:8" : "window:42:7"
            context.editableTarget = true
            return context
        }

        func capture(_ app: String, _ window: Int) -> SpokenLiteralTarget? {
            captures += 1
            let onset = focus
            let target: Field
            switch (app, window) {
            case ("com.apple.TextEdit", 7): target = onset == .neighbor ? neighbor : original
            case ("fixture.other", 8): target = otherApp
            default: return nil
            }
            return target.bind { self.focus == onset }
        }

        func append() throws {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0.25 }
            gate.append(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
        }
    }

    @MainActor
    private final class Fixture {
        let io: Endpoints
        let controller: VoiceController
        let lane: RealtimeVoiceLane
        let session: RestrictedVoiceSession
        var inspectedConnections = 0
        var expectedAudioWire: RecordedVoiceWire?
        var badge: HandsFreeIndicator.State? { HandsFreeIndicator.State.current(controller) }

        init(missing: [Permission]) throws {
            let io = Endpoints()
            self.io = io
            io.missing.set(missing)
            let config = Config.restrictedVoice(readPreference: { _ in nil }, writePreference: { _, _ in },
                readRealtimeKey: { io.keyReads += 1; return "offline-fixture" })
            let client = RealtimeVoiceClient(literalOnly: true, wireFactory: { request in
                XCTAssertEqual(request.url?.host, "api.openai.com")
                let wire = RecordedVoiceWire(acknowledgeUpdates: false)
                io.wires.append(wire)
                return wire
            })
            let mic = RealtimeVoiceLane.Microphone(gate: io.gate, permissionGranted: {
                !io.missing.value.contains(.microphone)
            }, resolve: { _ in .init(hardwareID: 1, uid: "synthetic", name: "Synthetic") }, prepare: { device, duplex, _ in
                XCTAssertTrue(duplex, "Restricted listening still requires the duplex microphone contract")
                return await MainActor.run {
                    io.micStarts += 1
                    return .init(name: device.name, format: io.format, firstFrames: 240, startupRecoveries: 0,
                                 playback: .init(realtime: io.output(.realtime), system: io.output(.system), local: io.output(.local)))
                }
            }, stop: {})
            lane = RealtimeVoiceLane(apiKey: { config.restrictedRealtimeKey() }, client: client,
                                     literalOnly: true, microphone: mic)
            controller = try VoiceController(restrictedConfig: config, lane: lane,
                observedFnUpGeneration: io.readUp, permissionStatusReader: {
                    Permission.restrictedVoiceMissing { permission in
                        io.statusReads.withLock { $0.append(permission) }
                        return !io.missing.value.contains(permission)
                    }
                }, resolveDevice: { _ in nil }, readContext: io.context, captureLiteralTarget: io.capture)
            session = RestrictedVoiceSession(controller: controller, monitorStart: {
                io.monitoring = true
                io.heartbeat()
            }, monitorStop: {
                io.monitoring = false
                io.observation.invalidate()
            }, observeUp: io.readUp)
        }
    }

    private func until(_ reason: String, file: StaticString = #filePath, line: UInt = #line,
                       _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                XCTFail(reason, file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func withFixture(missing: [Permission] = [], _ body: (Fixture) async throws -> Void) async throws {
        let f = try Fixture(missing: missing)
        do { try await body(f) }
        catch { await f.session.shutdown(); throw error }
        await f.session.shutdown()
        XCTAssertFalse(f.io.monitoring)
        XCTAssertFalse(f.controller.handsFreeListening)
        XCTAssertEqual(f.io.wires.count, f.inspectedConnections, "Unexpected unacknowledged connection")
        XCTAssertEqual(Set(f.io.statusReads.withLock { $0 }), [.microphone, .accessibility])
        XCTAssertEqual(f.io.neighbor.reads + f.io.neighbor.writes, 0)
        XCTAssertEqual(f.io.otherApp.reads + f.io.otherApp.writes, 0)
        for wire in f.io.wires {
            let sent = await wire.frames()
            XCTAssertEqual(sent.filter { $0["type"]?.string == "session.update" }.count, 1)
            for frame in sent {
                switch frame["type"]?.string {
                case "session.update": break
                case "input_audio_buffer.append":
                    XCTAssertTrue(wire === f.expectedAudioWire, "Unsolicited audio append")
                    XCTAssertEqual(Set(frame.object?.keys.map { $0 } ?? []), ["type", "audio"])
                default: XCTFail("Unexpected outbound frame: " + (frame["type"]?.string ?? "unknown"))
                }
            }
        }
    }

    private func acknowledge(_ f: Fixture, index: Int = 0, mismatch: Bool = false) async throws -> RecordedVoiceWire {
        try await until("Missing connection \(index)") { f.io.wires.count > index }
        let wire = f.io.wires[index]
        XCTAssertEqual(f.inspectedConnections, index)
        f.inspectedConnections += 1
        try await until("Missing session update") { await wire.frames().first?["type"]?.string == "session.update" }
        let frames = await wire.frames()
        let sent = try XCTUnwrap(frames.first?["session"])
        XCTAssertEqual(Set(sent.object?.keys.map { $0 } ?? []),
                       ["type", "audio", "tools", "instructions", "tool_choice", "output_modalities"])
        XCTAssertEqual(sent["type"], .string("realtime"))
        XCTAssertEqual(sent["tools"], .array([]))
        XCTAssertEqual(sent["instructions"], .string(""))
        XCTAssertEqual(sent["tool_choice"], .string("none"))
        XCTAssertEqual(sent["output_modalities"], .array([.string("text")]))
        XCTAssertNil(sent["audio"]?["output"])
        let input = sent["audio"]?["input"]
        XCTAssertEqual(input?["format"], .object(["type": .string("audio/pcm"), "rate": .number(24_000)]))
        XCTAssertEqual(input?["transcription"], .object(["model": .string("gpt-4o-transcribe")]))
        let vad = input?["turn_detection"]
        XCTAssertEqual(vad?["type"], .string("semantic_vad"))
        XCTAssertEqual(vad?["create_response"], .bool(false))
        XCTAssertEqual(vad?["interrupt_response"], .bool(false))
        XCTAssertEqual(f.badge, .starting)
        var ack = try XCTUnwrap(sent.object)
        if mismatch { ack["tool_choice"] = .string("auto") }
        try await wire.push(["type": .string("session.updated"), "session": .object(ack)])
        if mismatch {
            try await until("A mismatched acknowledgement did not fail shut") { f.badge == .unavailable }
        } else {
            try await until("Correct acknowledgement never reached audio-ready listening") { f.badge == .listening }
            XCTAssertTrue(f.controller.microphoneReady)
            XCTAssertEqual(f.io.routeChecks.withLock { $0 }, Set(VoicePlaybackChannel.allCases))
        }
        return wire
    }

    private func onset(_ wire: RecordedVoiceWire, item: String = "one") async throws {
        try await wire.push(["type": .string("input_audio_buffer.speech_started"), "item_id": .string(item)])
    }

    private func finish(_ wire: RecordedVoiceWire, item: String = "one", text: String = "Type blue kite") async throws {
        try await wire.push(["type": .string("input_audio_buffer.committed"), "item_id": .string(item)])
        try await wire.push(["type": .string("conversation.item.input_audio_transcription.completed"),
                             "item_id": .string(item), "transcript": .string(text)])
    }

    func testNoPressFromColdStartCarriesSyntheticAudioAndVerifiesOnlyOneOnsetWrite() async throws {
        try await withFixture { f in
            XCTAssertEqual(f.io.keyReads, 0)
            XCTAssertEqual(f.badge, .notReady)
            f.session.setActive(true)
            let wire = try await acknowledge(f)
            f.expectedAudioWire = wire
            try f.io.append()
            try await until("No converted PCM reached the recording wire") {
                (await wire.frames()).contains { frame in
                    guard frame["type"]?.string == "input_audio_buffer.append", let encoded = frame["audio"]?.string,
                          let pcm = Data(base64Encoded: encoded) else { return false }
                    return pcm.count >= 2 && pcm.contains { $0 != 0 }
                }
            }
            try await onset(wire)
            try await until("The onset field was not read") { f.io.original.reads == 1 }
            f.io.original.beforeSetter = { [weak controller = f.controller] in
                XCTAssertEqual(controller.flatMap { HandsFreeIndicator.State.current($0) }, .processing)
            }
            try await finish(wire, item: "unowned", text: "Type wrong input")
            try await finish(wire)
            try await finish(wire)
            try await until("No verified feedback") { f.controller.detail == "Typed the text." }
            XCTAssertEqual(f.io.original.value, "before blue kite")
            XCTAssertEqual(f.io.original.writes, 1)
            XCTAssertGreaterThan(f.io.original.postWriteReads, 0)
            XCTAssertEqual(f.io.captures, 1)
            XCTAssertEqual(f.badge, .listening)
        }
    }

    func testCurrentPermissionIsRecheckedInsideTheNativeSetter() async throws {
        try await withFixture { f in
            f.session.setActive(true)
            let wire = try await acknowledge(f)
            try await onset(wire)
            try await until("Missing bound field before setter race") { f.io.captures == 1 }
            var attempts = 0
            let missing = f.io.missing
            f.io.original.beforeSetter = {
                attempts += 1
                missing.set([.accessibility])
            }
            try await finish(wire)
            try await until("Setter did not recheck access") { attempts == 1 && !f.controller.handsFreeListening }
            XCTAssertEqual(f.io.original.writes, 0)
            XCTAssertEqual(f.io.original.value, "before sample")
            XCTAssertNotEqual(f.controller.detail, "Typed the text.")
        }
    }

    func testFieldSwitchOtherAppAndFalseReadbackCannotClaimSuccess() async throws {
        enum Scenario: CaseIterable { case fieldSwitch, otherAppAtOnset, otherAppAfterOnset, falseReadback }
        for scenario in Scenario.allCases {
            try await withFixture { f in
                f.session.setActive(true)
                let wire = try await acknowledge(f)
                if scenario == .otherAppAtOnset { f.io.focus = .otherApp }
                let reads = f.io.contextReads
                try await onset(wire)
                try await until("No onset context") { f.io.contextReads > reads }
                switch scenario {
                case .fieldSwitch: f.io.focus = .neighbor
                case .otherAppAfterOnset: f.io.focus = .otherApp
                case .falseReadback: f.io.original.discardWrite = true
                case .otherAppAtOnset: break
                }
                try await finish(wire)
                try await until("No terminal feedback for \(scenario)") {
                    f.controller.detail.contains("No text was sent") || f.controller.detail.contains("couldn’t verify")
                }
                XCTAssertEqual(f.io.original.value, "before sample")
                XCTAssertEqual(f.io.original.writes, scenario == .falseReadback ? 1 : 0)
                XCTAssertEqual(f.io.captures, scenario == .otherAppAtOnset ? 0 : 1)
                let notices = [
                    "The typing target wasn’t available. No text was sent.",
                    "No text was sent. Focus one field and say “type” followed by the text. Quote anything that could be a second instruction."
                ]
                if scenario == .falseReadback {
                    XCTAssertEqual(f.controller.detail, "I couldn’t verify the insertion. Check the field before trying again.")
                    XCTAssertGreaterThan(f.io.original.postWriteReads, 0)
                } else {
                    XCTAssertTrue(notices.contains(f.controller.detail))
                }
                XCTAssertEqual(f.controller.status, .error(f.controller.detail))
                let show = VoiceWindows.showsPanel(status: f.controller.status, automatic: f.controller.quietHandsFreePresentation,
                    hasAsk: f.controller.pendingTaskApproval != nil || !f.controller.pendingQuestions.isEmpty,
                    linger: false, microphoneTest: f.controller.isMicrophoneTest)
                XCTAssertTrue(show)
                XCTAssertNil(HandsFreeIndicator.State.current(f.controller, obscured: show))
                XCTAssertEqual(f.badge, .listening)
            }
        }
    }

    func testObservationLossAndRevocationDefeatDelayedFinal() async throws {
        enum Loss: CaseIterable { case fnHeld, fnDownAndUp, gap, unknown, escape, lock, micRevoked, axRevoked }
        for loss in Loss.allCases {
            try await withFixture { f in
                f.session.setActive(true)
                let wire = try await acknowledge(f)
                try await onset(wire)
                try await until("No bound onset before \(loss)") { f.io.original.reads == 1 }
                switch loss {
                case .fnHeld: f.io.fnDown = true
                case .fnDownAndUp:
                    f.io.fnDown = true; f.io.heartbeat()
                    f.io.fnDown = false; f.io.heartbeat()
                case .gap: f.io.now = f.io.now.advanced(by: .seconds(1))
                case .unknown: f.io.fnDown = nil
                case .escape: f.io.observation.invalidate(); f.session.escape()
                case .lock: f.session.setActive(false)
                case .micRevoked: f.io.missing.set([.microphone])
                case .axRevoked: f.io.missing.set([.accessibility])
                }
                try await finish(wire)
                try await until("Stale readiness after \(loss)") { !f.controller.handsFreeListening }
                XCTAssertEqual(f.io.original.writes, 0)
                XCTAssertEqual(f.io.original.value, "before sample")
                XCTAssertNotEqual(f.controller.detail, "Typed the text.")
                XCTAssertNotEqual(f.badge, .listening)
            }
        }
    }

    func testHeldAtStartupHealthAndPauseResumeRequireNewAuthority() async throws {
        try await withFixture { f in
            f.io.fnDown = true
            f.session.setActive(true)
            f.session.refresh()
            XCTAssertFalse(f.controller.handsFreeListening)
            XCTAssertEqual(f.io.keyReads, 0)
            XCTAssertEqual(f.io.micStarts, 0)
            XCTAssertTrue(f.io.wires.isEmpty)
            f.io.fnDown = false
            f.io.heartbeat()
            f.session.inputChanged()
            let old = try await acknowledge(f)
            try await onset(old)
            try await until("Missing onset before pause") { f.io.captures == 1 }
            f.session.toggle()
            XCTAssertEqual(f.badge, .paused)
            f.session.refresh()
            try await finish(old)
            f.session.toggle()
            let resumed = try await acknowledge(f, index: 1)
            try await finish(resumed)
            try await onset(resumed, item: "fresh")
            try await until("Missing fresh onset after resume") { f.io.captures == 2 }
            XCTAssertEqual(f.io.original.writes, 0)
            try await finish(resumed, item: "fresh", text: "Type fresh input")
            try await until("Fresh input never verified") { f.controller.detail == "Typed the text." }
            XCTAssertEqual(f.io.original.writes, 1)
            XCTAssertEqual(f.io.original.value, "before fresh input")
            f.io.fnDown = true
            f.session.refresh()
            XCTAssertNotEqual(f.badge, .listening)
        }
    }

    func testBroadAcknowledgementIsRejectedBeforeAudioOrFieldAccess() async throws {
        try await withFixture { f in
            f.session.setActive(true)
            let rejected = try await acknowledge(f, mismatch: true)
            try f.io.append()
            try await onset(rejected)
            try await finish(rejected)
            XCTAssertEqual(f.io.captures, 0)
            XCTAssertEqual(f.io.original.writes, 0)
            let frames = await rejected.frames()
            XCTAssertEqual(frames.compactMap { $0["type"]?.string }, ["session.update"])
        }
    }

    func testFailedDuplexRouteCannotAuthorizeDelayedLiteral() async throws {
        for channel in VoicePlaybackChannel.allCases {
            try await withFixture { f in
                f.session.setActive(true)
                let wire = try await acknowledge(f)
                try await onset(wire)
                try await until("No onset before output loss") { f.io.captures == 1 }
                f.io.failedRoute.set(channel)
                try await finish(wire)
                try await until("Failed \(channel) route left badge listening") { f.badge == .unavailable }
                XCTAssertEqual(f.io.original.writes, 0)
                XCTAssertNotEqual(f.controller.detail, "Typed the text.")
            }
        }
    }

    func testExplicitRetryRevalidatesAuthorityBeforeReconnectingAndRejectsOldFinal() async throws {
        enum Boundary: CaseIterable { case transport, route, inactive, permissionLost, fnHeld }
        for boundary in Boundary.allCases {
            try await withFixture { f in
                f.session.setActive(true)
                let old = try await acknowledge(f)
                let generation = try XCTUnwrap(f.io.readUp())
                try await onset(old)
                try await until("No bound field before failure") { f.io.captures == 1 }
                if boundary == .route {
                    f.io.failedRoute.set(.local)
                } else {
                    await old.close()
                }
                try await until("Failure not published") { f.badge == .unavailable }
                f.io.failedRoute.set(nil)
                let starts = f.io.micStarts
                for _ in 0..<3 { f.session.refresh() }
                try await Task.sleep(for: .milliseconds(75))
                XCTAssertEqual(f.badge, .unavailable)
                XCTAssertEqual(f.io.wires.count, 1, "Health refresh must not retry a failed transport")
                XCTAssertEqual(f.io.micStarts, starts)
                XCTAssertEqual(f.io.readUp(), generation)
                switch boundary {
                case .inactive: f.session.setActive(false)
                case .permissionLost: f.io.missing.set([.accessibility])
                case .fnHeld: f.io.fnDown = true
                case .transport, .route: break
                }
                f.session.retry()
                try await finish(old, text: "Type stale final")
                if boundary == .transport || boundary == .route {
                    let fresh = try await acknowledge(f, index: 1)
                    XCTAssertGreaterThan(f.io.micStarts, starts)
                    XCTAssertEqual(f.io.readUp(), generation)
                    try await finish(fresh, text: "Type stale final")
                    try await onset(fresh, item: "retry")
                    try await until("Retry did not bind a new field") { f.io.captures == 2 }
                    XCTAssertEqual(f.io.original.writes, 0)
                    try await finish(fresh, item: "retry", text: "Type fresh final")
                    try await until("Fresh retry did not verify") { f.controller.detail == "Typed the text." }
                    XCTAssertEqual(f.io.original.value, "before fresh final")
                    XCTAssertEqual(f.io.original.writes, 1)
                } else {
                    try await Task.sleep(for: .milliseconds(75))
                    XCTAssertNotEqual(f.badge, .listening)
                    XCTAssertEqual(f.io.wires.count, 1)
                    XCTAssertEqual(f.io.micStarts, starts)
                    XCTAssertEqual(f.io.original.writes, 0)
                }
            }
        }
    }

    func testMissingStartupGrantNeverPreparesMicrophoneOrOpensWire() async throws {
        for denied: [Permission] in [[.microphone], [.accessibility], [.microphone, .accessibility]] {
            try await withFixture(missing: denied) { f in
                XCTAssertEqual(f.controller.missingPermissions, denied)
                f.session.setActive(true)
                f.session.refresh()
                f.session.inputChanged()
                f.session.toggle()
                XCTAssertFalse(f.controller.handsFreeListening)
                XCTAssertNotEqual(f.badge, .listening)
                XCTAssertEqual(f.io.keyReads, 0)
                XCTAssertEqual(f.io.micStarts, 0)
                XCTAssertTrue(f.io.wires.isEmpty)
                XCTAssertEqual(f.io.captures, 0)
            }
        }
    }

    func testRestrictedControllerAndLaneRejectManualTypedAndHostileToolInput() async throws {
        try await withFixture { f in
            f.session.setActive(true)
            let wire = try await acknowledge(f)
            f.controller.begin()
            f.controller.beginDictation()
            f.controller.submitTypedCommand("Type forbidden")
            do { _ = try await f.lane.start(session: UUID(), inputUID: nil, transcribe: true); XCTFail("Manual lane admitted") }
            catch is VoiceError {}
            do { try await f.lane.submitTyped("Type forbidden", sessionID: UUID()); XCTFail("Typed lane admitted") }
            catch is VoiceError {}
            XCTAssertEqual(f.io.wires.count, 1)
            XCTAssertEqual(f.badge, .listening)
            try await onset(wire)
            try await until("No bound target before hostile tool frame") { f.io.original.reads == 1 }
            try await wire.push(["type": .string("response.function_call_arguments.done"), "response_id": .string("foreign"),
                "call_id": .string("foreign-call"), "name": .string("computer_task"),
                "arguments": .string(#"{"goal":"Type forbidden"}"#)])
            try await finish(wire)
            try await until("Tool frames must close the literal transport") { f.badge == .unavailable }
            XCTAssertEqual(f.io.original.writes, 0)
            XCTAssertEqual(f.controller.cuaTasks.count, 0)
        }
    }
}
