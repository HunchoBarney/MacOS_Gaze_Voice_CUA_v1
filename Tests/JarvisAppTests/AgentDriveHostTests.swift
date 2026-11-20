import Foundation
import Synchronization
import XCTest
import JarvisCore
@testable import Jarvis

/// The agent → app handoff over a real Unix socket in a private temp
/// directory. No daemon, model or desktop is involved.
final class AgentDriveHostTests: XCTestCase {
    private final class Calls: Sendable {
        let seen = Mutex<[(String, String, JSONValue)]>([])
        let cancelled = Mutex(false)
    }

    private func text(_ result: JSONValue) -> String {
        result["content"]?.array?.first?["text"]?.string ?? ""
    }

    func testTokenedRequestReachesTheHandlerAndItsResultComesBack() async throws {
        let calls = Calls()
        let host = try XCTUnwrap(AgentDriveHost { agent, tool, arguments in
            calls.seen.withLock { $0.append((agent, tool, arguments)) }
            return AgentDriveHost.toolText("Done.")
        })
        defer { host.stop() }
        let reply = try await AgentDriveHost.forward(socket: host.socketPath, request: .object([
            "agent": .string("scout"), "token": .string(host.token(for: "scout")),
            "tool": .string("drive_until"), "arguments": .object(["goal": .string("Save")])]))
        XCTAssertEqual(text(reply), "Done.")
        XCTAssertNil(reply["isError"])
        let seen = calls.seen.withLock { $0 }
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, "scout")
        XCTAssertEqual(seen.first?.1, "drive_until")
        XCTAssertEqual(seen.first?.2["goal"]?.string, "Save")
    }

    func testAWrongOrBorrowedTokenNeverRuns() async throws {
        let calls = Calls()
        let host = try XCTUnwrap(AgentDriveHost { agent, tool, arguments in
            calls.seen.withLock { $0.append((agent, tool, arguments)) }
            return AgentDriveHost.toolText("Done.")
        })
        defer { host.stop() }
        let other = host.token(for: "helper")
        for (agent, token) in [("scout", "0000"), ("scout", other), ("stranger", other), ("helper", "")] {
            let reply = try await AgentDriveHost.forward(socket: host.socketPath, request: .object([
                "agent": .string(agent), "token": .string(token),
                "tool": .string("drive_until"), "arguments": .object(["goal": .string("Save")])]))
            XCTAssertEqual(reply["isError"]?.bool, true, agent)
            XCTAssertTrue(text(reply).contains("doesn't recognize this agent"), text(reply))
        }
        XCTAssertTrue(calls.seen.withLock { $0.isEmpty })
    }

    func testTokensAreStablePerAgentAndDistinctAcrossAgents() throws {
        let host = try XCTUnwrap(AgentDriveHost { _, _, _ in .object([:]) })
        defer { host.stop() }
        let scout = host.token(for: "scout")
        XCTAssertEqual(scout, host.token(for: "scout"))
        XCTAssertNotEqual(scout, host.token(for: "helper"))
        XCTAssertEqual(scout.count, 64)
        XCTAssertTrue(host.authorized(agent: "scout", token: scout))
        XCTAssertFalse(host.authorized(agent: "helper", token: scout))
    }

    func testTheSocketDirectoryIsPrivate() throws {
        let host = try XCTUnwrap(AgentDriveHost { _, _, _ in .object([:]) })
        defer { host.stop() }
        let directory = (host.socketPath as NSString).deletingLastPathComponent
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o700)
    }

    func testHangingUpCancelsTheRunInTheApp() async throws {
        let calls = Calls()
        let started = expectation(description: "run started")
        let host = try XCTUnwrap(AgentDriveHost { _, _, _ in
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                calls.cancelled.withLock { $0 = true }
            }
            return AgentDriveHost.toolText("late")
        })
        defer { host.stop() }
        let token = host.token(for: "scout")
        let child = Task {
            try await AgentDriveHost.forward(socket: host.socketPath, request: .object([
                "agent": .string("scout"), "token": .string(token),
                "tool": .string("drive_until"), "arguments": .object(["goal": .string("Save")])]))
        }
        await fulfillment(of: [started], timeout: 5)
        child.cancel()
        _ = try? await child.value
        for _ in 0..<100 where !calls.cancelled.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(calls.cancelled.withLock { $0 })
    }

    func testAMissingHostIsUnavailable() async {
        do {
            _ = try await AgentDriveHost.forward(socket: "/nonexistent-\(UUID().uuidString.prefix(8))/agents.sock",
                                                 request: .object([:]))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? DriverConnectionError, .unavailable)
        }
    }

    func testDrivesRefuseBadCallsBeforeTouchingTheDaemon() async {
        let touched = Mutex(false)
        let drives = CuaDriveServer.Drives(
            chooser: { { _, _ in nil } }, granted: { false },
            socket: { touched.withLock { $0 = true }; throw DriverConnectionError.unavailable })
        let unknown = await drives.run(agent: "scout", tool: "rm_rf", arguments: .object(["goal": .string("x")]))
        XCTAssertEqual(unknown["isError"]?.bool, true)
        let invalid = await drives.run(agent: "scout", tool: "drive_until", arguments: .object(["window_id": .number(1)]))
        XCTAssertEqual(invalid["isError"]?.bool, true)
        XCTAssertFalse(touched.withLock { $0 })
        let unavailable = await drives.run(agent: "scout", tool: "drive_until", arguments: .object(["goal": .string("Save")]))
        XCTAssertEqual(unavailable["isError"]?.bool, true)
        XCTAssertTrue(touched.withLock { $0 })
    }
}
