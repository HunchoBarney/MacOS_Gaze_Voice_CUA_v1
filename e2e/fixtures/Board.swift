import AppKit

// The flows' own target window: three buttons and a code word, nothing
// personal. Each press appends the button's title to the file named by the
// first argument, so a test checks a click by reading that file.

final class Board: NSObject, NSApplicationDelegate {
    private let output: URL
    private var window: NSWindow?

    init(output: URL) {
        self.output = output
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileManager.default.createFile(atPath: output.path, contents: Data())
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

    @objc private func press(_ sender: NSButton) {
        guard let handle = try? FileHandle(forWritingTo: output) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(sender.title)\n".utf8))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
    FileHandle.standardError.write(Data("usage: Board <clicks file>\n".utf8))
    exit(64)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let board = Board(output: URL(fileURLWithPath: path))
app.delegate = board
app.run()
