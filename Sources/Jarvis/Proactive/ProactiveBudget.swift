import Foundation

/// The spoken-alert cap: a rolling hour and a rolling day. A bundle counts
/// once; security warnings and the person's own reminders don't count.
struct ProactiveBudget: Codable, Equatable, Sendable {
    private(set) var spoken: [Date] = []

    func allows(now: Date, level: ProactiveLevel) -> Bool {
        let hour = spoken.filter { now.timeIntervalSince($0) < 3_600 }.count
        let day = spoken.filter { now.timeIntervalSince($0) < 86_400 }.count
        return hour < level.hourlyCap && day < level.dailyCap
    }

    mutating func record(now: Date) {
        spoken.removeAll { now.timeIntervalSince($0) >= 86_400 }
        spoken.append(now)
    }
}

/// What "not now" teaches. It snoozes the sender (or the source when there
/// is no sender) for an hour, and three of them in one category move that
/// category to the glow until the person picks a level again.
struct ProactiveLearning: Codable, Equatable, Sendable {
    static let snooze: TimeInterval = 3_600
    static let demoteAfter = 3

    private(set) var snoozedUntil: [String: Date] = [:]
    private(set) var notNowCounts: [String: Int] = [:]

    static func snoozeKey(_ alert: ProactiveAlert) -> String {
        if let sender = alert.sender?.lowercased(), !sender.isEmpty { return "sender:" + sender }
        return "source:" + alert.source.rawValue
    }

    func isSnoozed(_ alert: ProactiveAlert, now: Date) -> Bool {
        snoozedUntil[Self.snoozeKey(alert)].map { now < $0 } ?? false
    }

    func isDemoted(_ category: ProactiveCategory) -> Bool {
        notNowCounts[category.rawValue, default: 0] >= Self.demoteAfter
    }

    mutating func notNow(_ alerts: [ProactiveAlert], now: Date) {
        snoozedUntil = snoozedUntil.filter { now < $0.value }
        for alert in alerts where alert.category.learns {
            snoozedUntil[Self.snoozeKey(alert)] = now.addingTimeInterval(Self.snooze)
        }
        for category in Set(alerts.map(\.category)) where category.learns {
            notNowCounts[category.rawValue, default: 0] += 1
        }
    }
}
