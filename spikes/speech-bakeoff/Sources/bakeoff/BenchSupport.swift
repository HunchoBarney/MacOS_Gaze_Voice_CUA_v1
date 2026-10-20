import Foundation
import Synchronization

protocol BenchEngine: Actor {
    var loadColdMs: Double? { get async }
    func load() async throws
    func feed(samples: [Float], realtime: Bool) async throws -> ClipRow
}

struct TraceEvent: Codable, Sendable {
    let t_ms: Double
    let audio_ms: Double
    let type: String
    let text: String
}

/// Callbacks timestamp synchronously: actor scheduling cannot inflate partial latency.
final class TraceLedger: Sendable {
    private struct State { var events: [TraceEvent] = []; var audioMS: Double = 0 }
    private let state = Mutex(State())
    let start = Clock.ms()

    func consumed(_ milliseconds: Double) { state.withLock { $0.audioMS = milliseconds } }
    func append(_ type: String, _ text: String) {
        let time = Clock.ms() - start
        state.withLock { $0.events.append(TraceEvent(t_ms: time, audio_ms: $0.audioMS, type: type, text: text)) }
    }
    var events: [TraceEvent] { state.withLock { $0.events } }
}

/// Final results can cover several sentences. Never keep only the last segment.
struct FinalSegments: Sendable {
    struct Segment: Sendable {
        let start: Double
        let end: Double
        let text: String
    }
    private var segments: [Segment] = []

    mutating func insert(start: Double, end: Double, text: String) {
        segments.removeAll { ($0.start == start && $0.end == end) || ($0.start < end && start < $0.end) }
        segments.append(Segment(start: start, end: end, text: text))
    }

    var text: String {
        segments.sorted { $0.start < $1.start }.map(\.text)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum BenchSupport {
    static func waitForAudio(endMS: Double, start: Double, realtime: Bool) async throws {
        guard realtime else { return }
        let delay = endMS - (Clock.ms() - start)
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
    }

    static func row(
        engine: String, variant: String, trace: TraceLedger, samples: [Float],
        final: String, feedLag: Double, prepareMS: Double = 0
    ) -> ClipRow {
        var row = ClipRow(clip: "", engine: engine, variant: variant, iter: 0)
        row.events = trace.events
        let partials = row.events.filter { $0.type == "partial" && !$0.text.isEmpty }
        row.input_duration_ms = Double(samples.count) / Audio.sampleRate * 1000
        row.wall_ms = Clock.ms() - trace.start
        row.final_ms_after_audio_end = max(0, row.wall_ms - (row.input_duration_ms ?? 0))
        row.first_partial_ms = partials.first?.t_ms
        row.last_partial_ms = partials.last?.t_ms
        row.partial_count = partials.count
        row.partial_flicker = Wer.flicker(partials.map(\.text))
        row.feed_lag_ms = max(0, feedLag)
        row.prepare_ms = prepareMS
        row.transcript_final = final.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.transcript_final.isEmpty { row.status = "engine_error"; row.detail = "empty transcript" }
        return row
    }

    struct View {
        let samples: [Float]
        let startMS: Double
        let endMS: Double
        let onsetMS: Double
    }

    static func view(_ samples: [Float]) throws -> View {
        let window = 320 // 20 ms at 16 kHz
        guard !samples.isEmpty else { throw BakeoffError.audio("empty benchmark file") }
        let windows = stride(from: 0, to: samples.count, by: window).map { start -> Double in
            let chunk = samples[start..<min(start + window, samples.count)]
            return sqrt(chunk.reduce(0) { $0 + Double($1) * Double($1) } / Double(chunk.count))
        }
        let threshold = max(pow(10, -45.0 / 20), (windows.max() ?? 0) * pow(10, -30.0 / 20))
        guard let first = windows.firstIndex(where: { $0 >= threshold }),
              let last = windows.lastIndex(where: { $0 >= threshold }) else {
            throw BakeoffError.audio("no speech-energy region in benchmark file")
        }
        let start = max(0, first * window - 3200)
        let end = min(samples.count, (last + 1) * window + 3200)
        return View(
            samples: Array(samples[start..<end]), startMS: Double(start) / 16,
            endMS: Double(end) / 16, onsetMS: Double(first * window - start) / 16)
    }
}
