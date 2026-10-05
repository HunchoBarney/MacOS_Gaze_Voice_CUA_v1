import XCTest
import JevVoiceCore
@testable import JevVoice

let mcpTestSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [:]
    return URLSession(configuration: config)
}()

func mcpRequest(_ id: Int, _ method: String, _ params: JSONValue? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method)
    ]
    if let params { object["params"] = params }
    return .object(object)
}

/// Raw JSON-RPC test client for the loopback MCP transport.
@discardableResult
func mcpPost(_ endpoint: LoopbackMCPServer.Endpoint, _ message: JSONValue,
             token: String? = nil) async throws -> (Int, JSONValue?) {
    var request = URLRequest(url: endpoint.url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token ?? endpoint.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(message)
    let (data, response) = try await mcpTestSession.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? -1,
            try? JSONDecoder().decode(JSONValue.self, from: data))
}

/// Recording stand-in for the driver session behind the gate.
actor StubDriverToolCaller: DriverToolCalling {
    struct Call: Equatable {
        var name: String
        var args: [String: JSONValue]
    }
    private(set) var calls: [Call] = []
    var nextResult = CuaToolResult(structured: .object(["ok": .bool(true)]), content: [])
    var nextError: Error?
    var toolList: [JSONValue] = [
        .object(["name": .string("click"), "inputSchema": .object(["type": .string("object")])]),
        .object(["name": .string("list_windows"), "inputSchema": .object(["type": .string("object")])])
    ]
    func callResult(_ name: String, arguments: [String: JSONValue]) async throws -> CuaToolResult {
        calls.append(Call(name: name, args: arguments))
        if let nextError { throw nextError }
        return nextResult
    }
    func tools() async throws -> [JSONValue] { toolList }
    func failWith(_ error: Error?) { nextError = error }
}

/// Recording stand-in for L1's drive loop.
actor RecordingDriveExecutor: DriveExecuting {
    private(set) var tasks: [DriveTask] = []
    var nextResult = DriveResult(status: .done, history: ["pressed Save"], pid: 42, windowID: 9)
    func drive(_ task: DriveTask) async throws -> DriveResult {
        tasks.append(task)
        return nextResult
    }
    func setNext(_ result: DriveResult) { nextResult = result }
}

struct StubSuggester: ActionSuggesting {
    var judgment = StepJudgment(elementToken: "el-3", kind: .press, confidence: 0.9)
    func suggestAction(pid: Int, windowID: Int) async throws -> StepJudgment { judgment }
}

/// Controllable clock for TTL-based gate tests.
final class TestClock: @unchecked Sendable {
    private(set) var now = Date()
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

struct StubError: Error {}

/// Recording stand-in for the shared lane registry — logs every lease
/// event, can refuse focus acquires, and can suspend inside the app
/// acquire so cancellation tests land deterministically.
actor RecordingLaneLeases: AgentLaneLeasing {
    private(set) var events: [String] = []
    private(set) var holding = false
    private var blocksAcquire = false
    private var holdWaiter: CheckedContinuation<Void, Never>?
    private var focusError: Error?

    func acquire(app: String, pid: Int?, workID: String) async throws {
        events.append("acquire:\(app)")
        guard blocksAcquire else { return }
        await withCheckedContinuation { continuation in
            holdWaiter = continuation
            holding = true
        }
        holding = false
    }
    func acquireFocus(workID: String) async throws {
        events.append("focus")
        if let focusError { throw focusError }
    }
    func acquirePasteboard(workID: String) async throws { events.append("pasteboard") }
    func releaseAll(workID: String) async { events.append("releaseAll") }
    func blockAcquires() { blocksAcquire = true }
    func unblock() { holdWaiter?.resume(); holdWaiter = nil }
    func failFocus(_ error: Error?) { focusError = error }
}
