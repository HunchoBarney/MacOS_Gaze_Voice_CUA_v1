import AppKit
import JevVoiceCore

struct LaunchReversalPolicy {
    enum Effect: Equatable { case requestQuit, restoreVisibility, unavailable }
    static func effect(wasRunning: Bool, unchanged: Bool) -> Effect {
        unchanged ? (wasRunning ? .restoreVisibility : .requestQuit) : .unavailable
    }
}

/// Session-local native targets and reversible launch receipts. No model output is
/// executable code; new capabilities are bounded native operations.
@MainActor
final class NativeAppActions {
    private struct Target {
        let app: NSRunningApplication
        let window: AXUIElement?
        let focused: AXUIElement?
        let url: String?
        let tab: AXUIElement?
    }
    private struct LaunchReceipt {
        let app: NSRunningApplication
        let wasRunning: Bool
        let wasHidden: Bool
        let wasMinimized: Bool
        let previous: NSRunningApplication?
        let window: AXUIElement?
        let inputGeneration: Int
    }
    var resolvedTargetName: String? { target?.app.localizedName }
    private var target: Target?
    private var dictation: (field: AXUIElement, draft: DictationDraft)?
    private var launch: LaunchReceipt?
    private var inputGeneration = 0
    private var targetInputGeneration = 0
    private var monitor: Any?

    init() { installInputMonitor() }
    private func installInputMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.inputGeneration += 1 }
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func begin(context: String?) {
        installInputMonitor()
        launch = nil
        dictation = nil
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? context.flatMap(Self.running) : front
        target = app.map(Self.capture)
        targetInputGeneration = inputGeneration
    }

    /// Returns false only before any write when an app cannot support addressed
    /// revisions. The caller can then retain its existing final-paste behavior.
    func updateDictation(_ decision: Decision) async throws -> Bool {
        let current = try requireTarget(named: decision.targetApp)
        guard let field = current.focused,
              let focused = Self.capture(current.app).focused, CFEqual(field, focused) else {
            throw ExecutorError.controlFailed("The text destination changed. Live dictation stopped.")
        }
        guard let text = decision.text else { throw ExecutorError.missingSlot("text") }
        let selection = Self.range(field, kAXSelectedTextRangeAttribute)
        let document = Self.string(field, kAXValueAttribute)
        if dictation == nil {
            guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(Self.string(field, kAXRoleAttribute) ?? ""),
                  Self.isSettable(field, kAXSelectedTextAttribute), Self.isSettable(field, kAXSelectedTextRangeAttribute),
                  let selection, selection.length == 0, let document else { return false }
            dictation = (field, try DictationDraft(document: document, insertion: selection.location))
        }
        guard var state = dictation, CFEqual(state.field, field),
              let selection, selection.length == 0, let document else {
            throw DictationDraft.DraftError.changedDestination
        }
        let replacement = try state.draft.replacementRange(in: document, caret: selection.location)
        guard state.draft.text != text else { return true }
        launch = nil // Typing makes an earlier launch ineligible for automatic undo.
        try Self.setRange(field, replacement)
        guard Self.range(field, kAXSelectedTextRangeAttribute) == replacement,
              Self.string(field, kAXValueAttribute) == document else {
            throw DictationDraft.DraftError.changedDestination
        }
        try Self.set(field, kAXSelectedTextAttribute, text as CFString)
        state.draft.accept(text)
        // Verify the addressed edit before accepting its ownership. Never retry
        // an uncertain write or fall back to a paste after a partial effect.
        guard Self.string(field, kAXValueAttribute) == state.draft.document else {
            throw ExecutorError.controlFailed("The app did not confirm the live text update. Existing text is kept; start a new command.")
        }
        try Self.setRange(field, NSRange(location: state.draft.caret, length: 0))
        dictation = state
        return true
    }

    func execute(_ decision: Decision) async throws -> String {
        let generation = inputGeneration
        defer { targetInputGeneration = generation }
        switch decision.action {
        case .openApp, .switchApp:
            guard let name = decision.targetApp, let url = InstalledApps.appURL(named: name),
                  let bundleID = Bundle(url: url)?.bundleIdentifier else { throw ExecutorError.missingSlot("target app") }
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            let front = NSWorkspace.shared.frontmostApplication
            let previous = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? target?.app : front
            let oldWindow = existing.flatMap { app -> AXUIElement? in
                if target?.app.processIdentifier == app.processIdentifier, let window = target?.window { return window }
                if let window = Self.capture(app).window { return window }
                let windows = Self.elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute)
                return windows.count == 1 ? windows[0] : nil
            }
            let minimized = oldWindow.map { Self.bool($0, kAXMinimizedAttribute) } ?? false
            let hidden = existing?.isHidden ?? false
            let generation = inputGeneration
            let message = try await Executor.execute(decision)
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                throw ExecutorError.controlFailed("The requested app did not launch")
            }
            // Record even when a spoken correction arrived while launch awaited.
            launch = LaunchReceipt(app: app, wasRunning: existing != nil, wasHidden: hidden,
                wasMinimized: minimized, previous: previous, window: oldWindow, inputGeneration: generation)
            if decision.action == .switchApp, let oldWindow, minimized {
                try Self.set(oldWindow, kAXMinimizedAttribute, kCFBooleanFalse)
            }
            target = try await readyTarget(app)
            return message
        case .createDocument:
            launch = nil
            guard decision.targetApp == nil || decision.targetApp == "TextEdit" else {
                throw ExecutorError.controlFailed("Creating documents is currently supported in TextEdit")
            }
            let current = try requireTarget(named: "TextEdit")
            let appElement = AXUIElementCreateApplication(current.app.processIdentifier)
            let oldWindows = Self.elements(appElement, kAXWindowsAttribute)
            // Native File > New, discovered from the app's accessibility menu.
            guard let menu = Self.element(appElement, kAXMenuBarAttribute),
                  let file = Self.find(menu, depth: 2, predicate: { Self.string($0, kAXTitleAttribute) == "File" }),
                  let new = Self.find(file, depth: 3, predicate: { Self.string($0, kAXTitleAttribute) == "New" }) else {
                throw ExecutorError.controlFailed("TextEdit's New Document command is unavailable")
            }
            try Self.press(new)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                let capture = Self.capture(current.app)
                if let window = capture.window, !oldWindows.contains(where: { CFEqual($0, window) }),
                   let field = Self.find(window, depth: 8, predicate: { Self.string($0, kAXRoleAttribute) == kAXTextAreaRole }) {
                    target = Target(app: current.app, window: window, focused: field, url: nil, tab: nil)
                    return "Created a new TextEdit document"
                }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            throw ExecutorError.controlFailed("TextEdit did not expose a new editable document")
        case .dictate:
            launch = nil
            let current = try requireTarget(named: decision.targetApp)
            guard let field = current.focused,
                  [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(Self.string(field, kAXRoleAttribute) ?? "") else {
                throw ExecutorError.controlFailed("Focus an editable field before dictating")
            }
            // Pin both the external window and field across interpretation/UI updates.
            let actual = Self.capture(current.app)
            guard let focused = actual.focused, CFEqual(field, focused) else {
                throw ExecutorError.controlFailed("The text destination changed. Focus the intended field and try again.")
            }
            guard let text = decision.text else { throw ExecutorError.missingSlot("text") }
            return try await Executor.dictate(text)
        case .scrollDown, .scrollUp, .browserBack:
            launch = nil
            let current = try requireTarget(named: decision.targetApp)
            guard current.app.bundleIdentifier == "com.google.Chrome", let window = current.window else {
                throw ExecutorError.controlFailed("This browser control currently requires Google Chrome")
            }
            let actual = Self.capture(current.app)
            if let tab = current.tab {
                guard let selected = actual.tab, CFEqual(tab, selected) else {
                    throw ExecutorError.controlFailed("The selected browser tab changed. Start a new command on the intended tab.")
                }
            }
            if let oldURL = current.url, oldURL != actual.url {
                throw ExecutorError.controlFailed("The browser page changed. Start a new command on the intended tab.")
            }
            if decision.action == .browserBack {
                guard let back = Self.find(window, depth: 7, predicate: {
                    Self.string($0, kAXRoleAttribute) == kAXButtonRole &&
                    (Self.string($0, kAXTitleAttribute) == "Back" || Self.string($0, kAXDescriptionAttribute) == "Back")
                }), Self.bool(back, kAXEnabledAttribute) else {
                    throw ExecutorError.controlFailed("There is no available Back action in this Chrome window")
                }
                try Self.press(back)
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    guard inputGeneration == generation else { throw ExecutorError.controlFailed("Browser navigation was interrupted") }
                    let updated = Self.capture(current.app)
                    if updated.url != nil && updated.url != current.url {
                        target = updated
                        return "Returned to the previous Chrome page"
                    }
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
                throw ExecutorError.controlFailed("Back was requested, but navigation could not be verified")
            }
            guard let web = Self.find(window, depth: 8, predicate: { Self.string($0, kAXRoleAttribute) == "AXWebArea" }),
                  let frame = Self.frame(web), frame.width > 0, frame.height > 0,
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: decision.action == .scrollDown ? -240 : 240, wheel2: 0, wheel3: 0) else {
                throw ExecutorError.controlFailed("This Chrome page does not expose a scrollable content area")
            }
            event.location = CGPoint(x: frame.midX, y: frame.midY)
            event.postToPid(current.app.processIdentifier)
            return "Scroll requested in Google Chrome"
        default:
            if decision.action != .none { launch = nil }
            if [.openURL, .webSearch].contains(decision.action) {
                let destination: URL?
                if decision.action == .webSearch, let query = decision.query {
                    destination = (decision.searchSite ?? .google).searchURL(query: query)
                } else { destination = decision.url.flatMap(URL.init(string:)) }
                guard let destination else { throw ExecutorError.missingSlot("URL or search query") }
                let appURL = decision.targetApp.flatMap(InstalledApps.appURL(named:))
                    ?? NSWorkspace.shared.urlForApplication(toOpen: destination)
                let bundleID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
                let message = try await Executor.execute(decision)
                target = nil
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    guard inputGeneration == generation else { throw ExecutorError.controlFailed("Navigation was interrupted by keyboard or mouse input") }
                    if let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                       NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                        let current = Self.capture(app)
                        if !AXIsProcessTrusted() || Self.matchesDestination(current.url, destination) {
                            target = current
                            return message
                        }
                    }
                    try await Task.sleep(nanoseconds: 30_000_000)
                }
                // The URL request already happened; never retry it or guess a
                // target for dependent actions when readiness is unobservable.
                return message + " · Destination not yet verified; start a new command once the page is ready"
            }
            return try await Executor.execute(decision)
        }
    }

    func undoLaunch() async throws -> String {
        guard let receipt = launch else { throw ExecutorError.controlFailed("There is no unchanged recent app launch to undo") }
        launch = nil // A refused quit is not automatically retried.
        let app = receipt.app
        let unchanged = monitor != nil && AXIsProcessTrusted() && !app.isTerminated && inputGeneration == receipt.inputGeneration &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        switch LaunchReversalPolicy.effect(wasRunning: receipt.wasRunning, unchanged: unchanged) {
        case .unavailable:
            throw ExecutorError.controlFailed("The app changed since launch; leaving your work intact")
        case .requestQuit:
            guard app.terminate() else { throw ExecutorError.controlFailed("The app declined the quit request") }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !app.isTerminated, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            guard app.isTerminated else {
                throw ExecutorError.controlFailed("Quit requested; the app is still open and may need you to save your work")
            }
        case .restoreVisibility:
            if receipt.wasHidden { app.hide() }
            if receipt.wasMinimized, let window = receipt.window { try Self.set(window, kAXMinimizedAttribute, kCFBooleanTrue) }
        }
        // Do not override a third-party focus change during asynchronous termination.
        let front = NSWorkspace.shared.frontmostApplication
        if front == nil || front?.processIdentifier == app.processIdentifier || front?.bundleIdentifier == "com.apple.finder" {
            if let previous = receipt.previous, !previous.isTerminated { previous.activate(options: []) }
        }
        target = receipt.previous.flatMap { $0.isTerminated ? nil : Self.capture($0) }
        return receipt.wasRunning ? "Restored the previous app; existing session kept open" : "Closed the app opened by Jarvis"
    }

    private func readyTarget(_ app: NSRunningApplication) async throws -> Target {
        // Without Accessibility, waiting cannot produce an AX window. App launch
        // itself still works; dependent controls report the missing permission.
        guard AXIsProcessTrusted() else { return Self.capture(app) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            let capture = Self.capture(app)
            if capture.window != nil { return capture }
            // A launch can be reversed after this wait even if the task was cancelled.
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        return Self.capture(app)
    }

    private func requireTarget(named name: String?) throws -> Target {
        guard AXIsProcessTrusted() else { throw ExecutorError.controlFailed("Accessibility permission is needed for this action") }
        guard inputGeneration == targetInputGeneration else {
            throw ExecutorError.controlFailed("Keyboard or mouse input changed the destination. Start a new command on the intended target.")
        }
        guard let current = target, !current.app.isTerminated,
              name == nil || current.app.localizedName?.caseInsensitiveCompare(name!) == .orderedSame else {
            throw ExecutorError.controlFailed("The target app changed. Start a new command in the intended app.")
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            current.app.activate(options: [])
            if let window = current.window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == current.app.processIdentifier else {
            throw ExecutorError.controlFailed("The target app changed. Start a new command in the intended app.")
        }
        if let expected = current.window {
            guard let actual = Self.capture(current.app).window, CFEqual(expected, actual) else {
                throw ExecutorError.controlFailed("The target window changed. Start a new command in the intended window.")
            }
        }
        return current
    }

    static func matchesDestination(_ actual: String?, _ expected: URL) -> Bool {
        guard let actual, let result = URLComponents(string: actual),
              let destination = URLComponents(url: expected, resolvingAgainstBaseURL: false),
              result.host?.lowercased() == destination.host?.lowercased(),
              result.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == destination.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return false }
        return (destination.queryItems ?? []).allSatisfy { (result.queryItems ?? []).contains($0) }
    }

    private static func running(named name: String) -> NSRunningApplication? {
        guard let url = InstalledApps.appURL(named: name), let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }
    private static func capture(_ app: NSRunningApplication) -> Target {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let window = element(ax, kAXFocusedWindowAttribute)
        return Target(app: app, window: window, focused: element(ax, kAXFocusedUIElementAttribute),
                      url: window.flatMap { string($0, kAXURLAttribute) },
                      tab: window.flatMap { window in
                          guard app.bundleIdentifier == "com.google.Chrome" else { return nil }
                          guard let group = find(window, depth: 6, predicate: { string($0, kAXRoleAttribute) == kAXTabGroupRole }) else { return nil }
                          return elements(group, kAXChildrenAttribute).first { bool($0, kAXValueAttribute) || bool($0, kAXSelectedAttribute) }
                      })
    }
    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] { value(el, attr) as? [AXUIElement] ?? [] }
    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        let result = value(el, attr)
        return (result as? String) ?? (result as? URL)?.absoluteString
    }
    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool { value(el, attr) as? Bool ?? false }
    private static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, attr as CFString, &result) == .success && result.boolValue
    }
    private static func range(_ el: AXUIElement, _ attr: String) -> NSRange? {
        guard let value = value(el, attr), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private static func setRange(_ el: AXUIElement, _ range: NSRange) throws {
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else { throw DictationDraft.DraftError.changedDestination }
        try set(el, kAXSelectedTextRangeAttribute, value)
    }
    private static func set(_ el: AXUIElement, _ attr: String, _ v: CFTypeRef) throws {
        guard AXUIElementSetAttributeValue(el, attr as CFString, v) == .success else { throw ExecutorError.controlFailed("The application refused a native control change") }
    }
    private static func press(_ element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { throw ExecutorError.controlFailed("The application refused that action") }
    }
    private static func find(_ root: AXUIElement, depth: Int, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var budget = 600
        func visit(_ node: AXUIElement, _ depth: Int) -> AXUIElement? {
            guard budget > 0 else { return nil }; budget -= 1
            if predicate(node) { return node }
            guard depth > 0 else { return nil }
            for child in elements(node, kAXChildrenAttribute) { if let found = visit(child, depth - 1) { return found } }
            return nil
        }
        return visit(root, depth)
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
