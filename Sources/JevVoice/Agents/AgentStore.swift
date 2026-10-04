import Foundation

/// CompanionAgent roster persisted as agents.json inside the Agents root.
/// Thread ids ride on the agent record (`threadIDs`, most recent last) so a
/// respawned app-server can resume where the last session left off.
public actor AgentStore {
    private let fileURL: URL
    private var bySlug: [String: CompanionAgent] = [:]

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("agents.json")
        if let data = try? Data(contentsOf: fileURL),
           let agents = try? JSONDecoder().decode([CompanionAgent].self, from: data) {
            for agent in agents { bySlug[agent.slug] = agent }
        }
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

    public func remove(slug: String) throws {
        bySlug.removeValue(forKey: slug)
        try persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(agents()).write(to: fileURL, options: .atomic)
    }
}
