import SwiftUI

/// C. Quiet: no light at all. The outline breathes out once for "this",
/// fills for the confirm, flashes on the press and turns green when done.
@MainActor
public enum FlashQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Quiet", axis: "No glow: stroke, fill and one check",
        pitch: "Wins if the press should feel like macOS itself: precise, instant and silent, with the voice surface doing the talking.",
        cost: "Without light it relies on the outline colour; on a blue toolbar button the tint needs Increase Contrast care.",
        libraries: [Lib.swiftUISpring],
        custom: "All of it: two rounded rectangles and a check. No library does less, and nothing here needs one.",
        skills: [SkillNote("remove-animations", "The baseline that shows what the light buys: same timing, no glow."),
                 SkillNote("emil-design-eng", "The press flash is 80 ms in and 350 ms out, asymmetric like a real button."),
                 SkillNote("animate", "'This' is one 0.3 s spring at 0.55 damping on the outline's outset: a single visible overshoot, then still."),
                 SkillNote("break-ui", "The caption chip is opaque black with white type, legible on any window under it.")],
        alwaysOn: false)

    static let tint = Color(red: 0.42, green: 0.52, blue: 1)
    static let green = Color(red: 0.25, green: 0.8, blue: 0.42)

    public static func update(_ f: FlashFixture, _ c: Ctx, _ m: MotionBank) {
        let pop = f.phase == .this && c.local < 0.14
        m.set("outset", pop ? 8 : f.phase == .press ? 1.5 : 3, c.geo(.spring(response: 0.3, damping: f.phase == .this ? 0.55 : 0.8)))
        m.set("stroke", f.phase == .this ? 2.5 : 1.5, c.fade(.spring(response: 0.3, damping: 1)))
        let flash = f.phase == .press && c.local < 0.08
        m.set("fill", flash ? 0.34 : f.phase == .confirm ? 0.14 : f.phase == .press ? 0.14 : 0.06,
              c.fade(flash ? .easeOut(0.08) : .easeOut(0.35)))
        m.set("ok", f.phase == .done ? 1 : 0, c.fade(.easeOut(0.25)))
        m.set("check", f.phase == .done ? 1 : 0, c.reduceMotion ? .snap : .easeOut(0.32))
        m.set("out", f.phase == .done && c.local > 0.8 ? 1 : 0, c.fade(.easeOut(0.35)))
        FlashMotion.caption(m, c, key: "cap.this", on: f.phase == .this)
        FlashMotion.caption(m, c, key: "cap.confirm", on: f.phase == .confirm)
    }

    public static func body(_ f: FlashFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let o = m["outset"]
        let r = f.target.insetBy(dx: -o, dy: -o)
        let ok = m["ok"]
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: f.radius + o, style: .continuous)
                    .fill(tint.opacity(m["fill"]))
                    .overlay(RoundedRectangle(cornerRadius: f.radius + o, style: .continuous)
                        .strokeBorder(tint.opacity(1 - ok), lineWidth: m["stroke"]))
                    .overlay(RoundedRectangle(cornerRadius: f.radius + o, style: .continuous)
                        .strokeBorder(green.opacity(ok), lineWidth: m["stroke"]))
                if m["check"] > 0.01 {
                    Check(progress: m["check"], color: .white, lineWidth: 2)
                        .frame(width: 9, height: 9)
                        .padding(4)
                        .background(Circle().fill(green))
                        .offset(x: 8, y: -8)
                }
            }
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .opacity(1 - m["out"])
            FlashMotion.place("This one", f, c, m["cap.this"])
            FlashMotion.place("Pressing Send", f, c, m["cap.confirm"])
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}
