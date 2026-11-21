import SwiftUI

/// What the gaze layer knows at one instant: where the tracker says you look,
/// how sure it is, and which control (if any) Jarvis would act on.
public struct GazeFixture {
    public enum Phase: String { case off, seeking, locked, reading, lost }

    public var phase: Phase
    /// The latest tracker sample, held between 10 Hz frames like the real feed.
    public var gaze: CGPoint
    /// One standard deviation of the tracker's error, in points.
    public var sigma: Double
    /// The control Jarvis would act on, already snapped to its full frame.
    public var target: CGRect?
    public var targetRadius: Double = 7
    public var targetLabel = ""
}

public enum GazeScript {
    static let paragraph = CGPoint(x: Desk.Target.paragraph.minX + 260, y: Desk.Target.paragraph.minY + 40)
    static var send: CGPoint { CGPoint(x: Desk.Target.send.midX, y: Desk.Target.send.midY) }
    static var attach: CGPoint { CGPoint(x: Desk.Target.attach.midX, y: Desk.Target.attach.midY) }

    /// Deterministic tracker noise: a new sample every 100 ms, as the tracker
    /// delivers at ~10 fps, with an error of about `sigma` points.
    static func jitter(_ t: Double, sigma: Double, seed: Double) -> CGVector {
        let k = floor(t * 10)
        func r(_ s: Double) -> Double {
            let x = sin(k * 12.9898 + s * 78.233) * 43758.5453
            return (x - floor(x)) * 2 - 1
        }
        return CGVector(dx: r(seed) * sigma * 0.55, dy: r(seed + 1.7) * sigma * 0.45)
    }

    static func ease(_ p: Double) -> Double {
        let x = min(1, max(0, p))
        return x * x * (3 - 2 * x)
    }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
    }

    static func sampled(_ t: Double) -> Double { floor(t * 10) / 10 }

    @MainActor
    public static let states: [StateEntry] = [
        StateEntry("off", "Off", caption: "Eye tracking is off or Jarvis isn't listening: nothing is drawn.", duration: 1.0) { _ in
            GazeFixture(phase: .off, gaze: paragraph, sigma: 60)
        },
        StateEntry("seeking", "Finding your eyes", caption: "Your eyes move toward the toolbar; the tracker is unsure, so nothing is picked yet.", duration: 2.2) { t in
            let p = mix(paragraph, CGPoint(x: send.x + 40, y: send.y + 34), ease(sampled(t) / 1.9))
            let j = jitter(t, sigma: 70, seed: 1)
            return GazeFixture(phase: .seeking, gaze: CGPoint(x: p.x + j.dx, y: p.y + j.dy), sigma: 70)
        },
        StateEntry("locked", "On a control", caption: "You look at Send: the whole button is picked, however the gaze jitters inside it.", duration: 2.4) { t in
            let j = jitter(t, sigma: 22, seed: 3)
            return GazeFixture(phase: .locked, gaze: CGPoint(x: send.x + j.dx, y: send.y + j.dy), sigma: 22,
                               target: Desk.Target.send, targetRadius: 8, targetLabel: "Send")
        },
        StateEntry("retarget", "Moving on", caption: "Your eyes jump to Attach: the highlight travels there, carrying its speed.", duration: 2.0) { t in
            let p = mix(send, attach, ease((sampled(t) - 0.2) / 0.2))
            let j = jitter(t, sigma: 24, seed: 5)
            let arrived = t >= 0.5
            return GazeFixture(phase: .locked, gaze: CGPoint(x: p.x + j.dx, y: p.y + j.dy), sigma: arrived ? 24 : 48,
                               target: arrived ? Desk.Target.attach : nil, targetRadius: 7, targetLabel: "Attach")
        },
        StateEntry("reading", "Reading", caption: "You read the message: text isn't a control, so only the gaze mark shows.", duration: 2.4) { t in
            let line = floor(sampled(t) / 0.8)
            let x = Desk.Target.paragraph.minX + 30 + (sampled(t).truncatingRemainder(dividingBy: 0.8) / 0.8) * 560
            let j = jitter(t, sigma: 30, seed: 7)
            return GazeFixture(phase: .reading, gaze: CGPoint(x: x + j.dx, y: Desk.Target.paragraph.minY + 22 + line * 30 + j.dy * 0.4), sigma: 30)
        },
        StateEntry("lost", "Lost you", caption: "You looked away: the mark rests where it last saw you and dims.", duration: 1.8) { _ in
            GazeFixture(phase: .lost, gaze: CGPoint(x: Desk.Target.paragraph.minX + 420, y: Desk.Target.paragraph.minY + 82), sigma: 90)
        },
    ]

    public static let flow = ["off", "seeking", "locked", "retarget", "reading", "lost", "off"]
}

/// Shared geometry for the gaze directions: the highlight's frame chases
/// either the target or a small disc at the gaze point.
@MainActor
enum GazeMotion {
    /// The gaze mark follows samples with a critically damped spring, so 10 Hz
    /// steps read as one smooth glide with no stop-start.
    static func follow(_ f: GazeFixture, _ c: Ctx, _ m: MotionBank, response: Double = 0.22) {
        let spec = c.geo(.spring(response: response, damping: 1))
        m.set("gx", f.gaze.x, spec)
        m.set("gy", f.gaze.y, spec)
    }

    /// The highlight rect: the target when there is one, else a disc of
    /// `orb` points at the smoothed gaze.
    static func rect(_ f: GazeFixture, _ c: Ctx, _ m: MotionBank, orb: Double, spec: MotionSpec) {
        let s = c.geo(spec)
        let center = f.target.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: m["gx"], y: m["gy"])
        let follow = c.geo(.spring(response: 0.1, damping: 1))
        m.set("hcx", center.x, f.target == nil ? follow : s)
        m.set("hcy", center.y, f.target == nil ? follow : s)
        m.set("hw", f.target.map { Double($0.width) } ?? orb, s)
        m.set("hh", f.target.map { Double($0.height) } ?? orb, s)
        m.set("hr", f.target == nil ? orb / 2 : f.targetRadius, s)
    }

    static func frame(_ m: MotionBank, outset: Double = 0) -> CGRect {
        CGRect(x: m["hcx"] - m["hw"] / 2 - outset, y: m["hcy"] - m["hh"] / 2 - outset,
               width: max(0, m["hw"] + outset * 2), height: max(0, m["hh"] + outset * 2))
    }
}
