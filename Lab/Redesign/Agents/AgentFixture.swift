import SwiftUI

/// What Jarvis shows about its agents at one instant: who is running (the
/// shelf, in order), where each one's cursor is heading, and the control it
/// is working on. Fixture names and tasks only.
public struct AgentFixture {
    public enum Phase: String { case idle, working, arriving, finishing, shelf, asking, large }
    public enum Status { case acting, asking, idle, done }

    public struct Agent {
        public var id: String
        public var status: Status
        /// Where the driver says the agent's pointer is; nil while it has no
        /// pointer on this screen (background work, or finished).
        public var cursor: CGPoint?
        /// The control it is acting on, once its pointer has arrived.
        public var target: CGRect?
        public var radius: Double = 6
        /// What it is doing, in the cursor label.
        public var action: String
        /// The one-word status the shelf shows while it acts.
        public var short: String
        public var question: String?
    }

    public var phase: Phase
    public var agents: [Agent]
    /// The comfort setting's label scale (1.0...2.0); every text size and
    /// text-driven dimension multiplies by it.
    public var labelScale: Double = 1

    public func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }
}

/// The fixture roster: every agent the script can show, with its colour.
enum AgentRoster {
    struct Entry { var id: String; var name: String; var color: Color }
    static let all: [Entry] = [
        Entry(id: "research", name: "Research", color: Color(red: 0.45, green: 0.36, blue: 0.98)),
        Entry(id: "calendar", name: "Calendar", color: Color(red: 0.04, green: 0.55, blue: 0.58)),
        Entry(id: "notes", name: "Notes", color: Color(red: 0.84, green: 0.24, blue: 0.52)),
        Entry(id: "travel", name: "Travel", color: Color(red: 0.16, green: 0.46, blue: 0.94)),
    ]
    static func entry(_ id: String) -> Entry { all.first { $0.id == id } ?? all[0] }
    /// The one colour that means "needs you" in every direction.
    static let ask = Color(red: 1, green: 0.58, blue: 0.1)
    static let done = Color(red: 0.25, green: 0.8, blue: 0.42)
}

public enum AgentScript {
    static var attachPoint: CGPoint { CGPoint(x: Desk.Target.attach.maxX - 6, y: Desk.Target.attach.maxY - 7) }
    static var subjectPoint: CGPoint { CGPoint(x: Desk.Target.subject.minX + 150, y: Desk.Target.subject.midY + 2) }
    static var toPoint: CGPoint { CGPoint(x: Desk.Target.to.minX + 128, y: Desk.Target.to.midY + 2) }

    static func research(_ status: AgentFixture.Status, cursor: CGPoint?, target: CGRect?) -> AgentFixture.Agent {
        AgentFixture.Agent(id: "research", status: status, cursor: cursor, target: target, radius: 7,
                           action: "Attaching the deck", short: "Attaching")
    }

    static func calendar(_ status: AgentFixture.Status, cursor: CGPoint?, target: CGRect?, question: String? = nil) -> AgentFixture.Agent {
        AgentFixture.Agent(id: "calendar", status: status, cursor: cursor, target: target, radius: 6,
                           action: status == .asking ? "Needs you" : "Filling in the subject",
                           short: status == .asking ? "Needs you" : "Subject", question: question)
    }

    static let notes = AgentFixture.Agent(id: "notes", status: .acting, cursor: nil, target: nil, action: "Summarising the thread", short: "In Notes")
    static let travel = AgentFixture.Agent(id: "travel", status: .idle, cursor: nil, target: nil, action: "", short: "Waiting")

    static var researchAtWork: AgentFixture.Agent { research(.acting, cursor: attachPoint, target: Desk.Target.attach) }
    static var calendarAtWork: AgentFixture.Agent { calendar(.acting, cursor: subjectPoint, target: Desk.Target.subject) }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("idle", "No agents", caption: "Nothing is running: nothing is drawn.", duration: 1.0) { _ in
            AgentFixture(phase: .idle, agents: [])
        },
        StateEntry("working", "One agent working", caption: "Research starts: its chip joins the shelf, its pointer leaves the chip and glides to Attach, its name riding along.", duration: 2.8) { t in
            AgentFixture(phase: .working, agents: [research(.acting, cursor: t < 0.22 ? nil : attachPoint,
                                                            target: t < 1.0 ? nil : Desk.Target.attach)])
        },
        StateEntry("arriving", "A second agent", caption: "Calendar joins: a second chip and a second pointer, each in its own colour, without disturbing the first.", duration: 2.8) { t in
            AgentFixture(phase: .arriving, agents: [researchAtWork,
                                                    calendar(.acting, cursor: t < 0.22 ? nil : subjectPoint,
                                                             target: t < 1.05 ? nil : Desk.Target.subject)])
        },
        StateEntry("finishing", "An agent finishing", caption: "Research is done: its pointer returns to its chip, the chip checks off and leaves, and Calendar's chip closes the gap.", duration: 2.6) { t in
            let done = research(.done, cursor: nil, target: nil)
            return AgentFixture(phase: .finishing, agents: t < 1.35 ? [done, calendarAtWork] : [calendarAtWork])
        },
        StateEntry("shelf", "Agents running", caption: "Three agents at once: the shelf lists each with what it is doing; only the one on this screen has a pointer.", duration: 2.6) { t in
            var agents = [calendarAtWork, notes]
            if t >= 0.06 { agents.append(travel) }
            return AgentFixture(phase: .shelf, agents: agents)
        },
        StateEntry("asking", "An agent needs you", caption: "Calendar stops at the To field with a question: its chip and pointer turn to the one colour that means \u{201C}needs you\u{201D}.", duration: 2.8) { t in
            let arrived = t >= 0.7
            let cal = calendar(arrived ? .asking : .acting, cursor: toPoint, target: arrived ? Desk.Target.to : nil,
                               question: arrived ? "Which Alex: Rivera or Chen?" : nil)
            return AgentFixture(phase: .asking, agents: [cal, notes, travel])
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "The bigger-labels comfort setting at its largest: chips, the needs-you card and the pointer's flag grow with their type (24 pt names) and the shelf re-stacks to fit.", duration: 2.4) { _ in
            let cal = calendar(.asking, cursor: toPoint, target: Desk.Target.to, question: "Which Alex: Rivera or Chen?")
            let research = research(.acting, cursor: nil, target: nil)
            return AgentFixture(phase: .large, agents: [cal, research, notes, travel], labelScale: 2)
        },
    ]

    public static let flow = ["idle", "working", "arriving", "finishing", "shelf", "asking", "large", "idle"]
}

/// Shared motion for the agent directions: the shelf stack, chip presence and
/// the pointers, so the three directions differ only in how they draw.
@MainActor
enum AgentMotion {
    static let shelfRight = Desk.size.width - 14
    static let shelfTop = Desk.menuBar + 10
    static let gap: CGFloat = 6

    static func status(_ f: AgentFixture, _ id: String) -> AgentFixture.Status { f.agent(id)?.status ?? .done }

    static func statusText(_ a: AgentFixture.Agent?) -> String {
        guard let a else { return "Done" }
        switch a.status {
        case .acting: return a.short
        case .asking: return "Needs you"
        case .idle: return "Idle"
        case .done: return "Done"
        }
    }

    /// Sets the stack: each present chip's size, slot, presence and the
    /// pointer that glides between its chip and its target.
    /// `size` gives a chip's target size for an agent (nil when it left).
    static func update(_ f: AgentFixture, _ c: Ctx, _ m: MotionBank, size: (AgentFixture.Agent, Double) -> CGSize,
                       grow: MotionSpec = .spring(response: 0.42, damping: 0.8)) {
        let k = f.labelScale
        m.set("k", k, c.geo(.spring(response: 0.42, damping: 1)), initial: k)
        var y = shelfTop
        for entry in AgentRoster.all {
            let id = entry.id
            guard let a = f.agent(id) else {
                m.set("on.\(id)", 0, c.fade(.easeOut(0.18)))
                m.set("cur.\(id)", 0, c.fade(.easeOut(0.15)))
                m.set("tgt.\(id)", 0, c.fade(.easeOut(0.2)))
                m.set("cx.\(id)", m.value("hx.\(id)", shelfRight - 20), .snap)
                m.set("cy.\(id)", m.value("hy.\(id)", shelfTop + 14), .snap)
                continue
            }
            let s = size(a, k)
            let fresh = m.value("on.\(id)", 0) < 0.01
            let slot = c.geo(.spring(response: 0.4, damping: 1))
            m.set("y.\(id)", y, fresh ? .snap : slot)
            m.set("w.\(id)", s.width, fresh ? .snap : c.geo(grow), initial: s.width)
            m.set("h.\(id)", s.height, fresh ? .snap : c.geo(grow), initial: s.height)
            m.set("on.\(id)", 1, c.fade(.spring(response: 0.32, damping: 1)))
            let home = CGPoint(x: shelfRight - m["w.\(id)"] + 14 * k, y: m["y.\(id)"] + 14 * k)
            y += s.height + gap * k
            m.set("hx.\(id)", home.x, .snap)
            m.set("hy.\(id)", home.y, .snap)
            let point = a.cursor ?? home
            let parked = a.cursor == nil && m.value("cur.\(id)", 0) < 0.02
            m.set("cx.\(id)", point.x, parked ? .snap : c.geo(.spring(response: 0.5, damping: 1)), initial: home.x)
            m.set("cy.\(id)", point.y, parked ? .snap : c.geo(.spring(response: 0.62, damping: 1)), initial: home.y)
            m.set("cur.\(id)", a.cursor == nil ? 0 : 1, c.reduceMotion ? .easeOut(0.2) : a.cursor == nil ? .linear(1.1) : .easeOut(0.12))
            m.set("tgt.\(id)", a.target == nil ? 0 : 1, c.fade(a.target == nil ? .easeOut(0.2) : .spring(response: 0.3, damping: 1)))
            m.set("ask.\(id)", a.status == .asking ? 1 : 0, c.fade(.spring(response: 0.3, damping: 1)))
            m.set("done.\(id)", a.status == .done ? 1 : 0, c.reduceMotion ? .snap : .easeOut(0.32))
            m.set("lab.\(id)", a.target == nil ? 0 : 1, c.geo(.spring(response: 0.38, damping: 0.82)))
            if let t = a.target {
                m.set("tx.\(id)", t.minX, .snap); m.set("ty.\(id)", t.minY, .snap)
                m.set("tw.\(id)", t.width, .snap); m.set("th.\(id)", t.height, .snap)
                m.set("tr.\(id)", a.radius, .snap)
            }
        }
    }

    /// A pointer is drawn while it is away from its chip: it emerges from the
    /// chip and dissolves back into it, so it never appears from nowhere.
    static func pointerOpacity(_ id: String, _ c: Ctx, _ m: MotionBank) -> Double {
        let on = m["on.\(id)"]
        if c.reduceMotion { return m["cur.\(id)"] * on }
        let d = hypot(m["cx.\(id)"] - m["hx.\(id)"], m["cy.\(id)"] - m["hy.\(id)"])
        return min(1, d / 46) * max(m["cur.\(id)"], min(1, d / 46)) * on
    }

    static func chipFrame(_ id: String, _ m: MotionBank) -> CGRect {
        let w = m["w.\(id)"], h = m["h.\(id)"]
        return CGRect(x: shelfRight - w, y: m["y.\(id)"], width: w, height: h)
    }

    static func targetFrame(_ id: String, _ m: MotionBank, outset: Double) -> CGRect {
        CGRect(x: m["tx.\(id)"] - outset, y: m["ty.\(id)"] - outset, width: m["tw.\(id)"] + outset * 2, height: m["th.\(id)"] + outset * 2)
    }

    /// Chip text width at the shelf's type: 12 pt name, 12 pt status, times the label scale.
    static func textWidth(_ a: AgentFixture.Agent, _ k: Double) -> CGFloat {
        TextMetrics.width(AgentRoster.entry(a.id).name, size: 12 * k, weight: .semibold) + 6 * k
            + TextMetrics.width(statusText(a), size: 12 * k, weight: .regular)
    }

    /// The label's x offset from the pointer tip: to the right, or hung to
    /// the left when a wide flag would run off the screen.
    /// Springs between the sides, so the flag swings across rather than jumping.
    static func flag(_ f: AgentFixture, _ c: Ctx, _ m: MotionBank, width: (AgentFixture.Agent, Double) -> CGFloat) {
        let k = f.labelScale
        for a in f.agents {
            let w = width(a, k)
            let right = 12 * pointer(k)
            let x = a.cursor.map { Double($0.x) } ?? m["cx.\(a.id)"]
            let target = x + right + w > Desk.size.width - 8 ? -w - 4 : right
            m.set("fx.\(a.id)", target, c.geo(.spring(response: 0.4, damping: 1)), initial: target)
        }
    }

    /// The pointer grows half as fast as the labels, so it stays a pointer.
    static func pointer(_ k: Double) -> Double { 1 + (k - 1) * 0.5 }
}

/// The classic arrow pointer, the shape every Mac user reads as "a cursor".
/// Custom because SF Symbols' cursorarrow is outline-only and cannot be
/// filled with an agent's colour.
struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let pts: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0.84), CGPoint(x: 0.3, y: 0.66), CGPoint(x: 0.5, y: 1),
                              CGPoint(x: 0.68, y: 0.93), CGPoint(x: 0.5, y: 0.6), CGPoint(x: 0.9, y: 0.6)]
        var p = Path()
        for (i, q) in pts.enumerated() {
            let point = CGPoint(x: rect.minX + q.x * rect.width, y: rect.minY + q.y * rect.height)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }
}

/// The pointer with its fill and outline, tip at the frame's top-left.
struct AgentPointer: View {
    var fill: Color
    var stroke: Color
    var scale: Double = 1
    var body: some View {
        PointerShape()
            .fill(fill)
            .overlay(PointerShape().stroke(stroke, style: StrokeStyle(lineWidth: 1.4 * scale, lineJoin: .round)))
            .frame(width: 13 * scale, height: 19 * scale)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}
