import Foundation
import CryptoKit
import XCTest
import JevVoiceCore
@testable import JevVoice

final class JevAdaptiveLiveTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        let client: JevClient
        let ledger: URL
        var spent: Int
        var traces: [JSONValue] = []
        var lastChoice: DriveLoop.JevChoice?

        init(key: String, ledger: URL) throws {
            client = JevClient(apiKey: key, model: "jev-1.14.0")
            self.ledger = ledger
            if FileManager.default.fileExists(atPath: ledger.path) {
                let data = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: ledger))
                guard data["grant"]?.string == "user-approved-additional-unlimited-synthetic",
                      let used = data["spent"]?.numberValue,
                      used.isFinite, used >= 0, used <= 512, used.rounded() == used else {
                    throw JevSelection.Failure.invalidAnswer
                }
                spent = Int(used)
            } else {
                spent = 0
            }
        }

        var infer: JevChooser.Infer {
            { state, questions in try await self.record(state, questions) }
        }

        private func record(_ state: JSONValue, _ questions: [String: Question]) async throws -> (SystemOneResponse, Double) {
            try Task.checkCancellation()
            guard spent < 512 else { throw JevSelection.Failure.invalidAnswer }
            spent += 1
            try JSONEncoder().encode(JSONValue.object([
                "grant": .string("user-approved-additional-unlimited-synthetic"),
                "spent": .number(Double(spent)), "batch_limit": .number(512)
            ])).write(to: ledger, options: .atomic)
            let encodedQuestions = try JSONDecoder().decode(
                JSONValue.self, from: JSONEncoder().encode(questions))
            let (response, latency) = try await client.systemOne(state: state, questions: questions)
            var answers: [String: JSONValue] = [:]
            for (name, answer) in response.answers {
                switch answer {
                case .choice(let id, let confidence, let probabilities):
                    answers[name] = .object([
                        "choice": .string(id), "confidence": .number(confidence),
                        "probabilities": .object(probabilities.mapValues(JSONValue.number))
                    ])
                case .noul(let value): answers[name] = .object(["noul": .number(value)])
                default: answers[name] = .string("unexpected answer type")
                }
            }
            traces.append(.object([
                "state": state, "questions": encodedQuestions, "answers": .object(answers),
                "model": .string(response.model), "latency_ms": .number(latency)
            ]))
            return (response, latency)
        }
    }

    func testMeasureCurrentProductionJudgments() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_P4_JEV_ADAPTIVE"] == "approved-additional" else {
            throw XCTSkip("explicit additional synthetic API approval required")
        }
        let key = try XCTUnwrap(env["TYPESAFE_API_KEY"])
        let arm = try XCTUnwrap(env["JARVIS_P4_JEV_ADAPTIVE_ARM"])
        guard ["baseline", "after", "after-repeat"].contains(arm) else {
            return XCTFail("invalid measurement arm")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".agent/results/P4")
        let output = directory.appendingPathComponent("jev-adaptive-\(arm)-r2.json")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            return XCTFail("refusing to overwrite previous measurement")
        }
        let recorder = try Recorder(key: key,
            ledger: directory.appendingPathComponent("jev-adaptive-grant.json"))
        let repeats = Int(env["JARVIS_P4_JEV_ADAPTIVE_REPEATS"] ?? "2") ?? 0
        guard (1...3).contains(repeats),
              recorder.spent + repeats * JevAdaptiveFixture.all.count * 2 <= 512 else {
            return XCTFail("batch budget insufficient or invalid repeat count")
        }
        let before = recorder.spent
        var rows: [JSONValue] = []
        for trial in 0..<repeats {
            let fixtures = trial.isMultiple(of: 2)
                ? JevAdaptiveFixture.all : Array(JevAdaptiveFixture.all.reversed())
            for fixture in fixtures {
                recorder.traces = []
                recorder.lastChoice = nil
                let callsBefore = recorder.spent
                let choose = JevChooser.make(model: "jev-1.14.0", infer: recorder.infer)
                let decider = JevDecider(choose: { state, candidates in
                    let picked = try await choose(state, candidates)
                    recorder.lastChoice = picked
                    return picked
                })
                let clock = ContinuousClock()
                let start = clock.now
                var row: [String: JSONValue] = [
                    "fixture": .string(fixture.name), "trial": .number(Double(trial)),
                    "held_out": .bool(fixture.heldOut), "expected": .string(fixture.expected)
                ]
                do {
                    let result = try await decider.nextStep(fixture.observation)
                    let actual = JevAdaptiveFixture.classify(result, task: fixture.task)
                    let deterministic = callsBefore == recorder.spent && actual == "verify"
                    let valid = deterministic || recorder.lastChoice != nil
                    row["response_valid"] = .bool(valid)
                    row["actual"] = .string(actual)
                    row["correct"] = .bool(valid && actual == fixture.expected)
                    row["wrong_action"] = .bool(
                        actual != fixture.expected && (actual.hasPrefix("click:") || actual.hasPrefix("type_text:")))
                    row["unsupported_done_claim"] = .bool(actual == "done" && fixture.expected != "done")
                } catch {
                    row["correct"] = .bool(false)
                    row["error_type"] = .string(String(describing: type(of: error)))
                }
                let elapsed = start.duration(to: clock.now).components
                row["wall_ms"] = .number(Double(elapsed.seconds) * 1000
                    + Double(elapsed.attoseconds) / 1e15)
                row["requests"] = .number(Double(recorder.spent - callsBefore))
                row["traces"] = .array(recorder.traces)
                rows.append(.object(row))
                let sourceNames = [
                    "Sources/JevVoice/Drive/JevChooser.swift",
                    "Sources/JevVoice/Drive/JevDecider.swift",
                    "Sources/JevVoice/Drive/DriveCandidates.swift",
                    "Sources/JevVoice/Drive/TaskLoop.swift",
                    "Sources/JevVoiceCore/Models/JevSelection.swift",
                    "Tests/JevVoiceAppTests/JevAdaptiveFixtures.swift",
                    "Tests/JevVoiceAppTests/JevAdaptiveLiveTests.swift"
                ]
                let hashes = try Dictionary(uniqueKeysWithValues: sourceNames.map { name in
                    (name, JSONValue.string(SHA256.hash(data: try Data(contentsOf:
                        root.appendingPathComponent(name))).map { String(format: "%02x", $0) }.joined()))
                })
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(JSONValue.object([
                    "kind": .string("current production chooser/decider; synthetic observations; no desktop actuation"),
                    "arm": .string(arm), "repeats": .number(Double(repeats)),
                    "requests_this_run": .number(Double(recorder.spent - before)),
                    "requests_total_for_grant": .number(Double(recorder.spent)),
                    "source_sha256": .object(hashes), "rows": .array(rows)
                ])).write(to: output, options: .atomic)
            }
        }
        XCTAssertEqual(rows.count, repeats * JevAdaptiveFixture.all.count)
        let development = rows.filter { $0["held_out"] == .bool(false) }
        print("MEASUREMENT ONLY \(arm): development correct "
              + "\(development.filter { $0["correct"] == .bool(true) }.count)/\(development.count). "
              + "Held-out scores sealed until treatment freezes. No product acceptance verdict.")
    }
}
