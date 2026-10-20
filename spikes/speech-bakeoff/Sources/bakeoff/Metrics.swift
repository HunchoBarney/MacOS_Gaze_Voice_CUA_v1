import Darwin
import Foundation
import Synchronization

/// Result row emitted per clip × engine × iteration. Written to results.json.
struct ClipRow: Codable {
    let kind: String // "clip"
    var clip: String
    let engine: String // parakeet | speechanalyzer | speechanalyzer-batch
    let variant: String
    var iter: Int
    var wall_ms: Double
    var first_partial_ms: Double? // feed-timeline ms of first non-empty partial
    var last_partial_ms: Double?
    var eou_ms: Double? // parakeet: EOU flag; speech: last isFinal timestamp
    var final_ms_after_audio_end: Double?
    var partial_count: Int
    var partial_flicker: Double? // mean edit distance between consecutive partials
    var transcript_final: String
    var wer_final: Double? // nil when no ground truth
    var tail_contains: Bool? // library clips: tail phrase present
    var status: String // ok | blocked_env | engine_error | timeout
    var detail: String?
    var events: [TraceEvent] = []
    var input_duration_ms: Double?
    var feed_lag_ms: Double?
    var prepare_ms: Double?
    var first_partial_after_onset_ms: Double?
    var eou_kind: String?
    var streamed_final: String?
    var refinement_error: String?
    var word_edits: Int?
    var reference_words: Int?
    var rss_load_mb: Double?
    var rss_transcribe_mb: Double?
    var source_sha256: String?
    var trim_start_ms: Double?
    var trim_end_ms: Double?
    var reference: String?
    init(clip: String, engine: String, variant: String, iter: Int, status: String = "ok") {
        kind = "clip"; self.clip = clip; self.engine = engine
        self.variant = variant; self.iter = iter; self.status = status
        wall_ms = 0; partial_count = 0; transcript_final = ""
    }
}

struct PartialProbeRow: Codable {
    let kind: String // "partials_probe"
    let engine: String
    var events: [PartialEvent]
    init(engine: String) { kind = "partials_probe"; self.engine = engine; events = [] }
}

struct PartialEvent: Codable {
    let t_ms: Double // feed-timeline timestamp
    let type: String // partial | eou | final
    let text_excerpt: String
}

/// Monotonic time: wall-clock adjustments must not change a latency.
enum Clock {
    static func ms() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
}

/// Peak-RSS sampling (proc_pid_rusage, RUSAGE_INFO_V4).
final class RssSampler: Sendable {
    private struct State { var baseline: Double = 0; var peak: Double = 0 }
    private let state = Mutex(State())
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    var baselineMB: Double { state.withLock { $0.baseline } }

    static func currentMB() -> Double {
        var info = rusage_info_v4()
        let pid = getpid()
        let err = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard err == 0 else { return 0 }
        return Double(info.ri_resident_size) / 1_048_576.0
    }

    func start() {
        let baseline = Self.currentMB()
        state.withLock { $0.baseline = baseline; $0.peak = baseline }
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    func stop() -> (baselineMB: Double, peakMB: Double) {
        timer.cancel()
        sample()
        return state.withLock { ($0.baseline, $0.peak) }
    }

    private func sample() {
        let current = Self.currentMB()
        state.withLock { $0.peak = max($0.peak, current) }
    }
}

/// Normalized word error rate: lowercase, strip punctuation, collapse
/// whitespace, Levenshtein on words.
enum Wer {
    static func normalize(_ s: String) -> [String] {
        s.lowercased()
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
    }

    static func rate(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var prev = Array(0 ... hyp.count)
        for index in ref.indices {
            let i = index + 1
            var cur = Array(repeating: 0, count: hyp.count + 1)
            cur[0] = i
            for index in hyp.indices {
                let j = index + 1
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }

    /// Mean character-level edit distance between consecutive partial strings.
    static func flicker(_ partials: [String]) -> Double? {
        guard partials.count > 1 else { return nil }
        var total = 0
        for i in 1 ..< partials.count {
            total += lev(partials[i - 1], partials[i])
        }
        return Double(total) / Double(partials.count - 1)
    }

    private static func lev(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0 ... y.count)
        for index in x.indices {
            let i = index + 1
            var cur = Array(repeating: 0, count: y.count + 1)
            cur[0] = i
            for index in y.indices {
                let j = index + 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}
