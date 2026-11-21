import AVFoundation
import XCTest
@testable import Jarvis

@MainActor
final class LiveVoiceTests: XCTestCase {
    private final class FakeMicrophone: LiveMicrophoneDriving {
        let relay = LiveInputRelay(sampleRate: 1000)
        var onInput: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        var starts = 0, stops = 0
        var tappedAtStop: [Bool] = []
        func start() throws { starts += 1 }
        func stop() { stops += 1; tappedAtStop.append(onInput != nil) }
    }

    private final class FakeWakeWord: WakeWordDetecting, @unchecked Sendable {
        var heard: (@MainActor (TimeInterval) -> Void)?
        var starts = 0, stops = 0
        func start(name: String, heard: @escaping @MainActor (TimeInterval) -> Void) throws {
            starts += 1
            self.heard = heard
        }
        func stop() { stops += 1; heard = nil }
        func hear(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
        func problem(with name: String) -> String? { nil }
    }

    private final class FakeTransport: LiveTransport, @unchecked Sendable {
        let incoming: AsyncStream<LiveTransportEvent>
        private let continuation: AsyncStream<LiveTransportEvent>.Continuation
        private(set) var sent: [String] = []
        init() { (incoming, continuation) = AsyncStream.makeStream() }
        func offer() async throws -> String { "offer-sdp" }
        func accept(answer: String) async throws {}
        func send(_ message: Data) throws {
            let json = try JSONSerialization.jsonObject(with: message) as? [String: Any]
            sent.append(json?["type"] as? String ?? "")
        }
        func close() { continuation.finish() }
        func deliver(_ json: String) { continuation.yield(.message(Data(json.utf8))) }
    }

    private struct FakeBroker: LiveSessionCreating {
        func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
            LiveSessionAnswer(id: "live_1", sdp: "answer-sdp")
        }
    }

    private let started = #"{"type":"session.started","session":{"id":"live_1"}}"#
    private func heard(_ text: String) -> String {
        #"{"type":"session.input_transcript.delta","delta":"\#(text)","start_ms":0,"end_ms":10}"#
    }
    private let answer = #"{"type":"session.output_transcript.delta","delta":"Tokyo.","start_ms":20,"end_ms":30}"#

    private var microphone: FakeMicrophone!
    private var wakeWord: FakeWakeWord!
    private var transports: [FakeTransport] = []
    private var configs: [LiveSessionConfig] = []

    private func voice(_ timings: LiveListening.Timings = .init()) throws -> LiveVoice {
        microphone = FakeMicrophone()
        wakeWord = FakeWakeWord()
        let voice = LiveVoice(microphone: microphone, wakeWord: wakeWord, timings: timings) { [unowned self] name in
            let transport = FakeTransport()
            self.transports.append(transport)
            let config = LiveSessionConfig(instructions: LiveVoice.instructions(name: name))
            self.configs.append(config)
            return LiveSession(transport: transport, broker: FakeBroker(), config: config)
        }
        try voice.arm(name: "Nova")
        return voice
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testArmingStartsTheMicrophoneAndTheWakeWordOnly() throws {
        let voice = try voice()
        XCTAssertTrue(voice.armed)
        XCTAssertEqual(microphone.starts, 1)
        XCTAssertEqual(wakeWord.starts, 1)
        XCTAssertEqual(voice.listening.state, .asleep)
        XCTAssertTrue(transports.isEmpty, "Nothing leaves the Mac before the wake word")
        XCTAssertEqual(voice.glow, .hidden)
    }

    func testTheWakeWordOpensASessionThatHearsTheRequestFromTheWakeMoment() async throws {
        let voice = try voice()
        let speech = [Float](repeating: 0.2, count: 1000)
        speech.withUnsafeBufferPointer { microphone.relay.write($0, endingAt: 101) }
        wakeWord.heard?(100.5)
        XCTAssertEqual(voice.listening.state, .connecting)
        XCTAssertEqual(voice.glow, .hearing)
        XCTAssertEqual(wakeWord.stops, 1, "The wake word rests while a session is open")
        XCTAssertTrue(configs[0].instructions.contains("Hey Nova"))
        var out = [Float](repeating: -1, count: 100)
        out.withUnsafeMutableBufferPointer { microphone.relay.read(into: $0) }
        XCTAssertEqual(out, [Float](repeating: 0, count: 100), "Held until the session starts")
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        out.withUnsafeMutableBufferPointer { microphone.relay.read(into: $0) }
        XCTAssertEqual(out, [Float](repeating: 0.2, count: 100), "The request plays into the session")
    }

    func testThatsAllClosesTheSessionAndListensForTheWakeWordAgain() async throws {
        let voice = try voice(LiveListening.Timings(settle: 0.05))
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        transports[0].deliver(heard("That's all, Nova."))
        try await waitUntil { voice.listening.state == .asleep }
        try await waitUntil { transports[0].sent.contains("session.close") }
        XCTAssertEqual(wakeWord.starts, 2)
        XCTAssertEqual(voice.glow, .hidden)
    }

    func testAFalseWakeClosesOnItsOwn() async throws {
        let voice = try voice(LiveListening.Timings(falseWake: 0.1))
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        try await waitUntil { voice.listening.state == .asleep }
        try await waitUntil { transports[0].sent.contains("session.close") }
    }

    func testThinkingGlowsAfterTheRequestAndControlWordsReachTheirHandler() async throws {
        let voice = try voice(LiveListening.Timings(thinkingAfter: 0.05, settle: 0.1))
        var controls: [LiveControlWord] = []
        voice.onControl = { controls.append($0) }
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        transports[0].deliver(heard("What's the capital of Japan?"))
        try await waitUntil { voice.glow == .thinking }
        transports[0].deliver(answer)
        try await waitUntil { voice.glow == .hearing }
        transports[0].deliver(heard("Cancel that."))
        try await waitUntil { controls == [.cancel] }
        XCTAssertTrue(voice.listening.sessionOpen)
    }

    func testDisarmingClosesTheSessionAndReleasesTheMicrophone() async throws {
        let voice = try voice()
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        voice.disarm()
        XCTAssertFalse(voice.armed)
        XCTAssertEqual(microphone.stops, 1)
        XCTAssertEqual(microphone.tappedAtStop, [true], "The engine stops before its tap is cleared, so the audio thread never reads a torn closure")
        XCTAssertNil(microphone.onInput)
        try await waitUntil { transports[0].sent.contains("session.close") }
        wakeWord.heard?(1)
        XCTAssertEqual(transports.count, 1)
    }
}
