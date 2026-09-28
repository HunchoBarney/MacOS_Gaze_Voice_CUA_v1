import XCTest
import JevVoiceCore
@testable import JevVoice

/// Run only with explicit desktop authorization and scripts/with-desktop-lock.py.
/// This Driver contract probe is not a live Jev or packaged-app acceptance test.
@MainActor
final class CuaReplacementContractLiveTests: XCTestCase {
    func testNativeVerificationPreservesTokenAndRefreshRetiresItOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_CUA_REPLACEMENT_TEST"] == "1" else {
            throw XCTSkip("Opt-in disposable TextEdit replacement contract proof")
        }
        let connection = try CuaLiveDriver.connection()
        try await connection.connect()
        let label = "Jarvis replacement proof \(UUID().uuidString.prefix(8))"
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("development/JevVoice/verification/execution-simplification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("replacement-\(UUID()).txt")
        // The pinned Driver omits empty AX values. Prove the supported nonempty
        // contract here; blank-value verification remains a recorded gap.
        let seed = "Disposable replacement seed"
        try seed.write(to: file, atomically: true, encoding: .utf8)
        // Leave the disposable document for inspection; never close unrelated documents.
        let call: CuaTaskAgent.Call = { tool, args in
            let result = try await connection.call(tool, arguments: args.merging(["session": .string(label)]) { _, b in b })
            if tool == "verify_state" { print("Disposable verification result:", result) }
            return result
        }
        do {
            _ = try await call("start_session", [:])
            let tools = try await connection.tools()
            guard tools.contains(where: { $0["name"] == .string("verify_state") }) else {
                throw DriverConnectionError.refused("The pinned verification tool is unavailable; no fixture was launched.")
            }
            let launched = try await call("launch_app", ["bundle_id": .string("com.apple.TextEdit"), "urls": .array([.string(file.path)])])
            let pid = try XCTUnwrap(launched["pid"]?.integer)
            var matching: [JSONValue] = []
            for _ in 0..<30 {
                let listed = try await call("list_windows", ["pid": .number(Double(pid))])
                matching = (listed["windows"]?.array ?? []).filter { $0["title"]?.string?.contains(file.lastPathComponent) == true }
                if !matching.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard matching.count == 1 else {
                throw DriverConnectionError.refused("The disposable fixture window is ambiguous; nothing was inserted.")
            }
            let window = try XCTUnwrap(matching.first?["window_id"]?.integer)
            let snapshotArgs: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window)), "include_screenshot": .bool(false)]
            let before = try await call("get_window_state", snapshotArgs)
            let fields = (before["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
            guard fields.count == 1 else {
                throw DriverConnectionError.refused("The disposable text field is ambiguous; nothing was inserted.")
            }
            let token = try XCTUnwrap(fields.first?["element_token"]?.string)
            print("Disposable text field value length:", fields.first?["value"]?.string?.count ?? -1,
                  "degraded:", before["degraded"] ?? .null, "complete:", before["elements_complete"] ?? .null)
            let initial = try await CuaStateVerification.elementValue(pid: pid, window: window, role: "AXTextArea", value: seed, call: call)
            guard initial == .satisfied else {
                throw DriverConnectionError.refused("The fixture seed was not verified; nothing was changed.")
            }
            let text = "Replacement contract copper lantern"
            var insertion: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window)),
                "element_token": .string(token), "value": .string(text)]
            _ = try await call("set_value", insertion)
            let inserted = try await CuaStateVerification.elementValue(pid: pid, window: window, role: "AXTextArea", value: text, call: call)
            guard inserted == .satisfied else {
                throw DriverConnectionError.refused("The first insertion was not verified; no further mutation probe will run.")
            }
            _ = try await call("get_window_state", snapshotArgs)
            insertion["value"] = .string("A retired token must never write this value")
            do {
                _ = try await call("set_value", insertion)
                XCTFail("A retired token authorized another insertion")
            } catch let error as DriverConnectionError {
                XCTAssertEqual(error, .toolRefused(tool: "set_value", code: "stale_element_token"))
            }
            let after = try await call("get_window_state", snapshotArgs)
            let bodies = (after["elements"]?.array ?? []).filter { $0["role"] == .string("AXTextArea") }
            XCTAssertEqual(bodies.count, 1)
            XCTAssertEqual(bodies.first?["value"], .string(text), "No duplicate mutation is permitted")
            _ = try await call("end_session", [:])
            await connection.close()
        } catch {
            _ = try? await call("end_session", [:])
            await connection.close()
            throw error
        }
    }
}
