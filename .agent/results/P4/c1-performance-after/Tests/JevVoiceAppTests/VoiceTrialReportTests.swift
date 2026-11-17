import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

final class VoiceTrialReportTests: XCTestCase {
    private func failed(_ kind: String = "frontmost_pid", dispatches: Int = 0) -> VoiceTrialReport.Row {
        ["case_id": .string("live-c2"), "phase": .string("scored"), "status": .string("failed"),
         "utterance": .string("show Calculator"), "actual_route": .string("remote"),
         "actual_intent": .string("remote"), "dispatch_count": .number(Double(dispatches)),
         "effect_count": .number(0), "verification": .object(["kind": .string(kind), "passed": .bool(false)])]
    }

    func testLocalMissExplainsGateAndEscapesOnlyConsoleHeardText() {
        let row = failed()
        XCTAssertEqual(VoiceTrialReport.failureStage(row), "local_admission")
        let text = VoiceTrialReport.consoleFailure(row, heard: "private text\n\u{1B}")
        XCTAssertTrue(text.contains("Expected: show Calculator"))
        XCTAssertTrue(text.contains("Heard: \"private text\\n\\u001b\"")
            || text.contains("Heard: \"private text\\n\\u001B\""))
        XCTAssertTrue(text.contains("normal app's semantic/realtime fallback"))
        XCTAssertTrue(text.contains("dispatches: 0"))
    }

    func testCaptureExecutionEffectAndSafetyFailuresRemainDistinct() {
        XCTAssertEqual(VoiceTrialReport.failureStage(failed("capture_failure")), "capture_or_finalize")
        XCTAssertEqual(VoiceTrialReport.failureStage(failed("task_completion", dispatches: 1)), "execution_settlement")
        XCTAssertEqual(VoiceTrialReport.failureStage(failed(dispatches: 1)), "effect_verification")
        XCTAssertEqual(VoiceTrialReport.failureStage(failed("no_dispatch")), "safety_verification")
        XCTAssertEqual(VoiceTrialReport.failureStage(failed("owned_literal_delivery")), "literal_delivery")
        XCTAssertEqual(VoiceTrialReport.failureStage(["status": .string("failed_fixture")]), "fixture_setup")
    }

    func testFailedRunWritesDiagnosticWithoutRawSpeechOrPhysicalPass() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = directory.appendingPathComponent("attempts.jsonl")
        try Data("immutable attempt\n".utf8).write(to: ledger)
        let reportURL = directory.appendingPathComponent("trial-report.json")
        var report = VoiceTrialReport(runID: "run", source: "physical", artifactSHA: "source", executedSHA: "signed")
        var row = failed()
        row["text"] = .string("SensitiveSentinel")
        row["transcript"] = .string("SensitiveSentinel")
        row["error"] = .string("SensitiveSentinel")
        report.append(row)
        try report.save(status: "stopped_on_failure", attemptsFile: ledger, to: reportURL)
        let bytes = try Data(contentsOf: reportURL)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("SensitiveSentinel"))
        let result = try JSONDecoder().decode(JSONValue.self, from: bytes)
        XCTAssertEqual(result["report_kind"], .string("local_voice_trial_diagnostic"))
        XCTAssertEqual(result["local_acoustic_gate"], .string("failed"))
        XCTAssertEqual(result["normal_app_routing_gate"], .string("not_exercised"))
        XCTAssertEqual(result["phase_acceptance"], .bool(false))
        XCTAssertEqual(result["attempt_count"], .number(1))
        XCTAssertEqual(try Data(contentsOf: ledger), Data("immutable attempt\n".utf8))
    }

    func testBoundedReportDisclosesTruncationWithoutChangingAttemptCount() {
        var report = VoiceTrialReport(runID: "run", source: "scripted", artifactSHA: "source", executedSHA: "signed")
        for _ in 0..<140 { report.append(failed()) }
        let result = report.snapshot(status: "stopped_on_failure", attemptsFile: "attempts", attemptsSHA: "hash")
        XCTAssertEqual(result["attempt_count"], .number(140))
        XCTAssertEqual(result["rows"]?.array?.count, 128)
        XCTAssertEqual(result["rows_truncated"], .bool(true))
        XCTAssertEqual(result["source"], .string("scripted"))
        XCTAssertEqual(result["phase_acceptance"], .bool(false))
    }

    private func normalRows() -> [[String: Any]] {
        VoiceTrialReport.routingCases.map { spec in
            ["command": spec.command, "observed_bundle_id": spec.target, "passed": true,
             "normal_route": spec.semantic ? "semantic" : "local", "semantic_focus": spec.semantic,
             "work_count": 1, "false_done": false, "scripted_confirmation": false]
        }
    }

    func testNormalPlanCoversFourDistinctLocalVerbsAndSemanticFallback() {
        XCTAssertEqual(VoiceTrialReport.routingCases.map(\.command), [
            "open Calculator", "show Calculator", "bring Calculator to front",
            "switch to Calculator", "show Apple's plain-text editor"
        ])
        XCTAssertEqual(VoiceTrialReport.routingCases.map(\.semantic), [false, false, false, false, true])
    }

    func testNormalTypedCoverageCannotClaimAcousticOrPhaseAcceptance() throws {
        let result = try VoiceTrialReport.normalRoutingCoverage(rows: normalRows(), artifactSHA: "signed")
        XCTAssertEqual(result["normal_typed_routing_gate"] as? String, "passed")
        XCTAssertEqual(result["local_acoustic_gate"] as? String, "not_exercised")
        XCTAssertEqual(result["physical_input"] as? Bool, false)
        XCTAssertEqual(result["phase_acceptance"] as? Bool, false)
        XCTAssertEqual(result["corpus_sha256"] as? String, try VoiceTrialReport.routingCorpusSHA())
        XCTAssertEqual(try VoiceTrialReport.routingCorpusSHA(),
                       "8b0a41025a9dcc5cf9f781f3a4c6aa14ad9f286011822ab3511fbada982fd675")
    }

    func testIncompleteDuplicateWrongLaneAndFailedNormalCasesCannotPass() throws {
        var duplicate = normalRows(); duplicate[4] = duplicate[0]
        var wrongLane = normalRows(); wrongLane[4]["normal_route"] = "local"
        var failedRow = normalRows(); failedRow[1]["passed"] = false
        for rows in [Array(normalRows().dropLast()), normalRows() + [normalRows()[0]], duplicate, wrongLane, failedRow] {
            let result = try VoiceTrialReport.normalRoutingCoverage(rows: rows, artifactSHA: "signed")
            XCTAssertEqual(result["normal_typed_routing_gate"] as? String, "failed")
        }
    }
}
