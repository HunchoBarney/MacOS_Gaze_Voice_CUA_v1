import Foundation
import JevVoiceCore

/// Transport failures from a `codex app-server` process. A closed transport is
/// replaced wholesale by CodexRuntimeBridge — a turn that may have dispatched
/// work is never retried silently.
public enum CodexConnectionError: Error, LocalizedError, Equatable {
    case unavailable, closed, malformed, timedOut, remote(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The codex binary is missing or not executable."
        case .closed: return "The codex app-server connection closed."
        case .malformed: return "The codex app-server sent an invalid message."
        case .timedOut: return "The codex app-server did not answer in time."
        case .remote(let text): return text
        }
    }
}

/// Terminal snapshot of a turn from `turn/completed`. `status` is the raw wire
/// value (`completed`, `failed`, `interrupted`) — the protocol is experimental
/// and new statuses must flow through rather than decode-fail.
public struct CodexTurnResult: Sendable, Equatable {
    public var id: String
    public var status: String
    public var errorMessage: String?
    public init(id: String, status: String, errorMessage: String? = nil) {
        self.id = id; self.status = status; self.errorMessage = errorMessage
    }
}

/// Typed decode of the app-server notification stream, observed on
/// codex-cli 0.158.0. Unrecognized methods land in `other` so a protocol bump
/// degrades to raw params instead of dropping events.
public enum CodexEvent: Sendable {
    case threadStarted(threadID: String)
    case threadStatus(threadID: String, status: String)
    case turnStarted(threadID: String, turnID: String)
    case turnCompleted(threadID: String, turn: CodexTurnResult)
    case agentMessageDelta(threadID: String, turnID: String, itemID: String, delta: String)
    case reasoningDelta(threadID: String, turnID: String, itemID: String, delta: String)
    case planDelta(threadID: String, turnID: String, itemID: String, delta: String)
    /// Raw `item` object — its `type` field selects userMessage / agentMessage /
    /// commandExecution / fileChange / mcpToolCall / collabAgentToolCall.
    case itemStarted(threadID: String, turnID: String, item: JSONValue)
    case itemCompleted(threadID: String, turnID: String, item: JSONValue)
    /// Streaming tool-side output (command exec, file change, MCP progress).
    /// `source` carries the originating method name.
    case toolOutputDelta(source: String, threadID: String?, itemID: String?, delta: String)
    case error(message: String, willRetry: Bool, threadID: String?, turnID: String?)
    case warning(message: String, threadID: String?)
    /// A server→client request (approvals, elicitations, tool input). The
    /// client answers `decline`/empty immediately — surfaced here so the
    /// coordinator can observe every ask the agent raised.
    case serverRequest(method: String, params: JSONValue)
    case other(method: String, params: JSONValue)

    /// Wire-method constants observed on 0.158.0 (`generate-json-schema` v2).
    static func notification(method: String, params: JSONValue) -> CodexEvent {
        let threadID = params["threadId"]?.string
        let turnID = params["turnId"]?.string
        let itemID = params["itemId"]?.string
        switch method {
        case "thread/started":
            return .threadStarted(threadID: params["thread"]?["id"]?.string ?? "")
        case "thread/status/changed":
            return .threadStatus(threadID: threadID ?? "",
                                 status: params["status"]?["type"]?.string ?? "unknown")
        case "turn/started":
            return .turnStarted(threadID: threadID ?? "",
                                turnID: params["turn"]?["id"]?.string ?? "")
        case "turn/completed":
            let turn = params["turn"]
            return .turnCompleted(threadID: threadID ?? "", turn: CodexTurnResult(
                id: turn?["id"]?.string ?? "",
                status: turn?["status"]?.string ?? "unknown",
                errorMessage: turn?["error"]?["message"]?.string))
        case "item/agentMessage/delta":
            return .agentMessageDelta(threadID: threadID ?? "", turnID: turnID ?? "",
                                      itemID: itemID ?? "", delta: params["delta"]?.string ?? "")
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta",
             "item/reasoning/summaryPartAdded":
            return .reasoningDelta(threadID: threadID ?? "", turnID: turnID ?? "",
                                   itemID: itemID ?? "", delta: params["delta"]?.string ?? "")
        case "item/plan/delta":
            return .planDelta(threadID: threadID ?? "", turnID: turnID ?? "",
                              itemID: itemID ?? "", delta: params["delta"]?.string ?? "")
        case "item/started":
            return .itemStarted(threadID: threadID ?? "", turnID: turnID ?? "",
                                item: params["item"] ?? .null)
        case "item/completed":
            return .itemCompleted(threadID: threadID ?? "", turnID: turnID ?? "",
                                  item: params["item"] ?? .null)
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
             "command/exec/outputDelta", "item/mcpToolCall/progress":
            return .toolOutputDelta(source: method, threadID: threadID, itemID: itemID,
                                    delta: params["delta"]?.string ?? params["message"]?.string ?? "")
        case "error":
            return .error(message: params["error"]?["message"]?.string ?? "codex reported an error",
                          willRetry: params["willRetry"]?.bool ?? false,
                          threadID: threadID, turnID: turnID)
        case "warning":
            return .warning(message: params["message"]?.string ?? "", threadID: threadID)
        default:
            return .other(method: method, params: params)
        }
    }
}

/// Line framing for app-server stdio. Unlike MCPFrames this does not require a
/// `"jsonrpc":"2.0"` member — observed responses (`{"id":1,"result":…}`) and
/// notifications (`{"method":…,"emittedAtMs":…}`) omit it.
struct CodexFrames {
    private var buffer = Data()
    let limit: Int
    init(limit: Int = 16 * 1024 * 1024) { self.limit = limit }
    mutating func append(_ data: Data) throws -> [JSONValue] {
        buffer.append(data)
        var messages: [JSONValue] = []
        while let end = buffer.firstIndex(of: 10) {
            guard end <= limit else { throw CodexConnectionError.malformed }
            let line = buffer.prefix(upTo: end)
            if !line.isEmpty {
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
                      value.object != nil else { throw CodexConnectionError.malformed }
                messages.append(value)
            }
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= limit else { throw CodexConnectionError.malformed }
        return messages
    }
}

/// One stdio JSON-RPC session against `codex app-server`. Covers the observed
/// v2 surface: initialize → thread/start | thread/resume → turn/start →
/// notification stream → turn/interrupt. Server→client requests are always
/// answered locally (decline) — agents run with `approvalPolicy: "never"`, so
/// any ask that still arrives is surfaced as `.serverRequest` and refused
/// rather than left hanging the turn.
public actor CodexProtocolClient {
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let clientName: String
    private let clientVersion: String
    private let onStderrLine: (@Sendable (String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var stderrReader: Task<Void, Never>?
    private var frames = CodexFrames()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var generation = UUID()
    private var initialized = false
    /// Absolute CODEX_HOME the server reported at initialize.
    public private(set) var codexHome: String?
    public nonisolated let events: AsyncStream<CodexEvent>
    private let eventContinuation: AsyncStream<CodexEvent>.Continuation
    /// A client that completed `initialize` and whose process is still alive.
    public var connected: Bool { initialized && process?.isRunning == true }

    public init(executable: URL, arguments: [String] = ["app-server"],
                environment: [String: String] = [:],
                clientName: String = "JevVoice", clientVersion: String = "1",
                onStderrLine: (@Sendable (String) -> Void)? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.onStderrLine = onStderrLine
        var continuation: AsyncStream<CodexEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    deinit {
        reader?.cancel()
        stderrReader?.cancel()
        try? input?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    public func start() async throws {
        guard process == nil else { throw CodexConnectionError.remote("Codex client already started.") }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodexConnectionError.unavailable
        }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        let token = UUID()
        generation = token
        frames = CodexFrames()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.environment = Self.filteredEnvironment(
            parent: ProcessInfo.processInfo.environment, injected: environment)
        let stderr = Pipe()
        process.standardError = onStderrLine == nil ? FileHandle.nullDevice : stderr
        process.terminationHandler = { [weak self] _ in
            Task { await self?.connectionEnded(token) }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        let handle = stdout.fileHandleForReading
        reader = Task.detached { [weak self] in
            while !Task.isCancelled {
                let bytes = handle.availableData
                if bytes.isEmpty { await self?.connectionEnded(token); return }
                await self?.receive(bytes, token: token)
            }
        }
        if let onStderrLine {
            let errHandle = stderr.fileHandleForReading
            stderrReader = Task.detached {
                var rest = Data()
                while !Task.isCancelled {
                    let bytes = errHandle.availableData
                    if bytes.isEmpty { return }
                    rest.append(bytes)
                    while let end = rest.firstIndex(of: 10) {
                        if let line = String(data: rest.prefix(upTo: end), encoding: .utf8) {
                            onStderrLine(line)
                        }
                        rest.removeSubrange(...end)
                    }
                }
            }
        }
        do {
            let result = try await request("initialize", params: .object([
                "clientInfo": .object([
                    "name": .string(clientName),
                    "version": .string(clientVersion)
                ])
            ]))
            guard result.object != nil else { throw CodexConnectionError.malformed }
            codexHome = result["codexHome"]?.string
            try write(.object(["jsonrpc": .string("2.0"), "method": .string("initialized"),
                              "params": .object([:])]))
            initialized = true
        } catch {
            disconnect(error)
            throw error
        }
    }

    /// Env allowlist — a long-lived app-server child must not inherit host
    /// secrets. Only launch essentials and network config (proxy/custom CA —
    /// needed to reach the model API in managed environments) pass through;
    /// every injected var (API env_key token, MCP bearer vars, CODEX_HOME) is
    /// carried explicitly.
    static func filteredEnvironment(parent: [String: String],
                                    injected: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["PATH", "HOME", "LANG", "LC_ALL", "TMPDIR",
                                    "USER", "SHELL", "__CF_USER_TEXT_ENCODING",
                                    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                                    "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"]
        var environment: [String: String] = [:]
        for (key, value) in parent where allowed.contains(key) || key.hasPrefix("XDG_") {
            environment[key] = value
        }
        for (key, value) in injected { environment[key] = value }
        return environment
    }

    /// New persistent thread rooted at `cwd` (the agent's workspace).
    @discardableResult
    public func startThread(cwd: String, model: String? = nil,
                            developerInstructions: String? = nil,
                            ephemeral: Bool = false) async throws -> String {
        var params: [String: JSONValue] = [
            "cwd": .string(cwd),
            "approvalPolicy": .string("never"),
            "sandbox": .string("workspace-write"),
            "ephemeral": .bool(ephemeral)
        ]
        if let model { params["model"] = .string(model) }
        if let developerInstructions { params["developerInstructions"] = .string(developerInstructions) }
        let result = try await request("thread/start", params: .object(params))
        guard let id = result["thread"]?["id"]?.string, !id.isEmpty else {
            throw CodexConnectionError.malformed
        }
        return id
    }

    /// Reload a persisted thread by id (sessions survive in CODEX_HOME).
    @discardableResult
    public func resumeThread(_ threadID: String, cwd: String? = nil,
                             model: String? = nil) async throws -> String {
        var params: [String: JSONValue] = ["threadId": .string(threadID)]
        if let cwd { params["cwd"] = .string(cwd) }
        if let model { params["model"] = .string(model) }
        let result = try await request("thread/resume", params: .object(params))
        guard let id = result["thread"]?["id"]?.string, !id.isEmpty else {
            throw CodexConnectionError.malformed
        }
        return id
    }

    /// One user message → a running turn. Returns the new turn id; the turn's
    /// lifecycle arrives on `events` (deltas, items, `turn/completed`).
    @discardableResult
    public func startTurn(threadID: String, text: String) async throws -> String {
        let result = try await request("turn/start", params: .object([
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(text)])])
        ]))
        guard let id = result["turn"]?["id"]?.string, !id.isEmpty else {
            throw CodexConnectionError.malformed
        }
        return id
    }

    public func interruptTurn(threadID: String, turnID: String) async throws {
        _ = try await request("turn/interrupt", params: .object([
            "threadId": .string(threadID), "turnId": .string(turnID)
        ]))
    }

    /// Escape hatch for v2 methods without a typed wrapper (thread/list,
    /// thread/read, model/list, …).
    public func call(_ method: String, params: JSONValue = .object([:]),
                     timeout: TimeInterval = 30) async throws -> JSONValue {
        try await request(method, params: params, timeout: timeout)
    }

    public func close() { disconnect(CodexConnectionError.closed) }

    private func request(_ method: String, params: JSONValue, timeout: TimeInterval = 30) async throws -> JSONValue {
        try Task.checkCancellation()
        guard process?.isRunning == true else { throw CodexConnectionError.closed }
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
                        await self?.cancel(id, error: CodexConnectionError.timedOut)
                    }
                } catch { complete(id, result: .failure(error)) }
            }
        } onCancel: {
            Task { await self.cancel(id, error: CancellationError()) }
        }
    }

    private func write(_ message: JSONValue) throws {
        guard let input else { throw CodexConnectionError.closed }
        var data = try JSONEncoder().encode(message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ bytes: Data, token: UUID) {
        guard token == generation else { return }
        do {
            for message in try frames.append(bytes) {
                if let method = message["method"]?.string {
                    let params = message["params"] ?? .null
                    if let id = message["id"] {
                        // Server→client request: approve nothing, answer so the
                        // turn never hangs, and let observers see the ask.
                        eventContinuation.yield(.serverRequest(method: method, params: params))
                        try write(Self.answerServerRequest(id: id, method: method))
                    } else {
                        eventContinuation.yield(CodexEvent.notification(method: method, params: params))
                    }
                    continue
                }
                guard let id = message["id"]?.integer else { throw CodexConnectionError.malformed }
                if let error = message["error"] {
                    complete(id, result: .failure(CodexConnectionError.remote(
                        error["message"]?.string ?? "codex rejected the request.")))
                } else if let result = message["result"] {
                    complete(id, result: .success(result))
                } else { throw CodexConnectionError.malformed }
            }
        } catch { disconnect(error) }
    }

    /// Observed server requests on 0.158.0: item/*/requestApproval family
    /// (decision: accept|acceptForSession|decline|cancel) — except
    /// item/permissions/requestApproval, whose result is a permissions map
    /// (empty = grant nothing); mcpServer/elicitation/request (action:
    /// accept|decline|cancel); item/tool/requestUserInput (answers map).
    /// Anything else gets -32601.
    private static func answerServerRequest(id: JSONValue, method: String) -> JSONValue {
        let result: JSONValue
        if method == "item/permissions/requestApproval" {
            result = .object(["permissions": .object([:])])
        } else if method.hasSuffix("requestApproval") {
            result = .object(["decision": .string("decline")])
        } else if method == "mcpServer/elicitation/request" {
            result = .object(["action": .string("decline")])
        } else if method == "item/tool/requestUserInput" {
            result = .object(["answers": .object([:])])
        } else {
            return .object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .number(-32601),
                                              "message": .string("Method not supported")])])
        }
        return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func cancel(_ id: Int, error: Error) {
        complete(id, result: .failure(error))
    }

    private func complete(_ id: Int, result: Result<JSONValue, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func connectionEnded(_ token: UUID) {
        guard token == generation else { return }
        disconnect(CodexConnectionError.closed)
    }

    private func disconnect(_ error: Error) {
        generation = UUID()
        initialized = false
        for id in Array(pending.keys) { complete(id, result: .failure(error)) }
        reader?.cancel(); reader = nil
        stderrReader?.cancel(); stderrReader = nil
        try? input?.close(); input = nil
        if process?.isRunning == true { process?.terminate() }
        process?.terminationHandler = nil
        process = nil
        eventContinuation.finish()
    }
}
