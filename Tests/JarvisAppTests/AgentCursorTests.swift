import XCTest
@testable import Jarvis
import JarvisCore

/// The driver draws each agent session's cursor; `agentCursorPoint` turns
/// `get_agent_cursor_state` into the AppKit point the name chip anchors to.
final class AgentCursorTests: XCTestCase {

    private func state(enabled: Bool, position: [String: JSONValue]?) -> JSONValue {
        var inner: [String: JSONValue] = ["enabled": .bool(enabled)]
        if let position { inner["position"] = .object(position) }
        return .object(["structuredContent": .object(inner)])
    }

    func testPositionedCursorYieldsFlippedPoint() {
        let payload = state(enabled: true, position: ["x": .number(400), "y": .number(300)])
        let point = VoiceTaskCoordinator.agentCursorPoint(from: payload, primaryHeight: 1000)
        XCTAssertEqual(point, NSPoint(x: 400, y: 700))
    }

    func testFlatPayloadWithoutWrapperAlsoParses() {
        let payload = JSONValue.object([
            "enabled": .bool(true),
            "position": .object(["x": .number(10), "y": .number(20)]),
        ])
        let point = VoiceTaskCoordinator.agentCursorPoint(from: payload, primaryHeight: 100)
        XCTAssertEqual(point, NSPoint(x: 10, y: 80))
    }

    func testDisabledCursorYieldsNil() {
        let payload = state(enabled: false, position: ["x": .number(400), "y": .number(300)])
        XCTAssertNil(VoiceTaskCoordinator.agentCursorPoint(from: payload, primaryHeight: 1000))
    }

    func testAbsentPositionYieldsNil() {
        XCTAssertNil(VoiceTaskCoordinator.agentCursorPoint(
            from: state(enabled: true, position: nil), primaryHeight: 1000))
    }

    func testMalformedPositionYieldsNil() {
        let payload = state(enabled: true, position: ["x": .string("left"), "y": .number(3)])
        XCTAssertNil(VoiceTaskCoordinator.agentCursorPoint(from: payload, primaryHeight: 1000))
    }

    /// `hashValue` is process-randomized — the palette must derive from the
    /// slug itself so an agent's color survives relaunch.
    func testPaletteIsDeterministic() {
        XCTAssertEqual(AgentCursor.palette(for: "inbox-desk"),
                       AgentCursor.palette(for: "inbox-desk"))
        XCTAssertEqual(AgentCursor.palette(for: "scout"),
                       AgentCursor.palette(for: "scout"))
        XCTAssertEqual(AgentCursor.palette(for: nil), "#14b8a6")
    }

    /// Edge inputs — empty, huge, non-ASCII — index the palette without
    /// trapping (the old `abs(Int.min)` hazard is gone with unsigned math).
    func testPaletteHandlesEdgeSlugs() {
        for slug in ["", "a", String(repeating: "é", count: 2000), "🎉", "-"] {
            let color = AgentCursor.palette(for: slug)
            XCTAssertTrue(color.hasPrefix("#"), "slug \(slug) must still pick a palette color")
        }
    }
}
