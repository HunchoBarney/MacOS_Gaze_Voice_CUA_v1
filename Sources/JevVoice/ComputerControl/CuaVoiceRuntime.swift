import AppKit
import Combine
import CoreGraphics
import Foundation
import JevVoiceCore
import OSLog

/// The JSON payload every voice tool result and pushed task event carries.
/// The realtime lane voices `say` verbatim and routes on `status` — so `say`
/// is always speakable text (no dashes, quotes or parens, word-capped) while
/// `detail`/`options` stay machine-readable context. `kind` marks pushed
/// events: "task_outcome" for settled work, "task_question" for parked asks.
struct VoiceToolResult {
    var kind: String?
    var status: String
    var say: String
    var detail: String?
    var options: [String]?

    init(kind: String? = nil, status: String, say: String,
         detail: String? = nil, options: [String]? = nil) {
        self.kind = kind; self.status = status; self.say = say
        self.detail = detail; self.options = options
    }

    /// Compact JSON, fixed key order: kind, status, say, detail, options.
    /// The lane's acceptance check matches `"status":"started"` literally —
    /// no whitespace after colons.
    func encoded() -> String {
        var parts: [String] = []
        if let kind { parts.append("\"kind\":\(Self.jsonString(kind))") }
        parts.append("\"status\":\(Self.jsonString(status))")
        parts.append("\"say\":\(Self.jsonString(say))")
        if let detail { parts.append("\"detail\":\(Self.jsonString(detail))") }
        if let options {
            parts.append("\"options\":[\(options.map(Self.jsonString).joined(separator: ","))]")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String,
              let say = object["say"] as? String else { return nil }
        self.kind = object["kind"] as? String
        self.status = status
        self.say = say
        self.detail = object["detail"] as? String
        self.options = object["options"] as? [String]
    }

    private static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// The spoken contract, enforced deterministically: dashes become commas
    /// or spaces, quotes/parens/brackets drop, and the line ends on terminal
    /// punctuation inside the word cap.
    static func spoken(_ text: String, words cap: Int) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"[—–‒]"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(^|\s)[-‑](\s|$)"#, with: "$1, $2", options: .regularExpression)
        s = s.replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: #"["“”`()\[\]{}<>#*|]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: ";", with: ",")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.:?!])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #",([,.]+)"#, with: "$1", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > cap { words = Array(words.prefix(cap)) }
        s = words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
        guard !s.isEmpty else { return s }
        if !s.hasSuffix(".") && !s.hasSuffix("?") && !s.hasSuffix("!") { s += "." }
        return s
    }

    /// "opening Spotify" from "open Spotify": the leading verb as a gerund
    /// plus the first few object words — deterministic, no model call. Nil
    /// when no clean action verb leads the instruction.
    static func gerundPhrase(for instruction: String) -> String? {
        var words = instruction.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let filler: Set<String> = ["please", "jarvis", "jev", "hey", "ok", "okay",
                                   "can", "could", "would", "will", "you", "just",
                                   "kindly", "go"]
        while let first = words.first,
              filler.contains(first.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)) {
            words.removeFirst()
        }
        guard let verb = words.first, let gerund = gerund(of: verb) else { return nil }
        var rest: [String] = []
        for word in words.dropFirst() {
            let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: ",;:."))
            if ["then", "afterwards", "after", "next", "please"].contains(cleaned.lowercased()) { break }
            if cleaned.isEmpty || rest.count >= 5 { break }
            rest.append(cleaned)
        }
        return ([gerund] + rest).joined(separator: " ")
    }

    private static func gerund(of verb: String) -> String? {
        let w = verb.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard w.count > 1, w.allSatisfy(\.isLetter) else { return nil }
        let nonActions: Set<String> = ["what", "when", "where", "who", "whom", "why",
            "how", "which", "the", "a", "an", "it", "its", "is", "are", "was",
            "were", "am", "be", "i", "we", "they", "he", "she", "me", "him",
            "them", "us", "my", "your", "his", "her", "their", "our", "this",
            "that", "these", "those", "there", "here", "if", "but", "not", "no",
            "yes", "to", "for", "in", "on", "at", "of", "as", "by", "or", "and",
            "so", "do", "does", "did", "have", "has", "had", "shall", "should",
            "may", "might", "must", "some", "any", "all"]
        guard !nonActions.contains(w) else { return nil }
        let doubles: Set<String> = ["run", "stop", "quit", "set", "cut", "hit",
            "put", "shut", "sit", "win", "plan", "drag", "drop", "grab", "tap",
            "hop", "skip", "swap", "wrap", "chat", "begin", "forget"]
        if doubles.contains(w) { return w + String(w.last!) + "ing" }
        if w.hasSuffix("ie") { return String(w.dropLast(2)) + "ying" }
        if w.count <= 2 || w.hasSuffix("ee") { return w + "ing" }
        if w.hasSuffix("e") { return String(w.dropLast()) + "ing" }
        return w + "ing"
    }
}

extension VoiceToolResult {
    enum Status {
        static let started = "started"
        static let resumed = "resumed"
        static let cancelled = "cancelled"
        static let delegated = "delegated"
        static let sent = "sent"
        static let refused = "refused"
        static let nothingPending = "nothing_pending"
        static let nothingRunning = "nothing_running"
        static let ok = "ok"
        static let question = "question"
    }
    enum Kind {
        static let taskOutcome = "task_outcome"
        static let taskQuestion = "task_question"
    }
}

@MainActor
final class CuaVoiceRuntime {
    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "cua-runtime")

    private static let observationTools: Set<String> = [
        "list_apps", "get_accessibility_tree", "list_windows", "get_window_state",
        "get_browser_state", "parse_visual_regions",
        // Raising a window is a precondition for interactive lanes, not a
        // content mutation — a cancelled approval that only ever raised a
        // window dispatched no task effect.
        "bring_to_front"
    ]

    private static func dispatchesEffect(tool: String, arguments: [String: JSONValue]) -> Bool {
        if observationTools.contains(tool) { return false }
        return tool != "browser_dialog" || arguments["action"] != .string("inspect")
    }

    /// One Work is a single execution attempt of a stable dialogue intent.
    /// `status` is derived presentation only: nothing may gate on the string.
    final class Work: Identifiable {
        enum Phase { case queued, waiting, working }
        /// Task identity: selection, approval, cancellation and app leases stay on this ID.
        let id = UUID()
        /// Stable dialogue intent this attempt belongs to.
        let intentID: UUID
        /// Planned dialogue attempt identity; the worker binds it via `dialogue.begin`.
        let attemptID: UUID
        /// Intent revision this attempt was accepted against.
        var intentRevision = 0
        let label: String
        let request: String
        var message = ""
        var bundle: String?
        var window: Int?
        /// Attempted dispatch only — verified/uncertain effects live in `outcome`.
        var dispatchedEffect = false
        /// The utterance's literal insert payload + content mode, kept for the
        /// inspector's "text payload" line. The spec — not replayed words —
        /// always carries the payload to the drive loop.
        var literalText: String?
        var contentMode: CuaContentMode = .control
        var provenance: SpeechProvenance?
        var worker: Task<Void, Never>?
        var elapsedMs: Double = 0
        var timings: [String: Double] = [:]
        /// systemOne token usage across the run's judge calls — counts, not
        /// milliseconds, so they live beside `timings` rather than inside it.
        var judgeInputTokens = 0
        var judgeOutputTokens = 0
        var active = true
        /// The attempt parked on a dialogue question — its task_question push is
        /// the live ask, so settle must not contradict it with a "blocked"
        /// outcome or show the task as failed.
        var questionParked = false
        /// Deterministic-lane work — a verified outcome is visible on screen
        /// (the app opened, the window focused), so the settle push stays
        /// silent instead of spending a spoken line confirming the obvious.
        var tookFastLane = false
        var approval: String?
        var approvalContinuation: CheckedContinuation<Bool, Never>?
        /// Uptime stamp of the last park — consent or question — so parked
        /// asks keep a deterministic order for ordinal hints.
        var askParkedAt: Double = 0
        var phase: Phase = .queued
        var outcome: CuaDialogueState.Outcome?
        var stopRequested = false
        var attemptBegan = false
        init(label: String, request: String, intentID: UUID, attemptID: UUID) {
            self.label = label; self.request = request
            self.intentID = intentID; self.attemptID = attemptID
        }
        var status: String {
            if approval != nil || approvalContinuation != nil { return "Needs confirmation" }
            if stopRequested { return active ? "Stopping" : "Cancelled" }
            guard active else {
                switch outcome {
                case .verified, .verifiedFact: return "Completed"
                case .partial: return "Partial"
                case .uncertain: return "Uncertain"
                case .blocked, .failed: return "Failed"
                case .cancelled, .none: return "Cancelled"
                }
            }
            switch phase {
            case .queued: return "Queued"
            case .waiting: return "Waiting"
            case .working: return "Working"
            }
        }
    }

    private final class Invocation {
        var work: Work?
        var timings: [String: Double] = [:]
        let receivedAt: Double
        init(receivedAt: Double) { self.receivedAt = receivedAt }
    }

    /// What one accepted instruction became — the worker's dispatch plan.
    /// The realtime model's tool choice IS the decision; this is only the
    /// deterministic-route vs drive-loop split.
    private enum AcceptedKind {
        /// Deterministic primitive: zero model calls to resolve, runFastLane proves it.
        case fastLane(CuaTaskAgent.FastResolution, goal: String)
        /// The instruction runs the observe → judge → dispatch → verify loop.
        case execute(TaskSpec)
    }

    private let config: Config
    private let judge: CuaTaskAgent.Judge
    private let requiresAPIKey: Bool
    private let makeConnection: () -> CuaConnection
    /// Injectable probe — unit tests must not depend on the host's real
    /// console lock state; production uses the CGSession read below.
    private let screenLocked: () -> Bool
    /// Persistent-agent seam (delegate / follow-up / memory). Nil means the
    /// agents runtime is not wired and agent decisions refuse honestly.
    /// Settable post-init: the agents runtime starts after the controller's
    /// own runtime exists, so main wires the bridge when it finishes booting.
    var agentBridge: (any AgentBridging)?
    /// Test seam: scripted scenarios stub deterministic fast-lane resolution.
    /// Production leaves this nil and uses CuaTaskAgent.resolveFastLane.
    /// (goal, appHint, frontmostBundleOverride, apps) — the override is the
    /// app frontmost before Jarvis's own UI took key status; an accessory app
    /// frontmost mid-turn must not steal "frontmost" targeting.
    private let fastLaneResolver: (@MainActor (String, String?, String?, [JSONValue]) -> CuaTaskAgent.FastResolution?)?
    /// Front-app check handed to each drive loop — real NSWorkspace in
    /// production; simulated drivers pretend their fixture app is frontmost.
    private let isFrontmostApp: ((Int) -> Bool)?
    /// Advisory planner seam. Nil (the default) resolves to the production
    /// `CuaPlanner.shared`, gated by `Config.plannerEnabled`; an injected
    /// client bypasses the flag — same posture as `judge:`/`fastLaneResolver:`
    /// — but never the JARVIS_PLANNER=0 kill switch, which skips all of them.
    private let planner: (any CuaPlanning)?
    /// Per-app memory feeding `previous_context` — always on; the kill
    /// switch gates the planner only.
    private let appMemory: CuaAppMemory
    /// App/focus/pasteboard leases — the shared registry the drive loop and
    /// the agents lane also hold, so one canonical app identity serializes
    /// dispatch across every lane.
    private let registry = CuaLaneRegistry.shared
    private let appInventory = CuaAppInventory()
    private(set) var tasks: [Work] = []
    private(set) var selectedID: UUID?

    private var nextLabel = 0
    private let instanceLabel = String(UUID().uuidString.prefix(6))
    /// One driver session per runtime: protected-resource grants — including
    /// existing-profile browser attach — are keyed to (session, transport,
    /// resource). A per-task session re-ran the browser's visible
    /// remote-debugging setup on every command; a per-run session makes the
    /// standing approval actually stick. `end_session` fires at shutdown.
    private var sessionConnection: CuaConnection?

    /// systemOne's measured latency and token usage can't flow through the
    /// Judge signature (it returns only answers), so the production judge
    /// drops each call's facts here and makeTimedJudge lifts them onto the
    /// owning invocation — the last completed call is always the one the
    /// wrapping defer just timed.
    private final class JudgeCallFacts: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (latencyMs: Double, inputTokens: Int?, outputTokens: Int?)?
        func set(_ value: (Double, Int?, Int?)) { lock.lock(); stored = value; lock.unlock() }
        func take() -> (latencyMs: Double, inputTokens: Int?, outputTokens: Int?)? {
            lock.lock(); defer { lock.unlock() }
            defer { stored = nil }
            return stored
        }
    }
    private let judgeFacts = JudgeCallFacts()

    private var sessionStartTask: Task<CuaConnection, Error>?
    private var sessionLabel: String { "Jarvis runtime · \(instanceLabel)" }
    /// Settings observers — the cursor policy re-applies on the live session
    /// transport so a mid-session toggle doesn't wait for a re-mint.
    private var configObservers: Set<AnyCancellable> = []
    /// The single owner of intents, attempts, relationships, questions and facts.
    /// Readable for diagnostics and tests; only the runtime mutates it.
    private(set) var dialogue = CuaDialogueState()
    /// The intent's execution contract — the TaskSpec bound at spawn —
    /// retained for question-resume merging and diagnostics.
    private var intentSpecs: [UUID: TaskSpec] = [:]
    var onChange: () -> Void = {}

    /// Live decision feed — every real transition (heard, routed, dispatched,
    /// verified, answered) appended at the point it happens. The Activity tab
    /// renders it; nothing here is logged speculatively.
    let feed = DecisionFeed()

    /// The CGSession screen-lock read used as the default probe.
    nonisolated static var consoleScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        let users = session["IOConsoleUsers"] as? [[String: Any]] ?? []
        return users.contains { ($0["CGSSessionScreenIsLocked"] as? Bool) == true }
    }

    init(config: Config, makeConnection: @escaping () -> CuaConnection = {
        // Pool-bound: the voice lane proxies onto the shared daemon
        // alongside agent lanes instead of spawning a second driver stack.
        // A refusal storm on this lane means the daemon itself is sick —
        // recycle it so the next call mints a healthy one.
        CuaConnection(socketProvider: { try await CuaConnectionPool.shared.socket() },
                      onDaemonHealthFault: { Task { await CuaConnectionPool.shared.invalidateDaemon() } })
    },
         judge: CuaTaskAgent.Judge? = nil, dialogue: CuaDialogueState = CuaDialogueState(),
         agentBridge: (any AgentBridging)? = nil,
         fastLaneResolver: (@MainActor (String, String?, String?, [JSONValue]) -> CuaTaskAgent.FastResolution?)? = nil,
         screenLocked: @escaping () -> Bool = { CuaVoiceRuntime.consoleScreenLocked },
         isFrontmostApp: ((Int) -> Bool)? = nil,
         planner: (any CuaPlanning)? = nil,
         appMemory: CuaAppMemory = .shared) {
        self.config = config
        self.makeConnection = makeConnection
        self.dialogue = dialogue
        self.screenLocked = screenLocked
        self.agentBridge = agentBridge
        self.fastLaneResolver = fastLaneResolver
        self.isFrontmostApp = isFrontmostApp
        self.planner = planner
        self.appMemory = appMemory
        if let judge {
            self.judge = judge
            self.requiresAPIKey = false
        } else {
            self.requiresAPIKey = true
            let judgeFacts = self.judgeFacts
            self.judge = { state, questions in
                let result = try await JevClient(apiKey: config.apiKey)
                    .systemOne(state: state, questions: questions)
                judgeFacts.set((result.latencyMs,
                                result.response.usage?.inputTokens,
                                result.response.usage?.outputTokens))
                return result.response.answers
            }
        }
        // Lease identity canonicalizes through our roster: "Spotify" and
        // "com.spotify.client" hold one app lane. The resolver reads the
        // cached app list; an unresolvable spelling falls back to its
        // lowercase-trim self, so identical spellings still serialize.
        let registry = self.registry
        Task {
            await registry.setAppIdentityResolver { [weak self] spelling in
                await self?.canonicalAppIdentity(spelling)
                    ?? spelling.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }
        // A mid-session Settings toggle must not wait for a transport
        // re-mint — re-apply on the live session connection when one exists.
        config.$agentCursorEnabled.dropFirst().sink { [weak self] enabled in
            Task { @MainActor [weak self] in self?.applyCursorPolicy(enabled) }
        }.store(in: &configObservers)
    }

    /// Push the cursor-visibility policy onto the already-minted session.
    /// Best-effort like the mint path — a daemon too old for the cursor
    /// tools still serves the session.
    private func applyCursorPolicy(_ enabled: Bool) {
        guard let connection = sessionConnection else { return }
        let label = sessionLabel
        Task {
            _ = try? await connection.call("set_agent_cursor_enabled", arguments: [
                "session": .string(label),
                "enabled": .bool(enabled)])
        }
    }

    /// Lease identity for the shared registry — a display name or bundle
    /// spelling resolves to the bundle id the roster knows; everything else
    /// normalizes to lowercase-trim.
    private func canonicalAppIdentity(_ spelling: String) async -> String {
        let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased().hasPrefix("pid:") { return trimmed.lowercased() }
        if let apps = try? await appList(
                invocation: Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)),
           let match = apps.first(where: {
               $0["bundle_id"]?.string?.caseInsensitiveCompare(trimmed) == .orderedSame
                   || $0["name"]?.string?.caseInsensitiveCompare(trimmed) == .orderedSame
           }), let bundle = match["bundle_id"]?.string, !bundle.isEmpty {
            return bundle.lowercased()
        }
        return trimmed.lowercased()
    }

    /// The realtime model occasionally hands back a URL-encoded form of the
    /// dictated text ("no+mistakes+by+kanye", "no%20mistakes"). The
    /// instruction is the transcript — ground truth: when it spells the
    /// literal verbatim (a real "c++", "a+b=c") the arg already copied
    /// faithfully and stays; a de-encoded candidate is trusted only when it
    /// lands inside the instruction on word boundaries — a multi-word
    /// decoded form the user provably said.
    nonisolated static func sanitizedLiteralText(_ literal: String, instruction: String) -> String {
        guard literal.contains("+") || literal.contains("%"),
              !instruction.localizedCaseInsensitiveContains(literal) else { return literal }
        var candidates = [literal.replacingOccurrences(of: "+", with: " ")]
        if let decoded = literal.removingPercentEncoding, decoded != literal {
            candidates.append(decoded)
        }
        let boundary: (Character) -> Bool = { !$0.isLetter && !$0.isNumber }
        for candidate in candidates {
            let normalized = candidate.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // A decoded form is only a plausible mangle when it carries the
            // spaces the encoding ate — a wordless "c" from "c++" is not.
            guard normalized.contains(" "), normalized != literal else { continue }
            var searchStart = instruction.startIndex
            while let range = instruction.range(of: normalized, options: .caseInsensitive,
                                                range: searchStart..<instruction.endIndex) {
                let beforeOK = range.lowerBound == instruction.startIndex
                    || boundary(instruction[instruction.index(before: range.lowerBound)])
                let afterOK = range.upperBound == instruction.endIndex
                    || boundary(instruction[range.upperBound])
                if beforeOK && afterOK { return normalized }
                searchStart = range.upperBound
            }
        }
        return literal
    }

    /// A deterministic floor under the planner's `foreground` flag: a request
    /// phrased "open/show/launch X" asks for the app in front whether or not
    /// the model set the flag, unless the utterance explicitly says the work
    /// belongs in the background.
    static func wantsForeground(_ utterance: String) -> Bool {
        let text = utterance.lowercased()
        guard !text.contains("background") else { return false }
        // Whole-word match — "reopen the doc" or "startup disk" must not be
        // read as an open/start foreground request.
        return text.range(
            of: #"\b(?:open|launch|show|bring|switch to|start)\b"#,
            options: .regularExpression) != nil
    }

    var active: Bool { tasks.contains(where: \.active) }
    var message: String {
        if let pending = dialogue.pendingClarification { return pending.question.prompt }
        return tasks.first(where: { $0.id == selectedID })?.message ?? ""
    }

    private func noteChange() { onChange() }

    // MARK: - Realtime lane entry

    /// Between-turn pushes to the voice lane — settled outcomes, parked
    /// consents, parked questions. Args: captureID, text, speak.
    var taskEventSink: ((UUID, String, Bool) -> Void)?

    private func pushTaskEvent(_ work: Work, _ text: String, speak: Bool) {
        guard let captureID = work.provenance?.captureID else { return }
        taskEventSink?(captureID, text, speak)
    }

    /// The realtime lane's `computer_command` tool entry — the model's tool
    /// choice already IS the decision, so this goes straight to routing: fast
    /// lane when the instruction is deterministic, else the drive loop. It
    /// returns the moment the work is accepted; the verified outcome arrives
    /// later as a pushed `task_outcome` event. No waiters, no timers. The
    /// result is a VoiceToolResult payload — the lane voices `say` verbatim.
    func beginVoiceTask(_ instruction: String, app: String?,
                        frontmostHint: String? = nil, literalText: String? = nil,
                        transcriptHint: String? = nil,
                        captureID: UUID = UUID()) async -> String {
        var trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "That command didn't name anything to do.").encoded()
        }
        // The realtime model sometimes emits the same call twice — an
        // identical instruction still live (running or parked on an ask)
        // must not run a second time.
        let key = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
        if let dupe = tasks.last(where: {
            $0.request.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ").lowercased() == key
                && ($0.active || $0.questionParked || $0.approvalContinuation != nil)
        }) {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "That request is already running.",
                detail: "Duplicate of \"\(dupe.request)\"; a task_outcome push arrives when it finishes.").encoded()
        }
        feed.add(.heard, trimmed)
        let invocation = Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)
        nextLabel += 1
        let label = "Jarvis \(nextLabel) · \(instanceLabel)"
        // The accept path never waits on the driver: a ≤45s roster snapshot
        // routes this turn; a cold or expired cache kicks a background
        // refresh and falls back to the instant local roster, so "open X"
        // still resolves deterministically instead of paying list_apps
        // inside the drive loop. The loop's own reads stay authoritative.
        let apps = acceptPathAppList()
        // The tool args can diverge from the model's own transcript of
        // the user's words — when both parse as "open X" naming DIFFERENT
        // installed apps, what the user said is ground truth.
        if let heard = transcriptHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !heard.isEmpty, heard.lowercased() != trimmed.lowercased(),
           let heardOpen = CuaFastAction.parseOpen(heard),
           let calledOpen = CuaFastAction.parseOpen(trimmed),
           heardOpen.query.lowercased() != calledOpen.query.lowercased(),
           let heardApp = CuaFastAction.resolveOpenApp(query: heardOpen.query,
                                                     apps: apps, frontmostBundle: nil),
           let calledApp = CuaFastAction.resolveOpenApp(query: calledOpen.query,
                                                      apps: apps, frontmostBundle: nil),
           heardApp.bundle != calledApp.bundle {
            Self.log.notice("voice_transcript_divergence heard=\"\(heard, privacy: .public)\" called=\"\(trimmed, privacy: .public)\"")
            trimmed = heard
        }
        // The controller captured who was frontmost before our own UI —
        // resolve that name to a bundle so an accessory app being
        // frontmost can't steal generic-command targeting.
        let frontmostBundle = frontmostHint.flatMap { hint in
            (apps.first { $0["name"]?.string?.localizedCaseInsensitiveCompare(hint) == .orderedSame })?["bundle_id"]?.string
        }
        let resolution = (fastLaneResolver ?? { goal, hint, frontmost, list in
            CuaTaskAgent(call: { _, _ in .object([:]) })
                .resolveFastLane(goal: goal, apps: list, appHint: hint,
                                 frontmostBundleOverride: frontmost)
        })(trimmed, app, frontmostBundle, apps)
        let kind: AcceptedKind
        if let resolution {
            feed.add(.route, "Fast lane: \(resolution.openVerb ?? "run") \(resolution.name)")
            kind = .fastLane(resolution, goal: trimmed)
        } else {
            let literal = (literalText?.trimmingCharacters(in: .whitespacesAndNewlines))
                .map { Self.sanitizedLiteralText($0, instruction: trimmed) }
            let spec = TaskSpec(goal: trimmed, application: app,
                                literalText: literal?.isEmpty == false ? literal : nil,
                                foreground: Self.wantsForeground(trimmed))
            kind = .execute(spec)
            feed.add(.route, "Drive loop — \(trimmed)")
        }
        let work = spawnVoiceWork(kind: kind, label: label, invocation: invocation,
                                  apps: apps, captureID: captureID, utterance: trimmed)
        guard work.active else {
            Self.log.notice("voice_task_rejected \"\(trimmed, privacy: .public)\" app=\(app ?? "-", privacy: .public)")
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: VoiceToolResult.spoken(work.message, words: 12).isEmpty
                    ? "The task could not be started."
                    : VoiceToolResult.spoken(work.message, words: 12),
                detail: work.message.isEmpty ? nil : work.message).encoded()
        }
        let lane = resolution != nil ? "fast" : "drive"
        Self.log.notice("voice_task_started lane=\(lane, privacy: .public) app=\(app ?? "-", privacy: .public) \"\(trimmed, privacy: .public)\"")
        let say = VoiceToolResult.gerundPhrase(for: trimmed)
            .map { "On it, \($0)" } ?? "On it"
        return VoiceToolResult(status: VoiceToolResult.Status.started,
            say: VoiceToolResult.spoken(say, words: 12),
            detail: work.request).encoded()
    }

    /// Spawns a Work for a voice instruction — same shape as acceptIntent but
    /// no transcript commit: the lane's tool argument is already final text.
    private func spawnVoiceWork(kind: AcceptedKind, label: String, invocation: Invocation,
                                apps: [JSONValue], captureID: UUID, utterance: String) -> Work {
        let intentID = UUID()
        let request: String
        switch kind {
        case .fastLane(_, let goal): request = goal
        default: request = utterance
        }
        let wordCount = max(1, utterance.split(whereSeparator: \.isWhitespace).count)
        let work = Work(label: label, request: request, intentID: intentID, attemptID: UUID())
        work.provenance = SpeechProvenance(captureID: captureID)
        if case .execute(let spec) = kind {
            work.literalText = spec.literalText
            work.contentMode = spec.literalText != nil ? .literal : .control
            work.bundle = spec.application
            intentSpecs[intentID] = spec
        } else if case .fastLane(let resolution, _) = kind {
            work.bundle = resolution.bundle
        }
        work.timings = invocation.timings
        work.timings["Transcript to submission"] =
            (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
        invocation.work = work
        let previousSelection = selectedID
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        let source = CuaDialogueState.Source(captureID: captureID, handoffID: UUID(),
                                             revision: 0, transcriptRanges: [0 ..< wordCount])
        do {
            try drainUnresolvedForCapacity()
            try dialogue.add(.init(id: intentID, source: source, utterance: utterance,
                                   instruction: request,
                                   target: intentTarget(for: kind, source: source, apps: apps)))
        } catch {
            work.active = false
            // The real refusal (e.g. unresolved-capacity) reaches the model —
            // "could not be accepted" tells it nothing to correct.
            work.outcome = .failed(reason: error.localizedDescription)
            work.message = error.localizedDescription
            intentSpecs.removeValue(forKey: intentID)
            selectedID = previousSelection
            noteChange()
            return work
        }
        work.intentRevision = dialogue.entry(for: intentID)?.revision ?? 0
        work.worker = Task { [weak self] in
            await self?.runWork(kind, work: work, invocation: invocation)
        }
        noteChange()
        return work
    }

    /// One parked user-facing ask: a yes/no consent on a live work or a
    /// dialogue question waiting on an answer.
    private enum ParkedAsk {
        case consent(Work)
        case question(CuaDialogueState.Entry, CuaDialogueState.Question)

        var request: String {
            switch self {
            case .consent(let work): return work.request
            case .question(let entry, _): return entry.intent.instruction
            }
        }
        var appName: String? {
            switch self {
            case .consent(let work): return work.bundle
            case .question(let entry, _):
                return entry.intent.target?.application ?? entry.intent.target?.description
            }
        }
    }

    /// `respond_to_task` — resolves a parked ask: a yes/no consent on a
    /// running work, or a free-text question answer that resumes its intent.
    /// Resolution order: (a) a `task` hint — request text, app name, or a
    /// park-order ordinal — picks the ask; (b) a single parked ask resolves
    /// regardless; (c) several parked asks and no usable hint refuse with
    /// the list rather than silently answering the newest. The input's shape
    /// routes between kinds: verdict words go to consent asks, free text to
    /// questions — a parked consent must not swallow text meant for a
    /// question. Returns nil when nothing is waiting — nil (not a
    /// `nothing_pending` payload) is deliberate: VoiceController falls
    /// through nil to the agent-gate consent surface, so a string here
    /// would swallow answers meant for that gate. Same for an empty answer.
    func respondToTask(_ answer: String, task: String? = nil,
                       captureID: UUID = UUID()) async -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let asks = parkedAsks()
        guard !asks.isEmpty else { return nil }
        let hint = (task ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !hint.isEmpty {
            if let match = Self.matchAsk(hint, in: asks) {
                return await resolveAsk(match, answer: trimmed, captureID: captureID)
            }
            return asks.count == 1
                ? await resolveAsk(asks[0], answer: trimmed, captureID: captureID)
                : Self.askListRefusal(asks)
        }
        if asks.count == 1 {
            return await resolveAsk(asks[0], answer: trimmed, captureID: captureID)
        }
        let verdict = Self.consentVerdict(trimmed)
        let consents = asks.filter { if case .consent = $0 { return true }; return false }
        let questions = asks.filter { if case .question = $0 { return true }; return false }
        if verdict != nil {
            if consents.count == 1 {
                return await resolveAsk(consents[0], answer: trimmed, captureID: captureID)
            }
            if consents.isEmpty, questions.count == 1 {
                return await resolveAsk(questions[0], answer: trimmed, captureID: captureID)
            }
        } else if questions.count == 1 {
            return await resolveAsk(questions[0], answer: trimmed, captureID: captureID)
        }
        return Self.askListRefusal(asks)
    }

    /// Every ask waiting on the user in park order — consents stamp the work
    /// when their continuation registers; questions stamp the owning work at
    /// park time. A question with no surviving work sorts last.
    private func parkedAsks() -> [ParkedAsk] {
        var stamped: [(stamp: Double, ask: ParkedAsk)] = []
        for work in tasks where work.approvalContinuation != nil && work.active {
            stamped.append((work.askParkedAt, .consent(work)))
        }
        for entry in dialogue.awaitingAnswerEntries {
            guard let question = entry.question else { continue }
            let stamp = tasks.last { $0.intentID == entry.intent.id }?.askParkedAt
                ?? .greatestFiniteMagnitude
            stamped.append((stamp, .question(entry, question)))
        }
        return stamped.sorted { $0.stamp < $1.stamp }.map(\.ask)
    }

    /// Hint → ask: a park-order ordinal ("first", "second", "last", "2")
    /// wins outright; otherwise the newest ask whose request text or app
    /// name contains the hint.
    private static func matchAsk(_ hint: String, in asks: [ParkedAsk]) -> ParkedAsk? {
        if let index = ordinalIndex(of: hint, count: asks.count) { return asks[index] }
        return asks.last {
            $0.request.lowercased().contains(hint)
                || ($0.appName?.lowercased().contains(hint) ?? false)
        }
    }

    private static func ordinalIndex(of hint: String, count: Int) -> Int? {
        let words = hint.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let table: [String: Int] = ["first": 0, "1st": 0, "second": 1, "2nd": 1,
                                    "third": 2, "3rd": 2, "fourth": 3, "4th": 3]
        for word in words {
            if let index = table[word] { return index < count ? index : nil }
            if ["last", "latest", "newest"].contains(word) { return count - 1 }
        }
        if let n = words.compactMap({ Int($0) }).first, n >= 1, n <= count { return n - 1 }
        return nil
    }

    /// Several parked asks and no addressing — refuse with the list so the
    /// model can re-ask with a `task` hint instead of guessing at the newest.
    private static func askListRefusal(_ asks: [ParkedAsk]) -> String {
        let names = asks.prefix(2).map {
            VoiceToolResult.spoken($0.request, words: 3)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        }
        let say: String
        if asks.count == 2, names.count == 2, names.allSatisfy({ !$0.isEmpty }),
           asks.allSatisfy({ if case .consent = $0 { return true }; return false }) {
            say = "Two tasks are waiting, say yes for \(names[0]) or \(names[1])."
        } else {
            say = "\(asks.count) tasks are waiting, name which one to answer."
        }
        let detail = asks.enumerated().map { index, ask in
            "\(index + 1)) \(String(ask.request.prefix(80)))"
        }.joined(separator: " | ")
        return VoiceToolResult(status: VoiceToolResult.Status.refused,
            say: VoiceToolResult.spoken(say, words: 14),
            detail: "Parked asks: \(detail). Pass the task parameter to respond_to_task to choose.").encoded()
    }

    /// Resolve one chosen ask — a consent needs a verdict word; a question
    /// takes free text, with denial words withdrawing the ask entirely.
    private func resolveAsk(_ ask: ParkedAsk, answer: String, captureID: UUID) async -> String {
        switch ask {
        case .consent(let work):
            guard let verdict = Self.consentVerdict(answer) else {
                return VoiceToolResult(status: VoiceToolResult.Status.refused,
                    say: "Please answer yes or no.",
                    detail: "\"\(work.approval ?? work.request)\" is still waiting.").encoded()
            }
            resolveApproval(work.id, approved: verdict)
            return verdict
                ? VoiceToolResult(status: VoiceToolResult.Status.resumed, say: "On it.").encoded()
                : VoiceToolResult(status: VoiceToolResult.Status.cancelled, say: "Skipped it.",
                                  detail: "Denied — the action was not run.").encoded()
        case .question(let entry, let question):
            // A denial word is a cancel, not an answer — "never mind"/"stop
            // it" must withdraw the ask, not resume the task with "never
            // mind" merged into its spec.
            if let denied = Self.questionDenied(answer), denied {
                if let work = tasks.last(where: { $0.intentID == entry.intent.id }) {
                    cancel(work.id)
                } else {
                    try? dialogue.cancel(intentID: entry.intent.id, reason: "Cancelled by the user.")
                }
                return VoiceToolResult(status: VoiceToolResult.Status.cancelled,
                                       say: "Cancelled, nothing further runs.").encoded()
            }
            return await resumeAnsweredQuestion(owner: entry, question: question,
                                                answer: answer, captureID: captureID)
        }
    }

    /// Cancel-shaped utterances that should withdraw a parked question
    /// rather than resume it. "no" alone is deliberately absent — a yes/no
    /// clarification needs it as a legitimate answer.
    static func questionDenied(_ text: String) -> Bool? {
        let normalized = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let cancels = ["never mind", "cancel", "cancel that", "stop", "stop it",
                       "forget it", "forget that", "abort", "don't", "do not",
                       "leave it", "skip it", "no thanks", "nah"]
        return cancels.contains(normalized) || normalized.hasPrefix("don't ")
    }

    /// A spoken answer resumes the question's owner intent in place — same
    /// mechanism the planner's resolvesPendingQuestion used, minus the model
    /// hop: the dialogue answer merges into a fresh attempt on the same intent.
    private func resumeAnsweredQuestion(owner: CuaDialogueState.Entry,
                                        question: CuaDialogueState.Question,
                                        answer: String, captureID: UUID) async -> String {
        let wordCount = max(1, answer.split(whereSeparator: \.isWhitespace).count)
        let source = CuaDialogueState.Source(captureID: captureID, handoffID: UUID(),
                                             revision: owner.revision,
                                             transcriptRanges: [0 ..< wordCount])
        do {
            try dialogue.answer(.init(questionID: question.id, intentID: owner.intent.id,
                                      revision: owner.revision, source: source, utterance: answer))
        } catch {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "That answer arrived too late.",
                detail: "The task is no longer waiting. Repeat the instruction.").encoded()
        }
        var spec = intentSpecs[owner.intent.id]
            ?? TaskSpec(goal: owner.intent.instruction,
                        application: owner.intent.target?.application)
        if !question.options.isEmpty {
            // A window/other-choice question — the answer selects an option
            // or carries the raw title.
            spec.window = question.options.first {
                $0.localizedCaseInsensitiveContains(answer)
                    || answer.localizedCaseInsensitiveContains($0)
            } ?? answer
            // A clarification answer that re-maps the target is durable app
            // knowledge — the next drive plans on it. Fire-and-forget.
            let target = spec.window ?? answer
            if let bundleID = owner.intent.target?.bundle?.bundleID ?? spec.application,
               !bundleID.isEmpty {
                let memory = appMemory
                Task { await memory.note(bundleID: bundleID,
                    appName: spec.application ?? owner.intent.target?.application,
                    record: CuaAppMemoryUpdate(note: "User clarified the target as \"\(target)\".")) }
            }
        } else {
            spec.values["answer"] = answer
            spec.goal += "\nThe user answered \"\(question.prompt)\": \(answer)"
        }
        intentSpecs[owner.intent.id] = spec
        let invocation = Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)
        nextLabel += 1
        let work = Work(label: "Jarvis \(nextLabel) · \(instanceLabel)",
                        request: owner.intent.instruction,
                        intentID: owner.intent.id, attemptID: UUID())
        work.provenance = SpeechProvenance(captureID: captureID)
        work.literalText = spec.literalText
        work.contentMode = spec.literalText != nil ? .literal : .control
        work.bundle = spec.application
        work.timings = invocation.timings
        invocation.work = work
        work.intentRevision = dialogue.entry(for: owner.intent.id)?.revision ?? owner.revision
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        work.worker = Task { [weak self] in
            await self?.runWork(.execute(spec), work: work, invocation: invocation)
        }
        noteChange()
        return VoiceToolResult(status: VoiceToolResult.Status.resumed, say: "On it.",
                               detail: owner.intent.instruction).encoded()
    }

    /// `cancel_task` — a hint matches by request text, label or app; bare
    /// "cancel that" stops the newest running work. A question-parked work
    /// reads as inactive but is still cancellable — without it "cancel that"
    /// says "nothing is running" while an ask sits live.
    func cancelVoiceTask(_ hint: String?) -> String {
        let live = tasks.filter {
            $0.active || (dialogue.entry(for: $0.intentID).map {
                if case .awaitingAnswer = $0.status { return true }
                return false
            } ?? false)
        }
        guard !live.isEmpty else {
            return VoiceToolResult(status: VoiceToolResult.Status.nothingRunning,
                                   say: "Nothing is running.").encoded()
        }
        let trimmed = (hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == "all" || trimmed == "everything" {
            stopAll()
            return VoiceToolResult(status: VoiceToolResult.Status.cancelled,
                                   say: "Stopping everything.").encoded()
        }
        let match = live.last {
            $0.request.lowercased().contains(trimmed)
                || $0.label.lowercased().contains(trimmed)
                || ($0.bundle?.lowercased().contains(trimmed) ?? false)
        } ?? (live.count == 1 ? live[0] : nil)
        guard let match else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "Which task should I stop?",
                detail: live.map(\.request).joined(separator: " | ")).encoded()
        }
        cancel(match.id)
        return VoiceToolResult(status: VoiceToolResult.Status.cancelled,
                               say: "Stopped.", detail: match.request).encoded()
    }

    /// `delegate_to_agent` — hands the task to a persistent background agent
    /// (Clicky's sessions_*). The bridge already returns a VoiceToolResult
    /// payload; a foreign AgentBridging answering plain text gets wrapped so
    /// the lane always sees the same shape.
    func delegateToAgent(task: String, agent: String?, name: String?,
                         role: String?, description: String?) async -> String {
        guard let agentBridge else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "No agents are configured in this build.").encoded()
        }
        do {
            let reply = try await agentBridge.delegate(DelegationRequest(
                agentSlug: agent, newAgentName: name, newAgentRole: role,
                newAgentDescription: description, message: task))
            return Self.agentReply(reply)
        } catch {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "The agent could not be reached.",
                detail: error.localizedDescription).encoded()
        }
    }

    /// Bridge replies are already VoiceToolResult payloads; anything else is
    /// acknowledged honestly with the raw text kept as detail.
    private static func agentReply(_ reply: String) -> String {
        if VoiceToolResult(jsonString: reply) != nil { return reply }
        return VoiceToolResult(status: VoiceToolResult.Status.delegated,
                               say: "On it.", detail: reply).encoded()
    }

    func cancelSelected() { if let id = selectedID { cancel(id) } }
    func cancel(_ id: UUID) {
        guard let work = tasks.first(where: { $0.id == id }), !work.stopRequested else { return }
        if case .awaitingAnswer = dialogue.entry(for: work.intentID)?.status {
            // Withdrawing a pending question resolves its intent and work.
            work.stopRequested = true
            try? dialogue.cancel(intentID: work.intentID, reason: "Cancelled.")
            work.active = false
            work.outcome = .cancelled(reason: "Cancelled.")
            work.message = "Cancelled."
            noteChange()
            return
        }
        guard work.active else { return }
        // A resolved intent means the attempt already settled and its worker is
        // only running session teardown. Cancelling now would rewrite the
        // recorded outcome and flip the task's status to Cancelled.
        if dialogue.entry(for: work.intentID)?.status.isResolved == true { return }
        resolveApproval(id, approved: false)
        work.stopRequested = true
        work.message = "Stopping; already dispatched effects may finish."
        if let status = dialogue.entry(for: work.intentID)?.status {
            switch status {
            case .executing:
                break // an in-flight attempt unwinds through its worker
            default:
                // A queued intent whose attempt never began still resolves so
                // cancelled utterances cannot wedge unresolved capacity.
                try? dialogue.cancel(intentID: work.intentID, reason: "Cancelled.")
            }
        }
        work.worker?.cancel()
        if work.worker == nil {
            work.active = false
            work.outcome = .cancelled(reason: "Cancelled.")
        }
        noteChange()
    }
    func stopAll() {
        for work in tasks { cancel(work.id) }
        // Withdraw pending questions that never produced a task record.
        for entry in dialogue.entries {
            if case .awaitingAnswer = entry.status {
                try? dialogue.cancel(intentID: entry.intent.id, reason: "Stopped.")
            }
        }
        noteChange()
    }
    func resolveApproval(_ id: UUID, approved: Bool) {
        guard let work = tasks.first(where: { $0.id == id }), let continuation = work.approvalContinuation else { return }
        work.approvalContinuation = nil
        work.approval = nil
        continuation.resume(returning: approved)
        noteChange()
    }
    private func requestApproval(_ description: String, for work: Work,
                                 invocation: Invocation? = nil) async throws -> Bool {
        try Task.checkCancellation()
        // Always-allow standing grant — the user opted out of per-action
        // confirmation; the driver still enforces deny lists and scope rules.
        guard !CuaStandingGrants.computerUseInput else { return true }
        feed.add(.consent, description)
        // A parked ask must not hold the app lease — the wait is unbounded,
        // so the lane drops here and re-acquires on approval.
        await registry.release(app: work.bundle ?? "", pid: nil, workID: work.id.uuidString)
        let consentStarted = ProcessInfo.processInfo.systemUptime
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.approval = description
                work.approvalContinuation = continuation
                work.askParkedAt = ProcessInfo.processInfo.systemUptime
                work.message = description
                selectedID = work.id
                pushTaskEvent(work, VoiceToolResult(
                    kind: VoiceToolResult.Kind.taskQuestion,
                    status: VoiceToolResult.Status.question,
                    say: Self.consentSay(description),
                    detail: "[needs confirmation, task \(work.id.uuidString.prefix(8))] \"\(work.request)\" — ask the user to confirm; when they answer, call respond_to_task.",
                    options: ["yes", "no"]).encoded(), speak: true)
                noteChange()
            }
        } onCancel: {
            Task { @MainActor in self.resolveApproval(work.id, approved: false) }
        }
        let waited = (ProcessInfo.processInfo.systemUptime - consentStarted) * 1000
        invocation?.timings["Consent wait", default: 0] += waited
        work.timings["Consent wait", default: 0] += waited
        try Task.checkCancellation()
        if accepted {
            // Re-take the app lease before dispatch resumes — a peer may be
            // mid-run on the same app after the park released it. The pid is
            // re-resolved so the lane matches the identity runWork took.
            if let app = work.bundle, !app.isEmpty {
                let queued = ProcessInfo.processInfo.systemUptime
                let pid = await leasePID(for: app,
                    invocation: invocation
                        ?? Invocation(receivedAt: ProcessInfo.processInfo.systemUptime))
                try await registry.acquire(app: app, pid: pid, workID: work.id.uuidString)
                let requeued = (ProcessInfo.processInfo.systemUptime - queued) * 1000
                invocation?.timings["Queue wait", default: 0] += requeued
                work.timings["Queue wait", default: 0] += requeued
            }
            work.phase = .working
            noteChange()
        }
        return accepted
    }
    func select(_ id: UUID) { selectedID = id; onChange() }
    /// The daemon's first calls after system wake stall while its own
    /// session/license checks wait on the returning network — a real user
    /// command shouldn't pay that warm-up. Best-effort: rebuilds a dead
    /// transport and exercises one read; failures are ignored by design.
    func wakeDriverSession() {
        Task { [weak self] in
            guard let self else { return }
            if let connection = try? await self.sessionTransport() {
                _ = try? await connection.call("check_permissions", arguments: [:])
            }
            // The roster cache expired while the machine slept — refresh it
            // in the same pass so the first post-wake command routes on
            // warm data instead of paying a cold list_apps mid-turn.
            _ = try? await self.appList(
                invocation: Invocation(receivedAt: ProcessInfo.processInfo.systemUptime))
        }
    }
    func shutdown() async {
        for work in tasks where work.active { cancel(work.id) }
        onChange()
        for work in tasks { await work.worker?.value }
        // A session bootstrap can still be in flight when shutdown starts:
        // let it finish so its session is released rather than leaked.
        _ = try? await sessionStartTask?.value
        sessionStartTask = nil
        // A background roster refresh can be mid-read too — drain it before
        // end_session or it could mint a fresh session past the teardown.
        _ = try? await appListFetch?.value
        appListFetch = nil
        // One `end_session` per run: the driver releases the run's grants and
        // rolls back remote-debugging setup it performed.
        if let connection = sessionConnection {
            sessionConnection = nil
            _ = try? await connection.call("end_session", arguments: ["session": .string(sessionLabel)], timeout: 5)
            await connection.close()
        }
        // Drop the warm planner session with the runtime — the next task
        // respawns it on demand.
        await CuaPlanner.shared.close()
    }

    // MARK: - Utterance intake

    /// Bare approval/denial words while a work parks on an approval resolve it
    /// directly — deterministic, no model call, and it never reaches the
    /// planner where "yes" could be misread as a request.
    private static func consentVerdict(_ utterance: String) -> Bool? {
        switch utterance.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: .punctuationCharacters) {
        case "yes", "yeah", "yep", "yup", "confirm", "go ahead", "approved",
             "approve", "do it", "ok", "okay", "sure", "continue", "proceed":
            return true
        case "no", "nope", "deny", "denied", "cancel", "don't", "do not",
             "stop", "never mind", "nevermind", "abort":
            return false
        default:
            return nil
        }
    }

    /// "Try that again" targets the intent the phrase refers to: a real retry
    /// state — uncertain, partial, blocked or failed — resolves newest first,
    /// a cancelled candidate still answers so the refusal is honest, and with
    /// nothing retryable the earliest resolved intent is the anchored
    /// referent ("the earlier task").
    private func retryTarget(explicitIntentID: UUID? = nil,
                             namedRequest: String? = nil) -> CuaDialogueState.Entry? {
        if let explicitIntentID { return dialogue.entry(for: explicitIntentID) }
        if let namedRequest {
            let needle = namedRequest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let named = dialogue.entries.last(where: {
                $0.intent.instruction.lowercased() == needle
            }) ?? dialogue.entries.last(where: {
                $0.intent.instruction.lowercased().contains(needle)
            }) { return named }
        }
        if let retryable = dialogue.entries.last(where: {
            switch $0.status {
            case .uncertain, .partial, .blocked, .failed, .cancelled: return true
            default: return false
            }
        }) { return retryable }
        return dialogue.entries.first(where: { $0.status.isResolved })
    }

    /// Deterministic retry — the UI's retry action and a voice "retry that"
    /// land here. Resumes the same intent in place: the fresh Work gets a new
    /// attempt id, never a new intent. The original spec is reused — a retry
    /// never re-plans. Cancelled intents refuse honestly; uncertain/partial/
    /// blocked keep their verified facts; failed/succeeded re-revise.
    func retryWork(_ workID: UUID) async -> String {
        guard let anchor = tasks.first(where: { $0.id == workID }) else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "That task is gone.").encoded()
        }
        guard let target = retryTarget(explicitIntentID: anchor.intentID) else {
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                                   say: "There is nothing to retry.").encoded()
        }
        let invocation = Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)
        nextLabel += 1
        let work = Work(label: "Jarvis \(nextLabel) · \(instanceLabel)",
                        request: target.intent.instruction,
                        intentID: target.intent.id, attemptID: UUID())
        work.provenance = anchor.provenance
        work.timings = invocation.timings
        invocation.work = work
        tasks.append(work)
        selectedID = work.id
        pruneWorks()
        if case .cancelled = target.status {
            work.active = false
            work.outcome = .blocked(reason: "The request was already cancelled; it cannot be retried.")
            work.message = "The request was already cancelled; it cannot be retried."
            noteChange()
            return VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: VoiceToolResult.spoken(work.message, words: 12),
                detail: work.message).encoded()
        }
        switch target.status {
        case .uncertain:
            try? dialogue.retryUncertain(intentID: target.intent.id)
        default:
            try? dialogue.revise(intentID: target.intent.id)
        }
        work.intentRevision = dialogue.entry(for: target.intent.id)?.revision ?? 0
        noteChange()
        let kind: AcceptedKind
        if let spec = intentSpecs[target.intent.id] {
            kind = .execute(spec)
        } else if let apps = try? await appList(invocation: invocation),
                  let resolved = (fastLaneResolver ?? { goal, hint, frontmost, list in
                      CuaTaskAgent(call: { _, _ in .object([:]) })
                          .resolveFastLane(goal: goal, apps: list, appHint: hint,
                                           frontmostBundleOverride: frontmost)
                  })(target.intent.instruction, nil, nil, apps) {
            kind = .fastLane(resolved, goal: target.intent.instruction)
        } else {
            kind = .execute(TaskSpec(goal: target.intent.instruction,
                                     application: target.intent.target?.application))
        }
        work.worker = Task { [weak self] in
            guard let self else { return }
            await self.runWork(kind, work: work, invocation: invocation)
        }
        return VoiceToolResult(status: VoiceToolResult.Status.resumed,
            say: "Trying that again.",
            detail: String(target.intent.instruction.prefix(120))).encoded()
    }


    /// The app roster changes on a human timescale — a ~5s cache collapses
    /// the per-command driver roundtrip without going stale between commands.
    /// Connect and list apps at launch — the first computer_command would
    /// otherwise pay the driver spawn + handshake (~2.5s) inside the turn.
    func warm() {
        Task { _ = try? await appList(invocation: Invocation(receivedAt: ProcessInfo.processInfo.systemUptime)) }
    }

    private var appListCache: (fetched: TimeInterval, apps: [JSONValue])?
    /// One in-flight roster read — the accept-path warm, lease resolution
    /// and the drive loop's early reads join it instead of stacking
    /// duplicate list_apps roundtrips on a cold or post-wake daemon.
    private var appListFetch: Task<[JSONValue], Error>?

    /// Accept-path roster read: the ≤45s snapshot when one exists, else an
    /// instant local roster plus a background refresh — acknowledging a
    /// command must never pay a driver roundtrip, and a cold cache must not
    /// blind fast-lane resolution to apps macOS already knows are running.
    private func acceptPathAppList() -> [JSONValue] {
        let now = ProcessInfo.processInfo.systemUptime
        guard let cached = appListCache, now - cached.fetched < 45 else {
            refreshAppList()
            return Self.fallbackAppList()
        }
        if now - cached.fetched >= 15 { refreshAppList() }
        return cached.apps
    }

    /// Instant routing roster for a cold cache: the live NSWorkspace
    /// roster in the driver's list_apps shape — real names, bundle ids and
    /// pids with no transport. Regular-activation apps only — accessory and
    /// background rows can't be named targets anyway, and an app not yet
    /// running resolves through the driver read the refresh lands.
    /// Routing data, never dispatch authority.
    static func fallbackAppList() -> [JSONValue] {
        NSWorkspace.shared.runningApplications.compactMap { running in
            guard running.activationPolicy == .regular,
                  let bundle = running.bundleIdentifier, !bundle.isEmpty else { return nil }
            return .object([
                "name": .string(running.localizedName ?? bundle),
                "bundle_id": .string(bundle),
                "running": .bool(true),
                "pid": .number(Double(running.processIdentifier))])
        }
    }

    private func refreshAppList() {
        // Join (or start) the single in-flight read — back-to-back commands
        // on a stale roster must not stack duplicate list_apps roundtrips.
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.fetchAppList().value
            } catch {
                let detail = (error as? DriverConnectionError)?.diagnosticsDetail ?? ""
                Self.log.notice("app_list_refresh_failed error=\(error.localizedDescription, privacy: .public) detail=\(detail, privacy: .public)")
            }
        }
    }

    private func fetchAppList() -> Task<[JSONValue], Error> {
        if let fetch = appListFetch { return fetch }
        // Bypass the 60s inventory cache — the running/pid hints drive
        // fast-lane candidacy and must reflect this read's own freshness.
        let fetch = Task { () throws -> [JSONValue] in
            defer { self.appListFetch = nil }
            let result = try await self.makeToolCall(
                invocation: Invocation(receivedAt: ProcessInfo.processInfo.systemUptime),
                useInstalledAppCache: false)("list_apps", [:])
            let apps = result["apps"]?.array ?? []
            self.appListCache = (ProcessInfo.processInfo.systemUptime, apps)
            return apps
        }
        appListFetch = fetch
        return fetch
    }

    private func appList(invocation: Invocation) async throws -> [JSONValue] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = appListCache {
            let age = now - cached.fetched
            if age < 15 { return cached.apps }
            if age < 45 {
                // Stale-while-revalidate: routing needs only names — the fresh
                // read lands for the next turn rather than stalling this one
                // on a ~2s list_apps roundtrip. Dispatch authority always
                // comes from the loop's own fresh reads.
                refreshAppList()
                return cached.apps
            }
        }
        // A cold or expired read joins the shared fetch; the caller bills
        // its wait — the same measure whether it spawned the read or not.
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            invocation.timings["Cua list_apps", default: 0] += elapsed
            invocation.work?.timings["Cua list_apps", default: 0] += elapsed
        }
        return try await fetchAppList().value
    }

    // MARK: - Intent acceptance

    /// Unresolved capacity is bounded: terminal-ambiguous records (blocked,
    /// uncertain, partial) drain oldest-first so an `add` cannot wedge on them.
    /// Entries with an in-flight attempt are never drained — their settle is
    /// still running — and a genuinely full ledger refuses honestly instead of
    /// dropping live intents or pending questions.
    private func drainUnresolvedForCapacity() throws {
        while dialogue.entries.filter({ !$0.status.isResolved }).count >= dialogue.unresolvedLimit {
            guard let oldest = dialogue.entries.first(where: { entry in
                switch entry.status {
                case .blocked, .uncertain, .partial:
                    return !tasks.contains { $0.intentID == entry.intent.id && $0.active }
                default:
                    return false
                }
            }) else {
                throw DriverConnectionError.refused("Too many unresolved requests remain open; cancel or resolve earlier tasks before asking for more work.")
            }
            // A failed cancel must not spin: the entry that refuses to
            // resolve stays unresolved, so looping again finds the same one.
            do {
                try dialogue.cancel(intentID: oldest.intent.id, reason: "Resolved to make room for newer requests.")
            } catch {
                throw DriverConnectionError.refused("Too many unresolved requests remain open; cancel or resolve earlier tasks before asking for more work.")
            }
        }
    }


    private func intentTarget(for kind: AcceptedKind,
                              source: CuaDialogueState.Source,
                              apps: [JSONValue] = []) -> CuaDialogueState.Target? {
        let app: String?
        var bundle: String?
        switch kind {
        case .fastLane(let resolved, _):
            app = resolved.name; bundle = resolved.bundle
        case .execute(let spec):
            app = spec.application
        }
        guard app != nil || bundle != nil else { return nil }
        if bundle == nil, let app {
            // The named app resolves to its bundle identity against the live
            // list, so facts and pending questions bind the real target.
            bundle = apps.first(where: {
                $0["name"]?.string?.caseInsensitiveCompare(app) == .orderedSame
                    || $0["bundle_id"]?.string?.caseInsensitiveCompare(app) == .orderedSame
            })?["bundle_id"]?.string
        }
        return .init(
            bundle: (bundle ?? app).map { .init(bundleID: $0, displayName: app) },
            description: app ?? bundle ?? "",
            provenance: .source(source))
    }

    /// Active and unresolved intents — plus everything they transitively
    /// reference — are never pruned; only unreferenced resolved work is bounded.
    private func pruneWorks() {
        var protected = Set(dialogue.entries.filter { !$0.status.isResolved }.map { $0.intent.id })
        var frontier = Array(protected)
        while let id = frontier.popLast() {
            guard let entry = dialogue.entry(for: id) else { continue }
            var parents: [UUID] = []
            if let parent = entry.prerequisite?.requiresIntentID { parents.append(parent) }
            switch entry.relationship {
            case .independent: break
            case .refinement(let parent), .continuation(let parent), .correction(let parent):
                parents.append(parent)
            }
            for parent in parents where protected.insert(parent).inserted { frontier.append(parent) }
        }
        while tasks.count > 32, let index = tasks.firstIndex(where: { !$0.active && !protected.contains($0.intentID) }) {
            tasks.remove(at: index)
        }
        let liveIntentIDs = Set(dialogue.entries.map { $0.intent.id })
        intentSpecs = intentSpecs.filter { liveIntentIDs.contains($0.key) }
    }

    // MARK: - Dispatch plumbing

    /// One lease identity per app: a bundle-id-shaped target resolves to its
    /// display name so "com.apple.Safari" and "Safari" share one queue entry.
    /// An unreadable app list keeps the raw spelling — identical spellings
    /// still serialize, which is the common case.
    private func leaseIdentity(for raw: String, invocation: Invocation) async -> String {
        guard raw.contains("."),
              let apps = try? await appList(invocation: invocation),
              let match = apps.first(where: {
                  $0["bundle_id"]?.string?.caseInsensitiveCompare(raw) == .orderedSame }),
              let name = match["name"]?.string, !name.isEmpty else { return raw }
        return name
    }

    /// The app's live pid when the roster pins one — a pid is the strongest
    /// lane identity and wins outright over spelling canonicalization, so
    /// every caller resolves it the same way at acquire time.
    private func leasePID(for app: String, invocation: Invocation) async -> Int? {
        guard let apps = try? await appList(invocation: invocation),
              let match = apps.first(where: {
                  $0["name"]?.string?.caseInsensitiveCompare(app) == .orderedSame
                      || $0["bundle_id"]?.string?.caseInsensitiveCompare(app) == .orderedSame
              }), let pid = match["pid"]?.integer, pid > 0 else { return nil }
        return pid
    }

    private func makeAgent(invocation: Invocation) -> CuaTaskAgent {
        CuaTaskAgent(call: makeToolCall(invocation: invocation, useInstalledAppCache: false),
            approve: { [weak self] description in
                guard let self, let work = invocation.work else { return false }
                return try await self.requestApproval(description, for: work, invocation: invocation)
            },
            // Leases must key on the owning work: a shared "" bucket would
            // satisfy every parallel lane instantly, and releaseAll(workID:)
            // at teardown could never reclaim a lane held under a name it
            // doesn't know. A nil-work probe gets its own throwaway id
            // rather than the shared bucket.
            workID: invocation.work?.id.uuidString ?? UUID().uuidString)
    }

    /// The shared live transport, created lazily. A dead one is replaced
    /// wholesale — a fresh proxy must `start_session` again before any tool
    /// call. Two tasks racing to build the first connection funnel through one
    /// serialized bootstrap so neither can orphan a transport or run calls on
    /// a session that was never started.
    private func sessionTransport(invocation: Invocation? = nil) async throws -> CuaConnection {
        // Daemon spawn + start_session is billed apart from the tool call
        // that rides it — a cold runtime's first call used to hide the whole
        // bootstrap inside "Cua <first tool>". Joiners of an in-flight
        // bootstrap bill their wait here too.
        let connectStarted = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = (ProcessInfo.processInfo.systemUptime - connectStarted) * 1000
            invocation?.timings["Driver connect", default: 0] += elapsed
            invocation?.work?.timings["Driver connect", default: 0] += elapsed
        }
        // Check-and-set is atomic here: every state check (including the
        // connected re-check) happens INSIDE the task, so two callers racing
        // a reconnect-after-death both join one bootstrap instead of
        // duplicating daemons or tombstoning each other's sessions.
        if let inFlight = sessionStartTask { return try await inFlight.value }
        let task = Task { () throws -> CuaConnection in
            if let connection = self.sessionConnection, await connection.connected { return connection }
            let connection = self.makeConnection()
            try await connection.connect()
            if self.sessionConnection != nil {
                // A replaced transport may have left a live daemon-side
                // session under this label — release it before re-starting
                // so session-scoped grants cannot double-accumulate.
                _ = try? await connection.call("end_session", arguments: ["session": .string(self.sessionLabel)], timeout: 5)
            }
            _ = try await connection.call("start_session", arguments: ["session": .string(self.sessionLabel)])
            // Session-scoped cursor policy: the user picks animated-overlay or
            // silent dispatch once, never a per-action mix. Best-effort — a
            // daemon too old for the cursor tools still serves the session.
            _ = try? await connection.call("set_agent_cursor_enabled", arguments: [
                "session": .string(self.sessionLabel),
                "enabled": .bool(self.config.agentCursorEnabled)])
            self.sessionConnection = connection
            return connection
        }
        sessionStartTask = task
        defer { sessionStartTask = nil }
        return try await task.value
    }

    private func makeTimedJudge(_ invocation: Invocation) -> CuaTaskAgent.Judge {
        { state, questions in
            let judgeFacts = self.judgeFacts
            _ = judgeFacts.take()
            let started = ProcessInfo.processInfo.systemUptime
            defer {
                invocation.timings["Jev judgment", default: 0] += (ProcessInfo.processInfo.systemUptime - started) * 1000
                // The production judge stashed systemOne's measured latency
                // and token usage; a scripted judge leaves the box empty.
                // Latency is a duration and bills to timings; usage is a
                // count and accumulates on the work beside them.
                if let facts = judgeFacts.take() {
                    invocation.timings["Jev latency", default: 0] += facts.latencyMs
                    invocation.work?.judgeInputTokens += facts.inputTokens ?? 0
                    invocation.work?.judgeOutputTokens += facts.outputTokens ?? 0
                }
            }
            return try await self.judge(state, questions)
        }
    }

    /// The core driver call shared by the plain and timeout-carrying seams:
    /// session merge, transport resolution (billed apart under "Driver
    /// connect"), the inventory cache, and "Cua <tool>" timing written
    /// through to the work live so the inspector sees mid-run accumulation.
    private func driverToolCall(invocation: Invocation,
                                useInstalledAppCache: Bool)
        -> (String, [String: JSONValue], TimeInterval?) async throws -> JSONValue {
        { tool, arguments, timeout in
            try Task.checkCancellation()
            if let work = invocation.work,
               Self.dispatchesEffect(tool: tool, arguments: arguments) {
                work.dispatchedEffect = true
                if work.timings["Transcript to first dispatch"] == nil {
                    let elapsed = (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
                    work.timings["Transcript to first dispatch"] = elapsed
                    invocation.timings["Transcript to first dispatch"] = elapsed
                }
            }
            let arguments = arguments.merging(["session": .string(self.sessionLabel)]) { _, current in current }
            // Resolve the transport per call: a dead connection is replaced
            // and re-sessioned inside sessionTransport, so a reconnect
            // mid-task never strands this closure on a stale transport.
            let connection = try await self.sessionTransport(invocation: invocation)
            let started = ProcessInfo.processInfo.systemUptime
            defer {
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                invocation.timings["Cua \(tool)", default: 0] += elapsed
                invocation.work?.timings["Cua \(tool)", default: 0] += elapsed
            }
            if tool == "list_apps", useInstalledAppCache {
                return try await self.appInventory.read { try await connection.call(tool, arguments: arguments) }
            }
            if let timeout {
                return try await connection.call(tool, arguments: arguments, timeout: timeout)
            }
            return try await connection.call(tool, arguments: arguments)
        }
    }

    private func makeToolCall(invocation: Invocation,
                              useInstalledAppCache: Bool = true) -> CuaTaskAgent.Call {
        let core = driverToolCall(invocation: invocation,
                                  useInstalledAppCache: useInstalledAppCache)
        return { tool, arguments in try await core(tool, arguments, nil) }
    }

    /// The loop's per-call-timeout seam — long type_text dispatches can
    /// outrun the driver's default 30s at the synthesized-typing rate.
    private func makeTimedToolCall(invocation: Invocation) -> CuaAgentLoop.TimedCall {
        let core = driverToolCall(invocation: invocation, useInstalledAppCache: false)
        return { tool, arguments, timeout in try await core(tool, arguments, timeout) }
    }

    // MARK: - Planner + app memory

    /// Planner gate: `JARVIS_PLANNER=0` (also off/false/no) disables
    /// unconditionally — even an injected client. An injected client then
    /// wins outright; the Config flag gates only the production default so
    /// the feature stays dark until its setting exists.
    private func activePlanner() -> (any CuaPlanning)? {
        let raw = config.environment["JARVIS_PLANNER"]
            ?? getenv("JARVIS_PLANNER").map { String(cString: $0) }
        if let raw, ["0", "false", "off", "no"].contains(raw.lowercased()) {
            return nil
        }
        if let planner { return planner }
        return config.plannerEnabled ? CuaPlanner.shared : nil
    }

    /// One bounded planner call — a cold codex spawn can eat seconds, so a
    /// fixed ~4s budget races it; a slow turn keeps running detached on the
    /// warm session and is simply ignored here.
    private func planWithBudget(_ planner: any CuaPlanning, goal: String, appName: String?,
                                windowTitle: String?, memoryContext: String?,
                                previousContext: String?,
                                budget: TimeInterval = 4) async -> DrivePlan? {
        await withTaskGroup(of: DrivePlan?.self) { group in
            group.addTask {
                await planner.plan(goal: goal, appName: appName, windowTitle: windowTitle,
                                   memoryContext: memoryContext, previousContext: previousContext)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(budget))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Ledger lines "<description> → <outcome>" mark dispatches that
    /// landed; " — " lines are skips/failures and carry no outcome. Landed
    /// descriptions map to coarse lane kinds memory can rank next time.
    private static func laneKinds(in history: [String]) -> [String] {
        var kinds: [String] = []
        for line in history {
            guard let sep = line.range(of: " → ") else { continue }
            let description = String(line[..<sep.lowerBound])
            let kind: String?
            if description.hasPrefix("Pixel-click") { kind = "pixel" }
            else if description.hasPrefix("Click the"), description.hasSuffix("seen on screen") { kind = "visual" }
            else if description.hasPrefix("Click page element") { kind = "browser_click" }
            else if description.hasPrefix("Type the supplied text into page field") { kind = "browser_type" }
            else if description.hasPrefix("Click ") { kind = "click" }
            else if description.hasPrefix("Type the supplied text") {
                kind = description.contains("keyboard focus") ? "type_window" : "type"
            }
            else if description.hasPrefix("Set the value") { kind = "set_value" }
            else if description.hasPrefix("Invoke the") { kind = "menu" }
            else if description.hasPrefix("Press ") { kind = "key" }
            else if description.hasPrefix("Scroll ") { kind = "scroll" }
            else if description.hasPrefix("Navigate the tab") { kind = "navigate" }
            else if description.hasPrefix("Open a new browser tab") { kind = "new_tab" }
            else if description.hasPrefix("Accept the open") || description.hasPrefix("Dismiss the open") { kind = "dialog" }
            else { kind = nil }
            if let kind, !kinds.contains(kind) { kinds.append(kind) }
        }
        return kinds
    }

    /// Lanes grounded in the AX tree — a landed one proves the tree wasn't
    /// sparse this run.
    private static let axLaneKinds: Set<String> = ["click", "type", "set_value", "menu"]

    /// Fold a settled drive into per-app memory. Reads only what the loop
    /// observed — the terminal status and the dispatch ledger — never the
    /// model's claims. Fire-and-forget: settlement never waits on a write.
    private func recordDriveMemory(result: DriveResult, spec: TaskSpec, work: Work) {
        let bundleID = result.bundleID ?? work.bundle ?? spec.application ?? ""
        guard !bundleID.isEmpty else { return }
        var update = CuaAppMemoryUpdate(laneKinds: Self.laneKinds(in: result.history))
        if case .handedBack(.noInteractiveElements) = result.status {
            update.axSparse = true
        } else if update.laneKinds.contains(where: { Self.axLaneKinds.contains($0) }) {
            update.axSparse = false
        }
        if update.laneKinds.contains("pixel") || update.laneKinds.contains("visual") {
            update.prefersVisual = true
        }
        let appName = spec.application ?? work.bundle
        let memory = appMemory
        Task { await memory.note(bundleID: bundleID, appName: appName, record: update) }
    }

    // MARK: - Worker

    private func runWork(_ kind: AcceptedKind, work: Work, invocation: Invocation) async {
        let start = ContinuousClock.now
        var outcome: CuaDialogueState.Outcome
        do {
            try Task.checkCancellation()
            if work.stopRequested { throw CancellationError() }
            // Spawn the planner now — the lease queue and consent asks below
            // are dead time the codex cold start can overlap. Prewarm is
            // fire-and-forget and survives cancellation (the spawn adopts
            // its own result), so a queued-then-cancelled task still leaves
            // the session warm.
            if case .execute = kind, let planner = activePlanner() {
                Task { await planner.warmUp() }
            }
            work.phase = .working
            // On a locked console every activation and key event silently
            // no-ops — the driver reports `partial` for each bring_to_front
            // and each step fails with a different confusing message. One
            // session read up front turns the whole class into a single
            // honest refusal instead of a per-step failure trail.
            if screenLocked() {
                throw DriverConnectionError.refused("The screen is locked. Unlock it before running computer commands.")
            }

            // Every app-bound attempt serializes on the app lease — the fast
            // lane and the drive loop dispatch the same kind of effect. The
            // registry canonicalizes the spelling to a resolved app identity,
            // so "com.apple.Safari" and "Safari" can never dispatch
            // concurrently; a live pid is the strongest identity.
            let queueApp: String? = {
                switch kind {
                case .execute(let spec): return spec.application
                case .fastLane(let resolved, _): return resolved.name
                }
            }()
            if let queueApp, !queueApp.isEmpty {
                let display = await leaseIdentity(for: queueApp, invocation: invocation)
                work.phase = .waiting
                work.message = "Waiting for \(display)…"
                noteChange()
                let queued = ProcessInfo.processInfo.systemUptime
                try await registry.acquire(app: queueApp,
                                           pid: await leasePID(for: queueApp, invocation: invocation),
                                           workID: work.id.uuidString)
                invocation.timings["Queue wait", default: 0] +=
                    (ProcessInfo.processInfo.systemUptime - queued) * 1000
                work.phase = .working
                noteChange()
            }
            // "Jev execution" is the execution span — the same measure whether
            // the deterministic lane or the drive loop produced the effects.
            let executionStarted = ProcessInfo.processInfo.systemUptime
            defer {
                invocation.timings["Jev execution", default: 0] +=
                    (ProcessInfo.processInfo.systemUptime - executionStarted) * 1000
            }
            switch kind {
            case .fastLane(let resolved, let goal):
                work.tookFastLane = true
                try await beginAttempt(for: work)
                outcome = try await runFastLaneOutcome(resolved, goal: goal, work: work,
                                                       agent: makeAgent(invocation: invocation),
                                                       invocation: invocation)
            case .execute(let spec):
                try await beginAttempt(for: work)
                outcome = try await runExecution(spec, work: work, agent: makeAgent(invocation: invocation),
                                                 invocation: invocation)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            outcome = .cancelled(reason: "Cancelled. Already dispatched effects may have finished.")
        } catch {
            if Task.isCancelled || work.stopRequested {
                outcome = .cancelled(reason: "Cancelled. Already dispatched effects may have finished.")
            } else if let uncertain = error as? CuaUncertainOutcome {
                outcome = .uncertain(reason: uncertain.localizedDescription)
            } else if let connection = error as? DriverConnectionError {
                switch connection {
                case .refused(let reason), .remote(let reason):
                    outcome = .blocked(reason: reason)
                case .closed, .timedOut:
                    // The transport died after a dispatch could have landed —
                    // the outcome is unknowable, not failed.
                    outcome = .uncertain(reason: connection.localizedDescription)
                case .unavailable:
                    outcome = .blocked(reason: connection.localizedDescription)
                case .malformed, .toolRefused:
                    outcome = .failed(reason: connection.localizedDescription)
                }
                // The daemon's own refusal reason is stripped from the
                // user-facing message; keep it in the local log — without it
                // every distinct refusal collapses into the bare code.
                if let detail = connection.diagnosticsDetail {
                    Self.log.notice("voice_task_driver_detail \"\(work.request, privacy: .public)\" — \(detail, privacy: .public)")
                }
            } else {
                outcome = .failed(reason: error.localizedDescription)
            }
        }
        // Every terminal path stamps the full transcript→result latency —
        // not just the success one.
        work.timings["Transcript to observed result"] =
            (ProcessInfo.processInfo.systemUptime - invocation.receivedAt) * 1000
        // Jarvis-side overhead: the execution span minus everything already
        // billed to the driver, the model and the user's consent wait.
        if let execution = invocation.timings["Jev execution"], execution > 0 {
            let billed = invocation.timings.reduce(0.0) { sum, entry in
                let key = entry.key
                // "Jev latency" re-measures the "Jev judgment" span server-
                // side — billing both would double-count the same wait.
                guard key != "Jev latency" else { return sum }
                return key.hasPrefix("Cua ")
                    || (key.hasPrefix("Jev ") && key != "Jev execution")
                    || key == "Consent wait" || key == "Driver connect"
                    ? sum + entry.value : sum
            }
            invocation.timings["Internal waits"] = max(0, execution - billed)
        }
        for (name, milliseconds) in invocation.timings { work.timings[name] = milliseconds }
        // Every lane this work may hold — app, focus, pasteboard — drops on
        // teardown; a dead owner can neither hold nor later claim a slot.
        await registry.releaseAll(workID: work.id.uuidString)
        settle(work: work, outcome: outcome)
        let duration = start.duration(to: .now).components
        work.elapsedMs = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        work.active = false
        noteChange()
    }

    /// Bind the planned attempt inside the dialogue. Only an explicit
    /// prerequisite waits — and only for required supported facts, even when
    /// another part of the predecessor failed.
    private func beginAttempt(for work: Work) async throws {
        guard !work.attemptBegan else { return }
        if let prerequisite = dialogue.entry(for: work.intentID)?.prerequisite {
            var visited: Set<UUID> = []
            while true {
                guard let required = dialogue.entry(for: prerequisite.requiresIntentID) else { break }
                let requiredWork = tasks.last { $0.intentID == required.intent.id && $0.active }
                let inFlight: Bool
                if case .executing = required.status { inFlight = requiredWork != nil }
                else { inFlight = required.status == .pending && requiredWork != nil }
                guard inFlight, let awaited = requiredWork, visited.insert(required.intent.id).inserted else { break }
                work.phase = .waiting
                work.message = "Waiting for \(awaited.label)…"
                noteChange()
                await awaited.worker?.value
                try Task.checkCancellation()
            }
            guard dialogue.canExecute(work.intentID) else {
                throw DriverConnectionError.refused("The required verified result from the earlier task was not observed. Nothing dependent was executed.")
            }
        }
        guard let entry = dialogue.entry(for: work.intentID), entry.status == .pending else {
            throw DriverConnectionError.refused("The request was already resolved before execution began.")
        }
        try dialogue.begin(.init(id: work.attemptID, intentID: work.intentID,
                               instruction: entry.intent.instruction,
                               target: entry.intent.target, revision: entry.revision))
        work.attemptBegan = true
    }

    /// The deterministic fast lane: zero model calls, postcondition-verified.
    /// A `nil` runFastLane means the primitive resolved but could not dispatch
    /// (e.g. ambiguous field) — the drive loop takes over from real state.
    private func runFastLaneOutcome(_ resolved: CuaTaskAgent.FastResolution, goal: String,
                                    work: Work, agent: CuaTaskAgent,
                                    invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        if let evidence = try await agent.runFastLane(resolved, goal: goal,
            progress: { progress in
                work.message = progress
                self.noteChange()
            }) {
            work.bundle = agent.bundleID ?? work.bundle
            return verifiedOutcome(evidence: evidence, agent: agent, work: work)
        }
        // Fast lane declined to dispatch — the drive loop continues from the
        // same intent with the utterance as its goal.
        work.bundle = agent.bundleID ?? work.bundle
        let spec = TaskSpec(goal: goal, application: resolved.name)
        intentSpecs[work.intentID] = spec
        return try await runDriveLoop(spec, work: work, invocation: invocation)
    }

    /// Planner-spec execution: fast-lane retry on the normalized goal first
    /// (the planner's cleaned-up goal often parses where the raw utterance
    /// did not), then the drive loop for everything else.
    private func runExecution(_ spec: TaskSpec, work: Work, agent: CuaTaskAgent,
                              invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        // The deterministic lane covers only a pure open-scope primitive —
        // the whole contract it can satisfy. A spec carrying work, literal
        // text, or targeting constraints belongs to the drive loop, which
        // honors all of them.
        if spec.scope == .open, spec.literalText == nil,
           spec.values.isEmpty, spec.window == nil, spec.deny.isEmpty,
           let apps = try? await appList(invocation: invocation),
           let resolved = agent.resolveFastLane(goal: spec.goal, apps: apps),
           let evidence = try await agent.runFastLane(resolved, goal: spec.goal,
               progress: { progress in
                   work.message = progress
                   self.noteChange()
               }) {
            work.bundle = agent.bundleID ?? work.bundle
            return verifiedOutcome(evidence: evidence, agent: agent, work: work)
        }
        return try await runDriveLoop(spec, work: work, invocation: invocation)
    }

    /// The drive loop executes one spec to a `DriveResult`; statuses map to
    /// honest dialogue outcomes. `.needsText` re-opens the intent with a
    /// question the next utterance answers through the normal decision path.
    /// Recover the verbatim query from a "search for X" / "look up X" /
    /// "find X" / "play X" goal. Matches run on the ORIGINAL string with word
    /// boundaries — "display" never trips "play", and indices stay valid for
    /// any casing. The LAST marker wins ("use the search bar and play X"
    /// captures X), falling back to earlier markers when the last yields a
    /// stopword ("play X and search for it" still lands X). Meta-tails cut
    /// at " then " / " and <verb>" / " please" — a plain " and " survives so
    /// "Simon and Garfunkel" keeps its name. A trailing " in <app>" naming
    /// the spec's application is stripped — and so is the app's first
    /// occurrence inside the query when it leads it or sits before "for",
    /// so "search Spotify for X" yields X, not "Spotify for X".
    static func impliedQuery(in goal: String, app: String?) -> String? {
        let pattern = #"\b(search for|searching for|search|look up|looking up|lookup|google|find|play|queue|listen to|watch|put on)\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let matches = regex.matches(in: goal, range: NSRange(goal.startIndex..., in: goal))
        // Last-to-first: the most recent marker owns the payload; a marker
        // whose tail is pure meta-language defers to the one before it.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: goal) else { continue }
            let marker = String(goal[range]).lowercased()
            var query = String(goal[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Cut meta-command tails — "play X then close the app" queries
            // only X; " and " cuts only when a meta-verb follows so titles
            // like "Simon and Garfunkel" stay whole.
            let tailPattern = #"( then\b| and then\b| and (search|find|play|queue|listen|watch|google|look up|open|close|press|click|type|hit|enter|go|send|select|choose|pick)\b| and after\b| afterwards\b| after that\b| next\b|, then\b|,\s| please\b|\.\s)"#
            if let tailRegex = try? NSRegularExpression(pattern: tailPattern, options: [.caseInsensitive]),
               let cut = tailRegex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
               let cutRange = Range(cut.range, in: query) {
                query = String(query[..<cutRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if marker.hasPrefix("search"), query.lowercased().hasPrefix("for ") {
                query = String(query.dropFirst(4))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let app, !app.isEmpty {
                let tail = " " + app.lowercased()
                for preposition in [" in", " on", " within", " inside", " using"] {
                    let suffix = preposition + tail
                    if query.lowercased().hasSuffix(suffix) {
                        query = String(query.dropLast(suffix.count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
                // The app can also sit INSIDE the query — "search Spotify
                // for X" binds the app as target, not payload. Strip its
                // first occurrence when it leads the query or is directly
                // followed by "for" (consuming the preposition with it).
                // A possessive form counts as the app mention — "Spotify's"
                // strips whole so the query never starts on a dangling 's.
                if let range = query.range(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: app))(?:'s|’s)?\\b",
                    options: [.caseInsensitive, .regularExpression]) {
                    var head = String(query[..<range.lowerBound])
                    var rest = query[range.upperBound...]
                    var consumedFor = false
                    let loweredRest = rest.lowercased()
                    if loweredRest.hasPrefix(" for ") || loweredRest == " for" {
                        rest = rest.dropFirst(4)
                        consumedFor = true
                    }
                    if consumedFor || head.allSatisfy(\.isWhitespace) {
                        head = head.trimmingCharacters(in: .whitespacesAndNewlines)
                        // "in Spotify for X" — the lead preposition dangles
                        // once app+for strip; the query is X, not "in X".
                        if consumedFor, !head.isEmpty,
                           let last = head.split(whereSeparator: \.isWhitespace).last,
                           ["in", "on", "at", "within", "inside", "using",
                            "of", "for", "to"].contains(last.lowercased()) {
                            head = String(head.dropLast(last.count))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        query = (head + String(rest))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            let lowered = query.lowercased()
            guard !query.isEmpty,
                  !["for", "in", "on", "at", "the", "it", "that", "this", "them",
                    "pause", "resume", "stop", "music", "the video", "the track",
                    "the result", "the song", "that song", "the one"].contains(lowered)
            else { continue }
            return query
        }
        return nil
    }

    private func runDriveLoop(_ spec: TaskSpec, work: Work,
                              invocation: Invocation) async throws -> CuaDialogueState.Outcome {
        if requiresAPIKey, config.apiKey.isEmpty {
            return .blocked(reason: "Save the Jev API key in Commands settings to run computer tasks.")
        }
        var values = spec.values
        var goal = spec.goal
        // A search/lookup utterance's query is verbatim payload; when the
        // planner left it out of `values`, recover it from the goal so the
        // loop can type it rather than hunt for a search affordance blind.
        if values["query"] == nil, let query = Self.impliedQuery(in: spec.goal, app: spec.application) {
            values["query"] = query
        }
        switch spec.scope {
        case .open:
            goal += "\nOnly open or show the app — perform no further actions."
        case .create:
            goal += "\nThe task must produce a new top-level document or window; a pre-existing one does not satisfy it."
        case .work:
            break
        }
        if let literal = spec.literalText {
            values["literal_text"] = literal
            goal += "\nInsert this exact text where the task calls for it: \(literal)"
        }
        // The app lease was taken in runWork for every app-bound kind; this
        // acquire is a re-entrant no-op while it holds — the registry
        // satisfies a second acquire by the same work instantly, so the
        // consent follow-up path re-acquires here only if runWork did not.
        if let app = spec.application, !app.isEmpty {
            let queued = ProcessInfo.processInfo.systemUptime
            try await registry.acquire(app: app,
                                       pid: await leasePID(for: app, invocation: invocation),
                                       workID: work.id.uuidString)
            invocation.timings["Queue wait", default: 0] +=
                (ProcessInfo.processInfo.systemUptime - queued) * 1000
            // The inspector's app identity is the resolved bundle id, never
            // the planner's spelling — the loop's own resolution lands in
            // DriveResult, but "Working" needs the real id while it runs.
            if !app.contains("."),
               let apps = try? await appList(invocation: invocation),
               let real = apps.first(where: {
                   $0["name"]?.string?.caseInsensitiveCompare(app) == .orderedSame
               })?["bundle_id"]?.string {
                work.bundle = real
                noteChange()
            }
        }
        // Advisory planner + per-app memory — both only enrich
        // `previous_context` and success strings. The plan sketches steps
        // and adds proof strings; the loop's own observation still decides
        // what dispatches and what counts as done.
        var taskSuccessContains = spec.successContains
        var taskPreviousContext = dialogue.entry(for: work.intentID)?.answers.last?.utterance
        let appIdentity = work.bundle ?? spec.application
        if let appIdentity, !appIdentity.isEmpty {
            let memoryContext = await appMemory.context(forApp: appIdentity)
            if let memoryContext {
                taskPreviousContext = ([taskPreviousContext, memoryContext]
                    .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: "\n")
            }
            if let planner = activePlanner() {
                let plannerStarted = ProcessInfo.processInfo.systemUptime
                defer {
                    invocation.timings["Planner", default: 0] +=
                        (ProcessInfo.processInfo.systemUptime - plannerStarted) * 1000
                }
                if let plan = await planWithBudget(planner, goal: goal,
                                                   appName: spec.application ?? appIdentity,
                                                   windowTitle: spec.window,
                                                   memoryContext: memoryContext,
                                                   previousContext: taskPreviousContext) {
                    var advisory: [String] = []
                    if !plan.steps.isEmpty {
                        advisory.append("Plan: " + plan.steps.joined(separator: "; "))
                    }
                    if plan.hints.preferVisual {
                        advisory.append("Planner hint: this app's surface may need the visual or pixel lanes.")
                    }
                    if let notes = plan.hints.notes {
                        advisory.append("Planner note: \(notes)")
                    }
                    if !advisory.isEmpty {
                        taskPreviousContext = (advisory + [taskPreviousContext]
                            .compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: "\n")
                    }
                    for claim in plan.successContains where !taskSuccessContains.contains(claim) {
                        taskSuccessContains.append(claim)
                    }
                    feed.add(.route, "Planner: \(plan.steps.count) step\(plan.steps.count == 1 ? "" : "s")")
                }
            }
        }
        let loop = CuaAgentLoop(call: makeToolCall(invocation: invocation, useInstalledAppCache: false),
            judge: makeTimedJudge(invocation),
            approve: { [weak self] description in
                guard let self else { return false }
                return try await self.requestApproval(description, for: work, invocation: invocation)
            },
            progress: { progress in
                work.message = progress
                self.noteChange()
            },
            isFrontmostApp: isFrontmostApp,
            timedCall: makeTimedToolCall(invocation: invocation),
            lanes: CuaLaneRegistry.shared,
            workID: work.id.uuidString,
            stepTiming: { step, phaseTimes in
                for (key, milliseconds) in phaseTimes {
                    let name = "step \(step) \(key)"
                    invocation.timings[name, default: 0] += milliseconds
                    work.timings[name, default: 0] += milliseconds
                }
            })
        let result: DriveResult
        do {
            result = try await loop.drive(DriveTask(
                goal: goal, application: spec.application,
                windowName: spec.window,
                previousContext: taskPreviousContext,
                scope: spec.scope,
                values: values, deny: spec.deny,
                successContains: taskSuccessContains,
                foreground: spec.foreground
                    || Self.wantsForeground(dialogue.entry(for: work.intentID)?.intent.utterance ?? goal)))
        } catch {
            let facts = loop.observedPostconditions.compactMap { dialogueFact(from: $0, work: work) }
            guard facts.isEmpty else {
                return .partial(evidence: facts.last?.evidence ?? "Some effects were verified.",
                                blockedReason: error.localizedDescription,
                                verifiedFacts: facts)
            }
            throw error
        }
        work.bundle = result.bundleID ?? work.bundle
        work.window = result.windowID ?? work.window
        // Feed the observed outcome back into per-app memory — the status
        // and dispatch ledger, never the model's claims. Fire-and-forget.
        recordDriveMemory(result: result, spec: spec, work: work)
        if let pendingAsk = pendingLoopQuestion(result.status) {
            // The loop needs an answer the caller never supplied — finish
            // this attempt honestly and re-open the intent with the ask; the
            // answer arrives via respond_to_task and resumes in place. Any
            // failed step means a newer decision already owns this intent —
            // the parked ask drops rather than wedging it executing.
            do {
                try dialogue.finish(attemptID: work.attemptID, intentID: work.intentID,
                                    outcome: .blocked(reason: pendingAsk.prompt))
                work.attemptBegan = false
                try dialogue.revise(intentID: work.intentID)
                if let revision = dialogue.entry(for: work.intentID)?.revision {
                    try dialogue.ask(.init(intentID: work.intentID, prompt: pendingAsk.prompt,
                                           options: pendingAsk.options,
                                           target: dialogue.entry(for: work.intentID)?.intent.target,
                                           revision: revision))
                }
                work.message = pendingAsk.prompt
                pushTaskEvent(work, VoiceToolResult(
                    kind: VoiceToolResult.Kind.taskQuestion,
                    status: VoiceToolResult.Status.question,
                    say: VoiceToolResult.spoken(pendingAsk.prompt, words: 20),
                    detail: "Ask the user; when they answer, call respond_to_task. This ask belongs to task \(work.id.uuidString.prefix(8)): \"\(work.request)\".",
                    options: pendingAsk.options.isEmpty ? nil : pendingAsk.options).encoded(),
                    speak: true)
            } catch {
                work.message = "The task was revised while a question was open."
            }
            work.questionParked = true
            work.askParkedAt = ProcessInfo.processInfo.systemUptime
            work.active = false
            // A parked ask holds no app lease — the answering resume spawns
            // a fresh work that acquires it again through runWork.
            await registry.release(app: spec.application ?? "", pid: nil,
                                   workID: work.id.uuidString)
            noteChange()
            return .blocked(reason: work.message)
        }
        return mapDriveResult(result, work: work, loop: loop)
    }

    private func pendingLoopQuestion(_ status: DriveStatus) -> (prompt: String, options: [String])? {
        switch status {
        case .needsText(let label):
            // The label is often the field's own prompt ("What do you want to
            // play?") — quoting it asks better than nesting it in ours.
            let prompt = label.hasSuffix("?") || label.hasSuffix(":")
                ? label : "What text should go in \(label)?"
            return (prompt, [])
        case .needsWindow(let candidates):
            return ("Which window should I use?", candidates)
        case .handedBack(.needsChoice(let options)):
            return ("Which of these did you mean?", options)
        default:
            return nil
        }
    }

    /// Verified with postcondition evidence when the run observed real effects.
    private func verifiedOutcome(evidence: String, agent: CuaTaskAgent,
                                 work: Work) -> CuaDialogueState.Outcome {
        let facts = agent.observedPostconditions.compactMap { dialogueFact(from: $0, work: work) }
        if let fact = facts.first(where: { $0.kind == .resultObserved }) ?? facts.first {
            return .verifiedFact(fact)
        }
        return .verified(evidence: evidence)
    }

    /// Drive statuses become honest dialogue outcomes: nothing is upgraded —
    /// a partial or uncertain run never reports success, and handbacks name
    /// what was observed rather than what was attempted.
    private func mapDriveResult(_ result: DriveResult, work: Work,
                                loop: CuaAgentLoop) -> CuaDialogueState.Outcome {
        let facts = loop.observedPostconditions.compactMap { dialogueFact(from: $0, work: work) }
        let lastStep = result.history.last ?? "the task ended"
        if case .done = result.status {
            if let fact = facts.first(where: { $0.kind == .resultObserved }) ?? facts.first {
                return .verifiedFact(fact)
            }
            return .verified(evidence: lastStep)
        }
        let outcome: CuaDialogueState.Outcome
        switch result.status {
        case .done:
            return .verified(evidence: lastStep) // unreachable — handled above
        case .handedBack(let reason):
            let detail = result.history.isEmpty
                ? "Nothing was dispatched."
                : "Stopped after: \(lastStep)."
            let honest: String
            switch reason {
            case .lowConfidence:
                honest = "The next step could not be chosen confidently. \(detail)"
            case .noCandidate:
                honest = "No matching control was found on screen. \(detail)"
            case .noInteractiveElements:
                honest = "The window showed no interactive elements. \(detail)"
            case .untrustedAnswer:
                honest = "The proposed action was not trustworthy and was refused. \(detail)"
            case .needsChoice(let options):
                honest = "Several actions could match: \(options.prefix(3).joined(separator: "; ")). \(detail)"
            }
            outcome = result.history.isEmpty ? .blocked(reason: honest) : .uncertain(reason: honest)
        case .blocked(let reason):
            outcome = (work.stopRequested || Task.isCancelled) ? .cancelled(reason: reason) : .blocked(reason: reason)
        case .blockedByConsent(let reason):
            outcome = .blocked(reason: reason)
        case .needsText(let label):
            outcome = .blocked(reason: "The field \(label) needs text that was never supplied.")
        case .needsWindow(let candidates):
            outcome = .blocked(reason: "The named window is ambiguous among \(candidates.count) live windows.")
        case .maxSteps:
            outcome = .uncertain(reason: "Stopped at the step limit — \(lastStep). The outcome is unverified.")
        case .cancelled:
            outcome = .cancelled(reason: "Cancelled. Already dispatched effects may have finished.")
        }
        // Verified observations from an unfinished run ride forward on the
        // retained spec — a retry's fresh loop reads them off the goal
        // instead of re-dispatching effects that already landed.
        switch outcome {
        case .blocked, .uncertain: carryForwardEvidence(facts, work: work)
        default: break
        }
        return outcome
    }

    /// Facts observed before a blocked/uncertain settle attach to the
    /// retained spec — retryWork reuses the spec verbatim, so the fresh
    /// drive loop's goal carries what already landed.
    private func carryForwardEvidence(_ facts: [CuaDialogueState.VerifiedFact], work: Work) {
        guard !facts.isEmpty else { return }
        var spec = intentSpecs[work.intentID]
            ?? TaskSpec(goal: work.request, application: work.bundle)
        let evidence = facts.map(\.evidence).joined(separator: "; ")
        guard !spec.goal.contains("Already verified on screen") else { return }
        spec.goal += "\nAlready verified on screen in an earlier attempt — do not redo these: \(evidence)"
        intentSpecs[work.intentID] = spec
    }

    // MARK: - Agent delegation outcomes

    private func delegateOutcome(_ request: DelegationRequest) async -> (String, String) {
        guard let agentBridge else {
            return ("refused", VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "No agents are configured in this build.").encoded())
        }
        do {
            return ("answer", Self.agentReply(try await agentBridge.delegate(request)))
        } catch {
            return ("refused", VoiceToolResult(status: VoiceToolResult.Status.refused,
                say: "The agent could not be reached.",
                detail: error.localizedDescription).encoded())
        }
    }

    // MARK: - Settlement

    /// Bind an observed postcondition to the producing attempt and intent
    /// revision. A target fact with no bindable target is dropped, never fabricated.
    private func dialogueFact(from postcondition: CuaObservedPostcondition, work: Work) -> CuaDialogueState.VerifiedFact? {
        let kind: CuaDialogueState.FactKind = postcondition.kind == .targetObserved ? .targetObserved : .resultObserved
        let bundleID = postcondition.bundleID ?? work.bundle
        var target: CuaDialogueState.Target?
        if bundleID != nil || postcondition.windowID != nil || postcondition.processID != nil {
            target = .init(
                bundle: bundleID.map { .init(bundleID: $0, displayName: postcondition.appName) },
                process: postcondition.processID.map { .init(processIdentifier: Int32($0), bundleID: bundleID) },
                window: postcondition.windowID.map { .init(windowID: String($0), title: postcondition.windowTitle) },
                description: postcondition.evidence,
                provenance: .observed(attemptID: work.attemptID))
        }
        if kind == .targetObserved, target == nil { return nil }
        return .init(kind: kind, intentID: work.intentID, attemptID: work.attemptID,
                     revision: work.intentRevision, target: target, evidence: postcondition.evidence)
    }

    /// Finish the dialogue attempt, or resolve a never-begun intent so blocked
    /// and cancelled utterances cannot accumulate against unresolved capacity.
    private func settle(work: Work, outcome: CuaDialogueState.Outcome) {
        if work.questionParked {
            // The task_question push already told the model the task waits —
            // a "blocked" outcome now would contradict a live ask and read
            // as failure while the question still expects an answer. And a
            // user-driven cancel that landed while this attempt was unwinding
            // already recorded its verdict — keep it over the park reason.
            if work.outcome == nil { work.outcome = outcome }
            noteChange()
            return
        }
        if work.attemptBegan {
            do {
                try dialogue.finish(attemptID: work.attemptID, intentID: work.intentID, outcome: outcome)
            } catch {
                // A finish that fails means a newer decision already moved
                // this intent — cancel is the same honest end, never a wedge.
                try? dialogue.cancel(intentID: work.intentID, reason: Self.terminalReason(outcome))
            }
        } else if dialogue.entry(for: work.intentID)?.status == .pending {
            try? dialogue.cancel(intentID: work.intentID, reason: Self.terminalReason(outcome))
        }
        switch outcome {
        case .cancelled(let reason), .failed(let reason), .blocked(let reason), .uncertain(let reason):
            work.message = reason
        case .partial(_, let blockedReason, _):
            work.message = blockedReason
        case .verified(let evidence):
            work.message = evidence
        case .verifiedFact(let fact):
            work.message = fact.evidence
        }
        work.outcome = outcome
        switch outcome {
        case .verified, .verifiedFact:
            feed.add(.verify, work.message)
        case .partial:
            feed.add(.outcome, "Partial — \(work.message)")
        case .cancelled:
            feed.add(.outcome, work.message)
        case .failed, .blocked, .uncertain:
            feed.add(.error, work.message)
        }
        // Tell the lane what happened — the model speaks the verdict aloud.
        // Cancelled work stays context-only (the user stopped it, they know)
        // and so does a successful fast-lane effect — open/focus results are
        // visible on screen, so a spoken "Done" is noise. Drive-loop and
        // question-answering work still speaks: that result isn't visible.
        let verdict = Self.outcomeWord(outcome)
        let timingSummary = work.timings.keys.sorted()
            .map { "\($0)=\(Int(work.timings[$0] ?? 0))ms" }.joined(separator: " ")
        let usage = work.judgeInputTokens + work.judgeOutputTokens > 0
            ? " tokens=\(work.judgeInputTokens)in+\(work.judgeOutputTokens)out" : ""
        Self.log.notice("voice_task_settled \(verdict, privacy: .public) \"\(work.request, privacy: .public)\" — \(work.message, privacy: .public) [\(timingSummary, privacy: .public)\(usage, privacy: .public)]")
        let silentSuccess = work.tookFastLane && outcome.isSuccess
        pushTaskEvent(work, VoiceToolResult(
            kind: VoiceToolResult.Kind.taskOutcome,
            status: Self.outcomeStatus(outcome),
            say: Self.outcomeSay(outcome, message: work.message),
            detail: "\(work.request): \(verdict) — \(work.message)").encoded(),
            speak: !outcome.isCancelled && !silentSuccess)
        noteChange()
    }

    /// A parked consent's spoken line — the verbatim description plus a short
    /// ask so the lane can voice it without composing one.
    private static func consentSay(_ description: String) -> String {
        let ask = VoiceToolResult.spoken(description, words: 11)
        if ask.isEmpty { return "I need your confirmation, shall I?" }
        if ask.hasSuffix("?") { return ask }
        return ask + " Shall I?"
    }

    /// The outcome's status token inside a task_outcome push — the same
    /// honest verdict `outcomeWord` reports, as the contract's vocabulary.
    private static func outcomeStatus(_ outcome: CuaDialogueState.Outcome) -> String {
        switch outcome {
        case .verified, .verifiedFact: return "verified"
        case .partial: return "partial"
        case .blocked: return "blocked"
        case .failed: return "failed"
        case .uncertain: return "uncertain"
        case .cancelled: return VoiceToolResult.Status.cancelled
        }
    }

    /// One spoken sentence per settled outcome — never upgraded, never a
    /// claim the status contradicts.
    private static func outcomeSay(_ outcome: CuaDialogueState.Outcome,
                                   message: String) -> String {
        let phrase = VoiceToolResult.spoken(message, words: 9)
        switch outcome {
        case .verified, .verifiedFact:
            return phrase.isEmpty ? "Done." : "Done, \(phrase)"
        case .partial:
            return phrase.isEmpty ? "Partly done." : "Partly done, \(phrase)"
        case .blocked, .failed:
            return actionableSay(verdict: "I couldn't finish", message: message)
        case .uncertain:
            return actionableSay(verdict: "I'm not sure that landed", message: message)
        case .cancelled:
            return "Cancelled."
        }
    }

    /// "<what to do next>. <verdict>." — reason strings end on the
    /// actionable clause ("unlock it before running commands"), and a
    /// generic verdict prefix used to consume the word budget so the advice
    /// truncated away. The say composes from clauses instead: the reason's
    /// tail first — it is the part the user can act on — verdict second,
    /// two clauses at most.
    private static func actionableSay(verdict: String, message: String) -> String {
        let clauses = message
            .replacingOccurrences(of: " — ", with: ". ")
            .components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let actionable = clauses.count > 1 ? clauses.last! : (clauses.first ?? "")
        let advice = VoiceToolResult.spoken(actionable, words: 8)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        guard !advice.isEmpty else { return verdict + "." }
        let leading = advice.prefix(1).uppercased() + advice.dropFirst()
        return "\(leading). \(verdict)."
    }

    /// The one-word verdict inside a task_outcome push's detail.
    private static func outcomeWord(_ outcome: CuaDialogueState.Outcome) -> String {
        switch outcome {
        case .verified, .verifiedFact: return "done"
        case .partial: return "partially done"
        case .blocked: return "blocked"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .uncertain: return "uncertain"
        }
    }

    private static func terminalReason(_ outcome: CuaDialogueState.Outcome) -> String {
        switch outcome {
        case .cancelled(let reason), .failed(let reason), .blocked(let reason), .uncertain(let reason):
            return reason
        case .partial(let evidence, let blockedReason, _):
            return "\(evidence) — \(blockedReason)"
        case .verified(let evidence):
            return evidence
        case .verifiedFact(let fact):
            return fact.evidence
        }
    }

}


private extension CuaDialogueState.Outcome {
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
    /// Verified or verified-with-facts — the success cases.
    var isSuccess: Bool {
        switch self {
        case .verified, .verifiedFact: return true
        default: return false
        }
    }
}

private extension CuaDialogueState.Status {
    /// The compact label the planner sees for a task it may reference.
    var plannerLabel: String {
        switch self {
        case .pending: return "pending"
        case .awaitingAnswer: return "awaitingAnswer"
        case .executing: return "executing"
        case .uncertain: return "uncertain"
        case .partial: return "partial"
        case .blocked: return "blocked"
        case .cancelled: return "cancelled"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }
}
