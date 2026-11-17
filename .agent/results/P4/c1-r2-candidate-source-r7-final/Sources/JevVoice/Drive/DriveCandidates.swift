import CoreGraphics
import Foundation
import JevVoiceCore

/// The one home of the Jev pick space — the role vocabularies, the
/// goal-word scorer, and the observation→candidate build shared by the
/// `JevDecider` (the contract loop's brain) and `DriveLoop.preview`.
/// Candidate ids, descriptions, and addressing match the hand-rolled
/// loop's exactly: `element_token` preferred, else `element_index`
/// bound to the snapshot's own id; pid/window_id/session are loop
/// authority and are stamped at dispatch, never minted here.
enum DriveCandidates {

    static let editableRoles = ["textfield", "textarea", "text", "searchfield",
                                "combo box", "combobox", "securetextfield"]
    static let clickableRoles = ["button", "link", "menuitem", "menu item", "tab",
                                 "checkbox", "radio", "row", "cell", "pop up",
                                 "popupbutton", "switch", "list"]

    /// One pick target — the description the model reads plus the
    /// request the loop would run. `kind` keeps the reserved picks
    /// (done/stuck) out of the request shape entirely; `element`
    /// carries the identity the stale-token relocate and the gaze
    /// annotation read.
    struct Draft: Sendable {
        enum Kind: Sendable {
            case request(ActuationRequest)
            case done
            case abstain
        }
        enum TargetScope: Sendable {
            case window
        }
        var id: String
        var description: String
        var needsText = false
        var kind: Kind
        var element: DriveLoop.Element? = nil
        var targetScope: TargetScope? = nil
    }

    /// Per-round extras — candidates the snapshot can't mint (traffic
    /// lights, page refs, tabs) plus the state fields only the bound
    /// lane knows (page_url).
    struct RoundExtras: Sendable {
        var candidates: [Draft] = []
        var stateFields: [String: JSONValue] = [:]
    }

    static func isWindowLocal(_ request: ActuationRequest) -> Bool {
        if request.effect == .reobserve || request.effect == .verifyState { return true }
        return ["click", "double_click", "type_text", "set_value", "press_key", "hotkey",
                "scroll", "invoke_menu", "browser_navigate", "browser_click", "browser_type",
                "switch_tab", "window_control"].contains(request.tool)
    }

    static func isSecure(role: String, label: String) -> Bool {
        if role.lowercased().contains("secure") { return true }
        let normalized = role.lowercased().replacingOccurrences(of: "ax", with: "")
        if ["statictext", "heading", "paragraph", "label"].contains(normalized) { return false }
        let text = (role + " " + label).lowercased()
        return text.contains("secure") || text.contains("password")
    }

    static func literalText(values: [String: String], label: String?) -> String? {
        if let label,
           let hit = values.first(where: { $0.key.lowercased() == label.lowercased() })?.value {
            return hit
        }
        return values["text"]
    }

    /// The judgment model's context is small: shipping every element on a
    /// large window overflows it (browsers blow past the cap on any real
    /// page). Always keep the elements that produced candidates, fill the
    /// rest with the most goal-relevant rows in document order, and state
    /// the truncation so the model knows content exists beyond the listing.
    static let observedContentLimit = 140

    static func observationFields(elements: [DriveLoop.Element], candidates: [Draft],
                                  goal: String, values: [String: String]) -> [String: JSONValue] {
        let visible = elements.filter { !isSecure(role: $0.role, label: $0.label) }
        var shown = visible
        var omitted = 0
        if visible.count > observedContentLimit {
            let goalWords = Set(goal.lowercased().split(whereSeparator: {
                !$0.isLetter && !$0.isNumber
            }).map(String.init))
            var keep = Set(candidates.compactMap { $0.element?.index })
            for entry in visible.enumerated().sorted(by: {
                let left = score($0.element, goalWords: goalWords)
                let right = score($1.element, goalWords: goalWords)
                return left == right ? $0.offset < $1.offset : left > right
            }) where keep.count < observedContentLimit {
                keep.insert(entry.element.index)
            }
            shown = visible.filter { keep.contains($0.index) }
            omitted = visible.count - shown.count
        }
        var observedLines = [
            "Element rows from this window's accessibility tree — a row can name "
                + "content scrolled out of view; only the picture shows what is rendered."
        ]
        observedLines += shown.map {
            $0.label + ($0.value.map { ": " + $0 } ?? "")
        }
        if omitted > 0 {
            observedLines.append("… \(omitted) more element rows not listed")
        }
        var fields: [String: JSONValue] = [
            "current_instruction": .string(goal),
            "observed_content": .string(observedLines.joined(separator: "\n")),
            "supplied_field_labels": .array(values.keys.sorted().map(JSONValue.string)),
        ]
        let screenValues = shown.compactMap { element in
            element.value.map { "\(element.label)=\($0)" }
        }
        if !screenValues.isEmpty {
            fields["screen_values"] = .string(screenValues.joined(separator: ", "))
        }
        var candidateDetails: [String: JSONValue] = [:]
        for candidate in candidates {
            var details: [String: JSONValue] = ["bounds": .null]
            if case .request(let request) = candidate.kind {
                details["tool"] = .string(request.tool)
                if case .window? = candidate.targetScope {
                    details["arguments"] = .object(request.args)
                    details["target_scope"] = .object(["kind": .string("window")])
                }
                if candidate.needsText {
                    let literal = literalText(values: values,
                                              label: candidate.element?.label ?? request.elementText)
                    details["literal_available"] = .bool(literal != nil)
                    if let element = candidate.element, let current = element.value, let literal,
                       !isSecure(role: element.role, label: element.label) {
                        details["literal_matches_current_value"] = .bool(current == literal)
                    }
                }
            }
            if let element = candidate.element {
                details["element_index"] = .number(Double(element.index))
                details["label"] = .string(element.label)
                details["role"] = .string(element.role)
                details["actions"] = .array(element.actions.map(JSONValue.string))
                if DriveLoop.nativeAXScreenRect(element) != nil {
                    details["bounds"] = .object([
                        "x": .number(element.frame.x), "y": .number(element.frame.y),
                        "width": .number(element.frame.w), "height": .number(element.frame.h),
                    ])
                }
                if let value = element.value, !isSecure(role: element.role, label: element.label) {
                    details["value"] = .string(value)
                }
            }
            candidateDetails[candidate.id] = .object(details)
        }
        fields["_candidate_details"] = .object(candidateDetails)
        return fields
    }

    // MARK: - Scoring

    static func role(_ e: DriveLoop.Element) -> String {
        e.role.lowercased().replacingOccurrences(of: "ax", with: "")
    }

    static func score(_ e: DriveLoop.Element, goalWords: Set<String>) -> Int {
        var s = 0
        for w in Set(e.label.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        where goalWords.contains(String(w)) { s += 3 }
        if e.actions.isEmpty { s -= 1 }
        if e.frame.h <= 1 { s -= 2 }
        return s
    }

    /// Interactive-or-editable rows scored by goal-word overlap, capped —
    /// the selection both lanes ordered candidates by.
    static func actionable(_ elements: [DriveLoop.Element], goal: String,
                           cap: Int?) -> [DriveLoop.Element] {
        let goalWords = Set(goal.lowercased().split(whereSeparator: {
            !$0.isLetter && !$0.isNumber
        }).map(String.init))
        let ordered = elements.filter {
            guard $0.index >= 0 else { return false }
            let r = role($0)
            return !$0.actions.isEmpty
                || editableRoles.contains(r)
                || clickableRoles.contains(where: r.contains)
        }.enumerated().sorted {
            let left = score($0.element, goalWords: goalWords)
            let right = score($1.element, goalWords: goalWords)
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
        return cap.map { Array(ordered.prefix(max(0, $0))) } ?? ordered
    }

    // MARK: - Element addressing + identity

    /// Element args: token preferred, else index bound to THIS
    /// snapshot's id — position never stands alone. `background` stated
    /// explicitly so a future driver-side default change can't silently
    /// steal focus. `_element` carries the row's identity so the
    /// actuator's stale-token relocate can re-find it; the actuator
    /// strips the key before the driver sees it. pid/window_id/session
    /// are loop authority — absent here on purpose.
    static func baseArgs(_ e: DriveLoop.Element,
                         snapshotID: String?) -> [String: JSONValue] {
        var a: [String: JSONValue] = ["delivery_mode": .string("background"),
                                    "_element": elementJSON(e)]
        if let token = e.token { a["element_token"] = .string(token) }
        else {
            a["element_index"] = .number(Double(e.index))
            if let snapshotID { a["snapshot_id"] = .string(snapshotID) }
        }
        return a
    }

    /// The row's identity, serialized — role+label+value+frame are what
    /// `DriveLoop.relocate` matches on a fresh snapshot.
    static func elementJSON(_ e: DriveLoop.Element) -> JSONValue {
        var o: [String: JSONValue] = [
            "element_index": .number(Double(e.index)),
            "role": .string(e.role), "label": .string(e.label),
            "frame": .object(["x": .number(e.frame.x), "y": .number(e.frame.y),
                              "w": .number(e.frame.w), "h": .number(e.frame.h)])]
        if let token = e.token { o["element_token"] = .string(token) }
        if let value = e.value { o["value"] = .string(value) }
        return .object(o)
    }

    static func element(fromJSON json: JSONValue) -> DriveLoop.Element? {
        guard let index = json["element_index"]?.integer else { return nil }
        let f = json["frame"]
        return DriveLoop.Element(
            index: index, token: json["element_token"]?.string,
            role: json["role"]?.string ?? "", label: json["label"]?.string ?? "",
            value: json["value"]?.string,
            frame: (x: f?["x"]?.numberValue ?? 0, y: f?["y"]?.numberValue ?? 0,
                    w: f?["w"]?.numberValue ?? 0, h: f?["h"]?.numberValue ?? 0),
            actions: [])
    }

    // MARK: - Snapshot conversion

    /// get_window_state JSON → the contract's AXSnapshot — the same
    /// element rows `DriveLoop.elements(from:)` decodes.
    static func axSnapshot(from snap: JSONValue) throws -> AXSnapshot {
        let body = snap["structuredContent"] ?? snap
        let rows = body["elements"]?.array ?? []
        let roots = rows.filter {
            ["AXWindow", "AXSheet"].contains($0["role"]?.string ?? "")
                && $0["parent_index"] == nil
        }
        let hasMenus = rows.contains { ($0["role"]?.string ?? "").hasPrefix("AXMenu") }
        var scoped = body.object ?? [:]
        if !roots.isEmpty || hasMenus {
            guard roots.count == 1, let root = roots[0]["element_index"]?.integer else {
                throw DriverConnectionError.malformed
            }
            let children = Dictionary(grouping: rows, by: { $0["parent_index"]?.integer })
            var pending = [root], allowed: Set<Int> = []
            while let index = pending.popLast() {
                guard allowed.insert(index).inserted else { continue }
                pending += (children[index] ?? []).compactMap { $0["element_index"]?.integer }
            }
            scoped["elements"] = .array(rows.filter {
                $0["element_index"]?.integer.map(allowed.contains) ?? false
            })
            scoped["tree_markdown"] = .string(
                scopedTreeMarkdown(body["tree_markdown"]?.string ?? "", allowed: allowed))
        }
        return AXSnapshot(windowTitle: snap["window_title"]?.string
                        ?? snap["structuredContent"]?["window_title"]?.string,
                   snapshotID: snap["snapshot_id"]?.string
                        ?? snap["structuredContent"]?["snapshot_id"]?.string,
                   elements: DriveLoop.elements(from: .object(scoped)).map(driveToAX(_:)),
                   treeMarkdown: scoped["tree_markdown"]?.string ?? "")
    }

    /// Window-scoped markdown: keep the rows whose element index survives
    /// scope filtering so `id=` tokens (toolbar/status state) stay
    /// available to fact extraction instead of blanking the whole tree.
    static func scopedTreeMarkdown(_ markdown: String, allowed: Set<Int>) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            guard let open = line.range(of: "- ["),
                  let close = line[open.upperBound...].firstIndex(of: "]"),
                  let index = Int(line[open.upperBound..<close]) else { return false }
            return allowed.contains(index)
        }.joined(separator: "\n")
    }

    static func driveToAX(_ e: DriveLoop.Element) -> AXElement {
        AXElement(index: e.index, token: e.token, role: e.role, label: e.label,
                  value: e.value,
                  frame: CGRect(x: e.frame.x, y: e.frame.y,
                                width: e.frame.w, height: e.frame.h),
                  actions: e.actions)
    }

    static func axToDrive(_ e: AXElement) -> DriveLoop.Element {
        DriveLoop.Element(index: e.index, token: e.token, role: e.role,
                          label: e.label, value: e.value,
                          frame: e.frame.map {
                              (x: $0.origin.x, y: $0.origin.y,
                               w: $0.size.width, h: $0.size.height)
                          } ?? (x: 0, y: 0, w: 0, h: 0),
                          actions: e.actions)
    }

    // MARK: - The deterministic candidate set

    /// Every candidate derivable from the snapshot and the task's own
    /// words — element rows, the reserved picks, bare keys, scrolls,
    /// media keys, the clipboard read, and the navigate offer — in the
    /// exact order the hand-rolled loop offered them.
    static func drafts(elements: [DriveLoop.Element], snapshotID: String?,
                       windowTitle: String?, goal: String, cap: Int?,
                       url: String?) -> [Draft] {
        var out: [Draft] = []
        for e in actionable(elements, goal: goal, cap: cap) {
            let r = role(e)
            let name = e.label.isEmpty ? r : e.label
            let elementText = (e.label + " " + (e.value ?? ""))
                .trimmingCharacters(in: .whitespaces)
            if editableRoles.contains(r) {
                out.append(Draft(id: "t\(e.index)",
                    description: "insert supplied text at the caret in \"\(name)\" without clearing existing text",
                    needsText: true,
                    kind: .request(ActuationRequest(
                        effect: .tool, tool: "type_text",
                        args: baseArgs(e, snapshotID: snapshotID),
                        elementText: elementText,
                        summary: "type into \"\(name)\"")),
                    element: e))
                if e.value != "", !isSecure(role: e.role, label: e.label) {
                    var args = baseArgs(e, snapshotID: snapshotID)
                    args["delivery_mode"] = nil
                    out.append(Draft(id: "v\(e.index)",
                        description: "replace the entire native text value of \"\(name)\" with the supplied text",
                        needsText: true,
                        kind: .request(ActuationRequest(
                            effect: .tool, tool: "set_value", args: args,
                            elementText: elementText,
                            summary: "replace all text in \"\(name)\"")),
                        element: e))
                }
            }
            out.append(Draft(id: "e\(e.index)",
                description: "press \"\(name)\" (\(r))",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "click",
                    args: baseArgs(e, snapshotID: snapshotID),
                    elementText: elementText,
                    summary: "press \"\(name)\" (\(r))")),
                element: e))
            if e.actions.contains("AXOpen") {
                // An unlabeled openable row still carries its value —
                // name what opens, not a bare role.
                let oname = e.label.isEmpty ? (e.value ?? r) : e.label
                out.append(Draft(id: "o\(e.index)",
                    description: "open \"\(oname)\"",
                    kind: .request(ActuationRequest(
                        effect: .tool, tool: "double_click",
                        args: baseArgs(e, snapshotID: snapshotID),
                        elementText: elementText,
                        summary: "open \"\(oname)\"")),
                    element: e))
            }
        }

        // Reserved candidates — always present, same ids the picks have
        // always carried.
        out.append(Draft(id: "done", description: "the task is complete",
                         kind: .done))
        out.append(Draft(id: "reobserve",
                         description: "look again before acting",
                         kind: .request(ActuationRequest(
                            effect: .reobserve, tool: "",
                            summary: "look again before acting"))))
        out.append(Draft(id: "stuck", description: "no safe next step exists",
                         kind: .abstain))
        // Bare-key and scroll candidates carry the window title as their
        // deny-scan context — Return on a "Confirm purchase" dialog
        // refuses on the dialog's own words.
        for key in ["return", "escape", "tab"] {
            out.append(Draft(id: "key:\(key)", description: "press \(key)",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "press_key",
                    args: ["key": .string(key),
                           "delivery_mode": .string("background")],
                    elementText: windowTitle,
                    summary: "press \(key)")), targetScope: .window))
        }
        for dir in ["up", "down"] {
            out.append(Draft(id: "scroll:\(dir)", description: "scroll \(dir)",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "scroll",
                    args: ["direction": .string(dir),
                           "by": .string("page"), "amount": .number(1),
                           "delivery_mode": .string("background")],
                    elementText: windowTitle,
                    summary: "scroll \(dir)")), targetScope: .window))
        }
        // A `menu A > B > C` path in the goal mints one invoke_menu
        // candidate — the driver resolves each segment against the live
        // menubar and refuses what it cannot act on. The path text rides
        // elementText so the deny scan sees the command itself.
        for path in Self.menuPaths(in: goal) {
            let joined = path.joined(separator: " > ")
            // invoke_menu's contract is strict — path/pid/window_id/session
            // only; an extra field is an `invalid_arguments` refusal.
            out.append(Draft(id: "menu:\(joined)", description: "menu \(joined)",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "invoke_menu",
                    args: ["path": .array(path.map { .string($0) })],
                    elementText: joined + " " + (windowTitle ?? ""),
                    summary: "menu \(joined)"))))
        }
        let g = goal.lowercased()
        // Word-boundary match — "display" contains "play" as a substring
        // and must never grow media candidates.
        if g.range(of: #"\b(volume|mute|play|pause|song|track|skip)\b"#,
                   options: .regularExpression) != nil {
            for (id, key) in mediaTable {
                out.append(Draft(id: "media:\(id)",
                    description: "media key \(id)",
                    kind: .request(ActuationRequest(
                        effect: .tool, tool: "media key",
                        args: ["key": .string(id)],
                        elementText: key.spokenName,
                        summary: "media key \(id)"))))
            }
        }
        if g.contains("clipboard") || g.contains("what did i copy")
            || g.contains("what's copied") {
            out.append(Draft(id: "clipboard:read",
                description: "read the clipboard",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "clipboard_read",
                    args: ["return_text": .bool(true)],
                    summary: "read the clipboard"))))
        }
        if let url {
            out.append(Draft(id: "nav",
                description: "navigate the browser to \(url)",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "browser_navigate",
                    args: ["url": .string(url)],
                    elementText: url,
                    summary: "navigate the browser to \(url)"))))
        }
        return out
    }

    /// `menu A > B` / `menu A > B > C` inside the goal — the same
    /// conservative frame the voice parser requires: no menu phrase, no
    /// candidate, and prose arrows never mint one. At most three paths so
    /// a rambled goal can't flood the pick space.
    static func menuPaths(in goal: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(
            pattern: #"\bmenu\s+([A-Za-z][^>.,;]*?(?:\s*>\s*[^>.,;]+)+)"#,
            options: .caseInsensitive) else { return [] }
        var paths: [[String]] = []
        for match in expression.matches(in: goal, range: NSRange(goal.startIndex..., in: goal)) {
            guard let range = Range(match.range(at: 1), in: goal) else { continue }
            let segments = String(goal[range])
                .components(separatedBy: ">")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .prefix(4)
            guard segments.count >= 2,
                  segments.allSatisfy({
                      (1...40).contains($0.count)
                          && $0.range(of: #"^[A-Za-z][A-Za-z0-9 '&\-()\.]*$"#,
                                      options: .regularExpression) != nil
                  }) else { continue }
            paths.append(Array(segments))
        }
        return paths
    }

    /// Candidate id → the HID key it posts — same six, same order.
    static let mediaTable: [(id: String, key: MediaKeys.Key)] = [
        ("volume_up", .volumeUp), ("volume_down", .volumeDown), ("mute", .mute),
        ("play_pause", .playPause), ("next_track", .nextTrack),
        ("previous_track", .previousTrack)]

    static func mediaKey(id: String) -> MediaKeys.Key? {
        mediaTable.first(where: { $0.id == id })?.key
    }

    // MARK: - Extras (host + browser candidates)

    /// Traffic-light controls — real AXButtons the snapshot never lists.
    /// `windowTitle` joins the control's name as the deny-scan corpus,
    /// same as the loop's old dispatch arm built it.
    static func windowControlDrafts(_ buttons: [WindowControls.Button],
                                    windowTitle: String?) -> [Draft] {
        buttons.map { button in
            let corpus = [button.kind.spokenName, windowTitle ?? ""]
                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return Draft(id: "wc:\(button.kind.rawValue)",
                description: "press \(button.kind.spokenName) (traffic light)",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "window_control",
                    args: ["kind": .string(button.kind.rawValue)],
                    elementText: corpus.isEmpty ? nil : corpus,
                    summary: "press \(button.kind.spokenName) (traffic light)")))
        }
    }

    /// Page refs and tab picks from the bound browser — same ids and
    /// descriptions the loop's browserCandidates built.
    static func browserDrafts(_ refs: [BrowserSupport.Ref],
                              binding: BrowserSupport.Binding,
                              cap: Int?) -> [Draft] {
        let offered = cap.map { Array(refs.prefix(max(0, $0))) } ?? refs
        var out: [Draft] = offered.flatMap { r in
            var list = [Draft(id: "b:\(r.ref)",
                description: "page: press \"\(r.label)\"",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "browser_click",
                    args: ["ref": .string(r.ref)],
                    elementText: r.label,
                    summary: "page: press \"\(r.label)\"")))]
            if r.editable {
                list.append(Draft(id: "bt:\(r.ref)",
                    description: "page: type into \"\(r.label)\"",
                    needsText: true,
                    kind: .request(ActuationRequest(
                        effect: .tool, tool: "browser_type",
                        args: ["ref": .string(r.ref)],
                        elementText: r.label,
                        summary: "page: type into \"\(r.label)\""))))
            }
            return list
        }
        for tab in binding.tabs {
            out.append(Draft(id: "tab:\(tab.id)",
                description: "switch to tab \"\(tab.title)\"",
                kind: .request(ActuationRequest(
                    effect: .tool, tool: "switch_tab",
                    args: ["tab_id": .string(tab.id)],
                    summary: "switch to tab \"\(tab.title)\""))))
        }
        return out
    }

    // MARK: - Picker state

    /// The state the pick sees — text only, the shape the loop's
    /// observation state has always been: goal, app, window, numbered
    /// options, recent steps, and any context/hints the lane supplies.
    static func stateJSON(goal: String, app: String, window: String,
                          options: [String], recentSteps: [String],
                          context: String?,
                          snapshotID: String? = nil,
                          fields: [String: JSONValue] = [:]) -> JSONValue {
        var s: [String: JSONValue] = [
            "goal": .string(goal),
            "app": .string(app),
            "window": .string(window),
            "options": .array(options.map { .string($0) }),
            "recent_steps": .array(recentSteps.map { .string($0) }),
            "snapshot_id": snapshotID.map(JSONValue.string) ?? .null,
        ]
        if let context { s["clipboard_or_context"] = .string(context) }
        for (key, value) in fields where s[key] == nil { s[key] = value }
        if let details = s["_candidate_details"]?.object {
            s["_candidate_details"] = .object(details.mapValues { value in
                guard var detail = value.object,
                      var scope = detail["target_scope"]?.object,
                      scope["kind"]?.string == "window" else { return value }
                scope["app"] = .string(app)
                scope["window"] = .string(window)
                detail["target_scope"] = .object(scope)
                return .object(detail)
            })
        }
        return .object(s)
    }
}

extension JSONValue {
    /// Numbers decode as Double — `integer` is exact-Int only; frames and
    /// bounds need the raw value.
    var numberValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
}
