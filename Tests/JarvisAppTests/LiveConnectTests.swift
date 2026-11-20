import XCTest
@testable import Jarvis

/// Real GPT-Live sessions over WebRTC, paid and on the microphone, so each
/// runs only behind its flags and JARVIS_LIVE_MIC=1, under
/// scripts/with-desktop-lock.py. The OpenAI key is read from Keychain into
/// this process and never printed; the app itself only uses the broker.
@MainActor
final class LiveConnectTests: XCTestCase {
    /// Stands in for the credential Worker's route, with the same fixed fields.
    private struct DirectLiveSessions: LiveSessionCreating {
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

    /// One minute of conversation with a person at the Mac: talk to it, go
    /// quiet long enough for Standby, talk again. Audible and about 10 cents,
    /// so it needs the owner present. It logs counts and timings only, never
    /// transcript text.
    func testAOneMinuteTalkPausesAndResumes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_LIVE_TALK"] == "1", environment["JARVIS_LIVE_MIC"] == "1" else {
            throw XCTSkip("Set JARVIS_LIVE_TALK=1 and JARVIS_LIVE_MIC=1, with someone at the Mac, for one minute of paid talk")
        }
        let live = try directSession("You are Jarvis, a Mac assistant being tested. Answer in one short sentence.")
        let began = ContinuousClock.now
        func at() -> String { "\((ContinuousClock.now - began).components.seconds)s" }
        var counts: [String: Int] = [:]
        live.onEvent = { event in
            switch event {
            case .resumed: counts["resumed", default: 0] += 1; print("live_talk resumed at=\(at())")
            case .paused: counts["paused", default: 0] += 1; print("live_talk paused at=\(at())")
            case .inputTranscript: counts["heard", default: 0] += 1
            case .outputTranscript: counts["spoke", default: 0] += 1
            case .error(let error): print("live_talk error type=\(error.type) code=\(error.code ?? "-")")
            default: break
            }
        }
        try await live.start(timeout: .seconds(15))
        print("live_talk started: speak now, pause for ten seconds, then speak again")
        try await Task.sleep(for: .seconds(60))
        let ending = await live.close(timeout: .seconds(10))
        print("live_talk ending=\(ending) counts=\(counts.sorted { $0.key < $1.key })")
        XCTAssertGreaterThanOrEqual(counts["resumed", default: 0], 2, "speech should wake it, twice")
        XCTAssertGreaterThanOrEqual(counts["paused", default: 0], 1, "silence should return it to Standby")
        XCTAssertGreaterThan(counts["spoke", default: 0], 0, "Live should answer aloud")
        XCTAssertTrue(ending.confirmed)
    }
}
