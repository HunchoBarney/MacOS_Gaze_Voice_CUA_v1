import XCTest
@testable import Jarvis
import JarvisCore

/// The L2 replay corpus: GPT-Live server events as they arrive on the wire
/// (JSONL, no audio, no personal content) driven through the delegation
/// bridge against a fake session and a fake spine.
@MainActor
final class DelegationBridgeTests: XCTestCase {

    private final class FakeSession: LiveSessionSending {
        var appends: [LiveAppend] = []
        func send(_ append: LiveAppend) { appends.append(append) }
    }

    private final class FakeSpine: DelegationSpine {
        var requests: [DelegatedRequest] = []
        var reply: DelegationSpineReply = .started("Opening Calculator")
        func begin(_ request: DelegatedRequest) async -> DelegationSpineReply {
            requests.append(request)
            return reply
        }
    }

    private var session: FakeSession!
    private var spine: FakeSpine!
    private var bridge: DelegationBridge!
    private var resolvedAt: [TimeInterval] = []

    override func setUp() async throws {
        session = FakeSession()
        spine = FakeSpine()
        resolvedAt = []
        bridge = makeBridge()
    }

    private func makeBridge(referent: String? = nil) -> DelegationBridge {
        DelegationBridge(live: session, spine: spine, sleep: { _ in }, uptime: { 100 },
                         resolveReferent: { [weak self] time in
                             self?.resolvedAt.append(time)
                             return referent
                         })
    }

    /// Feeds one JSONL corpus, then lets the bridge's tasks run.
    private func replay(_ jsonl: String) async throws {
        for line in jsonl.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            bridge.handle(try Self.event(String(line)))
        }
        await drain()
    }

    private func drain() async {
        for _ in 0..<50 { await Task.yield() }
    }

    /// Test-side decoder for the server events the corpus uses.
    private static func event(_ line: String) throws -> LiveSessionEvent {
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        func delta() -> LiveTranscriptDelta {
            LiveTranscriptDelta(text: o["delta"] as? String ?? "", startMs: o["start_ms"] as? Int ?? 0,
                                endMs: o["end_ms"] as? Int ?? 0)
        }
        switch o["type"] as? String {
        case "session.started": return .started(sessionID: (o["session"] as? [String: Any])?["id"] as? String ?? "")
        case "session.input_transcript.delta": return .inputTranscript(delta())
        case "session.output_transcript.delta": return .outputTranscript(delta())
        case "session.delegation.created":
            return .delegation(LiveDelegation(id: (o["delegation"] as? [String: Any])?["id"] as? String ?? "",
                                              offsetMs: o["offset_ms"] as? Int ?? 0))
        case "session.paused": return .paused
        case "session.resumed": return .resumed
        case "session.closed": return .closed(reason: LiveCloseReason(o["reason"] as? String ?? ""), usage: nil)
        case "error":
            let e = o["error"] as? [String: Any] ?? [:]
            return .error(LiveError(type: e["type"] as? String ?? "", code: e["code"] as? String,
                                    message: e["message"] as? String ?? "",
                                    clientEventID: e["client_event_id"] as? String, param: nil))
        default: throw XCTSkip("unknown event \(line)")
        }
    }

    private func started(_ id: String = "sess_1") -> String {
        #"{"type":"session.started","session":{"id":"\#(id)"}}"#
    }
    private func said(_ text: String, _ start: Int, _ end: Int) -> String {
        #"{"type":"session.input_transcript.delta","delta":"\#(text)","start_ms":\#(start),"end_ms":\#(end)}"#
    }
    private func delegation(_ id: String, at offset: Int) -> String {
        #"{"type":"session.delegation.created","offset_ms":\#(offset),"delegation":{"id":"\#(id)","type":"delegation","target":"client"}}"#
    }

    // MARK: - Exactly once

    func testOneDelegationRunsTheWordsOnce() async throws {
        try await replay([started(), said("open Calculator", 200, 900), delegation("del_1", at: 1000),
                          said("", 1000, 1400)].joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.text), ["open Calculator"])
        XCTAssertEqual(session.appends.map(\.kind), [.thinking])
        XCTAssertEqual(session.appends.first?.delegationID, "del_1")
        XCTAssertEqual(bridge.ledger.state(of: .init(liveSessionID: "sess_1", delegationID: "del_1")),
                       .committed(spine.requests[0].id))
    }

    func testWordsThatArriveAfterTheDelegationStillRun() async throws {
        let gate = AsyncStream<Void>.makeStream()
        bridge = DelegationBridge(live: session, spine: spine,
                                  timing: .init(settleMs: 300, maxWait: .milliseconds(300), lagWait: .seconds(2)),
                                  sleep: { duration in
                                      if duration == .seconds(2) { for await _ in gate.stream { return } }
                                  }, uptime: { 100 })
        try await replay([started(), delegation("del_1", at: 1000)].joined(separator: "\n"))
        XCTAssertTrue(spine.requests.isEmpty, "the transcript hasn't reached the delegation yet")
        try await replay(said("open Calculator", 200, 900))
        XCTAssertTrue(spine.requests.isEmpty, "still inside the lag wait")
        gate.continuation.finish()
        await drain()
        XCTAssertEqual(spine.requests.map(\.text), ["open Calculator"])
    }

    func testDuplicateDelegationProducesOneAction() async throws {
        try await replay([started(), said("open Calculator", 200, 900),
                          delegation("del_1", at: 1000), delegation("del_2", at: 1100),
                          delegation("del_1", at: 1000)].joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.text), ["open Calculator"], "one action for one set of words")
        XCTAssertTrue(session.appends.contains {
            $0 == LiveAppend(kind: .commentary, content: "I'm already working on that.", delegationID: "del_2",
                             eventID: $0.eventID)
        })
        XCTAssertEqual(bridge.ledger.state(of: .init(liveSessionID: "sess_1", delegationID: "del_2")),
                       .declined("nothing new"))
    }

    func testOverlappingRequestsEachGetTheirOwnWords() async throws {
        try await replay([started(), said("open Safari", 100, 800), delegation("del_1", at: 900),
                          said("and open Notes", 1500, 2400), delegation("del_2", at: 2500)]
            .joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.text), ["open Safari", "and open Notes"])
    }

    func testBargeInBeforeCommitProducesNoAction() async throws {
        try await replay([started(), said("close it,", 100, 600), delegation("del_1", at: 700),
                          said("no wait, stop", 800, 1500)].joined(separator: "\n"))
        XCTAssertTrue(spine.requests.isEmpty)
        XCTAssertEqual(bridge.ledger.state(of: .init(liveSessionID: "sess_1", delegationID: "del_1")),
                       .declined("barge-in"))
        try await replay([delegation("del_2", at: 1600)].joined(separator: "\n"))
        XCTAssertTrue(spine.requests.isEmpty, "a later delegation for the same words finds nothing new")
    }

    func testATakeBackInsideTheSameWordsProducesNoAction() async throws {
        try await replay([started(), said("close it, no wait, stop", 100, 1500),
                          delegation("del_1", at: 1600)].joined(separator: "\n"))
        XCTAssertTrue(spine.requests.isEmpty)
    }

    func testALocalStopBeforeCommitProducesNoAction() async throws {
        bridge.handle(try Self.event(started()))
        bridge.handle(try Self.event(said("delete this", 100, 700)))
        bridge.handle(try Self.event(delegation("del_1", at: 800)))
        bridge.bargeIn()
        await drain()
        XCTAssertTrue(spine.requests.isEmpty)
    }

    func testANegatedRequestDoesNothing() async throws {
        try await replay([started(), said("don't open Safari", 100, 900), delegation("del_1", at: 1000)]
            .joined(separator: "\n"))
        XCTAssertTrue(spine.requests.isEmpty)
    }

    func testReconnectDoesNotRepeat() async throws {
        try await replay([started("sess_1"), said("open Calculator", 200, 900), delegation("del_1", at: 1000),
                          said("", 1000, 1400),
                          #"{"type":"session.closed","reason":"connection_lost"}"#].joined(separator: "\n"))
        let first = try XCTUnwrap(spine.requests.first)
        bridge.taskEvent(captureID: first.id,
                         payload: #"{"kind":"task_outcome","status":"ok","say":"Calculator is open."}"#)
        XCTAssertFalse(session.appends.contains { $0.kind == .commentary }, "no session to tell yet")
        try await replay([started("sess_2"), delegation("del_9", at: 300)].joined(separator: "\n"))
        XCTAssertEqual(spine.requests.count, 1, "the replacement session's delegation finds nothing new")
        let spoken = session.appends.filter { $0.kind == .commentary }
        XCTAssertEqual(spoken.map(\.content), ["Calculator is open."])
        XCTAssertNil(spoken.first?.delegationID, "the new session never knew del_1")
    }

    func testTheOutcomeIsSpokenWithItsDelegation() async throws {
        try await replay([started(), said("open Calculator", 200, 900), delegation("del_1", at: 1000)]
            .joined(separator: "\n"))
        let id = try XCTUnwrap(spine.requests.first?.id)
        bridge.taskEvent(captureID: id, payload: #"{"kind":"task_question","status":"question","say":"Which one?"}"#)
        bridge.taskEvent(captureID: id, payload: #"{"kind":"task_outcome","status":"ok","say":"Done."}"#)
        bridge.taskEvent(captureID: id, payload: #"{"kind":"task_outcome","status":"ok","say":"Again."}"#)
        bridge.taskEvent(captureID: UUID(), payload: #"{"kind":"task_outcome","status":"ok","say":"Not ours."}"#)
        let spoken = session.appends.filter { $0.kind == .commentary }
        XCTAssertEqual(spoken.map(\.content), ["Which one?", "Done."])
        XCTAssertEqual(Set(spoken.map(\.delegationID)), ["del_1"])
    }

    func testAnImmediateAnswerIsSpoken() async throws {
        spine.reply = .answered("I haven't done anything yet.")
        try await replay([started(), said("what did you just do", 200, 900), delegation("del_1", at: 1000)]
            .joined(separator: "\n"))
        XCTAssertEqual(session.appends.map(\.kind), [.commentary])
        XCTAssertEqual(session.appends.first?.content, "I haven't done anything yet.")
    }

    func testWordsSaidWithTheNameStartTheFirstRequest() async throws {
        bridge.open(origin: .wakeWord, preface: "open Mail")
        try await replay([started(), delegation("del_1", at: 100)].joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.text), ["open Mail"])
    }

    func testARejectedResultIsRetriedOnceThenSaidWithoutItsDelegation() async throws {
        spine.reply = .answered("Done.")
        try await replay([started(), said("open Calculator", 200, 900), delegation("del_1", at: 1000)]
            .joined(separator: "\n"))
        func reject(_ append: LiveAppend?) throws {
            let id = try XCTUnwrap(append?.eventID)
            bridge.handle(.error(LiveError(type: "invalid_request_error", code: "unknown_delegation",
                                           message: "rejected", clientEventID: id, param: nil)))
        }
        try reject(session.appends.last)
        XCTAssertEqual(session.appends.count, 2)
        XCTAssertEqual(session.appends[1].delegationID, "del_1")
        XCTAssertNotEqual(session.appends[1].eventID, session.appends[0].eventID)
        try reject(session.appends.last)
        XCTAssertEqual(session.appends.count, 3)
        XCTAssertEqual(session.appends[2].kind, .commentary)
        XCTAssertEqual(session.appends[2].content, "Done.")
        XCTAssertNil(session.appends[2].delegationID)
        try reject(session.appends.last)
        XCTAssertEqual(session.appends.count, 3, "no endless retries")
    }

    // MARK: - Who spoke (D3)

    func testASessionOpenedWithTheNameTrustsTheWords() async throws {
        try await replay([started(), said("click send", 200, 900), delegation("del_1", at: 1000)]
            .joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.speakerVerified), [true])
    }

    func testTVSpeechAfterStandbyMakesConsequentialPressesAsk() async throws {
        try await replay([started(), said("open Mail", 200, 900), delegation("del_1", at: 1000),
                          #"{"type":"session.paused"}"#, #"{"type":"session.resumed"}"#,
                          said("delete this email", 12000, 13000), delegation("del_2", at: 13100)]
            .joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.text), ["open Mail", "delete this email"])
        XCTAssertEqual(spine.requests.map(\.speakerVerified), [true, false])
    }

    func testAnAlertReplyMakesConsequentialPressesAsk() async throws {
        bridge.open(origin: .alertReply)
        try await replay([started(), said("reply and send it", 200, 900), delegation("del_1", at: 1000)]
            .joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.speakerVerified), [false])
    }

    func testAnUnverifiedSpeakerIsAskedBeforeAConsequentialPress() async throws {
        var asked: [DriveLoop.Ask] = []
        let loop = DriveLoop(call: { _, _ in .object([:]) }, choose: { _, _ in nil },
                             ask: { ask in asked.append(ask); return "no" }, granted: { true })
        await loop.bindSpokenGoal("click Send", speakerVerified: false)
        var confirmed = false
        try await loop.gateExplicit("click", corpus: "Save Mail", denied: [], confirmed: &confirmed, press: "Save")
        XCTAssertTrue(asked.isEmpty, "an ordinary press goes ahead")
        do {
            try await loop.gateExplicit("click", corpus: "Send Mail", denied: [], confirmed: &confirmed, press: "Send")
            XCTFail("a no must stop the press")
        } catch DriveLoop.Abort.declined {}
        do {
            try await loop.consentGate(tool: "click", args: [:], elementText: "Send", denied: [], confirmed: &confirmed)
            XCTFail("the words don't cover the press")
        } catch DriveLoop.Abort.declined {}
        XCTAssertEqual(asked, [.confirm(Consequence.send.question(target: "Send")),
                               .confirm(Consequence.send.question(target: "Send"))])

        asked = []
        await loop.bindSpokenGoal("click Send")
        try await loop.gateExplicit("click", corpus: "Send Mail", denied: [], confirmed: &confirmed, press: "Send")
        try await loop.consentGate(tool: "click", args: [:], elementText: "Send", denied: [], confirmed: &confirmed)
        XCTAssertTrue(asked.isEmpty, "the person who said the name presses at once")
    }

    // MARK: - This and that

    func testDeicticWordTimeMapsOntoTheUptimeClock() async throws {
        bridge = makeBridge(referent: "Looking at: the Send button in Mail")
        try await replay([started(), said("click", 2000, 2400), said("this", 2500, 2800),
                          delegation("del_1", at: 2900)].joined(separator: "\n"))
        XCTAssertEqual(resolvedAt, [102.5], "session start at uptime 100, word at 2500 ms")
        XCTAssertEqual(spine.requests.first?.referent, "Looking at: the Send button in Mail")
        XCTAssertEqual(session.appends.first?.content, "Looking at: the Send button in Mail")
        XCTAssertEqual(session.appends.first?.delegationID, "del_1")
    }

    func testTakeBackPhrases() {
        XCTAssertTrue(DelegationBridge.takesBack("close it, no wait", fromStart: false))
        XCTAssertTrue(DelegationBridge.takesBack("open Mail. Stop.", fromStart: false))
        XCTAssertTrue(DelegationBridge.takesBack("never mind", fromStart: true))
        XCTAssertTrue(DelegationBridge.takesBack("stop", fromStart: true))
        XCTAssertFalse(DelegationBridge.takesBack("stop", fromStart: false), "a lone stop is a request")
        XCTAssertFalse(DelegationBridge.takesBack("stop the music", fromStart: true))
        XCTAssertFalse(DelegationBridge.takesBack("wait for the download and open it", fromStart: true))
        XCTAssertFalse(DelegationBridge.takesBack("open Calculator", fromStart: false))
    }
}
