import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaStateVerificationTests: XCTestCase {
    private func result(_ status: String, stable: Bool = false, samples: Int = 2) -> JSONValue {
        .object(["status": .string(status), "stable": .bool(stable), "samples": .number(Double(samples)),
                 "predicates": .array([.object(["index": .number(0), "status": .string(status),
                    "unknown_reason": status == "unknown" ? .string("multi_match") : .null])])])
    }

    func testOnlyStableSatisfiedEvidencePasses() throws {
        XCTAssertEqual(try CuaStateVerification.outcome(result("satisfied", stable: true)), .satisfied)
        XCTAssertEqual(try CuaStateVerification.outcome(result("unsatisfied")), .unsatisfied)
        XCTAssertEqual(try CuaStateVerification.outcome(result("unknown")), .unknown)
        XCTAssertThrowsError(try CuaStateVerification.outcome(result("satisfied")))
        XCTAssertThrowsError(try CuaStateVerification.outcome(result("satisfied", stable: true, samples: 1)))
        XCTAssertThrowsError(try CuaStateVerification.outcome(.object(["status": .string("satisfied")])))
        var contradictory = try XCTUnwrap(result("unknown").object)
        contradictory["status"] = .string("satisfied")
        contradictory["stable"] = .bool(true)
        XCTAssertThrowsError(try CuaStateVerification.outcome(.object(contradictory)))
    }

    func testExactWindowAndValueUseDriverPollingWithoutRefreshingTokens() async throws {
        var calls = 0
        let outcome = try await CuaStateVerification.elementValue(pid: 42, window: 7, role: "AXTextArea",
                                                                 value: "exact\ntext", call: { tool, args in
            calls += 1
            XCTAssertEqual(tool, "verify_state")
            XCTAssertEqual(args["pid"], .number(42)); XCTAssertEqual(args["window_id"], .number(7))
            XCTAssertEqual(args["stable_samples"], .number(2))
            XCTAssertEqual(args["expect"]?.array?.first?["element"]?["value_equals"], .string("exact\ntext"))
            return self.result("satisfied", stable: true)
        })
        XCTAssertEqual(outcome, .satisfied); XCTAssertEqual(calls, 1)
    }

    func testUnknownAndTimeoutNeverTriggerRetryOrAlternateObservation() async throws {
        for timeout in [false, true] {
            var calls = 0
            do {
                let outcome = try await CuaStateVerification.elementValue(pid: 42, window: 7, role: "AXTextArea", value: "text", call: { _, _ in
                    calls += 1
                    if timeout { throw DriverConnectionError.timedOut }
                    return self.result("unknown")
                })
                XCTAssertFalse(timeout); XCTAssertEqual(outcome, .unknown)
            } catch { XCTAssertTrue(timeout); XCTAssertEqual(error as? DriverConnectionError, .timedOut) }
            XCTAssertEqual(calls, 1)
        }
    }

    func testCancellationDiscardsLateVerification() async throws {
        var dispatched: CheckedContinuation<Void, Never>?
        var finish: CheckedContinuation<Void, Never>?
        let task = Task {
            try await CuaStateVerification.elementValue(pid: 42, window: 7, role: "AXTextArea", value: "text", call: { _, _ in
                await withCheckedContinuation { continuation in
                    finish = continuation
                    dispatched?.resume()
                }
                return self.result("satisfied", stable: true)
            })
        }
        await withCheckedContinuation { dispatched = $0 }
        task.cancel(); finish?.resume()
        do { _ = try await task.value; XCTFail("Late verification survived cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
