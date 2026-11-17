import XCTest
@testable import JevVoice
import JevVoiceCore

/// Dual-lane routing: the daemon serializes each connection's legacy
/// `tools/call` per transport, so reads must land on a SECOND connection
/// to overlap a mutation. Recording fakes pin which lane each pool call
/// actually touches — and prove reads and writes interleave with no
/// shared `pending` state.
final class DriverConnectionPoolTests: XCTestCase {

    /// Records every interaction; configurable failure for connect/call.
    private actor FakeLane: CuaLane {
        var connected = false
        var boundSocket: String?
        private(set) var called: [(name: String, args: [String: JSONValue])] = []
        private(set) var connectSockets: [String] = []
        private(set) var closeCount = 0
        private(set) var cursorSets: [(enabled: Bool, session: String)] = []
        var connectError: Error?
        var callError: Error?
        var callReturn: JSONValue = .object(["ok": .bool(true)])

        func connect(socket: String) async throws {
            connectSockets.append(socket)
            if let connectError { throw connectError }
            boundSocket = socket
            connected = true
        }
        func call(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
            called.append((name, arguments))
            if let callError { throw callError }
            return callReturn
        }
        func callResult(_ name: String, arguments: [String: JSONValue], timeout: TimeInterval) async throws -> CuaToolResult {
            called.append((name, arguments))
            if let callError { throw callError }
            return CuaToolResult(structured: callReturn, content: [])
        }
        func setAgentCursorEnabled(_ enabled: Bool, session: String) async {
            cursorSets.append((enabled: enabled, session: session))
        }
        func close() { closeCount += 1 }
        func failConnect(_ error: Error) { connectError = error }
        func markDisconnected() { connected = false }
    }

    private func pool() -> (CuaConnectionPool<FakeLane>, FakeLane, FakeLane) {
        let primary = FakeLane(), read = FakeLane()
        return (CuaConnectionPool(primary: primary, readConnection: read), primary, read)
    }

    // MARK: - Routing

    /// Mutations (and anything not asserted read-only) ride `primary`.
    func testCallRoutesToPrimaryOnly() async throws {
        let (pool, primary, read) = pool()
        let result = try await pool.call("click", arguments: ["session": .string("s")])
        XCTAssertEqual(result, .object(["ok": .bool(true)]))
        let primaryCalls = await primary.called
        XCTAssertEqual(primaryCalls.map { $0.name }, ["click"])
        let readCalls = await read.called
        XCTAssertEqual(readCalls.count, 0)
    }

    /// `callRead` dispatches on `readConnection` — never on `primary`.
    func testCallReadRoutesToReadConnectionOnly() async throws {
        let (pool, primary, read) = pool()
        let result = try await pool.callRead("list_apps", arguments: [:])
        XCTAssertEqual(result, .object(["ok": .bool(true)]))
        let readCalls = await read.called
        XCTAssertEqual(readCalls.map { $0.name }, ["list_apps"])
        let primaryCalls = await primary.called
        XCTAssertTrue(primaryCalls.isEmpty)
    }

    /// A mutation name on `callRead` throws before the wire — two
    /// in-flight GUI effects could race the same target.
    func testCallReadRefusesMutatingTool() async {
        let (pool, primary, read) = pool()
        do {
            _ = try await pool.callRead("click", arguments: ["session": .string("s")])
            XCTFail("a mutation must never reach the read lane")
        } catch let error as DriverConnectionError {
            guard case .remote = error else {
                return XCTFail("expected .remote, got \(error)")
            }
        } catch { XCTFail("expected DriverConnectionError, got \(error)") }
        let readCalls = await read.called
        XCTAssertTrue(readCalls.isEmpty)
        let primaryCalls = await primary.called
        XCTAssertTrue(primaryCalls.isEmpty)
    }

    /// `page` enforcement is argument-aware like `isReadOnly`: get_text
    /// routes, click_element refuses before the wire.
    func testCallReadPageIsActionAware() async throws {
        let (pool, _, read) = pool()
        _ = try await pool.callRead("page", arguments: ["action": .string("get_text")])
        do {
            _ = try await pool.callRead("page", arguments: ["action": .string("click_element")])
            XCTFail("a mutating page action must never reach the read lane")
        } catch {}
        let readCalls = await read.called
        XCTAssertEqual(readCalls.map { $0.name }, ["page"])
        XCTAssertEqual(readCalls.first?.args["action"], .string("get_text"))
    }

    /// Reads and writes interleave across lanes with independent pending
    /// state — both resolve; neither lane sees the other's call.
    func testReadAndWriteInterleaveSafely() async throws {
        let (pool, primary, read) = pool()
        async let write = pool.call("type_text", arguments: ["text": .string("x")])
        async let read1 = pool.callRead("get_window_state", arguments: [:])
        async let read2 = pool.callRead("get_agent_cursor_state", arguments: [:])
        _ = try await (write, read1, read2)
        let primaryCalls = await primary.called
        XCTAssertEqual(primaryCalls.map { $0.name }, ["type_text"])
        let readCalls = await read.called
        XCTAssertEqual(Set(readCalls.map { $0.name }),
                       ["get_window_state", "get_agent_cursor_state"])
    }

    // MARK: - Lifecycle

    /// One socket binds both lanes — the pair shares one daemon.
    func testConnectBindsBothLanesToSameSocket() async throws {
        let (pool, primary, read) = pool()
        try await pool.connect(socket: "/tmp/jev-test.sock")
        let primarySockets = await primary.connectSockets
        let readSockets = await read.connectSockets
        XCTAssertEqual(primarySockets, ["/tmp/jev-test.sock"])
        XCTAssertEqual(readSockets, ["/tmp/jev-test.sock"])
        let connected = await pool.connected
        XCTAssertTrue(connected)
        let bound = await pool.boundSocket
        XCTAssertEqual(bound, "/tmp/jev-test.sock")
    }

    /// A failed second bind tears the first lane down — no stranded proxy.
    func testConnectFailureClosesBothLanes() async {
        let (pool, primary, read) = pool()
        await read.failConnect(DriverConnectionError.unavailable)
        do {
            try await pool.connect(socket: "/tmp/jev-test.sock")
            XCTFail("connect should rethrow the lane failure")
        } catch {}
        let primaryCloses = await primary.closeCount
        let readCloses = await read.closeCount
        XCTAssertEqual(primaryCloses, 1)
        XCTAssertEqual(readCloses, 1)
        let connected = await pool.connected
        XCTAssertFalse(connected)
    }

    /// `connected` requires BOTH lanes — a dead lane strands the pair.
    func testConnectedRequiresBothLanes() async throws {
        let (pool, primary, _) = pool()
        try await pool.connect(socket: "/tmp/jev-test.sock")
        var connected = await pool.connected
        XCTAssertTrue(connected)
        await primary.markDisconnected()
        connected = await pool.connected
        XCTAssertFalse(connected)
    }

    /// One teardown ends both lanes.
    func testCloseEndsBothLanes() async {
        let (pool, primary, read) = pool()
        await pool.close()
        let primaryCloses = await primary.closeCount
        let readCloses = await read.closeCount
        XCTAssertEqual(primaryCloses, 1)
        XCTAssertEqual(readCloses, 1)
    }

    // MARK: - Cursor helper

    /// `set_agent_cursor_enabled` is a mutation — it routes over `primary`.
    func testSetAgentCursorEnabledRoutesToPrimary() async {
        let (pool, primary, read) = pool()
        await pool.setAgentCursorEnabled(false, session: "s1")
        let sets = await primary.cursorSets
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.enabled, false)
        XCTAssertEqual(sets.first?.session, "s1")
        let readSets = await read.cursorSets
        XCTAssertTrue(readSets.isEmpty)
    }
}
