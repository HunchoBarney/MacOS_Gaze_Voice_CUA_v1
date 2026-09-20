import XCTest
@testable import JevVoiceCore

final class RangedTranscriptTests: XCTestCase {
    func testRevisionReplacesOnlyOverlappingVolatileText() throws {
        var text = RangedTranscript()
        try text.apply(.init(start: 0, end: 1, text: "Open Notes.", isFinal: true))
        try text.apply(.init(start: 1, end: 2, text: " Create a boat", isFinal: false))
        try text.apply(.init(start: 1, end: 3, text: " Create a note.", isFinal: true))
        XCTAssertEqual(text.text, "Open Notes. Create a note.")
        XCTAssertEqual(text.segments.count, 2)
    }
    func testRepeatedIntentIsPreservedAndDuplicateEventIsIgnored() throws {
        var text = RangedTranscript()
        let first = SpeechRevision(start: 0, end: 1, text: "Scroll down", isFinal: true)
        XCTAssertTrue(try text.apply(first))
        XCTAssertFalse(try text.apply(first))
        try text.apply(.init(start: 1, end: 2, text: " Scroll down", isFinal: true))
        XCTAssertEqual(text.text, "Scroll down Scroll down")
        XCTAssertEqual(text.revision, 2)
    }
    func testInvalidAndFinalizedRangesAreRejectedWithoutMutation() throws {
        var text = RangedTranscript()
        try text.apply(.init(start: 0, end: 2, text: "Keep this", isFinal: true))
        XCTAssertThrowsError(try text.apply(.init(start: 1, end: 3, text: "Replace", isFinal: false)))
        XCTAssertThrowsError(try text.apply(.init(start: .nan, end: 3, text: "Bad", isFinal: true)))
        XCTAssertEqual(text.text, "Keep this")
    }
    func testRecognizerSpacingAndParagraphsArePreserved() throws {
        var text = RangedTranscript()
        try text.apply(.init(start: 0, end: 1, text: "今日は", isFinal: true))
        try text.apply(.init(start: 1, end: 2, text: "晴れです。\n\n", isFinal: true))
        try text.apply(.init(start: 2, end: 3, text: "次の段落", isFinal: true))
        XCTAssertEqual(text.text, "今日は晴れです。\n\n次の段落")
    }

}
