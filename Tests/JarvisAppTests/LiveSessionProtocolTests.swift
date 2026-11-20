import XCTest
@testable import Jarvis

final class LiveSessionProtocolTests: XCTestCase {
    func testBrokerBodyCarriesOnlyTheFieldsTheBrokerAllows() {
        let body = LiveSessionConfig(instructions: "Be brief.").brokerBody(sdp: "v=0")
        let allowed: Set<String> = ["sdp", "instructions", "input", "voice", "idle_timeout_s", "vad_threshold"]
        XCTAssertTrue(Set(body.keys).isSubset(of: allowed), "unexpected: \(Set(body.keys).subtracting(allowed))")
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["delegation"])
        XCTAssertEqual(body["sdp"] as? String, "v=0")
        XCTAssertEqual(body["instructions"] as? String, "Be brief.")
        XCTAssertEqual(body["voice"] as? String, "marin")
        XCTAssertEqual(body["idle_timeout_s"] as? Int, 8)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
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
