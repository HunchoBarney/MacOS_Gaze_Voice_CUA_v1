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

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: ProactiveSettings!
    private var engine: ProactiveEngine!
    private var opened: [URL] = []
    private var completed: [String] = []

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

    func testNoAndNotNowAreAnsweredAndOtherRepliesFallThrough() {
        engine.submit([alert(.urgentMessage, "Urgent from Mom", action: .read("Mom says: call me"))])
        XCTAssertEqual(commands.intercept("not now"), .say("Okay, later."))
        now = now.addingTimeInterval(200)
        engine.submit([alert(.meetingNow, "Sync starts now", action: nil)])
        XCTAssertNil(commands.intercept("who's in it"), "anything else goes on to a conversation or the task loop")
        XCTAssertNil(engine.awaiting)
    }

    func testScreenSharingIsReadFromIndicatorWindowNames() {
        XCTAssertTrue(ProactiveContextProbe.sharing([[kCGWindowName as String: "meet.google.com is sharing your screen."]]))
        XCTAssertFalse(ProactiveContextProbe.sharing([[kCGWindowName as String: "Inbox"], [:]]))
    }
}
