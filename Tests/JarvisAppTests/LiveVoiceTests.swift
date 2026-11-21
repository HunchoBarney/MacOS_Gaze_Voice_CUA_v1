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

    /// The Worker at the cap: `POST /v1/live/sessions` answers `live_limit`.
    private struct CappedBroker: LiveSessionCreating {
        func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
            throw LiveBrokerError(status: 429, code: "live_limit", message: "This month's Live voice is used up.")
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

    private func voice(_ timings: LiveListening.Timings = .init(), broker: LiveSessionCreating = FakeBroker(),
                       before arming: (LiveVoice) -> Void = { _ in }) throws -> LiveVoice {
        microphone = FakeMicrophone()
        wakeWord = FakeWakeWord()
        let voice = LiveVoice(microphone: microphone, wakeWord: wakeWord, timings: timings) { [unowned self] name in
            let transport = FakeTransport()
            self.transports.append(transport)
            let config = LiveSessionConfig(instructions: LiveVoice.instructions(name: name))
            self.configs.append(config)
            return LiveSession(transport: transport, broker: broker, config: config)
        }
        arming(voice)
        try voice.arm(name: "Nova")
        return voice
    }

    private let renews = Date(timeIntervalSince1970: 1_796_083_200)

    /// What the fake Worker's `GET /v1/usage` answers now.
    private var worker: LiveAllowanceStatus?

    private func usage(_ used: Double, capped: Bool = false) -> LiveAllowanceStatus {
        LiveAllowanceStatus(metering: true, tier: "jarvis", period: "2026-11", periodEnds: renews,
                            liveSeconds: used, liveSecondsLimit: 18_000, warnAt: 0.8, capped: capped,
                            tasksLimit: 100)
    }

    /// This month's Live voice, read from a fake Worker that answers `used`
    /// seconds of 5 h. Nothing leaves the Mac.
    private func allowance(used: Double, capped: Bool = false) -> LiveAllowance {
        let name = "live-voice-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let status = usage(used, capped: capped)
        worker = status
        let allowance = LiveAllowance(fetch: { @MainActor [unowned self] in self.worker ?? status },
                                      defaults: UserDefaults(suiteName: name)!)
        allowance.apply(status)
        return allowance
    }

    /// The request after the wake: speech, then a pause longer than `settle`.
    private func say(_ seconds: Double, thenQuiet quiet: Double, at end: TimeInterval = 1) {
        let speech = [Float](repeating: 0.2, count: Int(seconds * 1000))
        let silence = [Float](repeating: 0, count: Int(quiet * 1000))
        speech.withUnsafeBufferPointer { microphone.relay.write($0, endingAt: end) }
        silence.withUnsafeBufferPointer { microphone.relay.write($0, endingAt: end + quiet) }
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
        wakeWord.heard?(ProcessInfo.processInfo.systemUptime)
        let second = await result.value
        XCTAssertTrue(second)
        XCTAssertTrue(transports.isEmpty, "A test wake opens no session")
        XCTAssertEqual(voice.listening.state, .asleep)
        wakeWord.heard?(3)
        XCTAssertEqual(transports.count, 1, "After the test a wake opens a session again")
    }

    func testTheWakeTestIgnoresALateConfirmationOfJarvisSayingThePhrase() async throws {
        let voice = try voice()
        let saidAt = ProcessInfo.processInfo.systemUptime
        let result = Task { await voice.testWake(for: 0.5) {} }
        try await Task.sleep(for: .milliseconds(100))
        wakeWord.heard?(saidAt)
        let heard = await result.value
        XCTAssertFalse(heard, "A phrase that ended before the listening window isn't the person's")
        XCTAssertTrue(transports.isEmpty)
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

    // MARK: KAR-75 L10, basic voice and the warning

    func testACappedWakeHearsTheRequestOnTheMacAndOpensNoSession() async throws {
        var requests: [(samples: [Float], until: Date, glow: LiveVoice.Glow)] = []
        var voiceRef: LiveVoice?
        let voice = try voice(LiveListening.Timings(settle: 0.05)) { voice in
            voice.allowance = self.allowance(used: 18_000, capped: true)
            voice.onBasicRequest = { samples, until in requests.append((samples, until, voiceRef?.glow ?? .hidden)) }
        }
        voiceRef = voice
        wakeWord.heard?(0)
        XCTAssertEqual(voice.glow, .hearing)
        XCTAssertEqual(wakeWord.stops, 1)
        say(0.4, thenQuiet: 0.1)
        try await waitUntil { requests.count == 1 }
        XCTAssertTrue(transports.isEmpty, "Basic voice opens no Live session")
        XCTAssertEqual(requests[0].samples.count, 500)
        XCTAssertEqual(Array(requests[0].samples.prefix(400)), [Float](repeating: 0.2, count: 400))
        XCTAssertEqual(requests[0].until, renews)
        XCTAssertEqual(requests[0].glow, .thinking, "The glow thinks while the spine works on it")
        try await waitUntil { voice.listening.state == .asleep }
        XCTAssertEqual(voice.glow, .hidden)
        XCTAssertEqual(wakeWord.starts, 2, "Back to the wake word")
        XCTAssertEqual(microphone.starts, 1, "No call was opened, so recording never stopped")
    }

    func testABasicVoiceWakeWithNoRequestIsAFalseWake() async throws {
        var requests = 0
        let voice = try voice(LiveListening.Timings(falseWake: 0.2, settle: 0.05)) { voice in
            voice.allowance = self.allowance(used: 18_000, capped: true)
            voice.onBasicRequest = { _, _ in requests += 1 }
        }
        wakeWord.heard?(0)
        say(0, thenQuiet: 0.5)
        try await waitUntil { voice.listening.state == .asleep }
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(transports.isEmpty)
        XCTAssertEqual(wakeWord.starts, 2)
    }

    func testABrokerRefusalAtTheCapFallsBackToBasicVoiceWithTheSameBreath() async throws {
        var requests: [[Float]] = []
        let allowance = allowance(used: 17_900)
        let voice = try voice(LiveListening.Timings(settle: 0.05), broker: CappedBroker()) { voice in
            voice.allowance = allowance
            voice.onBasicRequest = { samples, _ in requests.append(samples) }
        }
        wakeWord.heard?(0)
        worker = usage(18_000, capped: true)
        say(0.3, thenQuiet: 0.1)
        try await waitUntil { requests.count == 1 }
        XCTAssertEqual(transports.count, 1, "Live was tried once")
        XCTAssertEqual(allowance.mode, .basic(until: renews))
        XCTAssertEqual(Array(requests[0].prefix(300)), [Float](repeating: 0.2, count: 300), "The words said with the wake reach basic voice")
        XCTAssertEqual(microphone.starts, 2, "The refused call stopped the engine, so recording starts again")
        try await waitUntil { voice.listening.state == .asleep }
        wakeWord.heard?(1)
        say(0.2, thenQuiet: 0.1, at: 2)
        try await waitUntil { requests.count == 2 }
        XCTAssertEqual(transports.count, 1, "Once refused, the next wake goes straight to basic voice")
    }

    func testBasicVoiceEndsOnceTheWorkerSaysLiveVoiceIsBack() async throws {
        var requests = 0
        let voice = try voice(LiveListening.Timings(settle: 0.05)) { voice in
            voice.allowance = self.allowance(used: 18_000, capped: true)
            voice.onBasicRequest = { _, _ in
                requests += 1
                self.worker = self.usage(0)
            }
        }
        wakeWord.heard?(0)
        say(0.3, thenQuiet: 0.1)
        try await waitUntil { requests == 1 }
        try await waitUntil { voice.allowance?.mode == .live }
        try await waitUntil { voice.listening.state == .asleep }
        XCTAssertTrue(transports.isEmpty)
        wakeWord.heard?(1)
        try await waitUntil { transports.count == 1 }
        XCTAssertEqual(requests, 1, "The month renewed, so the next wake opens Live")
    }

    func testAnUncappedWakeOpensLiveAndTheWarningShowsOnceThenLiveSaysItAtTheNextWake() async throws {
        var notices: [String] = []
        var requests = 0
        let voice = try voice(LiveListening.Timings(settle: 0.05)) { voice in
            voice.allowance = self.allowance(used: 14_760)
            voice.onNotice = { notices.append($0) }
            voice.speaksWarnings = { true }
            voice.onBasicRequest = { _, _ in requests += 1 }
        }
        try await waitUntil { notices.count == 1 }
        XCTAssertEqual(notices, ["You've used 82% of this month's Live voice. It renews on December 1."])
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        XCTAssertTrue(transports[0].sent.contains("session.instructions.append"), "Live says the warning once")
        transports[0].deliver(heard("That's all, Nova."))
        try await waitUntil { transports[0].sent.contains("session.close") }
        transports[0].deliver(closed)
        try await waitUntil { microphone.starts == 2 }
        wakeWord.heard?(1)
        try await waitUntil { transports.count == 2 }
        transports[1].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        XCTAssertFalse(transports[1].sent.contains("session.instructions.append"), "Only the next wake")
        XCTAssertEqual(notices.count, 1, "Once a period")
        XCTAssertEqual(requests, 0)
    }

    func testTheWarningIsNotSpokenWhenRepliesAreQuiet() async throws {
        var notices: [String] = []
        let voice = try voice { voice in
            voice.allowance = self.allowance(used: 14_760)
            voice.onNotice = { notices.append($0) }
            voice.speaksWarnings = { false }
        }
        try await waitUntil { notices.count == 1 }
        wakeWord.heard?(0)
        try await waitUntil { !transports.isEmpty }
        transports[0].deliver(started)
        try await waitUntil { voice.listening.state == .talking }
        XCTAssertFalse(transports[0].sent.contains("session.instructions.append"), "The line on the glow is the whole warning")
    }

    func testBasicVoiceSpeechIs24kHzPCM16ForTheOnDeviceTranscriber() {
        let second = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 48_000)) * 0.5 }
        let pcm = BasicVoiceTurn.speech(second, sampleRate: 48_000)
        XCTAssertEqual(Double(pcm.count) / 2, RecentSpeechAudio.sampleRate, accuracy: 600)
        let peak = pcm.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 }
        XCTAssertEqual(Double(peak), 0.5 * 32_767, accuracy: 1_500)
        XCTAssertTrue(BasicVoiceTurn.speech([], sampleRate: 48_000).isEmpty)
    }
}
