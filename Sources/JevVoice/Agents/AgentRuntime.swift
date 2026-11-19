import Foundation
import JevVoiceCore
import OSLog

/// Persistent named agents backed by vendored codex app-servers — each with
/// isolated CODEX_HOME + workspace. Consent lives in `CuaPolicy` (the
/// standing grant agents' stdio MCP server reads); there are no per-turn
/// asks, no loopback servers, no per-agent driver transports here.
@MainActor
final class AgentRuntime: ObservableObject {
    let store: AgentStore
    let bridge: CodexRuntimeBridge
    let scheduler: RoutineScheduler
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice",
                                    category: "agent-runtime")

    /// Turn ids in flight per slug — a Set because a chat send and a
    /// routine tick can overlap on one thread, and last-write-wins used
    /// to leave the older turn uninterruptible.
    private(set) var activeTurns: [String: Set<String>] = [:]
    /// Sends between call and turn id (spawn + startTurn still resolving)
    /// — a routine tick must not stack a turn beside one being created.
    private var pendingSends: [String: Int] = [:]
    private var eventTask: Task<Void, Never>?
    /// Hook installation the first send must await — spawn writes
    /// config.toml from these closures, so they must exist first.
    private var hooksTask: Task<Void, Never>?
    /// Set by stopAll — a late send resuming past teardown fails fast.
    private var stopped = false

    @Published private(set) var roster: [CompanionAgent] = []

    /// Surfaces for the voice/UI layer — clean replies get shown and
    /// spoken, events feed the chat stream.
    var onAgentReply: ((String, String) -> Void)?
    var onAgentEvent: ((AgentCodexEvent) -> Void)?

    /// The scheduler's fire closure needs the runtime before the runtime
    /// exists — a late-bound box breaks the init cycle.
    private final class FireBox: @unchecked Sendable {
        var fire: ((String, Routine) async -> Void)?
    }

    init(store: AgentStore, bridge: CodexRuntimeBridge) {
        let fireBox = FireBox()
        self.store = store; self.bridge = bridge
        self.scheduler = RoutineScheduler(fire: { slug, routine in
            await fireBox.fire?(slug, routine)
        })
        fireBox.fire = { [weak self] slug, routine in
            await self?.fireRoutine(slug: slug, routine: routine)
        }
    }

    /// Wires the per-agent config hooks the bridge reads at spawn. The MCP
    /// server entries come from `CuaDriveServer` config (stdio mode) — see
    /// `CuaDriveServers.config(for:)`; environment carries TYPESAFE_API_KEY
    /// so no key lands in a config file.
    func start(mcpServersFor: @escaping @Sendable (CompanionAgent) -> [CodexMCPServer] = { _ in [] },
               environmentFor: @escaping @Sendable (CompanionAgent) -> [String: String] = { _ in [:] }) {
        hooksTask = Task {
            await bridge.installHooks(mcpServersFor: mcpServersFor,
                                      environmentFor: environmentFor)
        }
        Task { @MainActor [weak self] in await self?.refreshRoster() }
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.bridge.events {
                self.handle(event)
            }
        }
    }

    // MARK: Roster

    func refreshRoster() async {
        roster = await store.agents()
        await scheduler.sync(agents: roster)
    }

    @discardableResult
    func foundAgent(name: String, role: String, description: String) async throws -> CompanionAgent {
        let agent = try await store.found(name: name, role: role, description: description)
        await refreshRoster()
        return agent
    }

    func removeAgent(_ agent: CompanionAgent) async throws {
        await bridge.stop(slug: agent.slug)
        try await store.remove(slug: agent.slug)
        // Per-slug turn state dies with the agent — a late event must not
        // linger on a turn that can never complete.
        activeTurns[agent.slug] = nil
        pendingSends[agent.slug] = nil
        await refreshRoster()
    }

    // MARK: Turns

    @discardableResult
    func send(_ text: String, to agent: CompanionAgent) async throws -> String {
        try await sendBound(text, to: agent).turn
    }

    func sendBound(_ text: String, to agent: CompanionAgent) async throws -> WorkerTurnReceipt {
        await hooksTask?.value
        // An in-flight send resuming past stopAll's drain must not spawn a
        // session the teardown already walked past.
        guard !stopped else { throw CancellationError() }
        // Mark the slug busy across the spawn/startTurn window so a routine
        // tick can't stack a second turn beside one still being created.
        // activeTurns itself stays event-sourced: inserting the fresh id
        // here could re-add a turn whose turn/completed was already
        // processed while this send was suspended.
        pendingSends[agent.slug, default: 0] += 1
        defer {
            pendingSends[agent.slug, default: 1] -= 1
            if pendingSends[agent.slug] == 0 { pendingSends.removeValue(forKey: agent.slug) }
        }
        let receipt = try await bridge.sendBound(to: agent, message: text)
        // Persist the bound thread so a respawn RESUMES the agent's chat
        // instead of starting a fresh one — the agent's memory is its thread.
        do {
            try await store.recordThread(slug: agent.slug, threadID: receipt.thread)
        } catch {
            Self.log.error("thread persistence failed for \(agent.slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return receipt
    }

    /// Slugs with a turn in flight or a send still binding one — the
    /// no-hint voice "stop" resolves against this set, never roster order.
    var activeTurnSlugs: Set<String> {
        Set(activeTurns.filter { !$0.value.isEmpty }.keys).union(pendingSends.keys)
    }

    /// Interrupts the agent's most recent in-flight turn. False when no
    /// turn is live — the caller speaks that instead of claiming a stop.
    @discardableResult
    func interrupt(slug: String) async throws -> Bool {
        try await bridge.interrupt(slug: slug)
    }

    private func fireRoutine(slug: String, routine: Routine) async {
        guard let agent = await store.agent(slug: slug) else { return }
        // A tick landing mid-turn would stack a second turn on the thread —
        // skip honestly and let the next tick catch up.
        guard !activeTurnSlugs.contains(slug) else {
            Self.log.notice("routine \(routine.id, privacy: .public) tick skipped — \(slug, privacy: .public) has a turn in flight")
            return
        }
        do { try await send(routine.task, to: agent) }
        // A thrown send emits no events — the routine fire fails silently
        // without this line.
        catch { Self.log.error("routine send failed for \(slug, privacy: .public): \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Events → markers

    private func handle(_ event: AgentCodexEvent) {
        let slug = event.agentSlug
        // Events buffered before removal can land after teardown — a dead
        // agent keeps bookkeeping but gets no user surface.
        let alive = roster.contains { $0.slug == slug }
        switch event.event {
        case .turnStarted(_, let turnID):
            activeTurns[slug, default: []].insert(turnID)
        case .turnCompleted(_, let turn):
            activeTurns[slug]?.remove(turn.id)
            if activeTurns[slug]?.isEmpty == true { activeTurns[slug] = nil }
            // A turn can fail with the error ONLY in turn/completed — no
            // preceding .error notification. Without this the user hears
            // "on it" and then silence forever.
            if turn.status == "failed", alive {
                onAgentReply?(slug, "Error: " + (turn.errorMessage ?? "the agent's turn failed"))
            }
        case .itemCompleted(_, _, let item):
            if let text = Self.agentMessageText(item) { completeMessage(slug: slug, text: text) }
        case .error(let message, let willRetry, _, _) where !willRetry && alive:
            onAgentReply?(slug, "Error: " + message)
        default: break
        }
        onAgentEvent?(event)
    }

    private static func agentMessageText(_ item: JSONValue) -> String? {
        guard item["type"]?.string == "agentMessage" else { return nil }
        if let text = item["text"]?.string { return text }
        return item["content"]?.array?
            .compactMap { $0["text"]?.string }.joined()
    }

    /// Final agent text: strip markers, register routine markers, surface
    /// the clean reply. Buffered events can arrive after the agent was
    /// removed — nothing it says should mint routines or a spoken reply.
    private func completeMessage(slug: String, text: String) {
        guard roster.contains(where: { $0.slug == slug }) else { return }
        let markers = AgentMarkers.routines(in: text)
        if !markers.isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                for marker in markers {
                    if case .refused(let reason) = await self.applyRoutineMarker(marker, slug: slug) {
                        Self.log.warning("routine marker refused for \(slug, privacy: .public): \(reason, privacy: .public)")
                        self.onAgentReply?(slug, reason)
                    }
                }
                await self.refreshRoster()
            }
        }
        let clean = AgentMarkers.strippingMarkers(text)
        if !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onAgentReply?(slug, clean)
        }
    }

    /// What became of one decoded `<ROUTINE>` marker.
    enum RoutineMarkerOutcome: Equatable {
        case applied
        /// The marker asked for something we won't do — the reason is
        /// surfaced as an agent reply so the refusal isn't silent.
        case refused(String)
        /// Malformed or no-op — nothing persisted, nothing to say.
        case ignored
    }

    /// Applies one routine marker to the store. The cadence floor refuses
    /// at CREATION — the scheduler would skip a sub-2-minute routine
    /// silently, so the honest refusal has to land here.
    @discardableResult
    func applyRoutineMarker(_ marker: AgentMarkers.RoutineMarker, slug: String) async -> RoutineMarkerOutcome {
        switch marker.action {
        case "create":
            guard let every = marker.everyMinutes, let task = marker.task,
                  !task.isEmpty else { return .ignored }
            guard every >= RoutineScheduler.minimumEveryMinutes else {
                return .refused("I couldn't schedule that — routines can repeat at most every \(RoutineScheduler.minimumEveryMinutes) minutes.")
            }
            let routine = Routine(id: marker.routineID ?? UUID().uuidString,
                                  everyMinutes: every, task: task, enabled: true)
            do { try await store.setRoutine(slug: slug, routine: routine) }
            catch {
                Self.log.error("routine persistence failed for \(slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .refused("I couldn't save that routine.")
            }
        case "pause", "resume":
            guard let id = marker.routineID,
                  let agent = await store.agent(slug: slug),
                  var routine = agent.routines.first(where: { $0.id == id }) else { return .ignored }
            routine.enabled = marker.action == "resume"
            do { try await store.setRoutine(slug: slug, routine: routine) }
            catch {
                Self.log.error("routine persistence failed for \(slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .refused("I couldn't update that routine.")
            }
        case "delete":
            guard let id = marker.routineID else { return .ignored }
            do { try await store.removeRoutine(slug: slug, routineID: id) }
            catch { Self.log.error("routine removal failed for \(slug, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        default:
            return .ignored
        }
        return .applied
    }

    // MARK: Cursor identity

    func cursor(for slug: String) -> AgentCursor {
        AgentCursor(agentSlug: slug, label: roster.first { $0.slug == slug }?.name ?? slug,
                    colorHex: AgentCursor.palette(for: slug))
    }

    // MARK: Shutdown

    /// Actually awaited on quit — fire-and-forget teardown used to reply
    /// `terminate` while `codex app-server` children were still spawning.
    func stopAll() async {
        stopped = true
        eventTask?.cancel()
        // Stop routine fires first so no new sends arrive mid-teardown.
        await scheduler.stopAll()
        hooksTask?.cancel()
        await bridge.stopAll()
    }
}
