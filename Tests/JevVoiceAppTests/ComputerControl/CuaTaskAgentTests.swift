import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaTaskAgentTests: XCTestCase {
    func testCancellationDuringWindowSelectionCannotActivateTheWindow() async throws {
        var activations = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7)]), .object(["window_id": .number(8)])])])
            case "bring_to_front":
                activations += 1
                return .object(["activated": .bool(true), "exact_window_effect": .object(["verified": .bool(true)])])
            default: throw CancellationError()
            }
        }, judge: { _, questions in
            if questions["window"] != nil {
                withUnsafeCurrentTask { $0?.cancel() }
                return ["window": .choice(choice: "7", confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "foreground", confidence: 1, probabilities: [:])]
        })
        let task = Task { try await agent.run(goal: "Show the requested document", context: "", progress: { _ in }) }
        do { _ = try await task.value; XCTFail("Cancelled selection completed") }
        catch is CancellationError { }
        XCTAssertEqual(activations, 0, "A late window decision must not steal focus after cancellation")
    }

    func testConfirmedScrollsCanRepeatButTimeoutAndUnverifiableEffectsCannot() async throws {
        for (timeout, unverifiable, repeatAuthorized, uncertainSecond) in [(false, false, true, false), (true, false, true, false), (false, true, true, false), (false, false, false, false), (false, false, true, true)] {
            var effects = 0
            let agent = CuaTaskAgent(call: { tool, _ in
                switch tool {
                case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
                case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
                case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
                case "get_window_state": return .object(["elements": .array([.object(["role": .string("AXScrollArea"), "label": .string("Document"), "element_token": .string("scroll-\(effects)")])])])
                case "scroll":
                    effects += 1
                    if timeout { throw DriverConnectionError.timedOut }
                    let unknown = unverifiable || (uncertainSecond && effects == 2)
                    return .object(["effect": .string(unknown ? "unverifiable" : "confirmed"), "route": .string("accessibility"),
                        "evidence": unknown ? .null : .array([.object(["kind": .string("value_readback")])])])
                default: throw DriverConnectionError.malformed
                }
            }, judge: { state, questions in
                var answers: [String: Answer] = [:]
                for (key, question) in questions {
                    let choice: String
                    switch key {
                    case "app": choice = "app_0"
                    case "scope": choice = "work"
                    case "visibility": choice = "background"
                    case "risk": choice = "ordinary"
                    case "windowEffect": choice = "same"
                    case "repeatIntent": choice = repeatAuthorized ? "additional" : "stop"
                    case "next":
                        if effects == (uncertainSecond ? 3 : 2) {
                            let history = state["history"]?.array ?? []
                            let ids = history.compactMap { $0["dispatch_id"]?.string }
                            XCTAssertEqual(ids.count, 2); XCTAssertEqual(Set(ids).count, 2)
                            choice = "done"
                        } else {
                            guard case let .choice(_, choices) = question,
                                  let id = choices.first(where: { $0.value == "Scroll Document down one page" })?.key else {
                                throw DriverConnectionError.refused("An intentional repeated scroll was suppressed.")
                            }
                            choice = id
                        }
                    default: throw DriverConnectionError.malformed
                    }
                    answers[key] = .choice(choice: choice, confidence: 1, probabilities: [:])
                }
                return answers
            }, windowID: 7, allowConfirmedRepetition: true)
            do {
                _ = try await agent.run(goal: "Scroll this document down one page, then down one more page", context: "", progress: { _ in })
                XCTAssertFalse(timeout || unverifiable || !repeatAuthorized || uncertainSecond)
            } catch {
                if timeout { XCTAssertEqual(error as? DriverConnectionError, .timedOut) }
                else if unverifiable || uncertainSecond { XCTAssertTrue(error.localizedDescription.contains("suppressed")) }
                else if !repeatAuthorized { XCTAssertTrue(error.localizedDescription.contains("No additional effect")) }
                else { throw error }
            }
            XCTAssertEqual(effects, timeout || unverifiable || !repeatAuthorized ? 1 : 2)
        }
    }
    func testDecisionContextPreservesAppStateAndExcludesUnrelatedSystemMenuSubtree() {
        let elements: [JSONValue] = [
            .object(["element_index": .number(0), "role": .string("AXMenuBarItem"), "label": .string("Apple")]),
            .object(["element_index": .number(1), "parent_index": .number(0), "role": .string("AXMenu")]),
            .object(["parent_index": .number(1), "role": .string("AXMenuItem"), "label": .string("Unrelated recent document")]),
            .object(["element_index": .number(2), "role": .string("AXMenuBarItem"), "label": .string("File")]),
            .object(["parent_index": .number(2), "role": .string("AXMenuItem"), "label": .string("New")]),
            .object(["role": .string("AXTextArea"), "value": .string("Current document"), "element_token": .string("opaque-handle")])
        ]
        let state = CuaTaskAgent.decisionElements(elements)
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(state[0]["label"], .string("File"))
        XCTAssertEqual(state[1]["label"], .string("New"))
        XCTAssertEqual(state[2]["value"], .string("Current document"))
        XCTAssertNil(state[2]["element_token"])
    }
    func testVisualInspectionUsesBoundCaptureAndNeverRetriesRejectedClick() async throws {
        for rejected in [false, true] {
            var parses = 0, clicks = 0
            let agent = CuaTaskAgent(call: { tool, args in
                switch tool {
                case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
                case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7), "title": .string(clicks == 0 ? "Ready" : "Applied")])])])
                case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
                case "get_window_state":
                    XCTAssertEqual(args["pid"], .number(42)); XCTAssertEqual(args["window_id"], .number(7))
                    return .object(["elements": .array([]), "capture_id": .string("capture-a")])
                case "parse_visual_regions":
                    parses += 1
                    XCTAssertEqual(args["capture_id"], .string("capture-a"))
                    return try JSONDecoder().decode(JSONValue.self, from: Data("""
                    {"schema":"cua.visual_regions_v1","capture":{"capture_id":"capture-a","source":{"kind":"window","pid":42,"window_id":7},"screenshot":{"reference":"fixture","width":800,"height":600,"mime_type":"image/png"},"action_coordinate_space":{"kind":"screenshot_pixels"}},"regions":[{"id":"apply","kind":"text","text":"Apply","confidence":0.99,"interactive":false,"bounds":{"x":100,"y":100,"width":40,"height":20}}]}
                    """.utf8))
                case "click":
                    clicks += 1
                    XCTAssertEqual(args["capture_id"], .string("capture-a"))
                    XCTAssertEqual(args["window_id"], .number(7))
                    XCTAssertEqual(args["x"], .number(120)); XCTAssertEqual(args["y"], .number(110))
                    if rejected { throw DriverConnectionError.toolRefused(tool: tool, code: "capture_frame_mismatch") }
                    return .object([:])
                default: XCTFail("Unexpected tool \(tool)"); throw DriverConnectionError.malformed
                }
            }, judge: { state, questions in
                var result: [String: Answer] = [:]
                for (key, question) in questions {
                    let answer: String
                    switch key {
                    case "app": answer = "app_0"
                    case "scope": answer = "work"
                    case "visibility": answer = "background"
                    case "risk": answer = "ordinary"
                    case "windowEffect": answer = "same"
                    case "next":
                        if clicks > 0 {
                            XCTAssertEqual(state["visual_regions"], .array([]), "A dispatched capture cannot survive as fresh evidence")
                            XCTAssertEqual(state["windows"]?.array?.first?["title"], .string("Applied"))
                            answer = "done"
                        } else if parses == 0 { answer = "inspectVisual" }
                        else {
                            guard case let .choice(_, choices) = question else { throw DriverConnectionError.malformed }
                            answer = try XCTUnwrap(choices.first { $0.value == "Click visual text Apply [region apply]" }?.key)
                        }
                    default: throw DriverConnectionError.malformed
                    }
                    result[key] = .choice(choice: answer, confidence: 1, probabilities: [:])
                }
                return result
            }, windowID: 7)
            do {
                _ = try await agent.run(goal: "Apply", context: "", progress: { _ in })
                XCTAssertFalse(rejected)
            } catch let error as DriverConnectionError {
                XCTAssertTrue(rejected)
                guard case .toolRefused(_, let code) = error else { throw error }
                XCTAssertEqual(code, "capture_frame_mismatch")
            }
            XCTAssertEqual(parses, 1); XCTAssertEqual(clicks, 1)
        }
    }

    func testSubmenuListingContinuesToAnObservedCommandWithoutClaimingAnAction() async throws {
        var listings = 0, mutations = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state": return .object(["elements": .array([
                .object(["element_index": .number(0), "role": .string("AXMenuBarItem"), "label": .string("Format")]),
                .object(["role": .string("AXStaticText"), "value": .string(mutations == 0 ? "Plain" : "Bold")])])])
            case "invoke_menu":
                XCTAssertEqual(args["window_id"], .number(7))
                if args["path"] == .array([.string("Format")]) {
                    listings += 1
                    return .object(["status": .string("listed"), "resolved_path": args["path"]!,
                        "items": .array([.object(["title": .string("Bold"), "has_submenu": .bool(false), "enabled": .bool(true)])])])
                }
                XCTAssertEqual(args["path"], .array([.string("Format"), .string("Bold")]))
                mutations += 1
                return .object([:])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            var answers: [String: Answer] = [:]
            for (key, question) in questions {
                let value: String
                switch key {
                case "app": value = "app_0"
                case "scope": value = "work"
                case "visibility": value = "background"
                case "risk": value = "ordinary"
                case "windowEffect": value = "same"
                case "next":
                    if mutations > 0 { value = "done" }
                    else {
                        guard case let .choice(_, criteria) = question else { throw DriverConnectionError.malformed }
                        let expected = listings == 0 ? "Inspect menu Format" : "Menu Format → Bold"
                        value = try XCTUnwrap(criteria.first { $0.value == expected }?.key)
                        if listings > 0 {
                            XCTAssertTrue(state["history"]?.array?.contains { $0["observation"] == .string("Listed submenu; no final command executed") } == true)
                        }
                    }
                default: throw DriverConnectionError.malformed
                }
                answers[key] = .choice(choice: value, confidence: 1, probabilities: [:])
            }
            return answers
        }, windowID: 7, approve: { _ in true })
        _ = try await agent.run(goal: "Make the fixture text bold", context: "", progress: { _ in })
        XCTAssertEqual(listings, 1)
        XCTAssertEqual(mutations, 1)
    }

    func testEmptyNativeObservationIsRefreshedWithoutReplayingActions() async throws {
        var reads = 0
        let agent = CuaTaskAgent(call: { name, _ in
            switch name {
            case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: name, code: "browser_route_unavailable")
            case "get_window_state":
                reads += 1
                return .object(["elements": .array(reads == 1 ? [] : [.object(["role": .string("AXButton"), "label": .string("Search"), "element_token": .string("search"), "actions": .array([.string("AXPress")])])])])
            default: XCTFail("Unexpected mutation \(name)"); throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["next"] != nil {
                XCTAssertEqual(reads, 2)
                return ["next": .choice(choice: "blocked", confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]), "scope": .choice(choice: "work", confidence: 1, probabilities: [:]), "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)
        do { _ = try await agent.run(goal: "Find the search control", context: "", progress: { _ in }); XCTFail("Fixture decision blocks") }
        catch { XCTAssertTrue(error.localizedDescription.contains("safe next action")) }
        XCTAssertEqual(reads, 2)
    }
    func testOpeningAppRequiresObservedRunningStateAndDoesNotReplay() async throws {
        var calls: [String] = []
        var running = false
        let agent = CuaTaskAgent(call: { name, _ in
            calls.append(name)
            switch name {
            case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("test.fixture"), "pid": .number(running ? 42 : 0), "running": .bool(running)])])])
            case "launch_app": running = true; return .object(["pid": .number(42)])
            case "list_windows": return .object(["windows": .array([])])
            default: XCTFail("Unexpected tool \(name)"); return .object([:])
            }
        }, judge: { _, questions in
            Dictionary(uniqueKeysWithValues: questions.map { key, _ in
                let value = key == "visibility" ? "background" : key == "app" ? "app_0" : key == "scope" ? "launch" : key == "next" ? "done" : "ordinary"
                return (key, Answer.choice(choice: value, confidence: 1, probabilities: [value: 1]))
            })
        })
        _ = try await agent.run(goal: "open Fixture", context: "", progress: { _ in })
        XCTAssertEqual(calls.filter { $0 == "launch_app" }.count, 1)
        XCTAssertTrue(calls.contains("get_accessibility_tree"), "Recheck live process state independently of the installed-app inventory")
    }
    func testUncertainLaunchIsNotRetried() async throws {
        var mutations = 0
        let agent = CuaTaskAgent(call: { name, _ in
            if ["list_apps", "get_accessibility_tree"].contains(name) { return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("test.fixture"), "pid": .number(0), "running": .bool(false)])])]) }
            if name == "launch_app" { mutations += 1; throw DriverConnectionError.timedOut }
            return .object([:])
        }, judge: { _, questions in
            Dictionary(uniqueKeysWithValues: questions.keys.map { ($0, Answer.choice(choice: $0 == "visibility" ? "background" : $0 == "app" ? "app_0" : $0 == "scope" ? "launch" : "ordinary", confidence: 1, probabilities: [:])) })
        })
        do { _ = try await agent.run(goal: "open Fixture", context: "", progress: { _ in }); XCTFail("Accepted uncertain mutation") }
        catch { XCTAssertEqual(error as? DriverConnectionError, .timedOut) }
        XCTAssertEqual(mutations, 1)
    }
    func testQueuedLaunchReobservesAndCannotClaimAnotherTasksProcess() async throws {
        var running = false, launches = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            if tool == "launch_app" { launches += 1; throw DriverConnectionError.malformed }
            XCTAssertTrue(["list_apps", "get_accessibility_tree"].contains(tool))
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(running ? 42 : 0), "running": .bool(running)])])])
        }, judge: { _, _ in ["visibility": .choice(choice: "background", confidence: 1, probabilities: [:]), "app": .choice(choice: "app_0", confidence: 1, probabilities: [:]), "scope": .choice(choice: "launch", confidence: 1, probabilities: [:])] })
        _ = try await agent.run(goal: "open Fixture", context: "", acquireApp: { _ in running = true }, progress: { _ in })
        XCTAssertEqual(launches, 0)
        XCTAssertNil(agent.launchedPID)
        XCTAssertNil(agent.launchReceipt)
    }
    func testLiteralContentCanOnlyBecomeOneAddressedInsertion() async throws {
        let literal = "open Notes and stop all"
        var inserted = "", actions: [String] = []
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "running": .bool(true), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable")
            case "get_window_state": return .object(["elements": .array([
                .object(["element_index": .number(0), "role": .string("AXTextArea"), "label": .string("Body"), "element_token": .string("body"), "value": .string(inserted)]),
                .object(["element_index": .number(1), "role": .string("AXButton"), "label": .string("Send"), "element_token": .string("send"), "actions": .array([.string("AXPress")])]),
                .object(["element_index": .number(2), "role": .string("AXTextField"), "label": .string("Other field"), "element_token": .string("other"), "value": .string("")])])])
            case "type_text": actions.append(tool); inserted = args["text"]!.string!; return .object([:])
            default: XCTFail("Literal text caused forbidden action \(tool)"); throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            var result: [String: Answer] = [:]
            for key in questions.keys {
                let choice: String
                switch key {
                case "app": choice = "app_0"
                case "visibility": choice = "background"
                case "scope": choice = "work"
                case "next": choice = "action_0" // An adversarial repeated choice must not cause a second insertion.
                case "risk": choice = "ordinary"
                case "windowEffect": choice = "same"
                default: throw DriverConnectionError.malformed
                }
                result[key] = .choice(choice: choice, confidence: 1, probabilities: [:])
            }
            return result
        }, generate: { _, _, _ in XCTFail("Literal input invoked generation"); return "" }, reasoningAvailable: true, literal: literal)
        _ = try await agent.run(goal: "Insert supplied literal text", context: "Fixture editor", progress: { _ in })
        XCTAssertEqual(inserted, literal)
        XCTAssertEqual(actions, ["type_text"])
    }

}
