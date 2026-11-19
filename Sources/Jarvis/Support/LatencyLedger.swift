import Combine
import Foundation

/// Per-interaction latency ledger — a read-only tap on the event streams
/// that already exist, never a new reporting path the lanes must feed.
///
/// Marks surface from four places:
///   - `FnInputMonitor.onAction` — fn_down / fn_release / cancel edges.
///   - `VoiceController.$captureState` — the `.finishing` edge is the
///     commit; leaving `.finishing` with text is the transcript final.
///   - `DecisionFeed.$entries` — heard / "→ drive loop" / "round N:" /
///     "tool → effect" / "dwell →" / outcome lines carry the drive side.
///   - `GazeService.eventSink` — `.acquire` is "eyes landed".
///
/// The feed cannot split a round's observe from its choose (no feed line
/// lands between `get_window_state` and `choose` returning), so the round
/// span is `round_decide_ms` — observe+choose merged — rather than two
/// numbers that aren't observable.
///
/// Completed interactions append as one JSON object per line to
/// `~/Library/Application Support/Jarvis/latency.jsonl`; the in-memory
/// ring keeps the last `capacity` records for the report's percentiles.
final class LatencyLedger {
    static let shared = LatencyLedger()

    /// Stage marks — one per transition the streams expose.
    enum Mark: String {
        case fnDown, fnRelease, commit, transcriptFinal
        case dispatch, effect, eyesLand
    }

    /// What started the interaction — voice hold, typed turn, gaze act —
    /// carried into the JSONL record for report filtering.
    enum Origin: String, Codable {
        case hold, typed, gaze, task
    }

    /// One drive-loop round's observable slice. `decideMs` is the merged
    /// observe+choose span (see the header note); `dispatchMs` is the
    /// pick→effect span, nil when the round ended without a dispatch
    /// (reobserve / done / abstain picks).
    struct Round: Codable, Equatable {
        var n: Int
        var decideMs: Double?
        var dispatchMs: Double?
    }

    /// One closed interaction — the JSONL record shape. `marks` are
    /// monotonic uptimes; `spans` are derived milliseconds filled as the
    /// ends land and finalized on close.
    struct Interaction: Codable, Equatable {
        var v = 1
        var id: UUID
        var origin: Origin
        var began: Date
        var ended: Date?
        var result: String?
        var marks: [String: TimeInterval] = [:]
        var spans: [String: Double] = [:]
        var rounds: [Round] = []
        var measurements: [String: Double] = [:]
    }

    /// Span keys the report aggregates — one list so the JSONL keys and
    /// the percentile rows can never drift apart.
    static let spanKeys = [
        "fn_hold_ms",
        "release_to_commit_ms",
        "commit_to_transcript_ms",
        "transcript_to_dispatch_ms",
        "dispatch_to_effect_ms",
        "eyes_land_to_effect_ms",
        "fn_to_effect_ms",
        "round_decide_ms",
        "round_dispatch_ms",
    ]

    /// An eyes-land mark older than this is a different glance, not the
    /// cause of the effect that just landed.
    static let eyesLandWindow: TimeInterval = 10

    // MARK: - State (lock-protected)

    private let lock = NSLock()
    private var current: Interaction?
    private var lastEyesLandAt: TimeInterval = -.greatestFiniteMagnitude
    /// The round still waiting on its "tool → effect" line.
    private var pendingRound: (n: Int, at: TimeInterval)?
    /// Where the current round's observe+choose started — set at task
    /// admission, then at each effect line.
    private var decideBase: TimeInterval?
    private var completed: [Interaction] = []
    private let capacity: Int
    private var seenFeedIDs: Set<UUID> = []
    private var previousCapture: VoiceController.CaptureState = .idle
    private var cancellables: Set<AnyCancellable> = []
    private var attached = false

    // MARK: - Clock + writer

    /// Monotonic clock — tests drive marks deterministically.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Wall clock for the record's began/ended stamps.
    var wall: () -> Date = { Date() }
    private let fileURL: URL
    /// Tests write inline so a record is on disk before the assert runs.
    private let synchronousWrites: Bool
    private let ioQueue = DispatchQueue(label: "com.karanvirkang.jarvis.latencyledger")

    /// Past this size the log rotates once to `latency-1.jsonl` — the
    /// file stays bounded without a compaction pass.
    static let rotationBytes: UInt64 = 4 * 1024 * 1024

    init(fileURL: URL? = nil, capacity: Int = 300, synchronousWrites: Bool = false) {
        self.fileURL = fileURL ?? Self.defaultURL()
        self.capacity = capacity
        self.synchronousWrites = synchronousWrites
    }

    /// `~/Library/Application Support/Jarvis/latency.jsonl` — the same
    /// support directory the tracker log and instance lock already use.
    static func defaultURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("latency.jsonl")
    }

    /// A snapshot of the closed-interaction ring, oldest first.
    var completedInteractions: [Interaction] {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    // MARK: - Wiring

    /// The one composition-root call. Chains `input.onAction` (the caller
    /// already set it — the ledger runs first so fn_release precedes the
    /// commit edge the controller emits synchronously), subscribes the
    /// feed and capture state, and wraps the gaze event sink after the
    /// coordinator's own closure so both hear every event.
    @MainActor
    func attach(controller: VoiceController, input: FnInputMonitor,
                gaze: GazeService = .shared) {
        guard !attached else { return }
        attached = true

        let priorAction = input.onAction
        input.onAction = { [weak self] action in
            switch action {
            case .begin: self?.mark(.fnDown)
            case .finish: self?.mark(.fnRelease)
            case .cancel, .cancelCapture: self?.closeCurrent(reason: "cancelled")
            case .none: break
            }
            priorAction(action)
        }

        seenFeedIDs = Set(controller.cua.feed.entries.map(\.id))
        controller.cua.feed.$entries
            .sink { [weak self] entries in self?.ingest(entries) }
            .store(in: &cancellables)

        controller.$captureState
            .sink { [weak self, weak controller] state in
                self?.captureStateChanged(state, transcript: controller?.transcript ?? "")
            }
            .store(in: &cancellables)

        controller.$measurements
            .sink { [weak self] m in self?.setMeasurements(m) }
            .store(in: &cancellables)

        // @Published fires in willSet — hop a main turn so `status` reads
        // post-change, then close on a terminal presentation the feed
        // never reports (a pure-reply turn emits no outcome line).
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak controller] _ in
                self?.statusProbe(controller?.status)
            }
            .store(in: &cancellables)

        let priorSink = gaze.eventSink
        gaze.eventSink = { [weak self] event in
            priorSink(event)
            if case .acquire = event { self?.noteEyesLand() }
        }
    }

    // MARK: - Marks

    /// Record a stage mark against the open interaction. `.fnDown` opens
    /// one; `.eyesLand` also records outside interactions (a dwell commit
    /// can be the whole interaction); other marks with nothing open are
    /// dropped — the feed-side paths re-open records lazily where they
    /// carry real work.
    func mark(_ mark: Mark) {
        let at = now()
        lock.lock(); defer { lock.unlock() }
        switch mark {
        case .fnDown:
            if var open = current {
                open.result = "superseded"
                closeLocked(&open)
            }
            current = Interaction(id: UUID(), origin: .hold, began: wall())
        case .eyesLand:
            lastEyesLandAt = at
            current?.marks[mark.rawValue] = at
            return
        default:
            guard current != nil else { return }
            current?.marks[mark.rawValue] = at
            return
        }
        current?.marks[mark.rawValue] = at
    }

    /// Eyes landed on a scored candidate — recorded outside interactions
    /// too, since a dwell commit can be the whole interaction.
    func noteEyesLand() { mark(.eyesLand) }

    /// The capture-state edge: `.finishing` is the commit; leaving it
    /// with text on the card is the transcript final (heardFinal lands
    /// `.executing`, the review lane lands `.awaitingRelease` — both read
    /// as captureState `.idle` with a transcript set). Internal so tests
    /// can drive the same transitions the sink does.
    func captureStateChanged(_ state: VoiceController.CaptureState,
                             transcript: String) {
        lock.lock()
        if state == .finishing, previousCapture != .finishing, current != nil {
            current?.marks[Mark.commit.rawValue] = now()
        }
        if previousCapture == .finishing, state != .finishing,
           current != nil, current?.marks[Mark.transcriptFinal.rawValue] == nil,
           !transcript.isEmpty {
            current?.marks[Mark.transcriptFinal.rawValue] = now()
        }
        previousCapture = state
        lock.unlock()
    }

    private func setMeasurements(_ m: [String: Double]) {
        lock.lock(); defer { lock.unlock() }
        current?.measurements = m
    }

    /// Terminal presentations the feed never reports close the record —
    /// a pure-reply turn emits no heard/route/outcome lines at all.
    func statusProbe(_ status: VoiceController.Status?) {
        guard let status else { return }
        switch status {
        case .done: closeCurrent(reason: "done")
        case .error: closeCurrent(reason: "error")
        case .idle: closeCurrent(reason: "idle")
        default: break
        }
    }

    // MARK: - Feed classification

    /// Newest feed entries — deduped against `seenFeedIDs` so the initial
    /// replay and back-to-back emissions classify once each.
    private func ingest(_ entries: [DecisionFeed.Entry]) {
        lock.lock(); defer { lock.unlock() }
        for entry in entries where !seenFeedIDs.contains(entry.id) {
            seenFeedIDs.insert(entry.id)
            classify(entry)
        }
        seenFeedIDs.formIntersection(Set(entries.map(\.id)))
    }

    /// Test seam — feed a single entry the way `ingest` does.
    func record(_ entry: DecisionFeed.Entry) { ingest([entry]) }

    private func uptime(for date: Date) -> TimeInterval {
        now() - Date().timeIntervalSince(date)
    }

    private func ensureInteraction(origin: Origin, at uptime: TimeInterval) {
        if current == nil {
            current = Interaction(id: UUID(), origin: origin, began: wall())
        }
    }

    /// `.dispatch`-kind lines that END an effect span — `tool → effect`
    /// results and the two commit lines (dwell fires, numbered picks)
    /// that dispatch without a `tool →` result of their own.
    private static let effectLine = try? NSRegularExpression(
        pattern: #"^(?!dwell\b)[a-z_]+ → "#)
    private static let dwellLine = try? NSRegularExpression(pattern: #"^dwell → "#)
    private static let pickLine = try? NSRegularExpression(pattern: #"^picked numbered target"#)
    private static let roundLine = try? NSRegularExpression(pattern: #"^round\s+(\d+):"#)

    private func isEffectLine(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return Self.effectLine?.firstMatch(in: text, range: range) != nil
            || Self.pickLine?.firstMatch(in: text, range: range) != nil
    }

    private func isDwellLine(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return Self.dwellLine?.firstMatch(in: text, range: range) != nil
    }

    /// Feed-entry → marks. Only the transitions that are real events get
    /// classified; consent/verify/note lines stay feed-only.
    private func classify(_ entry: DecisionFeed.Entry) {
        let at = uptime(for: entry.at)
        switch entry.kind {
        case .heard:
            // A heard line with no open interaction is a typed turn (or a
            // retry) — the transcript IS its start.
            ensureInteraction(origin: .typed, at: at)
            if current?.marks[Mark.transcriptFinal.rawValue] == nil {
                current?.marks[Mark.transcriptFinal.rawValue] = at
            }
        case .route where entry.text.hasSuffix("→ drive loop"):
            ensureInteraction(origin: .task, at: at)
            if current?.marks[Mark.dispatch.rawValue] == nil {
                current?.marks[Mark.dispatch.rawValue] = at
            }
            decideBase = at
        case .dispatch:
            let text = entry.text
            if let match = Self.roundLine?.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
               let nRange = Range(match.range(at: 1), in: text),
               let n = Int(text[nRange]) {
                ensureInteraction(origin: .task, at: at)
                let decide = decideBase.map { max(0, (at - $0) * 1000) }
                current?.rounds.append(Round(n: n, decideMs: decide, dispatchMs: nil))
                // A round line with a round still pending means the last
                // pick was reobserve/done/abstain — no dispatch came; the
                // pending round keeps its nil dispatchMs either way.
                pendingRound = (n: n, at: at)
                decideBase = nil
                return
            }
            if isDwellLine(text) {
                // The dwell commit — eyes landed, the actuation is the effect.
                recordEyesEffect(at: at)
                if current != nil { markEffect(at: at) }
                return
            }
            if isEffectLine(text) {
                markEffect(at: at)
            }
        case .outcome:
            closeCurrentLocked(reason: "settled")
        default:
            break
        }
    }

    /// An effect landed: close any pending round's dispatch span, set the
    /// next round's decide base, and resolve the eyes-land span when the
    /// land is still inside its window.
    private func markEffect(at: TimeInterval) {
        ensureInteraction(origin: .task, at: at)
        if current?.marks[Mark.effect.rawValue] == nil {
            current?.marks[Mark.effect.rawValue] = at
        }
        recordEyesEffect(at: at)
        if let pending = pendingRound,
           let idx = current?.rounds.lastIndex(where: { $0.n == pending.n }) {
            current?.rounds[idx].dispatchMs = max(0, (at - pending.at) * 1000)
        }
        pendingRound = nil
        decideBase = at
    }

    /// eyes_land→effect resolves once per land — the first effectish
    /// event inside the window consumes it.
    private func recordEyesEffect(at: TimeInterval) {
        guard lastEyesLandAt > 0, at - lastEyesLandAt <= Self.eyesLandWindow else { return }
        ensureInteraction(origin: .gaze, at: lastEyesLandAt)
        if current?.marks[Mark.eyesLand.rawValue] == nil {
            current?.marks[Mark.eyesLand.rawValue] = lastEyesLandAt
        }
        if current?.spans["eyes_land_to_effect_ms"] == nil {
            current?.spans["eyes_land_to_effect_ms"] = max(0, (at - lastEyesLandAt) * 1000)
        }
        lastEyesLandAt = -.greatestFiniteMagnitude
        // A pure-gaze interaction (a dwell click with no voice turn) is
        // complete the moment its effect lands — nothing else arrives.
        if current?.origin == .gaze {
            closeCurrentLocked(reason: "effect")
        }
    }

    // MARK: - Close

    /// End the open interaction: derive the remaining spans, ring it,
    /// append the JSONL line. Idempotent — a close with nothing open
    /// no-ops, and a superseded interaction still writes whatever marks
    /// it earned.
    func closeCurrent(reason: String) {
        lock.lock(); defer { lock.unlock() }
        closeCurrentLocked(reason: reason)
    }

    private func closeCurrentLocked(reason: String) {
        guard var open = current else { return }
        if open.result == nil { open.result = reason }
        closeLocked(&open)
    }

    /// The shared close path — `open` is the interaction being retired
    /// (always `current`, passed so superseded closes read plainly).
    private func closeLocked(_ open: inout Interaction) {
        finalizeSpans(&open)
        open.ended = wall()
        completed.append(open)
        if completed.count > capacity { completed.removeFirst(completed.count - capacity) }
        current = nil
        pendingRound = nil
        decideBase = nil
        write(open)
    }

    /// Marks → spans. Only pairs that both landed produce a number — a
    /// cancelled hold still writes the spans it reached.
    private func finalizeSpans(_ open: inout Interaction) {
        func span(_ key: String, _ a: Mark, _ b: Mark) {
            guard open.spans[key] == nil,
                  let t0 = open.marks[a.rawValue],
                  let t1 = open.marks[b.rawValue] else { return }
            open.spans[key] = max(0, (t1 - t0) * 1000)
        }
        span("fn_hold_ms", .fnDown, .fnRelease)
        span("release_to_commit_ms", .fnRelease, .commit)
        span("commit_to_transcript_ms", .commit, .transcriptFinal)
        span("transcript_to_dispatch_ms", .transcriptFinal, .dispatch)
        span("dispatch_to_effect_ms", .dispatch, .effect)
        span("fn_to_effect_ms", .fnDown, .effect)
    }

    // MARK: - JSONL writer

    private func write(_ interaction: Interaction) {
        guard let data = try? Self.encoder.encode(interaction) else { return }
        var line = data
        line.append(0x0A)
        let writeBlock = { [fileURL] in Self.appendLine(line, to: fileURL) }
        if synchronousWrites { writeBlock() } else { ioQueue.async(execute: writeBlock) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static func appendLine(_ line: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           UInt64(size) > rotationBytes {
            let rotated = url.deletingPathExtension()
                .appendingPathExtension("1.jsonl")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if fm.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch { }
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    // MARK: - Report

    /// p50/p95 per stage across the ring — the "Copy latency report"
    /// payload. Empty stages keep their n=0 line so a sparse first hour
    /// still shows which spans the ledger CAN see.
    func report() -> String {
        let interactions = completedInteractions
        var lines = [
            "Jarvis latency report · \(interactions.count) interactions",
            "generated \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))",
            "",
        ]
        var samples: [String: [Double]] = [:]
        for interaction in interactions {
            for (key, value) in interaction.spans { samples[key, default: []].append(value) }
            for round in interaction.rounds {
                if let decide = round.decideMs { samples["round_decide_ms", default: []].append(decide) }
                if let dispatch = round.dispatchMs { samples["round_dispatch_ms", default: []].append(dispatch) }
            }
        }
        for key in Self.spanKeys {
            let values = (samples[key] ?? []).sorted()
            guard !values.isEmpty else {
                lines.append("\(key.padding(toLength: 28, withPad: " ", startingAt: 0)) n=0")
                continue
            }
            let p50 = Self.percentile(values, 0.50)
            let p95 = Self.percentile(values, 0.95)
            lines.append("\(key.padding(toLength: 28, withPad: " ", startingAt: 0))"
                + "p50 \(Self.ms(p50))  p95 \(Self.ms(p95))  n=\(values.count)")
        }
        return lines.joined(separator: "\n")
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return sorted[index]
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%6.0f ms", value)
    }
}
