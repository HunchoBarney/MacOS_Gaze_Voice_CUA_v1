import AVFoundation
import XCTest
@testable import Jarvis

/// Under voice.live, Standby arms L3's Live listening, and only after this
/// lane's own microphone is released: one microphone owner at a time.
@MainActor
final class VoiceLiveStandbyTests: XCTestCase {
    private final class StubCapture: SpeechCapturing {
        var onEvent: ((UUID, SpeechEvent) -> Void)?
        var onReadiness: ((SpeechReadiness) -> Void)?
        var open = true
        var prepares = 0
        var suspends = 0
        func prepare(inputUID: String?) async throws -> String { prepares += 1; open = true; return "stub mic" }
        func suspend() async { suspends += 1; open = false }
        func start(session: UUID, inputUID: String?, transcribe: Bool) async throws -> String { open = true; return "stub mic" }
        func finish() {}
        func cancel() {}
    }

    private final class FakeMicrophone: LiveMicrophoneDriving {
        let relay = LiveInputRelay(sampleRate: 1000)
        var onInput: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        var laneOpenAtStart: [Bool] = []
        var laneIsOpen: () -> Bool = { false }
        var stops = 0
        func start() throws { laneOpenAtStart.append(laneIsOpen()) }
        func stop() { stops += 1 }
    }

    private final class FakeWakeWord: WakeWordDetecting, @unchecked Sendable {
        func start(name: String, heard: @escaping @MainActor (TimeInterval) -> Void) throws {}
        func stop() {}
        func hear(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
        func problem(with name: String) -> String? { nil }
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    override func tearDown() {
        ListeningPolicy.wakeWord = nil
        super.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testArmingLiveReleasesTheLanesMicrophoneFirst() async throws {
        let wake = FakeWakeWord()
        ListeningPolicy.wakeWord = wake
        let config = Config(defaults: UserDefaults(suiteName: "voice-live-standby-\(UUID().uuidString)")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                            environment: ["OPENAI_API_KEY": "test-key"])
        config.listeningMode = .standby
        config.voiceLive = true
        let capture = StubCapture()
        let controller = VoiceController(config: config, speech: capture, authorize: { true },
                                         timings: VoiceTimings(), cuaRuntime: testCoordinator(config),
                                         otherAppUsesMicrophone: { false })
        addTeardownBlock { await controller.shutdown() }
        let microphone = FakeMicrophone()
        microphone.laneIsOpen = { capture.open }
        let live = LiveVoice(microphone: microphone, wakeWord: wake) { _ in
            XCTFail("No session before a wake")
            return LiveSession(transport: NeverTransport(), broker: NeverBroker(), config: LiveSessionConfig(instructions: ""))
        }
        controller.liveVoice = live
        capture.open = true
        controller.armStandby()
        try await waitUntil { live.armed }
        XCTAssertEqual(microphone.laneOpenAtStart, [false], "The lane's microphone is released before Live records")
        XCTAssertGreaterThanOrEqual(capture.suspends, 1)
        XCTAssertEqual(controller.handsFreeState, .standby)
    }

    func testALiveNoticeShowsOnTheTabWhenNothingElseDoesThenClears() async throws {
        let config = Config(defaults: UserDefaults(suiteName: "voice-live-notice-\(UUID().uuidString)")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.voiceLive = true
        let controller = VoiceController(config: config, speech: StubCapture(), authorize: { true },
                                         timings: VoiceTimings(), cuaRuntime: testCoordinator(config),
                                         otherAppUsesMicrophone: { false })
        addTeardownBlock { await controller.shutdown() }
        XCTAssertEqual(IndicatorPhase.current(controller), .hidden)
        controller.showLiveNotice("You've used 82% of this month's Live voice. It renews on December 1.", for: 0.1)
        XCTAssertEqual(IndicatorPhase.current(controller), .notice)
        try await waitUntil { controller.liveNotice == nil }
        XCTAssertEqual(IndicatorPhase.current(controller), .hidden)
    }

    private func testCoordinator(_ config: Config) -> VoiceTaskCoordinator {
        VoiceTaskCoordinator(config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })))
    }

    private final class NeverTransport: LiveTransport, @unchecked Sendable {
        let incoming = AsyncStream<LiveTransportEvent> { _ in }
        func offer() async throws -> String { "" }
        func accept(answer: String) async throws {}
        func send(_ message: Data) throws {}
        func close() {}
    }

    private struct NeverBroker: LiveSessionCreating {
        func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
            LiveSessionAnswer(id: "", sdp: "")
        }
    }
}
