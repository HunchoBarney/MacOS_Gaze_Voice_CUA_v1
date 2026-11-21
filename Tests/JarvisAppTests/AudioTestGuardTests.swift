import XCTest
@testable import Jarvis

/// Tests never open a CoreAudio device: every RealtimeVoiceLane builds a
/// RealtimePlayer, and a real output engine per test process left coreaudiod
/// running IO for clients that had already gone.
final class AudioTestGuardTests: XCTestCase {
    func testThePlayerPlaysSilentlyWithoutOpeningTheSpeaker() async throws {
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
}
