import Foundation
import JevVoiceCore

/// Fresh `CuaAgentLoop` per `drive_until` — the loop accumulates per-run
/// state, so the executor is a factory, not a shared instance. The JevUse
/// server asserts consent before this runs, so the loop's internal driver
/// calls stay inside the same turn-armed consent as computer-use tools.
@MainActor
final class AgentDriveExecutor: DriveExecuting {
    private let connection: CuaConnection
    private let apiKey: @Sendable () -> String
    private let progress: @Sendable (String) -> Void

    init(connection: CuaConnection, apiKey: @escaping @Sendable () -> String,
         progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.connection = connection; self.apiKey = apiKey; self.progress = progress
    }

    func drive(_ task: DriveTask) async throws -> DriveResult {
        let connection = self.connection, apiKey = self.apiKey
        let loop = CuaAgentLoop(
            call: { name, args in try await connection.call(name, arguments: args) },
            judge: { state, questions in
                try await JevClient(apiKey: apiKey()).systemOne(state: state, questions: questions)
                    .response.answers
            },
            progress: progress)
        return try await loop.drive(task)
    }
}

/// The Clicky-parity composition root: persistent named agents backed by
/// vendored codex app-servers, each with isolated CODEX_HOME + workspace +
/// its own loopback MCP endpoints (computer-use through the consent gate,
/// jev-use through the drive loop). One approval arms an (agent, turn) pair
/// across both tool surfaces; a marker ask approved post-turn arms the
/// agent's NEXT turn — never another agent's.
@MainActor
final class AgentRuntime: ObservableObject {
    /// Lock-protected view of live endpoints for the bridge's spawn-time
    /// `mcpServersFor`/`environmentFor` closures, which run off-actor.
    private final class EndpointRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (mcp: [CodexMCPServer], env: [String: String])] = [:]
        func set(_ slug: String, mcp: [CodexMCPServer], env: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            entries[slug] = (mcp, env)
        }
        func mcp(_ slug: String) -> [CodexMCPServer] {
            lock.lock(); defer { lock.unlock() }
            return entries[slug]?.mcp ?? []
        }
        func env(_ slug: String) -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            return entries[slug]?.env ?? [:]
        }
        func clear() { lock.lock(); entries.removeAll(); lock.unlock() }
    }

    private struct Endpoints {
        let cu: LoopbackMCPServer
        let jev: LoopbackMCPServer
    }

    let store: AgentStore
    let bridge: CodexRuntimeBridge
    let scheduler: RoutineScheduler
    private let gate: ComputerUseGate
    private let connection: CuaConnection
    private let executor: AgentDriveExecutor
    private let registry = EndpointRegistry()
    private var endpoints: [String: Endpoints] = [:]
    private var markerAsks: [ConsentRequest] = []
    /// Marker asks the user approved post-turn — armed onto the agent's next
    /// turnStarted instead of the evicted turn they were asked under.
    private var armNextTurn: [String: ConsentRequest] = [:]
    private var activeTurns: [String: String] = [:]
    private var deltas: [String: String] = [:]
    private var eventTask: Task<Void, Never>?

    @Published private(set) var roster: [CompanionAgent] = []
    /// Gate refusal asks + agent marker asks — the single pending one is what
    /// a bare voice "yes"/"no" or a consent card resolves.
    @Published private(set) var pendingAsks: [ConsentRequest] = []

    /// Surfaces for the voice/UI layer — consent asks get spoken, clean
    /// replies get shown and spoken, events feed the chat stream.
    var onConsentAsk: ((ConsentRequest) -> Void)?
    var onAgentReply: ((String, String) -> Void)?
    var onAgentEvent: ((AgentCodexEvent) -> Void)?

    /// The scheduler's fire closure needs the runtime before the runtime
    /// exists — a late-bound box breaks the init cycle.
    private final class FireBox: @unchecked Sendable {
        var fire: ((String, Routine) async -> Void)?
    }

    init(store: AgentStore, bridge: CodexRuntimeBridge, connection: CuaConnection,
         apiKey: @escaping @Sendable () -> String) {
        let fireBox = FireBox()
        self.store = store; self.bridge = bridge; self.connection = connection
        self.gate = ComputerUseGate(driver: connection)
        self.scheduler = RoutineScheduler(fire: { slug, routine in
            await fireBox.fire?(slug, routine)
        })
        executor = AgentDriveExecutor(connection: connection, apiKey: apiKey,
                                      progress: { _ in })
        fireBox.fire = { [weak self] slug, routine in
            await self?.fireRoutine(slug: slug, routine: routine)
        }
    }

    /// Wires the per-agent config hooks the bridge reads at spawn. Called
    /// once after construction — the closures stay stable while endpoints
    /// materialize lazily in the registry.
    func start() {
        let registry = self.registry
        Task {
            await bridge.installHooks(mcpServersFor: { agent in registry.mcp(agent.slug) },
                                      environmentFor: { agent in registry.env(agent.slug) })
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
        await refreshRoster()
    }

    // MARK: Turns

    func send(_ text: String, to agent: CompanionAgent) async throws {
        try await ensureEndpoints(for: agent)
        try await bridge.send(to: agent, message: text)
        refreshPending()
    }

    /// The agent's workspace + codex home exist before first spawn —
    /// `AgentWorkspace.prepare` is idempotent so re-founding a deleted
    /// workspace repairs it.
    private func ensureEndpoints(for agent: CompanionAgent) async throws {
        guard endpoints[agent.slug] == nil else { return }
        let jev = JevUseMCPServer(executor: executor, consent: gate, agentSlug: agent.slug)
        let jevServer = jev.server()
        let cuServer = gate.server(agentSlug: agent.slug)
        let jevEndpoint = try await jevServer.start()
        let cuEndpoint = try await cuServer.start()
        endpoints[agent.slug] = Endpoints(cu: cuServer, jev: jevServer)
        let cuVar = "JEV_MCP_CU_TOKEN_" + Self.envToken(agent.slug)
        let jevVar = "JEV_MCP_JEV_TOKEN_" + Self.envToken(agent.slug)
        registry.set(agent.slug,
                     mcp: [CodexMCPServer(name: "computer-use", url: cuEndpoint.url.absoluteString,
                                          bearerTokenEnvVar: cuVar),
                           CodexMCPServer(name: "jev-use", url: jevEndpoint.url.absoluteString,
                                          bearerTokenEnvVar: jevVar)],
                     env: [cuVar: cuEndpoint.token, jevVar: jevEndpoint.token])
    }

    private static func envToken(_ slug: String) -> String {
        String(slug.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private func fireRoutine(slug: String, routine: Routine) async {
        guard let agent = await store.agent(slug: slug) else { return }
        do { try await send(routine.task, to: agent) }
        catch { /* surfaced through the agent's event stream */ }
    }

    // MARK: Events → consent + markers

    private func handle(_ event: AgentCodexEvent) {
        let slug = event.agentSlug
        switch event.event {
        case .turnStarted(_, let turnID):
            activeTurns[slug] = turnID
            gate.setActiveTurn(turnID, agentSlug: slug)
            if let armed = armNextTurn.removeValue(forKey: slug) {
                gate.approve(ConsentRequest(agentSlug: slug, turnID: turnID,
                                            summary: armed.summary, reason: armed.reason,
                                            state: .approved))
            }
        case .turnCompleted:
            activeTurns[slug] = nil
            gate.setActiveTurn(nil, agentSlug: slug)
        case .agentMessageDelta(_, _, let itemID, let delta):
            deltas[slug + "\u{1F}" + itemID, default: ""] += delta
        case .itemCompleted(_, _, let item):
            if let text = Self.agentMessageText(item) { completeMessage(slug: slug, text: text) }
        case .error(let message, let willRetry, _, _) where !willRetry:
            onAgentReply?(slug, "Error: " + message)
        default: break
        }
        refreshPending()
        onAgentEvent?(event)
    }

    private static func agentMessageText(_ item: JSONValue) -> String? {
        guard item["type"]?.string == "agentMessage" else { return nil }
        if let text = item["text"]?.string { return text }
        return item["content"]?.array?
            .compactMap { $0["text"]?.string }.joined()
    }

    /// Final agent text: strip markers, register routine + consent markers,
    /// surface the clean reply.
    private func completeMessage(slug: String, text: String) {
        addMarkerAsks(slug: slug, text: text)
        let markers = AgentMarkers.routines(in: text)
        if !markers.isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                for marker in markers {
                    switch marker.action {
                    case "create":
                        guard let every = marker.everyMinutes, let task = marker.task,
                              !task.isEmpty else { continue }
                        let routine = Routine(id: marker.routineID ?? UUID().uuidString,
                                              everyMinutes: every, task: task, enabled: true)
                        try? await self.store.setRoutine(slug: slug, routine: routine)
                    case "pause", "resume":
                        guard let id = marker.routineID,
                              let agent = await self.store.agent(slug: slug),
                              var routine = agent.routines.first(where: { $0.id == id }) else { continue }
                        routine.enabled = marker.action == "resume"
                        try? await self.store.setRoutine(slug: slug, routine: routine)
                    case "delete":
                        guard let id = marker.routineID else { continue }
                        try? await self.store.removeRoutine(slug: slug, routineID: id)
                    default: continue
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

    // MARK: Consent

    func pending() -> [ConsentRequest] {
        pendingAsks
    }

    /// Voice "yes"/"no" and consent cards resolve through here. Gate asks arm
    /// the live (agent, turn); marker asks arm the agent's next turn.
    func resolveConsent(_ request: ConsentRequest, approved: Bool) {
        if markerAsks.contains(where: { $0.id == request.id }) {
            markerAsks.removeAll { $0.id == request.id }
            if approved, let slug = request.agentSlug {
                armNextTurn[slug] = ConsentRequest(id: request.id, agentSlug: slug,
                                                 turnID: nil, summary: request.summary,
                                                 reason: request.reason, state: .approved)
            }
        } else {
            if approved { gate.approve(request) } else { gate.deny(request) }
        }
        refreshPending()
    }

    private func addMarkerAsks(slug: String, text: String) {
        for ask in AgentMarkers.computerUseRequests(in: text) {
            let request = ConsentRequest(agentSlug: slug, turnID: nil,
                                         summary: ask,
                                         reason: "The agent asked to use computer input.")
            markerAsks.append(request)
            onConsentAsk?(request)
        }
        refreshPending()
    }

    private func refreshPending() {
        var merged = gate.pending()
        let gateIDs = Set(merged.map(\.id))
        merged += markerAsks.filter { !gateIDs.contains($0.id) }
        pendingAsks = merged
    }

    /// Pending ask for the companion's bare-yes path — exactly one live ask
    /// resolves; more than one needs an explicit card choice.
    var solePendingAsk: ConsentRequest? {
        pendingAsks.count == 1 ? pendingAsks[0] : nil
    }

    // MARK: Cursor identity

    func cursor(for slug: String) -> AgentCursor {
        AgentCursor(agentSlug: slug, label: roster.first { $0.slug == slug }?.name ?? slug,
                    colorHex: AgentCursor.palette(for: slug))
    }

    // MARK: Shutdown

    func stopAll() {
        eventTask?.cancel()
        Task { await bridge.stopAll() }
        Task { await scheduler.stopAll() }
        registry.clear()
    }
}
