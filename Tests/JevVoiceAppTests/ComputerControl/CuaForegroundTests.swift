import XCTest
import JevVoiceCore
@testable import JevVoice

/// The fast lane's open-verb contract: the exact target window must be
/// verified in front before "opened" is reported — no unverified raises.
/// ("Open X in the background" is no longer modeled: TaskSpec carries no
/// visibility field — input delivery is background-mode, but app-open
/// visibility is planner territory, not a fast-lane concept.)
@MainActor
final class CuaForegroundTests: XCTestCase {
    private func run(goal: String = "show Fixture", verified: Bool = true,
                     hidden: Bool = false) async throws -> [String] {
        var calls: [String] = []
        var exposed = !hidden
        let agent = CuaTaskAgent(call: { tool, args in
            calls.append(tool)
            switch tool {
            case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "running": .bool(true), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7), "title": .string("Fixture"), "is_on_screen": .bool(exposed)])])])
            case "get_window_state": return .object(["elements": .array([])])
            case "bring_to_front":
                exposed = verified
                XCTAssertEqual(args["window_id"], .number(7))
                return .object(["activated": .bool(verified), "exact_window_effect": .object(["verified": .bool(verified)])])
            default: XCTFail("Unexpected action: \(tool)"); throw DriverConnectionError.malformed
            }
        })
        let resolved = try XCTUnwrap(agent.resolveFastLane(goal: goal, apps: [
            .object(["name": .string("Fixture"), "bundle_id": .string("fixture"),
                     "running": .bool(true), "pid": .number(42)])
        ]))
        _ = try await agent.runFastLane(resolved, goal: goal) { _ in }
        return calls
    }

    func testExplicitOpeningBringsExistingWindowForward() async throws {
        let calls = try await run()
        XCTAssertEqual(calls.filter { $0 == "bring_to_front" }.count, 1)
        XCTAssertFalse(calls.contains("launch_app"))
    }
    func testShowingCurrentAppStillVerifiesForegroundWindow() async throws {
        let calls = try await run(goal: "switch to Fixture")
        XCTAssertEqual(calls.filter { $0 == "bring_to_front" }.count, 1)
    }
    func testUnverifiedActivationCannotReportSuccess() async throws {
        do { _ = try await run(verified: false); XCTFail("Accepted unverified foreground effect") }
        catch { XCTAssertTrue(error is DriverConnectionError) }
    }
    func testHiddenAppStillRequiresExactWindowVerification() async throws {
        let calls = try await run(hidden: true)
        XCTAssertEqual(calls.filter { $0 == "bring_to_front" }.count, 1)
    }
}
