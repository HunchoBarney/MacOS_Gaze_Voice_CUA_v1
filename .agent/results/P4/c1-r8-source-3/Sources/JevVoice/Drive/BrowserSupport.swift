import Foundation
import JevVoiceCore

/// The browser half of the drive loop: binds a native browser window to a
/// CDP target, snapshots tabs/DOM refs as loop candidates, and dispatches
/// `browser_*` calls. Kept separate because it owns a small stateful
/// binding (target_id + tab_id per window) the loop holds between rounds.
struct BrowserSupport {
    /// Bundles whose content is DOM — the page escalation rung applies.
    static let browserBundles: Set<String> = [
        "com.apple.safari", "com.google.chrome", "com.brave.browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.opera",
        "com.vivaldi.vivaldi", "company.thebrowser.browser", "com.arc.browser",
    ]

    static func isBrowser(bundleID: String?) -> Bool {
        bundleID.map { browserBundles.contains($0.lowercased()) } ?? false
    }

    /// One bound browser window: the session-scoped ids every `browser_*`
    /// call repeats.
    struct Binding: Sendable {
        var targetID: String
        var tabID: String
        var tabs: [(id: String, title: String, active: Bool)]
        var pageURL: String?
    }

    /// A DOM ref candidate decoded from `get_browser_state`.
    struct Ref: Sendable {
        var ref: String          // "p<snapshot>:<index>"
        var role: String
        var label: String
        var editable: Bool
    }

    /// Bind pid+window → target/tab ids. The driver answers an unprepared
    /// browser with `browser_requires_setup` — as a thrown `toolRefused`
    /// through `call`, or as a refusal body on transports that return it.
    /// `browser_prepare` then attaches the user's real profile — a read
    /// AND a latent actuation on page content — so it rides the policy
    /// gate below rather than running grant-free. A refusal after
    /// preparation means the user declined profile access or the endpoint
    /// never came up — the loop falls back to AX candidates either way.
    ///
    /// Consent seams: `granted` answers standing authorization (default:
    /// the dedicated `browserPageAccess` grant or the broad computer-use
    /// grant); `confirm`, when a caller wires the loop's ask channel,
    /// offers one bounded ask whose yes is remembered as
    /// `browserPageAccess`. Neither present → the prepare is skipped and
    /// the binding honestly returns nil.
    static func bind(pid: Int, windowID: Int, session: String,
                     call: (String, [String: JSONValue]) async throws -> JSONValue,
                     allowPreparation: Bool = true,
                     granted: (@Sendable () -> Bool)? = nil,
                     confirm: (@Sendable (String) async -> Bool)? = nil) async throws -> Binding? {
        let args: [String: JSONValue] = ["pid": .number(Double(pid)),
                                         "window_id": .number(Double(windowID)),
                                         "session": .string(session)]
        var result = try await boundState(args, call: call)
        if result == nil {
            guard allowPreparation, await prepareAllowed(pid: pid, granted: granted,
                                       confirm: confirm) else { return nil }
            // Existing-profile attach is explicit per the driver's own
            // contract: strategy.kind=existing_profile anchored to the
            // exact native window, gated by the daemon's launch-time
            // `--grant existing-profile`. A refusal surfaces as nil on
            // the retry — the loop keeps its AX lane.
            _ = try? await call("browser_prepare", [
                "pid": .number(Double(pid)),
                "window_id": .number(Double(windowID)),
                "strategy": .object(["kind": .string("existing_profile")]),
                "session": .string(session)])
            result = try await boundState(args, call: call)
        }
        guard let result else { return nil }
        guard let targetID = result["target_id"]?.string
                ?? result["structuredContent"]?["target_id"]?.string else { return nil }
        let payload = result["structuredContent"] ?? result
        let tabs: [(id: String, title: String, active: Bool)] =
            (payload["tabs"]?.array ?? []).compactMap {
                t -> (id: String, title: String, active: Bool)? in
                guard let id = t["tab_id"]?.string ?? t["id"]?.string else { return nil }
                return (id: id, title: t["title"]?.string ?? "",
                        active: t["active"]?.bool ?? false)
            }
        // The bind payload tags the live tab per row — the first row is
        // not necessarily the active one on a multi-tab window.
        guard let tabID = payload["active_tab_id"]?.string
                ?? tabs.first(where: { $0.active })?.id
                ?? tabs.first?.id else { return nil }
        return Binding(targetID: targetID, tabID: tabID, tabs: tabs,
                       pageURL: payload["url"]?.string ?? payload["active_url"]?.string)
    }

    /// One bind-mode `get_browser_state`; nil only when the driver says
    /// the endpoint needs `browser_prepare` — every other refusal or
    /// transport fault still throws so the caller can settle honestly.
    private static func boundState(_ args: [String: JSONValue],
                                   call: (String, [String: JSONValue]) async throws -> JSONValue) async throws -> JSONValue? {
        do {
            let result = try await call("get_browser_state", args)
            return isSetupRefusal(result) ? nil : result
        } catch let error as DriverConnectionError {
            if isSetupRefusal(error) { return nil }
            throw error
        }
    }

    static func isSetupRefusal(_ result: JSONValue) -> Bool {
        result["error"]?.string == "browser_requires_setup"
            || result["code"]?.string == "browser_requires_setup"
            || result["refusal"]?.string == "browser_requires_setup"
            || result["refusal"]?["code"]?.string == "browser_requires_setup"
    }

    /// The thrown form — `CuaConnection.call` maps a `status: "refused"`
    /// tool result to `toolRefused`, so the setup refusal arrives as an
    /// error, not a value.
    static func isSetupRefusal(_ error: DriverConnectionError) -> Bool {
        if case .toolRefused(_, let code, _) = error {
            return code == "browser_requires_setup"
        }
        if case .refused(let text) = error {
            return text.contains("browser_requires_setup")
        }
        return false
    }

    /// The consent half of `bind`: `browser_prepare` runs the same
    /// `CuaPolicy.decide` seam every effect dispatch does — deny-list scan
    /// included — with the standing grants answering outright and the
    /// injected `confirm` offering the one bounded ask. A yes persists as
    /// `browserPageAccess` so the next task isn't re-asked (the grant's
    /// own doc: "the re-ask after the user approved once").
    static func prepareAllowed(pid: Int,
                               granted: (@Sendable () -> Bool)? = nil,
                               confirm: (@Sendable (String) async -> Bool)? = nil) async -> Bool {
        let standing = granted?() ?? (CuaStandingGrants.browserPageAccess
            || CuaStandingGrants.computerUseInput)
        switch CuaPolicy.decide(tool: "browser_prepare",
                                args: ["pid": .number(Double(pid))],
                                elementText: "this browser's page content",
                                standingGrant: standing) {
        case .allow: return true
        case .deny: return false
        case .needsConfirm(let prompt):
            guard let confirm, await confirm(prompt) else { return false }
            CuaStandingGrants.browserPageAccess = true
            return true
        }
    }

    /// Snapshot one tab → DOM refs. Each ref becomes a loop candidate;
    /// editable refs additionally offer a `browser_type` candidate.
    ///
    /// The driver's default `dom_refs_v1` payload emits `{ref, node,
    /// label, frame}` — `node` is the lowercase tag and `label` a
    /// space-joined `k=v` attribute string (aria-label, placeholder,
    /// name, id, type, value, href, role). `semantic_v2` emits `{ref,
    /// role, name, states, actions, frame, visibility}` instead. Both
    /// decode here so editable refs surface `bt:` candidates either way.
    static func snapshot(_ binding: Binding, session: String,
                         call: (String, [String: JSONValue]) async throws -> JSONValue) async throws -> [Ref] {
        let result = try await call("get_browser_state", [
            "target_id": .string(binding.targetID), "tab_id": .string(binding.tabID),
            "session": .string(session)])
        let nodes = result["structuredContent"]?["refs"]?.array
            ?? result["refs"]?.array ?? result["elements"]?.array ?? []
        return nodes.compactMap { node in
            guard let ref = node["ref"]?.string else { return nil }
            let label = node["name"]?.string ?? node["label"]?.string ?? ""
            // v2 emits `role` directly; v1's label string carries
            // `role=<value>` when the element has one, else the tag.
            let role = node["role"]?.string
                ?? attrValue("role", in: label)
                ?? node["node"]?.string ?? ""
            return Ref(ref: ref, role: role, label: label,
                       editable: isEditable(node.object ?? [:], label: label))
        }
    }

    /// Editability mirrors the driver's own Type-action rule
    /// (semantic.rs `action_kinds`): a v2 `actions` list is authoritative
    /// (`"type"` must be present); a v2 `states.editable`/`editable`
    /// truthy marker also qualifies. The v1 payload carries no explicit
    /// field, so the tag set {input, textarea} — the driver declares Type
    /// on all of it — plus a `role=textbox`/`role=searchbox` or
    /// `contenteditable` attr token in the label string says editable.
    static func isEditable(_ node: [String: JSONValue], label: String) -> Bool {
        if let actions = node["actions"]?.array {
            return actions.contains { $0.string == "type" }
        }
        if let states = node["states"], let value = states["editable"], isTruthy(value) {
            return true
        }
        if node["editable"].map(isTruthy) == true { return true }
        let tag = node["node"]?.string?.lowercased()
            ?? node["role"]?.string?.lowercased() ?? ""
        if tag == "input" || tag == "textarea" { return true }
        let l = label.lowercased()
        return l.contains("role=textbox") || l.contains("role=searchbox")
            || l.contains("contenteditable")
    }

    /// `k=v` lookup inside a v1 label string — `"id=q type=search"` →
    /// `"search"` for `type`. Values never contain spaces by construction
    /// (the driver joins `k=v` pairs with single spaces).
    static func attrValue(_ key: String, in label: String) -> String? {
        for token in label.split(separator: " ") {
            let kv = token.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == key {
                return kv[1].isEmpty ? nil : String(kv[1])
            }
        }
        return nil
    }

    /// The driver's editable-state truthiness: a bool, or a string that
    /// isn't literally "false" (semantic.rs treats any non-"false" string
    /// as editable).
    static func isTruthy(_ value: JSONValue) -> Bool {
        if let v = value.bool { return v }
        if let v = value.string { return v.lowercased() != "false" }
        return false
    }

    static func clickArgs(_ binding: Binding, ref: String, session: String) -> [String: JSONValue] {
        // `input_route: "dom_event"` — the default `trusted` CDP Input
        // route would activate a standalone macOS browser window, so the
        // driver refuses it (`browser_input_trust_unavailable`) and names
        // `dom_event` as the background-safe alternative for a ref.
        ["target_id": .string(binding.targetID), "tab_id": .string(binding.tabID),
         "ref": .string(ref), "input_route": .string("dom_event"),
         "session": .string(session)]
    }

    static func typeArgs(_ binding: Binding, ref: String, text: String,
                         session: String) -> [String: JSONValue] {
        ["target_id": .string(binding.targetID), "tab_id": .string(binding.tabID),
         "ref": .string(ref), "text": .string(text), "session": .string(session)]
    }

    static func navigateArgs(_ binding: Binding, url: String, session: String) -> [String: JSONValue] {
        ["target_id": .string(binding.targetID), "tab_id": .string(binding.tabID),
         "url": .string(url), "session": .string(session)]
    }
}
