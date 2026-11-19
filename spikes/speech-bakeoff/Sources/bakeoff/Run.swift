import AVFoundation
import Foundation

/// Corpus runner — `bakeoff feed [--engine X] [--clip Y] [--iters N] [--fast]`
/// Feeds every corpus clip through the chosen engine(s), appends rows to
/// results/results.json, and records probe + resource metadata.
enum Run {
    static let resultsURL = URL(fileURLWithPath: "spikes/speech-bakeoff/results/results.json")

    struct ResultsDoc: Codable {
        var probe: [String: String]
        var resources: [String: ResourceEntry]
        var rows: [ClipRow]
        var partials_probe: [PartialProbeRow]
    }
    struct ResourceEntry: Codable {
        var rss_baseline_mb: Double
        var rss_peak_mb: Double
        var load_cold_ms: Double?
        var disk_bytes: Int64?
        var note: String?
        var rss_load_peak_mb: Double?
        var rss_transcribe_peak_mb: Double?
        var warm_reuse_ms: Double?
        var first_inference_ms: Double?
    }

    static func loadDoc() -> ResultsDoc {
        guard let data = try? Data(contentsOf: resultsURL),
              let doc = try? JSONDecoder().decode(ResultsDoc.self, from: data)
        else { return ResultsDoc(probe: [:], resources: [:], rows: [], partials_probe: []) }
        return doc
    }

    static func saveDoc(_ doc: ResultsDoc) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(doc).write(to: resultsURL)
    }

    /// Directory size helper for model-bytes accounting.
    static func dirBytes(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    struct ClipSpec {
        let id: String
        let wav: URL
        let reference: String? // nil => no WER
        let tail: String?
    }

    static func corpus(corpusDir: URL) -> [ClipSpec] {
        var clips: [ClipSpec] = []
        let mURL = corpusDir.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: mURL),
           let m = try? JSONDecoder().decode(Record.Manifest.self, from: data) {
            for r in m.recordings where r.status == "ok" {
                clips.append(ClipSpec(
                    id: r.id,
                    wav: corpusDir.appendingPathComponent(r.wav),
                    reference: r.prompt, tail: nil))
            }
        }
        let lURL = corpusDir.appendingPathComponent("library/refs.json")
        if let data = try? Data(contentsOf: lURL),
           let lib = try? JSONDecoder().decode(LibDoc.self, from: data) {
            for c in lib.clips {
                let wav = corpusDir.appendingPathComponent("library/\(c.id).wav")
                if FileManager.default.fileExists(atPath: wav.path) {
                    clips.append(ClipSpec(id: c.id, wav: wav, reference: nil, tail: c.tail))
                }
            }
        }
        return clips
    }

    struct LibDoc: Codable { let clips: [LibClip] }
    struct LibClip: Codable { let id: String; let source: String; let tail: String }

    static func feed(engineArg: String, clipArg: String?, iters: Int, fast: Bool) async throws {
        var doc = loadDoc()
        let corpusDir = URL(fileURLWithPath: "spikes/speech-bakeoff/corpus")
        var clips = corpus(corpusDir: corpusDir)
        if let clipArg { clips = clips.filter { $0.id == clipArg } }
        guard !clips.isEmpty else { throw BakeoffError.usage("no corpus clips — run `bakeoff record` and `setup-corpus` first") }

        let engines = engineArg == "all" ? ["parakeet", "speechanalyzer"] : [engineArg]
        for engine in engines {
            let sampler = RssSampler(); sampler.start()
            var res = ResourceEntry(rss_baseline_mb: sampler.baselineMB, rss_peak_mb: 0)
            switch engine {
            case "parakeet":
                let root = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Jarvis/Models")
                let drv = ParakeetDriver(modelsRoot: root)
                do {
                    try await drv.load()
                } catch {
                    for c in clips {
                        var r = ClipRow(clip: c.id, engine: engine, variant: "eou160+ultra", iter: 0)
                        r.status = "blocked_env"; r.detail = "load: \(error)"
                        doc.rows.append(r)
                    }
                    doc.resources[engine] = res
                    continue
                }
                res.load_cold_ms = await drv.loadColdMs
                res.disk_bytes = dirBytes(root)
                try await runClips(drv: drv, clips: clips, iters: iters, fast: fast, doc: &doc)
            case "speechanalyzer":
                guard #available(macOS 26.0, *) else {
                    for c in clips {
                        var r = ClipRow(clip: c.id, engine: engine, variant: "progressiveTranscription", iter: 0)
                        r.status = "blocked_env"; r.detail = "requires macOS 26"
                        doc.rows.append(r)
                    }
                    continue
                }
                let drv = SpeechDriver()
                let (_, installed, note) = await drv.probe()
                doc.probe["speech_locale"] = note
                do {
                    try await drv.load()
                } catch {
                    for c in clips {
                        var r = ClipRow(clip: c.id, engine: engine, variant: "progressiveTranscription", iter: 0)
                        r.status = installed ? "engine_error" : "blocked_env"
                        r.detail = "load: \(error)"
                        doc.rows.append(r)
                    }
                    doc.resources[engine] = res
                    continue
                }
                res.load_cold_ms = await drv.loadColdMs
                res.note = await drv.assetNote
                try await runClips(drv: drv, clips: clips, iters: iters, fast: fast, doc: &doc)
            default:
                throw BakeoffError.usage("unknown engine \(engine)")
            }
            let (baseline, peak) = sampler.stop()
            res.rss_baseline_mb = baseline; res.rss_peak_mb = peak
            doc.resources[engine] = res
        }
        saveDoc(doc)
        print("wrote \(doc.rows.count) total rows -> results/results.json")
    }

    private static func runClips(drv: ParakeetDriver, clips: [ClipSpec], iters: Int, fast: Bool, doc: inout ResultsDoc) async throws {
        for i in 0 ..< iters {
            for c in clips {
                let samples = try Audio.samples(from: c.wav)
                var row = try await drv.feed(samples: samples, realtime: !fast)
                row.clip = c.id; row.iter = i
                finish(&row, clip: c)
                doc.rows.append(row)
                print("parakeet \(c.id) iter\(i): \(row.status) final=\(String(format: "%.0f", row.final_ms_after_audio_end ?? -1))ms partials=\(row.partial_count) wer=\(row.wer_final.map { String(format: "%.2f", $0) } ?? "n/a")")
            }
        }
    }

    @available(macOS 26.0, *)
    private static func runClips(drv: SpeechDriver, clips: [ClipSpec], iters: Int, fast: Bool, doc: inout ResultsDoc) async throws {
        for i in 0 ..< iters {
            for c in clips {
                let samples = try Audio.samples(from: c.wav)
                var row = try await drv.feed(samples: samples, realtime: !fast)
                row.clip = c.id; row.iter = i
                finish(&row, clip: c)
                doc.rows.append(row)
                print("speechanalyzer \(c.id) iter\(i): \(row.status) final=\(String(format: "%.0f", row.final_ms_after_audio_end ?? -1))ms partials=\(row.partial_count) wer=\(row.wer_final.map { String(format: "%.2f", $0) } ?? "n/a")")
            }
        }
    }

    private static func finish(_ row: inout ClipRow, clip: ClipSpec) {
        if row.status != "ok" { return }
        if let ref = clip.reference {
            row.wer_final = Wer.rate(reference: ref, hypothesis: row.transcript_final)
        }
        if let tail = clip.tail {
            let hay = Wer.normalize(row.transcript_final).joined(separator: " ")
            let needle = Wer.normalize(tail).joined(separator: " ")
            row.tail_contains = hay.contains(needle)
        }
    }
}
