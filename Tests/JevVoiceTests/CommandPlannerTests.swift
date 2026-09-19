import XCTest
@testable import JevVoiceCore

final class CommandPlannerTests: XCTestCase {
    func testExplicitUnsupportedSearchURLDoesNotUseGoogle() {
        XCTAssertThrowsError(try CommandPlanner.plan([
            .init(decision: Decision(clause: "search github.com for private issue", action: .webSearch,
                url: "https://github.com", query: "private issue", confidence: 0.99)),
        ], frontmostApp: "Safari"))
    }

    func testBrowserContextSurvivesSystemStepWithoutReordering() throws {
        let steps = try CommandPlanner.plan([
            .init(decision: Decision(clause: "open Safari", action: .openApp, targetApp: "Safari", confidence: 0.99)),
            .init(decision: Decision(clause: "mute", action: .system, systemAction: .mute, confidence: 0.99)),
            .init(decision: Decision(clause: "open Google", action: .openURL, url: SearchSite.google.homepage, confidence: 0.99), context: .previous),
        ], frontmostApp: "Finder")
        XCTAssertEqual(steps.map(\.action), [.openApp, .system, .openURL])
        XCTAssertEqual(steps.last?.targetApp, "Safari")
    }

    func testSystemThenDictationUsesTheOriginalFrontmostApp() throws {
        let steps = try CommandPlanner.plan([
            .init(decision: Decision(clause: "mute", action: .system, systemAction: .mute, confidence: 1)),
            .init(decision: Decision(clause: "type hello", action: .dictate, text: "hello", confidence: 1), context: .previous),
        ], frontmostApp: "Notes")
        XCTAssertEqual(steps.last?.targetApp, "Notes")
    }

    func testUncertainIndependentContextRequiresConfirmationToo() throws {
        let steps = try CommandPlanner.plan([
            .init(decision: Decision(clause: "search for cats", action: .webSearch, query: "cats", confidence: 0.99), context: .independent, contextConfidence: 0.2),
        ], frontmostApp: "Notes")
        XCTAssertEqual(steps.first?.confidence, 0.2)
    }

    func testSystemStepDoesNotEraseAppContextOrGetReordered() throws {
        let steps = try CommandPlanner.plan([
            .init(decision: Decision(clause: "open Notes", action: .openApp, targetApp: "Notes", confidence: 0.99)),
            .init(decision: Decision(clause: "mute", action: .system, systemAction: .mute, confidence: 0.99)),
            .init(decision: Decision(clause: "type hello", action: .dictate, text: "hello", confidence: 1), context: .previous),
        ], frontmostApp: "Finder")
        XCTAssertEqual(steps.map(\.action), [.openApp, .system, .dictate])
        XCTAssertEqual(steps.last?.targetApp, "Notes")
    }

    func testSpecializedWebsiteIsNotSilentlySearchedWithAnotherProduct() {
        XCTAssertThrowsError(try CommandPlanner.plan([
            .init(decision: Decision(clause: "open Google Maps", action: .openURL, url: "https://www.google.com/maps", confidence: 1)),
            .init(decision: Decision(clause: "search for cafes", action: .webSearch, query: "cafes", confidence: 1), context: .previous),
        ], frontmostApp: "Finder"))
    }

    func testBrowserLaunchAndDestinationAreOneActionAcrossBrowsers() throws {
        for browser in ["Safari", "Google Chrome", "Firefox"] {
            let steps = try CommandPlanner.plan([
                .init(decision: Decision(clause: "open \(browser)", action: .openApp, targetApp: browser, confidence: 0.95)),
                .init(decision: Decision(clause: "go to example.com", action: .openURL, url: "https://example.com", confidence: 0.99), context: .previous),
            ], frontmostApp: "Finder")
            XCTAssertEqual(steps.map(\.action), [.openURL])
            XCTAssertEqual(steps.first?.targetApp, browser)
            XCTAssertEqual(steps.first?.url, "https://example.com")
            XCTAssertEqual(steps.first?.confidence, 0.95)
        }
    }

    func testSiteSearchContinuesInEachSupportedSiteWithOneNavigation() throws {
        for site in SearchSite.allCases {
            let steps = try CommandPlanner.plan([
                .init(decision: Decision(clause: "open \(site.rawValue)", action: .openURL, url: site.homepage, confidence: 1)),
                .init(decision: Decision(clause: "search for cats", action: .webSearch, query: "cats", confidence: 0.99), context: .previous),
            ], frontmostApp: "Finder")
            XCTAssertEqual(steps.map(\.action), [.webSearch])
            XCTAssertEqual(steps.first?.searchSite, site)
            XCTAssertEqual(steps.first?.query, "cats")
        }
    }

    func testOpenAppThenDictateKeepsOrderedStepsAndPinsTheApp() throws {
        for app in ["Notes", "TextEdit"] {
            let steps = try CommandPlanner.plan([
                .init(decision: Decision(clause: "open \(app)", action: .openApp, targetApp: app, confidence: 0.95)),
                .init(decision: Decision(clause: "type hello and quit Safari", action: .dictate, text: "hello and quit Safari", confidence: 1), context: .previous),
            ], frontmostApp: "Finder")
            XCTAssertEqual(steps.map(\.action), [.openApp, .dictate])
            XCTAssertEqual(steps.last?.targetApp, app)
            XCTAssertEqual(steps.last?.text, "hello and quit Safari")
        }
    }

    func testPreviousReferenceDoesNotUseOriginalFrontmostApp() throws {
        let steps = try CommandPlanner.plan([
            .init(decision: Decision(clause: "open Notes", action: .openApp, targetApp: "Notes", confidence: 0.99)),
            .init(decision: Decision(clause: "minimize it", action: .minimizeApp, targetApp: "Finder", confidence: 0.99), context: .previous),
        ], frontmostApp: "Finder")
        XCTAssertEqual(steps.last?.targetApp, "Notes")
    }

    func testExplicitSeparateTabsArePreserved() throws {
        let steps = try CommandPlanner.plan([
            .init(decision: Decision(clause: "open YouTube", action: .openURL, url: SearchSite.youtube.homepage, confidence: 1)),
            .init(decision: Decision(clause: "search in another tab", action: .webSearch, query: "cats", confidence: 0.99), context: .previousSeparate),
        ], frontmostApp: "Finder")
        XCTAssertEqual(steps.map(\.action), [.openURL, .webSearch])
        XCTAssertEqual(steps.last?.searchSite, .youtube)
    }

    func testNativeAppSearchIsNotSilentlySentToGoogle() {
        XCTAssertThrowsError(try CommandPlanner.plan([
            .init(decision: Decision(clause: "open Notes", action: .openApp, targetApp: "Notes", confidence: 0.99)),
            .init(decision: Decision(clause: "search for private note", action: .webSearch, query: "private note", confidence: 0.99), context: .previous),
        ], frontmostApp: "Finder")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Searching inside Notes"))
        }
    }

    func testUnrelatedExplicitTargetIsNotOverwritten() throws {
        let steps = try CommandPlanner.plan([
            .init(decision: Decision(clause: "open Safari", action: .openApp, targetApp: "Safari", confidence: 0.99)),
            .init(decision: Decision(clause: "search in Firefox", action: .webSearch, targetApp: "Firefox", query: "cats", confidence: 0.99)),
        ], frontmostApp: "Finder")
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.last?.targetApp, "Firefox")
    }

    func testMissingWebsiteFailsBeforeAnyPlanIsReturned() {
        XCTAssertThrowsError(try CommandPlanner.plan([
            .init(decision: Decision(clause: "open unknown", action: .openURL, confidence: 0.99)),
            .init(decision: Decision(clause: "search for cats", action: .webSearch, query: "cats", confidence: 0.99)),
        ], frontmostApp: "Finder"))
    }

    func testQueriesAreEncodedAsOneParameter() {
        for site in SearchSite.allCases {
            let query = "cats & dogs # kittens? café"
            let url = site.searchURL(query: query)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.count, 1)
            XCTAssertEqual(items?.first?.value, query)
            XCTAssertNil(url.fragment)
        }
    }
}
