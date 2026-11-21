import EventKit
import Foundation

/// Calendar events and reminders through EventKit. Jarvis never asks for
/// access on its own: the Settings button (and later onboarding, L5) does.
@MainActor
final class EventKitSource {
    private let store = EKEventStore()

    var calendarAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var remindersAllowed: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    static var allowed: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
            && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    static func requestAccess() async {
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToEvents()
        _ = try? await store.requestFullAccessToReminders()
    }

    /// Timed events from two minutes ago to an hour and five minutes ahead.
    func events(now: Date) -> [CalendarEventSnapshot] {
        guard calendarAllowed else { return [] }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-120),
                                                 end: now.addingTimeInterval(CalendarRules.clashHorizon + 300),
                                                 calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEventSnapshot(
                id: event.calendarItemIdentifier,
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                declined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined,
                meetingLink: CalendarRules.meetingLink(in: [event.url?.absoluteString, event.location, event.notes]))
        }
    }

    /// Incomplete reminders that came due in the last day.
    func reminders(now: Date) async -> [ReminderSnapshot] {
        guard remindersAllowed else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: now.addingTimeInterval(-86_400),
                                                              ending: now.addingTimeInterval(60), calendars: nil)
        let store = self.store
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? []).compactMap { reminder -> ReminderSnapshot? in
                    guard let due = reminder.dueDateComponents?.date else { return nil }
                    return ReminderSnapshot(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                                            due: due, completed: reminder.isCompleted)
                }
                continuation.resume(returning: snapshots)
            }
        }
    }

    func complete(reminder id: String) -> Bool {
        guard remindersAllowed, let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        reminder.isCompleted = true
        return (try? store.save(reminder, commit: true)) != nil
    }
}
