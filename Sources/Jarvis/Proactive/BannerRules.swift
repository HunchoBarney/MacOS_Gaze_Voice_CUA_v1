import Foundation

/// One notification banner read from Notification Center through
/// Accessibility (D4, opt-in). Its text stays on the Mac.
struct BannerSnapshot: Equatable, Sendable {
    var app: String
    var title: String
    var body: String
}

/// Messages from banners: a reply the person is waiting for or an urgent
/// message from an important person is spoken; other messages glow; the
/// rest waits for the digest.
enum BannerRules {
    static let messagingApps = [
        "messages", "mail", "slack", "whatsapp", "microsoft teams", "teams", "telegram", "signal",
        "discord", "messenger", "outlook", "spark", "superhuman",
    ]
    private static let urgentWords = [
        "urgent", "asap", "emergency", "call me", "right now", "immediately", "help", "important",
    ]

    static func alerts(_ banners: [BannerSnapshot], important: [String], watches: [String],
                       now: Date) -> [ProactiveAlert] {
        banners.map { banner in
            let sender = banner.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let app = banner.app.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "banner.\(app).\(sender).\(banner.body)"
            let messaging = messagingApps.contains(app.lowercased())
            let from = app.isEmpty ? "" : " in \(app)"
            let read: ProactiveAction? = banner.body.isEmpty ? nil : .read("\(sender) says: \(banner.body)")
            let offer = read == nil ? nil : "Want me to read it?"
            if messaging, matches(sender, watches) {
                return ProactiveAlert(key: key, source: .notifications, category: .awaitedReply,
                                      headline: "\(sender) replied\(from)", offer: offer, action: read,
                                      sender: sender, at: now)
            }
            if messaging, matches(sender, important) {
                let body = banner.body.lowercased()
                let urgent = urgentWords.contains { body.contains($0) }
                return ProactiveAlert(key: key, source: .notifications, category: urgent ? .urgentMessage : .message,
                                      headline: urgent ? "Urgent message from \(sender)\(from)" : "Message from \(sender)\(from)",
                                      offer: offer, action: read, sender: sender, at: now)
            }
            return ProactiveAlert(key: key, source: .notifications, category: messaging ? .message : .other,
                                  headline: sender.isEmpty ? "A notification from \(app)" : "\(app): \(sender)",
                                  offer: offer, action: read, sender: sender.isEmpty ? nil : sender, at: now)
        }
    }

    /// Banners in a Notification Center window, from the screen reader's
    /// digest of it: each banner is a group of texts, sender first, then
    /// the message. The app name comes from the banner's description when
    /// macOS gives one.
    static func banners(from root: ScreenNode) -> [BannerSnapshot] {
        var found: [BannerSnapshot] = []
        func texts(_ node: ScreenNode) -> [String] {
            let own = node.role == "AXStaticText" ? [node.value ?? node.title ?? ""] : []
            return (own + node.children.flatMap(texts)).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }
        func visit(_ node: ScreenNode) {
            if node.subrole == "AXNotificationCenterBanner" || node.subrole == "AXNotificationCenterAlert" {
                let lines = texts(node)
                if let title = lines.first {
                    let app = node.description?.split(separator: ",").first.map(String.init) ?? ""
                    found.append(BannerSnapshot(app: app, title: title, body: lines.dropFirst().joined(separator: " ")))
                }
                return
            }
            node.children.forEach(visit)
        }
        visit(root)
        return found
    }

    static func matches(_ sender: String, _ names: [String]) -> Bool {
        let words = Set(sender.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return names.contains { name in
            let wanted = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty else { return false }
            return sender.lowercased() == wanted || wanted.split(separator: " ").allSatisfy { words.contains(String($0)) }
        }
    }
}
