import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaLaunchReceiptTests: XCTestCase {
    private var elements: [JSONValue] { [
        .object(["element_index": .number(1), "role": .string("AXMenuBarItem"), "label": .string("Fixture")]),
        .object(["element_index": .number(2), "parent_index": .number(1), "role": .string("AXMenu")]),
        .object(["element_index": .number(3), "parent_index": .number(2), "role": .string("AXMenuItem"), "label": .string("Quit Fixture"), "element_token": .string("fixture-menu"), "actions": .array([.string("AXPress")])])
    ] }
    func testNormalQuitReobservesAndNeverForceQuitsOrDiscards() async throws {
        for changed in [false, true] {
            var running = true, mutations = 0, reads = 0
            let receipt = CuaLaunchReceipt(bundle: "fixture", pid: 42, window: 7, windows: [7], content: CuaLaunchReceipt.identity(elements))
            do {
                let result = try await receipt.reverse(call: { tool, args in
                    switch tool {
                    case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["bundle_id": .string("fixture"), "pid": .number(42), "running": .bool(running)])])])
                    case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
                    case "get_window_state":
                        reads += 1
                        return .object(["elements": .array(self.elements + (changed && reads > 1 ? [.object(["role": .string("AXTextArea"), "value": .string("User edit")])] : []))])
                    case "invoke_menu":
                        XCTAssertEqual(args["path"], .array([.string("Fixture"), .string("Quit Fixture")]))
                        mutations += 1; running = false; return .object([:])
                    default: XCTFail("Unexpected reversal tool \(tool)"); throw DriverConnectionError.malformed
                    }
                }, judge: { _, _ in ["quit": .choice(choice: "0", confidence: 1, probabilities: [:])] }, approveFocus: { true })
                XCTAssertFalse(changed)
                XCTAssertTrue(result.contains("Closed"))
                XCTAssertEqual(mutations, 1)
                XCTAssertEqual(reads, 2)
            } catch {
                XCTAssertTrue(changed)
                XCTAssertEqual(mutations, 0)
                XCTAssertTrue(error.localizedDescription.contains("changed"))
            }
        }
    }
    func testRestartedProcessIsNotClosed() async throws {
        let receipt = CuaLaunchReceipt(bundle: "fixture", pid: 42, window: 7, windows: [7], content: [])
        do {
            _ = try await receipt.reverse(call: { tool, _ in
                XCTAssertTrue(["list_apps", "get_accessibility_tree"].contains(tool))
                return .object(["apps": .array([.object(["bundle_id": .string("fixture"), "pid": .number(99), "running": .bool(true)])])])
            }, judge: { _, _ in XCTFail("Must reject before deciding"); return [:] })
            XCTFail("Closed a different process")
        } catch { XCTAssertTrue(error.localizedDescription.contains("restarted")) }
    }
    func testNewWindowDuringApprovalPreventsApplicationQuit() async throws {
        var approved = false, mutations = 0
        let receipt = CuaLaunchReceipt(bundle: "fixture", pid: 42, window: 7, windows: [7], content: CuaLaunchReceipt.identity(elements))
        do {
            _ = try await receipt.reverse(call: { tool, _ in
                switch tool {
                case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["bundle_id": .string("fixture"), "pid": .number(42), "running": .bool(true)])])])
                case "list_windows": return .object(["windows": .array((approved ? [7, 8] : [7]).map { .object(["window_id": .number(Double($0))]) })])
                case "get_window_state": return .object(["elements": .array(self.elements)])
                default: mutations += 1; throw DriverConnectionError.malformed
                }
            }, judge: { _, _ in ["quit": .choice(choice: "0", confidence: 1, probabilities: [:])] }, approveFocus: { approved = true; return true })
            XCTFail("Quit after a new user window appeared")
        } catch { XCTAssertTrue(error.localizedDescription.contains("windows changed")) }
        XCTAssertEqual(mutations, 0)
    }

}
