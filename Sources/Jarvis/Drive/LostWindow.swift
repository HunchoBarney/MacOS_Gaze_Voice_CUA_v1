import CoreGraphics
import Foundation

/// "Where did my window go?" as a pure judgment. The executor gathers what
/// the window list, accessibility and the workspace say about one app's
/// windows; this picks the one cause a person would recognise and the
/// plain words for it. Nothing here touches the system, so every cause is
/// testable from fixtures. Public API only: no Spaces calls, and no window
/// ever moves between desktops.
enum LostWindow {
    struct Window: Equatable, Sendable {
        var id: Int
        /// Global top-left points, as `list_windows` reports them.
        var frame: CGRect
        /// The window list's `is_on_screen`: false when minimized, hidden
        /// or on another desktop.
        var onScreen: Bool
        /// AXMinimized and AXFullScreen read back from the window. Nil when
        /// accessibility can't see the window, which is normal for one on
        /// another desktop.
        var minimized: Bool? = nil
        var fullScreen: Bool? = nil
        /// Who sits on top of the window's centre: an app name, or
        /// "another Notes window". Nil when the window is in front.
        var coveredBy: String? = nil
    }

    struct Facts: Equatable, Sendable {
        var app: String
        var running: Bool
        var hidden = false
        /// WindowManager's Stage Manager switch.
        var stageManager = false
        /// Every attached display, global top-left points.
        var displays: [CGRect] = []
        var windows: [Window] = []
    }

    enum Cause: Equatable, Sendable {
        case inFront(window: Int)
        case behind(window: Int, coveredBy: String)
        case offEdge(window: Int)
        case minimized(window: Int)
        case hidden
        case fullScreen(window: Int)
        case stageManager
        case otherDesktop(window: Int)
        case closed
        case quit
    }

    /// The order is what makes the answer right: process state first, then
    /// a window that is already visible, then the off-screen explanations
    /// from the most certain (an attribute says so) to the least (it must be
    /// on another desktop).
    static func diagnose(_ facts: Facts) -> Cause {
        guard facts.running else { return .quit }
        if facts.hidden { return .hidden }
        guard !facts.windows.isEmpty else { return .closed }
        let shown = facts.windows.filter { $0.onScreen && $0.minimized != true }
        let reachable = shown.filter { isReachable($0.frame, on: facts.displays) }
        if let front = reachable.first(where: { $0.coveredBy == nil }) {
            return .inFront(window: front.id)
        }
        if let buried = reachable.first, let above = buried.coveredBy {
            return .behind(window: buried.id, coveredBy: above)
        }
        if let stray = shown.first { return .offEdge(window: stray.id) }
        if let docked = facts.windows.first(where: { $0.minimized == true }) {
            return .minimized(window: docked.id)
        }
        if let full = facts.windows.first(where: {
            $0.fullScreen ?? isDisplaySized($0.frame, on: facts.displays)
        }) {
            return .fullScreen(window: full.id)
        }
        if facts.stageManager { return .stageManager }
        return .otherDesktop(window: facts.windows[0].id)
    }

    /// Whether enough of the window sits on a display to see and grab it.
    /// With no display geometry there's nothing to judge, so it counts.
    static func isReachable(_ frame: CGRect, on displays: [CGRect]) -> Bool {
        guard !displays.isEmpty else { return true }
        return displays.contains { display in
            let visible = display.intersection(frame)
            return !visible.isNull && visible.width >= min(100, frame.width)
                && visible.height >= min(40, frame.height)
        }
    }

    /// A full-screen window on its own desktop keeps the display's exact
    /// size. A zoomed window stops short of the menu bar and Dock, so it
    /// never matches.
    static func isDisplaySized(_ frame: CGRect, on displays: [CGRect]) -> Bool {
        displays.contains { abs($0.width - frame.width) < 3 && abs($0.height - frame.height) < 3 }
    }

    /// Where a window that slid off goes: centred on the main display, no
    /// bigger than it, clear of the menu bar.
    static func rescueFrame(for frame: CGRect, on display: CGRect) -> CGRect {
        let margin: CGFloat = 40
        let width = min(frame.width, display.width - margin * 2)
        let height = min(frame.height, display.height - margin * 2)
        return CGRect(x: display.minX + ((display.width - width) / 2).rounded(),
                      y: display.minY + max(margin, ((display.height - height) / 2).rounded()),
                      width: width, height: height)
    }

    /// What Jarvis says. `fixed` is the verified readback, never the
    /// dispatch: a fix that didn't show up on screen says so plainly.
    static func line(for cause: Cause, app: String, fixed: Bool) -> String {
        switch cause {
        case .inFront:
            return "\(app) is already on your screen, in front."
        case .behind(_, let above):
            return fixed ? "It was behind \(above). It's in front now."
                : "It's behind \(above), but I couldn't bring it to the front."
        case .offEdge:
            return fixed ? "It had slid off the screen. I moved it back."
                : "It's slid off the screen, and I couldn't move it back."
        case .minimized:
            return fixed ? "It was tucked into the Dock. Here it is."
                : "It's tucked into the Dock, but it didn't come back. You can click it at the right end of the Dock."
        case .hidden:
            return fixed ? "\(app) was hidden. It's back."
                : "\(app) is hidden, and I couldn't bring it back."
        case .fullScreen:
            return fixed
                ? "\(app) was full screen, on its own desktop. I brought you to it. Want me to make it a normal window so it stays with the others?"
                : "\(app) is full screen, on its own desktop, but I couldn't take you there."
        case .stageManager:
            return "Your windows are in Stage Manager, the strip on the left. Want me to turn that off?"
        case .otherDesktop:
            return fixed ? "It was on your other desktop. You're there now."
                : "It's on another desktop, and I couldn't take you there."
        case .closed:
            return fixed ? "The window was closed, so I opened a new one."
                : "\(app) is open, but its window was closed and I couldn't open a new one."
        case .quit:
            return fixed ? "\(app) had closed. I've opened it again."
                : "\(app) had closed. I asked it to open again, but I can't see it yet."
        }
    }
}
