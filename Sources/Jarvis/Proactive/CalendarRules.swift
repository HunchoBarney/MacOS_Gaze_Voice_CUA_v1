import Foundation

/// A calendar event as the rules see it. The EventKit adapter builds it;
/// tests build it by hand.
struct CalendarEventSnapshot: Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var declined = false
    var meetingLink: URL? = nil
}

/// Speak-now calendar alerts: a meeting starting within two minutes, and
/// two meetings in the next hour that overlap. A meeting's headline names
/// its start time rather than a countdown, because the engine may hold or
/// bundle an alert for up to two minutes before it is spoken.
enum CalendarRules {
    static let lead: TimeInterval = 120
    static let clashHorizon: TimeInterval = 3_600

    static func alerts(_ events: [CalendarEventSnapshot], now: Date, calendar: Calendar = .current) -> [ProactiveAlert] {
        let timed = events.filter { !$0.isAllDay && !$0.declined && $0.end > $0.start }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var alerts: [ProactiveAlert] = []
        for event in timed {
            let until = event.start.timeIntervalSince(now)
            guard until <= lead, until > -60 else { continue }
            let when = until <= 60 ? "starts now" : "starts at \(time(event.start, calendar))"
            alerts.append(ProactiveAlert(
                key: "calendar.now.\(event.id).\(Int(event.start.timeIntervalSince1970))",
                source: .calendar, category: .meetingNow,
                headline: "\(name(event)) \(when)",
                offer: event.meetingLink == nil ? nil : "Want me to open the meeting link?",
                action: event.meetingLink.map { .openURL($0) },
                at: now, expires: event.start.addingTimeInterval(lead)))
        }
        let soon = timed.filter { $0.start > now && $0.start.timeIntervalSince(now) <= clashHorizon }
        for (index, first) in soon.enumerated() {
            for second in soon[(index + 1)...] where second.start < first.end {
                alerts.append(ProactiveAlert(
                    key: "calendar.clash.\(first.id).\(second.id)",
                    source: .calendar, category: .meetingClash,
                    headline: "\(name(first)) and \(name(second)) overlap at \(time(second.start, calendar))",
                    offer: "Want me to open your calendar?",
                    action: .request("open Calendar"),
                    at: now, expires: first.start))
            }
        }
        return alerts
    }

    /// The first video-meeting link in an event's URL, location or notes.
    static func meetingLink(in texts: [String?]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, url.scheme == "https", let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    private static func name(_ event: CalendarEventSnapshot) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Your meeting" : title
    }

    private static func time(_ date: Date, _ calendar: Calendar) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        return date.formatted(style)
    }
}

/// A reminder as the rules see it.
struct ReminderSnapshot: Equatable, Sendable {
    var id: String
    var title: String
    var due: Date
    var completed = false
}

/// A reminder the person set is spoken when it comes due. One that came
/// due more than ten minutes ago (say, while the Mac was asleep) only
/// reaches the digest, so a wake never reads out a backlog.
enum ReminderRules {
    static let grace: TimeInterval = 600

    static func alerts(_ reminders: [ReminderSnapshot], now: Date) -> [ProactiveAlert] {
        reminders.filter { !$0.completed && $0.due <= now }.map { reminder in
            let title = reminder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProactiveAlert(
                key: "reminder.\(reminder.id).\(Int(reminder.due.timeIntervalSince1970))",
                source: .reminders, category: .reminder,
                headline: title.isEmpty ? "You have a reminder" : "Reminder: \(title)",
                offer: "Want me to mark it done?",
                action: .completeReminder(reminder.id),
                at: now, expires: reminder.due.addingTimeInterval(grace))
        }
    }
}
