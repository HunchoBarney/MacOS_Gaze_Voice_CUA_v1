import XCTest
@testable import Jarvis

/// Contract: the agent roster persists across launches, slugs dedupe,
/// and workspaces always materialize the expected layout.
final class AgentStoreTests: XCTestCase {
    private var root: URL!
    private var store: AgentStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentstore-\(UUID().uuidString)")
        store = AgentStore(directory: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSlugify() {
        XCTAssertEqual(AgentWorkspace.slugify("Inbox Desk!"), "inbox-desk")
        XCTAssertEqual(AgentWorkspace.slugify("  Spaces  Everywhere  "), "spaces-everywhere")
        XCTAssertEqual(AgentWorkspace.slugify("!!!"), "agent")
        XCTAssertEqual(AgentWorkspace.slugify("Émile's Helper"), "émile-s-helper")
        XCTAssertLessThanOrEqual(AgentWorkspace.slugify(String(repeating: "x", count: 200)).count, 48)
    }

    func testFoundCreatesWorkspaceLayoutAndPersists() async throws {
        let agent = try await store.found(name: "Desk", role: "helper", description: "desc",
                                          root: root)
        XCTAssertEqual(agent.slug, "desk")
        let fm = FileManager.default
        let workspace = URL(fileURLWithPath: agent.workspacePath)
        for sub in ["output", "tmp", "codex-home", "AGENTS.md"] {
            XCTAssertTrue(fm.fileExists(atPath: workspace.appendingPathComponent(sub).path), sub)
        }
        // A second store instance over the same directory sees the roster.
        let reloaded = AgentStore(directory: root)
        let roster = await reloaded.agents().map(\.slug)
        XCTAssertEqual(roster, ["desk"])
    }

    func testFoundDedupesSlugs() async throws {
        let a = try await store.found(name: "Desk", role: "r", description: "", root: root)
        let b = try await store.found(name: "Desk", role: "r", description: "", root: root)
        XCTAssertEqual(a.slug, "desk")
        XCTAssertEqual(b.slug, "desk-2")
    }

    func testRemoveDeletesFromRoster() async throws {
        let agent = try await store.found(name: "Gone", role: "r", description: "", root: root)
        try await store.remove(slug: agent.slug)
        let gone = await store.agent(slug: agent.slug)
        XCTAssertNil(gone)
    }

    func testRemoveDeletesWorkspaceDirectory() async throws {
        let agent = try await store.found(name: "Clean", role: "r", description: "", root: root)
        let workspace = URL(fileURLWithPath: agent.workspacePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        try await store.remove(slug: agent.slug)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path),
                       "delete is the honest forget — a recreated slug must not inherit the old workspace")
    }

    func testMalformedRecordDropsOnlyThatRecord() async throws {
        _ = try await store.found(name: "Good", role: "r", description: "", root: root)
        // Corrupt one record inside an otherwise valid agents.json — a
        // wholesale decode failure used to zero the whole roster.
        let file = root.appendingPathComponent("agents.json")
        var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        rows.append(["slug": 42, "garbage": true])  // wrong types — undecodable
        let corrupted = try JSONSerialization.data(withJSONObject: rows)
        try corrupted.write(to: file)
        let reloaded = AgentStore(directory: root)
        let slugs = await reloaded.agents().map(\.slug)
        XCTAssertEqual(slugs, ["good"], "the valid record survives its corrupt sibling")
    }

    func testRecordThreadPersistsRecency() async throws {
        let agent = try await store.found(name: "T", role: "r", description: "", root: root)
        try await store.recordThread(slug: agent.slug, threadID: "th-1")
        try await store.recordThread(slug: agent.slug, threadID: "th-2")
        try await store.recordThread(slug: agent.slug, threadID: "th-1")
        let reloaded = AgentStore(directory: root)
        let stored = await reloaded.agent(slug: agent.slug)
        XCTAssertEqual(stored?.threadIDs, ["th-2", "th-1"],
                       "most recent last, re-recording dedupes")
    }

    func testRoutinesPersistOnAgent() async throws {
        let agent = try await store.found(name: "R", role: "r", description: "", root: root)
        try await store.setRoutine(slug: agent.slug,
                                   routine: Routine(everyMinutes: 15, task: "check"))
        let stored = await store.agent(slug: agent.slug)
        XCTAssertEqual(stored?.routines.first?.everyMinutes, 15)
        try await store.removeRoutine(slug: agent.slug,
                                      routineID: stored!.routines.first!.id)
        let after = await store.agent(slug: agent.slug)
        XCTAssertTrue(after?.routines.isEmpty ?? false)
    }

    func testPrepareNeverOverwritesCuratedAgentsMD() throws {
        let workspace = try AgentWorkspace.prepare(slug: "w", name: "W", role: "r",
                                                   description: "d", root: root)
        let file = workspace.appendingPathComponent("AGENTS.md")
        try "CURATED".write(to: file, atomically: true, encoding: .utf8)
        _ = try AgentWorkspace.prepare(slug: "w", name: "W", role: "r",
                                       description: "d", root: root)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "CURATED")
    }

    func testTemplateMentionsDriveToolsNotLegacyMarker() {
        let t = AgentWorkspace.template(name: "N", role: "r", description: "d")
        XCTAssertTrue(t.contains("drive_until"), "agents must be taught the real tool")
        XCTAssertFalse(t.contains("COMPUTER_USE_REQUEST"), "dead marker must not be taught")
    }
}
