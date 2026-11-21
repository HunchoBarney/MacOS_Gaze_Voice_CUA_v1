import AVFoundation
import XCTest
@testable import Jarvis
import JarvisCore

/// KAR-75 L2 adapters end to end: a fake Live transport through LiveVoice,
/// the delegation bridge and the real VoiceTaskCoordinator to a fake driver.
@MainActor
final class LiveDelegationTests: XCTestCase {
    private final class FakeMicrophone: LiveMicrophoneDriving {
        let relay = LiveInputRelay(sampleRate: 1000)
        var onInput: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        func start() throws {}
        func stop() {}
        func useInput(uid: String) {}
    }

    private final class FakeWakeWord: WakeWordDetecting, @unchecked Sendable {
        var heard: (@MainActor (TimeInterval) -> Void)?
        func start(name: String, heard: @escaping @MainActor (TimeInterval) -> Void) throws { self.heard = heard }
        func stop() { heard = nil }
        func hear(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
        func problem(with name: String) -> String? { nil }
    }

    /// Records what Jarvis sends to Live.
    private final class FakeTransport: LiveTransport, @unchecked Sendable {
        let incoming: AsyncStream<LiveTransportEvent>
        private let continuation: AsyncStream<LiveTransportEvent>.Continuation
        private let lock = NSLock()
        private var messages: [[String: Any]] = []
        init() { (incoming, continuation) = AsyncStream.makeStream() }
        func offer() async throws -> String { "offer-sdp" }
        func accept(answer: String) async throws {}
        func send(_ message: Data) throws {
            let json = try JSONSerialization.jsonObject(with: message) as? [String: Any] ?? [:]
            lock.withLock { messages.append(json) }
        }
        func close() { continuation.finish() }
        func deliver(_ json: String) { continuation.yield(.message(Data(json.utf8))) }
        /// What Live was told for `delegationID`.
        func appends(for delegationID: String) -> [(type: String, content: String)] {
            lock.withLock {
                messages.filter { $0["delegation_id"] as? String == delegationID }
                    .map { ($0["type"] as? String ?? "", $0["content"] as? String ?? "") }
            }
        }
    }

    private struct FakeBroker: LiveSessionCreating {
        func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
            LiveSessionAnswer(id: "live_1", sdp: "answer-sdp")
        }
    }

    /// Mail frontmost with Archive and Send in its toolbar. Records every press.
    private final class Desk: @unchecked Sendable {
        static let mailPID = 424_401
        private let lock = NSLock()
        private var pressed: [String] = []
        var presses: [String] { lock.withLock { pressed } }

        func call(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            if ["click", "press", "perform_action"].contains(tool) { lock.withLock { pressed.append(tool) } }
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Mail"), "bundle_id": .string("com.apple.mail"),
                                                         "pid": .number(Double(Self.mailPID)), "active": .bool(true)])])])
            case "list_windows":
                return .object(["windows": .array([.object([
                    "window_id": .number(11), "pid": .number(Double(Self.mailPID)), "app_name": .string("Mail"),
                    "title": .string("New Message"),
                    "bounds": .object(["x": .number(80), "y": .number(60), "width": .number(1100), "height": .number(760)]),
                    "z_index": .number(1), "is_on_screen": .bool(true), "is_minimized": .bool(false)])])])
            case "get_window_state":
                return .object(["pid": .number(Double(Self.mailPID)), "window_id": .number(11),
                                "window_title": .string("New Message"), "snapshot_id": .string("live-snapshot"),
                                "elements": .array(["Archive", "Send"].enumerated().map { index, label in
                                    .object(["element_index": .number(Double(index + 1)),
                                             "element_token": .string("tok-\(index + 1)"),
                                             "role": .string("AXButton"), "label": .string(label),
                                             "actions": .array([.string("AXPress")]),
                                             "frame": .object(["x": .number(120 + Double(index) * 64), "y": .number(70),
                                                               "w": .number(56), "h": .number(28)])])
                                })])
            default:
                return .object(["effect": .string("confirmed")])
            }
        }
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private var wakeWord: FakeWakeWord!
    private var transports: [FakeTransport] = []
    private var desk: Desk!
    private var coordinator: VoiceTaskCoordinator!
    private var voice: LiveVoice!
    private var bridge: DelegationBridge!

    override func setUp() async throws {
        usePrivateStandingGrants()
        transports = []
        desk = Desk()
        let config = Config(defaults: UserDefaults(suiteName: "live-delegation-\(UUID().uuidString)")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        config.alwaysAllowComputerUse = true
        let desk = desk!
        coordinator = VoiceTaskCoordinator(
            config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay(),
            resolver: AppResolver(exactBundleApps: { _ in [] }, listApps: {
                [AppResolver.App(name: "Mail", bundle: "com.apple.mail", pid: Desk.mailPID)]
            }),
            commandDriver: { tool, args in try await desk.call(tool, args) },
            foregroundAppLauncher: { _ in Desk.mailPID },
            desktopSpaces: DesktopSpaceSwitch.System(
                roots: { [] }, children: { _ in nil }, attr: { _, _ in nil },
                pressable: { _ in false }, press: { _ in false },
                displayID: { 9 }, labels: { nil },
                openMissionControl: {}, pause: {},
                watchSpaceChange: { { _ in true } },
                layout: { nil }, shortcutEnabled: { _ in true }),
            activateApp: { _ in })
        coordinator.gazeContextProvider = { nil }
        wakeWord = FakeWakeWord()
        voice = LiveVoice(microphone: FakeMicrophone(), wakeWord: wakeWord) { [unowned self] name in
            let transport = FakeTransport()
            self.transports.append(transport)
            return LiveSession(transport: transport, broker: FakeBroker(),
                               config: LiveSessionConfig(instructions: LiveVoice.instructions(name: name)))
        }
        try voice.arm(name: "Nova")
        bridge = DelegationBridge.connect(voice, to: coordinator,
                                          timing: .init(settleMs: 300, maxWait: .milliseconds(50), lagWait: .milliseconds(50)))
    }

    override func tearDown() async throws {
        voice.disarm()
        coordinator.stopAll()
        coordinator.shutdown()
    }

    /// Says the name, then plays `events` in from Live.
    private func converse(_ events: [String]) async throws -> FakeTransport {
        wakeWord.heard?(0)
        try await waitUntil { !self.transports.isEmpty }
        let live = transports[0]
        live.deliver(#"{"type":"session.started","session":{"id":"live_1"}}"#)
        try await waitUntil { self.voice.listening.state == .talking }
        for event in events { live.deliver(event) }
        return live
    }

    private func said(_ text: String, _ start: Int, _ end: Int) -> String {
        #"{"type":"session.input_transcript.delta","delta":"\#(text)","start_ms":\#(start),"end_ms":\#(end)}"#
    }

    private func delegation(_ id: String, at offset: Int) -> String {
        #"{"type":"session.delegation.created","offset_ms":\#(offset),"delegation":{"id":"\#(id)","target":"client"}}"#
    }

    private func state(of id: String) -> DelegationLedger.State? {
        bridge.ledger.state(of: .init(liveSessionID: "live_1", delegationID: id))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testADelegationPressesOnceAndItsDuplicatesDoNothing() async throws {
        _ = try await converse([said("click Archive in Mail", 200, 900), delegation("del_1", at: 500),
                                delegation("del_1", at: 500), delegation("del_2", at: 600)])
        try await waitUntil { !self.desk.presses.isEmpty }
        try await waitUntil { self.state(of: "del_2") != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(desk.presses.count, 1, "one press for one set of words")
        guard case .committed? = state(of: "del_1") else { return XCTFail("del_1: \(String(describing: state(of: "del_1")))") }
        XCTAssertEqual(state(of: "del_2"), .declined("nothing new"))
    }

    func testNoWaitStopTakesNoAction() async throws {
        _ = try await converse([said("click Archive in Mail, no wait, stop", 200, 1500), delegation("del_1", at: 1600)])
        try await waitUntil { self.state(of: "del_1") != nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state(of: "del_1"), .declined("taken back"))
        XCTAssertEqual(desk.presses, [])
        XCTAssertTrue(coordinator.tasks.isEmpty, "nothing reached the coordinator")
    }

    func testAfterStandbyClickingSendAsksFirstAndLiveHearsTheQuestion() async throws {
        let live = try await converse([#"{"type":"session.paused"}"#, #"{"type":"session.resumed"}"#,
                                       said("click Send in Mail", 12000, 12600), delegation("del_1", at: 12000)])
        try await waitUntil { self.coordinator.tasks.contains { $0.ask != nil } || !self.desk.presses.isEmpty }
        XCTAssertEqual(desk.presses, [], "after Standby another voice must not press Send unasked (D3)")
        guard case .confirm(let question)? = coordinator.tasks.compactMap(\.ask).first else {
            return XCTFail("expected a yes/no question before Send")
        }
        XCTAssertTrue(question.contains("sends this to other people"), question)
        try await waitUntil { live.appends(for: "del_1").contains { $0.type == "session.commentary.append" } }
        XCTAssertTrue(live.appends(for: "del_1").contains {
            $0.type == "session.commentary.append" && $0.content.contains("sends this to other people")
        }, "the question goes back to Live with its delegation")
    }

    func testOtherTaskEventsStillReachTheirOwner() {
        var passed: [String] = []
        let coordinator = VoiceTaskCoordinator(config: Config(defaults: UserDefaults(suiteName: "live-sink-\(UUID().uuidString)")!,
                                                              keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                                                              environment: [:]),
                                               jevRoute: { nil },
                                               gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
                                               overlay: TargetOverlay(), commandDriver: { _, _ in .object([:]) })
        defer { coordinator.shutdown() }
        coordinator.taskEventSink = { _, payload, _ in passed.append(payload) }
        _ = DelegationBridge.connect(voice, to: coordinator)
        coordinator.taskEventSink(UUID(), "typed work", true)
        XCTAssertEqual(passed, ["typed work"], "the bridge takes only the work it started")
    }
}
