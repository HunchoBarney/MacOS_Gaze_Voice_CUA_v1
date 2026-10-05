import AppKit
import ApplicationServices
import Foundation

/// Delivers dictated text into the focused editable element — the Fn+Ctrl
/// path, never the planner. First tries the AX selected-text insertion on the
/// focused element (element-scoped, no keystrokes); when no editable element
/// answers, falls back to clipboard+⌘V, which snapshots every pasteboard
/// item's types and restores them after the target has read the paste.
struct DictationDelivery: DictationDelivering {
    /// Element-scoped insertion seam (AX in production, stub in tests).
    var insertText: @Sendable (String) -> Bool
    /// Keystroke fallback seam (clipboard+⌘V in production, stub in tests).
    var pasteText: @Sendable (String) async -> Bool

    init(insertText: @escaping @Sendable (String) -> Bool = { DictationDelivery.insertAtInsertionPoint($0) },
         pasteText: @escaping @Sendable (String) async -> Bool = { await DictationDelivery.paste($0) }) {
        self.insertText = insertText
        self.pasteText = pasteText
    }

    func deliver(_ text: String) async throws {
        guard !text.isEmpty else { return }
        // Dictation writes to whatever is frontmost and (on the paste
        // path) to the global pasteboard — both are shared lanes. Holding
        // focus for the whole deliver and pasteboard for the paste window
        // keeps a parallel task's raise or ⌘C from redirecting either.
        let workID = "dictation-\(UUID().uuidString.prefix(8))"
        let lanes = CuaLaneRegistry.shared
        try await lanes.acquireFocus(workID: workID)
        var ok = insertText(text)
        if !ok {
            do {
                try await lanes.acquirePasteboard(workID: workID)
                ok = await pasteText(text)
                await lanes.releasePasteboard(workID: workID)
            } catch {
                // A thrown pasteboard acquire must still free the focus
                // lease — every deliver owns a fresh workID, so a skipped
                // release parks the global focus lane behind a holder
                // nothing can ever identify or release.
                await lanes.releaseFocus(workID: workID)
                throw error
            }
        }
        await lanes.releaseFocus(workID: workID)
        if ok { return }
        throw VoiceError("No editable field is focused for dictation.")
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

    /// The focused element's AXValue readback, when the app exposes it as a
    /// string — nil means unreadable, which is never evidence of a failed
    /// write (secure fields and masked editors simply don't mirror it).
    static func focusedElementValue() -> String? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var contents: CFTypeRef?
        guard AXUIElementCopyAttributeValue(value as! AXUIElement,
            kAXValueAttribute as CFString, &contents) == .success,
              let text = contents as? String else { return nil }
        return text
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
