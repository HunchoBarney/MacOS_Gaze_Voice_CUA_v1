import AppKit
import ApplicationServices
import Foundation

/// Delivers dictated text into the focused editable element — the dictation
/// path, never the planner. First tries the AX selected-text insertion on the
/// focused element (element-scoped, no keystrokes); when no editable element
/// answers, falls back to clipboard+⌘V, which snapshots every pasteboard
/// item's types and restores them after the target has read the paste.
///
/// The transcript runs through a small editing vocabulary first — "new
/// line" inserts a newline, "scratch that" deletes the last inserted
/// segment, "undo that" removes the last whole delivery, and "delete
/// last sentence" cuts back to the previous sentence boundary. Plain
/// text still lands through the same insert → paste path.
struct DictationDelivery: DictationDelivering {
    /// Element-scoped insertion seam (AX in production, stub in tests).
    var insertText: @Sendable (String) -> Bool
    /// Keystroke fallback seam (clipboard+⌘V in production, stub in tests).
    var pasteText: @Sendable (String) async -> Bool
    /// Backward-delete seam — N delete keystrokes in production, stub in
    /// tests. The editing vocabulary has no element-scoped delete, so
    /// removals ride keystrokes like a user's own backspaces.
    var deleteBackward: @Sendable (Int) async -> Bool
    /// Insert history backing the editing vocabulary — a reference box so
    /// the value-typed delivery keeps one continuous session across holds.
    private let history = EditHistory()

    init(insertText: @escaping @Sendable (String) -> Bool = { DictationDelivery.insertAtInsertionPoint($0) },
         pasteText: @escaping @Sendable (String) async -> Bool = { await DictationDelivery.paste($0) },
         deleteBackward: @escaping @Sendable (Int) async -> Bool = { await DictationDelivery.postDeletes($0) }) {
        self.insertText = insertText
        self.pasteText = pasteText
        self.deleteBackward = deleteBackward
    }

    /// Serializes our pasteboard/focus touches against EVERY local input
    /// lane — shared with voice-task dispatch: VoiceTaskCoordinator
    /// borrows this same lease as its `inputGuard`
    /// (`inputGuard = DictationDelivery.sharedLease`), so a drive-loop
    /// focus borrow or clipboard_write can never interleave with a
    /// dictation ⌘V+restore. One lease is the whole guarantee;
    /// cross-process races are the OS's problem.
    static let sharedLease = AsyncLease()

    /// One editing action parsed from a transcript — `insert` carries a
    /// literal segment (newlines included), the rest are removals.
    /// Internal for tests.
    enum EditToken: Equatable {
        case insert(String), scratch, undo, deleteSentence
    }

    /// Transcript → editing actions. Command phrases match
    /// case-insensitively on word boundaries with surrounding punctuation
    /// ignored; unmatched runs join into one insert each. Commands work
    /// standalone or mid-utterance — "one new line two" is a line, a
    /// newline, another line. Internal for tests.
    static func editTokens(_ transcript: String) -> [EditToken] {
        var tokens: [EditToken] = []
        var pending: [String] = []
        func flush() {
            guard !pending.isEmpty else { return }
            tokens.append(.insert(pending.joined(separator: " ")))
            pending = []
        }
        let words = transcript.split(whereSeparator: \.isWhitespace)
        func stripped(_ word: Substring) -> String {
            String(word).lowercased()
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }
        var i = words.startIndex
        while i < words.endIndex {
            let rest = words[i...]
            if rest.count >= 3,
               stripped(rest[rest.startIndex]) == "delete",
               stripped(rest[rest.index(after: rest.startIndex)]) == "last",
               stripped(rest[rest.index(rest.startIndex, offsetBy: 2)]) == "sentence" {
                flush(); tokens.append(.deleteSentence)
                i = rest.index(rest.startIndex, offsetBy: 3); continue
            }
            if rest.count >= 2 {
                let first = stripped(rest[rest.startIndex])
                let second = stripped(rest[rest.index(after: rest.startIndex)])
                if first == "scratch", second == "that" {
                    flush(); tokens.append(.scratch)
                    i = rest.index(rest.startIndex, offsetBy: 2); continue
                }
                if first == "undo", second == "that" {
                    flush(); tokens.append(.undo)
                    i = rest.index(rest.startIndex, offsetBy: 2); continue
                }
                if first == "new", second == "line" {
                    flush(); tokens.append(.insert("\n"))
                    i = rest.index(rest.startIndex, offsetBy: 2); continue
                }
            }
            if stripped(rest[rest.startIndex]) == "newline" {
                flush(); tokens.append(.insert("\n"))
                i = rest.index(after: rest.startIndex); continue
            }
            pending.append(String(rest[rest.startIndex]))
            i = rest.index(after: rest.startIndex)
        }
        flush()
        return tokens
    }

    /// What got inserted, oldest first — units split at every vocabulary
    /// command, and each deliver() call stamps its own group so "undo
    /// that" can remove a whole utterance while "scratch that" removes
    /// just the last piece. Deletions ride Character counts, matching the
    /// delete-keystroke seam.
    final class EditHistory: @unchecked Sendable {
        private let lock = NSLock()
        private var units: [(group: Int, text: String)] = []
        private var nextGroup = 0
        /// Cap the ledger — a segment forgotten beats deleting stale text
        /// from a field the user has edited by hand since.
        private static let unitCap = 200

        func beginGroup() -> Int {
            lock.lock(); defer { lock.unlock() }
            let group = nextGroup; nextGroup += 1
            return group
        }
        func record(_ text: String, group: Int) {
            guard !text.isEmpty else { return }
            lock.lock()
            units.append((group, text))
            if units.count > Self.unitCap { units.removeFirst(units.count - Self.unitCap) }
            lock.unlock()
        }
        /// "scratch that" — the last single unit's Character count.
        func popLast() -> Int {
            lock.lock(); defer { lock.unlock() }
            guard let last = units.popLast() else { return 0 }
            return last.text.count
        }
        /// "undo that" — every unit of the most recent delivery.
        func popLastGroup() -> Int {
            lock.lock(); defer { lock.unlock() }
            guard let group = units.last?.group else { return 0 }
            var chars = 0
            while let last = units.last, last.group == group {
                chars += last.text.count
                units.removeLast()
            }
            return chars
        }
        /// "delete last sentence" — the trailing fragment after the last
        /// sentence boundary (. ! ? or newline) that still has text
        /// following it; no usable boundary means the whole history is
        /// one sentence.
        func popSentence() -> Int {
            lock.lock(); defer { lock.unlock() }
            let full = units.map(\.text).joined()
            guard let lastText = full.lastIndex(where: { !Self.isTerminator($0) }) else {
                let n = full.count
                units.removeAll()
                return n
            }
            let head = full[..<lastText]
            guard let boundary = head.lastIndex(where: { Self.isTerminator($0) }) else {
                let n = full.count
                units.removeAll()
                return n
            }
            return popChars(full.distance(from: full.index(after: boundary), to: full.endIndex))
        }
        private static func isTerminator(_ c: Character) -> Bool {
            c == "." || c == "!" || c == "?" || c == "\n"
        }
        /// Removes `n` trailing Characters across units — the top unit
        /// may be only partly consumed, so trim it in place.
        private func popChars(_ n: Int) -> Int {
            var need = n, removed = 0
            while need > 0, let last = units.last {
                if last.text.count <= need {
                    removed += last.text.count
                    need -= last.text.count
                    units.removeLast()
                } else {
                    var trimmed = last.text
                    trimmed.removeLast(need)
                    units[units.count - 1] = (last.group, trimmed)
                    removed += need
                    need = 0
                }
            }
            return removed
        }
    }

    func deliver(_ text: String) async throws {
        let tokens = Self.editTokens(text)
        guard !tokens.isEmpty else { return }
        let group = history.beginGroup()
        // The acquire is raced — AsyncLease.acquire() is not
        // cancellation-aware, so a cancelled waiter would still take the
        // release() handoff and paste into whatever the user moved on to.
        guard await Self.acquireSharedLease() else { throw CancellationError() }
        // A cancel that raced the handoff still must not paste — only the
        // restore half of a paste already in flight is allowed to run.
        var ok = false
        var attempted = false
        if !Task.isCancelled {
            for token in tokens {
                if Task.isCancelled { break }
                switch token {
                case .insert(let segment):
                    attempted = true
                    var done = insertText(segment)
                    if !done { done = await pasteText(segment) }
                    if done { history.record(segment, group: group) }
                    ok = ok || done
                case .scratch:
                    let count = history.popLast()
                    guard count > 0 else { continue }
                    attempted = true
                    ok = (await deleteBackward(count)) || ok
                case .undo:
                    let count = history.popLastGroup()
                    guard count > 0 else { continue }
                    attempted = true
                    ok = (await deleteBackward(count)) || ok
                case .deleteSentence:
                    let count = history.popSentence()
                    guard count > 0 else { continue }
                    attempted = true
                    ok = (await deleteBackward(count)) || ok
                }
            }
        }
        await Self.sharedLease.release()
        try Task.checkCancellation()
        // A transcript of pure commands with nothing left to remove is a
        // successful no-op, not a lost paste; a failed insert still throws.
        if ok || !attempted { return }
        throw VoiceError("No editable field is focused for dictation.")
    }

    /// Cancellation-aware acquire. AsyncLease hands a released lease to
    /// its oldest parked waiter regardless of that waiter's cancellation,
    /// so abandoning the await isn't enough — when cancel wins the race,
    /// the still-landing acquire must hand the lease straight on or
    /// `held` would stay true forever and every later delivery wedges.
    private static func acquireSharedLease() async -> Bool {
        guard !Task.isCancelled else { return false }
        let race = DeliveryRace()
        Task {
            await Self.sharedLease.acquire()
            if !race.finish(true) {
                // The waiter left before the handoff — we own the lease
                // now; pass it to the next waiter (or mark it free).
                await Self.sharedLease.release()
            }
        }
        return await race.result(fallback: false)
    }

    /// First-finisher race — the same shape as VoiceController's
    /// CancellationRace; a small duplicate beats reaching across lanes
    /// for a helper.
    private final class DeliveryRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var outcome: Bool?
        private var settled = false
        /// Returns false when the race was already settled — the result
        /// goes unconsumed and the caller owns whatever it represented.
        @discardableResult
        func finish(_ value: Bool) -> Bool {
            lock.lock()
            if settled { lock.unlock(); return false }
            settled = true; outcome = value
            let pending = continuation; continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
            return true
        }
        func result(fallback: Bool) async -> Bool {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                    lock.lock()
                    if settled, let outcome { lock.unlock(); c.resume(returning: outcome) }
                    else { continuation = c; lock.unlock() }
                }
            } onCancel: { finish(fallback) }
        }
    }

    /// Setting the focused element's AXSelectedText inserts at the insertion
    /// point and preserves the app's own undo stack — the AX equivalent of
    /// typing without moving the selection.
    static func insertAtInsertionPoint(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return AXUIElementSetAttributeValue(value as! AXUIElement,
            kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    /// Snapshot → set dictated text → ⌘V → restore. The restore waits out a
    /// settle beat so the frontmost app has consumed the paste before the
    /// user's prior clipboard contents go back. Residual race: the settle is
    /// a heuristic, not proof — a target that reads the pasteboard unusually
    /// late can still paste the restored clipboard instead of the dictated
    /// text. No reader-side signal can close that window; the changeCount
    /// check below only prevents the reverse corruption (restoring over a
    /// newer clipboard written by someone else).
    static func paste(_ text: String) async -> Bool {
        let board = NSPasteboard.general
        let prior = snapshot(of: board)
        board.clearContents()
        board.setString(text, forType: .string)
        guard postCommandV() else {
            restore(prior, to: board)
            return false
        }
        let written = board.changeCount
        try? await Task.sleep(for: .milliseconds(400))
        // Another writer claimed the board after our paste — restoring the
        // snapshot would destroy their copy, so the residue stays instead.
        guard board.changeCount == written else { return true }
        restore(prior, to: board)
        return true
    }

    static func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// N backward-delete keystrokes (kVK_Delete) at the insertion point —
    /// the editing vocabulary's removal half. AX has no "select previous
    /// N characters" that works everywhere the ⌘V fallback does, so
    /// removals ride keystrokes; a brief settle every batch lets the
    /// target consume instead of coalescing surprises.
    static func postDeletes(_ count: Int) async -> Bool {
        guard count > 0,
              let source = CGEventSource(stateID: .hidSystemState) else { return false }
        for i in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            else { return false }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if i % 16 == 15 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        return true
    }

    /// Every item × every declared type — the pasteboard is the user's data,
    /// so dictation preserves all of it, not just the string flavor.
    static func snapshot(of board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [:]) { types, type in
                if let data = item.data(forType: type) { types[type] = data }
            }
        }
    }

    static func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        board.clearContents()
        let items = snapshot.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
