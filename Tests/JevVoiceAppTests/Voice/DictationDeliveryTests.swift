import AppKit
import XCTest
@testable import JevVoice

private final class CallLog: @unchecked Sendable {
    var values: [String] = []
}

final class DictationDeliveryTests: XCTestCase {
    func testAXInsertionSkipsPasteFallback() async throws {
        let calls = CallLog()
        let delivery = DictationDelivery(
            insertText: { calls.values.append("ax:" + $0); return true },
            pasteText: { calls.values.append("paste:" + $0); return true })
        try await delivery.deliver("hello")
        XCTAssertEqual(calls.values, ["ax:hello"])
    }

    func testPasteFallbackWhenAXRefuses() async throws {
        let calls = CallLog()
        let delivery = DictationDelivery(
            insertText: { _ in false },
            pasteText: { calls.values.append($0); return true })
        try await delivery.deliver("draft text")
        XCTAssertEqual(calls.values, ["draft text"])
    }

    func testFailureWhenNothingAcceptsTheText() async {
        let delivery = DictationDelivery(insertText: { _ in false }, pasteText: { _ in false })
        do {
            try await delivery.deliver("x")
            XCTFail("Delivery must fail when no editable target exists")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("editable"))
        }
    }

    func testEmptyTextDeliversNothing() async throws {
        let calls = CallLog()
        let delivery = DictationDelivery(
            insertText: { _ in calls.values.append("ax"); return true },
            pasteText: { _ in calls.values.append("paste"); return true })
        try await delivery.deliver("")
        XCTAssertTrue(calls.values.isEmpty)
    }

    func testClipboardSnapshotAndRestorePreservesEveryItemAndType() {
        let board = NSPasteboard(name: NSPasteboard.Name("dictation-test-\(UUID().uuidString)"))
        board.clearContents()
        let customType = NSPasteboard.PasteboardType("public.data")
        let item = NSPasteboardItem()
        item.setString("the user's earlier copy", forType: .string)
        item.setData(Data([1, 2, 3]), forType: customType)
        XCTAssertTrue(board.writeObjects([item]))
        let snapshot = DictationDelivery.snapshot(of: board)
        board.clearContents()
        board.setString("dictated payload", forType: .string)
        DictationDelivery.restore(snapshot, to: board)
        XCTAssertEqual(board.string(forType: .string), "the user's earlier copy")
        XCTAssertEqual(board.data(forType: customType), Data([1, 2, 3]))
    }

    func testEmptyClipboardRestoresToEmpty() {
        let board = NSPasteboard(name: NSPasteboard.Name("dictation-test-\(UUID().uuidString)"))
        board.clearContents()
        let snapshot = DictationDelivery.snapshot(of: board)
        board.setString("dictated", forType: .string)
        DictationDelivery.restore(snapshot, to: board)
        XCTAssertNil(board.string(forType: .string))
    }
}
