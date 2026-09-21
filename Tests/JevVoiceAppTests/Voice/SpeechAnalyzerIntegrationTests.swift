import XCTest
import Speech
import AVFoundation
import JevVoiceCore
@testable import JevVoice

final class SpeechAnalyzerIntegrationTests: XCTestCase {
    @MainActor
    func testSpeechPreparationTimingOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_SPEECH_PREPARE_TEST"] == "1" else { throw XCTSkip("Opt-in on-device model preparation; no microphone capture") }
        for sample in 1...3 {
            let started = ProcessInfo.processInfo.systemUptime
            let module = try await SpeechAssets.transcriber()
            let assets = await AssetInventory.status(forModules: [module])
            XCTAssertEqual(assets, .installed)
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            let configured = ProcessInfo.processInfo.systemUptime
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.prepareToAnalyze(in: format)
            print("Speech preparation sample", sample, "assets_format_ms", (configured - started) * 1000,
                  "prepare_ms", (ProcessInfo.processInfo.systemUptime - configured) * 1000)
            await analyzer.cancelAndFinishNow()
        }
        await SpeechAssets.shared.refresh()
        XCTAssertTrue(SpeechAssets.shared.ready)
        for sample in 1...3 {
            let started = ProcessInfo.processInfo.systemUptime
            let module = try await SpeechAssets.transcriber()
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            let analyzer = SpeechAssets.analyzer(for: module)
            try await analyzer.prepareToAnalyze(in: format)
            print("Prewarmed speech preparation sample", sample, "total_ms", (ProcessInfo.processInfo.systemUptime - started) * 1000)
            await analyzer.cancelAndFinishNow()
        }
    }
    @MainActor
    func testRecordedAudioWithInstalledAppleAssets() async throws {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_SPEECH_TEST_FILE"] else {
            throw XCTSkip("Opt-in recorded-audio check; no microphone or model call in the normal suite.")
        }
        try await recognizeFixture(path: path, requireStreaming: true, finalizationLimit: nil)
    }

    @MainActor
    func testShortUtteranceFinalizesWithinCurrentVoiceDeadlineOptIn() async throws {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_SHORT_SPEECH_TEST_FILE"] else {
            throw XCTSkip("Opt-in short recorded utterance with immediate end of input")
        }
        try await recognizeFixture(path: path, requireStreaming: false, finalizationLimit: VoiceTimings().finalization)
    }

    @MainActor
    private func recognizeFixture(path: String, requireStreaming: Bool, finalizationLimit: Double?) async throws {
        if ProcessInfo.processInfo.environment["JARVIS_PREPARE_SPEECH"] == "1" {
            await SpeechAssets.shared.refresh(install: true)
        }
        let module = try await SpeechAssets.transcriber()
        let status = await AssetInventory.status(forModules: [module])
        XCTAssertEqual(status, .installed, "Prepare speech assets in the app's Voice settings.")
        guard status == .installed else { return }
        let analyzer = SpeechAssets.analyzer(for: module)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let compatible = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: file.processingFormat)
        let format = try XCTUnwrap(compatible)
        let feed = try AnalyzerAudioFeed(input: file.processingFormat, output: format)
        try await analyzer.prepareToAnalyze(in: format)
        let observation = StreamingObservation()
        let collection = Task { () throws -> String in
            var transcript = RangedTranscript()
            for try await result in module.results {
                if !observation.inputEnded { observation.observedBeforeEnd = true }
                try transcript.apply(.init(start: result.range.start.seconds,
                    end: CMTimeRangeGetEnd(result.range).seconds,
                    text: String(result.text.characters), isFinal: result.isFinal))
            }
            return transcript.text
        }
        do {
            try await analyzer.start(inputSequence: feed.stream)
            while file.framePosition < file.length {
                let count = AVAudioFrameCount(min(1024, file.length - file.framePosition))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
                try file.read(into: buffer, frameCount: count)
                feed.append(buffer)
                try await Task.sleep(for: .seconds(Double(count) / file.processingFormat.sampleRate))
            }
            observation.inputEnded = true
            let finishStarted = ProcessInfo.processInfo.systemUptime
            feed.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await collection.value
            let finalization = ProcessInfo.processInfo.systemUptime - finishStarted
            print("Recorded speech finalization ms:", finalization * 1000)
            if let finalizationLimit { XCTAssertLessThanOrEqual(finalization, finalizationLimit, "The current live deadline would discard this utterance") }
            XCTAssertTrue(text.lowercased().contains("blue notebook"), "Recorded fixture content missing: \(text)")
            XCTAssertTrue(text.lowercased().contains("desk"), "Final word missing: \(text)")
            if requireStreaming { XCTAssertTrue(observation.observedBeforeEnd, "No streaming result before audio ended") }
        } catch {
            feed.finish(); collection.cancel(); await analyzer.cancelAndFinishNow(); throw error
        }
    }
}

@MainActor
private final class StreamingObservation {
    var inputEnded = false
    var observedBeforeEnd = false
}
