import AppKit
import Darwin
import Foundation
import XCTest
import JevVoiceCore
@testable import JevVoice

/// Explicitly authorized real API evaluation, never enabled by ordinary G3.
/// No app control, audio, screenshots, contact data or synthetic model outputs.
@MainActor
final class VoiceSemanticLiveTests: XCTestCase {
    private struct Corpus: Decodable {
        let schema_version: Int
        let cases: [Case]
    }
    private struct Case: Decodable {
        let id: String
        let split: String
        let text: String
        let role_mode: String
        let target: String?
        let target_role: String?
        let no_action: Bool?
    }
    private struct Payload: Encodable {
        let model: String
        let state: JSONValue
        let questions: [String: Question]
    }
    private struct Evaluation {
        let row: [String: Any]
        let expected: String?
        let picked: String?
        let score: Double
        let valid: Bool
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: url, options: .atomic)
    }

    func testAuthorizedTextOnlyCalibration() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_P3_SEMANTIC_LIVE"] == "approved-50" else {
            throw XCTSkip("Real TypeSafe calls require the separate capped authorization.")
        }
        let batch = ProcessInfo.processInfo.environment["JARVIS_P3_SEMANTIC_BATCH"]
        if let batch {
            guard batch.hasPrefix("semantic-"), batch.utf8.count <= 64,
                  batch.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                return XCTFail("Invalid batch ID")
            }
        }
        let directory = root.appendingPathComponent(".agent/results/P3/" + (batch ?? "semantic-live"))
        let corpusURL = batch == nil ? root.appendingPathComponent("Tests/Fixtures/P3/semantic-eval.json")
            : directory.appendingPathComponent("corpus.json")
        let bytes = try Data(contentsOf: corpusURL)
        let corpus = try JSONDecoder().decode(Corpus.self, from: bytes)
        let corpusHash = SemanticRequestBudget.digest(bytes)
        let budget = try SemanticRequestBudget(directory: directory, corpusSHA256: corpusHash)
        let runLock = Darwin.open(directory.appendingPathComponent("evaluation.lock").path,
                                 O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard runLock >= 0 else { return XCTFail("Cannot acquire evaluation lock") }
        defer { Darwin.close(runLock) }
        guard flock(runLock, LOCK_EX | LOCK_NB) == 0 else { return XCTFail("Evaluation already running") }
        defer { flock(runLock, LOCK_UN) }
        guard corpus.schema_version == 1, corpus.cases.count == 45,
              Set(corpus.cases.map(\.id)).count == 45,
              corpus.cases.filter({ $0.split == "calibration" }).count == 30,
              corpus.cases.filter({ $0.split == "holdout" }).count == 15 else {
            return XCTFail("Sealed corpus population is invalid")
        }
        let startMarker = directory.appendingPathComponent("evaluation-started.json")
        let reservations = directory.appendingPathComponent("requests.jsonl")
        let prior = FileManager.default.fileExists(atPath: reservations.path)
            ? try Data(contentsOf: reservations) : Data()
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("rows.jsonl").path),
              !FileManager.default.fileExists(atPath: startMarker.path), prior.isEmpty else {
            return XCTFail("Evaluation already attempted; never retry cases into a pass")
        }
        let key: String
        do {
            guard let value = try KeychainAPIKeyStore(allowUserInteraction: false).read(), !value.isEmpty else {
                try write(["status": "blocked_missing_key", "requests": 0], to: directory.appendingPathComponent("result.json"))
                return XCTFail("Saved TypeSafe key unavailable; no request made")
            }
            key = value
        } catch {
            try write(["status": "blocked_keychain", "requests": 0], to: directory.appendingPathComponent("result.json"))
            return XCTFail("Keychain access unavailable; no request made")
        }
        var context = VoiceAdmissionContext()
        context.entities = VoiceAdmissionContext.observedAppEntities()
        context.appRoles = VoiceAdmissionContext.observedAppRoles()
        context.targetAppID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let catalog: [[String: Any]] = context.entities.map {
            ["name": $0.name, "id": $0.id, "canOpenLocally": $0.canOpenLocally]
        }
        try write(["catalog": catalog, "observed_roles": context.appRoles,
                   "frontmost_app": context.targetAppID ?? "", "corpus_sha256": corpusHash],
                  to: directory.appendingPathComponent("context.json"))
        for item in corpus.cases where item.no_action != true {
            let expected = item.target ?? item.target_role.flatMap { context.appRoles[$0] }
            guard expected.map({ id in context.entities.contains { $0.id == id } }) == true else {
                try write(["status": "blocked_missing_context", "case": item.id, "requests": 0],
                          to: directory.appendingPathComponent("result.json"))
                return XCTFail("Expected app/default role absent; no requests sent")
            }
        }
        // Validate the actual production payload before declaring an attempt
        // started. A bad catalog must never consume an API reservation.
        for item in corpus.cases {
            var snapshot = context
            if item.role_mode == "no_roles" { snapshot.appRoles = [:] }
            let session = LocalSpeechSession { _ in }
            session.context = snapshot
            if let admission = await session.submitTyped(item.text, now: ProcessInfo.processInfo.systemUptime),
               VoiceSemanticRouter.eligible(admission, context: snapshot) {
                _ = try VoiceSemanticRouter.request(item.text, context: snapshot)
            }
        }
        let markerFD = Darwin.open(startMarker.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard markerFD >= 0 else { return XCTFail("Evaluation already started") }
        let marker = FileHandle(fileDescriptor: markerFD, closeOnDealloc: true)
        try marker.write(contentsOf: JSONSerialization.data(withJSONObject: [
            "corpus_sha256": corpusHash, "started_at": Date().timeIntervalSince1970
        ], options: [.sortedKeys]))
        try marker.synchronize(); try marker.close()
        let client = JevClient(apiKey: key)
        var all: [Evaluation] = []
        var selected: Double?
        var modelVersions: Set<String> = []
        for split in ["calibration", "holdout"] {
            if split == "holdout" {
                let candidates = [0.90, 0.95, 0.99, 1.0].filter { threshold in
                    all.allSatisfy { !($0.valid && $0.picked != nil && $0.score >= threshold) || $0.picked == $0.expected }
                }
                selected = candidates.first
                try write(["status": selected == nil ? "no_feasible_policy" : "frozen_before_holdout",
                           "minimum_confidence": selected as Any? ?? NSNull(),
                           "corpus_sha256": corpusHash, "models": modelVersions.sorted()],
                          to: directory.appendingPathComponent("selected-policy.json"))
                guard selected != nil else { break }
            }
            for item in corpus.cases where item.split == split {
                var snapshot = context
                if item.role_mode == "no_roles" { snapshot.appRoles = [:] }
                let expected = item.target ?? item.target_role.flatMap { context.appRoles[$0] }
                guard item.no_action == true || expected.map({ id in snapshot.entities.contains { $0.id == id } }) == true else {
                    try write(["status": "blocked_missing_context", "case": item.id],
                              to: directory.appendingPathComponent("result.json"))
                    return XCTFail("Expected app/default role not present; no substitute is allowed")
                }
                let evaluation = try await evaluate(item, expected: expected, context: snapshot,
                                                    client: client, budget: budget, directory: directory)
                all.append(evaluation)
                if let model = evaluation.row["model"] as? String { modelVersions.insert(model) }
                var line = try JSONSerialization.data(withJSONObject: evaluation.row, options: [.sortedKeys])
                line.append(10)
                let ledger = directory.appendingPathComponent("rows.jsonl")
                if !FileManager.default.fileExists(atPath: ledger.path) {
                    guard FileManager.default.createFile(atPath: ledger.path, contents: nil) else {
                        return XCTFail("Cannot preserve evaluation rows")
                    }
                }
                let handle = try FileHandle(forWritingTo: ledger)
                try handle.seekToEnd(); try handle.write(contentsOf: line)
                try handle.synchronize(); try handle.close()
                if evaluation.row["status"] as? String == "auth_error" {
                    try write(["status": "blocked_auth", "completed_cases": all.count],
                              to: directory.appendingPathComponent("result.json"))
                    return XCTFail("TypeSafe authentication refused; no retries")
                }
            }
        }
        let threshold = selected ?? 2
        let heldout = all.filter { $0.row["split"] as? String == "holdout" }
        let clear = heldout.filter { $0.expected != nil }
        let correctAuto = clear.filter { $0.valid && $0.picked == $0.expected && $0.score >= threshold }.count
        let unsafe = heldout.filter { $0.valid && $0.picked != nil && $0.score >= threshold && $0.picked != $0.expected }.count
        let errors = heldout.filter { !$0.valid && $0.row["status"] as? String != "code_skip" }.count
        let passed = heldout.count == 15 && !clear.isEmpty && unsafe == 0 && errors == 0
            && Double(correctAuto) / Double(clear.count) >= 0.95 && modelVersions.count == 1
            && selected == VoiceSemanticRouter.minimumAutomaticConfidence
        let attempted = all.filter { $0.row["request_sent"] as? Bool == true }
        let knownUsage = attempted.compactMap { $0.row["input_tokens"] as? Int }
        let unknownUsage = attempted.count - knownUsage.count
        let latencies = attempted.compactMap { $0.row["latency_ms"] as? Double }.sorted()
        let priced = modelVersions.allSatisfy { ["jev-1.14.0", "jev-1.13.0"].contains($0) }
        let interval = wilson(successes: correctAuto, total: clear.count)
        try write(["status": passed ? "pass_small_sample" : "failed",
                   "cases": all.count, "heldout_cases": heldout.count,
                   "heldout_clear": clear.count, "heldout_correct_auto": correctAuto,
                   "heldout_local_correct": clear.filter {
                       $0.row["status"] as? String == "code_local" && $0.picked == $0.expected
                   }.count,
                   "heldout_model_clear": clear.filter { $0.row["request_sent"] as? Bool == true }.count,
                   "heldout_model_correct_auto": clear.filter {
                       $0.row["request_sent"] as? Bool == true && $0.valid
                           && $0.picked == $0.expected && $0.score >= threshold
                   }.count,
                   "heldout_unsafe_auto": unsafe, "heldout_errors": errors,
                   "minimum_confidence": selected as Any? ?? NSNull(),
                   "models": modelVersions.sorted(), "corpus_sha256": corpusHash,
                   "completed_request_attempts": attempted.count,
                   "reserved_requests": String(decoding: (try? Data(contentsOf: reservations)) ?? Data(),
                       as: UTF8.self).split(separator: "\n").count,
                   "usage_known_requests": knownUsage.count, "usage_unknown_requests": unknownUsage,
                   "measured_input_tokens": knownUsage.reduce(0, +),
                   "estimated_cost_usd": priced && unknownUsage == 0
                       ? knownUsage.reduce(0.0, { $0 + Double($1) }) * 0.042 / 1_000_000 : NSNull(),
                   "pricing_source": "https://docs.typesafe.ai/models, 2026-10-24; input $0.042/M, output free",
                   "heldout_clear_wilson95": interval,
                   "api_p50_ms": latencies.isEmpty ? NSNull() : latencies[(latencies.count - 1) / 2],
                   "api_p95_ms": latencies.isEmpty ? NSNull() : latencies[Int(ceil(Double(latencies.count) * 0.95)) - 1],
                   "automatic_execution_enabled": false, "physical_proof": false],
                  to: directory.appendingPathComponent("result.json"))
        XCTAssertTrue(passed, "Live held-out policy did not meet the predeclared bar; do not enable it")
    }

    private func evaluate(_ item: Case, expected: String?, context: VoiceAdmissionContext,
                          client: JevClient, budget: SemanticRequestBudget, directory: URL) async throws -> Evaluation {
        var localTargets: [String?] = []
        let session = LocalSpeechSession { localTargets.append($0.slots["target_id"]) }
        session.context = context
        guard let admission = await session.submitTyped(item.text, now: ProcessInfo.processInfo.systemUptime) else {
            throw VoiceSemanticRouter.Failure.invalidContext
        }
        var row: [String: Any] = ["case": item.id, "split": item.split, "text": item.text,
                                  "expected_target": expected as Any? ?? NSNull(),
                                  "admission_route": admission.route.rawValue]
        if admission.route == .local, admission.intent == "open" {
            let picked = localTargets.count == 1 ? localTargets[0] : nil
            let correct = localTargets.count == 1 && picked == expected && expected != nil
            row["status"] = correct ? "code_local" : "local_execution_mismatch"
            row["request_sent"] = false
            row["local_dispatch_count"] = localTargets.count
            row["picked_target"] = picked as Any? ?? NSNull()
            return Evaluation(row: row, expected: expected, picked: picked, score: 1, valid: correct)
        }
        guard VoiceSemanticRouter.eligible(admission, context: context) else {
            row["status"] = "code_skip"; row["request_sent"] = false
            return Evaluation(row: row, expected: expected, picked: nil, score: 0, valid: false)
        }
        let request = try VoiceSemanticRouter.request(item.text, context: context)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(Payload(model: client.model, state: request.state, questions: request.questions))
        row["reservation"] = try await budget.reserve(subject: item.id, requestSHA256: SemanticRequestBudget.digest(payload))
        row["request_sent"] = true
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let (response, _) = try await withVoiceDeadline(until: start + 4) {
                try await client.systemOne(state: request.state, questions: request.questions)
            }
            row["latency_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            row["model"] = response.model
            row["input_tokens"] = response.usage.map { $0.inputTokens as Any } ?? NSNull()
            row["output_tokens"] = response.usage.map { $0.outputTokens as Any } ?? NSNull()
            let outcome = try VoiceSemanticRouter.decode(response, request: request, turn: admission.turn)
            var picked: String?, score = 0.0
            if case .proposal(let proposal) = outcome {
                picked = proposal.target.id
                score = min(proposal.actionConfidence, proposal.targetConfidence)
            }
            row["status"] = "ok"; row["picked_target"] = picked as Any? ?? NSNull(); row["score"] = score
            for name in ["operation"] {
                if case .choice(let choice, let confidence, let probabilities) = response.answers[name] {
                    row[name] = ["choice": choice, "confidence": confidence, "probabilities": probabilities] as [String: Any]
                }
            }
            return Evaluation(row: row, expected: expected, picked: picked, score: score, valid: true)
        } catch {
            row["latency_ms"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            row["status"] = "request_or_decode_error"
            if case JevError.http(let status, _) = error {
                row["http_status"] = status
                if status == 401 || status == 403 { row["status"] = "auth_error" }
            }
            return Evaluation(row: row, expected: expected, picked: nil, score: 0, valid: false)
        }
    }

    private func wilson(successes: Int, total: Int) -> [String: Double] {
        guard total > 0 else { return [:] }
        let n = Double(total), p = Double(successes) / n, z = 1.959963984540054
        let center = (p + z * z / (2 * n)) / (1 + z * z / n)
        let width = z * sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
        return ["lower": max(0, center - width), "upper": min(1, center + width)]
    }
}
