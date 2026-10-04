import Foundation
import JevVoiceCore

/// Preserve the full tool payload: captures can carry images alongside typed metadata.
struct CuaToolResult: Sendable {
    let structured: JSONValue
    let content: [JSONValue]
}

/// A dispatched effect may exist even when Driver reports an error. Keep its
/// evidence available to the task owner without reflecting observed content in UI.
struct CuaUncertainOutcome: Error, LocalizedError, Sendable {
    let tool: String
    let result: JSONValue
    var errorDescription: String? {
        "Cua reported a partial or uncertain outcome for \(tool). An effect may have occurred; inspect the target before retrying."
    }
}

/// One persistent MCP transport shared by the runtime's tasks — the driver's
/// protected-resource grants are keyed to (session, transport, resource), so a
/// per-task transport forced the browser consent/setup surface to re-run for
/// every task. Never reconnects or retries a mutation; a dead transport is
/// replaced wholesale by the runtime, not resumed.
actor CuaConnection {
    private let executable: URL
    private let arguments: [String]
    private let onToolCall: (@Sendable (String, Int?) -> Void)?
    private var process: Process?
    /// The `serve --embedded` daemon the MCP proxy connects to when the
    /// executable resolved to the bundle-embedded driver. Its stdin is a
    /// liveness pipe: EOF after host exit shuts the daemon down.
    private var daemon: Process?
    private var daemonLiveness: FileHandle?
    private var daemonSocketPath: String?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: Task<Void, Never>?
    private var frames = MCPFrames()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var generation = UUID()
    private var initialized = false
    private(set) var serverVersion: String?
    /// A connection that completed `initialize` and whose proxy process is
    /// still alive. Lets the runtime reuse one transport across tasks.
    var connected: Bool { initialized && process?.isRunning == true }

    init(executable: URL = CuaDependency.executable,
         arguments: [String] = ["mcp"],
         onToolCall: (@Sendable (String, Int?) -> Void)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.onToolCall = onToolCall
    }

    deinit {
        reader?.cancel()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        try? daemonLiveness?.close()
        if daemon?.isRunning == true { daemon?.terminate() }
    }

    func connect() async throws {
        guard process == nil else { throw DriverConnectionError.remote("Cua connection already started.") }
        var launchArguments = arguments
        if let bundled = CuaDependency.bundledExecutable, executable == bundled {
            try CuaDependency.verify(executable, expectedSHA256: CuaDependency.executableSHA256)
            try await startEmbeddedDaemon()
            launchArguments = ["mcp", "--embedded", "--socket", daemonSocketPath ?? "",
                               "--host-bundle-id", CuaDependency.hostBundleID]
        } else if executable == CuaDependency.installedExecutable {
            try CuaDependency.verify(executable, expectedSHA256: CuaDependency.executableSHA256)
            // The daemon's existing-profile browser grant is a launch-time
            // property; reconcile before this process's first connection so a
            // later consent request never finds a grantless daemon.
            await CuaDaemonControl.ensureExistingProfileGrant()
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DriverConnectionError.unavailable }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        let token = UUID()
        generation = token
        frames = MCPFrames()
        process.executableURL = executable
        process.arguments = launchArguments
        process.standardInput = stdin
        process.standardOutput = stdout
        // Driver logs may contain observed content. Do not persist them as product history.
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { await self?.connectionEnded(token) }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        let handle = stdout.fileHandleForReading
        reader = Task.detached { [weak self] in
            while !Task.isCancelled {
                let bytes = handle.availableData
                if bytes.isEmpty { await self?.connectionEnded(token); return }
                await self?.receive(bytes, token: token)
            }
        }
        do {
            let result = try await request("initialize", params: .object([
                "protocolVersion": .string("2025-03-26"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("Jarvis"), "version": .string("1")])
            ]))
            guard let version = result["protocolVersion"]?.string,
                  ["2024-11-05", "2025-03-26", "2025-06-18"].contains(version),
                  result["capabilities"]?["tools"]?.object != nil else { throw DriverConnectionError.malformed }
            serverVersion = result["serverInfo"]?["version"]?.string
            try write(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
            initialized = true
        } catch {
            disconnect(error)
            throw error
        }
    }

    func call(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval = 30) async throws -> JSONValue {
        try await callResult(name, arguments: arguments, timeout: timeout).structured
    }

    func tools() async throws -> [JSONValue] {
        guard initialized else { throw DriverConnectionError.closed }
        var result: [JSONValue] = [], cursors = Set<String>()
        var cursor: String?
        repeat {
            let page = try await request("tools/list", params: .object(cursor.map { ["cursor": .string($0)] } ?? [:]))
            guard let tools = page["tools"]?.array,
                  tools.allSatisfy({ $0["name"]?.string != nil && $0["inputSchema"]?.object != nil }) else {
                throw DriverConnectionError.malformed
            }
            result.append(contentsOf: tools)
            if let next = page["nextCursor"], next != .null {
                guard let next = next.string, !next.isEmpty, cursors.insert(next).inserted else {
                    throw DriverConnectionError.malformed
                }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        return result
    }

    /// Reads dispatch no GUI effect, so a transient fault inside the driver is
    /// safe to retry once — mutations are never retried since an effect may
    /// already exist on the target.
    private static let readOnlyTools: Set<String> = [
        "list_apps", "list_windows", "list_sessions", "get_window_state",
        "get_desktop_state", "get_browser_state", "get_accessibility_tree",
        "get_session", "get_session_state", "get_config", "get_recording_state",
        "get_agent_cursor_state", "get_cursor_position", "get_screen_size",
        "health_report", "check_permissions", "check_for_update",
        "clipboard_read", "parse_visual_regions", "verify_state", "page"
    ]

    private static func transientReadFault(_ error: Error) -> Bool {
        switch error as? DriverConnectionError {
        case .timedOut, .remote, .malformed: return true
        case .toolRefused(_, let code): return code == "tool_invocation_failed"
        default: return false
        }
    }

    func callResult(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval = 30) async throws -> CuaToolResult {
        guard initialized else { throw DriverConnectionError.closed }
        try Task.checkCancellation()
        onToolCall?(name, arguments["text"]?.string?.count)
        var attempts = Self.readOnlyTools.contains(name) ? 4 : 1
        var backoff: Duration = .milliseconds(400)
        while true {
            attempts -= 1
            do {
                return try await callResultOnce(name, arguments: arguments, timeout: timeout)
            } catch let error as DriverConnectionError where attempts > 0 && Self.transientReadFault(error) {
                // A daemon waking alongside the machine stalls in steps —
                // bounded backoff covers seconds of it, never a mutation.
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(2))
            }
        }
    }

    private func callResultOnce(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval) async throws -> CuaToolResult {
        let value = try await request("tools/call", params: .object([
            "name": .string(name), "arguments": .object(arguments)
        ]), timeout: timeout)
        if let body = value["structuredContent"],
           body["status"] == .string("partial") || ["partial", "indeterminate"].contains(body["effect"]?.string ?? "") || body["execution_state"] == .string("unknown") {
            throw CuaUncertainOutcome(tool: name, result: body)
        }
        // Retain typed refusal codes without reflecting arbitrary tool/page text into error UI.
        let code = value["structuredContent"]?["refusal"]?["code"]?.string
            ?? value["structuredContent"]?["code"]?.string ?? ""
        let safeCode = !code.isEmpty && code.count <= 80 && code.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }
        if value["isError"] == .bool(true) {
            if safeCode { throw DriverConnectionError.toolRefused(tool: name, code: code) }
            throw DriverConnectionError.remote("Cua could not complete \(name)\(safeCode ? " (" + code + ")" : ""). Inspect the target before retrying.")
        }
        guard let body = value["structuredContent"], body.object != nil else { throw DriverConnectionError.malformed }
        guard body["code"] != .string("tool_output_invalid") else { throw DriverConnectionError.malformed }
        if body["status"] == .string("refused") || body["effect"] == .string("refused") || body["refusal"] != nil {
            if safeCode { throw DriverConnectionError.toolRefused(tool: name, code: code) }
            throw DriverConnectionError.refused(body["refusal"]?["message"]?.string ?? "Cua refused this action.")
        }
        guard value["content"] == nil || value["content"]?.array != nil else { throw DriverConnectionError.malformed }
        return CuaToolResult(structured: body, content: value["content"]?.array ?? [])
    }

    func close() { disconnect(DriverConnectionError.closed) }

    /// Spawns `serve --embedded` as a direct child so the driver stays in this
    /// app's TCC responsibility chain — grants attribute to Jev Voice, never
    /// to a second CuaDriver identity. Mirrors the driver's documented host
    /// contract: private socket, liveness stdin pipe, host attribution env.
    private func startEmbeddedDaemon() async throws {
        let socket = Self.embeddedSocketPath()
        try? FileManager.default.removeItem(atPath: socket)
        // Env allowlist only — never inherit host secrets or ambient
        // CUA_DRIVER_* vars (an exported DANGEROUSLY_BYPASS_APPROVALS would
        // break startup; the SDK's env_clear + allowlist contract).
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "SHELL",
                    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "__CF_USER_TEXT_ENCODING"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        environment["CUA_DRIVER_EMBEDDED"] = "1"
        environment["CUA_DRIVER_HOST_BUNDLE_ID"] = CuaDependency.hostBundleID
        environment["CUA_DRIVER_EMBEDDED_HOST_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
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
        daemonLiveness = liveness.fileHandleForWriting
        daemonSocketPath = socket
        let deadline = Date().addingTimeInterval(10)
        while daemon.isRunning && !FileManager.default.fileExists(atPath: socket) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard daemon.isRunning, FileManager.default.fileExists(atPath: socket) else {
            stopEmbeddedDaemon()
            throw DriverConnectionError.unavailable
        }
    }

    private static func embeddedSocketPath() -> String {
        let name = "jev-cua-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let preferred = NSTemporaryDirectory() + name
        // Unix socket paths are limited to ~104 bytes.
        return preferred.utf8.count < 96 ? preferred : "/tmp/" + name
    }

    private func stopEmbeddedDaemon() {
        if daemon?.isRunning == true { daemon?.terminate() }
        daemon = nil
        try? daemonLiveness?.close()
        daemonLiveness = nil
        if let socket = daemonSocketPath {
            try? FileManager.default.removeItem(atPath: socket)
            daemonSocketPath = nil
        }
    }

    private func request(_ method: String, params: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw DriverConnectionError.closed }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try write(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                       "method": .string(method), "params": params]))
                    deadlines[id] = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                        await self?.cancel(id, error: DriverConnectionError.timedOut)
                    }
                } catch { complete(id, result: .failure(error)) }
            }
        } onCancel: {
            Task { await self.cancel(id, error: CancellationError()) }
        }
    }

    private func write(_ message: JSONValue) throws {
        guard let input else { throw DriverConnectionError.closed }
        var data = try JSONEncoder().encode(message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ bytes: Data, token: UUID) {
        guard token == generation else { return }
        do {
            for message in try frames.append(bytes) {
                // This client advertises no server-request capabilities.
                if message["method"] != nil {
                    if let id = message["id"] {
                        try write(.object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .number(-32601), "message": .string("Method not supported")])]))
                    }
                    continue
                }
                guard let id = message["id"]?.integer else { throw DriverConnectionError.malformed }
                if message["error"] != nil {
                    complete(id, result: .failure(DriverConnectionError.remote("Cua rejected the request.")))
                } else if let result = message["result"] {
                    complete(id, result: .success(result))
                } else { throw DriverConnectionError.malformed }
            }
        } catch { disconnect(error) }
    }

    private func cancel(_ id: Int, error: Error) {
        guard pending[id] != nil else { return }
        try? write(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                           "params": .object(["requestId": .number(Double(id)), "reason": .string("Cancelled")])]))
        complete(id, result: .failure(error))
        // Cancellation is not evidence that an already-dispatched GUI effect stopped.
        // Task owner must end its Driver session and reobserve any uncertain action.
    }

    private func complete(_ id: Int, result: Result<JSONValue, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func connectionEnded(_ token: UUID) {
        guard token == generation else { return }
        disconnect(DriverConnectionError.closed)
    }

    private func disconnect(_ error: Error) {
        generation = UUID()
        initialized = false
        for id in Array(pending.keys) { complete(id, result: .failure(error)) }
        reader?.cancel(); reader = nil
        try? input?.close(); input = nil
        if process?.isRunning == true { process?.terminate() }
        process?.terminationHandler = nil
        process = nil
        // Closing a FileHandle while another thread reads it can raise an ObjC exception.
        // Child exit closes the write side, unblocking the reader which owns its handle.
        output = nil
        stopEmbeddedDaemon()
    }
}
