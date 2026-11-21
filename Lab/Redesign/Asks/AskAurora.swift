import Aurora
import SwiftUI

/// B. Aurora: no card. The display's edge lights the way Siri does while
/// Jarvis waits for you, the ask floats under the notch on a scrim, and the
/// light swells with your voice when the answer is spoken. A problem turns
/// the light warm and quiet.
@MainActor
public enum AskAurora: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Aurora", axis: "The ask floats in Siri's light, no container",
        pitch: "Wins with the Aurora voice surface: Jarvis asking feels like Siri asking, ambient and unmistakable, and nothing sits on your window.",
        cost: "Full-display light for as long as Jarvis waits, the highest GPU cost of the three; floating text leans on the scrim, which Reduce Transparency makes nearly opaque.",
        libraries: [Lib.aurora, Lib.swiftUISpring],
        custom: "Mapping each ask to the glow (a burst per new ask, voice level to glow size, the warm palette for a problem) and the floating layouts with their scrim.",
        skills: [SkillNote("apple-design", "Siri's edge light means \u{201C}I'm listening to you\u{201D}; a new ask bursts the light once, the open question swells it with your voice, and the problem dims it to sunset."),
                 SkillNote("emil-design-eng", "LI-5: the batch 1 Aurora capsules (ink primary, translucent secondary) with key hints, centred under the words they answer."),
                 SkillNote("choreograph", "The light leads (burst at the change), the old ask leaves in 0.14 s and the new one focuses in at 0.1 s; buttons arrive with their question, not after it."),
                 SkillNote("animate", "No geometry moves at all: only opacity, blur and the shader's own clock, so the four asks swap without the surface jumping."),
                 SkillNote("break-ui", "A 300 pt top scrim keeps 24 pt type legible on the light wallpaper and over the Mail toolbar; long heard text wraps to a 760 pt measure."),
                 SkillNote("animation-performance", "One shader at the display edge, removed when idle.")],
        alwaysOn: true)

    public static func update(_ f: AskFixture, _ c: Ctx, _ m: MotionBank) {
        let lit = f.phase != .idle
        m.set("glow", lit ? 1 : 0, lit ? c.fade(.easeOut(0.3)) : c.fade(.easeOut(0.5)))
        m.set("scrim", lit ? 1 : 0, c.fade(.easeOut(0.3)))
        let start = c.t - c.local
        if lit, c.previous == nil || c.previous == "idle" { m.set("litAt", start, .snap) }
        if lit, f.phase != .problem { m.set("burstAt", start, .snap) }
        m.set("level", f.phase == .question ? f.level : 0, .spring(response: 0.16, damping: 1))
        m.set("warm", f.phase == .problem ? 1 : 0, c.fade(.easeOut(0.4)))
        AskMotion.content(f, c, m, delay: 0.1, enter: 0.28)
    }

    public static func body(_ f: AskFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let ink: Color = c.dark ? .white : Color.black.opacity(0.88)
        let sub: Color = c.dark ? .white.opacity(0.62) : Color.black.opacity(0.55)
        let level = m["level"]
        let k = f.labelScale
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [(c.dark ? Color.black : Color.white).opacity(c.reduceTransparency ? 0.94 : 0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: Desk.size.width, height: 300 * (0.5 + 0.5 * k))
                .opacity(m["scrim"])
            if m["glow"] > 0.002 {
                AuroraGlow(m["warm"] > 0.5 ? .subtle : .standard)
                    .cornerRadius(14)
                    .borderWidth(5 + level * 5)
                    .glowSize(26 + level * 30)
                    .palette(m["warm"] > 0.5 ? .sunset : .appleIntelligence)
                    .frame(width: Desk.size.width, height: Desk.size.height)
                    .environment(\.auroraTimes, AuroraGlow.Times(
                        elapsed: c.reduceMotion ? 0 : c.t,
                        burst: c.reduceMotion ? -1 : c.t - m.value("burstAt", c.t),
                        intro: c.reduceMotion ? -1 : c.t - m.value("litAt", c.t)))
                    .opacity(m["glow"] * (c.reduceTransparency ? 0.75 : 1))
            }
            ZStack(alignment: .top) {
                ForEach(AskMotion.phases, id: \.rawValue) { phase in
                    let p = m["c." + phase.rawValue].clamped(0, 1)
                    if p > 0.005 {
                        content(phase, c, k, ink: ink, sub: sub)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: min(760 * k, 1200))
                            .modifier(AskFocus(p: p))
                    }
                }
            }
            .frame(width: Desk.size.width)
            .offset(y: Desk.menuBar + 20)
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
        .environment(\.reduceMotionForAsks, c.reduceMotion)
    }

    @ViewBuilder
    static func content(_ phase: AskFixture.Phase, _ c: Ctx, _ k: Double, ink: Color, sub: Color) -> some View {
        let title = Font.system(size: 24 * k, weight: .semibold)
        switch phase {
        case .idle:
            EmptyView()
        case .review:
            VStack(spacing: 6 * k) {
                Text("Check what I heard").font(.system(size: 15 * k, weight: .medium)).foregroundStyle(sub)
                Text("\u{201C}" + AskScript.heard + "\u{201D}").font(title).foregroundStyle(ink)
                buttons(.review, c, k, sub: sub)
            }
        case .question:
            VStack(spacing: 12 * k) {
                Text(AskScript.question).font(title).foregroundStyle(ink)
                ShimmerText(text: "Listening for your answer", size: 17 * k, t: c.t, base: sub, highlight: ink, reduceMotion: c.reduceMotion)
                AuroraButton(title: "Cancel", key: "esc", primary: false, dark: c.dark, scale: k).padding(.top, 4 * k)
            }
        case .approval:
            VStack(spacing: 12 * k) {
                Text(AskScript.approval).font(title).foregroundStyle(ink)
                MoveRow(ink: ink, sub: sub, fill: c.dark ? .white.opacity(0.12) : .black.opacity(0.06), scale: k)
                buttons(.approval, c, k, sub: sub)
            }
        case .problem:
            VStack(spacing: 8 * k) {
                Text(AskScript.problemTitle).font(.system(size: 22 * k, weight: .semibold)).foregroundStyle(ink)
                Text(AskScript.problemDetail).font(.system(size: 15 * k)).foregroundStyle(sub)
                buttons(.problem, c, k, sub: sub).padding(.top, 2 * k)
            }
        }
    }

    static func buttons(_ phase: AskFixture.Phase, _ c: Ctx, _ k: Double, sub: Color) -> some View {
        let a = AskScript.actions(phase)
        return AnswerRow(say: a.say, color: sub, scale: k * 13 / 12, centered: true) {
            if let primary = a.primary { AuroraButton(title: primary, key: "\u{23CE}", primary: true, dark: c.dark, scale: k) }
            AuroraButton(title: a.secondary, key: "esc", primary: false, dark: c.dark, scale: k)
        }
        .padding(.top, 2 * k)
    }
}
