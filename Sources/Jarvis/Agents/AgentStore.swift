import Foundation
import OSLog

/// CompanionAgent roster persisted as agents.json inside the Agents root.
/// Thread ids ride on the agent record (`threadIDs`, most recent last) so a
/// respawned app-server can resume where the last session left off.
public actor AgentStore {
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis",
                                    category: "agent-store")

    private let fileURL: URL
    private var bySlug: [String: CompanionAgent] = [:]

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("agents.json")
        if let data = try? Data(contentsOf: fileURL) {
            for agent in Self.loadRoster(from: data) { bySlug[agent.slug] = agent }
        }
    }

    /// One malformed record must not zero the roster — decode wholesale
    /// first; on failure fall back to element-wise salvage so valid agents
    /// survive a corrupt sibling. Every dropped record is logged by what
    /// little identity it carried.
    static func loadRoster(from data: Data) -> [CompanionAgent] {
        if let agents = try? JSONDecoder().decode([CompanionAgent].self, from: data) {
            return agents
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            Self.log.error("agents.json is unreadable — roster left empty rather than guessed")
            return []
        }
        var dropped: [String] = []
        let agents = raw.compactMap { element -> CompanionAgent? in
            guard let slice = try? JSONSerialization.data(withJSONObject: element),
                  let agent = try? JSONDecoder().decode(CompanionAgent.self, from: slice)
            else {
                let identity = (element as? [String: Any])
                    .flatMap { $0["slug"] ?? $0["name"] } as? String ?? "<unidentified>"
                dropped.append(identity)
                return nil
            }
            return agent
        }
        for slug in dropped {
            Self.log.error("agents.json dropped a malformed record: \(slug, privacy: .public)")
        }
        return agents
    }

    public func agents() -> [CompanionAgent] {
        bySlug.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func agent(slug: String) -> CompanionAgent? { bySlug[slug] }

    @discardableResult
    public func upsert(_ agent: CompanionAgent) throws -> CompanionAgent {
        bySlug[agent.slug] = agent
        try persist()
        return agent
    }

    /// Founds an agent: slugifies the name (deduping against the roster),
    /// prepares its workspace, and records it.
    @discardableResult
    public func found(name: String, role: String, description: String,
                      root: URL = AgentWorkspace.root()) throws -> CompanionAgent {
        let base = AgentWorkspace.slugify(name)
        var slug = base, n = 2
        while bySlug[slug] != nil { slug = "\(base)-\(n)"; n += 1 }
        let workspace = try AgentWorkspace.prepare(slug: slug, name: name, role: role,
                                                   description: description, root: root)
        let agent = CompanionAgent(slug: slug, name: name, role: role, description: description,
                                   workspacePath: workspace.path,
                                   codexHomePath: AgentWorkspace.codexHomeURL(workspace: workspace).path)
        bySlug[slug] = agent
        try persist()
        return agent
    }

    /// Records a thread the agent was bound to (most recent last, deduped).
    public func recordThread(slug: String, threadID: String) throws {
        guard var agent = bySlug[slug] else { return }
        agent.threadIDs.removeAll { $0 == threadID }
        agent.threadIDs.append(threadID)
        bySlug[slug] = agent
        try persist()
    }

    public func setRoutine(slug: String, routine: Routine) throws {
        guard var agent = bySlug[slug] else { return }
        if let index = agent.routines.firstIndex(where: { $0.id == routine.id }) {
            agent.routines[index] = routine
        } else {
            agent.routines.append(routine)
        }
        bySlug[slug] = agent
        try persist()
    }

    public func removeRoutine(slug: String, routineID: String) throws {
        guard var agent = bySlug[slug] else { return }
        agent.routines.removeAll { $0.id == routineID }
        bySlug[slug] = agent
        try persist()
    }

    /// Removes the roster entry AND its workspace — the folder is
    /// agent-owned state, so delete is the honest "forget" and a recreated
    /// slug can't inherit the old AGENTS.md or codex-home. Path safety:
    /// the recorded path (canonical `<root>/<slug>` when absent) is
    /// resolved and prefix-checked, so a hand-edited record can never
    /// escape the agents root. Delete failure logs; the roster persists.
    public func remove(slug: String) throws {
        let recorded = bySlug[slug]?.workspacePath
        bySlug.removeValue(forKey: slug)
        try persist()
        let root = fileURL.deletingLastPathComponent().standardizedFileURL
        let workspace = URL(fileURLWithPath:
            recorded ?? root.appendingPathComponent(slug).path).standardizedFileURL
        guard workspace.path.hasPrefix(root.path + "/") else {
            Self.log.error("refusing to delete workspace outside the agents root: \(slug, privacy: .public)")
            return
        }
        do {
            try FileManager.default.removeItem(at: workspace)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError {
            // No workspace on disk — nothing to forget.
        } catch {
            Self.log.error("workspace delete failed for \(slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(agents()).write(to: fileURL, options: .atomic)
    }
}
