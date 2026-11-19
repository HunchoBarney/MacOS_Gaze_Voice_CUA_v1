import XCTest
@testable import Jarvis

/// The onboarding checklist is probe-driven: rows flip on refresh, the
/// card hides when all clear or dismissed, and fix buttons run their
/// injected actions then re-poll. Probes are stubbed — no TCC, no tracker.
@MainActor
final class UXOnboardingTests: XCTestCase {

    private func model() -> OnboardingChecklistModel {
        let suite = "ux-onboarding-\(UUID().uuidString)"
        return OnboardingChecklistModel(defaults: UserDefaults(suiteName: suite)!)
    }

    /// Everything pending → the card shows, rows are undone, and the
    /// try-it line tracks the FIRST unfinished row.
    func testAllPendingShowsCard() async {
        let m = model()
        // Stub every probe off — the real TCC/tracker state of the host
        // must not flip rows in a unit test.
        m.microphoneGranted = { false }
        m.accessibilityGranted = { false }
        m.screenRecordingGranted = { false }
        m.trackerEnabled = { false }
        m.trackerRunning = { false }
        m.voiceKeyConfigured = { false }
        await m.refresh()
        XCTAssertTrue(m.visible)
        XCTAssertFalse(m.allClear)
        XCTAssertEqual(m.rows.count, OnboardingChecklistModel.RowID.allCases.count)
        XCTAssertTrue(m.rows.allSatisfy { !$0.done })
        // First unfinished row is microphone → its prompt.
        XCTAssertEqual(m.pendingTryIt, m.rows.first?.tryIt)
        XCTAssertNotNil(m.pendingTryIt)
    }

    /// Grants flip their rows on the next refresh; all-clear retires the
    /// card without any dismissal.
    func testRowsFlipAndAllClearHides() async {
        let m = model()
        m.microphoneGranted = { true }
        m.accessibilityGranted = { true }
        m.screenRecordingGranted = { true }
        m.trackerEnabled = { true }
        m.trackerRunning = { true }
        m.voiceKeyConfigured = { true }
        await m.refresh()

        XCTAssertTrue(m.allClear)
        XCTAssertFalse(m.visible)
        XCTAssertTrue(m.rows.allSatisfy(\.done))
        XCTAssertNil(m.pendingTryIt)
    }

    /// The tracker row needs BOTH the config toggle and a live host — an
    /// enabled-but-stopped tracker still reads undone.
    func testTrackerRowNeedsRunning() async {
        let m = model()
        m.trackerEnabled = { true }
        m.trackerRunning = { false }
        await m.refresh()
        let row = m.rows.first { $0.id == .tracker }
        XCTAssertEqual(row?.done, false)

        m.trackerRunning = { true }
        await m.refresh()
        XCTAssertEqual(m.rows.first { $0.id == .tracker }?.done, true)
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
        let first = OnboardingChecklistModel(defaults: defaults)
        await first.refresh()
        XCTAssertTrue(first.visible)
        first.dismissed = true
        XCTAssertFalse(first.visible)

        let second = OnboardingChecklistModel(defaults: defaults)
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
