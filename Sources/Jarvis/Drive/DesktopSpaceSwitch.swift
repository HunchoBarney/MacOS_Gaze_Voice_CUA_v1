import AppKit
import ApplicationServices

/// Desktops (macOS Spaces) by voice. Mission Control's accessibility tree is
/// the only public way to pick a desktop: `mc` → `mc.display` → `mc.spaces` →
/// `mc.spaces.list`, one button per desktop or full-screen app, under the
/// Dock on macOS 26 and under WindowManager on macOS 27. A switch is one
/// AXPress on the matching button, never a synthetic click (macOS 27 ignores
/// those in Mission Control). Arrival is read back from
/// `NSWorkspace.activeSpaceDidChangeNotification` and Mission Control
/// closing and, where SkyLight's read-only Spaces calls load, from the
/// active space itself. Nothing here moves a window or calls a private API
/// that changes state.
///
/// Restored from the KAR-6 archive (6da5a5b), widened to both trees,
/// full-screen apps and arrival checks.
enum DesktopSpaceSwitch {
    enum Code: String, Sendable {
        case cancelled, displayChanged, treeUnavailable
        case rootUnreadable, rootUnrecognized, overviewUnreadable, displayBindingUnavailable
        case spacesGroupUnavailable, spacesListUnavailable, emptySpacesList, malformedThumbnail
        case targetMissing, targetAmbiguous, targetNotPressable, targetChanged, overviewClosedOnRecheck
        case openFailed, pollInterrupted, overviewNotReady, pressRefused, pressAcceptedUnverified
    }

    enum Origin: String, Sendable { case startedOpen, launchRequested }

    struct Outcome: Sendable {
        let code: Code
        let message: String
        let origin: Origin?
        init(_ code: Code, _ message: String, origin: Origin? = nil) {
            self.code = code; self.message = message; self.origin = origin
        }
    }

    enum Overview<Button> {
        case closed, unavailable(Code), openWithoutTarget(Code), target(Button)
    }

    enum Direction: Equatable, Sendable { case previous, next }

    /// What one Mission Control button stands for.
    enum Space: Equatable, Sendable {
        case desktop(Int)
        case fullScreen(String)
    }

    // MARK: - The press

    /// Open Mission Control when it's closed, wait for its list to fill in,
    /// read the target twice, and press it once. The outcome never claims
    /// arrival: the caller reads that back.
    static func perform<Button: Equatable>(
        name: String, invalidation: () -> Code?, inspect: () -> Overview<Button>,
        open: () async throws -> Void, pause: () async throws -> Void,
        press: (Button) -> Bool, note: (String) -> Void
    ) async -> Outcome {
        var origin: Origin?
        func outcome(_ code: Code, _ message: String) -> Outcome { Outcome(code, message, origin: origin) }
        func blocked(_ reason: String) -> String {
            reason + (origin == .launchRequested ? " Mission Control may be open." : "")
        }
        func invalid() -> Code? { invalidation() ?? (Task.isCancelled ? .cancelled : nil) }
        if let code = invalid() { return Outcome(code, "The target changed. Nothing was sent.") }
        var state = inspect()
        switch state {
        case .target, .openWithoutTarget: origin = .startedOpen
        default: break
        }
        if case .closed = state {
            if let code = invalid() { return Outcome(code, "The target changed. Nothing was sent.") }
            origin = .launchRequested
            note("Mission Control may be open. No desktop was selected.")
            do { try await open() } catch { return outcome(.openFailed, blocked("I couldn't finish opening Mission Control.")) }
            var sawList = false
            polling: for _ in 0..<12 {
                if let code = invalid() { return outcome(code, blocked("Stopped before selecting a desktop.")) }
                state = inspect()
                switch state {
                case .closed:
                    if sawList { return outcome(.overviewClosedOnRecheck, "Mission Control closed before I could select a desktop.") }
                case .openWithoutTarget(.emptySpacesList): sawList = true
                default: break polling
                }
                do { try await pause() } catch { return outcome(.pollInterrupted, blocked("I couldn't finish opening Mission Control.")) }
            }
        }
        let unselected = blocked("I couldn't identify \(name) safely. No desktop was selected.")
        let first: Button
        switch state {
        case .closed: return outcome(.overviewNotReady, unselected)
        case .unavailable(let code), .openWithoutTarget(let code): return outcome(code, unselected)
        case .target(let button): first = button
        }
        if let code = invalid() { return outcome(code, unselected) }
        let fresh: Button
        switch inspect() {
        case .closed: return outcome(.overviewClosedOnRecheck, unselected)
        case .unavailable(let code), .openWithoutTarget(let code): return outcome(code, unselected)
        case .target(let button): fresh = button
        }
        guard fresh == first else { return outcome(.targetChanged, unselected) }
        if let code = invalid() { return outcome(code, unselected) }
        note(blocked("A selection may have been sent. The active desktop is unverified."))
        guard press(fresh) else { return outcome(.pressRefused, blocked("macOS didn't confirm the selection request. I won't retry.")) }
        return outcome(.pressAcceptedUnverified, blocked("Requested \(name). Switch unverified."))
    }

    // MARK: - Reading Mission Control

    /// The first tree that shows Mission Control wins, so the Dock (macOS 26)
    /// and WindowManager (macOS 27) can both be asked. A tree that only
    /// shows the closed Dock says closed; one nobody can read says why.
    static func probe<Node>(roots: [Node], displayID: UInt32, accept: (String) -> Bool,
                            children: (Node) -> [Node]?, attr: (Node, String) -> Any?,
                            pressable: (Node) -> Bool) -> Overview<Node> {
        var fallback: Overview<Node>?
        for root in roots {
            let state = overview(root: root, displayID: displayID, accept: accept,
                                 children: children, attr: attr, pressable: pressable)
            switch state {
            case .target, .openWithoutTarget,
                 .unavailable(.overviewUnreadable), .unavailable(.displayBindingUnavailable):
                return state
            case .closed:
                fallback = .closed
            case .unavailable:
                if fallback == nil { fallback = state }
            }
        }
        return fallback ?? .unavailable(.treeUnavailable)
    }

    static func overview<Node>(root: Node, displayID: UInt32, accept: (String) -> Bool,
                               children: (Node) -> [Node]?, attr: (Node, String) -> Any?,
                               pressable: (Node) -> Bool) -> Overview<Node> {
        func matching(_ nodes: [Node], _ id: String) -> [Node] {
            nodes.filter { attr($0, kAXIdentifierAttribute) as? String == id }
        }
        guard let roots = children(root), !roots.isEmpty else { return .unavailable(.rootUnreadable) }
        let groups = matching(roots, "mc")
        if groups.isEmpty {
            guard roots.allSatisfy({ attr($0, kAXRoleAttribute) as? String == kAXListRole }) else { return .unavailable(.rootUnrecognized) }
            return .closed
        }
        guard let mc = groups.only, let displays = children(mc) else { return .unavailable(.overviewUnreadable) }
        guard let display = matching(displays, "mc.display").only,
              displayIdentifier(attr(display, "AXDisplayID")) == displayID, let sections = children(display)
        else { return .unavailable(.displayBindingUnavailable) }
        guard let spaces = matching(sections, "mc.spaces").only, let lists = children(spaces)
        else { return .openWithoutTarget(.spacesGroupUnavailable) }
        guard let list = matching(lists, "mc.spaces.list").only,
              attr(list, kAXRoleAttribute) as? String == kAXListRole,
              let buttons = children(list) else { return .openWithoutTarget(.spacesListUnavailable) }
        guard !buttons.isEmpty else { return .openWithoutTarget(.emptySpacesList) }
        let rows: [(String, Node)?] = buttons.map { button in
            guard attr(button, kAXRoleAttribute) as? String == kAXButtonRole,
                  let description = attr(button, kAXDescriptionAttribute) as? String,
                  !description.isEmpty else { return nil }
            return (description, button)
        }
        let match = matchButton(rows, where: accept)
        guard case .target(let button) = match else { return match }
        guard pressable(button) else { return .openWithoutTarget(.targetNotPressable) }
        return .target(button)
    }

    static func matchButton<T>(_ rows: [(String, T)?], where accept: (String) -> Bool) -> Overview<T> {
        guard rows.allSatisfy({ $0 != nil }) else { return .openWithoutTarget(.malformedThumbnail) }
        let matches = rows.compactMap { row in row.flatMap { accept($0.0) ? $0.1 : nil } }
        guard let button = matches.only else { return .openWithoutTarget(matches.isEmpty ? .targetMissing : .targetAmbiguous) }
        return .target(button)
    }

    /// A display number as Mission Control and CoreGraphics give it: a
    /// non-zero integer that fits 32 bits, never a float or a bool.
    static func displayIdentifier(_ raw: Any?) -> UInt32? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number), let id = UInt32(exactly: number), id != 0 else { return nil }
        return id
    }

    // MARK: - Names

    /// Mission Control's localized words from the Dock's own strings:
    /// "Desktop %@" and the wrappers its buttons carry, such as "exit to %@"
    /// and "exit to full screen %@".
    struct Labels: Equatable, Sendable {
        var desktop: String
        var wrappers: [String]
        var fullScreenWrappers: [String]
    }

    /// What a button's description names: "exit to Desktop 2" is Desktop 2,
    /// "exit to full screen Safari" is Safari's own desktop. Anything else is
    /// nil and never pressed.
    static func space(_ description: String, labels: Labels) -> Space? {
        func inner(_ text: String, _ format: String) -> String? {
            let parts = format.components(separatedBy: "%@")
            guard parts.count == 2, text.count > parts[0].count + parts[1].count,
                  text.hasPrefix(parts[0]), text.hasSuffix(parts[1]) else { return nil }
            return String(text.dropFirst(parts[0].count).dropLast(parts[1].count))
        }
        if let app = labels.fullScreenWrappers.lazy.compactMap({ inner(description, $0) }).first {
            return .fullScreen(app)
        }
        let label = labels.wrappers.lazy.compactMap { inner(description, $0) }.first ?? description
        guard let number = inner(label, labels.desktop).flatMap({ Int($0) }), number > 0 else { return nil }
        return .desktop(number)
    }

    /// A full-screen button matches the spoken app name as whole words, so
    /// "Safari" finds "Safari" and "Apple – Safari" but not "Safaricom".
    static func matches(_ space: Space?, _ target: Space) -> Bool {
        switch (space, target) {
        case (.desktop(let shown)?, .desktop(let wanted)):
            return shown == wanted
        case (.fullScreen(let shown)?, .fullScreen(let wanted)):
            let app = NamedTargetMatch.normalize(wanted)
            return !app.isEmpty && (" " + NamedTargetMatch.normalize(shown) + " ").contains(" " + app + " ")
        default:
            return false
        }
    }

    // MARK: - Read-only Spaces layout

    /// The one display's spaces in Mission Control order, read through
    /// SkyLight's `SLSCopyManagedDisplaySpaces` and `SLSGetActiveSpace`.
    struct Layout: Equatable, Sendable {
        struct Space: Equatable, Sendable {
            var id: UInt64
            var fullScreen: Bool
        }
        var spaces: [Space]
        var active: UInt64

        var desktops: [UInt64] { spaces.filter { !$0.fullScreen }.map(\.id) }
        var currentIndex: Int? { spaces.firstIndex { $0.id == active } }
        /// The active desktop's number; nil on a full-screen app's space.
        var currentNumber: Int? { number(of: active) }
        func number(of id: UInt64) -> Int? { desktops.firstIndex(of: id).map { $0 + 1 } }

        /// One entry per display comes back; with several, no single answer
        /// is right, so there is no layout. Type 0 is a desktop, 4 a
        /// full-screen app; other kinds aren't places a person goes.
        init?(displays: [[String: Any]], active: UInt64) {
            guard displays.count == 1, let rows = displays[0]["Spaces"] as? [[String: Any]] else { return nil }
            var spaces: [Space] = []
            for row in rows {
                guard let id = ((row["id64"] ?? row["ManagedSpaceID"]) as? NSNumber)?.uint64Value,
                      let type = (row["type"] as? NSNumber)?.intValue else { return nil }
                if type == 0 || type == 4 { spaces.append(Space(id: id, fullScreen: type == 4)) }
            }
            guard spaces.contains(where: { !$0.fullScreen }), spaces.contains(where: { $0.id == active })
            else { return nil }
            self.spaces = spaces
            self.active = active
        }
    }

    /// ⌃← and ⌃→ are symbolic hot keys 79 and 81 (80 and 82 are their ⇧
    /// twins, which Jarvis never sends). A missing entry is the default, on;
    /// an entry counts only while enabled and still bound to Control plus
    /// that arrow.
    static func shortcutEnabled(_ direction: Direction, hotkeys: [String: Any]?) -> Bool {
        let (id, key) = direction == .next ? ("81", 124) : ("79", 123)
        guard let entry = hotkeys?[id] as? [String: Any] else { return true }
        guard entry["enabled"] as? Bool == true else { return false }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3 else { return true }
        let shift = 0x20000, control = 0x40000, option = 0x80000, command = 0x100000
        return parameters[1] == key && parameters[2] & (shift | control | option | command) == control
    }

    // MARK: - What Jarvis says

    static func name(of space: Space) -> String {
        switch space {
        case .desktop(let number): return "Desktop \(number)"
        case .fullScreen(let app): return "full-screen \(app)"
        }
    }

    static func arrivedLine(_ space: Space) -> String { "You're on \(name(of: space)) now." }
    static let unsureLine = "I asked to switch, but I'm not sure it moved."
    static let whiteOutlineLine = "The one with the white outline is where you are."
    static let showLine = "Here are your desktops, along the top of the screen."
    static let cantOpenLine = "I couldn't open Mission Control."
    static let pickOneLine = "Your desktops are along the top of the screen. Click the one you want."
    static let sayNumberLine = "Which desktop? Say its number, like 'Desktop 2'."
    static let severalScreensLine = "You have more than one screen, so I can't pick the desktop myself. Your desktops are along the top. Click the one you want."

    static func whichOneLine(_ numbers: [Int]) -> String {
        let words = numbers.map(String.init)
        return "Which one: \(words.dropLast().joined(separator: ", ")) or \(words.last ?? "")?"
    }

    static func whereLine(_ layout: Layout) -> String {
        guard let number = layout.currentNumber else {
            return "You're in a full-screen app. It has a desktop of its own."
        }
        return "You're on Desktop \(number)."
    }

    static func stepLine(_ direction: Direction, landed: Layout?) -> String {
        if let number = landed?.currentNumber { return "You're on Desktop \(number) now." }
        return direction == .next ? "You're on the next desktop now." : "You're on the previous desktop now."
    }

    static func edgeLine(_ direction: Direction) -> String {
        direction == .next ? "You're already on the last desktop." : "You're already on the first desktop."
    }

    static func moveLine(to number: Int?, opened: Bool) -> String {
        let place = number.map { "onto Desktop \($0)" } ?? "onto the desktop you want"
        let lead = opened ? "Here's Mission Control. " : "Press Control and the Up arrow to open Mission Control. "
        return "I can't drag windows in Mission Control, so this one is yours. "
            + lead + "Drag the window \(place), at the top of the screen."
    }

    static func removeLine(opened: Bool) -> String {
        let lead = opened ? "Here are your desktops, along the top. "
            : "Press Control and the Up arrow to see your desktops. "
        return lead + "Hold the pointer over the one you don't need, then click the X in its corner. Its windows move to another desktop."
    }

    /// Why nothing was pressed, in plain words. When Jarvis opened Mission
    /// Control itself it says how to close it.
    static func notSwitchedLine(_ outcome: Outcome, _ space: Space) -> String {
        let name = name(of: space)
        let reason: String
        switch outcome.code {
        case .targetMissing:
            reason = "I couldn't find \(name) in Mission Control."
        case .targetAmbiguous:
            reason = "I see more than one \(name) in Mission Control, so I didn't pick one."
        case .openFailed, .pollInterrupted, .overviewNotReady:
            reason = cantOpenLine
        case .pressRefused:
            reason = "I asked to switch to \(name), but macOS didn't accept it."
        case .displayChanged:
            reason = "Your screens changed, so I stopped before switching."
        default:
            reason = "I couldn't read Mission Control, so I didn't switch."
        }
        return reason + (outcome.origin == .launchRequested ? " Press Escape to close Mission Control." : "")
    }

    // MARK: - The system

    /// Everything the desktop lanes read or press, injectable so tests never
    /// open Mission Control, press a key, or read a real preference.
    struct System {
        /// Mission Control's trees: the Dock's app element, then
        /// WindowManager's. Nodes are opaque to the lanes.
        var roots: () -> [AnyHashable]
        var children: (AnyHashable) -> [AnyHashable]?
        var attr: (AnyHashable, String) -> Any?
        var pressable: (AnyHashable) -> Bool
        var press: (AnyHashable) -> Bool
        /// The one display's id; nil with several screens.
        var displayID: () -> UInt32?
        var labels: () -> Labels?
        var openMissionControl: () async throws -> Void
        var pause: () async throws -> Void
        /// Starts listening for `activeSpaceDidChangeNotification` now; the
        /// closure it returns waits up to the given time for one, then stops.
        var watchSpaceChange: () -> (Duration) async -> Bool
        /// SkyLight's read-only layout; nil when the symbols don't load.
        var layout: () -> Layout?
        var shortcutEnabled: (Direction) -> Bool

        func inspect(displayID: UInt32, target: Space, labels: Labels) -> Overview<AnyHashable> {
            probe(roots: roots(), displayID: displayID,
                  accept: { DesktopSpaceSwitch.matches(DesktopSpaceSwitch.space($0, labels: labels), target) },
                  children: children, attr: attr, pressable: pressable)
        }

        static var live: System {
            func element(_ node: AnyHashable) -> AXUIElement? { (node.base as? AXNode)?.element }
            func read(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
                return value
            }
            return System(
                roots: {
                    guard AXIsProcessTrusted() else { return [] }
                    return ["com.apple.dock", "com.apple.WindowManager"].compactMap { id in
                        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
                        else { return nil }
                        return AnyHashable(AXNode(AXUIElementCreateApplication(app.processIdentifier)))
                    }
                },
                children: { node in
                    guard let element = element(node),
                          let kids = read(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
                    return kids.map { AnyHashable(AXNode($0)) }
                },
                attr: { node, key in element(node).flatMap { read($0, key) } },
                pressable: { node in
                    guard let element = element(node) else { return false }
                    var actions: CFArray?
                    return read(element, kAXEnabledAttribute) as? Bool == true
                        && AXUIElementCopyActionNames(element, &actions) == .success
                        && (actions as? [String])?.contains(kAXPressAction) == true
                },
                press: { node in
                    element(node).map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
                },
                displayID: {
                    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
                    var count: UInt32 = 0
                    guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
                    return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.only
                },
                labels: liveLabels,
                openMissionControl: {
                    let launcher = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
                    guard Bundle(url: launcher)?.bundleIdentifier == "com.apple.exposelauncher" else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    _ = try await NSWorkspace.shared.openApplication(at: launcher, configuration: .init())
                },
                pause: { try await Task.sleep(for: .milliseconds(100)) },
                watchSpaceChange: SpaceChangeWatch.start,
                layout: { SkyLight.loaded?.layout() },
                shortcutEnabled: { direction in
                    DesktopSpaceSwitch.shortcutEnabled(direction, hotkeys: CFPreferencesCopyAppValue(
                        "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any])
                })
        }

        /// The Dock's strings, or WindowManager's should the Dock stop
        /// carrying them.
        private static func liveLabels() -> Labels? {
            func format(_ bundle: Bundle, _ key: String, _ table: String) -> String? {
                let text = bundle.localizedString(forKey: key, value: "", table: table)
                return text.components(separatedBy: "%@").count == 2 ? text : nil
            }
            for path in ["/System/Library/CoreServices/Dock.app", "/System/Library/CoreServices/WindowManager.app"] {
                guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
                      let desktop = format(bundle, "DesktopNum", "Localizable") else { continue }
                return Labels(
                    desktop: desktop,
                    wrappers: ["AXExitToDesktop", "AXSelectDesktop"].compactMap { format(bundle, $0, "Accessibility") },
                    fullScreenWrappers: ["AXExitToFullscreenDesktop", "AXSelectFullscreenDesktop"]
                        .compactMap { format(bundle, $0, "Accessibility") })
            }
            return nil
        }
    }

    /// An AX element whose every message is bounded, so a busy Dock can't
    /// hold the caller for the six-second default.
    private struct AXNode: Hashable {
        let element: AXUIElement
        init(_ element: AXUIElement) {
            AXUIElementSetMessagingTimeout(element, 0.25)
            self.element = element
        }
        static func == (a: AXNode, b: AXNode) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// Notices `activeSpaceDidChangeNotification` from the moment it starts.
    private final class SpaceChangeWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var changed = false

        private var seen: Bool { lock.withLock { changed } }
        private func mark() { lock.withLock { changed = true } }

        static func start() -> (Duration) async -> Bool {
            let watch = SpaceChangeWatch()
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                           object: nil, queue: nil) { [weak watch] _ in watch?.mark() }
            return { window in
                defer { center.removeObserver(token) }
                let end = ContinuousClock.now + window
                while !watch.seen, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(50)) }
                return watch.seen
            }
        }
    }

    /// SkyLight's read-only Spaces symbols, found at run time. Only reads
    /// load here: nothing that switches a space or moves a window.
    private struct SkyLight: @unchecked Sendable {
        typealias Connection = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
        typealias ActiveSpace = @convention(c) (Int32) -> UInt64
        let connection: Connection
        let copySpaces: CopySpaces
        let activeSpace: ActiveSpace

        static let loaded: SkyLight? = {
            guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
                  let connection = dlsym(handle, "SLSMainConnectionID"),
                  let copySpaces = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
                  let activeSpace = dlsym(handle, "SLSGetActiveSpace") else { return nil }
            return SkyLight(connection: unsafeBitCast(connection, to: Connection.self),
                            copySpaces: unsafeBitCast(copySpaces, to: CopySpaces.self),
                            activeSpace: unsafeBitCast(activeSpace, to: ActiveSpace.self))
        }()

        func layout() -> Layout? {
            let cid = connection()
            guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
            return Layout(displays: displays, active: activeSpace(cid))
        }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
