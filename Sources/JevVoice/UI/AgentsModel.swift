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
/// would steal half the events (replies, consent asks, turn states).
protocol AgentRuntimeHandling: Sendable {
    @discardableResult func send(to agent: CompanionAgent, message: String) async throws -> String
    func interrupt(slug: String) async throws
}

extension AgentRuntime: AgentRuntimeHandling {
    @discardableResult func send(to agent: CompanionAgent, message: String) async throws -> String {
        try await send(message, to: agent)
    }
    func interrupt(slug: String) async throws {
        try await bridge.interrupt(slug: slug)
    }
}

/// Consent seam — a subset of `ConsentGating` (`ComputerUseGate` conforms
/// with no extra members). The coordinator binds the real gate; until then
/// cards render empty.
protocol ConsentCoordinating: Sendable {
    func pending() -> [ConsentRequest]
    func approve(_ request: ConsentRequest)
    func deny(_ request: ConsentRequest)
}

extension ComputerUseGate: ConsentCoordinating {}

/// Asks the gate alone can't see: agent-emitted <COMPUTER_USE_REQUEST>
/// markers and gate asks preserved past their turn's end live on the
/// runtime's `pendingAsks`, and only `resolveConsent` routes a marker
/// approval so it arms the agent's next turn. The bound runtime conforms;
/// it is preferred over `consent` whenever both exist.
@MainActor
protocol AgentConsentAsking: Sendable {
    var pendingAsks: [ConsentRequest] { get }
    func resolveConsent(_ request: ConsentRequest, approved: Bool)
}

extension AgentRuntime: AgentConsentAsking {}

/// A turn's final message decoded per mirror/10-message-protocol.md. `body`
/// is the visible reply with EVERY bracketed marker block removed — raw
/// tags never reach the UI.
struct AgentFinalMessage: Equatable {
    var body: String
    var summary: String?
    var nextActions: [String] = []
    var doneTitle: String?
    var artifacts: [String] = []
    var computerUseAsks: [String] = []
    var hasStructuredBlocks: Bool {
        summary != nil || doneTitle != nil || !nextActions.isEmpty || !artifacts.isEmpty
    }

    private static let tags = ["SUMMARY", "NEXT_ACTIONS", "DONE_TITLE", "ARTIFACTS",
                               "ROUTINE", "COMPUTER_USE_REQUEST"]

    static func parse(_ text: String) -> AgentFinalMessage {
        var parsed = AgentFinalMessage(body: stripMarkers(text))
        parsed.summary = blocks(in: text, tag: "SUMMARY").first
        parsed.doneTitle = blocks(in: text, tag: "DONE_TITLE").first
        parsed.nextActions = bullets(blocks(in: text, tag: "NEXT_ACTIONS").first ?? "")
        parsed.artifacts = bullets(blocks(in: text, tag: "ARTIFACTS").first ?? "")
        parsed.computerUseAsks = AgentMarkers.computerUseRequests(in: text)
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

struct ConsentDisplay: Identifiable, Equatable {
    enum Resolution: String, Equatable { case pending, approved, denied, expired }
    var request: ConsentRequest
    var resolution: Resolution
    var id: String { request.id }
    /// ConsentRequest isn't Equatable — compare the fields the card shows.
    static func == (a: ConsentDisplay, b: ConsentDisplay) -> Bool {
        a.resolution == b.resolution && a.request.id == b.request.id
            && a.request.agentSlug == b.request.agentSlug
            && a.request.turnID == b.request.turnID
            && a.request.summary == b.request.summary
            && a.request.reason == b.request.reason
            && a.request.state == b.request.state
    }
}

/// Transcript state for one agent — messages plus live turn bookkeeping.
struct AgentChat: Equatable {
    var messages: [AgentChatMessage] = []
    var busy = false
    var activity: String?
    var consents: [ConsentDisplay] = []
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
    private var consent: (any ConsentCoordinating)?
    private var asks: (any AgentConsentAsking)?
    private static let resolvedConsentLimit = 12
    /// Token deltas coalesce off the published path: each streamed item's
    /// text accrues here and lands in `chats` on a short timer — one render
    /// per tick instead of one per token. Any other event flushes first so
    /// completions and turn ends never race their own stream.
    private var queuedDeltas: [String: [(key: String, turnID: String, delta: String)]] = [:]
    private var deltaFlushTask: Task<Void, Never>?

    /// Defaults to the persisted roster so the UI shows real agents before
    /// the coordinator binds the live store; runtime/consent stay unbound
    /// until `bind` is called at integration.
    init(roster: (any AgentRosterProviding)? = nil,
         runtime: (any AgentRuntimeHandling)? = nil,
         consent: (any ConsentCoordinating)? = nil,
         asks: (any AgentConsentAsking)? = nil) {
        self.roster = roster
        self.runtime = runtime
        self.consent = consent
        self.asks = asks
    }

    /// Coordinator entry point — rebinds the live store/gate after the
    /// shared instances exist. Events reach `handle` through the runtime's
    /// `onAgentEvent` fan-out, never a second stream consumer.
    func bind(roster: (any AgentRosterProviding)? = nil,
              runtime: (any AgentRuntimeHandling)? = nil,
              consent: (any ConsentCoordinating)? = nil,
              asks: (any AgentConsentAsking)? = nil) {
        if let roster { self.roster = roster }
        if let consent { self.consent = consent }
        if let runtime, self.runtime == nil { self.runtime = runtime }
        if let asks { self.asks = asks }
        // The runtime's pendingAsks cover marker + post-turn asks the bare
        // gate can't see — prefer it whenever the bound runtime conforms.
        if self.asks == nil, let bound = runtime ?? self.runtime {
            self.asks = bound as? (any AgentConsentAsking)
        }
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
        refreshConsents()
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
            chats[slug] = Self.applying(deltas, to: chats[slug] ?? AgentChat())
        }
    }

    func send(_ rawText: String, to slug: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let agent = agents.first(where: { $0.slug == slug }) else { return }
        drafts[slug] = ""
        var transcript = self.storedChat(for: slug)
        let messageID = UUID().uuidString
        transcript.messages.append(AgentChatMessage(id: messageID, role: .user, text: text))
        chats[slug] = transcript
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
                    chats[slug] = transcript
                }
            } catch {
                appendNote(slug: slug,
                    "Couldn't reach \(agent.name): \(error.localizedDescription)")
            }
        }
    }

    func interrupt(slug: String) {
        Task { try? await runtime?.interrupt(slug: slug) }
    }

    func resolve(_ display: ConsentDisplay, approved: Bool) {
        guard let slug = display.request.agentSlug else { return }
        var transcript = self.storedChat(for: slug)
        guard let index = transcript.consents.firstIndex(
            where: { $0.id == display.id && $0.resolution == .pending }) else { return }
        transcript.consents[index].resolution = approved ? .approved : .denied
        chats[slug] = transcript
        // Marker asks only resolve through the runtime — approving arms the
        // agent's NEXT turn; a bare gate.approve would mint a stray nil-turn
        // one-shot instead. resolveConsent covers both ask kinds.
        if let asks { asks.resolveConsent(display.request, approved: approved) }
        else if approved { consent?.approve(display.request) } else { consent?.deny(display.request) }
    }

    /// Reconciles displayed asks with the ask source: new pendings appear,
    /// locally-pending asks the source no longer reports flip to `expired`
    /// (resolved elsewhere or superseded by a turn change).
    func refreshConsents() {
        // pendingAsks already merges gate asks with agent marker asks — the
        // gate alone would expire every post-turn ask that is still live.
        let pending = (asks?.pendingAsks ?? consent?.pending() ?? []).filter { $0.agentSlug != nil }
        for request in pending {
            var transcript = self.storedChat(for: request.agentSlug!)
            let display = ConsentDisplay(request: request, resolution: .pending)
            if let index = transcript.consents.firstIndex(where: { $0.id == request.id }) {
                // Same ask still pending — republishing an identical card
                // every poll tick re-renders the chat for nothing.
                guard transcript.consents[index] != display else { continue }
                transcript.consents[index] = display
            } else {
                transcript.consents.append(display)
            }
            chats[request.agentSlug!] = transcript
        }
        let live = Set(pending.map(\.id))
        for slug in Array(chats.keys) {
            var transcript = chats[slug]!, changed = false
            for index in transcript.consents.indices
                where transcript.consents[index].resolution == .pending && !live.contains(transcript.consents[index].id) {
                transcript.consents[index].resolution = .expired
                changed = true
            }
            let resolved = transcript.consents.filter { $0.resolution != .pending }
            if resolved.count > Self.resolvedConsentLimit {
                // Trim only resolved cards — a pending ask ahead of them in
                // the array must never be dropped to enforce the cap.
                var drop = resolved.count - Self.resolvedConsentLimit
                transcript.consents.removeAll { display in
                    guard display.resolution != .pending, drop > 0 else { return false }
                    drop -= 1
                    return true
                }
                changed = true
            }
            if changed { chats[slug] = transcript }
        }
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
                chats[slug] = transcript
                // A fresh COMPUTER_USE_REQUEST lands in the gate about now —
                // pull it rather than waiting for the next poll tick.
                if !parsed.computerUseAsks.isEmpty { refreshConsents() }
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
        if changed { chats[slug] = transcript }
    }

    private func appendNote(slug: String, _ text: String) {
        var transcript = self.storedChat(for: slug)
        transcript.messages.append(AgentChatMessage(id: UUID().uuidString, role: .note, text: text))
        chats[slug] = transcript
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
