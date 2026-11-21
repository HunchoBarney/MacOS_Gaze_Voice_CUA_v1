import Foundation
import os

/// KAR-75 L3: carries what the user says from the wake word into the Live
/// session, so "Hey Jarvis, open Mail" works in one breath.
///
/// The microphone writes here all the time. A short ring keeps the last few
/// seconds. On a wake, capture starts from just before the wake phrase
/// ended. Until the session starts, the input track gets silence and the
/// captured speech waits. Once it starts, the track plays the speech in real
/// time from where capture began, so Live hears it as it was said and its
/// own turn detection works unchanged. While playback is behind, quiet
/// 10 ms frames are skipped, so the lag (the connect time) is gone after the
/// first pause. WebRTC has no faster-than-real-time input and GPT-Live's
/// client delegation has no typed user turn, so this is how the words reach it.
///
/// Mono samples at the engine's rate. `write` and `read` run on audio
/// threads; everything else on any thread.
final class LiveInputRelay: @unchecked Sendable {
    struct Stats: Equatable {
        /// Seconds of speech waiting to be played into the session.
        var behind: Double
        /// Quiet seconds skipped to catch up since the last capture.
        var skipped: Double
        /// Whether a capture was abandoned because it fell too far behind.
        var overflowed: Bool
        /// Seconds of speech written since the capture began.
        var spoken: Double = 0
        /// Seconds of quiet written since the last speech.
        var quiet: Double = 0
    }

    let sampleRate: Double
    /// How much of the ring before the wake moment to keep.
    let lead: Double
    /// Beyond this lag the backlog is dropped and the user is asked to say
    /// it again; nothing is lost silently, and what they say next still plays.
    let maxBehind: Double

    private struct State {
        var ring: [Float] = []
        var ringEnd: TimeInterval = 0
        var queue: [Float] = []
        var head = 0
        var capturing = false
        var sending = false
        var skipped = 0
        var overflowed = false
        var spoken = 0
        var quiet = 0
        var floor: Float = 0.001
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let ringLength: Int
    private let frame: Int

    init(sampleRate: Double, lead: Double = 0.3, ringSeconds: Double = 4, maxBehind: Double = 8) {
        self.sampleRate = sampleRate
        self.lead = lead
        self.maxBehind = maxBehind
        ringLength = Int(sampleRate * ringSeconds)
        frame = max(1, Int(sampleRate / 100))
    }

    /// Microphone samples whose last one was heard at `end` (systemUptime).
    func write(_ samples: UnsafeBufferPointer<Float>, endingAt end: TimeInterval) {
        let level = Self.rms(samples)
        lock.withLock { state in
            if state.capturing {
                if level >= Self.speechThreshold(state.floor) {
                    state.spoken += samples.count
                    state.quiet = 0
                } else {
                    state.quiet += samples.count
                }
                state.queue.append(contentsOf: samples)
                if Double(state.queue.count - state.head) / sampleRate > maxBehind {
                    state.overflowed = true
                    state.queue = []
                    state.head = 0
                }
            }
            state.ring.append(contentsOf: samples)
            if state.ring.count > ringLength { state.ring.removeFirst(state.ring.count - ringLength) }
            state.ringEnd = end
            state.floor = level < state.floor ? level : state.floor * 1.002 + 0.000_001
        }
    }

    /// Starts keeping what follows `moment`, the end of the wake phrase.
    func capture(since moment: TimeInterval) {
        lock.withLock { state in
            let back = Int(((state.ringEnd - moment) + lead) * sampleRate)
            let kept = min(max(back, 0), state.ring.count)
            state.queue = Array(state.ring.suffix(kept))
            state.head = 0
            state.capturing = true
            state.sending = false
            state.skipped = 0
            state.overflowed = false
            state.spoken = 0
            state.quiet = 0
        }
    }

    /// The session started: play the capture into its input from now on.
    func startSending() {
        lock.withLock { $0.sending = true }
    }

    /// Basic voice (KAR-75 L10): stops capturing and returns the capture,
    /// for transcription on the Mac instead of a session.
    func take() -> [Float] {
        lock.withLock { state in
            let captured = Array(state.queue[state.head...])
            state.capturing = false
            state.sending = false
            state.queue = []
            state.head = 0
            return captured
        }
    }

    /// Stops capturing and sending; the input track hears silence again.
    func stop() {
        lock.withLock { state in
            state.capturing = false
            state.sending = false
            state.queue = []
            state.head = 0
        }
    }

    var stats: Stats {
        lock.withLock { state in
            Stats(behind: Double(state.queue.count - state.head) / sampleRate,
                  skipped: Double(state.skipped) / sampleRate, overflowed: state.overflowed,
                  spoken: Double(state.spoken) / sampleRate, quiet: Double(state.quiet) / sampleRate)
        }
    }

    /// Fills `out` with what the session's input should hear next. Short of
    /// a whole buffer it plays silence and waits, so the microphone's own
    /// timing jitter never cuts a word apart.
    func read(into out: UnsafeMutableBufferPointer<Float>) {
        lock.withLock { state in
            var written = 0
            if state.sending {
                let threshold = Self.speechThreshold(state.floor)
                while state.queue.count - state.head > out.count + frame {
                    let chunk = state.queue[state.head..<(state.head + frame)]
                    guard Self.rms(chunk) < threshold else { break }
                    state.head += frame
                    state.skipped += frame
                }
                if state.queue.count - state.head >= out.count {
                    for index in 0..<out.count { out[index] = state.queue[state.head + index] }
                    state.head += out.count
                    written = out.count
                }
                if state.head > 1 << 16 {
                    state.queue.removeFirst(state.head)
                    state.head = 0
                }
            }
            for index in written..<out.count { out[index] = 0 }
        }
    }

    private static func speechThreshold(_ floor: Float) -> Float { max(floor * 3, 0.003) }

    private static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}
