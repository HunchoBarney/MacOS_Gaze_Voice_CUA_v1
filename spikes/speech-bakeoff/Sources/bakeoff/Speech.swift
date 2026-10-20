import AVFoundation
import CoreMedia
import Foundation
import Speech

/// SpeechAnalyzer driver — `SpeechTranscriber` with the progressive
/// preset (volatile partials + final results) fed by an AsyncSequence
/// of AnalyzerInput, plus a file-based batch variant.
@available(macOS 26.0, *)
actor SpeechDriver: BenchEngine {
    let fast: Bool
    init(fast: Bool = false) { self.fast = fast }
    private(set) var loadColdMs: Double?
    private(set) var assetNote: String = "unprobed"

    /// Locale readiness probe — installed vs supported, and whether
    /// assets needed downloading (recorded, not assumed).
    /// NB: the framework reports underscore identifiers (en_US);
    /// contains() on Locale(identifier:"en-US") is string-strict → false.
    func probe() async -> (supported: Bool, installed: Bool, note: String) {
        let supported = await SpeechTranscriber.supportedLocales
            .contains { $0.identifier == "en_US" }
        let installed = await SpeechTranscriber.installedLocales
            .contains { $0.identifier == "en_US" }
        let note = "en_US supported=\(supported) installed=\(installed)"
        assetNote = note
        return (supported, installed, note)
    }

    func load() async throws {
        guard loadColdMs == nil else { return }
        let t0 = Clock.ms()
        let readiness = await probe()
        guard readiness.supported, readiness.installed else {
            throw BakeoffError.engine("local en_US SpeechTranscriber assets missing; no download or server fallback attempted")
        }
        let module = transcriber()
        let analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw BakeoffError.engine("no compatible SpeechAnalyzer input format")
        }
        try await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
        loadColdMs = Clock.ms() - t0
    }

    private func transcriber() -> SpeechTranscriber {
        if fast {
            return SpeechTranscriber(
                locale: Locale(identifier: "en_US"), transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        }
        return SpeechTranscriber(locale: Locale(identifier: "en_US"), preset: .progressiveTranscription)
    }

    /// Feed a clip at real-time pacing through a streaming analyzer.
    /// `eou_ms` maps to the timestamp of the last isFinal result.
    func feed(samples: [Float], realtime: Bool = true) async throws -> ClipRow {
        let transcriber = transcriber()
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let prepareStart = Clock.ms()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              format.sampleRate == Audio.sampleRate, format.channelCount == 1,
              format.commonFormat == .pcmFormatInt16 else {
            throw BakeoffError.engine("SpeechAnalyzer format changed; explicit conversion required")
        }
        try await analyzer.prepareToAnalyze(in: format)
        let prepareMS = Clock.ms() - prepareStart
        let trace = TraceLedger()
        let outcome = LockedOutcome()
        let collect = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        trace.append("segment_final", text)
                        await outcome.append(
                            start: CMTimeGetSeconds(result.range.start),
                            end: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)), text: text)
                    } else if !text.isEmpty {
                        trace.append("partial", text)
                    }
                }
            } catch {
                await outcome.mark(error: error.localizedDescription)
            }
        }
        var lag: Double = 0
        var fedMs: Double = 0
        do {
            try await analyzer.start(inputSequence: stream)
            for ch in Audio.chunks(samples) {
                let start = fedMs
                fedMs += Double(ch.count) / Audio.sampleRate * 1000
                try await BenchSupport.waitForAudio(endMS: fedMs, start: trace.start, realtime: realtime)
                lag = max(lag, Clock.ms() - trace.start - fedMs)
                trace.consumed(fedMs)
                let buf = try Audio.bufferInt16(ch)
                cont.yield(AnalyzerInput(buffer: buf, bufferStartTime: CMTime(seconds: start / 1000, preferredTimescale: 16_000)))
            }
            cont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            _ = await collect.value
        } catch {
            cont.finish()
            collect.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let final = await outcome.segments.text
        trace.append("final", final)
        var row = BenchSupport.row(
            engine: fast ? "speechanalyzer-fast" : "speechanalyzer",
            variant: fast ? "volatile+fastResults" : "progressiveTranscription",
            trace: trace, samples: samples, final: final, feedLag: lag, prepareMS: prepareMS)
        row.eou_ms = row.events.last { $0.type == "segment_final" }?.t_ms
        row.eou_kind = "last finalized segment; NOT an EOU detector"
        if let err = await outcome.error {
            row.status = "engine_error"; row.detail = err
        }
        return row
    }

    actor LockedOutcome {
        var segments = FinalSegments()
        var error: String?
        func append(start: Double, end: Double, text: String) {
            segments.insert(start: start, end: end, text: text)
        }
        func mark(error e: String) { error = e }
    }
}
