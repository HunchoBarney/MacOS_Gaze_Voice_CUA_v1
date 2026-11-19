import XCTest
@testable import Jarvis

/// Overlay pick ownership: one pick path at a time, the scorer's
/// conforming ring outlives every pick-set teardown, a pick may only
/// resolve the ask it armed for, and Escape stays consumable while any
/// pick is up — including bare number chips with no parked ask.
@MainActor
final class VoiceTaskCoordinatorOverlayTests: XCTestCase {

    /// In-memory key store — Config's init probes the store; tests never
    /// touch the real Keychain.
    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func coordinator(
        overlay: TargetOverlay,
        config: Config? = nil
    ) -> VoiceTaskCoordinator {
        let suite = "vtc-overlay-\(UUID().uuidString)"
        let config = config ?? Config(
            defaults: UserDefaults(suiteName: suite)!,
            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
            environment: [:])
        return VoiceTaskCoordinator(
            config: config, jevAPIKey: { "" },
            gazeService: GazeService(
                stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: overlay)
    }

    private func candidate(_ id: String,
                           kind: IntentCandidate.Kind = .axElement,
                           label: String = "Save",
                           x: Double = 100, y: Double = 100,
                           w: Double = 40, h: Double = 24,
                           url: String? = nil, windowTitle: String? = nil,
                           appName: String? = nil) -> IntentCandidate {
        let frame = CGRect(x: x, y: y, width: w, height: h)
        return IntentCandidate(id: id, kind: kind, frame: frame,
                               motorRect: frame, role: "AXButton", label: label,
                               url: url, appName: appName,
                               windowTitle: windowTitle)
    }

    /// Spin the main actor until `condition` holds or ~1s elapses —
    /// `park` runs synchronously up to its continuation, so this settles
    /// fast in practice.
    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - disarm must not kill the ring it just acquired

    /// The scorer's `.acquire` presents the ring AND resolves the
    /// ambiguity in the same event — the disarm is chip-scoped, so the
    /// ring survives the tick that armed it.
    func testNonAmbiguousEventDisarmsRadialButKeepsRing() async {
        let overlay = TargetOverlay()
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.acquire(a))
        XCTAssertTrue(overlay.ringArmed)
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertEqual(overlay.pendingCount, 2)
        XCTAssertTrue(c.hasActiveChoiceAsk)
        c.gazeService.eventSink(.acquire(b))
        XCTAssertEqual(overlay.pendingCount, 0)   // chips retracted
        XCTAssertNil(c.pendingOverlayPick)
        XCTAssertNil(c.gazeRadialPair)
        XCTAssertTrue(overlay.ringArmed)          // ring survived
        XCTAssertFalse(c.hasActiveChoiceAsk)
        overlay.hideAll()
    }

    // MARK: - task radials own the pick once armed

    /// A task's `.choice` radial taking `pendingOverlayPick` clears the
    /// gaze pair — the next scorer tick can't disarm the task's radial
    /// out from under its parked ask.
    func testTaskRadialArmClearsGazePairAndSurvivesTicks() async {
        let overlay = TargetOverlay()
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertEqual(c.overlayPickOwner, .gaze)
        XCTAssertNotNil(c.gazeRadialPair)

        let work = VoiceTaskCoordinator.Work(
            label: "pick one", request: "pick", spec: DriveTask(goal: "pick"))
        c.tasks = [work]
        let ask = DriveLoop.Ask.choice(prompt: "which?", options: ["x", "y"])
        let parked = Task { await c.park(ask, on: work) }
        let didPark = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(didPark)
        XCTAssertEqual(overlay.pendingCount, 2)
        XCTAssertEqual(c.overlayPickOwner, .choice)
        XCTAssertNil(c.gazeRadialPair)      // task radial owns the slot

        // A resolved contest must not retract the task's radial.
        c.gazeService.eventSink(.acquire(a))
        XCTAssertEqual(overlay.pendingCount, 2)
        XCTAssertTrue(overlay.ringArmed)
        XCTAssertEqual(c.pendingAskCount, 1)

        // The bound pick still resolves its own ask.
        c.pendingOverlayPick?(1)
        let resolved = await parked.value
        XCTAssertEqual(resolved, "1")
        XCTAssertEqual(overlay.pendingCount, 0)
        overlay.hideAll()
    }

    // MARK: - Escape consumability

    /// Bare number chips are an overlay pick — Escape is consumable
    /// while they're up and retracts them instead of leaking to the
    /// frontmost app.
    func testNumbersArmMakesEscapeConsumable() async {
        let overlay = TargetOverlay()
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let targets = [
            (frame: CGRect(x: 10, y: 10, width: 40, height: 20), label: "Save"),
            (frame: CGRect(x: 100, y: 10, width: 40, height: 20), label: "Open"),
        ]
        _ = await c.handleOverlayVerb(.showNumbers, targets: targets, gaze: nil)
        XCTAssertEqual(overlay.pendingCount, 2)
        XCTAssertEqual(c.overlayPickOwner, .numbers)
        XCTAssertTrue(c.hasActiveChoiceAsk)
        XCTAssertTrue(c.declineTopmostChoiceAsk())
        XCTAssertFalse(c.hasActiveChoiceAsk)
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertNil(c.pendingOverlayPick)
        // Nothing up → Escape falls through.
        XCTAssertFalse(c.declineTopmostChoiceAsk())
    }

    /// The gaze radial declines the same way — Escape retracts the
    /// chips but leaves the ring alone.
    func testEscapeOnGazeRadialKeepsRing() async {
        let overlay = TargetOverlay()
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.acquire(a))
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertTrue(c.declineTopmostChoiceAsk())
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertTrue(overlay.ringArmed)
        overlay.hideAll()
    }

    // MARK: - park re-entrancy

    /// A second park while one is parked declines honestly — the first
    /// continuation can never be orphaned because the row's ask slots
    /// were never overwritten.
    func testSecondParkOnSameWorkDeclines() async {
        let c = coordinator(overlay: TargetOverlay())
        let work = VoiceTaskCoordinator.Work(
            label: "two asks", request: "work", spec: DriveTask(goal: "work"))
        let first = Task { await c.park(.question("first?"), on: work) }
        let didPark = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(didPark)
        let second = await c.park(.question("second?"), on: work)
        XCTAssertNil(second)
        XCTAssertEqual(c.feed.entries.last?.text,
                       "two asks — an ask is already parked; declined the new one.")
        work.askContinuation?.resume(returning: "answer")
        let firstAnswer = await first.value
        XCTAssertEqual(firstAnswer, "answer")
    }

    // MARK: - stale picks bind to their ask

    /// A radial pick armed for ask A declining once the parked ask
    /// moved on — never resolving ask B with A's index.
    func testStaleChoicePickDeclinesInsteadOfResolvingWrongAsk() async {
        let overlay = TargetOverlay()
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let work = VoiceTaskCoordinator.Work(
            label: "choice", request: "choose", spec: DriveTask(goal: "choose"))
        let ask = DriveLoop.Ask.choice(prompt: "first", options: ["a", "b"])
        let parked = Task { await c.park(ask, on: work) }
        let didPark = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(didPark)
        let stalePick = c.pendingOverlayPick
        // Supersession: the row now parks a DIFFERENT ask while the old
        // pick closure is still reachable.
        work.ask = .choice(prompt: "second", options: ["x", "y", "z"])
        stalePick?(0)
        XCTAssertNil(c.pendingOverlayPick)
        XCTAssertEqual(overlay.pendingCount, 0)
        // The continuation belongs to ask B now — the stale pick must
        // not have consumed it.
        XCTAssertNotNil(work.askContinuation)
        work.askContinuation?.resume(returning: "0")
        _ = await parked.value
        overlay.hideAll()
    }

    // MARK: - respond_to_task ordinals

    func testParkedSelectionParsesPositions() {
        XCTAssertEqual(VoiceTaskCoordinator.parkedSelection(in: "the first one", count: 3),
                       .index(0))
        XCTAssertEqual(VoiceTaskCoordinator.parkedSelection(in: "second", count: 3),
                       .index(1))
        XCTAssertEqual(VoiceTaskCoordinator.parkedSelection(in: "the last one", count: 3),
                       .index(2))
        XCTAssertEqual(VoiceTaskCoordinator.parkedSelection(in: "newest", count: 3),
                       .index(2))
        XCTAssertEqual(VoiceTaskCoordinator.parkedSelection(in: "task 2", count: 3),
                       .index(1))
        XCTAssertEqual(VoiceTaskCoordinator.parkedSelection(in: "ninth", count: 3),
                       .outOfRange)
        XCTAssertEqual(VoiceTaskCoordinator.parkedSelection(in: "the safari one", count: 3),
                       .unparseable)
    }

    /// "the first one" means the OLDEST parked ask — the previous
    /// newest-fallback answered the wrong task.
    func testRespondToTaskFirstOrdinalAnswersOldest() async {
        let c = coordinator(overlay: TargetOverlay())
        let older = VoiceTaskCoordinator.Work(
            label: "older", request: "old task", spec: DriveTask(goal: "old"))
        let newer = VoiceTaskCoordinator.Work(
            label: "newer", request: "new task", spec: DriveTask(goal: "new"))
        older.ask = .question("older asks")
        newer.ask = .question("newer asks")
        let olderParked = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                older.askContinuation = cont
            }
        }
        let newerParked = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                newer.askContinuation = cont
            }
        }
        let didPark = await waitFor {
            older.askContinuation != nil && newer.askContinuation != nil
        }
        XCTAssertTrue(didPark)
        c.tasks = [older, newer]
        let reply = await c.respondToTask("yes", task: "the first one")
        XCTAssertNotNil(reply)
        // Oldest resolves; the newer ask stays parked.
        let olderAnswer = await olderParked.value
        XCTAssertEqual(olderAnswer, "yes")
        XCTAssertNotNil(newer.askContinuation)
        newer.askContinuation?.resume(returning: "cleanup")
        _ = await newerParked.value
    }

    /// An out-of-range ordinal refuses honestly instead of guessing.
    func testRespondToTaskOutOfRangeOrdinalRefuses() async {
        let c = coordinator(overlay: TargetOverlay())
        let work = VoiceTaskCoordinator.Work(
            label: "only one", request: "only", spec: DriveTask(goal: "only"))
        work.ask = .question("one ask")
        let parked = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                work.askContinuation = cont
            }
        }
        let didPark = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(didPark)
        c.tasks = [work]
        let reply = await c.respondToTask("yes", task: "the third one")
        XCTAssertNotNil(reply)
        XCTAssertTrue(reply?.contains("refused") ?? false)
        XCTAssertNotNil(work.askContinuation)   // still parked
        work.askContinuation?.resume(returning: "cleanup")
        _ = await parked.value
    }

    // MARK: - cancel verdict is real

    /// "cancel that" routes to the real cancel path — the newest active
    /// work settles cancelled and no Work row is created for the stop
    /// request itself.
    func testCancelUtteranceInterruptsNewestWork() async {
        let c = coordinator(overlay: TargetOverlay())
        let work = VoiceTaskCoordinator.Work(
            label: "running", request: "do the thing", spec: DriveTask(goal: "x"))
        c.tasks = [work]
        let reply = await c.beginVoiceTask("cancel that")
        XCTAssertTrue(reply.contains("cancelled"))
        XCTAssertEqual(work.outcome, .cancelled)
        XCTAssertFalse(work.active)
        XCTAssertEqual(c.tasks.count, 1)   // no row for "cancel that"
    }

    /// Nothing running → the honest nothing_running, still no Work row.
    func testCancelWithNothingRunning() async {
        let c = coordinator(overlay: TargetOverlay())
        let reply = await c.beginVoiceTask("stop")
        XCTAssertTrue(reply.contains("nothing_running"))
        XCTAssertTrue(c.tasks.isEmpty)
    }

    /// The cancel verb's remainder names the target — "stop scout"
    /// carries "scout" as the hint, "cancel that" carries nothing.
    func testCancelHintExtraction() {
        XCTAssertEqual(VoiceTaskCoordinator.cancelHint(from: "stop scout"), "scout")
        XCTAssertNil(VoiceTaskCoordinator.cancelHint(from: "cancel that"))
        XCTAssertNil(VoiceTaskCoordinator.cancelHint(from: "never mind"))
        XCTAssertEqual(VoiceTaskCoordinator.cancelHint(from: "cancel the download"),
                       "download")
    }

    // MARK: - dwell suppression seams

    /// A live capture suppresses dwell even with nothing parked —
    /// "click this" mid-sentence can't double-actuate.
    func testDwellSuppressionIncludesActiveCapture() {
        let c = coordinator(overlay: TargetOverlay())
        c.captureActiveProbe = { true }
        XCTAssertTrue(c.gazeService.dwellSuppressed())
        c.captureActiveProbe = { false }
        XCTAssertFalse(c.gazeService.dwellSuppressed())
    }

    /// Service stop() tears ALL overlay state down — ring included —
    /// plus every pick claim, so nothing survives into the next start.
    func testOverlayTeardownClearsEverything() async {
        let overlay = TargetOverlay()
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.acquire(a))
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertTrue(overlay.ringArmed)
        XCTAssertEqual(overlay.pendingCount, 2)
        c.gazeService.overlayTeardown?()
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertFalse(overlay.ringArmed)
        XCTAssertNil(c.pendingOverlayPick)
        XCTAssertNil(c.gazeRadialPair)
        XCTAssertEqual(c.overlayPickOwner, .none)
    }

    // MARK: - pending ask badge

    func testPendingAskCountTracksAsksAndGazeRadial() async {
        let overlay = TargetOverlay()
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        XCTAssertEqual(c.pendingAskCount, 0)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertEqual(c.pendingAskCount, 1)
        c.gazeService.eventSink(.acquire(a))
        XCTAssertEqual(c.pendingAskCount, 0)
        let work = VoiceTaskCoordinator.Work(
            label: "asking", request: "ask", spec: DriveTask(goal: "ask"))
        work.ask = .confirm("ok?")
        let parked = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                work.approvalContinuation = cont
            }
        }
        let didPark = await waitFor { work.approvalContinuation != nil }
        XCTAssertTrue(didPark)
        c.tasks = [work]
        XCTAssertEqual(c.pendingAskCount, 1)
        work.approvalContinuation?.resume(returning: false)
        _ = await parked.value
        overlay.hideAll()
    }

    // MARK: - agent cursor toggle

    /// "Show agent cursor" off gates the MOVING cursor surface only —
    /// no cursor-state calls, no label chips, no gaze targets — while
    /// the shelf (agents-presence) keeps updating.
    func testAgentCursorToggleSuppressesCursorSurface() async {
        final class Spy: AgentBridging {
            func roster() async -> [CompanionAgent] {
                [CompanionAgent(slug: "scout", name: "Scout", role: "watch",
                                description: "", workspacePath: "", codexHomePath: "")]
            }
            func delegate(_ request: DelegationRequest) async throws -> String { "{}" }
            func sendToAgent(slug: String, message: String) async throws -> String { "{}" }
            func agentMemory(slug: String) async throws -> String { "{}" }
            func interruptAgent(hint: String?) async -> String { "{}" }
        }
        let suite = "vtc-overlay-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "agentCursorEnabled")
        let config = Config(defaults: defaults, keyStore: MemoryKeys(),
                            openAIKeyStore: MemoryKeys(), environment: [:])
        let c = coordinator(overlay: TargetOverlay(), config: config)
        XCTAssertFalse(config.agentCursorEnabled)
        let spy = Spy()
        c.agentBridge = spy
        var labels: [(String, NSPoint?)] = []
        c.cursorLabelSink = { slug, point in labels.append((slug, point)) }
        await c.pollAgentCursors()
        // The roster answered, but nothing cursor-side ran.
        XCTAssertTrue(labels.isEmpty)
        XCTAssertTrue(c.lastChipPoints.isEmpty)
        // The shelf still carries the agent — presence ≠ cursor.
        XCTAssertEqual(AgentShelfOverlay.shared.entries.map(\.slug), ["scout"])
        XCTAssertEqual(AgentShelfOverlay.shared.entries.first?.state, .idle)
        AgentShelfOverlay.shared.hide()
    }

    // MARK: - actuation gates

    /// A pick on a protected-phrase candidate refuses the same way the
    /// dwell engine's deny list refuses — explicit pick ≠ deny bypass.
    func testDeniedCandidateRefusesActuation() async {
        let c = coordinator(overlay: TargetOverlay())
        let denied = candidate("d", kind: .dom, label: "Empty trash")
        let deniedResult = await c.actuateCommitted(denied)
        XCTAssertFalse(deniedResult)
        let single = candidate("d2", kind: .dom, label: "Delete")
        let singleResult = await c.actuateCommitted(single)
        XCTAssertFalse(singleResult)
        XCTAssertTrue(c.feed.entries.contains {
            $0.kind == .consent && $0.text.contains("protected list") })
    }

    /// A click arriving mid-paste drops rather than queueing — the
    /// shared input lease is held by dictation, so the actuation is
    /// refused instead of landing late.
    func testActuationDropsWhileInputLeaseHeld() async {
        let c = coordinator(overlay: TargetOverlay())
        let lease = DictationDelivery.sharedLease
        await lease.acquire()
        let benign = candidate("ok", kind: .dom, label: "Save")
        let result = await c.actuateCommitted(benign)
        await lease.release()
        XCTAssertFalse(result)
        XCTAssertTrue(c.feed.entries.contains { $0.text.contains("input was busy") })
    }

    /// A radial pick skips the dwell engine's upstream corpus scan, so
    /// the commit gate reads the candidate's full context — a benign
    /// "OK" inside a money-movement context refuses, same as the spoken
    /// gaze verb's corpus check.
    func testRadialPickScansWindowAndURLContext() async {
        let c = coordinator(overlay: TargetOverlay())
        let confirmDialog = candidate("ok", kind: .axElement, label: "OK",
                                      windowTitle: "Confirm Purchase")
        let dialogResult = await c.actuateCommitted(confirmDialog)
        XCTAssertFalse(dialogResult)
        let wirePage = candidate("ok2", kind: .axElement, label: "OK",
                                 url: "https://bank.example/wire-transfer")
        let wireResult = await c.actuateCommitted(wirePage)
        XCTAssertFalse(wireResult)
        XCTAssertTrue(c.feed.entries.contains {
            $0.kind == .consent && $0.text.contains("protected list") })
    }

    /// The gate helper reads both lists: CuaPolicy's protected phrases
    /// and dwell's own deny tokens.
    func testDeniedReasonReadsBothLists() {
        XCTAssertNotNil(VoiceTaskCoordinator.deniedReason(in: "Empty trash"))
        XCTAssertNotNil(VoiceTaskCoordinator.deniedReason(in: "Transfer money"))
        XCTAssertNotNil(VoiceTaskCoordinator.deniedReason(in: "Delete"))
        XCTAssertNotNil(VoiceTaskCoordinator.deniedReason(in: "Sign-out"))
        XCTAssertNil(VoiceTaskCoordinator.deniedReason(in: "Save"))
        XCTAssertNil(VoiceTaskCoordinator.deniedReason(in: ""))
        XCTAssertNil(VoiceTaskCoordinator.deniedReason(in: nil))
    }
}
