import Foundation
import XCTest
@testable import JevVoice

final class SemanticRequestBudgetTests: XCTestCase {
    private func directory(maximum: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let auth = SemanticRequestBudget.Authorization(id: "unit-authorization", scope: "typesafe-text-only",
            maximumRequests: maximum, corpusSHA256: "fixture-hash", expiresAt: Date().timeIntervalSince1970 + 3600)
        try JSONEncoder().encode(auth).write(to: url.appendingPathComponent("authorization.json"))
        return url
    }

    func testReservationsSurviveReopenAndFailedRequests() async throws {
        let url = try directory(maximum: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try SemanticRequestBudget(directory: url, corpusSHA256: "fixture-hash")
        let index = try await first.reserve(subject: "case", requestSHA256: "digest")
        XCTAssertEqual(index, 1)
        let reopened = try SemanticRequestBudget(directory: url, corpusSHA256: "fixture-hash")
        do {
            _ = try await reopened.reserve(subject: "retry", requestSHA256: "digest")
            XCTFail("failed/successful HTTP outcome never refunds a reservation")
        } catch SemanticRequestBudget.Failure.exhausted {}
    }

    func testParallelBudgetInstancesNeverExceedCeiling() async throws {
        let url = try directory(maximum: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for n in 0..<20 {
                group.addTask {
                    do {
                        let budget = try SemanticRequestBudget(directory: url, corpusSHA256: "fixture-hash")
                        _ = try await budget.reserve(subject: "\(n)", requestSHA256: "digest")
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        XCTAssertEqual(count, 5)
    }

    func testDifferentCorpusOrOversizedAuthorizationIsRefused() throws {
        let url = try directory(maximum: 50)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try SemanticRequestBudget(directory: url, corpusSHA256: "changed"))
        let bad = SemanticRequestBudget.Authorization(id: "bad", scope: "typesafe-text-only",
            maximumRequests: 51, corpusSHA256: "fixture-hash", expiresAt: Date().timeIntervalSince1970 + 3600)
        try JSONEncoder().encode(bad).write(to: url.appendingPathComponent("authorization.json"))
        XCTAssertThrowsError(try SemanticRequestBudget(directory: url, corpusSHA256: "fixture-hash"))
    }

    func testInterruptedSubjectsCannotRepeatAndGUIReservationsStayAvailable() async throws {
        let url = try directory(maximum: 50)
        defer { try? FileManager.default.removeItem(at: url) }
        let budget = try SemanticRequestBudget(directory: url, corpusSHA256: "fixture-hash")
        for n in 0..<45 { _ = try await budget.reserve(subject: "shadow-\(n)", requestSHA256: "digest") }
        let reopened = try SemanticRequestBudget(directory: url, corpusSHA256: "fixture-hash")
        do {
            _ = try await reopened.reserve(subject: "extra-shadow", requestSHA256: "digest")
            XCTFail("must reserve five slots for GUI even after an interrupted run")
        } catch SemanticRequestBudget.Failure.exhausted {}
        for n in 0..<5 {
            _ = try await reopened.reserve(subject: "gui-\(n)", requestSHA256: "digest", allocation: "gui")
        }
        let other = try directory(maximum: 50)
        defer { try? FileManager.default.removeItem(at: other) }
        let first = try SemanticRequestBudget(directory: other, corpusSHA256: "fixture-hash")
        _ = try await first.reserve(subject: "interrupted-first", requestSHA256: "digest")
        let next = try SemanticRequestBudget(directory: other, corpusSHA256: "fixture-hash")
        do {
            _ = try await next.reserve(subject: "interrupted-first", requestSHA256: "digest")
            XCTFail("a reserved request cannot be silently rerun")
        } catch SemanticRequestBudget.Failure.duplicateSubject {}
    }
}
