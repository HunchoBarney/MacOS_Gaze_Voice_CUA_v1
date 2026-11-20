import Foundation
import Synchronization
import JarvisCore

/// `Jarvis --mcp-stdio --agent <slug>` — the MCP server every agent's
/// codex app-server spawns to reach computer use. Newline-delimited
/// JSON-RPC over stdio (the MCP stdio transport). Exposes `drive_until`
/// and `suggest_action`, both running the same DriveLoop the voice path
/// runs against the app's shared daemon.
///
/// Trust model (per the megaplan):
/// - The daemon socket path arrives via the well-known file the app
///   rewrites on every re-mint — never a baked-in path that goes stale.
/// - Consent is the app's policy file: the standing grant and nothing
///   else. No grant → mutation calls refuse with guidance; the deny list
///   is code-compiled and identical for voice and agents.
/// - `TYPESAFE_API_KEY` (and `TYPESAFE_BASE_URL` when it is this Mac's
///   token for Jarvis's credential service) reaches this process through
///   codex's `env_vars` pass-through — never written into config.toml.
enum CuaDriveServer {
    /// The app's support root — the policy file and agent asks live here,
    /// shared with AgentWorkspace's parent directory.
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis", isDirectory: true)
    }
    /// Every successful transport bind mints a fresh session label — the
    /// connect and the rebind are paired in one place so they can't drift
    /// apart (a new transport never inherits the dead owner's tombstone).
    static func bindTransport(_ driver: CuaConnection,
                              session: AgentSession, socket: String) async throws {
        guard await !driver.connected else { return }
        try await driver.connect(socket: socket)
        session.rebind()
    }

    /// {"standingGrant": Bool} — rewritten by the app when the setting moves.
    static var policyFile: URL { supportDir.appendingPathComponent("policy.json") }

    /// One connection's session label. The daemon binds a session to the
    /// transport that first admits it and only that transport may revive
    /// it — a second `--mcp-stdio` child inheriting `agent-<slug>` wedges
    /// on the dead owner's tombstone until daemon respawn (the P1 bench
    /// finding). So the label mints per transport bind and stays stable
    /// between binds: the slug remains the stem for cursor/predicate
    /// rules, and the loop's own revive/rotate still resumes a session
    /// the daemon ends mid-task on THIS transport.
    final class AgentSession {
        let slug: String
        private(set) var label: String
        init(agent slug: String) {
            self.slug = slug
            label = Self.mint(slug)
        }
        /// A fresh transport never inherits the previous owner's label.
        func rebind() { label = Self.mint(slug) }
        private static func mint(_ slug: String) -> String {
            "agent-\(slug)-\(UUID().uuidString.prefix(8).lowercased())"
        }
    }

    /// Entry point for `--mcp-stdio`; never returns. Top-level code already
    /// runs on the main thread — the task hops the serve loop off it so
    /// RunLoop.main can pump stdin and stdio writes stay ordered.
    static func main() -> Never {
        let slug = Self.argument("--agent") ?? "agent"
        Task { await serve(agent: slug); exit(0) }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    private static func argument(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// The live daemon socket, looked up in the private directory the app
    /// passed as `--cua-dir` each time, since every re-mint moves it.
    private static func socketPath() throws -> String {
        guard let directory = argument("--cua-dir"),
              let socket = CuaSocketDirectory.liveSocket(in: directory) else {
            throw DriverConnectionError.unavailable
        }
        return socket
    }

    private static func standingGrant() -> Bool {
        guard let data = try? Data(contentsOf: policyFile),
              let object = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        return object["standingGrant"]?.bool ?? false
    }

    // MARK: - Serve loop

    private static func serve(agent slug: String) async {
        let driver = CuaConnection()
        let session = AgentSession(agent: slug)
        let liveCalls = Mutex<[String: Task<Void, Never>]>([:])
        // A blocking read pump on a background queue — AsyncBytes stalled
        // after the first line in practice, while `availableData` on a
        // pipe is boring and reliable: data or EOF, nothing else.
        let stdinLines = AsyncStream<String> { continuation in
            DispatchQueue.global().async {
                var buffer = Data()
                while true {
                    let chunk = FileHandle.standardInput.availableData
                    guard !chunk.isEmpty else { continuation.finish(); return }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        if let text = String(data: buffer[..<nl], encoding: .utf8) {
                            continuation.yield(text)
                        }
                        buffer.removeSubrange(...nl)
                    }
                }
            }
        }
        for await line in stdinLines {
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let method = frame["method"]?.string else { continue }
            let id = frame["id"]
            let idKey = id.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
            switch method {
            case "initialize":
                respond(id, .object([
                    "protocolVersion": .string(frame["params"]?["protocolVersion"]?.string ?? "2025-06-18"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("jev-drive"), "version": .string("1")])
                ]))
            case "ping":
                respond(id, .object([:]))
            case "tools/list":
                respond(id, .object(["tools": .array(toolList)]))
            case "notifications/initialized":
                break
            case "notifications/cancelled":
                if let target = frame["params"]?["requestId"],
                   let key = try? String(decoding: JSONEncoder().encode(target), as: UTF8.self) {
                    liveCalls.withLock { $0[key]?.cancel() }
                }
            case "tools/call":
                guard let id, let idKey else { break }
                let name = frame["params"]?["name"]?.string ?? ""
                let args = frame["params"]?["arguments"] ?? .object([:])
                let task = Task { [driver] in
                    let result = await callTool(name, args: args, session: session, driver: driver)
                    liveCalls.withLock { $0[idKey] = nil }
                    respond(id, result)
                }
                liveCalls.withLock { $0[idKey] = task }
            default:
                if id != nil {
                    respond(id, .object(["error": .object([
                        "code": .number(-32601),
                        "message": .string("Unknown method \(method)")])]))
                }
            }
        }
        for task in liveCalls.withLock({ $0.values.map { $0 } }) { task.cancel() }
        await driver.close()
    }

    private static let taskInputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "goal": .object(["type": .string("string"),
                             "description": .string("What to accomplish, concretely.")]),
            "app": .object(["type": .string("string"),
                            "description": .string("The target app, when the task names one.")]),
            "window_id": .object([
                "type": .string("integer"), "minimum": .number(1), "maximum": .number(4294967295),
                "description": .string("Exact target window in the requested app. Missing or foreign windows refuse without substitution. Excludes app-wide and global actions.")
            ]),
            "values": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("string")]),
                "description": .string("Caller-supplied literal text keyed by field label. Preserved verbatim; never inferred or authored by the action picker.")
            ]),
            "success_contains": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string"), "minLength": .number(1)]),
                "description": .string("Expected final-state text implied by the goal. Any one must be observed and verified. Available buttons and intermediate steps are not completion evidence.")
            ]),
            "deny": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string"), "minLength": .number(1)]),
                "description": .string("Additional forbidden target text. These restrictions only narrow existing policy.")
            ]),
        ]),
        "required": .array([.string("goal")]),
        "additionalProperties": .bool(false),
    ])

    private static let toolList: [JSONValue] = [
        .object([
            "name": .string("drive_until"),
            "description": .string("Drive the user's Mac toward a goal: open apps, click, type, scroll, navigate browsers. The loop observes the window, picks actions, and verifies — report its result verbatim. Requires the computer-use grant in Jarvis settings; without it every mutation refuses."),
            "inputSchema": taskInputSchema
        ]),
        .object([
            "name": .string("suggest_action"),
            "description": .string("Observe the target app's window and report the single best next action without dispatching it — a read-only preview of the drive loop's choice."),
            "inputSchema": taskInputSchema
        ])
    ]

    // MARK: - Tool calls

    enum TaskArgumentsError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    static func decodeTask(_ args: JSONValue) throws -> DriveTask {
        let allowed: Set<String> = ["goal", "app", "window_id", "values", "success_contains", "deny"]
        guard case .object(let fields) = args,
              Set(fields.keys).isSubset(of: allowed) else {
            throw TaskArgumentsError.invalid("Unsupported task arguments.")
        }
        guard let goal = args["goal"]?.string,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskArgumentsError.invalid("`goal` is required.")
        }
        if let app = args["app"] {
            guard let name = app.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TaskArgumentsError.invalid("`app` must be a nonempty string.")
            }
        }
        var values: [String: String] = [:]
        var windowID: Int?
        if let supplied = args["window_id"] {
            guard case .number(let number) = supplied, number.isFinite,
                  number >= 1, number <= Double(UInt32.max), number.rounded() == number else {
                throw TaskArgumentsError.invalid("`window_id` must be a positive exact window identity.")
            }
            windowID = Int(number)
        }
        if let supplied = args["values"] {
            guard case .object(let raw) = supplied else {
                throw TaskArgumentsError.invalid("`values` must be a string map.")
            }
            for (label, value) in raw {
                guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let literal = value.string else {
                    throw TaskArgumentsError.invalid("`values` must have nonempty field labels and string literals.")
                }
                values[label] = literal
            }
        }
        func strings(_ key: String) throws -> [String] {
            guard let supplied = args[key] else { return [] }
            guard case .array(let raw) = supplied else {
                throw TaskArgumentsError.invalid("`\(key)` must be an array of nonempty strings.")
            }
            return try raw.map {
                guard let text = $0.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TaskArgumentsError.invalid("`\(key)` must contain only nonempty strings.")
                }
                return text
            }
        }
        return try DriveTask(goal: goal, application: args["app"]?.string,
                             windowID: windowID,
                             values: values, deny: strings("deny"),
                             successContains: strings("success_contains"))
    }

    private static func callTool(_ name: String, args: JSONValue,
                                 session: AgentSession, driver: CuaConnection) async -> JSONValue {
        let task: DriveTask
        do {
            task = try decodeTask(args)
        } catch {
            return toolError(error.localizedDescription)
        }

        let apiKey = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? ""
        guard !apiKey.isEmpty else {
            return toolError("TYPESAFE_API_KEY is not configured for this agent.")
        }

        do {
            let socket = try socketPath()
            try await bindTransport(driver, session: session, socket: socket)
            let call: DriveLoop.Call = { tool, callArgs in
                do {
                    return try await driver.call(tool, arguments: callArgs)
                } catch let error as DriverConnectionError {
                    if error == .closed, CuaConnection.isReadOnly(tool, arguments: callArgs),
                       let fresh = try? socketPath(), fresh != socket,
                       (try? await bindTransport(driver, session: session, socket: fresh)) != nil {
                        // The reconnected transport is a new session
                        // owner — the old label is tombstoned to the
                        // dead one, so the retry rides a fresh label.
                        var callArgs = callArgs
                        if callArgs["session"] != nil {
                            callArgs["session"] = .string(session.label)
                        }
                        return try await driver.call(tool, arguments: callArgs)
                    }
                    throw error
                }
            }
            // Park + notify: the ask lands in the shared asks dir, the app
            // surfaces it (feed + overlay), and the answer file resumes us.
            // Timeout or dismissal reads as decline — never silent approval.
            // Agent-authored goals are autonomous effects, not a spoken
            // command — `explicitConsent: false` puts every fast-lane and
            // bind-phase dispatch on the standing grant / per-task
            // confirm like the model-picked loop candidates.
            let baseURL = ProcessInfo.processInfo.environment["TYPESAFE_BASE_URL"].flatMap(URL.init(string:))
            let loop = DriveLoop(call: call, choose: JevChooser.make(apiKey: apiKey,
                                                                     baseURL: baseURL ?? JevClient.systemOneURL),
                                 ask: { await AgentAskChannel.request($0, agent: session.slug) },
                                 granted: { standingGrant() },
                                 explicitConsent: false,
                                 config: .init(windowOnly: task.windowID != nil))
            if name == "suggest_action" {
                let text = try await loop.preview(task, session: session.label)
                return toolText(text)
            }
            guard name == "drive_until" else { return toolError("Unknown tool \(name).") }
            let result = await loop.run(task, session: session.label)
            return toolText(describe(result))
        } catch is CancellationError {
            return toolError("Cancelled.")
        } catch {
            return toolError(error.localizedDescription)
        }
    }

    /// DriveResult → the text the agent reports. `.done` is only claimed
    /// with a confirmed effect behind it — the loop enforces that.
    /// Internal (not private) so tests pin the consent-refusal wording.
    static func describe(_ result: DriveResult) -> String {
        let tail = result.history.suffix(3).joined(separator: "; ")
        switch result.status {
        case .done:
            return "Done.\(tail.isEmpty ? "" : " " + tail)"
        case .alreadySatisfied(let reason):
            return "Already satisfied: \(reason)."
        case .blocked(let why):
            return "Blocked: \(why)\(tail.isEmpty ? "" : " Recent steps: " + tail)"
        case .blockedByConsent:
            // The loop classifies its refusal in `consentBlock` — the
            // remedy text keys on that, never on the reason string, so a
            // refusal no setting fixes never reads as a grant hint.
            let why = result.blockedReason ?? ""
            switch result.consentBlock {
            case .permanent:
                // Deny-list hit, denied tool, or the task's own rule —
                // the reason text says which; no consent path reverses it.
                let w = why.isEmpty ? "Refused" : why
                return "\(w)\(w.hasSuffix(".") ? "" : ".") No grant or approval path changes that."
            case .declined:
                return why.isEmpty ? "Blocked: the action was not approved." : "Blocked: \(why)"
            case .missingGrant:
                return "Blocked: computer use needs the standing grant — the user enables it in Jarvis settings."
            case nil:
                // Unclassified consent block — relay the reason without
                // promising a remedy.
                return why.isEmpty ? "Blocked: a consent gate stopped the task." : "Blocked: \(why)"
            }
        case .handedBack(let reason):
            return "Stuck: \(reason.rawValue). \(tail)"
        case .needsText(let field):
            return "Needs input: text for \(field)."
        case .needsWindow(let candidates):
            return "Ambiguous: which of \(candidates.prefix(3).joined(separator: ", "))?"
        case .maxSteps:
            return "Ran out of steps. \(tail)"
        case .cancelled:
            return "Cancelled."
        }
    }

    private static func toolText(_ text: String) -> JSONValue {
        .object(["content": .array([.object([
            "type": .string("text"), "text": .string(text)])])])
    }
    private static func toolError(_ text: String) -> JSONValue {
        .object(["content": .array([.object([
            "type": .string("text"), "text": .string(text)])]),
            "isError": .bool(true)])
    }

    // MARK: - Wire

    /// Responses write through one lock — concurrent tool calls never
    /// interleave a frame.
    private static let writeLock = NSLock()
    private static func respond(_ id: JSONValue?, _ payload: JSONValue) {
        guard let id else { return }
        var frame = payload.object ?? [:]
        frame["jsonrpc"] = .string("2.0")
        if frame["error"] == nil && frame["result"] == nil {
            frame = ["result": payload]
        }
        frame["id"] = id
        guard let data = try? JSONEncoder().encode(JSONValue.object(frame)),
              let text = String(data: data, encoding: .utf8) else { return }
        writeLock.lock()
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        writeLock.unlock()
    }
}
