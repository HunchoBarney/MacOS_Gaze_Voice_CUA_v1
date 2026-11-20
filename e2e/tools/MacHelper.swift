import AppKit
import ApplicationServices

// The e2e harness's small native helper: posts the Fn key the way the
// keyboard does, and counts or quits apps by bundle id through
// NSRunningApplication, which needs no Automation grant.
//
//   e2e-helper fn down|up
//   e2e-helper count <bundle-id>
//   e2e-helper paths <bundle-id>
//   e2e-helper quit <bundle-id> [seconds]   force-quits what is left after the wait

func fail(_ message: String, _ code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("e2e-helper: \(message)\n".utf8))
    exit(code)
}

func running(_ bundleID: String) -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("fn", 2):
    guard arguments[1] == "down" || arguments[1] == "up" else { fail("fn takes down or up") }
    guard AXIsProcessTrusted() else {
        fail("this process can't post keys: grant Accessibility to the app that started the run", 77)
    }
    let down = arguments[1] == "down"
    guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                              virtualKey: 63, keyDown: down) else { fail("could not make the Fn event", 70) }
    event.type = .flagsChanged
    event.flags = down ? .maskSecondaryFn : []
    event.post(tap: .cghidEventTap)
case ("count", 2):
    print(running(arguments[1]).count)
case ("paths", 2):
    for app in running(arguments[1]) { print(app.bundleURL?.path ?? "") }
case ("quit", 2), ("quit", 3):
    let seconds = arguments.count == 3 ? Double(arguments[2]) ?? 15 : 15
    running(arguments[1]).forEach { $0.terminate() }
    let deadline = Date().addingTimeInterval(seconds)
    while !running(arguments[1]).isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    let left = running(arguments[1])
    guard !left.isEmpty else { exit(0) }
    left.forEach { $0.forceTerminate() }
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    fail("force-quit \(left.count) copy of \(arguments[1]) after \(Int(seconds)) s", running(arguments[1]).isEmpty ? 3 : 1)
default:
    fail("usage: e2e-helper fn down|up | count <bundle-id> | paths <bundle-id> | quit <bundle-id> [seconds]")
}
