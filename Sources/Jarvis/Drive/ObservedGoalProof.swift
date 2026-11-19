import CoreGraphics
import Foundation
import JarvisCore

struct ObservedGoalProof: Sendable, Equatable {
    enum Basis: String, Sendable { case general, exactReplacement }
    struct Node: Sendable, Equatable {
        var index: Int
        var role: String
        var label: String
        var value: String?
        var bounds: CGRect?
        var actions: [String]
        var nativeValue: NativeFieldProvenance?
        var nativeAncestorRoles: [String]?

        init(_ element: AXElement) {
            let secure = DriveCandidates.isSecure(role: element.role, label: element.label)
            index = element.index
            role = element.role
            label = secure ? "[secure]" : element.label
            value = secure ? nil : element.value
            bounds = element.frame
            actions = element.actions.sorted()
            nativeValue = secure ? nil : element.nativeValue
            nativeAncestorRoles = secure ? nil : element.nativeAncestorRoles
        }
    }

    struct Context: Sendable, Equatable {
        var title: String?
        var nodes: [Node]
        var nativeDocument: NativeDocumentSubject?

        init(_ snapshot: AXSnapshot) {
            title = snapshot.windowTitle
            nodes = snapshot.elements.map(Node.init).sorted { $0.index < $1.index }
            nativeDocument = snapshot.nativeDocument
        }
    }

    struct Fact: Sendable, Equatable {
        enum Kind: String, Sendable { case readOnlyLabel, value, identifier }
        var id: String
        var node: Node
        var kind: Kind

        var content: String { kind == .readOnlyLabel ? node.label : node.value ?? "" }

        var json: JSONValue {
            var fields: [String: JSONValue] = [
                "index": .number(Double(node.index)), "role": .string(node.role),
                "label": .string(node.label), "kind": .string(kind.rawValue),
                "observed": .string(content),
            ]
            if let bounds = node.bounds,
               bounds.minX.isFinite, bounds.minY.isFinite,
               bounds.width.isFinite, bounds.height.isFinite {
                fields["bounds"] = .object([
                    "x": .number(bounds.minX), "y": .number(bounds.minY),
                    "width": .number(bounds.width), "height": .number(bounds.height),
                ])
            }
            if kind == .value, let native = node.nativeValue {
                fields["native_value"] = .object([
                    "source": .string("native_ax_value"), "extent": .string("entire_field"),
                    "document_associated": .bool(native.document.map {
                        $0.window == native.window && $0.fingerprint.count == 32
                    } ?? false),
                ])
            }
            if let roles = node.nativeAncestorRoles {
                fields["native_ancestor_roles"] = .array(roles.map(JSONValue.string))
            }
            return .object(fields)
        }
    }

    var task: TaskBrief
    var snapshotID: String
    var context: Context
    var fact: Fact
    var model: String
    var completionProbability: Double?
    var selectionProbability: Double?
    var supportProbability: Double?
    var basis: Basis = .general
    var replacement: NativeReplacementEvidence? = nil

    init?(task: TaskBrief, snapshot: AXSnapshot, factID: String, model: String,
          completion: Double, selection: Double, support: Double) {
        guard task.successContains.isEmpty, task.window != nil, snapshot.goalContextComplete,
              let snapshotID = snapshot.snapshotID, !snapshotID.isEmpty,
              let fact = Self.facts(in: snapshot).first(where: { $0.id == factID }) else { return nil }
        if let subject = snapshot.nativeDocument,
           subject.window != task.window || subject.fingerprint.count != 32 { return nil }
        guard snapshot.elements.allSatisfy({
            guard let native = $0.nativeValue else { return true }
            return native.window == task.window
                && (native.document == nil || native.document == snapshot.nativeDocument)
        }) else { return nil }
        self.task = task
        self.snapshotID = snapshotID
        context = Context(snapshot)
        self.fact = fact
        self.model = model
        completionProbability = completion
        selectionProbability = selection
        supportProbability = support
        guard scoresValid else { return nil }
    }

    private var scoresValid: Bool {
        guard model == "jev-1.14.0" else { return false }
        if basis == .exactReplacement {
            return completionProbability == nil && selectionProbability == nil && supportProbability == nil
                && replacement?.votes.model == model
                && replacement?.valid(snapshotID: snapshotID, factID: fact.id) == true
        }
        guard replacement == nil, let completionProbability, let selectionProbability,
              let supportProbability else { return false }
        return completionProbability.isFinite && (0.95...1).contains(completionProbability)
            && selectionProbability.isFinite && (0.9...1).contains(selectionProbability)
            && supportProbability.isFinite && (0.9...1).contains(supportProbability)
    }

    init?(exactReplacement observation: TaskObservation, votes: NativeReplacementVotes,
          broadCompletion: Double?, broadSupport: Double?) {
        guard let snapshot = observation.axSnapshot,
              let candidate = NativeReplacementCandidate.make(observation: observation) else { return nil }
        task = observation.task
        snapshotID = candidate.snapshotID
        context = Context(snapshot)
        fact = candidate.fact
        model = votes.model
        completionProbability = nil
        selectionProbability = nil
        supportProbability = nil
        basis = .exactReplacement
        replacement = NativeReplacementEvidence(receipt: candidate.receipt, votes: votes,
            broadCompletion: broadCompletion, broadSupport: broadSupport)
        guard scoresValid else { return nil }
    }

    func matches(task: TaskBrief, snapshot: AXSnapshot?, requireOrigin: Bool = false) -> Bool {
        guard scoresValid, self.task == task, task.successContains.isEmpty,
              let snapshot, snapshot.goalContextComplete,
              !requireOrigin || snapshot.snapshotID == snapshotID else { return false }
        guard Context(snapshot) == context, Self.facts(in: snapshot).contains(fact) else { return false }
        return basis == .general || replacement?.matches(task: task, snapshot: snapshot) == true
    }

    /// `id=` tokens exist only in tree_markdown — the elements array never
    /// carries AXIdentifier — yet controls often encode live state there
    /// ("Mode: scientific"). Recover them as evidence: element index → id.
    static func markdownIdentifiers(in markdown: String) -> [Int: String] {
        var identifiers: [Int: String] = [:]
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let open = line.range(of: "- ["),
                  let close = line[open.upperBound...].firstIndex(of: "]"),
                  let index = Int(line[open.upperBound..<close]),
                  let idStart = line.range(of: " [id=", range: close..<line.endIndex)
            else { continue }
            let tail = line[idStart.upperBound...]
            var end = tail.endIndex
            for marker in [" help=", " actions=", " custom_actions=", "]"] {
                if let hit = tail.range(of: marker), hit.lowerBound < end { end = hit.lowerBound }
            }
            let identifier = tail[..<end].trimmingCharacters(in: .whitespaces)
            if !identifier.isEmpty { identifiers[index] = identifier }
        }
        return identifiers
    }

    static func facts(in snapshot: AXSnapshot) -> [Fact] {
        let labels = Set(["statictext", "heading", "paragraph", "label", "group", "cell", "row", "image"])
        let values = Set(DriveCandidates.editableRoles + [
            "statictext", "heading", "paragraph", "label", "cell", "row",
            "checkbox", "radiobutton", "switch", "slider", "progressindicator", "popupbutton",
        ])
        let identifiers = markdownIdentifiers(in: snapshot.treeMarkdown)
        return snapshot.elements.enumerated().flatMap { position, element -> [Fact] in
            guard !DriveCandidates.isSecure(role: element.role, label: element.label) else { return [] }
            let role = element.role.lowercased().replacingOccurrences(of: "ax", with: "")
            let node = Node(element)
            var result: [Fact] = []
            if values.contains(role), let value = element.value,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || DriveCandidates.editableRoles.contains(role) {
                result.append(Fact(id: "value:\(position)", node: node, kind: .value))
            }
            if labels.contains(role), element.actions.allSatisfy({ ["AXShowMenu", "AXCopy"].contains($0) }),
               !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               element.label != element.value {
                result.append(Fact(id: "label:\(position)", node: node, kind: .readOnlyLabel))
            }
            if let identifier = identifiers[element.index],
               identifier.range(of: "[:;=]", options: .regularExpression) != nil {
                var probe = element
                probe.value = identifier
                result.append(Fact(id: "identifier:\(element.index)", node: Node(probe), kind: .identifier))
            }
            return result
        }
    }

    static func choiceState(snapshot: AXSnapshot, task: TaskBrief,
                            originalDocument: NativeDocumentSubject? = nil) -> [String: JSONValue] {
        let current = snapshot.nativeDocument.flatMap {
            $0.window == task.window && $0.fingerprint.count == 32 && snapshot.goalContextComplete ? $0 : nil
        }
        let original = originalDocument.flatMap {
            $0.window == task.window && $0.fingerprint.count == 32 ? $0 : nil
        }
        let allFacts = facts(in: snapshot)
        let factLimit = 120
        return [
            "_observed_goal_allowed": .bool(task.successContains.isEmpty && task.window != nil
                                          && snapshot.goalContextComplete),
            "_goal_facts": .object(Dictionary(uniqueKeysWithValues:
                allFacts.prefix(factLimit).map { ($0.id, $0.json) })),
            "_goal_facts_omitted": .number(Double(max(0, allFacts.count - factLimit))),
            "native_document_context": .object([
                "current_known": .bool(current != nil),
                "original_known": .bool(original != nil),
                "original_unchanged": .bool(current != nil && current == original),
            ]),
        ]
    }
}
