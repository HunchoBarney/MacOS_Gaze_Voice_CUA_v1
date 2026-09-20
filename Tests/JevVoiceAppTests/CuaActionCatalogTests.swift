import XCTest
import JevVoiceCore
@testable import JevVoice

final class CuaActionCatalogTests: XCTestCase {
    func testSubmenuChoicesExtendOnlyTheObservedUnambiguousPath() {
        let listing: JSONValue = .object(["status": .string("listed"), "resolved_path": .array([.string("Format")]),
            "items": .array([
                .object(["title": .string("Font"), "has_submenu": .bool(true)]),
                .object(["title": .string("Disabled"), "has_submenu": .bool(false), "enabled": .bool(false)]),
                .object(["title": .string("Duplicate"), "has_submenu": .bool(false)]),
                .object(["title": .string("Duplicate"), "has_submenu": .bool(false)])])])
        let choices = CuaActionCatalog.submenu(listing, pid: 12, window: 34)
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices.first?.arguments["path"], .array([.string("Format"), .string("Font")]))
        XCTAssertEqual(choices.first?.arguments["window_id"], .number(34))
        XCTAssertTrue(CuaActionCatalog.submenu(.object(["status": .string("dispatched")]), pid: 12, window: 34).isEmpty)
    }
    func testSecondaryAndCustomActionsKeepTheirObservedTargetAndEnvelope() {
        let raw = "Name:Move Down\nTarget:0x123\nSelector:moveDown:"
        let element: JSONValue = .object([
            "role": .string("AXCell"), "label": .string("Fixture item"), "element_token": .string("bound-cell"),
            "actions": .array([.string("AXShowMenu"), .string("AXPick")]),
            "custom_actions": .array([.object(["name": .string("Move Down"), "raw": .string(raw)])])
        ])
        let actions = CuaActionCatalog.native(elements: [element], pid: 12, window: 34)
        XCTAssertEqual(Set(actions.compactMap { $0.arguments["action"]?.string }), ["show_menu", "pick", raw])
        XCTAssertTrue(actions.allSatisfy { $0.arguments["element_token"] == .string("bound-cell")
            && $0.arguments["window_id"] == .number(34) && $0.arguments["delivery_mode"] == .string("background") })
        var disabled = element.object!
        disabled["enabled"] = .bool(false)
        XCTAssertTrue(CuaActionCatalog.native(elements: [.object(disabled)], pid: 12, window: 34).isEmpty)
        disabled.removeValue(forKey: "enabled")
        disabled.removeValue(forKey: "element_token")
        XCTAssertTrue(CuaActionCatalog.native(elements: [.object(disabled)], pid: 12, window: 34).isEmpty)
    }
    func testEmbeddedAppButtonsAreAvailableWithoutTrustingWebTextInsertion() {
        let elements: [JSONValue] = [
            .object(["element_index": .number(1), "role": .string("AXWebArea")]),
            .object(["element_index": .number(2), "parent_index": .number(1), "role": .string("AXButton"), "label": .string("Search"), "element_token": .string("button"), "actions": .array([.string("AXPress")])]),
            .object(["element_index": .number(3), "parent_index": .number(1), "role": .string("AXComboBox"), "label": .string("Search query"), "element_token": .string("field")])
        ]
        XCTAssertTrue(CuaActionCatalog.native(elements: elements, pid: 12, window: 34).isEmpty)
        let embedded = CuaActionCatalog.native(elements: elements, pid: 12, window: 34, includeEmbeddedWebControls: true)
        XCTAssertEqual(embedded.map(\.tool), ["click"])
        XCTAssertEqual(embedded.first?.arguments["element_token"], .string("button"))
        XCTAssertEqual(embedded.first?.arguments["window_id"], .number(34))
    }
    func testMenuPathsComeFromObservedAncestryAndDisabledItemsAreExcluded() {
        let elements: [JSONValue] = [
            .object(["element_index": .number(0), "role": .string("AXMenuBarItem"), "label": .string("File")]),
            .object(["element_index": .number(1), "parent_index": .number(0), "role": .string("AXMenu")]),
            .object(["element_index": .number(2), "parent_index": .number(1), "role": .string("AXMenuItem"), "label": .string("New"), "enabled": .bool(true)]),
            .object(["element_index": .number(3), "parent_index": .number(1), "role": .string("AXMenuItem"), "label": .string("Disabled"), "enabled": .bool(false)])
        ]
        let actions = CuaActionCatalog.native(elements: elements, pid: 12, window: 34)
        XCTAssertTrue(actions.contains { $0.arguments["path"] == .array([.string("File"), .string("New")]) })
        XCTAssertFalse(actions.contains { $0.description.contains("Disabled") })
    }
    func testFieldActionRequiresBoundTokenAndNeverBuildsWholeValueReplacement() {
        let fields: [JSONValue] = [.object(["role": .string("AXTextArea"), "label": .string("Body"), "element_token": .string("observed-token")])]
        let actions = CuaActionCatalog.native(elements: fields, pid: 12, window: 34)
        XCTAssertTrue(actions.contains { $0.tool == "type_text" && $0.arguments["element_token"] == .string("observed-token") })
        XCTAssertFalse(actions.contains { $0.tool == "set_value" })
    }
}
