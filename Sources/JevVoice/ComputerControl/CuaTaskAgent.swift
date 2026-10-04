import Foundation
import AppKit
import JevVoiceCore

/// A postcondition the executor actually observed while running — backed by a
/// Driver result or an independent readback, never by tool acceptance alone.
struct CuaObservedPostcondition: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case targetObserved
        case resultObserved
    }
    let kind: Kind
    let evidence: String
    let appName: String?
    let bundleID: String?
    let processID: Int?
    let windowID: Int?
    let windowTitle: String?

    init(kind: Kind, evidence: String, appName: String? = nil, bundleID: String? = nil,
         processID: Int? = nil, windowID: Int? = nil, windowTitle: String? = nil) {
        self.kind = kind
        self.evidence = evidence
        self.appName = appName
        self.bundleID = bundleID
        self.processID = processID
        self.windowID = windowID
        self.windowTitle = windowTitle
    }
}

/// Namespace retained so `CuaAgentLoop.run` keeps compiling: it types one
/// parameter as `CuaExecutorDecision.ContentMode`. The utterance planner
/// battery that produced full executor decisions is deleted — the companion
/// planner emits `PlannerDecision`/`TaskSpec` and `CuaAgentLoop.drive` is the
/// per-step selector.
enum CuaExecutorDecision {
    enum ContentMode: String, Equatable, Sendable { case control, literal, dictate }
}

/// Per-task executor state for the voice path: the deterministic fast lane
/// plus the helpers the drive loop's escalation seams call back into.
/// Planning lives in CompanionBrain; per-step choice lives in CuaAgentLoop.
@MainActor
final class CuaTaskAgent {
    typealias Call = (String, [String: JSONValue]) async throws -> JSONValue
    typealias Judge = (JSONValue, [String: Question]) async throws -> [String: Answer]
    typealias Generate = (String, String, Bool) async throws -> String
    private let call: Call
    private let approve: ((String) async throws -> Bool)?
    private(set) var bundleID: String?
    private(set) var windowID: Int?
    private(set) var launchedPID: Int?
    /// Postconditions independently observed during this agent's run, in order.
    /// Only Driver results and readback-verified state are recorded here.
    private(set) var observedPostconditions: [CuaObservedPostcondition] = []

    private func recordPostcondition(_ kind: CuaObservedPostcondition.Kind, _ evidence: String,
                                     appName: String? = nil, bundleID: String? = nil,
                                     processID: Int? = nil, windowID: Int? = nil,
                                     windowTitle: String? = nil) {
        observedPostconditions.append(.init(kind: kind, evidence: evidence, appName: appName,
            bundleID: bundleID, processID: processID, windowID: windowID, windowTitle: windowTitle))
    }

    init(call: @escaping Call,
         approve: ((String) async throws -> Bool)? = nil,
         windowID: Int? = nil) {
        self.call = call
        self.approve = approve
        self.windowID = windowID
    }

    // MARK: - Deterministic fast lane

    /// A resolved fast-lane request: the parsed primitive plus its uniquely
    /// resolved app. Planning never runs on these utterances.
    struct FastResolution {
        let action: CuaFastAction?
        let openVerb: String?
        let name: String
        let bundle: String
    }

    /// Parse + resolve only — no dispatch. Nil when the utterance is not
    /// exactly one known primitive against an unambiguous installed app, so
    /// the planner owns it.
    func resolveFastLane(goal: String, apps: [JSONValue]) -> FastResolution? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let parsed = CuaFastAction.parse(goal),
           let resolved = CuaFastAction.resolveApp(qualifier: parsed.appQualifier, action: parsed.action,
                                                   apps: apps, frontmostBundle: frontmost),
           !parsed.action.needsTabbableApp || CuaFastAction.tabbableBundles.contains(resolved.bundle),
           parsed.action.selfApproves
               || !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description) {
            return FastResolution(action: parsed.action, openVerb: nil,
                                  name: resolved.name, bundle: resolved.bundle)
        }
        if let parsed = CuaFastAction.parseOpen(goal),
           let resolved = CuaFastAction.resolveOpenApp(query: parsed.query, apps: apps,
                                                     frontmostBundle: frontmost) {
            return FastResolution(action: nil, openVerb: parsed.verb,
                                  name: resolved.name, bundle: resolved.bundle)
        }
        return nil
    }

    /// Execute a resolved fast-lane request: bring the app to a running
    /// state, dispatch the primitive, and prove its effect — zero model
    /// calls. Returns nil only when nothing was dispatched and the request
    /// needs the drive loop's disambiguation (e.g. several editable fields).
    func runFastLane(_ resolved: FastResolution, goal: String,
                     progress: @escaping (String) -> Void) async throws -> String? {
        let bundle = resolved.bundle
        let name = resolved.name
        bundleID = bundle
        try Task.checkCancellation()
        let currentInventory = try await call("get_accessibility_tree", [:])
        let runningMatches = (currentInventory["apps"]?.array ?? []).filter {
            $0["bundle_id"]?.string == bundle && ($0["pid"]?.integer ?? 0) > 0
        }
        guard runningMatches.count <= 1 else {
            throw DriverConnectionError.refused("Multiple instances of this app are running. Specify the target before continuing.")
        }
        var pid = runningMatches.first?["pid"]?.integer ?? 0
        if runningMatches.isEmpty {
            // App-control verbs target a running app — launching one just to
            // hide or quit it would invent work the user did not ask for.
            if resolved.action != nil, case .appControl = resolved.action!.body {
                throw DriverConnectionError.refused("\(name) is not running. Nothing was changed.")
            }
            try Task.checkCancellation()
            progress("Opening \(name)…")
            let opened: JSONValue
            do {
                opened = try await call("launch_app", ["bundle_id": .string(bundle)])
            } catch DriverConnectionError.timedOut {
                try Task.checkCancellation()
                let inspection: String
                do {
                    let observed = try await call("get_accessibility_tree", [:])
                    let matches = (observed["apps"]?.array ?? []).filter {
                        $0["bundle_id"]?.string == bundle && ($0["pid"]?.integer ?? 0) > 0
                    }
                    inspection = matches.count == 1 ? "The app was observed running after the timeout."
                        : matches.isEmpty ? "The app was not observed running at inspection time."
                        : "Several matching processes made the launch result ambiguous."
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    inspection = "The app could not be inspected after the timeout."
                }
                try Task.checkCancellation()
                throw DriverConnectionError.refused("Cua launch timed out after dispatch. \(inspection) The launch remains uncertain and was not repeated; inspect the app before another request.")
            }
            guard let process = opened["pid"]?.integer, process > 0 else { throw DriverConnectionError.malformed }
            pid = process
            launchedPID = process
            // The lightweight running-process snapshot avoids scanning installed bundles again.
            let fresh = try await call("get_accessibility_tree", [:])
            guard (fresh["apps"]?.array ?? []).contains(where: {
                $0["bundle_id"]?.string == bundle && $0["pid"]?.integer == pid
            }) else {
                throw DriverConnectionError.refused("The launched application was not observed running. I will not repeat the launch.")
            }
            recordPostcondition(.targetObserved, "Observed \(name) running after launch.",
                                appName: name, bundleID: bundle, processID: pid)
        }
        guard pid > 0 else { throw DriverConnectionError.malformed }

        if resolved.openVerb != nil {
            // A bare "open X" ends deterministically: the process is observed
            // running and its window is verified in front — the same outcome
            // the loop produces, minus the model calls.
            if launchedPID != nil, windowID == nil {
                // Bounded patience for a just-launched app's first window; a
                // menu-bar app may never show one and "opened" stays honest.
                _ = try? await waitForLaunchWindow(pid: pid)
            }
            let rows = (try? await listedWindowRows(pid: pid)) ?? []
            if let pinned = windowID,
               !rows.contains(where: { $0["window_id"]?.integer == pinned }) {
                throw DriverConnectionError.refused("The pinned target window closed. No other window was substituted.")
            }
            if let wid = windowID ?? Self.bestWindowID(in: rows) {
                // Every open verb ends at the same contract: the exact window
                // verified in front. A just-launched window may still be
                // materializing — settle once and retry the verified raise.
                var activation = try await call("bring_to_front", ["pid": .number(Double(pid)), "window_id": .number(Double(wid))])
                if !(activation["activated"] == .bool(true)
                     && activation["exact_window_effect"]?["verified"] == .bool(true)) {
                    try await Task.sleep(for: .milliseconds(400))
                    activation = try await call("bring_to_front", ["pid": .number(Double(pid)), "window_id": .number(Double(wid))])
                }
                // The driver's exact-window verification is stricter than the
                // outcome the user sees: some apps (Calculator) sit in front
                // without satisfying it. The workspace frontmost read plus an
                // on-screen window is real evidence too — report which proof
                // stood rather than refusing a raise that visibly happened.
                let driverVerified = activation["activated"] == .bool(true)
                    && activation["exact_window_effect"]?["verified"] == .bool(true)
                var workspaceFronted = false
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid),
                   let row = try await windowRow(pid: pid, windowID: wid) {
                    workspaceFronted = row["is_on_screen"] != .bool(false)
                }
                guard driverVerified || workspaceFronted else {
                    throw DriverConnectionError.refused("\(name)'s window could not be verified in front. The foreground request was not satisfied.")
                }
                let proof = driverVerified ? "verified its window in front." : "verified as the front app."
                let done = (CuaFastAction.openRequiresRaise(goal: goal)
                    ? "Brought \(name) forward; " : "Opened \(name); ") + proof
                recordPostcondition(.resultObserved, done,
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return done
            }
            if CuaFastAction.openRequiresRaise(goal: goal) {
                throw DriverConnectionError.refused("\(name) has no observable window to bring forward.")
            }
            // A windowless foreground open still activates the app so the
            // request has a visible effect; apps that never front (menu-bar
            // agents) fall through to the observed-running report.
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                _ = app.activate(options: [])
            }
            recordPostcondition(.resultObserved, "Observed \(name) running.",
                                appName: name, bundleID: bundle, processID: pid)
            return launchedPID != nil ? "Opened \(name)." : "Observed \(name) running."
        }

        guard let action = resolved.action else { throw DriverConnectionError.malformed }
        return try await runFastLane(action, pid: pid, name: name, bundle: bundle,
                                     foreground: false, progress: progress)
    }

    /// Deterministic one-shot dispatch: resolve the window once, send the
    /// chorded shortcut or element-scoped text, then prove the effect with the
    /// smallest observable delta. No model calls, no page-content consent —
    /// the driver delivers input to the target window in the background when
    /// the user did not ask for focus. Returns nil when nothing was dispatched
    /// and the request needs the drive loop's disambiguation (e.g. several
    /// editable fields); once an input is dispatched the outcome is proven or
    /// honestly refused — never a silent partial.
    private func runFastLane(_ fast: CuaFastAction, pid: Int, name: String, bundle: String,
                             foreground: Bool, progress: (String) -> Void) async throws -> String? {
        if case .appControl(let verb) = fast.body {
            return try await runAppControl(verb, pid: pid, name: name, bundle: bundle,
                                           progress: progress)
        }
        var rows = try await listedWindowRows(pid: pid)
        if windowID == nil, rows.isEmpty {
            // A running-but-windowless app materializes a window on the reopen
            // event launch_app sends (e.g. Chrome with all windows closed).
            _ = try await call("launch_app", ["bundle_id": .string(bundle)])
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(150))
                rows = try await listedWindowRows(pid: pid)
                if !rows.isEmpty { break }
            }
        }
        // A retained/pinned window id is a preference, never a substitute
        // license: when it is absent from the fresh list, refuse like the
        // agent loop does rather than aim the input at another window.
        if let wid = windowID {
            guard rows.contains(where: { $0["window_id"]?.integer == wid }) else {
                throw DriverConnectionError.refused("The pinned target window closed. No other window was substituted.")
            }
        }
        if windowID == nil { windowID = Self.bestWindowID(in: rows) }
        guard let wid = windowID else {
            return nil // no usable window — the drive loop owns this refusal
        }

        // Pre-state for the delta check — one read, only what it needs.
        var beforeCount = 0
        var beforeSelected: String?
        var beforeTitle: String?
        var beforeWindows = 0
        switch fast.effect {
        case .tabsDelta, .tabSelectionDelta:
            let strip = try await tabStrip(pid: pid, window: wid)
            beforeCount = strip.count
            beforeSelected = strip.selected
            if rows.isEmpty { rows = try await listedWindowRows(pid: pid) }
            beforeTitle = rows.first(where: { $0["window_id"]?.integer == wid })?["title"]?.string
        case .windowDelta:
            if rows.isEmpty { rows = try await listedWindowRows(pid: pid) }
            // Phantom/utility windows (Chrome keeps several 1×1 ones) churn on
            // their own — the delta only counts real on-screen titled windows.
            beforeWindows = Self.realWindowCount(in: rows)
        case .windowOffScreen:
            if rows.isEmpty { rows = try await listedWindowRows(pid: pid) }
            // Nothing on screen to minimize — the loop owns the honest answer.
            guard rows.first(where: { $0["window_id"]?.integer == wid })?["is_on_screen"] != .bool(false) else { return nil }
        case .appOffScreen:
            if rows.isEmpty { rows = try await listedWindowRows(pid: pid) }
            // Already hidden — nothing for ⌘H to do; the loop owns the answer.
            guard rows.contains(where: { $0["is_on_screen"] == .bool(true) }) else { return nil }
        case .boundsToScreen:
            if rows.isEmpty { rows = try await listedWindowRows(pid: pid) }
            if Self.boundsCoverAScreen(rows.first(where: { $0["window_id"]?.integer == wid })?["bounds"]) {
                return "\(name)'s window already covers the screen."
            }
        case .boundsFromScreen:
            if rows.isEmpty { rows = try await listedWindowRows(pid: pid) }
            // ⌃⌘F toggles — on a non-fullscreen window it would ENTER, the
            // opposite of the request. Only dispatch when leaving is real.
            guard Self.boundsCoverAScreen(rows.first(where: { $0["window_id"]?.integer == wid })?["bounds"]) else { return nil }
        case .typedText, .delivered, .processGone, .appOnScreen:
            break // app verbs never reach this pre-state pass
        }

        // Window-scoped delivery targets the window by id, so a failed raise
        // (locked screen, off-Space or minimized window) is a caveat on the
        // report, never a reason to skip a provably-targeted action.
        var focusNote = ""
        if foreground {
            do {
                let activation = try await call("bring_to_front", ["pid": .number(Double(pid)), "window_id": .number(Double(wid))])
                guard activation["activated"] == .bool(true), activation["exact_window_effect"]?["verified"] == .bool(true) else {
                    throw DriverConnectionError.refused("The requested window could not be verified in front.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                focusNote = " \(name) could not be brought to the front."
            }
        }
        try Task.checkCancellation()
        progress(fast.description)

        switch fast.body {
        case .type(let payload):
            let typed = try await dispatchFastType(payload, pid: pid, window: wid, name: name, bundle: bundle)
            return typed.map { $0 + focusNote }
        case .appControl:
            throw DriverConnectionError.malformed // app verbs dispatch in runAppControl
        case .hotkey(let keys, _):
            _ = try await call("hotkey", [
                "keys": .array(keys.map { .string($0) }),
                "target": .object(["kind": .string("window"), "pid": .number(Double(pid)), "window_id": .number(Double(wid))])
            ])
        }
        let shortcut = fast.shortcut ?? ""

        switch fast.effect {
        case .tabsDelta(let delta):
            // `>=`, not `==`: a single-tab Chrome window hides its strip, so a
            // 0→2 materialization is the real new-tab transition there.
            if let observed = await pollDriver({ try await self.tabStrip(pid: pid, window: wid).count },
                                               until: { $0 >= beforeCount + delta }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); observed tab count \(beforeCount)→\(observed).",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name); tabs \(beforeCount)→\(observed)." + focusNote
            }
            if let title = await pollDriver({ try await self.windowTitle(pid: pid, window: wid) },
                                            until: { $0 != nil && $0 != beforeTitle }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); window title changed to \"\(title ?? "")\".",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name); the window title changed." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but could not confirm the tab effect from the window's observed state." + focusNote)
        case .tabSelectionDelta:
            if let observed = await pollDriver({ try await self.tabStrip(pid: pid, window: wid).selected },
                                               until: { $0 != nil && $0 != beforeSelected }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); selected tab became \"\(observed ?? "")\".",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name)." + focusNote
            }
            if let title = await pollDriver({ try await self.windowTitle(pid: pid, window: wid) },
                                            until: { $0 != nil && $0 != beforeTitle }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); window title changed to \"\(title ?? "")\".",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name); the window title changed." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but could not confirm the navigation from the window's observed state." + focusNote)
        case .windowDelta(let delta):
            if let observed = await pollDriver({ try await Self.realWindowCount(in: self.listedWindowRows(pid: pid)) },
                                               until: { $0 >= beforeWindows + delta }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); observed window count \(beforeWindows)→\(observed).",
                                    appName: name, bundleID: bundle, processID: pid)
                return "\(fast.result) in \(name); windows \(beforeWindows)→\(observed)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but could not confirm a new window appeared." + focusNote)
        case .windowOffScreen:
            let gone = await pollDriver({ () async throws -> Bool in
                guard let row = try await self.windowRow(pid: pid, windowID: wid) else { return true }
                return row["is_on_screen"] == .bool(false)
            }, until: { $0 })
            if gone == true {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); the window left the screen.",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but the window stayed on screen." + focusNote)
        case .appOffScreen:
            let hidden = await pollDriver({ () async throws -> Bool in
                let rows = try await self.listedWindowRows(pid: pid)
                return rows.isEmpty || rows.allSatisfy { $0["is_on_screen"] == .bool(false) }
            }, until: { $0 })
            if hidden == true {
                recordPostcondition(.resultObserved, "Hid \(name); all its windows left the screen.",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "Hid \(name)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but its windows stayed on screen." + focusNote)
        case .boundsToScreen:
            let full = await pollDriver({ () async throws -> Bool in
                Self.boundsCoverAScreen(try await self.windowRow(pid: pid, windowID: wid)?["bounds"])
            }, until: { $0 })
            if full == true {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); window bounds cover the screen.",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but the window never covered the screen." + focusNote)
        case .boundsFromScreen:
            let shrunk = await pollDriver({ () async throws -> Bool in
                guard let bounds = try await self.windowRow(pid: pid, windowID: wid)?["bounds"] else { return false }
                return !Self.boundsCoverAScreen(bounds)
            }, until: { $0 })
            if shrunk == true {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); window no longer covers the screen.",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but the window is still covering the screen." + focusNote)
        case .typedText:
            throw DriverConnectionError.malformed // .typedText returns inside dispatchFastType
        case .processGone, .appOnScreen:
            throw DriverConnectionError.malformed // app verbs complete inside runAppControl
        case .delivered:
            recordPostcondition(.resultObserved, "Cua confirmed \(shortcut) keystroke delivery to \(name).",
                                appName: name, bundleID: bundle, processID: pid, windowID: wid)
            return "\(fast.result) in \(name) — \(shortcut) delivered to the window." + focusNote
        }
    }

    /// Whole-app verbs: hide/unhide move through NSRunningApplication (no
    /// focus steal), minimize uses the app's own Window menu so it also works
    /// on a background app, and quit is a graceful terminate gated by the
    /// same approval surface the drive loop uses. Every path verifies the
    /// effect from fresh observation — a refused outcome names what held.
    private func runAppControl(_ verb: CuaFastAction.AppVerb, pid: Int, name: String,
                               bundle: String, progress: (String) -> Void) async throws -> String? {
        // Approval precedes the liveness check so a pending quit can be
        // cancelled from the same surface as any other risky action.
        if verb == .quit {
            guard let approve else { return nil } // an unapprovable quit stays with the drive loop
            guard try await approve("Quit \(name)? It may ask to save open documents first.") else {
                throw CancellationError()
            }
        }
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)), !app.isTerminated else {
            throw DriverConnectionError.refused("\(name) is no longer running. Nothing was changed.")
        }
        switch verb {
        case .hide:
            guard !app.isHidden else { return "\(name) is already hidden." }
            progress("Hiding \(name)")
            // hide()/unhide() return before the transition completes and their
            // Bool is unreliable — the observation poll below is the verdict.
            _ = app.hide()
            let hidden = await pollDriver({ () async throws -> Bool in
                let rows = try await self.listedWindowRows(pid: pid)
                return rows.isEmpty || rows.allSatisfy { $0["is_on_screen"] == .bool(false) }
            }, until: { $0 })
            if hidden == true {
                recordPostcondition(.resultObserved, "Hid \(name); all its windows left the screen.",
                                    appName: name, bundleID: bundle, processID: pid)
                return "Hid \(name)."
            }
            throw DriverConnectionError.refused("\(name) was asked to hide, but its windows stayed on screen.")
        case .unhide:
            if app.isHidden {
                progress("Unhiding \(name)")
                app.unhide()
            } else {
                _ = app.activate(options: [])
            }
            let shown = await pollDriver({ () async throws -> Bool in
                guard NSRunningApplication(processIdentifier: pid_t(pid))?.isHidden == false else { return false }
                let rows = try await self.listedWindowRows(pid: pid)
                return rows.isEmpty || rows.contains { $0["is_on_screen"] != .bool(false) }
            }, until: { $0 })
            if shown == true {
                recordPostcondition(.resultObserved, "Unhid \(name); it is visible again.",
                                    appName: name, bundleID: bundle, processID: pid)
                return "Unhid \(name)."
            }
            throw DriverConnectionError.refused("\(name) was asked to unhide, but no window returned to the screen.")
        case .minimize:
            let rows = try await listedWindowRows(pid: pid)
            guard let wid = Self.bestWindowID(in: rows) else {
                throw DriverConnectionError.refused("\(name) has no observable window to minimize.")
            }
            // invoke_menu temporarily focuses a background app — same standing
            // grant the loop asks for; a hidden/minimized app is unaffected.
            let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid)
            if !isFront, !CuaStandingGrants.menuFocus(bundle: bundle) {
                guard let approve,
                      try await approve("Temporarily focus \(name) to perform:\nWindow → Minimize\nCua restores the prior focus afterward. Granted once per app — Jarvis remembers this.") else {
                    throw CancellationError()
                }
                CuaStandingGrants.grantMenuFocus(bundle: bundle)
            }
            progress("Minimizing \(name)'s window")
            // A just-shown/just-raised app can still be building its menu bar;
            // one settle+retry absorbs that without repeating a dispatched act.
            do {
                _ = try await call("invoke_menu", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                   "path": .array([.string("Window"), .string("Minimize")])])
            } catch {
                try await Task.sleep(for: .milliseconds(400))
                _ = try await call("invoke_menu", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                   "path": .array([.string("Window"), .string("Minimize")])])
            }
            let gone = await pollDriver({ () async throws -> Bool in
                guard let row = try await self.windowRow(pid: pid, windowID: wid) else { return true }
                return row["is_on_screen"] == .bool(false)
            }, until: { $0 })
            if gone == true {
                recordPostcondition(.resultObserved, "Minimized \(name)'s window; it left the screen.",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "Minimized \(name)'s window."
            }
            throw DriverConnectionError.refused("Invoked Window → Minimize in \(name), but the window stayed on screen.")
        case .quit:
            progress("Quitting \(name)")
            _ = app.terminate()
            let gone = await pollDriver({ () async throws -> Bool in
                NSRunningApplication(processIdentifier: pid_t(pid))?.isTerminated ?? true
            }, until: { $0 })
            if gone == true {
                recordPostcondition(.resultObserved, "Quit \(name); the process exited.",
                                    appName: name, bundleID: bundle, processID: pid)
                return "Quit \(name)."
            }
            throw DriverConnectionError.refused("\(name) was asked to quit but is still running — it may be holding a save dialog open.")
        }
    }

    /// Exact text entry through the driver's element-scoped `type_text`. Fires
    /// only when the window exposes exactly one editable element — multiple
    /// fields are a targeting question, which belongs to the drive loop.
    /// A readable `value` delta proves insertion; when the element never
    /// exposes a value (secure fields) the driver's delivery is reported as
    /// delivery, not as a proven write.
    private func dispatchFastType(_ payload: String, pid: Int, window wid: Int,
                                  name: String, bundle: String) async throws -> String? {
        let snapshot = try await call("get_window_state", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                           "include_screenshot": .bool(false), "max_elements": .number(220)])
        let elements = snapshot["elements"]?.array ?? []
        guard let target = Self.uniqueEditableTarget(in: elements) else { return nil }
        let before = target["value"]?.string
        _ = try await call("type_text", [
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "element_token": .string(target["element_token"]?.string ?? ""),
            "delivery_mode": .string("background"),
            "text": .string(payload)
        ])
        let token = target["element_token"]?.string ?? ""
        let observed = await pollDriver { () async throws -> String? in
            let fresh = try await self.call("get_window_state", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                                 "include_screenshot": .bool(false), "max_elements": .number(220)])
            return fresh["elements"]?.array?.first(where: { $0["element_token"]?.string == token })?["value"]?.string
        } until: { value in
            guard let value else { return false }
            return value.hasSuffix(payload) || (before != nil && value == before! + payload)
        }
        let label = target["label"]?.string ?? target["description"]?.string ?? "text field"
        if observed != nil {
            recordPostcondition(.resultObserved, "Observed \"\(label)\" in \(name) hold the typed text.",
                                appName: name, bundleID: bundle, processID: pid, windowID: wid)
            return "Typed the text into \(label) in \(name)."
        }
        recordPostcondition(.resultObserved, "Cua confirmed text delivery to \(label) in \(name).",
                            appName: name, bundleID: bundle, processID: pid, windowID: wid)
        return "Delivered the text to \(label) in \(name); its value is not independently readable."
    }

    private func listedWindowRows(pid: Int) async throws -> [JSONValue] {
        (try await call("list_windows", ["pid": .number(Double(pid))]))["windows"]?.array ?? []
    }

    /// Real browser/document windows, excluding the off-screen untitled
    /// utility windows apps keep around (Chrome holds several 1×1 phantoms).
    private static func realWindowCount(in windows: [JSONValue]) -> Int {
        windows.filter { $0["is_on_screen"] != .bool(false) && !($0["title"]?.string ?? "").isEmpty }.count
    }

    /// Same candidate policy the loop uses: on-screen titled windows first,
    /// then any visible, then titled anywhere; highest z-index wins.
    private static func bestWindowID(in windows: [JSONValue]) -> Int? {
        let visible = windows.filter { $0["is_on_screen"] != .bool(false) }
        let titled = { (list: [JSONValue]) in list.filter { !($0["title"]?.string ?? "").isEmpty } }
        let candidates = !titled(visible).isEmpty ? titled(visible)
            : (!visible.isEmpty ? visible : titled(windows))
        return candidates.max { ($0["z_index"]?.integer ?? Int.min) < ($1["z_index"]?.integer ?? Int.min) }?["window_id"]?.integer
    }

    /// The window's browser-level tab strip: radio/tab elements that are NOT
    /// inside page content. On real Chrome, browser tabs are AXRadioButton
    /// children of AXWindow while in-page tab widgets live under AXWebArea —
    /// the ancestor exclusion is what separates them. `selected` carries a
    /// position-prefixed label so equal titles on different tabs still differ.
    private static func tabStrip(in elements: [JSONValue]) -> (count: Int, selected: String?) {
        let indexed = Dictionary(elements.compactMap { e in e["element_index"]?.integer.map { ($0, e) } },
                                 uniquingKeysWith: { a, _ in a })
        func insideWebArea(_ element: JSONValue) -> Bool {
            var node = element
            var hops = 0
            while let parent = node["parent_index"]?.integer, let upper = indexed[parent], hops < 12 {
                if upper["role"]?.string == "AXWebArea" { return true }
                node = upper; hops += 1
            }
            return false
        }
        var count = 0
        var selected: String?
        for e in elements where ["AXRadioButton", "AXTab"].contains(e["role"]?.string ?? "") && !insideWebArea(e) {
            let label = e["label"]?.string ?? e["title"]?.string ?? e["value"]?.string ?? ""
            if e["selected"]?.bool == true || e["value"]?.integer == 1 { selected = "\(count)|\(label)" }
            count += 1
        }
        return (count, selected)
    }

    /// The window's sole editable element, or nil when there is none or the
    /// choice between several is genuinely ambiguous. Element-token dispatch
    /// types into exactly this element — no focus guessing.
    static func uniqueEditableTarget(in elements: [JSONValue]) -> JSONValue? {
        let roles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXSecureTextField"]
        let candidates = elements.filter {
            roles.contains($0["role"]?.string ?? "")
                && $0["enabled"] != .bool(false)
                && !($0["element_token"]?.string ?? "").isEmpty
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func tabStrip(pid: Int, window wid: Int) async throws -> (count: Int, selected: String?) {
        let snapshot = try await call("get_window_state", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                           "include_screenshot": .bool(false), "max_elements": .number(220)])
        return Self.tabStrip(in: snapshot["elements"]?.array ?? [])
    }

    private func windowTitle(pid: Int, window wid: Int) async throws -> String? {
        try await listedWindowRows(pid: pid).first(where: { $0["window_id"]?.integer == wid })?["title"]?.string
    }

    private func windowRow(pid: Int, windowID wid: Int) async throws -> JSONValue? {
        try await listedWindowRows(pid: pid).first(where: { $0["window_id"]?.integer == wid })
    }

    /// Whether the window's bounds cover an attached screen — the observable
    /// state of macOS full screen. A couple of points of tolerance absorbs
    /// fractional Retina geometry.
    private static func boundsCoverAScreen(_ bounds: JSONValue?) -> Bool {
        func number(_ value: JSONValue?) -> Double? {
            guard case let .number(v)? = value, v.isFinite else { return nil }
            return v
        }
        guard let x = number(bounds?["x"]), let y = number(bounds?["y"]),
              let w = number(bounds?["width"]), let h = number(bounds?["height"]) else { return false }
        return NSScreen.screens.contains { screen in
            let f = screen.frame
            return abs(x - f.origin.x) < 3 && abs(y - f.origin.y) < 3
                && abs(w - f.width) < 3 && abs(h - f.height) < 3
        }
    }

    /// Poll a cheap Driver read until `until` holds or the budget expires.
    /// Keystroke effects land in tens of milliseconds; the bound keeps an
    /// undeliverable effect honest instead of hanging the task.
    private func pollDriver<T>(attempts: Int = 10,
                               _ read: () async throws -> T, until: (T) -> Bool) async -> T? {
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(150)) }
            if Task.isCancelled { return nil }
            if let value = try? await read(), until(value) { return value }
        }
        return nil
    }

    /// Browsers the driver's typed CDP route attests: Chrome and Edge carry
    /// an ownable DevTools endpoint; Safari/Firefox have no DOM binding and
    /// stay on the native/keyboard lanes.
    nonisolated static func supportsIsolatedBrowser(_ bundle: String) -> Bool {
        ["com.google.Chrome", "com.microsoft.edgemac"].contains(bundle)
    }

    /// Approved isolated-profile prepare — the drive loop's escalateBrowser
    /// seam calls this when the user's own browser refuses automation binding.
    func prepareIsolatedBrowser(name: String) async throws -> Int {
        guard let approve,
              try await approve("Open a new isolated Chrome profile for this request. It does not use your signed-in profile, cookies, or existing tabs.") else {
            throw DriverConnectionError.refused("Chrome is not prepared for automation. Approve a new isolated browser profile to continue.")
        }
        try Task.checkCancellation()
        let prepared = try await call("browser_prepare", [
            "allow_launch": .bool(true),
            "profile": .object(["mode": .string("isolated_new")])
        ])
        guard let pid = prepared["prepared_pid"]?.integer, pid > 0 else {
            throw DriverConnectionError.refused("Cua did not return the isolated browser process for \(name). No browser action was dispatched.")
        }
        launchedPID = pid
        return pid
    }

    func waitForBrowserWindow(pid: Int) async throws -> Int {
        for _ in 0..<50 {
            let result = try await call("list_windows", ["pid": .number(Double(pid))])
            let windows = result["windows"]?.array ?? []
            let visible = windows.filter { $0["is_on_screen"] != .bool(false) }
            let candidates = visible.isEmpty ? windows.filter { !($0["title"]?.string ?? "").isEmpty } : visible
            if candidates.count == 1, let id = candidates[0]["window_id"]?.integer { return id }
            if candidates.count > 1 { throw DriverConnectionError.refused("The isolated browser opened several windows. Select the exact target before continuing.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DriverConnectionError.refused("The isolated browser window did not become observable. No page action was dispatched.")
    }

    private func waitForLaunchWindow(pid: Int) async throws {
        // Bounded patience for a just-launched first window — a real window
        // materializes in well under a second; a menu-bar app never shows one
        // and "opened" stays honest instead of stalling the whole lane.
        for _ in 0..<8 {
            try Task.checkCancellation()
            let result = try await call("list_windows", ["pid": .number(Double(pid))])
            if (result["windows"]?.array ?? []).contains(where: {
                $0["is_on_screen"] != .bool(false) || !($0["title"]?.string ?? "").isEmpty
            }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        // A slow first launch can need a nudge: activating a running app opens
        // its main window for document-style apps before this refuses.
        NSRunningApplication(processIdentifier: pid_t(pid))?.activate()
        for _ in 0..<4 {
            try Task.checkCancellation()
            let result = try await call("list_windows", ["pid": .number(Double(pid))])
            if (result["windows"]?.array ?? []).contains(where: {
                $0["is_on_screen"] != .bool(false) || !($0["title"]?.string ?? "").isEmpty
            }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DriverConnectionError.refused("The launched app did not show an observable window. The launch was not repeated; inspect the app before retrying.")
    }

    /// The operand of an operand-carrying verb phrase — the words destined for
    /// a field after command wording like "search for", "go to", "type", or
    /// "run". The last whole-word introducer wins, so "open google and search
    /// for X" yields X, and "write a note that says Y" yields Y.
    nonisolated static func requestOperand(in source: String) -> String? {
        let introducers = ["that says", "says", "search for", "look for", "look up",
                           "navigate to", "go to", "visit", "google", "search",
                           "type", "write", "enter", "run", "play", "say", "find"]
        let lower = source.lowercased()
        var best: (position: Int, end: String.Index)?
        for introducer in introducers {
            var cursor = lower.startIndex
            while let range = lower.range(of: introducer, range: cursor..<lower.endIndex) {
                let leftOK = range.lowerBound == lower.startIndex
                    || !lower[lower.index(before: range.lowerBound)].isLetter
                let rightOK = range.upperBound == lower.endIndex
                    || !lower[range.upperBound].isLetter
                if leftOK && rightOK {
                    let position = lower.distance(from: lower.startIndex, to: range.lowerBound)
                    if best == nil || position > best!.position
                        || (position == best!.position && range.upperBound > best!.end) {
                        best = (position, range.upperBound)
                    }
                }
                cursor = range.upperBound
            }
        }
        guard let best else { return nil }
        let tail = source[best.end...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    /// Spoken payload introducers are grammar, not content: "the words hello"
    /// means the payload "hello". Only fires on the whole-phrase leads a
    /// dictation request uses — never inside the payload.
    nonisolated static func stripLiteralIntroducer(_ text: String) -> String {
        let lead = #"^\s*(?:the\s+)?(?:words?|text|message|phrase|sentence|line|following)\s+|^\s*(?:saying|that\s+says?|which\s+says?)\s+"#
        guard let range = text.range(of: lead, options: [.regularExpression, .caseInsensitive]) else { return text }
        let trimmed = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    /// A literal span's tail naming the destination app is not payload text.
    nonisolated static func stripDestinationTail(_ text: String, appName: String?) -> String {
        guard let appName, !appName.isEmpty else { return text }
        let tail = #"\s+(?:in|into|at|to)\s+"# + NSRegularExpression.escapedPattern(for: appName) + #"\s*$"#
        guard let range = text.range(of: tail, options: [.regularExpression, .caseInsensitive]) else { return text }
        let trimmed = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    /// Whether an action could have a consequence beyond a reversible local
    /// change — sending, deleting, purchasing, closing/quitting, or security —
    /// and so still needs an approval call. Ordinary clicks, text and
    /// navigation skip it entirely. Matching is deliberately generous: a
    /// false positive costs one extra approval ask, a false negative skips a
    /// safety check.
    nonisolated static func requiresRiskJudgment(goal: String, actionDescription: String) -> Bool {
        let consequential = ["delete", "trash", "remove", "erase", "format", "discard", "overwrite", "empty", "wipe",
                             "purchase", "buy", "checkout", "pay", "subscribe", "order",
                             "send", "submit", "post", "publish", "reply", "email",
                             "quit", "sign out", "log out", "restart", "shut down",
                             "password", "credential", "permission", "install", "authenticate",
                             "replace", "archive", "close", "upload", "download", "export"]
        let actionText = actionDescription.lowercased()
        if consequential.contains(where: { actionText.contains($0) }) { return true }
        // A bare confirm keystroke inside a send-style request is the send.
        let goalText = goal.lowercased()
        let sendContext = ["send", "submit", "post", "reply", "publish"].contains { goalText.contains($0) }
        let confirmKey = ["press return", "press enter", "press the return", "press the enter"].contains { actionText.contains($0) }
        if sendContext && confirmKey { return true }
        return goalText.contains("force quit") && actionText.contains("force quit")
    }

}
