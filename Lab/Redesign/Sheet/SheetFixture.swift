import SwiftUI

/// "Things you can say": the phrases Jarvis understands, and the same
/// surface reused for L7's "Type this?" drafts. Phrases are the product's
/// own list (VoiceTaskCoordinator.cheatSheet); the category labels are new.
public struct SheetFixture {
    public enum Phase: String { case off, eyesOff = "eyes-off", eyesOn = "eyes-on", typeThis = "type-this" }
    public var phase: Phase
    /// The bigger-labels comfort setting (Config.labelScale): 1 to 2 in quarter steps.
    public var labelScale: Double = 1
    public var shows: Bool { phase != .off }
    public var list: Bool { phase == .eyesOff || phase == .eyesOn }
}

struct SheetRow {
    var label: String
    var phrases: [String]
}

public enum SheetScript {
    static let rows: [SheetRow] = [
        SheetRow(label: "Apps", phrases: ["open Safari", "hide Mail", "quit Notes"]),
        SheetRow(label: "Controls", phrases: ["click Save", "show me Save", "show names"]),
        SheetRow(label: "Move", phrases: ["scroll down", "new tab", "go back"]),
        SheetRow(label: "Write", phrases: ["type <text>", "start dictating"]),
        SheetRow(label: "Undo", phrases: ["do that again", "cancel that", "what did you do"]),
        SheetRow(label: "Agents", phrases: ["ask <agent> to <task>", "stop <agent>"]),
        SheetRow(label: "Listening", phrases: ["pause listening"]),
    ]
    static let eyes = SheetRow(label: "Eyes", phrases: ["click this", "what is this", "recalibrate"])
    static let draftTitle = "Type this?"
    static let draft = "The Q3 deck is ready. Hiring is on slide 4 and the revenue bridge is on slide 9."

    /// Row pitch and header height at 1×; both grow with the label scale.
    static let rowHeight: CGFloat = 27
    static let header: CGFloat = 30

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("off", "Off", caption: "Nothing asked: no sheet.", duration: 0.8) { _ in SheetFixture(phase: .off) },
        StateEntry("eyes-off", "Eye tracking off", caption: "You ask \u{201C}what can I say?\u{201D}: the phrases Jarvis understands, by what they do.", duration: 2.6) { _ in
            SheetFixture(phase: .eyesOff)
        },
        StateEntry("eyes-on", "Eye tracking on", caption: "With eye tracking on, the sheet grows by one row of things you can say about what you look at.", duration: 2.2) { _ in
            SheetFixture(phase: .eyesOn)
        },
        StateEntry("type-this", "Type this?", caption: "The same surface holds a draft before Jarvis types it: you say \u{201C}type it\u{201D} or \u{201C}change it\u{201D}.", duration: 2.8) { _ in
            SheetFixture(phase: .typeThis)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "Bigger labels at 2\u{00D7}: the sheet widens to its cap, then long rows wrap under their phrase column instead of clipping.", duration: 2.6) { _ in
            SheetFixture(phase: .eyesOn, labelScale: 2)
        },
        StateEntry("large-draft", "Largest labels, draft (2\u{00D7})", caption: "The draft at 2\u{00D7}: it wraps to more lines and the card grows to hold them.", duration: 2.4) { _ in
            SheetFixture(phase: .typeThis, labelScale: 2)
        },
    ]

    public static let flow = ["off", "eyes-off", "eyes-on", "type-this", "off", "large", "large-draft", "off"]
}

/// One row: a quiet category label, then the phrases with their
/// placeholders set in italic and soft dots between them.
struct SheetLine: View {
    var row: SheetRow
    var ink: Color
    var sub: Color
    var faint: Color
    var size: CGFloat = 14
    var scale: CGFloat = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(row.label)
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(sub)
                .frame(width: 76 * scale, alignment: .leading)
            phrases
                .font(.system(size: size * scale))
                .lineSpacing(3 * scale)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, (SheetScript.rowHeight - size * 1.2) / 2 * scale)
    }

    private var phrases: Text {
        var out = Text("")
        for (i, phrase) in row.phrases.enumerated() {
            if i > 0 { out = Text("\(out)\(Text("  \u{00B7}  ").foregroundStyle(faint))") }
            for (j, part) in phrase.split(separator: "<", omittingEmptySubsequences: false).enumerated() {
                if j == 0 {
                    out = Text("\(out)\(Text(String(part)).foregroundStyle(ink))")
                    continue
                }
                let pieces = part.split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false)
                let slot = Text(String(pieces[0])).italic().foregroundStyle(sub)
                let rest = Text(pieces.count > 1 ? String(pieces[1]) : "").foregroundStyle(ink)
                out = Text("\(out)\(slot)\(rest)")
            }
        }
        return out
    }
}

/// The eye glyph that says eye tracking is on.
struct EyesOnTag: View {
    var color: Color
    var scale: CGFloat = 1
    var body: some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: "eye").font(.system(size: 11 * scale, weight: .semibold))
            Text("Eyes on").font(.system(size: 11.5 * scale, weight: .medium))
        }
        .foregroundStyle(color)
    }
}

/// The list, laid out the same way for drawing and for measuring.
struct SheetList<Title: View>: View {
    var scale: CGFloat
    var width: CGFloat
    var eyes: Bool
    var eyesP: (opacity: Double, blur: Double, y: Double) = (1, 0, 0)
    var ink: Color
    var sub: Color
    var faint: Color
    var size: CGFloat = 14
    var tag: Color
    @ViewBuilder var title: Title

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                title
                Spacer()
                EyesOnTag(color: tag, scale: scale).opacity(eyesP.opacity)
            }
            .frame(height: SheetScript.header * scale, alignment: .top)
            ForEach(SheetScript.rows.indices, id: \.self) { i in
                SheetLine(row: SheetScript.rows[i], ink: ink, sub: sub, faint: faint, size: size, scale: scale)
            }
            if eyes {
                SheetLine(row: SheetScript.eyes, ink: ink, sub: sub, faint: faint, size: size, scale: scale)
                    .opacity(eyesP.opacity)
                    .blur(radius: eyesP.blur)
                    .offset(y: eyesP.y)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

@MainActor
enum SheetMotion {
    /// Content groups: the list holds while eyes-off becomes eyes-on (only the
    /// new row arrives); the list and the draft never show together.
    static func content(_ f: SheetFixture, _ c: Ctx, _ m: MotionBank, delay: Double) {
        let list = f.list && (m["c.list"] > 0.5 || c.local > (c.reduceMotion ? 0 : delay))
        m.set("c.list", list ? 1 : 0, list ? c.fade(.easeOut(0.24)) : c.fade(.easeOut(0.12)))
        let eyes = f.phase == .eyesOn && (m["c.eyes"] > 0.5 || c.local > (c.reduceMotion ? 0 : delay + 0.06))
        m.set("c.eyes", eyes ? 1 : 0, eyes ? c.fade(.easeOut(0.26)) : c.fade(.easeOut(0.12)))
        let draft = f.phase == .typeThis && c.local > (c.reduceMotion ? 0 : delay)
        m.set("c.draft", draft ? 1 : 0, draft ? c.fade(.easeOut(0.24)) : c.fade(.easeOut(0.12)))
    }

    /// Content that focuses in: opacity, a little blur and a 4 pt drop.
    static func focus(_ p: Double, _ c: Ctx) -> (opacity: Double, blur: Double, y: Double) {
        let q = p.clamped(0, 1)
        return (q, c.reduceMotion ? 0 : (1 - q) * 4, c.reduceMotion ? 0 : (1 - q) * -4)
    }
}
