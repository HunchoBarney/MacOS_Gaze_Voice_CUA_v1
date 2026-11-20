import XCTest
@testable import Jarvis

/// The first run: how Jarvis listens, microphone, Accessibility, then a
/// try-it step. Grants
/// move the user on by themselves; refusals offer a way out. Probes are
/// stubbed — no TCC.
@MainActor
final class UXOnboardingTests: XCTestCase {

    /// A first run with its probes stubbed. Unless `choosing`, it starts
    /// past the listening choice, on the microphone step.
    private func model(engine: Bool = false, choosing: Bool = false) -> FirstRunModel {
        let m = FirstRunModel(policy: ListeningPolicy(wakeWordAvailable: engine))
        m.microphoneGrant = { .notAsked }
        m.accessibilityGranted = { false }
        m.requestMicrophone = {}
        m.requestAccessibility = {}
        m.openSystemSettings = { _ in }
        if !choosing { m.advance() }
        return m
    }

    /// Four numbered steps; the orange-dot screen stays hidden until a
    /// wake-word engine exists.
    func testFourStepsWithoutWakeWordEngine() {
        let m = model(choosing: true)
        XCTAssertEqual(m.steps, [.listening, .microphone, .accessibility, .tryIt])
        XCTAssertEqual(m.step, .listening)
        XCTAssertEqual(m.position?.number, 1)
        XCTAssertEqual(m.position?.of, 4)
    }

    /// The listening choice comes first and recommends Hold fn; Hands-free
    /// is the only other choice until the wake word ships.
    func testListeningChoiceRecommendsHoldFn() {
        let m = model(choosing: true)
        XCTAssertEqual(m.policy.offeredModes, [.pushToTalk, .conversation])
        XCTAssertEqual(m.policy.defaultMode, .pushToTalk)
        XCTAssertEqual(ListeningMode.pushToTalk.title, "Hold fn to talk")
        XCTAssertEqual(ListeningMode.conversation.title, "Hands-free")
        m.allow()
        XCTAssertEqual(m.step, .microphone)
        XCTAssertEqual(m.position?.number, 2)
    }

    /// Once the wake word ships, it is offered first and preselected.
    func testWakeWordBecomesTheRecommendedChoice() {
        let m = model(engine: true, choosing: true)
        XCTAssertEqual(m.policy.offeredModes, [.standby, .pushToTalk, .conversation])
        XCTAssertEqual(m.policy.defaultMode, .standby)
    }

    func testStandbyIntroFollowsTheChoiceOnlyWithEngine() {
        let m = model(engine: true)
        XCTAssertEqual(m.steps, [.listening, .standbyIntro, .microphone, .accessibility, .tryIt])
        XCTAssertEqual(m.step, .standbyIntro)
        XCTAssertNil(m.position, "the intro isn't a numbered step")
        m.allow()
        XCTAssertEqual(m.step, .microphone)
        XCTAssertEqual(m.position?.number, 2)
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
