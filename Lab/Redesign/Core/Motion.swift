import SwiftUI

/// How one animated value moves to its target.
///
/// Springs are SwiftUI's own `Spring`, stepped with `Spring.update`, so a
/// retarget keeps the value's velocity (Apple's "interruptible" rule) and the
/// same physics run live in the lab, frame-exact in the clip renderer, and in
/// the product once a direction is picked.
public enum MotionSpec: Sendable {
    case spring(Spring)
    case timing(duration: Double, curve: UnitCurve)
    case snap

    /// Response and damping ratio, Apple's two spring parameters.
    public static func spring(response: Double, damping: Double) -> MotionSpec {
        .spring(Spring(response: response, dampingRatio: damping))
    }

    /// Emil's strong ease-out, cubic-bezier(0.23, 1, 0.32, 1).
    public static func easeOut(_ duration: Double) -> MotionSpec {
        .timing(duration: duration, curve: .bezier(startControlPoint: UnitPoint(x: 0.23, y: 1), endControlPoint: UnitPoint(x: 0.32, y: 1)))
    }

    public static func linear(_ duration: Double) -> MotionSpec { .timing(duration: duration, curve: .linear) }
}

/// Named scalar channels that chase their targets. A direction declares the
/// targets for the current fixture every frame; the bank steps them.
@MainActor
public final class MotionBank {
    struct Channel {
        var value: Double
        var velocity: Double
        var target: Double
        var spec: MotionSpec
        var from: Double
        var start: Double
    }

    private var channels: [String: Channel] = [:]
    private var now = 0.0

    public init() {}

    public subscript(_ key: String) -> Double { channels[key]?.value ?? 0 }

    public func value(_ key: String, _ fallback: Double) -> Double { channels[key]?.value ?? fallback }

    /// Retarget `key`. A new channel starts at `initial`, or at the target.
    public func set(_ key: String, _ target: Double, _ spec: MotionSpec, initial: Double? = nil) {
        guard var channel = channels[key] else {
            let start = initial ?? target
            channels[key] = Channel(value: start, velocity: 0, target: target, spec: spec, from: start, start: now)
            return
        }
        channel.spec = spec
        if channel.target != target {
            channel.target = target
            channel.from = channel.value
            channel.start = now
            if case .snap = spec { channel.value = target; channel.velocity = 0 }
        }
        channels[key] = channel
    }

    public func step(_ dt: Double, now: Double) {
        self.now = now
        guard dt > 0 else { return }
        for key in Array(channels.keys) {
            guard var c = channels[key] else { continue }
            switch c.spec {
            case .snap:
                c.value = c.target
                c.velocity = 0
            case .timing(let duration, let curve):
                let p = duration <= 0 ? 1 : min(1, max(0, (now - c.start) / duration))
                let previous = c.value
                c.value = c.from + (c.target - c.from) * curve.value(at: p)
                c.velocity = (c.value - previous) / dt
            case .spring(let spring):
                var value = c.value, velocity = c.velocity
                var remaining = dt
                while remaining > 1e-9 {
                    let h = min(remaining, 1.0 / 240)
                    spring.update(value: &value, velocity: &velocity, target: c.target, deltaTime: h)
                    remaining -= h
                }
                if abs(value - c.target) < 1e-4 && abs(velocity) < 1e-3 { value = c.target; velocity = 0 }
                c.value = value
                c.velocity = velocity
            }
            channels[key] = c
        }
    }

    /// Jump every channel to its target: stills, and state jumps under Reduce Motion.
    public func settle() {
        for key in Array(channels.keys) {
            guard var c = channels[key] else { continue }
            c.value = c.target
            c.velocity = 0
            c.from = c.target
            channels[key] = c
        }
    }

    public func reset() { channels.removeAll() }
}
