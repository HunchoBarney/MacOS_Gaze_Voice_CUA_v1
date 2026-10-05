import XCTest
@testable import JevVoice

final class RealtimeClientTests: XCTestCase {

    /// The realtime API caps conversation item ids at 32 chars — a longer
    /// id once got the whole session killed with a validation error.
    func testContextItemIDStaysInsideTheServerCap() {
        for _ in 0..<100 {
            let id = RealtimeVoiceClient.contextItemID()
            XCTAssertTrue(id.hasPrefix("ctx-"))
            XCTAssertLessThanOrEqual(id.count, 32, "item.id must fit the API cap: \(id)")
        }
    }

    /// A rejected request on a live socket (empty-buffer commit, stale
    /// response.cancel, deleting a gone item) is a warning, not a session
    /// failure — the turn keeps streaming.
    func testRequestLevelErrorsDecodeAsWarnings() {
        for frame in [
            #"{"type":"error","error":{"type":"invalid_request_error","message":"Error committing input audio buffer: buffer is empty."}}"#,
            #"{"type":"invalid_request_error","error":{"type":"invalid_request_error","message":"response.cancel failed: no active response"}}"#,
            #"{"type":"error","error":{"type":"invalid_request_error","code":"item_not_found","message":"Item does not exist."}}"#
        ] {
            let events = RealtimeVoiceClient.decode(frame)
            XCTAssertEqual(events.count, 1, frame)
            guard case .warning = events[0] else {
                XCTFail("request-level error must decode as .warning: \(frame)")
                return
            }
        }
    }

    /// Session-scoped errors still decode fatal so the lane can surface
    /// them instead of reconnect-looping.
    func testSessionErrorsDecodeAsFailures() {
        let events = RealtimeVoiceClient.decode(
            #"{"type":"error","error":{"type":"session_error","message":"Your session expired."}}"#)
        XCTAssertEqual(events.count, 1)
        guard case .failure = events[0] else {
            XCTFail("session errors must decode as .failure")
            return
        }
    }

    /// response.done must emit function calls BEFORE responseDone — the
    /// lane populates pendingCalls first, then decides the turn ended.
    func testResponseDoneEmitsFunctionCallsBeforeDone() {
        let events = RealtimeVoiceClient.decode(#"{"type":"response.done","response":{"status":"completed","output":[{"type":"function_call","call_id":"call_1","name":"computer_command","arguments":"{\"instruction\":\"open Notes\"}"}]}}"#)
        XCTAssertEqual(events.count, 2)
        guard case .functionCall(let callID, let name, _) = events[0] else {
            XCTFail("expected functionCall first, got \(events)")
            return
        }
        XCTAssertEqual(callID, "call_1")
        XCTAssertEqual(name, "computer_command")
        guard case .responseDone = events[1] else {
            XCTFail("expected responseDone last, got \(events)")
            return
        }
    }

    /// A failed/incomplete response still ends with responseDone so the
    /// response gate frees — but surfaces the reason first.
    func testFailedResponseDoneSurfacesReasonThenDone() {
        let events = RealtimeVoiceClient.decode(#"{"type":"response.done","response":{"status":"failed","status_details":{"error":{"message":"model blew up"}},"output":[]}}"#)
        XCTAssertEqual(events.count, 2)
        guard case .failure = events[0], case .responseDone = events[1] else {
            XCTFail("expected failure then responseDone, got \(events)")
            return
        }
    }

    /// A cancelled response (our own barge-in) must not surface as a
    /// failure — only the gate-freeing done.
    func testCancelledResponseDoneStaysSilent() {
        let events = RealtimeVoiceClient.decode(#"{"type":"response.done","response":{"status":"cancelled","output":[]}}"#)
        XCTAssertEqual(events.count, 1)
        guard case .responseDone = events[0] else {
            XCTFail("expected lone responseDone, got \(events)")
            return
        }
    }
}
