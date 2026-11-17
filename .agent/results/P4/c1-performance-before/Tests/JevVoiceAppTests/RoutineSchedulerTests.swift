import Foundation
import XCTest
@testable import JevVoice

/// Routine cadence contract: lastRunAt persists across launches, a
/// relaunch dispatches only what the schedule is owed, never-run routines
/// keep the immediate first run, and the sub-2-minute floor refuses.
final class RoutineSchedulerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var fired: FireLog!

    /// Collects scheduler fires off the actor — the fire closure runs in
    /// a Task after dispatch, so assertions poll rather than assume order.
    private final class FireLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var slugs: [String] = []
        var routines: [Routine] = []
        func add(_ slug: String, _ routine: Routine) {
            lock.lock(); defer { lock.unlock() }
            slugs.append(slug); routines.append(routine)
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return slugs.count }
    }

    override func setUp() {
        suiteName = "routine-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        fired = FireLog()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func agent(slug: String = "desk", routines: [Routine]) -> CompanionAgent {
        CompanionAgent(slug: slug, name: slug, role: "r", description: "d",
                       workspacePath: "/tmp/\(slug)", codexHomePath: "/tmp/\(slug)/codex-home",
                       routines: routines)
    }

    private func scheduler(immediate: Bool = true) -> RoutineScheduler {
        let log = fired!
        return RoutineScheduler(firstRunImmediate: immediate, lastRunDefaults: defaults) { slug, routine in
            log.add(slug, routine)
        }
    }

    private func waitForFires(_ count: Int, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while fired.count < count && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return fired.count >= count
    }

    private func lastRunKey(_ routineID: String) -> String {
        "jevvoice.routineLastRunAt.\(routineID)"
    }

    func testNeverRunRoutineFiresImmediatelyAndRecordsLastRun() async {
        let routine = Routine(id: "r1", everyMinutes: 10, task: "check")
        let scheduler = scheduler()
        await scheduler.sync(agents: [agent(routines: [routine])])
        let firedOnce = await waitForFires(1)
        XCTAssertTrue(firedOnce, "first run should dispatch")
        XCTAssertNotNil(defaults.object(forKey: lastRunKey("r1")),
                        "lastRunAt must persist at dispatch")
        await scheduler.stopAll()
    }

    func testRelaunchDoesNotRefireRoutineInsideCadence() async {
        let routine = Routine(id: "r2", everyMinutes: 10, task: "check")
        // Pretend the routine ran a minute ago — well inside its interval.
        defaults.set(Date().addingTimeInterval(-60), forKey: lastRunKey("r2"))
        let scheduler = scheduler()
        await scheduler.sync(agents: [agent(routines: [routine])])
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fired.count, 0, "a relaunch must not refire a routine inside its cadence")
        await scheduler.stopAll()
    }

    func testOverdueRoutineDispatchesOnSync() async {
        let routine = Routine(id: "r3", everyMinutes: 10, task: "check")
        defaults.set(Date().addingTimeInterval(-3600), forKey: lastRunKey("r3"))
        let scheduler = scheduler()
        await scheduler.sync(agents: [agent(routines: [routine])])
        let firedOnce = await waitForFires(1)
        XCTAssertTrue(firedOnce, "an overdue routine owes a run")
        await scheduler.stopAll()
    }

    func testNeverRunRoutineWithImmediateOffDoesNotFire() async {
        let routine = Routine(id: "r4", everyMinutes: 10, task: "check")
        let scheduler = scheduler(immediate: false)
        await scheduler.sync(agents: [agent(routines: [routine])])
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fired.count, 0)
        await scheduler.stopAll()
    }

    func testCadenceFloorNeverSchedules() async {
        let routine = Routine(id: "r5", everyMinutes: 1, task: "spam")
        let scheduler = scheduler()
        await scheduler.sync(agents: [agent(routines: [routine])])
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fired.count, 0, "every_minutes < 2 must refuse, not clamp")
        XCTAssertNil(defaults.object(forKey: lastRunKey("r5")))
        await scheduler.stopAll()
    }

    @MainActor
    func testMarkerCreateRefusesSubFloorCadence() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentStore(directory: dir)
        let bridge = CodexRuntimeBridge(configuration: .init(
            codexBinary: URL(fileURLWithPath: "/bin/false"),
            provider: CodexModelProvider(name: "openai", baseURL: "https://example.invalid",
                                       envKey: "OPENAI_API_KEY", model: "")))
        let runtime = AgentRuntime(store: store, bridge: bridge)
        let outcome = await runtime.applyRoutineMarker(
            AgentMarkers.RoutineMarker(action: "create", everyMinutes: 1, task: "spam"),
            slug: "desk")
        XCTAssertEqual(outcome, .refused("I couldn't schedule that — routines can repeat at most every 2 minutes."))
        let applied = await runtime.applyRoutineMarker(
            AgentMarkers.RoutineMarker(action: "create", everyMinutes: 30, task: "check"),
            slug: "desk")
        XCTAssertEqual(applied, .applied)
    }
}
