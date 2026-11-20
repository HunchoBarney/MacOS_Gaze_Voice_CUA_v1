import CoreGraphics
import XCTest
@testable import Jarvis
import JarvisCore

// Quickdraw ships a C WindowRef that makes the contract name ambiguous here.
typealias WindowRef = Jarvis.WindowRef

/// Contract: one `TaskLoop` drives observe → decide → act → settle on a
/// bounded round budget. The loop — never the decider — owns actuation,
/// settle, and consent/ask routing; `DecideResult.done` is legal only
/// after a successful verify_state settle. Fakes script the capture
/// lane and the decider; every assertion reads outcomes, not internals.
final class TaskLoopTests: XCTestCase {
    func testOriginalNativeDocumentAnchorNeverAdoptsLaterDocument() async {
        let window = WindowRef(pid: 7, windowID: 42)
        let a = NativeDocumentSubject(window: window, fingerprint: Data(repeating: 1, count: 32))
        let b = NativeDocumentSubject(window: window, fingerprint: Data(repeating: 2, count: 32))
        for original in [a, nil] {
            var first = snap()
            first.nativeDocument = original
            var second = snap(id: "s2")
            second.nativeDocument = b
            let source = FakeSource(snapshots: [first, first, second])
            let box = Box()
            let brief = task()
            let loop = makeLoop(source: source, box: box) { observation in
                XCTAssertEqual(observation.nativeDocumentAnchor, original)
                XCTAssertEqual(observation.task, brief)
                if observation.stepIndex == 0 {
                    return .act(ActuationRequest(effect: .reobserve, tool: "", summary: "read again"))
                }
                return .blocked(reason: .safety("test finished"))
            }
            _ = await loop.run(brief)
            XCTAssertEqual(box.observations.count, 2)
            XCTAssertEqual(box.observations.last?.axSnapshot?.nativeDocument, b)
            XCTAssertTrue(box.actuated.isEmpty)
        }
    }

    /// Mutable state a @Sendable script closure can legitimately write.
    final class Box: @unchecked Sendable {
        var observations: [TaskObservation] = []
        var actuated: [ActuationRequest] = []
        var asks: [(question: String, choices: [String])] = []
        var consentCalls: [ActuationRequest] = []
        var askAnswer: String? = nil
    }

    /// A canned capture lane — snapshots vend in order (the last one
    /// repeats), every call counted so tests see exactly what the loop
    /// observed.
    final class FakeSource: CaptureSource, @unchecked Sendable {
        var front = WindowRef(pid: 7, windowID: 42)
        var snapshots: [AXSnapshot]
        var treeError: Error?
        var frontError: Error?
        var settleResult = true
        private(set) var frontCalls = 0
        private(set) var treeCalls = 0
        private(set) var settleCalls = 0

        init(snapshots: [AXSnapshot]) { self.snapshots = snapshots }

        func frontmostWindow() async throws -> WindowRef {
            frontCalls += 1
            if let frontError { throw frontError }
            return front
        }
        func axTree(of window: WindowRef, depth: AXDepth) async throws -> AXSnapshot {
            treeCalls += 1
            if let treeError { throw treeError }
            if snapshots.count > 1 { snapshots.removeFirst() }
            return snapshots.first ?? AXSnapshot(windowTitle: nil, snapshotID: nil,
                                                 elements: [], treeMarkdown: "")
        }
        func domSnapshot(of window: WindowRef) async throws -> DOMSnapshot {
            DOMSnapshot(url: "", title: "", indexedText: "", elements: [])
        }
        func settled(within timeout: Duration) async -> Bool {
            settleCalls += 1
            return settleResult
        }
    }

    /// A scripted brain — each `nextStep` runs the closure against the
    /// observation the LOOP built; observations land in the box so tests
    /// see exactly what crossed the contract boundary.
    struct ScriptedDecider: Decider {
        let box: Box
        let script: @Sendable (TaskObservation) throws -> DecideResult
        func nextStep(_ observation: TaskObservation) async throws -> DecideResult {
            box.observations.append(observation)
            return try script(observation)
        }
    }

    private func snap(title: String = "Fixture", markdown: String = "",
                      elements: [AXElement] = [], id: String = "s1") -> AXSnapshot {
        AXSnapshot(windowTitle: title, snapshotID: id,
                   elements: elements, treeMarkdown: markdown)
    }

    private func task(deny: [String] = [], success: [String] = [],
                      values: [String: String] = [:]) -> TaskBrief {
        TaskBrief(goal: "save the file", window: WindowRef(pid: 7, windowID: 42),
                  values: values, deny: deny, successContains: success)
    }

    /// `script` is last so a bare trailing closure binds the decider's
    /// brain, not the consent ruling.
    private func makeLoop(source: FakeSource, box: Box,
                          ruling: @escaping @Sendable (ActuationRequest, TaskBrief) -> TaskLoop.ConsentRuling = { _, _ in .allow },
                          outcome: TaskLoop.ActOutcome = .init(effect: "confirmed", verified: true, detail: nil),
                          script: @escaping @Sendable (TaskObservation) throws -> DecideResult) -> TaskLoop {
        TaskLoop(source: source, decider: ScriptedDecider(box: box, script: script),
                 actuate: { req in
                     box.actuated.append(req)
                     return outcome
                 },
                 consent: { req, brief in
                     box.consentCalls.append(req)
                     return ruling(req, brief)
                 },
                 ask: { q, c in
                     box.asks.append((q, c))
                     return box.askAnswer
                 })
    }

    // MARK: - done requires verify_state

    /// The zero-false-Done bar: a decider that only ever claims done
    /// never produces Done — the claim is rejected, then settled honest.
    func testDoneWithoutSettleIsRejected() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        let loop = makeLoop(source: source, box: box) { _ in .done(summary: "all done") }
        let result = await loop.run(task())
        guard case .blocked(.unverifiedDone) = result.outcome else {
            return XCTFail("expected .blocked(.unverifiedDone), got \(result.outcome)")
        }
        XCTAssertEqual(box.actuated.count, 0)
        XCTAssertEqual(box.asks.count, 0)
        XCTAssertTrue(result.history.contains { $0.echo == .rejectedDone })
    }

    /// One correction round: a done claim rejected once lets the decider
    /// run verify_state and then legitimately report done.
    func testDoneAcceptedAfterVerifiedSettle() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap(markdown: "File saved")])
        let loop = makeLoop(source: source, box: box) { obs in
            switch obs.stepIndex {
            case 0: return .done(summary: "premature")
            case 1: return .act(ActuationRequest(effect: .verifyState, tool: "",
                                                 summary: "verify the save"))
            default: return .done(summary: "saved")
            }
        }
        let result = await loop.run(task(success: ["file saved"]))
        guard case .done(let summary) = result.outcome else {
            return XCTFail("expected .done, got \(result.outcome)")
        }
        XCTAssertEqual(summary, "saved")
        XCTAssertTrue(result.history.contains { $0.echo == .rejectedDone })
        XCTAssertTrue(result.history.contains { $0.echo == .verify && $0.settleVerified })
    }

    /// A verify_state request that finds no evidence does not unlock done.
    func testFailedVerifyKeepsDoneLocked() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap(markdown: "nothing here")])
        let loop = makeLoop(source: source, box: box) { obs in
            switch obs.stepIndex {
            case 0: return .act(ActuationRequest(effect: .verifyState, tool: "",
                                                 summary: "verify"))
            default: return .done(summary: "nope")
            }
        }
        let result = await loop.run(task(success: ["saved"]))
        guard case .blocked(.unverifiedDone) = result.outcome else {
            return XCTFail("expected .blocked(.unverifiedDone), got \(result.outcome)")
        }
        XCTAssertTrue(result.history.contains { $0.echo == .verify && !$0.settleVerified })
    }

    /// A confirmed dispatched effect is a successful settle — done after
    /// it is legal.
    func testDoneAfterConfirmedAct() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap(markdown: "File saved")])
        let loop = makeLoop(source: source, box: box) { obs in
            obs.stepIndex == 0
                ? .act(ActuationRequest(effect: .tool, tool: "click",
                                        args: ["element_token": .string("tok1")],
                                        elementText: "Save", summary: "press Save"))
                : .done(summary: "saved")
        }
        let result = await loop.run(task(success: ["File saved"]))
        guard case .done = result.outcome else {
            return XCTFail("expected .done, got \(result.outcome)")
        }
        XCTAssertEqual(box.actuated.count, 1)
        XCTAssertEqual(result.verifiedEffects, 1)
        XCTAssertTrue(result.history.contains { $0.echo == .act && $0.actuated && $0.settleVerified })
    }

    /// An act that never verifies gives done no base — same rejection.
    func testDoneAfterUnverifiedActStillRejected() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        let loop = makeLoop(source: source, box: box,
                            outcome: .init(effect: "unverifiable", verified: false, detail: nil)) { obs in
            obs.stepIndex == 0
                ? .act(ActuationRequest(effect: .tool, tool: "click",
                                        summary: "press Save"))
                : .done(summary: "hmm")
        }
        let result = await loop.run(task())
        guard case .blocked(.unverifiedDone) = result.outcome else {
            return XCTFail("expected .blocked(.unverifiedDone), got \(result.outcome)")
        }
    }

    // MARK: - budget

    func testBlankCriteriaAndAvailableButtonsAreNotGoalEvidence() {
        let unrelated = snap(markdown: "Working")
        XCTAssertFalse(TaskLoop.successEvidence(in: unrelated, task: task(success: ["", " "])))
        XCTAssertFalse(TaskLoop.successEvidence(in: unrelated, task: task(success: ["", "Saved"])))
        let button = AXElement(index: 1, token: nil, role: "AXButton",
                               label: "Export complete", value: nil, frame: nil,
                               actions: ["AXPress"])
        let available = snap(markdown: "Export complete", elements: [button])
        XCTAssertFalse(TaskLoop.successEvidence(in: available,
                                                task: task(success: ["Export complete"])))
        let observed = AXElement(index: 2, token: nil, role: "AXStaticText",
                                 label: "Export complete", value: nil, frame: nil, actions: [])
        XCTAssertTrue(TaskLoop.successEvidence(in: snap(elements: [observed]),
                                               task: task(success: ["Export complete"])))
    }

    func testUnboundedLoopStopsEmptyDecisionsDespiteScreenChurn() async {
        let box = Box()
        let source = FakeSource(snapshots: (0..<30).map { snap(markdown: "Clock \($0)") })
        var config = TaskLoop.Config()
        config.maxRounds = nil
        config.maxNoProgressRounds = 3
        let loop = TaskLoop(source: source, decider: ScriptedDecider(box: box, script: { _ in
            .act(ActuationRequest(effect: .reobserve, tool: "", summary: "look"))
        }), actuate: { request in
            box.actuated.append(request)
            return .init(effect: "confirmed", verified: true, detail: nil)
        }, consent: { _, _ in .allow }, config: config)
        let result = await loop.run(task())
        XCTAssertEqual(result.outcome, .escalated(.staleScreen))
        XCTAssertEqual(box.observations.count, 3)
        XCTAssertTrue(box.actuated.isEmpty)
    }

    /// An unchanged fingerprint on the round after a real dispatch is
    /// delivery in flight — the app's repaint/AX propagation can lag the
    /// actuator's word — not proof the screen stopped changing. The
    /// stale mark the decider's stop counts stays clear for that round
    /// only; a genuinely static round right after still marks honestly.
    func testPostDispatchRoundIsNotMarkedStaleScreen() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap(markdown: "static")])
        let loop = makeLoop(source: source, box: box) { obs in
            switch obs.stepIndex {
            case 0: return .act(ActuationRequest(effect: .tool, tool: "click",
                                                summary: "press Save"))
            case 1: return .act(ActuationRequest(effect: .reobserve, tool: "",
                                                 summary: "wait"))
            default: return .blocked(reason: .safety("test finished"))
            }
        }
        let result = await loop.run(task())
        XCTAssertEqual(result.history.first { $0.echo == .reobserve }?.staleScreen, false)
        XCTAssertEqual(result.history.last?.staleScreen, true)
    }

    /// A dispatched round observed the screen before causing its
    /// change — marking it stale lets the pre-dispatch stillness
    /// streak escalate on the round right after the delivery. The
    /// mark stays off the act record so the streak restarts where the
    /// effect can first surface.
    func testDispatchedRoundIsNotMarkedStaleScreen() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap(markdown: "static")])
        let loop = makeLoop(source: source, box: box) { obs in
            switch obs.stepIndex {
            case 0: return .act(ActuationRequest(effect: .reobserve, tool: "",
                                                 summary: "look"))
            case 1: return .act(ActuationRequest(effect: .tool, tool: "click",
                                                summary: "press Save"))
            case 2: return .act(ActuationRequest(effect: .reobserve, tool: "",
                                                 summary: "wait"))
            default: return .blocked(reason: .safety("test finished"))
            }
        }
        let result = await loop.run(task())
        let act = result.history.first { $0.echo == .act }
        XCTAssertEqual(act?.actuated, true)
        XCTAssertEqual(act?.staleScreen, false)
        XCTAssertEqual(result.history.last?.staleScreen, true)
    }

    func testUnboundedLoopAllowsVisibleProgressWithoutEffects() async {
        let box = Box()
        let source = FakeSource(snapshots: (0..<20).map {
            snap(markdown: $0 >= 12 ? "Ready" : "Working", elements: [
                AXElement(index: 1, token: nil, role: "AXProgressIndicator", label: "Export",
                          value: "\($0)", frame: nil, actions: []),
                AXElement(index: 2, token: nil, role: "AXStaticText",
                          label: $0 >= 12 ? "Ready" : "Working", value: nil,
                          frame: nil, actions: [])])
        })
        var config = TaskLoop.Config()
        config.maxRounds = nil
        config.maxNoProgressRounds = 3
        config.settleReobserves = false
        let loop = TaskLoop(source: source, decider: ScriptedDecider(box: box, script: { obs in
            if obs.stepIndex < 12 {
                return .act(ActuationRequest(effect: .reobserve, tool: "", summary: "wait"))
            }
            if obs.stepIndex == 12 {
                return .act(ActuationRequest(effect: .verifyState, tool: "", summary: "verify"))
            }
            return .done(summary: "Ready")
        }), actuate: { _ in .init(effect: "confirmed", verified: true, detail: nil) },
        consent: { _, _ in .allow }, config: config)
        let result = await loop.run(task(success: ["Ready"]))
        XCTAssertEqual(result.outcome, .done(summary: "Ready"))
        XCTAssertEqual(result.roundsUsed, 14)
        XCTAssertTrue(box.observations.allSatisfy { $0.budget.roundsRemaining == nil })
    }

    func testCancellationAfterConsentNeverDispatches() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        let loop = TaskLoop(source: source, decider: ScriptedDecider(box: box, script: { _ in
            .act(ActuationRequest(effect: .tool, tool: "click", summary: "press"))
        }), actuate: { request in
            box.actuated.append(request)
            return .init(effect: "confirmed", verified: true, detail: nil)
        }, consent: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .allow
        })
        let result = await Task { await loop.run(task()) }.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(box.actuated.isEmpty)
    }

    func testExpiredWallBudgetReportsActualZeroRounds() async {
        let source = FakeSource(snapshots: [snap()])
        let box = Box()
        var config = TaskLoop.Config()
        config.wallBudget = .zero
        let loop = TaskLoop(source: source, decider: ScriptedDecider(box: box, script: { _ in
            .act(ActuationRequest(effect: .reobserve, tool: "", summary: "look"))
        }), actuate: { _ in .init(effect: "confirmed", verified: true, detail: nil) },
        consent: { _, _ in .allow }, config: config)
        let result = await loop.run(task())
        XCTAssertEqual(result.roundsUsed, 0)
        XCTAssertEqual(source.treeCalls, 0)
    }

    /// The Jev lane's 4-round ceiling: the loop calls the decider exactly
    /// maxRounds times, then hands up — never an extra observe.
    func testRoundBudgetStopsTheLoop() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        let loop = makeLoop(source: source, box: box) { _ in
            .act(ActuationRequest(effect: .reobserve, tool: "", summary: "look again"))
        }
        let result = await loop.run(task())
        guard case .escalated(.roundBudgetExhausted) = result.outcome else {
            return XCTFail("expected .escalated(.roundBudgetExhausted), got \(result.outcome)")
        }
        XCTAssertEqual(box.observations.count, 4)
        XCTAssertEqual(result.roundsUsed, 4)
        XCTAssertEqual(box.actuated.count, 0)  // reobserve is not actuation
    }

    // MARK: - askUser + consent routing

    /// `askUser` is a loop-seam round-trip: the question, the answer,
    /// and the resumed decision all flow through the loop's history —
    /// the decider never holds the ask channel itself.
    func testAskUserRoutedByLoop() async {
        let box = Box()
        box.askAnswer = "the second one"
        let source = FakeSource(snapshots: [snap(markdown: "File saved")])
        let loop = makeLoop(source: source, box: box) { obs in
            switch obs.stepIndex {
            case 0: return .askUser(question: "Which window?", choices: ["first", "second"])
            case 1: return .act(ActuationRequest(effect: .verifyState, tool: "",
                                                 summary: "verify"))
            default: return .done(summary: "saved")
            }
        }
        let result = await loop.run(task(success: ["file saved"]))
        guard case .done = result.outcome else {
            return XCTFail("expected .done, got \(result.outcome)")
        }
        XCTAssertEqual(box.asks.count, 1)
        XCTAssertEqual(box.asks[0].question, "Which window?")
        XCTAssertEqual(box.asks[0].choices, ["first", "second"])
        // The decider saw the answer in its next observation — user
        // words arriving through the contract, not a side channel.
        let seen = box.observations[1].history.last
        XCTAssertEqual(seen?.askKind, .question)
        XCTAssertEqual(seen?.askAnswer, "the second one")
    }

    /// A consent gate's confirm rides the same ask seam; a decline
    /// blocks before the actuator is ever touched.
    func testConsentConfirmDeclinedBlocks() async {
        let box = Box()
        box.askAnswer = "no"
        let source = FakeSource(snapshots: [snap()])
        let loop = makeLoop(source: source, box: box,
                            ruling: { _, _ in .needsConfirm(prompt: "Delete it?",
                                                            options: ["Yes", "No"], verdict: nil) }) { _ in
            .act(ActuationRequest(effect: .tool, tool: "click",
                                  elementText: "Delete", summary: "press Delete"))
        }
        let result = await loop.run(task())
        guard case .blocked(.consent) = result.outcome else {
            return XCTFail("expected .blocked(.consent), got \(result.outcome)")
        }
        XCTAssertEqual(box.actuated.count, 0)
        XCTAssertEqual(box.asks.count, 1)
    }

    /// A confirm answered yes lets the dispatch through — once, via the
    /// loop's own actuator call.
    func testConsentConfirmYesDispatches() async {
        let box = Box()
        box.askAnswer = "yes"
        let source = FakeSource(snapshots: [snap(markdown: "File saved")])
        let loop = makeLoop(source: source, box: box,
                            ruling: { _, _ in .needsConfirm(prompt: "Save it?",
                                                            options: ["Yes", "No"], verdict: nil) }) { obs in
            obs.stepIndex == 0
                ? .act(ActuationRequest(effect: .tool, tool: "click",
                                        summary: "press Save"))
                : .done(summary: "saved")
        }
        let result = await loop.run(task(success: ["File saved"]))
        guard case .done = result.outcome else {
            return XCTFail("expected .done, got \(result.outcome)")
        }
        XCTAssertEqual(box.actuated.count, 1)
    }

    /// The task's own deny strings are the loop's first gate — the
    /// consent seam never even runs on a deny hit.
    func testTaskDenyListBlockedInLoop() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        let loop = makeLoop(source: source, box: box) { _ in
            .act(ActuationRequest(effect: .tool, tool: "click",
                                  elementText: "Delete everything",
                                  summary: "press Delete everything"))
        }
        let result = await loop.run(task(deny: ["delete"]))
        guard case .blocked(.denyList(let hit)) = result.outcome else {
            return XCTFail("expected .blocked(.denyList), got \(result.outcome)")
        }
        XCTAssertEqual(hit, "delete")
        XCTAssertEqual(box.consentCalls.count, 0)
        XCTAssertEqual(box.actuated.count, 0)
    }

    // MARK: - blocked / escalate pass-through

    func testBlockedPassesThrough() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        let loop = makeLoop(source: source, box: box) { _ in
            .blocked(reason: .safety("no safe next step"))
        }
        let result = await loop.run(task())
        guard case .blocked(.safety(let why)) = result.outcome else {
            return XCTFail("expected .blocked(.safety), got \(result.outcome)")
        }
        XCTAssertEqual(why, "no safe next step")
        XCTAssertEqual(box.actuated.count, 0)
        XCTAssertEqual(box.observations.count, 1)  // one round, done
    }

    func testEscalatePassesThrough() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        let loop = makeLoop(source: source, box: box) { _ in
            .escalate(reason: .lowConfidenceTwice)
        }
        let result = await loop.run(task())
        guard case .escalated(.lowConfidenceTwice) = result.outcome else {
            return XCTFail("expected .escalated(.lowConfidenceTwice), got \(result.outcome)")
        }
        XCTAssertEqual(box.actuated.count, 0)
    }

    // MARK: - the decider cannot actuate

    /// The contract's structural guarantee: a decider's only reach is
    /// the DecideResult it returns — every dispatch flows through the
    /// loop's actuator, exactly once per granted `.act`, gated by
    /// consent, stamped with the loop's bound window.
    func testActuationOnlyFlowsThroughTheLoop() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap(markdown: "File saved")])
        let loop = makeLoop(source: source, box: box) { obs in
            switch obs.stepIndex {
            case 0, 1:
                // A decider trying to redirect the dispatch at a window
                // it was never bound to — the loop stamps its own
                // captured window over whatever args claim.
                return .act(ActuationRequest(effect: .tool, tool: "click",
                                             args: ["pid": .number(999),
                                                    "window_id": .number(999)],
                                             summary: "press Save"))
            default:
                return .done(summary: "saved")
            }
        }
        let result = await loop.run(task(success: ["File saved"]))
        guard case .done = result.outcome else {
            return XCTFail("expected .done, got \(result.outcome)")
        }
        XCTAssertEqual(box.actuated.count, 2)
        for req in box.actuated {
            XCTAssertEqual(req.args["pid"], .number(7))
            XCTAssertEqual(req.args["window_id"], .number(42))
        }
    }

    /// A consent ruling that never sees the actuator — the loop's gate
    /// is upstream of dispatch, so nothing a decider returns can bypass it.
    func testConsentDenyNeverDispatches() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        let loop = makeLoop(source: source, box: box,
                            ruling: { _, _ in .deny(.denyList("purchase")) }) { _ in
            .act(ActuationRequest(effect: .tool, tool: "click", summary: "press Pay"))
        }
        let result = await loop.run(task())
        guard case .blocked(.denyList(let hit)) = result.outcome else {
            return XCTFail("expected .blocked(.denyList), got \(result.outcome)")
        }
        XCTAssertEqual(hit, "purchase")
        XCTAssertEqual(box.actuated.count, 0)
    }

    // MARK: - observation + failure shapes

    /// An observation-lane failure degrades the snapshot — the decider
    /// sees `axSnapshot == nil` and may escalate; it is never lied to.
    func testDegradedObservationReachesDecider() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        source.treeError = DriverConnectionError.closed
        let loop = makeLoop(source: source, box: box) { obs in
            XCTAssertNil(obs.axSnapshot)
            return .escalate(reason: .degradedAX)
        }
        let result = await loop.run(task())
        guard case .escalated(.degradedAX) = result.outcome else {
            return XCTFail("expected .escalated(.degradedAX), got \(result.outcome)")
        }
    }

    /// A thrown decider is a block, not a crash or a fabricated done.
    func testDeciderThrowBlocks() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        struct DeciderError: Error {}
        let loop = makeLoop(source: source, box: box) { _ in throw DeciderError() }
        let result = await loop.run(task())
        guard case .blocked(.decider) = result.outcome else {
            return XCTFail("expected .blocked(.decider), got \(result.outcome)")
        }
    }

    /// Cancellation mid-observe settles cancelled — never blocked, never done.
    func testCancellationSettlesCancelled() async {
        let box = Box()
        let source = FakeSource(snapshots: [snap()])
        source.treeError = CancellationError()
        let loop = makeLoop(source: source, box: box) { _ in .done(summary: "never") }
        let result = await loop.run(task())
        guard case .cancelled = result.outcome else {
            return XCTFail("expected .cancelled, got \(result.outcome)")
        }
    }
}
