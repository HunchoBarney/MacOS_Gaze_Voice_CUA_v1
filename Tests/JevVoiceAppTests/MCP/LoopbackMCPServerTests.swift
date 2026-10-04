import XCTest
import Network
import JevVoiceCore
@testable import JevVoice

final class LoopbackMCPServerTests: XCTestCase {
    private func makeServer() -> LoopbackMCPServer {
        LoopbackMCPServer(serverName: "test-mcp",
            tools: { [.object(["name": .string("echo"), "inputSchema": .object(["type": .string("object")])])] },
            onCall: { name, args in
                .object([
                    "structuredContent": .object(["echo": .object(["name": .string(name), "args": args])]),
                    "content": .array([.object(["type": .string("text"), "text": .string("ok")])])
                ])
            })
    }

    func testInitializeAndToolsCallRoundTrip() async throws {
        let server = makeServer()
        let endpoint = try await server.start()
        XCTAssertEqual(endpoint.url.host, "127.0.0.1")
        XCTAssertFalse(endpoint.token.isEmpty)

        let (initStatus, initResponse) = try await mcpPost(endpoint, mcpRequest(1, "initialize", .object([
            "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("test"), "version": .string("1")])
        ])))
        XCTAssertEqual(initStatus, 200)
        XCTAssertEqual(initResponse?["result"]?["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(initResponse?["result"]?["serverInfo"]?["name"], .string("test-mcp"))
        XCTAssertNotNil(initResponse?["result"]?["capabilities"]?["tools"])

        let (notifyStatus, notifyBody) = try await mcpPost(endpoint,
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        XCTAssertEqual(notifyStatus, 202)
        XCTAssertNil(notifyBody)

        let (_, toolsResponse) = try await mcpPost(endpoint, mcpRequest(2, "tools/list"))
        let tools = toolsResponse?["result"]?["tools"]?.array
        XCTAssertEqual(tools?.first?["name"], .string("echo"))

        let (_, callResponse) = try await mcpPost(endpoint, mcpRequest(3, "tools/call", .object([
            "name": .string("echo"), "arguments": .object(["text": .string("hi")])
        ])))
        XCTAssertEqual(callResponse?["result"]?["structuredContent"]?["echo"]?["name"], .string("echo"))
        XCTAssertEqual(callResponse?["result"]?["structuredContent"]?["echo"]?["args"]?["text"], .string("hi"))
        await server.stop()
    }

    func testBearerTokenRequired() async throws {
        let server = makeServer()
        let endpoint = try await server.start()
        let (wrongStatus, _) = try await mcpPost(endpoint, mcpRequest(1, "initialize"), token: "wrong")
        XCTAssertEqual(wrongStatus, 401)

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(mcpRequest(1, "initialize"))
        let (data, response) = try await mcpTestSession.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(data.isEmpty)
        await server.stop()
    }

    func testUnknownMethodAndGarbage() async throws {
        let server = makeServer()
        let endpoint = try await server.start()
        let (_, unknown) = try await mcpPost(endpoint, mcpRequest(1, "resources/list"))
        XCTAssertEqual(unknown?["error"]?["code"], .number(-32601))

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("not json".utf8)
        let (data, response) = try await mcpTestSession.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data)["error"]?["code"], .number(-32700))
        await server.stop()
    }

    func testRestartAfterStop() async throws {
        let server = makeServer()
        _ = try await server.start()
        await server.stop()
        let endpoint = try await server.start()
        let (status, response) = try await mcpPost(endpoint, mcpRequest(1, "ping"))
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(response?["result"])
        await server.stop()
    }

    private func rawPeer(to endpoint: LoopbackMCPServer.Endpoint) throws -> NWConnection {
        let port = try XCTUnwrap(endpoint.url.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
        let connection = NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: .tcp)
        connection.start(queue: .global())
        return connection
    }

    func testStalledConnectionIsCutByReadDeadline() async throws {
        let server = LoopbackMCPServer(serverName: "test-mcp", readDeadline: 0.3,
            tools: { [] }, onCall: { _, _ in .object([:]) })
        let endpoint = try await server.start()
        let peer = try rawPeer(to: endpoint)
        try await Task.sleep(for: .seconds(1.0))
        let stalled = await server.connectionCount
        XCTAssertEqual(stalled, 0, "a peer that never sends must be reaped")
        peer.cancel()
        await server.stop()
    }

    func testConnectionMapIsBounded() async throws {
        let server = LoopbackMCPServer(serverName: "test-mcp", readDeadline: 5, maxConnections: 2,
            tools: { [] }, onCall: { _, _ in .object([:]) })
        let endpoint = try await server.start()
        var peers: [NWConnection] = []
        for _ in 0..<5 { peers.append(try rawPeer(to: endpoint)) }
        try await Task.sleep(for: .seconds(0.5))
        let bounded = await server.connectionCount
        XCTAssertLessThanOrEqual(bounded, 2)
        peers.forEach { $0.cancel() }
        await server.stop()
    }
}
