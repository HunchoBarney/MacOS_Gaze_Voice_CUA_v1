import XCTest
@testable import JevVoiceCore

/// Contract: System One request/response coding — the model's wire shape,
/// including the drifted key spellings the decoder was built to survive.
final class JevModelsTests: XCTestCase {
    private func decodeAnswer(_ json: String) throws -> Answer {
        try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
    }

    func testChoiceQuestionEncodesTypeInstructionsCriteria() throws {
        let q = Question.choice(instructions: "pick one",
                                criteria: ["a": "first", "b": nil])
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(q)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "choice")
        XCTAssertEqual(object?["instructions"] as? String, "pick one")
        let criteria = object?["criteria"] as? [String: Any]
        XCTAssertEqual(criteria?["a"] as? String, "first")
        XCTAssertTrue(criteria?.keys.contains("b") == true)
    }

    func testNoulAndScoreQuestionTypes() throws {
        for (q, want) in [(Question.noul(instructions: "i"), "noul"),
                          (Question.score(instructions: "i", levels: ["lo", "hi"]), "score")] {
            let object = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(q)) as? [String: Any]
            XCTAssertEqual(object?["type"] as? String, want)
        }
    }

    func testNoulCriteriaEncodeWithoutChangingLegacyRequests() throws {
        let defined = Question.noul(instructions: "Does the operation match?",
                                    criteria: ["true": "The target and operation match.",
                                               "false": "Only a related or missing target exists."])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defined)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "noul")
        XCTAssertEqual((object?["criteria"] as? [String: String])?["true"], "The target and operation match.")
        let legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Question.noul(instructions: "Legacy"))) as? [String: Any]
        XCTAssertNil(legacy?["criteria"])
        XCTAssertEqual(legacy?["instructions"] as? String, "Legacy")
    }

    func testChoiceAnswerDecodes() throws {
        let answer = try decodeAnswer("""
            {"type":"choice","choice":"e3","confidence":0.8,
             "probabilities":{"e3":0.8,"done":0.2}}
            """)
        guard case let .choice(choice, confidence, probabilities) = answer else {
            return XCTFail("expected .choice, got \(answer)")
        }
        XCTAssertEqual(choice, "e3")
        XCTAssertEqual(confidence, 0.8, accuracy: 0.001)
        XCTAssertEqual(probabilities["done"] ?? 0, 0.2, accuracy: 0.001)
    }

    /// The model has shipped `confidence_score` and `probs` — the decoder
    /// must still produce a trusted choice.
    func testDriftedKeysStillDecode() throws {
        let answer = try decodeAnswer("""
            {"type":"choice","choice":"done","confidence_score":0.9,
             "probs":{"done":0.9}}
            """)
        guard case let .choice(choice, confidence, _) = answer else {
            return XCTFail("expected .choice, got \(answer)")
        }
        XCTAssertEqual(choice, "done")
        XCTAssertEqual(confidence, 0.9, accuracy: 0.001)
    }

    /// No confidence AND no probabilities is untrusted — never decoded as
    /// a confident 0.0 or silently dropped.
    func testConfidencelessChoiceIsUntrusted() throws {
        let answer = try decodeAnswer("""
            {"type":"choice","choice":"e1"}
            """)
        guard case .untrustedChoice(let choice, _) = answer else {
            return XCTFail("expected .untrustedChoice, got \(answer)")
        }
        XCTAssertEqual(choice, "e1")
    }

    /// Probabilities without confidence: the pick's own mass is the
    /// confidence — still a real .choice, not a drop.
    func testProbabilityBackedChoiceConfidence() throws {
        let answer = try decodeAnswer("""
            {"type":"choice","choice":"e2","probabilities":{"e2":0.7,"e3":0.3}}
            """)
        guard case let .choice(_, confidence, _) = answer else {
            return XCTFail("expected .choice, got \(answer)")
        }
        XCTAssertEqual(confidence, 0.7, accuracy: 0.001)
    }

    func testSystemOneResponseDecodesAnswersMap() throws {
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data("""
            {"model":"jev-1",
             "answers":{"step":{"type":"choice","choice":"done","confidence":1.0,"probabilities":{"done":1.0}}},
             "usage":{"input_tokens":10,"output_tokens":3}}
            """.utf8))
        XCTAssertEqual(response.model, "jev-1")
        XCTAssertEqual(response.usage?.inputTokens, 10)
        XCTAssertNotNil(response.answers["step"])
    }

    func testBoxQuestionEncodesWithoutCriteria() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            Question.box(instructions: "the Search control in `window_image`"))) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "box")
        XCTAssertEqual(object?["instructions"] as? String, "the Search control in `window_image`")
        XCTAssertNil(object?["criteria"])
    }

    func testBoxAnswerPreservesNullableConfidence() throws {
        for field in ["null", "0.0", "0.91"] {
            let answer = try decodeAnswer("""
                {"type":"box","box":{"top":0.1,"bottom":0.5,"left":0.2,"right":0.8},"confidence":\(field)}
                """)
            guard case let .box(box, confidence) = answer else { return XCTFail("not a box") }
            XCTAssertEqual(box.left, 0.2)
            if field == "null" { XCTAssertNil(confidence) }
            else { XCTAssertEqual(confidence, Double(field)) }
        }
    }

    func testBoxRejectsOutsideReversedAndZeroAreaCoordinates() throws {
        for box in [
            #"{"top":-0.1,"bottom":0.5,"left":0.2,"right":0.8}"#,
            #"{"top":0.1,"bottom":1.1,"left":0.2,"right":0.8}"#,
            #"{"top":0.1,"bottom":0.5,"left":-0.2,"right":0.8}"#,
            #"{"top":0.1,"bottom":0.5,"left":0.2,"right":1.1}"#,
            #"{"top":0.5,"bottom":0.1,"left":0.2,"right":0.8}"#,
            #"{"top":0.1,"bottom":0.5,"left":0.8,"right":0.2}"#,
            #"{"top":0.1,"bottom":0.1,"left":0.2,"right":0.8}"#,
            #"{"top":0.1,"bottom":0.5,"left":0.2,"right":0.2}"#,
            #"{"top":"NaN","bottom":0.5,"left":0.2,"right":0.8}"#,
            #"{"top":true,"bottom":0.5,"left":0.2,"right":0.8}"#,
        ] {
            XCTAssertThrowsError(try decodeAnswer(
                #"{"type":"box","box":\#(box),"confidence":0.9}"#))
        }
    }

    func testBoxRejectsMalformedConfidence() {
        for value in ["-0.1", "1.1", #""certain""#, "true"] {
            XCTAssertThrowsError(try decodeAnswer("""
                {"type":"box","box":{"top":0,"bottom":1,"left":0,"right":1},"confidence":\(value)}
                """))
        }
    }

    /// A malformed answer drops its own key — the same lossy rule Answer
    /// applies to its fields — instead of poisoning sibling answers.
    func testMalformedAnswerDropsKeyWithoutPoisoningSiblings() throws {
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data("""
            {"model":"jev-1",
             "answers":{
               "step":{"type":"choice","choice":"done","confidence":1.0,"probabilities":{"done":1.0}},
               "pick_box":{"type":"box","box":{"top":0.8,"bottom":0.1,"left":0.2,"right":0.9},"confidence":0.9},
               "noul_gate":{"type":"noul","noul":0.97}
             },
             "usage":{"input_tokens":10,"output_tokens":3}}
            """.utf8))
        XCTAssertNotNil(response.answers["step"])
        XCTAssertNotNil(response.answers["noul_gate"])
        XCTAssertNil(response.answers["pick_box"])
        XCTAssertEqual(response.malformedAnswers, ["pick_box"])
    }

    /// A response whose `answers` object is absent or wrong-typed still
    /// refuses — only per-answer payloads are lossy.
    func testMalformedAnswersObjectStillRefuses() {
        for body in [
            #"{"model":"jev-1","usage":{"input_tokens":1,"output_tokens":1}}"#,
            #"{"model":"jev-1","answers":"nope","usage":{"input_tokens":1,"output_tokens":1}}"#,
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(
                SystemOneResponse.self, from: Data(body.utf8)))
        }
    }
}
