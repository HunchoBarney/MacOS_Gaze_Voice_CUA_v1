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
            .object(["ref": .string("p1:0"), "role": .string("textbox"), "name": .string("Draft"), "actions": .array([.string("type")]), "visibility": .string("in_viewport"), "frame": .string("main")]),
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
    func testBrowserTextEffectIdentitySurvivesReferenceReorderingButBindingDoesNot() throws {
        func action(ref: String) throws -> CuaObservedAction {
            let snapshot: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab"), "refs": .array([
                .object(["ref": .string(ref), "role": .string("textbox"), "name": .string("Search query"),
                         "actions": .array([.string("type")]), "visibility": .string("in_viewport"), "frame": .string("main")])])])
            return try XCTUnwrap(CuaActionCatalog.browser(snapshot: snapshot).first { $0.tool == "browser_type" })
        }
        let before = try action(ref: "p1:0")
        let after = try action(ref: "p2:1")
        XCTAssertEqual(before.effectIdentity, after.effectIdentity)
        XCTAssertNotEqual(before.bindingIdentity, after.bindingIdentity)
        XCTAssertNotEqual(before.arguments["ref"], after.arguments["ref"])
    }

    @MainActor
    func testBrowserTextReadbackRebindsOnlyToOneSameSemanticControl() throws {
        let original: JSONValue = .object(["ref": .string("p1:0"), "role": .string("textbox"),
            "name": .string("Search query"), "value": .string("copper "), "frame": .string("main"),
            "actions": .array([.string("type")]), "visibility": .string("in_viewport"),
            "states": .object(["editable": .string("plaintext")])])
        let updated: JSONValue = .object(["ref": .string("p2:1"), "role": .string("textbox"),
            "name": .string("Search query"), "value": .string("copper lantern"), "frame": .string("main"),
            "actions": .array([.string("type")]), "visibility": .string("in_viewport"),
            "states": .object(["editable": .string("plaintext")])])
        let unique: JSONValue = .object(["refs": .array([updated])])
        XCTAssertEqual(CuaBrowserTarget.uniqueTextTarget(matching: original, in: unique), updated)

        let duplicate: JSONValue = .object(["refs": .array([updated, .object(["ref": .string("p2:2"),
            "role": .string("textbox"), "name": .string("Search query"), "value": .string("other"),
            "frame": .string("main"), "actions": .array([.string("type")]), "visibility": .string("in_viewport"),
            "states": .object(["editable": .string("plaintext")])])])])
        XCTAssertNil(CuaBrowserTarget.uniqueTextTarget(matching: original, in: duplicate))
    }

    func testAmbiguousBrowserTextControlsAreNotOfferedAsInsertTargets() {
        let field = { (ref: String) in JSONValue.object(["ref": .string(ref), "role": .string("textbox"),
            "name": .string("Search query"), "actions": .array([.string("type")]),
            "visibility": .string("in_viewport"), "frame": .string("main")]) }
        let snapshot: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab"),
            "refs": .array([field("p1:0"), field("p1:1")])])

        XCTAssertTrue(CuaActionCatalog.browser(snapshot: snapshot).filter { $0.tool == "browser_type" }.isEmpty)
    }

    func testPointerChoicesRequireVisibleEnabledAdvertisedRefAndKeepExactBinding() {
        let snapshot: JSONValue = .object(["target_id": .string("target-1"), "tab_id": .string("tab-2"), "refs": .array([
            .object(["ref": .string("live"), "role": .string("button"), "name": .string("Canvas control"), "actions": .array([.string("pointer")]), "visibility": .string("in_viewport")]),
            .object(["ref": .string("disabled"), "role": .string("button"), "actions": .array([.string("pointer")]), "states": .object(["disabled": .bool(true)]), "visibility": .string("in_viewport")]),
            .object(["ref": .string("hidden"), "role": .string("button"), "actions": .array([.string("pointer")]), "visibility": .string("css_hidden")]),
            .object(["ref": .string("no-pointer"), "role": .string("button"), "actions": .array([.string("click")]), "visibility": .string("in_viewport")])
        ])])
        let choices = CuaActionCatalog.browser(snapshot: snapshot, surface: .candidate).filter { $0.tool == "browser_pointer" }
        XCTAssertEqual(Set(choices.compactMap { $0.arguments["action"]?.string }), ["hover", "right_click", "double_click"])
        XCTAssertTrue(choices.allSatisfy { $0.arguments["target_id"] == .string("target-1")
            && $0.arguments["tab_id"] == .string("tab-2")
            && $0.arguments["ref"] == .string("live")
            && $0.arguments["input_route"] == .string("dom_event") })
    }

    func testContentRefsAreActionableAndConflictingDuplicateRefsAreRejected() {
        let pointerRef: JSONValue = .object(["ref": .string("p1:4"), "role": .string("link"),
            "name": .string("Pointer target"), "actions": .array([.string("pointer")]),
            "visibility": .string("in_viewport"), "frame": .string("main")])
        let snapshot: JSONValue = .object(["target_id": .string("target-1"), "tab_id": .string("tab-2"),
            "content_refs": .array([pointerRef])])
        let actions = CuaActionCatalog.browser(snapshot: snapshot, surface: .candidate)
        XCTAssertEqual(actions.filter { $0.tool == "browser_pointer" }.count, 3)
        XCTAssertTrue(actions.allSatisfy { $0.arguments["ref"] == .string("p1:4") })

        let conflicting: JSONValue = .object(["target_id": .string("target-1"), "tab_id": .string("tab-2"),
            "content_refs": .array([pointerRef]),
            "refs": .array([.object(["ref": .string("p1:4"), "role": .string("button"),
                "name": .string("Different target"), "actions": .array([.string("pointer")]),
                "visibility": .string("in_viewport"), "frame": .string("main")])])])
        XCTAssertTrue(CuaActionCatalog.browser(snapshot: conflicting, surface: .candidate).isEmpty,
                      "Conflicting observations of one opaque ref cannot become a target choice.")
    }
}
