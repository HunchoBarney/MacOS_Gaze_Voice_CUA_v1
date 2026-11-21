import XCTest
@testable import Jarvis

final class LiveListeningTests: XCTestCase {
    private func talking(at start: TimeInterval = 0) -> LiveListening {
        var listening = LiveListening(name: "Jarvis")
        XCTAssertEqual(listening.handle(.wake, at: start), [.openSession])
        XCTAssertEqual(listening.state, .connecting)
        XCTAssertEqual(listening.handle(.started, at: start + 1), [])
        XCTAssertEqual(listening.state, .talking)
        return listening
    }

    func testAFalseWakeClosesAfterEightSeconds() {
        var listening = talking()
        XCTAssertEqual(listening.deadline(after: 1), 9)
        XCTAssertEqual(listening.handle(.tick, at: 8.9), [])
        XCTAssertEqual(listening.handle(.tick, at: 9), [.closeSession])
        XCTAssertEqual(listening.state, .asleep)
    }

    func testAConversationStaysOpenNinetySecondsAfterTheLastTurnThroughStandby() {
        var listening = talking()
        _ = listening.handle(.heard("What's the capital of Japan?"), at: 2)
        _ = listening.handle(.answered, at: 3)
        _ = listening.handle(.paused, at: 11)
        XCTAssertEqual(listening.state, .standby)
        XCTAssertEqual(listening.handle(.tick, at: 49), [])
        XCTAssertEqual(listening.handle(.resumed, at: 50), [])
        XCTAssertEqual(listening.state, .talking)
        _ = listening.handle(.heard("And of France?"), at: 50)
        _ = listening.handle(.answered, at: 51)
        XCTAssertEqual(listening.handle(.tick, at: 51), [])
        XCTAssertEqual(listening.deadline(after: 51), 141)
        XCTAssertEqual(listening.handle(.tick, at: 141), [.closeSession])
    }

    func testThatsAllClosesOnceItSettlesAndARequestContainingItDoesNot() {
        var listening = talking()
        _ = listening.handle(.heard("Open Mail, that's all"), at: 2)
        XCTAssertEqual(listening.handle(.tick, at: 2.9), [])
        XCTAssertTrue(listening.sessionOpen)
        _ = listening.handle(.answered, at: 3)
        _ = listening.handle(.heard("Thanks Jarvis, that\u{2019}s all."), at: 5)
        XCTAssertEqual(listening.deadline(after: 5) ?? -1, 5.3, accuracy: 1e-9)
        XCTAssertEqual(listening.handle(.tick, at: 5.3), [])
        XCTAssertEqual(listening.handle(.tick, at: 5.9), [.closeSession])
        XCTAssertEqual(listening.state, .asleep)
    }

    func testStopWaitsForTheWholeUtteranceSoStopTheMusicIsARequest() {
        var listening = talking()
        _ = listening.handle(.heard("Stop"), at: 2)
        _ = listening.handle(.heard(" the music"), at: 2.4)
        XCTAssertEqual(listening.handle(.tick, at: 3.3), [])
        _ = listening.handle(.answered, at: 4)
        _ = listening.handle(.heard("Stop."), at: 6)
        XCTAssertEqual(listening.handle(.answered, at: 6.5), [], "Live answering doesn't settle it early")
        XCTAssertEqual(listening.handle(.tick, at: 6.9), [.control(.stop)])
        XCTAssertTrue(listening.sessionOpen)
    }

    func testABackchannelMidSentenceNeitherSplitsNorSettlesIt() {
        var listening = talking()
        _ = listening.handle(.heard("Stop"), at: 2)
        _ = listening.handle(.answered, at: 2.2)
        _ = listening.handle(.heard(" the music"), at: 2.4)
        XCTAssertEqual(listening.handle(.tick, at: 3.3), [], "\"Stop the music\" is a request")
        _ = listening.handle(.heard("That's"), at: 5)
        _ = listening.handle(.answered, at: 5.2)
        _ = listening.handle(.heard(" all"), at: 5.4)
        XCTAssertEqual(listening.handle(.tick, at: 6.3), [.closeSession])
    }

    func testStayWithMeHoldsUntilTheThirtyMinuteCap() {
        var listening = talking()
        _ = listening.handle(.heard("Stay with me"), at: 2)
        _ = listening.handle(.tick, at: 2.9)
        XCTAssertTrue(listening.held)
        XCTAssertEqual(listening.handle(.tick, at: 200), [])
        XCTAssertEqual(listening.deadline(after: 200), 2 + 30 * 60)
        XCTAssertEqual(listening.handle(.tick, at: 2 + 30 * 60), [.closeSession])
        XCTAssertFalse(listening.held)
    }

    func testThinkingShowsShortlyAfterTheUserStopsAndClearsWhenLiveAnswers() {
        var listening = talking()
        _ = listening.handle(.heard("Open Mail"), at: 2)
        XCTAssertFalse(listening.thinking(at: 2.1))
        XCTAssertEqual(listening.deadline(after: 2.1) ?? -1, 2.3, accuracy: 1e-9)
        XCTAssertTrue(listening.thinking(at: 2.35))
        _ = listening.handle(.delegated, at: 2.5)
        XCTAssertTrue(listening.thinking(at: 2.6))
        _ = listening.handle(.answered, at: 4)
        XCTAssertFalse(listening.thinking(at: 4.5))
    }

    func testPauseClosesAnOpenSessionAndIgnoresWakesUntilResumed() {
        var listening = talking()
        XCTAssertEqual(listening.handle(.pause, at: 3), [.closeSession])
        XCTAssertEqual(listening.handle(.wake, at: 4), [])
        XCTAssertEqual(listening.handle(.resume, at: 5), [])
        XCTAssertEqual(listening.handle(.wake, at: 6), [.openSession])
    }

    func testControlWordsIgnoreFillerAndTheAssistantsName() {
        XCTAssertEqual(LiveControlWord.find(in: "Hey Nova, never mind.", name: "Nova"), .cancel)
        XCTAssertEqual(LiveControlWord.find(in: "Undo that please", name: "Jarvis"), .undo)
        XCTAssertEqual(LiveControlWord.find(in: "Keep listening", name: "Jarvis"), .stayWithMe)
        XCTAssertNil(LiveControlWord.find(in: "Cancel my three o'clock", name: "Jarvis"))
    }
}

final class LiveInputRelayTests: XCTestCase {
    /// 1 kHz, so a 10 ms frame is 10 samples.
    private func relay(maxBehind: Double = 8) -> LiveInputRelay {
        LiveInputRelay(sampleRate: 1000, lead: 0.1, ringSeconds: 2, maxBehind: maxBehind)
    }

    private func write(_ relay: LiveInputRelay, _ samples: [Float], endingAt end: TimeInterval) {
        samples.withUnsafeBufferPointer { relay.write($0, endingAt: end) }
    }

    private func read(_ relay: LiveInputRelay, _ count: Int) -> [Float] {
        var out = [Float](repeating: -1, count: count)
        out.withUnsafeMutableBufferPointer { relay.read(into: $0) }
        return out
    }

    func testTheCaptureStartsJustBeforeTheWakeMomentAndWaitsForTheSession() {
        let relay = relay()
        write(relay, (0..<1000).map { Float($0) / 10_000 + 0.05 }, endingAt: 10)
        relay.capture(since: 9.5)
        XCTAssertEqual(relay.stats.behind, 0.6, accuracy: 0.001)
        XCTAssertEqual(read(relay, 20), [Float](repeating: 0, count: 20), "Silence until the session starts")
        relay.startSending()
        let first = read(relay, 20)
        XCTAssertEqual(first[0], Float(400) / 10_000 + 0.05, accuracy: 1e-6)
    }

    func testCatchingUpSkipsOnlyQuietFrames() {
        let relay = relay()
        write(relay, [Float](repeating: 0, count: 1000), endingAt: 1)
        relay.capture(since: 1)
        let speech = [Float](repeating: 0.2, count: 100)
        let pause = [Float](repeating: 0.0001, count: 300)
        write(relay, speech + pause + speech, endingAt: 1.5)
        relay.startSending()
        var heard: [Float] = []
        for _ in 0..<10 { heard += read(relay, 50) }
        XCTAssertEqual(heard.filter { $0 == 0.2 }.count, 200, "Every speech sample plays")
        XCTAssertGreaterThan(relay.stats.skipped, 0.3)
    }

    func testAShortQueuePlaysSilenceRatherThanCuttingAWord() {
        let relay = relay()
        relay.capture(since: 0)
        relay.startSending()
        write(relay, [Float](repeating: 0.2, count: 30), endingAt: 1)
        XCTAssertEqual(read(relay, 50), [Float](repeating: 0, count: 50))
        write(relay, [Float](repeating: 0.2, count: 30), endingAt: 1.03)
        XCTAssertEqual(read(relay, 50), [Float](repeating: 0.2, count: 50))
    }

    func testFallingTooFarBehindAbandonsTheCaptureAndSaysSo() {
        let relay = relay(maxBehind: 0.5)
        relay.capture(since: 0)
        write(relay, [Float](repeating: 0.2, count: 600), endingAt: 1)
        XCTAssertTrue(relay.stats.overflowed)
        XCTAssertEqual(relay.stats.behind, 0)
        relay.startSending()
        write(relay, [Float](repeating: 0.3, count: 50), endingAt: 1.05)
        XCTAssertEqual(read(relay, 50), [Float](repeating: 0.3, count: 50), "What the user says again still reaches the session")
    }
}
