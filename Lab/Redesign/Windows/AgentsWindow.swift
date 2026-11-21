import Aurora
import SwiftUI

/// The Agents window at one instant: the helpers Jarvis runs for you (the
/// same roster, colours and faces as Agents on screen), which one is open,
/// and Activity, Jarvis's own feed of what you asked and what it did.
/// Fixture names and text only.
public struct AgentsWindowFixture {
    public enum Selection: Equatable {
        case none, activity, agent(String)
        var key: String {
            switch self {
            case .none: return "none"
            case .activity: return "activity"
            case .agent(let id): return id
            }
        }
    }

    public struct Agent {
        public var id: String
        public var role: String
        public var status: AgentFixture.Status
        public var routine: String?
    }

    public var agents: [Agent]
    public var selection: Selection
    /// Whether Activity has history.
    public var feed = true
    /// The comfort setting's label scale (1.0...2.0).
    public var labelScale: Double = 1

    func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }
}

public enum AgentsWindowScript {
    static func research(_ status: AgentFixture.Status = .acting) -> AgentsWindowFixture.Agent {
        .init(id: "research", role: "Finds and summarises sources", status: status)
    }
    static func calendar(_ status: AgentFixture.Status = .idle) -> AgentsWindowFixture.Agent {
        .init(id: "calendar", role: "Schedules meetings and invites", status: status)
    }
    static let notes = AgentsWindowFixture.Agent(id: "notes", role: "Keeps your meeting notes", status: .idle,
                                                 routine: "Weekdays at 9:00 \u{00B7} Tidy yesterday's notes")
    static var roster: [AgentsWindowFixture.Agent] { [research(), calendar(), notes] }

    struct Message { enum Role { case user, agent, note }; var role: Role; var text: String }

    static func conversation(_ id: String) -> [Message] {
        switch id {
        case "research":
            return [Message(role: .user, text: "Find recent work on on-device speech recognition and summarise the best four."),
                    Message(role: .agent, text: "On it. I'll put the summary in Notes when it's done."),
                    Message(role: .note, text: "Research opened six pages")]
        case "calendar":
            return [Message(role: .user, text: "Set up lunch with Alex next Thursday."),
                    Message(role: .agent, text: "Thursday at 12:30 is free on both calendars.")]
        default:
            return [Message(role: .note, text: "Runs on its own while Jarvis is open")]
        }
    }

    static let working = "Reading source 3 of 4"
    static let question = "Which Alex: Rivera or Chen?"

    /// What you asked and what Jarvis did, newest first. The fixture of
    /// today's Activity page, grouped by request.
    struct Request { var asked: String; var time: String; var agent: String?; var steps: [(symbol: String, text: String, warm: Bool)] }
    static let requests: [Request] = [
        Request(asked: "Reply to Alex and say the deck is ready", time: "9:41", agent: nil, steps: [
            ("keyboard", "Typed the reply into the message body", false),
            ("checkmark.shield", "Checked the reply is in the message body", false),
            ("hand.raised", "Asked before sending to Alex Rivera", false),
            ("paperplane", "Sent", false),
        ]),
        Request(asked: "Research saved a summary to Notes", time: "9:30", agent: "research", steps: []),
        Request(asked: "Open Keynote", time: "9:12", agent: nil, steps: [
            ("exclamationmark.triangle", "Keynote didn't open in 10 seconds", true),
        ]),
    ]

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("activity-empty", "Activity, nothing yet", caption: "Activity is Jarvis's own feed, first in the sidebar; before you ask anything it says what will appear.", duration: 2.0) { _ in
            AgentsWindowFixture(agents: [], selection: .activity, feed: false)
        },
        StateEntry("empty", "No agents yet", caption: "No helpers yet: the window says how one appears.", duration: 2.0) { _ in
            AgentsWindowFixture(agents: [], selection: .none, feed: false)
        },
        StateEntry("roster", "Three agents", caption: "Three helpers in the sidebar with the faces they wear on screen; Research is working, so its face moves and its status carries the family's light.", duration: 2.8) { _ in
            AgentsWindowFixture(agents: roster, selection: .agent("research"))
        },
        StateEntry("asking", "An agent needs you", caption: "Calendar has a question: its row turns the needs-you orange, and the question opens in its conversation with the answers and the words that pick them.", duration: 3.0) { _ in
            AgentsWindowFixture(agents: [research(), calendar(.asking), notes], selection: .agent("calendar"))
        },
        StateEntry("activity-feed", "Activity with history", caption: "What you asked and what Jarvis did, grouped by request, newest first; an agent's work shows its face.", duration: 2.6) { _ in
            AgentsWindowFixture(agents: roster, selection: .activity)
        },
        StateEntry("large", "Largest labels (2\u{00D7})", caption: "The bigger-labels comfort setting at its largest: the window widens, the sidebar rows, header and conversation grow with their type.", duration: 2.6) { _ in
            AgentsWindowFixture(agents: [research(), calendar(.asking), notes], selection: .agent("research"), labelScale: 2)
        },
    ]

    public static let flow = ["activity-empty", "empty", "roster", "asking", "activity-feed", "large", "activity-empty"]
}

@MainActor
struct AgentsLook {
    var fam: WinFamily
    var ink: WinInk
    var k: Double
    var t: Double
    var rm: Bool
    var rt: Bool

    init(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank, _ fam: WinFamily) {
        self.fam = fam
        ink = WinInk(c)
        k = (m.value("k", f.labelScale) * 100).rounded() / 100
        t = c.t
        rm = c.reduceMotion
        rt = c.reduceTransparency
    }

    var windowSize: CGSize { CGSize(width: 900 + 300 * (k - 1), height: 660) }
    var sidebarWidth: CGFloat { 230 + 80 * (k - 1) }
    var contentWidth: CGFloat { windowSize.width - sidebarWidth - 16 }
    var pad: CGFloat { 22 }
    var top: CGFloat { WWindow<EmptyView, EmptyView, EmptyView>.toolbar(k) + 8 }
    var activityRow: CGFloat { 30 * k }
    var header: CGFloat { 30 * k }
    var agentRow: CGFloat { 44 * k }
}

@MainActor
enum AgentsWindowMotion {
    static func update(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank, _ fam: WinFamily) {
        m.set("k", f.labelScale, c.geo(.spring(response: 0.3, damping: 1)), initial: f.labelScale)
        let l = AgentsLook(f, c, m, fam)
        for entry in AgentRoster.all {
            let a = f.agent(entry.id)
            m.set("on.\(entry.id)", a == nil ? 0 : 1, c.fade(a == nil ? .easeOut(0.15) : .spring(response: 0.32, damping: 1)))
            m.set("ask.\(entry.id)", a?.status == .asking ? 1 : 0, c.fade(.spring(response: 0.3, damping: 1)))
        }
        var y = 0.0, h = l.activityRow
        if case .agent(let id) = f.selection, let i = f.agents.firstIndex(where: { $0.id == id }) {
            y = l.activityRow + l.header + Double(i) * l.agentRow
            h = l.agentRow
        }
        let selected = f.selection != .none
        let fresh = m.value("selOn", 0) < 0.01
        m.set("selY", y, fresh ? .snap : c.geo(.spring(response: 0.28, damping: 1)), initial: y)
        m.set("selH", h, fresh ? .snap : c.geo(.spring(response: 0.28, damping: 1)), initial: h)
        m.set("selOn", selected ? 1 : 0, c.fade(.easeOut(0.15)))
        let keys = ["none", "activity"] + AgentRoster.all.map(\.id)
        for key in keys {
            let on = f.selection.key == key
            m.set("d.\(key)", on ? 1 : 0, c.fade(.easeOut(on ? 0.18 : 0.1)), initial: on ? 1 : 0)
        }
        m.set("feed", f.feed ? 1 : 0, c.fade(.easeOut(0.2)), initial: f.feed ? 1 : 0)
        let isAgent = f.selection != .activity
        m.set("title.agents", isAgent ? 1 : 0, c.fade(.easeOut(isAgent ? 0.2 : 0.1)), initial: isAgent ? 1 : 0)
        m.set("title.activity", isAgent ? 0 : 1, c.fade(.easeOut(isAgent ? 0.1 : 0.2)), initial: isAgent ? 0 : 1)

        var asking = false
        if case .agent(let id) = f.selection, f.agent(id)?.status == .asking { asking = true }
        let arrived = asking && (c.local > (c.reduceMotion ? 0 : 0.45) || c.state == "large")
        if fam == .glow, arrived, m["card"] < 0.02 { m.set("burst", c.t, .snap) }
        m.set("card", arrived ? 1 : 0, arrived ? c.geo(fam == .island ? .spring(response: 0.42, damping: 0.8) : .spring(response: 0.4, damping: 1))
                                            : c.geo(.spring(response: 0.3, damping: 1)))
        let shown = arrived && m["card"] > 0.3
        m.set("cardShow", shown ? 1 : 0, c.fade(.easeOut(shown ? 0.22 : 0.1)))
    }
}

@MainActor
enum AgentsWindowView {
    static func window(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank, _ fam: WinFamily) -> some View {
        let l = AgentsLook(f, c, m, fam)
        let size = l.windowSize
        let frame = CGRect(x: (Desk.size.width - size.width) / 2, y: 140, width: size.width, height: size.height)
        return ZStack(alignment: .topLeading) {
            WWindow(frame: frame, sidebarWidth: l.sidebarWidth, ink: l.ink, k: l.k) {
                sidebar(f, l, m)
            } toolbar: {
                ZStack(alignment: .leading) {
                    Text("Agents").opacity(m["title.agents"])
                    Text("Activity").opacity(m["title.activity"])
                }
                .font(WType.font(.title3, l.k, .semibold)).foregroundStyle(l.ink.primary)
            } content: {
                ZStack(alignment: .topLeading) {
                    if m["d.none"] > 0.01 { emptyAgents(l).opacity(m["d.none"]) }
                    if m["d.activity"] > 0.01 { activity(f, l, m).opacity(m["d.activity"]) }
                    ForEach(AgentRoster.all, id: \.id) { entry in
                        if m["d.\(entry.id)"] > 0.01, let a = f.agent(entry.id) {
                            detail(entry, a, f, l, c, m).opacity(m["d.\(entry.id)"])
                        }
                    }
                }
                .frame(width: l.contentWidth, height: size.height, alignment: .topLeading)
            }
        }
        .frame(width: Desk.size.width, height: Desk.size.height, alignment: .topLeading)
    }

    // MARK: Sidebar

    static func sidebar(_ f: AgentsWindowFixture, _ l: AgentsLook, _ m: MotionBank) -> some View {
        let k = l.k, ink = l.ink
        let w = l.sidebarWidth - 16
        return ZStack(alignment: .topLeading) {
            WSelection(y: m["selY"], height: m["selH"], width: w, k: k, ink: ink).opacity(m["selOn"])
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8 * k) {
                    WTile(symbol: "clock.fill", color: Color(red: 0.36, green: 0.46, blue: 0.62), k: k)
                    Text("Activity").font(WType.font(.body, k)).foregroundStyle(ink.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8 * k)
                .frame(width: w, height: l.activityRow)
                .offset(x: 8)
                Text("Agents").font(WType.font(.subheadline, k, .semibold)).foregroundStyle(ink.secondary)
                    .padding(.leading, 8 + 8 * k)
                    .frame(height: l.header, alignment: .bottomLeading)
                    .padding(.bottom, 0)
                if f.agents.isEmpty {
                    Text("None yet").font(WType.font(.subheadline, k)).foregroundStyle(ink.tertiary)
                        .padding(.leading, 8 + 8 * k)
                        .frame(height: 26 * k)
                }
                ForEach(f.agents, id: \.id) { a in
                    agentRow(AgentRoster.entry(a.id), a, l, m)
                        .frame(width: w, height: l.agentRow)
                        .offset(x: 8)
                }
            }
        }
        .padding(.top, 40)
        .frame(width: l.sidebarWidth, alignment: .topLeading)
    }

    static func subtitle(_ a: AgentsWindowFixture.Agent) -> String {
        switch a.status {
        case .acting: return "Working"
        case .asking: return "Needs you"
        default: return a.role
        }
    }

    static func agentRow(_ e: AgentRoster.Entry, _ a: AgentsWindowFixture.Agent, _ l: AgentsLook, _ m: MotionBank) -> some View {
        let k = l.k, ink = l.ink
        let on = m["on.\(e.id)"].clamped(0, 1)
        let ask = m["ask.\(e.id)"].clamped(0, 1)
        return HStack(spacing: 9 * k) {
            WAvatar(family: l.fam, color: e.color, size: 26 * k, moving: false, asking: ask, t: l.t, ink: ink)
            VStack(alignment: .leading, spacing: 1 * k) {
                Text(e.name).font(WType.font(.body, k, .medium)).foregroundStyle(ink.primary).lineLimit(1)
                Text(subtitle(a)).font(WType.font(.subheadline, k))
                    .foregroundStyle(a.status == .asking ? ink.askInk : ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if a.routine != nil {
                Image(systemName: "repeat").font(.system(size: 10 * k, weight: .medium)).foregroundStyle(ink.tertiary)
            }
        }
        .padding(.horizontal, 8 * k)
        .offset(y: l.rm ? 0 : (1 - on) * 6 * k)
        .opacity(on)
    }

    // MARK: Agent

    static func statusText(_ a: AgentsWindowFixture.Agent) -> String {
        switch a.status {
        case .acting: return "Working"
        case .asking: return "Needs you"
        default: return a.routine == nil ? "Idle" : "Next run 9:00"
        }
    }

    /// The agent's state beside its name, carrying the family's light only
    /// while it works or needs you. A: the island's black capsule; B: glass
    /// with the Aurora rim (cool working, warm needs-you); C: a crisp stroke
    /// in the agent's colour, orange when it needs you.
    @ViewBuilder
    static func status(_ e: AgentRoster.Entry, _ a: AgentsWindowFixture.Agent, _ l: AgentsLook, _ m: MotionBank) -> some View {
        let k = l.k, ink = l.ink
        let text = statusText(a)
        let live = a.status == .acting || a.status == .asking
        let ask = m["ask.\(e.id)"].clamped(0, 1)
        let tw = TextMetrics.width(text, size: WType.size(.callout) * k, weight: .medium)
        let dot = live ? 14 * k : 0
        let w = tw + 22 * k + dot, h = 24 * k
        let label = HStack(spacing: 6 * k) {
            if live {
                Circle().fill(e.color.mix(with: AgentRoster.ask, by: ask)).frame(width: 7 * k, height: 7 * k)
            }
            Text(text).font(WType.font(.callout, k, .medium))
        }
        switch l.fam {
        case .island:
            label.foregroundStyle(live ? Color.white : ink.secondary)
                .frame(width: w, height: h)
                .background(Capsule().fill(live ? Color.black : ink.control)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(live && ink.dark ? 0.16 : 0), lineWidth: 0.5)))
        case .glow:
            ZStack {
                if live {
                    AuroraEdge(size: CGSize(width: w, height: h), radius: h / 2, border: 1.6, rim: 3, bloom: 0.7,
                               times: AuroraGlow.Times(elapsed: l.rm ? 0 : l.t, burst: l.rm ? -1 : l.t - m.value("burst", l.t - 10)),
                               reduceTransparency: l.rt, palette: a.status == .asking ? .sunset : .appleIntelligence)
                    Capsule().fill(ink.group).padding(1.6)
                } else {
                    Capsule().fill(ink.control)
                }
                label.foregroundStyle(live ? ink.primary : ink.secondary)
            }
            .frame(width: w, height: h)
        case .quiet:
            let tint = e.color.mix(with: AgentRoster.ask, by: ask)
            label.foregroundStyle(live ? (a.status == .asking ? ink.askInk : tint) : ink.secondary)
                .frame(width: w, height: h)
                .background(Capsule().fill(live ? tint.opacity(ink.dark ? 0.14 : 0.08) : ink.control))
                .overlay(Capsule().strokeBorder(live ? tint : .clear, lineWidth: 1.5))
        }
    }

    static func detail(_ e: AgentRoster.Entry, _ a: AgentsWindowFixture.Agent, _ f: AgentsWindowFixture, _ l: AgentsLook, _ c: Ctx, _ m: MotionBank) -> some View {
        let k = l.k, ink = l.ink
        let messages = AgentsWindowScript.conversation(e.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12 * k) {
                WAvatar(family: l.fam, color: e.color, size: 40 * k, moving: a.status == .acting && !l.rm,
                        asking: m["ask.\(e.id)"].clamped(0, 1), t: l.t, ink: ink)
                VStack(alignment: .leading, spacing: 2 * k) {
                    Text(e.name).font(WType.font(.title2, k, .semibold)).foregroundStyle(ink.primary)
                    Text(a.role).font(WType.font(.callout, k)).foregroundStyle(ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 8 * k)
                status(e, a, l, m)
                if a.status == .acting { WButton(title: "Stop", k: k, ink: ink) }
            }
            if let routine = a.routine {
                Label(routine, systemImage: "repeat")
                    .font(WType.font(.subheadline, k)).foregroundStyle(ink.secondary)
                    .padding(.horizontal, 9 * k).frame(height: 22 * k)
                    .background(Capsule().fill(ink.control))
                    .padding(.top, 10 * k)
            }
            Rectangle().fill(ink.separator).frame(height: 0.5).padding(.top, 14 * k).padding(.horizontal, -l.pad)
            VStack(alignment: .leading, spacing: 12 * k) {
                Spacer(minLength: 0)
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    bubble(message, l)
                }
                if a.status == .acting {
                    Text(AgentsWindowScript.working + "\u{2026}").font(WType.font(.subheadline, k)).foregroundStyle(ink.secondary)
                }
                if a.status == .asking, m["card"] > 0.002 {
                    let inner = l.contentWidth - l.pad * 2
                    let size = Measure.size("agentsCard-\(l.fam)-\(k)", width: inner) { question(e, l, m, show: 1) }
                    question(e, l, m, show: m["cardShow"].clamped(0, 1))
                        .frame(height: size.height * m["card"], alignment: .top)
                        .scaleEffect(l.rm ? 1 : 0.97 + 0.03 * m["card"].clamped(0, 1), anchor: .bottom)
                }
            }
            .padding(.vertical, 14 * k)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .clipped()
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                Rectangle()
            })
            WField(placeholder: "Message \(e.name)\u{2026}", k: k, ink: ink, trailing: "arrow.up.circle.fill")
                .padding(.bottom, 16)
        }
        .padding(.horizontal, l.pad)
        .padding(.top, l.top)
        .frame(width: l.contentWidth, height: l.windowSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    static func bubble(_ message: AgentsWindowScript.Message, _ l: AgentsLook) -> some View {
        let k = l.k, ink = l.ink
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60 * k)
                Text(message.text).font(WType.font(.body, k)).foregroundStyle(ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12 * k).padding(.vertical, 8 * k)
                    .background(RoundedRectangle(cornerRadius: 14 * k, style: .continuous).fill(ink.control))
            }
        case .agent:
            Text(message.text).font(WType.font(.body, k)).foregroundStyle(ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 60 * k)
        case .note:
            Text(message.text).font(WType.font(.subheadline, k)).foregroundStyle(ink.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// The question, opened in the conversation. A grows a black island
    /// card (the one bounce); B is lit by the warm Aurora rim with one burst;
    /// C is outlined in the needs-you orange.
    static func question(_ e: AgentRoster.Entry, _ l: AgentsLook, _ m: MotionBank, show: Double) -> some View {
        let k = l.k, ink = l.ink
        let black = l.fam == .island
        let text = black ? Color.white : ink.primary
        let sub = black ? Color.white.opacity(0.62) : ink.secondary
        let shape = RoundedRectangle(cornerRadius: 18 * k, style: .continuous)
        let content = VStack(alignment: .leading, spacing: 8 * k) {
            HStack(spacing: 8 * k) {
                NeedsYouMark(family: l.fam, size: 15 * k, ink: ink)
                Text("\(e.name) needs you").font(WType.font(.headline, k, .semibold)).foregroundStyle(text)
            }
            Text(AgentsWindowScript.question).font(WType.font(.body, k)).foregroundStyle(text)
                .fixedSize(horizontal: false, vertical: true)
            AnswerRow(say: "Rivera", color: sub, scale: k) {
                if black {
                    Text("Alex Rivera").font(WType.font(.body, k, .medium)).foregroundStyle(.black)
                        .padding(.horizontal, 12 * k).frame(height: 26 * k).background(Capsule().fill(Color.white)).fixedSize()
                    Text("Alex Chen").font(WType.font(.body, k)).foregroundStyle(.white)
                        .padding(.horizontal, 12 * k).frame(height: 26 * k).background(Capsule().fill(Color.white.opacity(0.16))).fixedSize()
                } else {
                    WButton(title: "Alex Rivera", k: k, ink: ink, prominent: true, tint: l.fam == .quiet ? AgentRoster.ask.mix(with: .black, by: 0.12) : nil)
                    WButton(title: "Alex Chen", k: k, ink: ink)
                }
            }
        }
        .padding(14 * k)
        .opacity(show)
        .offset(y: l.rm ? 0 : (1 - show) * 4 * k)
        .frame(maxWidth: .infinity, alignment: .leading)
        return content
            .background {
                switch l.fam {
                case .island:
                    shape.fill(Color.black).overlay(shape.strokeBorder(Color.white.opacity(ink.dark ? 0.14 : 0), lineWidth: 0.5))
                        .shadow(color: .black.opacity(ink.dark ? 0.4 : 0.2), radius: 10, y: 3)
                case .glow:
                    GeometryReader { geo in
                        ZStack {
                            AuroraEdge(size: geo.size, radius: 18 * k, border: 2, rim: 4, bloom: 0.8,
                                       times: AuroraGlow.Times(elapsed: l.rm ? 0 : l.t, burst: l.rm ? -1 : l.t - m.value("burst", l.t - 10)),
                                       reduceTransparency: l.rt, palette: .sunset)
                            shape.fill(ink.group).padding(2)
                        }
                    }
                case .quiet:
                    shape.fill(ink.group).overlay(shape.strokeBorder(AgentRoster.ask, lineWidth: 1.5))
                }
            }
    }

    // MARK: Activity

    static func activity(_ f: AgentsWindowFixture, _ l: AgentsLook, _ m: MotionBank) -> some View {
        let k = l.k, ink = l.ink
        let feed = m["feed"].clamped(0, 1)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if feed > 0.01 {
                    VStack(alignment: .leading, spacing: 14 * k) {
                        ForEach(Array(AgentsWindowScript.requests.enumerated()), id: \.offset) { _, r in
                            request(r, l)
                        }
                        Spacer(minLength: 0)
                    }
                    .opacity(feed)
                }
                if feed < 0.99 {
                    VStack(spacing: 6 * k) {
                        Image(systemName: "clock").font(.system(size: 28 * k, weight: .light)).foregroundStyle(ink.tertiary)
                            .padding(.bottom, 4 * k)
                        Text("Nothing yet").font(WType.font(.title3, k, .semibold)).foregroundStyle(ink.primary)
                        Text("What you ask Jarvis, and what it does, shows up here.")
                            .font(WType.font(.callout, k)).foregroundStyle(ink.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(1 - feed)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            WField(placeholder: "Type a command, like \u{201C}open Calculator\u{201D}", k: k, ink: ink, trailing: "arrow.up.circle.fill")
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, l.pad)
        .padding(.top, l.top)
        .frame(width: l.contentWidth, height: l.windowSize.height, alignment: .topLeading)
    }

    static func request(_ r: AgentsWindowScript.Request, _ l: AgentsLook) -> some View {
        let k = l.k, ink = l.ink
        return WGroup(k: k, ink: ink) {
            HStack(alignment: .firstTextBaseline, spacing: 10 * k) {
                ZStack {
                    if let id = r.agent {
                        let e = AgentRoster.entry(id)
                        WAvatar(family: l.fam, color: e.color, size: 18 * k, moving: false, t: l.t, ink: ink)
                    } else {
                        Image(systemName: "text.bubble").font(.system(size: 13 * k)).foregroundStyle(ink.secondary)
                    }
                }
                .frame(width: 20 * k, height: 18 * k)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 * k }
                Text(r.agent == nil ? "\u{201C}\(r.asked)\u{201D}" : r.asked).font(WType.font(.body, k, .medium)).foregroundStyle(ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8 * k)
                Text(r.time).font(WType.font(.subheadline, k).monospacedDigit()).foregroundStyle(ink.tertiary)
            }
            .padding(.horizontal, 12 * k).padding(.vertical, 9 * k)
            if !r.steps.isEmpty {
                WSeparator(k: k, ink: ink)
                VStack(alignment: .leading, spacing: 6 * k) {
                    ForEach(Array(r.steps.enumerated()), id: \.offset) { _, step in
                        HStack(spacing: 10 * k) {
                            Image(systemName: step.symbol).font(.system(size: 11 * k))
                                .foregroundStyle(step.warm ? ink.askInk : ink.secondary)
                                .frame(width: 20 * k)
                            Text(step.text).font(WType.font(.callout, k)).foregroundStyle(step.warm ? ink.askInk : ink.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12 * k).padding(.vertical, 9 * k)
            }
        }
    }

    static func emptyAgents(_ l: AgentsLook) -> some View {
        let k = l.k, ink = l.ink
        return VStack(spacing: 8 * k) {
            WAvatar(family: l.fam, color: Color(white: 0.6), size: 44 * k, moving: false, t: l.t, ink: ink)
                .saturation(0)
                .padding(.bottom, 4 * k)
            Text("No agents yet").font(WType.font(.title3, k, .semibold)).foregroundStyle(ink.primary)
            Text("Ask Jarvis for a recurring job, like \u{201C}summarise new mail every morning\u{201D}, and a helper appears here.")
                .font(WType.font(.callout, k)).foregroundStyle(ink.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 320 * k)
        }
        .frame(width: l.contentWidth, height: l.windowSize.height)
    }
}

// MARK: Directions

@MainActor
public enum AgentsWindowIsland: Direction {
    public static let info = DirectionInfo(
        id: "A", name: "Islands", axis: "Each agent wears its on-screen island: a black disc with the thinking orb",
        pitch: "Wins with Agents on screen A: the face in the sidebar is the chip you saw over your windows, the status is the island's black capsule, and a question grows into an island card.",
        cost: "The thinking orb runs while an agent works and the window is open; black capsules beside native controls are the loudest of the three.",
        libraries: [Lib.thinkingOrbs, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The window kit shared with Settings, the sidebar's sliding selection, the bottom-anchored conversation and the island question card; AnswerRow is reused from the ask cards.",
        skills: [SkillNote("apple-design", "One system: AgentRoster's colours and the A chip's black disc with the thinking orb, so the window and the overlay read as one; a native sidebar with a glass pane, text styles times the comfort scale."),
                 SkillNote("emil-design-eng", "Only the working agent's face moves, and only in the header; sidebar faces are still, and the island's black marks only live states."),
                 SkillNote("animate", "The question card grows on 0.42 s / 0.8 damping, the one bounce, for the one moment that needs you; the selection slides on a 0.28 s critically damped spring."),
                 SkillNote("choreograph", "Switching agents is a 0.18 s crossfade with no rise or stagger (it happens many times a day); the question opens 0.45 s after the conversation lands, and its words fade in once the card is a third open."),
                 SkillNote("find-animation-opportunities", "Kept: the card growing, rows arriving together when the first agents appear. Rejected: per-message entrances, typing dots."),
                 SkillNote("remove-animations", "No spinner beside a working agent: the moving face already says it, and the step text says what."),
                 SkillNote("gestures", "The answer buttons have the spoken alternative beside them (or say \u{201C}Rivera\u{201D}); the composer takes Return."),
                 SkillNote("break-ui", "At 2x the window widens to 1200 pt, the sidebar to 310 pt, and the conversation stays anchored to the composer with a soft edge where older messages pass under the header."),
                 SkillNote("prototype", "Activity moves into this window as Jarvis's own feed, first in the sidebar: an IA proposal the owner should confirm.")],
        alwaysOn: true)

    public static func update(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank) { AgentsWindowMotion.update(f, c, m, .island) }
    public static func body(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank) -> some View { AgentsWindowView.window(f, c, m, .island) }
}

@MainActor
public enum AgentsWindowGlow: Direction {
    public static let info = DirectionInfo(
        id: "B", name: "Glow", axis: "Lit colour dots; Apple Intelligence light around a working or asking agent's status",
        pitch: "Wins with Agents on screen B: each agent is its lit colour dot, the one working carries the Siri rim on its status, and a question is lit by the warm end of the same light.",
        cost: "One Aurora shader runs while an agent works and the window is open, two while one also asks; the most light of the three in a window.",
        libraries: [Lib.aurora, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The window kit shared with Settings; glass faces with the agent's dot, the rimmed status capsule and question card.",
        skills: [SkillNote("apple-design", "Light as status: the rim lives only on the working agent's status and on a question; the sidebar is native glass with solid fallback under Reduce Transparency."),
                 SkillNote("animate", "The question card opens on a 0.4 s critically damped spring with one warm burst as it lands; the rim's shader time stops under Reduce Motion."),
                 SkillNote("choreograph", "Conversation lands, then the card and its burst on one frame, then the words."),
                 SkillNote("emil-design-eng", "The glow sits on a 24 pt capsule, not around the window or the row."),
                 SkillNote("find-animation-opportunities", "Rejected: glowing the sidebar row too; the colour dot's lit shadow is enough there."),
                 SkillNote("remove-animations", "Sidebar faces never animate; only the open agent's status does."),
                 SkillNote("gestures", "Standard buttons and Return in the composer."),
                 SkillNote("break-ui", "Rims are sized from the measured capsule and card, so they follow 2x labels."),
                 SkillNote("prototype", "B in the picker; Activity as the sidebar's first item is shared by all three.")],
        alwaysOn: true)

    public static func update(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank) { AgentsWindowMotion.update(f, c, m, .glow) }
    public static func body(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank) -> some View { AgentsWindowView.window(f, c, m, .glow) }
}

@MainActor
public enum AgentsWindowQuiet: Direction {
    public static let info = DirectionInfo(
        id: "C", name: "Marbles", axis: "Quietest: Orb marbles in each agent's colour, crisp strokes, no glow",
        pitch: "Wins with Agents on screen C: the marble that turns beside a working agent's pointer turns in its header here, its status is a stroke in its colour, and a question is outlined in orange.",
        cost: "Identity rests on colour; the marble is a GPU gradient that turns while an agent works.",
        libraries: [Lib.orb, Lib.sfSymbols, Lib.swiftUISpring],
        custom: "The window kit shared with Settings; the stroked status capsule and outlined question card.",
        skills: [SkillNote("emil-design-eng", "One stroke weight (1.5 pt), the agent's colour for identity and orange only for needs you."),
                 SkillNote("apple-design", "Native sidebar, grouped Activity, standard buttons; text styles times the comfort scale."),
                 SkillNote("animate", "Same timing as A and B except no bounce anywhere: the card opens critically damped."),
                 SkillNote("choreograph", "Crossfade on switch; the card after the conversation; rows arrive together."),
                 SkillNote("remove-animations", "The marble turns only in the open agent's header while it works, and stops under Reduce Motion."),
                 SkillNote("find-animation-opportunities", "Rejected: a pulse on the needs-you row; the orange subtitle and marble badge carry it."),
                 SkillNote("gestures", "Standard buttons and Return in the composer."),
                 SkillNote("break-ui", "At 2x the stroked capsule re-measures its text and the sidebar re-stacks."),
                 SkillNote("prototype", "C in the picker.")],
        alwaysOn: true)

    public static func update(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank) { AgentsWindowMotion.update(f, c, m, .quiet) }
    public static func body(_ f: AgentsWindowFixture, _ c: Ctx, _ m: MotionBank) -> some View { AgentsWindowView.window(f, c, m, .quiet) }
}
