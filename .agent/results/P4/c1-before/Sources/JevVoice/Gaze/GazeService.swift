import AppKit
import Foundation
import JevVoiceCore

/// B2 — the always-on gaze consumer. Owns the `/events` stream for the
/// app's life, the scored-candidate cadence (FeedGate: fetch on window
/// change, fixation entry, or TTL — never per frame), the
/// conforming-ring event fan-out, the dwell auto-click engine, and the
/// commit-time implicit labels. VoiceTaskCoordinator wires the seams in
/// `configureGazeService`; tests inject them wholesale.
///
/// Lifecycle deliberately coexists with the Fn hold's pump: the service
/// owns `GazeStream.shared` while `running`, and the coordinator's
/// hold-scoped pump reads the same `latest()` — its teardown checks
/// `running` before stopping the socket.
@MainActor
final class GazeService {
    typealias Batch = GazeCandidateFeed.Batch

    static let shared = GazeService()

    let stream: GazeStream
    let scorer: GazeIntentScorer

    // MARK: Seams — the coordinator wires the product; tests stub.

    /// The expensive enumeration, gate-driven.
    var enumerate: (CGPoint) async -> Batch = { _ in .empty }
    /// Cheap per-tick window hit-test — host-side CGWindowList, the
    /// gate's change signal.
    var windowIDUnder: (CGPoint) -> Int? = { _ in nil }
    /// The last heard utterance, briefly — the scorer's speech prior.
    var speechHint: () -> String? = { nil }
    /// MAGIC hot-spot prior — the macOS cursor in top-left points.
    var cursorPoint: () -> CGPoint? = {
        ScreenGeometry.appKitToTopLeft(NSEvent.mouseLocation)
    }
    /// Every tick's fresh point — the overlay's chip dwell and the
    /// coordinator's radial anchor.
    var gazePointSink: (CGPoint) -> Void = { TargetOverlay.shared.ingestGaze($0) }
    /// Scorer transitions → the conforming ring.
    var eventSink: (IntentEvent) -> Void = { TargetOverlay.shared.intentEvent($0) }
    /// Feed health → stale-dim; while the feed is stale it carries the
    /// live outage duration (seconds since the last fresh sample) on
    /// every tick, so duration-keyed thresholds actually fire; a 0
    /// marks recovery.
    var staleSink: (TimeInterval) -> Void = { stale in
        TargetOverlay.shared.gazeLost(stale > GazeSample.freshnessWindow)
    }
    /// Dwell suppression — the coordinator denies auto-click while an
    /// ask is parked or the overlay owns a pick.
    var dwellSuppressed: () -> Bool = { true }
    /// What a dwell commit does — the coordinator maps it to an
    /// actuation (element click / traffic-light press / pixel click).
    var actuate: (IntentCandidate) async -> Bool = { _ in false }
    /// Hard-clear for overlay chrome the scorer's events can't reach —
    /// chips, armed picks, the ring panel. Set in
    /// `configureGazeService`; stop() calls it after the terminal event
    /// so nothing stays ordered-front with the tracker off.
    var overlayTeardown: (() -> Void)?
    /// Feed/ledger note for dwell events.
    var noteOut: (String) -> Void = { _ in }
    /// Monotonic clock — tests drive ticks deterministically.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// The dwell policy — loaded once from defaults; `reloadPolicy()`
    /// re-reads after a mode flip or exemptions change.
    var dwellPolicy = DwellPolicy.load()
    var dwell = GazeDwell()
    /// Commit-time labels — breaker on the first unsupported answer.
    var labels = ImplicitLabeler()

    private var pump: Task<Void, Never>?
    private(set) var running = false
    private var gate = FeedGate()
    /// One enumeration in flight at a time — a call still inside the
    /// driver's timeout ladder doesn't get a sibling queued behind it.
    private var enumerateInFlight = false
    private(set) var batch = Batch()
    private(set) var lastPoint: CGPoint?
    private var lastFreshAt: TimeInterval = -.greatestFiniteMagnitude
    private var restarts = 0
    private var lastRestartAt: TimeInterval = -.greatestFiniteMagnitude
    /// Whether the last report was stale — the recovery edge emits one 0.
    private var reportedStale = false
    /// The candidate the ring is live on — stop() retires it
    /// synchronously; the scorer's own reset is async.
    private var liveCandidate: IntentCandidate?
    /// Defaults observer token — a Settings write to the gaze keys
    /// re-reads the dwell policy instead of pinning the launch-time mode.
    private var defaultsObserver: NSObjectProtocol?

    static let tick: Duration = .milliseconds(66)
    /// The enumeration budget per tick — a wedged driver call inside the
    /// feed suspends `enumerate` for the driver's whole timeout ladder
    /// otherwise: the reconnect cadence and the stale-feed report never
    /// run, and the ring claims live gaze on a dead feed. A timeout reads
    /// as an empty batch — the same shape the no-gaze branch feeds —
    /// while the abandoned call finishes on the driver's own deadline;
    /// its late answer is discarded, never applied over a newer tick's.
    static let enumerateDeadline: Duration = .seconds(2)
    /// Reconnect budget while the tracker was recently alive — then a
    /// slow probe so a dead tracker doesn't pay a WebSocket handshake
    /// every 2s forever.
    static let fastRestartCadence: TimeInterval = 2
    static let fastRestartAttempts = 5
    static let slowRestartCadence: TimeInterval = 15

    init(stream: GazeStream = .shared, scorer: GazeIntentScorer = GazeIntentScorer()) {
        self.stream = stream
        self.scorer = scorer
        // A Settings write to the gaze keys re-reads the policy live —
        // the launch-time load is never the last word.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadPolicy() }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Idempotent — the config toggle and lifecycle both kick it; a
    /// second start while running is a no-op, not a socket reconnect.
    func start() {
        guard !running else { return }
        running = true
        restarts = 0
        lastRestartAt = now()
        // The outage clock measures this run — a tracker dead at start
        // earns its stale-dim inside the freshness window, not instantly
        // on "last fresh: never".
        lastFreshAt = now()
        Task { await stream.start() }
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.running {
                await self.tick()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    /// The service, not its callers, owns teardown — the Fn pump and
    /// voice tasks read `latest()`, they never hold the socket.
    func stop() {
        running = false
        pump?.cancel(); pump = nil
        Task { await stream.stop() }
        // Terminal ring-down — the scorer reset lands async, so the
        // service retires the ring itself: .release shrinks it back
        // onto its element, .none when nothing was up. The teardown
        // hook then hard-clears chips/picks/ring so a live overlay
        // can't stay ordered-front past tracking-off.
        if let live = liveCandidate {
            liveCandidate = nil
            eventSink(.release(live))
        } else {
            eventSink(.none)
        }
        overlayTeardown?()
        Task { await scorer.reset() }
        Task { await labels.reset() }
        gate.reset(); batch = .empty
        // A wedged enumerate may outlive the stop — its flag must not
        // latch into the next start's ticks (its finish into a dead race
        // is harmless).
        enumerateInFlight = false
        lastPoint = nil; lastFreshAt = -.greatestFiniteMagnitude
        dwell.reset()
        if reportedStale { reportedStale = false; staleSink(0) }
    }

    /// A mode flip or exemptions change re-reads the persisted policy.
    func reloadPolicy() { dwellPolicy = DwellPolicy.load() }

    // MARK: - One tick

    private func tick() async {
        let t = now()
        // A dropped socket reconnects on a budgeted cadence — fast while
        // the tracker was recently alive, slow once it's clearly down.
        if !(await stream.streaming) {
            let cadence = restarts < Self.fastRestartAttempts
                ? Self.fastRestartCadence : Self.slowRestartCadence
            if t - lastRestartAt >= cadence {
                lastRestartAt = t
                restarts += 1
                await stream.start()
            }
        }
        if let sample = await stream.latest(), sample.isFresh {
            lastFreshAt = t
            restarts = 0
            reportStale(false)
            let point = CGPoint(x: sample.x, y: sample.y)
            lastPoint = point
            let saccade = sample.state == "saccade"
            if gate.shouldEnumerate(point: point, saccade: saccade,
                                    windowUnder: windowIDUnder(point), now: t) {
                batch = await enumerateWithinDeadline(point)
            }
            let event = await scorer.update(candidates: batch.candidates,
                                            at: point, isSaccade: saccade,
                                            speechHint: speechHint(),
                                            cursorPoint: cursorPoint())
            await handle(event)
            gazePointSink(point)
        } else {
            reportStale(true)
            // Tracker silent: feed an EMPTY feed with freshGaze:false.
            // The cached batch must NOT ride — re-marking lastSeen keeps
            // ghosts argmax-alive, the survival gap never opens, the
            // ring holds a dead element, and dwell could fire on nothing.
            // Empty feed → gap expires → release → the ring retracts;
            // lastUpdateAt freezes → commitTarget fails closed once the
            // freshness window passes. Dwell is skipped outright — no
            // hold ticks, no ghost fire inside the gap.
            if let point = lastPoint {
                let event = await scorer.update(candidates: [], at: point,
                                                isSaccade: true,
                                                freshGaze: false)
                await handle(event, dwellLive: false)
            }
        }
    }

    /// `enumerate` raced against `enumerateDeadline` — a wedged call
    /// inside the feed must not park the tick and take the reconnect
    /// loop and stale reporting down with it. The loser keeps running
    /// to its own end; nothing reads its late result, and TaskGroup
    /// can't express this because a suspended child still gates scope
    /// exit.
    private func enumerateWithinDeadline(_ point: CGPoint) async -> Batch {
        // One in flight at a time — a call still inside the driver's own
        // timeout ladder would just queue another behind it on the same
        // wedged transport. Skipping reads as the same .empty a deadline
        // loss does.
        guard !enumerateInFlight else { return .empty }
        enumerateInFlight = true
        let race = EnumerateRace()
        Task {
            let batch = await enumerate(point)
            enumerateInFlight = false
            race.finish(batch)
        }
        Task {
            try? await Task.sleep(for: Self.enumerateDeadline)
            race.finish(.empty)
        }
        return await race.result()
    }

    /// Stale-seconds report — while the feed is stale the sink hears
    /// the real outage duration on EVERY tick so stale-dim and
    /// halo-hide thresholds can actually fire; recovery reports a
    /// single 0.
    private func reportStale(_ stale: Bool) {
        if stale {
            reportedStale = true
            staleSink(max(0, now() - lastFreshAt))
        } else if reportedStale {
            reportedStale = false
            staleSink(0)
        }
    }

    private func handle(_ event: IntentEvent, dwellLive: Bool = true) async {
        // A tick still in flight when stop() ran must not re-arm
        // overlays the teardown already cleared.
        guard running else { return }
        eventSink(event)
        // Mirror the ring's live target so stop() can retire it
        // synchronously — the scorer's own reset is async.
        switch event {
        case .acquire(let c), .hold(let c, _): liveCandidate = c
        case .release, .none: liveCandidate = nil
        case .ambiguous: break
        }
        // The dwell engine only reads scorer events — a release, a feed
        // stall, an ambiguity all end or pause the hold through it. On a
        // stale tick only TERMINAL events reach the engine — a hold that
        // was mid-dwell when the tracker died aborts on the release, but
        // progress never advances on gaze nobody is reporting.
        if !dwellLive {
            switch event {
            case .hold, .acquire, .ambiguous: return
            case .release, .none: break
            }
        }
        let share: Double
        if case .hold = event {
            share = await scorer.currentReferent?.confidence ?? 0.5
        } else {
            share = 0
        }
        switch dwell.advance(event, share: share, policy: dwellPolicy) {
        case .fire(let candidate):
            // A suppressed fire is an aborted intent — feed it into the
            // learned-multiplier accounting or suppression would silently
            // tighten nothing and widen nothing.
            guard !dwellSuppressed() else {
                dwellPolicy.recordAbort()
                dwellPolicy.saveLearned()
                return
            }
            let name = candidate.label.isEmpty ? candidate.role : candidate.label
            noteOut("dwell → \(name.isEmpty ? candidate.id : name)")
            if await actuate(candidate) {
                dwellPolicy.recordCommit()
                dwellPolicy.saveLearned()
                let point = candidate.motorRect.contains(lastPoint ?? .zero)
                    ? (lastPoint ?? CGPoint(x: candidate.motorRect.midX,
                                            y: candidate.motorRect.midY))
                    : CGPoint(x: candidate.motorRect.midX, y: candidate.motorRect.midY)
                Task { await labels.commit(candidate, at: point) }
            }
        case .aborted:
            dwellPolicy.recordAbort()
            dwellPolicy.saveLearned()
        case .none:
            break
        }
    }

    // MARK: - B4 / B6 — the referent API

    /// The one referent answer every commit path reads: the winner
    /// `lookBackSec` into the sentence, plus its softmax share. nil =
    /// cold start or stalled feed — callers keep their raw-point
    /// fallback exactly as before. `recordSelection` false reads the
    /// referent without recording a commit — read-only polls
    /// (gazed-agent lookup) must not bias the scorer's selection
    /// priors or post an implicit calibration label.
    @discardableResult
    func commitTarget(lookBackSec: Double = 0.6,
                      recordSelection: Bool = true) async -> (IntentCandidate, Double)? {
        guard let hit = await scorer.commitTarget(lookBackSec: lookBackSec,
                                                  recordSelection: recordSelection)
        else { return nil }
        if recordSelection {
            let point = candidatePoint(hit.0)
            Task { await labels.commit(hit.0, at: point) }
        }
        return hit
    }

    /// Where a commit's label lands — the motor rect's midpoint, or the
    /// live gaze point when it's still inside the target.
    private func candidatePoint(_ c: IntentCandidate) -> CGPoint {
        if let point = lastPoint, c.motorRect.contains(point) { return point }
        return CGPoint(x: c.motorRect.midX, y: c.motorRect.midY)
    }

    /// Referents below this share are glances, not context.
    static let referentShareFloor = 0.3
    /// A referent older than this describes a screen that's already
    /// moved on — the focal gate plus the TTL keep stale gaze out of
    /// unrelated tasks.
    static let recentReferentTTL: TimeInterval = 45

    /// The focal-gated context line every task gets — "Looking at:" the
    /// live referent, plus up to two still-fresh recent fixations. nil
    /// when the feed is cold or everything fixated is a glance.
    func referentContext() async -> String? {
        var lines: [String] = []
        if let current = await scorer.currentReferent,
           current.confidence >= Self.referentShareFloor {
            lines.append("Looking at: \(current.contextLine)")
        }
        let recent = await scorer.recentReferents
        let fresh = recent.suffix(2).filter {
            Date().timeIntervalSince($0.at) <= Self.recentReferentTTL
                && $0.confidence >= Self.referentShareFloor
        }
        if !fresh.isEmpty {
            lines.append("Recently looked at: "
                + fresh.map(\.contextLine).joined(separator: " | "))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

// MARK: - Feed gate

/// The enumeration cadence (B2): candidates re-fetch on window change,
/// on a settled fixation entry, or on the refresh TTL — never per
/// frame. A saccade resets the settle clock so a fetch can't land
/// mid-flight on a point the eyes already left.
struct FeedGate: Sendable, Equatable {
    /// A point this far from the anchor is a new fixation.
    var settleRadius: Double = 48
    /// The gaze must park this long before the fetch fires.
    var settleSeconds: TimeInterval = 0.12
    /// A steady fixation still refreshes — the tree under a parked eye
    /// can change (scroll, JS, an agent acting) between fixations.
    var refreshTTL: TimeInterval = 1.5

    private var anchor: CGPoint?
    private var movedAt: TimeInterval = 0
    private var lastWindowID: Int?
    private var lastFetchAt: TimeInterval = -.greatestFiniteMagnitude

    mutating func shouldEnumerate(point: CGPoint, saccade: Bool,
                                  windowUnder: Int?, now: TimeInterval) -> Bool {
        if saccade { anchor = nil; return false }
        if windowUnder != lastWindowID {
            lastWindowID = windowUnder
            anchor = point
            lastFetchAt = now
            return true
        }
        if anchor == nil
            || hypot(point.x - anchor!.x, point.y - anchor!.y) > settleRadius {
            anchor = point
            movedAt = now
            return false
        }
        if now - movedAt >= settleSeconds, lastFetchAt < movedAt {
            lastFetchAt = now
            return true
        }
        if now - lastFetchAt >= refreshTTL {
            lastFetchAt = now
            return true
        }
        return false
    }

    mutating func reset() {
        anchor = nil; movedAt = 0; lastWindowID = nil
        lastFetchAt = -.greatestFiniteMagnitude
    }
}

/// First finisher wins — the enumerated batch, or `.empty` at the
/// deadline. Same shape as VoiceController's CancellationRace minus the
/// cancellation fallback: the timer IS the fallback.
private final class EnumerateRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GazeCandidateFeed.Batch, Never>?
    private var outcome: GazeCandidateFeed.Batch?
    private var settled = false

    func finish(_ value: GazeCandidateFeed.Batch) {
        lock.lock()
        if settled { lock.unlock(); return }
        settled = true; outcome = value
        let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func result() async -> GazeCandidateFeed.Batch {
        await withCheckedContinuation { (c: CheckedContinuation<GazeCandidateFeed.Batch, Never>) in
            lock.lock()
            if settled, let outcome { lock.unlock(); c.resume(returning: outcome) }
            else { continuation = c; lock.unlock() }
        }
    }
}
