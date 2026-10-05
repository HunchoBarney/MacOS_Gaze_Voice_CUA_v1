import Foundation

/// Synchronous, in-memory coordination owned by CuaVoiceRuntime. Nothing in this file
/// executes computer actions, records audio, or grants an assertion of success.
///
/// Slimmed for the planner split: intents, pending questions, answers, attempts
/// and outcomes. The planner handles routing; this store only records what was
/// asked, answered, attempted and concluded.
struct CuaDialogueState {
    /// Derivable provenance only: transcriptRanges are word offsets into the owning
    /// TranscriptHandoff's transcript.
    struct Source: Equatable {
        let captureID: UUID
        let handoffID: UUID
        let revision: Int
        let transcriptRanges: [Range<Int>]

        init(captureID: UUID, handoffID: UUID, revision: Int, transcriptRanges: [Range<Int>]) {
            self.captureID = captureID
            self.handoffID = handoffID
            self.revision = revision
            self.transcriptRanges = transcriptRanges
        }
    }

    struct Intent: Equatable {
        let id: UUID
        let source: Source
        let utterance: String
        let instruction: String
        let target: Target?

        init(id: UUID = UUID(), source: Source, utterance: String,
             instruction: String, target: Target? = nil) {
            self.id = id
            self.source = source
            self.utterance = utterance
            self.instruction = instruction
            self.target = target
        }
    }

    /// An attempt is not an intent: retries retain the same intent and have new IDs.
    struct Attempt: Equatable {
        let id: UUID
        let intentID: UUID
        let instruction: String
        let target: Target?
        let revision: Int

        init(id: UUID = UUID(), intentID: UUID, instruction: String, target: Target? = nil,
             revision: Int = 0) {
            self.id = id
            self.intentID = intentID
            self.instruction = instruction
            self.target = target
            self.revision = revision
        }
    }

    /// Describes a new intent only. Answers and retries resume the referenced entry in
    /// place via answer() and revise(); they are never relationships. No caller adds
    /// non-independent intents — the cases persist because VoiceController's task
    /// diagnostics still switch on the recorded value.
    enum Relationship: Equatable {
        case independent
        case refinement(of: UUID)
        case continuation(of: UUID)
        case correction(of: UUID)
    }

    /// An execution-blocking edge between intents. Nothing creates these anymore —
    /// the type survives on Entry only because the task diagnostics in
    /// VoiceController and the settle path in CuaVoiceRuntime still read it.
    struct Prerequisite: Equatable {
        let intentID: UUID
        let requiresIntentID: UUID
        let requiredFact: FactKind
    }

    enum FactKind: Equatable {
        case targetObserved
        case resultObserved
    }

    /// A verified readback bound to the producing attempt — recorded evidence,
    /// never an assertion of success the executor granted itself.
    struct VerifiedFact: Equatable {
        let kind: FactKind
        let intentID: UUID
        let attemptID: UUID
        let revision: Int
        let target: Target?
        let evidence: String

        init(kind: FactKind, intentID: UUID, attemptID: UUID, revision: Int,
             target: Target? = nil, evidence: String) {
            self.kind = kind
            self.intentID = intentID
            self.attemptID = attemptID
            self.revision = revision
            self.target = target
            self.evidence = evidence
        }
    }

    struct Target: Equatable {
        struct BundleIdentity: Equatable {
            let bundleID: String
            let displayName: String?
        }
        struct ProcessIdentity: Equatable {
            let processIdentifier: Int32
            let bundleID: String?
        }
        struct WindowIdentity: Equatable {
            let windowID: String
            let title: String?
        }
        /// `source` is derived from the utterance; `observed` is a postcondition
        /// readback bound to the producing attempt — the only claim that may
        /// satisfy a fact.
        enum Provenance: Equatable {
            case source(Source)
            case observed(attemptID: UUID)
        }

        let bundle: BundleIdentity?
        let process: ProcessIdentity?
        let window: WindowIdentity?
        let description: String
        let provenance: Provenance

        var application: String? { bundle?.displayName ?? bundle?.bundleID }

        init(bundle: BundleIdentity? = nil, process: ProcessIdentity? = nil,
             window: WindowIdentity? = nil, description: String, provenance: Provenance) {
            self.bundle = bundle
            self.process = process
            self.window = window
            self.description = description
            self.provenance = provenance
        }
    }

    struct Question: Equatable {
        let id: UUID
        let intentID: UUID
        let prompt: String
        let options: [String]
        let target: Target?
        let revision: Int
        /// Monotonic ask order, stamped by ask() so resolvers can order
        /// parked asks oldest→newest. Ordering metadata, not identity:
        /// excluded from Equatable so the stored (stamped) record still
        /// equals the one the caller asked with.
        let sequence: Int

        init(id: UUID = UUID(), intentID: UUID, prompt: String,
             options: [String] = [], target: Target? = nil, revision: Int = 0,
             sequence: Int = 0) {
            self.id = id
            self.intentID = intentID
            self.prompt = prompt
            self.options = options
            self.target = target
            self.revision = revision
            self.sequence = sequence
        }

        static func == (lhs: Question, rhs: Question) -> Bool {
            lhs.id == rhs.id && lhs.intentID == rhs.intentID && lhs.prompt == rhs.prompt
                && lhs.options == rhs.options && lhs.target == rhs.target
                && lhs.revision == rhs.revision
        }
    }

    struct Answer: Equatable {
        let questionID: UUID
        let intentID: UUID
        let revision: Int
        let source: Source
        let utterance: String
    }

    enum Outcome: Equatable {
        case verified(evidence: String)
        case verifiedFact(VerifiedFact)
        case partial(evidence: String, blockedReason: String, verifiedFacts: [VerifiedFact] = [])
        case blocked(reason: String)
        case cancelled(reason: String)
        case failed(reason: String)
        case uncertain(reason: String)
    }

    enum Status: Equatable {
        case pending
        case awaitingAnswer(questionID: UUID)
        case executing(attemptID: UUID)
        case uncertain(attemptID: UUID, reason: String)
        case partial(attemptID: UUID, evidence: String, blockedReason: String)
        case blocked(attemptID: UUID, reason: String)
        case cancelled(reason: String)
        case succeeded(attemptID: UUID, evidence: String)
        case failed(attemptID: UUID, reason: String)

        var isResolved: Bool {
            if case .succeeded = self { return true }
            if case .failed = self { return true }
            if case .cancelled = self { return true }
            return false
        }
    }

    struct Entry: Equatable {
        let intent: Intent
        let relationship: Relationship
        let prerequisite: Prerequisite?
        fileprivate(set) var status: Status = .pending
        fileprivate(set) var attempts: [Attempt] = []
        fileprivate(set) var question: Question?
        fileprivate(set) var answers: [Answer] = []
        fileprivate(set) var revision: Int = 0
        fileprivate(set) var verifiedFacts: [VerifiedFact] = []
    }

    enum TransitionError: Error, Equatable {
        case duplicateIntent
        case unknownIntent
        case unknownRelatedIntent
        case invalidPrerequisite
        case invalidTransition
        case invalidAttempt
        case invalidQuestion
        case emptyEvidence
        case invalidProvenance
        case unresolvedCapacity
    }

    /// Unresolved work is never discarded to make room; callers handle backpressure.
    let resolvedHistoryLimit: Int
    let unresolvedLimit: Int
    private(set) var entries: [Entry] = []
    private var knownIntentIDs: Set<UUID> = []
    private var knownQuestionIDs: Set<UUID> = []
    private var knownAttemptIDs: Set<UUID> = []
    private var questionSequence = 0

    init(resolvedHistoryLimit: Int = 32, unresolvedLimit: Int = 32) {
        self.resolvedHistoryLimit = max(0, resolvedHistoryLimit)
        self.unresolvedLimit = max(0, unresolvedLimit)
    }

    func entry(for id: UUID) -> Entry? { entries.first { $0.intent.id == id } }

    /// Whether the intent may begin an attempt: pending, with its prerequisite
    /// (when present) discharged by a verified fact of the required kind on the
    /// required intent — and only while that fact is revision-current. Answer,
    /// revise and cancel all bump the required intent's revision, and every
    /// path that re-opens an intent after a fact-recording finish goes through
    /// one of them, so evidence an earlier context produced can never satisfy
    /// a later attempt or a cancelled intent silently. A plain `verified`
    /// finish records no fact and can never satisfy a fact-bound prerequisite.
    func canExecute(_ id: UUID) -> Bool {
        guard let candidate = entry(for: id), candidate.status == .pending else { return false }
        guard let prerequisite = candidate.prerequisite else { return true }
        guard let required = entry(for: prerequisite.requiresIntentID) else { return false }
        return required.verifiedFacts.contains {
            $0.kind == prerequisite.requiredFact && $0.revision == required.revision
        }
    }

    /// The intent currently waiting on a user answer — the newest pending
    /// question when several exist, so respond_to_task sees the live ask.
    var pendingClarification: (entry: Entry, question: Question)? {
        for entry in entries.reversed() {
            guard let question = entry.question,
                  case .awaitingAnswer = entry.status,
                  question.revision == entry.revision else { continue }
            return (entry, question)
        }
        return nil
    }

    /// Every parked clarification, oldest ask first — the multi-ask
    /// complement to pendingClarification's newest-only view. Resolvers that
    /// enumerate or address a specific ask read this; the stamped question
    /// sequence is the ordering.
    var awaitingAnswerEntries: [Entry] {
        entries.filter { entry in
            guard let question = entry.question,
                  case .awaitingAnswer(let id) = entry.status,
                  question.id == id, question.revision == entry.revision
            else { return false }
            return true
        }.sorted { ($0.question?.sequence ?? 0) < ($1.question?.sequence ?? 0) }
    }

    mutating func add(_ intent: Intent, relationship: Relationship = .independent,
                      prerequisite: Prerequisite? = nil) throws {
        guard !knownIntentIDs.contains(intent.id) else { throw TransitionError.duplicateIntent }
        guard entries.filter({ !$0.status.isResolved }).count < unresolvedLimit else {
            throw TransitionError.unresolvedCapacity
        }
        guard !intent.utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !intent.source.transcriptRanges.isEmpty else {
            throw TransitionError.invalidProvenance
        }
        switch relationship {
        case .independent:
            break
        case .refinement(let id), .continuation(let id), .correction(let id):
            guard entry(for: id) != nil else { throw TransitionError.unknownRelatedIntent }
        }
        if let prerequisite {
            guard prerequisite.intentID == intent.id,
                  prerequisite.requiresIntentID != intent.id,
                  entry(for: prerequisite.requiresIntentID) != nil else {
                throw TransitionError.invalidPrerequisite
            }
        }
        entries.append(Entry(intent: intent, relationship: relationship,
                             prerequisite: prerequisite))
        knownIntentIDs.insert(intent.id)
        trimResolvedHistory()
    }

    mutating func ask(_ question: Question) throws {
        guard let index = entries.firstIndex(where: { $0.intent.id == question.intentID }) else {
            throw TransitionError.unknownIntent
        }
        guard entries[index].status == .pending else { throw TransitionError.invalidTransition }
        guard question.revision == entries[index].revision,
              !knownQuestionIDs.contains(question.id) else { throw TransitionError.invalidQuestion }
        knownQuestionIDs.insert(question.id)
        questionSequence += 1
        entries[index].question = Question(id: question.id, intentID: question.intentID,
                                           prompt: question.prompt, options: question.options,
                                           target: question.target, revision: question.revision,
                                           sequence: questionSequence)
        entries[index].status = .awaitingAnswer(questionID: question.id)
    }

    /// Answering re-opens the intent for a fresh attempt; the question remains as history.
    mutating func answer(_ answer: Answer) throws {
        guard let index = entries.firstIndex(where: { $0.intent.id == answer.intentID }) else {
            throw TransitionError.unknownIntent
        }
        guard entries[index].status == .awaitingAnswer(questionID: answer.questionID),
              entries[index].question?.revision == answer.revision,
              entries[index].revision == answer.revision else {
            throw TransitionError.invalidQuestion
        }
        guard !answer.utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !answer.source.transcriptRanges.isEmpty,
              answer.source != entries[index].intent.source,
              !entries[index].answers.contains(where: { $0.source == answer.source }) else {
            throw TransitionError.invalidProvenance
        }
        entries[index].answers.append(answer)
        entries[index].revision += 1
        entries[index].status = .pending
    }

    /// Begin a fresh attempt on a pending intent. Prerequisite edges are
    /// recorded metadata only — nothing in the current runtime creates them —
    /// so a pending status alone admits the attempt.
    mutating func begin(_ attempt: Attempt) throws {
        guard let index = entries.firstIndex(where: { $0.intent.id == attempt.intentID }) else {
            throw TransitionError.unknownIntent
        }
        guard entries[index].status == .pending else { throw TransitionError.invalidTransition }
        guard attempt.revision == entries[index].revision,
              !knownAttemptIDs.contains(attempt.id) else {
            throw TransitionError.invalidAttempt
        }
        knownAttemptIDs.insert(attempt.id)
        entries[index].attempts.append(attempt)
        entries[index].status = .executing(attemptID: attempt.id)
    }

    mutating func finish(attemptID: UUID, intentID: UUID, outcome: Outcome) throws {
        guard let index = entries.firstIndex(where: { $0.intent.id == intentID }) else {
            throw TransitionError.unknownIntent
        }
        guard entries[index].status == .executing(attemptID: attemptID) else {
            throw TransitionError.invalidAttempt
        }
        let revision = entries[index].revision
        func validate(_ fact: VerifiedFact) throws {
            guard !fact.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TransitionError.emptyEvidence
            }
            guard fact.intentID == intentID,
                  fact.attemptID == attemptID,
                  fact.revision == revision else {
                throw TransitionError.invalidProvenance
            }
            // Any carried target must be this attempt's own observation —
            // a target read back under another attempt can never be re-stamped
            // onto this one, whatever kind of fact rides on it.
            if let target = fact.target {
                guard case .observed(attemptID) = target.provenance else {
                    throw TransitionError.invalidProvenance
                }
            } else {
                guard fact.kind != .targetObserved else {
                    throw TransitionError.invalidProvenance
                }
            }
        }
        switch outcome {
        case .verified(let evidence):
            guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TransitionError.emptyEvidence
            }
            entries[index].status = .succeeded(attemptID: attemptID, evidence: evidence)
        case .verifiedFact(let fact):
            try validate(fact)
            entries[index].verifiedFacts.append(fact)
            entries[index].status = .succeeded(attemptID: attemptID, evidence: fact.evidence)
        case .partial(let evidence, let blockedReason, let verifiedFacts):
            guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !blockedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TransitionError.emptyEvidence
            }
            for fact in verifiedFacts { try validate(fact) }
            entries[index].verifiedFacts.append(contentsOf: verifiedFacts)
            entries[index].status = .partial(attemptID: attemptID, evidence: evidence,
                                             blockedReason: blockedReason)
        case .blocked(let reason):
            entries[index].status = .blocked(attemptID: attemptID, reason: reason)
        case .cancelled(let reason):
            entries[index].status = .cancelled(reason: reason)
        case .failed(let reason):
            entries[index].status = .failed(attemptID: attemptID, reason: reason)
        case .uncertain(let reason):
            entries[index].status = .uncertain(attemptID: attemptID, reason: reason)
        }
        trimResolvedHistory()
    }

    mutating func cancel(intentID: UUID, reason: String = "cancelled") throws {
        guard let index = entries.firstIndex(where: { $0.intent.id == intentID }) else {
            throw TransitionError.unknownIntent
        }
        if case .executing = entries[index].status {
            throw TransitionError.invalidTransition
        }
        // Resolved outcomes are terminal: rewriting them would bump the
        // revision that bound the intent's verified facts and let a late
        // cancel erase a recorded result.
        guard !entries[index].status.isResolved else {
            throw TransitionError.invalidTransition
        }
        entries[index].question = nil
        entries[index].revision += 1
        entries[index].status = .cancelled(reason: reason)
        trimResolvedHistory()
    }

    /// An uncertain attempt may be retried in place: the intent re-opens
    /// pending with the SAME revision — a retry is another attempt, not a
    /// revision. Recorded verified facts remain as history; prerequisite
    /// satisfaction still requires a revision-current fact.
    mutating func retryUncertain(intentID: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.intent.id == intentID }) else {
            throw TransitionError.unknownIntent
        }
        guard case .uncertain = entries[index].status else {
            throw TransitionError.invalidTransition
        }
        entries[index].status = .pending
    }

    /// Withdraw the current question and re-open the intent pending — used
    /// when a blocked attempt leaves a fresh clarification to ask.
    mutating func revise(intentID: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.intent.id == intentID }) else {
            throw TransitionError.unknownIntent
        }
        if case .executing = entries[index].status {
            throw TransitionError.invalidTransition
        }
        entries[index].question = nil
        entries[index].revision += 1
        entries[index].status = .pending
    }

    private mutating func trimResolvedHistory() {
        // Preserve the entire ancestor closure of unresolved work.
        var protected = Set(entries.filter { !$0.status.isResolved }.map { $0.intent.id })
        var frontier = Array(protected)
        while let id = frontier.popLast() {
            guard let entry = entry(for: id) else { continue }
            var parents: [UUID] = []
            if let parent = entry.prerequisite?.requiresIntentID { parents.append(parent) }
            switch entry.relationship {
            case .independent: break
            case .refinement(let parent), .continuation(let parent), .correction(let parent):
                parents.append(parent)
            }
            for parent in parents where protected.insert(parent).inserted { frontier.append(parent) }
        }
        var resolved = entries.filter { $0.status.isResolved }.count
        while resolved > resolvedHistoryLimit,
              let oldest = entries.firstIndex(where: { $0.status.isResolved && !protected.contains($0.intent.id) }) {
            entries.remove(at: oldest)
            resolved -= 1
        }
    }
}
