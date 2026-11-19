import AppKit
import Foundation
import JevVoiceCore

/// The voice-facing task spine: owns in-flight computer-use work, the
/// ask/confirm channel between the drive loop and the user, and the one
/// driver transport. Replaces the old dialogue graph — a task is one
/// `Work` row with one worker Task, not a state machine.
@MainActor
final class VoiceTaskCoordinator {
    /// One in-flight or finished voice task — the UI row model.
    final class Work: Identifiable {
        let id = UUID()
        let label: String
        let request: String
        var spec: DriveTask
        var message = ""
        var active = true
        var outcome: Outcome?
        /// A parked mid-task ask; the overlay shows it and
        /// `respondToTask`/`resolveApproval` resume it.
        var ask: DriveLoop.Ask? { didSet { askID = UUID() } }
        private(set) var askID = UUID()
        var askContinuation: CheckedContinuation<String?, Never>?
        var approvalContinuation: CheckedContinuation<Bool, Never>?
        /// A parked ask from an agent's MCP child — answering writes the
        /// shared answer file instead of resuming a continuation.
        var agentAskID: String?
        /// Agent-ask rows have no worker; the pending-ask file is the clock.
        var isAgentAsk: Bool { agentAskID != nil }
        var worker: Task<Void, Never>?
        var semanticFocus: VoiceSemanticRouter.Proposal?
        var windowScroll: WindowScrollRequest?
        var desktopSwitch: (number: Int, display: UInt32)?
        var desktopSideEffect: String?
        var desktopDecision: DesktopSpaceSwitch.Code?
        var desktopOverviewOrigin: DesktopSpaceSwitch.Origin?
        var allowParsedScroll = true
        var semanticExecutionStarted = false
        var semanticDriverLoop: DriveLoop?
        var scrollContinuation: NativeWindowObservation.ScrollViewport?
        var verifiedScroll: NativeWindowObservation.VerifiedScroll?
        var continuousScroll = false
        var continuousStartedAt: TimeInterval?
        var scrollAuthorization: (@MainActor @Sendable () -> Bool)?
        var onConversationScroll: (@MainActor (NativeWindowObservation.VerifiedScroll) -> Void)?
        var provenance: SpeechProvenance?
        /// The voice turn that spawned this work — session slices group on it.
        var captureID: UUID?
        var elapsedMs = 0.0
        var history: [String] = []
        var dispatchedEffect = false
        /// Last feed/dispatch timestamp — the stall watchdog's clock. A
        /// background task that's quiet this long is probably wedged, not
        /// working.
        var lastActivity = Date()
        /// Set by the watchdog; clears when the task next dispatches.
        var stalled = false
        /// The stall-check ask already fired for this quiet episode — a
        /// "keep working" answer (or the ask's own expiry) must not loop
        /// a fresh radial every `stallAskTimeout`. Clears when real
        /// dispatch activity lands, so the NEXT wedged stretch asks again.
        var stallAsked = false

        enum Outcome: Equatable, Sendable {
            case done, alreadyDone, blocked(String), failed(String),
                 cancelled, uncertain(String)
        }

        init(label: String, request: String, spec: DriveTask) {
            self.label = label; self.request = request; self.spec = spec
        }

        /// A parked ask the user can act on — in-process continuation or a
        /// cross-process agent ask awaiting an answer file.
        var awaitingAnswer: Bool {
            askContinuation != nil || approvalContinuation != nil || agentAskID != nil
        }

        /// A parked confirm specifically — the overlay's Confirm/Run gate.
        var awaitingApproval: Bool {
            guard case .confirm = ask else { return false }
            return awaitingAnswer
        }

        /// A parked `.choice` specifically — the radial is up, so Escape's
        /// consume gate and the decline path read it; `.question` and
        /// `.confirm` rows already have their own reads.
        var awaitingChoice: Bool {
            guard case .choice = ask else { return false }
            return awaitingAnswer
        }

        /// The parked ask's display text, whichever kind it is.
        var askPrompt: String? {
            switch ask {
            case .confirm(let p), .question(let p): return p
            case .choice(let p, _): return p
            case nil: return nil
            }
        }

        /// One-word state for the task row.
        var statusText: String {
            if active { return ask != nil ? "Waiting" : stalled ? "Stalled" : "Working" }
            switch outcome {
            case .done: return "Done"
            case .alreadyDone: return "Already done"
            case .blocked: return "Blocked"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            case .uncertain: return "Uncertain"
            case nil: return "Stopped"
            }
        }
    }

    var tasks: [Work] = [] { didSet { onChange() } }
    var selectedID: UUID? { didSet { onChange() } }
    var onChange: () -> Void = {}
    var audioFeedbackAllowed: () -> Bool = { true }
    enum ConversationBoundary: Sendable, Equatable {
        case question
        case finished(Work.Outcome)
    }
    private struct BoundaryWaiter {
        let id: UUID
        let throughQuestions: Bool
        let continuation: CheckedContinuation<ConversationBoundary?, Never>
    }
    private var conversationWaiters: [UUID: [BoundaryWaiter]] = [:]
    /// Content-free latency spans; fixture runners may observe them without
    /// recording tool arguments, screen contents or credentials.
    var onLatencySpan: ((String, TimeInterval, TimeInterval) -> Void)?
    var onCommandStage: ((UUID?, UUID?, VoiceCommandTrace.Stage, VoiceCommandTrace.Tool?) -> Void)?
    var onNativeTextInsertion: ((UUID?, UUID, FocusedTextBinding.Insertion) -> Void)?
    /// task_event pushes into the realtime lane — (workID, payload, speak).
    var taskEventSink: (UUID?, String, Bool) -> Void = { _, _, _ in }
    let feed = DecisionFeed()
    /// Agent delegation seam — set by main after the agent runtime exists.
    var agentBridge: (any AgentBridging)? {
        didSet {
            voiceDelegation = .init(revision: UUID(), receipt: nil)
            hasDelegationAttempt = false
        }
    }
    private(set) var voiceDelegation = DelegatedVoiceStatusScope(revision: UUID(), receipt: nil)
    private var hasDelegationAttempt = false

    /// The drive sessions' labels — the driver draws one agent cursor per
    /// session, so which label a call rides decides whether a cursor
    /// chases it. `session` is the model-driven loop's (the machine is
    /// the actor, so its cursor stays visible); `gazeSession` carries
    /// eye-driven referents (the eyes ARE the pointing device — a drawn
    /// cursor would only chase the user's own pick); `directSession`
    /// carries spoken one-shot fast-lane work for the same reason.
    // `nonisolated let` — immutable labels, read by the nonisolated
    // `cursorlessSession` predicate (DriveLoop is a different actor).
    nonisolated static let session = "voice"
    nonisolated static let gazeSession = "voice-gaze"
    nonisolated static let directSession = "voice-direct"
    /// Session labels the agent cursor stays off — the user's own
    /// gaze/voice drives them. Rotation-minted successors ("voice-gaze-2")
    /// inherit their stem's posture via the prefix rule.
    nonisolated static func cursorlessSession(_ label: String) -> Bool {
        [gazeSession, directSession].contains {
            label == $0 || label.hasPrefix($0 + "-")
        }
    }
    /// Labels already suppressed this connection generation — set_agent_
    /// cursor_enabled is idempotent, so the set is what makes it a
    /// once-per-session cost rather than a per-dispatch one.
    private var cursorSuppressedSessions: Set<String> = []

    /// One suppression per cursorless session, ordered BEFORE the first
    /// dispatch that would mint it: the driver creates a named session on
    /// first use, so awaiting the toggle here is what guarantees the
    /// session comes up cursorless instead of flashing a cursor for one
    /// action. A refusal is swallowed (session preference, not a
    /// correctness gate — `setAgentCursorEnabled` is fire-and-forget).
    private func suppressAgentCursorIfNeeded(on label: String) async {
        guard Self.cursorlessSession(label),
              !cursorSuppressedSessions.contains(label) else { return }
        cursorSuppressedSessions.insert(label)
        guard let conn = try? await transport() else { return }
        await conn.setAgentCursorEnabled(false, session: label)
    }

    private let config: Config
    private let jevAPIKey: () -> String
    private let resolver: AppResolver
    private let commandDriver: DriveLoop.Call?
    private let foregroundAppLauncher: ((String, @escaping @MainActor @Sendable () -> Bool) async throws -> Int)?
    var hasForegroundAppLauncher: Bool { foregroundAppLauncher != nil }
    private var connection: CuaConnection?
    private var connectTask: Task<CuaConnection, Error>?
    /// The read-only sibling transport — a second proxy on the same
    /// daemon socket. The daemon serializes every call per connection,
    /// so a slow mutation would starve any read queued behind it;
    /// `callRead` enforces `CuaConnection.isReadOnly` before the wire.
    private var readConnection: CuaConnection?
    private var connectReadTask: Task<CuaConnection, Error>?
    struct InventoryWarmupBinding {
        let generation: String
        let read: @MainActor () async throws -> Void
        let close: @MainActor () async -> Void
    }
    private var inventoryPreparationTask: Task<Void, Never>?
    private var inventoryWarmTask: Task<Void, Never>?
    private var inventoryWarmGeneration: String?
    private var inventoryWarmID: UUID?
    private var inventoryWarmStopped = false
    private var inventoryWarmAttempts = 0, inventoryWarmReads = 0
    private var inventoryWarmPending: Set<UUID> = []
    private var inventoryWarmCompleted = 0, inventoryWarmFailed = 0, inventoryWarmCancelled = 0
    private var inventoryWarmElapsed = 0.0
    private var inventoryWarmStartedAt: TimeInterval?
    private var inventoryWarmSettledAt: TimeInterval?

    var inventoryWarmupMetrics: [String: Any] {
        var result: [String: Any] = [
            "attempts": inventoryWarmAttempts, "reads_dispatched": inventoryWarmReads,
            "pending": inventoryWarmPending.count, "completed": inventoryWarmCompleted,
            "failed": inventoryWarmFailed, "cancelled": inventoryWarmCancelled,
            "settled_elapsed_ms": inventoryWarmElapsed
        ]
        if let inventoryWarmStartedAt { result["last_started_at"] = inventoryWarmStartedAt }
        if let inventoryWarmSettledAt { result["last_settled_at"] = inventoryWarmSettledAt }
        return result
    }
    /// Serialized local-input access — pasteboard writes and foreground
    /// focus are shared lanes; this mutex replaces the old lane registry.
    // Shared with DictationDelivery — dictation pastes and drive-loop focus
    // borrows serialize on ONE lease so a ⌘V can't land inside a focus steal.
    let inputGuard = DictationDelivery.sharedLease
    var switchDesktop: @MainActor (Int, UInt32, () -> Bool, (String) -> Void) async -> DesktopSpaceSwitch.Outcome = DesktopSpaceSwitch.run

    private(set) var pendingOverlayPick: (@MainActor (Int) -> Void)?
    private var choiceAskID: UUID?
    /// Latest fresh gaze point in top-left screen points — radials park
    /// near it and the agent-chip hit-test reads it.
    private var lastGazePoint: CGPoint?
    /// When `lastGazePoint` was ingested — a point older than
    /// `gazeAnchorTTL` is where the user *was*, so parked UI ignores it.
    private var lastGazeAt = Date.distantPast
    /// How long an ingested gaze point stays a valid radial anchor.
    static let gazeAnchorTTL: TimeInterval = 2
    /// The gaze anchor only while it still means "where the user is" —
    /// past the TTL it reads as no fix and the radial takes the
    /// screen-center fallback rather than landing where the user looked
    /// minutes ago.
    private var liveGazePoint: CGPoint? {
        guard let lastGazePoint,
              Date().timeIntervalSince(lastGazeAt) <= Self.gazeAnchorTTL
        else { return nil }
        return lastGazePoint
    }
    /// slug → AppKit screen point for the live agent cursor chips — the
    /// poller feeds it so a gaze hit-test can name the chip's agent.
    private(set) var lastChipPoints: [String: NSPoint] = [:]
    /// One note per key gap — a "no Jev key" line per task is noise.
    private var missingKeyNoted = false
    /// The always-on gaze consumer — `configureGazeService` wires its
    /// seams onto this instance; tests inject a fresh one.
    let gazeService: GazeService
    /// The last heard instruction — the scorer's speech prior, ~5s TTL.
    private var lastUtterance: (text: String, at: Date)?
    /// B6's context seam — the referent lines that ride into every
    /// task's previousContext and every delegation message. Production
    /// wires it to `gazeService.referentContext`; tests inject a line.
    var gazeContextProvider: () async -> String? = { nil }
    /// The candidate enumerator the service drives — built over `call`
    /// by `configureGazeService`; nil means the feed reports empty.
    private var gazeFeed: GazeCandidateFeed?
    private var gazeEnumeration = UUID()
    private var nativeGaze: (id: UUID, hit: CommittedGazeHit, target: IntentCandidate)?
    private var heldDwellRect: CGRect?
    var currentGazeClickLease: UUID? {
        guard let bound = nativeGaze, bound.id == gazeService.batch.nativeWitness else { return nil }
        return gazeService.currentActionLease
    }
    /// Fn-down pre-observe and its gaze pump — cancelled by
    /// `endListeningHint` or a watchdog so a non-computer utterance
    /// leaves nothing running.
    private var listenHintTask: Task<Void, Never>?
    private var gazePump: Task<Void, Never>?
    /// Which gaze pump is live — a superseded pump's teardown must not
    /// stop the stream its replacement just opened.
    private var gazePumpGeneration = 0
    /// Which Fn-down hint owns the gaze feed — a pending
    /// `endListeningHint` teardown must not stop the stream a NEWER
    /// hold just opened.
    private(set) var listenHintGeneration = 0

    /// Live Fn/dictation capture probe — true while the user is mid-
    /// sentence, so a dwell fire can't double-actuate on "click this".
    /// `configureGazeService` points it at L5's `VoiceController.shared`;
    /// the default-off seam keeps tests (and a missing wire) from
    /// suppressing anything.
    var captureActiveProbe: () -> Bool = { false }

    /// `gazeService`/`overlay` default inside the init — nonisolated
    /// defaults can't read the MainActor `shared`s.
    init(config: Config, jevAPIKey: @escaping () -> String,
         gazeService: GazeService? = nil, overlay: TargetOverlay? = nil,
         resolver: AppResolver? = nil, commandDriver: DriveLoop.Call? = nil,
         observeAgents: Bool = true,
         foregroundAppLauncher: ((String) async throws -> Int)? = nil) {
        self.config = config
        self.jevAPIKey = jevAPIKey
        self.resolver = resolver ?? AppResolver()
        self.commandDriver = commandDriver
        if let foregroundAppLauncher {
            self.foregroundAppLauncher = { bundle, current in
                guard await current() else { throw CancellationError() }
                return try await foregroundAppLauncher(bundle)
            }
        }
        else if commandDriver == nil {
            self.foregroundAppLauncher = { try await DriveLoop.openForegroundApplication($0, isCurrent: $1) }
        } else { self.foregroundAppLauncher = nil }
        self.gazeService = gazeService ?? .shared
        self.overlay = overlay ?? .shared
        if observeAgents {
            startAskWatcher()
            startCursorPoller()
        }
        configureGazeService()
    }

    /// The overlay surface for chips/radials/rings — `.shared` in
    /// production, a fresh instance in tests so arms/disarms are
    /// observable without panels.
    let overlay: TargetOverlay
    /// Per-agent cursor labels — the driver draws each session's cursor;
    /// the app adds the name chip so "which agent owns that cursor" reads
    /// at a glance. slug → AppKit screen point; nil hides the chip.
    var cursorLabelSink: (String, NSPoint?) -> Void = { _, _ in }
    private var cursorPoller: Task<Void, Never>?
    private var activeCursorAgents: Set<String> = []

    private func startCursorPoller() {
        cursorPoller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.pollAgentCursors()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    /// `get_agent_cursor_state` payload → AppKit point. The driver reports
    /// top-left-origin screen points; AppKit wants bottom-left, flipped
    /// against the primary screen height. Disabled or unpositioned cursors
    /// (or malformed payloads) yield nil — the chip hides.
    nonisolated static func agentCursorPoint(from payload: JSONValue,
                                             primaryHeight: CGFloat) -> NSPoint? {
        guard let object = (payload["structuredContent"] ?? payload).object,
              object["enabled"]?.bool == true,
              let position = object["position"]?.object,
              case .number(let x)? = position["x"],
              case .number(let y)? = position["y"]
        else { return nil }
        return NSPoint(x: x, y: primaryHeight - y)
    }

    /// Each agent session owns one drawn cursor — `get_agent_cursor_state`
    /// reports its screen position. Hidden/disabled cursors hide their chip.
    /// `agentCursorEnabled` gates ONLY the moving cursor surface — its
    /// name chips, its gaze-hit points, its halo stand-down rects. The
    /// shelf is the agents-presence surface and updates either way.
    func pollAgentCursors() async {
        guard let agentBridge else { return }
        let agents = await agentBridge.roster()
        guard !agents.isEmpty else {
            retractCursorChips()
            AgentShelfOverlay.shared.update([])
            return
        }
        var seen: Set<String> = []
        if config.agentCursorEnabled {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            // Each session's cursor read is independent — overlap them on
            // the read lane so N agents cost ~1 round trip, not N.
            let points = await withTaskGroup(
                of: (String, NSPoint?).self,
                returning: [String: NSPoint?].self
            ) { group in
                for agent in agents {
                    group.addTask { @MainActor [self] in
                        let state = try? await self.callRead(
                            "get_agent_cursor_state",
                            ["session": .string("agent-\(agent.slug)")])
                        return (agent.slug, state.flatMap {
                            Self.agentCursorPoint(from: $0, primaryHeight: primaryHeight)
                        })
                    }
                }
                var collected: [String: NSPoint?] = [:]
                for await item in group { collected[item.0] = item.1 }
                return collected
            }
            for agent in agents {
                guard let point = points[agent.slug] ?? nil else {
                    if activeCursorAgents.contains(agent.slug) {
                        activeCursorAgents.remove(agent.slug)
                        cursorLabelSink(agent.slug, nil)
                    }
                    lastChipPoints[agent.slug] = nil
                    continue
                }
                seen.insert(agent.slug)
                lastChipPoints[agent.slug] = point
                cursorLabelSink(agent.slug, point)
            }
            for slug in activeCursorAgents.subtracting(seen) {
                cursorLabelSink(slug, nil)
                lastChipPoints[slug] = nil
            }
            activeCursorAgents = seen
            // Overlay grammar: the halo stands down where an agent's
            // chip is acting — their flash owns that element. Points
            // arrive flipped to AppKit space; overlay rects are top-left.
            let chipRects = seen.compactMap { lastChipPoints[$0] }.map { p in
                CGRect(x: p.x - 8, y: (primaryHeight - p.y) - 8, width: 80, height: 44)
            }
            overlay.agentChips(chipRects)
        } else {
            retractCursorChips()
        }
        // B7's shelf — the roster as fixed chips, top-right. Asking
        // agents get the question glyph; a live cursor reads as acting.
        let asking = Set(AgentAskChannel.pending().map(\.agent))
        AgentShelfOverlay.shared.update(agents.map { agent in
            AgentShelfOverlay.Entry(
                slug: agent.slug, name: agent.name,
                colorHex: AgentCursor.palette(for: agent.slug),
                state: asking.contains(agent.slug) || asking.contains(agent.name) ? .asking
                    : (seen.contains(agent.slug) ? .acting : .idle))
        })
    }

    /// The cursor toggle went off (or the roster emptied) — every label
    /// chip hides and the gaze feed loses the cursor candidates, so a
    /// dead surface can't answer "which agent am I looking at".
    private func retractCursorChips() {
        for slug in activeCursorAgents { cursorLabelSink(slug, nil) }
        activeCursorAgents = []
        lastChipPoints = [:]
        overlay.agentChips([])
    }

    // MARK: - Agent asks (park + notify)

    /// Parked agent asks live as files — MCP children can't reach this
    /// process's continuations. The watcher materializes each pending ask
    /// into a Work row the overlay and voice `respond_to_task` resolve the
    /// same way as an in-process ask.
    private var askWatcher: Task<Void, Never>?

    private func startAskWatcher() {
        askWatcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.syncAgentAsks()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func syncAgentAsks() {
        let pending = AgentAskChannel.pending()
        let live = Set(pending.map(\.id))
        // The ask file disappearing means the child timed out or was
        // answered elsewhere — settle the row honestly.
        for work in tasks where work.isAgentAsk {
            guard let askID = work.agentAskID, !live.contains(askID) else { continue }
            finish(work, .cancelled, say: "Ask expired.")
        }
        for ask in pending where !tasks.contains(where: { $0.agentAskID == ask.id }) {
            let work = Work(label: "Agent \(ask.agent)", request: ask.prompt,
                            spec: DriveTask(goal: ask.prompt))
            work.agentAskID = ask.id
            work.ask = ask.kind == "confirm" ? .confirm(ask.prompt)
                : ask.kind == "choice" ? .choice(prompt: ask.prompt, options: ask.options)
                : .question(ask.prompt)
            tasks.append(work)
            selectedID = work.id
            feed.add(.consent, "Agent \(ask.agent) asks: \(ask.prompt)")
            cue("Glass")
        }
        if !pending.isEmpty { onChange() }
        checkStalledWork()
    }

    /// A task with no dispatch activity for `stallTimeout` is almost
    /// certainly wedged — flag the row so it reads "Stalled", and say so
    /// once. Further dispatches clear the flag via `lastActivity`.
    static let stallTimeout: TimeInterval = 45
    /// Second bound — the flagged task can't just run quiet forever: a
    /// parked `.choice` ask offers "keep going" or "stop". `stallAsked`
    /// holds the watchdog once asked (or answered) until real activity
    /// opens a fresh episode, so a vouched-for task isn't re-asked.
    static let stallAskTimeout: TimeInterval = 120

    private func checkStalledWork() {
        let now = Date()
        for work in tasks where work.active && work.ask == nil && !work.stallAsked {
            let quiet = now.timeIntervalSince(work.lastActivity)
            if !work.stalled, quiet > Self.stallTimeout {
                work.stalled = true
                feed.add(.error, "\(work.label) — quiet for \(Int(Self.stallTimeout))s, possibly stuck.")
                cue("Basso")
            }
            if quiet > Self.stallAskTimeout {
                work.stallAsked = true
                offerStallChoice(on: work)
            }
        }
    }

    /// 120s quiet → ask "keep going, or stop?" through the same parked
    /// `.choice` machinery a mid-task ask uses (radial + spoken ordinal
    /// + dwell pick). The expiry default keeps the task: `park`'s own
    /// deadline resumes nil, and a non-answer must never destroy work
    /// the user may want — only an explicit "Stop" cancels. That maps
    /// cleanly onto the existing nil-resume semantics; auto-cancel on
    /// expiry would let a timer kill a parked user's task.
    private func offerStallChoice(on work: Work) {
        feed.add(.consent, "\(work.label) — quiet for \(Int(Self.stallAskTimeout))s; asking whether to keep going.")
        Task { @MainActor [weak self, weak work] in
            guard let self, let work else { return }
            // Re-check inside the park's own turn — the worker may have
            // parked its own ask since checkStalledWork ran, and a second
            // park would clobber that live continuation. Any armed ask
            // (on ANY work, or the gaze radial) wins over stacking a
            // stall check on top of it.
            guard work.active, work.ask == nil, self.pendingAskCount == 0 else {
                work.stallAsked = false
                return
            }
            let answer = await self.park(.choice(
                prompt: "Still working on \"\(work.label)\" — keep going, or stop?",
                options: ["Keep working", "Stop"]), on: work)
            guard work.active else { return }
            let stop: Bool
            if let answer {
                if let index = Int(answer) {
                    stop = index == 1
                } else {
                    // A literal (non-ordinal) answer only stops on an
                    // explicit kill word — "keep", "yes", anything else
                    // vouches for the task.
                    let text = answer.lowercased()
                    stop = ["stop", "cancel", "quit", "kill"]
                        .contains { text.contains($0) }
                }
            } else {
                stop = false
            }
            if stop {
                self.feed.add(.note, "\(work.label) — stopped at the stall check.")
                self.cancel(work.id)
                return
            }
            // Vouched for — reset the quiet clock so the row reads
            // "Working" again; `stallAsked` keeps the watchdog from
            // re-asking until real dispatch activity lands.
            work.stalled = false
            work.lastActivity = Date()
            self.onChange()
        }
    }

    // MARK: - Transport

    /// One proxy connection to the shared embedded daemon; reconnects by
    /// wholesale replacement per the generation contract.
    private func transport() async throws -> CuaConnection {
        if let connection, await connection.connected { return connection }
        if let inFlight = connectTask { return try await inFlight.value }
        let task = Task<CuaConnection, Error> {
            let socket = try await CuaDaemonHost.shared.socket()
            let conn = CuaConnection()
            try await conn.connect(socket: socket)
            return conn
        }
        connectTask = task
        defer { connectTask = nil }
        do {
            let conn = try await task.value
            connection = conn
            return conn
        } catch {
            // The socket may predate a daemon restart — re-vend once, then fail.
            connection = nil
            throw error
        }
    }

    private func call(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        if let commandDriver { return try await commandDriver(tool, args) }
        let started = ProcessInfo.processInfo.systemUptime
        defer { onLatencySpan?("driver.\(tool)", started, ProcessInfo.processInfo.systemUptime) }
        var args = args
        // A label the daemon refused to revive (its owner transport
        // died) is rotated by SessionResurrector — direct session calls
        // (overlay clicks, cursor reads) follow the live successor the
        // same way drive-loop calls do.
        if case .string(let label) = args["session"] {
            let effective = await SessionResurrector.shared.effectiveLabel(label)
            args["session"] = .string(effective)
            await suppressAgentCursorIfNeeded(on: effective)
        }
        let conn = try await transport()
        do {
            return try await conn.call(tool, arguments: args)
        } catch {
            // A daemon refusal (including an ended session) is a valid reply,
            // not transport death. Dropping this live proxy tombstones its
            // other sessions and prevents DriveLoop reviving on the same owner.
            guard !(await conn.connected) else { throw error }
            // Mutations are never replayed — a closed connection may have
            // already applied the effect. Read-only calls retry once on a
            // fresh transport.
            if connection === conn {
                connection = nil
                cursorSuppressedSessions.removeAll()
            }
            // Transport death tombstoned the daemon's sessions — any
            // suppression we recorded belongs to labels that no longer
            // exist, so successors earn their own toggle.
            if let e = error as? DriverConnectionError, e == .closed,
               CuaConnection.isReadOnly(tool, arguments: args) {
                return try await transport().call(tool, arguments: args)
            }
            throw error
        }
    }

    /// Session-bound observations must use the mutation session's owner:
    /// the driver rejects the same public label on a second transport, and
    /// element IDs minted there could not be redeemed by the first one.
    /// Only independent observations may use the parallel read connection.
    static func routeObservation(
        _ tool: String, _ args: [String: JSONValue],
        owner: DriveLoop.Call, independent: DriveLoop.Call
    ) async throws -> JSONValue {
        guard CuaConnection.isReadOnly(tool, arguments: args) else {
            throw DriverConnectionError.remote(
                "callRead routes read-only tools — \(tool) can mutate")
        }
        if args["session"] != nil { return try await owner(tool, args) }
        return try await independent(tool, args)
    }

    func callRead(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        try await Self.routeObservation(tool, args,
            owner: { [self] in try await call($0, $1) },
            independent: { [self] in try await callIndependentRead($0, $1) })
    }

    private func callIndependentRead(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        if let commandDriver { return try await commandDriver(tool, args) }
        let conn = try await readTransport()
        do {
            return try await conn.call(tool, arguments: args)
        } catch {
            guard !(await conn.connected) else { throw error }
            if readConnection === conn { readConnection = nil }
            if let e = error as? DriverConnectionError, e == .closed {
                return try await readTransport().call(tool, arguments: args)
            }
            throw error
        }
    }

    /// Binds the read lane to the same daemon socket `transport()` uses.
    /// The pair shares nothing inside the actor, so reads and writes
    /// interleave with zero shared state.
    private func readTransport() async throws -> CuaConnection {
        if let readConnection, await readConnection.connected { return readConnection }
        if let inFlight = connectReadTask { return try await inFlight.value }
        let task = Task<CuaConnection, Error> {
            let socket = try await CuaDaemonHost.shared.socket()
            let conn = CuaConnectionPool.makeReadConnection()
            try await conn.connect(socket: socket)
            return conn
        }
        connectReadTask = task
        defer { connectReadTask = nil }
        do {
            let conn = try await task.value
            readConnection = conn
            return conn
        } catch {
            readConnection = nil
            throw error
        }
    }

    /// One funnel for every earcon — the `sounds` toggle silences them
    /// all instead of each call site re-checking the setting.
    private func cue(_ name: String) {
        guard config.sounds, audioFeedbackAllowed() else { return }
        NSSound(named: name)?.play()
    }

    /// Jev choice — one System One call, validated against the candidate
    /// set. An empty key still produces a working closure: the client
    /// fails the call and the loop's honest model-failure settle reports
    /// it rather than the chooser refusing to exist.
    private func chooser() -> DriveLoop.Choose {
        JevChooser.make(apiKey: jevAPIKey())
    }

    // MARK: - Voice tool entry points

    /// Admit only a clear typed app-focus operation requested by the user.
    /// The instruction supplies consent; freshness and identity remain code-owned.
    func offerSemanticFocus(_ proposal: VoiceSemanticRouter.Proposal,
                            validate: @escaping @MainActor () async -> Bool,
                            runConfirmed: (@MainActor (Work) async -> Void)? = nil,
                            driverLoop: DriveLoop? = nil) -> Bool {
        guard config.semanticAppSuggestions, VoiceSemanticRouter.permitsRequestedFocus(proposal) else { return false }
        let spec = DriveTask(goal: "Focus requested application", application: proposal.target.id,
                             scope: .open, foreground: true)
        let work = Work(label: "Focus app", request: "Focus \(proposal.target.name)", spec: spec)
        work.semanticFocus = proposal
        work.semanticDriverLoop = driverLoop
        work.captureID = proposal.turn.id
        tasks.append(work); selectedID = work.id
        onCommandStage?(proposal.turn.id, work.id, .workCreated, nil)
        work.worker = Task { @MainActor [weak self, weak work] in
            guard let self, let work else { return }
            let valid: Bool
            do {
                valid = try await withVoiceDeadline(until: ProcessInfo.processInfo.systemUptime + 4) {
                    await validate()
                }
            } catch {
                guard work.active else { return }
                self.finish(work, .blocked("freshness unavailable"), say: "App freshness could not be checked. No action taken.")
                return
            }
            guard !Task.isCancelled, work.active else { return }
            guard self.config.semanticAppSuggestions, valid else {
                self.finish(work, .blocked("semantic target changed"), say: "The app or permission changed. No action taken.")
                return
            }
            work.semanticExecutionStarted = true
            if let runConfirmed { await runConfirmed(work) }
            else { await self.execute(work) }
        }
        return true
    }

    func cancelPendingSemanticFocus() {
        for work in tasks where work.active && work.semanticFocus != nil && !work.semanticExecutionStarted {
            cancel(work.id)
        }
    }

    /// `computer_command` — admits the task, returns instantly; the worker
    /// drives and pushes its outcome through `taskEventSink`.
    func beginVoiceTask(_ instruction: String, app: String? = nil,
                        frontmostHint: String? = nil,
                        literalText: String? = nil,
                        transcriptHint: String? = nil,
                        taskOnly: Bool = false,
                        steps: [String] = [],
                        captureID: UUID? = nil,
                        pinnedWindowID: Int? = nil,
                        windowScroll: WindowScrollRequest? = nil,
                        desktopDisplay: UInt32? = nil,
                        allowParsedScroll: Bool = true,
                        scrollContinuation: NativeWindowObservation.ScrollViewport? = nil,
                        continuousScroll: Bool = false,
                        onConversationScroll: (@MainActor (NativeWindowObservation.VerifiedScroll) -> Void)? = nil,
                        admissionIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) async -> String {
        let started = ProcessInfo.processInfo.systemUptime
        onCommandStage?(captureID, nil, .coordinatorBegin, nil)
        defer { onLatencySpan?("task.admission", started, ProcessInfo.processInfo.systemUptime) }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled, admissionIsCurrent(), !trimmed.isEmpty else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "I didn't catch a task.").encoded()
        }
        if FastAction.retiredTargetRequest(trimmed) != nil || transcriptHint.flatMap(FastAction.retiredTargetRequest) != nil {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "Please name the control you want to use.").encoded()
        }
        if VoiceAdmissionPolicy.isDesktopSwitchQuestion(trimmed)
            || transcriptHint.map(VoiceAdmissionPolicy.isDesktopSwitchQuestion) == true {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "That question doesn't request an action.").encoded()
        }
        let normalized = trimmed.lowercased()
        let space = DesktopSpaceTarget(command: trimmed)
        let classified = windowScroll == nil ? IntentRouter.classify(trimmed) : nil
        if taskOnly, classified?.verb == .cancel, FastAction.parseOpen(trimmed) == nil {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "Say stop or pause listening to interrupt.").encoded()
        }
        if space != nil || desktopDisplay != nil {
            guard case .numbered = space, desktopDisplay != nil, transcriptHint == instruction,
                  captureID != nil, let pinnedWindowID, pinnedWindowID > 0, app != nil,
                  steps.isEmpty, literalText == nil, windowScroll == nil, !continuousScroll else {
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                       say: "Please make a fresh hands-free request naming the desktop.").encoded()
            }
        }
        if let windowScroll {
            let bound = Self.voiceTaskSpec(trimmed, app: app, frontmostHint: frontmostHint,
                values: literalText.map { ["text": $0] } ?? [:], windowID: pinnedWindowID)
            let sameTranscript = transcriptHint.map {
                Data($0.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                    == Data(windowScroll.goal.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            } ?? true
            guard steps.isEmpty, !continuousScroll, sameTranscript, windowScroll.matches(bound) else {
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                       say: "The scrolling request or target changed.").encoded()
            }
        }
        let phrase = Self.normalizedPhrase(trimmed)
        // Utterances about existing work aren't tasks — each answers from
        // the task log (or shows the cheat sheet) and creates no Work row.
        if windowScroll == nil, Self.repeatPhrases.contains(phrase) {
            guard let last = tasks.last(where: {
                !$0.active && !Self.repeatPhrases.contains(Self.normalizedPhrase($0.request))
            }) else {
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                       say: "Nothing to repeat.").encoded()
            }
            feed.add(.route, "repeat → \"\(last.request)\"")
            return await beginVoiceTask(last.request,
                                        app: app,
                                        frontmostHint: frontmostHint,
                                        taskOnly: taskOnly,
                                        captureID: captureID, pinnedWindowID: pinnedWindowID,
                                        allowParsedScroll: allowParsedScroll,
                                        scrollContinuation: scrollContinuation,
                                        continuousScroll: continuousScroll, onConversationScroll: onConversationScroll,
                                        admissionIsCurrent: admissionIsCurrent)
        }
        if Self.recapPhrases.contains(phrase) {
            guard let last = tasks.last(where: { !$0.active && !$0.isAgentAsk }) else {
                return VoiceToolResult(status: VoiceToolResult.Status.ok,
                                       say: "I haven't done anything yet.").encoded()
            }
            return VoiceToolResult(status: VoiceToolResult.Status.ok,
                say: VoiceToolResult.spoken(Self.recap(of: last), words: 30)).encoded()
        }
        if Self.helpPhrases.contains(phrase) {
            overlay.showCheatSheet(lines: Self.cheatSheet)
            feed.add(.note, "showed the command cheat sheet")
            return VoiceToolResult(status: VoiceToolResult.Status.ok,
                                   say: Self.helpSummary).encoded()
        }
        if tasks.contains(where: { $0.active && $0.request.lowercased() == normalized }) {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "I'm already working on that.").encoded()
        }
        feed.add(.heard, "\"\(trimmed)\"")
        // The scorer's speech prior — "click save" biases toward the
        // Save-labeled candidate for a few seconds after the utterance.
        lastUtterance = (trimmed, Date())
        // Deterministic lanes need no model — admit the task either way,
        // but note once per key gap why anything model-driven will fail.
        onCommandStage?(captureID, nil, .keyBegin, nil)
        let missingKey = jevAPIKey().isEmpty
        onCommandStage?(captureID, nil, .keyEnd, nil)
        if missingKey {
            if !missingKeyNoted {
                missingKeyNoted = true
                feed.add(.note, "No Jev API key — deterministic commands still work; model-driven tasks will fail.")
            }
        } else {
            missingKeyNoted = false
        }

        var values: [String: String] = [:]
        if let literalText { values["text"] = literalText }
        // The model's ordered steps ARE the plan — fold into context rather
        // than a second planner.
        let plan = steps.filter { !$0.isEmpty }
        onCommandStage?(captureID, nil, .gazeBegin, nil)
        var gazeContext: String?
        if windowScroll == nil, space == nil { gazeContext = await gazeContextProvider() }
        onCommandStage?(captureID, nil, .gazeEnd, nil)
        guard !Task.isCancelled, admissionIsCurrent() else {
            onCommandStage?(captureID, nil, .cancelled, nil)
            return VoiceToolResult(status: VoiceToolResult.Status.cancelled, say: "Cancelled.").encoded()
        }
        // Lane D — deterministic routing consult: verb × referent ×
        // modifiers picks the lane; the routed intent rides the context
        // so the executor knows an "answer" intent fetches, not clicks,
        // and the provenance echo (≤5 words) becomes the spoken ack.
        onCommandStage?(captureID, nil, .referentBegin, nil)
        var referent: GazeReferent?
        if windowScroll == nil, space == nil { referent = await gazeService.scorer.currentReferent }
        onCommandStage?(captureID, nil, .referentEnd, nil)
        guard !Task.isCancelled else {
            onCommandStage?(captureID, nil, .cancelled, nil)
            return VoiceToolResult(status: VoiceToolResult.Status.cancelled, say: "Cancelled.").encoded()
        }
        let routed = (taskOnly && classified?.verb == .cancel) ? nil : classified.flatMap {
            IntentRouter.route(verb: $0.verb, referent: referent, modifiers: $0.modifiers)
        }
        // The router's cancel verdict is authoritative, not advisory, and
        // it is UNIVERSAL: "stop"/"cancel that"/"never mind" with no named
        // target takes every active task and every live agent turn — a
        // stop request must never spin up a drive loop for itself, and it
        // must never leave sibling work running past the word "stop". A
        // named target ("stop scout") keeps the targeted path.
        if !taskOnly, classified?.verb == .cancel {
            feed.add(.route, "\"\(trimmed)\" → cancel")
            if let hint = Self.cancelHint(from: trimmed) {
                return await cancelVoiceTask(hint)
            }
            let stopped = await cancelAllRunning()
            return VoiceToolResult(
                status: stopped ? VoiceToolResult.Status.cancelled
                                : VoiceToolResult.Status.nothingRunning,
                say: stopped ? "Stopped." : "Nothing is running.").encoded()
        }
        let previousContext = windowScroll == nil ? ([plan.isEmpty ? nil : "Plan: \(plan.joined(separator: "; "))",
                                transcriptHint, gazeContext,
                                routed.map { "Intent lane: \($0.lane.rawValue) — \($0.reason)" }]
            .compactMap { $0 })
            .joined(separator: "\n") : ""
        let spec = Self.voiceTaskSpec(trimmed, app: app, frontmostHint: frontmostHint,
            previousContext: previousContext.isEmpty ? nil : previousContext,
            values: values, windowID: pinnedWindowID)

        let label = Self.gerundPhrase(for: trimmed) ?? trimmed
        guard !Task.isCancelled, admissionIsCurrent() else {
            onCommandStage?(captureID, nil, .cancelled, nil)
            return VoiceToolResult(status: VoiceToolResult.Status.cancelled, say: "Cancelled.").encoded()
        }
        let work = Work(label: label, request: trimmed, spec: spec)
        guard windowScroll?.matches(spec) != false else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "The scrolling request or target changed.").encoded()
        }
        work.windowScroll = windowScroll
        if case .numbered(let number) = space, let desktopDisplay {
            work.desktopSwitch = (number, desktopDisplay)
        }
        work.allowParsedScroll = allowParsedScroll
        work.provenance = captureID.map { SpeechProvenance(captureID: $0) }
        work.captureID = captureID
        work.scrollContinuation = scrollContinuation
        if continuousScroll {
            guard scrollContinuation != nil, let parsed = FastAction.parse(trimmed),
                  case .scroll = parsed.action.body else {
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                       say: "I couldn't bind a continuous scroll.").encoded()
            }
        }
        work.continuousScroll = continuousScroll
        work.scrollAuthorization = admissionIsCurrent
        work.onConversationScroll = onConversationScroll
        tasks.append(work)
        onCommandStage?(captureID, work.id, .workCreated, nil)
        selectedID = work.id
        work.worker = Task { [weak self] in
            if work.continuousScroll { await self?.executeContinuousScroll(work) }
            else { await self?.execute(work) }
        }
        // The provenance echo names the referent so a misread is caught in
        // the half-second before work starts; referent-free tasks keep the
        // gerund ack.
        let ack = routed.flatMap { $0.referent != nil ? IntentRouter.provenanceEcho($0) : nil } ?? label
        return VoiceToolResult(status: VoiceToolResult.Status.started, say: ack).encoded()
    }

    /// `respond_to_task` — resolves the parked ask. Returns a refusal when
    /// nothing is waiting, so the model can stop re-asking. The task hint
    /// resolves positionally first ("the first one" is the OLDEST parked
    /// ask, "last"/"newest" the newest), then by substring, then — with
    /// no hint at all — the turn that spawned the work, then the newest.
    func respondToTask(_ answer: String, task: String? = nil,
                       captureID: UUID? = nil, exactAskID: UUID? = nil) async -> String? {
        guard !VoiceAdmissionPolicy.isDesktopSwitchQuestion(answer) else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "That question doesn't select an answer.").encoded()
        }
        let parked = tasks.filter(\.awaitingAnswer)
        var target: Work?
        if let hint = task?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hint.isEmpty {
            if let exactID = UUID(uuidString: hint) {
                target = parked.first { $0.id == exactID }
                guard target != nil else {
                    return VoiceToolCatalog.result(status: "blocked", summary: "That task is no longer waiting.", error: "ask_changed")
                }
            } else {
            switch Self.parkedSelection(in: hint, count: parked.count) {
            case .index(let index):
                target = parked[index]
            case .outOfRange:
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                    say: "Only \(parked.count) \(parked.count == 1 ? "ask is" : "asks are") waiting.").encoded()
            case .unparseable:
                target = parked.first {
                    $0.request.localizedCaseInsensitiveContains(hint)
                        || $0.label.localizedCaseInsensitiveContains(hint)
                } ?? parked.last
            }
            }
        } else {
            // Attribute the answer to the turn that spawned the ask when
            // the caller carries it — a respond emitted inside the same
            // capture that raised the ask resolves that ask, not merely
            // the newest.
            target = captureID.flatMap { id in parked.first { $0.captureID == id } }
                ?? parked.last
        }
        guard let target else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "Nothing is waiting for an answer.").encoded()
        }
        let retired = FastAction.retiredTargetRequest(answer)
        let clickReply = VoiceAdmissionPolicy.isBareGazeClick(answer)
        if retired != nil || clickReply {
            guard parked.count == 1, target.active, exactAskID == target.askID else {
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                       say: "Please answer the current question by name.").encoded()
            }
            switch target.ask {
            case .choice: break
            case .question where clickReply: break
            default:
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                       say: "Please answer the current question by name.").encoded()
            }
        }
        var choice: OrdinalAnswer = .unparseable
        if case .choice(_, let options) = target.ask {
            let label = VoiceAdmissionPolicy.normalized(answer)
            let exact = options.indices.filter { VoiceAdmissionPolicy.normalized(options[$0]) == label }
            if exact.count == 1, let index = exact.first { choice = .picked(index) }
            else if !exact.isEmpty || clickReply || retired == .palette || retired == .unboundGaze { choice = .outOfRange }
            else { choice = Self.ordinalIndex(in: answer, limit: options.count) }
            if case .outOfRange = choice {
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                       say: "Which of the offered options do you mean?").encoded()
            }
        }
        // A parked agent ask resolves through the shared answer file — the
        // child's poll picks it up and its drive loop resumes.
        if let askID = target.agentAskID {
            let reply: String
            if case .confirm = target.ask {
                reply = DriveLoop.affirmative(answer) ? "yes" : "no"
            } else if case .picked(let index) = choice {
                // Agent choice asks take the option index — same wire
                // shape the child's DriveLoop already maps.
                reply = "\(index)"
            } else {
                reply = answer
            }
            AgentAskChannel.answer(askID, reply)
            finish(target, .done, say: "Answered.")
            return VoiceToolResult(status: VoiceToolResult.Status.ok,
                                   say: "Answered.").encoded()
        }
        if case .confirm = target.ask, let approval = target.approvalContinuation {
            let yes = DriveLoop.affirmative(answer)
            target.ask = nil
            target.approvalContinuation = nil
            approval.resume(returning: yes)
            if !yes { cancel(target.id) }
            return VoiceToolResult(status: VoiceToolResult.Status.ok,
                                   say: yes ? "Continuing." : "Stopped.").encoded()
        }
        // A parked choice wants an option index on the wire — spoken
        // ordinals ("two", "the second one", "number 3") map here; an
        // unparseable answer passes through literally and the loop maps it.
        if case .choice = target.ask,
           let continuation = target.askContinuation {
            switch choice {
            case .picked(let index):
                clearOverlayPick(ownedBy: target.askID)
                target.ask = nil
                target.askContinuation = nil
                continuation.resume(returning: "\(index)")
                return VoiceToolResult(status: VoiceToolResult.Status.ok,
                                       say: "Got it.").encoded()
            case .outOfRange:
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                       say: "Say the number next to it.").encoded()
            case .unparseable:
                clearOverlayPick(ownedBy: target.askID)
                target.ask = nil
                target.askContinuation = nil
                continuation.resume(returning: answer)
                return VoiceToolResult(status: VoiceToolResult.Status.ok,
                                       say: "Got it.").encoded()
            }
        }
        if let continuation = target.askContinuation {
            target.ask = nil
            target.askContinuation = nil
            continuation.resume(returning: answer)
            return VoiceToolResult(status: VoiceToolResult.Status.ok, say: "Got it.").encoded()
        }
        return VoiceToolResult(status: VoiceToolResult.Status.refused,
                               say: "That answer arrived too late.").encoded()
    }

    func respondToTaskExact(_ answer: String, taskID: UUID, askID: UUID, captureID: UUID) async -> String {
        guard let work = tasks.first(where: { $0.id == taskID }), work.awaitingAnswer,
              work.askID == askID else {
            return VoiceToolCatalog.result(status: "blocked", summary: "That question changed. Please answer the current question.",
                                            error: "ask_changed")
        }
        if case .confirm = work.ask {
            let words = VoiceAdmissionPolicy.normalized(answer)
            guard ["yes", "no", "approve", "decline", "go ahead", "do it"].contains(words) else {
                return VoiceToolCatalog.result(status: "clarification", summary: "Please explicitly approve or decline this action.",
                                                error: "explicit_consent_required")
            }
        }
        return await respondToTask(answer, task: taskID.uuidString, captureID: captureID, exactAskID: askID)
            ?? VoiceToolCatalog.result(status: "blocked", summary: "That task is no longer waiting.", error: "ask_changed")
    }

    /// `cancel_task` — hint-matched, else the newest active work.
    func cancelVoiceTask(_ hint: String? = nil) async -> String {
        let live = tasks.filter(\.active)
        let target = hint.flatMap { h in
            live.first { $0.request.localizedCaseInsensitiveContains(h)
                       || $0.label.localizedCaseInsensitiveContains(h) }
        } ?? live.last
        guard let target else {
            // No voice work matched — "stop scout" names a delegated agent
            // turn, not a local task. Interrupting beats a wrong refusal.
            if let agentBridge {
                return await agentBridge.interruptAgent(hint: hint)
            }
            return VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                                   say: "Nothing is running.").encoded()
        }
        cancel(target.id)
        return VoiceToolResult(status: VoiceToolResult.Status.cancelled,
                               say: "Cancelled \(target.label).").encoded()
    }

    /// `delegate_to_agent` — hands the instruction to a named agent.
    func delegateToAgent(task: String, agent: String? = nil,
                         name: String? = nil, role: String? = nil,
                         description: String? = nil) async -> String {
        guard let agentBridge else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "No agents are available.").encoded()
        }
        let soleAttempt = !hasDelegationAttempt
        hasDelegationAttempt = true
        let start = UUID()
        voiceDelegation = .init(revision: start, receipt: nil)
        do {
            // The delegated task carries the same gaze context the local
            // loop would get — an agent asked to "keep an eye on that"
            // needs to know what "that" was.
            var message = task
            if let gazeContext = await gazeContextProvider() {
                message += "\n\nGaze context (what the user is looking at):\n" + gazeContext
            }
            let result = try await agentBridge.delegateWithReceipt(DelegationRequest(
                agentSlug: agent, newAgentName: name, newAgentRole: role,
                newAgentDescription: description, message: message))
            if voiceDelegation.revision == start {
                voiceDelegation = .init(revision: UUID(), receipt: soleAttempt ? result.receipt : nil)
            }
            return result.payload
        } catch {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: VoiceToolResult.spoken(error.localizedDescription,
                                            words: 15)).encoded()
        }
    }

    // MARK: - UI surface

    func select(id: UUID?) {
        selectedID = id.flatMap { wanted in tasks.first { $0.id == wanted }?.id }
            ?? tasks.first(where: \.active)?.id
    }

    func cancel(_ id: UUID) {
        guard let work = tasks.first(where: { $0.id == id }),
              work.active || work.awaitingAnswer || work.ask != nil else { return }
        if let askID = work.agentAskID {
            AgentAskChannel.discard(askID)
            work.agentAskID = nil
        }
        work.worker?.cancel()
        if let continuation = work.askContinuation {
            work.askContinuation = nil
            continuation.resume(returning: nil)
        }
        if let approval = work.approvalContinuation {
            work.approvalContinuation = nil
            approval.resume(returning: false)
        }
        work.ask = nil
        if work.active {
            finish(work, .cancelled, say: work.desktopSideEffect.map { "Cancelled. " + $0 } ?? "Cancelled.")
        } else {
            onChange()
        }
    }

    func cancelSelected() { selectedID.map(cancel) }

    /// A parked `.choice` anywhere on the spine — a radial is up, so
    /// Escape must be consumable or the key leaks to the frontmost app
    /// mid-pick. `pendingTaskApproval`/`pendingQuestions` only count
    /// `.confirm`/`.question`; this is the missing arm of that gate.
    var hasActiveChoiceAsk: Bool {
        tasks.contains(where: \.awaitingChoice) || pendingOverlayPick != nil
    }

    var pendingAskCount: Int { tasks.filter(\.awaitingAnswer).count }

    /// Settle the newest parked `.choice` the way its deadline firing
    /// would — the continuation resumes nil and the radial retracts
    /// through the normal park teardown, so the task decides what a
    /// non-answer means (an ambiguity ask settles blocked, a loop ask
    /// declines). An agent's parked choice has no continuation — its row
    /// cancels, which reads to the child like its own timeout.
    /// Returns whether a parked choice was waiting.
    @discardableResult
    func declineTopmostChoiceAsk() -> Bool {
        let displayed = tasks.first { $0.awaitingChoice && $0.askID == choiceAskID }
        guard let work = displayed ?? tasks.last(where: \.awaitingChoice) else {
            guard pendingOverlayPick != nil else { return false }
            clearOverlayPick()
            return true
        }
        if work.agentAskID != nil {
            cancel(work.id)
            return true
        }
        clearOverlayPick(ownedBy: work.askID)
        work.ask = nil
        if let continuation = work.askContinuation {
            work.askContinuation = nil
            continuation.resume(returning: nil)
        }
        onChange()
        return true
    }

    /// Overlay Run/Cancel → resumes the parked confirm; an agent's parked
    /// ask gets its answer file instead.
    func resolveApproval(id: UUID, approved: Bool) {
        guard let work = tasks.first(where: { $0.id == id }) else { return }
        if let askID = work.agentAskID {
            AgentAskChannel.answer(askID, approved ? "yes" : "no")
            work.ask = nil
            work.agentAskID = nil
            finish(work, approved ? .done : .cancelled,
                   say: approved ? "Approved." : "Declined.")
            return
        }
        guard let approval = work.approvalContinuation else { return }
        work.ask = nil
        work.approvalContinuation = nil
        approval.resume(returning: approved)
        if !approved { cancel(id) }
    }

    func retryWork(_ id: UUID) {
        guard let old = tasks.first(where: { $0.id == id }), !old.active else { return }
        let work = Work(label: old.label, request: old.request, spec: old.spec)
        work.provenance = old.provenance
        work.captureID = old.captureID
        tasks.append(work)
        selectedID = work.id
        work.worker = Task { [weak self] in await self?.execute(work) }
    }

    func stopAll() {
        for work in tasks where work.active { cancel(work.id) }
    }

    /// Universal stop — "stop" means ALL of it, not the newest task or
    /// this capture's work: every active voice task, every parked ask
    /// (cancel resolves the continuation the same nil its deadline
    /// would), and every agent turn in flight. `cancel(_:)` already
    /// covers the ask+worker teardown per row; the agent reach goes
    /// through `interruptAll` so a bare "stop" doesn't bounce off an
    /// ambiguous roster. Returns whether anything was actually running
    /// so the caller's "Stopped."/"Nothing is running." stays honest.
    @discardableResult
    func cancelAllRunning() async -> Bool {
        let live = tasks.filter(\.active)
        for work in live { cancel(work.id) }
        var agentsStopped = false
        if let agentBridge {
            let reply = await agentBridge.interruptAll()
            agentsStopped = VoiceToolResult(jsonString: reply)?.status
                == VoiceToolResult.Status.cancelled
        }
        if !live.isEmpty || agentsStopped {
            feed.add(.outcome, "Stopped everything — \(live.count) task\(live.count == 1 ? "" : "s")\(agentsStopped ? " + agent turns" : "").")
        }
        return !live.isEmpty || agentsStopped
    }

    // MARK: - Lifecycle

    static func performInventoryWarmup(
        _ read: @MainActor (String, [String: JSONValue]) async throws -> JSONValue
    ) async throws {
        _ = try await read("list_windows", [:])
    }

    func scheduleInventoryWarmup(generation: String, read: @escaping @MainActor () async throws -> Void) {
        guard !inventoryWarmStopped, inventoryWarmGeneration != generation else { return }
        inventoryWarmTask?.cancel()
        inventoryWarmGeneration = generation
        let id = UUID()
        inventoryWarmID = id
        inventoryWarmAttempts += 1
        inventoryWarmPending.insert(id)
        inventoryWarmStartedAt = nil
        inventoryWarmSettledAt = nil
        inventoryWarmTask = Task { [weak self] in
            guard let self else { return }
            let start = ProcessInfo.processInfo.systemUptime
            if self.inventoryWarmID == id { self.inventoryWarmStartedAt = start }
            defer {
                let end = ProcessInfo.processInfo.systemUptime
                self.inventoryWarmElapsed += (end - start) * 1000
                self.inventoryWarmPending.remove(id)
                self.onLatencySpan?("driver.prewarmInventory", start, end)
                if self.inventoryWarmID == id {
                    self.inventoryWarmSettledAt = end
                    self.inventoryWarmTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                self.inventoryWarmReads += 1
                try await read()
                try Task.checkCancellation()
                self.inventoryWarmCompleted += 1
            } catch {
                if Task.isCancelled || error is CancellationError {
                    self.inventoryWarmCancelled += 1
                } else {
                    self.inventoryWarmFailed += 1
                }
            }
        }
    }

    func prepareInventoryWarmup(_ prepare: @escaping @MainActor () async throws -> InventoryWarmupBinding) {
        guard !inventoryWarmStopped, inventoryPreparationTask == nil else { return }
        inventoryPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inventoryPreparationTask = nil }
            do {
                try Task.checkCancellation()
                let binding = try await prepare()
                guard !self.inventoryWarmStopped, !Task.isCancelled else {
                    await binding.close()
                    return
                }
                self.scheduleInventoryWarmup(generation: binding.generation, read: binding.read)
            } catch {}
        }
    }

    private func scheduleInventoryPreparation() {
        guard Permission.screenRecording.isGranted else { return }
        prepareInventoryWarmup { [weak self] in
            guard let self else { throw CancellationError() }
            let conn = try await self.readTransport()
            guard let socket = await conn.boundSocket else { throw DriverConnectionError.closed }
            return InventoryWarmupBinding(generation: socket, read: {
                try await Self.performInventoryWarmup { try await conn.call($0, arguments: $1) }
            }, close: { [weak self] in
                await conn.close()
                if self?.readConnection === conn { self?.readConnection = nil }
            })
        }
    }

    private func warmDriver() async {
        guard !inventoryWarmStopped, commandDriver == nil else { return }
        let conn = try? await transport()
        guard !inventoryWarmStopped else {
            await conn?.close()
            if connection === conn { connection = nil }
            return
        }
        scheduleInventoryPreparation()
    }

    func warm() {
        Task { [weak self] in await self?.warmDriver() }
    }

    /// The app slept or woke — re-probe both transports; a dead proxy is
    /// replaced on next use, never repaired in place.
    func wakeDriverSession() {
        Task { [weak self] in
            guard let self else { return }
            if let conn = self.connection, await !conn.connected {
                self.connection = nil
                self.cursorSuppressedSessions.removeAll()
            }
            if let conn = self.readConnection, await !conn.connected {
                self.readConnection = nil
            }
        }
    }

    func shutdown() {
        voiceDelegation = .init(revision: UUID(), receipt: nil)
        inventoryWarmStopped = true
        inventoryPreparationTask?.cancel()
        inventoryWarmTask?.cancel()
        stopAll()
        // App teardown mid-hold must not orphan the gaze feed — the
        // pump's 30s watchdog would cap it, but the socket's owner is
        // here, not there.
        endListeningHint()
        let conn = connection
        connection = nil
        let read = readConnection
        readConnection = nil
        Task {
            await conn?.close()
            await read?.close()
        }
    }

    // MARK: - Execution

    private func executeContinuousScroll(_ work: Work) async {
        work.continuousStartedAt = ProcessInfo.processInfo.systemUptime
        while work.active, !Task.isCancelled {
            guard work.scrollAuthorization?() == true else {
                finish(work, .blocked("target_changed"), say: "The scrolling target changed. Scrolling stopped.")
                return
            }
            let began = ProcessInfo.processInfo.systemUptime
            let previousRead = work.verifiedScroll?.viewport.readGeneration
            await execute(work, keepScrolling: true)
            guard work.active, !Task.isCancelled else { return }
            guard let witness = work.verifiedScroll, witness.viewport.readGeneration != previousRead else {
                finish(work, .blocked("scroll_unverified"), say: "I couldn't verify the scroll. Scrolling stopped.")
                return
            }
            work.scrollContinuation = witness.viewport
            work.onConversationScroll?(witness)
            work.message = "Scrolling \(witness.direction)…"
            work.lastActivity = Date()
            work.stalled = false
            work.stallAsked = false
            onChange()
            let delay = max(0, 0.25 - (ProcessInfo.processInfo.systemUptime - began))
            do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } }
            catch { return }
        }
    }

    private func execute(_ work: Work, keepScrolling: Bool = false) async {
        let started = ProcessInfo.processInfo.systemUptime
        onCommandStage?(work.captureID, work.id, .executorBegin, nil)
        defer { onCommandStage?(work.captureID, work.id, .executorEnd, nil) }
        defer { onLatencySpan?("task.execution", started, ProcessInfo.processInfo.systemUptime) }
        feed.add(.route, "\(work.label) → drive loop")
        work.message = "Working…"
        onChange()

        // Ambiguous app names never bind silently — "devin" matching two
        // running apps parks a numbered choice (voice ordinal, "click 2",
        // or a dwell pick all resolve it) and the answer pins the spec to
        // that app's bundle. Unanswered, the task settles naming the
        // candidates rather than guessing at the wrong app.
        if work.desktopSwitch == nil, let requested = work.spec.application, work.spec.pid == nil {
            onCommandStage?(work.captureID, work.id, .resolveBegin, nil)
            if let pid = DriveLoop.capturedForegroundApplication(
                application: requested, windowID: work.spec.windowID)?.pid {
                work.spec.pid = pid
                onCommandStage?(work.captureID, work.id, .resolveEnd, nil)
            } else {
                let detail = await resolver.resolveDetailed(requested)
                onCommandStage?(work.captureID, work.id, .resolveEnd, nil)
                let names = detail.matches.map(\.name)
                if Set(names.map { $0.lowercased() }).count > 1 {
                    if let answer = await park(.choice(
                        prompt: "'\(requested)' could be more than one app.",
                        options: names), on: work) {
                        if let idx = Int(answer), detail.matches.indices.contains(idx) {
                            work.spec.application = detail.matches[idx].bundle
                                ?? detail.matches[idx].name
                        } else if let named = detail.matches.first(where: {
                            $0.name.localizedCaseInsensitiveContains(answer)
                        }) {
                            work.spec.application = named.bundle ?? named.name
                        } else {
                            finish(work, .blocked("ambiguous app"),
                                   say: "'\(requested)' could be \(names.joined(separator: " or ")) — say which.")
                            return
                        }
                    } else {
                        finish(work, .blocked("ambiguous app"),
                               say: "'\(requested)' could be \(names.joined(separator: " or ")) — say which.")
                        return
                    }
                }
            }
        }

        let traceTurn = work.captureID, traceWork = work.id
        let nativeCurrent: @MainActor @Sendable () -> Bool = { [weak work] in
            guard let work else { return false }
            return work.active && work.scrollAuthorization?() != false
        }
        let imageClient = JevChooser.experimentalWindowImages
            ? JevClient(apiKey: jevAPIKey(), model: "jev-1.14.0") : nil
        let loop = work.semanticDriverLoop ?? DriveLoop(
            call: { [weak self, weak work] tool, args in
                guard let self else { throw DriverConnectionError.closed }
                guard let work, work.active, work.scrollAuthorization?() != false else { throw CancellationError() }
                return try await self.observedDriverCall(tool, args, turn: traceTurn, work: traceWork, readOnly: false)
            },
            choose: chooser(),
            ask: { [weak self, weak work] ask in
                await self?.park(ask, on: work)
            },
            granted: { [config] in config.alwaysAllowComputerUse },
            // The read lane keeps observes off the mutation transport —
            // a slow dispatch can't starve the next round's snapshot.
            callRead: { [weak self] tool, args in
                guard let self else { throw DriverConnectionError.closed }
                return try await self.observedDriverCall(tool, args, turn: traceTurn, work: traceWork, readOnly: true)
            },
            scopedCall: imageClient.map { _ in
                { [weak self] tool, args, origin in
                    guard let self else { throw DriverConnectionError.closed }
                    return try await self.observedScopedDriverCall(
                        tool, args, origin: origin, turn: traceTurn, work: traceWork)
                }
            },
            visualChoose: imageClient.map { JevChooser.makeVisual(client: $0) },
            verifyVisual: imageClient.map { JevChooser.makeVisualVerifier(client: $0) },
            // Spoken one-shots ride the cursorless direct session; the
            // model-driven rounds below keep `session` and its cursor.
            directSession: Self.directSession,
            // Dictation verbs latch the literal-capture lane — the words
            // go to DictationDelivery verbatim, never to a planner.
            // `shared` is weak: nil outside a live app session reports
            // the feature as absent instead of claiming a toggle.
            onDictationRequest: { start in
                VoiceController.shared?.dictationRequest(start) ?? false
            },
            resolver: resolver,
            config: .init(allowParsedScroll: work.allowParsedScroll),
            focusLease: inputGuard,
            nativeEvent: { [weak self] stage in
                await self?.recordNativeStage(stage, turn: traceTurn, work: traceWork)
            },
            nativeTextEvent: { [weak self] receipt in
                await self?.recordNativeTextInsertion(receipt, turn: traceTurn, work: traceWork)
            },
            foregroundAppLauncher: foregroundAppLauncher.map { launch in { try await launch($0, nativeCurrent) } },
            nativeAdmission: nativeCurrent,
            gaze: { [weak self] in
                // A live hold already owns the ~20Hz stream — reading it
                // beats a fresh HTTP GET per command, and a dead stream
                // still falls back to one bounded snapshot inside.
                if let self { return try await self.freshestGazeSample() }
                return try await GazeClient().snapshot()
            },
            gazeCommit: { [weak self] in
                await self?.gazeService.commitTarget()
            },
            scrollContinuation: work.scrollContinuation,
            freshScrollContinuation: work.continuousScroll && work.verifiedScroll == nil,
            scrollContinuationIsCurrent: work.scrollAuthorization.map { authorization in
                { await authorization() }
            },
            onVerifiedScroll: { @MainActor [weak work] witness in
                guard let work, work.active, !Task.isCancelled else { return }
                work.verifiedScroll = witness
            },
            feed: { [weak self, weak work] s in
                Task { @MainActor in
                    self?.feed.add(.dispatch, s)
                    // Dispatch lines reset the stall clock — a task emitting
                    // feed lines is working, not wedged, and opens a fresh
                    // episode the stall check can ask about again.
                    work?.lastActivity = Date()
                    work?.stalled = false
                    work?.stallAsked = false
                }
            })

        // `run` never throws — cancellation and transport faults surface as
        // DriveResult statuses, so every outcome funnels through describe.
        @MainActor func runWork() async -> DriveResult {
            if let target = work.desktopSwitch {
                var confirmed = false
                let result: DesktopSpaceSwitch.Outcome
                do {
                    try await loop.gateExplicit("select desktop", corpus: "Mission Control Desktop \(target.number)",
                                                denied: work.spec.deny, confirmed: &confirmed)
                    result = try await loop.focusLeased {
                        await self.switchDesktop(target.number, target.display,
                            { work.active && work.scrollAuthorization?() == true },
                            { work.desktopSideEffect = $0 })
                    }
                } catch {
                    let code: DesktopSpaceSwitch.Code = error is CancellationError ? .authorizationCancelled : .policyDenied
                    result = .init(code, "The desktop request was not authorized or was cancelled.")
                }
                if work.active { work.desktopDecision = result.code; work.desktopOverviewOrigin = result.origin }
                return await loop.settle(.blocked(result.message), work.spec, [],
                    blockedReason: result.code == .pressAcceptedUnverified ? "desktop press unverified" : "desktop unverified")
            }
            if let scroll = work.windowScroll {
                return await loop.runWindowScroll(scroll, task: work.spec, session: Self.session)
            }
            if let semantic = work.semanticFocus {
                return await loop.runAppFocus(bundleID: semantic.target.id, task: work.spec,
                    session: Self.directSession, nativeEvents: { [weak self] stage in
                        await self?.recordNativeStage(stage, turn: traceTurn, work: traceWork)
                    })
            }
            return await loop.run(work.spec, session: Self.session)
        }
        var result = await runWork()
        // A session-death settle is the one block class a whole-task
        // retry can safely redo: the daemon rejected admission before
        // anything dispatched, and the resurrector has already rotated
        // "voice" to a live successor — the retried run lands on it.
        // One retry only; a second death settles honestly.
        if Self.shouldRetrySessionDeath(result) {
            feed.add(.note, "\(work.label) — the computer-control connection restarted; trying once more")
            result = await runWork()
        }
        guard work.active else { return }
        work.elapsedMs = (ProcessInfo.processInfo.systemUptime - (work.continuousStartedAt ?? started)) * 1000
        work.history = result.history
        work.dispatchedEffect = result.dispatchedEffect || (keepScrolling && work.dispatchedEffect)
        guard !Task.isCancelled else {
            finish(work, .cancelled, say: "Cancelled.")
            return
        }
        if keepScrolling, result.status == .done, result.dispatchedEffect, work.verifiedScroll != nil { return }
        let (outcome, say) = Self.describe(result, request: work.request)
        feed.add(.outcome, say)
        taskEventSink(work.captureID,
                      VoiceToolResult(kind: VoiceToolResult.Kind.taskOutcome, status: VoiceToolResult.Status.ok,
                                      say: VoiceToolResult.spoken(say, words: 30)).encoded(),
                      true)
        finish(work, outcome, say: say)
    }

    private func observedDriverCall(_ tool: String, _ args: [String: JSONValue],
                                    turn: UUID?, work: UUID, readOnly: Bool) async throws -> JSONValue {
        onCommandStage?(turn, work, .driverBegin, .init(tool))
        do {
            let result = try await (readOnly ? callRead(tool, args) : call(tool, args))
            onCommandStage?(turn, work, .driverEnd, .init(tool))
            return result
        } catch {
            onCommandStage?(turn, work, .driverFailed, .init(tool))
            throw error
        }
    }

    private func observedScopedDriverCall(
        _ tool: String, _ args: [String: JSONValue], origin: CuaResultOrigin?,
        turn: UUID?, work: UUID
    ) async throws -> CuaToolResult {
        guard commandDriver == nil else { throw VisualCaptureError.unavailable }
        onCommandStage?(turn, work, .driverBegin, .init(tool))
        let started = ProcessInfo.processInfo.systemUptime
        defer { onLatencySpan?("driver.\(tool)", started, ProcessInfo.processInfo.systemUptime) }
        do {
            let connection = try await transport()
            let result = try await connection.callScoped(tool, arguments: args, origin: origin)
            onCommandStage?(turn, work, .driverEnd, .init(tool))
            return result
        } catch {
            onCommandStage?(turn, work, .driverFailed, .init(tool))
            throw error
        }
    }

    private func recordNativeStage(_ stage: VoiceCommandTrace.Stage, turn: UUID?, work: UUID) {
        onCommandStage?(turn, work, stage, nil)
    }

    private func recordNativeTextInsertion(_ receipt: FocusedTextBinding.Insertion, turn: UUID?, work: UUID) {
        onNativeTextInsertion?(turn, work, receipt)
    }

    /// Park an ask on the work row until the overlay or voice resolves it.
    /// Both kinds reach the voice lane — a silent `.confirm` reads to the
    /// user as a hung task. A parked ask that nobody answers auto-declines
    /// after `Self.askDeadline` rather than wedging the task forever.
    static let askDeadline: TimeInterval = 90
    /// Tests may shorten expiry; it can never extend the production ceiling.
    var askExpirySeconds: TimeInterval = 90

    func park(_ ask: DriveLoop.Ask, on work: Work?) async -> String? {
        guard let work, work.active else { return nil }
        // One parked ask per work — a second park would overwrite the
        // ask row and orphan the first continuation forever (it could
        // never resume: every resolve path reads the CURRENT slots).
        // Declining honestly hands the loop the same nil an expiry
        // would, so the task settles instead of wedging.
        guard work.ask == nil, !work.awaitingAnswer else {
            feed.add(.consent, "\(work.label) — an ask is already parked; declined the new one.")
            return nil
        }
        work.ask = ask
        let askID = work.askID
        let prompt: String
        switch ask {
        case .confirm(let p): prompt = p + " Say yes or no."
        case .question(let p): prompt = p
        case .choice(let p, let options):
            // Spoken choices and explicit accessibility picks use the same index.
            let list = options.enumerated()
                .map { "\($0.offset + 1)) \($0.element)" }
                .joined(separator: ", ")
            prompt = p + " Which one — " + list + "?"
        }
        taskEventSink(work.captureID,
                      VoiceToolResult(kind: VoiceToolResult.Kind.taskQuestion,
                                      status: VoiceToolResult.Status.question,
                                      say: VoiceToolResult.spoken(prompt, words: 25)).encoded(),
                      true)
        feed.add(.consent, prompt)
        onChange()
        defer {
            if work.askID == askID { work.ask = nil }
            onChange()
        }
        switch ask {
        case .confirm:
            let yes: Bool = await withCheckedContinuation { c in
                work.approvalContinuation = c
                wakeConversationWaiters(work.id, .question)
                expire(ask, on: work)
            }
            return yes ? "yes" : "no"
        case .question:
            return await withCheckedContinuation { c in
                work.askContinuation = c
                wakeConversationWaiters(work.id, .question)
                expire(ask, on: work)
            }
        case .choice(_, let options):
            // The micro-radial rings the options around the gaze point;
            // explicit accessibility picks and spoken ordinals resume the
            // same continuation with the same 0-based index string. The
            // Glass earcon marks "your pick is needed" — same chime the
            // agent-ask path plays — so a radial appearing without a
            // voice line isn't silent.
            let answer: String? = await withCheckedContinuation { c in
                work.askContinuation = c
                wakeConversationWaiters(work.id, .question)
                armChoiceRadial(ask, options: options, on: work)
                cue("Glass")
                expire(ask, on: work)
            }
            clearOverlayPick(ownedBy: askID)
            return answer
        }
    }

    /// Auto-decline a parked ask whose deadline passes unresolved — the
    /// work row must still hold the same ask, or a later park's expiry
    /// would fire on the wrong continuation.
    private func expire(_ ask: DriveLoop.Ask, on work: Work) {
        let askID = work.askID
        let deadline = askExpirySeconds.isFinite
            ? min(Self.askDeadline, max(0.01, askExpirySeconds)) : Self.askDeadline
        Task { @MainActor [weak self, weak work] in
            try? await Task.sleep(for: .seconds(deadline))
            guard let self, let work, work.askID == askID, work.ask == ask else { return }
            // An expired choice retracts its radial — leaving the chips up
            // would invite a pick that resolves nothing.
            if case .choice = ask { self.clearOverlayPick(ownedBy: askID) }
            if let approval = work.approvalContinuation {
                work.approvalContinuation = nil
                work.ask = nil
                approval.resume(returning: false)
            } else if let question = work.askContinuation {
                work.askContinuation = nil
                work.ask = nil
                question.resume(returning: nil)
            }
            self.feed.add(.consent, "Timed out — declined.")
            self.onChange()
        }
    }

    private func finish(_ work: Work, _ outcome: Work.Outcome, say: String) {
        guard work.active || work.outcome == nil else { return }
        if let began = work.continuousStartedAt {
            work.elapsedMs = (ProcessInfo.processInfo.systemUptime - began) * 1000
        }
        // A retired work can't leave a parked ask open — loop asks always
        // resolve before their worker settles (the worker awaits `park`),
        // so the only reachable case is an ask parked outside the worker,
        // like the stall-check ask, whose task ended underneath it.
        if let continuation = work.askContinuation {
            work.askContinuation = nil
            clearOverlayPick(ownedBy: work.askID)
            continuation.resume(returning: nil)
        }
        if let approval = work.approvalContinuation {
            work.approvalContinuation = nil
            approval.resume(returning: false)
        }
        // The continuation arms above only clear resumable asks — an
        // agent ask (no continuation) or a continuation-less ask would
        // otherwise linger on the finished row and `pendingQuestions`
        // would resurface an unanswerable card forever.
        work.ask = nil
        work.agentAskID = nil
        work.active = false
        work.outcome = outcome
        wakeConversationWaiters(work.id, .finished(outcome))
        work.message = say
        work.worker = nil
        if selectedID == nil { selectedID = work.id }
        // Voice-turn tasks get their outcome spoken through the sink —
        // but a dead realtime socket makes that silence, so the earcon
        // plays for them too: Glass done, Basso anything else. Agent-ask
        // rows already chimed at park time; another would be spam.
        if !work.isAgentAsk {
            if case .done = outcome {
                cue("Glass")
            } else {
                cue("Basso")
            }
        }
        onChange()
    }

    func waitForConversationBoundary(_ id: UUID, throughQuestions: Bool = false) async -> ConversationBoundary? {
        guard let work = tasks.first(where: { $0.id == id }) else { return nil }
        if let outcome = work.outcome { return .finished(outcome) }
        if work.awaitingAnswer, !throughQuestions { return .question }
        if Task.isCancelled {
            cancel(id)
            return .finished(.cancelled)
        }
        let registration = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                conversationWaiters[id, default: []].append(
                    BoundaryWaiter(id: registration, throughQuestions: throughQuestions, continuation: $0))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.conversationWaiters[id]?.contains(where: { $0.id == registration }) == true else { return }
                self.cancel(id)
            }
        }
    }

    private func wakeConversationWaiters(_ id: UUID, _ boundary: ConversationBoundary) {
        let waiters = conversationWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            if waiter.throughQuestions, boundary == .question {
                conversationWaiters[id, default: []].append(waiter)
            } else { waiter.continuation.resume(returning: boundary) }
        }
    }

    /// Markers that turn a settle line into a qualified outcome — the
    /// executor's own "delivered but unconfirmed" phrasing ("…was not
    /// independently confirmed", "…not verified"). A clean effect keeps
    /// the terse "Done."; a caveat is spoken verbatim instead.
    private static let outcomeQualifiers = [
        "not independently confirmed", "not confirmed", "not verified",
        "could not be verified", "could not verify", "unverified"
    ]

    /// The one settle a whole-task retry can safely redo: a
    /// session-death block is provably pre-dispatch (the daemon rejected
    /// admission before any effect ran), and a confirmed effect would
    /// make a replay risk double-applying it.
    nonisolated static func shouldRetrySessionDeath(_ result: DriveResult) -> Bool {
        guard case .blocked = result.status,
              result.blockedReason == DriveLoop.sessionRestartedReason else { return false }
        return !result.dispatchedEffect
    }

    /// DriveResult → (outcome, spoken line). `.done` is only reached with
    /// a confirmed effect behind it — the loop enforces that invariant.
    /// When the settle's own outcome line (the history tail the executor
    /// writes) carries a verification caveat, that line IS the honest
    /// "Done." — flattening it would lie about what was confirmed.
    static func describe(_ result: DriveResult,
                                 request: String) -> (Work.Outcome, String) {
        switch result.status {
        case .done:
            guard result.dispatchedEffect else {
                return (.uncertain("unverified"), "Finished, but nothing visibly changed.")
            }
            if let tail = result.history.last,
               Self.outcomeQualifiers.contains(where: {
                   tail.localizedCaseInsensitiveContains($0) }) {
                return (.done, tail)
            }
            return (.done, "Done.")
        case .alreadySatisfied:
            return (.alreadyDone, "That's already done.")
        case .blocked(let why), .blockedByConsent(let why):
            if result.blockedReason == DriveLoop.scrollUnverifiedReason || result.blockedReason == DriveLoop.launchUnverifiedReason || result.blockedReason == "desktop press unverified" {
                return (.uncertain(why), why)
            }
            return (.blocked(why), why)
        case .handedBack(let reason):
            if reason == .lowConfidence {
                return (.blocked(reason.rawValue),
                        "I couldn't identify the target. Which control do you mean?")
            }
            return (.blocked(reason.rawValue),
                    "I couldn't pick a confident next step.")
        case .needsText(let field):
            return (.blocked("needs text for \(field)"),
                    "I need the text for \(field).")
        case .needsWindow(let candidates):
            return (.blocked("ambiguous window"),
                    "Which window — \(candidates.prefix(3).joined(separator: ", "))?")
        case .maxSteps:
            return (.blocked("ran out of steps"), "I ran out of steps.")
        case .cancelled:
            return (.cancelled, "Cancelled.")
        }
    }

    // MARK: - Overlay seam

    /// Retract the pick surface and drop its pick path — called when a
    /// parked choice resolves, expires, or is cancelled. Chip-scoped on
    /// purpose: the conforming ring and the hint halo retire on their
    /// own lifecycle, so resolving a pick can't order them out from
    /// under the scorer. Clearing the slot invalidates old choice callbacks.
    func clearOverlayPick(ownedBy askID: UUID? = nil) {
        if let askID, choiceAskID != askID { return }
        pendingOverlayPick = nil
        choiceAskID = nil
        overlay.hideChips()
    }

    /// A parked `.choice` rings its options around where the user is
    /// looking — explicit picks resolve the same continuation a spoken
    /// ordinal does, with the same 0-based index string. The pick is
    /// bound to the ask it armed for: a pick firing after the ask moved
    /// on (superseded, expired, already answered) declines rather than
    /// resolving a question it was never shown.
    private func armChoiceRadial(_ ask: DriveLoop.Ask, options: [String], on work: Work) {
        let askID = work.askID
        let onPick: @MainActor (Int) -> Void = { [weak self, weak work] idx in
            guard let self, let work, self.choiceAskID == askID, options.indices.contains(idx) else { return }
            guard work.askID == askID, work.ask == ask, let continuation = work.askContinuation else {
                self.clearOverlayPick()
                return
            }
            work.ask = nil
            work.askContinuation = nil
            self.clearOverlayPick()
            continuation.resume(returning: "\(idx)")
        }
        choiceAskID = askID
        pendingOverlayPick = onPick
        overlay.showRadial(labels: options,
                           near: liveGazePoint ?? screenCenter,
                           radius: Self.measuredRadius(for: options),
                           onPick: onPick)
    }

    /// The ring radius for N options — a readability floor per chip
    /// count, pushed outward by the measured gaze-error band so chips
    /// never crowd the region the target could actually be in. Better
    /// calibration → tighter disambiguation automatically; a missing
    /// report leaves the spacing floor (~40px minimum via the overlay).
    private static func measuredRadius(for options: [String]) -> Double {
        let spacing = min(max(110, Double(options.count) * 36), 220)
        return max(spacing, calibrationErrorBand())
    }

    /// Median tracker error in pixels, from the calibration run's
    /// `accuracy_report.json` in the tracker directory. Settable for
    /// tests — production reads the file the tracker's accuracy test
    /// writes via `writeReport("accuracy_report.json", …)`.
    static var accuracyReportURL: URL? = TrackerHost.trackerDirectory()?
        .appendingPathComponent("accuracy_report.json")

    static func calibrationErrorBand() -> Double {
        guard let url = accuracyReportURL,
              let data = try? Data(contentsOf: url),
              let report = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .number(let median)? = report["error_px"]?["overall"]?["median"],
              median.isFinite, median > 0
        else { return 0 }
        return median
    }

    /// Where a radial parks with no gaze fix — the middle of the display
    /// under the last gaze point (only while that point is still fresh),
    /// else the main screen (top-left space).
    private var screenCenter: CGPoint {
        let screen = liveGazePoint.flatMap { ScreenGeometry.display(containing: $0) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen.map({ ScreenGeometry.topLeftFrame(of: $0) })
        else { return .zero }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The overlay's dwell-pick feed — gaze points in top-left screen
    /// points. The listen-time pump calls this; TargetOverlay decides
    /// whether a pending radial pick resolves.
    func gazeIngest(_ p: CGPoint) {
        lastGazePoint = p
        lastGazeAt = Date()
        overlay.ingestGaze(p)
    }

    // MARK: - Always-on gaze (B2/B4/B5)

    /// Point the service's seams at this coordinator. The candidate feed
    /// enumerates through `call` (the resurrecting transport wrapper —
    /// a dead session label rotates, never fails the feed); every UI
    /// seam lands on TargetOverlay through the same paths the Fn pump
    /// already used, so hold-time behavior is unchanged — the stream
    /// just outlives the hold now.
    func configureGazeService() {
        var feed = GazeCandidateFeed(
            call: { [weak self] tool, args in
                guard let self else { throw DriverConnectionError.closed }
                return try await self.call(tool, args)
            },
            // Snapshots ride the read lane so a slow dispatch mid-task
            // can't starve the feed's tick; the DOM probe keeps `call`
            // (execute_javascript is mutation-class on the wire).
            readCall: { [weak self] tool, args in
                guard let self else { throw DriverConnectionError.closed }
                return try await self.callRead(tool, args)
            })
        feed.session = Self.gazeSession
        feed.agentCursors = { [weak self] in
            // Cursor chips ride the same rect grammar the halo stand-
            // down uses; shelf chips carry their own top-left rects.
            var out: [(slug: String, name: String, frame: CGRect)] = []
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            if let self {
                for (slug, p) in self.lastChipPoints {
                    out.append((slug: slug, name: slug, frame: CGRect(
                        x: p.x - 8, y: (primaryHeight - p.y) - 8,
                        width: 80, height: 44)))
                }
            }
            for (slug, rect) in AgentShelfOverlay.shared.chipRects {
                out.append((slug: slug, name: slug, frame: rect))
            }
            return out
        }
        gazeFeed = feed
        let service = gazeService
        service.enumerate = { [weak self] point in
            guard let self, let feed = self.gazeFeed else { return .empty }
            return await self.witnessedGazeRoster(at: point, capture: { await CommittedGazeHit.capture(at: $0) },
                                                 enumerate: { await feed.enumerate(around: $0) })
        }
        service.windowIDUnder = { [weak self] point in
            self?.gazeFeed?.windowUnder(point)?.id
        }
        service.speechHint = { [weak self] in
            guard let self, let last = self.lastUtterance,
                  Date().timeIntervalSince(last.at) < 5 else { return nil }
            return last.text
        }
        service.gazePointSink = { [weak self] point in
            guard let self else { return }
            if let rect = self.heldDwellRect, !rect.contains(point) { self.heldDwellRect = nil }
            self.gazeIngest(point)
        }
        service.eventSink = { [weak self] event in
            guard let self else { return }
            let dwellFeedback: Bool
            switch event {
            case .acquire(let c), .hold(let c, _):
                dwellFeedback = self.gazeService.dwellPolicy.allows(c) && !self.gazeService.dwellSuppressed()
            default: dwellFeedback = false
            }
            self.overlay.intentEvent(event, dwellFeedback: dwellFeedback)
        }
        service.staleSink = { [weak self] stale in
            guard let self else { return }
            self.overlay.gazeLost(stale > GazeSample.freshnessWindow)
            if self.overlay.haloArmed, stale > Self.haloStaleLimit {
                self.overlay.hideHalo()
            }
        }
        // Dwell never fires while the overlay owns a pick, an ask is
        // parked, or the user is mid-sentence — the voice answer is the
        // consent, and "click this" + a dwell fire in one breath is a
        // double actuation.
        service.dwellSuppressed = { [weak self] in
            guard let self else { return true }
            return self.heldDwellRect != nil || self.pendingOverlayPick != nil
                || self.captureActiveProbe()
                || self.tasks.contains {
                    $0.awaitingAnswer || $0.awaitingApproval || $0.awaitingChoice
                }
        }
        service.actuate = { [weak self] candidate in
            guard let self, self.heldDwellRect == nil else { return false }
            return await self.actuateCommitted(candidate, willPress: { self.heldDwellRect = candidate.motorRect }) {
                self.gazeService.dwellPolicy.allows(candidate) && !self.gazeService.dwellSuppressed()
            }
        }
        service.noteOut = { [weak self] s in self?.feed.add(.dispatch, s) }
        gazeContextProvider = { [weak service] in await service?.referentContext() }
        // L5's live-capture flag — the dwell-suppression arm above.
        // `shared` is weak: nil outside a live app session reads as "no
        // capture", never as suppression.
        captureActiveProbe = { VoiceController.shared?.captureActive ?? false }
        // Service stop() = full overlay teardown — the ring, halo and
        // chips all retire plus every pick claim, so the next start
        // can't inherit a dead pick path. The one place `hideAll` is
        // correct outside user-driven dismiss.
        service.overlayTeardown = { [weak self] in
            self?.gazeEnumeration = UUID()
            self?.nativeGaze = nil
            self?.heldDwellRect = nil
            self?.clearOverlayPick()
            self?.overlay.hideAll()
            self?.overlay.gazeLost(false)
        }
    }

    func witnessedGazeRoster(at point: CGPoint,
                             capture: @MainActor (CGPoint) async -> CommittedGazeHit?,
                             enumerate: @MainActor (CGPoint) async -> GazeCandidateFeed.Batch) async -> GazeCandidateFeed.Batch {
        let request = UUID()
        gazeEnumeration = request
        let hit = await capture(point)
        guard !Task.isCancelled, request == gazeEnumeration else { return .empty }
        var batch = await enumerate(point)
        guard !Task.isCancelled, request == gazeEnumeration else { return .empty }
        let previous = nativeGaze
        nativeGaze = nil
        guard let hit, let window = batch.windowID else { return batch }
        let matches = batch.candidates.filter { $0.windowID == window && hit.describes($0, at: point) }
        guard matches.count == 1, let target = matches.first,
              await hit.corroborates(target, at: point), !Task.isCancelled,
              request == gazeEnumeration else { return batch }
        let id = previous.map { $0.target == target && $0.hit.representsSameElement(as: hit) ? $0.id : UUID() } ?? UUID()
        nativeGaze = (id, hit, target)
        batch.nativeWitness = id
        return batch
    }

    /// Candidate → actuation mapping (`CommittedActuation` is file-scope,
    /// at the end of this file, so nonisolated callers can match it).
    /// The point is the live gaze when it's still inside the motor rect,
    /// else the motor midpoint — a commit clicks what the eyes chose,
    /// not a stale frame edge.
    nonisolated static func actuation(
        for c: IntentCandidate, gaze: CGPoint?,
        windowBounds: (Int) -> CGRect? = GazeCandidateFeed.windowBounds
    ) -> CommittedActuation? {
        let point = gaze.map { c.motorRect.contains($0) ? $0
            : CGPoint(x: c.motorRect.midX, y: c.motorRect.midY) }
            ?? CGPoint(x: c.motorRect.midX, y: c.motorRect.midY)
        switch c.kind {
        case .trafficLight:
            guard let raw = c.id.split(separator: ":").last,
                  let kind = WindowControls.Kind(rawValue: String(raw)),
                  let pid = c.pid else { return nil }
            // `c.frame` is the button rect — `press(matching:)` needs the
            // WINDOW bounds, resolved live from the candidate's windowID.
            guard let wid = c.windowID, let windowFrame = windowBounds(wid)
            else { return nil }
            return .trafficLight(kind, pid: pid, frame: windowFrame)
        case .axElement:
            if let token = axToken(in: c.id), let pid = c.pid, let wid = c.windowID {
                return .elementClick(pid: pid, windowID: wid, token: token)
            }
            return .pixelClick(point)
        case .dom, .menuBar, .ocr, .window:
            return .pixelClick(point)
        case .chip, .agentCursor:
            // Chips resolve through the overlay's own pick path; agent
            // cursors are observability chrome — never clicked.
            return nil
        }
    }

    /// `ax:<pid>:<wid>:<token>` → the element token; `_idx_<n>` marks an
    /// index-only element the verified path can't take — nil means the
    /// actuation falls back to the pixel form.
    nonisolated static func axToken(in id: String) -> String? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "ax" else { return nil }
        let token = parts.dropFirst(3).joined(separator: ":")
        guard !token.isEmpty, !token.hasPrefix("_idx_") else { return nil }
        return token
    }

    /// The gate every explicit actuation takes before touching input —
    /// the protected-phrase deny scan (a radial/overlay/dwell pick on a
    /// "Delete"/"Transfer money" candidate is refused the same way the
    /// dwell engine's own deny list refuses it: an explicit pick is not
    /// a bypass) and a NON-BLOCKING claim on the shared input lease. A
    /// click that missed its window drops instead of queueing behind a
    /// ⌘V paste or a dictation insert and landing late — the refusal is
    /// always honest in the feed.
    private func claimActuation(of elementText: String?) async -> Bool {
        if let phrase = Self.deniedReason(in: elementText) {
            feed.add(.consent, "Refused: '\(phrase)' is on the protected list.")
            cue("Basso")
            return false
        }
        guard await inputGuard.tryAcquire() else {
            feed.add(.note, "Dropped a click — input was busy.")
            return false
        }
        return true
    }

    /// The protected-phrase corpus check — the driver's deny list plus
    /// dwell's own token list, both matched on the same normalized text,
    /// so "sign-out"/"delete" can't hide behind a pick's consent.
    nonisolated static func deniedReason(in elementText: String?) -> String? {
        guard let elementText, !elementText.isEmpty else { return nil }
        if let hit = CuaPolicy.deniedPhrase(in: elementText) { return hit }
        let corpus = DwellPolicy.normalized(elementText)
        return DwellPolicy.deniedTokens.first {
            corpus.contains(DwellPolicy.normalized($0))
        }
    }

    @discardableResult
    func actuateCommitted(_ c: IntentCandidate, verb: FastAction.GazeVerb = .click,
                          willPress: @MainActor () -> Void = {},
                          permitted: @escaping @MainActor @Sendable () -> Bool = { true }) async -> Bool {
        guard verb == .click, !c.motorRect.isEmpty else { return false }
        // The pick lane skips the dwell engine's upstream corpus scan, so
        // this gate carries the same context a dwell commit sees: label,
        // role, URL, window title, app — an "OK" inside a "Confirm
        // Purchase" dialog or on a wire-transfer page refuses too.
        let corpus = [c.label, c.role, c.url ?? "", c.windowTitle ?? "",
                      c.appName ?? ""].joined(separator: " ")
        guard await claimActuation(of: corpus) else { return false }
        var target = c
        target.gazeLease = nil
        guard permitted(), let point = await gazeService.authorizedPoint(for: c), let bound = nativeGaze,
              gazeService.batch.nativeWitness == bound.id, bound.target == target else {
            await inputGuard.release()
            return false
        }
        let provenSource = gazeService.stream.liveObservations()
        let landed = Self.dispatchCommitted(verb: verb, current: {
            permitted() && gazeService.authorizes(c, at: point) { latest in
                bound.hit.matches(target, at: point) && (latest == point || bound.hit.matches(target, at: latest))
            }
        }, press: {
            bound.hit.press {
                guard permitted(), gazeService.authorizes(c, at: point),
                      gazeService.stream.isCurrent(provenSource) else { return false }
                willPress()
                return true
            }
        })
        if landed { overlay.flash(at: point) }
        await inputGuard.release()
        return landed
    }

    /// The dispatch half of `actuateCommitted` — runs under the input
    /// lease `claimActuation` claimed.
    static func dispatchCommitted(verb: FastAction.GazeVerb,
                                  current: () -> Bool, press: () -> Bool) -> Bool {
        guard verb == .click, current(), !Task.isCancelled else { return false }
        return press()
    }

    // MARK: - Fn-down pre-observe

    /// Called on Fn-down: everything here is speculative and bounded —
    /// warm the transport, the resolver's roster cache, and the gaze
    /// stream, then arm one best-effort halo where the user is already
    /// looking. Nothing may block capture, so every step is try?-quiet
    /// and the halo arm is budgeted to ~150ms.
    func beginListeningHint() {
        listenHintTask?.cancel()
        listenHintGeneration += 1
        listenHintTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let warm = Task { [weak self] in await self?.warmDriver() }
            // The always-on service already owns the socket while it
            // runs — a redundant start would drop+reconnect mid-hold.
            if !self.gazeService.running { await GazeStream.shared.start() }
            // A cancelled hint still runs to the end of its awaits —
            // never let a dead hold arm a pump behind endListeningHint.
            guard !Task.isCancelled else { return }
            self.startGazePump()
            if let front = NSWorkspace.shared.frontmostApplication?.localizedName {
                _ = await self.resolver.resolve(front)
            }
            if let point = await self.freshGazePoint() {
                let halo = Task { @MainActor [weak self] in await self?.armHalo(at: point) }
                Task { try? await Task.sleep(for: .milliseconds(150)); halo.cancel() }
                await halo.value
            }
            _ = await warm.value
        }
    }

    /// Capture ended or the utterance resolved non-computer — retract the
    /// speculative halo, stop feeding the dwell pick, undim any chips,
    /// and shut the stream down: nothing may keep the WebSocket and its
    /// ~20Hz parse running past the hold it was started for.
    ///
    /// Ordering matters: cancelling `listenHintTask` does not unwind an
    /// `await` already inside `GazeStream.start()` or a `startGazePump()`
    /// the task has queued but not yet run — cancellation is cooperative,
    /// not a kill. If `stop()` lands before that in-flight `start()`, the
    /// stream would be reopened with no consumer and nothing left to bound
    /// it. Draining the cancelled task first, then cancelling any pump it
    /// spawned, then stopping, is the only order that actually leaves the
    /// socket closed.
    func endListeningHint() {
        let hint = listenHintTask
        hint?.cancel(); listenHintTask = nil
        gazePump?.cancel(); gazePump = nil
        overlay.hideHalo()
        overlay.gazeLost(false)
        let generation = listenHintGeneration
        Task {
            await hint?.value
            // A Fn-down that arrived during the drain owns the stream
            // now — leave its socket and pump alone.
            guard listenHintGeneration == generation else { return }
            gazePump?.cancel(); gazePump = nil
            // The always-on service keeps the socket — the hold's
            // teardown only stops a stream the hold itself opened.
            if !gazeService.running { await GazeStream.shared.stop() }
        }
    }

    /// A dropped gaze socket mid-hold gets this many bounded reconnects —
    /// past that the pump keeps serving `latest()` and the staleness
    /// reads (dim, halo hide) carry the outage honestly.
    static let gazeRestartAttempts = 5
    static let gazeRestartCadence: TimeInterval = 2
    /// An armed halo whose feed has been stale this long is ordered out —
    /// a frozen ring reads as live UI, and the arm is display-only.
    static let haloStaleLimit: TimeInterval = 2

    /// The overlay's gaze feed for the hold's duration — every ~66ms the
    /// freshest stream sample lands in `gazeIngest`. Watchdog-bounded: a
    /// missed `endListeningHint` can't leave a pump running. While it
    /// runs it also owns the outage story: bounded socket restarts, the
    /// armed-chips stale dim, and the stale-halo retract.
    private func startGazePump() {
        gazePump?.cancel()
        gazePumpGeneration += 1
        let generation = gazePumpGeneration
        gazePump = Task { @MainActor [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            var lastFreshAt = ProcessInfo.processInfo.systemUptime
            var restarts = 0
            var lastRestartAt: TimeInterval = -.greatestFiniteMagnitude
            var gazeLost = false
            while !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime < deadline {
                let now = ProcessInfo.processInfo.systemUptime
                // The WS dropping must not die silently for the rest of
                // the hold — re-`start()` on a 2s cadence, bounded.
                if !(await GazeStream.shared.streaming),
                   restarts < Self.gazeRestartAttempts,
                   now - lastRestartAt >= Self.gazeRestartCadence {
                    restarts += 1
                    lastRestartAt = now
                    await GazeStream.shared.start()
                }
                if let sample = await GazeStream.shared.latest(), sample.isFresh {
                    lastFreshAt = now
                    self?.gazeIngest(CGPoint(x: sample.x, y: sample.y))
                }
                let staleFor = now - lastFreshAt
                // Armed chips reading "live" on a dead feed is a lie —
                // dim them ~1.5s into an outage, undim on recovery or
                // once nothing is armed.
                let overlay = self?.overlay
                let lost = (overlay?.pendingCount ?? 0) > 0
                    && staleFor > GazeSample.freshnessWindow
                if lost != gazeLost {
                    gazeLost = lost
                    overlay?.gazeLost(lost)
                }
                if overlay?.haloArmed == true, staleFor > Self.haloStaleLimit {
                    overlay?.hideHalo()
                }
                try? await Task.sleep(for: .milliseconds(66))
            }
            // Whoever ends the pump — Fn-up, watchdog, cancel — the
            // dim must not outlive the feed that drove it, and the
            // stream must not outlive the pump: it has no other reader,
            // so a missed endListeningHint still bounds the socket.
            // Generation-gated so a superseded pump can't hang up the
            // socket its replacement just opened — and the always-on
            // service's socket is never the hold's to stop.
            self?.overlay.gazeLost(false)
            if self?.gazePumpGeneration == generation,
               self?.gazeService.running == false {
                await GazeStream.shared.stop()
            }
        }
    }

    /// The freshest gaze sample the tracker can honestly offer — the
    /// live WebSocket stream first (during a hold it is ~20Hz and
    /// already paid for, so a command reads it in microseconds), a
    /// bounded HTTP snapshot only when the stream has nothing fresh.
    /// Neither fetch touches the tracker's health poll, and nothing on
    /// the command path waits on one.
    private func freshestGazeSample() async throws -> GazeSample {
        if let sample = await GazeStream.shared.latest(), sample.isFresh {
            return sample
        }
        return try await GazeClient().snapshot()
    }

    /// Same source as `freshestGazeSample`, snapped to a point and
    /// silent on miss — the halo arm takes this, never a refused claim.
    private func freshGazePoint() async -> CGPoint? {
        guard let sample = try? await freshestGazeSample() else { return nil }
        return CGPoint(x: sample.x, y: sample.y)
    }

    /// One halo arm: window under the gaze point, then the deepest element
    /// containing it — silent on every miss, this is a hint not a claim.
    /// Native AX frames and gaze share global top-left screen points.
    private func armHalo(at point: CGPoint) async {
        guard let target = try? await windowUnderGaze(point), !Task.isCancelled,
              let snap = try? await callRead("get_window_state", [
                  "pid": .number(Double(target.pid)),
                  "window_id": .number(Double(target.windowID)),
                  "session": .string(Self.gazeSession)]),
              !Task.isCancelled else { return }
        let content = snap["structuredContent"] ?? snap
        guard let frame = Self.haloFrame(at: point, in: content) else { return }
        overlay.showHalo(frame: frame)
    }

    static func haloFrame(at point: CGPoint, in snap: JSONValue) -> CGRect? {
        let content = snap["structuredContent"] ?? snap
        return DriveLoop.elements(from: content)
            .compactMap(DriveLoop.nativeAXScreenRect)
            .filter { $0.contains(point) }
            .min(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// The on-screen window under a top-left screen point — topmost z
    /// wins (`z_index` is higher = closer to the front on the wire), and
    /// our own windows never claim the gaze: a halo anchored on a chip
    /// or the settings card would read as Jev Voice targeting itself.
    private func windowUnderGaze(_ point: CGPoint) async throws -> (pid: Int, windowID: Int)? {
        let list = try await callRead("list_windows",
                                      ["session": .string(Self.gazeSession)])
        let rows = list["structuredContent"]?["windows"]?.array
            ?? list["windows"]?.array ?? []
        guard let row = DriveLoop.topmostWindowRow(
                at: point, in: rows, excludingPID: DriveLoop.ownPID),
              let pid = row["pid"]?.integer,
              let wid = row["window_id"]?.integer else { return nil }
        return (pid, wid)
    }

    /// JSONValue doubles for bounds/scale fields — `integer` is exact-Int
    /// only; geometry arrives fractional.
    private static func num(_ v: JSONValue?) -> Double? {
        if case .number(let d)? = v { return d }
        return nil
    }

    // MARK: - Utterance intercepts

    /// Intercept matching works on word content only — a trailing "again."
    /// is still "again".
    private static func normalizedPhrase(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let repeatPhrases: Set<String> = [
        "again", "do that again", "repeat that", "repeat",
        "do it again", "same thing", "one more time"
    ]
    static func isRepeatRequest(_ text: String) -> Bool {
        repeatPhrases.contains(normalizedPhrase(text))
    }
    private static let recapPhrases: Set<String> = [
        "what did you do", "what did you just do", "what happened",
        "what was that"
    ]
    private static let helpPhrases: Set<String> = [
        "what can i say", "what can you do", "help", "commands",
        "show commands"
    ]

    /// "What did you do" answered from the task's own ledger — the history
    /// tail plus the outcome line, never a model paraphrase.
    private static func recap(of work: Work) -> String {
        let tail = work.history.suffix(3).map {
            $0.replacingOccurrences(of: "\"", with: "")
        }
        let outcome = work.message.isEmpty ? "Finished." : work.message
        guard !tail.isEmpty else { return "Last task: \(work.label) — \(outcome)" }
        return "I \(tail.joined(separator: "; then ")). \(outcome)"
    }

    /// The spoken answer to "what can I say" — the lane families, terse.
    private static let helpSummary =
        "You can open, hide, or quit apps, click what you're looking at, "
        + "pause or recalibrate tracking, "
        + "hand work to an agent, or hold Fn and Control to dictate."

    /// The overlay cheat sheet — one line per lane family.
    private static let cheatSheet: [String] = [
        "open / hide / minimize / quit <app>",
        "click this · open this · what is this",
        "pause tracking · recalibrate · disable tracking",
        "type <text> here · scroll down",
        "ask <agent> to <task> · stop <agent>",
        "cancel that · do that again",
        "hold Fn+Ctrl to dictate text",
    ]

    /// Where a `respond_to_task` hint lands in the parked list — oldest
    /// first. Positional words ("first", "second", "last") beat
    /// substring matching because they're how people point at a list.
    enum ParkedSelection: Equatable {
        /// A positional word inside the list — 0-based, oldest first.
        case index(Int)
        /// A positional word the list doesn't reach — ask again.
        case outOfRange
        /// No positional word — the caller tries substring matching.
        case unparseable
    }

    /// "the first one" → 0, "second" → 1, "last"/"newest" → count-1.
    /// Bare digits read the same way ("task 2" → 1); anything else
    /// falls back to the caller's substring match.
    static func parkedSelection(in hint: String, count: Int) -> ParkedSelection {
        let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4,
                        "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
                        "ninth": 9]
        for token in normalizedPhrase(hint).split(separator: " ") {
            let token = String(token)
            switch token {
            case "last", "newest", "latest":
                return count > 0 ? .index(count - 1) : .outOfRange
            default:
                break
            }
            let n = ordinals[token]
                ?? Int(token)
                ?? Int(token.prefix(while: \.isNumber))
            guard let n, n > 0 else { continue }
            return (1...count).contains(n) ? .index(n - 1) : .outOfRange
        }
        return .unparseable
    }

    /// The cancel verb's remainder is the task/agent hint — "stop
    /// scout" → "scout", "cancel that" → nil (the newest active work).
    /// Fillers never name anything.
    static func cancelHint(from utterance: String) -> String? {
        let cancelVerbs: Set<String> = ["cancel", "stop", "nevermind", "abort"]
        var words = normalizedPhrase(utterance).split(separator: " ").map(String.init)
        if let i = words.firstIndex(where: { cancelVerbs.contains($0)
                                            || $0 == "never" }) {
            let drop = words[i] == "never" ? 2 : 1
            words.removeSubrange(i..<min(i + drop, words.count))
        }
        let fillers: Set<String> = ["that", "this", "it", "the", "please",
                                    "task", "everything", "all"]
        let rest = words.filter { !fillers.contains($0) }.joined(separator: " ")
        return rest.isEmpty ? nil : rest
    }

    /// How a spoken answer maps onto a parked choice's option list.
    enum OrdinalAnswer {
        /// A recognized ordinal/number inside the list — 0-based index.
        case picked(Int)
        /// A recognized number the list doesn't have — ask again.
        case outOfRange
        /// No ordinal at all — the loop maps the literal text itself.
        case unparseable
    }

    /// "2", "two", "second", "the second one", "number 3" → an option
    /// index. Spoken numbering is 1-based; the wire back to the loop is
    /// the 0-based index string the radial's onPick also produces.
    static func ordinalIndex(in answer: String, limit: Int) -> OrdinalAnswer {
        if case .pick(let number) = FastAction.retiredTargetRequest(answer) {
            return number <= limit ? .picked(number - 1) : .outOfRange
        }
        let cardinals = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                         "six": 6, "seven": 7, "eight": 8, "nine": 9]
        let ordinals = ["first": 1, "second": 2, "third": 3, "fourth": 4,
                        "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
                        "ninth": 9]
        for token in normalizedPhrase(answer).split(separator: " ") {
            let token = String(token)
            let n = Int(token)
                ?? Int(token.prefix(while: \.isNumber))  // "2nd" → 2
                ?? cardinals[token] ?? ordinals[token]
            guard let n else { continue }
            return (1...limit).contains(n) ? .picked(n - 1) : .outOfRange
        }
        return .unparseable
    }

    // MARK: - Intent helpers

    /// Pure construction shared by admission and the driver-boundary tests.
    static func voiceTaskSpec(_ instruction: String, app: String? = nil,
                              frontmostHint: String? = nil, previousContext: String? = nil,
                              values: [String: String] = [:], windowID: Int? = nil) -> DriveTask {
        let scope: TaskSpec.Scope = isPureOpenIntent(instruction) ? .open : .work
        var goal = instruction
        if let literal = values["text"], let parsed = FastAction.parse(instruction),
           parsed.appQualifier == nil, !parsed.action.deictic, case .type = parsed.action.body {
            goal = "type \"\(literal)\""
        }
        return DriveTask(goal: goal,
            application: app ?? (wantsFrontmost(instruction) ? frontmostHint : nil),
            windowID: windowID,
            previousContext: previousContext, scope: scope, values: values,
            foreground: wantsFrontmost(instruction) || scope == .open)
    }

    /// "open X" / "launch X" with no trailing clause — the app window is
    /// the deliverable, so the loop settles at launch rather than driving.
    static func isPureOpenIntent(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let openers = ["open ", "launch ", "start ", "bring up "]
        guard openers.contains(where: { lower.hasPrefix($0) }) else { return false }
        // Any continuation conjunction is a second step — "open Safari and
        // go to apple.com" must drive, not settle at launch.
        return !lower.contains(" and ") && !lower.contains(" to ")
            && !lower.contains(" then ")
    }

    static func wantsFrontmost(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("this app") || l.contains("current app")
            || l.contains("this window") || l.contains("frontmost")
    }

    /// "opening Spotify" from "open Spotify" — deterministic ack phrase.
    static func gerundPhrase(for instruction: String) -> String? {
        var words = instruction.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let filler: Set<String> = ["please", "jarvis", "jev", "hey", "ok", "okay",
                                   "can", "could", "would", "will", "you", "just",
                                   "kindly", "go"]
        while let first = words.first,
              filler.contains(first.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        guard let verb = words.first, let gerund = gerund(of: verb) else { return nil }
        var rest: [String] = []
        for word in words.dropFirst() {
            let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: ",;:."))
            if ["then", "afterwards", "after", "next", "please"].contains(cleaned.lowercased()) { break }
            if cleaned.isEmpty || rest.count >= 5 { break }
            rest.append(cleaned)
        }
        return ([gerund] + rest).joined(separator: " ")
    }

    private static func gerund(of verb: String) -> String? {
        let w = verb.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard w.count > 1, w.allSatisfy(\.isLetter) else { return nil }
        let nonActions: Set<String> = ["what", "when", "where", "who", "whom", "why",
            "how", "which", "the", "a", "an", "it", "its", "is", "are", "was",
            "were", "am", "be", "i", "we", "they", "he", "she", "me", "him",
            "them", "us", "my", "your", "his", "her", "their", "our", "this",
            "that", "these", "those", "there", "here", "if", "but", "not", "no",
            "yes", "to", "for", "in", "on", "at", "of", "as", "by", "or", "and",
            "so", "do", "does", "did", "have", "has", "had", "shall", "should",
            "may", "might", "must", "some", "any", "all"]
        guard !nonActions.contains(w) else { return nil }
        let doubles: Set<String> = ["run", "stop", "quit", "set", "cut", "hit",
            "put", "shut", "sit", "win", "plan", "drag", "drop", "grab", "tap",
            "hop", "skip", "swap", "wrap", "chat", "begin", "forget"]
        if doubles.contains(w) { return w + String(w.last!) + "ing" }
        if w.hasSuffix("ie") { return String(w.dropLast(2)) + "ying" }
        if w.count <= 2 || w.hasSuffix("ee") { return w + "ing" }
        if w.hasSuffix("e") { return String(w.dropLast()) + "ing" }
        return w + "ing"
    }
}

/// A trivial async mutex — one holder at a time for shared input surfaces
/// (pasteboard, foreground focus). Replaces the old lane registry's
/// focus/pasteboard leases with the only guarantee callers actually need.
actor AsyncLease {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var queuedCount: Int { waiters.count }

    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
        // release() left `held` true for us — ownership handoff, not release.
    }

    /// Non-blocking acquire for actuations that must not queue — a
    /// click arriving while a pasteboard/focus borrow is live drops
    /// (its window passed) rather than landing late.
    func tryAcquire() -> Bool {
        if held { return false }
        held = true
        return true
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()   // held stays true — the woken waiter owns it
        } else {
            held = false
        }
    }
}

/// Voice-tool payload — compact JSON the lane voices verbatim. The lane
/// matches `"status":"started"` literally to suppress a second response.
struct VoiceToolResult {
    enum Kind {
        static let taskOutcome = "task_outcome"
        static let taskQuestion = "task_question"
    }

    enum Status {
        static let started = "started"
        static let ok = "ok"
        static let refused = "refused"
        static let delegated = "delegated"
        static let sent = "sent"
        static let cancelled = "cancelled"
        static let nothingRunning = "nothing_running"
        static let question = "question"
        static let error = "error"
    }

    var kind: String?
    var status: String
    var say: String
    var detail: String?
    var options: [String]?

    init(kind: String? = nil, status: String, say: String,
         detail: String? = nil, options: [String]? = nil) {
        self.kind = kind; self.status = status; self.say = say
        self.detail = detail; self.options = options
    }

    func encoded() -> String {
        var parts: [String] = []
        if let kind { parts.append("\"kind\":\(Self.quote(kind))") }
        parts.append("\"status\":\(Self.quote(status))")
        parts.append("\"say\":\(Self.quote(say))")
        if let detail { parts.append("\"detail\":\(Self.quote(detail))") }
        if let options {
            parts.append("\"options\":[\(options.map(Self.quote).joined(separator: ","))]")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String,
              let say = object["say"] as? String else { return nil }
        self.kind = object["kind"] as? String
        self.status = status
        self.say = say
        self.detail = object["detail"] as? String
        self.options = object["options"] as? [String]
    }

    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// The spoken contract, enforced deterministically: dashes become
    /// commas, quotes/brackets drop, terminal punctuation inside the cap.
    static func spoken(_ text: String, words cap: Int) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"[—–‒]"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(^|\s)[-‑](\s|$)"#, with: "$1, $2", options: .regularExpression)
        s = s.replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: #"["“”`()\[\]{}<>#*|]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: ";", with: ",")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.:?!])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",([,.]+)"#, with: "$1", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > cap { words = Array(words.prefix(cap)) }
        s = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
        guard !s.isEmpty else { return s }
        if !s.hasSuffix(".") && !s.hasSuffix("?") && !s.hasSuffix("!") { s += "." }
        return s
    }
}

/// What a committed candidate's actuation is — shared by the dwell
/// engine, the ambiguity radial, and the spoken commit path. File-scope
/// so nonisolated callers (the drive loop's fast lane) can match it.
enum CommittedActuation: Equatable, Sendable {
    /// Host-side AXPress on the frame-matched window's control.
    case trafficLight(WindowControls.Kind, pid: pid_t, frame: CGRect)
    /// The driver's verified element-token click.
    case elementClick(pid: pid_t, windowID: Int, token: String)
    /// Desktop-pixel click at a point — dom/menu/ocr/window kinds.
    case pixelClick(CGPoint)
}
