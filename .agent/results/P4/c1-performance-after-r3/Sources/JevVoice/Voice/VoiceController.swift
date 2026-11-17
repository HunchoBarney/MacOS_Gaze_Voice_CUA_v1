import AppKit
import AVFoundation
import Combine
import OSLog
import JevVoiceCore

extension VoiceAdmissionContext {
    @MainActor static func observedAppEntities() -> [Entity] {
        var entities = NSWorkspace.shared.runningApplications.compactMap { app -> Entity? in
            guard app.activationPolicy == .regular,
                  let name = app.localizedName, let id = app.bundleIdentifier else { return nil }
            return .init(name: name, id: id, canOpenLocally: true)
        }
        for directory in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            where name.hasSuffix(".app") {
                guard let bundle = Bundle(path: directory + "/" + name), let id = bundle.bundleIdentifier,
                      !entities.contains(where: { $0.id == id }) else { continue }
                let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? String(name.dropLast(4))
                entities.append(.init(name: display, id: id, canOpenLocally: true))
            }
        }
        return entities
    }

    /// LaunchServices lookup only: this neither opens URLs nor reads accounts.
    @MainActor static func observedAppRoles() -> [String: String] {
        var roles: [String: String] = [:]
        for (scheme, example) in [
            ("https", "https://example.invalid"), ("mailto", "mailto:example@example.invalid")
        ] {
            if let url = URL(string: example),
               let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
               let id = Bundle(url: appURL)?.bundleIdentifier { roles[scheme] = id }
        }
        return roles
    }
}

struct VoiceTimings {
    var finalization: TimeInterval = 2
    var warning: TimeInterval = 50
    var limit: TimeInterval = 55
    var dismissal: TimeInterval = 1.5
}

@MainActor
final class VoiceController: ObservableObject {
    /// The app builds exactly one controller (main.swift); the gaze dwell
    /// suppressor (Lane 4) reaches `captureActive` through this seam.
    /// Weak so test instances never pin each other — last writer wins.
    static weak var shared: VoiceController?
    enum Status: Equatable {
        case idle, starting, listening, finishing, awaitingRelease, reviewTranscript
        case thinking, awaitingConfirm, executing, stopping, testingMicrophone, done
        /// A pending clarification: an ordinary dialogue state carrying the
        /// question prompt, never an Open-settings style error.
        case awaitingAnswer(String)
        case error(String)
    }
    enum CaptureState { case idle, starting, listening, finishing, awaitingRelease, testingMicrophone, stopping }
    @Published private(set) var captureState: CaptureState = .idle
    @Published private var presentation: Status = .idle
    // Task progress lives in the coordinator. It never replaces an active capture's state.
    private(set) var status: Status {
        get {
            switch captureState {
            case .idle: return presentation
            case .starting: return .starting
            case .listening: return .listening
            case .finishing: return .finishing
            case .awaitingRelease: return .awaitingRelease
            case .testingMicrophone: return .testingMicrophone
            case .stopping: return .stopping
            }
        }
        set {
            switch newValue {
            case .starting: captureState = .starting
            case .listening: captureState = .listening
            case .finishing: captureState = .finishing
            case .awaitingRelease: captureState = .awaitingRelease
            case .testingMicrophone: captureState = .testingMicrophone
            case .stopping: captureState = .stopping
            default: presentation = newValue; captureState = .idle
            }
        }
    }
    @Published private(set) var transcript = ""
    /// True while the displayed text is a provisional partial — the pill
    /// dims it so a mid-hold guess never reads as the committed transcript.
    @Published private(set) var partialLive = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var inputName = ""
    @Published private(set) var detail = ""
    @Published private(set) var resultMessage = ""
    @Published private(set) var measurements: [String: Double] = [:]
    @Published private(set) var isMicrophoneTest = false
    @Published private(set) var microphoneReady = false
    @Published private(set) var microphoneReadiness = "Preparing microphone…"
    @Published var missingPermissions: [Permission] = Permission.missing
    private let permissionMonitor: PermissionStatusMonitor
    private var lastPolledMicrophoneGranted = Permission.microphone.isGranted

    private static let voiceLog = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "capture")
    /// Content-free diagnostics let physical trials be correlated without retaining
    /// raw microphone audio, spoken text, app contents, or credentials.
    private func trace(_ event: String) {
        let id = sessionID?.uuidString ?? "none"
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - beganAt) * 1000
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        Self.voiceLog.notice("capture=\(id, privacy: .private) event=\(event, privacy: .public) held=\(self.held) words=\(words) elapsed_ms=\(elapsed) status=\(self.status.title, privacy: .public)")
        if let turn = sessionID {
            turnEvidence?.event(turn: turn, name: String(event.prefix(while: { !$0.isWhitespace })))
            if event.hasPrefix("capture_failed ") {
                turnEvidence?.failure(turn: turn, message: String(event.dropFirst("capture_failed ".count)))
            }
        }
    }

    let config: Config
    private let diagnosticTraceOnly: Bool
    let commandTrace = VoiceCommandTrace()
    /// Opt-in physical real-use evidence — nil unless JARVIS_VOICE_EVIDENCE_DIR
    /// is set; behaviour is identical either way, only the row dump changes.
    let turnEvidence: VoiceTurnEvidence?
    private var normalQualification: VoiceNormalQualification?
    var semanticAuditBudget: SemanticRequestBudget?
    var semanticAuditSubject: String?
    var auditDocumentBinding: (file: URL, windowID: Int)?
    let cua: VoiceTaskCoordinator
    var cuaTasks: [VoiceTaskCoordinator.Work] { cua.tasks }
    var diagnosticTask: VoiceTaskCoordinator.Work? { cuaTasks.first { $0.id == cua.selectedID } }
    func stopAll() { cancel(); cua.stopAll() }
    func selectTask(_ id: UUID) { cua.select(id: id) }
    func cancelTask(_ id: UUID) { cua.cancel(id) }
    func approveTask(_ id: UUID, approved: Bool) { cua.resolveApproval(id: id, approved: approved) }
    /// All parked confirm asks, oldest task first — every row's Run button
    /// is id-scoped (approveTask → resolveApproval), so it resolves its own.
    /// Agent asks carry no continuation — the parked `.confirm` itself is
    /// the signal, resolved through the shared answer file.
    var pendingTaskApprovals: [VoiceTaskCoordinator.Work] {
        cuaTasks.filter(\.awaitingApproval)
    }
    /// The single-Confirm surface must aim at the ask the voice path would
    /// resolve — respond_to_task answers the NEWEST parked ask.
    var pendingTaskApproval: VoiceTaskCoordinator.Work? {
        pendingTaskApprovals.last { $0.active } ?? pendingTaskApprovals.last
    }

    /// A pending clarification as a display row: the question plus the request
    /// it is about. Viewing it is informational and grants no control over the
    /// owning intent.
    struct PendingQuestionItem: Identifiable, Equatable {
        let id: UUID
        let prompt: String
        let owner: String
    }

    /// Attempts belonging to the current interaction, in creation order.
    /// Identity comes from the provenance capture id, never from task-list
    /// recency.
    private var interactionWorks: [VoiceTaskCoordinator.Work] {
        guard let sessionID else { return [] }
        return cua.tasks.filter { $0.captureID == sessionID }
    }

    /// A pending clarification owned by the current interaction — a normal
    /// question state, not an error. `.choice` asks count too: a parked
    /// numbered ask is the same "waiting on you" state for the card.
    private var interactionQuestion: PendingQuestionItem? {
        interactionWorks.compactMap { w -> PendingQuestionItem? in
            switch w.ask {
            case .question(let prompt), .choice(let prompt, _):
                return PendingQuestionItem(id: w.id, prompt: prompt, owner: w.request)
            default:
                return nil
            }
        }.last
    }

    /// The interaction's own conversational text: its pending question or its
    /// latest attempt's progress — never the diagnostically selected task's
    /// message.
    private var interactionMessage: String {
        if let question = interactionQuestion { return question.prompt }
        return interactionWorks.last?.message ?? ""
    }

    /// Only this session's own latest attempt can surface a failure on the
    /// interaction's status line; unrelated tasks report on their own rows.
    private var interactionFailure: String? {
        guard let outcome = interactionWorks.last?.outcome else { return nil }
        switch outcome {
        case .failed(let reason), .blocked(let reason): return reason
        default: return nil
        }
    }

    /// Escape/current-interaction cancel stops only this session's active
    /// work — never the diagnostically selected task and never unrelated
    /// background work.
    private func cancelInteractionWork() {
        for work in interactionWorks where work.active {
            cua.cancel(work.id)
        }
    }

    /// Pending clarification questions across the dialogue, oldest ask
    /// first, for surfaces that show dialogue state without granting
    /// control authority.
    /// Every parked question across all work, oldest first — `.choice`
    /// asks included so a numbered ask resurfaces the card and reaches
    /// the [context] note like any other wait-on-user state.
    var pendingQuestions: [PendingQuestionItem] {
        cua.tasks.compactMap { work in
            guard work.awaitingAnswer else { return nil }
            switch work.ask {
            case .question(let prompt), .choice(let prompt, _):
                return PendingQuestionItem(id: work.id, prompt: prompt, owner: work.request)
            default:
                return nil
            }
        }
    }

    /// A task may offer explicit retry when it settled short of done —
    /// running work and clean finishes refuse.
    func canRetryTask(_ id: UUID) -> Bool {
        guard let work = cuaTasks.first(where: { $0.id == id }), !work.active,
              let outcome = work.outcome else { return false }
        switch outcome {
        case .blocked, .failed, .uncertain: return true
        case .done, .alreadyDone, .cancelled: return false
        }
    }

    /// Instant gaze click seam — the coordinator lane wires
    /// `GazeService.commitTarget` + `actuateCommitted` here; a speechless
    /// Fn tap fires it instead of the silent dismiss. nil = today's
    /// silent dismiss.
    var gazeTapHandler: (@Sendable () async -> Bool)? {
        get { (speech as? RealtimeVoiceLane)?.gazeTapHandler }
        set { (speech as? RealtimeVoiceLane)?.gazeTapHandler = newValue }
    }
    /// Local speech tee — forwarded to the lane's capture feeds so the
    /// LocalTranscriber (composition lane) hears converted PCM chunks.
    /// nil = no tap.
    var localSpeechSink: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { (speech as? RealtimeVoiceLane)?.localSpeechSink }
        set { (speech as? RealtimeVoiceLane)?.localSpeechSink = newValue }
    }
    /// Universal stop seam — wired by composition to the coordinator's
    /// `cancelAllRunning()` once it exists; Escape/stop calls it
    /// fire-and-forget. nil = interaction-scoped cancel only.
    var cancelAllTasks: (() async -> Void)?
    /// Local-STT turn bracket — composition opens the transcriber's
    /// listening turn here so `localSpeechSink` audio lands inside it.
    /// True = a command capture's audio window opened; false = it closed
    /// (release, cancel, or failure). Dictation holds never fire `true`:
    /// literal text is not command-lane input.
    var localSpeechWindow: ((Bool) -> Void)?

    /// Agent-side speakable events (consent asks, replies) join the realtime
    /// voice whenever that lane exists — a dead socket queues for replay
    /// rather than dropping the line. A payload whose `say` is already fixed
    /// by contract is claimed AND voiced verbatim through the local TTS seam
    /// even lane-less — we hold the words, so no fallback synthesizer or RTT
    /// pays to repeat them. The return value stays for the caller's
    /// fallback path; everything this entry accepts is claimed.
    func voiceAgentEvent(_ text: String) -> Bool {
        pushOutcome(text, speak: true, to: speech as? RealtimeVoiceLane)
        return true
    }

    /// A runtime outcome pushed to the voice. A deterministic payload — one
    /// whose `say` the contract already fixes — is voiced verbatim through
    /// the TTS seam and reaches the model as context only (speak:false):
    /// no extra RTT just to repeat a line we hold. That local voice needs
    /// no lane — a deterministic say is spoken even when the realtime lane
    /// is absent. When a reply is already armed the queued response keeps
    /// its place — the model voices the outcome in order instead of
    /// talking over its own stream.
    private func pushOutcome(_ text: String, speak: Bool, to lane: RealtimeVoiceLane?) {
        if speak, lane?.responseVoiceArmed != true,
           let say = RealtimeVoiceLane.deterministicSay(text) {
            detail = say
            self.speak(say)
            lane?.pushTaskEvent(text, speak: false)
            return
        }
        lane?.pushTaskEvent(text, speak: speak)
    }

    /// An explicit retry resumes the intent in place through the runtime's
    /// direct path — same intent id, fresh attempt, re-observed state. It
    /// never replays a tool call or re-runs a worker directly. Requires an
    /// idle pipeline: it must not interleave with a live capture's events.
    func retryTask(_ id: UUID) {
        guard canRetryTask(id), !captureActive else { return }
        let lane = speech as? RealtimeVoiceLane
        cua.retryWork(id)
        pushOutcome(#"{"kind":"task_outcome","status":"ok","say":"Retrying."}"#,
                    speak: true, to: lane)
    }

    /// The per-turn [context] note — the model's world is frozen at session
    /// connect without it (Clicky injects the same facts every turn). Facts
    /// only, one line; the instructions tell the model to use them silently.
    private func turnContextNote() async -> String {
        var parts = ["local time: \(Self.timeFormatter.string(from: Date()))"]
        if let app = commandFrontmostApp ?? lastExternalApp { parts.append("active app: \(app)") }
        let snapshot = voiceAdmissionContext()
        parts += snapshot.currentAsks.map { "task_id=\($0.taskID.uuidString) ask_id=\($0.askID.uuidString)" }
        parts += snapshot.agents.map { "agent_id=\($0.key) name=\($0.value)" }
        let waiting = pendingQuestions.prefix(2).map { "[\($0.owner)] \"\($0.prompt)\"" }
        if !waiting.isEmpty { parts.append("waiting on your answer: \(waiting.joined(separator: ", "))") }
        let confirms = pendingTaskApprovals.prefix(3).map { "[\($0.request)] \"\($0.askPrompt ?? "")\"" }
        if !confirms.isEmpty { parts.append("needs confirmation: \(confirms.joined(separator: ", "))") }
        let running = cuaTasks.filter(\.active).prefix(2).map(\.request)
        if !running.isEmpty { parts.append("running: \(running.joined(separator: ", "))") }
        // D2 — the gaze referent rides every turn: "Looking at" /
        // "Recently looked at" lines let "this"/"that"/"it" resolve
        // without pointing words. Focal-gated — glances never reach here.
        if let gaze = await GazeService.shared.referentContext() {
            parts.append(gaze.replacingOccurrences(of: "\n", with: " · "))
        }
        return "[context] " + parts.joined(separator: " · ")
    }
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    /// Typed and reviewed commands take the same model turn the voice does —
    /// one decision surface (the realtime model), one screen, one tool set.
    private func routeCommand(_ text: String) {
        guard let lane = speech as? RealtimeVoiceLane else {
            fail("The realtime voice lane is not available.")
            return
        }
        // A typed retry can arrive with no live session — make one so the
        // turn's events have an identity to bind to.
        if sessionID == nil { _ = newSession() }
        let sid = sessionID ?? UUID()
        // Owned so cancel() can kill the in-flight send: an orphaned one
        // would still arm the dead turn's response.create after the user
        // bailed (the lane's own identity re-checks are the backstop).
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            do { try await lane.submitTyped(text, sessionID: sid) }
            catch { self?.fail("The voice model is unavailable: \(error.localizedDescription)") }
        }
    }

    /// Short stable identity for surfaces that show intent/attempt ids.
    func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// In-memory, content-minimized diagnostics for one work row: target,
    /// effect certainty, and the step ledger. Never dumps a literal payload.
    func taskDiagnostics(_ task: VoiceTaskCoordinator.Work) -> [String] {
        var lines = ["task \(shortID(task.id)) · \(task.request)"]
        if let app = task.spec.application { lines.append("target: \(app)") }
        switch task.outcome {
        case nil: lines.append(task.dispatchedEffect == true
            ? "effects dispatched · outcome pending" : "no effects dispatched")
        case .done: lines.append("effects dispatched · verified")
        case .uncertain: lines.append("effects dispatched · outcome uncertain")
        case .alreadyDone: lines.append("already satisfied · no effects needed")
        case .failed, .blocked, .cancelled:
            lines.append("effects dispatched · outcome unverified")
        }
        if task.elapsedMs > 0 { lines.append(String(format: "elapsed %.0f ms", task.elapsedMs)) }
        lines += task.history.suffix(8)
        return lines
    }

    private var speech: SpeechCapturing
    private let dictation: DictationDelivering
    /// Spoken replies seam — nil or Config.ttsEnabled=false stays silent.
    var speaker: SpeechSynthesizing?
    private let authorize: () async -> Bool
    private let timings: VoiceTimings
    private let frontmost: () -> String?
    private var appObserver: AnyCancellable?
    private var subscriptions: Set<AnyCancellable> = []
    private var lastExternalApp: String?
    private var commandFrontmostApp: String?
    private var sessionID: UUID?
    private var held = false
    private var dictating = false
    private var latchRelease = false
    /// A latch tap landed while startup was still resolving: `held` is already
    /// released but the capture continues, so the startup guards must treat
    /// the hold as logically alive instead of wedging at `.starting`.
    private var latched = false
    /// A dictation capture started by voice ("start dictating") has no
    /// finger on Fn — it latches open like a tap-latch and the next Fn
    /// press means stop. The input state can't see the voice latch (only
    /// a physical latch arms its own), so `canBegin` lets the tap through
    /// and `begin()` converts it to finish().
    private var voiceLatched = false
    private var automatic = true
    private var microphoneTask: Task<Void, Never>?
    /// The typed/reviewed turn's in-flight lane send — cancel() kills it.
    private var routeTask: Task<Void, Never>?
    /// Sessions created by submitTypedCommand — the admission callback labels
    /// these turns "typed" in evidence so physical rows stay honest.
    private var typedSessions: Set<UUID> = []
    private var microphoneEnabled = true
    private var configuredDevice: MicrophoneDevice?
    private var startupTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// The dictation insert/paste — owned so cancel() can stop a delivery
    /// still parked on the shared input lease; otherwise it would resume
    /// and paste into whatever the user moved on to.
    private var deliveryTask: Task<Void, Never>?
    private var beganAt: TimeInterval = 0
    private var releasedAt: TimeInterval = 0
    /// Accumulates the realtime lane's streaming reply text for the detail line.
    private var replyDraft = ""
    private var cachedVoiceEntities: [VoiceAdmissionContext.Entity] = []
    private var cachedVoiceAppRoles: [String: String] = [:]
    private var voiceEntityRefresh = Date.distantPast
    private var cachedVoiceAgents: [String: String] = [:]
    private var voiceRosterRefresh: Task<Void, Never>?

    func refreshVoiceContext() {
        guard voiceRosterRefresh == nil else { return }
        voiceRosterRefresh = Task { [weak self] in
            guard let self else { return }
            defer { self.voiceRosterRefresh = nil }
            let roster = await self.cua.agentBridge?.roster() ?? []
            self.cachedVoiceAgents = Dictionary(roster.map { ($0.slug, $0.name) },
                                                uniquingKeysWith: { first, _ in first })
        }
    }

    private func voiceAdmissionContext() -> VoiceAdmissionContext {
        var context = VoiceAdmissionContext()
        if Date().timeIntervalSince(voiceEntityRefresh) > 30 {
            cachedVoiceEntities = VoiceAdmissionContext.observedAppEntities()
            cachedVoiceAppRoles = VoiceAdmissionContext.observedAppRoles()
            voiceEntityRefresh = Date()
        }
        context.entities = cachedVoiceEntities; context.agents = cachedVoiceAgents
        context.appRoles = cachedVoiceAppRoles
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = FocusedTextBinding.capturedWindowID(pid: Int(front.processIdentifier)) {
            context.windowID = id
            context.targetAppID = front.bundleIdentifier
            context.targetID = "window:\(front.processIdentifier):\(id)"
            // The executor still validates the focused field before typing.
            context.editableTarget = true
        }
        let active = cua.tasks.filter(\.active)
        context.tasks = Set(active.map(\.id))
        context.selectedTask = active.count == 1 ? active.first?.id : nil
        context.capturedAsks = active.filter(\.awaitingAnswer).map { work in
            switch work.ask {
            case .confirm: return .init(taskID: work.id, askID: work.askID, kind: .confirm)
            case .choice(_, let options): return .init(taskID: work.id, askID: work.askID, kind: .choice, options: options)
            case .question: return .init(taskID: work.id, askID: work.askID, kind: .question)
            case nil: return .init(taskID: work.id, askID: work.askID)
            }
        }
        context.currentAsks = context.capturedAsks
        return context
    }
    var isListening: Bool { status == .listening }
    var canBegin: Bool {
        guard microphoneEnabled else { return false }
        // A voice-latched dictation means stop-on-tap — let the press
        // through so begin() can convert it to finish().
        if voiceLatched { return true }
        if !held, cleanupTask == nil, startupTask == nil,
           [.executing, .thinking].contains(status) { return true }
        if isMicrophoneTest && status != .stopping { return true }
        switch status {
        case .idle, .done, .error, .awaitingAnswer: return cleanupTask == nil
        default: return false
        }
    }
    /// Same gates as `canBegin` minus microphone availability — a typed
    /// command never touches the mic.
    var canSubmitCommand: Bool {
        if !held, cleanupTask == nil, startupTask == nil,
           [.executing, .thinking].contains(status) { return true }
        if isMicrophoneTest && status != .stopping { return true }
        switch status {
        case .idle, .done, .error, .awaitingAnswer: return cleanupTask == nil
        default: return false
        }
    }
    var operationActive: Bool {
        // Gates the Escape consume — the key is ours only while a real
        // interaction sits on the card: a live capture OR committed turn
        // (cancelling an in-flight turn is a valid Escape meaning), a
        // review/confirm prompt, or a parked question/approval/consent ask.
        // Bare background work (executing/thinking with no live turn and
        // nothing asked) must not eat the frontmost app's Escape — the
        // user's key press belongs to them.
        if captureActive { return true }
        switch status {
        case .awaitingConfirm, .reviewTranscript, .awaitingAnswer: return true
        default: break
        }
        return interactionQuestion != nil || pendingTaskApproval != nil || hasActiveChoiceAsk
    }
    /// A parked `.choice` ask anywhere in the dialogue — a numbered ask
    /// needs Escape to reach it the same way a question/confirm does.
    /// Delegates to the coordinator's `hasActiveChoiceAsk` (parked-ask
    /// store: `work.ask` `.choice` + `awaitingAnswer`, i.e. an armed
    /// choice radial — the missing arm of this Escape gate).
    private var hasActiveChoiceAsk: Bool { cua.hasActiveChoiceAsk }
    /// Dwell-suppression + Escape seam: true while a capture turn is live —
    /// Fn held through its commit, or a typed turn still in flight. Status
    /// alone can't see a committed turn: after .finishing the card shows
    /// .executing while the lane's turnID stays bound until .turnEnded,
    /// .final, or cancel. The lane's bound turn is the authority there —
    /// it's also what lets Escape reach a bare .executing turn.
    var captureActive: Bool {
        switch status {
        case .starting, .listening, .finishing, .awaitingRelease, .testingMicrophone:
            return true
        default:
            return (speech as? RealtimeVoiceLane)?.turnID != nil
        }
    }

    init(config: Config? = nil, speech: SpeechCapturing? = nil,
         authorize: (() async -> Bool)? = nil,
         timings: VoiceTimings = VoiceTimings(), frontmost: (() -> String?)? = nil,
         cuaRuntime: VoiceTaskCoordinator? = nil,
         dictation: DictationDelivering = DictationDelivery(),
         speaker: SpeechSynthesizing? = nil,
         diagnosticTraceOnly: Bool? = nil, turnEvidence: VoiceTurnEvidence? = nil,
         permissionStatusReader: @escaping @Sendable () -> [Permission] = { Permission.missing }) {
        let config = config ?? Config.shared
        self.config = config
        self.permissionMonitor = PermissionStatusMonitor(read: permissionStatusReader)
        self.turnEvidence = turnEvidence ?? VoiceTurnEvidence()
        self.diagnosticTraceOnly = diagnosticTraceOnly ?? VoiceUserAudit.networkFreeTrace
        self.dictation = dictation
        self.speaker = speaker
        self.authorize = authorize ?? { await RealtimeVoiceLane.requestAuthorization() }
        // `speech` must exist before self can appear in closures below.
        self.speech = speech ?? RealtimeVoiceLane(apiKey: { [weak config] in config?.openAIAPIKey ?? "" })
        // One final-only admission owner routes local actions or one
        // remote miss into the existing execution spine.
        self.cua = cuaRuntime ?? VoiceTaskCoordinator(config: config,
            jevAPIKey: { [weak config] in config?.apiKey ?? "" })
        self.timings = timings
        self.frontmost = frontmost ?? { NSWorkspace.shared.frontmostApplication?.localizedName }
        lastExternalApp = self.frontmost()
        appObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastExternalApp = $0.localizedName }
        self.cua.onChange = { [weak self] in self?.cuaChanged() }
        self.cua.onCommandStage = { [weak self] turn, task, stage, tool in
            guard let turn else { return }
            self?.commandTrace.record(stage, turn: turn, task: task, tool: tool)
            self?.turnEvidence?.event(turn: turn, name: "command.\(stage.rawValue)", tool: tool, task: task)
        }
        self.cua.onNativeTextInsertion = { [weak self] turn, task, receipt in
            guard let self, let turn else { return }
            let ended: VoiceCommandTrace.Stage = receipt.succeeded ? .nativeTextInsertionEnd : .nativeTextInsertionFailed
            for (stage, time) in [(VoiceCommandTrace.Stage.nativeTextInsertionBegin, receipt.issuedAt),
                                  (ended, receipt.returnedAt)] {
                self.commandTrace.record(stage, turn: turn, task: task, tool: .typeText, at: time)
                self.turnEvidence?.event(turn: turn, name: "command.\(stage.rawValue)", at: time, tool: .typeText, task: task)
            }
        }
        self.turnEvidence?.onGrace = { [weak self] turn in
            self?.flushEvidence(turn: turn, terminal: "grace_timeout")
        }
        // The realtime lane's tools reach the runtime spine — the model picks
        // the tool; fast lane / drive loop / consent decide how. computer_
        // command returns at spawn and the verified outcome pushes back
        // through taskEventSink as a spoken `[task outcome]`.
        normalQualification = VoiceNormalQualification.install(evidence: self.turnEvidence,
            lane: String(describing: type(of: self.speech)))
        if let lane = self.speech as? RealtimeVoiceLane {
            lane.onQualificationPreparation = { [weak self] stage, at in
                self?.normalQualification?.preparation(stage, at: at)
            }
            if let evidence = self.turnEvidence {
                lane.onDiagnostic = { [weak evidence] event in
                    evidence?.event(turn: event.turn, name: event.stage,
                                    at: event.monotonic, metrics: event.metrics)
                }
            }
            lane.onCommandStage = { [weak self] turn, stage in
                self?.commandTrace.record(stage, turn: turn)
                self?.turnEvidence?.event(turn: turn, name: "command.\(stage.rawValue)")
            }
            lane.onAdmission = { [weak self] turn, heard, route in
                guard let self else { return }
                let input = self.typedSessions.remove(turn) != nil ? "typed"
                    : route == .dictation ? "dictation" : "voice"
                self.turnEvidence?.begin(turn: turn, heard: heard, input: input,
                    submittedAt: ProcessInfo.processInfo.systemUptime,
                    releasedAt: input == "typed" ? 0 : self.releasedAt)
            }
            lane.audioRepliesEnabled = config.ttsEnabled
            lane.commandHandler = { [weak self, weak lane] instruction, app, literalText, transcript, steps, captureID in
                guard let self else { return #"{"status":"refused","say":"Jev is not available right now."}"# }
                let capturedWindow = lane?.capturedLocalWindowID(for: captureID)
                if let binding = self.auditDocumentBinding {
                    guard VoiceUserAudit.enabled,
                          capturedWindow == nil || capturedWindow == binding.windowID,
                          VoiceUserAudit.focusedOwnedDocument(binding.file, windowID: binding.windowID) else {
                        return #"{"status":"refused","say":"The owned test document lost focus. No action taken."}"#
                    }
                }
                // transcript is the turn's completed speech transcript —
                // the lane held dispatch until it landed (typed turns pass
                // nil), so the runtime's heard-vs-called check compares
                // against the user's final words, not a display partial.
                let prior = Set(self.cua.tasks.map(\.id))
                let result = await self.cua.beginVoiceTask(
                    instruction, app: app,
                    frontmostHint: self.commandFrontmostApp ?? self.lastExternalApp,
                    literalText: literalText,
                    transcriptHint: transcript, steps: steps, captureID: captureID,
                    pinnedWindowID: self.auditDocumentBinding?.windowID ?? capturedWindow)
                // Every contract `say` (including "started"'s provenance
                // echo) is voiced verbatim by the lane's `.toolSay` event
                // — the second model turn is suppressed for all of them,
                // so nothing is spoken here or it would double the ack.
                let added = self.cua.tasks.filter { !prior.contains($0.id) && $0.captureID == captureID }
                if added.count == 1, let id = added.first?.id,
                   let data = result.data(using: .utf8),
                   var fields = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object {
                    fields["task_id"] = .string(id.uuidString)
                    if let encoded = try? JSONEncoder().encode(JSONValue.object(fields)) {
                        return String(decoding: encoded, as: UTF8.self)
                    }
                }
                return result
            }
            lane.taskResponseHandler = { [weak self] answer, task, captureID in
                guard let self else { return "Nothing is waiting for an answer." }
                return await self.cua.respondToTask(answer, task: task,
                                                    captureID: captureID)
                    ?? #"{"status":"nothing_pending","say":"Nothing is waiting for an answer."}"#
            }
            lane.delegationHandler = { [weak self] task, agent, name, role, description in
                guard let self else { return #"{"status":"refused","say":"Jev is not available right now."}"# }
                let result = await self.cua.delegateToAgent(task: task, agent: agent,
                                                          name: name, role: role,
                                                          description: description)
                self.refreshVoiceContext()
                let roster = await self.cua.agentBridge?.roster() ?? []
                let matches = roster.filter { entry in
                    if let agent { return entry.slug == agent || entry.name == agent }
                    return name.map { entry.name == $0 } ?? false
                }
                if matches.count == 1, let slug = matches.first?.slug,
                   let data = result.data(using: .utf8),
                   var fields = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object {
                    fields["agent_id"] = .string(slug)
                    if let data = try? JSONEncoder().encode(JSONValue.object(fields)) {
                        return String(decoding: data, as: UTF8.self)
                    }
                }
                return result
            }
            lane.cancelHandler = { [weak self] hint in
                guard let self else { return #"{"status":"refused","say":"Jev is not available right now."}"# }
                return await self.cua.cancelVoiceTask(hint)
            }
            lane.exactTaskResponseHandler = { [weak self] answer, task, ask, captureID in
                guard let self else { return VoiceToolCatalog.result(status: "blocked", summary: "Jev is unavailable.", error: "unavailable") }
                return await self.cua.respondToTaskExact(answer, taskID: task, askID: ask, captureID: captureID)
            }
            lane.exactCancellationHandler = { [weak self] task in
                guard let self, self.cua.tasks.contains(where: { $0.id == task && $0.active }) else {
                    return VoiceToolCatalog.result(status: "blocked", summary: "That task is no longer active.", error: "stale_task")
                }
                self.cua.cancel(task)
                return VoiceToolCatalog.result(status: "accepted", summary: "Cancellation requested.", taskID: task.uuidString)
            }
            lane.admissionContextProvider = { [weak self] in self?.voiceAdmissionContext() ?? VoiceAdmissionContext() }
            lane.semanticEnabled = { [weak self] in
                self?.config.semanticAppSuggestions == true && self?.diagnosticTraceOnly == false
            }
            lane.remoteReasoningPermitted = !VoiceUserAudit.enabled && !self.diagnosticTraceOnly
                && self.normalQualification == nil
            lane.semanticContextProvider = { [weak self] in
                guard let self else { return VoiceAdmissionContext() }
                self.voiceEntityRefresh = .distantPast
                return self.voiceAdmissionContext()
            }
            lane.semanticInterpretation = { [weak self] admission, context in
                guard let self, !self.diagnosticTraceOnly, self.config.semanticAppSuggestions else {
                    throw CancellationError()
                }
                let key = self.config.apiKey
                guard !key.isEmpty else { throw VoiceSemanticRouter.Failure.unavailable }
                let qualificationBudget = self.normalQualification?.configuration.budget
                return try await VoiceSemanticRouter.live(apiKey: key,
                    budget: qualificationBudget ?? self.semanticAuditBudget,
                    subject: qualificationBudget == nil ? self.semanticAuditSubject : admission.turn.id.uuidString)
                    .interpret(admission, context: context)
            }
            lane.semanticConfirmationHandler = { [weak self] proposal in
                guard let self, self.config.semanticAppSuggestions else { return false }
                return self.cua.offerSemanticFocus(proposal, validate: { [weak self] in
                    guard let self, self.config.semanticAppSuggestions else { return false }
                    self.voiceEntityRefresh = .distantPast
                    return VoiceSemanticRouter.targetIsCurrent(proposal.target, context: self.voiceAdmissionContext())
                })
            }
            config.$semanticAppSuggestions.sink { [weak self, weak lane] enabled in
                if !enabled {
                    lane?.cancelSemanticInterpretation()
                    self?.cua.cancelPendingSemanticFocus()
                }
            }.store(in: &subscriptions)
            lane.contextProvider = { [weak self] in await self?.turnContextNote() ?? "" }
            self.cua.taskEventSink = { [weak self, weak lane] _, text, speak in
                self?.pushOutcome(text, speak: speak, to: lane)
            }
            config.$ttsEnabled.sink { [weak lane] in lane?.audioRepliesEnabled = $0 }
                .store(in: &subscriptions)
        }
        Self.shared = self
        wire(self.speech)
    }

    private func wire(_ capture: SpeechCapturing) {
        capture.onReadiness = { [weak self] readiness in
            guard let self else { return }
            let evidenceStage: String
            switch readiness {
            case .preparing: evidenceStage = "microphone.preparing"
            case .ready: evidenceStage = "microphone.ready"
            case .unavailable: evidenceStage = "microphone.unavailable"
            case .interrupted: evidenceStage = "microphone.interrupted"
            }
            self.normalQualification?.preparation(evidenceStage, at: ProcessInfo.processInfo.systemUptime)
            switch readiness {
            case .preparing: self.microphoneReady = false; self.microphoneReadiness = "Preparing microphone…"
            case .ready(let name): self.microphoneReady = true; self.microphoneReadiness = "Ready — " + name
            case .unavailable(let reason): self.microphoneReady = false; self.microphoneReadiness = reason
            case .interrupted(let reason):
                self.microphoneReady = false; self.microphoneReadiness = reason
                if self.microphoneEnabled { self.prepareMicrophone() }
            }
        }
        capture.onEvent = { [weak self] id, event in self?.receive(event, session: id) }
    }

    func refreshPermissions() {
        permissionMonitor.invalidate()
        applyPermissions(Permission.missing)
    }

    func refreshPermissionsInBackground(
        canPrepareMicrophone: @escaping @MainActor () -> Bool,
        onMicrophoneGranted: @escaping @MainActor () -> Void
    ) {
        permissionMonitor.refresh { [weak self] missing in
            guard let self else { return }
            let granted = !missing.contains(.microphone)
            let changed = granted != self.lastPolledMicrophoneGranted
            self.lastPolledMicrophoneGranted = granted
            self.applyPermissions(missing)
            if changed, granted, canPrepareMicrophone() { onMicrophoneGranted() }
        }
    }

    private func applyPermissions(_ missing: [Permission]) {
        let microphoneWasGranted = !missingPermissions.contains(.microphone)
        missingPermissions = missing
        if missing.contains(.microphone), microphoneReady || (microphoneEnabled && microphoneWasGranted) {
            suspendMicrophone("Microphone permission was removed.")
        }
    }

    func prepareMicrophone(deviceChanged: Bool = false) {
        let device = try? MicrophoneCatalog.resolve(uid: config.microphoneUID)
        let changed = deviceChanged && device != configuredDevice
        if deviceChanged && !changed { return }
        if changed, captureActive { interruptCapture("The selected microphone changed. Hold Fn again.") }
        configuredDevice = device
        microphoneEnabled = true
        let prior = microphoneTask
        let uid = config.microphoneUID
        microphoneTask = Task { [weak self] in
            // Bound the handoff — a wedged prior must not park this one
            // too. Cancelling afterwards marks the stale chain so the
            // lane's own wedged-preparation check can abandon it.
            await Self.awaitChained(prior)
            prior?.cancel()
            guard let self, self.microphoneEnabled, !Task.isCancelled else { return }
            if changed { await self.speech.suspend() }
            guard self.microphoneEnabled, !Task.isCancelled else { return }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await self.speech.prepare(inputUID: uid)
                let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                Self.voiceLog.notice("microphone_preparation_ms=\(milliseconds)")
            }
            catch { self.microphoneReady = false; self.microphoneReadiness = error.localizedDescription }
        }
    }

    func suspendMicrophone(_ reason: String) {
        microphoneEnabled = false
        microphoneReady = false; microphoneReadiness = reason
        if captureActive { interruptCapture(reason) }
        else {
            // A live turn dies with the socket — teardown emits no events,
            // so without failing here the card spins "Working…" forever.
            switch status {
            case .thinking, .executing, .awaitingAnswer: fail(reason)
            default: break
            }
        }
        speech.cancel()
        let prior = microphoneTask
        prior?.cancel()
        microphoneTask = Task { [weak self] in
            await self?.speech.suspend()
            // Bounded like the prepare path — the suspended chain's tail
            // must not park the teardown either.
            await Self.awaitChained(prior)
        }
    }

    func showSetup(_ message: String) {
        guard !operationActive else { return }
        fail(message)
    }
    func begin(inputHandlingMs: Double? = nil) { begin(inputHandlingMs: inputHandlingMs, dictating: false) }

    /// Fn+Ctrl dictation: the same capture pipeline, but the transcript is
    /// delivered as literal text — no planner call ever sees it.
    func beginDictation() {
        guard config.dictationHotkey else { return }
        begin(dictating: true)
    }

    /// The drive lane's "start dictation" verb — the Fn+Ctrl capture path
    /// without the physical chord; the dictationHotkey feature gate still
    /// applies. No finger holds Fn, so the capture latches open: an Fn
    /// tap (routed through begin() below), a finish() call from the
    /// "stop dictating" verb, Escape, or the recording limit ends it.
    func startDictation() {
        guard config.dictationHotkey else { return }
        // Idempotent — a repeated "start dictation" verb while a voice
        // dictation is already latched does nothing, never toggles it off.
        guard !voiceLatched else { return }
        begin(dictating: true)
        guard dictating, status == .starting || status == .listening else { return }
        voiceLatched = true
        // `held || latched` keeps the startup checkpoints alive without a
        // physical hold; latchRelease stays clear so finish() isn't eaten.
        latched = true
        held = false
    }

    /// The drive lane's dictation verbs land here — `onDictationRequest`
    /// hands a Bool ("start"/"stop dictating") and this reports whether
    /// the request actually took effect, so the loop's "Dictation is
    /// on"/"isn't available" lines stay honest: the feature gate off, an
    /// already-latched start, and a stop with nothing running all have
    /// their own truthful answers instead of a claimed toggle.
    func dictationRequest(_ start: Bool) -> Bool {
        if start {
            guard config.dictationHotkey else { return false }
            // Idempotent like `startDictation` — a second "start
            // dictating" while one runs reports the live state, not a
            // toggle-off.
            if voiceLatched { return dictating }
            startDictation()
            return dictating && (status == .starting || status == .listening)
        }
        // Only a voice-latched dictation ends here — a physical Fn+Ctrl
        // capture transcribes "stop dictating" as literal text and never
        // reaches this lane; a tap on Fn is its documented stop anyway.
        guard voiceLatched else { return false }
        voiceLatched = false
        finish()
        return true
    }

    /// Ctrl joined an armed Fn hold — the rest of this capture is dictation.
    func dictate() {
        guard config.dictationHotkey, !dictating else { return }
        guard status == .starting || status == .listening else { return }
        dictating = true
        if let id = sessionID { turnEvidence?.setInput(turn: id, input: "dictation") }
        (speech as? RealtimeVoiceLane)?.respondOnCommit = false
        // Partials already handed to the planner may have dispatched work —
        // conversion withdraws this interaction's intents and attempts along
        // with the pending decision.
        cancelInteractionWork()
        trace("dictation_mid_hold")
    }

    /// A tap-short Fn release with latch mode on: keep the capture listening;
    /// the monitor's `.finish` that follows is consumed here.
    func latchHold() {
        guard config.latchMode, status == .starting || status == .listening else { return }
        latchRelease = true
        // During startup the latch is deferred: `held` ends now but the
        // in-flight startup keeps going and resolves to `.listening`.
        latched = status == .starting
        held = false
        trace("latch_hold")
    }

    private func begin(inputHandlingMs: Double? = nil, dictating: Bool) {
        // A voice-latched dictation capture means Fn now — the input
        // state couldn't see the voice latch and dispatched `.begin`;
        // convert the tap into the release that ends dictation.
        if voiceLatched { voiceLatched = false; finish(); return }
        guard canBegin else { return }
        let priorStart = startupTask
        priorStart?.cancel()
        speech.cancel()
        isMicrophoneTest = false
        self.dictating = dictating
        // Dictation commits audio for transcript only — no spoken reply.
        (speech as? RealtimeVoiceLane)?.respondOnCommit = !dictating
        held = true
        let id = newSession()
        turnEvidence?.open(turn: id, input: dictating ? "dictation" : "voice", beganAt: beganAt)
        if let inputHandlingMs { measurements["Fn handler"] = inputHandlingMs }
        commandFrontmostApp = lastExternalApp
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            commandFrontmostApp = frontmost() ?? lastExternalApp
        }
        status = .starting
        trace("fn_down")
        // The gate's pre-roll cut — audio spoken during `.starting` is
        // replayed from this moment, never from before it.
        (speech as? RealtimeVoiceLane)?.holdStartedAt = beganAt
        // Pre-observe: the coordinator warms transport + gaze and arms the
        // target halo while the user is still talking — "click this" lands
        // as a lookup instead of a cold scan.
        cua.beginListeningHint()
        // The local transcriber's turn opens with the capture — dictation
        // holds skip it (their literal text never reaches a command lane).
        if !dictating { localSpeechWindow?(true) }
        let selectedUID = config.microphoneUID
        startupTask = Task { [weak self] in
            await Self.awaitUnlessCancelled(priorStart)
            await Self.awaitUnlessCancelled(self?.microphoneTask)
            guard let self, self.sessionID == id, !Task.isCancelled else { return }
            defer { if self.sessionID == id { self.startupTask = nil } }
            let permissionStart = ProcessInfo.processInfo.systemUptime
            let granted = await self.authorizeUnlessCancelled()
            self.refreshPermissions()
            guard self.sessionID == id, self.held || self.latched, !Task.isCancelled else { return }
            self.measurements["Permission check"] = (ProcessInfo.processInfo.systemUptime - permissionStart) * 1000
            guard granted else { self.fail("Microphone access is needed. Open Voice settings."); return }
            do {
                let name = try await self.speech.start(session: id, inputUID: selectedUID, transcribe: true)
                guard self.sessionID == id, self.held || self.latched, !Task.isCancelled else { return }
                self.inputName = name
                self.trace("capture_started")
                self.measurements["Microphone ready"] = (ProcessInfo.processInfo.systemUptime - self.beganAt) * 1000
                if self.status == .starting { self.status = .listening }
                self.scheduleDuration(id)
            } catch {
                if self.sessionID == id, !Task.isCancelled { self.fail(error.localizedDescription) }
            }
        }
    }

    func finish() {
        trace("fn_up")
        cua.endListeningHint()
        localSpeechWindow?(false)
        held = false
        // A latch release keeps the capture listening; the next Fn tap
        // arrives as a plain `.finish` and ends it below.
        guard !latchRelease else { latchRelease = false; return }
        if let id = sessionID {
            releasedAt = ProcessInfo.processInfo.systemUptime
            turnEvidence?.release(turn: id, at: releasedAt)
        }
        latched = false
        durationTask?.cancel(); durationTask = nil
        switch status {
        case .starting: cancel()
        case .awaitingRelease: showTranscriptReview()
        case .listening:
            status = .finishing
            audioLevel = 0
            speech.finish()
            guard let id = sessionID, status == .finishing else { return }
            deadlineTask = Task { [weak self] in
                guard let self else { return }
                // The realtime turn can run longer — tool calls, then speech.
                let timeout = self.speech is RealtimeVoiceLane
                    ? max(self.timings.finalization, 45) : self.timings.finalization
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) } catch { return }
                guard self.sessionID == id, self.status == .finishing else { return }
                self.trace("capture_finalization_timeout")
                self.speech.cancel()
                if self.speech is RealtimeVoiceLane {
                    // The model already heard the audio — there is no local
                    // transcript artifact to review.
                    self.fail("No response arrived. Hold Fn and try again.")
                } else {
                    self.detail = "Speech didn't finish in time. Review the captured text before continuing."
                    self.showTranscriptReview()
                }
            }
        default: break
        }
    }

    func acceptTranscript() {
        guard status == .reviewTranscript, let id = sessionID else { return }
        submit(transcript, session: id)
    }

    /// A typed command is a final transcript — it enters the identical
    /// handoff as a finished capture: `cua.begin` then `submit`, which honours
    /// `autoExecute` the same way voice does.
    func submitTypedCommand(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canSubmitCommand else { return }
        startupTask?.cancel()
        speech.cancel()
        isMicrophoneTest = false
        dictating = false
        held = false
        let id = newSession()
        turnEvidence?.open(turn: id, input: "typed", beganAt: beganAt)
        turnEvidence?.final(turn: id, text: trimmed)
        commandFrontmostApp = lastExternalApp
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            commandFrontmostApp = frontmost() ?? lastExternalApp
        }
        trace("typed_command")
        typedSessions.insert(id)
        submit(trimmed, session: id)
    }

    func confirm() {
        guard status == .awaitingConfirm else { return }
        status = .executing
        routeCommand(transcript)
    }

    func cancel() { cancel(endingWith: .idle) }

    func cancelCaptureAttempt() { cancel(endingWith: .idle, cancelTask: false) }

    private func cancel(endingWith terminalStatus: Status, cancelTask: Bool = true) {
        if cancelTask {
            cancelInteractionWork()
            // Escape with no capture running still owes the card's newest
            // numbered ask a settle — the coordinator's decline resumes it
            // like the ask deadline firing. The !captureActive guard keeps
            // the Fn-release-during-startup cancel from touching asks.
            // PAIRING: if the .cancel dispatch grows an explicit
            // declineTopmostChoiceAsk call, drop this routing — it must
            // not settle two asks on one keypress.
            if !captureActive { _ = cua.declineTopmostChoiceAsk() }
            // Universal stop seam — composition wires this to the
            // coordinator's cancelAllRunning(); nil keeps the cancel
            // scoped to this interaction's work.
            if let cancelAllTasks { Task { await cancelAllTasks() } }
        }
        guard status != .stopping else { return }
        held = false; dictating = false; latched = false; voiceLatched = false
        trace("capture_cancelled")
        if let id = sessionID { flushEvidence(turn: id, terminal: "cancelled", finalStatus: terminalStatus) }
        sessionID = nil
        deadlineTask?.cancel(); deadlineTask = nil
        durationTask?.cancel(); durationTask = nil
        hideTask?.cancel(); hideTask = nil
        // A dictation parked on the input lease must not paste after the
        // user bailed — kill the delivery, not just the card.
        deliveryTask?.cancel(); deliveryTask = nil
        // Same for a typed turn still sending — its response.create
        // belongs to the dead interaction.
        routeTask?.cancel(); routeTask = nil
        // The Fn-down pre-observe's gaze pump lives on the coordinator —
        // a cancelled hold must end it, not wait out its 30s watchdog.
        cua.endListeningHint()
        localSpeechWindow?(false)
        speech.cancel()
        audioLevel = 0
        isMicrophoneTest = false
        let startup = startupTask
        startup?.cancel()
        startupTask = nil
        if startup == nil { status = terminalStatus; return }
        // The cancelled startup's own checkpoints make it inert — the card
        // returns to its terminal state immediately instead of waiting out
        // an in-flight socket connect, and Fn stays responsive.
        cleanupTask = Task { [weak self] in
            await startup?.value
            self?.cleanupTask = nil
        }
        status = terminalStatus
    }

    func recordQualificationInputReady(_ ready: Bool) {
        normalQualification?.preparation(ready ? "fn.ready" : "fn.unavailable",
                                          at: ProcessInfo.processInfo.systemUptime)
    }

    func shutdown() async {
        permissionMonitor.stop()
        microphoneEnabled = false
        let microphone = microphoneTask
        microphone?.cancel()
        cancel()
        await speech.suspend()
        await microphone?.value
        cua.shutdown()
        await cleanupTask?.value
        normalQualification?.stop()
    }

    func interruptCapture(_ reason: String) {
        guard captureActive else { return }
        if let id = sessionID {
            turnEvidence?.event(turn: id, name: "interrupted")
            turnEvidence?.failure(turn: id, message: reason)
        }
        cancel(endingWith: .error(reason), cancelTask: false)
        detail = reason
    }

    func startMicrophoneTest() {
        guard canBegin, !isMicrophoneTest else { return }
        let id = newSession()
        held = false; isMicrophoneTest = true; dictating = false; status = .starting
        let selectedUID = config.microphoneUID
        startupTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.sessionID == id { self.startupTask = nil } }
            if !Permission.microphone.isGranted { await Self.requestMicrophoneUnlessCancelled() }
            self.refreshPermissions()
            guard self.sessionID == id, !Task.isCancelled else { return }
            guard Permission.microphone.isGranted else { self.fail("Microphone access is needed for the input test."); return }
            do {
                let name = try await self.speech.start(session: id, inputUID: selectedUID, transcribe: false)
                guard self.sessionID == id, !Task.isCancelled else { return }
                self.inputName = name
                self.status = .testingMicrophone
            } catch { if self.sessionID == id, !Task.isCancelled { self.fail(error.localizedDescription) } }
        }
    }

    func stopMicrophoneTest() { if isMicrophoneTest { cancel() } }

    func recordOverlayPresentation() {
        guard beganAt > 0, measurements["Overlay shown"] == nil else { return }
        measurements["Overlay shown"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000
    }

    func recordRecoveredFnRelease(observed: TimeInterval, confirmed: TimeInterval, latch: Bool) {
        guard let id = sessionID else { return }
        let elapsed = max(0, (confirmed - observed) * 1000)
        measurements["Fn release recovery"] = elapsed
        turnEvidence?.event(turn: id, name: latch ? "fn_latch_recovered" : "fn_release_recovered",
                            at: observed, metrics: ["confirmation_ms": elapsed])
    }

    private func newSession() -> UUID {
        deadlineTask?.cancel(); durationTask?.cancel(); hideTask?.cancel()
        deliveryTask?.cancel(); deliveryTask = nil
        routeTask?.cancel(); routeTask = nil
        latchRelease = false; latched = false; voiceLatched = false
        // A new capture barges in on any spoken reply.
        speaker?.stop()
        let id = UUID(); sessionID = id
        automatic = config.autoExecute
        transcript = ""; detail = ""; resultMessage = ""; audioLevel = 0; replyDraft = ""; partialLive = false
        measurements = [:]
        beganAt = ProcessInfo.processInfo.systemUptime
        releasedAt = 0
        return id
    }

    private func receive(_ event: SpeechEvent, session id: UUID) {
        guard sessionID == id else { return }
        switch event {
        case .partial(let text): turnEvidence?.partial(turn: id, text: text)
        case .final(let text), .heardFinal(let text): turnEvidence?.final(turn: id, text: text)
        case .failure(let message): turnEvidence?.failure(turn: id, message: message)
        case .level(let value): turnEvidence?.level(turn: id, value: value)
        case .timing(let name, let milliseconds):
            turnEvidence?.event(turn: id, name: "measurement", metrics: [name: milliseconds])
        default: break
        }
        // Assistant-side events outlive the capture: the turn keeps streaming
        // after Fn released and the status moved on to .executing.
        switch event {
        case .assistantDelta(let delta):
            replyDraft += delta
            detail = replyDraft
            if status == .finishing { status = .executing }
            return
        case .assistant(let text):
            replyDraft = ""
            detail = text
            return
        case .toolSay(let text):
            // A deterministic tool-result line — the lane suppressed the
            // second model turn, so the TTS seam voices `say` verbatim
            // and the card fills detail from it directly (no
            // assistantDone is coming to paint it).
            detail = text
            speak(text)
            return
        case .turnEnded:
            let reply = replyDraft.isEmpty ? detail : replyDraft
            replyDraft = ""
            guard status != .idle, status != .done else { return }
            // A parked question or approval still needs the card — the
            // STARTED fast-path ends turns while work is live, and an ask
            // that lands after dismissal would be unreachable. An ask parked
            // outside this interaction owns the card too — a minimal
            // presence beats completing to .done and hiding it.
            if interactionQuestion != nil || pendingTaskApproval != nil { return }
            if let ask = pendingQuestions.last {
                detail = ask.prompt
                status = .awaitingAnswer(ask.prompt)
                return
            }
            // The reply already played through the lane's speaker — complete
            // without re-speaking it via the TTS seam.
            complete(reply.isEmpty ? "Done." : reply, session: id, voiced: false)
            return
        case .heardFinal(let text):
            // The local whole-hold final is authoritative. Displaying it
            // never re-dispatches a decision already owned by the lane.
            transcript = text; partialLive = false
            trace("capture_final")
            deadlineTask?.cancel(); durationTask?.cancel()
            switch status {
            case .starting, .listening, .finishing, .testingMicrophone:
                status = .executing
                if replyDraft.isEmpty { detail = "Working…" }
            default: break
            }
            return
        case .failure(let message):
            // Lane failures can arrive mid-turn (.executing) — only an already
            // finished or dead session ignores them.
            switch status {
            case .idle, .done, .error: return
            default: break
            }
            trace("capture_failed \(message)")
            speech.cancel(); audioLevel = 0
            deadlineTask?.cancel(); durationTask?.cancel()
            detail = "Speech stopped: \(message)"
            if speech is RealtimeVoiceLane || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The realtime lane holds no reviewable transcript artifact —
                // the model already heard the audio.
                fail(detail)
            } else if held { status = .awaitingRelease }
            else { showTranscriptReview() }
            return
        default: break
        }
        let accepting = status == .starting || status == .listening || status == .finishing || status == .testingMicrophone
        guard accepting else { return }
        switch event {
        case .failure, .assistantDelta, .assistant, .turnEnded, .heardFinal, .toolSay:
            break // handled above — these outlive the capture window
        case .timing(let name, let milliseconds):
            guard milliseconds.isFinite, milliseconds >= 0 else { return }
            measurements[name] = milliseconds
            Self.voiceLog.notice("capture=\(id.uuidString, privacy: .private) timing=\(name, privacy: .public) milliseconds=\(milliseconds)")
        case .level(let level): audioLevel = level
        case .partial(let text):
            // Turn-tagged local partials are display-only.
            guard text != transcript else { return }
            transcript = text; partialLive = true
            if measurements["First partial"] == nil { measurements["First partial"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000 }
        case .final(let text):
            transcript = text; partialLive = false
            trace("capture_final")
            speech.cancel(); audioLevel = 0
            deadlineTask?.cancel(); durationTask?.cancel()
            if held {
                        detail = dictating
                    ? "Recognition ended before you released Fn. Release to insert what was captured."
                    : "Recognition ended before you released Fn. Release the key, then review the text."
                status = .awaitingRelease
            } else {
                measurements["Transcript finalized"] = (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000
                submit(text, session: id)
            }
        }
    }

    private func showTranscriptReview() {
        // Dictation never waits on a review — literal text goes straight to
        // the focused field; nothing usable means nothing delivered.
        if dictating {
            if let id = sessionID, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                deliver(transcript, session: id)
            } else {
                // The user dictated into a void — a silent dismissal reads
                // as a lost paste, so say so.
                fail("No speech was captured — hold Fn and dictate again.")
            }
            return
        }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("No usable speech remains. Hold Fn and try again.")
        } else { status = .reviewTranscript }
    }

    private func submit(_ text: String, session id: UUID) {
        guard sessionID == id else { return }
        transcript = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // An empty dictation is a lost outcome — say so instead of
            // vanishing. The non-dictation tap stays a silent dismiss:
            // committing no audio was never a turn (lane's own contract).
            if dictating { fail("No speech was captured — hold Fn and dictate again.") }
            else {
                flushEvidence(turn: id, terminal: "no_speech", finalStatus: .idle)
                cancelCaptureAttempt()
            }
            return
        }
        if dictating {
            deliver(text, session: id)
            return
        }
        if automatic { status = .executing; routeCommand(text) }
        else { status = .awaitingConfirm; detail = "Run this request through Cua?" }
    }

    /// Literal delivery to the focused editable element via the
    /// DictationDelivering seam — no intent is recorded for it. The task
    /// is owned (`deliveryTask`) so cancel() can stop a paste that's still
    /// parked on the input lease; an abandoned delivery resuming later
    /// would insert text the user no longer expects.
    private func deliver(_ text: String, session id: UUID) {
        status = .executing
        detail = "Dictating into the focused field…"
        deliveryTask?.cancel()
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dictation.deliver(text)
                guard self.sessionID == id else { return }
                self.complete("Dictated into the focused field.", session: id)
            } catch {
                // A cancelled delivery is not a failure — the card already
                // moved on; surfacing "cancelled" would be noise.
                guard self.sessionID == id, !(error is CancellationError) else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    /// Spoken replies go through the SpeechSynthesizing seam only; dictation
    /// completions stay silent since the text lands where the user is looking.
    private func speak(_ text: String) {
        guard config.ttsEnabled, !text.isEmpty else { return }
        speaker?.speak(text)
    }

    /// `voiced: false` — the realtime lane already played the reply's audio;
    /// re-speaking it through TTS would double the voice.
    private func complete(_ message: String, session id: UUID, voiced: Bool = true) {
        resultMessage = message
        if voiced, !dictating { speak(message) }
        dictating = false
        status = .done
        settleEvidence(terminal: "done")
        hideTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.timings.dismissal * 1e9)) } catch { return }
            if self.sessionID == id, self.status == .done { self.status = .idle }
        }
    }

    /// Evidence rows close on the first terminal signal: spawned work all
    /// settled, the turn parked on an ask, a terminal status with nothing
    /// outstanding, or the recorder's 30s grace.
    func maybeFlushEvidence(works suppliedWorks: [VoiceTaskCoordinator.Work]? = nil) {
        guard let evidence = turnEvidence else { return }
        let allWorks = suppliedWorks ?? cua.tasks
        for id in evidence.pendingTurns {
            let works = allWorks.filter { $0.captureID == id }
            if works.contains(where: \.awaitingAnswer) {
                flushEvidence(turn: id, terminal: "awaiting_user")
            } else if !works.isEmpty, works.allSatisfy({ !$0.active }) {
                flushEvidence(turn: id, terminal: "settled")
            }
        }
    }

    private func settleEvidence(terminal: String) {
        guard let id = sessionID, turnEvidence?.isPending(id) == true else { return }
        let works = interactionWorks
        if works.isEmpty || works.allSatisfy({ !$0.active }) {
            flushEvidence(turn: id, terminal: terminal)
        }
    }

    private func flushEvidence(turn: UUID, terminal: String, finalStatus: Status? = nil) {
        guard let evidence = turnEvidence, evidence.isPending(turn) else { return }
        evidence.flush(turn: turn, terminal: terminal,
                       status: finalStatus?.title ?? (turn == sessionID ? status.title : "not_current"),
                       uptime: ProcessInfo.processInfo.systemUptime,
                       trace: commandTrace.events.filter { $0.turn == turn },
                       works: cua.tasks.filter { $0.captureID == turn }, traceDropped: commandTrace.dropped)
    }

    private func cuaChanged() {
        normalQualification?.worksChanged(cua.tasks)
        objectWillChange.send()
        // Evidence first — the early returns below must not starve a row
        // whose work just settled or parked on an ask.
        maybeFlushEvidence()
        guard !isMicrophoneTest else { return }
        if held {
            // Capture owns the status while held; the detail line keeps this
            // interaction's progress — or an independent task's — visible
            // without letting any of it own the interaction's state.
            if let work = interactionWorks.last(where: \.active) ?? interactionWorks.last {
                detail = work.message
            } else if let question = interactionQuestion {
                detail = question.prompt
            } else {
                detail = cua.tasks.last(where: \.active)?.message ?? ""
            }
            return
        }
        // Dictation's executing/done projection belongs to the delivery path —
        // unrelated task state must not complete it early.
        guard !dictating else { return }
        // Only the interaction-driven presentation states are re-projected here.
        // Capture-owned and rest states keep whatever they already present —
        // EXCEPT a parked question or approval, which resurfaces a done/idle
        // card that the STARTED fast-path already dismissed.
        switch status {
        case .thinking, .executing, .awaitingAnswer: break
        case .idle, .done:
            guard !pendingQuestions.isEmpty || pendingTaskApproval != nil else { return }
        default: return
        }
        // Only this session's dialogue decides the interaction's presentation.
        // A pending clarification is a normal question state, not a failure.
        // The same question is already pushed to the model via task_question —
        // speaking it again through TTS produces the double-voice glitch.
        if let question = interactionQuestion {
            detail = question.prompt
            status = .awaitingAnswer(question.prompt)
            return
        }
        if interactionWorks.contains(where: \.active) {
            detail = interactionMessage
            status = .executing
            return
        }
        if let failure = interactionFailure {
            detail = failure
            status = .error(failure)
            return
        }
        if case .awaitingAnswer = status, interactionWorks.isEmpty,
           pendingQuestions.isEmpty, pendingTaskApproval == nil {
            // The question was withdrawn without an answer; the interaction ends.
            status = .idle
            return
        }
        // An ask parked outside this interaction still owns the card's
        // minimal presence — an outstanding ask stays reachable instead of
        // hiding with .idle.
        switch status {
        case .idle, .done, .awaitingAnswer:
            if let ask = pendingQuestions.last {
                detail = ask.prompt
                status = .awaitingAnswer(ask.prompt)
                return
            }
            if let approval = pendingTaskApproval {
                let text = approval.askPrompt ?? approval.request
                detail = text
                status = .awaitingAnswer(text)
                return
            }
        default: break
        }
        // The lane's reply stream owns the display once a turn is committed —
        // work settling between turns updates the task list, not this card.
        // Task progress must not stomp a reply that's mid-stream.
        if !interactionWorks.isEmpty, status == .executing, replyDraft.isEmpty {
            detail = interactionMessage
        }
    }

    private func fail(_ message: String) {
        trace("capture_failed \(message)")
        speech.cancel()
        audioLevel = 0; held = false; dictating = false; latched = false
        voiceLatched = false; isMicrophoneTest = false
        deadlineTask?.cancel(); durationTask?.cancel()
        // A pending dictation delivery dies with its session — a failed
        // capture must not paste anyway.
        deliveryTask?.cancel(); deliveryTask = nil
        cua.endListeningHint()
        localSpeechWindow?(false)
        status = .error(message)
        settleEvidence(terminal: "failed")
        // Failures used to be a silent pill — voice a short,
        // non-punitive phrase through the same TTS seam. The error text
        // itself is never spoken: it can carry paths or account details.
        speak(Self.spokenFailure(for: message))
    }

    /// The spoken half of a failure, keyed by category — brief and
    /// non-punitive; the message itself never reaches the synthesizer so
    /// paths and secrets stay off the speaker. Internal for tests.
    static func spokenFailure(for message: String) -> String {
        let m = message.lowercased()
        if m.contains("editable field") || m.contains("focused for dictation")
            || m.contains("insert") {
            return "I couldn't insert that text."
        }
        if m.contains("window server") { return "I couldn't reach the window server." }
        if m.contains("microphone") || m.contains("permission") || m.contains("access is needed") {
            return "I need microphone access — check Voice settings."
        }
        if m.contains("speech") || m.contains("try again") || m.contains("catch") {
            return "I didn't catch that."
        }
        if m.contains("session") || m.contains("server") || m.contains("connect")
            || m.contains("unavailable") || m.contains("api key") || m.contains("realtime") {
            return "I couldn't reach the voice server."
        }
        return "That didn't work."
    }

    /// First finisher wins — the raced work's value, or `fallback` the
    /// moment this task is cancelled. `authorize()`, a predecessor startup
    /// and the permission prompt can all park forever on a dead wait (an
    /// ignored system prompt); a cancelled startup must still unwind so
    /// `cleanupTask` completes — `canBegin` requires cleanupTask == nil.
    private final class CancellationRace<Result: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        private var outcome: Result?
        private var settled = false
        func finish(_ value: Result) {
            lock.lock()
            if settled { lock.unlock(); return }
            settled = true; outcome = value
            let pending = continuation; continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
        func result(fallback: Result) async -> Result {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
                    lock.lock()
                    if settled, let outcome { lock.unlock(); c.resume(returning: outcome) }
                    else { continuation = c; lock.unlock() }
                }
            } onCancel: { finish(fallback) }
        }
    }

    /// Awaits a task's completion unless this task is cancelled first — a
    /// predecessor parked on a non-cancellable wait must not chain the stall.
    private static func awaitUnlessCancelled(_ task: Task<Void, Never>?) async {
        guard let task else { return }
        let race = CancellationRace<Void>()
        Task { race.finish(await task.value) }
        await race.result(fallback: ())
    }

    /// Bounded chain-wait for the microphone task serialisation — a prior
    /// prepare parked on a dead wait (continuation that never resumes)
    /// must not chain-wedge every later preparation forever. Past the
    /// bound the caller abandons the chain; the lane skips re-joining a
    /// stale preparation on its own side.
    private static func awaitChained(_ task: Task<Void, Never>?, timeout: TimeInterval = 10) async {
        guard let task else { return }
        let race = CancellationRace<Void>()
        Task { race.finish(await task.value) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            race.finish(())
        }
        await race.result(fallback: ())
        timer.cancel()
    }

    private func authorizeUnlessCancelled() async -> Bool {
        let race = CancellationRace<Bool>()
        Task { [authorize] in race.finish(await authorize()) }
        return await race.result(fallback: false)
    }

    private static func requestMicrophoneUnlessCancelled() async {
        let race = CancellationRace<Void>()
        Task { await Permission.microphone.request(); race.finish(()) }
        await race.result(fallback: ())
    }

    private func scheduleDuration(_ id: UUID) {
        durationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.timings.warning * 1e9))
                guard self.sessionID == id, self.status == .listening else { return }
                self.detail = "Recording limit approaching — release Fn to finish."
                try await Task.sleep(nanoseconds: UInt64(max(0, self.timings.limit - self.timings.warning) * 1e9))
                guard self.sessionID == id, self.status == .listening else { return }
                self.trace("capture_limit")
                self.speech.cancel(); self.audioLevel = 0
                self.detail = "Recording reached its limit. Release Fn, then review the captured text."
                self.status = .awaitingRelease
            } catch { }
        }
    }


}
