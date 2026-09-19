import Foundation

/// Search capabilities are declared here; planning does not invent URLs or
/// assume that every native app can use a browser search action.
public enum SearchSite: String, CaseIterable, Codable {
    case google = "Google"
    case duckDuckGo = "DuckDuckGo"
    case youtube = "YouTube"

    public var homepage: String {
        switch self {
        case .google: return "https://www.google.com"
        case .duckDuckGo: return "https://duckduckgo.com"
        case .youtube: return "https://www.youtube.com"
        }
    }

    public func searchURL(query: String) -> URL {
        let path: String
        let parameter: String
        switch self {
        case .google: path = "/search"; parameter = "q"
        case .duckDuckGo: path = "/"; parameter = "q"
        case .youtube: path = "/results"; parameter = "search_query"
        }
        var components = URLComponents(string: homepage)!
        components.path = path
        components.queryItems = [URLQueryItem(name: parameter, value: query)]
        return components.url!
    }

    static func matching(url: String) -> SearchSite? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        return allCases.first {
            let canonical = URL(string: $0.homepage)!.host!
            return host == canonical || "www." + host == canonical || "www." + canonical == host
        }
    }

    static func isHomepage(_ url: String) -> Bool {
        guard matching(url: url) != nil, let parts = URLComponents(string: url) else { return false }
        return (parts.path.isEmpty || parts.path == "/") && parts.query == nil && parts.fragment == nil
    }

    func canSearch(from url: String) -> Bool {
        guard SearchSite.matching(url: url) == self, let parts = URLComponents(string: url) else { return false }
        let searchPath = URLComponents(url: searchURL(query: ""), resolvingAgainstBaseURL: false)!.path
        return SearchSite.isHomepage(url) || parts.path == searchPath
    }
}
