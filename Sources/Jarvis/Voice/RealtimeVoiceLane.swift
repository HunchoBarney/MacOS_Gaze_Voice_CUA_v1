import AppKit
import AVFoundation
import OSLog
import Synchronization
import JarvisCore

/// The voice lane: one OpenAI realtime session carries hearing,
/// reasoning and speech — no separate STT, planner hop, or TTS call on the
/// voice path. The model decides *what*; our execution spine (fast lane →
/// drive loop → consent → verification) still decides *how* via the
/// `computer_command` function tool.
///
/// A manual capture (dictation, the microphone test, typed review) maps
/// onto the documented recipe: `turn_detection: null`, the capture streams
/// `input_audio_buffer.append`, its finish sends `commit` +
/// `response.create`. A capture that starts while the model speaks is a
/// barge-in: `response.cancel` + `conversation.item.truncate` + local
/// playback stops.
@MainActor
final class RealtimeVoiceLane: SpeechCapturing {
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis.voice", category: "realtime")
    private var presentationHandler: ((UUID, SpeechEvent) -> Void)?
    private lazy var eventRelay: (UUID, SpeechEvent) -> Void = { [weak self] id, event in
        guard let self else { return }
        self.presentationHandler?(id, event)
        switch event {
        case .assistantDelta, .assistant, .toolSay, .turnEnded, .failure: self.quietFiller(turn: id)
        default: break
        }
        if self.remoteReplyTurn == id {
            switch event {
            case .turnEnded: self.finishRemoteReply()
            case .failure(let message): self.finishRemoteReply(error: VoiceError(message))
            default: break
            }
        }
    }
    var onEvent: ((UUID, SpeechEvent) -> Void)? {
        get { eventRelay }
        set { presentationHandler = newValue }
    }
    var onReadiness: ((SpeechReadiness) -> Void)?
    var onCommandStage: ((UUID, VoiceCommandTrace.Stage) -> Void)?
    /// Per-admission diagnostic — fires once per decided turn (voice and
    /// typed) with the final text and route. Evidence capture only; nil in
    /// normal use and never consulted for behavior.
    var onAdmission: ((UUID, String, VoiceRoute) -> Void)?
    var onDiagnostic: ((VoiceSpeechDiagnostic) -> Void)?

    /// Runs a spoken instruction through the runtime. Wired by VoiceController
    /// — returns the moment the work is *accepted* ("STARTED — …"); the real
    /// outcome arrives later via `pushTaskEvent`. The UUID is the hold's
    /// capture id so the work binds to this interaction. The transcript is
    /// this turn's COMPLETED speech transcript (nil for typed turns) — the
    /// runtime's heard-vs-called check wants the user's final words.
    /// `steps` carries the model's inline plan for multi-part requests.
    /// The memory intents, nil while `voice.live` is off; typed and held
    /// turns admit them locally and `commandHandler` answers them.
    var memoryCommands: (() -> MemoryCommands?)?
    var commandHandler: (String, String?, String?, String?, [String], UUID) async -> String = { _, _, _, _, _, _ in
        #"{"status":"refused","say":"Computer control is unavailable."}"#
    }
    /// Answers a parked ask — yes/no consent or a free-text task question.
    /// The optional task hint (request text, app name, or an ordinal) picks
    /// which ask when several are parked. Wired by VoiceController.
    var taskResponseHandler: (String, String?, UUID) async -> String = { _, _, _ in
        #"{"status":"nothing_pending","say":"Nothing is waiting for an answer."}"#
    }
    /// Hands work to a persistent background agent (sessions_*).
    var delegationHandler: (String, String?, String?, String?, String?) async -> String = { _, _, _, _, _ in
        #"{"status":"refused","say":"No agents are configured."}"#
    }
    /// Stops running work — "cancel that", "stop", "never mind".
    var cancelHandler: (String?) async -> String = { _ in
        #"{"status":"nothing_running","say":"Nothing is running."}"#
    }
    var exactTaskResponseHandler: (String, UUID, UUID, UUID) async -> String = { _, _, _, _ in
        VoiceToolCatalog.result(status: "blocked", summary: "That question is no longer available.", error: "ask_changed")
    }
    var exactCancellationHandler: (UUID) async -> String = { _ in
        VoiceToolCatalog.result(status: "blocked", summary: "No owned task was selected.", error: "ambiguous_task")
    }
    var admissionContextProvider: (@MainActor () async -> VoiceAdmissionContext)?
    var semanticEnabled: @MainActor () -> Bool = { false }
    /// Diagnostic runs must not accidentally spend on a second service.
    var remoteReasoningPermitted = true
    var semanticInterpretation: (@MainActor (VoiceAdmission, VoiceAdmissionContext) async throws
        -> VoiceSemanticRouter.Outcome)?
    var semanticContextProvider: (@MainActor () async -> VoiceAdmissionContext)?
    var semanticConfirmationHandler: (@MainActor (VoiceSemanticRouter.Proposal) async -> Bool)?
    /// The caller's wall on one semantic hop, from its start.
    static let semanticWall: TimeInterval = 4
    /// Waits out the semantic wall. Internal for tests, which fire it by hand.
    var semanticDeadline: @Sendable (TimeInterval) async throws -> Void = sleepUntilUptime
    private var semanticTask: Task<(VoiceSemanticRouter.Outcome, VoiceAdmissionContext), Error>?
    private var semanticTurn: VoiceTurnToken?
    private var semanticGeneration: UInt64 = 0

    func cancelSemanticInterpretation() {
        semanticGeneration &+= 1
        semanticTask?.cancel()
    }

    /// A clear user app-focus instruction authorizes only its bounded typed action.
    /// A no-match alone can continue the original, still-current remote path.
    private func handleSemanticIfNeeded(_ admission: VoiceAdmission) async -> Bool {
        let captured = speechSession.boundContext
        guard semanticEnabled(), VoiceSemanticRouter.eligible(admission, context: captured) else { return false }
        guard let interpret = semanticInterpretation,
              let freshContext = semanticContextProvider ?? admissionContextProvider,
              let confirm = semanticConfirmationHandler else {
            onEvent?(admission.turn.id, .toolSay("Semantic app suggestions are unavailable. No action was prepared."))
            completeLocalDecision(admission, reportAdmission: false)
            return true
        }
        let id = admission.turn.id
        let generation = semanticGeneration
        onDiagnostic?(.init(turn: id, stage: "semantic.begin", metrics: [:]))
        let began = ProcessInfo.processInfo.systemUptime
        let timings = VoiceSemanticRouter.StageTimings()
        let expire = semanticDeadline
        let task = VoiceSemanticRouter.$stageTimings.withValue(timings) {
            Task {
                try await withVoiceDeadline(until: ProcessInfo.processInfo.systemUptime + Self.semanticWall,
                                            expire: expire) {
                    let interpretStart = ProcessInfo.processInfo.systemUptime
                    do {
                        let result = try await interpret(admission, captured)
                        timings.record("interpret_ms",
                            milliseconds: (ProcessInfo.processInfo.systemUptime - interpretStart) * 1000)
                        try Task.checkCancellation()
                        let freshStart = ProcessInfo.processInfo.systemUptime
                        let fresh = await freshContext()
                        timings.record("fresh_context_ms",
                            milliseconds: (ProcessInfo.processInfo.systemUptime - freshStart) * 1000)
                        try Task.checkCancellation()
                        return (result, fresh)
                    } catch {
                        if timings.metrics["interpret_ms"] == nil {
                            timings.record("interpret_ms",
                                milliseconds: (ProcessInfo.processInfo.systemUptime - interpretStart) * 1000)
                        }
                        throw error
                    }
                }
            }
        }
        semanticTask = task; semanticTurn = admission.turn
        defer {
            if semanticTurn == admission.turn { semanticTask = nil; semanticTurn = nil }
        }
        do {
            let (result, fresh) = try await task.value
            guard turnID == id, speechSession.gate.isCurrent(admission.turn), !Task.isCancelled else { return true }
            guard generation == semanticGeneration else {
                semanticFailed(turn: id, timings: timings, began: began, code: 4)
                onEvent?(id, .toolSay("Semantic interpretation was cancelled. No action was prepared."))
                completeLocalDecision(admission, reportAdmission: false)
                return true
            }
            guard generation == semanticGeneration, semanticEnabled(),
                  VoiceSemanticRouter.contextIsCurrent(captured, current: fresh) else {
                semanticFailed(turn: id, timings: timings, began: began, code: 4)
                onEvent?(id, .toolSay("The request context changed. No semantic action was prepared."))
                completeLocalDecision(admission, reportAdmission: false)
                return true
            }
            let metrics = semanticMetrics(timings, began: began)
            switch result {
            case .noMatch:
                onDiagnostic?(.init(turn: id, stage: "semantic.no_match", metrics: metrics))
                return false
            case .clarify:
                onDiagnostic?(.init(turn: id, stage: "semantic.clarify", metrics: metrics))
                onEvent?(id, .toolSay("Which application do you mean? No semantic action was prepared."))
            case .proposal(let proposal):
                var proposed = metrics
                proposed["action_confidence"] = proposal.actionConfidence
                proposed["target_confidence"] = proposal.targetConfidence
                onDiagnostic?(.init(turn: id, stage: "semantic.proposal", metrics: proposed))
                guard VoiceSemanticRouter.permitsRequestedFocus(proposal) else {
                    onEvent?(id, .toolSay("Which application do you mean?"))
                    break
                }
                guard proposal.turn == admission.turn,
                      VoiceSemanticRouter.targetIsCurrent(proposal.target, context: fresh) else {
                    onEvent?(id, .toolSay("That application changed or is unavailable. No action was prepared."))
                    completeLocalDecision(admission, reportAdmission: false)
                    return true
                }
                if !(await confirm(proposal)) {
                    onDiagnostic?(.init(turn: id, stage: "semantic.rejected", metrics: [:]))
                    onEvent?(id, .toolSay("That app request could not be admitted. No action was taken."))
                } else {
                    onDiagnostic?(.init(turn: id, stage: "semantic.accepted", metrics: [:]))
                }
            }
        } catch {
            guard turnID == id, speechSession.gate.isCurrent(admission.turn) else { return true }
            semanticFailed(turn: id, timings: timings, began: began, code: semanticFailureCode(error))
            onEvent?(id, .toolSay("Semantic interpretation stopped or is unavailable. No semantic action was prepared."))
        }
        completeLocalDecision(admission, reportAdmission: false)
        return true
    }

    /// Stage metrics for one semantic hop — fixed numeric keys only.
    /// `interpret_ms` falls back to wall-clock when the in-flight record
    /// never landed (the deadline fired or the hop was cancelled mid-wait).
    private func semanticMetrics(_ timings: VoiceSemanticRouter.StageTimings,
                                 began: TimeInterval) -> [String: Double] {
        var metrics = timings.metrics
        if metrics["interpret_ms"] == nil {
            metrics["interpret_ms"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
        }
        return metrics
    }

    private func semanticFailed(turn id: UUID, timings: VoiceSemanticRouter.StageTimings,
                                began: TimeInterval, code: Double) {
        var metrics = semanticMetrics(timings, began: began)
        metrics["failure"] = code
        onDiagnostic?(.init(turn: id, stage: "semantic.failed", metrics: metrics))
    }

    /// The diagnostic channel carries numbers only — a category is a code,
    /// never a message, request, target identity or credential:
    /// 1 deadline, 2 transport, 4 cancelled, 5 protocol/decode.
    private func semanticFailureCode(_ error: Error) -> Double {
        if error as? LocalSpeechError == .deadline { return 1 }
        if error is CancellationError { return 4 }
        if let failure = error as? VoiceSemanticRouter.Failure,
           failure == .invalidResponse || failure == .invalidContext { return 5 }
        return 2
    }
    private var responseAuthority = VoiceResponseAuthority()
    private var pendingReasoning: VoiceAdmission?
    private var pendingInput: (turn: VoiceTurnToken, itemID: String?, typed: Bool, acknowledged: Bool)?
    private var seenInputItems: Set<String> = []
    private var wirePump: Task<Void, Never>?
    private let admissionOwner: LocalSpeechSession?
    private var remoteConversationOwner: LocalSpeechSession?
    private var speechSession: LocalSpeechSession { remoteConversationOwner ?? baseSpeechSession }
    private lazy var baseSpeechSession: LocalSpeechSession = {
        let session = admissionOwner ?? LocalSpeechSession { [weak self] admission in
            await self?.executeLocal(admission)
        }
        if onDiagnostic != nil {
            session.onDiagnostic = { [weak self] diagnostic in
                Task { @MainActor [weak self] in self?.onDiagnostic?(diagnostic) }
            }
        }
        session.memoryCommands = { [weak self] in self?.memoryCommands?() }
        session.onPartial = { [weak self] id, text in
            guard self?.turnID == id else { return }
            self?.onEvent?(id, .partial(text))
        }
        session.onDecision = { [weak self] admission in
            guard self?.turnID == admission.turn.id else { return }
            let stage: VoiceCommandTrace.Stage
            switch admission.route {
            case .local: stage = .admissionLocal
            case .remote: stage = .admissionRemote
            case .clarify: stage = .admissionClarify
            case .refuse: stage = .admissionRefuse
            case .dictation: stage = .admissionDictation
            }
            self?.onCommandStage?(admission.turn.id, stage)
            self?.onAdmission?(admission.turn.id, admission.text, admission.route)
            if admission.route == .clarify {
                switch admission.reason {
                case "ungrounded_target": self?.onCommandStage?(admission.turn.id, .ungroundedTarget)
                case "target_changed": self?.onCommandStage?(admission.turn.id, .changedTarget)
                case "ambiguous_ask", "ask_changed": self?.onCommandStage?(admission.turn.id, .ambiguousAsk)
                default: break
                }
            }
            if admission.route != .dictation { self?.onEvent?(admission.turn.id, .heardFinal(admission.text)) }
        }
        return session
    }()
    /// Facts about right now — local time, active app, what's waiting.
    /// Injected as a [context] note once per user turn; wired by
    /// VoiceController.
    var contextProvider: (@MainActor () async -> String)?
    /// Dictation holds commit audio but suppress the spoken reply — the
    /// transcript is delivered literally instead. `false` = commit only.
    var respondOnCommit = true {
        didSet { if !respondOnCommit { speechSession.enterDictation() } }
    }
    /// Replies stay silent when the user muted spoken output in settings.
    var audioRepliesEnabled = true {
        didSet {
            outputGate.store(audioRepliesEnabled && !holding, ordering: .releasing)
            if !audioRepliesEnabled {
                _ = player.interrupt(untilResponseDone: responseInFlight)
                retireFeedback()
            }
        }
    }
    /// Off-actor playback gate = replies enabled && !holding. The socket
    /// loop reads it directly: model audio enqueues without a MainActor
    /// hop, and a stray response that outraced response.cancel dies here
    /// instead of talking over the user's hold.
    private let outputGate = Atomic<Bool>(true)

    /// A turn that waits on the model for its answer says one short filler
    /// when nothing has been spoken this long after the hand-off: silence
    /// reads as failure, and a fast answer needs no preamble.
    static let fillerDelay: Duration = .milliseconds(1200)
    static let fillerLine = "Looking…"
    /// Voices the filler through the controller's fixed-line guards.
    var onFiller: ((UUID, String) -> Void)?
    /// Waits out `fillerDelay`. Internal for tests — a scripted clock.
    var fillerClock: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    private var filler: (turn: UUID, task: Task<Void, Never>)?
    private var fillerSpokenTurn: UUID?

    private let credential: () async throws -> RealtimeCredential?
    private let client: RealtimeVoiceClient
    let player = RealtimePlayer()
    private let input = MicrophoneInput()
    /// Hears the microphone while set: the wake word in Standby.
    var wakeListener: (any WakeWordDetecting)? {
        didSet { input.gate.listen(wakeListener) }
    }
    private var hardware: MicrophoneInput.Ready?
    /// Opens the selected microphone for listening and conversations.
    /// Internal for tests: a fixture input stands in for the hardware, so
    /// recovery runs without a microphone.
    lazy var prepareInput: @MainActor (String?, Bool, @escaping @Sendable () -> Void) async throws -> MicrophoneInput.Ready = {
        [input] uid, voiceProcessing, interrupted in
        guard Permission.microphone.isGranted else {
            throw VoiceError("Microphone access is needed. It's under Privacy & Security, then Microphone.")
        }
        return try await input.prepare(device: MicrophoneCatalog.resolve(uid: uid), voiceProcessing: voiceProcessing,
                                       interrupted: interrupted)
    }
    private var duplexRequested = false
    private var desiredInputMode: RealtimeVoiceClient.InputMode = .conversation
    private var conversationFeed: ConvertedAudioFeed?
    /// The last 20 s of hands-free speech sent to Realtime, for L7's
    /// on-device second transcription of "type this …".
    let recentSpeech = RecentSpeechAudio()
    private var conversationStartID = UUID()
    private var conversationMeter: Timer?
    private var conversationSender: Task<Void, Never>?
    private var conversationGate: VoiceActivityGate?
    private var conversationUnreadySince: TimeInterval?
    private var feedbackSuspended = true
    private var feedbackGeneration: UInt64 = 0
    private struct RemoteInput {
        let capture: ConversationSession.RemoteCapture
        var committed = false
        var final: String?
        var deadline: Task<Void, Never>?
    }
    private var remoteInputs: [String: RemoteInput] = [:]
    private var remoteInputOrder: [String] = []
    private var localSpeakingKey: String?
    private var awaitingCommit: [String] = []
    /// How long a turn waits for its commit and then its transcript.
    /// Internal for tests.
    var commitConfirmationTimeout: Duration = .seconds(8)
    /// Waits out one commit's confirmation timeout. Internal for tests, which
    /// fire it by hand.
    var commitConfirmationTimer: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var remoteInputDrain: Task<Void, Never>?
    private var remoteReplyTurn: UUID?
    private var remoteReplyContinuation: CheckedContinuation<Void, Error>?
    private var remoteDesktopExecutor: ConversationSession.RemoteExecutor?
    private struct ManualInput {
        let turn: VoiceTurnToken
        let connection: UUID
        var committed: VoiceRealtimeInput?
        var finals: [String: String] = [:]
        var failures: Set<String> = []
        var commitRequested = false
        var finishing = false
    }
    private var manualInput: ManualInput?
    private var manualCaptureConnection: UUID?
    private var manualFinalContinuation: CheckedContinuation<VoiceAdmission?, Error>?
    private var manualFinalDeadline: Task<Void, Never>?
    var onPlaybackOutputs: ((VoicePlaybackOutputs?) -> Void)?
    var onConversationMeter: ((Float, Bool) -> Void)?
    var onConversationState: ((ConversationListeningState) -> Void)?
    var playbackRoutingReady: (() -> Bool)?
    private(set) lazy var conversation: ConversationSession = {
        let session = ConversationSession()
        session.makeSpeechSession = { [weak self] context in
            guard let self else { throw CancellationError() }
            let owner = LocalSpeechSession { _ in }
            owner.context = context
            owner.onDiagnostic = { [weak self] diagnostic in
                Task { @MainActor [weak self] in self?.onDiagnostic?(diagnostic) }
            }
            return owner
        }
        session.onDiagnostic = { [weak self] diagnostic in
            Task { @MainActor [weak self] in self?.onDiagnostic?(diagnostic) }
        }
        session.onEnded = { [weak self] _, reason in
            self?.closeConversationFeed()
            self?.onConversationState?(.unavailable(reason))
        }
        session.onBargeIn = { [weak self] in self?.interruptConversationPlayback() }
        session.remote = { [weak self] admission, owner, execute in
            guard let self else { throw CancellationError() }
            try await self.respondToConversation(admission, owner: owner, execute: execute)
        }
        return session
    }()
    private var prepared: Session?
    /// Internal for tests — scripted captures bind it without a socket.
    var active: (id: UUID, session: Session)?
    private var preparation: Task<String, Error>?
    /// When the in-flight prepare spawned — a prepare outliving the
    /// session-confirm window is wedged on a dead wait, and re-joining it
    /// would chain the wedge into every later request.
    private var preparationBeganAt = Date.distantPast
    private var preparationID = UUID()
    private var selectedUID: String?
    private var enabled = false
    private var finishTask: Task<Void, Never>?
    private var meterTimer: Timer?
    /// Reconnect backoff — a persistent failure (bad key, rejected session)
    /// must not spin the socket.
    private var reconnectAttempts = 0
    /// A fatal session error (auth, billing, unsupported model) stops the
    /// idle reconnect loop until the next explicit prepare — the hold itself
    /// is the retry, so a fix in settings takes effect on the next keypress.
    private var lastSessionError: String?
    /// Function calls dispatched this turn — a turn only ends when the model
    /// has answered after every tool result it asked for.
    private var pendingCalls: Set<String> = []
    /// Dedupes tool calls for the SOCKET's lifetime — call_ids are unique
    /// per session, so this clears where the connection rebuilds, not per
    /// hold. Clearing it per hold let a cancelled response's response.done
    /// re-dispatch its calls, running the command twice under the new hold.
    private var handledCalls: Set<String> = []
    private var assistantText = ""
    /// Legacy receive bookkeeping; remote transcripts never drive display.
    private var transcriptInFlight = ""
    /// This turn's completed input transcript — stored at .transcriptDone so
    /// a computer_command that outraced it still carries the final heard
    /// text, never a mid-turn partial. Internal for tests.
    var turnTranscript: String?
    /// This turn's audio commit went out and no .transcriptDone/.transcriptFailed
    /// has settled it — a completion is owed, so a command dispatch waits
    /// briefly for it rather than guessing at args. Armed at commit; typed
    /// turns never arm it, so they never wait. Also the provenance gate: a
    /// completion arriving before this turn's commit belongs to a dead turn.
    /// Internal for tests.
    var transcriptPending = false
    /// The committed audio item's id — a completion carrying a different
    /// item_id belongs to a dead turn. Internal for tests.
    var turnAudioItemID: String?
    /// True while a manual capture is open — pushed outcomes wait as context
    /// until it finishes rather than talking over it.
    private var holding = false {
        didSet { outputGate.store(audioRepliesEnabled && !holding, ordering: .releasing) }
    }
    /// response.create serialisation — the API rejects a second response
    /// while one is generating, so turns and pushed outcomes queue here.
    /// Internal for tests — scripted turns mark the gate without a socket.
    var responseInFlight = false
    private var wantResponse = false
    private var pendingOutcomeReady = false
    /// A model reply is armed or streaming — its voice owns the audio, so
    /// a deterministic `say` pushed right now must queue behind it, not
    /// speak over it through the local seam.
    var responseVoiceArmed: Bool { responseInFlight || wantResponse }
    /// `[task outcome]` pushes waiting for a free response slot — each
    /// carries its send-attempt count so a .closed migration preserves
    /// the retry budget instead of resetting it.
    /// Internal for tests — the queue is scripted directly, no socket.
    var speakQueue: [(text: String, attempts: Int)] = []
    /// Runaway tool-call breaker (short-circuits
    /// the turn and forces a spoken answer instead of looping tools).
    private var toolCallsThisTurn = 0
    private var responseWatchdog: Task<Void, Never>?
    /// Outcome pushes that hit a dead socket — re-sent oldest-first when
    /// the next session confirms, or verified results are silently lost.
    /// Internal for tests — asserted after a .closed migrates speakQueue.
    var retryOutcomePush = OutcomeRetryQueue()
    /// Last injected [context] note — each turn replaces it rather than
    /// stacking stale frontmost-app/time facts on top of each other.
    private var lastContextItemID: String?
    /// A screen-text result is waiting for the model to answer from it.
    /// Internal for tests.
    var toolRelayOwed = false
    /// Screen-text tool results still in the conversation — deleted once
    /// the answer settles, so window text never outlives its turn.
    /// Internal for tests.
    var screenItems: [String] = []
    /// The digest the pending screen answer reads from — its refs turn the
    /// control the answer names into a frame to glow. Internal for tests.
    var screenAnswer: ScreenDigest?
    /// Reads the focused window, plus every visible window's title for the
    /// screen scope. Tests inject digests; the live read walks AX.
    var screenReader: @MainActor (ScreenQuestion.Scope) async
        -> (focused: ScreenDigest?, windows: [ScreenQuestion.WindowTitle]) = { scope in
        (await ScreenContext.readFocused(), scope == .screen ? await ScreenContext.visibleWindows() : [])
    }
    /// Glows the control a screen answer names. Wired by VoiceController.
    var onScreenPoint: ((CGRect) -> Void)?
    /// Serializes cancel()'s server sends against the next hold's stream —
    /// a clearAudio landing late would wipe freshly streamed audio.
    private var teardownTask: Task<Void, Never>?
    /// turnEnded belongs to the user's turn only — a pushed outcome's
    /// response.done must not close the interaction.
    /// Internal for tests — scripted turns arm it without a socket.
    var awaitingTurnEnd = false
    /// Set once THIS turn's response.create actually went out — a done
    /// belonging to a cancelled or queued response arriving in between
    /// must not satisfy awaitingTurnEnd.
    /// Internal for tests — scripted turns set it without a socket.
    var turnResponseOutstanding = false
    /// A response.cancel is outstanding — the cancelled response's late
    /// function_call_arguments.done (and the call list in its done) must
    /// not dispatch under the next hold.
    /// Internal for tests — scripted turns set it without a socket.
    var cancelledResponsePending = false
    /// response.done lands before the speaker drains — the card would close
    /// mid-sentence. When set, the next player idle emits the held turnEnded.
    private var pendingTurnEndOnIdle = false
    private var drainDeadline: Task<Void, Never>?
    /// The identity turn events and tool calls bind to — the active capture's
    /// id while holding, or the controller's session id for a typed command.
    /// Internal for tests — scripted turns bind it without a hold.
    var turnID: UUID?

    /// Internal for tests — scripted captures construct it directly.
    @MainActor
    final class Session {
        let name: String
        let feed: ConvertedAudioFeed
        /// Mic-test sessions meter hardware only — their audio must never
        /// reach the socket. Set true when the prepared session becomes live.
        var sendsAudio: Bool
        var sender: Task<Void, Never>?
        var localTurn: VoiceTurnToken?
        init(name: String, feed: ConvertedAudioFeed, sendsAudio: Bool) {
            self.name = name; self.feed = feed; self.sendsAudio = sendsAudio
        }
    }

    /// Dead-socket outcome pushes — FIFO capped at 4, drop-oldest. A single
    /// overwrite slot silently lost every verified outcome after the first
    /// when several landed during one reconnect gap. Entries also carry
    /// their failed send count: retries ride the reconnect's own backoff
    /// (each attempt waits for a fresh session.confirm), but a socket that
    /// keeps dying stops replaying an outcome after `maxAttempts`.
    struct OutcomeRetryQueue {
        static let maxAttempts = 3
        private(set) var items: [(text: String, attempts: Int)] = []
        var isEmpty: Bool { items.isEmpty }
        mutating func push(_ text: String, attempts: Int = 0) {
            items.append((text, attempts))
            if items.count > 4 { items.removeFirst() }
        }
        /// Empties the queue, returning items oldest-first.
        mutating func drain() -> [(text: String, attempts: Int)] {
            let all = items
            items = []
            return all
        }
    }

    /// `credential` is asked once per new socket: a developer's own key,
    /// or a fresh client secret from Jarvis's service.
    init(credential: @escaping () async throws -> RealtimeCredential?, client: RealtimeVoiceClient? = nil,
         admissionOwner: LocalSpeechSession? = nil) {
        self.credential = credential
        self.duplexRequested = true
        self.admissionOwner = admissionOwner
        self.client = client ?? RealtimeVoiceClient()
        self.client.onEvent = nil
        let (stream, continuation) = AsyncThrowingStream<RealtimeVoiceClient.WireEnvelope, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1024))
        self.client.onWireEvent = { envelope in
            if case .dropped = continuation.yield(envelope) {
                continuation.finish(throwing: VoiceError("Remote response frames were lost. No new tool will be admitted."))
            }
        }
        wirePump = Task { [weak self] in
            do {
                for try await envelope in stream { self?.handleWire(envelope) }
            } catch {
                self?.responseAuthority.revoke()
                self?.client.teardown()
                if let id = self?.turnID { self?.onEvent?(id, .failure(error.localizedDescription)) }
            }
        }
        player.onPlaybackIdle = { [weak self] in
            Task { @MainActor in
                guard let self, self.pendingTurnEndOnIdle else { return }
                self.pendingTurnEndOnIdle = false
                self.drainDeadline?.cancel()
                if let id = self.turnID {
                    self.onEvent?(id, .turnEnded)
                    self.turnID = nil
                }
                self.prepareNext()
            }
        }
    }

    /// Straight to OpenAI with this key; an empty one reports the missing key.
    convenience init(apiKey: @escaping () -> String, client: RealtimeVoiceClient? = nil,
                     admissionOwner: LocalSpeechSession? = nil) {
        self.init(credential: { RealtimeCredential(key: apiKey(), model: nil) },
                  client: client, admissionOwner: admissionOwner)
    }

    static func requestAuthorization() async -> Bool {
        if !Permission.microphone.isGranted { await Permission.microphone.request() }
        return Permission.microphone.isGranted
    }

    /// Only current local window commands inherit the hold's window authority.
    func capturedLocalWindowID(for id: UUID) -> Int? {
        guard turnID == id, let admission = speechSession.gate.admission,
              admission.turn.id == id, speechSession.gate.isCurrent(admission.turn),
              admission.route == .local, ["type", "hotkey", "scroll"].contains(admission.intent)
        else { return nil }
        return speechSession.boundContext.windowID
    }

    private func executeLocal(_ admission: VoiceAdmission) async {
        guard speechSession.gate.isCurrent(admission.turn), !Task.isCancelled else { return }
        onCommandStage?(admission.turn.id, .localBegin)
        defer { onCommandStage?(admission.turn.id, .localEnd) }
        let output: String
        switch admission.intent {
        case "respond":
            guard let t = admission.slots["task_id"].flatMap(UUID.init(uuidString:)),
                  let a = admission.slots["ask_id"].flatMap(UUID.init(uuidString:)) else { return }
            output = await exactTaskResponseHandler(admission.text, t, a, admission.turn.id)
        case "cancel":
            guard let t = admission.slots["task_id"].flatMap(UUID.init(uuidString:)) else { return }
            output = await exactCancellationHandler(t)
        default:
            let target: String?
            if admission.intent == "open" { target = admission.slots["target_id"] }
            else { target = speechSession.boundContext.targetAppID }
            let command = DriveLoop.repairsOffer(admission.text)
                ? admission.text
                : VoiceAdmissionPolicy.commandText(admission.text, context: speechSession.boundContext)
            output = await commandHandler(command, target, admission.slots["text"],
                                          admission.text, [], admission.turn.id)
        }
        guard turnID == admission.turn.id, !holding else { return }
        if let say = Self.deterministicSay(output) { onEvent?(admission.turn.id, .toolSay(say)) }
    }

    private func handleWire(_ envelope: RealtimeVoiceClient.WireEnvelope) {
        guard envelope.connectionID == client.connectionID else { return }
        for case .rejected(let eventID) in envelope.events { rejectedCommit(eventID) }
        if handleRemoteInput(envelope) { return }
        if envelope.kind == "session.updated" {
            responseAuthority.connect(envelope.connectionID)
        }
        if envelope.kind == "response.created" {
            if let id = envelope.responseID {
                if responseAuthority.retireCreated(connection: envelope.connectionID, responseID: id) {
                    Task { [weak self] in
                        guard let self, self.client.connectionID == envelope.connectionID else { return }
                        try? await self.client.cancelResponse(responseID: id)
                    }
                    return
                }
                _ = responseAuthority.bindCreated(connection: envelope.connectionID, responseID: id)
                Self.log.notice("response_created id=\(id, privacy: .public)")
            }
            return
        }
        if envelope.kind == "response.done", let response = envelope.responseID,
           responseAuthority.finishRetired(connection: envelope.connectionID, responseID: response) {
            player.responseDidFinish()
            responseInFlight = false
            cancelledResponsePending = false
            responseWatchdog?.cancel()
            requestResponseWhenFree()
            return
        }
        if envelope.kind == "input_audio_buffer.committed",
           let item = envelope.inputItemID, !seenInputItems.contains(item),
           let input = pendingInput, !input.typed, turnID == input.turn.id,
           speechSession.gate.isCurrent(input.turn) {
            seenInputItems.insert(item)
            pendingInput = (input.turn, item, false, true)
            turnAudioItemID = item
            requestResponseWhenFree()
            return
        }
        for event in envelope.events {
            switch event {
            case .itemCreated(let id, _):
                if let input = pendingInput, input.typed, input.itemID == id,
                   turnID == input.turn.id, speechSession.gate.isCurrent(input.turn) {
                    pendingInput = (input.turn, id, true, true)
                    requestResponseWhenFree()
                }
            case .transcriptDelta, .transcriptDone, .transcriptFailed:
                break
            case .functionCall(let call, let name, let arguments):
                guard let response = envelope.responseID,
                      let admission = speechSession.gate.admission,
                      admission.turn == responseAuthority.boundTurn,
                      turnID == admission.turn.id,
                      responseAuthority.takeExecutor(connection: envelope.connectionID,
                                                     responseID: response, callID: call) else { continue }
                dispatchToolV1(callID: call, name: name, arguments: arguments, admission: admission,
                               connection: envelope.connectionID)
            case .outputAudio(let data, let item):
                guard let response = envelope.responseID,
                      responseAuthority.matches(connection: envelope.connectionID, responseID: response),
                      responseAuthority.purpose == .outcomeOnly || speaksDuringReasoning,
                      outputGate.load(ordering: .acquiring) else { continue }
                quietFiller()
                player.enqueue(data, itemID: item)
            case .assistantDelta, .assistantDone, .outputAudioDone:
                guard let response = envelope.responseID,
                      responseAuthority.matches(connection: envelope.connectionID, responseID: response),
                      responseAuthority.purpose == .outcomeOnly || speaksDuringReasoning else { continue }
                handle(event)
            case .responseDone:
                guard let response = envelope.responseID,
                      responseAuthority.matches(connection: envelope.connectionID, responseID: response) else { continue }
                responseAuthority.finish(connection: envelope.connectionID, responseID: response)
                Self.log.notice("response_done id=\(response, privacy: .public)")
                handle(event)
            case .closed, .failure:
                if conversation.id != nil {
                    let message: String
                    if case .failure(let reason) = event { message = reason }
                    else { message = "The OpenAI voice connection closed. Resume listening to reconnect." }
                    stopConversation(state: .unavailable(message))
                }
                failManualFinal(VoiceError("The OpenAI voice connection closed before the transcript finished."))
                let ownsRemote = pendingReasoning != nil || responseInFlight
                responseAuthority.revoke()
                pendingReasoning = nil; pendingInput = nil
                responseInFlight = false; awaitingTurnEnd = false
                turnResponseOutstanding = false; responseWatchdog?.cancel()
                if ownsRemote, let id = turnID {
                    if case .failure(let message) = event { onEvent?(id, .failure(turnFailure(message))) }
                    else { onEvent?(id, .failure("The remote voice session closed. Local speech remains available.")) }
                }
            default:
                handle(event)
            }
        }
    }

    private func submitRemote(_ admission: VoiceAdmission, audio: [Data]?) async throws {
        guard remoteReasoningPermitted else {
            throw VoiceError("Remote reasoning is disabled for this bounded diagnostic run.")
        }
        guard turnID == admission.turn.id, speechSession.gate.isCurrent(admission.turn),
              admission.route == .remote else { throw CancellationError() }
        pendingReasoning = admission
        if let input = admission.realtimeInput {
            guard client.isReady, input.connectionID == client.connectionID else { throw CancellationError() }
        } else {
            try await ensureConnected()
        }
        let connection = client.connectionID
        guard turnID == admission.turn.id, !Task.isCancelled else { throw CancellationError() }
        let note = await contextProvider?() ?? ""
        guard turnID == admission.turn.id, client.connectionID == connection, !Task.isCancelled else { throw CancellationError() }
        if !note.isEmpty { _ = try await client.sendContextNote(note, replacing: lastContextItemID) }
        guard turnID == admission.turn.id, client.connectionID == connection, !Task.isCancelled else { throw CancellationError() }
        if let input = admission.realtimeInput {
            pendingInput = (admission.turn, input.itemID, false, true)
            turnAudioItemID = input.itemID
            _ = try await client.sendContextNote(
                "[host-authorized final user transcript; source=openai_realtime; input_item=\(input.itemID)] "
                + admission.text)
        } else if let audio {
            _ = try await client.sendContextNote("[authoritative local final] " + admission.text)
            for data in audio {
                guard turnID == admission.turn.id, client.connectionID == connection, !Task.isCancelled else { throw CancellationError() }
                try await client.sendAudio(data)
            }
            pendingInput = (admission.turn, nil, false, false)
            try await client.commitAudio()
        } else {
            let item = RealtimeVoiceClient.contextItemID()
            pendingInput = (admission.turn, item, true, false)
            _ = try await client.sendText(admission.text, itemID: item)
        }
        guard turnID == admission.turn.id, client.connectionID == connection, !Task.isCancelled else { throw CancellationError() }
        awaitingTurnEnd = true
        requestResponseWhenFree()
        armFiller(turn: admission.turn.id)
    }

    /// Starts the filler clock for a turn that waits on the model's answer
    /// (`speaksDuringReasoning`); direct commands already speak an ack.
    /// Fires at most once, and only while the turn is still silent.
    private func armFiller(turn id: UUID) {
        filler?.task.cancel(); filler = nil
        guard speaksDuringReasoning, fillerSpokenTurn != id else { return }
        let clock = fillerClock
        filler = (id, Task { [weak self] in
            await clock(Self.fillerDelay)
            guard !Task.isCancelled, let self, self.filler?.turn == id, self.turnID == id,
                  self.audioRepliesEnabled, !self.holding else { return }
            self.filler = nil; self.fillerSpokenTurn = id
            self.onFiller?(id, Self.fillerLine)
        })
    }

    /// Anything spoken or played, or the turn ending, retires the filler.
    private func quietFiller(turn id: UUID? = nil) {
        guard let pending = filler, id == nil || pending.turn == id else { return }
        pending.task.cancel(); filler = nil
    }

    private func dispatchToolV1(callID: String, name: String, arguments: String,
                                admission: VoiceAdmission, connection: UUID) {
        guard handledCalls.insert(callID).inserted else { return }
        let pendingKey = connection.uuidString + ":" + callID
        pendingCalls.insert(pendingKey)
        Task { [weak self] in
            guard let self else { return }
            defer { self.pendingCalls.remove(pendingKey) }
            let output: String
            var screenItem: String?
            do {
                let fresh = await self.admissionContextProvider?() ?? self.speechSession.context
                var context = self.speechSession.boundContext
                context.currentAsks = fresh.currentAsks
                context.agents = context.agents.filter { fresh.agents[$0.key] == $0.value }
                guard self.turnID == admission.turn.id, self.client.connectionID == connection,
                      self.speechSession.gate.isCurrent(admission.turn), !Task.isCancelled else { return }
                let call = try VoiceToolCatalog.validate(name, arguments: arguments, admission: admission, context: context)
                if VoiceToolCatalog.unavailable.contains(name) {
                    output = VoiceToolCatalog.result(status: "unavailable",
                        summary: "That capability is not implemented yet.",
                        error: "unavailable:" + (VoiceToolCatalog.capabilityIDs[name] ?? name))
                } else {
                    switch name {
                    case "computer_task":
                        if call.args["gaze_target"] != nil {
                            output = VoiceToolCatalog.result(status: "unavailable",
                                summary: "That resolved-target executor is not available yet.", error: "unavailable:resolved_target")
                        } else if self.remoteReplyTurn == admission.turn.id, let execute = self.remoteDesktopExecutor {
                            if let effect = try await execute() {
                                output = VoiceToolCatalog.result(
                                    status: effect.verified ? "completed" : effect.waitingForAnswer ? "clarification" : "accepted",
                                    summary: effect.message)
                            } else {
                                output = VoiceToolCatalog.result(status: "blocked",
                                    summary: "No computer action was admitted.", error: "not_admitted")
                            }
                        } else {
                            let legacy = await self.commandHandler(admission.text, call.args["app_hint"]?.string,
                                                                  nil, admission.text, [], admission.turn.id)
                            output = Self.wrapExecutorResult(legacy)
                        }
                    case "respond_to_task":
                        guard let task = call.args["task_id"]?.string.flatMap(UUID.init(uuidString:)),
                              let ask = call.args["ask_id"]?.string.flatMap(UUID.init(uuidString:)) else { throw VoiceError("invalid_arguments") }
                        output = Self.wrapExecutorResult(await self.exactTaskResponseHandler(admission.text, task, ask, admission.turn.id))
                    case "delegate_to_agent":
                        let create = call.args["create"]?.object
                        output = Self.wrapExecutorResult(await self.delegationHandler(
                            admission.text, call.args["agent"]?.string, create?["name"]?.string,
                            create?["role"]?.string, create?["description"]?.string))
                    case "ask_about_screen":
                        let scope = ScreenQuestion.Scope(rawValue: call.args["scope"]?.string ?? "") ?? .window
                        let read = await self.screenReader(scope)
                        switch await ScreenQuestion.reply(question: call.args["question"]?.string ?? admission.text,
                                                          scope: scope, focused: read.focused, windows: read.windows) {
                        case .text(let text, let digest):
                            output = ScreenQuestion.output(text)
                            screenItem = RealtimeVoiceClient.contextItemID(prefix: "scr-")
                            self.screenAnswer = digest
                        case .refused(let line):
                            output = VoiceToolCatalog.result(status: "refused", summary: line, error: "screen_vault")
                        case .unavailable(let line):
                            output = VoiceToolCatalog.result(status: "unavailable", summary: line,
                                                             error: "unavailable:screen_text")
                        }
                    case "answer":
                        output = VoiceToolCatalog.result(status: "completed", summary: call.args["text"]?.string ?? "")
                    default:
                        output = VoiceToolCatalog.result(status: "refused", summary: "That tool is unavailable.", error: "unknown_tool")
                    }
                }
            } catch {
                output = VoiceToolCatalog.result(status: "blocked", summary: "That request could not be safely admitted.",
                                                 error: "invalid_or_ungrounded_arguments")
            }
            guard self.turnID == admission.turn.id, self.client.connectionID == connection,
                  !Task.isCancelled else { return }
            try? await self.client.sendFunctionOutput(callID: callID, output: output, itemID: screenItem)
            if let screenItem { self.screenItems.append(screenItem) }
            if let say = Self.deterministicSay(output) { self.onEvent?(admission.turn.id, .toolSay(say)) }
            self.pendingCalls.remove(pendingKey)
            self.settleToolCall(output: output, session: admission.turn.id)
        }
    }

    private static func wrapExecutorResult(_ output: String, agentID: String? = nil) -> String {
        if let data = output.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           value["schema_version"]?.integer == 1 {
            return VoiceToolCatalog.validResult(value) ? output
                : VoiceToolCatalog.result(status: "failed", summary: "The executor returned an invalid result.", error: "invalid_executor_result")
        }
        guard let result = VoiceToolResult(jsonString: output) else {
            return VoiceToolCatalog.result(status: "failed", summary: "The executor returned an invalid result.", error: "invalid_executor_result")
        }
        let status = ["started", "delegated", "sent", "ok"].contains(result.status) ? "accepted" : "blocked"
        let fields = output.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        return VoiceToolCatalog.result(status: status, summary: result.say,
                                       taskID: fields?["task_id"]?.string, agentID: agentID ?? fields?["agent_id"]?.string)
    }

    private func ensureConnected(inputMode: RealtimeVoiceClient.InputMode? = nil) async throws {
        // Sessions cap at 60 minutes — a stale warm socket reconnects rather
        // than failing mid-hold.
        let stale = client.connectedAt.map { Date().timeIntervalSince($0) > 50 * 60 } ?? false
        if responseAuthority.requiresReconnect {
            client.teardown(); responseInFlight = false; wantResponse = false
        }
        if client.isReady, !stale {
            if let inputMode, inputMode != client.inputMode { try await client.configureInput(inputMode) }
            if responseAuthority.connection != client.connectionID { seenInputItems = [] }
            responseAuthority.connect(client.connectionID)
            replayOutcomes()
            return
        }
        let credential = try await credential()
        // Minting a client secret goes to the network; a caller that
        // connected meanwhile owns the socket now.
        if client.isReady, !responseAuthority.requiresReconnect,
           client.connectedAt.map({ Date().timeIntervalSince($0) <= 50 * 60 }) == true {
            return try await ensureConnected(inputMode: inputMode)
        }
        guard let credential,
              case let key = credential.key.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw VoiceError(OutcomeWording.missingVoiceKey)
        }
        client.teardown()
        lastSessionError = nil
        // A rebuilt session resets the call_id namespace — the dedupe set's
        // lifetime ends with the socket it belonged to.
        handledCalls = []
        try await client.connect(apiKey: key, model: credential.model ?? RealtimeVoiceClient.defaultModel,
                                 inputMode: inputMode ?? .conversation)
        seenInputItems = []
        responseAuthority.connect(client.connectionID)
        replayOutcomes()
    }

    func prepareRealtimeTransport(_ mode: RealtimeVoiceClient.InputMode) async throws {
        guard remoteReasoningPermitted else {
            throw VoiceError("OpenAI voice is disabled for this diagnostic.")
        }
        feedbackSuspended = false
        try await ensureConnected(inputMode: mode)
    }

    func beginRealtimeConversation(session: UUID) throws {
        guard client.isReady, client.inputMode == .conversation else {
            throw VoiceError("OpenAI has not confirmed continuous voice input.")
        }
        feedbackSuspended = false
        try conversation.startExternal(session: session)
    }

    private func handleRemoteInput(_ envelope: RealtimeVoiceClient.WireEnvelope) -> Bool {
        let inputEvent = envelope.kind.hasPrefix("input_audio_buffer.")
            || envelope.kind.hasPrefix("conversation.item.input_audio_transcription.")
        guard inputEvent else { return false }
        guard client.isReady, envelope.connectionID == client.connectionID else { return true }
        if manualInput != nil {
            receiveManualInput(envelope)
            return true
        }
        guard conversation.id != nil, client.inputMode == .conversation,
              let item = envelope.inputItemID, !item.isEmpty, item.utf8.count <= 200 else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        for event in envelope.events {
            switch event {
            case .inputCommitted:
                guard seenInputItems.insert(item).inserted, !awaitingCommit.isEmpty else { continue }
                let key = awaitingCommit.removeFirst()
                guard let local = remoteInputs.removeValue(forKey: key),
                      let slot = remoteInputOrder.firstIndex(of: key) else { continue }
                local.deadline?.cancel()
                remoteInputOrder[slot] = item
                var record = RemoteInput(capture: local.capture.bound(to: item))
                remoteInputs[item] = record
                guard conversation.commitExternal(record.capture, at: now) else {
                    expireRemoteInput(item)
                    continue
                }
                record.committed = true
                Self.log.notice("turn_committed key=\(key, privacy: .public) item=\(item, privacy: .public)")
                record.deadline = expiry(item)
                remoteInputs[item] = record
                drainRemoteInputs()
            case .transcriptDone(let text, _, let finalItem):
                guard finalItem == item, var record = remoteInputs[item], record.final == nil else { continue }
                record.final = text
                remoteInputs[item] = record
                onDiagnostic?(.init(turn: record.capture.turn.id, stage: "realtime.input.final", metrics: [:]))
                drainRemoteInputs()
            case .transcriptFailed:
                guard var record = remoteInputs[item], record.final == nil else { continue }
                record.final = ""
                remoteInputs[item] = record
                drainRemoteInputs()
            default: break
            }
        }
        return true
    }

    /// Hands-free speech began on the Mac: the turn's capture starts now and
    /// is bound to the server's input item when the commit is confirmed.
    /// Internal for tests — scripted turns drive it without a microphone.
    func localTurnStarted(connection: UUID) {
        guard conversation.id != nil, localSpeakingKey == nil else { return }
        do {
            guard remoteInputs.count < 32 else { throw VoiceError("Voice input could not keep up. Resume listening.") }
            let key = "local-" + UUID().uuidString
            let capture = try conversation.beginExternal(
                input: .init(connectionID: connection, itemID: ""), at: ProcessInfo.processInfo.systemUptime)
            holding = true
            localSpeakingKey = key
            remoteInputs[key] = .init(capture: capture)
            Self.log.notice("turn_started key=\(key, privacy: .public)")
            remoteInputOrder.append(key)
        } catch {
            stopConversation(state: .unavailable(error.localizedDescription))
        }
    }

    /// The Mac heard the end of the turn: commit what was uploaded. Commits
    /// confirm in order, so each `committed` binds the oldest waiting turn.
    /// Internal for tests.
    func localTurnEnded(connection: UUID) async throws {
        guard let key = localSpeakingKey else { return }
        localSpeakingKey = nil; holding = false
        guard var record = remoteInputs[key] else { flushSpeech(); return }
        record.deadline = expiry(key)
        remoteInputs[key] = record
        guard client.connectionID == connection else { throw VoiceError("The realtime connection changed mid-turn.") }
        awaitingCommit.append(key)
        Self.log.notice("turn_commit_sent key=\(key, privacy: .public)")
        do {
            try await client.commitAudio(eventID: key)
        } catch {
            awaitingCommit.removeAll { $0 == key }
            throw error
        }
    }

    /// The server refused a turn's commit, so no confirmation will come for
    /// it: its slot leaves the queue and the turn is dropped.
    private func rejectedCommit(_ eventID: String) {
        guard let slot = awaitingCommit.firstIndex(of: eventID) else { return }
        awaitingCommit.remove(at: slot)
        expireRemoteInput(eventID)
    }

    private func expiry(_ key: String) -> Task<Void, Never> {
        Task { [weak self] in
            guard let timer = self?.commitConfirmationTimer, let timeout = self?.commitConfirmationTimeout else { return }
            do { try await timer(timeout) } catch { return }
            self?.expireRemoteInput(key)
        }
    }

    /// A turn that expires before its commit is confirmed keeps its slot in
    /// `awaitingCommit`: confirmations arrive in commit order, so the late
    /// one consumes that slot and is dropped instead of binding the next turn.
    private func expireRemoteInput(_ item: String) {
        if let record = remoteInputs.removeValue(forKey: item) {
            record.deadline?.cancel()
            conversation.discardExternal(record.capture)
        }
        drainRemoteInputs()
    }

    private func drainRemoteInputs() {
        guard remoteInputDrain == nil, let session = conversation.id else { return }
        remoteInputDrain = Task { [weak self] in
            guard let self else { return }
            defer { if self.conversation.id == session { self.remoteInputDrain = nil } }
            while self.conversation.id == session, !Task.isCancelled, let first = self.remoteInputOrder.first {
                guard let record = self.remoteInputs[first] else {
                    self.remoteInputOrder.removeFirst()
                    continue
                }
                guard record.committed, let final = record.final else { return }
                self.remoteInputOrder.removeFirst()
                self.remoteInputs.removeValue(forKey: first)
                record.deadline?.cancel()
                await self.conversation.finishExternal(record.capture, text: final,
                    at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func respondToConversation(_ admission: VoiceAdmission, owner: LocalSpeechSession,
                                       execute: @escaping ConversationSession.RemoteExecutor) async throws {
        guard remoteReplyContinuation == nil, let input = admission.realtimeInput,
              input.connectionID == client.connectionID, client.isReady else { throw CancellationError() }
        remoteConversationOwner = owner
        remoteReplyTurn = admission.turn.id
        remoteDesktopExecutor = execute
        turnID = admission.turn.id
        turnTranscript = admission.text
        turnAudioItemID = input.itemID
        pendingCalls = []; assistantText = ""
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                remoteReplyContinuation = continuation
                Task { [weak self] in
                    guard let self, self.remoteReplyTurn == admission.turn.id else { return }
                    do { try await self.submitRemote(admission, audio: nil) }
                    catch { self.finishRemoteReply(error: error) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.remoteReplyTurn == admission.turn.id else { return }
                self?.finishRemoteReply(error: CancellationError())
            }
        }
    }

    private func finishRemoteReply(error: Error? = nil) {
        let continuation = remoteReplyContinuation
        remoteReplyContinuation = nil
        if error != nil, let owner = remoteConversationOwner, let turn = owner.gate.token {
            owner.cancel(turn)
        }
        if pendingReasoning?.turn.id == remoteReplyTurn { pendingReasoning = nil; pendingInput = nil }
        remoteReplyTurn = nil; remoteConversationOwner = nil; remoteDesktopExecutor = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    func beginRemoteManualInput(id: UUID, mode: VoiceCaptureMode, context: VoiceAdmissionContext,
                                at now: TimeInterval) throws -> VoiceTurnToken {
        guard client.isReady, client.inputMode == .manual,
              manualCaptureConnection != client.connectionID, manualInput == nil,
              mode == .command || mode == .dictation else {
            throw VoiceError("A fresh confirmed manual voice session is required.")
        }
        manualCaptureConnection = client.connectionID
        baseSpeechSession.context = context
        let turn = baseSpeechSession.beginRemoteCapture(id: id, mode: mode,
            connection: client.connectionID, now: now)
        turnID = id
        manualInput = .init(turn: turn, connection: client.connectionID)
        return turn
    }

    func finalizeRemoteManualInput(_ turn: VoiceTurnToken) async throws -> VoiceAdmission? {
        guard manualInput?.turn == turn, manualFinalContinuation == nil,
              client.isReady, client.inputMode == .manual else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                manualFinalContinuation = continuation
                manualInput?.commitRequested = true
                manualFinalDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard self?.manualInput?.turn == turn else { return }
                    self?.failManualFinal(VoiceError("OpenAI did not finish that transcript. Please try again."))
                }
                Task { [weak self] in
                    guard let self, self.manualInput?.turn == turn else { return }
                    do { try await self.client.commitAudio() }
                    catch { self.failManualFinal(error) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.manualInput?.turn == turn else { return }
                self?.failManualFinal(CancellationError())
            }
        }
    }

    private func receiveManualInput(_ envelope: RealtimeVoiceClient.WireEnvelope) {
        guard var pending = manualInput, pending.commitRequested, !pending.finishing,
              pending.connection == envelope.connectionID, turnID == pending.turn.id,
              baseSpeechSession.gate.isCurrent(pending.turn),
              let item = envelope.inputItemID, !item.isEmpty, item.utf8.count <= 200 else { return }
        for event in envelope.events {
            switch event {
            case .inputCommitted:
                guard pending.committed == nil, !seenInputItems.contains(item) else { continue }
                let input = VoiceRealtimeInput(connectionID: envelope.connectionID, itemID: item)
                guard baseSpeechSession.commitRemoteCapture(pending.turn, input: input,
                    now: ProcessInfo.processInfo.systemUptime) else { continue }
                pending.committed = input
                turnAudioItemID = input.itemID
                seenInputItems.insert(item)
            case .transcriptDone(let text, _, let finalItem):
                guard finalItem == item, pending.finals[item] == nil, pending.finals.count < 32 else { continue }
                pending.finals[item] = text
            case .transcriptFailed:
                pending.failures.insert(item)
            default: break
            }
        }
        manualInput = pending
        guard let input = pending.committed else { return }
        if pending.failures.contains(input.itemID) {
            failManualFinal(VoiceError("OpenAI could not transcribe that turn. Please try again."))
            return
        }
        guard let text = pending.finals[input.itemID] else { return }
        manualInput?.finishing = true
        Task { [weak self] in
            guard let self, self.manualInput?.turn == pending.turn else { return }
            let admission = await self.baseSpeechSession.finishRemoteCapture(text, turn: pending.turn,
                input: input, now: ProcessInfo.processInfo.systemUptime)
            guard self.manualInput?.turn == pending.turn else { return }
            let continuation = self.manualFinalContinuation
            self.manualFinalContinuation = nil
            self.manualInput = nil
            self.manualFinalDeadline?.cancel(); self.manualFinalDeadline = nil
            continuation?.resume(returning: admission)
        }
    }

    private func failManualFinal(_ error: Error) {
        if let pending = manualInput { baseSpeechSession.cancel(pending.turn) }
        manualInput = nil
        manualFinalDeadline?.cancel(); manualFinalDeadline = nil
        let continuation = manualFinalContinuation
        manualFinalContinuation = nil
        continuation?.resume(throwing: error)
    }

    func completeRemoteManualAdmission(_ admission: VoiceAdmission) async {
        guard turnID == admission.turn.id, baseSpeechSession.gate.isCurrent(admission.turn),
              baseSpeechSession.gate.state == .admitted else { return }
        turnTranscript = admission.text
        if admission.route == .dictation {
            baseSpeechSession.cancel(admission.turn)
            onEvent?(admission.turn.id, .final(admission.text))
            discardDictationItem(fallback: admission.realtimeInput?.itemID)
            return
        }
        if await handleSemanticIfNeeded(admission) { return }
        if admission.route == .remote {
            do { try await submitRemote(admission, audio: nil) }
            catch { onEvent?(admission.turn.id, .failure(error.localizedDescription)) }
        } else {
            if admission.route == .local, baseSpeechSession.consumeAdmission(admission.turn) != nil {
                await executeLocal(admission)
            }
            completeLocalDecision(admission)
        }
    }

    func realtimeInput(for turn: UUID) -> VoiceRealtimeInput? {
        guard speechSession.gate.admission?.turn.id == turn else { return nil }
        return speechSession.gate.admission?.realtimeInput
    }

    /// Race artefacts, not faults: a response.cancel that lands after the
    /// response already finished, a commit on an empty buffer. Surfacing
    /// these as failures kills the live capture for nothing.
    private static func isBenignRace(_ detail: String) -> Bool {
        let d = detail.lowercased()
        return d.contains("no active response") || d.contains("cancellation failed")
            || d.contains("response not in progress") || d.contains("already has a response")
            || d.contains("empty buffer") || d.contains("buffer too small")
            || d.contains("does not exist") || d.contains("not found")
    }

    /// A tool name the model invented still answers on the wire contract —
    /// JSON with a verbatim `say`, never bare text. Internal for tests.
    static func unknownToolOutput(_ name: String) -> String {
        VoiceToolResult(status: VoiceToolResult.Status.refused,
                        say: "That tool isn't available.").encoded()
    }

    /// The "started" suppression check — a real decode of the JSON tool
    /// contract so a `say` quoting 'started' can't false-positive, and the
    /// dead bare-"STARTED" prefix stays gone. Internal for tests.
    static func isStartedToolResult(_ output: String) -> Bool {
        VoiceToolResult(jsonString: output)?.status == VoiceToolResult.Status.started
    }

    /// The `say` field of a decoded contract result — the verbatim line
    /// the TTS seam voices when the second model turn is suppressed. nil =
    /// not a contract result or an empty say — the model still answers
    /// (web_lookup and higher-model results return bare content text).
    /// Internal for tests.
    static func deterministicSay(_ output: String) -> String? {
        if let data = output.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           value["schema_version"]?.integer == 1,
           let summary = value["summary"]?.string, !summary.isEmpty { return summary }
        guard let parsed = VoiceToolResult(jsonString: output) else { return nil }
        let say = parsed.say.trimmingCharacters(in: .whitespacesAndNewlines)
        return say.isEmpty ? nil : say
    }

    /// Errors that retrying can never fix — billing, auth, a model the
    /// account can't see. Everything else (network drop, server restart)
    /// stays on the reconnect path.
    private static func isFatalSessionError(_ detail: String) -> Bool {
        let d = detail.lowercased()
        return d.contains("credit") || d.contains("billing") || d.contains("quota")
            || d.contains("api key") || d.contains("unauthorized") || d.contains("forbidden")
            || d.contains("model") || d.contains("beta") || d.contains("refused")
    }

    func prepare(inputUID: String?) async throws -> String {
        try Task.checkCancellation()
        let uid = inputUID ?? ""
        if selectedUID == uid {
            if let prepared { return prepared.name }
            if let preparation {
                // A prepare past the session-confirm window (~10s) is
                // parked on a dead wait — nothing legitimate still runs.
                // Abandoning it beats re-joining the wedge; its own
                // cancellation checks retire it whenever the wait returns.
                if Date().timeIntervalSince(preparationBeganAt) > 185 {
                    Self.log.notice("realtime_prepare_wedged — abandoning a stale preparation")
                    preparation.cancel()
                    self.preparation = nil
                }
            }
            if let preparation { return try await preparation.value }
        } else {
            await suspend()
        }
        try Task.checkCancellation()
        enabled = true; selectedUID = uid
        feedbackSuspended = false
        let token = UUID(); preparationID = token
        onReadiness?(.preparing)
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            defer { if self.preparationID == token { self.preparation = nil } }
            do {
                try Task.checkCancellation()
                let inputStarted = ProcessInfo.processInfo.systemUptime
                Self.log.notice("prepare stage=microphone_input begin")
                let hardware = try await self.prepareInput(uid, self.duplexRequested, self.inputInterrupted(token: token))
                Self.log.notice("prepare stage=microphone_input elapsed_ms=\((ProcessInfo.processInfo.systemUptime - inputStarted) * 1000)")
                try Task.checkCancellation()
                try await self.ensureConnected(inputMode: self.desiredInputMode)
                guard self.enabled, self.preparationID == token else { throw CancellationError() }
                let oldOutput = self.hardware?.playback?.realtime.id
                self.hardware = hardware
                if oldOutput != hardware.playback?.realtime.id {
                    self.player.setPlaybackRoute(hardware.playback?.realtime)
                    self.onPlaybackOutputs?(hardware.playback)
                }
                guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                                              channels: 1, interleaved: true) else {
                    throw VoiceError("Could not build the speech audio format.")
                }
                let feed = try ConvertedAudioFeed(input: hardware.format, output: pcm)
                // Local speech tee — the transcriber hears the same
                // converted chunks the socket does (24kHz int16; the
                // transcriber resamples for its own model).
                self.prepared = Session(name: hardware.name, feed: feed, sendsAudio: true)
                self.onReadiness?(.ready(hardware.name))
                return hardware.name
            } catch {
                Self.log.error("prepare stage=microphone_input failed error=\(error.localizedDescription, privacy: .public)")
                if self.preparationID == token {
                    self.hardware = nil
                    await self.input.stop()
                    self.player.setPlaybackRoute(nil)
                    self.onPlaybackOutputs?(nil)
                    self.onReadiness?(.unavailable(error.localizedDescription))
                }
                throw error
            }
        }
        preparation = task
        preparationBeganAt = Date()
        return try await task.value
    }

    var conversationAudioReady: Bool {
        guard conversation.id != nil, let outputs = hardware?.playback else { return false }
        if !client.isReady { return false }
        return outputs.realtime.isReady() && outputs.system.isReady() && outputs.local.isReady()
            && playbackRoutingReady?() == true
    }

    func startConversation(inputUID: String?, since: TimeInterval? = nil) async throws {
        if conversation.id != nil { return }
        feedbackSuspended = false
        desiredInputMode = .conversation
        let request = UUID()
        conversationStartID = request
        onConversationState?(.preparing)
        do {
            guard playbackRoutingReady?() == true else {
                throw VoiceError("I can't listen all the time with this audio setup. Choose another microphone or speaker in Settings.")
            }
            guard conversationStartID == request, !Task.isCancelled else { throw CancellationError() }
            if !duplexRequested {
                await finishTask?.value
                guard conversationStartID == request, !Task.isCancelled else { throw CancellationError() }
                await suspend()
                guard conversationStartID == request, !Task.isCancelled else { throw CancellationError() }
                duplexRequested = true
            }
            _ = try await prepare(inputUID: inputUID)
            try await prepareRealtimeTransport(.conversation)
            guard conversationStartID == request, !Task.isCancelled,
                  let hardware, let outputs = hardware.playback,
                  outputs.realtime.isReady(), outputs.system.isReady(), outputs.local.isReady(),
                  playbackRoutingReady?() == true else {
                throw VoiceError("I can't listen all the time with this audio device. Choose another microphone or speaker in Settings.")
            }
            let speechGate = try VoiceActivityGate.silero()
            let session = UUID()
            try beginRealtimeConversation(session: session)
            guard conversationStartID == request, !Task.isCancelled else {
                conversation.stop()
                throw CancellationError()
            }
            try openConversationAudio(hardware: hardware, outputs: outputs, gate: speechGate, session: session,
                                      connection: client.connectionID, since: since)
            onConversationState?(.listening)
        } catch {
            if conversationStartID == request {
                closeConversationFeed()
                conversation.stop()
                if !(error is CancellationError) { onConversationState?(.unavailable(error.localizedDescription)) }
            }
            throw error
        }
    }

    /// Opens the conversation's audio on prepared hardware: the converted
    /// feed, the sender that runs it through the speech gate to the socket,
    /// and the meter that watches the playback route.
    private func openConversationAudio(hardware: MicrophoneInput.Ready, outputs: VoicePlaybackOutputs,
                                       gate speechGate: VoiceActivityGate, session: UUID, connection: UUID,
                                       since: TimeInterval? = nil) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                         channels: 1, interleaved: true) else {
            throw LocalSpeechError.unavailable
        }
        let feed = try ConvertedAudioFeed(input: hardware.format, output: format)
        conversationSender = Task { [weak self] in
            guard let self else { return }
            do {
                for try await buffer in feed.stream {
                    guard !Task.isCancelled, self.conversation.id == session else { return }
                    guard let samples = buffer.int16ChannelData?[0] else {
                        throw VoiceError("The microphone audio format changed.")
                    }
                    for event in try await speechGate.admit(Data(bytes: samples, count: Int(buffer.frameLength) * 2)) {
                        guard self.conversation.id == session else { return }
                        switch event {
                        case .turnStarted: self.localTurnStarted(connection: connection)
                        case .audio(let pcm):
                            self.recentSpeech.append(pcm)
                            try await self.client.sendAudio(pcm, connection: connection)
                        case .turnEnded: try await self.localTurnEnded(connection: connection)
                        }
                    }
                }
            } catch {
                guard self.conversation.id == session, !Task.isCancelled else { return }
                self.stopConversation(state: .unavailable(error.localizedDescription))
            }
        }
        conversationFeed = feed
        conversationGate = speechGate
        input.gate.open(feed, at: AVAudioTime.hostTime(forSeconds: since ?? ProcessInfo.processInfo.systemUptime))
        conversationMeter?.invalidate()
        conversationUnreadySince = nil
        conversationMeter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.conversation.id == session else { return }
                if outputs.realtime.isReady(), outputs.system.isReady(), outputs.local.isReady() {
                    self.conversationUnreadySince = nil
                } else {
                    let now = ProcessInfo.processInfo.systemUptime
                    let unready = self.conversationUnreadySince ?? now
                    self.conversationUnreadySince = unready
                    guard now - unready < 2 * MicrophoneInput.stallTolerance else {
                        Self.log.error("playback_route_unready stopping_conversation")
                        self.stopConversation(state: .unavailable("The microphone stopped. Choose Start listening in Settings to try again."))
                        await self.suspend()
                        return
                    }
                }
                self.onConversationMeter?(feed.level(), !self.player.playbackIdle)
            }
        }
    }

    /// A real device change rebuilds only the microphone: the conversation,
    /// its socket and a turn in progress carry on with the new input.
    private func rebuildConversationInput(token: UUID) async -> Bool {
        guard let session = conversation.id, let speechGate = conversationGate else { return false }
        let started = ProcessInfo.processInfo.systemUptime
        Self.log.notice("conversation_input_rebuild begin")
        conversationMeter?.invalidate(); conversationMeter = nil
        conversationSender?.cancel(); conversationSender = nil
        if let feed = conversationFeed {
            conversationFeed = nil
            input.gate.close(ifCurrent: feed)?.finish()
        }
        do {
            let hardware = try await prepareInput(selectedUID, duplexRequested, inputInterrupted(token: token))
            guard conversation.id == session, preparationID == token, conversationGate === speechGate,
                  let outputs = hardware.playback else { throw CancellationError() }
            self.hardware = hardware
            replaceConversationPlaybackRoute(outputs.realtime)
            onPlaybackOutputs?(outputs)
            try openConversationAudio(hardware: hardware, outputs: outputs, gate: speechGate, session: session,
                                      connection: client.connectionID)
            Self.log.notice("conversation_input_rebuild elapsed_ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000)")
            return true
        } catch {
            Self.log.error("conversation_input_rebuild failed error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Internal for tests. A new route drops the audio the old one still
    /// held, so a reply that was playing is cancelled and truncated like a
    /// barge-in instead of being cut off silently.
    func replaceConversationPlaybackRoute(_ route: VoicePlaybackRoute?) {
        if !player.playbackIdle { interruptConversationPlayback() }
        player.setPlaybackRoute(route)
    }

    private func inputInterrupted(token: UUID) -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor in
                guard let self, self.enabled, self.preparationID == token else { return }
                if await self.rebuildConversationInput(token: token) { return }
                guard self.enabled, self.preparationID == token else { return }
                let reason = "Microphone configuration changed. Preparing a fresh input is required."
                if let active = self.active { self.onEvent?(active.id, .failure(reason)) }
                await self.suspend()
                self.onReadiness?(.interrupted(reason))
            }
        }
    }

    func stopConversation(state: ConversationListeningState = .paused) {
        conversationStartID = UUID()
        recentSpeech.clear()
        closeConversationFeed()
        remoteInputDrain?.cancel(); remoteInputDrain = nil
        for record in remoteInputs.values { record.deadline?.cancel() }
        remoteInputs = [:]; remoteInputOrder = []; localSpeakingKey = nil; awaitingCommit = []
        finishRemoteReply(error: CancellationError())
        conversation.stop()
        if case .unavailable = state {
            for item in speakQueue { retryOutcomePush.push(item.text, attempts: item.attempts) }
            speakQueue = []
        } else {
            feedbackSuspended = true
            retireFeedback()
        }
        holding = false
        responseAuthority.revoke()
        client.teardown()
        responseInFlight = false
        turnID = nil
        pendingReasoning = nil; pendingInput = nil
        pendingOutcomeReady = false; wantResponse = false
        _ = player.interrupt(untilResponseDone: false)
        onConversationState?(state)
    }

    private func closeConversationFeed() {
        conversationMeter?.invalidate(); conversationMeter = nil
        conversationSender?.cancel(); conversationSender = nil
        if let gate = conversationGate {
            conversationGate = nil
            Task {
                let usage = await gate.usage
                Self.log.notice("voice gate heard_s=\(usage.heard, format: .fixed(precision: 1)) speech_s=\(usage.sentSpeech, format: .fixed(precision: 1))")
            }
        }
        guard let feed = conversationFeed else { return }
        conversationFeed = nil
        input.gate.close(ifCurrent: feed)?.finish()
    }

    func interruptConversationPlayback() {
        quietFiller()
        let interrupted = player.interrupt(untilResponseDone: responseInFlight)
        let cancel = responseInFlight
        let response = responseAuthority.interruptConversation()
        if cancel { cancelledResponsePending = true }
        discardScreenItems(); toolRelayOwed = false
        finishRemoteReply(error: CancellationError())
        pendingReasoning = nil; pendingInput = nil
        awaitingTurnEnd = false; turnResponseOutstanding = false
        pendingTurnEndOnIdle = false
        drainDeadline?.cancel()
        Self.log.notice("playback_interrupted item=\(interrupted.itemID ?? "-", privacy: .public) played_ms=\(interrupted.playedMs) cancel=\(cancel)")
        guard cancel || interrupted.itemID != nil else { return }
        let connection = client.connectionID
        Task { [weak self] in
            guard let self, self.client.connectionID == connection else { return }
            if let response { try? await self.client.cancelResponse(responseID: response) }
            if let item = interrupted.itemID, self.client.connectionID == connection {
                try? await self.client.truncate(itemID: item, audioEndMs: interrupted.playedMs)
            }
        }
    }

    func start(session id: UUID, inputUID: String?, transcribe: Bool) async throws -> String {
        cancel()
        if transcribe {
            feedbackSuspended = false
            client.teardown()
            desiredInputMode = .manual
        }
        turnID = id
        // Re-raise the hold gate before the first await — a cancelled
        // response's trailing .responseDone lands in the prepare gap and
        // its flushSpeech() would fire a queued outcome's response.create
        // into the start of this hold.
        holding = true
        // Lane entry scopes the gate's pre-roll flush: audio from before
        // this capture is never replayed.
        let started = ProcessInfo.processInfo.systemUptime
        var session: Session!
        if transcribe {
            // The previous hold's teardown sends must land before this one
            // streams — a late clearAudio wipes freshly streamed audio.
            await teardownTask?.value
            teardownTask = nil
            _ = try await prepare(inputUID: inputUID)
            try Task.checkCancellation()
            guard turnID == id else { throw CancellationError() }
            let context = await admissionContextProvider?() ?? VoiceAdmissionContext()
            guard turnID == id, !Task.isCancelled else { throw CancellationError() }
            speechSession.context = context
            let localTurn: VoiceTurnToken
            responseInFlight = false
            try await prepareRealtimeTransport(.manual)
            guard turnID == id, !Task.isCancelled else { throw CancellationError() }
            localTurn = try beginRemoteManualInput(id: id, mode: respondOnCommit ? .command : .dictation,
                context: context, at: started)
            guard turnID == id, !Task.isCancelled else {
                await speechSession.cancelCapture(localTurn); throw CancellationError()
            }
            guard let next = prepared else { throw VoiceError("Speech input is not ready yet.") }
            session = next
            session.localTurn = localTurn
            prepared = nil
            pendingCalls = []; assistantText = ""; transcriptInFlight = ""
            turnTranscript = nil; transcriptPending = false; turnAudioItemID = nil
            pendingTurnEndOnIdle = false
            toolCallsThisTurn = 0
            holding = true
            // The mic gate opens BEFORE the barge-in sends — every awaited
            // socket write ahead of it would silently drop what the user is
            // already saying (the head of every barge-in hold was clipped).
            active = (id, session)
            turnID = id
            // Pin the local tee for THIS capture's mode — the prepared
            // feed took the sink eagerly at prepare time, possibly under
            // a stale respondOnCommit from a prior dictation hold.
            beginStreaming(session: session, id: id, pressUptime: started)
            onEvent?(id, .timing("Input admission", milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000))
            // Barge-in: a new hold interrupts the model mid-sentence — stop
            // playback locally and truncate what never reached the user. A
            // response mid-generation has no audio yet — cancel it too, or it
            // would start talking over this hold.
            let interrupted = player.interrupt(untilResponseDone: responseInFlight)
            if interrupted.itemID != nil || responseInFlight {
                // The cancelled response keeps emitting until its done —
                // its function calls must not dispatch under this hold.
                if responseInFlight { cancelledResponsePending = true }
                do { try await client.cancelResponse() }
                catch {
                    // A cancel that never lands must not wedge the response
                    // gate — the response is either done or the socket is
                    // dead and its .closed path handles recovery. It also
                    // leaves no pending cancelled response to shield, so
                    // the shield itself must come down here: kept set, it
                    // would silently skip this hold's tool dispatches until
                    // .closed or the watchdog cleared it.
                    responseInFlight = false
                    cancelledResponsePending = false
                }
                if let itemID = interrupted.itemID {
                    try? await client.truncate(itemID: itemID, audioEndMs: interrupted.playedMs)
                }
            }
            // No clearAudio here: the gate is already streaming this hold's
            // audio, so a clear now would clip its head. Stale audio from a
            // dead hold was already cleared by the teardownTask awaited
            // above — and that task now outlives the dead sender's last
            // append, so nothing can land after it.
            // A cancel() that landed during the sends must not leave the mic
            // streaming into the socket with the UI idle — tear the
            // just-opened capture down before propagating.
            do { try Task.checkCancellation() }
            catch { cancel(); throw error }
        } else {
            // Metering opens no socket — the input test never sends audio out.
            await suspend()
            try Task.checkCancellation()
            selectedUID = inputUID ?? ""; enabled = true
            let device = try MicrophoneCatalog.resolve(uid: inputUID)
            // The interruption handler is last-writer-wins on the shared
            // input: a transcribe prepare() racing in mid-test installs its
            // own (and can reconfigure the engine under the live test).
            // The stale-token guard keeps OUR handler from suspending a
            // newer preparation — the uncovered direction is a reprepare
            // silencing the test's hardware-change events until it ends.
            let hardware = try await input.prepare(device: device, interrupted: interruptionHandler(session: id))
            try Task.checkCancellation()
            session = Session(name: hardware.name,
                              feed: try ConvertedAudioFeed(input: hardware.format, output: hardware.format),
                              sendsAudio: false)
            holding = true
            active = (id, session)
            // Metering binds no turn — an unrelated socket death must not
            // fault an input test that never used the socket.
            input.gate.open(session.feed)
        }
        var reportedFirst = false
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active?.id == id else { return }
                if !reportedFirst, let first = session.feed.firstBufferTime() {
                    reportedFirst = true
                    self.onEvent?(id, .timing("Capture call to first audio", milliseconds: (first - started) * 1000))
                }
                self.onEvent?(id, .level(session.feed.level()))
            }
        }
        if let meterTimer { RunLoop.main.add(meterTimer, forMode: .common) }
        return session.name
    }

    /// Internal for tests: a stale handler (preparationID no longer current)
    /// must be a no-op — only the live input lifecycle may suspend.
    func interruptionHandler(session id: UUID) -> @Sendable () -> Void {
        let token = preparationID
        return { [weak self] in
            Task { @MainActor in
                guard let self, self.preparationID == token else { return }
                if self.active?.id == id { self.onEvent?(id, .failure("Microphone configuration changed.")) }
                await self.suspend()
            }
        }
    }

    // MARK: - Server events

    /// Internal for tests — injects a decoded socket event directly; in
    /// production the client's receive loop hops here via Task.
    func handle(_ event: RealtimeVoiceClient.Event) {
        // Response bookkeeping is session-independent — pushed outcomes land
        // their response.done between holds with no active capture, and the
        // gate still has to free up.
        switch event {
        case .responseDone:
            // A cancelled response's items can emit no more deltas — the
            // player's barge-in drop rules are stale from here on.
            player.responseDidFinish()
            responseInFlight = false
            responseWatchdog?.cancel()
            cancelledResponsePending = false
            // The done must belong to THIS turn's response.create — one
            // carried by a cancelled response (barge-in) or a queued push
            // that outraced release must not close the interaction.
            // A screen result that settled before this done still owes its
            // spoken answer — the relay response ends the turn, not this one.
            if turnResponseOutstanding, let id = turnID, awaitingTurnEnd, pendingCalls.isEmpty, !toolRelayOwed {
                awaitingTurnEnd = false
                discardScreenItems()
                if player.playbackIdle {
                    onEvent?(id, .turnEnded)
                    turnID = nil
                } else {
                    // The reply is still playing — hold the interaction open
                    // until the last buffer drains so the UI doesn't vanish
                    // while the model is mid-sentence.
                    deferTurnEndOnDrain(turn: id)
                }
            }
            turnResponseOutstanding = false
            flushSpeech()
            prepareNext()
            if turnID == nil { return }
        case .outputAudio:
            // Playback was already enqueued off-actor in client.onEvent —
            // there is no capture-scoped handling for the deltas.
            break
        case .failure:
            responseInFlight = false
            responseWatchdog?.cancel()
            awaitingTurnEnd = false
            turnResponseOutstanding = false
            cancelledResponsePending = false
        case .warning(let detail):
            // A rejected request on a live socket (bad item.id, deleting an
            // already-gone item) — the turn keeps streaming. The watchdog
            // still covers the one dangerous case: a refused response.create
            // leaves responseInFlight set until it fires.
            Self.log.notice("realtime_warning \(detail, privacy: .public)")
        case .closed:
            player.responseDidFinish()
            responseInFlight = false
            responseWatchdog?.cancel()
            // A queued speak whose text landed but whose response.create
            // never went out dies with the socket — replay it like a send
            // failure rather than dropping the outcome silently.
            for queued in speakQueue {
                retryOutcomePush.push(queued.text, attempts: queued.attempts)
            }
            speakQueue = []; wantResponse = false
            awaitingTurnEnd = false
            turnResponseOutstanding = false
            cancelledResponsePending = false
            pendingTurnEndOnIdle = false
            pendingCalls = []
            // A dead socket produces no transcript — release any command
            // dispatch parked on it instead of burning the wait bound.
            transcriptPending = false
            lastContextItemID = nil
            toolRelayOwed = false; screenItems = []; screenAnswer = nil
            prepared = nil
        case .sessionUpdated:
            // A fresh confirmed session — replay the outcome pushes a dead
            // socket dropped, oldest first, or verified results never reach
            // the user. A re-failure re-queues at the tail, keeping order.
            // Serial awaits: concurrent pushes would reorder on the wire.
            // A rebuilt session also retires any stale barge-in drop rules.
            player.responseDidFinish()
            cancelledResponsePending = false
            turnResponseOutstanding = false
            replayOutcomes()
        case .itemCreated(let itemID, let isImage):
            // Context notes are only real once the server confirms the item —
            // recording the id optimistically leaves a phantom we delete
            // (warn on) next turn.
            if itemID.hasPrefix("ctx-") { lastContextItemID = itemID }
        default: break
        }
        guard let id = turnID else {
            switch event {
            case .closed:
                // A socket that lived >3s died of ordinary causes — its loss
                // doesn't count toward the storm backoff.
                if client.connectedAt.map({ Date().timeIntervalSince($0) > 3 }) == true {
                    reconnectAttempts = 0
                }
                // A fatal session rejection (billing, auth) can't heal by
                // reconnecting — stay down until the next explicit prepare.
                if enabled, lastSessionError == nil { prepared = nil; prepareNext() }
            case .failure(let detail):
                // Session-scope errors (bad auth, rejected session.update)
                // surface on the readiness line even with no hold active.
                // Benign races (a stale response.cancel) only log.
                Self.log.notice("realtime_idle_error \(detail, privacy: .public)")
                if Self.isFatalSessionError(detail) { lastSessionError = detail }
                if !Self.isBenignRace(detail) { onReadiness?(.unavailable(detail)) }
                flushSpeech()
            case .warning(let detail):
                Self.log.notice("realtime_idle_warning \(detail, privacy: .public)")
            default: break
            }
            return
        }
        switch event {
        case .transcriptDelta, .transcriptFailed, .transcriptDone:
            break
        case .assistantDelta(let delta):
            onEvent?(id, .assistantDelta(delta))
        case .assistantDone(let text):
            assistantText = text
            onEvent?(id, .assistant(text))
            if let digest = screenAnswer, let ref = ScreenQuestion.pointedRef(answer: text, in: digest),
               let frame = digest.frame(ref: ref) {
                onScreenPoint?(frame)
            }
        case .functionCall:
            break // Only handleWire can spend response-bound executor authority.
        case .failure(let detail):
            if Self.isFatalSessionError(detail) { lastSessionError = detail }
            // A benign race must not kill a healthy capture — the hold is
            // still streaming; only real faults surface as .failure.
            if !Self.isBenignRace(detail) { onEvent?(id, .failure(turnFailure(detail))) }
            flushSpeech()
        case .warning, .rejected:
            break // logged in the session-level switch above
        case .closed:
            onEvent?(id, .failure("The voice session closed."))
        case .inputCommitted(let itemID):
            // The transcription.completed that follows carries this
            // item_id — recorded so a stale one can't pose as this turn's.
            turnAudioItemID = itemID
        case .sessionStarted, .speechStarted,
             .speechStopped, .outputAudio, .outputAudioDone, .responseDone,
             .itemCreated, .sessionUpdated:
            break
        }
    }

    /// Dictation commits leave a conversation item holding the raw audio —
    /// and its transcription — server-side. Deleting it once the turn
    /// settles keeps dictated text (a spoken credential, a pasted secret)
    /// out of the next turn's context, where it would read as a prior user
    /// message. Advisory: a dead socket loses the delete the same way it
    /// lost the audio.
    private func discardDictationItem(fallback itemID: String? = nil) {
        let target = turnAudioItemID ?? itemID ?? ""
        turnAudioItemID = nil
        guard !target.isEmpty else { return }
        let connection = client.connectionID
        Task { [weak self] in
            guard let self, self.client.connectionID == connection else { return }
            do { try await self.client.deleteItem(itemID: target) }
            catch { Self.log.notice("dictation_item_delete_failed \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Screen text leaves the conversation once its answer settles — the
    /// same advisory delete as the dictation item.
    private func discardScreenItems() {
        let items = screenItems
        screenItems = []; screenAnswer = nil
        guard !items.isEmpty else { return }
        let connection = client.connectionID
        Task { [weak self] in
            guard let self, self.client.connectionID == connection else { return }
            for item in items {
                do { try await self.client.deleteItem(itemID: item) }
                catch { Self.log.notice("screen_item_delete_failed") }
            }
        }
    }

    /// The screen answer's response was refused (the session is gone or
    /// reconnecting): say so in fixed words and end the turn, rather than
    /// holding it open until the person's next turn.
    private func abandonScreenAnswer() {
        toolRelayOwed = false
        discardScreenItems()
        guard let id = turnID, awaitingTurnEnd else { return }
        awaitingTurnEnd = false
        onEvent?(id, .toolSay(ScreenQuestion.failure))
        if player.playbackIdle {
            onEvent?(id, .turnEnded)
            turnID = nil
            prepareNext()
        } else {
            deferTurnEndOnDrain(turn: id)
        }
    }

    /// A question about the screen may speak while it reasons (a clarifying
    /// question with no tool call), like a plain question; every other turn
    /// speaks only its outcome.
    private var speaksDuringReasoning: Bool {
        ["question", "screen_question"].contains(speechSession.gate.admission?.intent ?? "")
    }

    /// A screen question fails in plain, fixed words; provider error text
    /// never reaches the person.
    private func turnFailure(_ detail: String) -> String {
        speechSession.gate.admission?.intent == "screen_question" ? ScreenQuestion.failure : detail
    }

    /// Turn bookkeeping after a tool result reached the model — split from
    /// the socket send so tests can drive it. A say-carrying contract
    /// result ends the turn without a second response
    /// (returnToolResult suppression, widened from `started` to every
    /// `say`); say-less output still arms the response so the model
    /// relays the content. Internal for tests.
    func settleToolCall(output: String, session id: UUID) {
        guard turnID == id else { return }
        if Self.deterministicSay(output) != nil {
            // A response already armed/queued owns the say — its done
            // lands the turn end. Sibling calls still in flight keep the
            // turn open; the last one to settle ends it here.
            guard !responseInFlight, !wantResponse, pendingCalls.isEmpty else { return }
            awaitingTurnEnd = false
            if player.playbackIdle {
                onEvent?(id, .turnEnded)
                turnID = nil
                prepareNext()
            } else {
                deferTurnEndOnDrain(turn: id)
            }
            return
        }
        // Only screen text owes a spoken follow-up. An accepted executor
        // result with an empty summary must not be narrated: its verified
        // outcome arrives later as its own push.
        if ScreenQuestion.isScreenAnswer(output) { toolRelayOwed = true }
        awaitingTurnEnd = true
        requestResponseWhenFree()
    }

    // MARK: - Between-turn pushes

    /// A runtime event the model must hear about — a settled task outcome, a
    /// parked consent, a parked question. Always injected into conversation
    /// context; `speak` also queues a response once the model is free —
    /// never over a hold the user is mid-way through.
    func pushTaskEvent(_ text: String, speak: Bool) {
        guard !feedbackSuspended else { return }
        let generation = feedbackGeneration
        Task { [weak self] in
            guard let self, generation == self.feedbackGeneration,
                  !self.feedbackSuspended else { return }
            await self.deliverPush(text, speak: speak)
        }
    }

    private func retireFeedback() {
        feedbackGeneration &+= 1
        speakQueue = []; retryOutcomePush = OutcomeRetryQueue()
        pendingOutcomeReady = false
    }

    private func replayOutcomes() {
        guard client.isReady, !feedbackSuspended else { return }
        let generation = feedbackGeneration
        let retries = retryOutcomePush.drain()
        Task { [weak self] in
            for retry in retries {
                guard let self, generation == self.feedbackGeneration,
                      !self.feedbackSuspended else { return }
                await self.deliverPush(retry.text, speak: true, attempts: retry.attempts)
            }
        }
    }

    /// The person's reply speed and length. A live session gets them as a
    /// `session.update`, so the next reply uses them; a later connect
    /// starts with them.
    func setReplyStyle(_ style: RealtimeVoiceClient.ReplyStyle) {
        Task { [client] in
            do { try await client.setReplyStyle(style) }
            catch { Self.log.notice("reply_style_send_failed error=\(error.localizedDescription, privacy: .public)") }
        }
    }

    func speakFeedback(_ text: String) {
        quietFiller()
        guard audioRepliesEnabled, !text.isEmpty,
              let data = try? JSONEncoder().encode(JSONValue.object([
                "kind": .string("voice_feedback"), "say": .string(text)])) else { return }
        pushTaskEvent(String(decoding: data, as: UTF8.self), speak: true)
    }

    /// The push's async core — queued speaks arm a response only after the
    /// text is on the wire (arming before it landed asked the model to
    /// voice an outcome it never received). Replays await it serially so
    /// retried outcomes keep FIFO order. `attempts` counts prior failed
    /// sends for this text — the retry budget the OutcomeRetryQueue enforces.
    private func deliverPush(_ text: String, speak: Bool, attempts: Int = 0) async {
        guard !feedbackSuspended else { return }
        let generation = feedbackGeneration
        guard client.isReady else {
            if speak, audioRepliesEnabled { retryOutcomePush.push(text, attempts: attempts) }
            return
        }
        let connection = client.connectionID
        do { try await client.sendText(text) }
        catch {
            Self.log.notice("realtime_push_failed error=\(error.localizedDescription, privacy: .public)")
            // A dead socket must never mean a silent outcome — the error
            // earcon marks the loss even when nothing else surfaces.
            earcon("Basso")
            // A verified outcome that hit a dead socket must not vanish —
            // it's re-sent when the rebuilt session confirms, but only up
            // to the attempt cap: a socket that keeps dying drops the
            // outcome honestly rather than replaying it forever.
            guard speak, audioRepliesEnabled, generation == feedbackGeneration,
                  !feedbackSuspended else { return }
            if attempts < OutcomeRetryQueue.maxAttempts {
                retryOutcomePush.push(text, attempts: attempts + 1)
            } else {
                Self.log.notice("realtime_push_dropped exhausted \(OutcomeRetryQueue.maxAttempts, privacy: .public) retries — outcome left unspoken")
            }
            return
        }
        guard speak, audioRepliesEnabled, client.isReady, client.connectionID == connection else { return }
        guard generation == feedbackGeneration,
              !feedbackSuspended else { return }
        guard speakQueue.count < 8 else {
            // The text reached the model as context; only its spoken
            // replay is dropped. Bounded, but no longer silent.
            Self.log.notice("realtime_push_queue_full — outcome reached context unspoken")
            return
        }
        speakQueue.append((text, attempts))
        flushSpeech()
    }

    /// Error earcon — the same three lines the coordinator's cue() runs,
    /// duplicated rather than coupled across lanes.
    private func earcon(_ name: String) {
        guard enabled, Config.shared.sounds else { return }
        NSSound(named: name)?.play()
    }

    /// Typed commands take the same turn the voice does — one model, one tool
    /// surface, one screen. The controller's session id binds turn events so
    /// `.turnEnded` and tool calls flow exactly like a spoken turn.
    func submitTyped(_ text: String, sessionID: UUID) async throws {
        cancel()
        feedbackSuspended = false
        turnID = sessionID
        holding = false
        pendingCalls = []; toolCallsThisTurn = 0
        // Typed turns produce no input transcript — a stale pending flag
        // from a spoken hold must not stall this turn's dispatch.
        turnTranscript = nil; transcriptPending = false; turnAudioItemID = nil
        pendingTurnEndOnIdle = false
        turnResponseOutstanding = false
        onCommandStage?(sessionID, .contextBegin)
        let context = await admissionContextProvider?() ?? VoiceAdmissionContext()
        onCommandStage?(sessionID, .contextEnd)
        guard !Task.isCancelled, turnID == sessionID else { return }
        speechSession.context = context
        guard let admission = await speechSession.submitTyped(
            text, id: sessionID, now: ProcessInfo.processInfo.systemUptime) else { return }
        guard !Task.isCancelled, turnID == sessionID else { return }
        turnTranscript = admission.text
        if await handleSemanticIfNeeded(admission) { return }
        guard turnID == sessionID, !Task.isCancelled else { return }
        if admission.route == .remote {
            try await submitRemote(admission, audio: nil)
        } else {
            completeLocalDecision(admission)
        }
    }

    private func completeLocalDecision(_ admission: VoiceAdmission, reportAdmission: Bool = true) {
        guard turnID == admission.turn.id else { return }
        if reportAdmission && (admission.route == .clarify || admission.route == .refuse) {
            let message: String
            switch admission.reason {
            case "negated_request": message = "I won't act on that request."
            case "ambiguous_ask", "ask_changed": message = "Which current task are you answering?"
            case "empty_transcript": message = "I didn't catch that. Try again once you see Listening at the top of the screen."
            default: message = "Please clarify the intended target or value."
            }
            onEvent?(admission.turn.id, .toolSay(message))
        }
        awaitingTurnEnd = false
        onEvent?(admission.turn.id, .turnEnded)
        turnID = nil
        prepareNext()
        flushSpeech()
    }

    /// Arms the drain defer: if the output engine wedges (device pulled,
    /// failed restart) playbackIdle never fires and the card would spin
    /// "Working…" forever — an early dismiss beats an unrecoverable stall.
    private func deferTurnEndOnDrain(turn id: UUID) {
        pendingTurnEndOnIdle = true
        drainDeadline?.cancel()
        drainDeadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled, let self, self.pendingTurnEndOnIdle else { return }
            self.pendingTurnEndOnIdle = false
            Self.log.notice("playback_drain_deadline — ending turn without drain")
            self.onEvent?(id, .turnEnded)
            if self.turnID == id { self.turnID = nil }
            self.prepareNext()
        }
    }

    /// Serialised response.create — the API rejects a second response while
    /// one is generating, and a hold means the user is talking. Queued wants
    /// flush on the next response.done or on release.
    private func requestResponseWhenFree() {
        guard !responseInFlight, !responseAuthority.waitingForRetirement, !holding else {
            Self.log.notice("response_deferred in_flight=\(self.responseInFlight) retiring=\(self.responseAuthority.waitingForRetirement) holding=\(self.holding)")
            wantResponse = true; return
        }
        if pendingReasoning == nil,
           speechSession.gate.state == .capturing || speechSession.gate.state == .finishing {
            Self.log.notice("response_deferred capturing")
            wantResponse = true; return
        }
        let purpose: VoiceResponseAuthority.Purpose
        if let admission = pendingReasoning {
            guard let input = pendingInput, input.acknowledged, input.turn == admission.turn,
                  turnID == admission.turn.id, speechSession.gate.isCurrent(admission.turn),
                  speechSession.gate.admission?.route == .remote else { return }
            purpose = admission.turn.mode == .typed ? .typed : .reasoning
            guard responseAuthority.request(admission: admission, purpose: purpose, inputItemID: input.itemID) else { return }
            pendingReasoning = nil; pendingInput = nil
            awaitingTurnEnd = true; turnResponseOutstanding = true
        } else {
            guard pendingOutcomeReady || toolRelayOwed else { return }
            purpose = .outcomeOnly
            guard responseAuthority.request(admission: nil, purpose: purpose, inputItemID: nil) else {
                if toolRelayOwed { abandonScreenAnswer() }
                return
            }
            turnResponseOutstanding = toolRelayOwed
            pendingOutcomeReady = false; toolRelayOwed = false
        }
        responseInFlight = true
        let requireTool = purpose != .outcomeOnly && speechSession.gate.admission?.intent != "question"
        Self.log.notice("response_requested purpose=\(String(describing: purpose), privacy: .public)")
        // This response.create is what awaitingTurnEnd waits on — a done
        // that lands while it was still queued (or belonged to a cancelled
        // or pushed response) must not end the turn.
        let connection = client.connectionID
        armResponseWatchdog()
        Task { [weak self] in
            guard let self, self.client.connectionID == connection else { return }
            do { try await self.client.requestResponse(allowTools: purpose != .outcomeOnly, requireTool: requireTool) }
            catch {
                guard self.client.connectionID == connection else { return }
                self.responseAuthority.revoke()
                self.responseInFlight = false
                self.awaitingTurnEnd = false
                self.turnResponseOutstanding = false
                if let id = self.turnID { self.onEvent?(id, .failure(error.localizedDescription)) }
                if self.conversation.id != nil {
                    self.stopConversation(state: .unavailable(error.localizedDescription))
                }
            }
        }
    }

    /// If response.done never arrives the gate would wedge every later turn —
    /// tear the socket down instead.
    private func armResponseWatchdog() {
        responseWatchdog?.cancel()
        responseWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.responseInFlight else { return }
            Self.log.notice("response_watchdog_fired no response.done in 30s — rebuilding session")
            self.responseInFlight = false
            self.wantResponse = false
            self.turnResponseOutstanding = false
            self.cancelledResponsePending = false
            self.onEvent?(self.active?.id ?? self.turnID ?? UUID(),
                          .failure("The voice server stopped responding. Try again in a moment."))
            // teardown() cancels the receiver first — no .closed event
            // ever arrives, so the reprepare must run here directly or
            // `prepared` stays stale and every later hold wedges on a
            // dead socket.
            self.responseAuthority.revoke()
            self.pendingInput = nil; self.pendingReasoning = nil
            self.client.teardown()
            self.prepareNext()
        }
    }

    private func flushSpeech() {
        guard wantResponse || !speakQueue.isEmpty else { return }
        wantResponse = false
        if !speakQueue.isEmpty { pendingOutcomeReady = true }
        speakQueue.removeAll(keepingCapacity: true)
        // A queued outcome response is its own turn — the tool-call cap
        // counts per turn, not per session lifetime.
        toolCallsThisTurn = 0
        requestResponseWhenFree()
    }

    /// send_to_higher_model — a one-shot chat call carrying the question and
    /// a fresh screenshot. Local to the lane: it owns the key and the screen
    /// provider, and the runtime stays out of it.

    /// web_lookup's backend — the Responses API's hosted web_search tool,
    /// so the model's answer carries live results rather than memory.

    // MARK: - SpeechCapturing tail

    /// Spawns the session's socket sender and opens the mic gate — the
    /// caller binds `active`/`turnID` first so chunks never send anonymously.
    /// The pump is detached: a MainActor-bound sender let any UI stall
    /// carve silent gaps into the audio the model hears. `pressUptime`
    /// (capture start, systemUptime seconds) marks the pre-roll cut: the
    /// gate replays only audio meant for this capture, never earlier room
    /// noise.
    private func beginStreaming(session: Session, id: UUID, pressUptime: TimeInterval) {
        let feed = session.feed, sendsAudio = session.sendsAudio
        let connection = client.connectionID
        session.sender = Task { [weak self] in
            var sequence = 0
            do {
                for try await buffer in feed.stream {
                    guard !Task.isCancelled else { return }
                    guard sendsAudio else { continue }
                    guard let self, let turn = session.localTurn,
                          self.speechSession.gate.isCurrent(turn) else { return }
                    guard let samples = buffer.int16ChannelData?[0] else {
                        throw VoiceError("The microphone audio format changed.")
                    }
                    try await self.client.sendAudio(Data(bytes: samples, count: Int(buffer.frameLength) * 2),
                                                    connection: connection)
                    sequence += 1
                }
            } catch {
                if let self, self.active?.id == id {
                    if let turn = session.localTurn { self.speechSession.fail(turn, reason: "capture_loss") }
                    self.onEvent?(id, .failure(error.localizedDescription))
                }
            }
        }
        input.gate.open(session.feed, at: AVAudioTime.hostTime(forSeconds: pressUptime))
    }

    func finish() {
        guard finishTask == nil, let active else { return }
        let released = ProcessInfo.processInfo.systemUptime
        let session = active.session
        input.gate.close(ifCurrent: session.feed)?.finish()
        meterTimer?.invalidate(); meterTimer = nil
        let durations = session.feed.audioSummary()
        onEvent?(active.id, .timing("Captured audio duration", milliseconds: durations.input * 1000))
        onDiagnostic?(.init(turn: active.id, stage: "capture.closed", metrics: [
            "converted_audio_ms": session.feed.audioDurations().converted * 1000,
            "emitted_frames": Double(session.feed.emittedFrameCount())]))
        finishTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.active?.id == active.id {
                    self.active = nil; self.finishTask = nil; self.prepareNext()
                }
            }
            guard session.sendsAudio,
                  session.feed.audioSummary().converted >= 0.1 else {
                guard !Task.isCancelled, self.turnID == active.id, self.active?.id == active.id else { return }
                if let turn = session.localTurn { await self.speechSession.cancelCapture(turn) }
                guard !Task.isCancelled, self.turnID == active.id, self.active?.id == active.id else { return }
                self.holding = false
                self.turnID = nil
                self.onEvent?(active.id, .final(""))
                return
            }
            do {
                guard let turn = session.localTurn else { throw LocalSpeechError.unavailable }
                let contextStarted = ProcessInfo.processInfo.systemUptime
                let fresh = await self.admissionContextProvider?() ?? self.speechSession.context
                self.onEvent?(active.id, .timing("Release context refresh",
                    milliseconds: (ProcessInfo.processInfo.systemUptime - contextStarted) * 1000))
                guard self.turnID == active.id, !Task.isCancelled else { return }
                self.speechSession.context = fresh
                self.holding = false
                let sender = session.sender
                await sender?.value
                guard self.turnID == active.id, !Task.isCancelled else { return }
                let final = try await self.finalizeRemoteManualInput(turn)
                guard self.turnID == active.id, !Task.isCancelled else { return }
                guard let admission = final else {
                    self.onEvent?(active.id, .final(""))
                    return
                }
                await self.completeRemoteManualAdmission(admission)
                self.onEvent?(active.id, .timing("Release to realtime final",
                    milliseconds: ((self.speechSession.finalizedAt ?? released) - released) * 1000))
            } catch {
                guard self.turnID == active.id else { return }
                self.holding = false
                self.onEvent?(active.id, .failure(error.localizedDescription))
            }
        }
    }

    func cancel() {
        quietFiller()
        discardScreenItems(); toolRelayOwed = false
        failManualFinal(CancellationError())
        cancelSemanticInterpretation(); semanticTask = nil; semanticTurn = nil
        if conversation.id != nil {
            interruptConversationPlayback()
            remoteInputDrain?.cancel(); remoteInputDrain = nil
            for record in remoteInputs.values { record.deadline?.cancel() }
            remoteInputs = [:]; remoteInputOrder = []
            conversation.cancelExternalWork()
            turnID = nil
            return
        }
        finishRemoteReply(error: CancellationError())
        let prior = active
        // Only cancel what's actually cancellable — a finished session
        // leaves `active` set, and a bare response.cancel earns a
        // "no active response" error that used to kill the next hold. Read
        // before the queued-want flag clears below.
        let needsCancel = responseInFlight || wantResponse
        if let turn = speechSession.gate.token {
            speechSession.cancel(turn)
            Task { [speechSession] in await speechSession.cancelCapture(turn) }
        }
        responseAuthority.revoke()
        pendingInput = nil; pendingReasoning = nil
        for item in speakQueue { retryOutcomePush.push(item.text, attempts: item.attempts) }
        speakQueue = []
        client.teardown()
        responseInFlight = false; pendingOutcomeReady = false
        responseWatchdog?.cancel()
        active = nil
        turnID = nil
        holding = false
        awaitingTurnEnd = false
        turnResponseOutstanding = false
        pendingTurnEndOnIdle = false
        drainDeadline?.cancel()
        if let prior { input.gate.close(ifCurrent: prior.session.feed)?.finish() }
        meterTimer?.invalidate(); meterTimer = nil
        finishTask?.cancel(); finishTask = nil
        pendingCalls = []; transcriptInFlight = ""
        // A dictation turn cancelled after its commit landed still left the
        // audio item server-side — delete it like a delivered one rather
        // than letting dictated text reach a later turn's context.
        turnTranscript = nil; transcriptPending = false; turnAudioItemID = nil
        // The dead turn's queued response-create must not fire on release —
        // a cancelled typed turn would still answer after the user bailed.
        wantResponse = false
        prior?.session.sender?.cancel()
        // `prior == nil` is the typed-turn path — its response still has
        // to die with the cancel, and playback still has to stop.
        teardownTask?.cancel(); teardownTask = nil
        cancelledResponsePending = false
        if prior != nil || needsCancel { _ = player.interrupt(untilResponseDone: false) }
        prepareNext()
    }

    private func prepareNext() {
        guard enabled, prepared == nil, preparation == nil else { return }
        // A stale-socket reprepare while a reply is live would teardown()
        // the very connection it's arriving on — the create was already
        // armed and its done would never come. Defer to the next
        // .responseDone/.turnEnded, which re-runs this.
        if client.isReady,
           client.connectedAt.map({ Date().timeIntervalSince($0) > 50 * 60 }) == true,
           responseInFlight || awaitingTurnEnd || pendingTurnEndOnIdle || wantResponse || holding {
            return
        }
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        // 0.25s → 8s exponential cap — a dead socket must not storm.
        let delay = min(0.25 * Double(1 << min(attempt, 5)), 8)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard let self, self.enabled else { return }
            _ = try? await self.prepare(inputUID: self.selectedUID)
        }
    }

    func suspend() async {
        feedbackSuspended = true
        retireFeedback()
        if conversation.id != nil || conversationFeed != nil { stopConversation() }
        enabled = false
        preparationID = UUID()
        let retiring = preparationID
        let pending = preparation
        preparation = nil
        pending?.cancel()
        cancel()
        prepared = nil
        speakQueue = []; wantResponse = false; responseInFlight = false
        turnResponseOutstanding = false; cancelledResponsePending = false
        player.stop()
        hardware = nil
        player.setPlaybackRoute(nil)
        onPlaybackOutputs?(nil)
        client.teardown()
        await input.stop()
        // A wedged prepare never finishes — bound the unwind wait so
        // suspend() itself can't chain-park behind it.
        if let pending {
            _ = try? await withVoiceDeadline(until: ProcessInfo.processInfo.systemUptime + 5) {
                _ = try? await pending.value
            }
        }
        if preparationID == retiring { onReadiness?(.unavailable("Microphone is paused.")) }
    }
}
