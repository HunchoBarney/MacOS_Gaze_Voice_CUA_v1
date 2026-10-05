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
    /// A follow-up into an existing agent's thread.
    func sendToAgent(slug: String, message: String) async throws -> String
    /// Read findings without waking the agent.
    func agentMemory(slug: String) async throws -> String
    /// Interrupt an agent's live turn by name/slug hint — the voice
    /// cancel_task path's reach into delegated work.
    func interruptAgent(hint: String?) async -> String
}

/// Production `AgentBridging` over `AgentRuntime` — the voice path's
/// delegation seam. A nil runtime means agents are unavailable in this
/// build; decisions refuse honestly rather than guessing.
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

    private let runtime: AgentRuntime?

    init(runtime: AgentRuntime?) { self.runtime = runtime }

    func roster() async -> [CompanionAgent] {
        guard let runtime else { return [] }
        return await runtime.store.agents()
    }

    func delegate(_ request: DelegationRequest) async throws -> String {
        guard let runtime else { throw Failure.unavailable }
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
        guard let runtime,
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
        guard let runtime,
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

    func interruptAgent(hint: String?) async -> String {
        guard let runtime else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "No agents are configured in this build.").encoded()
        }
        let agents = await runtime.store.agents()
        let needle = hint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let matches = agents.filter {
            needle.isEmpty || $0.slug.lowercased().contains(needle)
                || $0.name.lowercased().contains(needle)
        }
        guard let agent = matches.count == 1 ? matches[0]
                : (needle.isEmpty ? agents.last : nil) else {
            return matches.isEmpty
                ? VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                    say: "No running agent matches.", detail: hint).encoded()
                : VoiceToolResult(status: VoiceToolResult.Status.refused,
                    say: "Several agents could match, name one.",
                    detail: matches.map(\.name).joined(separator: ", ")).encoded()
        }
        do {
            try await runtime.interrupt(slug: agent.slug)
            return VoiceToolResult(status: VoiceToolResult.Status.cancelled,
                say: VoiceToolResult.spoken("Stopped \(agent.name)", words: 12)).encoded()
        } catch {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: VoiceToolResult.spoken("\(agent.name) could not be stopped", words: 12),
                detail: error.localizedDescription).encoded()
        }
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
