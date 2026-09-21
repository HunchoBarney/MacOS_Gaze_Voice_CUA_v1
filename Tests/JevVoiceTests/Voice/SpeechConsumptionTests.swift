import XCTest
@testable import JevVoiceCore

final class SpeechConsumptionTests: XCTestCase {
    func testReleaseCannotRepeatCommittedRequestButIntentionalRepeatSurvives() throws {
        var ledger = SpeechConsumption()
        try ledger.update("open Notes")
        let first = try ledger.commit(wordCount: 2)
        try ledger.update("open Notes")
        XCTAssertTrue(ledger.pending.isEmpty)
        try ledger.update("open Notes open Notes")
        let second = try ledger.commit(wordCount: 2)
        XCTAssertEqual(first.text, second.text)
        XCTAssertNotEqual(first.id, second.id)
    }
    func testPendingRevisionDoesNotRewriteConsumedAction() throws {
        var ledger = SpeechConsumption()
        try ledger.update("open Notes and search for cap")
        _ = try ledger.commit(wordCount: 2)
        try ledger.update("Open Notes, and search for cats")
        XCTAssertEqual(ledger.pending, "and search for cats")
        XCTAssertThrowsError(try ledger.update("open Messages and search for cats"))
        XCTAssertEqual(ledger.pending, "and search for cats")
    }
    func testInvalidBoundariesAndUnicode() throws {
        var ledger = SpeechConsumption()
        try ledger.update("type café 👩🏽‍💻")
        XCTAssertThrowsError(try ledger.commit(wordCount: 0))
        XCTAssertThrowsError(try ledger.commit(wordCount: 4))
        XCTAssertEqual(try ledger.commit(wordCount: 3).text, "type café 👩🏽‍💻")
    }
    func testSubmittedSpanPreservesParagraphsAndInternalSpacing() throws {
        var ledger = SpeechConsumption()
        try ledger.update("open Notes then dictate blue\n\nnotebook  on desk")
        _ = try ledger.commit(wordCount: 2)
        XCTAssertEqual(ledger.pending, "then dictate blue\n\nnotebook  on desk")
        let submitted = try ledger.commit(wordCount: 6)
        XCTAssertEqual(submitted.text, "then dictate blue\n\nnotebook  on desk")
    }

}
