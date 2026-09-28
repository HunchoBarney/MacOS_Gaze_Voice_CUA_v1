import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaTaskAgentTests: XCTestCase {
    func testExplicitKeyRequestCannotBecomeTextInsertion() async throws {
        var body = "seed"
        var keyCalls = 0
        var textCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array([.object(["element_index": .number(0), "role": .string("AXTextArea"),
                    "label": .string("Body"), "element_token": .string("body"), "value": .string(body)])])])
            case "press_key":
                XCTAssertEqual(args["key"], .string("return"))
                keyCalls += 1; body += "\n"
                return .object(["effect": .string("confirmed"), "evidence": .array([.string("AX value changed")])])
            case "type_text":
                textCalls += 1
                return .object([:])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            if case let .choice(_, criteria) = questions["next"] {
                if keyCalls > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                XCTAssertFalse(criteria.values.compactMap { $0 }.contains { $0.hasPrefix("Insert supplied text") })
                let key = try XCTUnwrap(criteria.first { $0.value?.hasPrefix("Press the requested key") == true }?.key)
                return ["next": .choice(choice: key, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7, actionSurface: .candidate)

        _ = try await agent.run(goal: "Press the key \"return\" in the body.", context: "", progress: { _ in })

        XCTAssertEqual(body, "seed\n")
        XCTAssertEqual(keyCalls, 1)
        XCTAssertEqual(textCalls, 0)
    }

    func testNegatedExplicitKeyRequestNeverOffersOrDispatchesAnAction() async {
        var body = "seed"
        var mutations = 0
        var nextDecisionCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object([
                    "name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)
                ])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state":
                throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array([.object([
                    "element_index": .number(0), "role": .string("AXTextArea"),
                    "label": .string("Body"), "element_token": .string("body"), "value": .string(body)
                ])])])
            case "press_key":
                mutations += 1
                body += "\n"
                return .object(["effect": .string("confirmed"), "evidence": .array([.string("AX value changed")])])
            case "type_text":
                mutations += 1
                body += args["text"]?.string ?? ""
                return .object(["effect": .string("confirmed"), "evidence": .array([.string("AX value changed")])])
            default:
                throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            if case let .choice(_, choices) = questions["next"] {
                nextDecisionCalls += 1
                if mutations > 0 {
                    return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])]
                }
                let mutation = try XCTUnwrap(choices.first {
                    $0.value?.hasPrefix("Press the requested key") == true
                        || $0.value?.hasPrefix("Insert supplied text") == true
                }?.key)
                return ["next": .choice(choice: mutation, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7, actionSurface: .candidate)

        do {
            _ = try await agent.run(goal: "Do not press the key \"return\" in Body.", context: "", progress: { _ in })
            XCTFail("A directly negated keyboard request must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("negated"), error.localizedDescription)
        }

        XCTAssertEqual(nextDecisionCalls, 0)
        XCTAssertEqual(mutations, 0)
        XCTAssertEqual(body, "seed")
    }

    func testNegatedExplicitKeyRequestDoesNotLaunchItsTarget() async {
        var running = false
        var launchCalls = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                var app: [String: JSONValue] = [
                    "name": .string("Fixture"), "bundle_id": .string("fixture")
                ]
                if running { app["pid"] = .number(42) }
                return .object(["apps": .array([.object(app)])])
            case "launch_app":
                launchCalls += 1
                running = true
                return .object(["pid": .number(42)])
            case "list_windows":
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "title": .string("Fixture")
                ])])])
            case "get_window_state":
                return .object(["elements": .array([.object([
                    "element_index": .number(0), "role": .string("AXTextArea"),
                    "label": .string("Body"), "element_token": .string("body"), "value": .string("seed")
                ])])])
            case "get_browser_state":
                throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default:
                throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
             "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
             "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, actionSurface: .candidate)

        do {
            _ = try await agent.run(goal: "Do not press the key \"return\" in Body.", context: "", progress: { _ in })
            XCTFail("A directly negated keyboard request must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("negated"), error.localizedDescription)
        }

        XCTAssertEqual(launchCalls, 0)
        XCTAssertFalse(running)
    }

    func testAddressedTextInsertionDoesNotPredictAnotherWindow() async throws {
        var inserted = "", mutations = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state": return .object(["elements": .array([.object(["element_index": .number(0), "role": .string("AXTextArea"), "label": .string("Body"), "element_token": .string("body"), "value": .string(inserted)])])])
            case "type_text":
                XCTAssertEqual(args["window_id"], .number(7))
                mutations += 1; inserted = args["text"]?.string ?? ""
                return .object([:])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            if questions["risk"] != nil {
                XCTAssertNil(questions["windowEffect"], "Addressed insertion must not ask a model to invent another destination")
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "new", confidence: 1, probabilities: [:])]
            }
            if questions["next"] != nil {
                if mutations > 0 { XCTAssertEqual(state["selected_window_id"], .number(7)) }
                if mutations > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                guard case let .choice(_, criteria) = questions["next"] else { throw DriverConnectionError.malformed }
                let candidate = try XCTUnwrap(criteria.first { $0.value == "Insert supplied text into AXTextArea Body" }?.key)
                return ["next": .choice(choice: candidate, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7, payload: { _, _ in "copper lantern" })
        _ = try await agent.run(goal: "Type copper lantern into this document", context: "", progress: { _ in })
        XCTAssertEqual(inserted, "copper lantern")
        XCTAssertEqual(mutations, 1)
    }

    func testNativeRefreshRejectsButtonWhoseMeaningChangesDuringRiskJudgment() async throws {
        var buttonLabel = "Preview"
        var clickCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array([.object(["element_index": .number(0), "role": .string("AXButton"),
                    "label": .string(buttonLabel), "element_token": .string("button-\(buttonLabel)"),
                    "actions": .array([.string("AXPress")]), "enabled": .bool(true)])])])
            case "click":
                clickCalls += 1
                return .object(["effect": .string("confirmed"), "evidence": .array([.string("AX action completed")])])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil {
                buttonLabel = "Delete"
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            if case let .choice(_, choices) = questions["next"] {
                if clickCalls > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                let preview = try XCTUnwrap(choices.first { $0.value == "Press AXButton Preview" }?.key)
                return ["next": .choice(choice: preview, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)

        do {
            _ = try await agent.run(goal: "Press Preview in the fixture.", context: "", progress: { _ in })
            XCTFail("A refreshed Delete control inherited Preview's risk decision")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("changed"))
        }
        XCTAssertEqual(clickCalls, 0)
    }

    func testSeventeenDistinctActionsFitWithinTheBoundedTaskBudget() async throws {
        let actionCount = 17
        var clicked = Set<Int>()
        let elements: [JSONValue] = (0..<actionCount).map { index in
            .object(["element_index": .number(Double(index)), "role": .string("AXButton"),
                     "label": .string("Button \(index)"), "element_token": .string("button-\(index)"),
                     "actions": .array([.string("AXPress")]), "enabled": .bool(true)])
        }
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state": return .object(["elements": .array(elements)])
            case "click":
                guard let token = args["element_token"]?.string,
                      let index = Int(token.dropFirst("button-".count)), clicked.insert(index).inserted else {
                    throw DriverConnectionError.refused("A button action was repeated or ambiguous.")
                }
                return .object(["effect": .string("confirmed"), "evidence": .array([.string("AX action completed")])])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            if case let .choice(_, criteria) = questions["next"] {
                if clicked.count == actionCount { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                let next = (0..<actionCount).first { !clicked.contains($0) }!
                let candidate = try XCTUnwrap(criteria.first { $0.value?.hasSuffix("Button \(next)") == true }?.key,
                                              "Missing Button \(next); observed choices: \(criteria.values.compactMap { $0 })")
                return ["next": .choice(choice: candidate, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)

        _ = try await agent.run(goal: "Press each of the 17 observed buttons once.", context: "", progress: { _ in })

        XCTAssertEqual(clicked.count, actionCount)
    }

    func testQuotedTextIsBoundBeforeJevChoosesTheInsertAction() async throws {
        var inserted = "", payloadCalls = 0, mutations = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array([.object(["element_index": .number(0), "role": .string("AXTextArea"), "label": .string("Body"), "element_token": .string("body"), "value": .string(inserted)])])])
            case "type_text":
                mutations += 1; inserted = args["text"]?.string ?? ""
                return .object([:])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil { return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:])] }
            if case let .choice(_, criteria) = questions["next"] {
                if mutations > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                let id = try XCTUnwrap(criteria.first { $0.value == "Insert supplied text into AXTextArea Body" }?.key)
                return ["next": .choice(choice: id, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7, payload: { _, _ in
            payloadCalls += 1
            return "copper lantern beside the"
        })

        _ = try await agent.run(goal: "Enter exactly \"copper lantern beside the window\" into the body.", context: "", progress: { _ in })

        XCTAssertEqual(inserted, "copper lantern beside the window")
        XCTAssertEqual(payloadCalls, 0)
        XCTAssertEqual(mutations, 1)
    }

    func testQuotedDestinationDoesNotBecomeTheInsertedText() async throws {
        var body = ""
        var payloadCalls = 0
        var mutations = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array([.object(["element_index": .number(0), "role": .string("AXTextArea"),
                    "label": .string("Body"), "element_token": .string("body"), "value": .string(body)])])])
            case "type_text":
                mutations += 1
                body = args["text"]?.string ?? ""
                return .object([:])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil { return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:])] }
            if case let .choice(_, choices) = questions["next"] {
                if mutations > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                let action = try XCTUnwrap(choices.first { $0.value == "Insert supplied text into AXTextArea Body" }?.key)
                return ["next": .choice(choice: action, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7, payload: { _, _ in
            payloadCalls += 1
            return "hello"
        })

        _ = try await agent.run(goal: #"Type hello into "Draft"."#, context: "", progress: { _ in })

        XCTAssertEqual(body, "hello")
        XCTAssertEqual(payloadCalls, 1)
        XCTAssertEqual(mutations, 1)
    }

    func testUnverifiedScrollCannotLeadToAnotherMutationOrSuccess() async throws {
        for nextAfterScroll in ["done", "click"] {
            var scrollCalls = 0
            var clickCalls = 0
            var nextDecisionCalls = 0
            let agent = CuaTaskAgent(call: { tool, _ in
                switch tool {
                case "list_apps", "get_accessibility_tree":
                    return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
                case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
                case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
                case "get_window_state":
                    return .object(["elements": .array([
                        .object(["element_index": .number(0), "role": .string("AXScrollArea"), "label": .string("Document"), "element_token": .string("scroll-area")]),
                        .object(["element_index": .number(1), "role": .string("AXButton"), "label": .string("Open"), "element_token": .string("open-button"), "actions": .array([.string("AXPress")]), "enabled": .bool(true)])
                    ])])
                case "scroll":
                    scrollCalls += 1
                    return .object(["effect": .string("unverifiable"), "route": .string("accessibility"), "evidence": .null])
                case "click":
                    clickCalls += 1
                    return .object(["effect": .string("confirmed"), "evidence": .array([.string("AX action completed")])])
                default: throw DriverConnectionError.malformed
                }
            }, judge: { _, questions in
                if questions["risk"] != nil {
                    return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                            "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
                }
                if case let .choice(_, choices) = questions["next"] {
                    nextDecisionCalls += 1
                    if scrollCalls == 0 {
                        let scroll = try XCTUnwrap(choices.first { $0.value == "Scroll Document down one page" }?.key)
                        return ["next": .choice(choice: scroll, confidence: 1, probabilities: [:])]
                    }
                    if nextAfterScroll == "done" || clickCalls > 0 {
                        return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])]
                    }
                    let click = try XCTUnwrap(choices.first { $0.value == "Press AXButton Open" }?.key)
                    return ["next": .choice(choice: click, confidence: 1, probabilities: [:])]
                }
                return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                        "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                        "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
            }, windowID: 7)

            do {
                _ = try await agent.run(goal: "Scroll down one page, then open the button.", context: "", progress: { _ in })
                XCTFail("An unresolved scroll was reported as completed")
            } catch {
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("incomplete"))
            }
            XCTAssertEqual(scrollCalls, 1)
            XCTAssertEqual(nextDecisionCalls, 1, "A known unresolved effect must surface before another Jev decision")
            XCTAssertEqual(clickCalls, 0, "A later action must not run before the uncertain scroll is resolved")
        }
    }

    func testPaginatedChoiceNavigationStopsWhenTheModelCyclesBetweenTargets() async throws {
        let controls: [JSONValue] = (0..<300).map { index in
            .object(["element_index": .number(Double(index)), "role": .string("AXButton"),
                     "label": .string("Control \(index)"), "element_token": .string("control-\(index)"),
                     "actions": .array([.string("AXPress")]), "enabled": .bool(true)])
        }
        var nextDecisionCalls = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state":
                throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array(controls)])
            default:
                XCTFail("Choice navigation dispatched unexpected tool \(tool)")
                throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            if questions["app"] != nil {
                return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                        "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                        "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
            }
            guard case let .choice(_, choices) = questions["next"] else {
                throw DriverConnectionError.malformed
            }
            nextDecisionCalls += 1
            if nextDecisionCalls > 40 {
                throw DriverConnectionError.refused("test pagination sentinel")
            }
            XCTAssertEqual(state["candidate_action_count"], .number(300))
            let choice: String
            if choices[CuaActionChoiceBook.backToTargetsID] != nil {
                choice = CuaActionChoiceBook.backToTargetsID
            } else {
                XCTAssertEqual(state["choice_grouping"], .string("target_groups"))
                choice = try XCTUnwrap(choices.keys.first(where: { $0.hasPrefix("target_") }))
            }
            return ["next": .choice(choice: choice, confidence: 1, probabilities: [:])]
        }, windowID: 7)

        do {
            _ = try await agent.run(goal: "Press one fixture control.", context: "", progress: { _ in })
            XCTFail("A cycling model must not keep the task alive indefinitely")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("bounded decision limit"), error.localizedDescription)
        }
        XCTAssertLessThanOrEqual(nextDecisionCalls, 40)
    }

    func testBrowserTextInsertionRebindsUniqueTargetWhenSnapshotRefIndexMoves() async throws {
        var value = "copper "
        var snapshotRevision = 0
        var typeCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome")])])])
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_window_state": return .object(["elements": .array([])])
            case "get_browser_state":
                if args["target_id"] == nil {
                    return .object(["binding_quality": .string("exact"), "mutation_allowed": .bool(true),
                                    "target_id": .string("target"), "tabs": .array([.object(["tab_id": .string("tab"), "active": .bool(true)])])])
                }
                snapshotRevision += 1
                let index = typeCalls == 0 ? 0 : 1
                return .object(["target_id": .string("target"), "tab_id": .string("tab"),
                    "page": .object(["url": .string("http://127.0.0.1/")]),
                    "refs": .array([.object(["ref": .string("p\(snapshotRevision):\(index)"), "role": .string("textbox"),
                        "name": .string("Search query"), "value": .string(value), "frame": .string("main"),
                        "actions": .array([.string("type")]), "visibility": .string("in_viewport"),
                        "states": .object(["editable": .string("plaintext"), "focusable": .bool(true)])])])])
            case "browser_dialog":
                return .object(["status": .string("ok"), "target_id": .string("target"), "tab_id": .string("tab"), "present": .bool(false)])
            case "browser_type":
                XCTAssertEqual(args["text"], .string("lantern"))
                XCTAssertEqual(args["ref"]?.string?.split(separator: ":").last.map(String.init), "0")
                typeCalls += 1
                value += args["text"]?.string ?? ""
                return .object(["status": .string("ok")])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:])]
            }
            if case let .choice(_, choices) = questions["next"] {
                if typeCalls > 0 {
                    XCTAssertFalse(choices.values.compactMap { $0 }.contains("Insert supplied text into page textbox Search query"),
                                   "A changed snapshot ref must not make a completed insertion eligible again.")
                    return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])]
                }
                let action = try XCTUnwrap(choices.first { $0.value == "Insert supplied text into page textbox Search query" }?.key)
                return ["next": .choice(choice: action, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)

        let result = try await agent.run(goal: "In Google Chrome in the background, type exactly \"lantern\" into the Search query field.",
                                         context: "Disposable local browser fixture", progress: { _ in })

        XCTAssertTrue(result.contains("Completed"))
        XCTAssertEqual(value, "copper lantern")
        XCTAssertEqual(typeCalls, 1)
    }

    func testExactQuotedTextRequiresOneUnambiguousClosedPair() {
        XCTAssertEqual(CuaTaskAgent.exactQuotedText(in: "Type exactly \" copper lantern. \" into the field."), " copper lantern. ")
        XCTAssertEqual(CuaTaskAgent.exactQuotedText(in: "Type exactly “copper lantern” into the field."), "copper lantern")
        XCTAssertNil(CuaTaskAgent.exactQuotedText(in: "Type \"one\" then \"two\"."))
        XCTAssertNil(CuaTaskAgent.exactQuotedText(in: "Type exactly \"unfinished into the field."))
    }

    func testPartialQuotedInsertionWithChangedLabelIsNotRepeatedOrReportedComplete() async throws {
        var fieldValue = "", mutations = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                let label = fieldValue.isEmpty ? "Body" : fieldValue
                return .object(["elements": .array([.object(["element_index": .number(0), "role": .string("AXTextArea"), "label": .string(label), "element_token": .string("snapshot-\(mutations)"), "value": .string(fieldValue)])])])
            case "type_text":
                mutations += 1
                XCTAssertEqual(args["text"], .string("copper lantern beside the window"))
                fieldValue = "copper lantern beside the"
                return .object(["effect": .string("confirmed"), "evidence": .array([.object(["kind": .string("accepted")])])])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil { return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:])] }
            if case let .choice(_, criteria) = questions["next"] {
                if mutations > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                let id = try XCTUnwrap(criteria.first { $0.value == "Insert supplied text into AXTextArea Body" }?.key)
                return ["next": .choice(choice: id, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7, payload: { _, _ in XCTFail("Quoted text must bypass extraction"); return "" })

        do {
            _ = try await agent.run(goal: "Enter exactly \"copper lantern beside the window\" into the body.", context: "", progress: { _ in })
            XCTFail("Partial insertion must not be accepted as complete")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be verified"), error.localizedDescription)
        }
        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(fieldValue, "copper lantern beside the")
    }

    func testMissingPreInsertionValueCannotBeAssumedBlank() async throws {
        var inserted = false, mutations = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                let element = JSONValue.object(["element_index": .number(0), "role": .string("AXTextArea"),
                    "label": .string("Body"), "element_token": .string("body"),
                    "value": inserted ? .string("exact phrase") : .null])
                return .object(["elements": .array([element])])
            case "type_text":
                mutations += 1; inserted = true
                return .object([:])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil { return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:])] }
            if case let .choice(_, criteria) = questions["next"] {
                if inserted { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                let candidate = try XCTUnwrap(criteria.first { $0.value == "Insert supplied text into AXTextArea Body" }?.key)
                return ["next": .choice(choice: candidate, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)

        do {
            _ = try await agent.run(goal: "Enter exactly \"exact phrase\" into the body.", context: "", progress: { _ in })
            XCTFail("An unknown starting value cannot prove exact insertion")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be verified"), error.localizedDescription)
        }
        XCTAssertEqual(mutations, 1, "An uncertain dispatched insertion must not be retried")
    }

    func testCreateRequestCannotTypeIntoTheExistingWindow() async throws {
        var mutations = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array([.object(["element_index": .number(0), "role": .string("AXTextArea"),
                    "label": .string("Existing document"), "element_token": .string("body"), "value": .string("Keep this text")])])])
            case "type_text": mutations += 1; return .object([:])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil { return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:])] }
            if case let .choice(_, criteria) = questions["next"] {
                let candidate = try XCTUnwrap(criteria.first { $0.value == "Insert supplied text into AXTextArea Existing document" }?.key)
                return ["next": .choice(choice: candidate, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "create", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)

        do {
            _ = try await agent.run(goal: "Create a new document and insert exactly \"new content\".", context: "", progress: { _ in })
            XCTFail("Create must wait until a new window is observed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no new window has been observed"), error.localizedDescription)
        }
        XCTAssertEqual(mutations, 0)
    }

    func testBrowserWithoutWindowsRequiresApprovalAndNavigatesThePreparedTab() async throws {
        var prepared = false
        var currentURL = "about:blank"
        var prepareCalls = 0
        var navigations: [[String: JSONValue]] = []
        var approvals: [String] = []
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome")])])])
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome"), "pid": .number(41)])])])
            case "list_windows":
                if args["pid"] == .number(41) { return .object(["windows": .array([])]) }
                XCTAssertEqual(args["pid"], .number(43))
                return .object(["windows": .array([.object(["window_id": .number(9), "title": .string("Chromium"), "is_on_screen": .bool(true)])])])
            case "browser_prepare":
                prepareCalls += 1
                XCTAssertEqual(args["allow_launch"], .bool(true))
                XCTAssertEqual(args["profile"], .object(["mode": .string("isolated_new")]))
                prepared = true
                return .object(["prepared_pid": .number(43)])
            case "get_window_state":
                XCTAssertEqual(args["pid"], .number(43))
                XCTAssertEqual(args["window_id"], .number(9))
                return .object(["elements": .array([])])
            case "get_browser_state":
                if args["target_id"] == nil {
                    XCTAssertEqual(args["pid"], .number(43))
                    XCTAssertEqual(args["window_id"], .number(9))
                    return .object(["binding_quality": .string("exact"), "mutation_allowed": .bool(true),
                                    "target_id": .string("isolated-target"),
                                    "tabs": .array([.object(["tab_id": .string("isolated-tab"), "active": .bool(true)])])])
                }
                XCTAssertEqual(args["target_id"], .string("isolated-target"))
                XCTAssertEqual(args["tab_id"], .string("isolated-tab"))
                return .object(["target_id": .string("isolated-target"), "tab_id": .string("isolated-tab"),
                                "page": .object(["url": .string(currentURL)]), "refs": .array([])])
            case "browser_dialog":
                return .object(["status": .string("ok"), "target_id": .string("isolated-target"),
                                "tab_id": .string("isolated-tab"), "present": .bool(false)])
            case "browser_navigate":
                XCTAssertTrue(prepared)
                XCTAssertEqual(args["target_id"], .string("isolated-target"))
                XCTAssertEqual(args["tab_id"], .string("isolated-tab"))
                navigations.append(args)
                currentURL = args["url"]?.string ?? ""
                return .object(["status": .string("accepted")])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            if questions["app"] != nil {
                return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                        "scope": .choice(choice: "create", confidence: 1, probabilities: [:]),
                        "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
            }
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            guard case let .choice(_, choices) = questions["next"] else { throw DriverConnectionError.malformed }
            if state["browser_page"]?["page"]?["url"] == .string("https://example.invalid/path?q=1") {
                return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])]
            }
            let candidate = try XCTUnwrap(choices.first { $0.value == "Navigate the bound browser tab to the requested address" }?.key)
            return ["next": .choice(choice: candidate, confidence: 1, probabilities: [:])]
        }, approve: { message in
            approvals.append(message)
            return true
        }, actionSurface: .candidate)

        _ = try await agent.run(goal: "Open \"https://example.invalid/path?q=1\"", context: "", progress: { _ in })

        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(navigations.count, 1)
        XCTAssertEqual(navigations[0]["url"], .string("https://example.invalid/path?q=1"))
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(approvals[0].contains("isolated Chrome profile"))
    }

    func testBrowserSetupRecoveryTracksPreparedProcessForSafeReversal() async throws {
        var prepareCalls = 0
        let stableElements: [JSONValue] = [
            .object(["element_index": .number(0), "role": .string("AXWindow"), "label": .string("Isolated browser")])
        ]
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome")])])])
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome"), "pid": .number(41)])])])
            case "list_windows":
                if args["pid"] == .number(41) {
                    return .object(["windows": .array([.object(["window_id": .number(7), "title": .string("Existing Chrome")])])])
                }
                XCTAssertEqual(args["pid"], .number(43))
                return .object(["windows": .array([.object(["window_id": .number(9), "title": .string("Isolated Chrome"), "is_on_screen": .bool(true)])])])
            case "get_window_state":
                return .object(["elements": .array(stableElements)])
            case "get_browser_state":
                if args["target_id"] != nil {
                    return .object(["target_id": .string("isolated-target"), "tab_id": .string("isolated-tab"),
                                    "page": .object(["url": .string("about:blank")]), "refs": .array([])])
                }
                if args["pid"] == .number(41) {
                    throw DriverConnectionError.toolRefused(tool: tool, code: "browser_requires_setup")
                }
                XCTAssertEqual(args["pid"], .number(43))
                XCTAssertEqual(args["window_id"], .number(9))
                return .object(["binding_quality": .string("exact"), "mutation_allowed": .bool(true),
                                "target_id": .string("isolated-target"),
                                "tabs": .array([.object(["tab_id": .string("isolated-tab"), "active": .bool(true)])])])
            case "browser_prepare":
                prepareCalls += 1
                return .object(["prepared_pid": .number(43)])
            case "browser_dialog":
                return .object(["status": .string("ok"), "target_id": .string("isolated-target"),
                                "tab_id": .string("isolated-tab"), "present": .bool(false)])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["app"] != nil {
                return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                        "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                        "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
            }
            if questions["next"] != nil {
                return ["next": .choice(choice: "blocked", confidence: 1, probabilities: [:])]
            }
            throw DriverConnectionError.malformed
        }, approve: { _ in true }, actionSurface: .candidate)

        do {
            _ = try await agent.run(goal: "Inspect the current page in Chrome.", context: "", progress: { _ in })
            XCTFail("The fixture has no safe page action")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("safe next action"), error.localizedDescription)
        }

        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(agent.launchedPID, 43)
        XCTAssertEqual(agent.launchReceipt?.pid, 43)
        XCTAssertEqual(agent.launchReceipt?.window, 9)
    }

    func testBoundBrowserPageChoicesExcludeNativeChromeMenus() async throws {
        var pointerCalls = 0
        let page: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab"),
            "page": .object(["url": .string("https://example.invalid/pointer")]),
            "refs": .array([.object(["ref": .string("p1:3"), "role": .string("link"),
                "name": .string("Pointer target"), "actions": .array([.string("pointer")]),
                "visibility": .string("in_viewport"), "frame": .string("main")])])])
        let nativeChrome: [JSONValue] = [
            .object(["element_index": .number(0), "parent_index": .number(1), "role": .string("AXButton"),
                     "label": .string("Close Window"), "element_token": .string("close"),
                     "actions": .array([.string("AXPress")])]),
            .object(["element_index": .number(1), "role": .string("AXMenuBarItem"), "label": .string("File"),
                     "element_token": .string("file"), "actions": .array([.string("AXPress")])])
        ]
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_window_state": return .object(["elements": .array(nativeChrome)])
            case "get_browser_state":
                if args["target_id"] == nil {
                    return .object(["binding_quality": .string("exact"), "mutation_allowed": .bool(true),
                                    "target_id": .string("target"), "tabs": .array([.object(["tab_id": .string("tab"), "active": .bool(true)])])])
                }
                return page
            case "browser_dialog":
                return .object(["status": .string("ok"), "target_id": .string("target"), "tab_id": .string("tab"), "present": .bool(false)])
            case "browser_pointer":
                XCTAssertEqual(args["target_id"], .string("target"))
                XCTAssertEqual(args["tab_id"], .string("tab"))
                XCTAssertEqual(args["ref"], .string("p1:3"))
                XCTAssertEqual(args["action"], .string("hover"))
                XCTAssertEqual(args["input_route"], .string("dom_event"))
                pointerCalls += 1
                return .object(["status": .string("accepted")])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            if case let .choice(_, criteria)? = questions["next"] {
                let descriptions = criteria.values.compactMap { $0 }
                XCTAssertFalse(descriptions.contains { $0.contains("Close Window") || $0.contains("Menu File") })
                if pointerCalls > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                let candidate = try XCTUnwrap(criteria.first { $0.value == "Hover over page link Pointer target" }?.key)
                return ["next": .choice(choice: candidate, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7, actionSurface: .candidate)

        _ = try await agent.run(goal: "Hover over the Pointer target link without clicking.", context: "", progress: { _ in })

        XCTAssertEqual(pointerCalls, 1)
    }

    func testDeniedIsolatedBrowserPreparationDoesNotLaunchOrNavigate() async throws {
        var prepareCalls = 0
        var actionCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome")])])])
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome"), "pid": .number(41)])])])
            case "list_windows": return .object(["windows": .array([])])
            case "browser_prepare": prepareCalls += 1; return .object(["prepared_pid": .number(43)])
            case "browser_navigate": actionCalls += 1; return .object([:])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["app"] != nil {
                return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                        "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                        "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
            }
            throw DriverConnectionError.malformed
        }, approve: { _ in false }, actionSurface: .candidate)

        do {
            _ = try await agent.run(goal: "Open \"https://example.invalid/\"", context: "", progress: { _ in })
            XCTFail("Denied browser preparation must stop the request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Approve a new isolated browser profile"))
        }
        XCTAssertEqual(prepareCalls, 0)
        XCTAssertEqual(actionCalls, 0)
    }

    func testBrowserUploadCannotDispatchWithoutHostApproval() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-upload-\(UUID().uuidString).txt")
        try Data("disposable upload fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var uploadCalls = 0
        var approvals: [String] = []
        let page: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab"),
            "page": .object(["url": .string("https://example.invalid/upload")]),
            "refs": .array([.object(["ref": .string("p4:2"), "role": .string("button"), "name": .string("Choose file"),
                "actions": .array([.string("upload")]), "visibility": .string("in_viewport")])])])
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome")])])])
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome"), "pid": .number(43)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(9), "title": .string("Upload fixture")])])])
            case "get_window_state": return .object(["elements": .array([])])
            case "get_browser_state":
                if args["target_id"] == nil {
                    return .object(["binding_quality": .string("exact"), "mutation_allowed": .bool(true),
                                    "target_id": .string("target"),
                                    "tabs": .array([.object(["tab_id": .string("tab"), "active": .bool(true)])])])
                }
                return page
            case "browser_dialog":
                return .object(["status": .string("ok"), "target_id": .string("target"),
                                "tab_id": .string("tab"), "present": .bool(false)])
            case "browser_set_input_files": uploadCalls += 1; return .object(["status": .string("ok")])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["app"] != nil {
                return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                        "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                        "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
            }
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            guard case let .choice(_, choices) = questions["next"],
                  let candidate = choices.first(where: { $0.value?.hasPrefix("Upload ") == true })?.key else {
                throw DriverConnectionError.malformed
            }
            return ["next": .choice(choice: candidate, confidence: 1, probabilities: [:])]
        }, approve: { message in
            approvals.append(message)
            return false
        }, actionSurface: .candidate)

        do {
            _ = try await agent.run(goal: "Upload the file \"\(file.path)\"", context: "", progress: { _ in })
            XCTFail("A denied file transfer must stop before dispatch")
        } catch { }

        XCTAssertEqual(uploadCalls, 0)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(approvals[0].contains(file.lastPathComponent))
        XCTAssertTrue(approvals[0].contains("example.invalid"))
    }

    func testWindowFrameRequiresApprovalAndIndependentGeometryReadback() async throws {
        for approvalResult in [false, true] {
            var frame = ["x": 0.0, "y": 0.0, "width": 800.0, "height": 600.0]
            var frameCalls = 0
            var approvals = 0
            let agent = CuaTaskAgent(call: { tool, args in
                switch tool {
                case "list_apps", "get_accessibility_tree":
                    return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
                case "list_windows":
                    return .object(["windows": .array([.object(["window_id": .number(7), "title": .string("Disposable"),
                        "bounds": .object(Dictionary(uniqueKeysWithValues: frame.map { ($0.key, .number($0.value)) }))])])])
                case "get_window_state": return .object(["elements": .array([])])
                case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
                case "set_window_frame":
                    frameCalls += 1
                    for key in ["x", "y", "width", "height"] {
                        if case .number(let value)? = args[key] { frame[key] = value }
                    }
                    return .object(["effect": .string("confirmed"), "route": .string("accessibility"),
                                    "evidence": .array([.object(["kind": .string("value_readback")])])])
                default: throw DriverConnectionError.malformed
                }
            }, judge: { _, questions in
                if questions["app"] != nil {
                    return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                            "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                            "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
                }
                if questions["risk"] != nil {
                    return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                            "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
                }
                guard case let .choice(_, choices) = questions["next"] else { throw DriverConnectionError.malformed }
                if frameCalls > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                let id = try XCTUnwrap(choices.first { $0.value?.hasPrefix("Set this window to x=") == true }?.key)
                return ["next": .choice(choice: id, confidence: 1, probabilities: [:])]
            }, approve: { _ in approvals += 1; return approvalResult }, actionSurface: .candidate)

            do {
                _ = try await agent.run(goal: "Set the current window to x=80 y=90 width=1000 height=700.", context: "", progress: { _ in })
                XCTAssertTrue(approvalResult)
            } catch {
                XCTAssertFalse(approvalResult)
            }
            XCTAssertEqual(approvals, 1)
            XCTAssertEqual(frameCalls, approvalResult ? 1 : 0)
            if approvalResult { XCTAssertEqual(frame, ["x": 80, "y": 90, "width": 1000, "height": 700]) }
        }
    }

    func testBrowserDialogResolutionUsesCurrentIDAndIsReobserved() async throws {
        var dialogOpen = false
        var clickCalls = 0
        var resolutionCalls = 0
        var approvals = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7), "title": .string("Dialog fixture")])])])
            case "get_window_state": return .object(["elements": .array([])])
            case "get_browser_state":
                if args["target_id"] == nil {
                    return .object(["binding_quality": .string("exact"), "mutation_allowed": .bool(true),
                                    "target_id": .string("target"), "tabs": .array([.object(["tab_id": .string("tab"), "active": .bool(true)])])])
                }
                XCTAssertFalse(dialogOpen, "Do not query browser page state while its JavaScript modal is open.")
                return .object(["target_id": .string("target"), "tab_id": .string("tab"),
                    "page": .object(["url": .string("https://example.invalid/dialog")]),
                    "refs": .array([.object(["ref": .string("p1:0"), "role": .string("button"),
                        "name": .string("Show confirmation"), "actions": .array([.string("click")]),
                        "visibility": .string("in_viewport")])])])
            case "browser_dialog":
                if args["action"] == .string("inspect") {
                    var inspection: [String: JSONValue] = ["status": .string("ok"), "target_id": .string("target"),
                        "tab_id": .string("tab"), "present": .bool(dialogOpen)]
                    if dialogOpen { inspection["dialog_id"] = .string("dialog-1"); inspection["kind"] = .string("confirm") }
                    return .object(inspection)
                }
                XCTAssertEqual(args["action"], .string("accept"))
                XCTAssertEqual(args["dialog_id"], .string("dialog-1"))
                resolutionCalls += 1; dialogOpen = false
                return .object(["status": .string("ok")])
            case "browser_click": clickCalls += 1; dialogOpen = true; return .object(["status": .string("ok")])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            if questions["app"] != nil {
                return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                        "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                        "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
            }
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            guard case let .choice(_, choices) = questions["next"] else { throw DriverConnectionError.malformed }
            if resolutionCalls > 0 {
                XCTAssertEqual(state["browser_dialog"]?["present"], .bool(false))
                return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])]
            }
            let description = dialogOpen ? "Accept the current JavaScript confirm dialog" : "Click page button Show confirmation"
            let id = try XCTUnwrap(choices.first { $0.value == description }?.key)
            return ["next": .choice(choice: id, confidence: 1, probabilities: [:])]
        }, approve: { _ in approvals += 1; return true }, actionSurface: .candidate)

        _ = try await agent.run(goal: "Click the \"Show confirmation\" button, then accept the current JavaScript dialog.", context: "", progress: { _ in })
        XCTAssertEqual(clickCalls, 1)
        XCTAssertEqual(resolutionCalls, 1)
        XCTAssertEqual(approvals, 1)
    }

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
            var postTimeoutInspections = 0
            let agent = CuaTaskAgent(call: { tool, _ in
                switch tool {
                case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
                case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
                case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
                case "get_window_state":
                    if timeout && effects > 0 { postTimeoutInspections += 1 }
                    return .object(["elements": .array([.object(["role": .string("AXScrollArea"), "label": .string("Document"), "element_token": .string("scroll-\(effects)")])])])
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
                        if effects >= (unverifiable ? 1 : 2) {
                            let history = state["history"]?.array ?? []
                            let ids = history.compactMap { $0["dispatch_id"]?.string }
                            XCTAssertEqual(ids.count, effects); XCTAssertEqual(Set(ids).count, effects)
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
                if timeout {
                    XCTAssertTrue(error.localizedDescription.contains("timed out after dispatch"))
                    XCTAssertTrue(error.localizedDescription.contains("effect remains uncertain"))
                }
                else if unverifiable || uncertainSecond { XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("incomplete")) }
                else if !repeatAuthorized { XCTAssertTrue(error.localizedDescription.contains("No additional effect")) }
                else { throw error }
            }
            XCTAssertEqual(effects, timeout || unverifiable || !repeatAuthorized ? 1 : 2)
            if timeout { XCTAssertEqual(postTimeoutInspections, 1, "A timed-out dispatched effect needs one read-only inspection before reporting uncertainty") }
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
    func testForegroundLaunchWaitsForSlowFirstWindowWithoutReplayingLaunch() async throws {
        var running = false, launchCalls = 0, windowReads = 0
        let agent = CuaTaskAgent(call: { name, _ in
            switch name {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("test.fixture"),
                    "pid": .number(running ? 42 : 0)])])])
            case "launch_app":
                launchCalls += 1; running = true
                return .object(["pid": .number(42)])
            case "list_windows":
                windowReads += 1
                return .object(["windows": .array(windowReads > 35 ? [.object(["window_id": .number(7),
                    "title": .string("Ready"), "is_on_screen": .bool(true)])] : [])])
            case "bring_to_front":
                return .object(["activated": .bool(true), "exact_window_effect": .object(["verified": .bool(true)])])
            case "get_window_state": return .object(["elements": .array([])])
            default: XCTFail("Unexpected tool \(name)"); return .object([:])
            }
        }, judge: { _, questions in
            Dictionary(uniqueKeysWithValues: questions.keys.map { key in
                let value = key == "app" ? "app_0" : key == "scope" ? "launch" : "foreground"
                return (key, Answer.choice(choice: value, confidence: 1, probabilities: [value: 1]))
            })
        })
        let result = try await agent.run(goal: "Open Fixture", context: "", progress: { _ in })
        XCTAssertTrue(result.contains("verified its window in front"))
        XCTAssertEqual(launchCalls, 1)
        XCTAssertGreaterThan(windowReads, 35)
    }
    func testUncertainLaunchIsNotRetried() async throws {
        var mutations = 0
        var postTimeoutInspections = 0
        let agent = CuaTaskAgent(call: { name, _ in
            if ["list_apps", "get_accessibility_tree"].contains(name) {
                if name == "get_accessibility_tree" && mutations > 0 { postTimeoutInspections += 1 }
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("test.fixture"), "pid": .number(mutations > 0 ? 42 : 0), "running": .bool(mutations > 0)])])])
            }
            if name == "launch_app" { mutations += 1; throw DriverConnectionError.timedOut }
            return .object([:])
        }, judge: { _, questions in
            Dictionary(uniqueKeysWithValues: questions.keys.map { ($0, Answer.choice(choice: $0 == "visibility" ? "background" : $0 == "app" ? "app_0" : $0 == "scope" ? "launch" : "ordinary", confidence: 1, probabilities: [:])) })
        })
        do { _ = try await agent.run(goal: "open Fixture", context: "", progress: { _ in }); XCTFail("Accepted uncertain mutation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("launch timed out")) }
        XCTAssertEqual(mutations, 1)
        XCTAssertEqual(postTimeoutInspections, 1, "A timed-out launch must be inspected without retrying")
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
                case "next":
                    guard case let .choice(_, criteria) = questions["next"] else { throw DriverConnectionError.malformed }
                    choice = try XCTUnwrap(criteria.first { $0.value == "Insert supplied text into AXTextArea Body" }?.key)
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

    func testExactInsertionVerificationDoesNotBlockOnALongAppend() async throws {
        let payload = "z"
        var body = String(repeating: "a", count: 5_000)
        var typeCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"),
                                                        "running": .bool(true), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state":
                throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array([.object([
                    "element_index": .number(0), "role": .string("AXTextArea"), "label": .string("Body"),
                    "element_token": .string("body"), "value": .string(body)
                ])])])
            case "type_text":
                typeCalls += 1
                body += args["text"]?.string ?? ""
                return .object([:])
            default:
                throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["app"] != nil {
                return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                        "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                        "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
            }
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:])]
            }
            guard case let .choice(_, choices) = questions["next"] else {
                throw DriverConnectionError.malformed
            }
            if typeCalls > 0 {
                return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])]
            }
            let action = try XCTUnwrap(choices.first { $0.value == "Insert supplied text into AXTextArea Body" }?.key)
            return ["next": .choice(choice: action, confidence: 1, probabilities: [:])]
        }, literal: payload)

        let start = ContinuousClock.now
        _ = try await agent.run(goal: "Append the supplied literal text.", context: "", progress: { _ in })
        let elapsed = start.duration(to: .now).components
        let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18

        XCTAssertEqual(typeCalls, 1)
        XCTAssertEqual(body, String(repeating: "a", count: 5_000) + payload)
        XCTAssertLessThan(elapsedSeconds, 1, "Exact-insertion verification must remain responsive on the main actor")
    }

}
