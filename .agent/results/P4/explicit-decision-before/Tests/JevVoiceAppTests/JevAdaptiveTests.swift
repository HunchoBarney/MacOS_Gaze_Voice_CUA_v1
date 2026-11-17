import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

final class JevAdaptiveTests: XCTestCase {
    final class Script: @unchecked Sendable {
        var calls: [(JSONValue, [String: Question])] = []
        var responses: [SystemOneResponse]

        init(_ responses: [SystemOneResponse]) { self.responses = responses }

        var infer: JevChooser.Infer {
            { state, questions in
                self.calls.append((state, questions))
                guard !self.responses.isEmpty else { throw JevSelection.Failure.invalidAnswer }
                return (self.responses.removeFirst(), 10)
            }
        }
    }

    private let candidates = [(id: "e1", description: "press Save"),
                              (id: "e2", description: "press Cancel")]
    private let state = JSONValue.object([
        "goal": .string("Save the draft then close it"),
        "current_instruction": .string("Save the draft then close it"),
        "observed_content": .string("Draft is unsaved"),
        "recent_steps": .array([])
    ])

    private func reply(_ probabilities: [String: Double], applicable: Double = 0.95,
                       support: [String: Double] = [:], textEntry: Double? = nil,
                       selected: String = "e1",
                       supportByIndex: [Int: Double] = [:]) throws -> SystemOneResponse {
        var answers: [String: Any] = [
            "step": ["type": "choice", "choice": selected, "confidence": 0.5,
                     "probabilities": probabilities],
            "applicable": ["type": "noul", "noul": applicable],
            "done": ["type": "noul", "noul": 0.01]
        ]
        if let textEntry { answers["text_entry"] = ["type": "noul", "noul": textEntry] }
        for (id, value) in support {
            let index = try XCTUnwrap(["e1": 0, "e2": 1, "e3": 2, "e4": 3, "e5": 4, "t1": 0][id])
            answers["support_\(index)"] = ["type": "noul", "noul": value]
        }
        for (index, value) in supportByIndex {
            answers["support_\(index)"] = ["type": "noul", "noul": value]
        }
        return try JSONDecoder().decode(SystemOneResponse.self, from:
            JSONSerialization.data(withJSONObject: ["model": "jev-1.14.0", "answers": answers]))
    }

    func testRefinementCanReachCandidateOutsideFirstThree() async throws {
        let script = try Script([
            reply(["e1": 0.3, "e2": 0.25, "e3": 0.2, "e4": 0.15, "e5": 0.1]),
            reply(["e1": 0.01, "e2": 0.01, "e3": 0.01, "e4": 0.01, "e5": 0.96],
                  support: ["e1": 0.01, "e2": 0.01, "e3": 0.01, "e4": 0.01, "e5": 0.99],
                  selected: "e5"),
        ])
        let options = (1...5).map { (id: "e\($0)", description: "press Choice \($0)") }
        let result = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, options)
        XCTAssertEqual(result?.id, "e5")
        XCTAssertEqual(script.calls.count, 2)
    }

    func testSequenceIsNotAutomaticallyRejectedByQuestion() async throws {
        let script = Script([try reply(["e1": 0.99, "e2": 0.01])])
        _ = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
        let questions = try JSONDecoder().decode(JSONValue.self, from:
            JSONEncoder().encode(try XCTUnwrap(script.calls.first?.1)))
        let instructions = try XCTUnwrap(questions["applicable"]?["instructions"]?.string)
        XCTAssertFalse(instructions.contains("requests needing a sequence"))
        XCTAssertTrue(instructions.lowercased().contains("next"))
    }

    func testBorderlineApplicabilityGetsSpecificActionEvidence() async throws {
        let script = Script([
            try reply(["e1": 0.99, "e2": 0.01], applicable: 0.55),
            try reply(["e1": 0.98, "e2": 0.02], support: ["e1": 0.96, "e2": 0.02])
        ])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
        XCTAssertEqual(script.calls.count, 2)
        XCTAssertEqual(picked?.id, "e1")
        XCTAssertEqual(picked?.applicability, 0.96)
        XCTAssertEqual(picked?.latencyMs, 20)
    }

    func testClearNoMatchDoesNotSpendAnotherCall() async throws {
        let script = Script([try reply(["e1": 0.99, "e2": 0.01], applicable: 0.03)])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
        XCTAssertEqual(script.calls.count, 1)
        XCTAssertLessThan(picked?.applicability ?? 1, 0.7)
    }

    func testClearMatchDoesNotSpendAnotherCall() async throws {
        let script = Script([try reply(["e1": 0.99, "e2": 0.01])])
        _ = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
        XCTAssertEqual(script.calls.count, 1)
    }

    func testTiedPrimaryCanBeRefinedWithoutAuthorizingTheTie() async throws {
        let script = Script([
            try reply(["e1": 0.5, "e2": 0.5]),
            try reply(["e1": 0.98, "e2": 0.02], support: ["e1": 0.96, "e2": 0.03])
        ])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
        XCTAssertEqual(script.calls.count, 2)
        XCTAssertEqual(picked?.probabilities["e1"], 0.98)
    }

    func testSecondStageRejectionCannotAuthorizeThePrimary() async throws {
        let script = Script([
            try reply(["e1": 0.6, "e2": 0.4]),
            try reply(["e1": 0.98, "e2": 0.02], support: ["e1": 0.05, "e2": 0.05])
        ])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
        XCTAssertEqual(script.calls.count, 2)
        XCTAssertTrue(picked == nil || (picked?.applicability ?? 1) < 0.7)
    }

    func testMissingSecondStageEvidenceFailsClosed() async throws {
        let script = Script([
            try reply(["e1": 0.6, "e2": 0.4]),
            try reply(["e1": 0.98, "e2": 0.02])
        ])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
        XCTAssertNil(picked)
    }

    func testInvalidDistributionCannotObtainARefinement() async throws {
        let script = Script([try reply(["e1": 0.9, "e2": 0.9])])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
        XCTAssertEqual(script.calls.count, 1)
        XCTAssertNil(picked)
    }

    func testSecondStageErrorIsNotRetried() async throws {
        let script = Script([try reply(["e1": 0.6, "e2": 0.4])])
        do {
            _ = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(state, candidates)
            XCTFail("a failed refinement must not return the first uncertain pick")
        } catch {
            XCTAssertEqual(script.calls.count, 2)
        }
    }

    func testCancellationPreventsSecondRequest() async throws {
        let first = try reply(["e1": 0.6, "e2": 0.4])
        let input = state
        let options = candidates
        let task = Task.detached {
            try await JevChooser.make(model: "jev-1.14.0", infer: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (first, 10)
            })(input, options)
        }
        do {
            _ = try await task.value
            XCTFail("cancellation must abort, not authorize or start a refinement")
        } catch is CancellationError {
        }
    }

    func testReplacementUsesFieldIdentityButKeepsPolicyCorpus() async throws {
        let fixture = try XCTUnwrap(JevAdaptiveFixture.all.first { $0.name == "replacement" })
        let decider = JevDecider(choose: { _, _ in
            DriveLoop.JevChoice(id: "t1", confidence: 1, doneVote: false)
        })
        guard case .act(let request) = try await decider.nextStep(fixture.observation) else {
            return XCTFail("the supplied Address literal must not become another question")
        }
        XCTAssertEqual(request.args["text"]?.string, "42 Sample Lane")
        XCTAssertTrue(request.elementText?.contains("Old road") == true)
    }

    func testPrivateCandidateDetailsAreNotSentOnFastPath() async throws {
        let script = Script([try reply(["e1": 0.99, "e2": 0.01])])
        var fields = try XCTUnwrap(state.object)
        fields["_candidate_details"] = .object(["e1": .object(["label": .string("Save")])])
        _ = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(.object(fields), candidates)
        XCTAssertNil(script.calls.first?.0["_candidate_details"])
        XCTAssertNil(script.calls.first?.0["candidate_details"])
    }

    func testFocusDoesNotReplaceAnAuthorizedTextEntryAction() async throws {
        let script = Script([
            try reply(["e1": 0.9, "t1": 0.1], textEntry: 0.99),
            try reply(["e1": 0.01, "t1": 0.99], selected: "t1",
                      supportByIndex: [0: 0.01, 1: 0.99])
        ])
        let input: JSONValue = .object([
            "goal": .string("Type supplied text into Email"),
            "current_instruction": .string("Type supplied text into Email"),
            "supplied_field_labels": .array([.string("Email")]),
            "_candidate_details": .object([
                "t1": .object(["tool": .string("type_text"), "label": .string("Email"),
                               "literal_available": .bool(true)])
            ])
        ])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(
            input, [("e1", "press Email"), ("t1", "type into Email")])
        XCTAssertEqual(script.calls.count, 2)
        XCTAssertEqual(picked?.id, "t1")
        XCTAssertEqual(picked?.applicability, 0.99)
    }

    func testExplicitFocusIntentDoesNotBecomeTyping() async throws {
        let script = Script([try reply(["e1": 0.99, "t1": 0.01], textEntry: 0.01)])
        let input: JSONValue = .object([
            "goal": .string("Click Email"), "current_instruction": .string("Click Email"),
            "_candidate_details": .object(["t1": .object(["tool": .string("type_text")])])
        ])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(
            input, [("e1", "press Email"), ("t1", "type into Email")])
        XCTAssertEqual(script.calls.count, 1)
        XCTAssertEqual(picked?.id, "e1")
    }

    func testReplacementGetsLiteralStateAndTextEntryJudgment() async throws {
        let script = Script([try reply(["v1": 1], textEntry: 0.99, selected: "v1")])
        let input: JSONValue = .object([
            "goal": .string("Replace the document with supplied text"),
            "_candidate_details": .object([
                "v1": .object(["tool": .string("set_value"), "literal_available": .bool(true),
                               "literal_matches_current_value": .bool(false)]),
            ]),
        ])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(
            input, [("v1", "replace all text in Document")])
        XCTAssertEqual(picked?.id, "v1")
        XCTAssertNotNil(script.calls[0].1["text_entry"])
        XCTAssertEqual(script.calls[0].0["literal_state"]?["v1"]?["literal_available"]?.bool, true)
        XCTAssertEqual(script.calls[0].0["literal_state"]?["v1"]?["literal_matches_current_value"]?.bool, false)
    }

    func testHighSupportReplacementIsNotVetoedAsNonEntry() async throws {
        let script = Script([try reply(["v1": 0.99, "t1": 0.01], textEntry: 0.99, selected: "v1")])
        let input: JSONValue = .object([
            "goal": .string("Replace all existing document text"),
            "_candidate_details": .object([
                "v1": .object(["tool": .string("set_value"), "literal_available": .bool(true)]),
                "t1": .object(["tool": .string("type_text"), "literal_available": .bool(true)]),
            ]),
        ])
        let picked = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(
            input, [("v1", "replace all text in Document"), ("t1", "insert into Document")])
        XCTAssertEqual(script.calls.count, 1)
        XCTAssertEqual(picked?.id, "v1")
    }

    func testExplicitEmptyReplacementStillGetsEntryJudgment() async throws {
        let script = Script([try reply(["v1": 1], textEntry: 0.99, selected: "v1")])
        let input: JSONValue = .object([
            "goal": .string("Clear the document"),
            "_candidate_details": .object([
                "v1": .object(["tool": .string("set_value"), "literal_available": .bool(true),
                               "literal_matches_current_value": .bool(false)]),
            ]),
        ])
        _ = try await JevChooser.make(model: "jev-1.14.0", infer: script.infer)(
            input, [("v1", "replace all text in Document")])
        XCTAssertNotNil(script.calls[0].1["text_entry"])
        XCTAssertEqual(script.calls[0].0["literal_state"]?["v1"]?["literal_available"]?.bool, true)
    }
}
