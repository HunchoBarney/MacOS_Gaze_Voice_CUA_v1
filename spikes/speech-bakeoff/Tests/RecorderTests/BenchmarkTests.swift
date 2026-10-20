import Foundation
import Testing
@testable import BakeoffCore

@Suite
struct BenchmarkTests {
    @Test func wordErrorRateHandlesEmptyResultsWithoutCrashing() {
        #expect(Wer.rate(reference: "open this", hypothesis: "") == 1)
        #expect(Wer.rate(reference: "", hypothesis: "") == 0)
        #expect(Wer.rate(reference: "open this", hypothesis: "Open, this!") == 0)
        #expect(Wer.flicker(["", "open"]) == 4)
    }

    @Test func finalizedSegmentsRetainEarlierSentencesAndReplaceCorrections() {
        var finals = FinalSegments()
        finals.insert(start: 3, end: 5, text: "Second sentence.")
        finals.insert(start: 0, end: 3, text: "First sentence.")
        #expect(finals.text == "First sentence. Second sentence.")
        finals.insert(start: 3, end: 5, text: "Corrected second.")
        #expect(finals.text == "First sentence. Corrected second.")
        finals.insert(start: 0, end: 5, text: "Replacement of both.")
        #expect(finals.text == "Replacement of both.")
    }

    @Test func scheduledEndDoesNotHideProcessingBacklog() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus/library/lib03.wav")
        let samples = Array(try Audio.samples(from: path).prefix(2560))
        let trace = TraceLedger()
        try await Task.sleep(for: .milliseconds(250))
        trace.append("final", "real input timing control")
        let row = BenchSupport.row(
            engine: "timing-control", variant: "guard", trace: trace,
            samples: samples, final: "timing control", feedLag: 50)
        #expect(row.input_duration_ms == 160)
        #expect((row.final_ms_after_audio_end ?? 0) >= 80)
        #expect(row.feed_lag_ms == 50)
    }

    @Test func realAudioViewDoesNotModifyTheSource() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("corpus/library/lib03.wav")
        let original = try Data(contentsOf: path)
        let samples = try Audio.samples(from: path)
        let view = try BenchSupport.view(samples)
        #expect(view.startMS >= 0)
        #expect(view.endMS <= Double(samples.count) / 16)
        #expect(view.onsetMS >= 0)
        #expect(view.samples.count <= samples.count)
        #expect(view.samples.count > 16_000)
        #expect(try Data(contentsOf: path) == original)
    }
}
