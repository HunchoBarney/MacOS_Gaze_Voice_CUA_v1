import AppKit
import ApplicationServices
import Foundation

/// L7, writing by instruction (plan §8). "Type this …" types the exact
/// words into the focused field once an on-device transcription of the
/// same speech has the same words, keeping the conversation transcript's
/// case and punctuation. When the words differ, or there is no on-device
/// transcript, it shows them first ("Type this?") and waits for "type it". "Come up with a reply for this" drafts through the Responses
/// API and puts the draft in the reply field unsent; only "send it" sends.
/// Every typing is read back through Accessibility before it counts.
///
/// Off unless `Config.voiceLive` is on. `VoiceTaskCoordinator.beginVoiceTask`
/// asks it first, so today's lane and L2's delegation bridge both reach it.
@MainActor
final class WritingByInstruction {
    struct Field: Sendable, Equatable {
        var value: String?
        var selectedText: String?
        var editable: Bool
        var appName: String?
        var bundleID: String?
        var windowTitle: String?
        var pid: Int32?
    }

    /// The message "this" points at, as text to reply to.
    struct Referent: Sendable, Equatable {
        var text: String
        var appName: String?
        var windowTitle: String?
    }

    struct Draft: Sendable, Equatable {
        var text: String
        var placed = false
        var bundleID: String?
        var pid: Int32?
    }

    enum Pending: Sendable, Equatable {
        /// Shown on screen, waiting for "type it" or "no".
        case type(String)
        /// Drafted; in the field once `placed`, waiting for "send it".
        case draft(Draft)
    }

    var enabled: () -> Bool
    var localTranscript: () async -> String?
    var insert: (String) async throws -> Void
    var readField: () async -> Field?
    var referent: (TimeInterval?) async -> Referent?
    var compose: (Referent) async throws -> String
    /// Presses send for a placed draft and returns the spine's payload.
    var send: (Draft) async -> String
    /// Puts lines on screen; an empty list hides them.
    var show: ([String]) -> Void
    var note: (String) -> Void
    private(set) var pending: Pending?

    init(enabled: @escaping () -> Bool,
         localTranscript: @escaping () async -> String? = { nil },
         insert: @escaping (String) async throws -> Void = { try await DictationDelivery().deliverVerbatim($0) },
         readField: @escaping () async -> Field? = { WritingByInstruction.focusedField() },
         referent: @escaping (TimeInterval?) async -> Referent? = { _ in WritingByInstruction.focusedReferent() },
         compose: @escaping (Referent) async throws -> String,
         send: @escaping (Draft) async -> String,
         show: @escaping ([String]) -> Void = { _ in },
         note: @escaping (String) -> Void = { _ in }) {
        self.enabled = enabled
        self.localTranscript = localTranscript
        self.insert = insert
        self.readField = readField
        self.referent = referent
        self.compose = compose
        self.send = send
        self.show = show
        self.note = note
    }

    /// The VoiceToolResult payload for a writing instruction, or nil when
    /// the words aren't one and the caller's own routing should run.
    func handle(_ utterance: String, input: WritingInput = WritingInput()) async -> String? {
        guard enabled() else { return nil }
        let intent = WritingInstruction.intent(utterance)
        switch pending {
        case .type(let text)?:
            pending = nil
            show([])
            if intent == nil, let yes = WritingInstruction.confirmation(utterance) {
                return yes ? await type(text) : Self.result(VoiceToolResult.Status.cancelled, "Okay, I won't type it.")
            }
        case .draft(let draft)?:
            if intent == .sendDraft { return await sendDraft(draft) }
            if !draft.placed, intent == nil, let yes = WritingInstruction.confirmation(utterance) {
                guard yes else {
                    pending = nil
                    show([])
                    return Self.result(VoiceToolResult.Status.cancelled, "Okay, I dropped the draft.")
                }
                return await place(draft)
            }
        case nil:
            break
        }
        switch intent {
        case .type(let literal)?: return await check(literal, input: input)
        case .draftReply?: return await draftReply(input)
        case .sendDraft?, nil: return nil
        }
    }

    private func check(_ literal: String, input: WritingInput) async -> String {
        let local: String?
        if let given = input.localTranscript { local = given } else { local = await localTranscript() }
        let heard = local.map(WritingInstruction.literals(within:)) ?? []
        if heard.contains(where: { WritingInstruction.agrees(literal, $0) }) {
            return await type(literal)
        }
        pending = .type(literal)
        var lines = ["Type this?", literal]
        if let other = heard.min(by: { abs($0.count - literal.count) < abs($1.count - literal.count) }) {
            lines.append("On-device heard: \(other)")
        }
        show(lines + ["Say \"type it\" or \"no\"."])
        note(local == nil ? "type: no on-device transcript, showing before typing"
                          : "type: transcripts disagree, showing before typing")
        return Self.result(VoiceToolResult.Status.question, "Type this? \(literal)",
                           kind: VoiceToolResult.Kind.taskQuestion)
    }

    private func type(_ text: String) async -> String {
        guard let before = await readField(), before.editable else {
            return Self.result(VoiceToolResult.Status.refused, "Click into the field you want first, then say it again.")
        }
        do {
            try await insert(text)
        } catch {
            return Self.result(VoiceToolResult.Status.error, "I couldn't type into that field.")
        }
        guard let value = await readField()?.value else {
            return Self.result(VoiceToolResult.Status.error, "I typed it, but I couldn't read the field back to check.")
        }
        guard Self.count(text, in: value) > Self.count(text, in: before.value ?? "") else {
            return Self.result(VoiceToolResult.Status.error, "I typed it, but it isn't showing in the field.")
        }
        note("type: read back from the field")
        return Self.result(VoiceToolResult.Status.ok, "Typed.")
    }

    private func draftReply(_ input: WritingInput) async -> String {
        guard let target = await referent(input.deicticTime) else {
            return Self.result(VoiceToolResult.Status.question,
                               "Which message? Select it or look at it, then ask again.")
        }
        let text: String
        do {
            text = try await compose(target).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return Self.result(VoiceToolResult.Status.error,
                               (error as? LocalizedError)?.errorDescription ?? "I couldn't draft a reply.")
        }
        guard !text.isEmpty else {
            return Self.result(VoiceToolResult.Status.error, "I couldn't draft a reply.")
        }
        let draft = Draft(text: text)
        guard await readField()?.editable == true else {
            pending = .draft(draft)
            show(["Draft reply, not sent", text, "Click into the reply field and say \"type it\"."])
            return Self.result(VoiceToolResult.Status.question,
                               "Here's a draft: \(Self.firstLine(text)) Click into the reply and say type it.")
        }
        return await place(draft)
    }

    private func place(_ draft: Draft) async -> String {
        guard let field = await readField(), field.editable else {
            pending = .draft(draft)
            return Self.result(VoiceToolResult.Status.question, "Click into the reply field first, then say type it.")
        }
        do {
            try await insert(draft.text)
        } catch {
            pending = .draft(draft)
            return Self.result(VoiceToolResult.Status.error, "I couldn't put the draft in that field.")
        }
        if let value = await readField()?.value,
           Self.count(draft.text, in: value) <= Self.count(draft.text, in: field.value ?? "") {
            pending = nil
            show([])
            return Self.result(VoiceToolResult.Status.error, "I put the draft in, but it isn't showing in the field.")
        }
        pending = .draft(Draft(text: draft.text, placed: true, bundleID: field.bundleID, pid: field.pid))
        show(["Draft is in the field, not sent", Self.firstLine(draft.text), "Say \"send it\" to send."])
        note("draft: placed unsent")
        return Self.result(VoiceToolResult.Status.ok,
                           "Draft's in, not sent. It starts: \(Self.firstLine(draft.text)) Say send it to send.")
    }

    private func sendDraft(_ draft: Draft) async -> String {
        guard draft.placed else {
            return Self.result(VoiceToolResult.Status.question,
                               "The draft isn't in a reply field yet. Click into the reply and say type it.")
        }
        guard let field = await readField(), field.pid == draft.pid,
              let value = field.value, Self.count(draft.text, in: value) > 0 else {
            return Self.result(VoiceToolResult.Status.refused,
                               "The draft isn't in the focused field anymore, so I didn't send anything.")
        }
        pending = nil
        show([])
        return await send(draft)
    }

    private static func result(_ status: String, _ say: String, kind: String? = nil) -> String {
        VoiceToolResult(kind: kind, status: status, say: say).encoded()
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    /// Occurrences of `text` in a field's value, ignoring the curly quotes
    /// and line endings editors substitute as you type.
    static func count(_ text: String, in value: String) -> Int {
        let fold = { (s: String) -> String in
            s.precomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "[‘’]", with: "'", options: .regularExpression)
                .replacingOccurrences(of: "[“”]", with: "\"", options: .regularExpression)
        }
        let needle = fold(text), haystack = fold(value)
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - Accessibility

    nonisolated static func focusedField() -> Field? {
        let system = AXUIElementCreateSystemWide()
        guard let element = element(system, kAXFocusedUIElementAttribute) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let window = Self.element(element, kAXWindowAttribute)
        let editable = FocusedTextBinding.accepts(role: attribute(element, kAXRoleAttribute) as? String,
                                                  subrole: attribute(element, kAXSubroleAttribute) as? String,
                                                  enabled: attribute(element, kAXEnabledAttribute) as? Bool,
                                                  readOnly: attribute(element, "AXReadOnly") as? Bool)
        return Field(value: attribute(element, kAXValueAttribute) as? String,
                     selectedText: attribute(element, kAXSelectedTextAttribute) as? String,
                     editable: editable,
                     appName: app?.localizedName,
                     bundleID: app?.bundleIdentifier,
                     windowTitle: window.flatMap { attribute($0, kAXTitleAttribute) as? String },
                     pid: pid)
    }

    /// Until L6's DeicticResolver lands: the selected text, else the
    /// focused element's own text when it isn't the field being typed in.
    nonisolated static func focusedReferent() -> Referent? {
        guard let field = focusedField() else { return nil }
        let text = [field.selectedText, field.editable ? nil : field.value]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let text else { return nil }
        return Referent(text: String(text.prefix(4_000)), appName: field.appName, windowTitle: field.windowTitle)
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

extension WritingByInstruction {
    /// The draft request on the Responses API: the message in, one reply out.
    static func composeRequest(for referent: Referent) -> TerraClient.Request {
        var context = "Message to reply to:\n\(referent.text)"
        if let app = referent.appName { context += "\n\nApp: \(app)" }
        if let title = referent.windowTitle, !title.isEmpty { context += "\nWindow: \(title)" }
        return TerraClient.Request(
            instructions: """
            Draft a reply the user can send as written, in their own voice: short, plain and friendly. \
            Answer in the message's language. Match the medium: no greeting or sign-off for a chat, \
            a brief one for an email. Never invent facts, times, prices or commitments; where the user \
            must decide, leave a short gap in [brackets].
            """,
            text: context,
            schemaName: "reply_draft",
            schema: .object([
                "type": .string("object"),
                "properties": .object(["reply": .object(["type": .string("string")])]),
                "required": .array([.string("reply")]),
                "additionalProperties": .bool(false),
            ]),
            effort: .low,
            maxOutputTokens: 600)
    }
}
