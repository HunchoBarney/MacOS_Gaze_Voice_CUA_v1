import Foundation
import JevVoiceCore

@MainActor
final class ContinuousIntentCoordinator {
    typealias Decide = ([String], Bool, JSONValue) async throws -> SpeechIntent?
    typealias Interpret = ([String], Bool, JSONValue) async throws -> JevSpeechIntent.Understanding
    private let interpret: Interpret
    private let submit: (SpeechIntent) async throws -> Void
    private var ledger = SpeechConsumption()
    private var generation = UUID()
    private var pendingTask: Task<Void, Never>?
    private var literalKind: SpeechIntent.Kind?
    private var final = false
    private var currentText = ""
    private var inputRevision = -1
    private var transcriptReceivedAt = ProcessInfo.processInfo.systemUptime
    private var captureID = UUID()
    private(set) var audio = RangedTranscript()
    var context: () -> JSONValue = { .object([:]) }
    var onChange: () -> Void = {}
    enum Event: String { case candidate, handoff, discarded, incomplete, clarification, noRequest, failure }
    var observe: (Event, SpeechIntent?) -> Void = { _, _ in }
    private(set) var outcome = "idle"
    private(set) var message = ""
    private(set) var error: String?
    private(set) var busy = false
    var remainder: String { ledger.pending }

    init(decide: @escaping Decide, submit: @escaping (SpeechIntent) async throws -> Void) {
        self.interpret = { words, final, context in
            if let intent = try await decide(words, final, context) { return .ready(intent) }
            return .incomplete("Please finish the request or specify its missing information.")
        }
        self.submit = submit
    }
    init(interpret: @escaping Interpret, submit: @escaping (SpeechIntent) async throws -> Void) {
        self.interpret = interpret; self.submit = submit
    }
    func begin(captureID: UUID = UUID()) {
        cancel()
        self.captureID = captureID; audio = RangedTranscript()
        ledger = SpeechConsumption(); literalKind = nil; final = false; currentText = ""; inputRevision = -1; error = nil; message = ""; outcome = "idle"
    }
    func record(_ snapshot: RangedTranscript) { audio = snapshot }
    func update(_ text: String, final: Bool) {
        guard text != currentText || final != self.final || inputRevision != audio.revision else { return }
        inputRevision = audio.revision
        transcriptReceivedAt = ProcessInfo.processInfo.systemUptime
        let previous = ledger.pendingWords
        do { try ledger.update(text) }
        catch { cancel(); self.error = error.localizedDescription; onChange(); return }
        let extendsPrevious = ledger.pendingWords.starts(with: previous)
        currentText = text; self.final = final
        // Growing speech coalesces behind the in-flight judgment. Revisions cancel it.
        if busy && extendsPrevious { return }
        pendingTask?.cancel()
        if !extendsPrevious { literalKind = nil }
        generation = UUID()
        let revision = generation
        busy = true; error = nil; message = ""; outcome = "understanding"
        pendingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == revision { self.busy = false; self.onChange() } }
            do {
                while !self.ledger.pendingWords.isEmpty {
                    try Task.checkCancellation()
                    let words = self.ledger.pendingWords
                    let wasFinal = self.final
                    let inputAudio = self.audio
                    let receivedAt = self.transcriptReceivedAt
                    let understanding: JevSpeechIntent.Understanding
                    if let literalKind = self.literalKind {
                        understanding = .ready(SpeechIntent(kind: literalKind, count: words.count, text: words.joined(separator: " "), literalMode: .dictate))
                    } else { understanding = try await self.interpret(words, wasFinal, self.context()) }
                    guard !Task.isCancelled, self.generation == revision else {
                        self.observe(.discarded, nil); return
                    }
                    let latest = self.ledger.pendingWords
                    let unchanged = latest == words && self.final == wasFinal && self.audio.revision == inputAudio.revision
                    let stablePrefix: Bool
                    if case .ready(let candidate) = understanding {
                        let end = self.ledger.consumedWordCount + candidate.count
                        stablePrefix = candidate.count > 0 && candidate.count < words.count &&
                            latest.starts(with: words.prefix(candidate.count)) &&
                            inputAudio.isFinal(throughWord: end) && self.audio.isFinal(throughWord: end)
                    } else { stablePrefix = false }
                    guard unchanged || stablePrefix else {
                        self.observe(.discarded, nil); continue
                    }
                    let intent: SpeechIntent
                    switch understanding {
                    case .ready(let candidate):
                        intent = candidate
                        self.outcome = "candidate"; self.observe(.candidate, candidate)
                    case .noRequest:
                        intent = SpeechIntent(kind: .ignore, count: words.count, text: words.joined(separator: " "))
                        self.outcome = "noRequest"; self.observe(.noRequest, nil)
                    case .incomplete(let reason):
                        self.outcome = "incomplete"; self.observe(.incomplete, nil)
                        if self.final { self.error = reason } else { self.message = "Listening for the rest of your request…" }
                        return
                    case .clarification(let reason):
                        self.outcome = "clarification"; self.observe(.clarification, nil)
                        if self.final { self.error = reason } else { self.message = reason }
                        return
                    case .limitation(let reason):
                        self.outcome = "limitation"; self.error = reason; return
                    }
                    // A non-action at the current speech edge can still govern later
                    // words ("Don't" + "open Safari") or be revised. Keep that tail
                    // pending until release; a bounded prefix can still make progress.
                    if intent.kind == .ignore && !self.final && intent.count == words.count { return }
                    if intent.literalMode == .dictate { self.literalKind = intent.kind }
                    if intent.literalMode != nil && !self.final {
                        self.message = "Text inserts on release; safe live revision is not available yet."
                        self.onChange(); return
                    }
                    // Finalized segments are stable immediately. Volatile or text-only
                    // input must remain unchanged for 350ms, in addition to semantic
                    // completeness. This is eligibility evidence, never a deadline.
                    if !self.final && !inputAudio.isFinal(throughWord: self.ledger.consumedWordCount + intent.count) {
                        let remaining = max(0, 0.35 - (ProcessInfo.processInfo.systemUptime - receivedAt))
                        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                        try Task.checkCancellation()
                        guard self.generation == revision else { return }
                        if self.ledger.pendingWords != words || self.final != wasFinal || self.audio.revision != inputAudio.revision {
                            self.observe(.discarded, intent); continue
                        }
                    }
                    // Commit before handing off: uncertainty/error must never make this span replayable.
                    let start = self.ledger.consumedWordCount
                    let committed = try self.ledger.commit(wordCount: intent.count)
                    if intent.kind != .ignore {
                        self.outcome = "handoff"; self.observe(.handoff, intent)
                        try await self.submit(SpeechIntent(kind: intent.kind, count: intent.count, text: committed.text, provenance: SpeechProvenance(captureID: self.captureID, revision: inputAudio.revision, wordStart: start, wordEnd: start + intent.count, audioRanges: inputAudio.segments), transcriptReceivedAt: receivedAt, literalMode: intent.literalMode))
                    }
                    try Task.checkCancellation()
                    guard self.generation == revision else { return }
                }
            } catch is CancellationError { self.observe(.discarded, nil) }
            catch { if self.generation == revision { self.outcome = "failure"; self.observe(.failure, nil); self.error = "Voice interpretation failed: " + error.localizedDescription } }
        }
    }
    func reviewRemainder(_ text: String) throws -> String {
        cancel(); try ledger.update(text); return ledger.pending
    }
    func cancel() {
        generation = UUID(); pendingTask?.cancel(); pendingTask = nil; busy = false
    }
    func waitForPending() async { await pendingTask?.value }
}
