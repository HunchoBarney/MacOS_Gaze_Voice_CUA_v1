import XCTest
@testable import JevVoice

@MainActor
final class SpeechCaptureInterruptionTests: XCTestCase {
    func testDelayedMicrophoneTestInterruptionCannotSuspendReplacementLifecycle() async {
        let capture = RealtimeVoiceLane(apiKey: { "" })
        let oldInterruption = capture.interruptionHandler(session: UUID())
        // End the old input lifecycle, as replacement by a new input does.
        // No hardware or socket is started by this test.
        await capture.suspend()
        let replacementInterruption = capture.interruptionHandler(session: UUID())

        let staleTeardown = expectation(description: "Stale interruption must not publish a paused input")
        staleTeardown.isInverted = true
        capture.onReadiness = { _ in staleTeardown.fulfill() }
        oldInterruption()
        await fulfillment(of: [staleTeardown], timeout: 0.1)

        let currentTeardown = expectation(description: "Current interruption still suspends input")
        capture.onReadiness = { readiness in
            if case .unavailable = readiness { currentTeardown.fulfill() }
        }
        replacementInterruption()
        await fulfillment(of: [currentTeardown], timeout: 1)
        capture.onReadiness = nil
        await capture.suspend()
    }
}
