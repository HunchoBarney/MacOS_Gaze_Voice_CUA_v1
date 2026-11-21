import CoreGraphics
import Foundation
import XCTest
@testable import Jarvis

/// Gaze-highlight latency and flicker on synthetic gaze — the highlight
/// is the scorer's incumbent, so this drives `IntentScorerCore` with
/// fixation sequences across real-sized control layouts and measures how
/// many frames the incumbent takes to follow each new fixation and how
/// often it lands on something the eyes are not on. The noise model is a
/// per-fixation calibration bias plus per-sample jitter after the
/// tracker's fixation filter; it is a model, not anyone's eyes.
final class GazeHighlightBenchTests: XCTestCase {
    struct Layout {
        let name: String
        let frames: [CGRect]
    }

    struct Result {
        var latenciesMs: [Double] = []
        var missed = 0
        var fixations = 0
        var wrongSwitches = 0
        var seconds: Double = 0

        func percentile(_ p: Double) -> Double {
            guard !latenciesMs.isEmpty else { return .nan }
            let sorted = latenciesMs.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
        }
        var flickerPerMinute: Double { Double(wrongSwitches) / seconds * 60 }
    }

    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func gaussian() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    static func row(_ name: String, count: Int, width: CGFloat, height: CGFloat,
                    gap: CGFloat) -> Layout {
        Layout(name: name, frames: (0..<count).map { i in
            CGRect(x: 200 + CGFloat(i) * (width + gap), y: 300, width: width, height: height)
        })
    }

    static let layouts = [
        row("toolbar 80x28 gap 8", count: 6, width: 80, height: 28, gap: 8),
        row("icons 28x28 gap 6", count: 8, width: 28, height: 28, gap: 6),
        row("spread 120x32 gap 200", count: 4, width: 120, height: 32, gap: 200),
    ]

    /// One run: `fixations` looks, each on a different control than the
    /// last, 300–700 ms long, sampled at `hz`. The landing sample carries
    /// the tracker's saccade flag only when `flagged`.
    static func run(_ layout: Layout, sigma: Double, biasPt: Double, jitterPt: Double,
                    hz: Double, flagged: Bool, fixations: Int = 400,
                    seed: UInt64 = 7) -> Result {
        var config = IntentScorerCore.Config()
        config.sigmaPx = sigma
        let core = IntentScorerCore(config: config)
        let candidates = layout.frames.enumerated().map { i, f in
            IntentCandidate(id: "c\(i)", kind: .axElement, frame: f, motorRect: f,
                            role: "AXButton", label: "button \(i)")
        }
        var rng = SplitMix(state: seed)
        var result = Result()
        var t = 0.0
        var target = 0
        let dt = 1 / hz
        for _ in 0..<fixations {
            var next = Int(rng.uniform() * Double(candidates.count))
            if next == target { next = (next + 1) % candidates.count }
            target = next
            let frame = layout.frames[target]
            let bias = CGPoint(x: rng.gaussian() * biasPt, y: rng.gaussian() * biasPt)
            let length = 0.3 + 0.4 * rng.uniform()
            let start = t
            var acquiredAt: Double?
            var shown = core.incumbent?.id
            var first = true
            while t - start < length {
                let point = CGPoint(x: frame.midX + bias.x + rng.gaussian() * jitterPt,
                                    y: frame.midY + bias.y + rng.gaussian() * jitterPt)
                core.update(candidates: candidates, at: point,
                            isSaccade: flagged && first,
                            now: Date(timeIntervalSinceReferenceDate: t))
                first = false
                let now = core.incumbent?.id
                if now != shown {
                    if let now, now != "c\(target)" { result.wrongSwitches += 1 }
                    shown = now
                }
                if acquiredAt == nil, now == "c\(target)" { acquiredAt = t }
                t += dt
            }
            result.fixations += 1
            if let acquiredAt {
                result.latenciesMs.append((acquiredAt - start) * 1000)
            } else {
                result.missed += 1
            }
        }
        result.seconds = t
        return result
    }

    func testReportHighlightLatencyAndFlicker() throws {
        guard ProcessInfo.processInfo.environment["JARVIS_BENCH_GAZE_HIGHLIGHT"] == "1" else {
            throw XCTSkip("a report, not a check: set JARVIS_BENCH_GAZE_HIGHLIGHT=1 to print it")
        }
        var lines = ["layout | σ | Hz | flagged | p50 ms | p90 ms | missed | wrong/min"]
        for layout in Self.layouts {
            for sigma in [40.0, 150.0] {
                for hz in [15.0, 30.0] {
                    for flagged in [true, false] {
                        let r = Self.run(layout, sigma: sigma, biasPt: 20, jitterPt: 15,
                                         hz: hz, flagged: flagged, fixations: 200)
                        lines.append(String(format: "%@ | %.0f | %.0f | %@ | %.0f | %.0f | %d/%d | %.1f",
                                            layout.name, sigma, hz, flagged ? "yes" : "no",
                                            r.percentile(0.5), r.percentile(0.9),
                                            r.missed, r.fixations, r.flickerPerMinute))
                    }
                }
            }
        }
        print("GAZE-HIGHLIGHT-BENCH\n" + lines.joined(separator: "\n"))
    }

    /// Budgets: well-separated controls highlight within two tracker
    /// frames of the eyes landing (the landing frame plus one confirming
    /// frame) even before calibration has learned anything, and a dense
    /// toolbar at a settled error band stays flicker-free.
    func testHighlightFollowsAFixationWithinTwoFrames() {
        let frame = 1000.0 / 15
        for sigma in [40.0, 150.0] {
            let r = Self.run(Self.layouts[2], sigma: sigma, biasPt: 20, jitterPt: 15,
                             hz: 15, flagged: true)
            XCTAssertEqual(r.missed, 0, "σ \(sigma)")
            XCTAssertLessThanOrEqual(r.percentile(0.9), 2 * frame + 1, "σ \(sigma)")
            XCTAssertEqual(r.wrongSwitches, 0, "σ \(sigma)")
        }
        let toolbar = Self.run(Self.layouts[0], sigma: 40, biasPt: 20, jitterPt: 15,
                               hz: 15, flagged: true)
        XCTAssertLessThanOrEqual(toolbar.percentile(0.5), 3 * frame + 1)
        XCTAssertLessThanOrEqual(Double(toolbar.missed) / Double(toolbar.fixations), 0.25)
        XCTAssertLessThanOrEqual(toolbar.flickerPerMinute, 2)
    }

    /// The scorer's share of the sample-to-highlight path: one update over
    /// a crowded window's worth of candidates. Measured in this thread's CPU
    /// time, so other test processes sharing the cores can't inflate it.
    func testScorerUpdateCostPerSample() {
        let frames = (0..<60).map { i in
            CGRect(x: 40 + CGFloat(i % 10) * 90, y: 80 + CGFloat(i / 10) * 40, width: 80, height: 28)
        }
        let candidates = frames.enumerated().map { i, f in
            IntentCandidate(id: "c\(i)", kind: .axElement, frame: f, motorRect: f,
                            role: "AXButton", label: "button \(i)")
        }
        let core = IntentScorerCore(config: .init(sigmaPx: 40))
        var rng = SplitMix(state: 3)
        let n = 3000
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for i in 0..<n {
            let point = CGPoint(x: 300 + rng.gaussian() * 30, y: 150 + rng.gaussian() * 30)
            core.update(candidates: candidates, at: point, isSaccade: i % 8 == 0,
                        now: Date(timeIntervalSinceReferenceDate: Double(i) / 15))
        }
        let perUpdateMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1e6 / Double(n)
        print(String(format: "GAZE-SCORER-UPDATE %.3f ms per sample, 60 candidates", perUpdateMs))
        XCTAssertLessThan(perUpdateMs, 5)
    }
}
