import Foundation
import JevVoiceCore

/// Browser target/tab helpers shared by the drive loop's two entry paths.
/// Target and tab ids are session-scoped — a read's own ids are authoritative;
/// a caller-held id is only a fallback the driver refuses once it goes stale.
enum CuaBrowserTarget {
    static func tabs(_ state: JSONValue) -> [JSONValue] {
        state["tabs"]?.array ?? []
    }

    static func pageRefs(_ state: JSONValue) -> [JSONValue] {
        state["page"]?["refs"]?.array ?? state["refs"]?.array ?? []
    }

    /// The tab the page refs belong to: the read's own `tab_id`, else the
    /// uniquely-active or single tab in the list.
    static func shownTab(in state: JSONValue, tabs: [JSONValue], fallback: String?) -> String? {
        if let echoed = state["tab_id"]?.string { return echoed }
        let active = tabs.filter { $0["active"] == .bool(true) }
        if active.count == 1 { return active[0]["tab_id"]?.string }
        return tabs.count == 1 ? tabs[0]["tab_id"]?.string : fallback
    }

    static func targetID(_ state: JSONValue) -> JSONValue? {
        state["target_id"]
    }

    static func compactTab(_ tab: JSONValue) -> JSONValue {
        .object(["title": tab["title"] ?? .null, "url": tab["url"] ?? .null,
                 "active": tab["active"] ?? .null])
    }

    /// Tab-resolution for browser_navigate: the fresh tab the task opened
    /// (unique blank signature gained over the baseline), else the single or
    /// uniquely-active tab. Anything ambiguous is nil — the caller refuses.
    static func resolveNavigationTab(tabs: [JSONValue],
                                     baseline: [String]?, newTabRequested: Bool) -> JSONValue? {
        if newTabRequested {
            // No baseline means the fresh tab cannot be told apart from the
            // user's existing tabs in the bound window — ambiguous, so
            // refuse rather than navigate whatever happens to be active.
            guard let baseline else { return nil }
            let (added, removed) = tabSignatureDelta(from: baseline, to: tabs.map(tabSignature))
            guard removed.isEmpty, added.count == 1, let sig = added.first,
                  isBlankTabURL(tabSignatureURL(sig)) else { return nil }
            // A matching signature can still be ambiguous — the user may
            // already hold an identical blank tab. The freshly opened tab
            // is the active one; without a unique pick, refuse.
            let matches = tabs.filter { tabSignature($0) == sig }
            if matches.count == 1 { return matches[0] }
            let activeMatches = matches.filter { $0["active"] == .bool(true) }
            return activeMatches.count == 1 ? activeMatches[0] : nil
        }
        let active = tabs.filter { $0["active"] == .bool(true) }
        let candidates = tabs.count == 1 ? tabs : active
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: - Tab signatures (multiset, order-free)

    static func tabSignature(_ tab: JSONValue) -> String {
        "\(tab["url"]?.string ?? "")\u{1F}\(tab["title"]?.string ?? "")"
    }

    static func tabSignatureURL(_ signature: String) -> String {
        String(signature.split(separator: "\u{1F}").first ?? "")
    }

    static func tabSignatureDelta(from old: [String], to new: [String]) -> (added: [String], removed: [String]) {
        var remaining = old
        var added: [String] = []
        for sig in new {
            if let i = remaining.firstIndex(of: sig) { remaining.remove(at: i) }
            else { added.append(sig) }
        }
        return (added, remaining)
    }

    static func isBlankTabURL(_ url: String) -> Bool {
        let u = url.lowercased()
        // Safari reports an empty URL for a fresh tab; Chromium-family new
        // tab pages serve the "newtab" host or the local-ntp host. Host
        // equality, not substring — a real page embedding "…://newtab" in
        // its query is not a blank tab.
        if u.isEmpty || u == "about:blank" || u == "about:newtab"
            || u.hasPrefix("chrome-search://local-ntp") { return true }
        guard let schemeEnd = u.range(of: "://") else { return false }
        let host = u[schemeEnd.upperBound...].prefix {
            $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" && $0 != "@"
        }
        return host == "newtab"
    }
}
