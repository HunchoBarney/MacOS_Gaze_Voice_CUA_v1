import Foundation
import JevVoiceCore

/// Roster seam — `AgentStore` satisfies it as-is; the coordinator binds the
/// shared instance so roster edits elsewhere appear here.
protocol AgentRosterProviding: Sendable {
    func agents() async -> [CompanionAgent]
}

extension AgentStore: AgentRosterProviding {}

/// Runtime seam — `AgentRuntime` satisfies it. `events` is deliberately NOT
/// here: the bridge stream is single-consumer, owned by `AgentRuntime.start`,
/// and fanned out to this model through `onAgentEvent` — a second iterator
/// would steal half the events (replies, turn states).
protocol AgentRuntimeHandling: Sendable {
    @discardableResult func send(to agent: CompanionAgent, message: String) async throws -> String
    /// False when the agent had no live turn to interrupt.
    @discardableResult func interrupt(slug: String) async throws -> Bool
}

extension AgentRuntime: AgentRuntimeHandling {
    @discardableResult func send(to agent: CompanionAgent, message: String) async throws -> String {
        try await send(message, to: agent)
    }
}

/// A turn's final message decoded per mirror/10-message-protocol.md. `body`
/// is the visible reply with EVERY bracketed marker block removed — raw
/// tags never reach the UI.
struct AgentFinalMessage: Equatable {
    var body: String
    var summary: String?
    var nextActions: [String] = []
    var doneTitle: String?
    var artifacts: [String] = []
    var hasStructuredBlocks: Bool {
        summary != nil || doneTitle != nil || !nextActions.isEmpty || !artifacts.isEmpty
    }

    private static let tags = ["SUMMARY", "NEXT_ACTIONS", "DONE_TITLE", "ARTIFACTS",
                               "ROUTINE"]

    static func parse(_ text: String) -> AgentFinalMessage {
        var parsed = AgentFinalMessage(body: stripMarkers(text))
        parsed.summary = blocks(in: text, tag: "SUMMARY").first
        parsed.doneTitle = blocks(in: text, tag: "DONE_TITLE").first
        parsed.nextActions = bullets(blocks(in: text, tag: "NEXT_ACTIONS").first ?? "")
        parsed.artifacts = bullets(blocks(in: text, tag: "ARTIFACTS").first ?? "")
        return parsed
    }

    /// Visible reply: every known marker block removed, earliest open tag
    /// wins so nested markers are consumed whole, a dangling open tag cuts
    /// the tail (stream cut mid-marker), and a trailing partial `<TAG…`
    /// fragment is hidden while streaming.
    static func stripMarkers(_ text: String) -> String {
        var stripped = "", cursor = text.startIndex
        while cursor < text.endIndex {
            var open: Range<String.Index>?, tag = ""
            for name in tags {
                if let range = text.range(of: "<\(name)>", range: cursor..<text.endIndex),
                   open == nil || range.lowerBound < open!.lowerBound {
                    open = range; tag = name
                }
            }
            guard let open else { break }
            stripped += text[cursor..<open.lowerBound]
            guard let close = closeRange(in: text, tag: tag, after: open.upperBound) else {
                return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            cursor = close.upperBound
        }
        stripped += text[cursor...]
        if let cut = partialTagStart(stripped) {
            stripped = String(stripped[..<cut])
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Index where a trailing "<FOO" fragment begins — only when the
    /// fragment prefixes a real marker tag, so "a < B" stays visible.
    private static func partialTagStart(_ text: String) -> String.Index? {
        guard let angle = text.lastIndex(of: "<") else { return nil }
        let fragment = text[text.index(after: angle)...]
        guard !fragment.isEmpty,
              fragment.allSatisfy({ $0.isLetter && $0.isUppercase || $0 == "_" }),
              tags.contains(where: { $0.hasPrefix(fragment) }) else { return nil }
        return angle
    }

    private static func closeRange(in text: String, tag: String,
                                   after index: String.Index) -> Range<String.Index>? {
        if let tagged = text.range(of: "</\(tag)>", range: index..<text.endIndex) {
            return tagged
        }
        return text.range(of: "</>", range: index..<text.endIndex)
    }

    private static func blocks(in text: String, tag: String) -> [String] {
        var found: [String] = [], cursor = text.startIndex
        while let open = text.range(of: "<\(tag)>", range: cursor..<text.endIndex),
              let close = closeRange(in: text, tag: tag, after: open.upperBound) {
            found.append(String(text[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines))
            cursor = close.upperBound
        }
        return found
    }

    private static func bullets(_ block: String) -> [String] {
        block.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
    }
}

/// One chat row. `note` rows are app-side status lines (send failures,
/// interrupted turns) styled differently from both speakers.
struct AgentChatMessage: Identifiable, Equatable {
    enum Role: String, Equatable { case user, agent, note }
    var id: String
    var role: Role
    var text: String
    var turnID: String?
    var streaming = false
    var final: AgentFinalMessage?
}

/// Transcript state for one agent — messages plus live turn bookkeeping.
struct AgentChat: Equatable {
    var messages: [AgentChatMessage] = []
    var busy = false
    var activity: String?
    /// "turnID:itemID" → index into messages for the streaming agent row.
    var streamingItems: [String: Int] = [:]
}

@MainActor
final class AgentsViewModel: ObservableObject {
    @Published private(set) var agents: [CompanionAgent] = []
    @Published var selection: String?
    @Published private(set) var chats: [String: AgentChat] = [:]
    @Published var drafts: [String: String] = [:]

    /// Nil until `init`/`bind` supplies one or the first refresh lazily
    /// opens the persisted store — see `rosterProvider()`.
    private var roster: (any AgentRosterProviding)?
    private var runtime: (any AgentRuntimeHandling)?
    /// Token deltas coalesce off the published path: each streamed item's
    /// text accrues here and lands in `chats` on a short timer — one render
    /// per tick instead of one per token. Any other event flushes first so
    /// completions and turn ends never race their own stream.
    private var queuedDeltas: [String: [(key: String, turnID: String, delta: String)]] = [:]
    private var deltaFlushTask: Task<Void, Never>?

    /// Defaults to the persisted roster so the UI shows real agents before
    /// the coordinator binds the live store; runtime stays unbound until
    /// `bind` is called at integration.
    init(roster: (any AgentRosterProviding)? = nil,
         runtime: (any AgentRuntimeHandling)? = nil) {
        self.roster = roster
        self.runtime = runtime
    }

    /// Coordinator entry point — rebinds the live store after the shared
    /// instances exist. Events reach `handle` through the runtime's
    /// `onAgentEvent` fan-out, never a second stream consumer.
    func bind(roster: (any AgentRosterProviding)? = nil,
              runtime: (any AgentRuntimeHandling)? = nil) {
        if let roster { self.roster = roster }
        if let runtime, self.runtime == nil { self.runtime = runtime }
    }

    /// The bound roster, or the persisted agents.json materialized off the
    /// main actor — AgentStore's init does a blocking read and constructing
    /// it eagerly would stall launch (VoiceWindows builds this model inline).
    private func rosterProvider() async -> any AgentRosterProviding {
        if let roster { return roster }
        let loaded = await Task.detached { AgentStore(directory: AgentWorkspace.root()) }.value
        roster = loaded
        return loaded
    }

    /// Poll tick — the store and gate are pull-based, so the view calls
    /// this on a short timer. Cheap: an in-memory read plus a lock.
    func refresh() async {
        let list = await rosterProvider().agents()
        // An unchanged roster must not publish — the 2s poll would
        // otherwise re-render the whole window for nothing.
        if list != agents { agents = list }
        if let selection, !agents.contains(where: { $0.slug == selection }) {
            self.selection = agents.first?.slug
        } else if selection == nil {
            selection = agents.first?.slug
        }
    }

    /// Published transcript merged with any deltas still inside the
    /// coalescing window — readers always see the live text between flushes.
    func chat(for slug: String) -> AgentChat {
        let stored = chats[slug] ?? AgentChat()
        guard let queued = queuedDeltas[slug], !queued.isEmpty else { return stored }
        return Self.applying(queued, to: stored)
    }

    /// Raw stored transcript — every write path uses this. Writing a merged
    /// `chat(for:)` copy back would commit the queue early AND double it
    /// on the next flush.
    private func storedChat(for slug: String) -> AgentChat { chats[slug] ?? AgentChat() }

    /// Transcript bound — long sessions used to grow `messages` forever,
    /// making every render re-walk the whole history. Pruning shifts
    /// `streamingItems` indices, so the map is re-based with the drop.
    static let messageCap = 500

    private static func capped(_ transcript: AgentChat) -> AgentChat {
        var transcript = transcript
        let overflow = transcript.messages.count - messageCap
        guard overflow > 0 else { return transcript }
        transcript.messages.removeFirst(overflow)
        // Indices below the cut point to evicted rows — drop them so a
        // streaming item can't re-anchor to the wrong message.
        transcript.streamingItems = transcript.streamingItems.reduce(into: [:]) { out, pair in
            let shifted = pair.value - overflow
            if shifted >= 0 { out[pair.key] = shifted }
        }
        return transcript
    }

    /// Every `chats[slug]` write passes through the cap.
    private func commit(_ transcript: AgentChat, slug: String) {
        chats[slug] = Self.capped(transcript)
    }

    private static func applying(_ deltas: [(key: String, turnID: String, delta: String)],
                                 to transcript: AgentChat) -> AgentChat {
        var transcript = transcript
        for (key, turnID, delta) in deltas {
            if let index = transcript.streamingItems[key], index < transcript.messages.count {
                transcript.messages[index].text += delta
            } else {
                transcript.streamingItems[key] = transcript.messages.count
                transcript.messages.append(AgentChatMessage(
                    id: key, role: .agent, text: delta, turnID: turnID, streaming: true))
            }
        }
        return transcript
    }

    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.deltaFlushTask = nil
            self.flushDeltas()
        }
    }

    private func flushDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !queuedDeltas.isEmpty else { return }
        let queued = queuedDeltas
        queuedDeltas.removeAll()
        for (slug, deltas) in queued {
            commit(Self.applying(deltas, to: chats[slug] ?? AgentChat()), slug: slug)
        }
    }

    func send(_ rawText: String, to slug: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let agent = agents.first(where: { $0.slug == slug }) else { return }
        drafts[slug] = ""
        var transcript = self.storedChat(for: slug)
        let messageID = UUID().uuidString
        transcript.messages.append(AgentChatMessage(id: messageID, role: .user, text: text))
        commit(transcript, slug: slug)
        guard let runtime else {
            appendNote(slug: slug, "\(agent.name) isn't connected to a runtime yet.")
            return
        }
        Task {
            do {
                let turnID = try await runtime.send(to: agent, message: text)
                // Tag the local echo so the streamed userMessage item with
                // this turn doesn't post the text a second time.
                var transcript = self.storedChat(for: slug)
                if let index = transcript.messages.firstIndex(where: { $0.id == messageID }) {
                    transcript.messages[index].turnID = turnID
                    commit(transcript, slug: slug)
                }
            } catch {
                appendNote(slug: slug,
                    "Couldn't reach \(agent.name): \(error.localizedDescription)")
            }
        }
    }

    func interrupt(slug: String) {
        Task { _ = try? await runtime?.interrupt(slug: slug) }
    }

    func handle(_ event: AgentCodexEvent) {
        let slug = event.agentSlug
        if case let .agentMessageDelta(_, turnID, itemID, delta) = event.event {
            queuedDeltas[slug, default: []].append(
                (key: "\(turnID):\(itemID)", turnID: turnID, delta: delta))
            scheduleDeltaFlush()
            return
        }
        flushDeltas()
        var transcript = self.storedChat(for: slug)
        var changed = true
        switch event.event {
        case .turnStarted:
            transcript.busy = true
            transcript.activity = "Working…"
        case let .itemCompleted(_, turnID, item):
            guard let type = item["type"]?.string else { changed = false; break }
            if type == "agentMessage" {
                let key = "\(turnID):\(item["id"]?.string ?? "")"
                let streamed = transcript.streamingItems[key].flatMap {
                    $0 < transcript.messages.count ? transcript.messages[$0].text : nil
                }
                let parsed = AgentFinalMessage.parse(item["text"]?.string ?? streamed ?? "")
                if let index = transcript.streamingItems.removeValue(forKey: key),
                   index < transcript.messages.count {
                    transcript.messages[index].text = parsed.body
                    transcript.messages[index].streaming = false
                    transcript.messages[index].final = parsed
                } else {
                    transcript.messages.append(AgentChatMessage(
                        id: key, role: .agent, text: parsed.body, turnID: turnID, final: parsed))
                }
                transcript.activity = nil
                commit(transcript, slug: slug)
                transcript = self.storedChat(for: slug)
                changed = false
            } else if type == "userMessage", let text = item["text"]?.string {
                // Routine sends and coordinator-originated turns echo here;
                // locally-sent rows are tagged with their turnID already.
                let echoed = transcript.messages.contains {
                    $0.role == .user && ($0.turnID == turnID || $0.text == text)
                }
                if !echoed {
                    transcript.messages.append(AgentChatMessage(
                        id: "\(turnID):\(item["id"]?.string ?? UUID().uuidString)",
                        role: .user, text: text, turnID: turnID))
                } else {
                    changed = false
                }
            } else {
                changed = false
            }
        case let .turnCompleted(_, turn):
            transcript.busy = false
            transcript.activity = nil
            for key in Array(transcript.streamingItems.keys) where key.hasPrefix("\(turn.id):") {
                guard let index = transcript.streamingItems.removeValue(forKey: key),
                      index < transcript.messages.count else { continue }
                let parsed = AgentFinalMessage.parse(transcript.messages[index].text)
                transcript.messages[index].text = parsed.body
                transcript.messages[index].streaming = false
                transcript.messages[index].final = parsed
            }
            if let error = turn.errorMessage, !error.isEmpty {
                transcript.messages.append(AgentChatMessage(
                    id: "err-\(turn.id)", role: .note, text: error))
            }
        case let .error(message, willRetry, _, _):
            if willRetry {
                transcript.activity = "Retrying…"
            } else {
                // A terminal error without a following turnCompleted (dead
                // session) must not leave the chat spinning "Working…".
                transcript.busy = false
                transcript.activity = nil
                transcript.messages.append(AgentChatMessage(
                    id: UUID().uuidString, role: .note, text: message))
            }
        case .toolOutputDelta:
            // Output chunks arrive at stream rate — republish only on the
            // transition into "Running tools…", not on every chunk.
            if transcript.activity == "Running tools…" { changed = false }
            else { transcript.activity = "Running tools…" }
        default:
            changed = false
        }
        if changed { commit(transcript, slug: slug) }
    }

    private func appendNote(slug: String, _ text: String) {
        var transcript = self.storedChat(for: slug)
        transcript.messages.append(AgentChatMessage(id: UUID().uuidString, role: .note, text: text))
        commit(transcript, slug: slug)
    }
}

extension Routine {
    var scheduleLabel: String {
        switch everyMinutes {
        case ..<60: return "Every \(everyMinutes)m"
        case 60: return "Hourly"
        case 1440: return "Daily"
        default:
            let hours = everyMinutes / 60, minutes = everyMinutes % 60
            return minutes == 0 ? "Every \(hours)h" : "Every \(hours)h \(minutes)m"
        }
    }
}
