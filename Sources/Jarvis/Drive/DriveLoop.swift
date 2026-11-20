import AppKit
import Foundation
import JarvisCore
import os

/// The single observe → choose → dispatch loop for computer use.
///
/// Contract (per `action-selection-policy.mdx`): one `get_window_state` per
/// round grounds everything; element actions address the fresh snapshot by
/// `element_token`/`element_index+snapshot_id`; results are trusted from
/// the driver's `effect`/`verified`/`escalation` fields, never assumed.
/// Jev only *selects* among bounded candidates — literal user text is
/// never rewritten by a model.
actor DriveLoop {
    /// What the loop can need from a human mid-task.
    enum Ask: Equatable {
        /// Yes/no gate — resolve true to dispatch the effect anyway.
        case confirm(String)
        /// Free-text hole in the task (text to type, which window).
        case question(String)
        /// Pick one of N options — the micro-radial's voice/dwell path.
        /// The answer resolves to an option index (spoken ordinal/number
        /// or dwell); the coordinator maps "two"/"the second one"/"2".
        case choice(prompt: String, options: [String])
    }

    /// The chooser's answer: the picked candidate id plus the model's own
    /// confidence (nil = no score — treated as ungated so stub choosers and
    /// non-scoring lanes keep working). `doneVote` carries the same-call
    /// noul judgment — "is the goal already visibly complete?" — so the
    /// second question rides the one RTT the chooser already pays.
    struct JevChoice: Sendable, Equatable {
        enum ActionRejection: String, Sendable {
            case selection, support, applicability, operation
        }
        var id: String
        var confidence: Double?
        var doneVote: Bool?
        var probabilities: [String: Double] = [:]
        var applicability: Double? = nil
        var completionProbability: Double? = nil
        var model: String? = nil
        var latencyMs: Double? = nil
        var requestCount = 1
        var proposedActionID: String? = nil
        var actionSupport: [String: Double] = [:]
        var actionRejection: ActionRejection? = nil
        var goalFactID: String? = nil
        var goalFactProbability: Double? = nil
        var goalFactSupport: Double? = nil
        var primaryCompletionProbability: Double? = nil
        var refinedCompletionProbability: Double? = nil
        var replacementVotes: NativeReplacementVotes? = nil
    }

    typealias Call = (String, [String: JSONValue]) async throws -> JSONValue
    /// Pick one candidate; nil = unusable answer (bounded retry then stuck).
    typealias Choose = (JSONValue, [(id: String, description: String)]) async throws -> JevChoice?
    typealias AskFn = (Ask) async -> String?

    struct Config: Sendable {
        var maxRounds: Int? = nil
        /// Element-derived candidates are score-ordered; the judgment
        /// model's context bounds the pick payload, so keep the 24 most
        /// goal-relevant rows. Reserved picks (scroll, keys, done…) are
        /// appended after the cap and are never cut by it.
        var elementCap: Int? = 24
        var browserRefCap: Int? = nil
        var maxInvalidChoices = 2
        var maxStaleRounds = 3
        var windowOnly = false
        var allowParsedScroll = true
        static let `default` = Config()
    }

    struct Element: Sendable {
        var index: Int
        var token: String?
        var role: String
        var label: String
        var value: String?
        var frame: (x: Double, y: Double, w: Double, h: Double)
        var actions: [String]
    }

    /// Pinned macOS Cua AX frames are global top-left points, not image pixels.
    static func nativeAXScreenRect(_ element: Element) -> CGRect? {
        let f = element.frame
        guard f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
              f.w > 0, f.h > 0, (f.x + f.w).isFinite, (f.y + f.h).isFinite,
              (f.w * f.h).isFinite else { return nil }
        return CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
    }

    /// Policy refusals end the task, not the transport — carried as an
    /// error so the round loop unwinds cleanly to `.refused`.
    enum Abort: Error {
        /// A permanent refusal — protected list, denied tool, or the
        /// task's own deny rule. No grant or approval reverses it.
        case denied(String)
        /// A live confirm card ran and the user declined.
        case declined
        /// No standing grant and no ask channel — the only block the
        /// settings toggle fixes.
        case missingGrant
        /// The driver refused the dispatch — an admission failure, not a
        /// consent outcome.
        case refused(String)
    }

    /// The driver rejected an element dispatch because the snapshot's
    /// tokens went stale — the one refusal class whose remedy is a
    /// re-observe and a retry by element IDENTITY, never the dead token
    /// or a positional guess. Kept out of `Abort` so it can't settle a
    /// task; the `.tool` dispatch site catches it, relocates, and throws
    /// `Abort.refused` only when the element is gone or still stale.
    struct StaleElementToken: Error {}

    let call: Call
    let callOnce: Call
    /// Read-only sibling of `call` — present only when the caller wired a
    /// second transport. Every element of `CuaConnection.readOnlyTools`
    /// this loop issues (list_apps/list_windows/get_window_state/
    /// clipboard_read/get_browser_state) routes
    /// through `observe` so an in-flight mutation can't starve them.
    private let callRead: Call?
    /// Reads stay serialized on `call` when no read lane exists — same
    /// behavior the loop always had; nothing about the contract changes.
    func observe(_ tool: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        if let callRead { return try await callRead(tool, args) }
        return try await call(tool, args)
    }
    private let choose: Choose
    private let resurrector: SessionResurrector
    /// On-device chooser — answers a round before the hosted `choose`;
    /// nil/unusable falls through. The pick's evidence gates apply
    /// identically whichever engine answered.
    /// The cursorless direct-action session — fast-lane dispatches ride
    /// it when set (voice path); nil keeps the caller's `session`.
    private let directSession: String?
    var requiresCapturedTextTarget: Bool { explicitConsent && directSession != nil }
    /// Dictation-mode verbs hand their bool here — the coordinator wires
    /// it to VoiceController's literal-capture lane.
    /// Internal (not private): `FastLaneExecutor`'s extension lives in its
    /// own file.
    let onDictationRequest: ((Bool) async -> Bool)?
    /// The bound target's identity — set once the loop knows which app
    /// it's touching (post-bind in `run`, post-resolution in the fast
    /// lane) so a consent ask can offer "Always for <app>" and a yes
    /// lands as a (tool, bundle) scoped grant, never a blanket one.
    var consentAppName: String?
    /// The person's own words for the running task ("send it", "delete
    /// that email"). A consequential press they name goes ahead with a
    /// glow; any other asks first. Nil when the goal is model-authored
    /// (`explicitConsent` off).
    private(set) var spokenGoal: String?
    /// Control phrases the words already pressed once this task: "click
    /// Send" covers one Send, and a second one asks.
    private var spentCoverage: Set<String> = []
    /// The press this task made without asking because the app can take
    /// it back. One per task: a later consequential press asks again.
    private var pendingUndo: PendingUndo?
    /// Set once this task presses without asking, whether or not the app
    /// then showed an undo to offer, so a press that left no offer can't
    /// open the door to another unasked one.
    private var unaskedPressSpent = false
    let undo: UndoSupport
    var consentAppBundleID: String?
    let ask: AskFn?
    let granted: () -> Bool
    /// Whose words the `DriveTask.goal` is. When true (the voice path)
    /// the goal is the user's own spoken command — the deterministic
    /// fast lane's named verbs are user-explicit actions whose consent
    /// IS the utterance, so they need only the deny-list scan, never
    /// the standing grant. When false — an agent's `drive_until`, where
    /// the goal is model-authored text — the same dispatches are
    /// autonomous effects and ride `CuaPolicy.decide`'s grant/confirm
    /// path like every other model-picked mutation.
    let explicitConsent: Bool
    let resolver: AppResolver
    private let config: Config
    /// Serializes activation-prone calls (raise, host-side activate, menu
    /// focus) so parallel tasks can't interleave a raise with another
    /// task's verify.
    let focusLease: AsyncLease?
    let focusedTextTarget: @Sendable (Int, Int) async -> FocusedTextBinding?
    let nativeFocusedWindowID: @Sendable (Int) async -> Int?
    let nativeForegroundWindow: @Sendable (Int) async -> Int?
    let nativeEvent: @Sendable (VoiceCommandTrace.Stage) async -> Void
    let nativeTextEvent: @Sendable (FocusedTextBinding.Insertion) async -> Void
    /// System-key post — injectable so tests never touch the real HID tap.
    let postMediaKey: (MediaKeys.Key) -> Bool
    /// Host-side app activation — the reopen trigger the driver won't do.
    /// Injectable so tests never activate real processes.
    let activateApp: (Int) -> Void
    /// Window restoration for an explicitly requested raise. Kept separate
    /// from activation: activate() alone does not unhide a running app.
    let appIsHidden: (Int) -> Bool
    let unhideApp: (Int) -> Bool
    /// A normal OS reopen can restore a closed main window; activate() alone
    /// only fronts existing windows. Pinned-window requests never use this.
    let activateRestoredApp: (Int, String?) -> Void
    let foregroundAppLauncher: ((String) async throws -> Int)?
    let observeLaunchedPID: (String) async -> Int?
    /// The freshest eye-tracker sample — injected so tests serve canned
    /// points and agent contexts can leave it nil (a nil seam reads to the
    /// caller as "tracker unreachable": gaze referents refuse honestly).
    let gaze: (() async throws -> GazeSample)?
    /// The scorer's committed referent — the semantic answer to "what is
    /// 'this'". Nil seam or nil answer = cold feed; gaze verbs fall back
    /// to the raw point exactly as before.
    let gazeCommit: (() async -> (IntentCandidate, Double)?)?
    /// Traffic-light discovery — host-side AX on the app's front window.
    /// Injectable so tests never open a real AX session.
    let windowControlButtons: (pid_t) -> [WindowControls.Button]
    /// Traffic-light press — background-safe AXPress, same seam.
    let windowControlPress: (WindowControls.Kind, pid_t) -> Bool
    let windowControlButtonsInWindow: (pid_t, Int) -> [WindowControls.Button]
    let windowControlPressInWindow: (WindowControls.Kind, pid_t, Int) -> Bool
    /// Minimized, full-screen, raise and Stage Manager reads and writes for
    /// the lost-window and exit-full-screen lanes — same seam posture.
    let windowAttributes: WindowControls.Attributes
    /// Mission Control's tree, the desktop-change notification, SkyLight's
    /// read-only Spaces layout and the ⌃←/⌃→ preference — same seam posture.
    let desktopSpaces: DesktopSpaceSwitch.System
    private let nativeReadOnly: NativeWindowObservation.Read
    let nativeScrollRead: NativeWindowObservation.ScrollRead
    let nativeScrollControl: NativeWindowObservation.ScrollControl
    let scrollContinuation: NativeWindowObservation.ScrollViewport?
    let freshScrollContinuation: Bool
    let scrollContinuationIsCurrent: (@Sendable () async -> Bool)?
    let onVerifiedScroll: (@Sendable (NativeWindowObservation.VerifiedScroll) async -> Void)?
    /// App-side overlay seam for `.overlay` verbs — numbered chips and
    /// radial picks resolve against TargetOverlay on the main actor.
    /// Receives the verb, the resolved target frames (top-left screen
    /// points) with labels, and the current gaze point. A nil seam (agent
    /// contexts, headless runs) makes overlay verbs refuse honestly.
    let overlayDispatch: ((FastAction.OverlayVerb,
                           [(frame: CGRect, label: String)],
                           CGPoint?) async -> DriveResult?)?
    /// The frontmost non-self app's bundle — injectable so fast-lane
    /// resolution in tests doesn't read the real workspace roster.
    let frontmostBundleID: () -> String?
    /// Independent AppKit PID readback for uncertain foreground effects.
    /// Injectable so tests never need to steal the real desktop's focus.
    let frontmostPID: () -> Int?
    let frontmostWindowID: () -> Int?
    private let feedOut: (String) -> Void
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis",
                                    category: "drive-loop")

    /// Dead-session recovery budget per call: revive-then-retry, then
    /// rotate-then-retry — three dispatches at most, never a loop.
    static let maxResurrections = 2
    /// The one say a session-death settle ever produces — the daemon
    /// tombstoned the label mid-task. Never raw driver text.
    static let sessionRestartedMessage = "The computer-control connection restarted — try that again."
    /// Marker `blockedReason` for that settle: provably nothing
    /// dispatched (the daemon rejected admission), so it's the one
    /// block class the coordinator may auto-retry as a whole task.
    static let sessionRestartedReason = "session restarted"

    /// Every drive step is observable — the UI feed and OSLog carry the
    /// same ledger so a failed session leaves a trace. `.notice`, not
    /// `.info`: info-level entries live only in the memory ring buffer and
    /// AppKit's per-second window churn evicts them within minutes —
    /// postmortems need these on disk.
    func feed(_ s: String) {
        Self.log.notice("\(s, privacy: .public)")
        feedOut(s)
    }

    init(call: @escaping Call, choose: @escaping Choose,
         ask: AskFn?, granted: @escaping () -> Bool,
         explicitConsent: Bool = true,
         /// Read-only observation lane — the coordinator routes it over a
         /// second transport so an in-flight mutation can't starve the
         /// next observe (the coordinator enforces read-only before the
         /// wire). Nil keeps every read on `call` — the serialized
         /// behavior tests and agent loops already have.
         callRead: Call? = nil,
         /// The session label direct (single deterministic dispatch)
         /// fast-lane work runs under — the coordinator supplies
         /// "voice-direct" so its transport can suppress the agent
         /// cursor on it; model-driven rounds keep `session`. Nil
         /// (agents, tests) keeps the caller's session for both.
         directSession: String? = nil,
         /// The dictation-mode verbs' hand-off — true latches the
         /// literal-capture lane, false ends it. Nil reports the feature
         /// as unavailable instead of claiming a toggle nothing honored.
         onDictationRequest: ((Bool) async -> Bool)? = nil,
         resolver: AppResolver = AppResolver(),
         config: Config = .default,
         focusLease: AsyncLease? = nil,
         focusedTextTarget: @escaping @Sendable (Int, Int) async -> FocusedTextBinding? = {
             await FocusedTextBinding.capture(pid: $0, windowID: $1)
         },
         nativeFocusedWindowID: @escaping @Sendable (Int) async -> Int? = {
             await FocusedTextBinding.focusedWindowID(pid: $0)
         },
         nativeForegroundWindow: @escaping @Sendable (Int) async -> Int? = {
             await DriveLoop.observeForegroundWindow(pid: $0)
         },
         nativeEvent: @escaping @Sendable (VoiceCommandTrace.Stage) async -> Void = { _ in },
         nativeTextEvent: @escaping @Sendable (FocusedTextBinding.Insertion) async -> Void = { _ in },
         postMediaKey: @escaping (MediaKeys.Key) -> Bool = { MediaKeys.post($0) },
         activateApp: @escaping (Int) -> Void = { pid in
             _ = NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: [])
         },
         appIsHidden: @escaping (Int) -> Bool = { pid in
             NSRunningApplication(processIdentifier: pid_t(pid))?.isHidden == true
         },
         unhideApp: @escaping (Int) -> Bool = { pid in
             NSRunningApplication(processIdentifier: pid_t(pid))?.unhide() == true
         },
         activateRestoredApp: @escaping (Int, String?) -> Void = { pid, expectedBundle in
             guard let expectedBundle,
                   let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                   app.bundleIdentifier == expectedBundle, let url = app.bundleURL else { return }
             let configuration = NSWorkspace.OpenConfiguration()
             configuration.activates = true
             configuration.createsNewApplicationInstance = false
             NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
         },
         foregroundAppLauncher: ((String) async throws -> Int)? = nil,
         observeLaunchedPID: @escaping (String) async -> Int? = { await DriveLoop.observedPID(bundle: $0) },
         gaze: (() async throws -> GazeSample)? = nil,
         gazeCommit: (() async -> (IntentCandidate, Double)?)? = nil,
         windowControlButtons: ((pid_t) -> [WindowControls.Button])? = nil,
         windowControlPress: ((WindowControls.Kind, pid_t) -> Bool)? = nil,
         windowControlButtonsInWindow: ((pid_t, Int) -> [WindowControls.Button])? = nil,
         windowControlPressInWindow: ((WindowControls.Kind, pid_t, Int) -> Bool)? = nil,
         windowAttributes: WindowControls.Attributes = .live,
         desktopSpaces: DesktopSpaceSwitch.System = .live,
         undo: UndoSupport = .live,
         overlayDispatch: ((FastAction.OverlayVerb,
                            [(frame: CGRect, label: String)],
                            CGPoint?) async -> DriveResult?)? = nil,
         frontmostBundleID: @escaping () -> String? = {
             NSWorkspace.shared.frontmostApplication.flatMap {
                 $0.bundleIdentifier != Bundle.main.bundleIdentifier
                     ? $0.bundleIdentifier : nil
             }
         },
         frontmostPID: @escaping () -> Int? = {
             NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) }
         },
         frontmostWindowID: @escaping () -> Int? = {
             let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]]
             let front = rows?.first { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
             return (front?[kCGWindowNumber as String] as? NSNumber)?.intValue
         },
         resurrector: SessionResurrector = .shared,
         nativeReadOnly: @escaping NativeWindowObservation.Read = NativeWindowObservation.live,
         nativeScrollRead: @escaping NativeWindowObservation.ScrollRead = NativeWindowObservation.liveScroll,
         nativeScrollControl: @escaping NativeWindowObservation.ScrollControl = NativeWindowObservation.liveScrollControl,
         scrollContinuation: NativeWindowObservation.ScrollViewport? = nil,
         freshScrollContinuation: Bool = false,
         scrollContinuationIsCurrent: (@Sendable () async -> Bool)? = nil,
         onVerifiedScroll: (@Sendable (NativeWindowObservation.VerifiedScroll) async -> Void)? = nil,
         feed: @escaping (String) -> Void = { _ in }) {
        // Session resurrection, serialized per label (see
        // SessionResurrector): the daemon tombstones a session when its
        // owner transport dies or it sits past the idle TTL, and only the
        // ORIGINAL owner may `start_session` it — a replaced proxy gets
        // "session is not available to this transport". One waiter runs
        // the start while the rest share its outcome; a refused revival
        // rotates the label (the daemon's own "use a new session label"
        // remedy) so later calls mint a live successor instead of
        // racing a second start on a dead-owner tombstone. The retry
        // itself is the verification — a start that "succeeded" but left
        // the session dead surfaces as a refusal on the re-dispatch.
        self.callOnce = { tool, args in
            try Task.checkCancellation()
            var args = args
            if case .string(let label) = args["session"] {
                args["session"] = .string(await resurrector.effectiveLabel(label))
            }
            return try await call(tool, args)
        }
        self.call = { tool, args in
            var args = args
            // Rotated labels dispatch as their live successor — callers
            // keep asking for "voice" and never learn it moved.
            if case .string(let label) = args["session"] {
                args["session"] = .string(await resurrector.effectiveLabel(label))
            }
            var resurrections = 0
            while true {
                do {
                    return try await call(tool, args)
                } catch let error as DriverConnectionError {
                    resurrections += 1
                    guard resurrections <= Self.maxResurrections,
                          tool != "start_session", tool != "end_session",
                          case .string(let label) = args["session"],
                          error.isDeadSession else {
                        // Out of budget on a dead label — the caller gets
                        // the human line, never raw daemon text.
                        if error.isDeadSession {
                            throw DriverConnectionError.refused(Self.sessionRestartedMessage)
                        }
                        throw error
                    }
                    Self.log.notice("session '\(label, privacy: .public)' ended — restarting it")
                    switch await resurrector.restart(label, start: { target in
                        do {
                            _ = try await call("start_session",
                                               ["session": .string(target)])
                            return .live
                        } catch let error as DriverConnectionError {
                            return error.isDaemonRefusal ? .refused : .unreachable
                        } catch {
                            return .unreachable
                        }
                    }) {
                    case .live:
                        continue        // retry on the revived label
                    case .refused:
                        // The tombstone binds `label` to a dead transport
                        // — dispatch the successor it tells us to use.
                        args["session"] = .string(await resurrector.rotate(label))
                        continue
                    case .unreachable:
                        // The restart never reached the daemon — surface
                        // the real transport failure, not a fake revive.
                        throw error
                    }
                }
            }
        }
        self.choose = choose; self.ask = ask
        self.resurrector = resurrector
        self.nativeReadOnly = nativeReadOnly
        self.nativeScrollRead = nativeScrollRead
        self.nativeScrollControl = nativeScrollControl
        self.scrollContinuation = scrollContinuation
        self.freshScrollContinuation = freshScrollContinuation
        self.scrollContinuationIsCurrent = scrollContinuationIsCurrent
        self.onVerifiedScroll = onVerifiedScroll
        self.granted = granted; self.explicitConsent = explicitConsent
        self.directSession = directSession
        self.onDictationRequest = onDictationRequest
        // The read lane gets the same rotated-label rewrite `call` got
        // above — a resurrector-minted successor is invisible to callers
        // either way. Dead-session resurrection stays on the primary
        // wrapper: a failed read surfaces to the round, which re-observes
        // on the next pass rather than replaying an admission sequence.
        self.callRead = callRead.map { lane in
            { tool, args in
                var args = args
                if case .string(let label) = args["session"] {
                    args["session"] = .string(await resurrector.effectiveLabel(label))
                }
                return try await lane(tool, args)
            }
        }
        self.resolver = resolver
        self.config = config; self.focusLease = focusLease
        self.focusedTextTarget = focusedTextTarget
        self.nativeFocusedWindowID = nativeFocusedWindowID
        self.nativeForegroundWindow = nativeForegroundWindow
        self.nativeEvent = nativeEvent
        self.nativeTextEvent = nativeTextEvent
        self.postMediaKey = postMediaKey
        self.activateApp = activateApp
        self.appIsHidden = appIsHidden
        self.unhideApp = unhideApp
        self.activateRestoredApp = activateRestoredApp
        self.foregroundAppLauncher = foregroundAppLauncher
        self.observeLaunchedPID = observeLaunchedPID
        self.gaze = gaze
        self.gazeCommit = gazeCommit
        self.windowControlButtons = windowControlButtons ?? { WindowControls.buttons(pid: $0) }
        self.windowControlPress = windowControlPress ?? { WindowControls.press($0, pid: $1) }
        self.windowControlButtonsInWindow = windowControlButtonsInWindow ?? { pid, windowID in
            windowControlButtons?(pid) ?? WindowControls.buttons(pid: pid, windowID: windowID)
        }
        self.windowControlPressInWindow = windowControlPressInWindow ?? { kind, pid, windowID in
            windowControlPress?(kind, pid) ?? WindowControls.press(kind, pid: pid, windowID: windowID)
        }
        self.windowAttributes = windowAttributes
        self.desktopSpaces = desktopSpaces
        self.overlayDispatch = overlayDispatch
        self.undo = undo
        self.frontmostBundleID = frontmostBundleID
        self.frontmostPID = frontmostPID
        self.frontmostWindowID = frontmostWindowID
        self.feedOut = feed
    }

    // MARK: - Run

    static func verifiedForegroundWindowID(pid: Int, frontmost: Int?, focused: Int?,
                                           rows: [[String: Any]]) -> Int? {
        guard pid > 0, frontmost == pid, let focused, focused > 0,
              let row = rows.first(where: {
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                      && $0[kCGWindowIsOnscreen as String] as? Bool == true
              }),
              (row[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid,
              (row[kCGWindowNumber as String] as? NSNumber)?.intValue == focused else { return nil }
        return focused
    }

    @MainActor
    static func observeForegroundWindow(
        pid: Int,
        frontmost: @MainActor () -> Int? = {
            NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) }
        },
        focusedWindow: @MainActor (Int) -> Int? = { FocusedTextBinding.capturedWindowID(pid: $0) },
        windows: @MainActor () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                      kCGNullWindowID) as? [[String: Any]] ?? []
        }
    ) -> Int? {
        guard pid > 0, frontmost() == pid,
              let first = windows().first(where: {
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
                      && $0[kCGWindowIsOnscreen as String] as? Bool == true
              }),
              (first[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid else { return nil }
        let focused = focusedWindow(pid)
        let rows = windows()
        guard let verified = verifiedForegroundWindowID(pid: pid,
            frontmost: frontmost(),
            focused: focused, rows: rows),
              frontmost() == pid,
              focusedWindow(pid) == verified else { return nil }
        return verified
    }

    static func permitsPinnedScroll(_ resolved: FastResolution, task: DriveTask) -> Bool {
        guard let window = task.windowID, window > 0, task.scope == .work,
              task.application != nil, task.values.isEmpty, task.successContains.isEmpty,
              task.previousContext?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              resolved.openVerb == nil, resolved.launchURLs.isEmpty, !resolved.displayScoped,
              let action = resolved.action, !action.deictic,
              case .scroll(_, let pages) = action.body, pages == 1 else { return false }
        return true
    }

    func runWindowScroll(_ request: WindowScrollRequest, task: DriveTask, session: String) async -> DriveResult {
        var history: [String] = []
        do {
            try Task.checkCancellation()
            guard request.matches(task) else {
                return settle(.blocked("The scrolling request or target changed."),
                              task, history, blockedReason: "scroll request changed")
            }
            let candidates = await resolveTaskApplication(task)
            guard let app = try await resolveTargetApp(candidates, task: task, session: session),
                  app.bundle == request.application, let pid = task.pid ?? app.pid, pid > 0 else {
                return settle(.blocked("The captured application's window is unavailable."),
                              task, history, blockedReason: "pinned app mismatch")
            }
            let action = FastAction(body: .scroll(direction: request.direction, pages: 1), generic: true,
                description: "Scrolling \(request.direction)", result: "Scrolled \(request.direction)",
                effect: .delivered)
            let resolved = FastResolution(action: action, openVerb: nil, name: app.name,
                                          bundle: request.application, pid: pid)
            var confirmed = false
            try Task.checkCancellation()
            return try await runFastLane(resolved, task: task, session: session,
                history: &history, confirmed: &confirmed, scrollLines: request.lines,
                scrollAnchor: request.continuation)
                ?? settle(.blocked("The scroll could not be verified."), task, history)
        } catch is CancellationError {
            return settle(.cancelled, task, history)
        } catch let abort as Abort {
            switch abort {
            case .denied(let why):
                return settle(.blockedByConsent(why), task, history,
                              blockedReason: why, consentBlock: .permanent)
            case .declined:
                return settle(.blockedByConsent("The scroll was not approved."), task, history,
                              consentBlock: .declined)
            case .missingGrant:
                return settle(.blockedByConsent("Computer use needs the standing grant."), task, history,
                              consentBlock: .missingGrant)
            case .refused(let why):
                return settle(.blocked(why), task, history, blockedReason: why)
            }
        } catch {
            return settle(.blocked("The scroll could not be verified: \(error.localizedDescription)"),
                          task, history, blockedReason: "scroll unverified")
        }
    }

    /// Typed semantic handler: never reparse a model/user/display string into
    /// a primitive or fall through to the generic chooser.
    func runAppFocus(bundleID: String, task: DriveTask, session: String,
                     nativeEvents: (@Sendable (VoiceCommandTrace.Stage) async -> Void)? = nil) async -> DriveResult {
        var history: [String] = []
        do {
            try Task.checkCancellation()
            guard task.application == bundleID, task.scope == .open, task.foreground,
                  task.values.isEmpty, task.windowID == nil, task.windowName == nil,
                  let app = await resolver.resolve(bundleID), app.bundle == bundleID,
                  !bundleID.isEmpty else {
                return settle(.blocked("The confirmed application is unavailable or changed."),
                              task, history, blockedReason: "semantic target changed")
            }
            var resolved = FastResolution(action: nil, openVerb: "show", name: app.name, bundle: bundleID)
            resolved.pid = app.pid
            var confirmed = true
            try Task.checkCancellation()
            return try await runFastLane(resolved, task: task, session: session,
                                         history: &history, confirmed: &confirmed,
                                         nativeEvents: nativeEvents)
                ?? settle(.blocked("Confirmed app focus is unavailable."), task, history)
        } catch is CancellationError {
            return settle(.cancelled, task, history)
        } catch let abort as Abort {
            if case .denied(let why) = abort {
                return settle(.blockedByConsent(why), task, history, blockedReason: why, consentBlock: .permanent)
            }
            return settle(.blocked("Confirmed app focus was refused."), task, history)
        } catch {
            return settle(.blocked("The confirmed app focus could not be verified. Nothing was retried."),
                          task, history, blockedReason: "semantic focus unverified")
        }
    }

    func run(_ task: DriveTask, session: String) async -> DriveResult {
        var history: [String] = []
        /// A per-task approval granted this run — one `ask` covers every
        /// later consent prompt, including the bind-phase launch gate.
        var confirmedTask = false
        bindSpokenGoal(explicitConsent ? task.goal : nil)
        func step(_ s: String) { feed(s); history.append(s) }
        if explicitConsent, Self.asksToUndo(task.goal), let pending = undo.offers.take(now: undo.now()) {
            return await runOfferedUndo(pending, task: task, session: directSession ?? session)
        }

        do {
            if config.windowOnly, task.windowID == nil {
                return settle(.blocked("An exact target window is required."), task, history)
            }
            let directLiteral: Bool
            if requiresCapturedTextTarget, let parsed = FastAction.parse(task.goal),
               parsed.appQualifier == nil, !Self.pointsByGaze(parsed.action), case .type = parsed.action.body {
                directLiteral = true
                guard task.windowID != nil, task.application != nil,
                      task.values["text"] != nil else {
                    return settle(.blocked("Focus a text field before asking me to type. No text was sent."),
                                  task, history, blockedReason: "captured typing target unavailable")
                }
            } else { directLiteral = false }
            // 0. Fast lane — a deterministic verb (open/raise, hide, quit,
            //    new tab, media keys, engine search, scroll, type) needs no
            //    model call; it dispatches once and verifies its effect
            //    from live state. The app inventory it may consult and the
            //    local resolver the bind below needs are INDEPENDENT reads —
            //    overlap them. The inventory is skipped entirely when the
            //    goal can only take an app-free lane (a gaze referent,
            //    tracker control, a media/system chord, an overlay verb,
            //    dictation, a URL/web lane): a spoken "click" never pays
            //    for a list_apps roundtrip it can't consume.
            let needsInventory = Self.fastLaneNeedsInventory(goal: task.goal,
                                                             appHint: task.application)
            async let resolvedApps = resolveTaskApplication(task)
            let apps: [JSONValue]
            if needsInventory, let requested = task.application,
               let bound = (await resolvedApps).app, bound.bundle == requested {
                // A canonical app identity already proved by AppResolver does
                // not need a global scan for open/raise, an exact bound literal,
                // or an unqualified window chord on that same frontmost app.
                var row: [String: JSONValue] = [
                    "name": .string(bound.name), "bundle_id": .string(requested)
                ]
                if let pid = bound.pid { row["pid"] = .number(Double(pid)) }
                let local = Self.resolveFastLane(goal: task.goal, apps: [.object(row)],
                    appHint: task.application, frontmostBundle: frontmostBundleID())
                let boundLiteral: Bool
                if let parsed = FastAction.parse(task.goal), parsed.appQualifier == nil,
                   !Self.pointsByGaze(parsed.action), case .type(let text) = parsed.action.body,
                   task.values["text"] == text, local?.bundle == requested,
                   case .type(let localText)? = local?.action?.body, localText == text {
                    boundLiteral = true
                } else { boundLiteral = false }
                let boundHotkey: Bool
                if let parsed = FastAction.parse(task.goal), parsed.appQualifier == nil,
                   !Self.pointsByGaze(parsed.action), case .hotkey(let keys, _) = parsed.action.body,
                   local?.bundle == requested, frontmostBundleID() == requested,
                   case .hotkey(let localKeys, _)? = local?.action?.body, localKeys == keys {
                    boundHotkey = true
                } else { boundHotkey = false }
                let boundScroll = local.map { Self.permitsPinnedScroll($0, task: task) } ?? false
                apps = local?.openVerb != nil || boundLiteral || boundHotkey || boundScroll
                    ? [.object(row)] : await appInventory(session: session)
            } else {
                apps = needsInventory ? await appInventory(session: session) : []
            }
            let frontmost = frontmostBundleID()
            if var fast = Self.resolveFastLane(goal: task.goal, apps: apps,
                                               appHint: task.application,
                                               frontmostBundle: frontmost),
               config.allowParsedScroll || !fast.isScroll,
               !config.windowOnly || Self.permitsPinnedScroll(fast, task: task) {
                if task.windowID != nil, !fast.bundle.isEmpty {
                    guard let bound = try await resolveTargetApp(await resolvedApps, task: task, session: session),
                          bound.bundle?.caseInsensitiveCompare(fast.bundle) == .orderedSame else {
                        return settle(.blocked("The action does not match the pinned app. No other app was substituted."),
                                      task, history, blockedReason: "pinned app mismatch")
                    }
                    fast.pid = task.pid ?? bound.pid
                }
                if task.application != nil, fast.openVerb != nil {
                    guard let expected = (await resolvedApps).app, let bundle = expected.bundle,
                          !bundle.isEmpty, fast.bundle == bundle else {
                        return settle(.blocked("The bound app is unavailable or changed. No other app was substituted."),
                                      task, history, blockedReason: "app identity changed")
                    }
                }
                // Direct user actions ride the cursorless session when
                // the caller distinguished one — every call inside the
                // lane shares it so element tokens mint and redeem under
                // the same label. Model rounds below keep `session`.
                if let result = try await runFastLane(fast, task: task,
                                                      session: directSession ?? session,
                                                      history: &history,
                                                      confirmed: &confirmedTask) {
                    return result
                }
            }
            if directLiteral {
                return settle(.blocked("The captured typing target is unavailable. No text was sent."),
                              task, history, blockedReason: "captured typing target unavailable")
            }

            // 1. Bind the app.
            var pid = task.pid
            var appName = task.application ?? ""
            var bundleID: String?
            var launchWindows: [JSONValue] = []
            if pid == nil {
                let resolved = try await resolveTargetApp(await resolvedApps, task: task, session: session)
                // A deictic/appearance goal points at the screen, not a
                // process. Two signals say so: the goal is a known deictic
                // phrase, or the resolver could only echo the utterance
                // back (bare `App(name: query)` — no bundle, no pid).
                // Launching a process named "this button" would be
                // nonsense the driver can only refuse; bind whatever is
                // in front instead.
                let deictic = task.application == nil
                    && (Self.isDeicticGoal(task.goal)
                        || (resolved.map { $0.bundle == nil && $0.pid == nil } ?? true))
                if deictic {
                    if let front = frontmostBundleID(),
                       let foregroundPID = frontmostPID(), foregroundPID > 0,
                       let app = apps.first(where: {
                           $0["bundle_id"]?.string == front
                               && $0["pid"]?.integer == foregroundPID
                       }) {
                        bundleID = front
                        pid = foregroundPID
                        appName = app["name"]?.string ?? front
                    }
                    guard pid != nil else {
                        return settle(.blocked("The goal doesn't name an app, and nothing is in front to act on."),
                                      task, history,
                                      blockedReason: "no frontmost app to bind")
                    }
                    step("bound the frontmost app \(appName) pid=\(pid ?? -1)")
                } else if config.windowOnly {
                    appName = resolved?.name ?? appName
                    bundleID = resolved?.bundle
                    guard let owner = resolved?.pid else {
                        return settle(.blocked("The target app is not running. No application was launched."),
                                      task, history, blockedReason: "pinned app unavailable")
                    }
                    pid = owner
                } else {
                    appName = resolved?.name ?? appName
                    bundleID = resolved?.bundle
                    pid = resolved?.pid
                    var args: [String: JSONValue] = ["session": .string(session)]
                    if let bundleID { args["bundle_id"] = .string(bundleID) }
                    else { args["name"] = .string(appName) }
                    var launchCorpus = appName
                    // Browser targets pick the goal's domain token up too —
                    // "open example.com in Safari" carries its address
                    // mid-sentence, and the URL rides the same reopen that
                    // materializes the window a windowless browser lacks.
                    let taskURL = task.values["url"] ?? (task.goal.hasPrefix("http") ? task.goal : nil)
                        ?? (BrowserSupport.isBrowser(bundleID: bundleID)
                            ? ActionCatalog.firstDomainURL(in: task.goal) : nil)
                    if let url = taskURL {
                        args["urls"] = .array([.string(url)])
                        launchCorpus += " " + url
                    }
                    // The named task consents to launching its own app —
                    // the name/URL still rides the deny scan; a
                    // model-authored goal rides the standing-grant gate.
                    try await gateExplicit("launch_app", corpus: launchCorpus,
                                           denied: task.deny, confirmed: &confirmedTask)
                    let launched: JSONValue
                    do {
                        launched = try await call("launch_app", args)
                    } catch let error as DriverConnectionError {
                        // A tool-level refusal is a definitive answer — surface
                        // the driver's reason ("No installed macOS app found…"),
                        // not the generic transport-failure text.
                        if case .toolRefused(_, _, let detail) = error {
                            return settle(.blocked(detail), task, history)
                        }
                        if case .remote(let text) = error {
                            return settle(.blocked(text), task, history)
                        }
                        throw error
                    }
                    let payload = launched["structuredContent"] ?? launched
                    pid = pid ?? payload["pid"]?.integer
                    bundleID = bundleID ?? payload["bundle_id"]?.string
                    appName = payload["name"]?.string ?? appName
                    launchWindows = payload["windows"]?.array ?? []
                    step("launched \(appName) pid=\(pid ?? -1)")
                }
            }
            guard let pid else {
                return settle(.blocked("Could not launch or find \(appName)."),
                              task, history)
            }
            // Consent now knows its scope — an "Always" answer persists
            // against exactly this (action, bundle) pair.
            bindConsentIdentity(name: appName.isEmpty ? nil : appName,
                                bundleID: bundleID)

            // 2. Bind a window — launch rows first, then a materialize
            //    pass (poll → host-side activate → poll): the driver
            //    suppresses activation on launch by design, so a fresh
            //    app's window appears only after something fronts it. A
            //    pinned target is revalidated, never substituted.
            if task.scope == .open, task.foreground, task.windowID == nil, task.windowName == nil {
                try await gateExplicit("bring_to_front", corpus: appName,
                                       denied: task.deny, confirmed: &confirmedTask)
                try await focusLeased {
                    if self.appIsHidden(pid) { _ = self.unhideApp(pid) }
                    self.activateRestoredApp(pid, bundleID)
                }
            }
            var rows = launchWindows
            if rows.isEmpty {
                rows = try await listedWindowRows(pid: pid, session: session)
            }
            if task.windowID == nil, rows.isEmpty {
                rows = await materialize(pid: pid, bundle: bundleID ?? "",
                                         didLaunch: task.pid == nil,
                                         session: session)
            }
            if let pinned = task.windowID, (config.windowOnly || !rows.isEmpty),
               !rows.contains(where: {
                   $0["window_id"]?.integer == pinned
                       && ($0["pid"]?.integer == nil || $0["pid"]?.integer == pid)
               }) {
                return settle(.blocked("The pinned target window closed. No other window was substituted."),
                              task, history, pid: pid,
                              blockedReason: "pinned window closed")
            }
            if task.windowID == nil, let named = task.windowName,
               windowID(named: named, in: rows) == nil {
                return settle(.blocked("The named target window was not found. No other window was substituted."),
                              task, history, pid: pid, blockedReason: "named window missing")
            }
            let windowID = task.windowID
                ?? windowID(named: task.windowName, in: rows)
                ?? Self.bestWindowID(in: rows)
            guard let windowID else {
                if task.scope == .open {
                    if task.foreground {
                        return settle(.blocked("\(appName) has no observable window after activation."),
                                      task, history, pid: pid, blockedReason: "foreground open unverified")
                    }
                    // A windowless open still activates the app — a visible
                    // effect — before reporting the observed running state.
                    try? await focusLeased { self.activateApp(pid) }
                    return settle(.done, task, history, pid: pid,
                                  bundleID: bundleID, confirmedAny: true)
                }
                return settle(.blocked("No usable window for \(appName)."),
                              task, history, pid: pid)
            }
            if task.foreground {
                try await gateExplicit("bring_to_front",
                                       corpus: [appName, task.windowName ?? ""]
                                            .joined(separator: " "),
                                       denied: task.deny, confirmed: &confirmedTask)
                _ = try? await focusLeased { try await self.call("bring_to_front",
                    ["pid": .number(Double(pid)),
                     "window_id": .number(Double(windowID)),
                     "session": .string(session)]) }
            }

            // 3. Open-scope tasks finish at a live window — no loop needed.
            //    The observed window is the verified postcondition and the
            //    launch/raise is the dispatched effect — `.done` is honest.
            if task.scope == .open {
                if task.foreground,
                   (try? await verifyForeground(pid: pid, windowID: windowID, session: session)) != true {
                    return settle(.blocked("\(appName) could not be verified in front."),
                                  task, history, pid: pid, windowID: windowID,
                                  blockedReason: "foreground open unverified")
                }
                return settle(.done, task, history, pid: pid, windowID: windowID,
                              bundleID: bundleID, confirmedAny: true)
            }

            // 4. Browser binding when the target is a known browser.
            var browser: BrowserSupport.Binding?
            if BrowserSupport.isBrowser(bundleID: bundleID) {
                browser = try? await BrowserSupport.bind(pid: pid, windowID: windowID,
                                                         session: session, call: call,
                                                         allowPreparation: !config.windowOnly)
            }

            // 4. The rounds — JevDecider inside TaskLoop. Bind, launch,
            //    window selection, and the fast lane above are
            //    unchanged; below, the same bounded candidate space,
            //    pick gates, dispatch ladder, and refusal shapes are
            //    re-expressed on the contract's loop:
            //    observe → decide → consent → actuate → settle.
            let box = RoundBox(browser: browser)
            box.context = task.previousContext
            box.confirmed = confirmedTask
            var rounds = TaskLoop.Config()
            rounds.maxRounds = config.maxRounds
            rounds.observedPostActionProgress = true
            // The drive lane's settle is the driver's own `effect` word —
            // no settle-wait or re-read per round — and observation
            // errors keep their typed refusal shapes (sessionRestarted,
            // transport failure) instead of degrading to a nil snapshot.
            rounds.settleReobserves = false
            rounds.observationFailure = .propagate
            // Its done rule distinguishes "done for an effect we
            // confirmed" from "the goal was already true".
            rounds.donePolicy = .verifiedOrAlreadySatisfied
            let bound = WindowRef(pid: pid, windowID: windowID)
            let grantCheck = granted
            let askFn = ask
            let taskLoop = TaskLoop(
                source: DriveCaptureSource(
                    observe: { try await self.observe($0, $1) },
                    window: bound, session: session, nativeRead: nativeReadOnly),
                decider: JevDecider(
                    choose: choose,
                    maxInvalidPicks: config.maxInvalidChoices,
                    maxStaleRounds: config.maxStaleRounds,
                    elementCap: config.elementCap,
                    windowOnly: config.windowOnly,
                    extras: { [weak self] observation in
                        guard let self else { return .init() }
                        return await self.roundExtras(
                            pid: pid, windowID: windowID, box: box, session: session,
                            windowTitle: observation.axSnapshot?.windowTitle)
                    },
                    gaze: { [gaze] in try? await gaze?() },
                    context: {
                        guard let context = box.context else { return nil }
                        return box.contextIsClipboard && !grantCheck()
                            ? "[clipboard: \(context.count) chars — withheld; no standing grant]"
                            : context
                    }),
                actuate: { [weak self] request in
                    guard let self else { throw DriverConnectionError.closed }
                    return try await self.actuate(request, box: box, task: task,
                                                  pid: pid, windowID: windowID,
                                                  session: session)
                },
                consent: { [weak self] request, _ in
                    guard let self else { return .allow }
                    return await self.consentRuling(request, denied: task.deny,
                                                    pid: pid, windowID: windowID,
                                                    box: box)
                },
                ask: askFn.map { askFn in
                    { prompt, options in
                        await askFn(options.isEmpty
                            ? .question(prompt)
                            : .choice(prompt: prompt, options: options))
                    }
                },
                config: rounds,
                feed: { [weak self] s in Task { await self?.feed(s) } })
            let result = await taskLoop.run(TaskBrief(
                goal: task.goal, window: bound, application: task.application,
                values: task.values, deny: task.deny,
                successContains: task.successContains))
            for rec in result.history {
                history.append(rec.detail.map { "\(rec.summary) — \($0)" }
                    ?? rec.summary)
            }
            return settleRound(result, task: task, history: history, box: box,
                               pid: pid, windowID: windowID, bundleID: bundleID,
                               appName: appName)
        } catch is CancellationError {
            return settle(.cancelled, task, history)
        } catch let abort as Abort {
            switch abort {
            case .denied(let why):
                return settle(.blockedByConsent(why), task, history,
                              blockedReason: why, consentBlock: .permanent)
            case .declined:
                let why = "The action was not approved."
                return settle(.blockedByConsent(why), task, history,
                              blockedReason: why, consentBlock: .declined)
            case .missingGrant:
                let why = "Computer use needs the standing grant — the user enables it in Jarvis settings."
                return settle(.blockedByConsent(why), task, history,
                              blockedReason: why, consentBlock: .missingGrant)
            case .refused(let why):
                // A driver refusal is an admission failure — never a
                // consent block the standing grant could fix.
                return settle(.blocked(why), task, history,
                              blockedReason: why)
            }
        } catch let error as DriverConnectionError {
            // Session-death is an admission failure — the daemon rejected
            // the call before it dispatched — so the say is a restart
            // line, never the daemon's tombstone bookkeeping text. The
            // marker reason lets the coordinator auto-retry the task.
            if error.isDeadSession || error.isSessionRestarted {
                return settle(.blocked(Self.sessionRestartedMessage), task, history,
                              blockedReason: Self.sessionRestartedReason)
            }
            switch error {
            // Honest refusals carry their own reason — surfacing them as a
            // "connection dropped" misleads the user about what failed.
            case .refused(let why), .remote(let why):
                return settle(.blocked(why), task, history, blockedReason: why)
            case .toolRefused(_, let code, let detail):
                let why = detail.isEmpty ? "The driver refused (\(code))." : detail
                return settle(.blocked(why), task, history, blockedReason: why)
            default:
                return settle(.blocked("The driver connection dropped mid-task: \(error.localizedDescription)"),
                              task, history,
                              blockedReason: "transport failure")
            }
        } catch is CuaUncertainOutcome {
            // Dispatched but the postcondition could not be proven — the
            // honest outcome is blocked-with-reason, never done.
            return settle(.blocked("The action was delivered but its result could not be verified — the target state is unknown."),
                          task, history,
                          blockedReason: "dispatched but unverifiable")
        } catch {
            // Uncertain transport — an in-flight mutation may have landed.
            // Never report done; never replay.
            return settle(.blocked("The driver connection dropped mid-task: \(error.localizedDescription)"),
                          task, history,
                          blockedReason: "transport failure")
        }
    }

    func resolveTaskApplication(
        _ task: DriveTask,
        capturedOwner: @Sendable (DriveTask) async -> AppResolver.App? = { task in
            await DriveLoop.capturedForegroundApplication(application: task.application, windowID: task.windowID)
        }
    ) async -> (app: AppResolver.App?, matches: [AppResolver.App]) {
        if let pid = task.pid, pid > 0, let bundle = task.application, !bundle.isEmpty,
           let window = task.windowID, window > 0, let app = await capturedOwner(task),
           app.pid == pid, app.bundle == bundle, !app.name.isEmpty {
            return (app, [app])
        }
        return await resolver.resolveDetailed(task.application ?? task.goal)
    }

    private func resolveTargetApp(
        _ resolved: (app: AppResolver.App?, matches: [AppResolver.App]),
        task: DriveTask, session: String
    ) async throws -> AppResolver.App? {
        guard task.pid == nil, let pinned = task.windowID,
              let bundle = resolved.app?.bundle, !bundle.isEmpty else { return resolved.app }
        var candidates: [Int: AppResolver.App] = [:]
        for app in resolved.matches where app.bundle?.caseInsensitiveCompare(bundle) == .orderedSame {
            if let pid = app.pid, pid > 0 { candidates[pid] = app }
        }
        guard candidates.count > 1 else { return resolved.app }
        let refusal = DriverConnectionError.refused(
            "The pinned window has no unique verified owner in the requested app. No other window was substituted.")
        var owner: AppResolver.App?
        for (pid, app) in candidates {
            try Task.checkCancellation()
            let rows = try await listedWindowRows(pid: pid, session: session).filter {
                $0["window_id"]?.integer == pinned
            }
            guard rows.count <= 1 else { throw refusal }
            if let row = rows.first {
                guard row["pid"]?.integer == pid, owner == nil else { throw refusal }
                owner = app
            }
        }
        try Task.checkCancellation()
        guard let owner else { throw refusal }
        return owner
    }

    /// `suggest_action` — one resolve→observe→choose pass, no dispatch. The
    /// app must already be running; launching it would itself be an effect.
    func preview(_ task: DriveTask, session: String) async throws -> String {
        if config.windowOnly, task.windowID == nil { return "An exact target window is required." }
        let apps = await resolver.resolveDetailed(task.application ?? task.goal)
        guard let resolved = try await resolveTargetApp(apps, task: task, session: session),
              let pid = task.pid ?? resolved.pid else {
            return "The app isn't running — nothing to observe."
        }
        let chosenWindow: Int?
        if let pinned = task.windowID {
            let rows = try await listedWindowRows(pid: pid, session: session)
            guard rows.contains(where: {
                $0["window_id"]?.integer == pinned
                    && ($0["pid"]?.integer == nil || $0["pid"]?.integer == pid)
            }) else { return "The pinned target window is unavailable. No sibling was observed." }
            chosenWindow = pinned
        } else {
            chosenWindow = try await pickWindow(pid: pid, wanted: task.windowName,
                                                session: session, launchWindows: [])
        }
        guard let windowID = chosenWindow else {
            return "No usable window for \(resolved.name)."
        }
        let window = WindowRef(pid: pid, windowID: windowID)
        let snap = try await DriveCaptureSource(
            observe: { try await self.observe($0, $1) }, window: window,
            session: session, nativeRead: nativeReadOnly).axTree(of: window, depth: .standard)
        let elements = snap.elements.map(DriveCandidates.axToDrive).map { element in
            var element = element
            if DriveCandidates.isSecure(role: element.role, label: element.label) {
                element.value = nil
            }
            return element
        }
        let snapID = snap.snapshotID
        let title = snap.windowTitle
        var candidates = DriveCandidates.drafts(
            elements: elements, snapshotID: snapID, windowTitle: title,
            goal: task.goal, cap: config.elementCap,
            url: task.values["url"] ?? (task.goal.hasPrefix("http") ? task.goal : nil))
        candidates += DriveCandidates.windowControlDrafts(
            windowControlButtonsInWindow(pid_t(pid), windowID), windowTitle: title)
        var pageURL: String?
        if BrowserSupport.isBrowser(bundleID: resolved.bundle),
           let bound = try? await BrowserSupport.bind(pid: pid, windowID: windowID,
                                                      session: session, call: call,
                                                      allowPreparation: !config.windowOnly),
           let refs = try? await BrowserSupport.snapshot(bound, session: session,
                                                         call: { try await self.observe($0, $1) }) {
            pageURL = bound.pageURL
            candidates += DriveCandidates.browserDrafts(refs, binding: bound,
                                                        cap: config.browserRefCap)
        }
        if config.windowOnly {
            candidates.removeAll {
                if case .request(let request) = $0.kind { return !DriveCandidates.isWindowLocal(request) }
                return false
            }
        }
        var fields = DriveCandidates.observationFields(
            elements: elements, candidates: candidates, goal: task.goal, values: task.values)
        if let pageURL { fields["page_url"] = .string(pageURL) }
        let state = DriveCandidates.stateJSON(
            goal: task.goal, app: task.application ?? "", window: title ?? "",
            options: candidates.map { "\($0.id): \($0.description)" },
            recentSteps: [], context: task.previousContext,
            snapshotID: snapID, fields: fields)
        guard let picked = try await choose(state,
                                            candidates.map { ($0.id, $0.description) }),
              let candidate = candidates.first(where: { $0.id == picked.id }) else {
            return "No confident next step."
        }
        if picked.doneVote == true {
            return "The goal may be complete; drive_until must verify it."
        }
        return "Next step: \(candidate.description)."
    }

    /// `list_apps` on the observation lane — roster reads never mutate,
    /// so they ride `callRead` when the caller wired one.
    private func appInventory(session: String) async -> [JSONValue] {
        let appList = try? await observe("list_apps",
            ["session": .string(session)])
        return appList?["structuredContent"]?["apps"]?.array
            ?? appList?["apps"]?.array ?? []
    }

    /// Whether the fast-lane resolution for this goal could ever consult
    /// the app roster. The app-free bodies — gaze referents, tracker
    /// control, media/system chords, overlay verbs, repeat/locate,
    /// dictation, and the URL/web-search lanes — dispatch without it, so
    /// a spoken "click" never waits on `list_apps`. Everything else
    /// (qualifier resolution, `parseOpen`, the appHint merge) reads it.
    static func fastLaneNeedsInventory(goal: String, appHint: String? = nil) -> Bool {
        if let parsed = FastAction.parse(goal) {
            switch parsed.action.body {
            case .gaze, .tracker, .mediaKey, .systemHotkey, .overlay,
                 .repeatLast, .locate, .locatePointer, .dictation, .webSearch, .navigateURL, .desktop:
                return false
            case .hotkey, .type, .scroll, .appControl, .appSearch,
                 .menu, .windowFrame, .clickNamed, .showNamed, .exitFullScreen:
                return true
            }
        }
        // A bare "search for X" binds a browser through LaunchServices —
        // the roster can't change its answer. Open verbs and the appHint
        // merge are the inventory's real consumers.
        if FastAction.parseBareSearch(goal) != nil { return false }
        return true
    }

    // MARK: - Dispatch

    /// The three exits a consent ask can take — chip index or spoken
    /// literal both map here.
    enum ConsentVerdict: Equatable {
        case yes, no, always
    }

    /// Consent-ask answer → verdict. Ordinal answers index the radial
    /// (0 Yes, 1 No, 2 Always for <app>); literal speech maps "always",
    /// explicit negatives, and the affirmative set the same way. A
    /// consent default fails closed: anything unparseable is a no.
    nonisolated static func consentVerdict(_ answer: String?,
                                           optionCount: Int) -> ConsentVerdict {
        if let answer, let index = Int(answer), index >= 0, index < optionCount {
            switch index {
            case 0: return .yes
            case 2: return .always
            default: return .no
            }
        }
        guard let answer else { return .no }
        let a = answer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Negatives first — "no, always ask" must decline, not grant.
        if isDenial(a) { return .no }
        if a.hasPrefix("always") || a.contains("always for") { return .always }
        return affirmative(a) ? .yes : .no
    }

    /// The spoken no-set — shared by the consent verdict and the
    /// coordinator's parked-ask shape check so both lanes parse the same
    /// words as a decline.
    nonisolated static func isDenial(_ answer: String) -> Bool {
        let a = answer.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["no", "nope", "nah", "don't", "do not", "never", "stop",
                "cancel", "decline", "refuse"].contains { a.hasPrefix($0) }
    }

    /// Bind consent's scope — called once the loop knows which app it's
    /// touching (bind in `run`, fast-lane resolution). Internal so tests
    /// can stand in for the bind without driving a full launch.
    func bindConsentIdentity(name: String?, bundleID: String?) {
        consentAppName = name
        consentAppBundleID = bundleID
    }

    /// The persisted "Always for <app>" check — answerable only once the
    /// loop knows the target's bundle (post-bind / post-resolution), and
    /// exact on the (actionKind, bundle) pair: a Safari click grant never
    /// answers for Mail.
    private func consentScopedGrant(for tool: String) -> Bool {
        guard let consentAppBundleID else { return false }
        return CuaPolicy.scopedGrantAllows(actionKind: tool,
                                           appBundleID: consentAppBundleID)
    }

    /// The consent half of `dispatch` — the task's own deny strings plus
    /// `CuaPolicy.decide` plus the one `ask`. Factored out so mutations
    /// that never ride the driver tool call (the HID media-key post, the
    /// host-side AXPress) run the identical gate instead of a hand copy.
    @discardableResult
    func consentGate(tool: String, args: [String: JSONValue],
                     elementText: String?, denied: [String],
                     confirmed: inout Bool, pressFrame: CGRect? = nil) async throws -> UndoPlan? {
        if let elementText,
           let hit = denied.first(where: { elementText.lowercased().contains($0.lowercased()) }) {
            feed("denied by task rule: \(hit)")
            throw Abort.denied("Refused: '\(hit)' is blocked for this task.")
        }
        let press = CuaPolicy.consequentialPress(tool: tool, args: args, elementText: elementText)
        let covered = spokenCoverage(press)
        var plan = covered == nil ? await undoPlan(tool: tool, args: args, label: elementText ?? "") : nil
        var decision = CuaPolicy.decide(tool: tool, args: args, elementText: elementText,
                                        standingGrant: granted() || confirmed,
                                        scopedGrant: consentScopedGrant(for: tool),
                                        consequenceConfirmed: covered != nil, undo: plan?.route)
        if case .askFirst(let consequence) = decision {
            plan = nil
            if let pressFrame { await glowPress(pressFrame, label: press?.label ?? "") }
            try await confirmConsequence(consequence, label: press?.label)
            decision = CuaPolicy.decide(tool: tool, args: args, elementText: elementText,
                                        standingGrant: true, scopedGrant: consentScopedGrant(for: tool),
                                        consequenceConfirmed: true)
        }
        switch decision {
        case .deny(let why):
            feed("denied: \(why)")
            throw Abort.denied(why)
        case .askFirst:
            throw Abort.denied("Refused: the press still needed a yes after one was given.")
        case .needsConfirm(let prompt):
            guard let ask else { throw Abort.missingGrant }
            // ONE ask carries every consent shape — the radial shows
            // "Yes", "No", and "Always for <app>" (when the bound app's
            // name is known), and the same continuation resolves a chip
            // pick, a spoken ordinal, or the words themselves. An
            // "always" persists a (tool, bundle) scoped grant — the
            // exact action in the exact app, never a blanket pass.
            var options = ["Yes", "No"]
            if let consentAppName, consentAppBundleID != nil {
                options.append("Always for \(consentAppName)")
            }
            let answer = await ask(.choice(prompt: prompt, options: options))
            switch Self.consentVerdict(answer, optionCount: options.count) {
            case .yes:
                confirmed = true
            case .always where consentAppBundleID != nil:
                CuaPolicy.grantAlways(actionKind: tool,
                                      appBundleID: consentAppBundleID!)
                feed("granted \(tool) for \(consentAppName ?? consentAppBundleID!) — persisted")
                confirmed = true
            case .always:
                // No bound app to scope to — "always" degrades to the
                // per-task yes rather than pretending a grant exists.
                confirmed = true
            case .no:
                throw Abort.declined
            }
        case .allow:
            break
        }
        if let covered { spentCoverage.insert(covered) }
        if plan != nil { unaskedPressSpent = true }
        if let pressFrame, let press { await glowPress(pressFrame, label: press.label) }
        return plan
    }

    /// A press Jarvis is about to make without asking, and the app's ⌘Z
    /// item just before it.
    struct UndoPlan: Sendable {
        let route: UndoRegistry.Route
        let pid: Int
        let windowID: Int
        let bundleID: String
        let label: String
        let before: UndoRegistry.MenuItem
    }

    /// The undo route for a press Jarvis chose itself, or nil. It needs
    /// someone to hear the offer, no earlier unasked press this task, a known
    /// app and window, a registry route, and an app that has an undo
    /// command at all. Archive offers undo only when the person's words
    /// didn't ask for it.
    private func undoPlan(tool: String, args: [String: JSONValue], label: String) async -> UndoPlan? {
        guard ask != nil, !unaskedPressSpent,
              let pid = args["pid"]?.integer, let windowID = args["window_id"]?.integer,
              let bundleID = consentAppBundleID,
              let route = UndoRegistry.route(tool: tool, args: args, label: label, bundleID: bundleID,
                                             mailUndoSendDelay: undo.mailUndoSendDelay) else { return nil }
        if route.kind == .archive,
           (" " + CuaPolicy.normalize((spokenGoal ?? "").lowercased()) + " ").contains(" archive ") { return nil }
        guard let before = await undo.undoItem(pid) else {
            feed("no undo command in \(bundleID) — asking instead")
            return nil
        }
        return UndoPlan(route: route, pid: pid, windowID: windowID, bundleID: bundleID,
                        label: label, before: before)
    }

    /// After the press: keep the offer only when the app's ⌘Z item changed
    /// to a live one, which is the app saying it can take this press back.
    private func recordUndo(_ plan: UndoPlan, pressedAt: Date) async {
        var after = await undo.undoItem(plan.pid)
        for _ in 0..<3 where after == plan.before {
            await undo.settle()
            after = await undo.undoItem(plan.pid)
        }
        guard let after, after.enabled, after != plan.before else {
            feed("pressed \(plan.label) without asking, but \(plan.bundleID) shows no new undo — nothing to offer")
            return
        }
        pendingUndo = PendingUndo(route: plan.route, pid: plan.pid, windowID: plan.windowID,
                                  bundleID: plan.bundleID, item: after, pressedAt: pressedAt)
        feed("pressed \(plan.label) without asking; undo stands as \(after.menu) → \(after.title)")
    }

    /// Binds the person's words for a new task. Internal so tests can
    /// stand in for `run`.
    func bindSpokenGoal(_ goal: String?) {
        spokenGoal = goal
        spentCoverage = []
        pendingUndo = nil
        unaskedPressSpent = false
    }

    /// The control phrase when the person's words name this press and
    /// haven't been spent on an earlier one, else nil.
    private func spokenCoverage(_ press: (consequence: Consequence, label: String, coverage: String)?) -> String? {
        guard let press, let spokenGoal,
              let phrase = Consequence.match(control: press.coverage)?.phrase,
              !spentCoverage.contains(phrase),
              Consequence.covers(goal: spokenGoal, control: press.coverage) else { return nil }
        return phrase
    }

    /// Ask-first for a consequential press Jarvis chose itself (one the
    /// person's words didn't name): one short `Consequence` question, and
    /// only a clear yes within 30 s goes on. The yes covers this one press;
    /// it never sets the task's `confirmed` flag. With nobody to ask, the
    /// press is refused.
    private func confirmConsequence(_ consequence: Consequence, label: String?) async throws {
        guard let ask else {
            feed("denied: \(consequence.rawValue) needs a yes and nobody can answer")
            throw Abort.denied("Refused: pressing that needs your OK, and I can't ask right now.")
        }
        let pending = ConsequenceConfirmation(consequence: consequence, label: label)
        let answer = await ask(.confirm(pending.question))
        guard pending.accepts(answer) else {
            feed("not confirmed: \(consequence.rawValue)")
            throw Abort.declined
        }
        feed("confirmed \(consequence.rawValue)")
    }

    /// The glow on a consequential control as Jarvis presses it, so the
    /// person sees what was pressed for them. Best effort: no overlay
    /// (agent contexts, tests) means no glow, never a refusal.
    func glowPress(_ frame: CGRect, label: String) async {
        _ = await overlayDispatch?(.pressGlow, [(frame: frame, label: label)], nil)
    }

    /// The fast lane's consent gate — the (a) side of the two-class
    /// model `CuaPolicy` documents. A goal the user literally spoke
    /// names its own action, so the utterance IS the consent: the only
    /// veto left is the deny scan (the task's own rules plus the
    /// protected list) over `corpus`, the text the effect lands on —
    /// app name, URL, menu path, window/dialog title, a committed
    /// element's label. Typed text stays OUT of the corpus, the same
    /// exclusion `decide` applies to `args["text"]`. With
    /// `explicitConsent` off — an agent's `drive_until`, where the goal
    /// is model-authored — the identical dispatch is an autonomous
    /// mutation and rides the standing grant / per-task confirm like
    /// every other effect.
    func gateExplicit(_ tool: String, corpus: String, denied: [String],
                      confirmed: inout Bool) async throws {
        if explicitConsent {
            if let hit = denied.first(where: {
                corpus.lowercased().contains($0.lowercased())
            }) {
                feed("denied by task rule: \(hit)")
                throw Abort.denied("Refused: '\(hit)' is blocked for this task.")
            }
            if let why = CuaPolicy.neverReason(text: corpus) {
                feed("denied: \(why)")
                throw Abort.denied(why)
            }
            return
        }
        try await consentGate(tool: tool, args: [:], elementText: corpus,
                              denied: denied, confirmed: &confirmed)
    }

    /// Policy gate → driver call → `effect`. The task's own deny strings
    /// join the code deny list for this call only.
    func dispatch(_ tool: String, _ args: [String: JSONValue],
                          elementText: String?, denied: [String],
                          confirmed: inout Bool, pressFrame: CGRect? = nil) async throws -> (effect: String, escalation: String?, confirmed: Bool) {
        let plan = try await consentGate(tool: tool, args: args, elementText: elementText,
                                         denied: denied, confirmed: &confirmed, pressFrame: pressFrame)
        do {
            let pressedAt = undo.now()
            let result = try await call(tool, args)
            let effect = result["effect"]?.string ?? "unverifiable"
            let escalation = result["escalation"]?["recommended"]?.string
            feed("\(tool) → \(effect)")
            if let plan, effect != "suspected_noop" { await recordUndo(plan, pressedAt: pressedAt) }
            return (effect, escalation, effect == "confirmed")
        } catch let error as DriverConnectionError {
            if case .toolRefused(_, let code, let detail) = error {
                // A stale token is the ONE refusal a retry can fix — by
                // identity, on a fresh snapshot, upstream. Every other
                // refusal settles the task.
                if code == "stale_element_token" || detail.contains("stale_element_token") {
                    throw StaleElementToken()
                }
                throw Abort.refused("The driver refused: \(code).")
            }
            if case .refused(let text) = error, text.contains("stale_element_token") {
                throw StaleElementToken()
            }
            throw error
        }
    }

    /// Re-find an element in a fresh snapshot by identity — role + label
    /// (+ value for unlabeled rows) + frame proximity — never by index:
    /// a new snapshot re-orders rows and re-mints tokens, so a position
    /// match says nothing about which element this was. A unique match
    /// only: a vanished element or a pair of look-alikes returns nil —
    /// clicking the wrong neighbor is worse than an honest skip.
    static func relocate(_ element: Element, in fresh: [Element]) -> Element? {
        func centerDistance(_ e: Element) -> Double {
            let dx = (e.frame.x + e.frame.w / 2) - (element.frame.x + element.frame.w / 2)
            let dy = (e.frame.y + e.frame.h / 2) - (element.frame.y + element.frame.h / 2)
            return (dx * dx + dy * dy).squareRoot()
        }
        let matches = fresh.filter { candidate in
            guard candidate.role.lowercased() == element.role.lowercased(),
                  centerDistance(candidate) <= 48 else { return false }
            if element.label.isEmpty {
                // An unlabeled element's role+value is the only identity
                // signal it carries.
                return candidate.label.isEmpty
                    && (candidate.value ?? "") == (element.value ?? "")
            }
            return candidate.label.caseInsensitiveCompare(element.label) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The stale-token remedy: re-observe once, re-derive the dispatch
    /// args from the element's IDENTITY (its fresh token, or its index
    /// plus the NEW snapshot's id — a retry on the dead token or a bare
    /// index would bind position, not identity), and deny-scan under the
    /// matched element's own text — a "Buy now" button relabelled between
    /// snapshots still refuses. One retry: a second stale means the
    /// screen is churning faster than the loop can bind it, and a
    /// vanished or ambiguous element gets an honest refusal, never a
    /// positional guess.
    private func redispatchRelocated(_ tool: String, _ args: [String: JSONValue],
                                     element: Element?, pid: Int, windowID: Int,
                                     session: String, denied: [String],
                                     confirmed: inout Bool) async throws
        -> (effect: String, escalation: String?, confirmed: Bool) {
        guard let element else {
            throw Abort.refused("The element's token went stale and there is no identity to relocate — nothing was retried.")
        }
        let fresh = try await observe("get_window_state", [
            "pid": .number(Double(pid)),
            "window_id": .number(Double(windowID)),
            "include_screenshot": .bool(false),
            "max_elements": .number(600), "max_depth": .number(20),
            "session": .string(session)])
        let snapshotID = fresh["snapshot_id"]?.string
            ?? fresh["structuredContent"]?["snapshot_id"]?.string
        guard let relocated = Self.relocate(element, in: Self.elements(from: fresh)) else {
            throw Abort.refused("The element went stale and can't be re-found — nothing was retried.")
        }
        var retry = args
        retry["element_index"] = nil
        retry["element_token"] = nil
        retry["snapshot_id"] = nil
        if let token = relocated.token {
            retry["element_token"] = .string(token)
        } else {
            retry["element_index"] = .number(Double(relocated.index))
            if let snapshotID { retry["snapshot_id"] = .string(snapshotID) }
        }
        let text = (relocated.label + " " + (relocated.value ?? ""))
            .trimmingCharacters(in: .whitespaces)
        do {
            return try await dispatch(tool, retry,
                                      elementText: text.isEmpty ? nil : text,
                                      denied: denied, confirmed: &confirmed)
        } catch is StaleElementToken {
            throw Abort.refused("The element kept going stale — the screen is changing faster than the loop can bind it.")
        }
    }

    static func affirmative(_ answer: String?) -> Bool {
        guard let answer, !Consequence.hasNegation(answer) else { return false }
        let a = CuaPolicy.normalize(answer.lowercased()) + " "
        return ["yes", "yeah", "yep", "sure", "ok", "okay", "go ahead", "do it",
                "confirm", "allow", "approve", "run it", "fine"].contains { a.hasPrefix($0 + " ") }
    }

    // MARK: - Observation → candidates

    private func pickWindow(pid: Int, wanted: String?, session: String,
                            launchWindows: [JSONValue]) async throws -> Int? {
        var windows = launchWindows.compactMap(Self.windowEntry)
        if windows.isEmpty {
            let list = try await observe("list_windows",
                ["pid": .number(Double(pid)), "session": .string(session)])
            windows = (list["structuredContent"]?["windows"]?.array
                ?? list["windows"]?.array ?? []).compactMap(Self.windowEntry)
        }
        if let wanted,
           let match = windows.first(where: {
               $0.title.localizedCaseInsensitiveContains(wanted)
           }) { return match.id }
        return windows.first?.id
    }

    private static func windowEntry(_ w: JSONValue) -> (id: Int, title: String)? {
        guard let id = w["window_id"]?.integer ?? w["id"]?.integer else { return nil }
        return (id, w["title"]?.string ?? w["name"]?.string ?? "")
    }

    static func elements(from snap: JSONValue) -> [Element] {
        (snap["structuredContent"]?["elements"]?.array
            ?? snap["elements"]?.array ?? []).compactMap { e in
            guard let index = e["element_index"]?.integer else { return nil }
            let f = e["frame"]
            return Element(index: index,
                           token: e["element_token"]?.string,
                           role: e["role"]?.string ?? "",
                           label: e["label"]?.string ?? e["title"]?.string ?? "",
                           value: e["value"]?.string,
                           frame: (f?["x"]?.numberValue ?? 0, f?["y"]?.numberValue ?? 0,
                                   f?["w"]?.numberValue ?? 0, f?["h"]?.numberValue ?? 0),
                           actions: e["actions"]?.array?.compactMap(\.string) ?? [])
        }
    }

    static func fingerprint(of elements: [Element], title: String?) -> String {
        var h = Hasher()
        h.combine(title)
        h.combine(elements.count)
        for e in elements {
            h.combine(e.index)
            h.combine(e.role)
            h.combine(e.label)
            h.combine(e.value)
            h.combine(e.frame.x)
            h.combine(e.frame.y)
            h.combine(e.frame.w)
            h.combine(e.frame.h)
            h.combine(e.actions)
        }
        return String(h.finalize())
    }

    /// Goals that point at the screen instead of naming a process —
    /// "this button", "the yellow thing". Whole-phrase boundary match so
    /// "submit" never trips on "it".
    static func isDeicticGoal(_ goal: String) -> Bool {
        goal.lowercased().range(
            of: #"\b(this|that|it|the thing|the yellow thing|this button|that button)\b"#,
            options: .regularExpression) != nil
    }

    func settle(_ status: DriveStatus, _ task: DriveTask, _ history: [String],
                pid: Int? = nil, windowID: Int? = nil,
                bundleID: String? = nil, confirmedAny: Bool = false,
                blockedReason: String? = nil,
                consentBlock: DriveStatus.ConsentBlock? = nil) -> DriveResult {
        Self.log.notice("settle \(String(describing: status), privacy: .public) goal=\(task.goal, privacy: .public) pid=\(pid ?? -1) wid=\(windowID ?? -1) effect=\(confirmedAny) reason=\(blockedReason ?? "-", privacy: .public)")
        var result = DriveResult(status: status, history: history, pid: pid,
                                 windowID: windowID, bundleID: bundleID,
                                 dispatchedEffect: confirmedAny, blockedReason: blockedReason,
                                 consentBlock: consentBlock)
        // A press made without asking is offered back as the task ends,
        // whatever else happened after it.
        if let pending = pendingUndo {
            pendingUndo = nil
            let now = undo.now()
            let offered = pending.offered(at: now)
            if now < offered.expiresAt {
                undo.offers.offer(offered)
                result.spoken = pending.route.offer
                result.history.append(pending.route.offer)
            }
        }
        return result
    }
}

extension DriverConnectionError {
    /// A session-lifecycle refusal — the daemon says this label cannot
    /// serve the call: tombstoned ("session has ended"), bound to a
    /// different transport ("session is not available to this
    /// transport"), mid-teardown ("session is ending"), or waiting on a
    /// finished cleanup before revival is allowed. These are session
    /// bookkeeping, not tool refusals: the remedy is resurrection or a
    /// fresh label, and the raw text never reaches the user.
    var isDeadSession: Bool {
        let code: String?
        let message: String
        switch self {
        case .remote(let text), .refused(let text):
            code = nil; message = text
        case .toolRefused(_, let refusalCode, let detail):
            code = refusalCode; message = detail
        default:
            return false
        }
        if code == "session_ended" || code == "session_unavailable" { return true }
        let lower = message.lowercased()
        guard lower.contains("session") else { return false }
        // The daemon quotes the label inside these phrases ("session
        // 'voice' is not available to this transport"), so match the
        // fixed tails rather than whole strings.
        return lower.contains("has ended")
            || lower.contains("is not available to this transport")
            || lower.contains("is ending")
            || lower.contains("cleanup is incomplete")
    }

    /// The daemon answered "no" (any refusal shape) as opposed to the
    /// wire itself dying — used to classify a failed `start_session`,
    /// where a refusal means the label is un-revivable from this
    /// transport and a transport fault means the restart never ran.
    var isDaemonRefusal: Bool {
        switch self {
        case .refused, .remote, .toolRefused: return true
        default: return false
        }
    }

    /// The mapped human line the call wrapper throws when its
    /// resurrection budget is spent — lets the settle path tag the
    /// marker reason instead of treating it as an ordinary refusal.
    var isSessionRestarted: Bool {
        self == .refused(DriveLoop.sessionRestartedMessage)
    }
}

/// Session-label resurrection, serialized per label across every drive
/// loop sharing a transport. The daemon tombstones a public session
/// label when its owner transport dies — each `CuaConnection` mints one
/// `mcp --embedded` proxy identity the daemon binds as the session's
/// owner — or after the idle TTL sweep, and only the ORIGINAL owner may
/// `start_session` it back. So one waiter runs the restart while the
/// rest share its outcome; when the daemon refuses revival, the label
/// rotates to a fresh successor (the daemon's own remedy) and every
/// later `session` arg follows the map. Rotations are sticky for the
/// daemon's life — a tombstone never becomes usable to us again.
actor SessionResurrector {
    static let shared = SessionResurrector()

    /// What a serialized `start_session` came back as.
    enum RestartOutcome: Sendable {
        case live        /// daemon accepted — the label serves this transport again
        case refused     /// daemon refused revival — the label needs rotation
        case unreachable /// the restart never reached the daemon — surface the real error
    }

    /// label → in-flight restart; later waiters share the first one's work.
    private var restarts: [String: Task<RestartOutcome, Never>] = [:]
    /// label → its live successor; set only after a refused revival.
    private var rotated: [String: String] = [:]
    /// successor → the stem it was minted from, so 'voice-1' rotates to
    /// 'voice-2' rather than nesting a suffix.
    private var stem: [String: String] = [:]
    private var nextSuffix: [String: Int] = [:]

    /// The label calls should dispatch as — follows rotation chains so a
    /// twice-lost 'voice' lands on its current successor.
    func effectiveLabel(_ label: String) -> String {
        var current = label
        var seen: Set<String> = [label]
        while let next = rotated[current], seen.insert(next).inserted { current = next }
        return current
    }

    /// One `start_session` per label at a time: the first waiter runs
    /// `start`; later waiters share its outcome — a second concurrent
    /// start on the same tombstone risks re-binding the session the
    /// first caller just revived.
    func restart(_ label: String,
                 start: @escaping @Sendable (String) async -> RestartOutcome) async -> RestartOutcome {
        if let pending = restarts[label] { return await pending.value }
        let task = Task<RestartOutcome, Never> { await start(label) }
        restarts[label] = task
        defer { restarts[label] = nil }
        return await task.value
    }

    /// A refused revival sticks: `label` maps to a fresh successor and
    /// stays there — the daemon's tombstone binds it to a dead transport
    /// for the rest of the daemon's life.
    @discardableResult
    func rotate(_ label: String) -> String {
        if let live = rotated[label] { return effectiveLabel(live) }
        let root = stem[label] ?? label
        let n = (nextSuffix[root] ?? 0) + 1
        nextSuffix[root] = n
        let fresh = "\(root)-\(n)"
        rotated[label] = fresh
        stem[fresh] = root
        return fresh
    }
}

// MARK: - TaskLoop bridge (the Jev lane's rounds)

extension DriveLoop {
    /// Per-round state the TaskLoop seams share — the browser binding
    /// the actuate arm mutates, the clipboard text the chooser's state
    /// may carry, and the per-task consent approvals + refusal class.
    /// All access is serialized within one run's rounds.
    final class RoundBox: @unchecked Sendable {
        var browser: BrowserSupport.Binding?
        var context: String?
        var contextIsClipboard = false
        var confirmed = false
        var consentBlock: DriveStatus.ConsentBlock = .permanent
        init(browser: BrowserSupport.Binding?) { self.browser = browser }
    }

    /// The drive lane's CaptureSource — one get_window_state per round
    /// through the read lane, mapped to the contract's AXSnapshot. The
    /// bound window is fixed upstream; screenshots and settle waits are
    /// never consumed (the Jev lane is AX-only, and the driver's own
    /// `effect` word is this lane's settle).
    struct DriveCaptureSource: CaptureSource {
        let observe: Call
        let window: WindowRef
        let session: String
        var nativeRead: NativeWindowObservation.Read = NativeWindowObservation.live
        func frontmostWindow() async throws -> WindowRef { window }
        func axTree(of window: WindowRef, depth: AXDepth) async throws -> AXSnapshot {
            try Task.checkCancellation()
            guard window == self.window else {
                throw DriverConnectionError.malformed
            }
            let snap = try await observe("get_window_state", [
                "pid": .number(Double(window.pid)),
                "window_id": .number(Double(window.windowID)),
                "max_elements": .number(Double(depth.maxElements)),
                "max_depth": .number(Double(depth.maxDepth)),
                "tree_format": .string("both"),
                "include_screenshot": .bool(false),
                "session": .string(session)])
            let body = snap["structuredContent"] ?? snap
            guard (body["pid"]?.integer ?? window.pid) == window.pid,
                  (body["window_id"]?.integer ?? window.windowID) == window.windowID else {
                throw DriverConnectionError.malformed
            }
            let snapshot = NativeWindowObservation.applying(
                await nativeRead(window, depth),
                to: try DriveCandidates.axSnapshot(from: snap), window: window)
            try Task.checkCancellation()
            return snapshot
        }
        func domSnapshot(of window: WindowRef) async throws -> DOMSnapshot {
            DOMSnapshot(url: "", title: "", indexedText: "", elements: [])
        }
        func settled(within timeout: Duration) async -> Bool { true }
    }

    /// Per-round candidates the AX tree can't mint — the traffic-light
    /// controls (host-side AX) and the bound browser's page refs/tabs —
    /// plus the page_url state field. Same ids and descriptions the
    /// hand-rolled loop offered.
    private func roundExtras(pid: Int, windowID: Int, box: RoundBox, session: String,
                             windowTitle: String?) async -> DriveCandidates.RoundExtras {
        var out = DriveCandidates.RoundExtras()
        out.candidates += DriveCandidates.windowControlDrafts(
            windowControlButtonsInWindow(pid_t(pid), windowID), windowTitle: windowTitle)
        if let browser = box.browser,
           let refs = try? await BrowserSupport.snapshot(browser, session: session,
                                                         call: { try await self.observe($0, $1) }) {
            out.candidates += DriveCandidates.browserDrafts(refs, binding: browser,
                                                            cap: config.browserRefCap)
        }
        if let url = box.browser?.pageURL { out.stateFields["page_url"] = .string(url) }
        return out
    }

    /// The consent half of dispatch as a TaskLoop ruling — the task's
    /// deny strings ran upstream already; this reproduces
    /// `consentGate`'s CuaPolicy.decide + the one per-task confirm,
    /// including the missing-grant and declined settle classes.
    private func consentRuling(_ request: ActuationRequest, denied: [String],
                               pid: Int, windowID: Int,
                               box: RoundBox) -> TaskLoop.ConsentRuling {
        // Effects the old loop never gated: a tab switch mutates only
        // the binding; the clipboard read is an observation-lane call.
        if request.tool == "switch_tab" || request.tool == "clipboard_read" {
            return .allow
        }
        var args = request.args
        args["pid"] = .number(Double(pid))
        args["window_id"] = .number(Double(windowID))
        switch CuaPolicy.decide(tool: request.tool, args: args,
                                elementText: request.elementText,
                                standingGrant: granted() || box.confirmed,
                                scopedGrant: consentScopedGrant(for: request.tool),
                                consequenceConfirmed: spokenCoverage(CuaPolicy.consequentialPress(
                                    tool: request.tool, args: args, elementText: request.elementText)) != nil) {
        case .allow:
            return .allow
        case .askFirst:
            // A consequential press Jarvis chose: `consentGate` asks at
            // dispatch, where it hears the spoken words, and the yes covers
            // that one press. With nobody to ask, refuse here.
            guard ask != nil else {
                box.consentBlock = .permanent
                return .deny(.consent("Pressing that needs your OK, and I can't ask right now."))
            }
            return .allow
        case .deny(let why):
            feed("denied: \(why)")
            box.consentBlock = .permanent
            return .deny(.consent(why))
        case .needsConfirm(let prompt):
            guard ask != nil else {
                box.consentBlock = .missingGrant
                return .deny(.consent("Computer use needs the standing grant — the user enables it in Jarvis settings."))
            }
            var options = ["Yes", "No"]
            if let consentAppName, consentAppBundleID != nil {
                options.append("Always for \(consentAppName)")
            }
            let appName = consentAppName, appBundle = consentAppBundleID
            return .needsConfirm(prompt: prompt, options: options) { [weak self] verdict in
                switch verdict {
                case .yes:
                    box.confirmed = true
                case .always where appBundle != nil:
                    CuaPolicy.grantAlways(actionKind: request.tool,
                                          appBundleID: appBundle!)
                    let scope = appName ?? appBundle!
                    Task { await self?.feed("granted \(request.tool) for \(scope) — persisted") }
                    box.confirmed = true
                case .always:
                    box.confirmed = true
                case .no:
                    box.consentBlock = .declined
                }
            }
        }
    }

    /// One ActuationRequest through the same dispatch, escalation
    /// ladder, and host-side effect paths the hand-rolled loop ran.
    /// pid/window_id arrive stamped by the loop; session is stamped
    /// here — the decider never saw either.
    private func actuate(_ request: ActuationRequest, box: RoundBox,
                         task: DriveTask, pid: Int, windowID: Int,
                         session: String) async throws -> TaskLoop.ActOutcome {
        guard !config.windowOnly || DriveCandidates.isWindowLocal(request) else {
            throw Abort.denied("The requested action is outside the exact target window.")
        }
        var args = request.args
        let element = args.removeValue(forKey: "_element")
            .flatMap(DriveCandidates.element(fromJSON:))
        args["session"] = .string(session)
        switch request.tool {
        case "switch_tab":
            guard let tabID = args["tab_id"]?.string else {
                return .init(effect: "skipped", verified: false, dispatched: false)
            }
            box.browser?.tabID = tabID
            return .init(effect: "switched", verified: false, dispatched: false)
        case "clipboard_read":
            let clip = try await observe("clipboard_read",
                ["return_text": .bool(true), "session": .string(session)])
            if let text = (clip["structuredContent"]?["text"] ?? clip["text"])?.string {
                box.context = text
                box.contextIsClipboard = true
            }
            return .init(effect: "observed", verified: false, dispatched: false)
        case "media key":
            return try await actuateMedia(args, task: task, box: box)
        case "window_control":
            return try await actuateWindowControl(args, pid: pid,
                                                  windowID: windowID, session: session)
        case "browser_navigate":
            guard let url = args["url"]?.string, let browser = box.browser else {
                return .init(effect: "skipped", verified: false, dispatched: false)
            }
            let outcome = try await dispatch("browser_navigate",
                BrowserSupport.navigateArgs(browser, url: url, session: session),
                elementText: request.elementText, denied: task.deny,
                confirmed: &box.confirmed)
            return .init(effect: outcome.effect, verified: outcome.confirmed)
        case "browser_click", "browser_type":
            guard let ref = args["ref"]?.string, let browser = box.browser else {
                return .init(effect: "skipped", verified: false, dispatched: false)
            }
            let req = request.tool == "browser_click"
                ? BrowserActuation.clickRequest(ref: ref, binding: browser,
                                                session: session)
                : BrowserActuation.typeRequest(ref: ref,
                                               text: args["text"]?.string ?? "",
                                               binding: browser, session: session)
            do {
                let outcome = try await dispatch(req.tool, req.args,
                    elementText: request.elementText, denied: task.deny,
                    confirmed: &box.confirmed)
                if request.tool == "browser_click", outcome.effect == "unverifiable" {
                    return .init(effect: outcome.effect, verified: outcome.confirmed,
                        detail: "the click dispatched synthetically — its effect is unverifiable; the next observe confirms or disproves it")
                }
                return .init(effect: outcome.effect, verified: outcome.confirmed)
            } catch is StaleElementToken {
                // A stale page ref is never retried by identity — refs
                // are minted fresh every round; re-observe stands.
                return .init(effect: "skipped", verified: false,
                             detail: "the page changed under that element — re-observing",
                             dispatched: false)
            } catch let abort as Abort {
                guard case .refused(let why) = abort,
                      why.contains("browser_ref_stale")
                        || why.contains("browser_binding_stale")
                else { throw abort }
                return .init(effect: "skipped", verified: false,
                             detail: "the page changed under that element — re-observing",
                             dispatched: false)
            }
        case "invoke_menu":
            // A native menu path — the driver resolves each segment
            // against the live menubar under its own permission checks;
            // nothing here re-walks the menu.
            let outcome = try await dispatch("invoke_menu", args,
                elementText: request.elementText, denied: task.deny,
                confirmed: &box.confirmed)
            return .init(effect: outcome.effect, verified: outcome.confirmed)
        case "press_key", "hotkey":
            // A bare key is press_key; only a real chord (modifiers +
            // one non-modifier) is hotkey with a keys array.
            let combo = args["key"]?.string ?? ""
            let parts = combo.lowercased()
                .split(whereSeparator: { $0 == "+" || $0 == " " })
                .map(String.init)
            var tool = request.tool
            if parts.count > 1 {
                tool = "hotkey"
                args["keys"] = .array(parts.map { .string($0) })
                args["key"] = nil
            } else {
                tool = "press_key"
                args["key"] = .string(parts.first ?? combo)
            }
            let outcome = try await dispatch(tool, args,
                elementText: request.elementText, denied: task.deny,
                confirmed: &box.confirmed)
            return .init(effect: outcome.effect, verified: outcome.confirmed)
        default:
            // click / double_click / type_text / scroll — the element
            // lane, with the stale-token remedy and the noop ladder.
            var paced = args
            paced["post_action_wait"] = .string("none")
            if CuaDispatchPacing.requested(request.tool, paced) { args = paced }
            do {
                var outcome = try await dispatch(request.tool, args,
                    elementText: request.elementText, denied: task.deny,
                    confirmed: &box.confirmed, pressFrame: element.flatMap(Self.nativeAXScreenRect))
                if outcome.effect == "suspected_noop", let element {
                    outcome = try await escalateNoop(request.tool, args,
                        outcome: outcome, element: element,
                        elementText: request.elementText, task: task,
                        box: box, pid: pid, windowID: windowID, session: session)
                }
                return .init(effect: outcome.effect, verified: outcome.confirmed)
            } catch is StaleElementToken {
                let outcome = try await redispatchRelocated(request.tool, args,
                    element: element, pid: pid, windowID: windowID,
                    session: session, denied: task.deny, confirmed: &box.confirmed)
                return .init(effect: outcome.effect, verified: outcome.confirmed)
            }
        }
    }

    /// The HID media-key post — consent already ruled upstream; a
    /// refused post is reported, never claimed.
    private func actuateMedia(_ args: [String: JSONValue], task: DriveTask,
                              box: RoundBox) async throws -> TaskLoop.ActOutcome {
        guard let id = args["key"]?.string,
              let key = DriveCandidates.mediaKey(id: id) else {
            return .init(effect: "skipped", verified: false, dispatched: false)
        }
        guard postMediaKey(key) else {
            let why = MediaKeys.refusal == .postAccessDenied
                ? "macOS denied the synthetic key — check Accessibility and Input Monitoring permissions"
                : "the system key event could not be created"
            return .init(effect: "unverifiable", verified: false,
                         detail: "the \(key.spokenName) key was not delivered — \(why)")
        }
        return .init(effect: "confirmed", verified: true)
    }

    /// Traffic-light press: an AXPress, not a driver tool — the effect
    /// verifies from live window state exactly as before.
    private func actuateWindowControl(_ args: [String: JSONValue],
                                      pid: Int, windowID: Int,
                                      session: String) async throws -> TaskLoop.ActOutcome {
        guard let raw = args["kind"]?.string,
              let kind = WindowControls.Kind(rawValue: raw) else {
            return .init(effect: "skipped", verified: false, dispatched: false)
        }
        let beforeBounds = ((try? await listedWindowRows(pid: pid, session: session)) ?? [])
            .first(where: { $0["window_id"]?.integer == windowID })?["bounds"]
        guard windowControlPressInWindow(kind, pid_t(pid), windowID) else {
            return .init(effect: "unverifiable", verified: false,
                         detail: "the \(kind.rawValue) control is gone or refused the press")
        }
        var verified = false
        // A read ERROR is not "window unchanged": the press may have
        // landed, so a post-read that never succeeds reports
        // unverifiable rather than folding failure into a negative.
        var readSucceeded = false
        for _ in 0..<10 where !verified {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(150))
            guard let rows = try? await listedWindowRows(pid: pid, session: session)
            else { continue }
            readSucceeded = true
            let row = rows.first(where: { $0["window_id"]?.integer == windowID })
            switch kind {
            case .close:
                verified = row == nil
            case .minimize:
                verified = row == nil
                    || row?["is_on_screen"] == .bool(false)
                    || row?["minimized"] == .bool(true)
            case .zoom, .fullscreen:
                verified = row != nil && row?["bounds"] != beforeBounds
            }
        }
        if verified { return .init(effect: "confirmed", verified: true) }
        if !readSucceeded {
            throw CuaUncertainOutcome(tool: "window_control", result: .object([:]))
        }
        return .init(effect: "unverifiable", verified: false,
                     detail: "pressed the \(kind.rawValue) control but the window did not change")
    }

    /// The suspected_noop ladder: px at the element's center, then
    /// foreground delivery — each behind the same consent+deny gate
    /// the first dispatch cleared (an approval this task covers it).
    private func escalateNoop(_ tool: String, _ args: [String: JSONValue],
                              outcome: (effect: String, escalation: String?, confirmed: Bool),
                              element: Element, elementText: String?,
                              task: DriveTask, box: RoundBox,
                              pid: Int, windowID: Int,
                              session: String) async throws
        -> (effect: String, escalation: String?, confirmed: Bool) {
        var latest = outcome
        switch outcome.escalation {
        case "px":
            // The carried frame is from the STALE snapshot — re-observe
            // and re-locate by identity before spending a pixel click.
            let fresh = try await observe("get_window_state", [
                "pid": .number(Double(pid)),
                "window_id": .number(Double(windowID)),
                "include_screenshot": .bool(false),
                "max_elements": .number(600), "max_depth": .number(20),
                "session": .string(session)])
            guard let relocated = Self.relocate(element, in: Self.elements(from: fresh)) else {
                return ("skipped", nil, false)
            }
            var px = args
            px["element_index"] = nil
            px["element_token"] = nil
            px["snapshot_id"] = nil
            px["x"] = .number(relocated.frame.x + relocated.frame.w / 2)
            px["y"] = .number(relocated.frame.y + relocated.frame.h / 2)
            let pxText = (relocated.label + " " + (relocated.value ?? ""))
                .trimmingCharacters(in: .whitespaces)
            let r = try await dispatch(tool, px,
                elementText: pxText.isEmpty ? nil : pxText,
                denied: task.deny, confirmed: &box.confirmed)
            latest = (r.effect, r.escalation, latest.confirmed || r.confirmed)
        case "foreground":
            var fg = args
            fg["delivery_mode"] = .string("foreground")
            // Foreground delivery fronts the window — it serializes
            // with every other focus borrow.
            let r = try await focusLeased {
                try await self.dispatch(tool, fg,
                    elementText: elementText, denied: task.deny,
                    confirmed: &box.confirmed)
            }
            latest = (r.effect, r.escalation, latest.confirmed || r.confirmed)
        default:
            break
        }
        return latest
    }

    /// TaskLoopResult → the DriveResult the loop always produced —
    /// same statuses, say text, blockedReason markers, consent classes.
    private func settleRound(_ result: TaskLoopResult, task: DriveTask,
                             history: [String], box: RoundBox,
                             pid: Int, windowID: Int, bundleID: String?,
                             appName: String) -> DriveResult {
        let confirmedAny = result.verifiedEffects > 0
        func out(_ status: DriveStatus, reason: String? = nil,
                 consent: DriveStatus.ConsentBlock? = nil) -> DriveResult {
            settle(status, task, history, pid: pid, windowID: windowID,
                   bundleID: bundleID, confirmedAny: confirmedAny,
                   blockedReason: reason, consentBlock: consent)
        }
        switch result.outcome {
        case .done:
            return out(.done)
        case .alreadySatisfied(let reason):
            return out(.alreadySatisfied(reason: reason))
        case .cancelled:
            return out(.cancelled)
        case .escalated(let why):
            switch why {
            case .invalidChoice:
                return out(.handedBack(.untrustedAnswer),
                           reason: "The model could not pick a valid action.")
            case .lowConfidenceTwice:
                return out(.handedBack(.lowConfidence),
                           reason: "The model could not pick confidently.")
            case .staleScreen:
                return out(.blocked("The screen stopped changing; I'm stuck."),
                           reason: "The screen stopped changing.")
            case .roundBudgetExhausted:
                return out(.maxSteps(history: history),
                           reason: "Ran out of steps without finishing.")
            case .wallBudgetExhausted:
                return out(.blocked("The requested time budget expired."),
                           reason: "The requested time budget expired.")
            case .degradedAX, .domCannotGround:
                return out(.blocked("The driver connection dropped mid-task."),
                           reason: "transport failure")
            }
        case .blocked(let reason):
            switch reason {
            case .consent(let why):
                return out(.blockedByConsent(why), reason: why,
                           consent: box.consentBlock)
            case .denyList(let hit):
                let why = "Refused: '\(hit)' is blocked for this task."
                return out(.blockedByConsent(why), reason: why, consent: .permanent)
            case .safety(let why):
                if why == JevDecider.noSafeStepReason {
                    return out(.blocked("I can't see a safe next step in \(appName)."),
                               reason: "no safe next step")
                }
                if why == JevDecider.unverifiedDoneReason {
                    return out(.blocked(why), reason: "success evidence absent")
                }
                return out(.blocked(why), reason: why)
            case .decider(let why):
                if why == JevDecider.needsTextReason {
                    let label = result.history.last(where: {
                        $0.askKind == .question
                    })?.askQuestion.flatMap(Self.textFieldLabel(fromQuestion:))
                        ?? "field"
                    return out(.needsText(fieldLabel: label),
                               reason: JevDecider.needsTextReason)
                }
                if why.hasPrefix("The decider failed: ") {
                    let detail = String(why.dropFirst("The decider failed: ".count))
                    return out(.blocked("The model call failed: \(detail)"),
                               reason: "model failure")
                }
                return out(.blocked(why), reason: why)
            case .actuation(let why):
                let (status, blockReason, consent) = actuationSettle(
                    result.failure, fallback: why)
                return out(status, reason: blockReason, consent: consent)
            case .unverifiedDone:
                return out(.blocked("The task reported complete but could not be verified."),
                           reason: "unverified done")
            case .unobservable:
                return out(.blocked("No usable window for the task."),
                           reason: "unobservable")
            }
        }
    }

    /// The typed error under an actuation block → the exact settle the
    /// hand-rolled loop's catch chain produced.
    private func actuationSettle(_ failure: (any Error)?, fallback: String)
        -> (DriveStatus, String?, DriveStatus.ConsentBlock?) {
        switch failure {
        case let abort as Abort:
            switch abort {
            case .denied(let why):
                return (.blockedByConsent(why), why, .permanent)
            case .declined:
                let why = "The action was not approved."
                return (.blockedByConsent(why), why, .declined)
            case .missingGrant:
                let why = "Computer use needs the standing grant — the user enables it in Jarvis settings."
                return (.blockedByConsent(why), why, .missingGrant)
            case .refused(let why):
                return (.blocked(why), why, nil)
            }
        case is CuaUncertainOutcome:
            return (.blocked("The action was delivered but its result could not be verified — the target state is unknown."),
                    "dispatched but unverifiable", nil)
        case let error as DriverConnectionError:
            if error.isDeadSession || error.isSessionRestarted {
                return (.blocked(Self.sessionRestartedMessage),
                        Self.sessionRestartedReason, nil)
            }
            switch error {
            case .refused(let why), .remote(let why):
                return (.blocked(why), why, nil)
            case .toolRefused(_, let code, let detail):
                let why = detail.isEmpty ? "The driver refused (\(code))." : detail
                return (.blocked(why), why, nil)
            default:
                return (.blocked("The driver connection dropped mid-task: \(error.localizedDescription)"),
                        "transport failure", nil)
            }
        case let error?:
            return (.blocked("The driver connection dropped mid-task: \(error.localizedDescription)"),
                    "transport failure", nil)
        case nil:
            return (.blocked(fallback), fallback, nil)
        }
    }

    /// "What should I type into <label>?" → <label>.
    static func textFieldLabel(fromQuestion question: String) -> String? {
        let prefix = "What should I type into "
        guard question.hasPrefix(prefix), question.hasSuffix("?") else { return nil }
        return String(question.dropFirst(prefix.count).dropLast())
    }
}
