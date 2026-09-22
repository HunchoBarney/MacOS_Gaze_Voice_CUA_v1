import XCTest
import JevVoiceCore
@testable import JevVoice

/// No paid service or credential access unless the exact opt-in is present.
/// The sink never creates Cua tasks or desktop effects.
@MainActor
final class VoiceUnderstandingEvaluationTests: XCTestCase {
    struct Manifest: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let id, split, category, family, text, expectedOutcome: String
        let final: Bool
        let expectedKind, expectedText, critical, expectedPayload: String?
        let context: JSONValue
    }
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func fixtures() throws -> [Case] {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: Self.root.appendingPathComponent("Tests/Fixtures/Voice/understanding.json"))).cases
    }
    static func matches(_ fixture: Case, outcome: String, handoffs: [SpeechIntent]) -> Bool {
        if fixture.expectedOutcome == "ready" {
            return handoffs.count == 1 && handoffs[0].kind.rawValue == fixture.expectedKind && handoffs[0].text == fixture.expectedText
        }
        return handoffs.isEmpty && outcome == fixture.expectedOutcome
    }
    func testManifestAndScorerRejectWrongInterpretation() throws {
        let cases = try fixtures(), held = cases.filter { $0.split == "heldout" }
        XCTAssertEqual(held.count, 60)
        XCTAssertEqual(held.filter { $0.category == "valid" }.count, 30)
        XCTAssertEqual(held.filter { $0.category == "negative" }.count, 15)
        XCTAssertEqual(held.filter { $0.category == "scenario" }.count, 15)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        XCTAssertTrue(Set(held.map(\.family)).isDisjoint(with: cases.filter { $0.split == "development" }.map(\.family)))
        let fixture = try XCTUnwrap(held.first)
        XCTAssertFalse(Self.matches(fixture, outcome: "handoff", handoffs: [.init(kind: .command, count: 1, text: "wrong")]))
        XCTAssertFalse(Self.matches(fixture, outcome: "candidate", handoffs: []))
        XCTAssertFalse(Self.matches(fixture, outcome: "discarded", handoffs: []))
    }
    func testRealJevUnderstandingOptIn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_VOICE_EVALUATION"] == "1" else { throw XCTSkip("Opt-in real Jev semantic evaluation; no credential access in default tests") }
        let split = env["JARVIS_VOICE_EVALUATION_SPLIT"] ?? "development"
        guard ["development", "heldout", "latency"].contains(split) else { XCTFail("Unknown evaluation split"); return }
        let key = try KeychainAPIKeyStore().read() ?? env["TYPESAFE_API_KEY"] ?? ""
        guard !key.isEmpty else { XCTFail("Requested real-model evaluation unmet: existing Jev credential unavailable"); return }
        let client = JevClient(apiKey: key)
        let all = try fixtures()
        let selected = split == "latency" ? Array(repeating: all.filter { $0.id.hasPrefix("development-") && $0.category == "valid" && $0.expectedKind == "command" }, count: 6).flatMap { $0 }.prefix(31).map { $0 } : all.filter { $0.split == split }
        let baseline = env["JARVIS_VOICE_BASELINE"] == "1"
        guard !baseline || split == "latency" else { XCTFail("Baseline comparison is limited to the matched latency workload"); return }
        let label = baseline ? "baseline-latency" : split
        let output = Self.root.appendingPathComponent(".context/voice/\(label)-results.jsonl")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        var correctValid = 0, totalValid = 0, failures = 0, criticalViolations = 0, mandatoryFailures = 0
        var warm: [Double] = []
        for (index, fixture) in selected.enumerated() {
            var calls = 0, models: [String] = [], handoffs: [SpeechIntent] = [], events: [String] = []
            var serviceFailure = false
            var judgments: [[String: String]] = []
            let evaluate: JevSpeechIntent.Evaluate = { state, questions in
                calls += 1
                do {
                    let result = try await client.systemOne(state: state, questions: questions)
                    models.append(result.response.model)
                    judgments.append(result.response.answers.reduce(into: [:]) { output, entry in
                        if case .choice(let choice, _, _) = entry.value { output[entry.key] = choice }
                    })
                    return result.response.answers
                } catch { serviceFailure = true; throw error }
            }
            let model = JevSpeechIntent(evaluate: evaluate)
            let oldModel = BaselineSpeechIntent(evaluate: evaluate)
            let coordinator = ContinuousIntentCoordinator(interpret: { words, final, context in
                if baseline {
                    if let intent = try await oldModel.next(words: words, final: final, context: context) { return .ready(intent) }
                    return .incomplete("Baseline wait")
                }
                return try await model.understand(words: words, final: final, context: context)
            }, submit: { handoffs.append($0) })
            coordinator.context = { fixture.context }
            coordinator.observe = { event, _ in events.append(event.rawValue) }
            coordinator.begin()
            let start = ProcessInfo.processInfo.systemUptime
            coordinator.record(.init(start: 0, end: 1, text: fixture.text, isFinal: true))
            coordinator.update(fixture.text, final: fixture.final)
            await coordinator.waitForPending()
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let outcome = coordinator.outcome == "candidate" && handoffs.isEmpty && coordinator.remainder.isEmpty ? "noRequest" : coordinator.outcome
            var payload: String?, payloadFailed = false
            if fixture.expectedPayload != nil, let intent = handoffs.first {
                do {
                    if intent.kind == .correction {
                        payload = try await model.textPayload(request: intent.text, purpose: "The complete replacement computer request, excluding the retraction of the previous request")
                    } else if [.dictate, .textEntry].contains(intent.kind) {
                        payload = try await model.extractText(request: intent.text, purpose: "Only the exact literal text to insert. Keep command-like words inside the content; exclude the instruction to dictate or type.").text
                    }
                }
                catch { payloadFailed = true }
            }
            let correct = Self.matches(fixture, outcome: outcome, handoffs: handoffs) && !payloadFailed && (fixture.expectedPayload == nil || payload == fixture.expectedPayload)
            if fixture.category == "valid" { totalValid += 1; if correct { correctValid += 1 } }
            if !correct {
                failures += 1
                if fixture.category != "valid" || fixture.id.hasPrefix("development-") { mandatoryFailures += 1 }
            }
            let critical = handoffs.count > 1 || (fixture.critical == "negation" && !handoffs.isEmpty) || ((fixture.critical == "literalControl" || fixture.expectedKind == "dictate" || fixture.expectedKind == "textEntry") && handoffs.contains { $0.kind == .stop || $0.kind == .stopAll || $0.kind == .correction })
            if critical { criticalViolations += 1 }
            if index > 0 && correct && !serviceFailure && fixture.category == "valid" { warm.append(elapsed) }
            let record: [String: Any] = ["caseID": fixture.id, "split": label, "sample": index, "category": fixture.category,
                "expectedOutcome": fixture.expectedOutcome, "expectedKind": fixture.expectedKind ?? "", "transcript": fixture.text,
                "revisionSequence": [["start": 0, "end": 1, "final": true]], "captureComplete": fixture.final,
                "outcome": outcome, "handoffs": handoffs.map { ["kind": $0.kind.rawValue, "text": $0.text] }, "events": events,
                "correct": correct, "critical": critical, "failureClass": correct ? "none" : (serviceFailure ? "service" : "semantic"),
                "milliseconds": elapsed, "calls": calls, "configuredModel": client.model, "returnedModels": models, "judgments": judgments, "cold": index == 0,
                "feedback": coordinator.error ?? coordinator.message, "literalPayload": payload ?? "", "expectedPayload": fixture.expectedPayload ?? ""]
            try log.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10]))
            print("VOICE_EVAL", split, fixture.id, correct ? "PASS" : "FAIL", outcome, Int(elapsed), "ms", "calls", calls)
        }
        let sorted = warm.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        print("VOICE_SUMMARY", split, "valid", correctValid, "/", totalValid, "failures", failures, "critical", criticalViolations, "warm", warm.count, "p95_ms", p95)
        XCTAssertEqual(criticalViolations, 0)
        if split == "heldout" {
            XCTAssertGreaterThanOrEqual(Double(correctValid) / Double(max(totalValid, 1)), 0.90)
            XCTAssertEqual(mandatoryFailures, 0, "Mandatory scenario/negative outcomes remain open; do not tune on held-out failures without replacing the set")
        } else if split == "latency" { XCTAssertGreaterThanOrEqual(warm.count, 30) }
        else {
            XCTAssertGreaterThanOrEqual(Double(correctValid) / Double(max(totalValid, 1)), 0.90)
            XCTAssertEqual(mandatoryFailures, 0, "Mandatory examples/negative/scenario failures remain open")
        }
    }
}

extension VoiceUnderstandingEvaluationTests {
    /// Real model answers with controlled delivery timing, not physical audio.
    func testRealJevRevisionDeliveryOptIn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["JARVIS_VOICE_TIMELINE_EVALUATION"] == "1" else { throw XCTSkip("Opt-in real Jev with simulated revision timing") }
        let key = try KeychainAPIKeyStore().read() ?? env["TYPESAFE_API_KEY"] ?? ""
        guard !key.isEmpty else { return XCTFail("Requested real timeline evaluation unmet: no configured Jev key") }
        let client = JevClient(apiKey: key)
        let output = Self.root.appendingPathComponent(".context/voice/real-model-timelines.jsonl")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let log = try FileHandle(forWritingTo: output); defer { try? log.close() }
        for scenario in ["sameTextFinality", "applicationRevision", "extendedQuery", "cancel", "newCapture", "negatedRevision"] {
            var release: CheckedContinuation<Void, Never>?, delayed = false, calls = 0
            var submitted: [SpeechIntent] = [], events: [String] = [], models: [String] = []
            let model = JevSpeechIntent(evaluate: { state, questions in
                calls += 1
                let result = try await client.systemOne(state: state, questions: questions)
                models.append(result.response.model)
                if !delayed {
                    delayed = true
                    await withCheckedContinuation { release = $0 }
                }
                return result.response.answers
            })
            let c = ContinuousIntentCoordinator(interpret: { try await model.understand(words: $0, final: $1, context: $2) }, submit: { submitted.append($0) })
            c.observe = { event, _ in events.append(event.rawValue) }
            let first = scenario == "extendedQuery" ? "Search for hiking boots" : "Open Notes"
            c.begin(); c.record(.init(start: 0, end: 1, text: first, isFinal: false)); c.update(first, final: false)
            for _ in 0..<1500 where release == nil && c.busy { try await Task.sleep(for: .milliseconds(10)) }
            guard let resume = release else { c.cancel(); XCTFail("Real model did not return the initial judgment for \(scenario)"); continue }
            let expected: String?
            switch scenario {
            case "cancel": c.cancel(); expected = nil
            case "newCapture":
                c.begin(); c.record(.init(start: 0, end: 1, text: "Open Maps", isFinal: true)); c.update("Open Maps", final: true); expected = "Open Maps"
            case "applicationRevision":
                c.record(.init(start: 0, end: 1, text: "Open Maps", isFinal: true)); c.update("Open Maps", final: true); expected = "Open Maps"
            case "extendedQuery":
                let text = first + " for rainy weather"
                c.record(.init(start: 0, end: 2, text: text, isFinal: true)); c.update(text, final: true); expected = text
            case "negatedRevision":
                c.record(.init(start: 0, end: 1, text: "Don't open Notes", isFinal: true)); c.update("Don't open Notes", final: true); expected = nil
            default:
                c.record(.init(start: 0, end: 1, text: first, isFinal: true)); c.update(first, final: false); expected = first
            }
            resume.resume(); await c.waitForPending()
            if scenario == "sameTextFinality" {
                c.update(first, final: true); await c.waitForPending()
            }
            for _ in 0..<100 where !events.contains("discarded") { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(events.contains("discarded"), "The superseded real response must be observed as discarded")
            let correct = submitted.map(\.text) == (expected.map { [$0] } ?? []) && submitted.allSatisfy { $0.kind == .command }
            XCTAssertTrue(correct, "\(scenario): wrong, stale, or duplicate handoff")
            let record: [String: Any] = ["scenario": scenario, "category": "real-model answers with simulated revision timing", "correct": correct,
                "handoffs": submitted.map { ["kind": $0.kind.rawValue, "text": $0.text] }, "events": events,
                "modelCalls": calls, "returnedModels": models, "injectedAnswers": false, "delayedDelivery": true]
            try log.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10]))
        }
    }
}
