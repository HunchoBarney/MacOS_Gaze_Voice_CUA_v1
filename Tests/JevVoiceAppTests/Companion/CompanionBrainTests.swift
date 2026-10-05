import XCTest
@testable import JevVoice

/// The companion fast path's contract: canned/clock replies for
/// whole-utterance exchanges only — work requests, pending-ask replies and
/// verdict words must always fall through to the model turn.
final class CompanionBrainTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    /// 2026-09-28 15:04 UTC — a Monday.
    private let now = Date(timeIntervalSince1970: 1_790_607_840)

    private func reply(_ text: String, askPending: Bool = false) -> String? {
        CompanionBrain.instantReply(for: text, askPending: askPending,
                                    now: now, calendar: calendar)
    }

    func testCannedExchangesReply() {
        XCTAssertEqual(reply("hello"), "Hi.")
        XCTAssertEqual(reply("Thank you!"), "You're welcome.")
        XCTAssertEqual(reply("who are you"), "I'm Jev, the voice layer on this Mac.")
        XCTAssertEqual(reply("can you hear me"), "I hear you.")
        XCTAssertEqual(reply("good night"), "Good night.")
    }

    func testFillersAndPunctuationNormalizeAway() {
        XCTAssertEqual(reply("Hey Jarvis, thanks"), "You're welcome.")
        XCTAssertEqual(reply("please, what time is it?"), "It's 3:04 PM.")
        XCTAssertEqual(reply("what's the time"), "It's 3:04 PM.")
    }

    func testClockAndDateReadTheInjectedClock() {
        XCTAssertEqual(reply("what time is it"), "It's 3:04 PM.")
        XCTAssertEqual(reply("what day is it"), "It's Monday, September 28.")
        XCTAssertEqual(reply("what's today's date"), "It's Monday, September 28.")
    }

    /// While any ask is parked — task consent, dialogue question or
    /// agent-gate consent — the fast path must consume nothing.
    func testAskPendingConsumesNothing() {
        for probe in ["yes", "no", "what time is it", "hello", "thanks",
                      "the second window", "open notes"] {
            XCTAssertNil(CompanionBrain.instantReply(for: probe, askPending: true,
                                                     now: now, calendar: calendar),
                         "\(probe) must reach the pending ask")
        }
    }

    /// Anything that could be work, a cancel, or a parked-ask answer falls
    /// through — the fast path never acts or swallows instead of routing.
    func testRequestsAndControlFallThrough() {
        for probe in ["open notes", "open the clock app", "tell me the time then open notes",
                      "set a timer", "stop", "cancel that", "never mind",
                      "what time is it in london", "remind me the time",
                      "what time does the meeting start", "close the window",
                      "type hello", "play some music"] {
            XCTAssertNil(reply(probe), "\(probe) is not a canned exchange")
        }
    }

    /// Verdict words can answer the model's own spoken questions, which
    /// askPending never sees — they are never canned.
    func testVerdictWordsAreNeverCanned() {
        for probe in ["yes", "yeah", "no", "nope", "ok", "okay", "sure", "go ahead"] {
            XCTAssertNil(reply(probe), "\(probe) may be answering a live question")
        }
    }

    func testEmptyAndFillerOnlyUtterancesFallThrough() {
        for probe in ["", "   ", "jarvis", "hey jev", "please", "..."] {
            XCTAssertNil(reply(probe))
        }
    }
}
