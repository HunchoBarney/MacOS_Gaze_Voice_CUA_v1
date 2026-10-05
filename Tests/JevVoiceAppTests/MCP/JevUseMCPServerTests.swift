import XCTest
import JevVoiceCore
@testable import JevVoice

final class JevUseMCPServerTests: XCTestCase {
    func testToolsExposeClickySchemas() {
        let tools = JevUseMCPServer.tools()
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, [JevUseTools.driveUntil, JevUseTools.suggestAction])
        let drive = tools[0]
        XCTAssertEqual(drive["inputSchema"]?["required"]?.array?.first, .string("goal"))
        let properties = drive["inputSchema"]?["properties"]?.object?.keys.sorted() ?? []
        for key in ["goal", "application", "pid", "window_id", "values", "deny", "success_contains", "max_steps"] {
            XCTAssertTrue(properties.contains(key), key)
        }
        let suggest = tools[1]
        XCTAssertEqual(suggest["inputSchema"]?["required"]?.array?.compactMap(\.string), ["pid", "window_id"])
    }

    func testDriveUntilMapsArgumentsAndReturnsResultJSON() async throws {
        let executor = RecordingDriveExecutor()
        let server = JevUseMCPServer(executor: executor)
        let result = try await server.callTool(JevUseTools.driveUntil, arguments: .object([
            "goal": .string("send the reply"),
            "application": .string("com.apple.mail"),
            "pid": .number(42),
            "window_id": .number(9),
            "values": .object(["Subject": .string("hello"), "ignored": .number(3)]),
            "deny": .array([.string("Delete")]),
            "success_contains": .array([.string("Sent")]),
            "max_steps": .number(5)
        ]))
        let tasks = await executor.tasks
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.goal, "send the reply")
        XCTAssertEqual(task.application, "com.apple.mail")
        XCTAssertEqual(task.pid, 42)
        XCTAssertEqual(task.windowID, 9)
        XCTAssertEqual(task.values, ["Subject": "hello"])
        XCTAssertEqual(task.deny, ["Delete"])
        XCTAssertEqual(task.successContains, ["Sent"])
        XCTAssertEqual(task.maxSteps, 5)

        XCTAssertNil(result["isError"])
        XCTAssertEqual(result["structuredContent"]?["status"], .string("done"))
        XCTAssertEqual(result["structuredContent"]?["history"]?.array?.first, .string("pressed Save"))
        XCTAssertEqual(result["structuredContent"]?["pid"], .number(42))
        XCTAssertEqual(result["structuredContent"]?["window_id"], .number(9))
        XCTAssertEqual(result["content"]?.array?.first?["type"], .string("text"))
    }

    func testDriveUntilStatusMapping() async throws {
        let executor = RecordingDriveExecutor()
        let server = JevUseMCPServer(executor: executor)
        await executor.setNext(DriveResult(status: .needsText(fieldLabel: "Subject")))
        var result = try await server.callTool(JevUseTools.driveUntil,
            arguments: .object(["goal": .string("fill the form")]))
        XCTAssertEqual(result["structuredContent"]?["status"], .string("needs_text"))
        XCTAssertEqual(result["structuredContent"]?["reason"], .string("Subject"))
        await executor.setNext(DriveResult(status: .handedBack(.lowConfidence)))
        result = try await server.callTool(JevUseTools.driveUntil,
            arguments: .object(["goal": .string("fill the form")]))
        XCTAssertEqual(result["structuredContent"]?["status"], .string("handed_back"))
        XCTAssertEqual(result["structuredContent"]?["reason"], .string("low_confidence"))
    }

    func testSuggestActionReturnsJudgmentJSON() async throws {
        let server = JevUseMCPServer(executor: RecordingDriveExecutor(), suggester: StubSuggester())
        let result = try await server.callTool(JevUseTools.suggestAction,
            arguments: .object(["pid": .number(1), "window_id": .number(2)]))
        XCTAssertNil(result["isError"])
        XCTAssertEqual(result["structuredContent"]?["element_token"], .string("el-3"))
        XCTAssertEqual(result["structuredContent"]?["kind"], .string("press"))
        XCTAssertEqual(result["structuredContent"]?["confidence"], .number(0.9))
        XCTAssertEqual(result["structuredContent"]?["done"], .bool(false))
    }

    func testInvalidArgumentsAndUnknownToolAreToolErrors() async throws {
        let server = JevUseMCPServer(executor: RecordingDriveExecutor())
        let missingGoal = try await server.callTool(JevUseTools.driveUntil, arguments: .object([:]))
        XCTAssertEqual(missingGoal["isError"], .bool(true))
        XCTAssertEqual(missingGoal["structuredContent"]?["code"], .string("invalid_arguments"))
        let missingPid = try await server.callTool(JevUseTools.suggestAction, arguments: .object(["pid": .number(1)]))
        XCTAssertEqual(missingPid["structuredContent"]?["code"], .string("invalid_arguments"))
        let unknown = try await server.callTool("screenshot", arguments: .object([:]))
        XCTAssertEqual(unknown["structuredContent"]?["code"], .string("unknown_tool"))
    }

    func testLoopbackRoundTripExposesAndDrives() async throws {
        let executor = RecordingDriveExecutor()
        let mcp = JevUseMCPServer(executor: executor, suggester: StubSuggester())
        let server = mcp.server()
        let endpoint = try await server.start()

        let (_, initResponse) = try await mcpPost(endpoint, mcpRequest(1, "initialize", .object([
            "protocolVersion": .string("2025-03-26"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("codex"), "version": .string("1")])
        ])))
        XCTAssertEqual(initResponse?["result"]?["serverInfo"]?["name"], .string("jev-use"))

        let (_, toolsResponse) = try await mcpPost(endpoint, mcpRequest(2, "tools/list"))
        let names = toolsResponse?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
        XCTAssertEqual(names, [JevUseTools.driveUntil, JevUseTools.suggestAction])

        let (_, callResponse) = try await mcpPost(endpoint, mcpRequest(3, "tools/call", .object([
            "name": .string(JevUseTools.driveUntil),
            "arguments": .object(["goal": .string("send the reply"), "window_id": .number(9)])
        ])))
        XCTAssertEqual(callResponse?["result"]?["structuredContent"]?["status"], .string("done"))
        let tasks = await executor.tasks
        XCTAssertEqual(tasks.first?.goal, "send the reply")
        XCTAssertEqual(tasks.first?.maxSteps, 24)
        await server.stop()
    }

    /// An unwired server must not advertise suggest_action — a listed tool
    /// that always answers "unavailable" burns agent turns on a dead door.
    func testUnwiredSuggesterHidesSuggestTool() async throws {
        let server = JevUseMCPServer(executor: RecordingDriveExecutor()).server()
        let endpoint = try await server.start()
        let (_, response) = try await mcpPost(endpoint, mcpRequest(1, "tools/list"))
        let names = response?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
        XCTAssertEqual(names, [JevUseTools.driveUntil])
        await server.stop()
    }
}
