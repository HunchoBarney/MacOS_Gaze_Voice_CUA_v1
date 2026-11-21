import AppKit
import XCTest
@testable import Jarvis

/// Real GPT-Live sessions over WebRTC, paid and on the microphone, so each
/// runs only behind its flags, JARVIS_LIVE_MIC=1 and JARVIS_LIVE_KEYCHAIN=1, under
/// scripts/with-desktop-lock.py. The OpenAI key is read from Keychain into
/// this process and never printed; the app itself only uses the broker.
@MainActor
final class LiveConnectTests: XCTestCase {
    /// Stands in for the credential Worker's route, with the same fixed fields.
    struct DirectLiveSessions: LiveSessionCreating {
        let key: String
        func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/live/sessions")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let fields = config.brokerBody(sdp: offer)
            var wake: [String: Any] = ["type": "speech"]
            wake["vad_threshold"] = fields["vad_threshold"]
            var session: [String: Any] = [
                "model": "gpt-live-1.1", "delegation": ["type": "client"], "store": false,
                "instructions": config.instructions, "wake_policy": wake, "idle_timeout_s": config.idleTimeoutS,
                "audio": ["output": ["voice": config.voice]],
            ]
            session["input"] = fields["input"]
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "session": session, "transport": ["type": "webrtc", "sdp": offer],
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            return try HostedLiveSessions.answer(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func directBroker() throws -> DirectLiveSessions {
        guard ProcessInfo.processInfo.environment["JARVIS_LIVE_KEYCHAIN"] == "1" else {
            throw XCTSkip("Also set JARVIS_LIVE_KEYCHAIN=1 so the test can read the OpenAI key from Keychain")
        }
        let store = KeychainAPIKeyStore(service: "com.chriswozniczek.jevvoice", account: "openAIAPIKey",
                                        allowUserInteraction: false)
        return DirectLiveSessions(key: try XCTUnwrap(try store.read(), "no OpenAI key in Keychain"))
    }

    private func directSession(_ instructions: String) throws -> LiveSession {
        #if canImport(LiveKitWebRTC)
        return LiveSession(transport: WebRTCLiveTransport(), broker: try directBroker(),
                           config: LiveSessionConfig(instructions: instructions))
        #else
        throw XCTSkip("WebRTC isn't fetched: run python3 -I ThirdParty/WebRTC/fetch.py first")
        #endif
    }

    /// Connect, see session.started, close, see session.closed. About a cent.
    func testARealSessionStartsAndClosesWithConfirmedUsage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_LIVE_CONNECT"] == "1", environment["JARVIS_LIVE_MIC"] == "1" else {
            throw XCTSkip("Set JARVIS_LIVE_CONNECT=1 and JARVIS_LIVE_MIC=1 to open one paid GPT-Live session")
        }
        let live = try directSession("You are a connection test. Stay silent.")
        var events = 0
        live.onEvent = { _ in events += 1 }
        let began = ContinuousClock.now
        try await live.start(timeout: .seconds(15))
        let startedAfter = ContinuousClock.now - began
        XCTAssertNotNil(live.sessionID)
        try await Task.sleep(for: .seconds(3))
        let ending = await live.close(timeout: .seconds(10))
        let steps = live.startSteps.map { "\($0.step)=\(Int($0.seconds * 1000))ms" }.joined(separator: " ")
        print("live_connect started_after=\(startedAfter) \(steps) ending=\(ending) events=\(events)")
        XCTAssertEqual(ending.reason, .closeRequested)
        XCTAssertNotNil(ending.usage)
    }

    /// About a minute of conversation with the owner at the Mac, over the
    /// real mic: wake it twice with "Hey Jarvis", with Standby in between.
    /// The wake word listens to a tap on Live's own engine the whole time,
    /// as L3 would share the mic. Audible and about 10 cents; it waits up to
    /// 15 minutes in Standby for the owner. It logs counts and timings only,
    /// never transcript text.
    func testAOneMinuteTalkPausesAndResumes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_LIVE_TALK"] == "1", environment["JARVIS_LIVE_MIC"] == "1" else {
            throw XCTSkip("Set JARVIS_LIVE_TALK=1 and JARVIS_LIVE_MIC=1, with someone at the Mac, for one minute of paid talk")
        }
        #if canImport(LiveKitWebRTC)
        let live = try directSession("You are Jarvis, a Mac assistant being tested. Answer in one short sentence.")
        let rig = try LiveAudioRig(.microphone)
        let wake = VoskWakeWordDetector()
        let began = ContinuousClock.now
        func at() -> String { "\((ContinuousClock.now - began).components.seconds)s" }
        var wakes = 0
        try wake.start(name: "Jarvis") { _ in
            wakes += 1
            print("live_talk wake_word at=\(at())")
        }
        rig.onInput = { buffer, time in wake.hear(buffer, at: time) }
        var counts: [String: Int] = [:]
        var awake = false
        var pausedAfterSecondWake = false
        func woke(_ how: String) {
            guard !awake else { return }
            awake = true
            counts["live_wakes", default: 0] += 1
            print("live_talk live_wake by=\(how) at=\(at())")
        }
        live.onEvent = { event in
            switch event {
            case .resumed: counts["resumed", default: 0] += 1; woke("resumed")
            case .paused:
                counts["paused", default: 0] += 1
                awake = false
                if counts["live_wakes", default: 0] >= 2 { pausedAfterSecondWake = true }
                print("live_talk paused at=\(at())")
            case .inputTranscript: counts["heard", default: 0] += 1; woke("speech")
            case .outputTranscript: counts["spoke", default: 0] += 1; woke("speech")
            case .error(let error): print("live_talk error type=\(error.type) code=\(error.code ?? "-")")
            default: break
            }
        }
        let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.karanvirkang.jarvis").isEmpty
        try await live.start(timeout: .seconds(15))
        print("live_talk armed jarvis_app_running=\(appRunning)")
        fflush(stdout)
        let deadline = ContinuousClock.now + .seconds(15 * 60)
        while !pausedAfterSecondWake, ContinuousClock.now < deadline {
            if case .ended = live.phase { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let ending = await live.close(timeout: .seconds(10))
        wake.stop()
        let elapsed = ContinuousClock.now - began
        let stats = rig.inputStats
        let seconds = Double(elapsed.components.seconds)
        print("""
        live_talk ending=\(ending) counts=\(counts.sorted { $0.key < $1.key }) wake_words=\(wakes) \
        input_frames_per_s=\(Int(Double(stats.frames) / max(seconds, 1))) input_buffers=\(stats.buffers) \
        largest_input_gap_s=\(String(format: "%.3f", stats.largestGap)) config_changes=\(stats.configChanges) \
        loud_input_buffers=\(stats.loudInputBuffers) peak_input=\(String(format: "%.4f", stats.peakInput)) \
        engines=\(stats.engines) jarvis_app_running=\(appRunning)
        """)
        XCTAssertGreaterThanOrEqual(counts["live_wakes", default: 0], 2,
                                    "speech should wake it twice; the first wake of a session sends no session.resumed")
        XCTAssertTrue(pausedAfterSecondWake, "silence should return it to Standby")
        XCTAssertGreaterThan(counts["spoke", default: 0], 0, "Live should answer aloud")
        XCTAssertGreaterThanOrEqual(wakes, 2, "the wake word should hear both wakes through Live's engine")
        XCTAssertTrue(ending.confirmed)
        #else
        throw XCTSkip("WebRTC isn't fetched: run python3 -I ThirdParty/WebRTC/fetch.py first")
        #endif
    }
    /// L3's one-breath request, timed, with the owner at the Mac: the app's
    /// own microphone, wake word and session code. Say "Hey Jarvis, open
    /// Mail" in one breath, then "That's all"; then "Hey Jarvis, what's the
    /// capital of Japan?" in one breath, then "That's all". The second wake
    /// comes after the first session closed, so it also proves recording
    /// restarts after a call. Two short paid sessions, about 3 cents. It logs
    /// timings only, never transcript text.
    func testOneBreathRequestsReachLive() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_LIVE_ONE_BREATH"] == "1", environment["JARVIS_LIVE_MIC"] == "1" else {
            throw XCTSkip("Set JARVIS_LIVE_ONE_BREATH=1 and JARVIS_LIVE_MIC=1, with someone at the Mac, for two paid one-breath requests")
        }
        #if canImport(LiveKitWebRTC)
        let broker = try directBroker()
        let voice = LiveVoice(microphone: LiveMicrophone(), wakeWord: VoskWakeWordDetector()) { name in
            LiveSession(transport: WebRTCLiveTransport(), broker: broker,
                        config: LiveSessionConfig(instructions: LiveVoice.instructions(name: name)))
        }
        var breaths: [LiveVoice.OneBreath] = []
        voice.onOneBreath = { breath in
            breaths.append(breath)
            print("""
            live_one_breath wake=\(breaths.count) started_s=\(breath.started) behind_s=\(breath.behind) \
            first_s=\(breath.first ?? -1) delegation=\(breath.firstWasDelegation) skipped_s=\(breath.skipped)
            """)
            fflush(stdout)
        }
        try voice.arm(name: "Jarvis")
        print("live_one_breath armed")
        fflush(stdout)
        let deadline = ContinuousClock.now + .seconds(10 * 60)
        while breaths.count < 2 || voice.listening.sessionOpen, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        voice.disarm()
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(breaths.count, 2, "both one-breath requests should get a reply or a delegation; a missing second one means the wake word went deaf after the first session closed")
        XCTAssertTrue(breaths.allSatisfy { $0.first != nil })
        #else
        throw XCTSkip("WebRTC isn't fetched: run python3 -I ThirdParty/WebRTC/fetch.py first")
        #endif
    }
}
