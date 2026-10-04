import Foundation
import AppKit
import JevVoiceCore

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
    typealias Generate = CuaTaskAgent.Generate

    private let call: Call
    private let judge: Judge
    private let generate: Generate?
    private let approve: ((String) async throws -> Bool)?
    private let progress: (String) -> Void
    /// When the user's browser refuses automation binding, the agent prepares
    /// an approved isolated profile and hands the loop its new pid+window.
    /// Called at most once per run.
    private let escalateBrowser: (() async throws -> (pid: Int, windowID: Int))?
    /// True when the run target is already an isolated profile the agent
    /// prepared — `get_browser_state` binds it directly, no prepare call.
    private let browserPreparedExternally: Bool
    /// Extracts the payload words of an insert request that carries no
    /// bounded literal — called lazily, only when a type action is picked.
    private let payload: ((String, String) async throws -> String)?

    private static let maximumSteps = 24
    private static let maximumUnprovenDone = 2
    private static let maximumDispatchFailures = 3
    private static let maximumElementCandidates = 40
    private static let navigationPolls = 6

    private(set) var observedPostconditions: [CuaObservedPostcondition] = []
    private(set) var pendingQuestionOptions: [String] = []
    private(set) var mutatedContent = false
    /// The window the loop is pinned to — repinned to a task-produced window
    /// when exactly one appears (a created document outranks a baseline one).
    private(set) var currentWindowID: Int?
    private var history: [JSONValue] = []
    private var generatedText: String?

    init(call: @escaping Call, judge: @escaping Judge,
         generate: Generate? = nil,
         approve: ((String) async throws -> Bool)? = nil,
         escalateBrowser: (() async throws -> (pid: Int, windowID: Int))? = nil,
         browserPreparedExternally: Bool = false,
         payload: ((String, String) async throws -> String)? = nil,
         progress: @escaping (String) -> Void = { _ in }) {
        self.call = call; self.judge = judge
        self.generate = generate; self.approve = approve; self.progress = progress
        self.escalateBrowser = escalateBrowser
        self.browserPreparedExternally = browserPreparedExternally
        self.payload = payload
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
        case draftText
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
            case .draftText: return "draft_text"
            case .done: return "done"
            case .stuck: return "stuck"
            }
        }

        /// Lanes that dispatch app-level input. The driver cannot pin them
        /// to one window when the app owns several — it reports that as
        /// `same_pid_keyboard_ambiguity`, a durable fact about the pid.
        var usesWindowInput: Bool {
            switch self {
            case .typeIntoWindow, .pressKey, .hotkey, .newTab: return true
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
            case .done, .stuck, .draftText:
                return .none
            default:
                return .press
            }
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
    private static let hotkeyChords: [[String]] = [
        ["cmd", "t"], ["cmd", "l"], ["cmd", "n"], ["cmd", "w"], ["cmd", "a"],
        ["cmd", "c"], ["cmd", "v"], ["cmd", "x"], ["cmd", "z"], ["cmd", "s"],
        ["cmd", "q"], ["cmd", "f"], ["cmd", "shift", "z"]]

    // MARK: - Main loop

    /// Runs the task inside an already-resolved app window to a verified
    /// outcome or an honest refusal. `baselineWindowIDs` is the window set
    /// that predates the task (empty when the task itself launched the app):
    /// a window outside it is task-produced — the one bit of bookkeeping a
    /// create-scope done-veto needs.
    func run(goal: String, context: String, pid: Int, appName name: String, bundleID bundle: String,
             scope: String, literal: String?, contentMode: CuaExecutorDecision.ContentMode,
             windowID: Int?, baselineWindowIDs: Set<Int>) async throws -> String {
        var pid = pid
        var windowID = windowID
        var textToInsert = literal
        // An insert request without a bounded literal still types — the
        // payload extractor resolves the exact words when a type lane is
        // picked (so a non-insert goal never pays that call).
        var insertImplied = textToInsert != nil || contentMode != .control
            || CuaTaskAgent.requestOperand(in: goal) != nil
        var browserTarget: JSONValue?      // latest target_id; dies with each re-read
        var browserShownTab: String?       // tab_id the page refs belong to
        var tabsBaseline: [String]?
        var newTabRequested = false
        var dispatchFailures = 0
        /// The driver proved app-level input can't be pinned to one window
        /// of this pid — those lanes stop being offered for the run.
        var windowInputAmbiguous = false
        var unprovenDone = 0
        var isolatedEscalated = false
        var bindingUpgradeTried = false
        /// After a text dispatch, the next observation proves it landed — an
        /// element value containing the text is recorded as a verified fact.
        var pendingInsertProof: (index: Int?, text: String)?
        currentWindowID = windowID

        let isBrowser = CuaTaskAgent.supportsIsolatedBrowser(bundle)

        for _ in 0..<Self.maximumSteps {
            try Task.checkCancellation()
            guard var wid = windowID else {
                throw DriverConnectionError.refused("No usable window exists in \(name). Nothing was dispatched.")
            }

            // ── Observe: window elements (+ browser page when bound).
            let snapshot = try await call("get_window_state", [
                "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                "include_screenshot": .bool(false), "max_elements": .number(200)])
            let elements = snapshot["elements"]?.array ?? []
            let windowTitle = snapshot["window"]?["title"]?.string
                ?? snapshot["title"]?.string ?? ""

            // A previously dispatched insertion is verified the moment an
            // element's value reads it back — evidence, not tool acceptance.
            if let proof = pendingInsertProof, !proof.text.isEmpty {
                func reads(_ element: JSONValue) -> Bool {
                    element["value"]?.string?.contains(proof.text) == true
                        || element["label"]?.string?.contains(proof.text) == true
                }
                let target = proof.index.flatMap { i in
                    elements.first { $0["element_index"]?.integer == i } }
                let hit = target ?? elements.first(where: { reads($0) })
                if let hit, reads(hit) {
                    let label = hit["label"]?.string ?? hit["title"]?.string ?? "the field"
                    recordPostcondition(.resultObserved, "The inserted text is visible in \(label).",
                                        appName: name, bundleID: bundle, processID: pid, windowID: wid)
                    history.append(.object(["observation": .string(
                        "Verified: the inserted text now reads back from \(label).")]))
                    pendingInsertProof = nil
                }
            }

            var tabs: [JSONValue] = []
            var pageRefs: [JSONValue] = []
            var browserPage: JSONValue = .null
            if isBrowser {
                let page = try await boundBrowser(pid: &pid, wid: &wid,
                                                  target: &browserTarget, shownTab: &browserShownTab,
                                                  isolatedEscalated: &isolatedEscalated,
                                                  bindingUpgradeTried: &bindingUpgradeTried)
                windowID = wid
                tabs = page.tabs; pageRefs = page.refs; browserPage = page.state
            }

            // ── Candidates: flat, from this observation only.
            var lanes: [String: Lane] = [:]
            var criteria: [String: String?] = [:]
            func offer(_ lane: Lane, _ description: String) {
                lanes[lane.id] = lane; criteria[lane.id] = description
            }

            // A baseline window in a create request is not the document the
            // task will produce — text insertion is only offered once the
            // loop is pinned to a task-produced window.
            let baselinePinned = scope == "create" && baselineWindowIDs.contains(wid)
            // Insert requests without a bounded literal still offer typing —
            // the payload extractor resolves the words at dispatch time.
            let offersInsertion = !baselinePinned
                && (textToInsert != nil || generatedText != nil || insertImplied)
            var elementCandidates = 0
            for element in elements {
                guard elementCandidates < Self.maximumElementCandidates else { break }
                let index = element["element_index"]?.integer ?? -1
                let token = element["element_token"]?.string ?? String(index)
                let role = element["role"]?.string ?? ""
                let label = element["label"]?.string ?? element["title"]?.string ?? ""
                guard index >= 0, !role.isEmpty else { continue }
                if Self.textRoles.contains(role), offersInsertion {
                    offer(.typeIntoElement(token: token, index: index), "Type the supplied text into \(role) \"\(label)\"")
                    elementCandidates += 1
                } else if Self.clickRoles.contains(role) {
                    offer(.clickElement(token: token, index: index), "Click \(role) \"\(label)\"")
                    elementCandidates += 1
                }
            }
            if offersInsertion, !windowInputAmbiguous {
                offer(.typeIntoWindow, "Type the supplied text into this window as keyboard input")
            }
            if !windowInputAmbiguous {
                for key in Self.keyNames { offer(.pressKey(key), "Press \(key)") }
                for chord in Self.hotkeyChords { offer(.hotkey(chord), "Press \(chord.joined(separator: "+"))") }
            }
            for direction in ["up", "down", "left", "right"] { offer(.scroll(direction), "Scroll \(direction)") }
            if isBrowser {
                if !windowInputAmbiguous { offer(.newTab, "Open a new browser tab") }
                let navURL = CuaActionCatalog.explicitBrowserNavigationURL(in: goal)
                    ?? CuaActionCatalog.searchNavigationURL(in: goal, payload: textToInsert)
                if let navURL { offer(.navigate(navURL), "Navigate the tab to \(navURL)") }
                for ref in pageRefs.prefix(20) {
                    guard let refID = ref["ref"]?.string ?? ref["id"]?.string else { continue }
                    let label = ref["label"]?.string ?? ref["text"]?.string ?? ""
                    offer(.browserClick(ref: refID), "Click page element \"\(label)\"")
                    if offersInsertion {
                        offer(.browserType(ref: refID), "Type the supplied text into page field \"\(label)\"")
                    }
                }
            }
            if generate != nil, textToInsert == nil, generatedText == nil, contentMode != .control {
                offer(.draftText, "Draft the requested text with the generator, then review it")
            }
            offer(.done, "The request is fully satisfied by the observed state")
            offer(.stuck, "The request cannot be completed from here; stop honestly")

            // ── One model call: action + done-evidence rides along.
            let mergedState: [String: JSONValue] = [
                "request": .string(goal), "previous_context": .string(context),
                "app": .string(name), "window_title": .string(windowTitle),
                "selected_window_id": .number(Double(wid)),
                "scope": .string(scope),
                "window_produced_by_task": .bool(!baselineWindowIDs.contains(wid)),
                "supplied_text": .string(textToInsert ?? generatedText ?? ""),
                "verified_facts": .array(observedPostconditions.map { .string($0.evidence) }),
                "elements": .array(elements.prefix(80).map(Self.compactElement)),
                "tabs": .array(tabs.map(CuaBrowserTarget.compactTab)),
                "browser_page": browserPage,
                "history": .array(history.suffix(10))]
            let questions: [String: Question] = [
                "next": .choice(
                    instructions: "Choose the single next action for this step. Pick done only when the observed state alone proves the exact request is satisfied — an identical pre-existing window, tab, or document does not count as this task's work. Pick stuck only when no action can progress. Element indices refer to the elements list; never invent one.",
                    criteria: criteria),
                "doneEvidence": .choice(
                    instructions: "Answered only when `next` is done: does the observed state (element values, tab urls/titles, window state, verified_facts) prove the exact requested outcome? History proves steps ran, never that the request succeeded.",
                    criteria: ["proven": "Readable evidence shows the exact requested outcome.",
                               "unproven": "Nothing readable proves it, or the state contradicts it."])]
            let answers = try await judge(.object(mergedState), questions)
            let nextID = try JevSelection.read(answers["next"], allowed: Set(criteria.keys))
            guard let lane = lanes[nextID] else {
                throw DriverConnectionError.refused("The model picked an action outside the observed set. Nothing was dispatched.")
            }

            // ── done: gate on observed evidence, not on the claim.
            if case .done = lane {
                let evidence = (try? JevSelection.read(answers["doneEvidence"], allowed: ["proven", "unproven"])) == "proven"
                let createVetoed = scope == "create" && baselineWindowIDs.contains(wid)
                if createVetoed || !evidence {
                    unprovenDone += 1
                    guard unprovenDone < Self.maximumUnprovenDone else {
                        throw DriverConnectionError.refused(createVetoed
                            ? "A new document window was requested, but the task could not be completed: \(name)'s observed state never produced one. Nothing is claimed as success."
                            : "The request's outcome could not be proven from \(name)'s observed state. Completed steps are not claimed as success; inspect the app before retrying.")
                    }
                    history.append(.object(["observation": .string(
                        "The completion claim was rejected: its evidence is not observable yet. Continuing.")]))
                    continue
                }
                recordPostcondition(.resultObserved, "Observed the requested outcome in \(name).",
                                    appName: name, bundleID: bundle, processID: pid, windowID: windowID)
                return "Completed in \(name); the requested outcome is visible in the app."
            }
            if case .stuck = lane {
                throw DriverConnectionError.refused("The task could not be completed from \(name)'s current state. Nothing further was dispatched.")
            }

            // ── Dispatch. Consequential descriptions ask the user once — the
            // vocabulary boundary carries the safety, not a per-action judge.
            let description = criteria[lane.id].flatMap { $0 } ?? lane.id
            if CuaTaskAgent.requiresRiskJudgment(goal: goal, actionDescription: description) {
                guard let approve, try await approve("\(name)\n\(description)") else {
                    throw DriverConnectionError.refused("The operation or its authorization is unclear: \(description). Nothing was dispatched.")
                }
            }
            var dispatchText = textToInsert ?? generatedText
            if dispatchText == nil, laneNeedsText(lane), let payload {
                dispatchText = CuaTaskAgent.stripLiteralIntroducer(
                    CuaTaskAgent.stripDestinationTail(try await payload(goal, context), appName: name))
                textToInsert = dispatchText
            }
            // A transient driver fault is an observation, not a verdict: the
            // next observe→decide pass re-reads real state and chooses again —
            // never a blind replay of a mutation that may have landed.
            // Consecutive faults still bound out honestly.
            let result: JSONValue
            do {
                result = try await dispatch(lane, pid: pid, wid: wid, goal: goal,
                                            text: dispatchText,
                                            browserTarget: browserTarget, shownTab: browserShownTab,
                                            tabs: tabs, tabsBaseline: &tabsBaseline,
                                            newTabRequested: &newTabRequested)
                dispatchFailures = 0
            } catch let error as DriverConnectionError {
                // `.refused` is a semantic guard (stale pin, missing payload,
                // ambiguous target) — it aborts. Transport faults re-observe.
                if case .refused = error { throw error }
                if case .toolRefused(_, let code) = error,
                   code == "same_pid_keyboard_ambiguity", lane.usesWindowInput {
                    // Not a fault — the driver observed that app-level input
                    // can't reach this window. The lanes retire; the next
                    // pass offers only what can still act.
                    windowInputAmbiguous = true
                    history.append(.object(["action": .string(description),
                                            "observation": .string("App-level input cannot target this window; only element-scoped actions remain available.")]))
                    continue
                }
                dispatchFailures += 1
                history.append(.object(["action": .string(description),
                                        "observation": .string("Dispatch failed: \(error.localizedDescription). The effect may not have happened — re-check before acting.")]))
                if dispatchFailures >= Self.maximumDispatchFailures { throw error }
                continue
            }
            mutatedContent = mutatedContent || laneMutates(lane)
            // The payload is spent on dispatch — leaving it offered invites
            // duplicate insertion. The next observation proves where it landed.
            if case .typeIntoElement(_, let index) = lane {
                pendingInsertProof = (index, dispatchText ?? "")
                textToInsert = nil; generatedText = nil; insertImplied = false
            }
            if case .typeIntoWindow = lane {
                pendingInsertProof = (nil, dispatchText ?? "")
                textToInsert = nil; generatedText = nil; insertImplied = false
            }
            if case .browserType = lane { textToInsert = nil; generatedText = nil; insertImplied = false }
            history.append(.object(["action": .string(description),
                                    "observation": .string(Self.outcomeSummary(result))]))
            // A produced window outranks a baseline pin for create-scope
            // work: when exactly one new onscreen window appears after a
            // mutation, repin to it. Two or more means ambiguity — keep the
            // pin rather than guessing.
            if laneMutates(lane), scope == "create", baselineWindowIDs.contains(wid),
               let listing = try? await call("list_windows", ["pid": .number(Double(pid))]) {
                let produced = (listing["windows"]?.array ?? []).filter {
                    $0["is_on_screen"] != .bool(false)
                        && !baselineWindowIDs.contains($0["window_id"]?.integer ?? -1) }
                if produced.count == 1, let newID = produced[0]["window_id"]?.integer {
                    windowID = newID
                    currentWindowID = newID
                    wid = newID
                }
            }
        }
        throw DriverConnectionError.refused("The task exceeded \(Self.maximumSteps) steps without reaching a proven outcome. Nothing further was dispatched.")
    }

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
        var appName = ""
        var bundleID = ""
        var ledger: [String] = []
        func finish(_ status: DriveStatus) -> DriveResult {
            DriveResult(status: status, history: ledger, pid: pid, windowID: windowID)
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
                pid = launched["pid"]?.integer
                appName = launched["name"]?.string ?? appName
                bundleID = launched["bundle_id"]?.string ?? bundleID
                if windowID == nil {
                    windowID = Self.preferredWindow(in: launched["windows"]?.array ?? [])
                }
                ledger.append("launched \(appName.isEmpty ? application : appName)")
                mutatedContent = true
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

        if windowID == nil,
           let listing = try? await call("list_windows", ["pid": .number(Double(resolvedPID))]) {
            windowID = Self.preferredWindow(in: listing["windows"]?.array ?? [])
        }
        currentWindowID = windowID

        let isBrowser = CuaTaskAgent.supportsIsolatedBrowser(bundleID)
        var browserTarget: JSONValue?
        var browserShownTab: String?
        var tabsBaseline: [String]?
        var newTabRequested = false
        var dispatchFailures = 0
        var windowInputAmbiguous = false
        var unprovenDone = 0
        var isolatedEscalated = false
        var bindingUpgradeTried = false
        /// After a text dispatch, the next observation proves it landed — an
        /// element value containing the text is recorded as a verified fact.
        var pendingInsertProof: (index: Int?, text: String)?
        /// Elements whose AX click reported suspected_noop / a pixel
        /// escalation — the next reads offer a pixel-click lane, resolved
        /// against that read's own frame and screenshot space.
        var pixelArmed: [Int: String] = [:]
        var modelHistory: [JSONValue] = []

        for _ in 0..<max(task.maxSteps, 1) {
            do { try Task.checkCancellation() } catch { return finish(.cancelled) }
            guard var wid = windowID else {
                return finish(.blocked("No usable window exists in \(appName). Nothing was dispatched."))
            }

            // ── Observe: window elements (+ browser page when bound). The
            // screenshot rides along only while pixel lanes need the image
            // coordinate space it defines.
            let snapshot = try await call("get_window_state", [
                "pid": .number(Double(resolvedPID)), "window_id": .number(Double(wid)),
                "include_screenshot": .bool(!pixelArmed.isEmpty), "max_elements": .number(200)])
            let elements = snapshot["elements"]?.array ?? []
            let windowTitle = snapshot["window"]?["title"]?.string
                ?? snapshot["title"]?.string ?? snapshot["window_title"]?.string ?? ""

            if let proof = pendingInsertProof, !proof.text.isEmpty {
                func reads(_ element: JSONValue) -> Bool {
                    element["value"]?.string?.contains(proof.text) == true
                        || element["label"]?.string?.contains(proof.text) == true
                }
                let target = proof.index.flatMap { i in
                    elements.first { $0["element_index"]?.integer == i } }
                let hit = target ?? elements.first(where: { reads($0) })
                if let hit, reads(hit) {
                    let label = hit["label"]?.string ?? hit["title"]?.string ?? "the field"
                    recordPostcondition(.resultObserved, "The inserted text is visible in \(label).",
                                        appName: appName, bundleID: bundleID,
                                        processID: resolvedPID, windowID: wid)
                    modelHistory.append(.object(["observation": .string(
                        "Verified: the inserted text now reads back from \(label).")]))
                    pendingInsertProof = nil
                }
            }

            var tabs: [JSONValue] = []
            var pageRefs: [JSONValue] = []
            var browserPage: JSONValue = .null
            if isBrowser {
                let page = try await boundBrowser(pid: &resolvedPID, wid: &wid,
                                                  target: &browserTarget, shownTab: &browserShownTab,
                                                  isolatedEscalated: &isolatedEscalated,
                                                  bindingUpgradeTried: &bindingUpgradeTried)
                windowID = wid
                pid = resolvedPID
                tabs = page.tabs; pageRefs = page.refs; browserPage = page.state
            }

            // ── Candidates: flat, from this observation only. deny[] pass 1:
            // a denied label never becomes an offered candidate.
            var lanes: [String: Lane] = [:]
            var criteria: [String: String?] = [:]
            var laneText: [String: String] = [:]
            func offer(_ lane: Lane, _ description: String, text: String? = nil) {
                lanes[lane.id] = lane; criteria[lane.id] = description
                if let text { laneText[lane.id] = text }
            }
            var elementByIndex: [Int: JSONValue] = [:]
            for element in elements {
                if let index = element["element_index"]?.integer { elementByIndex[index] = element }
            }
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(resolvedPID)
            var interactive = 0
            var elementCandidates = 0
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
                    offer(.typeIntoElement(token: token, index: index),
                          "Type the supplied text into \(role) \"\(label)\"", text: Self.elementText(element))
                    offer(.setValue(token: token, index: index),
                          "Set the value of \(role) \"\(label)\" to the supplied text", text: Self.elementText(element))
                } else if Self.menuRoles.contains(role), frontmost,
                          let path = Self.menuPath(for: index, in: elementByIndex),
                          path.allSatisfy({ !Self.isDenied($0, deny: task.deny) }) {
                    offer(.invokeMenu(path: path, index: index),
                          "Invoke the \"\(path.joined(separator: " → "))\" menu item", text: Self.elementText(element))
                } else {
                    offer(.clickElement(token: token, index: index),
                          "Click \(role) \"\(label)\"", text: Self.elementText(element))
                    if Self.valueRoles.contains(role) {
                        offer(.setValue(token: token, index: index),
                              "Set the value of \(role) \"\(label)\"", text: Self.elementText(element))
                    }
                }
            }
            // Pixel-click rungs armed by the driver's own escalation signal.
            for (index, armedLabel) in pixelArmed {
                guard let element = elementByIndex[index],
                      let point = Self.pixelPoint(of: element, in: snapshot) else { continue }
                let label = element["label"]?.string ?? element["title"]?.string ?? ""
                guard label == armedLabel, !Self.isDenied(label, deny: task.deny) else { continue }
                offer(.pixelClick(token: element["element_token"]?.string ?? String(index),
                                  index: index, x: point.x, y: point.y),
                      "Pixel-click \"\(label)\" at its observed center", text: Self.elementText(element))
            }
            if !windowInputAmbiguous {
                // Deny gates key names too — "delete" must not remain
                // reachable via the keyboard when the button is denied.
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
                if !windowInputAmbiguous, !Self.isDenied("new tab", deny: task.deny) { offer(.newTab, "Open a new browser tab") }
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

            // An empty or fully inert projection hands back for the
            // pixel/screenshot path rather than guessing at controls.
            if interactive == 0 && pageRefs.isEmpty {
                return finish(.handedBack(.noInteractiveElements))
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
            let mergedState: [String: JSONValue] = [
                "request": .string(task.goal),
                "app": .string(appName), "window_title": .string(windowTitle),
                "selected_window_id": .number(Double(wid)),
                "values_available": .array(task.values.keys.sorted().map { .string($0) }),
                "success_contains": .array(task.successContains.map { .string($0) }),
                "verified_facts": .array(observedPostconditions.map { .string($0.evidence) }),
                "elements": .array(elements.prefix(80).map { Self.compactElement($0, deny: task.deny) }),
                "tabs": .array(tabs.map(CuaBrowserTarget.compactTab)),
                "browser_page": browserPage,
                "history": .array(modelHistory.suffix(10))]
            let questions: [String: Question] = [
                "next": .choice(
                    instructions: "Choose the single next action for this step. Pick done only when the observed state alone proves the exact request is satisfied. Pick stuck only when no action can progress. Action ids refer to the offered list; never invent one.",
                    criteria: criteria),
                "fill": .choice(
                    instructions: "Answered only when `next` types or sets a field: which supplied value belongs in that field? Pick the matching value key, or unavailable when the field needs text the caller did not supply.",
                    criteria: fillChoices),
                "doneEvidence": .choice(
                    instructions: "Answered only when `next` is done: does the observed state (element values, tab urls/titles, window state, verified_facts, success_contains) prove the exact requested outcome? History proves steps ran, never that the request succeeded.",
                    criteria: ["proven": "Readable evidence shows the exact requested outcome.",
                               "unproven": "Nothing readable proves it, or the state contradicts it."]),
                "blockedReason": .choice(
                    instructions: "Answered only when `next` is stuck: what stops progress?",
                    criteria: blockedChoices)]
            let answers = try await judge(.object(mergedState), questions)
            let nextID: String
            do {
                nextID = try JevSelection.read(answers["next"], allowed: Set(criteria.keys))
            } catch {
                return finish(.handedBack(.untrustedAnswer))
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
                return finish(.handedBack(.lowConfidence))
            }

            // ── done: gate on observed evidence, not on the claim.
            if judgment.done {
                let evidence = (try? JevSelection.read(answers["doneEvidence"], allowed: ["proven", "unproven"])) == "proven"
                let corpus = Self.observedCorpus(elements: elements, title: windowTitle,
                                                 tabs: tabs, facts: observedPostconditions)
                let postUnmet = !task.successContains.isEmpty
                    && !task.successContains.contains { corpus.contains($0.lowercased()) }
                if !evidence || postUnmet {
                    unprovenDone += 1
                    guard unprovenDone < Self.maximumUnprovenDone else {
                        return finish(.blocked("The request's outcome could not be proven from \(appName)'s observed state. Completed steps are not claimed as success; inspect the app before retrying."))
                    }
                    modelHistory.append(.object(["observation": .string(
                        "The completion claim was rejected: its evidence is not observable yet. Continuing.")]))
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

            // ── Dispatch. A transient driver fault is an observation, not a
            // verdict: the next observe→decide pass re-reads real state and
            // chooses again — never a blind replay of a mutation that may
            // have landed. Consecutive faults still bound out honestly.
            let description = criteria[lane.id].flatMap { $0 } ?? lane.id
            let result: JSONValue
            do {
                result = try await dispatch(lane, pid: resolvedPID, wid: wid, goal: task.goal,
                                            text: dispatchText,
                                            browserTarget: browserTarget, shownTab: browserShownTab,
                                            tabs: tabs, tabsBaseline: &tabsBaseline,
                                            newTabRequested: &newTabRequested)
                dispatchFailures = 0
            } catch let error as DriverConnectionError {
                if case .toolRefused(_, let code) = error, code.contains("consent") {
                    return finish(.blockedByConsent(code))
                }
                if case .refused(let message) = error {
                    return finish(.blocked(message))
                }
                if case .toolRefused(_, let code) = error,
                   code == "same_pid_keyboard_ambiguity", lane.usesWindowInput {
                    windowInputAmbiguous = true
                    modelHistory.append(.object(["action": .string(description),
                        "observation": .string("App-level input cannot target this window; only element-scoped actions remain available.")]))
                    continue
                }
                dispatchFailures += 1
                modelHistory.append(.object(["action": .string(description),
                    "observation": .string("Dispatch failed: \(error.localizedDescription). The effect may not have happened — re-check before acting.")]))
                ledger.append("\(description) — dispatch failed: \(error.localizedDescription)")
                guard dispatchFailures < Self.maximumDispatchFailures else {
                    return finish(.blocked(error.localizedDescription))
                }
                continue
            } catch let outcome as CuaUncertainOutcome {
                return finish(.blocked("\(outcome.localizedDescription) Inspect \(appName) before retrying."))
            }
            mutatedContent = mutatedContent || laneMutates(lane)
            if case .typeIntoElement(_, let index) = lane {
                pendingInsertProof = (index, dispatchText ?? "")
            }
            if case .setValue(_, let index) = lane {
                pendingInsertProof = (index, dispatchText ?? "")
            }
            if case .typeIntoWindow = lane { pendingInsertProof = (nil, dispatchText ?? "") }
            if case .browserType = lane { pendingInsertProof = (nil, dispatchText ?? "") }
            let outcome = Self.effectSummary(result)
            modelHistory.append(.object(["action": .string(description),
                                         "observation": .string(outcome)]))
            ledger.append("\(description) → \(outcome)")
            progress("\(description) → \(outcome)")
            // Driver honesty fields: a confirmed effect (or an explicit
            // verified readback) is proof; a suspected noop or a pixel
            // escalation arms the pixel rung for the next observation;
            // anything weaker is reported, never claimed.
            if Self.isProven(result) {
                recordPostcondition(.resultObserved, "Driver confirmed: \(description)",
                                    appName: appName, bundleID: bundleID,
                                    processID: resolvedPID, windowID: wid)
            }
            if let index = lane.elementIndex, Self.escalatesToPixel(result),
               let element = elementByIndex[index] {
                pixelArmed[index] = element["label"]?.string ?? element["title"]?.string ?? ""
            }
        }
        return finish(.maxSteps(history: ledger))
    }

    // MARK: - Drive-until helpers

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
                                       tabs: [JSONValue], facts: [CuaObservedPostcondition]) -> String {
        var parts = [title]
        for element in elements {
            for key in ["label", "title", "value", "description"] {
                if let text = element[key]?.string { parts.append(text) }
            }
        }
        for tab in tabs {
            for key in ["title", "url"] {
                if let text = tab[key]?.string { parts.append(text) }
            }
        }
        return parts.joined(separator: "\n").lowercased()
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
    /// requested effect — a suspected noop or an explicit pixel escalation.
    private static func escalatesToPixel(_ result: JSONValue) -> Bool {
        result["escalation"]?["target"]?.string == "pixel"
            || result["escalation"]?["recommended"]?.string == "pixel"
            || result["effect"]?.string == "suspected_noop"
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
                          tabsBaseline: inout [String]?, newTabRequested: inout Bool) async throws -> JSONValue {
        switch lane {
        case .clickElement(let token, _):
            return try await call("click", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                            "element_token": .string(token),
                                            "delivery_mode": .string("background")])
        case .typeIntoElement(let token, _):
            guard let text, !text.isEmpty else { throw DriverConnectionError.refused("There is no text to insert.") }
            return try await call("type_text", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                "element_token": .string(token), "text": .string(text),
                                                "delivery_mode": .string("background")])
        case .typeIntoWindow:
            guard let text, !text.isEmpty else { throw DriverConnectionError.refused("There is no text to insert.") }
            return try await call("type_text", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                "text": .string(text),
                                                "delivery_mode": .string("background")])
        case .setValue(let token, _):
            guard let text, !text.isEmpty else { throw DriverConnectionError.refused("There is no value to set.") }
            return try await call("set_value", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                "element_token": .string(token), "value": .string(text)])
        case .pixelClick(_, _, let x, let y):
            return try await call("click", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                            "x": .number(x), "y": .number(y),
                                            "delivery_mode": .string("background")])
        case .invokeMenu(let path, _):
            return try await call("invoke_menu", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                  "path": .array(path.map { .string($0) })])
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
            return try await call("launch_app", args)
        case .pressKey(let key):
            return try await call("press_key", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                "key": .string(key),
                                                "delivery_mode": .string("background")])
        case .hotkey(let keys):
            return try await call("hotkey", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                             "keys": .array(keys.map { .string($0) }),
                                             "delivery_mode": .string("background")])
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
                                             "delivery_mode": .string("background")])
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
            let needle = url.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            for _ in 0..<Self.navigationPolls {
                if let after = try? await observeBrowser(pid: pid, wid: wid,
                                                         target: target, tab: tabID),
                   let pageURL = after["page"]?["url"]?.string,
                   pageURL.localizedCaseInsensitiveContains(needle) {
                    return outcome
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw CuaUncertainOutcome(tool: "browser_navigate", result: outcome)
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
        case .draftText:
            guard let generate else { throw DriverConnectionError.refused("Text generation is unavailable.") }
            generatedText = try await generate("Write the text the request asks for, ready to paste: \(goal)", "", false)
            return .object(["status": .string("drafted")])
        case .done, .stuck:
            return .null  // handled before dispatch
        }
    }

    private func laneNeedsText(_ lane: Lane) -> Bool {
        lane.needsFillText
    }

    private func laneMutates(_ lane: Lane) -> Bool {
        switch lane {
        case .done, .stuck, .draftText: return false
        default: return true
        }
    }

    // MARK: - Observation shaping

    private static func compactElement(_ element: JSONValue) -> JSONValue {
        .object([
            "i": element["element_index"] ?? .null,
            "role": element["role"] ?? .null,
            "label": element["label"] ?? element["title"] ?? .null,
            "value": (element["value"]?.string).map { .string(String($0.prefix(80))) } ?? .null])
    }

    private static func outcomeSummary(_ result: JSONValue) -> String {
        if let summary = result["summary"]?.string { return String(summary.prefix(80)) }
        if let status = result["status"]?.string { return status }
        return "ok"
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
    /// call reads the page. A requires_setup refusal escalates once to an
    /// approved isolated profile (moving the whole task to the prepared
    /// pid+window); a failed plain read gets one existing-profile prepare —
    /// the same call that upgrades a weak binding for mutation. Every other
    /// browser failure degrades to the keyboard lanes.
    private func boundBrowser(pid: inout Int, wid: inout Int,
                              target: inout JSONValue?, shownTab: inout String?,
                              isolatedEscalated: inout Bool,
                              bindingUpgradeTried: inout Bool) async throws
        -> (tabs: [JSONValue], refs: [JSONValue], state: JSONValue) {
        var browserState: JSONValue?
        do {
            browserState = try await observeBrowser(pid: pid, wid: wid, target: target, tab: shownTab)
        } catch let refusal as DriverConnectionError {
            if case .toolRefused(_, let code) = refusal,
               code == "browser_requires_setup",
               !isolatedEscalated, let escalateBrowser {
                isolatedEscalated = true
                let prepared = try await escalateBrowser()
                pid = prepared.pid
                wid = prepared.windowID
                currentWindowID = prepared.windowID
                browserState = try? await observeBrowser(pid: pid, wid: wid, target: nil, tab: nil)
            } else {
                browserState = nil
            }
        } catch {
            browserState = nil
        }
        if browserState == nil, !browserPreparedExternally, !bindingUpgradeTried {
            bindingUpgradeTried = true
            _ = try? await call("browser_prepare", [
                "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                "strategy": .object(["kind": .string("existing_profile")])])
            browserState = try? await observeBrowser(pid: pid, wid: wid, target: nil, tab: nil)
        }
        guard let browserState else { return ([], [], .null) }
        let tabs = CuaBrowserTarget.tabs(browserState)
        target = CuaBrowserTarget.targetID(browserState) ?? target
        shownTab = CuaBrowserTarget.shownTab(in: browserState, tabs: tabs, fallback: shownTab)
        return (tabs, CuaBrowserTarget.pageRefs(browserState), browserState)
    }
}
