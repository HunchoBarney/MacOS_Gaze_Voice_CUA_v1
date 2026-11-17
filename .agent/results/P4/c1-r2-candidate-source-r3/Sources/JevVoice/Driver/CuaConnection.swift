import Foundation
import JevVoiceCore

struct CuaResultOrigin: Sendable, Equatable {
    let session: String?
    let daemonSocket: String
    var transport: UUID? = nil
    var sessionEpoch: UUID? = nil
}

struct CuaSessionEpochs {
    private var epochs: [String: UUID] = [:]

    func current(_ session: String?) -> UUID? { session.flatMap { epochs[$0] } }

    mutating func willCall(_ name: String, session: String?) -> UUID? {
        guard let session else { return nil }
        if epochs[session] == nil || ["start_session", "end_session"].contains(name) {
            epochs[session] = UUID()
        }
        return epochs[session]
    }
}

typealias CuaScopedCall = @Sendable (
    String, [String: JSONValue], CuaResultOrigin?
) async throws -> CuaToolResult

/// Preserve the full tool payload: captures can carry images alongside typed metadata.
struct CuaToolResult: Sendable {
    let structured: JSONValue
    let content: [JSONValue]
    var origin: CuaResultOrigin? = nil
    var capturedElementTools: Set<String> = []
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

actor CuaDispatchPacing {
    typealias Load = @Sendable () async throws -> [JSONValue]
    typealias Configure = @Sendable ([String: JSONValue]) async throws -> JSONValue

    private var generation: UUID?
    private var definitions: Task<[JSONValue], Error>?
    private var preparations: [UUID: Task<Void, Error>] = [:]

    static func requested(_ name: String, _ arguments: [String: JSONValue]) -> Bool {
        ["click", "double_click", "type_text", "scroll", "set_value"].contains(name)
            && arguments["post_action_wait"] == .string("none")
            && arguments["capture_id"] == nil
            && (arguments["pid"]?.integer ?? 0) > 0
            && (arguments["window_id"]?.integer ?? 0) > 0
            && arguments["element_token"]?.string?.isEmpty == false
            && arguments["session"]?.string?.isEmpty == false
            && arguments["session"] != .string("default")
    }

    func tools(generation: UUID, load: @escaping Load) async throws -> [JSONValue] {
        try Task.checkCancellation()
        if self.generation != generation {
            self.generation = generation
            definitions = nil
            preparations = [:]
        }
        if definitions == nil { definitions = Task { try await load() } }
        let result = try await definitions!.value
        guard self.generation == generation else { throw DriverConnectionError.closed }
        try Task.checkCancellation()
        return result
    }

    func arguments(_ name: String, _ arguments: [String: JSONValue],
                   generation: UUID, epoch: UUID?, load: @escaping Load,
                   configure: @escaping Configure) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        var result = arguments
        guard Self.requested(name, arguments) else {
            if result["post_action_wait"] == .string("none") { result["post_action_wait"] = nil }
            return result
        }
        let tools: [JSONValue]
        do {
            tools = try await self.tools(generation: generation, load: load)
        } catch let error as DriverConnectionError {
            switch error {
            case .malformed, .remote, .refused, .toolRefused:
                result["post_action_wait"] = nil
                return result
            default: throw error
            }
        }
        func schema(_ tool: String) -> JSONValue? {
            let matches = tools.filter { $0["name"]?.string == tool }
            guard matches.count == 1 else { return nil }
            return matches[0]["inputSchema"]
        }
        let input = schema(name)?["properties"]
        guard input?["element_token"]?["type"] == .string("string") else {
            result["post_action_wait"] = nil
            return result
        }
        if input?["post_action_wait"]?["type"] != .string("string")
            || input?["post_action_wait"]?["enum"]?.array?.contains(.string("none")) != true {
            result["post_action_wait"] = nil
        }
        let motionSchema = schema("set_agent_cursor_motion")
        let required = motionSchema?["required"]
        let supportsRequiredFields = required == nil || required?.array?.allSatisfy {
            $0.string.map { ["session", "glide_duration_ms"].contains($0) } == true
        } == true
        let motion = motionSchema?["properties"]
        if supportsRequiredFields, let epoch, motion?["session"]?["type"] == .string("string"),
           [JSONValue.string("number"), .string("integer")].contains(motion?["glide_duration_ms"]?["type"] ?? .null) {
            if preparations[epoch] == nil {
                let session = arguments["session"]!
                preparations[epoch] = Task {
                    let reply = try await configure(["session": session, "glide_duration_ms": .number(120)])
                    guard reply["session"] == session, reply["motion"]?["glide_duration_ms"] == .number(120)
                    else { throw DriverConnectionError.malformed }
                }
            }
            do {
                try await preparations[epoch]!.value
            } catch let error as DriverConnectionError {
                switch error {
                case .refused, .toolRefused: break
                default: throw error
                }
            }
        }
        guard self.generation == generation else { throw DriverConnectionError.closed }
        try Task.checkCancellation()
        return result
    }
}

/// One persistent MCP stdio transport — a `cua-driver mcp --embedded` proxy
/// bound to the shared daemon socket vended by CuaDaemonHost. Sessions and
/// driver grants are keyed per (session, transport, resource), so a caller
/// owns one connection for its session's lifetime. Never reconnects or
/// retries a mutation; a dead transport is replaced wholesale by the caller.
actor CuaConnection {
    private let executable: URL
    private let onToolCall: (@Sendable (String, Int?) -> Void)?
    /// Fired once per refusal storm: a read-only call that burns its whole
    /// retry budget on `tool_invocation_failed` means the daemon itself is
    /// sick — alive, answering, refusing. Carries the bound socket so the
    /// host can no-op a stale fault aimed at a recycled generation.
    /// Defaults to `defaultSickDaemonHook` — pass nil explicitly to leave
    /// the shared daemon out of this connection's failure handling.
    /// `nonisolated let` — immutable since init; tests read it directly.
    nonisolated let onSickDaemon: (@Sendable (String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: Task<Void, Never>?
    private var frames = MCPFrames()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var generation = UUID()
    private var initialized = false
    private(set) var dispatchPacing = CuaDispatchPacing()
    private var sessionEpochs = CuaSessionEpochs()
    /// The daemon socket this proxy is bound to — the sick-daemon token.
    private(set) var boundSocket: String?
    /// A wedged daemon can hold the socket open and never answer — two
    /// consecutive timeouts mark the transport dead rather than letting
    /// every later call burn a full timeout forever.
    private var consecutiveTimeouts = 0
    private(set) var serverVersion: String?
    /// A connection that completed `initialize` and whose proxy process is
    /// still alive.
    var connected: Bool { initialized && process?.isRunning == true }

    /// The shared host's token-scoped re-mint — the sick-daemon hook's
    /// intended consumer. Token-scoped, so a stale fault aimed at a
    /// recycled generation no-ops against the healthy successor. Wired by
    /// default at every construction site so a refusing-but-alive daemon is
    /// recoverable in-process no matter who owns the transport.
    static let defaultSickDaemonHook: @Sendable (String) -> Void = { socket in
        Task { await CuaDaemonHost.shared.invalidate(matching: socket) }
    }

    init(executable: URL = CuaDependency.executable,
         onToolCall: (@Sendable (String, Int?) -> Void)? = nil,
         onSickDaemon: (@Sendable (String) -> Void)? = CuaConnection.defaultSickDaemonHook) {
        // A write to a just-dead proxy raises SIGPIPE, whose default
        // disposition kills the process — ignore it once so EPIPE surfaces
        // as a thrown error instead of an app crash.
        signal(SIGPIPE, SIG_IGN)
        self.executable = executable
        self.onToolCall = onToolCall
        self.onSickDaemon = onSickDaemon
    }

    deinit {
        reader?.cancel()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    /// Spawns `mcp --embedded --socket <socket>` and runs the MCP handshake.
    /// The proxy is the same pinned binary as the daemon — verified here even
    /// though the daemon was verified by the host. One-shot: a connected or
    /// dead connection is never restarted in place; make a new one.
    func connect(socket: String) async throws {
        guard process == nil, !initialized else {
            throw DriverConnectionError.remote("Cua connection already started.")
        }
        let expected = executable == CuaDependency.bundledExecutable
            ? (CuaDependency.bundledSHA256 ?? CuaDependency.executableSHA256)
            : CuaDependency.executableSHA256
        try CuaDependency.verify(executable, expectedSHA256: expected)
        boundSocket = socket
        do {
            try await startProxy(socket: socket)
        } catch {
            boundSocket = nil
            throw error
        }
    }

    static func makeProxyProcess(
        executable: URL, socket: String, hostEnvironment: [String: String]
    ) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp", "--embedded", "--socket", socket,
                             "--host-bundle-id", CuaDependency.hostBundleID]
        process.environment = EmbeddedDaemon.daemonEnvironment(host: hostEnvironment)
        return process
    }

    private func startProxy(socket: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DriverConnectionError.unavailable }
        let process = Self.makeProxyProcess(
            executable: executable, socket: socket,
            hostEnvironment: ProcessInfo.processInfo.environment
        )
        let stdin = Pipe(), stdout = Pipe()
        let token = UUID()
        generation = token
        dispatchPacing = CuaDispatchPacing()
        frames = MCPFrames()
        consecutiveTimeouts = 0
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

    /// Shows or hides the session's agent cursor (`set_agent_cursor_enabled`,
    /// args `{session, enabled}` — `deny_unknown_fields`, so nothing else).
    /// The driver declares the tool idempotent, and `animate_cursor_to`
    /// early-returns while a session's cursor is disabled — a hidden cursor
    /// never visibly teleports on the user. Fire-and-forget safe: failures
    /// are swallowed because cursor visibility is a session preference, not
    /// a correctness gate. Call at session start via
    /// `Task { await conn.setAgentCursorEnabled(...) }`. Short timeout —
    /// session-start bookkeeping must not hang on a wedged transport.
    func setAgentCursorEnabled(_ enabled: Bool, session: String) async {
        _ = try? await call("set_agent_cursor_enabled", arguments: [
            "session": .string(session),
            "enabled": .bool(enabled)
        ], timeout: 5)
    }

    func tools(timeout: TimeInterval = 30) async throws -> [JSONValue] {
        let token = generation
        let result = try await dispatchPacing.tools(generation: token) {
            try await self.loadTools(generation: token, timeout: timeout)
        }
        guard initialized, generation == token else { throw DriverConnectionError.closed }
        return result
    }

    private func loadTools(generation token: UUID, timeout: TimeInterval) async throws -> [JSONValue] {
        guard initialized else { throw DriverConnectionError.closed }
        guard timeout.isFinite, timeout > 0 else { throw DriverConnectionError.timedOut }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var result: [JSONValue] = [], cursors = Set<String>()
        var names = Set<String>()
        var cursor: String?
        repeat {
            guard initialized, generation == token else { throw DriverConnectionError.closed }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw DriverConnectionError.timedOut }
            let page = try await request("tools/list", params: .object(cursor.map { ["cursor": .string($0)] } ?? [:]),
                                         timeout: remaining)
            guard generation == token else { throw DriverConnectionError.closed }
            guard let tools = page["tools"]?.array,
                  tools.allSatisfy({
                      guard let name = $0["name"]?.string, !name.isEmpty,
                            $0["inputSchema"]?.object != nil else { return false }
                      return names.insert(name).inserted
                  }) else {
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
    /// safe to retry — mutations are never retried since an effect may
    /// already exist on the target.
    private static let readOnlyTools: Set<String> = [
        "list_apps", "list_windows", "list_sessions", "get_window_state",
        "get_desktop_state", "get_browser_state", "get_accessibility_tree",
        "get_session", "get_session_state", "get_config", "get_recording_state",
        "get_agent_cursor_state", "get_cursor_position", "get_screen_size",
        "health_report", "check_permissions", "check_for_update",
        "clipboard_read", "verify_state", "page"
    ]

    /// `page` is polymorphic: get_text/query_dom read, while
    /// execute_javascript / click_element / insert_text / type_keystrokes /
    /// enable_javascript_apple_events mutate. Only the two read actions
    /// earn a retry.
    private static let pageReadActions: Set<String> = ["get_text", "query_dom"]

    /// Transient read-fault backoff: the first retry waits 150ms — a wedged
    /// driver shouldn't cost ≥400ms before a retry even starts — then each
    /// step doubles up to the cap. A daemon waking alongside the machine
    /// stalls in steps; bounded backoff covers seconds of it. Mutations
    /// never reach this: they get a single attempt.
    static let readRetryInitialBackoff: Duration = .milliseconds(150)
    static let readRetryMaxBackoff: Duration = .seconds(2)

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
    /// (.malformed) never succeeds on retry.
    static func transientReadFault(_ error: Error) -> Bool {
        switch error as? DriverConnectionError {
        case .timedOut, .closed: return true
        case .toolRefused(_, let code, _): return code == "tool_invocation_failed"
        default: return false
        }
    }

    static func argumentsForTool(_ name: String, _ arguments: [String: JSONValue]) -> [String: JSONValue] {
        guard name == "get_window_state", arguments["tree_format"] == nil,
              arguments["full_output"] == nil, arguments["since"] == nil else { return arguments }
        // 0.38 defaults to Markdown; existing consumers need structured rows
        // and geometry. Narrow callers can explicitly request elements only.
        var result = arguments
        result["full_output"] = .bool(true)
        return result
    }

    func callResult(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval = 30) async throws -> CuaToolResult {
        var arguments = Self.argumentsForTool(name, arguments)
        guard initialized else { throw DriverConnectionError.closed }
        try Task.checkCancellation()
        if arguments["post_action_wait"] == .string("none") {
            let token = generation
            let session = arguments["session"]?.string
            let epoch = CuaDispatchPacing.requested(name, arguments)
                ? sessionEpochs.willCall(name, session: session) : nil
            arguments = try await dispatchPacing.arguments(name, arguments, generation: token, epoch: epoch,
                load: { try await self.loadTools(generation: token, timeout: min(timeout, 2)) },
                configure: { try await self.configureMotion($0, generation: token, epoch: epoch,
                                                          timeout: min(timeout, 2)) })
            guard initialized, generation == token,
                  epoch == nil || sessionEpochs.current(session) == epoch else {
                throw DriverConnectionError.closed
            }
            try Task.checkCancellation()
        }
        onToolCall?(name, arguments["text"]?.string?.count)
        var attempts = Self.isReadOnly(name, arguments: arguments) ? 4 : 1
        var backoff: Duration = Self.readRetryInitialBackoff
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
                    // identically. Kill this transport and tell the host to
                    // recycle the daemon generation this proxy was bound to.
                    // A single refusal on a mutation is a real tool error,
                    // never a storm. Only refusals count: a wedged proxy or
                    // slow daemon exhausts on .timedOut/.closed — noteTimeout
                    // already tore this transport down, and recycling the
                    // shared daemon for that would kill healthy proxies.
                    if Self.isReadOnly(name, arguments: arguments),
                       case .toolRefused(_, let code, _) = error,
                       code == "tool_invocation_failed", let socket = boundSocket {
                        disconnect(DriverConnectionError.closed)
                        onSickDaemon?(socket)
                    }
                    throw error
                }
                // A daemon waking alongside the machine stalls in steps —
                // bounded backoff covers seconds of it, never a mutation.
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, Self.readRetryMaxBackoff)
            }
        }
    }

    private func configureMotion(_ arguments: [String: JSONValue], generation token: UUID,
                                 epoch: UUID?, timeout: TimeInterval) async throws -> JSONValue {
        guard initialized, generation == token, let epoch,
              sessionEpochs.current(arguments["session"]?.string) == epoch else {
            throw DriverConnectionError.closed
        }
        return try await callResultOnce("set_agent_cursor_motion", arguments: arguments, timeout: timeout).structured
    }

    func callScoped(_ name: String, arguments: [String: JSONValue],
                    origin: CuaResultOrigin?, timeout: TimeInterval = 30) async throws -> CuaToolResult {
        try validateScope(name, arguments: arguments, origin: origin)
        let definitions = JSONValue.object(["tools": .array(try await tools(timeout: min(timeout, 8)))])
        guard Self.supportsCapturedInputs(definitions) else {
            throw DriverConnectionError.refused("The driver does not support capture-bound clicks, typing, keys and scrolling.")
        }
        let nativeCaptureTools = Self.capturedElementTools(definitions)
        try validateScope(name, arguments: arguments, origin: origin)
        if arguments["capture_id"] != nil, arguments["element_token"] != nil,
           !nativeCaptureTools.contains(name) {
            throw DriverConnectionError.refused("The driver does not support capture-bound native elements for this tool.")
        }
        var result = try await callResult(name, arguments: arguments, timeout: timeout)
        result.capturedElementTools = nativeCaptureTools
        return result
    }

    private func validateScope(_ name: String, arguments: [String: JSONValue],
                               origin: CuaResultOrigin?) throws {
        if let origin {
            guard initialized, let socket = boundSocket,
                  origin == CuaResultOrigin(session: arguments["session"]?.string,
                    daemonSocket: socket, transport: generation,
                    sessionEpoch: sessionEpochs.current(arguments["session"]?.string)) else {
                throw DriverConnectionError.refused("The capture's transport scope is no longer current.")
            }
        } else if !Self.isReadOnly(name, arguments: arguments) {
            throw DriverConnectionError.refused("A capture-bound input requires its original transport scope.")
        }
    }

    static func supportsCapturedInputs(_ definitions: JSONValue) -> Bool {
        let tools = definitions["tools"]?.array ?? []
        return ["click", "type_text", "press_key", "scroll"].allSatisfy { name in
            tools.contains {
                $0["name"]?.string == name
                    && $0["inputSchema"]?["properties"]?["capture_id"]?.object != nil
            }
        }
    }

    static func capturedElementTools(_ definitions: JSONValue) -> Set<String> {
        Set((definitions["tools"]?.array ?? []).compactMap { definition in
            guard let name = definition["name"]?.string,
                  ["click", "type_text", "press_key", "scroll"].contains(name),
                  let schema = definition["inputSchema"],
                  schema["x-cua-capture-bound-element"] == .bool(true),
                  schema["properties"]?["capture_id"]?["type"] == .string("string"),
                  schema["properties"]?["element_token"]?["type"] == .string("string")
            else { return nil }
            return name
        })
    }

    /// Two consecutive timeouts is a dead transport, not a slow one — tear it
    /// down so callers get `.closed` and replace it wholesale.
    private func noteTimeout() {
        consecutiveTimeouts += 1
        if consecutiveTimeouts >= 2 {
            disconnect(DriverConnectionError.closed)
        }
    }

    private func callResultOnce(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval) async throws -> CuaToolResult {
        guard let socket = boundSocket else { throw DriverConnectionError.closed }
        let origin = CuaResultOrigin(session: arguments["session"]?.string,
            daemonSocket: socket, transport: generation,
            sessionEpoch: sessionEpochs.willCall(name, session: arguments["session"]?.string))
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
        return CuaToolResult(structured: merged, content: content, origin: origin)
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
        dispatchPacing = CuaDispatchPacing()
        initialized = false
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
    }
}
