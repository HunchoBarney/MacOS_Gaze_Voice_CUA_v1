import XCTest
@testable import JevVoiceCore

final class DictationDraftTests: XCTestCase {
    func testRevisesOnlyOwnedTextAndPreservesSurroundingContent() throws {
        var draft = try DictationDraft(document: "Before  after", insertion: 7)
        XCTAssertEqual(try draft.replacementRange(in: "Before  after", caret: 7), NSRange(location: 7, length: 0))
        draft.accept("red book")
        XCTAssertEqual(draft.document, "Before red book after")
        XCTAssertEqual(try draft.replacementRange(in: draft.document, caret: 15), NSRange(location: 7, length: 8))
        draft.accept("blue notebook")
        XCTAssertEqual(draft.document, "Before blue notebook after")
        draft.accept("")
        XCTAssertEqual(draft.document, "Before  after")
    }

    func testExternalEditOrCaretMovementStopsRevision() throws {
        var draft = try DictationDraft(document: "User text", insertion: 9)
        draft.accept(" hello")
        XCTAssertThrowsError(try draft.replacementRange(in: "User text edited hello", caret: 15))
        XCTAssertThrowsError(try draft.replacementRange(in: draft.document, caret: 0))
    }

    func testUnicodeOffsetsAndInvalidInsertion() throws {
        var draft = try DictationDraft(document: "🐱 end", insertion: 2)
        draft.accept(" café 🪁")
        XCTAssertEqual(draft.document, "🐱 café 🪁 end")
        XCTAssertEqual(try draft.replacementRange(in: draft.document, caret: 10), NSRange(location: 2, length: 8))
        XCTAssertThrowsError(try DictationDraft(document: "🐱", insertion: 1))
        XCTAssertThrowsError(try DictationDraft(document: "", insertion: 1))
    }
}
