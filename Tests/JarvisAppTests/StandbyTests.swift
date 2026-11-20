import AVFoundation
import XCTest
@testable import Jarvis

/// Standby: the wake word hears the lane's microphone tap, a wake opens a
/// hands-free session that closes when it goes quiet, and Fn or a pause
/// stands it down. No microphone or socket is used.
@MainActor
final class StandbyTests: XCTestCase {
    private final class FakeWakeWord: WakeWordDetecting, @unchecked Sendable {
        var starts = 0
        var stops = 0
        var heard: (@MainActor (TimeInterval) -> Void)?
        func start(heard: @escaping @MainActor (TimeInterval) -> Void) throws { starts += 1; self.heard = heard }
        func stop() { stops += 1; heard = nil }
        func hear(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
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

    private func standby() -> (VoiceController, FakeWakeWord) {
        let wake = FakeWakeWord()
        ListeningPolicy.wakeWord = wake
        let config = Config(defaults: UserDefaults(suiteName: "standby-\(UUID().uuidString)")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                            environment: ["OPENAI_API_KEY": "test-key"])
        config.listeningMode = .standby
        var timings = VoiceTimings()
        timings.wakeSessionQuiet = 0.5
        let controller = VoiceController(config: config, speech: RealtimeVoiceLane(apiKey: { "test-key" }),
                                         authorize: { true }, timings: timings, cuaRuntime: testCoordinator(config))
        addTeardownBlock { await controller.shutdown() }
        return (controller, wake)
    }

    func testStandbyListensForTheWakeWordWithoutStreaming() {
        let (controller, wake) = standby()
        XCTAssertFalse(controller.handsFreeEnabled, "nothing streams in Standby")
        XCTAssertTrue(controller.listensWithoutFn)
        controller.armStandby()
        XCTAssertEqual(wake.starts, 1)
        XCTAssertEqual(controller.handsFreeState, .standby)
        XCTAssertTrue(controller.listeningWithoutFn)
        controller.armStandby()
        XCTAssertEqual(wake.starts, 1, "arming twice starts the engine once")
    }

    func testPauseStandsStandbyDown() {
        let (controller, wake) = standby()
        controller.armStandby()
        controller.pauseHandsFree()
        XCTAssertEqual(wake.stops, 1)
        XCTAssertEqual(controller.handsFreeState, .paused)
        XCTAssertFalse(controller.listeningWithoutFn)
        controller.armStandby()
        XCTAssertEqual(wake.starts, 1, "a paused Standby doesn't rearm on its own")
    }

    func testAWakeOpensASessionThatClosesWhenQuietAndRearms() async {
        let (controller, wake) = standby()
        controller.armStandby()
        wake.heard?(ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(wake.stops, 1, "the engine rests during the session")
        XCTAssertTrue(controller.listeningWithoutFn)
        await poll(seconds: 5) { wake.starts == 2 }
        XCTAssertEqual(wake.starts, 2, "Standby rearms after the quiet session")
        XCTAssertEqual(controller.handsFreeState, .standby)
    }

    func testLeavingStandbyStopsTheWakeWord() async {
        let (controller, wake) = standby()
        controller.armStandby()
        controller.config.listeningMode = .pushToTalk
        await poll(seconds: 2) { wake.stops == 1 }
        XCTAssertEqual(wake.stops, 1)
        XCTAssertNotEqual(controller.handsFreeState, .standby)
        XCTAssertFalse(controller.listensWithoutFn)
    }

    func testTheTapFeedsTheWakeWordAndKeepsFiveSecondsForTheSession() throws {
        final class Counter: WakeWordDetecting, @unchecked Sendable {
            var frames = 0
            func start(heard: @escaping @MainActor (TimeInterval) -> Void) throws {}
            func stop() {}
            func hear(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) { frames += Int(buffer.frameLength) }
        }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let gate = MicrophoneAudioGate()
        let counter = Counter()
        gate.listen(counter)
        let start = ProcessInfo.processInfo.systemUptime - 6
        for second in 0..<6 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            gate.append(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start + Double(second))))
        }
        XCTAssertEqual(counter.frames, 96_000)
        gate.listen(nil)
        let feed = try ConvertedAudioFeed(input: format, output: format)
        defer { feed.finish() }
        let since = start + 3.5
        gate.open(feed, at: AVAudioTime.hostTime(forSeconds: since))
        var replayed = 0
        let drained = expectation(description: "replayed")
        Task {
            for try await buffer in feed.stream {
                replayed += Int(buffer.frameLength)
                if replayed >= 35_000 { drained.fulfill(); break }
            }
        }
        wait(for: [drained], timeout: 2)
        XCTAssertLessThanOrEqual(replayed, 40_000, "nothing before the wake moment is replayed")
    }

    func testTheDetectorHearsTheWakePhraseFromTheTap() async throws {
        guard Vosk.directory() != nil else { throw XCTSkip("Vosk isn't fetched: run ThirdParty/Vosk/fetch.sh") }
        let detector = VoskWakeWordDetector()
        var moments: [TimeInterval] = []
        try detector.start { moments.append($0) }
        defer { detector.stop() }
        let samples = try spoken("What's the weather like? Hey Jarvis, open Mail.") + [Float](repeating: 0, count: 96_000)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let origin: TimeInterval = 1_000
        for offset in stride(from: 0, to: samples.count, by: 1_024) {
            let count = min(1_024, samples.count - offset)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count) }
            detector.hear(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: origin + Double(offset) / 48_000)))
        }
        await poll(seconds: 20) { !moments.isEmpty }
        XCTAssertEqual(moments.count, 1)
        let moment = try XCTUnwrap(moments.first) - origin
        XCTAssertGreaterThan(moment, 1.0, "after the opening question")
        XCTAssertLessThan(moment, Double(samples.count) / 48_000 - 1.5, "while the phrase is still in the pre-roll")
    }

    private func testCoordinator(_ config: Config) -> VoiceTaskCoordinator {
        VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })))
    }

    private func poll(seconds: TimeInterval, _ done: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done(), ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func spoken(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("standby-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=LEF32@48000", text]
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { throw XCTSkip("say is unavailable") }
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say could not render speech")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
