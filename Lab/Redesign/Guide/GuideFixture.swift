import AppKit
import SwiftUI

/// One guide step as the callout sees it: the words, the control they point
/// at, whether the step has consequences, and the text size setting.
public struct GuideFixture {
    public enum Phase: String { case off, appear, next, consequential, large, dismissed }
    public var phase: Phase
    public var visible: Bool
    public var step: Int
    public var total = 3
    public var text: String
    public var target: CGRect
    public var radius: Double
    public var warning = false
    /// The comfort setting's label scale (1.0...2.0): type, padding and the
    /// width cap all grow with it; the callout never goes below 17 pt.
    public var labelScale: Double = 1
}

public enum GuideScript {
    static let attach = "Click the paperclip to attach the deck."
    static let subject = "Check the subject says \u{201C}Q4 deck\u{201D}."
    static let send = "This sends the email to Alex Rivera."

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("off", "No step", caption: "No guide is running: nothing is drawn.", duration: 0.8) { _ in
            GuideFixture(phase: .off, visible: false, step: 1, text: attach, target: Desk.Target.attach, radius: 7)
        },
        StateEntry("appear", "Points at a control", caption: "Step one: the callout grows out of the control it points at, and the control lights.", duration: 2.0) { _ in
            GuideFixture(phase: .appear, visible: true, step: 1, text: attach, target: Desk.Target.attach, radius: 7)
        },
        StateEntry("next", "Next step", caption: "The step changes: the same callout travels to the next control and its words cross-fade.", duration: 2.2) { _ in
            GuideFixture(phase: .next, visible: true, step: 2, text: subject, target: Desk.Target.subject, radius: 6)
        },
        StateEntry("consequential", "A step with consequences", caption: "Pressing Send can't be undone: the callout names the effect first and takes the warning tone.", duration: 2.4) { _ in
            GuideFixture(phase: .consequential, visible: true, step: 3, text: send, target: Desk.Target.send, radius: 8, warning: true)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "The bigger-labels comfort setting at its largest: 34 pt words, padding and width grow together, the card wraps to two lines and stays inside the window.", duration: 2.2) { _ in
            GuideFixture(phase: .large, visible: true, step: 3, text: send, target: Desk.Target.send, radius: 8, warning: true, labelScale: 2)
        },
        StateEntry("dismissed", "Dismissed", caption: "You pressed Send or said \u{201C}stop\u{201D}: the callout returns into the control in 120 ms and the light goes.", duration: 1.4) { _ in
            GuideFixture(phase: .dismissed, visible: false, step: 3, text: send, target: Desk.Target.send, radius: 8, warning: true, labelScale: 2)
        },
    ]

    public static let flow = ["off", "appear", "next", "consequential", "large", "dismissed"]
}

/// Layout and shared motion for the guide directions. Sizes follow the
/// product callout (Sources/Jarvis/UI/GuideCallout.swift): 17 pt semibold
/// minimum, 300 pt wide at 1x, 16 pt clear of the control.
@MainActor
enum GuideMotion {
    static let gap: CGFloat = 16
    /// The region the callout must stay inside (the component's crop, less a margin).
    static let bounds = CGRect(x: 306, y: 151, width: 900, height: 460)

    static func font(_ scale: Double) -> CGFloat { max(17, (17 * scale).rounded()) }
    static func padding(_ scale: Double) -> CGSize { CGSize(width: (14 * max(1, scale)).rounded(), height: (11 * max(1, scale)).rounded()) }
    static func counterFont(_ scale: Double) -> CGFloat { max(12, (12 * scale).rounded()) }

    static func textSize(_ text: String, size: CGFloat, maxWidth: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let r = (text as NSString).boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// The card's frame below the target, centred on it and kept in bounds;
    /// `extra` is width a direction adds (a glyph column).
    static func card(_ f: GuideFixture, extra: CGFloat = 0) -> CGRect {
        let pad = padding(f.labelScale)
        let maxText = 300 * max(1, f.labelScale) - 2 * pad.width - extra
        let text = textSize(f.text, size: font(f.labelScale), maxWidth: maxText)
        let counter = counterFont(f.labelScale) + 6
        let counterWidth = TextMetrics.width(counterText(f.step, f), size: counterFont(f.labelScale), weight: .medium) + (f.warning ? counterFont(f.labelScale) + 5 : 0)
        let w = max(text.width, counterWidth) + extra + 2 * pad.width
        let h = counter + text.height + 2 * pad.height
        var x = f.target.midX - w / 2
        x = min(max(x, bounds.minX), bounds.maxX - w)
        return CGRect(x: x, y: f.target.maxY + gap, width: w, height: h)
    }

    /// Card geometry, presence and the entry offset, shared by every direction.
    static func update(_ f: GuideFixture, _ c: Ctx, _ m: MotionBank, extra: CGFloat = 0,
                       travel: MotionSpec = .spring(response: 0.42, damping: 0.86)) {
        let r = card(f, extra: extra)
        let shown = m.value("on", 0) > 0.01
        let spec: MotionSpec = shown ? c.geo(travel) : .snap
        m.set("x", r.minX, spec); m.set("y", r.minY, spec)
        m.set("w", r.width, spec); m.set("h", r.height, spec)
        m.set("scale", f.labelScale, shown ? c.geo(travel) : .snap)
        m.set("on", f.visible ? 1 : 0, f.visible ? c.fade(.spring(response: 0.3, damping: 1)) : c.fade(.easeOut(0.12)))
        m.set("rise", f.visible ? 1 : 0, f.visible ? c.geo(.spring(response: 0.34, damping: 0.82)) : c.geo(.easeOut(0.12)))
        let tshown = m.value("ton", 0) > 0.01
        let tspec: MotionSpec = tshown ? c.geo(travel) : .snap
        m.set("tx", f.target.minX, tspec); m.set("ty", f.target.minY, tspec)
        m.set("tw", f.target.width, tspec); m.set("th", f.target.height, tspec)
        m.set("tr", f.radius, tspec)
        m.set("ton", f.visible ? 1 : 0, f.visible ? c.fade(.spring(response: 0.3, damping: 1)) : c.fade(.easeOut(0.2)))
        m.set("warn", f.warning ? 1 : 0, c.fade(.spring(response: 0.3, damping: 1)))
        for step in 1...3 {
            let on = f.visible && f.step == step && (c.reduceMotion || c.previous == nil || c.local > 0.08 || stepOf(c.previous) == step)
            m.set("t\(step)", on ? 1 : 0, on ? c.fade(.easeOut(0.2)) : c.fade(.easeOut(0.1)))
        }
        let arrived = f.visible && c.local > 0.3 && c.local < 0.42 && f.phase != .large
        m.set("pop", arrived ? 1 : 0, c.reduceMotion ? .snap : .spring(response: 0.28, damping: 0.7))
    }

    static func counterText(_ step: Int, _ f: GuideFixture) -> String {
        step == 3 && f.warning ? "Step \(step) of \(f.total) \u{00B7} Can\u{2019}t be undone" : "Step \(step) of \(f.total)"
    }

    static func stepOf(_ state: String?) -> Int {
        switch state {
        case "next": return 2
        case "consequential", "large", "dismissed": return 3
        case "off", "appear": return 1
        default: return 0
        }
    }

    static func frame(_ m: MotionBank) -> CGRect { CGRect(x: m["x"], y: m["y"], width: m["w"], height: m["h"]) }

    static func target(_ m: MotionBank, outset: Double) -> CGRect {
        CGRect(x: m["tx"] - outset, y: m["ty"] - outset, width: m["tw"] + 2 * outset, height: m["th"] + 2 * outset)
    }

    /// The step's words and the counter above them, laid out for one step;
    /// directions stack the three steps and fade between them.
    static func words(_ step: Int, _ f: GuideFixture, _ m: MotionBank, ink: Color, secondary: Color, warnInk: Color) -> some View {
        let s = m.value("scale", 1)
        let text = step == 1 ? GuideScript.attach : step == 2 ? GuideScript.subject : GuideScript.send
        let warning = step == 3 && f.warning
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if warning {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: counterFont(s) - 1, weight: .semibold))
                        .foregroundStyle(warnInk)
                }
                Text(counterText(step, f))
                    .font(.system(size: counterFont(s), weight: .medium))
                    .foregroundStyle(warning ? warnInk : secondary)
            }
            Text(text)
                .font(.system(size: font(s), weight: .semibold))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(m["t\(step)"].clamped(0, 1))
    }
}
