import SwiftUI

/// The first-run window: microphone, Accessibility and a first request.
/// Words are the product's (FirstRun.swift) apart from the new waiting
/// lines and the granted state, which FR-1 asks for.
public struct SetupFixture {
    public enum Step: String { case microphone, accessibility, tryIt = "try-it" }
    public enum Status: String { case ask, waiting, refused, granted, listening, done }
    public var step: Step
    public var status: Status
    /// The bigger-labels comfort setting (Config.labelScale): 1 to 2 in quarter steps.
    public var labelScale: Double = 1
    /// Microphone level while Jarvis hears you in Try it.
    public var level: Double = 0
}

public enum SetupScript {
    static func number(_ f: SetupFixture) -> Int {
        switch f.step { case .microphone: return 2; case .accessibility: return 3; case .tryIt: return 4 }
    }

    static func title(_ f: SetupFixture) -> String {
        switch f.step {
        case .microphone: return "Let Jarvis hear you"
        case .accessibility: return "Let Jarvis use your Mac"
        case .tryIt: return f.status == .done ? "That worked" : "Try it"
        }
    }

    static func body(_ f: SetupFixture) -> String {
        switch (f.step, f.status) {
        case (.microphone, .waiting): return "Choose Allow in the box that just opened."
        case (.microphone, .refused): return "Jarvis can't hear you yet. In System Settings, open Privacy & Security, then Microphone, and switch on Jarvis."
        case (.microphone, _): return "Jarvis needs the microphone to hear what you ask."
        case (.accessibility, .waiting), (.accessibility, .granted):
            return "In System Settings, switch on Jarvis in the Accessibility list. This page moves on by itself when you do."
        case (.accessibility, _): return "To click, type and open apps for you, Jarvis needs Accessibility. macOS will ask you to switch it on in System Settings."
        case (.tryIt, .done): return "You're all set. Say \u{201C}help\u{201D} any time to hear what Jarvis can do."
        case (.tryIt, _): return "Say \u{201C}Hey Jarvis, open Calculator\u{201D}."
        }
    }

    /// The line under the words that shows Jarvis is still watching (FR-1).
    static func status(_ f: SetupFixture) -> String? {
        switch (f.step, f.status) {
        case (.microphone, .waiting): return "Waiting for your answer\u{2026}"
        case (.accessibility, .waiting): return "Waiting for you to switch it on\u{2026}"
        case (.accessibility, .granted): return "Accessibility is on"
        case (.tryIt, .listening): return "Listening\u{2026}"
        default: return nil
        }
    }

    static func buttons(_ f: SetupFixture) -> (secondary: String?, primary: String) {
        switch (f.step, f.status) {
        case (.microphone, .refused), (.accessibility, .waiting): return ("Check again", "Open System Settings")
        case (.accessibility, .granted): return (nil, "Continue")
        case (.tryIt, .done): return (nil, "Done")
        case (.tryIt, _): return ("Skip", "Done")
        default: return ("Not now", "Allow")
        }
    }

    static func headKey(_ f: SetupFixture) -> String { "\(number(f))|\(title(f))" }
    static func bodyKey(_ f: SetupFixture) -> String { body(f) }
    static func statusKey(_ f: SetupFixture) -> String { "\(f.status.rawValue)|\(status(f) ?? "")" }
    static func footerKey(_ f: SetupFixture) -> String { "\(buttons(f).secondary ?? "")|\(buttons(f).primary)" }
    static func heroKey(_ f: SetupFixture) -> String { "\(f.step.rawValue)|\(f.status.rawValue)" }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("microphone", "Microphone", caption: "Step 2: Jarvis asks for the microphone.", duration: 2.0) { _ in
            SetupFixture(step: .microphone, status: .ask)
        },
        StateEntry("microphone-waiting", "Microphone, waiting", caption: "macOS's own prompt is open; the window shows it is waiting for your answer.", duration: 2.2) { _ in
            SetupFixture(step: .microphone, status: .waiting)
        },
        StateEntry("microphone-refused", "Microphone refused", caption: "You chose Don't Allow: the way back through System Settings, and Check again.", duration: 2.2) { _ in
            SetupFixture(step: .microphone, status: .refused)
        },
        StateEntry("accessibility", "Accessibility", caption: "Step 3: Jarvis asks to use your Mac.", duration: 2.0) { _ in
            SetupFixture(step: .accessibility, status: .ask)
        },
        StateEntry("accessibility-waiting", "Accessibility, waiting", caption: "FR-1: while you switch it on in System Settings, the window shows a sign of life instead of static grey text.", duration: 2.6) { _ in
            SetupFixture(step: .accessibility, status: .waiting)
        },
        StateEntry("accessibility-granted", "Accessibility granted", caption: "FR-1: the switch flips, the wait resolves into a check, and the page moves on by itself.", duration: 2.0) { _ in
            SetupFixture(step: .accessibility, status: .granted)
        },
        StateEntry("try-it", "Try it", caption: "Step 4: Jarvis is listening for your first request.", duration: 2.6) { t in
            SetupFixture(step: .tryIt, status: .listening, level: t > 0.5 ? VoiceScript.speech(t - 0.5, until: 1.6) : 0.03)
        },
        StateEntry("try-it-done", "That worked", caption: "Calculator opened: you're set up.", duration: 2.0) { _ in
            SetupFixture(step: .tryIt, status: .done)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "Bigger labels at 2\u{00D7}: text, buttons and spacing double and the window grows to hold them, with nothing clipped.", duration: 2.6) { _ in
            SetupFixture(step: .accessibility, status: .waiting, labelScale: 2)
        },
    ]

    public static let flow = ["microphone", "microphone-waiting", "microphone-refused", "accessibility", "accessibility-waiting",
                              "accessibility-granted", "try-it", "try-it-done", "large", "microphone"]

    @MainActor
    static func fixture(of state: String?) -> SetupFixture? {
        guard let state, let entry = states.first(where: { $0.id == state }) else { return nil }
        return entry.fixture(0) as? SetupFixture
    }

    /// One fixture per distinct screen, at 1x.
    @MainActor
    static let samples: [SetupFixture] = states.compactMap { $0.fixture(0) as? SetupFixture }.filter { $0.labelScale == 1 }
}

/// A capsule push button at macOS 26's large control size. Primary is the
/// default button (return): accent, or ink for the island family.
struct SetupButton: View {
    var title: String
    var primary: Bool
    var ink: Bool
    var dark: Bool
    var k: Double

    var body: some View {
        let fill: Color = primary ? (ink ? (dark ? .white : .black) : ShellAccent.blue(dark))
            : (dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
        let text: Color = primary ? (ink && dark ? .black : .white) : (dark ? .white.opacity(0.92) : .black.opacity(0.85))
        Text(title)
            .font(.system(size: 13 * k, weight: primary ? .semibold : .regular))
            .foregroundStyle(text)
            .padding(.horizontal, 16 * k)
            .frame(height: 30 * k)
            .background(Capsule().fill(fill))
            .fixedSize()
    }
}

/// Words arriving in the window: opacity, a 6 pt rise and a little blur
/// (first run is rare, so it may take a quarter second); Reduce Motion keeps
/// the fade only.
struct SetupFocus: ViewModifier {
    var p: Double
    var reduceMotion: Bool
    func body(content: Content) -> some View {
        content
            .opacity(p)
            .offset(y: reduceMotion ? 0 : (1 - p) * 6)
            .blur(radius: reduceMotion ? 0 : (1 - p) * 4)
    }
}

/// The window every first-run direction shares: chrome, the words, the
/// buttons and how they change. A direction supplies its hero and its
/// status line. One radius scale (FR-2): window 16, tiles 14, controls capsules.
@MainActor
enum SetupWindow {
    struct Style {
        var key: String
        var centered: Bool
        var statusRow: Bool
        var ink: Bool
        var heroHeight: (Double) -> CGFloat
    }

    static let radius: CGFloat = 16
    static func width(_ k: Double) -> CGFloat { 520 + 240 * (k - 1) }
    static func pad(_ k: Double) -> CGFloat { 36 + 8 * (k - 1) }
    static func titleBar(_ k: Double) -> CGFloat { 30 + 10 * k }
    static let top: CGFloat = 96

    static func head(_ f: SetupFixture, _ s: Style, dark: Bool) -> some View {
        let k = f.labelScale
        return VStack(alignment: s.centered ? .center : .leading, spacing: 5 * k) {
            Text("Step \(SetupScript.number(f)) of 4").font(.system(size: 13 * k, weight: .medium))
                .foregroundStyle(dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45))
            Text(SetupScript.title(f)).font(.system(size: 26 * k, weight: .bold)).tracking(-0.5 * k)
                .foregroundStyle(dark ? Color.white : Color.black.opacity(0.88))
        }
        .multilineTextAlignment(s.centered ? .center : .leading)
    }

    static func bodyText(_ f: SetupFixture, _ s: Style, dark: Bool) -> some View {
        Text(SetupScript.body(f))
            .font(.system(size: 15 * f.labelScale)).lineSpacing(3 * f.labelScale)
            .foregroundStyle(dark ? Color.white.opacity(0.86) : Color.black.opacity(0.78))
            .multilineTextAlignment(s.centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func inner(_ k: Double) -> CGFloat { width(k) - 2 * pad(k) }

    /// The tallest set of words at this label size, so the buttons never move between steps.
    static func textHeight(_ k: Double, _ s: Style) -> CGFloat {
        let a: HorizontalAlignment = s.centered ? .center : .leading
        return SetupScript.samples.enumerated().map { i, sample in
            var f = sample
            f.labelScale = k
            return Measure.size("setup-\(s.key)-\(i)-\(k)", width: inner(k)) {
                VStack(alignment: a, spacing: 0) {
                    head(f, s, dark: true).padding(.bottom, 12 * k)
                    bodyText(f, s, dark: true)
                    if s.statusRow, SetupScript.status(f) != nil {
                        Color.clear.frame(height: 20 * k).padding(.top, 14 * k)
                    }
                }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: a, vertical: .top))
            }.height
        }.max() ?? 0
    }

    static func size(_ k: Double, _ s: Style) -> CGSize {
        CGSize(width: width(k), height: titleBar(k) + 10 * k + s.heroHeight(k) + 18 * k + textHeight(k, s) + 28 * k + 30 * k + pad(k) * 0.8)
    }

    static func update(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank, _ s: Style) {
        let before = SetupScript.fixture(of: c.previous)
        let slots: [(String, (SetupFixture) -> String)] = [("h", SetupScript.headKey), ("b", SetupScript.bodyKey),
                                                           ("s", SetupScript.statusKey), ("f", SetupScript.footerKey)]
        for (slot, key) in slots {
            let current = key(f)
            for k in Set(SetupScript.samples.map(key)) {
                let stays = before.map(key) == current
                let on = k == current && (c.reduceMotion || c.previous == nil || stays || c.local > 0.12)
                m.set("fr.\(slot).\(k)", on ? 1 : 0, on ? c.fade(.easeOut(0.26)) : c.fade(.easeOut(0.12)))
            }
        }
        let size = self.size(f.labelScale, s)
        m.set("fr.w", size.width, c.geo(.spring(response: 0.42, damping: 1)))
        m.set("fr.h", size.height, c.geo(.spring(response: 0.42, damping: 1)))
        let resolved = f.status == .granted || f.status == .done
        let check = resolved && (c.previous == nil || c.reduceMotion || c.local > 0.16)
        m.set("fr.check", check ? 1 : 0, check ? c.geo(.easeOut(0.4)) : .snap)
    }

    static func sample(for key: String, _ slot: (SetupFixture) -> String, _ f: SetupFixture) -> SetupFixture {
        var s = SetupScript.samples.first { slot($0) == key } ?? f
        s.labelScale = f.labelScale
        s.level = f.level
        return s
    }

    static func body<Hero: View, Status: View>(_ f: SetupFixture, _ c: Ctx, _ m: MotionBank, _ s: Style,
                                               hero: Hero, @ViewBuilder status: @escaping (SetupFixture) -> Status) -> some View {
        let k = f.labelScale
        let w = m["fr.w"], h = m["fr.h"]
        let frame = CGRect(x: (Desk.size.width - w) / 2, y: top, width: w, height: h)
        let dark = c.dark
        let a: HorizontalAlignment = s.centered ? .center : .leading
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let keys = { (slot: (SetupFixture) -> String) in Array(Set(SetupScript.samples.map(slot))).sorted() }
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .top) {
                shape.fill(dark ? Color(white: 0.15) : Color(white: 0.99))
                chrome(k, dark: dark)
                VStack(alignment: a, spacing: 0) {
                    hero.frame(height: s.heroHeight(k))
                        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: a, vertical: .center))
                        .padding(.bottom, 18 * k)
                    ZStack(alignment: Alignment(horizontal: a, vertical: .top)) {
                        ForEach(keys(SetupScript.headKey), id: \.self) { key in
                            let p = m["fr.h.\(key)"].clamped(0, 1)
                            if p > 0.005 { head(sample(for: key, SetupScript.headKey, f), s, dark: dark).modifier(SetupFocus(p: p, reduceMotion: c.reduceMotion)) }
                        }
                    }
                    .padding(.bottom, 12 * k)
                    ZStack(alignment: Alignment(horizontal: a, vertical: .top)) {
                        ForEach(keys(SetupScript.bodyKey), id: \.self) { key in
                            let p = m["fr.b.\(key)"].clamped(0, 1)
                            if p > 0.005 { bodyText(sample(for: key, SetupScript.bodyKey, f), s, dark: dark).modifier(SetupFocus(p: p, reduceMotion: c.reduceMotion)) }
                        }
                    }
                    if s.statusRow {
                        ZStack(alignment: Alignment(horizontal: a, vertical: .top)) {
                            ForEach(keys(SetupScript.statusKey), id: \.self) { key in
                                let p = m["fr.s.\(key)"].clamped(0, 1)
                                let sf = sample(for: key, SetupScript.statusKey, f)
                                if p > 0.005, SetupScript.status(sf) != nil {
                                    status(sf).modifier(SetupFocus(p: p, reduceMotion: c.reduceMotion))
                                }
                            }
                        }
                        .padding(.top, 14 * k)
                    }
                }
                .frame(width: inner(k), alignment: Alignment(horizontal: a, vertical: .top))
                .padding(.top, titleBar(k) + 10 * k)
                .frame(width: w, height: h, alignment: .top)
                ZStack(alignment: .bottom) {
                    ForEach(keys(SetupScript.footerKey), id: \.self) { key in
                        let p = m["fr.f.\(key)"].clamped(0, 1)
                        if p > 0.005 {
                            footer(sample(for: key, SetupScript.footerKey, f), s, dark: dark).opacity(p)
                        }
                    }
                }
                .frame(width: inner(k), height: h - pad(k) * 0.8, alignment: .bottom)
            }
            .frame(width: w, height: h)
            .clipShape(shape)
            .overlay(shape.strokeBorder((dark ? Color.white : Color.black).opacity(dark ? 0.14 : 0.1), lineWidth: 0.5))
            .compositingGroup()
            .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 36, y: 18)
            .offset(x: frame.minX, y: frame.minY)
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func chrome(_ k: Double, dark: Bool) -> some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
                Spacer()
            }
            .padding(.leading, 18)
            Text("Set up Jarvis").font(.system(size: 13 * k, weight: .semibold))
                .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.8))
        }
        .frame(height: titleBar(k))
    }

    static func footer(_ f: SetupFixture, _ s: Style, dark: Bool) -> some View {
        let b = SetupScript.buttons(f)
        return HStack {
            if let secondary = b.secondary { SetupButton(title: secondary, primary: false, ink: s.ink, dark: dark, k: f.labelScale) }
            Spacer()
            SetupButton(title: b.primary, primary: true, ink: s.ink, dark: dark, k: f.labelScale)
        }
    }
}

/// AppKit's indeterminate spinner (eight ticks, the lead one solid), on the
/// stage clock so clips render it; held at one frame under Reduce Motion.
struct SetupSpinner: View {
    var size: CGFloat
    var t: Double
    var reduceMotion: Bool
    var color: Color

    var body: some View {
        let lead = reduceMotion ? 0 : Int(t * 12) % 8
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: size * 0.13, height: size * 0.3)
                    .offset(y: -size * 0.32)
                    .rotationEffect(.degrees(Double(i) * 45))
                    .opacity(1 - Double((lead - i + 8) % 8) * 0.105)
            }
        }
        .frame(width: size, height: size)
    }
}
