import AppKit

// Disposable native surface: controls are drawn, deliberately absent from AX.
// Successful input changes the window title, allowing independent readback.
final class Surface: NSView {
    private let actionRect = NSRect(x: 80, y: 100, width: 320, height: 90)
    private var count = 0
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let font = NSFont.systemFont(ofSize: 26, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        ("Jarvis disposable visual test" as NSString).draw(at: NSPoint(x: 35, y: 30), withAttributes: attributes)
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: actionRect, xRadius: 12, yRadius: 12).fill()
        ("Apply" as NSString).draw(at: NSPoint(x: 199, y: 127), withAttributes: attributes)
        ("No personal content" as NSString).draw(at: NSPoint(x: 110, y: 240), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard actionRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        count += 1
        window?.title = "Jarvis Visual Fixture — Applied \(count)"
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 480, height: 320),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Jarvis Visual Fixture — Ready"
        window.contentView = Surface(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let review = NSButton(title: "Fixture review", target: self, action: #selector(ordinaryReview))
        review.frame = NSRect(x: 325, y: 275, width: 140, height: 32)
        review.cell?.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Mark reviewed", handler: { [weak window] in
            window?.title = "Jarvis Visual Fixture — Custom Reviewed"
            return window != nil
        })])
        window.contentView?.addSubview(review)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        self.window = window
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let fixtureItem = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        let fixtureMenu = NSMenu(title: "Fixture")
        let reviewItem = NSMenuItem(title: "Review", action: nil, keyEquivalent: "")
        let reviewMenu = NSMenu(title: "Review")
        let mark = NSMenuItem(title: "Mark via Menu", action: #selector(menuReview), keyEquivalent: "")
        mark.target = self
        reviewMenu.addItem(mark)
        reviewItem.submenu = reviewMenu
        fixtureMenu.addItem(reviewItem)
        fixtureItem.submenu = fixtureMenu
        bar.addItem(fixtureItem)
        app.mainMenu = bar
    }
    @objc private func ordinaryReview() { window?.title = "Jarvis Visual Fixture — Ordinary Press" }
    @objc private func menuReview() { window?.title = "Jarvis Visual Fixture — Menu Reviewed" }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
