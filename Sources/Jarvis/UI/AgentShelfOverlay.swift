import AppKit
import SwiftUI

/// B7's fixed top-right shelf — every live agent as a chip with its
/// palette color, name, and state (acting / asking / idle). The
/// convention holds: persistent surfaces stay fixed; transient radials
/// stay gaze-anchored. Panels are borderless, nonactivating, all-Space
/// and mouse-transparent — the same grammar as TargetOverlay.
///
/// The shelf is also a gaze surface: `chipRects` (global top-left
/// points) feed the candidate feed as `.agentCursor` targets, so
/// looking at an agent's chip addresses it — "stop" at the chip
/// interrupts that agent.
@MainActor
final class AgentShelfOverlay {
    nonisolated enum State: String, Equatable, Sendable { case acting, asking, idle }

    nonisolated struct Entry: Equatable, Sendable {
        var slug: String
        var name: String
        var colorHex: String
        var state: State
    }

    static let shared = AgentShelfOverlay()

    private(set) var entries: [Entry] = []
    /// slug → chip rect in global top-left points — the feed's surface.
    private(set) var chipRects: [String: CGRect] = [:]

    /// One small panel per entry — same shape the cursor labels use.
    private var panels: [String: NSPanel] = [:]

    nonisolated static let edgeInset: CGFloat = 12
    nonisolated static let rowSpacing: CGFloat = 6
    nonisolated static let chipHeight: CGFloat = 24
    /// Estimated chip width for pure layout — the panel's hosting view
    /// measures the real width after build; this keeps `chipFrames`
    /// deterministic for tests and pre-layout hit-tests.
    nonisolated static func chipWidth(_ e: Entry) -> CGFloat {
        8 + 10 + 6 + CGFloat(e.name.count) * 6.5 + 10
            + (e.state == .idle ? 0 : 14)
    }

    /// Pure placement: chip rects stacked top-right of a top-left-space
    /// display frame — exposed so the rects stay honest for tests and
    /// before any panel exists.
    nonisolated static func chipFrames(_ entries: [Entry],
                                       inFrame f: CGRect) -> [String: CGRect] {
        var y = f.minY + edgeInset
        var out: [String: CGRect] = [:]
        for e in entries {
            let w = chipWidth(e)
            out[e.slug] = CGRect(x: f.maxX - edgeInset - w, y: y,
                                 width: w, height: chipHeight)
            y += chipHeight + rowSpacing
        }
        return out
    }

    /// Push the current roster — an equal set leaves the panels alone
    /// (no flicker on a 400ms poll); empty hides the shelf.
    func update(_ new: [Entry], displayTopLeft frame: CGRect? = nil) {
        let frame = frame ?? Self.displayFrame()
        guard new != entries || panels.isEmpty != new.isEmpty else { return }
        entries = new
        chipRects = Self.chipFrames(new, inFrame: frame)
        var keep: Set<String> = []
        for entry in new {
            keep.insert(entry.slug)
            let panel = panels[entry.slug] ?? Self.makePanel(for: entry)
            panels[entry.slug] = panel
            guard let rect = chipRects[entry.slug] else { continue }
            let appKit = TargetOverlay.appKitFrame(for: rect)
            (panel.contentView as? NSHostingView<AgentShelfChip>)?.rootView = AgentShelfChip(entry: entry)
            panel.setFrame(appKit, display: true)
            panel.orderFront(nil)
        }
        for slug in panels.keys where !keep.contains(slug) {
            panels[slug]?.orderOut(nil)
            panels[slug] = nil
        }
    }

    func hide() {
        entries = []; chipRects = [:]
        for (_, panel) in panels { panel.orderOut(nil) }
        panels = [:]
    }

    /// The shelf parks on the display the gaze (or cursor) is on —
    /// top-right of its top-left-space frame.
    private static func displayFrame() -> CGRect {
        let screen = ScreenGeometry.display(containing:
            ScreenGeometry.appKitToTopLeft(NSEvent.mouseLocation))
            ?? NSScreen.main ?? NSScreen.screens.first
        return screen.map { ScreenGeometry.topLeftFrame(of: $0) } ?? .zero
    }

    private static func makePanel(for entry: Entry) -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: AgentShelfChip(entry: entry))
        return panel
    }
}

/// One shelf chip — slug-colored dot, name, and a state glyph only when
/// the agent is doing something (acting) or parked on a question.
private struct AgentShelfChip: View {
    let entry: AgentShelfOverlay.Entry

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(agentHex: entry.colorHex))
                .frame(width: 8, height: 8)
            Text(entry.name)
                .font(.system(size: 10, weight: .semibold))
            if entry.state == .asking {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
            } else if entry.state == .acting {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .colorScheme(.dark)
        .foregroundStyle(.white)
        .opacity(entry.state == .idle ? 0.65 : 1)
    }
}
