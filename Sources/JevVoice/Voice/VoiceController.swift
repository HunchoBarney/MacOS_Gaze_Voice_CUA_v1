import AppKit
import Combine
import OSLog
import JevVoiceCore

struct VoiceTimings {
    var finalization: TimeInterval = 2
    var warning: TimeInterval = 50
    var limit: TimeInterval = 55
    var dismissal: TimeInterval = 1.5
}

@MainActor
final class VoiceController: ObservableObject {
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
    // Task progress lives in CuaVoiceRuntime. It never replaces an active capture's state.
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
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var inputName = ""
    @Published private(set) var detail = ""
    @Published private(set) var resultMessage = ""
    @Published private(set) var measurements: [String: Double] = [:]
    @Published private(set) var isMicrophoneTest = false
    @Published private(set) var microphoneReady = false
    @Published private(set) var microphoneReadiness = "Preparing microphone…"
    @Published var missingPermissions: [Permission] = Permission.missing

    private static let voiceLog = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "capture")
    /// Content-free diagnostics let physical trials be correlated without retaining
    /// raw microphone audio, spoken text, app contents, or credentials.
    private func trace(_ event: String) {
        let id = sessionID?.uuidString ?? "none"
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - beganAt) * 1000
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        Self.voiceLog.notice("capture=\(id, privacy: .public) event=\(event, privacy: .public) held=\(self.held) words=\(words) elapsed_ms=\(elapsed) status=\(self.status.title, privacy: .public)")
    }

    let config: Config
    let cua: CuaVoiceRuntime
    var cuaTasks: [CuaVoiceRuntime.Work] { cua.tasks }
    var diagnosticTask: CuaVoiceRuntime.Work? { cuaTasks.first { $0.id == cua.selectedID } }
    func stopAll() { cancel(); cua.stopAll() }
    func selectTask(_ id: UUID) { cua.select(id) }
    func cancelTask(_ id: UUID) { cua.cancel(id) }
    func approveTask(_ id: UUID, approved: Bool) { cua.resolveApproval(id, approved: approved) }
    var pendingTaskApproval: CuaVoiceRuntime.Work? { cuaTasks.first(where: { $0.approval != nil }) }

    /// A pending clarification as a display row: the question plus the request
    /// it is about. Viewing it is informational and grants no control over the
    /// owning intent.
    struct PendingQuestionItem: Identifiable, Equatable {
        let id: UUID
        let prompt: String
        let owner: String
    }

    /// Intents this hold's capture created or resumed — the current
    /// interaction. Identity comes from provenance capture ids, never from
    /// task-list recency or the diagnostic selection.
    private var sessionIntentIDs: Set<UUID> {
        guard let sessionID else { return [] }
        var ids = Set<UUID>()
        for entry in cua.dialogue.entries {
            if entry.intent.source.captureID == sessionID ||
               entry.answers.contains(where: { $0.source.captureID == sessionID }) {
                ids.insert(entry.intent.id)
            }
        }
        for work in cua.tasks where work.provenance?.captureID == sessionID {
            ids.insert(work.intentID)
        }
        return ids
    }

    /// Attempts belonging to the current interaction, in creation order.
    private var interactionWorks: [CuaVoiceRuntime.Work] {
        let intents = sessionIntentIDs
        return cua.tasks.filter { intents.contains($0.intentID) }
    }

    /// A pending clarification owned by the current interaction. It is normal
    /// dialogue state — question text plus its owning intent — not an error.
    private var interactionQuestion: CuaDialogueState.Question? {
        let intents = sessionIntentIDs
        return cua.dialogue.entries.last(where: { entry in
            guard intents.contains(entry.intent.id),
                  case .awaitingAnswer(let id) = entry.status,
                  let question = entry.question,
                  question.id == id, question.revision == entry.revision
            else { return false }
            return true
        })?.question
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

    /// Escape/current-interaction cancel stops only this session's active or
    /// queued attempts — never the diagnostically selected task and never
    /// unrelated background work. A work-less pending question intentionally
    /// survives so the next hold can answer it; Stop All withdraws it.
    private func cancelInteractionWork() {
        let intents = sessionIntentIDs
        for work in cua.tasks where work.active && intents.contains(work.intentID) {
            cua.cancel(work.id)
        }
    }

    /// Pending clarification questions across the dialogue, for surfaces that
    /// show dialogue state without granting control authority.
    var pendingQuestions: [PendingQuestionItem] {
        cua.dialogue.entries.compactMap { entry in
            guard case .awaitingAnswer(let id) = entry.status,
                  let question = entry.question,
                  question.id == id, question.revision == entry.revision
            else { return nil }
            return PendingQuestionItem(id: question.id, prompt: question.prompt,
                                       owner: entry.intent.utterance)
        }
    }

    /// A task may offer explicit retry only while its intent rests in a
    /// retryable state; the runtime's in-place retry policy still owns the
    /// real decision and refuses executing or cancelled intents itself.
    func canRetryTask(_ id: UUID) -> Bool {
        guard let work = cuaTasks.first(where: { $0.id == id }), !work.active,
              let status = cua.dialogue.entry(for: work.intentID)?.status else { return false }
        switch status {
        case .blocked, .failed, .uncertain, .partial: return true
        case .pending, .awaitingAnswer, .executing, .cancelled, .succeeded: return false
        }
    }

    /// An explicit retry resumes the intent in place through the runtime's
    /// direct path — same intent id, fresh attempt, re-observed state. It
    /// never replays a tool call or re-runs a worker directly. Requires an
    /// idle pipeline: it must not interleave with a live capture's events.
    func retryTask(_ id: UUID) {
        guard canRetryTask(id), !captureActive else { return }
        let lane = speech as? RealtimeVoiceLane
        Task { [weak self] in
            let reply = await self?.cua.retryWork(id) ?? "That task is gone."
            lane?.pushTaskEvent("[task outcome] retry: \(reply)", speak: true)
        }
    }

    /// Typed and reviewed commands take the same model turn the voice does —
    /// one decision surface (the realtime model), one screen, one tool set.
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
        Task { [weak self] in
            do { try await lane.submitTyped(text, sessionID: sid) }
            catch { self?.fail("The voice model is unavailable: \(error.localizedDescription)") }
        }
    }

    /// Short stable identity for surfaces that show intent/attempt ids.
    func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// In-memory, content-minimized diagnostics for one attempt: identities,
    /// relation/prerequisite reason, target resolution, context (intent)
    /// revision and effect certainty. Never dumps a literal payload.
    func taskDiagnostics(_ task: CuaVoiceRuntime.Work) -> [String] {
        var lines = ["intent \(shortID(task.intentID)) · attempt \(shortID(task.attemptID))"]
        let entry = cua.dialogue.entry(for: task.intentID)
        var relation: [String] = []
        switch entry?.relationship {
        case .refinement(let id): relation.append("refines \(relatedLabel(id))")
        case .continuation(let id): relation.append("continues \(relatedLabel(id))")
        case .correction(let id): relation.append("corrects \(relatedLabel(id))")
        case .independent, nil: break
        }
        if let prerequisite = entry?.prerequisite {
            let fact = prerequisite.requiredFact == .targetObserved ? "verified target" : "verified result"
            relation.append("requires \(fact) from \(relatedLabel(prerequisite.requiresIntentID))")
        }
        if !relation.isEmpty { lines.append(relation.joined(separator: " · ")) }
        let app = task.bundle ?? entry?.intent.target?.application
        let window = entry?.intent.target?.window
        if app != nil || window != nil || task.window != nil {
            var target = "target: \(app ?? "unresolved")"
            if let window { target += " · window \(window.title ?? window.windowID)" }
            else if let taskWindow = task.window { target += " · window \(taskWindow)" }
            lines.append(target)
        }
        if let revision = entry?.revision {
            lines.append("context revision \(revision) · attempt bound at revision \(task.intentRevision)")
        }
        switch task.outcome {
        case nil: lines.append(task.dispatchedEffect ? "effects dispatched · outcome pending" : "no effects dispatched")
        case .verified, .verifiedFact: lines.append("effects dispatched · verified")
        case .partial: lines.append("effects dispatched · partially verified")
        case .uncertain: lines.append("effects dispatched · outcome uncertain")
        case .failed, .blocked, .cancelled: lines.append("effects dispatched · outcome unverified")
        }
        if task.contentMode != .control {
            if let literal = task.literalText {
                lines.append(task.contentMode == .dictate
                    ? "dictated text (\(literal.count) chars)"
                    : "insert text (\(literal.count) chars)")
            } else {
                lines.append(task.contentMode == .dictate ? "dictation payload pending" : "text payload pending")
            }
        }
        return lines
    }

    private func relatedLabel(_ intentID: UUID) -> String {
        cua.tasks.last { $0.intentID == intentID }?.label ?? "intent \(shortID(intentID))"
    }
    private var speech: SpeechCapturing
    private let dictation: DictationDelivering
    /// Spoken replies seam — nil or Config.ttsEnabled=false stays silent.
    var speaker: SpeechSynthesizing?
    /// Consent yes/no binding: the runtime reports the single pending ask and
    /// consumes the resolution (e.g. gate.approve / gate.deny).
    var pendingConsent: () -> ConsentRequest? = { nil }
    var onConsentResolution: (ConsentRequest, Bool) -> Void = { _, _ in }
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
    private var automatic = true
    private var microphoneTask: Task<Void, Never>?
    private var microphoneEnabled = true
    private var configuredDevice: MicrophoneDevice?
    private var startupTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var beganAt: TimeInterval = 0
    private var releasedAt: TimeInterval = 0
    /// Accumulates the realtime lane's streaming reply text for the detail line.
    private var replyDraft = ""
    var isListening: Bool { status == .listening }
    var canBegin: Bool {
        guard microphoneEnabled else { return false }
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
        // Gates the Escape consume — a background task must not eat the key
        // in other apps; only a presented interaction owns it.
        switch status { case .idle, .done, .error: return false; default: return true }
    }
    var captureActive: Bool { status == .starting || status == .listening || status == .finishing || status == .awaitingRelease || status == .testingMicrophone }

    init(config: Config? = nil, speech: SpeechCapturing? = nil,
         authorize: (() async -> Bool)? = nil,
         timings: VoiceTimings = VoiceTimings(), frontmost: (() -> String?)? = nil,
         cuaRuntime: CuaVoiceRuntime? = nil,
         dictation: DictationDelivering = DictationDelivery(),
         speaker: SpeechSynthesizing? = nil) {
        let config = config ?? Config.shared
        self.config = config
        self.dictation = dictation
        self.speaker = speaker
        self.authorize = authorize ?? { await RealtimeVoiceLane.requestAuthorization() }
        // `speech` must exist before self can appear in closures below.
        self.speech = speech ?? RealtimeVoiceLane(apiKey: { [weak config] in config?.openAIAPIKey ?? "" })
        // No second planner — the realtime model's tool choice is the
        // decision; the runtime routes it (fast lane → drive loop).
        self.cua = cuaRuntime ?? CuaVoiceRuntime(config: config)
        self.timings = timings
        self.frontmost = frontmost ?? { NSWorkspace.shared.frontmostApplication?.localizedName }
        lastExternalApp = self.frontmost()
        appObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastExternalApp = $0.localizedName }
        self.cua.onChange = { [weak self] in self?.cuaChanged() }
        // The realtime lane's tools reach the runtime spine — the model picks
        // the tool; fast lane / drive loop / consent decide how. computer_
        // command returns at spawn and the verified outcome pushes back
        // through taskEventSink as a spoken `[task outcome]`.
        if let lane = self.speech as? RealtimeVoiceLane {
            lane.audioRepliesEnabled = config.ttsEnabled
            lane.commandHandler = { [weak self] instruction, app, literalText, captureID in
                guard let self else { return "Jev is not available." }
                return await self.cua.beginVoiceTask(
                    instruction, app: app,
                    frontmostHint: self.commandFrontmostApp ?? self.lastExternalApp,
                    literalText: literalText,
                    transcriptHint: self.transcript, captureID: captureID)
            }
            lane.taskResponseHandler = { [weak self] answer, captureID in
                guard let self else { return "Nothing is waiting for an answer." }
                // A parked voice ask (task consent or question) wins; then
                // the agent-gate consent; then an honest "nothing pending".
                if let reply = await self.cua.respondToTask(answer, captureID: captureID) {
                    return reply
                }
                if let pending = self.pendingConsent(),
                   let approved = Self.consentAnswer(answer) {
                    self.onConsentResolution(pending, approved)
                    return approved ? "Confirmed — go ahead." : "Cancelled."
                }
                return "Nothing is waiting for an answer."
            }
            lane.delegationHandler = { [weak self] task, agent, name, role, description in
                guard let self else { return "Jev is not available." }
                return await self.cua.delegateToAgent(task: task, agent: agent,
                                                      name: name, role: role,
                                                      description: description)
            }
            lane.cancelHandler = { [weak self] hint in
                guard let self else { return "Nothing is running." }
                return self.cua.cancelVoiceTask(hint)
            }
            lane.screenShotProvider = {
                try? await ScreenCapture.jpeg()
            }
            self.cua.taskEventSink = { [weak lane] _, text, speak in
                lane?.pushTaskEvent(text, speak: speak)
            }
            config.$ttsEnabled.sink { [weak lane] in lane?.audioRepliesEnabled = $0 }
                .store(in: &subscriptions)
        }
        wire(self.speech)
    }

    private func wire(_ capture: SpeechCapturing) {
        capture.onReadiness = { [weak self] readiness in
            guard let self else { return }
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
        missingPermissions = Permission.missing
        if !Permission.microphone.isGranted, microphoneReady { suspendMicrophone("Microphone permission was removed.") }
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
            await prior?.value
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
            await prior?.value
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

    /// Ctrl joined an armed Fn hold — the rest of this capture is dictation.
    func dictate() {
        guard config.dictationHotkey, !dictating else { return }
        guard status == .starting || status == .listening else { return }
        dictating = true
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
        if let inputHandlingMs { measurements["Fn handler"] = inputHandlingMs }
        commandFrontmostApp = lastExternalApp
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            commandFrontmostApp = frontmost() ?? lastExternalApp
        }
        status = .starting
        trace("fn_down")
        let selectedUID = config.microphoneUID
        startupTask = Task { [weak self] in
            await priorStart?.value
            await self?.microphoneTask?.value
            guard let self, self.sessionID == id, !Task.isCancelled else { return }
            defer { if self.sessionID == id { self.startupTask = nil } }
            let permissionStart = ProcessInfo.processInfo.systemUptime
            let granted = await self.authorize()
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
        held = false
        // A latch release keeps the capture listening; the next Fn tap
        // arrives as a plain `.finish` and ends it below.
        guard !latchRelease else { latchRelease = false; return }
        latched = false
        durationTask?.cancel(); durationTask = nil
        switch status {
        case .starting: cancel()
        case .awaitingRelease: showTranscriptReview()
        case .listening:
            releasedAt = ProcessInfo.processInfo.systemUptime
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
        commandFrontmostApp = lastExternalApp
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            commandFrontmostApp = frontmost() ?? lastExternalApp
        }
        trace("typed_command")
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
        if cancelTask { cancelInteractionWork() }
        guard status != .stopping else { return }
        held = false; dictating = false; latched = false
        trace("capture_cancelled")
        sessionID = nil
        deadlineTask?.cancel(); deadlineTask = nil
        durationTask?.cancel(); durationTask = nil
        hideTask?.cancel(); hideTask = nil
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

    func shutdown() async {
        microphoneEnabled = false
        let microphone = microphoneTask
        microphone?.cancel()
        cancel()
        await speech.suspend()
        await microphone?.value
        await cua.shutdown()
        await cleanupTask?.value
    }

    func interruptCapture(_ reason: String) {
        guard captureActive else { return }
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
            if !Permission.microphone.isGranted { await Permission.microphone.request() }
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

    private func newSession() -> UUID {
        deadlineTask?.cancel(); durationTask?.cancel(); hideTask?.cancel()
        latchRelease = false; latched = false
        // A new capture barges in on any spoken reply.
        speaker?.stop()
        let id = UUID(); sessionID = id
        automatic = config.autoExecute
        transcript = ""; detail = ""; resultMessage = ""; audioLevel = 0; replyDraft = ""
        measurements = [:]
        beganAt = ProcessInfo.processInfo.systemUptime
        return id
    }

    private func receive(_ event: SpeechEvent, session id: UUID) {
        guard sessionID == id else { return }
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
        case .turnEnded:
            let reply = replyDraft.isEmpty ? detail : replyDraft
            replyDraft = ""
            guard status != .idle, status != .done else { return }
            // A parked question or approval still needs the card — the
            // STARTED fast-path ends turns while work is live, and an ask
            // that lands after dismissal would be unreachable.
            if interactionQuestion != nil || pendingTaskApproval != nil { return }
            // The reply already played through the lane's speaker — complete
            // without re-speaking it via the TTS seam.
            complete(reply.isEmpty ? "Done." : reply, session: id, voiced: false)
            return
        case .heardFinal(let text):
            // The model already heard the audio — this transcript is display
            // only; the function call carries the instruction into the
            // runtime. The completion can arrive AFTER the reply starts
            // streaming (status already .executing) — record it regardless,
            // or the user's own words never show on the card.
            transcript = text
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
        case .failure, .assistantDelta, .assistant, .turnEnded, .heardFinal:
            break // handled above — these outlive the capture window
        case .timing(let name, let milliseconds):
            guard milliseconds.isFinite, milliseconds >= 0 else { return }
            measurements[name] = milliseconds
            Self.voiceLog.notice("capture=\(id.uuidString, privacy: .public) timing=\(name, privacy: .public) milliseconds=\(milliseconds)")
        case .level(let level): audioLevel = level
        case .partial(let text):
            // Realtime transcription deltas are display-only — the tool call
            // carries the real instruction; fragments never reach the runtime.
            guard text != transcript else { return }
            transcript = text
            if measurements["First partial"] == nil { measurements["First partial"] = (ProcessInfo.processInfo.systemUptime - beganAt) * 1000 }
        case .final(let text):
            transcript = text
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
                cancelCaptureAttempt()
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
            cancelCaptureAttempt()
            return
        }
        if dictating {
            deliver(text, session: id)
            return
        }
        // A bare yes/no with exactly one pending consent ask is a resolution,
        // not an utterance — surfaced through the runtime's hook.
        if let request = pendingConsent(), let approved = Self.consentAnswer(text) {
            onConsentResolution(request, approved)
            complete(approved ? "Approved." : "Denied.", session: id)
            return
        }
        if automatic { status = .executing; routeCommand(text) }
        else { status = .awaitingConfirm; detail = "Run this request through Cua?" }
    }

    /// Literal delivery to the focused editable element via the
    /// DictationDelivering seam — no intent is recorded for it.
    private func deliver(_ text: String, session id: UUID) {
        status = .executing
        detail = "Dictating into the focused field…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.dictation.deliver(text)
                guard self.sessionID == id else { return }
                self.complete("Dictated into the focused field.", session: id)
            } catch {
                guard self.sessionID == id else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    /// A bare yes/no — normalized against punctuation — that resolves the
    /// single pending consent ask.
    static func consentAnswer(_ text: String) -> Bool? {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "yes", "yeah", "yep": return true
        case "no", "nope", "nah": return false
        default: return nil
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
        hideTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.timings.dismissal * 1e9)) } catch { return }
            if self.sessionID == id, self.status == .done { self.status = .idle }
        }
    }

    private func cuaChanged() {
        objectWillChange.send()
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
            guard interactionQuestion != nil || pendingTaskApproval != nil else { return }
        default: return
        }
        // Only this session's dialogue decides the interaction's presentation.
        // A pending clarification is a normal question state, not a failure.
        if let question = interactionQuestion {
            detail = question.prompt
            speak(question.prompt)
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
        if case .awaitingAnswer = status, interactionWorks.isEmpty {
            // The question was withdrawn without an answer; the interaction ends.
            status = .idle
            return
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
        audioLevel = 0; held = false; dictating = false; latched = false; isMicrophoneTest = false
        deadlineTask?.cancel(); durationTask?.cancel()
        status = .error(message)
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
