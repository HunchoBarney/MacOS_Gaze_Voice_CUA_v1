import XCTest
import JevVoiceCore
@testable import JevVoice

final class CuaConnectionTests: XCTestCase {
    private func fixture() throws -> (CuaConnection, URL) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-fixture-\(UUID()).py")
        try #"""
import json,sys,time
for line in sys.stdin:
    req=json.loads(line)
    if 'id' not in req: continue
    method=req['method']
    if method=='initialize':
        result={'protocolVersion':'2025-03-26','capabilities':{'tools':{}},'serverInfo':{'version':'fixture'}}
    elif method=='tools/list':
        if req['params'].get('cursor')=='second':
            result={'tools':[{'name':'parse_visual_regions','inputSchema':{'type':'object'}}]}
        else:
            result={'tools':[{'name':'screenshot','inputSchema':{'type':'object','properties':{'description':{'type':'string'}}}}],'nextCursor':'second'}
    elif req['params']['name']=='capture':
        result={'structuredContent':{'capture_id':'capture-one'},'content':[{'type':'image','mimeType':'image/png','data':'aW1hZ2U='},{'type':'text','text':'capture metadata'}]}
    elif req['params']['name']=='bad_content': result={'structuredContent':{},'content':{}}
    elif req['params']['name']=='die': sys.exit(0)
    elif req['params']['name']=='wait':
        time.sleep(0.3)
        result={'structuredContent':{'late':True}}
    elif req['params']['name']=='malformed':
        print('invalid-json',flush=True)
        continue
    elif req['params']['name']=='invalid_output': result={'structuredContent':{'code':'tool_output_invalid','execution_state':'unknown','invalid_output':{}}}
    elif req['params']['name']=='native_refusal': result={'isError':True,'structuredContent':{'status':'refused','refusal':{'code':'menu_path_unavailable','message':'private target contents'}}}
    elif req['params']['name']=='refuse_status': result={'structuredContent':{'status':'refused'}}
    elif req['params']['name']=='refuse': result={'structuredContent':{'refusal':{'message':'No target'}}}
    else: result={'structuredContent':{'echo':req['params']['arguments']}}
    print(json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}),flush=True)
"""#.write(to: path, atomically: true, encoding: .utf8)
        return (CuaConnection(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", path.path]), path)
    }

    func testPersistentTransportAndRefusal() async throws {
        let (connection, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try await connection.connect()
        let first = try await connection.call("echo", arguments: ["task": .string("one")])
        let second = try await connection.call("echo", arguments: ["task": .string("two")])
        XCTAssertEqual(first["echo"]?["task"], .string("one"))
        XCTAssertEqual(second["echo"]?["task"], .string("two"))
        do { _ = try await connection.call("refuse", arguments: [:]); XCTFail("Accepted refusal") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .refused("No target")) }
        do { _ = try await connection.call("refuse_status", arguments: [:]); XCTFail("Accepted status-only refusal") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .refused("Cua refused this action.")) }
        do { _ = try await connection.call("invalid_output", arguments: [:]); XCTFail("Accepted invalid upstream output") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .malformed) }
        do { _ = try await connection.call("native_refusal", arguments: [:]); XCTFail("Accepted native refusal") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("menu_path_unavailable"))
            XCTAssertFalse(error.localizedDescription.contains("private target contents"))
        }
        await connection.close()
    }

    func testPreservesCaptureContentAndDiscoversAllToolPages() async throws {
        let (connection, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try await connection.connect()
        let tools = try await connection.tools()
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, ["screenshot", "parse_visual_regions"])
        XCTAssertEqual(tools[0]["inputSchema"]?["properties"]?["description"]?["type"], .string("string"))
        let result = try await connection.callResult("capture", arguments: [:])
        XCTAssertEqual(result.structured["capture_id"], .string("capture-one"))
        XCTAssertEqual(result.content.count, 2)
        XCTAssertEqual(result.content[0]["data"], .string("aW1hZ2U="))
        XCTAssertEqual(result.content[0]["mimeType"], .string("image/png"))
        do { _ = try await connection.callResult("bad_content", arguments: [:]); XCTFail("Accepted malformed content") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .malformed) }
        await connection.close()
    }

    func testTimeoutLateResponseDoesNotSatisfyNextRequest() async throws {
        let (connection, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try await connection.connect()
        do { _ = try await connection.call("wait", arguments: [:], timeout: 0.03); XCTFail("No timeout") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .timedOut) }
        let response = try await connection.call("echo", arguments: ["fresh": .bool(true)])
        XCTAssertEqual(response["echo"]?["fresh"], .bool(true))
        await connection.close()
    }

    func testDeathAndMalformedOutputFailWithoutReconnect() async throws {
        for name in ["die", "malformed"] {
            let (connection, path) = try fixture()
            defer { try? FileManager.default.removeItem(at: path) }
            try await connection.connect()
            do { _ = try await connection.call(name, arguments: [:]); XCTFail("Accepted broken transport") }
            catch { XCTAssertTrue(error is DriverConnectionError) }
            do { _ = try await connection.call("echo", arguments: [:]); XCTFail("Reconnected automatically") }
            catch { XCTAssertEqual(error as? DriverConnectionError, .closed) }
            await connection.close()
        }
    }

    func testCancellationDoesNotConsumeLateResult() async throws {
        let (connection, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try await connection.connect()
        let task = Task { try await connection.call("wait", arguments: [:]) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let value = try await connection.call("echo", arguments: [:])
        XCTAssertEqual(value["echo"], .object([:]))
        await connection.close()
    }

    func testInstalledDriverConnectionOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_TEST"] == "1" else {
            throw XCTSkip("Opt-in observed Driver connection check")
        }
        let connection = CuaConnection()
        try await connection.connect()
        let permissions = try await connection.call("check_permissions", arguments: [:])
        XCTAssertEqual(permissions["accessibility"], .bool(true))
        XCTAssertEqual(permissions["screen_recording"], .bool(true))
        await connection.close()
    }
}
