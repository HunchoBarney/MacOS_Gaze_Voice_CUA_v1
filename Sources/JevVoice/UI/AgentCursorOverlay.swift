import AppKit
import SwiftUI

/// Name chip + colored dot drawn at an agent's action target — Clicky-style
/// per-agent cursor identity (AgentCursor carries slug/name/colorHex). Pure
/// observability: the panel ignores mouse events and never moves the pointer.
struct AgentCursorChip: View {
    let cursor: AgentCursor
    private var color: Color { Color(agentHex: cursor.colorHex) }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The dot anchors at the action point; the label hangs beneath it.
    static let anchor = CGPoint(x: 7, y: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
            Text(cursor.label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(reduceTransparency ? Color(white: 0.10) : Color.black.opacity(0.6),
                            in: Capsule())
                .overlay(Capsule().stroke(color, lineWidth: 1))
        }
        .foregroundStyle(.white)
        .colorScheme(.dark)
        .padding(1)
    }
}

/// One borderless panel per active agent cursor. The coordinator pushes
/// positions (e.g. from driver cursor state) via `show`; the voice direct
/// path keeps using the driver-drawn cursor instead.
@MainActor
final class AgentCursorLabels {
    private final class LabelPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panels: [String: NSPanel] = [:]

    /// Places (or moves) an agent's chip so its dot sits on `point`, given
    /// in AppKit screen coordinates.
    func show(_ cursor: AgentCursor, at point: NSPoint) {
        let key = cursor.agentSlug ?? ""
        let hosting: NSHostingView<AgentCursorChip>
        if let panel = panels[key] {
            hosting = panel.contentView as! NSHostingView<AgentCursorChip>
            hosting.rootView = AgentCursorChip(cursor: cursor)
        } else {
            hosting = NSHostingView(rootView: AgentCursorChip(cursor: cursor))
            let panel = LabelPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = hosting
            panels[key] = panel
        }
        let size = hosting.fittingSize
        var origin = NSPoint(x: point.x - AgentCursorChip.anchor.x,
                             y: point.y - (size.height - AgentCursorChip.anchor.y))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panels[key]?.setFrame(NSRect(origin: origin, size: size), display: true)
        panels[key]?.orderFrontRegardless()
    }

    func hide(agentSlug: String?) {
        guard let panel = panels.removeValue(forKey: agentSlug ?? "") else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func hideAll() {
        for key in Array(panels.keys) { hide(agentSlug: key.isEmpty ? nil : key) }
    }
}
