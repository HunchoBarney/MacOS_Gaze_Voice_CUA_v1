import CoreGraphics
import Foundation
import JevVoiceCore
import OSLog

@MainActor
final class CuaVoiceRuntime {
    private static let observationTools: Set<String> = [
        "list_apps", "get_accessibility_tree", "list_windows", "get_window_state",
        "get_browser_state", "parse_visual_regions"
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
        var launchReceipt: CuaLaunchReceipt?
        /// Attempted dispatch only — verified/uncertain effects live in `outcome`.
        var dispatchedEffect = false
        /// The attempt's exact insertion payload and content mode, retained so a
        /// resumed attempt re-executes the same request rather than the resuming
        /// utterance's words. Not a replayable effect — fresh observation still
        /// gates every dispatch.
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
        /// Intent a conversational relationship or prerequisite edge points at.
        var referencedIntentID: UUID?
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

    private let config: Config
    private let judge: CuaTaskAgent.Judge
    private let requiresAPIKey: Bool
    private let makeConnection: () -> CuaConnection
    /// Injectable probe — unit tests must not depend on the host's real
    /// console lock state; production uses the CGSession read below.
    private let screenLocked: () -> Bool
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
    /// The intent's own execution contract — scope, visibility and the literal
    /// payload — recorded when the intent is added. A Work is only an attempt:
    /// a decide-time clarification removes its Work while the intent stays
    /// awaiting an answer, and a resuming answer/retry describes the reply
    /// fragment, not the original request, so the stored contract always wins.
    private struct IntentPayload {
        var literalText: String?
        var contentMode: CuaExecutorDecision.ContentMode
        var scope: String?
        var visibility: String?
    }
    private var intentPayloads: [UUID: IntentPayload] = [:]
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
         screenLocked: @escaping () -> Bool = { CuaVoiceRuntime.consoleScreenLocked }) {
        self.config = config
        self.makeConnection = makeConnection
        self.dialogue = dialogue
        self.screenLocked = screenLocked
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

    private func receive(_ handoff: TranscriptHandoff) async throws {
        if requiresAPIKey, config.apiKey.isEmpty {
            throw DriverConnectionError.refused("Save the Jev API key in Commands settings.")
        }
        nextLabel += 1
        let label = "Jarvis \(nextLabel) · \(instanceLabel)"
        let invocation = Invocation(receivedAt: handoff.receivedAt)
        let agent = makeAgent(invocation: invocation)
        do {
            let previousContext = handoff.taskContext["initial_app"]?.string ?? initialApp
            let decision: CuaExecutorDecision
            if let cachedInventory = appInventory.snapshot() {
                let cachedDecision = try await agent.decide(handoff: handoff,
                    previousContext: previousContext, installedApps: cachedInventory)
                if cachedDecision.operation == .execute ||
                    (cachedDecision.operation == .clarify && cachedDecision.clarification == .target) {
                    let currentInventory = try await makeToolCall(invocation: invocation)("list_apps", [:])
                    decision = currentInventory == cachedInventory ? cachedDecision :
                        try await agent.decide(handoff: handoff, previousContext: previousContext,
                            installedApps: currentInventory)
                } else {
                    decision = cachedDecision
                }
            } else {
                let inventory = try await makeToolCall(invocation: invocation)("list_apps", [:])
                decision = try await agent.decide(handoff: handoff,
                    previousContext: previousContext, installedApps: inventory)
            }
            invocation.timings["Transcript to first Jev decision"] =
                (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
            try Task.checkCancellation()

            switch decision.operation {
            case .wait:
                speech.report(handoff, outcome: "incomplete", message: handoff.final ? "The request is incomplete; no action was taken." : "Listening for a complete request…")
            case .clarify:
                // Record the ambiguous request as an intent awaiting an answer so
                // the next hold's reply binds a real question owner, then present
                // the question with the same surface a plain clarification had.
                let prompt = decision.clarification?.question ?? "What would you like me to do?"
                let range = decision.consumedRange ?? handoff.pendingWordStart..<handoff.pendingWordEnd
                guard !range.isEmpty, let acceptance = speech.validateSource(handoff, wordRange: range) else {
                    speech.report(handoff, outcome: "clarification", message: prompt)
                    return
                }
                do {
                    _ = try acceptIntent(decision: decision, handoff: handoff,
                                         acceptance: acceptance, label: label, invocation: invocation)
                    speech.publishOutcome("clarification", message: prompt)
                } catch {
                    speech.publishOutcome("clarification", message: error.localizedDescription)
                }
                speech.resumePending()
            case .ignore:
                if let range = decision.consumedRange { _ = speech.consume(handoff, wordRange: range) }
            case .stopAll:
                guard let range = decision.consumedRange, speech.consume(handoff, wordRange: range) else {
                    return
                }
                stopAll()
            case .execute, .stop, .correction:
                guard let range = decision.consumedRange, decision.request != nil else {
                    throw DriverConnectionError.malformed
                }
                // Only the utterance's own live text waits for release: a resumed
                // intent's stored payload was finalized in its original hold, so
                // an answer or retry dispatches like any control decision.
                let effectiveMode = decision.contentMode
                if effectiveMode != .control, !handoff.final {
                    let message = effectiveMode == .dictate
                        ? "Dictation will be inserted after you finish speaking."
                        : "Text will be inserted after you finish speaking."
                    speech.report(handoff, outcome: "dictationWaitingForFinal", message: message)
                    return
                }
                // One no-await acceptance transition: validate the source/read set,
                // publish known intent metadata, claim the source, then schedule
                // the worker and the remaining speech.
                guard let acceptance = speech.validateSource(handoff, wordRange: range) else {
                    return
                }
                let work: Work
                do {
                    work = try acceptIntent(decision: decision, handoff: handoff,
                                            acceptance: acceptance, label: label,
                                            invocation: invocation)
                } catch {
                    speech.report(handoff, outcome: "clarification", message: error.localizedDescription)
                    return
                }
                if work.active {
                    work.worker = Task { [weak self] in
                        guard let self else { return }
                        await self.runSelected(decision, handoff: handoff, work: work, agent: agent,
                                               invocation: invocation)
                    }
                    speech.resumePending()
                } else {
                    speech.resumePending()
                }
            }
        } catch {
            throw error
        }
    }

    /// Planned routing for one accepted utterance. Every routing kind either
    /// adds a new intent, resumes an existing one in place, or honestly blocks.
    /// A pending question means the new intent enters awaiting-answer state.
    private struct Routing {
        enum Kind {
            case add(CuaDialogueState.Relationship, CuaDialogueState.Prerequisite?, String?)
            case resume
            case blocked(String)
        }
        let kind: Kind
        let intentID: UUID
        let request: String
        let referencedIntentID: UUID?
        let questionID: UUID?
    }

    private func planRouting(decision: CuaExecutorDecision,
                             acceptance: ContinuousIntentCoordinator.SourceAcceptance) -> Routing {
        let referencedID = decision.selectedTaskID
        let referencedWork = referencedID.flatMap { id in
            tasks.last { $0.id == id } ?? tasks.last { $0.intentID == id }
        }
        let referencedIntentID = referencedWork?.intentID
            ?? referencedID.flatMap { dialogue.entry(for: $0) != nil ? $0 : nil }
        let referencedEntry = referencedIntentID.flatMap { dialogue.entry(for: $0) }

        var route: Routing
        switch decision.relationship {
        case .answer:
            guard let questionID = decision.questionID,
                  let ownerID = dialogue.questionOwner(for: questionID),
                  let owner = dialogue.entry(for: ownerID) else {
                route = Routing(kind: .blocked("That answer no longer matches a pending question."),
                                intentID: UUID(), request: acceptance.text,
                                referencedIntentID: nil, questionID: nil)
                break
            }
            if let revision = decision.intentRevision, revision != owner.revision {
                route = Routing(kind: .blocked("That answer is no longer current; the task changed since the question was asked."),
                                intentID: UUID(), request: acceptance.text,
                                referencedIntentID: ownerID, questionID: questionID)
                break
            }
            route = Routing(kind: .resume, intentID: ownerID, request: owner.intent.instruction,
                            referencedIntentID: ownerID, questionID: questionID)
        case .retry:
            guard let intentID = referencedIntentID, let entry = referencedEntry else {
                route = Routing(kind: .blocked("The task to retry is no longer available."),
                                intentID: UUID(), request: acceptance.text,
                                referencedIntentID: nil, questionID: nil)
                break
            }
            switch entry.status {
            case .cancelled:
                route = Routing(kind: .blocked("The selected task was cancelled; it will not be retried."),
                                intentID: UUID(), request: acceptance.text,
                                referencedIntentID: intentID, questionID: nil)
            case .executing:
                route = Routing(kind: .blocked("The selected task is still running; stop it before retrying."),
                                intentID: UUID(), request: acceptance.text,
                                referencedIntentID: intentID, questionID: nil)
            default:
                route = Routing(kind: .resume, intentID: intentID, request: entry.intent.instruction,
                                referencedIntentID: intentID, questionID: nil)
            }
        default:
            route = planAddedIntent(decision: decision, acceptance: acceptance,
                                    referencedIntentID: referencedIntentID,
                                    referencedEntry: referencedEntry)
        }
        return route
    }

    private func planAddedIntent(decision: CuaExecutorDecision,
                                 acceptance: ContinuousIntentCoordinator.SourceAcceptance,
                                 referencedIntentID: UUID?, referencedEntry: CuaDialogueState.Entry?) -> Routing {
        let intentID = UUID()
        func blocked(_ reason: String) -> Routing {
            Routing(kind: .blocked(reason), intentID: intentID, request: acceptance.text,
                    referencedIntentID: referencedIntentID, questionID: nil)
        }
        let relationship: CuaDialogueState.Relationship
        var prerequisite: CuaDialogueState.Prerequisite?
        switch decision.operation {
        case .correction:
            relationship = referencedEntry != nil ? .correction(of: referencedIntentID!) : .independent
        case .stop, .stopAll, .ignore, .wait:
            relationship = .independent
        case .clarify:
            // An ambiguous request becomes an intent awaiting the user's answer;
            // the question binds its owner so the next hold can resolve it.
            return Routing(kind: .add(.independent, nil,
                                      decision.clarification?.question
                                        ?? "What would you like me to do?"),
                           intentID: intentID, request: acceptance.text,
                           referencedIntentID: nil, questionID: nil)
        case .execute:
            switch decision.relationship {
            case .reference:
                // A context reference is conversational only. It degrades to an
                // independent intent when the referent is gone — never a block.
                relationship = referencedEntry != nil ? .refinement(of: referencedIntentID!) : .independent
            case .continuation:
                guard let intentID = referencedIntentID, referencedEntry != nil else {
                    return blocked("The task that request continues is no longer available.")
                }
                relationship = .continuation(of: intentID)
            case .revision:
                guard let intentID = referencedIntentID, referencedEntry != nil else {
                    return blocked("The task that request revises is no longer available.")
                }
                relationship = .correction(of: intentID)
            case .prerequisite:
                guard let required = referencedIntentID, referencedEntry != nil else {
                    return blocked("The earlier task this request requires is no longer available.")
                }
                guard !createsPrerequisiteCycle(intentID: intentID, requiresIntentID: required) else {
                    return blocked("That request would create a dependency cycle.")
                }
                relationship = .independent
                prerequisite = .init(intentID: intentID, requiresIntentID: required)
            case .independent:
                relationship = .independent
            case .answer, .retry:
                return blocked("The decision could not be routed.")
            }
        }
        return Routing(kind: .add(relationship, prerequisite, nil), intentID: intentID,
                       request: decision.request ?? acceptance.text,
                       referencedIntentID: referencedIntentID, questionID: nil)
    }

    /// Prerequisite edges can only point backwards at already-added intents, so a
    /// true cycle is structurally unreachable; this still rejects any pre-existing
    /// chain that would loop the new intent back to itself.
    private func createsPrerequisiteCycle(intentID: UUID, requiresIntentID: UUID) -> Bool {
        var visited: Set<UUID> = [intentID]
        var current: UUID? = requiresIntentID
        while let id = current {
            guard visited.insert(id).inserted else { return true }
            current = dialogue.entry(for: id)?.prerequisite?.requiresIntentID
        }
        return false
    }

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
            try? dialogue.cancel(intentID: oldest.intent.id, reason: "Resolved to make room for newer requests.")
        }
    }

    /// One no-await transition: validate routing, publish known metadata, claim
    /// the source exactly once, then mutate dialogue state. Context freshness
    /// stays untouched until the source is claimed because nothing on the read
    /// set changes between validate and commit.
    private func acceptIntent(decision: CuaExecutorDecision, handoff: TranscriptHandoff,
                              acceptance: ContinuousIntentCoordinator.SourceAcceptance,
                              label: String, invocation: Invocation) throws -> Work {
        let routing = planRouting(decision: decision, acceptance: acceptance)
        let work = Work(label: label, request: routing.request,
                        intentID: routing.intentID, attemptID: UUID())
        work.provenance = acceptance.provenance
        work.literalText = decision.literalText
        work.contentMode = decision.contentMode
        // Known app/relationship metadata is populated before the task is visible.
        work.bundle = decision.bundleID
        work.referencedIntentID = routing.referencedIntentID
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
            invocation.work = nil
            selectedID = previousSelection
            onChange()
            throw DriverConnectionError.refused("The transcript changed before the request could be accepted.")
        }
        // The source is claimed; only now may routing mutate dialogue state.
        applyRouting(routing, decision: decision, acceptance: acceptance, work: work)
        work.intentRevision = dialogue.entry(for: work.intentID)?.revision ?? 0
        if case .awaitingAnswer = dialogue.entry(for: work.intentID)?.status {
            // A pending question is dialogue-visible, not a running task: the
            // surface stays identical to a plain clarification and the answer
            // resumes the intent through the normal execute path.
            tasks.removeAll { $0.id == work.id }
            invocation.work = nil
            selectedID = previousSelection
        }
        noteChange()
        return work
    }

    private func applyRouting(_ routing: Routing, decision: CuaExecutorDecision,
                              acceptance: ContinuousIntentCoordinator.SourceAcceptance, work: Work) {
        let source = CuaDialogueState.Source(captureID: acceptance.handoff.captureID,
                                             handoffID: acceptance.handoff.id,
                                             revision: acceptance.handoff.revision,
                                             transcriptRanges: [acceptance.wordRange])
        var addedNewIntent = false
        do {
            switch routing.kind {
            case .add(let relationship, let prerequisite, let question):
                try drainUnresolvedForCapacity()
                try dialogue.add(.init(id: routing.intentID, source: source,
                                       utterance: acceptance.text,
                                       instruction: routing.request,
                                       target: intentTarget(for: decision, source: source)),
                                 relationship: relationship, prerequisite: prerequisite)
                addedNewIntent = true
                intentPayloads[routing.intentID] = IntentPayload(literalText: decision.literalText,
                    contentMode: decision.contentMode, scope: decision.scope,
                    visibility: decision.visibility)
                if let question {
                    let ownerEntry = dialogue.entry(for: routing.intentID)
                    let candidates = decision.clarification == .task
                        ? dialogue.entries.filter {
                            $0.intent.id != routing.intentID && !$0.status.isResolved
                        }.map(\.intent.utterance)
                        : []
                    try dialogue.ask(.init(intentID: routing.intentID, prompt: question,
                                           options: candidates,
                                           target: ownerEntry?.intent.target,
                                           revision: ownerEntry?.revision ?? 0))
                    work.message = question
                    work.phase = .waiting
                }
            case .resume:
                switch decision.relationship {
                case .answer:
                    guard let questionID = routing.questionID else {
                        throw CuaDialogueState.TransitionError.invalidQuestion
                    }
                    try dialogue.answer(.init(questionID: questionID, intentID: routing.intentID,
                        revision: dialogue.entry(for: routing.intentID)?.revision ?? 0,
                        source: source, utterance: acceptance.text))
                case .retry:
                    guard let entry = dialogue.entry(for: routing.intentID) else {
                        throw CuaDialogueState.TransitionError.unknownIntent
                    }
                    // A retry resumes the intent in place: uncertain intents keep
                    // their revision and facts; anything else revises forward.
                    if case .uncertain = entry.status { try dialogue.retryUncertain(intentID: routing.intentID) }
                    else { try dialogue.revise(intentID: routing.intentID) }
                default:
                    throw CuaDialogueState.TransitionError.invalidTransition
                }
            case .blocked(let reason):
                // Record the utterance as a resolved intent so it cannot wedge;
                // the Work carries the honest blocked outcome.
                let relationship: CuaDialogueState.Relationship
                if let referenced = routing.referencedIntentID, dialogue.entry(for: referenced) != nil {
                    relationship = .refinement(of: referenced)
                } else {
                    relationship = .independent
                }
                try? drainUnresolvedForCapacity()
                try? dialogue.add(.init(id: routing.intentID, source: source,
                                        utterance: acceptance.text, instruction: routing.request),
                                  relationship: relationship)
                try? dialogue.cancel(intentID: routing.intentID, reason: reason)
                work.outcome = .blocked(reason: reason)
                work.message = reason
                work.active = false
            }
            noteChange()
        } catch {
            // Only an intent this call added may be resolved here. A resume
            // failure must not destroy the existing intent it targeted — the
            // user's earlier question or goal survives to be answered or
            // retried again.
            if addedNewIntent {
                try? dialogue.cancel(intentID: routing.intentID, reason: "The request could not be recorded.")
            }
            work.outcome = .failed(reason: error.localizedDescription)
            work.message = error.localizedDescription
            work.active = false
            noteChange()
        }
    }

    private func intentTarget(for decision: CuaExecutorDecision,
                              source: CuaDialogueState.Source) -> CuaDialogueState.Target? {
        guard let preference = decision.targetPreference else { return nil }
        return .init(
            bundle: preference.bundleID.map { .init(bundleID: $0, displayName: preference.appName) },
            process: preference.processID.map { .init(processIdentifier: Int32($0), bundleID: preference.bundleID) },
            window: preference.windowID.map { .init(windowID: String($0), title: preference.windowTitle) },
            description: preference.appName ?? decision.request ?? "",
            provenance: .source(source))
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
        intentPayloads = intentPayloads.filter { liveIntentIDs.contains($0.key) }
    }

    private func makeAgent(invocation: Invocation) -> CuaTaskAgent {
        CuaTaskAgent(call: makeToolCall(invocation: invocation),
            judge: makeTimedJudge(invocation), generate: { prompt, context, reasoning in
                let accessStarted = ProcessInfo.processInfo.systemUptime
                let client = try {
                    defer { invocation.timings["Provider credential access", default: 0] += (ProcessInfo.processInfo.systemUptime - accessStarted) * 1000 }
                    return try TextProviderSettings.shared.client()
                }()
                let generationStarted = ProcessInfo.processInfo.systemUptime
                defer { invocation.timings["Text generation", default: 0] += (ProcessInfo.processInfo.systemUptime - generationStarted) * 1000 }
                return try await client.generate(prompt: prompt, context: context, reasoning: reasoning)
            }, reasoningAvailable: TextProviderSettings.shared.configured, allowConfirmedRepetition: true, approve: { [weak self] description in
                guard let self, let work = invocation.work else { return false }
                return try await self.requestApproval(description, for: work)
            }, payload: { request, purpose in
                try await JevSpeechIntent(client: JevClient(apiKey: self.config.apiKey)).textPayload(request: request, purpose: purpose)
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
            defer { invocation.timings["Jev execution", default: 0] += (ProcessInfo.processInfo.systemUptime - started) * 1000 }
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

    private func runSelected(_ decision: CuaExecutorDecision, handoff: TranscriptHandoff, work: Work,
                             agent: CuaTaskAgent, invocation: Invocation) async {
        let start = ContinuousClock.now
        do {
            try Task.checkCancellation()
            if work.stopRequested { throw CancellationError() }
            try await beginAttempt(for: work)
            work.phase = .working
            // On a locked console every activation and key event silently
            // no-ops — the driver reports `partial` for each bring_to_front
            // and each step fails with a different confusing message. One
            // session read up front turns the whole class into a single
            // honest refusal instead of a per-step failure trail. `.stop`
            // is bookkeeping only; it still runs.
            if decision.operation != .stop, screenLocked() {
                throw DriverConnectionError.refused("The screen is locked. Unlock it before running computer commands.")
            }
            let outcome: CuaDialogueState.Outcome
            switch decision.operation {
            case .stop:
                outcome = try executeStop(decision, work: work)
            case .correction:
                outcome = try await applyCorrection(decision, work: work, agent: agent,
                    initialApp: handoff.taskContext["initial_app"]?.string ?? "",
                    invocation: invocation)
            case .execute:
                let result = await execute(decision, work: work, agent: agent, invocation: invocation,
                    initialApp: handoff.taskContext["initial_app"]?.string ?? "")
                if let question = Self.pendingQuestion(result.outcome) {
                    // The attempt observed an ambiguity: finish it honestly,
                    // re-open the intent and attach the question the next hold
                    // answers through an .answer decision.
                    let alreadyAnswered = !(dialogue.entry(for: work.intentID)?.answers.isEmpty ?? true)
                    try? dialogue.finish(attemptID: work.attemptID, intentID: work.intentID,
                                         outcome: .blocked(reason: question))
                    if alreadyAnswered {
                        // The user already answered this intent's question and
                        // it still cannot resolve; re-asking only loops.
                        work.message = "Your answer did not resolve it — try restating the request."
                        outcome = .blocked(reason: question)
                    } else {
                        try? dialogue.revise(intentID: work.intentID)
                        if let revision = dialogue.entry(for: work.intentID)?.revision {
                            try? dialogue.ask(.init(intentID: work.intentID, prompt: question,
                                                    options: agent.pendingQuestionOptions,
                                                    target: dialogue.entry(for: work.intentID)?.intent.target,
                                                    revision: revision))
                        }
                        work.message = question
                        outcome = .blocked(reason: question)
                    }
                } else {
                    outcome = mapOutcome(result, work: work)
                }
            default:
                throw DriverConnectionError.malformed
            }
            try Task.checkCancellation()
            work.timings["Transcript to observed result"] = (ProcessInfo.processInfo.systemUptime - handoff.receivedAt) * 1000
            settle(work: work, outcome: outcome)
        } catch is CancellationError {
            settle(work: work, outcome: .cancelled(reason: "Cancelled. Already dispatched effects may have finished."))
        } catch {
            let mapped: CuaDialogueState.Outcome
            if Task.isCancelled || work.stopRequested {
                mapped = .cancelled(reason: "Cancelled. Already dispatched effects may have finished.")
            } else if case .refused(let reason) = error as? DriverConnectionError {
                mapped = .blocked(reason: reason)
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

    /// Published ids are intent ids; resolve a selected id to a task record,
    /// preferring an in-flight attempt when an intent has several works.
    private func workForPublishedID(_ id: UUID) -> Work? {
        tasks.first { $0.id == id }
            ?? tasks.first { $0.intentID == id && $0.active }
            ?? tasks.last { $0.intentID == id }
    }

    private func executeStop(_ decision: CuaExecutorDecision, work: Work) throws -> CuaDialogueState.Outcome {
        guard let id = decision.selectedTaskID, let target = workForPublishedID(id) else {
            throw DriverConnectionError.refused("The selected task is no longer available to stop.")
        }
        cancel(target.id)
        work.message = target.active ? "Stop requested for \(target.label); in-flight effects may finish." : "The selected task has already completed."
        return .verified(evidence: work.message)
    }

    /// The agent gets a fresh structured run every attempt: no raw related-task
    /// window is ever inherited, and references contribute context only.
    private func execute(_ decision: CuaExecutorDecision, work: Work, agent: CuaTaskAgent,
                         invocation: Invocation, initialApp: String) async -> CuaTaskExecutionResult {
        defer {
            work.bundle = agent.bundleID ?? work.bundle
            work.window = agent.windowID ?? work.window
            work.launchReceipt = agent.launchReceipt ?? work.launchReceipt
        }
        var executionDecision = decision
        var context = referencedContext(for: work) ?? initialApp
        if !decision.addsDialogueIntent, let entry = dialogue.entry(for: work.intentID) {
            // Answers and retries resume the intent in place: execution uses the
            // intent's own instruction, with the applied answer kept in context.
            // The intent's stored target supplies an app the resuming utterance
            // did not name, and its previous attempt retains the literal payload
            // so a retry re-executes the same request instead of the empty reply.
            let previous = tasks.last { $0.intentID == work.intentID && $0.id != work.id }
            // An answer/retry utterance is the reply to a question, never the
            // payload itself — "Untitled 21" answers which window, it is not
            // text to insert. Dropping the reply's own literal lets the
            // intent's stored payload restore below.
            let replyOnly = decision.relationship == .answer || decision.relationship == .retry
            var literalText = replyOnly ? nil : decision.literalText
            var contentMode = replyOnly ? .control : decision.contentMode
            // The intent's recorded contract outlives its attempts: a reply that
            // names no payload still re-executes the original literal, and the
            // reply's own scope/visibility can never narrow the request (an
            // answer judged "launch" must not complete a "work" intent early).
            let payload = intentPayloads[work.intentID]
            if literalText == nil, contentMode == .control {
                if let stored = payload?.literalText {
                    literalText = stored
                    contentMode = payload?.contentMode ?? .literal
                } else if let prior = previous?.literalText {
                    literalText = prior
                    contentMode = previous?.contentMode ?? .literal
                }
            }
            var resumed = CuaExecutorDecision(operation: .execute, consumedRange: decision.consumedRange,
                request: entry.intent.instruction, replacementRequest: nil,
                selectedTaskID: nil, dependencyTaskID: nil,
                appName: decision.appName ?? entry.intent.target?.bundle.map { $0.displayName ?? $0.bundleID },
                bundleID: decision.bundleID ?? entry.intent.target?.bundle?.bundleID,
                scope: {
                    // An answer naming one of the offered options picks a
                    // concrete existing target; a stored "create" contract is
                    // contradicted by that choice — the user pointed at the
                    // window to work in, not at a document to make.
                    if payload?.scope == "create",
                       let options = entry.question?.options, !options.isEmpty,
                       let answer = entry.answers.last?.utterance,
                       options.contains(where: {
                           $0.trimmingCharacters(in: .whitespaces).lowercased()
                               == answer.trimmingCharacters(in: .whitespaces).lowercased()
                       }) { return "work" }
                    return payload?.scope ?? decision.scope
                }(),
                visibility: payload?.visibility ?? decision.visibility,
                literalText: literalText, contentMode: contentMode)
            resumed.relationship = decision.relationship
            resumed.targetPreference = decision.targetPreference ?? entry.intent.target.map { stored in
                CuaTargetPreference(
                    appName: stored.application,
                    bundleID: stored.bundle?.bundleID,
                    processID: stored.process.map { Int($0.processIdentifier) },
                    windowID: stored.window.flatMap { Int($0.windowID) },
                    windowTitle: stored.window?.title,
                    provenance: .retained)
            }
            resumed.questionID = decision.questionID
            resumed.intentRevision = decision.intentRevision
            work.bundle = work.bundle ?? resumed.bundleID
            executionDecision = resumed
            if let answer = entry.answers.last {
                context = "Answer to the pending question: \(answer.utterance). " + context
            }
        }
        work.message = "Starting the selected Cua operation…"
        work.phase = .working
        noteChange(progressOnly: true)
        return await agent.executeStructured(executionDecision, context: context,
            actionOwner: CuaActionOwner(taskID: work.id, revision: work.intentRevision),
            acquireApp: { app in
                work.bundle = app
                work.phase = .waiting
                work.message = "Waiting for \(app)…"
                self.noteChange(progressOnly: true)
                let queued = ProcessInfo.processInfo.systemUptime
                try await self.queue.acquire(work.id, app: app)
                invocation.timings["Queue wait", default: 0] += (ProcessInfo.processInfo.systemUptime - queued) * 1000
                work.phase = .working
                self.noteChange(progressOnly: true)
            }, progress: { progress in
                work.message = progress
                self.noteChange(progressOnly: true)
            })
    }

    private func referencedContext(for work: Work) -> String? {
        guard let referencedID = work.referencedIntentID,
              let referenced = tasks.last(where: { $0.intentID == referencedID && $0.id != work.id })
            else { return nil }
        return "Previous task: \(referenced.request). App: \(referenced.bundle ?? ""). Result: \(referenced.message)"
    }

    private static func pendingQuestion(_ outcome: CuaTaskExecutionOutcome) -> String? {
        switch outcome {
        case .clarification(_, let message), .targetAmbiguous(let message): return message
        default: return nil
        }
    }

    /// Structured executor outcomes become dialogue outcomes. Verified facts are
    /// emitted only for observed postconditions bound to this attempt and intent
    /// revision; a plain verified outcome records no fact and cannot discharge a
    /// prerequisite.
    private func mapOutcome(_ result: CuaTaskExecutionResult, work: Work) -> CuaDialogueState.Outcome {
        switch result.outcome {
        case .verified(let evidence):
            let facts = result.postconditions.compactMap { dialogueFact(from: $0, work: work) }
            if let fact = facts.first(where: { $0.kind == .resultObserved }) ?? facts.first {
                return .verifiedFact(fact)
            }
            return .verified(evidence: evidence)
        case .partial(let evidence, let blockedReason):
            return .partial(evidence: evidence, blockedReason: blockedReason,
                            verifiedFacts: result.postconditions.compactMap { dialogueFact(from: $0, work: work) })
        case .uncertain(let reason):
            return .uncertain(reason: reason)
        case .blocked(let reason):
            return (work.stopRequested || Task.isCancelled) ? .cancelled(reason: reason) : .blocked(reason: reason)
        case .failed(let reason):
            return .failed(reason: reason)
        case .clarification(_, let message), .targetAmbiguous(let message):
            return .blocked(reason: message)
        }
    }

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
            try? dialogue.finish(attemptID: work.attemptID, intentID: work.intentID, outcome: outcome)
        } else if dialogue.entry(for: work.intentID)?.status == .pending {
            try? dialogue.cancel(intentID: work.intentID, reason: Self.terminalReason(outcome))
        }
        switch outcome {
        case .cancelled(let reason), .failed(let reason), .blocked(let reason), .uncertain(let reason):
            work.message = reason
        case .partial(_, let blockedReason, _):
            work.message = blockedReason
        case .verified, .verifiedFact:
            break
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

    private func applyCorrection(_ decision: CuaExecutorDecision, work: Work, agent: CuaTaskAgent,
                                 initialApp: String,
                                 invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        guard let id = decision.selectedTaskID, let target = workForPublishedID(id), target.id != work.id else {
            throw DriverConnectionError.refused("The selected task is no longer available to correct.")
        }
        cancel(target.id)
        // An inactive work can still hold a live pending question or an
        // unresolved blocked/uncertain/partial intent: the correction must
        // actually withdraw it, not just claim it was cancelled.
        if !target.active, let status = dialogue.entry(for: target.intentID)?.status,
           !status.isResolved {
            target.stopRequested = true
            try? dialogue.cancel(intentID: target.intentID, reason: "Cancelled.")
            target.outcome = .cancelled(reason: "Cancelled.")
            target.message = "Cancelled."
            noteChange()
        }
        await target.worker?.value
        try Task.checkCancellation()
        if let receipt = target.launchReceipt {
            _ = try await sessionTransport()
            work.phase = .waiting
            work.message = "Checking whether the original launch is unchanged…"
            noteChange(progressOnly: true)
            let queued = ProcessInfo.processInfo.systemUptime
            try await queue.acquire(work.id, app: receipt.bundle)
            invocation.timings["Queue wait", default: 0] += (ProcessInfo.processInfo.systemUptime - queued) * 1000
            work.message = try await receipt.reverse(call: makeToolCall(invocation: invocation,
                useInstalledAppCache: false),
                judge: makeTimedJudge(invocation), approveFocus: {
                    try await self.requestApproval("Temporarily focus \(receipt.bundle) to normally quit the unchanged app launched by \(target.label). No work will be discarded.", for: work)
                })
            queue.release(work.id)
        } else if target.dispatchedEffect {
            throw DriverConnectionError.refused("Pending work stopped. No unchanged launch is eligible for reversal; completed or uncertain effects remain.")
        } else {
            work.message = "The earlier request was cancelled before any computer action was dispatched."
        }

        guard let replacement = decision.replacementExecution else {
            return .verified(evidence: work.message.isEmpty
                ? "The earlier request was retracted." : work.message)
        }
        _ = try await sessionTransport()
        let result = await execute(replacement, work: work, agent: agent, invocation: invocation,
                                   initialApp: initialApp)
        return mapOutcome(result, work: work)
    }

}
