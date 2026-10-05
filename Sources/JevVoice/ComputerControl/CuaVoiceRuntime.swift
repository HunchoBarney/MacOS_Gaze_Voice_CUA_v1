import CoreGraphics
import Foundation
import JevVoiceCore
import OSLog

@MainActor
final class CuaVoiceRuntime {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "cua-runtime")

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
        var contentMode: CuaContentMode = .control
        var provenance: SpeechProvenance?
        var worker: Task<Void, Never>?
        var elapsedMs: Double = 0
        var timings: [String: Double] = [:]
        var active = true
        /// The attempt parked on a dialogue question — its [question] push is
        /// the live ask, so settle must not contradict it with a "blocked"
        /// outcome or show the task as failed.
        var questionParked = false
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

    /// What one accepted instruction became — the worker's dispatch plan.
    /// The realtime model's tool choice IS the decision; this is only the
    /// deterministic-route vs drive-loop split.
    private enum AcceptedKind {
        /// Deterministic primitive: zero model calls to resolve, runFastLane proves it.
        case fastLane(CuaTaskAgent.FastResolution, goal: String)
        /// The instruction runs the observe → judge → dispatch → verify loop.
        case execute(TaskSpec)
    }

    private let config: Config
    private let judge: CuaTaskAgent.Judge
    private let requiresAPIKey: Bool
    private let makeConnection: () -> CuaConnection
    /// Injectable probe — unit tests must not depend on the host's real
    /// console lock state; production uses the CGSession read below.
    private let screenLocked: () -> Bool
    /// Persistent-agent seam (delegate / follow-up / memory). Nil means the
    /// agents runtime is not wired and agent decisions refuse honestly.
    /// Settable post-init: the agents runtime starts after the controller's
    /// own runtime exists, so main wires the bridge when it finishes booting.
    var agentBridge: (any AgentBridging)?
    /// Test seam: scripted scenarios stub deterministic fast-lane resolution.
    /// Production leaves this nil and uses CuaTaskAgent.resolveFastLane.
    /// (goal, appHint, frontmostBundleOverride, apps) — the override is the
    /// app frontmost before Jarvis's own UI took key status; an accessory app
    /// frontmost mid-turn must not steal "frontmost" targeting.
    private let fastLaneResolver: (@MainActor (String, String?, String?, [JSONValue]) -> CuaTaskAgent.FastResolution?)?
    /// Front-app check handed to each drive loop — real NSWorkspace in
    /// production; simulated drivers pretend their fixture app is frontmost.
    private let isFrontmostApp: ((Int) -> Bool)?
    private let queue = CuaWorkQueue()
    private let appInventory = CuaAppInventory()
    private(set) var tasks: [Work] = []
    private(set) var selectedID: UUID?

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
    /// The intent's execution contract — the TaskSpec bound at spawn —
    /// retained for question-resume merging and diagnostics.
    private var intentSpecs: [UUID: TaskSpec] = [:]
    var onChange: () -> Void = {}

    /// Live decision feed — every real transition (heard, routed, dispatched,
    /// verified, answered) appended at the point it happens. The Activity tab
    /// renders it; nothing here is logged speculatively.
    let feed = DecisionFeed()

    /// The CGSession screen-lock read used as the default probe.
    nonisolated static var consoleScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        let users = session["IOConsoleUsers"] as? [[String: Any]] ?? []
        return users.contains { ($0["CGSSessionScreenIsLocked"] as? Bool) == true }
    }

    init(config: Config, makeConnection: @escaping () -> CuaConnection = { CuaConnection() },
         judge: CuaTaskAgent.Judge? = nil, dialogue: CuaDialogueState = CuaDialogueState(),
         agentBridge: (any AgentBridging)? = nil,
         fastLaneResolver: (@MainActor (String, String?, String?, [JSONValue]) -> CuaTaskAgent.FastResolution?)? = nil,
         screenLocked: @escaping () -> Bool = { CuaVoiceRuntime.consoleScreenLocked },
         isFrontmostApp: ((Int) -> Bool)? = nil) {
        self.config = config
        self.makeConnection = makeConnection
        self.dialogue = dialogue
        self.screenLocked = screenLocked
        self.agentBridge = agentBridge
        self.fastLaneResolver = fastLaneResolver
        self.isFrontmostApp = isFrontmostApp
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

    /// A deterministic floor under the planner's `foreground` flag: a request
    /// phrased "open/show/launch X" asks for the app in front whether or not
    /// the model set the flag, unless the utterance explicitly says the work
    /// belongs in the background.
    static func wantsForeground(_ utterance: String) -> Bool {
        let text = utterance.lowercased()
        guard !text.contains("background") else { return false }
        // Whole-word match — "reopen the doc" or "startup disk" must not be
        // read as an open/start foreground request.
        return text.range(
            of: #"\b(?:open|launch|show|bring|switch to|start)\b"#,
            options: .regularExpression) != nil
    }

    var active: Bool { tasks.contains(where: \.active) }
    var message: String {
        if let pending = dialogue.pendingClarification { return pending.question.prompt }
        return tasks.first(where: { $0.id == selectedID })?.message ?? ""
    }

    private func noteChange() { onChange() }

    // MARK: - Realtime lane entry

    /// Between-turn pushes to the voice lane — settled outcomes, parked
    /// consents, parked questions. Args: captureID, text, speak.
    var taskEventSink: ((UUID, String, Bool) -> Void)?

    private func pushTaskEvent(_ work: Work, _ text: String, speak: Bool) {
        guard let captureID = work.provenance?.captureID else { return }
        taskEventSink?(captureID, text, speak)
    }

    /// The realtime lane's `computer_command` tool entry — the model's tool
    /// choice already IS the decision, so this goes straight to routing: fast
    /// lane when the instruction is deterministic, else the drive loop. It
    /// returns the moment the work is accepted; the verified outcome arrives
    /// later as a pushed `[task outcome]` message. No waiters, no timers.
    func beginVoiceTask(_ instruction: String, app: String?,
                        frontmostHint: String? = nil, literalText: String? = nil,
                        transcriptHint: String? = nil,
                        captureID: UUID = UUID()) async -> String {
        var trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No instruction was provided." }
        // The realtime model sometimes emits the same call twice — an
        // identical instruction still live (running or parked on an ask)
        // must not run a second time.
        let key = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
        if let dupe = tasks.last(where: {
            $0.request.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ").lowercased() == key
                && ($0.active || $0.questionParked || $0.approvalContinuation != nil)
        }) {
            return "That request is already running — \"\(dupe.request)\". A [task outcome] message arrives when it finishes."
        }
        feed.add(.heard, trimmed)
        let invocation = Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)
        nextLabel += 1
        let label = "Jarvis \(nextLabel) · \(instanceLabel)"
        var apps: [JSONValue] = []
        var resolution: CuaTaskAgent.FastResolution?
        do {
            apps = try await appList(invocation: invocation)
            // The tool args can diverge from the model's own transcript of
            // the user's words — when both parse as "open X" naming DIFFERENT
            // installed apps, what the user said is ground truth.
            if let heard = transcriptHint?.trimmingCharacters(in: .whitespacesAndNewlines),
               !heard.isEmpty, heard.lowercased() != trimmed.lowercased(),
               let heardOpen = CuaFastAction.parseOpen(heard),
               let calledOpen = CuaFastAction.parseOpen(trimmed),
               heardOpen.query.lowercased() != calledOpen.query.lowercased(),
               let heardApp = CuaFastAction.resolveOpenApp(query: heardOpen.query,
                                                         apps: apps, frontmostBundle: nil),
               let calledApp = CuaFastAction.resolveOpenApp(query: calledOpen.query,
                                                          apps: apps, frontmostBundle: nil),
               heardApp.bundle != calledApp.bundle {
                Self.log.notice("voice_transcript_divergence heard=\"\(heard, privacy: .public)\" called=\"\(trimmed, privacy: .public)\"")
                trimmed = heard
            }
            // The controller captured who was frontmost before our own UI —
            // resolve that name to a bundle so an accessory app being
            // frontmost can't steal generic-command targeting.
            let frontmostBundle = frontmostHint.flatMap { hint in
                (apps.first { $0["name"]?.string?.localizedCaseInsensitiveCompare(hint) == .orderedSame })?["bundle_id"]?.string
            }
            resolution = (fastLaneResolver ?? { goal, hint, frontmost, list in
                CuaTaskAgent(call: { _, _ in .object([:]) })
                    .resolveFastLane(goal: goal, apps: list, appHint: hint,
                                     frontmostBundleOverride: frontmost)
            })(trimmed, app, frontmostBundle, apps)
        } catch {
            Self.log.notice("fast_lane_app_list_failed error=\(error.localizedDescription, privacy: .public)")
            feed.add(.error, "The computer-use driver isn't reachable — the task will retry it directly.")
        }
        let kind: AcceptedKind
        if let resolution {
            feed.add(.route, "Fast lane: \(resolution.openVerb ?? "run") \(resolution.name)")
            kind = .fastLane(resolution, goal: trimmed)
        } else {
            let literal = literalText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let spec = TaskSpec(goal: trimmed, application: app,
                                literalText: literal?.isEmpty == false ? literal : nil,
                                foreground: Self.wantsForeground(trimmed))
            kind = .execute(spec)
            feed.add(.route, "Drive loop — \(trimmed)")
        }
        let work = spawnVoiceWork(kind: kind, label: label, invocation: invocation,
                                  apps: apps, captureID: captureID, utterance: trimmed)
        guard work.active else {
            Self.log.notice("voice_task_rejected \"\(trimmed, privacy: .public)\" app=\(app ?? "-", privacy: .public)")
            return work.message.isEmpty ? "The task could not be started." : work.message
        }
        let lane = resolution != nil ? "fast" : "drive"
        Self.log.notice("voice_task_started lane=\(lane, privacy: .public) app=\(app ?? "-", privacy: .public) \"\(trimmed, privacy: .public)\"")
        return "STARTED — \(work.request). Acknowledge briefly; a [task outcome] message arrives when it finishes."
    }

    /// Spawns a Work for a voice instruction — same shape as acceptIntent but
    /// no transcript commit: the lane's tool argument is already final text.
    private func spawnVoiceWork(kind: AcceptedKind, label: String, invocation: Invocation,
                                apps: [JSONValue], captureID: UUID, utterance: String) -> Work {
        let intentID = UUID()
        let request: String
        switch kind {
        case .fastLane(_, let goal): request = goal
        default: request = utterance
        }
        let wordCount = max(1, utterance.split(whereSeparator: \.isWhitespace).count)
        let work = Work(label: label, request: request, intentID: intentID, attemptID: UUID())
        work.provenance = SpeechProvenance(captureID: captureID)
        if case .execute(let spec) = kind {
            work.literalText = spec.literalText
            work.contentMode = spec.literalText != nil ? .literal : .control
            work.bundle = spec.application
            intentSpecs[intentID] = spec
        } else if case .fastLane(let resolution, _) = kind {
            work.bundle = resolution.bundle
        }
        work.timings = invocation.timings
        work.timings["Transcript to submission"] =
            (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
        invocation.work = work
        let previousSelection = selectedID
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        let source = CuaDialogueState.Source(captureID: captureID, handoffID: UUID(),
                                             revision: 0, transcriptRanges: [0 ..< wordCount])
        do {
            try drainUnresolvedForCapacity()
            try dialogue.add(.init(id: intentID, source: source, utterance: utterance,
                                   instruction: request,
                                   target: intentTarget(for: kind, source: source, apps: apps)))
        } catch {
            work.active = false
            // The real refusal (e.g. unresolved-capacity) reaches the model —
            // "could not be accepted" tells it nothing to correct.
            work.outcome = .failed(reason: error.localizedDescription)
            work.message = error.localizedDescription
            intentSpecs.removeValue(forKey: intentID)
            selectedID = previousSelection
            noteChange()
            return work
        }
        work.intentRevision = dialogue.entry(for: intentID)?.revision ?? 0
        work.worker = Task { [weak self] in
            await self?.runWork(kind, work: work, invocation: invocation)
        }
        noteChange()
        return work
    }

    /// `respond_to_task` — resolves the newest parked ask: a yes/no consent on
    /// a running work, or a free-text question answer that resumes its intent.
    /// Returns nil when nothing is waiting, so the caller can fall through to
    /// other consent surfaces (the agent gate).
    func respondToTask(_ answer: String, captureID: UUID = UUID()) async -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let work = tasks.last(where: { $0.approvalContinuation != nil && $0.active }) {
            guard let verdict = Self.consentVerdict(trimmed) else {
                return "Please answer yes or no — \"\(work.approval ?? work.request)\" is still waiting."
            }
            resolveApproval(work.id, approved: verdict)
            return verdict ? "Approved — the action is running." : "Denied — the action was not run."
        }
        guard let pending = dialogue.pendingClarification else { return nil }
        // A denial word is a cancel, not an answer — "never mind"/"stop it"
        // must withdraw the ask, not resume the task with "never mind"
        // merged into its spec.
        if let denied = Self.questionDenied(trimmed), denied {
            if let work = tasks.last(where: { $0.intentID == pending.entry.intent.id }) {
                cancel(work.id)
            } else {
                try? dialogue.cancel(intentID: pending.entry.intent.id, reason: "Cancelled by the user.")
            }
            return "Cancelled — nothing further runs."
        }
        return await resumeAnsweredQuestion(owner: pending.entry, question: pending.question,
                                            answer: trimmed, captureID: captureID)
    }

    /// Cancel-shaped utterances that should withdraw a parked question
    /// rather than resume it. "no" alone is deliberately absent — a yes/no
    /// clarification needs it as a legitimate answer.
    static func questionDenied(_ text: String) -> Bool? {
        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let cancels = ["never mind", "cancel", "cancel that", "stop", "stop it",
                       "forget it", "forget that", "abort", "don't", "do not",
                       "leave it", "skip it", "no thanks", "nah"]
        return cancels.contains(normalized) || normalized.hasPrefix("don't ")
    }

    /// A spoken answer resumes the question's owner intent in place — same
    /// mechanism the planner's resolvesPendingQuestion used, minus the model
    /// hop: the dialogue answer merges into a fresh attempt on the same intent.
    private func resumeAnsweredQuestion(owner: CuaDialogueState.Entry,
                                        question: CuaDialogueState.Question,
                                        answer: String, captureID: UUID) async -> String {
        let wordCount = max(1, answer.split(whereSeparator: \.isWhitespace).count)
        let source = CuaDialogueState.Source(captureID: captureID, handoffID: UUID(),
                                             revision: owner.revision,
                                             transcriptRanges: [0 ..< wordCount])
        do {
            try dialogue.answer(.init(questionID: question.id, intentID: owner.intent.id,
                                      revision: owner.revision, source: source, utterance: answer))
        } catch {
            return "That answer arrived too late — the task is no longer waiting. Repeat the instruction."
        }
        var spec = intentSpecs[owner.intent.id]
            ?? TaskSpec(goal: owner.intent.instruction,
                        application: owner.intent.target?.application)
        if !question.options.isEmpty {
            // A window/other-choice question — the answer selects an option
            // or carries the raw title.
            spec.window = question.options.first {
                $0.localizedCaseInsensitiveContains(answer)
                    || answer.localizedCaseInsensitiveContains($0)
            } ?? answer
        } else {
            spec.values["answer"] = answer
            spec.goal += "\nThe user answered \"\(question.prompt)\": \(answer)"
        }
        intentSpecs[owner.intent.id] = spec
        let invocation = Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)
        nextLabel += 1
        let work = Work(label: "Jarvis \(nextLabel) · \(instanceLabel)",
                        request: owner.intent.instruction,
                        intentID: owner.intent.id, attemptID: UUID())
        work.provenance = SpeechProvenance(captureID: captureID)
        work.literalText = spec.literalText
        work.contentMode = spec.literalText != nil ? .literal : .control
        work.bundle = spec.application
        work.timings = invocation.timings
        invocation.work = work
        work.intentRevision = dialogue.entry(for: owner.intent.id)?.revision ?? owner.revision
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        work.worker = Task { [weak self] in
            await self?.runWork(.execute(spec), work: work, invocation: invocation)
        }
        noteChange()
        return "Resuming \"\(owner.intent.instruction)\" — acknowledge briefly; a [task outcome] message arrives when it finishes."
    }

    /// `cancel_task` — a hint matches by request text, label or app; bare
    /// "cancel that" stops the newest running work. A question-parked work
    /// reads as inactive but is still cancellable — without it "cancel that"
    /// says "nothing is running" while an ask sits live.
    func cancelVoiceTask(_ hint: String?) -> String {
        let live = tasks.filter {
            $0.active || (dialogue.entry(for: $0.intentID).map {
                if case .awaitingAnswer = $0.status { return true }
                return false
            } ?? false)
        }
        guard !live.isEmpty else { return "Nothing is running." }
        let trimmed = (hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "all" || trimmed == "everything" {
            stopAll()
            return "Stopping everything."
        }
        let match = live.last {
            $0.request.lowercased().contains(trimmed)
                || $0.label.lowercased().contains(trimmed)
                || ($0.bundle?.lowercased().contains(trimmed) ?? false)
        } ?? (live.count == 1 ? live[0] : nil)
        guard let match else {
            return "Which task — \(live.map { "\"\($0.request)\"" }.joined(separator: " or "))?"
        }
        cancel(match.id)
        return "Stopping \"\(match.request)\"."
    }

    /// `delegate_to_agent` — hands the task to a persistent background agent
    /// (Clicky's sessions_*). The bridge already returns an acknowledgement,
    /// never a completion claim.
    func delegateToAgent(task: String, agent: String?, name: String?,
                         role: String?, description: String?) async -> String {
        guard let agentBridge else { return "No agent backend is configured in this build." }
        do {
            return try await agentBridge.delegate(DelegationRequest(
                agentSlug: agent, newAgentName: name, newAgentRole: role,
                newAgentDescription: description, message: task))
        } catch {
            return "The agent could not be reached: \(error.localizedDescription)"
        }
    }

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
        noteChange()
    }
    private func requestApproval(_ description: String, for work: Work) async throws -> Bool {
        try Task.checkCancellation()
        // Always-allow standing grant — the user opted out of per-action
        // confirmation; the driver still enforces deny lists and scope rules.
        guard !CuaStandingGrants.computerUseInput else { return true }
        feed.add(.consent, description)
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.approval = description
                work.approvalContinuation = continuation
                work.message = description
                selectedID = work.id
                pushTaskEvent(work, "[needs confirmation] \(description) Ask the user to confirm; when they answer, call respond_to_task.", speak: true)
                noteChange()
            }
        } onCancel: {
            Task { @MainActor in self.resolveApproval(work.id, approved: false) }
        }
        try Task.checkCancellation()
        if accepted { work.phase = .working; noteChange() }
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
        for work in tasks where work.active { cancel(work.id) }
        onChange()
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

    /// Deterministic retry — the UI's retry action and a voice "retry that"
    /// land here. Resumes the same intent in place: the fresh Work gets a new
    /// attempt id, never a new intent. The original spec is reused — a retry
    /// never re-plans. Cancelled intents refuse honestly; uncertain/partial/
    /// blocked keep their verified facts; failed/succeeded re-revise.
    func retryWork(_ workID: UUID) async -> String {
        guard let anchor = tasks.first(where: { $0.id == workID }) else {
            return "That task is gone."
        }
        guard let target = retryTarget(explicitIntentID: anchor.intentID) else {
            return "There is nothing to retry."
        }
        let invocation = Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)
        nextLabel += 1
        let work = Work(label: "Jarvis \(nextLabel) · \(instanceLabel)",
                        request: target.intent.instruction,
                        intentID: target.intent.id, attemptID: UUID())
        work.provenance = anchor.provenance
        work.timings = invocation.timings
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        if case .cancelled = target.status {
            work.active = false
            work.outcome = .blocked(reason: "The request was already cancelled; it cannot be retried.")
            work.message = "The request was already cancelled; it cannot be retried."
            noteChange()
            return work.message
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
                  let resolved = (fastLaneResolver ?? { goal, hint, frontmost, list in
                      CuaTaskAgent(call: { _, _ in .object([:]) })
                          .resolveFastLane(goal: goal, apps: list, appHint: hint,
                                           frontmostBundleOverride: frontmost)
                  })(target.intent.instruction, nil, nil, apps) {
            kind = .fastLane(resolved, goal: target.intent.instruction)
        } else {
            kind = .execute(TaskSpec(goal: target.intent.instruction,
                                     application: target.intent.target?.application))
        }
        work.worker = Task { [weak self] in
            guard let self else { return }
            await self.runWork(kind, work: work, invocation: invocation)
        }
        return "Trying again: \(String(target.intent.instruction.prefix(60)))"
    }


    /// The app roster changes on a human timescale — a ~5s cache collapses
    /// the per-command driver roundtrip without going stale between commands.
    /// Connect and list apps at launch — the first computer_command would
    /// otherwise pay the driver spawn + handshake (~2.5s) inside the turn.
    func warm() {
        Task { _ = try? await appList(invocation: Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)) }
    }

    private var appListCache: (fetched: TimeInterval, apps: [JSONValue])?
    private func appList(invocation: Invocation) async throws -> [JSONValue] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = appListCache {
            let age = now - cached.fetched
            if age < 15 { return cached.apps }
            if age < 45 {
                // Stale-while-revalidate: routing needs only names — the fresh
                // read lands for the next turn rather than stalling this one
                // on a ~2s list_apps roundtrip. Dispatch authority always
                // comes from the loop's own fresh reads.
                Task { [weak self] in
                    guard let self,
                          let result = try? await self.makeToolCall(
                              invocation: Invocation(receivedAt: now),
                              useInstalledAppCache: false)("list_apps", [:]),
                          let apps = result["apps"]?.array else { return }
                    self.appListCache = (ProcessInfo.processInfo.systemUptime, apps)
                }
                return cached.apps
            }
        }
        // Bypass the 60s inventory cache — the running/pid hints drive
        // fast-lane candidacy and must reflect this read's own freshness.
        let result = try await makeToolCall(invocation: invocation,
                                            useInstalledAppCache: false)("list_apps", [:])
        let apps = result["apps"]?.array ?? []
        appListCache = (ProcessInfo.processInfo.systemUptime, apps)
        return apps
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
        // Check-and-set is atomic here: every state check (including the
        // connected re-check) happens INSIDE the task, so two callers racing
        // a reconnect-after-death both join one bootstrap instead of
        // duplicating daemons or tombstoning each other's sessions.
        if let inFlight = sessionStartTask { return try await inFlight.value }
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
                noteChange()
                let queued = ProcessInfo.processInfo.systemUptime
                try await queue.acquire(work.id, app: leaseKey)
                invocation.timings["Queue wait", default: 0] +=
                    (ProcessInfo.processInfo.systemUptime - queued) * 1000
                work.phase = .working
                noteChange()
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
            case .fastLane(let resolved, let goal):
                try await beginAttempt(for: work)
                outcome = try await runFastLaneOutcome(resolved, goal: goal, work: work,
                                                       agent: makeAgent(invocation: invocation),
                                                       invocation: invocation)
            case .execute(let spec):
                try await beginAttempt(for: work)
                outcome = try await runExecution(spec, work: work, agent: makeAgent(invocation: invocation),
                                                 invocation: invocation)
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
                noteChange()
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
                self.noteChange()
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
                   self.noteChange()
               }) {
            work.bundle = agent.bundleID ?? work.bundle
            return verifiedOutcome(evidence: evidence, agent: agent, work: work)
        }
        return try await runDriveLoop(spec, work: work, invocation: invocation)
    }

    /// The drive loop executes one spec to a `DriveResult`; statuses map to
    /// honest dialogue outcomes. `.needsText` re-opens the intent with a
    /// question the next utterance answers through the normal decision path.
    /// Recover the verbatim query from a "search for X" / "look up X" /
    /// "find X" / "play X" goal. Matches run on the ORIGINAL string with word
    /// boundaries — "display" never trips "play", and indices stay valid for
    /// any casing. The LAST marker wins ("use the search bar and play X"
    /// captures X), falling back to earlier markers when the last yields a
    /// stopword ("play X and search for it" still lands X). Meta-tails cut
    /// at " then " / " and <verb>" / " please" — a plain " and " survives so
    /// "Simon and Garfunkel" keeps its name. A trailing " in <app>" naming
    /// the spec's application is stripped.
    static func impliedQuery(in goal: String, app: String?) -> String? {
        let pattern = #"\b(search for|searching for|search|look up|looking up|lookup|google|find|play|queue|listen to|watch|put on)\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let matches = regex.matches(in: goal, range: NSRange(goal.startIndex..., in: goal))
        // Last-to-first: the most recent marker owns the payload; a marker
        // whose tail is pure meta-language defers to the one before it.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: goal) else { continue }
            let marker = String(goal[range]).lowercased()
            var query = String(goal[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Cut meta-command tails — "play X then close the app" queries
            // only X; " and " cuts only when a meta-verb follows so titles
            // like "Simon and Garfunkel" stay whole.
            let tailPattern = #"( then\b| and then\b| and (search|find|play|queue|listen|watch|google|look up|open|close|press|click|type|hit|enter|go|send|select|choose|pick)\b| and after\b| afterwards\b| after that\b| next\b|, then\b|,\s| please\b|\.\s)"#
            if let tailRegex = try? NSRegularExpression(pattern: tailPattern, options: [.caseInsensitive]),
               let cut = tailRegex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
               let cutRange = Range(cut.range, in: query) {
                query = String(query[..<cutRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if marker.hasPrefix("search"), query.lowercased().hasPrefix("for ") {
                query = String(query.dropFirst(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let app, !app.isEmpty {
                let tail = " " + app.lowercased()
                for preposition in [" in", " on", " within", " inside", " using"] {
                    let suffix = preposition + tail
                    if query.lowercased().hasSuffix(suffix) {
                        query = String(query.dropLast(suffix.count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
            let lowered = query.lowercased()
            guard !query.isEmpty,
                  !["for", "in", "on", "at", "the", "it", "that", "this", "them",
                    "pause", "resume", "stop", "music", "the video", "the track",
                    "the result", "the song", "that song", "the one"].contains(lowered)
            else { continue }
            return query
        }
        return nil
    }

    private func runDriveLoop(_ spec: TaskSpec, work: Work,
                              invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        if requiresAPIKey, config.apiKey.isEmpty {
            return .blocked(reason: "Save the Jev API key in Commands settings to run computer tasks.")
        }
        var values = spec.values
        var goal = spec.goal
        // A search/lookup utterance's query is verbatim payload; when the
        // planner left it out of `values`, recover it from the goal so the
        // loop can type it rather than hunt for a search affordance blind.
        if values["query"] == nil, let query = Self.impliedQuery(in: spec.goal, app: spec.application) {
            values["query"] = query
        }
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
            // The inspector's app identity is the resolved bundle id, never
            // the planner's spelling — the loop's own resolution lands in
            // DriveResult, but "Working" needs the real id while it runs.
            if !app.contains("."),
               let apps = try? await appList(invocation: invocation),
               let real = apps.first(where: {
                   $0["name"]?.string?.caseInsensitiveCompare(app) == .orderedSame
               })?["bundle_id"]?.string {
                work.bundle = real
                noteChange()
            }
        }
        let loop = CuaAgentLoop(call: makeToolCall(invocation: invocation, useInstalledAppCache: false),
            judge: makeTimedJudge(invocation),
            approve: { [weak self] description in
                guard let self else { return false }
                return try await self.requestApproval(description, for: work)
            },
            progress: { progress in
                work.message = progress
                self.noteChange()
            },
            isFrontmostApp: isFrontmostApp)
        let result: DriveResult
        do {
            result = try await loop.drive(DriveTask(
                goal: goal, application: spec.application,
                windowName: spec.window,
                previousContext: dialogue.entry(for: work.intentID)?.answers.last?.utterance,
                scope: spec.scope,
                values: values, deny: spec.deny,
                successContains: spec.successContains,
                foreground: spec.foreground
                    || Self.wantsForeground(dialogue.entry(for: work.intentID)?.intent.utterance ?? goal)))
        } catch {
            let facts = loop.observedPostconditions.compactMap { dialogueFact(from: $0, work: work) }
            guard facts.isEmpty else {
                return .partial(evidence: facts.last?.evidence ?? "Some effects were verified.",
                                blockedReason: error.localizedDescription,
                                verifiedFacts: facts)
            }
            throw error
        }
        work.bundle = result.bundleID ?? work.bundle
        work.window = result.windowID ?? work.window
        if let pendingAsk = pendingLoopQuestion(result.status) {
            // The loop needs an answer the caller never supplied — finish
            // this attempt honestly and re-open the intent with the ask; the
            // answer arrives via respond_to_task and resumes in place. Any
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
                let options = pendingAsk.options.isEmpty ? ""
                    : " Options: \(pendingAsk.options.joined(separator: ", "))."
                pushTaskEvent(work, "[question] \(pendingAsk.prompt)\(options) Ask the user; when they answer, call respond_to_task.", speak: true)
            } catch {
                work.message = "The task was revised while a question was open."
            }
            work.questionParked = true
            work.active = false
            noteChange()
            return .blocked(reason: work.message)
        }
        return mapDriveResult(result, work: work, loop: loop)
    }

    private func pendingLoopQuestion(_ status: DriveStatus) -> (prompt: String, options: [String])? {
        switch status {
        case .needsText(let label):
            // The label is often the field's own prompt ("What do you want to
            // play?") — quoting it asks better than nesting it in ours.
            let prompt = label.hasSuffix("?") || label.hasSuffix(":")
                ? label : "What text should go in \(label)?"
            return (prompt, [])
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
        if work.questionParked {
            // The [question] push already told the model the task waits —
            // a "blocked" outcome now would contradict a live ask and read
            // as failure while the question still expects an answer.
            work.outcome = outcome
            noteChange()
            return
        }
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
        switch outcome {
        case .verified, .verifiedFact:
            feed.add(.verify, work.message)
        case .partial:
            feed.add(.outcome, "Partial — \(work.message)")
        case .cancelled:
            feed.add(.outcome, work.message)
        case .failed, .blocked, .uncertain:
            feed.add(.error, work.message)
        }
        // Tell the lane what happened — the model speaks the verdict aloud.
        // Cancelled work stays context-only: the user stopped it, they know.
        let verdict = Self.outcomeWord(outcome)
        Self.log.notice("voice_task_settled \(verdict, privacy: .public) \"\(work.request, privacy: .public)\" — \(work.message, privacy: .public)")
        pushTaskEvent(work, "[task outcome] \(work.request): \(verdict) — \(work.message)",
                      speak: !outcome.isCancelled)
        noteChange()
    }

    /// The one-word verdict the model reads in a `[task outcome]` push.
    private static func outcomeWord(_ outcome: CuaDialogueState.Outcome) -> String {
        switch outcome {
        case .verified, .verifiedFact: return "done"
        case .partial: return "partially done"
        case .blocked: return "blocked"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .uncertain: return "uncertain"
        }
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


private extension CuaDialogueState.Outcome {
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
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
