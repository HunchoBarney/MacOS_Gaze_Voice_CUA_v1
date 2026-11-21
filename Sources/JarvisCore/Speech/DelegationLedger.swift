import Foundation

/// One GPT-Live client delegation: `(live_session_id, delegation.id)`.
public struct DelegationKey: Hashable, Sendable {
    public let liveSessionID: String
    public let delegationID: String

    public init(liveSessionID: String, delegationID: String) {
        self.liveSessionID = liveSessionID
        self.delegationID = delegationID
    }
}

/// The exactly-once record for GPT-Live delegations. Live only says "I need
/// help"; the person's words come from the transcript, so two things must
/// each happen once: a delegation is admitted once, and a stretch of the
/// person's words goes to at most one request. Every state change is
/// recorded before the work it allows runs, and a committed request is never
/// committed again, so an uncertain step is never retried.
public struct DelegationLedger: Sendable {
    public enum State: Sendable, Equatable {
        /// Seen; the person's words are still settling. Nothing has run.
        case waiting
        /// Handed to the spine as this request. It may have acted.
        case committed(UUID)
        /// Closed with no action, for this reason.
        case declined(String)
    }

    public private(set) var states: [DelegationKey: State] = [:]
    /// Per Live session, the session time (ms) up to which the person's
    /// words already belong to a request or were dropped.
    private var consumedThrough: [String: Int] = [:]

    public init() {}

    public func state(of key: DelegationKey) -> State? { states[key] }

    /// Records a new delegation. False for one already seen: a redelivered
    /// event is ignored, whatever happened to the first.
    public mutating func admit(_ key: DelegationKey) -> Bool {
        guard states[key] == nil else { return false }
        states[key] = .waiting
        return true
    }

    /// Takes the person's words from where the last request ended up to
    /// `end` (exclusive, session ms) in this session. Returns the start of
    /// that stretch, or nil when nothing new is left: those words already
    /// went to a request or were taken back.
    public mutating func consume(session: String, through end: Int) -> Int? {
        let start = consumedThrough[session] ?? 0
        guard end > start else { return nil }
        consumedThrough[session] = end
        return start
    }

    /// Where the next request's words start in this session.
    public func consumed(session: String) -> Int { consumedThrough[session] ?? 0 }

    /// Moves a waiting delegation to committed. False when it isn't waiting,
    /// so a second commit of the same delegation can't happen.
    public mutating func commit(_ key: DelegationKey, request: UUID) -> Bool {
        guard states[key] == .waiting else { return false }
        states[key] = .committed(request)
        return true
    }

    /// Closes a waiting delegation with no action. False when it isn't
    /// waiting: a committed request can't be taken back by the ledger.
    public mutating func decline(_ key: DelegationKey, reason: String) -> Bool {
        guard states[key] == .waiting else { return false }
        states[key] = .declined(reason)
        return true
    }
}
