import SwiftUI

/// The menu Jarvis's item opens. Item titles are the product's
/// (AppDelegate's NSMenu); the eye tracker's failure is fixture text.
public struct MenuFixture {
    public enum Eyes: String { case off, on, failed }
    public var open: Bool
    public var eyes: Eyes = .off
    /// A task is running, so Stop is offered.
    public var task = false
    /// Questions parked for you.
    public var asks = 0
    /// The row the keyboard highlight is on.
    public var highlight: String? = nil
    /// The bigger-labels comfort setting (Config.labelScale): 1 to 2 in quarter steps.
    public var labelScale: Double = 1

    var item: ItemFixture {
        ItemFixture(phase: task ? .working : asks > 0 ? .asks : .standby, labelScale: labelScale, asks: asks)
    }

    /// The status line: what Jarvis is doing right now.
    var status: String {
        if task { return MenuScript.task }
        if asks > 0 { return "\(asks) questions waiting" }
        return "Waiting for \u{201C}Hey Jarvis\u{201D}"
    }
}

/// One menu row.
struct MenuRow {
    enum Kind { case item, header, separator }
    var kind: Kind
    var title = ""
    /// A key equivalent for an item; the state for a section header.
    var trailing: String? = nil
    var symbol: String? = nil
    var subtitle: String? = nil
    var badge: Int? = nil
}

public enum MenuScript {
    static let task = "Replying to Alex"
    static let eyesFailure = "The camera is in use by another app."

    /// The product's items in the product's order. statusHeader adds the
    /// status as a section header; asksItem lists parked questions as an item.
    static func rows(_ f: MenuFixture, statusHeader: Bool, asksItem: Bool) -> [MenuRow] {
        var rows: [MenuRow] = []
        if statusHeader, !(asksItem && f.asks > 0) { rows.append(MenuRow(kind: .header, title: f.status)) }
        if asksItem, f.asks > 0 {
            rows.append(MenuRow(kind: .item, title: "Answer Questions\u{2026}", symbol: "questionmark.bubble", badge: f.asks))
        }
        if statusHeader || (asksItem && f.asks > 0) { rows.append(MenuRow(kind: .separator)) }
        rows += [MenuRow(kind: .item, title: "Settings\u{2026}", trailing: "\u{2318},", symbol: "gearshape"),
                 MenuRow(kind: .item, title: "Activity", symbol: "clock.arrow.circlepath"),
                 MenuRow(kind: .item, title: "Agents", symbol: "person.2"),
                 MenuRow(kind: .item, title: "Pause Listening", symbol: "pause.circle")]
        if f.task { rows.append(MenuRow(kind: .item, title: "Stop", trailing: "\u{238B}", symbol: "stop.circle")) }
        rows.append(MenuRow(kind: .separator))
        switch f.eyes {
        case .off:
            rows += [MenuRow(kind: .header, title: "Eyes", trailing: "Off"),
                     MenuRow(kind: .item, title: "Enable Eye Tracking", symbol: "eye")]
        case .on:
            rows += [MenuRow(kind: .header, title: "Eyes", trailing: "Tracking"),
                     MenuRow(kind: .item, title: "Pause Tracking", symbol: "pause"),
                     MenuRow(kind: .item, title: "Recalibrate", symbol: "scope")]
        case .failed:
            rows += [MenuRow(kind: .header, title: "Eyes", trailing: "Stopped"),
                     MenuRow(kind: .item, title: "Restart Eye Tracking", symbol: "arrow.clockwise", subtitle: eyesFailure)]
        }
        rows += [MenuRow(kind: .item, title: "Eye Tracking Settings\u{2026}", symbol: "slider.horizontal.3"),
                 MenuRow(kind: .separator),
                 MenuRow(kind: .item, title: "Export Logs\u{2026}", symbol: "square.and.arrow.up"),
                 MenuRow(kind: .separator),
                 MenuRow(kind: .item, title: "Quit Jarvis", trailing: "\u{2318}Q", symbol: "power")]
        return rows
    }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("idle", "Open", caption: "Click the item: Jarvis's commands, with eye tracking off.", duration: 2.0) { _ in MenuFixture(open: true) },
        StateEntry("closed", "Closed", caption: "The item at rest, menu closed.", duration: 0.9) { _ in MenuFixture(open: false) },
        StateEntry("keyboard", "Keyboard", caption: "Arrow keys move the highlight, return chooses, esc closes; \u{2318}, and \u{2318}Q work while it's open.", duration: 1.8) { _ in
            MenuFixture(open: true, highlight: "Activity")
        },
        StateEntry("eyes-on", "Eye tracking on", caption: "With eye tracking running, the Eyes section offers pause and recalibrate (MM-1: a real section header, not a greyed-out item).", duration: 2.0) { _ in
            MenuFixture(open: true, eyes: .on)
        },
        StateEntry("eyes-failed", "Eye tracking stopped", caption: "The tracker stopped: why, in full under Restart, instead of a header cut off mid-sentence.", duration: 2.0) { _ in
            MenuFixture(open: true, eyes: .failed)
        },
        StateEntry("task-running", "A task running", caption: "Jarvis is working: the menu says on what, and offers Stop.", duration: 2.4) { _ in
            MenuFixture(open: true, task: true)
        },
        StateEntry("asks-parked", "Questions waiting", caption: "Two questions are parked: the menu is where you answer them, now the item carries no count text (MB-1).", duration: 2.4) { _ in
            MenuFixture(open: true, asks: 2)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "Bigger labels at 2\u{00D7}: every row, header and shortcut doubles and the menu widens to fit, so the failure reason reads in full instead of clipping.", duration: 2.6) { _ in
            MenuFixture(open: true, eyes: .failed, task: true, labelScale: 2)
        },
    ]

    public static let flow = ["closed", "idle", "keyboard", "eyes-on", "eyes-failed", "task-running", "asks-parked", "closed", "large", "closed"]

    @MainActor
    static func fixture(of state: String?) -> MenuFixture? {
        guard let state, let entry = states.first(where: { $0.id == state }) else { return nil }
        return entry.fixture(0) as? MenuFixture
    }
}

/// An NSMenu as macOS 26 draws it: glass, 13 pt rows with SF Symbols in the
/// leading column, real section headers, key equivalents, item badges and
/// subtitles (NSMenuItem.sectionHeader, .badge and .subtitle, macOS 14+).
@MainActor
enum NativeMenu {
    struct Metrics {
        var k: Double
        var inset: CGFloat { 5 }
        var row: CGFloat { 22 * k + 2 }
        var header: CGFloat { 20 * k + 3 }
        var separator: CGFloat { 9 + 2 * min(k, 1.5) }
        var subtitle: CGFloat { 14 * k }
        var font: CGFloat { 13 * k }
        var lead: CGFloat { 10 * k + 16 * k + 7 * k }
    }

    static func height(_ rows: [MenuRow], _ mt: Metrics) -> CGFloat {
        rows.reduce(mt.inset * 2) { sum, row in
            switch row.kind {
            case .separator: return sum + mt.separator
            case .header: return sum + mt.header
            case .item: return sum + mt.row + (row.subtitle == nil ? 0 : mt.subtitle)
            }
        }
    }

    static func rowWidth(_ row: MenuRow, _ mt: Metrics) -> CGFloat {
        let k = mt.k
        switch row.kind {
        case .separator:
            return 0
        case .header:
            let title: CGFloat = TextMetrics.width(row.title, size: 11 * k, weight: .semibold)
            var state: CGFloat = 0
            if let trailing = row.trailing { state = 24 * k + TextMetrics.width(trailing, size: 11 * k, weight: .regular) }
            return 22 * k + title + state
        case .item:
            let title: CGFloat = TextMetrics.width(row.title, size: mt.font, weight: .regular)
            var sub: CGFloat = 0
            if let subtitle = row.subtitle { sub = TextMetrics.width(subtitle, size: 11 * k, weight: .regular) }
            var key: CGFloat = 0
            if let trailing = row.trailing { key = 28 * k + TextMetrics.width(trailing, size: mt.font, weight: .regular) }
            let badge: CGFloat = row.badge == nil ? 0 : 36 * k
            let line: CGFloat = title + key + badge + 24 * k
            return mt.lead + max(line, sub) + 14 * k
        }
    }

    static func width(_ rows: [MenuRow], _ mt: Metrics, minimum: CGFloat = 0) -> CGFloat {
        var widest: CGFloat = 0
        for row in rows { widest = max(widest, rowWidth(row, mt)) }
        return max(widest + mt.inset * 2, minimum, 200 * mt.k)
    }

    struct Palette {
        var ink: Color
        var secondary: Color
        var rule: Color
        var selection: Color
        var badge: Color
    }

    static func palette(_ c: Ctx, selection: Color?) -> Palette {
        Palette(ink: c.dark ? Color.white.opacity(0.92) : Color.black.opacity(0.86),
                secondary: c.dark ? Color.white.opacity(0.5) : Color.black.opacity(0.48),
                rule: (c.dark ? Color.white : Color.black).opacity(0.1),
                selection: selection ?? ShellAccent.blue(c.dark),
                badge: (c.dark ? Color.white : Color.black).opacity(0.14))
    }

    static func rows(_ rows: [MenuRow], _ mt: Metrics, _ c: Ctx, highlight: String?, width: CGFloat, selection: Color? = nil) -> some View {
        let p = palette(c, selection: selection)
        let inner = width - mt.inset * 2
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                MenuRowView(row: row, mt: mt, palette: p, on: row.title == highlight, inner: inner)
            }
        }
        .padding(mt.inset)
        .frame(width: width, alignment: .topLeading)
    }

    /// Where a menu hangs from the item: its leading edge under the item's,
    /// pushed left to stay on screen.
    static func origin(itemWidth: CGFloat, width: CGFloat) -> CGPoint {
        let x = StatusBar.trailing - itemWidth - 6
        return CGPoint(x: min(x, Desk.size.width - 8 - width), y: Desk.menuBar + 5)
    }
}

/// One NSMenu row: separator, section header or item.
struct MenuRowView: View {
    var row: MenuRow
    var mt: NativeMenu.Metrics
    var palette: NativeMenu.Palette
    var on: Bool
    var inner: CGFloat

    var body: some View {
        switch row.kind {
        case .separator:
            Rectangle().fill(palette.rule)
                .frame(width: inner - 20, height: 1)
                .frame(width: inner, height: mt.separator)
        case .header:
            header
        case .item:
            item
        }
    }

    private var header: some View {
        let k = mt.k
        return HStack(spacing: 6 * k) {
            Text(row.title).font(.system(size: 11 * k, weight: .semibold)).foregroundStyle(palette.secondary)
            Spacer(minLength: 12 * k)
            if let state = row.trailing {
                Text(state).font(.system(size: 11 * k)).foregroundStyle(palette.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10 * k)
        .padding(.bottom, 3 * k)
        .frame(width: inner, height: mt.header, alignment: .bottomLeading)
    }

    private var item: some View {
        let k = mt.k
        let fg: Color = on ? .white : palette.ink
        let fg2: Color = on ? Color.white.opacity(0.8) : palette.secondary
        return HStack(alignment: .top, spacing: 7 * k) {
            Image(systemName: row.symbol ?? "circle")
                .font(.system(size: 12.5 * k))
                .foregroundStyle(fg)
                .frame(width: 16 * k, height: mt.row)
                .opacity(row.symbol == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 0) {
                line(fg: fg, fg2: fg2)
                if let sub = row.subtitle {
                    Text(sub).font(.system(size: 11 * k)).foregroundStyle(fg2)
                        .lineLimit(1)
                        .frame(height: mt.subtitle, alignment: .top)
                        .offset(y: -3 * k)
                }
            }
        }
        .padding(.leading, 10 * k)
        .padding(.trailing, 12 * k)
        .frame(width: inner, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.selection.opacity(on ? 1 : 0)))
    }

    private func line(fg: Color, fg2: Color) -> some View {
        let k = mt.k
        return HStack(spacing: 8 * k) {
            Text(row.title).font(.system(size: mt.font)).foregroundStyle(fg).lineLimit(1)
            Spacer(minLength: 16 * k)
            if let badge = row.badge {
                Text("\(badge)").font(.system(size: 11 * k, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(fg2)
                    .padding(.horizontal, 6 * k)
                    .frame(height: 16 * k)
                    .background(Capsule().fill(on ? Color.white.opacity(0.2) : palette.badge))
            }
            if let key = row.trailing {
                Text(key).font(.system(size: mt.font)).foregroundStyle(fg2)
            }
        }
        .frame(height: mt.row)
    }
}
