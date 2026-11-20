import AVFoundation
import XCTest
@testable import Jarvis

/// Contract: hands-free uploads microphone audio only while local speech
/// detection hears someone, starting a second before the speech and ending
/// with silence (not room audio) once the speaker stops.
final class VoiceActivityGateTests: XCTestCase {
    private let rate = 24_000.0
    private let frame = 2_400

    /// A loud buffer scores as speech, a quiet one as silence.
    private func gate(_ tuning: VoiceActivityGate.Tuning = .init()) throws -> VoiceActivityGate {
        try VoiceActivityGate(sampleRate: rate, tuning: tuning) { chunk in
            chunk.map { $0 * $0 }.reduce(0, +) / Float(chunk.count) > 0.01 ? 0.9 : 0.05
        }
    }

    private func buffer(loud: Bool, seed: Int16 = 0) -> Data {
        let samples = (0..<frame).map { i -> Int16 in
            loud ? Int16(8_000 * sin(Double(i) * 0.2)) &+ seed : (i % 2 == 0 ? 3 : -3)
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func isSilence(_ data: Data) -> Bool { data.allSatisfy { $0 == 0 } }

    func testRoomAudioStaysOnTheMac() async throws {
        let gate = try gate()
        for _ in 0..<50 { let sent = try await gate.admit(buffer(loud: false)); XCTAssertTrue(sent.isEmpty) }
        let usage = await gate.usage
        XCTAssertEqual(usage.heard, 5, accuracy: 0.01)
        XCTAssertEqual(usage.sentSpeech, 0)
        XCTAssertEqual(usage.sentSilence, 0)
    }

    func testSpeechUploadsWithTheSecondBeforeIt() async throws {
        let gate = try gate()
        var quiet: [Data] = []
        for i in 0..<30 {
            let data = buffer(loud: false, seed: Int16(i))
            quiet.append(data)
            _ = try await gate.admit(data)
        }
        var sent: [Data] = []
        var speech: [Data] = []
        for i in 0..<10 {
            let data = buffer(loud: true, seed: Int16(i))
            speech.append(data)
            sent += try await gate.admit(data)
        }
        XCTAssertFalse(sent.isEmpty, "speech must open the gate")
        XCTAssertFalse(sent.contains(where: isSilence))
        XCTAssertEqual(Array(sent.suffix(speech.count)), speech, "every speech buffer is uploaded, in order")
        let lead = sent.dropLast(speech.count)
        XCTAssertGreaterThanOrEqual(lead.count, 10, "at least a second of audio from before the speech")
        XCTAssertLessThanOrEqual(lead.count, 16, "and no more than the pre-roll plus the scoring lag")
        XCTAssertEqual(Array(lead), Array(quiet.suffix(lead.count)))
    }

    func testAfterSpeechTheTailIsSilenceAndTheServiceCanEndIt() async throws {
        let gate = try gate(.init(preRoll: 0.5, hangover: 0.5, silenceTail: 3))
        for _ in 0..<10 { _ = try await gate.admit(buffer(loud: true)) }
        var after: [Data] = []
        for _ in 0..<20 { after += try await gate.admit(buffer(loud: false)) }
        XCTAssertFalse(after.isEmpty)
        let realAfterSpeech = after.prefix { !isSilence($0) }.count
        XCTAssertLessThanOrEqual(realAfterSpeech, 10, "real room audio stops shortly after the speaker does")
        XCTAssertTrue(after.dropFirst(realAfterSpeech).allSatisfy(isSilence))
        XCTAssertTrue(isSilence(after.last!))
        await gate.speechServiceHeardStop()
        for _ in 0..<5 { let sent = try await gate.admit(buffer(loud: false)); XCTAssertTrue(sent.isEmpty) }
    }

    func testTheSilenceTailEndsOnItsOwn() async throws {
        let gate = try gate(.init(hangover: 0.3, silenceTail: 1))
        for _ in 0..<10 { _ = try await gate.admit(buffer(loud: true)) }
        var trailing = 0
        for _ in 0..<60 { trailing += try await gate.admit(buffer(loud: false)).count }
        XCTAssertLessThanOrEqual(trailing, 6 + 3 + 10, "hangover, decision lag and a one-second tail")
        let usage = await gate.usage
        XCTAssertEqual(usage.sentSilence, 1, accuracy: 0.11)
    }

    func testServiceStopDuringHangoverSkipsTheTail() async throws {
        let gate = try gate(.init(hangover: 0.5, silenceTail: 3))
        for _ in 0..<10 { _ = try await gate.admit(buffer(loud: true)) }
        await gate.speechServiceHeardStop()
        var after: [Data] = []
        for _ in 0..<40 { after += try await gate.admit(buffer(loud: false)) }
        XCTAssertFalse(after.contains(where: isSilence))
        let usage = await gate.usage
        XCTAssertEqual(usage.sentSilence, 0)
    }

    func testSpeechDuringTheTailReopensWithRealAudio() async throws {
        let gate = try gate(.init(hangover: 0.3, silenceTail: 3))
        for _ in 0..<10 { _ = try await gate.admit(buffer(loud: true)) }
        for _ in 0..<15 { _ = try await gate.admit(buffer(loud: false)) }
        var resumed: [Data] = []
        for i in 0..<6 { resumed += try await gate.admit(buffer(loud: true, seed: Int16(100 + i))) }
        XCTAssertTrue(resumed.contains(buffer(loud: true, seed: 105)))
    }

    // MARK: - The shipped Silero model

    func testSileroHearsSpokenWordsAndIgnoresRoomNoise() async throws {
        let speech = try spoken("Hey Jarvis, open Mail and check my messages please.")
        var noise = [Int16](repeating: 0, count: Int(rate) * 2)
        var generator = SystemRandomNumberGenerator()
        for i in noise.indices { noise[i] = Int16.random(in: -60...60, using: &generator) }

        let gate = try VoiceActivityGate.silero(sampleRate: rate)
        var sent: [Data] = []
        let stream = noise + speech + noise + noise
        let speechStart = noise.count * 2
        var offset = 0
        var firstUploadAt: Int?
        var uploadedBeforeSpeech = 0
        for start in stride(from: 0, to: stream.count, by: frame) {
            let chunk = Array(stream[start..<min(start + frame, stream.count)])
            let out = try await gate.admit(chunk.withUnsafeBytes { Data($0) })
            if !out.isEmpty, firstUploadAt == nil { firstUploadAt = offset }
            if offset + chunk.count * 2 <= speechStart { uploadedBeforeSpeech += out.count }
            sent += out
            offset += chunk.count * 2
        }
        XCTAssertEqual(uploadedBeforeSpeech, 0, "two seconds of room noise stay local")
        let usage = await gate.usage
        let spokenSeconds = Double(speech.count) / rate
        XCTAssertGreaterThan(usage.sentSpeech, spokenSeconds * 0.9, "the sentence is uploaded")
        XCTAssertLessThan(usage.sentSpeech, spokenSeconds + 3.5, "plus at most the pre-roll, scoring lag and hangover")
        let firstRealBytes = sent.first { !isSilence($0) }
        XCTAssertNotNil(firstRealBytes)
    }

    private func spoken(_ text: String) throws -> [Int16] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vad-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=LEI16@24000", text]
        guard (try? say.run()) != nil else { throw XCTSkip("say is unavailable") }
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw XCTSkip("say could not render speech") }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    }
}
