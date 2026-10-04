import CoreGraphics
import Foundation
import JevVoiceCore
import OSLog

@MainActor
final class CuaVoiceRuntime {
    private static let observationTools: Set<String> = [
        "list_apps", "get_accessibility_tree", "list_windows", "get_window_state",
        "get_browser_state", "parse_visual_regions",
        // Raising a window is a precondition for interactive lanes, not a
        // content mutation — a cancelled approval that only ever raised a
        // window dispatched no task effect.
        "bring_to_front"
    ]

    private static func dispatchesEffect(tool: String, arguments: [String: JSONValue]) -> Bool {
        if observationTools.contains(tool) { return false }
        return tool != "browser_dialog" || arguments["action"] != .string("inspect")
    }

    /// One Work is a single execution attempt of a stable dialogue intent.
    /// `status` is derived presentation only: nothing may gate on the string.
    final class Work: Identifiable {
        enum Phase { case queued, waiting, working }
        /// Task identity: selection, approval, cancellation and app leases stay on this ID.
        let id = UUID()
        /// Stable dialogue intent this attempt belongs to.
        let intentID: UUID
        /// Planned dialogue attempt identity; the worker binds it via `dialogue.begin`.
        let attemptID: UUID
        /// Intent revision this attempt was accepted against.
        var intentRevision = 0
        let label: String
        let request: String
        var message = ""
        var bundle: String?
        var window: Int?
        /// Attempted dispatch only — verified/uncertain effects live in `outcome`.
        var dispatchedEffect = false
        /// The utterance's literal insert payload + content mode, kept for the
        /// inspector's "text payload" line. The spec — not replayed words —
        /// always carries the payload to the drive loop.
        var literalText: String?
        var contentMode: CuaExecutorDecision.ContentMode = .control
        var provenance: SpeechProvenance?
        var worker: Task<Void, Never>?
        var elapsedMs: Double = 0
        var timings: [String: Double] = [:]
        var active = true
        var approval: String?
        var approvalContinuation: CheckedContinuation<Bool, Never>?
        var phase: Phase = .queued
        var outcome: CuaDialogueState.Outcome?
        var stopRequested = false
        var attemptBegan = false
        init(label: String, request: String, intentID: UUID, attemptID: UUID) {
            self.label = label; self.request = request
            self.intentID = intentID; self.attemptID = attemptID
        }
        var status: String {
            if approval != nil || approvalContinuation != nil { return "Needs confirmation" }
            if stopRequested { return active ? "Stopping" : "Cancelled" }
            guard active else {
                switch outcome {
                case .verified, .verifiedFact: return "Completed"
                case .partial: return "Partial"
                case .uncertain: return "Uncertain"
                case .blocked, .failed: return "Failed"
                case .cancelled, .none: return "Cancelled"
                }
            }
            switch phase {
            case .queued: return "Queued"
            case .waiting: return "Waiting"
            case .working: return "Working"
            }
        }
    }

    private final class Invocation {
        var work: Work?
        var timings: [String: Double] = [:]
        let receivedAt: Double
        init(receivedAt: Double) { self.receivedAt = receivedAt }
    }

    /// What one accepted utterance became — the worker's dispatch plan.
    private enum AcceptedKind {
        /// Deterministic primitive: zero model calls to resolve, runFastLane proves it.
        case fastLane(CuaTaskAgent.FastResolution, goal: String)
        /// The planner handed a task spec to the drive loop.
        case execute(TaskSpec)
        /// The planner deferred on consent: park for approval, then re-decide.
        /// The consumed span rides along — a compound utterance's remainder
        /// re-decides instead of being spent on the ask.
        case consent(ConsentRequest, consumedThrough: Int?)
        /// The planner stopped a specific earlier intent.
        case cancel(CancelRequest)
        /// The planner corrected an earlier intent — retract or revise.
        case correct(CorrectionRequest)

        /// Leading words of the utterance the decision consumed, when the
        /// planner marked a prefix — nil consumes the whole span.
        var consumedThrough: Int? {
            switch self {
            case .execute(let spec): return spec.consumedThrough
            case .consent(_, let consumed): return consumed
            case .cancel(let request): return request.consumedThrough
            case .correct(let request): return request.consumedThrough
            default: return nil
            }
        }
    }

    private let config: Config
    private let judge: CuaTaskAgent.Judge
    private let requiresAPIKey: Bool
    private let makeConnection: () -> CuaConnection
    /// Injectable probe — unit tests must not depend on the host's real
    /// console lock state; production uses the CGSession read below.
    private let screenLocked: () -> Bool
    /// The utterance planner — one provider call per final utterance.
    /// Injectable: tests drive decisions with a scripted stub; a missing or
    /// failing planner degrades to fast-lane + honest unavailability.
    private let planner: (any CompanionPlanning)?
    /// Persistent-agent seam (delegate / follow-up / memory). Nil means the
    /// agents runtime is not wired and agent decisions refuse honestly.
    /// Settable post-init: the agents runtime starts after the controller's
    /// own runtime exists, so main wires the bridge when it finishes booting.
    var agentBridge: (any AgentBridging)?
    /// Test seam: scripted scenarios disable deterministic preemption so every
    /// utterance reaches the injected planner. Production leaves this nil.
    private let fastLaneResolver: (@MainActor (String, [JSONValue]) -> CuaTaskAgent.FastResolution?)?
    private let queue = CuaWorkQueue()
    private let appInventory = CuaAppInventory()
    private(set) var tasks: [Work] = []
    private(set) var selectedID: UUID?
    private var initialApp = ""
    private var nextLabel = 0
    private let instanceLabel = String(UUID().uuidString.prefix(6))
    /// One driver session per runtime: protected-resource grants — including
    /// existing-profile browser attach — are keyed to (session, transport,
    /// resource). A per-task session re-ran the browser's visible
    /// remote-debugging setup on every command; a per-run session makes the
    /// standing approval actually stick. `end_session` fires at shutdown.
    private var sessionConnection: CuaConnection?

    private var sessionStartTask: Task<CuaConnection, Error>?
    private var sessionLabel: String { "Jarvis runtime · \(instanceLabel)" }
    /// The single owner of intents, attempts, relationships, questions and facts.
    /// Readable for diagnostics and tests; only the runtime mutates it.
    private(set) var dialogue = CuaDialogueState()
    /// The intent's execution contract — the TaskSpec the planner produced —
    /// retained for diagnostics and pruning.
    private var intentSpecs: [UUID: TaskSpec] = [:]
    private var contextVersion = 0
    var onChange: () -> Void = {}

    /// Only these projected context members gate source freshness; progress text,
    /// timings and presentation state can never invalidate a pending decision.
    private static let contextReadSet: [String] = ["task_state", "questions", "focus"]

    lazy var speech: ContinuousIntentCoordinator = {
        let coordinator = ContinuousIntentCoordinator(submit: { [weak self] handoff in
            guard let self else { throw CancellationError() }
            try await self.receive(handoff)
        })
        coordinator.semanticContext = { [weak self] in
            self?.semanticSnapshot() ?? .init(taskContext: .object([:]))
        }
        coordinator.context = { [weak self] in self?.context ?? .object([:]) }
        coordinator.onChange = { [weak self] in self?.onChange() }
        return coordinator
    }()

    /// The CGSession screen-lock read used as the default probe.
    nonisolated static var consoleScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        let users = session["IOConsoleUsers"] as? [[String: Any]] ?? []
        return users.contains { ($0["CGSSessionScreenIsLocked"] as? Bool) == true }
    }

    init(config: Config, makeConnection: @escaping () -> CuaConnection = { CuaConnection() },
         judge: CuaTaskAgent.Judge? = nil, dialogue: CuaDialogueState = CuaDialogueState(),
         planner: (any CompanionPlanning)? = nil,
         agentBridge: (any AgentBridging)? = nil,
         fastLaneResolver: (@MainActor (String, [JSONValue]) -> CuaTaskAgent.FastResolution?)? = nil,
         screenLocked: @escaping () -> Bool = { CuaVoiceRuntime.consoleScreenLocked }) {
        self.config = config
        self.makeConnection = makeConnection
        self.dialogue = dialogue
        self.screenLocked = screenLocked
        self.planner = planner
        self.agentBridge = agentBridge
        self.fastLaneResolver = fastLaneResolver
        if let judge {
            self.judge = judge
            self.requiresAPIKey = false
        } else {
            self.requiresAPIKey = true
            self.judge = { state, questions in
                try await JevClient(apiKey: config.apiKey).systemOne(state: state, questions: questions).response.answers
            }
        }
    }

    var active: Bool { tasks.contains(where: \.active) || speech.busy }
    var message: String {
        if !speech.message.isEmpty,
           ["incomplete", "clarification", "dictationWaitingForFinal"].contains(speech.outcome) {
            return speech.message
        }
        return tasks.first(where: { $0.id == selectedID })?.message ?? speech.message
    }

    /// Relevant dialogue state: every unresolved intent, transitively referenced
    /// entries and bounded resolved history — not a raw history suffix. Semantic
    /// statuses are projected, never Work display strings.
    var context: JSONValue {
        var taskEntries: [JSONValue] = []
        var taskState: [String: JSONValue] = [:]
        var questions: [JSONValue] = []
        var focus = ""
        for entry in dialogue.entries {
            let work = tasks.last { $0.intentID == entry.intent.id }
            // Jev-facing identity is the stable intent id; attempt identity is
            // published separately so resumed attempts never churn the read set.
            let publishedID = entry.intent.id.uuidString
            let status = Self.semanticStatus(entry.status)
            taskEntries.append(.object([
                "id": .string(publishedID),
                "intent_id": .string(entry.intent.id.uuidString),
                "attempt_id": .string(work?.attemptID.uuidString ?? ""),
                "label": .string(work?.label ?? "Intent"),
                "request": .string(entry.intent.utterance),
                "revision": .number(Double(entry.revision)),
                "status": .string(status),
                "app": .string(work?.bundle ?? entry.intent.target?.application ?? ""),
                "result": .string(work?.message ?? "")
            ]))
            taskState[publishedID] = .object([
                "status": .string(status), "revision": .number(Double(entry.revision))])
            if !entry.status.isResolved { focus = publishedID }
            if let question = entry.question,
               entry.status == .awaitingAnswer(questionID: question.id),
               question.revision == entry.revision {
                questions.append(.object([
                    "id": .string(question.id.uuidString),
                    "question": .string(question.prompt),
                    "prompt": .string(question.prompt),
                    "options": .array(question.options.map { .string($0) }),
                    "task": .string(publishedID),
                    "request": .string(entry.intent.utterance),
                    "revision": .number(Double(entry.revision)),
                    "intent_revision": .number(Double(entry.revision))
                ]))
            }
        }
        return .object([
            "initial_app": .string(initialApp),
            "tasks": .array(taskEntries),
            "task_state": .object(taskState),
            "questions": .array(questions),
            "focus": .string(focus)
        ])
    }

    private static func semanticStatus(_ status: CuaDialogueState.Status) -> String {
        switch status {
        case .pending: return "pending"
        case .awaitingAnswer: return "awaitingAnswer"
        case .executing: return "executing"
        case .uncertain: return "uncertain"
        case .partial: return "partial"
        case .blocked: return "blocked"
        case .cancelled: return "cancelled"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }

    private func semanticSnapshot() -> ContinuousIntentCoordinator.SemanticContext {
        .init(taskContext: context, revision: contextVersion, readSet: Self.contextReadSet)
    }

    /// Semantic mutations bump the context version and revalidate a pending
    /// decision; progress-only updates are explicitly not rejudgment triggers.
    private func noteChange(progressOnly: Bool = false) {
        if !progressOnly { contextVersion += 1 }
        speech.semanticStateChanged(progressOnly: progressOnly)
        onChange()
    }

    /// A new capture resets capture state only; dialogue intents, questions and
    /// the explicit selection focus survive the hold boundary.
    func begin(app: String?, captureID: UUID = UUID()) {
        initialApp = app ?? ""
        speech.begin(captureID: captureID)
    }
    func update(_ text: String, final: Bool) { speech.update(text, final: final); onChange() }
    func cancelCapture() { speech.cancel() }
    func cancelSelected() { if let id = selectedID { cancel(id) } }
    func cancel(_ id: UUID) {
        guard let work = tasks.first(where: { $0.id == id }), !work.stopRequested else { return }
        if case .awaitingAnswer = dialogue.entry(for: work.intentID)?.status {
            // Withdrawing a pending question resolves its intent and work.
            work.stopRequested = true
            try? dialogue.cancel(intentID: work.intentID, reason: "Cancelled.")
            work.active = false
            work.outcome = .cancelled(reason: "Cancelled.")
            work.message = "Cancelled."
            noteChange()
            return
        }
        guard work.active else { return }
        // A resolved intent means the attempt already settled and its worker is
        // only running session teardown. Cancelling now would rewrite the
        // recorded outcome and flip the task's status to Cancelled.
        if dialogue.entry(for: work.intentID)?.status.isResolved == true { return }
        resolveApproval(id, approved: false)
        work.stopRequested = true
        work.message = "Stopping; already dispatched effects may finish."
        if let status = dialogue.entry(for: work.intentID)?.status {
            switch status {
            case .executing:
                break // an in-flight attempt unwinds through its worker
            default:
                // A queued intent whose attempt never began still resolves so
                // cancelled utterances cannot wedge unresolved capacity.
                try? dialogue.cancel(intentID: work.intentID, reason: "Cancelled.")
            }
        }
        work.worker?.cancel()
        if work.worker == nil {
            work.active = false
            work.outcome = .cancelled(reason: "Cancelled.")
        }
        noteChange()
    }
    func stopAll() {
        speech.cancel()
        for work in tasks { cancel(work.id) }
        // Withdraw pending questions that never produced a task record.
        for entry in dialogue.entries {
            if case .awaitingAnswer = entry.status {
                try? dialogue.cancel(intentID: entry.intent.id, reason: "Stopped.")
            }
        }
        noteChange()
    }
    func resolveApproval(_ id: UUID, approved: Bool) {
        guard let work = tasks.first(where: { $0.id == id }), let continuation = work.approvalContinuation else { return }
        work.approvalContinuation = nil
        work.approval = nil
        continuation.resume(returning: approved)
        noteChange(progressOnly: true)
    }
    private func requestApproval(_ description: String, for work: Work) async throws -> Bool {
        try Task.checkCancellation()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.approval = description
                work.approvalContinuation = continuation
                work.message = description
                selectedID = work.id
                noteChange(progressOnly: true)
            }
        } onCancel: {
            Task { @MainActor in self.resolveApproval(work.id, approved: false) }
        }
        try Task.checkCancellation()
        if accepted { work.phase = .working; noteChange(progressOnly: true) }
        return accepted
    }
    func select(_ id: UUID) { selectedID = id; onChange() }
    /// The daemon's first calls after system wake stall while its own
    /// session/license checks wait on the returning network — a real user
    /// command shouldn't pay that warm-up. Best-effort: rebuilds a dead
    /// transport and exercises one read; failures are ignored by design.
    func wakeDriverSession() {
        Task { [weak self] in
            guard let connection = try? await self?.sessionTransport() else { return }
            _ = try? await connection.call("check_permissions", arguments: [:])
        }
    }
    func shutdown() async {
        let pendingDecision = speech.cancel()
        for work in tasks where work.active { cancel(work.id) }
        onChange()
        await pendingDecision?.value
        for work in tasks { await work.worker?.value }
        // A session bootstrap can still be in flight when shutdown starts:
        // let it finish so its session is released rather than leaked.
        _ = try? await sessionStartTask?.value
        sessionStartTask = nil
        // One `end_session` per run: the driver releases the run's grants and
        // rolls back remote-debugging setup it performed.
        if let connection = sessionConnection {
            sessionConnection = nil
            _ = try? await connection.call("end_session", arguments: ["session": .string(sessionLabel)], timeout: 5)
            await connection.close()
        }
    }

    // MARK: - Utterance intake

    /// Bare approval/denial words while a work parks on an approval resolve it
    /// directly — deterministic, no model call, and it never reaches the
    /// planner where "yes" could be misread as a request.
    private static func consentVerdict(_ utterance: String) -> Bool? {
        switch utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: .punctuationCharacters) {
        case "yes", "yeah", "yep", "yup", "confirm", "go ahead", "approved",
             "approve", "do it", "ok", "okay", "sure", "continue", "proceed":
            return true
        case "no", "nope", "deny", "denied", "cancel", "don't", "do not",
             "stop", "never mind", "nevermind", "abort":
            return false
        default:
            return nil
        }
    }

    /// Bare stop phrases cancel or withdraw — deterministic, no model call.
    /// A stop phrase inside a longer request falls through to the planner,
    /// which is the correct owner of "click the stop button" style tasks.
    private static func retryVerdict(_ utterance: String) -> Bool {
        switch utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: .punctuationCharacters) {
        case "try that again", "try again", "retry", "retry that",
             "do that again", "redo", "redo that", "run that again":
            return true
        default:
            return false
        }
    }

    /// "Try that again" targets the intent the phrase refers to: a real retry
    /// state — uncertain, partial, blocked or failed — resolves newest first,
    /// a cancelled candidate still answers so the refusal is honest, and with
    /// nothing retryable the earliest resolved intent is the anchored
    /// referent ("the earlier task").
    private func retryTarget(explicitIntentID: UUID? = nil,
                             namedRequest: String? = nil) -> CuaDialogueState.Entry? {
        if let explicitIntentID { return dialogue.entry(for: explicitIntentID) }
        if let namedRequest {
            let needle = namedRequest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let named = dialogue.entries.last(where: {
                $0.intent.instruction.lowercased() == needle
            }) ?? dialogue.entries.last(where: {
                $0.intent.instruction.lowercased().contains(needle)
            }) { return named }
        }
        if let retryable = dialogue.entries.last(where: {
            switch $0.status {
            case .uncertain, .partial, .blocked, .failed, .cancelled: return true
            default: return false
            }
        }) { return retryable }
        return dialogue.entries.first(where: { $0.status.isResolved })
    }

    /// A retry resumes the same intent in place — the fresh Work gets a new
    /// attempt id, never a new intent. The original spec is reused: a retry
    /// never re-plans, so a reply-shaped phrase can't narrow scope. Cancelled
    /// and withdrawn intents refuse honestly; uncertain/partial/blocked keep
    /// their verified facts (same revision), failed/succeeded re-revise.
    private func handleRetry(utterance: String, label: String, invocation: Invocation,
                             explicitTarget: UUID? = nil,
                             provenance: SpeechProvenance? = nil) async {
        let namedRequest: String? = {
            let lower = utterance.lowercased()
            guard let marker = lower.range(of: "try the earlier task again:") else { return nil }
            return String(utterance[marker.upperBound...])
        }()
        guard let target = retryTarget(explicitIntentID: explicitTarget,
                                       namedRequest: namedRequest) else {
            speech.publishOutcome("answer", message: "There is nothing to retry.")
            return
        }
        let work = Work(label: label, request: target.intent.instruction,
                        intentID: target.intent.id, attemptID: UUID())
        work.provenance = provenance
        work.timings = invocation.timings
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        if case .cancelled = target.status {
            work.active = false
            work.outcome = .blocked(reason: "The request was already cancelled; it cannot be retried.")
            work.message = "The request was already cancelled; it cannot be retried."
            noteChange()
            return
        }
        switch target.status {
        case .uncertain:
            try? dialogue.retryUncertain(intentID: target.intent.id)
        default:
            try? dialogue.revise(intentID: target.intent.id)
        }
        work.intentRevision = dialogue.entry(for: target.intent.id)?.revision ?? 0
        noteChange()
        let kind: AcceptedKind
        if let spec = intentSpecs[target.intent.id] {
            kind = .execute(spec)
        } else if let apps = try? await appList(invocation: invocation),
                  let resolved = (fastLaneResolver ?? { goal, list in
                      CuaTaskAgent(call: { _, _ in .object([:]) }).resolveFastLane(goal: goal, apps: list)
                  })(target.intent.instruction, apps) {
            kind = .fastLane(resolved, goal: target.intent.instruction)
        } else {
            kind = .execute(TaskSpec(goal: target.intent.instruction,
                                     application: target.intent.target?.application))
        }
        work.worker = Task { [weak self] in
            guard let self else { return }
            await self.runWork(kind, work: work, invocation: invocation)
        }
    }

    private enum StopVerdict { case all, one, withdraw }
    /// Utterances that introduce literal text — dictate/type/insert led —
    /// whose payload must stay revisable until the release-final handoff.
    private static func isLiteralIntroducer(_ utterance: String) -> Bool {
        let first = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return ["dictate", "type", "insert", "write"].contains(first)
    }

    private static func stopVerdict(_ utterance: String) -> StopVerdict? {
        switch utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: .punctuationCharacters) {
        case "stop everything", "stop all", "cancel everything", "cancel all",
             "abort everything":
            return .all
        case "stop", "stop that", "stop it", "cancel", "cancel that",
             "cancel it", "abort":
            return .one
        case "never mind", "nevermind", "forget it", "forget that":
            return .withdraw
        default:
            return nil
        }
    }

    private func receive(_ handoff: TranscriptHandoff) async throws {
        // An utterance is decidable once its pending span rests on final
        // segments — hold-to-talk streams final phrases mid-hold, so release
        // is not the decision boundary. Genuinely partial text settles inside
        // the coordinator's window and is resubmitted when it finalizes.
        var snapshot = RangedTranscript()
        for range in handoff.audioRanges { _ = try? snapshot.apply(range) }
        let range = handoff.pendingWordStart..<handoff.pendingWordEnd
        guard !range.isEmpty,
              let utterance = try? handoff.text(in: range),
              !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            speech.report(handoff, outcome: "incomplete",
                          message: "The request is incomplete; no action was taken.")
            return
        }

        // Every pending span gets a decision — volatile text included, so a
        // stable prefix pays its model latency once. Only a segment-final or
        // release-final span may materialize (the gate sits after the
        // decision, before any commit); a volatile decision stays a reported
        // candidate the next revision re-decides, never dispatches.
        let materializable = handoff.final
            || snapshot.isFinal(throughWord: handoff.pendingWordEnd)

        nextLabel += 1
        let label = "Jarvis \(nextLabel) · \(instanceLabel)"
        let invocation = Invocation(receivedAt: handoff.receivedAt)
        // A standalone utterance is the whole transcript of this hold — the
        // user's own control words. A span inside a compound utterance
        // ("open X stop it") is routed by the planner, which picks the target
        // a bare phrase cannot.
        let standalone = handoff.pendingWordStart == 0
            && handoff.pendingWordEnd == utterance.split(whereSeparator: \.isWhitespace).count

        // Deterministic control phrases — resolved without any model call,
        // and only once their span may commit.
        if standalone, materializable {
            if let verdict = Self.consentVerdict(utterance) {
                let pending = tasks.filter { $0.approvalContinuation != nil && $0.active }
                if pending.count == 1, let work = pending.first {
                    guard speech.consume(handoff, wordRange: range) else { return }
                    resolveApproval(work.id, approved: verdict)
                    return
                }
                if pending.count > 1 {
                    // One bare "yes" must never arm several asks at once —
                    // the same ambiguity rule the consent surface applies.
                    guard speech.consume(handoff, wordRange: range) else { return }
                    speech.publishOutcome("clarification",
                                          message: "More than one approval is waiting — say which task you mean.")
                    return
                }
            }
            if let verdict = Self.stopVerdict(utterance) {
                handleStop(verdict, handoff: handoff, range: range,
                           label: label, invocation: invocation)
                return
            }
            if Self.retryVerdict(utterance) || utterance.lowercased().hasPrefix("try the earlier task again") {
                guard let acceptance = speech.validateSource(handoff, wordRange: range),
                      speech.commit(acceptance, scheduleRemainder: false) else { return }
                await handleRetry(utterance: utterance, label: label, invocation: invocation,
                                  provenance: acceptance.provenance)
                speech.resumePending()
                return
            }
        }

        var kind: AcceptedKind?
        var decision: PlannerDecision?
        // The deterministic fast lane resolves exact primitives against the
        // installed-app list — "open Safari", "quit Mail" — without a
        // planner call. Ambiguity falls through to the planner unchanged.
        // The same list feeds intent-target binding below, so bundle ids and
        // display names resolve to one identity.
        var fastApps: [JSONValue] = []
        var fastResolution: CuaTaskAgent.FastResolution?
        if let apps = try? await appList(invocation: invocation) {
            fastApps = apps
            fastResolution = (fastLaneResolver ?? { goal, list in
                CuaTaskAgent(call: { _, _ in .object([:]) }).resolveFastLane(goal: goal, apps: list)
            })(utterance, apps)
        }
        if let resolved = fastResolution {
            kind = .fastLane(resolved, goal: utterance)
        } else {
            guard let planner else {
                speech.report(handoff, outcome: "failure",
                              message: "Voice planning is not available in this build. Simple app commands still work.")
                return
            }
            do {
                let context = await plannerContext(utteranceFinal: handoff.final)
                decision = try await planner.decide(utterance: utterance, context: context)
            } catch {
                speech.report(handoff, outcome: "failure",
                              message: "Voice planning is unavailable right now: \(error.localizedDescription)")
                return
            }
            invocation.timings["Transcript to first Jev decision"] =
                (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
            try Task.checkCancellation()
        }

        // A decision on volatile text is a candidate only — the model may
        // still revise, so nothing commits until the span is segment-final
        // or the hold released. Literal holds report their waiting state.
        guard materializable else {
            let literalHold: Bool = {
                if Self.isLiteralIntroducer(utterance) { return true }
                if case .execute(let spec) = decision { return spec.literalText != nil }
                return false
            }()
            speech.report(handoff,
                          outcome: literalHold ? "dictationWaitingForFinal" : "candidate",
                          message: literalHold
                              ? "Dictation will be inserted after you finish speaking."
                              : "Processing transcript…")
            return
        }

        // Multi-span utterances ("open Notes then quit Mail"): the decision
        // declares how many leading words it consumed; the committed prefix
        // reschedules the remainder as its own decision automatically.
        func consumedRange(_ explicit: Int?) -> Range<Int> {
            let used = min(explicit ?? range.count, range.count)
            return range.lowerBound..<(range.lowerBound + used)
        }
        func acceptanceFor(_ explicit: Int?) -> ContinuousIntentCoordinator.SourceAcceptance? {
            speech.validateSource(handoff, wordRange: consumedRange(explicit))
        }

        var immediate: (outcome: String, message: String)?
        if kind == nil, let decision {
            switch decision {
            case .execute(let spec):
                if spec.resolvesPendingQuestion {
                    guard let owner = questionOwner(for: spec.answersQuestionID) else {
                        // A stale answer names no live question — surface an
                        // honest ask rather than silently executing a guess.
                        guard let acceptance = acceptanceFor(spec.consumedThrough) else { return }
                        let question = "Which task do you mean?"
                        acceptClarify(ClarifyRequest(question: question),
                                      acceptance: acceptance, label: label, invocation: invocation)
                        speech.publishOutcome("clarification", message: question)
                        speech.resumePending()
                        return
                    }
                    await resumeAnsweredIntent(owner: owner, spec: spec, utterance: utterance,
                                               handoff: handoff, range: consumedRange(spec.consumedThrough),
                                               label: label, invocation: invocation)
                    speech.resumePending()
                    return
                }
                if spec.literalText != nil, spec.application == nil {
                    // A literal payload with no named target needs its app
                    // first — the stored spec survives for the answer's resume.
                    guard let acceptance = acceptanceFor(spec.consumedThrough) else { return }
                    let question = "Which app should I use?"
                    acceptClarify(ClarifyRequest(question: question),
                                  acceptance: acceptance, label: label, invocation: invocation,
                                  retainedSpec: spec)
                    speech.publishOutcome("clarification", message: question)
                    speech.resumePending()
                    return
                }
                if spec.literalText != nil, !handoff.final {
                    speech.report(handoff, outcome: "dictationWaitingForFinal",
                                  message: "Dictation will be inserted after you finish speaking.")
                    return
                }
                kind = .execute(spec)
            case .consentNeeded(let request, let consumed):
                guard acceptanceFor(consumed) != nil else { return }
                kind = .consent(request, consumedThrough: consumed)
            case .clarify(let request):
                guard let acceptance = acceptanceFor(request.consumedThrough) else { return }
                acceptClarify(request, acceptance: acceptance, label: label, invocation: invocation)
                speech.publishOutcome("clarification", message: request.question)
                speech.resumePending()
                return
            case .answer(let text, let consumed):
                guard let acceptance = acceptanceFor(consumed),
                      speech.commit(acceptance) else { return }
                immediate = ("answer", text)
            case .refuse(let reason, let consumed):
                guard let acceptance = acceptanceFor(consumed),
                      speech.commit(acceptance) else { return }
                immediate = ("incomplete", reason)
            case .cancel(let request):
                if request.stopAll {
                    guard speech.consume(handoff, wordRange: consumedRange(request.consumedThrough)) else { return }
                    stopAll()
                    speech.publishOutcome("answer", message: "Stopped everything.")
                    return
                }
                if request.targetIntentID == nil {
                    // An un-named cancel binds the single live intent —
                    // several live ones is a real question, never stop-all.
                    let live = dialogue.entries.filter { !$0.status.isResolved }
                    guard live.count <= 1 else {
                        guard let acceptance = acceptanceFor(request.consumedThrough) else { return }
                        let question = "Which task should I stop?"
                        acceptClarify(ClarifyRequest(question: question),
                                      acceptance: acceptance, label: label, invocation: invocation)
                        speech.publishOutcome("clarification", message: question)
                        speech.resumePending()
                        return
                    }
                    var bound = request
                    bound.targetIntentID = live.first?.intent.id
                    kind = .cancel(bound)
                    break
                }
                kind = .cancel(request)
            case .correct(let request):
                if request.targetIntentID == nil {
                    let candidates = dialogue.entries.filter { !$0.status.isResolved }
                    if candidates.count > 1 {
                        // An ambiguous correction is a real question — the
                        // referenced intents must not be touched on a guess.
                        guard let acceptance = acceptanceFor(request.consumedThrough) else { return }
                        let question = "Which task do you mean?"
                        acceptClarify(ClarifyRequest(question: question),
                                      acceptance: acceptance, label: label, invocation: invocation)
                        speech.publishOutcome("clarification", message: question)
                        speech.resumePending()
                        return
                    }
                }
                kind = .correct(request)
            case .retry(let request):
                guard let acceptance = acceptanceFor(request.consumedThrough),
                      speech.commit(acceptance, scheduleRemainder: false) else { return }
                await handleRetry(utterance: utterance, label: label, invocation: invocation,
                                  explicitTarget: request.targetIntentID,
                                  provenance: acceptance.provenance)
                speech.resumePending()
                return
            case .delegate(let request):
                guard speech.consume(handoff, wordRange: consumedRange(request.consumedThrough)) else { return }
                immediate = await delegateOutcome(request)
            case .sendToAgent(let slug, let message, let consumed):
                guard speech.consume(handoff, wordRange: consumedRange(consumed)) else { return }
                immediate = await sendToAgentOutcome(slug: slug, message: message)
            case .agentMemory(let slug, let consumed):
                guard speech.consume(handoff, wordRange: consumedRange(consumed)) else { return }
                immediate = await agentMemoryOutcome(slug: slug)
            }
        }
        if let immediate {
            speech.publishOutcome(immediate.outcome, message: immediate.message)
            speech.resumePending()
            return
        }
        // A literal insert resolved before release parks its dispatch until
        // the release-final handoff — the decision re-runs on those same
        // words, so nothing needs storing here.
        if let kind, isLiteralKind(kind), !handoff.final {
            speech.report(handoff, outcome: "dictationWaitingForFinal",
                          message: "Dictation will be inserted after you finish speaking.")
            return
        }
        guard let kind else { return }
        // The first-decision timing covers deterministic resolution too —
        // session bootstrap is inside it, so a fast-lane hit still accounts
        // the wait the user actually paid.
        if invocation.timings["Transcript to first Jev decision"] == nil {
            invocation.timings["Transcript to first Jev decision"] =
                (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
        }

        // Accept the utterance's task: validate the source is still current,
        // claim it exactly once, bind the intent, then spawn the worker.
        let consumed = consumedRange(kind.consumedThrough)
        guard let acceptance = speech.validateSource(handoff, wordRange: consumed) else {
            return
        }
        let work: Work
        do {
            work = try acceptIntent(kind: kind, acceptance: acceptance, label: label,
                                    invocation: invocation, apps: fastApps)
        } catch {
            speech.report(handoff, outcome: "clarification", message: error.localizedDescription)
            return
        }
        if work.active {
            work.worker = Task { [weak self] in
                guard let self else { return }
                await self.runWork(kind, work: work, invocation: invocation)
            }
            if case .consent(let request, _) = kind {
                speech.publishOutcome("clarification", message: request.summary)
            }
            speech.resumePending()
        } else {
            speech.resumePending()
        }
    }

    /// True when the accepted dispatch is a literal insertion — those hold
    /// for the release-final handoff so dictated text stays revisable.
    private func isLiteralKind(_ kind: AcceptedKind) -> Bool {
        switch kind {
        case .execute(let spec): return spec.literalText != nil
        case .fastLane(let resolved, _):
            if case .type = resolved.action?.body { return true }
            return false
        default: return false
        }
    }

    /// A bare stop phrase, applied: everything → stopAll; a pending question →
    /// withdraw it; exactly one running task → cancel; an ambiguous "stop"
    /// becomes a real question — the user is asked, never told something stopped.
    private func handleStop(_ verdict: StopVerdict, handoff: TranscriptHandoff,
                            range: Range<Int>, label: String, invocation: Invocation) {
        switch verdict {
        case .all:
            guard speech.consume(handoff, wordRange: range) else { return }
            stopAll()
            speech.publishOutcome("answer", message: "Stopped everything.")
        case .withdraw:
            guard speech.consume(handoff, wordRange: range) else { return }
            if let awaiting = dialogue.entries.first(where: {
                if case .awaitingAnswer = $0.status { return true }
                return false
            }) {
                try? dialogue.cancel(intentID: awaiting.intent.id, reason: "Withdrawn.")
                if let work = tasks.last(where: { $0.intentID == awaiting.intent.id }) {
                    work.active = false
                    work.outcome = .cancelled(reason: "Withdrawn.")
                    work.message = "Withdrawn."
                }
                noteChange()
                speech.publishOutcome("answer", message: "Withdrawn.")
            } else if let target = tasks.first(where: { $0.id == selectedID && $0.active })
                        ?? tasks.last(where: { $0.active }) {
                cancel(target.id)
                speech.publishOutcome("answer", message: "Cancelled.")
            } else {
                speech.publishOutcome("answer", message: "Nothing to withdraw.")
            }
        case .one:
            let target = tasks.first(where: { $0.id == selectedID && $0.active })
                ?? (tasks.filter { $0.active }.count == 1 ? tasks.last(where: { $0.active }) : nil)
            if let target {
                guard speech.consume(handoff, wordRange: range) else { return }
                cancel(target.id)
                speech.publishOutcome("answer", message: "Stopping \(target.label); dispatched effects may finish.")
            } else {
                guard let acceptance = speech.validateSource(handoff, wordRange: range) else { return }
                let question = "Which assistant task do you mean?"
                acceptClarify(ClarifyRequest(question: question),
                              acceptance: acceptance, label: label, invocation: invocation)
                speech.publishOutcome("clarification", message: question)
            }
        }
    }

    /// The intent a correction binds to — the explicit target, else the most
    /// recent intent that is not the correction itself or already resolved
    /// into nothing.
    private func correctionTarget(_ request: CorrectionRequest,
                                  excluding: UUID? = nil) -> CuaDialogueState.Entry? {
        if let target = request.targetIntentID {
            return dialogue.entry(for: target)
        }
        return dialogue.entries.last { $0.intent.id != excluding }
    }

    /// The intent that owns the question an answer binds to — the named
    /// question when the planner picked one, else the newest pending ask.
    private func questionOwner(for questionID: UUID?) -> CuaDialogueState.Entry? {
        if let questionID, let ownerID = dialogue.questionOwner(for: questionID) {
            return dialogue.entry(for: ownerID)
        }
        return dialogue.pendingClarification?.entry
    }

    /// The pending question an answer resolves — the named one when the
    /// planner picked it, else the newest pending ask.
    private func pendingQuestion(for questionID: UUID?) -> CuaDialogueState.Question? {
        if let questionID {
            return dialogue.entries.lazy.compactMap(\.question).first { $0.id == questionID }
        }
        return dialogue.pendingClarification?.question
    }

    /// The answering spec fills only what the question left open: targeting
    /// fields (app, window, values) merge in; goal, scope, literal payload and
    /// denials always stay with the original — a reply's own shape can never
    /// narrow an earlier request into an easier success.
    private func mergeAnswer(_ answer: TaskSpec, into stored: TaskSpec) -> TaskSpec {
        var merged = stored
        if merged.application == nil { merged.application = answer.application }
        for (key, value) in answer.values where merged.values[key] == nil {
            merged.values[key] = value
        }
        merged.relationship = stored.relationship
        merged.requiresIntentID = stored.requiresIntentID
        return merged
    }

    /// A pending question's intent is superseded by the planner's folded
    /// decision: the answer is recorded on the question (with the answering
    /// utterance's own source), and the awaiting intent closes honestly —
    /// the NEW intent carries the folded goal.
    /// An utterance that answers a pending question resumes the question's
    /// owner intent: `dialogue.answer` records the reply on the question and
    /// re-opens the intent pending with a bumped revision; the fresh Work is a
    /// new attempt carrying the folded spec, never a new intent.
    private func resumeAnsweredIntent(owner: CuaDialogueState.Entry,
                                      spec: TaskSpec,
                                      utterance: String,
                                      handoff: TranscriptHandoff,
                                      range: Range<Int>,
                                      label: String,
                                      invocation: Invocation) async {
        guard let acceptance = speech.validateSource(handoff, wordRange: range),
              let question = pendingQuestion(for: spec.answersQuestionID),
              question.intentID == owner.intent.id else {
            speech.report(handoff, outcome: "incomplete", message: "That answer arrived too late; please ask again.")
            return
        }
        guard speech.commit(acceptance, scheduleRemainder: false) else { return }
        let merged = mergeAnswer(spec, into: intentSpecs[owner.intent.id] ?? spec)
        let source = CuaDialogueState.Source(captureID: acceptance.handoff.captureID,
                                             handoffID: acceptance.handoff.id,
                                             revision: acceptance.handoff.revision,
                                             transcriptRanges: [acceptance.wordRange])
        do {
            try dialogue.answer(.init(questionID: question.id, intentID: owner.intent.id,
                                      revision: owner.revision, source: source,
                                      utterance: utterance))
        } catch {
            speech.publishOutcome("clarification", message: "That answer arrived too late; please ask again.")
            return
        }
        let work = Work(label: label, request: merged.goal,
                        intentID: owner.intent.id, attemptID: UUID())
        work.provenance = acceptance.provenance
        work.literalText = merged.literalText
        work.contentMode = merged.literalText != nil ? .literal : .control
        work.bundle = merged.application
        work.intentRevision = dialogue.entry(for: owner.intent.id)?.revision ?? owner.revision
        work.timings = invocation.timings
        intentSpecs[owner.intent.id] = merged
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        noteChange()
        work.worker = Task { [weak self] in
            guard let self else { return }
            await self.runWork(.execute(merged), work: work, invocation: invocation)
        }
    }

    /// The pending clarification the planner saw, as a ClarifyRequest — the
    /// newest awaiting-answer intent's question.
    private func pendingClarifyRequest() -> ClarifyRequest? {
        guard let pending = dialogue.pendingClarification else { return nil }
        return ClarifyRequest(question: pending.question.prompt,
                              options: pending.question.options)
    }

    /// The lean planner context: recent intents, one pending question or
    /// consent, the agent roster, and a foreground hint.
    private func plannerContext(utteranceFinal: Bool = true) async -> PlannerContext {
        let unresolved = dialogue.entries.filter { !$0.status.isResolved }.map(\.intent.utterance)
        let resolved = dialogue.entries.filter { $0.status.isResolved }
            .suffix(4).map(\.intent.utterance)
        let roster = (await agentBridge?.roster()) ?? []
        return PlannerContext(
            recentIntents: Array((unresolved + resolved).suffix(8)),
            tasks: dialogue.entries.suffix(8).map { entry in
                PlannerTaskRef(intentID: entry.intent.id,
                               request: entry.intent.instruction,
                               status: entry.status.plannerLabel,
                               application: entry.intent.target?.application)
            },
            pendingClarify: pendingClarifyRequest(),
            questions: dialogue.entries.filter {
                if case .awaitingAnswer = $0.status { return true }
                return false
            }.compactMap(\.question).map {
                PendingQuestionRef(questionID: $0.id, intentID: $0.intentID,
                                   prompt: $0.prompt, options: $0.options)
            },
            pendingConsent: dialogue.solePendingConsent,
            agents: roster,
            foregroundHint: initialApp.isEmpty ? nil : initialApp,
            utteranceFinal: utteranceFinal)
    }

    private func appList(invocation: Invocation) async throws -> [JSONValue] {
        let result = try await makeToolCall(invocation: invocation)("list_apps", [:])
        return result["apps"]?.array ?? []
    }

    // MARK: - Intent acceptance

    /// Unresolved capacity is bounded: terminal-ambiguous records (blocked,
    /// uncertain, partial) drain oldest-first so an `add` cannot wedge on them.
    /// Entries with an in-flight attempt are never drained — their settle is
    /// still running — and a genuinely full ledger refuses honestly instead of
    /// dropping live intents or pending questions.
    private func drainUnresolvedForCapacity() throws {
        while dialogue.entries.filter({ !$0.status.isResolved }).count >= dialogue.unresolvedLimit {
            guard let oldest = dialogue.entries.first(where: { entry in
                switch entry.status {
                case .blocked, .uncertain, .partial:
                    return !tasks.contains { $0.intentID == entry.intent.id && $0.active }
                default:
                    return false
                }
            }) else {
                throw DriverConnectionError.refused("Too many unresolved requests remain open; cancel or resolve earlier tasks before asking for more work.")
            }
            // A failed cancel must not spin: the entry that refuses to
            // resolve stays unresolved, so looping again finds the same one.
            do {
                try dialogue.cancel(intentID: oldest.intent.id, reason: "Resolved to make room for newer requests.")
            } catch {
                throw DriverConnectionError.refused("Too many unresolved requests remain open; cancel or resolve earlier tasks before asking for more work.")
            }
        }
    }

    /// An ambiguous request becomes an intent awaiting the answer — the Work
    /// registers the utterance, the question owns the wait, and the intent
    /// resolves when a later utterance supersedes or withdraws it.
    private func acceptClarify(_ request: ClarifyRequest,
                             acceptance: ContinuousIntentCoordinator.SourceAcceptance,
                             label: String, invocation: Invocation,
                             retainedSpec: TaskSpec? = nil) {
        let intentID = UUID()
        let source = CuaDialogueState.Source(captureID: acceptance.handoff.captureID,
                                             handoffID: acceptance.handoff.id,
                                             revision: acceptance.handoff.revision,
                                             transcriptRanges: [acceptance.wordRange])
        // The source is claimed before the intent binds — a commit failure
        // can never leave an orphaned question with unclaimed words behind it.
        guard speech.commit(acceptance, scheduleRemainder: false) else { return }
        do {
            try drainUnresolvedForCapacity()
            try dialogue.add(.init(id: intentID, source: source,
                                   utterance: acceptance.text, instruction: acceptance.text))
            try dialogue.ask(.init(intentID: intentID, prompt: request.question,
                                   options: request.options,
                                   revision: dialogue.entry(for: intentID)?.revision ?? 0))
            if let retainedSpec { intentSpecs[intentID] = retainedSpec }
        } catch {
            try? dialogue.cancel(intentID: intentID, reason: "The question could not be recorded.")
        }
        noteChange()
    }

    /// One no-await transition: the source was validated by the caller; commit
    /// claims it exactly once, then the intent is bound. A commit failure
    /// rolls the Work back so a stale transcript never leaves phantom tasks.
    private func acceptIntent(kind: AcceptedKind,
                              acceptance: ContinuousIntentCoordinator.SourceAcceptance,
                              label: String, invocation: Invocation,
                              apps: [JSONValue] = []) throws -> Work {
        let intentID = UUID()
        let request: String
        switch kind {
        case .fastLane(_, let goal): request = goal
        case .execute: request = acceptance.text
        case .consent(let consent, _): request = consent.summary
        case .cancel: request = acceptance.text
        case .correct(let correction):
            request = correction.replacement?.goal ?? acceptance.text
        }
        let work = Work(label: label, request: request, intentID: intentID, attemptID: UUID())
        work.provenance = acceptance.provenance
        var pendingSpec: TaskSpec?
        if case .execute(let spec) = kind {
            work.literalText = spec.literalText
            work.contentMode = spec.literalText != nil ? .literal : .control
            work.bundle = spec.application
            pendingSpec = spec
        }
        work.timings = invocation.timings
        work.timings["Transcript to submission"] =
            (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
        invocation.work = work
        let previousSelection = selectedID
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        guard speech.commit(acceptance, scheduleRemainder: false) else {
            tasks.removeAll { $0.id == work.id }
            intentSpecs.removeValue(forKey: intentID)
            invocation.work = nil
            selectedID = previousSelection
            onChange()
            throw DriverConnectionError.refused("The transcript changed before the request could be accepted.")
        }
        // The source is claimed; only now may the intent be bound.
        let source = CuaDialogueState.Source(captureID: acceptance.handoff.captureID,
                                             handoffID: acceptance.handoff.id,
                                             revision: acceptance.handoff.revision,
                                             transcriptRanges: [acceptance.wordRange])
        do {
            try drainUnresolvedForCapacity()
            var relationship = CuaDialogueState.Relationship.independent
            var prerequisite: CuaDialogueState.Prerequisite?
            switch kind {
            case .execute(let spec):
                // A follow-up naming a terminal-failed or cancelled intent is
                // conversational context, never an execution dependency.
                func normalized(_ relationship: CuaDialogueState.Relationship,
                                to parent: UUID) -> CuaDialogueState.Relationship {
                    guard let target = dialogue.entry(for: parent) else { return relationship }
                    switch target.status {
                    case .failed, .cancelled, .blocked: return .independent
                    default: return relationship
                    }
                }
                switch spec.relationship {
                case .independent: break
                case .continuation(let parent):
                    relationship = normalized(.continuation(of: parent), to: parent)
                case .correction(let parent):
                    relationship = normalized(.correction(of: parent), to: parent)
                }
                if let required = spec.requiresIntentID {
                    prerequisite = .init(intentID: intentID, requiresIntentID: required)
                }
            case .correct(let correction):
                if let target = correction.targetIntentID ?? correctionTarget(correction)?.intent.id {
                    relationship = .correction(of: target)
                }
            default: break
            }
            try dialogue.add(.init(id: intentID, source: source,
                                   utterance: acceptance.text, instruction: request,
                                   target: intentTarget(for: kind, source: source, apps: apps)),
                             relationship: relationship,
                             prerequisite: prerequisite)
        } catch {
            // The words were already claimed — the refusal's honest record is
            // a settled failed row, never a silent drop or a phantom intent.
            work.active = false
            work.outcome = .failed(reason: error.localizedDescription)
            work.message = error.localizedDescription
            intentSpecs.removeValue(forKey: intentID)
            invocation.work = nil
            noteChange()
            return work
        }
        // The intent is live now — record its spec where pruneWorks keeps it,
        // so an explicit retry can re-execute the same payload in place.
        if let pendingSpec { intentSpecs[intentID] = pendingSpec }
        work.intentRevision = dialogue.entry(for: intentID)?.revision ?? 0
        noteChange()
        return work
    }

    private func intentTarget(for kind: AcceptedKind,
                              source: CuaDialogueState.Source,
                              apps: [JSONValue] = []) -> CuaDialogueState.Target? {
        let app: String?
        var bundle: String?
        switch kind {
        case .fastLane(let resolved, _):
            app = resolved.name; bundle = resolved.bundle
        case .execute(let spec):
            app = spec.application
        case .cancel, .correct, .consent:
            return nil
        }
        guard app != nil || bundle != nil else { return nil }
        if bundle == nil, let app {
            // The named app resolves to its bundle identity against the live
            // list, so facts and pending questions bind the real target.
            bundle = apps.first(where: {
                $0["name"]?.string?.caseInsensitiveCompare(app) == .orderedSame
                    || $0["bundle_id"]?.string?.caseInsensitiveCompare(app) == .orderedSame
            })?["bundle_id"]?.string
        }
        return .init(
            bundle: (bundle ?? app).map { .init(bundleID: $0, displayName: app) },
            description: app ?? bundle ?? "",
            provenance: .source(source))
    }

    /// The planner's stop for a specific intent: withdraw a pending question,
    /// cancel the running work, or report honestly that nothing was live.
    /// The correction work itself is never a candidate for its own target.
    private func runCancelWork(_ request: CancelRequest, work: Work) async -> CuaDialogueState.Outcome {
        let target = request.targetIntentID.flatMap { dialogue.entry(for: $0) }
            ?? dialogue.entries.last { $0.intent.id != work.intentID }
        guard let target else {
            return .verified(evidence: "There was nothing to stop.")
        }
        if case .awaitingAnswer = target.status {
            try? dialogue.cancel(intentID: target.intent.id, reason: "Withdrawn by the user.")
            if let targetWork = tasks.last(where: { $0.intentID == target.intent.id }),
               targetWork.active {
                targetWork.worker?.cancel()
                targetWork.active = false
                targetWork.outcome = .cancelled(reason: "Withdrawn by the user.")
                targetWork.message = "Withdrawn."
            }
            noteChange()
            return .verified(evidence: "Withdrew the pending question.")
        }
        if let targetWork = tasks.last(where: { $0.intentID == target.intent.id && $0.active }) {
            cancel(targetWork.id)
            _ = await targetWork.worker?.value
            return .verified(evidence: "Stopped \(targetWork.label).")
        }
        return .verified(evidence: "Nothing was running for that task.")
    }

    /// A correction: withdraws a question, cancels live work, or unwinds an
    /// effect the target verifiably owns. Reversal is bounded — it only
    /// quits an app the target's own verified launch fact still shows
    /// running, re-observed before and after, never a guessed kill.
    private func runCorrectionWork(_ request: CorrectionRequest, work: Work,
                                   invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        guard let target = correctionTarget(request, excluding: work.intentID) else {
            return .verified(evidence: "There was nothing to correct.")
        }
        if case .awaitingAnswer = target.status {
            try? dialogue.cancel(intentID: target.intent.id, reason: "Withdrawn by the correction.")
            if let targetWork = tasks.last(where: { $0.intentID == target.intent.id }),
               targetWork.active {
                targetWork.worker?.cancel()
                targetWork.active = false
                targetWork.outcome = .cancelled(reason: "Withdrawn by the correction.")
                targetWork.message = "Withdrawn."
            }
            noteChange()
            return .verified(evidence: "Withdrew the pending question.")
        }
        if let targetWork = tasks.last(where: { $0.intentID == target.intent.id && $0.active }) {
            cancel(targetWork.id)
            _ = await targetWork.worker?.value
            return .verified(evidence: "Stopped \(targetWork.label).")
        }
        if request.mode == .revise, let replacement = request.replacement {
            intentSpecs[work.intentID] = replacement
            return try await runExecution(replacement, work: work,
                                          agent: makeAgent(invocation: invocation),
                                          invocation: invocation)
        }
        if request.mode == .retract,
           let fact = target.verifiedFacts.first(where: { $0.kind == .resultObserved }),
           fact.target != nil {
            let callTool = makeToolCall(invocation: invocation, useInstalledAppCache: false)
            // The recorded process identity is the "unchanged" evidence: only
            // the very pid the task launched is reversed — a relaunched or
            // user-restarted app (different pid, same bundle) is left alone,
            // and a transport fault surfaces as uncertain rather than a
            // fabricated "no longer running".
            guard let observedPID = fact.target?.process.map({ Int($0.processIdentifier) }) else {
                return .verified(evidence: "Nothing to undo — the launch left no recorded process.")
            }
            guard try await runningApp(pid: observedPID, call: callTool) else {
                return .verified(evidence: "Nothing to undo — the app is no longer running.")
            }
            _ = try await callTool("invoke_menu", [
                "pid": .number(Double(observedPID)),
                "path": .array([.string("Quit")])
            ])
            if try await runningApp(pid: observedPID, call: callTool) {
                return .uncertain(reason: "The quit was dispatched but the app still reports running.")
            }
            return .verified(evidence: "Closed only the unchanged app launched by that task.")
        }
        return .verified(evidence: "Recorded the correction.")
    }

    /// Whether the recorded target still reports running — the reversal's
    /// re-observation, never trusted from a stale list. Only the recorded pid
    /// matches: it pins the exact process the task owned, so a substitute
    /// instance is never mistaken for it.
    private func runningApp(pid: Int, call: CuaTaskAgent.Call) async throws -> Bool {
        let result = try await call("list_apps", [:])
        return (result["apps"]?.array ?? []).contains {
            $0["pid"]?.integer == pid && $0["running"] != .bool(false)
        }
    }

    /// Active and unresolved intents — plus everything they transitively
    /// reference — are never pruned; only unreferenced resolved work is bounded.
    private func pruneWorks() {
        var protected = Set(dialogue.entries.filter { !$0.status.isResolved }.map { $0.intent.id })
        var frontier = Array(protected)
        while let id = frontier.popLast() {
            guard let entry = dialogue.entry(for: id) else { continue }
            var parents: [UUID] = []
            if let parent = entry.prerequisite?.requiresIntentID { parents.append(parent) }
            switch entry.relationship {
            case .independent: break
            case .refinement(let parent), .continuation(let parent), .correction(let parent):
                parents.append(parent)
            }
            for parent in parents where protected.insert(parent).inserted { frontier.append(parent) }
        }
        while tasks.count > 32, let index = tasks.firstIndex(where: { !$0.active && !protected.contains($0.intentID) }) {
            tasks.remove(at: index)
        }
        let liveIntentIDs = Set(dialogue.entries.map { $0.intent.id })
        intentSpecs = intentSpecs.filter { liveIntentIDs.contains($0.key) }
    }

    // MARK: - Dispatch plumbing

    /// One lease identity per app: a bundle-id-shaped target resolves to its
    /// display name so "com.apple.Safari" and "Safari" share one queue entry.
    /// An unreadable app list keeps the raw spelling — identical spellings
    /// still serialize, which is the common case.
    private func leaseIdentity(for raw: String, invocation: Invocation) async -> String {
        guard raw.contains("."),
              let apps = try? await appList(invocation: invocation),
              let match = apps.first(where: {
                  $0["bundle_id"]?.string?.caseInsensitiveCompare(raw) == .orderedSame }),
              let name = match["name"]?.string, !name.isEmpty else { return raw }
        return name
    }

    private func makeAgent(invocation: Invocation) -> CuaTaskAgent {
        CuaTaskAgent(call: makeToolCall(invocation: invocation, useInstalledAppCache: false),
            approve: { [weak self] description in
                guard let self, let work = invocation.work else { return false }
                return try await self.requestApproval(description, for: work)
            })
    }

    /// The shared live transport, created lazily. A dead one is replaced
    /// wholesale — a fresh proxy must `start_session` again before any tool
    /// call. Two tasks racing to build the first connection funnel through one
    /// serialized bootstrap so neither can orphan a transport or run calls on
    /// a session that was never started.
    private func sessionTransport() async throws -> CuaConnection {
        if let inFlight = sessionStartTask {
            _ = try await inFlight.value
            if let connection = sessionConnection, await connection.connected { return connection }
        }
        if let connection = sessionConnection, await connection.connected { return connection }
        let task = Task { () throws -> CuaConnection in
            if let connection = self.sessionConnection, await connection.connected { return connection }
            let connection = self.makeConnection()
            try await connection.connect()
            if self.sessionConnection != nil {
                // A replaced transport may have left a live daemon-side
                // session under this label — release it before re-starting
                // so session-scoped grants cannot double-accumulate.
                _ = try? await connection.call("end_session", arguments: ["session": .string(self.sessionLabel)], timeout: 5)
            }
            _ = try await connection.call("start_session", arguments: ["session": .string(self.sessionLabel)])
            // Session-scoped cursor policy: the user picks animated-overlay or
            // silent dispatch once, never a per-action mix. Best-effort — a
            // daemon too old for the cursor tools still serves the session.
            _ = try? await connection.call("set_agent_cursor_enabled", arguments: [
                "session": .string(self.sessionLabel),
                "enabled": .bool(self.config.agentCursorEnabled)])
            self.sessionConnection = connection
            return connection
        }
        sessionStartTask = task
        defer { sessionStartTask = nil }
        return try await task.value
    }

    private func makeTimedJudge(_ invocation: Invocation) -> CuaTaskAgent.Judge {
        { state, questions in
            let started = ProcessInfo.processInfo.systemUptime
            defer { invocation.timings["Jev judgment", default: 0] += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
            return try await self.judge(state, questions)
        }
    }

    private func makeToolCall(invocation: Invocation,
                              useInstalledAppCache: Bool = true) -> CuaTaskAgent.Call {
        { tool, arguments in
            try Task.checkCancellation()
            if let work = invocation.work,
               Self.dispatchesEffect(tool: tool, arguments: arguments) {
                work.dispatchedEffect = true
                if work.timings["Transcript to first dispatch"] == nil {
                    let elapsed = (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
                    work.timings["Transcript to first dispatch"] = elapsed
                    invocation.timings["Transcript to first dispatch"] = elapsed
                }
            }
            let started = ProcessInfo.processInfo.systemUptime
            defer { invocation.timings["Cua \(tool)", default: 0] += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
            let arguments = arguments.merging(["session": .string(self.sessionLabel)]) { _, current in current }
            // Resolve the transport per call: a dead connection is replaced
            // and re-sessioned inside sessionTransport, so a reconnect
            // mid-task never strands this closure on a stale transport.
            let connection = try await self.sessionTransport()
            if tool == "list_apps", useInstalledAppCache {
                return try await self.appInventory.read { try await connection.call(tool, arguments: arguments) }
            }
            return try await connection.call(tool, arguments: arguments)
        }
    }

    // MARK: - Worker

    private func runWork(_ kind: AcceptedKind, work: Work, invocation: Invocation) async {
        let start = ContinuousClock.now
        do {
            try Task.checkCancellation()
            if work.stopRequested { throw CancellationError() }
            work.phase = .working
            // On a locked console every activation and key event silently
            // no-ops — the driver reports `partial` for each bring_to_front
            // and each step fails with a different confusing message. One
            // session read up front turns the whole class into a single
            // honest refusal instead of a per-step failure trail.
            if screenLocked() {
                throw DriverConnectionError.refused("The screen is locked. Unlock it before running computer commands.")
            }

            // Every app-bound attempt serializes on the app lease — the fast
            // lane and the drive loop dispatch the same kind of effect.
            let queueApp: String? = {
                switch kind {
                case .execute(let spec): return spec.application
                case .fastLane(let resolved, _): return resolved.name
                case .consent, .cancel, .correct: return nil
                }
            }()
            // A bundle-id-shaped target shares its app's lease — the lease is
            // an app identity, not a spelling, so "com.apple.Safari" and
            // "Safari" can never dispatch concurrently.
            var leaseKey = queueApp
            if let raw = queueApp, !raw.isEmpty {
                leaseKey = await leaseIdentity(for: raw, invocation: invocation)
            }
            if let leaseKey, !leaseKey.isEmpty {
                work.phase = .waiting
                work.message = "Waiting for \(leaseKey)…"
                noteChange(progressOnly: true)
                let queued = ProcessInfo.processInfo.systemUptime
                try await queue.acquire(work.id, app: leaseKey)
                invocation.timings["Queue wait", default: 0] +=
                    (ProcessInfo.processInfo.systemUptime - queued) * 1000
                work.phase = .working
                noteChange(progressOnly: true)
            }
            // "Jev execution" is the execution span — the same measure whether
            // the deterministic lane or the drive loop produced the effects.
            let executionStarted = ProcessInfo.processInfo.systemUptime
            defer {
                invocation.timings["Jev execution", default: 0] +=
                    (ProcessInfo.processInfo.systemUptime - executionStarted) * 1000
            }
            var outcome: CuaDialogueState.Outcome
            switch kind {
            case .consent(let request, _):
                try await beginAttempt(for: work)
                // The consent ask parks the attempt on the existing approval
                // surface — "Needs confirmation" in the task list, voice yes/no
                // and the confirm/cancel buttons resolve it. Recording happens
                // here, at park time, so a stale or failed commit can never
                // leak a pending consent.
                dialogue.recordConsent(request)
                let approved: Bool
                do {
                    approved = try await requestApproval(request.summary, for: work)
                } catch {
                    // A park that never happened must not leave the ask
                    // pending forever — resolve it on the way out.
                    dialogue.resolveConsent(id: request.id, approved: false)
                    throw error
                }
                dialogue.resolveConsent(id: request.id, approved: approved)
                guard approved else {
                    outcome = .blocked(reason: "The request was declined.")
                    break
                }
                // Approved — the planner re-decides the original instruction
                // with the consent resolved; the utterance's words were claimed
                // by the consent intent, so the instruction text decides again.
                guard let planner else {
                    outcome = .blocked(reason: "Planning is not available in this build.")
                    break
                }
                let followup = try await planner.decide(utterance: work.request,
                                                        context: await plannerContext())
                switch followup {
                case .execute(let spec):
                    intentSpecs[work.intentID] = spec
                    outcome = try await runExecution(spec, work: work, agent: makeAgent(invocation: invocation),
                                                     invocation: invocation)
                case .clarify(let clarify):
                    outcome = .blocked(reason: clarify.question)
                case .answer(let text, _):
                    work.message = text
                    outcome = .verified(evidence: text)
                case .refuse(let reason, _):
                    outcome = .blocked(reason: reason)
                case .consentNeeded(let again, _):
                    // A chained ask parks again — approval state reset by the gate.
                    dialogue.recordConsent(again)
                    let reapproved: Bool
                    do {
                        reapproved = try await requestApproval(again.summary, for: work)
                    } catch {
                        dialogue.resolveConsent(id: again.id, approved: false)
                        throw error
                    }
                    dialogue.resolveConsent(id: again.id, approved: reapproved)
                    outcome = reapproved
                        ? .blocked(reason: "The request was approved but needs another pass — please ask again.")
                        : .blocked(reason: "The request was declined.")
                case .delegate, .sendToAgent, .agentMemory, .cancel, .correct, .retry:
                    outcome = .blocked(reason: "The approved request could not be converted to an action.")
                }
            case .fastLane(let resolved, let goal):
                try await beginAttempt(for: work)
                outcome = try await runFastLaneOutcome(resolved, goal: goal, work: work,
                                                       agent: makeAgent(invocation: invocation),
                                                       invocation: invocation)
            case .execute(let spec):
                try await beginAttempt(for: work)
                outcome = try await runExecution(spec, work: work, agent: makeAgent(invocation: invocation),
                                                 invocation: invocation)
            case .cancel(let request):
                try await beginAttempt(for: work)
                outcome = await runCancelWork(request, work: work)
            case .correct(let request):
                try await beginAttempt(for: work)
                outcome = try await runCorrectionWork(request, work: work, invocation: invocation)
            }
            try Task.checkCancellation()
            work.timings["Transcript to observed result"] =
                (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
            settle(work: work, outcome: outcome)
        } catch is CancellationError {
            settle(work: work, outcome: .cancelled(reason: "Cancelled. Already dispatched effects may have finished."))
        } catch {
            let mapped: CuaDialogueState.Outcome
            if Task.isCancelled || work.stopRequested {
                mapped = .cancelled(reason: "Cancelled. Already dispatched effects may have finished.")
            } else if let uncertain = error as? CuaUncertainOutcome {
                mapped = .uncertain(reason: uncertain.localizedDescription)
            } else if let connection = error as? DriverConnectionError {
                switch connection {
                case .refused(let reason), .remote(let reason):
                    mapped = .blocked(reason: reason)
                case .closed, .timedOut:
                    // The transport died after a dispatch could have landed —
                    // the outcome is unknowable, not failed.
                    mapped = .uncertain(reason: connection.localizedDescription)
                case .unavailable:
                    mapped = .blocked(reason: connection.localizedDescription)
                case .malformed, .toolRefused:
                    mapped = .failed(reason: connection.localizedDescription)
                }
            } else {
                mapped = .failed(reason: error.localizedDescription)
            }
            settle(work: work, outcome: mapped)
        }
        for (name, milliseconds) in invocation.timings { work.timings[name] = milliseconds }
        queue.release(work.id)
        let duration = start.duration(to: .now).components
        work.elapsedMs = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        work.active = false
        noteChange()
    }

    /// Bind the planned attempt inside the dialogue. Only an explicit
    /// prerequisite waits — and only for required supported facts, even when
    /// another part of the predecessor failed.
    private func beginAttempt(for work: Work) async throws {
        guard !work.attemptBegan else { return }
        if let prerequisite = dialogue.entry(for: work.intentID)?.prerequisite {
            var visited: Set<UUID> = []
            while true {
                guard let required = dialogue.entry(for: prerequisite.requiresIntentID) else { break }
                let requiredWork = tasks.last { $0.intentID == required.intent.id && $0.active }
                let inFlight: Bool
                if case .executing = required.status { inFlight = requiredWork != nil }
                else { inFlight = required.status == .pending && requiredWork != nil }
                guard inFlight, let awaited = requiredWork, visited.insert(required.intent.id).inserted else { break }
                work.phase = .waiting
                work.message = "Waiting for \(awaited.label)…"
                noteChange(progressOnly: true)
                await awaited.worker?.value
                try Task.checkCancellation()
            }
            guard dialogue.canExecute(work.intentID) else {
                throw DriverConnectionError.refused("The required verified result from the earlier task was not observed. Nothing dependent was executed.")
            }
        }
        guard let entry = dialogue.entry(for: work.intentID), entry.status == .pending else {
            throw DriverConnectionError.refused("The request was already resolved before execution began.")
        }
        try dialogue.begin(.init(id: work.attemptID, intentID: work.intentID,
                               instruction: entry.intent.instruction,
                               target: entry.intent.target, revision: entry.revision))
        work.attemptBegan = true
    }

    /// The deterministic fast lane: zero model calls, postcondition-verified.
    /// A `nil` runFastLane means the primitive resolved but could not dispatch
    /// (e.g. ambiguous field) — the drive loop takes over from real state.
    private func runFastLaneOutcome(_ resolved: CuaTaskAgent.FastResolution, goal: String,
                                    work: Work, agent: CuaTaskAgent,
                                    invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        if let evidence = try await agent.runFastLane(resolved, goal: goal,
            progress: { progress in
                work.message = progress
                self.noteChange(progressOnly: true)
            }) {
            work.bundle = agent.bundleID ?? work.bundle
            return verifiedOutcome(evidence: evidence, agent: agent, work: work)
        }
        // Fast lane declined to dispatch — the drive loop continues from the
        // same intent with the utterance as its goal.
        work.bundle = agent.bundleID ?? work.bundle
        let spec = TaskSpec(goal: goal, application: resolved.name)
        intentSpecs[work.intentID] = spec
        return try await runDriveLoop(spec, work: work, invocation: invocation)
    }

    /// Planner-spec execution: fast-lane retry on the normalized goal first
    /// (the planner's cleaned-up goal often parses where the raw utterance
    /// did not), then the drive loop for everything else.
    private func runExecution(_ spec: TaskSpec, work: Work, agent: CuaTaskAgent,
                              invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        // The deterministic lane covers only a pure open-scope primitive —
        // the whole contract it can satisfy. A spec carrying work, literal
        // text, or targeting constraints belongs to the drive loop, which
        // honors all of them.
        if spec.scope == .open, spec.literalText == nil,
           spec.values.isEmpty, spec.window == nil, spec.deny.isEmpty,
           let apps = try? await appList(invocation: invocation),
           let resolved = agent.resolveFastLane(goal: spec.goal, apps: apps),
           let evidence = try await agent.runFastLane(resolved, goal: spec.goal,
               progress: { progress in
                   work.message = progress
                   self.noteChange(progressOnly: true)
               }) {
            work.bundle = agent.bundleID ?? work.bundle
            return verifiedOutcome(evidence: evidence, agent: agent, work: work)
        }
        return try await runDriveLoop(spec, work: work, invocation: invocation)
    }

    /// The drive loop executes one spec to a `DriveResult`; statuses map to
    /// honest dialogue outcomes. `.needsText` re-opens the intent with a
    /// question the next utterance answers through the normal decision path.
    private func runDriveLoop(_ spec: TaskSpec, work: Work,
                              invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        if requiresAPIKey, config.apiKey.isEmpty {
            return .blocked(reason: "Save the Jev API key in Commands settings to run computer tasks.")
        }
        var values = spec.values
        var goal = spec.goal
        switch spec.scope {
        case .open:
            goal += "\nOnly open or show the app — perform no further actions."
        case .create:
            goal += "\nThe task must produce a new top-level document or window; a pre-existing one does not satisfy it."
        case .work:
            break
        }
        if let literal = spec.literalText {
            values["literal_text"] = literal
            goal += "\nInsert this exact text where the task calls for it: \(literal)"
        }
        // The app lease was taken in runWork for every app-bound kind; the
        // consent follow-up path re-acquires here only if runWork did not —
        // through the same normalization, so spellings can't split the lease.
        if let app = spec.application, !app.isEmpty {
            let queued = ProcessInfo.processInfo.systemUptime
            try await queue.acquire(work.id, app: await leaseIdentity(for: app, invocation: invocation))
            invocation.timings["Queue wait", default: 0] +=
                (ProcessInfo.processInfo.systemUptime - queued) * 1000
        }
        let loop = CuaAgentLoop(call: makeToolCall(invocation: invocation, useInstalledAppCache: false),
            judge: makeTimedJudge(invocation),
            approve: { [weak self] description in
                guard let self else { return false }
                return try await self.requestApproval(description, for: work)
            },
            progress: { progress in
                work.message = progress
                self.noteChange(progressOnly: true)
            })
        let result: DriveResult
        do {
            result = try await loop.drive(DriveTask(
                goal: goal, application: spec.application,
                windowName: spec.window,
                previousContext: dialogue.entry(for: work.intentID)?.answers.last?.utterance,
                scope: spec.scope,
                values: values, deny: spec.deny,
                successContains: spec.successContains))
        } catch {
            let facts = loop.observedPostconditions.compactMap { dialogueFact(from: $0, work: work) }
            guard facts.isEmpty else {
                return .partial(evidence: facts.last?.evidence ?? "Some effects were verified.",
                                blockedReason: error.localizedDescription,
                                verifiedFacts: facts)
            }
            throw error
        }
        work.bundle = result.pid.flatMap { _ in work.bundle }
        if let pendingAsk = pendingLoopQuestion(result.status) {
            // The loop needs an answer the caller never supplied — finish
            // this attempt honestly and re-open the intent with the ask; the
            // answer arrives as a new utterance the planner folds in. Any
            // failed step means a newer decision already owns this intent —
            // the parked ask drops rather than wedging it executing.
            do {
                try dialogue.finish(attemptID: work.attemptID, intentID: work.intentID,
                                    outcome: .blocked(reason: pendingAsk.prompt))
                work.attemptBegan = false
                try dialogue.revise(intentID: work.intentID)
                if let revision = dialogue.entry(for: work.intentID)?.revision {
                    try dialogue.ask(.init(intentID: work.intentID, prompt: pendingAsk.prompt,
                                           options: pendingAsk.options,
                                           target: dialogue.entry(for: work.intentID)?.intent.target,
                                           revision: revision))
                }
                work.message = pendingAsk.prompt
            } catch {
                work.message = "The task was revised while a question was open."
            }
            work.active = false
            noteChange()
            return .blocked(reason: work.message)
        }
        return mapDriveResult(result, work: work, loop: loop)
    }

    private func pendingLoopQuestion(_ status: DriveStatus) -> (prompt: String, options: [String])? {
        switch status {
        case .needsText(let label):
            return ("What text should go in \(label)?", [])
        case .needsWindow(let candidates):
            return ("Which window should I use?", candidates)
        default:
            return nil
        }
    }

    /// Verified with postcondition evidence when the run observed real effects.
    private func verifiedOutcome(evidence: String, agent: CuaTaskAgent,
                                 work: Work) -> CuaDialogueState.Outcome {
        let facts = agent.observedPostconditions.compactMap { dialogueFact(from: $0, work: work) }
        if let fact = facts.first(where: { $0.kind == .resultObserved }) ?? facts.first {
            return .verifiedFact(fact)
        }
        return .verified(evidence: evidence)
    }

    /// Drive statuses become honest dialogue outcomes: nothing is upgraded —
    /// a partial or uncertain run never reports success, and handbacks name
    /// what was observed rather than what was attempted.
    private func mapDriveResult(_ result: DriveResult, work: Work,
                                loop: CuaAgentLoop) -> CuaDialogueState.Outcome {
        let facts = loop.observedPostconditions.compactMap { dialogueFact(from: $0, work: work) }
        let lastStep = result.history.last ?? "the task ended"
        switch result.status {
        case .done:
            if let fact = facts.first(where: { $0.kind == .resultObserved }) ?? facts.first {
                return .verifiedFact(fact)
            }
            return .verified(evidence: lastStep)
        case .handedBack(let reason):
            let detail = result.history.isEmpty
                ? "Nothing was dispatched."
                : "Stopped after: \(lastStep)."
            let honest: String
            switch reason {
            case .lowConfidence:
                honest = "The next step could not be chosen confidently. \(detail)"
            case .noCandidate:
                honest = "No matching control was found on screen. \(detail)"
            case .noInteractiveElements:
                honest = "The window showed no interactive elements. \(detail)"
            case .untrustedAnswer:
                honest = "The proposed action was not trustworthy and was refused. \(detail)"
            }
            return result.history.isEmpty ? .blocked(reason: honest) : .uncertain(reason: honest)
        case .blocked(let reason):
            return (work.stopRequested || Task.isCancelled) ? .cancelled(reason: reason) : .blocked(reason: reason)
        case .blockedByConsent(let reason):
            return .blocked(reason: reason)
        case .needsText(let label):
            return .blocked(reason: "The field \(label) needs text that was never supplied.")
        case .needsWindow(let candidates):
            return .blocked(reason: "The named window is ambiguous among \(candidates.count) live windows.")
        case .maxSteps:
            return .uncertain(reason: "Stopped at the step limit — \(lastStep). The outcome is unverified.")
        case .cancelled:
            return .cancelled(reason: "Cancelled. Already dispatched effects may have finished.")
        }
    }

    // MARK: - Agent delegation outcomes

    private func delegateOutcome(_ request: DelegationRequest) async -> (String, String) {
        guard let agentBridge else {
            return ("refused", "Persistent agents are not available in this build.")
        }
        do {
            return ("answer", try await agentBridge.delegate(request))
        } catch {
            return ("refused", "The agent could not be delegated: \(error.localizedDescription)")
        }
    }

    private func sendToAgentOutcome(slug: String, message: String) async -> (String, String) {
        guard let agentBridge else {
            return ("refused", "Persistent agents are not available in this build.")
        }
        do {
            return ("answer", try await agentBridge.sendToAgent(slug: slug, message: message))
        } catch {
            return ("refused", "The agent could not be reached: \(error.localizedDescription)")
        }
    }

    private func agentMemoryOutcome(slug: String) async -> (String, String) {
        guard let agentBridge else {
            return ("refused", "Persistent agents are not available in this build.")
        }
        do {
            return ("answer", try await agentBridge.agentMemory(slug: slug))
        } catch {
            return ("refused", "The agent's memory could not be read: \(error.localizedDescription)")
        }
    }

    // MARK: - Settlement

    /// Bind an observed postcondition to the producing attempt and intent
    /// revision. A target fact with no bindable target is dropped, never fabricated.
    private func dialogueFact(from postcondition: CuaObservedPostcondition, work: Work) -> CuaDialogueState.VerifiedFact? {
        let kind: CuaDialogueState.FactKind = postcondition.kind == .targetObserved ? .targetObserved : .resultObserved
        let bundleID = postcondition.bundleID ?? work.bundle
        var target: CuaDialogueState.Target?
        if bundleID != nil || postcondition.windowID != nil || postcondition.processID != nil {
            target = .init(
                bundle: bundleID.map { .init(bundleID: $0, displayName: postcondition.appName) },
                process: postcondition.processID.map { .init(processIdentifier: Int32($0), bundleID: bundleID) },
                window: postcondition.windowID.map { .init(windowID: String($0), title: postcondition.windowTitle) },
                description: postcondition.evidence,
                provenance: .observed(attemptID: work.attemptID))
        }
        if kind == .targetObserved, target == nil { return nil }
        return .init(kind: kind, intentID: work.intentID, attemptID: work.attemptID,
                     revision: work.intentRevision, target: target, evidence: postcondition.evidence)
    }

    /// Finish the dialogue attempt, or resolve a never-begun intent so blocked
    /// and cancelled utterances cannot accumulate against unresolved capacity.
    private func settle(work: Work, outcome: CuaDialogueState.Outcome) {
        if work.attemptBegan {
            do {
                try dialogue.finish(attemptID: work.attemptID, intentID: work.intentID, outcome: outcome)
            } catch {
                // A finish that fails means a newer decision already moved
                // this intent — cancel is the same honest end, never a wedge.
                try? dialogue.cancel(intentID: work.intentID, reason: Self.terminalReason(outcome))
            }
        } else if dialogue.entry(for: work.intentID)?.status == .pending {
            try? dialogue.cancel(intentID: work.intentID, reason: Self.terminalReason(outcome))
        }
        switch outcome {
        case .cancelled(let reason), .failed(let reason), .blocked(let reason), .uncertain(let reason):
            work.message = reason
        case .partial(_, let blockedReason, _):
            work.message = blockedReason
        case .verified(let evidence):
            work.message = evidence
        case .verifiedFact(let fact):
            work.message = fact.evidence
        }
        work.outcome = outcome
        noteChange()
    }

    private static func terminalReason(_ outcome: CuaDialogueState.Outcome) -> String {
        switch outcome {
        case .cancelled(let reason), .failed(let reason), .blocked(let reason), .uncertain(let reason):
            return reason
        case .partial(let evidence, let blockedReason, _):
            return "\(evidence) — \(blockedReason)"
        case .verified(let evidence):
            return evidence
        case .verifiedFact(let fact):
            return fact.evidence
        }
    }

}


private extension CuaDialogueState.Status {
    /// The compact label the planner sees for a task it may reference.
    var plannerLabel: String {
        switch self {
        case .pending: return "pending"
        case .awaitingAnswer: return "awaitingAnswer"
        case .executing: return "executing"
        case .uncertain: return "uncertain"
        case .partial: return "partial"
        case .blocked: return "blocked"
        case .cancelled: return "cancelled"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }
}
