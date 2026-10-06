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

/// How a work item's payload is executed: UI control steps, literal text
/// insertion, or dictation into the frontmost field.
enum CuaContentMode: String, Equatable, Sendable { case control, literal, dictate }

/// Per-task executor state for the voice path: the deterministic fast lane
/// plus the helpers the drive loop's escalation seams call back into.
/// Per-step choice lives in CuaAgentLoop.
@MainActor
final class CuaTaskAgent {
    typealias Call = (String, [String: JSONValue]) async throws -> JSONValue
    typealias Judge = (JSONValue, [String: Question]) async throws -> [String: Answer]
    private let call: Call
    private let approve: ((String) async throws -> Bool)?
    /// Shared-state leases — deictic writes land on the frontmost app's
    /// focused element, so a parallel lane's raise must not redirect them.
    private let lanes: (any CuaLaneLeasing)?
    private(set) var bundleID: String?
    private(set) var windowID: Int?
    private(set) var launchedPID: Int?
    /// True when this run's launch_app call already carried the resolution's
    /// `launchURLs` — spares a redundant URI re-delivery to a fresh process.
    private var launchURIsDelivered = false
    /// The scripting-bridge play was already attempted this run — the
    /// window-bound fallback must not fire the same `tell` twice.
    private var spotifyScriptingTried = false
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

    /// One bounded osascript run — a seam so tests can answer the Spotify
    /// and script lanes without a real `tell` ever leaving the build.
    /// Production defaults to the capped /usr/bin/osascript spawn.
    private let osascript: (String, TimeInterval) async -> String?

    init(call: @escaping Call,
         approve: ((String) async throws -> Bool)? = nil,
         windowID: Int? = nil,
         lanes: (any CuaLaneLeasing)? = CuaLaneRegistry.shared,
         workID: String = "",
         osascript: ((String, TimeInterval) async -> String?)? = nil) {
        self.call = call
        self.approve = approve
        self.windowID = windowID
        self.lanes = lanes
        self.workID = workID
        self.osascript = osascript ?? Self.runOsaScript
    }

    /// Runs `body` holding the global focus lane — raises, launches and
    /// menu invocations all mutate or depend on the frontmost app, which
    /// parallel lanes share. A nil registry runs unleased (no peers).
    private let workID: String
    private func focusLeased<T>(_ body: () async throws -> T) async throws -> T {
        guard let lanes else { return try await body() }
        try await lanes.acquireFocus(workID: workID)
        do {
            let value = try await body()
            await lanes.releaseFocus(workID: workID)
            return value
        } catch {
            await lanes.releaseFocus(workID: workID)
            throw error
        }
    }

    /// The shared pasteboard lane — a clipboard read/write must not land
    /// between a peer lane's write and readback or a dictation
    /// snapshot→paste→restore sequence. Serialize on the same lease the
    /// drive loop's gate holds for clipboard_* tools.
    private func pasteboardLeased<T>(_ body: () async throws -> T) async throws -> T {
        guard let lanes else { return try await body() }
        try await lanes.acquirePasteboard(workID: workID)
        do {
            let value = try await body()
            await lanes.releasePasteboard(workID: workID)
            return value
        } catch {
            await lanes.releasePasteboard(workID: workID)
            throw error
        }
    }

    // MARK: - Deterministic fast lane

    /// A resolved fast-lane request: the parsed primitive plus its uniquely
    /// resolved app. Planning never runs on these utterances.
    struct FastResolution {
        let action: CuaFastAction?
        let openVerb: String?
        let name: String
        let bundle: String
        /// URLs delivered through launch_app's LaunchServices hand-off —
        /// URI schemes and file/URL opens that ride the launch instead of
        /// needing a second dispatch (Spotify search URIs). Empty for
        /// ordinary launches.
        var launchURLs: [String] = []
    }

    /// Parse + resolve only — no dispatch. Nil when the utterance is not
    /// exactly one known primitive against an unambiguous installed app, so
    /// the drive loop owns it. `appHint` is the model-supplied `app` argument —
    /// used only when the instruction itself names no app.
    /// `frontmostBundleOverride` carries the app frontmost before Jarvis's
    /// own UI took key status — the live NSWorkspace read can name an
    /// accessory overlay that should never own "frontmost" targeting.
    func resolveFastLane(goal: String, apps: [JSONValue], appHint: String? = nil,
                         frontmostBundleOverride: String? = nil) -> FastResolution? {
        let frontmost = frontmostBundleOverride
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let parsed = CuaFastAction.parse(goal) {
            // Global lanes need no app and must not queue behind an app
            // lease — a media key is a system event, not a window action,
            // and so are the pasteboard and osascript volume/player reads.
            switch parsed.action.body {
            case .mediaKey, .clipboardRead, .clipboardWrite, .scriptVerb:
                guard !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description)
                else { return nil }
                return FastResolution(action: parsed.action, openVerb: nil, name: "", bundle: "")
            default:
                break
            }
            // A misheard model `app` arg must not sink an otherwise-valid
            // command — and it must not outrank what the user is looking
            // at. With no spoken qualifier the frontmost app resolves
            // first; the model's hint is only a fallback when frontmost
            // doesn't resolve ("press space" + app:"spotify" targets the
            // app in front, not a backgrounded Spotify).
            let qualifiers: [String?] = parsed.appQualifier != nil
                ? [parsed.appQualifier] : [nil, appHint]
            for qualifier in qualifiers {
                // "search google for X" names an engine, not an installed
                // app — the engine URL is the deterministic target. The
                // check runs before app resolution so an installed app
                // whose name merely contains the engine word ("Google
                // Chrome") can't capture a site-search intent.
                if let qualifier, case .appSearch(let query, _) = parsed.action.body,
                   let url = CuaActionCatalog.namedEngineSearchURL(engine: qualifier, query: query),
                   !Self.requiresRiskJudgment(goal: goal,
                                              actionDescription: "Searching \(qualifier) for “\(query)”") {
                    return FastResolution(action: CuaFastAction(
                            body: .navigateURL(url), generic: true,
                            description: "Searching \(qualifier) for “\(query)”",
                            result: "Opened the results", effect: .delivered),
                        openVerb: nil, name: "", bundle: "")
                }
                guard let resolved = CuaFastAction.resolveApp(qualifier: qualifier,
                                                            action: parsed.action,
                                                            apps: apps, frontmostBundle: frontmost),
                      !parsed.action.needsTabbableApp || CuaFastAction.tabbableBundles.contains(resolved.bundle) else {
                    continue
                }
                // "type X here" means the live insertion point — a qualifier
                // naming an app other than the frontmost one contradicts it;
                // the drive loop owns that question.
                if case .deicticType = parsed.action.body, resolved.bundle != frontmost { continue }
                // "play X" only lands on a media app; a non-media resolution
                // is the loop's question, not a search field to guess at.
                if case .appSearch(_, let playTopHit) = parsed.action.body, playTopHit,
                   !Self.mediaBundles.contains(resolved.bundle) { continue }
                guard parsed.action.selfApproves
                        || !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description) else { break }
                var resolution = FastResolution(action: parsed.action, openVerb: nil,
                                                name: resolved.name, bundle: resolved.bundle)
                if case .appSearch(let query, _) = parsed.action.body, resolved.bundle == Self.spotifyBundle {
                    resolution.launchURLs = [Self.spotifySearchURI(query)]
                }
                return resolution
            }
            // A bare "play X" that resolved no media app above still has one
            // deterministic reading: the frontmost or uniquely-running media
            // app, or an installed Spotify.
            if parsed.appQualifier == nil, case .appSearch(_, let playTopHit) = parsed.action.body,
               playTopHit,
               !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description),
               let media = Self.implicitMediaApp(apps: apps, frontmostBundle: frontmost) {
                var resolution = FastResolution(action: parsed.action, openVerb: nil,
                                                name: media.name, bundle: media.bundle)
                if media.bundle == Self.spotifyBundle, case .appSearch(let query, _) = parsed.action.body {
                    resolution.launchURLs = [Self.spotifySearchURI(query)]
                }
                return resolution
            }
        }
        if let parsed = CuaFastAction.parseOpen(goal) {
            if let resolved = CuaFastAction.resolveOpenApp(query: parsed.query, apps: apps,
                                                           frontmostBundle: frontmost) {
                return FastResolution(action: nil, openVerb: parsed.verb,
                                      name: resolved.name, bundle: resolved.bundle)
            }
            // A URL-shaped tail that resolved to no app is a navigation
            // request — "go to apple.com" binds a browser or goes through
            // LaunchServices; a tail carrying more than the address stays
            // with the drive loop.
            if let url = CuaActionCatalog.explicitBrowserNavigationURL(in: goal),
               !Self.requiresRiskJudgment(goal: goal, actionDescription: "Opening \(url)") {
                return FastResolution(action: CuaFastAction(
                        body: .navigateURL(url), generic: true,
                        description: "Opening \(url)", result: "Opened \(url)", effect: .delivered),
                    openVerb: nil, name: "", bundle: "")
            }
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
        if !bundle.isEmpty { bundleID = bundle }
        launchURIsDelivered = false
        spotifyScriptingTried = false
        try Task.checkCancellation()
        // App-free lanes dispatch before any inventory read: media keys post
        // to the HID tap, deictic text lands at the live insertion point, and
        // a navigation URL binds a browser or goes through LaunchServices.
        if let action = resolved.action {
            switch action.body {
            case .mediaKey(let key):
                progress(action.description)
                guard MediaKeys.post(key) else {
                    throw DriverConnectionError.refused("The system key event could not be created. Nothing was delivered.")
                }
                recordPostcondition(.resultObserved, "\(action.result); posted to the HID event tap.")
                return "\(action.result)."
            case .deicticType(let payload):
                return try await dispatchDeicticType(payload, action: action, name: name, progress: progress)
            case .navigateURL(let url):
                return try await dispatchURLLane(url, progress: progress)
            case .clipboardRead:
                return try await dispatchClipboardRead(action, progress: progress)
            case .clipboardWrite(let payload):
                return try await dispatchClipboardWrite(payload, action: action, progress: progress)
            case .scriptVerb(let verb):
                return try await dispatchScriptVerb(verb, action: action, progress: progress)
            case .systemURL(let verb):
                return try await dispatchSystemURL(verb, action: action, progress: progress)
            case .appSearch(let query, let playTopHit) where playTopHit
                    && (bundle.isEmpty || bundle == Self.spotifyBundle):
                // "play X" is a media verb, not an open request — the
                // scripting bridge resolves the top hit inside Spotify and
                // `current track` proves what actually started. `tell` on a
                // cold Spotify waits out the launch itself, so this beats
                // racing launch_app against the app's boot. A consent wall
                // or a missing player falls through to the URI path below.
                progress(action.description)
                spotifyScriptingTried = true
                if let played = await spotifyAppleScriptPlay(query) {
                    recordPostcondition(.resultObserved,
                        "Spotify reports playing \"\(played.track)\" by \(played.artist).",
                        appName: "Spotify", bundleID: Self.spotifyBundle)
                    return "Playing \(played.track) by \(played.artist) on Spotify."
                }
            default:
                break
            }
        }
        // The running check rides the live process table — the same rows
        // list_apps resolves `running`/`pid` from, without the ~1.7s
        // inventory scan on every dispatch.
        let runningMatches = try await runningPIDs(bundle: bundle)
        guard runningMatches.count <= 1 else {
            throw DriverConnectionError.refused("Multiple instances of this app are running. Specify the target before continuing.")
        }
        var pid = runningMatches.first ?? 0
        var launchResult: JSONValue?
        if runningMatches.isEmpty {
            // App-bound verbs target a running app — launching one just to
            // hide, kill, resize, read or invoke a menu in it would invent
            // work the user did not ask for.
            if let action = resolved.action {
                switch action.body {
                case .appControl, .killApp, .windowFrame, .menuVerb, .screenRead:
                    throw DriverConnectionError.refused("\(name) is not running. Nothing was changed.")
                default:
                    break
                }
            }
            try Task.checkCancellation()
            progress("Opening \(name)…")
            let opened: JSONValue
            do {
                var args: [String: JSONValue] = ["bundle_id": .string(bundle)]
                if !resolved.launchURLs.isEmpty {
                    args["urls"] = .array(resolved.launchURLs.map { .string($0) })
                }
                opened = try await focusLeased { try await call("launch_app", args) }
                launchResult = opened
                launchURIsDelivered = !resolved.launchURLs.isEmpty
            } catch DriverConnectionError.timedOut {
                try Task.checkCancellation()
                let inspection: String
                do {
                    let matches = try await runningPIDs(bundle: bundle)
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
            // launch_app's resolved pid is the liveness evidence — no second
            // inventory read is needed to confirm what the driver attested.
            recordPostcondition(.targetObserved, "Observed \(name) running after launch.",
                                appName: name, bundleID: bundle, processID: pid)
        }
        guard pid > 0 else { throw DriverConnectionError.malformed }

        if resolved.openVerb != nil {
            // A bare "open X" ends deterministically: the process is observed
            // running and its window is verified in front — the same outcome
            // the loop produces, minus the model calls. `launch_app` already
            // polled for the window — its returned `windows[]` spares a full
            // re-list when the first window registered in time.
            var launchWindows: [JSONValue] = []
            if let opened = launchResult, let array = opened["windows"]?.array, !array.isEmpty {
                launchWindows = array
            }
            if launchedPID != nil, windowID == nil, launchWindows.isEmpty {
                // Bounded patience for a just-launched app's first window; a
                // menu-bar app may never show one and "opened" stays honest.
                // The poll's own winning read is reused — no re-list.
                launchWindows = (try? await waitForLaunchWindow(pid: pid)) ?? []
            }
            // A transport fault is not "no windows" — propagate it rather
            // than skipping the verified-front contract on a dead driver.
            var rows = launchWindows.isEmpty
                ? try await listedWindowRowsResilient(pid: pid)
                : launchWindows
            if let pinned = windowID,
               !rows.contains(where: { $0["window_id"]?.integer == pinned }) {
                throw DriverConnectionError.refused("The pinned target window closed. No other window was substituted.")
            }
            // A raise verb on a running-but-windowless app (every window
            // closed, process alive): macOS reopens the default window on
            // an AppleEvent. One reopen-and-poll before the honest refusal
            // — otherwise we refuse a request the system could satisfy.
            if rows.isEmpty, launchedPID == nil,
               CuaFastAction.openRequiresRaise(goal: goal) {
                _ = try? await focusLeased { try await call("launch_app", ["bundle_id": .string(bundle)]) }
                if let waited = try? await waitForLaunchWindow(pid: pid) {
                    rows = waited
                } else {
                    rows = try await listedWindowRowsResilient(pid: pid)
                }
            }
            if let wid = windowID ?? Self.bestWindowID(in: rows) {
                // Every open verb ends at the same contract: the exact window
                // verified in front. A just-launched window may still be
                // materializing — settle once and retry the verified raise.
                // A refused raise is caught so the retry and the workspace
                // fallback below actually run; a transport fault still
                // propagates — replaying on a dead transport is the unsafe
                // retry this surface refuses. The raise+retry+verify hold
                // the focus lane — a parallel lane's raise must not
                // interleave between our raise and its verification.
                return try await focusLeased { () -> String in
                    var activation: JSONValue
                    do {
                        activation = try await call("bring_to_front", ["pid": .number(Double(pid)), "window_id": .number(Double(wid))])
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as DriverConnectionError {
                        switch error {
                        case .closed, .timedOut, .unavailable, .malformed, .toolRefused: throw error
                        case .refused, .remote: activation = .object([:])
                        }
                    }
                    if !(activation["activated"] == .bool(true)
                         && activation["exact_window_effect"]?["verified"] == .bool(true)) {
                        try await Task.sleep(for: .milliseconds(400))
                        activation = (try? await call("bring_to_front", ["pid": .number(Double(pid)), "window_id": .number(Double(wid))])) ?? activation
                    }
                    // The driver's exact-window verification is stricter than the
                    // outcome the user sees: some apps (Calculator) sit in front
                    // without satisfying it. The workspace frontmost read plus an
                    // on-screen window is real evidence too — report which proof
                    // stood rather than refusing a raise that visibly happened.
                    // When the driver already verified, the re-list is skipped.
                    let driverVerified = activation["activated"] == .bool(true)
                        && activation["exact_window_effect"]?["verified"] == .bool(true)
                    var workspaceFronted = false
                    if !driverVerified,
                       NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid),
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
            }
            if CuaFastAction.openRequiresRaise(goal: goal) {
                throw DriverConnectionError.refused("\(name) has no observable window to bring forward.")
            }
            // A windowless foreground open still activates the app so the
            // request has a visible effect; apps that never front (menu-bar
            // agents) fall through to the observed-running report.
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                try await focusLeased { _ = app.activate(options: []) }
            }
            recordPostcondition(.resultObserved, "Observed \(name) running.",
                                appName: name, bundleID: bundle, processID: pid)
            return launchedPID != nil ? "Opened \(name)." : "Observed \(name) running."
        }

        guard let action = resolved.action else { throw DriverConnectionError.malformed }
        // launch_app already polled for the window — its returned `windows[]`
        // spares a re-list while a first window is still materializing.
        let launchWindows = launchResult?["windows"]?.array ?? []
        return try await runFastLane(action, pid: pid, name: name, bundle: bundle,
                                     initialRows: launchWindows, progress: progress)
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
                             initialRows: [JSONValue] = [],
                             progress: (String) -> Void) async throws -> String? {
        if case .appControl(let verb) = fast.body {
            return try await runAppControl(verb, pid: pid, name: name, bundle: bundle,
                                           progress: progress)
        }
        if case .killApp = fast.body {
            return try await runKillApp(pid: pid, name: name, bundle: bundle,
                                        progress: progress)
        }
        var rows = initialRows.isEmpty ? try await listedWindowRows(pid: pid) : initialRows
        if windowID == nil, rows.isEmpty {
            // Confirm the app is truly windowless before spending the reopen
            // event and the materialization poll: a second cheap
            // list_windows read a beat later catches a transient
            // under-report while a window is still materializing.
            try await Task.sleep(for: .milliseconds(150))
            rows = try await listedWindowRows(pid: pid)
            if rows.isEmpty {
                // A running-but-windowless app materializes a window on the
                // reopen event launch_app sends (e.g. Chrome with all
                // windows closed).
                _ = try await focusLeased { try await call("launch_app", ["bundle_id": .string(bundle)]) }
                for _ in 0..<20 {
                    try await Task.sleep(for: .milliseconds(150))
                    rows = try await listedWindowRows(pid: pid)
                    if !rows.isEmpty { break }
                }
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

        // Window-scoped delivery targets the window by id — it dispatches
        // in the background without a raise, so `focusNote` stays empty;
        // the caveat slot survives for evidence strings that need it.
        let focusNote = ""
        try Task.checkCancellation()
        progress(fast.description)

        switch fast.body {
        case .type(let payload):
            let typed = try await dispatchFastType(payload, pid: pid, window: wid, name: name, bundle: bundle)
            return typed.map { $0 + focusNote }
        case .appSearch(let query, let playTopHit):
            let searched = bundle == Self.spotifyBundle
                ? try await dispatchSpotifySearch(query, playTopHit: playTopHit, pid: pid, window: wid, name: name)
                : try await dispatchAppSearch(query, playTopHit: playTopHit, pid: pid, window: wid, name: name)
            return searched.map { $0 + focusNote }
        case .windowFrame(let verb):
            return try await dispatchWindowFrame(verb, pid: pid, window: wid,
                                                 rows: rows, name: name,
                                                 bundle: bundle, fast: fast)
        case .menuVerb(let menu):
            return try await dispatchMenuVerb(menu, pid: pid, window: wid,
                                              name: name, bundle: bundle)
        case .screenRead:
            return try await dispatchScreenRead(pid: pid, window: wid,
                                                rows: rows, name: name, bundle: bundle)
        case .appControl, .killApp:
            throw DriverConnectionError.malformed // process verbs dispatch in their own runners
        case .mediaKey, .deicticType, .navigateURL, .clipboardRead, .clipboardWrite, .scriptVerb, .systemURL:
            throw DriverConnectionError.malformed // dispatched before window binding
        case .hotkey(let keys, _):
            if keys.count == 1, let key = keys.first {
                // `hotkey` requires ≥2 keys (a chord) — a single key is a
                // `press_key` call or the schema validator rejects it.
                _ = try await call("press_key", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                 "key": .string(key),
                                                 "delivery_mode": .string("background")])
            } else {
                // Flat pid/window_id/keys — the driver's schema declares
                // no `target` object and rejects additional properties.
                _ = try await call("hotkey", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                              "keys": .array(keys.map { .string($0) }),
                                              "delivery_mode": .string("background")])
            }
        case .scroll(let direction, let pages):
            _ = try await call("scroll", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                          "direction": .string(direction), "by": .string("page"),
                                          "amount": .number(Double(pages)),
                                          "delivery_mode": .string("background")])
        }
        let shortcut = fast.shortcut ?? ""

        switch fast.effect {
        case .tabsDelta(let delta):
            // Cheap reads first: the window-title poll rides list_windows;
            // the tab-strip walk (a full window snapshot per attempt) runs
            // only when the title never moved.
            if let title = try await pollDriver({ try await self.windowTitle(pid: pid, window: wid) },
                                            until: { $0 != nil && $0 != beforeTitle }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); window title changed to \"\(title ?? "")\".",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name); the window title changed." + focusNote
            }
            // `>=`, not `==`: a single-tab Chrome window hides its strip, so a
            // 0→2 materialization is the real new-tab transition there.
            if let observed = try await pollDriver({ try await self.tabStrip(pid: pid, window: wid).count },
                                               until: { $0 >= beforeCount + delta }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); observed tab count \(beforeCount)→\(observed).",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name); tabs \(beforeCount)→\(observed)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but could not confirm the tab effect from the window's observed state." + focusNote)
        case .tabSelectionDelta:
            if let title = try await pollDriver({ try await self.windowTitle(pid: pid, window: wid) },
                                            until: { $0 != nil && $0 != beforeTitle }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); window title changed to \"\(title ?? "")\".",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name); the window title changed." + focusNote
            }
            if let observed = try await pollDriver({ try await self.tabStrip(pid: pid, window: wid).selected },
                                               until: { $0 != nil && $0 != beforeSelected }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); selected tab became \"\(observed ?? "")\".",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but could not confirm the navigation from the window's observed state." + focusNote)
        case .windowDelta(let delta):
            if let observed = try await pollDriver({ try await Self.realWindowCount(in: self.listedWindowRows(pid: pid)) },
                                               until: { $0 >= beforeWindows + delta }) {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); observed window count \(beforeWindows)→\(observed).",
                                    appName: name, bundleID: bundle, processID: pid)
                return "\(fast.result) in \(name); windows \(beforeWindows)→\(observed)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but could not confirm a new window appeared." + focusNote)
        case .windowOffScreen:
            let gone = try await pollDriver({ () async throws -> Bool in
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
            let hidden = try await pollDriver({ () async throws -> Bool in
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
            let full = try await pollDriver({ () async throws -> Bool in
                Self.boundsCoverAScreen(try await self.windowRow(pid: pid, windowID: wid)?["bounds"])
            }, until: { $0 })
            if full == true {
                recordPostcondition(.resultObserved, "\(fast.result) in \(name); window bounds cover the screen.",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(fast.result) in \(name)." + focusNote
            }
            throw DriverConnectionError.refused("Sent \(shortcut) to \(name), but the window never covered the screen." + focusNote)
        case .boundsFromScreen:
            let shrunk = try await pollDriver({ () async throws -> Bool in
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
            // Only hotkey lanes carry a chord label — scroll's receipt is a
            // window-scroll delivery, not a keystroke.
            let receipt = shortcut.isEmpty ? "window scroll" : "\(shortcut) keystroke"
            recordPostcondition(.resultObserved, "Cua confirmed \(receipt) delivery to \(name).",
                                appName: name, bundleID: bundle, processID: pid, windowID: wid)
            let suffix = shortcut.isEmpty ? "delivered" : "\(shortcut) delivered to the window"
            return "\(fast.result) in \(name) — \(suffix)." + focusNote
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
            // A windowless/LSUIElement app has nothing for hide() to hide —
            // refusing is honest, whereas an empty rows poll would claim success.
            let rows = try await listedWindowRows(pid: pid)
            guard !rows.isEmpty else {
                throw DriverConnectionError.refused("\(name) has no windows to hide.")
            }
            // hide()/unhide() return before the transition completes and their
            // Bool is unreliable — the observation poll below is the verdict.
            // Hiding the frontmost app activates the next one — a focus
            // mutation, same as a raise.
            try await focusLeased { _ = app.hide() }
            let hidden = try await pollDriver({ () async throws -> Bool in
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
            // Already-visible windowless apps have nothing to unhide — say
            // so instead of claiming success on an empty rows poll.
            let wasHidden = app.isHidden
            let preRows = try await listedWindowRows(pid: pid)
            let hasWindows = !preRows.isEmpty
            if !wasHidden, !hasWindows {
                return "\(name) is already visible and has no windows to unhide."
            }
            if wasHidden {
                progress("Unhiding \(name)")
                try await focusLeased { _ = app.unhide() }
            } else {
                try await focusLeased { _ = app.activate(options: []) }
            }
            let shown = try await pollDriver({ () async throws -> Bool in
                guard NSRunningApplication(processIdentifier: pid_t(pid))?.isHidden == false else { return false }
                let rows = try await self.listedWindowRows(pid: pid)
                return rows.isEmpty || rows.contains { $0["is_on_screen"] != .bool(false) }
            }, until: { $0 })
            if shown == true {
                recordPostcondition(.resultObserved, "Unhid \(name); it is visible again.",
                                    appName: name, bundleID: bundle, processID: pid)
                return wasHidden ? "Unhid \(name)." : "\(name) was already visible."
            }
            throw DriverConnectionError.refused("\(name) was asked to unhide, but no window returned to the screen.")
        case .minimize:
            let rows = try await listedWindowRows(pid: pid)
            // Honor a pinned window when one exists; otherwise the topmost
            // visible window is the most likely target, matching the loop.
            let wid: Int
            if let pinned = self.windowID, rows.contains(where: { $0["window_id"]?.integer == pinned }) {
                wid = pinned
            } else {
                guard let best = Self.bestWindowID(in: rows) else {
                    throw DriverConnectionError.refused("\(name) has no observable window to minimize.")
                }
                wid = best
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
            // one settle+retry absorbs an answered-but-refused menu path.
            // Only .refused/.toolRefused retry — the driver answered, so the
            // menu definitely did not dispatch. A transport fault means the
            // first call may have landed; .unavailable/.malformed mean the
            // path itself is bad or the slot is gone, not a transient state.
            try await focusLeased {
                do {
                    _ = try await call("invoke_menu", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                       "path": .array([.string("Window"), .string("Minimize")])])
                } catch let error as DriverConnectionError {
                    switch error {
                    case .closed, .timedOut, .remote, .unavailable, .malformed: throw error
                    case .refused, .toolRefused: break
                    }
                    try await Task.sleep(for: .milliseconds(400))
                    _ = try await call("invoke_menu", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                       "path": .array([.string("Window"), .string("Minimize")])])
                }
            }
            let gone = try await pollDriver({ () async throws -> Bool in
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
            // Terminating the frontmost app activates whatever is next —
            // same focus mutation as hide().
            try await focusLeased { _ = app.terminate() }
            let gone = try await pollDriver({ () async throws -> Bool in
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
        // Element tokens are re-minted per snapshot, so the readback matches
        // by the element's slot — index first, role+label when the order
        // shifted — never by token.
        let targetIndex = target["element_index"]?.integer
        let targetRole = target["role"]?.string
        let targetLabel = target["label"]?.string ?? target["description"]?.string
        let observed = try await pollDriver { () async throws -> String? in
            let fresh = try await self.call("get_window_state", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                                 "include_screenshot": .bool(false), "max_elements": .number(220)])
            return Self.sameElement(in: fresh["elements"]?.array ?? [], index: targetIndex,
                                    role: targetRole, label: targetLabel)?["value"]?.string
        } until: { value in
            guard let value else { return false }
            // A field that already ended with the payload reads identical
            // before and after — an unchanged value proves nothing.
            if let before, value == before { return false }
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

    /// Live pids for a bundle: the workspace's process table first — the same
    /// rows list_apps resolves `running`/`pid` from, without the ~1.7s
    /// inventory scan. The driver read only runs when the workspace names no
    /// live pid, so a launch/refuse verdict keeps its driver-side check.
    private func runningPIDs(bundle: String) async throws -> [Int] {
        let local = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .filter { !$0.isTerminated }
        if !local.isEmpty { return local.map { Int($0.processIdentifier) } }
        let inventory = try await call("list_apps", [:])
        // The `running != false` predicate the loop applies everywhere —
        // a stale/exited row must not read as a live pid or trip the
        // multiple-instances refusal.
        return (inventory["apps"]?.array ?? []).compactMap {
            $0["bundle_id"]?.string == bundle && $0["running"] != .bool(false)
                ? $0["pid"]?.integer : nil
        }.filter { $0 > 0 }
    }

    private func listedWindowRows(pid: Int) async throws -> [JSONValue] {
        (try await call("list_windows", ["pid": .number(Double(pid))]))["windows"]?.array ?? []
    }

    /// `list_windows` with one recovery attempt: a daemon that refuses a
    /// read across its whole retry budget is torn down and re-minted by the
    /// transport layer, so the retry lands on a healthy daemon. Only
    /// transient faults qualify — a real refusal propagates immediately.
    private func listedWindowRowsResilient(pid: Int) async throws -> [JSONValue] {
        do {
            return try await listedWindowRows(pid: pid)
        } catch let error as DriverConnectionError where CuaConnection.transientReadFault(error) {
            try? await Task.sleep(for: .milliseconds(300))
            return try await listedWindowRows(pid: pid)
        }
    }

    /// `waitForLaunchWindow` with the same one-shot daemon-recovery retry.
    private func launchWindowResilient(pid: Int) async throws -> [JSONValue] {
        do {
            return try await waitForLaunchWindow(pid: pid)
        } catch let error as DriverConnectionError where CuaConnection.transientReadFault(error) {
            try? await Task.sleep(for: .milliseconds(300))
            return try await waitForLaunchWindow(pid: pid)
        }
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

    /// Browser chrome lives outside the page's AXWebArea — in-page
    /// lookalikes (radio groups, search inputs) must not be mistaken for
    /// app-level controls.
    private static func insideWebArea(_ element: JSONValue, indexed: [Int: JSONValue]) -> Bool {
        var node = element
        var hops = 0
        while let parent = node["parent_index"]?.integer, let upper = indexed[parent], hops < 12 {
            if upper["role"]?.string == "AXWebArea" { return true }
            node = upper; hops += 1
        }
        return false
    }

    /// An element-index map for ancestor walks — indices are per-snapshot
    /// identifiers stable enough to key within one read.
    private static func elementIndexMap(_ elements: [JSONValue]) -> [Int: JSONValue] {
        Dictionary(elements.compactMap { e in e["element_index"]?.integer.map { ($0, e) } },
                   uniquingKeysWith: { a, _ in a })
    }

    /// The window's browser-level tab strip: radio/tab elements that are NOT
    /// inside page content. On real Chrome, browser tabs are AXRadioButton
    /// children of AXWindow while in-page tab widgets live under AXWebArea —
    /// the ancestor exclusion is what separates them. `selected` carries a
    /// position-prefixed label so equal titles on different tabs still differ.
    private static func tabStrip(in elements: [JSONValue]) -> (count: Int, selected: String?) {
        let indexed = elementIndexMap(elements)
        var count = 0
        var selected: String?
        for e in elements where ["AXRadioButton", "AXTab"].contains(e["role"]?.string ?? "") && !insideWebArea(e, indexed: indexed) {
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

    /// The window's sole app-level search field: an AXSearchField, or an
    /// editable text element labelled for search — always outside page
    /// content, where a web input with "search" in its name is the app's
    /// affordance. More than one candidate is a targeting question the
    /// drive loop owns.
    static func uniqueSearchTarget(in elements: [JSONValue]) -> JSONValue? {
        let indexed = elementIndexMap(elements)
        let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]
        let candidates = elements.filter { e in
            guard e["enabled"] != .bool(false),
                  !(e["element_token"]?.string ?? "").isEmpty,
                  !insideWebArea(e, indexed: indexed) else { return false }
            let role = e["role"]?.string ?? ""
            if role == "AXSearchField" { return true }
            guard editableRoles.contains(role) else { return false }
            let label = (e["label"]?.string ?? e["description"]?.string ?? e["title"]?.string ?? "").lowercased()
            return label.contains("search")
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Element identity across snapshots: tokens are re-minted per read, so
    /// the match is the element's slot — index first, role+label as the
    /// fallback when the list order shifted. The slot is positional though:
    /// a reshuffled tree can seat a different element at it, so the
    /// role+label match wins outright and an index hit is trusted only when
    /// it still names the same control.
    static func sameElement(in elements: [JSONValue], index: Int?, role: String?, label: String?) -> JSONValue? {
        if let role, let match = elements.first(where: {
            $0["role"]?.string == role && ($0["label"]?.string ?? $0["description"]?.string) == label
        }) {
            return match
        }
        if let index, let hit = elements.first(where: { $0["element_index"]?.integer == index }) {
            if let role, hit["role"]?.string != role { return nil }
            if let label, (hit["label"]?.string ?? hit["description"]?.string) != label { return nil }
            return hit
        }
        return nil
    }

    // MARK: - Deterministic lanes beyond the keystroke table

    /// Apps "play X" may land on — the media-capable set, not "any app with
    /// a search field". Qualified plays gate on this; unqualified plays
    /// resolve the frontmost or uniquely-running member.
    private static let mediaBundles: Set<String> = [
        "com.spotify.client", "com.apple.Music", "com.apple.TV"
    ]
    private static let spotifyBundle = "com.spotify.client"

    /// The deterministic "play X" target: the frontmost media app, else the
    /// uniquely running one, else Spotify when installed — a user who keeps
    /// a music player installed and asks to play a song means that one.
    /// Several running candidates or no resolvable player stays with the
    /// drive loop.
    private static func implicitMediaApp(apps: [JSONValue], frontmostBundle: String?) -> (name: String, bundle: String)? {
        if let frontmostBundle, mediaBundles.contains(frontmostBundle),
           let app = apps.first(where: { $0["bundle_id"]?.string == frontmostBundle }),
           (app["pid"]?.integer ?? 0) > 0 {
            return (app["name"]?.string ?? frontmostBundle, frontmostBundle)
        }
        let running = apps.filter {
            mediaBundles.contains($0["bundle_id"]?.string ?? "") && ($0["pid"]?.integer ?? 0) > 0
        }
        if running.count == 1, let app = running.first, let bundle = app["bundle_id"]?.string {
            return (app["name"]?.string ?? bundle, bundle)
        }
        if running.isEmpty, let app = apps.first(where: { $0["bundle_id"]?.string == spotifyBundle }),
           let bundle = app["bundle_id"]?.string, !bundle.isEmpty {
            return (app["name"]?.string ?? bundle, bundle)
        }
        return nil
    }

    /// `spotify:search:<query>` — the URI form Spotify resolves to its
    /// results page when LaunchServices hands it over.
    nonisolated static func spotifySearchURI(_ query: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "spotify:search:" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query)
    }

    /// `play track "spotify:search:q"` through Spotify's AppleScript
    /// dictionary, then a `current track` readback — the only path that
    /// both resolves the top hit inside Spotify AND proves what is
    /// playing. Returns nil on a consent prompt, a missing Spotify, or any
    /// script failure so the caller can fall back to the URI lane. The
    /// 20s cap covers a first-run TCC consent prompt without stalling the
    /// task forever.
    func spotifyAppleScriptPlay(_ query: String) async
        -> (track: String, artist: String)? {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        guard await osascript(
            "tell application \"Spotify\" to play track \"spotify:search:\(escaped)\"",
            20) != nil else { return nil }
        // The search URI resolves asynchronously — the first readback can
        // still show the previous state ("stopped"/"paused") while Spotify
        // fetches the top hit. Poll a few seconds before giving up so a
        // slow resolve doesn't fall through to the GUI fallback.
        var playing: (track: String, artist: String)?
        for _ in 0..<8 {
            guard let state = await spotifyPlayerState() else { return nil }
            if state.playing { playing = (state.track, state.artist); break }
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: .milliseconds(600))
        }
        guard let played = playing else { return nil }
        // A cold-boot race can drop the URI argument and leave Spotify
        // resuming the previous queue — "playing" then reports whatever was
        // cued, not the search's top hit. No content word of the query in
        // the readback means the search never resolved; return nil so the
        // caller's visible-results page drives the real search instead.
        let wanted = Self.queryWords(query)
        let observed = Self.queryWords("\(played.track) \(played.artist)")
        guard !wanted.isEmpty, !wanted.isDisjoint(with: observed) else { return nil }
        return played
    }

    /// One `current track` readback — "{name, artist, player state}" with
    /// the state tail deciding `playing` and commas inside either name
    /// tolerated. nil on a consent prompt, a missing Spotify, or a script
    /// failure.
    func spotifyPlayerState() async
        -> (track: String, artist: String, playing: Bool)? {
        guard let state = await osascript(
            "tell application \"Spotify\" to get {name of current track, artist of current track, player state}",
            10) else { return nil }
        var parts = state.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        let playing = parts.removeLast() == "playing"
        let artist = parts.removeLast()
        return (track: parts.joined(separator: ", "), artist: artist, playing: playing)
    }

    /// Alphanumeric content tokens of a query or track readback, minus the
    /// filler words a "play X" utterance carries — what identifies the song.
    private nonisolated static func queryWords(_ text: String) -> Set<String> {
        let filler: Set<String> = ["play", "playing", "the", "a", "an", "by", "some",
                                   "it", "that", "this", "song", "songs", "music",
                                   "track", "tracks", "album", "for", "me", "please",
                                   "on", "in", "of", "to", "my", "spotify"]
        return Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !filler.contains($0) })
    }

    /// One osascript invocation, capped — a pending Automation consent
    /// blocks the process until the user answers, so the deadline must be
    /// enforced outside it.
    private nonisolated static func runOsaScript(_ source: String,
                                                 timeout: TimeInterval) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil as String? }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning { process.terminate(); return nil as String? }
            guard process.terminationStatus == 0 else { return nil as String? }
            let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        }.value
    }

    /// "type X here": AXSelectedText insertion at the live insertion point —
    /// the same element-scoped route dictation uses, no window binding
    /// needed. A nil return hands the request to the drive loop's richer
    /// fallback rather than failing it; a dispatched insert is verified by
    /// the focused element's AXValue readback where the app exposes one.
    private func dispatchDeicticType(_ payload: String, action: CuaFastAction, name: String,
                                     progress: (String) -> Void) async throws -> String? {
        progress(action.description)
        // The insert targets whatever app is frontmost right now — hold
        // the focus lane so a parallel task's raise can't redirect it.
        // The lease keys on this work's own id: an ad-hoc "deictic-*" name
        // would be invisible to the owning work's releaseAll at teardown,
        // and a detached release could race the next acquire.
        return try await focusLeased {
            let before = DictationDelivery.focusedElementValue()
            guard DictationDelivery.insertAtInsertionPoint(payload) else { return nil }
            return try await self.confirmDeicticInsert(payload, name: name, before: before)
        }
    }

    /// The bounded readback for a deictic insert — the insert already
    /// landed; this only proves or denies the field now holds the payload.
    private func confirmDeicticInsert(_ payload: String, name: String,
                                      before: String?) async throws -> String {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            guard let value = DictationDelivery.focusedElementValue() else {
                if attempt < 2 { continue }
                recordPostcondition(.resultObserved, "Inserted text at the insertion point in \(name); the field's value is not readable.",
                                    appName: name, bundleID: bundleID)
                return "Delivered the text at the insertion point in \(name); the focused field's value is not readable."
            }
            // A field that already contained the payload (a rerun of the
            // same request) reads identical before and after — unchanged
            // is not proof of insertion.
            if value != before, value.contains(payload) {
                recordPostcondition(.resultObserved, "Observed the typed text at the insertion point in \(name).",
                                    appName: name, bundleID: bundleID)
                return "Typed the text at the insertion point in \(name)."
            }
            if attempt == 2 {
                recordPostcondition(.resultObserved, "Inserted text at the insertion point in \(name); readback did not confirm it.",
                                    appName: name, bundleID: bundleID)
                return "Delivered the text at the insertion point in \(name); the field's value did not confirm it."
            }
        }
        return "Delivered the text at the insertion point in \(name)."
    }

    /// "go to / open <url>": a bound Chrome/Edge window takes the URL over
    /// the driver's DOM route and proves it with a page readback; otherwise
    /// LaunchServices delivers to the default browser — honest delivery,
    /// never a claimed page load.
    private func dispatchURLLane(_ url: String, progress: (String) -> Void) async throws -> String {
        progress("Opening \(url)…")
        if let browser = try await boundIsolatedBrowser() {
            do {
                if let evidence = try await navigateBoundBrowser(browser, url: url) {
                    return evidence
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let outcome as CuaUncertainOutcome {
                throw outcome // dispatched but unverifiable — don't double-navigate
            } catch let error as DriverConnectionError {
                switch error {
                case .timedOut, .closed, .unavailable:
                    // The wire died mid-dispatch — the tab may already
                    // hold the URL, so a LaunchServices re-delivery would
                    // navigate it twice.
                    throw error
                default:
                    break
                }
            } catch {
                // Binding/refusal means the DOM route is unavailable — the
                // LaunchServices path below delivers the same URL honestly.
            }
        }
        guard let target = URL(string: url) else {
            throw DriverConnectionError.refused("The URL could not be delivered to any browser.")
        }
        // LaunchServices activates the default browser — same focus lane
        // the driver's bring_to_front takes.
        guard try await focusLeased({ NSWorkspace.shared.open(target) }) else {
            throw DriverConnectionError.refused("The URL could not be delivered to any browser.")
        }
        recordPostcondition(.resultObserved, "Opened \(url) in the default browser via LaunchServices.")
        return "Opened \(url) in the default browser."
    }

    /// The deterministic browser for a navigation lane: the frontmost app
    /// when it carries an ownable DevTools endpoint, else the uniquely
    /// running one. Ambiguity returns nil and LaunchServices answers.
    private func boundIsolatedBrowser() async throws -> (pid: Int, name: String, bundle: String)? {
        if let front = NSWorkspace.shared.frontmostApplication,
           let bundle = front.bundleIdentifier,
           bundle != Bundle.main.bundleIdentifier, Self.supportsIsolatedBrowser(bundle) {
            return (Int(front.processIdentifier), front.localizedName ?? bundle, bundle)
        }
        // The workspace's live roster answers the uniquely-running check
        // without an inventory roundtrip; the driver read only runs when it
        // reports no live browser so ambiguity keeps its current verdict.
        let localBrowsers = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && Self.supportsIsolatedBrowser($0.bundleIdentifier ?? "")
        }
        if localBrowsers.count > 1 { return nil }
        if let app = localBrowsers.first, let bundle = app.bundleIdentifier {
            return (Int(app.processIdentifier), app.localizedName ?? bundle, bundle)
        }
        let apps = (try await call("list_apps", [:]))["apps"]?.array ?? []
        let running = apps.filter {
            Self.supportsIsolatedBrowser($0["bundle_id"]?.string ?? "") && ($0["pid"]?.integer ?? 0) > 0
        }
        guard running.count == 1, let app = running.first,
              let bundle = app["bundle_id"]?.string, let pid = app["pid"]?.integer else { return nil }
        return (pid, app["name"]?.string ?? bundle, bundle)
    }

    /// browser_navigate against the bound window's resolvable tab, verified
    /// by the page's own URL readback — the same contract the drive loop's
    /// navigate case honors. A nil return means no addressable browser was
    /// bound at all; an unverified dispatch throws uncertain, not refused.
    private func navigateBoundBrowser(_ browser: (pid: Int, name: String, bundle: String),
                                      url: String) async throws -> String? {
        let rows = try await listedWindowRows(pid: browser.pid)
        guard let wid = Self.bestWindowID(in: rows) else { return nil }
        let state = try await call("get_browser_state", ["pid": .number(Double(browser.pid)),
                                                         "window_id": .number(Double(wid))])
        let tabs = CuaBrowserTarget.tabs(state)
        guard let targetID = CuaBrowserTarget.targetID(state),
              let tab = CuaBrowserTarget.resolveNavigationTab(tabs: tabs, baseline: nil, newTabRequested: false),
              let tabID = tab["tab_id"]?.string else { return nil }
        let outcome = try await call("browser_navigate", [
            "target_id": targetID, "tab_id": .string(tabID), "url": .string(url)])
        // Verify on the addressed tab itself: a page-scoped read must report
        // the destination url — never a same-titled sibling tab. Host
        // equality, not substring: "apple.com" must not pass against
        // "notapple.com", while subdomains still match their registrable
        // host.
        let wantedHost = URLComponents(string: url)?.host?.lowercased()
            ?? url.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                .split(separator: "/").first.map(String.init)?.lowercased()
        for _ in 0..<6 {
            // `page.url` exists only under semantic_v2; the default
            // dom_refs_v1 read carries the address at the top level.
            if let after = try? await call("get_browser_state", ["pid": .number(Double(browser.pid)),
                                                                 "window_id": .number(Double(wid)),
                                                                 "target_id": targetID, "tab_id": .string(tabID)]),
               let pageURL = after["page"]?["url"]?.string ?? after["url"]?.string,
               let wantedHost,
               Self.urlHostMatches(pageURL, wanted: wantedHost) {
                bundleID = browser.bundle
                recordPostcondition(.resultObserved, "Opened \(url) in \(browser.name); the tab reports the destination.",
                                    appName: browser.name, bundleID: browser.bundle, processID: browser.pid, windowID: wid)
                return "Opened \(url) in \(browser.name)."
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CuaUncertainOutcome(tool: "browser_navigate", result: outcome)
    }

    /// Host equality with a subdomain allowance: "www.apple.com" satisfies
    /// a request for "apple.com" (and vice versa — the site redirects), but
    /// "notapple.com" never does.
    static func urlHostMatches(_ pageURL: String, wanted host: String) -> Bool {
        var observed = URLComponents(string: pageURL)?.host?.lowercased() ?? ""
        if observed.isEmpty {
            observed = pageURL.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                .split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        }
        let observedHost = observed.split(separator: ":").first.map(String.init) ?? observed
        let wantedHost = host.split(separator: ":").first.map(String.init) ?? host
        guard !wantedHost.isEmpty else { return false }
        return observedHost == wantedHost
            || observedHost.hasSuffix("." + wantedHost)
            || wantedHost.hasSuffix("." + observedHost)
    }

    /// "search <app> for X" on a non-Spotify target: element-scoped text into
    /// the app's unique search field plus a window-scoped Return. The field's
    /// value readback is the typed-text evidence; a cheap title poll after
    /// Return is the navigation evidence — either unobservable side is
    /// reported as delivered, never as confirmed.
    private func dispatchAppSearch(_ query: String, playTopHit: Bool, pid: Int, window wid: Int,
                                   name: String) async throws -> String? {
        let snapshot = try await call("get_window_state", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                           "include_screenshot": .bool(false), "max_elements": .number(220)])
        let elements = snapshot["elements"]?.array ?? []
        guard let target = Self.uniqueSearchTarget(in: elements) else { return nil }
        let before = target["value"]?.string
        let targetIndex = target["element_index"]?.integer
        let targetRole = target["role"]?.string
        let targetLabel = target["label"]?.string ?? target["description"]?.string
        _ = try await call("type_text", [
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "element_token": .string(target["element_token"]?.string ?? ""),
            "delivery_mode": .string("background"),
            "text": .string(query)
        ])
        let fieldHoldsQuery = try await pollDriver { () async throws -> Bool in
            let fresh = try await self.call("get_window_state", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                                 "include_screenshot": .bool(false), "max_elements": .number(220)])
            let value = Self.sameElement(in: fresh["elements"]?.array ?? [], index: targetIndex,
                                         role: targetRole, label: targetLabel)?["value"]?.string
            // Identical before and after means nothing landed — the query
            // already sat in the field.
            return value != before && value?.localizedCaseInsensitiveContains(query) == true
        } until: { $0 }
        let beforeTitle = try? await windowTitle(pid: pid, window: wid)
        _ = try await call("press_key", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                         "key": .string("return"), "delivery_mode": .string("background")])
        let moved = try await pollDriver(attempts: 4, { try await self.windowTitle(pid: pid, window: wid) },
                                     until: { $0 != nil && $0 != beforeTitle }) ?? nil
        let label = targetLabel ?? "the search field"
        let verb = playTopHit ? "Dispatched play for" : "Searched \(name) for"
        if fieldHoldsQuery == true {
            let evidence = "\(verb) \"\(query)\"; the field held it."
            recordPostcondition(.resultObserved, evidence, appName: name, bundleID: bundleID,
                                processID: pid, windowID: wid, windowTitle: moved)
            return moved != nil ? "\(evidence) The window moved to results." : evidence
        }
        recordPostcondition(.resultObserved, "Delivered \"\(query)\" to \(label) in \(name) and pressed Return; the field's value was not independently confirmed.",
                            appName: name, bundleID: bundleID, processID: pid, windowID: wid)
        return "Delivered \"\(query)\" to \(label) in \(name) and pressed Return; the field's value was not independently confirmed."
    }

    /// Spotify's deterministic search URI: launch_app hands the URI to
    /// LaunchServices (no activation needed), the app lands on the results
    /// page, and a window-scoped Return starts the top hit. Spotify's AX
    /// tree blanks for ~a beat around submission, so verification reads
    /// around the gap and the result is reported as dispatched — never as
    /// "playing".
    private func dispatchSpotifySearch(_ query: String, playTopHit: Bool, pid: Int, window wid: Int,
                                       name: String) async throws -> String {
        // Deterministic play first: Spotify's own scripting bridge resolves
        // "spotify:search:" to the top hit and starts it — no AX field, no
        // blind Return, and `current track` proves what actually started. A
        // consent wall or a Spotify build without the command returns nil
        // and the URI+Return path below carries the task.
        if playTopHit, !spotifyScriptingTried,
           let played = await spotifyAppleScriptPlay(query) {
            recordPostcondition(.resultObserved,
                                "Spotify reports playing \"\(played.track)\" by \(played.artist).",
                                appName: name, bundleID: Self.spotifyBundle,
                                processID: pid, windowID: wid)
            return "Playing \(played.track) by \(played.artist) on Spotify."
        }
        let uri = Self.spotifySearchURI(query)
        if !launchURIsDelivered {
            do {
                _ = try await focusLeased { try await call("launch_app", ["bundle_id": .string(Self.spotifyBundle),
                                                  "urls": .array([.string(uri)])]) }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DriverConnectionError {
                switch error {
                case .timedOut, .closed, .unavailable:
                    // A dead transport after dispatch could mean the URI
                    // already reached LaunchServices — re-delivering it
                    // would fire the same hand-off twice.
                    throw error
                default:
                    // The driver's URL hand-off is LaunchServices
                    // underneath — the workspace route delivers the same
                    // URI honestly.
                    guard let target = URL(string: uri) else { throw error }
                    guard try await focusLeased({ NSWorkspace.shared.open(target) }) else { throw error }
                }
            }
            launchURIsDelivered = true
        }
        // Wait for the results surface, not a fixed delay: Spotify mirrors
        // the URI query into its search box, so a field holding the query
        // is the page-rendered signal. Cold launches and login walls can
        // outlive a fixed sleep — Return pressed then lands on the home
        // page's focused element, not the top result. Spotify can mirror
        // the ENCODED form back ("no+mistakes"/"no%20mistakes"), so the
        // raw and both wire spellings all prove the page.
        let queryForms = [query,
                          query.replacingOccurrences(of: " ", with: "+"),
                          query.addingPercentEncoding(withAllowedCharacters:
                            .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? query]
        let resultsReady = try await pollDriver(attempts: 7, { () async throws -> Bool in
            let state = try await self.call("get_window_state", ["pid": .number(Double(pid)),
                                                                 "window_id": .number(Double(wid)),
                                                                 "include_screenshot": .bool(false),
                                                                 "max_elements": .number(220)])
            return (state["elements"]?.array ?? []).contains { element in
                let role = element["role"]?.string ?? ""
                guard ["AXTextField", "AXComboBox", "AXSearchField", "AXTextArea"].contains(role) else { return false }
                guard let value = element["value"]?.string, !value.isEmpty else { return false }
                return queryForms.contains { value.localizedCaseInsensitiveContains($0) }
            }
        }, until: { $0 }) ?? false
        if !playTopHit {
            recordPostcondition(.resultObserved, "Delivered \(uri) to Spotify; the results page is Spotify's to render.",
                                appName: name, bundleID: Self.spotifyBundle, processID: pid, windowID: wid)
            return "Opened a Spotify search for \"\(query)\"."
        }
        guard resultsReady == true else {
            // No evidence the results page exists — a blind Return presses
            // whatever element holds focus. The search was delivered;
            // top-hit play is honestly undispatched.
            recordPostcondition(.resultObserved, "Delivered \(uri) to Spotify but the results page never became observable; play was not dispatched.",
                                appName: name, bundleID: Self.spotifyBundle, processID: pid, windowID: wid)
            return "Opened a Spotify search for \"\(query)\"; the results page could not be confirmed, so play was not dispatched."
        }
        let beforeTitle = try? await windowTitle(pid: pid, window: wid)
        _ = try await call("press_key", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                         "key": .string("return"), "delivery_mode": .string("background")])
        // Spotify's title rarely reflects the track — an unchanged title
        // proves nothing either way, so a moved title is evidence and a
        // still one is honest delivery.
        let moved = try await pollDriver(attempts: 4, { try await self.windowTitle(pid: pid, window: wid) },
                                     until: { $0 != nil && $0 != beforeTitle }) ?? nil
        // The Return ran its settle window — name what is actually playing
        // so a wrong top hit reads as the track it is, not "dispatched".
        if let nowPlaying = await spotifyPlayerState(), nowPlaying.playing {
            recordPostcondition(.resultObserved,
                "Spotify reports playing \"\(nowPlaying.track)\" by \(nowPlaying.artist).",
                appName: name, bundleID: Self.spotifyBundle, processID: pid,
                windowID: wid, windowTitle: moved)
            return "Searched Spotify for \"\(query)\" — playing \(nowPlaying.track) by \(nowPlaying.artist)."
        }
        if let moved {
            recordPostcondition(.resultObserved, "Spotify's window moved to \"\(moved)\" after the dispatched play.",
                                appName: name, bundleID: Self.spotifyBundle, processID: pid,
                                windowID: wid, windowTitle: moved)
            return "Searched Spotify for \"\(query)\" and dispatched play to the top result; the window moved to \"\(moved)\"."
        }
        recordPostcondition(.resultObserved, "Delivered \(uri) to Spotify and sent Return to the top result.",
                            appName: name, bundleID: Self.spotifyBundle, processID: pid, windowID: wid)
        return "Searched Spotify for \"\(query)\" and dispatched play to the top result."
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
        return coversAnyScreen(x: x, y: y, width: w, height: h,
                               screens: NSScreen.screens.map(\.frame))
    }

    /// Top-left-origin AX/CGWindow bounds against bottom-left-origin
    /// NSScreen frames — the spaces coincide only on the primary display.
    /// `screens` is NSScreen-ordered (first = the zero-origin primary
    /// screen); a frame's top-left y is primaryHeight − y − height.
    static func coversAnyScreen(x: Double, y: Double, width: Double, height: Double,
                                screens: [CGRect]) -> Bool {
        guard let primaryHeight = screens.first?.height else { return false }
        return screens.contains { f in
            abs(x - f.origin.x) < 3 && abs(y - (primaryHeight - f.origin.y - f.height)) < 3
                && abs(width - f.width) < 3 && abs(height - f.height) < 3
        }
    }

    /// Poll a cheap Driver read until `until` holds or the budget expires.
    /// Keystroke effects land in tens of milliseconds; the bound keeps an
    /// undeliverable effect honest instead of hanging the task. Read
    /// failures propagate — a dead transport or an uncertain outcome must
    /// never be folded into "the effect did not happen."
    private func pollDriver<T>(attempts: Int = 10,
                               _ read: () async throws -> T, until: (T) -> Bool) async throws -> T? {
        for attempt in 0..<attempts {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            let value = try await read()
            if until(value) { return value }
        }
        return nil
    }

    /// Browsers the driver's typed CDP route attests: Chrome and Edge carry
    /// an ownable DevTools endpoint; Safari/Firefox have no DOM binding and
    /// stay on the native/keyboard lanes.
    nonisolated static func supportsIsolatedBrowser(_ bundle: String) -> Bool {
        ["com.google.Chrome", "com.microsoft.edgemac"].contains(bundle)
    }

    /// Returns the successful poll's window rows so callers reuse them
    /// rather than paying a second list_windows for the same observation.
    private func waitForLaunchWindow(pid: Int) async throws -> [JSONValue] {
        // Bounded patience for a just-launched first window — a real window
        // materializes in well under a second; a menu-bar app never shows one
        // and "opened" stays honest instead of stalling the whole lane.
        for _ in 0..<8 {
            try Task.checkCancellation()
            let windows = (try await call("list_windows", ["pid": .number(Double(pid))]))["windows"]?.array ?? []
            if windows.contains(where: {
                $0["is_on_screen"] != .bool(false) || !($0["title"]?.string ?? "").isEmpty
            }) { return windows }
            try await Task.sleep(for: .milliseconds(100))
        }
        // A slow first launch can need a nudge: activating a running app opens
        // its main window for document-style apps before this refuses.
        _ = try? await focusLeased { NSRunningApplication(processIdentifier: pid_t(pid))?.activate() }
        for _ in 0..<4 {
            try Task.checkCancellation()
            let windows = (try await call("list_windows", ["pid": .number(Double(pid))]))["windows"]?.array ?? []
            if windows.contains(where: {
                $0["is_on_screen"] != .bool(false) || !($0["title"]?.string ?? "").isEmpty
            }) { return windows }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DriverConnectionError.refused("The launched app did not show an observable window. The launch was not repeated; inspect the app before retrying.")
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
        // A hotkey description names no keyword but carries the same effect:
        // ⌘Q quits, ⌘W closes, ⌘⌫ trashes, ⇧⌘Q signs out, ⇧⌘⌫ empties it.
        let chords = ["cmd+q", "command+q", "⌘q", "cmd+w", "command+w", "⌘w",
                      "cmd+delete", "command+delete", "⌘⌫", "cmd+backspace",
                      "cmd+shift+q", "shift+cmd+q", "cmd+shift+delete",
                      "shift+cmd+delete", "cmd+option+esc", "command+option+esc"]
        if chords.contains(where: { actionText.contains($0) }) { return true }
        // A bare confirm keystroke inside a send-style request is the send.
        let goalText = goal.lowercased()
        let sendContext = ["send", "submit", "post", "reply", "publish"].contains { goalText.contains($0) }
        let confirmKey = ["press return", "press enter", "press the return", "press the enter"].contains { actionText.contains($0) }
        if sendContext && confirmKey { return true }
        return goalText.contains("force quit") && actionText.contains("force quit")
    }

    /// "what's on my clipboard": the owner's own pasteboard read, spoken
    /// back truncated. No consent — the lane never writes, and the text is
    /// already the user's. Empty and non-text clipboards say so honestly.
    private func dispatchClipboardRead(_ action: CuaFastAction,
                                       progress: (String) -> Void) async throws -> String {
        progress(action.description)
        let result = try await pasteboardLeased {
            try await call("clipboard_read", ["include_text": .bool(true)])
        }
        let types = result["types"]?.array?.compactMap { $0.string } ?? []
        guard var text = result["text"]?.string, !text.isEmpty else {
            let holding = types.isEmpty ? ""
                : " It holds \(types.prefix(4).joined(separator: ", ")) — not text."
            recordPostcondition(.resultObserved,
                                "Clipboard read: no text on the pasteboard.\(holding)")
            return types.isEmpty
                ? "Your clipboard is empty."
                : "Your clipboard has no text.\(holding)"
        }
        // One spoken line, ~300 chars — the pasteboard can hold a book.
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                   .trimmingCharacters(in: .whitespaces)
        let clipped = text.count > 300 ? String(text.prefix(300)) + "…" : text
        recordPostcondition(.resultObserved,
                            "Read \(text.count) character(s) of text off the pasteboard.")
        return "Your clipboard says: \(clipped)"
    }

    /// "copy X to my clipboard": a verbatim payload onto the owner's own
    /// pasteboard — no consent — proven by a same-lease readback so the
    /// write can never race a peer lane's clipboard work.
    private func dispatchClipboardWrite(_ payload: String, action: CuaFastAction,
                                        progress: (String) -> Void) async throws -> String {
        progress(action.description)
        let readback = try await pasteboardLeased { () async throws -> JSONValue in
            _ = try await call("clipboard_write", ["text": .string(payload)])
            return try await call("clipboard_read", ["include_text": .bool(true)])
        }
        guard readback["text"]?.string == payload else {
            recordPostcondition(.resultObserved,
                                "clipboard_write completed but the readback did not hold the payload.")
            return "Copied — the clipboard readback did not confirm it."
        }
        recordPostcondition(.resultObserved,
                            "Verified \(payload.count) character(s) on the pasteboard after the write.")
        return "On your clipboard."
    }

    /// "force quit X": SIGKILL through the driver's kill_app — the
    /// escalation the graceful `.quit` can't reach. The approval replaces
    /// the drive loop's per-action judgment; a nil approve means the loop
    /// keeps its own say. The process-gone poll is the proof — never the
    /// driver's send receipt.
    private func runKillApp(pid: Int, name: String, bundle: String,
                            progress: (String) -> Void) async throws -> String? {
        guard let approve else { return nil }
        guard try await approve("Force quit \(name)? Unsaved work is lost — the app cannot ask you to save first.") else {
            throw CancellationError()
        }
        // Re-resolve liveness through the same table the launch path reads —
        // killing a stale pid could hit a recycled process.
        guard try await runningPIDs(bundle: bundle).contains(pid) else {
            throw DriverConnectionError.refused("\(name) is no longer running. Nothing was changed.")
        }
        progress("Force quitting \(name)")
        _ = try await call("kill_app", ["pid": .number(Double(pid))])
        let gone = try await pollDriver({ () async throws -> Bool in
            NSRunningApplication(processIdentifier: pid_t(pid))?.isTerminated ?? true
        }, until: { $0 })
        if gone == true {
            recordPostcondition(.resultObserved, "Force quit \(name); the process exited.",
                                appName: name, bundleID: bundle, processID: pid)
            return "Force quit \(name)."
        }
        throw DriverConnectionError.refused("\(name) was sent SIGKILL but is still running.")
    }

    /// set_window_frame against the bound window — snap halves, maximize,
    /// center, other display. Geometry comes from NSScreen's visible frame
    /// (menu bar and Dock excluded) converted into WindowServer's
    /// top-left-origin space; the driver's own WindowServer readback is the
    /// verdict, so its "suspected_noop"/"unverifiable" effects are reported
    /// as what they are.
    private func dispatchWindowFrame(_ verb: CuaFastAction.WindowVerb,
                                     pid: Int, window wid: Int, rows: [JSONValue],
                                     name: String, bundle: String,
                                     fast: CuaFastAction) async throws -> String {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            throw DriverConnectionError.refused("No display is attached.")
        }
        let bounds = rows.first(where: { $0["window_id"]?.integer == wid })?["bounds"]
        func number(_ value: JSONValue?) -> Double? {
            guard case .number(let d)? = value, d.isFinite else { return nil }
            return d
        }
        // NSScreen frames sit in the bottom-left-origin screen space;
        // WindowServer/AX bounds are top-left origin on the primary display.
        // A frame converts by y_ax = primaryHeight − y_ns − height.
        func toAX(_ r: CGRect) -> (x: Double, y: Double, w: Double, h: Double) {
            (r.origin.x, primaryHeight - r.origin.y - r.height, r.width, r.height)
        }
        // The screen holding the window's center owns the snap; a window
        // whose bounds never resolve lands on the main screen.
        var screen = NSScreen.main ?? NSScreen.screens.first
        if let x = number(bounds?["x"]), let y = number(bounds?["y"]),
           let w = number(bounds?["width"]), let h = number(bounds?["height"]) {
            let centerNS = CGPoint(x: x + w / 2, y: primaryHeight - (y + h / 2))
            if let hosting = NSScreen.screens.first(where: { $0.frame.contains(centerNS) }) {
                screen = hosting
            }
        }
        guard let current = screen else {
            throw DriverConnectionError.refused("No display is attached.")
        }
        var target = toAX(current.visibleFrame)
        switch verb {
        case .left:
            target.w /= 2
        case .right:
            target.x += target.w / 2
            target.w /= 2
        case .top:
            target.h /= 2
        case .bottom:
            target.y += target.h / 2
            target.h /= 2
        case .fill:
            break
        case .center:
            guard let w = number(bounds?["width"]), let h = number(bounds?["height"]) else {
                throw DriverConnectionError.refused("The window's current size could not be read to center it.")
            }
            target.x += (target.w - w) / 2
            target.y += (target.h - h) / 2
            target.w = w
            target.h = h
        case .otherDisplay:
            guard let other = NSScreen.screens.first(where: { $0 != current }) else {
                return "There's only one display — nowhere else to move \(name)'s window."
            }
            guard let w = number(bounds?["width"]), let h = number(bounds?["height"]) else {
                throw DriverConnectionError.refused("The window's current size could not be read to move it.")
            }
            target = toAX(other.visibleFrame)
            target.x += (target.w - w) / 2
            target.y += (target.h - h) / 2
            target.w = w
            target.h = h
        }
        let result = try await call("set_window_frame", [
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "x": .number(target.x), "y": .number(target.y),
            "width": .number(target.w), "height": .number(target.h)])
        switch result["effect"]?.string {
        case "confirmed":
            recordPostcondition(.resultObserved,
                                "\(fast.result) in \(name); WindowServer confirmed the frame.",
                                appName: name, bundleID: bundle, processID: pid, windowID: wid)
            return "\(fast.result) in \(name)."
        case "suspected_noop":
            recordPostcondition(.resultObserved,
                                "\(name)'s window was already near the target frame — no visible change.",
                                appName: name, bundleID: bundle, processID: pid, windowID: wid)
            return "\(name)'s window was already there."
        default:
            // "unverifiable" (or anything else): the driver dispatched but
            // could not prove the frame — say exactly that, never "moved".
            recordPostcondition(.resultObserved,
                                "set_window_frame on \(name) reported \(result["effect"]?.string ?? "no effect").",
                                appName: name, bundleID: bundle, processID: pid, windowID: wid)
            return "Asked \(name)'s window to move; the new frame could not be verified."
        }
    }

    /// invoke_menu on the bound window with exact menu-bar paths. The lane
    /// asks once when the verb is destructive (closeTab) — that replaces the
    /// drive loop's per-action judgment — and a background app pays the same
    /// temporary-focus grant the loop's own menu path asks for (invoke_menu
    /// raises it itself and restores focus). The driver's listed-refusal
    /// outcome is reported; the lane never manufactures success.
    private func dispatchMenuVerb(_ verb: CuaFastAction.MenuVerb,
                                  pid: Int, window wid: Int,
                                  name: String, bundle: String) async throws -> String? {
        let path = verb.path
        if case .closeTab = verb {
            guard let approve else { return nil }
            guard try await approve("Close the current tab in \(name)?") else {
                throw CancellationError()
            }
        }
        // invoke_menu temporarily focuses a background app — same standing
        // grant the loop asks for.
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid)
        if !isFront, !CuaStandingGrants.menuFocus(bundle: bundle) {
            guard let approve,
                  try await approve("Temporarily focus \(name) to perform:\n\(path.joined(separator: " → "))\nCua restores the prior focus afterward. Granted once per app — Jarvis remembers this.") else {
                throw CancellationError()
            }
            CuaStandingGrants.grantMenuFocus(bundle: bundle)
        }
        // One settle+retry absorbs an answered-but-refused menu path on a
        // just-raised app, matching the minimize lane — only driver
        // refusals retry, never transport faults.
        let args: [String: JSONValue] = ["pid": .number(Double(pid)),
                                         "window_id": .number(Double(wid)),
                                         "path": .array(path.map { .string($0) })]
        let result: JSONValue
        do {
            result = try await focusLeased {
                do {
                    return try await call("invoke_menu", args)
                } catch let error as DriverConnectionError {
                    switch error {
                    case .closed, .timedOut, .remote, .unavailable, .malformed: throw error
                    case .refused, .toolRefused: break
                    }
                    try await Task.sleep(for: .milliseconds(400))
                    return try await call("invoke_menu", args)
                }
            }
        } catch let error as DriverConnectionError {
            // A listed refusal reaches us as a typed toolRefused — the
            // driver answered: the path is missing, disabled or ambiguous.
            // Report it as "not there right now"; other refusals are real
            // failures and propagate.
            if case .toolRefused(tool: "invoke_menu", code: "menu_path_unavailable", detail: _) = error {
                recordPostcondition(.resultObserved,
                                    "\(name) refused \(path.joined(separator: " → ")) (menu_path_unavailable).",
                                    appName: name, bundleID: bundle, processID: pid, windowID: wid)
                return "\(name) doesn't have that menu item right now."
            }
            throw error
        }
        if result["status"]?.string == "listed" {
            recordPostcondition(.resultObserved,
                                "\(name) resolved the path to a submenu but no leaf command was named.",
                                appName: name, bundleID: bundle, processID: pid, windowID: wid)
            return "\(name) doesn't have that menu item right now."
        }
        recordPostcondition(.resultObserved,
                            "Invoked \(path.joined(separator: " → ")) in \(name).",
                            appName: name, bundleID: bundle, processID: pid, windowID: wid)
        return "Invoked \(path.joined(separator: " → ")) in \(name)."
    }

    /// "what's on my screen": the bound window's AX state read aloud —
    /// app, title, the first few readable strings and control counts.
    /// `elements[]` carries only actionable nodes, so the spoken text comes
    /// from `tree_markdown`'s non-indexed `= "value"` lines. Sparse trees
    /// report sparseness; the user gets truth over theatre.
    private func dispatchScreenRead(pid: Int, window wid: Int, rows: [JSONValue],
                                    name: String, bundle: String) async throws -> String {
        let snapshot = try await call("get_window_state", [
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "include_screenshot": .bool(false), "max_elements": .number(150)])
        let elements = snapshot["elements"]?.array ?? []
        let title = snapshot["window_title"]?.string
            ?? rows.first(where: { $0["window_id"]?.integer == wid })?["title"]?.string
            ?? ""
        let fieldRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox",
                                       "AXSearchField", "AXSecureTextField"]
        var buttons = 0
        var fields = 0
        for element in elements {
            let role = element["role"]?.string ?? ""
            if role == "AXButton" { buttons += 1 }
            if fieldRoles.contains(role) { fields += 1 }
        }
        // Display-only nodes render as `- AXRole = "value"` in the markdown —
        // the readable text the elements array leaves out. First five, ≤80
        // characters each, deduplicated in order.
        var texts: [String] = []
        let markdown = snapshot["tree_markdown"]?.string ?? ""
        if let expression = try? NSRegularExpression(
            pattern: #"- AX(?:StaticText|Title|Heading|Label)\s*=\s*"([^"]*)""#) {
            for match in expression.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
                guard texts.count < 5,
                      let range = Range(match.range(at: 1), in: markdown) else { break }
                let text = String(markdown[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !texts.contains(text) else { continue }
                texts.append(text.count > 80 ? String(text.prefix(80)) + "…" : text)
            }
        }
        let heading = title.isEmpty ? "\(name)'s window" : "\(name)'s window “\(title)”"
        let degraded = snapshot["degraded"] == .bool(true)
        var spoken = "On your screen: \(heading)."
        if texts.isEmpty, elements.isEmpty {
            spoken += degraded
                ? " The accessibility read was degraded — nothing readable came back."
                : " Nothing in it is readable to accessibility."
        } else {
            if !texts.isEmpty {
                spoken += " It says: " + texts.map { "“\($0)”" }.joined(separator: ", ") + "."
            }
            var counts: [String] = []
            if buttons > 0 { counts.append("\(buttons) button\(buttons == 1 ? "" : "s")") }
            if fields > 0 { counts.append("\(fields) text field\(fields == 1 ? "" : "s")") }
            if !counts.isEmpty { spoken += " I see \(counts.joined(separator: " and "))." }
        }
        recordPostcondition(.resultObserved,
                            "Read the screen aloud for \(name): \(elements.count) element(s), \(texts.count) spoken text(s).",
                            appName: name, bundleID: bundle, processID: pid,
                            windowID: wid, windowTitle: title.isEmpty ? nil : title)
        return spoken
    }

    /// Fixed osascript templates for the script lanes — the payload is the
    /// template choice, never freeform text. `set volume` and `player
    /// state` ride Standard Additions / the app's own dictionary; a consent
    /// prompt blocks until the deadline, which runOsaScript caps. `return`
    /// inside a `tell` returns from the whole script.
    nonisolated static func scriptSource(_ verb: CuaFastAction.ScriptVerb) -> String {
        switch verb {
        case .nowPlaying:
            // AppleScript has no "\t" escape — `tab` is the tab constant.
            // `player state is not stopped` guards the track read: a stopped
            // player's `current track` property raises instead of answering.
            return """
            set out to ""
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is not stopped then
                        set out to (name of current track) & tab & (artist of current track) & tab & ((player state) as string) & tab & "Spotify"
                    end if
                end tell
            else if application "Music" is running then
                tell application "Music"
                    if player state is not stopped then
                        set out to (name of current track) & tab & (artist of current track) & tab & ((player state) as string) & tab & "Music"
                    end if
                end tell
            end if
            return out
            """
        case .volumeUp:
            return """
            set v to (output volume of (get volume settings)) + 10
            if v > 100 then set v to 100
            set volume output volume v
            return v
            """
        case .volumeDown:
            return """
            set v to (output volume of (get volume settings)) - 10
            if v < 0 then set v to 0
            set volume output volume v
            return v
            """
        case .mute(let target):
            if let target {
                return target
                    ? "set volume with output muted\nreturn output muted of (get volume settings)"
                    : "set volume without output muted\nreturn output muted of (get volume settings)"
            }
            return """
            if output muted of (get volume settings) then
                set volume without output muted
                return "false"
            else
                set volume with output muted
                return "true"
            end if
            """
        case .setVolume(let level):
            let clamped = min(100, max(0, level))
            return "set volume output volume \(clamped)\nreturn output volume of (get volume settings)"
        case .getVolume:
            return "set s to get volume settings\nreturn (output volume of s) & tab & (output muted of s)"
        }
    }

    /// script lanes: deterministic osascript templates interpreted into
    /// honest spoken answers — the track name/state for now-playing, the
    /// read-back level/mute state for volume. A nil script result means a
    /// permission prompt or error kept the answer from coming.
    private func dispatchScriptVerb(_ verb: CuaFastAction.ScriptVerb,
                                    action: CuaFastAction,
                                    progress: (String) -> Void) async throws -> String {
        progress(action.description)
        let timeout: TimeInterval = verb == .nowPlaying ? 15 : 8
        guard let out = await osascript(Self.scriptSource(verb), timeout) else {
            throw DriverConnectionError.refused("The script did not answer — a permission prompt may be waiting for your attention.")
        }
        switch verb {
        case .nowPlaying:
            let parts = out.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else {
                recordPostcondition(.resultObserved,
                                    "Now-playing query: no player running.")
                return "Nothing is playing."
            }
            let artist = parts[1].isEmpty ? "" : " by \(parts[1])"
            switch parts[2] {
            case "playing" where !parts[0].isEmpty:
                recordPostcondition(.resultObserved,
                                    "\(parts[3]) reports playing \"\(parts[0])\" by \(parts[1]).")
                return "Playing \(parts[0])\(artist) on \(parts[3])."
            case "paused" where !parts[0].isEmpty:
                recordPostcondition(.resultObserved,
                                    "\(parts[3]) reports paused \"\(parts[0])\" by \(parts[1]).")
                return "Paused: \(parts[0])\(artist) on \(parts[3])."
            default:
                recordPostcondition(.resultObserved,
                                    "Now-playing query: \(parts[3]) reports \(parts[2]).")
                return "Nothing is playing."
            }
        case .volumeUp, .volumeDown, .setVolume:
            let level = Int(out.trimmingCharacters(in: .whitespaces))
            if let level {
                recordPostcondition(.resultObserved, "System output volume read back at \(level).")
                return "Volume at \(level)."
            }
            recordPostcondition(.resultObserved, "Volume adjusted; the read-back level was not parseable.")
            return "Adjusted the volume."
        case .mute:
            let muted = out == "true"
            recordPostcondition(.resultObserved,
                                muted ? "Output muted." : "Output unmuted.")
            return muted ? "Muted." : "Unmuted."
        case .getVolume:
            let parts = out.split(separator: "\t").map(String.init)
            let level = parts.first ?? out
            let muted = parts.count > 1 && parts[1] == "true"
            recordPostcondition(.resultObserved,
                                "Output volume read at \(level)\(muted ? " (muted)" : "").")
            return muted ? "Muted — the volume is at \(level)." : "Volume at \(level)."
        }
    }

    /// A fixed URL scheme through LaunchServices — Shortcuts runs in place.
    /// `.delivered` is the honest postcondition: the run itself reports
    /// through Shortcuts, not the driver.
    private func dispatchSystemURL(_ verb: CuaFastAction.SystemVerb,
                                   action: CuaFastAction,
                                   progress: (String) -> Void) async throws -> String {
        progress(action.description)
        guard let target = verb.url else {
            throw DriverConnectionError.refused("The shortcut URL could not be built.")
        }
        guard try await focusLeased({ NSWorkspace.shared.open(target) }) else {
            throw DriverConnectionError.refused("The shortcut could not be delivered to Shortcuts.")
        }
        recordPostcondition(.resultObserved, "\(action.result); delivered to Shortcuts.")
        return "\(action.result)."
    }

}
