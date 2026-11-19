import Foundation
import OSLog
import JevVoiceCore

struct DelegatedVoiceStatusScope: Sendable, Equatable {
    let revision: UUID
    let receipt: WorkerTurnReceipt?

    static func asks(_ final: String) -> Bool {
        guard final.utf8.count <= 160 else { return false }
        var words = final.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if words.last == "?" || words.last == "." { words.removeLast() }
        return ["has my delegated task finished", "is my delegated task done",
                "what is the status of my delegated task", "what’s the status of my delegated task",
                "what's the status of my delegated task"].contains(words)
    }
}

extension VoiceAdmission {
    var isLocalStatusQuestion: Bool {
        intent == "desktop_switch_status" || (intent != "respond" && DelegatedVoiceStatusScope.asks(text))
    }
}

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

        static func sameParkedSnapshot(_ opened: [Self], _ current: [Self]) -> Bool {
            guard opened.count == current.count, Set(opened.map(\.taskID)).count == opened.count,
                  Set(opened.map(\.askID)).count == opened.count else { return false }
            return opened.allSatisfy { ask in
                current.contains { other in
                    other == ask && other.kind == ask.kind &&
                        other.options.elementsEqual(ask.options) { $0.utf8.elementsEqual($1.utf8) }
                }
            }
        }
    }
    var entities: [Entity] = []
    var appRoles: [String: String] = [:]
    var targetID: String?
    var targetAppID: String?
    var windowID: Int?
    var desktopDisplayID: UInt32?
    var editableTarget = false
    var tasks: Set<UUID> = []
    var selectedTask: UUID?
    var delegatedStatus: DelegatedVoiceStatusScope?
    var capturedAsks: [Ask] = []
    var currentAsks: [Ask] = []
    var hasExplicitGrantScope = false
    var agents: [String: String] = [:]
}

/// Final-only deterministic admission. Unknown values never become phonetic substitutions.
enum VoiceAdmissionPolicy {
    static func isDesktopSwitchQuestion(_ final: String) -> Bool {
        guard final.utf8.count <= 160 else { return false }
        var words = final.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = words.last, ".?!".contains(last) { words.removeLast() }
        return words.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") == "did it switch"
    }

    static func isBareGazeClick(_ final: String) -> Bool {
        guard final.utf8.count <= 32 else { return false }
        let words = final.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return words == "click" || words == "click." || words == "click!"
    }

    /// Same captured-state interpretation is used by admission and execution.
    /// This changes request syntax, never the retained transcript or literals.
    static func commandText(_ original: String, context: VoiceAdmissionContext) -> String {
        guard original.utf8.count <= 4000 else { return original }
        if matchesCapturedChoice(original, context: context) { return original }
        let command = HandsFreeActionSyntax.withoutCourtesy(original)
        if FastAction.parse(command) != nil { return command }
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
        if speech, isDesktopSwitchQuestion(original) { return .local("desktop_switch_status") }
        let request = FastAction.retiredTargetRequest(original)
        let clickReply = isBareGazeClick(original) && (!context.capturedAsks.isEmpty || !context.currentAsks.isEmpty)
        if request != nil || clickReply {
            let asks = context.capturedAsks
            let current = context.currentAsks
            guard asks.count == 1, let ask = asks.first,
                  current.count == 1, let fresh = current.first, fresh == ask,
                  fresh.kind == ask.kind, fresh.options == ask.options else { return blocked(.clarify, "unbound_pointing") }
            let answer = normalized(original)
            if clickReply, ask.kind == .question { return answerProposal(answer, context: context) }
            guard ask.kind == .choice else { return blocked(.clarify, "unbound_pointing") }
            let labels = ask.options.filter { normalized($0) == answer }
            if labels.count == 1 { return answerProposal(answer, context: context) }
            guard labels.isEmpty, case .pick(let n) = request, ask.options.indices.contains(n - 1) else {
                return blocked(.clarify, "unbound_pointing")
            }
            return answerProposal(answer, context: context)
        }
        if ScreenQuestionObservation.isScreenInquiry(original, context: context) {
            return remote("screen_question", context: context)
        }
        let originalValue = normalized(original)
        if matchesCapturedChoice(original, context: context) {
            return answerProposal(originalValue, context: context)
        }
        let text = commandText(original, context: context)
        let t = normalized(text)
        if speech, (t.range(of: #"^(?:click|tap|press|select|open|choose|hit)\s+(?:this|that|it|here|there)(?:\s+(?:one|button|link|control|item))?$"#, options: .regularExpression) != nil
            || t.range(of: #"^(?:click|tap|press|select|open|choose|hit)\b.*\b(?:looking|pointing) at\b"#, options: .regularExpression) != nil) {
            return blocked(.clarify, "unbound_pointing")
        }
        guard !t.isEmpty else { return blocked(.refuse, "empty_transcript") }
        guard text.utf8.count <= 4000 else { return blocked(.refuse, "invalid_length") }

        let parsed = FastAction.parse(text)
        if speech, let parsed, case .gaze(let verb) = parsed.action.body, verb != .describe {
            return blocked(.clarify, "unbound_pointing")
        }
        // Literal command words are data, not cancellation or negation.
        if let parsed, case .type(let payload) = parsed.action.body {
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
        if DesktopSpaceTarget(command: original) != nil {
            guard context.capturedAsks.isEmpty, context.currentAsks.isEmpty else {
                return blocked(.clarify, "ask_changed")
            }
            return VoiceProposal(route: .local, intent: "switch_space", targetIDs: targets(context))
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
        if DelegatedVoiceStatusScope.asks(original) {
            return .local("delegated_status")
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

        if let parsed {
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
                return blocked(.clarify, speech ? "unbound_pointing" : "ungrounded_target")
            default:
                return VoiceProposal(route: .local, intent: "primitive", targetIDs: targets(context))
            }
        }

        if let open = FastAction.parseOpen(text) {
            let pieces = open.query.components(separatedBy: " and ")
            let query = pieces[0]
            let candidates = namedCandidates(query, context: context)
            if candidates.count > 1 { return blocked(.clarify, "ambiguous_target") }
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

    static func matchesCapturedChoice(_ final: String, context: VoiceAdmissionContext) -> Bool {
        let value = normalized(final)
        return eligibleAsks(context).contains { ask in
            ask.kind == .choice && ask.options.contains { normalized($0) == value }
        }
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

    private static func explicitNewRequest(_ text: String) -> Bool {
        let first = normalized(text).split(separator: " ").first.map(String.init) ?? ""
        if ["open", "launch", "show", "new", "close", "scroll", "type", "undo", "redo", "copy", "paste", "cut",
            "select", "move", "bring", "switch", "organize", "find", "read", "summarize", "check", "send", "reply",
            "stop", "cancel", "search"].contains(first) { return true }
        if case .query = IntentRouter.classify(text).verb { return true }
        return FastAction.parse(text) != nil
    }

    static func isSpokenTypeRequest(_ command: String) -> Bool {
        if command.split(whereSeparator: \.isWhitespace).first?.lowercased() == "type" { return true }
        if case .type? = FastAction.parse(command)?.action.body { return true }
        return false
    }

    static func standaloneLiteral(_ command: String, admission: VoiceAdmission) -> String? {
        guard admission.route == .local, admission.intent == "type", let literal = admission.slots["text"],
              let parsed = FastAction.parse(command), parsed.appQualifier == nil, !parsed.action.deictic,
              case .type = parsed.action.body else { return nil }
        if quotedLiteral(command) {
            guard let close = command.last, !literal.contains(close) else { return nil }
        } else {
            guard !command.contains(where: { "\"“”‘`?;\n".contains($0) }),
                  !literal.hasPrefix("'"), !literal.hasSuffix("'"),
                  literal.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || "'’-".contains($0) }),
                  normalized(literal).range(of: #"\b(?:then|actually|instead|but|unless|except|and|or|if|when|after|before|otherwise|while|until)\b"#,
                                             options: .regularExpression) == nil else { return nil }
        }
        return literal
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
    private static let finalLog = Logger(subsystem: "com.chriswozniczek.jevvoice.voice", category: "local-final")
    private(set) var gate = VoiceTurnGate()
    var context = VoiceAdmissionContext()
    private var capturedContext = VoiceAdmissionContext()
    private(set) var gazeClickOnset: UUID?
    private(set) var gazeClickFinal: UUID?
    private let provider: (any LocalTranscriptProvider)?
    private var drainedFrames = 0
    private var remoteFrames: [Data] = []
    private var remoteBytes = 0
    private var exportedRemote = false
    private(set) var finalizedAt: TimeInterval?
    var boundContext: VoiceAdmissionContext { capturedContext }
    var execute: (VoiceAdmission) async -> Void
    var onDecision: ((VoiceAdmission) -> Void)?
    var onPartial: ((UUID, String) -> Void)?
    var onDiagnostic: (@Sendable (VoiceSpeechDiagnostic) -> Void)?

    init(provider: (any LocalTranscriptProvider)? = nil,
         execute: @escaping (VoiceAdmission) async -> Void) {
        self.provider = provider; self.execute = execute
    }

#if DEBUG
    typealias FixtureFinal = @MainActor (VoiceAdmission, VoiceAdmissionContext, VoiceAdmissionContext, @escaping @MainActor () -> Bool) async -> Bool
    private var reservedFixture = false
    private var fixtureFinal: FixtureFinal?
    private var fixtureTask: Task<Bool, Never>?

    convenience init(reservedFixtureFinal: FixtureFinal?) {
        self.init { _ in }
        reservedFixture = true
        fixtureFinal = reservedFixtureFinal
    }

    func consumeReservedFixture(_ turn: VoiceTurnToken, input: VoiceRealtimeInput?, current: @escaping @MainActor () -> Bool) async -> Bool {
        guard reservedFixture, turn.mode == .command else { return false }
        guard let fixtureFinal else { fail(turn, reason: "fixture_unavailable"); return true }
        guard current(), !Task.isCancelled, let input, gate.realtimeInput == input else {
            cancel(turn)
            return true
        }
        guard let admission = consumeAdmission(turn), admission.realtimeInput == input else {
            fail(turn, reason: "fixture_refused")
            return true
        }
        let task = Task { @MainActor [weak self, boundContext, context] in
            guard let self, current(), !Task.isCancelled, self.gate.isCurrent(turn), self.gate.state == .completed else { return false }
            return await fixtureFinal(admission, boundContext, context) { [weak self] in
                current() && !Task.isCancelled && self?.gate.isCurrent(turn) == true && self?.gate.state == .completed
            }
        }
        fixtureTask = task
        let handled = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if gate.isCurrent(turn) { fixtureTask = nil }
        if !handled, current(), gate.state == .completed { fail(turn, reason: "fixture_refused") }
        return true
    }
#endif

    @discardableResult
    func begin(id: UUID = UUID(), mode: VoiceCaptureMode, ready: Bool, now: TimeInterval,
               realtimeConnection: UUID? = nil) -> VoiceTurnToken {
#if DEBUG
        fixtureTask?.cancel(); fixtureTask = nil
#endif
        capturedContext = context
        gazeClickOnset = nil; gazeClickFinal = nil
        finalizedAt = nil
        drainedFrames = 0; remoteFrames = []; remoteBytes = 0; exportedRemote = false
        return gate.begin(id: id, mode: mode, ready: ready, now: now, realtimeConnection: realtimeConnection)
    }

    func beginRemoteCapture(id: UUID, mode: VoiceCaptureMode, connection: UUID,
                            now: TimeInterval, gazeClickLease: UUID? = nil) -> VoiceTurnToken {
        let turn = begin(id: id, mode: mode, ready: true, now: now, realtimeConnection: connection)
        if mode == .command { gazeClickOnset = gazeClickLease }
        return turn
    }

    func commitRemoteCapture(_ turn: VoiceTurnToken, input: VoiceRealtimeInput, now: TimeInterval) -> Bool {
        gate.acknowledgeRealtimeCommit(turn, input: input, now: now)
    }

    func finishRemoteCapture(_ text: String, turn: VoiceTurnToken,
                             input: VoiceRealtimeInput, now: TimeInterval, gazeClickLease: UUID? = nil) async -> VoiceAdmission? {
        guard gate.isCurrent(turn), gate.state == .finishing, gate.realtimeInput == input else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            gate.cancel(turn)
            onDiagnostic?(.init(turn: turn.id, stage: "finalization.realtime.empty", metrics: [:]))
            return nil
        }
        if turn.mode == .command, VoiceAdmissionPolicy.isBareGazeClick(text) { gazeClickFinal = gazeClickLease }
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

    func cancel(_ turn: VoiceTurnToken) {
#if DEBUG
        if gate.isCurrent(turn) { fixtureTask?.cancel() }
#endif
        gate.cancel(turn)
    }
    func fail(_ turn: VoiceTurnToken, reason: String) { gate.fail(turn, reason: reason) }

    var readyForCapture: Bool { provider?.readyForTurn ?? false }
    var preparedForCapture: Bool { provider?.preparedForCapture ?? false }

    func recordedSession(context: VoiceAdmissionContext) -> LocalSpeechSession {
        let session = LocalSpeechSession(provider: provider) { _ in }
        session.context = context
        session.onDiagnostic = onDiagnostic
        return session
    }

    func consumeAdmission(_ turn: VoiceTurnToken, resolvingClarification: Bool = false) -> VoiceAdmission? {
        gate.consume(turn, resolvingClarification: resolvingClarification)
    }

    func prewarm() async throws {
        guard let provider else { throw LocalSpeechError.unavailable }
        try await withVoiceDeadline(until: ProcessInfo.processInfo.systemUptime + 180) {
            try await provider.prepare()
        }
    }

    func beginCapture(id: UUID, mode: VoiceCaptureMode, now: TimeInterval,
                      previews: Bool = true, readyDeadline: TimeInterval? = nil) async throws -> VoiceTurnToken {
        let old = gate.token
        let turn = begin(id: id, mode: mode, ready: true, now: now)
        guard let provider, mode != .microphoneTest else {
            gate.fail(turn, reason: "provider_unavailable"); throw LocalSpeechError.unavailable
        }
        provider.evidenceSink?.set(onDiagnostic)
        if let old { await provider.cancelHold(old) }
        // A short finishing gap can ride the mic's existing pre-roll; a cold
        // provider never accepts speech while waiting for its models.
        let waitEnd = readyDeadline ?? (ProcessInfo.processInfo.systemUptime + 0.25)
        while !provider.readyForTurn, ProcessInfo.processInfo.systemUptime < waitEnd {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
            guard gate.isCurrent(turn) else { throw LocalSpeechError.stale }
        }
        guard provider.readyForTurn, gate.isCurrent(turn) else {
            gate.fail(turn, reason: "provider_unavailable"); throw LocalSpeechError.unavailable
        }
        do {
            if previews {
                try await provider.beginHold(turn) { [weak self] token, text in
                    Task { @MainActor [weak self] in self?.partial(text, turn: token) }
                }
            } else {
                try await provider.beginRecordedUtterance(turn)
            }
        } catch {
            gate.fail(turn, reason: "provider_unavailable")
            throw error
        }
        guard gate.isCurrent(turn), !Task.isCancelled else {
            await provider.cancelHold(turn); throw LocalSpeechError.stale
        }
        return turn
    }

    func consume(_ frame: VoicePCMFrame, sequence: Int, turn: VoiceTurnToken,
                 retainRemote: Bool = true) async throws {
        guard gate.isCurrent(turn), let provider else { throw LocalSpeechError.stale }
        guard gate.acceptFrame(turn, sequence: sequence) else { throw LocalSpeechError.captureLoss }
        do {
            if retainRemote {
                guard !frame.isFloat, frame.sampleRate == 24_000,
                      remoteBytes + frame.bytes.count <= 60 * 24_000 * 2 else {
                    throw LocalSpeechError.captureLoss
                }
                remoteFrames.append(frame.bytes); remoteBytes += frame.bytes.count
            }
            try await provider.appendHold(turn, frame: frame)
            guard gate.isCurrent(turn) else { throw LocalSpeechError.stale }
            drainedFrames += 1
        } catch {
            gate.fail(turn, reason: "capture_loss")
            await provider.cancelHold(turn)
            throw error
        }
    }

    /// `capturedSeconds` is the sealed hold's total duration — the caller's
    /// count includes frames still queued in `drain`, which this session
    /// cannot see before the drain runs but whose decode the budget must pay.
    func finishCapture(
        _ turn: VoiceTurnToken, acceptedFrames: Int, releasedAt: TimeInterval,
        capturedSeconds: Double,
        executeAutomatically: Bool = true,
        drain: @escaping @Sendable () async throws -> Void
    ) async throws -> VoiceAdmission? {
        guard gate.release(turn, acceptedFrames: acceptedFrames, now: releasedAt),
              let provider else { throw LocalSpeechError.stale }
        do {
            // One authoritative whole-hold decode plus capture drain. Optional
            // streaming partials are not a dependency. Keep the release-anchored
            // safety budget unchanged; it is not the warm latency target.
            let budget = min(8, max(2.0, 1.2 + capturedSeconds * 0.3))
            let observe = onDiagnostic
            observe?(.init(turn: turn.id, stage: "finalization.begin", metrics: [
                "budget_ms": budget * 1000, "captured_seconds": capturedSeconds,
                "accepted_frames": Double(acceptedFrames),
                "before_drain_ms": (ProcessInfo.processInfo.systemUptime - releasedAt) * 1000]))
            Self.finalLog.notice("finalize generation=\(turn.generation) budget_ms=\(budget * 1000) elapsed_before_drain_ms=\((ProcessInfo.processInfo.systemUptime - releasedAt) * 1000)")
            let text = try await withVoiceDeadline(until: releasedAt + budget) {
                let drainStarted = ProcessInfo.processInfo.systemUptime
                observe?(.init(turn: turn.id, stage: "finalization.drain_begin"))
                try await drain()
                observe?(.init(turn: turn.id, stage: "finalization.drain_end", metrics: [
                    "elapsed_ms": (ProcessInfo.processInfo.systemUptime - drainStarted) * 1000]))
                Self.finalLog.notice("finalize generation=\(turn.generation) drain_ms=\((ProcessInfo.processInfo.systemUptime - drainStarted) * 1000)")
                try Task.checkCancellation()
                return try await provider.finishHold(turn)
            }
            guard gate.isCurrent(turn) else { throw LocalSpeechError.stale }
            try Task.checkCancellation()
            guard let admitted = await finalize(text, turn: turn, drainedFrames: drainedFrames,
                                                now: ProcessInfo.processInfo.systemUptime,
                                                speech: true, window: budget,
                                                executeAutomatically: executeAutomatically) else {
                throw LocalSpeechError.deadline
            }
            onDiagnostic?(.init(turn: turn.id, stage: "finalization.admitted"))
            return admitted
        } catch {
            let code = (error as? LocalSpeechError).map { String(describing: $0) }
                ?? (error is CancellationError ? "cancelled" : "unknown")
            onDiagnostic?(.init(turn: turn.id, stage: "finalization.failure.\(code)"))
            if gate.isCurrent(turn) {
                gate.fail(turn, reason: error is CancellationError ? "cancelled" : "finalization_failed")
                remoteFrames = []; remoteBytes = 0
            }
            await provider.cancelHold(turn)
            throw error
        }
    }

    func cancelCapture(_ turn: VoiceTurnToken) async {
        guard gate.isCurrent(turn) else { return }
        gate.cancel(turn); remoteFrames = []; remoteBytes = 0
        await provider?.cancelHold(turn)
    }

    func takeRemoteAudio(_ turn: VoiceTurnToken) throws -> [Data] {
        guard gate.isCurrent(turn), gate.admission?.route == .remote,
              !exportedRemote else { throw LocalSpeechError.stale }
        exportedRemote = true
        let frames = remoteFrames
        remoteFrames = []; remoteBytes = 0
        return frames
    }

    func discardRemoteAudio() { remoteFrames = []; remoteBytes = 0 }

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
        if realtimeInput != nil, turn.mode == .command, VoiceAdmissionPolicy.isBareGazeClick(text),
           proposal.intent != "respond", boundContext.capturedAsks.isEmpty, boundContext.currentAsks.isEmpty,
           let gazeClickOnset, gazeClickFinal == gazeClickOnset {
            proposal = .local("spoken_gaze_click")
        }
        if !executeAutomatically, ConversationContext.localControl(text) != nil,
           proposal.intent != "respond", !VoiceAdmissionPolicy.matchesCapturedChoice(text, context: boundContext) {
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
