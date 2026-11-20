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

    private func directSession(_ instructions: String) throws -> LiveSession {
        #if canImport(LiveKitWebRTC)
        guard ProcessInfo.processInfo.environment["JARVIS_LIVE_KEYCHAIN"] == "1" else {
            throw XCTSkip("Also set JARVIS_LIVE_KEYCHAIN=1 so the test can read the OpenAI key from Keychain")
        }
        let store = KeychainAPIKeyStore(service: "com.chriswozniczek.jevvoice", account: "openAIAPIKey",
                                        allowUserInteraction: false)
        let key = try XCTUnwrap(try store.read(), "no OpenAI key in Keychain")
        return LiveSession(transport: WebRTCLiveTransport(), broker: DirectLiveSessions(key: key),
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
        let live = try directSession("You are Jarvis, a Mac assistant being tested. Answer in one short sentence.")
        var counts: [String: Int] = [:]
        var pausedAfterSecondWake = false
        live.onEvent = { event in
            switch event {
            case .resumed: counts["resumed", default: 0] += 1; print("live_talk resumed at=\(at())")
            case .paused:
                counts["paused", default: 0] += 1
                if counts["resumed", default: 0] >= 2 { pausedAfterSecondWake = true }
                print("live_talk paused at=\(at())")
            case .inputTranscript: counts["heard", default: 0] += 1
            case .outputTranscript: counts["spoke", default: 0] += 1
            case .error(let error): print("live_talk error type=\(error.type) code=\(error.code ?? "-")")
            default: break
            }
        }
        let appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.karanvirkang.jarvis").isEmpty
        try await live.start(timeout: .seconds(15))
        print("live_talk armed jarvis_app_running=\(appRunning)")
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
        engines=\(stats.engines) jarvis_app_running=\(appRunning)
        """)
        XCTAssertGreaterThanOrEqual(counts["resumed", default: 0], 2, "speech should wake it, twice")
        XCTAssertTrue(pausedAfterSecondWake, "silence should return it to Standby")
        XCTAssertGreaterThan(counts["spoke", default: 0], 0, "Live should answer aloud")
        XCTAssertGreaterThanOrEqual(wakes, 2, "the wake word should hear both wakes through Live's engine")
        XCTAssertTrue(ending.confirmed)
        #else
        throw XCTSkip("WebRTC isn't fetched: run python3 -I ThirdParty/WebRTC/fetch.py first")
        #endif
    }
}
