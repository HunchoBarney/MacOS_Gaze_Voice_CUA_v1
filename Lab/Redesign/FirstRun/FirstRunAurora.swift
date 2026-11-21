import Aurora
import SwiftUI

/// B. Aurora: a quiet native page whose step tile lights with Siri's light
/// only while Jarvis is live, waiting for you in System Settings or
/// listening for your first request, and bursts once when a permission
/// flips. The waiting line shimmers.
@MainActor
public enum FirstRunAurora: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Aurora", axis: "A native page; the step's tile lights while Jarvis waits or listens",
        pitch: "Wins with the Aurora voice surface: the page is plain macOS until Jarvis is live, then the same Apple Intelligence light rims the step's tile, waiting with you (FR-1), swelling with your voice when you try it, and bursting once when a switch flips.",
        cost: "Shader light on a settings-like page is the most GPU of the three while waiting, and the shimmer is a second moving thing next to it.",
        libraries: [Lib.aurora, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The tile and the mapping of each step to light (on while waiting and listening, a burst when granted, off otherwise); the shimmer is batch 1's ShimmerText.",
        skills: [SkillNote("find-animation-opportunities", "FR-1: the waiting line shimmers and the tile's light runs while Jarvis watches for the switch; when it flips, one burst and a check, then the light goes out."),
                 SkillNote("emil-design-eng", "Light only where Jarvis is live: the tile is grey on ask, refused and done, so the glow means 'Jarvis is with you right now', never decoration."),
                 SkillNote("apple-design", "FR-2: the shared radius scale (window 16, tile 14, capsules); SF Symbols' variable value turns the tile's waveform into a level meter in Try it."),
                 SkillNote("choreograph", "Light leads: the burst lands on the frame the permission flips, the check replaces the symbol 0.16 s later, the words follow."),
                 SkillNote("animate", "The light fades in over 0.3 s and out over 0.6 s; voice level drives it through a critically damped 0.12 s spring."),
                 SkillNote("remove-animations", "No glow while you read a step that isn't waiting on anything, and none at all under Reduce Motion beyond a still rim."),
                 SkillNote("break-ui", "Largest labels (2x): the window widens and measures its words; the tile stays its size, as it carries no text."),
                 SkillNote("gestures", "The default button takes return, the secondary esc; Check again stays available while the light runs.")],
        alwaysOn: true)

    static let tile: CGFloat = 60
    static let style = SetupWindow.Style(key: "B", centered: false, statusRow: true, ink: false, heroHeight: { _ in tile })

    public static func update(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) {
        SetupWindow.update(f, c, m, style)
        let live = f.status == .waiting || f.status == .listening || (f.status == .granted && c.local < 0.7)
        m.set("fb.glow", live ? 1 : 0, live ? c.fade(.easeOut(0.3)) : c.fade(.easeOut(0.6)))
        if f.status == .granted || (live && c.previous != nil && SetupScript.fixture(of: c.previous)?.status != f.status) {
            m.set("fb.burstAt", c.t - c.local, .snap)
        }
        m.set("fb.level", f.status == .listening ? f.level : 0, .spring(response: 0.12, damping: 1))
        let before = SetupScript.fixture(of: c.previous).map(SetupScript.heroKey)
        for sample in SetupScript.samples {
            let key = SetupScript.heroKey(sample)
            let on = key == SetupScript.heroKey(f) && (c.reduceMotion || c.previous == nil || before == key || c.local > 0.16)
            m.set("fb." + key, on ? 1 : 0, on ? c.fade(.easeOut(0.22)) : c.fade(.easeOut(0.1)))
        }
    }

    public static func body(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        SetupWindow.body(f, c, m, style, hero: hero(f, c, m)) { s in status(s, c) }
    }

    static func hero(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let glow = m["fb.glow"].clamped(0, 1), level = m["fb.level"]
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let times = AuroraGlow.Times(elapsed: c.reduceMotion ? 0 : c.t, burst: c.reduceMotion ? -1 : c.t - m.value("fb.burstAt", -10))
        return ZStack {
            shape.fill((c.dark ? Color.white : Color.black).opacity(c.dark ? 0.08 : 0.05))
            if glow > 0.005 {
                AuroraEdge(size: CGSize(width: tile, height: tile), radius: 14, border: 2 + level * 2.5, rim: 6 + level * 8, bloom: 0.8,
                           times: times, reduceTransparency: c.reduceTransparency)
                    .opacity(glow)
            }
            ForEach(SetupScript.samples.indices, id: \.self) { i in
                let sample = SetupScript.samples[i]
                let p = m["fb." + SetupScript.heroKey(sample)].clamped(0, 1)
                if p > 0.005 { symbol(sample, c, m).modifier(SymbolIn(p: p, reduceMotion: c.reduceMotion)) }
            }
        }
        .frame(width: tile, height: tile)
    }

    @ViewBuilder
    static func symbol(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let ink: Color = c.dark ? .white.opacity(0.9) : Color.black.opacity(0.78)
        let font = Font.system(size: 26, weight: .medium)
        switch (f.step, f.status) {
        case (_, .granted), (_, .done):
            Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold)).foregroundStyle(ShellAccent.green)
        case (.microphone, .refused):
            Image(systemName: "mic.slash.fill").font(font).foregroundStyle(ink.opacity(0.7))
        case (.microphone, _):
            Image(systemName: "mic.fill").font(font).foregroundStyle(ink)
        case (.accessibility, _):
            Image(systemName: "accessibility").font(font).foregroundStyle(ink)
        case (.tryIt, _):
            Image(systemName: "waveform", variableValue: (0.15 + m["fb.level"] * 1.6).clamped(0, 1)).font(font).foregroundStyle(ink)
        }
    }

    @ViewBuilder
    static func status(_ f: SetupFixture, _ c: Ctx) -> some View {
        let k = f.labelScale
        let ink: Color = c.dark ? .white : Color.black.opacity(0.85)
        let sub: Color = c.dark ? .white.opacity(0.5) : Color.black.opacity(0.45)
        let text = SetupScript.status(f) ?? ""
        if f.status == .granted {
            HStack(spacing: 6 * k) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14 * k)).foregroundStyle(ShellAccent.green)
                Text(text).font(.system(size: 14 * k, weight: .medium)).foregroundStyle(ink)
            }
        } else {
            ShimmerText(text: text, size: 14 * k, t: c.t, base: sub, highlight: ink, reduceMotion: c.reduceMotion)
        }
    }
}
