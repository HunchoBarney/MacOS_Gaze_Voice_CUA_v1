import SwiftUI

/// Chips that label targets for a voice pick: a number on every candidate
/// control, their names, or a radial fanned on the tracker's error band
/// around an ambiguous gaze. Fixture controls on the fixture Mail window.
public struct ChipsFixture {
    public enum Phase: String { case off, numbers, names, radial, lost, pick }
    public var phase: Phase
    /// The bigger-labels comfort setting (Config.labelScale): 1 to 2 in quarter steps.
    public var labelScale: Double = 1
}

struct ChipTarget {
    var frame: CGRect
    var name: String
    /// Text fields sit 36 pt apart: a corner chip would fall between two rows,
    /// so their chips sit on the field's own label instead.
    var isField: Bool { frame.width > 200 }
}

public enum ChipsScript {
    /// The candidates, in the order the numbers count them. The To field's
    /// accessibility label is long on purpose (TC-1).
    static let targets: [ChipTarget] = [
        ChipTarget(frame: Desk.Target.send, name: "Send"),
        ChipTarget(frame: Desk.Target.attach, name: "Attach"),
        ChipTarget(frame: Desk.Target.format, name: "Format"),
        ChipTarget(frame: Desk.Target.to, name: "To: Alex Rivera, Jordan Lee and 3 more"),
        ChipTarget(frame: Desk.Target.to.offsetBy(dx: 0, dy: 36), name: "Cc"),
        ChipTarget(frame: Desk.Target.subject, name: "Subject"),
    ]
    /// The radial offers the first three: the gaze sits between them.
    static let radialCount = 3
    static var gaze: CGPoint { CGPoint(x: Desk.Target.send.midX + 30, y: Desk.Target.send.midY) }
    /// The tracker's error band, in points.
    static let radius = 60.0
    /// TC-1: a name never runs wider than this (times the label scale); the full name is in the ask.
    static let cap: CGFloat = 160
    static let height: CGFloat = 24
    static let nudge: CGFloat = 6

    /// Bigger chips need a wider band to stay apart: 60 pt at 1×, 90 pt at 2×.
    static func band(_ s: Double) -> Double { radius * (0.5 + 0.5 * s) }

    struct Slot {
        var center: CGPoint
        var width: CGFloat
        var number: Bool
        var name: Bool
    }

    static func textWidth(_ s: String, _ k: Double) -> CGFloat { min(cap * k, TextMetrics.width(s, size: 12.5 * k, weight: .medium)) }
    static func nameWidth(_ s: String, _ k: Double) -> CGFloat { textWidth(s, k) + 20 * k }
    static func radialWidth(_ s: String, _ k: Double) -> CGFloat { textWidth(s, k) + 36 * k }

    /// The product's own radial geometry (TargetOverlay.radialChipCenters).
    static func radialCenters(_ k: Double) -> [CGPoint] {
        let count = radialCount
        let radius = band(k)
        let spread = min(70 * Double(count - 1), 210) * .pi / 180
        let start = -Double.pi / 2 - spread / 2
        return (0..<count).map { i in
            let theta = start + spread * Double(i) / Double(count - 1)
            return CGPoint(x: gaze.x + radius * cos(theta), y: gaze.y + radius * sin(theta))
        }
    }

    /// Where each chip sits in a phase; nil means it isn't shown. Chips never
    /// overlap: a chip that would cover an earlier one hangs under its
    /// control (buttons) or moves along its row (fields), which is what
    /// keeps Attach and Format apart and the 2× chips readable.
    static func slots(_ f: ChipsFixture) -> [Slot?] {
        let k = f.labelScale
        let h = height * k
        switch f.phase {
        case .off:
            return targets.map { _ in nil }
        case .numbers, .names:
            let names = f.phase == .names
            var placed: [CGRect] = []
            return targets.map { t in
                let w = names ? nameWidth(t.name, k) : h
                let x0 = t.isField ? t.frame.minX - (names ? 14 : 2 + h / 2) : t.frame.minX - nudge - (names ? 0 : h / 2)
                let y0 = t.isField ? t.frame.midY - h / 2 : t.frame.minY - nudge - h / 2
                var rect = CGRect(x: x0, y: y0, width: w, height: h)
                func clashes(_ r: CGRect) -> CGRect? { placed.first { $0.insetBy(dx: -3, dy: -3).intersects(r) } }
                if !t.isField, clashes(rect) != nil { rect.origin.y = t.frame.maxY + 4 }
                while t.isField, let other = clashes(rect) { rect.origin.x = other.maxX + 6 }
                placed.append(rect)
                return Slot(center: CGPoint(x: rect.midX, y: rect.midY), width: w, number: !names, name: names)
            }
        case .radial, .lost, .pick:
            let centers = radialCenters(k)
            let shown = f.phase == .pick ? 1 : radialCount
            return targets.indices.map { i in
                i < shown ? Slot(center: centers[i], width: radialWidth(targets[i].name, k), number: true, name: true) : nil
            }
        }
    }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("off", "Off", caption: "No chips: nothing asked for them.", duration: 0.8) { _ in ChipsFixture(phase: .off) },
        StateEntry("numbers", "Numbers", caption: "\u{201C}Show numbers\u{201D}: one chip on each control you can pick, counted 1 to 6.", duration: 2.0) { _ in
            ChipsFixture(phase: .numbers)
        },
        StateEntry("names", "Names", caption: "\u{201C}Show names\u{201D}: each number opens into the control's name; long names stop at 160 pt.", duration: 2.2) { _ in
            ChipsFixture(phase: .names)
        },
        StateEntry("radial", "Which one?", caption: "Your gaze is between three controls: their chips gather on the tracker's error band around it.", duration: 2.4) { _ in
            ChipsFixture(phase: .radial)
        },
        StateEntry("lost", "Gaze lost", caption: "The tracker loses your eyes: the choice waits, dimmed, and a number still works.", duration: 2.0) { _ in
            ChipsFixture(phase: .lost)
        },
        StateEntry("pick", "Pick", caption: "You say \u{201C}one\u{201D}: Send's chip confirms and the others leave.", duration: 1.8) { _ in
            ChipsFixture(phase: .pick)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "Bigger labels at 2\u{00D7}: names and numbers grow with the type, and chips that would collide step aside along their row.", duration: 2.4) { _ in
            ChipsFixture(phase: .names, labelScale: 2)
        },
        StateEntry("large-radial", "Largest labels, radial (2\u{00D7})", caption: "The radial at 2\u{00D7}: its band widens to 90 pt so the bigger chips stay apart.", duration: 2.4) { _ in
            ChipsFixture(phase: .radial, labelScale: 2)
        },
    ]

    public static let flow = ["off", "numbers", "names", "radial", "lost", "pick", "off", "large", "large-radial", "off"]
}

/// One chip's face in a family's skin. Its parts cross-fade on the bank's
/// channels, so a number can open into a name without the chip changing.
struct ChipFace: View {
    enum Skin { case island, glass, quiet }

    var skin: Skin
    var number: Int
    var name: String
    var width: CGFloat
    var showNumber: Double
    var showName: Double
    var picked: Double
    var check: Double
    var dark: Bool
    var reduceTransparency: Bool
    var scale: Double = 1

    static let quietTint = Color(red: 0.36, green: 0.46, blue: 1)
    static let green = Color(red: 0.25, green: 0.8, blue: 0.42)

    var body: some View {
        let k = scale
        let h = ChipsScript.height * k
        let nameX = (10 + 16 * showNumber) * k
        ZStack(alignment: .leading) {
            background
            numberCell
                .frame(width: h - 2, height: h - 2)
                .offset(x: 1)
            Text(name)
                .font(.system(size: 12.5 * k, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(ink)
                .frame(width: ChipsScript.textWidth(name, k), alignment: .leading)
                .opacity(showName.clamped(0, 1))
                .offset(x: nameX)
        }
        .frame(width: width, height: h, alignment: .leading)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(stroke, lineWidth: skin == .quiet ? 1 : 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(shadow), radius: skin == .quiet ? 3 : 8, y: skin == .quiet ? 1 : 3)
    }

    private var ink: Color {
        switch skin {
        case .island: return Color(white: 1 - picked)
        case .glass, .quiet: return dark ? .white : Color.black.opacity(0.86)
        }
    }

    private var stroke: Color {
        switch skin {
        case .island: return Color.white.opacity(0.16 * (1 - picked))
        case .glass: return (dark ? Color.white : Color.black).opacity(0.12)
        case .quiet:
            return picked > 0.01 ? Self.quietTint.opacity(0.35 + 0.65 * picked) : (dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14))
        }
    }

    private var shadow: Double {
        switch skin {
        case .island: return 0.3
        case .glass: return dark ? 0.35 : 0.14
        case .quiet: return dark ? 0.3 : 0.1
        }
    }

    @ViewBuilder private var background: some View {
        switch skin {
        case .island:
            Capsule().fill(Color.black.opacity(1 - picked)).overlay(Capsule().fill(Color.white.opacity(picked)))
        case .glass:
            Capsule().fill(dark ? Color(white: 0.1).opacity(reduceTransparency ? 1 : 0.82) : Color.white.opacity(reduceTransparency ? 1 : 0.86))
        case .quiet:
            Capsule().fill(dark ? Color(white: 0.15) : Color.white)
        }
    }

    @ViewBuilder private var numberCell: some View {
        let n = showNumber.clamped(0, 1)
        ZStack {
            switch skin {
            case .island:
                Text("\(number)").font(.system(size: 13 * scale, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    .opacity(1 - check)
                Check(progress: check, color: Color(red: 0.1, green: 0.62, blue: 0.3), lineWidth: 2 * scale).frame(width: 11 * scale, height: 11 * scale)
            case .glass:
                Circle().fill(AngularGradient(colors: ChipFace.aurora + [ChipFace.aurora[0]], center: .center))
                    .frame(width: 18 * scale, height: 18 * scale)
                Text("\(number)").font(.system(size: 11.5 * scale, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1)
                    .opacity(1 - check)
                Check(progress: check, color: .white, lineWidth: 2 * scale).frame(width: 9 * scale, height: 9 * scale)
            case .quiet:
                Circle().fill(Self.green).frame(width: 18 * scale, height: 18 * scale).opacity(check > 0 ? 1 : 0)
                Text("\(number)").font(.system(size: 13 * scale, weight: .semibold, design: .rounded)).foregroundStyle(Self.quietTint)
                    .opacity(1 - check)
                Check(progress: check, color: .white, lineWidth: 2 * scale).frame(width: 9 * scale, height: 9 * scale)
            }
        }
        .opacity(n)
    }

    /// Apple Intelligence's warm-cool anchors, as the Aurora palette defines them.
    static let aurora: [Color] = [
        Color(red: 0.983, green: 0.392, blue: 1.0), Color(red: 1.0, green: 0.145, blue: 0.333),
        Color(red: 1.0, green: 0.577, blue: 0.0), Color(red: 0.0, green: 0.588, blue: 1.0),
    ]
}

/// The motion all three families share: where chips go and when they show.
/// Each family passes its own springs; the geometry is the product's.
@MainActor
enum ChipsMotion {
    struct Tuning {
        var move: MotionSpec
        var appear: MotionSpec
        /// 1 ripples chips out from the gaze (about 0.1 s across the window); 0 shows them together.
        var ripple: Double
    }

    static func update(_ f: ChipsFixture, _ c: Ctx, _ m: MotionBank, _ k: Tuning) {
        let slots = ChipsScript.slots(f)
        let gaze = ChipsScript.gaze
        for i in ChipsScript.targets.indices {
            var slot = slots[i]
            if f.phase == .pick, c.local > 1.15 { slot = nil }
            guard let s = slot else {
                m.set("on\(i)", 0, c.fade(.easeOut(0.14)))
                continue
            }
            let shown = m["on\(i)"] > 0.02
            let move: MotionSpec = shown ? c.geo(k.move) : .snap
            m.set("x\(i)", s.center.x, move)
            m.set("y\(i)", s.center.y, move)
            m.set("w\(i)", s.width, move)
            m.set("num\(i)", s.number ? 1 : 0, c.fade(.easeOut(0.18)))
            m.set("name\(i)", s.name ? 1 : 0, c.fade(.easeOut(s.name ? 0.22 : 0.12)))
            let distance = hypot(s.center.x - gaze.x, s.center.y - gaze.y)
            let delay = c.reduceMotion ? 0 : min(0.12, distance / 5000) * k.ripple
            if shown || c.local >= delay { m.set("on\(i)", 1, c.fade(k.appear)) }
        }
        let hub = [.radial, .lost].contains(f.phase) || (f.phase == .pick && c.local < 0.1)
        m.set("hub", hub ? 1 : 0, hub ? c.fade(.easeOut(0.24)) : c.fade(.easeOut(0.16)))
        m.set("dim", f.phase == .lost ? 1 : 0, c.fade(.easeOut(f.phase == .lost ? 0.4 : 0.2)))
        let lostCaption = f.phase == .lost && c.local > (c.reduceMotion ? 0 : 0.35)
        m.set("say", lostCaption ? 1 : 0, lostCaption ? c.fade(.spring(response: 0.32, damping: 0.86)) : c.fade(.easeOut(0.12)))
        m.set("pick", f.phase == .pick ? 1 : 0, c.fade(.easeOut(f.phase == .pick ? 0.16 : 0.12)))
        m.set("check", f.phase == .pick && c.local > 0.12 ? 1 : 0, c.reduceMotion ? .snap : .easeOut(0.3))
        m.set("scale", f.labelScale, c.geo(k.move))
        m.set("band", ChipsScript.band(f.labelScale), c.geo(k.move))
    }

    /// A chip's scale while it enters or leaves: never from zero.
    static func scale(_ on: Double, _ c: Ctx) -> Double { c.reduceMotion ? 1 : 0.9 + 0.1 * on }

    /// \"Say 1, 2 or 3\" under the dimmed radial while the gaze is lost.
    static func sayCaption(_ m: MotionBank, _ c: Ctx, fill: Color, ink: Color) -> some View {
        let p = m["say"].clamped(0, 1)
        let k = m.value("scale", 1)
        return Text("Say 1, 2 or 3")
            .font(.system(size: 12 * k, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 10 * k)
            .frame(height: 24 * k)
            .background(Capsule().fill(fill))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .fixedSize()
            .opacity(p)
            .offset(y: c.reduceMotion ? 0 : (1 - p) * -6)
            .frame(width: 400)
            .offset(x: ChipsScript.gaze.x - 200, y: ChipsScript.gaze.y + 30 * k)
    }
}
