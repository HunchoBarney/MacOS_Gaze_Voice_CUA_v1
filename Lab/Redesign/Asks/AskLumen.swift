import SwiftUI
import VoiceRingKit

/// C. Lumen pills: the island stays compact; the ask is a caption under it
/// and its answers drop as two pills, 40 ms apart. The voice ring in the
/// left ear listens when the answer is spoken; a problem turns it into a
/// warm dot.
@MainActor
public enum AskLumen: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Lumen pills", axis: "Smallest: a caption and two pills under a compact island",
        pitch: "Wins with the Lumen voice surface: even a question takes one line and two pills, and the notch never grows.",
        cost: "Less room for detail: the heard words and the folder move share the caption, and the caption relies on a soft backing to stay legible over busy windows.",
        libraries: [Lib.voiceRing, Lib.dynamicNotchKit, Lib.swiftUISpring],
        custom: "The caption layouts per ask and the ear glyphs; compact island, ring and pills are batch 1's Lumen parts.",
        skills: [SkillNote("emil-design-eng", "LI-5: pills sized to their words with key hints, and a quiet \u{201C}or say\u{201D} line, instead of blue bordered buttons in a fixed 420 pt card."),
                 SkillNote("choreograph", "The caption lands, then the pills drop 40 ms apart from 8 pt above (0.36 s at 0.8 damping); when the ask changes they leave together in 0.12 s."),
                 SkillNote("apple-design", "Compact island with leading and trailing ears as on iPhone: the ring is the only moving thing, and only while it is your turn to talk."),
                 SkillNote("remove-animations", "The island never resizes between asks; only the caption's text and the pill count change."),
                 SkillNote("gestures", "Pills are 32 pt tall with return and esc mapped; the open question shows Cancel alone, because the answer is spoken."),
                 SkillNote("break-ui", "Captions are capped at 560 pt and wrap to two lines; Reduce Transparency puts an opaque backing behind them.")],
        alwaysOn: true)

    static let ear: CGFloat = VoiceLumen.ear

    public static func update(_ f: AskFixture, _ c: Ctx, _ m: MotionBank) {
        let open = f.phase != .idle
        m.set("w", open ? Desk.notch.width + ear * 2 : Desk.notch.width,
              c.geo(open ? .spring(response: 0.42, damping: 0.78) : .spring(response: 0.34, damping: 0.95)))
        m.set("r", open ? 16 : Desk.notchRadius, c.geo(.spring(response: 0.42, damping: 0.85)))
        m.set("ears", open && (c.local > (c.reduceMotion ? 0 : 0.08) || c.previous != "idle") ? 1 : 0, c.fade(.easeOut(0.22)))
        m.set("level", f.phase == .question ? f.level : 0, .spring(response: 0.12, damping: 1))
        m.set("warm", f.phase == .problem ? 1 : 0, c.fade(.easeOut(0.3)))
        AskMotion.content(f, c, m, delay: 0.1, enter: 0.26)
        let count = AskScript.actions(f.phase).primary == nil ? 1 : 2
        for i in 0..<2 {
            let on = open && i < count && c.local > (c.reduceMotion ? 0 : 0.26 + Double(i) * 0.04)
            m.set("pill\(i)", on ? 1 : 0, on ? c.fade(.spring(response: 0.36, damping: 0.8)) : c.fade(.easeOut(0.12)))
        }
    }

    public static func body(_ f: AskFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let w = m["w"]
        return ZStack(alignment: .top) {
            NotchSilhouette(width: w, height: Desk.menuBar, ear: 8, bottomRadius: m["r"])
                .fill(Color.black)
                .frame(width: w + 40, height: Desk.menuBar)
            if m["ears"] > 0.002 { ears(f, c, m, w: w) }
            VStack(spacing: 10 * f.labelScale) {
                caption(c, m, f.labelScale)
                pills(f, c, m)
            }
            .padding(f.labelScale > 1 ? 12 * f.labelScale : 0)
            .background(
                RoundedRectangle(cornerRadius: 28 * f.labelScale, style: .continuous)
                    .fill((c.dark ? Color.black : Color.white).opacity(c.reduceTransparency ? 0.92 : 0.001))
                    .shadow(color: (c.dark ? Color.black : Color.white).opacity(f.labelScale > 1 && !c.reduceTransparency ? 0.7 : 0), radius: 30)
            )
            .offset(y: Desk.menuBar + 12)
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .top)
    }

    static func ears(_ f: AskFixture, _ c: Ctx, _ m: MotionBank, w: CGFloat) -> some View {
        HStack(spacing: 0) {
            ZStack {
                VoiceRing(.ring, state: f.phase == .question ? .listening : .speaking, source: .level({ m["level"] }),
                          style: .ring(paused: c.reduceMotion), size: 24)
                    .frame(width: 24, height: 24)
                    .opacity(1 - m["warm"])
                Circle().fill(Color(red: 1, green: 0.62, blue: 0.24)).frame(width: 9, height: 9)
                    .shadow(color: Color(red: 1, green: 0.5, blue: 0.1), radius: 6)
                    .opacity(m["warm"])
            }
            .frame(width: ear, height: Desk.menuBar)
            Spacer(minLength: Desk.notch.width)
            Text("?").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                .opacity(1 - m["warm"])
                .frame(width: ear, height: Desk.menuBar)
        }
        .frame(width: Desk.notch.width + ear * 2, height: Desk.menuBar)
        .frame(width: w, height: Desk.menuBar)
        .clipped()
        .opacity(m["ears"])
        .environment(\.colorScheme, .dark)
    }

    static func caption(_ c: Ctx, _ m: MotionBank, _ k: Double) -> some View {
        let ink: Color = c.dark ? .white : Color.black.opacity(0.9)
        let sub: Color = c.dark ? .white.opacity(0.66) : Color.black.opacity(0.58)
        let backing: Color = c.dark ? Color.black : Color.white
        return ZStack {
            line(.review, m, c) {
                VStack(spacing: 3 * k) {
                    Text("Check what I heard").font(.system(size: 12.5 * k, weight: .medium)).foregroundStyle(sub)
                    Text("\u{201C}" + AskScript.heard + "\u{201D}").font(.system(size: 16 * k, weight: .semibold)).foregroundStyle(ink)
                }
            }
            line(.question, m, c) {
                VStack(spacing: 3 * k) {
                    Text(AskScript.question).font(.system(size: 16 * k, weight: .semibold)).foregroundStyle(ink)
                    ShimmerText(text: "Listening for your answer", size: 13 * k, t: c.t, base: sub, highlight: ink, reduceMotion: c.reduceMotion)
                }
            }
            line(.approval, m, c) {
                VStack(spacing: 5 * k) {
                    Text(AskScript.approval).font(.system(size: 16 * k, weight: .semibold)).foregroundStyle(ink)
                    HStack(spacing: 5 * k) {
                        Image(systemName: "folder.fill").foregroundStyle(Color(red: 0.36, green: 0.66, blue: 1))
                        Text(AskScript.from)
                        Image(systemName: "arrow.right").font(.system(size: 10 * k, weight: .semibold))
                        Image(systemName: "folder.fill").foregroundStyle(Color(red: 0.36, green: 0.66, blue: 1))
                        Text(AskScript.to)
                    }
                    .font(.system(size: 12.5 * k, weight: .medium))
                    .foregroundStyle(sub)
                }
            }
            line(.problem, m, c) {
                VStack(spacing: 3 * k) {
                    Text(AskScript.problemTitle).font(.system(size: 16 * k, weight: .semibold)).foregroundStyle(ink)
                    Text(AskScript.problemDetail).font(.system(size: 13 * k)).foregroundStyle(sub)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: min(560 * k, 1000))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14 * k)
        .padding(.vertical, 6 * k)
        .background(
            Capsule().fill(backing.opacity(c.reduceTransparency ? 0.92 : 0.001))
                .shadow(color: backing.opacity(c.reduceTransparency ? 0 : 0.6), radius: 22)
        )
        .environment(\.reduceMotionForAsks, c.reduceMotion)
    }

    @ViewBuilder
    static func line<Content: View>(_ phase: AskFixture.Phase, _ m: MotionBank, _ c: Ctx, @ViewBuilder _ content: () -> Content) -> some View {
        let p = m["c." + phase.rawValue].clamped(0, 1)
        if p > 0.005 {
            content().opacity(p).blur(radius: c.reduceMotion ? 0 : (1 - p) * 4)
        }
    }

    static func pills(_ f: AskFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let a = AskScript.actions(f.phase)
        let labels = [a.primary, a.secondary].compactMap { $0 }
        let k = f.labelScale
        let sub: Color = c.dark ? .white.opacity(0.55) : Color.black.opacity(0.5)
        return AnswerRow(say: a.say, color: sub, scale: k, centered: true) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                let p = m["pill\(i)"]
                let primary = a.primary != nil && i == 0
                AuroraButton(title: label, key: primary ? "\u{23CE}" : "esc", primary: primary, dark: c.dark, scale: k)
                    .opacity(p.clamped(0, 1))
                    .offset(y: c.reduceMotion ? 0 : (1 - p) * -8)
                    .scaleEffect(c.reduceMotion ? 1 : 0.94 + 0.06 * p, anchor: .top)
            }
        }
        .opacity(f.phase == .idle ? 0 : 1)
    }
}
