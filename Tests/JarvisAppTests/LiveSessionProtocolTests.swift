import XCTest
@testable import Jarvis

final class LiveSessionProtocolTests: XCTestCase {
    private let allowed: Set<String> = ["sdp", "instructions", "input", "voice", "idle_timeout_s", "vad_threshold"]

    func testBrokerBodyCarriesOnlyTheFieldsTheBrokerAllows() {
        let body = LiveSessionConfig(instructions: "Be brief.").brokerBody(sdp: "v=0")
        XCTAssertEqual(Set(body.keys), ["sdp", "instructions", "voice", "idle_timeout_s"])
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["delegation"])
        XCTAssertEqual(body["sdp"] as? String, "v=0")
        XCTAssertEqual(body["instructions"] as? String, "Be brief.")
        XCTAssertEqual(body["voice"] as? String, "marin")
        XCTAssertEqual(body["idle_timeout_s"] as? Int, 8)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testSeededInputAndVadThresholdUseTheBrokersShape() throws {
        var config = LiveSessionConfig(instructions: "")
        config.input = [.init(role: .developer, text: "Your 3 pm starts soon."),
                        .init(role: .assistant, text: "Want the Zoom link?")]
        config.vadThreshold = 0.7
        let body = config.brokerBody(sdp: "v=0")
        XCTAssertTrue(Set(body.keys).isSubset(of: allowed), "unexpected: \(Set(body.keys).subtracting(allowed))")
        XCTAssertEqual(body["vad_threshold"] as? Double, 0.7)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["role"] as? String }, ["developer", "assistant"])
        let parts = input.map { ($0["content"] as? [[String: Any]])?.first }
        XCTAssertEqual(parts.map { $0?["type"] as? String }, ["input_text", "output_text"])
        XCTAssertEqual(parts.map { $0?["text"] as? String }, ["Your 3 pm starts soon.", "Want the Zoom link?"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testEachAppendHasItsOwnEventID() {
        let a = LiveAppend(kind: .thinking, content: "", delegationID: nil)
        let b = LiveAppend(kind: .thinking, content: "", delegationID: nil)
        XCTAssertNotEqual(a.eventID, b.eventID)
    }

    func testCloseReasonsDecodeAndKeepUnknownOnes() {
        XCTAssertEqual(LiveCloseReason("close_requested"), .closeRequested)
        XCTAssertEqual(LiveCloseReason("expired"), .expired)
        XCTAssertEqual(LiveCloseReason("content"), .content)
        XCTAssertEqual(LiveCloseReason("remote_hangup"), .remoteHangup)
        XCTAssertEqual(LiveCloseReason("connection_lost"), .connectionLost)
        XCTAssertEqual(LiveCloseReason("brand_new"), .other("brand_new"))
    }
}
