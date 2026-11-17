import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: a `--mcp-stdio` child's drive session is minted per
/// connection, not derived from the slug. The daemon binds a session
/// label to the transport that first admits it and only that transport
/// may revive it — so a second same-slug child inheriting
/// `agent-<slug>` wedged on the dead owner's tombstone until daemon
/// respawn (the P1 bench finding, reproduced 2×).
final class CuaDriveSessionTests: XCTestCase {

    func testTaskArgumentsPreserveExactWindowTarget() throws {
        let task = try CuaDriveServer.decodeTask(.object([
            "goal": .string("Replace the test document text"),
            "app": .string("TextEdit"), "window_id": .number(48289),
            "values": .object(["text": .string("Literal test body")]),
        ]))
        XCTAssertEqual(task.windowID, 48289)
        XCTAssertEqual(task.application, "TextEdit")
        XCTAssertNil(task.pid)
        XCTAssertEqual(task.values["text"], "Literal test body")
    }

    func testTaskArgumentsRejectInvalidWindowIdentities() {
        for value: JSONValue in [.number(0), .number(-1), .number(1.5),
                                .number(4294967296), .string("42"), .bool(true), .null] {
            XCTAssertThrowsError(try CuaDriveServer.decodeTask(.object([
                "goal": .string("Edit"), "app": .string("TextEdit"), "window_id": value,
            ])))
        }
    }

    func testTaskArgumentsPreserveSuppliedLiteralsAndCompletionEvidence() throws {
        let task = try CuaDriveServer.decodeTask(.object([
            "goal": .string("Fill the profile"),
            "app": .string("Fixture"),
            "values": .object(["Name": .string(" Aster "), "Email": .string("")]),
            "success_contains": .array([.string("Profile complete")]),
            "deny": .array([.string("Send")]),
        ]))
        XCTAssertEqual(task.values, ["Name": " Aster ", "Email": ""])
        XCTAssertEqual(task.successContains, ["Profile complete"])
        XCTAssertEqual(task.deny, ["Send"])
        XCTAssertEqual(task.application, "Fixture")
        XCTAssertNil(task.pid)
        XCTAssertNil(task.windowID)
    }

    func testTaskArgumentsRejectMalformedOrMeaninglessConstraints() {
        let bad: [(String, JSONValue)] = [
            ("values", .array([])),
            ("values", .object(["Name": .number(1)])),
            ("values", .object(["": .string("Aster")])),
            ("success_contains", .string("Saved")),
            ("success_contains", .array([.string("")])),
            ("success_contains", .array([.string(" \n")])),
            ("success_contains", .array([.string("Saved"), .number(1)])),
            ("deny", .array([.string("Send"), .bool(true)])),
            ("deny", .array([.string("")])),
            ("app", .number(1)),
        ]
        for (key, value) in bad {
            XCTAssertThrowsError(try CuaDriveServer.decodeTask(.object([
                "goal": .string("Save"), key: value,
            ])), key)
        }
    }

    func testLegacyTaskArgumentsRemainValidWithoutInventedEvidence() throws {
        let task = try CuaDriveServer.decodeTask(.object(["goal": .string("Save")]))
        XCTAssertEqual(task.goal, "Save")
        XCTAssertTrue(task.values.isEmpty)
        XCTAssertTrue(task.successContains.isEmpty)
        XCTAssertTrue(task.deny.isEmpty)
        XCTAssertNil(task.application)
    }

    /// A daemon-shaped double for the lifecycle the wedge depends on:
    /// a label binds to the first transport that admits it; that
    /// transport's death tombstones the label; a foreign transport
    /// touching a tombstone loses its connection — the bench-observed
    /// `.closed` rather than an answer. Payloads delegate to the
    /// DriveLoop fixture so the loop sees ordinary responses.
    private final class Daemon {
        let inner = DriveLoopTests.FakeDriver()
        private var owner: [String: Int] = [:]
        private var tombstoned: Set<String> = []
        private(set) var calls: [(transport: Int, session: String?)] = []

        func call(_ transport: Int, _ tool: String,
                  _ args: [String: JSONValue]) throws -> JSONValue {
            let session = args["session"]?.string
            calls.append((transport, session))
            if let session {
                if tombstoned.contains(session) {
                    throw DriverConnectionError.closed
                }
                if let bound = owner[session], bound != transport {
                    throw DriverConnectionError.refused(
                        "session '\(session)' is not available to this transport")
                }
                owner[session] = transport
            }
            return try inner.call(tool, args)
        }

        /// The transport's proxy died — the daemon tombstones every
        /// session label it owned.
        func drop(_ transport: Int) {
            for (label, bound) in owner where bound == transport {
                tombstoned.insert(label)
            }
            owner = owner.filter { $0.value != transport }
        }
    }

    private func loop(_ daemon: Daemon, transport: Int) -> DriveLoop {
        daemon.inner.snapshotForRound = { _ in
            DriveLoopTests.FakeDriver.snap([
                DriveLoopTests.FakeDriver.element(0, role: "statictext",
                                                 label: "Session ready", actions: [])
            ])
        }
        return DriveLoop(call: { tool, args in try daemon.call(transport, tool, args) },
                  choose: { _, _ in
                      DriveLoop.JevChoice(id: "done", confidence: nil, doneVote: nil)
                  },
                  ask: nil,
                  granted: { true },
                  windowControlButtons: { _ in [] },
                  windowControlPress: { _, _ in false },
                  resurrector: SessionResurrector())
    }

    /// The wedge itself: two sequential `--mcp-stdio --agent scout`
    /// children. The first exits and the daemon tombstones its label —
    /// a slug-derived label made the second child's every call die on
    /// the dead owner's tombstone. Per-connection labels must both
    /// complete, and the second must never dispatch on the tombstone.
    func testSequentialSameSlugSessionsBothComplete() async {
        let daemon = Daemon()
        let first = CuaDriveServer.AgentSession(agent: "scout")
        let r1 = await loop(daemon, transport: 1).run(
            DriveTask(goal: "check", pid: 42, windowID: 7,
                      successContains: ["Session ready"]), session: first.label)
        guard case .alreadySatisfied = r1.status else {
            return XCTFail("expected alreadySatisfied, got \(r1.status)")
        }
        daemon.drop(1)

        let second = CuaDriveServer.AgentSession(agent: "scout")
        XCTAssertNotEqual(second.label, first.label,
                          "a second same-slug connection must not inherit the label")
        let r2 = await loop(daemon, transport: 2).run(
            DriveTask(goal: "check", pid: 42, windowID: 7,
                      successContains: ["Session ready"]), session: second.label)
        guard case .alreadySatisfied = r2.status else {
            return XCTFail("expected alreadySatisfied, got \(r2.status)")
        }
        XCTAssertFalse(daemon.calls.contains {
            $0.transport == 2 && $0.session == first.label
        }, "the second child must never dispatch on the tombstoned label")
    }

    /// Two same-slug children alive at once — the concurrent shape of
    /// the same defect: the second's calls refuse on the live record's
    /// owner check. Distinct labels let both run.
    func testConcurrentSameSlugSessionsBothComplete() async {
        let daemon = Daemon()
        let first = CuaDriveServer.AgentSession(agent: "scout")
        let second = CuaDriveServer.AgentSession(agent: "scout")
        let r1 = await loop(daemon, transport: 1).run(
            DriveTask(goal: "check", pid: 42, windowID: 7,
                      successContains: ["Session ready"]), session: first.label)
        let r2 = await loop(daemon, transport: 2).run(
            DriveTask(goal: "check", pid: 42, windowID: 7,
                      successContains: ["Session ready"]), session: second.label)
        guard case .alreadySatisfied = r1.status, case .alreadySatisfied = r2.status else {
            return XCTFail("expected alreadySatisfied for both, got \(r1.status) / \(r2.status)")
        }
    }

    /// The label keeps `agent-<slug>` as its stem — the coordinator's
    /// cursorless predicate and the agent-cursor surface key off that
    /// shape — while the suffix differs per mint.
    func testSessionLabelKeepsAgentStem() {
        let session = CuaDriveServer.AgentSession(agent: "scout")
        XCTAssertTrue(session.label.hasPrefix("agent-scout-"), session.label)
        XCTAssertGreaterThan(session.label.count, "agent-scout-".count)
        XCTAssertFalse(VoiceTaskCoordinator.cursorlessSession(session.label),
                       "agent sessions keep the drawn cursor")
    }

    /// Resume semantics: the label is stable for a transport's life —
    /// the loop's revive/rotate resumes a session the daemon ends
    /// mid-task — and a (re)bound transport mints a fresh one instead
    /// of inheriting the dead owner's tombstone.
    func testRebindMintsAFreshLabel() {
        let session = CuaDriveServer.AgentSession(agent: "scout")
        let bound = session.label
        session.rebind()
        XCTAssertNotEqual(session.label, bound)
        XCTAssertTrue(session.label.hasPrefix("agent-scout-"))
    }

    /// Production bind path: a failed connect never mints — a label only
    /// changes when a transport bind actually succeeds.
    func testBindTransportNeverMintsOnFailedConnect() async throws {
        let session = CuaDriveServer.AgentSession(agent: "scout")
        let bound = session.label
        let driver = CuaConnection()
        do {
            try await CuaDriveServer.bindTransport(driver, session: session,
                                                   socket: "/nonexistent/no-such-daemon.sock")
            XCTFail("missing daemon socket must throw")
        } catch {
            XCTAssertEqual(session.label, bound)
        }
        XCTAssertEqual(session.label, bound)
    }
}
