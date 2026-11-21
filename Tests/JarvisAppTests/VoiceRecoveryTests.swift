import Foundation
import XCTest
@testable import Jarvis

/// Records what the player hands a playback route and plays buffers back
/// only when the test says so.
private final class RecordedRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [(bytes: Int, played: @Sendable () -> Void)] = []
    private var plays = 0
    private var stops = 0
    var ready = true

    var route: VoicePlaybackRoute {
        VoicePlaybackRoute(id: UUID(), isReady: { [unowned self] in self.lock.withLock { self.ready } },
                           schedule: { [unowned self] data, played in
                               self.lock.withLock { self.buffers.append((data.count, played)) }
                           },
                           play: { [unowned self] in self.lock.withLock { self.plays += 1 } },
                           stop: { [unowned self] in self.lock.withLock { self.stops += 1 } })
    }
    var scheduled: [Int] { lock.withLock { buffers.map(\.bytes) } }
    var playCount: Int { lock.withLock { plays } }
    var stopCount: Int { lock.withLock { stops } }
    func play(_ index: Int) { lock.withLock { buffers[index].played }() }
}

final class VoiceRecoveryTests: XCTestCase {
    private let tenthOfASecond = 4_800

    private func waitFor(_ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let until = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < until {
            if check() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition timed out", file: file, line: line)
    }

    private func makePlayer(on recorded: RecordedRoute) -> RealtimePlayer {
        let player = RealtimePlayer()
        player.setPlaybackRoute(recorded.route)
        return player
    }

    // MARK: Wake session

    func testAFalseWakeClosesAfterTheQuietTime() {
        var clock = WakeSessionClock(opened: 0, timings: VoiceTimings())
        XCTAssertFalse(clock.shouldClose(busy: false, replying: false, now: 7.9))
        XCTAssertTrue(clock.shouldClose(busy: false, replying: false, now: 8))
    }

    func testEachReplyOpensANinetySecondFollowUpWindow() {
        var clock = WakeSessionClock(opened: 0, timings: VoiceTimings())
        XCTAssertFalse(clock.shouldClose(busy: true, replying: false, now: 2))
        XCTAssertFalse(clock.shouldClose(busy: true, replying: true, now: 5))
        XCTAssertFalse(clock.shouldClose(busy: false, replying: false, now: 10))
        XCTAssertFalse(clock.shouldClose(busy: false, replying: false, now: 60), "a reply keeps it open past the quiet time")
        XCTAssertFalse(clock.shouldClose(busy: false, replying: false, now: 99.9))
        XCTAssertTrue(clock.shouldClose(busy: false, replying: false, now: 100))
    }

    func testSpeechWithoutAReplyDoesNotRefreshTheWindow() {
        var clock = WakeSessionClock(opened: 0, timings: VoiceTimings())
        _ = clock.shouldClose(busy: true, replying: true, now: 5)
        _ = clock.shouldClose(busy: false, replying: false, now: 10)
        XCTAssertFalse(clock.shouldClose(busy: true, replying: false, now: 95), "someone talks, Jarvis says nothing")
        XCTAssertFalse(clock.shouldClose(busy: false, replying: false, now: 102.9))
        XCTAssertTrue(clock.shouldClose(busy: false, replying: false, now: 103),
                      "the window still ends 90 s after the reply, plus the quiet time after the speech")
    }

    func testANewReplyRestartsTheWindow() {
        var clock = WakeSessionClock(opened: 0, timings: VoiceTimings())
        _ = clock.shouldClose(busy: true, replying: true, now: 5)
        _ = clock.shouldClose(busy: false, replying: false, now: 10)
        _ = clock.shouldClose(busy: true, replying: true, now: 70)
        _ = clock.shouldClose(busy: false, replying: false, now: 80)
        XCTAssertFalse(clock.shouldClose(busy: false, replying: false, now: 169.9))
        XCTAssertTrue(clock.shouldClose(busy: false, replying: false, now: 170))
    }

    func testNoWakeSessionOutlivesThirtyMinutes() {
        var clock = WakeSessionClock(opened: 0, timings: VoiceTimings())
        var now: TimeInterval = 0
        while now < 30 * 60 {
            XCTAssertFalse(clock.shouldClose(busy: true, replying: true, now: now + 1))
            XCTAssertFalse(clock.shouldClose(busy: false, replying: false, now: now + 5))
            now += 60
        }
        XCTAssertFalse(clock.shouldClose(busy: true, replying: false, now: 30 * 60 + 1), "a turn in progress finishes")
        XCTAssertTrue(clock.shouldClose(busy: false, replying: false, now: 30 * 60 + 2),
                      "past the cap the next idle moment closes it, however recent the last reply")
    }

    // MARK: RealtimePlayer

    func testTheReplyDrainsOnlyOnceEveryScheduledBufferHasPlayed() async {
        let recorded = RecordedRoute()
        let player = makePlayer(on: recorded)
        let idle = Counter()
        player.onPlaybackIdle = { idle.add() }

        player.enqueue(Data(count: tenthOfASecond), itemID: "reply")
        player.enqueue(Data(count: tenthOfASecond), itemID: "reply")
        await waitFor { recorded.scheduled.count == 2 }
        XCTAssertFalse(player.playbackIdle)
        recorded.play(0)
        XCTAssertFalse(player.playbackIdle, "half the reply is still ahead of the speaker")
        XCTAssertEqual(idle.value, 0)
        recorded.play(1)
        XCTAssertTrue(player.playbackIdle)
        XCTAssertEqual(idle.value, 1)
    }

    func testPlaybackStartsOnceTheJitterBufferFillsAndShortRepliesStillPlay() async {
        let full = RecordedRoute()
        let fullPlayer = makePlayer(on: full)
        fullPlayer.enqueue(Data(count: 6_000), itemID: "long")
        await waitFor { full.playCount == 1 }

        let short = RecordedRoute()
        let shortPlayer = makePlayer(on: short)
        shortPlayer.enqueue(Data(count: 960), itemID: "short")
        await waitFor { short.scheduled.count == 1 }
        await waitFor { short.playCount == 1 }
    }

    func testABargeInReportsWhatWasHeardAndDropsTheRestOfThatItem() async {
        let recorded = RecordedRoute()
        let player = makePlayer(on: recorded)
        for _ in 0..<3 { player.enqueue(Data(count: tenthOfASecond), itemID: "heard") }
        await waitFor { recorded.scheduled.count == 3 }
        recorded.play(0)

        let interrupted = player.interrupt()
        XCTAssertEqual(interrupted.itemID, "heard")
        XCTAssertEqual(interrupted.playedMs, 100, "truncation names exactly what reached the speaker")
        await waitFor { recorded.stopCount == 1 }

        player.enqueue(Data(count: tenthOfASecond), itemID: "heard")
        player.enqueue(Data(count: 2_400), itemID: "next")
        await waitFor { recorded.scheduled.count == 4 }
        XCTAssertEqual(recorded.scheduled.last, 2_400, "late audio for the interrupted item is dropped")

        recorded.play(1)
        recorded.play(2)
        XCTAssertFalse(player.playbackIdle, "buffers from before the barge-in can't drain the new reply")
        recorded.play(3)
        XCTAssertTrue(player.playbackIdle)
    }

    func testACancelledResponseDropsEveryItemUntilItsDone() async {
        let recorded = RecordedRoute()
        let player = makePlayer(on: recorded)
        player.enqueue(Data(count: tenthOfASecond), itemID: "cancelled")
        await waitFor { recorded.scheduled.count == 1 }

        player.interrupt(untilResponseDone: true)
        player.enqueue(Data(count: 2_400), itemID: "unseen-item-of-the-same-response")
        player.responseDidFinish()
        player.enqueue(Data(count: 960), itemID: "next-response")
        await waitFor { recorded.scheduled.count == 2 }
        XCTAssertEqual(recorded.scheduled, [tenthOfASecond, 960])
    }

    func testAnUnreadyRouteReportsPlaybackUnavailableAndSchedulesNothing() async {
        let recorded = RecordedRoute()
        recorded.ready = false
        let player = makePlayer(on: recorded)
        let unavailable = Counter()
        player.onPlaybackUnavailable = { unavailable.add() }

        player.enqueue(Data(count: tenthOfASecond), itemID: "reply")
        await waitFor { unavailable.value == 1 }
        XCTAssertTrue(recorded.scheduled.isEmpty)
        XCTAssertTrue(player.playbackIdle)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
