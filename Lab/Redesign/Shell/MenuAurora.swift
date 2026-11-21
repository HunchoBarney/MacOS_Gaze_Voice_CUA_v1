import Aurora
import SwiftUI

/// B. Live row: still a real NSMenu, but while Jarvis is live its first item
/// is a custom view, a card with what Jarvis is doing and the one control
/// for it (Stop, or Answer), rimmed in Siri's light. At rest the menu is
/// plain, with the status as a section header. The item is the Aurora waveform.
@MainActor
public enum MenuAurora: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Live row", axis: "A real NSMenu whose first row is lit while Jarvis is live",
        pitch: "Stays an NSMenu for the keyboard and VoiceOver, with one custom-view item at the top (NSMenuItem.view) because that's where Jarvis is live: what it's doing and the control that stops or answers it, in the same light as the Aurora voice surface. The light goes out when Jarvis is at rest.",
        cost: "A custom-view item doesn't take the menu's highlight or type-to-select, so Stop and Answer also need their own keys (esc and return), and the card is shader light inside a menu, the most GPU of the three while open.",
        libraries: [Lib.aurora, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The live card and its rim mapping (palette per state, burst on change); everything else is NSMenu (sectionHeader, key equivalents, subtitle).",
        skills: [SkillNote("apple-design", "MM-1: Eyes is a real section header with its state; the live card is the only custom view, the rest is the system menu."),
                 SkillNote("emil-design-eng", "The light marks the one live thing in the menu, the task or the questions, never the menu itself; a warm rim means it's waiting on you."),
                 SkillNote("animate", "The menu opens on the system's terms (instant, fades out over 0.15 s); only the card's rim fades in over 0.3 s with a shader burst, and cross-fades palettes when the state changes."),
                 SkillNote("choreograph", "Menu and card arrive together, then the light: cause (menu opened) before effect (Jarvis is live)."),
                 SkillNote("remove-animations", "Rows never animate; at rest there is no card and no light, so most opens cost nothing."),
                 SkillNote("gestures", "Stop shows esc and Answer return, the keys that work while the menu is open; the rest is NSMenu's keyboard."),
                 SkillNote("break-ui", "At 2x the card's text and button double and the card measures itself, so a long task name wraps rather than running under Stop.")],
        alwaysOn: true)

    static func live(_ f: MenuFixture) -> Bool { f.task || f.asks > 0 }

    public static func update(_ f: MenuFixture, _ c: Ctx, _ m: MotionBank) {
        ItemAurora.update(f.item, c, m)
        m.set("mm.open", f.open ? 1 : 0, f.open ? .snap : c.fade(.easeOut(0.15)))
        let lit = f.open && live(f)
        m.set("mm.glow", lit ? 1 : 0, lit ? c.fade(.easeOut(0.3)) : c.fade(.easeOut(0.2)))
        m.set("mm.warm", f.asks > 0 && !f.task ? 1 : 0, c.fade(.easeOut(0.3)))
        if lit, c.previous != nil, let before = MenuScript.fixture(of: c.previous), !(before.open && live(before)) || before.task != f.task {
            m.set("mm.burstAt", c.t - c.local, .snap)
        }
    }

    static func cardPad(_ k: Double) -> CGFloat { 11 * k }

    static func cardHeight(_ f: MenuFixture, width: CGFloat) -> CGFloat {
        let k = f.labelScale
        let inner = width - 2 * cardPad(k)
        return Measure.size("menuB-card-\(f.task)-\(k)", width: inner) { cardContent(f, dark: true) }.height + 2 * cardPad(k)
    }

    public static func body(_ f: MenuFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let k = f.labelScale
        let itemWidth = ItemAurora.width(k)
        let open = m["mm.open"].clamped(0, 1)
        let isLive = live(f)
        let rows = MenuScript.rows(f, statusHeader: !isLive, asksItem: false)
        let mt = NativeMenu.Metrics(k: k)
        let width = NativeMenu.width(rows, mt, minimum: 260 * k)
        let cardW = width - 2 * mt.inset - 2 * 4
        let card = isLive ? cardHeight(f, width: cardW) : 0
        let top = isLive ? card + 2 * 4 + mt.separator : 0
        let size = CGSize(width: width, height: NativeMenu.height(rows, mt) + top)
        let origin = NativeMenu.origin(itemWidth: itemWidth, width: size.width)
        return ZStack(alignment: .topLeading) {
            StatusBar.openHighlight(c, width: itemWidth, opacity: f.open ? 1 : 0).offset(x: StatusBar.trailing - itemWidth)
            ItemAurora.glyph(f.item, c, m).offset(x: StatusBar.trailing - itemWidth)
            if open > 0.005 {
                ZStack(alignment: .topLeading) {
                    ShellGlass(frame: CGRect(origin: origin, size: size), radius: 12, scheme: c.scheme, showsMail: true,
                               reduceTransparency: c.reduceTransparency)
                    VStack(spacing: 0) {
                        if isLive {
                            liveCard(f, c, m, size: CGSize(width: cardW, height: card))
                                .padding(.top, mt.inset + 4)
                            Rectangle().fill((c.dark ? Color.white : Color.black).opacity(0.1))
                                .frame(width: width - 2 * mt.inset - 20, height: 1)
                                .frame(height: mt.separator)
                                .padding(.top, 4 - mt.inset)
                        }
                        NativeMenu.rows(rows, mt, c, highlight: f.highlight, width: width)
                    }
                    .frame(width: width, alignment: .top)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .offset(x: origin.x, y: origin.y)
                .opacity(open)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    static func liveCard(_ f: MenuFixture, _ c: Ctx, _ m: MotionBank, size: CGSize) -> some View {
        let k = f.labelScale
        let glow = m["mm.glow"].clamped(0, 1), warm = m["mm.warm"].clamped(0, 1)
        let times = AuroraGlow.Times(elapsed: c.reduceMotion ? 0 : c.t, burst: c.reduceMotion ? -1 : c.t - m.value("mm.burstAt", -10))
        let shape = RoundedRectangle(cornerRadius: 9 * k, style: .continuous)
        return ZStack(alignment: .topLeading) {
            shape.fill((c.dark ? Color.white : Color.black).opacity(c.dark ? 0.07 : 0.04))
            if glow * (1 - warm) > 0.005 {
                AuroraEdge(size: size, radius: 9 * k, border: 1.6, rim: 6, bloom: 0, times: times,
                           reduceTransparency: c.reduceTransparency, palette: .appleIntelligence)
                    .opacity(glow * (1 - warm))
            }
            if glow * warm > 0.005 {
                AuroraEdge(size: size, radius: 9 * k, border: 1.6, rim: 6, bloom: 0, times: times,
                           reduceTransparency: c.reduceTransparency, palette: .sunset)
                    .opacity(glow * warm)
            }
            cardContent(f, dark: c.dark)
                .padding(cardPad(k))
                .frame(width: size.width, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
    }

    static func cardContent(_ f: MenuFixture, dark: Bool) -> some View {
        let k = f.labelScale
        let ink: Color = dark ? .white : Color.black.opacity(0.88)
        let sub: Color = dark ? Color.white.opacity(0.55) : Color.black.opacity(0.5)
        return HStack(alignment: .center, spacing: 10 * k) {
            VStack(alignment: .leading, spacing: 2 * k) {
                Text(f.task ? "Working" : "Needs you").font(.system(size: 11 * k, weight: .semibold)).foregroundStyle(sub)
                Text(f.status).font(.system(size: 13 * k, weight: .medium)).foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4 * k)
            AuroraButton(title: f.task ? "Stop" : "Answer", key: f.task ? "esc" : "\u{23CE}", primary: !f.task, dark: dark, scale: k * 0.82)
        }
    }
}
