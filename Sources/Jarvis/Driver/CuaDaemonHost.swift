import Foundation
import JarvisCore

/// Where the daemon's sockets live: one directory per app run, made by
/// mkdtemp (mode 0700, random name) in the per-user temp folder. Nothing
/// publishes its path in a well-known file, and agent MCP children never
/// learn it: they reach the app through `AgentDriveHost` instead. This is
/// obscurity, not access control: any same-user process can still find the
/// socket (lsof, a proxy's argv, a directory scan).
enum CuaSocketDirectory {
    static let current: String? = create(in: NSTemporaryDirectory())

    /// Unix socket paths are limited to ~104 bytes, so a long temp folder
    /// falls back to /tmp.
    static func create(in base: String) -> String? {
        let parent = base.utf8.count < 60 ? base : "/tmp"
        var template = Array(URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent("jarvis-cua-XXXXXXXXXX").path.utf8CString)
        return template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
    }

    /// The live daemon socket in `directory`. A re-mint removes the old
    /// socket before binding the next, so there is normally one; the
    /// newest wins otherwise.
    static func liveSocket(in directory: String) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
        return names.filter { $0.hasSuffix(".sock") }
            .map { URL(fileURLWithPath: directory).appendingPathComponent($0).path }
            .max { modified($0) < modified($1) }
    }

    private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}

/// The `serve --embedded` daemon child — spawned as a direct descendant so
/// the driver stays in this app's TCC responsibility chain (grants attribute
/// to Jarvis, never a second CuaDriver identity). Owns the private socket
/// and the liveness stdin pipe: EOF after host exit shuts the daemon down.
/// Mirrors the driver's documented host contract (reference/cua-driver/
/// embedding.mdx): spawn directly, never via LaunchServices.
final class EmbeddedDaemon {
    private let executable: URL
    private let directory: String
    private var daemon: Process?
    private var liveness: FileHandle?
    private(set) var socketPath: String?
    var isRunning: Bool { daemon?.isRunning == true }

    init(executable: URL, directory: String) {
        self.executable = executable
        self.directory = directory
    }

    /// Test seam: fabricates a non-running daemon already bound to `socket`
    /// so host lifecycle tests can observe teardown (`stop()` clears the
    /// bound path) without spawning a real driver process.
    convenience init(executable: URL, preboundSocket socket: String) {
        self.init(executable: executable, directory: (socket as NSString).deletingLastPathComponent)
        socketPath = socket
    }

    /// The daemon's post-mutation observation window — how long its
    /// WindowChangeDetector waits for a window change after each
    /// bound-window mutation. Driver default is 1000ms (the dominant
    /// per-dispatch tax, ~1.4s clicks); the driver clamps the knob to
    /// 0–10000ms. 100ms keeps the window-diff coverage launch/menu opens
    /// need while shrinking the tail ~10x per dispatch.
    ///
    /// SAFETY: a shorter tail means the detector can report "no change"
    /// for UI still settling past 100ms — the drive loop's next observe
    /// then reads a mid-settle frame, exactly what `staleRounds` (its
    /// unchanged-fingerprint counter, maxStaleRounds=3 → blocked) already
    /// absorbs. This clamps the tail only; detection semantics are
    /// untouched, and slower UI is still re-observed by our own polls.
    static let windowChangeTimeoutMS = "100"
    /// Inter-poll interval inside the observation window — driver default
    /// 50ms, clamped 5–1000ms and never longer than the wait. 25ms halves
    /// detection latency inside the shorter tail.
    static let windowChangePollMS = "25"

    /// The daemon child's environment — allowlist only: never inherit host
    /// secrets or ambient CUA_DRIVER_* vars (an exported
    /// DANGEROUSLY_BYPASS_APPROVALS would break startup; the SDK's
    /// env_clear + allowlist contract). The window-change tail knobs are
    /// the one deliberate exception: a host-exported value passes through
    /// so operators can loosen the clamp without a rebuild; unset, the
    /// clamped defaults above apply.
    static func daemonEnvironment(host: [String: String]) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "SHELL",
                    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "__CF_USER_TEXT_ENCODING"] {
            if let value = host[key] { environment[key] = value }
        }
        environment["CUA_DRIVER_EMBEDDED"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        environment["CUA_TELEMETRY"] = "0"
        environment["CUA_DRIVER_RS_TELEMETRY_ENABLED"] = "0"
        environment["CUA_DRIVER_HOST_BUNDLE_ID"] = CuaDependency.hostBundleID
        environment["CUA_DRIVER_EMBEDDED_HOST_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
        environment["CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS"] =
            host["CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS"] ?? Self.windowChangeTimeoutMS
        environment["CUA_DRIVER_WINDOW_CHANGE_POLL_MS"] =
            host["CUA_DRIVER_WINDOW_CHANGE_POLL_MS"] ?? Self.windowChangePollMS
        return environment
    }

    func start() async throws {
        let socket = Self.socketPath(in: directory)
        try? FileManager.default.removeItem(atPath: socket)
        let environment = Self.daemonEnvironment(host: ProcessInfo.processInfo.environment)
        let liveness = Pipe()
        let daemon = Process()
        daemon.executableURL = executable
        daemon.arguments = ["serve", "--embedded", "--parent-liveness-stdio",
                            "--no-permissions-gate", "--socket", socket,
                            "--host-bundle-id", CuaDependency.hostBundleID,
                            "--permission-mode", "standard",
                            "--grant", "existing-profile"]
        daemon.environment = environment
        // Daemon logs may contain observed content; do not persist them.
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError = FileHandle.nullDevice
        daemon.standardInput = liveness
        try daemon.run()
        self.daemon = daemon
        self.liveness = liveness.fileHandleForWriting
        self.socketPath = socket
        let deadline = Date().addingTimeInterval(10)
        do {
            while daemon.isRunning && !FileManager.default.fileExists(atPath: socket) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            // A cancelled readiness wait must not strand the spawned daemon —
            // without stop() it outlives the wrapper until liveness-stdin EOF.
            stop()
            throw error
        }
        guard daemon.isRunning, FileManager.default.fileExists(atPath: socket) else {
            stop()
            throw DriverConnectionError.unavailable
        }
    }

    func stop() {
        if daemon?.isRunning == true { daemon?.terminate() }
        daemon = nil
        try? liveness?.close()
        liveness = nil
        if let socket = socketPath {
            try? FileManager.default.removeItem(atPath: socket)
            socketPath = nil
        }
    }

    /// A fresh name per mint, so a fault tagged with an old socket can't
    /// match its successor (`CuaDaemonHost.invalidate(matching:)`).
    static func socketPath(in directory: String) -> String {
        URL(fileURLWithPath: directory)
            .appendingPathComponent("d-\(UUID().uuidString.prefix(8).lowercased()).sock").path
    }
}

/// One daemon for the whole app. Every consumer (voice session, agent MCP
/// children, setup probes) spawns its own `mcp --embedded` proxy onto this
/// socket — the daemon serves N connections concurrently by design.
///
/// Health model: `socket()` re-mints a dead daemon lazily (child exited or
/// socket file gone). A daemon that's alive but refusing every tool is sick,
/// not dead — `invalidate(matching:)` re-mints it, token-scoped so a stale
/// fault from a recycled generation no-ops against the healthy successor.
actor CuaDaemonHost {
    static let shared = CuaDaemonHost()
    private var daemon: EmbeddedDaemon?
    private var minting: Task<String, Error>?
    /// Internal so lifecycle tests can observe mint/teardown without
    /// touching the non-Sendable daemon reference across the boundary.
    var minted: Bool { daemon != nil }
    /// Test seam: replaces the spawn+publish path inside `socket()` — the
    /// override's return is vended as the live socket and `daemon` stays
    /// nil, so the next `socket()` re-mints. Production leaves it nil.
    var mintOverride: (@Sendable () async throws -> String)?

    init(daemon: EmbeddedDaemon? = nil,
         mintOverride: (@Sendable () async throws -> String)? = nil) {
        self.daemon = daemon
        self.mintOverride = mintOverride
    }

    /// The shared daemon's socket — mints on first use, re-mints on death.
    /// A re-mint invalidates every proxy bound to the old socket; callers
    /// drop their dead transports and reconnect (sessions re-mint caller-side).
    func socket() async throws -> String {
        if let minting { return try await minting.value }
        if let daemon, daemon.isRunning, let socket = daemon.socketPath,
           FileManager.default.fileExists(atPath: socket) {
            return socket
        }
        let task = Task<String, Error> {
            if let mintOverride = self.mintOverride { return try await mintOverride() }
            let executable = CuaDependency.executable
            let expected = executable == CuaDependency.bundledExecutable
                ? (CuaDependency.bundledSHA256 ?? CuaDependency.executableSHA256)
                : CuaDependency.executableSHA256
            try CuaDependency.verify(executable, expectedSHA256: expected)
            guard let directory = CuaSocketDirectory.current else { throw DriverConnectionError.unavailable }
            let daemon = EmbeddedDaemon(executable: executable, directory: directory)
            try await daemon.start()
            guard let socket = daemon.socketPath else { throw DriverConnectionError.unavailable }
            self.daemon = daemon
            return socket
        }
        minting = task
        defer { minting = nil }
        return try await task.value
    }

    /// Token-scoped re-mint: `socket` is the daemon socket the faulting
    /// transport was bound to. If a re-mint already landed, a mismatched
    /// token no-ops instead of killing the healthy generation.
    func invalidate(matching socket: String) {
        guard let daemon, daemon.socketPath == socket else { return }
        self.daemon = nil
        daemon.stop()
    }

    /// Unconditional re-mint for a hung-but-alive daemon — one that holds
    /// the socket open but never answers still passes `socket()`'s liveness
    /// check (process running + socket file present is all it verifies), so
    /// callers holding dead-transport evidence force the cycle here:
    /// teardown, respawn, and the same socket-file readiness wait a normal
    /// mint pays — `socket()` does the work.
    ///
    /// Prefer `invalidate(matching:)` when the fault came tagged with its
    /// generation (the sick-daemon hook) — it can't kill a healthy
    /// successor, while this drops the current daemon no matter what. A
    /// failed re-mint is non-fatal: the host stays unminted and the next
    /// `socket()` retries lazily.
    func restartDriver() async {
        daemon?.stop()
        daemon = nil
        _ = try? await socket()
    }

    /// Ends the daemon. Sessions are caller-owned — callers end them on
    /// their own transports before calling this.
    func shutdown() {
        daemon?.stop()
        daemon = nil
    }
}
