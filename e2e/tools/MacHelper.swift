import AppKit
import ApplicationServices

// The e2e harness's small native helper. It counts and quits apps through
// NSRunningApplication, which needs no Automation grant, and reads or presses
// other apps' controls through Accessibility, which the process that runs
// make e2e (Terminal, or Capy) holds. It never asks for a permission: grants
// only reports what is already granted.
//
//   e2e-helper count <bundle-id>
//   e2e-helper paths <bundle-id>
//   e2e-helper quit <bundle-id> [seconds]      force-quits what is left after the wait
//   e2e-helper grants                           accessibility=<bool> screen-recording=<bool>
//   e2e-helper windows <bundle-id>              one line per window: <width>x<height> <title>
//   e2e-helper web-url <bundle-id>              the URL of the focused window's web page
//   e2e-helper extra <bundle-id> [item]         lists the menu-bar extra's items, or presses one
//   e2e-helper focus <bundle-id> <placeholder>  focuses the text field with that placeholder
//   e2e-helper menu <bundle-id> <menu> <item>   presses an item in the app's menu bar
//   e2e-helper close-front <bundle-id> <n>      closes the n frontmost windows
//   e2e-helper discard <bundle-id>              closes every window without saving
//   e2e-helper post fn-hold <seconds> | escape  posts the key as a program, never as hardware

func fail(_ message: String, _ code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("e2e-helper: \(message)\n".utf8))
    exit(code)
}

func running(_ bundleID: String) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    (attribute(element, name) as? [AXUIElement]) ?? []
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func application(_ bundleID: String) -> AXUIElement {
    guard AXIsProcessTrusted() else { fail("Accessibility is not granted to the app running make e2e", 77) }
    guard let app = running(bundleID).first else { fail("\(bundleID) is not running", 3) }
    return AXUIElementCreateApplication(app.processIdentifier)
}

func size(_ window: AXUIElement) -> CGSize {
    var size = CGSize.zero
    guard let value = attribute(window, kAXSizeAttribute) else { return size }
    AXValueGetValue(value as! AXValue, .cgSize, &size)
    return size
}

func find(_ root: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(root) { return root }
    guard depth < 40 else { return nil }
    for child in elements(root, kAXChildrenAttribute) {
        if let found = find(child, depth: depth + 1, match) { return found }
    }
    return nil
}

func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

func wait(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags = [], type: CGEventType? = nil) {
    guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: key, keyDown: down) else {
        fail("couldn't make a key event")
    }
    if let type { event.type = type }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("count", 2):
    print(running(arguments[1]).count)
case ("paths", 2):
    for app in running(arguments[1]) { print(app.bundleURL?.path ?? "") }
case ("quit", 2), ("quit", 3):
    let seconds = arguments.count == 3 ? Double(arguments[2]) ?? 15 : 15
    running(arguments[1]).forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(seconds)
    while !running(arguments[1]).isEmpty, Date() < deadline { wait(0.2) }
    let left = running(arguments[1])
    guard !left.isEmpty else { exit(0) }
    left.forEach { $0.forceTerminate() }
    wait(1)
    fail("force-quit \(left.count) copy of \(arguments[1]) after \(Int(seconds)) s", running(arguments[1]).isEmpty ? 3 : 1)
case ("grants", 1):
    print("accessibility=\(AXIsProcessTrusted()) screen-recording=\(CGPreflightScreenCaptureAccess())")
case ("windows", 2):
    for window in elements(application(arguments[1]), kAXWindowsAttribute) {
        let frame = size(window)
        print("\(Int(frame.width))x\(Int(frame.height)) \(string(window, kAXTitleAttribute) ?? "")")
    }
case ("web-url", 2):
    let app = application(arguments[1])
    guard let window = attribute(app, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) ?? elements(app, kAXWindowsAttribute).first,
          let page = find(window, { string($0, kAXRoleAttribute) == "AXWebArea" }),
          let url = attribute(page, kAXURLAttribute) as? URL else { fail("no web page in the focused window", 1) }
    print(url.absoluteString)
case ("extra", 2), ("extra", 3):
    let bar = attribute(application(arguments[1]), kAXExtrasMenuBarAttribute).map { $0 as! AXUIElement }
    guard let item = bar.flatMap({ elements($0, kAXChildrenAttribute).first }) else { fail("\(arguments[1]) has no menu-bar extra", 1) }
    guard press(item) else { fail("couldn't open the menu-bar extra", 1) }
    wait(0.5)
    let menu = elements(item, kAXChildrenAttribute).first
    let items = menu.map { elements($0, kAXChildrenAttribute) } ?? []
    if arguments.count == 3 {
        guard let target = items.first(where: { string($0, kAXTitleAttribute) == arguments[2] }) else {
            if let menu { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
            fail("the menu has no \(arguments[2]) item", 1)
        }
        guard press(target) else { fail("couldn't press \(arguments[2])", 1) }
    } else {
        for entry in items { if let title = string(entry, kAXTitleAttribute), !title.isEmpty { print(title) } }
        if let menu { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
    }
case ("focus", 3):
    let app = application(arguments[1])
    guard let field = elements(app, kAXWindowsAttribute).lazy.compactMap({ window in
        find(window, { string($0, kAXPlaceholderValueAttribute) == arguments[2] })
    }).first else { fail("no field with placeholder \(arguments[2])", 1) }
    guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
        fail("couldn't focus \(arguments[2])", 1)
    }
case ("menu", 4):
    let bar = attribute(application(arguments[1]), kAXMenuBarAttribute).map { $0 as! AXUIElement }
    guard let menu = bar.flatMap({ elements($0, kAXChildrenAttribute).first { string($0, kAXTitleAttribute) == arguments[2] } }),
          let list = elements(menu, kAXChildrenAttribute).first,
          let item = elements(list, kAXChildrenAttribute).first(where: { string($0, kAXTitleAttribute) == arguments[3] }),
          press(item) else { fail("couldn't press \(arguments[2]) > \(arguments[3])", 1) }
case ("close-front", 3):
    for window in elements(application(arguments[1]), kAXWindowsAttribute).prefix(Int(arguments[2]) ?? 0) {
        if let close = attribute(window, kAXCloseButtonAttribute).map({ $0 as! AXUIElement }) { _ = press(close) }
        wait(0.5)
    }
case ("discard", 2):
    let app = application(arguments[1])
    for window in elements(app, kAXWindowsAttribute) {
        guard let close = attribute(window, kAXCloseButtonAttribute).map({ $0 as! AXUIElement }), press(close) else { continue }
        wait(0.8)
        for sheet in elements(app, kAXWindowsAttribute) + elements(window, kAXChildrenAttribute) {
            if let button = find(sheet, { ["Delete", "Don’t Save", "Don't Save", "Delete Draft"].contains(string($0, kAXTitleAttribute) ?? "") }) {
                _ = press(button)
                wait(0.5)
            }
        }
    }
case ("post", 2) where arguments[1] == "escape":
    post(53, down: true)
    post(53, down: false)
case ("post", 3) where arguments[1] == "fn-hold":
    post(63, down: true, flags: .maskSecondaryFn, type: .flagsChanged)
    wait(Double(arguments[2]) ?? 1)
    post(63, down: false, type: .flagsChanged)
default:
    fail("usage: e2e-helper count|paths|quit|grants|windows|web-url|extra|focus|menu|close-front|discard|post (see the header)")
}
