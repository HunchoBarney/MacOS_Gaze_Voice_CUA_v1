import Foundation
import XCTest
@testable import Jarvis
import JarvisCore

/// Contract: `AgentAskChannel.changes()` wakes on the asks dir itself —
/// a 10s safety interval means any sub-second yield came from the vnode
/// watch, never the poll. Same public API: `pending()`/`answer()`/
/// `discard()`/`request()` behave exactly as the poll did.
final class ConsentAskWatchTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("askswatch-\(UUID().uuidString)", isDirectory: true)
        AgentAskChannel.asksDir = dir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A file landing in asks/ wakes the stream in well under 200ms —
    /// with the heartbeat set to 10s, only the directory watch can fire.
    func testWatchFiresUnder200ms() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stream = AgentAskChannel.changes(safetyInterval: .seconds(10))
        let elapsed = Task { () -> TimeInterval in
            var it = stream.makeAsyncIterator()
            _ = await it.next()                    // immediate first yield
            let start = Date()
            _ = await it.next()                    // the watch wake
            return Date().timeIntervalSince(start)
        }
        try await Task.sleep(for: .milliseconds(100)) // let the watch arm
        let body: [String: JSONValue] = [
            "id": .string("probe"), "agent": .string("scout"),
            "kind": .string("confirm"), "prompt": .string("Go?"),
            "deadline": .number(Date().timeIntervalSince1970 + 60)]
        try JSONEncoder().encode(JSONValue.object(body))
            .write(to: dir.appendingPathComponent("probe.json"))
        let seconds = await elapsed.value
        XCTAssertLessThan(seconds, 0.2,
                          "directory watch must wake well under the heartbeat")
    }

    /// The child side keeps its round-trip: the host's `.answer` write
    /// fires the watch inside `request` and the answer comes back fast —
    /// the same contract the 300ms poll had, minus the sleep.
    func testRequestWakesOnAnswerWrite() async throws {
        let request = Task { await AgentAskChannel.request(
            .confirm("Quit Safari?"), agent: "scout", timeout: 10) }
        var pending: [AgentAskChannel.Pending] = []
        for _ in 0..<40 where pending.isEmpty {
            pending = AgentAskChannel.pending()
            if pending.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertEqual(pending.count, 1)
        let start = Date()
        AgentAskChannel.answer(pending[0].id, "yes")
        let answer = await request.value
        XCTAssertEqual(answer, "yes")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5,
                          "watch wake should beat the old 300ms poll")
        XCTAssertTrue(AgentAskChannel.pending().isEmpty)
    }

    /// Timeout is still the honest decline — a watch never invents an
    /// answer.
    func testTimeoutStillDeclines() async {
        let answer = await AgentAskChannel.request(
            .confirm("Delete everything?"), agent: "scout", timeout: 0.5)
        XCTAssertNil(answer)
        XCTAssertTrue(AgentAskChannel.pending().isEmpty)
    }
}
