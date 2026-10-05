import Foundation
import JevVoiceCore
import OSLog

/// Fresh `CuaAgentLoop` per `drive_until` — the loop accumulates per-run
/// state, so the executor is a factory, not a shared instance. The JevUse
/// server asserts consent before this runs, so the loop's internal driver
/// calls stay inside the same turn-armed consent as computer-use tools.
/// The whole drive holds the target's lane lease — the same registry the
/// voice runtime serializes on, so an agent drive and a voice task on one
/// app take turns instead of racing.
@MainActor
final class AgentDriveExecutor: DriveExecuting {
    private let call: CuaTaskAgent.Call
    private let judge: CuaTaskAgent.Judge
    private let agentSlug: String
    /// Resolved per drive — the work id binds the lease to the live turn.
    private let turnID: @MainActor () -> String?
    /// Raw identity → lane key: the task's own spelling, or a resolved app
    /// for a bare pid. Injectable for tests.
    private let leaseIdentity: (DriveTask) async -> String
    private let lanes: any AgentLaneLeasing
    private let progress: @Sendable (String) -> Void

    init(connection: CuaConnection, apiKey: @escaping @Sendable () -> String,
         agentSlug: String,
         turnID: (@MainActor () -> String?)? = nil,
         sessionLabel: (() -> String?)? = nil,
         lanes: any AgentLaneLeasing = CuaLaneRegistry.shared,
         progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.agentSlug = agentSlug
        self.turnID = { turnID?() }
        self.lanes = lanes
        self.progress = progress
        self.call = { name, args in
            var merged = args
            // Resolved per call, not captured at init — the runtime mints a
            // fresh label whenever the transport reconnects (the daemon
            // tombstones dead leases' sessions, so a stale label is worse
            // than none).
            if let label = sessionLabel?() { merged["session"] = .string(label) }
            return try await connection.call(name, arguments: merged)
        }
        self.judge = { state, questions in
            try await JevClient(apiKey: apiKey()).systemOne(state: state, questions: questions)
                .response.answers
        }
        self.leaseIdentity = { task in
            await Self.identity(for: task, agentSlug: agentSlug,
                                connection: connection, sessionLabel: sessionLabel)
        }
    }

    /// Test seam — stubbed loop internals + a recording lane registry.
    init(call: @escaping CuaTaskAgent.Call, judge: @escaping CuaTaskAgent.Judge,
         agentSlug: String, turnID: (@MainActor () -> String?)? = nil,
         leaseIdentity: @escaping (DriveTask) async -> String,
         lanes: any AgentLaneLeasing,
         progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.call = call; self.judge = judge
        self.agentSlug = agentSlug; self.turnID = { turnID?() }
        self.leaseIdentity = leaseIdentity
        self.lanes = lanes; self.progress = progress
    }

    func drive(_ task: DriveTask) async throws -> DriveResult {
        let workID = "agent-\(agentSlug)-\(turnID() ?? UUID().uuidString.prefix(8).lowercased())"
        try await lanes.acquire(app: await leaseIdentity(task), pid: task.pid, workID: workID)
        let loop = CuaAgentLoop(call: call, judge: judge, progress: progress)
        let result: DriveResult
        do { result = try await loop.drive(task) }
        catch {
            await lanes.releaseAll(workID: workID)
            throw error
        }
        await lanes.releaseAll(workID: workID)
        return result
    }

    /// The lease keys on the app the task targets — its own spelling for an
    /// `application` task (the registry normalizes bundle/name aliases), a
    /// `list_apps` resolution for a bare pid, or the agent itself when the
    /// task names no target yet (the loop resolves it mid-run; one agent
    /// still shouldn't run two untargeted drives at once).
    private static func identity(for task: DriveTask, agentSlug: String,
                                 connection: CuaConnection,
                                 sessionLabel: (() -> String?)?) async -> String {
        if let app = task.application, !app.isEmpty { return app }
        if let pid = task.pid {
            var args: [String: JSONValue] = [:]
            if let label = sessionLabel?() { args["session"] = .string(label) }
            if let apps = (try? await connection.call("list_apps", arguments: args))?["apps"]?.array,
               let match = apps.first(where: { $0["pid"]?.integer == pid }) {
                return match["bundle_id"]?.string ?? match["name"]?.string ?? "pid-\(pid)"
            }
            return "pid-\(pid)"
        }
        return "agent-\(agentSlug)"
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
        func remove(_ slug: String) {
            lock.lock(); defer { lock.unlock() }
            entries[slug] = nil
        }
    }

    /// Lock-protected slug → driver transport — the gate's `driverFor`
    /// resolves per call inside tools/list and tools/call handlers, which
    /// run off-actor. Each agent gets its own CuaConnection (its own
    /// embedded daemon): one shared proxy serialized every agent's driver
    /// calls into a single FIFO.
    private final class DriverDirectory: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [String: CuaConnection] = [:]
        func resolve(_ slug: String?) -> CuaConnection? {
            lock.lock(); defer { lock.unlock() }
            return slug.flatMap { connections[$0] }
        }
        func set(_ slug: String, _ connection: CuaConnection) {
            lock.lock(); defer { lock.unlock() }
            connections[slug] = connection
        }
        func remove(_ slug: String) -> CuaConnection? {
            lock.lock(); defer { lock.unlock() }
            return connections.removeValue(forKey: slug)
        }
        func removeAll() -> [CuaConnection] {
            lock.lock(); defer { lock.unlock() }
            let all = Array(connections.values)
            connections.removeAll()
            return all
        }
    }

    /// Lock-protected slug → driver session label. The suggester's `Call`
    /// is explicitly nonisolated @Sendable and the executor's label closure
    /// rides wherever the drive loop suspends, so the lookup cannot live in
    /// MainActor-isolated state — a plain dictionary read off-actor races.
    private final class SessionLabels: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: [String: String] = [:]
        func label(_ slug: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return labels[slug]
        }
        func set(_ slug: String, _ label: String?) {
            lock.lock(); defer { lock.unlock() }
            labels[slug] = label
        }
    }

    private struct Endpoints {
        let cu: LoopbackMCPServer
        let jev: LoopbackMCPServer
    }

    let store: AgentStore
    let bridge: CodexRuntimeBridge
    let scheduler: RoutineScheduler
    /// Exposed for the UI's consent-card bind — approvals still only flow
    /// through resolveConsent so marker asks stay runtime-owned.
    let gate: ComputerUseGate
    /// Minted lazily per agent — the directory above is what the gate reads.
    private let makeConnection: @MainActor () -> CuaConnection
    private let drivers: DriverDirectory
    private let apiKey: @Sendable () -> String
    /// Read at each session mint — the Settings toggle governs agent
    /// cursors the same way it governs the voice session's.
    private let cursorEnabled: () -> Bool
    private let registry = EndpointRegistry()
    private var endpoints: [String: Endpoints] = [:]
    /// Driver session labels minted per transport lease — see
    /// `prepareDriver` for why reuse across connections is refused.
    private let sessionLabels = SessionLabels()
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "agent-runtime")
    private var markerAsks: [ConsentRequest] = []
    /// Marker asks the user approved post-turn — armed onto the agent's next
    /// turnStarted instead of the evicted turn they were asked under.
    private var armNextTurn: [String: ConsentRequest] = [:]
    private var activeTurns: [String: String] = [:]
    private var deltas: [String: String] = [:]
    private var eventTask: Task<Void, Never>?
    /// One connect per agent transport — concurrent sends must not race two
    /// driver spawns into the same connection.
    private var connectTasks: [String: Task<Void, Error>] = [:]
    /// Endpoint materialization is per-slug deduped — a prewarm racing a
    /// delegation must not mint twin loopback servers for one agent.
    private var endpointTasks: [String: Task<Void, Error>] = [:]
    /// Pending asks already announced — the diff that turns a gate-minted
    /// ask into a spoken/pushed one exactly once.
    private var knownPendingIDs: Set<String> = []
    /// Hook installation the first send must await — without it a fast
    /// caller could spawn codex before mcpServersFor exists and bake an
    /// empty tool surface into the agent's config.toml.
    private var hooksTask: Task<Void, Never>?

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

    init(store: AgentStore, bridge: CodexRuntimeBridge,
         makeConnection: @escaping @MainActor () -> CuaConnection,
         apiKey: @escaping @Sendable () -> String,
         cursorEnabled: @escaping () -> Bool = { true }) {
        let fireBox = FireBox()
        let drivers = DriverDirectory()
        self.store = store; self.bridge = bridge
        self.drivers = drivers; self.makeConnection = makeConnection
        self.gate = ComputerUseGate(
            driverFor: { slug in drivers.resolve(slug).map { $0 as any DriverToolCalling } },
            lanes: CuaLaneRegistry.shared)
        self.scheduler = RoutineScheduler(fire: { slug, routine in
            await fireBox.fire?(slug, routine)
        })
        self.apiKey = apiKey
        self.cursorEnabled = cursorEnabled
        fireBox.fire = { [weak self] slug, routine in
            await self?.fireRoutine(slug: slug, routine: routine)
        }
    }

    /// Single-transport wiring — every slug resolves to the one injected
    /// connection. Kept for embedders/tests that own the driver process.
    convenience init(store: AgentStore, bridge: CodexRuntimeBridge, connection: CuaConnection,
                     apiKey: @escaping @Sendable () -> String) {
        self.init(store: store, bridge: bridge, makeConnection: { connection }, apiKey: apiKey)
    }

    /// Wires the per-agent config hooks the bridge reads at spawn. Called
    /// once after construction — the closures stay stable while endpoints
    /// materialize lazily in the registry.
    func start() {
        let registry = self.registry
        hooksTask = Task {
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
        // Agents without live endpoints warm in the background — a routine
        // fire or a delegation must not cold-connect inside its turn.
        for agent in roster where endpoints[agent.slug] == nil {
            warm(agent)
        }
    }

    @discardableResult
    func foundAgent(name: String, role: String, description: String) async throws -> CompanionAgent {
        let agent = try await store.found(name: name, role: role, description: description)
        await refreshRoster()
        return agent
    }

    func removeAgent(_ agent: CompanionAgent) async throws {
        // Cancel in-flight materialization first — a send racing removal
        // must not mint endpoints for a dead agent after teardown.
        endpointTasks[agent.slug]?.cancel()
        connectTasks[agent.slug]?.cancel()
        await bridge.stop(slug: agent.slug)
        try await store.remove(slug: agent.slug)
        // The agent's loopback servers die with it too — a listener left
        // behind keeps its bearer-tokened MCP surface reachable forever.
        if let entry = endpoints.removeValue(forKey: agent.slug) {
            await entry.cu.stop()
            await entry.jev.stop()
        }
        registry.remove(agent.slug)
        // The agent's daemon + tombstoned session die with it — keeping the
        // transport would orphan an embedded driver process per removal.
        if let connection = drivers.remove(agent.slug) { await connection.close() }
        sessionLabels.set(agent.slug, nil)
        // Per-slug turn/consent state dies with the agent — a late event or
        // a resolved ask must not linger in the pending list or arm a turn
        // that can never start.
        activeTurns[agent.slug] = nil
        armNextTurn[agent.slug] = nil
        deltas = deltas.filter { !$0.key.hasPrefix(agent.slug + "\u{1F}") }
        markerAsks.removeAll { $0.agentSlug == agent.slug }
        gate.setActiveTurn(nil, agentSlug: agent.slug)
        refreshPending()
        await refreshRoster()
    }

    /// Cold-start the roster's app-servers + driver transports in the
    /// background so the first delegation doesn't pay codex spawn and the
    /// MCP handshake inside the turn. Strictly best-effort: a failed start
    /// logs and the lazy path retries on first send — never throws, never
    /// blocks launch.
    func prewarm() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.hooksTask?.value
            for agent in await self.store.agents() { self.warm(agent) }
        }
    }

    /// One agent's cold start in the background: endpoint materialization
    /// is per-slug deduped and the bridge shares an in-flight spawn, so a
    /// warm racing a send only ever pays one cold start. Hooks install is
    /// awaited before thread bind — spawn writes config.toml from
    /// mcpServersFor, which must exist first.
    private func warm(_ agent: CompanionAgent) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.ensureEndpoints(for: agent)
                await self.hooksTask?.value
                _ = try await self.bridge.threadID(for: agent)
            } catch {
                Self.log.notice("prewarm \(agent.slug, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Turns

    @discardableResult
    func send(_ text: String, to agent: CompanionAgent) async throws -> String {
        await hooksTask?.value
        try await ensureEndpoints(for: agent)
        let turnID = try await bridge.send(to: agent, message: text)
        // Persist the bound thread so a respawn RESUMES the agent's chat
        // instead of starting a fresh one — the agent's memory is its thread.
        if let threadID = try? await bridge.threadID(for: agent) {
            try? await store.recordThread(slug: agent.slug, threadID: threadID)
        }
        refreshPending()
        return turnID
    }

    /// The agent's workspace + codex home exist before first spawn —
    /// `AgentWorkspace.prepare` is idempotent so re-founding a deleted
    /// workspace repairs it. Serialized per slug: a prewarm racing a send
    /// must share one materialization, not mint twin daemons + endpoints.
    private func ensureEndpoints(for agent: CompanionAgent) async throws {
        if let inFlight = endpointTasks[agent.slug] { return try await inFlight.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.materializeEndpoints(for: agent)
        }
        endpointTasks[agent.slug] = task
        defer { endpointTasks[agent.slug] = nil }
        try await task.value
    }

    private func materializeEndpoints(for agent: CompanionAgent) async throws {
        // Each agent owns its transport — minted lazily, registered before
        // connect so the gate resolves it immediately (calls throw .closed
        // until connected, which codex reads as "MCP server broken" — no
        // client of the loopbacks exists until this whole block finishes,
        // so nothing can call in early).
        let connection: CuaConnection
        if let existing = drivers.resolve(agent.slug) {
            connection = existing
        } else {
            connection = makeConnection()
            drivers.set(agent.slug, connection)
        }
        // The two halves are independent — the gate resolves the driver per
        // call — so the loopback binds run while the proxy negotiates the
        // shared-daemon socket and mints its session. Spawn latency is the
        // slower branch, not their sum.
        async let loopbacks: Void = materializeLoopbacks(for: agent, connection: connection)
        try await prepareDriver(for: agent, connection: connection)
        try await loopbacks
    }

    /// Driver transport + session mint for one agent. Nothing lazily
    /// connects CuaConnection — the gate's tools/list provider throws
    /// .closed until the transport is up, which codex reads as "MCP server
    /// broken" and drops the tool surface entirely. A dead transport also
    /// loses its session lease, so a reconnect must mint a fresh label
    /// rather than reuse the tombstoned one.
    private func prepareDriver(for agent: CompanionAgent, connection: CuaConnection) async throws {
        let reconnected = await !connection.connected
        if reconnected {
            // Concurrent sends (routine fire + delegation) must share one
            // connect — two winners would spawn twin driver processes and
            // corrupt the shared pending/frame state.
            if let inFlight = connectTasks[agent.slug] { try await inFlight.value }
            else {
                let task = Task { try await connection.connect() }
                connectTasks[agent.slug] = task
                defer { connectTasks[agent.slug] = nil }
                try await task.value
            }
            // Every label minted under this dead transport is tombstoned —
            // only this agent's, now that each agent owns its daemon. Nil it
            // so a failed session mint still re-mints on the next attempt.
            sessionLabels.set(agent.slug, nil)
        }
        if reconnected || sessionLabels.label(agent.slug) == nil {
            // The label must be unique per transport: when a proxy lease dies
            // the daemon tombstones its sessions permanently — a later
            // connection reusing the same label gets session_unavailable on
            // start_session and tool_invocation_failed on every call carrying
            // it. A stable label buys nothing anyway: process-ownership and
            // the agent cursor die with the transport either way.
            let label = "agent-" + agent.slug + "-"
                + UUID().uuidString.prefix(8).lowercased()
            // The driver's session owns the visible per-agent cursor: session
            // color + name badge follow every action this agent dispatches.
            // start_session must succeed — a swallowed failure is exactly how
            // the tombstoned-label bug stayed hidden: every subsequent call
            // would carry a label the daemon refuses. Publish the label to
            // the gate + call closures only AFTER the daemon has it — before
            // this point the label does not exist driver-side, so in-flight
            // calls keep their (already-refused) stale label instead of
            // minting calls under an unregistered one.
            _ = try await connection.call("start_session",
                                          arguments: ["session": .string(label)])
            sessionLabels.set(agent.slug, label)
            gate.setSessionLabel(label, agentSlug: agent.slug)
            // The cursor flag is cosmetic, so it stays best-effort.
            _ = try? await connection.call("set_agent_cursor_enabled",
                                           arguments: ["session": .string(label),
                                                       "enabled": .bool(self.cursorEnabled())])
        }
    }

    /// The agent's two loopback MCP endpoints + the config entries codex
    /// reads at spawn. Independent of the driver transport, so the binds
    /// overlap `prepareDriver`.
    private func materializeLoopbacks(for agent: CompanionAgent,
                                      connection: CuaConnection) async throws {
        guard endpoints[agent.slug] == nil else { return }
        let labels = sessionLabels
        let sessionLabel: @Sendable () -> String? = { labels.label(agent.slug) }
        let executor = AgentDriveExecutor(connection: connection, apiKey: apiKey,
                                          agentSlug: agent.slug,
                                          turnID: { [weak self] in
                                              MainActor.assumeIsolated {
                                                  self?.activeTurns[agent.slug]
                                              }
                                          },
                                          sessionLabel: sessionLabel)
        let suggester = AgentActionSuggester(
            call: { name, args in
                var merged = args
                if let label = sessionLabel() { merged["session"] = .string(label) }
                return try await connection.call(name, arguments: merged)
            },
            apiKey: apiKey)
        let jev = JevUseMCPServer(executor: executor, suggester: suggester,
                                  consent: gate, agentSlug: agent.slug)
        let jevServer = jev.server()
        let cuServer = gate.server(agentSlug: agent.slug)
        // Reserve the slot before binding — a removal landing while the
        // listeners come up still finds (and stops) the servers.
        endpoints[agent.slug] = Endpoints(cu: cuServer, jev: jevServer)
        do {
            // Two independent listener binds — run them together.
            async let jevEndpoint = jevServer.start()
            async let cuEndpoint = cuServer.start()
            let (jev, cu) = try await (jevEndpoint, cuEndpoint)
            // The agent may have been removed while the binds were in
            // flight — minted endpoints must not outlive it.
            guard await store.agent(slug: agent.slug) != nil else {
                throw CancellationError()
            }
            let cuVar = "JEV_MCP_CU_TOKEN_" + Self.envToken(agent.slug)
            let jevVar = "JEV_MCP_JEV_TOKEN_" + Self.envToken(agent.slug)
            registry.set(agent.slug,
                         mcp: [CodexMCPServer(name: "computer-use", url: cu.url.absoluteString,
                                              bearerTokenEnvVar: cuVar),
                               CodexMCPServer(name: "jev-use", url: jev.url.absoluteString,
                                              bearerTokenEnvVar: jevVar)],
                         env: [cuVar: cu.token, jevVar: jev.token])
        } catch {
            endpoints[agent.slug] = nil
            await jevServer.stop()
            await cuServer.stop()
            throw error
        }
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
        // Events buffered before removal can land after teardown — a dead
        // agent keeps its bookkeeping (turn/lease cleanup) but gets no user
        // surface: no asks, no replies.
        let alive = roster.contains { $0.slug == slug }
        switch event.event {
        case .turnStarted(_, let turnID):
            activeTurns[slug] = turnID
            gate.setActiveTurn(turnID, agentSlug: slug)
            if let armed = armNextTurn.removeValue(forKey: slug) {
                gate.approve(ConsentRequest(agentSlug: slug, turnID: turnID,
                                            summary: armed.summary, reason: armed.reason,
                                            state: .approved))
            }
        case .turnCompleted(_, let turn):
            activeTurns[slug] = nil
            // A turn can fail with the error ONLY in turn/completed — no
            // preceding .error notification. Without this the user hears
            // "on it" and then silence forever.
            if turn.status == "failed", alive {
                onAgentReply?(slug, "Error: " + (turn.errorMessage ?? "the agent's turn failed"))
            }
            // A mid-turn consent refusal dies with its turn (setActiveTurn
            // evicts it) — but the user still needs the ask AFTER the agent
            // stops. Preserve it as a roster-level ask: resolving it arms
            // the agent's NEXT turn, the same path an emitted
            // <COMPUTER_USE_REQUEST> marker takes. Model compliance with the
            // marker is a nicety, not the load-bearing mechanism. An agent
            // off the roster gets no surface — its asks die with it.
            for ask in gate.pending() where ask.agentSlug == slug && alive {
                let preserved = ConsentRequest(id: ask.id, agentSlug: slug,
                                               turnID: nil, summary: ask.summary,
                                               reason: ask.reason, state: .pending)
                if !markerAsks.contains(where: { $0.id == preserved.id }) {
                    markerAsks.append(preserved)
                    onConsentAsk?(preserved)
                }
            }
            gate.setActiveTurn(nil, agentSlug: slug)
        case .agentMessageDelta(_, _, let itemID, let delta):
            deltas[slug + "\u{1F}" + itemID, default: ""] += delta
        case .itemCompleted(_, _, let item):
            if let text = Self.agentMessageText(item) { completeMessage(slug: slug, text: text) }
        case .error(let message, let willRetry, _, _) where !willRetry && alive:
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
    /// surface the clean reply. Buffered events can arrive after the agent
    /// was removed — nothing it says should mint asks, routines, or a
    /// spoken reply for a dead agent.
    private func completeMessage(slug: String, text: String) {
        guard roster.contains(where: { $0.slug == slug }) else { return }
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
            // Ask storms: a retrying agent re-emits the identical marker
            // every turn — the pending (or already-armed) ask IS the ask,
            // not a new card and another spoken prompt.
            guard !markerAsks.contains(where: { $0.agentSlug == slug && $0.summary == ask }),
                  armNextTurn[slug]?.summary != ask else { continue }
            markerAsks.append(ConsentRequest(agentSlug: slug, turnID: nil,
                                             summary: ask,
                                             reason: "The agent asked to use computer input."))
        }
        // Newly pending ids announce here — a direct onConsentAsk call
        // would speak every marker ask twice.
        refreshPending()
    }

    private func refreshPending() {
        var merged = gate.pending()
        let gateIDs = Set(merged.map(\.id))
        merged += markerAsks.filter { !gateIDs.contains($0.id) }
        pendingAsks = merged
        // A gate-minted ask (mid-turn tool refusal) never raised onConsentAsk
        // — it used to sit silent until the agent bothered to emit its
        // marker, stalling the whole turn with no user signal. Any newly
        // pending id announces once, whichever source minted it.
        for ask in merged where !knownPendingIDs.contains(ask.id) {
            onConsentAsk?(ask)
        }
        knownPendingIDs = Set(merged.map(\.id))
    }

    /// Pending ask for the companion's bare-yes path — the NEWEST live ask
    /// resolves (a mid-turn gate ask plus its marker echo is one logical
    /// ask; answering the newest resolves what the user was just asked).
    var solePendingAsk: ConsentRequest? {
        pendingAsks.last
    }

    // MARK: Cursor identity

    func cursor(for slug: String) -> AgentCursor {
        AgentCursor(agentSlug: slug, label: roster.first { $0.slug == slug }?.name ?? slug,
                    colorHex: AgentCursor.palette(for: slug))
    }

    // MARK: Shutdown

    /// Actually awaited on quit — fire-and-forget teardown used to reply
    /// `terminate` while `codex app-server` children were still spawning,
    /// leaving orphaned processes holding CODEX_HOME and loopback ports.
    func stopAll() async {
        eventTask?.cancel()
        await bridge.stopAll()
        await scheduler.stopAll()
        for endpoint in endpoints.values {
            await endpoint.cu.stop()
            await endpoint.jev.stop()
        }
        endpoints.removeAll()
        registry.clear()
        for connection in drivers.removeAll() { await connection.close() }
    }
}
