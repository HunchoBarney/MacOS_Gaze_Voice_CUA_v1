import XCTest
@testable import JevVoice

/// Overlay pick ownership: one pick path at a time, the scorer's
/// conforming ring outlives every pick-set teardown, a pick may only
/// resolve the ask it armed for, and Escape stays consumable while any
/// pick is up.
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
        config.sounds = false
        let report = VoiceTaskCoordinator.accuracyReportURL
        VoiceTaskCoordinator.accuracyReportURL = nil
        addTeardownBlock { @MainActor in VoiceTaskCoordinator.accuracyReportURL = report }
        return VoiceTaskCoordinator(
            config: config, jevAPIKey: { "" },
            gazeService: GazeService(
                stream: GazeStream(frames: { AsyncThrowingStream { _ in } }),
                defaults: UserDefaults(suiteName: suite)!),
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

    // MARK: - passive gaze never opens a choice

    func testTieReleasesRingWithoutArmingChoiceThenNextControlHighlights() async {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.acquire(a))
        XCTAssertTrue(overlay.ringArmed)
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertFalse(overlay.ringArmed)
        XCTAssertFalse(c.hasActiveChoiceAsk)
        c.gazeService.eventSink(.acquire(b))
        XCTAssertEqual(overlay.pendingCount, 0)   // chips retracted
        XCTAssertNil(c.pendingOverlayPick)
        XCTAssertTrue(overlay.ringArmed)          // ring survived
        XCTAssertFalse(c.hasActiveChoiceAsk)
        overlay.hideAll()
    }

    // MARK: - task radials own the pick once armed

    func testTaskRadialSurvivesPassiveAmbiguityAndAcquisition() async {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertNil(c.pendingOverlayPick)
        XCTAssertEqual(overlay.pendingCount, 0)

        let work = VoiceTaskCoordinator.Work(
            label: "pick one", request: "pick", spec: DriveTask(goal: "pick"))
        c.tasks = [work]
        let ask = DriveLoop.Ask.choice(prompt: "which?", options: ["x", "y"])
        let parked = Task { await c.park(ask, on: work) }
        let didPark = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(didPark)
        XCTAssertEqual(overlay.pendingCount, 2)
        XCTAssertNotNil(c.pendingOverlayPick)
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertEqual(overlay.pendingCount, 2)

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

    func testRetiredTargetCommandsCreateNoWorkOrPanels() async {
        let overlay = TargetOverlay(presentsPanels: false)
        let c = coordinator(overlay: overlay)
        for (phrase, final) in [("show numbers", "show numbers"), ("show numbers everywhere", "show numbers everywhere"),
                                ("hide numbers", "hide numbers"), ("click two", "click two"), ("open Numbers", "show numbers")] {
            let result = await c.beginVoiceTask(phrase, transcriptHint: final)
            XCTAssertTrue(result.contains("Please name the control"), phrase)
            XCTAssertTrue(c.tasks.isEmpty)
            XCTAssertNil(c.pendingOverlayPick)
            XCTAssertFalse(c.hasActiveChoiceAsk)
            XCTAssertFalse(c.declineTopmostChoiceAsk())
            XCTAssertEqual(overlay.pendingCount, 0)
        }
    }

    func testRetiredPicksNeedExactAskAndNumericLabelsWin() async {
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
        for (reply, expected) in [("Report 2", "0"), ("click two", "1")] {
            let work = VoiceTaskCoordinator.Work(label: "fixture", request: "fixture", spec: DriveTask(goal: "fixture"))
            work.ask = .choice(prompt: "Which report?", options: ["Report 2", "Annual report"])
            c.tasks = [work]
            let answer = Task {
                await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                    work.askContinuation = continuation
                }
            }
            let armed = await waitFor { work.askContinuation != nil }
            XCTAssertTrue(armed)
            _ = await c.respondToTask("click two")
            XCTAssertNotNil(work.askContinuation)
            for invalid in ["click two in Safari", "pick 3"] {
                _ = await c.respondToTaskExact(invalid, taskID: work.id, askID: work.askID, captureID: UUID())
                XCTAssertNotNil(work.askContinuation)
            }
            let another = VoiceTaskCoordinator.Work(label: "other", request: "", spec: DriveTask(goal: "other"))
            another.ask = .choice(prompt: "Other?", options: ["a", "b"])
            another.agentAskID = "fixture"
            c.tasks.append(another)
            _ = await c.respondToTaskExact("click two", taskID: work.id, askID: work.askID, captureID: UUID())
            XCTAssertNotNil(work.askContinuation)
            c.tasks.removeAll { $0.id == another.id }
            _ = await c.respondToTaskExact(reply, taskID: work.id, askID: work.askID, captureID: UUID())
            work.askContinuation?.resume(returning: nil)
            let selected = await answer.value
            XCTAssertEqual(selected, expected)
        }
    }

    func testPassiveTieDoesNotCaptureEscape() async {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.acquire(a))
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertFalse(c.declineTopmostChoiceAsk())
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertFalse(overlay.ringArmed)
        overlay.hideAll()
    }

    func testBareClickFreeformResumesOnlyTheAddressedQuestionWithOriginalWords() async {
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
        let work = VoiceTaskCoordinator.Work(label: "fixture", request: "fixture", spec: .init(goal: "fixture"))
        c.tasks = [work]
        let answer = Task { await c.park(.question("Which word?"), on: work) }
        let armed = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(armed)
        _ = await c.respondToTask("Click.")
        _ = await c.respondToTaskExact("Click.", taskID: work.id, askID: UUID(), captureID: UUID())
        _ = await c.respondToTaskExact("Click two.", taskID: work.id, askID: work.askID, captureID: UUID())
        XCTAssertNotNil(work.askContinuation)
        _ = await c.respondToTaskExact("Click.", taskID: work.id, askID: work.askID, captureID: UUID())
        work.askContinuation?.resume(returning: nil)
        let literal = await answer.value
        XCTAssertEqual(literal, "Click.")
    }

    func testDesktopSwitchQuestionLeavesOriginalChoiceAndDeadlineIntact() async {
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
        let ask = DriveLoop.Ask.choice(prompt: "Which option?", options: ["Did it switch?", "Other"])
        for choose in [false, true] {
            let work = VoiceTaskCoordinator.Work(label: "fixture", request: "fixture", spec: .init(goal: "fixture"))
            c.tasks = [work]
            c.askExpirySeconds = choose ? 2 : 0.15
            var prompts = 0
            c.taskEventSink = { _, _, _ in prompts += 1 }
            let answer = Task { await c.park(ask, on: work) }
            let armed = await waitFor { work.askContinuation != nil }
            XCTAssertTrue(armed)
            let askID = work.askID
            _ = await c.respondToTask("Did it switch?")
            _ = await c.respondToTaskExact("Did it switch?", taskID: work.id, askID: askID, captureID: UUID())
            XCTAssertEqual(work.ask, ask)
            XCTAssertEqual(work.askID, askID)
            XCTAssertNotNil(work.askContinuation)
            if choose {
                _ = await c.respondToTaskExact("Choose one.", taskID: work.id, askID: askID, captureID: UUID())
            }
            let result = await answer.value
            XCTAssertEqual(result, choose ? "0" : nil)
            XCTAssertEqual(prompts, 1)
            XCTAssertNil(work.ask)
            XCTAssertNil(work.askContinuation)
        }
    }

    func testRetiringAnotherChoicePreservesTheDisplayedAsk() async {
        for expiry in [false, true] {
            let overlay = TargetOverlay(presentsPanels: false), c = coordinator(overlay: overlay)
            let older = VoiceTaskCoordinator.Work(label: "older", request: "", spec: .init(goal: "older"))
            let newer = VoiceTaskCoordinator.Work(label: "newer", request: "", spec: .init(goal: "newer"))
            c.tasks = [older, newer]
            let ask = DriveLoop.Ask.choice(prompt: "Which?", options: ["Alpha", "Beta"])
            c.askExpirySeconds = expiry ? 0.20 : 1
            let first = Task { await c.park(ask, on: older) }
            let firstReady = await waitFor { older.askContinuation != nil }
            XCTAssertTrue(firstReady)
            let stalePick = c.pendingOverlayPick
            c.askExpirySeconds = 1
            let second = Task { await c.park(ask, on: newer) }
            let secondReady = await waitFor { newer.askContinuation != nil }
            XCTAssertTrue(secondReady)
            stalePick?(1)
            XCTAssertNotNil(older.askContinuation)
            if !expiry {
                _ = await c.respondToTaskExact("Alpha", taskID: older.id, askID: older.askID, captureID: UUID())
            }
            let answer = await first.value
            XCTAssertEqual(answer, expiry ? nil : "0")
            XCTAssertEqual(overlay.pendingCount, 2)
            c.pendingOverlayPick?(1)
            let selected = await second.value
            XCTAssertEqual(selected, "1")
        }
    }

    func testCaptureAndParkedChoiceSuppressDwellFillEvenWhenOptedIn() async {
        let overlay = TargetOverlay(presentsPanels: false), c = coordinator(overlay: overlay)
        c.gazeService.dwellPolicy.mode = .safe
        let target = candidate("safe")
        c.captureActiveProbe = { false }
        c.gazeService.eventSink(.acquire(target))
        c.gazeService.eventSink(.hold(target, progress: 0.4))
        XCTAssertEqual(overlay.ringProgress, 0.4)
        c.captureActiveProbe = { true }
        c.gazeService.eventSink(.hold(target, progress: 0.45))
        XCTAssertEqual(overlay.ringProgress, 0)
        c.captureActiveProbe = { false }
        let work = VoiceTaskCoordinator.Work(label: "choice", request: "", spec: .init(goal: "choice"))
        c.tasks = [work]
        let parked = Task { await c.park(.choice(prompt: "Which?", options: ["A", "B"]), on: work) }
        let ready = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(ready)
        c.gazeService.eventSink(.hold(target, progress: 0.5))
        XCTAssertEqual(overlay.ringProgress, 0)
        XCTAssertTrue(c.declineTopmostChoiceAsk())
        _ = await parked.value
    }

    // MARK: - park re-entrancy

    /// A second park while one is parked declines honestly — the first
    /// continuation can never be orphaned because the row's ask slots
    /// were never overwritten.
    func testSecondParkOnSameWorkDeclines() async {
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
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
        let overlay = TargetOverlay(presentsPanels: false)
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
        c.captureActiveProbe = { true }
        XCTAssertTrue(c.gazeService.dwellSuppressed())
        c.captureActiveProbe = { false }
        XCTAssertFalse(c.gazeService.dwellSuppressed())
    }

    /// Service stop() tears ALL overlay state down — ring included —
    /// plus every pick claim, so nothing survives into the next start.
    func testOverlayTeardownClearsEverything() async {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.acquire(a))
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertFalse(overlay.ringArmed)
        XCTAssertEqual(overlay.pendingCount, 0)
        c.gazeService.eventSink(.acquire(b))
        XCTAssertTrue(overlay.ringArmed)
        c.gazeService.overlayTeardown?()
        XCTAssertEqual(overlay.pendingCount, 0)
        XCTAssertFalse(overlay.ringArmed)
        XCTAssertNil(c.pendingOverlayPick)
    }

    // MARK: - pending ask badge

    func testPendingAskCountTracksOnlyExplicitAsks() async {
        let overlay = TargetOverlay(presentsPanels: false)
        overlay.now = { 0 }
        let c = coordinator(overlay: overlay)
        XCTAssertEqual(c.pendingAskCount, 0)
        let a = candidate("a", x: 0), b = candidate("b", x: 200)
        c.gazeService.eventSink(.ambiguous([a, b]))
        XCTAssertEqual(c.pendingAskCount, 0)
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false), config: config)
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
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
        let c = coordinator(overlay: TargetOverlay(presentsPanels: false))
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
