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

    /// Runs `body`, or gives up after `seconds` so a missed wake fails
    /// instead of hanging the run.
    private func within<T: Sendable>(_ seconds: Int, _ body: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// A file landing in asks/ wakes the stream. The heartbeat is an hour,
    /// so any wake inside the run came from the directory watch.
    func testAFileLandingWakesTheWatchNotTheHeartbeat() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stream = AgentAskChannel.changes(safetyInterval: .seconds(3600))
        try await Task.sleep(for: .milliseconds(100)) // let the watch arm
        let body: [String: JSONValue] = [
            "id": .string("probe"), "agent": .string("scout"),
            "kind": .string("confirm"), "prompt": .string("Go?"),
            "deadline": .number(Date().timeIntervalSince1970 + 60)]
        try JSONEncoder().encode(JSONValue.object(body))
            .write(to: dir.appendingPathComponent("probe.json"))
        let woke = await within(30) {
            var it = stream.makeAsyncIterator()
            _ = await it.next()                    // immediate first yield
            return await it.next() != nil          // the watch wake
        }
        XCTAssertEqual(woke, true, "only the directory watch can wake the stream before the heartbeat")
    }

    /// The child side keeps its round-trip: the host's `.answer` write
    /// fires the watch inside `request`. With an hour-long heartbeat, only
    /// the watch can bring the answer back.
    func testRequestWakesOnAnswerWrite() async throws {
        let request = Task { await AgentAskChannel.request(
            .confirm("Quit Safari?"), agent: "scout", timeout: 10, safetyInterval: .seconds(3600)) }
        var pending: [AgentAskChannel.Pending] = []
        for _ in 0..<40 where pending.isEmpty {
            pending = AgentAskChannel.pending()
            if pending.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertEqual(pending.count, 1)
        AgentAskChannel.answer(pending[0].id, "yes")
        let answer = await within(30) { await request.value } ?? nil
        request.cancel()
        XCTAssertEqual(answer, "yes", "only the directory watch can deliver the answer before the heartbeat")
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
