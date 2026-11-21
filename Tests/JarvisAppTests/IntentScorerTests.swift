import XCTest
@testable import Jarvis

/// Contract for `IntentScorerCore`: edge-distance likelihood, leaky
/// log-evidence accumulation, Meta-style consensus handover, ambiguity,
/// focal-gated referents, and look-back commits. All inputs are points +
/// candidate rects — no AX, no tracker, no clock beyond what we pass in.
final class IntentScorerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        _ id: String, x: Double, y: Double, w: Double = 60, h: Double = 24,
        role: String = "AXButton", kind: IntentCandidate.Kind = .axElement,
        label: String? = nil, specificity: Double = 0.8
    ) -> IntentCandidate {
        let frame = CGRect(x: x, y: y, width: w, height: h)
        return IntentCandidate(id: id, kind: kind, frame: frame, motorRect: frame,
                               role: role, label: label ?? id, specificity: specificity)
    }

    /// Feed `seconds` of fixation frames at `point` over `candidates`,
    /// returning every event. 60Hz cadence — the real pump's rate.
    @discardableResult
    private func gaze(
        _ scorer: IntentScorerCore, at point: CGPoint, seconds: Double,
        candidates: [IntentCandidate], from start: Date,
        saccade: Bool = false, speechHint: String? = nil
    ) -> [IntentEvent] {
        var events: [IntentEvent] = []
        let frames = max(1, Int(seconds * 60))
        for i in 0..<frames {
            let at = start.addingTimeInterval(Double(i) / 60)
            events.append(scorer.update(candidates: candidates, at: point,
                                        isSaccade: saccade, now: at,
                                        speechHint: speechHint))
        }
        return events
    }

    private func lastEvent(_ events: [IntentEvent]) -> IntentEvent { events.last ?? .none }

    // MARK: likelihood + priors

    func testInsideCandidateBeatsOutside() {
        // Edge distance, not center distance: gaze inside the rect is the
        // strongest signal, even for a big target.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("near", x: 0, y: 0)           // contains (10,10)
        let b = candidate("far", x: 500, y: 0)
        let events = gaze(s, at: CGPoint(x: 10, y: 10), seconds: 0.3,
                          candidates: [a, b], from: t0)
        XCTAssertTrue(events.contains(.acquire(a)))
        XCTAssertEqual(s.currentWinner?.0.id, "near")
    }

    func testSpecificityTiebreaksInsideBoth() {
        // A button inside a window — both contain the point, the deeper
        // element must win (Meta's specificity tiebreak).
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let window = candidate("window", x: 0, y: 0, w: 800, h: 600,
                               role: "AXWindow", kind: .window, specificity: 0.1)
        let button = candidate("ok", x: 300, y: 200, specificity: 0.9)
        gaze(s, at: CGPoint(x: 330, y: 212), seconds: 0.3,
             candidates: [window, button], from: t0)
        XCTAssertEqual(s.currentWinner?.0.id, "ok")
    }

    // MARK: accumulation + gating

    func testSaccadeFramesDoNotVote() {
        // Mid-flight gaze is noise — only the decay runs.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let events = gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.5,
                          candidates: [a], from: t0, saccade: true)
        XCTAssertTrue(events.allSatisfy { $0 == .none })
        XCTAssertNil(s.currentWinner)
    }

    func testSingleFrameChallengerCannotSteal() {
        // One noisy frame is never a handover — consensus window + margin.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 200, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.5, candidates: [a, b], from: t0)
        // One frame blip onto b — then back to a. Incumbent must survive.
        let blipAt = t0.addingTimeInterval(0.5)
        _ = s.update(candidates: [a, b], at: CGPoint(x: 230, y: 12), isSaccade: false, now: blipAt)
        let events = gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.2,
                          candidates: [a, b], from: blipAt.addingTimeInterval(1 / 60.0))
        guard case .hold(let held, _) = lastEvent(events) else {
            return XCTFail("expected incumbent hold after a blip, got \(lastEvent(events))")
        }
        XCTAssertEqual(held.id, "a")
        XCTAssertEqual(s.currentWinner?.0.id, "a")
    }

    func testSustainedChallengerTakesOver() {
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 200, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.4, candidates: [a, b], from: t0)
        // User moves to b and stays — majority-of-window + margin flips it.
        let events = gaze(s, at: CGPoint(x: 230, y: 12), seconds: 0.4,
                          candidates: [a, b], from: t0.addingTimeInterval(0.4))
        XCTAssertTrue(events.contains(.acquire(b)))
        XCTAssertEqual(s.currentWinner?.0.id, "b")
    }

    // MARK: ambiguity + release

    func testTopTwoTooCloseIsAmbiguous() {
        let s = IntentScorerCore(config: .init(sigmaPx: 200))
        // Two overlapping buttons, gaze on the seam — σ wide enough that
        // neither pulls away from the other.
        let a = candidate("left", x: 0, y: 0)
        let b = candidate("right", x: 40, y: 0)
        let events = gaze(s, at: CGPoint(x: 55, y: 12), seconds: 0.3,
                          candidates: [a, b], from: t0)
        guard case .ambiguous(let pair) = events.first(where: {
            if case .ambiguous = $0 { return true }; return false
        }) ?? .none else {
            return XCTFail("expected ambiguity, got \(lastEvent(events))")
        }
        XCTAssertEqual(Set(pair.map(\.id)), ["left", "right"])
    }

    func testIncumbentSurvivesBriefCandidateGap() {
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.3, candidates: [a], from: t0)
        // Enumeration drops the candidate for 100ms — blink of the feed,
        // not a release.
        let gapEvent = s.update(candidates: [], at: CGPoint(x: 30, y: 12),
                                isSaccade: false, now: t0.addingTimeInterval(0.4))
        guard case .hold(let held, _) = gapEvent else {
            return XCTFail("expected hold through the gap, got \(gapEvent)")
        }
        XCTAssertEqual(held.id, "a")
    }

    func testReleaseAfterGapSurvival() {
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.3, candidates: [a], from: t0)
        let event = s.update(candidates: [], at: CGPoint(x: 30, y: 12),
                             isSaccade: false, now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(event, .release(a))
    }

    // MARK: commit + referents

    func testCommitLooksBackToThePreUtteranceWinner() {
        // The eyes move before the words finish — "close this" spoken while
        // glancing away must still hit what they were looking at.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("doc", x: 0, y: 0)
        let b = candidate("other", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.5, candidates: [a, b], from: t0)
        // Eyes move to b ~200ms before the commit lands.
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.2,
             candidates: [a, b], from: t0.addingTimeInterval(0.5))
        let commitAt = t0.addingTimeInterval(0.7)
        let target = s.commitTarget(at: commitAt, lookBackSec: 0.6)
        XCTAssertEqual(target?.0.id, "doc")
    }

    func testCommitLookBackSurvivesLongReign() {
        // A reign longer than consensusWindow+historySec (2.2s) must
        // still look back correctly: history pruning keeps the entry
        // that MARKS the current reign — otherwise the commit falls back
        // to whatever post-glance candidate happens to be winning.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("doc", x: 0, y: 0)
        let b = candidate("other", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 2.6, candidates: [a, b], from: t0)
        // Glance to b — b wins the consensus and takes the ring.
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.5,
             candidates: [a, b], from: t0.addingTimeInterval(2.6))
        XCTAssertEqual(s.currentWinner?.0.id, "other")
        // The commit's 0.6s horizon lands inside the doc reign — the
        // pruned-but-kept reign marker is the only entry that can answer.
        let target = s.commitTarget(at: t0.addingTimeInterval(3.1), lookBackSec: 0.6)
        XCTAssertEqual(target?.0.id, "doc")
    }

    func testCommitQueryLeavesPriorsUntouched() {
        // recordSelection:false is a peek — it must not feed the recency
        // prior that biases future scoring.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.4, candidates: [a, b], from: t0)
        func shareOfA() -> Double {
            s.posterior(at: CGPoint(x: 30, y: 12), candidates: [a, b])
                .first { $0.candidate.id == "a" }?.share ?? 0
        }
        let before = shareOfA()
        _ = s.commitTarget(at: t0.addingTimeInterval(0.4), recordSelection: false)
        XCTAssertEqual(shareOfA(), before, accuracy: 1e-9,
                       "a read-only commit must not touch the recency prior")
        _ = s.commitTarget(at: t0.addingTimeInterval(0.4))
        XCTAssertGreaterThan(shareOfA(), before,
                             "a real selection still feeds the prior")
    }

    func testFocalGateKeepsGlancesOutOfTheReferentBuffer() {
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("glance", x: 0, y: 0)
        let b = candidate("fixated", x: 300, y: 0)
        // 100ms on a — below the 180ms focal gate, never a referent.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.1, candidates: [a, b], from: t0)
        // A real fixation on b — consensus delay eats ~0.25s of it, so the
        // argmax-time gate only counts the settled tail.
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.6, candidates: [a, b],
             from: t0.addingTimeInterval(0.1))
        // A referent only lands in the buffer once dethroned — let a take
        // over (past consensus) so "fixated" gets pushed.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.5, candidates: [a, b],
             from: t0.addingTimeInterval(0.7))
        let ids = s.recentReferents.map(\.candidateID)
        XCTAssertFalse(ids.contains("glance"))
        XCTAssertTrue(ids.contains("fixated"))
    }

    func testReferentBufferExpiresAndDedupes() {
        var config = IntentScorerCore.Config()
        config.referentBufferSec = 1.0
        let s = IntentScorerCore(config: config)
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.3, candidates: [a, b], from: t0)
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.3, candidates: [a, b],
             from: t0.addingTimeInterval(0.3))
        // Longer re-fixation — consensus handover + crater recovery take
        // ~0.4s before a reacquires and pushes b's referent.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.7, candidates: [a, b],
             from: t0.addingTimeInterval(0.6))
        // a→b→a: two entries (adjacent dupes collapse), not three.
        XCTAssertEqual(s.recentReferents.map(\.candidateID), ["a", "b"])
        // Past retention: everything drains.
        _ = s.update(candidates: [], at: .zero, isSaccade: false,
                     now: t0.addingTimeInterval(3.0))
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.05, candidates: [b],
             from: t0.addingTimeInterval(3.0))
        XCTAssertTrue(s.recentReferents.isEmpty)
    }

    func testReferentSurvivesLongerThanBufferFixation() {
        // A fixation longer than the buffer must still land a referent —
        // recency keys on when the fixation ENDED, not when it started.
        var config = IntentScorerCore.Config()
        config.referentBufferSec = 0.5
        let s = IntentScorerCore(config: config)
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 300, y: 0)
        // 0.7s reign > 0.5s buffer; dethroned moments later by b.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.7, candidates: [a, b], from: t0)
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.5, candidates: [a, b],
             from: t0.addingTimeInterval(0.7))
        XCTAssertTrue(s.recentReferents.contains { $0.candidateID == "a" },
                      "a just-ended long fixation is still a recent referent")
    }

    // MARK: priors

    func testSpeechHintBiasesScoring() {
        // Genuinely equidistant buttons — save ends at y24, quit starts
        // at y36, gaze at y30 is 6px from each; identical priors too, so
        // the label match is the ONLY thing that can break the tie.
        let s = IntentScorerCore(config: .init(sigmaPx: 60))
        let save = candidate("save-btn", x: 0, y: 0, label: "Save")
        let quit = candidate("quit-btn", x: 0, y: 36, label: "Quit")
        // Accumulated evidence needs dwell time to separate the shares —
        // the hint biases the outcome, not the first frame.
        gaze(s, at: CGPoint(x: 30, y: 30), seconds: 0.8,
             candidates: [save, quit], from: t0,
             speechHint: "click save")
        XCTAssertEqual(s.currentWinner?.0.id, "save-btn")
    }

    func testCursorProximityPrior() {
        // MAGIC hot-spot: the hand sits where the eye already decided.
        // Genuinely equidistant candidates — a ends at y24, b starts at
        // y100, gaze at y62 is 38px from each — so the parked cursor is
        // the ONLY asymmetry; it's far enough from a that a's own hot
        // -spot falloff can't blur the margin.
        let s = IntentScorerCore(config: .init(sigmaPx: 60))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 0, y: 100)
        _ = gazeWithCursor(s, at: CGPoint(x: 30, y: 62), seconds: 1.2,
                           candidates: [a, b], from: t0,
                           cursor: CGPoint(x: 30, y: 112))
        XCTAssertEqual(s.currentWinner?.0.id, "b")
    }

    private func gazeWithCursor(
        _ scorer: IntentScorerCore, at point: CGPoint, seconds: Double,
        candidates: [IntentCandidate], from start: Date, cursor: CGPoint
    ) -> [IntentEvent] {
        var events: [IntentEvent] = []
        let frames = max(1, Int(seconds * 60))
        for i in 0..<frames {
            let at = start.addingTimeInterval(Double(i) / 60)
            events.append(scorer.update(candidates: candidates, at: point,
                                        isSaccade: false, now: at,
                                        cursorPoint: cursor))
        }
        return events
    }

    // MARK: posterior + misc

    func testPosteriorSumsToOneAndRanks() {
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 500, y: 0)
        let posterior = s.posterior(at: CGPoint(x: 10, y: 10), candidates: [a, b])
        XCTAssertEqual(posterior.map(\.share).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(posterior.first?.candidate.id, "a")
    }

    func testCurrentReferentRequiresFocalHold() {
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        // 50ms in — won, but not yet a referent.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.05, candidates: [a], from: t0)
        XCTAssertNil(s.currentReferent)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.3, candidates: [a],
             from: t0.addingTimeInterval(0.05))
        XCTAssertEqual(s.currentReferent?.candidateID, "a")
        XCTAssertEqual(s.currentReferent?.label, "a")
    }

    func testResetClearsEverything() {
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.3, candidates: [a], from: t0)
        s.reset()
        XCTAssertNil(s.currentWinner)
        XCTAssertNil(s.currentReferent)
        XCTAssertTrue(s.recentReferents.isEmpty)
        XCTAssertTrue(s.winnerHistory.isEmpty)
    }

    func testDroppedCandidateCannotWinArgmax() {
        // A vanished element keeps decayed score in the table — it must
        // never vote or acquire. The feed is the world.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.4, candidates: [a, b], from: t0)
        XCTAssertEqual(s.currentWinner?.0.id, "b")
        // b drops out of the feed; gaze sits at b's old spot anyway.
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.4, candidates: [a],
             from: t0.addingTimeInterval(0.4))
        // The incumbent released (it's gone from the world); a — the only
        // real candidate — should be acquired, not ghost-b.
        XCTAssertEqual(s.currentWinner?.0.id, "a")
    }

    func testFeedDropMidConsensusDoesNotAcquireGhost() {
        // Challenger building majority when the enumeration stalls must
        // not win on momentum alone.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.5, candidates: [a, b], from: t0)
        // 3 frames of b — not yet majority — then the feed drops entirely.
        let mid = t0.addingTimeInterval(0.5)
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.05, candidates: [a, b], from: mid)
        let events = gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.4, candidates: [],
                          from: mid.addingTimeInterval(0.05))
        XCTAssertFalse(events.contains { if case .acquire(let c) = $0 { return c.id == "b" }; return false })
    }

    func testAccumulationIsCadenceInvariant() {
        // ·Δt weighting: 60Hz and 15Hz feeds must reach equivalent evidence
        // for the same wall-clock fixation — the pump's real rate ~15Hz
        // can't dilute the evidence the tuned constants assume.
        func scoreAfter(_ fps: Double) -> Double {
            let s = IntentScorerCore(config: .init(sigmaPx: 40))
            let a = candidate("a", x: 0, y: 0)
            let b = candidate("b", x: 500, y: 0)
            for i in 0..<Int(fps / 2) {   // 0.5s of fixation
                _ = s.update(candidates: [a, b], at: CGPoint(x: 30, y: 12),
                             isSaccade: false,
                             now: t0.addingTimeInterval(Double(i) / fps))
            }
            return s.currentWinner?.1 ?? 0
        }
        XCTAssertEqual(scoreAfter(60), scoreAfter(15), accuracy: 0.02)
    }

    func testAmbiguousIsAStateNotAnEdge() {
        // While the tie persists the scorer keeps reporting `.ambiguous` —
        // a consumer that only saw the first edge could never tell
        // "still contested" from "resolved". The radial lifecycle keys on
        // the state; the pop-once edge lives in the consumer's dedupe.
        var config = IntentScorerCore.Config()
        config.sigmaPx = 200
        let s = IntentScorerCore(config: config)
        let a = candidate("left", x: 0, y: 0)
        let b = candidate("right", x: 40, y: 0)
        let events = gaze(s, at: CGPoint(x: 55, y: 12), seconds: 0.45,
                          candidates: [a, b], from: t0)
        let ambiguousCount = events.filter {
            if case .ambiguous = $0 { return true }; return false
        }.count
        // The state is continuous: once the same pair has persisted a
        // consensus window, EVERY tied tick reports `.ambiguous` — the
        // count equals the number of tied ticks past the threshold, and
        // the suffix is unbroken.
        guard let firstAmbiguous = events.firstIndex(where: { $0.isAmbiguous })
        else { return XCTFail("a persistent tie must turn ambiguous") }
        XCTAssertTrue(events[firstAmbiguous...].allSatisfy { $0.isAmbiguous },
                      "every tick after onset reports ambiguous while tied")
        XCTAssertEqual(ambiguousCount, events.count - firstAmbiguous)
        // Onset: frame 0 doesn't vote (dt=0), so the tie clock starts on
        // frame 1 and can't fire before a full consensus window passes.
        let earliestOnset = 1 + Int(config.consensusWindowSec * 60)
        XCTAssertGreaterThanOrEqual(firstAmbiguous, earliestOnset)
        // The reported pair is stable — same candidates each time.
        let pairs = events.compactMap { e -> Set<String>? in
            if case .ambiguous(let c) = e { return Set(c.map(\.id)) }
            return nil
        }
        XCTAssertTrue(pairs.allSatisfy { $0 == ["left", "right"] })
    }

    func testAmbiguousResolvesToAcquire() {
        // Leaving the tied zone emits a normal acquire — the consumer's
        // cue to retract the radial. The candidate gap must exceed ~2σ:
        // leaky accumulation saturates share gaps at rate×τ, so a merely
        // "closer" candidate can sit ambiguous forever (honest — it IS
        // contested); a decisive gap lets the loser decay.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("left", x: 0, y: 0)
        let b = candidate("right", x: 140, y: 0)
        _ = gaze(s, at: CGPoint(x: 100, y: 12), seconds: 0.45,
                 candidates: [a, b], from: t0)
        let resolved = gaze(s, at: CGPoint(x: 10, y: 12), seconds: 0.5,
                            candidates: [a, b], from: t0.addingTimeInterval(0.45))
        XCTAssertTrue(resolved.contains {
            if case .acquire(let c) = $0 { return c.id == "left" }; return false
        })
    }

    func testIncumbentInsideAmbiguousPairHolds() {
        // A tie that includes the incumbent holds — ambiguity is for
        // challengers the incumbent can't shake, not the incumbent itself.
        let s = IntentScorerCore(config: .init(sigmaPx: 200))
        let a = candidate("left", x: 0, y: 0)
        let b = candidate("right", x: 40, y: 0)
        // Win a decisively first — alone in the feed, no tie possible.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.4, candidates: [a], from: t0)
        // Then b appears and gaze sits on the seam — incumbent inside the
        // near-tie must hold, not flicker ambiguous.
        let events = gaze(s, at: CGPoint(x: 50, y: 12), seconds: 0.2,
                          candidates: [a, b], from: t0.addingTimeInterval(0.4))
        XCTAssertFalse(events.contains {
            if case .ambiguous = $0 { return true }; return false
        })
    }

    func testAmbiguousNeedsSamePairPersistence() {
        // Tie persistence is measured on the CURRENT tied pair — argmax
        // residue from a previous reign isn't a tie duration, so a fresh
        // tie can't fire the radial on arrival.
        var config = IntentScorerCore.Config()
        config.sigmaPx = 200
        let s = IntentScorerCore(config: config)
        let b = candidate("b", x: 0, y: 0)
        // Long solo reign leaves deep argmax residue on b.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.6, candidates: [b], from: t0)
        // Feed goes silent long enough to release the incumbent — the
        // coming tie is b-vs-c with NO incumbent inside it.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.4, candidates: [],
             from: t0.addingTimeInterval(0.6))
        XCTAssertNil(s.currentWinner)
        let c = candidate("c", x: 40, y: 0)
        let events = gaze(s, at: CGPoint(x: 55, y: 12), seconds: 0.5,
                          candidates: [b, c], from: t0.addingTimeInterval(1.0))
        // Under residue timing this fired on the first tied frame.
        let persistence = Int(ceil(config.consensusWindowSec * 60))
        XCTAssertTrue(events.prefix(persistence).allSatisfy { !$0.isAmbiguous },
                      "a fresh tie must persist a consensus window first")
        XCTAssertTrue(events.contains { $0.isAmbiguous },
                      "the same tie past the window still reports ambiguous")
    }

    func testContestedWinCountsConsensusArgmaxTowardFocal() {
        // A challenger that led argmax through the consensus window has
        // already been fixated ~200ms — the referent must materialize on
        // takeover, not after another full focal wait.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.4, candidates: [a, b], from: t0)
        gaze(s, at: CGPoint(x: 330, y: 12), seconds: 0.5, candidates: [a, b],
             from: t0.addingTimeInterval(0.4))
        XCTAssertEqual(s.currentWinner?.0.id, "b")
        XCTAssertEqual(s.currentReferent?.candidateID, "b",
                       "consensus-leadership time must count toward the focal gate")
    }

    func testStaleTicksReleaseAndFailCommitClosed() {
        // Production outage shape: the service keeps ticking on a dead
        // tracker with an EMPTY feed and freshGaze:false. lastSeen must
        // NOT refresh — the survival gap opens, the ring releases, and
        // commitTarget fails closed once the freshness window lapses.
        // (Re-feeding the cached batch here is what kept ghosts alive.)
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.4, candidates: [a], from: t0)
        XCTAssertEqual(s.currentWinner?.0.id, "a")
        let staleEvents = (0..<60).map { i in
            s.update(candidates: [], at: CGPoint(x: 30, y: 12),
                     isSaccade: true,
                     now: t0.addingTimeInterval(0.4 + Double(i) / 60),
                     freshGaze: false)
        }
        XCTAssertTrue(staleEvents.contains {
            if case .release = $0 { return true }; return false
        }, "the survival gap must release the ring during an outage")
        XCTAssertNil(s.commitTarget(at: t0.addingTimeInterval(3.0)),
                     "stale winner must not commit after the freshness window")
    }

    func testStaleTicksDecayPerTickNotCumulatively() {
        // dt is the per-tick interval, not the outage duration — a 1s
        // outage at 60Hz must decay ~1s of evidence total, not ~30s of
        // compounding, and the first fresh tick back votes 16ms, not 1s.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.5, candidates: [a, b], from: t0)
        for i in 0..<60 {
            _ = s.update(candidates: [], at: CGPoint(x: 30, y: 12),
                         isSaccade: false,
                         now: t0.addingTimeInterval(0.5 + Double(i) / 60),
                         freshGaze: false)
        }
        // One resumed tick lands on b — a single frame of evidence, not
        // the outage's worth.
        _ = s.update(candidates: [a, b], at: CGPoint(x: 330, y: 12),
                     isSaccade: false, now: t0.addingTimeInterval(1.5))
        // Back on a — the preserved reign evidence must out-vote the blip.
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.1,
             candidates: [a, b], from: t0.addingTimeInterval(1.5 + 1.0 / 60))
        XCTAssertEqual(s.currentWinner?.0.id, "a")
        XCTAssertGreaterThan(s.currentWinner?.1 ?? 0, 0.7,
                             "per-tick decay must preserve the reign's share")
    }

    func testStaleTickWithFeedDoesNotVoteOrRefresh() {
        // The core enforces "stale input = no feed observation": a stale
        // tick carrying the re-fed batch with isSaccade:false must not
        // vote or refresh lastSeen — the survival gap still opens.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.4, candidates: [a], from: t0)
        XCTAssertEqual(s.currentWinner?.0.id, "a")
        let staleEvents = (0..<45).map { i in
            s.update(candidates: [a], at: CGPoint(x: 30, y: 12),
                     isSaccade: false,
                     now: t0.addingTimeInterval(0.4 + Double(i) / 60),
                     freshGaze: false)
        }
        XCTAssertTrue(staleEvents.contains {
            if case .release = $0 { return true }; return false
        }, "lastSeen must not refresh — the survival gap opens")
        XCTAssertTrue(staleEvents.allSatisfy {
            switch $0 {
            case .hold, .release, .none: return true
            case .acquire, .ambiguous: return false
            }
        }, "stale input can't vote — nothing new can acquire or contest")
    }

    func testSameTimestampBurstDoesNotPadConsensus() {
        // dt=0 frames carry no new evidence — a burst at one timestamp
        // must not pad a challenger's consensus window with phantom
        // argmax entries.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        let b = candidate("b", x: 300, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.5, candidates: [a, b], from: t0)
        let burstAt = t0.addingTimeInterval(0.5)
        for _ in 0..<30 {
            _ = s.update(candidates: [a, b], at: CGPoint(x: 330, y: 12),
                         isSaccade: false, now: burstAt)
        }
        XCTAssertEqual(s.currentWinner?.0.id, "a",
                       "phantom frames must not build a consensus majority")
    }

    func testNaNGazeIsSkipped() {
        // A non-finite sample is dropped before it can poison scores or
        // clocks — the tick after it must behave normally.
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.3, candidates: [a], from: t0)
        let event = s.update(candidates: [a], at: CGPoint(x: CGFloat.nan, y: 12),
                             isSaccade: false, now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(event, IntentEvent.none)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.1, candidates: [a],
             from: t0.addingTimeInterval(0.31))
        XCTAssertEqual(s.currentWinner?.0.id, "a")
    }

    func testCommitFailsClosedWhenStreamStalled() {
        let s = IntentScorerCore(config: .init(sigmaPx: 40))
        let a = candidate("a", x: 0, y: 0)
        gaze(s, at: CGPoint(x: 30, y: 12), seconds: 0.3, candidates: [a], from: t0)
        // Commit 5s later with no frames — the winner is stale, not real.
        XCTAssertNil(s.commitTarget(at: t0.addingTimeInterval(5.3)))
    }

    func testReferentContextLineCarriesUrlAndApp() {
        let dom = IntentCandidate(
            id: "dom:abc", kind: .dom,
            frame: CGRect(x: 0, y: 0, width: 200, height: 100),
            motorRect: CGRect(x: 0, y: 0, width: 200, height: 100),
            role: "link", label: "Tokyo travel video",
            url: "https://youtube.com/watch?v=abc",
            appName: "Safari", windowTitle: "YouTube")
        let referent = GazeReferent(dom, confidence: 0.8, at: t0)
        XCTAssertEqual(
            referent.contextLine,
            #"dom link "Tokyo travel video", in Safari, window "YouTube", https://youtube.com/watch?v=abc"#)
    }

    // MARK: wide error band, ties, containers (JARA-55)

    /// At a wide error band the gaze barely separates neighbours, so a
    /// cursor parked on one of them used to decide outright (×2.5) and
    /// the highlight followed the hand. The bonus now shrinks as 1/σ²,
    /// and the control the eyes are on wins.
    func testWideSigmaCursorBonusDoesNotOverrideGaze() {
        let s = IntentScorerCore(config: .init(sigmaPx: 120))
        let a = candidate("a", x: 0, y: 0, w: 100, h: 30)
        let b = candidate("b", x: 160, y: 0, w: 100, h: 30)
        _ = gazeWithCursor(s, at: CGPoint(x: 50, y: 15), seconds: 1.5,
                           candidates: [a, b], from: t0,
                           cursor: CGPoint(x: 210, y: 15))
        XCTAssertEqual(s.currentWinner?.0.id, "a")
    }

    /// A tie that includes the incumbent holds through one consensus
    /// window, then releases it: the scorer can't say which control the
    /// eyes are on, so nothing stays highlighted as if it could.
    func testTieIncludingTheIncumbentReleasesIt() {
        let s = IntentScorerCore(config: .init(sigmaPx: 200))
        let a = candidate("left", x: 0, y: 0)
        let b = candidate("right", x: 40, y: 0)
        gaze(s, at: CGPoint(x: 5, y: 12), seconds: 0.4, candidates: [a], from: t0)
        XCTAssertEqual(s.currentWinner?.0.id, "left")
        // Onto the seam both share — past the fixation break, so the
        // contest starts even.
        let events = gaze(s, at: CGPoint(x: 55, y: 12), seconds: 0.6,
                          candidates: [a, b], from: t0.addingTimeInterval(0.4))
        XCTAssertTrue(events.contains { $0.isAmbiguous })
        XCTAssertNil(s.currentWinner, "a tie leaves nothing highlighted")
        XCTAssertTrue(events.prefix(Int(0.2 * 60)).allSatisfy { !$0.isAmbiguous },
                      "the incumbent still holds through the consensus window")
    }

    /// Containers hold controls rather than being one. "tab" inside
    /// "AXTable" or "AXTabGroup" used to earn the control prior.
    func testContainersRankBelowControls() {
        let button = candidate("b", x: 0, y: 0).clickabilityPrior
        for role in ["AXTable", "AXTabGroup", "AXGroup", "AXScrollArea", "AXOutline"] {
            XCTAssertLessThan(candidate("c", x: 0, y: 0, role: role).clickabilityPrior,
                              button, role)
        }
        XCTAssertEqual(candidate("r", x: 0, y: 0, role: "AXRadioButton").clickabilityPrior, button)
        XCTAssertEqual(candidate("t", x: 0, y: 0, role: "tab", kind: .menuBar).clickabilityPrior, button)
    }
}
