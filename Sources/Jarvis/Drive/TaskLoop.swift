import CoreGraphics
import Foundation
import JarvisCore
import os

// MARK: - CONTRACTS §1 frozen shapes (v0)
//
// One `TaskLoop` drives all UI automation: observe → decide → act →
// settle. A `Decider` is the brain it calls once per round — it returns
// exactly one `DecideResult` and never actuates, asks, or verifies
// itself; the loop owns actuation, settle, budgets, and consent
// routing. `done` is a claim the loop must be able to verify: a decider
// that reports done without a preceding successful verify_state settle
// is a defect (the "zero false Done" bar), and the loop enforces it.

/// What the loop hands the decider each round.
struct TaskObservation: Sendable {
    var stepIndex: Int                    // 0-based round number
    var axSnapshot: AXSnapshot?           // nil when degraded
    var domSnapshot: DOMSnapshot? = nil   // browsers only; nil elsewhere
    var task: TaskBrief                   // goal, constraints, gaze hint
    var history: [RoundRecord]            // prior picks + settle results
    var budget: RoundBudget               // rounds/ms remaining
    var nativeDocumentAnchor: NativeDocumentSubject? = nil
    var replacementReceipt: NativeReplacementReceipt? = nil
    var deliveredReplacement: DeliveredReplacementObservation? = nil
}

/// What the decider returns — exactly one of these per round.
enum DecideResult: Sendable, Equatable {
    case act(ActuationRequest)            // loop executes + settles
    case askUser(question: String, choices: [String])
    case escalate(reason: EscalationReason) // Jev→Sol / DOM→pixels
    case done(summary: String)            // only after verify_state
    case blocked(reason: BlockedReason)   // consent, deny-list, safety
}

protocol Decider: Sendable {
    func nextStep(_ observation: TaskObservation) async throws -> DecideResult
}

enum EscalationReason: String, Sendable {
    case lowConfidenceTwice, staleScreen, invalidChoice,
         degradedAX, roundBudgetExhausted, wallBudgetExhausted, domCannotGround
}

/// Why a task stopped short — the loop classifies its own blocks; the
/// decider's `.blocked` reasons pass through unchanged.
enum BlockedReason: Sendable, Equatable {
    /// A consent gate denied the action, a confirm was declined, or a
    /// required confirm had no ask channel.
    case consent(String)
    /// The task's own deny strings or a policy deny-list hit — no grant
    /// or approval reverses it.
    case denyList(String)
    /// A safety stop — no safe next step, a protected target.
    case safety(String)
    /// The decider's own reason or a thrown decider failure.
    case decider(String)
    /// Dispatch refused or the transport failed mid-task.
    case actuation(String)
    /// A done claim with no preceding successful verify_state settle.
    case unverifiedDone
    /// No bound window and no frontmost window to bind.
    case unobservable
}

/// The goal and its constraints — the task's own words, never model
/// text. `values` are caller-supplied literals used verbatim (the
/// decider selects fields; it never authors text), `window` is the
/// captured/pinned target — bound once, never substituted.
struct TaskBrief: Sendable, Equatable {
    var goal: String
    var window: WindowRef? = nil
    var application: String? = nil
    var values: [String: String] = [:]
    var deny: [String] = []
    /// Postcondition strings a verify_state settle looks for.
    var successContains: [String] = []
    var context: String? = nil
    /// Resolved referent text — a hint, never raw coordinates.
    var gazeHint: String? = nil
}

/// Prior rounds as the loop recorded them — what the decider returned,
/// whether an effect dispatched and its settle verified, ask traffic,
/// and the stale-screen marks the decider's escalation reads.
struct RoundRecord: Sendable {
    /// Compact echo of the round's DecideResult — a decider re-created
    /// mid-task still reads its own retry history.
    enum Echo: String, Sendable {
        case act, verify, reobserve, ask, done, blocked, escalate, rejectedDone
    }
    /// Which lane an ask came through — a consent "yes" is an approval,
    /// never literal text a decider may type.
    enum AskKind: String, Sendable { case consent, question }

    var stepIndex: Int
    var echo: Echo
    var summary: String
    var detail: String? = nil
    var actuated = false            // the loop dispatched a real effect
    var settleVerified = false      // verify_state settle succeeded
    var staleScreen = false         // observation fingerprint unchanged
    var askKind: AskKind? = nil
    var askQuestion: String? = nil
    var askAnswer: String? = nil
}

struct RoundBudget: Sendable {
    var roundsRemaining: Int?
    var millisecondsRemaining: Int?
}

/// The decider's request for the loop to execute. `reobserve` and
/// `verifyState` dispatch no effect — verify_state is how an "already
/// true" goal earns its done claim: the loop observes and checks the
/// declared evidence, and only a verified settle unlocks `done`.
struct ActuationRequest: Sendable, Equatable {
    enum Effect: String, Sendable {
        case tool          // dispatch `tool`/`args` — a real mutation
        case verifyState   // run verify_state only — no effect
        case reobserve     // observe again — no effect
    }
    var effect: Effect
    /// The driver tool for `.tool` requests — element actions address
    /// the fresh snapshot by element_token / element_index+snapshot_id.
    /// pid/window_id are LOOP authority and stamped at dispatch.
    var tool: String
    var args: [String: JSONValue] = [:]
    var verification: ObservedGoalProof? = nil
    var replacement: NativeReplacementProposal? = nil
    /// The consent/deny-scan corpus — element label+value, dialog
    /// title. Typed text stays out, the same exclusion the policy
    /// applies to args["text"].
    var elementText: String? = nil
    /// Ledger line — "press \"Save\" (button)".
    var summary: String
}

struct NativeReplacementReceipt: Sendable, Equatable {
    let id: UUID
    let proposal: NativeReplacementProposal

    fileprivate init(proposal: NativeReplacementProposal) {
        id = UUID()
        self.proposal = proposal
    }
}

struct DeliveredReplacementObservation: Sendable {
    let binding: NativeReplacementBinding

    fileprivate init(binding: NativeReplacementBinding) {
        self.binding = binding
    }
}

// MARK: - CONTRACTS §2 frozen shapes (v0)

/// The single seam for observing the screen. Backed by the pinned Cua
/// driver in production; fakes satisfy the same protocol in tests.
protocol CaptureSource: Sendable {
    func frontmostWindow() async throws -> WindowRef
    func axTree(of window: WindowRef,
                depth: AXDepth) async throws -> AXSnapshot
    func domSnapshot(of window: WindowRef) async throws -> DOMSnapshot // browsers
    /// Screen is quiet long enough to trust the observation.
    func settled(within timeout: Duration) async -> Bool
}

struct WindowRef: Sendable, Hashable {
    var pid: Int
    var windowID: Int
}

/// How much tree one observe pays for — the production read is
/// 600 elements / 20 deep.
struct AXDepth: Sendable, Equatable {
    var maxElements: Int
    var maxDepth: Int
    static let standard = AXDepth(maxElements: 600, maxDepth: 20)
}

struct NativeDocumentSubject: Sendable, Equatable {
    var window: WindowRef
    var fingerprint: Data
}

struct NativeFieldProvenance: Sendable, Equatable {
    var window: WindowRef
    var document: NativeDocumentSubject?
}

struct AXSnapshot: Sendable {
    var windowTitle: String?
    var snapshotID: String?
    var elements: [AXElement]
    /// The rendered text tree — verify_state's successContains evidence
    /// scans it first, element label+value text as fallback.
    var treeMarkdown: String
    var goalContextComplete = true
    var nativeDocument: NativeDocumentSubject? = nil
}

struct AXElement: Sendable {
    var index: Int
    var token: String?
    var role: String
    var label: String
    var value: String?
    var frame: CGRect?
    var actions: [String]
    var nativeValue: NativeFieldProvenance? = nil
    var nativeIdentity: NativeFieldIdentity? = nil
    var nativeAncestorRoles: [String]? = nil
}

/// DOM-first browser control's snapshot shape — CONTRACTS §5.
struct DOMSnapshot: Sendable {
    var url: String
    var title: String
    /// Compact indexed form — Browser-Use style: "[12] <button> Save".
    var indexedText: String
    var elements: [DOMElement]      // index → role, name, bbox, href?
}

struct DOMElement: Sendable {
    var index: Int
    var role: String
    var name: String
    var bounds: CGRect?
    var href: String?
}

// MARK: - The loop

/// How a run ended — `done` is always settle-verified; budget exhaustion
/// and decider escalations both surface as `escalated` so the ladder
/// (Jev→Sol) sees one shape.
enum TaskOutcome: Sendable, Equatable {
    case done(summary: String)
    case blocked(BlockedReason)
    case escalated(EscalationReason)
    case cancelled
    /// The goal was already true — zero verified effects behind the
    /// done claim. Only reachable under
    /// `Config.DonePolicy.verifiedOrAlreadySatisfied` (the drive lane's
    /// settle rule); the contract default rejects such claims instead.
    case alreadySatisfied(reason: String)
}

struct TaskLoopResult: Sendable {
    var outcome: TaskOutcome
    var history: [RoundRecord]
    var roundsUsed: Int
    /// Dispatched effects that settled verified — the only honest base
    /// for "Done" speech, same rule DriveResult.dispatchedEffect carries.
    var verifiedEffects: Int
    /// The error that ended the run when one was thrown (an actuation
    /// or propagated observation failure) — callers that must preserve
    /// typed refusal shapes classify on it, never on the reason string.
    var failure: (any Error)? = nil
}

/// The single observe → decide → act → settle loop for computer use.
/// The decider supplies judgment; the loop supplies everything that can
/// touch the world: actuation (stamped with the bound window), the
/// verify_state settle, the round budget, and every ask — consent
/// confirms and decider questions alike — through one seam.
actor TaskLoop {
    struct Config: Sendable {
        var maxRounds: Int? = 4
        var maxNoProgressRounds = 8
        var observedPostActionProgress = false
        /// Wall-clock ceiling alongside the round count; nil disables it.
        var wallBudget: Duration? = nil
        /// Screen-quiet wait each settle pays before re-observing.
        var settleTimeout: Duration = .milliseconds(1200)
        var depth: AXDepth = .standard
        /// Rejected done claims tolerated before the task settles
        /// honest — one correction round, then an unverified-Done block.
        var maxRejectedDone = 1
        /// Both policies require verified, current goal evidence; the
        /// drive lane separately labels verified goals requiring no effect.
        enum DonePolicy: Sendable {
            case verifiedSettle
            case verifiedOrAlreadySatisfied
        }
        var donePolicy: DonePolicy = .verifiedSettle
        /// What an axTree failure does to the round. `.degrade` is the
        /// contract default — the decider sees `axSnapshot == nil` and
        /// escalates honestly. `.propagate` ends the run as an
        /// actuation block carrying the typed error, for callers whose
        /// refusal shapes live on the error's classification.
        enum ObservationFailure: Sendable {
            case degrade
            case propagate
        }
        var observationFailure: ObservationFailure = .degrade
        /// Whether the settle re-observes (settle-wait + fresh tree).
        /// The contract default pays for it; the drive lane's settle is
        /// the driver's own `effect` word, so it re-reads nothing.
        var settleReobserves = true
        static let `default` = Config()
    }

    /// The consent gate's ruling — produced by a seam the caller wires
    /// (M3 binds CuaPolicy's decide/grant path); the decider never sees
    /// or runs it.
    enum ConsentRuling: Sendable {
        case allow
        /// Permanent — carries the block classification the loop settles.
        case deny(BlockedReason)
        /// The gate wants a live confirm. `verdict` receives the
        /// resolved outcome so the ruling producer can persist a scoped
        /// "always" grant — consent stays loop-routed either way.
        case needsConfirm(prompt: String, options: [String],
                          verdict: (@Sendable (DriveLoop.ConsentVerdict) -> Void)?)
    }

    /// What the actuator reports — the effect word rides verbatim so a
    /// driver's "unverifiable"/"suspected_noop" survives to the ledger.
    struct ActOutcome: Sendable, Equatable {
        var effect: String
        var verified: Bool
        var detail: String? = nil
        var dispatched = true
    }

    private let source: any CaptureSource
    private let decider: any Decider
    /// The only path to the world — the loop calls it once per granted
    /// `.tool` request, with the bound window stamped over whatever the
    /// request claimed.
    private let actuate: (ActuationRequest) async throws -> ActOutcome
    private let consent: (ActuationRequest, TaskBrief) async -> ConsentRuling
    /// ONE ask channel — decider `askUser` and consent confirms alike
    /// route through it. Nil means asks go unanswered honestly.
    private let ask: ((String, [String]) async -> String?)?
    private let config: Config
    private let feedOut: (String) -> Void
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis",
                                    category: "task-loop")

    init(source: any CaptureSource, decider: any Decider,
         actuate: @escaping (ActuationRequest) async throws -> ActOutcome,
         consent: @escaping (ActuationRequest, TaskBrief) async -> ConsentRuling,
         ask: ((String, [String]) async -> String?)? = nil,
         config: Config = .default,
         feed: @escaping (String) -> Void = { _ in }) {
        self.source = source; self.decider = decider
        self.actuate = actuate; self.consent = consent; self.ask = ask
        self.config = config; self.feedOut = feed
    }

    private func feed(_ s: String) {
        Self.log.notice("\(s, privacy: .public)")
        feedOut(s)
    }

    func run(_ task: TaskBrief) async -> TaskLoopResult {
        var history: [RoundRecord] = []
        var verifiedSettles = 0   // the gate every done claim must clear
        var verifiedEffects = 0   // dispatched AND verified — the report's done base
        var verifiedGoal: ObservedGoalProof?
        var nativeDocumentAnchor: NativeDocumentSubject?
        var replacementReceipt: NativeReplacementReceipt?
        var pendingDeliveredReplacement: NativeReplacementBinding?
        var deliveredReplacement: DeliveredReplacementObservation?
        var rejectedDone = 0
        var lastFingerprint = ""
        var step = 0
        var idleRounds = 0
        var progressHighWater: [String: Double] = [:]
        let started = ContinuousClock.now
        let deadline = config.wallBudget.map { started + $0 }

        // Captured-window authority: the caller's pin, else the frontmost
        // window right now — bound ONCE, never re-resolved or substituted.
        let window: WindowRef
        do {
            if let pinned = task.window {
                window = pinned
            } else {
                window = try await source.frontmostWindow()
            }
        } catch is CancellationError {
            return finish(.cancelled, history: history, rounds: 0,
                          verifiedEffects: 0)
        } catch {
            return finish(.blocked(.unobservable), history: history, rounds: 0,
                                  verifiedEffects: 0)
        }
        var boundTask = task
        boundTask.window = window

        while config.maxRounds.map({ step < max(0, $0) }) ?? true {
            if Task.isCancelled {
                return finish(.cancelled, history: history, rounds: step,
                              verifiedEffects: verifiedEffects)
            }
            if let deadline, ContinuousClock.now >= deadline {
                return finish(.escalated(.wallBudgetExhausted), history: history,
                              rounds: step, verifiedEffects: verifiedEffects)
            }
            var progressed = false
            defer {
                step += 1
                idleRounds = progressed ? 0 : idleRounds + 1
            }

            func note(_ echo: RoundRecord.Echo, _ summary: String,
                      detail: String? = nil, actuated: Bool = false,
                      settleVerified: Bool = false, stale: Bool = false,
                      askKind: RoundRecord.AskKind? = nil,
                      question: String? = nil, answer: String? = nil) {
                // An unchanged fingerprint on the round after a real
                // dispatch is delivery in flight — the app's repaint/AX
                // propagation can lag the actuator's word — not proof
                // the screen stopped changing. A dispatched round's own
                // mark is excluded for the same reason: it observed the
                // screen before causing its change, so counting it
                // would let pre-dispatch stillness escalate past the
                // delivery it just made.
                let inFlight = history.last?.echo == .act
                    && history.last?.actuated == true
                history.append(RoundRecord(stepIndex: step, echo: echo,
                                           summary: summary, detail: detail,
                                           actuated: actuated,
                                           settleVerified: settleVerified,
                                           staleScreen: stale && !inFlight && !actuated,
                                           askKind: askKind,
                                           askQuestion: question, askAnswer: answer))
            }

            // OBSERVE — one tree per round grounds the round's decision.
            // An observation failure is degraded, not fatal: the decider
            // sees `axSnapshot == nil` and may escalate honestly.
            var snap: AXSnapshot?
            do {
                snap = try await source.axTree(of: window, depth: config.depth)
            } catch is CancellationError {
                return finish(.cancelled, history: history, rounds: step,
                              verifiedEffects: verifiedEffects)
            } catch {
                // Propagate mode keeps the typed error's refusal shape —
                // the settle classifier reads `failure`, not the text.
                if config.observationFailure == .propagate {
                    note(.blocked, "the observation failed",
                         detail: error.localizedDescription)
                    return finish(.blocked(.actuation(
                            "The observation failed: \(error.localizedDescription)")),
                                  history: history, rounds: step,
                                  verifiedEffects: verifiedEffects,
                                  failure: error)
                }
                snap = nil
            }
            if step == 0, let subject = snap?.nativeDocument, subject.window == window {
                nativeDocumentAnchor = subject
            }
            func observation() -> TaskObservation {
                TaskObservation(stepIndex: step, axSnapshot: snap,
                    task: boundTask, history: history, budget: RoundBudget(
                        roundsRemaining: config.maxRounds.map { max(0, $0 - step) },
                        millisecondsRemaining: deadline.map {
                            Self.milliseconds($0 - ContinuousClock.now)
                        }),
                    nativeDocumentAnchor: nativeDocumentAnchor, replacementReceipt: replacementReceipt,
                    deliveredReplacement: deliveredReplacement)
            }
            guard !Task.isCancelled else {
                return finish(.cancelled, history: history, rounds: step,
                              verifiedEffects: verifiedEffects)
            }
            if let pending = pendingDeliveredReplacement {
                pendingDeliveredReplacement = nil
                if step > pending.stepIndex, let snap,
                   pending.freshFact(task: boundTask, snapshot: snap,
                                     original: nativeDocumentAnchor) != nil {
                    deliveredReplacement = DeliveredReplacementObservation(binding: pending)
                }
            }
            if let delivered = deliveredReplacement,
               snap.map({ delivered.binding.freshFact(task: boundTask, snapshot: $0,
                   original: nativeDocumentAnchor) != nil }) != true {
                deliveredReplacement = nil
                verifiedGoal = nil
            }
            let fingerprint = Self.fingerprint(of: snap)
            let stale = fingerprint == lastFingerprint && !history.isEmpty
            if config.observedPostActionProgress, snap != nil,
               !stale, history.last?.echo == .act, history.last?.actuated == true {
                progressed = true
            }
            lastFingerprint = fingerprint
            for element in snap?.elements ?? []
            where element.role.lowercased().contains("progressindicator") {
                guard let text = element.value, let value = Double(text),
                      value.isFinite else { continue }
                let key = "\(element.index):\(element.label)"
                if progressHighWater[key].map({ value > $0 }) ?? true {
                    progressed = true
                    progressHighWater[key] = value
                }
            }
            if idleRounds >= max(1, config.maxNoProgressRounds), !progressed {
                note(.escalate, "No verified progress; stopping repeated empty decisions.")
                return finish(.escalated(.staleScreen), history: history,
                              rounds: step + 1, verifiedEffects: verifiedEffects)
            }
            let currentObservation = observation()

            // DECIDE — a thrown decider blocks; it never becomes a guess.
            let decision: DecideResult
            do {
                decision = try await decider.nextStep(currentObservation)
            } catch is CancellationError {
                return finish(.cancelled, history: history, rounds: step,
                              verifiedEffects: verifiedEffects)
            } catch {
                note(.blocked, "the decider failed", detail: "\(error)")
                return finish(.blocked(.decider(
                        "The decider failed: \(error.localizedDescription)")),
                              history: history, rounds: step + 1,
                                  verifiedEffects: verifiedEffects)
            }
            if Task.isCancelled {
                return finish(.cancelled, history: history, rounds: step,
                              verifiedEffects: verifiedEffects)
            }
            switch decision {
            case .blocked(let reason):
                note(.blocked, "blocked", detail: "\(reason)", stale: stale)
                return finish(.blocked(reason), history: history, rounds: step + 1,
                              verifiedEffects: verifiedEffects)
            case .escalate(let reason):
                note(.escalate, "escalate", detail: reason.rawValue, stale: stale)
                return finish(.escalated(reason), history: history, rounds: step + 1,
                              verifiedEffects: verifiedEffects)
            case .done(let summary):
                // Zero false Done: the claim needs a preceding successful
                // verify_state settle this run. Rejected once, the decider
                // gets a correction round; rejected again, the task blocks.
                guard verifiedSettles > 0,
                      Self.successEvidence(in: snap, task: task)
                        || verifiedGoal?.matches(task: boundTask, snapshot: snap) == true else {
                    rejectedDone += 1
                    note(.rejectedDone, summary,
                         detail: "done claimed without verified current goal evidence",
                         stale: stale)
                    feed("done rejected — verified current goal evidence is missing")
                    guard rejectedDone <= config.maxRejectedDone else {
                        return finish(.blocked(.unverifiedDone), history: history,
                                      rounds: step + 1,
                                      verifiedEffects: verifiedEffects)
                    }
                    continue
                }
                note(.done, summary, stale: stale)
                if config.donePolicy == .verifiedOrAlreadySatisfied,
                   !history.contains(where: \.actuated) {
                    return finish(.alreadySatisfied(reason: summary), history: history,
                                  rounds: step + 1, verifiedEffects: verifiedEffects)
                }
                feed("done — \(summary)")
                return finish(.done(summary: summary), history: history,
                              rounds: step + 1, verifiedEffects: verifiedEffects)
            case .askUser(let question, let choices):
                // Questions route through the loop's one ask seam — the
                // decider never holds the channel; an unanswered ask is
                // recorded honestly for its next observation.
                let answer = await ask?(question, choices)
                progressed = progressed || answer?.isEmpty == false
                note(.ask, question, stale: stale, askKind: .question,
                     question: question, answer: answer)
                continue
            case .act(let request):
                switch request.effect {
                case .reobserve:
                    note(.reobserve, request.summary, stale: stale)
                    continue
                case .verifyState:
                    let verified: Bool
                    if let proof = request.verification {
                        guard !Task.isCancelled else {
                            return finish(.cancelled, history: history, rounds: step,
                                          verifiedEffects: verifiedEffects)
                        }
                        let post = proof.matches(task: boundTask, snapshot: snap, requireOrigin: true)
                            ? try? await source.axTree(of: window, depth: config.depth) : nil
                        guard !Task.isCancelled else {
                            return finish(.cancelled, history: history, rounds: step,
                                          verifiedEffects: verifiedEffects)
                        }
                        let deliveryMatches: Bool
                        if let delivered = deliveredReplacement {
                            deliveryMatches = post.flatMap {
                                delivered.binding.freshFact(task: boundTask, snapshot: $0,
                                                            original: nativeDocumentAnchor)
                            } != nil
                        } else {
                            deliveryMatches = true
                        }
                        verified = proof.matches(task: boundTask, snapshot: post) && deliveryMatches
                        verifiedGoal = verified ? proof : nil
                    } else {
                        verified = await verifyState(window: window, task: task,
                                                     outcome: nil, latest: snap)
                    }
                    progressed = progressed || verified
                    if verified { verifiedSettles += 1 }
                    note(.verify, request.summary, settleVerified: verified,
                         stale: stale)
                    continue
                case .tool:
                    verifiedGoal = nil
                    pendingDeliveredReplacement = nil
                    deliveredReplacement = nil
                    break
                }

                if request.args["capture_id"] != nil {
                    return finish(.blocked(.safety("The visual input does not match the current task, capture, or authorized arguments.")),
                                  history: history, rounds: step + 1,
                                  verifiedEffects: verifiedEffects)
                }

                // ACT — consent first, always the loop's. The task's own
                // deny strings scan before the gate even runs.
                if let elementText = request.elementText,
                   let hit = task.deny.first(where: {
                       elementText.lowercased().contains($0.lowercased()) }) {
                    note(.blocked, request.summary, detail: hit, stale: stale)
                    feed("denied by task rule: \(hit)")
                    return finish(.blocked(.denyList(hit)), history: history,
                                  rounds: step + 1, verifiedEffects: verifiedEffects)
                }
                switch await consent(request, task) {
                case .allow:
                    break
                case .deny(let reason):
                    note(.blocked, request.summary, detail: "\(reason)", stale: stale)
                    feed("denied: \(reason)")
                    return finish(.blocked(reason), history: history,
                                  rounds: step + 1, verifiedEffects: verifiedEffects)
                case .needsConfirm(let prompt, let options, let verdict):
                    guard let ask else {
                        note(.blocked, request.summary, stale: stale)
                        return finish(.blocked(.consent(
                                "The action needs approval and no ask channel answered.")),
                                      history: history, rounds: step + 1,
                                      verifiedEffects: verifiedEffects)
                    }
                    let answer = await ask(prompt, options)
                    let v = DriveLoop.consentVerdict(answer, optionCount: options.count)
                    note(.ask, prompt, stale: stale, askKind: .consent,
                         question: prompt, answer: answer)
                    verdict?(v)
                    guard v != .no else {
                        return finish(.blocked(.consent("The action was not approved.")),
                                      history: history, rounds: step + 1,
                                      verifiedEffects: verifiedEffects)
                    }
                }

                // Captured-window authority stamps the dispatch — a
                // decider request can never redirect the effect at a
                // window the loop didn't bind.
                var stamped = request
                stamped.args["pid"] = .number(Double(window.pid))
                stamped.args["window_id"] = .number(Double(window.windowID))
                let replacement = stamped.replacement.flatMap {
                    $0.authorizes(stamped, observation: observation()) ? $0 : nil
                }
                let delivery = NativeReplacementBinding.make(observation: observation(), request: stamped)
                replacementReceipt = nil
                let outcome: ActOutcome
                do {
                    try Task.checkCancellation()
                    outcome = try await actuate(stamped)
                } catch is CancellationError {
                    return finish(.cancelled, history: history, rounds: step,
                                  verifiedEffects: verifiedEffects)
                } catch {
                    note(.blocked, request.summary,
                         detail: error.localizedDescription, stale: stale)
                    return finish(.blocked(.actuation(
                            "The dispatch failed: \(error.localizedDescription)")),
                                  history: history, rounds: step + 1,
                                  verifiedEffects: verifiedEffects,
                                  failure: error)
                }
                feed("\(request.tool) → \(outcome.effect)")
                if outcome.dispatched, outcome.verified, let replacement {
                    replacementReceipt = NativeReplacementReceipt(proposal: replacement)
                }
                if outcome.dispatched, outcome.verified, !Task.isCancelled,
                   let delivery, delivery.changesValue {
                    pendingDeliveredReplacement = delivery
                }

                // SETTLE — verify_state: the screen quiets, the tree is
                // re-read, and declared success evidence counts toward
                // the verified base next to the actuator's own word.
                let verified = await verifyState(window: window, task: task,
                                                 outcome: outcome, latest: snap)
                progressed = progressed || verified
                if verified {
                    verifiedSettles += 1
                    if outcome.dispatched { verifiedEffects += 1 }
                }
                note(.act, request.summary, detail: outcome.detail,
                     actuated: outcome.dispatched, settleVerified: verified, stale: stale)
                feed("round \(step + 1): \(request.summary)")
            }
        }
        return finish(.escalated(.roundBudgetExhausted), history: history,
                      rounds: step, verifiedEffects: verifiedEffects)
    }

    /// The post-decision state check — the settle a `.done` claim must
    /// be able to point at. A dispatched effect verifies on its own
    /// confirmed word or on observed postcondition evidence — never on
    /// silence. A verify-only request verifies when the declared
    /// evidence is present. Quietness alone never proves completion.
    private func verifyState(window: WindowRef, task: TaskBrief,
                             outcome: ActOutcome?,
                             latest: AXSnapshot? = nil) async -> Bool {
        if !config.settleReobserves {
            // The driver's own effect word is the settle — a tool
            // outcome verifies on it alone; a verify-only request
            // checks the declared evidence on this round's tree.
            if let outcome { return outcome.verified }
            return Self.successEvidence(in: latest, task: task)
        }
        _ = await source.settled(within: config.settleTimeout)
        let post = try? await source.axTree(of: window, depth: config.depth)
        let evidence = Self.successEvidence(in: post, task: task)
        if let outcome { return outcome.verified || evidence }
        return evidence
    }

    /// Available controls are not outcomes. Prefer structured observed
    /// values and read-only text over a rendered tree containing buttons.
    static func successEvidence(in snap: AXSnapshot?, task: TaskBrief) -> Bool {
        guard let snap, !task.successContains.isEmpty else { return false }
        let evidence: [String]
        if snap.elements.isEmpty {
            evidence = [snap.treeMarkdown.lowercased()]
        } else {
            evidence = ObservedGoalProof.facts(in: snap).map { $0.content.lowercased() }
        }
        return task.successContains.contains {
            let expected = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !expected.isEmpty && evidence.contains { $0.contains(expected) }
        }
    }

    /// The stale-screen signal — the loop's fingerprint rides
    /// DriveLoop's own so a TaskLoop observation reads identical to the
    /// loop it replaces.
    static func fingerprint(of snap: AXSnapshot?) -> String {
        guard let snap else { return "degraded" }
        let elements = snap.elements.map { e in
            DriveLoop.Element(index: e.index, token: e.token, role: e.role,
                              label: e.label, value: e.value,
                              frame: e.frame.map {
                                  (x: $0.origin.x, y: $0.origin.y,
                                   w: $0.size.width, h: $0.size.height)
                              } ?? (x: 0, y: 0, w: 0, h: 0),
                              actions: e.actions)
        }
        return DriveLoop.fingerprint(of: elements, title: snap.windowTitle)
    }

    private static func milliseconds(_ d: Duration) -> Int {
        Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    private func finish(_ outcome: TaskOutcome, history: [RoundRecord],
                        rounds: Int, verifiedEffects: Int,
                        failure: (any Error)? = nil) -> TaskLoopResult {
        Self.log.notice("settle \(String(describing: outcome), privacy: .public) rounds=\(rounds) effects=\(verifiedEffects)")
        return TaskLoopResult(outcome: outcome, history: history,
                              roundsUsed: rounds, verifiedEffects: verifiedEffects,
                              failure: failure)
    }
}
