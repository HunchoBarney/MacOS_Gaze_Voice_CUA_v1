import Foundation
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
                // `get_browser_state` binds a window's tab directly; when a
                // target+tab are already known the same call reads the page.
                // A requires_setup refusal escalates once to an approved
                // isolated profile and the loop continues there.
                var browserState: JSONValue?
                do {
                    browserState = try await observeBrowser(pid: pid, wid: wid,
                                                            target: browserTarget, tab: browserShownTab)
                } catch let refusal as DriverConnectionError {
                    // Only an automation-refused binding escalates; every
                    // other browser failure degrades to the keyboard lanes.
                    if case .toolRefused(_, let code) = refusal,
                       code == "browser_requires_setup",
                       !isolatedEscalated, let escalateBrowser {
                        isolatedEscalated = true
                        let prepared = try await escalateBrowser()
                        pid = prepared.pid
                        windowID = prepared.windowID
                        currentWindowID = prepared.windowID
                        wid = prepared.windowID
                        browserState = try? await observeBrowser(pid: pid, wid: wid,
                                                                 target: nil, tab: nil)
                    } else {
                        browserState = nil
                    }
                } catch {
                    browserState = nil
                }
                if browserState == nil, !browserPreparedExternally, !bindingUpgradeTried {
                    // A failed plain read gets one existing-profile prepare —
                    // the same call that upgrades a weak binding for mutation.
                    bindingUpgradeTried = true
                    _ = try? await call("browser_prepare", [
                        "pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                        "strategy": .object(["kind": .string("existing_profile")])])
                    browserState = try? await observeBrowser(pid: pid, wid: wid,
                                                             target: nil, tab: nil)
                }
                if let browserState {
                    tabs = browserState["tabs"]?.array ?? tabs
                    browserPage = browserState
                    pageRefs = browserState["page"]?["refs"]?.array ?? browserState["refs"]?.array ?? []
                    browserTarget = browserState["target_id"] ?? browserTarget
                    // The shown tab is the read's own `tab_id`, else the
                    // uniquely-active or single tab in the list.
                    browserShownTab = browserState["tab_id"]?.string
                        ?? tabs.first(where: { $0["active"] == .bool(true) })?["tab_id"]?.string
                        ?? (tabs.count == 1 ? tabs[0]["tab_id"]?.string : browserShownTab)
                }
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
                "tabs": .array(tabs.map { Self.compactTab($0) }),
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

    // MARK: - Dispatch

    private func dispatch(_ lane: Lane, pid: Int, wid: Int, goal: String,
                          text: String?, browserTarget: JSONValue?, shownTab: String?,
                          tabs: [JSONValue],
                          tabsBaseline: inout [String]?, newTabRequested: inout Bool) async throws -> JSONValue {
        switch lane {
        case .clickElement(let token, _):
            return try await call("click", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                            "element_token": .string(token)])
        case .typeIntoElement(let token, _):
            guard let text, !text.isEmpty else { throw DriverConnectionError.refused("There is no text to insert.") }
            return try await call("type_text", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                "element_token": .string(token), "text": .string(text)])
        case .typeIntoWindow:
            guard let text, !text.isEmpty else { throw DriverConnectionError.refused("There is no text to insert.") }
            return try await call("type_text", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                "text": .string(text)])
        case .pressKey(let key):
            return try await call("press_key", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                                "key": .string(key)])
        case .hotkey(let keys):
            return try await call("hotkey", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                             "keys": .array(keys.map { .string($0) })])
        case .scroll(let direction):
            return try await call("scroll", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                             "direction": .string(direction), "by": .string("page"), "amount": .number(1)])
        case .newTab:
            if tabsBaseline == nil,
               let state = try? await call("get_browser_state", [
                   "pid": .number(Double(pid)), "window_id": .number(Double(wid))]) {
                tabsBaseline = (state["tabs"]?.array ?? []).map(Self.tabSignature)
            }
            newTabRequested = true
            return try await call("hotkey", ["pid": .number(Double(pid)), "window_id": .number(Double(wid)),
                                             "keys": .array([.string("cmd"), .string("t")])])
        case .navigate(let url):
            guard let target = browserTarget else {
                throw DriverConnectionError.refused("This window is not bound to the browser route; DOM navigation is unavailable.")
            }
            guard let tab = resolveNavigationTab(tabs: tabs, baseline: tabsBaseline, newTabRequested: newTabRequested),
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
        switch lane {
        case .typeIntoElement, .typeIntoWindow, .browserType: return true
        default: return false
        }
    }

    private func laneMutates(_ lane: Lane) -> Bool {
        switch lane {
        case .done, .stuck, .draftText: return false
        default: return true
        }
    }

    /// Tab-resolution for browser_navigate: the fresh tab the task opened
    /// (unique blank signature gained over the baseline), else the single or
    /// uniquely-active tab. Anything ambiguous is nil — the caller refuses.
    private func resolveNavigationTab(tabs: [JSONValue],
                                      baseline: [String]?, newTabRequested: Bool) -> JSONValue? {
        if newTabRequested, let baseline {
            let (added, removed) = Self.tabSignatureDelta(from: baseline, to: tabs.map(Self.tabSignature))
            if removed.isEmpty, added.count == 1, let sig = added.first,
               Self.isBlankTabURL(Self.tabSignatureURL(sig)) {
                return tabs.first { Self.tabSignature($0) == sig }
            }
            return nil
        }
        let active = tabs.filter { $0["active"] == .bool(true) }
        let candidates = tabs.count == 1 ? tabs : active
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: - Observation shaping

    private static func compactElement(_ element: JSONValue) -> JSONValue {
        .object([
            "i": element["element_index"] ?? .null,
            "role": element["role"] ?? .null,
            "label": element["label"] ?? element["title"] ?? .null,
            "value": (element["value"]?.string).map { .string(String($0.prefix(80))) } ?? .null])
    }

    private static func compactTab(_ tab: JSONValue) -> JSONValue {
        .object(["title": tab["title"] ?? .null, "url": tab["url"] ?? .null,
                 "active": tab["active"] ?? .null])
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

    // MARK: - Tab signatures (multiset, order-free)

    nonisolated static func tabSignature(_ tab: JSONValue) -> String {
        "\(tab["url"]?.string ?? "")\u{1F}\(tab["title"]?.string ?? "")"
    }

    nonisolated static func tabSignatureURL(_ signature: String) -> String {
        String(signature.split(separator: "\u{1F}").first ?? "")
    }

    nonisolated static func tabSignatureDelta(from old: [String], to new: [String]) -> (added: [String], removed: [String]) {
        var remaining = old
        var added: [String] = []
        for sig in new {
            if let i = remaining.firstIndex(of: sig) { remaining.remove(at: i) }
            else { added.append(sig) }
        }
        return (added, remaining)
    }

    nonisolated static func isBlankTabURL(_ url: String) -> Bool {
        let u = url.lowercased()
        return u == "about:blank" || u.contains("://newtab") || u == "about:newtab"
            || u.hasPrefix("chrome-search://local-ntp")
    }
}
