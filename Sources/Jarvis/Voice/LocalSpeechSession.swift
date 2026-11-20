import Foundation
import JarvisCore

/// Observed identities, not a vocabulary supplied with expected ASR answers.
struct VoiceAdmissionContext: Sendable {
    struct Entity: Sendable, Equatable {
        let name: String
        let id: String
        let canOpenLocally: Bool
    }
    struct Ask: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case unspecified, confirm, choice, question }
        let taskID: UUID
        let askID: UUID
        let kind: Kind
        let options: [String]
        init(taskID: UUID, askID: UUID, kind: Kind = .unspecified, options: [String] = []) {
            self.taskID = taskID; self.askID = askID; self.kind = kind; self.options = options
        }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.taskID == rhs.taskID && lhs.askID == rhs.askID }
    }
    var entities: [Entity] = []
    var appRoles: [String: String] = [:]
    var targetID: String?
    var targetAppID: String?
    var windowID: Int?
    var editableTarget = false
    var tasks: Set<UUID> = []
    var selectedTask: UUID?
    var capturedAsks: [Ask] = []
    var currentAsks: [Ask] = []
    var hasExplicitGrantScope = false
    var agents: [String: String] = [:]
}

/// Final-only deterministic admission. Unknown values never become phonetic substitutions.
enum VoiceAdmissionPolicy {
    /// Same captured-state interpretation is used by admission and execution.
    /// This changes request syntax, never the retained transcript or literals.
    static func commandText(_ original: String, context: VoiceAdmissionContext) -> String {
        guard original.utf8.count <= 4000 else { return original }
        let raw = normalized(original)
        if eligibleAsks(context).contains(where: { ask in
            ask.kind == .choice && ask.options.contains { normalized($0) == raw }
        }) { return original }
        var command = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:"))
        let courtesies = ["would you mind", "could you", "would you", "can you", "will you",
                          "hey jarvis", "hey jev", "jarvis", "jev", "please", "just"]
        while true {
            var stripped = false
            for prefix in courtesies where command.lowercased().hasPrefix(prefix) {
                let tail = String(command.dropFirst(prefix.count))
                guard let first = tail.first, first.isWhitespace || first == "," || first == ":" else { continue }
                let rest = tail.trimmingCharacters(in: separators)
                guard !rest.isEmpty else { continue }
                command = rest; stripped = true
                break
            }
            if !stripped { break }
        }
        if let parsed = FastAction.parse(command), !namesApp(parsed.action, context: context) { return command }
        if let parsed = FastAction.parseOpen(command),
           !namedCandidates(parsed.query.components(separatedBy: " and ")[0], context: context).isEmpty {
            // Preserve both unique and ambiguous original names before
            // interpreting "me", "back", etc. as part of another frame.
            return command
        }
        let n = normalized(command)
        if ["do not", "don t", "dont", "never", "won t", "avoid", "not", "stop", "cancel",
            "never mind", "nevermind"].contains(where: { n == $0 || n.hasPrefix($0 + " ") }) {
            return command
        }
        for (prefix, replacement) in [
            ("show me ", "show "), ("switch back to ", "switch to "),
            ("go back to ", "go to "), ("take me to ", "go to ")
        ] where command.lowercased().hasPrefix(prefix) {
            return replacement + command.dropFirst(prefix.count)
        }
        if command.lowercased().hasPrefix("get "),
           [" to the front", " to front", " up front", " forward"].contains(where: {
               n.hasSuffix($0)
           }) {
            return "bring " + command.dropFirst(4)
        }
        if let focus = focusInflection(command, context: context) { return focus }
        if FastAction.parseOpen(command) == nil,
           context.capturedAsks.isEmpty, context.currentAsks.isEmpty,
           IntentRouter.classify(command).verb == .unknown,
           !["hi", "hello", "hey", "thanks", "thank you", "yes", "no",
             "approve", "decline", "always allow"].contains(n),
           !command.contains("?"),
           let first = command.first, !"\"'`“‘”’".contains(first) {
            let candidates = namedCandidates(command, context: context)
            if candidates.count == 1, let target = candidates.first, target.canOpenLocally {
                return "show " + target.name
            }
        }
        return FastAction.parseOpen(command) == nil ? original : command
    }

    /// "show me Chrome" brings an app forward; "show me Save" points at
    /// a control. An app the Mac knows by that name wins.
    private static func namesApp(_ action: FastAction, context: VoiceAdmissionContext) -> Bool {
        guard case .showNamed(let name) = action.body else { return false }
        return !namedCandidates(name, context: context).isEmpty
    }

    private static func focusInflection(_ command: String, context: VoiceAdmissionContext) -> String? {
        guard context.capturedAsks.isEmpty, context.currentAsks.isEmpty,
              let open = FastAction.parseOpen(command),
              namedCandidates(open.query, context: context).isEmpty else { return nil }
        let text = normalized(command), query = normalized(open.query)
        let canonicalPrefix: String
        if open.verb == "switch to", text == "switch to " + query {
            canonicalPrefix = "switch to "
        } else if open.verb == "bring",
                  [" to front", " to the front", " up front", " forward"].contains(where: {
                      text == "bring " + query + $0
                  }) {
            canonicalPrefix = "bring "
        } else { return nil }
        guard !query.split(separator: " ").contains(where: { ["and", "or"].contains(String($0)) }) else {
            return nil
        }
        var name = query
        for prefix in ["the ", "my "] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        for suffix in [" application", " app"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        guard name.hasSuffix("s"), !name.hasSuffix("ss") else { return nil }
        let base = String(name.dropLast())
        guard !base.isEmpty, !base.hasSuffix("s") else { return nil }
        let matches = Dictionary(grouping: context.entities.filter {
            normalized($0.name) == base
        }, by: \.id)
        guard matches.count == 1, let entity = matches.values.first?.first,
              context.entities.filter({ $0.id == entity.id }).allSatisfy(\.canOpenLocally) else { return nil }
        return canonicalPrefix + entity.name + (open.verb == "bring" ? " to front" : "")
    }

    private static func namedCandidates(_ query: String,
                                        context: VoiceAdmissionContext) -> [VoiceAdmissionContext.Entity] {
        let raw = normalized(query)
        guard !raw.isEmpty else { return [] }
        var q = raw
        for prefix in ["the ", "my "] where q.hasPrefix(prefix) { q.removeFirst(prefix.count) }
        for suffix in [" application", " app"] where q.hasSuffix(suffix) { q.removeLast(suffix.count) }
        guard !q.isEmpty else { return [] }
        let original = context.entities.filter { normalized($0.name) == raw }
        let exact = context.entities.filter { normalized($0.name) == q }
        let matches = !original.isEmpty ? original : (!exact.isEmpty ? exact : context.entities.filter {
            (" " + normalized($0.name) + " ").contains(" " + q + " ")
        })
        return Dictionary(grouping: matches, by: \.id).values.compactMap { group in
            guard let first = group.first else { return nil }
            return .init(name: first.name, id: first.id,
                         canOpenLocally: context.entities.filter { $0.id == first.id }.allSatisfy(\.canOpenLocally))
        }.sorted { $0.id < $1.id }
    }

    static func propose(_ original: String, context: VoiceAdmissionContext,
                        speech: Bool = false) -> VoiceProposal {
        guard original.utf8.count <= 4000 else { return blocked(.refuse, "invalid_length") }
        let originalValue = normalized(original)
        if eligibleAsks(context).contains(where: { ask in
            ask.kind == .choice && ask.options.contains { normalized($0) == originalValue }
        }) {
            return answerProposal(originalValue, context: context)
        }
        let text = commandText(original, context: context)
        let t = normalized(text)
        guard !t.isEmpty else { return blocked(.refuse, "empty_transcript") }
        guard text.utf8.count <= 4000 else { return blocked(.refuse, "invalid_length") }

        // Literal command words are data, not cancellation or negation.
        if let parsed = FastAction.parse(text), case .type(let payload) = parsed.action.body {
            let literal = normalized(payload)
            let withdrawal = ["do not type", "don t type", "stop typing", "do not write", "don t write",
                              "do not enter", "don t enter"].contains { literal.contains($0) }
            let correction = literal.contains(" actually ")
                && [" do not ", " don t ", " no "].contains { (" " + literal + " ").contains($0) }
            if !quotedLiteral(text), withdrawal || correction {
                return blocked(.clarify, "contradictory_request", risk: .contradictory)
            }
            guard context.targetID != nil, context.editableTarget else {
                return blocked(.clarify, "ungrounded_target")
            }
            // ASR closes a spoken utterance with sentence punctuation the
            // speaker never dictated ("type the word stop."). Only a voice
            // final drops terminal marks from an unquoted payload — typed
            // text and quoted literals stay verbatim.
            var literalPayload = payload
            if speech, !quotedLiteral(text) {
                while let last = literalPayload.last, ".!?…,;:".contains(last) {
                    literalPayload.removeLast()
                }
                if literalPayload.isEmpty { literalPayload = payload }
            }
            return VoiceProposal(route: .local, intent: "type", slots: ["text": literalPayload],
                                 targetIDs: targets(context))
        }
        let negators = ["do not", "don't", "don t", "dont", "never", "won't", "won t", "avoid"]
        if t != "never mind", negators.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) {
            return blocked(.refuse, "negated_request", risk: .negated)
        }
        if t.hasPrefix("not ") {
            let rest = String(text.dropFirst(4))
            if FastAction.parseOpen(rest) != nil || FastAction.parse(rest) != nil {
                return blocked(.refuse, "negated_request", risk: .negated)
            }
        }
        if t.contains(" actually ") && ["don't", "don t", "do not", " no"].contains(where: { t.contains($0) }) {
            return blocked(.clarify, "contradictory_request", risk: .contradictory)
        }
        let imperative = ["open", "launch", "show", "send", "reply", "remind", "set", "delete", "click"]
            .contains { t.hasPrefix($0 + " ") }
        if imperative && t.contains(" or ") {
            return blocked(.clarify, t.hasPrefix("open ") ? "ambiguous_target" : "ambiguous_critical_value")
        }
        if ["yes", "no", "approve", "decline", "always allow"].contains(t) {
            return answerProposal(t, context: context)
        }
        let eligible = eligibleAsks(context)
        if eligible.count > 1, !explicitNewRequest(text) {
            return blocked(.clarify, "ambiguous_ask")
        }
        if eligible.count == 1, let ask = eligible.first {
            let ordinals = ["one", "two", "three", "four", "five", "first", "second", "third", "fourth", "fifth"]
            if ask.kind == .choice,
               ordinals.contains(t) || Int(t) != nil || ask.options.contains(where: { normalized($0) == t }) {
                return answerProposal(t, context: context)
            }
            let leading = t.split(separator: " ").first.map(String.init) ?? ""
            let commandHead = explicitNewRequest(text) || ["open", "launch", "click", "scroll", "type", "stop", "cancel", "send", "delete", "show"].contains(leading)
            if ask.kind == .question, !commandHead, FastAction.parse(text) == nil {
                return answerProposal(t, context: context)
            }
        }
        if ["stop", "cancel", "cancel the task", "cancel that", "never mind", "nevermind"].contains(t) {
            let task = context.selectedTask.flatMap { context.tasks.contains($0) ? $0 : nil }
                ?? (context.tasks.count == 1 ? context.tasks.first : nil)
            guard let task else { return blocked(.clarify, "ambiguous_task") }
            return VoiceProposal(route: .local, intent: "cancel", slots: ["task_id": task.uuidString])
        }
        if t.hasPrefix("stop ") || t.hasPrefix("cancel ") {
            return blocked(.clarify, "ambiguous_task")
        }
        if t.hasPrefix("select ") && t.contains(" task") && context.tasks.isEmpty {
            return blocked(.clarify, "ambiguous_task")
        }
        let hasPersonDestination = t.hasPrefix("send ") && t.contains(" to ") && !t.contains(" channel")
        if t.hasPrefix("reply to ") || hasPersonDestination {
            // Contacts/script binding belongs to its approved executor, not an invented identity.
            return blocked(.clarify, "unavailable_recipient")
        }
        if t.hasPrefix("delete ") || t.hasPrefix("click delete") {
            return blocked(.clarify, "confirmation_required")
        }
        if t.hasPrefix("click "), context.targetID == nil {
            return blocked(.clarify, "ungrounded_target")
        }

        if let parsed = FastAction.parse(text), !namesApp(parsed.action, context: context) {
            if let qualifier = parsed.appQualifier,
               !context.entities.contains(where: { normalized($0.name) == normalized(qualifier) }) {
                if t.hasPrefix("search for ") {
                    switch parsed.action.body {
                    case .webSearch, .appSearch:
                        return remote("browser_request", context: context)
                    default: break
                    }
                }
                return blocked(.clarify, "ungrounded_target")
            }
            switch parsed.action.body {
            case .hotkey(let keys, _), .systemHotkey(let keys, _):
                guard context.targetID != nil else { return blocked(.clarify, "ungrounded_target") }
                return VoiceProposal(route: .local, intent: "hotkey",
                                     slots: ["keys": keys.joined(separator: "+")], targetIDs: targets(context))
            case .scroll(let direction, let pages):
                guard context.targetID != nil else { return blocked(.clarify, "ungrounded_target") }
                return VoiceProposal(route: .local, intent: "scroll",
                                     slots: ["direction": direction, "pages": String(pages)],
                                     targetIDs: targets(context))
            case .gaze:
                return blocked(.clarify, "ungrounded_target")
            default:
                return VoiceProposal(route: .local, intent: "primitive", targetIDs: targets(context))
            }
        }

        if let open = FastAction.parseOpen(text) {
            let pieces = open.query.components(separatedBy: " and ")
            let query = pieces[0]
            let candidates = namedCandidates(query, context: context)
            let rows = candidates.map { entity in JSONValue.object([
                "name": .string(entity.name), "bundle_id": .string(entity.id)
            ]) }
            guard candidates.count == 1,
                  let resolved = FastAction.resolveOpenApp(query: query, apps: rows, frontmostBundle: nil),
                  let entity = candidates.first(where: { $0.id == resolved.bundle }) else {
                return blocked(.clarify, "ungrounded_target")
            }
            if pieces.count > 1 || !entity.canOpenLocally {
                return remote("remote", context: context, slots: ["target_id": entity.id], targets: [entity.id])
            }
            return VoiceProposal(route: .local, intent: "open", slots: ["target_id": entity.id],
                                 targetIDs: [entity.id])
        }
        if ["hi", "hello", "hey", "thanks", "thank you"].contains(t) {
            return remote("question", context: context)
        }
        if t.split(separator: " ").count == 1 { return blocked(.clarify, "unclear_request") }
        if case .query = IntentRouter.classify(text).verb {
            if ["screen", "this page", "this window", "this button"].contains(where: { t.contains($0) }) {
                return remote("screen_question", context: context)
            }
            return remote("question", context: context)
        }
        return remote("remote", context: context)
    }

    private static func answerProposal(_ text: String, context: VoiceAdmissionContext) -> VoiceProposal {
        if text == "always allow", !context.hasExplicitGrantScope {
            return blocked(.refuse, "permission_required")
        }
        let asks = eligibleAsks(context)
        guard asks.count == 1, let ask = asks.first else {
            return blocked(.clarify, "ambiguous_ask")
        }
        guard context.currentAsks.contains(ask) else { return blocked(.refuse, "ask_changed") }
        return VoiceProposal(route: .local, intent: "respond",
                             slots: ["task_id": ask.taskID.uuidString, "ask_id": ask.askID.uuidString],
                             replyTo: .init(taskID: ask.taskID, askID: ask.askID))
    }

    static func eligibleAsks(_ context: VoiceAdmissionContext) -> [VoiceAdmissionContext.Ask] {
        context.capturedAsks.filter { context.selectedTask == nil || $0.taskID == context.selectedTask }
    }

    private static func remote(_ intent: String, context: VoiceAdmissionContext,
                               slots: [String: String] = [:], targets: Set<String> = []) -> VoiceProposal {
        let eligible = eligibleAsks(context)
        let binding = eligible.count == 1 ? eligible.first.map { VoiceAskBinding(taskID: $0.taskID, askID: $0.askID) } : nil
        return VoiceProposal(route: .remote, intent: intent, slots: slots, targetIDs: targets, replyTo: binding)
    }

    static func explicitNewRequest(_ text: String) -> Bool {
        if let parsed = FastAction.parse(text), case .overlay = parsed.action.body { return false }
        let first = normalized(text).split(separator: " ").first.map(String.init) ?? ""
        if ["open", "launch", "show", "new", "close", "scroll", "type", "undo", "redo", "copy", "paste", "cut",
            "select", "move", "bring", "switch", "organize", "find", "read", "summarize", "check", "send", "reply",
            "stop", "cancel", "search"].contains(first) { return true }
        if case .query = IntentRouter.classify(text).verb { return true }
        guard let parsed = FastAction.parse(text) else { return false }
        if case .overlay = parsed.action.body { return false }
        return true
    }

    private static func quotedLiteral(_ text: String) -> Bool {
        let pattern = #"\btype(?:\s+(?:out|exactly|the\s+(?:word|phrase|text|string)))?\s+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let prefix = Range(match.range, in: text) else { return false }
        let payload = text[prefix.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.count >= 2, let first = payload.unicodeScalars.first?.value,
              let last = payload.unicodeScalars.last?.value else { return false }
        return (first == 34 && last == 34) || (first == 39 && last == 39)
            || (first == 8220 && last == 8221) || (first == 8216 && last == 8217)
    }
    private static func targets(_ context: VoiceAdmissionContext) -> Set<String> {
        context.targetID.map { [$0] } ?? []
    }

    private static func blocked(_ route: VoiceRoute, _ reason: String, risk: VoiceRisk = .clear) -> VoiceProposal {
        VoiceProposal(route: route, intent: "blocked", risk: risk, reason: reason)
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// This owner is used by typed and recorded turns and, at integration, the microphone lane.
@MainActor
final class LocalSpeechSession {
    private(set) var gate = VoiceTurnGate()
    var context = VoiceAdmissionContext()
    private var capturedContext = VoiceAdmissionContext()
    private(set) var finalizedAt: TimeInterval?
    var boundContext: VoiceAdmissionContext { capturedContext }
    var execute: (VoiceAdmission) async -> Void
    var onDecision: ((VoiceAdmission) -> Void)?
    var onPartial: ((UUID, String) -> Void)?
    var onDiagnostic: (@Sendable (VoiceSpeechDiagnostic) -> Void)?

    init(execute: @escaping (VoiceAdmission) async -> Void) {
        self.execute = execute
    }

    @discardableResult
    func begin(id: UUID = UUID(), mode: VoiceCaptureMode, ready: Bool, now: TimeInterval,
               realtimeConnection: UUID? = nil) -> VoiceTurnToken {
        capturedContext = context
        finalizedAt = nil
        return gate.begin(id: id, mode: mode, ready: ready, now: now, realtimeConnection: realtimeConnection)
    }

    func beginRemoteCapture(id: UUID, mode: VoiceCaptureMode, connection: UUID,
                            now: TimeInterval) -> VoiceTurnToken {
        begin(id: id, mode: mode, ready: true, now: now, realtimeConnection: connection)
    }

    func commitRemoteCapture(_ turn: VoiceTurnToken, input: VoiceRealtimeInput, now: TimeInterval) -> Bool {
        gate.acknowledgeRealtimeCommit(turn, input: input, now: now)
    }

    func finishRemoteCapture(_ text: String, turn: VoiceTurnToken,
                             input: VoiceRealtimeInput, now: TimeInterval) async -> VoiceAdmission? {
        guard gate.isCurrent(turn), gate.state == .finishing, gate.realtimeInput == input else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            gate.cancel(turn)
            onDiagnostic?(.init(turn: turn.id, stage: "finalization.realtime.empty", metrics: [:]))
            return nil
        }
        let admission = await finalize(text, turn: turn, drainedFrames: 0, now: now,
            speech: true, window: 8, executeAutomatically: false, realtimeInput: input)
        if admission != nil {
            onDiagnostic?(.init(turn: turn.id, stage: "finalization.realtime.final", metrics: [:]))
        }
        return admission
    }

    func partial(_ text: String, turn: VoiceTurnToken) {
        guard gate.acceptPartial(turn) else { return }
        onPartial?(turn.id, text)
    }

    @discardableResult
    func acceptFrame(_ turn: VoiceTurnToken, sequence: Int) -> Bool {
        gate.acceptFrame(turn, sequence: sequence)
    }

    @discardableResult
    func release(_ turn: VoiceTurnToken, acceptedFrames: Int? = nil, now: TimeInterval) -> Bool {
        gate.release(turn, acceptedFrames: acceptedFrames, now: now)
    }

    func cancel(_ turn: VoiceTurnToken) { gate.cancel(turn) }
    func fail(_ turn: VoiceTurnToken, reason: String) { gate.fail(turn, reason: reason) }

    func consumeAdmission(_ turn: VoiceTurnToken, resolvingClarification: Bool = false) -> VoiceAdmission? {
        gate.consume(turn, resolvingClarification: resolvingClarification)
    }

    func cancelCapture(_ turn: VoiceTurnToken) async {
        guard gate.isCurrent(turn) else { return }
        gate.cancel(turn)
    }

    func enterDictation() {
        guard let turn = gate.token else { return }
        _ = gate.enterDictation(turn)
    }

    @discardableResult
    func submitTyped(_ text: String, id: UUID = UUID(), now: TimeInterval) async -> VoiceAdmission? {
        let turn = begin(id: id, mode: .typed, ready: true, now: now)
        guard gate.release(turn, now: now) else { return nil }
        return await finalize(text, turn: turn, drainedFrames: 0, now: now)
    }

    @discardableResult
    func finalize(_ text: String, turn: VoiceTurnToken, drainedFrames: Int, now: TimeInterval,
                  speech: Bool = false, window: TimeInterval = 1,
                  executeAutomatically: Bool = true, realtimeInput: VoiceRealtimeInput? = nil) async -> VoiceAdmission? {
        guard !Task.isCancelled else { gate.cancel(turn); return nil }
        var boundContext = capturedContext
        boundContext.currentAsks = context.currentAsks
        var proposal = VoiceAdmissionPolicy.propose(text, context: boundContext, speech: speech)
        if !executeAutomatically, ConversationContext.localControl(text) != nil {
            proposal = VoiceProposal(route: .local, intent: "conversation_control")
        }
        if proposal.route == .local, let target = capturedContext.targetID,
           proposal.targetIDs.contains(target), context.targetID != target {
            proposal = VoiceProposal(route: .clarify, intent: proposal.intent, reason: "target_changed")
        }
        guard let admitted = gate.finalize(turn, text: text, proposal: proposal,
                                          drainedFrames: drainedFrames, now: now,
                                          window: window, realtimeInput: realtimeInput) else { return nil }
        finalizedAt = now
        onDecision?(admitted)
        guard gate.isCurrent(turn), gate.admission != nil else { return nil }
        if executeAutomatically && admitted.route == .local { await execute(admitted) }
        return admitted
    }
}
