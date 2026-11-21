import SwiftUI
import VoiceRingKit

/// C. Lumen: the island stays compact, a notch with two ears, and the
/// light lives in a ring of voice beside the camera. Your words are captions
/// that float free under it; choices drop as two small pills. The least
/// screen it can take while still being unmistakable.
@MainActor
public enum VoiceLumen: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Lumen", axis: "Smallest footprint: a compact island, words as free captions",
        pitch: "Wins if Jarvis should stay out of the way: you glance at a ring of light and read a caption, nothing opens.",
        cost: "Captions without a card rely on a soft shadow for legibility on busy wallpapers; asks have less room for detail.",
        libraries: [Lib.voiceRing, Lib.dynamicNotchKit, Lib.swiftUISpring],
        custom: "The compact island silhouette, the caption line and the pill row.",
        skills: [SkillNote("emil-design-eng", "Frequency rule: the surface you see most gets the least motion; captions only fade and focus in."),
                 SkillNote("apple-design", "Compact island with leading and trailing ears, as on iPhone; the ring is the only thing that moves while you talk."),
                 SkillNote("choreograph", "Pills drop 40 ms apart after the caption lands; they leave together."),
                 SkillNote("gestures", "Pills are 32 pt tall hit targets with keyboard hints (return / esc)."),
                 SkillNote("remove-animations", "No width changes while you talk: the island never resizes per word.")],
        alwaysOn: true)

    static let ear: CGFloat = 56

    public static func update(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank) {
        let open = f.phase != .idle
        let w = open ? Desk.notch.width + ear * 2 : Desk.notch.width
        m.set("w", w, c.geo(open ? .spring(response: 0.42, damping: 0.78) : .spring(response: 0.34, damping: 0.95)))
        m.set("r", open ? 16 : Desk.notchRadius, c.geo(.spring(response: 0.42, damping: 0.85)))
        m.set("ears", open && c.local > (c.reduceMotion ? 0 : 0.08) || (open && c.previous != "idle") ? 1 : 0, c.fade(.easeOut(0.22)))
        m.set("level", f.phase == .hearing || f.phase == .listening ? f.level : 0, .spring(response: 0.12, damping: 1))
        for phase in [VoiceFixture.Phase.listening, .hearing, .working, .asking, .done, .problem] {
            let on = f.phase == phase && c.local > (c.reduceMotion ? 0 : 0.1)
            m.set("c." + phase.rawValue, on ? 1 : 0, on ? c.fade(.easeOut(0.26)) : c.fade(.easeOut(0.14)))
        }
        for i in 0..<2 {
            let on = (f.phase == .asking || (f.phase == .problem && i == 0)) && c.local > (c.reduceMotion ? 0 : 0.26 + Double(i) * 0.04)
            m.set("pill\(i)", on ? 1 : 0, on ? c.fade(.spring(response: 0.36, damping: 0.8)) : c.fade(.easeOut(0.12)))
        }
        m.set("check", f.phase == .done && c.local > 0.1 ? 1 : 0, c.reduceMotion ? .snap : .easeOut(0.32))
        m.set("warm", f.phase == .problem ? 1 : 0, c.fade(.easeOut(0.3)))
    }

    public static func body(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let w = m["w"]
        let ringState: VoiceState = switch f.phase {
        case .hearing, .listening: .listening
        case .working: .processing
        case .asking: .speaking
        default: .idle
        }
        return ZStack(alignment: .top) {
            NotchSilhouette(width: w, height: Desk.menuBar, ear: 8, bottomRadius: m["r"])
                .fill(Color.black)
                .frame(width: w + 40, height: Desk.menuBar)
            if m["ears"] > 0.002 {
            HStack(spacing: 0) {
                ZStack {
                    VoiceRing(.ring, state: ringState, source: .level({ m["level"] }), style: .ring(paused: c.reduceMotion), size: 24)
                        .frame(width: 24, height: 24)
                        .opacity(1 - m["warm"])
                    Circle().fill(Color(red: 1, green: 0.62, blue: 0.24)).frame(width: 9, height: 9)
                        .shadow(color: Color(red: 1, green: 0.5, blue: 0.1), radius: 6)
                        .opacity(m["warm"])
                }
                .frame(width: ear, height: Desk.menuBar)
                Spacer(minLength: Desk.notch.width)
                ZStack {
                    if f.phase == .done {
                        Check(progress: m["check"], color: Color(red: 0.35, green: 0.9, blue: 0.5), lineWidth: 2.4).frame(width: 15, height: 15)
                    } else if f.phase == .working {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Color.white.opacity(0.16), in: Circle())
                    } else if f.phase == .asking {
                        Text("?").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: ear, height: Desk.menuBar)
            }
            .frame(width: Desk.notch.width + ear * 2, height: Desk.menuBar)
            .frame(width: w, height: Desk.menuBar)
            .clipped()
            .opacity(m["ears"])
            .environment(\.colorScheme, .dark)
            }
            captions(f, c, m)
                .offset(y: Desk.menuBar + 12)
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .top)
    }

    @ViewBuilder
    static func captions(_ f: VoiceFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let ink: Color = c.dark ? .white : Color.black.opacity(0.9)
        let sub: Color = c.dark ? .white.opacity(0.66) : Color.black.opacity(0.58)
        let backing: Color = c.dark ? Color.black : Color.white
        let shadow = c.reduceTransparency ? 0 : 0.6
        VStack(spacing: 10) {
            ZStack {
                if m["c.listening"] > 0.005 {
                    Text("Listening").font(.system(size: 15, weight: .medium)).foregroundStyle(sub).opacity(m["c.listening"])
                }
                if m["c.hearing"] > 0.005 {
                    WordStream(words: f.words, size: 16, color: ink, maxWidth: 560, reduceMotion: c.reduceMotion).opacity(m["c.hearing"])
                }
                if m["c.working"] > 0.005 {
                    ShimmerText(text: f.label, size: 15, t: c.t, base: sub, highlight: ink, reduceMotion: c.reduceMotion).opacity(m["c.working"])
                }
                if m["c.asking"] > 0.005 {
                    Text(f.question).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink).opacity(m["c.asking"])
                }
                if m["c.done"] > 0.005 {
                    Text(f.label).font(.system(size: 15, weight: .medium)).foregroundStyle(sub).opacity(m["c.done"])
                }
                if m["c.problem"] > 0.005 {
                    VStack(spacing: 3) {
                        Text(f.problemTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                        Text(f.problemDetail).font(.system(size: 13)).foregroundStyle(sub)
                    }
                    .opacity(m["c.problem"])
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(backing.opacity(c.reduceTransparency ? 0.92 : 0.001))
                    .shadow(color: backing.opacity(shadow), radius: 22)
            )
            HStack(spacing: 8) {
                let labels = f.phase == .problem ? [f.problemAction] : f.options
                ForEach(Array(labels.prefix(2).enumerated()), id: \.offset) { i, label in
                    let p = m["pill\(i)"]
                    AuroraButton(title: label, key: f.phase == .asking ? (i == 0 ? "\u{23CE}" : "esc") : nil,
                                 primary: i == 0 && f.phase == .asking, dark: c.dark)
                        .opacity(p.clamped(0, 1))
                        .offset(y: c.reduceMotion ? 0 : (1 - p) * -8)
                        .scaleEffect(c.reduceMotion ? 1 : 0.94 + 0.06 * p, anchor: .top)
                }
            }
        }
    }
}
