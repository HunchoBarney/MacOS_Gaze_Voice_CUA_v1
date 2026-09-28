import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaGenerationTests: XCTestCase {
    private func answer(_ value: String) -> Answer { .choice(choice: value, confidence: 1, probabilities: [value: 1]) }
    private func app() -> JSONValue { .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42), "running": .bool(true)])])]) }
    private func snapshot(_ text: String) -> JSONValue { .object(["elements": .array([.object(["role": .string("AXStaticText"), "label": .string(text)])])]) }
    func testRejectedDraftIsBoundedAndNeverInserted() async throws {
        var generated = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree": return self.app()
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(1)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable")
            case "get_window_state": return self.snapshot("Disposable source")
            default: XCTFail("Rejected draft dispatched a mutation"); throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            if questions["draftQuality"] != nil { XCTAssertEqual(state["whitespace_word_count"], .number(2)) }
            return Dictionary(uniqueKeysWithValues: questions.keys.map { key in
                (key, self.answer(key == "draftQuality" ? "revise" : key == "visibility" ? "background" : key == "app" ? "app_0" : key == "scope" ? "work" : key == "source" ? "none" : "draft"))
            })
        }, generate: { prompt, _, _ in
            XCTAssertTrue(prompt.contains("Generate only the draft text"))
            generated += 1; return "Wrong length"
        })
        do { _ = try await agent.run(goal: "Draft a five-word greeting", context: "", progress: { _ in }); XCTFail("Accepted rejected text") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not satisfy")) }
        XCTAssertEqual(generated, 2)
    }
    func testSummaryUsesSelectedContextAndNeverMutates() async throws {
        var generated = false
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree": return self.app()
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(1)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable")
            case "get_window_state": return self.snapshot("The copper lantern is beside the window.")
            default: XCTFail("Summary dispatched mutation: \(tool)"); throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            Dictionary(uniqueKeysWithValues: questions.keys.map { key in
                (key, self.answer(key == "draftQuality" ? "acceptable" : key == "visibility" ? "background" : key == "app" ? "app_0" : key == "scope" ? "work" : key == "source" ? "0" : "summary"))
            })
        }, generate: { prompt, context, reasoning in
            XCTAssertEqual(prompt, "Summarize this page")
            XCTAssertEqual(context, "The copper lantern is beside the window.")
            XCTAssertFalse(reasoning); generated = true
            return "A lantern stands by the window."
        })
        let result = try await agent.run(goal: "Summarize this page", context: "", progress: { _ in })
        XCTAssertTrue(generated)
        XCTAssertEqual(result, "A lantern stands by the window.")
    }
    func testChangedSourceRejectsLateGenerationWithoutInsertion() async throws {
        var generated = false
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree": return self.app()
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(1)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable")
            case "get_window_state": return self.snapshot(generated ? "Different recipient" : "Original recipient")
            default: XCTFail("Stale generation mutated an app"); throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            Dictionary(uniqueKeysWithValues: questions.keys.map { key in
                (key, self.answer(key == "draftQuality" ? "acceptable" : key == "visibility" ? "background" : key == "app" ? "app_0" : key == "scope" ? "work" : key == "source" ? "0" : "draft"))
            })
        }, generate: { _, _, _ in generated = true; return "Generated draft" })
        do { _ = try await agent.run(goal: "Draft a reply", context: "", progress: { _ in }); XCTFail("Accepted stale source") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed while generating")) }
    }
    func testCancelledProviderOutputCannotBecomeAnAction() async throws {
        var entered = false
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree": return self.app()
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(1)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable")
            case "get_window_state": return self.snapshot("Disposable source")
            default: XCTFail("Cancelled output dispatched a mutation"); throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            Dictionary(uniqueKeysWithValues: questions.keys.map { key in
                (key, self.answer(key == "draftQuality" ? "acceptable" : key == "visibility" ? "background" : key == "app" ? "app_0" : key == "scope" ? "work" : key == "source" ? "0" : "draft"))
            })
        }, generate: { _, _, _ in entered = true; try? await Task.sleep(for: .seconds(1)); return "Late draft" })
        let task = Task { try await agent.run(goal: "Draft a reply", context: "", progress: { _ in }) }
        for _ in 0..<100 where !entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(entered); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled provider was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testUnrelatedNewWindowCannotStealGeneratedDraftDestination() async throws {
        var generated = false, inserted = false, insertionWindow: Int?
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree": return self.app()
            case "list_windows": return .object(["windows": .array((generated ? [1, 2] : [1]).map { .object(["window_id": .number(Double($0))]) })])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable")
            case "get_window_state": return .object(["elements": .array([.object(["role": .string("AXTextArea"), "label": .string("Body"), "element_token": .string("body"), "value": .string(inserted ? "Draft text" : "")])])])
            case "type_text": insertionWindow = args["window_id"]?.integer; inserted = true; return .object([:])
            default: XCTFail("Unexpected mutation"); throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            var answers: [String: Answer] = [:]
            for key in questions.keys {
                let choice: String
                switch key {
                case "app": choice = "app_0"
                case "visibility": choice = "background"
                case "scope": choice = "work"
                case "source": choice = "none"
                case "draftQuality": choice = "acceptable"
                case "next":
                    if inserted {
                        choice = "done"
                    } else if generated, case let .choice(_, criteria)? = questions["next"],
                              let action = criteria.first(where: { $0.value?.hasPrefix("Insert supplied text") == true })?.key {
                        choice = action
                    } else {
                        choice = "draft"
                    }
                case "risk": choice = "ordinary"
                case "windowEffect": choice = "same"
                default: throw DriverConnectionError.malformed
                }
                answers[key] = self.answer(choice)
            }
            return answers
        }, windowID: 1, generate: { _, _, _ in generated = true; return "Draft text" })
        _ = try await agent.run(goal: "Draft a greeting here", context: "", progress: { _ in })
        XCTAssertEqual(insertionWindow, 1)
        XCTAssertEqual(agent.windowID, 1)
    }

}
