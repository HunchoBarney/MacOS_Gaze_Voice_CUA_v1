import SwiftUI

/// A library a direction uses, as the gallery and REUSE.md record it.
public struct LibraryUse: Sendable, Codable, Hashable {
    public var name: String
    public var version: String
    public var license: String
    public var url: String
    public var role: String

    public init(_ name: String, _ version: String, _ license: String, _ url: String, role: String) {
        self.name = name
        self.version = version
        self.license = license
        self.url = url
        self.role = role
    }
}

public struct SkillNote: Sendable, Codable, Hashable {
    public var skill: String
    public var change: String
    public init(_ skill: String, _ change: String) {
        self.skill = skill
        self.change = change
    }
}

/// What the gallery and the lab say about one direction.
public struct DirectionInfo: Sendable {
    public var id: String
    public var name: String
    public var axis: String
    public var pitch: String
    public var cost: String
    public var libraries: [LibraryUse]
    public var custom: String
    public var skills: [SkillNote]
    /// Whether the direction draws continuously while visible (its cost is measured).
    public var alwaysOn: Bool

    public init(id: String, name: String, axis: String, pitch: String, cost: String,
                libraries: [LibraryUse], custom: String, skills: [SkillNote], alwaysOn: Bool) {
        self.id = id
        self.name = name
        self.axis = axis
        self.pitch = pitch
        self.cost = cost
        self.libraries = libraries
        self.custom = custom
        self.skills = skills
        self.alwaysOn = alwaysOn
    }
}

/// Everything a direction may read while it sets targets or draws.
public struct Ctx {
    /// Seconds on the stage clock.
    public var t: Double
    /// Seconds since the current state began.
    public var local: Double
    public var state: String
    public var previous: String?
    public var scheme: ColorScheme
    public var reduceMotion: Bool
    public var reduceTransparency: Bool

    public var dark: Bool { scheme == .dark }

    /// Geometry under Reduce Motion jumps; colour and opacity still fade.
    public func geo(_ spec: MotionSpec) -> MotionSpec { reduceMotion ? .snap : spec }
    public func fade(_ spec: MotionSpec) -> MotionSpec { reduceMotion ? .easeOut(0.2) : spec }
}

/// One design direction for one component.
@MainActor
public protocol Direction {
    associatedtype Fixture
    associatedtype Body: View
    static var info: DirectionInfo { get }
    static func update(_ fixture: Fixture, _ ctx: Ctx, _ m: MotionBank)
    @ViewBuilder static func body(_ fixture: Fixture, _ ctx: Ctx, _ m: MotionBank) -> Body
}

@MainActor
public struct AnyDirection {
    public let info: DirectionInfo
    let update: (Any, Ctx, MotionBank) -> Void
    let view: (Any, Ctx, MotionBank) -> AnyView

    public init<D: Direction>(_ type: D.Type) {
        info = D.info
        update = { fixture, ctx, m in
            if let f = fixture as? D.Fixture { D.update(f, ctx, m) }
        }
        view = { fixture, ctx, m in
            guard let f = fixture as? D.Fixture else { return AnyView(EmptyView()) }
            return AnyView(D.body(f, ctx, m))
        }
    }
}

public struct StateEntry {
    public var id: String
    public var title: String
    public var caption: String
    /// How long the state plays in the flow and in its clip.
    public var duration: Double
    /// The fixture at a time since the state began.
    public var fixture: (Double) -> Any

    public init(_ id: String, _ title: String, caption: String, duration: Double, fixture: @escaping (Double) -> Any) {
        self.id = id
        self.title = title
        self.caption = caption
        self.duration = duration
        self.fixture = fixture
    }
}

@MainActor
public struct ComponentEntry {
    public var id: String
    public var title: String
    public var batch: Int
    public var summary: String
    /// Component ids in the existing gallery that show today's design.
    public var currentIDs: [String]
    public var currentNote: String
    public var states: [StateEntry]
    /// State ids, in order, for "auto-play the flow".
    public var flow: [String]
    /// The state a clip of state N starts from (the one before it in the flow).
    public var directions: [AnyDirection]
    /// The region of the desktop the component's clips show.
    public var crop: CGRect
    public var showsMail: Bool

    public init(id: String, title: String, batch: Int, summary: String, currentIDs: [String], currentNote: String,
                states: [StateEntry], flow: [String], directions: [AnyDirection], crop: CGRect, showsMail: Bool) {
        self.id = id
        self.title = title
        self.batch = batch
        self.summary = summary
        self.currentIDs = currentIDs
        self.currentNote = currentNote
        self.states = states
        self.flow = flow
        self.directions = directions
        self.crop = crop
        self.showsMail = showsMail
    }

    public func index(of state: String) -> Int? { states.firstIndex { $0.id == state } }
}

/// Plays one direction of one component: a clock, the current state, the
/// motion bank and the clocks the vendored libraries read.
@MainActor
public final class Stage: ObservableObject {
    public let component: ComponentEntry
    public private(set) var direction: Int
    public private(set) var stateIndex = 0
    public private(set) var time = 0.0
    public private(set) var stateStart = 0.0
    public private(set) var previous: String?
    public var scheme: ColorScheme = .dark
    public var reduceMotion = false
    public var reduceTransparency = false
    public let bank = MotionBank()
    public let clocks = LibraryClocks()
    private var queue: [(at: Double, state: Int)] = []

    public init(_ component: ComponentEntry, direction: Int = 0) {
        self.component = component
        self.direction = direction
        prime()
    }

    public var state: StateEntry { component.states[stateIndex] }
    public var info: DirectionInfo { component.directions[direction].info }
    public var playingFlow: Bool { !queue.isEmpty }
    public var fixture: Any { state.fixture(time - stateStart) }

    public var ctx: Ctx {
        Ctx(t: time, local: time - stateStart, state: state.id, previous: previous, scheme: scheme,
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
    }

    public func select(direction: Int) {
        self.direction = direction
        bank.reset()
        prime()
        objectWillChange.send()
    }

    /// Change state now; motion carries on from where it is.
    public func go(to index: Int) {
        guard component.states.indices.contains(index) else { return }
        previous = state.id
        stateIndex = index
        stateStart = time
        objectWillChange.send()
    }

    public func go(to id: String) {
        if let index = component.index(of: id) { go(to: index) }
    }

    /// Jump to a state with its motion already settled (stills, and the
    /// starting point of a state's clip).
    public func settle(at index: Int, previousState: String? = nil) {
        queue.removeAll()
        stateIndex = index
        previous = previousState
        stateStart = time
        apply()
        bank.settle()
        objectWillChange.send()
    }

    /// Schedule every flow state back to back from now.
    public func playFlow() {
        queue.removeAll()
        var at = time
        for id in component.flow {
            guard let index = component.index(of: id) else { continue }
            queue.append((at, index))
            at += component.states[index].duration
        }
    }

    public var flowDuration: Double {
        component.flow.compactMap { component.index(of: $0) }.reduce(0) { $0 + component.states[$1].duration }
    }

    public func stopFlow() { queue.removeAll() }

    public func advance(_ dt: Double) {
        time += dt
        while let next = queue.first, next.at <= time + 1e-9 {
            queue.removeFirst()
            go(to: next.state)
        }
        apply()
        bank.step(dt, now: time)
        clocks.set(time)
        objectWillChange.send()
    }

    private func apply() {
        component.directions[direction].update(fixture, ctx, bank)
    }

    private func prime() {
        apply()
        bank.settle()
        clocks.set(time)
    }

    public func content() -> AnyView {
        component.directions[direction].view(fixture, ctx, bank)
    }
}
