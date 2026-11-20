import AppKit

// The flows' own target windows, with nothing personal in them. Each one
// appends what happens to it to the file named by the first argument, so a
// test checks an effect by reading that file, not by asking Jarvis.
//
//   (default)  three buttons and a code word; a press appends the button's title
//   --list     a long list of numbered rows; a scroll appends the offset
//   --field    one empty text field; an edit appends "value <text>"
//   --message  a received message, selected, a Reply field and a Send button;
//              an edit of Reply appends "value <text>", a press of Send "Send"
//
// In "value" lines a newline is written as a backslash and an n.

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

/// The received message: static text the person has selected, so Jarvis's
/// "this" is its text and it is not a field to type into.
final class Message: NSView {
    static let text = "Hi, can we move tomorrow's 3 pm call to Thursday at 10? Thanks, Dana"

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { Self.text }
    override func accessibilitySelectedText() -> String? { Self.text }
    override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: 0, length: (Self.text as NSString).length) }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.selectedTextBackgroundColor.setFill()
        bounds.fill()
        (Self.text as NSString).draw(in: bounds.insetBy(dx: 8, dy: 6),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
    }
}

enum Mode {
    case board, list, field, message
}

final class Board: NSObject, NSApplicationDelegate {
    private let output: URL
    private let mode: Mode
    private var window: NSWindow?
    private var editable: NSTextField?
    private var recorded = ""

    init(output: URL, mode: Mode) {
        self.output = output
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileManager.default.createFile(atPath: output.path, contents: Data())
        switch mode {
        case .list: return showList()
        case .field: return showField()
        case .message: return showMessage()
        case .board: break
        }
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

    private func show(_ title: String, _ content: NSView, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    private func textField(placeholder: String) -> NSTextField {
        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15)
        field.widthAnchor.constraint(equalToConstant: 460).isActive = true
        editable = field
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.recordValue() }
        return field
    }

    private func recordValue() {
        guard let value = editable?.stringValue, value != recorded else { return }
        recorded = value
        append("value " + value.replacingOccurrences(of: "\n", with: "\\n"))
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        return stack
    }

    private func showField() {
        let field = textField(placeholder: "Type here")
        show("Jarvis E2E Field", stack([NSTextField(labelWithString: "Notes"), field]), size: NSSize(width: 520, height: 140))
        window?.makeFirstResponder(field)
    }

    private func showMessage() {
        let message = Message()
        message.translatesAutoresizingMaskIntoConstraints = false
        message.widthAnchor.constraint(equalToConstant: 460).isActive = true
        message.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let reply = textField(placeholder: "Reply")
        let send = NSButton(title: "Send", target: self, action: #selector(press(_:)))
        show("Jarvis E2E Message", stack([NSTextField(labelWithString: "From Dana"), message, reply, send]), size: NSSize(width: 520, height: 260))
        window?.makeFirstResponder(message)
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
    FileHandle.standardError.write(Data("usage: Board <record file> [--list | --field | --message]\n".utf8))
    exit(64)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let flags = Set(CommandLine.arguments.dropFirst())
let mode: Mode = flags.contains("--list") ? .list : flags.contains("--field") ? .field : flags.contains("--message") ? .message : .board
let board = Board(output: URL(fileURLWithPath: path), mode: mode)
app.delegate = board
app.run()
