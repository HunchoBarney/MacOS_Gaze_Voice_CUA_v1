import Foundation
import JevVoiceCore
import OSLog

/// Custom OpenAI-compatible provider written into the agent's config.toml.
/// `envKey` names the environment variable codex reads the API key from —
/// the key itself is only ever placed in the child process environment.
/// `usesSystemAuth` means codex's builtin provider authenticates through the
/// user's own `~/.codex/auth.json` (ChatGPT login) symlinked into the agent's
/// CODEX_HOME — no custom provider table is emitted at all.
public struct CodexModelProvider: Sendable, Equatable {
    public var name: String
    public var baseURL: String
    /// Observed values: "responses", "chat".
    public var wireAPI: String
    public var envKey: String
    public var model: String
    /// True → use the machine's existing codex auth (auth.json); the config
    /// writes only model/approval/sandbox, no provider override.
    public var usesSystemAuth: Bool
    public init(name: String, baseURL: String, wireAPI: String = "responses",
                envKey: String, model: String) {
        self.name = name; self.baseURL = baseURL; self.wireAPI = wireAPI
        self.envKey = envKey; self.model = model
        self.usesSystemAuth = false
    }
    /// The user's own codex login — auth.json is symlinked into the agent's
    /// CODEX_HOME at spawn. `model` may be empty → codex's account default.
    public static func chatGPT(model: String = "") -> CodexModelProvider {
        CodexModelProvider(name: "openai", baseURL: "https://api.openai.com/v1",
                           envKey: "", model: model).withSystemAuth()
    }
    private func withSystemAuth() -> CodexModelProvider {
        var copy = self; copy.usesSystemAuth = true; return copy
    }
}

/// A stdio MCP server entry for config.toml (`[mcp_servers.<name>]`). The
/// agent's codex spawns `command args` per session; `envVars` names codex
/// forwards from its own environment to the child — so a key rides the
/// process tree and never lands in a file.
/// `default_tools_approval_mode = "approve"` is emitted for every server:
/// these are our own surfaces and CuaPolicy IS the consent
/// layer — codex's per-call gate would auto-refuse everything under
/// `approval_policy = "never"` (openai/codex#24135).
public struct CodexMCPServer: Sendable, Equatable {
    public var name: String
    public var command: String
    public var args: [String]
    public var envVars: [String]
    public var cwd: String?
    public init(name: String, command: String, args: [String] = [],
                envVars: [String] = [], cwd: String? = nil) {
        self.name = name; self.command = command; self.args = args
        self.envVars = envVars; self.cwd = cwd
    }
}

/// One app-server event tagged with the agent that produced it.
public struct AgentCodexEvent: Sendable {
    public var agentSlug: String
    public var event: CodexEvent
    public init(agentSlug: String, event: CodexEvent) {
        self.agentSlug = agentSlug; self.event = event
    }
}

/// Owns one `codex app-server` process per CompanionAgent, each with an
/// isolated CODEX_HOME under the agent's workspace (Clicky parity). Writes
/// config.toml on spawn; secrets arrive via `Configuration.environment` and
/// reach codex only through process env — nothing secret touches disk.
public actor CodexRuntimeBridge {
    public struct Configuration: Sendable {
        public var codexBinary: URL
        public var provider: CodexModelProvider
        public var mcpServers: [CodexMCPServer]
        /// Extra child-process env — API key under `provider.envKey`,
        /// plus any keys a stdio MCP server picks up via `env_vars`.
        public var environment: [String: String]
        /// Per-agent overrides — each agent gets its own stdio MCP server
        /// spec (same binary, different --agent slug). Nil keeps the
        /// shared `mcpServers`/`environment` behavior.
        public var mcpServersFor: (@Sendable (CompanionAgent) -> [CodexMCPServer])?
        public var environmentFor: (@Sendable (CompanionAgent) -> [String: String])?
        public var onStderrLine: (@Sendable (String) -> Void)?
        public init(codexBinary: URL, provider: CodexModelProvider,
                    mcpServers: [CodexMCPServer] = [],
                    environment: [String: String] = [:],
                    mcpServersFor: (@Sendable (CompanionAgent) -> [CodexMCPServer])? = nil,
                    environmentFor: (@Sendable (CompanionAgent) -> [String: String])? = nil,
                    onStderrLine: (@Sendable (String) -> Void)? = nil) {
            self.codexBinary = codexBinary; self.provider = provider
            self.mcpServers = mcpServers; self.environment = environment
            self.mcpServersFor = mcpServersFor; self.environmentFor = environmentFor
            self.onStderrLine = onStderrLine
        }
    }

    private struct Session {
        var client: CodexProtocolClient
        var threadID: String
        /// Turn ids accepted by turn/start and not yet finished — ordered,
        /// most recent last. Concurrent sends (chat + a routine tick)
        /// share the thread, so a single last-write-wins id used to leave
        /// every earlier turn uninterruptible.
        var activeTurnIDs: [String] = []
        /// Recently finished turn ids — `turn/completed` can land before
        /// `send` writes the id back, so a bare "still listed" check can't
        /// catch the finish and it would latch as in-flight forever.
        /// Bounded: oldest entries fall out.
        var completedTurns: [String] = []
        var forwarder: Task<Void, Never>
    }

    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice",
                                    category: "codex-bridge")

    private var configuration: Configuration
    private var sessions: [String: Session] = [:]
    /// Cold starts in flight — a second send for the same slug awaits the
    /// first's spawn instead of binding a second app-server to the same
    /// CODEX_HOME/thread.
    private var starting: [String: Task<Session, Error>] = [:]
    public nonisolated let events: AsyncStream<AgentCodexEvent>
    private let eventContinuation: AsyncStream<AgentCodexEvent>.Continuation

    public init(configuration: Configuration) {
        self.configuration = configuration
        var continuation: AsyncStream<AgentCodexEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    /// Per-agent MCP/env providers — installed by the coordinator once
    /// endpoints can be minted lazily. Must land before the first spawn;
    /// already-running sessions keep the config they spawned with.
    public func installHooks(mcpServersFor: (@Sendable (CompanionAgent) -> [CodexMCPServer])?,
                             environmentFor: (@Sendable (CompanionAgent) -> [String: String])?) {
        configuration.mcpServersFor = mcpServersFor
        configuration.environmentFor = environmentFor
    }

    /// In-flight spawns retain the bridge, so a deinit means only registered
    /// sessions can still be live — cancel forwarders and terminate children.
    /// App quit should still call `stopAll()` for deterministic teardown.
    deinit {
        for session in sessions.values {
            session.forwarder.cancel()
            let client = session.client
            Task { await client.close() }
        }
        eventContinuation.finish()
    }

    /// Lazily spawns (or reuses) the agent's app-server and returns its live
    /// thread id. Resumes the agent's last thread when possible, falls back
    /// to a fresh thread — the caller should persist a new id via AgentStore.
    @discardableResult
    public func threadID(for agent: CompanionAgent) async throws -> String {
        try await session(for: agent).threadID
    }

    /// Starts a turn on the agent's thread. Returns the new turn id; stream
    /// the reply from `events` filtered on `agentSlug`.
    @discardableResult
    public func send(to agent: CompanionAgent, message: String) async throws -> String {
        let session = try await self.session(for: agent)
        let turnID = try await session.client.startTurn(threadID: session.threadID, text: message)
        // Write back only while this is still the registered session — a
        // concurrent sessionEnded/stop must not be resurrected. Consult
        // the registered session's completed-turn ledger too:
        // turn/completed landing between startTurn and this write-back
        // means the turn already finished — latching it in-flight would
        // let a later interrupt fire at a dead turn.
        if sessions[agent.slug]?.client === session.client,
           sessions[agent.slug]?.completedTurns.contains(turnID) != true {
            sessions[agent.slug]?.activeTurnIDs.append(turnID)
        }
        return turnID
    }

    /// Interrupts the agent's most recent in-flight turn. Returns false —
    /// instead of silently no-opping — when the agent has no live turn, so
    /// the caller can answer "nothing is running" honestly.
    @discardableResult
    public func interrupt(slug: String) async throws -> Bool {
        guard let session = sessions[slug], let turnID = session.activeTurnIDs.last else {
            return false
        }
        try await session.client.interruptTurn(threadID: session.threadID, turnID: turnID)
        // The interrupt is accepted — turn/completed (status "interrupted")
        // closes the ledger on the forwarder, but drop the id now so a
        // second stop doesn't aim at an already-dying turn.
        sessions[slug]?.activeTurnIDs.removeAll { $0 == turnID }
        return true
    }

    /// Slugs with at least one in-flight turn — the only honest target set
    /// for a no-hint "stop".
    public func activeTurnSlugs() -> [String] {
        sessions.filter { !$0.value.activeTurnIDs.isEmpty }.keys.sorted()
    }

    /// Thread the agent is currently bound to, if a session is live.
    public func activeThread(slug: String) -> String? { sessions[slug]?.threadID }

    /// Escape hatch: the live protocol client for a running agent session.
    public func client(slug: String) -> CodexProtocolClient? { sessions[slug]?.client }

    /// Tears the agent's app-server down; the next send respawns it. A stop
    /// requested while a cold start is in flight cancels the spawn — the
    /// late session never registers and its process is closed.
    public func stop(slug: String) {
        // Remove, not just cancel — a later send must respawn rather than
        // await the dead task's CancellationError.
        starting.removeValue(forKey: slug)?.cancel()
        guard let session = sessions.removeValue(forKey: slug) else { return }
        teardown(session)
    }

    public func stopAll() {
        for slug in Set(sessions.keys).union(starting.keys) { stop(slug: slug) }
    }

    private func teardown(_ session: Session) {
        session.forwarder.cancel()
        Task { await session.client.close() }
    }

    private func session(for agent: CompanionAgent) async throws -> Session {
        let slug = agent.slug
        // The connected check suspends — a stop() can land in between. Only
        // return the session if it's still the registered one afterwards.
        if let session = sessions[slug], await session.client.connected,
           sessions[slug]?.client === session.client { return session }
        // A cold start is already running — share its outcome rather than
        // spawn a twin app-server against the same CODEX_HOME.
        if let pending = starting[slug] { return try await pending.value }
        if let stale = sessions.removeValue(forKey: slug) { teardown(stale) }
        let task = Task<Session, Error> { [self] in try await spawnAndRegister(agent) }
        starting[slug] = task
        defer { starting.removeValue(forKey: slug) }
        return try await task.value
    }

    /// Spawns the app-server, binds/resumes the thread, then registers —
    /// re-checking cancellation at the last point so a stop() that landed
    /// mid-spawn closes the session instead of publishing it.
    private func spawnAndRegister(_ agent: CompanionAgent) async throws -> Session {
        try writeConfig(for: agent)
        // Per-agent vars (MCP tokens) layer OVER the base env — a non-nil
        // environmentFor must never discard configuration.environment,
        // which carries the provider's API key.
        var environment = configuration.environment
        environment.merge(configuration.environmentFor?(agent) ?? [:]) { _, new in new }
        // The base env and any values captured inside the environmentFor
        // closure are launch-time snapshots — a key entered mid-session
        // (Settings → Keychain) would never reach a child spawned after
        // boot. Re-read the credentials this configuration transports
        // live at spawn; a non-empty live value wins, an empty one can't
        // be told from "never set" so the snapshot stands.
        environment.merge(liveCredentials()) { _, new in new }
        environment["CODEX_HOME"] = agent.codexHomePath
        let client = CodexProtocolClient(executable: configuration.codexBinary,
                                       environment: environment,
                                       onStderrLine: configuration.onStderrLine)
        let slug = agent.slug
        let continuation = eventContinuation
        // Subscribe before start() — the client's event bus drops events
        // with no attached reader, and the Task body's first iteration
        // races the server's earliest notifications.
        let events = client.events
        let forwarder = Task { [weak self] in
            for await event in events {
                if case .turnCompleted(_, let turn) = event {
                    await self?.turnEnded(slug: slug, client: client, turnID: turn.id)
                }
                continuation.yield(AgentCodexEvent(agentSlug: slug, event: event))
            }
            await self?.sessionEnded(slug: slug, client: client)
        }
        do {
            try await client.start()
            let model = configuration.provider.model.isEmpty ? nil : configuration.provider.model
            var threadID: String
            if let last = agent.threadIDs.last {
                do {
                    threadID = try await client.resumeThread(last, cwd: agent.workspacePath,
                                                           model: model)
                } catch {
                    threadID = try await client.startThread(cwd: agent.workspacePath,
                                                          model: model,
                                                          sandbox: "workspace-write")
                }
            } else {
                threadID = try await client.startThread(cwd: agent.workspacePath,
                                                        model: model,
                                                        sandbox: "workspace-write")
            }
            let session = Session(client: client, threadID: threadID,
                                  forwarder: forwarder)
            try Task.checkCancellation()
            sessions[slug] = session
            return session
        } catch {
            forwarder.cancel()
            await client.close()
            throw error
        }
    }

    /// Records the finished turn and drops it from the in-flight set.
    /// The ledger matters because turn/completed can land BEFORE send's
    /// write-back — without it the id would latch active and a later
    /// interrupt() would fire turn/interrupt at a dead turn.
    private func turnEnded(slug: String, client: CodexProtocolClient, turnID: String) {
        guard sessions[slug]?.client === client else { return }
        sessions[slug]?.activeTurnIDs.removeAll { $0 == turnID }
        sessions[slug]?.completedTurns.append(turnID)
        if let turns = sessions[slug]?.completedTurns, turns.count > 16 {
            sessions[slug]?.completedTurns = Array(turns.suffix(16))
        }
    }

    /// Only clears the registry when the finished stream belongs to the
    /// session still registered — a replaced session's dying forwarder must
    /// not evict its successor.
    private func sessionEnded(slug: String, client: CodexProtocolClient) {
        guard sessions[slug]?.client === client else { return }
        sessions.removeValue(forKey: slug)
    }

    /// The credentials this configuration transports, read live at spawn.
    /// Covers the provider's env_key and the TYPESAFE_API_KEY the jev-drive
    /// MCP server picks up via env_vars — both live in Config (Keychain-
    /// backed) so mid-session entry lands without a relaunch. Keys with no
    /// live source (or an empty live value) pass through untouched.
    private func liveCredentials() -> [String: String] {
        var live: [String: String] = [:]
        for key in [configuration.provider.envKey, "TYPESAFE_API_KEY"] where !key.isEmpty {
            let value: String?
            switch key {
            case "OPENAI_API_KEY": value = Config.shared.openAIAPIKey
            case "TYPESAFE_API_KEY": value = Config.shared.apiKey
            default: value = ProcessInfo.processInfo.environment[key]
            }
            if let value, !value.isEmpty { live[key] = value }
        }
        return live
    }

    /// config.toml — Clicky parity: custom provider authenticated via env_key,
    /// never ask for approval, workspace-scoped writes plus loopback network
    /// for the computer-use/jev-use MCP servers. For system-auth providers the
    /// user's login is LINKED into the isolated CODEX_HOME — see
    /// `linkSystemAuth`; without it every turn on the preferred ChatGPT
    /// sign-in path failed auth.
    private func writeConfig(for agent: CompanionAgent) throws {
        let home = URL(fileURLWithPath: agent.codexHomePath, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let toml = Self.configTOML(provider: configuration.provider,
                                   mcpServers: configuration.mcpServersFor?(agent) ?? configuration.mcpServers)
        try toml.write(to: home.appendingPathComponent("config.toml"),
                       atomically: true, encoding: .utf8)
        if configuration.provider.usesSystemAuth {
            Self.linkSystemAuth(into: home, source: FileManager.default
                .homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"))
        } else {
            // Env-key provider: a stale auth link/file left by an earlier
            // system-auth spawn would silently override the configured key.
            try? FileManager.default.removeItem(
                at: home.appendingPathComponent("auth.json"))
        }
    }

    /// auth.json is SYMLINKED — never copied — into agent homes. A copy
    /// stranded every other home on a rotated credential the next refresh,
    /// and widened the login's blast radius per duplicate; a link keeps one
    /// credential on disk so rotation lands in the real file and refresh
    /// propagates through it. Missing source → leave absent: the turn fails
    /// auth honestly, exactly as an unlinked home did. An existing real
    /// file or a link to the wrong target is replaced (migrated); a link
    /// failure logs and the spawn proceeds — codex reports the miss at
    /// turn time.
    static func linkSystemAuth(into home: URL, source: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        let link = home.appendingPathComponent("auth.json")
        // A dangling symlink reads as "no file" — check the link itself.
        let existing = try? fm.destinationOfSymbolicLink(atPath: link.path)
        if existing == source.path { return }
        if existing != nil || fm.fileExists(atPath: link.path) {
            try? fm.removeItem(at: link)
        }
        do {
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
        } catch {
            Self.log.error("auth.json link failed in \(home.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func configTOML(provider: CodexModelProvider, mcpServers: [CodexMCPServer]) -> String {
        var toml = """
        \(provider.model.isEmpty ? "" : "model = \(tomlString(provider.model))\n")\
        \(provider.usesSystemAuth ? "" : "model_provider = \(tomlString(provider.name))\n")\
        approval_policy = "never"
        sandbox_mode = "workspace-write"

        [sandbox_workspace_write]
        network_access = true

        """
        if !provider.usesSystemAuth {
            toml += """

            [model_providers.\(tomlString(provider.name))]
            name = \(tomlString(provider.name))
            base_url = \(tomlString(provider.baseURL))
            wire_api = \(tomlString(provider.wireAPI))
            env_key = \(tomlString(provider.envKey))

            """
        }
        for server in mcpServers {
            toml += """

            [mcp_servers.\(tomlString(server.name))]
            command = \(tomlString(server.command))
            args = [\(server.args.map(tomlString).joined(separator: ", "))]
            default_tools_approval_mode = "approve"

            """
            if !server.envVars.isEmpty {
                toml += "env_vars = [\(server.envVars.map(tomlString).joined(separator: ", "))]\n"
            }
            if let cwd = server.cwd {
                toml += "cwd = \(tomlString(cwd))\n"
            }
        }
        return toml
    }

    private static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
