import Foundation
import JevVoiceCore

struct CuaObservedAction {
    let description: String
    let tool: String
    var arguments: [String: JSONValue]
    let targetIdentity: String?
    let effectTargetIdentity: String?
    var requiresText = false
    var requiresApproval = false
    var approvalDescription: String?
    var preconditionIdentity: String?

    init(description: String, tool: String, arguments: [String: JSONValue],
         targetIdentity: String? = nil, effectTargetIdentity: String? = nil,
         requiresText: Bool = false, requiresApproval: Bool = false,
         approvalDescription: String? = nil, preconditionIdentity: String? = nil) {
        self.description = description
        self.tool = tool
        self.arguments = arguments
        self.targetIdentity = targetIdentity
        self.effectTargetIdentity = effectTargetIdentity
        self.requiresText = requiresText
        self.requiresApproval = requiresApproval
        self.approvalDescription = approvalDescription
        self.preconditionIdentity = preconditionIdentity
    }

    /// A stable task-local identity for duplicate suppression. Display labels,
    /// snapshot tokens and inserted values may change after a successful action.
    var effectIdentity: String {
        let omitted = Set(["element_token", "snapshot_id", "ref", "destination_ref", "capture_id", "text", "session"])
        let stableArguments = arguments.filter { !omitted.contains($0.key) }
        return [tool, effectTargetIdentity ?? targetIdentity ?? "", Self.canonical(stableArguments)].joined(separator: "|")
    }

    /// Used only to reacquire a selected target after the host's safety check.
    /// It deliberately ignores per-snapshot handles and labels.
    var bindingIdentity: String {
        let omitted = Set(["element_token", "snapshot_id", "ref", "destination_ref", "capture_id", "text", "session"])
        let stableArguments = arguments.filter { !omitted.contains($0.key) }
        return [tool, targetIdentity ?? "", Self.canonical(stableArguments)].joined(separator: "|")
    }

    private static func canonical(_ arguments: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(JSONValue.object(arguments))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

enum CuaActionSurface: Equatable {
    case production
    case candidate
}

enum CuaActionCatalog {
    static func merge(_ catalogs: [CuaObservedAction]...) -> [CuaObservedAction] {
        var result: [CuaObservedAction] = []
        for action in catalogs.flatMap({ $0 }) where !result.contains(where: { $0.tool == action.tool && $0.arguments == action.arguments }) {
            result.append(action)
        }
        return result
    }

    static func submenu(_ listing: JSONValue, pid: Int, window: Int) -> [CuaObservedAction] {
        guard listing["status"] == .string("listed"),
              let path = listing["resolved_path"]?.array, !path.isEmpty, path.count < 16,
              path.allSatisfy({ !($0.string ?? "").isEmpty }),
              path.first != .string("Apple"), let items = listing["items"]?.array else { return [] }
        let counts = Dictionary(items.compactMap { $0["title"]?.string }.map { ($0, 1) }, uniquingKeysWith: +)
        return items.compactMap { item in
            guard let title = item["title"]?.string, !title.isEmpty, counts[title] == 1,
                  item["enabled"] != .bool(false), item["has_submenu"]?.bool != nil else { return nil }
            let fullPath = path + [.string(title)]
            return .init(description: "Menu " + fullPath.compactMap(\.string).joined(separator: " → "), tool: "invoke_menu",
                arguments: ["pid": .number(Double(pid)), "window_id": .number(Double(window)), "path": .array(fullPath)],
                targetIdentity: "menu:\(pid):\(window):\(fullPath.compactMap(\.string).joined(separator: "/"))")
        }
    }

    static func browser(snapshot: JSONValue, goal: String = "", surface: CuaActionSurface = .production) -> [CuaObservedAction] {
        guard let target = snapshot["target_id"], let tab = snapshot["tab_id"] else { return [] }
        var result: [CuaObservedAction] = []
        let refs = browserActionRefs(snapshot)
        let textTargetCounts = Dictionary(grouping: refs.filter { element in
            let capabilities = element["actions"]?.array?.compactMap(\.string) ?? []
            return capabilities.contains("type")
                && ["in_viewport", "near_viewport"].contains(element["visibility"]?.string ?? "")
                && element["states"]?["disabled"] != .bool(true)
                && !(element["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && !(element["role"]?.string?.isEmpty ?? true)
        }, by: { element in
            "\(element["role"]?.string ?? "")|\(element["name"]?.string ?? "")"
        }).mapValues(\.count)
        let requestedURL = surface == .candidate ? explicitBrowserNavigationURL(in: goal) : nil
        if let requestedURL {
            result.append(.init(description: "Navigate the bound browser tab to the requested address",
                tool: "browser_navigate", arguments: ["target_id": target, "tab_id": tab, "url": .string(requestedURL)],
                targetIdentity: "browser:\(target):\(tab):navigation"))
        }
        let requestedUpload = surface == .candidate ? explicitUploadFile(in: goal) : nil
        if let requestedUpload {
            let matches = refs.filter {
                ["in_viewport", "near_viewport"].contains($0["visibility"]?.string ?? "")
                    && $0["states"]?["disabled"] != .bool(true)
                    && ($0["actions"]?.array?.contains(.string("upload")) ?? false)
                    && $0["ref"] != nil
            }
            if matches.count == 1, let ref = matches[0]["ref"], let precondition = requestedUpload.identity {
                let components = URLComponents(string: snapshot["page"]?["url"]?.string ?? "")
                let site = components.flatMap { parts -> String? in
                    guard let scheme = parts.scheme, let host = parts.host else { return nil }
                    return scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
                } ?? "the current site"
                let filename = URL(fileURLWithPath: requestedUpload.path).lastPathComponent
                let referenceIndex = ref.string?.split(separator: ":").last.map(String.init) ?? "unknown"
                let role = matches[0]["role"]?.string ?? ""
                let name = matches[0]["name"]?.string ?? ""
                let frame = matches[0]["frame"]?.string ?? ""
                let targetIdentity = "browser:\(target):\(tab):upload:\(referenceIndex):\(role):\(frame)"
                let effectTargetIdentity = "browser:\(target):\(tab):upload:\(role):\(name):\(frame)"
                result.append(.init(description: "Upload \(filename) to \(site) through the observed file input",
                    tool: "browser_set_input_files",
                    arguments: ["target_id": target, "tab_id": tab, "ref": ref,
                                "files": .array([.string(requestedUpload.path)])],
                    targetIdentity: targetIdentity, effectTargetIdentity: effectTargetIdentity,
                    requiresApproval: true,
                    approvalDescription: "Send the file \(filename) to \(site) through this page's file input?",
                    preconditionIdentity: precondition))
            }
        }
        let requestedDrag = surface == .candidate ? exactBrowserDragLabels(in: goal) : nil
        let dragSourceRef: JSONValue? = requestedDrag.flatMap { request in
            let sources = refs.filter {
                $0["name"]?.string?.localizedCaseInsensitiveCompare(request.source) == .orderedSame
                    && ["in_viewport", "near_viewport"].contains($0["visibility"]?.string ?? "")
                    && $0["states"]?["disabled"] != .bool(true)
                    && ($0["actions"]?.array?.contains(.string("pointer")) ?? false)
                    && $0["frame"] != nil && $0["frame"] != .null
            }
            return sources.count == 1 ? sources[0]["ref"] : nil
        }
        for element in refs {
            guard ["in_viewport", "near_viewport"].contains(element["visibility"]?.string ?? ""), let ref = element["ref"],
                  element["states"]?["disabled"] != .bool(true) else { continue }
            let capabilities = element["actions"]?.array?.compactMap(\.string) ?? []
            let role = element["role"]?.string ?? "control"
            let name = element["name"]?.string ?? ""
            let frame = element["frame"]?.string ?? ""
            let label = "\(role) \(name)"
            let base: [String: JSONValue] = ["target_id": target, "tab_id": tab, "ref": ref]
            let referenceIndex = ref.string?.split(separator: ":").last.map(String.init) ?? ref.string ?? "unknown"
            let targetIdentity = "browser:\(target):\(tab):ref:\(referenceIndex):\(role):\(frame)"
            let effectTargetIdentity = "browser:\(target):\(tab):element:\(role):\(name):\(frame)"
            if capabilities.contains("type"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !frame.isEmpty, textTargetCounts["\(role)|\(name)"] == 1 {
                result.append(.init(description: "Insert supplied text into page \(label)", tool: "browser_type", arguments: base.merging(["replace": .bool(false)]) { _, b in b }, targetIdentity: targetIdentity, effectTargetIdentity: effectTargetIdentity, requiresText: true))
            }
            if capabilities.contains("click") {
                result.append(.init(description: "Click page \(label)", tool: "browser_click", arguments: base.merging(["input_route": .string("dom_event")]) { _, b in b }, targetIdentity: targetIdentity, effectTargetIdentity: effectTargetIdentity))
            }
            if capabilities.contains("pointer"), surface == .candidate {
                for (operation, description) in [("hover", "Hover over"), ("right_click", "Right-click"), ("double_click", "Double-click")] {
                    result.append(.init(description: "\(description) page \(label)", tool: "browser_pointer",
                        arguments: base.merging(["action": .string(operation), "input_route": .string("dom_event")]) { _, b in b }, targetIdentity: targetIdentity, effectTargetIdentity: effectTargetIdentity))
                }
                if let requestedDrag,
                   let dragSourceRef, element["ref"] == dragSourceRef,
                   element["name"]?.string?.localizedCaseInsensitiveCompare(requestedDrag.source) == .orderedSame,
                   let sourceFrame = element["frame"], sourceFrame != .null {
                    let destinations = refs.filter {
                       $0["name"]?.string?.localizedCaseInsensitiveCompare(requestedDrag.destination) == .orderedSame
                           && ["in_viewport", "near_viewport"].contains($0["visibility"]?.string ?? "")
                           && $0["states"]?["disabled"] != .bool(true)
                           && ($0["actions"]?.array?.contains(.string("pointer")) ?? false)
                           && $0["frame"] == sourceFrame
                    }
                    if destinations.count == 1, let destinationRef = destinations[0]["ref"] {
                        result.append(.init(description: "Drag page \(label) to the requested observed destination",
                            tool: "browser_pointer",
                            arguments: base.merging(["action": .string("drag"), "destination_ref": destinationRef,
                                                     "input_route": .string("dom_event")]) { _, b in b },
                            targetIdentity: targetIdentity + ":to:\(destinationRef.string ?? "")",
                            effectTargetIdentity: effectTargetIdentity + ":to:\(destinations[0]["role"]?.string ?? ""):\(destinations[0]["name"]?.string ?? ""):\(sourceFrame.string ?? "")"))
                    }
                }
            }
            if capabilities.contains("scroll") {
                for direction in ["up", "down"] {
                    result.append(.init(description: "Scroll page \(label) \(direction)", tool: "browser_pointer", arguments: base.merging(["action": .string("scroll"), "delta_y": .number(direction == "down" ? 500 : -500), "input_route": .string("dom_event")]) { _, b in b }, targetIdentity: targetIdentity, effectTargetIdentity: effectTargetIdentity))
                }
            }
        }
        return result
    }

    private static func browserActionRefs(_ snapshot: JSONValue) -> [JSONValue] {
        let identified = ((snapshot["content_refs"]?.array ?? []) + (snapshot["refs"]?.array ?? [])).compactMap { element -> (String, JSONValue)? in
            guard let ref = element["ref"]?.string, !ref.isEmpty else { return nil }
            return (ref, element)
        }
        let groups = Dictionary(grouping: identified, by: \.0)
        var emitted = Set<String>()
        return identified.compactMap { ref, element in
            guard emitted.insert(ref).inserted,
                  let copies = groups[ref], copies.allSatisfy({ $0.1 == element }) else { return nil }
            return element
        }
    }

    static func browserDialog(snapshot: JSONValue, dialog: JSONValue, goal: String,
                              surface: CuaActionSurface) -> [CuaObservedAction] {
        guard surface == .candidate, dialog["present"] == .bool(true),
              let target = snapshot["target_id"], let tab = snapshot["tab_id"],
              let dialogID = dialog["dialog_id"], let kind = dialog["kind"]?.string,
              let resolution = explicitDialogResolution(in: goal) else { return [] }
        if kind == "beforeunload", resolution.action == "accept" { return [] }
        if kind == "prompt", resolution.action == "accept", resolution.promptText == nil { return [] }
        if kind != "prompt", resolution.promptText != nil { return [] }
        var arguments: [String: JSONValue] = [
            "target_id": target, "tab_id": tab, "dialog_id": dialogID,
            "action": .string(resolution.action)
        ]
        if let text = resolution.promptText { arguments["prompt_text"] = .string(text) }
        let consequence = resolution.action == "accept" ? "accept" : "dismiss"
        let approval = resolution.action == "accept"
        return [.init(description: "\(consequence.capitalized) the current JavaScript \(kind) dialog",
                      tool: "browser_dialog", arguments: arguments,
                      targetIdentity: "browser:\(target):\(tab):dialog:\(kind)",
                      requiresApproval: approval,
                      approvalDescription: approval ? "Accept the current JavaScript \(kind) dialog on this page?" : nil)]
    }
    static func native(elements: [JSONValue], pid: Int, window: Int, includeEmbeddedWebControls: Bool = false,
                       goal: String = "", surface: CuaActionSurface = .production) -> [CuaObservedAction] {
        let base: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window))]
        let indexed = Dictionary(elements.compactMap { e in e["element_index"]?.integer.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        var result: [CuaObservedAction] = []
        let requestedKey = surface == .candidate ? explicitKeyboardInput(in: goal) : nil
        if surface == .candidate, let frame = explicitWindowFrame(in: goal) {
            let targetIdentity = "native-window:\(pid):\(window)"
            let arguments: [String: JSONValue] = base.merging([
                "x": .number(frame.x), "y": .number(frame.y),
                "width": .number(frame.width), "height": .number(frame.height)
            ]) { _, value in value }
            result.append(.init(description: "Set this window to x=\(frame.x), y=\(frame.y), width=\(frame.width), height=\(frame.height)",
                tool: "set_window_frame", arguments: arguments, targetIdentity: targetIdentity,
                requiresApproval: true,
                approvalDescription: "Set this exact window frame to x=\(frame.x), y=\(frame.y), width=\(frame.width), height=\(frame.height)?"))
        }
        let requestedPopupValue = surface == .candidate ? explicitPopupValue(in: goal) : nil
        for element in elements where element["enabled"] != .bool(false) {
            var parentIndex = element["parent_index"]?.integer
            var visited = Set<Int>()
            var webContent = element["role"] == .string("AXWebArea")
            while let index = parentIndex, visited.insert(index).inserted, let parent = indexed[index] {
                webContent = webContent || parent["role"] == .string("AXWebArea")
                parentIndex = parent["parent_index"]?.integer
            }
            // Real browsers use DOM actions. Non-browser apps can expose embedded-web
            // buttons through AX; each click still needs an observed resulting state.
            if webContent && !includeEmbeddedWebControls { continue }
            let role = element["role"]?.string ?? ""
            let label = element["label"]?.string ?? ""
            if role == "AXMenuBarItem", !label.isEmpty, label != "Apple" {
                result.append(.init(description: "Inspect menu \(label)", tool: "invoke_menu",
                    arguments: base.merging(["path": .array([.string(label)])]) { _, b in b },
                    targetIdentity: "menu:\(pid):\(window):\(label)"))
                continue
            }
            if role == "AXMenuItem", !label.isEmpty {
                var path = [label], ancestor = element["parent_index"]?.integer
                var seen = Set<Int>()
                var rooted = false
                while let index = ancestor, seen.insert(index).inserted, let parent = indexed[index] {
                    let r = parent["role"]?.string ?? ""
                    if ["AXMenuItem", "AXMenuBarItem"].contains(r), let name = parent["label"]?.string, !name.isEmpty {
                        path.insert(name, at: 0)
                        if r == "AXMenuBarItem" { rooted = true; break }
                    }
                    ancestor = parent["parent_index"]?.integer
                }
                // Global OS menus are not application controls; never expose force-quit/security routes.
                if rooted, path.first != "Apple", path.count <= 16 {
                    result.append(.init(description: "Menu " + path.joined(separator: " → "), tool: "invoke_menu",
                        arguments: base.merging(["path": .array(path.map(JSONValue.string))]) { _, b in b },
                        targetIdentity: "menu:\(pid):\(window):\(path.joined(separator: "/"))"))
                }
                continue
            }
            guard let token = element["element_token"]?.string else { continue }
            var args = base
            args["element_token"] = .string(token)
            args["delivery_mode"] = .string("background")
            let observedIndex = element["element_index"]?.integer.map { "index:\($0)" }
            let frameEncoder = JSONEncoder(); frameEncoder.outputFormatting = [.sortedKeys]
            let fallbackFrame = element["frame"].flatMap { try? frameEncoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let fallbackTarget = "fallback:\(role):\(element["subrole"]?.string ?? ""):\(element["label"]?.string ?? ""):\(element["parent_index"]?.integer.map(String.init) ?? ""):\(fallbackFrame)"
            let targetIdentity = "native:\(pid):\(window):\(observedIndex ?? fallbackTarget)"
            let preconditionIdentity = nativeActionPreconditionIdentity(element)
            // AXValue can echo a web write without proving renderer insertion.
            if !webContent && ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) {
                result.append(.init(description: "Insert supplied text into \(role) \(label)", tool: "type_text", arguments: args,
                                    targetIdentity: targetIdentity, requiresText: true, preconditionIdentity: preconditionIdentity))
            }
            let actions = element["actions"]?.array?.compactMap(\.string) ?? []
            if actions.contains("AXPress"), role != "AXMenuBarItem" {
                result.append(.init(description: "Press \(role) \(label)", tool: "click", arguments: args,
                                    targetIdentity: targetIdentity, preconditionIdentity: preconditionIdentity))
            }
            for (native, alias) in [("AXShowMenu", "show_menu"), ("AXPick", "pick"),
                                    ("AXConfirm", "confirm"), ("AXCancel", "cancel"), ("AXOpen", "open")]
                where actions.contains(native) && role != "AXMenuBarItem" {
                result.append(.init(description: "\(alias) \(role) \(label)", tool: "click",
                    arguments: args.merging(["action": .string(alias)]) { _, b in b }, targetIdentity: targetIdentity,
                    preconditionIdentity: preconditionIdentity))
            }
            for custom in element["custom_actions"]?.array ?? [] {
                guard let name = custom["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let raw = custom["raw"]?.string, !raw.isEmpty else { continue }
                // Preserve the exact advertised envelope; a readable name alone
                // can collide with another action supplied by the application.
                result.append(.init(description: "\(name) on \(role) \(label)", tool: "click",
                    arguments: args.merging(["action": .string(raw)]) { _, b in b }, targetIdentity: targetIdentity,
                    preconditionIdentity: preconditionIdentity))
            }
            if surface == .candidate {
                if actions.contains("AXShowMenu") {
                    result.append(.init(description: "Right-click \(role) \(label)", tool: "right_click",
                        arguments: args, targetIdentity: targetIdentity, preconditionIdentity: preconditionIdentity))
                }
                if actions.contains("AXOpen") {
                    result.append(.init(description: "Double-click to open \(role) \(label)", tool: "double_click",
                        arguments: args, targetIdentity: targetIdentity, preconditionIdentity: preconditionIdentity))
                }
                if let requestedKey, role == "AXTextArea", element["value"]?.string != nil {
                    // The host currently has an independent exact postcondition only
                    // for one Return/Enter newline in a readable text area. Never
                    // expose other keys or hotkeys as choices that dispatch will refuse.
                    if case .key(let key) = requestedKey, ["return", "enter"].contains(key.lowercased()) {
                        var keyArguments = args
                        keyArguments["key"] = .string(key)
                        keyArguments["delivery_mode"] = .string(explicitKeyboardDeliveryMode(in: goal))
                        result.append(.init(description: "Press the requested key in \(role) \(label)", tool: "press_key",
                                            arguments: keyArguments, targetIdentity: targetIdentity,
                                            preconditionIdentity: preconditionIdentity))
                    }
                }
            }
            if role == "AXScrollArea" {
                for direction in ["up", "down"] {
                    var scroll = args
                    scroll["direction"] = .string(direction); scroll["by"] = .string("page"); scroll["amount"] = .number(1)
                    result.append(.init(description: "Scroll \(label) \(direction) one page", tool: "scroll", arguments: scroll,
                                        targetIdentity: targetIdentity, preconditionIdentity: preconditionIdentity))
                }
            }
        }
        if surface == .candidate {
            let children = Dictionary(grouping: elements.compactMap { element -> (Int, JSONValue)? in
                guard let parent = element["parent_index"]?.integer else { return nil }
                return (parent, element)
            }, by: { $0.0 })
            for popup in elements where popup["role"] == .string("AXPopUpButton") && popup["enabled"] != .bool(false) {
                guard let index = popup["element_index"]?.integer, let token = popup["element_token"]?.string else { continue }
                let options = (children[index] ?? []).compactMap { pair -> String? in
                    let child = pair.1
                    guard child["role"] == .string("AXMenuItem"), child["enabled"] != .bool(false) else { return nil }
                    return child["value"]?.string ?? child["label"]?.string
                }
                let counts = Dictionary(options.map { ($0, 1) }, uniquingKeysWith: +)
                for option in options where counts[option] == 1 && option == requestedPopupValue {
                    var arguments = base
                    arguments["element_token"] = .string(token)
                    arguments["value"] = .string(option)
                    result.append(.init(description: "Choose \(option) in popup \(popup["label"]?.string ?? "control")",
                        tool: "set_value", arguments: arguments,
                        targetIdentity: "native:\(pid):\(window):index:\(index):option:\(option)",
                        preconditionIdentity: nativeActionPreconditionIdentity(popup)))
                }
            }
        }
        return result
    }

    private static func nativeActionPreconditionIdentity(_ element: JSONValue) -> String {
        let fields = ["element_index", "parent_index", "role", "subrole", "label", "description", "help",
                      "value", "enabled", "selected", "frame", "actions", "custom_actions"]
        let identity = JSONValue.object(Dictionary(uniqueKeysWithValues: fields.compactMap { key in
            element[key].map { (key, $0) }
        }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(identity)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private enum KeyboardInput {
        case key(String)
        case hotkey([String])
    }

    private static func explicitPopupValue(in goal: String) -> String? {
        guard let quoted = quotedSpan(in: goal),
              goal[..<quoted.opening].range(of: #"(?i)\b(?:choose|select|set)\s+(?:the\s+)?(?:value\s+)?$"#, options: .regularExpression) != nil,
              goal[..<quoted.opening].range(of: #"(?i)\b(?:do\s+not|don't|never|avoid)\b"#, options: .regularExpression) == nil else { return nil }
        return quoted.text
    }

    private static func explicitWindowFrame(in goal: String) -> (x: Double, y: Double, width: Double, height: Double)? {
        let pattern = #"(?i)^\s*(?:please\s+)?(?:set|move|resize)\s+(?:the\s+)?(?:current\s+)?window\s+to\s+x\s*=\s*(-?\d+(?:\.\d+)?)\s+y\s*=\s*(-?\d+(?:\.\d+)?)\s+width\s*=\s*(\d+(?:\.\d+)?)\s+height\s*=\s*(\d+(?:\.\d+)?)\s*[.!?]?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              (1...4).allSatisfy({ match.range(at: $0).location != NSNotFound }) else { return nil }
        let values = (1...4).compactMap { index -> Double? in
            guard let range = Range(match.range(at: index), in: goal) else { return nil }
            return Double(goal[range])
        }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return (values[0], values[1], values[2], values[3])
    }

    private static func explicitDialogResolution(in goal: String) -> (action: String, promptText: String?)? {
        let promptPattern = #"(?i)\b(?:please\s+)?(?:accept|confirm)\s+(?:the\s+)?(?:current\s+)?prompt\s+(?:with|saying)\s*$"#
        if let quoted = quotedSpan(in: goal),
           let expression = try? NSRegularExpression(pattern: promptPattern),
           let match = expression.firstMatch(in: goal, range: NSRange(goal.startIndex..<quoted.opening, in: goal)),
           let matchRange = Range(match.range, in: goal),
           !containsExplicitNegation(in: goal[..<matchRange.lowerBound]),
           onlyTrailingPunctuation(goal[goal.index(after: quoted.range.upperBound)...]) {
            return ("accept", quoted.text)
        }
        let actionPattern = #"(?i)\b(accept|confirm|dismiss|cancel|close|decline)\s+(?:the\s+)?(?:current\s+)?(?:javascript\s+)?(?:alert|dialog|prompt)\s*[.!?]?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: actionPattern),
              let match = expression.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              let range = Range(match.range(at: 1), in: goal),
              let matchRange = Range(match.range, in: goal),
              !containsExplicitNegation(in: goal[..<matchRange.lowerBound]) else { return nil }
        let verb = String(goal[range]).lowercased()
        return (["accept", "confirm"].contains(verb) ? "accept" : "dismiss", nil)
    }

    private static func containsExplicitNegation(in text: Substring) -> Bool {
        text.range(of: #"(?i)\b(?:do\s+not|don't|never|avoid)\b"#, options: .regularExpression) != nil
    }

    private static func onlyTrailingPunctuation(_ text: Substring) -> Bool {
        text.allSatisfy { $0.isWhitespace || ".!?".contains($0) }
    }

    private static func explicitKeyboardInput(in goal: String) -> KeyboardInput? {
        guard let quoted = quotedSpan(in: goal),
              goal[..<quoted.opening].range(of: #"(?i)\b(?:press|hit|type)\s+(?:the\s+)?(?:key|shortcut|hotkey)\s*$"#, options: .regularExpression) != nil else { return nil }
        let text = quoted.text
        let normalized = text.lowercased().replacingOccurrences(of: " ", with: "")
        if normalized.contains("+") {
            let parts = normalized.split(separator: "+").map(String.init)
            let modifiers: Set<String> = ["cmd", "command", "shift", "option", "alt", "ctrl", "control", "fn"]
            guard let last = parts.last, parts.count >= 2, parts.dropLast().allSatisfy(modifiers.contains),
                  parts.dropLast().count == Set(parts.dropLast()).count,
                  Set(parts.dropLast()).isSubset(of: modifiers), Self.validKey(last) else { return nil }
            let aliases = ["command": "cmd", "control": "ctrl", "alt": "option"]
            return .hotkey(parts.map { aliases[$0] ?? $0 })
        }
        guard Self.validKey(normalized) else { return nil }
        return .key(normalized)
    }

    static func explicitKeyboardTool(in goal: String) -> String? {
        guard let input = explicitKeyboardInput(in: goal) else { return nil }
        switch input {
        case .key: return "press_key"
        case .hotkey: return "hotkey"
        }
    }

    private static func explicitKeyboardDeliveryMode(in goal: String) -> String {
        guard let quoted = quotedSpan(in: goal) else { return "background" }
        let foregroundPattern = #"(?i)^\s*(?:please\s+)?(?:in|with)\s+the\s+foreground\s*,?\s*(?:press|hit)\s+(?:the\s+)?(?:key|shortcut|hotkey)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: foregroundPattern),
              expression.firstMatch(in: goal, range: NSRange(goal.startIndex..<quoted.opening, in: goal)) != nil else {
            return "background"
        }
        return "foreground"
    }

    private static func validKey(_ key: String) -> Bool {
        let keys: Set<String> = ["return", "enter", "tab", "escape", "esc", "up", "down", "left", "right",
                                 "space", "delete", "home", "end", "pageup", "pagedown"]
        return keys.contains(key) || key.range(of: #"^(?:[a-z]|[0-9]|f(?:[1-9]|1[0-2]))$"#, options: .regularExpression) != nil
    }

    private static func explicitHTTPURL(in goal: String) -> String? {
        guard let text = quotedSpan(in: goal)?.text,
              let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return text
    }

    static func explicitBrowserNavigationURL(in goal: String) -> String? {
        guard let quoted = quotedSpan(in: goal),
              onlyTrailingPunctuation(goal[goal.index(after: quoted.range.upperBound)...]),
              let url = explicitHTTPURL(in: goal), hasExplicitNavigationVerb(in: goal) else { return nil }
        return url
    }

    private static func explicitUploadFile(in goal: String) -> (path: String, identity: String?)? {
        guard let quoted = quotedSpan(in: goal), quoted.text.hasPrefix("/"),
              quoted.text == URL(fileURLWithPath: quoted.text).standardizedFileURL.path else { return nil }
        let prefix = goal[..<quoted.opening]
        guard prefix.range(of: #"(?i)\b(?:do\s+not|don't|never|avoid)\b"#, options: .regularExpression) == nil,
              prefix.range(of: #"(?i)\b(?:upload|attach)\s+(?:(?:the|this|a|file)\s+)*$"#, options: .regularExpression) != nil,
              let identity = uploadFileIdentity(path: quoted.text) else { return nil }
        return (quoted.text, identity)
    }

    static func uploadFileIdentity(path: String) -> String? {
        let manager = FileManager.default
        guard path.hasPrefix("/"), path == URL(fileURLWithPath: path).standardizedFileURL.path,
              manager.fileExists(atPath: path), (try? manager.destinationOfSymbolicLink(atPath: path)) == nil,
              let attributes = try? manager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        let values = [attributes[.systemNumber], attributes[.systemFileNumber], attributes[.size], attributes[.modificationDate]]
        return values.map { String(describing: $0 ?? "") }.joined(separator: ":")
    }

    private static func hasExplicitNavigationVerb(in goal: String) -> Bool {
        guard let quoted = quotedSpan(in: goal) else { return false }
        let prefix = goal[..<quoted.opening]
        guard prefix.range(of: #"(?i)\b(?:do\s+not|don't|didn't|never|avoid)\b"#, options: .regularExpression) == nil else { return false }
        return prefix.range(of: #"(?i)\b(?:navigate\s+to|visit|go\s+to|open)\s*$"#, options: .regularExpression) != nil
    }

    private static func quotedSpan(in source: String) -> (text: String, range: Range<String.Index>, opening: String.Index)? {
        var spans: [(String, Range<String.Index>, String.Index)] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let opening = source[cursor]
            let closing: Character
            switch opening {
            case "\"": closing = "\""
            case "“": closing = "”"
            default:
                cursor = source.index(after: cursor)
                continue
            }
            let start = source.index(after: cursor)
            var end = start
            while end < source.endIndex, source[end] != closing { end = source.index(after: end) }
            guard end < source.endIndex else { return nil }
            spans.append((String(source[start..<end]), start..<end, cursor))
            cursor = source.index(after: end)
        }
        guard spans.count == 1, let (text, range, opening) = spans.first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, range, opening)
    }

    private static func exactBrowserDragLabels(in goal: String) -> (source: String, destination: String)? {
        let pattern = #"(?i)^\s*drag\s+\"([^\"]+)\"\s+to\s+\"([^\"]+)\"\s*[.!?]?\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              let sourceRange = Range(match.range(at: 1), in: goal), let destinationRange = Range(match.range(at: 2), in: goal) else { return nil }
        return (String(goal[sourceRange]), String(goal[destinationRange]))
    }
}
