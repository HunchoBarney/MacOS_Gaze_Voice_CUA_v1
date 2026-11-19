import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: the termination handler hops onto the actor and only an
/// exit that still owns `process` counts — stale handlers from replaced
/// spawns and deliberate kills (the handle was already cleared) must
/// never respawn. A mid-boot death is the boot loop's cleanup, not an
/// unexpected exit. `retireSpawn` is the stale-generation exit path: it
/// must never kill a spawn a newer generation adopted, and never clear
/// a child that isn't the one it spawned.
final class TrackerHostTests: XCTestCase {

    /// A real (harmless, short-lived) child — the pid identity check
    /// needs a genuine processIdentifier, which Process assigns at run().
    private func makeChild() throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        return proc
    }

    /// A live tracker on the API port means a kill-path test would POST
    /// a real {"action":"quit"} — skip rather than kill someone's
    /// running tracker.
    private func skipIfTrackerServing() async throws {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(TrackerHost.port)/health")!)
        request.timeoutInterval = 0.5
        let live = (try? await URLSession.shared.data(for: request))
            .flatMap { _, r in (r as? HTTPURLResponse)?.statusCode } == 200
        try XCTSkipIf(live, "a real tracker is serving on :\(TrackerHost.port) — kill-path tests would quit it")
    }

    private func tempTrackerDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackerhost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - handleExit identity check

    /// An exit whose pid doesn't match the owned child — a stale
    /// handler from a replaced spawn — must not touch anything.
    func testStaleExitPidIsIgnored() async throws {
        let host = TrackerHost()
        let proc = try makeChild()
        defer { proc.terminate() }
        await host.installForTest(child: proc, attempts: 0, state: .running)
        let generation = await host.generationForTest
        await host.handleExit(pid: proc.processIdentifier + 1)
        let state = await host.state
        let childPid = await host.childPidForTest
        let generationAfter = await host.generationForTest
        XCTAssertEqual(state, .running, "a stale exit must not disturb the live claim")
        XCTAssertEqual(childPid, proc.processIdentifier,
                       "a stale exit never clears the live child's handle")
        XCTAssertEqual(generationAfter, generation, "a stale exit never respawns")
        XCTAssertTrue(proc.isRunning)
    }

    /// With no child owned — the deliberate-stop shape — any exit is noise.
    func testExitWithNoOwnedChildIsIgnored() async throws {
        let host = TrackerHost()
        await host.installForTest(child: nil, attempts: TrackerHost.maxAttempts,
                                  state: .stopped)
        let generation = await host.generationForTest
        await host.handleExit(pid: 4242)
        let state = await host.state
        let generationAfter = await host.generationForTest
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(generationAfter, generation)
    }

    /// A mid-boot death clears the handle but must NOT respawn — the
    /// boot loop owns that cleanup and writes the honest .failed.
    func testBootTimeDeathDoesNotRespawn() async throws {
        let host = TrackerHost()
        let proc = try makeChild()
        defer { proc.terminate() }
        await host.installForTest(child: proc, attempts: 0, state: .starting)
        let generation = await host.generationForTest
        await host.handleExit(pid: proc.processIdentifier)
        let childPid = await host.childPidForTest
        let state = await host.state
        let generationAfter = await host.generationForTest
        XCTAssertNil(childPid, "the dead child's handle is released")
        XCTAssertEqual(state, .starting, "a pre-.running death stays the boot loop's problem")
        XCTAssertEqual(generationAfter, generation,
                       "no respawn claim before .running")
    }

    /// The respawn path itself: a .running child dying unexpectedly with
    /// budget left is claimed synchronously — handle cleared, generation
    /// bumped. Spawning is disabled so the claim never forks a real
    /// tracker; a live foreign tracker may adopt the claim, which is
    /// still a claim.
    func testOwnedRunningExitClaimsRespawn() async throws {
        let host = TrackerHost(spawnEnabled: false)
        let proc = try makeChild()
        defer { proc.terminate() }
        let pid = proc.processIdentifier
        await host.installForTest(child: proc, attempts: 0, state: .running)
        let before = await host.generationForTest
        await host.handleExit(pid: pid)
        let childPid = await host.childPidForTest
        let generationAfter = await host.generationForTest
        let state = await host.state
        XCTAssertNil(childPid)
        XCTAssertEqual(generationAfter, before + 1,
                       "a .running death with budget respawns through ensureRunning")
        XCTAssertNotEqual(state, .stopped,
                          "the claim never parks on the dead child's .stopped")
    }

    /// Budget spent — the same exit writes the honest terminal .failed
    /// and claims nothing.
    func testOwnedRunningExitWithSpentBudgetFails() async throws {
        let host = TrackerHost()
        let proc = try makeChild()
        defer { proc.terminate() }
        await host.installForTest(child: proc, attempts: TrackerHost.maxAttempts,
                                  state: .running)
        let generation = await host.generationForTest
        await host.handleExit(pid: proc.processIdentifier)
        let state = await host.state
        let childPid = await host.childPidForTest
        let generationAfter = await host.generationForTest
        guard case .failed = state else {
            return XCTFail("expected .failed, got \(state)")
        }
        XCTAssertNil(childPid)
        XCTAssertEqual(generationAfter, generation,
                       "an exhausted budget must not respawn")
    }

    /// The deliberate-kill shape: stop() cleared the handle before the
    /// SIGTERM landed, so when the termination handler fires the exit is
    /// already unowned — the identity check is what keeps an
    /// intentional kill off the respawn path.
    func testDeliberateKillDoesNotRespawn() async throws {
        let host = TrackerHost()
        let proc = try makeChild()
        defer { proc.terminate() }
        // What the actor looks like after stop() ran: handle cleared,
        // budget spent, deliberate .stopped.
        await host.installForTest(child: nil, attempts: TrackerHost.maxAttempts,
                                  state: .stopped)
        let generation = await host.generationForTest
        await host.handleExit(pid: proc.processIdentifier)
        let state = await host.state
        let generationAfter = await host.generationForTest
        XCTAssertEqual(state, .stopped, "an intentional kill must stay stopped")
        XCTAssertEqual(generationAfter, generation)
    }

    // MARK: - Stale-generation exits

    /// The off→on toggle race: a start suspended in its boot window
    /// must not resurrect after a stop() superseded it. The spawn fuse
    /// makes a guard regression observable — a stale start that slipped
    /// through would land .failed instead of leaving .stopped.
    func testStaleStartLeavesStoppedStanding() async throws {
        try await skipIfTrackerServing()
        let host = TrackerHost(spawnEnabled: false)
        // Pin the sweep's blast radius to a temp dir — stop() runs the
        // pkill last resort against it.
        await host.installForTest(child: nil, attempts: 0, state: .stopped,
                                  trackerDir: try tempTrackerDir())
        await host.ensureRunning()
        let claimed = await host.generationForTest
        await host.stop()
        // Give the queued stale start its turns — it must exit quietly.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            if await host.state != .starting { break }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let state = await host.state
        let generationAfter = await host.generationForTest
        XCTAssertEqual(state, .stopped,
                       "a superseded start must not write state behind stop()'s back")
        XCTAssertEqual(generationAfter, claimed + 1,
                       "nothing respawned — only stop()'s own bump landed")
    }

    /// A stale spawn that a newer generation adopted IS the live
    /// tracker — retiring it must not run the kill tree.
    func testRetireSpawnKeepsAdoptedTrackerAlive() async throws {
        let host = TrackerHost()
        let proc = try makeChild()
        defer { proc.terminate() }
        // Newer generation adopted the API while our spawn still ran:
        // adopted + .running marks it.
        await host.installForTest(child: proc, attempts: 0, state: .running,
                                  adopted: true, trackerDir: try tempTrackerDir())
        await host.retireSpawn(proc)
        XCTAssertTrue(proc.isRunning,
                      "the adopted spawn IS the tracker — retire must not kill it")
        let childPid = await host.childPidForTest
        XCTAssertNil(childPid, "the stale claim releases its handle either way")
    }

    /// The ordinary stale/unadopted retire — the spawn gets the full
    /// kill tree and the handle is released.
    func testRetireSpawnKillsUnadoptedSpawn() async throws {
        try await skipIfTrackerServing()
        let host = TrackerHost()
        let proc = try makeChild()
        defer { proc.terminate() }
        await host.installForTest(child: proc, attempts: 0, state: .stopped,
                                  trackerDir: try tempTrackerDir())
        await host.retireSpawn(proc)
        for _ in 0..<20 where proc.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(proc.isRunning, "a stale spawn nobody adopted gets the kill tree")
        let childPid = await host.childPidForTest
        XCTAssertNil(childPid)
    }
}
