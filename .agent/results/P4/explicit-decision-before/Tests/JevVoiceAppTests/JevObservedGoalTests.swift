import CoreGraphics
import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

final class JevObservedGoalTests: XCTestCase {
    func testNativeHierarchyChangeInvalidatesFreshProofWithoutChangingFieldValue() throws {
        let window = JevVoice.WindowRef(pid: 7, windowID: 42)
        let element = AXElement(index: 3, token: nil, role: "AXTextArea", label: "Body",
            value: "owned value", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            actions: [], nativeAncestorRoles: ["AXWindow", "AXScrollArea"])
        let snapshot = AXSnapshot(windowTitle: "Owned", snapshotID: "s1",
            elements: [element], treeMarkdown: "")
        let task = TaskBrief(goal: "Replace Body with owned value", window: window)
        let proof = try XCTUnwrap(ObservedGoalProof(task: task, snapshot: snapshot, factID: "value:0",
            model: "jev-1.14.0", completion: 0.99, selection: 0.99, support: 0.99))
        var fresh = snapshot
        fresh.snapshotID = "s2"
        XCTAssertTrue(proof.matches(task: task, snapshot: fresh))
        fresh.elements[0].nativeAncestorRoles = ["AXWindow", "AXToolbar"]
        XCTAssertFalse(proof.matches(task: task, snapshot: fresh))
        fresh.elements[0].nativeAncestorRoles = nil
        XCTAssertFalse(proof.matches(task: task, snapshot: fresh))
    }

    func testNativeProofRejectsSameTitleDocumentSwitchWithoutWeakeningScores() throws {
        let window = JevVoice.WindowRef(pid: 7, windowID: 42)
        let a = NativeDocumentSubject(window: window, fingerprint: Data(repeating: 1, count: 32))
        let b = NativeDocumentSubject(window: window, fingerprint: Data(repeating: 2, count: 32))
        let element = AXElement(index: 3, token: "native-token", role: "AXTextArea",
            label: "Body", value: "owned value", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            actions: ["AXSetValue"], nativeValue: .init(window: window, document: a))
        let snapshot = AXSnapshot(windowTitle: "Same title", snapshotID: "s1",
            elements: [element], treeMarkdown: "", nativeDocument: a)
        let task = TaskBrief(goal: "Replace Body with owned value", window: window,
                             values: ["text": "owned value"])
        let proof = try XCTUnwrap(ObservedGoalProof(task: task, snapshot: snapshot, factID: "value:0",
            model: "jev-1.14.0", completion: 0.99, selection: 0.99, support: 0.99))
        var fresh = snapshot
        fresh.snapshotID = "s2"
        XCTAssertTrue(proof.matches(task: task, snapshot: fresh))
        fresh.nativeDocument = b
        fresh.elements[0].nativeValue = .init(window: window, document: b)
        XCTAssertFalse(proof.matches(task: task, snapshot: fresh))
        fresh.nativeDocument = nil
        fresh.elements[0].nativeValue = nil
        XCTAssertFalse(proof.matches(task: task, snapshot: fresh))
        for scores in [(0.94, 0.99, 0.99), (0.99, 0.89, 0.99), (0.99, 0.99, 0.89)] {
            XCTAssertNil(ObservedGoalProof(task: task, snapshot: snapshot, factID: "value:0",
                model: "jev-1.14.0", completion: scores.0, selection: scores.1, support: scores.2))
        }
        let state = ObservedGoalProof.choiceState(snapshot: fresh, task: task, originalDocument: a)
        XCTAssertEqual(state["native_document_context"]?["original_known"]?.bool, true)
        XCTAssertEqual(state["native_document_context"]?["current_known"]?.bool, false)
        XCTAssertEqual(state["native_document_context"]?["original_unchanged"]?.bool, false)
    }

    final class Fixture: CaptureSource, @unchecked Sendable {
        var complete = false
        var readCount = 0
        var completeReads = 0
        var effects = 0
        var wrongSubject = false
        var drift = false
        var buttonOnly = false
        var changeSubject = false
        var windows: [JevVoice.WindowRef] = []
        var states: [JSONValue] = []
        var choices: [DriveLoop.JevChoice] = []
        var forgedFact = false
        var cancelSupport = false
        var weakCompletion = false
        var weakRefinedCompletion = false
        var initialFactNone = false
        var focusedGoalCalls = 0
        var focusedFactSelections = 0
        var refinementModel: String? = nil
        let window = JevVoice.WindowRef(pid: 7, windowID: 42)

        func frontmostWindow() async throws -> JevVoice.WindowRef { window }

        func axTree(of window: JevVoice.WindowRef, depth: AXDepth) async throws -> AXSnapshot {
            windows.append(window)
            readCount += 1
            if complete {
                completeReads += 1
                if changeSubject && completeReads >= 2 { wrongSubject = true }
            }
            var elements = [
                AXElement(index: 20, token: nil, role: "AXStaticText",
                          label: wrongSubject ? "Account B" : "Account A", value: nil,
                          frame: .init(x: 10, y: 10, width: 200, height: 20), actions: []),
                AXElement(index: 21, token: nil, role: "AXStaticText",
                          label: drift ? "Tick \(readCount)" : "Setup details", value: nil,
                          frame: nil, actions: []),
            ]
            if complete {
                elements.append(AXElement(index: 22, token: nil,
                    role: buttonOnly ? "AXButton" : "AXStaticText",
                    label: "Setup complete", value: nil, frame: nil, actions: []))
                elements.append(AXElement(index: 23, token: nil, role: "AXSecureTextField",
                    label: "Password", value: "private-sentinel", frame: nil, actions: ["AXPress"]))
            } else {
                elements.append(AXElement(index: 1, token: "continue", role: "AXButton",
                    label: "Continue", value: nil, frame: nil, actions: ["AXPress"]))
            }
            return AXSnapshot(windowTitle: "Owned setup", snapshotID: "capture-\(readCount)",
                              elements: elements, treeMarkdown: "")
        }

        func screenshot(of window: JevVoice.WindowRef?, region: CGRect?) async throws -> CapturedImage {
            throw NSError(domain: "pixels-not-permitted", code: 1)
        }

        func domSnapshot(of window: JevVoice.WindowRef) async throws -> DOMSnapshot {
            DOMSnapshot(url: "", title: "", indexedText: "", elements: [])
        }

        func settled(within timeout: Duration) async -> Bool { true }

        func act(_ request: ActuationRequest) throws -> TaskLoop.ActOutcome {
            guard !complete, request.tool == "click",
                  request.args["pid"] == .number(7),
                  request.args["window_id"] == .number(42),
                  request.args["element_token"]?.string == "continue" else {
                throw NSError(domain: "unexpected-effect", code: 1)
            }
            complete = true
            effects += 1
            return .init(effect: "confirmed", verified: true)
        }

        func infer(state: JSONValue, questions: [String: Question]) async throws -> (SystemOneResponse, Double) {
            states.append(state)
            if questions["goal_complete"] != nil { focusedGoalCalls += 1 }
            if questions["goal_fact"] != nil, state["supported_goal_facts"] != nil {
                focusedFactSelections += 1
            }
            var answers: [String: Any] = [:]
            for (name, question) in questions {
                if case .choice(_, let criteria) = question {
                    let selected: String
                    if name == "goal_fact" {
                        selected = forgedFact ? "not-observed"
                            : initialFactNone && state["supported_goal_facts"] == nil ? "none" : criteria.first {
                            ($0.value ?? "").contains("Setup complete")
                        }?.key ?? "none"
                    } else {
                        selected = !complete && criteria["e1"] != nil ? "e1" : criteria.keys.sorted()[0]
                    }
                    var probabilities = Dictionary(uniqueKeysWithValues: criteria.keys.map { ($0, 0.0) })
                    probabilities[selected] = 1
                    answers[name] = ["type": "choice", "choice": selected,
                                     "confidence": 1.0, "probabilities": probabilities]
                } else {
                    let value: Double
                    switch name {
                    case "done": value = complete ? (weakCompletion ? 0.48 : 0.99) : 0.01
                    case "goal_complete":
                        value = complete && !wrongSubject && !weakRefinedCompletion ? 0.99 : 0.01
                    case "applicable": value = !complete && !wrongSubject ? 0.99 : 0.01
                    case "goal_supported":
                        if cancelSupport { withUnsafeCurrentTask { $0?.cancel() } }
                        value = wrongSubject ? 0.01 : 0.99
                    default:
                        if name.hasPrefix("goal_support_") {
                            value = complete && !wrongSubject
                                && state["goal_refinement_candidates"]?[name]?["observed"]?.string == "Setup complete"
                                ? 0.99 : 0.01
                        } else {
                            value = 0.01
                        }
                    }
                    answers[name] = ["type": "noul", "noul": value]
                }
            }
            let isRefinement = questions["goal_supported"] != nil || questions["goal_complete"] != nil
                || state["supported_goal_facts"] != nil
            let responseModel = isRefinement ? refinementModel ?? "jev-1.14.0" : "jev-1.14.0"
            let data = try JSONSerialization.data(withJSONObject: ["model": responseModel, "answers": answers])
            return (try JSONDecoder().decode(SystemOneResponse.self, from: data), 1)
        }
    }

    func run(_ fixture: Fixture, criteria: [String] = [], model: String = "jev-1.14.0",
             extraState: [String: JSONValue] = [:]) async -> TaskLoopResult {
        let choose = JevChooser.make(model: model, infer: fixture.infer)
        let decider = JevDecider(choose: { state, candidates in
            let choice = try await choose(state, candidates)
            if let choice { fixture.choices.append(choice) }
            return choice
        }, extras: { _ in .init(stateFields: extraState) })
        var config = TaskLoop.Config()
        config.maxRounds = 6
        config.settleReobserves = false
        let loop = TaskLoop(source: fixture, decider: decider, actuate: fixture.act,
                            consent: { _, _ in .allow }, config: config)
        return await loop.run(TaskBrief(goal: "Finish setup for Account A", successContains: criteria))
    }

    func testGoalOnlyRequestCompletesThroughActualProductionPipeline() async {
        let fixture = Fixture()
        let result = await run(fixture)
        guard case .done = result.outcome else { return XCTFail("expected observed completion: \(result.outcome)") }
        XCTAssertEqual(fixture.effects, 1)
        XCTAssertGreaterThanOrEqual(fixture.completeReads, 3)
        XCTAssertTrue(fixture.windows.allSatisfy { $0 == fixture.window })
    }

    func testAlreadyTrueGoalRequiresFreshSemanticReadWithoutMutation() async {
        let fixture = Fixture()
        fixture.complete = true
        let result = await run(fixture)
        guard case .done = result.outcome else { return XCTFail("expected observed already: \(result.outcome)") }
        XCTAssertEqual(fixture.effects, 0)
        XCTAssertGreaterThanOrEqual(fixture.completeReads, 3)
        XCTAssertTrue(fixture.windows.allSatisfy { $0 == fixture.window })
    }

    func testUncertainBroadCompletionGetsFocusedObservedEvidenceCheck() async {
        let fixture = Fixture()
        fixture.weakCompletion = true
        let result = await run(fixture)
        guard case .done = result.outcome else { return XCTFail("focused outcome proof missing: \(result.outcome)") }
        XCTAssertEqual(fixture.effects, 1)
        XCTAssertEqual(fixture.focusedGoalCalls, 1)
        let proof = fixture.choices.last { $0.goalFactID != nil }
        XCTAssertEqual(proof?.primaryCompletionProbability, 0.48)
        XCTAssertEqual(proof?.refinedCompletionProbability, 0.99)
        XCTAssertEqual(proof?.completionProbability, 0.99)
        XCTAssertEqual(proof?.requestCount, 2)
        XCTAssertGreaterThanOrEqual(fixture.completeReads, 3)
    }

    func testProductionSnapshotIdentitySurvivesFocusedEvidenceAndCannotBeForgedByExtras() async {
        let fixture = Fixture()
        fixture.weakCompletion = true
        _ = await run(fixture, extraState: ["snapshot_id": .string("forged")])
        XCTAssertEqual(fixture.states.first?["snapshot_id"]?.string, "capture-1")
        guard let focusedIndex = fixture.states.firstIndex(where: {
            $0["goal_refinement_candidates"] != nil
        }), let focusedID = fixture.states[focusedIndex]["snapshot_id"]?.string else {
            return XCTFail("production refinement lost its captured snapshot identity")
        }
        XCTAssertTrue(focusedID.hasPrefix("capture-"))
        XCTAssertEqual(focusedID, fixture.states[..<focusedIndex].last?["snapshot_id"]?.string)
    }

    func testFocusedEvidenceCannotReplaceWeakCompletionWithStrongFactSupport() async {
        let fixture = Fixture()
        fixture.weakCompletion = true
        fixture.weakRefinedCompletion = true
        let result = await run(fixture)
        if case .done = result.outcome { XCTFail("weak focused completion must not finish") }
        XCTAssertGreaterThan(fixture.focusedGoalCalls, 0)
    }

    func testFocusedEvidenceUsesRealFactChoiceWhenInitialSelectionIsNone() async {
        let fixture = Fixture()
        fixture.weakCompletion = true
        fixture.initialFactNone = true
        let result = await run(fixture)
        guard case .done = result.outcome else { return XCTFail("supported fact was never selected: \(result.outcome)") }
        XCTAssertEqual(fixture.focusedFactSelections, 1)
        XCTAssertEqual(fixture.choices.last { $0.goalFactID != nil }?.requestCount, 3)
        XCTAssertGreaterThanOrEqual(fixture.completeReads, 3)
    }

    func testFocusedEvidenceRejectsForgedFactIdentity() async {
        let fixture = Fixture()
        fixture.weakCompletion = true
        fixture.forgedFact = true
        let result = await run(fixture)
        if case .done = result.outcome { XCTFail("forged focused fact cannot finish") }
    }

    func testHighCompletionAliasDriftCannotMintProofFromDifferentModel() async {
        let fixture = Fixture()
        fixture.complete = true
        fixture.refinementModel = "jev-1.13.0"
        let result = await run(fixture, model: "jev-latest")
        if case .done = result.outcome { XCTFail("support from a different actual model cannot prove completion") }
        XCTAssertEqual(fixture.effects, 0)
    }

    func testFocusedCompletionAliasDriftCannotMintProofFromDifferentModel() async {
        let fixture = Fixture()
        fixture.complete = true
        fixture.weakCompletion = true
        fixture.refinementModel = "jev-1.13.0"
        let result = await run(fixture, model: "jev-latest")
        if case .done = result.outcome { XCTFail("focused evidence from a different actual model cannot finish") }
        XCTAssertEqual(fixture.effects, 0)
    }

    func testAvailableButtonAndSecureValueCannotBecomeProof() async {
        let fixture = Fixture()
        fixture.complete = true
        fixture.buttonOnly = true
        let result = await run(fixture)
        if case .done = result.outcome { XCTFail("available control is not an outcome") }
        XCTAssertEqual(fixture.effects, 0)
        XCTAssertFalse(fixture.states.contains { "\($0)".contains("private-sentinel") })
    }

    func testButtonWithoutActionMetadataIsNotDeclaredOutcomeEvidence() {
        let snap = AXSnapshot(windowTitle: "Setup", snapshotID: "buttons-only", elements: [
            AXElement(index: 1, token: nil, role: "AXButton", label: "Setup complete",
                      value: nil, frame: nil, actions: []),
        ], treeMarkdown: "Setup complete")
        XCTAssertFalse(TaskLoop.successEvidence(in: snap,
            task: TaskBrief(goal: "Finish setup", successContains: ["Setup complete"])))
    }

    func testChangedSubjectWithSameOutcomeTextInvalidatesProof() async {
        let fixture = Fixture()
        fixture.complete = true
        fixture.changeSubject = true
        let result = await run(fixture)
        if case .done = result.outcome { XCTFail("proof crossed an account change") }
        XCTAssertGreaterThanOrEqual(fixture.completeReads, 2)
        XCTAssertEqual(fixture.effects, 0)
    }

    func testUnchangedOutcomeWithTickingContextStillFailsClosed() async {
        let fixture = Fixture()
        fixture.complete = true
        fixture.drift = true
        let result = await run(fixture)
        if case .done = result.outcome { XCTFail("context equality was weakened") }
        XCTAssertEqual(fixture.effects, 0)
    }

    func testForgedFactIDDoesNotAuthorizeCompletion() async {
        let fixture = Fixture()
        fixture.complete = true
        fixture.forgedFact = true
        let result = await run(fixture)
        if case .done = result.outcome { XCTFail("unobserved evidence ID accepted") }
        XCTAssertEqual(fixture.effects, 0)
    }

    func testSemanticProofCannotOverrideDeclaredOrBlankCriteria() async {
        for criteria in [["Other outcome"], [" "]] {
            let fixture = Fixture()
            fixture.complete = true
            let result = await run(fixture, criteria: criteria)
            if case .done = result.outcome { XCTFail("explicit criteria were overridden") }
            XCTAssertEqual(fixture.effects, 0)
        }
    }

    func testCancellationDuringTargetedSupportCannotClaimDone() async {
        let fixture = Fixture()
        fixture.complete = true
        fixture.cancelSupport = true
        let result = await Task { await self.run(fixture) }.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(fixture.effects, 0)
    }
}
