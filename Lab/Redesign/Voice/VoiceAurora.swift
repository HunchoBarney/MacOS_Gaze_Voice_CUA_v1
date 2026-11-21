import Aurora
import SwiftUI

/// B. Aurora: no container. The display's edge lights up the way Siri does
/// in Apple Intelligence and swells with your voice; your words float under
/// the notch; when Jarvis starts working the light gathers around the window
/// it is working in, so you see where the work happens. When it's done the
/// light bursts once and goes.
@MainActor
public enum VoiceAurora: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Aurora", axis: "Light at the screen's edge instead of a container",
        pitch: "Wins if Jarvis should feel like Siri in Apple Intelligence: ambient and alive, never sitting on your windows.",
        cost: "The most light on screen and the highest GPU cost while you talk; it leans on Reduce Motion and Reduce Transparency to stay calm.",
        libraries: [Lib.aurora, Lib.swiftUISpring],
        custom: "Driving the glow's frame from the display edge to the working window, voice level to glow size, and the floating word line with its scrim.",
        skills: [SkillNote("apple-design", "Siri's own edge light (Aurora ports Apple's IntelligentLight algorithm); a top scrim keeps words legible on any wallpaper."),
                 SkillNote("choreograph", "The light leads, gathering to the window; the label follows after it lands (350 ms)."),
                 SkillNote("animate", "The light travels far, so its frame uses a critically damped spring (response 0.62, no overshoot)."),
                 SkillNote("find-animation-opportunities", "Showing where the work is happening is the one new motion that carries information."),
                 SkillNote("animation-performance", "The shader only draws while lit; idle removes the view, so nothing renders between turns.")],
        alwaysOn: true)

    static func frame(_ f: VoiceFixture) -> CGRect {
        switch f.phase {
        case .working, .asking, .done: return Desk.mail.insetBy(dx: -2, dy: -2)
        default: return Desk.full
        }
    }

    public static func update(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank) {
        let r = frame(f)
        let travel: MotionSpec = c.geo(.spring(response: 0.62, damping: 1))
        m.set("x", r.minX, travel)
        m.set("y", r.minY, travel)
        m.set("w", r.width, travel)
        m.set("h", r.height, travel)
        m.set("corner", r.width > 1000 ? 14 : 18, travel)
        let lit = f.phase != .idle
        m.set("glow", lit ? 1 : 0, lit ? c.fade(.easeOut(0.3)) : c.fade(.easeOut(0.5)))
        let start = c.t - c.local
        if lit, c.previous == nil || c.previous == "idle" { m.set("litAt", start, .snap) }
        if f.phase == .done { m.set("burstAt", start, .snap) } else if lit, c.previous == nil || c.previous == "idle" { m.set("burstAt", start, .snap) }
        let voice = f.phase == .hearing || f.phase == .listening ? f.level : 0
        m.set("level", voice, .spring(response: 0.16, damping: 1))
        m.set("scrim", lit ? 1 : 0, c.fade(.easeOut(0.3)))
        for phase in [VoiceFixture.Phase.listening, .hearing, .working, .asking, .done, .problem] {
            let delay = phase == .working ? 0.35 : 0.08
            let on = f.phase == phase && c.local > (c.reduceMotion ? 0 : delay)
            m.set("c." + phase.rawValue, on ? 1 : 0, on ? c.fade(.easeOut(0.28)) : c.fade(.easeOut(0.14)))
        }
        m.set("warm", f.phase == .problem ? 1 : 0, c.fade(.easeOut(0.4)))
        m.set("check", f.phase == .done && c.local > 0.1 ? 1 : 0, c.reduceMotion ? .snap : .easeOut(0.32))
    }

    public static func body(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let ink: Color = c.dark ? .white : Color.black.opacity(0.88)
        let sub: Color = c.dark ? .white.opacity(0.62) : Color.black.opacity(0.55)
        let level = m["level"]
        let wide = m["w"] > 1000
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [(c.dark ? Color.black : Color.white).opacity(c.reduceTransparency ? 0.92 : 0.5), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: Desk.size.width, height: 200)
                .opacity(m["scrim"])
            if m["glow"] > 0.002 {
                AuroraGlow(m["warm"] > 0.5 ? .subtle : .standard)
                    .cornerRadius(m["corner"])
                    .borderWidth((wide ? 5 : 4) + level * 5)
                    .glowSize((wide ? 26 : 18) + level * 30)
                    .palette(m["warm"] > 0.5 ? .sunset : .appleIntelligence)
                    .frame(width: m["w"], height: m["h"])
                    .environment(\.auroraTimes, AuroraGlow.Times(
                        elapsed: c.reduceMotion ? 0 : c.t,
                        burst: c.reduceMotion ? -1 : c.t - m.value("burstAt", c.t),
                        intro: c.reduceMotion ? -1 : c.t - m.value("litAt", c.t)))
                    .opacity(m["glow"] * (c.reduceTransparency ? 0.75 : 1))
                    .offset(x: m["x"], y: m["y"])
            }
            ZStack {
                if m["c.listening"] > 0.005 {
                    Text("Listening").font(.system(size: 20, weight: .semibold)).foregroundStyle(sub)
                        .opacity(m["c.listening"])
                }
                if m["c.hearing"] > 0.005 {
                    WordStream(words: f.words, size: 24, weight: .semibold, color: ink, maxWidth: 900, reduceMotion: c.reduceMotion)
                        .opacity(m["c.hearing"])
                }
                if m["c.working"] > 0.005 {
                    ShimmerText(text: f.label, size: 20, t: c.t, base: sub, highlight: ink, reduceMotion: c.reduceMotion)
                        .opacity(m["c.working"])
                }
                if m["c.asking"] > 0.005 {
                    VStack(spacing: 14) {
                        Text(f.question).font(.system(size: 24, weight: .semibold)).foregroundStyle(ink)
                        HStack(spacing: 10) {
                            AuroraButton(title: f.options.first ?? "", key: "\u{23CE}", primary: true, dark: c.dark)
                            AuroraButton(title: f.options.dropFirst().first ?? "", key: "esc", primary: false, dark: c.dark)
                        }
                    }
                    .opacity(m["c.asking"])
                    .blur(radius: (1 - m["c.asking"]) * 6)
                }
                if m["c.done"] > 0.005 {
                    HStack(spacing: 8) {
                        Check(progress: m["check"], color: c.dark ? Color(red: 0.35, green: 0.9, blue: 0.5) : Color(red: 0.1, green: 0.6, blue: 0.3), lineWidth: 2.6)
                            .frame(width: 20, height: 20)
                        Text(f.label).font(.system(size: 22, weight: .semibold)).foregroundStyle(ink)
                    }
                    .opacity(m["c.done"])
                }
                if m["c.problem"] > 0.005 {
                    VStack(spacing: 8) {
                        Text(f.problemTitle).font(.system(size: 22, weight: .semibold)).foregroundStyle(ink)
                        Text(f.problemDetail).font(.system(size: 15)).foregroundStyle(sub)
                        AuroraButton(title: f.problemAction, key: nil, primary: false, dark: c.dark).padding(.top, 6)
                    }
                    .opacity(m["c.problem"])
                    .blur(radius: (1 - m["c.problem"]) * 6)
                }
            }
            .frame(width: Desk.size.width)
            .offset(y: Desk.menuBar + 28)
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}

struct AuroraButton: View {
    var title: String
    var key: String?
    var primary: Bool
    var dark: Bool
    var body: some View {
        let fill: Color = primary ? (dark ? .white : .black) : (dark ? Color.white.opacity(0.14) : Color.black.opacity(0.07))
        let ink: Color = primary ? (dark ? .black : .white) : (dark ? .white : .black)
        HStack(spacing: 7) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let key { Text(key).font(.system(size: 11, weight: .semibold, design: .rounded)).opacity(0.5) }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(fill, in: Capsule())
    }
}
