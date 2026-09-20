import XCTest
import JevVoiceCore
@testable import JevVoice

final class CuaCustomActionLiveTests: XCTestCase {
    func testNestedMenuListingAndFinalCommandOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_MENU_TEST"] == "1" else {
            throw XCTSkip("Requires source Driver and disposable PerceptionTarget.app")
        }
        let connection = CuaConnection(executable: URL(fileURLWithPath: "/Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local"))
        try await connection.connect()
        let label = "Jarvis menu fixture \(UUID().uuidString.prefix(8))"
        func call(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            try await connection.call(tool, arguments: args.merging(["session": .string(label)]) { _, b in b })
        }
        do {
            _ = try await call("start_session", [:])
            let launch = try await call("launch_app", ["bundle_id": .string("dev.jarvis.perception-fixture")])
            let pid = try XCTUnwrap(launch["pid"]?.integer)
            let listed = try await call("list_windows", ["pid": .number(Double(pid))])
            let windows = listed["windows"]?.array?.filter { $0["title"]?.string?.hasPrefix("Jarvis Visual Fixture — ") == true } ?? []
            XCTAssertEqual(windows.count, 1)
            let window = try XCTUnwrap(windows.first?["window_id"]?.integer)
            let before = try XCTUnwrap(windows.first?["title"])
            XCTAssertNotEqual(before, .string("Jarvis Visual Fixture — Menu Reviewed"))
            let target: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window))]
            let listing = try await call("invoke_menu", target.merging(["path": .array([.string("Fixture"), .string("Review")])]) { _, b in b })
            XCTAssertEqual(listing["status"], .string("listed"))
            let observed = try await call("list_windows", ["pid": .number(Double(pid))])
            XCTAssertEqual(observed["windows"]?.array?.first { $0["window_id"]?.integer == window }?["title"], before, "Listing must not execute a final command")
            let actions = CuaActionCatalog.submenu(listing, pid: pid, window: window)
            let matches = actions.filter { $0.description == "Menu Fixture → Review → Mark via Menu" }
            XCTAssertEqual(matches.count, 1)
            let action = try XCTUnwrap(matches.first)
            _ = try await call(action.tool, action.arguments)
            var title: JSONValue?
            for _ in 0..<20 {
                let after = try await call("list_windows", ["pid": .number(Double(pid))])
                title = after["windows"]?.array?.first { $0["window_id"]?.integer == window }?["title"]
                if title == .string("Jarvis Visual Fixture — Menu Reviewed") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(title, .string("Jarvis Visual Fixture — Menu Reviewed"))
        } catch {
            _ = try? await call("end_session", [:])
            await connection.close()
            throw error
        }
        _ = try? await call("end_session", [:])
        await connection.close()
    }

    func testCustomActionUsesAdvertisedEnvelopeInsteadOfOrdinaryPressOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_CUSTOM_ACTION_TEST"] == "1" else {
            throw XCTSkip("Requires source Driver and disposable PerceptionTarget.app")
        }
        let connection = CuaConnection(executable: URL(fileURLWithPath: "/Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local"))
        try await connection.connect()
        let label = "Jarvis custom action \(UUID().uuidString.prefix(8))"
        func call(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
            try await connection.call(tool, arguments: args.merging(["session": .string(label)]) { _, b in b })
        }
        do {
            _ = try await call("start_session", [:])
            let launch = try await call("launch_app", ["bundle_id": .string("dev.jarvis.perception-fixture")])
            let pid = try XCTUnwrap(launch["pid"]?.integer)
            var windows: [JSONValue] = []
            for _ in 0..<30 {
                windows = (try await call("list_windows", ["pid": .number(Double(pid))]))["windows"]?.array?.filter {
                    $0["title"]?.string?.hasPrefix("Jarvis Visual Fixture — ") == true
                } ?? []
                if !windows.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(windows.count, 1)
            let window = try XCTUnwrap(windows.first?["window_id"]?.integer)
            XCTAssertNotEqual(windows.first?["title"], .string("Jarvis Visual Fixture — Custom Reviewed"), "Fresh effect must be observable")
            let target: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window))]
            let observation = try await call("get_window_state", target.merging(["include_screenshot": .bool(false)]) { _, b in b })
            let fixtureEvidence = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("JevVoice/verification/custom-action-observation.json")
            let fixtureControls = observation["elements"]?.array?.filter { $0["label"] == .string("Fixture review") } ?? []
            try JSONEncoder().encode(fixtureControls).write(to: fixtureEvidence, options: .atomic)
            let actions = CuaActionCatalog.native(elements: observation["elements"]?.array ?? [], pid: pid, window: window)
            let custom = actions.filter { $0.description.hasPrefix("Mark reviewed on ") }
            XCTAssertEqual(custom.count, 1, "Driver must expose the real custom action, not just AXPress")
            let action = try XCTUnwrap(custom.first)
            _ = try await call(action.tool, action.arguments)
            let after = try await call("list_windows", ["pid": .number(Double(pid))])
            XCTAssertTrue(after["windows"]?.array?.contains {
                $0["window_id"]?.integer == window && $0["title"] == .string("Jarvis Visual Fixture — Custom Reviewed")
            } == true, "Ordinary Press changes a different title and must not satisfy this check")
        } catch {
            _ = try? await call("end_session", [:])
            await connection.close()
            throw error
        }
        _ = try? await call("end_session", [:])
        await connection.close()
    }
}
