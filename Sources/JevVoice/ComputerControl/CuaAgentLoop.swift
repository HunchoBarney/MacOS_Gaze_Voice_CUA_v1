import Foundation
import AppKit
import OSLog
import JevVoiceCore

/// Shared-resource leases between concurrent drive loops — focus (anything
/// that transiently fronts an app: raises, invoke_menu, launch_app,
/// foreground delivery) and the pasteboard (⌘C/⌘X/⌧ chords). The lane
/// registry satisfies this shape; a nil registry means this loop owns the
/// desktop alone. Releases are declared async so either a sync or an
/// actor-isolated registry can satisfy them.
protocol CuaLaneLeasing: Sendable {
    func acquireFocus(workID: String) async throws
    func releaseFocus(workID: String) async
    func acquirePasteboard(workID: String) async throws
    func releasePasteboard(workID: String) async
}

/// Thin observe→choose→act executor: the Hermes shape. Each step reads the
/// window (and browser page when bound), offers one flat candidate list, and
/// makes exactly one model call. The next observation is the verification —
/// there are no signature ledgers, no per-action judges, no replay ledgers;
/// a step budget and an unproven-done budget bound the loop, and honest
/// refusals beat substitute actions.
///
/// Element tokens come only from the *latest* snapshot; a stale token fails
/// at the driver and the next pass re-observes. Browser target/tab ids are
/// likewise single-snapshot references — resolved inside one read, used
/// immediately, and never carried across reads.
@MainActor
final class CuaAgentLoop {
    typealias Call = CuaTaskAgent.Call
    typealias Judge = CuaTaskAgent.Judge
    /// A driver call with an explicit per-call timeout — needed when the
    /// synthesized-typing rate (~38ms/char) can outrun the default 30s.
    typealias TimedCall = (String, [String: JSONValue], TimeInterval) async throws -> JSONValue

    private let call: Call
    private let timedCall: TimedCall?
    private let judge: Judge
    private let approve: ((String) async throws -> Bool)?
    private let progress: (String) -> Void
    /// Whether a pid currently owns the frontmost app — a seam so tests can
    /// simulate foreground state. Foreground delivery and menu lanes are
    /// only honest while this is true.
    private let isFrontmostApp: (Int) -> Bool
    /// Shared-state leases across concurrent loops — wired to the lane
    /// registry (`CuaLaneRegistry.shared`) once it exists; nil = no peers.
    private let lanes: (any CuaLaneLeasing)?
    /// Identity this drive holds leases under — the work-item id when the
    /// caller has one.
    private let workID: String
    /// Per-step phase timings, fired once per loop iteration.
    private let stepTiming: ((Int, [String: Double]) -> Void)?

    private static let log = Logger(subsystem: "com.chriswozniczek.jevvoice", category: "agent-loop")
    private static let maximumUnprovenDone = 2
    private static let maximumDispatchFailures = 3
    private static let maximumElementCandidates = 40
    /// Shortlist budget: ~30 offered criteria keeps the typed classifier's
    /// confidence above the act gate; a flat 100-option list does not.
    private static let maximumOfferedLanes = 30
    /// Lexical goal-matched element lanes offered before the cap trims.
    private static let maximumElementLanes = 18
    /// When nothing matches the goal lexically, still offer this many
    /// element lanes by role priority.
    private static let elementLaneFloor = 8
    /// Uncertain outcomes allowed per identical dispatch before a block —
    /// the true replay risk — and across different lanes per run, where the
    /// re-observe between them is itself the recovery.
    private static let maximumUncertainPerDispatch = 2
    private static let maximumUncertainTotal = 4

    private(set) var observedPostconditions: [CuaObservedPostcondition] = []
    /// The window the loop is pinned to — repinned to a task-produced window
    /// when exactly one appears (a created document outranks a baseline one).
    private(set) var currentWindowID: Int?
    /// A dispatched browser_navigate whose destination url wasn't yet
    /// visible — verified against the NEXT ordinary browser read, not a
    /// poll loop. `key` is the dispatchKey the miss counts against.
    private var pendingNavigation: (key: String, needle: String)?
    /// Observed-but-unmatched page reads while pendingNavigation is armed —
    /// two misses mean the navigation did not land, recorded honestly.
    private var pendingNavigationMisses = 0

    init(call: @escaping Call, judge: @escaping Judge,
         approve: ((String) async throws -> Bool)? = nil,
         progress: @escaping (String) -> Void = { _ in },
         isFrontmostApp: ((Int) -> Bool)? = nil,
         timedCall: TimedCall? = nil,
         lanes: (any CuaLaneLeasing)? = nil,
         workID: String = "",
         stepTiming: ((Int, [String: Double]) -> Void)? = nil) {
        self.call = call; self.timedCall = timedCall; self.judge = judge
        self.approve = approve; self.progress = progress
        self.lanes = lanes; self.workID = workID; self.stepTiming = stepTiming
        self.isFrontmostApp = isFrontmostApp ?? { pid in
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid)
        }
    }

    /// `call` with an explicit timeout when a timed call seam is wired.
    private func callTool(_ name: String, _ args: [String: JSONValue],
                          timeout: TimeInterval? = nil) async throws -> JSONValue {
        if let timeout, let timedCall { return try await timedCall(name, args, timeout) }
        return try await call(name, args)
    }

    /// Run `body` under the requested leases; every exit releases what was
    /// taken. An acquire failure refuses the dispatch honestly rather than
    /// running unleased against another lane's state.
    private func leased<T>(focus: Bool = false, pasteboard: Bool = false,
                           _ body: () async throws -> T) async throws -> T {
        guard let lanes else { return try await body() }
        var focusHeld = false, pasteHeld = false
        // Staged acquires: the focus lease drops if the pasteboard acquire
        // is refused, so no dispatch runs half-leased against a peer lane.
        do {
            if focus { try await lanes.acquireFocus(workID: workID); focusHeld = true }
        } catch {
            throw DriverConnectionError.refused("A shared lane lease could not be acquired; the action was not dispatched.")
        }
        do {
            if pasteboard { try await lanes.acquirePasteboard(workID: workID); pasteHeld = true }
        } catch {
            if focusHeld { await lanes.releaseFocus(workID: workID) }
            throw DriverConnectionError.refused("A shared lane lease could not be acquired; the action was not dispatched.")
        }
        do {
            let value = try await body()
            if pasteHeld { await lanes.releasePasteboard(workID: workID) }
            if focusHeld { await lanes.releaseFocus(workID: workID) }
            return value
        } catch {
            if pasteHeld { await lanes.releasePasteboard(workID: workID) }
            if focusHeld { await lanes.releaseFocus(workID: workID) }
            throw error
        }
    }

    /// The chord pastes or reads the pasteboard — ⌘C/⌘X/⌘V must not run
    /// while another lane is mid-copy. A press_key with chord notation
    /// ("cmd+c") gets the same lease.
    private static func touchesPasteboard(_ lane: Lane) -> Bool {
        let keys: [String]
        switch lane {
        case .hotkey(let chord): keys = chord
        case .pressKey(let key): keys = key.split(separator: "+").map(String.init)
        default: return false
        }
        let set = Set(keys.map { $0.lowercased() })
        return set.contains("cmd") && !set.isDisjoint(with: ["c", "x", "v"])
    }

    /// Synthesized typing runs ~38ms/char — the default 30s call timeout
    /// stops fitting long payloads. Scale with the text, capped at 2m.
    private static func typeTimeout(_ text: String) -> TimeInterval {
        min(120, 30 + Double(text.count) * 0.05)
    }

    private func recordPostcondition(_ kind: CuaObservedPostcondition.Kind, _ evidence: String,
                                     appName: String? = nil, bundleID: String? = nil,
                                     processID: Int? = nil, windowID: Int? = nil,
                                     windowTitle: String? = nil) {
        observedPostconditions.append(.init(kind: kind, evidence: evidence, appName: appName,
            bundleID: bundleID, processID: processID, windowID: windowID, windowTitle: windowTitle))
    }

    // MARK: - Vocabulary

    /// One flat action the model can pick, built fresh each observation.
    /// Element lanes carry the snapshot's own token so dispatch needs no
    /// re-matching; a stale token is the driver's to refuse.
    private enum Lane {
        case clickElement(token: String, index: Int)
        case typeIntoElement(token: String, index: Int)
        case typeIntoWindow
        case setValue(token: String, index: Int)
        case pixelClick(token: String, index: Int, x: Double, y: Double)
        case invokeMenu(path: [String], index: Int)
        case browserDialog(accept: Bool)
        case launchApp(String)
        case pressKey(String)
        case hotkey([String])
        case scroll(String)
        case newTab
        case navigate(String)
        case browserClick(ref: String)
        case browserType(ref: String)
        case done, stuck

        var id: String {
            switch self {
            case .clickElement(_, let i): return "click_\(i)"
            case .typeIntoElement(_, let i): return "typeinto_\(i)"
            case .typeIntoWindow: return "type_window"
            case .setValue(_, let i): return "setvalue_\(i)"
            case .pixelClick(_, let i, _, _): return "pixel_\(i)"
            case .invokeMenu(_, let i): return "menu_\(i)"
            case .browserDialog(let accept): return accept ? "bdialog_accept" : "bdialog_dismiss"
            case .launchApp: return "launch_app"
            case .pressKey(let k): return "key_\(k)"
            case .hotkey(let keys): return "hotkey_\(keys.joined(separator: "+"))"
            case .scroll(let d): return "scroll_\(d)"
            case .newTab: return "new_tab"
            case .navigate: return "navigate"
            case .browserClick(let r): return "bclick_\(r)"
            case .browserType(let r): return "btype_\(r)"
            case .done: return "done"
            case .stuck: return "stuck"
            }
        }

        /// Lanes that dispatch app-level input. The driver cannot pin them
        /// to one window when the app owns several — it reports that as
        /// `same_pid_keyboard_ambiguity`, a durable fact about the pid.
        var usesWindowInput: Bool {
            switch self {
            case .typeIntoWindow, .pressKey, .hotkey, .newTab, .scroll: return true
            default: return false
            }
        }

        /// The snapshot element the lane acts on, when it has one.
        var elementToken: String? {
            switch self {
            case .clickElement(let t, _), .typeIntoElement(let t, _),
                 .setValue(let t, _), .pixelClick(let t, _, _, _):
                return t
            default:
                return nil
            }
        }

        var elementIndex: Int? {
            switch self {
            case .clickElement(_, let i), .typeIntoElement(_, let i),
                 .setValue(_, let i), .invokeMenu(_, let i):
                return i
            case .pixelClick(_, let i, _, _):
                return i
            default:
                return nil
            }
        }

        /// The `StepJudgment.Kind` the lane maps to: element fills are `type`,
        /// scrolls `scroll`, terminal picks `none`, everything else `press`.
        var stepKind: StepJudgment.Kind {
            switch self {
            case .typeIntoElement, .typeIntoWindow, .setValue, .browserType:
                return .type
            case .scroll:
                return .scroll
            case .done, .stuck:
                return .none
            default:
                return .press
            }
        }

        /// Lanes whose effect can plausibly mint a window — a key press,
        /// scroll or type never produces one, so polling list_windows after
        /// them is ~0.8s + 3 RTTs of pure per-step latency.
        var mayProduceWindow: Bool {
            switch self {
            case .clickElement, .invokeMenu, .newTab, .navigate,
                 .pixelClick, .browserClick, .launchApp:
                return true
            case .hotkey(let keys):
                let set = Set(keys.map { $0.lowercased() })
                return set.contains("cmd") && !set.isDisjoint(with: ["n", "t", "o"])
            default:
                return false
            }
        }

        /// A submit keypress — replayed verbatim it can skip past results.
        var isSubmitKey: Bool {
            if case .pressKey(let key) = self {
                return ["return", "enter"].contains(key.lowercased())
            }
            return false
        }

        /// Lanes that put caller-supplied text into a field.
        var needsFillText: Bool {
            switch self {
            case .typeIntoElement, .typeIntoWindow, .setValue, .browserType:
                return true
            default:
                return false
            }
        }
    }

    private static let keyNames = ["return", "escape", "tab", "delete", "space",
                                   "left", "right", "up", "down", "home", "end", "pageup", "pagedown"]
    /// Clicky's hotkey policy, mirrored: ⌘L is never offered — delivered to a
    /// backgrounded pid the omnibox-focus semantic still pulls the app
    /// forward, and on a browser the correct navigation path is the agent's
    /// own window, not the user's address bar. ⌘F is out too: "find" is an
    /// app-level feature, not a universal chord — in Spotify it opens the
    /// shortcuts overlay, elsewhere it may do nothing or something worse.
    /// The element lanes reach the app's own find/search affordance instead.
    private static let hotkeyChords: [[String]] = [
        ["cmd", "t"], ["cmd", "n"], ["cmd", "w"], ["cmd", "a"],
        ["cmd", "c"], ["cmd", "v"], ["cmd", "x"], ["cmd", "z"], ["cmd", "s"],
        ["cmd", "q"], ["cmd", "shift", "z"]]

    // MARK: - Main loop

    /// Runs the task inside an already-resolved app window to a verified
    /// outcome or an honest refusal. `baselineWindowIDs` is the window set
    /// that predates the task (empty when the task itself launched the app):
    /// a window outside it is task-produced — the one bit of bookkeeping a
    /// create-scope done-veto needs.
    // MARK: - Drive-until (Clicky `drive_until` contract)

    /// Clicky's `drive_until`: snapshot → Jev step → one background-delivery
    /// action → re-snapshot, bounded by `task.maxSteps`. Jev picks an element
    /// + kind; it never writes text — caller-supplied literals live in
    /// `task.values` keyed by field label, and a field with no supplied value
    /// ends the run as `needsText`. `task.deny` is enforced twice: denied
    /// labels never become candidates, and the model's answer is re-checked
    /// before dispatch. Honest terminal statuses ride in `DriveResult`; a
    /// thrown error means the transport itself failed mid-run.
    func drive(_ task: DriveTask) async throws -> DriveResult {
        var pid = task.pid
        var windowID = task.windowID
        var taskLaunchedApp = false
        var appName = ""
        var bundleID = ""
        var ledger: [String] = []
        func finish(_ status: DriveStatus) -> DriveResult {
            DriveResult(status: status, history: ledger, pid: pid, windowID: windowID,
                        bundleID: bundleID.isEmpty ? nil : bundleID)
        }

    /// Best-effort window listing: ordinary failures degrade to nil, but a
    /// dead or timed-out transport rethrows — a launch's own success report
    /// can never stand in for liveness after the driver died.
    func listWindows(pid: Int) async throws -> JSONValue? {
        do {
            return try await call("list_windows", ["pid": .number(Double(pid))])
        } catch let error as DriverConnectionError {
            switch error {
            case .closed, .timedOut: throw error
            default: return nil
            }
        } catch {
            return nil
        }
    }

    /// The target window (or app) is gone — `window_id_not_found` and kin.
    /// This is the success signature of a close/quit goal, not a fault.
    func vanishedWindowOutcome(pid: Int, goal: String, appName: String,
                               ledger: inout [String],
                               windowID: inout Int?) async throws -> DriveResult? {
        let closeGoal = goal.range(of: #"\b(close|quit|exit|shut)\b"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil
        let apps: [JSONValue]
        do {
            apps = (try await call("list_apps", [:]))["apps"]?.array ?? []
        } catch {
            // A failed liveness read is not evidence of a quit — only a
            // successful observation may prove the app is gone. Transport
            // faults propagate; other failures report honestly.
            return finish(.blocked("Could not verify whether \(appName) is still running. Inspect the app before assuming the close landed."))
        }
        let alive = apps.contains {
            $0["pid"]?.integer == pid && $0["running"] != .bool(false)
        }
        if !alive {
            if closeGoal {
                ledger.append("\(appName) is no longer running — the close request is satisfied.")
                recordPostcondition(.resultObserved, "Observed \(appName) no longer running.",
                                    appName: appName, bundleID: bundleID, processID: pid)
                return finish(.done)
            }
            return finish(.blocked("\(appName) quit while the task was in progress. The remaining steps did not run."))
        }
        let windowsValue = try await listWindows(pid: pid)
        guard let rows = windowsValue?["windows"]?.array else {
            // The window list itself was unreadable — not proof of no windows.
            return finish(.blocked("Could not verify \(appName)'s remaining windows. Inspect the app before assuming the close landed."))
        }
        if rows.isEmpty {
            if closeGoal {
                ledger.append("\(appName) has no windows left — the close request is satisfied.")
                recordPostcondition(.resultObserved, "Observed \(appName) with no remaining windows.",
                                    appName: appName, bundleID: bundleID, processID: pid)
                return finish(.done)
            }
            return finish(.blocked("The \(appName) window the task was driving closed before the request finished."))
        }
        // The driven window is gone but the app lives — re-pin to a remaining
        // window and keep driving (close-tab flows land here legitimately).
        if let newID = Self.preferredWindow(in: rows) {
            ledger.append("target window closed — continuing in \(appName)'s remaining window")
            windowID = newID
            return nil
        }
        return finish(.blocked("The \(appName) window the task was driving closed before the request finished."))
    }

        // ── Target: a caller pid, a running app matched by name/bundle, or a
        // background launch — `launch_app` returns its own `windows[]` so the
        // pin needs no extra listing round-trip.
        if let application = task.application, !application.isEmpty {
            let apps = (try? await call("list_apps", [:]))?["apps"]?.array ?? []
            if pid == nil, let match = apps.first(where: {
                $0["running"] != .bool(false) && (
                    $0["bundle_id"]?.string?.caseInsensitiveCompare(application) == .orderedSame
                        || $0["name"]?.string?.caseInsensitiveCompare(application) == .orderedSame) }) {
                pid = match["pid"]?.integer
            }
            if pid == nil {
                var baseline: [String]?
                var newTab = false
                let launched: JSONValue
                do {
                    launched = try await dispatch(.launchApp(application), pid: 0, wid: 0,
                                                  goal: task.goal, text: nil,
                                                  browserTarget: nil, shownTab: nil,
                                                  tabs: [], tabsBaseline: &baseline, newTabRequested: &newTab)
                } catch {
                    return finish(.blocked("\(application) could not be launched. Nothing was dispatched."))
                }
                taskLaunchedApp = true
                pid = launched["pid"]?.integer
                appName = launched["name"]?.string ?? appName
                bundleID = launched["bundle_id"]?.string ?? bundleID
                if windowID == nil {
                    windowID = Self.preferredWindow(in: launched["windows"]?.array ?? [])
                }
                ledger.append("launched \(appName.isEmpty ? application : appName)")
            }
            if appName.isEmpty, let match = apps.first(where: { $0["pid"]?.integer == pid }) {
                appName = match["name"]?.string ?? ""
                bundleID = match["bundle_id"]?.string ?? bundleID
            }
            if appName.isEmpty { appName = application }
        }
        // Pid-only target: still resolve name/bundleID or every
        // bundle-keyed lane (browser isolation) silently disables.
        if task.application == nil, pid != nil, bundleID.isEmpty {
            let apps = (try? await call("list_apps", [:]))?["apps"]?.array ?? []
            if let match = apps.first(where: { $0["pid"]?.integer == pid }) {
                appName = match["name"]?.string ?? ""
                bundleID = match["bundle_id"]?.string ?? ""
            }
        }
        guard var resolvedPID = pid else {
            let target = task.application ?? "the target application"
            return finish(.blocked("\(target) is not running and could not be launched. Nothing was dispatched."))
        }
        if appName.isEmpty { appName = task.application ?? "pid \(resolvedPID)" }

        // An open-scope request is satisfied by the app itself running —
        // the loop never demands a window it has no work to do in. A task
        // carrying a literal payload is never open-only: the text still needs
        // a live surface, so a "launch" classification can never early-pass it.
        if task.scope == .open, task.values["literal_text"] == nil {
            // "Observed running" must be an observation, not the launch's own
            // success report — a transport failure here propagates honestly
            // rather than fabricating the postcondition.
            let live = try await call("list_apps", [:])
            let stillRunning = (live["apps"]?.array ?? []).contains {
                $0["pid"]?.integer == resolvedPID && $0["running"] != .bool(false)
            }
            guard stillRunning else {
                return finish(.blocked("\(appName) did not stay running after launch. Nothing further was dispatched."))
            }
            ledger.append("\(appName) is running — the open request is satisfied.")
            recordPostcondition(.resultObserved, "Observed \(appName) running.",
                                appName: appName, bundleID: bundleID, processID: resolvedPID)
            return finish(.done)
        }

        /// The window set observed before any task effect — a create-scope
        /// request is only proven by a window outside this set.
        var baselineWindowIDs: Set<Int> = []

        // Several windows the request could mean hand the pick to the judge
        // first — a prior answer rides `previous_context` so a re-asked
        // ambiguity resolves from the reply instead of looping identically.
        // Only a "none" answer becomes a user-facing question; a matched or
        // sole window binds silently.
        // A transport death mid-run is never "no windows" — only ordinary
        // listing failures are best-effort. `.closed`/`.timedOut` must
        // propagate so the outcome reads uncertain, never false-blocked.
        if windowID == nil, let listing = try await listWindows(pid: resolvedPID) {
            var matches = listing["windows"]?.array ?? []
            if let wanted = task.windowName, !wanted.isEmpty {
                matches = matches.filter {
                    ($0["title"]?.string ?? "").localizedCaseInsensitiveContains(wanted)
                }
            }
            // Apps expose phantom untitled offscreen windows — they can never
            // be the request's target, so the pick and binds only see real
            // (onscreen, titled) windows. An all-phantom listing falls back
            // unfiltered so "no usable window" stays honest downstream.
            let real = matches.filter {
                $0["is_on_screen"] != .bool(false) && !($0["title"]?.string ?? "").isEmpty
            }
            if !real.isEmpty { matches = real }
            // A listing taken after this task's own launch sees task-produced
            // windows — those must never enter the baseline or a create-scope
            // done could be vetoed by a window the task itself caused.
            if baselineWindowIDs.isEmpty, !taskLaunchedApp {
                baselineWindowIDs = Set((listing["windows"]?.array ?? [])
                    .compactMap { $0["window_id"]?.integer })
            }
            // A "which window" ask is only meaningful when the window's
            // identity carries the goal — a named window matching several
            // titles, or a payload that could land in the wrong window.
            // Carrier goals (any window produces the outcome), create scope
            // and browsers bind the most plausible window silently — create
            // re-pins to the produced window later.
            let windowIdentityMatters = task.windowName != nil || !task.values.isEmpty
            if matches.count > 1, task.scope != .create, windowIdentityMatters,
               !CuaTaskAgent.supportsIsolatedBrowser(bundleID) {
                var criteria: [String: String?] = [
                    "none": "None of these — the user must choose which window."]
                for match in matches {
                    guard let id = match["window_id"]?.integer else { continue }
                    criteria["w\(id)"] = match["title"]?.string ?? "window \(id)"
                }
                let state: JSONValue = .object([
                    "request": .string(task.goal),
                    "app": .string(appName),
                    "previous_context": .string(task.previousContext ?? ""),
                    "windows": .array(matches)])
                var picked: Int?
                if let answers = try? await judge(state, [
                        "window": .choice(
                            instructions: "Which live window should this request bind to? Use previous_context when it names the window; pick none only when the request gives no steer.",
                            criteria: criteria)]),
                   let answer = answers["window"],
                   case .choice(let key, _, _) = answer,
                   key.hasPrefix("w"), key != "none",
                   let id = Int(key.dropFirst()),
                   criteria[key] != nil {
                    picked = id
                }
                if let picked {
                    windowID = picked
                } else {
                    return finish(.needsWindow(candidates:
                        matches.compactMap { $0["title"]?.string ?? $0["window_id"]?.integer.map(String.init) }))
                }
            } else {
                windowID = Self.preferredWindow(in: matches)
            }
        }

        if windowID == nil, let listing = try await listWindows(pid: resolvedPID) {
            if baselineWindowIDs.isEmpty, !taskLaunchedApp {
                baselineWindowIDs = Set((listing["windows"]?.array ?? [])
                    .compactMap { $0["window_id"]?.integer })
            }
            windowID = Self.preferredWindow(in: listing["windows"]?.array ?? [])
        }
        // A caller-pinned window skipped both listings — its pid's window set
        // still predates every task effect, so capture it as the baseline. A
        // failed listing degrades to the pin alone, which provably pre-exists.
        if !taskLaunchedApp, baselineWindowIDs.isEmpty {
            baselineWindowIDs = Set(((try await listWindows(pid: resolvedPID))?["windows"]?.array ?? [])
                .compactMap { $0["window_id"]?.integer })
            if let wid = windowID { baselineWindowIDs.insert(wid) }
        }
        currentWindowID = windowID

        // An explicit "open/show X" request raises the bound window once —
        // the user asked for the app in front. Everything else stays
        // background-honest: element clicks, types and value writes never
        // need the target raised, and window-level input raises on demand
        // only after the driver proves it cannot be pinned. A background
        // task preserves the user's foreground app.
        if task.foreground, let wid = windowID {
            _ = try? await leased(focus: true) {
                try await self.call("bring_to_front",
                    ["pid": .number(Double(resolvedPID)), "window_id": .number(Double(wid))])
            }
        }

        let isBrowser = CuaTaskAgent.supportsIsolatedBrowser(bundleID)
        var browserTarget: JSONValue?
        var browserShownTab: String?
        var tabsBaseline: [String]?

        var newTabRequested = false
        var dispatchFailures = 0
        /// Driver-reported partial/uncertain outcomes, keyed by the exact
        /// dispatch that produced them — the true replay risk is the SAME
        /// action going uncertain twice. A smaller total bound covers
        /// different lanes, where the re-observe between them is itself
        /// the recovery.
        var uncertainPerDispatchKey: [String: Int] = [:]
        var uncertainTotal = 0
        /// Identical fill/submit repeats are effects replayed, never intent —
        /// tracked so a second run of the same payload can't double-type.
        var lastDispatchKey: String?
        /// Consecutive dispatches of the identical action — with the
        /// post-dispatch observation revisiting an already-seen state, a
        /// third blind repeat is suppressed rather than re-fired.
        var identicalStreak = 0
        /// Content fingerprints of every observation this run — a
        /// re-picked action landing in a state the loop already saw is
        /// repetition, not progress.
        var seenFingerprints: Set<String> = []
        /// Consecutive skips of the identical dispatch: a lane the model
        /// keeps re-picking after its effect already ran is removed from
        /// the offered set rather than skipped forever.
        var rePickSkips: [String: Int] = [:]
        var rePickBanned: Set<String> = []
        /// Consecutive sub-0.5-confidence picks: one re-observe pass, then
        /// an honest needsChoice handback carrying the top candidates.
        var lowConfidenceStreak = 0
        /// Transient empty AX reads right after a mutation — one bounded
        /// re-read before the noInteractiveElements handback.
        var emptyReads = 0
        /// Lanes that failed at dispatch — the fallback rung (an AX value
        /// overwrite after faithful typing failed) is only offered for
        /// these; two equivalent fill lanes split judge confidence below
        /// the act threshold.
        var failedLaneIDs: Set<String> = []
        var windowInputAmbiguous = false
        var unprovenDone = 0
        var bindingUpgradeTried = false
        /// After a text dispatch, the next observation proves it landed — an
        /// element value containing the text is recorded as a verified fact.
        var pendingInsertProof: (index: Int?, text: String)?
        /// Elements whose AX click reported suspected_noop / a pixel
        /// escalation — the next reads offer a pixel-click lane, resolved
        /// against that read's own frame and screenshot space. Entries
        /// expire: two reads where the element no longer matches, or three
        /// loop steps old, ends the per-step screenshot tax.
        var pixelArmed: [Int: (label: String, step: Int, misses: Int)] = [:]
        /// The post-produce settle probe's last read — a fresh observation
        /// the next iteration consumes instead of paying for another
        /// get_window_state round-trip.
        var seededObservation: (wid: Int, snapshot: JSONValue, at: Date)?
        /// OCR'd text from one bounded `parse_visual_regions` read — armed
        /// the first time a done claim is rejected for missing evidence.
        /// Windows whose content lives only in pixels (Calculator's
        /// display, a terminal's scrollback) expose nothing readable to AX;
        /// this is their observed evidence, not a replayed claim.
        var visualTexts: [String] = []
        var visualParseTried = false
        var modelHistory: [JSONValue] = []

        for stepIndex in 0..<max(task.maxSteps, 1) {
            /// Per-phase timings fire on every exit — early `continue`s
            /// and terminal `return`s alike.
            var phases: [String: Double] = [:]
            defer { stepTiming?(stepIndex, phases) }
            try Task.checkCancellation()
            // Armed pixel lanes expire: three loop steps, or two reads
            // where the element no longer matches (handled at offer time).
            pixelArmed = pixelArmed.filter { stepIndex - $0.value.step <= 3 }
            guard var wid = windowID else {
                if task.values["literal_text"] != nil {
                    return finish(.blocked("No app was launched to receive the text — \(appName) produced no usable window. Nothing was dispatched."))
                }
                return finish(.blocked("No usable window exists in \(appName). Nothing was dispatched."))
            }

            // ── Observe: window elements (+ browser page when bound). The
            // screenshot rides along only while pixel lanes need the image
            // coordinate space it defines. A re-pin settle probe younger
            // than two seconds stands in for a fresh read — it IS a fresh
            // observation of the same window, already paid for.
            let observeStart = Date()
            var snapshot: JSONValue?
            if let seeded = seededObservation, seeded.wid == wid,
               Date().timeIntervalSince(seeded.at) < 2 {
                snapshot = seeded.snapshot
            }
            seededObservation = nil
            if snapshot == nil {
                do {
                    snapshot = try await call("get_window_state", [
                        "pid": .number(Double(resolvedPID)), "window_id": .number(Double(wid)),
                        "include_screenshot": .bool(!pixelArmed.isEmpty), "max_elements": .number(200)])
                } catch let error as DriverConnectionError {
                    // A vanished window is not a transport failure. For a
                    // close/quit goal it IS the done evidence; for anything
                    // else it's a honest blocked, or a re-pin when other
                    // windows of the app remain.
                    guard Self.windowVanished(error) else { throw error }
                    if let outcome = try await vanishedWindowOutcome(
                        pid: resolvedPID, goal: task.goal, appName: appName,
                        ledger: &ledger, windowID: &windowID) {
                        return outcome
                    }
                    continue
                }
            }
            phases["observe_ms"] = Date().timeIntervalSince(observeStart) * 1000
            guard let snapshot else { continue }  // unreachable — observe always sets or continues
            let elements = snapshot["elements"]?.array ?? []
            let windowTitle = snapshot["window"]?["title"]?.string
                ?? snapshot["title"]?.string ?? snapshot["window_title"]?.string ?? ""
            // tree_markdown carries static text the driver filters out of
            // `elements` — a calculator's display, a terminal's scrollback.
            // That is real observed evidence, not a replayed claim, and it
            // needs no screenshot. Menu chrome is filtered out so a stale
            // menu label can never pose as window content.
            let windowText = Self.windowStaticTexts(
                markdown: snapshot["tree_markdown"]?.string ?? "").joined(separator: "\n")
            let windowTextDigest = String(windowText.prefix(3000))

            if let proof = pendingInsertProof, !proof.text.isEmpty {
                func reads(_ element: JSONValue) -> Bool {
                    element["value"]?.string?.contains(proof.text) == true
                        || element["label"]?.string?.contains(proof.text) == true
                }
                let target = proof.index.flatMap { i in
                    elements.first { $0["element_index"]?.integer == i } }
                // A positional target that doesn't read the text proves
                // nothing — the broad scan still runs before the proof
                // gives up (the text may have landed in a sibling field).
                let hit = target.flatMap { reads($0) ? $0 : nil }
                    ?? elements.first(where: { reads($0) })
                if let hit {
                    let label = hit["label"]?.string ?? hit["title"]?.string ?? "the field"
                    recordPostcondition(.resultObserved, "The inserted text is visible in \(label).",
                                        appName: appName, bundleID: bundleID,
                                        processID: resolvedPID, windowID: wid)
                    modelHistory.append(.object(["observation": .string(
                        "Verified: the inserted text now reads back from \(label).")]))
                    pendingInsertProof = nil
                } else if windowText.localizedCaseInsensitiveContains(proof.text) {
                    recordPostcondition(.resultObserved, "The inserted text is visible in \(appName)'s window content.",
                                        appName: appName, bundleID: bundleID,
                                        processID: resolvedPID, windowID: wid)
                    modelHistory.append(.object(["observation": .string(
                        "Verified: the inserted text is visible in the window's text content.")]))
                    pendingInsertProof = nil
                } else if !visualParseTried {
                    // Pixel-only surfaces (a terminal's scrollback, a
                    // calculator display) hold no AX text — one bounded
                    // visual read proves the landing before the model may
                    // retype the payload into the same place.
                    visualParseTried = true
                    let texts = await readVisualTexts(pid: resolvedPID, wid: wid)
                    if !texts.isEmpty { visualTexts = texts }
                    let needle = String(proof.text.prefix(24))
                    if texts.contains(where: {
                        $0.localizedCaseInsensitiveContains(proof.text)
                            || $0.localizedCaseInsensitiveContains(needle) }) {
                        recordPostcondition(.resultObserved, "The inserted text is visible on screen.",
                                            appName: appName, bundleID: bundleID,
                                            processID: resolvedPID, windowID: wid)
                        modelHistory.append(.object(["observation": .string(
                            "Verified: the inserted text is visible on screen.")]))
                        pendingInsertProof = nil
                    }
                }
            }

            var tabs: [JSONValue] = []
            var pageRefs: [JSONValue] = []
            var browserPage: JSONValue = .null
            if isBrowser {
                let browserStart = Date()
                let page = try await boundBrowser(pid: &resolvedPID, wid: &wid,
                                                  target: &browserTarget, shownTab: &browserShownTab,
                                                  bindingUpgradeTried: &bindingUpgradeTried)
                windowID = wid
                pid = resolvedPID
                tabs = page.tabs; pageRefs = page.refs; browserPage = page.state
                // Deferred navigation proof: a dispatched browser_navigate
                // whose destination wasn't yet visible is verified (or
                // honestly missed) by THIS read instead of a poll loop.
                if let pending = pendingNavigation {
                    if let pageURL = Self.browserPageURL(browserPage) {
                        if pageURL.localizedCaseInsensitiveContains(pending.needle) {
                            pendingNavigation = nil
                            pendingNavigationMisses = 0
                            recordPostcondition(.resultObserved,
                                                "The page navigated to \(pending.needle).",
                                                appName: appName, bundleID: bundleID,
                                                processID: resolvedPID, windowID: wid)
                            modelHistory.append(.object(["observation": .string(
                                "Verified: the page now shows \(pending.needle).")]))
                        } else {
                            pendingNavigationMisses += 1
                            if pendingNavigationMisses >= 2 {
                                pendingNavigation = nil
                                modelHistory.append(.object(["observation": .string(
                                    "The navigation to \(pending.needle) did not land — the page still shows \(pageURL). Re-dispatch only if it is still needed.")]))
                            }
                        }
                    }
                    // No readable url this step (transitional/unbound):
                    // keep armed; the next read resolves it.
                }
                phases["browser_ms"] = Date().timeIntervalSince(browserStart) * 1000
            }

            // The observation's content fingerprint marks states the run
            // has already seen: a re-picked identical action landing in a
            // seen state is repetition, not progress — the difference
            // between a click the window ignored and one it answered.
            let fingerprint = Self.observationFingerprint(
                elements: elements, title: windowTitle, tabs: tabs,
                refs: pageRefs, browserURL: Self.browserPageURL(browserPage),
                staticText: windowTextDigest)
            let revisitedState = !seenFingerprints.insert(fingerprint).inserted

            // ── Candidates: flat, from this observation only. deny[] pass 1:
            // a denied label never becomes an offered candidate.
            var lanes: [String: Lane] = [:]
            var criteria: [String: String?] = [:]
            var laneText: [String: String] = [:]
            /// Element-stable identity per offered lane — survives
            /// re-snapshot token/index rotation so re-pick and failure
            /// memory follow the control, not the slot it sits in.
            var laneSig: [String: String] = [:]
            func offer(_ lane: Lane, _ description: String, text: String? = nil,
                       element: JSONValue? = nil) {
                lanes[lane.id] = lane; criteria[lane.id] = description
                if let text { laneText[lane.id] = text }
                laneSig[lane.id] = Self.laneIdentity(lane, element: element)
            }
            var elementByIndex: [Int: JSONValue] = [:]
            for element in elements {
                if let index = element["element_index"]?.integer { elementByIndex[index] = element }
            }
            let frontmost = isFrontmostApp(resolvedPID)
            var interactive = 0
            var elementCandidates = 0
            var textLaneOffered = false
            for element in elements {
                guard elementCandidates < Self.maximumElementCandidates else { break }
                let index = element["element_index"]?.integer ?? -1
                let token = element["element_token"]?.string ?? String(index)
                let role = element["role"]?.string ?? ""
                let label = element["label"]?.string ?? element["title"]?.string ?? ""
                guard index >= 0, !role.isEmpty else { continue }
                if element["enabled"] == .bool(false) { continue }
                let isInteractive = Self.textRoles.contains(role)
                    || Self.clickRoles.contains(role) || Self.valueRoles.contains(role)
                if isInteractive { interactive += 1 } else { continue }
                if Self.isDenied(label, deny: task.deny) { continue }
                elementCandidates += 1
                if Self.textRoles.contains(role) {
                    textLaneOffered = true
                    offer(.typeIntoElement(token: token, index: index),
                          "Type the supplied text into \(role) \"\(label)\"",
                          text: Self.elementText(element), element: element)
                    // Two equivalent fill lanes split the judge's confidence
                    // below the act threshold — an AX overwrite only earns an
                    // offer once faithful typing has already failed.
                    // Failure memory keys on the element's own signature —
                    // role + label + frame — not bare index: element_index
                    // is positional per read, so a reshuffled tree must
                    // neither offer AX overwrite on a different element now
                    // sitting at that slot nor lose it for the same element
                    // that moved.
                    if failedLaneIDs.contains(Self.laneIdentity(
                        .typeIntoElement(token: token, index: index), element: element)) {
                        offer(.setValue(token: token, index: index),
                              "Set the value of \(role) \"\(label)\" to the supplied text",
                              text: Self.elementText(element), element: element)
                    }
                } else if Self.menuRoles.contains(role) {
                    // A menu item lives outside every window — an element
                    // click on it can only fail with element_outside_target_
                    // window. Menu invocation is the only honest lane, and
                    // only while the app is frontmost with a resolved path.
                    if frontmost, let path = Self.menuPath(for: index, in: elementByIndex),
                       path.allSatisfy({ !Self.isDenied($0, deny: task.deny) }) {
                        offer(.invokeMenu(path: path, index: index),
                              "Invoke the \"\(path.joined(separator: " → "))\" menu item",
                              text: Self.elementText(element), element: element)
                    }
                } else {
                    offer(.clickElement(token: token, index: index),
                          "Click \(role) \"\(label)\"", text: Self.elementText(element),
                          element: element)
                    if Self.valueRoles.contains(role) {
                        offer(.setValue(token: token, index: index),
                              "Set the value of \(role) \"\(label)\"", text: Self.elementText(element),
                              element: element)
                    }
                }
            }
            // Pixel-click rungs armed by the driver's own escalation signal.
            // A read where the element is gone or relabeled counts a miss —
            // two misses disarms the rung so the screenshot tax stops.
            for index in pixelArmed.keys.sorted() {
                guard let armed = pixelArmed[index] else { continue }
                let element = elementByIndex[index]
                let label = element?["label"]?.string ?? element?["title"]?.string ?? ""
                guard let element, label == armed.label else {
                    var decayed = armed
                    decayed.misses += 1
                    pixelArmed[index] = decayed.misses >= 2 ? nil : decayed
                    continue
                }
                guard !Self.isDenied(label, deny: task.deny),
                      let point = Self.pixelPoint(of: element, in: snapshot) else { continue }
                offer(.pixelClick(token: element["element_token"]?.string ?? String(index),
                                  index: index, x: point.x, y: point.y),
                      "Pixel-click \"\(label)\" at its observed center",
                      text: Self.elementText(element), element: element)
            }
            // Deny gates key names too — "delete" must not remain
            // reachable via the keyboard when the button is denied. Once the
            // driver reports window ambiguity, dispatch re-raises the bound
            // window and re-verifies frontmost before foreground delivery —
            // so a keystroke is never aimed at a window the driver could not
            // pin. A raise is honest for a foreground task, or while the app
            // is already frontmost; a background task whose app sits behind
            // gets no window-input lanes at all rather than stealing the
            // user's foreground.
            // A text payload with no writable element still lands in one
            // dispatch: the window-level lane types at the target's focus —
            // Calculator's button field, a terminal prompt — rather than
            // approximating the text with per-key or per-button presses.
            let windowInputAllowed = !windowInputAmbiguous || task.foreground || frontmost
            if !task.values.isEmpty, !textLaneOffered, windowInputAllowed {
                let preview = task.values.values.sorted()
                    .map { String($0.prefix(40)) }.joined(separator: ", ")
                offer(.typeIntoWindow,
                      "Type the supplied text \"\(preview)\" at the window's keyboard focus in one action")
            }
            if windowInputAllowed {
                for key in Self.keyNames where !Self.isDenied(key, deny: task.deny) {
                    offer(.pressKey(key), "Press \(key)")
                }
                for chord in Self.hotkeyChords where !Self.isDenied(chord.joined(separator: "+"), deny: task.deny) {
                    offer(.hotkey(chord), "Press \(chord.joined(separator: "+"))")
                }
            }
            for direction in ["up", "down", "left", "right"] where !Self.isDenied(direction, deny: task.deny) {
                offer(.scroll(direction), "Scroll \(direction)")
            }
            if isBrowser {
                if windowInputAllowed, !Self.isDenied("new tab", deny: task.deny) { offer(.newTab, "Open a new browser tab") }
                let navURL = CuaActionCatalog.explicitBrowserNavigationURL(in: task.goal)
                if let navURL, !Self.isDenied(navURL, deny: task.deny) { offer(.navigate(navURL), "Navigate the tab to \(navURL)") }
                for ref in pageRefs.prefix(20) {
                    guard let refID = ref["ref"]?.string ?? ref["id"]?.string else { continue }
                    let label = ref["label"]?.string ?? ref["text"]?.string ?? ""
                    if Self.isDenied(label, deny: task.deny) { continue }
                    offer(.browserClick(ref: refID), "Click page element \"\(label)\"", text: label)
                    offer(.browserType(ref: refID), "Type the supplied text into page field \"\(label)\"", text: label)
                }
                if browserTarget != nil, !Self.isDenied("dialog", deny: task.deny) {
                    offer(.browserDialog(accept: true), "Accept the open JavaScript dialog on this page")
                    offer(.browserDialog(accept: false), "Dismiss the open JavaScript dialog on this page")
                }
            }
            offer(.done, "The request is fully satisfied by the observed state")
            offer(.stuck, "The request cannot be completed from here; stop honestly")

            // Lanes the model re-picked past the bound stay out of the
            // offer set — matched on the element signature (survives
            // token/index rotation) and on the lane id + text pair
            // (survives frame jitter while the slot stays put), so a
            // re-snapshotted control cannot slip the ban and a stranger
            // landing on the slot cannot inherit it.
            for id in lanes.keys.sorted()
            where rePickBanned.contains(laneSig[id] ?? id)
                || rePickBanned.contains(id + "|" + (laneText[id] ?? "")) {
                lanes.removeValue(forKey: id)
                criteria.removeValue(forKey: id)
                laneText.removeValue(forKey: id)
                laneSig.removeValue(forKey: id)
            }

            // ── Deterministic done, every step: a success_contains claim
            // readable in this observation's corpus is proven evidence —
            // no model call may spend itself re-deciding it, and a model
            // done claim rides the same corpus below. Gated on the pending
            // navigation (a stale corpus must not satisfy a destination
            // claim) and on the create-scope baseline veto.
            let corpus = Self.observedCorpus(elements: elements, title: windowTitle,
                                             tabs: tabs, facts: observedPostconditions,
                                             visualTexts: visualTexts,
                                             staticText: windowText)
            // A produced pin already proves the structural half of a
            // create goal — "new document" is verified by the window
            // existing, never by window text that could contain the
            // words. Only user-named content (a title, a body) still
            // gates on the observed corpus.
            let producedPin = task.scope == .create && !baselineWindowIDs.contains(wid)
            let createVetoed = task.scope == .create && baselineWindowIDs.contains(wid)
            let claimsMatched = !task.successContains.isEmpty
                && task.successContains.contains { claim in
                    let lowered = claim.lowercased()
                    return corpus.contains(lowered)
                        || (producedPin && Self.isProducedArtifactClaim(lowered)) }
            if claimsMatched, pendingNavigation == nil, !createVetoed {
                recordPostcondition(.resultObserved, "Observed the requested outcome in \(appName).",
                                    appName: appName, bundleID: bundleID,
                                    processID: resolvedPID, windowID: windowID)
                ledger.append("done — the requested outcome is visible in \(appName)")
                return finish(.done)
            }

            // ── Shortlist: junk lanes sink typed-classifier confidence —
            // the offered set is trimmed to the plausible few before the
            // judge sees it. The single-action bypass is counted BEFORE
            // the trim: it means "the window offers exactly one action",
            // never "the shortlist left one" — a trimmed-away lane must
            // not turn the loop into a judge-free dispatcher.
            let singleActionID: String? = {
                let actionLanes = lanes.filter { $0.key != "done" && $0.key != "stuck" }
                return actionLanes.count == 1 ? actionLanes.keys.first : nil
            }()
            (lanes, criteria, laneText) = Self.shortlist(
                lanes: lanes, criteria: criteria, laneText: laneText,
                goal: task.goal, values: task.values)

            // A caller-supplied payload needs a live surface to land in —
            // with nothing interactive there is nowhere to put it. With no
            // payload the judge still sees done/stuck/keyboard lanes, so an
            // empty window can honestly satisfy or honestly block the goal.
            if interactive == 0 && pageRefs.isEmpty && !task.values.isEmpty {
                // A mutation (typed text, pressed Return) can blank the AX
                // tree for a beat while the app re-renders — Spotify after
                // a search submit is exactly this. One bounded re-read
                // before honestly handing back.
                if !modelHistory.isEmpty, emptyReads == 0 {
                    emptyReads = 1
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
                return finish(.handedBack(.noInteractiveElements))
            }
            if interactive > 0 { emptyReads = 0 }

            // ── Single-action bypass: exactly one offered action lane (the
            // done/stuck sentinels don't count) makes the model pick
            // deterministic — synthesize the pick and fall through the same
            // dispatch path. Done is already checked deterministically
            // above on every step. A fill pick is only deterministic with
            // exactly one supplied value — an ambiguous field→value binding
            // still goes through the judge. If the shortlist trimmed the
            // sole lane away the judge gets the (sentinel-only) list.
            var synthesizedPick: [String: Answer]?
            if let onlyID = singleActionID, let only = lanes[onlyID],
               !only.needsFillText || task.values.count == 1 {
                synthesizedPick = ["next": .choice(choice: onlyID, confidence: 1, probabilities: [:])]
                if only.needsFillText, let key = task.values.keys.first {
                    synthesizedPick?["fill"] = .choice(choice: key, confidence: 1, probabilities: [:])
                }
                ledger.append("single lane — dispatched without a judge call")
            }

            var fillChoices: [String: String?] = [
                "unavailable": "The chosen field needs text the caller did not supply in values."]
            for key in task.values.keys.sorted() {
                fillChoices[key] = "The supplied value for \"\(key)\"."
            }
            let blockedChoices: [String: String?] = [
                "authentication": "A login, sign-in, or account wall blocks the goal.",
                "dialog": "A modal dialog or prompt blocks the goal.",
                "permission": "A system permission or consent prompt blocks the goal.",
                "missing_info": "Information the caller did not supply is required.",
                "other": "Something else prevents progress."]

            // ── One model call: action + fill + done-evidence + blocked
            // reason ride along, mapped onto a StepJudgment.
            var mergedState: [String: JSONValue] = [
                "request": .string(task.goal),
                "previous_context": .string(task.previousContext ?? ""),
                "scope": .string(task.scope.rawValue),
                "window_produced_by_task": .bool(!baselineWindowIDs.contains(wid)),
                "app": .string(appName), "window_title": .string(windowTitle),
                "selected_window_id": .number(Double(wid)),
                "values_available": .array(task.values.keys.sorted().map { .string($0) }),
                "success_contains": .array(task.successContains.map { .string($0) }),
                "verified_facts": .array(observedPostconditions.suffix(8).map { .string($0.evidence) }),
                "elements": .array(elements.prefix(80).map { Self.compactElement($0, deny: task.deny) }),
                "tabs": .array(tabs.map(CuaBrowserTarget.compactTab)),
                "browser_page": Self.projectedBrowserPage(browserPage, refs: pageRefs, tabs: tabs),
                "history": .array(modelHistory.suffix(10))]
            if !visualTexts.isEmpty {
                mergedState["visual_texts"] = .array(visualTexts.map { .string($0) })
            }
            if !windowTextDigest.isEmpty {
                mergedState["window_text"] = .string(windowTextDigest)
            }
            let questions: [String: Question] = [
                "next": .choice(
                    instructions: "Choose the single next action for this step. When the request supplies text and an action delivers it in one step, prefer that over sequences of small element actions — clicking each key or button one at a time is slower and error-prone. For a feature the request names (a search field, a button, a menu item), act on that element directly — a chorded shortcut means different things in different apps, so use one only when no element offers the feature. Pick done only when the observed state alone proves the exact request is satisfied. Pick stuck only when no action can progress. Action ids refer to the offered list; never invent one.",
                    criteria: criteria),
                "fill": .choice(
                    instructions: "Answered only when `next` types or sets a field: which supplied value belongs in that field? Pick the matching value key, or unavailable when the field needs text the caller did not supply.",
                    criteria: fillChoices),
                "doneEvidence": .choice(
                    instructions: "Answered only when `next` is done: does the observed state (element values, tab urls/titles, window_text, verified_facts, visual_texts, success_contains) prove the exact requested outcome? A success_contains string appearing in the observed text IS proof — for a compute request, the expected result string is listed there. History proves steps ran, never that the request succeeded.",
                    criteria: ["proven": "Readable evidence shows the exact requested outcome.",
                               "unproven": "Nothing readable proves it, or the state contradicts it."]),
                "blockedReason": .choice(
                    instructions: "Answered only when `next` is stuck: what stops progress?",
                    criteria: blockedChoices)]
            let answers: [String: Answer]
            let nextID: String
            if let synthesizedPick {
                answers = synthesizedPick
                nextID = singleActionID ?? ""
            } else {
                let judgeStart = Date()
                do {
                    answers = try await judge(.object(mergedState), questions)
                } catch {
                    // One bounded retry — the judge call is the most
                    // failure-prone hop in the loop; a blip must not kill
                    // an otherwise healthy run. Only transient faults earn
                    // it: a 4xx or a malformed response fails the same way
                    // twice, so it throws through immediately.
                    guard Self.retryableJudgeFault(error) else { throw error }
                    try? await Task.sleep(for: .milliseconds(300))
                    answers = try await judge(.object(mergedState), questions)
                }
                phases["judge_ms"] = Date().timeIntervalSince(judgeStart) * 1000
                do {
                    nextID = try JevSelection.read(answers["next"], allowed: Set(criteria.keys))
                } catch {
                    return finish(.handedBack(.untrustedAnswer))
                }
            }
            guard let lane = lanes[nextID] else {
                return finish(.handedBack(.untrustedAnswer))
            }
            // deny[] pass 2: re-check the answer's full element text before
            // dispatch — a model that reaches for denied content stops the run.
            if let text = laneText[nextID], Self.isDenied(text, deny: task.deny) {
                return finish(.handedBack(.untrustedAnswer))
            }
            var judgment = StepJudgment(
                elementToken: lane.elementToken, kind: lane.stepKind,
                confidence: (answers["next"].flatMap { a -> Double? in
                    if case .choice(_, let confidence, _) = a { return confidence }
                    return nil }) ?? 0)
            if case .done = lane { judgment.done = true }
            if case .stuck = lane {
                judgment.blocked = (try? JevSelection.read(answers["blockedReason"], allowed: Set(blockedChoices.keys))) ?? "other"
            }
            if lane.needsFillText, let fillAnswer = answers["fill"],
               case .choice(let fill, _, _) = fillAnswer {
                judgment.fillTokens = [fill]
            }
            if judgment.kind != .none && judgment.confidence < 0.5 {
                // A hesitant pick is a signal to look again, not yet to
                // give up: settle once and re-observe — the next read may
                // resolve the ambiguity the model stared at. A second
                // consecutive hesitant pick hands back the real choice.
                lowConfidenceStreak += 1
                if lowConfidenceStreak < 2 {
                    try? await Task.sleep(for: .milliseconds(400))
                    continue
                }
                var optionIDs: [String] = []
                if case .choice(_, _, let probabilities) = answers["next"] {
                    optionIDs = probabilities
                        .filter { $0.key != "done" && $0.key != "stuck" && criteria[$0.key] != nil }
                        .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                        .map { $0.key }
                }
                var options = optionIDs.prefix(3).compactMap { criteria[$0] ?? nil }
                if options.isEmpty {
                    options = lanes.values
                        .filter { $0.elementIndex != nil }
                        .sorted { $0.id < $1.id }
                        .prefix(3).compactMap { criteria[$0.id] ?? nil }
                }
                return finish(.handedBack(.needsChoice(options: options)))
            }
            lowConfidenceStreak = 0

            // ── done: gate on observed evidence, not on the claim. The
            // corpus, produced-pin and baseline veto are this step's own —
            // computed once above and shared with the every-step check.
            if judgment.done {
                let evidence = (try? JevSelection.read(answers["doneEvidence"], allowed: ["proven", "unproven"])) == "proven"
                let postUnmet = !task.successContains.isEmpty
                    && !task.successContains.contains { claim in
                        let lowered = claim.lowercased()
                        return corpus.contains(lowered)
                            || (producedPin && Self.isProducedArtifactClaim(lowered)) }
                if !evidence || postUnmet || createVetoed {
                    unprovenDone += 1
                    guard unprovenDone < Self.maximumUnprovenDone else {
                        return finish(.blocked(createVetoed
                            ? "A new document window was requested, but the task could not be completed: \(appName)'s observed state never produced one. Nothing is claimed as success."
                            : "The request's outcome could not be proven from \(appName)'s observed state. Completed steps are not claimed as success; inspect the app before retrying."))
                    }
                    // One bounded visual read arms the next round: pixel-only
                    // surfaces (Calculator's display, terminal scrollback)
                    // have no AX text for the corpus, so the same claim can
                    // only ever be unproven without this evidence.
                    if !visualParseTried {
                        visualParseTried = true
                        let texts = await self.readVisualTexts(pid: resolvedPID, wid: wid)
                        if !texts.isEmpty {
                            visualTexts = texts
                            modelHistory.append(.object(["observation": .string(
                                "A visual read of the window shows: \(texts.prefix(8).joined(separator: "; ")).")]))
                        }
                    }
                    modelHistory.append(.object(["observation": .string(
                        "The completion claim was rejected: its evidence is not observable yet. Continuing — actions already dispatched took effect; do not repeat them unless fresh evidence shows they did not land.")]))
                    ledger.append("done claim rejected — evidence not observable")
                    continue
                }
                recordPostcondition(.resultObserved, "Observed the requested outcome in \(appName).",
                                    appName: appName, bundleID: bundleID,
                                    processID: resolvedPID, windowID: windowID)
                ledger.append("done — the requested outcome is visible in \(appName)")
                return finish(.done)
            }
            if let reason = judgment.blocked {
                return finish(.blocked("The task could not be completed from \(appName)'s current state (\(reason)). Nothing further was dispatched."))
            }

            // ── Fill resolution: Jev selected the field and the value key;
            // the literal text is always the caller's. A field the caller
            // supplied nothing for ends the run asking for that label.
            var dispatchText: String?
            if lane.needsFillText {
                let pick: String
                do {
                    pick = try JevSelection.read(answers["fill"], allowed: Set(fillChoices.keys))
                } catch {
                    return finish(.handedBack(.untrustedAnswer))
                }
                guard pick != "unavailable", let text = task.values[pick] else {
                    let fieldLabel = elements.first(where: {
                        $0["element_index"]?.integer == lane.elementIndex })?["label"]?.string
                        ?? laneText[nextID] ?? "the field"
                    return finish(.needsText(fieldLabel: fieldLabel))
                }
                dispatchText = text
            }

            // ── Dispatch. Consequential descriptions ask the user once —
            // the vocabulary boundary carries the safety, not a per-action
            // judge. A transient driver fault is an observation, not a
            // verdict: the next observe→decide pass re-reads real state and
            // chooses again — never a blind replay of a mutation that may
            // have landed. Consecutive faults still bound out honestly.
            let description = criteria[lane.id].flatMap { $0 } ?? lane.id
            if CuaTaskAgent.requiresRiskJudgment(goal: task.goal, actionDescription: description) {
                guard let approve, try await approve("\(appName)\n\(description)") else {
                    throw DriverConnectionError.refused("The operation or its authorization is unclear: \(description). Nothing was dispatched.")
                }
            }
            // Foreground input lands wherever focus is — honest only while
            // the bound window is frontmost, so the pinned window is raised
            // and frontmost re-verified before each delivery. Element lanes
            // never reach this: a raise happens only when the chosen action
            // genuinely needs window-level input the driver refused to pin.
            // A raise that cannot verify frontmost is a dispatch failure,
            // never a blind keystroke into the wrong app.
            let foregroundInput = windowInputAmbiguous && lane.usesWindowInput
            // A fill or submit replayed verbatim is never intent — typing
            // the same text twice appends it, Return pressed twice can skip
            // past the result — so it is skipped, never re-dispatched. Any
            // other lane earns one retry, but a third consecutive identical
            // dispatch landing in an already-seen state is blind repetition:
            // the lane leaves the offered set and the model must pick
            // something else or honestly stop. Identity rides the element
            // signature, so a re-snapshotted token or a reshuffled index
            // cannot slip the same control past the bound.
            let dispatchKey = (laneSig[nextID] ?? lane.id) + "|" + (dispatchText ?? "")
            if lastDispatchKey == dispatchKey {
                let replayGuarded = lane.needsFillText || lane.isSubmitKey
                if replayGuarded || (revisitedState && identicalStreak >= 2) {
                    if replayGuarded { rePickSkips[dispatchKey, default: 0] += 1 }
                    if !replayGuarded || (rePickSkips[dispatchKey] ?? 0) >= 2 {
                        rePickBanned.insert(laneSig[nextID] ?? nextID)
                        rePickBanned.insert(nextID + "|" + (laneText[nextID] ?? ""))
                        lanes.removeValue(forKey: nextID)
                        criteria.removeValue(forKey: nextID)
                        laneText.removeValue(forKey: nextID)
                        laneSig.removeValue(forKey: nextID)
                        modelHistory.append(.object(["action": .string(description),
                            "observation": .string(replayGuarded
                                ? "The identical action was re-picked after its effect already ran — it is removed from the offered set. Choose a different action or report honestly."
                                : "The identical action already ran twice and the window still shows a state this run already observed — it is removed from the offered set. Choose a different action or report honestly.")]))
                        ledger.append("\(description) — removed: identical action re-picked")
                    } else {
                        modelHistory.append(.object(["action": .string(description),
                            "observation": .string("The identical action already ran — its effect is in this observation. Do not repeat it.")]))
                        ledger.append("\(description) — skipped: identical to the previous step")
                    }
                    continue
                }
            }
            let result: JSONValue
            do {
                Self.log.notice("agent_step \"\(task.goal, privacy: .public)\" -> \(description, privacy: .public)")
                let dispatchStart = Date()
                // Foreground delivery holds the focus lease across the
                // WHOLE raise→verify→dispatch sequence — the lease means
                // nothing if the keystroke ships after another lane took
                // the front app back. A raise that cannot verify frontmost
                // is a dispatch failure, never a blind keystroke.
                let outcome = try await leased(focus: foregroundInput) { () throws -> JSONValue? in
                    if foregroundInput {
                        let raised = try? await self.call("bring_to_front",
                            ["pid": .number(Double(resolvedPID)), "window_id": .number(Double(wid))])
                        guard raised?["activated"] == .bool(true), self.isFrontmostApp(resolvedPID) else {
                            return nil
                        }
                    }
                    return try await self.dispatch(lane, pid: resolvedPID, wid: wid, goal: task.goal,
                                                   text: dispatchText,
                                                   browserTarget: browserTarget, shownTab: browserShownTab,
                                                   tabs: tabs, tabsBaseline: &tabsBaseline,
                                                   newTabRequested: &newTabRequested,
                                                   foregroundInput: foregroundInput)
                }
                phases["dispatch_ms"] = Date().timeIntervalSince(dispatchStart) * 1000
                guard let outcome else {
                    dispatchFailures += 1
                    modelHistory.append(.object(["action": .string(description),
                        "observation": .string("The bound window could not be brought to the front; the input was not sent.")]))
                    ledger.append("\(description) — not dispatched: window is not frontmost")
                    guard dispatchFailures < Self.maximumDispatchFailures else {
                        return finish(.blocked("The bound window could not be brought to the front for keyboard input. Nothing further was dispatched."))
                    }
                    continue
                }
                result = outcome
                dispatchFailures = 0
            } catch let error as DriverConnectionError {
                if case .toolRefused(_, let code, _) = error, code.contains("consent") {
                    return finish(.blockedByConsent(code))
                }
                if case .refused(let message) = error {
                    return finish(.blocked(message))
                }
                if case .timedOut = error, laneMutates(lane) {
                    // The mutation's response was lost — the effect may
                    // have landed. Read the pinned target once so the
                    // uncertainty report carries fresh evidence, then
                    // stop: a lost response is never re-dispatched blindly
                    // and never claimed as success.
                    var evidence: [String: JSONValue] = [:]
                    if let fresh = try? await call("get_window_state", [
                        "pid": .number(Double(resolvedPID)), "window_id": .number(Double(wid)),
                        "include_screenshot": .bool(false), "max_elements": .number(200)]) {
                        let freshElements = fresh["elements"]?.array ?? []
                        evidence["window_title"] = .string(fresh["window"]?["title"]?.string
                            ?? fresh["title"]?.string ?? fresh["window_title"]?.string ?? "")
                        evidence["element_count"] = .number(Double(freshElements.count))
                        evidence["element_labels"] = .array(freshElements.prefix(5).compactMap {
                            ($0["label"]?.string ?? $0["title"]?.string).map { .string($0) } })
                    }
                    throw CuaUncertainOutcome(tool: lane.id, result: .object(evidence))
                }
                if case .toolRefused(_, let code, _) = error,
                   code == "same_pid_keyboard_ambiguity", lane.usesWindowInput {
                    windowInputAmbiguous = true
                    let explanation = task.foreground || isFrontmostApp(resolvedPID)
                        ? "App-level input could not be pinned to the window in the background; the next window-input action raises the bound window to the front and delivers it there instead."
                        : "App-level input could not be pinned to the window and this task must stay in the background; window-level key and focus-typing actions are no longer available — use element actions or report honestly."
                    modelHistory.append(.object(["action": .string(description),
                        "observation": .string(explanation)]))
                    continue
                }
                failedLaneIDs.insert(laneSig[nextID] ?? lane.id)
                dispatchFailures += 1
                modelHistory.append(.object(["action": .string(description),
                    "observation": .string("Dispatch failed: \(error.localizedDescription). The effect may not have happened — re-check before acting.")]))
                ledger.append("\(description) — dispatch failed: \(error.localizedDescription)")
                guard dispatchFailures < Self.maximumDispatchFailures else {
                    return finish(.blocked(error.localizedDescription))
                }
                continue
            } catch let outcome as CuaUncertainOutcome {
                // "Partial" is an observation, not a verdict — the typed
                // text may have landed. Re-observe once (with the insert
                // proof armed) before honestly blocking; never replay.
                if lane.needsFillText { pendingInsertProof = (lane.elementIndex, dispatchText ?? "") }
                // The AX overwrite fallback earns an offer once faithful
                // typing went uncertain — the same failure memory a hard
                // refusal builds.
                failedLaneIDs.insert(laneSig[nextID] ?? lane.id)
                uncertainPerDispatchKey[dispatchKey, default: 0] += 1
                uncertainTotal += 1
                modelHistory.append(.object(["action": .string(description),
                    "observation": .string("The driver reported an uncertain outcome — the effect may have landed. Verify against the fresh observation before repeating it.")]))
                ledger.append("\(description) — uncertain outcome; verifying before retry")
                guard (uncertainPerDispatchKey[dispatchKey] ?? 0) < Self.maximumUncertainPerDispatch,
                      uncertainTotal < Self.maximumUncertainTotal else {
                    return finish(.blocked("\(outcome.localizedDescription) Inspect \(appName) before retrying."))
                }
                continue
            }
            // An acknowledged cancellation stops the drive here — reads
            // after this point would only decorate a dead run, and any
            // later mutation is forbidden outright.
            try Task.checkCancellation()
            let postStart = Date()
            if case .typeIntoElement(_, let index) = lane {
                pendingInsertProof = (index, dispatchText ?? "")
            }
            if case .setValue(_, let index) = lane {
                pendingInsertProof = (index, dispatchText ?? "")
            }
            if case .typeIntoWindow = lane { pendingInsertProof = (nil, dispatchText ?? "") }
            if case .browserType = lane { pendingInsertProof = (nil, dispatchText ?? "") }
            identicalStreak = dispatchKey == lastDispatchKey ? identicalStreak + 1 : 1
            lastDispatchKey = dispatchKey
            // A landing dispatch clears its own uncertain count and every
            // stale re-pick skip — skips only bound CONSECUTIVE repeats.
            uncertainPerDispatchKey.removeValue(forKey: dispatchKey)
            rePickSkips.removeAll()
            let outcome = Self.effectSummary(result)
            modelHistory.append(.object(["action": .string(description),
                                         "observation": .string(outcome)]))
            ledger.append("\(description) → \(outcome)")
            progress("\(description) → \(outcome)")
            // A produced window outranks the baseline pin: exactly one new
            // onscreen window after a mutation becomes the pin — the new
            // document, dialog or sheet the action caused; two or more
            // stays ambiguous rather than guessed. The driver's own
            // new_window report settles it without a listing; otherwise the
            // list_windows poll only pays for itself when a create-scope
            // task could actually be proven by the produce — for every
            // other goal the poll is pure per-step latency. Registration
            // lags dispatch — the window server needs a beat to publish
            // the new document — so settle and re-list once when the first
            // snapshot shows nothing new.
            var producedID: Int?
            if lane.mayProduceWindow, !lane.needsFillText, baselineWindowIDs.contains(wid) {
                let reported = (result["new_window_ids"]?.array ?? []).compactMap { $0.integer }
                    + (result["new_windows"]?.array ?? []).compactMap { $0["window_id"]?.integer }
                let distinct = Array(Set(reported))
                if distinct.count == 1 {
                    producedID = distinct[0]
                } else if distinct.isEmpty, task.scope == .create {
                    producedID = await producedWindowID(pid: resolvedPID, excluding: baselineWindowIDs)
                }
            }
            if let newID = producedID {
                windowID = newID
                currentWindowID = newID
                wid = newID
                // The window id publishes before its content does — a
                // re-pinned read that arrives too early shows the judge an
                // empty shell and invites repeating the producing action.
                // Settle on a populated (or honestly empty) tree before
                // the next observation — which then consumes this read
                // instead of paying for another one.
                var probe: JSONValue?
                for _ in 0..<3 {
                    probe = try? await call("get_window_state", [
                        "pid": .number(Double(resolvedPID)), "window_id": .number(Double(newID)),
                        "include_screenshot": .bool(false), "max_elements": .number(50)])
                    if !(probe?["elements"]?.array ?? []).isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(400))
                }
                if let probe { seededObservation = (wid: newID, snapshot: probe, at: Date()) }
                // The produce is evidence, not a claim — record it so the
                // done-evidence question sees it in verified_facts.
                recordPostcondition(.resultObserved,
                                    "Task produced a new \(appName) window (id \(newID)).",
                                    appName: appName, bundleID: bundleID,
                                    processID: resolvedPID, windowID: newID)
            }
            // Driver honesty fields: a confirmed effect (or an explicit
            // verified readback) is proof; a suspected noop or a pixel
            // escalation arms the pixel rung for the next observation;
            // anything weaker is reported, never claimed.
            if Self.isProven(result) {
                recordPostcondition(.resultObserved, "Driver confirmed: \(description)",
                                    appName: appName, bundleID: bundleID,
                                    processID: resolvedPID, windowID: wid)
            }
            // A "foreground" escalation says pinned/background delivery
            // can't reach the target: window-input lanes escalate to the
            // raise→verify→foreground path; element lanes join the failure
            // memory so alternates (the AX overwrite rung) surface.
            if Self.escalatesToForeground(result) {
                if lane.usesWindowInput {
                    windowInputAmbiguous = true
                } else {
                    failedLaneIDs.insert(laneSig[nextID] ?? lane.id)
                }
            }
            if let index = lane.elementIndex, Self.escalatesToPixel(result),
               let element = elementByIndex[index] {
                pixelArmed[index] = (label: element["label"]?.string ?? element["title"]?.string ?? "",
                                     step: stepIndex, misses: 0)
            }
            phases["post_ms"] = Date().timeIntervalSince(postStart) * 1000
        }
        return finish(.maxSteps(history: ledger))
    }

    // MARK: - Drive-until helpers

    /// Driver codes that mean the window/app we were driving no longer
    /// exists — checked by code first (typed refusals), then the remote
    /// string for transports that only carry text.
    nonisolated static func windowVanished(_ error: DriverConnectionError) -> Bool {
        // The driver names the family (`window_id_not_found`,
        // `window_target_not_found`, `bring_to_front_pid_not_found`,
        // `app_not_running`, `px_window_not_found`…) — match the family,
        // not an exact-name list that ages out with every new tool.
        func vanished(_ text: String) -> Bool {
            let lowered = text.lowercased()
            return lowered.contains("not_found") || lowered.contains("not_running")
                || lowered.contains("invalid_window")
        }
        switch error {
        case .toolRefused(_, let code, _):
            return vanished(code)
        case .remote(let text), .refused(let text):
            return vanished(text)
        default:
            return false
        }
    }

    /// deny[] match — case-insensitive substring on the candidate's text.
    nonisolated static func isDenied(_ text: String, deny: [String]) -> Bool {
        let lowered = text.lowercased()
        return deny.contains { needle in
            let n = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !n.isEmpty && lowered.contains(n)
        }
    }

    /// All the text a candidate carries — deny's second pass checks beyond
    /// the offered label so a clean-titled element with denied content still
    /// cannot dispatch.
    private static func elementText(_ element: JSONValue) -> String {
        [element["label"]?.string, element["title"]?.string,
         element["description"]?.string, element["value"]?.string]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// The re-pick identity of a lane — what "the same action" means
    /// across re-snapshots. Element lanes key on the control's own
    /// signature (role + label + frame origin) plus the lane kind:
    /// element_index and element_token rotate between reads, so an
    /// identity that used them would let the same control slip a ban by
    /// moving slots — and would blame a different control that landed on
    /// the vacated one. Non-element lanes are already stable by id.
    private static func laneIdentity(_ lane: Lane, element: JSONValue?) -> String {
        func signature(_ element: JSONValue?) -> String {
            guard let element else { return lane.id }
            var sig = (element["role"]?.string ?? "") + "|"
                + (element["label"]?.string ?? element["title"]?.string ?? "")
            if let fx = num(element["frame"]?["x"]),
               let fy = num(element["frame"]?["y"]) {
                sig += "|\(Int(fx.rounded())),\(Int(fy.rounded()))"
            }
            return sig
        }
        switch lane {
        case .clickElement: return "click|" + signature(element)
        case .typeIntoElement: return "typeinto|" + signature(element)
        case .setValue: return "setvalue|" + signature(element)
        case .pixelClick: return "pixel|" + signature(element)
        case .invokeMenu(let path, _): return "menu|" + path.joined(separator: "\u{1F}")
        default: return lane.id
        }
    }

    /// The menu path of an AXMenuItem/AXMenuBarItem, walked up `parent_index`
    /// to the menu bar — invoke_menu resolves an exact path, and containers
    /// (AXMenu/AXMenuBar) carry no segment of their own.
    private static func menuPath(for index: Int, in elements: [Int: JSONValue]) -> [String]? {
        var segments: [String] = []
        var cursor = elements[index]
        var hops = 0
        while let element = cursor, hops < 12 {
            switch element["role"]?.string ?? "" {
            case "AXMenuBarItem", "AXMenuItem":
                let label = element["label"]?.string ?? element["title"]?.string ?? ""
                guard !label.isEmpty else { return nil }
                segments.append(label)
            case "AXMenuBar":
                return segments.isEmpty ? nil : segments.reversed()
            case "AXMenu":
                break
            default:
                return nil
            }
            cursor = element["parent_index"]?.integer.flatMap { elements[$0] }
            hops += 1
        }
        return segments.isEmpty ? nil : segments.reversed()
    }

    /// An element's frame center in the observation's screenshot pixel space —
    /// the coordinate frame `click` x/y reads against.
    private static func pixelPoint(of element: JSONValue, in snapshot: JSONValue) -> (x: Double, y: Double)? {
        guard let fx = Self.num(element["frame"]?["x"]),
              let fy = Self.num(element["frame"]?["y"]),
              let fw = Self.num(element["frame"]?["w"]),
              let fh = Self.num(element["frame"]?["h"]),
              let bx = Self.num(snapshot["window_bounds"]?["x"]),
              let by = Self.num(snapshot["window_bounds"]?["y"]),
              let bw = Self.num(snapshot["window_bounds"]?["width"]), bw > 0,
              let bh = Self.num(snapshot["window_bounds"]?["height"]), bh > 0,
              let sw = Self.num(snapshot["screenshot_width"]),
              let sh = Self.num(snapshot["screenshot_height"]) else { return nil }
        return ((fx + fw / 2 - bx) / bw * sw, (fy + fh / 2 - by) / bh * sh)
    }

    private static func num(_ value: JSONValue?) -> Double? {
        guard let value, case .number(let n) = value else { return nil }
        return n
    }

    /// The first real window in a driver listing — on-screen, titled
    /// preferred — matching the launch_app `windows[]` shape.
    private static func preferredWindow(in rows: [JSONValue]) -> Int? {
        let onscreen = rows.filter { $0["is_on_screen"] != .bool(false) }
        let titled = onscreen.filter { !($0["title"]?.string ?? "").isEmpty }
        return (titled.first ?? onscreen.first)?["window_id"]?.integer
    }

    /// Everything readable in this observation, for the success_contains
    /// postcondition check on a done claim. Observed state only — recorded
    /// postcondition evidence is our own synthesis and must not satisfy
    /// success_contains (it feeds the model via verified_facts instead).
    private static func observedCorpus(elements: [JSONValue], title: String,
                                       tabs: [JSONValue], facts: [CuaObservedPostcondition],
                                       visualTexts: [String] = [],
                                       staticText: String = "") -> String {
        var parts = [title]
        for element in elements {
            // Menu chrome is not window content — a "recent items" menu can
            // list a stale result and must not satisfy success_contains.
            if let role = element["role"]?.string, menuRoles.contains(role)
                || role == "AXMenu" || role == "AXMenuBar" || role == "AXMenuBarItem" { continue }
            for key in ["label", "title", "value", "description"] {
                if let text = element[key]?.string { parts.append(text) }
            }
        }
        for tab in tabs {
            for key in ["title", "url"] {
                if let text = tab[key]?.string { parts.append(text) }
            }
        }
        parts += visualTexts
        parts.append(staticText)
        return parts.joined(separator: "\n").lowercased()
    }

    /// A content fingerprint of the observation — what the window shows,
    /// sorted so positional reshuffles don't fake change. Element tokens
    /// and indices are excluded: they rotate between reads and would make
    /// every state look new. Compared across steps to tell "the action
    /// did something" from "the identical action produced nothing new" —
    /// a repeat landing in an already-seen state is blind repetition.
    private static func observationFingerprint(elements: [JSONValue], title: String,
                                               tabs: [JSONValue], refs: [JSONValue],
                                               browserURL: String?, staticText: String) -> String {
        var parts = [title, staticText]
        for element in elements {
            var entry = [element["role"]?.string, element["label"]?.string,
                         element["title"]?.string, element["value"]?.string,
                         element["description"]?.string]
                .compactMap { $0 }.joined(separator: "|")
            let frame = ["x", "y", "w", "h"].compactMap {
                num(element["frame"]?[$0]).map { String(Int($0)) }
            }.joined(separator: ",")
            if !frame.isEmpty { entry += "#" + frame }
            if let enabled = element["enabled"]?.bool {
                entry += enabled ? "+enabled" : "+disabled"
            }
            parts.append(entry)
        }
        for tab in tabs {
            parts.append("tab:" + (tab["title"]?.string ?? "")
                         + "@" + (tab["url"]?.string ?? ""))
        }
        for ref in refs.prefix(30) {
            parts.append("ref:" + (ref["label"]?.string ?? ref["text"]?.string ?? ""))
        }
        if let browserURL { parts.append("url:" + browserURL) }
        return parts.sorted().joined(separator: "\u{1F}")
    }

    /// Judge faults worth one bounded retry: transport blips, request
    /// timeouts and 5xx responses. A 4xx or a malformed payload fails the
    /// same way twice — throwing it through immediately is the honest move.
    private static func retryableJudgeFault(_ error: Error) -> Bool {
        guard let jev = error as? JevError else { return false }
        switch jev {
        case .transport: return true
        case .http(let status, _): return status == 408 || status >= 500
        case .decoding: return false
        }
    }

    /// The raw bound-browser state re-serialized for the model — url,
    /// title, any open dialog, the first page refs and the tab list. The
    /// raw payload carries DOM payloads and page text the typed classifier
    /// never needed.
    private static func projectedBrowserPage(_ state: JSONValue,
                                             refs: [JSONValue],
                                             tabs: [JSONValue]) -> JSONValue {
        guard state.object != nil else { return .null }
        var page: [String: JSONValue] = [
            "url": browserPageURL(state).map { .string($0) } ?? .null,
            "title": state["title"] ?? state["page"]?["title"] ?? .null,
            "tabs": .array(tabs.map(CuaBrowserTarget.compactTab)),
            "refs": .array(refs.prefix(30).map {
                .object(["ref": $0["ref"] ?? $0["id"] ?? .null,
                         "role": $0["role"] ?? .null,
                         "label": $0["label"] ?? $0["text"] ?? .null]) })]
        if let dialog = state["dialog"] ?? state["page"]?["dialog"] {
            page["dialog"] = dialog
        }
        return .object(page)
    }

    /// Words that carry no discriminative content when goal-matching lanes —
    /// request verbs ("click", "type") appear in every lane description, so
    /// keeping them would match everything.
    private static let shortlistStopwords: Set<String> = [
        "a", "an", "the", "to", "in", "on", "of", "for", "and", "or", "it",
        "its", "is", "be", "at", "by", "with", "that", "this", "my", "your",
        "you", "me", "please", "into", "from", "click", "type", "press",
        "set", "open", "go", "do", "make", "new", "supplied", "text"]

    /// Role-priority tier for an element lane — text surfaces beat click
    /// surfaces beat value writes beat menu items when nothing matches
    /// the goal and the floor must pick.
    private static func elementTier(_ lane: Lane) -> Int {
        switch lane {
        case .typeIntoElement: return 0
        case .clickElement, .pixelClick: return 1
        case .setValue: return 2
        case .invokeMenu: return 3
        default: return 9
        }
    }

    /// Trim the flat candidate list to the plausible few before the judge
    /// sees it: ~30 offered criteria keeps typed-classifier confidence
    /// above the act gate; a flat 100-option list does not. Terminal and
    /// browser lanes always stay; element lanes survive on goal-lexical
    /// match (a role-priority floor when nothing matches); keyboard and
    /// scroll lanes are offered only when the request or the element set
    /// calls for them. Pure — the same inputs always trim the same way.
    private static func shortlist(lanes: [String: Lane], criteria: [String: String?],
                                  laneText: [String: String], goal: String,
                                  values: [String: String])
        -> (lanes: [String: Lane], criteria: [String: String?], laneText: [String: String]) {
        func contentWords(_ text: String) -> Set<String> {
            Set(text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 2 && !shortlistStopwords.contains($0) })
        }
        let goalWords = contentWords(goal)
        var elementIDs: [String] = []
        var keyboardIDs: [String] = []
        var scrollIDs: [String] = []
        var keep: Set<String> = []
        for (id, lane) in lanes {
            if lane.elementIndex != nil { elementIDs.append(id); continue }
            switch lane {
            case .pressKey, .hotkey: keyboardIDs.append(id)
            case .scroll: scrollIDs.append(id)
            // done/stuck, browser dialog/click/type, newTab, navigate,
            // launchApp, typeIntoWindow — never trimmed.
            default: keep.insert(id)
            }
        }
        func ranked(_ ids: [String]) -> [String] {
            ids.sorted { a, b in
                let ta = elementTier(lanes[a] ?? .done), tb = elementTier(lanes[b] ?? .done)
                return ta == tb ? a < b : ta < tb
            }
        }
        // Goal-lexical element matches earn offers first; a zero-match
        // goal still gets a role-priority floor so the judge isn't
        // staring at sentinels alone.
        var goalMatched: [String] = []
        for id in elementIDs {
            let description = (criteria[id] ?? nil) ?? ""
            let text = description + " " + (laneText[id] ?? "")
            if !contentWords(text).isDisjoint(with: goalWords) { goalMatched.append(id) }
        }
        let keptElements = goalMatched.isEmpty
            ? Array(ranked(elementIDs).prefix(elementLaneFloor))
            : Array(ranked(goalMatched).prefix(maximumElementLanes))
        keep.formUnion(keptElements)
        // A caller-supplied payload makes every fill lane a candidate
        // delivery surface — a field labeled by its placeholder text
        // matches no goal word yet is the only lane that can land the
        // value. The 30-lane cap still ranks fills above clicks.
        if !values.isEmpty {
            for (id, lane) in lanes where lane.needsFillText { keep.insert(id) }
        }
        let keyboardWanted = !values.isEmpty || keptElements.isEmpty
            || goal.range(of: #"(?i)\b(?:press|type|enter|tab|key|shortcut)\b"#,
                          options: .regularExpression) != nil
        if keyboardWanted { keep.formUnion(keyboardIDs) }
        let scrollWanted = keptElements.isEmpty
            || goal.range(of: #"(?i)\b(?:scroll|down|up|page|list|bottom|top)\b"#,
                          options: .regularExpression) != nil
        if scrollWanted { keep.formUnion(scrollIDs) }
        if keep.count > maximumOfferedLanes {
            // Last-resort cap: terminals and browser lanes first, then
            // element lanes by tier, keyboard and scroll last.
            func rank(_ id: String) -> (Int, String) {
                switch lanes[id] ?? .done {
                case .done: return (0, id)
                case .stuck: return (1, id)
                case .browserDialog, .browserClick, .browserType,
                     .newTab, .navigate, .launchApp, .typeIntoWindow:
                    return (2, id)
                case .pressKey, .hotkey: return (7, id)
                case .scroll: return (8, id)
                default: return (3 + elementTier(lanes[id] ?? .done), id)
                }
            }
            keep = Set(keep.sorted { rank($0) < rank($1) }.prefix(maximumOfferedLanes))
        }
        return (lanes.filter { keep.contains($0.key) },
                criteria.filter { keep.contains($0.key) },
                laneText.filter { keep.contains($0.key) })
    }

    /// Display content pulled out of `tree_markdown`: static text and value
    /// lines only. Menu chrome is excluded — a Calculator "recent items"
    /// menu can literally list a prior result like "14" and must never
    /// count as the current window's evidence.
    static func windowStaticTexts(markdown: String) -> [String] {
        markdown.split(separator: "\n").compactMap { line in
            guard line.contains("AXStaticText") || line.contains("AXValue")
                    || line.contains("AXTextArea") || line.contains("AXTextField")
                    || line.contains("AXComboBox") || line.contains("AXSlider")
                    || line.contains("AXProgressIndicator")
                    || line.contains("AXHeading") else { return nil }
            guard let quoted = line.split(separator: "\"").dropFirst().first else {
                let tail = line.split(separator: "=", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                return tail.isEmpty ? nil : String(tail)
            }
            return String(quoted)
        }
    }

    /// One bounded visual read: a fresh window capture feeds the driver's
    /// `parse_visual_regions`; the region text is observed evidence for
    /// surfaces whose content exists only as pixels. Read-only — it never
    /// counts as a dispatch and never repeats.
    private func readVisualTexts(pid: Int, wid: Int) async -> [String] {
        guard let capture = try? await call("get_window_state",
            ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
             "include_screenshot": .bool(true), "include_accessibility_tree": .bool(false)]),
              let captureID = capture["capture_id"]?.string,
              let parsed = try? await call("parse_visual_regions",
                  ["capture_id": .string(captureID)]) else { return [] }
        return (parsed["regions"]?.array ?? [])
            .compactMap { $0["text"]?.string ?? $0["label"]?.string }
    }

    /// Driver ActionResult honesty: `effect: confirmed` or an explicit
    /// `verified` readback (including nested postcondition reads like
    /// `exact_window_effect.verified`) is proof of the requested effect.
    private static func isProven(_ result: JSONValue) -> Bool {
        if result["effect"]?.string == "confirmed" || result["verified"] == .bool(true) { return true }
        for (_, value) in result.object ?? [:] where value["verified"] == .bool(true) { return true }
        return false
    }

    /// The driver's own signal that the AX rung could not produce the
    /// requested effect — a suspected noop or an explicit pixel escalation
    /// (the driver spells it "px").
    private static func escalatesToPixel(_ result: JSONValue) -> Bool {
        let recommended = result["escalation"]?["recommended"]?.string ?? ""
        return result["escalation"]?["target"]?.string == "pixel"
            || ["px", "pixel"].contains(recommended)
            || result["effect"]?.string == "suspected_noop"
    }

    /// The driver's signal that window-pinned/background delivery cannot
    /// reach the target — window-input lanes escalate to the foreground
    /// raise path; element lanes mark the failure instead.
    private static func escalatesToForeground(_ result: JSONValue) -> Bool {
        result["escalation"]?["recommended"]?.string == "foreground"
    }

    /// One human-readable outcome line from the driver's honesty fields.
    private static func effectSummary(_ result: JSONValue) -> String {
        var parts: [String] = []
        if let effect = result["effect"]?.string { parts.append("effect \(effect)") }
        else if let summary = result["summary"]?.string { parts.append(String(summary.prefix(80))) }
        else if let status = result["status"]?.string { parts.append(status) }
        else { parts.append("ok") }
        if let mode = result["delivery"]?["mode"]?.string { parts.append("delivery \(mode)") }
        if let escalation = result["escalation"] {
            let target = escalation["target"]?.string ?? escalation["recommended"]?.string ?? "unknown"
            parts.append("escalation → \(target)")
        }
        return parts.joined(separator: ", ")
    }

    private static func compactElement(_ element: JSONValue, deny: [String]) -> JSONValue {
        var compact = compactElement(element).object ?? [:]
        if let label = compact["label"]?.string, isDenied(label, deny: deny) {
            compact["denied"] = .bool(true)
        }
        return .object(compact)
    }

    /// Roles an AX write makes sense on in addition to a click — controls
    /// whose `value` is the semantic action surface.
    private static let valueRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXSlider", "AXSwitch", "AXStepper", "AXIncrementor"]

    /// Menu roles — driven through invoke_menu's path resolution when the
    /// target app is frontmost (the only posture its brief focus is honest).
    private static let menuRoles: Set<String> = ["AXMenuItem", "AXMenuBarItem"]

    // MARK: - Dispatch

    private func dispatch(_ lane: Lane, pid: Int, wid: Int, goal: String,
                          text: String?, browserTarget: JSONValue?, shownTab: String?,
                          tabs: [JSONValue],
                          tabsBaseline: inout [String]?, newTabRequested: inout Bool,
                          foregroundInput: Bool = false) async throws -> JSONValue {
        let inputMode = JSONValue.string(foregroundInput ? "foreground" : "background")
        switch lane {
        case .clickElement(let token, _):
            return try await call("click", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                            "element_token": .string(token),
                                            "delivery_mode": .string("background")])
        case .typeIntoElement(let token, _):
            guard let text, !text.isEmpty else { throw DriverConnectionError.refused("There is no text to insert.") }
            return try await callTool("type_text", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                    "element_token": .string(token), "text": .string(text),
                                                    "delivery_mode": .string("background")],
                                      timeout: Self.typeTimeout(text))
        case .typeIntoWindow:
            guard let text, !text.isEmpty else { throw DriverConnectionError.refused("There is no text to insert.") }
            return try await callTool("type_text", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                    "text": .string(text),
                                                    "delivery_mode": inputMode],
                                      timeout: Self.typeTimeout(text))
        case .setValue(let token, _):
            guard let text, !text.isEmpty else { throw DriverConnectionError.refused("There is no value to set.") }
            return try await call("set_value", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                "element_token": .string(token), "value": .string(text)])
        case .pixelClick(_, _, let x, let y):
            return try await call("click", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                            "x": .number(x), "y": .number(y),
                                            "delivery_mode": .string("background")])
        case .invokeMenu(let path, _):
            // Menu invocation transiently fronts the app — serialize the
            // brief focus grab against peer lanes.
            return try await leased(focus: true) {
                try await self.call("invoke_menu", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                    "path": .array(path.map { .string($0) })])
            }
        case .browserDialog(let accept):
            guard let target = browserTarget, let tab = shownTab else {
                throw DriverConnectionError.refused("No browser binding for the page dialog.")
            }
            let inspected = try await call("browser_dialog", [
                "target_id": target, "tab_id": .string(tab), "action": .string("inspect")])
            guard inspected["present"] == .bool(true), let dialogID = inspected["dialog_id"]?.string else {
                throw DriverConnectionError.refused("No page dialog is open on the bound tab.")
            }
            return try await call("browser_dialog", [
                "target_id": target, "tab_id": .string(tab),
                "action": .string(accept ? "accept" : "dismiss"),
                "dialog_id": .string(dialogID),
                "delivery_mode": .string("background")])
        case .launchApp(let application):
            var args: [String: JSONValue] = [:]
            if application.contains(".") { args["bundle_id"] = .string(application) }
            else { args["name"] = .string(application) }
            // A launch fronts the app on most desktops — hold the focus
            // lane while it lands.
            return try await leased(focus: true) {
                try await self.call("launch_app", args)
            }
        case .pressKey(let key):
            return try await leased(pasteboard: Self.touchesPasteboard(lane)) {
                try await self.call("press_key", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                  "key": .string(key),
                                                  "delivery_mode": inputMode])
            }
        case .hotkey(let keys):
            return try await leased(pasteboard: Self.touchesPasteboard(lane)) {
                try await self.call("hotkey", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                               "keys": .array(keys.map { .string($0) }),
                                               "delivery_mode": inputMode])
            }
        case .scroll(let direction):
            return try await call("scroll", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                             "direction": .string(direction), "by": .string("page"), "amount": .number(1),
                                             "delivery_mode": .string("background")])
        case .newTab:
            if tabsBaseline == nil,
               let state = try? await call("get_browser_state", [
                   "pid": .number(Double(pid)), "window_id": .number(Double(wid))]) {
                tabsBaseline = CuaBrowserTarget.tabs(state).map(CuaBrowserTarget.tabSignature)
            }
            newTabRequested = true
            return try await call("hotkey", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                             "keys": .array([.string("cmd"), .string("t")]),
                                             "delivery_mode": inputMode])
        case .navigate(let url):
            guard let target = browserTarget else {
                throw DriverConnectionError.refused("This window is not bound to the browser route; DOM navigation is unavailable.")
            }
            guard let tab = CuaBrowserTarget.resolveNavigationTab(tabs: tabs, baseline: tabsBaseline, newTabRequested: newTabRequested),
                  let tabID = tab["tab_id"]?.string else {
                throw DriverConnectionError.refused("The destination tab is ambiguous; no tab was navigated.")
            }
            let outcome = try await call("browser_navigate", [
                "target_id": target, "tab_id": .string(tabID), "url": .string(url)])
            // Verify on the addressed tab itself: a page-scoped read must
            // report the destination url — never a same-titled sibling tab.
            // One immediate read confirms the common case; a miss defers to
            // the NEXT ordinary browser observation (pendingNavigation) —
            // the read the loop pays for anyway.
            let needle = url.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            if let after = try? await observeBrowser(pid: pid, wid: wid,
                                                     target: target, tab: tabID),
               let pageURL = Self.browserPageURL(after),
               pageURL.localizedCaseInsensitiveContains(needle) {
                return outcome
            }
            pendingNavigation = (key: "navigate", needle: needle)
            return outcome
        case .browserClick(let ref):
            guard let target = browserTarget, let tab = shownTab else {
                throw DriverConnectionError.refused("No browser binding for the page element.")
            }
            return try await call("browser_click", ["target_id": target, "tab_id": .string(tab),
                                                    "ref": .string(ref), "input_route": .string("dom_event")])
        case .browserType(let ref):
            guard let target = browserTarget, let tab = shownTab, let text, !text.isEmpty else {
                throw DriverConnectionError.refused("No browser binding or no text to insert.")
            }
            return try await call("browser_type", ["target_id": target, "tab_id": .string(tab),
                                                   "ref": .string(ref), "text": .string(text),
                                                   "replace": .bool(false), "input_route": .string("dom_event")])
        case .done, .stuck:
            return .null  // handled before dispatch
        }
    }

    private func laneMutates(_ lane: Lane) -> Bool {
        switch lane {
        case .done, .stuck: return false
        default: return true
        }
    }

    /// Exactly one new onscreen window outside the baseline, or nil when none
    /// or several appeared. Listing errors and ambiguity both collapse to nil
    /// — the step loop re-observes anyway; only a confident unique produce
    /// may steal the pin.
    private func producedWindowID(pid: Int, excluding baseline: Set<Int>) async -> Int? {
        for attempt in 0...2 {
            if let listing = try? await call("list_windows", ["pid": .number(Double(pid))]) {
                let produced = (listing["windows"]?.array ?? []).filter {
                    $0["is_on_screen"] != .bool(false)
                        && !baseline.contains($0["window_id"]?.integer ?? -1) }
                if produced.count == 1 { return produced[0]["window_id"]?.integer }
                if produced.count > 1 { return nil }
            }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        return nil
    }

    // MARK: - Observation shaping

    private static func compactElement(_ element: JSONValue) -> JSONValue {
        .object([
            "i": element["element_index"] ?? .null,
            "role": element["role"] ?? .null,
            "label": element["label"] ?? element["title"] ?? .null,
            "value": (element["value"]?.string).map { .string(String($0.prefix(80))) } ?? .null])
    }

    /// A success_contains entry that only describes the artifact a create
    /// task produces — "new document", "a new note" — can never appear in
    /// observed window text; the produced window itself is its only proof.
    /// Any user-named content in the claim (a title, a body phrase) keeps it
    /// gated on the corpus instead.
    private static func isProducedArtifactClaim(_ claim: String) -> Bool {
        let words = claim.split { !$0.isLetter }
        return !words.isEmpty && words.allSatisfy { producedArtifactVocabulary.contains($0.lowercased()) }
    }

    private static let producedArtifactVocabulary: Set<String> = [
        "a", "an", "the", "new", "fresh", "blank", "empty", "untitled",
        "document", "doc", "window", "note", "file", "draft", "message",
        "email", "mail", "task", "todo", "reminder", "event", "appointment",
        "meeting", "tab", "page", "item", "entry", "record", "card", "post",
        "text", "sheet", "canvas", "project", "list", "board", "created",
        "create", "opened", "open", "made", "make"]

    /// The page url across snapshot contracts: `dom_refs_v1` reports it
    /// top-level, `semantic_v2` nests it under `page`. Absent = inconclusive
    /// read, never a miss.
    nonisolated static func browserPageURL(_ state: JSONValue) -> String? {
        state["url"]?.string ?? state["page"]?["url"]?.string
    }

    /// Roles a click makes sense on; everything else is skipped as a candidate
    /// (the model sees all elements in state, only these become actions).
    private static let clickRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem",
        "AXPopUpButton", "AXComboBox", "AXTab", "AXLink", "AXImage",
        "AXCell", "AXRow", "AXOutlineRow", "AXDisclosureTriangle", "AXIncrementor",
        "AXSlider", "AXSegment", "AXToolbarButton", "AXScrollBar", "AXSwitch"]

    private static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    /// One browser read: with a known target+tab it returns page state, with
    /// just pid+window it returns (or mints) the binding and the tab list.
    private func observeBrowser(pid: Int, wid: Int, target: JSONValue?, tab: String?) async throws -> JSONValue {
        var args: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(wid))]
        if let target, let tab { args["target_id"] = target; args["tab_id"] = .string(tab) }
        return try await call("get_browser_state", args)
    }

    /// The browser half of one observation: `get_browser_state` binds a
    /// window's tab directly; when a target+tab are already known the same
    /// call reads the page. A failed plain read gets one existing-profile
    /// prepare — the same call that upgrades a weak binding for mutation.
    /// Every other browser failure degrades to the keyboard lanes.
    private func boundBrowser(pid: inout Int, wid: inout Int,
                              target: inout JSONValue?, shownTab: inout String?,
                              bindingUpgradeTried: inout Bool) async throws
        -> (tabs: [JSONValue], refs: [JSONValue], state: JSONValue) {
        var browserState: JSONValue?
        do {
            browserState = try await observeBrowser(pid: pid, wid: wid, target: target, tab: shownTab)
        } catch {
            browserState = nil
        }
        if browserState == nil, !bindingUpgradeTried {
            bindingUpgradeTried = true
            do {
                _ = try await call("browser_prepare", [
                    "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                    "strategy": .object(["kind": .string("existing_profile")])])
            } catch let error as DriverConnectionError {
                // A grant refusal means the daemon wasn't launched with
                // --grant existing-profile — clear the verified flag so the
                // next connect re-reconciles instead of trusting stale state.
                if case .toolRefused(_, let code, _) = error,
                   code.contains("grant") || code.contains("permission") {
                    CuaDaemonControl.markGrantUnconfirmed()
                }
            } catch {}
            browserState = try? await observeBrowser(pid: pid, wid: wid, target: nil, tab: nil)
        }
        guard let browserState else { return ([], [], .null) }
        let tabs = CuaBrowserTarget.tabs(browserState)
        target = CuaBrowserTarget.targetID(browserState) ?? target
        shownTab = CuaBrowserTarget.shownTab(in: browserState, tabs: tabs, fallback: shownTab)
        return (tabs, CuaBrowserTarget.pageRefs(browserState), browserState)
    }
}
