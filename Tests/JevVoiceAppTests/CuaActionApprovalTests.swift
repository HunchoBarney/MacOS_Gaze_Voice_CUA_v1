import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaActionApprovalTests: XCTestCase {
    func testConfirmationIsExactSingleUseAndChangedContentStopsDispatch() async throws {
        for mode in ["approve", "decline", "changed"] {
            var approvals = 0, mutations = 0, changed = false
            let agent = CuaTaskAgent(call: { tool, _ in
                switch tool {
                case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42), "running": .bool(true)])])])
                case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7), "title": .string("Disposable test item")])])])
                case "get_browser_state": throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable")
            case "get_window_state": return .object(["elements": .array([
                    .object(["element_index": .number(0), "role": .string("AXMenuBarItem"), "label": .string("File")]),
                    .object(["element_index": .number(1), "parent_index": .number(0), "role": .string("AXMenuItem"), "label": .string("Move to Trash"), "element_token": .string("fixture-menu"), "actions": .array([.string("AXPress")])]),
                    .object(["role": .string("AXTextArea"), "value": .string(changed ? "User change" : "Fixture content")])
                ])])
                case "invoke_menu": mutations += 1; return .object([:])
                default: XCTFail("Unexpected fixture tool \(tool)"); throw DriverConnectionError.malformed
                }
            }, judge: { _, questions in
                var answers: [String: Answer] = [:]
                for key in questions.keys {
                    let value: String
                    switch key {
                    case "app": value = "app_0"
                    case "visibility": value = "background"
                case "scope": value = "work"
                    case "next":
                        if mutations == 0 {
                            guard case let .choice(_, criteria) = questions[key] else { throw DriverConnectionError.malformed }
                            value = try XCTUnwrap(criteria.first { $0.value == "Menu File → Move to Trash" }?.key)
                        } else { value = "done" }
                    case "risk": value = "confirmation"
                    case "windowEffect": value = "same"
                    default: throw DriverConnectionError.malformed
                    }
                    answers[key] = .choice(choice: value, confidence: 1, probabilities: [:])
                }
                return answers
            }, approve: { operation in
                approvals += 1
                XCTAssertEqual(operation, "Fixture — Disposable test item\nMenu File → Move to Trash\nThis menu temporarily focuses the target window.")
                changed = mode == "changed"
                return mode != "decline"
            })
            do {
                _ = try await agent.run(goal: "Delete the disposable test item", context: "", progress: { _ in })
                XCTAssertEqual(mode, "approve")
            } catch {
                XCTAssertNotEqual(mode, "approve")
                if mode == "decline" { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error.localizedDescription.contains("target changed")) }
            }
            XCTAssertEqual(approvals, 1)
            XCTAssertEqual(mutations, mode == "approve" ? 1 : 0)
        }
    }
}
