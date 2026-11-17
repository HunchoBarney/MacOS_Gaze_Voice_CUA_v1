import Foundation
import CryptoKit
import XCTest
import JevVoiceCore
@testable import JevVoice

final class JevLiveIntegrationTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let client: JevClient
        let ledger: URL
        var spent: Int
        var trace: [String: JSONValue] = [:]
        var lastChoice: DriveLoop.JevChoice?

        init(key: String, ledger: URL) throws {
            client = JevClient(apiKey: key, model: "jev-1.14.0")
            self.ledger = ledger
            if FileManager.default.fileExists(atPath: ledger.path) {
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: ledger))
                guard let used = value["spent"]?.numberValue, used >= 0, used <= 30,
                      used.rounded() == used else { throw JevSelection.Failure.invalidAnswer }
                spent = Int(used)
            } else {
                spent = 0
            }
        }

        func infer(_ state: JSONValue, _ questions: [String: Question]) async throws -> (SystemOneResponse, Double) {
            guard spent < 30 else { throw JevSelection.Failure.invalidAnswer }
            spent += 1
            try JSONEncoder().encode(JSONValue.object([
                "grant": .string("2026-11-08-user-approved-30-synthetic-only"),
                "spent": .number(Double(spent)), "limit": .number(30)
            ])).write(to: ledger, options: .atomic)
            trace = ["state": state, "questions": try JSONDecoder().decode(
                JSONValue.self, from: JSONEncoder().encode(questions))]
            let (response, latency) = try await client.systemOne(state: state, questions: questions)
            var answers: [String: JSONValue] = [:]
            for (name, answer) in response.answers {
                switch answer {
                case .choice(let id, let confidence, let probabilities):
                    answers[name] = .object([
                        "choice": .string(id), "confidence": .number(confidence),
                        "probabilities": .object(probabilities.mapValues(JSONValue.number))
                    ])
                case .noul(let value):
                    answers[name] = .object(["noul": .number(value)])
                default:
                    answers[name] = .string("unusable answer")
                }
            }
            trace["answers"] = .object(answers)
            trace["model"] = .string(response.model)
            trace["latency_ms"] = .number(latency)
            return (response, latency)
        }
    }

    private struct Fixture {
        var name: String
        var task: TaskBrief
        var elements: [AXElement]
        var expected: String
    }

    private func element(_ index: Int, label: String, role: String = "AXButton",
                         value: String? = nil) -> AXElement {
        AXElement(index: index, token: "fixture-\(index)", role: role, label: label,
                  value: value, frame: nil, actions: role == "AXStaticText" ? [] : ["AXPress"])
    }

    private var fixtures: [Fixture] {
        [
            Fixture(name: "save", task: TaskBrief(goal: "Press the Save button"),
                    elements: [element(1, label: "Save"), element(2, label: "Cancel")],
                    expected: "click:fixture-1"),
            Fixture(name: "numeric-target", task: TaskBrief(goal: "Press the 7 button"),
                    elements: (0..<10).map { element($0, label: String($0)) },
                    expected: "click:fixture-7"),
            Fixture(name: "literal-email", task: TaskBrief(
                goal: "Type the supplied email text into the Email field",
                values: ["Email": "fixture@example.com"]),
                    elements: [element(1, label: "Email", role: "AXTextField"),
                               element(2, label: "Name", role: "AXTextField")],
                    expected: "type_text:fixture-1"),
            Fixture(name: "missing-control", task: TaskBrief(goal: "Click Publish"),
                    elements: [element(1, label: "Save draft"), element(2, label: "Cancel"),
                               element(3, label: "Only draft controls are available", role: "AXStaticText")],
                    expected: "abstain"),
            Fixture(name: "already-exported", task: TaskBrief(
                goal: "Confirm that export completed successfully",
                successContains: ["Export completed successfully"]),
                    elements: [element(1, label: "Export completed successfully", role: "AXStaticText"),
                               element(2, label: "Export again")],
                    expected: "verify")
        ]
    }

    private var heldOut: [Fixture] {
        [
            Fixture(name: "heldout-name-entry", task: TaskBrief(
                goal: "Enter the supplied name into Full Name",
                values: ["Full Name": "Fixture User"]),
                    elements: [element(1, label: "Full Name", role: "AXTextField"),
                               element(2, label: "Organization", role: "AXTextField")],
                    expected: "type_text:fixture-1"),
            Fixture(name: "heldout-checkbox", task: TaskBrief(goal: "Select the Updates checkbox"),
                    elements: [element(3, label: "Updates", role: "AXCheckBox", value: "0"),
                               element(4, label: "Emails", role: "AXCheckBox", value: "0")],
                    expected: "click:fixture-3"),
            Fixture(name: "heldout-absent-field", task: TaskBrief(
                goal: "Type the supplied address into Street", values: ["Street": "42 Sample Lane"]),
                    elements: [element(1, label: "City", role: "AXTextField"),
                               element(2, label: "Email", role: "AXTextField")],
                    expected: "abstain"),
            Fixture(name: "heldout-failed-upload", task: TaskBrief(goal: "Confirm upload succeeded"),
                    elements: [element(1, label: "Upload failed: offline", role: "AXStaticText"),
                               element(2, label: "Retry")],
                    expected: "abstain"),
            Fixture(name: "heldout-needs-plan", task: TaskBrief(
                goal: "Enter 12, press multiply, enter 7 and press equals"),
                    elements: [element(1, label: "1"), element(2, label: "2"),
                               element(3, label: "7"), element(4, label: "multiply"),
                               element(5, label: "equals")],
                    expected: "abstain")
        ]
    }

    private func legacy(_ recorder: Recorder) -> DriveLoop.Choose {
        { state, candidates in
            guard case .object(var fields) = state else { return nil }
            for key in ["screen_values", "observed_content", "current_instruction", "supplied_field_labels"] {
                fields.removeValue(forKey: key)
            }
            let criteria = Dictionary(uniqueKeysWithValues: candidates.map {
                ($0.id, Optional($0.description))
            })
            let (response, _) = try await recorder.infer(.object(fields), [
                "step": .choice(
                    instructions: "Pick the single candidate id that best advances the goal. "
                        + "Use 'done' when the goal is visibly complete, 'reobserve' when the "
                        + "screen may have changed, 'stuck' when nothing applies.",
                    criteria: criteria),
                "done": .noul(instructions: "Score 1 only when the goal is already visibly complete "
                    + "on screen right now \u{2014} the requested end state plainly present.")
            ])
            guard let picked = try? JevSelection.readDetailed(
                response.answers["step"], allowed: Set(criteria.keys)) else { return nil }
            let done: Bool
            if case .noul(let probability) = response.answers["done"] { done = probability >= 0.5 }
            else { done = false }
            return .init(id: picked.id, confidence: picked.confidence, doneVote: done)
        }
    }

    private func classify(_ result: DecideResult, task: TaskBrief) -> String {
        switch result {
        case .act(let request):
            if request.effect == .reobserve { return "abstain" }
            if request.effect == .verifyState { return "verify" }
            if request.tool == "type_text",
               !task.values.values.contains(request.args["text"]?.string ?? "") { return "rewritten_literal" }
            return "\(request.tool):\(request.args["element_token"]?.string ?? "unbound")"
        case .blocked, .escalate: return "abstain"
        case .done: return "unverified_completion_claim"
        case .askUser: return "unexpected_ask"
        }
    }

    func testPairedSyntheticRequests() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_P4_JEV_LIVE"] == "approved-30" else {
            throw XCTSkip("requires explicit capped TypeSafe authorization")
        }
        let key = try XCTUnwrap(environment["TYPESAFE_API_KEY"])
        let repeats = Int(environment["JARVIS_P4_JEV_REPEATS"] ?? "1") ?? 0
        let arms = environment["JARVIS_P4_JEV_ARMS"] == "corrected" ? ["corrected"] : ["legacy", "corrected"]
        let cases = fixtures + (environment["JARVIS_P4_JEV_HELD_OUT"] == "1" ? heldOut : [])
        let trialOffset = Int(environment["JARVIS_P4_JEV_TRIAL_OFFSET"] ?? "0") ?? -1
        guard (1...3).contains(repeats) else { return XCTFail("invalid repeat count") }
        guard (0...2).contains(trialOffset) else { return XCTFail("invalid trial offset") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".agent/results/P4")
        let filename = environment["JARVIS_P4_JEV_OUTPUT"] ?? "jev-live-initial.json"
        guard filename.hasPrefix("jev-live-"), filename.hasSuffix(".json"),
              filename != "jev-live-grant.json",
              !filename.contains("/"), !filename.contains("..") else { return XCTFail("invalid output name") }
        let output = directory.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            return XCTFail("refusing to overwrite prior live evidence")
        }
        let recorder = try Recorder(key: key, ledger: directory.appendingPathComponent("jev-live-grant.json"))
        guard recorder.spent + repeats * cases.count * arms.count <= 30 else {
            return XCTFail("the approved 30-request grant has insufficient remaining calls")
        }
        let before = recorder.spent
        var rows: [JSONValue] = []
        for trial in trialOffset..<(trialOffset + repeats) {
            for fixture in cases {
                for arm in trial.isMultiple(of: 2) ? arms : Array(arms.reversed()) {
                    recorder.trace = [:]
                    recorder.lastChoice = nil
                    let choose = arm == "legacy" ? legacy(recorder) : JevChooser.make(
                        model: recorder.client.model, infer: { state, questions in
                            try await recorder.infer(state, questions)
                        })
                    let decider = JevDecider(choose: { state, candidates in
                        let choice = try await choose(state, candidates)
                        recorder.lastChoice = choice
                        return choice
                    })
                    let observation = TaskObservation(
                        stepIndex: 0, axSnapshot: AXSnapshot(
                            windowTitle: "Synthetic fixture", snapshotID: "fixture-snapshot",
                            elements: fixture.elements, treeMarkdown: ""),
                        task: fixture.task, history: [],
                        budget: RoundBudget(roundsRemaining: 4, millisecondsRemaining: nil))
                    var row: [String: JSONValue] = [
                        "fixture": .string(fixture.name), "arm": .string(arm),
                        "trial": .number(Double(trial)), "expected": .string(fixture.expected)
                    ]
                    let callsBefore = recorder.spent
                    do {
                        let decision = try await decider.nextStep(observation)
                        let actual = classify(decision, task: fixture.task)
                        let deterministic = recorder.spent == callsBefore && actual == "verify"
                            && TaskLoop.successEvidence(in: observation.axSnapshot, task: fixture.task)
                        row["actual"] = .string(actual)
                        row["deterministic_postcondition"] = .bool(deterministic)
                        row["response_valid"] = .bool(recorder.lastChoice != nil || deterministic)
                        row["correct"] = .bool(actual == fixture.expected && (recorder.lastChoice != nil || deterministic))
                    } catch {
                        row["error_type"] = .string(String(describing: type(of: error)))
                        row["correct"] = .bool(false)
                    }
                    row.merge(recorder.trace) { current, _ in current }
                    rows.append(.object(row))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let hash = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(
                        "Sources/JevVoice/Drive/JevChooser.swift"))).map { String(format: "%02x", $0) }.joined()
                    try encoder.encode(JSONValue.object([
                        "kind": .string("synthetic request-level A/B; same repaired candidate builder and executor policy; no actuation"),
                        "chooser_sha256": .string(hash), "model": .string("jev-1.14.0"),
                        "requests_this_run": .number(Double(recorder.spent - before)),
                        "requests_total_for_grant": .number(Double(recorder.spent)), "rows": .array(rows)
                    ])).write(to: output, options: .atomic)
                }
            }
        }
        XCTAssertEqual(rows.count, repeats * cases.count * arms.count)
        for row in rows where row["arm"]?.string == "corrected" {
            XCTAssertEqual(row["correct"], .bool(true), "\(row["fixture"]?.string ?? ""): \(row["actual"]?.string ?? "error")")
        }
    }

    func testRecordedJudgmentsReplayThroughCurrentDecider() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_P4_JEV_REPLAY"] == "1" else {
            throw XCTSkip("explicit recorded-response replay only; no network")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".agent/results/P4")
        let recording = try JSONDecoder().decode(JSONValue.self, from:
            Data(contentsOf: directory.appendingPathComponent("jev-live-final.json")))
        let chooserHash = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(
            "Sources/JevVoice/Drive/JevChooser.swift"))).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(recording["chooser_sha256"]?.string, chooserHash)
        let recordedRows = try XCTUnwrap(recording["rows"]?.array)
        var results: [JSONValue] = []
        for row in recordedRows {
            let name = try XCTUnwrap(row["fixture"]?.string)
            let fixture = try XCTUnwrap((fixtures + heldOut).first { $0.name == name })
            let choose = JevChooser.make(model: "jev-1.14.0") { state, questions in
                XCTAssertEqual(state, row["state"])
                let wireQuestions = try JSONDecoder().decode(
                    JSONValue.self, from: JSONEncoder().encode(questions))
                XCTAssertEqual(wireQuestions, row["questions"])
                let answers = try XCTUnwrap(row["answers"]?.object).mapValues { answer -> JSONValue in
                    var fields = answer.object ?? [:]
                    fields["type"] = .string(fields["choice"] != nil ? "choice" : "noul")
                    return .object(fields)
                }
                let response = try JSONDecoder().decode(SystemOneResponse.self, from:
                    JSONEncoder().encode(JSONValue.object([
                        "model": row["model"] ?? .string(""), "answers": .object(answers)
                    ])))
                return (response, row["latency_ms"]?.numberValue ?? 0)
            }
            let observation = TaskObservation(stepIndex: 0, axSnapshot: AXSnapshot(
                windowTitle: "Synthetic fixture", snapshotID: "fixture-snapshot",
                elements: fixture.elements, treeMarkdown: ""), task: fixture.task, history: [],
                budget: RoundBudget(roundsRemaining: 4, millisecondsRemaining: nil))
            let decision = try await JevDecider(choose: choose).nextStep(observation)
            let actual = classify(decision, task: fixture.task)
            XCTAssertEqual(actual, fixture.expected, name)
            results.append(.object([
                "fixture": .string(name), "actual": .string(actual),
                "expected": .string(fixture.expected), "correct": .bool(actual == fixture.expected),
                "deterministic_postcondition": .bool(
                    TaskLoop.successEvidence(in: observation.axSnapshot, task: fixture.task))
            ]))
        }
        XCTAssertEqual(results.count, 10)
        let deciderHash = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(
            "Sources/JevVoice/Drive/JevDecider.swift"))).map { String(format: "%02x", $0) }.joined()
        let output = directory.appendingPathComponent("jev-replay-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(JSONValue.object([
            "kind": .string("recorded-response replay; ZERO network requests; not a fresh live run"),
            "chooser_sha256": .string(chooserHash), "decider_sha256": .string(deciderHash),
            "rows": .array(results)
        ])).write(to: output, options: .atomic)
        print("Recorded-response replay evidence: \(output.lastPathComponent)")
    }
}
