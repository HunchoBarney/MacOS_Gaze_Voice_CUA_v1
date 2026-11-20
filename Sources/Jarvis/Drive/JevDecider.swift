import CoreGraphics
import Foundation
import JarvisCore

/// The AX-first brain — CONTRACTS §1's `JevDecider`. It adapts the
/// existing bounded candidate pick (`JevChooser.make` in production)
/// to `DecideResult`: build the same candidate set the drive loop
/// built (`DriveCandidates` is the one home), ask bounded judgments,
/// map the picked candidate to a request the `TaskLoop`
/// executes and settles.
///
/// The decider holds no actuator, no ask channel, and no consent gate:
/// every mutation it names comes back as `DecideResult.act` for the
/// loop to gate, dispatch, and verify. Literal text is never authored —
/// a type pick either carries a caller-supplied `values` literal
/// verbatim or raises `askUser` for the loop to route.
actor JevDecider: Decider {
    /// The existing bounded pick — `DriveLoop.Choose` is the factory
    /// shape `JevChooser.make` produces: state JSON in, a validated
    /// `JevChoice` (id + optional confidence + same-call done vote) out.
    typealias Choose = DriveLoop.Choose
    private let choose: Choose
    private var activeTask: TaskBrief?

    /// Per-round candidates the AX tree can't mint (traffic lights,
    /// page refs, tabs) plus lane-known state fields — the drive loop's
    /// browser/traffic-light arms ride this seam. Nil keeps the decider
    /// snapshot-only.
    private let extras: (@Sendable (TaskObservation) async -> DriveCandidates.RoundExtras)?
    /// The freshest gaze point — the lane resolves it; the decider only
    /// tags the candidate under it, never filters or reorders.
    private let gaze: (@Sendable () async -> GazeSample?)?
    /// The chooser-visible context — the lane decides what travels
    /// (clipboard text withheld without the standing grant arrives
    /// pre-masked; the decider never sees the rule).
    private let contextProvider: (@Sendable () -> String?)?

    /// The pick's evidence gates — the same thresholds DriveLoop applies
    /// to whatever engine answered.
    private let confidenceFloor: Double
    private let maxInvalidPicks: Int
    private let maxLowConfidence: Int
    private let maxStaleRounds: Int
    private let elementCap: Int?
    private let windowOnly: Bool
    private var invalidPicks = 0
    private var lowConfidenceStreak = 0
    /// The parked text hole — a needs-text pick whose question is out.
    /// The next observation resolves it on the recorded answer rather
    /// than spending another model call on an identical pick.
    private var pendingTextHole: (request: ActuationRequest, historyCount: Int, question: String)?
    /// Internal stale streak — the decider's own fingerprint count
    /// carries the CURRENT observation exactly like the drive loop's
    /// counter did; the history marks only see prior rounds.
    private var lastFingerprint: String?
    private var staleStreak = 0
    private var observedGoal: ObservedGoalProof?

    /// Reasons the drive lane's settle mapping keys on — emitted
    /// verbatim so refusal and already-satisfied shapes stay identical
    /// to the hand-rolled loop's.
    static let noSafeStepReason = "no safe next step exists"
    static let needsTextReason = "I need the text to type."
    static let unverifiedDoneReason = "The task reported complete, but the expected evidence never appeared on screen — the outcome is unverified."
    static let missingEvidenceReason = "the expected evidence was not observed"
    static let alreadySatisfiedReason = "already on screen"

    init(choose: @escaping Choose,
         confidenceFloor: Double = 0.45,
         maxInvalidPicks: Int = 2,
         maxLowConfidence: Int = 2,
         maxStaleRounds: Int = 3,
         elementCap: Int? = nil,
         windowOnly: Bool = false,
         extras: (@Sendable (TaskObservation) async -> DriveCandidates.RoundExtras)? = nil,
         gaze: (@Sendable () async -> GazeSample?)? = nil,
         context: (@Sendable () -> String?)? = nil) {
        self.choose = choose
        self.confidenceFloor = confidenceFloor
        self.maxInvalidPicks = maxInvalidPicks
        self.maxLowConfidence = maxLowConfidence
        self.maxStaleRounds = maxStaleRounds
        self.elementCap = elementCap
        self.windowOnly = windowOnly
        self.extras = extras
        self.gaze = gaze
        self.contextProvider = context
    }

    func nextStep(_ observation: TaskObservation) async throws -> DecideResult {
        try Task.checkCancellation()
        if activeTask != observation.task {
            observedGoal = nil
            pendingTextHole = nil
            invalidPicks = 0
            lowConfidenceStreak = 0
            lastFingerprint = nil
            staleStreak = 0
        }
        if observation.stepIndex == 0 { observedGoal = nil }
        activeTask = observation.task
        let result = try await decideStep(observation)
        try Task.checkCancellation()
        if case .act(let request) = result, request.effect == .reobserve {
            return result
        }
        switch result {
        case .done, .blocked, .escalate:
            activeTask = nil
            pendingTextHole = nil
            observedGoal = nil
        default: break
        }
        return result
    }

    private func decideStep(_ observation: TaskObservation) async throws -> DecideResult {
        // A degraded observation is an honest escalate — never a pick
        // made blind.
        guard let snap = observation.axSnapshot else {
            return .escalate(reason: .degradedAX)
        }
        if let proof = observedGoal,
           observation.history.last?.echo == .verify,
           observation.history.last?.settleVerified == true,
           proof.matches(task: observation.task, snapshot: snap) {
            return .done(summary: observation.history.contains(where: \.actuated)
                ? observation.task.goal : Self.alreadySatisfiedReason)
        }
        if TaskLoop.successEvidence(in: snap, task: observation.task) {
            return decide(Candidate(draft: .init(id: "done", description: "declared postcondition", kind: .done)),
                          observation: observation)
        }
        let fingerprint = TaskLoop.fingerprint(of: snap)
        if fingerprint == lastFingerprint, !observation.history.isEmpty {
            // A just-dispatched effect is progress in flight, not a
            // stale screen — the first capture after it can precede the
            // app's repaint/AX propagation. Re-observe once rather than
            // act on a pre-delivery view. The lag round itself doesn't
            // count toward the stale stop, but it doesn't erase what
            // already accumulated — a repeated no-op still walks the
            // streak to its bound.
            if observation.history.last?.echo == .act,
               observation.history.last?.actuated == true {
                return .act(.init(effect: .reobserve, tool: "",
                    summary: "the delivered effect hasn't surfaced yet — re-observing"))
            }
            staleStreak += 1
        } else { staleStreak = 0 }
        lastFingerprint = fingerprint

        // A parked text question resolves on the recorded answer — the
        // pick that opened the hole dispatches with the literal, never
        // a re-asked model or a re-picked guess.
        if let pending = pendingTextHole {
            pendingTextHole = nil
            guard let text = observation.history.dropFirst(pending.historyCount).last(where: {
                $0.askKind == .question && $0.askQuestion == pending.question
            })?.askAnswer, !text.isEmpty else {
                return .blocked(reason: .decider(Self.needsTextReason))
            }
            var request = pending.request
            request.args[request.tool == "set_value" ? "value" : "text"] = .string(text)
            return .act(request)
        }

        // The screen stopped changing — either streak reaching the
        // bound is the stale stop.
        let markedStreak = observation.history.reversed()
            .prefix(while: { $0.staleScreen }).count
        if max(staleStreak, markedStreak) >= maxStaleRounds {
            return .escalate(reason: .staleScreen)
        }

        var candidates = buildCandidates(from: snap, task: observation.task)
        var fields: [String: JSONValue] = [:]
        if let extras {
            let extra = await extras(observation)
            candidates += extra.candidates.map(Candidate.init(draft:))
            fields = extra.stateFields
        }
        fields.removeValue(forKey: "executed_replacement")
        fields.removeValue(forKey: "_exact_replacement")
        fields.removeValue(forKey: "semantic_proposal")
        if windowOnly {
            candidates.removeAll {
                if case .request(let request) = $0.kind { return !DriveCandidates.isWindowLocal(request) }
                return false
            }
        }
        fields.merge(DriveCandidates.observationFields(
            elements: snap.elements.map(DriveCandidates.axToDrive),
            candidates: candidates.map(\.draft), goal: observation.task.goal,
            values: observation.task.values)) { _, observed in observed }
        fields.merge(ObservedGoalProof.choiceState(snapshot: snap, task: observation.task,
            originalDocument: observation.nativeDocumentAnchor)) { _, owned in owned }
        if let delivered = observation.deliveredReplacement {
            fields.merge(delivered.fields(observation: observation)) { _, owned in owned }
        }
        if let replacement = NativeReplacementCandidate.make(observation: observation) {
            fields.merge(replacement.fields) { _, owned in owned }
        }
        // Resolve the hint locally; the model gets candidate identity,
        // never the raw gaze sample. Gaze does not filter candidates.
        if let point = await gaze?() {
            markGazeHit(&candidates, point: point)
        }
        let actionCount = candidates.filter { !["done", "reobserve", "stuck"].contains($0.id) }.count
        fields["_action_probability_floor"] = .number(JevChooser.actionProbabilityFloor(
            optionCount: actionCount, confidenceFloor: confidenceFloor))
        if let hint = observation.task.gazeHint {
            fields["gaze_hint"] = .string(hint)
        }

        let picked = try await choose(
            state(observation, snap: snap, candidates: candidates, fields: fields),
            candidates.map { ($0.id, $0.description) })
        try Task.checkCancellation()

        guard let picked,
              var candidate = candidates.first(where: { $0.id == picked.id }) else {
            // An unusable answer re-observes within the bound, then
            // hands up — it never becomes a nearest-guess dispatch.
            invalidPicks += 1
            guard invalidPicks < maxInvalidPicks else {
                return .escalate(reason: .invalidChoice)
            }
            return .act(ActuationRequest(effect: .reobserve, tool: "",
                                       summary: "the pick was unusable — re-observing"))
        }
        invalidPicks = 0

        if let votes = picked.replacementVotes,
           let proof = ObservedGoalProof(exactReplacement: observation, votes: votes,
                broadCompletion: picked.primaryCompletionProbability ?? picked.completionProbability,
                broadSupport: picked.goalFactSupport) {
            observedGoal = proof
            return .act(ActuationRequest(effect: .verifyState, tool: "",
                verification: proof, summary: "verify exact replacement outcome"))
        }

        if picked.doneVote == true,
           let done = candidates.first(where: { $0.id == "done" }) {
            if observation.task.successContains.isEmpty {
                if let id = picked.goalFactID, let model = picked.model,
                   let completion = picked.completionProbability,
                   let selection = picked.goalFactProbability, let support = picked.goalFactSupport,
                   let proof = ObservedGoalProof(task: observation.task, snapshot: snap, factID: id,
                        model: model, completion: completion, selection: selection, support: support) {
                    observedGoal = proof
                    return .act(ActuationRequest(effect: .verifyState, tool: "",
                        verification: proof, summary: "verify the observed goal outcome"))
                }
            }
            return decide(done, observation: observation)
        }
        if picked.model != nil, candidate.id == "done" {
            candidate = candidates.first(where: { $0.id == "reobserve" }) ?? candidate
        }

        if picked.actionRejection != nil {
            lowConfidenceStreak += 1
            guard lowConfidenceStreak < maxLowConfidence else {
                return .escalate(reason: .lowConfidenceTwice)
            }
            return .act(.init(effect: .reobserve, tool: "",
                summary: "the immediate action is uncertain — re-observing"))
        }

        // Below the confidence floor a pick is a guess — re-observe
        // within the bound, then the contract's named escalation.
        let uncertain: Bool
        if !picked.probabilities.isEmpty {
            let floor = JevChooser.actionProbabilityFloor(
                optionCount: actionCount, confidenceFloor: confidenceFloor)
            uncertain = (picked.probabilities[picked.id] ?? 0) < floor
                || (picked.applicability ?? 0) < 0.7
        } else {
            uncertain = picked.confidence.map { $0 < confidenceFloor } ?? false
        }
        if uncertain {
            lowConfidenceStreak += 1
            guard lowConfidenceStreak < maxLowConfidence else {
                return .escalate(reason: .lowConfidenceTwice)
            }
            return .act(ActuationRequest(effect: .reobserve, tool: "",
                summary: "the immediate action is uncertain — re-observing"))
        }
        lowConfidenceStreak = 0

        let decision = decide(candidate, observation: observation)
        if case .act(var request) = decision, let model = picked.model {
            let selection = picked.probabilities[picked.id] ?? picked.confidence ?? 0
            request.replacement = NativeReplacementProposal.make(
                observation: observation, request: request, candidateID: candidate.id,
                model: model, selection: selection)
            return .act(request)
        }
        return decision
    }

    /// Picked candidate → DecideResult. The request carries the element
    /// addressing the snapshot minted (token, or index+snapshot_id) —
    /// pid/window_id are the loop's to stamp.
    private func decide(_ candidate: Candidate,
                        observation: TaskObservation) -> DecideResult {
        switch candidate.kind {
        case .done:
            // The drive loop's done gates: declared success evidence
            // must be visible in this snapshot's tree, and the claim is
            // done for an effect the loop confirmed or "already
            // satisfied" for one it didn't — never a guessed victory.
            let confirmed = observation.history.contains {
                $0.actuated && $0.settleVerified
            }
            if TaskLoop.successEvidence(in: observation.axSnapshot, task: observation.task),
               !observation.history.contains(where: \.settleVerified) {
                return .act(ActuationRequest(effect: .verifyState, tool: "",
                                            summary: "verify the visible postcondition"))
            }
            if !observation.task.successContains.isEmpty {
                if !TaskLoop.successEvidence(in: observation.axSnapshot, task: observation.task) {
                    // On the final round an evidence-less done is NOT a
                    // guess that gets to claim victory — an effect we
                    // dispatched but can't verify is uncertain, and no
                    // effect at all is merely unsatisfied.
                    guard observation.budget.roundsRemaining.map({ $0 > 1 }) ?? true else {
                        return confirmed
                            ? .blocked(reason: .safety(Self.unverifiedDoneReason))
                            : .done(summary: Self.missingEvidenceReason)
                    }
                    return .act(ActuationRequest(effect: .reobserve, tool: "",
                        summary: "the claimed completion isn't on screen — re-observing"))
                }
            }
            return .done(summary: observation.history.contains(where: \.actuated)
                ? observation.task.goal : Self.alreadySatisfiedReason)
        case .abstain:
            return .blocked(reason: .safety(Self.noSafeStepReason))
        case .request(var request):
            if candidate.needsText {
                guard let text = literalText(observation, label: candidate.element?.label ?? request.elementText) else {
                    // One ask per hole — a question already raised and
                    // unanswered is an honest block, not a loop.
                    let lastQuestion = observation.history.last { $0.askKind == .question }
                    guard lastQuestion == nil || lastQuestion?.askAnswer?.isEmpty == false else {
                        return .blocked(reason: .decider(Self.needsTextReason))
                    }
                    let question = "What should I type into \(request.elementText ?? "that field")?"
                    pendingTextHole = (request, observation.history.count, question)
                    return .askUser(question: question, choices: [])
                }
                request.args[request.tool == "set_value" ? "value" : "text"] = .string(text)
            }
            return .act(request)
        }
    }

    /// Literal text for a field: a label-matched `values` entry first,
    /// then the generic "text" literal — every source is user-supplied.
    /// A parked question's answer resolves through `pendingTextHole`,
    /// never by leaking one field's answer into another's.
    private func literalText(_ obs: TaskObservation, label: String?) -> String? {
        DriveCandidates.literalText(values: obs.task.values, label: label)
    }

    // MARK: - Candidates

    /// One pick target — the description the model reads plus the
    /// request the loop would run. Wraps the shared `Draft`.
    private struct Candidate {
        var draft: DriveCandidates.Draft
        var description: String
        var id: String { draft.id }
        var needsText: Bool { draft.needsText }
        var kind: DriveCandidates.Draft.Kind { draft.kind }
        var element: DriveLoop.Element? { draft.element }

        init(draft: DriveCandidates.Draft) {
            self.draft = draft
            self.description = draft.description
        }
    }

    /// Interactive-or-editable rows plus the deterministic candidates —
    /// `DriveCandidates.drafts` is the single build both lanes share.
    private func buildCandidates(from snap: AXSnapshot,
                                 task: TaskBrief) -> [Candidate] {
        let url = task.values["url"]
            ?? (task.goal.hasPrefix("http") ? task.goal : nil)
        return DriveCandidates.drafts(
            elements: snap.elements.map {
                var element = $0
                if Self.isSecure(element) { element.value = nil }
                return DriveCandidates.axToDrive(element)
            },
            snapshotID: snap.snapshotID, windowTitle: snap.windowTitle,
            goal: task.goal, cap: elementCap, url: url
        ).map(Candidate.init(draft:))
    }

    private static func isSecure(_ element: AXElement) -> Bool {
        DriveCandidates.isSecure(role: element.role, label: element.label)
    }

    /// Tag the element candidate under the user's eyes with
    /// "(under your eyes)". Native AX frames and gaze are both global
    /// top-left screen points. The smallest containing frame wins; a
    /// hint, never a filter or reorder.
    /// Gaze narrows the pick without filtering it: the smallest control
    /// under the gaze point reads "(under your eyes)", and up to two more
    /// inside the user's measured error band (2σ) read "(near your gaze)",
    /// so a near-miss fixation still points the chooser at the right one.
    private func markGazeHit(_ candidates: inout [Candidate],
                             point: GazeSample) {
        let frames = candidates.map { $0.element.flatMap { DriveLoop.nativeAXScreenRect($0) } }
        let near = GazeErrorBand.nearest(frames: frames, to: CGPoint(x: point.x, y: point.y),
                                         bandPt: 2 * GazeErrorBand.sigmaPt())
        for (rank, hit) in near.prefix(3).enumerated() {
            candidates[hit.index].description += rank == 0 && hit.distance == 0
                ? " (under your eyes)" : " (near your gaze)"
        }
    }

    /// The state the pick sees — text only, same shape the loop's
    /// observation state has always been: goal, app, window, numbered
    /// options, recent steps, and any context/hint the lane supplies.
    private func state(_ obs: TaskObservation, snap: AXSnapshot,
                       candidates: [Candidate],
                       fields: [String: JSONValue]) -> JSONValue {
        DriveCandidates.stateJSON(
            goal: obs.task.goal,
            app: obs.task.application ?? "",
            window: snap.windowTitle ?? "",
            options: candidates.map { "\($0.id): \($0.description)" },
            recentSteps: obs.history.map { $0.summary },
            context: contextProvider?() ?? obs.task.context,
            snapshotID: snap.snapshotID,
            pid: obs.task.window?.pid,
            fields: fields)
    }
}
