import Foundation

public enum VoiceCaptureMode: String, Sendable, Hashable {
    case command, dictation, microphoneTest, typed
}

public struct VoiceTurnToken: Sendable, Hashable {
    public let id: UUID
    public let generation: UInt64
    public let mode: VoiceCaptureMode

    public init(id: UUID, generation: UInt64, mode: VoiceCaptureMode) {
        self.id = id; self.generation = generation; self.mode = mode
    }
}

public enum VoiceRoute: String, Sendable, Hashable {
    case local, remote, clarify, refuse, dictation
}

public enum VoiceRisk: Sendable {
    case clear, ambiguous, negated, contradictory, invalidCapture
}

public struct VoiceAskBinding: Sendable, Equatable {
    public let taskID: UUID
    public let askID: UUID
    public init(taskID: UUID, askID: UUID) { self.taskID = taskID; self.askID = askID }
}

public struct VoiceProposal: Sendable {
    public let route: VoiceRoute
    public let intent: String
    public let slots: [String: String]
    public let targetIDs: Set<String>
    public let risk: VoiceRisk
    public let reason: String
    public let replyTo: VoiceAskBinding?

    public init(route: VoiceRoute, intent: String, slots: [String: String] = [:],
                targetIDs: Set<String> = [], risk: VoiceRisk = .clear, reason: String = "",
                replyTo: VoiceAskBinding? = nil) {
        self.route = route; self.intent = intent; self.slots = slots
        self.targetIDs = targetIDs; self.risk = risk; self.reason = reason
        self.replyTo = replyTo
    }

    public static func local(_ intent: String) -> Self { Self(route: .local, intent: intent) }
    public static func remote() -> Self { Self(route: .remote, intent: "remote") }
}

/// Immutable authority produced only after a released, fully drained turn.
public struct VoiceAdmission: Sendable {
    public let turn: VoiceTurnToken
    public let text: String
    public let route: VoiceRoute
    public let intent: String
    public let slots: [String: String]
    public let targetIDs: Set<String>
    public let reason: String
    public let replyTo: VoiceAskBinding?
}

/// Owned by the capture actor. Never authorizes from a partial or a time-window text match.
public struct VoiceTurnGate: Sendable {
    public enum State: Sendable, Equatable { case idle, capturing, finishing, admitted, failed, cancelled, completed }
    public private(set) var token: VoiceTurnToken?
    public private(set) var state: State = .idle
    public private(set) var admission: VoiceAdmission?
    public private(set) var failureReason: String?
    public private(set) var acceptedFrames = 0
    public private(set) var mode: VoiceCaptureMode = .command
    private var generation: UInt64 = 0
    private var releaseTime: TimeInterval?
    private var sealedFrames: Int?
    private var startedAt: TimeInterval = 0

    public init() {}

    @discardableResult
    public mutating func begin(id: UUID = UUID(), mode: VoiceCaptureMode, ready: Bool,
                               now: TimeInterval) -> VoiceTurnToken {
        generation &+= 1
        let next = VoiceTurnToken(id: id, generation: generation, mode: mode)
        token = next; self.mode = mode; admission = nil; failureReason = nil
        releaseTime = nil; sealedFrames = nil; acceptedFrames = 0; startedAt = now
        state = ready || mode == .typed || mode == .microphoneTest ? .capturing : .failed
        if state == .failed { failureReason = "provider_unavailable" }
        return next
    }

    public func isCurrent(_ candidate: VoiceTurnToken) -> Bool { token == candidate }

    public func acceptPartial(_ candidate: VoiceTurnToken) -> Bool {
        isCurrent(candidate) && mode != .microphoneTest
            && (state == .capturing || state == .finishing)
    }

    @discardableResult
    public mutating func enterDictation(_ candidate: VoiceTurnToken) -> Bool {
        guard isCurrent(candidate), state == .capturing, mode == .command else { return false }
        mode = .dictation
        return true
    }

    @discardableResult
    public mutating func acceptFrame(_ candidate: VoiceTurnToken, sequence: Int) -> Bool {
        guard isCurrent(candidate) else { return false }
        let drainingAccepted = state == .finishing && acceptedFrames < (sealedFrames ?? 0)
        guard state == .capturing || drainingAccepted else { return false }
        guard sequence == acceptedFrames else {
            fail(candidate, reason: "capture_loss"); return false
        }
        acceptedFrames += 1
        return true
    }

    @discardableResult
    public mutating func release(_ candidate: VoiceTurnToken, acceptedFrames boundary: Int? = nil,
                                 now: TimeInterval) -> Bool {
        guard isCurrent(candidate), state == .capturing else { return false }
        guard now >= startedAt else { fail(candidate, reason: "invalid_clock"); return false }
        let sealed = boundary ?? acceptedFrames
        guard sealed >= acceptedFrames else { fail(candidate, reason: "capture_loss"); return false }
        sealedFrames = sealed; releaseTime = now; state = .finishing
        return true
    }

    /// `window` is the caller's release→final budget: LocalSpeechSession scales
    /// it with banked capture length (a whole-hold decode on >4s of audio needs
    /// ~1s+; a hardcoded 1s starved real holds — physical 5.2s hold at 1006ms).
    public mutating func finalize(
        _ candidate: VoiceTurnToken, text: String, proposal: VoiceProposal,
        drainedFrames: Int, now: TimeInterval, window: TimeInterval = 1
    ) -> VoiceAdmission? {
        guard isCurrent(candidate), state == .finishing, let releaseTime else { return nil }
        guard now >= releaseTime, now - releaseTime <= window else {
            fail(candidate, reason: "finalization_timeout"); return nil
        }
        guard drainedFrames == sealedFrames, acceptedFrames == sealedFrames else {
            fail(candidate, reason: "capture_loss"); return nil
        }
        guard mode != .microphoneTest else { state = .completed; return nil }
        guard mode == .typed || acceptedFrames > 0 else {
            fail(candidate, reason: "capture_loss"); return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard mode != .dictation else { state = .completed; return nil }
            let refused = VoiceAdmission(turn: candidate, text: text, route: .refuse,
                                         intent: "blocked", slots: [:], targetIDs: [],
                                         reason: "empty_transcript", replyTo: nil)
            admission = refused; state = .admitted
            return refused
        }
        var route = proposal.route
        var reason = proposal.reason
        var intent = proposal.intent
        var slots = proposal.slots
        if mode == .dictation {
            route = .dictation; intent = "dictation"; slots = [:]; reason = ""
        } else {
            switch proposal.risk {
            case .clear: break
            case .negated: route = .refuse; reason = "negated_request"
            case .contradictory: route = .clarify; reason = "contradictory_request"
            case .ambiguous: route = .clarify; reason = "ambiguous_critical_value"
            case .invalidCapture:
                fail(candidate, reason: "capture_loss"); return nil
            }
            guard route != .dictation else { fail(candidate, reason: "invalid_mode"); return nil }
        }
        let result = VoiceAdmission(
            turn: candidate, text: text, route: route, intent: intent, slots: slots,
            targetIDs: proposal.targetIDs, reason: reason, replyTo: proposal.replyTo)
        admission = result; state = .admitted
        return result
    }

    public mutating func fail(_ candidate: VoiceTurnToken, reason: String) {
        guard isCurrent(candidate) else { return }
        admission = nil; failureReason = reason; state = .failed
    }

    public mutating func cancel(_ candidate: VoiceTurnToken) {
        guard isCurrent(candidate) else { return }
        admission = nil; failureReason = nil; state = .cancelled
    }
}

/// Connection-tagged permit; response narration cannot grant another action.
public struct VoiceResponseAuthority: Sendable {
    public enum Purpose: String, Sendable { case reasoning, typed, outcomeOnly = "outcome_only" }
    private struct Ticket: Sendable {
        let admission: VoiceAdmission?
        let purpose: Purpose
        let inputItemID: String?
        var responseID: String?
        var spent = false
    }
    public private(set) var connection: UUID?
    public private(set) var requiresReconnect = false
    private var ticket: Ticket?
    private var seenResponses: Set<String> = []
    private var lastRequestedGeneration: UInt64 = 0

    public init() {}

    public var boundTurn: VoiceTurnToken? { ticket?.admission?.turn }
    public var boundResponseID: String? { ticket?.responseID }
    public var purpose: Purpose? { ticket?.purpose }
    public var inputItemID: String? { ticket?.inputItemID }

    public mutating func connect(_ identity: UUID) {
        guard identity != connection else { return }
        connection = identity; ticket = nil; seenResponses = []
        requiresReconnect = false
    }

    @discardableResult
    public mutating func request(admission: VoiceAdmission?, purpose: Purpose, inputItemID: String?) -> Bool {
        guard connection != nil, !requiresReconnect, ticket == nil else { return false }
        if purpose == .outcomeOnly {
            guard admission == nil else { return false }
        } else {
            guard let admission, admission.route == .remote,
                  admission.turn.generation > lastRequestedGeneration,
                  let inputItemID, !inputItemID.isEmpty else { return false }
            guard (purpose == .reasoning && admission.turn.mode == .command)
                    || (purpose == .typed && admission.turn.mode == .typed) else { return false }
            lastRequestedGeneration = admission.turn.generation
        }
        ticket = Ticket(admission: admission, purpose: purpose, inputItemID: inputItemID)
        return true
    }

    @discardableResult
    public mutating func bindCreated(connection identity: UUID, responseID: String) -> Bool {
        guard identity == connection, !requiresReconnect, !responseID.isEmpty,
              !seenResponses.contains(responseID), ticket?.responseID == nil, ticket != nil else { return false }
        ticket?.responseID = responseID
        seenResponses.insert(responseID)
        return true
    }

    public func matches(connection identity: UUID, responseID: String) -> Bool {
        identity == connection && !requiresReconnect && !responseID.isEmpty && ticket?.responseID == responseID
    }

    @discardableResult
    public mutating func takeExecutor(connection identity: UUID, responseID: String, callID: String) -> Bool {
        guard matches(connection: identity, responseID: responseID), !callID.isEmpty,
              ticket?.purpose != .outcomeOnly, ticket?.admission != nil, ticket?.spent == false else { return false }
        ticket?.spent = true
        return true
    }

    public mutating func finish(connection identity: UUID, responseID: String) {
        guard matches(connection: identity, responseID: responseID) else { return }
        ticket = nil
    }

    public mutating func revoke() {
        if ticket != nil { requiresReconnect = true }
        ticket = nil
    }
}
