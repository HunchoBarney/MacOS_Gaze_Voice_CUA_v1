import AppKit
import Foundation
import OSLog

/// Host-side pointer clicks at a screen point — the path for gaze verbs the
/// driver's `scope:"desktop"` doesn't cover (`right_click`/`double_click`
/// there require a pid + window-local px). Posting through the HID tap
/// makes the event indistinguishable from a hardware click to the app
/// under the point — the same trust the MediaKeys path already carries.
enum GazePointer {
    enum Kind: Sendable {
        case left, right, double
    }

    /// Posting seam — HID tap in production, stubbed in tests so no real
    /// mouse events fire.
    static var poster: (Kind, CGPoint) -> Bool = { kind, point in
        post(kind, at: point)
    }

    /// The refusal of the last production post, for diagnostics.
    static var refusal: Refusal? { state.refusal }

    enum Refusal: String, Sendable {
        case postAccessDenied
        case eventCreation
    }

    private static let log = Logger(subsystem: "com.karanvirkang.jarvis", category: "gaze-pointer")
    private static let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var granted = false
        private var last: Refusal?
        var refusal: Refusal? { lock.lock(); defer { lock.unlock() }; return last }
        /// Same posture as MediaKeys: cache only a grant; a mid-run grant
        /// takes effect on the next click without a restart.
        var postAccessGranted: Bool {
            lock.lock()
            defer { lock.unlock() }
            if !granted { granted = CGPreflightPostEventAccess() }
            return granted
        }
        func set(_ refusal: Refusal?) { lock.lock(); last = refusal; lock.unlock() }
    }

    /// Post a complete click gesture at a global screen point (top-left
    /// origin, points — the space `CGEvent.location` and the tracker's
    /// gaze output share). A double-click is the canonical two-beat pair:
    /// clickState 1 then clickState 2 — macOS coalesces them into the
    /// double-click any app's double-click handler expects.
    @discardableResult
    private static func post(_ kind: Kind, at point: CGPoint) -> Bool {
        guard state.postAccessGranted else {
            state.set(.postAccessDenied)
            log.error("Gaze click refused: this process lacks event-posting access (Privacy & Security).")
            return false
        }
        func event(_ type: CGEventType, button: CGMouseButton, clickState: Int64) -> CGEvent? {
            let e = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: button)
            e?.setIntegerValueField(.mouseEventClickState, value: clickState)
            return e
        }
        let beats: [(CGEventType, CGMouseButton, Int64)]
        switch kind {
        case .left:
            beats = [(.leftMouseDown, .left, 1), (.leftMouseUp, .left, 1)]
        case .right:
            beats = [(.rightMouseDown, .right, 1), (.rightMouseUp, .right, 1)]
        case .double:
            beats = [(.leftMouseDown, .left, 1), (.leftMouseUp, .left, 1),
                     (.leftMouseDown, .left, 2), (.leftMouseUp, .left, 2)]
        }
        for (type, button, clickState) in beats {
            guard let e = event(type, button: button, clickState: clickState) else {
                state.set(.eventCreation)
                return false
            }
            e.post(tap: .cghidEventTap)
        }
        state.set(nil)
        return true
    }
}
