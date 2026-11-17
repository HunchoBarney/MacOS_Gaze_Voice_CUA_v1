import Foundation
import XCTest
@testable import JevVoice
import JevVoiceCore

/// The park+notify file channel: the agent child parks an ask on disk,
/// the app surfaces it, and the answer file resumes the child. A timeout
/// is an honest decline — never a silent approval.
final class AgentAskChannelTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asks-\(UUID().uuidString)", isDirectory: true)
        AgentAskChannel.asksDir = dir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A parked ask is visible to the app and an answer resumes the child.
    func testParkedAskRoundTrips() async throws {
        let request = Task { await AgentAskChannel.request(
            .confirm("Quit Safari?"), agent: "scout", timeout: 10) }
        // The child writes the ask file before it starts polling.
        var pending: [AgentAskChannel.Pending] = []
        for _ in 0..<40 where pending.isEmpty {
            pending = AgentAskChannel.pending()
            if pending.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].agent, "scout")
        XCTAssertEqual(pending[0].kind, "confirm")
        XCTAssertEqual(pending[0].prompt, "Quit Safari?")
        AgentAskChannel.answer(pending[0].id, "yes")
        let answer = await request.value
        XCTAssertEqual(answer, "yes")
        // The child cleans up both files after reading the answer.
        XCTAssertTrue(AgentAskChannel.pending().isEmpty)
    }

    /// An unanswered ask times out to nil — the drive loop declines it.
    func testTimeoutDeclines() async {
        let answer = await AgentAskChannel.request(
            .confirm("Delete everything?"), agent: "scout", timeout: 0.5)
        XCTAssertNil(answer)
        XCTAssertTrue(AgentAskChannel.pending().isEmpty)
    }

    /// A stale ask file past its deadline is swept, not surfaced.
    func testExpiredAskIsNotPending() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale: [String: JSONValue] = [
            "id": .string("old"), "agent": .string("scout"), "kind": .string("confirm"),
            "prompt": .string("Quit Safari?"), "deadline": .number(Date().timeIntervalSince1970 - 10)]
        try JSONEncoder().encode(JSONValue.object(stale))
            .write(to: dir.appendingPathComponent("old.json"))
        XCTAssertTrue(AgentAskChannel.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("old.json").path))
    }

    /// The child writes its own `agent` field — a slug outside the roster
    /// still surfaces (it's a real ask) but flagged untrusted so the
    /// consumer can mark it instead of trusting the claim.
    func testRosterBindingFlagsUnknownSlugs() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (id, slug) in [("known", "scout"), ("rogue", "not-an-agent")] {
            let body: [String: JSONValue] = [
                "id": .string(id), "agent": .string(slug), "kind": .string("confirm"),
                "prompt": .string("Proceed?"),
                "deadline": .number(Date().timeIntervalSince1970 + 60)]
            try JSONEncoder().encode(JSONValue.object(body))
                .write(to: dir.appendingPathComponent("\(id).json"))
        }
        let pending = AgentAskChannel.pending(rosterSlugs: ["scout"])
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.first { $0.id == "known" }?.trusted, true)
        XCTAssertEqual(pending.first { $0.id == "rogue" }?.trusted, false)
        // No roster supplied → no claim either way.
        XCTAssertTrue(AgentAskChannel.pending().allSatisfy(\.trusted))
    }
}
