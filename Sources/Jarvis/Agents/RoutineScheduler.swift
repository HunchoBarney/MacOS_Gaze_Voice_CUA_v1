import Foundation
import OSLog

/// Re-injects a routine's task message into its agent's thread every
/// `everyMinutes` while the app runs (Mac awake + app open,
/// first run immediate, every_minutes >= 2). Timer-based on the main runloop;
/// `fire` hands the (slug, routine) pair to the coordinator, which owns the
/// actual `send(to:message:)`.
public actor RoutineScheduler {
    private static let log = Logger(subsystem: "com.karanvirkang.jarvis", category: "routines")
    /// Minimum cadence — shorter cadences are refused, not clamped.
    public static let minimumEveryMinutes = 2

    private struct Entry {
        var routine: Routine
        /// Identifies the schedule() generation — also the id the main-side
        /// timer registry installs and retires under.
        var token: UUID
    }

    private let fire: @Sendable (String, Routine) async -> Void
    private let firstRunImmediate: Bool
    /// lastRunAt lives in a defaults sidecar keyed by routine id — Routine
    /// is a Codable value decoded from agents.json, and recording each run
    /// back on it would churn the roster (and reschedule the timer) on
    /// every fire. Injectable so tests get an isolated suite.
    private let lastRunDefaults: UserDefaults
    /// Timers live on the main runloop. The registry, not actor state, owns
    /// the Timer objects — Timer isn't Sendable, so every hop carries a
    /// UUID token and all create/invalidate executes on MainActor.
    private let timers = RoutineTimers()
    /// Key: "<slug>\u{1F}<routineID>".
    private var entries: [String: Entry] = [:]
    /// Keys whose fire is still running — a slow send must not stack a
    /// duplicate turn on the agent when the next tick lands.
    private var inFlight: Set<String> = []

    public init(firstRunImmediate: Bool = true,
                lastRunDefaults: UserDefaults = .standard,
                fire: @escaping @Sendable (String, Routine) async -> Void) {
        self.firstRunImmediate = firstRunImmediate
        self.lastRunDefaults = lastRunDefaults
        self.fire = fire
    }

    /// Reconciles the schedule with the current roster — called after any
    /// AgentStore mutation. Disabled routines and removed agents stop firing.
    public func sync(agents: [CompanionAgent]) {
        var wanted: [String: (slug: String, routine: Routine)] = [:]
        for agent in agents {
            for routine in agent.routines where routine.enabled {
                guard routine.everyMinutes >= Self.minimumEveryMinutes else {
                    Self.log.warning("routine \(routine.id, privacy: .public) on \(agent.slug, privacy: .public) skipped: every_minutes \(routine.everyMinutes) < \(Self.minimumEveryMinutes)")
                    continue
                }
                wanted[key(slug: agent.slug, routineID: routine.id)] = (agent.slug, routine)
            }
        }
        // Iterate a snapshot — unschedule mutates `entries`.
        for (entryKey, entry) in Array(entries) where wanted[entryKey]?.routine != entry.routine {
            unschedule(entryKey)
        }
        for (entryKey, pair) in wanted where entries[entryKey] == nil {
            let interval = TimeInterval(pair.routine.everyMinutes) * 60
            schedule(key: entryKey, slug: pair.slug, routine: pair.routine,
                     interval: interval, fireNow: isDue(pair.routine, interval: interval))
        }
    }

    /// Relaunch must not refire routines that already ran inside their
    /// cadence — a routine is due only when `now − lastRunAt >= interval`
    /// (a closed app just runs late, never stacked). Never-run routines
    /// keep the firstRunImmediate behavior.
    private func isDue(_ routine: Routine, interval: TimeInterval) -> Bool {
        guard let last = lastRunDefaults.object(forKey: Self.lastRunKey(routine.id)) as? Date
        else { return firstRunImmediate }
        return Date().timeIntervalSince(last) >= interval
    }

    private static func lastRunKey(_ routineID: String) -> String {
        "jarvis.routineLastRunAt.\(routineID)"
    }

    public func stopAll() {
        let tokens = entries.values.map(\.token)
        entries = [:]
        if !tokens.isEmpty {
            Task { @MainActor [timers] in timers.retire(tokens) }
        }
    }

    /// Timers live on the main runloop — retire every live token so a
    /// released scheduler leaves no repeater firing into the void.
    deinit {
        let tokens = entries.values.map(\.token)
        if !tokens.isEmpty {
            Task { @MainActor [timers] in timers.retire(tokens) }
        }
    }

    /// Interval is a parameter so tests can run sub-second schedules.
    /// Rescheduling the same key retires the prior token before the new
    /// entry is written — no orphaned repeaters survive a re-attach.
    func schedule(key entryKey: String, slug: String, routine: Routine,
                  interval: TimeInterval, fireNow: Bool? = nil) {
        if let old = entries[entryKey]?.token {
            Task { @MainActor [timers] in timers.retire([old]) }
        }
        let token = UUID()
        entries[entryKey] = Entry(routine: routine, token: token)
        Task { @MainActor [weak self] in
            // Released before the hop landed: installing anyway would leave
            // an unattached repeater firing forever.
            self?.timers.install(id: token, interval: interval) { [weak self] in
                Task { await self?.dispatch(entryKey: entryKey, token: token,
                                            slug: slug, routine: routine) }
            }
        }
        if fireNow ?? firstRunImmediate {
            dispatch(entryKey: entryKey, token: token, slug: slug, routine: routine)
        }
    }

    /// One fire per entry at a time — ticks for a retired or replaced entry
    /// drop instead of dispatching a stale routine, and a tick arriving
    /// while the previous send still runs coalesces into it. lastRunAt is
    /// recorded at dispatch — the cadence measures from when the routine
    /// actually ran, not when the send finished.
    private func dispatch(entryKey: String, token: UUID, slug: String, routine: Routine) {
        guard entries[entryKey]?.token == token, !inFlight.contains(entryKey) else { return }
        inFlight.insert(entryKey)
        lastRunDefaults.set(Date(), forKey: Self.lastRunKey(routine.id))
        let fire = self.fire
        Task { [weak self] in
            await fire(slug, routine)
            await self?.removeInFlight(entryKey)
        }
    }

    private func removeInFlight(_ entryKey: String) {
        inFlight.remove(entryKey)
    }

    private func unschedule(_ entryKey: String) {
        guard let token = entries.removeValue(forKey: entryKey)?.token else { return }
        Task { @MainActor [timers] in timers.retire([token]) }
    }

    private func key(slug: String, routineID: String) -> String {
        "\(slug)\u{1F}\(routineID)"
    }
}

/// Main-runloop home for the scheduler's repeating Timers. Ordering between
/// queued installs and retires is not guaranteed, so `retire` also records
/// the id — an install that lands after its retire is refused outright, and
/// a retire that lands after the install invalidates the live timer.
@MainActor
private final class RoutineTimers {
    private var live: [UUID: Timer] = [:]
    private var retired: Set<UUID> = []

    /// The registry is only ever touched through MainActor hops after
    /// construction — the actor keeps a reference without paying a hop.
    nonisolated init() {}

    func install(id: UUID, interval: TimeInterval, fire: @escaping @Sendable () -> Void) {
        guard !retired.contains(id) else { return }
        live[id]?.invalidate()
        live[id] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in fire() }
    }

    func retire(_ ids: [UUID]) {
        retired.formUnion(ids)
        for id in ids { live.removeValue(forKey: id)?.invalidate() }
    }
}
