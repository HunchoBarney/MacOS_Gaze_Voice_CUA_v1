import Foundation
import JevVoiceCore

/// Browser target/tab helpers shared by the drive loop's two entry paths.
/// Target and tab ids are single-snapshot references — resolved inside one
/// `get_browser_state` read, used immediately, and never carried across reads.
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
        state["tab_id"]?.string
            ?? tabs.first(where: { $0["active"] == .bool(true) })?["tab_id"]?.string
            ?? (tabs.count == 1 ? tabs[0]["tab_id"]?.string : fallback)
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
        if newTabRequested, let baseline {
            let (added, removed) = tabSignatureDelta(from: baseline, to: tabs.map(tabSignature))
            if removed.isEmpty, added.count == 1, let sig = added.first,
               isBlankTabURL(tabSignatureURL(sig)) {
                return tabs.first { tabSignature($0) == sig }
            }
            return nil
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
        return u == "about:blank" || u.contains("://newtab") || u == "about:newtab"
            || u.hasPrefix("chrome-search://local-ntp")
    }
}
