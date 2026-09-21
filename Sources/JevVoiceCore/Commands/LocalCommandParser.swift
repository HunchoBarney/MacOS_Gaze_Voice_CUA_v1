import Foundation

/// Finite, fully matched commands. Anything outside these shapes remains a Jev decision.
public enum LocalCommandParser {
    public static func parse(_ clause: String, installedApps: [String], context: String?) -> Decision? {
        let clean = IncrementalCommandCoordinator.clean(clause).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if let navigation = AppMatcher.explicitNavigation(clause: clean, installedApps: installedApps) {
            return Decision(clause: clause, action: navigation.action, targetApp: navigation.app, confidence: 1, model: "local-app-navigation")
        }
        let text = clean.replacingOccurrences(of: #"^(?:(?:can|could|would|will) you\s+)?(?:please\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        func decision(_ action: Action, target: String? = nil) -> Decision {
            Decision(clause: clause, action: action, targetApp: target ?? context, confidence: 1, model: "local-native-command")
        }
        if matches(#"^(?:create|make|open) (?:a )?new (?:text )?document(?: in TextEdit)?$"#) {
            return decision(.createDocument, target: matches(#" in TextEdit$"#) ? "TextEdit" : nil)
        }
        if matches(#"^scroll (?:down|up)(?: (?:a little|a bit|slightly|one page))?(?: please)?$"#) {
            return decision(matches(#"^scroll up"#) ? .scrollUp : .scrollDown)
        }
        if matches(#"^(?:go|navigate) back(?: (?:one page|in (?:Chrome|Google Chrome|the browser)))?$"#) {
            let explicit = matches(#" in (?:Google )?Chrome$"#)
            let browser = explicit ? AppMatcher.explicitNavigation(clause: "open Chrome", installedApps: installedApps)?.app : nil
            return decision(.browserBack, target: browser)
        }
        if matches(#"^(?:bring (?:it|that)(?: back| to the front)|restore (?:it|that))$"#) { return decision(.switchApp) }
        let pattern = #"^(minimi[sz]e|hide|quit|close) (.+?)(?: please)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let verb = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text) {
            let target = String(text[name])
            let app: String?
            if ["it", "that", "its window", "the window"].contains(target.lowercased()) { app = context }
            else { app = AppMatcher.explicitNavigation(clause: "open " + target, installedApps: installedApps)?.app }
            guard app != nil || ["it", "that", "its window", "the window"].contains(target.lowercased()) else { return nil }
            let v = text[verb].lowercased()
            return decision(v.hasPrefix("minimi") ? .minimizeApp : v == "hide" ? .hideApp : .closeApp, target: app)
        }
        return nil
    }
}
