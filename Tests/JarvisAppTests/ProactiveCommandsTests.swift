import XCTest
@testable import Jarvis

/// The spoken requests proactivity answers before the task loop, and the
/// screen-sharing heuristic. Nothing is opened, spoken aloud or read from
/// the Mac.
@MainActor
final class ProactiveCommandsTests: XCTestCase {
    private final class SilentVoice: OneWayVoice {
        var spoken: [String] = []
        func speak(_ text: String) { spoken.append(text) }
        func stop() {}
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: ProactiveSettings!
    private var engine: ProactiveEngine!
    private var opened: [URL] = []
    private var completed: [String] = []
    private var spoken: [String] = []

    override func setUp() {
        super.setUp()
        suite = "ProactiveCommandsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = ProactiveSettings(defaults: defaults)
        engine = ProactiveEngine(settings: settings, voice: SilentVoice(), clock: { [unowned self] in self.now },
                                 context: { .clear })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var commands: ProactiveCommands {
        ProactiveCommands(engine: engine, settings: settings,
                          speak: { [unowned self] in self.spoken.append($0) },
                          openURL: { [unowned self] in self.opened.append($0) },
                          completeReminder: { [unowned self] in self.completed.append($0); return true })
    }

    private func alert(_ category: ProactiveCategory, _ headline: String, action: ProactiveAction?) -> ProactiveAlert {
        ProactiveAlert(key: headline, source: .calendar, category: category, headline: headline,
                       offer: "Want me to?", action: action, at: now)
    }

    func testOrdinaryRequestsPassThrough() {
        XCTAssertNil(commands.intercept("open Calculator"))
        XCTAssertNil(commands.intercept("yes"), "a yes with no alert waiting is not a reply")
    }

    func testWhatsUpAndWhatDidIMiss() {
        engine.submit([alert(.message, "Message from Sam", action: nil), alert(.other, "Backup finished", action: nil)])
        XCTAssertEqual(commands.intercept("What's up?"), .say("One thing: Message from Sam."))
        XCTAssertEqual(commands.intercept("what did I miss"), .say("While you were busy: Backup finished."))
    }

    func testTellMeWhenSomeoneRepliesAddsAWatch() {
        XCTAssertEqual(commands.intercept("Tell me when Dana replies."), .say("I'll tell you when dana replies."))
        XCTAssertEqual(settings.watches, ["dana"])
        let banner = BannerRules.alerts([BannerSnapshot(app: "Messages", title: "Dana", body: "Done")],
                                        important: [], watches: settings.watches, now: now)
        XCTAssertEqual(banner.first?.category, .awaitedReply)
    }

    func testYesRunsTheAlertsOffer() {
        let link = URL(string: "https://zoom.us/j/1")!
        engine.submit([alert(.meetingNow, "Standup starts now", action: .openURL(link))])
        XCTAssertEqual(commands.intercept("yes"), .say("Opening it."))
        XCTAssertEqual(opened, [link])

        now = now.addingTimeInterval(200)
        engine.submit([alert(.security, "Careful: fake alert", action: .request("close this tab"))])
        XCTAssertEqual(commands.intercept("sure"), .request("close this tab"))

        now = now.addingTimeInterval(200)
        engine.submit([alert(.reminder, "Reminder: pills", action: .completeReminder("r1"))])
        XCTAssertEqual(commands.intercept("okay"), .say("Done."))
        XCTAssertEqual(completed, ["r1"])
    }

    func testTheWakePhraseIsNotPartOfTheReply() {
        let link = URL(string: "https://zoom.us/j/2")!
        engine.submit([alert(.meetingNow, "Review starts now", action: .openURL(link))])
        XCTAssertEqual(commands.intercept("Hey Jarvis, yes."), .say("Opening it."))
        XCTAssertEqual(opened, [link])
        XCTAssertEqual(commands.intercept("Jarvis, what's up?"), .say("Nothing new."))
        XCTAssertEqual(commands.intercept("hey jarvis tell me when Dana replies"), .say("I'll tell you when dana replies."))
    }

    func testBeginVoiceTaskInterceptsThePersonsWordsNotTheModelsInstruction() async {
        let config = Config(defaults: defaults, keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.handsFreeEnabled = false
        let coordinator = VoiceTaskCoordinator(config: config, jevRoute: { nil },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })))
        var heard: [String] = []
        coordinator.proactiveIntercept = { heard.append($0); return .say("Opening it.") }
        let result = await coordinator.beginVoiceTask("open the meeting link", transcriptHint: "Yes.")
        XCTAssertEqual(heard, ["Yes."])
        XCTAssertFalse(result.contains("Opening it."), "the answer was spoken on the Mac, not handed to the model")
        XCTAssertTrue(result.contains("answered this aloud on the Mac"))
        XCTAssertTrue(coordinator.tasks.isEmpty)
    }

    func testAMessageIsReadAloudOnTheMac() {
        engine.submit([alert(.urgentMessage, "Urgent from Mom", action: .read("Mom says: call me asap"))])
        XCTAssertEqual(commands.intercept("yes"), .say("Mom says: call me asap"))
        XCTAssertEqual(spoken, ["Mom says: call me asap"])
        XCTAssertEqual(commands.intercept("open Calculator"), nil)
        XCTAssertEqual(spoken, ["Mom says: call me asap"], "nothing is spoken for a request proactivity leaves alone")
    }

    func testLiveRepliesAreAnsweredBeforeAdmissionAndNeverReachTheModel() async throws {
        let conversation = ConversationSession()
        var context = VoiceAdmissionContext()
        context.targetAppID = "fixture.editor"; context.windowID = 42
        context.targetID = "fixture.editor.42"
        conversation.makeSpeechSession = { captured in
            let owner = LocalSpeechSession { _ in XCTFail("queue owns execution") }
            owner.context = captured
            return owner
        }
        conversation.readContext = { context }
        conversation.interpret = { _, _, _ in
            XCTFail("a proactive answer or a native scroll must not call a model")
            return .init(kind: .clarify)
        }
        conversation.remote = { _, _, _ in XCTFail("a proactive answer must not reach the Live model") }
        var executed: [String] = []
        let effect = expectation(description: "the offered request runs")
        conversation.execute = { command in
            executed.append(command.text)
            effect.fulfill()
            return .init(verified: true, waitingForAnswer: false, message: "Scrolled.")
        }
        conversation.onControl = { _ in }
        var ignored: [UUID] = []
        conversation.onEvent = { if case .ignored(let turn) = $0 { ignored.append(turn) } }
        var heard: [String] = []
        conversation.proactiveIntercept = { text in
            heard.append(text)
            switch text {
            case "What's up?": return .say("One thing: Message from Sam.")
            case "Yes.": return .request("scroll down")
            default: return nil
            }
        }
        let session = UUID(), connection = UUID()
        try conversation.startExternal(session: session)
        defer { conversation.stop() }

        let whatsUp = try conversation.beginExternal(input: .init(connectionID: connection, itemID: "up"), at: 1)
        XCTAssertTrue(conversation.commitExternal(whatsUp, at: 2))
        await conversation.finishExternal(whatsUp, text: "What's up?", at: 2.1)
        XCTAssertEqual(ignored, [whatsUp.turn.id], "an answered turn ends on the Mac")

        let reply = try conversation.beginExternal(input: .init(connectionID: connection, itemID: "yes"), at: 3)
        XCTAssertTrue(conversation.commitExternal(reply, at: 4))
        await conversation.finishExternal(reply, text: "Yes.", at: 4.1)
        await fulfillment(of: [effect], timeout: 2)
        XCTAssertEqual(heard, ["What's up?", "Yes."])
        XCTAssertEqual(executed, ["scroll down"], "the offered request is admitted in place of the reply")
    }

    func testNoAndNotNowAreAnsweredAndOtherRepliesFallThrough() {
        engine.submit([alert(.urgentMessage, "Urgent from Mom", action: .read("Mom says: call me"))])
        XCTAssertEqual(commands.intercept("not now"), .say("Okay, later."))
        now = now.addingTimeInterval(200)
        engine.submit([alert(.meetingNow, "Sync starts now", action: nil)])
        XCTAssertNil(commands.intercept("who's in it"), "anything else goes on to a conversation or the task loop")
        XCTAssertNil(engine.awaiting)
    }

    func testSafetyCardIsSizedFromThePublishedCard() {
        let card = alert(.security, "Careful: this page is a fake virus warning", action: nil)
        let content = ProactiveCardPanel.content(for: card) {}
        XCTAssertEqual(content.frame.width, 480)
        XCTAssertGreaterThan(content.frame.height, 80, "the panel is measured with the card's text, not empty")
    }

    func testScreenSharingIsReadFromIndicatorWindowNames() {
        XCTAssertTrue(ProactiveContextProbe.sharing([[kCGWindowName as String: "meet.google.com is sharing your screen."]]))
        XCTAssertFalse(ProactiveContextProbe.sharing([[kCGWindowName as String: "Inbox"], [:]]))
    }
}
