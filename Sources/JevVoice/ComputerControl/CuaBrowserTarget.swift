import Foundation
import JevVoiceCore

/// Browser refs stay inside the Driver transport/session that minted them.
@MainActor
struct CuaBrowserTarget {
    let window: Int
    let target: JSONValue
    let tab: JSONValue

    static func discover(pid: Int, window: Int, call: CuaTaskAgent.Call) async throws -> Self? {
        do { return try await bind(pid: pid, window: window, call: call) }
        catch DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable") { return nil }
    }

    static func bind(pid: Int, window: Int, call: CuaTaskAgent.Call) async throws -> Self {
        let result = try await call("get_browser_state", ["pid": .number(Double(pid)), "window_id": .number(Double(window))])
        guard result["binding_quality"] == .string("exact"), result["mutation_allowed"] == .bool(true),
              let target = result["target_id"] else {
            throw DriverConnectionError.refused("Cua could not bind this browser window exactly. No browser action was dispatched.")
        }
        let tabs = result["tabs"]?.array ?? []
        let selected = tabs.filter { $0["active"] == .bool(true) }
        let candidates = tabs.count == 1 ? tabs : selected
        guard candidates.count == 1, let tab = candidates[0]["tab_id"] else {
            throw DriverConnectionError.refused("Select the browser tab to use; its identity is ambiguous.")
        }
        return Self(window: window, target: target, tab: tab)
    }

    func observe(call: CuaTaskAgent.Call) async throws -> JSONValue {
        let result = try await call("get_browser_state", ["target_id": target, "tab_id": tab, "snapshot_format": .string("semantic_v2")])
        guard result["target_id"] == target, result["tab_id"] == tab else { throw DriverConnectionError.malformed }
        return result
    }

    static func identity(_ snapshot: JSONValue) -> JSONValue {
        .object(["page": snapshot["page"] ?? .null, "refs": .array(((snapshot["content_refs"]?.array ?? []) + (snapshot["refs"]?.array ?? [])).map { ref in
            .object(Dictionary(uniqueKeysWithValues: ["role", "name", "value", "states", "actions", "visibility", "frame"].compactMap { key in ref[key].map { (key, $0) } }))
        })])
    }

    static func textElements(_ snapshot: JSONValue) -> [JSONValue] {
        ((snapshot["content_refs"]?.array ?? []) + (snapshot["refs"]?.array ?? [])).compactMap { ref in
            guard ref["visibility"] == .string("in_viewport"), ref["states"]?["password"] != .bool(true) else { return nil }
            return .object(["role": .string("AXStaticText"), "label": ref["name"] ?? .string(""), "value": ref["value"] ?? ref["name"] ?? .string("")])
        }
    }
}
