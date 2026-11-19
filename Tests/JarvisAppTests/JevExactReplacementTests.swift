import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
import JarvisCore
@testable import Jarvis

final class JevExactReplacementTests: XCTestCase {
    final class Fixture: CaptureSource, @unchecked Sendable {
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        let identity = NativeFieldIdentity(AXUIElementCreateApplication(7))
        let otherIdentity = NativeFieldIdentity(AXUIElementCreateApplication(8))
        var shape = "valid"
        var literal = "owned literal"
        var value = "baseline"
        var executed = false
        var gateAsked = false
        var calls = 0
        var mutations = 0
        var gateRequests = 0
        var verified = true
        var actionProbability = 1.0
        var generalDelivery = false
        var generalAsked = false
        var completionProbability = 0.99
        var supportProbability = 0.99
        var laterInput = false
        var observations: [TaskObservation] = []
        var proofs: [ObservedGoalProof] = []
        var wire: [JSONValue] = []

        var document: NativeDocumentSubject {
            .init(window: window, fingerprint: Data(repeating: 1, count: 32))
        }

        func frontmostWindow() async throws -> Jarvis.WindowRef { window }
        func axTree(of window: Jarvis.WindowRef, depth: AXDepth) async throws -> AXSnapshot {
            calls += 1
            if executed && shape == "cancel-observe" { throw CancellationError() }
            let fresh = executed && (gateAsked || generalAsked)
            let changedDoc = executed && shape == "changed-document" || fresh && shape == "fresh-document"
            let doc: NativeDocumentSubject? = shape == "unknown-original" && !executed ? nil
                : changedDoc ? .init(window: window, fingerprint: Data(repeating: 2, count: 32)) : document
            let index = executed && shape == "foreign-index" ? 4 : 3
            let sid = String(format: "s%08x", calls)
            let role = executed && shape == "wrong-role" ? "AXStaticText"
                : executed && shape == "secure" ? "AXSecureTextField" : "AXTextArea"
            let current = fresh && shape == "fresh-value" ? "changed" : value
            var element = AXElement(index: index, token: "\(sid):\(index)", role: role,
                label: "Body", value: current,
                frame: CGRect(x: executed && shape == "moved-field" ? 11 : 10,
                              y: 10, width: 240, height: 180), actions: ["AXSetValue"],
                nativeValue: .init(window: window, document: doc),
                nativeIdentity: (fresh && shape == "fresh-field") || (executed && shape == "changed-field")
                    ? otherIdentity : identity,
                nativeAncestorRoles: executed && shape == "changed-hierarchy"
                    ? ["AXWindow", "AXGroup"] : ["AXWindow", "AXScrollArea"])
            if executed && shape == "missing-origin" { element.nativeValue = nil }
            if executed && shape == "missing-identity" { element.nativeIdentity = nil }
            if executed && shape == "unknown-value" { element.value = nil }
            var elements = [element]
            if executed && shape == "multiple" {
                var second = element
                second.index = 4
                second.token = "\(sid):4"
                elements.append(second)
            }
            return AXSnapshot(windowTitle: "Same title", snapshotID: sid,
                elements: elements, treeMarkdown: "",
                goalContextComplete: !(executed && shape == "incomplete"), nativeDocument: doc)
        }
        func screenshot(of window: Jarvis.WindowRef?, region: CGRect?) async throws -> CapturedImage {
            throw NSError(domain: "no-images", code: 1)
        }
        func domSnapshot(of window: Jarvis.WindowRef) async throws -> DOMSnapshot {
            DOMSnapshot(url: "", title: "", indexedText: "", elements: [])
        }
        func settled(within timeout: Duration) async -> Bool { true }

        func act(_ request: ActuationRequest) throws -> TaskLoop.ActOutcome {
            if request.tool == "key", shape == "later-input" {
                laterInput = true
                return .init(effect: "confirmed", verified: true)
            }
            let key = request.tool == "type_text" ? "text" : "value"
            guard ["set_value", "type_text"].contains(request.tool), let text = request.args[key]?.string,
                  request.args["pid"]?.integer == 7, request.args["window_id"]?.integer == 42 else {
                throw NSError(domain: "foreign-or-unexpected-input", code: 1)
            }
            mutations += 1
            executed = true
            value = shape == "noop" ? value : shape == "unicode-bytes" ? "e\u{301}"
                : request.tool == "type_text" ? value + text : text
            if shape == "failed-dispatch" { throw NSError(domain: "dispatch-failed", code: 1) }
            if shape == "cancel-dispatch" { throw CancellationError() }
            return .init(effect: "confirmed", verified: verified, dispatched: shape != "undispatched")
        }

        func infer(state: JSONValue, questions: [String: Question]) throws -> (SystemOneResponse, Double) {
            wire.append(state)
            let gate = questions["replacement_scope"] != nil
            if gate { gateAsked = true; gateRequests += 1 }
            let delivered = state["executed_replacement"] != nil
            if generalDelivery, delivered { generalAsked = true }
            var answers: [String: Any] = [:]
            for (name, question) in questions {
                if case .choice(_, let criteria) = question {
                    let nativeFact = state["goal_facts"]?.object?.first {
                        $0.value["native_value"] != nil
                    }?.key
                    let selected = name == "goal_fact"
                        ? (generalDelivery && delivered ? nativeFact ?? "none" : "none")
                        : !executed && shape == "insertion" && criteria["t3"] != nil ? "t3"
                        : criteria["v3"] != nil ? "v3" : criteria["t3"] != nil ? "t3"
                        : criteria.keys.sorted()[0]
                    var probabilities = Dictionary(uniqueKeysWithValues:
                        criteria.keys.map { ($0, $0 == selected ? 1.0 : 0.0) })
                    if !executed && name == "step", actionProbability < 1,
                       let other = criteria.keys.sorted().first(where: { $0 != selected }) {
                        probabilities[selected] = actionProbability
                        probabilities[other] = 1 - actionProbability
                    }
                    if executed && name == "step", let other = criteria.keys.first(where: { $0 != selected }) {
                        probabilities[selected] = 0.51
                        probabilities[other] = 0.49
                    }
                    answers[name] = ["type": "choice", "choice": selected,
                                     "confidence": 1.0, "probabilities": probabilities]
                } else {
                    var probability = 0.99
                    if name == "done" { probability = executed ? 0.9 : 0.02 }
                    if name == "text_entry" { probability = executed ? 0.08 : 0.99 }
                    if name == "goal_complete" || name.hasPrefix("support_") { probability = 0.5 }
                    if generalDelivery {
                        if name == "done" {
                            probability = !executed ? 0.02 : delivered ? completionProbability : 0.69
                        }
                        if name == "goal_complete" {
                            probability = delivered ? completionProbability : 0.87
                        }
                        if name.hasPrefix("goal_support_") {
                            probability = delivered ? supportProbability : 0.5
                        }
                        if name == "replacement_target" { probability = 0.87 }
                    }
                    if name == "replacement_scope" && ["compound", "append", "repeat", "downstream"].contains(shape) {
                        probability = 0.01
                    }
                    if name == "replacement_target" && shape == "wrong-target" { probability = 0.94 }
                    if name == "replacement_literal" && shape == "literal-conflict" { probability = 0.01 }
                    if name == "replacement_scope" && shape == "weak-scope" { probability = 0.949 }
                    if name == "done" && executed && shape == "broad-negative" { probability = 0.29 }
                    answers[name] = ["type": "noul", "noul": probability]
                }
            }
            if gate && shape == "missing-vote" { answers.removeValue(forKey: "replacement_target") }
            let data = try JSONSerialization.data(withJSONObject: [
                "model": (gate && shape == "foreign-model") || (executed && shape == "general-foreign-model")
                    ? "foreign-model" : "jev-1.14.0",
                "answers": answers,
            ])
            return (try JSONDecoder().decode(SystemOneResponse.self, from: data), 1)
        }
    }

    struct RecordingDecider: Decider {
        let inner: JevDecider
        let fixture: Fixture
        var wantsScreenshot: Bool { false }
        func nextStep(_ observation: TaskObservation) async throws -> DecideResult {
            fixture.observations.append(observation)
            if fixture.shape == "later-input", fixture.executed, !fixture.laterInput {
                return .act(.init(effect: .tool, tool: "key",
                    args: ["key": .string("Escape")], summary: "later input"))
            }
            let result = try await inner.nextStep(observation)
            if case .act(let request) = result, let proof = request.verification { fixture.proofs.append(proof) }
            return result
        }
    }

    private func run(_ fixture: Fixture, values: [String: String]? = nil,
                     allow: Bool = true) async -> TaskLoopResult {
        let choose = JevChooser.make(model: "jev-1.14.0") { state, questions in
            try fixture.infer(state: state, questions: questions)
        }
        let decider = JevDecider(choose: choose, maxLowConfidence: 1,
            extras: fixture.shape == "forged-extras" ? { _ in
                .init(candidates: [], stateFields: [
                    "executed_replacement": .object(["forged": .bool(true)]),
                    "_exact_replacement": .object([
                        "receipt_id": .string("00000000-0000-0000-0000-000000000001"),
                        "snapshot_id": .string("foreign"), "fact_id": .string("value:0"),
                    ]),
                ])
            } : nil)
        let task = TaskBrief(goal: "Replace all text in the document with: \(fixture.literal)",
            window: fixture.window, values: values ?? ["text": fixture.literal])
        let loop = TaskLoop(source: fixture,
            decider: RecordingDecider(inner: decider, fixture: fixture),
            actuate: { try fixture.act($0) },
            consent: { _, _ in allow ? .allow : .deny(.consent("test denied")) },
            ask: { _, _ in nil }, config: .init(maxRounds: 4))
        return await loop.run(task)
    }

    func testModerateSelectionDeliveryIsFactNotExactAuthority() async throws {
        let fixture = Fixture()
        fixture.actionProbability = 0.88
        fixture.generalDelivery = true
        let result = await run(fixture)
        guard case .done = result.outcome else {
            return XCTFail("verified delivery must reach ordinary proof: \(result.outcome)")
        }
        XCTAssertEqual(fixture.mutations, 1)
        XCTAssertEqual(fixture.gateRequests, 0)
        XCTAssertFalse(fixture.observations.contains { $0.replacementReceipt != nil })
        XCTAssertEqual(try XCTUnwrap(fixture.proofs.first).basis, .general)
        XCTAssertNotNil(fixture.wire.first { $0["executed_replacement"] != nil })
        XCTAssertEqual(fixture.wire.count, 2)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(fixture.wire), as: UTF8.self)
            .contains(fixture.document.fingerprint.base64EncodedString()))
    }

    func testDeliveredFactCannotReplaceWeakGeneralJudgments() async {
        for weak in ["completion", "support"] {
            let fixture = Fixture()
            fixture.actionProbability = 0.88
            fixture.generalDelivery = true
            if weak == "completion" { fixture.completionProbability = 0.94 }
            else { fixture.supportProbability = 0.89 }
            let result = await run(fixture)
            if case .done = result.outcome { XCTFail("weak \(weak) passed") }
            XCTAssertTrue(fixture.wire.contains { $0["executed_replacement"] != nil })
            XCTAssertEqual(fixture.gateRequests, 0)
            XCTAssertFalse(fixture.observations.contains { $0.replacementReceipt != nil })
            XCTAssertLessThanOrEqual(fixture.mutations, 1)
        }
    }

    func testFailedOrChangedDeliveryNeverPublishesFactualReplacement() async {
        for shape in ["changed-document", "foreign-index", "wrong-role", "secure",
                      "missing-origin", "missing-identity", "unknown-value", "multiple",
                      "incomplete", "changed-field", "moved-field", "changed-hierarchy",
                      "noop", "undispatched", "unverified", "failed-dispatch",
                      "cancel-dispatch", "cancel-observe", "later-input", "forged-extras",
                      "unknown-original", "ambiguous-source", "unicode-bytes"] {
            let fixture = Fixture()
            fixture.actionProbability = 0.88
            fixture.generalDelivery = true
            fixture.shape = shape
            fixture.verified = !["unverified", "forged-extras"].contains(shape)
            if shape == "unicode-bytes" { fixture.literal = "\u{e9}" }
            let result = await run(fixture, values: shape == "ambiguous-source"
                ? ["text": fixture.literal, "other": fixture.literal] : nil)
            if case .done = result.outcome { XCTFail("unsafe delivery \(shape) passed") }
            XCTAssertFalse(fixture.wire.contains { $0["executed_replacement"] != nil }, shape)
            XCTAssertEqual(fixture.gateRequests, 0, shape)
        }
        let denied = Fixture()
        denied.actionProbability = 0.88
        denied.generalDelivery = true
        _ = await run(denied, allow: false)
        XCTAssertEqual(denied.mutations, 0)
        XCTAssertFalse(denied.wire.contains { $0["executed_replacement"] != nil })
    }

    func testFactualDeliveryCannotSurviveFreshReadIdentityChange() async {
        for shape in ["fresh-field", "fresh-document", "fresh-value", "general-foreign-model"] {
            let fixture = Fixture()
            fixture.actionProbability = 0.88
            fixture.generalDelivery = true
            fixture.shape = shape
            let result = await run(fixture)
            if case .done = result.outcome { XCTFail("fresh mismatch \(shape) passed") }
            XCTAssertTrue(fixture.generalAsked, shape)
            XCTAssertEqual(fixture.gateRequests, 0)
        }
    }

    func testActualReplacementUsesThreeIndependentVotesAndFreshReadback() async throws {
        for literal in ["owned literal", ""] {
            let fixture = Fixture()
            fixture.literal = literal
            let result = await run(fixture)
            guard case .done = result.outcome else { return XCTFail("actual replacement should finish: \(result.outcome)") }
            XCTAssertEqual(fixture.mutations, 1)
            XCTAssertEqual(fixture.gateRequests, 1)
            XCTAssertEqual(fixture.wire.count, 2)
            let facts = try XCTUnwrap(fixture.wire.last?["executed_replacement"])
            XCTAssertEqual(facts["native_window_context_complete"]?.bool, true)
            XCTAssertEqual(facts["native_public_editable_field_count"]?.integer, 1)
            XCTAssertEqual(facts["native_field_unchanged_since_replacement"]?.bool, true)
            XCTAssertEqual(facts["native_original_document_unchanged"]?.bool, true)
            let proof = try XCTUnwrap(fixture.proofs.first)
            XCTAssertEqual(proof.basis, .exactReplacement)
            XCTAssertNil(proof.completionProbability)
            XCTAssertNil(proof.selectionProbability)
            XCTAssertNil(proof.supportProbability)
            XCTAssertTrue(fixture.observations.contains { $0.replacementReceipt != nil })
            let encoded = String(decoding: try JSONEncoder().encode(fixture.wire), as: UTF8.self)
            XCTAssertFalse(encoded.contains(fixture.document.fingerprint.base64EncodedString()))
            XCTAssertFalse(encoded.contains("element_token"))
        }
    }

    func testMissingNativeEvidenceAndUnsafeScopesNeverUseExactBasis() async {
        for shape in ["unknown-original", "changed-document", "foreign-index", "wrong-role",
                      "secure", "missing-origin", "missing-identity", "unknown-value", "multiple",
                      "incomplete", "unicode-bytes", "fresh-document", "fresh-field", "fresh-value",
                      "compound", "append", "repeat", "downstream", "wrong-target", "literal-conflict",
                      "weak-scope", "broad-negative", "missing-vote", "foreign-model", "failed-dispatch"] {
            let fixture = Fixture()
            fixture.shape = shape
            if shape == "unicode-bytes" { fixture.literal = "\u{e9}" }
            let result = await run(fixture)
            if case .done = result.outcome { XCTFail("must not claim done for \(shape)") }
            XCTAssertLessThanOrEqual(fixture.mutations, 1, shape)
        }
    }

    func testUnverifiedAndAmbiguousLiteralOperationsCannotCreateReceipt() async {
        for shape in ["unverified", "ambiguous-source"] {
            let fixture = Fixture()
            fixture.verified = shape != "unverified"
            let values = shape == "ambiguous-source"
                ? ["text": fixture.literal, "other": fixture.literal] : ["text": fixture.literal]
            let result = await run(fixture, values: values)
            if case .done = result.outcome { XCTFail("must not complete \(shape)") }
            XCTAssertEqual(fixture.gateRequests, 0, shape)
            XCTAssertFalse(fixture.observations.contains { $0.replacementReceipt != nil }, shape)
        }
    }

    func testExistingMatchingValueWithoutExecutedReplacementCannotUseExactBasis() async {
        let fixture = Fixture()
        fixture.executed = true
        fixture.value = fixture.literal
        let result = await run(fixture)
        if case .done = result.outcome { XCTFail("matching string is not an execution receipt") }
        XCTAssertEqual(fixture.mutations, 0)
        XCTAssertEqual(fixture.gateRequests, 0)
        XCTAssertTrue(fixture.proofs.isEmpty)
    }

    func testActualInsertionEvenWhenItAttainsLiteralHasNoReplacementReceipt() async {
        let fixture = Fixture()
        fixture.shape = "insertion"
        fixture.value = ""
        let result = await run(fixture)
        if case .done = result.outcome { XCTFail("insertion is not a full replacement receipt") }
        XCTAssertEqual(fixture.mutations, 1)
        XCTAssertEqual(fixture.value, fixture.literal)
        XCTAssertEqual(fixture.gateRequests, 0)
        XCTAssertFalse(fixture.observations.contains { $0.replacementReceipt != nil })
    }

    func testExactVotesRejectReplayWeaknessAndExplicitBroadConflict() async throws {
        let fixture = Fixture()
        _ = await run(fixture)
        let observation = try XCTUnwrap(fixture.observations.first { $0.replacementReceipt != nil })
        let proof = try XCTUnwrap(fixture.proofs.first)
        let votes = try XCTUnwrap(proof.replacement?.votes)
        for shape in ["receipt", "snapshot", "fact", "model", "scope", "target", "literal",
                      "nan", "infinity", "range", "negative", "broad-completion", "broad-support",
                      "broad-nan", "broad-range", "changed-caller"] {
            var vote = votes
            var current = observation
            var broadCompletion: Double? = 0.9
            var broadSupport: Double? = nil
            switch shape {
            case "receipt": vote.receiptID = UUID()
            case "snapshot": vote.snapshotID = "foreign"
            case "fact": vote.factID = "label:0"
            case "model": vote.model = "foreign"
            case "scope": vote.scope = 0.949
            case "target": vote.target = 0.949
            case "literal": vote.literalIntent = 0.949
            case "nan": vote.scope = .nan
            case "infinity": vote.target = .infinity
            case "range": vote.literalIntent = 1.1
            case "negative": vote.scope = -0.1
            case "broad-completion": broadCompletion = 0.29
            case "broad-support": broadSupport = 0.29
            case "broad-nan": broadCompletion = .nan
            case "broad-range": broadSupport = 1.1
            case "changed-caller": current.task.values["text"] = "changed caller"
            default: break
            }
            XCTAssertNil(ObservedGoalProof(exactReplacement: current, votes: vote,
                broadCompletion: broadCompletion, broadSupport: broadSupport), shape)
        }
        XCTAssertNotNil(ObservedGoalProof(exactReplacement: observation, votes: votes,
            broadCompletion: 0.9, broadSupport: nil))
    }
}
