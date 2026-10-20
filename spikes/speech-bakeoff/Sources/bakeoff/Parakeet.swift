import AVFoundation
import FluidAudio
import Foundation

/// Production engine/configuration, with benchmark-only synchronous tracing.
actor ParakeetDriver: BenchEngine {
    let modelsRoot: URL
    private var eou: StreamingEouAsrManager?
    private var asr: AsrManager?
    private(set) var loadColdMs: Double?

    init(modelsRoot: URL) { self.modelsRoot = modelsRoot }

    func load() async throws {
        guard asr == nil else { return }
        let t0 = Clock.ms()
        let eou = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)
        let ultraDir = modelsRoot.appendingPathComponent(
            Repo.parakeetUltra.folderName, isDirectory: true)
        // Local-only APIs: missing assets fail rather than silently downloading.
        let loaded = try AsrModels.loadLocal(
            from: ultraDir, version: .ultra, encoderComputeUnits: .cpuAndNeuralEngine)
        try await eou.loadModels(from: modelsRoot.appendingPathComponent("parakeet-eou-streaming/160ms"))
        asr = AsrManager(models: loaded)
        self.eou = eou
        loadColdMs = Clock.ms() - t0
    }

    func feed(samples: [Float], realtime: Bool = true) async throws -> ClipRow {
        guard let eou, let asr else { throw BakeoffError.engine("parakeet not loaded") }
        await eou.reset()
        let trace = TraceLedger()
        await eou.setPartialCallback { trace.append("partial", $0) }
        await eou.setEouCallback { trace.append("eou", $0) }
        var fedMs: Double = 0
        var lag: Double = 0
        for ch in Audio.chunks(samples) {
            fedMs += Double(ch.count) / Audio.sampleRate * 1000
            try await BenchSupport.waitForAudio(endMS: fedMs, start: trace.start, realtime: realtime)
            lag = max(lag, Clock.ms() - trace.start - fedMs)
            trace.consumed(fedMs)
            let buf = try Audio.buffer(ch)
            _ = try await eou.process(audioBuffer: buf)
        }
        // Fn-up flush: do not invent 1.6 seconds of unpaced trailing silence.
        let finalStreamed = try await eou.finish()
        var final = finalStreamed.trimmingCharacters(in: .whitespacesAndNewlines)
        var refinementError: String?
        let layers = await asr.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: layers)
        do {
            let refined = try await asr.transcribe(samples, decoderState: &decoderState)
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !refined.isEmpty { final = refined }
            else { refinementError = "Ultra returned empty; streamed fallback" }
        } catch {
            refinementError = String(describing: error)
        }
        trace.append("final", final)
        var row = BenchSupport.row(
            engine: "parakeet", variant: "eou160+ultra", trace: trace,
            samples: samples, final: final, feedLag: lag)
        row.eou_ms = row.events.first { $0.type == "eou" }?.t_ms
        row.eou_kind = "explicit EOU flag (null when no flag before Fn-up)"
        row.streamed_final = finalStreamed
        row.refinement_error = refinementError
        return row
    }

    /// Batch-only decode (no streaming) — for the batch latency column.
    func batch(samples: [Float]) async throws -> (ms: Double, text: String) {
        guard let asr else { throw BakeoffError.engine("parakeet not loaded") }
        let t0 = Clock.ms()
        let layers = await asr.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: layers)
        let text = try await asr.transcribe(samples, decoderState: &decoderState)
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Clock.ms() - t0, text)
    }

    func reset() async { await eou?.reset() }
}
