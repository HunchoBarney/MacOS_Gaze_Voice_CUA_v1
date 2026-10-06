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
    /// The `serve --embedded` daemon this transport spawned itself. Its
    /// stdin is a liveness pipe: EOF after host exit shuts the daemon
    /// down. Pool transports spawn proxies only — CuaConnectionPool owns
    /// the shared daemon and its socket.
    private var embeddedDaemon: CuaEmbeddedDaemon?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: Task<Void, Never>?
    private var frames = MCPFrames()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var generation = UUID()
    private var initialized = false
    /// Check/set must happen before connect() first suspends — without it a
    /// second connect spawns a second daemon, overwrites `process`, and the
    /// first caller's teardown kills the live transport.
    private var connectInFlight = false
    /// When set, `connect()` proxies onto this shared daemon's socket
    /// instead of spawning a `serve --embedded` child — the pool path for
    /// per-lane transports that never owned a daemon in the first place.
    private let socketProvider: (@Sendable () async throws -> String)?
    /// A read-only call that burns its whole retry budget on daemon
    /// refusals means the daemon itself is sick — alive, answering, and
    /// refusing every tool. Fired once per storm so the pool can re-mint
    /// the daemon; a live-but-refusing daemon never heals on its own.
    private let onDaemonHealthFault: (@Sendable () -> Void)?
    /// Scoped variant of the same fault — carries the daemon socket this
    /// transport was bound to so the pool can no-op a stale fault aimed
    /// at a daemon generation it already recycled.
    private let onDaemonSocketFault: (@Sendable (String) -> Void)?
    /// The daemon socket this transport's proxy was bound to — the token
    /// handed to `onDaemonSocketFault`, and the pool's key for closing
    /// only proxies bound to a recycled daemon.
    private(set) var boundSocket: String?
    /// A wedged daemon can hold the socket open and never answer — two
    /// consecutive request timeouts mark the transport dead rather than
    /// letting every later call burn a full timeout forever.
    private var consecutiveTimeouts = 0
    private(set) var serverVersion: String?
    /// A connection that completed `initialize` and whose proxy process is
    /// still alive. Lets the runtime reuse one transport across tasks.
    var connected: Bool { initialized && process?.isRunning == true }

    /// Live transports across the whole process — daemon-wide decisions
    /// (grant reconcile, shared-daemon teardown) consult it before
    /// restarting anything that would tombstone live sessions.
    private static let live = LiveConnections()
    static var liveConnectionCount: Int { live.count }

    /// Object-identity set behind a lock — touched from actor teardown and
    /// deinit alike.
    private final class LiveConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var members = Set<ObjectIdentifier>()
        var count: Int { lock.lock(); defer { lock.unlock() }; return members.count }
        func add(_ member: CuaConnection) {
            lock.lock(); members.insert(ObjectIdentifier(member)); lock.unlock()
        }
        func remove(_ member: CuaConnection) {
            lock.lock(); members.remove(ObjectIdentifier(member)); lock.unlock()
        }
    }

    init(executable: URL = CuaDependency.executable,
         arguments: [String] = ["mcp"],
         onToolCall: (@Sendable (String, Int?) -> Void)? = nil,
         socketProvider: (@Sendable () async throws -> String)? = nil,
         onDaemonHealthFault: (@Sendable () -> Void)? = nil,
         onDaemonSocketFault: (@Sendable (String) -> Void)? = nil) {
        // A write to a just-dead proxy raises SIGPIPE, whose default
        // disposition kills the process — ignore it once so EPIPE surfaces
        // as a thrown error instead of an app crash.
        signal(SIGPIPE, SIG_IGN)
        self.executable = executable
        self.arguments = arguments
        self.onToolCall = onToolCall
        self.socketProvider = socketProvider
        self.onDaemonHealthFault = onDaemonHealthFault
        self.onDaemonSocketFault = onDaemonSocketFault
    }

    deinit {
        reader?.cancel()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
        embeddedDaemon?.stop()
        Self.live.remove(self)
    }

    func connect() async throws {
        // Set before the first suspension — the daemon-spawn and grant
        // awaits below are seconds long, and a second connect entering that
        // window would spawn a duplicate and clobber this one's transport.
        guard process == nil, !connectInFlight else {
            throw DriverConnectionError.remote("Cua connection already started.")
        }
        connectInFlight = true
        defer { connectInFlight = false }
        // Pool-bound transports never mint a daemon — resolve the shared
        // socket and spawn only the proxy (same path as connect(proxyOnlyOn:)).
        if let socketProvider {
            if let bundled = CuaDependency.bundledExecutable, executable == bundled {
                try CuaDependency.verify(executable, expectedSHA256: CuaDependency.bundledSHA256 ?? CuaDependency.executableSHA256)
            } else if executable == CuaDependency.installedExecutable {
                // Same pin the standalone path enforces — the proxy spawns
                // this binary directly, bundled or not.
                try CuaDependency.verify(executable, expectedSHA256: CuaDependency.executableSHA256)
            }
            let socket = try await socketProvider()
            boundSocket = socket
            try await startProxy(launchArguments: ["mcp", "--embedded", "--socket", socket,
                                                   "--host-bundle-id", CuaDependency.hostBundleID])
            return
        }
        var launchArguments = arguments
        if let bundled = CuaDependency.bundledExecutable, executable == bundled {
            try CuaDependency.verify(executable, expectedSHA256: CuaDependency.bundledSHA256 ?? CuaDependency.executableSHA256)
            try await startEmbeddedDaemon()
            boundSocket = embeddedDaemon?.socketPath
            launchArguments = ["mcp", "--embedded", "--socket", embeddedDaemon?.socketPath ?? "",
                               "--host-bundle-id", CuaDependency.hostBundleID]
        } else if executable == CuaDependency.installedExecutable {
            try CuaDependency.verify(executable, expectedSHA256: CuaDependency.executableSHA256)
        }
        try await startProxy(launchArguments: launchArguments)
    }

    /// Pool path — CuaConnectionPool owns the shared embedded daemon and
    /// its socket; this transport spawns only its own `mcp --embedded`
    /// proxy onto it. Same single-flight, handshake, and teardown contract
    /// as connect(); session mint stays caller-side.
    func connect(proxyOnlyOn socket: String) async throws {
        guard process == nil, !connectInFlight else {
            throw DriverConnectionError.remote("Cua connection already started.")
        }
        connectInFlight = true
        defer { connectInFlight = false }
        // The proxy is the same pinned binary — verify before spawning even
        // though the daemon itself is pool-owned.
        if let bundled = CuaDependency.bundledExecutable, executable == bundled {
            try CuaDependency.verify(executable, expectedSHA256: CuaDependency.bundledSHA256 ?? CuaDependency.executableSHA256)
        } else if executable == CuaDependency.installedExecutable {
            try CuaDependency.verify(executable, expectedSHA256: CuaDependency.executableSHA256)
        }
        boundSocket = socket
        try await startProxy(launchArguments: ["mcp", "--embedded", "--socket", socket,
                                               "--host-bundle-id", CuaDependency.hostBundleID])
    }

    /// Spawn the stdio proxy and run the MCP initialize handshake. Split
    /// from daemon spawn so the pool can attach many proxies to one socket.
    private func startProxy(launchArguments: [String]) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DriverConnectionError.unavailable }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        let token = UUID()
        generation = token
        frames = MCPFrames()
        consecutiveTimeouts = 0
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
        Self.live.add(self)
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
            try await write(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
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

    /// `page` is polymorphic: get_text/query_dom read, while
    /// execute_javascript / click_element / insert_text / type_keystrokes /
    /// enable_javascript_apple_events mutate (behind the driver's legacy-
    /// mutations env). Only the two read actions earn a retry.
    private static let pageReadActions: Set<String> = ["get_text", "query_dom"]

    static func isReadOnly(_ name: String, arguments: [String: JSONValue]) -> Bool {
        guard readOnlyTools.contains(name) else { return false }
        if name == "page" {
            return pageReadActions.contains(arguments["action"]?.string ?? "")
        }
        return true
    }

    /// Only genuinely transient faults earn a retry: `.timedOut` plus
    /// transport-level failures (tool_invocation_failed, closed). A
    /// deterministic JSON-RPC rejection (.remote) or bad envelope
    /// (.malformed) never succeeds on retry — retrying one burned ~4
    /// calls and seconds of backoff for nothing.
    static func transientReadFault(_ error: Error) -> Bool {
        switch error as? DriverConnectionError {
        case .timedOut, .closed: return true
        case .toolRefused(_, let code, _): return code == "tool_invocation_failed"
        default: return false
        }
    }

    /// Mutations inside an already-bound window pay a post-action
    /// observation window in the driver. The daemon-level tail is sized by
    /// `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS`/`CUA_DRIVER_WINDOW_CHANGE_POLL_MS`
    /// on the embedded spawn (see CuaConnectionPool) — per-call arguments are
    /// NOT a safe channel: tool schemas are `additionalProperties:false`, so
    /// an extra arg fails validation as `invalid_arguments` before the typed
    /// projection can drop it.
    func callResult(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval = 30) async throws -> CuaToolResult {
        guard initialized else { throw DriverConnectionError.closed }
        try Task.checkCancellation()
        onToolCall?(name, arguments["text"]?.string?.count)
        let arguments = arguments
        var attempts = Self.isReadOnly(name, arguments: arguments) ? 4 : 1
        var backoff: Duration = .milliseconds(400)
        while true {
            attempts -= 1
            do {
                let result = try await callResultOnce(name, arguments: arguments, timeout: timeout)
                consecutiveTimeouts = 0
                return result
            } catch let error as DriverConnectionError {
                if case .timedOut = error { noteTimeout() }
                guard attempts > 0, Self.transientReadFault(error) else {
                    // A READ that exhausted its retries on daemon refusals is
                    // a sick-daemon storm — four consecutive
                    // tool_invocation_failed answers, not a slow transport:
                    // a fresh proxy on the same daemon would refuse
                    // identically. Kill this transport so the next call
                    // re-mints it, and tell the pool's owner to recycle the
                    // daemon itself. A single refusal on a mutation is a
                    // real tool error, never a storm. Only refusals count:
                    // a wedged local proxy or a slow daemon exhausts on
                    // .timedOut/.closed — noteTimeout already tore the
                    // transport down and the caller re-mints; recycling the
                    // shared daemon for that would kill every other lane's
                    // healthy proxies.
                    if Self.isReadOnly(name, arguments: arguments),
                       case .toolRefused(_, let code, _) = error,
                       code == "tool_invocation_failed" {
                        let socket = boundSocket
                        disconnect(DriverConnectionError.closed)
                        onDaemonHealthFault?()
                        onDaemonSocketFault?(socket ?? "")
                    }
                    throw error
                }
                // A daemon waking alongside the machine stalls in steps —
                // bounded backoff covers seconds of it, never a mutation.
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(2))
            }
        }
    }

    /// Two consecutive timeouts is a dead transport, not a slow one — tear it
    /// down so callers get `.closed` and the runtime replaces it wholesale.
    private func noteTimeout() {
        consecutiveTimeouts += 1
        if consecutiveTimeouts >= 2 {
            disconnect(DriverConnectionError.closed)
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
        // The daemon's own reason lives in refusal.message or the text block —
        // without it every distinct refusal collapses into the bare code.
        let detail = value["structuredContent"]?["refusal"]?["message"]?.string
            ?? value["content"]?.array?.compactMap { $0["text"]?.string }.first ?? ""
        let safeCode = !code.isEmpty && code.count <= 80 && code.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }
        if value["isError"] == .bool(true) {
            if safeCode { throw DriverConnectionError.toolRefused(tool: name, code: code, detail: detail) }
            throw DriverConnectionError.remote("Cua could not complete \(name)\(safeCode ? " (" + code + ")" : ""). Inspect the target before retrying.")
        }
        guard let body = value["structuredContent"], body.object != nil else { throw DriverConnectionError.malformed }
        guard body["code"] != .string("tool_output_invalid") else { throw DriverConnectionError.malformed }
        if body["status"] == .string("refused") || body["effect"] == .string("refused") || body["refusal"] != nil {
            if safeCode { throw DriverConnectionError.toolRefused(tool: name, code: code, detail: detail) }
            throw DriverConnectionError.refused(body["refusal"]?["message"]?.string ?? "Cua refused this action.")
        }
        guard value["content"] == nil || value["content"]?.array != nil else { throw DriverConnectionError.malformed }
        let content = value["content"]?.array ?? []
        // The detector only appends window-change data to action results —
        // reads skip the text-block JSON probe, which otherwise decodes (and
        // brace-scans) every snapshot's tree_markdown for nothing.
        let merged = Self.isReadOnly(name, arguments: arguments)
            ? body : Self.mergeWindowChanges(body, content: content)
        return CuaToolResult(structured: merged, content: content)
    }

    /// The driver's WindowChangeDetector appends `changes.new_windows` /
    /// `new_window_ids` to the action result's TEXT block — structuredContent
    /// doesn't carry it, so it was silently discarded. Merge those keys
    /// upward (top level or under `changes`) so callers can skip a
    /// list_windows re-poll; existing structured keys always win.
    static func mergeWindowChanges(_ body: JSONValue, content: [JSONValue]) -> JSONValue {
        guard var object = body.object,
              object["new_windows"] == nil, object["new_window_ids"] == nil else { return body }
        for block in content {
            // Both merge keys share the `new_window` prefix — a block without
            // it can only cost a failed decode, so skip it before parsing.
            guard let text = block["text"]?.string, text.contains("new_window"),
                  let extra = decodeJSONObject(in: text)?.object else { continue }
            for key in ["new_windows", "new_window_ids"] where object[key] == nil {
                object[key] = extra[key] ?? extra["changes"]?[key]
            }
            if object["new_windows"] != nil || object["new_window_ids"] != nil { break }
        }
        return .object(object)
    }

    private static func decodeJSONObject(in text: String) -> JSONValue? {
        func decode(_ string: String) -> JSONValue? {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)),
                  value.object != nil else { return nil }
            return value
        }
        if let value = decode(text) { return value }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
        else { return nil }
        return decode(String(text[start...end]))
    }

    func close() { disconnect(DriverConnectionError.closed) }

    /// Spawns `serve --embedded` as a direct child so the driver stays in this
    /// app's TCC responsibility chain — grants attribute to Jev Voice, never
    /// to a second CuaDriver identity. Mirrors the driver's documented host
    /// contract: private socket, liveness stdin pipe, host attribution env.
    private func startEmbeddedDaemon() async throws {
        let daemon = CuaEmbeddedDaemon(executable: executable)
        try await daemon.start()
        embeddedDaemon = daemon
    }

    private func stopEmbeddedDaemon() {
        embeddedDaemon?.stop()
        embeddedDaemon = nil
    }

    private func request(_ method: String, params: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw DriverConnectionError.closed }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                // Writes serialize through the actor — a request queued
                // behind a slow dispatch must not burn its deadline before
                // it is even sent, so the deadline arms at WRITE time. It
                // still lands BEFORE the blocking write itself: a write
                // that never returns (full pipe, wedged daemon) must still
                // let the timeout fire the request's owner.
                Task { [weak self] in
                    guard let self else { return }
                    guard await self.armDeadline(id, timeout: timeout) else { return }
                    do {
                        try await self.write(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                           "method": .string(method), "params": params]))
                    } catch { await self.complete(id, result: .failure(error)) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id, error: CancellationError()) }
        }
    }

    /// Arms the timeout — returns false when the request is already gone
    /// (cancelled or the transport torn down) so a stale write never ships.
    private func armDeadline(_ id: Int, timeout: TimeInterval) -> Bool {
        guard pending[id] != nil else { return false }
        deadlines[id]?.cancel()
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            await self?.cancel(id, error: DriverConnectionError.timedOut)
        }
        return true
    }

    /// Chains detached writes FIFO — the actor alone does NOT serialize them:
    /// a request blocked in `write` suspends, and a later write (another
    /// queued request, a cancel notification, a method-not-supported reply)
    /// would run its own detached block concurrently and could interleave
    /// bytes on the pipe. Each write awaits its predecessor so exactly one
    /// blocking syscall touches the handle at a time.
    private var writeTail: Task<Void, Never>?

    /// FileHandle.write is a blocking syscall — on the actor executor a full
    /// pipe would wedge every request, deadline, and disconnect behind it,
    /// so the syscall runs off-actor behind the write tail. Order is
    /// preserved while the timeout machinery stays reachable.
    private func write(_ message: JSONValue) async throws {
        guard let input else { throw DriverConnectionError.closed }
        var data = try JSONEncoder().encode(message)
        data.append(10)
        let prior = writeTail
        let write = Task.detached {
            _ = await prior?.value
            try input.write(contentsOf: data)
        }
        writeTail = Task { _ = try? await write.value }
        try await write.value
    }

    private func receive(_ bytes: Data, token: UUID) {
        guard token == generation else { return }
        do {
            for message in try frames.append(bytes) {
                // This client advertises no server-request capabilities.
                if message["method"] != nil {
                    if let id = message["id"] {
                        Task { [weak self] in
                            try? await self?.write(.object(["jsonrpc": .string("2.0"), "id": id,
                                "error": .object(["code": .number(-32601), "message": .string("Method not supported")])]))
                        }
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
        // The stdio proxy drops notifications — this documents intent only;
        // the daemon still runs the dispatched action to completion.
        Task { [weak self] in
            try? await self?.write(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/cancelled"),
                                "params": .object(["requestId": .number(Double(id)), "reason": .string("Cancelled")])]))
        }
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
        Self.live.remove(self)
        for id in Array(pending.keys) { complete(id, result: .failure(error)) }
        reader?.cancel(); reader = nil
        // Close behind the write tail: closing a FileHandle mid-write can
        // raise an ObjC exception, and the child exit below fails any
        // blocked write so the deferred close always runs.
        if let input {
            let prior = writeTail
            Task { _ = await prior?.value; try? input.close() }
            self.input = nil
            writeTail = nil
        }
        if process?.isRunning == true { process?.terminate() }
        process?.terminationHandler = nil
        process = nil
        // Closing a FileHandle while another thread reads it can raise an ObjC exception.
        // Child exit closes the write side, unblocking the reader which owns its handle.
        output = nil
        boundSocket = nil
        stopEmbeddedDaemon()
    }
}
