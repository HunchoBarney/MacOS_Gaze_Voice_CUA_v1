import AppKit
import Foundation
import JarvisCore

/// The deterministic half of the drive path. `run()` resolves a
/// `FastResolution` before the observe→choose loop: a verb whose correct
/// execution is a known chord, app primitive, or URL is dispatched
/// directly and its `Effect` is verified from live state — zero model
/// calls, ~0.4s instead of a drive round.
///
/// Nothing here fabricates: an unverifiable effect is refused with the
/// observation that held, and a transport fault propagates rather than
/// replaying a maybe-landed mutation.
extension DriveLoop {
    @MainActor
    static func capturedForegroundApplication(
        application: String?, windowID: Int?,
        frontmost: @MainActor () -> AppResolver.App? = {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundle = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return AppResolver.App(name: name, bundle: bundle, pid: Int(app.processIdentifier))
        },
        focusedWindow: @MainActor (Int) -> Int? = { FocusedTextBinding.capturedWindowID(pid: $0) }
    ) -> AppResolver.App? {
        guard let application, let windowID, windowID > 0,
              let current = frontmost(), let pid = current.pid, pid > 0,
              !current.name.isEmpty, current.bundle == application,
              focusedWindow(pid) == windowID else { return nil }
        return current
    }

    @MainActor
    static func openForegroundApplication(_ bundleID: String) async throws -> Int {
        try Task.checkCancellation()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              Bundle(url: url)?.bundleIdentifier == bundleID else {
            throw DriverConnectionError.refused("The requested application is no longer installed.")
        }
        return try await withVoiceDeadline(until: ProcessInfo.processInfo.systemUptime + 5) { @MainActor in
            try Task.checkCancellation()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.hides = false
            configuration.createsNewApplicationInstance = false
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            guard !app.isTerminated, app.bundleIdentifier == bundleID else {
                throw DriverConnectionError.refused("The requested application identity could not be verified.")
            }
            return Int(app.processIdentifier)
        }
    }

    /// A fast-lane resolution: the deterministic action (or open verb) plus
    /// the uniquely resolved app identity. `launchURLs` rides the app's
    /// `launch_app` hand-off (URI schemes, file opens).
    struct FastResolution: Sendable {
        let action: FastAction?
        let openVerb: String?
        let name: String
        let bundle: String
        /// The resolved app row's live pid — nil when the app isn't running.
        var pid: Int? = nil
        var launchURLs: [String] = []
        /// The qualifier was the display-scope sentinel ("on this monitor") —
        /// the app can't be known until live window rows answer which display
        /// the gaze point sits on. `runFastLane` resolves it at dispatch.
        var displayScoped = false
        var isScroll: Bool {
            if case .scroll? = action?.body { return true }
            return false
        }
    }

    /// The outcome of one whole-utterance parse attempt. A risk-gated
    /// command is a veto, not a miss — it must not fall through to the
    /// open/search lanes or the appHint merge and resolve as something else.
    private enum ParsedOutcome {
        case resolved(FastResolution)
        case unresolved
        case vetoed
    }

    /// Parse + resolve only — no dispatch. Nil when the utterance is not
    /// exactly one known primitive against an unambiguous installed app, so
    /// the drive loop owns it. `appHint` is the model-supplied `app` argument —
    /// used only when the instruction itself names no app.
    static func resolveFastLane(goal: String, apps: [JSONValue], appHint: String? = nil,
                                frontmostBundle: String?) -> FastResolution? {
        if let parsed = FastAction.parse(goal) {
            switch Self.resolveParsed(parsed, goal: goal, apps: apps,
                                      appHint: appHint, frontmostBundle: frontmostBundle) {
            case .resolved(let resolution): return resolution
            case .vetoed: return nil
            case .unresolved: break
            }
        }
        // A bare "search [for] X" qualified by no app or engine is a web
        // search in a fresh tab — not an app named "search for X" for
        // launch_app to refuse. Runs only after the qualified parses so
        // "search spotify for X" keeps its in-app lane.
        if let action = FastAction.parseBareSearch(goal),
           !Self.requiresRiskJudgment(goal: goal, actionDescription: action.description) {
            return FastResolution(action: action, openVerb: nil, name: "", bundle: "")
        }
        if let parsed = FastAction.parseOpen(goal),
           let resolution = Self.resolveOpenParsed(parsed, goal: goal, apps: apps,
                                                   frontmostBundle: frontmostBundle) {
            return resolution
        }
        // The model's `app` argument can complete a phrase that doesn't
        // parse alone — "quit" + app:"Devin" reads as "quit devin" and
        // lanes as app control; "focus" + app:"Devin" opens it. The merge
        // retries only after the bare utterance resolved nothing — a
        // spoken qualifier or resolved lane always wins. The bare-search
        // lane is deliberately not retried: the app word is never a query.
        guard let appHint, !appHint.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let merged = goal + " " + appHint
        if let parsed = FastAction.parse(merged) {
            switch Self.resolveParsed(parsed, goal: goal, apps: apps,
                                      appHint: nil, frontmostBundle: frontmostBundle) {
            case .resolved(let resolution): return resolution
            case .vetoed: return nil
            case .unresolved: break
            }
        }
        if let parsed = FastAction.parseOpen(merged),
           let resolution = Self.resolveOpenParsed(parsed, goal: merged, apps: apps,
                                                   frontmostBundle: frontmostBundle) {
            return resolution
        }
        return nil
    }

    /// Resolve one `parse` result to a fast-lane resolution — app-free
    /// lanes, the qualifier loop, and the implicit-media fallback.
    /// Factored so the appHint merge retry runs the identical pipeline on
    /// "goal + appHint" instead of duplicating it.
    private static func resolveParsed(_ parsed: (action: FastAction, appQualifier: String?),
                                      goal: String, apps: [JSONValue], appHint: String?,
                                      frontmostBundle: String?) -> ParsedOutcome {
        // Global lanes need no app and must not queue behind an app
        // lease — a media key is a system event, not a window action.
        if case .mediaKey = parsed.action.body {
            guard !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description)
            else { return .vetoed }
            return .resolved(FastResolution(action: parsed.action, openVerb: nil, name: "", bundle: ""))
        }
        // Gaze referents need no app either — the target is a screen
        // point. A peeled qualifier ("click this in chrome") is ignored:
        // the referent is what the user is looking at.
        if case .gaze = parsed.action.body {
            guard !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description)
            else { return .vetoed }
            return .resolved(FastResolution(action: parsed.action, openVerb: nil, name: "", bundle: ""))
        }
        // Tracker self-control needs no app either — it steers the
        // tracker process ("pause tracking"), not a window.
        if case .tracker = parsed.action.body {
            guard !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description)
            else { return .vetoed }
            return .resolved(FastResolution(action: parsed.action, openVerb: nil, name: "", bundle: ""))
        }
        // The desktop and overlay lanes need no app either — a system
        // chord posts scope:"desktop", "do that again" replays the
        // coordinator's log, "where did X go" hunts every window,
        // overlay verbs number what's under the gaze point, and
        // dictation verbs steer the capture lane. Peeled qualifiers are
        // emphasis, the same as the gaze referents above.
        switch parsed.action.body {
        case .systemHotkey, .overlay, .repeatLast, .locate, .dictation:
            guard !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description)
            else { return .vetoed }
            return .resolved(FastResolution(action: parsed.action, openVerb: nil, name: "", bundle: ""))
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
            // "on this monitor" names a display, not an app — the target
            // is the app owning the topmost window on the screen under
            // the gaze point. Live window rows answer that at dispatch
            // time; the resolution only marks the lane display-scoped.
            if qualifier == FastAction.gazeDisplayQualifier {
                guard !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description)
                else { return .vetoed }
                var resolution = FastResolution(action: parsed.action, openVerb: nil,
                                                name: "", bundle: "")
                resolution.displayScoped = true
                return .resolved(resolution)
            }
            // "search google for X" names an engine, not an installed
            // app — the engine URL is the deterministic target. The
            // check runs before app resolution so an installed app
            // whose name merely contains the engine word ("Google
            // Chrome") can't capture a site-search intent.
            if let qualifier, case .appSearch(let query, _) = parsed.action.body,
               let url = ActionCatalog.namedEngineSearchURL(engine: qualifier, query: query),
               !Self.requiresRiskJudgment(goal: goal,
                                          actionDescription: "Searching \(qualifier) for '\(query)'") {
                return .resolved(FastResolution(action: FastAction(
                        body: .navigateURL(url), generic: true,
                        description: "Searching \(qualifier) for '\(query)'",
                        result: "Opened the results", effect: .delivered),
                    openVerb: nil, name: "", bundle: ""))
            }
            guard let resolved = FastAction.resolveApp(qualifier: qualifier,
                                                       action: parsed.action,
                                                       apps: apps, frontmostBundle: frontmostBundle),
                  !parsed.action.needsTabbableApp || FastAction.tabbableBundles.contains(resolved.bundle) else {
                continue
            }
            // "play X" only lands on a media app; a non-media resolution
            // is the loop's question, not a search field to guess at.
            if case .appSearch(_, let playTopHit) = parsed.action.body, playTopHit,
               !Self.mediaBundles.contains(resolved.bundle) { continue }
            // A literally-named mutation is its own consent — the gate
            // only stops actions the user didn't name.
            guard parsed.action.selfApproves || parsed.action.directlyRequested
                    || !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description) else { break }
            var resolution = FastResolution(action: parsed.action, openVerb: nil,
                                            name: resolved.name, bundle: resolved.bundle)
            resolution.pid = Self.livePID(bundle: resolved.bundle, in: apps)
            if case .appSearch(let query, _) = parsed.action.body, resolved.bundle == Self.spotifyBundle {
                resolution.launchURLs = [Self.spotifySearchURI(query)]
            }
            return .resolved(resolution)
        }
        // A bare "play X" that resolved no media app above still has one
        // deterministic reading: the frontmost or uniquely-running media
        // app, or an installed Spotify.
        if parsed.appQualifier == nil, case .appSearch(_, let playTopHit) = parsed.action.body,
           playTopHit,
           !Self.requiresRiskJudgment(goal: goal, actionDescription: parsed.action.description),
           let media = Self.implicitMediaApp(apps: apps, frontmostBundle: frontmostBundle) {
            var resolution = FastResolution(action: parsed.action, openVerb: nil,
                                            name: media.name, bundle: media.bundle)
            resolution.pid = Self.livePID(bundle: media.bundle, in: apps)
            if media.bundle == Self.spotifyBundle, case .appSearch(let query, _) = parsed.action.body {
                resolution.launchURLs = [Self.spotifySearchURI(query)]
            }
            return .resolved(resolution)
        }
        return .unresolved
    }

    /// Resolve one `parseOpen` result — a uniquely named app rides the
    /// open/raise contract; a URL-shaped tail that names no app is a
    /// navigation request ("go to apple.com" binds a browser or goes
    /// through LaunchServices; a tail carrying more than the address
    /// stays with the drive loop).
    private static func resolveOpenParsed(_ parsed: (verb: String, query: String),
                                          goal: String, apps: [JSONValue],
                                          frontmostBundle: String?) -> FastResolution? {
        if let resolved = FastAction.resolveOpenApp(query: parsed.query, apps: apps,
                                                  frontmostBundle: frontmostBundle) {
            var resolution = FastResolution(action: nil, openVerb: parsed.verb,
                                            name: resolved.name, bundle: resolved.bundle)
            resolution.pid = Self.livePID(bundle: resolved.bundle, in: apps)
            return resolution
        }
        if let url = ActionCatalog.explicitBrowserNavigationURL(in: goal),
           !Self.requiresRiskJudgment(goal: goal, actionDescription: "Opening \(url)") {
            return FastResolution(action: FastAction(
                    body: .navigateURL(url), generic: true,
                    description: "Opening \(url)", result: "Opened \(url)", effect: .delivered),
                openVerb: nil, name: "", bundle: "")
        }
        return nil
    }

    /// Execute a resolved fast-lane request: bring the app to a running
    /// state, dispatch the primitive, and prove its effect — zero model
    /// calls. Returns nil only when nothing was dispatched and the request
    /// needs the drive loop's disambiguation (e.g. several editable fields).
    ///
    /// Consent: a spoken command IS its own consent — these lanes need no
    /// standing grant — but every dispatch still runs `gateExplicit`'s
    /// deny scan over the target it would touch (app names, URLs, menu
    /// paths, window/dialog titles, a committed element's label). When
    /// `explicitConsent` is off (agent-authored goals) the same lanes
    /// ride the standing grant / per-task confirm instead.
    func runFastLane(_ resolved: FastResolution, task: DriveTask, session: String,
                     history: inout [String],
                     confirmed: inout Bool,
                     nativeEvents: (@Sendable (VoiceCommandTrace.Stage) async -> Void)? = nil,
                     scrollLines: Int? = nil,
                     scrollAnchor: NativeWindowObservation.ScrollViewport? = nil) async throws -> DriveResult? {
        let nativeEvent = nativeEvents ?? self.nativeEvent
        var bundle = resolved.bundle
        var name = resolved.name
        var displayPID: Int?
        try Task.checkCancellation()
        // App-free lanes dispatch before any inventory read: media keys post
        // to the HID tap and a navigation URL binds a browser or goes
        // through LaunchServices.
        if let action = resolved.action {
            switch action.body {
            case .mediaKey(let key):
                feed(action.description)
                try await gateExplicit("media key", corpus: action.description,
                                       denied: task.deny, confirmed: &confirmed)
                guard postMediaKey(key) else {
                    let why = MediaKeys.refusal == .postAccessDenied
                        ? "macOS denied the synthetic key — check Accessibility and Input Monitoring permissions. Nothing was delivered."
                        : "The system key event could not be created. Nothing was delivered."
                    throw DriverConnectionError.refused(why)
                }
                return done("\(action.result).", task, history, effect: true)
            case .systemHotkey(let keys, _):
                feed(action.description)
                // A desktop-scope chord — the driver's frontmost/system
                // target, never a pid. The delivery receipt is the honest
                // effect: there is no AX readback for "locked the screen".
                try await gateExplicit("hotkey",
                                       corpus: "\(action.description) \(keys.joined(separator: "+"))",
                                       denied: task.deny, confirmed: &confirmed)
                do {
                    _ = try await call("hotkey", ["keys": .array(keys.map { .string($0) }),
                                                  "scope": .string("desktop"),
                                                  "session": .string(session)])
                } catch let error as DriverConnectionError {
                    if case .toolRefused(_, _, let detail) = error {
                        return settle(.blocked(detail), task, history)
                    }
                    throw error
                }
                return done("\(action.result).", task, history, effect: true)
            case .navigateURL(let url):
                feed(action.description)
                try await gateExplicit("browser_navigate", corpus: url,
                                       denied: task.deny, confirmed: &confirmed)
                return try await dispatchURLLane(url, task: task, session: session, history: &history)
            case .webSearch(let url):
                feed(action.description)
                try await gateExplicit("web search", corpus: url,
                                       denied: task.deny, confirmed: &confirmed)
                return try await dispatchWebSearch(url, task: task, history: &history)
            case .gaze(let verb):
                feed(action.description)
                guard Self.gazeEnabled() else {
                    return settle(.blocked(Self.eyesOffReply(verb)), task, history,
                                  blockedReason: "eye tracking off")
                }
                // Gaze referents dispatch on the gaze session — the same
                // label the candidate feed's reads mint element tokens
                // under, and a cursorless lane the coordinator's
                // transport suppresses once: the eyes are the pointing
                // device, so no agent cursor should chase the pick.
                return try await runGazeVerb(verb, task: task,
                                             session: VoiceTaskCoordinator.gazeSession,
                                             history: &history, confirmed: &confirmed)
            case .dictation(let start):
                feed(action.description)
                try await gateExplicit("dictation", corpus: action.description,
                                       denied: task.deny, confirmed: &confirmed)
                guard let onDictationRequest, await onDictationRequest(start) else {
                    return settle(.blocked(start
                        ? "Dictation isn't available — it's off in Settings or nothing can capture right now."
                        : "No dictation is running."),
                                  task, history, blockedReason: "dictation unavailable")
                }
                return done(start
                    ? "Dictation is on — speak, then tap Fn or say 'stop dictating' to finish."
                    : "Stopped dictating.",
                    task, history, effect: true)
            case .tracker(let verb):
                feed(action.description)
                try await gateExplicit("tracker control", corpus: action.description,
                                       denied: task.deny, confirmed: &confirmed)
                do {
                    try await Self.dispatchTrackerVerb(verb)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return settle(.blocked(await Self.trackerVerbRefusal()),
                                  task, history, blockedReason: "tracker control failed")
                }
                return done("\(action.result).", task, history, effect: true)
            case .overlay(let verb):
                feed(action.description)
                try await gateExplicit("overlay pick", corpus: action.description,
                                       denied: task.deny, confirmed: &confirmed)
                return try await runOverlayVerb(verb, task: task, session: session,
                                                history: &history)
            case .repeatLast:
                feed(action.description)
                // The coordinator owns the replay log and replays confirmed
                // actions before a task ever reaches the loop — a task that
                // still lands here has nothing behind it to repeat.
                return settle(.blocked("Nothing to repeat."), task, history,
                              blockedReason: "no action to replay")
            case .locate(let query):
                feed(action.description)
                try await gateExplicit("locate window", corpus: "\(action.description) \(query)",
                                       denied: task.deny, confirmed: &confirmed)
                return try await runLocate(query, task: task, session: session,
                                           history: &history)
            default:
                break
            }
        }
        // A deictic window verb ("minimize this", "close it", "hide this")
        // names the window under the user's eyes — resolve it before app
        // binding so the action lands on the gazed window, never the
        // frontmost app's focused one. A dead tracker refuses like a
        // deictic type: retargeting the frontmost window is a mutation
        // the user didn't point at.
        if let action = resolved.action, Self.pointsByGaze(action),
           let control = Self.deicticWindowControl(for: action) {
            return try await runDeicticWindowControl(control, action: action, task: task,
                                                     session: session, history: &history,
                                                     confirmed: &confirmed)
        }
        // A display-scoped qualifier ("minimize on this monitor") names no
        // app — the target is the app owning the topmost window on the
        // display under the gaze point. It resolves here, not in the static
        // resolver, because it needs live window rows.
        if resolved.displayScoped {
            switch try await displayScopedApp(session: session) {
            case .app(let scopedName, let scopedBundle, let scopedPID):
                name = scopedName; bundle = scopedBundle; displayPID = scopedPID
            case .refused(let why):
                return settle(.blocked(why), task, history,
                              blockedReason: "display scope unresolved")
            }
        }
        // "click open in maps": a control called that in the frontmost
        // window wins over the app the tail names. Only a label that is or
        // starts with the phrase counts: a link that merely mentions it
        // ("How to save in Pages documents") must not win over Pages.
        if let action = resolved.action, case .clickNamed = action.body, let whole = action.wholeName,
           let frontBundle = frontmostBundleID(), let frontPID = frontmostPID(),
           let frontWindow = frontmostWindowID() {
            bindConsentIdentity(name: NSRunningApplication(processIdentifier: pid_t(frontPID))?.localizedName,
                                bundleID: frontBundle)
            if let clicked = try await runNamedTarget(whole, clicks: true, anywhere: false, pid: frontPID,
                                                      windowID: frontWindow, windowTitle: "",
                                                      task: task, session: session,
                                                      history: &history, confirmed: &confirmed) {
                return clicked
            }
        }
        guard !bundle.isEmpty else { return nil }
        // Consent now knows its scope — an "Always" answer on this lane's
        // asks persists against exactly this (action, bundle) pair.
        bindConsentIdentity(name: name, bundleID: bundle)

        // The consent gate covers the whole lane once: the command names
        // its app and its action, so launching/dispatching shares the
        // utterance's consent — for agent-authored goals it shares one
        // grant check. The corpus joins the action's own words, the app
        // name, any launch URL, and a menu path — the pieces a deny
        // match would act through.
        var bindCorpus = [resolved.action?.description ?? resolved.openVerb ?? "", name]
        bindCorpus += resolved.launchURLs
        if case .menu(let path) = resolved.action?.body { bindCorpus += path }
        try await gateExplicit(resolved.openVerb != nil ? "bring_to_front" : "launch_app",
                               corpus: bindCorpus.joined(separator: " "),
                               denied: task.deny, confirmed: &confirmed)

        // Bind the app: launch (background) if not running. `launchURLs`
        // ride the launch hand-off so the app receives them on arrival.
        var launchedPID: Int?
        var foregroundLaunched = false
        var pid = task.pid ?? displayPID ?? resolved.pid ?? Self.runningPID(bundle: bundle, in: [])
        if pid == nil, task.windowID != nil || task.windowName != nil {
            return settle(.blocked("The pinned application's window is no longer available. No replacement was launched."),
                          task, history, blockedReason: "pinned app missing")
        }
        let nativeFocus = resolved.openVerb != nil
            && (task.foreground || FastAction.openRequiresRaise(goal: task.goal))
            && resolved.launchURLs.isEmpty && task.windowID == nil && task.windowName == nil
        if pid == nil, nativeFocus, let foregroundAppLauncher {
            do {
                pid = try await tracedNativeActivation(events: nativeEvent) {
                    try await foregroundAppLauncher(bundle)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A native request may have reached LaunchServices. Never
                // launch again through the background primitive after error.
                pid = await observeLaunchedPID(bundle)
            }
            guard let observed = pid, observed > 0 else {
                return settle(.blocked("The foreground launch could not be observed. Nothing was retried."),
                              task, history, blockedReason: "native launch unverifiable")
            }
            launchedPID = observed
            foregroundLaunched = true
        } else if pid == nil {
            var args: [String: JSONValue] = ["bundle_id": .string(bundle),
                                             "session": .string(session)]
            if !resolved.launchURLs.isEmpty {
                args["urls"] = .array(resolved.launchURLs.map { .string($0) })
            }
            do {
                let launched = try await call("launch_app", args)
                let payload = launched["structuredContent"] ?? launched
                pid = payload["pid"]?.integer
                launchedPID = pid
            } catch is CuaUncertainOutcome {
                // A suppressed background launch produces no window change
                // inside the daemon's post-mutation window, so launch_app
                // can honestly report "effect unknown". Never replay the
                // mutation — verify by observation instead: AppKit knows
                // whether the process is running without any driver grant.
                pid = await Self.observedPID(bundle: bundle)
                guard pid != nil else {
                    return settle(.blocked("The launch was dispatched but its result is unknown, and \(name) is not running. Nothing was retried."),
                                  task, history, blockedReason: "launch unverifiable")
                }
                launchedPID = pid
            } catch let error as DriverConnectionError {
                if case .toolRefused(_, _, let detail) = error {
                    return settle(.blocked(detail), task, history)
                }
                if case .remote(let text) = error {
                    return settle(.blocked(text), task, history)
                }
                throw error
            }
        }
        guard let pid, pid > 0 else {
            return settle(.blocked("Could not launch or find \(name)."), task, history)
        }

        if let verb = resolved.openVerb {
            return try await runOpenVerb(verb, pid: pid, name: name, bundle: bundle,
                                         didLaunch: launchedPID != nil,
                                         foregroundLaunched: foregroundLaunched,
                                         allowsNativeProof: nativeFocus && resolved.action == nil,
                                         nativeEvents: nativeEvent,
                                         task: task, session: session, history: &history)
        }
        guard let action = resolved.action else { return nil }
        if case .appControl(let verb) = action.body {
            return try await runAppControl(verb, pid: pid, name: name, bundle: bundle,
                                           task: task, session: session, history: &history,
                                           alreadyConfirmed: confirmed)
        }

        // Window-scoped lanes: materialize a window, capture the pre-state
        // the effect predicate reads, dispatch, verify.
        var retainedTextTarget: FocusedTextBinding.Capture?
        var nativeTextWindow: FocusedTextBinding.WindowSnapshot?
        if requiresCapturedTextTarget, case .type(let payload) = action.body,
           !Self.pointsByGaze(action), !resolved.displayScoped, task.windowName == nil,
           !BrowserSupport.isBrowser(bundleID: bundle),
           task.application == bundle, task.values["text"] == payload,
           CuaPolicy.deniedInTypedPayload(payload) == nil, let pinned = task.windowID {
            let captured = await focusedTextTarget(pid, pinned)
            retainedTextTarget = captured.map { .bound($0) } ?? .unavailable
            if let read = captured?.windowSnapshot, let observed = await read(),
               observed.pid == pid, observed.windowID == pinned, observed.isOnScreen {
                nativeTextWindow = observed
            }
        }
        var rows: [JSONValue]
        if let observed = nativeTextWindow {
            rows = [.object(["pid": .number(Double(observed.pid)),
                             "window_id": .number(Double(observed.windowID)),
                             "title": .string(observed.title), "is_on_screen": .bool(true)])]
            history.append("Native captured typing window proof: exact owner and on-screen window.")
        } else {
            rows = try await listedWindowRows(pid: pid, session: session)
        }
        if task.windowID == nil, rows.isEmpty {
            rows = await materialize(pid: pid, bundle: bundle, didLaunch: launchedPID != nil,
                                     session: session)
        }
        if case .scroll = action.body, let pinned = task.windowID {
            let matches = rows.filter { $0["window_id"]?.integer == pinned }
            guard matches.count == 1, let row = matches.first, row["pid"]?.integer == pid,
                  task.windowName == nil || windowID(named: task.windowName, in: matches) == pinned else {
                return settle(.blocked("The pinned scroll window has no unique verified owner."),
                              task, history, blockedReason: "pinned scroll window changed")
            }
        }
        if let pinned = task.windowID, !rows.isEmpty,
           !rows.contains(where: { $0["window_id"]?.integer == pinned }) {
            throw DriverConnectionError.refused("The pinned target window closed. No other window was substituted.")
        }
        let wid = task.windowID ?? windowID(named: task.windowName, in: rows) ?? Self.bestWindowID(in: rows)
        guard let windowID = wid else {
            return settle(.blocked("\(name) has no observable window to act on."),
                          task, history, pid: pid)
        }

        // The bound window's title joins the corpus — Return on a
        // "Confirm purchase" dialog or a menu path like "Empty Trash"
        // refuses on the window's own words, not just the action's.
        let windowTitle = rows.first(where: {
            $0["window_id"]?.integer == windowID
        })?["title"]?.string ?? ""
        var actionCorpus = [action.description, name, windowTitle]
        if case .menu(let path) = action.body { actionCorpus += path }
        try await gateExplicit(Self.fastLaneToolName(for: action),
                               corpus: actionCorpus.joined(separator: " "),
                               denied: task.deny, confirmed: &confirmed)

        feed(action.description)
        switch action.body {
        case .hotkey(let keys, _):
            return try await runWindowHotkey(keys: keys, action: action, pid: pid,
                                             windowID: windowID, name: name, bundle: bundle,
                                             task: task, session: session, history: &history)
        case .menu(let path):
            return try await runMenuPath(path, action: action, pid: pid,
                                         windowID: windowID, name: name, bundle: bundle,
                                         task: task, session: session, history: &history)
        case .windowFrame(let snap):
            return try await runWindowSnap(snap, action: action, pid: pid,
                                           windowID: windowID, name: name, bundle: bundle,
                                           task: task, session: session, history: &history)
        case .clickNamed(let spoken), .showNamed(let spoken):
            var clicks = false
            if case .clickNamed = action.body { clicks = true }
            return try await runNamedTarget(spoken, clicks: clicks, pid: pid, windowID: windowID,
                                            windowTitle: windowTitle, task: task, session: session,
                                            history: &history, confirmed: &confirmed)
        case .scroll(let direction, let pages):
            return try await runVerifiedScroll(direction: direction, pages: pages, task: task,
                window: WindowRef(pid: pid, windowID: windowID), name: name, bundle: bundle,
                session: session, history: &history, lineAmount: scrollLines, scrollAnchor: scrollAnchor)
        case .type(let payload):
            // "type X here" binds the target to the gaze point — a dead
            // or unsure tracker must not retarget the bound/frontmost
            // window: typing into it is a mutation the user didn't
            // point at. Non-deictic type keeps the bound-window path.
            if Self.pointsByGaze(action) {
                let sample: GazeSample
                do {
                    sample = try await gazeSample()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return settle(.blocked("The eye tracker isn't answering — tell me which window instead."),
                                  task, history, pid: pid, windowID: windowID,
                                  blockedReason: "deictic gaze unavailable")
                }
                guard let target = try await windowAtPoint(CGPoint(x: sample.x, y: sample.y),
                                                         session: session) else {
                    return settle(.blocked("There's no window where you're looking — tell me which window you mean."),
                                  task, history, pid: pid, windowID: windowID,
                                  blockedReason: "no window at gaze point")
                }
                // The window under the gaze is the typed-text's context —
                // scan its identity for the corpus, then the payload
                // itself: the command-shaped deny list reads the actual
                // text before any dispatch (the field-label scan can't
                // see it, same as `decide`'s args["text"] rule).
                if let hit = CuaPolicy.deniedInTypedPayload(payload) {
                    feed("denied: typed payload \(hit)")
                    throw Abort.denied("Refused: the text itself runs '\(hit)' — shell-shaped input is the user's own hands, not ours")
                }
                try await gateExplicit("type_text",
                                       corpus: "\(target.app) \(target.title)",
                                       denied: task.deny, confirmed: &confirmed)
                let px = Self.desktopPixels(CGPoint(x: sample.x, y: sample.y))
                _ = try await call("click", ["scope": .string("desktop"),
                                             "x": .number(px.x), "y": .number(px.y),
                                             "session": .string(session)])
                _ = try await call("type_text",
                                   ["pid": .number(Double(target.pid)),
                                    "text": .string(payload),
                                    "session": .string(session)])
                return done("Typed at the point you were looking at.", task, history,
                            pid: target.pid, windowID: target.windowID,
                            bundleID: bundle, effect: true)
            }
            return try await dispatchFastType(payload, pid: pid, window: windowID,
                                              name: name, bundle: bundle, task: task,
                                              session: session, history: &history,
                                              confirmed: &confirmed, retainedTarget: retainedTextTarget)
        case .appSearch(let query, let playTopHit):
            return try await dispatchAppSearch(query, playTopHit: playTopHit, pid: pid,
                                               window: windowID, name: name, bundle: bundle,
                                               task: task, session: session, history: &history,
                                               confirmed: &confirmed)
        case .mediaKey, .systemHotkey, .navigateURL, .webSearch, .appControl,
             .gaze, .tracker, .overlay, .repeatLast, .locate, .dictation:
            return nil // handled above
        }
    }

    // MARK: - Open / raise contract

    /// Every open verb ends at the same contract: the exact window verified
    /// in front (raise verbs) or the process observed running and fronted
    /// (launch verbs). Windows materialize on reopen/activate — never settle
    /// "no window" without spending both.
    private func runOpenVerb(_ verb: String, pid: Int, name: String, bundle: String,
                             didLaunch: Bool, foregroundLaunched: Bool, allowsNativeProof: Bool,
                             nativeEvents nativeEvent: @escaping @Sendable (VoiceCommandTrace.Stage) async -> Void,
                             task: DriveTask, session: String,
                             history: inout [String]) async throws -> DriveResult {
        let needsRaise = FastAction.openRequiresRaise(goal: task.goal)
        let needsForeground = needsRaise || task.foreground
        var nativeForegroundRequested = foregroundLaunched
        if needsForeground, task.windowID == nil, appIsHidden(pid) {
            // `activate()` cannot materialize a window in a hidden running
            // app on every macOS version. `unhide()` can return false even
            // though the OS restores it asynchronously; trust observed state,
            // then still demand a real window and a verified raise.
            _ = try await tracedNativeActivation(events: nativeEvent, restoringHidden: true) { self.unhideApp(pid) }
            nativeForegroundRequested = true
            let restored = try await pollDriver({ self.appIsHidden(pid) }, until: { !$0 })
            guard restored == false else {
                return settle(.blocked("\(name) is hidden and could not be restored."),
                              task, history, pid: pid, blockedReason: "unhide failed")
            }
        }
        if needsForeground, !foregroundLaunched, task.windowID == nil, task.windowName == nil {
            try await tracedNativeActivation(events: nativeEvent) { self.activateRestoredApp(pid, bundle) }
            nativeForegroundRequested = true
        }
        if allowsNativeProof, needsForeground, nativeForegroundRequested,
           task.windowID == nil, task.windowName == nil {
            let observed: Int? = try await focusLeased {
                try await self.pollDriver(attempts: 3,
                    {
                        await nativeEvent(.nativeForegroundReadBegin)
                        let window = await self.nativeForegroundWindow(pid)
                        await nativeEvent(.nativeForegroundReadEnd)
                        return window
                    }, until: { $0 != nil })
            } ?? nil
            try Task.checkCancellation()
            if let window = observed {
                await nativeEvent(.nativeForegroundVerified)
                history.append("Native foreground verified by active PID, focused AX window and fresh on-screen CG owner row.")
                return done("Brought \(name) forward; verified its focused window in front.",
                            task, history, pid: pid, windowID: window, bundleID: bundle, effect: true)
            }
        }
        var rows = try await listedWindowRows(pid: pid, session: session)
        if task.windowID == nil, rows.isEmpty {
            rows = await materialize(pid: pid, bundle: bundle, didLaunch: didLaunch,
                                     session: session)
        }
        if rows.isEmpty, !didLaunch, needsForeground, task.windowID == nil, task.windowName == nil {
            // Running-but-windowless: the reopen event launch_app sends
            // materializes the default window (Chrome all-closed, Notes).
            _ = try? await focusLeased { try await self.call("launch_app",
                ["bundle_id": .string(bundle), "session": .string(session)]) }
            rows = await materialize(pid: pid, bundle: bundle, didLaunch: true,
                                     session: session)
        }
        let addressable = rows.filter {
            ($0["window_id"]?.integer ?? 0) > 0
                && ($0["pid"]?.integer == nil || $0["pid"]?.integer == pid)
        }
        if let pinned = task.windowID, !rows.isEmpty,
           !addressable.contains(where: { $0["window_id"]?.integer == pinned }) {
            throw DriverConnectionError.refused("The pinned target window closed. No other window was substituted.")
        }
        if task.windowID == nil, let named = task.windowName,
           windowID(named: named, in: addressable) == nil {
            return settle(.blocked("The named target window was not found. No other window was substituted."),
                          task, history, pid: pid, blockedReason: "named window missing")
        }
        var wid = task.windowID ?? windowID(named: task.windowName, in: addressable)
            ?? Self.bestWindowID(in: addressable)
        if wid == nil, needsForeground, task.windowID == nil, task.windowName == nil,
           let native = await nativeFocusedWindowID(pid), native > 0 {
            try Task.checkCancellation()
            let groundsNative: ([JSONValue]) -> Bool = { inventory in
                inventory.contains {
                    $0["window_id"]?.integer == native
                        && ($0["pid"]?.integer == nil || $0["pid"]?.integer == pid)
                }
            }
            if groundsNative(rows) {
                wid = native
            } else if let fresh = try await pollDriver({ try await self.listedWindowRows(pid: pid, session: session) },
                                                       until: groundsNative) {
                rows = fresh
                wid = native
            }
            if wid == native {
                history.append("Window inventory: native window identity matched an addressable driver row.")
            }
        }
        if let wid {
            // A just-launched window may still be materializing — settle
            // once and retry the verified raise. The driver's exact-window
            // verification is stricter than the outcome the user sees, so
            // the workspace frontmost read plus an on-screen row is real
            // evidence too.
            let canVerifyNativeEffect = nativeForegroundRequested && needsForeground
                && task.windowID == nil && task.windowName == nil
            let raised = try await focusLeased { () async throws -> Bool in
                if canVerifyNativeEffect {
                    let verified = try await self.pollDriver(attempts: 3, { () async throws -> Bool in
                        guard self.frontmostPID() == pid, self.frontmostWindowID() == wid else { return false }
                        let nativeWindow = await self.nativeFocusedWindowID(pid)
                        try Task.checkCancellation()
                        guard nativeWindow == wid else { return false }
                        let current = try? await self.windowRow(pid: pid, windowID: wid, session: session)
                        try Task.checkCancellation()
                        return current?["is_on_screen"] == .bool(true)
                            && self.frontmostPID() == pid && self.frontmostWindowID() == wid
                    }, until: { $0 })
                    try Task.checkCancellation()
                    if verified == true {
                        history.append("Window inventory: native foreground effect independently verified; skipped redundant driver raise.")
                        return true
                    }
                }
                try Task.checkCancellation()
                var activation: JSONValue
                var canRetry = true
                do {
                    activation = try await self.call("bring_to_front",
                        ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                         "session": .string(session)])
                } catch is CancellationError { throw CancellationError()
                } catch is CuaUncertainOutcome {
                    // The action may already have landed. Do not dispatch
                    // it again; only independent PID + exact-window readback
                    // may turn this uncertain receipt into verified success.
                    activation = .object([:])
                    canRetry = false
                } catch let error as DriverConnectionError {
                    switch error {
                    case .closed, .timedOut, .unavailable, .malformed, .toolRefused: throw error
                    case .refused, .remote: activation = .object([:])
                    }
                }
                if canRetry, !(activation["activated"] == .bool(true)
                     && activation["exact_window_effect"]?["verified"] == .bool(true)) {
                    try await Task.sleep(for: .milliseconds(400))
                    activation = (try? await self.call("bring_to_front",
                        ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                         "session": .string(session)])) ?? activation
                }
                if activation["activated"] == .bool(true)
                    && activation["exact_window_effect"]?["verified"] == .bool(true) { return true }
                return (try? await self.verifyForeground(pid: pid, windowID: wid, session: session)) == true
            }
            if raised {
                let proof = needsRaise ? "Brought \(name) forward" : "Opened \(name)"
                return done("\(proof); verified its window in front.", task, history,
                            pid: pid, windowID: wid, bundleID: bundle, effect: true)
            }
            if needsForeground {
                return settle(.blocked("\(name)'s window could not be verified in front. The foreground request was not satisfied."),
                              task, history, pid: pid, windowID: wid,
                              blockedReason: "raise unverified")
            }
            return done("Opened \(name); its window exists but front status was not verified.",
                        task, history, pid: pid, windowID: wid, bundleID: bundle, effect: true)
        }
        if needsForeground {
            history.append("Window inventory: rows=\(rows.count), addressable=\(addressable.count), visible=\(rows.filter { $0["is_on_screen"] == .bool(true) }.count), titled=\(rows.filter { !($0["title"]?.string ?? "").isEmpty }.count)")
            return settle(.blocked("\(name) has no observable window to bring forward."),
                          task, history, pid: pid,
                          blockedReason: "no window to raise")
        }
        // A windowless foreground open still activates the app so the
        // request has a visible effect; apps that never front (menu-bar
        // agents) fall through to the observed-running report.
        try? await focusLeased { self.activateApp(pid) }
        return done(didLaunch ? "Opened \(name)." : "\(name) was already running; brought it forward.",
                    task, history, pid: pid, bundleID: bundle, effect: true)
    }

    // MARK: - Tracker self-control

    /// Pause/recalibrate ride the tracker's `POST /control`; the feature
    /// switch is our own Config (its publisher owns the tracker spawn and
    /// stop). No verify pass — the tracker owns the state and the next
    /// status read reports what actually landed.
    private static func dispatchTrackerVerb(_ verb: FastAction.TrackerVerb) async throws {
        switch verb {
        case .pauseToggle:
            try await TrackerControl.post(action: "pause_toggle")
        case .recalibrate:
            try await TrackerControl.post(action: "recalibrate")
        case .enable:
            await TrackerControl.setTrackingEnabled(true)
        case .disable:
            await TrackerControl.setTrackingEnabled(false)
        }
    }

    /// The tracker's process state — read live from the host in
    /// production; tests pose boot/respawn windows through the seam so a
    /// dead socket never has to fake them (same posture as
    /// `TrackerControl.transport` and `displayFrames`).
    static var trackerState: () async -> TrackerHost.State = {
        await TrackerHost.shared.state
    }

    /// Whether the user turned eye tracking on. Off, gaze referents answer
    /// with what to say instead, and "here"/"this" mean the insertion
    /// point and the front window. Reads the stored switch so any thread
    /// can ask; tests replace it.
    static var gazeEnabled: () -> Bool = {
        UserDefaults.standard.bool(forKey: "gazeTracking")
    }

    /// "here"/"this" aim at the user's eyes only while eye tracking is on;
    /// otherwise they mean the insertion point and the front window.
    static func pointsByGaze(_ action: FastAction) -> Bool {
        action.deictic && gazeEnabled()
    }

    /// The reply when a gaze referent arrives with eye tracking off — the
    /// next thing to say, never a push back to eye tracking.
    static func eyesOffReply(_ verb: FastAction.GazeVerb) -> String {
        switch verb {
        case .describe:
            return "Eye tracking's off, so I can't tell what you're looking at. Say “show names” and I'll label what's on screen."
        case .click, .rightClick, .doubleClick:
            return "Eye tracking's off, so I can't tell what you're looking at. Just tell me the button, like “click Save”."
        }
    }

    /// The process-state word, when it beats any HTTP-derived remedy —
    /// nil when the live `/snapshot` read should arbitrate instead.
    /// While the host is booting or respawning, "turn eye tracking on"
    /// is a no-op (`ensureRunning` early-returns), so the only honest
    /// remedy is to wait or restart — a dead socket can't say that.
    /// `.stopped` and `.running` don't short-circuit: process state
    /// doesn't arbitrate a live answer, and a tracker still serving
    /// `/snapshot` is running in the only sense the next command cares
    /// about — its own status names the fix. (`.stopped` + nothing
    /// serving lands on the same "isn't running" line as before.)
    private static func trackerStateRefusal() async -> String? {
        switch await Self.trackerState() {
        case .starting:
            return "The eye tracker is still starting — give it a few seconds."
        case .failed(let message):
            return "The eye tracker stopped (\(Self.shortReason(message))) — say 'enable eye tracking' or open the Eyes menu to restart it."
        case .stopped, .running:
            return nil
        }
    }

    /// A `.failed` reason short enough to sit inside a spoken sentence —
    /// drops the "The eye tracker" subject (the sentence already has it)
    /// and the trailing period.
    private static func shortReason(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespaces)
        for prefix in ["the eye tracker", "eye tracker", "the tracker"] {
            if text.lowercased().hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if text.hasSuffix(".") { text.removeLast() }
        if let first = text.first {
            text = first.lowercased() + text.dropFirst()
        }
        if text.count > 80 { text = String(text.prefix(80)) + "…" }
        return text.isEmpty ? "it reported a failure" : text
    }

    /// The spoken fix for the state the tracker is actually in — process
    /// state first (boot/respawn has no remedy verb), then the served
    /// status (pause/calibration/face name their verb), then the bare
    /// "didn't answer" only when nothing can explain the failure.
    private static func gazeRefusal(_ error: GazeError) async -> String {
        if let state = await Self.trackerStateRefusal() { return state }
        guard let status = try? await TrackerControl().status() else {
            return "The eye tracker isn't running — say 'turn eye tracking on' or open the Eyes menu."
        }
        switch status.label {
        case "Paused":
            return "Eye tracking is paused — say 'resume tracking'."
        case "Needs calibration":
            return "The eye tracker needs calibration — say 'recalibrate'."
        case "No face":
            return "The tracker can't see your eyes right now."
        case "No gaze":
            return "The tracker sees you but the gaze feed stopped updating — say 'recalibrate' or check the Eyes menu."
        default:
            return error.userFacing
        }
    }

    /// The refusal for a tracker-verb dispatch that threw — same
    /// remedy-naming posture as a gaze failure: process state first,
    /// then the served status names the unsticking command, then the
    /// generic "isn't running" when nothing answered.
    private static func trackerVerbRefusal() async -> String {
        if let state = await Self.trackerStateRefusal() { return state }
        guard let status = try? await TrackerControl().status() else {
            return "The eye tracker isn't running — say 'turn eye tracking on' or open the Eyes menu."
        }
        switch status.label {
        case "Paused":
            return "The tracker is paused and didn't take the command — say 'resume tracking'."
        case "Needs calibration":
            return "The tracker needs calibration and didn't take the command — say 'recalibrate'."
        case "No face":
            return "The tracker can't see your eyes right now — the command didn't land."
        case "No gaze":
            return "The gaze feed stopped updating and the command didn't land — check the Eyes menu."
        default:
            return "The eye tracker didn't take the command — it may not be running."
        }
    }

    // MARK: - Gaze referents

    static let scrollUnverifiedReason = "scroll_outcome_unverified"

    private func runVerifiedScroll(direction: String, pages: Int, task: DriveTask,
                                   window: WindowRef, name: String, bundle: String,
                                   session: String, history: inout [String],
                                   lineAmount: Int? = nil,
                                   scrollAnchor: NativeWindowObservation.ScrollViewport? = nil) async throws -> DriveResult {
        let scrollContinuation = scrollAnchor ?? self.scrollContinuation
        guard pages > 0, ["up", "down", "left", "right"].contains(direction),
              lineAmount.map({ pages == 1 && [1, 3].contains($0) }) != false else {
            return settle(.blocked("The scroll direction or amount is unclear."), task, history,
                          pid: window.pid, windowID: window.windowID, bundleID: bundle)
        }
        var point: CGPoint?
        let targetName = name.isEmpty ? "the captured window" : "\(name)'s window"
        let sample: GazeSample?
        if scrollContinuation == nil {
            do { sample = try await gazeSample() }
            catch {
                sample = nil
                if gaze != nil { history.append("Eye tracking is unavailable for this scroll. Using \(targetName).") }
            }
        } else { sample = nil }
        if let scrollContinuation {
            guard scrollContinuation.window == window, scrollContinuation.supports(direction) else {
                return settle(.blocked("The previous scroll belongs to another window or direction."), task, history,
                    pid: window.pid, windowID: window.windowID, bundleID: bundle)
            }
            point = scrollContinuation.point
        } else if let sample {
            let proposed = CGPoint(x: sample.x, y: sample.y)
            guard let target = try await windowAtPoint(proposed, session: session),
                  target.pid == window.pid, target.windowID == window.windowID else {
                return settle(.blocked("You're looking outside the captured window. Choose that window before scrolling."),
                    task, history, pid: window.pid, windowID: window.windowID, bundleID: bundle,
                    blockedReason: "scroll target changed")
            }
            point = proposed
        }
        var verifiedCount = 0
        var previousViewport = scrollContinuation
        var reachedEdge = false
        let small = ["a little", "a bit"].contains { task.goal.lowercased().contains($0) }
        let lines = lineAmount ?? (small ? 1 : 3)
        func unverified(_ reason: String, _ records: [String]) -> DriveResult {
            settle(.blocked(reason), task, records + [reason], pid: window.pid, windowID: window.windowID,
                   bundleID: bundle, confirmedAny: verifiedCount > 0,
                   blockedReason: Self.scrollUnverifiedReason)
        }
        for step in 0..<pages {
            try Task.checkCancellation()
            guard var before = await nativeScrollRead(window, point, direction, previousViewport) else {
                return unverified("I couldn't identify the viewport to scroll. No further input was sent.", history)
            }
            if let previousViewport {
                guard before.sameTarget(as: previousViewport),
                      before.position == previousViewport.position || (freshScrollContinuation && verifiedCount == 0) else {
                    return unverified("The scroll target changed before the remaining input could be sent.", history)
                }
            }
            if before.atEdge(direction: direction) {
                let reason = "The viewport is already at the requested edge."
                if verifiedCount == 0 {
                    return settle(.alreadySatisfied(reason: reason), task, history + [reason],
                                  pid: window.pid, windowID: window.windowID, bundleID: bundle)
                }
                reachedEdge = true
                break
            }
            var dispatchedAt = ProcessInfo.processInfo.systemUptime
            let nativeOutcome: NativeWindowObservation.ScrollDispatch
            do {
                nativeOutcome = try await focusLeased {
                    guard let fresh = await self.nativeScrollRead(window, point, direction, before),
                          fresh.sameTarget(as: before), fresh.position == before.position else {
                        throw Abort.refused("The scroll target changed before input was sent.")
                    }
                    before = fresh
                    if let isCurrent = self.scrollContinuationIsCurrent, !(await isCurrent()) {
                        throw Abort.refused("The scrolling target changed before dispatch.")
                    }
                    try Task.checkCancellation()
                    await self.nativeEvent(.nativeScrollBegin)
                    dispatchedAt = ProcessInfo.processInfo.systemUptime
                    let outcome = try await self.nativeScrollControl(fresh, direction, lines)
                    await self.nativeEvent(.nativeScrollEnd)
                    return outcome
                }
            } catch is CancellationError {
                return settle(.cancelled, task, history + ["Scroll cancelled; any sent input was not repeated."],
                    pid: window.pid, windowID: window.windowID, bundleID: bundle,
                    confirmedAny: verifiedCount > 0)
            } catch let Abort.refused(reason) {
                return unverified(reason, history)
            } catch {
                await nativeEvent(.nativeScrollUncertain)
                return unverified("The scroll outcome is uncertain. I won't repeat a possibly performed action.", history)
            }
            if nativeOutcome == .uncertain {
                await nativeEvent(.nativeScrollUncertain)
                return unverified("The native scroll outcome is uncertain. No additional input was sent.", history)
            }
            if nativeOutcome == .unavailable {
                await nativeEvent(.nativeScrollUnavailable)
                var arguments: [String: JSONValue] = [
                    "pid": .number(Double(window.pid)), "window_id": .number(Double(window.windowID)),
                    "direction": .string(direction), "by": .string("line"), "amount": .number(Double(lines)),
                    "session": .string(session),
                ]
                var regionBound = false, usesToken = false
                if before.tokenCenterMatches,
                   let token = try? await scrollRegionToken(before, session: session) {
                    arguments["element_token"] = .string(token)
                    arguments["post_action_wait"] = .string("none")
                    regionBound = true
                    usesToken = true
                } else if let read = imageObservation,
                          let result = try? await read("get_window_state", [
                            "pid": .number(Double(window.pid)), "window_id": .number(Double(window.windowID)),
                            "session": .string(session), "include_screenshot": .bool(true),
                            "include_accessibility_tree": .bool(true), "max_image_dimension": .number(1568),
                            "max_elements": .number(600), "max_depth": .number(20), "tree_format": .string("both"),
                          ]),
                          let frame = try? VisualFrame.decode(result, window: window, session: session),
                          frame.bounds.contains(before.point), frame.bounds == before.windowFrame {
                    arguments["x"] = .number((before.point.x - frame.bounds.minX) / frame.bounds.width * frame.driverSize.width)
                    arguments["y"] = .number((before.point.y - frame.bounds.minY) / frame.bounds.height * frame.driverSize.height)
                    regionBound = true
                }
                guard regionBound else {
                    return unverified("I couldn't bind a supported scroll action to this viewport. No further input was sent.", history)
                }
                guard let fresh = await nativeScrollRead(window, point, direction, before),
                      fresh.sameTarget(as: before), fresh.position == before.position,
                      !usesToken || fresh.tokenCenterMatches else {
                    return unverified("The scroll target changed before input was sent.", history)
                }
                before = fresh
                if let isCurrent = scrollContinuationIsCurrent, !(await isCurrent()) {
                    return unverified("The scrolling target changed before dispatch.", history)
                }
                try Task.checkCancellation()
                dispatchedAt = ProcessInfo.processInfo.systemUptime
                do {
                    let result = try await callOnce("scroll", arguments)
                    if result["isError"]?.bool == true {
                        return unverified("The driver reported a scroll error. No additional input was sent.", history)
                    }
                } catch is CancellationError {
                    return settle(.cancelled, task, history + ["Scroll cancelled; any sent input was not repeated."],
                        pid: window.pid, windowID: window.windowID, bundleID: bundle,
                        confirmedAny: verifiedCount > 0)
                } catch {
                    return unverified("The scroll outcome is uncertain. No additional input was sent.", history)
                }
            }
            history.append("Scroll request sent to \(targetName).")
            try Task.checkCancellation()
            var last: NativeWindowObservation.ScrollViewport?
            var verified = false
            let deadline = dispatchedAt + 0.75
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                guard let current = await nativeScrollRead(window, point, direction, before),
                      current.sameTarget(as: before) else {
                    return unverified("The viewport changed before I could verify the scroll.", history)
                }
                if let last, last.position == current.position,
                   last.readGeneration != current.readGeneration,
                   current.capturedAt - last.capturedAt >= 0.03 {
                    if current.moved(from: before, direction: direction, dispatchedAt: dispatchedAt) {
                        verified = true
                        previousViewport = current
                        break
                    }
                    if current.position != before.position {
                        return unverified("The viewport didn't move in the requested direction.", history)
                    }
                }
                last = current
                try await Task.sleep(for: .milliseconds(40))
            }
            guard verified else {
                return unverified("I couldn't verify viewport movement. The view may be at its edge.", history)
            }
            verifiedCount += 1
            await nativeEvent(.nativeScrollVerified)
            if let previousViewport {
                await onVerifiedScroll?(.init(viewport: previousViewport, application: bundle,
                                             direction: direction, lines: lines))
            }
            history.append("Verified \(direction) viewport movement \(step + 1) of \(pages).")
        }
        let message = "Scrolled \(direction) in \(targetName)." + (reachedEdge ? " The viewport reached its edge." : "")
        return done(message, task, history, pid: window.pid,
                    windowID: window.windowID, bundleID: bundle, effect: verifiedCount > 0)
    }

    private func scrollRegionToken(_ viewport: NativeWindowObservation.ScrollViewport,
                                   session: String) async throws -> String? {
        let response = try await observe("get_window_state", [
            "pid": .number(Double(viewport.window.pid)), "window_id": .number(Double(viewport.window.windowID)),
            "session": .string(session), "include_screenshot": .bool(false),
            "max_elements": .number(600), "max_depth": .number(20), "tree_format": .string("both"),
        ])
        let body = response["structuredContent"] ?? response
        guard body["pid"]?.integer == viewport.window.pid,
              body["window_id"]?.integer == viewport.window.windowID else { return nil }
        let snapshot = try DriveCandidates.axSnapshot(from: response)
        let candidates = snapshot.elements.filter {
            $0.role == "AXScrollArea" && $0.frame == viewport.frame && $0.token?.isEmpty == false
        }
        return candidates.count == 1 ? candidates.first?.token : nil
    }

    /// The freshest tracker sample, or a typed refusal. A nil seam means the
    /// caller never wired a client (agent contexts) — indistinguishable to
    /// the user from a dead tracker, and equally honest. Freshness is
    /// re-checked here too: a click on where the user *was* is worse than
    /// no click, and seams other than `GazeClient` may not gate.
    private func gazeSample() async throws -> GazeSample {
        guard let gaze else { throw GazeError.unreachable }
        let sample = try await gaze()
        guard sample.isFresh else { throw GazeError.stale }
        return sample
    }

    /// The window under a global screen point: topmost on-screen row whose
    /// `bounds` contain it. `list_windows` reports WindowServer bounds —
    /// global top-left *points*, the same space the tracker emits — so no
    /// conversion is needed to hit-test.
    struct GazeWindowTarget: Sendable {
        var pid: Int
        var windowID: Int
        var app: String
        var title: String
        /// The window's list_windows bounds in top-left points — what the
        /// AX traffic-light press frame-matches against. Zero when the
        /// target came from a fallback that never had a row.
        var frame: CGRect = .zero
    }

    /// The global window inventory — every app's rows, used by the
    /// hit-test, display-scope and locate lanes that cross app boundaries.
    func allWindowRows(session: String) async throws -> [JSONValue] {
        let list = try await observe("list_windows", ["session": .string(session)])
        return list["structuredContent"]?["windows"]?.array
            ?? list["windows"]?.array ?? []
    }

    /// The topmost on-screen window row containing a top-left point, in
    /// the wire contract's z order: `z_index` is higher = closer to the
    /// front (CGWindowList front-to-back reversed into an index — the
    /// driver documents "take the maximum"), and a null means the order
    /// is unavailable, so a z-less row trails every ordered one rather
    /// than claiming the front. `excludingPID` drops a process's own
    /// rows: our overlay panels/halo/cheat sheet are non-layer-0 and the
    /// driver already hides them, but a gaze at Jarvis chrome must
    /// never resolve this app as the target even if a row leaks through.
    static func topmostWindowRow(at point: CGPoint, in rows: [JSONValue],
                                 excludingPID: Int? = nil) -> JSONValue? {
        var best: (row: JSONValue, z: Int)?
        for row in rows {
            guard row["is_on_screen"] != .bool(false),
                  let pid = row["pid"]?.integer, pid != excludingPID,
                  let bounds = row["bounds"],
                  let x = Self.num(bounds["x"]), let y = Self.num(bounds["y"]),
                  let w = Self.num(bounds["width"]), let h = Self.num(bounds["height"]),
                  CGRect(x: x, y: y, width: w, height: h).contains(point) else { continue }
            let z = row["z_index"]?.integer ?? Int.min
            if best == nil || z > best!.z { best = (row, z) }
        }
        return best?.row
    }

    /// The app's own pid — the exclusion every gaze hit-test applies so
    /// our windows (settings, chips if they ever surface as layer-0)
    /// can't win a "this" referent.
    static var ownPID: Int { Int(ProcessInfo.processInfo.processIdentifier) }

    func windowAtPoint(_ point: CGPoint, session: String) async throws -> GazeWindowTarget? {
        guard let row = Self.topmostWindowRow(at: point,
                                              in: try await allWindowRows(session: session),
                                              excludingPID: Self.ownPID),
              let pid = row["pid"]?.integer,
              let wid = row["window_id"]?.integer else { return nil }
        var frame = CGRect.zero
        if let bounds = row["bounds"], let x = Self.num(bounds["x"]),
           let y = Self.num(bounds["y"]), let w = Self.num(bounds["width"]),
           let h = Self.num(bounds["height"]) {
            frame = CGRect(x: x, y: y, width: w, height: h)
        }
        return GazeWindowTarget(pid: pid, windowID: wid,
                                app: row["app_name"]?.string ?? "the app",
                                title: row["title"]?.string ?? "", frame: frame)
    }

    /// The window-verb a deictic phrase aims at the gazed window — the
    /// action's effect is what names it (the same ⌘M row also serves a
    /// bare "minimize", so the row alone can't distinguish).
    enum DeicticWindowControl { case minimize, close, hideApp }

    static func deicticWindowControl(for action: FastAction) -> DeicticWindowControl? {
        switch action.effect {
        case .windowOffScreen: return .minimize
        case .windowDelta(-1): return .close
        case .appOffScreen: return .hideApp
        default: return nil
        }
    }

    /// "minimize this" / "close it" / "hide this": the window under the
    /// gaze point is the target. minimize/close AXPress the traffic-light
    /// on THAT window — background-safe, no focus borrow, the same button
    /// the user would have clicked; hide routes the whole-app path on the
    /// window's owner. Every leg verifies from live window state.
    private func runDeicticWindowControl(_ control: DeicticWindowControl, action: FastAction,
                                         task: DriveTask, session: String,
                                         history: inout [String],
                                         confirmed: inout Bool) async throws -> DriveResult {
        let sample: GazeSample
        do {
            sample = try await gazeSample()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return settle(.blocked("The eye tracker isn't answering — tell me which window instead."),
                          task, history, blockedReason: "deictic gaze unavailable")
        }
        guard let target = try await windowAtPoint(CGPoint(x: sample.x, y: sample.y),
                                                 session: session) else {
            return settle(.blocked("There's no window where you're looking — tell me which window you mean."),
                          task, history, blockedReason: "no window at gaze point")
        }
        let noun = target.title.isEmpty ? "\(target.app)'s window" : "“\(target.title)”"
        // The gazed window's own words are the deny corpus — "close it"
        // on a "Confirm purchase" dialog refuses on its title.
        try await gateExplicit(control == .hideApp ? "hide app" : "window_control",
                               corpus: "\(action.description) \(target.app) \(target.title)",
                               denied: task.deny, confirmed: &confirmed)
        switch control {
        case .hideApp:
            // The verified whole-app path — already handles already-
            // hidden, no-windows, and the on-screen readback.
            feed("Hiding \(target.app)")
            return try await runAppControl(.hide, pid: target.pid, name: target.app,
                                           bundle: "", task: task, session: session,
                                           history: &history, alreadyConfirmed: confirmed)
        case .minimize, .close:
            let kind: WindowControls.Kind = control == .minimize ? .minimize : .close
            feed(control == .minimize ? "Minimizing \(noun)" : "Closing \(noun)")
            guard WindowControls.press(kind, pid: pid_t(target.pid), matching: target.frame) else {
                return settle(.blocked("I see \(noun), but its \(kind == .minimize ? "minimize" : "close") button isn't reachable."),
                              task, history, pid: target.pid, windowID: target.windowID,
                              blockedReason: "window control absent")
            }
            let gone = try await pollDriver({ () async throws -> Bool in
                guard let row = try await self.windowRow(pid: target.pid, windowID: target.windowID,
                                                        session: session) else { return true }
                return row["is_on_screen"] == .bool(false)
            }, until: { $0 })
            guard gone == true else {
                throw DriverConnectionError.refused("\(noun) was asked to \(control == .minimize ? "minimize" : "close"), but it's still on screen.")
            }
            return done(control == .minimize ? "Minimized \(noun)." : "Closed \(noun).",
                        task, history, pid: target.pid, windowID: target.windowID,
                        bundleID: "", effect: true)
        }
    }

    /// The attached displays as `(topLeftFrame, backingScale)` — behind a
    /// seam because NSScreen can't be stubbed in a test host; production
    /// maps `NSScreen.screens` through `ScreenGeometry`, tests serve fake
    /// geometry. The frame and scale are the only things the display-scope
    /// and snap lanes ever read.
    static var displayFrames: () -> [(frame: CGRect, scale: Double)] = {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        return screens.map {
            (ScreenGeometry.topLeftFrame(of: $0, primaryHeight: primaryHeight),
             Double($0.backingScaleFactor))
        }
    }

    /// The display-scope resolution: an app identity the display under the
    /// gaze point produced, or the refusal text to settle with.
    private enum DisplayScope {
        case app(name: String, bundle: String, pid: Int?)
        case refused(String)
    }

    /// "on this monitor" — the app owning the topmost on-screen window on
    /// the display under the gaze point. Fallbacks in order: no tracker
    /// seam → the pointer's display (AppKit bottom-left flipped to
    /// top-left); no display or window claim → the frontmost app. A
    /// tracker *fault* refuses — clicking where the user *was* is worse
    /// than naming the failure.
    private func displayScopedApp(session: String) async throws -> DisplayScope {
        let point: CGPoint
        if gaze != nil {
            do {
                let sample = try await gazeSample()
                point = CGPoint(x: sample.x, y: sample.y)
            } catch let error as GazeError {
                return .refused(await Self.gazeRefusal(error))
            }
        } else {
            point = ScreenGeometry.appKitToTopLeft(NSEvent.mouseLocation)
        }
        if let display = Self.displayFrames().first(where: { $0.frame.contains(point) })?.frame {
            let top = try await allWindowRows(session: session)
                .filter { row in
                    guard row["is_on_screen"] != .bool(false),
                          row["pid"]?.integer != Self.ownPID,
                          let bounds = row["bounds"],
                          let x = Self.num(bounds["x"]), let y = Self.num(bounds["y"]),
                          let w = Self.num(bounds["width"]), let h = Self.num(bounds["height"])
                    else { return false }
                    return CGRect(x: x, y: y, width: w, height: h).intersects(display)
                }
                // z_index is higher = closer to front; null can't be
                // inferred and trails any ordered row.
                .max { ($0["z_index"]?.integer ?? Int.min) < ($1["z_index"]?.integer ?? Int.min) }
            if let top, let pid = top["pid"]?.integer,
               let bundle = try await bundleID(forPID: pid, session: session) {
                return .app(name: top["app_name"]?.string ?? bundle,
                            bundle: bundle, pid: pid)
            }
        }
        // No window claim on the gaze display — "this screen" most often
        // means the one in use.
        if let bundle = frontmostBundleID() {
            let name = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundle })?.localizedName ?? bundle
            return .app(name: name, bundle: bundle,
                        pid: Self.runningPID(bundle: bundle, in: []))
        }
        return .refused("I couldn't tell which display you meant — nothing is under your gaze on any screen.")
    }

    /// pid → bundle: `list_windows` reports pids, not bundles, so the app
    /// inventory answers first and AppKit's roster is the local fallback.
    private func bundleID(forPID pid: Int, session: String) async throws -> String? {
        if let apps = try? await observe("list_apps", ["session": .string(session)]),
           let bundle = (apps["structuredContent"]?["apps"]?.array
                ?? apps["apps"]?.array ?? [])
                .first(where: { $0["pid"]?.integer == pid })?["bundle_id"]?.string,
           !bundle.isEmpty {
            return bundle
        }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
    }

    /// Convert a gaze point (global top-left points) into the driver's
    /// desktop pixel space: multiply by the backing scale of the screen
    /// containing the point. NSScreen frames are Cocoa bottom-left — the
    /// flip uses the primary screen's height.
    static func desktopPixels(_ point: CGPoint) -> CGPoint {
        let screens = NSScreen.screens
        let primaryHeight = screens.first?.frame.height ?? 0
        for screen in screens {
            let frame = screen.frame
            let topLeft = CGRect(x: frame.minX, y: primaryHeight - frame.maxY,
                                 width: frame.width, height: frame.height)
            if topLeft.contains(point) {
                let scale = screen.backingScaleFactor
                return CGPoint(x: point.x * scale, y: point.y * scale)
            }
        }
        // Off every known screen (transitioning display, menu bar) — the
        // main display's scale is the least-wrong guess.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return CGPoint(x: point.x * scale, y: point.y * scale)
    }

    /// Dispatch a gaze-referent verb at the freshest tracker point.
    /// Click lands through the driver's desktop pixel path; right and
    /// double clicks post through the host HID tap (the driver's pixel
    /// forms of those want a pid + window-local coordinates).
    ///
    /// Consent is the gaze itself — the user looked AT the thing — but
    /// the committed referent's own words (label + href + window title)
    /// still ride the deny scan, and a raw-point fallback scans the
    /// window under the point when no candidate exists.
    private func runGazeVerb(_ verb: FastAction.GazeVerb, task: DriveTask,
                             session: String, history: inout [String],
                             confirmed: inout Bool) async throws -> DriveResult {
        let sample: GazeSample
        do {
            sample = try await gazeSample()
        } catch let error as GazeError {
            return settle(.blocked(await Self.gazeRefusal(error)), task, history,
                          blockedReason: "gaze unavailable")
        }
        let point = CGPoint(x: sample.x, y: sample.y)
        /// The referent's own words — what the effect lands on.
        func corpus(_ c: IntentCandidate) -> String {
            [c.label, c.url ?? "", c.windowTitle ?? "", c.appName ?? ""]
                .joined(separator: " ")
        }
        switch verb {
        case .click:
            // The scorer's committed referent decides where the click
            // lands — an element-token dispatch is driver-verified; the
            // pixel form clicks the candidate's motor point, not raw
            // gaze. A cold scorer falls back to the point unchanged.
            var target = point
            var say = "Clicked where you're looking."
            var outcome: DriveResult?
            if let gazeCommit, let (candidate, _) = await gazeCommit() {
                // Deny-scan BEFORE picking the actuation form — a "Buy
                // now" referent refuses whichever way the click lands.
                try await gateExplicit("click", corpus: corpus(candidate),
                                       denied: task.deny, confirmed: &confirmed)
                let name = candidate.label.isEmpty
                    ? Self.speakableRole(candidate.role) : candidate.label
                switch VoiceTaskCoordinator.actuation(for: candidate, gaze: point) {
                case .elementClick(let pid, let wid, let token):
                    do {
                        _ = try await call("click", [
                            "pid": .number(Double(pid)),
                            "window_id": .number(Double(wid)),
                            "element_token": .string(token),
                            "delivery_mode": .string("background"),
                            "session": .string(session)])
                        outcome = done("Clicked \(name).", task, history,
                                       pid: Int(pid), windowID: wid, effect: true)
                    } catch let error as DriverConnectionError {
                        if case .toolRefused(_, _, let detail) = error {
                            return settle(.blocked(detail), task, history)
                        }
                        throw error
                    }
                case .trafficLight(let kind, let pid, let frame):
                    if WindowControls.press(kind, pid: pid, matching: frame) {
                        outcome = done("Clicked \(name).", task, history,
                                       pid: Int(pid), windowID: candidate.windowID,
                                       effect: true)
                    } else {
                        // Press refused — the pixel path below lands on
                        // the button's rect, same target.
                        target = CGPoint(x: candidate.motorRect.midX,
                                         y: candidate.motorRect.midY)
                        say = "Clicked \(name)."
                    }
                case .pixelClick(let p):
                    target = p
                    say = "Clicked \(name)."
                case .none:
                    break
                }
            } else {
                // Cold scorer: the window under the point is the only
                // deny-scan context a raw pixel click has.
                let fallback = (try? await windowAtPoint(target, session: session))
                    .map { "\($0.title) \($0.app)" } ?? ""
                try await gateExplicit("click", corpus: fallback,
                                       denied: task.deny, confirmed: &confirmed)
            }
            if let outcome { return outcome }
            let px = Self.desktopPixels(target)
            do {
                _ = try await call("click", ["scope": .string("desktop"),
                                             "x": .number(px.x), "y": .number(px.y),
                                             "session": .string(session)])
            } catch let error as DriverConnectionError {
                if case .toolRefused(_, _, let detail) = error {
                    return settle(.blocked(detail), task, history)
                }
                throw error
            }
            return done(say, task, history, effect: true)
        case .rightClick, .doubleClick:
            // Same single-referent contract as .click: the committed
            // candidate's motor point decides where the post lands —
            // raw gaze is the cold-scorer fallback, not the primary path.
            var postPoint = point
            var corpusText = ""
            if let gazeCommit, let (candidate, _) = await gazeCommit() {
                if !candidate.motorRect.isEmpty {
                    postPoint = candidate.motorRect.contains(point) ? point
                        : CGPoint(x: candidate.motorRect.midX, y: candidate.motorRect.midY)
                }
                corpusText = corpus(candidate)
            } else {
                corpusText = (try? await windowAtPoint(point, session: session))
                    .map { "\($0.title) \($0.app)" } ?? ""
            }
            try await gateExplicit(verb == .rightClick ? "gaze right click" : "gaze double click",
                                   corpus: corpusText, denied: task.deny,
                                   confirmed: &confirmed)
            guard GazePointer.poster(verb == .rightClick ? .right : .double, postPoint) else {
                let reason = GazePointer.refusal == .postAccessDenied
                    ? "macOS denied the synthetic click — check Accessibility and Input Monitoring permissions."
                    : "The click event couldn't be built."
                return settle(.blocked(reason), task, history,
                              blockedReason: "pointer post refused")
            }
            return done(verb == .rightClick
                        ? "Right-clicked where you're looking."
                        : "Double-clicked where you're looking.",
                        task, history, effect: true)
        case .describe:
            // The committed referent answers directly — its label, role,
            // app and DOM href are already resolved; no second window
            // observation. Cold scorer → the raw-point read below.
            if let gazeCommit, let (candidate, _) = await gazeCommit() {
                let role = Self.speakableRole(candidate.role)
                let app = candidate.appName.map { " in \($0)" } ?? ""
                var say = candidate.label.isEmpty
                    ? "That's a \(role)\(app)."
                    : "That's a \(role), “\(candidate.label)”\(app)."
                if let url = candidate.url, !url.isEmpty {
                    say += " It links to \(url)."
                }
                return done(say, task, history,
                            pid: candidate.pid.map(Int.init),
                            windowID: candidate.windowID, effect: true)
            }
            return try await describeGaze(at: point, task: task, session: session,
                                          history: &history)
        }
    }

    /// The screen reader the gaze "what is this" goes through. Tests swap
    /// in a fixed digest; the live read walks the window's AX tree.
    nonisolated(unsafe) static var screenReader: @Sendable (WindowRef) async -> ScreenDigest? = {
        await ScreenContext.read($0)
    }

    /// "What is this" — the window under the gaze point, read through the
    /// screen reader so secret fields and password managers stay unread,
    /// then the smallest element containing the point. Native AX frames
    /// already use the gaze point's global screen space.
    private func describeGaze(at point: CGPoint, task: DriveTask, session: String,
                              history: inout [String]) async throws -> DriveResult {
        guard let target = try await windowAtPoint(point, session: session) else {
            return done("You're looking at the desktop — no window is under that point.",
                        task, history, effect: true)
        }
        let digest = await Self.screenReader(WindowRef(pid: target.pid, windowID: target.windowID))
            ?? ScreenDigest(app: target.app, windowTitle: target.title)
        return done(ScreenQuestion.describe(at: point, in: digest), task, history,
                    pid: target.pid, windowID: target.windowID, effect: true)
    }

    /// An AX role as spoken words — "AXTextField" and "textField" both
    /// say "text field". The strip is uppercase-run/camelCase splits only;
    /// a role that's already words ("menu bar item") passes through.
    private static func speakableRole(_ role: String) -> String {
        var r = role.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("AX") { r = String(r.dropFirst(2)) }
        guard !r.isEmpty else { return "element" }
        var words = ""
        for (i, ch) in r.enumerated() {
            if ch.isUppercase, i > 0 {
                let prev = r[r.index(r.startIndex, offsetBy: i - 1)]
                if !prev.isUppercase || (i + 1 < r.count
                    && r[r.index(r.startIndex, offsetBy: i + 1)].isLowercase) {
                    words.append(" ")
                }
            }
            words.append(ch)
        }
        return words.lowercased()
    }

    // MARK: - Overlay and locate lanes

    /// Overlay verbs — names, a highlight, or numbers over an ambiguous
    /// name's matches — resolve app-side through the injected
    /// `overlayDispatch` seam (TargetOverlay on the coordinator), never
    /// through the driver. The window is the one under the user's eyes
    /// when eye tracking is on and answering, otherwise the frontmost
    /// window. A nil seam means nothing can draw; the refusal says so
    /// instead of pretending labels went up.
    private func runOverlayVerb(_ verb: FastAction.OverlayVerb, task: DriveTask,
                                session: String, history: inout [String]) async throws -> DriveResult {
        guard let overlayDispatch else {
            return settle(.blocked("I can't put names on the screen right now."),
                          task, history, blockedReason: "overlay seam absent")
        }
        let gaze = Self.gazeEnabled()
            ? (try? await gazeSample()).map { CGPoint(x: $0.x, y: $0.y) } : nil
        switch verb {
        case .showNames, .showNumbers, .highlight, .pressGlow:
            // Show verbs need real targets — an unreadable window or an
            // empty tree is an honest "nothing to name", not a silent
            // overlay.
            let targets = try await collectOverlayTargets(gaze: gaze, session: session)
            guard !targets.isEmpty else {
                return settle(.blocked("I can't find anything with a name in this window."),
                              task, history, blockedReason: "no overlay targets")
            }
            guard let result = await overlayDispatch(verb, targets, gaze) else {
                return settle(.blocked("I can't put names on the screen right now."),
                              task, history, blockedReason: "overlay declined")
            }
            return result
        case .hideNumbers, .clickIndex:
            // Pick/hide verbs ride the overlay's own pending state — the
            // targets here are best-effort context, so a failed snapshot
            // doesn't veto the pick.
            let targets = (try? await collectOverlayTargets(gaze: gaze, session: session)) ?? []
            guard let result = await overlayDispatch(verb, targets, gaze) else {
                return settle(.blocked("I can't put names on the screen right now."),
                              task, history, blockedReason: "overlay declined")
            }
            return result
        }
    }

    /// The one window an overlay verb labels: the window under the user's
    /// eyes when eye tracking is on and answering, otherwise the
    /// frontmost window — the one a voice-only user is talking about.
    private func collectOverlayTargets(gaze: CGPoint?,
                                     session: String) async throws -> [(frame: CGRect, label: String)] {
        var target: GazeWindowTarget?
        if let gaze { target = try await windowAtPoint(gaze, session: session) }
        if target == nil, let bundle = frontmostBundleID(),
           let pid = Self.runningPID(bundle: bundle, in: []),
           let wid = Self.bestWindowID(
                in: try await listedWindowRows(pid: pid, session: session)) {
            target = GazeWindowTarget(pid: pid, windowID: wid, app: bundle, title: "")
        }
        guard let target else { return [] }
        return try await overlayTargets(pid: target.pid, windowID: target.windowID, session: session)
    }

    /// "click Send" / "show me Send" — the spoken name against the window's
    /// labelled controls. One match clicks (or is highlighted); several get
    /// numbers and a question; none returns nil so the drive loop can try
    /// a description the labels don't carry.
    private func runNamedTarget(_ spoken: String, clicks: Bool, anywhere: Bool = true, pid: Int, windowID: Int,
                                windowTitle: String, task: DriveTask, session: String,
                                history: inout [String], confirmed: inout Bool) async throws -> DriveResult? {
        let snap = try await observe("get_window_state",
            ["pid": .number(Double(pid)), "window_id": .number(Double(windowID)),
             "include_screenshot": .bool(false), "max_elements": .number(220),
             "session": .string(session)])
        let elements = Self.elements(from: snap["structuredContent"] ?? snap).compactMap { e -> (Element, CGRect)? in
            guard Self.overlayActionable(e), let frame = Self.nativeAXScreenRect(e) else { return nil }
            return (e, frame)
        }
        let candidates = elements.map { e, frame in
            NamedTargetMatch.Candidate(label: e.label.isEmpty ? (e.value ?? "") : e.label,
                                       frame: frame, pressable: !e.actions.isEmpty)
        }
        let hits = NamedTargetMatch.matches(spoken, in: candidates, anywhere: anywhere)
        guard !hits.isEmpty else {
            history.append("No control called \(spoken) in this window.")
            return nil
        }
        let targets = hits.map { (frame: candidates[$0].frame, label: candidates[$0].label) }
        let label = candidates[hits[0]].label
        if clicks, hits.count == 1, let hit = hits.first {
            let (element, frame) = elements[hit]
            try await gateExplicit("click", corpus: "\(label) \(windowTitle)",
                                   denied: task.deny, confirmed: &confirmed)
            if Consequence.of(control: label) != nil { await glowPress(frame, label: label) }
            var args: [String: JSONValue] = ["session": .string(session)]
            if let token = element.token, !token.isEmpty {
                args["pid"] = .number(Double(pid))
                args["window_id"] = .number(Double(windowID))
                args["element_token"] = .string(token)
                args["delivery_mode"] = .string("background")
            } else {
                let px = Self.desktopPixels(CGPoint(x: frame.midX, y: frame.midY))
                args["scope"] = .string("desktop")
                args["x"] = .number(px.x)
                args["y"] = .number(px.y)
            }
            do {
                _ = try await call("click", args)
            } catch let error as DriverConnectionError {
                if case .toolRefused(_, _, let detail) = error {
                    return settle(.blocked(detail), task, history, pid: pid, windowID: windowID)
                }
                throw error
            }
            return done("Clicked \(label).", task, history, pid: pid, windowID: windowID, effect: true)
        }
        let verb: FastAction.OverlayVerb = hits.count == 1 ? .highlight : .showNumbers
        guard let overlayDispatch,
              let shown = await overlayDispatch(verb, targets, nil),
              case .done = shown.status else {
            return settle(.blocked(hits.count == 1
                                   ? "I found \(label), but I can't point at it right now."
                                   : "I can see \(hits.count) things called \(label), but I can't number them right now."),
                          task, history, pid: pid, windowID: windowID, blockedReason: "overlay declined")
        }
        if hits.count == 1 {
            return done("That's \(label).", task, history, pid: pid, windowID: windowID)
        }
        return settle(.blocked(Self.whichOneReply(label: label, count: hits.count)),
                      task, history, pid: pid, windowID: windowID, blockedReason: "ambiguous name")
    }

    /// "I can see two things called Send. One or two?" — the question after
    /// numbers go up over an ambiguous name.
    static func whichOneReply(label: String, count: Int) -> String {
        let words = ["one", "two", "three", "four", "five"]
        guard count <= words.count else {
            return "I can see \(count) things called \(label). Say the number of the one you want."
        }
        let options = words.prefix(count).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let spoken = options.dropLast().joined(separator: ", ") + " or " + options.last!.lowercased()
        return "I can see \(words[count - 1]) things called \(label). \(spoken)?"
    }

    /// The window's actionable elements as top-left screen rects — element
    /// frames already share the overlay and gaze sample's global point space.
    private func overlayTargets(pid: Int, windowID: Int,
                                session: String) async throws -> [(frame: CGRect, label: String)] {
        let snap = try await observe("get_window_state",
            ["pid": .number(Double(pid)), "window_id": .number(Double(windowID)),
             "include_screenshot": .bool(false), "max_elements": .number(220),
             "session": .string(session)])
        let content = snap["structuredContent"] ?? snap
        return Self.elements(from: content).compactMap { e in
            guard Self.overlayActionable(e), let frame = Self.nativeAXScreenRect(e) else { return nil }
            return (frame, e.label.isEmpty ? (e.value ?? e.role) : e.label)
        }
    }

    /// The actionable-role vocabulary the overlay numbers — the same
    /// filter pattern the chooser's candidate builder applies, duplicated
    /// here so this lane doesn't grow a dependency on the chooser's
    /// private tables.
    private static func overlayActionable(_ e: Element) -> Bool {
        guard e.frame.w > 0, e.frame.h > 0 else { return false }
        let r = e.role.lowercased().replacingOccurrences(of: "ax", with: "")
        return !e.actions.isEmpty
            || ["textfield", "textarea", "text", "searchfield",
                "combo box", "combobox", "securetextfield"].contains(where: r.contains)
            || ["button", "link", "menuitem", "menu item", "tab",
                "checkbox", "radio", "row", "cell", "pop up",
                "popupbutton", "switch", "list"].contains(where: r.contains)
    }

    /// "where did X go" — hunt the global window inventory for an app name
    /// or title fragment, then either report it on screen or bring it back
    /// with a real activation. Several distinct matching apps is a choice
    /// the user owns; the lane names the candidates instead of guessing.
    private func runLocate(_ query: String, task: DriveTask, session: String,
                           history: inout [String]) async throws -> DriveResult {
        let rows = try await allWindowRows(session: session)
        let matches = rows.filter { row in
            let app = row["app_name"]?.string ?? ""
            let title = row["title"]?.string ?? ""
            return app.localizedCaseInsensitiveContains(query)
                || title.localizedCaseInsensitiveContains(query)
        }
        guard !matches.isEmpty else {
            return settle(.blocked("I can't find anything called \(query) — say 'what can I say' to see what I understand."),
                          task, history, blockedReason: "locate found nothing")
        }
        var names: [String] = []
        for row in matches {
            let app = row["app_name"]?.string ?? ""
            if !app.isEmpty, !names.contains(app) { names.append(app) }
        }
        guard names.count <= 1 else {
            return settle(.blocked("“\(query)” could be a few things — \(names.joined(separator: ", ")). Which one?"),
                          task, history, blockedReason: "locate ambiguous")
        }
        let appName = names.first ?? query
        guard matches.contains(where: { $0["is_on_screen"] == .bool(false) }) else {
            return done("\(appName) is already on screen.", task, history)
        }
        guard let pid = matches.compactMap({ $0["pid"]?.integer }).first else {
            return settle(.blocked("I found \(appName) but its window can't be reached."),
                          task, history, blockedReason: "locate no pid")
        }
        // The window is minimized or off-Space — a real activate fires the
        // app's un-minimize path; the driver won't do this on its own.
        try await focusLeased { self.activateApp(pid) }
        let back = try await pollDriver({ () async throws -> Bool in
            try await self.allWindowRows(session: session)
                .contains { $0["pid"]?.integer == pid && $0["is_on_screen"] != .bool(false) }
        }, until: { $0 })
        guard back == true else {
            return settle(.blocked("\(appName) was asked to come back, but no window returned to the screen."),
                          task, history, pid: pid, blockedReason: "restore unverified")
        }
        return done("\(appName) was minimized — brought it back.", task, history,
                    pid: pid, effect: true)
    }

    /// Bounded patience for a just-launched app's first window, then the
    /// host-side activate that fires the app's reopen handler — the one
    /// move the driver deliberately refuses to make on its own.
    /// Returns the winning rows or [] — never claims a window exists.
    func materialize(pid: Int, bundle: String, didLaunch: Bool,
                     session: String) async -> [JSONValue] {
        for _ in 0..<8 {
            if Task.isCancelled { return [] }
            let rows = (try? await listedWindowRows(pid: pid, session: session)) ?? []
            if rows.contains(where: {
                $0["is_on_screen"] != .bool(false) || !($0["title"]?.string ?? "").isEmpty
            }) { return rows }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Activation can reveal existing windows, but does not create a
        // closed main window. Explicit foreground opens issue a normal OS
        // reopen before this poll; other callers only observe existing UI.
        // A delayed window may outlive the first poll, so activate once
        // more mid-patience without replaying a driver mutation.
        _ = try? await focusLeased { self.activateApp(pid) }
        for i in 0..<20 {
            if Task.isCancelled { return [] }
            let rows = (try? await listedWindowRows(pid: pid, session: session)) ?? []
            if rows.contains(where: {
                $0["is_on_screen"] != .bool(false) || !($0["title"]?.string ?? "").isEmpty
            }) { return rows }
            if i == 8 { _ = try? await focusLeased { self.activateApp(pid) } }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return []
    }

    // MARK: - Whole-app verbs

    /// hide/unhide/minimize/quit — verified from live window/process state.
    /// hide/unhide move through NSRunningApplication (no focus steal),
    /// minimize uses the app's own Window menu so it also works on a
    /// background app, and quit is a graceful terminate gated by the same
    /// approval surface the drive loop uses.
    private func runAppControl(_ verb: FastAction.AppVerb, pid: Int, name: String,
                               bundle: String, task: DriveTask, session: String,
                               history: inout [String],
                               alreadyConfirmed: Bool = false) async throws -> DriveResult {
        if verb == .quit, !granted(), !alreadyConfirmed {
            // The standing grant covers computer use — asking anyway would
            // park the task on a card the user already opted out of. No
            // grant: one explicit confirm — a destructive lifecycle action
            // keeps its own approval even on the spoken-command path, and
            // an agent-path gate approval (`alreadyConfirmed`) counts too.
            guard let ask else { throw Abort.missingGrant }
            guard DriveLoop.affirmative(await ask(.confirm("Quit \(name)? It may ask to save open documents first."))) else {
                throw Abort.declined
            }
        }
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)), !app.isTerminated else {
            throw DriverConnectionError.refused("\(name) is no longer running. Nothing was changed.")
        }
        switch verb {
        case .hide:
            guard !app.isHidden else { return done("\(name) is already hidden.", task, history) }
            let rows = try await listedWindowRows(pid: pid, session: session)
            guard !rows.isEmpty else {
                throw DriverConnectionError.refused("\(name) has no windows to hide.")
            }
            feed("Hiding \(name)")
            try await focusLeased { _ = app.hide() }
            let hidden = try await pollDriver({ () async throws -> Bool in
                let rows = try await self.listedWindowRows(pid: pid, session: session)
                return rows.isEmpty || rows.allSatisfy { $0["is_on_screen"] == .bool(false) }
            }, until: { $0 })
            if hidden == true {
                return done("Hid \(name); all its windows left the screen.", task, history,
                            pid: pid, bundleID: bundle, effect: true)
            }
            throw DriverConnectionError.refused("\(name) was asked to hide, but its windows stayed on screen.")
        case .unhide:
            let wasHidden = app.isHidden
            let preRows = try await listedWindowRows(pid: pid, session: session)
            if !wasHidden, preRows.isEmpty {
                return done("\(name) is already visible and has no windows to unhide.", task, history)
            }
            if wasHidden {
                feed("Unhiding \(name)")
                try await focusLeased { _ = app.unhide() }
            } else {
                try await focusLeased { _ = app.activate(options: []) }
            }
            let shown = try await pollDriver({ () async throws -> Bool in
                guard NSRunningApplication(processIdentifier: pid_t(pid))?.isHidden == false else { return false }
                let rows = try await self.listedWindowRows(pid: pid, session: session)
                return rows.isEmpty || rows.contains { $0["is_on_screen"] != .bool(false) }
            }, until: { $0 })
            if shown == true {
                return done(wasHidden ? "Unhid \(name); it is visible again."
                                      : "\(name) was already visible.",
                            task, history, pid: pid, bundleID: bundle, effect: true)
            }
            throw DriverConnectionError.refused("\(name) was asked to unhide, but no window returned to the screen.")
        case .minimize:
            let rows = try await listedWindowRows(pid: pid, session: session)
            let wid: Int
            if let pinned = task.windowID, rows.contains(where: { $0["window_id"]?.integer == pinned }) {
                wid = pinned
            } else {
                guard let best = Self.bestWindowID(in: rows) else {
                    throw DriverConnectionError.refused("\(name) has no observable window to minimize.")
                }
                wid = best
            }
            // invoke_menu temporarily focuses a background app — ask once
            // per bundle unless a standing grant covers input already.
            // `menuFocus` grants are process-wide and per-bundle, kept in
            // shared UserDefaults — child processes (agent drive children,
            // the same binary) deliberately see the same grant: the
            // consent is about a focus borrow on the user's screen,
            // whoever's hand is on the wheel.
            let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid)
            if !isFront, !CuaStandingGrants.menuFocus(bundle: bundle), !granted() {
                guard let ask else { throw Abort.missingGrant }
                guard DriveLoop.affirmative(await ask(.confirm(
                    "Temporarily focus \(name) to perform:\nWindow → Minimize\nThe driver restores the prior focus afterward."))) else {
                    throw Abort.declined
                }
                CuaStandingGrants.grantMenuFocus(bundle: bundle)
            }
            feed("Minimizing \(name)'s window")
            try await focusLeased {
                do {
                    _ = try await self.call("invoke_menu",
                        ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                         "path": .array([.string("Window"), .string("Minimize")]),
                         "session": .string(session)])
                } catch let error as DriverConnectionError {
                    switch error {
                    case .closed, .timedOut, .remote, .unavailable, .malformed: throw error
                    case .refused, .toolRefused: break
                    }
                    try await Task.sleep(for: .milliseconds(400))
                    _ = try await self.call("invoke_menu",
                        ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                         "path": .array([.string("Window"), .string("Minimize")]),
                         "session": .string(session)])
                }
            }
            let gone = try await pollDriver({ () async throws -> Bool in
                guard let row = try await self.windowRow(pid: pid, windowID: wid, session: session) else { return true }
                return row["is_on_screen"] == .bool(false)
            }, until: { $0 })
            if gone == true {
                return done("Minimized \(name)'s window; it left the screen.", task, history,
                            pid: pid, windowID: wid, bundleID: bundle, effect: true)
            }
            throw DriverConnectionError.refused("Invoked Window → Minimize in \(name), but the window stayed on screen.")
        case .quit:
            feed("Quitting \(name)")
            try await focusLeased { _ = app.terminate() }
            let gone = try await pollDriver({ () async throws -> Bool in
                NSRunningApplication(processIdentifier: pid_t(pid))?.isTerminated ?? true
            }, until: { $0 })
            if gone == true {
                return done("Quit \(name); the process exited.", task, history,
                            pid: pid, bundleID: bundle, effect: true)
            }
            throw DriverConnectionError.refused("\(name) was asked to quit but is still running — it may be holding a save dialog open.")
        }
    }

    // MARK: - Window-scoped verbs

    /// A native menu path — `invoke_menu` resolves each segment against the
    /// live menu bar, so a single-segment path passes through as an
    /// item-only request the driver fails closed on. The call briefly
    /// fronts a background app, which is the same focus borrow the
    /// minimize lane makes: one standing-grant ask per bundle, then the
    /// focus lease serializes it against parallel raises.
    private func runMenuPath(_ path: [String], action: FastAction, pid: Int,
                             windowID: Int, name: String, bundle: String,
                             task: DriveTask, session: String,
                             history: inout [String]) async throws -> DriveResult {
        // `invoke_menu` briefly focuses a background app — ask once per
        // bundle unless the standing grant covers input. `menuFocus`
        // grants are process-wide and per-bundle in shared UserDefaults,
        // so agent children (the same binary) see the same grant —
        // deliberate: the consent is about a focus borrow on the user's
        // screen, whoever's hand is on the wheel.
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid)
        if !isFront, !CuaStandingGrants.menuFocus(bundle: bundle), !granted() {
            guard let ask else { throw Abort.missingGrant }
            guard DriveLoop.affirmative(await ask(.confirm(
                "Temporarily focus \(name) to perform:\n\(path.joined(separator: " → "))\nThe driver restores the prior focus afterward."))) else {
                throw Abort.declined
            }
            CuaStandingGrants.grantMenuFocus(bundle: bundle)
        }
        let args: [String: JSONValue] = ["pid": .number(Double(pid)),
                                       "window_id": .number(Double(windowID)),
                                       "path": .array(path.map { .string($0) }),
                                       "session": .string(session)]
        do {
            if isFront {
                _ = try await call("invoke_menu", args)
            } else {
                try await focusLeased { _ = try await self.call("invoke_menu", args) }
            }
        } catch let error as DriverConnectionError {
            // A failed-closed menu lookup is a targeting question, not a
            // transport failure — ask which menu, never retry a guess.
            if case .toolRefused(_, _, let detail) = error {
                return settle(.blocked(detail.isEmpty
                        ? "The menu didn't have that item — which menu is it in?"
                        : "\(detail) Which menu is it in?"),
                              task, history, pid: pid, windowID: windowID,
                              blockedReason: "menu path refused")
            }
            throw error
        }
        return done("\(action.result).", task, history, pid: pid,
                    windowID: windowID, bundleID: bundle, effect: true)
    }

    /// Snap/tile — `set_window_frame` against the display containing the
    /// window's center, in the top-left point space `list_windows` reports
    /// and the tool writes. The bounds readback is the verification: a
    /// window that never moved was never snapped.
    private func runWindowSnap(_ snap: FastAction.WindowSnap, action: FastAction,
                               pid: Int, windowID: Int, name: String, bundle: String,
                               task: DriveTask, session: String,
                               history: inout [String]) async throws -> DriveResult {
        guard let before = try await windowRow(pid: pid, windowID: windowID, session: session),
              let bounds = before["bounds"],
              let bx = Self.num(bounds["x"]), let by = Self.num(bounds["y"]),
              let bw = Self.num(bounds["width"]), let bh = Self.num(bounds["height"]) else {
            throw DriverConnectionError.refused("\(name)'s window bounds could not be read — nothing was moved.")
        }
        let center = CGPoint(x: bx + bw / 2, y: by + bh / 2)
        guard let d = Self.displayFrames().first(where: { $0.frame.contains(center) })?.frame else {
            return settle(.blocked("\(name)'s window isn't on any display I can see — nothing was moved."),
                          task, history, pid: pid, windowID: windowID,
                          blockedReason: "no containing display")
        }
        let frame: CGRect
        switch snap {
        case .left: frame = CGRect(x: d.minX, y: d.minY,
                                   width: d.width / 2, height: d.height)
        case .right: frame = CGRect(x: d.minX + d.width / 2, y: d.minY,
                                    width: d.width / 2, height: d.height)
        case .fill: frame = d
        }
        if abs(bx - frame.minX) < 3 && abs(by - frame.minY) < 3
            && abs(bw - frame.width) < 3 && abs(bh - frame.height) < 3 {
            return done("The window is already there.", task, history,
                        pid: pid, windowID: windowID, bundleID: bundle)
        }
        do {
            _ = try await call("set_window_frame",
                ["pid": .number(Double(pid)), "window_id": .number(Double(windowID)),
                 "x": .number(frame.minX), "y": .number(frame.minY),
                 "width": .number(frame.width), "height": .number(frame.height),
                 "session": .string(session)])
        } catch let error as DriverConnectionError {
            if case .toolRefused(_, _, let detail) = error {
                return settle(.blocked(detail), task, history,
                              pid: pid, windowID: windowID)
            }
            throw error
        }
        let moved = try await pollDriver({ () async throws -> Bool in
            guard let bounds = try await self.windowRow(pid: pid, windowID: windowID,
                                                        session: session)?["bounds"],
                  let nx = Self.num(bounds["x"]), let ny = Self.num(bounds["y"]),
                  let nw = Self.num(bounds["width"]), let nh = Self.num(bounds["height"])
            else { return false }
            return abs(nx - bx) > 1 || abs(ny - by) > 1
                || abs(nw - bw) > 1 || abs(nh - bh) > 1
        }, until: { $0 })
        guard moved == true else {
            return settle(.blocked("Asked to snap \(name)'s window, but its bounds never moved."),
                          task, history, pid: pid, windowID: windowID,
                          blockedReason: "frame unchanged")
        }
        return done("\(action.result).", task, history, pid: pid,
                    windowID: windowID, bundleID: bundle, effect: true)
    }

    /// A chorded window action with a verified effect: pre-state read,
    /// `hotkey` dispatch, then the effect predicate polled from live state.
    /// An unverifiable effect refuses — "Pressed ⌘T" is not "Opened a new tab".
    private func runWindowHotkey(keys: [String], action: FastAction, pid: Int,
                                 windowID: Int, name: String, bundle: String,
                                 task: DriveTask, session: String,
                                 history: inout [String]) async throws -> DriveResult {
        // Pre-state for the delta check — one read, only what it needs.
        var beforeCount = 0
        var beforeSelected: String?
        var beforeTitle: String?
        var beforeWindows = 0
        switch action.effect {
        case .tabsDelta, .tabSelectionDelta:
            // The tab strip and the window rows are independent reads —
            // overlap them; the pre-state just has to predate the chord.
            async let stripFetch = tabStrip(pid: pid, window: windowID, session: session)
            async let rowsFetch = listedWindowRows(pid: pid, session: session)
            let strip = try await stripFetch
            beforeCount = strip.count
            beforeSelected = strip.selected
            var rows = try await rowsFetch
            if rows.isEmpty { rows = try await listedWindowRows(pid: pid, session: session) }
            beforeTitle = rows.first(where: { $0["window_id"]?.integer == windowID })?["title"]?.string
        case .windowDelta:
            let rows = try await listedWindowRows(pid: pid, session: session)
            beforeWindows = Self.realWindowCount(in: rows)
        case .boundsToScreen, .boundsFromScreen, .windowOffScreen:
            break // post-state read alone proves the effect
        default:
            break
        }
        _ = try await call("hotkey", ["keys": .array(keys.map { .string($0) }),
                                      "pid": .number(Double(pid)),
                                      "window_id": .number(Double(windowID)),
                                      "session": .string(session)])
        let verified = try await verifyEffect(action.effect, pid: pid, windowID: windowID,
                                              beforeCount: beforeCount,
                                              beforeSelected: beforeSelected,
                                              beforeTitle: beforeTitle,
                                              beforeWindows: beforeWindows,
                                              session: session)
        guard verified else {
            throw DriverConnectionError.refused(
                "\(action.description) was delivered, but the expected change never appeared.")
        }
        return done("\(action.result).", task, history, pid: pid, windowID: windowID,
                    bundleID: bundle, effect: true)
    }

    /// The `Effect` predicates — each reads fresh state and polls until the
    /// postcondition holds or the budget expires.
    private func verifyEffect(_ effect: FastAction.Effect, pid: Int, windowID: Int,
                              beforeCount: Int, beforeSelected: String?,
                              beforeTitle: String?, beforeWindows: Int,
                              session: String) async throws -> Bool {
        switch effect {
        case .tabsDelta(let delta):
            // Cheap reads first: the window-title poll rides list_windows;
            // the tab strip is the precise instrument when it exists.
            if let title = try await pollDriver({ try await self.windowTitle(pid: pid, window: windowID, session: session) },
                                                until: { $0 != nil && $0 != beforeTitle }),
               title != beforeTitle { return true }
            if let observed = try await pollDriver({ try await self.tabStrip(pid: pid, window: windowID, session: session).count },
                                                   until: { $0 == beforeCount + delta }) {
                return observed == beforeCount + delta
            }
            return false
        case .tabSelectionDelta:
            if let title = try await pollDriver({ try await self.windowTitle(pid: pid, window: windowID, session: session) },
                                                until: { $0 != nil && $0 != beforeTitle }),
               title != beforeTitle { return true }
            if let observed = try await pollDriver({ try await self.tabStrip(pid: pid, window: windowID, session: session).selected },
                                                   until: { $0 != nil && $0 != beforeSelected }) {
                return observed != beforeSelected
            }
            return false
        case .windowDelta(let delta):
            let observed = try await pollDriver({ () async throws -> Int in
                Self.realWindowCount(in: try await self.listedWindowRows(pid: pid, session: session))
            }, until: { $0 == beforeWindows + delta })
            return observed == beforeWindows + delta
        case .typedText:
            return true // verified at the element in dispatchFastType
        case .windowOffScreen:
            let gone = try await pollDriver({ () async throws -> Bool in
                guard let row = try await self.windowRow(pid: pid, windowID: windowID, session: session) else { return true }
                return row["is_on_screen"] == .bool(false)
            }, until: { $0 })
            return gone == true
        case .appOffScreen:
            let hidden = try await pollDriver({ () async throws -> Bool in
                let rows = try await self.listedWindowRows(pid: pid, session: session)
                return rows.isEmpty || rows.allSatisfy { $0["is_on_screen"] == .bool(false) }
            }, until: { $0 })
            return hidden == true
        case .appOnScreen:
            let shown = try await pollDriver({ () async throws -> Bool in
                let rows = try await self.listedWindowRows(pid: pid, session: session)
                return rows.contains { $0["is_on_screen"] != .bool(false) }
            }, until: { $0 })
            return shown == true
        case .boundsToScreen:
            return (try await pollDriver({ () async throws -> Bool in
                Self.boundsCoverAScreen(try await self.windowRow(pid: pid, windowID: windowID, session: session)?["bounds"])
            }, until: { $0 })) == true
        case .boundsFromScreen:
            return (try await pollDriver({ () async throws -> Bool in
                guard let bounds = try await self.windowRow(pid: pid, windowID: windowID, session: session)?["bounds"] else { return false }
                return !Self.boundsCoverAScreen(bounds)
            }, until: { $0 })) == true
        case .processGone:
            return (try await pollDriver({ () async throws -> Bool in
                NSRunningApplication(processIdentifier: pid_t(pid))?.isTerminated ?? true
            }, until: { $0 })) == true
        case .delivered:
            return true
        }
    }

    /// Exact text entry through the driver's element-scoped `type_text`. Fires
    /// only when the window exposes exactly one editable element — multiple
    /// fields are a targeting question, which belongs to the drive loop.
    /// A readable `value` delta proves insertion; when the element never
    /// exposes a value (secure fields) the driver's delivery is reported as
    /// delivery, not as a proven write.
    private func dispatchFastType(_ payload: String, pid: Int, window wid: Int,
                                  name: String, bundle: String, task: DriveTask,
                                  session: String,
                                  history: inout [String],
                                  confirmed: inout Bool,
                                  retainedTarget: FocusedTextBinding.Capture? = nil) async throws -> DriveResult? {
        // The typed payload is a hard floor beneath consent: this lane's
        // corpus scan only ever sees field/app names, so the command-
        // shaped deny list runs on the text itself before any dispatch —
        // a spoken "type rm -rf …" refuses here no matter who asked.
        if let hit = CuaPolicy.deniedInTypedPayload(payload) {
            feed("denied: typed payload \(hit)")
            throw Abort.denied("Refused: the text itself runs '\(hit)' — shell-shaped input is the user's own hands, not ours")
        }
        let focusedAllowed = task.windowID == wid && task.application == bundle
            && task.values["text"] == payload
        if requiresCapturedTextTarget || (BrowserSupport.isBrowser(bundleID: bundle) && focusedAllowed) {
            guard focusedAllowed else {
                return settle(.blocked("The captured typing target changed. No text was sent."),
                              task, history, pid: pid, windowID: wid,
                              blockedReason: "captured typing target changed")
            }
            let captured: FocusedTextBinding?
            switch retainedTarget {
            case .some(.bound(let target)): captured = target
            case .some(.unavailable): captured = nil
            case .none: captured = await focusedTextTarget(pid, wid)
            }
            guard let target = captured else {
                return settle(.blocked("Focus an editable field in the captured window. No text was sent."),
                              task, history, pid: pid, windowID: wid,
                              blockedReason: "focused editable field unavailable")
            }
            return try await dispatchFocusedType(payload, target: target, pid: pid, window: wid,
                                                  name: name, bundle: bundle, task: task,
                                                  session: session, history: &history, confirmed: &confirmed)
        }
        let snapshot = try await observe("get_window_state",
            ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
             "tree_format": .string("elements"),
             "include_screenshot": .bool(false), "max_elements": .number(220),
             "session": .string(session)])
        let elements = snapshot["structuredContent"]?["elements"]?.array
            ?? snapshot["elements"]?.array ?? []
        guard let target = Self.uniqueEditableTarget(in: elements) else {
            if focusedAllowed, let target = await focusedTextTarget(pid, wid) {
                return try await dispatchFocusedType(payload, target: target, pid: pid, window: wid,
                                                      name: name, bundle: bundle, task: task,
                                                      session: session, history: &history, confirmed: &confirmed)
            }
            return nil
        }
        // The field's identity (label/description) is the deny corpus;
        // the payload's own scan already ran above — `decide` scans
        // `args["text"]` the same way when the loop's dispatch path
        // reaches it.
        let fieldName = target["label"]?.string ?? target["description"]?.string ?? ""
        try await gateExplicit("type_text", corpus: "\(name) \(fieldName)",
                               denied: task.deny, confirmed: &confirmed)
        let before = target["value"]?.string
        _ = try await call("type_text", [
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "element_token": .string(target["element_token"]?.string ?? ""),
            "delivery_mode": .string("background"),
            "text": .string(payload),
            "session": .string(session)])
        let index = target["element_index"]?.integer
        let role = target["role"]?.string
        let label = target["label"]?.string ?? target["description"]?.string
        let held = try await pollDriver({ () async throws -> Bool in
            let fresh = try await self.observe("get_window_state",
                ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                 "tree_format": .string("elements"),
                 "include_screenshot": .bool(false), "max_elements": .number(220),
                 "session": .string(session)])
            let value = Self.sameElement(
                in: (fresh["structuredContent"]?["elements"]?.array
                     ?? fresh["elements"]?.array) ?? [],
                index: index, role: role, label: label)?["value"]?.string
            return value != before && value?.contains(payload) == true
        }, until: { $0 })
        if held == true {
            return done("Typed the text; the field held it.", task, history,
                        pid: pid, windowID: wid, bundleID: bundle, effect: true)
        }
        return settle(.blocked("Text was sent to \(name), but the field's value was not independently confirmed. Check it before trying again."),
                      task, history, pid: pid, windowID: wid,
                      blockedReason: "literal typing delivery unverified")
    }

    private func dispatchFocusedType(_ payload: String, target: FocusedTextBinding,
                                     pid: Int, window wid: Int, name: String, bundle: String,
                                     task: DriveTask, session: String, history: inout [String],
                                     confirmed: inout Bool) async throws -> DriveResult {
        try await gateExplicit("type_text", corpus: "\(name) \(target.label)",
                               denied: task.deny, confirmed: &confirmed)
        return try await focusLeased {
            guard await target.isCurrent() else {
                throw Abort.refused("The focused field changed before typing. No text was sent.")
            }
            guard let before = await target.value() else {
                return settle(.blocked("The focused field could not be read. No text was sent."),
                              task, history, pid: pid, windowID: wid,
                              blockedReason: "focused typing value unavailable")
            }
            let expected: String?
            var capturedSelection: NSRange?
            if let selection = target.selection {
                guard let range = await selection(),
                      range.location >= 0, range.length >= 0,
                      range.location <= before.utf16.count,
                      range.length <= before.utf16.count - range.location else {
                    return settle(.blocked("The text insertion point could not be verified. No text was sent."),
                                  task, history, pid: pid, windowID: wid,
                                  blockedReason: "focused typing selection unavailable")
                }
                expected = (before as NSString).replacingCharacters(in: range, with: payload)
                capturedSelection = range
            } else { expected = nil }
            try Task.checkCancellation()
            guard await target.isCurrent() else {
                throw Abort.refused("The focused field changed before typing. No text was sent.")
            }
            try Task.checkCancellation()
            if requiresCapturedTextTarget, !BrowserSupport.isBrowser(bundleID: bundle),
               let selection = capturedSelection, let expected, let insert = target.insertSelectedText {
                if let receipt = try await insert(payload, before, selection) {
                    await nativeTextEvent(receipt)
                    try Task.checkCancellation()
                    let current = await target.isCurrent()
                    let after = await target.value()
                    let exact = after == expected && after != before
                    history.append("Native focused typing proof: delivered=\(receipt.succeeded) current=\(current) exact=\(exact)")
                    if receipt.succeeded, current, exact {
                        return done("Typed the text; the focused field held it.", task, history,
                                    pid: pid, windowID: wid, bundleID: bundle, effect: true)
                    }
                    return settle(.blocked("The native text insertion could not be independently verified. Check the field before trying again."),
                                  task, history, pid: pid, windowID: wid,
                                  blockedReason: "native focused typing delivery unverified")
                }
                guard await target.isCurrent(), await target.value() == before,
                      await target.selection?() == selection else {
                    throw Abort.refused("The captured field or insertion point changed. No text was sent.")
                }
                try Task.checkCancellation()
            }
            let reply = try await call("type_text", [
                "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                "delivery_mode": .string(BrowserSupport.isBrowser(bundleID: bundle) ? "foreground" : "background"),
                "text": .string(payload),
                "session": .string(session)
            ])
            let result = reply["structuredContent"] ?? reply
            let currentAfter = await target.isCurrent()
            let after = await target.value()
            let exact = after != nil && expected != nil && after == expected
            let canonicalNative = requiresCapturedTextTarget && !BrowserSupport.isBrowser(bundleID: bundle)
                && result["verified"] == nil && result["route"] == .string("accessibility")
                && result["delivery"]?["mode"] == .string("background")
                && result["evidence"]?.array?.contains(where: { $0["kind"] == .string("value_readback") }) == true
                && result["summary"] != nil && exact
            let receiptConfirmed = result["effect"] == .string("confirmed")
                && (result["verified"] == .bool(true) || canonicalNative)
                && !["partial", "refused"].contains(result["status"]?.string ?? "")
                && result["refusal"] == nil && result["execution_state"] != .string("unknown")
            history.append("Focused typing proof: receiptConfirmed=\(receiptConfirmed) canonicalNative=\(canonicalNative) current=\(currentAfter) exact=\(exact)")
            if receiptConfirmed,
               currentAfter, let after,
               after != before, expected.map({ after == $0 }) ?? after.contains(payload) {
                return done("Typed the text; the focused field held it.", task, history,
                            pid: pid, windowID: wid, bundleID: bundle, effect: true)
            }
            return settle(.blocked("Text was sent to the focused field, but its effect could not be independently verified. Check it before trying again."),
                          task, history, pid: pid, windowID: wid,
                          blockedReason: "focused typing delivery unverified")
        }
    }

    /// "search <app> for X" on a non-Spotify target: element-scoped text into
    /// the app's unique search field plus a window-scoped Return. Spotify's
    /// deterministic search URI rides the launch hand-off when present —
    /// `launchURLs` already delivered it, so only the Return lands here.
    private func dispatchAppSearch(_ query: String, playTopHit: Bool, pid: Int, window wid: Int,
                                   name: String, bundle: String, task: DriveTask,
                                   session: String,
                                   history: inout [String],
                                   confirmed: inout Bool) async throws -> DriveResult? {
        if bundle == Self.spotifyBundle {
            _ = try await call("press_key", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                             "key": .string("return"),
                                             "delivery_mode": .string("background"),
                                             "session": .string(session)])
            return done("Dispatched \"\(query)\" to Spotify; the search URI was delivered at launch.",
                        task, history, pid: pid, windowID: wid, bundleID: bundle, effect: true)
        }
        // The query lands as a typed payload — scan the text itself, not
        // just the field it targets (same hard floor as dispatchFastType).
        if let hit = CuaPolicy.deniedInTypedPayload(query) {
            feed("denied: search query \(hit)")
            throw Abort.denied("Refused: the query itself runs '\(hit)' — shell-shaped input is the user's own hands, not ours")
        }
        let snapshot = try await observe("get_window_state",
            ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
             "include_screenshot": .bool(false), "max_elements": .number(220),
             "session": .string(session)])
        let elements = snapshot["structuredContent"]?["elements"]?.array
            ?? snapshot["elements"]?.array ?? []
        guard let target = Self.uniqueSearchTarget(in: elements) else { return nil }
        let before = target["value"]?.string
        let targetIndex = target["element_index"]?.integer
        let targetRole = target["role"]?.string
        let targetLabel = target["label"]?.string ?? target["description"]?.string
        // The field's identity is the deny corpus — the payload's own
        // scan already ran above, so a shell-shaped query refused there
        // never reaches this gate.
        try await gateExplicit("type_text", corpus: "\(name) \(targetLabel ?? "")",
                               denied: task.deny, confirmed: &confirmed)
        _ = try await call("type_text", [
            "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
            "element_token": .string(target["element_token"]?.string ?? ""),
            "delivery_mode": .string("background"),
            "text": .string(query),
            "session": .string(session)])
        let fieldHoldsQuery = try await pollDriver { () async throws -> Bool in
            let fresh = try await self.observe("get_window_state",
                ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                 "include_screenshot": .bool(false), "max_elements": .number(220),
                 "session": .string(session)])
            let value = Self.sameElement(
                in: (fresh["structuredContent"]?["elements"]?.array
                     ?? fresh["elements"]?.array) ?? [],
                index: targetIndex, role: targetRole, label: targetLabel)?["value"]?.string
            return value != before && value?.localizedCaseInsensitiveContains(query) == true
        } until: { $0 }
        let beforeTitle = try? await windowTitle(pid: pid, window: wid, session: session)
        _ = try await call("press_key", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                         "key": .string("return"),
                                         "delivery_mode": .string("background"),
                                         "session": .string(session)])
        let moved = try await pollDriver(attempts: 4,
            { try await self.windowTitle(pid: pid, window: wid, session: session) },
            until: { $0 != nil && $0 != beforeTitle }) ?? nil
        let label = targetLabel ?? "the search field"
        let verb = playTopHit ? "Dispatched play for" : "Searched \(name) for"
        if fieldHoldsQuery == true {
            let evidence = "\(verb) \"\(query)\"; the field held it."
            return done(moved != nil ? "\(evidence) The window moved to results." : evidence,
                        task, history, pid: pid, windowID: wid, bundleID: bundle, effect: true)
        }
        return done("Delivered \"\(query)\" to \(label) in \(name) and pressed Return; the field's value was not independently confirmed.",
                    task, history, pid: pid, windowID: wid, bundleID: bundle, effect: true)
    }

    /// A URL lane: the typed-CDP bound browser when one's bound, else a
    /// LaunchServices hand-off to the default browser — itself an activation.
    private func dispatchURLLane(_ url: String, task: DriveTask, session: String,
                                 history: inout [String]) async throws -> DriveResult {
        if let browser = try await boundIsolatedBrowser() {
            do {
                if let evidence = try await navigateBoundBrowser(browser, url: url,
                                                                 task: task, session: session,
                                                                 history: &history) {
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
                    // hold the URL, so a re-delivery would navigate twice.
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
        do {
            _ = try await focusLeased {
                try await NSWorkspace.shared.open(target, configuration: NSWorkspace.OpenConfiguration())
            }
        } catch {
            throw DriverConnectionError.refused("The URL could not be delivered to any browser.")
        }
        return done("Opened \(url) in the default browser.", task, history, effect: true)
    }

    /// A bare web search opens a FRESH tab — never navigates the bound tab
    /// the user is looking at (a Google Doc must not become the results
    /// page). Prefers the frontmost-or-unique running browser via
    /// LaunchServices, falls back to the default browser. Needs no CDP
    /// grant: `open` is a launch hand-off, not page access.
    private func dispatchWebSearch(_ url: String, task: DriveTask,
                                   history: inout [String]) async throws -> DriveResult {
        guard let target = URL(string: url) else {
            throw DriverConnectionError.refused("The search URL could not be delivered.")
        }
        let browser = try? await boundIsolatedBrowser()
        let appURL = browser.flatMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle)
        }
        do {
            _ = try await focusLeased {
                if let appURL {
                    try await NSWorkspace.shared.open([target], withApplicationAt: appURL,
                                                      configuration: NSWorkspace.OpenConfiguration())
                } else {
                    try await NSWorkspace.shared.open(target, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        } catch {
            throw DriverConnectionError.refused("The search could not be delivered to any browser.")
        }
        return done(browser != nil
                    ? "Opened the search in a new \(browser!.name) tab."
                    : "Opened the search in a new browser tab.",
                  task, history, effect: true)
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
        return nil
    }

    private func navigateBoundBrowser(_ browser: (pid: Int, name: String, bundle: String),
                                      url: String, task: DriveTask, session: String,
                                      history: inout [String]) async throws -> DriveResult? {
        let rows = try await listedWindowRows(pid: browser.pid, session: session)
        guard let wid = Self.bestWindowID(in: rows) else { return nil }
        guard let bound = try await BrowserSupport.bind(pid: browser.pid, windowID: wid,
                                                        session: session, call: call),
              let tabID = bound.tabID.isEmpty ? nil : bound.tabID else { return nil }
        let outcome = try await call("browser_navigate",
            BrowserSupport.navigateArgs(bound, url: url, session: session))
        // Verify on the addressed tab itself: a page-scoped read must report
        // the destination url — never a same-titled sibling tab. Host
        // equality, not substring: "apple.com" must not pass against
        // "notapple.com", while subdomains still match their registrable host.
        let wantedHost = URLComponents(string: url)?.host?.lowercased()
            ?? url.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                .split(separator: "/").first.map(String.init)?.lowercased()
        for _ in 0..<6 {
            if let after = try? await observe("get_browser_state",
                    ["pid": .number(Double(browser.pid)), "window_id": .number(Double(wid)),
                     "target_id": .string(bound.targetID), "tab_id": .string(tabID),
                     "session": .string(session)]) {
                let payload = after["structuredContent"] ?? after
                if let pageURL = payload["page"]?["url"]?.string ?? payload["url"]?.string,
                   let wantedHost,
                   Self.urlHostMatches(pageURL, wanted: wantedHost) {
                    return done("Opened \(url) in \(browser.name).", task, history,
                                pid: browser.pid, windowID: wid, bundleID: browser.bundle,
                                effect: true)
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CuaUncertainOutcome(tool: "browser_navigate", result: outcome)
    }

    // MARK: - Observation primitives

    func verifyForeground(pid: Int, windowID: Int, session: String) async throws -> Bool {
        (try await pollDriver({ () async throws -> Bool in
            let row = try await self.windowRow(pid: pid, windowID: windowID, session: session)
            return self.frontmostPID() == pid && self.frontmostWindowID() == windowID
                && row?["is_on_screen"] == .bool(true)
        }, until: { $0 })) == true
    }

    func listedWindowRows(pid: Int, session: String) async throws -> [JSONValue] {
        let list = try await observe("list_windows",
            ["pid": .number(Double(pid)), "session": .string(session)])
        return list["structuredContent"]?["windows"]?.array ?? list["windows"]?.array ?? []
    }

    private func windowTitle(pid: Int, window wid: Int, session: String) async throws -> String? {
        try await listedWindowRows(pid: pid, session: session)
            .first(where: { $0["window_id"]?.integer == wid })?["title"]?.string
    }

    private func windowRow(pid: Int, windowID wid: Int, session: String) async throws -> JSONValue? {
        try await listedWindowRows(pid: pid, session: session)
            .first(where: { $0["window_id"]?.integer == wid })
    }

    func windowID(named wanted: String?, in rows: [JSONValue]) -> Int? {
        guard let wanted, !wanted.isEmpty else { return nil }
        return rows.first(where: {
            ($0["title"]?.string ?? "").localizedCaseInsensitiveContains(wanted)
        })?["window_id"]?.integer
    }

    private func tabStrip(pid: Int, window wid: Int, session: String) async throws -> (count: Int, selected: String?) {
        let snapshot = try await observe("get_window_state",
            ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
             "include_screenshot": .bool(false), "max_elements": .number(220),
             "session": .string(session)])
        return Self.tabStrip(in: (snapshot["structuredContent"]?["elements"]?.array
                                  ?? snapshot["elements"]?.array) ?? [])
    }

    /// Poll a cheap Driver read until `until` holds or the budget expires.
    /// Keystroke effects land in tens of milliseconds; the bound keeps an
    /// undeliverable effect honest instead of hanging the task. Read
    /// failures propagate — a dead transport or an uncertain outcome must
    /// never be folded into "the effect did not happen."
    private func tracedNativeActivation<T>(
        events: @escaping @Sendable (VoiceCommandTrace.Stage) async -> Void,
        restoringHidden: Bool = false,
        _ body: () async throws -> T
    ) async throws -> T {
        try await focusLeased {
            await events(restoringHidden ? .nativeUnhideBegin : .nativeActivationBegin)
            do {
                try Task.checkCancellation()
                let result = try await body()
                await events(restoringHidden ? .nativeUnhideEnd : .nativeActivationEnd)
                return result
            } catch {
                await events(restoringHidden ? .nativeUnhideFailed : .nativeActivationFailed)
                throw error
            }
        }
    }

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

    /// Hold the focus lease across activation-prone calls — a parallel
    /// lane's raise must not interleave between our raise and its verify.
    func focusLeased<T>(_ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard let lease = focusLease else { return try await body() }
        await lease.acquire()
        do {
            try Task.checkCancellation()
            let result = try await body()
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }

    /// A `.done` settle for a fast-lane outcome whose effect is already
    /// verified (or whose delivery is the only honest claim available).
    /// Routes through `settle` so the outcome lands in the log.
    private func done(_ say: String, _ task: DriveTask, _ history: [String],
                      pid: Int? = nil, windowID: Int? = nil,
                      bundleID: String? = nil, effect: Bool = false) -> DriveResult {
        var h = history
        h.append(say)
        feed(say)
        return settle(.done, task, h, pid: pid, windowID: windowID,
                      bundleID: bundleID, confirmedAny: effect)
    }

    // MARK: - Static helpers

    /// JSONValue number extraction for optional bounds/scale fields —
    /// `integer` is exact-Int only; these carry fractional geometry.
    private static func num(_ v: JSONValue?) -> Double? {
        if case .number(let d)? = v { return d }
        return nil
    }

    /// The pid of a running app by bundle — the workspace roster answers
    /// without an inventory roundtrip.
    static func runningPID(bundle: String, in apps: [JSONValue]) -> Int? {
        livePID(bundle: bundle, in: apps)
            ?? NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundle })
                .map { Int($0.processIdentifier) }
    }

    /// After an uncertain launch, poll AppKit's roster for the process —
    /// it answers locally with no driver grant. ~2s covers a spawn still
    /// registering with LaunchServices.
    static func observedPID(bundle: String) async -> Int? {
        for _ in 0..<14 {
            if Task.isCancelled { return nil }
            if let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundle }) {
                return Int(app.processIdentifier)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    /// A resolved app row's live pid — the driver reports running pids on
    /// its `list_apps` inventory; absent/zero means not running.
    static func livePID(bundle: String, in apps: [JSONValue]) -> Int? {
        guard let pid = apps.first(where: { $0["bundle_id"]?.string == bundle })?["pid"]?.integer,
              pid > 0 else { return nil }
        return pid
    }

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
    /// own results page on launch hand-off.
    static func spotifySearchURI(_ query: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "spotify:search:" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query)
    }

    /// Browsers the driver's typed CDP route attests: Chrome and Edge carry
    /// an ownable DevTools endpoint; Safari/Firefox have no DOM binding and
    /// stay on the native/keyboard lanes.
    static func supportsIsolatedBrowser(_ bundle: String) -> Bool {
        ["com.google.Chrome", "com.microsoft.edgemac"].contains(bundle)
    }

    /// Real browser/document windows, excluding the off-screen untitled
    /// utility windows apps keep around (Chrome holds several 1×1 phantoms).
    static func realWindowCount(in windows: [JSONValue]) -> Int {
        windows.filter { $0["is_on_screen"] != .bool(false) && !($0["title"]?.string ?? "").isEmpty }.count
    }

    /// The window's browser-level tab strip: radio/tab elements that are NOT
    /// inside page content. On real Chrome, browser tabs are AXRadioButton
    /// children of AXWindow while in-page tab widgets live under AXWebArea —
    /// the ancestor exclusion is what separates them. `selected` carries a
    /// position-prefixed label so equal titles on different tabs still differ.
    static func tabStrip(in elements: [JSONValue]) -> (count: Int, selected: String?) {
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

    /// The window a window-scoped action binds when the task pinned
    /// nothing and named no title. The fallback is explicit and
    /// deterministic — a titled, on-screen window in z-order first, then
    /// any visible window, then any titled window — never a positional
    /// first row, and NEVER a substitute for a pinned window (a closed
    /// pin refuses at the pin check, it does not rebind).
    static func bestWindowID(in windows: [JSONValue]) -> Int? {
        let visible = windows.filter { $0["is_on_screen"] != .bool(false) }
        let titled = { (list: [JSONValue]) in list.filter { !($0["title"]?.string ?? "").isEmpty } }
        let candidates = !titled(visible).isEmpty ? titled(visible)
            : (!visible.isEmpty ? visible : titled(windows))
        return candidates.max { ($0["z_index"]?.integer ?? Int.min) < ($1["z_index"]?.integer ?? Int.min) }?["window_id"]?.integer
    }

    /// The driver-tool name a fast-lane action would ride, so `decide`'s
    /// needsConfirm prompt names the effect in its own words instead of
    /// a generic "computer use".
    static func fastLaneToolName(for action: FastAction) -> String {
        switch action.body {
        case .hotkey, .systemHotkey: return "press_key"
        case .menu: return "invoke_menu"
        case .windowFrame: return "window_control"
        case .scroll: return "scroll"
        case .type, .appSearch: return "type_text"
        case .mediaKey: return "media key"
        case .navigateURL, .webSearch: return "browser_navigate"
        case .appControl(let verb):
            switch verb {
            case .quit: return "quit app"
            case .minimize: return "window_control"
            case .hide, .unhide: return "hide app"
            }
        case .gaze: return "click"
        case .tracker: return "tracker control"
        case .overlay, .clickNamed, .showNamed: return "click"
        case .repeatLast: return "repeat last action"
        case .locate: return "list_windows"
        case .dictation: return "dictation"
        }
    }

    /// The window's sole editable element, or nil when there is none or the
    /// choice between several is genuinely ambiguous. Element-token dispatch
    /// types into exactly this element — no focus guessing.
    static func uniqueEditableTarget(in elements: [JSONValue]) -> JSONValue? {
        let candidates = elements.filter {
            FocusedTextBinding.accepts(role: $0["role"]?.string, subrole: $0["subrole"]?.string,
                                      enabled: $0["enabled"]?.bool, readOnly: $0["read_only"]?.bool)
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
    /// fallback when the list order shifted.
    static func sameElement(in elements: [JSONValue], index: Int?, role: String?, label: String?) -> JSONValue? {
        if let index, let hit = elements.first(where: { $0["element_index"]?.integer == index }) {
            return hit
        }
        guard let role else { return nil }
        return elements.first {
            $0["role"]?.string == role && ($0["label"]?.string ?? $0["description"]?.string) == label
        }
    }

    /// Whether the window's bounds cover an attached screen — the observable
    /// state of macOS full screen. A couple of points of tolerance absorbs
    /// fractional Retina geometry.
    static func boundsCoverAScreen(_ bounds: JSONValue?) -> Bool {
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

    /// Whether an action could have a consequence beyond a reversible local
    /// change — sending, deleting, purchasing, closing/quitting, or security —
    /// and so still needs an approval call. Ordinary clicks, text and
    /// navigation skip it entirely. Matching is deliberately generous: a
    /// false positive costs one extra approval ask, a false negative skips
    /// a safety check.
    static func requiresRiskJudgment(goal: String, actionDescription: String) -> Bool {
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
}
