import Orb
import SwiftUI

/// C. Native: macOS Setup Assistant's grammar. A large SF Symbol over
/// centred words, the system's own spinner beside the waiting line, a check
/// drawn when the switch flips, and the Orb marble, still, as Jarvis in
/// Try it with a crisp level meter. No glow.
@MainActor
public enum FirstRunQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Native", axis: "Quietest: Setup Assistant's grammar, the system spinner, no light",
        pitch: "Wins if first run should feel like macOS setting itself up: a big symbol, centred words, the spinner you already read as 'working' (FR-1), and the marble you'll see as Jarvis's item. Nothing glows, so the page reads as trustworthy rather than magical.",
        cost: "The least memorable first meeting of the three: nothing here teaches you what Jarvis looks like when it's live, beyond the marble.",
        libraries: [Lib.orb, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The spinner (AppKit's eight-tick indicator on the stage clock, because ImageRenderer can't run NSProgressIndicator), the drawn check and the three-bar level meter.",
        skills: [SkillNote("find-animation-opportunities", "FR-1: the waiting line gets the system's indeterminate spinner; when the switch flips the spinner gives way to a check drawn over 0.4 s, and the page moves on."),
                 SkillNote("apple-design", "FR-2: one radius scale (window 16, controls capsules), hierarchical SF Symbols at 44 pt as in Setup Assistant, centred words with the title tracked tighter as it grows."),
                 SkillNote("remove-animations", "The marble is still and the symbols swap with a fade; the spinner and the level meter are the only moving parts, and both mean something."),
                 SkillNote("choreograph", "The symbol changes first, the words 0.12 s later; the buttons cross-fade in place, so your pointer never chases a button."),
                 SkillNote("animate", "Symbols arrive with SF Symbols' replace shape (70% scale, 2 pt blur, 0.22 s); the check is an ease-out stroke, the spinner steps 12 ticks a second like AppKit's."),
                 SkillNote("emil-design-eng", "The default button is the system accent capsule with return; everything else is grey, so there's one obvious next step."),
                 SkillNote("break-ui", "Largest labels (2x): centred words wrap inside a measured, wider window; spinner, check and meter scale with the line they sit on."),
                 SkillNote("gestures", "Keyboard first: return for the default, esc for Not now, tab between the two capsules.")],
        alwaysOn: true)

    static let style = SetupWindow.Style(key: "C", centered: true, statusRow: true, ink: false, heroHeight: { _ in 56 })

    public static func update(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) {
        SetupWindow.update(f, c, m, style)
        m.set("fc.level", f.status == .listening ? f.level : 0, .spring(response: 0.1, damping: 1))
        let before = SetupScript.fixture(of: c.previous).map(heroKey)
        for key in Set(SetupScript.samples.map(heroKey)) {
            let on = key == heroKey(f) && (c.reduceMotion || c.previous == nil || before == key || c.local > 0.08)
            m.set("fc." + key, on ? 1 : 0, on ? c.fade(.easeOut(0.22)) : c.fade(.easeOut(0.1)))
        }
    }

    /// Waiting doesn't change the symbol, only the line under the words.
    static func heroKey(_ f: SetupFixture) -> String {
        switch (f.step, f.status) {
        case (.microphone, .refused): return "mic-off"
        case (.microphone, _): return "mic"
        case (.accessibility, .granted), (.tryIt, .done): return "done"
        case (.accessibility, _): return "accessibility"
        case (.tryIt, _): return "jarvis"
        }
    }

    public static func body(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        SetupWindow.body(f, c, m, style, hero: hero(f, c, m)) { s in status(s, c, m) }
    }

    static let marble = OrbConfiguration(backgroundColors: [Color(red: 0.55, green: 0.35, blue: 1), Color(red: 0.42, green: 0.52, blue: 1), .cyan],
                                         glowColor: .white, coreGlowIntensity: 0.9, showParticles: false, showShadow: false, speed: 0)

    static func hero(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let blue = ShellAccent.blue(c.dark)
        let grey: Color = c.dark ? .white.opacity(0.45) : Color.black.opacity(0.35)
        return ZStack {
            ForEach(["mic", "mic-off", "accessibility", "jarvis", "done"], id: \.self) { key in
                let p = m["fc." + key].clamped(0, 1)
                if p > 0.005 {
                    Group {
                        switch key {
                        case "mic": Image(systemName: "mic.fill").font(.system(size: 44, weight: .regular)).foregroundStyle(blue)
                        case "mic-off": Image(systemName: "mic.slash.fill").font(.system(size: 44, weight: .regular)).foregroundStyle(grey)
                        case "accessibility": Image(systemName: "accessibility").font(.system(size: 44, weight: .regular)).foregroundStyle(blue)
                        case "jarvis": Marble(configuration: marble, size: 50)
                        default: Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.white, ShellAccent.green)
                        }
                    }
                    .modifier(SymbolIn(p: p, reduceMotion: c.reduceMotion))
                }
            }
        }
        .frame(width: 60, height: 56)
    }

    @ViewBuilder
    static func status(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let k = f.labelScale
        let sub: Color = c.dark ? .white.opacity(0.55) : Color.black.opacity(0.5)
        let ink: Color = c.dark ? .white.opacity(0.9) : Color.black.opacity(0.8)
        let text = SetupScript.status(f) ?? ""
        HStack(spacing: 8 * k) {
            switch f.status {
            case .granted:
                Check(progress: c.reduceMotion ? 1 : m["fr.check"], color: ShellAccent.green, lineWidth: 2 * k).frame(width: 15 * k, height: 15 * k)
            case .listening:
                HStack(alignment: .center, spacing: 2 * k) {
                    ForEach(0..<3, id: \.self) { i in
                        let level = m["fc.level"] * [0.7, 1, 0.8][i]
                        Capsule().fill(ink).frame(width: 2.5 * k, height: (4 + 11 * level.clamped(0, 1)) * k)
                    }
                }
                .frame(width: 15 * k, height: 15 * k)
            default:
                SetupSpinner(size: 15 * k, t: c.t, reduceMotion: c.reduceMotion, color: sub)
            }
            Text(text).font(.system(size: 14 * k, weight: f.status == .granted ? .medium : .regular))
                .foregroundStyle(f.status == .granted ? ink : sub)
        }
    }
}
