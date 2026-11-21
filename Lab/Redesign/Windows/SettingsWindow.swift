import Aurora
import Orb
import SwiftUI
import ThinkingOrbsKit

/// Jarvis's Settings window at one instant: which part of the page is at the
/// top, whether eye tracking is on, which permissions are missing, the Live
/// voice meter and the comfort label scale. Fixture text only; the Live voice
/// share is a fixture, not a real allowance.
public struct SettingsFixture {
    public enum Live: String, CaseIterable { case unmetered, warning, cap }
    public var anchor: SettingsPane
    public var eyes: Bool
    public var missing = false
    public var live: Live = .unmetered
    /// The comfort setting's label scale (1.0...2.0); every text size and
    /// text-driven dimension multiplies by it.
    public var labelScale: Double = 1
}

public enum SettingsPane: String, CaseIterable {
    case listening, replies, live, doing, eyes, permissions, comfort, general

    var title: String {
        switch self {
        case .listening: return "Listening"
        case .replies: return "Replies"
        case .live: return "Live voice"
        case .doing: return "Doing things"
        case .eyes: return "Eye tracking"
        case .permissions: return "Permissions"
        case .comfort: return "Comfort"
        case .general: return "General"
        }
    }

    var symbol: String {
        switch self {
        case .listening: return "ear"
        case .replies: return "speaker.wave.2.fill"
        case .live: return "waveform"
        case .doing: return "hand.tap.fill"
        case .eyes: return "eye.fill"
        case .permissions: return "hand.raised.fill"
        case .comfort: return "textformat.size"
        case .general: return "gearshape.fill"
        }
    }

    var tile: Color {
        switch self {
        case .listening: return Color(red: 0.2, green: 0.5, blue: 1)
        case .replies: return Color(red: 1, green: 0.27, blue: 0.38)
        case .live: return Color(red: 0.55, green: 0.36, blue: 0.95)
        case .doing: return Color(red: 0.2, green: 0.72, blue: 0.4)
        case .eyes: return Color(red: 0.08, green: 0.62, blue: 0.86)
        case .permissions: return Color(red: 0.42, green: 0.45, blue: 0.5)
        case .comfort: return Color(red: 0.3, green: 0.38, blue: 0.92)
        case .general: return Color(red: 0.52, green: 0.54, blue: 0.58)
        }
    }
}

public enum SettingsScript {
    static let warnShare = 0.8

    /// The label scale stepping up the Comfort slider, a quarter at a time.
    static func stepping(_ t: Double) -> Double {
        guard t >= 0.5 else { return 1 }
        return min(2, 1.25 + 0.25 * floor((t - 0.5) / 0.24))
    }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("top", "Settings", caption: "The page opens at Listening: grouped rows with standard switches, and Jarvis in the sidebar showing it is listening.", duration: 2.2) { _ in
            SettingsFixture(anchor: .listening, eyes: false)
        },
        StateEntry("full", "Further down", caption: "Doing things in the sidebar: the page glides to it and the selection follows.", duration: 2.4) { _ in
            SettingsFixture(anchor: .doing, eyes: false)
        },
        StateEntry("eyes-on", "Eye tracking on", caption: "Turning eye tracking on: the switch flips, then its options open under it.", duration: 2.8) { t in
            SettingsFixture(anchor: .eyes, eyes: t >= 0.7)
        },
        StateEntry("missing-permissions", "Permissions missing", caption: "Three permissions aren't allowed yet: each row says what it is for, and the family's needs-you mark lands on them and on Jarvis in the sidebar.", duration: 2.8) { _ in
            SettingsFixture(anchor: .permissions, eyes: true, missing: true)
        },
        StateEntry("live-unmetered", "Live voice: not metered", caption: "Live voice while it isn't metered on this Mac, as it is today.", duration: 2.2) { _ in
            SettingsFixture(anchor: .live, eyes: true, live: .unmetered)
        },
        StateEntry("live-warning", "Live voice: past 80%", caption: "From the warning share on, a note says basic voice takes over at the cap. The share is a fixture, not a real allowance.", duration: 2.8) { _ in
            SettingsFixture(anchor: .live, eyes: true, live: .warning)
        },
        StateEntry("live-cap", "Live voice: at the cap", caption: "The month's Live voice is used up: basic voice until it renews. Fixture share only.", duration: 2.6) { _ in
            SettingsFixture(anchor: .live, eyes: true, live: .cap)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "The Comfort label-size slider steps from 1\u{00D7} to 2\u{00D7} and drives the whole window: type, controls, rows and sidebar grow, and the window widens to hold them.", duration: 3.2) { t in
            SettingsFixture(anchor: .comfort, eyes: true, labelScale: stepping(t))
        },
    ]

    public static let flow = ["top", "full", "eyes-on", "missing-permissions", "live-unmetered", "live-warning", "live-cap", "large", "top"]
}

/// Every animated value the page reads, gathered once per frame so the same
/// view draws the window and measures it.
@MainActor
struct SettingsLook {
    var fam: WinFamily
    var ink: WinInk
    var k: Double
    var t: Double
    var rm: Bool
    var rt: Bool
    var eyesKnob = 0.0
    var eyesFill = 0.0
    var eyesOpen = 0.0
    var eyesShow = 0.0
    var miss = 0.0
    var burst = -1.0
    var meter = 0.0
    var meterRow = 0.0
    var lv: [SettingsFixture.Live: Double] = [:]
    var warm = 0.0
    var noteRow = 0.0
    var noteWarning = 0.0
    var noteCap = 0.0
    var slider = 0.0
    var labelScale = 1.0

    init(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank, _ fam: WinFamily) {
        self.fam = fam
        ink = WinInk(c)
        k = (m.value("k", f.labelScale) * 100).rounded() / 100
        t = c.t
        rm = c.reduceMotion
        rt = c.reduceTransparency
        eyesKnob = m["eyesKnob"]
        eyesFill = m["eyesFill"]
        eyesOpen = m["eyesOpen"].clamped(0, 1.2)
        eyesShow = m["eyesShow"]
        miss = m["miss"].clamped(0, 1)
        burst = c.reduceMotion ? -1 : min(SettingsLook.burstHold, c.t - m.value("burst", c.t - 10))
        meter = m["meter"]
        meterRow = m["meterRow"].clamped(0, 1)
        for v in SettingsFixture.Live.allCases { lv[v] = m["lv.\(v.rawValue)"].clamped(0, 1) }
        warm = m["warm"].clamped(0, 1)
        noteRow = m["noteRow"].clamped(0, 1)
        noteWarning = m["note.warning"].clamped(0, 1)
        noteCap = m["note.cap"].clamped(0, 1)
        slider = m["slider"]
        labelScale = f.labelScale
    }

    /// The burst's shader time stops here, so once it has played the warm
    /// rims hold one frame instead of decaying forever.
    static let burstHold = 2.4

    var windowSize: CGSize { CGSize(width: 840 + 270 * (k - 1), height: 880) }
    var sidebarWidth: CGFloat { 224 + 80 * (k - 1) }
    var padX: CGFloat { 26 }
    var pageWidth: CGFloat { windowSize.width - sidebarWidth - 16 - padX * 2 }
    var spacing: CGFloat { 22 * k }
    var top: CGFloat { WWindow<EmptyView, EmptyView, EmptyView>.toolbar(k) + 6 }
}

@MainActor
enum SettingsMotion {
    static func update(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank, _ fam: WinFamily) {
        m.set("k", f.labelScale, c.geo(.spring(response: 0.3, damping: 1)), initial: f.labelScale)
        m.set("slider", (f.labelScale - 1), c.geo(.spring(response: 0.22, damping: 1)), initial: f.labelScale - 1)
        m.set("eyesKnob", f.eyes ? 1 : 0, c.geo(.spring(response: 0.26, damping: 0.86)))
        m.set("eyesFill", f.eyes ? 1 : 0, c.fade(.easeOut(0.2)))
        m.set("eyesOpen", f.eyes ? 1 : 0, c.geo(fam == .island ? .spring(response: 0.42, damping: 0.86) : .spring(response: 0.4, damping: 1)))
        let showing = f.eyes && m["eyesOpen"] > 0.35
        m.set("eyesShow", showing ? 1 : 0, c.fade(.easeOut(showing ? 0.22 : 0.1)))

        let landed = c.local > (c.reduceMotion ? 0 : 0.3)
        let miss = f.missing && landed
        if fam == .glow, miss, m["miss"] < 0.02 { m.set("burst", c.t, .snap) }
        m.set("miss", miss ? 1 : 0, c.fade(.easeOut(miss ? 0.3 : 0.15)))

        let metered = f.live != .unmetered
        m.set("meterRow", metered ? 1 : 0, c.geo(.spring(response: 0.4, damping: 1)))
        if landed || !metered {
            let share = f.live == .warning ? 0.82 : f.live == .cap ? 1 : 0
            m.set("meter", share, c.geo(.spring(response: 0.7, damping: 1)))
        }
        for v in SettingsFixture.Live.allCases {
            m.set("lv.\(v.rawValue)", f.live == v ? 1 : 0, c.fade(.easeOut(f.live == v ? 0.24 : 0.12)))
        }
        m.set("warm", f.live == .cap && landed ? 1 : 0, c.fade(.easeOut(0.3)))
        m.set("noteRow", metered ? 1 : 0, c.geo(.spring(response: 0.4, damping: 1)))
        let noted = c.local > (c.reduceMotion ? 0 : 0.7)
        m.set("note.warning", f.live == .warning && noted ? 1 : 0, c.fade(.easeOut(f.live == .warning ? 0.26 : 0.12)))
        m.set("note.cap", f.live == .cap && noted ? 1 : 0, c.fade(.easeOut(f.live == .cap ? 0.26 : 0.12)))

        let index = Double(SettingsPane.allCases.firstIndex(of: f.anchor) ?? 0)
        let same = abs(m.value("anchor", index) - index) < 0.01
        m.set("anchor", index, .snap)
        let look = SettingsLook(f, c, m, fam)
        let target = SettingsPage.scroll(to: f.anchor, f, look)
        m.set("scroll", target, same ? .snap : c.geo(.spring(response: 0.6, damping: 1)), initial: target)
        m.set("sel", index, c.geo(.spring(response: 0.36, damping: 0.86)), initial: index)
    }
}

/// The settings page: sections in the order people reach for them, each a
/// headline over a grouped form, the way System Settings lays out a pane.
@MainActor
enum SettingsPage {
    static func missingCount(_ f: SettingsFixture) -> Int { f.missing ? (f.eyes ? 3 : 2) : 0 }

    static func heights(_ f: SettingsFixture, _ l: SettingsLook) -> [CGFloat] {
        SettingsPane.allCases.map { pane in
            var closed = l
            closed.eyesOpen = 0
            closed.meterRow = 0
            closed.noteRow = 0
            let key = "settings-\(l.fam)-\(pane.rawValue)-\(l.k)-\(f.eyes)-\(f.missing)-\(f.live.rawValue)"
            var h = Measure.size(key, width: l.pageWidth) { section(pane, f, closed) }.height
            if pane == .eyes { h += eyeOptionsHeight(l) * l.eyesOpen }
            if pane == .live { h += meterHeight(l) * l.meterRow + noteHeight(l) * l.noteRow }
            return h
        }
    }

    static func scroll(to anchor: SettingsPane, _ f: SettingsFixture, _ l: SettingsLook) -> CGFloat {
        let hs = heights(f, l)
        let i = SettingsPane.allCases.firstIndex(of: anchor) ?? 0
        let before = hs.prefix(i).reduce(0) { $0 + $1 + l.spacing }
        let total = hs.reduce(0, +) + l.spacing * CGFloat(hs.count - 1) + 40
        let room = l.windowSize.height - l.top
        return max(0, min(before, total - room))
    }

    static func eyeOptionsHeight(_ l: SettingsLook) -> CGFloat {
        Measure.size("settings-eyeopts-\(l.k)", width: l.pageWidth) { eyeOptions(l) }.height
    }

    static func meterHeight(_ l: SettingsLook) -> CGFloat { 22 * l.k }

    static func noteHeight(_ l: SettingsLook) -> CGFloat {
        Measure.size("settings-note-\(l.k)", width: l.pageWidth) { notes(l) }.height + 6 * l.k
    }

    static func page(_ f: SettingsFixture, _ l: SettingsLook) -> some View {
        VStack(alignment: .leading, spacing: l.spacing) {
            ForEach(SettingsPane.allCases, id: \.self) { pane in section(pane, f, l) }
        }
        .frame(width: l.pageWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    static func section(_ pane: SettingsPane, _ f: SettingsFixture, _ l: SettingsLook) -> some View {
        VStack(alignment: .leading, spacing: 7 * l.k) {
            Text(pane == .doing ? "Doing things for you" : pane.title)
                .font(WType.font(.headline, l.k, .semibold)).foregroundStyle(l.ink.primary)
                .padding(.leading, 4 * l.k)
            switch pane {
            case .listening: listening(f, l)
            case .replies: replies(l)
            case .live: live(f, l)
            case .doing: doing(l)
            case .eyes: eyes(l)
            case .permissions: permissions(f, l)
            case .comfort: comfort(f, l)
            case .general: general(l)
            }
        }
        .frame(width: l.pageWidth, alignment: .leading)
    }

    static func footer(_ text: String, _ l: SettingsLook, color: Color? = nil) -> some View {
        Text(text).font(WType.font(.subheadline, l.k)).foregroundStyle(color ?? l.ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4 * l.k)
            .padding(.top, 1 * l.k)
    }

    static func listening(_ f: SettingsFixture, _ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        return VStack(alignment: .leading, spacing: 7 * k) {
            WGroup(k: k, ink: ink) {
                ZStack(alignment: .leading) {
                    WRow(title: "Listening for \u{201C}Hey Jarvis\u{201D}", detail: "Say it, then what you need.", k: k, ink: ink) {
                        WButton(title: "Pause", k: k, ink: ink)
                    }
                    .opacity(1 - l.miss)
                    if l.miss > 0.01 {
                        WRow(title: "Can't listen yet", detail: "Allow the microphone under Permissions.", k: k, ink: ink, detailColor: ink.askInk) {
                            EmptyView()
                        }
                        .opacity(l.miss)
                    }
                }
                WSeparator(k: k, ink: ink)
                radioRow("Wait for \u{201C}Hey Jarvis\u{201D}", "Listens on your Mac for its name. Nothing leaves your Mac until you say it.", on: true, l)
                WSeparator(k: k, ink: ink)
                radioRow("Hands-free", "Listens all the time, so you can just talk.", on: false, l)
                WSeparator(k: k, ink: ink)
                WRow(title: "Microphone", k: k, ink: ink) { WPopup(title: "MacBook Pro Microphone", k: k, ink: ink) }
            }
            footer("While Jarvis is listening, what you say is sent to OpenAI so it can understand you. Eye tracking never leaves your Mac.", l)
        }
    }

    static func radioRow(_ title: String, _ detail: String, on: Bool, _ l: SettingsLook) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9 * l.k) {
            WRadio(on: on, k: l.k, ink: l.ink).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 * l.k }
            VStack(alignment: .leading, spacing: 2 * l.k) {
                Text(title).font(WType.font(.body, l.k)).foregroundStyle(l.ink.primary)
                Text(detail).font(WType.font(.subheadline, l.k)).foregroundStyle(l.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12 * l.k)
        .padding(.vertical, 8 * l.k)
    }

    static func replies(_ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        return WGroup(k: k, ink: ink) {
            WRow(title: "Say replies out loud", k: k, ink: ink) { WSwitch(on: 1, k: k, ink: ink) }
            WSeparator(k: k, ink: ink)
            WRow(title: "Sounds", detail: "Chimes when a task finishes, fails or needs you. Off by default: the surface already shows these.", k: k, ink: ink) {
                WSwitch(on: 0, k: k, ink: ink)
            }
        }
    }

    static func live(_ f: SettingsFixture, _ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        let unmetered = l.lv[.unmetered] ?? 0, warning = l.lv[.warning] ?? 0, cap = l.lv[.cap] ?? 0
        return VStack(alignment: .leading, spacing: 7 * k) {
            WGroup(k: k, ink: ink) {
                ZStack(alignment: .topLeading) {
                    WRow(title: "Live voice isn't metered on this Mac", detail: "Jarvis talks with Live voice whenever it is on.", k: k, ink: ink) { EmptyView() }
                        .opacity(unmetered)
                    WRow(title: "82% of this month's Live voice used", k: k, ink: ink) {
                        Text("Renews on the 1st").font(WType.font(.callout, k)).foregroundStyle(ink.secondary)
                    }
                    .opacity(warning)
                    WRow(title: "This month's Live voice is used up", k: k, ink: ink) {
                        Text("Renews on the 1st").font(WType.font(.callout, k)).foregroundStyle(ink.secondary)
                    }
                    .opacity(cap)
                }
                meter(l)
                    .padding(.horizontal, 12 * k)
                    .frame(height: meterHeight(l) * l.meterRow, alignment: .top)
                    .clipped()
                    .opacity(l.meterRow)
            }
            notes(l)
                .frame(height: noteHeight(l) * l.noteRow, alignment: .top)
                .clipped()
        }
    }

    static func notes(_ l: SettingsLook) -> some View {
        ZStack(alignment: .topLeading) {
            footer("Most of this month's Live voice is used. Basic voice takes over when it runs out.", l)
                .opacity(l.noteWarning)
            footer("Basic voice until Live voice renews on the 1st.", l, color: l.ink.askInk)
                .opacity(l.noteCap)
        }
    }

    /// The month's share. A: a black island capsule; B: the Apple
    /// Intelligence gradient; C: a hairline with the warning share marked.
    static func meter(_ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        let fill = l.meter.clamped(0, 1)
        return GeometryReader { geo in
            let w = geo.size.width
            switch l.fam {
            case .island:
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(ink.dark ? 0.16 : 0), lineWidth: 0.5))
                    Capsule().fill(Color.white.mix(with: AgentRoster.ask, by: l.warm))
                        .frame(width: max(0, (w - 6 * k) * fill), height: 4 * k)
                        .offset(x: 3 * k)
                        .opacity(fill > 0.002 ? 1 : 0)
                }
                .frame(width: w, height: 10 * k)
            case .glow:
                let intelligence = LinearGradient(colors: [Color(red: 0.2, green: 0.55, blue: 1), Color(red: 0.66, green: 0.4, blue: 1),
                                                           Color(red: 1, green: 0.4, blue: 0.62), Color(red: 1, green: 0.62, blue: 0.3)],
                                                  startPoint: .leading, endPoint: .trailing)
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.control)
                    ZStack {
                        Capsule().fill(intelligence)
                        Capsule().fill(AgentRoster.ask).opacity(l.warm)
                    }
                    .frame(width: w * fill)
                    .opacity(fill > 0.002 ? 1 : 0)
                }
                .frame(width: w, height: 6 * k)
            case .quiet:
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.control)
                    Capsule().fill(ink.primary.mix(with: AgentRoster.ask, by: l.warm)).frame(width: w * fill)
                        .opacity(fill > 0.002 ? 1 : 0)
                    Rectangle().fill(ink.group).frame(width: 2 * k, height: 3 * k)
                        .offset(x: w * SettingsScript.warnShare)
                    Rectangle().fill(ink.secondary).frame(width: 1, height: 4 * k)
                        .offset(x: w * SettingsScript.warnShare, y: 5 * k)
                }
                .frame(width: w, height: 3 * k)
            }
        }
        .frame(height: 10 * k)
        .padding(.bottom, 12 * k)
    }

    static func doing(_ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        return VStack(alignment: .leading, spacing: 7 * k) {
            WGroup(k: k, ink: ink) {
                WRow(title: "Do it as soon as I finish speaking", detail: "Jarvis acts on what you said straight away.", k: k, ink: ink) { WSwitch(on: 1, k: k, ink: ink) }
                WSeparator(k: k, ink: ink)
                WRow(title: "Don't ask before changing things", detail: "Jarvis checks with you before it changes something.", k: k, ink: ink) { WSwitch(on: 0, k: k, ink: ink) }
                WSeparator(k: k, ink: ink)
                WRow(title: "Show where Jarvis clicks", k: k, ink: ink) { WSwitch(on: 1, k: k, ink: ink) }
                WSeparator(k: k, ink: ink)
                WRow(title: "Get help with unusual requests", detail: "When Jarvis isn't sure which app you mean, it asks an online helper. Only your words and app names are sent.", k: k, ink: ink) {
                    WSwitch(on: 1, k: k, ink: ink)
                }
                WSeparator(k: k, ink: ink)
                WRow(title: "Helper agents", detail: "Not signed in. Everyday requests don't need it.", k: k, ink: ink) {
                    WButton(title: "Sign in with ChatGPT", k: k, ink: ink)
                }
            }
            footer("Jarvis won't delete things or buy things for you.", l)
        }
    }

    static func eyes(_ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        return WGroup(k: k, ink: ink) {
            WRow(title: "Use eye tracking", detail: "Look at something and say \u{201C}click that\u{201D}. Uses the camera; nothing it sees leaves your Mac.", k: k, ink: ink) {
                WSwitch(on: l.eyesFill, knob: l.eyesKnob, k: k, ink: ink)
            }
            eyeOptions(l)
                .opacity(l.eyesShow)
                .offset(y: l.rm ? 0 : (1 - l.eyesShow) * -4 * k)
                .frame(height: eyeOptionsHeight(l) * l.eyesOpen, alignment: .top)
                .clipped()
        }
    }

    static func eyeOptions(_ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        return VStack(alignment: .leading, spacing: 0) {
            WSeparator(k: k, ink: ink)
            WRow(title: "Dot size", k: k, ink: ink) { WSegmented(items: ["Small", "Medium", "Large"], index: 1, k: k, ink: ink) }
            WSeparator(k: k, ink: ink)
            WRow(title: "Show a dot where I'm looking", detail: "When it's off, the thing you look at lights up instead.", k: k, ink: ink) { WSwitch(on: 0, k: k, ink: ink) }
            WSeparator(k: k, ink: ink)
            WRow(title: "Hold the highlight steady", k: k, ink: ink) { WSwitch(on: 1, k: k, ink: ink) }
            WSeparator(k: k, ink: ink)
            WRow(title: "Click by looking", detail: "Keep your eyes on something for a moment and Jarvis clicks it.", k: k, ink: ink) {
                WSegmented(items: ["Off", "Buttons", "Anything"], index: 0, k: k, ink: ink)
            }
            WSeparator(k: k, ink: ink)
            WRow(title: "Accuracy", detail: "About four minutes: follow the dot, then look at each target.", k: k, ink: ink) {
                WButton(title: "Check\u{2026}", k: k, ink: ink)
            }
        }
    }

    struct Permission {
        var title: String
        var allowedDetail = "Allowed"
        var reason: String
        var action: String
        var missing: Bool
    }

    static func permissionRows(_ f: SettingsFixture) -> [Permission] {
        var rows = [Permission(title: "Microphone", reason: "To hear you", action: "Open System Settings", missing: f.missing)]
        if f.eyes { rows.append(Permission(title: "Camera", reason: "For eye tracking only", action: "Allow", missing: f.missing)) }
        rows.append(Permission(title: "Screen Recording", reason: "To see what you see", action: "Allow", missing: false))
        rows.append(Permission(title: "Accessibility", reason: "To click, type and open apps", action: "Allow", missing: f.missing))
        return rows
    }

    static func permissions(_ f: SettingsFixture, _ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        let rows = permissionRows(f)
        return VStack(alignment: .leading, spacing: 7 * k) {
            WGroup(k: k, ink: ink) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, p in
                    if i > 0 { WSeparator(k: k, ink: ink) }
                    permissionRow(p, l)
                }
            }
            footer("Jarvis asks for each one the first time it needs it, and works without the camera.", l)
        }
    }

    static func permissionRow(_ p: Permission, _ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        let need = p.missing ? l.miss : 0
        return HStack(spacing: 10 * k) {
            ZStack {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16 * k))
                    .foregroundStyle(Color.white, Color(red: 0.2, green: 0.76, blue: 0.42))
                    .opacity(1 - need)
                if need > 0.01 { NeedsYouMark(family: l.fam, size: 16 * k, ink: ink).opacity(need) }
            }
            .frame(width: 18 * k, height: 18 * k)
            VStack(alignment: .leading, spacing: 2 * k) {
                Text(p.title).font(WType.font(.body, k)).foregroundStyle(ink.primary)
                ZStack(alignment: .leading) {
                    Text(p.allowedDetail).opacity(1 - need)
                    Text(p.reason).opacity(need)
                }
                .font(WType.font(.subheadline, k)).foregroundStyle(ink.secondary)
            }
            Spacer(minLength: 8 * k)
            if p.missing { allowButton(p.action, l).opacity(need).scaleEffect(l.rm ? 1 : 0.96 + 0.04 * need, anchor: .trailing) }
        }
        .padding(.horizontal, 12 * k)
        .padding(.vertical, 8 * k)
        .frame(minHeight: 36 * k)
    }

    /// A missing permission's button in each family: A the island's black
    /// capsule, B the warm Aurora rim (one burst as it arrives), C a crisp
    /// orange outline.
    @ViewBuilder
    static func allowButton(_ title: String, _ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        let w = TextMetrics.width(title, size: WType.size(.body) * k, weight: .medium) + 24 * k
        let h = 24 * k
        switch l.fam {
        case .island:
            Text(title).font(WType.font(.body, k, .medium)).foregroundStyle(.white)
                .frame(width: w, height: h)
                .background(Capsule().fill(Color.black).overlay(Capsule().strokeBorder(Color.white.opacity(ink.dark ? 0.18 : 0), lineWidth: 0.5)))
        case .glow:
            ZStack {
                AuroraEdge(size: CGSize(width: w, height: h), radius: h / 2, border: 1.6, rim: 3, bloom: 0.6,
                           times: AuroraGlow.Times(elapsed: 2.4, burst: l.burst), reduceTransparency: l.rt, palette: .sunset)
                Capsule().fill(ink.group).padding(1.6)
                Text(title).font(WType.font(.body, k, .medium)).foregroundStyle(ink.primary)
            }
            .frame(width: w, height: h)
        case .quiet:
            Text(title).font(WType.font(.body, k, .medium)).foregroundStyle(ink.askInk)
                .frame(width: w, height: h)
                .overlay(Capsule().strokeBorder(AgentRoster.ask, lineWidth: 1.5))
        }
    }

    static func comfort(_ f: SettingsFixture, _ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        let label = String(format: "%g\u{00D7}", l.labelScale)
        return WGroup(k: k, ink: ink) {
            VStack(alignment: .leading, spacing: 10 * k) {
                WRow(title: "Label size", detail: "The labels Jarvis draws over your screen, and this window.", k: k, ink: ink) {
                    Text(label).font(WType.font(.body, k, .medium).monospacedDigit()).foregroundStyle(ink.primary)
                }
                .padding(.bottom, -8 * k)
                HStack(alignment: .top, spacing: 10 * k) {
                    Text("A").font(.system(size: WType.size(.subheadline) * k, weight: .medium)).foregroundStyle(ink.secondary)
                    WSlider(value: l.slider.clamped(0, 1), ticks: 5, width: l.pageWidth - 24 * k - 2 * TextMetrics.width("A", size: 20 * k) - 20 * k, k: k, ink: ink)
                        .padding(.top, 1 * k)
                    Text("A").font(.system(size: 20 * k, weight: .medium)).foregroundStyle(ink.secondary)
                }
                .padding(.horizontal, 12 * k)
                .padding(.bottom, 10 * k)
            }
            WSeparator(k: k, ink: ink)
            WRow(title: "Spoken replies", k: k, ink: ink) {
                WSegmented(items: ["Shorter", "Standard", "Detailed"], index: 1, k: k, ink: ink)
            }
        }
    }

    static func general(_ l: SettingsLook) -> some View {
        let k = l.k, ink = l.ink
        return WGroup(k: k, ink: ink) {
            WRow(title: "Open Jarvis when I log in", detail: "Works once Jarvis is in your Applications folder.", k: k, ink: ink) { WSwitch(on: 0, k: k, ink: ink) }
        }
    }

    // MARK: Sidebar

    static func rowHeight(_ k: Double) -> CGFloat { 30 * k }

    static func sidebar(_ f: SettingsFixture, _ l: SettingsLook, _ m: MotionBank) -> some View {
        let k = l.k, ink = l.ink
        let w = l.sidebarWidth
        let count = missingCount(f)
        return VStack(alignment: .leading, spacing: 12 * k) {
            HStack(spacing: 6 * k) {
                Image(systemName: "magnifyingglass").font(.system(size: 11 * k, weight: .medium))
                Text("Search").font(WType.font(.body, k))
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink.tertiary)
            .padding(.horizontal, 9 * k)
            .frame(height: 26 * k)
            .background(Capsule().fill(ink.control))
            .padding(.horizontal, 10)
            HStack(spacing: 10 * k) {
                JarvisMark(family: l.fam, size: 34 * k, needs: l.miss, burst: l.burst, ink: ink, rt: l.rt)
                VStack(alignment: .leading, spacing: 1 * k) {
                    Text("Jarvis").font(WType.font(.body, k, .semibold)).foregroundStyle(ink.primary)
                    ZStack(alignment: .topLeading) {
                        Text("Listening for \u{201C}Hey Jarvis\u{201D}").foregroundStyle(ink.secondary).opacity(1 - l.miss)
                        if l.miss > 0.01 {
                            Text("\(count) permissions need you").foregroundStyle(ink.askInk).opacity(l.miss)
                        }
                    }
                    .font(WType.font(.subheadline, k))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4 * k)
            ZStack(alignment: .topLeading) {
                WSelection(y: m["sel"] * rowHeight(k), height: rowHeight(k), width: w - 16, k: k, ink: ink)
                VStack(spacing: 0) {
                    ForEach(SettingsPane.allCases, id: \.self) { pane in
                        HStack(spacing: 8 * k) {
                            WTile(symbol: pane.symbol, color: pane.tile, k: k)
                            Text(pane.title).font(WType.font(.body, k)).foregroundStyle(ink.primary).lineLimit(1)
                            Spacer(minLength: 0)
                            if pane == .permissions, l.miss > 0.01 {
                                Text("\(count)").font(WType.font(.subheadline, k, .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6 * k)
                                    .frame(minWidth: 18 * k, minHeight: 18 * k)
                                    .background(Capsule().fill(AgentRoster.ask))
                                    .opacity(l.miss)
                                    .scaleEffect(l.rm ? 1 : 0.85 + 0.15 * l.miss)
                            }
                        }
                        .padding(.horizontal, 8 * k)
                        .frame(width: w - 16, height: rowHeight(k))
                        .offset(x: 8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 40)
        .frame(width: w, alignment: .topLeading)
    }

    static func window(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank, _ fam: WinFamily) -> some View {
        let l = SettingsLook(f, c, m, fam)
        let size = l.windowSize
        let frame = CGRect(x: (Desk.size.width - size.width) / 2, y: 64, width: size.width, height: size.height)
        return ZStack(alignment: .topLeading) {
            WWindow(frame: frame, sidebarWidth: l.sidebarWidth, ink: l.ink, k: l.k) {
                sidebar(f, l, m)
            } toolbar: {
                Text("Settings").font(WType.font(.title3, l.k, .semibold)).foregroundStyle(l.ink.primary)
            } content: {
                page(f, l)
                    .padding(.horizontal, l.padX)
                    .offset(y: l.top - m["scroll"])
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}

/// Jarvis itself in the sidebar, the one live mark in Settings. It holds
/// still: the window can stay open for minutes and the listening state
/// doesn't change while it does.
struct JarvisMark: View {
    var family: WinFamily
    var size: CGFloat
    var needs: Double
    var burst: Double
    var ink: WinInk
    var rt: Bool

    var body: some View {
        switch family {
        case .island:
            ZStack {
                Circle().fill(Color.black)
                    .overlay(Circle().strokeBorder(Color.white.opacity(ink.dark ? 0.16 : 0), lineWidth: 0.5))
                ThinkingOrb(state: .listening, size: .px20, theme: .dark, paused: true, displaySize: size * 0.6)
                    .orbFrozenTime(nil)
                    .frame(width: size * 0.6, height: size * 0.6)
                if needs > 0.01 {
                    Circle().fill(AgentRoster.ask)
                        .overlay(Circle().strokeBorder(ink.glass.opacity(1), lineWidth: max(1.5, size * 0.06)))
                        .frame(width: size * 0.34, height: size * 0.34)
                        .offset(x: size * 0.34, y: -size * 0.34)
                        .opacity(needs)
                }
            }
            .frame(width: size, height: size)
        case .glow:
            ZStack {
                Circle().fill(ink.group)
                AuroraEdge(size: CGSize(width: size, height: size), radius: size / 2, border: 2, rim: 4, bloom: 0.7,
                           times: AuroraGlow.Times(elapsed: 2.4), reduceTransparency: rt, palette: .appleIntelligence)
                    .opacity(1 - needs)
                if needs > 0.01 {
                    AuroraEdge(size: CGSize(width: size, height: size), radius: size / 2, border: 2, rim: 4, bloom: 0.9,
                               times: AuroraGlow.Times(elapsed: 2.4, burst: burst), reduceTransparency: rt, palette: .sunset)
                        .opacity(needs)
                }
                Image(systemName: "waveform").font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(ink.primary)
            }
            .frame(width: size, height: size)
        case .quiet:
            ZStack {
                OrbView(configuration: OrbConfiguration(backgroundColors: [Color(red: 0.2, green: 0.78, blue: 0.74), Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.12, green: 0.5, blue: 0.6)],
                                                        glowColor: .white, coreGlowIntensity: 0.7,
                                                        showParticles: false, showShadow: false, speed: 0))
                    .frame(width: size, height: size)
                if needs > 0.01 {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Color.white, AgentRoster.ask)
                        .background(Circle().fill(ink.glass).padding(-1.5))
                        .offset(x: size * 0.34, y: -size * 0.34)
                        .opacity(needs)
                }
            }
            .frame(width: size, height: size)
        }
    }
}

/// The needs-you glyph beside a row in each family.
struct NeedsYouMark: View {
    var family: WinFamily
    var size: CGFloat
    var ink: WinInk
    var body: some View {
        switch family {
        case .island:
            ZStack {
                Circle().fill(Color.black)
                Circle().fill(AgentRoster.ask).frame(width: size * 0.42, height: size * 0.42)
            }
            .frame(width: size, height: size)
        case .glow:
            Circle().fill(AgentRoster.ask).frame(width: size * 0.56, height: size * 0.56)
                .shadow(color: AgentRoster.ask.opacity(0.9), radius: size * 0.25)
                .frame(width: size, height: size)
        case .quiet:
            Image(systemName: "questionmark.circle.fill").font(.system(size: size))
                .foregroundStyle(Color.white, AgentRoster.ask)
        }
    }
}

// MARK: Directions

@MainActor
public enum SettingsIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Island", axis: "Native window; Jarvis's live parts are the island's black material",
        pitch: "Wins with the Island voice surface: the window is plain System Settings, and wherever Jarvis is live or needs you (its mark, the meter, a missing permission) it is the same black island with the thinking orb.",
        cost: "Black capsules are the loudest thing on a light window, so they have to stay rare: three Allow buttons at once is the most it should ever show.",
        libraries: [Lib.thinkingOrbs, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The window kit (macOS 26 window, glass sidebar, grouped rows) and drawings of the standard switch, segmented control, slider and buttons, because ImageRenderer can't draw AppKit controls; the product uses the real ones. The black meter and Allow capsules.",
        skills: [SkillNote("apple-design", "SW-1: every size is an SF text style (body 13, subheadline 11, headline 13, title3 15 from NSFont.preferredFont) times the comfort scale, instead of hand-sized 28/17/14/13 pt; grouped rows with trailing switches and a glass sidebar like System Settings; Reduce Transparency makes the sidebar solid."),
                 SkillNote("emil-design-eng", "Restraint: no glow anywhere, and the island's black appears only on Jarvis's mark, the Live voice meter and missing permissions."),
                 SkillNote("animate", "The page glides to a section on a 0.6 s critically damped spring; the sidebar selection slides on 0.36 s / 0.86; the switch knob on 0.26 s / 0.86 while its colour fades in 0.2 s."),
                 SkillNote("choreograph", "Cause before effect: the switch flips, then eye tracking's options open under it (0.42 s / 0.86, the one bounce) and fade in once the group is a third open; the meter fills, then its note arrives 0.7 s in."),
                 SkillNote("find-animation-opportunities", "Kept: the scroll, the selection, the disclosure and the meter fill, each explaining a change. Rejected: hover lifts on rows and any entrance stagger."),
                 SkillNote("remove-animations", "The thinking orb is paused in Settings: the window can stay open for minutes and listening doesn't change, so nothing loops."),
                 SkillNote("gestures", "Every control is a standard macOS control with its own keyboard behaviour (Tab, Space, arrow keys on the slider and segments); the sidebar follows arrow keys."),
                 SkillNote("break-ui", "At 2x the window widens to 1100 pt and the sidebar to 290 pt, rows wrap their detail instead of truncating, and the page measures every section so nothing clips."),
                 SkillNote("prototype", "One of three families behind the gallery's A/B/C picker; the window chrome is identical so only the live marks differ.")],
        alwaysOn: false)

    public static func update(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank) { SettingsMotion.update(f, c, m, .island) }
    public static func body(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank) -> some View { SettingsPage.window(f, c, m, .island) }
}

@MainActor
public enum SettingsGlow: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Glow", axis: "Native window; Apple Intelligence light only where Jarvis listens or needs you",
        pitch: "Wins with the Aurora voice surface: Jarvis's mark carries a still Siri rim while it listens, missing permissions get the warm end of the same light, and the Live voice meter fills with the Apple Intelligence colours.",
        cost: "Three Aurora shaders when permissions are missing (still frames, plus one burst on arrival); the gradient meter is the only colour on the page, so it reads as more important than it is.",
        libraries: [Lib.aurora, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The window kit and control drawings shared with A and C; the still Aurora frames (elapsed time held) and the warm burst when permissions go missing.",
        skills: [SkillNote("apple-design", "SW-1 text styles times the comfort scale; light as status, not ornament: the rim marks Jarvis listening and turns warm when it needs you, the way Siri's edge light means Siri is there."),
                 SkillNote("animate", "One 0.3 s fade brings the warm rims in once the page has landed; the shader's burst plays once on that frame, and the light then holds still."),
                 SkillNote("choreograph", "Scroll lands first, then the needs-you light, the sidebar badge and the 'permissions need you' line arrive on the same frame, so they read as one event."),
                 SkillNote("remove-animations", "The Aurora rims are held at one frame (elapsed fixed): a Settings window open for minutes shouldn't breathe."),
                 SkillNote("emil-design-eng", "Glow sits on the button you have to press, not around the row or the window."),
                 SkillNote("find-animation-opportunities", "Rejected: animating the meter's gradient; it would make usage look like activity."),
                 SkillNote("gestures", "Standard controls and keyboard behaviour; the glowing button is still a plain button for Tab and Space."),
                 SkillNote("break-ui", "Reduce Transparency drops the rims' bloom and makes the sidebar solid; at 2x the rims are re-measured to the larger buttons."),
                 SkillNote("prototype", "B in the gallery's picker.")],
        alwaysOn: false)

    public static func update(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank) { SettingsMotion.update(f, c, m, .glow) }
    public static func body(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank) -> some View { SettingsPage.window(f, c, m, .glow) }
}

@MainActor
public enum SettingsQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Quiet", axis: "Quietest: System Settings as it is, crisp orange outlines when Jarvis needs you",
        pitch: "Wins if Settings should look exactly like the rest of macOS: Jarvis is a still Orb marble, missing permissions are outlined in the one needs-you orange, and the meter is a hairline with the warning share marked.",
        cost: "Nothing in it says 'Jarvis' beyond the marble; a 1.5 pt outline is easy to scroll past when permissions are missing.",
        libraries: [Lib.orb, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The window kit and control drawings shared with A and B; the hairline meter with its 80% tick.",
        skills: [SkillNote("emil-design-eng", "Restraint: one stroke weight, one accent; the meter marks where the warning starts instead of colouring the whole bar early."),
                 SkillNote("apple-design", "SW-1 text styles times the comfort scale; the page is a grouped form with standard controls, nothing custom where macOS has a control."),
                 SkillNote("animate", "Same springs as A and B (0.6 s scroll, 0.36 s selection, 0.4 s critically damped disclosure) so the families differ only in their marks."),
                 SkillNote("choreograph", "Switch, then options; meter, then note; scroll, then needs-you outlines."),
                 SkillNote("remove-animations", "The marble is still in Settings; nothing moves once a change has landed."),
                 SkillNote("find-animation-opportunities", "Rejected: a pulse on missing permissions; the outline and badge are enough."),
                 SkillNote("gestures", "Standard controls and keyboard behaviour."),
                 SkillNote("break-ui", "The question-mark badge on the marble is sized from the marble, and survives 2x without covering the name."),
                 SkillNote("prototype", "C in the gallery's picker.")],
        alwaysOn: false)

    public static func update(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank) { SettingsMotion.update(f, c, m, .quiet) }
    public static func body(_ f: SettingsFixture, _ c: Ctx, _ m: MotionBank) -> some View { SettingsPage.window(f, c, m, .quiet) }
}
