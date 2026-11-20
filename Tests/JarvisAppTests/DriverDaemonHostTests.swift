import XCTest
@testable import Jarvis
import JarvisCore

/// Daemon spawn environment and host lifecycle. The env contract is a pure
/// function of the host's environment so the clamp + override path is
/// pinned without spawning a driver; lifecycle uses the `mintOverride` /
/// `preboundSocket` seams — no real daemon ever starts.
final class DriverDaemonHostTests: XCTestCase {

    func testDaemonEnvironmentForcesTelemetryOff() {
        let env = EmbeddedDaemon.daemonEnvironment(host: [
            "DO_NOT_TRACK": "0",
            "CUA_TELEMETRY": "1",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "true",
        ])
        XCTAssertEqual(env["DO_NOT_TRACK"], "1")
        XCTAssertEqual(env["CUA_TELEMETRY"], "0")
        XCTAssertEqual(env["CUA_DRIVER_RS_TELEMETRY_ENABLED"], "0")
    }

    func testProxyProcessUsesSafeChildEnvironmentWithoutLaunching() {
        let executable = URL(fileURLWithPath: "/bin/true")
        let proxy = CuaConnection.makeProxyProcess(
            executable: executable,
            socket: "/tmp/jev-test-never-opened.sock",
            hostEnvironment: [
                "HOME": "/tmp/jev-test-home",
                "AWS_SECRET_ACCESS_KEY": "synthetic-secret",
                "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS": "1",
                "DO_NOT_TRACK": "0",
                "CUA_TELEMETRY": "1",
            ]
        )
        XCTAssertFalse(proxy.isRunning)
        XCTAssertEqual(proxy.executableURL, executable)
        XCTAssertEqual(proxy.arguments, [
            "mcp", "--embedded", "--socket", "/tmp/jev-test-never-opened.sock",
            "--host-bundle-id", CuaDependency.hostBundleID,
        ])
        let env = proxy.environment ?? [:]
        XCTAssertEqual(env["HOME"], "/tmp/jev-test-home")
        XCTAssertEqual(env["DO_NOT_TRACK"], "1")
        XCTAssertEqual(env["CUA_TELEMETRY"], "0")
        XCTAssertEqual(env["CUA_DRIVER_RS_TELEMETRY_ENABLED"], "0")
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(env["CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS"])
    }

    // MARK: - Window-change tail knobs

    /// Unset host env → the clamped defaults: 100ms observation window,
    /// 25ms poll interval.
    func testDaemonEnvironmentDefaultsWindowChangeTail() {
        let env = EmbeddedDaemon.daemonEnvironment(host: [:])
        XCTAssertEqual(env["CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS"], "100")
        XCTAssertEqual(env["CUA_DRIVER_WINDOW_CHANGE_POLL_MS"], "25")
    }

    /// Host-exported knobs pass through verbatim — operators can loosen
    /// the clamp without a rebuild; the driver clamps bad values itself.
    func testDaemonEnvironmentRespectsHostOverrides() {
        let env = EmbeddedDaemon.daemonEnvironment(host: [
            "CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS": "750",
            "CUA_DRIVER_WINDOW_CHANGE_POLL_MS": "40",
        ])
        XCTAssertEqual(env["CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS"], "750")
        XCTAssertEqual(env["CUA_DRIVER_WINDOW_CHANGE_POLL_MS"], "40")
    }

    /// The env allowlist still drops everything ambient — an exported
    /// secret or an unrelated CUA_DRIVER_* flag never reaches the daemon.
    func testDaemonEnvironmentAllowlistDropsAmbientVars() {
        let env = EmbeddedDaemon.daemonEnvironment(host: [
            "AWS_SECRET_ACCESS_KEY": "secret",
            "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS": "1",
            "HOME": "/tmp/home",
        ])
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(env["CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS"])
        XCTAssertEqual(env["HOME"], "/tmp/home")
    }

    /// Embedded pins are always set — identity, host pid, embedded flag.
    func testDaemonEnvironmentPinsEmbeddedIdentity() {
        let env = EmbeddedDaemon.daemonEnvironment(host: [:])
        XCTAssertEqual(env["CUA_DRIVER_EMBEDDED"], "1")
        XCTAssertEqual(env["CUA_DRIVER_HOST_BUNDLE_ID"], CuaDependency.hostBundleID)
        XCTAssertEqual(env["CUA_DRIVER_EMBEDDED_HOST_PID"],
                       "\(ProcessInfo.processInfo.processIdentifier)")
    }

    // MARK: - Private socket directory

    /// The daemon's socket directory is created per run with mkdtemp:
    /// owner-only (0700) and an unguessable name, never a fixed path.
    func testSocketDirectoryIsPrivateAndRandom() throws {
        let base = FileManager.default.temporaryDirectory.path
        let first = try XCTUnwrap(CuaSocketDirectory.create(in: base))
        let second = try XCTUnwrap(CuaSocketDirectory.create(in: base))
        defer {
            try? FileManager.default.removeItem(atPath: first)
            try? FileManager.default.removeItem(atPath: second)
        }
        XCTAssertNotEqual(first, second)
        XCTAssertTrue((first as NSString).lastPathComponent.hasPrefix("jarvis-cua-"))
        let mode = try FileManager.default.attributesOfItem(atPath: first)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    /// A long temp folder falls back to /tmp so the socket path stays under
    /// the ~104-byte Unix socket limit.
    func testSocketPathFitsTheUnixSocketLimit() throws {
        let long = "/private/var/folders/" + String(repeating: "x", count: 80) + "/T/"
        let directory = try XCTUnwrap(CuaSocketDirectory.create(in: long))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        XCTAssertTrue(directory.hasPrefix("/tmp/jarvis-cua-"))
        let socket = EmbeddedDaemon.socketPath(in: directory)
        XCTAssertLessThan(socket.utf8.count, 104)
        XCTAssertNotEqual(socket, EmbeddedDaemon.socketPath(in: directory),
                          "each mint gets a fresh name so stale faults can't match a successor")
    }

    /// Agent MCP children find the live socket inside the directory they
    /// were handed — the newest `.sock`, ignoring anything else.
    func testLiveSocketPicksTheNewestSocketInTheDirectory() throws {
        let directory = try XCTUnwrap(CuaSocketDirectory.create(in: FileManager.default.temporaryDirectory.path))
        defer { try? FileManager.default.removeItem(atPath: directory) }
        XCTAssertNil(CuaSocketDirectory.liveSocket(in: directory))
        let fm = FileManager.default
        let old = (directory as NSString).appendingPathComponent("d-old.sock")
        let new = (directory as NSString).appendingPathComponent("d-new.sock")
        XCTAssertTrue(fm.createFile(atPath: old, contents: nil))
        XCTAssertTrue(fm.createFile(atPath: new, contents: nil))
        XCTAssertTrue(fm.createFile(atPath: (directory as NSString).appendingPathComponent("notes.txt"), contents: nil))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old)
        XCTAssertEqual(CuaSocketDirectory.liveSocket(in: directory), new)
        XCTAssertNil(CuaSocketDirectory.liveSocket(in: "/nonexistent-\(UUID())"))
    }

    // MARK: - Sick-daemon invalidation (the onSickDaemon wiring target)

    private actor MintCounter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    /// The token-scoped path: a fault naming the live socket stops the
    /// daemon — `stop()` clears the bound socket path.
    func testInvalidateMatchingStopsBoundDaemon() async {
        let bound = EmbeddedDaemon(
            executable: URL(fileURLWithPath: "/bin/true"),
            preboundSocket: "/tmp/jev-test-\(UUID().uuidString).sock")
        let host = CuaDaemonHost(daemon: bound)
        await host.invalidate(matching: bound.socketPath!)
        XCTAssertNil(bound.socketPath, "stop() must clear the bound socket")
        let minted = await host.minted
        XCTAssertFalse(minted)
    }

    /// A stale fault aimed at a recycled generation must no-op — the
    /// mismatched token leaves the healthy daemon bound.
    func testInvalidateMismatchedTokenNoOps() async {
        let socket = "/tmp/jev-test-\(UUID().uuidString).sock"
        let bound = EmbeddedDaemon(
            executable: URL(fileURLWithPath: "/bin/true"), preboundSocket: socket)
        let host = CuaDaemonHost(daemon: bound)
        await host.invalidate(matching: "/tmp/jev-test-stale-\(UUID().uuidString).sock")
        XCTAssertEqual(bound.socketPath, socket)
        let minted = await host.minted
        XCTAssertTrue(minted)
    }

    // MARK: - restartDriver

    /// Teardown + respawn + readiness: the bound daemon is stopped (its
    /// socket cleared) and the mint path runs once through `socket()`.
    func testRestartDriverTearsDownAndRemints() async {
        let mints = MintCounter()
        let bound = EmbeddedDaemon(
            executable: URL(fileURLWithPath: "/bin/true"),
            preboundSocket: "/tmp/jev-test-\(UUID().uuidString).sock")
        let host = CuaDaemonHost(daemon: bound) {
            await mints.bump()
            return "/tmp/jev-test-fresh.sock"
        }
        await host.restartDriver()
        XCTAssertNil(bound.socketPath, "old daemon must be torn down")
        let mintCount = await mints.value
        XCTAssertEqual(mintCount, 1, "respawn must run the mint path once")
    }

    /// No live daemon → restartDriver still runs the mint path.
    func testRestartDriverWithNoDaemonMints() async {
        let mints = MintCounter()
        let host = CuaDaemonHost {
            await mints.bump()
            return "/tmp/jev-test-fresh.sock"
        }
        await host.restartDriver()
        let mintCount = await mints.value
        XCTAssertEqual(mintCount, 1)
    }

    /// A failed re-mint is non-fatal — restartDriver returns and the host
    /// stays unminted so the next `socket()` retries lazily.
    func testRestartDriverSwallowsMintFailure() async {
        let host = CuaDaemonHost {
            throw DriverConnectionError.unavailable
        }
        await host.restartDriver()  // must return, not throw
        let minted = await host.minted
        XCTAssertFalse(minted)
    }
}
