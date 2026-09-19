import Foundation
import XCTest
@testable import JevVoiceCore

final class CommandInterpreterTests: XCTestCase {
    func testExplicitAppNavigationWorksOfflineWithoutModelConfidenceGate() async throws {
        let (interpreter, session) = makeInterpreter(response: "reject", installedApps: ["Messages", "Calculator", "Google Chrome"])
        defer { session.invalidateAndCancel() }
        for (phrase, app, action) in [
            ("Open Messages.", "Messages", Action.openApp),
            ("open the Messages app", "Messages", .openApp),
            ("could you please launch Calculator", "Calculator", .openApp),
            ("switch to Chrome please", "Google Chrome", .switchApp),
        ] {
            let decisions = try await interpreter.interpret(transcript: phrase, frontmostApp: "Finder")
            XCTAssertEqual(decisions.count, 1)
            XCTAssertEqual(decisions.first?.action, action)
            XCTAssertEqual(decisions.first?.targetApp, app)
            XCTAssertEqual(decisions.first?.confidence, 1)
            XCTAssertEqual(decisions.first?.model, "local-app-navigation")
        }
    }

    func testExplicitAppThenLiteralDictationKeepsContextOffline() async throws {
        let (interpreter, session) = makeInterpreter(response: "reject")
        defer { session.invalidateAndCancel() }
        let decisions = try await interpreter.interpret(transcript: "open Notes and type hello and quit Safari", frontmostApp: "Finder")
        XCTAssertEqual(decisions.map(\.action), [.openApp, .dictate])
        XCTAssertEqual(decisions.map(\.targetApp), ["Notes", "Notes"])
        XCTAssertEqual(decisions.last?.text, "hello and quit Safari")
    }

    func testConditionalRequestCannotRunAnIsolatedLocalClause() async throws {
        let (interpreter, session) = makeInterpreter(response: "none")
        defer { session.invalidateAndCancel() }
        for phrase in ["When I get home, open Safari and open Notes", "open Notes and open Safari tomorrow"] {
            let decisions = try await interpreter.interpret(transcript: phrase, frontmostApp: "Finder")
            XCTAssertTrue(decisions.allSatisfy { $0.action == .none }, phrase)
        }
    }

    func testNamedUnsupportedSearchDestinationStopsInsteadOfDefaultingToGoogle() async throws {
        let (interpreter, session) = makeInterpreter(response: "unsupportedSearch")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await interpreter.interpret(transcript: "search eBay for shoes", frontmostApp: "Safari")
            XCTFail("Unsupported search destination must be explained before execution")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't supported"))
        }
    }

    func testKnownHomepageNavigationDoesNotNeedTheModel() async throws {
        let (interpreter, session) = makeInterpreter(response: "reject")
        defer { session.invalidateAndCancel() }
        let decisions = try await interpreter.interpret(transcript: "Open Google.", frontmostApp: "Finder")
        XCTAssertEqual(decisions.first?.action, .openURL)
        XCTAssertEqual(decisions.first?.url, "https://www.google.com")
        XCTAssertEqual(decisions.first?.confidence, 1)
    }

    func testInstalledAppsAreIncludedInTheActualAPIChoices() async throws {
        let (interpreter, session) = makeInterpreter(response: "validateCandidates")
        defer { session.invalidateAndCancel() }
        let decisions = try await interpreter.interpret(transcript: "I need to use Notes", frontmostApp: "Finder")
        XCTAssertEqual(decisions.first?.targetApp, "Notes")
    }

    func testUncertainSystemActionRetainsConfidenceForDiagnostics() async throws {
        let (interpreter, session) = makeInterpreter(response: "uncertainSystem")
        defer { session.invalidateAndCancel() }
        let decisions = try await interpreter.interpret(transcript: "increase volume", frontmostApp: "Finder")
        XCTAssertEqual(decisions.first?.action, .system)
        XCTAssertEqual(decisions.first?.confidence, 0.2)
    }

    func testAmbiguousLocalAppMatchDoesNotReplaceConfidentModelChoice() async throws {
        let (interpreter, session) = makeInterpreter(
            response: "googleApp", installedApps: ["Google Chrome", "Google Drive"]
        )
        defer { session.invalidateAndCancel() }
        let decisions = try await interpreter.interpret(transcript: "launch Google", frontmostApp: "Finder")
        XCTAssertEqual(decisions.first?.action, .openApp)
        XCTAssertEqual(decisions.first?.targetApp, "Google Chrome")
        XCTAssertEqual(decisions.first?.confidence, 0.99)
    }

    func testOpenGoogleThenSearchHasExecutableSlotsAndIgnoresUnusedSystemConfidence() async throws {
        let (interpreter, session) = makeInterpreter(response: "googleSearch")
        defer { session.invalidateAndCancel() }
        for query in ["cats", "the weather in yuba city"] {
            let decisions = try await interpreter.interpret(
                transcript: "open google and search for \(query)", frontmostApp: "Finder"
            )
            XCTAssertEqual(decisions.map(\.action), [.webSearch])
            XCTAssertEqual(decisions.first?.query, query)
            XCTAssertEqual(decisions.first?.clause, "open google and search for \(query)")
            XCTAssertTrue(decisions.allSatisfy { $0.confidence >= 0.7 })
        }
    }

    func testOpeningAnUnrelatedWebsiteBeforeSearchingStillOpensBoth() async throws {
        let (interpreter, session) = makeInterpreter(response: "independentSearch")
        defer { session.invalidateAndCancel() }
        for website in ["github.com", "google.com/maps", "google.com/search?q=dogs"] {
            let decisions = try await interpreter.interpret(
                transcript: "open \(website) and search for cats", frontmostApp: "Finder"
            )
            XCTAssertEqual(decisions.map(\.action), [.openURL, .webSearch], website)
        }
    }

    func testExplicitDictationDoesNotConsultTheModel() async throws {
        let (interpreter, session) = makeInterpreter(response: "reject")
        defer { session.invalidateAndCancel() }

        for (transcript, expectedText) in [
            ("type hello and close Notes", "hello and close Notes"),
            ("write hello then launch Terminal", "hello then launch Terminal"),
            ("dictate hello and lock the screen", "hello and lock the screen"),
            ("say hello and quit Safari", "hello and quit Safari"),
            ("could you please type “open Notes” then close Safari", "“open Notes” then close Safari"),
            ("please, type hello then close Notes", "hello then close Notes"),
            ("could you please, write hello and lock the screen", "hello and lock the screen"),
        ] {
            let decisions = try await interpreter.interpret(transcript: transcript, frontmostApp: "Notes")
            XCTAssertEqual(decisions.map(\.action), [.dictate], transcript)
            XCTAssertEqual(decisions.first?.text, expectedText, transcript)
            XCTAssertEqual(decisions.first?.targetApp, "Notes")
            XCTAssertNil(decisions.first?.systemAction)
            XCTAssertNil(decisions.first?.url)
        }
    }

    func testEmptyDictationDoesNothingWithoutConsultingTheModel() async throws {
        let (interpreter, session) = makeInterpreter(response: "reject")
        defer { session.invalidateAndCancel() }

        for transcript in ["type", "please write ", "dictate", "say", "could you please type"] {
            let decisions = try await interpreter.interpret(transcript: transcript, frontmostApp: "Notes")
            XCTAssertEqual(decisions.map(\.action), [.none], transcript)
            XCTAssertNil(decisions.first?.text)
        }
    }

    func testExplicitWantAndWouldLikeDictationPreservesLiteralSuffixOffline() async throws {
        let (interpreter, session) = makeInterpreter(response: "reject")
        defer { session.invalidateAndCancel() }

        for prefix in ["I want you to type", "I want you to please write", "I would like you to dictate", "I would like you to please say", "I'd like you to type", "I’d like you to please write"] {
            let transcript = "\(prefix) hello and quit Safari"
            let decisions = try await interpreter.interpret(transcript: transcript, frontmostApp: "Notes")
            XCTAssertEqual(decisions.map(\.action), [.dictate], transcript)
            XCTAssertEqual(decisions.first?.text, "hello and quit Safari", transcript)
        }
    }

    func testModelCannotReinterpretExplicitLiteralTextAsAnAction() async throws {
        let (interpreter, session) = makeInterpreter(response: "closeApp")
        defer { session.invalidateAndCancel() }
        let decisions = try await interpreter.interpret(
            transcript: "please type close Notes", frontmostApp: "Notes"
        )
        XCTAssertEqual(decisions.map(\.action), [.dictate])
        XCTAssertEqual(decisions.first?.text, "close Notes")
        XCTAssertEqual(decisions.first?.targetApp, "Notes")
        XCTAssertNil(decisions.first?.systemAction)
    }

    func testCommandThenDictationReturnsOnlyTheRequestedCommandAndLiteralSuffix() async throws {
        let (interpreter, session) = makeInterpreter(response: "openApp")
        defer { session.invalidateAndCancel() }
        let decisions = try await interpreter.interpret(
            transcript: "open Notes then type hello and close Safari", frontmostApp: "Finder"
        )
        XCTAssertEqual(decisions.map(\.action), [.openApp, .dictate])
        XCTAssertEqual(decisions.first?.targetApp, "Notes")
        XCTAssertEqual(decisions.last?.text, "hello and close Safari")
    }

    func testModelSelectedDictationWithoutLiteralBoundaryAsksForExplicitPrefix() async throws {
        let (interpreter, session) = makeInterpreter(response: "dictate")
        defer { session.invalidateAndCancel() }
        for transcript in ["I need to use Notes", "enter hello"] {
            do {
                _ = try await interpreter.interpret(transcript: transcript, frontmostApp: "Finder")
                XCTFail("Dictation without a safe literal boundary must not produce an executable decision: \(transcript)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("start"))
                for prefix in ["type", "write", "dictate", "say"] {
                    XCTAssertTrue(error.localizedDescription.contains(prefix))
                }
            }
        }
    }

    private func makeInterpreter(
        response: String, installedApps: [String] = ["Notes", "Safari", "Terminal"]
    ) -> (CommandInterpreter, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterpreterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = JevClient(
            apiKey: "test-key",
            baseURL: URL(string: "https://interpreter.test/\(response)")!,
            session: session
        )
        return (CommandInterpreter(client: client, installedApps: installedApps), session)
    }
}

private final class InterpreterURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scenario = request.url!.lastPathComponent
        var action = scenario
        guard action != "reject" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if scenario == "validateCandidates" {
            let questions = payload?["questions"] as? [String: Any]
            let target = questions?["target_app"] as? [String: Any]
            let criteria = target?["criteria"] as? [String: Any]
            guard Set(criteria?.keys.map { $0 } ?? []) == Set(["none", "Notes", "Safari", "Terminal"]),
                  criteria?["Notes"] is NSNull else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            action = "openApp"
        }
        if scenario == "googleSearch" || scenario == "independentSearch" {
            let state = payload?["state"] as? [String: Any]
            action = (state?["clause"] as? String)?.hasPrefix("open") == true ? "openURL" : "webSearch"
        }
        if scenario == "uncertainSystem" { action = "system" }
        if scenario == "unsupportedSearch" { action = "webSearch" }
        if scenario == "googleApp" { action = "openApp" }
        let targetApp = scenario == "googleApp" ? "Google Chrome" :
            (action == "dictate" || ["googleSearch", "independentSearch"].contains(scenario) ? "none" : "Notes")
        let systemConfidence = ["googleSearch", "uncertainSystem"].contains(scenario) ? 0.2 : 0.99
        let systemAction = scenario == "uncertainSystem" ? "volumeUp" : "none"
        let state = payload?["state"] as? [String: Any]
        let context = scenario == "googleSearch" && (state?["clause_index"] as? Int ?? 0) > 0 ? "previous" : "independent"
        let searchSite = scenario == "unsupportedSearch" ? "unsupported" : "none"
        let response = """
        {
          "model": "test-model",
          "answers": {
            "action": {"type": "choice", "choice": "\(action)", "confidence": 0.99, "probabilities": {"\(action)": 0.99, "none": 0.01}},
            "target_app": {"type": "choice", "choice": "\(targetApp)", "confidence": 0.99, "probabilities": {"\(targetApp)": 0.99}},
            "system_action": {"type": "choice", "choice": "\(systemAction)", "confidence": \(systemConfidence), "probabilities": {"\(systemAction)": \(systemConfidence)}},
            "target_context": {"type": "choice", "choice": "\(context)", "confidence": 0.99, "probabilities": {"\(context)": 0.99}},
            "search_site": {"type": "choice", "choice": "\(searchSite)", "confidence": 0.99, "probabilities": {"\(searchSite)": 0.99}}
          },
          "usage": {"input_tokens": 10, "output_tokens": 10}
        }
        """
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
