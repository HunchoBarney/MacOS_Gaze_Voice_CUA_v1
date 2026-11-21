import Aurora
import SwiftUI

/// B. Siri: the Apple Intelligence glow. "This" flares it once, the confirm
/// holds it, the press pulls it tight onto the control and it dissolves.
@MainActor
public enum FlashSiri: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Siri", axis: "Glow: flare, hold, tighten, dissolve",
        pitch: "Wins with the Aura gaze highlight and the Aurora voice surface: Jarvis's attention is one light everywhere.",
        cost: "A shader for a sub-second moment; and the warm-cool palette is Apple's signature, so it reads as Apple's.",
        libraries: [Lib.aurora, Lib.swiftUISpring],
        custom: "Mapping the four moments to the shader's burst, glow size and outro.",
        skills: [SkillNote("apple-design", "Siri's edge light acknowledges you, then gets out of the way: flare on 'this', dissolve on done."),
                 SkillNote("animate", "The press tightens the glow on a 0.22 s spring at 0.7 damping: the only bounce, at the moment of contact."),
                 SkillNote("choreograph", "Caption lands 80 ms after the flare peaks, so the light leads and the words confirm."),
                 SkillNote("animation-performance", "The glow view only exists between 'this' and done; nothing renders while idle.")],
        alwaysOn: false)

    public static func update(_ f: FlashFixture, _ c: Ctx, _ m: MotionBank) {
        let start = c.t - c.local
        if f.phase == .this, c.previous != "this" { m.set("burstAt", start, .snap) }
        if f.phase == .press { m.set("burstAt", start, .snap) }
        if f.phase == .done { m.set("outAt", start + 0.6, .snap) }
        let outset: Double = switch f.phase {
        case .aim: 3
        case .this: 5
        case .confirm: 3
        case .press: 0.5
        case .done: 3
        }
        m.set("outset", outset, c.geo(f.phase == .press ? .spring(response: 0.22, damping: 0.7) : .spring(response: 0.4, damping: 1)))
        let flare = f.phase == .this && c.local < 0.25 || f.phase == .press && c.local < 0.15
        m.set("glow", flare ? 1.6 : f.phase == .aim ? 0.5 : 0.9, c.fade(.spring(response: flare ? 0.18 : 0.45, damping: 1)))
        m.set("on", f.phase == .done && c.local > 0.6 ? 0 : 1, c.fade(.easeOut(0.5)))
        FlashMotion.caption(m, c, key: "cap.this", on: f.phase == .this, delay: 0.16)
        FlashMotion.caption(m, c, key: "cap.confirm", on: f.phase == .confirm)
    }

    public static func body(_ f: FlashFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let o = m["outset"]
        let r = f.target.insetBy(dx: -o, dy: -o)
        let outro: Double = f.phase == .done && c.t >= m.value("outAt", .infinity) ? c.t - m.value("outAt", c.t) : -1
        return ZStack(alignment: .topLeading) {
            if m["on"] > 0.002 {
                AuroraEdge(size: r.size, radius: f.radius + o, border: f.phase == .press ? 3.5 : 2.5, rim: 5,
                           bloom: m["glow"],
                           times: AuroraGlow.Times(
                               elapsed: c.reduceMotion ? 0 : c.t,
                               burst: c.reduceMotion ? -1 : c.t - m.value("burstAt", c.t - 10),
                               outro: c.reduceMotion ? -1 : outro),
                           reduceTransparency: c.reduceTransparency)
                    .opacity(m["on"])
                    .offset(x: r.minX, y: r.minY)
            }
            FlashMotion.place("This one", f, c, m["cap.this"])
            FlashMotion.place("Pressing Send", f, c, m["cap.confirm"])
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}
