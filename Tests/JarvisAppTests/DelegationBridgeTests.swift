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
        var last: String?
        var finishGate: SleepGate?
        func begin(_ request: DelegatedRequest) async -> DelegationSpineReply {
            requests.append(request)
            return reply
        }
        func finished(_ request: DelegatedRequest) async -> String? {
            await finishGate?.wait()
            return last
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

    func testAnotherDelegationDoesNotCutTheSettlingWindowShort() async throws {
        try await replay([started(), said("close it,", 100, 600), delegation("del_1", at: 700),
                          delegation("del_2", at: 750), said("no wait, stop", 800, 1500)].joined(separator: "\n"))
        XCTAssertTrue(spine.requests.isEmpty, "the take-back arrived inside del_1's window")
    }

    func testAStoppedRequestTakesItsPrefaceWithIt() async throws {
        bridge.open(origin: .wakeWord, preface: "close Mail")
        bridge.handle(try Self.event(started()))
        bridge.handle(try Self.event(delegation("del_1", at: 100)))
        bridge.bargeIn()
        await drain()
        try await replay(delegation("del_2", at: 200))
        XCTAssertTrue(spine.requests.isEmpty, "a later delegation must not revive the stopped words")
    }

    func testDictatedTakeBackWordsAreText() async throws {
        try await replay([started(), said("type never mind", 100, 900), delegation("del_1", at: 1000),
                          said("", 1000, 1400)].joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.text), ["type never mind"])
    }

    func testAStopAfterDictatedTextCancelsIt() async throws {
        try await replay([started(), said("type hello", 100, 700), delegation("del_1", at: 800),
                          said("stop", 900, 1200)].joined(separator: "\n"))
        XCTAssertTrue(spine.requests.isEmpty, "the person stopped the typing before it was committed")
        XCTAssertEqual(bridge.ledger.state(of: .init(liveSessionID: "sess_1", delegationID: "del_1")),
                       .declined("barge-in"))
    }

    func testTakeBackWordsSaidAsTheTextAreStillTyped() async throws {
        try await replay([started(), said("type", 100, 400), delegation("del_1", at: 500),
                          said("never mind", 450, 900)].joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.text), ["type never mind"])
    }

    func testWordsLaterThanTheLagWaitGoToTheNextRequest() async throws {
        try await replay([started(), delegation("del_1", at: 1000)].joined(separator: "\n"))
        XCTAssertTrue(spine.requests.isEmpty)
        try await replay([said("open Calculator", 200, 900), delegation("del_2", at: 1500), said("", 1500, 1900)]
            .joined(separator: "\n"))
        XCTAssertEqual(spine.requests.map(\.text), ["open Calculator"], "the late words were never consumed")
    }

    func testWorkThatEndsOffTheResultPathIsStillSpoken() async throws {
        spine.last = "'Mail' could be Mail or Mailspring — say which."
        try await replay([started(), said("open Mail", 200, 900), delegation("del_1", at: 1000)]
            .joined(separator: "\n"))
        let spoken = session.appends.filter { $0.kind == .commentary }
        XCTAssertEqual(spoken.map(\.content), ["'Mail' could be Mail or Mailspring — say which."])
        XCTAssertEqual(spoken.first?.delegationID, "del_1")
    }

    func testTheResultIsNotSpokenTwice() async throws {
        let gate = SleepGate()
        spine.finishGate = gate
        spine.last = "Done."
        try await replay([started(), said("open Calculator", 200, 900), delegation("del_1", at: 1000)]
            .joined(separator: "\n"))
        let id = try XCTUnwrap(spine.requests.first?.id)
        bridge.taskEvent(captureID: id, payload: #"{"kind":"task_outcome","status":"ok","say":"Calculator is open."}"#)
        gate.open()
        await drain()
        XCTAssertEqual(session.appends.filter { $0.kind == .commentary }.map(\.content), ["Calculator is open."])
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
        do {
            try await loop.gateExplicit("click", corpus: "Mail", denied: [], confirmed: &confirmed, press: "")
            XCTFail("a click with no label asks too")
        } catch DriveLoop.Abort.declined {}
        XCTAssertEqual(asked, [.confirm(Consequence.send.question(target: "Send")),
                               .confirm(Consequence.send.question(target: "Send")),
                               .confirm(Consequence.unnamed.question(target: ""))])

        asked = []
        await loop.bindSpokenGoal("click Send")
        try await loop.gateExplicit("click", corpus: "Send Mail", denied: [], confirmed: &confirmed, press: "Send")
        try await loop.consentGate(tool: "click", args: [:], elementText: "Send", denied: [], confirmed: &confirmed)
        try await loop.gateExplicit("click", corpus: "Mail", denied: [], confirmed: &confirmed, press: "")
        XCTAssertTrue(asked.isEmpty, "the person who said the name presses at once")
    }

    // MARK: - Through the real spine (JARA-54 P1-4)

    func testAfterStandbyAClickOnSendThroughTheRealCoordinatorAsksFirst() async throws {
        let desk = SpineDesk()
        let coordinator = spineCoordinator(desk)
        defer { coordinator.shutdown() }
        wireBridge(to: coordinator)
        try await replay([started(), #"{"type":"session.paused"}"#, #"{"type":"session.resumed"}"#,
                          said("click Send in Mail", 12000, 12600), delegation("del_1", at: 13000)].joined(separator: "\n"))
        let parked = await waitFor { coordinator.tasks.contains { $0.ask != nil } || !desk.presses.isEmpty }
        XCTAssertTrue(parked, "the task never reached Send")
        XCTAssertEqual(desk.presses, [], "after Standby another voice must not press Send unasked (D3)")
        guard case .confirm(let question)? = coordinator.tasks.compactMap(\.ask).first else {
            return XCTFail("expected a yes/no question before Send")
        }
        XCTAssertTrue(question.contains("sends this to other people"), question)
        XCTAssertTrue(session.appends.contains { $0.kind == .commentary && $0.delegationID == "del_1" },
                      "the question goes back to Live with its delegation")
        coordinator.stopAll()
    }

    func testTheNameSaidThisSessionPressesSendThroughTheRealCoordinatorAtOnce() async throws {
        let desk = SpineDesk()
        let coordinator = spineCoordinator(desk)
        defer { coordinator.shutdown() }
        wireBridge(to: coordinator)
        try await replay([started(), said("click Send in Mail", 200, 800), delegation("del_1", at: 1200)]
            .joined(separator: "\n"))
        let pressed = await waitFor { !desk.presses.isEmpty || coordinator.tasks.contains { $0.ask != nil } }
        XCTAssertTrue(pressed, "the task never reached Send")
        XCTAssertFalse(desk.presses.isEmpty, "the person who said the name presses at once")
        XCTAssertTrue(coordinator.tasks.allSatisfy { $0.ask == nil })
        coordinator.stopAll()
    }

    func testAYesWithTwoQuestionsWaitingAnswersNeither() async throws {
        let coordinator = spineCoordinator(SpineDesk())
        defer { coordinator.shutdown() }
        let first = VoiceTaskCoordinator.Work(label: "Sending the reply", request: "send the reply",
                                              spec: DriveTask(goal: "send the reply"))
        let second = VoiceTaskCoordinator.Work(label: "Deleting the draft", request: "delete the draft",
                                               spec: DriveTask(goal: "delete the draft"))
        coordinator.tasks = [first, second]
        let asks = [Task { await coordinator.park(.confirm("Send it?"), on: first) },
                    Task { await coordinator.park(.confirm("Delete it?"), on: second) }]
        let parked = await waitFor { first.awaitingAnswer && second.awaitingAnswer }
        XCTAssertTrue(parked)
        let reply = await coordinator.begin(DelegatedRequest(id: UUID(), text: "yes", speakerVerified: true,
                                                             deicticTime: nil))
        guard case .answered(let say) = reply else { return XCTFail("expected a question back, got \(reply)") }
        XCTAssertTrue(say.contains("Nothing was answered"), say)
        XCTAssertTrue(first.awaitingAnswer && second.awaitingAnswer, "a bare yes must not pick the newest ask")
        coordinator.cancel(first.id)
        coordinator.cancel(second.id)
        for ask in asks { _ = await ask.value }
    }

    func testANewSessionDeclinesRequestsStillWaitingFromTheOldOne() async throws {
        let gate = SleepGate()
        bridge = DelegationBridge(live: session, spine: spine, sleep: { _ in await gate.wait() }, uptime: { 100 })
        for line in [started("sess_1"), said("open Calculator", 200, 900), delegation("del_1", at: 1000),
                     started("sess_2"), said("delete this email", 100, 1400), delegation("del_2", at: 1500)] {
            bridge.handle(try Self.event(line))
        }
        await drain()
        gate.open()
        await drain()
        XCTAssertEqual(spine.requests.map(\.text), ["delete this email"],
                       "del_1 ended with its session; the new session's words run once, for its own delegation")
    }

    private func wireBridge(to coordinator: VoiceTaskCoordinator) {
        let bridge = DelegationBridge(live: session, spine: coordinator, sleep: { _ in })
        coordinator.taskEventSink = { [weak bridge] id, payload, _ in bridge?.taskEvent(captureID: id, payload: payload) }
        self.bridge = bridge
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func spineCoordinator(_ desk: SpineDesk) -> VoiceTaskCoordinator {
        usePrivateStandingGrants()
        let config = Config(defaults: UserDefaults(suiteName: "delegation-spine-\(UUID().uuidString)")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        config.alwaysAllowComputerUse = true
        let coordinator = VoiceTaskCoordinator(
            config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay(),
            resolver: AppResolver(exactBundleApps: { _ in [] }, listApps: {
                [AppResolver.App(name: "Mail", bundle: "com.apple.mail", pid: SpineDesk.mailPID)]
            }),
            commandDriver: { tool, args in try await desk.call(tool, args) },
            foregroundAppLauncher: { _ in SpineDesk.mailPID },
            desktopSpaces: DesktopSpaceSwitch.System(
                roots: { [] }, children: { _ in nil }, attr: { _, _ in nil },
                pressable: { _ in false }, press: { _ in false },
                displayID: { 9 }, labels: { nil },
                openMissionControl: {}, pause: {},
                watchSpaceChange: { { _ in true } },
                layout: { nil }, shortcutEnabled: { _ in true }),
            activateApp: { _ in })
        coordinator.gazeContextProvider = { nil }
        return coordinator
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The driver behind the real coordinator: Mail frontmost with Archive
    /// and Send in its toolbar. Records every press.
    private final class SpineDesk: @unchecked Sendable {
        static let mailPID = 424_301
        private let lock = NSLock()
        private var pressed: [String] = []
        var presses: [String] { lock.withLock { pressed } }

        func call(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            if ["click", "press", "perform_action"].contains(tool) { lock.withLock { pressed.append(tool) } }
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Mail"), "bundle_id": .string("com.apple.mail"),
                                                         "pid": .number(Double(Self.mailPID)), "active": .bool(true)])])])
            case "list_windows":
                return .object(["windows": .array([.object([
                    "window_id": .number(11), "pid": .number(Double(Self.mailPID)), "app_name": .string("Mail"),
                    "title": .string("New Message"),
                    "bounds": .object(["x": .number(80), "y": .number(60), "width": .number(1100), "height": .number(760)]),
                    "z_index": .number(1), "is_on_screen": .bool(true), "is_minimized": .bool(false)])])])
            case "get_window_state":
                return .object(["pid": .number(Double(Self.mailPID)), "window_id": .number(11),
                                "window_title": .string("New Message"), "snapshot_id": .string("spine-snapshot"),
                                "elements": .array(["Archive", "Send"].enumerated().map { index, label in
                                    .object(["element_index": .number(Double(index + 1)),
                                             "element_token": .string("tok-\(index + 1)"),
                                             "role": .string("AXButton"), "label": .string(label),
                                             "actions": .array([.string("AXPress")]),
                                             "frame": .object(["x": .number(120 + Double(index) * 64), "y": .number(70),
                                                               "w": .number(56), "h": .number(28)])])
                                })])
            default:
                return .object(["effect": .string("confirmed")])
            }
        }
    }

    /// A sleep that holds every waiting delegation until the test opens it.
    private final class SleepGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }

        func open() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            waiting.forEach { $0.resume() }
        }
    }

    // MARK: - This and that

    func testDeicticWordTimeMapsOntoTheUptimeClock() async throws {
        bridge = makeBridge(referent: "Looking at: the Send button in Mail")
        try await replay([started(), said("click", 2000, 2400), said("this", 2500, 2800),
                          delegation("del_1", at: 2900)].joined(separator: "\n"))
        XCTAssertEqual(resolvedAt, [102.5], "session start at uptime 100, word at 2500 ms")
        XCTAssertEqual(spine.requests.first?.deicticTime, 102.5, "writing resolves \"this\" at the same moment")
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
