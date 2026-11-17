import Foundation
import JevVoiceCore

/// Diagnostic coverage is deliberately not an acceptance result.
struct VoiceTrialReport {
    typealias Row = [String: JSONValue]
    struct RoutingCase: Codable, Sendable {
        let command: String
        let target: String
        let semantic: Bool
    }

    static let routingCases: [RoutingCase] = [
        .init(command: "open Calculator", target: "com.apple.calculator", semantic: false),
        .init(command: "show Calculator", target: "com.apple.calculator", semantic: false),
        .init(command: "bring Calculator to front", target: "com.apple.calculator", semantic: false),
        .init(command: "switch to Calculator", target: "com.apple.calculator", semantic: false),
        .init(command: "show Apple's plain-text editor", target: "com.apple.TextEdit", semantic: true)
    ]

    static func routingCorpusSHA() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SemanticRequestBudget.digest(try encoder.encode(routingCases))
    }

    let runID: String
    let source: String
    let artifactSHA: String
    let executedSHA: String
    private(set) var totalAttempts = 0
    private(set) var rows: [Row] = []

    static func failureStage(_ row: Row) -> String? {
        guard row["status"] != .string("ok") else { return nil }
        switch row["verification"]?["kind"]?.string {
        case "capture_failure": return "capture_or_finalize"
        case "task_completion": return "execution_settlement"
        case "owned_literal_delivery": return "literal_delivery"
        case "no_dispatch": return "safety_verification"
        case "frontmost_pid":
            return row["dispatch_count"]?.integer == 0 ? "local_admission" : "effect_verification"
        default:
            return row["status"] == .string("failed_fixture") ? "fixture_setup" : "unclassified"
        }
    }

    static func consoleFailure(_ row: Row, heard: String?) -> String {
        let quoted: String
        if let heard, let data = try? JSONEncoder().encode(String(heard.prefix(1_000))) {
            quoted = String(decoding: data, as: UTF8.self)
        } else { quoted = "(no authoritative final transcript)" }
        let expected = row["utterance"]?.string ?? row["case_id"]?.string ?? "current case"
        return """
        Local-only trial stopped at \(failureStage(row) ?? "unknown").
          Expected: \(expected)
          Heard: \(quoted)
          Local route: \(row["actual_route"]?.string ?? "none"); intent: \(row["actual_intent"]?.string ?? "none"); dispatches: \(row["dispatch_count"]?.integer ?? 0).
          This CLI slice does not exercise the normal app's semantic/realtime fallback.
          The failed check is not an unimplemented feature. Scored failures are not retried.
        """
    }

    mutating func append(_ row: Row) {
        totalAttempts += 1
        let allowed: Set<String> = [
            "case_id", "phase", "repetition", "attempt", "status", "source",
            "actual_route", "actual_intent", "dispatch_count", "effect_count",
            "wrong_critical_actions", "transcript_sha256", "transcript_word_count", "turn_id", "generation"
        ]
        var safe = row.filter { allowed.contains($0.key) }
        safe["failure_stage"] = Self.failureStage(row).map(JSONValue.string) ?? .null
        if let error = row["error"]?.string {
            safe["failure_detail_sha256"] = .string(SemanticRequestBudget.digest(Data(error.utf8)))
        }
        rows.append(safe)
        if rows.count > 128 { rows.removeFirst() }
    }

    func snapshot(status: String, attemptsFile: String, attemptsSHA: String) -> JSONValue {
        .object([
            "schema_version": .number(1), "report_kind": .string("local_voice_trial_diagnostic"),
            "run_id": .string(runID), "source": .string(source),
            "artifact_sha256": .string(artifactSHA), "executed_artifact_sha256": .string(executedSHA),
            "status": .string(status), "phase_acceptance": .bool(false),
            "local_acoustic_gate": .string(status == "stopped_on_failure" ? "failed" : "pending_live_verifier"),
            "normal_app_routing_gate": .string("not_exercised"),
            "attempts_file": .string(attemptsFile), "attempts_sha256": .string(attemptsSHA),
            "attempt_count": .number(Double(totalAttempts)), "rows_truncated": .bool(totalAttempts > rows.count),
            "raw_transcript_persisted": .bool(false), "rows": .array(rows.map(JSONValue.object))
        ])
    }

    func save(status: String, attemptsFile: URL, to url: URL) throws {
        let data = try Data(contentsOf: attemptsFile)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot(status: status, attemptsFile: attemptsFile.lastPathComponent,
                                    attemptsSHA: SemanticRequestBudget.digest(data)))
            .write(to: url, options: .atomic)
    }

    static func normalRoutingCoverage(rows: [[String: Any]], artifactSHA: String) throws -> [String: Any] {
        let passed = rows.count == routingCases.count && zip(rows, routingCases).allSatisfy { row, spec in
            row["command"] as? String == spec.command && row["observed_bundle_id"] as? String == spec.target
                && row["passed"] as? Bool == true && row["work_count"] as? Int == 1
                && row["normal_route"] as? String == (spec.semantic ? "semantic" : "local")
                && row["semantic_focus"] as? Bool == spec.semantic
                && row["false_done"] as? Bool == false && row["scripted_confirmation"] as? Bool == false
        }
        return [
            "schema_version": 1, "report_kind": "normal_controller_typed_routing",
            "artifact_sha256": artifactSHA, "corpus_sha256": try routingCorpusSHA(),
            "normal_typed_routing_gate": passed ? "passed" : "failed",
            "local_acoustic_gate": "not_exercised", "phase_acceptance": false,
            "physical_input": false, "human_confirmed": false
        ]
    }
}
