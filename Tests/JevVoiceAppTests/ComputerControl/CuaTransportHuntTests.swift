import XCTest
import JevVoiceCore
@testable import JevVoice

/// Hunt regressions: the refusal-storm guard must fire only on genuine
/// daemon refusals, daemon invalidation is token-scoped against re-mint
/// races, and reconnect resets the timeout streak.
final class CuaTransportHuntTests: XCTestCase {

    /// list_apps storms tool_invocation_failed, get_desktop_state sleeps
    /// past the caller's timeout, get_window_state kills the transport,
    /// die exits mid-call, anything else echoes.
    private func fixture() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-hunt-\(UUID()).py")
        try """
#!/usr/bin/env python3
import json,sys,time
for line in sys.stdin:
    try: req=json.loads(line)
    except Exception: continue
    if 'id' not in req: continue
    if req['method']=='initialize':
        result={'protocolVersion':'2025-03-26','capabilities':{'tools':{}},'serverInfo':{'version':'fixture'}}
    elif req['method']=='tools/call':
        name=req['params']['name']
        if name=='list_apps': result={'isError':True,'structuredContent':{'code':'tool_invocation_failed','exit_code':1},'content':[{'type':'text','text':'daemon wedge'}]}
        elif name=='get_desktop_state':
            time.sleep(0.4)
            result={'structuredContent':{'late':True}}
        elif name=='get_window_state': sys.exit(0)
        elif name=='wait':
            time.sleep(0.4)
            result={'structuredContent':{'late':True}}
        elif name=='die': sys.exit(0)
        else: result={'structuredContent':{'echo':req['params'].get('arguments',{})}}
    else:
        result={}
    print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
""".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    private func connection(_ path: URL,
                            fault: (@Sendable (String) -> Void)? = nil) -> CuaConnection {
        CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                      arguments: ["-u", path.path],
                      onDaemonSocketFault: fault)
    }

    /// A slow read that burns its whole retry budget on .timedOut (then
    /// .closed after noteTimeout tears the transport down) is a local
    /// transport death — the caller re-mints. It must NOT report a daemon
    /// fault: a healthy shared daemon would be killed under every lane.
    func testTimeoutStormDoesNotReportDaemonFault() async throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        var faulted = false
        let conn = connection(path, fault: { _ in faulted = true })
        try await conn.connect()
        do {
            _ = try await conn.call("get_desktop_state", arguments: [:], timeout: 0.03)
            XCTFail("Accepted a wedged read")
        } catch { XCTAssertEqual(error as? DriverConnectionError, .closed) }
        XCTAssertFalse(faulted, "a timeout storm is a dead proxy, not a sick daemon")
        await conn.close()
    }

    /// Same for a proxy that dies mid-read: every retry fails .closed, the
    /// budget exhausts on a transport fault — never a daemon-health fault.
    func testClosedTransportStormDoesNotReportDaemonFault() async throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        var faulted = false
        let conn = connection(path, fault: { _ in faulted = true })
        try await conn.connect()
        do {
            _ = try await conn.call("get_window_state", arguments: [:])
            XCTFail("Accepted a dead transport")
        } catch { XCTAssertEqual(error as? DriverConnectionError, .closed) }
        XCTAssertFalse(faulted, "a dead proxy exhausts on .closed, not a daemon storm")
        await conn.close()
    }

    /// The genuine storm still fires — and hands the pool the socket the
    /// proxy was bound to, so a delayed fault can be matched against the
    /// daemon generation it referred to.
    func testRefusalStormReportsBoundSocket() async throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        let socket = "/tmp/jev-hunt-\(UUID().uuidString.prefix(8)).sock"
        var faulted = false
        var reported: String?
        // The socketProvider path launches the executable itself with
        // `mcp --embedded` args — the fixture is executable for that reason.
        let conn = CuaConnection(executable: path,
                                 socketProvider: { socket },
                                 onDaemonHealthFault: { faulted = true },
                                 onDaemonSocketFault: { reported = $0 })
        try await conn.connect()
        do {
            _ = try await conn.call("list_apps", arguments: [:])
            XCTFail("Accepted a refusal storm")
        } catch {
            guard case .toolRefused(_, let code, _) = error as? DriverConnectionError else {
                return XCTFail("expected toolRefused, got \(error)")
            }
            XCTAssertEqual(code, "tool_invocation_failed")
        }
        XCTAssertTrue(faulted, "a refusal storm must report the daemon fault")
        XCTAssertEqual(reported, socket, "the fault must carry the bound daemon socket")
        let stillUp = await conn.connected
        XCTAssertFalse(stillUp, "storm must tear the transport down")
        await conn.close()
    }

    /// consecutiveTimeouts used to survive a transport swap: one timeout on
    /// the old proxy plus one on the fresh proxy meant instant death. A
    /// reconnect must reset the streak — one timeout leaves the transport
    /// alive enough to answer the next call. `wait` is a mutating tool (one
    /// attempt, no retry) so each lifetime sees exactly ONE timeout.
    func testReconnectResetsTimeoutStreak() async throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        let conn = connection(path)
        try await conn.connect()
        do { _ = try await conn.call("wait", arguments: [:], timeout: 0.03); XCTFail("No timeout") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .timedOut) }
        // Kill the transport wholesale so connect() mints a fresh proxy.
        do { _ = try await conn.call("die", arguments: [:]); XCTFail("Dead transport replied") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .closed) }
        try await conn.connect()
        do { _ = try await conn.call("wait", arguments: [:], timeout: 0.03); XCTFail("No timeout") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .timedOut) }
        // Second lifetime, first timeout — the transport must still answer.
        let echo = try await conn.call("echo", arguments: ["fresh": .bool(true)])
        XCTAssertEqual(echo["echo"]?["fresh"], .bool(true))
        await conn.close()
    }

    /// The pool fixture — `serve --embedded` mints a socket and blocks on
    /// the liveness pipe; `mcp --embedded` runs the stdio JSON-RPC loop.
    private func poolFixture() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pool-hunt-\(UUID()).py")
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

    /// Two lanes storming on generation N queue two invalidations; if a
    /// re-mint lands between them, the stale fault must not stop the
    /// healthy generation N+1.
    @MainActor
    func testStaleDaemonFaultDoesNotKillRemintedDaemon() async throws {
        let script = try poolFixture()
        defer { try? FileManager.default.removeItem(at: script) }
        let pool = CuaConnectionPool(executable: script)
        let first = try await pool.socket()
        // A fault naming a socket the pool never minted is a no-op.
        await pool.invalidateDaemon(matching: first + "-stale")
        XCTAssertEqual(pool.socketPath, first)
        // A fault against the live generation recycles it.
        await pool.invalidateDaemon(matching: first)
        XCTAssertNil(pool.socketPath)
        // Lazy re-mint on next use...
        let second = try await pool.socket()
        XCTAssertNotEqual(second, first)
        // ...and the delayed duplicate fault must leave it standing.
        await pool.invalidateDaemon(matching: first)
        XCTAssertEqual(pool.socketPath, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second))
        await pool.shutdown()
    }

    /// Invalidation drops the proxies bound to the recycled daemon and the
    /// pool keeps serving — the next lane mints a proxy on a fresh daemon.
    @MainActor
    func testInvalidationClosesVictimProxiesAndPoolRecovers() async throws {
        let script = try poolFixture()
        defer { try? FileManager.default.removeItem(at: script) }
        let pool = CuaConnectionPool(executable: script)
        let victim = try await pool.connection(label: "alpha")
        let socket = try XCTUnwrap(pool.socketPath)
        let victimUp = await victim.connected
        XCTAssertTrue(victimUp)
        await pool.invalidateDaemon(matching: socket)
        let victimDown = await victim.connected
        XCTAssertFalse(victimDown, "proxies bound to the recycled daemon must close")
        XCTAssertNil(pool.socketPath)
        let fresh = try await pool.connection(label: "beta")
        let freshUp = await fresh.connected
        XCTAssertTrue(freshUp)
        XCTAssertNotEqual(pool.socketPath, socket)
        let ok = try await fresh.call("anything", arguments: [:])
        XCTAssertEqual(ok["ok"], .bool(true))
        await pool.shutdown()
    }
}
