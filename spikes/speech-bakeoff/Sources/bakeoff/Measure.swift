import AVFoundation
import CryptoKit
import Foundation
import Speech

enum Measure {
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func run(engine: String, iters: Int, clip: String?, output: URL) async throws {
        guard iters > 0 else { throw BakeoffError.usage("iterations must be positive") }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis/Models")
        if engine == "parakeet" {
            try await run(driver: ParakeetDriver(modelsRoot: root), engine: engine, iters: iters, clip: clip, output: output)
        } else if #available(macOS 26.0, *), ["speechanalyzer", "speechanalyzer-fast"].contains(engine) {
            try await run(driver: SpeechDriver(fast: engine.hasSuffix("-fast")), engine: engine, iters: iters, clip: clip, output: output)
        } else {
            throw BakeoffError.usage("unknown or unavailable engine: \(engine)")
        }
    }

    private static func run<D: BenchEngine>(
        driver: D, engine: String, iters: Int, clip: String?, output: URL
    ) async throws {
        let corpus = package.appendingPathComponent("corpus")
        var clips = Run.corpus(corpusDir: corpus)
        if let clip { clips = clips.filter { $0.id == clip } }
        guard !clips.isEmpty else { throw BakeoffError.usage("no matching audio clips") }
        var doc = Run.ResultsDoc(probe: [
            "schema": "2", "engine": engine, "date": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "fluidaudio_pin": "0.17.5",
            "microphone_authorization": String(AVCaptureDevice.authorizationStatus(for: .audio).rawValue),
            "speech_authorization": "\(SFSpeechRecognizer.authorizationStatus().rawValue); not requested by this benchmark",
            "network": "local assets only; no downloads or SFSpeechRecognizer fallback; XPC network activity not independently observed",
            "pid": String(getpid()), "timing": "monotonic; scheduled end, 160 ms chunk availability",
        ], resources: [:], rows: [], partials_probe: [])
        #if DEBUG
        doc.probe["build"] = "debug"
        #else
        doc.probe["build"] = "release"
        #endif
        let loadMemory = RssSampler()
        loadMemory.start()
        do { try await driver.load() } catch {
            _ = loadMemory.stop()
            var row = ClipRow(clip: clips[0].id, engine: engine, variant: engine, iter: -1, status: "blocked_env")
            row.detail = String(describing: error)
            doc.rows.append(row)
            try save(doc, output: output)
            throw error
        }
        let memory = loadMemory.stop()
        let reuseStart = Clock.ms()
        try await driver.load()
        var resource = Run.ResourceEntry(
            rss_baseline_mb: memory.baselineMB, rss_peak_mb: memory.peakMB,
            load_cold_ms: await driver.loadColdMs, disk_bytes: nil,
            note: "fresh-process load with existing caches; RSS excludes system/XPC services",
            rss_load_peak_mb: memory.peakMB, rss_transcribe_peak_mb: nil,
            warm_reuse_ms: Clock.ms() - reuseStart)
        if engine == "parakeet" {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Jarvis/Models")
            resource.disk_bytes = Run.dirBytes(root.appendingPathComponent("parakeet-ultra"))
                + Run.dirBytes(root.appendingPathComponent("parakeet-eou-streaming/160ms"))
        }
        doc.resources[engine] = resource
        try save(doc, output: output)
        // First inference is a distinct warm-up, never mixed into scored p50.
        for iteration in -1..<iters {
            let iterationClips = iteration == -1 ? Array(clips.prefix(1)) : clips
            for spec in iterationClips {
                let source = try Data(contentsOf: spec.wav)
                let view = try BenchSupport.view(Audio.samples(from: spec.wav))
                let inferenceMemory = RssSampler()
                inferenceMemory.start()
                var row: ClipRow
                do {
                    row = try await driver.feed(samples: view.samples, realtime: true)
                } catch {
                    row = ClipRow(clip: spec.id, engine: engine, variant: engine, iter: iteration, status: "engine_error")
                    row.detail = String(describing: error)
                }
                let inferMemory = inferenceMemory.stop()
                row.clip = spec.id; row.iter = iteration
                row.source_sha256 = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
                row.trim_start_ms = view.startMS; row.trim_end_ms = view.endMS
                row.reference = spec.reference
                row.rss_load_mb = memory.peakMB
                row.rss_transcribe_mb = inferMemory.peakMB
                row.first_partial_after_onset_ms = row.first_partial_ms.map { $0 - view.onsetMS }
                if let reference = spec.reference {
                    let words = Wer.normalize(reference).count
                    row.reference_words = words
                    row.wer_final = Wer.rate(reference: reference, hypothesis: row.transcript_final)
                    row.word_edits = Int(((row.wer_final ?? 0) * Double(words)).rounded())
                }
                if let tail = spec.tail {
                    row.tail_contains = Wer.normalize(row.transcript_final).joined(separator: " ")
                        .contains(Wer.normalize(tail).joined(separator: " "))
                }
                resource.rss_peak_mb = max(resource.rss_peak_mb, inferMemory.peakMB)
                resource.rss_transcribe_peak_mb = max(resource.rss_transcribe_peak_mb ?? 0, inferMemory.peakMB)
                if iteration == -1 { resource.first_inference_ms = row.wall_ms }
                doc.resources[engine] = resource
                doc.rows.append(row)
                try save(doc, output: output)
                await Record.say("\(engine) \(spec.id) i\(iteration): \(row.status), final \(Int(row.final_ms_after_audio_end ?? -1))ms, partials \(row.partial_count), WER \(row.wer_final.map { String(format: "%.3f", $0) } ?? "n/a")")
            }
        }
    }

    private static func save(_ doc: Run.ResultsDoc, output: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(doc).write(to: output, options: .atomic)
    }
}
