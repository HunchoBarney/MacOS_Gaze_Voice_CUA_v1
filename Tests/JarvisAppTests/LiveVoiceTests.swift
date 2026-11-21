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
        var inputs: [String] = []
        func useInput(uid: String) { inputs.append(uid) }
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
    private let closed = #"{"type":"session.closed","event_id":"e9","reason":"client_requested","session":{"id":"live_1"},"usage":{"seconds":5,"active_seconds":5,"paused_seconds":0}}"#
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
        XCTAssertEqual(microphone.starts, 1, "Recording restarts only once the call has closed")
        transports[0].deliver(closed)
        try await waitUntil { microphone.starts == 2 }
        XCTAssertEqual(voice.glow, .hidden)
    }

    func testAFalseWakeTimesOutThenRecordingRestartsAndTheNextWakeOpensASession() async throws {
        let voice = try voice(LiveListening.Timings(falseWake: 0.1))
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        try await waitUntil { voice.listening.state == .asleep }
        try await waitUntil { transports[0].sent.contains("session.close") }
        transports[0].deliver(closed)
        try await waitUntil { microphone.starts == 2 }
        wakeWord.heard?(1)
        XCTAssertEqual(transports.count, 2, "The second wake opens a new session")
        transports[1].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
    }

    func testThinkingGlowsAfterTheRequestAndControlWordsReachTheirHandler() async throws {
        let voice = try voice(LiveListening.Timings(thinkingAfter: 0.05, settle: 0.1))
        var controls: [LiveControlWord] = []
        voice.onControl = { controls.append($0) }
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        transports[0].deliver(heard("What's the capital of Japan?"))
        try await waitUntil { voice.glow == .thinking }
        transports[0].deliver(answer)
        try await waitUntil { voice.glow == .hearing }
        try await Task.sleep(for: .milliseconds(200))
        transports[0].deliver(heard("Cancel that."))
        try await waitUntil { controls == [.cancel] }
        XCTAssertTrue(voice.listening.sessionOpen)
    }

    func testTheWakeTestIgnoresJarvisSayingThePhraseAndOpensNothing() async throws {
        let voice = try voice()
        let heard = await voice.testWake(for: 0.3) { [wakeWord] in wakeWord?.heard?(1) }
        XCTAssertFalse(heard, "Jarvis saying the phrase doesn't count")
        let result = Task { await voice.testWake(for: 2) {} }
        try await Task.sleep(for: .milliseconds(50))
        wakeWord.heard?(2)
        let second = await result.value
        XCTAssertTrue(second)
        XCTAssertTrue(transports.isEmpty, "A test wake opens no session")
        XCTAssertEqual(voice.listening.state, .asleep)
        wakeWord.heard?(3)
        XCTAssertEqual(transports.count, 1, "After the test a wake opens a session again")
    }

    func testTheFirstReplyReportsTheOneBreathTimings() async throws {
        let voice = try voice()
        var breaths: [LiveVoice.OneBreath] = []
        voice.onOneBreath = { breaths.append($0) }
        wakeWord.heard?(ProcessInfo.processInfo.systemUptime)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        transports[0].deliver(#"{"type":"session.delegation.created","delegation":{"id":"d1","target":"client"},"offset_ms":5}"#)
        transports[0].deliver(answer)
        try await waitUntil { !breaths.isEmpty }
        XCTAssertEqual(breaths.count, 1)
        XCTAssertTrue(breaths[0].firstWasDelegation)
        XCTAssertGreaterThanOrEqual(breaths[0].first ?? -1, breaths[0].started)
    }

    func testTheChosenMicrophoneReachesTheEngine() throws {
        let voice = try voice()
        voice.useInput(uid: "BuiltInMicrophoneDevice")
        XCTAssertEqual(microphone.inputs, ["BuiltInMicrophoneDevice"])
    }

    func testRepliesAreOfferedAsTextTurnByTurn() async throws {
        let voice = try voice()
        var replies: [String] = []
        voice.onReply = { replies.append($0) }
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        transports[0].deliver(#"{"type":"session.output_transcript.delta","delta":"Tokyo","start_ms":20,"end_ms":30}"#)
        transports[0].deliver(#"{"type":"session.output_transcript.delta","delta":" it is.","start_ms":30,"end_ms":40}"#)
        transports[0].deliver(heard("And France?"))
        transports[0].deliver(#"{"type":"session.output_transcript.delta","delta":"Paris.","start_ms":60,"end_ms":70}"#)
        try await waitUntil { replies.count == 3 }
        XCTAssertEqual(replies, ["Tokyo", "Tokyo it is.", "Paris."])
    }

    #if canImport(LiveKitWebRTC)
    func testRepliesNotSpokenAloudMuteLivesVoiceButKeepTheSession() {
        final class Output: LiveVoiceOutput { var isEnabled = true }
        let transport = WebRTCLiveTransport()
        transport.playsAudio = false
        let output = Output()
        transport.adopt(output)
        XCTAssertFalse(output.isEnabled, "No output audio plays when replies aren't spoken")
        transport.playsAudio = true
        XCTAssertTrue(output.isEnabled)
        transport.playsAudio = false
        XCTAssertFalse(output.isEnabled, "Turning it off mid-session mutes at once")
    }

    func testTheChosenMicrophoneIsFoundByItsUIDElseTheDefault() {
        XCTAssertEqual(LiveMicrophone.inputIndex(for: "usb-mic", ids: ["built-in", "usb-mic"]), 1)
        XCTAssertNil(LiveMicrophone.inputIndex(for: "", ids: ["built-in"]))
        XCTAssertNil(LiveMicrophone.inputIndex(for: "unplugged", ids: ["built-in"]))
    }

    func testWhatTheSessionHearsIsKeptForL7At24kHz() {
        var samples: [Float] = [0.5, 0.5, -1, -1, 3, 1]
        let pcm = samples.withUnsafeMutableBufferPointer { LiveMicrophone.pcm16At24k($0) }
        let values = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(values, [16383, -32767, 32767])
    }
    #endif

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
        transports[0].deliver(closed)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(microphone.starts, 1, "A disarmed microphone stays off after the session closes")
    }
}
