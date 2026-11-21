import Aurora
import SwiftUI

/// B. Aurora: a glass card ringed with Siri's light, like Apple
/// Intelligence's own panels. The light arrives with the card and settles;
/// it flares once when the card turns into a draft, then holds still.
@MainActor
public enum SheetAurora: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Aurora", axis: "A glass card in Apple Intelligence light",
        pitch: "Wins with the Aurora voice surface: help is lit the way Siri lights everything it is doing, and reads as part of Apple Intelligence.",
        cost: "A shader around a 500 pt card; the light is frozen once it settles, so it costs a frame only when it changes, but it is still the brightest help sheet of the three.",
        libraries: [Lib.aurora, Lib.swiftUISpring],
        custom: "The card and its sizes, the gradient title, and freezing the glow's clock 1.4 s after each change.",
        skills: [SkillNote("apple-design", "Apple Intelligence's panel language: a calm glass surface and a light rim; Reduce Transparency makes the card opaque and drops the bloom."),
                 SkillNote("remove-animations", "The light stops 1.4 s after it arrives: a reference card you are reading shouldn't shimmer at you."),
                 SkillNote("choreograph", "The light and the card arrive together (one beat), the list is already inside; on the draft the card resizes while the list leaves, then the draft focuses in and the rim flares once."),
                 SkillNote("animate", "The card resizes on a critically damped 0.45 s spring (glass shouldn't wobble); it enters from scale 0.96 at the top edge, not from zero."),
                 SkillNote("emil-design-eng", "The colour is in two places only, the rim and the title; phrases stay in plain ink so they are easy to read.")],
        alwaysOn: false)

    static let top: CGFloat = Desk.menuBar + 10
    static func listWidth(_ k: Double) -> CGFloat { min(500 * k, 780) }
    static func draftWidth(_ k: Double) -> CGFloat { min(452 * k, 760) }
    static func pad(_ k: Double) -> CGFloat { 28 * k }

    static func size(_ f: SheetFixture) -> CGSize {
        let k = f.labelScale
        switch f.phase {
        case .off, .eyesOff, .eyesOn:
            let w = listWidth(k)
            let eyes = f.phase == .eyesOn
            let content = Measure.size("sheetB-list-\(k)-\(eyes)", width: w - pad(k) * 2) {
                SheetList(scale: k, width: w - pad(k) * 2, eyes: eyes, ink: .white, sub: .white, faint: .white, tag: .white) { title(k) }
            }
            return CGSize(width: w, height: 16 * k + content.height + 14 * k)
        case .typeThis:
            let w = draftWidth(k)
            let content = Measure.size("sheetB-draft-\(k)", width: w - pad(k) * 2) { draftContent(k, dark: true) }
            return CGSize(width: w, height: 18 * k + content.height + 20 * k)
        }
    }

    public static func update(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank) {
        let s = size(f)
        let resize = c.geo(.spring(response: 0.45, damping: 1))
        if f.shows || m["w"] == 0 {
            m.set("w", s.width, resize)
            m.set("h", s.height, resize)
        }
        m.set("card", f.shows ? 1 : 0, f.shows ? c.fade(.easeOut(0.26)) : c.fade(.easeOut(0.16)))
        let start = c.t - c.local
        if f.shows, c.previous == nil || c.previous == "off" { m.set("litAt", start, .snap); m.set("burstAt", start, .snap) }
        if f.phase == .typeThis { m.set("burstAt", start + 0.1, .snap) }
        SheetMotion.content(f, c, m, delay: 0.1)
    }

    public static func body(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let w = m["w"], h = m["h"]
        let k = f.labelScale
        let card = m["card"].clamped(0, 1)
        let lit = m.value("litAt", c.t)
        let burst = m.value("burstAt", c.t)
        let now = min(c.t, max(lit, burst) + 1.4)
        let times = AuroraGlow.Times(elapsed: c.reduceMotion ? 0 : now,
                                     burst: c.reduceMotion ? -1 : now - burst,
                                     intro: c.reduceMotion ? -1 : now - lit)
        let fill: Color = c.dark ? Color(white: 0.07).opacity(c.reduceTransparency ? 1 : 0.88) : Color.white.opacity(c.reduceTransparency ? 1 : 0.9)
        return ZStack(alignment: .topLeading) {
            if card > 0.002 {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(fill)
                    AuroraEdge(size: CGSize(width: w, height: h), radius: 24, border: 2, rim: 5, bloom: c.reduceTransparency ? 0 : 0.8,
                               times: times, reduceTransparency: c.reduceTransparency)
                    ZStack(alignment: .top) {
                        if m["c.list"] > 0.005 { list(f, c, m, k) }
                        if m["c.draft"] > 0.005 { draft(c, m, k) }
                    }
                    .frame(width: w, height: h, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .frame(width: w, height: h)
                .shadow(color: .black.opacity(c.dark ? 0.4 : 0.15), radius: 24, y: 10)
                .scaleEffect(c.reduceMotion ? 1 : 0.96 + 0.04 * card, anchor: .top)
                .opacity(card)
                .offset(x: Desk.size.width / 2 - w / 2, y: top)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func colors(_ c: Ctx) -> (ink: Color, sub: Color, faint: Color) {
        colors(dark: c.dark)
    }

    static func colors(dark: Bool) -> (ink: Color, sub: Color, faint: Color) {
        dark ? (.white, .white.opacity(0.5), .white.opacity(0.28)) : (Color.black.opacity(0.88), Color.black.opacity(0.5), Color.black.opacity(0.25))
    }

    static func title(_ k: Double) -> some View {
        Text("Things you can say").font(.system(size: 13 * k, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: ChipFace.aurora, startPoint: .leading, endPoint: .trailing))
    }

    static func list(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank, _ k: Double) -> some View {
        let p = SheetMotion.focus(m["c.list"], c)
        let x = colors(c)
        return SheetList(scale: k, width: listWidth(k) - pad(k) * 2, eyes: f.phase == .eyesOn || m["c.eyes"] > 0.005,
                         eyesP: SheetMotion.focus(m["c.eyes"], c), ink: x.ink, sub: x.sub, faint: x.faint, tag: x.sub) { title(k) }
            .padding(.top, 16 * k)
            .opacity(p.opacity)
            .blur(radius: p.blur)
    }

    static func draftContent(_ k: Double, dark: Bool) -> some View {
        let x = colors(dark: dark)
        return VStack(alignment: .leading, spacing: 8 * k) {
            Text(SheetScript.draftTitle).font(.system(size: 17 * k, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: ChipFace.aurora, startPoint: .leading, endPoint: .trailing))
            Text("\u{201C}" + SheetScript.draft + "\u{201D}").font(.system(size: 15 * k)).foregroundStyle(x.ink)
                .lineSpacing(2 * k)
                .fixedSize(horizontal: false, vertical: true)
            AnswerRow(say: "type it", color: x.sub, scale: k) {
                AuroraButton(title: "Type it", key: "\u{23CE}", primary: true, dark: dark, scale: k)
                AuroraButton(title: "Change it", key: "esc", primary: false, dark: dark, scale: k)
            }
            .padding(.top, 6 * k)
        }
    }

    static func draft(_ c: Ctx, _ m: MotionBank, _ k: Double) -> some View {
        let p = SheetMotion.focus(m["c.draft"], c)
        return draftContent(k, dark: c.dark)
            .frame(width: draftWidth(k) - pad(k) * 2, alignment: .leading)
            .padding(.top, 18 * k)
            .opacity(p.opacity)
            .blur(radius: p.blur * 1.5)
    }
}
