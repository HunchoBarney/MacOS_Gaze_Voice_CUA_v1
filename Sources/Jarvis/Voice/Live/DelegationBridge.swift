import Foundation
import JarvisCore

/// One delegation the ledger admitted, as the spine receives it.
struct DelegatedRequest: Sendable, Equatable {
    /// Also the capture id the coordinator reports the outcome under.
    let id: UUID
    /// The person's own words for this request, from the transcript.
    let text: String
    /// False after a Standby resume or in reply to an alert, where anyone
    /// in the room could have spoken: a consequential press asks first (D3).
    let speakerVerified: Bool
    /// When the first "this", "that", "here" or "it" was said, in
    /// `ProcessInfo.systemUptime` seconds, so writing (L7) resolves it at
    /// word time rather than call time.
    let deicticTime: TimeInterval?
}

enum DelegationSpineReply: Sendable, Equatable {
    /// Work started. Its outcome arrives later through
    /// `DelegationBridge.taskEvent`.
    case started(String)
    /// Answered, refused or cancelled at once.
    case answered(String)
}

/// The existing spine behind the bridge: VoiceTaskCoordinator, then
/// IntentRouter, the fast lane, Jev, Cua or native, consent, undo and
/// verification.
@MainActor
protocol DelegationSpine: AnyObject {
    func begin(_ request: DelegatedRequest) async -> DelegationSpineReply
}

/// Turns GPT-Live client delegations into Jarvis requests, once each.
///
/// `session.delegation.created` says only that Live wants help, at
/// `offset_ms`. The bridge keeps the person's transcript, waits briefly so a
/// "no wait, stop" can still arrive, takes the words since the last request
/// and hands them to the spine. The ledger admits each delegation once and
/// gives each stretch of words to at most one request, so a duplicate
/// delegation or a replacement session after a reconnect finds nothing new
/// to do. Results go back to Live as `session.thinking.append` (progress)
/// or `session.commentary.append` (the verified outcome) with the
/// delegation id. Live's own speech never acts.
@MainActor
final class DelegationBridge {
    enum Origin: Sendable { case wakeWord, alertReply }

    struct Timing: Sendable {
        /// How far past `offset_ms` the person's words belong to this
        /// request, and how long the transcript gets to cover that.
        var settleMs = 300
        /// The longest wait before the request goes ahead anyway.
        var maxWait: Duration = .milliseconds(300)
        /// The extra wait when no new words have arrived yet, so a
        /// transcript that lags the delegation isn't lost.
        var lagWait: Duration = .seconds(2)
    }

    private let live: LiveSessionSending
    private let spine: DelegationSpine
    private let timing: Timing
    private let sleep: @Sendable (Duration) async -> Void
    private let uptime: () -> TimeInterval
    private let resolveReferent: ((TimeInterval) async -> String?)?

    private(set) var ledger = DelegationLedger()
    private var sessionID: String?
    private var sessionStartUptime: TimeInterval = 0
    private var origin = Origin.wakeWord
    private var resumed = false
    private var preface: String?
    private var input: [LiveTranscriptDelta] = []
    /// Delegations whose words are still settling, with whether the
    /// speaker was trusted when Live asked.
    private var waiting: [(key: DelegationKey, offsetMs: Int, verified: Bool)] = []
    private var running: [UUID: DelegationKey] = [:]
    private var heldForNextSession: [String] = []
    /// Recent appends by event id, so a rejection can be retried once.
    private var sent: [(append: LiveAppend, retried: Bool)] = []

    init(live: LiveSessionSending, spine: DelegationSpine, timing: Timing = .init(),
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         resolveReferent: ((TimeInterval) async -> String?)? = nil) {
        self.live = live; self.spine = spine; self.timing = timing
        self.sleep = sleep; self.uptime = uptime; self.resolveReferent = resolveReferent
    }

    /// Whether the words in this session can be trusted as the person's:
    /// true in a session opened with the name until Standby resumes it.
    var speakerVerified: Bool { origin == .wakeWord && !resumed }

    /// A new conversation, before its session connects. `preface` is what
    /// the person said with the name, transcribed on the Mac before Live
    /// was listening.
    func open(origin: Origin, preface: String? = nil) {
        self.origin = origin
        resumed = false
        let trimmed = preface?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.preface = trimmed.isEmpty ? nil : trimmed
    }

    func handle(_ event: LiveSessionEvent) {
        switch event {
        case .started(let id):
            declineWaiting("the session ended")
            sessionID = id
            sessionStartUptime = uptime()
            input = []
            let held = heldForNextSession
            heldForNextSession = []
            for content in held { send(.commentary, content, for: nil) }
        case .inputTranscript(let delta):
            guard sessionID != nil else { return }
            input.append(delta)
            if !waiting.isEmpty, Self.takesBack(delta.text, fromStart: true) {
                stopWaiting(through: delta.endMs)
                return
            }
            for entry in waiting where heardMs >= entry.offsetMs + timing.settleMs { settle(entry.key) }
        case .outputTranscript:
            break
        case .delegation(let delegation):
            receive(delegation)
        case .paused, .usage:
            break
        case .resumed:
            resumed = true
        case .error(let error):
            guard let id = error.clientEventID, let index = sent.firstIndex(where: { $0.append.eventID == id }) else { return }
            let (append, retried) = sent.remove(at: index)
            if !retried {
                transmit(LiveAppend(kind: append.kind, content: append.content, delegationID: append.delegationID),
                         retried: true)
            } else if append.kind == .commentary, append.delegationID != nil {
                transmit(LiveAppend(kind: .commentary, content: append.content, delegationID: nil), retried: true)
            }
        case .closed:
            declineWaiting("the session ended")
            sessionID = nil
            sent = []
        }
    }

    /// A local "stop" or "cancel": every request still waiting is dropped
    /// before it reaches the spine. Work already handed over keeps going
    /// and reports honestly.
    func bargeIn() {
        stopWaiting(through: heardMs)
    }

    /// Session ms up to which the input transcript has arrived.
    private var heardMs: Int { input.map(\.endMs).max() ?? 0 }

    /// Whether any words past the last request have arrived yet.
    private func hasNewWords(in session: String) -> Bool {
        let start = ledger.consumed(session: session)
        return preface != nil || input.contains {
            $0.startMs >= start && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The coordinator's `taskEventSink`: a question or the outcome of
    /// work the bridge started.
    func taskEvent(captureID: UUID?, payload: String) {
        guard let captureID, let key = running[captureID] else { return }
        let (kind, say) = Self.decode(payload)
        if kind != VoiceToolResult.Kind.taskQuestion { running[captureID] = nil }
        guard !say.isEmpty else { return }
        send(.commentary, say, for: key)
    }

    private func receive(_ delegation: LiveDelegation) {
        guard let session = sessionID else { return }
        let key = DelegationKey(liveSessionID: session, delegationID: delegation.id)
        guard ledger.admit(key) else { return }
        for earlier in waiting { settle(earlier.key) }
        waiting.append((key, delegation.offsetMs, speakerVerified))
        if heardMs >= delegation.offsetMs + timing.settleMs {
            settle(key)
            return
        }
        Task { [weak self, sleep, maxWait = timing.maxWait, lagWait = timing.lagWait] in
            await sleep(maxWait)
            if let self, !self.hasNewWords(in: key.liveSessionID) { await sleep(lagWait) }
            self?.settle(key)
        }
    }

    /// The commit point. The ledger records the request before the spine
    /// sees it; from here on a "stop" is a new request, not a take-back.
    private func settle(_ key: DelegationKey) {
        guard let index = waiting.firstIndex(where: { $0.key == key }) else { return }
        let (_, offsetMs, verified) = waiting.remove(at: index)
        let end = offsetMs + timing.settleMs
        let words = ledger.consume(session: key.liveSessionID, through: end).map { start in
            input.filter { $0.startMs >= start && $0.startMs < end }
        } ?? []
        let text = ([preface ?? ""] + words.map(\.text)).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        preface = nil
        if text.isEmpty {
            _ = ledger.decline(key, reason: "nothing new")
            if running.isEmpty {
                send(.thinking, "No new request: those words were already handled. Nothing else was done.", for: key)
            } else {
                send(.commentary, "I'm already working on that.", for: key)
            }
            return
        }
        if Self.takesBack(text, fromStart: false) {
            _ = ledger.decline(key, reason: "taken back")
            send(.thinking, "Nothing was done: the person took that back or changed it mid-sentence. If they still want something, ask what.", for: key)
            return
        }
        let proposal = VoiceAdmissionPolicy.propose(text, context: VoiceAdmissionContext(), speech: true)
        if [.negated, .contradictory].contains(proposal.risk) {
            _ = ledger.decline(key, reason: proposal.reason)
            send(.thinking, "Nothing was done: the request said not to, or contradicted itself. Ask what they want.", for: key)
            return
        }
        let id = UUID()
        guard ledger.commit(key, request: id) else { return }
        running[id] = key
        let wordTime = Self.deicticStartMs(in: words).map { sessionStartUptime + Double($0) / 1000 }
        Task { [weak self] in
            guard let self else { return }
            if let wordTime, let resolveReferent, let referent = await resolveReferent(wordTime) {
                self.send(.thinking, referent, for: key)
            }
            let reply = await self.spine.begin(DelegatedRequest(id: id, text: text, speakerVerified: verified,
                                                                deicticTime: wordTime))
            switch reply {
            case .started(let say):
                self.send(.thinking, "Started: \(say). It isn't finished; don't say it's done until the result arrives.", for: key)
            case .answered(let say):
                self.running[id] = nil
                self.send(.commentary, say, for: key)
            }
        }
    }

    private func stopWaiting(through endMs: Int) {
        guard !waiting.isEmpty else { return }
        let stopped = waiting
        waiting = []
        for entry in stopped {
            _ = ledger.consume(session: entry.key.liveSessionID, through: endMs)
            guard ledger.decline(entry.key, reason: "barge-in") else { continue }
            send(.thinking, "The person stopped this before anything happened. Nothing was done.", for: entry.key)
        }
    }

    private func declineWaiting(_ reason: String) {
        for entry in waiting { _ = ledger.decline(entry.key, reason: reason) }
        waiting = []
    }

    /// Sends to the open session. An update about a delegation from an
    /// earlier session goes without its id, which only that session knew;
    /// a spoken result with no session open waits for the next one.
    private func send(_ kind: LiveAppend.Kind, _ content: String, for key: DelegationKey?) {
        guard let sessionID else {
            if kind == .commentary { heldForNextSession = Array((heldForNextSession + [content]).suffix(4)) }
            return
        }
        let delegationID = key.flatMap { $0.liveSessionID == sessionID ? $0.delegationID : nil }
        transmit(LiveAppend(kind: kind, content: content, delegationID: delegationID), retried: false)
    }

    /// A rejected append is sent again once. If that fails too, a spoken
    /// result tied to a delegation goes as general commentary, so the person
    /// still hears it.
    private func transmit(_ append: LiveAppend, retried: Bool) {
        sent = Array((sent + [(append, retried)]).suffix(16))
        live.send(append)
    }

    private static let deicticWords: Set<String> = ["this", "that", "these", "those", "here", "it"]

    /// Session ms of the fragment that holds the first "this", "that",
    /// "here" or "it", which is when the gaze fixation counts.
    static func deicticStartMs(in words: [LiveTranscriptDelta]) -> Int? {
        words.first { delta in
            !deicticWords.isDisjoint(with: tokens(delta.text).filter { $0 != "|" })
        }?.startMs
    }

    private static let takeBackPhrases: [[String]] = [["no", "wait"], ["never", "mind"], ["nevermind"],
                                                       ["hold", "on"], ["forget", "it"], ["actually", "no"]]
    private static let takeBackWords: Set<String> = ["stop", "cancel", "wait"]

    /// Whether words take a request back: "no wait", "never mind", "hold
    /// on", "forget it" or "actually no" anywhere after the first word, or a
    /// last clause that is only "stop", "cancel" or "wait". `fromStart`
    /// checks a fragment that may open with them, where a lone "stop" or
    /// "no wait" is enough.
    static func takesBack(_ text: String, fromStart: Bool) -> Bool {
        let words = tokens(text)
        let plain = words.filter { $0 != "|" }
        let first = fromStart ? 0 : 1
        guard plain.count > first else { return false }
        for i in first..<plain.count where takeBackPhrases.contains(where: { plain[i...].starts(with: $0) }) {
            return true
        }
        let clauses = words.split(separator: "|").map(Array.init)
        guard let last = clauses.last, last.count == 1, takeBackWords.contains(last[0]) else { return false }
        return fromStart || clauses.count > 1
    }

    /// Lowercased words with "|" where a clause breaks.
    private static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                word.append(ch)
            } else if ch == "'" || ch == "\u{2019}" {
                continue
            } else {
                if !word.isEmpty { out.append(word); word = "" }
                if ",.;:!?\u{2014}".contains(ch), out.last != "|" { out.append("|") }
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    static func reply(fromPayload payload: String) -> DelegationSpineReply {
        let (status, say) = decode(payload, field: "status")
        return status == VoiceToolResult.Status.started ? .started(say) : .answered(say)
    }

    private static func decode(_ payload: String, field: String = "kind") -> (String?, String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
        return (object?[field] as? String, object?["say"] as? String ?? "")
    }
}

extension VoiceTaskCoordinator: DelegationSpine {
    /// Words that answer a parked question go to that question; anything
    /// else is a new voice task, where the memory and writing intents also
    /// live. The referent line stays out of `transcriptHint`: writing and
    /// guide mode read that as the person's own words.
    func begin(_ request: DelegatedRequest) async -> DelegationSpineReply {
        if tasks.contains(where: \.awaitingAnswer), !VoiceAdmissionPolicy.explicitNewRequest(request.text) {
            return DelegationBridge.reply(fromPayload: await respondToTask(request.text) ?? "")
        }
        return DelegationBridge.reply(fromPayload: await beginVoiceTask(
            request.text, captureID: request.id, speakerVerified: request.speakerVerified,
            writing: WritingInput(deicticTime: request.deicticTime)))
    }
}
