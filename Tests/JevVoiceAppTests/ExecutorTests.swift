import AppKit
import XCTest
@testable import JevVoice

final class ExecutorTests: XCTestCase {
    @MainActor
    func testConsecutiveDictationsRestoreOriginalClipboardBeforeReturning() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var pasted: [String] = []
        for text in ["first private phrase", "second private phrase"] {
            _ = try await Executor.dictate(text, pasteboard: board) {
                pasted.append(board.string(forType: .string) ?? "")
            }
            XCTAssertEqual(board.string(forType: .string), "original")
        }
        XCTAssertEqual(pasted, ["first private phrase", "second private phrase"])
    }

    @MainActor
    func testExternalCopyDuringPasteIsPreserved() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        _ = try await Executor.dictate("private", pasteboard: board) {
            board.clearContents()
            board.setString("user copy", forType: .string)
        }
        _ = try await Executor.dictate("next", pasteboard: board, sendPaste: {})
        XCTAssertEqual(board.string(forType: .string), "user copy")
    }

    @MainActor
    func testPasteFailureRestoresEveryClipboardRepresentation() async throws {
        struct PasteFailure: Error {}
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        let custom = NSPasteboard.PasteboardType("test.jev.original")
        item.setData(Data([0, 1, 255]), forType: custom)
        board.writeObjects([item])
        do {
            _ = try await Executor.dictate("private", pasteboard: board) { throw PasteFailure() }
            XCTFail("Paste error should propagate")
        } catch is PasteFailure {}
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: custom), Data([0, 1, 255]))
    }

    @MainActor
    func testConcurrentPasteIsRejectedAndCancellationRestoresClipboard() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let began = expectation(description: "first paste began")
        let first = Task { @MainActor in
            try await Executor.dictate("private", pasteboard: board) { began.fulfill() }
        }
        await fulfillment(of: [began], timeout: 2)
        do {
            _ = try await Executor.dictate("overlap", pasteboard: board, sendPaste: {})
            XCTFail("Overlapping paste must not replace the in-flight payload")
        } catch is ExecutorError {}
        first.cancel()
        _ = try? await first.value
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    @MainActor
    func testInitiallyEmptyClipboardIsRestored() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        _ = try await Executor.dictate("private", pasteboard: board, sendPaste: {})
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor
    func testCancellationDoesNotRestoreClipboardBeforeQueuedPasteReadsIt() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original private clipboard", forType: .string)
        let sent = expectation(description: "paste shortcut sent")
        let consumed = expectation(description: "target consumed queued paste")
        var received: String?
        let task = Task { @MainActor in
            try await Executor.dictate("intended text", pasteboard: board) {
                Task { @MainActor in
                    try await Task.sleep(nanoseconds: 20_000_000)
                    received = board.string(forType: .string)
                    consumed.fulfill()
                }
                sent.fulfill()
            }
        }
        await fulfillment(of: [sent], timeout: 2)
        task.cancel()
        await fulfillment(of: [consumed], timeout: 2)
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate after paste cleanup")
        } catch is CancellationError {}
        XCTAssertEqual(received, "intended text")
        XCTAssertEqual(board.string(forType: .string), "original private clipboard")
    }

    func testLockRequestsMacOSLockShortcutInsteadOfDisplaySleep() throws {
        var calls: [(String, [String])] = []
        let result = try Executor.runSystem(.lockScreen, percent: nil) { path, arguments in
            calls.append((path, arguments))
            return ""
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "/usr/bin/osascript")
        XCTAssertEqual(calls.first?.1, ["-e", "tell application \"System Events\" to key code 12 using {control down, command down}"])
        XCTAssertEqual(result, "Lock screen requested")
    }

    func testLockFailureIsNotReportedAsSuccess() {
        struct Denied: Error {}
        XCTAssertThrowsError(try Executor.runSystem(.lockScreen, percent: nil) { _, _ in throw Denied() })
    }

    func testSleepRemainsSeparateFromLock() throws {
        var arguments: [String] = []
        let result = try Executor.runSystem(.sleep, percent: nil) { path, args in
            XCTAssertEqual(path, "/usr/bin/pmset")
            arguments = args
            return ""
        }
        XCTAssertEqual(arguments, ["sleepnow"])
        XCTAssertEqual(result, "Sleeping")
    }
}
