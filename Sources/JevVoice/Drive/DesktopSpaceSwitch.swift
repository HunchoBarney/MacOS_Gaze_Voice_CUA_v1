import AppKit
import ApplicationServices

@MainActor
enum DesktopSpaceSwitch {
    enum Code: String, Sendable {
        case policyDenied, authorizationCancelled, authorityNotCurrent, displayChanged, dockUnavailable, dockTerminated
        case accessibilityNotTrusted, launcherUnavailable, localeUnavailable
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

    static var singleDisplay: UInt32? {
        let screens = NSScreen.screens
        guard screens.count == 1 else { return nil }
        return displayIdentifier(screens[0].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")])
    }

    private static func displayIdentifier(_ raw: Any?) -> UInt32? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number), let id = UInt32(exactly: number), id != 0 else { return nil }
        return id
    }

    static func perform<Button: Equatable>(
        number: Int, invalidation: () -> Code?, inspect: () -> Overview<Button>,
        open: () async throws -> Void, pause: () async throws -> Void,
        press: (Button) -> Bool, note: (String) -> Void
    ) async -> Outcome {
        var origin: Origin?
        func outcome(_ code: Code, _ message: String) -> Outcome { Outcome(code, message, origin: origin) }
        func blocked(_ reason: String) -> String {
            reason + (origin == .launchRequested ? " Mission Control may be open." : "")
        }
        func invalid() -> Code? { invalidation() ?? (Task.isCancelled ? .authorizationCancelled : nil) }
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
        let unselected = blocked("I couldn't identify Desktop \(number) safely. No desktop was selected.")
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
        return outcome(.pressAcceptedUnverified, blocked("Requested Desktop \(number). Switch unverified."))
    }

    static func run(number: Int, display: UInt32, current: () -> Bool, note: (String) -> Void) async -> Outcome {
        let unreadable = "I couldn't read the Dock's accessibility controls."
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").only,
              let dockURL = dock.bundleURL, let bundle = Bundle(url: dockURL) else { return Outcome(.dockUnavailable, unreadable) }
        guard AXIsProcessTrusted() else { return Outcome(.accessibilityNotTrusted, unreadable) }
        let launcher = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        guard Bundle(url: launcher)?.bundleIdentifier == "com.apple.exposelauncher" else {
            return Outcome(.launcherUnavailable, "The system Mission Control app is unavailable.")
        }
        let desktop = bundle.localizedString(forKey: "DesktopNum", value: "", table: "Localizable")
        let exit = bundle.localizedString(forKey: "AXExitToDesktop", value: "", table: "Accessibility")
        guard desktop.components(separatedBy: "%@").count == 2,
              exit.components(separatedBy: "%@").count == 2 else { return Outcome(.localeUnavailable, "I couldn't identify localized desktop names.") }
        let label = desktop.replacingOccurrences(of: "%@", with: String(number))
        let expected = exit.replacingOccurrences(of: "%@", with: label)
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        return await perform(number: number, invalidation: {
                guard current() else { return .authorityNotCurrent }
                guard singleDisplay == display else { return .displayChanged }
                return dock.isTerminated ? .dockTerminated : nil
            },
            inspect: { overview(root: root, displayID: display, expected: expected) }, open: {
                _ = try await NSWorkspace.shared.openApplication(at: launcher, configuration: .init())
            }, pause: { try await Task.sleep(for: .milliseconds(100)) }, press: {
                AXUIElementPerformAction($0, kAXPressAction as CFString) == .success
            }, note: note)
    }

    private static func overview(root: AXUIElement, displayID: UInt32, expected: String) -> Overview<AXUIElement> {
        func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
            return value
        }
        return overview(root: root, displayID: displayID, expected: expected,
            children: { attr($0, kAXChildrenAttribute) as? [AXUIElement] }, attr: attr, pressable: {
                var actions: CFArray?
                return attr($0, kAXEnabledAttribute) as? Bool == true &&
                    AXUIElementCopyActionNames($0, &actions) == .success &&
                    (actions as? [String])?.contains(kAXPressAction) == true
            })
    }

    static func overview<Node>(root: Node, displayID: UInt32, expected: String,
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
        let match = matchButton(rows, matching: expected)
        guard case .target(let button) = match else { return match }
        guard pressable(button) else { return .openWithoutTarget(.targetNotPressable) }
        return .target(button)
    }

    static func matchButton<T>(_ rows: [(String, T)?], matching expected: String) -> Overview<T> {
        guard rows.allSatisfy({ $0 != nil }) else { return .openWithoutTarget(.malformedThumbnail) }
        let matches = rows.compactMap { row in row.flatMap { $0.0 == expected ? $0.1 : nil } }
        guard let button = matches.only else { return .openWithoutTarget(matches.isEmpty ? .targetMissing : .targetAmbiguous) }
        return .target(button)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
