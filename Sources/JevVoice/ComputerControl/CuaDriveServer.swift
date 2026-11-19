import Foundation
import JevVoiceCore

enum CuaDriveServer {
    /// The app's support root — the socket-path and policy files live here,
    /// shared with AgentWorkspace's parent directory.
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("JevVoice", isDirectory: true)
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

    /// One line: the live daemon socket path. The app rewrites it on every
    /// daemon re-mint so children never bind a stale socket.
    static var socketHintFile: URL { supportDir.appendingPathComponent("cua.socket") }
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
        Task { await serve(); exit(0) }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    private static func serve() async {
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
                  let id = frame["id"], let response = response(to: frame) else { continue }
            respond(id, response)
        }
    }

    static func response(to frame: JSONValue) -> JSONValue? {
        guard frame["id"] != nil, let method = frame["method"]?.string else { return nil }
        switch method {
        case "initialize":
            return .object([
                "protocolVersion": .string(frame["params"]?["protocolVersion"]?.string ?? "2025-06-18"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("jev-drive"), "version": .string("1")])
            ])
        case "ping": return .object([:])
        case "tools/list": return .object(["tools": .array(toolList)])
        case "tools/call":
            switch frame["params"]?["name"]?.string {
            case "drive_until", "suggest_action":
                return toolError("Blocked: trusted operator handoff unavailable. The worker did not access the desktop.")
            default: return toolError("Unknown tool.")
            }
        default:
            return .object(["error": .object(["code": .number(-32601),
                "message": .string("Unknown method \(method)")])])
        }
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
            "description": .string("Desktop execution requires a trusted operator handoff, unavailable to this worker."),
            "inputSchema": taskInputSchema
        ]),
        .object([
            "name": .string("suggest_action"),
            "description": .string("Desktop preview is unavailable because observation can change shared state."),
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
        if FastAction.retiredTargetRequest(goal) != nil {
            throw TaskArgumentsError.invalid("Please name the control you want to use.")
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
                return "Blocked: computer use needs the standing grant — the user enables it in Jev Voice settings."
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
        guard let data = try? JSONEncoder().encode(envelope(id: id, payload: payload)),
              let text = String(data: data, encoding: .utf8) else { return }
        writeLock.lock()
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        writeLock.unlock()
    }

    static func envelope(id: JSONValue, payload: JSONValue) -> JSONValue {
        var frame = payload.object ?? [:]
        if frame["error"] == nil && frame["result"] == nil {
            frame = ["result": payload]
        }
        frame["id"] = id
        frame["jsonrpc"] = .string("2.0")
        return .object(frame)
    }
}
