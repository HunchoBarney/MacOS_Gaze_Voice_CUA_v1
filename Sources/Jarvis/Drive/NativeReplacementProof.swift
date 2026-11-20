import CoreGraphics
import Foundation
import JarvisCore

private struct NativeReplacementField: Sendable {
    let element: AXElement
    let fact: ObservedGoalProof.Fact
    let identity: NativeFieldIdentity

    static func select(task: TaskBrief, snapshot: AXSnapshot,
                       original: NativeDocumentSubject?) -> Self? {
        guard task.successContains.isEmpty, let window = task.window, snapshot.goalContextComplete,
              let original, original.window == window, original.fingerprint.count == 32,
              snapshot.nativeDocument == original else { return nil }
        let fields = snapshot.elements.filter {
            DriveCandidates.editableRoles.contains($0.role.lowercased().replacingOccurrences(of: "ax", with: ""))
                && !DriveCandidates.isSecure(role: $0.role, label: $0.label)
        }
        guard fields.count == 1, let element = fields.first, element.index >= 0,
              element.value != nil, let identity = element.nativeIdentity,
              element.nativeValue?.window == window, element.nativeValue?.document == original,
              let frame = element.frame, frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
        let facts = ObservedGoalProof.facts(in: snapshot).filter {
            $0.kind == .value && $0.node.index == element.index
                && $0.node.role == element.role
                && $0.content.utf8.elementsEqual(element.value!.utf8)
        }
        guard facts.count == 1, let fact = facts.first else { return nil }
        return Self(element: element, fact: fact, identity: identity)
    }
}

struct NativeReplacementBinding: Sendable {
    private let field: NativeReplacementField
    let snapshotID: String
    let document: NativeDocumentSubject
    let literalKey: String
    let literal: String
    let task: TaskBrief
    let stepIndex: Int

    var index: Int { field.element.index }
    var role: String { field.element.role }
    var factID: String { field.fact.id }
    var identity: NativeFieldIdentity { field.identity }
    var changesValue: Bool { !field.fact.content.utf8.elementsEqual(literal.utf8) }

    static func make(observation: TaskObservation, request: ActuationRequest) -> Self? {
        guard request.effect == .tool, request.tool == "set_value",
              observation.task.values.count == 1, let source = observation.task.values.first,
              let text = request.args["value"]?.string, text.utf8.elementsEqual(source.value.utf8),
              let snapshot = observation.axSnapshot, let sid = snapshot.snapshotID, !sid.isEmpty,
              let document = observation.nativeDocumentAnchor,
              let field = NativeReplacementField.select(task: observation.task, snapshot: snapshot,
                                                        original: document) else { return nil }
        let addressed: Bool
        if let token = field.element.token {
            addressed = request.args["element_token"]?.string == token
        } else {
            addressed = request.args["element_index"]?.integer == field.element.index
                && request.args["snapshot_id"]?.string == sid
        }
        guard addressed else { return nil }
        return Self(field: field, snapshotID: sid, document: document,
            literalKey: source.key, literal: text, task: observation.task, stepIndex: observation.stepIndex)
    }

    func freshFact(task: TaskBrief, snapshot: AXSnapshot,
                   original: NativeDocumentSubject?) -> ObservedGoalProof.Fact? {
        guard task == self.task, original == document,
              task.values.count == 1, let current = task.values[literalKey],
              current.utf8.elementsEqual(literal.utf8),
              let sid = snapshot.snapshotID, !sid.isEmpty, sid != snapshotID,
              let read = NativeReplacementField.select(task: task, snapshot: snapshot, original: original),
              read.identity == identity, read.element.index == index,
              read.element.role == role, read.fact.id == factID,
              read.element.frame == field.element.frame,
              read.element.nativeAncestorRoles == field.element.nativeAncestorRoles,
              read.fact.content.utf8.elementsEqual(literal.utf8) else { return nil }
        return read.fact
    }
}

struct NativeReplacementProposal: Sendable, Equatable {
    let candidateID: String
    let snapshotID: String
    let index: Int
    let factID: String
    let role: String
    let identity: NativeFieldIdentity
    let document: NativeDocumentSubject
    let literalKey: String
    let literal: String
    let task: TaskBrief
    let stepIndex: Int
    let model: String
    let selection: Double

    static func make(observation: TaskObservation, request: ActuationRequest,
                     candidateID: String, model: String, selection: Double) -> Self? {
        guard model == "jev-1.14.0", selection.isFinite, (0.9...1).contains(selection),
              let binding = NativeReplacementBinding.make(observation: observation, request: request),
              candidateID == "v\(binding.index)" else { return nil }
        return Self(candidateID: candidateID, snapshotID: binding.snapshotID, index: binding.index,
            factID: binding.factID, role: binding.role, identity: binding.identity, document: binding.document,
            literalKey: binding.literalKey, literal: binding.literal, task: binding.task, stepIndex: binding.stepIndex,
            model: model, selection: selection)
    }

    func authorizes(_ request: ActuationRequest, observation: TaskObservation) -> Bool {
        guard let window = task.window,
              request.args["pid"]?.integer == window.pid,
              request.args["window_id"]?.integer == window.windowID,
              let current = Self.make(observation: observation, request: request,
                  candidateID: candidateID, model: model, selection: selection) else { return false }
        return current == self && current.literal.utf8.elementsEqual(literal.utf8)
    }
}

private func replacementFactFields(_ fact: ObservedGoalProof.Fact,
                                   literalKey: String) -> [String: JSONValue] {
    ["executed_replacement": .object([
        "fact": fact.json, "actual_operation": .string("set_value"),
        "literal_source": .string("caller_value"), "literal_key": .string(literalKey),
        "full_native_value_equals_literal": .bool(true),
        "original_subject_unchanged": .bool(true),
        "native_window_context_complete": .bool(true),
        "native_public_editable_field_count": .number(1),
        "native_field_unchanged_since_replacement": .bool(true),
        "native_original_document_unchanged": .bool(true),
    ])]
}

extension DeliveredReplacementObservation {
    func fields(observation: TaskObservation) -> [String: JSONValue] {
        guard observation.stepIndex > binding.stepIndex, let snapshot = observation.axSnapshot,
              let fact = binding.freshFact(task: observation.task, snapshot: snapshot,
                                          original: observation.nativeDocumentAnchor) else { return [:] }
        return replacementFactFields(fact, literalKey: binding.literalKey)
    }
}

struct NativeReplacementCandidate: Sendable {
    let receipt: NativeReplacementReceipt
    let snapshotID: String
    let fact: ObservedGoalProof.Fact

    static func make(observation: TaskObservation) -> Self? {
        guard let receipt = observation.replacementReceipt,
              observation.stepIndex > receipt.proposal.stepIndex,
              let snapshot = observation.axSnapshot else { return nil }
        return make(task: observation.task, snapshot: snapshot,
                    original: observation.nativeDocumentAnchor, receipt: receipt)
    }

    static func make(task: TaskBrief, snapshot: AXSnapshot, original: NativeDocumentSubject?,
                     receipt: NativeReplacementReceipt) -> Self? {
        let proposal = receipt.proposal
        guard task == proposal.task, original == proposal.document,
              task.values.count == 1, let literal = task.values[proposal.literalKey],
              literal.utf8.elementsEqual(proposal.literal.utf8),
              let sid = snapshot.snapshotID, !sid.isEmpty,
              let field = NativeReplacementField.select(task: task, snapshot: snapshot, original: original),
              field.identity == proposal.identity, field.element.index == proposal.index,
              field.element.role == proposal.role, field.fact.id == proposal.factID,
              field.fact.content.utf8.elementsEqual(proposal.literal.utf8) else { return nil }
        return Self(receipt: receipt, snapshotID: sid, fact: field.fact)
    }

    var fields: [String: JSONValue] {
        var fields = replacementFactFields(fact, literalKey: receipt.proposal.literalKey)
        fields["_exact_replacement"] = .object([
            "receipt_id": .string(receipt.id.uuidString),
            "snapshot_id": .string(snapshotID), "fact_id": .string(fact.id),
        ])
        return fields
    }
}

struct NativeReplacementVotes: Sendable, Equatable {
    var receiptID: UUID
    var snapshotID: String
    var factID: String
    var model: String
    var scope: Double
    var target: Double
    var literalIntent: Double

    var strong: Bool {
        model == "jev-1.14.0"
            && [scope, target, literalIntent].allSatisfy { $0.isFinite && (0.95...1).contains($0) }
    }
}

struct NativeReplacementEvidence: Sendable, Equatable {
    let receipt: NativeReplacementReceipt
    let votes: NativeReplacementVotes
    let broadCompletion: Double?
    let broadSupport: Double?

    func valid(snapshotID: String, factID: String) -> Bool {
        votes.strong && votes.receiptID == receipt.id && votes.snapshotID == snapshotID
            && votes.factID == factID
            && [broadCompletion, broadSupport].compactMap { $0 }.allSatisfy {
                $0.isFinite && (0.3...1).contains($0)
            }
    }

    func matches(task: TaskBrief, snapshot: AXSnapshot) -> Bool {
        NativeReplacementCandidate.make(task: task, snapshot: snapshot,
            original: receipt.proposal.document, receipt: receipt)?.fact.id == votes.factID
    }
}
