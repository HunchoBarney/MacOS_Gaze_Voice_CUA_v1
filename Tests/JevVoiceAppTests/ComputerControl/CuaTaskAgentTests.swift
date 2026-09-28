import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaTaskAgentTests: XCTestCase {
    private func transcriptHandoff(_ text: String, taskContext: JSONValue = .object([:])) throws -> TranscriptHandoff {
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 2, text: text, isFinal: true))
        return TranscriptHandoff(id: UUID(), captureID: UUID(), revision: audio.revision,
            transcript: text, pendingWordStart: 0, pendingWordEnd: text.split(whereSeparator: \.isWhitespace).count,
            final: false, receivedAt: 123.5, audioRanges: audio.segments, taskContext: taskContext)
    }

    private func voiceAnswers(_ questions: [String: Question], operation: String = "execute", span: String = "2",
                              task: String = "independent", app: String = "app_0", scope: String = "work",
                              visibility: String = "background", contentMode: String = "control",
                              literalStart: String = "none", literalEnd: String = "none",
                              correctionMode: String = "retract", replacementStart: String = "none",
                              replacementEnd: String = "none", clarification: String = "none") throws -> [String: Answer] {
        var answers: [String: Answer] = [:]
        for key in questions.keys {
            let value: String
            switch key {
            case "operation": value = operation
            case "span": value = span
            case "task": value = task
            case "app": value = app
            case "scope": value = scope
            case "visibility": value = visibility
            case "contentMode": value = contentMode
            case "literalStart": value = literalStart
            case "literalEnd": value = literalEnd
            case "correctionMode": value = correctionMode
            case "replacementStart": value = replacementStart
            case "replacementEnd": value = replacementEnd
            case "clarification": value = clarification
            default: throw DriverConnectionError.malformed
            }
            answers[key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
        }
        return answers
    }

    func testFirstExecutorDecisionReceivesOriginalTranscriptAndTaskContextWithCuaInventory() async throws {
        let activeTask: JSONValue = .object(["id": .string("task-17"), "request": .string("Open Notes"), "status": .string("Working")])
        let handoff = try transcriptHandoff("open Fixture", taskContext: .object(["tasks": .array([activeTask])]))
        var decisions = 0
        var selectedState: JSONValue?
        var selectedQuestions: Set<String> = []
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
        }, judge: { state, questions in
            decisions += 1
            selectedState = state
            selectedQuestions = Set(questions.keys)
            return try self.voiceAnswers(questions, span: "2")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(selectedState?["transcript"], .string("open Fixture"))
        XCTAssertEqual(selectedState?["task_context"], handoff.taskContext)
        XCTAssertEqual(selectedState?["installed_apps"]?.array?.first?["bundle_id"], .string("fixture"))
        XCTAssertNil(selectedState?["pending_speech"])
        XCTAssertTrue(selectedQuestions.contains("operation"))
        XCTAssertTrue(selectedQuestions.contains("app"))
        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.request, "open Fixture")
        XCTAssertEqual(decision.bundleID, "fixture")
        XCTAssertNil(decision.dependencyTaskID)
    }

    func testIncompleteTranscriptWaitsWithoutMutatingDesktop() async throws {
        let handoff = try transcriptHandoff("search for")
        var tools: [String] = []
        let agent = CuaTaskAgent(call: { tool, _ in
            tools.append(tool)
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, operation: "wait", span: "wait", app: "none", scope: "work")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.operation, .wait)
        XCTAssertNil(decision.consumedRange)
        XCTAssertEqual(tools, ["list_apps"], "An incomplete search must not dispatch an application action")
    }

    func testClarificationCarriesTheQuestionSelectedByTheFirstDecision() async throws {
        let handoff = try transcriptHandoff("send that")
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, operation: "clarify", span: "clarify", app: "none",
                                  clarification: "recipient")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.operation, .clarify)
        XCTAssertEqual(decision.clarification, .recipient)
        XCTAssertEqual(decision.clarification?.question, "Who should receive this?")
    }

    func testDecisionRefusesSpeechBeyondSupportedBoundBeforeCallingJev() async throws {
        let transcript = (0..<2_049).map { "word\($0)" }.joined(separator: " ")
        let handoff = try transcriptHandoff(transcript)
        var calledJev = false
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([])])
        }, judge: { _, _ in
            calledJev = true
            return [:]
        })

        do {
            _ = try await agent.decide(handoff: handoff)
            XCTFail("An oversized Choice request was sent to Jev")
        } catch {
            XCTAssertFalse(calledJev, "The executor must reject the request before constructing an invalid Jev Choice")
            XCTAssertTrue(error.localizedDescription.contains("2048"))
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("retained"))
        }
    }

    func testSupportedLongDecisionUsesBoundedGroupedChoicesInOneJevCall() async throws {
        let words = (0..<2_048).map { "word\($0)" }
        let handoff = try transcriptHandoff(words.joined(separator: " "))
        var decisions = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
        }, judge: { _, questions in
            decisions += 1
            var answers: [String: Answer] = [:]
            for (key, question) in questions {
                guard case let .choice(_, criteria) = question else {
                    XCTFail("Unexpected non-choice question \(key)")
                    continue
                }
                XCTAssertLessThanOrEqual(criteria.count, 255, "\(key) exceeded the TypeSafe Choice limit")
                let value: String
                switch key {
                case "operation": value = "execute"
                case "spanGroup": value = "10"
                case "spanOffset": value = "47"
                case "task": value = "independent"
                case "app": value = "app_0"
                case "scope": value = "work"
                case "visibility": value = "background"
                case "contentMode": value = "literal"
                case "literalStartGroup": value = "10"
                case "literalStartOffset": value = "0"
                case "literalEndGroup": value = "10"
                case "literalEndOffset": value = "47"
                case "correctionMode": value = "retract"
                case "clarification": value = "none"
                case "replacementStartGroup", "replacementStartOffset",
                     "replacementEndGroup", "replacementEndOffset": value = "none"
                default: throw DriverConnectionError.malformed
                }
                answers[key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
            }
            return answers
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decisions, 1, "Grouping must remain inside the executor's first Jev decision")
        XCTAssertEqual(decision.consumedRange, 0..<2_048)
        XCTAssertEqual(decision.request, words.joined(separator: " "))
        XCTAssertEqual(decision.literalText, words[2_000..<2_048].joined(separator: " "))
    }

    func testExecutorDecisionRoutesFollowUpToJevSelectedTask() async throws {
        let taskID = UUID()
        let context: JSONValue = .object(["tasks": .array([.object([
            "id": .string(taskID.uuidString), "request": .string("Open Notes"), "status": .string("Completed")
        ])])])
        let handoff = try transcriptHandoff("add a heading there", taskContext: context)
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "4", task: taskID.uuidString, app: "app_0")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.dependencyTaskID, taskID)
        XCTAssertEqual(decision.request, "add a heading there")
    }

    func testCorrectionReplacementIsSelectedWithItsTaskAndAppInOneExecutorDecision() async throws {
        let taskID = UUID()
        let task: JSONValue = .object(["id": .string(taskID.uuidString), "request": .string("Open Fixture"), "status": .string("Completed")])
        let handoff = try transcriptHandoff("actually open Fixture", taskContext: .object(["tasks": .array([task])]))
        var decisions = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
        }, judge: { _, questions in
            decisions += 1
            return try self.voiceAnswers(questions, operation: "correction", span: "3", task: taskID.uuidString,
                app: "app_0", scope: "launch", visibility: "foreground", correctionMode: "replace",
                replacementStart: "1", replacementEnd: "3")
        })

        let decision = try await agent.decide(handoff: handoff)
        let replacement = try XCTUnwrap(decision.replacementExecution)

        XCTAssertEqual(decisions, 1, "Task routing and replacement selection belong to the first executor decision")
        XCTAssertEqual(decision.operation, .correction)
        XCTAssertEqual(decision.selectedTaskID, taskID)
        XCTAssertEqual(decision.replacementRequest, "open Fixture")
        XCTAssertEqual(replacement.operation, .execute)
        XCTAssertEqual(replacement.request, "open Fixture")
        XCTAssertEqual(replacement.bundleID, "fixture")
        XCTAssertEqual(replacement.scope, "launch")
    }

    func testLiteralPayloadIsCopiedFromOriginalTranscriptIncludingControlWords() async throws {
        let original = "write open Notes\nand stop all into Fixture"
        let handoff = try transcriptHandoff(original)
        var decisions = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
        }, judge: { _, questions in
            decisions += 1
            return try self.voiceAnswers(questions, span: "8", contentMode: "literal", literalStart: "1", literalEnd: "6")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decisions, 1, "Literal text is selected in the first executor decision, without a second extraction request")
        XCTAssertEqual(decision.literalText, "open Notes\nand stop all")
        XCTAssertEqual(decision.request, original)
    }

    func testLiteralPayloadCanCreateTypeAndSubmitUsingJevSelectedScope() async throws {
        let transcript = "create a new document, enter Copper lantern, then submit it"
        let handoff = try transcriptHandoff(transcript)
        var createdWindow = false, foregrounded = false, submitted = false
        var typed = ""
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows":
                var windows: [JSONValue] = [.object(["window_id": .number(7), "title": .string("Original"), "is_on_screen": .bool(true)])]
                if createdWindow { windows.append(.object(["window_id": .number(8), "title": .string("New"), "is_on_screen": .bool(true)])) }
                return .object(["windows": .array(windows)])
            case "bring_to_front":
                foregrounded = true
                return .object(["activated": .bool(true), "exact_window_effect": .object(["verified": .bool(true)])])
            case "get_browser_state":
                throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                if args["window_id"]?.integer == 7 {
                    return .object(["elements": .array([
                        .object(["element_index": .number(0), "role": .string("AXMenuBarItem"), "label": .string("File")]),
                        .object(["element_index": .number(1), "parent_index": .number(0), "role": .string("AXMenuItem"), "label": .string("New")])
                    ])])
                }
                return .object(["elements": .array([
                    .object(["element_index": .number(0), "role": .string("AXTextField"), "label": .string("Search"), "element_token": .string("search"), "value": .string(typed)]),
                    .object(["element_index": .number(1), "role": .string("AXButton"), "label": .string("Submit"), "element_token": .string("submit"), "actions": .array([.string("AXPress")])])
                ])])
            case "invoke_menu":
                createdWindow = true
                return .object(["status": .string("invoked"), "resolved_path": args["path"] ?? .null])
            case "type_text":
                typed = args["text"]?.string ?? ""
                XCTAssertEqual(typed, "Copper lantern,", "The selected literal span must reach the selected CUA text action exactly")
                return .object([:])
            case "click":
                submitted = true
                return .object([:])
            default:
                XCTFail("Unexpected CUA tool \(tool)")
                throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            if questions["operation"] != nil {
                return try self.voiceAnswers(questions, span: "10", scope: "create", visibility: "foreground",
                    contentMode: "literal", literalStart: "5", literalEnd: "7")
            }
            if let question = questions["next"], case let .choice(_, choices) = question {
                if !createdWindow, let item = choices.first(where: { $0.value == "Menu File → New" }) {
                    return ["next": .choice(choice: item.key, confidence: 1, probabilities: [item.key: 1])]
                }
                if createdWindow, typed.isEmpty, let item = choices.first(where: { $0.value?.contains("Insert supplied text") == true }) {
                    return ["next": .choice(choice: item.key, confidence: 1, probabilities: [item.key: 1])]
                }
                if !typed.isEmpty, !submitted, let item = choices.first(where: { $0.value?.contains("Press AXButton Submit") == true }) {
                    return ["next": .choice(choice: item.key, confidence: 1, probabilities: [item.key: 1])]
                }
                return ["next": .choice(choice: "done", confidence: 1, probabilities: ["done": 1])]
            }
            if questions["risk"] != nil {
                let newWindow = state["request"] != nil && !createdWindow
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: newWindow ? "new" : "same", confidence: 1, probabilities: [:])]
            }
            throw DriverConnectionError.malformed
        })

        let decision = try await agent.decide(handoff: handoff)
        do { _ = try await agent.execute(decision, context: "Disposable Fixture", progress: { _ in }) }
        catch {
            XCTFail("Literal workflow failed after type_text: typed=\(typed), created=\(createdWindow), submitted=\(submitted), error=\(error)")
            return
        }

        XCTAssertTrue(foregrounded, "The executor must honor its selected foreground visibility")
        XCTAssertTrue(createdWindow, "A literal payload must not suppress the requested new-document action")
        XCTAssertEqual(typed, "Copper lantern,")
        XCTAssertTrue(submitted, "Post-insertion steps remain in the same observed execution workflow")
        XCTAssertEqual(agent.windowID, 8)
    }

    func testActionChoiceUsesFreshCuaObservationAfterTranscriptDecision() async throws {
        let handoff = try transcriptHandoff("click Search")
        var clicks = 0
        var observedSearch = false
        var decisionCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7), "title": .string("Search")])])])
            case "get_browser_state":
                throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                observedSearch = true
                return .object(["elements": .array([.object([
                    "element_index": .number(0), "role": .string("AXButton"), "label": .string(clicks == 0 ? "Search" : "Searched"),
                    "element_token": .string("search"), "actions": .array([.string("AXPress")])
                ])])])
            case "click":
                clicks += 1
                XCTAssertEqual(args["element_token"], .string("search"))
                return .object([:])
            default:
                XCTFail("Unexpected CUA tool \(tool)")
                throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            decisionCalls += 1
            if questions["operation"] != nil {
                return try self.voiceAnswers(questions, span: "2", scope: "work")
            }
            if questions["next"] != nil {
                XCTAssertTrue(observedSearch)
                XCTAssertEqual(state["elements"]?.array?.first?["label"], .string(clicks == 0 ? "Search" : "Searched"))
                if clicks > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])] }
                guard case let .choice(_, choices) = questions["next"] else { throw DriverConnectionError.malformed }
                let choice = try XCTUnwrap(choices.first { $0.value == "Press AXButton Search" }?.key)
                return ["next": .choice(choice: choice, confidence: 1, probabilities: [choice: 1])]
            }
            if questions["risk"] != nil {
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: "same", confidence: 1, probabilities: [:])]
            }
            throw DriverConnectionError.malformed
        })

        let decision = try await agent.decide(handoff: handoff)
        _ = try await agent.execute(decision, context: "Fixture", progress: { _ in })

        XCTAssertEqual(decisionCalls, 4)
        XCTAssertEqual(clicks, 1)
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
