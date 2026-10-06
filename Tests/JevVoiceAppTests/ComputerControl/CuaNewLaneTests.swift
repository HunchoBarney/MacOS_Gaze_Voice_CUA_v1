import XCTest
import JevVoiceCore
import AppKit
@testable import JevVoice

/// New deterministic lanes: clipboard read/write, window frames, force
/// quit, menu verbs, screen reads and script verbs — parse shapes, app
/// resolution, and the exact driver argument shapes each lane dispatches.
@MainActor
final class CuaNewLaneTests: XCTestCase {

    private func app(_ name: String, bundle: String, running: Bool = false, pid: Int = 0) -> JSONValue {
        .object(["name": .string(name), "bundle_id": .string(bundle),
                 "running": .bool(running), "pid": .number(Double(pid))])
    }

    private func windowRow(_ wid: Int, title: String = "Doc",
                           bounds: JSONValue? = nil) -> JSONValue {
        .object(["window_id": .number(Double(wid)), "is_on_screen": .bool(true),
                 "title": .string(title), "bounds": bounds ?? .object([
                    "x": .number(0), "y": .number(0),
                    "width": .number(100), "height": .number(100)])])
    }

    // MARK: - Clipboard

    /// The payload keeps raw casing/punctuation like .type; the clipboard
    /// tail is the fixed destination marker, never an app qualifier.
    func testClipboardWriteParsesVerbatimPayload() {
        XCTAssertEqual(CuaFastAction.parse("copy Hello, World to my clipboard")?.action.body,
                       .clipboardWrite("Hello, World"))
        XCTAssertEqual(CuaFastAction.parse("copy abc123 to the clipboard")?.action.body,
                       .clipboardWrite("abc123"))
        XCTAssertEqual(CuaFastAction.parse("copy \"quoted text\" to my clipboard")?.action.body,
                       .clipboardWrite("quoted text"))
        // A vague payload means the selection — ⌘C semantics the loop owns.
        for phrase in ["copy this to my clipboard", "copy it to my clipboard",
                       "copy the selection to my clipboard", "copy that to my clipboard"] {
            XCTAssertNil(CuaFastAction.parse(phrase), phrase)
        }
        // The pasteboard can't be scoped by an app qualifier.
        XCTAssertNil(CuaFastAction.parse("copy hello to my clipboard in notes"))
    }

    func testClipboardReadParsesWholePhrases() {
        for phrase in ["what's on my clipboard", "read my clipboard",
                       "what did I copy", "show me my clipboard",
                       "what's on the clipboard", "check my clipboard"] {
            XCTAssertEqual(CuaFastAction.parse(phrase)?.action.body, .clipboardRead, phrase)
        }
        XCTAssertNil(CuaFastAction.parse("read my clipboard in notes"))
        XCTAssertNil(CuaFastAction.parse("what's on my mind"))
    }

    /// clipboard_* need no app and no focus lease — the call goes straight
    /// to the driver with include_text, and the text is spoken truncated.
    func testClipboardReadSpeaksTheText() async throws {
        var calls: [(String, [String: JSONValue])] = []
        let sut = CuaTaskAgent(call: { tool, args in
            calls.append((tool, args))
            if tool == "clipboard_read" {
                return .object(["supported": .bool(true),
                                "types": .array([.string("public.utf8-plain-text")]),
                                "text": .string("hello clipboard")])
            }
            return .object([:])
        }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(goal: "what's on my clipboard", apps: []))
        let spoken = try await sut.runFastLane(resolved, goal: "what's on my clipboard") { _ in }
        XCTAssertEqual(spoken, "Your clipboard says: hello clipboard")
        XCTAssertEqual(calls.map(\.0), ["clipboard_read"])
        XCTAssertEqual(calls[0].1["include_text"], .bool(true))
    }

    func testClipboardReadTruncatesLongText() async throws {
        let long = String(repeating: "word ", count: 200)
        let sut = CuaTaskAgent(call: { tool, _ in
            if tool == "clipboard_read" {
                return .object(["types": .array([.string("public.utf8-plain-text")]),
                                "text": .string(long)])
            }
            return .object([:])
        }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(goal: "read my clipboard", apps: []))
        let result = try await sut.runFastLane(resolved, goal: "read my clipboard") { _ in }
        let spoken = try XCTUnwrap(result)
        XCTAssertTrue(spoken.hasPrefix("Your clipboard says: "))
        XCTAssertTrue(spoken.hasSuffix("…"))
        XCTAssertLessThan(spoken.count, 340)
    }

    /// Empty and non-text pasteboards report honestly rather than claim
    /// silence — an image-only clipboard says what it does hold.
    func testEmptyAndNonTextClipboardsSaySo() async throws {
        let empty = CuaTaskAgent(call: { tool, _ in
            if tool == "clipboard_read" {
                return .object(["types": .array([]), "text": .null])
            }
            return .object([:])
        }, lanes: nil)
        var resolved = try XCTUnwrap(empty.resolveFastLane(goal: "what's on my clipboard", apps: []))
        var spoken = try await empty.runFastLane(resolved, goal: "what's on my clipboard") { _ in }
        XCTAssertEqual(spoken, "Your clipboard is empty.")

        let imageOnly = CuaTaskAgent(call: { tool, _ in
            if tool == "clipboard_read" {
                return .object(["types": .array([.string("public.png")]), "text": .null])
            }
            return .object([:])
        }, lanes: nil)
        resolved = try XCTUnwrap(imageOnly.resolveFastLane(goal: "what's on my clipboard", apps: []))
        spoken = try await imageOnly.runFastLane(resolved, goal: "what's on my clipboard") { _ in }
        XCTAssertEqual(spoken, "Your clipboard has no text. It holds public.png — not text.")
    }

    /// The write lands then a same-lease readback proves it — the spoken
    /// line is the readback verdict, not the driver's send receipt.
    func testClipboardWriteVerifiesReadback() async throws {
        var calls: [(String, [String: JSONValue])] = []
        let sut = CuaTaskAgent(call: { tool, args in
            calls.append((tool, args))
            if tool == "clipboard_read" {
                return .object(["text": .string("Hello, World")])
            }
            return .object([:])
        }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(goal: "copy Hello, World to my clipboard", apps: []))
        let spoken = try await sut.runFastLane(resolved, goal: "copy Hello, World to my clipboard") { _ in }
        XCTAssertEqual(spoken, "On your clipboard.")
        XCTAssertEqual(calls.map(\.0), ["clipboard_write", "clipboard_read"])
        XCTAssertEqual(calls[0].1["text"], .string("Hello, World"))
    }

    func testClipboardWriteAdmitsAFailedReadback() async throws {
        let sut = CuaTaskAgent(call: { tool, _ in
            if tool == "clipboard_read" { return .object(["text": .string("something else")]) }
            return .object([:])
        }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(goal: "copy hello to my clipboard", apps: []))
        let spoken = try await sut.runFastLane(resolved, goal: "copy hello to my clipboard") { _ in }
        XCTAssertEqual(spoken, "Copied — the clipboard readback did not confirm it.")
    }

    // MARK: - Window verbs

    func testWindowVerbsParseDeterministically() {
        let cases: [(String, CuaFastAction.WindowVerb)] = [
            ("snap left", .left), ("snap to the left", .left),
            ("move this window to the left", .left),
            ("move this window to the left half", .left),
            ("put the window on the left", .left),
            ("snap right", .right), ("tile to the right", .right),
            ("move the window to the right half", .right),
            ("send this window to the right", .right),
            ("snap up", .top), ("move this window to the top", .top),
            ("snap down", .bottom), ("move this window to the bottom half", .bottom),
            ("maximize the window", .fill), ("fill the screen", .fill),
            ("center this window", .center), ("centre the window", .center),
            ("move this window to the other display", .otherDisplay),
            ("send this window to the other monitor", .otherDisplay),
            ("move the window to the next screen", .otherDisplay)
        ]
        for (phrase, verb) in cases {
            XCTAssertEqual(CuaFastAction.parse(phrase)?.action.body, .windowFrame(verb), phrase)
        }
    }

    /// Phrases that merely contain a window word or a direction without
    /// the window anchor stay with the loop — no swallowing.
    func testWindowVerbKeepsNonWindowPhrasesOut() {
        XCTAssertNil(CuaFastAction.parse("move the file to the left"))
        XCTAssertNil(CuaFastAction.parse("move window"))
        XCTAssertNil(CuaFastAction.parse("move this window over"))
        XCTAssertNil(CuaFastAction.parse("kill the window"))
        // Real fullscreen keeps its ⌃⌘F chord — .fill is maximize, never
        // a fake fullscreen.
        guard case .hotkey = CuaFastAction.parse("make this window fullscreen")?.action.body else {
            return XCTFail("fullscreen phrasing must keep the ⌃⌘F chord")
        }
        guard case .hotkey = CuaFastAction.parse("unfullscreen")?.action.body else {
            return XCTFail("unfullscreen must keep the ⌃⌘F chord")
        }
        // Existing window chords keep their own lanes.
        guard case .hotkey = CuaFastAction.parse("minimize the window")?.action.body else {
            return XCTFail("minimize must keep ⌘M")
        }
        guard case .hotkey = CuaFastAction.parse("new window")?.action.body else {
            return XCTFail("new window must keep ⌘N")
        }
    }

    func testWindowFrameResolvesFrontmost() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Notes", bundle: "com.apple.Notes", running: true, pid: 5),
                    app("Safari", bundle: "com.apple.Safari", running: true, pid: 7)]
        let resolved = sut.resolveFastLane(goal: "snap left", apps: apps,
                                           frontmostBundleOverride: "com.apple.Notes")
        XCTAssertEqual(resolved?.bundle, "com.apple.Notes")
        XCTAssertEqual(resolved?.action?.body, .windowFrame(.left))
        // A peeled qualifier names the target app instead.
        let qualified = sut.resolveFastLane(goal: "move this window to the left in safari", apps: apps,
                                            frontmostBundleOverride: "com.apple.Notes")
        XCTAssertEqual(qualified?.bundle, "com.apple.Safari")
    }

    /// set_window_frame dispatches the visible-frame geometry — left half
    /// is x/w of the hosting screen's visible frame — and the driver's
    /// confirmed effect is the spoken verdict.
    func testWindowSnapDispatchesExactFrame() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no display") }
        var frameArgs: [String: JSONValue]?
        let sut = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture", running: true, pid: 999999)])])
            case "list_windows":
                return .object(["windows": .array([self.windowRow(7, bounds: .object([
                    "x": .number(0), "y": .number(0),
                    "width": .number(100), "height": .number(100)]))])])
            case "set_window_frame":
                frameArgs = args
                return .object(["effect": .string("confirmed")])
            default:
                return .object([:])
            }
        }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "move this window to the left",
            apps: [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)],
            frontmostBundleOverride: "test.fixture"))
        let spoken = try await sut.runFastLane(resolved, goal: "move this window to the left") { _ in }
        XCTAssertEqual(spoken, "Moved the window to the left half in Fixture.")
        let vf = screen.visibleFrame
        let primary = screen.frame.height
        XCTAssertEqual(frameArgs?["pid"], .number(999999))
        XCTAssertEqual(frameArgs?["window_id"], .number(7))
        XCTAssertEqual(frameArgs?["x"], .number(vf.origin.x))
        XCTAssertEqual(frameArgs?["width"], .number(vf.width / 2))
        XCTAssertEqual(frameArgs?["height"], .number(vf.height))
        XCTAssertEqual(frameArgs?["y"], .number(primary - vf.origin.y - vf.height))
    }

    /// unverifiable stays honest — never "moved".
    func testWindowFrameReportsUnverifiable() async throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("no display") }
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let sut = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            case "list_windows":
                return .object(["windows": .array([self.windowRow(7)])])
            case "set_window_frame":
                return .object(["effect": .string("unverifiable")])
            default:
                return .object([:])
            }
        }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "center this window", apps: apps, frontmostBundleOverride: "test.fixture"))
        let spoken = try await sut.runFastLane(resolved, goal: "center this window") { _ in }
        XCTAssertEqual(spoken, "Asked Fixture's window to move; the new frame could not be verified.")
    }

    // MARK: - Force quit

    func testKillParsesTightly() {
        for phrase in ["force quit", "force close", "force quit spotify",
                       "kill spotify", "force close notes", "terminate safari"] {
            XCTAssertEqual(CuaFastAction.parse(phrase)?.action.body, .killApp, phrase)
        }
        XCTAssertEqual(CuaFastAction.parse("force quit spotify")?.appQualifier, "spotify")
        // "kill it" refers to the frontmost app through the qualifier.
        XCTAssertEqual(CuaFastAction.parse("kill it")?.appQualifier, "it")
        // A peeled qualifier supplies the target too.
        XCTAssertEqual(CuaFastAction.parse("force quit in spotify")?.appQualifier, "spotify")
        // A tail AND a qualifier is two names — the loop owns it.
        XCTAssertNil(CuaFastAction.parse("force quit spotify in safari"))
        // Window work is not a process kill.
        XCTAssertNil(CuaFastAction.parse("kill the window"))
        // Graceful quit stays its own lane.
        XCTAssertEqual(CuaFastAction.parse("quit spotify")?.action.body, .appControl(.quit))
    }

    /// kill_app asks once — the SIGKILL is destructive — then the
    /// process-gone poll is the proof, not the driver's receipt.
    func testKillAppAsksThenVerifiesGone() async throws {
        var asked: [String] = []
        var killed: [String: JSONValue]?
        let sut = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            case "kill_app":
                killed = args
                return .object([:])
            default:
                return .object([:])
            }
        }, approve: { prompt in asked.append(prompt); return true }, lanes: nil)
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let resolved = try XCTUnwrap(sut.resolveFastLane(goal: "force quit fixture", apps: apps))
        let spoken = try await sut.runFastLane(resolved, goal: "force quit fixture") { _ in }
        XCTAssertEqual(killed?["pid"], .number(999999))
        XCTAssertTrue(asked.first?.contains("Force quit Fixture") ?? false)
        // pid 999999 is beyond the Darwin pid range — NSRunningApplication
        // always reports it terminated.
        XCTAssertEqual(spoken, "Force quit Fixture.")
    }

    /// Denying the approval cancels the whole lane — kill_app never fires.
    func testKillAppDeniedApprovalNeverDispatches() async throws {
        var calls: [String] = []
        let sut = CuaTaskAgent(call: { tool, _ in
            calls.append(tool)
            if tool == "list_apps" {
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            }
            return .object([:])
        }, approve: { _ in false }, lanes: nil)
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let resolved = try XCTUnwrap(sut.resolveFastLane(goal: "force quit fixture", apps: apps))
        do {
            _ = try await sut.runFastLane(resolved, goal: "force quit fixture") { _ in }
            XCTFail("a denied approval must cancel the lane")
        } catch { }
        XCTAssertFalse(calls.contains("kill_app"))
    }

    /// Without an approve hook the lane hands back to the drive loop
    /// rather than firing a consented-action it cannot ask about.
    func testKillAppWithoutApproverFallsToLoop() async throws {
        let sut = CuaTaskAgent(call: { tool, _ in
            if tool == "list_apps" {
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            }
            return .object([:])
        }, lanes: nil)
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let resolved = try XCTUnwrap(sut.resolveFastLane(goal: "force quit fixture", apps: apps))
        let result = try await sut.runFastLane(resolved, goal: "force quit fixture") { _ in }
        XCTAssertNil(result)
    }

    // MARK: - Menu verbs

    func testMenuVerbsParseStandardPaths() {
        let cases: [(String, CuaFastAction.MenuVerb)] = [
            ("save", .save), ("save this", .save), ("save the document", .save),
            ("undo", .undo), ("redo", .redo),
            ("print this", .print), ("print the page", .print),
            ("close tab", .closeTab), ("close the tab", .closeTab),
            ("close this tab", .closeTab)
        ]
        for (phrase, menu) in cases {
            XCTAssertEqual(CuaFastAction.parse(phrase)?.action.body, .menuVerb(menu), phrase)
        }
        // Whole-phrase claim before app control — "close the tab" never
        // parses as "quit the app named tab".
        XCTAssertEqual(CuaFastAction.parse("close the tab")?.action.body, .menuVerb(.closeTab))
        // "close the window" still falls to the loop — never a quit.
        XCTAssertNil(CuaFastAction.parse("close the window"))
        // The paths are the literal menu titles the driver matches.
        XCTAssertEqual(CuaFastAction.MenuVerb.save.path, ["File", "Save"])
        XCTAssertEqual(CuaFastAction.MenuVerb.print.path, ["File", "Print…"])
        XCTAssertEqual(CuaFastAction.MenuVerb.closeTab.path, ["File", "Close Tab"])
    }

    /// invoke_menu carries pid/window_id and the exact path — the
    /// granted-once focus ask happens only when the target is not
    /// frontmost (and never in tests, where the fixture stays frontmost
    /// via the standing grant).
    func testMenuVerbInvokesExactPath() async throws {
        var menuArgs: [String: JSONValue]?
        var asked: [String] = []
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let sut = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            case "list_windows":
                return .object(["windows": .array([self.windowRow(7)])])
            case "invoke_menu":
                menuArgs = args
                return .object(["effect": .string("unverifiable")])
            default:
                return .object([:])
            }
        }, approve: { prompt in asked.append(prompt); return true }, lanes: nil)
        // The fixture can't be frontmost on the test host — grant the
        // standing menu-focus permission for this bundle only.
        CuaStandingGrants.grantMenuFocus(bundle: "test.fixture")
        defer { UserDefaults.standard.removeObject(forKey: "cuaStandingGrant.menuFocus.test.fixture") }
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "save this", apps: apps, frontmostBundleOverride: "test.fixture"))
        let spoken = try await sut.runFastLane(resolved, goal: "save this") { _ in }
        XCTAssertEqual(spoken, "Invoked File → Save in Fixture.")
        XCTAssertEqual(menuArgs?["pid"], .number(999999))
        XCTAssertEqual(menuArgs?["window_id"], .number(7))
        XCTAssertEqual(menuArgs?["path"], .array([.string("File"), .string("Save")]))
        XCTAssertTrue(asked.isEmpty, "a granted menu focus must not re-ask")
    }

    /// closeTab carries its own approval — denial cancels before the
    /// menu fires.
    func testCloseTabDeniedApprovalNeverDispatches() async throws {
        var calls: [String] = []
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let sut = CuaTaskAgent(call: { tool, _ in
            calls.append(tool)
            if tool == "list_apps" {
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            }
            if tool == "list_windows" {
                return .object(["windows": .array([self.windowRow(7)])])
            }
            return .object([:])
        }, approve: { _ in false }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "close tab", apps: apps, frontmostBundleOverride: "test.fixture"))
        do {
            _ = try await sut.runFastLane(resolved, goal: "close tab") { _ in }
            XCTFail("a denied approval must cancel the lane")
        } catch { }
        XCTAssertFalse(calls.contains("invoke_menu"))
    }

    /// A driver-listed path refusal surfaces as a typed toolRefused —
    /// the lane reports it honestly, never "saved".
    func testMenuVerbReportsDriverRefusal() async throws {
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let sut = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            case "list_windows":
                return .object(["windows": .array([self.windowRow(7)])])
            case "invoke_menu":
                throw DriverConnectionError.toolRefused(
                    tool: "invoke_menu", code: "menu_path_unavailable", detail: "disabled")
            default:
                return .object([:])
            }
        }, approve: { _ in true }, lanes: nil)
        CuaStandingGrants.grantMenuFocus(bundle: "test.fixture")
        defer { UserDefaults.standard.removeObject(forKey: "cuaStandingGrant.menuFocus.test.fixture") }
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "save this", apps: apps, frontmostBundleOverride: "test.fixture"))
        let spoken = try await sut.runFastLane(resolved, goal: "save this") { _ in }
        XCTAssertEqual(spoken, "Fixture doesn't have that menu item right now.")
    }

    // MARK: - Screen read

    func testScreenReadParsesAndKeepsDestinationsInside() {
        for phrase in ["what's on my screen", "read the screen",
                       "what does this say", "what am I looking at",
                       "describe my screen", "what's on the window"] {
            XCTAssertEqual(CuaFastAction.parse(phrase)?.action.body, .screenRead, phrase)
        }
        // "on my screen" is the object, not an app qualifier.
        XCTAssertNil(CuaFastAction.parse("what's on my screen")?.appQualifier)
        // A later real preposition can still name the app.
        XCTAssertEqual(CuaFastAction.parse("what's on the screen in notes")?.appQualifier, "notes")
        XCTAssertNil(CuaFastAction.parse("what's on my mind"))
    }

    /// The spoken summary carries the app, title, first static texts and
    /// control counts — not just "done".
    func testScreenReadSpeaksTheWindowSummary() async throws {
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let sut = CuaTaskAgent(call: { tool, args in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            case "list_windows":
                return .object(["windows": .array([self.windowRow(7, title: "Notes — Doc")])])
            case "get_window_state":
                XCTAssertEqual(args["pid"], .number(999999))
                XCTAssertEqual(args["window_id"], .number(7))
                XCTAssertEqual(args["include_screenshot"], .bool(false))
                // elements[] carries actionable nodes only; the readable
                // text rides tree_markdown's non-indexed `= "value"` lines.
                return .object(["window_title": .string("Notes — Doc"),
                                "tree_markdown": .string("- AXGroup\n  - AXStaticText = \"Hello there\"\n  - AXStaticText = \"Second line\"\n  - [0] AXButton \"OK\" [actions=[AXPress]]\n  - [1] AXButton \"Cancel\" [actions=[AXPress]]\n  - [2] AXTextField \"Search\" [actions=[AXConfirm]]"),
                                "elements": .array([
                                    .object(["role": .string("AXButton"), "label": .string("OK")]),
                                    .object(["role": .string("AXButton"), "label": .string("Cancel")]),
                                    .object(["role": .string("AXTextField"), "value": .string("")])])])
            default:
                return .object([:])
            }
        }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "what's on my screen", apps: apps, frontmostBundleOverride: "test.fixture"))
        let spoken = try await sut.runFastLane(resolved, goal: "what's on my screen") { _ in }
        XCTAssertTrue(spoken?.contains("Fixture's window “Notes — Doc”") ?? false, spoken ?? "")
        XCTAssertTrue(spoken?.contains("“Hello there”") ?? false, spoken ?? "")
        XCTAssertTrue(spoken?.contains("“Second line”") ?? false, spoken ?? "")
        XCTAssertTrue(spoken?.contains("2 buttons") ?? false, spoken ?? "")
        XCTAssertTrue(spoken?.contains("1 text field") ?? false, spoken ?? "")
    }

    /// A sparse AX tree reports sparseness honestly.
    func testScreenReadReportsSparseTree() async throws {
        let apps = [app("Fixture", bundle: "test.fixture", running: true, pid: 999999)]
        let sut = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps":
                return .object(["apps": .array([self.app("Fixture", bundle: "test.fixture",
                                                         running: true, pid: 999999)])])
            case "list_windows":
                return .object(["windows": .array([self.windowRow(7)])])
            case "get_window_state":
                return .object(["window_title": .string("Canvas"), "elements": .array([]),
                                "degraded": .bool(true)])
            default:
                return .object([:])
            }
        }, lanes: nil)
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "read the screen", apps: apps, frontmostBundleOverride: "test.fixture"))
        let spoken = try await sut.runFastLane(resolved, goal: "read the screen") { _ in }
        XCTAssertTrue(spoken?.contains("degraded") ?? false, spoken ?? "")
    }

    // MARK: - Script verbs

    func testScriptVerbsParse() {
        XCTAssertEqual(CuaFastAction.parse("what's playing")?.action.body, .scriptVerb(.nowPlaying))
        XCTAssertEqual(CuaFastAction.parse("what song is playing")?.action.body, .scriptVerb(.nowPlaying))
        XCTAssertEqual(CuaFastAction.parse("what am I listening to")?.action.body, .scriptVerb(.nowPlaying))
        XCTAssertEqual(CuaFastAction.parse("what's the volume")?.action.body, .scriptVerb(.getVolume))
        XCTAssertEqual(CuaFastAction.parse("set volume to 50")?.action.body, .scriptVerb(.setVolume(50)))
        XCTAssertEqual(CuaFastAction.parse("set the volume to twenty percent")?.action.body, .scriptVerb(.setVolume(20)))
        XCTAssertEqual(CuaFastAction.parse("turn the volume down to twenty percent")?.action.body, .scriptVerb(.setVolume(20)))
        XCTAssertEqual(CuaFastAction.parse("volume to 75")?.action.body, .scriptVerb(.setVolume(75)))
        XCTAssertEqual(CuaFastAction.parse("volume fifty")?.action.body, .scriptVerb(.setVolume(50)))
        XCTAssertEqual(CuaFastAction.parse("half volume")?.action.body, .scriptVerb(.setVolume(50)))
        XCTAssertEqual(CuaFastAction.parse("full volume")?.action.body, .scriptVerb(.setVolume(100)))
        XCTAssertEqual(CuaFastAction.parse("mute the speakers")?.action.body, .scriptVerb(.mute(true)))
        XCTAssertEqual(CuaFastAction.parse("unmute my speaker")?.action.body, .scriptVerb(.mute(false)))
        // The HID-key phrases keep their lanes — a peel can't scope
        // system volume or the player query.
        XCTAssertEqual(CuaFastAction.parse("volume up")?.action.body, .mediaKey(.volumeUp))
        XCTAssertEqual(CuaFastAction.parse("mute")?.action.body, .mediaKey(.mute))
        XCTAssertNil(CuaFastAction.parse("set volume to 50 in safari"))
        XCTAssertNil(CuaFastAction.parse("whats playing in spotify"))
        XCTAssertNil(CuaFastAction.parse("volume to banana"))
        XCTAssertNil(CuaFastAction.parse("set volume to 250"))
    }

    /// The osascript payloads are fixed templates — the payload is the
    /// template choice, never freeform text, and setVolume clamps.
    func testScriptSourcesAreFixedTemplates() {
        XCTAssertTrue(CuaTaskAgent.scriptSource(.setVolume(50)).contains("output volume 50"))
        XCTAssertTrue(CuaTaskAgent.scriptSource(.setVolume(250)).contains("output volume 100"))
        XCTAssertTrue(CuaTaskAgent.scriptSource(.setVolume(-5)).contains("output volume 0"))
        XCTAssertTrue(CuaTaskAgent.scriptSource(.nowPlaying).contains("Spotify"))
        XCTAssertTrue(CuaTaskAgent.scriptSource(.nowPlaying).contains("Music"))
        XCTAssertTrue(CuaTaskAgent.scriptSource(.mute(true)).contains("output muted"))
        XCTAssertTrue(CuaTaskAgent.scriptSource(.mute(false)).contains("without output muted"))
    }

    /// Script lanes are app-free — they never touch list_apps, the focus
    /// lease or a window binding.
    func testScriptVerbNeedsNoApp() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let resolved = sut.resolveFastLane(goal: "what's playing", apps: [])
        XCTAssertEqual(resolved?.action?.body, .scriptVerb(.nowPlaying))
        XCTAssertEqual(resolved?.bundle, "")
    }

    // MARK: - Regression: existing lanes keep their shapes

    func testExistingLanesKeepTheirShapes() {
        XCTAssertEqual(CuaFastAction.parse("quit spotify")?.action.body, .appControl(.quit))
        XCTAssertEqual(CuaFastAction.parse("minimize notes window")?.action.body,
                       .appControl(.minimize))
        guard case .hotkey = CuaFastAction.parse("next window")?.action.body else {
            return XCTFail("next window keeps ⌘`")
        }
        guard case .hotkey = CuaFastAction.parse("open a new tab")?.action.body else {
            return XCTFail("new tab keeps ⌘T")
        }
        XCTAssertNil(CuaFastAction.parse("close the window"))
    }

    // MARK: - systemURL: named Shortcuts runs

    /// "run the X shortcut" carries the name verbatim — casing included —
    /// and never collides with "run Spotify" (no `shortcut` token).
    func testShortcutRunsParseVerbatimName() {
        guard case .systemURL(.shortcut(let name)) =
                CuaFastAction.parse("run the Morning Brief shortcut")?.action.body else {
            return XCTFail("run the X shortcut must lane")
        }
        XCTAssertEqual(name, "Morning Brief")
        guard case .systemURL(.shortcut(let name2)) =
                CuaFastAction.parse("run shortcut Deploy")?.action.body else {
            return XCTFail("run shortcut X must lane")
        }
        XCTAssertEqual(name2, "Deploy")
        XCTAssertNil(CuaFastAction.parse("run shortcut"))
        XCTAssertNil(CuaFastAction.parse("run the morning routine"))
    }

    /// The URL the lane hands LaunchServices runs the named shortcut in
    /// place — `name` is query-encoded, never rewritten.
    func testShortcutURLRunsInPlace() {
        let verb = CuaFastAction.SystemVerb.shortcut("Morning Brief")
        XCTAssertEqual(verb.url?.absoluteString,
                       "shortcuts://run-shortcut?name=Morning%20Brief")
    }
}
