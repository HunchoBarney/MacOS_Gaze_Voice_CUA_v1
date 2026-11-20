import Foundation

/// Scam shapes Jarvis refuses on sight, checked inside
/// `CuaPolicy.neverReason` so no grant or spoken yes gets past them.
enum ScamSignals {

    /// Top-level names a link's words have to end in before they count as
    /// a website. A file name like "report.pdf" is not a site.
    private static let siteEndings: Set<String> = [
        "com", "net", "org", "gov", "edu", "mil", "int", "info", "biz", "io", "co", "us", "uk",
        "ca", "au", "nz", "ie", "de", "fr", "es", "it", "nl", "in", "me", "app", "online", "site",
    ]

    private static let domainPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w@.-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?![\w-])"#)
    private static let hrefPattern = try! NSRegularExpression(pattern: #"(?i)\bhref=(\S+)"#)
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"(?<!\d)(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}(?!\d)"#)

    /// A link whose words name one website while its address goes to
    /// another: "paypal.com" pointing at paypa1-secure.xyz. The address
    /// comes from `url`, or from an `href=` the browser lane folds into the
    /// element text.
    static func linkMismatch(text: String, url: String?) -> (shown: String, actual: String)? {
        let href = url ?? firstMatch(hrefPattern, in: text, group: 1)
        guard let href, let actual = host(of: href) else { return nil }
        let words = hrefPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let shown = matches(domainPattern, in: words).map { $0.lowercased() }
            .filter { siteEndings.contains(String($0.split(separator: ".").last ?? "")) }
        guard let first = shown.first, !shown.contains(where: { site($0) == site(actual) }) else { return nil }
        return (first, actual)
    }

    private static let alarmPhrases = [
        "virus", "infected", "malware", "spyware", "hacked", "compromised", "security alert",
        "computer is locked", "mac is locked", "computer has been locked", "do not restart",
        "do not shut down", "do not close this", "call support", "call apple", "call microsoft",
        "tech support", "technical support", "support hotline", "toll free", "account suspended",
        "unauthorized purchase", "refund department",
    ]

    /// A phone number on a scare screen: the warning popups that tell you
    /// to call "Apple Support". Returns the number.
    static func alarmPhoneNumber(in text: String) -> String? {
        let words = " " + CuaPolicy.normalize(text.lowercased()) + " "
        guard alarmPhrases.contains(where: { words.contains(" " + CuaPolicy.normalize($0) + " ") }) else { return nil }
        return firstMatch(phonePattern, in: text, group: 0)
    }

    /// The host a link goes to, scheme or not; nil for tel: and friends.
    static func host(of link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: CharacterSet(charactersIn: "\"' <>"))
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let host = URLComponents(string: withScheme)?.host?.lowercased(), host.contains(".") else { return nil }
        return host
    }

    /// The registrable part of a host: "mail.google.com" is "google.com",
    /// "bbc.co.uk" stays "bbc.co.uk".
    static func site(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel = labels[labels.count - 2]
        let keep = labels.last!.count == 2 && ["co", "com", "org", "net", "gov", "ac", "edu"].contains(secondLevel) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String, group: Int) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}
