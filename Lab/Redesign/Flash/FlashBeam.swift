import BorderBeamKit
import SwiftUI

/// A. Beam: the same border light as the gaze highlight. "This" sends one
/// echo ring off the control; the press dips the light and it runs out.
@MainActor
public enum FlashBeam: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Beam", axis: "Light on the border: echo for 'this', dip for the press",
        pitch: "Wins with the Beam gaze highlight: every acknowledgement is the same light doing one extra thing.",
        cost: "The beam keeps moving while it waits, which is more motion than C during the confirm.",
        libraries: [Lib.borderBeam, Lib.swiftUISpring],
        custom: "The echo ring and the press dip.",
        skills: [SkillNote("animate", "The echo is a strong ease-out (0.23, 1, 0.32, 1) over 0.5 s; the press dip is a 0.24 s spring at 0.6 damping, so it feels pressed, not scaled."),
                 SkillNote("choreograph", "Echo first, caption 80 ms later; on the press the beam dims as the dip bottoms out, then everything leaves together."),
                 SkillNote("emil-design-eng", "Never from scale 0: the dip goes to 0.96 and the echo starts at the control's own edge."),
                 SkillNote("review-animations", "Replaces today's 1.2 s press glow hold (PG-1) and the ease-in fade on 'this' (DF-1).")],
        alwaysOn: false)

    public static func update(_ f: FlashFixture, _ c: Ctx, _ m: MotionBank) {
        let strength: Double = switch f.phase {
        case .aim: 0.45
        case .this: 1
        case .confirm: 0.8
        case .press: c.local < 0.12 ? 1 : 0.3
        case .done: 0
        }
        m.set("beam", strength, c.fade(.spring(response: 0.3, damping: 1)))
        m.set("dip", f.phase == .press && c.local < 0.12 ? 1 : 0, c.geo(.spring(response: 0.24, damping: 0.6)))
        m.set("fill", f.phase == .press && c.local < 0.2 ? 1 : 0, c.fade(.easeOut(f.phase == .press && c.local < 0.2 ? 0.08 : 0.4)))
        FlashMotion.caption(m, c, key: "cap.this", on: f.phase == .this)
        FlashMotion.caption(m, c, key: "cap.confirm", on: f.phase == .confirm)
        m.set("check", f.phase == .done ? 1 : 0, c.reduceMotion ? .snap : .easeOut(0.32))
        m.set("out", f.phase == .done && c.local > 0.7 ? 1 : 0, c.fade(.easeOut(0.4)))
    }

    public static func body(_ f: FlashFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let r = f.target.insetBy(dx: -3, dy: -3)
        let radius = f.radius + 3
        let echo = f.phase == .this && !c.reduceMotion ? min(1, c.local / 0.5) : 1
        let curve = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.23, y: 1), endControlPoint: UnitPoint(x: 0.32, y: 1))
        let e = curve.value(at: echo)
        return ZStack(alignment: .topLeading) {
            ZStack {
                BorderBeam(size: .sm, colorVariant: .colorful, theme: c.dark ? .dark : .light, staticColors: c.reduceMotion,
                           borderRadius: radius, strength: m["beam"].clamped(0, 1)) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill((c.dark ? Color.white : Color.black).opacity(0.05 + 0.12 * m["fill"]))
                        .frame(width: r.width, height: r.height)
                }
                .environment(\.beamFrozenTime, c.reduceMotion ? 0 : c.t * (f.phase == .this ? 1.6 : 1))
                if f.phase == .this, echo < 1 {
                    RoundedRectangle(cornerRadius: radius + 10 * e, style: .continuous)
                        .strokeBorder(Color(red: 0.6, green: 0.55, blue: 1).opacity(0.9 * (1 - e)), lineWidth: 2)
                        .frame(width: r.width + 20 * e, height: r.height + 20 * e)
                }
                if m["check"] > 0.01 {
                    Check(progress: m["check"], color: Color(red: 0.3, green: 0.85, blue: 0.45), lineWidth: 2.2)
                        .frame(width: 12, height: 12)
                        .padding(5)
                        .background(Circle().fill(c.dark ? Color.black : Color.white).shadow(color: .black.opacity(0.2), radius: 3))
                        .offset(x: r.width / 2, y: -r.height / 2)
                }
            }
            .scaleEffect(1 - 0.04 * m["dip"])
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .opacity(1 - m["out"])
            FlashMotion.place("This one", f, c, m["cap.this"])
            FlashMotion.place("Pressing Send", f, c, m["cap.confirm"])
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}
