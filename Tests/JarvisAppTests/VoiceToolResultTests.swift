import XCTest
@testable import Jarvis

/// Contract: VoiceToolResult is the wire shape between tool handlers and
/// the realtime lane — hand-rolled JSON must round-trip exactly and the
/// spoken sanitizer must hold its invariants.
final class VoiceToolResultTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let original = VoiceToolResult(kind: VoiceToolResult.Kind.taskOutcome,
                                       status: VoiceToolResult.Status.ok,
                                       say: "Done.", detail: "clicked Save",
                                       options: ["a", "b"])
        let decoded = VoiceToolResult(jsonString: original.encoded())
        XCTAssertEqual(decoded?.kind, "task_outcome")
        XCTAssertEqual(decoded?.status, "ok")
        XCTAssertEqual(decoded?.say, "Done.")
        XCTAssertEqual(decoded?.detail, "clicked Save")
        XCTAssertEqual(decoded?.options, ["a", "b"])
    }

    /// The payload is user-derived text — quotes, newlines, backslashes
    /// and control characters must survive the hand-rolled encoder.
    func testEncodingEscapesHostileText() {
        let nasty = "say \"hi\"\nline2\\end\u{0007}"
        let encoded = VoiceToolResult(status: "ok", say: nasty).encoded()
        let parsed = VoiceToolResult(jsonString: encoded)
        XCTAssertEqual(parsed?.say, nasty)
        // And it must be real JSON — a JSONSerialization consumer agrees.
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(encoded.utf8)))
    }

    func testOptionalsOmittedWhenAbsent() {
        let encoded = VoiceToolResult(status: "cancelled", say: "x.").encoded()
        XCTAssertFalse(encoded.contains("\"kind\""))
        XCTAssertFalse(encoded.contains("\"detail\""))
        XCTAssertFalse(encoded.contains("\"options\""))
    }

    func testDecodeRejectsMissingStatusOrSay() {
        XCTAssertNil(VoiceToolResult(jsonString: "{\"say\":\"x\"}"))
        XCTAssertNil(VoiceToolResult(jsonString: "{\"status\":\"ok\"}"))
        XCTAssertNil(VoiceToolResult(jsonString: "not json"))
    }

    // MARK: spoken()

    func testSpokenBoundsWords() {
        let long = (1...60).map { "word\($0)" }.joined(separator: " ")
        let out = VoiceToolResult.spoken(long, words: 30)
        XCTAssertEqual(out.split(separator: " ").count, 30)
    }

    func testSpokenStripsVoiceHostileCharacters() {
        let out = VoiceToolResult.spoken("See [notes] — (draft) \"quoted\" `code`; done", words: 50)
        XCTAssertFalse(out.contains("["), out)
        XCTAssertFalse(out.contains("\""), out)
        XCTAssertFalse(out.contains("`"), out)
        XCTAssertFalse(out.contains(";"), out)
    }

    func testSpokenAlwaysEndsTerminated() {
        XCTAssertTrue(VoiceToolResult.spoken("hi", words: 5).hasSuffix("."))
        XCTAssertTrue(VoiceToolResult.spoken("hi?", words: 5).hasSuffix("?"))
    }

    func testSpokenEmptyStaysEmpty() {
        XCTAssertEqual(VoiceToolResult.spoken("   ", words: 5), "")
    }

    func testStatusConstantsMatchLaneContract() {
        // The lane suppresses a second response on the literal "started"
        // status — the constant must stay that string.
        XCTAssertEqual(VoiceToolResult.Status.started, "started")
        XCTAssertEqual(VoiceToolResult.Kind.taskOutcome, "task_outcome")
        XCTAssertEqual(VoiceToolResult.Kind.taskQuestion, "task_question")
    }
}
