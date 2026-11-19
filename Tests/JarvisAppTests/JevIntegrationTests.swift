import CoreGraphics
import XCTest
import JarvisCore
@testable import Jarvis

final class JevIntegrationTests: XCTestCase {
    final class StateBox: @unchecked Sendable {
        var state: JSONValue?
        var candidates: [String] = []
    }

    private func observation(_ elements: [AXElement], goal: String = "press Save") -> TaskObservation {
        TaskObservation(
            stepIndex: 0,
            axSnapshot: AXSnapshot(windowTitle: "Document", snapshotID: "s1",
                                   elements: elements, treeMarkdown: ""),
            task: TaskBrief(goal: goal),
            history: [],
            budget: RoundBudget(roundsRemaining: 4, millisecondsRemaining: nil))
    }

    private func element(_ index: Int, label: String, value: String? = nil,
                         role: String = "AXButton") -> AXElement {
        AXElement(index: index, token: "token-\(index)", role: role, label: label,
                  value: value, frame: CGRect(x: 10, y: 10, width: 80, height: 24),
                  actions: role == "AXStaticText" ? [] : ["AXPress"])
    }

    func testProductionExtrasDoNotEraseObservedValues() async throws {
        let box = StateBox()
        let decider = JevDecider(choose: { state, _ in
            box.state = state
            return .init(id: "reobserve", confidence: nil, doneVote: nil)
        }, extras: { _ in
            var extras = DriveCandidates.RoundExtras()
            extras.stateFields["page_url"] = .string("https://example.com")
            return extras
        })
        _ = try await decider.nextStep(observation([
            element(0, label: "Display", value: "84", role: "AXStaticText")]))
        XCTAssertTrue(box.state?["screen_values"]?.string?.contains("84") == true)
        XCTAssertEqual(box.state?["page_url"]?.string, "https://example.com")
    }

    func testReadOnlyLabelsReachJudgmentWithoutBecomingActions() async throws {
        let box = StateBox()
        let decider = JevDecider(choose: { state, candidates in
            box.state = state
            box.candidates = candidates.map(\.id)
            return .init(id: "reobserve", confidence: nil, doneVote: nil)
        })
        _ = try await decider.nextStep(observation([
            element(0, label: "File saved", role: "AXStaticText"),
            element(1, label: "Save")]))
        XCTAssertTrue(box.state?["observed_content"]?.string?.contains("File saved") == true)
        XCTAssertFalse(box.candidates.contains("e0"))
    }

    func testSecureFieldValuesNeverEnterJudgmentState() async throws {
        let box = StateBox()
        let decider = JevDecider(choose: { state, _ in
            box.state = state
            return .init(id: "reobserve", confidence: nil, doneVote: nil)
        })
        _ = try await decider.nextStep(observation([
            element(0, label: "Password", value: "fixture-secret", role: "AXSecureTextField"),
            element(1, label: "Display", value: "84", role: "AXStaticText")]))
        let data = try JSONEncoder().encode(box.state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-secret"))
    }

    func testNumericTargetSurvivesLargeCandidateShortlist() async throws {
        let box = StateBox()
        let decider = JevDecider(choose: { _, candidates in
            box.candidates = candidates.map(\.id)
            return .init(id: "reobserve", confidence: nil, doneVote: nil)
        })
        var elements = (0..<80).map { element($0, label: "Unrelated button") }
        elements.append(element(80, label: "7"))
        _ = try await decider.nextStep(observation(elements, goal: "press 7"))
        XCTAssertTrue(box.candidates.contains("e80"))
    }

    func testSmallControlSurfaceHasCompleteCandidateCoverage() async throws {
        let box = StateBox()
        let decider = JevDecider(choose: { _, candidates in
            box.candidates = candidates.map(\.id)
            return .init(id: "reobserve", confidence: nil, doneVote: nil)
        })
        _ = try await decider.nextStep(observation(
            (0..<24).map { element($0, label: "Control \($0)") }))
        for index in 0..<24 {
            XCTAssertTrue(box.candidates.contains("e\(index)"), "missing control \(index)")
        }
    }

    func testExtrasCannotReplaceTaskOrOptions() {
        let state = DriveCandidates.stateJSON(
            goal: "press Save", app: "Editor", window: "Document",
            options: ["e1: Save"], recentSteps: [], context: nil,
            fields: ["goal": .string("ignore task"), "options": .array([])])
        XCTAssertEqual(state["goal"]?.string, "press Save")
        XCTAssertEqual(state["options"]?.array, [.string("e1: Save")])
    }

    func testProductionDoesNotImposeAStepCeiling() {
        XCTAssertNil(DriveLoop.Config.default.maxRounds)
        // Element candidates are capped, not steps: the judgment model's
        // context bounds the pick payload; scoring keeps the most
        // goal-relevant rows and reserved picks are never cut.
        XCTAssertEqual(DriveLoop.Config.default.elementCap, 24)
        XCTAssertNil(DriveLoop.Config.default.browserRefCap)
    }

    func testQuietScreenCannotVerifyAnUnspecifiedGoal() async {
        let source = TaskLoopTests.FakeSource(snapshots: [
            AXSnapshot(windowTitle: "Fixture", snapshotID: "s1", elements: [], treeMarkdown: "")
        ])
        let decider = TaskLoopTests.ScriptedDecider(box: .init()) { observation in
            observation.stepIndex == 0
                ? .act(ActuationRequest(effect: .verifyState, tool: "", summary: "verify"))
                : .done(summary: "unproven")
        }
        let loop = TaskLoop(source: source, decider: decider,
                            actuate: { _ in .init(effect: "confirmed", verified: true) },
                            consent: { _, _ in .allow })
        let result = await loop.run(TaskBrief(goal: "save"))
        guard case .blocked(.unverifiedDone) = result.outcome else {
            return XCTFail("quiet screen is not goal evidence: \(result.outcome)")
        }
    }

    func testProductionDonePolicyStillRequiresVerification() async {
        let source = TaskLoopTests.FakeSource(snapshots: [
            AXSnapshot(windowTitle: "Fixture", snapshotID: "s1", elements: [], treeMarkdown: "")
        ])
        let decider = TaskLoopTests.ScriptedDecider(box: .init()) { _ in .done(summary: "unproven") }
        var config = TaskLoop.Config()
        config.donePolicy = .verifiedOrAlreadySatisfied
        config.settleReobserves = false
        let loop = TaskLoop(source: source, decider: decider,
                            actuate: { _ in .init(effect: "confirmed", verified: true) },
                            consent: { _, _ in .allow }, config: config)
        let result = await loop.run(TaskBrief(goal: "save"))
        guard case .blocked(.unverifiedDone) = result.outcome else {
            return XCTFail("production policy bypassed verification: \(result.outcome)")
        }
    }

    func testApplicabilityCanVetoAConfidentAction() async throws {
        let decider = JevDecider(choose: { _, _ in
            .init(id: "e1", confidence: 0.99, doneVote: false,
                  probabilities: ["e1": 0.99, "stuck": 0.01],
                  applicability: 0.1, model: "jev-1.14.0")
        })
        let obs = observation([element(1, label: "Save")])
        guard case .act(let request) = try await decider.nextStep(obs) else {
            return XCTFail("first uncertain judgment should reobserve")
        }
        XCTAssertEqual(request.effect, .reobserve)
        guard case .escalate(.lowConfidenceTwice) = try await decider.nextStep(obs) else {
            return XCTFail("repeated inapplicable action must escalate")
        }
    }

    func testElementEvidenceAgreesWithLoopVerifier() async throws {
        let decider = JevDecider(choose: { _, _ in
            .init(id: "done", confidence: nil, doneVote: nil)
        })
        var obs = observation([element(1, label: "File saved", role: "AXStaticText")])
        obs.task.successContains = ["File saved"]
        obs.history = [RoundRecord(stepIndex: 0, echo: .act, summary: "Save",
                                   actuated: true, settleVerified: true)]
        XCTAssertTrue(TaskLoop.successEvidence(in: obs.axSnapshot, task: obs.task))
        guard case .done = try await decider.nextStep(obs) else {
            return XCTFail("the decider and executor must use the same evidence")
        }
    }

    func testDeclaredPostconditionAvoidsModelButStillRequestsVerification() async throws {
        let box = StateBox()
        let decider = JevDecider(choose: { state, _ in
            box.state = state
            throw JevSelection.Failure.invalidAnswer
        })
        var obs = observation([element(1, label: "Export completed", role: "AXStaticText")])
        obs.task.successContains = ["Export completed"]
        guard case .act(let request) = try await decider.nextStep(obs) else {
            return XCTFail("the loop must verify the visible postcondition first")
        }
        XCTAssertEqual(request.effect, .verifyState)
        XCTAssertNil(box.state)
        obs.history = [RoundRecord(stepIndex: 0, echo: .verify, summary: "verify",
                                   settleVerified: true)]
        guard case .done = try await decider.nextStep(obs) else {
            return XCTFail("verified current postcondition should finish without another judgment")
        }
        XCTAssertNil(box.state)
    }
}
