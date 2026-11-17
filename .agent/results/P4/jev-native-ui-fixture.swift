import AppKit
import Foundation

final class NumericOutput: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Numeric output" }
    override func accessibilityValue() -> Any? { NSNumber(value: 7) }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        NSStringFromSelector(selector) != "setAccessibilityValue:"
            && super.isAccessibilitySelectorAllowed(selector)
    }
    override func draw(_ dirtyRect: NSRect) {
        ("7" as NSString).draw(in: bounds, withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 25, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}

final class NativeOutcomeFixture: NSObject, NSApplicationDelegate {
    let directory: URL
    let nonce: String
    var window: NSWindow!
    var result: NSTextField!
    var retired: [NSTextField] = []
    var generation = 0
    var timer: Timer?

    init(directory: URL, nonce: String) {
        self.directory = directory
        self.nonce = nonce
    }

    func label(_ value: String, y: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.frame = CGRect(x: 32, y: y, width: 300, height: 36)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 25, weight: .regular)
        return field
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 240, y: 220, width: 380, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Jev Native UI Outcome Test"
        let view = window.contentView!
        view.addSubview(label("3 + 4", y: 240))
        result = label("\u{200e}7", y: 170)
        view.addSubview(result)
        view.addSubview(label("\u{200e}7", y: 70))
        let numeric = NumericOutput(frame: CGRect(x: 32, y: 15, width: 300, height: 36))
        view.addSubview(numeric)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        emit()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.command()
        }
    }

    func emit() {
        guard let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        window.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let top = NSScreen.screens.first!.frame.maxY
        let body: [String: Any] = [
            "nonce": nonce, "pid": ProcessInfo.processInfo.processIdentifier,
            "window_id": window.windowNumber, "generation": generation,
            "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
            "bounds": ["x": rect.minX, "y": top - rect.maxY, "width": rect.width, "height": rect.height],
        ]
        try! bitmap.representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent("fixture.png"), options: .atomic)
        try! JSONSerialization.data(withJSONObject: body).write(
            to: directory.appendingPathComponent("journal.json"), options: .atomic)
    }

    func command() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["nonce"] as? String == nonce else { return }
        if body["operation"] as? String == "quit" {
            timer?.invalidate()
            NSApp.terminate(nil)
            return
        }
        guard body["operation"] as? String == "replace",
              body["generation"] as? Int == generation + 1 else { return }
        let next = label(result.stringValue, y: result.frame.minY)
        next.frame = result.frame
        retired.append(result)
        window.contentView!.replaceSubview(result, with: next)
        result = next
        generation += 1
        NSAccessibility.post(element: window!, notification: .layoutChanged)
        emit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = NativeOutcomeFixture(
    directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
    nonce: CommandLine.arguments[2])
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
