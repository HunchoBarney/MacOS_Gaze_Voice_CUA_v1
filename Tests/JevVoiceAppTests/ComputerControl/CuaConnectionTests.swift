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
    elif req['params']['name']=='check_permissions':
        arguments=req['params']['arguments']
        if not set(arguments).issubset({'prompt','probe_direct_capture'}):
            result={'isError':True,'structuredContent':{'refusal':{'message':'unknown permission field'}}}
        else:
            result={'structuredContent':{'accessibility':False,'screen_recording':False}}
    elif req['params']['name']=='bad_content': result={'structuredContent':{},'content':{}}
    elif req['params']['name']=='die': sys.exit(0)
    elif req['params']['name']=='wait':
        time.sleep(0.3)
        result={'structuredContent':{'late':True}}
    elif req['params']['name']=='malformed':
        print('invalid-json',flush=True)
        continue
    elif req['params']['name']=='invalid_output': result={'structuredContent':{'code':'tool_output_invalid','execution_state':'unknown','invalid_output':{}}}
    elif req['params']['name']=='partial_effect': result={'isError':True,'structuredContent':{'status':'partial','observed':{'focused':False},'private':'fixture content'}}
    elif req['params']['name']=='indeterminate_text': result={'isError':True,'structuredContent':{'effect':'indeterminate','code':'type_text_synthesis_budget_exceeded','retryable':False,'escalation':{'recommended':'verify_state'}}}
    elif req['params']['name']=='partial_text': result={'structuredContent':{'effect':'partial','requested_chars':10,'delivered_chars':4}}
    elif req['params']['name']=='native_refusal': result={'isError':True,'structuredContent':{'status':'refused','refusal':{'code':'menu_path_unavailable','message':'private target contents'}}}
    elif req['params']['name']=='refuse_status': result={'structuredContent':{'status':'refused'}}
    elif req['params']['name']=='effect_refusal': result={'structuredContent':{'effect':'refused','escalation':{'reason':'route_unavailable','target':'page'}}}
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
        do { _ = try await connection.call("effect_refusal", arguments: [:]); XCTFail("Accepted effect-only refusal") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .refused("Cua refused this action.")) }
        do { _ = try await connection.call("invalid_output", arguments: [:]); XCTFail("Accepted invalid upstream output") }
        catch {
            let uncertain = try XCTUnwrap(error as? CuaUncertainOutcome)
            XCTAssertEqual(uncertain.result["execution_state"], .string("unknown"))
        }
        do { _ = try await connection.call("partial_effect", arguments: [:]); XCTFail("Accepted partial effect") }
        catch {
            let uncertain = try XCTUnwrap(error as? CuaUncertainOutcome)
            XCTAssertEqual(uncertain.tool, "partial_effect")
            XCTAssertEqual(uncertain.result["observed"]?["focused"], .bool(false))
            XCTAssertFalse(error.localizedDescription.contains("fixture content"))
        }
        do { _ = try await connection.call("partial_text", arguments: [:]); XCTFail("Accepted partial text as success") }
        catch {
            let uncertain = try XCTUnwrap(error as? CuaUncertainOutcome)
            XCTAssertEqual(uncertain.result["delivered_chars"], .number(4))
        }
        do { _ = try await connection.call("indeterminate_text", arguments: [:]); XCTFail("Accepted indeterminate text") }
        catch {
            let uncertain = try XCTUnwrap(error as? CuaUncertainOutcome)
            XCTAssertEqual(uncertain.result["retryable"], .bool(false))
            XCTAssertEqual(uncertain.result["escalation"]?["recommended"], .string("verify_state"))
        }
        do { _ = try await connection.call("native_refusal", arguments: [:]); XCTFail("Accepted native refusal") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("menu_path_unavailable"))
            XCTAssertFalse(error.localizedDescription.contains("private target contents"))
        }
        await connection.close()
    }

    func testSetupPermissionProbeMatchesTheInstalledToolInputSchema() async throws {
        let (connection, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        try await connection.connect()

        let permissions = try await CuaPermissionProbe.read(using: connection)

        XCTAssertEqual(permissions["accessibility"], .bool(false))
        XCTAssertEqual(permissions["screen_recording"], .bool(false))
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
        let permissions = try await connection.call("check_permissions", arguments: ["prompt": .bool(false)])
        XCTAssertEqual(permissions["accessibility"], .bool(true))
        XCTAssertEqual(permissions["screen_recording"], .bool(true))
        await connection.close()
    }

    func testInstalledSetupTargetWindowInventoryOptIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_CUA_SETUP_WINDOW_INVENTORY"] == "1",
              let titleFragment = environment["JARVIS_CUA_SETUP_WINDOW_TITLE_FRAGMENT"],
              !titleFragment.isEmpty else {
            throw XCTSkip("Opt-in read-only inventory for one disposable setup window")
        }
        let connection = CuaConnection()
        try await connection.connect()
        let session = "Jarvis setup inventory \(UUID().uuidString.prefix(8))"
        _ = try await connection.call("start_session", arguments: ["session": .string(session)])
        do {
            let definitions = try await connection.tools()
            let launchSchema = definitions.first { $0["name"] == .string("launch_app") }?["inputSchema"]
            let launchProperties = launchSchema?["properties"]?.object?.keys.sorted() ?? []
            print("Installed launch_app contract:", launchProperties, "session:", launchProperties.contains("session"),
                  "additionalProperties:", launchSchema?["additionalProperties"]?.bool ?? true)
            let inventory = try await connection.call("get_accessibility_tree", arguments: ["session": .string(session)])
            let pid = try XCTUnwrap(inventory["apps"]?.array?.first { $0["bundle_id"] == .string("com.apple.TextEdit") }?["pid"]?.integer)
            let listed = try await connection.call("list_windows", arguments: ["pid": .number(Double(pid)), "session": .string(session)])
            let matches = (listed["windows"]?.array ?? []).filter { $0["title"]?.string?.contains(titleFragment) == true }
            print("Read-only setup target windows:", matches.map { "\($0["title"]?.string ?? "<missing>") id=\($0["window_id"]?.integer ?? -1)" })
            XCTAssertLessThanOrEqual(matches.count, 1, "A disposable setup URL must not match multiple TextEdit windows")
            if let windowID = matches.first?["window_id"]?.integer {
                let state = try await connection.call("get_window_state", arguments: [
                    "pid": .number(Double(pid)), "window_id": .number(Double(windowID)),
                    "include_screenshot": .bool(false), "session": .string(session)
                ])
                let fields = (state["elements"]?.array ?? []).filter {
                    ["AXTextArea", "AXTextField"].contains($0["role"]?.string ?? "")
                }
                let lengths = fields.map { $0["value"]?.string?.count ?? -1 }
                print("Read-only setup target editable fields:", fields.count, "value lengths:", lengths)
                if environment["JARVIS_CUA_SETUP_CLOSE_WINDOW"] == "1" {
                    let fieldsAreBlank = !fields.isEmpty && fields.allSatisfy {
                        $0["value"] == nil || $0["value"] == .string("")
                    }
                    guard matches.count == 1, fieldsAreBlank else {
                        throw DriverConnectionError.refused("The exact setup target is not a single blank disposable document; it will not be closed.")
                    }
                    _ = try await connection.call("invoke_menu", arguments: [
                        "pid": .number(Double(pid)), "window_id": .number(Double(windowID)),
                        "path": .array([.string("File"), .string("Close")]), "session": .string(session)
                    ])
                    var remaining = [JSONValue.object(["title": .string(titleFragment)])]
                    for _ in 0..<20 where !remaining.isEmpty {
                        let fresh = try await connection.call("list_windows", arguments: ["pid": .number(Double(pid)), "session": .string(session)])
                        remaining = (fresh["windows"]?.array ?? []).filter { $0["title"]?.string?.contains(titleFragment) == true }
                        if !remaining.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
                    }
                    XCTAssertTrue(remaining.isEmpty, "Only the exact disposable setup target should have closed")
                }
            }
            _ = try await connection.call("end_session", arguments: ["session": .string(session)])
        } catch {
            _ = try? await connection.call("end_session", arguments: ["session": .string(session)])
            await connection.close()
            throw error
        }
        await connection.close()
    }
}
