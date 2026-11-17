import Foundation
import XCTest
@testable import JevVoice
import JevVoiceCore

/// The chat transcript is bounded — long sessions prune oldest rows
/// instead of growing forever.
@MainActor
final class AgentsModelTests: XCTestCase {
    private final class StubRoster: AgentRosterProviding {
        let list: [CompanionAgent]
        init(_ list: [CompanionAgent]) { self.list = list }
        func agents() async -> [CompanionAgent] { list }
    }

    private func agent(_ slug: String) -> CompanionAgent {
        CompanionAgent(slug: slug, name: slug, role: "r", description: "d",
                       workspacePath: "/tmp/\(slug)",
                       codexHomePath: "/tmp/\(slug)/codex-home")
    }

    func testTranscriptIsCapped() async {
        let model = AgentsViewModel(roster: StubRoster([agent("a")]))
        await model.refresh()
        // No runtime bound → each send appends a user row plus a note row.
        for i in 0..<600 { model.send("message \(i)", to: "a") }
        let chat = model.chat(for: "a")
        XCTAssertEqual(chat.messages.count, AgentsViewModel.messageCap)
        XCTAssertTrue(chat.messages.contains { $0.text == "message 599" },
                      "pruning drops oldest, keeps newest")
        XCTAssertFalse(chat.messages.contains { $0.text == "message 0" })
    }

    func testStreamingIndexRebasedAcrossPrune() async {
        let model = AgentsViewModel(roster: StubRoster([agent("a")]))
        await model.refresh()
        // Drive appends through the event path so streaming anchors exist:
        // a delta creates a streaming row, then enough notes to evict it.
        model.handle(AgentCodexEvent(agentSlug: "a", event:
            .agentMessageDelta(threadID: "t", turnID: "turn-1",
                               itemID: "item-1", delta: "partial")))
        model.handle(AgentCodexEvent(agentSlug: "a", event:
            .error(message: "boom", willRetry: false, threadID: "t", turnID: "turn-1")))
        for _ in 0..<AgentsViewModel.messageCap + 10 {
            model.handle(AgentCodexEvent(agentSlug: "a", event:
                .error(message: "x", willRetry: false, threadID: "t", turnID: nil)))
        }
        let chat = model.chat(for: "a")
        XCTAssertEqual(chat.messages.count, AgentsViewModel.messageCap)
        XCTAssertTrue(chat.streamingItems.isEmpty,
                      "an evicted streaming row must drop its index, not re-anchor")
    }
}
