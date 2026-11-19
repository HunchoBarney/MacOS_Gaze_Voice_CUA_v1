import XCTest
@testable import Jarvis
import JarvisCore

/// Coordinator-lane contracts that need a live coordinator but no driver:
/// session labels and the cursor-suppression predicate, the local-lane
/// claim ledger that fences the realtime echo, parked-ask answering from
/// a local command, and `cancelAllRunning` reaching agent turns.
@MainActor
final class VoiceTaskCoordinatorLaneTests: XCTestCase {
    func testR7CoordinatorRejectsRetargetedOrReplayedScrollBeforeAdmission() async throws {
        let original = "Move the page down a little."
        let request = try XCTUnwrap(WindowScrollRequest(goal: original,
            application: "fixture.editor", windowID: 41, direction: "down", small: true))
        for variant in ["goal", "app", "window", "literal", "plan", "repeat", "transcript", "cancelled"] {
            let c = coordinator()
            var lookups = 0
            c.gazeContextProvider = { lookups += 1; return nil }
            let result = await c.beginVoiceTask(
                variant == "goal" ? original + " until Cedar is visible." : variant == "repeat" ? "do that again" : original,
                app: variant == "app" ? "fixture.other" : "fixture.editor",
                literalText: variant == "literal" ? "Cedar" : nil,
                transcriptHint: variant == "transcript" ? original + " until Cedar is visible." : nil,
                steps: variant == "plan" ? ["click Save"] : [],
                pinnedWindowID: variant == "window" ? 42 : 41, windowScroll: request,
                admissionIsCurrent: { variant != "cancelled" })
            XCTAssertFalse(result.contains("\"status\":\"started\""), variant)
            XCTAssertTrue(c.tasks.isEmpty, variant)
            XCTAssertEqual(lookups, 0, variant)
            c.shutdown()
        }
    }

    func testContinuousOwnerWaitSurvivesItsQuestionUntilActualCancellation() async {
        let c = coordinator()
        c.audioFeedbackAllowed = { false }
        let work = VoiceTaskCoordinator.Work(label: "Scroll", request: "Scroll", spec: DriveTask(goal: "Scroll"))
        c.tasks = [work]
        var resumed = false
        let waiting = Task {
            let result = await c.waitForConversationBoundary(work.id, throughQuestions: true)
            resumed = true
            return result
        }
        let parked = Task { await c.park(.question("Allow scrolling?"), on: work) }
        let ready = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(ready)
        await Task.yield()
        XCTAssertFalse(resumed)
        c.cancel(work.id)
        let result = await waiting.value
        XCTAssertEqual(result, .finished(.cancelled))
        let answer = await parked.value
        XCTAssertNil(answer)
    }

    func testConversationWaitReturnsAtAQuestionSoItsAnswerCanBeHeard() async {
        let c = coordinator()
        c.audioFeedbackAllowed = { false }
        let work = VoiceTaskCoordinator.Work(label: "Owned", request: "Owned", spec: DriveTask(goal: "Owned"))
        c.tasks = [work]
        let waiting = Task { await c.waitForConversationBoundary(work.id) }
        let parked = Task { await c.park(.question("Which document?"), on: work) }
        let ready = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(ready)
        let boundary = await waiting.value
        XCTAssertEqual(boundary, .question)
        c.cancel(work.id)
        let answer = await parked.value
        XCTAssertNil(answer)
        let finished = await c.waitForConversationBoundary(work.id)
        XCTAssertEqual(finished, .finished(.cancelled))
    }

    func testCancellingConversationWaitCancelsOnlyItsOwnedWork() async {
        let c = coordinator()
        c.audioFeedbackAllowed = { false }
        let owned = VoiceTaskCoordinator.Work(label: "Owned", request: "Owned", spec: DriveTask(goal: "Owned"))
        let other = VoiceTaskCoordinator.Work(label: "Other", request: "Other", spec: DriveTask(goal: "Other"))
        c.tasks = [owned, other]
        let waiting = Task { await c.waitForConversationBoundary(owned.id) }
        waiting.cancel()
        let result = await waiting.value
        XCTAssertEqual(result, .finished(.cancelled))
        XCTAssertFalse(owned.active)
        XCTAssertTrue(other.active)
        c.cancel(other.id)
    }

    private struct MemoryKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    private func coordinator() -> VoiceTaskCoordinator {
        let suite = "vtc-lane-\(UUID().uuidString)"
        let config = Config(defaults: UserDefaults(suiteName: suite)!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(),
                            environment: [:])
        return VoiceTaskCoordinator(
            config: config, jevAPIKey: { "" },
            gazeService: GazeService(
                stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay())
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testSemanticCreationIsTracedBeforeValidationAndNeverInventsDispatch() async {
        for scenario in 0..<3 {
            let c = coordinator(), turn = UUID()
            let proposal = VoiceSemanticRouter.Proposal(
                turn: VoiceTurnToken(id: turn, generation: 1, mode: .typed),
                target: .init(name: "Fixture editor", id: "fixture.editor", canOpenLocally: true),
                model: "protocol-fixture", actionConfidence: 1, targetConfidence: 1)
            var created: [(UUID?, UUID?)] = []
            var mutations = 0, executions = 0
            c.onCommandStage = { owner, task, stage, _ in
                if stage == .workCreated { created.append((owner, task)) }
                if stage == .nativeActivationBegin || stage == .nativeUnhideBegin || stage == .driverBegin {
                    mutations += 1
                }
            }
            XCTAssertTrue(c.offerSemanticFocus(proposal, validate: {
                XCTAssertEqual(created.count, 1)
                return scenario == 0
            }, runConfirmed: { work in
                executions += 1
                work.active = false
            }))
            guard let work = c.tasks.first else { XCTFail("Missing semantic work"); continue }
            XCTAssertEqual(created.count, 1)
            XCTAssertEqual(created.first?.0, turn)
            XCTAssertEqual(created.first?.1, work.id)
            if scenario == 2 { c.cancelPendingSemanticFocus() }
            let settled = await waitFor { !work.active }
            XCTAssertTrue(settled)
            XCTAssertEqual(executions, scenario == 0 ? 1 : 0)
            XCTAssertEqual(mutations, 0)
            XCTAssertEqual(created.count, 1)
            c.shutdown()
        }
    }

    // MARK: - Session labels and cursor posture

    private final class WarmGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testInventoryWarmupCoalescesWithoutAwaitingRead() async {
        let c = coordinator(), gate = WarmGate()
        var reads = 0
        c.scheduleInventoryWarmup(generation: "one") {
            reads += 1
            await gate.wait()
        }
        c.scheduleInventoryWarmup(generation: "one") { reads += 100 }
        let started = await waitFor { reads == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(c.inventoryWarmupMetrics["pending"] as? Int, 1)
        gate.release()
        let settled = await waitFor { c.inventoryWarmupMetrics["pending"] as? Int == 0 }
        XCTAssertTrue(settled)
        c.scheduleInventoryWarmup(generation: "one") { reads += 100 }
        await Task.yield()
        XCTAssertEqual(reads, 1)
        c.shutdown()
    }

    func testInventoryWarmupOldCompletionDoesNotClearSuccessor() async {
        let c = coordinator(), first = WarmGate(), second = WarmGate()
        var reads = 0
        c.scheduleInventoryWarmup(generation: "one") { reads += 1; await first.wait() }
        let firstStarted = await waitFor { reads == 1 }
        XCTAssertTrue(firstStarted)
        c.scheduleInventoryWarmup(generation: "two") { reads += 1; await second.wait() }
        let secondStarted = await waitFor { reads == 2 }
        XCTAssertTrue(secondStarted)
        let successorStartedAt = c.inventoryWarmupMetrics["last_started_at"] as? Double
        XCTAssertNotNil(successorStartedAt)
        first.release()
        let oldSettled = await waitFor { c.inventoryWarmupMetrics["pending"] as? Int == 1 }
        XCTAssertTrue(oldSettled)
        XCTAssertEqual(c.inventoryWarmupMetrics["last_started_at"] as? Double, successorStartedAt)
        XCTAssertNil(c.inventoryWarmupMetrics["last_settled_at"])
        c.scheduleInventoryWarmup(generation: "two") { reads += 100 }
        XCTAssertEqual(reads, 2)
        second.release()
        let allSettled = await waitFor { c.inventoryWarmupMetrics["pending"] as? Int == 0 }
        XCTAssertTrue(allSettled)
        XCTAssertEqual(c.inventoryWarmupMetrics["cancelled"] as? Int, 1)
        c.shutdown()
    }

    func testInventoryWarmupFailureIsQuietAndNotRedispatched() async {
        enum Failed: Error { case expected }
        let c = coordinator()
        var reads = 0
        c.scheduleInventoryWarmup(generation: "one") { reads += 1; throw Failed.expected }
        let settled = await waitFor { c.inventoryWarmupMetrics["failed"] as? Int == 1 }
        XCTAssertTrue(settled)
        c.scheduleInventoryWarmup(generation: "one") { reads += 100 }
        await Task.yield()
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(c.tasks.isEmpty)
        c.shutdown()
    }

    func testInventoryWarmupShutdownClosesLatePreparedBindingWithoutRead() async {
        let c = coordinator(), gate = WarmGate()
        var preparations = 0, reads = 0, closes = 0
        c.prepareInventoryWarmup {
            preparations += 1
            await gate.wait()
            return .init(generation: "one", read: { reads += 1 }, close: { closes += 1 })
        }
        c.prepareInventoryWarmup { preparations += 100; throw CancellationError() }
        let started = await waitFor { preparations == 1 }
        XCTAssertTrue(started)
        c.shutdown()
        gate.release()
        let closed = await waitFor { closes == 1 }
        XCTAssertTrue(closed)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(preparations, 1)
        c.scheduleInventoryWarmup(generation: "two") { reads += 100 }
        await Task.yield()
        XCTAssertEqual(reads, 0)
    }

    func testInventoryWarmupUsesOnlySessionlessReadAndDiscardsPayload() async throws {
        var tools: [String] = []
        try await VoiceTaskCoordinator.performInventoryWarmup { tool, args in
            tools.append(tool)
            XCTAssertTrue(args.isEmpty)
            XCTAssertTrue(CuaConnection.isReadOnly(tool, arguments: args))
            return .object(["windows": .array([.object(["window_id": .number(99)])])])
        }
        XCTAssertEqual(tools, ["list_windows"])
    }

    func testHaloUsesNativeScreenPointsWithoutScreenshotMetadata() {
        let snap: JSONValue = .object(["elements": .array([
            .object(["element_index": .number(1), "role": .string("AXTextArea"),
                     "frame": .object(["x": .number(634), "y": .number(192),
                                       "w": .number(656), "h": .number(384)])])
        ])])
        XCTAssertEqual(VoiceTaskCoordinator.haloFrame(at: CGPoint(x: 700, y: 220), in: snap),
                       CGRect(x: 634, y: 192, width: 656, height: 384))
        XCTAssertNil(VoiceTaskCoordinator.haloFrame(at: CGPoint(x: 10, y: 10), in: snap))
    }

    func testProductionNativeSelectionAndControlledDriverSuppression() {
        let production = coordinator()
        XCTAssertTrue(production.hasForegroundAppLauncher)
        let config = Config(defaults: UserDefaults(suiteName: "native-select-\(UUID())")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        let controlled = VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay(), commandDriver: { _, _ in .object([:]) })
        XCTAssertFalse(controlled.hasForegroundAppLauncher)
    }

    func testCoordinatorWorkActuallySelectsNativeForegroundLauncher() async throws {
        let config = Config(defaults: UserDefaults(suiteName: "native-work-\(UUID())")!,
                            keyStore: MemoryKeys(), openAIKeyStore: MemoryKeys(), environment: [:])
        config.sounds = false
        var nativeCalls = 0, backgroundCalls = 0, raises = 0
        let c = VoiceTaskCoordinator(config: config, jevAPIKey: { "" },
            gazeService: GazeService(stream: GazeStream(frames: { AsyncThrowingStream { _ in } })),
            overlay: TargetOverlay(), resolver: AppResolver(listApps: {
                [.init(name: "AuditFixture", bundle: "fixture.audit")]
            }), commandDriver: { tool, _ in
                if tool == "launch_app" { backgroundCalls += 1; return .object(["pid": .number(424242)]) }
                if tool == "bring_to_front" {
                    raises += 1
                    return .object(["activated": .bool(true),
                                    "exact_window_effect": .object(["verified": .bool(true)])])
                }
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "is_on_screen": .bool(true), "title": .string("Owned")
                ])])])
            }, foregroundAppLauncher: { bundle in
                XCTAssertEqual(bundle, "fixture.audit")
                nativeCalls += 1; return 424242
            })
        c.gazeContextProvider = { nil }
        _ = await c.beginVoiceTask("open AuditFixture", app: "fixture.audit", captureID: UUID())
        let settled = await waitFor { c.tasks.first?.active == false }
        XCTAssertTrue(settled)
        XCTAssertEqual(c.tasks.first?.outcome, .done)
        XCTAssertEqual(nativeCalls, 1)
        XCTAssertEqual(backgroundCalls, 0)
        XCTAssertEqual(raises, 1)
        XCTAssertFalse(c.tasks.first?.awaitingAnswer == true)
    }

    /// Direct and gaze sessions — and their rotated successors — are
    /// cursorless; model work and agent sessions keep a visible cursor.
    /// A bare prefix ("voice-gazer") is NOT the stem — the successor
    /// boundary is the hyphen.
    func testCursorlessSessionPredicate() {
        XCTAssertTrue(VoiceTaskCoordinator.cursorlessSession("voice-gaze"))
        XCTAssertTrue(VoiceTaskCoordinator.cursorlessSession("voice-direct"))
        XCTAssertTrue(VoiceTaskCoordinator.cursorlessSession("voice-gaze-2"))
        XCTAssertTrue(VoiceTaskCoordinator.cursorlessSession("voice-direct-17"))
        XCTAssertFalse(VoiceTaskCoordinator.cursorlessSession("voice"))
        XCTAssertFalse(VoiceTaskCoordinator.cursorlessSession("voice-3"))
        XCTAssertFalse(VoiceTaskCoordinator.cursorlessSession("agent-scout"))
        XCTAssertFalse(VoiceTaskCoordinator.cursorlessSession("voice-gazer"))
    }

    /// The three labels are distinct so the driver draws (or suppresses)
    /// a cursor per session independently.
    func testSessionLabelsAreDistinct() {
        XCTAssertEqual(VoiceTaskCoordinator.session, "voice")
        XCTAssertEqual(VoiceTaskCoordinator.gazeSession, "voice-gaze")
        XCTAssertEqual(VoiceTaskCoordinator.directSession, "voice-direct")
    }

    /// Reproduced on the pinned driver: minting a session on the read proxy
    /// then using it on the command proxy returns session_unavailable.
    func testSessionObservationStaysOnCommandOwner() async throws {
        let args: [String: JSONValue] = ["session": .string("voice-direct-1"), "pid": .number(42)]
        let result = try await VoiceTaskCoordinator.routeObservation("get_window_state", args,
            owner: { tool, received in
                XCTAssertEqual(tool, "get_window_state")
                XCTAssertEqual(received, args)
                return .object(["element_id": .string("owner-bound-element")])
            },
            independent: { _, _ in
                XCTFail("a second proxy cannot observe this owner's session")
                throw DriverConnectionError.refused("session is not available to this transport")
            })
        XCTAssertEqual(result["element_id"]?.string, "owner-bound-element")
    }

    func testIndependentObservationKeepsParallelReadLane() async throws {
        let result = try await VoiceTaskCoordinator.routeObservation("list_apps", [:],
            owner: { _, _ in XCTFail("independent reads need not block mutations"); return .null },
            independent: { _, _ in .object(["apps": .array([])]) })
        XCTAssertEqual(result["apps"]?.array, [])
    }

    func testObservationLaneRejectsMutationBeforeEitherTransport() async {
        do {
            _ = try await VoiceTaskCoordinator.routeObservation("click", ["session": .string("voice")],
                owner: { _, _ in XCTFail("mutation reached observation owner"); return .null },
                independent: { _, _ in XCTFail("mutation reached read proxy"); return .null })
            XCTFail("the observation lane must reject mutations")
        } catch {}
    }

    // MARK: - Capture authority replaces text-window claims

    func testIntentionalIdenticalTurnsAreNotSuppressedByTime() async {
        var calls = 0
        let session = LocalSpeechSession { _ in calls += 1 }
        session.context.targetID = "fixture"
        _ = await session.submitTyped("scroll down", now: 1)
        _ = await session.submitTyped("scroll down", now: 1.01)
        XCTAssertEqual(calls, 2)
    }

    func testNormalizationDoesNotEraseDirection() {
        XCTAssertEqual(VoiceAdmissionPolicy.normalized("Scroll  down."), "scroll down")
        XCTAssertNotEqual(VoiceAdmissionPolicy.normalized("scroll down"),
                          VoiceAdmissionPolicy.normalized("scroll up"))
    }

    func testRemoteRephraseCannotReplaceTheFinalSource() async throws {
        let session = LocalSpeechSession { _ in XCTFail("this is a miss") }
        let decision = await session.submitTyped("organize these files by date", now: 1)
        let admission = try XCTUnwrap(decision)
        XCTAssertEqual(admission.route, .remote)
        XCTAssertThrowsError(try VoiceToolCatalog.validate("computer_task",
            arguments: #"{"goal":"open the notes app"}"#,
            admission: admission, context: VoiceAdmissionContext()))
    }

    // MARK: - Parked asks answered by speech

    /// A parked confirm takes a spoken "yes" through the local command
    /// lane — no second Fn press, no new task.
    func testLocalCommandAnswersParkedConfirm() async {
        let c = coordinator()
        let work = VoiceTaskCoordinator.Work(
            label: "click save", request: "click save",
            spec: DriveTask(goal: "click save"))
        c.tasks = [work]
        let parked = Task { await c.park(.confirm("Allow computer control?"),
                                         on: work) }
        let armed = await waitFor { work.approvalContinuation != nil }
        XCTAssertTrue(armed)

        let reply = await c.respondToTaskExact("yes", taskID: work.id, askID: work.askID, captureID: UUID())
        let answer = await parked.value
        XCTAssertEqual(answer, "yes")
        XCTAssertEqual(VoiceToolResult(jsonString: reply)?.status,
                       VoiceToolResult.Status.ok)
        XCTAssertNil(work.ask)
    }

    /// A parked choice takes a spoken ordinal — "two" resolves to the
    /// radial's second option index.
    func testLocalCommandAnswersParkedChoiceOrdinal() async {
        let c = coordinator()
        let overlay = c.overlay
        overlay.now = { 0 }
        let work = VoiceTaskCoordinator.Work(
            label: "pick", request: "pick", spec: DriveTask(goal: "pick"))
        c.tasks = [work]
        let parked = Task {
            await c.park(.choice(prompt: "which?", options: ["a", "b"]),
                         on: work)
        }
        let armed = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(armed)

        _ = await c.respondToTaskExact("two", taskID: work.id, askID: work.askID, captureID: UUID())
        let answer = await parked.value
        XCTAssertEqual(answer, "1")   // 0-based index on the wire
        XCTAssertNil(work.askContinuation)
        overlay.hideAll()
    }

    /// Speech that isn't shaped like the ask's answer is not claimed —
    /// the parked-ask path returns nil and leaves the ask parked.
    func testUnshapedSpeechLeavesParkedAsk() async {
        let c = coordinator()
        let work = VoiceTaskCoordinator.Work(
            label: "ask", request: "ask", spec: DriveTask(goal: "ask"))
        c.tasks = [work]
        let parked = Task {
            await c.park(.choice(prompt: "which app?",
                                 options: ["Safari", "Notes"]),
                         on: work)
        }
        let armed = await waitFor { work.askContinuation != nil }
        XCTAssertTrue(armed)

        // "scroll down" is not an ordinal, verdict word, or either
        // option's name — it's a command, not the radial's answer.
        var context = VoiceAdmissionContext()
        context.targetID = "fixture"
        let ask = VoiceAdmissionContext.Ask(taskID: work.id, askID: work.askID, kind: .choice, options: ["Safari", "Notes"])
        context.capturedAsks = [ask]; context.currentAsks = [ask]
        let proposal = VoiceAdmissionPolicy.propose("scroll down", context: context)
        XCTAssertEqual(proposal.intent, "scroll")
        XCTAssertNotNil(work.askContinuation,
                        "unshaped speech must not consume the ask")

        // Tidy: resolve the ask so the parked task can't linger.
        c.pendingOverlayPick?(0)
        _ = await parked.value
        c.overlay.hideAll()
    }

    // MARK: - Universal cancel

    /// `cancelAllRunning` retires every active task AND interrupts every
    /// live agent turn — one "stop" never leaves sibling work behind.
    func testCancelAllRunningStopsTasksAndAgents() async {
        let c = coordinator()
        let bridge = FakeBridge()
        c.agentBridge = bridge
        let a = VoiceTaskCoordinator.Work(label: "a", request: "do a",
                                          spec: DriveTask(goal: "do a"))
        let b = VoiceTaskCoordinator.Work(label: "b", request: "do b",
                                          spec: DriveTask(goal: "do b"))
        c.tasks = [a, b]

        let stopped = await c.cancelAllRunning()
        XCTAssertTrue(stopped)
        XCTAssertEqual(bridge.interruptAllCalls, 1)
        XCTAssertFalse(a.active); XCTAssertFalse(b.active)
        XCTAssertEqual(a.outcome, .cancelled)
        XCTAssertEqual(b.outcome, .cancelled)
    }

    /// No tasks but live agent turns still reports stopped — the agent
    /// reply is what makes "Stopped." honest.
    func testCancelAllRunningReachesAgentsAlone() async {
        let c = coordinator()
        let bridge = FakeBridge()
        c.agentBridge = bridge

        let stopped = await c.cancelAllRunning()
        XCTAssertTrue(stopped)
        XCTAssertEqual(bridge.interruptAllCalls, 1)
    }

    /// Nothing running anywhere → honest "nothing". The bridge is still
    /// asked — a live agent turn may exist with no local tasks — and its
    /// own verdict is what reports whether anything stopped.
    func testCancelAllRunningOnIdleIsHonest() async {
        let c = coordinator()
        let bridge = FakeBridge()
        bridge.interruptAllResult = VoiceToolResult(
            status: VoiceToolResult.Status.nothingRunning,
            say: "Nothing is running.").encoded()
        c.agentBridge = bridge

        let stopped = await c.cancelAllRunning()
        XCTAssertFalse(stopped)
        XCTAssertEqual(bridge.interruptAllCalls, 1)
    }

    /// A ".cancel" verdict inside beginVoiceTask stops everything instead
    /// of spawning work — the router's classify is authoritative.
    func testSpokenCancelVerdictStopsWork() async {
        let c = coordinator()
        let bridge = FakeBridge()
        c.agentBridge = bridge
        let a = VoiceTaskCoordinator.Work(label: "a", request: "do a",
                                          spec: DriveTask(goal: "do a"))
        c.tasks = [a]

        let reply = await c.beginVoiceTask("stop")
        let parsed = VoiceToolResult(jsonString: reply)
        XCTAssertEqual(parsed?.status, VoiceToolResult.Status.cancelled)
        XCTAssertFalse(a.active)
        XCTAssertEqual(bridge.interruptAllCalls, 1)
    }

    /// A finished row that still carries an ask (an agent ask has no
    /// continuation to resume, so the old finish/cancel arms left it
    /// orphaned) must be clearable — the pill's "waiting for your
    /// answer" card would otherwise resurface an unanswerable prompt.
    func testOrphanedAskOnInactiveWorkIsDismissable() {
        let c = coordinator()
        let dead = VoiceTaskCoordinator.Work(label: "Agent bench", request: "Continue?",
                                             spec: DriveTask(goal: "Continue?"))
        dead.agentAskID = "dead-ask-\(UUID().uuidString)"
        dead.ask = .confirm("Continue with the risky step?")
        dead.active = false
        c.tasks = [dead]
        XCTAssertTrue(dead.awaitingAnswer)

        c.cancel(dead.id)

        XCTAssertNil(dead.ask)
        XCTAssertNil(dead.agentAskID)
        XCTAssertFalse(dead.awaitingAnswer)
    }

    /// An agent ask that expires while its child is gone settles through
    /// `finish` — the row must drop the ask and the agentAskID so no
    /// parked card survives the work that owned it.
    func testFinishedAgentAskLeavesNoParkedCard() async {
        let c = coordinator()
        let work = VoiceTaskCoordinator.Work(label: "Agent bench", request: "Pick one",
                                             spec: DriveTask(goal: "Pick one"))
        work.agentAskID = "gone-\(UUID().uuidString)"
        work.ask = .choice(prompt: "Pick one", options: ["first", "second"])
        c.tasks = [work]
        _ = await c.beginVoiceTask("stop")

        XCTAssertNil(work.ask)
        XCTAssertNil(work.agentAskID)
        XCTAssertFalse(work.awaitingAnswer)
        XCTAssertFalse(work.active)
    }

    /// AgentBridging spy — records the all-turn sweep the universal
    /// cancel depends on.
    private final class FakeBridge: AgentBridging, @unchecked Sendable {
        var interruptAllCalls = 0
        var interruptHints: [String?] = []
        /// What interruptAll reports — "cancelled" claims turns stopped,
        /// "nothing_running" reports an idle roster.
        var interruptAllResult = VoiceToolResult(
            status: VoiceToolResult.Status.cancelled,
            say: "Stopped.").encoded()

        func roster() async -> [CompanionAgent] { [] }
        func delegate(_ request: DelegationRequest) async throws -> String {
            VoiceToolResult(status: VoiceToolResult.Status.refused,
                            say: "no").encoded()
        }
        func sendToAgent(slug: String, message: String) async throws -> String {
            VoiceToolResult(status: VoiceToolResult.Status.ok, say: "ok").encoded()
        }
        func agentMemory(slug: String) async throws -> String {
            VoiceToolResult(status: VoiceToolResult.Status.ok, say: "ok").encoded()
        }
        func interruptAgent(hint: String?) async -> String {
            interruptHints.append(hint)
            return VoiceToolResult(status: VoiceToolResult.Status.cancelled,
                                   say: "Stopped.").encoded()
        }
        func interruptAll() async -> String {
            interruptAllCalls += 1
            return interruptAllResult
        }
    }
}
