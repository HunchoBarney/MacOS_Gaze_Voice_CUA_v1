import XCTest
import JevVoiceCore

final class JevPayloadLiveTests: XCTestCase {
    /// Model-only probe: no desktop actions; source text is disposable.
    func testUnquotedQueryOptIn() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_JEV_PAYLOAD_TEST"] == "1" else {
            throw XCTSkip("Opt-in real Jev payload selection")
        }
        let key = try CuaLiveCredential.jev()
        var calls = 0
        let model = JevSpeechIntent(evaluate: { state, questions in
            calls += 1
            let answers = try await JevClient(apiKey: key).systemOne(state: state, questions: questions).response.answers
            print("Disposable payload decision:", answers)
            return answers
        })
        let cases = [
            ("In Google Chrome in the background, search this local site for copper lantern, then open the Copper Lantern Guide result.", "Insert supplied text into page textbox Search query", "copper lantern"),
            ("Search this site for river stone, then open the guide.", "Insert supplied text into page textbox Search query", "river stone"),
            ("In Chrome, search for exactly \"copper lantern\", then open the guide.", "Insert supplied text into page textbox Search query", "copper lantern"),
            ("Type Hello! including the exclamation mark into the greeting field.", "Insert supplied text into page textbox Greeting", "Hello!"),
            ("Type stop all into the note field.", "Insert supplied text into page textbox Note", "stop all")
        ]
        for (request, purpose, expected) in cases {
            do {
                let text = try await model.textPayload(request: request, purpose: purpose)
                XCTAssertEqual(text, expected, request)
            } catch {
                XCTFail("Payload refused for \(request): \(error)")
            }
        }
        print("Payload model calls:", calls)
    }
}
