import AppKit

// The flows' own target window: three buttons and a code word, nothing
// personal. Each press appends the button's title to the file named by the
// first argument, so a test checks a click by reading that file. With --list
// it shows a long list of numbered rows instead and appends the list's scroll
// offset to that file each time it moves, so a test checks scrolling the same
// way.

final class Rows: NSView {
    static let height: CGFloat = 28
    static let count = 4000

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let first = max(0, Int(dirtyRect.minY / Self.height))
        let last = min(Self.count - 1, Int(dirtyRect.maxY / Self.height))
        guard first <= last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor]
        for row in first...last {
            ("Row \(row + 1)" as NSString).draw(at: NSPoint(x: 16, y: CGFloat(row) * Self.height + 5), withAttributes: attributes)
        }
    }
}

final class Board: NSObject, NSApplicationDelegate {
    private let output: URL
    private let list: Bool
    private var window: NSWindow?

    init(output: URL, list: Bool) {
        self.output = output
        self.list = list
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileManager.default.createFile(atPath: output.path, contents: Data())
        if list { return showList() }
        let code = NSTextField(labelWithString: "The code word is PELICAN.")
        code.font = .systemFont(ofSize: 18)
        let buttons = ["Apple", "Banana", "Cherry"].map { NSButton(title: $0, target: self, action: #selector(press(_:))) }
        let row = NSStackView(views: buttons)
        row.spacing = 16
        let stack = NSStackView(views: [code, row])
        stack.orientation = .vertical
        stack.spacing = 28
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Jarvis E2E Board"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    private func showList() {
        let rows = Rows(frame: NSRect(x: 0, y: 0, width: 440, height: Rows.height * CGFloat(Rows.count)))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 360))
        scroll.hasVerticalScroller = true
        scroll.documentView = rows
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Jarvis E2E List"
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    @objc private func press(_ sender: NSButton) {
        append(sender.title)
    }

    @objc private func scrolled(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        append(String(Int(clip.bounds.origin.y.rounded())))
    }

    private func append(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: output) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(line)\n".utf8))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
    FileHandle.standardError.write(Data("usage: Board <record file> [--list]\n".utf8))
    exit(64)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let board = Board(output: URL(fileURLWithPath: path), list: CommandLine.arguments.contains("--list"))
app.delegate = board
app.run()
