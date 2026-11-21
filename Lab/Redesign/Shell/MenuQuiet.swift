import SwiftUI

/// C. Native menu: a real NSMenu, as macOS 26 draws it. The status is a
/// section header, parked questions are an item with a badge, Eyes is a
/// section header with its state (MM-1), and the tracker's failure reads in
/// full as Restart's subtitle. The item is the Marble ring.
@MainActor
public enum MenuQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Native menu", axis: "Stays a real NSMenu: section headers, badges, subtitles, no custom views",
        pitch: "Stays a real NSMenu, because a menu bar menu you open many times a day should behave exactly like every other one: type-to-select, arrow keys, return and esc, VoiceOver and the system's own glass and fade, all for free. MM-1 becomes NSMenuItem.sectionHeader, MB-1's count moves to an item badge.",
        cost: "No sign of life inside the menu: the status is a line of text, and Stop is just another item rather than a control next to what it stops.",
        libraries: [Lib.sfSymbols, Lib.orb],
        custom: "None in the product beyond the item titles: sectionHeader, badge and subtitle are AppKit (macOS 14+). The lab redraws the menu because ImageRenderer can't capture an NSMenu.",
        skills: [SkillNote("apple-design", "MM-1: 'Eyes' is NSMenuItem.sectionHeader with its state on the right, so it reads as a heading rather than a disabled item; macOS 26's leading SF Symbols on every item."),
                 SkillNote("remove-animations", "No animation of our own: NSMenu appears on click and fades out on close; rows update in place while it's open."),
                 SkillNote("animate", "Frequency gate: a menu-bar menu is opened tens of times a day and from the keyboard, so it gets the system's behaviour and nothing more."),
                 SkillNote("gestures", "Everything NSMenu gives: arrow keys move the accent highlight, return chooses, esc closes, type-to-select, \u{2318}, and \u{2318}Q, and Stop shows esc as its key."),
                 SkillNote("emil-design-eng", "MB-1's count comes back where it belongs: an item badge on Answer Questions, so the item never carries text."),
                 SkillNote("break-ui", "The tracker's long failure reason was cut off mid-header; it is now Restart's subtitle, in full. At 2x the menu widens to the longest row instead of truncating."),
                 SkillNote("choreograph", "Nothing to sequence: the item's highlight and the menu appear on the same frame, as AppKit draws them.")],
        alwaysOn: false)

    public static func update(_ f: MenuFixture, _ c: Ctx, _ m: MotionBank) {
        ItemQuiet.update(f.item, c, m)
        m.set("mm.open", f.open ? 1 : 0, f.open ? .snap : c.fade(.easeOut(0.15)))
    }

    public static func body(_ f: MenuFixture, _ c: Ctx, _ m: MotionBank) -> some View {
        let k = f.labelScale
        let itemWidth = ItemQuiet.width(k)
        let open = m["mm.open"].clamped(0, 1)
        let rows = MenuScript.rows(f, statusHeader: true, asksItem: true)
        let mt = NativeMenu.Metrics(k: k)
        let size = CGSize(width: NativeMenu.width(rows, mt), height: NativeMenu.height(rows, mt))
        let origin = NativeMenu.origin(itemWidth: itemWidth, width: size.width)
        return ZStack(alignment: .topLeading) {
            StatusBar.openHighlight(c, width: itemWidth, opacity: f.open ? 1 : 0).offset(x: StatusBar.trailing - itemWidth)
            ItemQuiet.glyph(f.item, c, m).offset(x: StatusBar.trailing - itemWidth)
            if open > 0.005 {
                ZStack(alignment: .topLeading) {
                    ShellGlass(frame: CGRect(origin: origin, size: size), radius: 12, scheme: c.scheme, showsMail: true,
                               reduceTransparency: c.reduceTransparency)
                    NativeMenu.rows(rows, mt, c, highlight: f.highlight, width: size.width)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .offset(x: origin.x, y: origin.y)
                .opacity(open)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }
}
