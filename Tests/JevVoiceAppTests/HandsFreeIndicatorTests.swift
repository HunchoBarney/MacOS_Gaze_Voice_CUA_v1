import AppKit
import XCTest
@testable import JevVoice

@MainActor
final class HandsFreeIndicatorTests: XCTestCase {
    func testListeningRequiresReadyConversationAndMicrophone() {
        XCTAssertEqual(state(.off, ready: false), .notReady)
        XCTAssertEqual(state(.off, ready: true), .notReady)
        XCTAssertEqual(state(.preparing, ready: true), .starting)
        XCTAssertEqual(state(.listening, ready: false, processing: true), .notReady)
        XCTAssertEqual(state(.listening, ready: true), .listening)
        XCTAssertEqual(state(.listening, ready: true, processing: true), .processing)
    }

    func testOffAndObscuredHideWhilePauseAndFailureWinOverWork() {
        XCTAssertNil(state(.listening, enabled: false, ready: true, processing: true))
        XCTAssertNil(state(.listening, ready: true, processing: true, obscured: true))
        XCTAssertEqual(state(.listening, paused: true, ready: true, processing: true), .paused)
        XCTAssertEqual(state(.paused, ready: true, processing: true), .paused)
        XCTAssertEqual(state(.unavailable("fixture"), ready: true, processing: true), .unavailable)
    }

    func testStatesUseDifferentReadableTitlesAndNativeSymbols() {
        let states = HandsFreeIndicator.State.allCases
        XCTAssertEqual(Set(states.map(\.title)).count, states.count)
        XCTAssertEqual(Set(states.map(\.symbol)).count, states.count)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for state in states {
            XCTAssertNotNil(NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil))
            let titleWidth = (state.title as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(ceil(titleWidth) + 43, HandsFreeIndicator.size.width)
        }
    }

    func testActionableCardCanReportListeningOrUnavailableWithoutADuplicateBadge() {
        for (status, ask): (VoiceController.Status, Bool) in [
            (.error("Finish setup"), false), (.awaitingConfirm, false),
            (.reviewTranscript, false), (.awaitingAnswer("Choose a field"), true), (.idle, true)
        ] {
            let show = VoiceWindows.showsPanel(status: status, automatic: true, hasAsk: ask, linger: false, microphoneTest: false)
            XCTAssertTrue(show)
            for (lane, mic, title): (ConversationListeningState, Bool, String) in [
                (.listening, true, "Listening"), (.listening, false, "Not ready"),
                (.paused, true, "Paused"), (.unavailable("fixture"), true, "Unavailable")
            ] {
                XCTAssertNil(state(lane, ready: mic, obscured: show))
                XCTAssertEqual(state(lane, ready: mic)?.title, title)
            }
        }
        let show = VoiceWindows.showsPanel(status: .thinking, automatic: true, hasAsk: false, linger: false, microphoneTest: false)
        XCTAssertFalse(show)
        XCTAssertEqual(state(.listening, ready: true, processing: true, obscured: show), .processing)
    }

    func testFrameRemainsInsideDockAdjustedScreenAtAnyOrigin() {
        let screen = CGRect(x: -1440, y: -200, width: 1390, height: 860)
        let frame = HandsFreeIndicator.frame(in: screen)
        XCTAssertEqual(frame, CGRect(x: -176, y: -188, width: 114, height: 26))
        XCTAssertTrue(frame.map { screen.contains($0) } ?? false)
        XCTAssertNil(HandsFreeIndicator.frame(in: CGRect(x: 0, y: 0, width: 120, height: 100)))
        XCTAssertNil(HandsFreeIndicator.frame(in: CGRect(x: 0, y: 0, width: 200, height: 40)))
    }

    private func state(_ conversation: ConversationListeningState, enabled: Bool = true, paused: Bool = false,
                       ready: Bool = false, processing: Bool = false, obscured: Bool = false) -> HandsFreeIndicator.State? {
        .resolve(conversation, enabled: enabled, userPaused: paused, microphoneReady: ready,
            processing: processing, obscured: obscured)
    }
}
