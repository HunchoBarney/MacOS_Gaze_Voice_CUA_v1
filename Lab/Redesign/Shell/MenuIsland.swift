import SwiftUI
import ThinkingOrbsKit

/// A. Island popover: the menu becomes a black island that grows out of the
/// item. Its top is live, what Jarvis is doing with the orb and the one
/// control for it; below it the same commands as the menu, with the same
/// keyboard. The item is the Island capsule.
@MainActor
public enum MenuIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island popover", axis: "A black popover that grows from the item, with a live header",
        pitch: "Becomes a popover (an NSPanel anchored to the item) because the header is live: the orb working, the task's name and Stop beside it, or the questions with Answer, and NSMenu can't animate a view or keep a control focused. It keeps the menu's keyboard, so arrows, return, esc, \u{2318}, and \u{2318}Q behave as before.",
        cost: "A popover has to rebuild what NSMenu gives for free (type-to-select, VoiceOver's menu role, closing on a click elsewhere), and a black panel in light mode is the loudest of the three.",
        libraries: [Lib.thinkingOrbs, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The panel, its growth from the item (two springs), the live header and its cross-fade; the rows reuse the menu layout on black.",
        skills: [SkillNote("apple-design", "Spatial consistency: the panel scales from the item it belongs to (anchored at the item, from 92%) and returns into it; MM-1's Eyes is a real section header with its state on the right."),
                 SkillNote("animate", "Opening is a 0.3 s spring at 0.86 damping, inside the dropdown budget, with opacity in 0.14 s; closing is a 0.12 s fade. Height changes while open ride a critically damped 0.34 s spring."),
                 SkillNote("choreograph", "One entrance for the container, never a row stagger (rows are a high-frequency surface); only the header's words cross-fade, 0.12 s out and 0.2 s in."),
                 SkillNote("find-animation-opportunities", "The one loop is the orb, while a task runs: it's the only place in the menu where Jarvis is live."),
                 SkillNote("gestures", "Stop and Answer carry their keys (esc, return) and the rows keep the menu's arrow-key highlight, so pointer, keyboard and voice reach the same commands."),
                 SkillNote("emil-design-eng", "MB-1's count lands in the header with its Answer button; the panel uses the island's radius and the island's white capsules."),
                 SkillNote("break-ui", "At 2x rows, header and buttons double, the panel widens to the longest row and moves left to stay on screen; the header measures its words."),
                 SkillNote("animate-expo", "Principles only: springs carry velocity when you open and close quickly; nothing waits for an animation to finish before it takes input.")],
        alwaysOn: true)

    static func pad(_ k: Double) -> CGFloat { 14 * k }

    static func headerHeight(_ f: MenuFixture, width: CGFloat) -> CGFloat {
        Measure.size("menuA-head-\(f.status)-\(f.labelScale)", width: width - 2 * pad(f.labelScale)) {
            header(f, MenuFixture(open: true), nil, nil)
        }.height + 2 * pad(f.labelScale)
    }

    static func geometry(_ f: MenuFixture) -> (rows: [MenuRow], mt: NativeMenu.Metrics, size: CGSize, header: CGFloat) {
        let k = f.labelScale
        let rows = MenuScript.rows(f, statusHeader: false, asksItem: false)
        let mt = NativeMenu.Metrics(k: k)
        let width = NativeMenu.width(rows, mt, minimum: 290 * k)
        let header = headerHeight(f, width: width)
        return (rows, mt, CGSize(width: width, height: header + 1 + NativeMenu.height(rows, mt)), header)
    }

    public static func update(_ f: MenuFixture, _ c: Ctx, _ m: MotionBank) {
        ItemIsland.update(f.item, c, m)
        let wasOpen = m["mm.openO"] > 0.01
        m.set("mm.open", f.open ? 1 : 0, c.geo(f.open ? .spring(response: 0.3, damping: 0.86) : .spring(response: 0.24, damping: 1)))
        m.set("mm.openO", f.open ? 1 : 0, c.fade(.easeOut(f.open ? 0.14 : 0.12)))
        let h = geometry(f).size.height
        m.set("mm.h", h, f.open && wasOpen ? c.geo(.spring(response: 0.34, damping: 1)) : .snap)
        let before = MenuScript.fixture(of: c.previous)?.status
        for status in statuses {
            let on = f.status == status && (c.reduceMotion || c.previous == nil || before == status || c.local > 0.1)
            m.set("mh." + status, on ? 1 : 0, on ? c.fade(.easeOut(0.2)) : c.fade(.easeOut(0.12)))
        }
    }

    static var statuses: [String] {
        [MenuFixture(open: true).status, MenuFixture(open: true, task: true).status, MenuFixture(open: true, asks: 2).status]
    }

    public static func body(_ f: MenuFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let k = f.labelScale
        let itemWidth = ItemIsland.width(k)
        let g = geometry(f)
        let open = m["mm.open"], o = m["mm.openO"].clamped(0, 1)
        let h = max(g.header, m.value("mm.h", g.size.height))
        let origin = NativeMenu.origin(itemWidth: itemWidth, width: g.size.width)
        let anchor = UnitPoint(x: ((StatusBar.trailing - itemWidth / 2) - origin.x) / g.size.width, y: 0)
        let radius = 18 * min(k, 1.5)
        return ZStack(alignment: .topLeading) {
            StatusBar.openHighlight(c, width: itemWidth, opacity: f.open ? 1 : 0).offset(x: StatusBar.trailing - itemWidth)
            ItemIsland.glyph(f.item, c, m).offset(x: StatusBar.trailing - itemWidth)
            if o > 0.005 {
                ZStack(alignment: .topLeading) {
                    ShellGlass(frame: CGRect(origin: origin, size: CGSize(width: g.size.width, height: h)), radius: radius,
                               scheme: .dark, showsMail: true, reduceTransparency: c.reduceTransparency, tint: .black)
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            ForEach(statuses, id: \.self) { status in
                                let p = m["mh." + status].clamped(0, 1)
                                if p > 0.005 {
                                    header(f, statusFixture(status, f), c, m)
                                        .padding(pad(k))
                                        .frame(width: g.size.width, alignment: .leading)
                                        .opacity(p)
                                        .blur(radius: c.reduceMotion ? 0 : (1 - p) * 3)
                                }
                            }
                        }
                        .frame(height: g.header, alignment: .topLeading)
                        Rectangle().fill(Color.white.opacity(0.1)).frame(width: g.size.width - 2 * pad(k), height: 1)
                            .frame(width: g.size.width)
                        NativeMenu.rows(g.rows, g.mt, darkCtx(c), highlight: f.highlight, width: g.size.width,
                                        selection: Color.white.opacity(0.16))
                    }
                    .frame(width: g.size.width, height: h, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
                .frame(width: g.size.width, height: h, alignment: .topLeading)
                .scaleEffect(c.reduceMotion ? 1 : 0.92 + 0.08 * open, anchor: anchor)
                .offset(x: origin.x, y: origin.y)
                .opacity(o)
                .environment(\.colorScheme, .dark)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func darkCtx(_ c: Ctx) -> Ctx {
        var d = c
        d.scheme = .dark
        return d
    }

    static func statusFixture(_ status: String, _ f: MenuFixture) -> MenuFixture {
        var s = MenuFixture(open: true, labelScale: f.labelScale)
        if status == MenuFixture(open: true, task: true).status { s.task = true }
        if status == MenuFixture(open: true, asks: 2).status { s.asks = 2 }
        return s
    }

    /// The live header: the orb and the task with Stop, the questions with
    /// Answer, or the resting status.
    static func header(_ base: MenuFixture, _ f: MenuFixture, _ c: Ctx?, _ m: MotionBank?) -> some View {
        let k = base.labelScale
        return HStack(spacing: 10 * k) {
            ZStack {
                if f.task {
                    ThinkingOrb(state: .working, size: .px20, theme: .dark, paused: c?.reduceMotion ?? true, displaySize: 20 * k)
                } else {
                    Circle().fill(f.asks > 0 ? ShellAccent.amber : Color.white.opacity(0.5))
                        .frame(width: 8 * k, height: 8 * k)
                }
            }
            .frame(width: 20 * k, height: 20 * k)
            VStack(alignment: .leading, spacing: 1 * k) {
                Text(f.task ? "Working" : f.asks > 0 ? "Needs you" : "Jarvis")
                    .font(.system(size: 11 * k, weight: .semibold)).foregroundStyle(Color.white.opacity(0.5))
                Text(f.status).font(.system(size: 14 * k, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6 * k)
            if f.task {
                IslandButton(title: "Stop", key: "esc", primary: false, scale: k * 0.9)
            } else if f.asks > 0 {
                IslandButton(title: "Answer", key: "\u{23CE}", primary: true, scale: k * 0.9)
            }
        }
    }
}
