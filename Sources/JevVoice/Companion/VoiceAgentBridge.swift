import Foundation
import JevVoiceCore

/// The voice path's delegation seam into the persistent-agent runtime.
/// Every String return is a VoiceToolResult payload — the lane voices `say`
/// verbatim and routes on `status`.
protocol AgentBridging: Sendable {
    /// Slugs/names/roles the tool surface may route to.
    func roster() async -> [CompanionAgent]
    /// `delegate_to_agent` tool: found or reuse a persistent agent. Returns
    /// the acknowledgement payload the runtime reports.
    func delegate(_ request: DelegationRequest) async throws -> String
    /// A follow-up into an existing agent's thread. Implemented but not yet
    /// wired into a voice tool — kept as public API for a later lane.
    func sendToAgent(slug: String, message: String) async throws -> String
    /// Read findings without waking the agent. Same status as
    /// `sendToAgent` — real implementation, no production caller yet.
    func agentMemory(slug: String) async throws -> String
    /// Interrupt an agent's live turn by name/slug hint — the voice
    /// cancel_task path's reach into delegated work.
    func interruptAgent(hint: String?) async -> String
    /// Interrupt EVERY agent turn in flight — the universal "stop". The
    /// default degrades to the hinted path so stubs and test spies keep
    /// working; production overrides with the real all-turn sweep.
    func interruptAll() async -> String
}

extension AgentBridging {
    func interruptAll() async -> String { await interruptAgent(hint: nil) }
}

/// Production `AgentBridging` over `AgentRuntime` — the voice path's
/// delegation seam. A nil runtime means agents are unavailable in this
/// build; decisions refuse honestly rather than guessing. When the runtime
/// was nil at boot (no codex auth at launch), `ensureRuntime` re-attempts
/// construction on demand — a user who signs in mid-session gets agents on
/// the next request instead of after a relaunch. The resolver owns the full
/// wiring (start hooks, reply/event sinks, UI binding) and must be cheap
/// while unauthenticated; once it returns a runtime the instance is kept.
@MainActor
final class VoiceAgentBridge: AgentBridging {
    enum Failure: Error, LocalizedError {
        case unavailable
        case unknownAgent(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Persistent agents are not available in this build."
            case .unknownAgent(let slug): return "No agent named \(slug) exists."
            }
        }
    }

    private var runtime: AgentRuntime?
    private let ensureRuntime: (() async -> AgentRuntime?)?
    /// One resolution in flight at a time — concurrent voice calls must
    /// not each build a runtime.
    private var resolving: Task<AgentRuntime?, Never>?

    init(runtime: AgentRuntime?, ensureRuntime: (() async -> AgentRuntime?)? = nil) {
        self.runtime = runtime
        self.ensureRuntime = ensureRuntime
    }

    /// The bound runtime — re-resolved through the hook while nil, kept
    /// once one exists. Stays nil (honest refusal) when nothing wires it.
    private func currentRuntime() async -> AgentRuntime? {
        if let runtime { return runtime }
        guard let ensureRuntime else { return nil }
        if let resolving { return await resolving.value }
        let task = Task { await ensureRuntime() }
        resolving = task
        let resolved = await task.value
        resolving = nil
        if let resolved { runtime = resolved }
        return resolved
    }

    func roster() async -> [CompanionAgent] {
        guard let runtime = await currentRuntime() else { return [] }
        return await runtime.store.agents()
    }

    func delegate(_ request: DelegationRequest) async throws -> String {
        guard let runtime = await currentRuntime() else { throw Failure.unavailable }
        let agent: CompanionAgent
        if let slug = request.agentSlug {
            // A delegation that names an agent binds it — a stale slug is a
            // wrong-target risk, never a reason to found a substitute. The
            // model passes NAMES ("Inbox Desk") — match name, slug, and the
            // slugified name before refusing.
            guard let existing = try await resolveAgent(slug, runtime: runtime) else {
                throw Failure.unknownAgent(slug)
            }
            agent = existing
        } else {
            agent = try await runtime.foundAgent(
                name: request.newAgentName ?? "Agent",
                role: request.newAgentRole ?? "assistant",
                description: request.newAgentDescription ?? request.message)
        }
        try await runtime.send(request.message, to: agent)
        return VoiceToolResult(status: VoiceToolResult.Status.delegated,
            say: VoiceToolResult.spoken("On it, \(agent.name) has it", words: 12)).encoded()
    }

    func sendToAgent(slug: String, message: String) async throws -> String {
        guard let runtime = await currentRuntime(),
              let agent = await runtime.store.agent(slug: slug) else {
            throw Failure.unknownAgent(slug)
        }
        try await runtime.send(message, to: agent)
        return VoiceToolResult(status: VoiceToolResult.Status.sent,
            say: VoiceToolResult.spoken("Sent to \(agent.name)", words: 12)).encoded()
    }

    /// The agent's curated memory is the "Notes" section of its AGENTS.md —
    /// read straight from the workspace so the lookup never wakes a thread.
    func agentMemory(slug: String) async throws -> String {
        guard let runtime = await currentRuntime(),
              let agent = await runtime.store.agent(slug: slug) else {
            throw Failure.unknownAgent(slug)
        }
        let url = URL(fileURLWithPath: agent.workspacePath)
            .appendingPathComponent("AGENTS.md")
        let empty = VoiceToolResult(status: VoiceToolResult.Status.ok,
            say: VoiceToolResult.spoken("\(agent.name) has no recorded findings yet",
                                        words: 20)).encoded()
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let range = text.range(of: "## Notes") else {
            return empty
        }
        let notes = String(text[range.upperBound...])
            .components(separatedBy: "\n## ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !notes.isEmpty else { return empty }
        // Short notes read aloud verbatim; longer ones get a spoken summary
        // line and the full text stays in detail for the model to paraphrase.
        let spoken = VoiceToolResult.spoken(notes, words: 20)
        let short = notes.split(whereSeparator: \.isWhitespace).count <= 20
        return VoiceToolResult(status: VoiceToolResult.Status.ok,
            say: short ? spoken
                : VoiceToolResult.spoken("\(agent.name) has notes on file, too long to read aloud", words: 20),
            detail: notes).encoded()
    }

    /// Where a voice "stop" should land.
    enum StopResolution: Equatable {
        /// The single agent to interrupt — carries its slug.
        case target(String)
        /// No agent has a live turn (bare "stop") — answer honestly.
        case nothingRunning
        /// The hint matched no roster agent at all.
        case noMatch
        /// More than one candidate — the names for the refusal detail.
        case ambiguous([String])
    }

    /// A bare "stop" resolves against agents with a turn in flight ONLY —
    /// falling back to roster order used to interrupt whatever was last
    /// founded and claim a stop that never happened.
    static func resolveStop(hint: String?, agents: [CompanionAgent],
                            active: Set<String>) -> StopResolution {
        let needle = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let pool = needle.isEmpty ? agents.filter { active.contains($0.slug) } : agents
        let matches = pool.filter {
            needle.isEmpty || $0.slug.lowercased().contains(needle)
                || $0.name.lowercased().contains(needle)
        }
        if matches.count == 1, let only = matches.first { return .target(only.slug) }
        if matches.isEmpty { return needle.isEmpty ? .nothingRunning : .noMatch }
        return .ambiguous(matches.map(\.name))
    }

    func interruptAgent(hint: String?) async -> String {
        guard let runtime = await currentRuntime() else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "No agents are configured in this build.").encoded()
        }
        let agents = await runtime.store.agents()
        let noHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        switch Self.resolveStop(hint: hint, agents: agents, active: runtime.activeTurnSlugs) {
        case .nothingRunning:
            return VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                say: "Nothing is running.").encoded()
        case .noMatch:
            return VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                say: "No running agent matches.", detail: hint).encoded()
        case .ambiguous(let names):
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: noHint ? "Several agents are running, name one."
                            : "Several agents could match, name one.",
                detail: names.joined(separator: ", ")).encoded()
        case .target(let slug):
            guard let agent = agents.first(where: { $0.slug == slug }) else {
                return VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                    say: "No running agent matches.", detail: hint).encoded()
            }
            do {
                // False means the resolve raced a finish — report the miss
                // rather than claim a stop that didn't happen.
                guard try await runtime.interrupt(slug: agent.slug) else {
                    return VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                        say: VoiceToolResult.spoken("\(agent.name) isn't running.", words: 12)).encoded()
                }
                return VoiceToolResult(status: VoiceToolResult.Status.cancelled,
                    say: VoiceToolResult.spoken("Stopped \(agent.name)", words: 12)).encoded()
            } catch {
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                    say: VoiceToolResult.spoken("\(agent.name) could not be stopped", words: 12),
                    detail: error.localizedDescription).encoded()
            }
        }
    }

    /// Universal stop — every slug with a turn in flight, not the single
    /// target `resolveStop` picks. A bare "stop" must reach all delegated
    /// work; a race where a turn finished between the roster read and the
    /// interrupt just counts as missed, never claimed.
    func interruptAll() async -> String {
        guard let runtime = await currentRuntime() else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "No agents are configured in this build.").encoded()
        }
        let agents = await runtime.store.agents()
        let slugs = runtime.activeTurnSlugs
        guard !slugs.isEmpty else {
            return VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                say: "Nothing is running.").encoded()
        }
        var stopped: [String] = []
        var missed: [String] = []
        for slug in slugs.sorted() {
            let name = agents.first(where: { $0.slug == slug })?.name ?? slug
            do {
                if try await runtime.interrupt(slug: slug) {
                    stopped.append(name)
                } else {
                    missed.append(name)
                }
            } catch {
                missed.append(name)
            }
        }
        if stopped.isEmpty {
            return VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                say: "The agents already stopped.").encoded()
        }
        let spoken = "Stopped \(VoiceToolResult.spoken(stopped.joined(separator: ", "), words: 8))"
        return VoiceToolResult(
            status: VoiceToolResult.Status.cancelled,
            say: missed.isEmpty ? spoken
                : "\(spoken); \(missed.count) already finished").encoded()
    }

    /// Name-or-slug resolution: the model passes display names, the store
    /// keys on slugs — match slug exactly, name case-insensitively, or the
    /// slugified name.
    private func resolveAgent(_ value: String, runtime: AgentRuntime) async throws -> CompanionAgent? {
        if let direct = await runtime.store.agent(slug: value) { return direct }
        let slugified = AgentWorkspace.slugify(value)
        return await runtime.store.agents().first {
            $0.slug == slugified || $0.name.caseInsensitiveCompare(value) == .orderedSame
        }
    }
}
