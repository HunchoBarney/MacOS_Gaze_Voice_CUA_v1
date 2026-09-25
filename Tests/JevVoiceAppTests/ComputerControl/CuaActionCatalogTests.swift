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

    func testExpandedBrowserPointerActionsStayBehindCandidateSurface() {
        let snapshot: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab"), "refs": .array([
            .object(["ref": .string("p1:0"), "role": .string("button"), "name": .string("Canvas"),
                     "actions": .array([.string("pointer")]), "visibility": .string("in_viewport")])
        ])])

        let production = CuaActionCatalog.browser(snapshot: snapshot)
        let candidate = CuaActionCatalog.browser(snapshot: snapshot, surface: .candidate)

        XCTAssertFalse(production.contains { $0.tool == "browser_pointer" })
        XCTAssertEqual(Set(candidate.compactMap { $0.arguments["action"]?.string }), ["hover", "right_click", "double_click"])
        XCTAssertTrue(candidate.allSatisfy {
            $0.arguments["target_id"] == .string("target") && $0.arguments["tab_id"] == .string("tab")
                && $0.arguments["ref"] == .string("p1:0")
        })
    }

    func testBrowserNavigationAndDragBindExactUserAndObservedTargets() {
        let snapshot: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab"), "refs": .array([
            .object(["ref": .string("p1:0"), "role": .string("button"), "name": .string("Start"),
                     "actions": .array([.string("pointer")]), "visibility": .string("in_viewport"), "frame": .string("main")]),
            .object(["ref": .string("p1:1"), "role": .string("button"), "name": .string("Finish"),
                     "actions": .array([.string("pointer")]), "visibility": .string("in_viewport"), "frame": .string("main")])
        ])])

        let navigation = CuaActionCatalog.browser(snapshot: snapshot, goal: "Open \"https://example.invalid/a?q=1\"", surface: .candidate)
        let navigate = try! XCTUnwrap(navigation.first { $0.tool == "browser_navigate" })
        XCTAssertEqual(navigate.arguments["target_id"], .string("target"))
        XCTAssertEqual(navigate.arguments["tab_id"], .string("tab"))
        XCTAssertEqual(navigate.arguments["url"], .string("https://example.invalid/a?q=1"))
        XCTAssertTrue(CuaActionCatalog.browser(snapshot: snapshot, goal: "Do not open \"https://example.invalid/a\"", surface: .candidate).allSatisfy { $0.tool != "browser_navigate" })
        XCTAssertTrue(CuaActionCatalog.browser(snapshot: snapshot, goal: "Open https://example.invalid/a", surface: .candidate).allSatisfy { $0.tool != "browser_navigate" })

        let drag = CuaActionCatalog.browser(snapshot: snapshot, goal: "Drag \"Start\" to \"Finish\".", surface: .candidate).first { $0.arguments["action"] == .string("drag") }
        XCTAssertEqual(drag?.tool, "browser_pointer")
        XCTAssertEqual(drag?.arguments["ref"], .string("p1:0"))
        XCTAssertEqual(drag?.arguments["destination_ref"], .string("p1:1"))
        XCTAssertEqual(drag?.arguments["input_route"], .string("dom_event"))
        XCTAssertEqual(CuaActionCatalog.browser(snapshot: snapshot,
                         goal: "In Google Chrome in the background, drag \"Start\" to \"Finish\".",
                         surface: .candidate).first { $0.arguments["action"] == .string("drag") }?.arguments["destination_ref"], .string("p1:1"))
        let refreshed: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab"), "refs": .array([
            .object(["ref": .string("p2:0"), "role": .string("button"), "name": .string("Start"),
                     "actions": .array([.string("pointer")]), "visibility": .string("in_viewport"), "frame": .string("main")]),
            .object(["ref": .string("p2:1"), "role": .string("button"), "name": .string("Finish"),
                     "actions": .array([.string("pointer")]), "visibility": .string("in_viewport"), "frame": .string("main")])
        ])])
        let rebound = CuaActionCatalog.browser(snapshot: refreshed, goal: "Drag \"Start\" to \"Finish\".", surface: .candidate).first { $0.arguments["action"] == .string("drag") }
        XCTAssertEqual(rebound?.bindingIdentity, drag?.bindingIdentity, "A fresh snapshot may retire both refs while retaining one exact semantic pair")
        XCTAssertEqual(rebound?.arguments["destination_ref"], .string("p2:1"))

        let ambiguous = JSONValue.object(["target_id": .string("target"), "tab_id": .string("tab"), "refs": .array([
            .object(["ref": .string("p1:0"), "role": .string("button"), "name": .string("Start"), "actions": .array([.string("pointer")]), "visibility": .string("in_viewport"), "frame": .string("main")]),
            .object(["ref": .string("p1:1"), "role": .string("button"), "name": .string("Finish"), "actions": .array([.string("pointer")]), "visibility": .string("in_viewport"), "frame": .string("main")]),
            .object(["ref": .string("p1:2"), "role": .string("button"), "name": .string("Finish"), "actions": .array([.string("pointer")]), "visibility": .string("in_viewport"), "frame": .string("main")])
        ])])
        XCTAssertTrue(CuaActionCatalog.browser(snapshot: ambiguous, goal: "Drag \"Start\" to \"Finish\".", surface: .candidate).allSatisfy { $0.arguments["action"] != .string("drag") })
    }

    func testNavigationRefusesTrailingNewTabInstructionItCannotHonor() {
        let snapshot: JSONValue = .object([
            "target_id": .string("target"), "tab_id": .string("tab"), "refs": .array([])
        ])

        let actions = CuaActionCatalog.browser(snapshot: snapshot,
            goal: "Open \"https://example.invalid/a\" in a new tab.", surface: .candidate)

        XCTAssertFalse(actions.contains { $0.tool == "browser_navigate" })
    }

    func testBrowserUploadRequiresOneObservedInputAndOneExactRegularFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-upload-\(UUID().uuidString).txt")
        try Data("disposable upload fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let snapshot: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab"),
            "page": .object(["url": .string("https://example.invalid/upload")]),
            "refs": .array([.object(["ref": .string("p4:2"), "role": .string("button"), "name": .string("Choose file"),
                "actions": .array([.string("upload")]), "visibility": .string("in_viewport")])])])
        let goal = "Upload the file \"\(file.path)\""

        let production = CuaActionCatalog.browser(snapshot: snapshot, goal: goal)
        let candidate = try XCTUnwrap(CuaActionCatalog.browser(snapshot: snapshot, goal: goal, surface: .candidate)
            .first { $0.tool == "browser_set_input_files" })

        XCTAssertFalse(production.contains { $0.tool == "browser_set_input_files" })
        XCTAssertEqual(candidate.arguments["target_id"], .string("target"))
        XCTAssertEqual(candidate.arguments["tab_id"], .string("tab"))
        XCTAssertEqual(candidate.arguments["ref"], .string("p4:2"))
        XCTAssertEqual(candidate.arguments["files"], .array([.string(file.path)]))
        XCTAssertTrue(candidate.requiresApproval)
        XCTAssertTrue(candidate.approvalDescription?.contains("example.invalid") == true)
        var refreshed = snapshot.object!
        var refreshedRefs = snapshot["refs"]!.array!
        var refreshedRef = refreshedRefs[0].object!
        refreshedRef["ref"] = .string("p5:2")
        refreshedRefs[0] = .object(refreshedRef)
        refreshed["refs"] = .array(refreshedRefs)
        let rebound = try XCTUnwrap(CuaActionCatalog.browser(snapshot: .object(refreshed), goal: goal, surface: .candidate)
            .first { $0.tool == "browser_set_input_files" })
        XCTAssertEqual(candidate.bindingIdentity, rebound.bindingIdentity)
        XCTAssertEqual(rebound.arguments["ref"], .string("p5:2"))
        XCTAssertTrue(CuaActionCatalog.browser(snapshot: snapshot, goal: "Do not upload \"\(file.path)\"", surface: .candidate)
            .allSatisfy { $0.tool != "browser_set_input_files" })
        var ambiguous = snapshot.object!
        ambiguous["refs"] = .array(snapshot["refs"]!.array! + [.object(["ref": .string("p4:3"), "role": .string("button"),
            "actions": .array([.string("upload")]), "visibility": .string("in_viewport")])])
        XCTAssertTrue(CuaActionCatalog.browser(snapshot: .object(ambiguous), goal: goal, surface: .candidate)
            .allSatisfy { $0.tool != "browser_set_input_files" })

        let symlink = file.deletingLastPathComponent().appendingPathComponent("jarvis-upload-link-\(UUID().uuidString).txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        defer { try? FileManager.default.removeItem(at: symlink) }
        XCTAssertNil(CuaActionCatalog.uploadFileIdentity(path: symlink.path))
    }

    func testDifferentPopupValuesHaveDifferentActionAndBindingIdentities() throws {
        let elements: [JSONValue] = [
            .object(["element_index": .number(0), "role": .string("AXPopUpButton"), "label": .string("Format"),
                     "element_token": .string("popup"), "enabled": .bool(true)]),
            .object(["element_index": .number(1), "parent_index": .number(0), "role": .string("AXMenuItem"),
                     "label": .string("Plain Text"), "enabled": .bool(true)]),
            .object(["element_index": .number(2), "parent_index": .number(0), "role": .string("AXMenuItem"),
                     "label": .string("Rich Text"), "enabled": .bool(true)])
        ]
        let plain = try XCTUnwrap(CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Choose \"Plain Text\".", surface: .candidate).first { $0.tool == "set_value" })
        let rich = try XCTUnwrap(CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Choose \"Rich Text\".", surface: .candidate).first { $0.tool == "set_value" })
        XCTAssertEqual(plain.arguments["value"], .string("Plain Text"))
        XCTAssertEqual(rich.arguments["value"], .string("Rich Text"))
        XCTAssertNotEqual(plain.bindingIdentity, rich.bindingIdentity)
        XCTAssertNotEqual(plain.effectIdentity, rich.effectIdentity)
    }

    func testPopupChoiceComesOnlyFromAnExplicitUserValue() {
        let elements: [JSONValue] = [
            .object(["element_index": .number(0), "role": .string("AXPopUpButton"), "label": .string("Theme"), "element_token": .string("theme")]),
            .object(["element_index": .number(1), "parent_index": .number(0), "role": .string("AXMenuItem"), "label": .string("Ocean"), "enabled": .bool(true)]),
            .object(["element_index": .number(2), "parent_index": .number(0), "role": .string("AXMenuItem"), "label": .string("Sand"), "enabled": .bool(true)])
        ]
        let actions = CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Choose \"Ocean\" in Theme.", surface: .candidate).filter { $0.tool == "set_value" }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.arguments["value"], .string("Ocean"))
        XCTAssertTrue(CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Choose a theme", surface: .candidate).allSatisfy { $0.tool != "set_value" })
    }

    func testExplicitWindowFrameBindsGeometryAndRequiresApproval() throws {
        let action = try XCTUnwrap(CuaActionCatalog.native(elements: [], pid: 12, window: 34,
            goal: "Set the current window to x=80 y=90 width=1000 height=700.", surface: .candidate)
            .first { $0.tool == "set_window_frame" })
        XCTAssertEqual(action.arguments["pid"], .number(12))
        XCTAssertEqual(action.arguments["window_id"], .number(34))
        XCTAssertEqual(action.arguments["x"], .number(80))
        XCTAssertEqual(action.arguments["y"], .number(90))
        XCTAssertEqual(action.arguments["width"], .number(1000))
        XCTAssertEqual(action.arguments["height"], .number(700))
        XCTAssertTrue(action.requiresApproval)
        XCTAssertFalse(CuaActionCatalog.native(elements: [], pid: 12, window: 34,
            goal: "Arrange the windows to x=80 y=90 width=1000 height=700.", surface: .candidate)
            .contains { $0.tool == "set_window_frame" })
        XCTAssertFalse(CuaActionCatalog.native(elements: [], pid: 12, window: 34,
            goal: "Set the current window to x=80 y=90 width=0 height=700.", surface: .candidate)
            .contains { $0.tool == "set_window_frame" })
    }

    func testBrowserDialogChoicesRequireExplicitDecisionAndExactCurrentDialog() throws {
        let snapshot: JSONValue = .object(["target_id": .string("target"), "tab_id": .string("tab")])
        let dialog: JSONValue = .object(["present": .bool(true), "dialog_id": .string("dialog-4"), "kind": .string("prompt")])
        let actions = CuaActionCatalog.browserDialog(snapshot: snapshot, dialog: dialog,
            goal: "Accept the prompt with \"copper lantern\".", surface: .candidate)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.tool, "browser_dialog")
        XCTAssertEqual(action.arguments["target_id"], .string("target"))
        XCTAssertEqual(action.arguments["tab_id"], .string("tab"))
        XCTAssertEqual(action.arguments["dialog_id"], .string("dialog-4"))
        XCTAssertEqual(action.arguments["action"], .string("accept"))
        XCTAssertEqual(action.arguments["prompt_text"], .string("copper lantern"))
        XCTAssertTrue(action.requiresApproval)
        XCTAssertTrue(CuaActionCatalog.browserDialog(snapshot: snapshot, dialog: dialog,
            goal: "Accept the prompt with \"copper lantern\".", surface: .production).isEmpty)
        XCTAssertTrue(CuaActionCatalog.browserDialog(snapshot: snapshot,
            dialog: .object(["present": .bool(true), "dialog_id": .string("dialog-5"), "kind": .string("beforeunload")]),
            goal: "Accept the dialog.", surface: .candidate).isEmpty)
        XCTAssertTrue(CuaActionCatalog.browserDialog(snapshot: snapshot, dialog: dialog,
            goal: "Accept the prompt.", surface: .candidate).isEmpty)
        let confirm = CuaActionCatalog.browserDialog(snapshot: snapshot,
            dialog: .object(["present": .bool(true), "dialog_id": .string("dialog-6"), "kind": .string("confirm")]),
            goal: "Click the \"Show confirmation\" button, then accept the current dialog.", surface: .candidate)
        XCTAssertEqual(confirm.first?.arguments["action"], .string("accept"))
        XCTAssertTrue(CuaActionCatalog.browserDialog(snapshot: snapshot, dialog: dialog,
            goal: "Do not accept the prompt with \"copper lantern\".", surface: .candidate).isEmpty)
    }

    func testNativeCandidateKeysPointerAndPopupValuesStayExactAndIsolated() {
        let elements: [JSONValue] = [
            .object(["element_index": .number(0), "role": .string("AXPopUpButton"), "label": .string("Theme"), "element_token": .string("theme")]),
            .object(["element_index": .number(1), "parent_index": .number(0), "role": .string("AXMenuItem"), "label": .string("Ocean"), "enabled": .bool(true)]),
            .object(["element_index": .number(2), "role": .string("AXRow"), "label": .string("Result"), "element_token": .string("row"), "actions": .array([.string("AXOpen"), .string("AXShowMenu")])]),
            .object(["element_index": .number(3), "role": .string("AXTextArea"), "label": .string("Body"), "element_token": .string("body"), "value": .string("seed")])
        ]
        let goal = "Press the key \"Return\" in Body."
        let production = CuaActionCatalog.native(elements: elements, pid: 12, window: 34, goal: goal)
        XCTAssertFalse(production.contains { ["press_key", "hotkey", "right_click", "double_click", "set_value"].contains($0.tool) })

        let candidate = CuaActionCatalog.native(elements: elements, pid: 12, window: 34, goal: goal, surface: .candidate)
        let enter = try! XCTUnwrap(candidate.first { $0.tool == "press_key" && $0.arguments["element_token"] == .string("body") })
        XCTAssertEqual(enter.arguments["key"], .string("return"))
        XCTAssertEqual(enter.arguments["element_token"], .string("body"))
        let rightClick = try! XCTUnwrap(candidate.first { $0.tool == "right_click" })
        XCTAssertEqual(rightClick.arguments["element_token"], .string("row"))
        let doubleClick = try! XCTUnwrap(candidate.first { $0.tool == "double_click" })
        XCTAssertEqual(doubleClick.arguments["element_token"], .string("row"))
        let option = try! XCTUnwrap(CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Choose \"Ocean\" in Theme.", surface: .candidate).first { $0.tool == "set_value" })
        XCTAssertEqual(option.arguments["element_token"], .string("theme"))
        XCTAssertEqual(option.arguments["value"], .string("Ocean"))

        let unsupportedKey = CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Press the key \"Tab\" in Body.", surface: .candidate)
        XCTAssertFalse(unsupportedKey.contains { ["press_key", "hotkey"].contains($0.tool) })
        let unsupportedHotkey = CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Press the shortcut \"cmd+shift+z\" in Body.", surface: .candidate)
        XCTAssertFalse(unsupportedHotkey.contains { ["press_key", "hotkey"].contains($0.tool) })
    }

    func testForegroundKeyDeliveryNeedsAnExplicitUserDirectedForegroundPhrase() throws {
        let elements: [JSONValue] = [.object(["element_index": .number(2), "role": .string("AXTextArea"),
            "label": .string("Body"), "element_token": .string("body"), "value": .string("seed"), "actions": .array([])])]
        let background = try XCTUnwrap(CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Press the key \"return\" in Body.", surface: .candidate).first { $0.tool == "press_key" })
        XCTAssertEqual(background.arguments["delivery_mode"], .string("background"))

        let foreground = try XCTUnwrap(CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "In the foreground, press the key \"return\" in Body.", surface: .candidate).first { $0.tool == "press_key" })
        XCTAssertEqual(foreground.arguments["delivery_mode"], .string("foreground"))

        let negated = CuaActionCatalog.native(elements: elements, pid: 12, window: 34,
            goal: "Do not bring the app to the foreground; press the key \"return\" in Body.", surface: .candidate)
            .first { $0.tool == "press_key" }
        XCTAssertEqual(negated?.arguments["delivery_mode"], .string("background"))
    }

    func testTextEffectIdentitySurvivesAChangedFieldLabelAndSnapshotToken() {
        let first = CuaObservedAction(description: "Insert supplied text into AXTextArea Draft",
                                      tool: "type_text",
                                      arguments: ["pid": .number(12), "window_id": .number(34), "element_token": .string("old-token"), "text": .string("copper lantern beside the")],
                                      targetIdentity: "native:12:34:element:7",
                                      requiresText: true)
        let second = CuaObservedAction(description: "Insert supplied text into AXTextArea copper lantern beside the",
                                       tool: "type_text",
                                       arguments: ["pid": .number(12), "window_id": .number(34), "element_token": .string("new-token"), "text": .string("copper lantern beside the window")],
                                       targetIdentity: "native:12:34:element:7",
                                       requiresText: true)

        XCTAssertEqual(first.effectIdentity, second.effectIdentity)
    }

    func testNativeEffectIdentitySurvivesTokenRefreshWhenIndexIsUnavailable() {
        func scroll(token: String) -> CuaObservedAction? {
            CuaActionCatalog.native(elements: [.object([
                "role": .string("AXScrollArea"), "label": .string("Document"), "element_token": .string(token)
            ])], pid: 12, window: 34).first
        }

        let first = scroll(token: "snapshot-a")
        let second = scroll(token: "snapshot-b")
        XCTAssertEqual(first?.effectIdentity, second?.effectIdentity)
        XCTAssertEqual(first?.bindingIdentity, second?.bindingIdentity)
    }

    func testDenseActionChoicesExposeEveryTargetThroughBoundedPages() {
        let owner = CuaActionOwner(taskID: UUID(), revision: 4)
        let actions = (0..<600).map { index in
            CuaObservedAction(description: "Click control \(index)", tool: "click",
                              arguments: ["pid": .number(12), "window_id": .number(34), "element_token": .string("token-\(index)")],
                              targetIdentity: "native:12:34:element:\(index)")
        }
        let book = CuaActionChoiceBook(actions: actions, owner: owner)
        let reserved: [String: String?] = ["done": "Done", "blocked": "Blocked"]

        let first = book.rootPage(reservedChoices: reserved, page: 0)
        XCTAssertEqual(first.mode, .targetGroups)
        XCTAssertLessThanOrEqual(first.choices.count, 255)
        XCTAssertTrue(first.choices[ CuaActionChoiceBook.nextPageID ] != nil)
        XCTAssertEqual(book.candidateCount, 600)

        let last = book.rootPage(reservedChoices: reserved, page: first.pageCount - 1)
        XCTAssertLessThanOrEqual(last.choices.count, 255)
        let lastGroupID = try! XCTUnwrap(last.groupIDs.first)
        let actionsForLastTarget = book.actionPage(groupID: lastGroupID, reservedChoices: reserved, page: 0)
        XCTAssertEqual(actionsForLastTarget.mode, .actions)
        XCTAssertLessThanOrEqual(actionsForLastTarget.choices.count, 255)
        XCTAssertTrue(actionsForLastTarget.choices.values.contains { $0 == "Done" })
        XCTAssertEqual(actionsForLastTarget.candidateIDs.count, 1)
    }

    func testCandidateIDKeepsOriginalArgumentsAndRejectsAnotherTaskRevision() {
        let owner = CuaActionOwner(taskID: UUID(), revision: 9)
        let action = CuaObservedAction(description: "Click observed control", tool: "click",
                                       arguments: ["pid": .number(12), "window_id": .number(34), "element_token": .string("exact-token")],
                                       targetIdentity: "native:12:34:element:7")
        let book = CuaActionChoiceBook(actions: [action], owner: owner)
        let page = book.rootPage(reservedChoices: ["done": "Done"], page: 0)
        let id = try! XCTUnwrap(page.candidateIDs.first)

        XCTAssertEqual(book.candidate(id: id, owner: owner)?.action.arguments["element_token"], .string("exact-token"))
        XCTAssertNil(book.candidate(id: id, owner: CuaActionOwner(taskID: owner.taskID, revision: 10)))
        XCTAssertNil(book.candidate(id: "candidate_stale", owner: owner))
    }
}
