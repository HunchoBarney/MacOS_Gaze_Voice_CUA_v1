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
    private(set) var audio = RangedTranscript()
    var context: () -> JSONValue = { .object([:]) }
    var onChange: () -> Void = {}
    private(set) var outcome = "idle"
    private(set) var message = ""
    private(set) var error: String?
    private(set) var busy = false
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
        error = nil
        message = ""
        outcome = "idle"
    }

    func record(_ snapshot: RangedTranscript) {
        audio = snapshot
    }

    func update(_ text: String, final: Bool) {
        guard text != currentText || final != self.final || inputRevision != audio.revision else { return }
        inputRevision = audio.revision
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
        pendingTask?.cancel()
        pendingTask = nil
        activeHandoffID = nil
        activeHandoff = nil
        generation = UUID()
        error = nil
        message = ""
        scheduleHandoff()
    }

    /// Accept only the source span chosen by the executor for this current snapshot.
    /// The ledger commits the original characters before any selected operation runs.
    @discardableResult
    func consume(_ handoff: TranscriptHandoff, wordRange: Range<Int>) -> Bool {
        guard handoff.captureID == captureID,
              handoff.id == activeHandoffID,
              wordRange.lowerBound == ledger.consumedWordCount,
              wordRange.lowerBound == handoff.pendingWordStart,
              wordRange.upperBound > wordRange.lowerBound,
              wordRange.upperBound <= handoff.pendingWordEnd else { return false }

        let sourceWords = handoff.transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        let currentWords = currentText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard currentWords.count >= wordRange.upperBound,
              Array(sourceWords[wordRange]) == Array(currentWords[wordRange]) else { return false }

        guard hasStableCurrentPrefix(matching: handoff, throughWord: wordRange.upperBound) else { return false }
        // Final recognition freezes words, not their meaning. A new suffix can
        // qualify a request that ended at the old edge; let the executor rejudge
        // that boundary before committing it. Interior boundaries remain usable.
        guard wordRange.upperBound < handoff.pendingWordEnd ||
              currentWords.count == handoff.pendingWordEnd else { return false }

        do {
            _ = try ledger.commit(wordCount: wordRange.count)
        } catch {
            self.error = error.localizedDescription
            outcome = "failure"
            onChange()
            return false
        }
        activeHandoffID = nil
        activeHandoff = nil
        outcome = "handoff"
        message = ""
        scheduleHandoff()
        return true
    }

    /// Preserve an executor's wait/clarification result without consuming its source text.
    func report(_ handoff: TranscriptHandoff, outcome: String, message: String, error: String? = nil) {
        guard handoff.captureID == captureID, handoff.id == activeHandoffID else { return }
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
        busy = false
        return task
    }

    func waitForPending() async {
        while let task = pendingTask {
            await task.value
        }
    }

    private func scheduleHandoff() {
        guard !ledger.pendingWords.isEmpty else {
            busy = false
            activeHandoffID = nil
            activeHandoff = nil
            onChange()
            return
        }
        let snapshot = audio
        let snapshotText = currentText
        let snapshotFinal = final
        let receivedAt = transcriptReceivedAt
        let pendingStart = ledger.consumedWordCount
        let pendingEnd = snapshotText.split(whereSeparator: \.isWhitespace).count
        let ticket = UUID()
        let handoff = TranscriptHandoff(id: UUID(), captureID: captureID, revision: snapshot.revision,
            transcript: snapshotText, pendingWordStart: pendingStart, pendingWordEnd: pendingEnd,
            final: snapshotFinal, receivedAt: receivedAt, audioRanges: snapshot.segments, taskContext: context())
        generation = ticket
        activeHandoffID = handoff.id
        activeHandoff = handoff
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
                guard self.generation == ticket,
                      self.activeHandoffID == handoff.id,
                      self.captureID == handoff.captureID,
                      self.ledger.consumedWordCount == handoff.pendingWordStart,
                      self.matchesCurrentPrefix(matching: handoff, throughWord: handoff.pendingWordEnd) else {
                    self.outcome = "discarded"
                    return
                }
                try await self.submit(handoff)
                try Task.checkCancellation()
                guard self.generation == ticket, self.activeHandoffID == handoff.id else { return }
                // Coalesced updates still need a decision when the old snapshot
                // waited, requested clarification, or could not be consumed.
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
