import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaForegroundTests: XCTestCase {
    private func run(visibility: String, verified: Bool = true, hidden: Bool = false) async throws -> [String] {
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
        }, judge: { _, questions in
            Dictionary(uniqueKeysWithValues: questions.keys.map { key in
                let answer = key == "app" ? "app_0" : key == "visibility" ? visibility : key == "scope" ? "launch" : "done"
                return (key, .choice(choice: answer, confidence: 1, probabilities: [:]))
            })
        }, approve: { _ in XCTFail("Explicit opening must not ask again"); return false })
        _ = try await agent.run(goal: visibility == "background" ? "start Fixture in the background" : "show Fixture", context: "", progress: { _ in })
        return calls
    }

    func testExplicitOpeningBringsExistingWindowForward() async throws {
        let calls = try await run(visibility: "foreground")
        XCTAssertEqual(calls.filter { $0 == "bring_to_front" }.count, 1)
        XCTAssertFalse(calls.contains("launch_app"))
    }
    func testBackgroundLaunchDoesNotTakeFocus() async throws {
        let calls = try await run(visibility: "background")
        XCTAssertFalse(calls.contains("bring_to_front"))
    }
    func testShowingCurrentAppStillVerifiesForegroundWindow() async throws {
        let calls = try await run(visibility: "current")
        XCTAssertEqual(calls.filter { $0 == "bring_to_front" }.count, 1)
    }
    func testUnverifiedActivationCannotReportSuccess() async throws {
        do { _ = try await run(visibility: "foreground", verified: false); XCTFail("Accepted unverified foreground effect") }
        catch { XCTAssertTrue(error is DriverConnectionError) }
    }
    func testHiddenAppStillRequiresExactWindowVerification() async throws {
        let calls = try await run(visibility: "foreground", hidden: true)
        XCTAssertEqual(calls.filter { $0 == "bring_to_front" }.count, 1)
    }
}
