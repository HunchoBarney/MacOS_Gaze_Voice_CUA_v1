import Foundation
import JevVoiceCore

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
            // wrong-target risk, never a reason to found a substitute.
            guard let existing = await runtime.store.agent(slug: slug) else {
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
        return "\(agent.name) is on it."
    }

    func sendToAgent(slug: String, message: String) async throws -> String {
        guard let runtime,
              let agent = await runtime.store.agent(slug: slug) else {
            throw Failure.unknownAgent(slug)
        }
        try await runtime.send(message, to: agent)
        return "Passed to \(agent.name)."
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
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let range = text.range(of: "## Notes") else {
            return "\(agent.name) has no recorded findings yet."
        }
        let notes = String(text[range.upperBound...])
            .components(separatedBy: "\n## ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.isEmpty ? "\(agent.name) has no recorded findings yet." : notes
    }
}
