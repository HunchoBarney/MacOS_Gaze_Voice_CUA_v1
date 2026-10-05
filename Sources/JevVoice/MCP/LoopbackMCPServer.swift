import Foundation
import Network
import JevVoiceCore

/// Localhost HTTP+bearer JSON-RPC server — the MCP surface Codex agents
/// connect to. One instance per agent-facing endpoint (computer-use gate,
/// jev-use); the coordinator mints the token, writes `url` + token into the
/// agent's `mcp_servers` config, and the bearer check keeps other local
/// processes out. One POST per connection, `Connection: close`.
actor LoopbackMCPServer {
    struct Endpoint: Sendable, Equatable {
        let url: URL
        let token: String
    }
    enum ServerError: Error {
        case alreadyStarted, notRunning, closed, oversized, malformed
    }

    private static let knownProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    private static let byteLimit = 16 * 1024 * 1024

    private let serverName: String
    private let serverVersion: String
    private let path: String
    private let token: String
    /// Per-connection lifetime cap — a stalled or drip-fed peer is cancelled
    /// once this elapses instead of pinning a connection slot forever.
    private let readDeadline: TimeInterval
    /// Hard bound on live connections; extra peers are refused outright.
    private let maxConnections: Int
    private let toolsProvider: @Sendable () async throws -> [JSONValue]
    private let callHandler: @Sendable (_ name: String, _ arguments: JSONValue) async throws -> JSONValue
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    /// Live connection count — diagnostics/tests.
    var connectionCount: Int { connections.count }

    init(serverName: String, serverVersion: String = "1", path: String = "/mcp", token: String? = nil,
         readDeadline: TimeInterval = 300, maxConnections: Int = 64,
         tools: @escaping @Sendable () async throws -> [JSONValue],
         onCall: @escaping @Sendable (_ name: String, _ arguments: JSONValue) async throws -> JSONValue) {
        self.serverName = serverName; self.serverVersion = serverVersion; self.path = path
        self.token = token ?? (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        self.readDeadline = readDeadline; self.maxConnections = maxConnections
        self.toolsProvider = tools; self.callHandler = onCall
    }

    deinit { listener?.cancel() }

    /// Binds 127.0.0.1 on an ephemeral port; resolves once the listener is ready.
    func start() async throws -> Endpoint {
        guard listener == nil else { throw ServerError.alreadyStarted }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let path = self.path, token = self.token
        do {
            return try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        guard let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)") else {
                            continuation.resume(throwing: ServerError.notRunning); return
                        }
                        continuation.resume(returning: Endpoint(url: url, token: token))
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: ServerError.notRunning)
                    default: break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        } catch {
            // Reset so a failed listener can be re-started instead of bricking
            // the server behind `alreadyStarted`.
            if self.listener === listener { self.listener = nil }
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            throw error
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < maxConnections else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global(qos: .userInitiated))
        Task { await serve(connection, id: id) }
    }

    private func serve(_ connection: NWConnection, id: UUID) async {
        // Connection idle watchdog, not a per-request timeout: drive_until
        // and other long multi-turn calls must stay alive across many
        // seconds with no traffic. Tests override this for fast reap checks.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(readDeadline))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer {
            watchdog.cancel()
            connection.cancel()
            connections[id] = nil
        }
        guard Self.loopback(connection.endpoint),
              let request = try? await Self.readRequest(connection) else {
            await Self.send(connection, status: "400 Bad Request", body: Data())
            return
        }
        guard request.method == "POST" else {
            await Self.send(connection, status: "405 Method Not Allowed", body: Data())
            return
        }
        guard request.path == path else {
            await Self.send(connection, status: "404 Not Found", body: Data())
            return
        }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            await Self.send(connection, status: "401 Unauthorized", body: Data())
            return
        }
        if let response = await respond(to: request.body) {
            let data = (try? JSONEncoder().encode(response)) ?? Data()
            await Self.send(connection, status: "200 OK", contentType: "application/json", body: data)
        } else {
            await Self.send(connection, status: "202 Accepted", body: Data())
        }
    }

    /// Only loopback peers ever reach dispatch; the bearer token is the real
    /// auth — this is defense in depth, not a substitute.
    private static func loopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address): return address == .loopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    private static func readRequest(_ connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        var headerEnd: Data.Index?
        while headerEnd == nil {
            guard let chunk = try await receive(connection, upTo: 64 * 1024), !chunk.isEmpty else { throw ServerError.closed }
            buffer.append(chunk)
            guard buffer.count <= byteLimit else { throw ServerError.oversized }
            headerEnd = buffer.range(of: Data([13, 10, 13, 10]))?.upperBound
        }
        guard let headerEnd, let head = String(data: buffer.prefix(upTo: headerEnd), encoding: .utf8) else {
            throw ServerError.malformed
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw ServerError.malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        guard length >= 0, length <= byteLimit else { throw ServerError.oversized }
        var body = Data(buffer.suffix(from: headerEnd))
        while body.count < length {
            guard let chunk = try await receive(connection, upTo: length - body.count), !chunk.isEmpty else { throw ServerError.closed }
            body.append(chunk)
        }
        return HTTPRequest(method: String(requestLine[0]),
                           path: requestLine[1].split(separator: "?").first.map(String.init) ?? "",
                           headers: headers, body: body.prefix(length))
    }

    private static func receive(_ connection: NWConnection, upTo limit: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: limit) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
    }

    private static func send(_ connection: NWConnection, status: String, contentType: String? = nil, body: Data) async {
        var head = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// One JSON-RPC message in, one response out — nil means the message was
    /// a notification and the HTTP layer should answer 202 with no body.
    private func respond(to body: Data) async -> JSONValue? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body), message.object != nil else {
            return Self.error(id: .null, code: -32700, message: "Parse error")
        }
        guard let method = message["method"]?.string else {
            return Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request")
        }
        guard let id = message["id"], id != .null else { return nil }
        switch method {
        case "initialize":
            let requested = message["params"]?["protocolVersion"]?.string
            let version = requested.flatMap { Self.knownProtocolVersions.contains($0) ? $0 : nil } ?? "2025-03-26"
            return Self.result(id: id, value: .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)])
            ]))
        case "ping":
            return Self.result(id: id, value: .object([:]))
        case "tools/list":
            do {
                return Self.result(id: id, value: .object(["tools": .array(try await toolsProvider())]))
            } catch {
                return Self.error(id: id, code: -32000, message: "tools/list failed")
            }
        case "tools/call":
            guard let name = message["params"]?["name"]?.string else {
                return Self.error(id: id, code: -32602, message: "Invalid params")
            }
            let arguments = message["params"]?["arguments"] ?? .object([:])
            do {
                return Self.result(id: id, value: try await callHandler(name, arguments))
            } catch {
                return Self.result(id: id, value: Self.toolError(error))
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found")
        }
    }

    private static func toolError(_ error: Error) -> JSONValue {
        let message = (error as? LocalizedError)?.errorDescription ?? "The tool call failed."
        return .object([
            "isError": .bool(true),
            "structuredContent": .object(["code": .string("tool_error"), "message": .string(message)]),
            "content": .array([.object(["type": .string("text"), "text": .string(message)])])
        ])
    }

    private static func result(id: JSONValue, value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
