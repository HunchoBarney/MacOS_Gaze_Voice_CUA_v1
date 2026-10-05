import XCTest
@testable import JevVoiceCore

final class JevModelsTests: XCTestCase {
    func testDecodeResponse() throws {
        let json = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "action": {
              "type": "choice",
              "choice": "openApp",
              "confidence": 0.95,
              "probabilities": {"openApp": 0.96, "none": 0.04}
            },
            "mentions_url": {"type": "noul", "noul": 0.99},
            "lvl": {
              "type": "score",
              "score": 0.97,
              "confidence": 0.9,
              "legend": {"0": "low"},
              "probabilities": {"0": 0.05, "1": 0.93}
            }
          },
          "usage": {"input_tokens": 631, "output_tokens": 180}
        }
        """
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.model, "jev-1.13.0")
        XCTAssertEqual(response.usage?.inputTokens, 631)

        guard case .choice(let choice, let confidence, let probs) = response.answers["action"] else {
            return XCTFail("action should decode as choice")
        }
        XCTAssertEqual(choice, "openApp")
        XCTAssertEqual(confidence, 0.95)
        XCTAssertEqual(probs["openApp"], 0.96)

        guard case .noul(let p) = response.answers["mentions_url"] else {
            return XCTFail("mentions_url should decode as noul")
        }
        XCTAssertEqual(p, 0.99)

        guard case .score(let score, _, _, let legend) = response.answers["lvl"] else {
            return XCTFail("lvl should decode as score")
        }
        XCTAssertEqual(score, 0.97)
        XCTAssertEqual(legend["0"], "low")
    }

    /// Drifted confidence spellings (`confidence_score`, `conf`) decode as
    /// real choices, not as untrusted answers.
    func testChoiceDecodesAlternateConfidenceKeys() throws {
        for key in ["confidence_score", "conf"] {
            let json = """
            {"model": "jev", "answers": {"next": {"type": "choice", "choice": "a",
              "\(key)": 0.7, "probabilities": {"a": 0.7, "b": 0.3}}}}
            """
            let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data(json.utf8))
            guard case .choice(let choice, let confidence, _) = response.answers["next"] else {
                return XCTFail("\(key) should decode as a trusted choice")
            }
            XCTAssertEqual(choice, "a")
            XCTAssertEqual(confidence, 0.7)
        }
    }

    /// A missing confidence with a shipped distribution: the pick's own
    /// recorded mass is its confidence — never the old auto-abstain 0.0,
    /// never untrusted.
    func testChoiceDerivesConfidenceFromProbabilityMass() throws {
        let json = """
        {"model": "jev", "answers": {"next": {"type": "choice", "choice": "a",
          "probabilities": {"a": 0.8, "b": 0.2}}}}
        """
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data(json.utf8))
        guard case .choice(_, let confidence, _) = response.answers["next"] else {
            return XCTFail("probabilities should stand in for a missing confidence")
        }
        XCTAssertEqual(confidence, 0.8)
    }

    /// A pick carrying no recorded mass decodes as an honest zero-confidence
    /// choice — abstains downstream rather than dying as untrusted.
    func testChoiceWithNoRecordedMassIsZeroConfidence() throws {
        let json = """
        {"model": "jev", "answers": {"next": {"type": "choice", "choice": "a",
          "probabilities": {"b": 0.9, "c": 0.1}}}}
        """
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data(json.utf8))
        guard case .choice(_, let confidence, _) = response.answers["next"] else {
            return XCTFail("a massless pick should decode as choice, not untrusted")
        }
        XCTAssertEqual(confidence, 0)
    }

    /// A bare choice — no confidence and no distribution — stays untrusted.
    func testBareChoiceStaysUntrusted() throws {
        let json = """
        {"model": "jev", "answers": {"next": {"type": "choice", "choice": "a"}}}
        """
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data(json.utf8))
        guard case .untrustedChoice(let choice, _) = response.answers["next"] else {
            return XCTFail("a bare choice must stay untrusted")
        }
        XCTAssertEqual(choice, "a")
    }

    /// A wrong-typed optional field reads as absent — it must not poison
    /// an otherwise-decodable answer.
    func testChoiceToleratesMistypedFields() throws {
        let json = """
        {"model": "jev", "answers": {"next": {"type": "choice", "choice": "a",
          "confidence": "high", "probabilities": {"a": 0.6, "b": 0.4}}}}
        """
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data(json.utf8))
        guard case .choice(_, let confidence, let probs) = response.answers["next"] else {
            return XCTFail("mistyped confidence should fall back to the pick's mass")
        }
        XCTAssertEqual(confidence, 0.6)
        XCTAssertEqual(probs["a"], 0.6)
    }

    func testEncodeRequestShape() throws {
        struct S: Encodable { let clause: String }
        let request = SystemOneRequest(
            model: "jev-latest",
            state: S(clause: "open chrome"),
            questions: [
                "action": .choice(
                    instructions: "pick",
                    criteria: ["openApp": "Open an app", "none": nil]
                ),
                "mentions": .noul(instructions: "mentions url?"),
                "lvl": .score(instructions: "rate", levels: ["low", "high"]),
            ]
        )
        let data = try JSONEncoder().encode(request)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(obj["model"] as? String, "jev-latest")
        let state = obj["state"] as! [String: Any]
        XCTAssertEqual(state["clause"] as? String, "open chrome")

        let questions = obj["questions"] as! [String: [String: Any]]
        let action = questions["action"]!
        XCTAssertEqual(action["type"] as? String, "choice")
        let criteria = action["criteria"] as! [String: Any]
        XCTAssertEqual(criteria["openApp"] as? String, "Open an app")
        XCTAssertTrue(criteria.keys.contains("none"))

        XCTAssertEqual(questions["mentions"]?["type"] as? String, "noul")

        let score = questions["lvl"]!
        XCTAssertEqual(score["type"] as? String, "score")
        XCTAssertEqual(score["criteria"] as? [String], ["low", "high"])
    }
}
