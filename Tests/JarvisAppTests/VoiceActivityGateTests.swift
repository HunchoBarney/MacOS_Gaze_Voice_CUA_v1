import AVFoundation
import XCTest
@testable import Jarvis

/// Contract: hands-free uploads microphone audio only while local speech
/// detection hears someone, starting a second before the speech, and the
/// Mac ends each turn itself after `endOfTurn` of quiet: one start and one
/// end per utterance, never inside a shorter pause.
final class VoiceActivityGateTests: XCTestCase {
    private let rate = 24_000.0
    private let frame = 2_400
    /// One Silero chunk (256 ms) of 24 kHz audio.
    private let chunkFrame = 6_144

    /// A loud buffer scores as speech, a quiet one as silence.
    private func gate(_ tuning: VoiceActivityGate.Tuning = .init()) throws -> VoiceActivityGate {
        try VoiceActivityGate(sampleRate: rate, tuning: tuning) { chunk in
            chunk.map { $0 * $0 }.reduce(0, +) / Float(chunk.count) > 0.01 ? 0.9 : 0.05
        }
    }

    private func buffer(loud: Bool, seed: Int16 = 0, frames: Int? = nil) -> Data {
        let samples = (0..<(frames ?? frame)).map { i -> Int16 in
            let quiet: Int16 = i % 2 == 0 ? 3 : -3
            let sample = loud ? Int16(8_000 * sin(Double(i) * 0.2)) : quiet
            return sample &+ seed
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func audio(_ events: [VoiceActivityGate.Event]) -> [Data] {
        events.compactMap { if case .audio(let data) = $0 { return data }; return nil }
    }

    // MARK: - Scripted speech: one score per 256 ms chunk

    private final class Script: @unchecked Sendable {
        let scores: [Float]
        var scored = 0
        init(_ scores: [Float]) { self.scores = scores }
        func next() -> Float { defer { scored += 1 }; return scored < scores.count ? scores[scored] : 0.05 }
    }

    private struct Run {
        var events: [VoiceActivityGate.Event] = []
        /// Chunks scored when each turn ended.
        var endedAfter: [Int] = []
        var sentPerBuffer: [Int: Int] = [:]
        var buffers: [Data: Int] = [:]
    }

    /// `script` reads S for a speech chunk and . for a quiet one. Each
    /// microphone buffer is one chunk long and carries its own seed, so the
    /// uploaded audio can be traced back to the buffer it came from.
    private func run(_ script: String, tuning: VoiceActivityGate.Tuning = .init()) async throws -> Run {
        let scores = Script(script.map { $0 == "S" ? 0.9 : 0.05 })
        let gate = try VoiceActivityGate(sampleRate: rate, tuning: tuning) { _ in scores.next() }
        var result = Run()
        for index in 0..<(script.count + 4) {
            let data = buffer(loud: false, seed: Int16(index * 7), frames: chunkFrame)
            result.buffers[data] = index
            let events = try await gate.admit(data)
            result.events += events
            if events.contains(.turnEnded) { result.endedAfter.append(scores.scored) }
        }
        for data in audio(result.events) { result.sentPerBuffer[result.buffers[data]!, default: 0] += 1 }
        return result
    }

    private func turns(_ run: Run) -> [VoiceActivityGate.Event] {
        run.events.filter { $0 == .turnStarted || $0 == .turnEnded }
    }

    /// Speech that never pauses ends its turn at maxTurn and, still going,
    /// opens the next one: every buffer goes up exactly once.
    func testContinuousSpeechIsCutIntoTurnsOfAtMostMaxTurn() async throws {
        var tuning = VoiceActivityGate.Tuning()
        tuning.maxTurn = 1.0
        let result = try await run("SSSSSSSSSSSS", tuning: tuning)
        XCTAssertEqual(Array(result.endedAfter.prefix(2)), [5, 10], "1.0 s caps a turn at four chunks after its first")
        XCTAssertEqual(Array(turns(result).prefix(4)), [.turnStarted, .turnEnded, .turnStarted, .turnEnded])
        for index in 0..<12 {
            XCTAssertEqual(result.sentPerBuffer[index], 1, "buffer \(index) is uploaded exactly once")
        }
        XCTAssertEqual(VoiceActivityGate.Tuning().maxTurn, 30)
    }

    func testTheTurnEndsAfterEndOfTurnOfQuiet() async throws {
        let result = try await run("........SSSS......")
        XCTAssertEqual(turns(result), [.turnStarted, .turnEnded])
        XCTAssertEqual(result.endedAfter, [8 + 4 + 3], "0.6 s rounds up to three quiet 256 ms chunks")
        XCTAssertEqual(result.events.first, .turnStarted, "the turn starts before its first audio")
        XCTAssertEqual(result.events.last, .turnEnded, "and ends after its last")
    }

    func testPausesShorterThanTheThresholdKeepOneTurn() async throws {
        let result = try await run("......SSS..SSS.SS..SSS.......")
        XCTAssertEqual(turns(result), [.turnStarted, .turnEnded], "pauses of 256 and 512 ms never end the turn")
        XCTAssertEqual(result.endedAfter, [22 + 3])
        XCTAssertTrue(result.sentPerBuffer.values.allSatisfy { $0 == 1 }, "no buffer is uploaded twice")
        for index in 6..<22 { XCTAssertEqual(result.sentPerBuffer[index], 1, "buffer \(index) inside the turn is uploaded") }
    }

    func testAPauseAtTheThresholdEndsTheTurn() async throws {
        let result = try await run("......SSS...SSS......")
        XCTAssertEqual(turns(result), [.turnStarted, .turnEnded, .turnStarted, .turnEnded])
        XCTAssertEqual(result.endedAfter, [6 + 3 + 3, 12 + 3 + 3])
    }

    func testSpeechAfterTheCommitIsANewTurnWithItsFirstWord() async throws {
        let result = try await run("......SSSS.....SSS......")
        XCTAssertEqual(turns(result), [.turnStarted, .turnEnded, .turnStarted, .turnEnded])
        let second = try XCTUnwrap(result.events.lastIndex(of: .turnStarted))
        let secondTurn = audio(Array(result.events[second...])).compactMap { result.buffers[$0] }
        XCTAssertTrue(result.sentPerBuffer.values.allSatisfy { $0 == 1 },
                      "the new turn's pre-roll holds only audio heard after the commit")
        XCTAssertTrue(secondTurn.contains(14), "the quiet just before the second turn's first word is its pre-roll")
        XCTAssertTrue(secondTurn.contains(15), "the second turn's first word belongs to it")
        XCTAssertFalse(secondTurn.contains { $0 < 13 }, "nothing from the first turn")
    }

    func testEndOfTurnIsTunable() async throws {
        let short = try await run("....SSS..SSS.....", tuning: .init(endOfTurn: 0.5))
        XCTAssertEqual(turns(short), [.turnStarted, .turnEnded, .turnStarted, .turnEnded], "0.5 s is two quiet chunks")
        XCTAssertEqual(short.endedAfter.first, 4 + 3 + 2)
        let long = try await run("....SSS...SSS.......", tuning: .init(endOfTurn: 1.0))
        XCTAssertEqual(turns(long), [.turnStarted, .turnEnded], "1 s is four quiet chunks")
        XCTAssertEqual(long.endedAfter, [13 + 4])
    }

    // MARK: - Energy-scored buffers

    func testRoomAudioStaysOnTheMac() async throws {
        let gate = try gate()
        for _ in 0..<50 { let sent = try await gate.admit(buffer(loud: false)); XCTAssertTrue(sent.isEmpty) }
        let usage = await gate.usage
        XCTAssertEqual(usage.heard, 5, accuracy: 0.01)
        XCTAssertEqual(usage.sentSpeech, 0)
    }

    func testSpeechUploadsWithTheSecondBeforeIt() async throws {
        let gate = try gate()
        var quiet: [Data] = []
        for i in 0..<30 {
            let data = buffer(loud: false, seed: Int16(i))
            quiet.append(data)
            _ = try await gate.admit(data)
        }
        var events: [VoiceActivityGate.Event] = []
        var speech: [Data] = []
        for i in 0..<10 {
            let data = buffer(loud: true, seed: Int16(i))
            speech.append(data)
            events += try await gate.admit(data)
        }
        XCTAssertEqual(events.first, .turnStarted, "speech opens a turn before its pre-roll goes out")
        XCTAssertFalse(events.contains(.turnEnded))
        let sent = audio(events)
        XCTAssertEqual(Array(sent.suffix(speech.count)), speech, "every speech buffer is uploaded, in order")
        let lead = sent.dropLast(speech.count)
        XCTAssertGreaterThanOrEqual(lead.count, 10, "at least a second of audio from before the speech")
        XCTAssertLessThanOrEqual(lead.count, 16, "and no more than the pre-roll plus the scoring lag")
        XCTAssertEqual(Array(lead), Array(quiet.suffix(lead.count)))
    }

    func testAfterTheTurnEndsRoomAudioStaysOnTheMac() async throws {
        let gate = try gate()
        for _ in 0..<10 { _ = try await gate.admit(buffer(loud: true)) }
        var after: [VoiceActivityGate.Event] = []
        for _ in 0..<40 { after += try await gate.admit(buffer(loud: false)) }
        XCTAssertEqual(after.filter { $0 == .turnEnded }.count, 1)
        XCTAssertEqual(after.last, .turnEnded, "nothing is uploaded once the turn has ended")
        XCTAssertLessThanOrEqual(audio(after).count, 14, "real audio stops within the end-of-turn wait and scoring lag")
        XCTAssertFalse(audio(after).contains { $0.allSatisfy { $0 == 0 } }, "no digital silence is sent")
    }

    // MARK: - The shipped Silero model

    func testSileroHearsSpokenWordsAndIgnoresRoomNoise() async throws {
        let speech = try spoken("Hey Jarvis, open Mail and check my messages please.")
        var noise = [Int16](repeating: 0, count: Int(rate) * 2)
        var generator = SystemRandomNumberGenerator()
        for i in noise.indices { noise[i] = Int16.random(in: -60...60, using: &generator) }

        let gate = try VoiceActivityGate.silero(sampleRate: rate)
        let stream = noise + speech + noise + noise
        let speechStart = noise.count * 2
        var offset = 0
        var firstUploadAt: Int?
        var uploadedBeforeSpeech = 0
        for start in stride(from: 0, to: stream.count, by: frame) {
            let chunk = Array(stream[start..<min(start + frame, stream.count)])
            let out = audio(try await gate.admit(chunk.withUnsafeBytes { Data($0) }))
            if !out.isEmpty, firstUploadAt == nil { firstUploadAt = offset }
            if offset + chunk.count * 2 <= speechStart { uploadedBeforeSpeech += out.count }
            offset += chunk.count * 2
        }
        XCTAssertEqual(uploadedBeforeSpeech, 0, "two seconds of room noise stay local")
        let firstUpload = try XCTUnwrap(firstUploadAt, "the sentence opens the gate")
        XCTAssertGreaterThanOrEqual(firstUpload, speechStart - frame * 2, "nothing leaves before the speech begins")
        XCTAssertLessThan(firstUpload, speechStart + Int(rate) * 2, "the gate opens within a second of speech")
        let usage = await gate.usage
        let spokenSeconds = Double(speech.count) / rate
        XCTAssertGreaterThan(usage.sentSpeech, spokenSeconds * 0.9, "the sentence is uploaded")
        XCTAssertLessThan(usage.sentSpeech, spokenSeconds + 3.5, "plus at most the pre-roll, scoring lag and end-of-turn wait")
    }

    /// The bench's pause-heavy phrases: a 450 or 500 ms pause mid-sentence
    /// keeps one turn, and the turn ends after the speech does.
    func testSileroKeepsOneTurnAcrossShortPauses() async throws {
        for text in ["open [[slnc 450]] Calculator", "click the [[slnc 500]] Reply button"] {
            let speech = try spoken(text)
            let lead = [Int16](repeating: 0, count: Int(rate) / 2)
            let stream = lead + speech + [Int16](repeating: 0, count: Int(rate) * 2)
            let gate = try VoiceActivityGate.silero(sampleRate: rate)
            var events: [VoiceActivityGate.Event] = []
            var endedAt: Int?
            for start in stride(from: 0, to: stream.count, by: frame) {
                let chunk = Array(stream[start..<min(start + frame, stream.count)])
                let out = try await gate.admit(chunk.withUnsafeBytes { Data($0) })
                if out.contains(.turnEnded), endedAt == nil { endedAt = start + chunk.count }
                events += out
            }
            XCTAssertEqual(events.filter { $0 == .turnStarted || $0 == .turnEnded }, [.turnStarted, .turnEnded], text)
            let speechEnd = lead.count + speech.count
            let ended = try XCTUnwrap(endedAt, text)
            XCTAssertGreaterThan(ended, speechEnd, "\(text): the turn ends after the speech")
            XCTAssertLessThan(ended, speechEnd + Int(rate * 1.6), "\(text): within the end-of-turn wait and scoring lag")
        }
    }

    private func spoken(_ text: String) throws -> [Int16] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vad-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=LEI16@24000", text]
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/say") else { throw XCTSkip("say is unavailable") }
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say could not render speech")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }
}
