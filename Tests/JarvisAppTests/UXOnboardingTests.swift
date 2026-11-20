import XCTest
@testable import Jarvis

/// The first run: microphone, Accessibility, then a try-it step. Grants
/// move the user on by themselves; refusals offer a way out. Probes are
/// stubbed — no TCC.
@MainActor
final class UXOnboardingTests: XCTestCase {

    private func model(engine: Bool = false) -> FirstRunModel {
        let m = FirstRunModel(policy: ListeningPolicy(wakeWordAvailable: engine))
        m.microphoneGrant = { .notAsked }
        m.accessibilityGranted = { false }
        m.requestMicrophone = {}
        m.requestAccessibility = {}
        m.openSystemSettings = { _ in }
        return m
    }

    /// Three numbered steps; the orange-dot screen stays hidden until a
    /// wake-word engine exists.
    func testThreeStepsWithoutWakeWordEngine() {
        let m = model()
        XCTAssertEqual(m.steps, [.microphone, .accessibility, .tryIt])
        XCTAssertEqual(m.step, .microphone)
        XCTAssertEqual(m.position?.number, 1)
        XCTAssertEqual(m.position?.of, 3)
    }

    func testStandbyIntroLeadsOnlyWithEngine() {
        let m = model(engine: true)
        XCTAssertEqual(m.steps, [.standbyIntro, .microphone, .accessibility, .tryIt])
        XCTAssertEqual(m.step, .standbyIntro)
        XCTAssertNil(m.position, "the intro isn't a numbered step")
        m.allow()
        XCTAssertEqual(m.step, .microphone)
        XCTAssertEqual(m.position?.number, 1)
    }

    /// A grant that lands while the page is up moves the user on.
    func testMicrophoneGrantAdvances() async {
        let m = model()
        var granted = false
        m.microphoneGrant = { granted ? .granted : .notAsked }
        m.requestMicrophone = { granted = true }
        m.allow()
        XCTAssertEqual(m.microphone, .waiting)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(m.step, .accessibility)
        XCTAssertEqual(m.microphone, .granted)
    }

    /// A refused microphone stays on the page and the button opens System
    /// Settings instead of asking again.
    func testRefusedMicrophoneOpensSystemSettings() {
        let m = model()
        var opened: [Permission] = []
        m.microphoneGrant = { .refused }
        m.openSystemSettings = { opened.append($0) }
        m.refresh()
        XCTAssertEqual(m.microphone, .refused)
        XCTAssertEqual(m.step, .microphone)
        m.allow()
        XCTAssertEqual(opened, [.microphone])
        XCTAssertEqual(m.step, .microphone)
    }

    /// Accessibility waits after the request, then moves on when the
    /// switch is turned on in System Settings — nothing to press.
    func testAccessibilityWaitsThenAdvancesOnItsOwn() async {
        let m = model()
        m.microphoneGrant = { .granted }
        m.refresh()
        XCTAssertEqual(m.step, .accessibility)
        m.allow()
        XCTAssertEqual(m.accessibility, .waiting)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(m.step, .accessibility, "still waiting until the switch is on")
        m.accessibilityGranted = { true }
        m.refresh()
        XCTAssertEqual(m.step, .tryIt)
    }

    /// Opening Calculator during the try-it step counts; other apps and
    /// other steps don't.
    func testTryItWatchesForCalculator() {
        let m = model()
        m.applicationLaunched(bundleID: "com.apple.calculator")
        XCTAssertFalse(m.triedIt, "too early")
        m.microphoneGrant = { .granted }
        m.accessibilityGranted = { true }
        m.refresh()
        m.refresh()
        XCTAssertEqual(m.step, .tryIt)
        m.applicationLaunched(bundleID: "com.apple.Safari")
        XCTAssertFalse(m.triedIt)
        m.applicationLaunched(bundleID: "com.apple.calculator")
        XCTAssertTrue(m.triedIt)
    }

    /// "Not now" skips a permission without granting it.
    func testNotNowSkipsAhead() {
        let m = model()
        m.advance()
        XCTAssertEqual(m.step, .accessibility)
        m.advance()
        XCTAssertEqual(m.step, .tryIt)
        m.advance()
        XCTAssertEqual(m.step, .tryIt, "the last step stays put")
    }
}
