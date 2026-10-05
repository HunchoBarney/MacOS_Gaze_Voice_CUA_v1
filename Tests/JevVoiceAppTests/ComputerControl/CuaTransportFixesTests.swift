import XCTest
import JevVoiceCore
@testable import JevVoice

/// Transport fixes: deterministic-fault retry narrowing, the outcome-push
/// FIFO, the window-change passthrough, and the shared-daemon pool.
final class CuaTransportFixesTests: XCTestCase {

    /// A stdio JSON-RPC stub that counts tools/call invocations in a file.
    private func fixture() throws -> (CuaConnection, URL, URL) {
        let count = FileManager.default.temporaryDirectory.appendingPathComponent("cua-calls-\(UUID()).count")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-fixture-\(UUID()).py")
        try """
import json,sys
COUNT=\(pythonStringLiteral(path: count.path))
def bump():
    try: n=int(open(COUNT).read())
    except Exception: n=0
    open(COUNT,'w').write(str(n+1))
for line in sys.stdin:
    try: req=json.loads(line)
    except Exception: continue
    if 'id' not in req: continue
    if req['method']=='initialize':
        result={'protocolVersion':'2025-03-26','capabilities':{'tools':{}},'serverInfo':{'version':'fixture'}}
    elif req['method']=='tools/call':
        bump()
        name=req['params']['name']
        if name=='get_window_state':
            print(json.dumps({'jsonrpc':'2.0','id':req['id'],'error':{'code':-32000,'message':'rejected'}}),flush=True)
            continue
        elif name=='list_apps': result={'isError':True,'structuredContent':{'code':'tool_invocation_failed'}}
        elif name=='verify_state': result={'structuredContent':'not-an-object'}
        elif name=='win_top': result={'structuredContent':{'action':'ok'},'content':[{'type':'text','text':'{"new_window_ids":[7],"new_windows":[{"window_id":7}]}'}]}
        elif name=='win_nested': result={'structuredContent':{'action':'ok'},'content':[{'type':'text','text':'done {"changes":{"new_window_ids":[8]}} tail'}]}
        elif name=='win_plain': result={'structuredContent':{'action':'ok'},'content':[{'type':'text','text':'no json here'}]}
        elif name=='list_windows': result={'structuredContent':{'windows':[]},'content':[{'type':'text','text':'{"new_window_ids":[9]}'}]}
        else: result={'structuredContent':{'echo':req['params'].get('arguments',{})}}
    else:
        result={}
    print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
""".write(to: path, atomically: true, encoding: .utf8)
        return (CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", path.path]), path, count)
    }

    private func pythonStringLiteral(path: String) -> String {
        "'" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func callCount(_ url: URL) -> Int {
        (try? String(contentsOf: url)).flatMap(Int.init) ?? 0
    }

    // MARK: - read-fault classification

    func testReadFaultRetriesOnlyTransientTransportFaults() {
        XCTAssertTrue(CuaConnection.transientReadFault(DriverConnectionError.timedOut))
        XCTAssertTrue(CuaConnection.transientReadFault(DriverConnectionError.closed))
        XCTAssertTrue(CuaConnection.transientReadFault(
            DriverConnectionError.toolRefused(tool: "list_apps", code: "tool_invocation_failed", detail: "")))
        // Deterministic failures return immediately — never retried.
        XCTAssertFalse(CuaConnection.transientReadFault(DriverConnectionError.remote("Cua rejected the request.")))
        XCTAssertFalse(CuaConnection.transientReadFault(DriverConnectionError.malformed))
        XCTAssertFalse(CuaConnection.transientReadFault(DriverConnectionError.refused("no")))
        XCTAssertFalse(CuaConnection.transientReadFault(DriverConnectionError.unavailable))
        XCTAssertFalse(CuaConnection.transientReadFault(
            DriverConnectionError.toolRefused(tool: "list_apps", code: "menu_path_unavailable", detail: "")))
        XCTAssertFalse(CuaConnection.transientReadFault(CuaUncertainOutcome(tool: "x", result: .null)))
    }

    /// `page` is polymorphic — mutating actions must never earn the read
    /// retry budget or a transient fault would double-dispatch an effect.
    func testPageMutatingActionsAreNotRetried() {
        XCTAssertTrue(CuaConnection.isReadOnly("page", arguments: ["action": .string("get_text")]))
        XCTAssertTrue(CuaConnection.isReadOnly("page", arguments: ["action": .string("query_dom")]))
        for action in ["execute_javascript", "click_element", "insert_text",
                       "type_keystrokes", "enable_javascript_apple_events", "unknown", ""] {
            XCTAssertFalse(CuaConnection.isReadOnly("page", arguments: ["action": .string(action)]),
                           "\(action) must not retry")
        }
        XCTAssertFalse(CuaConnection.isReadOnly("page", arguments: [:]))
        XCTAssertTrue(CuaConnection.isReadOnly("list_apps", arguments: [:]))
        XCTAssertFalse(CuaConnection.isReadOnly("click", arguments: [:]))
    }

    /// A remote JSON-RPC rejection fails after exactly ONE wire request —
    /// retrying it used to burn 4 calls plus ~3s of backoff for nothing.
    func testRemoteRejectionIsNotRetried() async throws {
        let (connection, path, count) = try fixture()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: count) }
        try await connection.connect()
        do {
            _ = try await connection.call("get_window_state", arguments: [:])
            XCTFail("Accepted a rejected request")
        } catch { XCTAssertEqual(error as? DriverConnectionError, .remote("Cua rejected the request.")) }
        XCTAssertEqual(callCount(count), 1)
        await connection.close()
    }

    /// Malformed envelopes are equally deterministic — one request, no retry.
    func testMalformedResultIsNotRetried() async throws {
        let (connection, path, count) = try fixture()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: count) }
        try await connection.connect()
        do {
            _ = try await connection.call("verify_state", arguments: [:])
            XCTFail("Accepted a malformed result")
        } catch { XCTAssertEqual(error as? DriverConnectionError, .malformed) }
        XCTAssertEqual(callCount(count), 1)
        await connection.close()
    }

    /// tool_invocation_failed is a transport-level fault — a read-only tool
    /// still gets the full retry budget.
    func testInvocationFailureRetriesTheFullBudget() async throws {
        let (connection, path, count) = try fixture()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: count) }
        try await connection.connect()
        do {
            _ = try await connection.call("list_apps", arguments: [:])
            XCTFail("Accepted a wedged invocation")
        } catch {
            guard case .toolRefused(_, let code, _) = error as? DriverConnectionError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "tool_invocation_failed")
        }
        XCTAssertEqual(callCount(count), 4)
        await connection.close()
    }

    // MARK: - window-change passthrough

    func testWindowChangesMergeFromTextBlock() async throws {
        let (connection, path, count) = try fixture()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: count) }
        try await connection.connect()
        let top = try await connection.call("win_top", arguments: [:])
        XCTAssertEqual(top["action"], .string("ok"))
        XCTAssertEqual(top["new_window_ids"], .array([.number(7)]))
        XCTAssertEqual(top["new_windows"], .array([.object(["window_id": .number(7)])]))
        let nested = try await connection.call("win_nested", arguments: [:])
        XCTAssertEqual(nested["new_window_ids"], .array([.number(8)]))
        // A non-JSON text block merges nothing and never breaks the call.
        let plain = try await connection.call("win_plain", arguments: [:])
        XCTAssertNil(plain["new_window_ids"])
        XCTAssertEqual(plain["action"], .string("ok"))
        await connection.close()
    }

    func testStructuredContentKeysAlwaysWin() {
        let body: JSONValue = .object(["new_window_ids": .array([.number(1)])])
        let merged = CuaConnection.mergeWindowChanges(body, content: [
            .object(["text": .string("{\"new_window_ids\":[9]}")])
        ])
        XCTAssertEqual(merged["new_window_ids"], .array([.number(1)]))
    }

    /// Read-only results return as-sent: the detector only appends window
    /// changes to ACTION results, so reads skip the text-block probe — a
    /// read whose text happens to carry the marker is not rewritten either.
    func testReadOnlyResultsSkipWindowChangeMerge() async throws {
        let (connection, path, count) = try fixture()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: count) }
        try await connection.connect()
        let windows = try await connection.call("list_windows", arguments: [:])
        XCTAssertEqual(windows["windows"], .array([]))
        XCTAssertNil(windows["new_window_ids"])
        await connection.close()
    }

    // MARK: - mutation argument purity

    /// Tool schemas are `additionalProperties:false` on the stock driver,
    /// so a per-call observation-tail argument fails validation before any
    /// typed projection can drop it. Mutating calls must travel with only
    /// the caller's own arguments — the daemon-level tail knob lives on the
    /// embedded spawn environment instead.
    func testMutationCallsPassArgumentsUnmodified() async throws {
        let (connection, path, count) = try fixture()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: count) }
        try await connection.connect()

        let mutated = try await connection.call("press_key", arguments: ["key": .string("return")])
        XCTAssertEqual(mutated["echo"], .object(["key": .string("return")]))

        let explicit = try await connection.call("hotkey", arguments: [
            "keys": .array([.string("command"), .string("v")]),
        ])
        XCTAssertEqual(explicit["echo"], .object(["keys": .array([.string("command"), .string("v")])]))
        await connection.close()
    }

    // MARK: - live-connection registry

    func testLiveConnectionCountTracksSpawnedProxies() async throws {
        let base = CuaConnection.liveConnectionCount
        let (connection, path, count) = try fixture()
        defer { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: count) }
        try await connection.connect()
        XCTAssertEqual(CuaConnection.liveConnectionCount, base + 1)
        await connection.close()
        XCTAssertEqual(CuaConnection.liveConnectionCount, base)
    }

    // MARK: - outcome push FIFO

    @MainActor
    func testOutcomeRetryQueueIsFifoAndDropsOldest() {
        var queue = RealtimeVoiceLane.OutcomeRetryQueue()
        XCTAssertTrue(queue.isEmpty)
        for text in ["a", "b", "c", "d", "e"] { queue.push(text) }
        XCTAssertEqual(queue.items, ["b", "c", "d", "e"])
        XCTAssertEqual(queue.drain(), ["b", "c", "d", "e"])
        XCTAssertTrue(queue.isEmpty)
        queue.push("x")
        XCTAssertEqual(queue.drain(), ["x"])
    }

    // MARK: - connection pool

    /// A dual-mode stub: `serve --embedded` mints a socket file and blocks on
    /// the liveness pipe; `mcp --embedded` runs the stdio JSON-RPC loop.
    private func poolFixture() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pool-fixture-\(UUID()).py")
        try """
#!/usr/bin/env python3
import json,sys,os
if len(sys.argv)>1 and sys.argv[1]=='serve':
    socket=sys.argv[sys.argv.index('--socket')+1]
    open(socket,'w').close()
    sys.stdin.read()
    sys.exit(0)
for line in sys.stdin:
    try: req=json.loads(line)
    except Exception: continue
    if 'id' not in req: continue
    if req['method']=='initialize':
        result={'protocolVersion':'2025-03-26','capabilities':{'tools':{}},'serverInfo':{'version':'pool-fixture'}}
    else:
        result={'structuredContent':{'ok':True}}
    print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
""".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    @MainActor
    private func makePool() throws -> (CuaConnectionPool, URL) {
        let script = try poolFixture()
        return (CuaConnectionPool(executable: script), script)
    }

    @MainActor
    func testPoolSharesOneDaemonAcrossLanes() async throws {
        let (pool, script) = try makePool()
        defer { try? FileManager.default.removeItem(at: script) }
        let a = try await pool.connection(label: "alpha")
        let socket = try XCTUnwrap(pool.socketPath)
        let b = try await pool.connection(label: "beta")
        // Second lane reused the daemon — same socket, no second spawn.
        XCTAssertEqual(pool.socketPath, socket)
        XCTAssertFalse(a === b)
        let aConnected = await a.connected
        let bConnected = await b.connected
        XCTAssertTrue(aConnected)
        XCTAssertTrue(bConnected)
        _ = try await b.call("anything", arguments: [:])
        // Same label returns the same live transport.
        let again = try await pool.connection(label: "alpha")
        XCTAssertTrue(again === a)
        await pool.shutdown()
        XCTAssertNil(pool.socketPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
    }

    @MainActor
    func testPoolRemintsOnlyTheDeadProxy() async throws {
        let (pool, script) = try makePool()
        defer { try? FileManager.default.removeItem(at: script) }
        let a = try await pool.connection(label: "alpha")
        let socket = try XCTUnwrap(pool.socketPath)
        await a.close()
        let reminted = try await pool.connection(label: "alpha")
        XCTAssertFalse(a === reminted)
        let reconnected = await reminted.connected
        XCTAssertTrue(reconnected)
        // The daemon was untouched — same socket, no re-mint.
        XCTAssertEqual(pool.socketPath, socket)
        await pool.shutdown()
    }

    @MainActor
    func testPoolRemintsDaemonAndLanesWhenSocketDies() async throws {
        let (pool, script) = try makePool()
        defer { try? FileManager.default.removeItem(at: script) }
        let a = try await pool.connection(label: "alpha")
        let socket = try XCTUnwrap(pool.socketPath)
        try FileManager.default.removeItem(atPath: socket)
        let b = try await pool.connection(label: "beta")
        let newSocket = try XCTUnwrap(pool.socketPath)
        XCTAssertNotEqual(newSocket, socket)
        let bConnected = await b.connected
        XCTAssertTrue(bConnected)
        // The old label's proxy was bound to the removed socket — re-mints lazily.
        let reminted = try await pool.connection(label: "alpha")
        XCTAssertFalse(a === reminted)
        let reconnected = await reminted.connected
        XCTAssertTrue(reconnected)
        await pool.shutdown()
    }
}
