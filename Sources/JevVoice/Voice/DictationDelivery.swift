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
        if insertText(text) { return }
        if await pasteText(text) { return }
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

    /// Snapshot → set dictated text → ⌘V → restore. The restore waits out a
    /// short beat so the frontmost app has consumed the paste before the
    /// user's prior clipboard contents go back.
    static func paste(_ text: String) async -> Bool {
        let board = NSPasteboard.general
        let prior = snapshot(of: board)
        board.clearContents()
        board.setString(text, forType: .string)
        guard postCommandV() else {
            restore(prior, to: board)
            return false
        }
        try? await Task.sleep(for: .milliseconds(250))
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
