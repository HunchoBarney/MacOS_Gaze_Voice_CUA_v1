import AppKit
import AVFoundation
import XCTest
@testable import JevVoice

/// The onboarding checklist is probe-driven: rows flip on refresh, the
/// card hides when all clear or dismissed, and fix buttons run their
/// injected actions then re-poll. Probes are stubbed — no TCC, no tracker.
@MainActor
final class UXOnboardingTests: XCTestCase {
    func testQuietHandsFreePanelOnlyAppearsForActionableWork() {
        for status: VoiceController.Status in [.idle, .thinking, .executing, .replied, .done, .stopped] {
            XCTAssertFalse(VoiceWindows.showsPanel(status: status, automatic: true, hasAsk: false,
                linger: true, microphoneTest: false))
        }
        for status: VoiceController.Status in [.error("Action needed"), .awaitingAnswer("Which?"), .awaitingConfirm, .reviewTranscript] {
            XCTAssertTrue(VoiceWindows.showsPanel(status: status, automatic: true, hasAsk: false,
                linger: false, microphoneTest: false))
        }
        XCTAssertTrue(VoiceWindows.showsPanel(status: .idle, automatic: true, hasAsk: true, linger: false, microphoneTest: false))
        XCTAssertFalse(VoiceWindows.showsPanel(status: .idle, automatic: true, hasAsk: true, linger: false, microphoneTest: true))
        for status: VoiceController.Status in [.starting, .listening, .finishing, .executing, .replied] {
            XCTAssertTrue(VoiceWindows.showsPanel(status: status, automatic: false, hasAsk: false,
                linger: false, microphoneTest: false))
        }
    }

    func testQuietPresentationOrdersOnlyAtVisibilityBoundaries() {
        var visible = false
        let steps = [false, false, true, true, false, false, false]
        let orders = steps.map { ask in
            let show = VoiceWindows.showsPanel(status: .idle, automatic: true, hasAsk: ask, linger: true, microphoneTest: false)
            let order = VoiceWindows.panelOrder(show: show, visible: visible)
            visible = show
            return order
        }
        XCTAssertEqual(orders, [.unchanged, .unchanged, .front, .unchanged, .out, .unchanged, .unchanged])
        XCTAssertFalse(visible)
    }

    func testVoiceMenuUsesActualStateAndRejectsUnsafeResume() {
        func menu(_ state: ConversationListeningState, enabled: Bool = true, userPaused: Bool = true,
                  available: Bool = true, permitted: Bool = true) -> HandsFreeMenuState {
            HandsFreeMenuState(state: state, enabled: enabled, label: "Listening hands-free", userPaused: userPaused,
                controlsAvailable: available, canResume: permitted, stoppable: true, pending: 2)
        }
        XCTAssertEqual(menu(.listening).accessibilityValue, "Listening hands-free, 2 pending")
        XCTAssertEqual(menu(.listening).toggle, .pause); XCTAssertTrue(menu(.listening).stoppable)
        XCTAssertEqual(menu(.preparing).toggle, .pause)
        XCTAssertEqual(menu(.paused).toggle, .resume)
        XCTAssertNil(menu(.paused, available: false).toggle)
        XCTAssertNil(menu(.paused, userPaused: false).toggle)
        XCTAssertNil(menu(.paused, permitted: false).toggle)
        XCTAssertNil(menu(.unavailable("fixture")).toggle)
        XCTAssertNil(menu(.off).toggle)
        XCTAssertEqual(menu(.listening, enabled: false).accessibilityValue, "Hands-free off, 2 pending")
        XCTAssertNil(menu(.listening, enabled: false).toggle)
        let symbols = [menu(.off), menu(.preparing), menu(.paused), menu(.listening), menu(.unavailable("fixture"))].map(\.symbol)
        XCTAssertEqual(Set(symbols).count, 5)
        for symbol in symbols { XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil)) }
    }

    private func model(defaults: UserDefaults = UserDefaults(suiteName: "ux-onboarding-\(UUID().uuidString)")!) -> OnboardingChecklistModel {
        let m = OnboardingChecklistModel(defaults: defaults)
        m.microphoneGranted = { false }
        m.accessibilityGranted = { false }
        m.screenRecordingGranted = { false }
        m.trackerEnabled = { false }
        m.trackerRunning = { false }
        m.cameraAuthorization = { .notDetermined }
        m.voiceKeyConfigured = { false }
        m.enableTracker = { XCTFail("Unexpected tracker enable") }
        return m
    }

    func testAllPendingShowsCard() async {
        let m = model()
        await m.refresh()
        XCTAssertTrue(m.visible)
        XCTAssertFalse(m.allClear)
        XCTAssertEqual(m.rows.count, OnboardingChecklistModel.RowID.allCases.count)
        XCTAssertTrue(m.rows.allSatisfy { !$0.done })
        // First unfinished row is microphone → its prompt.
        XCTAssertEqual(m.pendingTryIt, m.rows.first?.tryIt)
        XCTAssertNotNil(m.pendingTryIt)
    }

    func testNonGazeRowsClearIndependentlyOfOptionalGaze() async {
        let m = model()
        m.microphoneGranted = { true }
        m.accessibilityGranted = { true }
        m.screenRecordingGranted = { true }
        m.trackerEnabled = { true }
        m.trackerRunning = { true }
        m.cameraAuthorization = { .authorized }
        m.voiceKeyConfigured = { true }
        await m.refresh()

        XCTAssertFalse(m.allClear)
        XCTAssertTrue(m.visible)
        XCTAssertEqual(m.rows.filter { !$0.done }.map(\.id), [.tracker])
        XCTAssertNil(m.pendingTryIt)
    }

    func testCameraRemediesFollowPermissionNotLiveness() async throws {
        let m = model()
        m.trackerEnabled = { true }
        m.trackerRunning = { true }
        for (status, guidance): (AVAuthorizationStatus, String) in [
            (.denied, "System Settings → Privacy & Security → Camera"),
            (.restricted, "restricted"),
            (.notDetermined, "Camera under Permissions"),
            (.authorized, "Gaze hasn’t been verified")
        ] {
            m.cameraAuthorization = { status }
            await m.refresh()
            let row = try XCTUnwrap(m.rows.first { $0.id == .tracker })
            XCTAssertTrue(row.detail.contains(guidance))
            XCTAssertEqual(row.detail.contains("denied"), status == .denied)
            XCTAssertFalse(row.done)
            XCTAssertNil(row.fixLabel)
            XCTAssertNil(row.tryIt)
        }
    }

    func testWakeAndRegrantCannotVerifyGaze() async throws {
        let m = model()
        m.trackerEnabled = { true }
        for (camera, running): (AVAuthorizationStatus, Bool) in [
            (.authorized, true), (.authorized, false), (.authorized, true),
            (.denied, true), (.authorized, true)
        ] {
            m.cameraAuthorization = { camera }
            m.trackerRunning = { running }
            await m.refresh()
            let row = try XCTUnwrap(m.rows.first { $0.id == .tracker })
            XCTAssertFalse(row.done)
            XCTAssertEqual(row.detail.contains("tracker responded"), running && camera == .authorized)
            XCTAssertTrue(m.visible)
        }
    }

    func testEnableRequiresExplicitActionAndCurrentPermission() async throws {
        let m = model()
        var enabled = false
        m.trackerEnabled = { enabled }
        m.enableTracker = { enabled = true }
        m.cameraAuthorization = { .authorized }
        await m.refresh()
        XCTAssertEqual(m.rows.first { $0.id == .tracker }?.fixLabel, "Enable")
        XCTAssertFalse(enabled)
        m.cameraAuthorization = { .denied }
        m.fix(.tracker)
        XCTAssertFalse(enabled)
        m.cameraAuthorization = { .authorized }
        m.fix(.tracker)
        XCTAssertTrue(enabled)
        await m.refresh()
        let row = try XCTUnwrap(m.rows.first { $0.id == .tracker })
        XCTAssertNil(row.fixLabel)
        XCTAssertFalse(row.done)
    }

    /// A fix runs the injected action then refreshes — the row flips only
    /// because the probe now reports granted (honest repaint, no optimism).
    func testFixRunsActionAndRepaints() async {
        let m = model()
        var granted = false
        var afterFixCalled = false
        m.microphoneGranted = { granted }
        m.requestMicrophone = { granted = true }
        m.afterFix = { afterFixCalled = true }

        m.fix(.microphone)
        // fix() hops through a Task — give it a turn to run the request,
        // the afterFix callback, and the refresh.
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(afterFixCalled)
        await m.refresh()
        XCTAssertEqual(m.rows.first { $0.id == .microphone }?.done, true)
    }

    /// "Set up later" persists — a fresh model over the same defaults
    /// stays hidden even with rows undone.
    func testDismissalPersists() async {
        let suite = "ux-onboarding-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = model(defaults: defaults)
        await first.refresh()
        XCTAssertTrue(first.visible)
        first.dismissed = true
        first.trackerRunning = { true }
        await first.refresh()
        XCTAssertFalse(first.visible)

        let second = model(defaults: defaults)
        XCTAssertTrue(second.dismissed)
        await second.refresh()
        XCTAssertFalse(second.visible)
        XCTAssertTrue(defaults.bool(forKey: OnboardingChecklistModel.dismissedKey))
    }

    func testVoiceSetupRequiresAKeyInsteadOfLocalModels() async {
        let m = model()
        m.voiceKeyConfigured = { false }
        await m.refresh()
        let row = m.rows.first { $0.id == .voiceService }
        XCTAssertEqual(row?.title, "OpenAI API key")
        XCTAssertEqual(row?.done, false)
        XCTAssertNil(row?.fixLabel)
        m.voiceKeyConfigured = { true }
        await m.refresh()
        XCTAssertEqual(m.rows.first { $0.id == .voiceService }?.done, true)
    }
}
