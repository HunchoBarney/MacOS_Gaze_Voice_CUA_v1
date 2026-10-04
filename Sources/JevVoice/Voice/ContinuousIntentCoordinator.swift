import Foundation
import JevVoiceCore

struct TranscriptHandoff: Sendable, Equatable {
    let id: UUID
    let captureID: UUID
    let revision: Int
    let transcript: String
    let pendingWordStart: Int
    let pendingWordEnd: Int
    let final: Bool
    let receivedAt: Double
    let audioRanges: [SpeechRevision]
    let taskContext: JSONValue
    let contextRevision: Int
    let contextReadSet: [String]

    init(id: UUID, captureID: UUID, revision: Int, transcript: String, pendingWordStart: Int, pendingWordEnd: Int,
         final: Bool, receivedAt: Double, audioRanges: [SpeechRevision], taskContext: JSONValue,
         contextRevision: Int = 0, contextReadSet: [String] = []) {
        self.id = id
        self.captureID = captureID
        self.revision = revision
        self.transcript = transcript
        self.pendingWordStart = pendingWordStart
        self.pendingWordEnd = pendingWordEnd
        self.final = final
        self.receivedAt = receivedAt
        self.audioRanges = audioRanges
        self.taskContext = taskContext
        self.contextRevision = contextRevision
        self.contextReadSet = contextReadSet
    }

    /// Freshness is tracked only when the producer named the context members the decision may depend on.
    var tracksFreshness: Bool { !contextReadSet.isEmpty }

    func text(in wordRange: Range<Int>) throws -> String {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        guard wordRange.lowerBound >= 0, wordRange.upperBound > wordRange.lowerBound,
              wordRange.upperBound <= words.count else { throw SpeechConsumption.Failure.invalidBoundary }
        let lower = words[wordRange.lowerBound].startIndex
        let upper = words[wordRange.upperBound - 1].endIndex
        return String(transcript[lower..<upper])
    }

    func provenance(for wordRange: Range<Int>) -> SpeechProvenance {
        SpeechProvenance(captureID: captureID, revision: revision, wordStart: wordRange.lowerBound,
                         wordEnd: wordRange.upperBound, audioRanges: audioRanges)
    }
}

/// Transports authoritative transcript snapshots and owns their capture/revision lifecycle.
/// Jev selects semantic spans and operations inside the Cua task executor.
@MainActor
final class ContinuousIntentCoordinator {
    struct SemanticContext: Sendable, Equatable {
        let taskContext: JSONValue
        let revision: Int
        let readSet: [String]

        /// `readSet` names taskContext key paths the pending decision may depend on;
        /// only those member values decide freshness. CuaVoiceRuntime is the sole producer.
        init(taskContext: JSONValue, revision: Int = 0, readSet: [String] = []) {
            self.taskContext = taskContext
            self.revision = revision
            self.readSet = readSet
        }

        var tracksFreshness: Bool { !readSet.isEmpty }
    }

    struct SourceAcceptance: Sendable, Equatable {
        let handoff: TranscriptHandoff
        let wordRange: Range<Int>
        let text: String
        let provenance: SpeechProvenance
    }

    typealias Submit = (TranscriptHandoff) async throws -> Void
    private let submit: Submit
    private var ledger = SpeechConsumption()
    private var generation = UUID()
    private var pendingTask: Task<Void, Never>?
    private var final = false
    private var currentText = ""
    private var inputRevision = -1
    private var transcriptReceivedAt = ProcessInfo.processInfo.systemUptime
    private var captureID = UUID()
    private var activeHandoffID: UUID?
    private var activeHandoff: TranscriptHandoff?
    private var activeRefreshCount = 0
    private(set) var audio = RangedTranscript()
    var context: () -> JSONValue = { .object([:]) }
    var semanticContext: () -> SemanticContext = { .init(taskContext: .object([:])) }
    var onChange: () -> Void = {}
    private(set) var outcome = "idle"
    private(set) var message = ""
    private(set) var error: String?
    private(set) var busy = false
    /// Finality last seen over the pending span — a volatile span that
    /// finalizes with identical text is still a semantic change worth a fresh
    /// decision, so the early-return guard compares it every update.
    private var lastSeenPendingFinal = false
    var remainder: String { ledger.pending }

    init(submit: @escaping Submit) {
        self.submit = submit
    }

    func begin(captureID: UUID = UUID()) {
        cancel()
        self.captureID = captureID
        audio = RangedTranscript()
        ledger = SpeechConsumption()
        final = false
        currentText = ""
        inputRevision = -1
        transcriptReceivedAt = ProcessInfo.processInfo.systemUptime
        activeHandoffID = nil
        activeHandoff = nil
        activeRefreshCount = 0
        error = nil
        message = ""
        outcome = "idle"
        lastSeenPendingFinal = false
    }

    func record(_ snapshot: RangedTranscript) {
        audio = snapshot
    }

    func update(_ text: String, final: Bool) {
        // Finality over the pending span is semantic state: identical text
        // that finalizes still re-decides. A parked dictation hold is the one
        // exception — it only lifts on release, so a mid-hold finality flip
        // would decide again just to re-park the same literal.
        let pendingFinal = audio.isFinal(throughWord:
            text.split(whereSeparator: \.isWhitespace).count)
        let parkedDictation = outcome == "dictationWaitingForFinal" && !final
        let finalityChanged = pendingFinal != lastSeenPendingFinal && !parkedDictation
        guard text != currentText || final != self.final
                || inputRevision != audio.revision || finalityChanged else { return }
        inputRevision = audio.revision
        lastSeenPendingFinal = pendingFinal
        transcriptReceivedAt = ProcessInfo.processInfo.systemUptime
        do {
            try ledger.update(text)
        } catch {
            cancel()
            self.error = error.localizedDescription
            outcome = "failure"
            onChange()
            return
        }
        let preserveDecision = activeHandoff.flatMap { handoff in
            canPreserve(handoff, for: text, final: final) ? handoff : nil
        }
        currentText = text
        self.final = final
        if preserveDecision != nil {
            onChange()
            return
        }
        // Only fresh pending work resets the surface — a release with no new
        // words must leave the published outcome (a refusal, a clarification)
        // visible instead of blanking it back to the last task's message.
        cancelPendingHandoff()
        if !ledger.pendingWords.isEmpty {
            error = nil
            message = ""
        }
        scheduleHandoff()
    }

    /// Notify that semantic state used by Jev routing changed. Progress-only updates are intentionally ignored.
    /// A refresh happens only when a member named by the handoff's read set actually changed; an unchanged
    /// snapshot — matching revision, or a revision bump outside the read set — never rejudges pending input.
    func semanticStateChanged(progressOnly: Bool = false) {
        guard !progressOnly, pendingTask != nil, let handoff = activeHandoff else { return }
        guard relevantContextChanged(from: handoff, to: currentSemanticContext()) else { return }
        refreshOrClarifyActiveHandoff(refreshCount: activeRefreshCount)
    }

    /// Validate the source span selected by the executor without mutating the ledger.
    func validateSource(_ handoff: TranscriptHandoff, wordRange: Range<Int>) -> SourceAcceptance? {
        guard handoff.captureID == captureID,
              handoff.id == activeHandoffID,
              wordRange.lowerBound == ledger.consumedWordCount,
              wordRange.lowerBound == handoff.pendingWordStart,
              wordRange.upperBound > wordRange.lowerBound,
              wordRange.upperBound <= handoff.pendingWordEnd else { return nil }

        let sourceWords = handoff.transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        let currentWords = currentText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard currentWords.count >= wordRange.upperBound,
              Array(sourceWords[wordRange]) == Array(currentWords[wordRange]) else { return nil }

        guard hasStableCurrentPrefix(matching: handoff, throughWord: wordRange.upperBound) else { return nil }
        guard wordRange.upperBound < handoff.pendingWordEnd ||
              currentWords.count == handoff.pendingWordEnd else { return nil }

        guard isFresh(handoff) else { return nil }
        guard !refreshRelevantContextIfNeeded(for: handoff, ticket: generation, refreshCount: activeRefreshCount) else { return nil }
        guard isFresh(handoff) else { return nil }
        guard let text = try? handoff.text(in: wordRange) else { return nil }
        return SourceAcceptance(handoff: handoff, wordRange: wordRange, text: text,
                                provenance: handoff.provenance(for: wordRange))
    }

    /// Commit a previously validated source span and explicitly schedule the remaining speech.
    @discardableResult
    func commit(_ acceptance: SourceAcceptance, scheduleRemainder: Bool = true) -> Bool {
        guard validateSource(acceptance.handoff, wordRange: acceptance.wordRange) == acceptance else { return false }
        do {
            _ = try ledger.commit(wordCount: acceptance.wordRange.count)
        } catch {
            self.error = error.localizedDescription
            outcome = "failure"
            onChange()
            return false
        }
        activeHandoffID = nil
        activeHandoff = nil
        activeRefreshCount = 0
        outcome = "handoff"
        message = ""
        if scheduleRemainder { scheduleRemaining() }
        return true
    }

    /// Resume processing remaining speech after committing with scheduleRemainder: false.
    func resumePending() {
        scheduleRemaining()
    }

    func scheduleRemaining() {
        scheduleHandoff()
    }

    /// Accept only the source span chosen by the executor for this current snapshot.
    /// The ledger commits the original characters before any selected operation runs.
    @discardableResult
    func consume(_ handoff: TranscriptHandoff, wordRange: Range<Int>) -> Bool {
        guard let acceptance = validateSource(handoff, wordRange: wordRange) else { return false }
        return commit(acceptance, scheduleRemainder: true)
    }

    /// Preserve an executor's wait/clarification result without consuming its source text.
    func report(_ handoff: TranscriptHandoff, outcome: String, message: String, error: String? = nil) {
        guard handoff.captureID == captureID, handoff.id == activeHandoffID else { return }
        self.outcome = outcome
        self.message = message
        self.error = error
        onChange()
    }

    /// Present an outcome after its handoff has already been committed — e.g. a
    /// clarification whose question is now owned by dialogue state rather than
    /// by unconsumed speech.
    func publishOutcome(_ outcome: String, message: String, error: String? = nil) {
        self.outcome = outcome
        self.message = message
        self.error = error
        onChange()
    }

    func reviewRemainder(_ text: String) throws -> String {
        cancel()
        try ledger.update(text)
        currentText = text
        return ledger.pending
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        let task = pendingTask
        generation = UUID()
        task?.cancel()
        pendingTask = nil
        activeHandoffID = nil
        activeHandoff = nil
        activeRefreshCount = 0
        busy = false
        return task
    }

    func waitForPending() async {
        while let task = pendingTask {
            await task.value
        }
    }

    private func cancelPendingHandoff() {
        generation = UUID()
        pendingTask?.cancel()
        pendingTask = nil
        activeHandoffID = nil
        activeHandoff = nil
        busy = false
    }

    private func scheduleHandoff(refreshCount: Int = 0) {
        guard !ledger.pendingWords.isEmpty else {
            busy = false
            activeHandoffID = nil
            activeHandoff = nil
            activeRefreshCount = 0
            onChange()
            return
        }
        let snapshot = audio
        let snapshotText = currentText
        let snapshotFinal = final
        let receivedAt = transcriptReceivedAt
        let pendingStart = ledger.consumedWordCount
        let pendingEnd = snapshotText.split(whereSeparator: \.isWhitespace).count
        let contextSnapshot = currentSemanticContext()
        let ticket = UUID()
        let handoff = TranscriptHandoff(id: UUID(), captureID: captureID, revision: snapshot.revision,
            transcript: snapshotText, pendingWordStart: pendingStart, pendingWordEnd: pendingEnd,
            final: snapshotFinal, receivedAt: receivedAt, audioRanges: snapshot.segments,
            taskContext: contextSnapshot.taskContext, contextRevision: contextSnapshot.revision,
            contextReadSet: contextSnapshot.readSet)
        generation = ticket
        activeHandoffID = handoff.id
        activeHandoff = handoff
        activeRefreshCount = refreshCount
        busy = true
        outcome = "candidate"
        message = "Processing transcript…"
        error = nil
        pendingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == ticket {
                    self.busy = false
                    self.pendingTask = nil
                    self.onChange()
                }
            }
            do {
                if !snapshotFinal && !snapshot.isFinal(throughWord: pendingEnd) {
                    let remaining = max(0, 0.35 - (ProcessInfo.processInfo.systemUptime - receivedAt))
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                }
                try Task.checkCancellation()
                guard self.isCurrent(handoff, ticket: ticket) else {
                    self.outcome = "discarded"
                    return
                }
                if self.refreshRelevantContextIfNeeded(for: handoff, ticket: ticket, refreshCount: refreshCount) { return }
                try await self.submit(handoff)
                try Task.checkCancellation()
                guard self.generation == ticket, self.activeHandoffID == handoff.id else { return }
                guard self.isFresh(handoff) else {
                    _ = self.refreshRelevantContextIfNeeded(for: handoff, ticket: ticket, refreshCount: refreshCount)
                    return
                }
                if self.refreshRelevantContextIfNeeded(for: handoff, ticket: ticket, refreshCount: refreshCount) { return }
                if self.error == nil,
                   self.currentText != handoff.transcript || self.final != handoff.final || self.inputRevision != handoff.revision {
                    self.scheduleHandoff()
                    return
                }
                if self.outcome == "candidate" { self.outcome = "handoff" }
            } catch is CancellationError {
                if self.generation == ticket { self.outcome = "discarded" }
            } catch {
                if self.generation == ticket {
                    self.outcome = "failure"
                    self.error = "Transcript handoff failed: " + error.localizedDescription
                }
            }
        }
        onChange()
    }

    private func currentSemanticContext() -> SemanticContext {
        let semantic = semanticContext()
        if semantic == SemanticContext(taskContext: .object([:])) {
            return SemanticContext(taskContext: context())
        }
        return semantic
    }

    private func isCurrent(_ handoff: TranscriptHandoff, ticket: UUID) -> Bool {
        generation == ticket &&
            activeHandoffID == handoff.id &&
            captureID == handoff.captureID &&
            ledger.consumedWordCount == handoff.pendingWordStart &&
            matchesCurrentPrefix(matching: handoff, throughWord: handoff.pendingWordEnd)
    }

    private func refreshRelevantContextIfNeeded(for handoff: TranscriptHandoff, ticket: UUID, refreshCount: Int) -> Bool {
        let latest = currentSemanticContext()
        guard relevantContextChanged(from: handoff, to: latest) else { return false }
        guard generation == ticket, activeHandoffID == handoff.id else { return false }
        refreshOrClarifyActiveHandoff(refreshCount: refreshCount, ticket: ticket)
        return true
    }

    private func isFresh(_ handoff: TranscriptHandoff) -> Bool {
        !relevantContextChanged(from: handoff, to: currentSemanticContext())
    }

    private func refreshOrClarifyActiveHandoff(refreshCount: Int, ticket: UUID? = nil) {
        // A stale ticket must not mutate scheduler state: check it before anything else.
        if let ticket, generation != ticket { return }
        guard refreshCount < 2 else {
            generation = UUID()
            if pendingTask != nil { pendingTask?.cancel() }
            pendingTask = nil
            activeHandoffID = nil
            activeHandoff = nil
            activeRefreshCount = 0
            busy = false
            outcome = "clarification"
            message = "Context changed repeatedly while reviewing speech. Please repeat the request."
            error = nil
            onChange()
            return
        }
        generation = UUID()
        if pendingTask != nil { pendingTask?.cancel() }
        pendingTask = nil
        busy = false
        scheduleHandoff(refreshCount: refreshCount + 1)
    }

    private func relevantContextChanged(from handoff: TranscriptHandoff, to latest: SemanticContext) -> Bool {
        guard handoff.tracksFreshness || latest.tracksFreshness else { return false }
        for key in handoff.contextReadSet where handoff.taskContext.value(at: key) != latest.taskContext.value(at: key) {
            return true
        }
        return false
    }

    private func canPreserve(_ handoff: TranscriptHandoff, for text: String, final: Bool) -> Bool {
        guard pendingTask != nil, activeHandoffID == handoff.id,
              handoff.captureID == captureID,
              handoff.pendingWordStart == ledger.consumedWordCount else { return false }
        let oldWords = handoff.transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        let newWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard newWords.count > handoff.pendingWordEnd,
              oldWords.count >= handoff.pendingWordEnd,
              Array(oldWords[..<handoff.pendingWordEnd]) == Array(newWords[..<handoff.pendingWordEnd]),
              Self.snapshotHasFinalPrefix(handoff, throughWord: handoff.pendingWordEnd) else { return false }
        return hasStableCurrentPrefix(matching: handoff, throughWord: handoff.pendingWordEnd, text: text, final: final)
    }

    private func hasStableCurrentPrefix(matching handoff: TranscriptHandoff, throughWord count: Int,
                                        text: String? = nil, final: Bool? = nil) -> Bool {
        let currentText = text ?? self.currentText
        let isFinal = final ?? self.final
        let currentWords = currentText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard matchesCurrentPrefix(matching: handoff, throughWord: count, text: currentText) else { return false }
        guard !audio.segments.isEmpty else {
            return isFinal && currentText == handoff.transcript
        }
        let audioWords = audio.text.split(whereSeparator: \.isWhitespace).map(String.init)
        return audio.isFinal(throughWord: count) && audioWords.count >= count &&
            Array(audioWords[..<count]) == Array(currentWords[..<count])
    }

    private func matchesCurrentPrefix(matching handoff: TranscriptHandoff, throughWord count: Int,
                                      text: String? = nil) -> Bool {
        let currentWords = (text ?? currentText).split(whereSeparator: \.isWhitespace).map(String.init)
        let sourceWords = handoff.transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        guard count > 0, sourceWords.count >= count, currentWords.count >= count else { return false }
        return Array(sourceWords[..<count]) == Array(currentWords[..<count])
    }

    private static func snapshotHasFinalPrefix(_ handoff: TranscriptHandoff, throughWord count: Int) -> Bool {
        var snapshot = RangedTranscript()
        do {
            for range in handoff.audioRanges { try snapshot.apply(range) }
        } catch {
            return false
        }
        return snapshot.text == handoff.transcript && snapshot.isFinal(throughWord: count)
    }
}

private extension JSONValue {
    func value(at path: String) -> JSONValue? {
        let parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return self }
        var current: JSONValue? = self
        for part in parts {
            guard case .object(let object)? = current else { return nil }
            current = object[part]
        }
        return current
    }
}
