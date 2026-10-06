import Foundation
import JevVoiceCore

/// The `serve --embedded` child — spawned as a direct descendant so the
/// driver stays in this app's TCC responsibility chain (grants attribute to
/// Jev Voice, never a second CuaDriver identity). Owns the private socket
/// path and the liveness stdin pipe: EOF after host exit shuts the daemon
/// down. A standalone CuaConnection owns one per connect(); the pool owns a
/// single shared one. Not an actor — each owner serializes its own
/// start/stop calls.
final class CuaEmbeddedDaemon {
    private let executable: URL
    private var daemon: Process?
    private var liveness: FileHandle?
    private(set) var socketPath: String?
    var isRunning: Bool { daemon?.isRunning == true }

    init(executable: URL) {
        self.executable = executable
    }

    /// Mirrors the driver's documented host contract: private socket,
    /// liveness stdin pipe, host attribution env.
    func start() async throws {
        let socket = Self.makeSocketPath()
        try? FileManager.default.removeItem(atPath: socket)
        // Env allowlist only — never inherit host secrets or ambient
        // CUA_DRIVER_* vars (an exported DANGEROUSLY_BYPASS_APPROVALS would
        // break startup; the SDK's env_clear + allowlist contract). The
        // upstream CUA_DRIVER_RS_MCP_HTTP_PORT front-end stays off —
        // per-connection proxies on this socket are the sanctioned path.
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "SHELL",
                    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "__CF_USER_TEXT_ENCODING"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        environment["CUA_DRIVER_EMBEDDED"] = "1"
        environment["CUA_DRIVER_HOST_BUNDLE_ID"] = CuaDependency.hostBundleID
        environment["CUA_DRIVER_EMBEDDED_HOST_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
        // The stock 0.32.0 driver reads the post-mutation observation
        // window from its environment. The default is a fixed 1000ms —
        // the dominant per-dispatch tax we measured in production
        // (~1.4s clicks). 300ms keeps the window-diff + focus-suppression
        // coverage that launch/menu calls need while shrinking the tail
        // ~3x on every bound-window mutation; calls that can spawn UI
        // slower than that are re-observed by our own polls anyway.
        // Daemon-level only — proxies inherit behavior from the daemon.
        environment["CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS"] = "300"
        environment["CUA_DRIVER_WINDOW_CHANGE_POLL_MS"] = "50"
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
        // JARVIS_DRIVER_STDERR redirects stderr for diagnostics only.
        daemon.standardOutput = FileHandle.nullDevice
        if let logPath = ProcessInfo.processInfo.environment["JARVIS_DRIVER_STDERR"] {
            _ = FileManager.default.createFile(atPath: logPath, contents: nil)
            daemon.standardError = FileHandle(forWritingAtPath: logPath) ?? FileHandle.nullDevice
        } else {
            daemon.standardError = FileHandle.nullDevice
        }
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
            // A cancelled readiness wait must not strand the spawned
            // daemon — without stop() it outlives the dropped wrapper
            // until liveness-stdin EOF and leaks the socket file.
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

    private static func makeSocketPath() -> String {
        let name = "jev-cua-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let preferred = NSTemporaryDirectory() + name
        // Unix socket paths are limited to ~104 bytes.
        return preferred.utf8.count < 96 ? preferred : "/tmp/" + name
    }
}

/// Many lanes, one daemon — the `serve --embedded` child serves N
/// connections concurrently (documented upstream design), so every label
/// gets its own `mcp --embedded` proxy on the pool's shared socket instead
/// of each spawning a daemon.
///
/// Failure contract: a dead single proxy re-mints just its proxy; a dead
/// DAEMON (socket gone or child exited) re-mints the daemon lazily on next
/// use and drops every existing proxy — they were bound to the removed
/// socket. Session mint (start_session, cursor policy) stays caller-side:
/// the pool hands out a CONNECTED transport only.
@MainActor
final class CuaConnectionPool {
    /// The app-wide pool — voice tasks and agents all proxy onto this one
    /// daemon, so N lanes cost N light proxies, not N driver processes.
    static let shared = CuaConnectionPool()
    private let executable: URL
    private var daemon: CuaEmbeddedDaemon?
    private var daemonStart: Task<String, Error>?
    private var connections: [String: CuaConnection] = [:]
    private var connectionTasks: [String: Task<CuaConnection, Error>] = [:]

    init(executable: URL = CuaDependency.executable) {
        self.executable = executable
    }

    /// The shared daemon's socket — nil until the first connection mints
    /// it. Diagnostics/test seam.
    var socketPath: String? { daemon?.socketPath }

    /// The shared daemon's socket for transports that manage their own
    /// proxy (the `socketProvider` init path). Minting/re-minting the
    /// daemon is identical to `connection(label:)` — a re-mint kills every
    /// extant proxy, which each transport's own reconnect handles.
    func socket() async throws -> String {
        try await sharedSocket()
    }

    /// A live connected transport for `label` on the shared daemon. First
    /// use spawns the daemon; later uses spawn only a fresh proxy on the
    /// same socket. Two callers racing one label share a single mint.
    func connection(label: String) async throws -> CuaConnection {
        if let inFlight = connectionTasks[label] { return try await inFlight.value }
        let task = Task { () throws -> CuaConnection in
            // Daemon first — if it died, every minted proxy is bound to a
            // removed socket and must re-mint, not be reused.
            let socket = try await self.sharedSocket()
            if let existing = self.connections[label] {
                if await existing.connected { return existing }
                await existing.close()
                self.connections[label] = nil
            }
            // The fault token is the socket the proxy binds to — a stale
            // storm report against an already-recycled daemon no-ops in
            // invalidateDaemon(matching:).
            let connection = CuaConnection(executable: self.executable,
                                           onDaemonSocketFault: { socket in
                                               Task { await self.invalidateDaemon(matching: socket) }
                                           })
            try await connection.connect(proxyOnlyOn: socket)
            self.connections[label] = connection
            return connection
        }
        connectionTasks[label] = task
        defer { connectionTasks[label] = nil }
        return try await task.value
    }

    /// A daemon that answers MCP but refuses every tool is sick, not dead —
    /// `isRunning` and the socket file both pass, so nothing would ever
    /// re-mint it. Called when a read-only call burns its whole retry budget
    /// on `tool_invocation_failed`: stop the daemon and drop every proxy
    /// bound to its socket so the next sharedSocket() mints a fresh one.
    func invalidateDaemon() async {
        await invalidateDaemon(matching: nil)
    }

    /// Token-scoped invalidation — `socket` is the daemon socket the faulting
    /// transport was bound to, delivered through `onDaemonHealthFault`. Two
    /// lanes storming on generation N queue two faults; if a re-mint lands
    /// between them the second must not stop the healthy generation N+1, so a
    /// mismatched token no-ops. nil = unscoped, every proxy is recycled.
    func invalidateDaemon(matching socket: String?) async {
        guard let victim = daemon, socket == nil || victim.socketPath == socket else { return }
        // Detach before the first suspension — a sharedSocket() entering
        // mid-drain must mint a fresh daemon, never fast-path onto the
        // doomed socket.
        daemon = nil
        // In-flight mints must land before the snapshot: one resolving on
        // the doomed socket would otherwise store a zombie proxy onto a
        // dead daemon after the drain and hand it to a caller.
        for task in connectionTasks.values { _ = try? await task.value }
        let stale = connections
        connections = [:]
        for (label, connection) in stale {
            // A proxy minted on a fresh daemon during the drain stays live.
            if let socket, await connection.boundSocket != socket {
                if connections[label] == nil { connections[label] = connection }
                continue
            }
            await connection.close()
        }
        victim.stop()
    }

    /// Ends every label's session and tears down the shared daemon. Not a
    /// tombstone — a later connection() lazily re-mints the daemon.
    func shutdown() async {
        // In-flight mints must land before draining or their transports
        // would leak past the teardown.
        for task in connectionTasks.values { _ = try? await task.value }
        let all = connections
        connections = [:]
        for (label, connection) in all {
            _ = try? await connection.call("end_session", arguments: ["session": .string(label)], timeout: 5)
            await connection.close()
        }
        daemon?.stop()
        daemon = nil
    }

    /// The shared daemon's socket, spawning it on first use and lazily
    /// re-minting when it dies. A re-mint invalidates every existing proxy,
    /// so the live-connection map is cleared alongside.
    private func sharedSocket() async throws -> String {
        if let inFlight = daemonStart { return try await inFlight.value }
        let task = Task { () throws -> String in
            if let daemon = self.daemon, daemon.isRunning, let socket = daemon.socketPath,
               FileManager.default.fileExists(atPath: socket) {
                return socket
            }
            let stale = self.connections
            self.connections = [:]
            for connection in stale.values { await connection.close() }
            self.daemon?.stop()
            if self.executable == CuaDependency.bundledExecutable {
                try CuaDependency.verify(self.executable,
                    expectedSHA256: CuaDependency.bundledSHA256 ?? CuaDependency.executableSHA256)
            } else if self.executable == CuaDependency.installedExecutable {
                // Dev/unpackaged runs spawn the installed binary as the
                // pool daemon — same pin as the standalone path.
                try CuaDependency.verify(self.executable, expectedSHA256: CuaDependency.executableSHA256)
            }
            let daemon = CuaEmbeddedDaemon(executable: self.executable)
            try await daemon.start()
            self.daemon = daemon
            guard let socket = daemon.socketPath else { throw DriverConnectionError.unavailable }
            return socket
        }
        daemonStart = task
        defer { daemonStart = nil }
        return try await task.value
    }
}
