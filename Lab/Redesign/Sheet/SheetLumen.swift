import SwiftUI

/// C. Lumen: the island stays compact (a notch with two ears) and the
/// sheet drops under it as a crisp card: opaque, a hairline, no glow. The
/// right ear shows an eye while eye tracking is on.
@MainActor
public enum SheetLumen: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Lumen", axis: "Compact island, crisp card beneath: a system popover, not a light",
        pitch: "Wins with the Lumen voice surface: the notch stays small, and help reads like a macOS popover you can glance at and dismiss.",
        cost: "A separate card under the island is a second surface to place; in light mode it is a white card on a white window, held apart by its hairline and shadow.",
        libraries: [Lib.dynamicNotchKit, Lib.swiftUISpring],
        custom: "The card, its sizes and the eye in the ear; the compact island and the pills are batch 1's.",
        skills: [SkillNote("apple-design", "A popover's anatomy: opaque in both appearances, 18 pt continuous corners, a 0.5 pt hairline and a short shadow, hanging 10 pt under what it belongs to."),
                 SkillNote("emil-design-eng", "The frequency rule: help is occasional, so it gets one plain entrance (0.2 s fade and a 6 pt drop) and nothing else moves."),
                 SkillNote("choreograph", "The ears open first, the card follows 0.08 s later; for the draft the card resizes while the list leaves, and the two pills drop 40 ms apart as on the voice surface."),
                 SkillNote("find-animation-opportunities", "The one new signal is the eye in the right ear when eye tracking turns on: state, shown where you already glance."),
                 SkillNote("remove-animations", "No ring in the left ear while the sheet is open (a question mark instead): nothing moves while you read."),
                 SkillNote("break-ui", "In light mode the card is white on a white Mail window; the hairline is 0.12 black and the shadow 0.12 so its edge survives.")],
        alwaysOn: false)

    static let ear: CGFloat = VoiceLumen.ear
    static let top: CGFloat = Desk.menuBar + 10
    static func listWidth(_ k: Double) -> CGFloat { min(480 * k, 760) }
    static func draftWidth(_ k: Double) -> CGFloat { min(440 * k, 740) }
    static func pad(_ k: Double) -> CGFloat { 24 * k }

    static func size(_ f: SheetFixture) -> CGSize {
        let k = f.labelScale
        switch f.phase {
        case .off, .eyesOff, .eyesOn:
            let w = listWidth(k)
            let eyes = f.phase == .eyesOn
            let content = Measure.size("sheetC-list-\(k)-\(eyes)", width: w - pad(k) * 2) {
                SheetList(scale: k, width: w - pad(k) * 2, eyes: eyes, ink: .white, sub: .white, faint: .white, size: 13.5, tag: .white) { title(k, .white) }
            }
            return CGSize(width: w, height: 15 * k + content.height + 13 * k)
        case .typeThis:
            let w = draftWidth(k)
            let content = Measure.size("sheetC-draft-\(k)", width: w - pad(k) * 2) {
                draftContent(k, dark: true, pills: [1, 1])
            }
            return CGSize(width: w, height: 17 * k + content.height + 18 * k)
        }
    }

    public static func update(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank) {
        let open = f.shows
        m.set("iw", open ? Desk.notch.width + ear * 2 : Desk.notch.width,
              c.geo(open ? .spring(response: 0.42, damping: 0.78) : .spring(response: 0.34, damping: 0.95)))
        m.set("ir", open ? 16 : Desk.notchRadius, c.geo(.spring(response: 0.42, damping: 0.85)))
        m.set("ears", open && (c.local > (c.reduceMotion ? 0 : 0.08) || c.previous != "off") ? 1 : 0, c.fade(.easeOut(0.22)))
        let s = size(f)
        let resize = c.geo(.spring(response: 0.4, damping: 0.9))
        if f.shows || m["w"] == 0 {
            m.set("w", s.width, resize)
            m.set("h", s.height, resize)
        }
        let card = open && (m["card"] > 0.5 || c.local > (c.reduceMotion ? 0 : 0.08))
        m.set("card", card ? 1 : 0, card ? c.fade(.easeOut(0.2)) : c.fade(.easeOut(0.14)))
        m.set("eye", f.phase == .eyesOn ? 1 : 0, c.fade(.easeOut(0.22)))
        SheetMotion.content(f, c, m, delay: 0.1)
        for i in 0..<2 {
            let on = f.phase == .typeThis && c.local > (c.reduceMotion ? 0 : 0.28 + Double(i) * 0.04)
            m.set("pill\(i)", on ? 1 : 0, on ? c.fade(.spring(response: 0.36, damping: 0.8)) : c.fade(.easeOut(0.12)))
        }
    }

    public static func body(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let iw = m["iw"]
        let w = m["w"], h = m["h"]
        let k = f.labelScale
        let card = m["card"].clamped(0, 1)
        let surface: Color = c.dark ? Color(white: 0.13) : .white
        let hairline: Color = c.dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .top) {
                NotchSilhouette(width: iw, height: Desk.menuBar, ear: 8, bottomRadius: m["ir"])
                    .fill(Color.black)
                    .frame(width: iw + 40, height: Desk.menuBar)
                if m["ears"] > 0.002 { ears(c, m, w: iw) }
            }
            .frame(width: Desk.size.width, alignment: .top)
            if card > 0.002 {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(surface)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(hairline, lineWidth: 0.5))
                    ZStack(alignment: .top) {
                        if m["c.list"] > 0.005 { list(f, c, m, k) }
                        if m["c.draft"] > 0.005 { draft(c, m, k) }
                    }
                    .frame(width: w, height: h, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .frame(width: w, height: h)
                .shadow(color: .black.opacity(c.dark ? 0.45 : 0.12), radius: 16, y: 6)
                .opacity(card)
                .offset(x: Desk.size.width / 2 - w / 2, y: top + (c.reduceMotion ? 0 : (1 - card) * -6))
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func ears(_ c: Ctx, _ m: MotionBank, w: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("?").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                .frame(width: ear, height: Desk.menuBar)
            Spacer(minLength: Desk.notch.width)
            Image(systemName: "eye").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .opacity(m["eye"])
                .frame(width: ear, height: Desk.menuBar)
        }
        .frame(width: Desk.notch.width + ear * 2, height: Desk.menuBar)
        .frame(width: w, height: Desk.menuBar)
        .clipped()
        .opacity(m["ears"])
    }

    static func title(_ k: Double, _ color: Color) -> some View {
        Text("Things you can say").font(.system(size: 12.5 * k, weight: .semibold)).foregroundStyle(color)
    }

    static func list(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank, _ k: Double) -> some View {
        let p = SheetMotion.focus(m["c.list"], c)
        let x = SheetAurora.colors(c)
        var eyesP = SheetMotion.focus(m["c.eyes"], c)
        eyesP.blur = 0
        return SheetList(scale: k, width: listWidth(k) - pad(k) * 2, eyes: f.phase == .eyesOn || m["c.eyes"] > 0.005,
                         eyesP: eyesP, ink: x.ink, sub: x.sub, faint: x.faint, size: 13.5, tag: .clear) { title(k, x.sub) }
            .padding(.top, 15 * k)
            .opacity(p.opacity)
    }

    static func draftContent(_ k: Double, dark: Bool, pills: [Double], reduceMotion: Bool = false) -> some View {
        let x = SheetAurora.colors(dark: dark)
        return VStack(alignment: .leading, spacing: 7 * k) {
            Text(SheetScript.draftTitle).font(.system(size: 16 * k, weight: .semibold)).foregroundStyle(x.ink)
            Text("\u{201C}" + SheetScript.draft + "\u{201D}").font(.system(size: 14 * k)).foregroundStyle(x.ink.opacity(0.8))
                .lineSpacing(2 * k)
                .fixedSize(horizontal: false, vertical: true)
            AnswerRow(say: "type it", color: x.sub, scale: k) {
                ForEach(0..<2, id: \.self) { i in
                    let q = pills[i]
                    AuroraButton(title: i == 0 ? "Type it" : "Change it", key: i == 0 ? "\u{23CE}" : "esc", primary: i == 0, dark: dark, scale: k)
                        .opacity(q.clamped(0, 1))
                        .offset(y: reduceMotion ? 0 : (1 - q) * -8)
                        .scaleEffect(reduceMotion ? 1 : 0.94 + 0.06 * q, anchor: .top)
                }
            }
            .padding(.top, 7 * k)
        }
    }

    static func draft(_ c: Ctx, _ m: MotionBank, _ k: Double) -> some View {
        let p = SheetMotion.focus(m["c.draft"], c)
        return draftContent(k, dark: c.dark, pills: [m["pill0"], m["pill1"]], reduceMotion: c.reduceMotion)
            .frame(width: draftWidth(k) - pad(k) * 2, alignment: .leading)
            .padding(.top, 17 * k)
            .opacity(p.opacity)
    }
}
