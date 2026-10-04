import Foundation

/// Re-injects a routine's task message into its agent's thread every
/// `everyMinutes` while the app runs (Clicky routines: mac awake + app open,
/// first run immediate, every_minutes >= 2). Timer-based on the main runloop;
/// `fire` hands the (slug, routine) pair to the coordinator, which owns the
/// actual `send(to:message:)`.
public actor RoutineScheduler {
    private struct Entry {
        var routine: Routine
        var timer: Timer?
    }

    private let fire: @Sendable (String, Routine) async -> Void
    private let firstRunImmediate: Bool
    /// Key: "<slug>\u{1F}<routineID>".
    private var entries: [String: Entry] = [:]

    public init(firstRunImmediate: Bool = true,
                fire: @escaping @Sendable (String, Routine) async -> Void) {
        self.firstRunImmediate = firstRunImmediate
        self.fire = fire
    }

    /// Reconciles the schedule with the current roster — called after any
    /// AgentStore mutation. Disabled routines and removed agents stop firing.
    public func sync(agents: [CompanionAgent]) {
        var wanted: [String: (slug: String, routine: Routine)] = [:]
        for agent in agents {
            for routine in agent.routines where routine.enabled && routine.everyMinutes >= 1 {
                wanted[key(slug: agent.slug, routineID: routine.id)] = (agent.slug, routine)
            }
        }
        for (entryKey, entry) in entries where wanted[entryKey]?.routine != entry.routine {
            unschedule(entryKey)
        }
        for (entryKey, pair) in wanted where entries[entryKey] == nil {
            schedule(key: entryKey, slug: pair.slug, routine: pair.routine,
                     interval: TimeInterval(pair.routine.everyMinutes) * 60)
        }
    }

    public func stopAll() {
        for entryKey in Array(entries.keys) { unschedule(entryKey) }
    }

    /// Interval is a parameter so tests can run sub-second schedules.
    func schedule(key entryKey: String, slug: String, routine: Routine,
                  interval: TimeInterval, fireNow: Bool? = nil) {
        entries[entryKey] = Entry(routine: routine, timer: nil)
        let fire = self.fire
        DispatchQueue.main.async { [weak self] in
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                Task { await fire(slug, routine) }
            }
            Task { await self?.attach(entryKey, timer: timer) }
        }
        if fireNow ?? firstRunImmediate {
            Task { await fire(slug, routine) }
        }
    }

    private func attach(_ entryKey: String, timer: Timer) {
        guard entries[entryKey] != nil else {
            // Unscheduled before the main-runloop hop landed — kill the timer
            // on the thread that owns it.
            DispatchQueue.main.async { timer.invalidate() }
            return
        }
        entries[entryKey]?.timer = timer
    }

    private func unschedule(_ entryKey: String) {
        guard let timer = entries.removeValue(forKey: entryKey)?.timer else { return }
        DispatchQueue.main.async { timer.invalidate() }
    }

    private func key(slug: String, routineID: String) -> String {
        "\(slug)\u{1F}\(routineID)"
    }
}
