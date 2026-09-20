import Foundation
import JevVoiceCore

struct CuaObservedAction {
    let description: String
    let tool: String
    var arguments: [String: JSONValue]
    var requiresText = false
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
                arguments: ["pid": .number(Double(pid)), "window_id": .number(Double(window)), "path": .array(fullPath)])
        }
    }

    static func browser(snapshot: JSONValue) -> [CuaObservedAction] {
        guard let target = snapshot["target_id"], let tab = snapshot["tab_id"] else { return [] }
        var result: [CuaObservedAction] = []
        for element in snapshot["refs"]?.array ?? [] {
            guard ["in_viewport", "near_viewport"].contains(element["visibility"]?.string ?? ""), let ref = element["ref"],
                  element["states"]?["disabled"] != .bool(true) else { continue }
            let capabilities = element["actions"]?.array?.compactMap(\.string) ?? []
            let label = "\(element["role"]?.string ?? "control") \(element["name"]?.string ?? "")"
            let base: [String: JSONValue] = ["target_id": target, "tab_id": tab, "ref": ref]
            if capabilities.contains("type") {
                result.append(.init(description: "Insert supplied text into page \(label)", tool: "browser_type", arguments: base.merging(["replace": .bool(false)]) { _, b in b }, requiresText: true))
            }
            if capabilities.contains("click") {
                result.append(.init(description: "Click page \(label)", tool: "browser_click", arguments: base.merging(["input_route": .string("dom_event")]) { _, b in b }))
            }
            if capabilities.contains("scroll") {
                for direction in ["up", "down"] {
                    result.append(.init(description: "Scroll page \(label) \(direction)", tool: "browser_pointer", arguments: base.merging(["action": .string("scroll"), "delta_y": .number(direction == "down" ? 500 : -500), "input_route": .string("dom_event")]) { _, b in b }))
                }
            }
        }
        return result
    }
    static func native(elements: [JSONValue], pid: Int, window: Int, includeEmbeddedWebControls: Bool = false) -> [CuaObservedAction] {
        let base: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window))]
        let indexed = Dictionary(elements.compactMap { e in e["element_index"]?.integer.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        var result: [CuaObservedAction] = []
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
                    arguments: base.merging(["path": .array([.string(label)])]) { _, b in b }))
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
                        arguments: base.merging(["path": .array(path.map(JSONValue.string))]) { _, b in b }))
                }
                continue
            }
            guard let token = element["element_token"]?.string else { continue }
            var args = base
            args["element_token"] = .string(token)
            args["delivery_mode"] = .string("background")
            // AXValue can echo a web write without proving renderer insertion.
            if !webContent && ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) {
                result.append(.init(description: "Insert supplied text into \(role) \(label)", tool: "type_text", arguments: args, requiresText: true))
            }
            let actions = element["actions"]?.array?.compactMap(\.string) ?? []
            if actions.contains("AXPress"), role != "AXMenuBarItem" {
                result.append(.init(description: "Press \(role) \(label)", tool: "click", arguments: args))
            }
            for (native, alias) in [("AXShowMenu", "show_menu"), ("AXPick", "pick"),
                                    ("AXConfirm", "confirm"), ("AXCancel", "cancel"), ("AXOpen", "open")]
                where actions.contains(native) && role != "AXMenuBarItem" {
                result.append(.init(description: "\(alias) \(role) \(label)", tool: "click",
                    arguments: args.merging(["action": .string(alias)]) { _, b in b }))
            }
            for custom in element["custom_actions"]?.array ?? [] {
                guard let name = custom["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let raw = custom["raw"]?.string, !raw.isEmpty else { continue }
                // Preserve the exact advertised envelope; a readable name alone
                // can collide with another action supplied by the application.
                result.append(.init(description: "\(name) on \(role) \(label)", tool: "click",
                    arguments: args.merging(["action": .string(raw)]) { _, b in b }))
            }
            if role == "AXScrollArea" {
                for direction in ["up", "down"] {
                    var scroll = args
                    scroll["direction"] = .string(direction); scroll["by"] = .string("page"); scroll["amount"] = .number(1)
                    result.append(.init(description: "Scroll \(label) \(direction) one page", tool: "scroll", arguments: scroll))
                }
            }
        }
        return result
    }
}
