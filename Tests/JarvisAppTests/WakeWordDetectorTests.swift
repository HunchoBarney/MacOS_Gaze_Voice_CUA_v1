import AVFoundation
import XCTest
@testable import Jarvis

final class WakeWordDetectorTests: XCTestCase {
    func testTypedNamesBecomeModelWords() {
        XCTAssertEqual(WakePhraseSpotter.words("  Jarvis "), ["jarvis"])
        XCTAssertEqual(WakePhraseSpotter.words("Mary-Jane O'Neil"), ["mary", "jane", "o'neil"])
        XCTAssertEqual(WakePhraseSpotter.words("R2!"), ["r"])
        XCTAssertEqual(WakePhraseSpotter.words(" 42 "), [])
    }

    func testRivalsAreOtherFirstNames() {
        let rivals = WakePhraseSpotter.rivals(excluding: ["jake"])
        XCTAssertTrue(rivals.contains("jack"))
        XCTAssertFalse(rivals.contains("jake"))
        XCTAssertTrue(rivals.allSatisfy { $0 == $0.lowercased() && $0.allSatisfy(\.isLetter) })
    }

    func testHearsTheWakePhraseOnceAndNothingElse() throws {
        let spotter = try WakePhraseSpotter(name: "Jarvis", vosk: try engine())
        XCTAssertEqual(try wakes(spotter, "Open Mail and check the weather for tomorrow."), 0, "ordinary speech")
        XCTAssertEqual(try wakes(spotter, "Jarvis, open Mail."), 0, "the name without hey")
        XCTAssertEqual(try wakes(spotter, "Hey Jarvis, open Mail."), 1, "the wake phrase")
        XCTAssertEqual(try wakes(spotter, "What's the weather like? Hey Jarvis."), 1, "the wake phrase after other words")
    }

    func testTheNameIsTheUsersChoice() throws {
        let spotter = try WakePhraseSpotter(name: "Nova", vosk: try engine())
        XCTAssertEqual(try wakes(spotter, "Hey Jarvis, open Mail."), 0, "the default name no longer wakes it")
        XCTAssertEqual(try wakes(spotter, "Hey Nova, open Mail."), 1)
    }

    func testAResetForgetsAPhraseStillBeingConfirmed() throws {
        let phrase = try spoken("What's the weather like? Hey Jarvis.") + [Int16](repeating: 0, count: 8_000)
        func wakesOnSilence(_ spotter: WakePhraseSpotter) -> Int {
            (0..<20).filter { _ in spotter.accept([Int16](repeating: 0, count: 1_600)) }.count
        }
        func confirming(_ spotter: WakePhraseSpotter) {
            for start in stride(from: 0, to: phrase.count, by: 1_600) where !spotter.confirming {
                XCTAssertFalse(spotter.accept(Array(phrase[start..<min(start + 1_600, phrase.count)])))
            }
        }
        let kept = try WakePhraseSpotter(name: "Jarvis", vosk: try engine())
        confirming(kept)
        XCTAssertTrue(kept.confirming)
        XCTAssertEqual(wakesOnSilence(kept), 1, "without a reset the old phrase still wakes")
        let reset = try WakePhraseSpotter(name: "Jarvis", vosk: try engine())
        confirming(reset)
        XCTAssertTrue(reset.confirming)
        reset.reset()
        XCTAssertFalse(reset.confirming)
        XCTAssertEqual(wakesOnSilence(reset), 0)
    }

    func testANameTheModelCantHearIsRefused() throws {
        XCTAssertThrowsError(try WakePhraseSpotter(name: "Karanvir", vosk: try engine()))
        XCTAssertNoThrow(try WakePhraseSpotter(name: "Jarvis", vosk: try engine()))
    }

    private func engine() throws -> Vosk {
        guard Vosk.directory() != nil else { throw XCTSkip("Vosk isn't fetched: run ThirdParty/Vosk/fetch.sh") }
        return try Vosk.shared()
    }

    private func wakes(_ spotter: WakePhraseSpotter, _ text: String) throws -> Int {
        let audio = try spoken(text) + [Int16](repeating: 0, count: 32_000)
        let chunk = 1_600
        return stride(from: 0, to: audio.count, by: chunk).filter {
            spotter.accept(Array(audio[$0..<min($0 + chunk, audio.count)]))
        }.count
    }

    private func spoken(_ text: String) throws -> [Int16] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wake-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=LEI16@16000", text]
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
