import XCTest
import JevVoiceCore
@testable import JevVoice

final class AgentFinalMessageTests: XCTestCase {
    func testFinalBlocksParseAndBodyStripsEveryMarker() {
        let text = """
        Here is the report.
        <SUMMARY>Report is in your output folder.</SUMMARY>
        <NEXT_ACTIONS>
        - Trim it to one page
        - Send it to the team
        </NEXT_ACTIONS>
        <DONE_TITLE>Weekly Report</DONE_TITLE>
        <ARTIFACTS>
        - /tmp/ws/output/report.pdf
        </ARTIFACTS>
        <ROUTINE>{"action":"create","every_minutes":60,"task":"sweep"}</ROUTINE>
        """
        let parsed = AgentFinalMessage.parse(text)
        XCTAssertEqual(parsed.body, "Here is the report.")
        XCTAssertEqual(parsed.summary, "Report is in your output folder.")
        XCTAssertEqual(parsed.nextActions, ["Trim it to one page", "Send it to the team"])
        XCTAssertEqual(parsed.doneTitle, "Weekly Report")
        XCTAssertEqual(parsed.artifacts, ["/tmp/ws/output/report.pdf"])
        XCTAssertTrue(parsed.hasStructuredBlocks)
    }

    func testSloppyCloseVariantAndDanglingTagAreStripped() {
        XCTAssertEqual(AgentFinalMessage.parse("done <SUMMARY>ok</>").body, "done")
        XCTAssertEqual(AgentFinalMessage.stripMarkers("half <SUMMARY>cut mid"), "half")
        // A trailing partial tag fragment hides while streaming; "a < B" stays.
        XCTAssertEqual(AgentFinalMessage.stripMarkers("working <SUM"), "working")
        XCTAssertEqual(AgentFinalMessage.stripMarkers("a < B"), "a < B")
    }

    func testComputerUseAsksParseWithoutLeakingIntoBody() {
        let text = "Need input. <COMPUTER_USE_REQUEST>Click Send in Mail?</COMPUTER_USE_REQUEST>"
        let parsed = AgentFinalMessage.parse(text)
        XCTAssertEqual(parsed.computerUseAsks, ["Click Send in Mail?"])
        XCTAssertEqual(parsed.body, "Need input.")
    }
}

@MainActor
final class AgentsViewModelTests: XCTestCase {
    private struct StubRoster: AgentRosterProviding {
        var list: [CompanionAgent]
        func agents() async -> [CompanionAgent] { list }
    }

    private final class StubConsent: ConsentCoordinating, @unchecked Sendable {
        var requests: [ConsentRequest] = []
        var approved: [String] = []
        var denied: [String] = []
        func pending() -> [ConsentRequest] { requests }
        func approve(_ request: ConsentRequest) {
            approved.append(request.id); requests.removeAll { $0.id == request.id }
        }
        func deny(_ request: ConsentRequest) {
            denied.append(request.id); requests.removeAll { $0.id == request.id }
        }
    }

    private func agent() -> CompanionAgent {
        CompanionAgent(slug: "desk", name: "Inbox Desk", role: "Mail Triage",
                       description: "Triage.", workspacePath: "/tmp/ws",
                       codexHomePath: "/tmp/ws/codex-home")
    }

    private func model(consent: StubConsent? = nil) -> AgentsViewModel {
        AgentsViewModel(roster: StubRoster(list: [agent()]), consent: consent)
    }

    func testDeltasAccumulateAndItemCompletionParsesFinalBlocks() {
        let model = model()
        let slug = "desk"
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .turnStarted(threadID: "t", turnID: "u")))
        XCTAssertTrue(model.chat(for: slug).busy)
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .agentMessageDelta(threadID: "t", turnID: "u", itemID: "i", delta: "Hel")))
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .agentMessageDelta(threadID: "t", turnID: "u", itemID: "i", delta: "lo")))
        XCTAssertEqual(model.chat(for: slug).messages.count, 1)
        XCTAssertTrue(model.chat(for: slug).messages[0].streaming)
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .itemCompleted(threadID: "t", turnID: "u", item: .object([
                "id": .string("i"), "type": .string("agentMessage"),
                "text": .string("Hello <DONE_TITLE>Hi There</DONE_TITLE>")]))))
        let message = model.chat(for: slug).messages[0]
        XCTAssertFalse(message.streaming)
        XCTAssertEqual(message.text, "Hello")
        XCTAssertEqual(message.final?.doneTitle, "Hi There")
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .turnCompleted(threadID: "t",
                                  turn: CodexTurnResult(id: "u", status: "completed"))))
        XCTAssertFalse(model.chat(for: slug).busy)
    }

    func testTurnCompletedFinalizesOrphanStreamsAndReportsErrors() {
        let model = model(), slug = "desk"
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .agentMessageDelta(threadID: "t", turnID: "u", itemID: "i",
                                      delta: "partial <SUMMARY>x")))
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .turnCompleted(threadID: "t",
                turn: CodexTurnResult(id: "u", status: "failed", errorMessage: "boom"))))
        let chat = model.chat(for: slug)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertFalse(chat.messages[0].streaming)
        XCTAssertEqual(chat.messages[0].text, "partial")
        XCTAssertEqual(chat.messages[1].role, .note)
        XCTAssertEqual(chat.messages[1].text, "boom")
    }

    func testUserMessageEchoDoesNotDoublePost() async {
        let model = model(), slug = "desk"
        await model.refresh()
        model.send("do it", to: slug)
        // No runtime bound → user echo + a note; a later userMessage item
        // carrying the same text must not append again.
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .itemCompleted(threadID: "t", turnID: "u", item: .object([
                "id": .string("i"), "type": .string("userMessage"),
                "text": .string("do it")]))))
        let users = model.chat(for: slug).messages.filter { $0.role == .user }
        XCTAssertEqual(users.count, 1)
        // Coordinator-originated sends (routines) DO appear.
        model.handle(AgentCodexEvent(agentSlug: slug,
            event: .itemCompleted(threadID: "t", turnID: "v", item: .object([
                "id": .string("j"), "type": .string("userMessage"),
                "text": .string("sweep the inbox")]))))
        XCTAssertEqual(model.chat(for: slug).messages.filter { $0.role == .user }.count, 2)
    }

    func testConsentLifecyclePendingApprovedExpired() {
        let consent = StubConsent()
        let model = model(consent: consent), slug = "desk"
        consent.requests = [ConsentRequest(id: "r1", agentSlug: slug, turnID: "u",
                                           summary: "Click Send?", reason: "click needs approval")]
        model.refreshConsents()
        var card = model.chat(for: slug).consents.first
        XCTAssertEqual(card?.resolution, .pending)
        model.resolve(card!, approved: true)
        XCTAssertEqual(consent.approved, ["r1"])
        model.refreshConsents()
        card = model.chat(for: slug).consents.first
        XCTAssertEqual(card?.resolution, .approved)
        // A pending ask that vanishes unresolved expires.
        consent.requests = [ConsentRequest(id: "r2", agentSlug: slug, turnID: "v",
                                           summary: "Again?", reason: "x")]
        model.refreshConsents()
        consent.requests = []
        model.refreshConsents()
        XCTAssertEqual(model.chat(for: slug).consents.last?.resolution, .expired)
    }

    func testRoutineScheduleLabels() {
        func label(_ minutes: Int) -> String {
            Routine(everyMinutes: minutes, task: "t").scheduleLabel
        }
        XCTAssertEqual(label(5), "Every 5m")
        XCTAssertEqual(label(60), "Hourly")
        XCTAssertEqual(label(1440), "Daily")
        XCTAssertEqual(label(90), "Every 1h 30m")
    }
}
