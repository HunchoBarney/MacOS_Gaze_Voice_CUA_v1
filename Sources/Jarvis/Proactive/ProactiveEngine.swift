import Combine
import Foundation

/// Proactivity: sources submit alerts, the ranker picks a tier, the
/// suppression rules and the budget decide whether a speak-now alert is
/// spoken, and alerts that arrive close together are bundled into one
/// sentence. Spoken alerts use the one-way voice; a conversation opens only
/// when the person answers with something other than yes, no or not now.
@MainActor
final class ProactiveEngine: ObservableObject {
    /// Alerts spoken within this long of the last spoken alert wait and go
    /// out together when it ends.
    static let bundleWindow: TimeInterval = 120
    /// How long Jarvis takes an answer after it finishes speaking.
    static let replyWindow: TimeInterval = 8
    static let digestLimit = 50

    enum ReplyOutcome: Equatable {
        /// No alert was waiting for an answer.
        case ignored
        case accepted([ProactiveAlert])
        case declined
        case snoozed
        /// Anything else: hand it to a conversation seeded with the alert.
        case converse(seed: String)
    }

    struct Awaiting: Equatable {
        var alerts: [ProactiveAlert]
        var spoken: String
        var until: Date
    }

    let settings: ProactiveSettings
    private let voice: OneWayVoice
    private let clock: () -> Date
    private let context: () -> ProactiveContext

    @Published private(set) var glow: [ProactiveAlert] = []
    @Published private(set) var card: ProactiveAlert?
    @Published private(set) var awaiting: Awaiting?
    private(set) var digest: [ProactiveAlert] = []
    private(set) var held: [ProactiveAlert] = []
    private(set) var bundle: [ProactiveAlert] = []
    private(set) var lastSpokenAt: Date?
    private var handled: [String: Date] = [:]

    init(settings: ProactiveSettings, voice: OneWayVoice,
         clock: @escaping () -> Date = { Date() },
         context: @escaping () -> ProactiveContext) {
        self.settings = settings
        self.voice = voice
        self.clock = clock
        self.context = context
    }

    /// Alerts from a source poll. A key already handled is ignored, so a
    /// source can report the same meeting on every poll.
    func submit(_ alerts: [ProactiveAlert]) {
        let now = clock()
        handled = handled.filter { now.timeIntervalSince($0.value) < 86_400 }
        var speakNow: [ProactiveAlert] = []
        for alert in alerts where handled[alert.key] == nil {
            handled[alert.key] = now
            if isStale(alert, now) { file(alert); continue }
            switch ProactiveRanker.tier(for: alert, level: settings.level, learning: settings.learning, now: now) {
            case .digest: file(alert)
            case .glow: glow.append(alert)
            case .speakNow: speakNow.append(alert)
            }
        }
        route(speakNow, now: now)
    }

    /// Called on a timer: retries held alerts, sends a bundle whose window
    /// has ended, keeps the reply window open while the alert is still
    /// being spoken, and closes it once unanswered.
    func tick() {
        let now = clock()
        if let awaiting {
            if context().jarvisSpeaking {
                self.awaiting?.until = max(awaiting.until, now.addingTimeInterval(Self.replyWindow))
            } else if now >= awaiting.until {
                self.awaiting = nil
            }
        }
        let retry = held
        held = []
        route(retry, now: now)
    }

    func handleReply(_ text: String) -> ReplyOutcome {
        let now = clock()
        guard let current = awaiting, now < current.until else {
            awaiting = nil
            return .ignored
        }
        awaiting = nil
        switch ProactiveReply.classify(text) {
        case .yes:
            return .accepted(current.alerts)
        case .no:
            return .declined
        case .notNow:
            settings.learning.notNow(current.alerts, now: now)
            voice.stop()
            return .snoozed
        case .other(let reply):
            return .converse(seed: "Jarvis just told the user: \"\(current.spoken)\" The user answered: \"\(reply)\"")
        }
    }

    /// "What's up?": the glow items, then the badge clears.
    func whatsUp() -> String {
        let items = glow
        glow = []
        guard !items.isEmpty else { return "Nothing new." }
        return Self.list(items, lead: items.count == 1 ? "One thing" : "\(Self.count(items.count)) things")
    }

    /// "What did I miss?": everything saved for later and on the glow.
    func whatDidIMiss() -> String {
        let items = digest + glow
        digest = []
        glow = []
        guard !items.isEmpty else { return "You haven't missed anything." }
        return Self.list(items, lead: "While you were busy")
    }

    func dismissCard() {
        card = nil
    }

    // MARK: - Delivery

    private func route(_ incoming: [ProactiveAlert], now: Date) {
        var alerts = incoming
        if !inBundleWindow(now) {
            alerts = bundle + alerts
            bundle = []
        }
        guard !alerts.isEmpty else { return }
        let situation = context()
        var speak: [ProactiveAlert] = []
        for alert in alerts {
            if isStale(alert, now) { file(alert); continue }
            switch ProactiveRanker.tier(for: alert, level: settings.level, learning: settings.learning, now: now) {
            case .digest: file(alert); continue
            case .glow: glow.append(alert); continue
            case .speakNow: break
            }
            switch ProactiveSuppression.verdict(for: alert, in: situation) {
            case .hold: held.append(alert)
            case .card:
                card = alert
                file(alert)
            case .glow: glow.append(alert)
            case .speak: speak.append(alert)
            }
        }
        let security = speak.filter { $0.category == .security }
        let rest = speak.filter { $0.category != .security }
        if !security.isEmpty { say(security, now: now) }
        guard !rest.isEmpty else { return }
        if inBundleWindow(now) {
            bundle += rest
            return
        }
        say(rest, now: now)
    }

    private func say(_ alerts: [ProactiveAlert], now: Date) {
        var alerts = alerts
        if alerts.contains(where: { !$0.category.exemptFromBudget }) {
            if settings.budget.allows(now: now, level: settings.level) {
                settings.budget.record(now: now)
            } else {
                glow += alerts.filter { !$0.category.exemptFromBudget }
                alerts.removeAll { !$0.category.exemptFromBudget }
            }
        }
        guard !alerts.isEmpty else { return }
        let spoken = Self.sentence(for: alerts)
        voice.speak(spoken)
        lastSpokenAt = now
        awaiting = Awaiting(alerts: alerts, spoken: spoken, until: now.addingTimeInterval(Self.replyWindow))
    }

    private func inBundleWindow(_ now: Date) -> Bool {
        guard let lastSpokenAt else { return false }
        return now.timeIntervalSince(lastSpokenAt) < Self.bundleWindow
    }

    private func isStale(_ alert: ProactiveAlert, _ now: Date) -> Bool {
        alert.expires.map { now >= $0 } ?? false
    }

    private func file(_ alert: ProactiveAlert) {
        digest.append(alert)
        if digest.count > Self.digestLimit { digest.removeFirst(digest.count - Self.digestLimit) }
    }

    /// One alert is its sentence and offer; several become one sentence and
    /// an offer to hear the details.
    static func sentence(for alerts: [ProactiveAlert]) -> String {
        guard alerts.count > 1 else { return alerts.first?.spoken ?? "" }
        let heads = alerts.map(\.headline)
        let joined = heads.dropLast().joined(separator: ", ") + (heads.count > 2 ? "," : "") + " and " + heads.last!
        return "Heads up: \(joined). Want the details?"
    }

    private static func list(_ items: [ProactiveAlert], lead: String) -> String {
        let shown = items.prefix(5).map(\.headline)
        var text = "\(lead): " + shown.joined(separator: "; ") + "."
        if items.count > shown.count { text += " And \(items.count - shown.count) more." }
        return text
    }

    private static func count(_ n: Int) -> String {
        let words = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return n < words.count ? words[n] : String(n)
    }
}
