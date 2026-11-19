import Foundation
import XCTest
@testable import JevVoice

final class AccuracyCheckTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @MainActor
    func testSummaryReadsMedianP90AndS90InPlainWords() throws {
        let data = try json([
            "held_out": ["overall": ["median_deg": 2.14, "p90_deg": 3.46]],
            "hit_test": ["s90_deg": 2.5],
        ])
        XCTAssertEqual(AccuracyCheck.summary(from: data),
                       "Typical error 2.1°; 9 in 10 targets were within 3.5°. You hit targets 2.5° in radius or larger 9 times in 10.")
    }

    @MainActor
    func testSummarySaysWhenNoSizeReachedNinetyPercent() throws {
        let data = try json([
            "held_out": ["overall": ["median_deg": 4.0, "p90_deg": 6.0]],
            "hit_test": ["s90_deg": NSNull()],
        ])
        XCTAssertEqual(AccuracyCheck.summary(from: data),
                       "Typical error 4.0°; 9 in 10 targets were within 6.0°. No target size up to 3° was hit 9 times in 10.")
    }

    @MainActor
    func testSummaryRejectsReportsWithoutTheHeldOutGrid() throws {
        XCTAssertNil(AccuracyCheck.summary(from: try json(["error_px": ["overall": ["median": 50]]])))
        XCTAssertNil(AccuracyCheck.summary(from: Data("not json".utf8)))
    }
}
