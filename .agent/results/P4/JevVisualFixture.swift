import AppKit
import Foundation

@MainActor
final class VisualFixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let output: URL
    let seed: Int
    var window: NSWindow!
    var status: NSTextField!
    var targetCount = 0
    var otherCount = 0

    init(output: URL, seed: Int) {
        self.output = output
        self.seed = seed
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 240, y: 220, width: 640, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Jev Visual Qualification"
        window.delegate = self
        let root = NSView()
        let heading = NSTextField(labelWithString: "Choose from the picture")
        heading.font = .systemFont(ofSize: 24)
        heading.frame = NSRect(x: 36, y: 320, width: 568, height: 40)
        root.addSubview(heading)
        for index in 0..<2 {
            let target = index == seed % 2
            let button = NSButton(image: icon(target: target), target: self, action: #selector(tap(_:)))
            button.tag = target ? 1 : 2
            button.imageScaling = .scaleProportionallyUpOrDown
            button.bezelStyle = .regularSquare
            button.frame = NSRect(x: 80 + index * 280, y: 130, width: 200, height: 150)
            button.setAccessibilityLabel("")
            button.setAccessibilityIdentifier("symbol-\(index)")
            root.addSubview(button)
        }
        status = NSTextField(labelWithString: "Nothing activated.")
        status.font = .systemFont(ofSize: 18)
        status.frame = NSRect(x: 36, y: 65, width: 568, height: 36)
        root.addSubview(status)
        let note = NSTextField(labelWithString: "Synthetic test window. No account or personal data.")
        note.frame = NSRect(x: 36, y: 24, width: 568, height: 24)
        root.addSubview(note)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeState()
    }

    func icon(target: Bool) -> NSImage {
        NSImage(size: NSSize(width: 100, height: 100), flipped: false) { _ in
            (target ? NSColor.systemGreen : NSColor.systemRed).setFill()
            let path = NSBezierPath()
            if target {
                path.move(to: NSPoint(x: 24, y: 15))
                path.line(to: NSPoint(x: 88, y: 50))
                path.line(to: NSPoint(x: 24, y: 85))
                path.close()
            } else {
                path.appendRect(NSRect(x: 18, y: 18, width: 64, height: 64))
            }
            path.fill()
            return true
        }
    }

    @objc func tap(_ sender: NSButton) {
        if sender.tag == 1 {
            targetCount += 1
            status.stringValue = "Green triangle activated."
        } else {
            otherCount += 1
            status.stringValue = "Red square activated."
        }
        writeState()
    }

    func writeState() {
        let state: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "window_id": window.windowNumber, "seed": seed,
            "target_count": targetCount, "other_count": otherCount,
            "status": status.stringValue,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try data.write(to: output, options: .atomic)
        } catch {
            fputs("Cannot persist owned fixture state.\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

@main
struct Main {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let seed = Int(arguments[2]) else { exit(64) }
        let delegate = VisualFixture(output: URL(fileURLWithPath: arguments[1]), seed: seed)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
