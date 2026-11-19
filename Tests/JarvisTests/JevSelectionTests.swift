import XCTest
@testable import JarvisCore

/// Contract: JevSelection.read is the last check before a model's pick
/// becomes an action — only in-bounds, finite-confidence members pass.
final class JevSelectionTests: XCTestCase {
    private let allowed: Set<String> = ["e1", "done", "reobserve"]

    private func choice(_ value: String, confidence: Double = 0.8,
                        probabilities: [String: Double] = [:]) -> Answer {
        .choice(choice: value, confidence: confidence, probabilities: probabilities)
    }

    func testValidMemberReads() throws {
        XCTAssertEqual(try JevSelection.read(choice("e1"), allowed: allowed), "e1")
    }

    func testUnknownChoiceRejected() {
        XCTAssertThrowsError(try JevSelection.read(choice("e99"), allowed: allowed)) {
            XCTAssertEqual($0 as? JevSelection.Failure, .invalidAnswer)
        }
    }

    func testNilAnswerRejected() {
        XCTAssertThrowsError(try JevSelection.read(nil, allowed: allowed))
    }

    func testUntrustedChoiceRejected() {
        let answer = Answer.untrustedChoice(choice: "e1", probabilities: ["e1": 0.5])
        XCTAssertThrowsError(try JevSelection.read(answer, allowed: allowed))
    }

    func testOutOfRangeConfidenceRejected() {
        for bad in [-0.1, 1.1, .nan, .infinity] {
            XCTAssertThrowsError(try JevSelection.read(choice("e1", confidence: bad),
                                                       allowed: allowed),
                                 "confidence \(bad) must reject")
        }
    }

    /// A probability mass naming an option we never offered poisons the
    /// whole answer — the model can't smuggle a candidate through probs.
    func testProbabilityMassOutsideAllowedSetRejected() {
        let answer = choice("e1", probabilities: ["e1": 0.5, "ghost": 0.5])
        XCTAssertThrowsError(try JevSelection.read(answer, allowed: allowed))
    }

    func testNonFiniteProbabilityRejected() {
        let answer = choice("e1", probabilities: ["e1": .nan])
        XCTAssertThrowsError(try JevSelection.read(answer, allowed: allowed))
    }

    /// .noul/.score answers are not selections — always reject.
    func testNonChoiceAnswersRejected() {
        XCTAssertThrowsError(try JevSelection.read(.noul(0.9), allowed: allowed))
    }
}
