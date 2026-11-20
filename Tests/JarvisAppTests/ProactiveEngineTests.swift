import XCTest
@testable import Jarvis

/// Proactivity delivery rules with an injected clock, context and voice:
/// every suppression, bundling, the caps, "not now" learning, the more/less
/// setting and the reply window. Nothing here speaks or opens a session.
@MainActor
final class ProactiveEngineTests: XCTestCase {
    private final class FakeVoice: OneWayVoice {
        var spoken: [String] = []
        var stops = 0
        func speak(_ text: String) { spoken.append(text) }
        func stop() { stops += 1 }
    }

    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var situation = ProactiveContext.clear
    private var voice: FakeVoice!
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: ProactiveSettings!
    private var engine: ProactiveEngine!

    override func setUp() {
        super.setUp()
        suite = "ProactiveEngineTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        voice = FakeVoice()
        settings = ProactiveSettings(defaults: defaults)
        engine = makeEngine()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeEngine() -> ProactiveEngine {
        ProactiveEngine(settings: settings, voice: voice, clock: { [unowned self] in self.now },
                        context: { [unowned self] in self.situation })
    }

    private func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    private var serial = 0
    private func alert(_ category: ProactiveCategory, _ headline: String? = nil, sender: String? = nil,
                       source: ProactiveSource = .calendar, expires: Date? = nil) -> ProactiveAlert {
        serial += 1
        return ProactiveAlert(key: "k\(serial)", source: source, category: category,
                              headline: headline ?? "Alert \(serial)", offer: "Want me to help?",
                              action: .request("help"), sender: sender, at: now, expires: expires)
    }

    // MARK: Speaking

    func testSpeakNowIsOneSentenceAndAnOfferWithNoConversation() {
        engine.submit([alert(.meetingNow, "Standup starts in 2 minutes")])
        XCTAssertEqual(voice.spoken, ["Standup starts in 2 minutes. Want me to help?"])
        XCTAssertNotNil(engine.awaiting)
        advance(9)
        engine.tick()
        XCTAssertNil(engine.awaiting, "an unanswered alert closes its reply window and opens nothing")
        XCTAssertEqual(engine.handleReply("tell me more"), .ignored)
    }

    func testTheSameKeyIsDeliveredOnce() {
        let meeting = alert(.meetingNow)
        engine.submit([meeting])
        advance(600)
        engine.submit([meeting])
        XCTAssertEqual(voice.spoken.count, 1)
    }

    func testGlowAndDigestTiersAreNeverSpoken() {
        engine.submit([alert(.message, "Message from Sam"), alert(.other, "Disk is almost full")])
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertEqual(engine.glow.map(\.headline), ["Message from Sam"])
        XCTAssertEqual(engine.digest.map(\.headline), ["Disk is almost full"])
    }

    // MARK: Suppression

    func testNothingIsSpokenWhileThePersonTalksThenItIsSpokenAfter() {
        situation.userTalking = true
        engine.submit([alert(.reminder, "Reminder: call Mom")])
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertEqual(engine.held.count, 1)
        engine.tick()
        XCTAssertTrue(voice.spoken.isEmpty)
        situation.userTalking = false
        advance(5)
        engine.tick()
        XCTAssertEqual(voice.spoken, ["Reminder: call Mom. Want me to help?"])
    }

    func testNothingIsSpokenOverJarvisOwnSpeech() {
        situation.jarvisSpeaking = true
        engine.submit([alert(.security)])
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertEqual(engine.held.count, 1)
    }

    func testOnACallAlertsGlowAndASecurityWarningIsShownNotSpoken() {
        situation.onCall = true
        engine.submit([alert(.meetingNow, "Standup"), alert(.security, "Careful: fake alert")])
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertEqual(engine.glow.map(\.headline), ["Standup"])
        XCTAssertEqual(engine.card?.headline, "Careful: fake alert")
        engine.dismissCard()
        XCTAssertNil(engine.card)
    }

    func testScreenSharingPresentingAndFocusEachSuppressSpeech() {
        for change: (inout ProactiveContext) -> Void in [
            { $0.screenSharing = true }, { $0.presenting = true }, { $0.focus = true },
        ] {
            situation = .clear
            change(&situation)
            engine.submit([alert(.urgentMessage), alert(.security)])
        }
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertEqual(engine.glow.count, 3)
        XCTAssertNotNil(engine.card)
    }

    func testUnknownFocusDoesNotSuppress() {
        situation.focus = nil
        engine.submit([alert(.meetingNow)])
        XCTAssertEqual(voice.spoken.count, 1)
    }

    // MARK: Bundling

    func testAlertsArrivingTogetherAreOneSentence() {
        engine.submit([alert(.meetingNow, "Standup starts now"), alert(.awaitedReply, "Dana replied"),
                       alert(.reminder, "Reminder: water the plants")])
        XCTAssertEqual(voice.spoken, ["Heads up: Standup starts now, Dana replied, and Reminder: water the plants. Want the details?"])
    }

    func testAlertsWithinTwoMinutesWaitAndGoOutTogether() {
        engine.submit([alert(.meetingNow, "Standup starts now")])
        advance(30)
        engine.submit([alert(.awaitedReply, "Dana replied")])
        advance(30)
        engine.submit([alert(.urgentMessage, "Urgent message from Sam")])
        XCTAssertEqual(voice.spoken.count, 1)
        XCTAssertEqual(engine.bundle.count, 2)
        advance(59)
        engine.tick()
        XCTAssertEqual(voice.spoken.count, 1)
        advance(1)
        engine.tick()
        XCTAssertEqual(voice.spoken.last, "Heads up: Dana replied and Urgent message from Sam. Want the details?")
        XCTAssertEqual(settings.budget.spoken.count, 2, "a bundle counts once against the cap")
    }

    func testSecurityIsNeverHeldForABundle() {
        engine.submit([alert(.meetingNow)])
        advance(10)
        engine.submit([alert(.security, "Careful: fake alert")])
        XCTAssertEqual(voice.spoken.last, "Careful: fake alert. Want me to help?")
    }

    func testABundledAlertThatGoesStaleOnlyReachesTheDigest() {
        engine.submit([alert(.meetingNow)])
        advance(10)
        engine.submit([alert(.meetingNow, "Sync starts now", expires: now.addingTimeInterval(60))])
        advance(120)
        engine.tick()
        XCTAssertEqual(voice.spoken.count, 1)
        XCTAssertEqual(engine.digest.map(\.headline), ["Sync starts now"])
    }

    // MARK: Caps

    func testThreeSpokenAlertsAnHourThenGlowUntilTheHourPasses() {
        for _ in 0..<3 {
            engine.submit([alert(.urgentMessage)])
            advance(130)
        }
        engine.submit([alert(.urgentMessage, "Fourth")])
        XCTAssertEqual(voice.spoken.count, 3)
        XCTAssertEqual(engine.glow.map(\.headline), ["Fourth"])
        advance(3_600)
        engine.submit([alert(.urgentMessage, "Fifth")])
        XCTAssertEqual(voice.spoken.last, "Fifth. Want me to help?")
    }

    func testTenSpokenAlertsADay() {
        for _ in 0..<10 {
            engine.submit([alert(.urgentMessage)])
            advance(1_300)
        }
        XCTAssertEqual(voice.spoken.count, 10)
        engine.submit([alert(.urgentMessage, "Eleventh")])
        XCTAssertEqual(voice.spoken.count, 10)
        XCTAssertEqual(engine.glow.last?.headline, "Eleventh")
    }

    func testSecurityAndRemindersDoNotCountAgainstTheCap() {
        for _ in 0..<3 {
            engine.submit([alert(.urgentMessage)])
            advance(130)
        }
        engine.submit([alert(.security, "Careful")])
        advance(130)
        engine.submit([alert(.reminder, "Reminder: pills")])
        XCTAssertEqual(Array(voice.spoken.suffix(2)), ["Careful. Want me to help?", "Reminder: pills. Want me to help?"])
    }

    func testOverTheCapABundleKeepsOnlyExemptItems() {
        for _ in 0..<3 {
            engine.submit([alert(.urgentMessage)])
            advance(130)
        }
        engine.submit([alert(.meetingNow, "Standup"), alert(.reminder, "Reminder: pills")])
        XCTAssertEqual(voice.spoken.last, "Reminder: pills. Want me to help?")
        XCTAssertEqual(engine.glow.map(\.headline), ["Standup"])
    }

    // MARK: Learning

    func testNotNowSnoozesTheSenderForAnHour() {
        engine.submit([alert(.urgentMessage, sender: "Dana")])
        XCTAssertEqual(engine.handleReply("Not now."), .snoozed)
        advance(200)
        engine.submit([alert(.urgentMessage, "Dana again", sender: "dana")])
        XCTAssertEqual(voice.spoken.count, 1)
        XCTAssertEqual(engine.glow.map(\.headline), ["Dana again"])
        engine.submit([alert(.urgentMessage, "Sam", sender: "Sam")])
        XCTAssertEqual(voice.spoken.last, "Sam. Want me to help?")
        advance(3_600)
        engine.submit([alert(.urgentMessage, "Dana later", sender: "Dana")])
        XCTAssertEqual(voice.spoken.last, "Dana later. Want me to help?")
    }

    func testNotNowWithoutASenderSnoozesTheSource() {
        engine.submit([alert(.meetingNow, source: .calendar)])
        _ = engine.handleReply("later")
        advance(200)
        engine.submit([alert(.meetingNow, "Next meeting", source: .calendar),
                       alert(.reminder, "Reminder: pills", source: .reminders)])
        XCTAssertEqual(voice.spoken.last, "Reminder: pills. Want me to help?")
        XCTAssertEqual(engine.glow.map(\.headline), ["Next meeting"])
    }

    func testThreeNotNowsDemoteTheCategoryToTheGlow() {
        for name in ["A", "B", "C"] {
            engine.submit([alert(.awaitedReply, sender: name)])
            XCTAssertEqual(engine.handleReply("not now"), .snoozed)
            advance(1_300)
        }
        engine.submit([alert(.awaitedReply, "D replied", sender: "D")])
        XCTAssertEqual(voice.spoken.count, 3)
        XCTAssertEqual(engine.glow.map(\.headline), ["D replied"])
        engine.submit([alert(.urgentMessage, "Urgent from E", sender: "E")])
        XCTAssertEqual(voice.spoken.last, "Urgent from E. Want me to help?", "only that category is demoted")
    }

    func testNotNowNeverHidesASecurityWarning() {
        for _ in 0..<3 {
            engine.submit([alert(.security, source: .safety)])
            _ = engine.handleReply("not now")
            advance(10)
        }
        engine.submit([alert(.security, "Careful again", source: .safety)])
        XCTAssertEqual(voice.spoken.last, "Careful again. Want me to help?")
    }

    func testLearningPersistsAndPickingALevelResetsIt() {
        for name in ["A", "B", "C"] {
            engine.submit([alert(.awaitedReply, sender: name)])
            _ = engine.handleReply("not now")
            advance(130)
        }
        let reloaded = ProactiveSettings(defaults: defaults)
        XCTAssertTrue(reloaded.learning.isDemoted(.awaitedReply))
        reloaded.level = .normal
        XCTAssertFalse(reloaded.learning.isDemoted(.awaitedReply))
    }

    // MARK: More / less

    func testQuietSpeaksOnlySafetyAndReminders() {
        settings.level = .quiet
        engine.submit([alert(.meetingNow, "Standup"), alert(.message, "Message from Sam")])
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertEqual(engine.glow.map(\.headline), ["Standup"])
        XCTAssertEqual(engine.digest.map(\.headline), ["Message from Sam"])
        engine.submit([alert(.security, "Careful")])
        advance(130)
        engine.submit([alert(.reminder, "Reminder: pills")])
        XCTAssertEqual(voice.spoken, ["Careful. Want me to help?", "Reminder: pills. Want me to help?"])
    }

    func testChattySpeaksGlowItemsWithAHigherCap() {
        settings.level = .chatty
        for index in 0..<7 {
            engine.submit([alert(.message, "Message \(index)")])
            advance(130)
        }
        XCTAssertEqual(voice.spoken.count, 6)
        XCTAssertEqual(engine.glow.map(\.headline), ["Message 6"])
    }

    // MARK: Replies

    func testYesOnOneAlertHandsBackItsAction() {
        let meeting = alert(.meetingNow)
        engine.submit([meeting])
        XCTAssertEqual(engine.handleReply("Yes please"), .accepted([meeting]))
        XCTAssertNil(engine.awaiting)
    }

    func testYesOnABundleHandsBackEveryAlert() {
        let first = alert(.meetingNow, "A"), second = alert(.reminder, "B")
        engine.submit([first, second])
        XCTAssertEqual(engine.handleReply("sure"), .accepted([first, second]))
    }

    func testTheContextIsOnlyReadWhenSomethingMightBeSpoken() {
        var reads = 0
        engine = ProactiveEngine(settings: settings, voice: voice, clock: { [unowned self] in self.now },
                                 context: { reads += 1; return .clear })
        engine.tick()
        engine.submit([alert(.message)])
        XCTAssertEqual(reads, 0)
        engine.submit([alert(.meetingNow)])
        XCTAssertEqual(reads, 1)
    }

    func testNoDeclinesWithoutLearning() {
        engine.submit([alert(.urgentMessage, sender: "Dana")])
        XCTAssertEqual(engine.handleReply("no thanks"), .declined)
        advance(200)
        engine.submit([alert(.urgentMessage, "Dana again", sender: "Dana")])
        XCTAssertEqual(voice.spoken.count, 2)
    }

    func testAnythingElseOpensAConversationSeededWithTheAlert() {
        engine.submit([alert(.meetingNow, "Standup starts now")])
        advance(3)
        guard case .converse(let seed) = engine.handleReply("who's in it?") else {
            return XCTFail("expected a conversation")
        }
        XCTAssertTrue(seed.contains("Standup starts now. Want me to help?"))
        XCTAssertTrue(seed.contains("who's in it?"))
    }

    func testTheReplyWindowStaysOpenWhileTheAlertIsStillBeingSpoken() {
        let first = alert(.meetingNow, "A"), second = alert(.reminder, "B")
        engine.submit([first, second])
        situation.jarvisSpeaking = true
        advance(7)
        engine.tick()
        advance(7)
        engine.tick()
        situation.jarvisSpeaking = false
        advance(7)
        engine.tick()
        XCTAssertEqual(engine.handleReply("yes"), .accepted([first, second]))
    }

    func testALateReplyIsIgnored() {
        engine.submit([alert(.meetingNow)])
        advance(8)
        XCTAssertEqual(engine.handleReply("yes"), .ignored)
    }

    // MARK: What's up / what did I miss

    func testWhatsUpReadsTheGlowAndClearsIt() {
        XCTAssertEqual(engine.whatsUp(), "Nothing new.")
        engine.submit([alert(.message, "Message from Sam"), alert(.update, "Your order is out for delivery")])
        XCTAssertEqual(engine.whatsUp(), "Two things: Message from Sam; Your order is out for delivery.")
        XCTAssertTrue(engine.glow.isEmpty)
    }

    func testWhatDidIMissReadsTheDigestAndGlow() {
        engine.submit([alert(.other, "Backup finished"), alert(.message, "Message from Sam")])
        XCTAssertEqual(engine.whatDidIMiss(), "While you were busy: Backup finished; Message from Sam.")
        XCTAssertEqual(engine.whatDidIMiss(), "You haven't missed anything.")
    }
}
