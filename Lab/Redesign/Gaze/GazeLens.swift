import Orb
import SwiftUI

/// C. Lens: a small glass marble at your gaze. On a control it docks at the
/// corner like a badge and the control gets a crisp tinted outline. The
/// quietest of the three: nothing glows.
@MainActor
public enum GazeLens: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Lens", axis: "Quietest: a marble and a crisp outline, no glow",
        pitch: "Wins if the highlight should feel like macOS focus, precise and calm, and leave the light show to the voice surface.",
        cost: "Least magical of the three; on a busy window a 1.5 pt outline is easier to miss than light.",
        libraries: [Lib.orb, Lib.swiftUISpring],
        custom: "The outline and its tint, and the docking position of the marble.",
        skills: [SkillNote("emil-design-eng", "Restraint: one accent, one stroke weight, no blur on the highest-frequency surface."),
                 SkillNote("apple-design", "The outline follows macOS keyboard focus: continuous corners, 3 pt outset, the control's own radius."),
                 SkillNote("choreograph", "The marble travels to the corner while the outline draws in, on one spring, so the hand-off reads as one move."),
                 SkillNote("break-ui", "Docking at the corner keeps the marble off the label on small controls like Attach."),
                 SkillNote("remove-animations", "The marble's own swirl is slowed to a third and stops under Reduce Motion.")],
        alwaysOn: true)

    static let tint = Color(red: 0.42, green: 0.52, blue: 1)

    public static func update(_ f: GazeFixture, _ c: Ctx, _ m: MotionBank) {
        GazeMotion.follow(f, c, m)
        GazeMotion.rect(f, c, m, orb: 14, spec: .spring(response: 0.3, damping: 1))
        m.set("on", f.phase == .off ? 0 : 1, c.fade(.easeOut(f.phase == .off ? 0.3 : 0.2)))
        m.set("lock", f.target == nil ? 0 : 1, c.fade(.spring(response: 0.28, damping: 1)))
        m.set("dim", f.phase == .lost ? 1 : 0, c.fade(.easeOut(0.5)))
        let dock = f.target.map { CGPoint(x: $0.maxX + 1, y: $0.minY - 1) } ?? f.gaze
        let spec = c.geo(f.target == nil ? .spring(response: 0.22, damping: 1) : .spring(response: 0.34, damping: 0.88))
        m.set("mx", f.target == nil ? m["gx"] : dock.x, spec)
        m.set("my", f.target == nil ? m["gy"] : dock.y, spec)
    }

    public static func body(_ f: GazeFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let lock = m["lock"].clamped(0, 1)
        let r = GazeMotion.frame(m, outset: 3)
        let on = m["on"] * (1 - m["dim"] * 0.65)
        let size = 16 - lock * 4
        return ZStack(alignment: .topLeading) {
            if lock > 0.01 {
                RoundedRectangle(cornerRadius: m["hr"] + 3, style: .continuous)
                    .fill(tint.opacity((c.dark ? 0.16 : 0.1) * lock))
                    .overlay(RoundedRectangle(cornerRadius: m["hr"] + 3, style: .continuous)
                        .strokeBorder(tint.opacity(lock), lineWidth: 1.5))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .opacity(on)
            }
            if on > 0.002 {
            OrbView(configuration: OrbConfiguration(backgroundColors: [Color(red: 0.55, green: 0.35, blue: 1), tint, .cyan],
                                                    glowColor: .white, coreGlowIntensity: 0.9,
                                                    showParticles: false, showShadow: false,
                                                    speed: c.reduceMotion ? 0 : 20))
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .opacity(on)
                .offset(x: m["mx"] - size / 2, y: m["my"] - size / 2)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}
