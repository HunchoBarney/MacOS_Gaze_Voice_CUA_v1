import AppKit
import ApplicationServices
import Foundation

/// Host-side read of a window's native traffic-light controls — the
/// red/yellow/green buttons the driver's element snapshot doesn't expose
/// as clickable candidates. AX position/size arrive in global top-left
/// screen points, the same space `list_windows` bounds and gaze samples
/// already use — no conversion needed to hit-test.
///
/// These are REAL AXButtons with AXPress — pressing them works on
/// backgrounded windows without raising them (the minimize light on a
/// buried window minimizes it where it sits).
enum WindowControls {
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case close, minimize, zoom, fullscreen
        /// The spoken name a model or overlay can offer — "the yellow
        /// minimize button" finally names a real thing.
        var spokenName: String {
            switch self {
            case .close: return "the red close button"
            case .minimize: return "the yellow minimize button"
            case .zoom: return "the green zoom button"
            case .fullscreen: return "the fullscreen control"
            }
        }
    }

    struct Button: Sendable, Equatable {
        var kind: Kind
        /// Global top-left screen points.
        var frame: CGRect
    }

    /// The AX attribute names each kind answers to. Electron/Chromium apps
    /// expose them on the window; some expose `AXFullScreenButton`
    /// separately, most fold it into zoom's subrole.
    private static let attributes: [Kind: String] = [
        .close: kAXCloseButtonAttribute,
        .minimize: kAXMinimizeButtonAttribute,
        .zoom: kAXZoomButtonAttribute,
        .fullscreen: kAXFullScreenButtonAttribute,
    ]

    /// Every exposed window control on `windowElement` — empty on apps
    /// that don't publish them (genuinely absent, not a parse failure).
    /// Injectable `element` factory so tests never open a real AX session.
    static func buttons(on windowElement: AXUIElement) -> [Button] {
        Kind.allCases.compactMap { kind in
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(windowElement,
                                                attributes[kind]! as CFString,
                                                &ref) == .success,
                  let ref else { return nil }
            let button = ref as! AXUIElement
            guard let frame = frame(of: button) else { return nil }
            return Button(kind: kind, frame: frame)
        }
    }

    /// The app's front window's controls — the discovery path the drive
    /// loop uses to offer "the yellow minimize button" as a candidate.
    static func buttons(pid: pid_t) -> [Button] {
        guard let window = frontWindow(pid: pid) else { return [] }
        return buttons(on: window)
    }

    static func buttons(pid: pid_t, windowID: Int) -> [Button] {
        guard let window = windowElement(pid: pid, windowID: windowID) else { return [] }
        return buttons(on: window)
    }

    /// AXPress the control — background-safe, no raise, no focus borrow.
    /// False when the button is absent or the press was refused.
    @discardableResult
    static func press(_ kind: Kind, pid: pid_t) -> Bool {
        guard let window = frontWindow(pid: pid) else { return false }
        return press(kind, on: window)
    }

    @discardableResult
    static func press(_ kind: Kind, pid: pid_t, windowID: Int) -> Bool {
        guard let window = windowElement(pid: pid, windowID: windowID) else { return false }
        return press(kind, on: window)
    }

    /// AXPress the control on a SPECIFIC window — the one whose AX frame
    /// matches `target` (the gaze-resolved window's bounds). list_windows
    /// bounds and AX frames share the same top-left point space; a few
    /// points of shadow/Dock drift is all the tolerance absorbs. This is
    /// the deictic path: "minimize this" presses the button on the window
    /// the user is looking at, never the app's focused one.
    @discardableResult
    static func press(_ kind: Kind, pid: pid_t, matching target: CGRect) -> Bool {
        guard let window = windowElement(pid: pid, matching: target) else { return false }
        return press(kind, on: window)
    }

    private static func press(_ kind: Kind, on window: AXUIElement) -> Bool {
        guard buttons(on: window).contains(where: { $0.kind == kind }) else { return false }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attributes[kind]! as CFString, &ref) == .success,
              let ref else { return false }
        return AXUIElementPerformAction(ref as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// The app's AXWindow whose frame matches `target` within ~4pt —
    /// larger tolerances risk sibling windows of identical size.
    private static func windowElement(pid: pid_t, matching target: CGRect) -> AXUIElement? {
        guard !target.isEmpty else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let f = frame(of: window) else { return false }
            return abs(f.minX - target.minX) < 4 && abs(f.minY - target.minY) < 4
                && abs(f.width - target.width) < 4 && abs(f.height - target.height) < 4
        }
    }

    private static func windowElement(pid: pid_t, windowID: Int) -> AXUIElement? {
        guard pid > 0, let expected = UInt32(exactly: windowID), expected > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        let matches = windows.filter { FocusedTextBinding.windowNumber($0) == expected }
        guard matches.count == 1, let window = matches.first else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(window, &owner) == .success, owner == pid else { return nil }
        return window
    }

    private static func frontWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        // AXFocusedWindow first; AXWindows[0] for the un-focused-but-real
        // window (backgrounded app — the whole point of this lane).
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let ref { return (ref as! AXUIElement) }
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
           let windows = ref as? [AXUIElement], let first = windows.first { return first }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
