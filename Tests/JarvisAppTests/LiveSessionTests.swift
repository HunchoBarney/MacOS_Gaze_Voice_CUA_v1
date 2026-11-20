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

    private func usage(_ seconds: Double, active: Int? = 30, paused: Int? = 10, ratio: Double? = nil) -> LiveUsage {
        LiveUsage(seconds: seconds, activeSeconds: active, pausedSeconds: paused, contextRatio: ratio)
    }

    private func session() -> (LiveSession, FakeTransport, Events) {
        let transport = FakeTransport()
        let live = LiveSession(transport: transport, broker: FakeBroker(), config: LiveSessionConfig(instructions: "Be brief."))
        let events = Events()
        live.onEvent = { events.all.append($0) }
        return (live, transport, events)
    }

    private final class Events { var all: [LiveSessionEvent] = [] }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func isEnded(_ live: LiveSession) -> Bool {
        if case .ended = live.phase { return true }
        return false
    }

    func testStartWaitsForSessionStartedThenFollowsStandbyAndResume() async throws {
        let (live, transport, events) = session()
        transport.deliver(started)
        try await live.start()
        XCTAssertEqual(transport.answers, ["answer-sdp"])
        XCTAssertEqual(live.sessionID, "live_123")
        XCTAssertEqual(live.phase, .standby, "the speech wake policy waits for speech")
        XCTAssertEqual(live.startSteps.map { $0.step }, ["offer", "create", "answer", "started"])
        transport.deliver(#"{"type":"session.resumed","event_id":"e2"}"#)
        try await waitUntil { live.phase == .active }
        XCTAssertEqual(live.phase, .active)
        transport.deliver(#"{"type":"session.usage.updated","event_id":"e3","usage":{"seconds":12},"context_window":{"usage_ratio":0.42}}"#)
        transport.deliver(#"{"type":"session.paused","event_id":"e4"}"#)
        try await waitUntil { live.phase == .standby }
        XCTAssertEqual(live.phase, .standby)
        let reported = usage(12, active: nil, paused: nil, ratio: 0.42)
        XCTAssertEqual(live.lastUsage, reported)
        XCTAssertEqual(events.all, [.started(sessionID: "live_123"), .resumed, .usage(reported), .paused])
    }

    func testCloseSendsSessionCloseAndConfirmsTheReasonAndFinalUsage() async throws {
        let (live, transport, events) = session()
        transport.deliver(started)
        try await live.start()
        async let ending = live.close()
        try await waitUntil { !transport.sent.isEmpty }
        XCTAssertEqual(transport.sent.first?["type"] as? String, "session.close")
        XCTAssertEqual(live.phase, .closing)
        transport.deliver(closed("close_requested"))
        let result = await ending
        XCTAssertEqual(result, LiveSessionEnding(reason: .closeRequested, usage: usage(40)))
        XCTAssertTrue(result.confirmed)
        XCTAssertEqual(transport.closes, 1, "the connection is released only after session.closed")
        XCTAssertEqual(events.all.last, .closed(reason: .closeRequested, usage: usage(40)))
        XCTAssertEqual(events.all.filter { if case .closed = $0 { return true }; return false }.count, 1)
    }

    func testEveryServerCloseReasonEndsTheSession() async throws {
        let reasons: [(String, LiveCloseReason)] = [("close_requested", .closeRequested), ("expired", .expired),
                                                    ("content", .content), ("remote_hangup", .remoteHangup),
                                                    ("connection_lost", .connectionLost), ("rebooted", .other("rebooted"))]
        for (wire, reason) in reasons {
            let (live, transport, events) = session()
            transport.deliver(started)
            try await live.start()
            transport.deliver(closed(wire, seconds: 7))
            try await waitUntil { isEnded(live) }
            let ending = LiveSessionEnding(reason: reason, usage: usage(7))
            XCTAssertEqual(live.phase, .ended(ending), wire)
            XCTAssertEqual(events.all.last, .closed(reason: reason, usage: usage(7)), wire)
            XCTAssertEqual(transport.closes, 1, wire)
            live.send(LiveAppend(kind: .instructions, content: "late", delegationID: nil))
            XCTAssertTrue(transport.sent.isEmpty, "an append after the close is dropped: \(wire)")
        }
    }

    func testALostConnectionEndsUnconfirmedAndKeepsTheLastUsage() async throws {
        let (live, transport, events) = session()
        transport.deliver(started)
        try await live.start()
        transport.deliver(#"{"type":"session.usage.updated","event_id":"e3","usage":{"seconds":12}}"#)
        transport.drop()
        try await waitUntil { isEnded(live) }
        let ending = LiveSessionEnding(reason: .connectionLost, usage: nil)
        XCTAssertEqual(live.phase, .ended(ending))
        XCTAssertFalse(ending.confirmed)
        XCTAssertEqual(live.lastUsage, usage(12, active: nil, paused: nil))
        XCTAssertEqual(events.all.last, .closed(reason: .connectionLost, usage: nil))
    }

    func testCloseGivesUpWithoutSessionClosed() async throws {
        let (live, transport, _) = session()
        transport.deliver(started)
        try await live.start()
        let ending = await live.close(timeout: .milliseconds(50))
        XCTAssertEqual(ending, LiveSessionEnding(reason: .closeRequested, usage: nil))
        XCTAssertFalse(ending.confirmed)
        XCTAssertEqual(transport.closes, 1)
    }

    func testStartFailsWhenSessionStartedNeverArrives() async throws {
        let (live, transport, events) = session()
        do {
            try await live.start(timeout: .milliseconds(50))
            XCTFail("start should time out")
        } catch {
            XCTAssertEqual(error as? LiveSessionError, .startTimedOut)
        }
        XCTAssertEqual(live.phase, .ended(LiveSessionEnding(reason: .connectionLost, usage: nil)))
        XCTAssertEqual(transport.closes, 1)
        XCTAssertTrue(events.all.isEmpty, "a session that never started reports nothing")
    }

    func testTranscriptsDelegationsAndErrorsReachTheEvents() async throws {
        let (live, transport, events) = session()
        transport.deliver(started)
        try await live.start()
        transport.deliver(#"{"type":"session.input_transcript.delta","event_id":"e5","delta":"open","start_ms":1000,"end_ms":1200}"#)
        transport.deliver(#"{"type":"session.output_transcript.delta","event_id":"e6","delta":"Sure","start_ms":1300,"end_ms":1500}"#)
        transport.deliver(#"{"type":"session.delegation.created","event_id":"e7","offset_ms":1600,"delegation":{"id":"item_1","type":"delegation","target":"client"}}"#)
        transport.deliver(#"{"type":"session.delegation.created","event_id":"e8","offset_ms":1700,"delegation":{"id":"item_2","type":"delegation","target":"server"}}"#)
        transport.deliver(#"{"type":"error","event_id":"e9","error":{"type":"invalid_request_error","code":"immutable_field_update","message":"No.","param":"session.delegation.type","client_event_id":"jarvis_1"}}"#)
        transport.deliver(#"{"type":"session.something_new","event_id":"e10"}"#)
        transport.deliver(#"{"type":"session.resumed","event_id":"e11"}"#)
        try await waitUntil { events.all.last == .resumed }
        XCTAssertEqual(Array(events.all.dropFirst()), [
            .inputTranscript(LiveTranscriptDelta(text: "open", startMs: 1000, endMs: 1200)),
            .outputTranscript(LiveTranscriptDelta(text: "Sure", startMs: 1300, endMs: 1500)),
            .delegation(LiveDelegation(id: "item_1", offsetMs: 1600)),
            .error(LiveError(type: "invalid_request_error", code: "immutable_field_update", message: "No.",
                             clientEventID: "jarvis_1", param: "session.delegation.type")),
            .resumed,
        ])
    }

    func testAppendsCarryTheirEventIDAndANullDelegation() async throws {
        let (live, transport, _) = session()
        transport.deliver(started)
        try await live.start()
        let append = LiveAppend(kind: .commentary, content: "Calculator is open.", delegationID: nil)
        live.send(append)
        let sent = try XCTUnwrap(transport.sent.last)
        XCTAssertEqual(sent["type"] as? String, "session.commentary.append")
        XCTAssertEqual(sent["event_id"] as? String, append.eventID)
        XCTAssertEqual(sent["content"] as? String, "Calculator is open.")
        XCTAssertTrue(sent["delegation_id"] is NSNull, "delegation_id is required even when null")
        live.send(LiveAppend(kind: .thinking, content: "Done.", delegationID: "item_1"))
        XCTAssertEqual(transport.sent.last?["delegation_id"] as? String, "item_1")
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
        var config = LiveSessionConfig(instructions: "Be brief.")
        config.input = [.init(role: .user, text: "Hi"), .init(role: .assistant, text: "Hello")]
        config.vadThreshold = 0.6
        let answer = try await broker.createSession(offer: "v=0 offer", config: config)
        XCTAssertEqual(answer, LiveSessionAnswer(id: "live_9", sdp: "v=0 answer"))
        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.url?.absoluteString, "https://keys.example/v1/live/sessions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer install-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["sdp", "instructions", "input", "idle_timeout_s", "vad_threshold", "voice"],
                       "exactly the fields the broker allows")
        XCTAssertEqual(body["sdp"] as? String, "v=0 offer")
        XCTAssertNil(body["model"], "the broker fixes the model")
    }

    func testBrokerAndOpenAIErrorsComeBackReadable() throws {
        let limited = #"{"error":{"code":"daily_limit","message":"Today's voice limit is used up."}}"#
        XCTAssertThrowsError(try HostedLiveSessions.answer(data: Data(limited.utf8), status: 429)) { error in
            XCTAssertEqual(error as? LiveBrokerError,
                           LiveBrokerError(status: 429, code: "daily_limit", message: "Today's voice limit is used up."))
        }
        let tooLong = #"{"error":{"message":"Instructions are too long.","type":"invalid_request_error","code":null,"param":"session.instructions"}}"#
        XCTAssertThrowsError(try HostedLiveSessions.answer(data: Data(tooLong.utf8), status: 400)) { error in
            XCTAssertEqual(error as? LiveBrokerError, LiveBrokerError(status: 400, code: nil, message: "Instructions are too long."))
        }
        XCTAssertThrowsError(try HostedLiveSessions.answer(data: Data("<html>".utf8), status: 502)) { error in
            XCTAssertEqual((error as? LiveBrokerError)?.message, "The voice service answered 502.")
        }
        let sip = #"{"session":{"id":"live_9"},"transport":{"type":"sip"}}"#
        XCTAssertThrowsError(try HostedLiveSessions.answer(data: Data(sip.utf8), status: 201))
    }

    func testAStartThatFailsAtTheBrokerEndsTheSession() async throws {
        struct Refusing: LiveSessionCreating {
            func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
                throw LiveBrokerError(status: 429, code: "daily_limit", message: "Used up.")
            }
        }
        let transport = FakeTransport()
        let live = LiveSession(transport: transport, broker: Refusing(), config: LiveSessionConfig(instructions: ""))
        do {
            try await live.start()
            XCTFail("start should fail")
        } catch {
            XCTAssertEqual((error as? LiveBrokerError)?.code, "daily_limit")
        }
        XCTAssertTrue(isEnded(live))
        XCTAssertEqual(transport.closes, 1)
    }

    func testACloseDuringStartEndsItWithoutCreatingTheSession() async throws {
        final class SlowOffer: LiveTransport, @unchecked Sendable {
            let incoming = AsyncStream<LiveTransportEvent> { _ in }
            var release: CheckedContinuation<Void, Never>?
            var accepted = false
            func offer() async throws -> String {
                await withCheckedContinuation { release = $0 }
                return "offer-sdp"
            }
            func accept(answer: String) async throws { accepted = true }
            func send(_ message: Data) throws {}
            func close() {}
        }
        final class Counting: LiveSessionCreating, @unchecked Sendable {
            var calls = 0
            func createSession(offer: String, config: LiveSessionConfig) async throws -> LiveSessionAnswer {
                calls += 1
                return LiveSessionAnswer(id: "live_123", sdp: "answer-sdp")
            }
        }
        let transport = SlowOffer()
        let broker = Counting()
        let live = LiveSession(transport: transport, broker: broker, config: LiveSessionConfig(instructions: ""))
        let starting = Task { try await live.start(timeout: .seconds(30)) }
        try await waitUntil { transport.release != nil }
        let ending = await live.close()
        XCTAssertEqual(ending, LiveSessionEnding(reason: .closeRequested, usage: nil))
        transport.release?.resume()
        do {
            try await starting.value
            XCTFail("start should fail once closed")
        } catch {
            XCTAssertEqual(error as? LiveSessionError, .endedBeforeStart)
        }
        XCTAssertEqual(broker.calls, 0, "no session is created after the close")
        XCTAssertFalse(transport.accepted)
        XCTAssertEqual(live.phase, .ended(ending))
    }

    private final class Captured: @unchecked Sendable { var request: URLRequest? }
}
