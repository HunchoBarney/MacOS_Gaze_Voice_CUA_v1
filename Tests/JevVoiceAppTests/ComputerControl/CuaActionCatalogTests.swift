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

    func testNegatedKeyboardRequestIsDetected() {
        XCTAssertTrue(CuaActionCatalog.isExplicitlyNegatedKeyboardRequest(in: "do not press the key \"return\""))
        XCTAssertFalse(CuaActionCatalog.isExplicitlyNegatedKeyboardRequest(in: "press the key \"return\""))
        XCTAssertFalse(CuaActionCatalog.isExplicitlyNegatedKeyboardRequest(in: "open Notes"))
    }
}
