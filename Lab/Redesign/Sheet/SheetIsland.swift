import SwiftUI

/// A. Island: the sheet is the island's expanded card. It grows out of the
/// notch like every other Island state, holds still while you read, and
/// morphs into the draft card for "Type this?" (CS-1: help comes from where
/// Jarvis already speaks, not from a third dark slab).
@MainActor
public enum SheetIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island", axis: "The island's expanded card: one black surface for talking, asking and help",
        pitch: "Wins with the Island voice surface: there is one place Jarvis speaks from, and help is just the island opening wider.",
        cost: "The tallest island state (300 pt) covers the middle of the menu bar and the top of the front window while it is open.",
        libraries: [Lib.dynamicNotchKit, Lib.swiftUISpring],
        custom: "The sheet layout (category column, phrases with italic placeholders) and the island sizes per state; the silhouette and buttons are batch 1's.",
        skills: [SkillNote("apple-design", "The Dynamic Island's expanded state: the card grows from the notch's outline on the voice surface's springs (0.48 / 0.74 open, 0.36 / 0.9 home)."),
                 SkillNote("choreograph", "One entrance per container: the island opens and the list is already in it, no row stagger. For eyes on, the island grows first and only the new row focuses in 0.06 s later. List to draft changes width and height, so the list leaves before the draft arrives."),
                 SkillNote("emil-design-eng", "Type does the structure: a 76 pt column of quiet labels, phrases at 14 pt, placeholders in italic and dots at a third of the ink. No dividers, no icons per row."),
                 SkillNote("remove-animations", "Nothing moves while the sheet is open: no orb in the ears, no shimmer. It is reference text."),
                 SkillNote("break-ui", "Rows are one line by design; the longest (\u{201C}do that again \u{00B7} cancel that \u{00B7} what did you do\u{201D}) fits 500 pt with 60 pt to spare, and the draft wraps instead of truncating."),
                 SkillNote("animate", "Draft buttons are the island's white and translucent capsules with return and esc hints (LI-5), not stock blue.")],
        alwaysOn: false)

    static func listWidth(_ k: Double) -> CGFloat { min(500 * k, 780) }
    static func draftWidth(_ k: Double) -> CGFloat { min(452 * k, 760) }
    static func pad(_ k: Double) -> CGFloat { 28 * k }

    static func shape(_ f: SheetFixture) -> VoiceIsland.Shape {
        let k = f.labelScale
        switch f.phase {
        case .off: return VoiceIsland.Shape(w: Desk.notch.width, h: Desk.menuBar, r: Desk.notchRadius, shoulder: 6)
        case .eyesOff, .eyesOn:
            let w = listWidth(k)
            let eyes = f.phase == .eyesOn
            let content = Measure.size("sheetA-list-\(k)-\(eyes)", width: w - pad(k) * 2) {
                SheetList(scale: k, width: w - pad(k) * 2, eyes: eyes, ink: .white, sub: .white, faint: .white, tag: .white) { title(k) }
            }
            return VoiceIsland.Shape(w: w, h: Desk.menuBar + 16 * k + content.height + 14 * k, r: 36, shoulder: 12)
        case .typeThis:
            let w = draftWidth(k)
            let content = Measure.size("sheetA-draft-\(k)", width: w - pad(k) * 2) { draftContent(k) }
            return VoiceIsland.Shape(w: w, h: Desk.menuBar + 18 * k + content.height + 18 * k, r: 36, shoulder: 12)
        }
    }

    public static func update(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank) {
        let s = shape(f)
        let growing = s.w * s.h >= m.value("w", s.w) * m.value("h", s.h)
        let spring: MotionSpec = growing ? .spring(response: 0.48, damping: 0.74) : .spring(response: 0.36, damping: 0.9)
        m.set("w", s.w, c.geo(spring))
        m.set("h", s.h, c.geo(spring))
        m.set("r", s.r, c.geo(spring))
        m.set("sh", s.shoulder, c.geo(spring))
        SheetMotion.content(f, c, m, delay: 0.09)
    }

    public static func body(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let w = m["w"], h = m["h"]
        let k = f.labelScale
        return ZStack(alignment: .top) {
            NotchSilhouette(width: w, height: h, ear: m["sh"], bottomRadius: m["r"])
                .fill(Color.black)
                .frame(width: w + 40, height: h)
                .shadow(color: .black.opacity(h > 40 ? 0.35 : 0), radius: 18, y: 8)
            ZStack(alignment: .top) {
                if m["c.list"] > 0.005 { list(f, c, m, k) }
                if m["c.draft"] > 0.005 { draft(c, m, k) }
            }
            .frame(width: w, height: max(0, h - Desk.menuBar), alignment: .top)
            .clipped()
            .offset(y: Desk.menuBar)
        }
        .frame(width: w + 40, height: max(h, Desk.menuBar), alignment: .top)
        .offset(x: Desk.size.width / 2 - w / 2 - 20)
        .environment(\.colorScheme, .dark)
    }

    static func title(_ k: Double) -> some View {
        Text("Things you can say").font(.system(size: 12.5 * k, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
    }

    static func list(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank, _ k: Double) -> some View {
        let p = SheetMotion.focus(m["c.list"], c)
        let width = listWidth(k) - pad(k) * 2
        return SheetList(scale: k, width: width, eyes: f.phase == .eyesOn || m["c.eyes"] > 0.005,
                         eyesP: SheetMotion.focus(m["c.eyes"], c),
                         ink: .white, sub: .white.opacity(0.45), faint: .white.opacity(0.28), tag: .white.opacity(0.55)) { title(k) }
            .padding(.top, 16 * k)
            .opacity(p.opacity)
            .blur(radius: p.blur)
    }

    static func draftContent(_ k: Double) -> some View {
        VStack(alignment: .leading, spacing: 8 * k) {
            Text(SheetScript.draftTitle).font(.system(size: 17 * k, weight: .semibold)).foregroundStyle(.white)
            Text("\u{201C}" + SheetScript.draft + "\u{201D}").font(.system(size: 15 * k)).foregroundStyle(.white.opacity(0.72))
                .lineSpacing(2 * k)
                .fixedSize(horizontal: false, vertical: true)
            AnswerRow(say: "type it", color: .white.opacity(0.4), scale: k) {
                IslandButton(title: "Type it", key: "\u{23CE}", primary: true, scale: k)
                IslandButton(title: "Change it", key: "esc", primary: false, scale: k)
            }
            .padding(.top, 8 * k)
        }
    }

    static func draft(_ c: Ctx, _ m: MotionBank, _ k: Double) -> some View {
        let p = SheetMotion.focus(m["c.draft"], c)
        return draftContent(k)
            .frame(width: draftWidth(k) - pad(k) * 2, alignment: .leading)
            .padding(.top, 18 * k)
            .opacity(p.opacity)
            .blur(radius: p.blur * 1.5)
            .scaleEffect(c.reduceMotion ? 1 : 0.96 + 0.04 * p.opacity, anchor: .top)
    }
}
