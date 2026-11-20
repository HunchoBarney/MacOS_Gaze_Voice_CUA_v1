import Foundation
import CoreGraphics

// MARK: - Candidates

/// One scored thing the user might be looking at — the unit every gaze
/// consumer resolves through the scorer instead of acting on raw pixels.
/// Feeds: AX elements, browser DOM nodes, menu-bar items, our own chips,
/// agent cursors, Vision-OCR regions, and the window itself as the floor.
struct IntentCandidate: Sendable, Equatable, Codable {
    enum Kind: String, Sendable, Codable {
        case axElement, trafficLight, dom, menuBar, chip, agentCursor, ocr, window
    }

    /// Stable-ish identity — "ax:<pid>:<token>", "dom:<href-hash>", etc.
    /// Identity is what recency and commit history attach to.
    var id: String
    var kind: Kind
    /// Bounding rect in global top-left screen points.
    var frame: CGRect
    /// Where an actuation lands — usually == frame; a traffic-light
    /// candidate's motorRect is the button itself, not the window.
    var motorRect: CGRect
    /// AX role or DOM-ish role ("AXButton", "link", "text field"…).
    var role: String
    /// Human-readable name — label, title, or DOM text.
    var label: String
    /// DOM href when known — the reason "explain this" can fetch instead
    /// of open.
    var url: String?
    var pid: Int32?
    var windowID: Int?
    var appName: String?
    var windowTitle: String?
    /// Meta's specificity tiebreak: smaller/deeper elements outrank their
    /// containers at equal likelihood. 0…1, higher = more specific.
    var specificity: Double = 0.5
    /// Weak prior only — 0 is frontmost.
    var zOrder: Int = 0

    /// Distance from `point` to the rect edge — 0 when inside. Edge
    /// distance, not center distance: a big element under the gaze should
    /// score as well as a small one containing the point.
    func edgeDistance(to point: CGPoint) -> Double {
        // Non-standard rects (negative w/h from AX conversions) measure
        // from the wrong corners — normalize first.
        let rect = frame.standardized
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Clickable-ish roles carry a prior — the tracker can't see into an
    /// app, so role is our evidence that gaze here is *about* something.
    var clickabilityPrior: Double {
        switch kind {
        case .chip, .agentCursor, .trafficLight: return 1.6
        case .dom: return url != nil ? 1.4 : 0.9
        case .axElement, .menuBar:
            let r = role.lowercased()
            if r.contains("button") || r.contains("link") || r.contains("menu")
                || r.contains("checkbox") || r.contains("radio") || r.contains("tab")
                || r.contains("menuitem") || r.contains("cell") {
                return 1.3
            }
            if r.contains("text") || r.contains("field") || r.contains("area") {
                return 1.1
            }
            return 0.9
        case .ocr, .window: return 0.7
        }
    }
}

// MARK: - Referent

/// The semantic answer to "what are they looking at" — this is what rides
/// into task context so "explain this" resolves without pointing words.
struct GazeReferent: Sendable, Equatable {
    var candidateID: String
    var kind: IntentCandidate.Kind
    var label: String
    var role: String
    var appName: String?
    var windowTitle: String?
    var url: String?
    var frame: CGRect
    /// Normalized winner score at commit time (0…1, softmax share).
    var confidence: Double
    /// Fixation start while live (`currentReferent`); fixation END once
    /// buffered — the recency key for buffer expiry.
    var at: Date

    /// The pinned serialization for task context injection — tests hold
    /// this shape so previousContext stays machine-readable.
    var contextLine: String {
        var parts = ["\(kind.rawValue) \(role) \"\(label)\""]
        if let appName, !appName.isEmpty { parts.append("in \(appName)") }
        if let windowTitle, !windowTitle.isEmpty { parts.append("window \"\(windowTitle)\"") }
        if let url, !url.isEmpty { parts.append(url) }
        return parts.joined(separator: ", ")
    }

    init(_ candidate: IntentCandidate, confidence: Double, at: Date) {
        candidateID = candidate.id
        kind = candidate.kind
        label = candidate.label
        role = candidate.role
        appName = candidate.appName
        windowTitle = candidate.windowTitle
        url = candidate.url
        frame = candidate.frame
        self.confidence = confidence
        self.at = at
    }
}

// MARK: - Events

/// What the overlay renders — the scorer emits transitions, not frames,
/// so a flickering score can't flicker the ring.
enum IntentEvent: Equatable, Sendable {
    /// Nothing acquired (or released past the survival gap).
    case none
    /// A new winner took over — morph/show the ring on its element.
    case acquire(IntentCandidate)
    /// Incumbent still winning — update dwell progress, no visual change.
    case hold(IntentCandidate, progress: Double)
    /// Winner lost — reverse morph.
    case release(IntentCandidate)
    /// Top candidates too close to call — show the radial. A STATE,
    /// emitted on every tick the tie persists: consumers arm once per
    /// pair and retract on the first non-ambiguous event.
    case ambiguous([IntentCandidate])

    var isAmbiguous: Bool {
        if case .ambiguous = self { return true }
        return false
    }
}

// MARK: - Scorer core (pure, nonisolated, testable)

/// BayesGaze-style evidence accumulation over gaze frames:
/// each non-saccade frame adds `log(L·P)` into a leaky per-candidate
/// accumulator (exponential half-life forgets stale evidence). Handover is
/// Meta's consensus model — a challenger must lead the argmax for a
/// majority of frames inside the consensus window AND clear a score
/// margin — so single noisy frames can't flicker the winner, and the
/// incumbent survives short candidate gaps (blinks, enumeration lag).
final class IntentScorerCore {
    struct Config: Sendable {
        /// Spatial spread of the gaze likelihood in points — the user's
        /// measured error (GazeErrorBand) for the live scorer; 40 pt
        /// (~2° at laptop distance) is only the unmeasured default.
        var sigmaPx: Double = GazeErrorBand.fallbackSigmaPt
        /// Evidence half-life — stale evidence decays away in ~1s.
        var halfLifeSec: Double = 0.8
        /// Gaze observations per second counted as independent evidence.
        /// Scores stay Δt-weighted (frame-rate independent); this sets
        /// how fast they separate — at 1 a whole second of looking moved
        /// the posterior as much as one sample should.
        var evidenceRate: Double = 5
        /// A point this far from the running fixation centroid starts a
        /// new fixation even without the tracker's saccade flag (its
        /// dispersion radius is wider than neighbouring controls).
        var fixationBreakPt: Double = 48
        /// Share of the old evidence a new fixation keeps. Evidence
        /// describes where the eyes WERE: carried in full, a look at the
        /// next control waited out a whole half-life before the winner
        /// could move.
        var fixationCarry: Double = 0
        /// Frames a challenger must lead inside the new fixation before
        /// it can take over a live highlight — one noisy landing sample
        /// never moves it.
        var minHandoverFrames: Int = 2
        /// Meta's consensus window for a handover.
        var consensusWindowSec: Double = 0.2
        /// Log score margin a challenger needs over the incumbent.
        var handoverLogMargin: Double = 0.26 // ≈ ln(1.3)
        /// Top-2 softmax shares within this → ambiguous, never a guess.
        var ambiguityGap: Double = 0.15
        /// Incumbent survives candidate-feed gaps this long (blinks,
        /// re-enumeration) before release.
        var gapSurvivalSec: Double = 0.25
        /// A winner must hold this long to enter the referent buffer —
        /// Velichkovsky's ambient/focal threshold. Glances don't count.
        var focalFixationSec: Double = 0.18
        /// Referent buffer retention.
        var referentBufferSec: Double = 45
        /// Winner history depth — commit look-back lives here.
        var historySec: Double = 2.0

        static let `default` = Config()

        /// The default config with σ from the user's latest calibration or
        /// accuracy report.
        static func measured(in directory: URL? = GazeErrorBand.directory) -> Config {
            var config = Config()
            config.sigmaPx = GazeErrorBand.sigmaPt(in: directory)
            return config
        }
    }

    private var config: Config
    private var scores: [String: Double] = [:]
    private var lastSeen: [String: Date] = [:]
    private var candidatesByID: [String: IntentCandidate] = [:]
    /// Candidates present in the CURRENT feed — dropped elements can't
    /// vote or win argmax on decayed ghost scores.
    private var feedIDs: Set<String> = []
    /// Frames where each candidate led the argmax — the consensus window.
    private var argmaxHistory: [(at: Date, id: String?)] = []
    /// Per-candidate accumulated argmax time (leaky) — the focal gate.
    /// A challenger's pre-takeover consensus leadership counts: eyes on it
    /// for the whole window ARE a fixation on it.
    private var argmaxSec: [String: Double] = [:]
    /// Candidates whose accumulated argmax time ever crossed the focal
    /// gate. argmaxSec decays (split attention isn't fixation), but "was
    /// fixated ≥180ms" is a fact about the past — the referent buffer
    /// keys on the fact, not the residue.
    private var focalCrossed: Set<String> = []
    /// Winner transition history — commit look-back walks it.
    private(set) var winnerHistory: [(at: Date, candidate: IntentCandidate)] = []
    /// BayesGaze categorical prior: recent selections bias future scoring.
    /// Decays like evidence — it's recency, not popularity.
    private var selectionCounts: [String: Double] = [:]
    /// The currently-tied top-2 pair (id-ordered) and when the tie began —
    /// `.ambiguous` fires only after the SAME pair persists ~a consensus
    /// window; summed argmax residue from a previous reign isn't a tie.
    private var tiePair: (String, String)?
    private var tieSince: Date?
    /// Running centroid of the current fixation — a point past
    /// `fixationBreakPt` from it starts the next one.
    private var fixationCentroid: CGPoint?
    private var fixationSamples = 0

    private(set) var incumbent: IntentCandidate?
    private var incumbentSince: Date?
    private var lastCandidateSeenAt: Date?
    /// Commit-freshness clock — advances on fresh gaze only, so
    /// `commitTarget` fails closed once the tracker stalls.
    private var lastUpdateAt: Date?
    /// Decay/vote dt clock — advances EVERY tick. Splitting it from
    /// `lastUpdateAt` keeps a stale run from compounding the whole outage
    /// into each tick's decay, or injecting it as one giant resume vote.
    private var lastTickAt: Date?

    /// Fixation-gated history of what the user actually looked at —
    /// `commitTarget` and task context read it.
    private(set) var recentReferents: [GazeReferent] = []

    init(config: Config = .default) {
        self.config = config
    }

    /// The current winning candidate with its softmax share, if any.
    var currentWinner: (IntentCandidate, Double)? {
        guard let incumbent else { return nil }
        return (incumbent, share(of: incumbent.id))
    }

    /// The current semantic referent — the winner only counts once it has
    /// led the argmax past the focal gate (a real fixation, not a glance).
    var currentReferent: GazeReferent? {
        guard let (winner, share) = currentWinner,
              let since = incumbentSince,
              (argmaxSec[winner.id] ?? 0) >= config.focalFixationSec
        else { return nil }
        return GazeReferent(winner, confidence: share, at: since)
    }

    /// One scoring step. `candidates` is the current enumeration (feeds
    /// refresh on fixation entry / window change — re-feeding between is
    /// cheap). Saccade frames decay evidence but never vote. `freshGaze`
    /// false means the tracker stopped delivering live samples — stale
    /// input is no feed observation, enforced HERE not by caller
    /// discipline: no vote, no `lastSeen`/`lastCandidateSeenAt` refresh
    /// (a re-fed batch can't keep ghosts argmax-alive). The tick still
    /// decays and runs survival-gap/release processing with honest
    /// per-tick dt, and `lastUpdateAt` holds so `commitTarget` fails
    /// closed after the freshness window. Returns the event the overlay
    /// should render.
    @discardableResult
    func update(
        candidates: [IntentCandidate],
        at point: CGPoint,
        isSaccade: Bool,
        now: Date,
        speechHint: String? = nil,
        cursorPoint: CGPoint? = nil,
        freshGaze: Bool = true
    ) -> IntentEvent {
        // A non-finite point poisons everything downstream (log(NaN)
        // collapses shares to uniform) — skip without touching clocks.
        guard point.x.isFinite, point.y.isFinite else { return .none }
        // dt comes off the TICK clock: it advances unconditionally, so a
        // stale run decays honestly per tick instead of compounding the
        // whole outage into each step — and the first fresh tick after an
        // outage votes a normal frame's worth, not the outage duration.
        let dt = lastTickAt.map { min(max(now.timeIntervalSince($0), 0), 1) } ?? 0
        lastTickAt = now
        if freshGaze { lastUpdateAt = now }

        // Decay every tracked quantity — evidence half-life; absent
        // candidates fade instead of dying instantly (the survival gap),
        // and the recency prior fades like everything else.
        if dt > 0 {
            let decay = exp(-log(2.0) * dt / config.halfLifeSec)
            for id in scores.keys { scores[id]! *= decay }
            for id in selectionCounts.keys { selectionCounts[id]! *= decay }
            // Attention streaks decay faster — split attention isn't a
            // fixation no matter how the total sums.
            let gazeDecay = exp(-log(2.0) * dt / 0.6)
            for id in argmaxSec.keys { argmaxSec[id]! *= gazeDecay }
        }

        if freshGaze, startsFixation(at: point, flagged: isSaccade) {
            for id in scores.keys { scores[id]! *= config.fixationCarry }
            argmaxHistory.removeAll()
        }

        feedIDs = Set(candidates.map(\.id))
        if freshGaze {
            for c in candidates {
                candidatesByID[c.id] = c
                lastSeen[c.id] = now
            }
            if !candidates.isEmpty { lastCandidateSeenAt = now }
        }

        // Saccade frames don't vote — mid-flight gaze is noise. Neither
        // do stale ticks (no feed observation) or dt<=0 ticks (first
        // frame ever, same-timestamp bursts) — phantom argmax entries
        // would inflate a challenger's consensus majority.
        if freshGaze, !isSaccade, dt > 0 {
            for c in candidates {
                let l = max(likelihood(of: c, at: point), 1e-9)
                let p = prior(of: c, speechHint: speechHint, cursorPoint: cursorPoint)
                // Δt-weighted accumulation — scores are seconds of
                // evidence, so margins mean the same at any frame rate.
                // Floor at -3 nats·s: a long look-away can't dig a hole
                // so deep that re-look can never recover (~5% share).
                scores[c.id, default: 0] = max(-3.0, scores[c.id, default: 0]
                                                   + log(l * p) * dt * config.evidenceRate)
            }
            let argmaxID = topCandidate()?.0.id
            argmaxHistory.append((now, argmaxID))
            if let argmaxID {
                argmaxSec[argmaxID, default: 0] += dt
                if argmaxSec[argmaxID]! >= config.focalFixationSec {
                    focalCrossed.insert(argmaxID)
                }
            }
        }
        // History prunes on every tick — a saccade-only stall (dead
        // tracker) must not let look-back commits reach arbitrarily far.
        pruneHistory(before: now.addingTimeInterval(-config.consensusWindowSec))
        pruneScores(at: now)

        return resolveEvent(now: now, feedEmpty: !freshGaze || candidates.isEmpty)
    }

    /// Look-back commit: which candidate was winning `lookBackSec` ago —
    /// the eyes move before the words finish, so the referent of a verb is
    /// where the gaze was when the sentence started, not when it ended.
    /// `recordSelection` false makes it a read-only query — real
    /// selections feed the recency prior, peeks must not.
    func commitTarget(at now: Date, lookBackSec: Double = 0.6,
                      recordSelection: Bool = true) -> (IntentCandidate, Double)? {
        // A stalled stream means the winner is stale too — fail closed.
        guard let lastUpdateAt,
              now.timeIntervalSince(lastUpdateAt) <= GazeSample.freshnessWindow
        else { return nil }
        let horizon = now.addingTimeInterval(-lookBackSec)
        // Newest winner at-or-before the horizon — if history doesn't reach
        // back that far, fall back to the current winner rather than none.
        if let past = winnerHistory.last(where: { $0.at <= horizon })?.candidate {
            let share = share(of: past.id)
            if recordSelection { selectionCounts[past.id, default: 0] += 1 }
            return (past, share)
        }
        guard let (winner, share) = currentWinner else { return nil }
        if recordSelection { selectionCounts[winner.id, default: 0] += 1 }
        return (winner, share)
    }

    /// Softmax posterior over candidates at an arbitrary point — pure,
    /// no accumulator state touched. Available for saccade pre-scoring
    /// and the radial preview; exercised by tests, no production caller
    /// yet.
    func posterior(
        at point: CGPoint,
        candidates: [IntentCandidate],
        speechHint: String? = nil
    ) -> [(candidate: IntentCandidate, share: Double)] {
        let logs = candidates.map { c in
            (c, log(max(likelihood(of: c, at: point), 1e-6) * prior(of: c, speechHint: speechHint, cursorPoint: nil)))
        }
        guard let top = logs.map(\.1).max() else { return [] }
        let exps = logs.map { ($0.0, exp($0.1 - top)) }
        let z = exps.map(\.1).reduce(0, +)
        guard z > 0 else { return [] }
        return exps.map { ($0.0, $0.1 / z) }.sorted { $0.1 > $1.1 }
    }

    func setSigma(_ sigmaPx: Double) { config.sigmaPx = sigmaPx }

    /// Drop all state — tracker restart or a calibration change means old
    /// evidence describes a different world.
    func reset() {
        scores.removeAll(); lastSeen.removeAll(); candidatesByID.removeAll()
        feedIDs.removeAll(); argmaxHistory.removeAll(); argmaxSec.removeAll()
        focalCrossed.removeAll()
        winnerHistory.removeAll()
        selectionCounts.removeAll(); recentReferents.removeAll()
        incumbent = nil; incumbentSince = nil
        lastCandidateSeenAt = nil; lastUpdateAt = nil; lastTickAt = nil
        tiePair = nil; tieSince = nil
        fixationCentroid = nil; fixationSamples = 0
    }

    /// Tracks the running fixation and reports when this point begins a
    /// new one — the tracker's saccade flag, or a jump past
    /// `fixationBreakPt` it filtered as the same fixation.
    private func startsFixation(at point: CGPoint, flagged: Bool) -> Bool {
        guard let centroid = fixationCentroid else {
            fixationCentroid = point
            fixationSamples = 1
            return true
        }
        if flagged || hypot(point.x - centroid.x, point.y - centroid.y) > config.fixationBreakPt {
            fixationCentroid = point
            fixationSamples = 1
            return true
        }
        fixationSamples += 1
        let n = CGFloat(fixationSamples)
        fixationCentroid = CGPoint(x: centroid.x + (point.x - centroid.x) / n,
                                   y: centroid.y + (point.y - centroid.y) / n)
        return false
    }

    // MARK: - Internals

    private func likelihood(of c: IntentCandidate, at point: CGPoint) -> Double {
        let d = c.edgeDistance(to: point)
        // σ is the user's measured spread; the ~0.5° floor keeps a lucky
        // report from collapsing real near-ties into false confidence.
        let sigma = max(config.sigmaPx, GazeErrorBand.minimumSigmaPt)
        return exp(-(d * d) / (2 * sigma * sigma))
    }

    private func prior(of c: IntentCandidate, speechHint: String?, cursorPoint: CGPoint?) -> Double {
        var p = c.clickabilityPrior
        // BayesGaze categorical prior — recently picked candidates stay
        // easier to pick (bounded so history can't lock the winner in).
        p *= 1 + min(0.5, 0.1 * selectionCounts[c.id, default: 0])
        // Specificity: a button inside a window beats the window.
        p *= 0.5 + c.specificity
        // Frontmost beats occluded, weakly.
        p *= max(0.7, 1 - 0.05 * Double(c.zOrder))
        // Cursor proximity — MAGIC hot-spot: the user's hand usually
        // confirms what the eye already chose. Cursor parked INSIDE the
        // element is near-conclusive (2.5×); the falloff is tight (40px)
        // so "somewhere in the vicinity" doesn't masquerade as parked-on.
        if let cursorPoint {
            let d = c.edgeDistance(to: cursorPoint)
            p *= 1 + 1.5 * exp(-(d * d) / (2 * 40 * 40))
        }
        // Speech match — "click save" biases labeled matches.
        if let hint = speechHint, !hint.isEmpty, fuzzyMatch(hint, c.label) {
            p *= 2
        }
        return p
    }

    /// Softmax share of one candidate's accumulated evidence over the
    /// CURRENT feed — ghosts don't dilute shares. This is the confidence
    /// number referents and dwell timing consume.
    private func share(of id: String) -> Double {
        let live = scores.filter { feedIDs.contains($0.key) }
        guard let top = live.values.max() else { return 0 }
        let exps = live.values.map { exp($0 - top) }
        let z = exps.reduce(0, +)
        guard z > 0, z.isFinite, let s = live[id], s.isFinite else { return 0 }
        return exp(s - top) / z
    }

    /// Argmax by accumulated score — feed candidates only, so a vanished
    /// element's decayed residue can never win, vote, or acquire. Meta's
    /// tiebreak order: score (angle proxy) → specificity.
    private func topCandidate() -> (IntentCandidate, Double)? {
        var best: (IntentCandidate, Double)?
        for id in feedIDs {
            guard let score = scores[id], let c = candidatesByID[id] else { continue }
            if let b = best {
                if score > b.1 || (score == b.1 && c.specificity > b.0.specificity) {
                    best = (c, score)
                }
            } else {
                best = (c, score)
            }
        }
        return best
    }

    /// Top two by accumulated score, current feed only.
    private func topTwo() -> (IntentCandidate, IntentCandidate)? {
        let ranked = feedIDs.compactMap { id -> (IntentCandidate, Double)? in
            guard let s = scores[id] else { return nil }
            return candidatesByID[id].map { ($0, s) }
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.specificity > rhs.0.specificity : lhs.1 > rhs.1
        }
        guard ranked.count >= 2 else { return nil }
        return (ranked[0].0, ranked[1].0)
    }

    private func resolveEvent(now: Date, feedEmpty: Bool) -> IntentEvent {
        // An empty feed means the enumerator sees nothing — release after
        // the survival gap rather than trusting decayed ghost scores.
        guard !feedEmpty, let leader = topCandidate()?.0 else {
            return releaseIncumbentIfNeeded(now: now)
        }

        // Ambiguity: top two shares too close to call → radial, never a
        // silent guess. `.ambiguous` is a STATE — emitted on every tick
        // while the tie persists so the consumer knows the contest is
        // unresolved (the radial arms once per pair and retracts on the
        // first non-ambiguous event). Guards: the tie must have persisted
        // ~a consensus window (frame-1 scores are all ~0 — every glance
        // would flash a radial otherwise), and a tie that INCLUDES the
        // incumbent holds instead of flickering.
        if let (first, second) = topTwo() {
            let s1 = share(of: first.id), s2 = share(of: second.id)
            let inc = incumbent?.id
            if s1 > 0, s1 - s2 < config.ambiguityGap,
               first.id != inc, second.id != inc {
                // Tie persistence means the SAME pair stayed tied ~a
                // consensus window — id-ordered so a rank swap can't
                // reset it, re-keyed on any new pair so residue from a
                // previous reign can't fire the radial on arrival.
                let pair = first.id < second.id
                    ? (first.id, second.id) : (second.id, first.id)
                if tiePair.map({ $0 == pair }) != true {
                    tiePair = pair
                    tieSince = now
                }
                if let tieSince,
                   now.timeIntervalSince(tieSince) >= config.consensusWindowSec {
                    return .ambiguous([first, second])
                }
                // Fresh tie, no incumbent — wait for the evidence to
                // separate instead of acquiring on a coin flip.
                return incumbent.map { .hold($0, progress: holdProgress(now: now)) } ?? .none
            }
        }
        // No qualifying tie this tick — the contest separated, a new pair
        // formed, or the incumbent is inside it: the clock restarts.
        tiePair = nil
        tieSince = nil

        if leader.id == incumbent?.id {
            return .hold(leader, progress: holdProgress(now: now))
        }

        // Consensus handover: challenger must dominate the window AND
        // clear the margin — else the incumbent holds through the noise.
        if let current = incumbent {
            let frames = argmaxHistory.map(\.id)
            let wins = frames.filter { $0 == leader.id }.count
            let majority = wins >= config.minHandoverFrames && wins * 2 > frames.count
            // Margin in share space — exp of the log-score diff — so it's
            // identical at any accumulation rate.
            let marginOk = share(of: leader.id) >= share(of: current.id) * exp(config.handoverLogMargin)
            if !(majority && marginOk) {
                return .hold(current, progress: holdProgress(now: now))
            }
        }

        return switchIncumbent(to: leader, now: now)
    }

    private func switchIncumbent(to winner: IntentCandidate, now: Date) -> IntentEvent {
        if let old = incumbent,
           incumbentSince != nil,
           focalCrossed.contains(old.id) {
            // `at` stamps the dethrone — recency keys on when the
            // fixation ENDED, so a reign longer than the buffer isn't
            // born expired.
            pushReferent(GazeReferent(old, confidence: share(of: old.id), at: now), now: now)
        }
        incumbent = winner
        incumbentSince = now
        winnerHistory.append((now, winner))
        return .acquire(winner)
    }

    private func releaseIncumbentIfNeeded(now: Date) -> IntentEvent {
        guard let old = incumbent else { return .none }
        // Survival gap — a dropped feed or a blink shouldn't release.
        if let lastSeen = lastCandidateSeenAt,
           now.timeIntervalSince(lastSeen) <= config.gapSurvivalSec {
            return .hold(old, progress: holdProgress(now: now))
        }
        if incumbentSince != nil,
           focalCrossed.contains(old.id) {
            // Here the fixation ended when the feed last saw the
            // element — the release itself may fire long after (a dead
            // tracker's first tick back), which would overstate recency.
            let ended = min(now, lastSeen[old.id] ?? now)
            pushReferent(GazeReferent(old, confidence: share(of: old.id), at: ended), now: now)
        }
        incumbent = nil
        incumbentSince = nil
        // Whatever the eyes were on is gone — the next sample opens a new
        // fixation instead of inheriting this one's evidence.
        fixationCentroid = nil
        return .release(old)
    }

    private func holdProgress(now: Date) -> Double {
        guard let since = incumbentSince else { return 0 }
        // 0→1 across ~1s — the overlay maps this onto the dwell fill.
        return min(1, now.timeIntervalSince(since) / 1.0)
    }

    private func pushReferent(_ referent: GazeReferent, now: Date) {
        // Same referent twice in a row collapses — the buffer records
        // *changes* of attention, not dwell duration.
        if recentReferents.last?.candidateID != referent.candidateID {
            recentReferents.append(referent)
        }
        recentReferents.removeAll { now.timeIntervalSince($0.at) > config.referentBufferSec }
    }

    private func pruneHistory(before horizon: Date) {
        argmaxHistory.removeAll { $0.at < horizon }
        // The newest pre-cutoff entry marks the CURRENT reign — pruning
        // it makes a look-back commit past the horizon fall back to
        // whatever post-glance candidate happens to be winning. Keep
        // exactly that one survivor.
        let cutoff = horizon.addingTimeInterval(-config.historySec)
        if let marker = winnerHistory.lastIndex(where: { $0.at < cutoff }) {
            winnerHistory.removeSubrange(..<marker)
        }
    }

    private func pruneScores(at now: Date) {
        // lastSeen-driven pruning only — accumulation floors at -3 so a
        // separate score floor could never reach lower anyway.
        scores = scores.filter { id, _ in
            lastSeen[id].map { now.timeIntervalSince($0) <= config.historySec } ?? false
        }
        // Memory hygiene beyond the score table — saccade-fed candidates,
        // attention streaks and recency all expire on the same horizon.
        for (id, seen) in lastSeen where now.timeIntervalSince(seen) > config.historySec {
            lastSeen[id] = nil
            candidatesByID[id] = nil
            argmaxSec[id] = nil
            focalCrossed.remove(id)
        }
        selectionCounts = selectionCounts.filter { $0.value > 0.01 }
    }

    private func fuzzyMatch(_ hint: String, _ label: String) -> Bool {
        Self.labelMatches(hint: hint, label: label)
    }

    /// Token overlap — enough to bias "click save" toward the Save button
    /// without pretending to be a matcher.
    nonisolated static func labelMatches(hint: String, label: String) -> Bool {
        let stop: Set<String> = ["the", "a", "an", "this", "that", "it", "click", "open", "press"]
        let h = Set(hint.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(stop)
        let l = Set(label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return !h.isDisjoint(with: l)
    }
}

// MARK: - Actor wrapper

/// Actor shell around the pure core — feeds arrive from the gaze pump and
/// candidate enumerators; consumers await the event stream.
actor GazeIntentScorer {
    private var core: IntentScorerCore

    private let measuresSigma: Bool

    /// With no explicit config the scorer reads σ from the user's latest
    /// measured error, and re-reads it on every reset (tracker restart or
    /// recalibration).
    init(config: IntentScorerCore.Config? = nil) {
        measuresSigma = config == nil
        core = IntentScorerCore(config: config ?? .measured())
    }

    @discardableResult
    func update(
        candidates: [IntentCandidate],
        at point: CGPoint,
        isSaccade: Bool,
        speechHint: String? = nil,
        cursorPoint: CGPoint? = nil,
        freshGaze: Bool = true
    ) -> IntentEvent {
        core.update(candidates: candidates, at: point, isSaccade: isSaccade,
                    now: Date(), speechHint: speechHint,
                    cursorPoint: cursorPoint, freshGaze: freshGaze)
    }

    func commitTarget(lookBackSec: Double = 0.6,
                      recordSelection: Bool = true) -> (IntentCandidate, Double)? {
        core.commitTarget(at: Date(), lookBackSec: lookBackSec,
                          recordSelection: recordSelection)
    }

    var currentReferent: GazeReferent? { core.currentReferent }
    var recentReferents: [GazeReferent] { core.recentReferents }

    func reset() {
        core.reset()
        refreshMeasuredSigma()
    }

    /// Re-read σ from the newest report — invisible calibration rewrites
    /// its learning report as the map improves, so the band follows it.
    func refreshMeasuredSigma() {
        if measuresSigma { core.setSigma(GazeErrorBand.sigmaPt()) }
    }
}
