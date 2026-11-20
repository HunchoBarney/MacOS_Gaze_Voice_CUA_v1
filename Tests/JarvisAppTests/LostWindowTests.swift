import CoreGraphics
import XCTest
@testable import Jarvis
import JarvisCore

/// A pretend desktop for the lost-window and full-screen lanes: window
/// rows, process state and the AX attributes the lanes read, changed by the
/// same seams production drives. `steps` records every fix in order.
private final class FakeDesk {
    struct Win {
        var id: Int
        var pid: Int
        var app: String
        var title: String
        var frame: CGRect
        var onScreen = true
        var z = 1
        var minimized: Bool? = nil
        var fullScreen: Bool? = nil
    }

    var windows: [Win] = []
    var hidden: Set<Int> = []
    var stageManager = false
    var steps: [String] = []
    var frameWrites: [CGRect] = []
    var onActivate: (FakeDesk, Int) -> Void = { _, _ in }
    var onReopen: (FakeDesk, Int) -> Void = { _, _ in }
    var onLaunch: (FakeDesk, String) -> Int? = { _, _ in nil }
    var unminimizeWorks = true
    var setFullScreen: (FakeDesk, Int) -> Bool = { _, _ in false }
    var pressFullScreen: (FakeDesk, Int) -> Bool = { _, _ in false }
    var menu: (FakeDesk, [String]) throws -> Void = { _, _ in
        throw DriverConnectionError.toolRefused(tool: "invoke_menu", code: "menu_not_found", detail: "")
    }
    var hotkey: (FakeDesk, [String]) -> Void = { _, _ in }

    func index(_ id: Int) -> Int? { windows.firstIndex { $0.id == id } }

    func exitFullScreen(_ id: Int, to frame: CGRect = CGRect(x: 100, y: 100, width: 900, height: 600)) {
        guard let i = index(id) else { return }
        windows[i].fullScreen = windows[i].fullScreen == nil ? nil : false
        windows[i].frame = frame
    }

    func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
        let confirmed = JSONValue.object(["effect": .string("confirmed")])
        switch tool {
        case "list_windows":
            let pid = args["pid"]?.integer
            return .object(["windows": .array(windows.filter { pid == nil || $0.pid == pid }.map { w in
                .object(["window_id": .number(Double(w.id)), "pid": .number(Double(w.pid)),
                         "app_name": .string(w.app), "title": .string(w.title),
                         "bounds": .object(["x": .number(w.frame.minX), "y": .number(w.frame.minY),
                                            "width": .number(w.frame.width),
                                            "height": .number(w.frame.height)]),
                         "z_index": .number(Double(w.z)), "is_on_screen": .bool(w.onScreen)])
            })])
        case "list_apps":
            var seen: [Int: String] = [:]
            for w in windows { seen[w.pid] = w.app }
            return .object(["apps": .array(seen.map { pid, app in
                .object(["name": .string(app), "bundle_id": .string("fixture.\(app.lowercased())"),
                         "pid": .number(Double(pid))])
            })])
        case "set_window_frame":
            guard let id = args["window_id"]?.integer, let i = index(id),
                  case .number(let x)? = args["x"], case .number(let y)? = args["y"],
                  case .number(let w)? = args["width"], case .number(let h)? = args["height"] else { return confirmed }
            steps.append("move \(id)")
            windows[i].frame = CGRect(x: x, y: y, width: w, height: h)
            frameWrites.append(windows[i].frame)
            return confirmed
        case "launch_app":
            let bundle = args["bundle_id"]?.string ?? ""
            steps.append("launch \(bundle)")
            guard let pid = onLaunch(self, bundle) else { return confirmed }
            return .object(["pid": .number(Double(pid))])
        case "invoke_menu":
            let path = args["path"]?.array?.compactMap(\.string) ?? []
            steps.append("menu \(path.joined(separator: " > "))")
            try menu(self, path)
            return confirmed
        case "hotkey":
            let keys = args["keys"]?.array?.compactMap(\.string) ?? []
            steps.append("hotkey \(keys.joined(separator: "+"))")
            hotkey(self, keys)
            return confirmed
        default:
            return confirmed
        }
    }

    var attributes: WindowControls.Attributes {
        WindowControls.Attributes(
            minimized: { _, id in self.index(id).flatMap { self.windows[$0].minimized } },
            setMinimized: { _, id, value in
                self.steps.append("unminimize \(id)")
                guard self.unminimizeWorks, let i = self.index(id) else { return false }
                self.windows[i].minimized = value
                self.windows[i].onScreen = !value
                return true
            },
            fullScreen: { _, id in self.index(id).flatMap { self.windows[$0].fullScreen } },
            setFullScreen: { _, id, _ in
                self.steps.append("AXFullScreen")
                return self.setFullScreen(self, id)
            },
            raise: { _, id in
                self.steps.append("raise \(id)")
                guard let i = self.index(id) else { return false }
                self.windows[i].z = (self.windows.map(\.z).max() ?? 0) + 1
                return true
            },
            stageManager: { self.stageManager })
    }

    func loop(apps: [AppResolver.App] = [], front: Int? = nil,
              frontBundle: String? = nil) -> DriveLoop {
        DriveLoop(call: { t, a in try self.call(t, a) },
                  choose: { _, _ in nil }, ask: nil, granted: { true },
                  resolver: AppResolver(exactBundleApps: { _ in [] }, listApps: { apps }),
                  activateApp: { pid in
                      self.steps.append("activate \(pid)")
                      self.onActivate(self, pid)
                  },
                  appIsHidden: { self.hidden.contains($0) },
                  unhideApp: { pid in
                      self.steps.append("unhide \(pid)")
                      self.hidden.remove(pid)
                      for i in self.windows.indices where self.windows[i].pid == pid {
                          self.windows[i].onScreen = true
                      }
                      return true
                  },
                  activateRestoredApp: { pid, _ in
                      self.steps.append("reopen \(pid)")
                      self.onReopen(self, pid)
                  },
                  observeLaunchedPID: { _ in nil },
                  windowControlPressInWindow: { kind, _, id in
                      self.steps.append("button \(kind.rawValue)")
                      return kind == .fullscreen && self.pressFullScreen(self, id)
                  },
                  windowAttributes: attributes,
                  frontmostBundleID: { frontBundle },
                  frontmostPID: { front })
    }
}

private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

private func withDisplay<T>(_ body: () async throws -> T) async rethrows -> T {
    let old = DriveLoop.displayFrames
    DriveLoop.displayFrames = { [(frame: display, scale: 2)] }
    defer { DriveLoop.displayFrames = old }
    return try await body()
}

/// The diagnosis alone: facts in, cause out, for each of the nine causes
/// and the "it's right there" answer.
final class LostWindowDiagnosisTests: XCTestCase {
    private func facts(_ windows: [LostWindow.Window], running: Bool = true, hidden: Bool = false,
                       stageManager: Bool = false) -> LostWindow.Facts {
        LostWindow.Facts(app: "Mail", running: running, hidden: hidden, stageManager: stageManager,
                         displays: [display], windows: windows)
    }
    private let normal = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testMinimizedWindowIsInTheDock() {
        let cause = LostWindow.diagnose(facts([.init(id: 7, frame: normal, onScreen: false, minimized: true)]))
        XCTAssertEqual(cause, .minimized(window: 7))
        XCTAssertEqual(LostWindow.line(for: cause, app: "Mail", fixed: true),
                       "It was tucked into the Dock. Here it is.")
    }

    func testHiddenAppWinsOverItsOffscreenWindows() {
        let cause = LostWindow.diagnose(facts([.init(id: 7, frame: normal, onScreen: false, minimized: false)],
                                              hidden: true))
        XCTAssertEqual(cause, .hidden)
        XCTAssertEqual(LostWindow.line(for: cause, app: "Mail", fixed: true), "Mail was hidden. It's back.")
    }

    func testFullScreenByAttributeOrByDisplaySize() {
        let byAttribute = LostWindow.diagnose(facts([.init(id: 7, frame: normal, onScreen: false, fullScreen: true)]))
        XCTAssertEqual(byAttribute, .fullScreen(window: 7))
        let bySize = LostWindow.diagnose(facts([.init(id: 8, frame: display, onScreen: false)]))
        XCTAssertEqual(bySize, .fullScreen(window: 8))
        XCTAssertEqual(LostWindow.line(for: bySize, app: "Safari", fixed: true),
                       "Safari was full screen, on its own desktop. I brought you to it. Want me to make it a normal window so it stays with the others?")
        let zoomed = CGRect(x: 0, y: 25, width: 1440, height: 800)
        XCTAssertEqual(LostWindow.diagnose(facts([.init(id: 9, frame: zoomed, onScreen: false)])),
                       .otherDesktop(window: 9), "a zoomed window isn't full screen")
    }

    func testOffscreenUnexplainedWindowIsOnAnotherDesktop() {
        let cause = LostWindow.diagnose(facts([.init(id: 7, frame: normal, onScreen: false, minimized: false)]))
        XCTAssertEqual(cause, .otherDesktop(window: 7))
        XCTAssertEqual(LostWindow.line(for: cause, app: "Mail", fixed: true),
                       "It was on your other desktop. You're there now.")
    }

    func testWindowOutsideEveryDisplaySlidOffTheEdge() {
        let gone = CGRect(x: 2400, y: 200, width: 800, height: 600)
        let sliver = CGRect(x: 1400, y: 200, width: 800, height: 600)
        XCTAssertEqual(LostWindow.diagnose(facts([.init(id: 7, frame: gone, onScreen: true)])), .offEdge(window: 7))
        XCTAssertEqual(LostWindow.diagnose(facts([.init(id: 7, frame: sliver, onScreen: true)])), .offEdge(window: 7))
        XCTAssertEqual(LostWindow.line(for: .offEdge(window: 7), app: "Mail", fixed: true),
                       "It had slid off the screen. I moved it back.")
        let rescued = LostWindow.rescueFrame(for: CGRect(x: 2400, y: 200, width: 2000, height: 600), on: display)
        XCTAssertTrue(display.contains(rescued), "\(rescued)")
        XCTAssertEqual(rescued.height, 600)
    }

    func testCoveredWindowIsBehindTheOneOnTop() {
        let cause = LostWindow.diagnose(facts([.init(id: 7, frame: normal, onScreen: true, coveredBy: "Safari")]))
        XCTAssertEqual(cause, .behind(window: 7, coveredBy: "Safari"))
        XCTAssertEqual(LostWindow.line(for: cause, app: "Mail", fixed: true), "It was behind Safari. It's in front now.")
    }

    func testRunningAppWithNoWindowsWasClosed() {
        XCTAssertEqual(LostWindow.diagnose(facts([])), .closed)
        XCTAssertEqual(LostWindow.line(for: .closed, app: "Mail", fixed: true),
                       "The window was closed, so I opened a new one.")
    }

    func testNoProcessMeansTheAppQuit() {
        XCTAssertEqual(LostWindow.diagnose(facts([], running: false)), .quit)
        XCTAssertEqual(LostWindow.line(for: .quit, app: "Mail", fixed: true), "Mail had closed. I've opened it again.")
    }

    func testStageManagerExplainsAnOffscreenWindowNothingElseDoes() {
        let cause = LostWindow.diagnose(facts([.init(id: 7, frame: normal, onScreen: false, minimized: false)],
                                              stageManager: true))
        XCTAssertEqual(cause, .stageManager)
        XCTAssertEqual(LostWindow.line(for: cause, app: "Mail", fixed: false),
                       "Your windows are in Stage Manager, the strip on the left. Want me to turn that off?")
        // A minimized window is still the Dock's answer with Stage Manager on.
        XCTAssertEqual(LostWindow.diagnose(facts([.init(id: 7, frame: normal, onScreen: false, minimized: true)],
                                                 stageManager: true)), .minimized(window: 7))
    }

    func testVisibleUncoveredWindowIsAlreadyInFront() {
        let cause = LostWindow.diagnose(facts([
            .init(id: 6, frame: normal, onScreen: false, minimized: true),
            .init(id: 7, frame: normal, onScreen: true),
        ]))
        XCTAssertEqual(cause, .inFront(window: 7))
    }

    /// An unverified fix never claims success.
    func testUnverifiedLinesSaySoPlainly() {
        let causes: [LostWindow.Cause] = [.minimized(window: 1), .hidden, .fullScreen(window: 1),
                                          .otherDesktop(window: 1), .offEdge(window: 1),
                                          .behind(window: 1, coveredBy: "Safari"), .closed, .quit]
        for cause in causes {
            let fixed = LostWindow.line(for: cause, app: "Mail", fixed: true)
            let failed = LostWindow.line(for: cause, app: "Mail", fixed: false)
            XCTAssertNotEqual(fixed, failed, "\(cause)")
            XCTAssertTrue(failed.contains("couldn't") || failed.contains("didn't") || failed.contains("can't"),
                          "\(cause): \(failed)")
        }
    }
}

/// The whole lane: "where did X go" reads the desk, applies the cause's
/// fix through the production seams, and speaks only after the readback.
final class LostWindowLocateTests: XCTestCase {
    private let normal = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func run(_ desk: FakeDesk, _ goal: String, apps: [AppResolver.App] = [],
                     front: Int? = nil) async -> DriveResult {
        await withDisplay {
            await desk.loop(apps: apps, front: front).run(DriveTask(goal: goal), session: "t")
        }
    }

    private func said(_ result: DriveResult) -> String {
        if case .blocked(let reason) = result.status { return reason }
        return result.history.last ?? ""
    }

    func testMinimizedWindowComesBackFromTheDock() async {
        let desk = FakeDesk()
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal,
                              onScreen: false, minimized: true)]
        let result = await run(desk, "where did mail go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "It was tucked into the Dock. Here it is.")
        XCTAssertEqual(desk.steps, ["unminimize 7", "activate 42"])
    }

    func testMinimizedWindowThatStaysDockedIsReportedHonestly() async {
        let desk = FakeDesk()
        desk.unminimizeWorks = false
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal,
                              onScreen: false, minimized: true)]
        let result = await run(desk, "where did mail go")
        guard case .blocked = result.status else { return XCTFail("expected blocked, got \(result.status)") }
        XCTAssertTrue(said(result).hasPrefix("It's tucked into the Dock, but it didn't come back."), said(result))
    }

    func testHiddenAppIsUnhidden() async {
        let desk = FakeDesk()
        desk.hidden = [42]
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal, onScreen: false)]
        let result = await run(desk, "where did mail go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "Mail was hidden. It's back.")
        XCTAssertEqual(desk.steps, ["unhide 42", "activate 42"])
    }

    func testFullScreenWindowTakesYouToItsDesktopAndOffersToExit() async {
        let desk = FakeDesk()
        desk.windows = [.init(id: 7, pid: 42, app: "Safari", title: "Apple", frame: display, onScreen: false)]
        desk.onActivate = { desk, _ in desk.windows[0].onScreen = true }
        let result = await run(desk, "where did safari go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "Safari was full screen, on its own desktop. I brought you to it. Want me to make it a normal window so it stays with the others?")
        XCTAssertEqual(desk.steps, ["activate 42"])
        XCTAssertFalse(desk.steps.contains("AXFullScreen"), "exiting full screen is an offer, not done unasked")
    }

    func testWindowOnAnotherDesktopIsReachedByActivation() async {
        let desk = FakeDesk()
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal,
                              onScreen: false, minimized: false)]
        desk.onActivate = { desk, _ in desk.windows[0].onScreen = true }
        let result = await run(desk, "where did mail go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "It was on your other desktop. You're there now.")
        XCTAssertEqual(desk.steps, ["activate 42"])
    }

    func testDesktopSwitchThatNeverArrivesIsNotClaimed() async {
        let desk = FakeDesk()
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal, onScreen: false)]
        let result = await run(desk, "where did mail go")
        guard case .blocked = result.status else { return XCTFail("expected blocked, got \(result.status)") }
        XCTAssertEqual(said(result), "It's on another desktop, and I couldn't take you there.")
    }

    func testWindowOffTheEdgeIsMovedOntoTheMainScreen() async {
        let desk = FakeDesk()
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox",
                              frame: CGRect(x: 2600, y: 300, width: 800, height: 600))]
        let result = await run(desk, "where did mail go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "It had slid off the screen. I moved it back.")
        XCTAssertEqual(desk.steps, ["move 7", "activate 42"])
        XCTAssertEqual(desk.frameWrites.count, 1)
        XCTAssertTrue(display.contains(desk.frameWrites[0]), "\(desk.frameWrites)")
    }

    func testBuriedWindowIsRaisedAboveTheOneCoveringIt() async {
        let desk = FakeDesk()
        desk.windows = [
            .init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal, z: 1),
            .init(id: 9, pid: 50, app: "Safari", title: "Apple", frame: CGRect(x: 0, y: 0, width: 1200, height: 800), z: 5),
        ]
        let result = await run(desk, "where did mail go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "It was behind Safari. It's in front now.")
        XCTAssertEqual(desk.steps, ["raise 7", "activate 42"])
    }

    func testClosedWindowIsReopenedThroughTheApp() async {
        let desk = FakeDesk()
        desk.onReopen = { desk, pid in
            desk.windows.append(.init(id: 11, pid: pid, app: "Mail", title: "Inbox", frame: CGRect(x: 100, y: 100, width: 800, height: 600)))
        }
        let result = await run(desk, "where did mail go",
                               apps: [.init(name: "Mail", bundle: "com.apple.mail", pid: 42)])
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "The window was closed, so I opened a new one.")
        XCTAssertEqual(desk.steps.first, "reopen 42")
    }

    /// TextEdit ships in /System/Applications on every Mac, so the resolver
    /// finds it installed and not running without anything launching.
    func testQuitAppIsOpenedAgain() async {
        let desk = FakeDesk()
        desk.onLaunch = { desk, _ in
            desk.windows.append(.init(id: 12, pid: 77, app: "TextEdit", title: "Untitled", frame: CGRect(x: 100, y: 100, width: 800, height: 600)))
            return 77
        }
        let result = await run(desk, "where did textedit go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "TextEdit had closed. I've opened it again.")
        XCTAssertEqual(desk.steps.first, "launch com.apple.TextEdit")
    }

    func testStageManagerIsExplainedAndNothingIsChanged() async {
        let desk = FakeDesk()
        desk.stageManager = true
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal,
                              onScreen: false, minimized: false)]
        let result = await run(desk, "where did mail go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "Your windows are in Stage Manager, the strip on the left. Want me to turn that off?")
        XCTAssertEqual(desk.steps, [])
        XCTAssertFalse(result.dispatchedEffect)
    }

    func testVisibleWindowIsAlreadyThere() async {
        let desk = FakeDesk()
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal)]
        let result = await run(desk, "where did mail go")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "Mail is already on your screen, in front.")
        XCTAssertEqual(desk.steps, [])
    }

    /// "where did my window go" names no app: the app in front is the one
    /// the person was using, so its minimized window is the answer.
    func testMyWindowMeansTheAppInFront() async {
        let desk = FakeDesk()
        desk.windows = [
            .init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal, onScreen: false, minimized: true),
            .init(id: 9, pid: 50, app: "Safari", title: "Apple", frame: normal, onScreen: false, minimized: true),
        ]
        let result = await run(desk, "where did my window go", front: 42)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "It was tucked into the Dock. Here it is.")
        XCTAssertEqual(desk.steps, ["unminimize 7", "activate 42"])
    }

    func testEverythingDisappearedAsksWhenTheFrontAppIsFine() async {
        let desk = FakeDesk()
        desk.windows = [.init(id: 7, pid: 42, app: "Mail", title: "Inbox", frame: normal)]
        let result = await run(desk, "everything disappeared", front: 42)
        guard case .blocked(let reason) = result.status else { return XCTFail("expected blocked, got \(result.status)") }
        XCTAssertEqual(reason, DriveLoop.whichAppLine)
        XCTAssertEqual(desk.steps, [])
    }

    func testEverythingDisappearedInStageManagerExplainsIt() async {
        let desk = FakeDesk()
        desk.stageManager = true
        desk.windows = [.init(id: 7, pid: 42, app: "Finder", title: "", frame: normal)]
        let result = await run(desk, "everything disappeared", front: 42)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "Your windows are in Stage Manager, the strip on the left. Want me to turn that off?")
    }
}

/// The exit-full-screen ladder: attribute, button, View menu, ⌃⌘F — each
/// rung tried only after the one before it failed, each read back.
final class ExitFullScreenTests: XCTestCase {
    private func desk(fullScreen: Bool? = true) -> FakeDesk {
        let desk = FakeDesk()
        desk.windows = [.init(id: 7, pid: 42, app: "Safari", title: "Apple", frame: display,
                              fullScreen: fullScreen)]
        return desk
    }

    private func run(_ desk: FakeDesk, _ goal: String = "exit full screen") async -> DriveResult {
        await withDisplay {
            await desk.loop(frontBundle: "fixture.safari").run(DriveTask(goal: goal), session: "t")
        }
    }

    func testAttributeRungWorksAlone() async {
        let desk = desk()
        desk.setFullScreen = { desk, id in desk.exitFullScreen(id); return true }
        let result = await run(desk)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.history.last, "Safari is a normal window again.")
        XCTAssertEqual(desk.steps, ["AXFullScreen"])
    }

    func testButtonRungAfterTheAttributeFails() async {
        let desk = desk()
        desk.pressFullScreen = { desk, id in desk.exitFullScreen(id); return true }
        let result = await run(desk)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(desk.steps, ["AXFullScreen", "button fullscreen"])
    }

    /// The attribute write is accepted but doesn't take, the button is
    /// missing, and the View menu does it.
    func testMenuRungAfterAttributeAndButtonFail() async {
        let desk = desk()
        desk.setFullScreen = { _, _ in true }
        desk.menu = { desk, path in
            XCTAssertEqual(path, ["View", "Exit Full Screen"])
            desk.exitFullScreen(7)
        }
        let result = await run(desk)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(desk.steps, ["AXFullScreen", "button fullscreen", "menu View > Exit Full Screen"])
    }

    func testChordRungOnlyAfterEverythingElseFails() async {
        let desk = desk()
        desk.hotkey = { desk, keys in
            XCTAssertEqual(keys, ["ctrl", "cmd", "f"])
            desk.exitFullScreen(7)
        }
        let result = await run(desk, "the menu bar is gone")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(desk.steps, ["AXFullScreen", "button fullscreen", "menu View > Exit Full Screen",
                                    "hotkey ctrl+cmd+f"])
    }

    func testEveryRungFailingIsSaidPlainly() async {
        let desk = desk()
        let result = await run(desk)
        guard case .blocked(let reason) = result.status else { return XCTFail("expected blocked, got \(result.status)") }
        XCTAssertTrue(reason.hasPrefix("I couldn't take Safari out of full screen."), reason)
        XCTAssertEqual(desk.steps.count, 4)
        XCTAssertFalse(result.dispatchedEffect)
    }

    func testNormalWindowIsLeftAlone() async {
        let desk = desk(fullScreen: false)
        let result = await run(desk)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.history.last, "Safari isn't full screen right now.")
        XCTAssertEqual(desk.steps, [], "⌃⌘F on a normal window would put it INTO full screen")
    }

    /// Apps that don't publish AXFullScreen are judged by their bounds.
    func testUnreadableAttributeFallsBackToTheWindowBounds() async {
        let desk = desk(fullScreen: nil)
        desk.pressFullScreen = { desk, id in desk.exitFullScreen(id); return true }
        let result = await run(desk)
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(desk.steps, ["AXFullScreen", "button fullscreen"])
    }
}

/// The phrases: exit full screen in plain words, and "where did it go"
/// without an app name.
final class LostWindowPhraseTests: XCTestCase {
    func testExitFullScreenPhrases() {
        for phrase in ["exit full screen", "leave fullscreen", "get out of full screen",
                       "turn off full screen", "make it a normal window", "make this a normal window",
                       "the menu bar is gone", "my menu bar disappeared", "where is the menu bar",
                       "where did the menu bar go", "I can't see the menu bar", "bring back the menu bar",
                       "take it out of full screen"] {
            guard let parsed = FastAction.parse(phrase), case .exitFullScreen = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to exit full screen, got \(String(describing: FastAction.parse(phrase)?.action.body))")
                continue
            }
            XCTAssertNil(parsed.appQualifier, phrase)
        }
        guard let scoped = FastAction.parse("exit full screen in safari"),
              case .exitFullScreen = scoped.action.body else {
            return XCTFail("'exit full screen in safari' should parse")
        }
        XCTAssertEqual(scoped.appQualifier, "safari")
        guard let enter = FastAction.parse("enter full screen"), case .hotkey = enter.action.body else {
            return XCTFail("entering full screen keeps its chord")
        }
    }

    func testLocateWithoutAnAppName() {
        for (phrase, query) in [("where did my window go", ""), ("where did my windows go", ""),
                                ("everything disappeared", ""), ("where did everything go", ""),
                                ("my window disappeared", ""), ("all my windows are gone", ""),
                                ("I lost my window", ""), ("find my window", ""),
                                ("where did mail go", "mail"), ("I lost my notes", "notes")] {
            guard let parsed = FastAction.parse(phrase), case .locate(let q) = parsed.action.body else {
                XCTFail("'\(phrase)' should parse to locate"); continue
            }
            XCTAssertEqual(q, query, phrase)
        }
        for phrase in ["the sound is gone", "where is it", "my notes disappeared"] {
            if let parsed = FastAction.parse(phrase), case .locate = parsed.action.body {
                XCTFail("'\(phrase)' must not hunt for a window")
            }
        }
    }
}
