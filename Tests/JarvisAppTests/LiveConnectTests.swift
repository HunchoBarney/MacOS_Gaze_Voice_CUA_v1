import XCTest
@testable import Jarvis

/// One real GPT-Live session over WebRTC: connect, see session.started, close,
/// see session.closed. It costs about a cent (billed seconds) and needs the
/// microphone, so it runs only with JARVIS_LIVE_CONNECT=1 and JARVIS_LIVE_MIC=1,
/// under scripts/with-desktop-lock.py. The OpenAI key is read from Keychain
/// into this process and never printed; the app itself only uses the broker.
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
            var session: [String: Any] = [
                "model": "gpt-live-1.1", "delegation": ["type": "client"], "store": false,
                "wake_policy": ["type": "speech"], "idle_timeout_s": config.idleTimeoutS,
                "audio": ["output": ["voice": config.voice]],
            ]
            if let instructions = config.instructions { session["instructions"] = instructions }
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "session": session, "transport": ["type": "webrtc", "sdp": offer],
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            return try HostedLiveSessions.answer(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func testARealSessionStartsAndClosesWithConfirmedUsage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_LIVE_CONNECT"] == "1", environment["JARVIS_LIVE_MIC"] == "1" else {
            throw XCTSkip("Set JARVIS_LIVE_CONNECT=1 and JARVIS_LIVE_MIC=1 to open one paid GPT-Live session")
        }
        #if canImport(LiveKitWebRTC)
        let store = KeychainAPIKeyStore(service: "com.chriswozniczek.jevvoice", account: "openAIAPIKey",
                                        allowUserInteraction: false)
        let key = try XCTUnwrap(try store.read(), "no OpenAI key in Keychain")
        var config = LiveSessionConfig()
        config.instructions = "You are a connection test. Stay silent."
        let live = LiveSession(transport: WebRTCLiveTransport(), broker: DirectLiveSessions(key: key), config: config)
        var updates: [LiveSessionUpdate] = []
        live.onUpdate = { updates.append($0) }
        let began = ContinuousClock.now
        try await live.start(timeout: .seconds(15))
        let startedAfter = ContinuousClock.now - began
        XCTAssertNotNil(live.sessionID)
        try await Task.sleep(for: .seconds(3))
        let ending = await live.close(timeout: .seconds(10))
        let steps = live.startSteps.map { "\($0.step)=\(Int($0.seconds * 1000))ms" }.joined(separator: " ")
        print("live_connect started_after=\(startedAfter) \(steps) ending=\(ending) updates=\(updates.count)")
        XCTAssertEqual(ending.reason, .closeRequested)
        XCTAssertNotNil(ending.usage)
        #else
        throw XCTSkip("WebRTC isn't fetched: run python3 -I ThirdParty/WebRTC/fetch.py first")
        #endif
    }
}
