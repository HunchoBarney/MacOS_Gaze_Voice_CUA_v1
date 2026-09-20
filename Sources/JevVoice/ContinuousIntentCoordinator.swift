import Foundation
import JevVoiceCore

@MainActor
final class ContinuousIntentCoordinator {
    typealias Decide = ([String], Bool, JSONValue) async throws -> SpeechIntent?
    private let decide: Decide
    private let submit: (SpeechIntent) async throws -> Void
    private var ledger = SpeechConsumption()
    private var generation = UUID()
    private var pendingTask: Task<Void, Never>?
    private var literal = false
    private var final = false
    private var currentText = ""
    private var transcriptReceivedAt = ProcessInfo.processInfo.systemUptime
    private var captureID = UUID()
    private var audio = RangedTranscript()
    var context: () -> JSONValue = { .object([:]) }
    var onChange: () -> Void = {}
    private(set) var message = ""
    private(set) var error: String?
    private(set) var busy = false
    var remainder: String { ledger.pending }

    init(decide: @escaping Decide, submit: @escaping (SpeechIntent) async throws -> Void) {
        self.decide = decide; self.submit = submit
    }
    func begin() {
        cancel()
        captureID = UUID(); audio = RangedTranscript()
        ledger = SpeechConsumption(); literal = false; final = false; currentText = ""; error = nil; message = ""
    }
    func record(_ revision: SpeechRevision) {
        do { try audio.apply(revision) }
        catch { cancel(); self.error = "Speech audio ranges changed inconsistently. Release Fn and try again."; onChange() }
    }
    func update(_ text: String, final: Bool) {
        guard text != currentText || final != self.final else { return }
        transcriptReceivedAt = ProcessInfo.processInfo.systemUptime
        let previous = ledger.pendingWords
        do { try ledger.update(text) }
        catch { cancel(); self.error = error.localizedDescription; onChange(); return }
        let extendsPrevious = ledger.pendingWords.starts(with: previous)
        currentText = text; self.final = final
        // Growing speech coalesces behind the in-flight judgment. Revisions cancel it.
        if busy && extendsPrevious { return }
        pendingTask?.cancel()
        if !extendsPrevious { literal = false }
        generation = UUID()
        let revision = generation
        busy = true
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
                    let intent: SpeechIntent?
                    if self.literal {
                        intent = SpeechIntent(kind: .dictate, count: words.count, text: words.joined(separator: " "))
                    } else { intent = try await self.decide(words, wasFinal, self.context()) }
                    try Task.checkCancellation()
                    guard self.generation == revision else { return }
                    let latest = self.ledger.pendingWords
                    guard let intent else {
                        if latest != words || self.final != wasFinal { continue }
                        if self.final { self.error = "I need a clearer or more complete request: " + self.ledger.pending }
                        return
                    }
                    // A command ending at the old transcript edge might acquire another
                    // argument as speech grows. Rejudge it using the newest context.
                    if latest != words && (intent.count >= words.count || !latest.starts(with: words)) { continue }
                    if intent.kind == .dictate { self.literal = true }
                    if (intent.kind == .dictate || intent.kind == .textEntry) && !self.final {
                        self.message = "Text inserts on release; safe live revision is not available yet."
                        self.onChange(); return
                    }
                    // Commit before handing off: uncertainty/error must never make this span replayable.
                    let start = self.ledger.consumedWordCount
                    let committed = try self.ledger.commit(wordCount: intent.count)
                    if intent.kind != .ignore {
                        try await self.submit(SpeechIntent(kind: intent.kind, count: intent.count, text: committed.text, provenance: SpeechProvenance(captureID: self.captureID, revision: inputAudio.revision, wordStart: start, wordEnd: start + intent.count, audioRanges: inputAudio.segments), transcriptReceivedAt: receivedAt))
                    }
                    try Task.checkCancellation()
                    guard self.generation == revision else { return }
                }
            } catch is CancellationError { }
            catch { if self.generation == revision { self.error = error.localizedDescription } }
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
