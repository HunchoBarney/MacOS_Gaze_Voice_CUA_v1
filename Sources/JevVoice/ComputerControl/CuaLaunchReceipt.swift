import Foundation
import JevVoiceCore

/// Evidence for compensating a launch, never a general-purpose application rollback.
struct CuaLaunchReceipt {
    let bundle: String
    let pid: Int
    let window: Int
    let windows: Set<Int>
    let content: [JSONValue]

    static func identity(_ elements: [JSONValue]) -> [JSONValue] {
        elements.map { e in .object(Dictionary(uniqueKeysWithValues:
            ["element_index", "parent_index", "role", "subrole", "label", "value", "enabled"].compactMap { key in e[key].map { (key, $0) } })) }
    }

    @MainActor
    func reverse(call: CuaTaskAgent.Call, judge: CuaTaskAgent.Judge, approveFocus: (() async throws -> Bool)? = nil) async throws -> String {
        try Task.checkCancellation()
        let apps = try await call("list_apps", [:])
        guard let app = (apps["apps"]?.array ?? []).first(where: { $0["bundle_id"]?.string == bundle }), app["running"] == .bool(true) else {
            return "The app is already closed."
        }
        guard app["pid"]?.integer == pid else { throw DriverConnectionError.refused("The app restarted; it is no longer owned by the original launch.") }
        let listed = try await call("list_windows", ["pid": .number(Double(pid))])
        guard Set((listed["windows"]?.array ?? []).compactMap { $0["window_id"]?.integer }) == windows else {
            throw DriverConnectionError.refused("The app's windows changed. I left it open to protect your work.")
        }
        let args: [String: JSONValue] = ["pid": .number(Double(pid)), "window_id": .number(Double(window)), "include_screenshot": .bool(false), "max_elements": .number(220)]
        let observed = try await call("get_window_state", args)
        let elements = observed["elements"]?.array ?? []
        guard Self.identity(elements) == content else { throw DriverConnectionError.refused("The app changed after launch. I left it open to protect your work.") }
        let menus = Self.menuPaths(in: elements).filter { $0.path.count > 1 }
        var choices: [String: String?] = ["none": "No ordinary application Quit command is present."]
        for (i, menu) in menus.enumerated() { choices[String(i)] = menu.description }
        let result = try await judge(.object(["application": .string(bundle)]), ["quit": .choice(instructions: "Select only this application's ordinary Quit menu item. Never choose Force Quit, Close Document, discard, delete, or a save-dialog action. Choose none if no exact normal Quit action exists.", criteria: choices)])
        let choice = try JevSelection.read(result["quit"], allowed: Set(choices.keys))
        guard let index = Int(choice), menus.indices.contains(index) else { throw DriverConnectionError.refused("No supported normal Quit action was available. The app remains open.") }
        guard let approveFocus, try await approveFocus() else { throw DriverConnectionError.refused("Normal Quit requires temporary foreground access. The app remains open.") }
        // Recheck after the model/approval awaits; a user's edits take precedence over compensation.
        let latestApps = try await call("list_apps", [:])
        guard (latestApps["apps"]?.array ?? []).contains(where: { $0["bundle_id"]?.string == bundle && $0["pid"]?.integer == pid && $0["running"] == .bool(true) }) else { throw DriverConnectionError.refused("The app process changed while correcting. No Quit was sent.") }
        let latestWindows = try await call("list_windows", ["pid": .number(Double(pid))])
        guard Set((latestWindows["windows"]?.array ?? []).compactMap { $0["window_id"]?.integer }) == windows else { throw DriverConnectionError.refused("The app's windows changed while confirming. Nothing was closed.") }
        let current = try await call("get_window_state", args)
        guard Self.identity(current["elements"]?.array ?? []) == content else { throw DriverConnectionError.refused("The app changed while correcting. I left it open.") }
        try Task.checkCancellation()
        let refreshed = Self.menuPaths(in: current["elements"]?.array ?? []).filter { $0.description == menus[index].description }
        guard refreshed.count == 1 else { throw DriverConnectionError.refused("The normal Quit target changed. The app remains open.") }
        _ = try await call("invoke_menu", ["pid": .number(Double(pid)), "window_id": .number(Double(window)),
                                           "path": .array(refreshed[0].path.map(JSONValue.string))])
        let after = try await call("list_apps", [:])
        if (after["apps"]?.array ?? []).contains(where: { $0["bundle_id"]?.string == bundle && $0["running"] == .bool(true) }) {
            throw DriverConnectionError.refused("Normal Quit did not close the app. A save dialog or other app condition may need your attention; nothing was discarded.")
        }
        return "Closed only the unchanged app launched by that task."
    }

    /// Application-menu entries as rooted label paths — the only part of the
    /// observed element set a reversal needs. Global OS menus are excluded.
    static func menuPaths(in elements: [JSONValue]) -> [(description: String, path: [String])] {
        let indexed = Dictionary(elements.compactMap { e in
            e["element_index"]?.integer.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        var result: [(description: String, path: [String])] = []
        for element in elements where element["enabled"] != .bool(false) {
            guard element["role"] == .string("AXMenuItem"),
                  let label = element["label"]?.string, !label.isEmpty else { continue }
            var path = [label], ancestor = element["parent_index"]?.integer
            var seen = Set<Int>(), rooted = false
            while let index = ancestor, seen.insert(index).inserted, let parent = indexed[index] {
                let role = parent["role"]?.string ?? ""
                if ["AXMenuItem", "AXMenuBarItem"].contains(role),
                   let name = parent["label"]?.string, !name.isEmpty {
                    path.insert(name, at: 0)
                    if role == "AXMenuBarItem" { rooted = true; break }
                }
                ancestor = parent["parent_index"]?.integer
            }
            if rooted, path.first != "Apple", path.count <= 16 {
                result.append(("Menu " + path.joined(separator: " → "), path))
            }
        }
        return result
    }
}
