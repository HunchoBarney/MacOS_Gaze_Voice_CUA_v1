import Foundation
import JevVoiceCore

/// Custom OpenAI-compatible provider written into the agent's config.toml.
/// `envKey` names the environment variable codex reads the API key from —
/// the key itself is only ever placed in the child process environment.
public struct CodexModelProvider: Sendable, Equatable {
    public var name: String
    public var baseURL: String
    /// Observed values: "responses", "chat".
    public var wireAPI: String
    public var envKey: String
    public var model: String
    public init(name: String, baseURL: String, wireAPI: String = "responses",
                envKey: String, model: String) {
        self.name = name; self.baseURL = baseURL; self.wireAPI = wireAPI
        self.envKey = envKey; self.model = model
    }
}

/// A streamable-HTTP MCP server entry for config.toml (`[mcp_servers.<name>]`).
/// Loopback URLs are injected, never hardcoded — L5 owns the actual servers.
public struct CodexMCPServer: Sendable, Equatable {
    public var name: String
    public var url: String
    /// When set, the bearer token is read by codex from this process env var.
    public var bearerTokenEnvVar: String?
    public init(name: String, url: String, bearerTokenEnvVar: String? = nil) {
        self.name = name; self.url = url; self.bearerTokenEnvVar = bearerTokenEnvVar
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
        /// Extra child-process env — API key under `provider.envKey`, MCP
        /// bearer tokens under each server's `bearerTokenEnvVar`.
        public var environment: [String: String]
        /// Per-agent overrides — installed by the coordinator when each agent
        /// gets its own loopback MCP endpoints + bearer tokens. Nil keeps the
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
        var activeTurnID: String?
        var forwarder: Task<Void, Never>
    }

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
        var session = try await self.session(for: agent)
        let turnID = try await session.client.startTurn(threadID: session.threadID, text: message)
        session.activeTurnID = turnID
        // Write back only while this is still the registered session — a
        // concurrent sessionEnded/stop must not be resurrected.
        if sessions[agent.slug]?.client === session.client {
            sessions[agent.slug] = session
        }
        return turnID
    }

    /// Interrupts the agent's most recent turn, if one is still running.
    public func interrupt(slug: String) async throws {
        guard let session = sessions[slug], let turnID = session.activeTurnID else { return }
        try await session.client.interruptTurn(threadID: session.threadID, turnID: turnID)
    }

    /// Thread the agent is currently bound to, if a session is live.
    public func activeThread(slug: String) -> String? { sessions[slug]?.threadID }

    /// Escape hatch: the live protocol client for a running agent session.
    public func client(slug: String) -> CodexProtocolClient? { sessions[slug]?.client }

    /// Tears the agent's app-server down; the next send respawns it. A stop
    /// requested while a cold start is in flight cancels the spawn — the
    /// late session never registers and its process is closed.
    public func stop(slug: String) {
        starting[slug]?.cancel()
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
        if let session = sessions[slug], await session.client.connected { return session }
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
        var environment = configuration.environmentFor?(agent) ?? configuration.environment
        environment["CODEX_HOME"] = agent.codexHomePath
        let client = CodexProtocolClient(executable: configuration.codexBinary,
                                       environment: environment,
                                       onStderrLine: configuration.onStderrLine)
        let slug = agent.slug
        let continuation = eventContinuation
        let forwarder = Task { [weak self] in
            for await event in client.events {
                if case .turnCompleted(_, let turn) = event {
                    await self?.turnEnded(slug: slug, client: client, turnID: turn.id)
                }
                continuation.yield(AgentCodexEvent(agentSlug: slug, event: event))
            }
            await self?.sessionEnded(slug: slug, client: client)
        }
        do {
            try await client.start()
            var threadID: String
            if let last = agent.threadIDs.last {
                do {
                    threadID = try await client.resumeThread(last, cwd: agent.workspacePath,
                                                           model: configuration.provider.model)
                } catch {
                    threadID = try await client.startThread(cwd: agent.workspacePath,
                                                          model: configuration.provider.model)
                }
            } else {
                threadID = try await client.startThread(cwd: agent.workspacePath,
                                                        model: configuration.provider.model)
            }
            let session = Session(client: client, threadID: threadID,
                                  activeTurnID: nil, forwarder: forwarder)
            try Task.checkCancellation()
            sessions[slug] = session
            return session
        } catch {
            forwarder.cancel()
            await client.close()
            throw error
        }
    }

    /// Clears the completed turn so a later interrupt() can't hit a stale id.
    private func turnEnded(slug: String, client: CodexProtocolClient, turnID: String) {
        guard sessions[slug]?.client === client,
              sessions[slug]?.activeTurnID == turnID else { return }
        sessions[slug]?.activeTurnID = nil
    }

    /// Only clears the registry when the finished stream belongs to the
    /// session still registered — a replaced session's dying forwarder must
    /// not evict its successor.
    private func sessionEnded(slug: String, client: CodexProtocolClient) {
        guard sessions[slug]?.client === client else { return }
        sessions.removeValue(forKey: slug)
    }

    /// config.toml — Clicky parity: custom provider authenticated via env_key,
    /// never ask for approval, workspace-scoped writes plus loopback network
    /// for the computer-use/jev-use MCP servers.
    private func writeConfig(for agent: CompanionAgent) throws {
        let home = URL(fileURLWithPath: agent.codexHomePath, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let toml = Self.configTOML(provider: configuration.provider,
                                   mcpServers: configuration.mcpServersFor?(agent) ?? configuration.mcpServers)
        try toml.write(to: home.appendingPathComponent("config.toml"),
                       atomically: true, encoding: .utf8)
    }

    static func configTOML(provider: CodexModelProvider, mcpServers: [CodexMCPServer]) -> String {
        var toml = """
        model = \(tomlString(provider.model))
        model_provider = \(tomlString(provider.name))
        approval_policy = "never"
        sandbox_mode = "workspace-write"

        [sandbox_workspace_write]
        network_access = true

        [model_providers.\(tomlString(provider.name))]
        name = \(tomlString(provider.name))
        base_url = \(tomlString(provider.baseURL))
        wire_api = \(tomlString(provider.wireAPI))
        env_key = \(tomlString(provider.envKey))

        """
        for server in mcpServers {
            toml += """

            [mcp_servers.\(tomlString(server.name))]
            url = \(tomlString(server.url))

            """
            if let envVar = server.bearerTokenEnvVar {
                toml += "bearer_token_env_var = \(tomlString(envVar))\n"
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
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
