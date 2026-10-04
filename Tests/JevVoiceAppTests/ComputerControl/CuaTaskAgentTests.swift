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
                              correctionMode: String = "retract", relationship: String? = nil,
                              pendingQuestion: String = "none",
                              replacementStart: String = "none",
                              replacementEnd: String = "none", clarification: String = "none") throws -> [String: Answer] {
        var answers: [String: Answer] = [:]
        for key in questions.keys {
            let value: String
            switch key {
            case "operation": value = operation
            case "span": value = span
            case "task": value = task
            case "relationship": value = relationship ?? (task == "independent" ? "independent" : "reference")
            case "pendingQuestion": value = pendingQuestion
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
            case "doneEvidence": value = "proven"
            default: throw DriverConnectionError.malformed
            }
            answers[key] = .choice(choice: value, confidence: 1, probabilities: [value: 1])
        }
        return answers
    }

    func testRelationshipSemanticsMapToDialogueContracts() {
        let intentID = UUID()

        XCTAssertEqual(CuaTaskRelationship(dialogue: .independent), .independent)
        XCTAssertEqual(CuaTaskRelationship(dialogue: .refinement(of: intentID)), .reference)
        XCTAssertEqual(CuaTaskRelationship(dialogue: .continuation(of: intentID)), .continuation)
        XCTAssertEqual(CuaTaskRelationship(dialogue: .correction(of: intentID)), .revision)

        // Conversational relationships recorded by `add` map exhaustively.
        XCTAssertEqual(CuaTaskRelationship.independent.dialogueRelationship(referencedIntentID: nil), .independent)
        XCTAssertEqual(CuaTaskRelationship.reference.dialogueRelationship(referencedIntentID: intentID), .refinement(of: intentID))
        XCTAssertEqual(CuaTaskRelationship.continuation.dialogueRelationship(referencedIntentID: intentID), .continuation(of: intentID))
        XCTAssertEqual(CuaTaskRelationship.revision.dialogueRelationship(referencedIntentID: intentID), .correction(of: intentID))
        XCTAssertNil(CuaTaskRelationship.reference.dialogueRelationship(referencedIntentID: nil))
        XCTAssertNil(CuaTaskRelationship.continuation.dialogueRelationship(referencedIntentID: nil))
        XCTAssertNil(CuaTaskRelationship.revision.dialogueRelationship(referencedIntentID: nil))

        // Answers and retries are in-place operations on an existing entry, and a
        // prerequisite contributes only an execution-blocking edge: none of them is
        // a Relationship, and a prerequisite must never collapse into .continuation.
        XCTAssertNil(CuaTaskRelationship.answer.dialogueRelationship(referencedIntentID: intentID))
        XCTAssertNil(CuaTaskRelationship.retry.dialogueRelationship(referencedIntentID: intentID))
        XCTAssertNil(CuaTaskRelationship.prerequisite.dialogueRelationship(referencedIntentID: intentID))
      }

      func testPrerequisiteDecisionAddsIndependentIntentWithABlockingEdge() {
        let intentID = UUID()
        let requiredID = UUID()
        var decision = CuaExecutorDecision(operation: .execute, consumedRange: 0..<2, request: "then add a heading",
            replacementRequest: nil, selectedTaskID: requiredID, dependencyTaskID: requiredID,
            appName: "Notes", bundleID: "notes", scope: "work", visibility: "background", literalText: nil)
        decision.relationship = .prerequisite

        XCTAssertTrue(decision.addsDialogueIntent)
        XCTAssertEqual(decision.dialogueAddRelationship, .independent,
                       "A prerequisite is conversationally independent; only its Prerequisite edge blocks execution")
        XCTAssertNil(decision.dialogueRelationship)
        XCTAssertEqual(decision.dialoguePrerequisite(intentID: intentID),
                       CuaDialogueState.Prerequisite(intentID: intentID, requiresIntentID: requiredID))
        // A non-prerequisite reference never grows an execution-blocking edge.
        XCTAssertNil(CuaExecutorDecision(operation: .execute, consumedRange: 0..<2, request: "same app",
            replacementRequest: nil, selectedTaskID: requiredID, dependencyTaskID: nil,
            appName: "Notes", bundleID: "notes", scope: "work", visibility: "background", literalText: nil)
            .dialoguePrerequisite(intentID: intentID))
      }

      func testAnswerAndRetryDecisionsOperateOnExistingEntries() {
        let intentID = UUID()
        var answer = CuaExecutorDecision(operation: .execute, consumedRange: 0..<3, request: "the front window",
            replacementRequest: nil, selectedTaskID: intentID, dependencyTaskID: nil,
            appName: "Notes", bundleID: "notes", scope: "work", visibility: "background", literalText: nil)
        answer.relationship = .answer
        answer.questionID = UUID()

        var retry = CuaExecutorDecision(operation: .execute, consumedRange: 0..<3, request: "try that again",
            replacementRequest: nil, selectedTaskID: intentID, dependencyTaskID: nil,
            appName: "Notes", bundleID: "notes", scope: "work", visibility: "background", literalText: nil)
        retry.relationship = .retry

        XCTAssertFalse(answer.addsDialogueIntent)
        XCTAssertNil(answer.dialogueRelationship)
        XCTAssertNotNil(answer.questionID)
        XCTAssertFalse(retry.addsDialogueIntent)
        XCTAssertNil(retry.dialogueRelationship)
        XCTAssertEqual(retry.selectedTaskID, intentID)
      }

      func testStructuredExecutorResultDistinguishesTargetAmbiguity() async throws {
        let decision = CuaExecutorDecision(operation: .execute, consumedRange: 0..<1, request: "open it",
            replacementRequest: nil, selectedTaskID: nil, dependencyTaskID: nil, appName: "Fixture",
            bundleID: "fixture", scope: "work", visibility: "background", literalText: nil)
        let agent = CuaTaskAgent(call: { _, _ in
            throw DriverConnectionError.refused("The destination is ambiguous; ask which window before continuing.")
        }, judge: { _, _ in [:] })

        let result = await agent.executeStructured(decision, context: "", progress: { _ in })

        XCTAssertEqual(result.decision, decision)
        XCTAssertEqual(result.outcome, .targetAmbiguous("The destination is ambiguous; ask which window before continuing."))
      }

      func testExecutorDecisionCarriesTypedFreshTargetPreference() async throws {
        let handoff = try transcriptHandoff("open Fixture")
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "2")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.targetPreference, CuaTargetPreference(appName: "Fixture", bundleID: "fixture", provenance: .selectedApp))
        XCTAssertEqual(decision.dialogueRelationship, .independent)
      }

      func testUtteranceNamingPendingQuestionOptionBindsAsAnswer() async throws {
        let questionID = UUID()
        let pendingQuestion: JSONValue = .object([
            "id": .string(questionID.uuidString),
            "question": .string("Which window should I use?"),
            "options": .array([.string("Untitled 21"), .string("Untitled 19"), .string("Untitled 20")]),
            "task": .string("task-17")
        ])
        let activeTask: JSONValue = .object([
            "id": .string("task-17"),
            "request": .string("type the words meeting moved to 4pm into TextEdit"),
            "status": .string("awaitingAnswer"),
            "app": .string("com.apple.TextEdit")
        ])
        let handoff = try transcriptHandoff("Untitled 21", taskContext: .object([
            "tasks": .array([activeTask]), "questions": .array([pendingQuestion])
        ]))
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("TextEdit"), "bundle_id": .string("com.apple.TextEdit")])])])
        }, judge: { _, questions in
            // The model misses the answer entirely — the same failure the live
            // Activity UI produced (op=wait, rel=independent).
            try self.voiceAnswers(questions, operation: "wait")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.relationship, .answer)
        XCTAssertEqual(decision.questionID, questionID)
        XCTAssertEqual(decision.bundleID, "com.apple.TextEdit")
      }

      func testUtteranceMerelyContainingAnOptionStaysAnIndependentRequest() async throws {
        // "open Fixture" only *contains* a window titled "Fixture" — treating
        // it as the answer would steal every command naming the app while a
        // question is pending.
        let pendingQuestion: JSONValue = .object([
            "id": .string(UUID().uuidString),
            "question": .string("Which window should I use?"),
            "options": .array([.string("Fixture"), .string("Untitled 21")]),
            "task": .string("task-17")
        ])
        let handoff = try transcriptHandoff("open Fixture", taskContext: .object([
            "tasks": .array([.object(["id": .string("task-17"), "app": .string("fixture")])]),
            "questions": .array([pendingQuestion])
        ]))
        let agent = CuaTaskAgent(call: { _, _ in
            .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "2")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.relationship, .independent)
        XCTAssertNil(decision.questionID)
      }

      func testFirstExecutorDecisionReceivesOriginalTranscriptAndTaskContextWithCuaInventory() async throws {
        let activeTask: JSONValue = .object(["id": .string("task-17"), "request": .string("Open Notes"), "status": .string("Working")])
        let pendingQuestion: JSONValue = .object(["id": .string(UUID().uuidString), "question": .string("Which window should I use?"), "task": .string("Open Notes")])
        let handoff = try transcriptHandoff("open Fixture", taskContext: .object([
            "tasks": .array([activeTask]), "questions": .array([pendingQuestion])
        ]))
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
        XCTAssertTrue(selectedQuestions.contains("pendingQuestion"),
                      "Pending questions are offered inside the same atomic decision")
        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.request, "open Fixture")
        XCTAssertEqual(decision.bundleID, "fixture")
        XCTAssertNil(decision.dependencyTaskID)
    }

    func testExplicitAppMentionOverridesTheModelAppPick() async throws {
        // The live failure this guards: "open Notes…" was answered with
        // app_0 → Google Chrome, and the whole task ran against the wrong
        // app. A whole-word app name in the transcript outranks the pick.
        let handoff = try transcriptHandoff("open Notes and write a note that says buy milk and eggs")
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([
                .object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome")]),
                .object(["name": .string("Notes"), "bundle_id": .string("com.apple.Notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "12", app: "app_0")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.bundleID, "com.apple.Notes",
                       "An app named in the request wins over the model's contradictory pick")
        XCTAssertEqual(decision.appName, "Notes")
    }

    func testTwoExplicitAppMentionsKeepTheModelAppPick() async throws {
        // "from Chrome into Notes" names two apps — which is the destination
        // is a judgment call, so the model's answer stands.
        let handoff = try transcriptHandoff("copy the current page from Chrome into Notes")
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([
                .object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome")]),
                .object(["name": .string("Notes"), "bundle_id": .string("com.apple.Notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "8", app: "app_0")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.bundleID, "com.google.Chrome")
    }

    func testPayloadNounDoesNotBindAnApp() async throws {
        // The live failure this guards: "search for the weather today" named
        // no app, yet a bare noun match hijacked the task into Weather.app.
        // An app binds only in app position — after a launcher or at the
        // request's start — never as a payload noun.
        let handoff = try transcriptHandoff("open google and search for the weather today in yuba city")
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([
                .object(["name": .string("Google Chrome"), "bundle_id": .string("com.google.Chrome")]),
                .object(["name": .string("Weather"), "bundle_id": .string("com.apple.weather")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "11", app: "app_0",
                                  contentMode: "literal", literalStart: "6", literalEnd: "11")
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.bundleID, "com.google.Chrome",
                       "A payload noun must not bind the Weather app")
    }

    func testDirectVoiceDecisionCannotDispatchAnExplicitlyNegatedKeyAction() async throws {
        let text = "Do not press the key \"return\" in Body."
        let handoff = try transcriptHandoff(text)
        var effects = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            if tool == "list_apps" {
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture")])])])
            }
            effects += 1
            throw DriverConnectionError.malformed
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: String(text.split(whereSeparator: \.isWhitespace).count),
                                  scope: "work")
        })
        let decision = try await agent.decide(handoff: handoff)
        XCTAssertEqual(decision.operation, .execute)
        do {
            _ = try await agent.execute(decision, context: "", progress: { _ in })
            XCTFail("A selected operation cannot bypass the negated-key guard")
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("negated"), error.localizedDescription)
        }
        XCTAssertEqual(effects, 0)
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
                case "relationship": value = "independent"
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

        XCTAssertEqual(decision.selectedTaskID, taskID)
        XCTAssertNil(decision.dependencyTaskID, "A reference is not a prerequisite")
        XCTAssertEqual(decision.relationship, .reference)
        XCTAssertEqual(decision.dialogueRelationship, .refinement(of: taskID))
        XCTAssertTrue(decision.addsDialogueIntent)
        XCTAssertNil(decision.dialoguePrerequisite(intentID: UUID()), "A reference never grows a blocking edge")
        XCTAssertEqual(decision.request, "add a heading there")
    }

    func testPrerequisiteDecisionDoesNotGateOnTaskStatusDisplayStrings() async throws {
        let taskID = UUID()
        // A failed related task still produces a prerequisite decision: whether it
        // may execute is dialogue-state enforcement, not a status-string check.
        let context: JSONValue = .object(["tasks": .array([.object([
            "id": .string(taskID.uuidString), "request": .string("Open Notes"), "status": .string("Failed")
        ])])])
        let handoff = try transcriptHandoff("then add a heading", taskContext: context)
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "4", task: taskID.uuidString, app: "app_0", relationship: "prerequisite")
        })
        let decision = try await agent.decide(handoff: handoff)
        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.relationship, .prerequisite)
        XCTAssertEqual(decision.dependencyTaskID, taskID)
        XCTAssertNil(decision.dialogueRelationship)
        XCTAssertEqual(decision.dialogueAddRelationship, .independent)
        XCTAssertEqual(decision.dialoguePrerequisite(intentID: UUID())?.requiresIntentID, taskID)
    }

    func testVerifiedPrerequisiteRetainsDependency() async throws {
        let taskID = UUID()
        let context: JSONValue = .object(["tasks": .array([.object([
            "id": .string(taskID.uuidString), "request": .string("Open Notes"), "status": .string("verified")
        ])])])
        let handoff = try transcriptHandoff("then add a heading", taskContext: context)
        let agent = CuaTaskAgent(call: { _, _ in
            .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "4", task: taskID.uuidString, app: "app_0", relationship: "prerequisite")
        })
        let decision = try await agent.decide(handoff: handoff)
        XCTAssertEqual(decision.relationship, .prerequisite)
        XCTAssertEqual(decision.dependencyTaskID, taskID)
        XCTAssertEqual(decision.dialogueAddRelationship, .independent)
    }

    func testNonIndependentRelationshipWithoutReferencedTaskClarifies() async throws {
        let handoff = try transcriptHandoff("continue that work")
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "3", task: "independent", relationship: "continuation")
        })
        let decision = try await agent.decide(handoff: handoff)
        XCTAssertEqual(decision.operation, .clarify)
        // No tasks exist in context, so "which task" would be unanswerable;
        // the question degrades to the answerable operation prompt.
        XCTAssertEqual(decision.clarification, .operation)
    }

    func testIndependentRelationshipCannotCarryATaskReference() async throws {
        let taskID = UUID()
        let context: JSONValue = .object(["tasks": .array([.object([
            "id": .string(taskID.uuidString), "request": .string("Open Notes"), "status": .string("Completed")
        ])])])
        let handoff = try transcriptHandoff("open something else", taskContext: context)
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "3", task: taskID.uuidString, relationship: "independent")
        })
        let decision = try await agent.decide(handoff: handoff)
        // The stray task pick must not be carried: an independent request
        // executes standalone rather than parking on a "which task" question.
        XCTAssertEqual(decision.operation, .execute)
        XCTAssertNil(decision.selectedTaskID)
        XCTAssertEqual(decision.request, "open something else")
    }

    func testAnswerDecisionBindsPendingQuestionAndNeverAddsAnIntent() async throws {
        let taskID = UUID()
        let questionID = UUID()
        let context: JSONValue = .object([
            "tasks": .array([.object([
                "id": .string(taskID.uuidString), "request": .string("Open Notes"),
                "status": .string("Needs confirmation")
            ])]),
            "questions": .array([.object([
                "id": .string(questionID.uuidString),
                "question": .string("Which window should I use?"),
                "task": .string("Open Notes"), "revision": .number(3)
            ])])
        ])
        let handoff = try transcriptHandoff("the front window", taskContext: context)
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "3", task: taskID.uuidString, app: "app_0",
                relationship: "answer", pendingQuestion: questionID.uuidString)
        })
        let decision = try await agent.decide(handoff: handoff)
        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.relationship, .answer)
        XCTAssertEqual(decision.questionID, questionID)
        XCTAssertEqual(decision.intentRevision, 3)
        XCTAssertEqual(decision.selectedTaskID, taskID)
        XCTAssertFalse(decision.addsDialogueIntent, "An answer routes to dialogue.answer, never add")
        XCTAssertNil(decision.dialogueRelationship)
        XCTAssertNil(decision.dependencyTaskID)
    }

    func testAnswerDecisionWithoutAPendingQuestionClarifies() async throws {
        let taskID = UUID()
        let context: JSONValue = .object(["tasks": .array([.object([
            "id": .string(taskID.uuidString), "request": .string("Open Notes"), "status": .string("Working")
        ])])])
        let handoff = try transcriptHandoff("the front window", taskContext: context)
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            XCTAssertNil(questions["pendingQuestion"], "No pending questions exist to answer")
            return try self.voiceAnswers(questions, span: "3", task: taskID.uuidString,
                app: "app_0", relationship: "answer")
        })
        let decision = try await agent.decide(handoff: handoff)
        XCTAssertEqual(decision.operation, .clarify)
        XCTAssertEqual(decision.clarification, .task)
        XCTAssertNil(decision.questionID)
    }

    func testRetryDecisionResumesTheExistingIntentWithoutStatusGating() async throws {
        let taskID = UUID()
        // An "Uncertain" display status must not decide blocking here; the dialogue
        // state enforces retry admissibility via retryUncertain/revise.
        let context: JSONValue = .object(["tasks": .array([.object([
            "id": .string(taskID.uuidString), "request": .string("Open Notes"), "status": .string("Uncertain")
        ])])])
        let handoff = try transcriptHandoff("try that again", taskContext: context)
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "3", task: taskID.uuidString, app: "app_0",
                relationship: "retry")
        })
        let decision = try await agent.decide(handoff: handoff)
        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.relationship, .retry)
        XCTAssertEqual(decision.selectedTaskID, taskID)
        XCTAssertFalse(decision.addsDialogueIntent, "A retry resumes the intent in place, never add")
        XCTAssertNil(decision.dialogueRelationship)
        XCTAssertNil(decision.dependencyTaskID)
    }

    /// An answer that names the missing detail rather than an app resolves the
    /// question owner's published target from task context, so the owner resumes
    /// in place instead of becoming a fresh clarification intent.
    func testAnswerWithoutAnAppUsesTheQuestionOwnersPublishedTarget() async throws {
        let taskID = UUID()
        let questionID = UUID()
        let context: JSONValue = .object([
            "tasks": .array([.object([
                "id": .string(taskID.uuidString), "request": .string("Open Notes and type"),
                "status": .string("awaitingAnswer"), "app": .string("notes")
            ])]),
            "questions": .array([.object([
                "id": .string(questionID.uuidString),
                "question": .string("Which window should I use?"),
                "task": .string(taskID.uuidString), "revision": .number(1)
            ])])
        ])
        let handoff = try transcriptHandoff("the front window", taskContext: context)
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "3", task: taskID.uuidString, app: "none",
                relationship: "answer", pendingQuestion: questionID.uuidString)
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.relationship, .answer)
        XCTAssertEqual(decision.questionID, questionID)
        XCTAssertEqual(decision.bundleID, "notes",
            "The owner's stored target supplies the app the answer did not name")
        XCTAssertEqual(decision.appName, "Notes")
        XCTAssertFalse(decision.addsDialogueIntent)
    }

    /// When neither the answering utterance nor the owner's published target
    /// resolves an installed app, the decision still binds the question — the
    /// runtime resumes the owner and the executor blocks honestly, instead of
    /// creating a fresh clarification intent that loses the answer.
    func testAnswerWithUnresolvableAppStillBindsItsQuestion() async throws {
        let taskID = UUID()
        let questionID = UUID()
        let context: JSONValue = .object([
            "tasks": .array([.object([
                "id": .string(taskID.uuidString), "request": .string("Open Notes and type"),
                "status": .string("awaitingAnswer"), "app": .string("missing.app")
            ])]),
            "questions": .array([.object([
                "id": .string(questionID.uuidString),
                "question": .string("Which window should I use?"),
                "task": .string(taskID.uuidString), "revision": .number(1)
            ])])
        ])
        let handoff = try transcriptHandoff("the front window", taskContext: context)
        let agent = CuaTaskAgent(call: { tool, _ in
            XCTAssertEqual(tool, "list_apps")
            return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
        }, judge: { _, questions in
            try self.voiceAnswers(questions, span: "3", task: taskID.uuidString, app: "none",
                relationship: "answer", pendingQuestion: questionID.uuidString)
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.relationship, .answer)
        XCTAssertEqual(decision.questionID, questionID)
        XCTAssertNil(decision.bundleID)
        XCTAssertNil(decision.targetPreference,
            "No target preference is fabricated; the runtime re-binds the stored target")
        XCTAssertFalse(decision.addsDialogueIntent)
    }

    /// A pending-question binding with a non-answer relationship is
    /// contradictory: it surfaces a task-identification clarification rather
    /// than silently dropping the bound answer or misrouting an explicit answer.
    func testPendingQuestionBoundToNonAnswerRelationshipClarifies() async throws {
        for relationship in ["independent", "reference", "continuation", "retry", "revision", "prerequisite"] {
            let taskID = UUID()
            let questionID = UUID()
            let context: JSONValue = .object([
                "tasks": .array([.object([
                    "id": .string(taskID.uuidString), "request": .string("Open Notes"),
                    "status": .string("awaitingAnswer")
                ])]),
                "questions": .array([.object([
                    "id": .string(questionID.uuidString),
                    "question": .string("Which window should I use?"),
                    "task": .string(taskID.uuidString), "revision": .number(1)
                ])])
            ])
            let handoff = try transcriptHandoff("the front window", taskContext: context)
            let agent = CuaTaskAgent(call: { tool, _ in
                XCTAssertEqual(tool, "list_apps")
                return .object(["apps": .array([.object(["name": .string("Notes"), "bundle_id": .string("notes")])])])
            }, judge: { _, questions in
                try self.voiceAnswers(questions, span: "3",
                    task: relationship == "independent" ? "independent" : taskID.uuidString,
                    app: "app_0", relationship: relationship, pendingQuestion: questionID.uuidString)
            })

            let decision = try await agent.decide(handoff: handoff)

            XCTAssertEqual(decision.operation, .clarify,
                "relationship=\(relationship) with a bound question must clarify")
            XCTAssertEqual(decision.clarification, .task)
            XCTAssertNil(decision.questionID)
        }
    }

    func testStructuredRunResultReportsVerifiedEvidence() async throws {
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state":
                return .object(["elements": .array([.object(["role": .string("AXStaticText"), "value": .string("Done")])])])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["next"] != nil {
                return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]), "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        })

        let result = await agent.runStructured(goal: "Check the fixture", context: "", progress: { _ in })

        guard case .verified(let evidence) = result.outcome else {
            XCTFail("Expected a verified outcome, got \(result.outcome)")
            return
        }
        XCTAssertTrue(evidence.contains("Completed in Fixture"), evidence)
        XCTAssertNil(result.decision)
    }

    /// A completion claim is a claim, not proof: when the evidence question
    /// answers unproven twice, the task must fail honestly instead of reporting
    /// completion on action history alone. Each retry must be preceded by a
    /// fresh observation carrying the rejection in history — never a bare
    /// repeat of the same judgment.
    func testDoneClaimRejectedWhenObservedEvidenceDoesNotProveIt() async throws {
        var doneClaims = 0, windowReads = 0, dispatches = 0
        var secondCallSawRejection = false
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state": windowReads += 1; return .object(["elements": .array([])])
            default: dispatches += 1; throw DriverConnectionError.malformed
            }
        }, judge: { state, questions in
            if questions["next"] != nil {
                XCTAssertNotNil(questions["doneEvidence"], "doneEvidence must ride inside the action judgment, not a second call")
                doneClaims += 1
                if doneClaims == 2 {
                    let history = state["history"]?.array ?? []
                    secondCallSawRejection = history.contains {
                        $0["observation"]?.string?.contains("completion claim was rejected") == true
                    }
                }
                return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]),
                        "doneEvidence": .choice(choice: "unproven", confidence: 1, probabilities: ["unproven": 1])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        })

        let result = await agent.runStructured(goal: "Change the fixture state", context: "", progress: { _ in })

        XCTAssertEqual(doneClaims, 2, "A rejected completion claim must be verified again before failing")
        XCTAssertTrue(secondCallSawRejection, "The retry must be decided on a fresh observation that records the rejection")
        XCTAssertGreaterThanOrEqual(windowReads, 2, "Each retried judgment must be preceded by a fresh window observation")
        XCTAssertEqual(dispatches, 0, "No action may be dispatched while a completion claim is being rejected")
        guard case .blocked(let message) = result.outcome else {
            XCTFail("An unproven completion claim must not report success, got \(result.outcome)")
            return
        }
        XCTAssertTrue(message.contains("could not be proven"), message)
    }

    /// A proven completion must cost ONE judgment call: `doneEvidence` is an
    /// answer in the same request that produces `next`, never a follow-up
    /// choose-then-verify pair on the same observation.
    func testProvenDoneClaimCostsOneJudgmentCall() async throws {
        var nextJudgments = 0, standaloneEvidenceCalls = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state": return .object(["elements": .array([])])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["next"] != nil {
                nextJudgments += 1
                XCTAssertNotNil(questions["doneEvidence"], "The completion judgment must accompany the action judgment")
                return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]),
                        "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])]
            }
            if questions["doneEvidence"] != nil { standaloneEvidenceCalls += 1 }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        })

        let result = await agent.runStructured(goal: "Check the fixture state", context: "", progress: { _ in })

        XCTAssertEqual(nextJudgments, 1, "A proven done claim must be decided in a single judgment call")
        XCTAssertEqual(standaloneEvidenceCalls, 0, "Completion evidence must never be a separate serial call")
        guard case .verified = result.outcome else {
            XCTFail("A proven completion claim must complete, got \(result.outcome)")
            return
        }
    }

    /// A `done` answer with no evidence answer at all is unproven by default —
    /// an absent or unreadable evidence answer can never be a pass.
    func testDoneClaimWithMissingEvidenceAnswerIsNotSuccess() async throws {
        var doneClaims = 0, dispatches = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree": return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows": return .object(["windows": .array([.object(["window_id": .number(7)])])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            case "get_window_state": return .object(["elements": .array([])])
            default: dispatches += 1; throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["next"] != nil {
                doneClaims += 1
                return ["next": .choice(choice: "done", confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        })

        let result = await agent.runStructured(goal: "Change the fixture state", context: "", progress: { _ in })

        XCTAssertEqual(doneClaims, 2, "A missing evidence answer is unproven; the claim is retried once then refused")
        XCTAssertEqual(dispatches, 0)
        guard case .blocked(let message) = result.outcome, message.contains("could not be proven") else {
            XCTFail("An unanswered evidence question must not report success, got \(result.outcome)")
            return
        }
    }

    func testStructuredOutcomesClassifyExecutorFailuresWithoutThrowing() async throws {
        let cases: [(Error, CuaTaskExecutionOutcome)] = [
            (CuaUncertainOutcome(tool: "click", result: .object([:])),
             .uncertain("Cua reported a partial or uncertain outcome for click. An effect may have occurred; inspect the target before retrying.")),
            (DriverConnectionError.timedOut,
             .uncertain("Cua timed out. A dispatched action may have completed; inspect before retrying.")),
            (DriverConnectionError.unavailable,
             .blocked("Install Cua Driver in Applications before connecting.")),
            (DriverConnectionError.malformed,
             .failed("Cua returned an invalid response. No action will be replayed.")),
            (DriverConnectionError.toolRefused(tool: "click", code: "denied"),
             .failed("Cua could not complete click (denied). Inspect the target before retrying.")),
            (DriverConnectionError.refused("Which assistant task do you mean?"),
             .clarification(.task, "Which assistant task do you mean?")),
            (DriverConnectionError.refused("Which window should I use?"),
             .targetAmbiguous("Which window should I use?")),
        ]
        for (error, expected) in cases {
            let agent = CuaTaskAgent(call: { _, _ in throw error }, judge: { _, _ in [:] })
            let result = await agent.runStructured(goal: "do something", context: "", progress: { _ in })
            XCTAssertEqual(result.outcome, expected, "for \(error)")
        }
    }

    func testStructuredResultReportsCancellationAsBlockedWithoutThrowing() async throws {
        let agent = CuaTaskAgent(call: { _, _ in throw CancellationError() }, judge: { _, _ in [:] })
        let result = await agent.runStructured(goal: "do something", context: "", progress: { _ in })
        XCTAssertEqual(result.outcome, .blocked("The task was cancelled before a verified executor outcome."))
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
            case "invoke_menu", "hotkey":
                // Either create mechanism satisfies the request: a picked
                // File → New menu item or the deterministic ⌘N chord.
                createdWindow = true
                return .object(["status": .string("invoked"), "resolved_path": args["path"] ?? .null])
            case "type_text":
                typed = args["text"]?.string ?? ""
                XCTAssertEqual(typed, "Copper lantern,", "The selected literal span must reach the selected CUA text action exactly")
                return .object([:])
            case "click", "press_key":
                // Either submission mechanism satisfies "submit it": a picked
                // Submit-button click or the deterministic post-typing Return.
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
                if !createdWindow, let item = choices.first(where: { $0.value == "Press cmd+n" }) {
                    return ["next": .choice(choice: item.key, confidence: 1, probabilities: [item.key: 1])]
                }
                if createdWindow, typed.isEmpty, let item = choices.first(where: { $0.value?.contains("Type the supplied text") == true }) {
                    return ["next": .choice(choice: item.key, confidence: 1, probabilities: [item.key: 1])]
                }
                if !typed.isEmpty, !submitted, let item = choices.first(where: { $0.value?.contains("Click AXButton") == true }) {
                    return ["next": .choice(choice: item.key, confidence: 1, probabilities: [item.key: 1])]
                }
                return ["next": .choice(choice: "done", confidence: 1, probabilities: ["done": 1]),
                        "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])]
            }
            if questions["risk"] != nil {
                let newWindow = state["request"] != nil && !createdWindow
                return ["risk": .choice(choice: "ordinary", confidence: 1, probabilities: [:]),
                        "windowEffect": .choice(choice: newWindow ? "new" : "same", confidence: 1, probabilities: [:])]
            }
            throw DriverConnectionError.malformed
        }, approve: { _ in true })

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
                if clicks > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]), "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])] }
                guard case let .choice(_, choices) = questions["next"] else { throw DriverConnectionError.malformed }
                let choice = try XCTUnwrap(choices.first { $0.value == "Click AXButton \"Search\"" }?.key)
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

        XCTAssertEqual(decisionCalls, 3, "A benign action dispatches from the choose call alone; no separate risk judgment is needed")
        XCTAssertEqual(clicks, 1)
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
                let value = key == "visibility" ? "background" : key == "app" ? "app_0" : key == "scope" ? "launch" : key == "next" ? "done" : key == "doneEvidence" ? "proven" : "ordinary"
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
        catch { XCTAssertTrue(error.localizedDescription.contains("launch remains uncertain"), error.localizedDescription) }
        XCTAssertEqual(mutations, 1)
    }
    func testQueuedLaunchReobservesAndCannotClaimAnotherTasksProcess() async throws {
        var running = false, launches = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            if tool == "launch_app" { launches += 1; throw DriverConnectionError.malformed }
            if tool == "list_windows" { return .object(["windows": .array([])]) }
            XCTAssertTrue(["list_apps", "get_accessibility_tree"].contains(tool))
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(running ? 42 : 0), "running": .bool(running)])])])
        }, judge: { _, _ in ["visibility": .choice(choice: "background", confidence: 1, probabilities: [:]), "app": .choice(choice: "app_0", confidence: 1, probabilities: [:]), "scope": .choice(choice: "launch", confidence: 1, probabilities: [:])] })
        _ = try await agent.run(goal: "open Fixture", context: "", acquireApp: { _ in running = true }, progress: { _ in })
        XCTAssertEqual(launches, 0)
        XCTAssertNil(agent.launchedPID)
        XCTAssertNil(agent.launchReceipt)
    }

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
                if keyCalls > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]), "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])] }
                XCTAssertFalse(criteria.values.compactMap { $0 }.contains { $0.hasPrefix("Type the supplied text") })
                let key = try XCTUnwrap(criteria.first { $0.value == "Press return" }?.key)
                return ["next": .choice(choice: key, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)

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
                    return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]), "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])]
                }
                let mutation = try XCTUnwrap(choices.first {
                    $0.value?.hasPrefix("Press ") == true
                        || $0.value?.hasPrefix("Type the supplied text") == true
                }?.key)
                return ["next": .choice(choice: mutation, confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)

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
        })

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
                if mutations > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]), "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])] }
                guard case let .choice(_, criteria) = questions["next"] else { throw DriverConnectionError.malformed }
                let candidate = try XCTUnwrap(criteria.first { $0.value == "Type the supplied text into AXTextArea \"Body\"" }?.key)
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
                if mutations > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]), "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])] }
                let id = try XCTUnwrap(criteria.first { $0.value == "Type the supplied text into AXTextArea \"Body\"" }?.key)
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
                if mutations > 0 { return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]), "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])] }
                let action = try XCTUnwrap(choices.first { $0.value == "Type the supplied text into AXTextArea \"Body\"" }?.key)
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




    func testExactQuotedTextRequiresOneUnambiguousClosedPair() {
        XCTAssertEqual(CuaTaskAgent.exactQuotedText(in: "Type exactly \" copper lantern. \" into the field."), " copper lantern. ")
        XCTAssertEqual(CuaTaskAgent.exactQuotedText(in: "Type exactly “copper lantern” into the field."), "copper lantern")
        XCTAssertNil(CuaTaskAgent.exactQuotedText(in: "Type \"one\" then \"two\"."))
        XCTAssertNil(CuaTaskAgent.exactQuotedText(in: "Type exactly \"unfinished into the field."))
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
                // Create scope suppresses insertion into a pre-existing
                // window at offer time — the model cannot even pick it, so a
                // stray choice can never reach the dispatch gate.
                XCTAssertNil(criteria.first { $0.value == "Type the supplied text into AXTextArea \"Existing document\"" },
                             "Create scope must not offer typing into a pre-existing window")
                return ["next": .choice(choice: "stuck", confidence: 1, probabilities: [:]),
                        "doneEvidence": .choice(choice: "unproven", confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "create", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: 7)

        do {
            _ = try await agent.run(goal: "Create a new document and insert exactly \"new content\".", context: "", progress: { _ in })
            XCTFail("Create must refuse rather than type into the existing window")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be completed")
                          || error.localizedDescription.contains("could not be proven"),
                          error.localizedDescription)
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
                return ["next": .choice(choice: "done", confidence: 1, probabilities: [:]), "doneEvidence": .choice(choice: "proven", confidence: 1, probabilities: ["proven": 1])]
            }
            let candidate = try XCTUnwrap(choices.first { $0.value?.hasPrefix("Navigate the tab to ") == true }?.key)
            return ["next": .choice(choice: candidate, confidence: 1, probabilities: [:])]
        }, approve: { message in
            approvals.append(message)
            return true
        })

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
                return ["next": .choice(choice: "stuck", confidence: 1, probabilities: [:])]
            }
            throw DriverConnectionError.malformed
        }, approve: { _ in true })

        do {
            _ = try await agent.run(goal: "Inspect the current page in Chrome.", context: "", progress: { _ in })
            XCTFail("The fixture has no safe page action")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not be completed"), error.localizedDescription)
        }

        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(agent.launchedPID, 43)
        XCTAssertEqual(agent.launchReceipt?.pid, 43)
        XCTAssertEqual(agent.launchReceipt?.window, 9)
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
        }, approve: { _ in false })

        do {
            _ = try await agent.run(goal: "Open \"https://example.invalid/\"", context: "", progress: { _ in })
            XCTFail("Denied browser preparation must stop the request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Approve a new isolated browser profile"))
        }
        XCTAssertEqual(prepareCalls, 0)
        XCTAssertEqual(actionCalls, 0)
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
                return ["window": .choice(choice: "w7", confidence: 1, probabilities: [:])]
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


    func testStructuredRunResultPreservesPartialEvidence() async throws {
        let agent = CuaTaskAgent(call: { _, _ in
            throw DriverConnectionError.refused("Incomplete evidence: could not confirm the click result.")
        }, judge: { _, _ in [:] })

        let result = await agent.runStructured(goal: "Click the visible button", context: "", progress: { _ in })

        XCTAssertEqual(result.outcome, .partial(evidence: "Incomplete evidence: could not confirm the click result.", blockedReason: "Incomplete evidence: could not confirm the click result."))
    }

    /// A remembered window id is a preference, never execution authority. When
    /// the pinned window is absent from the target app's fresh window list the
    /// run refuses instead of substituting another window, and no mutation tool
    /// is ever dispatched.
    func testStalePinnedWindowIsRefusedWithoutSubstitution() async throws {
        var calls: [String] = []
        var decision = CuaExecutorDecision(operation: .execute, consumedRange: 0..<2,
            request: "type into the window", replacementRequest: nil, selectedTaskID: nil,
            dependencyTaskID: nil, appName: "Fixture", bundleID: "fixture",
            scope: "work", visibility: "background", literalText: nil)
        decision.targetPreference = CuaTargetPreference(appName: "Fixture", bundleID: "fixture",
            windowID: 9, windowTitle: "Old window", provenance: .retained)
        let agent = CuaTaskAgent(call: { tool, _ in
            calls.append(tool)
            switch tool {
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"),
                    "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Fixture")])])])
            default:
                return .object([:])
            }
        }, judge: { _, _ in [:] })

        let result = await agent.executeStructured(decision, context: "", progress: { _ in })

        guard case .blocked(let message) = result.outcome else {
            return XCTFail("A stale pinned window must refuse, not substitute: \(result.outcome)")
        }
        XCTAssertTrue(message.contains("pinned target window closed"), message)
        let mutations = calls.filter { !["get_accessibility_tree", "list_windows", "get_window_state",
            "list_apps", "check_permissions", "get_browser_state"].contains($0) }
        XCTAssertTrue(mutations.isEmpty,
            "A stale pinned target refuses before any mutation dispatch: \(mutations)")
    }

    /// A retained target preference bound to a different app than the decision
    /// contradicts the contract: the run refuses before any Driver call rather
    /// than applying the remembered target to the wrong app.
    func testRetainedTargetBoundToAnotherAppIsRefusedBeforeDispatch() async throws {
        var calls = 0
        var decision = CuaExecutorDecision(operation: .execute, consumedRange: 0..<2,
            request: "use it", replacementRequest: nil, selectedTaskID: nil, dependencyTaskID: nil,
            appName: "Fixture", bundleID: "fixture", scope: "work",
            visibility: "background", literalText: nil)
        decision.targetPreference = CuaTargetPreference(appName: "Other", bundleID: "other.bundle",
            windowID: 7, provenance: .retained)
        let agent = CuaTaskAgent(call: { _, _ in
            calls += 1
            return .object([:])
        }, judge: { _, _ in [:] })

        let result = await agent.executeStructured(decision, context: "", progress: { _ in })

        guard case .blocked(let message) = result.outcome else {
            return XCTFail("A mismatched retained target must refuse: \(result.outcome)")
        }
        XCTAssertTrue(message.contains("no longer matches"), message)
        XCTAssertEqual(calls, 0, "The wrong-app target is rejected before any Driver call")
    }

    // MARK: - Fast lane (deterministic one-shot primitives)

    /// The fast-lane table matches only whole-phrase known commands plus an
    /// optional trailing app qualifier; anything else is nil and stays in the
    /// agent loop.
    func testFastLaneParsesOnlyWholePhraseKnownCommands() {
        guard let newTab = CuaFastAction.parse("open a new tab in chrome") else {
            return XCTFail("a whole-phrase new-tab request must parse")
        }
        XCTAssertEqual(newTab.appQualifier, "chrome")
        guard case .hotkey(let keys, _) = newTab.action.body else {
            return XCTFail("new tab must resolve to a hotkey body")
        }
        XCTAssertEqual(keys, ["cmd", "t"])
        XCTAssertEqual(newTab.action.effect, .tabsDelta(1))

        XCTAssertNil(CuaFastAction.parse("close the tab"), "close is deliberately not a fast primitive")
        XCTAssertNil(CuaFastAction.parse("open a new tab and then close it"), "multi-step stays in the loop")
        XCTAssertNil(CuaFastAction.parse("don't open a new tab"), "negated commands never dispatch")
        XCTAssertNil(CuaFastAction.parse("tell me about new tabs"), "conversational mentions stay in the loop")
        XCTAssertNil(CuaFastAction.parse("new"))
        XCTAssertNil(CuaFastAction.parse("open a new"), "truncated phrases never dispatch")
    }

    /// The lane is not browser-only: generic window chords and single-key
    /// presses run on any app, while destructive or risk-keyword phrases stay
    /// in the agent loop where judgment applies.
    func testFastLaneGenericCommandsParseForAnyApp() {
        guard let minimize = CuaFastAction.parse("minimize window") else {
            return XCTFail("minimize must parse")
        }
        XCTAssertFalse(minimize.action.needsTabbableApp, "⌘M is a generic chord")
        guard case .hotkey(let minimizeKeys, _) = minimize.action.body else { return XCTFail("minimize is a hotkey") }
        XCTAssertEqual(minimizeKeys, ["cmd", "m"])
        XCTAssertEqual(minimize.action.effect, .windowOffScreen)

        guard let newWindow = CuaFastAction.parse("open a new window") else {
            return XCTFail("new window must parse")
        }
        XCTAssertFalse(newWindow.action.needsTabbableApp, "⌘N is a generic chord, not browser-only")

        guard let enter = CuaFastAction.parse("press enter") else {
            return XCTFail("press enter must parse")
        }
        XCTAssertFalse(enter.action.needsTabbableApp)
        guard case .hotkey(let enterKeys, _) = enter.action.body else { return XCTFail() }
        XCTAssertEqual(enterKeys, ["return"])
        XCTAssertEqual(enter.action.effect, .delivered)

        // Destructive/risk-keyword phrases never reach the lane ungated.
        XCTAssertNil(CuaFastAction.parse("press delete"))
        XCTAssertNil(CuaFastAction.parse("press backspace"))
        XCTAssertNil(CuaFastAction.parse("close window"))
        // App-qualified quit parses, but only as a self-approving verb — the
        // lane asks explicitly rather than letting a model pick a menu item.
        guard let quit = CuaFastAction.parse("quit chrome") else {
            return XCTFail("quit <app> must parse")
        }
        guard case .appControl(.quit) = quit.action.body else {
            return XCTFail("quit <app> is an app verb, not a hotkey")
        }
        XCTAssertEqual(quit.appQualifier, "chrome")
        XCTAssertTrue(quit.action.selfApproves, "quit asks for approval in the lane")
        XCTAssertNil(CuaFastAction.parse("press enter to send it"),
                     "a confirm key inside a send request keeps the loop's risk judgment")
        XCTAssertNil(CuaFastAction.match(goal: "type delete", bundle: "fixture.notes", appName: "Fixture Notes"),
                     "a payload carrying a risk keyword keeps the per-action judgment")
        XCTAssertNotNil(CuaFastAction.match(goal: "minimize window", bundle: "fixture.notes", appName: "Fixture Notes"),
                        "generic chords match non-tabbable bundles")
        XCTAssertNil(CuaFastAction.match(goal: "new tab", bundle: "fixture.notes", appName: "Fixture Notes"),
                     "browser-chrome chords still refuse non-tabbable apps")
    }

    /// Generic window chords run on non-browser apps end to end: "minimize
    /// window" dispatches ⌘M window-scoped to the resolved app and verifies
    /// the window left the screen — zero model calls.
    func testFastLaneMinimizeWindowWorksOnANonBrowserApp() async throws {
        var hotkeyArgs: [String: JSONValue]?
        var minimized = false
        var judgeCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture Notes"),
                    "bundle_id": .string("fixture.notes"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Note"), "is_on_screen": .bool(!minimized), "z_index": .number(0)])])])
            case "get_window_state":
                return .object(["elements": .array([])])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            case "hotkey":
                hotkeyArgs = args
                minimized = true
                return .object(["delivery": .string("background")])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            judgeCalls += 1
            return [:]
        }, windowID: nil)

        let result = try await agent.run(goal: "Minimize the window in fixture notes", context: "", progress: { _ in })

        XCTAssertEqual(judgeCalls, 0)
        XCTAssertEqual(hotkeyArgs?["keys"], .array([.string("cmd"), .string("m")]))
        XCTAssertEqual(hotkeyArgs?["target"]?["window_id"], .number(7))
        XCTAssertTrue(result.contains("Minimized the window"), result)
    }

    /// "press enter" dispatches the single key window-scoped with a
    /// driver-confirmed delivery as the honest postcondition.
    func testFastLanePressEnterDeliversASingleKey() async throws {
        var hotkeyArgs: [String: JSONValue]?
        var judgeCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture Notes"),
                    "bundle_id": .string("fixture.notes"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Note"), "is_on_screen": .bool(true), "z_index": .number(0)])])])
            case "get_window_state":
                return .object(["elements": .array([])])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            case "hotkey":
                hotkeyArgs = args
                return .object(["delivery": .string("background")])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            judgeCalls += 1
            return [:]
        }, windowID: nil)

        let result = try await agent.run(goal: "Press enter in fixture notes", context: "", progress: { _ in })

        XCTAssertEqual(judgeCalls, 0)
        XCTAssertEqual(hotkeyArgs?["keys"], .array([.string("return")]))
        XCTAssertEqual(hotkeyArgs?["target"]?["window_id"], .number(7))
        XCTAssertTrue(result.contains("Pressed Return"), result)
    }

    /// ⌃⌘F toggles — "exit full screen" on a window that does not cover the
    /// screen would ENTER instead. The lane abstains; nothing is dispatched.
    func testFastLaneExitFullScreenOnlyDispatchesFromACoveringWindow() async throws {
        var dispatched = false
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture Notes"),
                    "bundle_id": .string("fixture.notes"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Note"), "is_on_screen": .bool(true),
                    "bounds": .object(["x": .number(10), "y": .number(40),
                                      "width": .number(800), "height": .number(600)])])])])
            case "get_window_state": return .object(["elements": .array([])])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            case "hotkey":
                dispatched = true
                return .object([:])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            if questions["next"] != nil {
                return ["next": .choice(choice: "stuck", confidence: 1, probabilities: [:]),
                        "doneEvidence": .choice(choice: "unproven", confidence: 1, probabilities: [:])]
            }
            return ["app": .choice(choice: "app_0", confidence: 1, probabilities: [:]),
                    "scope": .choice(choice: "work", confidence: 1, probabilities: [:]),
                    "visibility": .choice(choice: "background", confidence: 1, probabilities: [:])]
        }, windowID: nil)

        _ = try? await agent.run(goal: "Exit full screen in fixture notes", context: "", progress: { _ in })

        XCTAssertFalse(dispatched, "⌃⌘F on a non-fullscreen window would ENTER it — abstain, never invert the request")
    }

    /// Typed payloads keep their original casing and punctuation — "type" is
    /// literal insertion, so the normalized command form must not leak in.
    func testFastLaneTypePreservesTheLiteralPayload() {
        guard let typed = CuaFastAction.parse("Type Hello, World! in Notes") else {
            return XCTFail("a type command must parse")
        }
        guard case .type(let payload) = typed.action.body else {
            return XCTFail("type must produce a text body")
        }
        XCTAssertEqual(payload, "Hello, World!")
        XCTAssertEqual(typed.appQualifier, "notes")

        guard case .type(let quoted) = CuaFastAction.parse("type \"quoted, text\"")?.action.body else {
            return XCTFail("quoted payloads must parse")
        }
        XCTAssertEqual(quoted, "quoted, text")
        guard case .type(let plain) = CuaFastAction.parse("type the word hello")?.action.body else {
            return XCTFail("type the word must parse")
        }
        XCTAssertEqual(plain, "hello")

        XCTAssertNil(CuaFastAction.parse("type"), "an empty payload never dispatches")
        XCTAssertNil(CuaFastAction.parse("don't type anything"), "negated typing never dispatches")
        XCTAssertFalse(CuaFastAction.parse("type log in")?.appQualifier != nil,
                       "a payload-internal preposition is not an app qualifier")
    }

    /// A final transcript whose pending span is exactly one known primitive
    /// resolves without any Jev call — the deterministic decision matches what
    /// the battery would produce.
    func testFinalFastSpanDecidesWithoutAJevCall() async throws {
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 2, text: "open a new tab in google chrome", isFinal: true))
        let handoff = TranscriptHandoff(id: UUID(), captureID: UUID(), revision: audio.revision,
            transcript: "open a new tab in google chrome", pendingWordStart: 0, pendingWordEnd: 7,
            final: true, receivedAt: 123.5, audioRanges: audio.segments, taskContext: .object([:]))
        var judgeCalls = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            guard tool == "list_apps" else { throw DriverConnectionError.malformed }
            return .object(["apps": .array([.object(["name": .string("Google Chrome"),
                "bundle_id": .string("com.google.Chrome"), "pid": .number(42)])])])
        }, judge: { _, _ in
            judgeCalls += 1
            return [:]
        })

        let decision = try await agent.decide(handoff: handoff)

        XCTAssertEqual(judgeCalls, 0, "a whole-phrase fast primitive must not invoke the model")
        XCTAssertEqual(decision.operation, .execute)
        XCTAssertEqual(decision.bundleID, "com.google.Chrome")
        XCTAssertEqual(decision.consumedRange, 0..<7)
        XCTAssertEqual(decision.request, "open a new tab in google chrome")
        XCTAssertNil(decision.literalText)
        XCTAssertEqual(decision.contentMode, .control)
    }

    /// Non-final utterances and spans that are not whole primitives keep the
    /// ordinary Jev battery — the lane never guesses.
    func testNonFinalOrNonPrimitiveSpanStillUsesTheDecisionBattery() async throws {
        var judgeCalls = 0
        let apps: JSONValue = .object(["apps": .array([.object(["name": .string("Google Chrome"),
            "bundle_id": .string("com.google.Chrome"), "pid": .number(42)])])])

        // "close it" multi-step span still needs the battery even when final.
        var audio = RangedTranscript()
        try audio.apply(.init(start: 0, end: 2, text: "open a new tab and close it", isFinal: true))
        var handoff = TranscriptHandoff(id: UUID(), captureID: UUID(), revision: audio.revision,
            transcript: "open a new tab and close it", pendingWordStart: 0, pendingWordEnd: 7,
            final: true, receivedAt: 123.5, audioRanges: audio.segments, taskContext: .object([:]))
        var agent = CuaTaskAgent(call: { tool, _ in
            guard tool == "list_apps" else { throw DriverConnectionError.malformed }
            return apps
        }, judge: { _, questions in
            judgeCalls += 1
            return try self.voiceAnswers(questions)
        })
        _ = try await agent.decide(handoff: handoff)
        XCTAssertEqual(judgeCalls, 1, "a multi-step span must use the battery")

        // The same primitive phrasing on a non-final partial stays in the battery.
        judgeCalls = 0
        handoff = TranscriptHandoff(id: UUID(), captureID: UUID(), revision: audio.revision,
            transcript: "open a new tab in google chrome", pendingWordStart: 0, pendingWordEnd: 7,
            final: false, receivedAt: 123.5, audioRanges: audio.segments, taskContext: .object([:]))
        agent = CuaTaskAgent(call: { tool, _ in
            guard tool == "list_apps" else { throw DriverConnectionError.malformed }
            return apps
        }, judge: { _, questions in
            judgeCalls += 1
            return try self.voiceAnswers(questions)
        })
        _ = try await agent.decide(handoff: handoff)
        XCTAssertEqual(judgeCalls, 1, "a still-growing utterance must not fast-lane")
    }

    /// End to end through run(): the fast lane resolves the app, waits for the
    /// window, sends a window-scoped ⌘T, and proves the tab delta — all with
    /// zero model calls and no click dispatch.
    func testFastLaneNewTabDispatchesWindowScopedHotkeyWithObservedDelta() async throws {
        var calls: [String] = []
        var hotkeyArgs: [String: JSONValue]?
        var tabCount = 2
        var judgeCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            calls.append(tool)
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Google Chrome"),
                    "bundle_id": .string("com.google.Chrome"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Example"), "is_on_screen": .bool(true), "z_index": .number(0)])])])
            case "get_window_state":
                // Real-Chrome shape: browser tabs are AXRadioButton directly
                // under AXWindow; the AXTabGroup under AXWebArea is in-page
                // content and must not count.
                var elements: [JSONValue] = (0..<tabCount).map { i in
                    .object(["element_index": .number(Double(i)), "role": .string("AXRadioButton"),
                             "label": .string("Tab \(i)"), "element_token": .string("tab-\(i)"),
                             "parent_index": .number(90)])
                }
                elements.append(.object(["element_index": .number(90), "role": .string("AXWindow")]))
                elements.append(.object(["element_index": .number(91), "role": .string("AXWebArea"),
                                         "parent_index": .number(90)]))
                elements.append(.object(["element_index": .number(92), "role": .string("AXRadioButton"),
                                         "label": .string("Page tab"), "element_token": .string("page-tab"),
                                         "parent_index": .number(91)]))
                return .object(["elements": .array(elements)])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            case "hotkey":
                hotkeyArgs = args
                tabCount += 1
                return .object(["effect": .string("unverifiable"), "delivery": .string("background")])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            judgeCalls += 1
            return [:]
        }, windowID: nil)

        let result = try await agent.run(goal: "Open a new tab in Chrome", context: "", progress: { _ in })

        XCTAssertEqual(judgeCalls, 0, "the deterministic lane runs no model calls")
        XCTAssertEqual(hotkeyArgs?["keys"], .array([.string("cmd"), .string("t")]))
        XCTAssertEqual(hotkeyArgs?["target"]?["kind"], .string("window"))
        XCTAssertEqual(hotkeyArgs?["target"]?["window_id"], .number(7))
        XCTAssertTrue(result.contains("Opened a new tab"), result)
        XCTAssertFalse(calls.contains("click"), "the lane uses the keystroke primitive, never blind clicks")
    }

    /// "type X" dispatches element-scoped type_text only when the window has
    /// exactly one editable element; the typed value delta is the evidence.
    func testFastLaneTypeUsesTheSingleEditableElement() async throws {
        var typeArgs: [String: JSONValue]?
        var typed = false
        let agent = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture Notes"),
                    "bundle_id": .string("fixture.notes"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Note"), "is_on_screen": .bool(true)])])])
            case "get_window_state":
                return .object(["elements": .array([
                    .object(["element_index": .number(0), "role": .string("AXTextArea"),
                             "label": .string("Body"), "element_token": .string("field-0"),
                             "enabled": .bool(true),
                             "value": .string(typed ? "Hello, World!" : "")])])])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            case "type_text":
                typeArgs = args
                typed = true
                return .object(["delivery": .string("confirmed")])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            XCTFail("the type lane must not invoke the model")
            return [:]
        }, windowID: nil)

        let result = try await agent.run(goal: "Type Hello, World! in fixture notes", context: "", progress: { _ in })

        XCTAssertEqual(typeArgs?["text"], .string("Hello, World!"))
        XCTAssertEqual(typeArgs?["element_token"], .string("field-0"))
        XCTAssertTrue(result.contains("Typed the text"), result)
    }

    /// Two editable fields make "type X" ambiguous — the deterministic lane
    /// abstains (no type_text dispatch) and the request falls into the agent
    /// loop, which owns field disambiguation. The mock judge cannot ground a
    /// target, so the loop refuses without any mutation.
    func testFastLaneTypeFallsThroughWhenTheEditableTargetIsAmbiguous() async throws {
        var dispatched = false
        var judgeCalls = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture Notes"),
                    "bundle_id": .string("fixture.notes"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Note"), "is_on_screen": .bool(true)])])])
            case "get_window_state":
                return .object(["elements": .array((0..<2).map { i in
                    .object(["element_index": .number(Double(i)), "role": .string("AXTextField"),
                             "label": .string("Field \(i)"), "element_token": .string("field-\(i)"),
                             "enabled": .bool(true)])
                })])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            case "type_text", "hotkey", "click":
                dispatched = true
                return .object([:])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, questions in
            judgeCalls += 1
            if questions["next"] != nil {
                return ["next": .choice(choice: "stuck", confidence: 1, probabilities: [:])]
            }
            return [:]
        }, windowID: nil)

        _ = try? await agent.run(goal: "Type hello in fixture notes", context: "", progress: { _ in })

        XCTAssertFalse(dispatched, "an ambiguous editable target must never receive blind text")
        XCTAssertGreaterThan(judgeCalls, 0, "ambiguity belongs to the agent loop, not the lane")
    }

    /// A bare "open X" runs launch/raise directly — no Jev calls, no agent
    /// loop iterations; the observed running process plus a verified front
    /// window is the evidence.
    func testFastLaneOpenBringsRunningAppToFrontWithoutModelCalls() async throws {
        var calls: [String] = []
        var judgeCalls = 0
        let agent = CuaTaskAgent(call: { tool, args in
            calls.append(tool)
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"),
                    "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Fixture"), "is_on_screen": .bool(true)])])])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            judgeCalls += 1
            return [:]
        }, windowID: nil)

        let result = try await agent.run(goal: "Open Fixture", context: "", progress: { _ in })

        XCTAssertEqual(judgeCalls, 0)
        XCTAssertTrue(result.contains("verified its window in front"), result)
        XCTAssertEqual(calls.filter { !["list_apps", "get_accessibility_tree", "list_windows",
            "bring_to_front"].contains($0) }, [], "open lane must not dispatch anything else")
    }

    /// "open X" for a not-running app launches it once and returns on the
    /// observed running process — no loop, no model calls.
    func testFastLaneOpenLaunchesOnceAndReturnsOnObservedRunning() async throws {
        var launchCalls = 0
        var running = false
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([.object(["name": .string("Fixture"),
                    "bundle_id": .string("fixture"), "pid": .number(running ? 42 : 0)])])])
            case "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"),
                    "bundle_id": .string("fixture"), "pid": .number(running ? 42 : 0)])])])
            case "launch_app":
                launchCalls += 1
                running = true
                return .object(["pid": .number(42)])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Fixture"), "is_on_screen": .bool(true)])])])
            case "bring_to_front":
                return .object(["activated": .bool(true),
                                "exact_window_effect": .object(["verified": .bool(true)])])
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            XCTFail("a bare open command must not invoke the model")
            return [:]
        }, windowID: nil)

        let result = try await agent.run(goal: "Open Fixture", context: "", progress: { _ in })

        XCTAssertEqual(launchCalls, 1, "launch exactly once, never replayed")
        XCTAssertTrue(result.contains("verified its window in front"), result)
    }

    /// "open X" must not report success when the raise cannot be verified —
    /// an app left behind another window is not what was asked. The lane
    /// retries the raise once for the just-launched race, then refuses.
    func testFastLaneOpenRetriesRaiseThenRefusesWhenUnverified() async throws {
        var raiseCalls = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"),
                    "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Fixture"), "is_on_screen": .bool(true)])])])
            case "bring_to_front":
                raiseCalls += 1
                return .object(["activated": .bool(false),
                                "exact_window_effect": .object(["verified": .bool(false)])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            XCTFail("a bare open command must not invoke the model")
            return [:]
        }, windowID: nil)

        do {
            _ = try await agent.run(goal: "Open Fixture", context: "", progress: { _ in })
            XCTFail("an unverified raise must not report success")
        } catch {
            XCTAssertTrue(error is DriverConnectionError)
        }
        XCTAssertEqual(raiseCalls, 2, "one settle-and-retry covers the window materializing late")
    }

    /// The retry is not cosmetic: a raise that verifies on the second attempt
    /// completes as opened-in-front.
    func testFastLaneOpenCompletesWhenRaiseVerifiesOnRetry() async throws {
        var raiseCalls = 0
        let agent = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([.object(["name": .string("Fixture"),
                    "bundle_id": .string("fixture"), "pid": .number(42)])])])
            case "list_windows":
                return .object(["windows": .array([.object(["window_id": .number(7),
                    "title": .string("Fixture"), "is_on_screen": .bool(true)])])])
            case "bring_to_front":
                raiseCalls += 1
                let verified = raiseCalls > 1
                return .object(["activated": .bool(verified),
                                "exact_window_effect": .object(["verified": .bool(verified)])])
            case "get_browser_state": throw DriverConnectionError.toolRefused(tool: tool, code: "browser_route_unavailable")
            default: throw DriverConnectionError.malformed
            }
        }, judge: { _, _ in
            XCTFail("a bare open command must not invoke the model")
            return [:]
        }, windowID: nil)

        let result = try await agent.run(goal: "Open Fixture", context: "", progress: { _ in })

        XCTAssertEqual(raiseCalls, 2)
        XCTAssertTrue(result.contains("verified its window in front"), result)
    }

    /// A window whose only semantic surface is buttons — nothing carries a
    /// readable value, so no observed state can prove an outcome — still
    /// offers OCR as the read path. This is the Calculator case: withholding
    /// inspectVisual there forced the model to guess a button (it pressed
    /// "All Clear" on a live result). When a value-bearing element exists,
    /// semantic evidence suffices and OCR stays closed. The judge answers the
    /// app-resolution battery so the run really reaches the action choices —
    /// a vacuous pass is not a test of the gate.
}
