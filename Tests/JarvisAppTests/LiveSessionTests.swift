import XCTest
@testable import Jarvis

/// The GPT-Live session over a fake transport and broker: no network, no
/// microphone. Event shapes follow OpenAI's Live reference.
@MainActor
final class LiveSessionTests: XCTestCase {
    private final class FakeTransport: LiveTransport, @unchecked Sendable {
        let incoming: AsyncStream<LiveTransportEvent>
        private let continuation: AsyncStream<LiveTransportEvent>.Continuation
        private(set) var answers: [String] = []
        private(set) var sent: [[String: Any]] = []
        private(set) var closes = 0

        init() { (incoming, continuation) = AsyncStream.makeStream() }
        func offer() async throws -> String { "offer-sdp" }
        func accept(answer: String) async throws { answers.append(answer) }
        func send(_ message: Data) throws {
            sent.append(try XCTUnwrap(JSONSerialization.jsonObject(with: message) as? [String: Any]))
        }
        func close() { closes += 1; continuation.finish() }
        func deliver(_ json: String) { continuation.yield(.message(Data(json.utf8))) }
        func drop() { continuation.yield(.closed("ice failed")); continuation.finish() }
    }

    private struct FakeBroker: LiveSessionCreating {
        func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
            LiveSessionAnswer(id: "live_123", sdp: "answer-sdp")
        }
    }

    private let started = #"{"type":"session.started","event_id":"e1","session":{"id":"live_123","model":"gpt-live-1.1"}}"#

    private func closed(_ reason: String, seconds: Double = 40) -> String {
        #"{"type":"session.closed","event_id":"e9","reason":"\#(reason)","session":{"id":"live_123"},"usage":{"seconds":\#(seconds),"active_seconds":30,"paused_seconds":10}}"#
    }

    private func session() -> (LiveSession, FakeTransport, Updates) {
        let transport = FakeTransport()
        let live = LiveSession(transport: transport, broker: FakeBroker(), config: LiveSessionConfig())
        let updates = Updates()
        live.onUpdate = { updates.all.append($0) }
        return (live, transport, updates)
    }

    private final class Updates { var all: [LiveSessionUpdate] = [] }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testStartWaitsForSessionStartedThenFollowsStandbyAndResume() async throws {
        let (live, transport, updates) = session()
        transport.deliver(started)
        try await live.start()
        XCTAssertEqual(transport.answers, ["answer-sdp"])
        XCTAssertEqual(live.sessionID, "live_123")
        XCTAssertEqual(live.phase, .standby, "the speech wake policy waits for speech")
        transport.deliver(#"{"type":"session.resumed","event_id":"e2"}"#)
        try await waitUntil { live.phase == .active }
        XCTAssertEqual(live.phase, .active)
        transport.deliver(#"{"type":"session.usage.updated","event_id":"e3","usage":{"seconds":12},"context_window":{"usage_ratio":0.42}}"#)
        transport.deliver(#"{"type":"session.paused","event_id":"e4"}"#)
        try await waitUntil { live.phase == .standby }
        XCTAssertEqual(live.phase, .standby)
        XCTAssertEqual(live.lastUsage, LiveUsage(seconds: 12, contextRatio: 0.42))
        XCTAssertEqual(updates.all, [.started(sessionID: "live_123"), .resumed,
                                     .usage(LiveUsage(seconds: 12, contextRatio: 0.42)), .paused])
    }

    func testCloseSendsSessionCloseAndConfirmsTheReasonAndFinalUsage() async throws {
        let (live, transport, _) = session()
        transport.deliver(started)
        try await live.start()
        async let ending = live.close()
        try await waitUntil { !transport.sent.isEmpty }
        XCTAssertEqual(transport.sent.first?["type"] as? String, "session.close")
        XCTAssertEqual(live.phase, .closing)
        transport.deliver(closed("close_requested"))
        let result = await ending
        XCTAssertEqual(result, LiveSessionEnding(reason: .closeRequested,
                                                 usage: LiveUsage(seconds: 40, activeSeconds: 30, pausedSeconds: 10)))
        XCTAssertTrue(result.confirmed)
        XCTAssertEqual(transport.closes, 1, "the connection is released only after session.closed")
    }

    func testEveryServerCloseReasonEndsTheSession() async throws {
        let reasons: [(String, LiveCloseReason)] = [("close_requested", .closeRequested), ("expired", .expired),
                                                    ("content", .content), ("remote_hangup", .remoteHangup),
                                                    ("connection_lost", .connectionLost)]
        for (wire, reason) in reasons {
            let (live, transport, updates) = session()
            transport.deliver(started)
            try await live.start()
            transport.deliver(closed(wire, seconds: 7))
            try await waitUntil { if case .ended = live.phase { return true }; return false }
            let ending = LiveSessionEnding(reason: reason, usage: LiveUsage(seconds: 7, activeSeconds: 30, pausedSeconds: 10))
            XCTAssertEqual(live.phase, .ended(ending), wire)
            XCTAssertEqual(updates.all.last, .ended(ending), wire)
            XCTAssertEqual(transport.closes, 1, wire)
            XCTAssertThrowsError(try live.send(.appendInstructions("late")), wire)
        }
    }

    func testALostConnectionLeavesTheLastUsageUnconfirmed() async throws {
        let (live, transport, _) = session()
        transport.deliver(started)
        try await live.start()
        transport.deliver(#"{"type":"session.usage.updated","event_id":"e3","usage":{"seconds":12}}"#)
        transport.drop()
        try await waitUntil { if case .ended = live.phase { return true }; return false }
        let ending = LiveSessionEnding(reason: nil, usage: LiveUsage(seconds: 12))
        XCTAssertEqual(live.phase, .ended(ending))
        XCTAssertFalse(ending.confirmed)
    }

    func testCloseGivesUpWithoutSessionClosed() async throws {
        let (live, transport, _) = session()
        transport.deliver(started)
        try await live.start()
        let ending = await live.close(timeout: .milliseconds(50))
        XCTAssertEqual(ending, LiveSessionEnding(reason: nil, usage: nil))
        XCTAssertEqual(transport.closes, 1)
    }

    func testStartFailsWhenSessionStartedNeverArrives() async throws {
        let (live, transport, _) = session()
        do {
            try await live.start(timeout: .milliseconds(50))
            XCTFail("start should time out")
        } catch {
            XCTAssertEqual(error as? LiveSessionError, .startTimedOut)
        }
        XCTAssertEqual(live.phase, .ended(LiveSessionEnding(reason: nil, usage: nil)))
        XCTAssertEqual(transport.closes, 1)
    }

    func testTranscriptsAndErrorsReachTheUpdates() async throws {
        let (live, transport, updates) = session()
        transport.deliver(started)
        try await live.start()
        transport.deliver(#"{"type":"session.input_transcript.delta","event_id":"e5","delta":"open","start_ms":1000,"end_ms":1200}"#)
        transport.deliver(#"{"type":"session.output_transcript.delta","event_id":"e6","delta":"Sure","start_ms":1300,"end_ms":1500}"#)
        transport.deliver(#"{"type":"error","event_id":"e7","error":{"type":"invalid_request_error","code":"immutable_field_update","message":"No.","param":"session.delegation.type","client_event_id":"jarvis_1"}}"#)
        transport.deliver(#"{"type":"session.delegation.created","event_id":"e8"}"#)
        try await waitUntil { updates.all.count >= 4 }
        XCTAssertEqual(Array(updates.all.dropFirst()), [
            .inputTranscript(LiveTranscriptDelta(text: "open", startMs: 1000, endMs: 1200)),
            .outputTranscript(LiveTranscriptDelta(text: "Sure", startMs: 1300, endMs: 1500)),
            .error(LiveError(type: "invalid_request_error", code: "immutable_field_update", message: "No.",
                             clientEventID: "jarvis_1", param: "session.delegation.type")),
        ])
    }

    func testCommandsCarryAnEventIDAndANullDelegation() async throws {
        let (live, transport, _) = session()
        transport.deliver(started)
        try await live.start()
        let id = try live.send(.appendCommentary("Calculator is open.", delegationID: nil))
        let sent = try XCTUnwrap(transport.sent.last)
        XCTAssertEqual(sent["type"] as? String, "session.commentary.append")
        XCTAssertEqual(sent["event_id"] as? String, id)
        XCTAssertEqual(sent["content"] as? String, "Calculator is open.")
        XCTAssertTrue(sent["delegation_id"] is NSNull, "delegation_id is required even when null")
    }

    func testBrokerRequestCarriesOnlyWhatJarvisChooses() async throws {
        let captured = Captured()
        let broker = HostedLiveSessions(
            baseURL: URL(string: "https://keys.example/")!, installToken: { "install-token" },
            send: { request in
                captured.request = request
                let body = #"{"session":{"id":"live_9"},"transport":{"type":"webrtc","sdp":"v=0 answer"}}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
            })
        var config = LiveSessionConfig()
        config.instructions = "Be brief."
        config.input = [.init(role: .user, text: "Hi"), .init(role: .assistant, text: "Hello")]
        config.vadThreshold = 0.6
        let answer = try await broker.createSession(offer: "v=0 offer", config: config)
        XCTAssertEqual(answer, LiveSessionAnswer(id: "live_9", sdp: "v=0 answer"))
        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.url?.absoluteString, "https://keys.example/v1/live/sessions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer install-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["sdp", "instructions", "input", "idle_timeout_s", "vad_threshold", "voice"])
        XCTAssertEqual(body["voice"] as? String, "marin")
        XCTAssertEqual(body["idle_timeout_s"] as? Int, 8)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let assistantPart = (input[1]["content"] as? [[String: Any]])?.first
        XCTAssertEqual(assistantPart?["type"] as? String, "output_text")
        XCTAssertNil(body["model"], "the broker fixes the model")
    }

    func testBrokerAndOpenAIErrorsComeBackReadable() throws {
        let limited = #"{"error":{"code":"daily_limit","message":"Today's voice limit is used up."}}"#
        XCTAssertThrowsError(try HostedLiveSessions.answer(data: Data(limited.utf8), status: 429)) { error in
            XCTAssertEqual(error as? LiveBrokerError,
                           LiveBrokerError(status: 429, code: "daily_limit", message: "Today's voice limit is used up."))
        }
        let openAI = #"{"error":{"message":"Instructions are too long.","type":"invalid_request_error","code":null,"param":"session.instructions"}}"#
        XCTAssertThrowsError(try HostedLiveSessions.answer(data: Data(openAI.utf8), status: 400)) { error in
            XCTAssertEqual((error as? LiveBrokerError)?.message, "Instructions are too long.")
        }
        let sip = #"{"session":{"id":"live_9"},"transport":{"type":"sip"}}"#
        XCTAssertThrowsError(try HostedLiveSessions.answer(data: Data(sip.utf8), status: 201))
    }

    private final class Captured: @unchecked Sendable { var request: URLRequest? }
}
