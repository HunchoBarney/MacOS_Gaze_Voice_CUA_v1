import AppKit
import ApplicationServices
import Foundation
import JarvisCore

/// Presses macOS can take back, and how. The owner's rule (KAR-69): where
/// the app itself can undo a press, Jarvis presses and then offers undo
/// ("Moved to Trash. Say undo to bring it back.") instead of asking first.
/// Everything this registry doesn't name keeps asking: Pay, Call, Allow,
/// account changes, presses with no name, permanent deletes, and sends
/// outside Mail.
///
/// Every route goes through the app's own undo command, the menu item
/// bound to ⌘Z. Jarvis reads that item's title over Accessibility before
/// and after the press, so an offer stands only when the press put a new
/// action on top of the app's undo stack, and a spoken "undo" invokes that
/// exact item in that app, never whatever happens to be in front.
enum UndoRegistry {
    enum Kind: String, Sendable {
        /// Finder's Move to Trash. Undo puts the item back where it was.
        case putBack
        /// Mail's Delete or Move to Trash, and Delete in a document app.
        case delete
        /// Mail's Archive.
        case archive
        /// Mail's Undo Send, inside its send delay.
        case unsend
    }

    struct Route: Sendable, Equatable {
        let kind: Kind
        /// The longest the offer can stand after the press, when the app
        /// sets one (Mail sends the message once its delay runs out).
        let deadline: TimeInterval?

        /// Only a delete or a send can skip its question. Pay, Call, Allow,
        /// account changes and unnamed presses ask whatever route a caller
        /// passes.
        func covers(_ consequence: Consequence) -> Bool {
            switch kind {
            case .unsend: return consequence == .send
            case .putBack, .delete: return consequence == .delete
            case .archive: return false
            }
        }

        /// What Jarvis says after the press.
        var offer: String {
            switch kind {
            case .putBack: return "Moved to Trash. Say \u{201C}undo\u{201D} to bring it back."
            case .delete: return "Deleted. Say \u{201C}undo\u{201D} to bring it back."
            case .archive: return "Archived. Say \u{201C}undo\u{201D} to bring it back."
            case .unsend: return "Sent. Say \u{201C}undo\u{201D} to unsend it."
            }
        }

        /// What Jarvis says once the undo took.
        var undone: String {
            switch kind {
            case .putBack: return "Put it back."
            case .delete, .archive: return "Brought it back."
            case .unsend: return "Unsent. The message is open again."
            }
        }
    }

    /// How long a spoken "undo" stays open after Jarvis offers it.
    static let offerWindow: TimeInterval = 10
    /// Time kept back from Mail's send delay for the offer to be spoken.
    static let unsendMargin: TimeInterval = 3

    static let finder = "com.apple.finder"
    static let mail = "com.apple.mail"
    /// Apps whose Delete lands on their own undo stack, so ⌘Z restores it.
    static let documentApps: Set<String> = [
        "com.apple.notes", "com.apple.textedit", "com.apple.iwork.pages",
        "com.apple.iwork.numbers", "com.apple.iwork.keynote",
    ]
    /// Words that make a delete permanent or wholesale: these keep asking
    /// (or, like Empty Trash, stay on the never list).
    private static let permanentWords: Set<String> = [
        "immediately", "permanently", "forever", "all", "erase", "empty", "everything",
    ]

    /// The undo route for pressing this control in this app, or nil when
    /// nothing reliable can take it back. `mailUndoSendDelay` is Mail's
    /// send delay in seconds, nil when unknown.
    static func route(tool: String, args: [String: JSONValue], label: String, bundleID: String?,
                      mailUndoSendDelay: () -> TimeInterval?) -> Route? {
        guard let bundle = bundleID?.lowercased() else { return nil }
        let words = Set(CuaPolicy.normalize(label.lowercased()).split(separator: " ").map(String.init))
        guard words.isDisjoint(with: permanentWords) else { return nil }
        if bundle == mail, words.contains("archive"), CuaPolicy.pressTools.contains(tool) {
            return Route(kind: .archive, deadline: nil)
        }
        guard let press = CuaPolicy.consequentialPress(tool: tool, args: args, elementText: label) else { return nil }
        let phrase = Consequence.match(control: press.coverage)?.phrase
        switch (bundle, press.consequence) {
        case (finder, .delete) where phrase == "move to trash":
            return Route(kind: .putBack, deadline: nil)
        case (mail, .delete) where phrase == "move to trash" || phrase == "delete":
            return Route(kind: .delete, deadline: nil)
        case (mail, .send) where phrase == "send" && !words.contains("later"):
            guard let delay = mailUndoSendDelay(), delay - unsendMargin >= 4 else { return nil }
            return Route(kind: .unsend, deadline: delay - unsendMargin)
        case (_, .delete) where documentApps.contains(bundle) && phrase == "delete":
            return Route(kind: .delete, deadline: nil)
        default:
            return nil
        }
    }

    // MARK: - The app's undo item

    /// The menu item bound to ⌘Z in one app: the menu it sits in, its
    /// title ("Undo Move of “Notes.txt”") and whether it can be chosen.
    struct MenuItem: Sendable, Equatable {
        let menu: String
        let title: String
        let enabled: Bool
    }

    /// Reads the app's ⌘Z item over Accessibility. Found by its key
    /// equivalent, not its words, so it works in every language.
    static func readUndoItem(pid: Int) -> MenuItem? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar = element(app, kAXMenuBarAttribute) else { return nil }
        for barItem in elements(bar, kAXChildrenAttribute) {
            for menu in elements(barItem, kAXChildrenAttribute) {
                for item in elements(menu, kAXChildrenAttribute) {
                    guard (string(item, kAXMenuItemCmdCharAttribute) ?? "").lowercased() == "z",
                          number(item, kAXMenuItemCmdModifiersAttribute) == 0,
                          let title = string(item, kAXTitleAttribute), !title.isEmpty else { continue }
                    return MenuItem(menu: string(barItem, kAXTitleAttribute) ?? "",
                                    title: title, enabled: number(item, kAXEnabledAttribute) == 1)
                }
            }
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let ref = value(element, attribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func number(_ element: AXUIElement, _ attribute: String) -> Int? {
        (value(element, attribute) as? NSNumber)?.intValue
    }

    /// Mail's Undo Send delay in seconds (Mail ▸ Settings ▸ Composing),
    /// stored as `UndoSendDelayTime`. Mail ships with 10 s, so a readable
    /// Mail domain without the key is 10. An unreadable or empty domain is
    /// unknown, and a send then asks.
    static func mailUndoSendDelay() -> TimeInterval? {
        let domain = mail as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else { return nil }
        guard let value = CFPreferencesCopyAppValue("UndoSendDelayTime" as CFString, domain) else { return 10 }
        return (value as? NSNumber)?.doubleValue
    }
}

/// One press Jarvis made without asking, and how to take it back.
struct PendingUndo: Sendable, Equatable {
    let route: UndoRegistry.Route
    let pid: Int
    let windowID: Int
    let bundleID: String
    /// The app's ⌘Z item right after the press. A spoken "undo" runs only
    /// while the app still shows this exact item.
    let item: UndoRegistry.MenuItem
    let pressedAt: Date
    var expiresAt: Date

    init(route: UndoRegistry.Route, pid: Int, windowID: Int, bundleID: String,
         item: UndoRegistry.MenuItem, pressedAt: Date) {
        self.route = route; self.pid = pid; self.windowID = windowID
        self.bundleID = bundleID; self.item = item; self.pressedAt = pressedAt
        self.expiresAt = route.deadline.map { pressedAt.addingTimeInterval($0) } ?? .distantFuture
    }

    /// The offer is spoken now: the window runs `offerWindow` from here,
    /// and never past the app's own deadline.
    func offered(at now: Date) -> PendingUndo {
        var copy = self
        copy.expiresAt = min(expiresAt, now.addingTimeInterval(UndoRegistry.offerWindow))
        return copy
    }
}

/// The one live undo offer, shared between the task that pressed and the
/// next utterance. A newer offer replaces an older one.
final class UndoOffers: Sendable {
    static let shared = UndoOffers()

    private let box = LockedBox<PendingUndo?>(nil)

    func offer(_ pending: PendingUndo) { box.set(pending) }

    /// The live offer, removed so it runs once. An expired offer is dropped.
    func take(now: Date = Date()) -> PendingUndo? {
        let pending = box.value
        box.set(nil)
        guard let pending, now < pending.expiresAt else { return nil }
        return pending
    }

    var current: PendingUndo? { box.value }
}

/// The drive loop's undo seams: the live ones read Accessibility and
/// Mail's preferences; tests serve canned answers.
struct UndoSupport: Sendable {
    var undoItem: @Sendable (Int) async -> UndoRegistry.MenuItem?
    var mailUndoSendDelay: @Sendable () -> TimeInterval?
    var offers: UndoOffers
    var now: @Sendable () -> Date = { Date() }
    var settle: @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 150_000_000) }

    static let live = UndoSupport(undoItem: { UndoRegistry.readUndoItem(pid: $0) },
                                  mailUndoSendDelay: { UndoRegistry.mailUndoSendDelay() },
                                  offers: .shared)
}

extension DriveLoop {
    /// "undo", "undo that", "take that back", "put it back": the fast
    /// lane's ⌘Z phrases, with no app named.
    static func asksToUndo(_ goal: String) -> Bool {
        guard let parsed = FastAction.parse(goal), parsed.appQualifier == nil,
              case .hotkey(let keys, _) = parsed.action.body else { return false }
        return keys == ["cmd", "z"]
    }

    /// Takes back the press Jarvis offered undo for: the app's own ⌘Z item,
    /// by its exact menu path, in the app that was pressed, and only while
    /// the app still shows the item the press left. Anything else since
    /// (a later edit, another undo) means it refuses instead of undoing
    /// the wrong thing. The item changing afterwards is the evidence it
    /// took.
    func runOfferedUndo(_ pending: PendingUndo, task: DriveTask, session: String) async -> DriveResult {
        let name = NSRunningApplication(processIdentifier: pid_t(pending.pid))?.localizedName ?? pending.bundleID
        var history = ["undo offered for \(pending.item.menu) → \(pending.item.title)"]
        guard let current = await undo.undoItem(pending.pid), current == pending.item else {
            feed("undo refused: \(name)'s undo item changed since the press")
            return settle(.blocked("I can't undo that safely now: \(name) has changed since."), task, history,
                          pid: pending.pid, windowID: pending.windowID, bundleID: pending.bundleID,
                          blockedReason: "undo item changed")
        }
        var confirmed = false
        do {
            try await gateExplicit("invoke_menu", corpus: "\(name) \(pending.item.menu) \(pending.item.title)",
                                   denied: task.deny, confirmed: &confirmed)
            try await invokeMenu([pending.item.menu, pending.item.title], pid: pending.pid,
                                 windowID: pending.windowID, name: name, bundle: pending.bundleID,
                                 session: session)
        } catch {
            feed("undo failed: \(error)")
            return settle(.blocked("I couldn't undo that in \(name)."), task, history,
                          pid: pending.pid, windowID: pending.windowID, bundleID: pending.bundleID,
                          blockedReason: "undo failed")
        }
        guard let after = await undo.undoItem(pending.pid), after != pending.item else {
            history.append("chose \(pending.item.title), but the undo item didn't change")
            return settle(.blocked("I chose Undo in \(name), but couldn't tell that it worked."), task, history,
                          pid: pending.pid, windowID: pending.windowID, bundleID: pending.bundleID,
                          blockedReason: "undo unverified")
        }
        history.append(pending.route.undone)
        feed(pending.route.undone)
        var result = settle(.done, task, history, pid: pending.pid, windowID: pending.windowID,
                            bundleID: pending.bundleID, confirmedAny: true)
        result.spoken = pending.route.undone
        return result
    }
}
