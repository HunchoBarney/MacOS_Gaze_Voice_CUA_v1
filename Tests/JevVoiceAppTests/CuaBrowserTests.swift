import XCTest
import JevVoiceCore
@testable import JevVoice

final class CuaBrowserTests: XCTestCase {
    @MainActor
    func testOnlyExplicitNonBrowserRefusalSelectsNativeRoute() async throws {
        let native = try await CuaBrowserTarget.discover(pid: 42, window: 7, call: { _, _ in
            throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_route_unavailable")
        })
        XCTAssertNil(native)
        do {
            _ = try await CuaBrowserTarget.discover(pid: 42, window: 7, call: { _, _ in
                throw DriverConnectionError.toolRefused(tool: "get_browser_state", code: "browser_consent_required")
            })
            XCTFail("Consent refusal must not fall back to native web input")
        } catch {
            XCTAssertEqual(error as? DriverConnectionError, .toolRefused(tool: "get_browser_state", code: "browser_consent_required"))
        }
    }
    @MainActor
    func testBrowserIdentityIgnoresRefRevisionButDetectsContentAndFrameChanges() {
        func snapshot(ref: String, value: String = "draft", frame: String = "main") -> JSONValue {
            .object(["page": .object(["url": .string("http://127.0.0.1/")]), "refs": .array([
                .object(["ref": .string(ref), "role": .string("textbox"), "name": .string("Draft"), "value": .string(value), "frame": .string(frame)])])])
        }
        XCTAssertEqual(CuaBrowserTarget.identity(snapshot(ref: "p1:0")), CuaBrowserTarget.identity(snapshot(ref: "p2:0")))
        XCTAssertNotEqual(CuaBrowserTarget.identity(snapshot(ref: "p1:0")), CuaBrowserTarget.identity(snapshot(ref: "p2:0", value: "user edit")))
        XCTAssertNotEqual(CuaBrowserTarget.identity(snapshot(ref: "p1:0")), CuaBrowserTarget.identity(snapshot(ref: "p2:0", frame: "child")))
    }
    @MainActor
    func testBindingRefusesAmbiguousTabsAndHeuristicTargets() async throws {
        for exact in [false, true] {
            do {
                _ = try await CuaBrowserTarget.bind(pid: 42, window: 7, call: { _, _ in
                    .object(["binding_quality": .string(exact ? "exact" : "heuristic"), "mutation_allowed": .bool(exact), "target_id": .string("bt1"), "tabs": .array([
                        .object(["tab_id": .string("tab1")]), .object(["tab_id": .string("tab2")])])])
                })
                XCTFail("Accepted unbound browser target")
            } catch { XCTAssertTrue(error is DriverConnectionError) }
        }
    }
    func testBrowserActionsUseOnlyObservedCapabilitiesAndExactBinding() {
        let snapshot: JSONValue = .object(["target_id": .string("bt1"), "tab_id": .string("tab1"), "refs": .array([
            .object(["ref": .string("p1:0"), "role": .string("textbox"), "name": .string("Draft"), "actions": .array([.string("type")]), "visibility": .string("in_viewport")]),
            .object(["ref": .string("p1:1"), "role": .string("button"), "name": .string("Send"), "actions": .array([.string("click")]), "visibility": .string("near_viewport")]),
            .object(["ref": .string("p1:2"), "role": .string("button"), "name": .string("Hidden"), "actions": .array([.string("click")]), "visibility": .string("css_hidden")])])])
        let actions = CuaActionCatalog.browser(snapshot: snapshot)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.map(\.tool), ["browser_type", "browser_click"])
        XCTAssertTrue(actions.allSatisfy { $0.arguments["target_id"] == .string("bt1") && $0.arguments["tab_id"] == .string("tab1") })
        XCTAssertEqual(actions[0].arguments["replace"], .bool(false))
        XCTAssertTrue(actions[0].requiresText)
        XCTAssertFalse(actions[1].requiresText)
        XCTAssertTrue(CuaActionCatalog.browser(snapshot: .object([:])).isEmpty)
    }
}
