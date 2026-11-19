import XCTest
@testable import Jarvis

/// Contract: agent replies embed `<ROUTINE>` payloads the app parses and
/// every marker tag is stripped from what the user sees or hears.
final class AgentMarkersTests: XCTestCase {
    func testRoutineMarkerParses() {
        let text = """
            Sure — I'll check hourly. <ROUTINE>{"action":"create","every_minutes":60,"task":"check mail"}</ROUTINE> Anything else?
            """
        let markers = AgentMarkers.routines(in: text)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].action, "create")
        XCTAssertEqual(markers[0].everyMinutes, 60)
        XCTAssertEqual(markers[0].task, "check mail")
    }

    /// Camel-case keys decode too — the model is not reliable about
    /// spelling conventions.
    func testRoutineMarkerAcceptsCamelCase() {
        let text = "<ROUTINE>{\"everyMinutes\":30,\"task\":\"ping\",\"routineId\":\"r1\"}</ROUTINE>"
        let markers = AgentMarkers.routines(in: text)
        XCTAssertEqual(markers.first?.everyMinutes, 30)
        XCTAssertEqual(markers.first?.routineID, "r1")
    }

    func testMalformedMarkerPayloadSkipped() {
        let text = "a <ROUTINE>{broken</ROUTINE> b"
        XCTAssertTrue(AgentMarkers.routines(in: text).isEmpty)
    }

    func testStrippingRemovesMarkerAndKeepsProse() {
        let text = "Before <ROUTINE>{\"task\":\"x\"}</ROUTINE> after."
        XCTAssertEqual(AgentMarkers.strippingMarkers(text).trimmingCharacters(in: .whitespaces),
                       "Before  after.")
    }

    /// A stream cut mid-marker strips the dangling tag through end —
    /// partial payloads never leak into what the user hears.
    func testDanglingMarkerStrippedToEnd() {
        let text = "visible <ROUTINE>{\"task\":\"x"
        XCTAssertEqual(AgentMarkers.strippingMarkers(text).trimmingCharacters(in: .whitespaces),
                       "visible")
    }

    /// No COMPUTER_USE_REQUEST handling remains — the tag is inert: not
    /// parsed, and not stripped from what the user sees.
    func testComputerUseRequestIsInert() {
        let text = "I need <COMPUTER_USE_REQUEST>click ok</COMPUTER_USE_REQUEST>"
        XCTAssertTrue(AgentMarkers.routines(in: text).isEmpty)
        XCTAssertTrue(AgentMarkers.strippingMarkers(text).contains("COMPUTER_USE_REQUEST"))
    }
}
