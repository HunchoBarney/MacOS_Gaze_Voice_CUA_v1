import Darwin
import Foundation
import XCTest
@testable import Jarvis
import JarvisCore

/// The host connection speaks to the daemon socket directly: one
/// `mcp_envelope_stream` request line, one acknowledgement, then MCP. A
/// fake daemon on a private socket plays the daemon's side.
final class CuaHostStreamTests: XCTestCase {

    /// A one-connection Unix socket server. `reply` maps each received
    /// line to the lines to send back; returning nil closes the connection.
    private final class FakeDaemon: @unchecked Sendable {
        let path: String
        private let listener: Int32
        private let lock = NSLock()
        private var lines: [String] = []
        var received: [String] { lock.withLock { lines } }

        init(reply: @escaping @Sendable (String) -> [String]?) throws {
            let directory = try XCTUnwrap(CuaSocketDirectory.create(in: "/tmp"))
            path = directory + "/d.sock"
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(bound, 0)
            XCTAssertEqual(Darwin.listen(fd, 1), 0)
            listener = fd
            Thread.detachNewThread { [self] in
                let peer = Darwin.accept(fd, nil, nil)
                guard peer >= 0 else { return }
                defer { Darwin.close(peer) }
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(peer, &chunk, chunk.count)
                    guard count > 0 else { return }
                    buffer.append(contentsOf: chunk[..<count])
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeSubrange(...newline)
                        lock.withLock { lines.append(line) }
                        guard let replies = reply(line) else { return }
                        for reply in replies {
                            let data = Array((reply + "\n").utf8)
                            _ = data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
                        }
                    }
                }
            }
        }

        deinit {
            Darwin.close(listener)
            unlink(path)
            rmdir((path as NSString).deletingLastPathComponent)
        }
    }

    private static func mcpReply(_ line: String) -> [String]? {
        if line == #"{"method":"mcp_envelope_stream"}"# {
            return [#"{"ok":true,"result":{"mcp_envelope_stream":1}}"#]
        }
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let id = frame["id"]?.integer else { return [] }
        switch frame["method"]?.string {
        case "initialize":
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"cua-driver","version":"0.54.0"}}}"#]
        case "tools/list":
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[]}}"#]
        case "tools/call":
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[],"structuredContent":{"apps":[]}}}"#]
        default:
            return []
        }
    }

    func testEnvelopeAcknowledgementMustOpenTheStream() {
        XCTAssertTrue(CuaConnection.acceptsEnvelopeAcknowledgement(
            Data(#"{"ok":true,"result":{"mcp_envelope_stream":1}}"#.utf8)))
        for refusal in [#"{"ok":false,"error":"MCP envelope stream unavailable","code":77}"#,
                        #"{"ok":true,"result":{}}"#, #"{"ok":true,"result":{"mcp_envelope_stream":2}}"#, "", "not json"] {
            XCTAssertFalse(CuaConnection.acceptsEnvelopeAcknowledgement(Data(refusal.utf8)), refusal)
        }
    }

    func testHostConnectionUpgradesThenSpeaksMCPOnTheSameSocket() async throws {
        let daemon = try FakeDaemon(reply: Self.mcpReply)
        let connection = CuaConnection(onSickDaemon: nil)
        try await connection.connect(socket: daemon.path)
        let isConnected = await connection.connected
        XCTAssertTrue(isConnected)
        let apps = try await connection.call("list_apps", arguments: [:])
        XCTAssertEqual(apps["apps"], .array([]))
        let lines = daemon.received
        XCTAssertEqual(lines.first, #"{"method":"mcp_envelope_stream"}"#)
        let methods = lines.dropFirst().compactMap {
            (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?["method"]?.string
        }
        XCTAssertEqual(Array(methods.prefix(2)), ["initialize", "notifications/initialized"])
        XCTAssertEqual(methods.last, "tools/call")
        await connection.close()
        let stillConnected = await connection.connected
        XCTAssertFalse(stillConnected)
    }

    /// Under `--host-connections-only` a refused peer's connection closes
    /// before the daemon reads a request: connect fails and never retries.
    func testRefusedPeerFailsToConnect() async throws {
        let daemon = try FakeDaemon(reply: { _ in nil })
        let connection = CuaConnection(onSickDaemon: nil)
        do {
            try await connection.connect(socket: daemon.path)
            XCTFail("A refused stream connected")
        } catch {
            XCTAssertEqual(error as? DriverConnectionError, .closed)
        }
        let isConnected = await connection.connected
        XCTAssertFalse(isConnected)
    }

    func testDaemonWithoutEnvelopesIsRefused() async throws {
        let daemon = try FakeDaemon(reply: { _ in [#"{"ok":false,"error":"MCP envelope stream unavailable","code":77}"#] })
        let connection = CuaConnection(onSickDaemon: nil)
        do {
            try await connection.connect(socket: daemon.path)
            XCTFail("A daemon without envelope streams connected")
        } catch {
            XCTAssertEqual(error as? DriverConnectionError, .refused("The Cua daemon did not open an MCP stream."))
        }
    }
}
