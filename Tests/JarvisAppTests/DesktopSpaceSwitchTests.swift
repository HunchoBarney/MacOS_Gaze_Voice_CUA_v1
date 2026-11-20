import XCTest
@testable import Jarvis
import JarvisCore

private let english = DesktopSpaceSwitch.Labels(
    desktop: "Desktop %@", wrappers: ["exit to %@", "select %@"],
    fullScreenWrappers: ["exit to full screen %@", "select full screen %@"])

/// A layout as SkyLight reports it: one display, spaces in order, type 0 a
/// desktop and 4 a full-screen app. Ids are 11, 12, 13…
private func layout(_ types: [Int], active: Int) -> DesktopSpaceSwitch.Layout? {
    let spaces: [[String: Any]] = types.enumerated().map { ["id64": NSNumber(value: 11 + $0.offset), "type": NSNumber(value: $0.element)] }
    return DesktopSpaceSwitch.Layout(displays: [["Display Identifier": "Main", "Spaces": spaces]],
                                     active: UInt64(11 + active))
}

/// The archived KAR-6 tests, restored: Mission Control's tree as injected
/// Int hierarchies, the open-then-wait path, and every refusal.
final class DesktopSpaceSwitchTreeTests: XCTestCase {
    func testWaitsForAnOpenedEmptyListWithoutRelaunching() async {
        var inspections = 0, opens = 0, presses: [Int] = []
        let result = await DesktopSpaceSwitch.perform(name: "Desktop 2", invalidation: { nil }, inspect: {
            inspections += 1
            let edges = [0: inspections == 1 ? [7] : [1], 1: [2], 2: [3], 3: [4], 4: inspections == 2 ? [] : [5]]
            let attrs: [Int: [String: Any]] = [
                1: ["AXIdentifier": "mc"], 2: ["AXIdentifier": "mc.display", "AXDisplayID": 9],
                3: ["AXIdentifier": "mc.spaces"], 4: ["AXIdentifier": "mc.spaces.list", "AXRole": "AXList"],
                5: ["AXDescription": "exit to Desktop 2", "AXRole": "AXButton"], 7: ["AXRole": "AXList"]
            ]
            return DesktopSpaceSwitch.overview(root: 0, displayID: 9, accept: { $0 == "exit to Desktop 2" },
                children: { edges[$0] }, attr: { attrs[$0]?[$1] }, pressable: { _ in true })
        }, open: { opens += 1 }, pause: {}, press: { presses.append($0); return true }, note: { _ in })
        XCTAssertEqual(inspections, 4); XCTAssertEqual(opens, 1); XCTAssertEqual(presses, [5])
        XCTAssertEqual(result.code, .pressAcceptedUnverified)
        XCTAssertEqual(result.origin, .launchRequested)
    }

    /// The Dock's own "Desktop %@" and "exit to %@" strings, read from its
    /// bundle (a file read; nothing is opened or pressed).
    func testInspectorClassifiesTheFirstFailingRead() throws {
        let dock = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app")))
        let desktop = dock.localizedString(forKey: "DesktopNum", value: "", table: "Localizable")
        let exit = dock.localizedString(forKey: "AXExitToDesktop", value: "", table: "Accessibility")
        XCTAssertEqual(desktop.components(separatedBy: "%@").count, 2)
        XCTAssertEqual(exit.components(separatedBy: "%@").count, 2)
        let expected = exit.replacingOccurrences(of: "%@", with: desktop.replacingOccurrences(of: "%@", with: "2"))
        let labels = DesktopSpaceSwitch.Labels(desktop: desktop, wrappers: [exit], fullScreenWrappers: [])
        XCTAssertEqual(DesktopSpaceSwitch.space(expected, labels: labels), .desktop(2))
        var edges = [0: [1], 1: [2], 2: [3], 3: [4], 4: [6, 5]]
        var attributes: [Int: [String: Any]] = [
            1: ["AXIdentifier": "mc"], 2: ["AXIdentifier": "mc.display", "AXDisplayID": NSNumber(value: 9)],
            3: ["AXIdentifier": "mc.spaces"], 4: ["AXIdentifier": "mc.spaces.list", "AXRole": "AXList"],
            5: ["AXRole": "AXButton", "AXDescription": expected], 6: ["AXRole": "AXButton", "AXDescription": "fixture"],
            7: ["AXRole": "AXList"]
        ]
        var allow = true, checked: [Int] = []
        func inspect(displayID: UInt32 = 9) -> DesktopSpaceSwitch.Overview<Int> {
            checked = []
            return DesktopSpaceSwitch.overview(root: 0, displayID: displayID, accept: {
                    DesktopSpaceSwitch.matches(DesktopSpaceSwitch.space($0, labels: labels), .desktop(2))
                }, children: { edges[$0] },
                attr: { attributes[$0]?[$1] }, pressable: { checked.append($0); return allow })
        }
        func refusal(_ code: DesktopSpaceSwitch.Code, checked count: Int = 0, displayID: UInt32 = 9, line: UInt = #line) {
            switch inspect(displayID: displayID) {
            case .openWithoutTarget(let observed), .unavailable(let observed): XCTAssertEqual(observed, code, line: line)
            default: XCTFail("Expected refusal", line: line)
            }
            XCTAssertEqual(checked.count, count, line: line)
        }
        guard case .target(5) = inspect() else { return XCTFail("Unique target not resolved") }
        XCTAssertEqual(checked, [5])
        let aliases: [(NSNumber, UInt32)] = [
            (NSNumber(value: UInt64(4_294_967_305)), 9), (NSNumber(value: 9.5), 9),
            (NSNumber(value: true), 1), (NSNumber(value: Int64(-1)), .max), (NSNumber(value: 0), 0)
        ]
        for (raw, captured) in aliases {
            attributes[2]?["AXDisplayID"] = raw
            refusal(.displayBindingUnavailable, displayID: captured)
        }
        attributes[2]?["AXDisplayID"] = NSNumber(value: UInt32.max)
        guard case .target(5) = inspect(displayID: .max) else { return XCTFail("Valid UInt32 refused") }
        attributes[2]?["AXDisplayID"] = NSNumber(value: 9)
        allow = false; refusal(.targetNotPressable, checked: 1)
        attributes[6]?["AXDescription"] = expected; refusal(.targetAmbiguous)
        attributes[5]?["AXDescription"] = nil; refusal(.malformedThumbnail)
        edges[4] = []; refusal(.emptySpacesList)
        edges[4] = nil; refusal(.spacesListUnavailable)
        edges[2] = []; refusal(.spacesGroupUnavailable)
        attributes[2]?["AXDisplayID"] = NSNumber(value: 99); refusal(.displayBindingUnavailable)
        edges[1] = nil; refusal(.overviewUnreadable)
        edges[0] = [7]; guard case .closed = inspect() else { return XCTFail("Expected closed overview") }
        attributes[7]?["AXRole"] = "AXGroup"; refusal(.rootUnrecognized)
        edges[0] = nil; refusal(.rootUnreadable)
    }

    func testPressBoundaries() async {
        let expected = "quitter vers Bureau 2"
        let rows = [("quitter vers Bureau 2 en plein écran", 10), (expected, 41), ("quitter vers Bureau 1", 72)]
        let exact: (String) -> Bool = { $0 == expected }
        typealias State = DesktopSpaceSwitch.Overview<Int>
        func run(_ states: [State], authorized: Bool = true, revokeOnOpen: Bool = false,
                 openFails: Bool = false, pollFails: Bool = false, pressAccepted: Bool = true)
            async -> (opens: Int, presses: [Int], notes: [String], message: String, code: DesktopSpaceSwitch.Code, origin: DesktopSpaceSwitch.Origin?) {
            var states = states, current = authorized, opens = 0, presses: [Int] = [], notes: [String] = []
            let result = await DesktopSpaceSwitch.perform(name: "Desktop 2", invalidation: { current ? nil : .displayChanged },
                inspect: { states.isEmpty ? .unavailable(.rootUnreadable) : states.removeFirst() },
                open: { opens += 1; if openFails { throw CancellationError() }; if revokeOnOpen { current = false } },
                pause: { if pollFails { throw CancellationError() } }, press: {
                    presses.append($0); return pressAccepted
                }, note: { notes.append($0) })
            return (opens, presses, notes, result.message, result.code, result.origin)
        }
        let target = DesktopSpaceSwitch.matchButton(rows, where: exact)
        let delivered = await run([.closed, .closed, target, target])
        XCTAssertEqual(delivered.code, .pressAcceptedUnverified)
        XCTAssertEqual(delivered.opens, 1); XCTAssertEqual(delivered.presses, [41])
        XCTAssertTrue(delivered.message.contains("Switch unverified"))
        XCTAssertTrue(delivered.message.contains("Mission Control may be open"))
        XCTAssertTrue(delivered.notes.last?.contains("Mission Control may be open") == true)
        XCTAssertTrue(delivered.notes.last?.contains("selection may have been sent") == true)
        let existing = await run([.target(41), .target(41)])
        XCTAssertEqual(existing.origin, .startedOpen)
        XCTAssertEqual(existing.opens, 0); XCTAssertEqual(existing.presses, [41])
        let revoked = await run([.closed, .target(41)], revokeOnOpen: true)
        XCTAssertEqual(revoked.opens, 1); XCTAssertTrue(revoked.presses.isEmpty)
        XCTAssertTrue(revoked.message.contains("Mission Control may be open"))
        XCTAssertTrue(revoked.notes.first?.contains("Mission Control") == true)
        XCTAssertEqual(revoked.code, .displayChanged)
        let refused = await run([target, target], pressAccepted: false)
        XCTAssertEqual(refused.code, .pressRefused); XCTAssertEqual(refused.presses, [41])
        let cases: [([State], DesktopSpaceSwitch.Code, Int)] = [
            ([.unavailable(.rootUnrecognized)], .rootUnrecognized, 0),
            ([DesktopSpaceSwitch.matchButton(rows + [(expected, 32)], where: exact)], .targetAmbiguous, 0),
            ([DesktopSpaceSwitch.matchButton(rows.map(Optional.some) + [nil], where: exact)], .malformedThumbnail, 0),
            ([.closed, DesktopSpaceSwitch.matchButton(rows, where: { $0 == "exit to Desktop 2" })], .targetMissing, 1),
            ([target, .unavailable(.spacesListUnavailable)], .spacesListUnavailable, 0),
            ([target, .closed], .overviewClosedOnRecheck, 0), ([target, .target(42)], .targetChanged, 0),
            ([.openWithoutTarget(.emptySpacesList), target], .emptySpacesList, 0),
            ([.closed, .openWithoutTarget(.emptySpacesList), .closed, target], .overviewClosedOnRecheck, 1),
            ([.closed, .unavailable(.displayBindingUnavailable), target], .displayBindingUnavailable, 1),
            ([.closed] + Array(repeating: .openWithoutTarget(.emptySpacesList), count: 12) + [target], .emptySpacesList, 1),
            (Array(repeating: .closed, count: 13), .overviewNotReady, 1)
        ]
        for (states, code, opens) in cases {
            let result = await run(states)
            XCTAssertEqual(result.code, code); XCTAssertEqual(result.opens, opens); XCTAssertTrue(result.presses.isEmpty)
            switch states.first {
            case .target?, .openWithoutTarget?: XCTAssertEqual(result.origin, .startedOpen)
            case .closed?: XCTAssertEqual(result.origin, .launchRequested)
            default: XCTAssertNil(result.origin)
            }
        }
        let denied = await run([.closed], authorized: false)
        XCTAssertEqual(denied.code, .displayChanged); XCTAssertEqual(denied.opens, 0); XCTAssertTrue(denied.presses.isEmpty)
        let launch = await run([.closed], openFails: true)
        XCTAssertEqual(launch.code, .openFailed); XCTAssertEqual(launch.opens, 1); XCTAssertTrue(launch.presses.isEmpty)
        let poll = await run([.closed, .closed], pollFails: true)
        XCTAssertEqual(poll.code, .pollInterrupted); XCTAssertEqual(poll.opens, 1); XCTAssertTrue(poll.presses.isEmpty)
    }

    /// macOS 27 moves the tree to WindowManager; the closed Dock list must
    /// not hide it, and a WindowManager that shows nothing must not hide
    /// the Dock.
    func testWindowManagerTreeIsFoundBesideTheClosedDock() {
        let edges = [0: [1], 100: [110], 110: [111], 111: [112], 112: [113], 113: [120, 121]]
        let attrs: [Int: [String: Any]] = [
            1: ["AXRole": "AXList"],
            110: ["AXIdentifier": "mc"], 111: ["AXIdentifier": "mc.display", "AXDisplayID": 9],
            112: ["AXIdentifier": "mc.spaces"], 113: ["AXIdentifier": "mc.spaces.list", "AXRole": "AXList"],
            120: ["AXRole": "AXButton", "AXDescription": "exit to Desktop 1"],
            121: ["AXRole": "AXButton", "AXDescription": "exit to Desktop 2"]
        ]
        func probe(_ roots: [Int], _ edges: [Int: [Int]]) -> DesktopSpaceSwitch.Overview<Int> {
            DesktopSpaceSwitch.probe(roots: roots, displayID: 9, accept: {
                    DesktopSpaceSwitch.matches(DesktopSpaceSwitch.space($0, labels: english), .desktop(2))
                }, children: { edges[$0] }, attr: { attrs[$0]?[$1] }, pressable: { _ in true })
        }
        guard case .target(121) = probe([0, 100], edges) else { return XCTFail("WindowManager's Desktop 2 not found") }
        var closedEverywhere = edges
        closedEverywhere[100] = []
        guard case .closed = probe([0, 100], closedEverywhere) else { return XCTFail("closed Dock must read closed") }
        guard case .unavailable(.treeUnavailable) = probe([], edges) else { return XCTFail("no trees") }
    }

    func testButtonNamesForDesktopsAndFullScreenApps() {
        XCTAssertEqual(DesktopSpaceSwitch.space("exit to Desktop 2", labels: english), .desktop(2))
        XCTAssertEqual(DesktopSpaceSwitch.space("Desktop 12", labels: english), .desktop(12))
        XCTAssertEqual(DesktopSpaceSwitch.space("select Desktop 3", labels: english), .desktop(3))
        XCTAssertEqual(DesktopSpaceSwitch.space("exit to full screen Safari", labels: english), .fullScreen("Safari"))
        XCTAssertNil(DesktopSpaceSwitch.space("exit to Desktop", labels: english))
        XCTAssertNil(DesktopSpaceSwitch.space("add desktop", labels: english))
        let french = DesktopSpaceSwitch.Labels(desktop: "Bureau %@", wrappers: ["quitter vers %@"],
                                               fullScreenWrappers: ["quitter vers le plein écran %@"])
        XCTAssertEqual(DesktopSpaceSwitch.space("quitter vers Bureau 2", labels: french), .desktop(2))
        XCTAssertEqual(DesktopSpaceSwitch.space("quitter vers le plein écran Safari", labels: french), .fullScreen("Safari"))
        XCTAssertTrue(DesktopSpaceSwitch.matches(.fullScreen("Safari"), .fullScreen("safari")))
        XCTAssertTrue(DesktopSpaceSwitch.matches(.fullScreen("Apple – Safari"), .fullScreen("Safari")))
        XCTAssertFalse(DesktopSpaceSwitch.matches(.fullScreen("Safaricom"), .fullScreen("Safari")))
        XCTAssertFalse(DesktopSpaceSwitch.matches(.desktop(12), .desktop(2)))
    }

    func testSkyLightLayoutAndShortcutPreferences() {
        let mixed = layout([0, 4, 0], active: 2)
        XCTAssertEqual(mixed?.desktops, [11, 13])
        XCTAssertEqual(mixed?.currentNumber, 2)
        XCTAssertNil(layout([0, 4, 0], active: 1)?.currentNumber, "a full-screen app has no desktop number")
        XCTAssertNil(DesktopSpaceSwitch.Layout(displays: [["Spaces": []], ["Spaces": []]], active: 11))
        XCTAssertNil(layout([0, 0], active: 5), "an active space the list doesn't hold is no answer")
        let on: [String: Any] = ["79": ["enabled": true, "value": ["parameters": [65535, 123, 8650752]]],
                                 "81": ["enabled": true, "value": ["parameters": [65535, 124, 8650752]]]]
        XCTAssertTrue(DesktopSpaceSwitch.shortcutEnabled(.previous, hotkeys: on))
        XCTAssertTrue(DesktopSpaceSwitch.shortcutEnabled(.next, hotkeys: on))
        XCTAssertTrue(DesktopSpaceSwitch.shortcutEnabled(.next, hotkeys: nil), "on by default")
        let off: [String: Any] = ["81": ["enabled": false, "value": ["parameters": [65535, 124, 8650752]]]]
        XCTAssertFalse(DesktopSpaceSwitch.shortcutEnabled(.next, hotkeys: off))
        let rebound: [String: Any] = ["79": ["enabled": true, "value": ["parameters": [65535, 123, 1048576]]]]
        XCTAssertFalse(DesktopSpaceSwitch.shortcutEnabled(.previous, hotkeys: rebound), "⌘← isn't ⌃←")
    }
}

/// A pretend Mission Control, SkyLight and shortcut preference behind the
/// production seam. Dock root 0 and WindowManager root 100; when open, the
/// tree hangs under whichever host is set. `steps` records every open,
/// press and key in order.
private final class FakeSpaces {
    enum Host { case dock, windowManager }
    var host = Host.dock
    var open = false
    var buttons = ["exit to Desktop 1", "exit to Desktop 2"]
    /// What SkyLight would say; nil when its symbols don't load.
    var sky: DesktopSpaceSwitch.Layout?
    var shortcuts: [DesktopSpaceSwitch.Direction: Bool] = [:]
    var screens = 1
    var arrives = true
    var closesOnPress = true
    var lands = true
    var moved = false
    var steps: [String] = []

    private var base: Int { host == .dock ? 10 : 110 }

    func children(_ node: Int) -> [Int]? {
        switch node {
        case 0: return open && host == .dock ? [10] : [1]
        case 100: return open && host == .windowManager ? [110] : []
        case base: return [base + 1]
        case base + 1: return [base + 2]
        case base + 2: return [base + 3]
        case base + 3: return buttons.indices.map { base + 10 + $0 }
        default: return nil
        }
    }

    func attr(_ node: Int, _ key: String) -> Any? {
        let attributes: [String: Any]
        switch node {
        case 1: attributes = ["AXRole": "AXList"]
        case base: attributes = ["AXIdentifier": "mc"]
        case base + 1: attributes = ["AXIdentifier": "mc.display", "AXDisplayID": NSNumber(value: 9)]
        case base + 2: attributes = ["AXIdentifier": "mc.spaces"]
        case base + 3: attributes = ["AXIdentifier": "mc.spaces.list", "AXRole": "AXList"]
        default:
            guard buttons.indices.contains(node - base - 10) else { return nil }
            attributes = ["AXRole": "AXButton", "AXDescription": buttons[node - base - 10]]
        }
        return attributes[key]
    }

    private func land(on id: UInt64?) {
        guard lands else { return }
        moved = true
        if let id { sky?.active = id }
    }

    var system: DesktopSpaceSwitch.System {
        DesktopSpaceSwitch.System(
            roots: { [0, 100] },
            children: { self.children($0.base as! Int)?.map(AnyHashable.init) },
            attr: { self.attr($0.base as! Int, $1) },
            pressable: { _ in true },
            press: { node in
                let label = self.buttons[(node.base as! Int) - self.base - 10]
                self.steps.append("press \(label)")
                if self.closesOnPress { self.open = false }
                switch DesktopSpaceSwitch.space(label, labels: english) {
                case .desktop(let n)?: self.land(on: self.sky.map { $0.desktops[n - 1] })
                default: self.land(on: self.sky?.spaces.first(where: \.fullScreen)?.id)
                }
                return true
            },
            displayID: { self.screens == 1 ? 9 : nil },
            labels: { english },
            openMissionControl: {
                self.steps.append("open Mission Control")
                self.open = true
            },
            pause: {},
            watchSpaceChange: {
                self.steps.append("watch")
                return { _ in self.arrives && self.moved }
            },
            layout: { self.sky },
            shortcutEnabled: { self.shortcuts[$0] ?? true })
    }

    func call(_ tool: String, _ args: [String: JSONValue]) throws -> JSONValue {
        if tool == "hotkey" {
            let keys = args["keys"]?.array?.compactMap(\.string) ?? []
            steps.append("hotkey \(keys.joined(separator: "+"))")
            if let sky, let index = sky.currentIndex {
                let target = keys.last == "right" ? index + 1 : index - 1
                if sky.spaces.indices.contains(target) { land(on: sky.spaces[target].id) }
            } else {
                land(on: nil)
            }
        }
        return .object(["effect": .string("confirmed")])
    }

    func say(_ goal: String) async -> String { said(await run(goal)) }

    func run(_ goal: String) async -> DriveResult {
        let loop = DriveLoop(call: { t, a in try self.call(t, a) },
                             choose: { _, _ in nil }, ask: nil, granted: { true },
                             resolver: AppResolver(exactBundleApps: { _ in [] }, listApps: { [] }),
                             desktopSpaces: system)
        return await loop.run(DriveTask(goal: goal), session: "t")
    }
}

private func said(_ result: DriveResult) -> String {
    if case .blocked(let reason) = result.status { return reason }
    return result.history.last ?? ""
}

/// The whole lane: phrase in, Mission Control or ⌃ arrow through the seam,
/// and words only after the arrival reads back.
final class DesktopSwitchLaneTests: XCTestCase {
    func testSwitchOpensMissionControlPressesOnceAndConfirmsArrival() async {
        let desk = FakeSpaces()
        let result = await desk.run("go to Desktop 2")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "You're on Desktop 2 now.")
        XCTAssertEqual(desk.steps, ["open Mission Control", "watch", "press exit to Desktop 2"])
        XCTAssertTrue(result.dispatchedEffect)
    }

    func testSwitchOnWindowManagerTree() async {
        let desk = FakeSpaces()
        desk.host = .windowManager
        let result = await desk.run("switch to desktop two")
        XCTAssertEqual(said(result), "You're on Desktop 2 now.")
        XCTAssertEqual(desk.steps, ["open Mission Control", "watch", "press exit to Desktop 2"])
    }

    func testNoNotificationMeansNotSure() async {
        let desk = FakeSpaces()
        desk.arrives = false
        let result = await desk.run("go to Desktop 2")
        guard case .blocked = result.status else { return XCTFail("expected blocked, got \(result.status)") }
        XCTAssertEqual(said(result), "I asked to switch, but I'm not sure it moved.")
        XCTAssertEqual(desk.steps.filter { $0.hasPrefix("press") }.count, 1, "never pressed twice")
    }

    func testMissionControlStayingOpenMeansNotSure() async {
        let desk = FakeSpaces()
        desk.closesOnPress = false
        let result = await desk.run("go to Desktop 2")
        XCTAssertEqual(said(result), "I asked to switch, but I'm not sure it moved.")
    }

    func testSkyLightReadBackDecidesArrivalExactly() async {
        let desk = FakeSpaces()
        desk.sky = layout([0, 0], active: 0)
        let good = await desk.run("go to Desktop 2")
        XCTAssertEqual(said(good), "You're on Desktop 2 now.")
        let wrong = FakeSpaces()
        wrong.sky = layout([0, 0], active: 0)
        wrong.lands = false
        wrong.moved = true
        let result = await wrong.run("go to Desktop 2")
        XCTAssertEqual(said(result), "I asked to switch, but I'm not sure it moved.")
    }

    func testAlreadyThereAndNoSuchDesktop() async {
        let desk = FakeSpaces()
        desk.sky = layout([0, 0], active: 1)
        let heard1 = await desk.say("go to Desktop 2")
        XCTAssertEqual(heard1, "You're already on Desktop 2.")
        let heard2 = await desk.say("go to Desktop 5")
        XCTAssertEqual(heard2, "You have 2 desktops, so there's no Desktop 5.")
        XCTAssertEqual(desk.steps, [])
    }

    func testMissingDesktopIsSaidWithHowToClose() async {
        let desk = FakeSpaces()
        let result = await desk.run("go to Desktop 3")
        XCTAssertEqual(said(result), "I couldn't find Desktop 3 in Mission Control. Press Escape to close Mission Control.")
        XCTAssertFalse(desk.steps.contains { $0.hasPrefix("press") })
    }

    func testOtherDesktopWithTwoGoesToTheOneYoureNotOn() async {
        let desk = FakeSpaces()
        desk.sky = layout([0, 0], active: 1)
        let result = await desk.run("switch to my other desktop")
        XCTAssertEqual(said(result), "You're on Desktop 1 now.")
        XCTAssertEqual(desk.steps, ["open Mission Control", "watch", "press exit to Desktop 1"])
    }

    func testOtherDesktopWithThreeAsksWhichAndShowsMissionControl() async {
        let desk = FakeSpaces()
        desk.buttons = ["exit to Desktop 1", "exit to Desktop 2", "exit to Desktop 3"]
        desk.sky = layout([0, 0, 0], active: 0)
        let result = await desk.run("go to the other desktop")
        guard case .blocked = result.status else { return XCTFail("expected a question, got \(result.status)") }
        XCTAssertEqual(said(result), "Which one: 2 or 3?")
        XCTAssertEqual(desk.steps, ["open Mission Control"])
    }

    func testOtherDesktopWithoutSkyLightAsksForTheNumber() async {
        let desk = FakeSpaces()
        let result = await desk.run("other desktop")
        XCTAssertEqual(said(result), "Which desktop? Say its number, like 'Desktop 2'.")
        XCTAssertEqual(desk.steps, ["open Mission Control"])
    }

    func testFullScreenAppByName() async {
        let desk = FakeSpaces()
        desk.buttons = ["exit to Desktop 1", "exit to full screen Safari", "exit to full screen Notes"]
        desk.sky = layout([0, 4, 4], active: 0)
        let result = await desk.run("go to my full-screen Safari")
        XCTAssertEqual(said(result), "You're on full-screen Safari now.")
        XCTAssertEqual(desk.steps, ["open Mission Control", "watch", "press exit to full screen Safari"])
    }

    func testNextAndPreviousUseTheShortcutWhenItsOn() async {
        let desk = FakeSpaces()
        desk.sky = layout([0, 0, 0], active: 0)
        let heard3 = await desk.say("next desktop")
        XCTAssertEqual(heard3, "You're on Desktop 2 now.")
        let heard4 = await desk.say("go to the previous desktop")
        XCTAssertEqual(heard4, "You're on Desktop 1 now.")
        XCTAssertEqual(desk.steps, ["watch", "hotkey ctrl+right", "watch", "hotkey ctrl+left"])
        let heard5 = await desk.say("previous desktop")
        XCTAssertEqual(heard5, "You're already on the first desktop.")
        let plain = FakeSpaces()
        let heard6 = await plain.say("next desktop")
        XCTAssertEqual(heard6, "You're on the next desktop now.")
        plain.arrives = false
        let heard7 = await plain.say("previous space")
        XCTAssertEqual(heard7, "I asked to switch, but I'm not sure it moved.")
    }

    func testNextAndPreviousFallBackToMissionControlWhenTheShortcutIsOff() async {
        let desk = FakeSpaces()
        desk.shortcuts = [.next: false, .previous: false]
        desk.sky = layout([0, 0], active: 0)
        let heard8 = await desk.say("next desktop")
        XCTAssertEqual(heard8, "You're on Desktop 2 now.")
        XCTAssertEqual(desk.steps, ["open Mission Control", "watch", "press exit to Desktop 2"])
        let blind = FakeSpaces()
        blind.shortcuts = [.previous: false]
        let result = await blind.run("previous desktop")
        XCTAssertEqual(said(result), "Your desktops are along the top of the screen. Click the one you want.")
        XCTAssertEqual(blind.steps, ["open Mission Control"])
    }

    func testWhichDesktopWithAndWithoutSkyLight() async {
        let desk = FakeSpaces()
        desk.sky = layout([0, 0, 0], active: 2)
        let heard9 = await desk.say("Which desktop am I on?")
        XCTAssertEqual(heard9, "You're on Desktop 3.")
        XCTAssertEqual(desk.steps, [], "a read needs no Mission Control")
        desk.sky = layout([0, 4], active: 1)
        let heard10 = await desk.say("what desktop is this")
        XCTAssertEqual(heard10, "You're in a full-screen app. It has a desktop of its own.")
        let blind = FakeSpaces()
        let heard11 = await blind.say("which desktop am i on")
        XCTAssertEqual(heard11, "The one with the white outline is where you are.")
        XCTAssertEqual(blind.steps, ["open Mission Control"])
    }

    func testShowMeMyDesktopsOpensMissionControl() async {
        let desk = FakeSpaces()
        let result = await desk.run("show me my desktops")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(said(result), "Here are your desktops, along the top of the screen.")
        XCTAssertEqual(desk.steps, ["open Mission Control"])
    }

    func testMoveAndRemoveAreGuidesOnly() async {
        let desk = FakeSpaces()
        let move = await desk.run("move this window to Desktop 2")
        XCTAssertEqual(said(move), "I can't drag windows in Mission Control, so this one is yours. Here's Mission Control. Drag the window onto Desktop 2, at the top of the screen.")
        XCTAssertFalse(move.dispatchedEffect)
        let remove = await desk.run("get rid of the extra desktops")
        XCTAssertEqual(said(remove), "Here are your desktops, along the top. Hold the pointer over the one you don't need, then click the X in its corner. Its windows move to another desktop.")
        XCTAssertEqual(desk.steps, ["open Mission Control", "open Mission Control"], "nothing pressed, nothing moved")
    }

    func testSeveralScreensAreNotGuessed() async {
        let desk = FakeSpaces()
        desk.screens = 2
        let result = await desk.run("go to Desktop 2")
        XCTAssertEqual(said(result), DesktopSpaceSwitch.severalScreensLine)
        XCTAssertFalse(desk.steps.contains { $0.hasPrefix("press") })
    }
}

final class DesktopSwitchPhraseTests: XCTestCase {
    private func verb(_ phrase: String) -> FastAction.DesktopVerb? {
        guard let parsed = FastAction.parse(phrase), case .desktop(let verb) = parsed.action.body else { return nil }
        XCTAssertNil(parsed.appQualifier, phrase)
        return verb
    }

    func testDesktopPhrases() {
        let cases: [(String, FastAction.DesktopVerb)] = [
            ("Go to Desktop 2.", .go(.number(2))), ("switch to desktop two", .go(.number(2))),
            ("take me to the second desktop", .go(.number(2))), ("go to desktop number 3", .go(.number(3))),
            ("Please switch to Space two.", .go(.number(2))), ("desktop 3", .go(.number(3))),
            ("go to desktop to", .go(.number(2))),
            ("switch to my other desktop", .go(.other)), ("go to the other desktop", .go(.other)),
            ("next desktop", .go(.step(.next))), ("go to the previous space", .go(.step(.previous))),
            ("go to my full-screen Safari", .go(.fullScreen(app: "safari"))),
            ("switch to full screen notes", .go(.fullScreen(app: "notes"))),
            ("go to safari full screen", .go(.fullScreen(app: "safari"))), ("open desktop 2", .go(.number(2))),
            ("Which desktop am I on?", .which), ("what desktop is this", .which),
            ("show me my desktops", .show), ("how many desktops do I have", .show),
            ("move this window to Desktop 2", .moveWindow(to: 2)),
            ("put this window on desktop 3", .moveWindow(to: 3)),
            ("how do I move a window to another desktop", .moveWindow(to: nil)),
            ("move it to my other desktop", .moveWindow(to: nil)),
            ("get rid of the extra desktops", .removeExtra), ("remove desktop 3", .removeExtra),
            ("delete a desktop", .removeExtra), ("I have too many desktops", .removeExtra)
        ]
        for (phrase, expected) in cases {
            XCTAssertEqual(verb(phrase), expected, phrase)
        }
    }

    func testNearMissesStayWithTheirOwnLanes() {
        for phrase in ["don't go to Desktop 2", "go to Desktop 2 then click", "type go to Desktop 2",
                       "go to Desktop 2 on the other monitor", "next window", "go to desktop 40",
                       "full screen safari", "go to full screen", "remove the photo",
                       "remove the extra spaces", "delete extra spaces", "remove the empty spaces",
                       "move this to desktop", "put it on desktop", "send this to desktop",
                       "open safari in full screen", "open safari full screen", "open full screen notes"] {
            XCTAssertNil(verb(phrase), phrase)
        }
        guard let showDesktop = FastAction.parse("show desktop"), case .systemHotkey = showDesktop.action.body else {
            return XCTFail("'show desktop' keeps its F11 chord")
        }
        guard let missionControl = FastAction.parse("mission control"), case .hotkey = missionControl.action.body else {
            return XCTFail("'mission control' keeps its ⌃↑ row")
        }
    }

    func testWhichOneWording() {
        XCTAssertEqual(DesktopSpaceSwitch.whichOneLine([2, 3]), "Which one: 2 or 3?")
        XCTAssertEqual(DesktopSpaceSwitch.whichOneLine([1, 3, 4]), "Which one: 1, 3 or 4?")
    }
}
