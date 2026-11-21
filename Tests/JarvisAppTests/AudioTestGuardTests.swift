import XCTest
@testable import Jarvis

/// Tests never open a CoreAudio device: every RealtimeVoiceLane builds a
/// RealtimePlayer, and a real output engine per test process left coreaudiod
/// running IO for clients that had already gone.
final class AudioTestGuardTests: XCTestCase {
    func testThePlayerPlaysSilentlyWithoutOpeningTheSpeaker() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["JARVIS_LIVE_MIC"] == "1",
                      "A live run opens the real speaker on purpose")
        let player = RealtimePlayer()
        let drained = expectation(description: "the queued audio drains")
        player.onPlaybackIdle = { drained.fulfill() }
        let started = ProcessInfo.processInfo.systemUptime
        player.enqueue(Data(count: 24 * 2 * 200), itemID: "probe")
        await fulfillment(of: [drained], timeout: 10)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.19,
                                    "200 ms of audio takes 200 ms to play")
        XCTAssertTrue(player.playbackIdle)
        XCTAssertFalse(player.opensOutputDevice)
    }

    func testStoppingSilentPlaybackFreesItForTheNextReplyAtOnce() async throws {
        let speaker = SilentPlayback().route
        let next = expectation(description: "the next reply plays")
        speaker.schedule(Data(count: 48_000)) {}
        speaker.play()
        try await Task.sleep(for: .milliseconds(50))
        speaker.stop()
        let started = ProcessInfo.processInfo.systemUptime
        speaker.schedule(Data(count: 4_800)) { next.fulfill() }
        speaker.play()
        await fulfillment(of: [next], timeout: 5)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.6,
                          "a stopped 1 s buffer must not hold back the next 100 ms reply")
    }
}
