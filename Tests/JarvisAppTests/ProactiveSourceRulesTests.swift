import XCTest
@testable import Jarvis

/// The source rules: calendar, reminders, screen safety and notification
/// banners, each from hand-built snapshots.
final class ProactiveSourceRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func event(_ id: String, _ title: String, in minutes: Double, for length: Double = 30,
                       allDay: Bool = false, declined: Bool = false, link: URL? = nil) -> CalendarEventSnapshot {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEventSnapshot(id: id, title: title, start: start, end: start.addingTimeInterval(length * 60),
                                     isAllDay: allDay, declined: declined, meetingLink: link)
    }

    // MARK: Calendar

    func testAMeetingWithinTwoMinutesIsSpokenWithItsLink() throws {
        let link = URL(string: "https://zoom.us/j/123")!
        let alerts = CalendarRules.alerts([event("a", "Standup", in: 2, link: link), event("b", "Lunch", in: 40)],
                                          now: now, calendar: calendar)
        XCTAssertEqual(alerts.count, 1)
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alert.category, .meetingNow)
        XCTAssertTrue(alert.spoken.hasPrefix("Standup starts at 8:02"), alert.spoken)
        XCTAssertTrue(alert.spoken.hasSuffix("M. Want me to open the meeting link?"), alert.spoken)
        XCTAssertEqual(alert.action, .openURL(link))
        XCTAssertEqual(alert.expires, now.addingTimeInterval(240))
    }

    func testAMeetingHeadlineStaysTrueWhileTheAlertIsHeld() throws {
        let alert = try XCTUnwrap(CalendarRules.alerts([event("a", "Standup", in: 1.5)], now: now, calendar: calendar).first)
        XCTAssertFalse(alert.headline.contains("minute"), "a countdown goes stale while the engine holds or bundles it")
        XCTAssertTrue(alert.headline.hasPrefix("Standup starts at 8:01"), alert.headline)
        let soon = try XCTUnwrap(CalendarRules.alerts([event("b", "Sync", in: 0.75)], now: now, calendar: calendar).first)
        XCTAssertEqual(soon.headline, "Sync starts now")
    }

    func testAllDayDeclinedAndPastMeetingsAreSkipped() {
        let alerts = CalendarRules.alerts([
            event("a", "Holiday", in: 1, allDay: true), event("b", "Declined", in: 1, declined: true),
            event("c", "Started", in: -2),
        ], now: now, calendar: calendar)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testAMeetingStartingNowSaysSo() {
        let alerts = CalendarRules.alerts([event("a", "", in: 0)], now: now, calendar: calendar)
        XCTAssertEqual(alerts.first?.spoken, "Your meeting starts now.")
    }

    func testOverlappingMeetingsInTheNextHourClash() throws {
        let alerts = CalendarRules.alerts([
            event("a", "Design review", in: 20, for: 60), event("b", "1:1 with Dana", in: 40),
            event("c", "Later", in: 120),
        ], now: now, calendar: calendar)
        let clash = try XCTUnwrap(alerts.first { $0.category == .meetingClash })
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(clash.headline.hasPrefix("Design review and 1:1 with Dana overlap at 8:40"), clash.headline)
        XCTAssertEqual(clash.key, "calendar.clash.a.b")
    }

    func testAMeetingLinkIsFoundInLocationOrNotes() {
        XCTAssertEqual(CalendarRules.meetingLink(in: [nil, "Room 4", "Join: https://meet.google.com/abc-defg-hij"]),
                       URL(string: "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(CalendarRules.meetingLink(in: ["https://us02web.zoom.us/j/99"]), URL(string: "https://us02web.zoom.us/j/99"))
        XCTAssertNil(CalendarRules.meetingLink(in: ["https://example.com/zoom.us"]))
    }

    // MARK: Reminders

    func testADueReminderIsSpokenAndAnOldOneOnlyReachesTheDigest() {
        let alerts = ReminderRules.alerts([
            ReminderSnapshot(id: "r1", title: "Take pills", due: now.addingTimeInterval(-30)),
            ReminderSnapshot(id: "r2", title: "Future", due: now.addingTimeInterval(60)),
            ReminderSnapshot(id: "r3", title: "Done", due: now, completed: true),
        ], now: now)
        XCTAssertEqual(alerts.map(\.spoken), ["Reminder: Take pills. Want me to mark it done?"])
        XCTAssertEqual(alerts.first?.action, .completeReminder("r1"))
        XCTAssertEqual(alerts.first?.expires, now.addingTimeInterval(570))
    }

    // MARK: Safety

    private func page(_ items: [ScreenDigest.Item], url: String = "https://scam.example/alert") -> ScreenDigest {
        ScreenDigest(app: "Safari", bundleID: "com.apple.Safari", windowTitle: "Alert", pageURL: url,
                     items: items, webArea: true)
    }

    func testAFakeSecurityAlertWithAPhoneNumberIsAWarning() throws {
        let digest = page([.init(ref: "e1", kind: "heading", text: "Your Mac is infected with a virus"),
                           .init(ref: "e2", kind: "text", text: "Call Apple Support at 1-888-555-0199 now")])
        let alerts = SafetyRules.alerts(page: digest, frontBundleID: "com.apple.Safari", frontAppName: "Safari",
                                        onCall: false, now: now)
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alert.category, .security)
        XCTAssertEqual(alert.action, .request("close this tab"))
        XCTAssertTrue(alert.headline.contains("fake security alert"))
    }

    func testAnOrdinaryPageWithAPhoneNumberIsQuiet() {
        let digest = page([.init(ref: "e1", kind: "text", text: "Pizza Palace: call 415-555-0100 to order")])
        XCTAssertTrue(SafetyRules.alerts(page: digest, frontBundleID: "com.apple.Safari", frontAppName: "Safari",
                                         onCall: false, now: now).isEmpty)
    }

    func testASignInPageWithAMismatchedLinkIsAWarning() {
        let digest = page([.init(ref: "e1", kind: "password field", text: "Password"),
                           .init(ref: "e2", kind: "link", text: "paypal.com", url: "https://paypa1-secure.xyz/login")])
        let alerts = SafetyRules.alerts(page: digest, frontBundleID: "com.apple.Safari", frontAppName: "Safari",
                                        onCall: false, now: now)
        XCTAssertEqual(alerts.map(\.headline), ["Careful: a link here says paypal.com but goes to paypa1-secure.xyz"])
    }

    func testMismatchedLinksOnOrdinaryPagesOrThroughRedirectorsAreQuiet() {
        let newsletter = page([.init(ref: "e1", kind: "link", text: "nytimes.com", url: "https://evil.example/x")])
        let tracked = page([.init(ref: "e1", kind: "text", text: "Sign in to continue"),
                            .init(ref: "e2", kind: "link", text: "nytimes.com", url: "https://t.co/abc")])
        for digest in [newsletter, tracked] {
            XCTAssertTrue(SafetyRules.alerts(page: digest, frontBundleID: "com.apple.Safari", frontAppName: "Safari",
                                             onCall: false, now: now).isEmpty)
        }
    }

    func testNonBrowserWindowsAndPasswordManagersAreNotScanned() {
        var notes = page([.init(ref: "e1", kind: "text", text: "Your Mac is infected. Call 1-888-555-0199")])
        notes.webArea = false
        XCTAssertTrue(SafetyRules.alerts(page: notes, frontBundleID: "com.apple.Notes", frontAppName: "Notes",
                                         onCall: false, now: now).isEmpty)
        var vault = notes
        vault.withheld = .vault
        XCTAssertTrue(SafetyRules.alerts(page: vault, frontBundleID: "com.apple.Safari", frontAppName: "Safari",
                                         onCall: false, now: now).isEmpty)
    }

    func testRemoteAccessSoftwareDuringACallIsAWarning() {
        let onCall = SafetyRules.alerts(page: nil, frontBundleID: "com.philandro.anydesk", frontAppName: "AnyDesk",
                                        onCall: true, now: now)
        XCTAssertEqual(onCall.map(\.offer), ["Want me to quit AnyDesk?"])
        XCTAssertEqual(onCall.first?.category, .security)
        XCTAssertTrue(SafetyRules.alerts(page: nil, frontBundleID: "com.philandro.anydesk", frontAppName: "AnyDesk",
                                         onCall: false, now: now).isEmpty)
    }

    func testRemoteAccessIsWarnedAgainAnHourLaterAndFoundByNameAlone() {
        let first = SafetyRules.alerts(page: nil, frontBundleID: nil, frontAppName: "TeamViewer QuickSupport",
                                       onCall: true, now: now)
        let later = SafetyRules.alerts(page: nil, frontBundleID: nil, frontAppName: "TeamViewer QuickSupport",
                                       onCall: true, now: now.addingTimeInterval(3_600))
        XCTAssertEqual(first.map(\.offer), ["Want me to quit TeamViewer?"])
        XCTAssertNotEqual(first.first?.key, later.first?.key)
    }

    func testAPhishingPageOnGoogleSitesIsFlaggedButGoogleRedirectsAreNot() {
        let hosted = page([.init(ref: "e1", kind: "text", text: "Verify your account"),
                           .init(ref: "e2", kind: "link", text: "paypal.com", url: "https://sites.google.com/view/paypal-verify")])
        let redirect = page([.init(ref: "e1", kind: "text", text: "Sign in"),
                             .init(ref: "e2", kind: "link", text: "nytimes.com", url: "https://www.google.com/url?q=nytimes.com")])
        XCTAssertEqual(SafetyRules.alerts(page: hosted, frontBundleID: "com.apple.Safari", frontAppName: "Safari",
                                          onCall: false, now: now).count, 1)
        XCTAssertTrue(SafetyRules.alerts(page: redirect, frontBundleID: "com.apple.Safari", frontAppName: "Safari",
                                         onCall: false, now: now).isEmpty)
    }

    func testRegionalOutlookSafeLinksAreNotFlagged() {
        let mail = page([.init(ref: "e1", kind: "text", text: "Sign in"),
                         .init(ref: "e2", kind: "link", text: "nytimes.com",
                               url: "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fnytimes.com")])
        XCTAssertTrue(SafetyRules.alerts(page: mail, frontBundleID: "com.apple.Safari", frontAppName: "Safari",
                                         onCall: false, now: now).isEmpty)
    }

    // MARK: Banners

    func testBannersRankByWatchesAndImportantPeople() {
        let banners = [
            BannerSnapshot(app: "Messages", title: "Dana Smith", body: "Here's the file"),
            BannerSnapshot(app: "Slack", title: "Mom", body: "Call me ASAP"),
            BannerSnapshot(app: "Messages", title: "Mom", body: "Dinner at 7?"),
            BannerSnapshot(app: "Mail", title: "Newsletter", body: "This week"),
            BannerSnapshot(app: "Software Update", title: "Updates available", body: ""),
        ]
        let alerts = BannerRules.alerts(banners, important: ["Mom"], watches: ["dana"], now: now)
        XCTAssertEqual(alerts.map(\.category), [.awaitedReply, .urgentMessage, .message, .message, .other])
        XCTAssertEqual(alerts[0].headline, "Dana Smith replied in Messages")
        XCTAssertEqual(alerts[1].action, .read("Mom says: Call me ASAP"))
        XCTAssertEqual(alerts[1].sender, "Mom")
        XCTAssertNil(alerts[4].offer)
    }

    func testTwoMessagesWithTheSameOpeningAreBothKept() {
        let opening = String(repeating: "Running late, sorry about that, ", count: 3)
        let banners = [BannerSnapshot(app: "Messages", title: "Mom", body: opening + "see you at 6"),
                       BannerSnapshot(app: "Messages", title: "Mom", body: opening + "actually make it 7")]
        let alerts = BannerRules.alerts(banners, important: ["Mom"], watches: [], now: now)
        XCTAssertEqual(Set(alerts.map(\.key)).count, 2)
    }

    func testBannersAreReadFromTheNotificationCenterTree() {
        let root = ScreenNode(role: "AXWindow", children: [
            ScreenNode(role: "AXGroup", subrole: "AXNotificationCenterBanner", description: "Messages, Dana, Here's the file",
                       children: [ScreenNode(role: "AXStaticText", value: "Dana"),
                                  ScreenNode(role: "AXStaticText", value: "Here's the file")]),
            ScreenNode(role: "AXGroup", children: [ScreenNode(role: "AXStaticText", value: "Not a banner")]),
        ])
        XCTAssertEqual(BannerRules.banners(from: root),
                       [BannerSnapshot(app: "Messages", title: "Dana", body: "Here's the file")])
    }
}
