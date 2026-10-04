import XCTest
@testable import JevVoice

final class CuaActionCatalogTests: XCTestCase {
    func testExplicitNavigationURLAcceptsQuotedAndSpokenForms() {
        XCTAssertEqual(CuaActionCatalog.explicitBrowserNavigationURL(in: "Navigate to \"https://example.invalid/a?q=1\""),
                       "https://example.invalid/a?q=1")
        XCTAssertEqual(CuaActionCatalog.explicitBrowserNavigationURL(in: "go to apple.com"), "https://apple.com")
        XCTAssertEqual(CuaActionCatalog.explicitBrowserNavigationURL(in: "navigate to developer.apple.com/xcode"),
                       "https://developer.apple.com/xcode")
    }

    func testExplicitNavigationURLRefusesAmbiguousOrNegatedRequests() {
        XCTAssertNil(CuaActionCatalog.explicitBrowserNavigationURL(in: "Do not open \"https://example.invalid/a\""))
        XCTAssertNil(CuaActionCatalog.explicitBrowserNavigationURL(in: "Open https://example.invalid/a and click the button"))
        XCTAssertNil(CuaActionCatalog.explicitBrowserNavigationURL(in: "Open https://example.invalid/a in a new tab"))
        XCTAssertNil(CuaActionCatalog.explicitBrowserNavigationURL(in: "open the thing"))
    }

    func testSearchNavigationURLRequiresANamedEngineAndPayload() {
        XCTAssertEqual(CuaActionCatalog.searchNavigationURL(in: "search google for the weather", payload: "the weather"),
                       "https://www.google.com/search?q=the%20weather")
        XCTAssertEqual(CuaActionCatalog.searchNavigationURL(in: "bing for flights", payload: "flights"),
                       "https://www.bing.com/search?q=flights")
        XCTAssertNil(CuaActionCatalog.searchNavigationURL(in: "search for the weather", payload: "the weather"))
        XCTAssertNil(CuaActionCatalog.searchNavigationURL(in: "search google", payload: nil))
    }

    func testNegatedKeyboardRequestIsDetected() {
        XCTAssertTrue(CuaActionCatalog.isExplicitlyNegatedKeyboardRequest(in: "do not press the key \"return\""))
        XCTAssertFalse(CuaActionCatalog.isExplicitlyNegatedKeyboardRequest(in: "press the key \"return\""))
        XCTAssertFalse(CuaActionCatalog.isExplicitlyNegatedKeyboardRequest(in: "open Notes"))
    }
}
