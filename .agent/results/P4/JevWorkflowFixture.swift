import AppKit
import Foundation

@MainActor
final class WorkflowFixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let kind: String
    let output: URL
    let steps: Int
    var window: NSWindow!
    var stage = 0
    var completed = false
    var cancelled = false
    var name = "Old Name"
    var email = ""
    var nameField: NSTextField?
    var emailField: NSTextField?
    var left = ""
    var right = ""
    var operation: String?
    var result: Double?
    var selection: Int?

    init(kind: String, output: URL, steps: Int) {
        self.kind = kind
        self.output = output
        self.steps = steps
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 660, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Jev P4 Fixture - " + kind.capitalized
        window.delegate = self
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeState()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func label(_ text: String, size: CGFloat = 18) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.setAccessibilityLabel(text)
        return field
    }

    func button(_ title: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(tap(_:)))
        button.bezelStyle = .rounded
        button.tag = tag
        button.setAccessibilityLabel(title)
        if title == "Finish" || title == "Submit" || title == "Equals" {
            button.keyEquivalent = "\r"
        }
        return button
    }

    func field(_ title: String, value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return field
    }

    func render() {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -30),
        ])
        stack.addArrangedSubview(label("Synthetic desktop workflow", size: 24))
        if cancelled {
            stack.addArrangedSubview(label("Setup cancelled"))
        } else if kind == "setup" {
            stack.addArrangedSubview(label(completed ? "Setup complete" : "Installer setup"))
            if !completed {
                stack.addArrangedSubview(label("Step \(stage + 1) of \(steps)"))
                stack.addArrangedSubview(button(stage == steps - 1 ? "Finish" : "Continue", tag: 1))
                stack.addArrangedSubview(button("Cancel", tag: -1))
            }
        } else if kind == "form" {
            if completed {
                stack.addArrangedSubview(label("Profile complete: \(name) <\(email)>"))
            } else if stage == 0 {
                stack.addArrangedSubview(label("Profile setup - Name"))
                nameField = field("Name", value: name)
                stack.addArrangedSubview(nameField!)
                stack.addArrangedSubview(button("Next", tag: 1))
            } else {
                stack.addArrangedSubview(label("Profile setup - Email"))
                emailField = field("Email", value: email)
                stack.addArrangedSubview(emailField!)
                stack.addArrangedSubview(button("Submit", tag: 1))
            }
        } else if kind == "choices" {
            if let selection {
                stack.addArrangedSubview(label("Selected Choice \(selection)"))
            } else {
                stack.addArrangedSubview(label("Choose one option"))
                let rows = (0..<9).map { row in
                    (0..<5).map { column in
                        let index = row * 5 + column
                        return button("Choice \(index)", tag: index) as NSView
                    }
                }
                let grid = NSGridView(views: rows)
                grid.rowSpacing = 5
                grid.columnSpacing = 8
                stack.addArrangedSubview(grid)
            }
        } else {
            stack.addArrangedSubview(label("Calculator"))
            stack.addArrangedSubview(label("Expression: \(left.isEmpty ? "0" : left) \(operation ?? "") \(right)"))
            stack.addArrangedSubview(label("Result: " + (result.map { String(format: "%.0f", $0) } ?? "--")))
            let grid = NSGridView(views: [
                [button("7", tag: 7), button("8", tag: 8), button("9", tag: 9), button("Multiply", tag: 100)],
                [button("4", tag: 4), button("5", tag: 5), button("6", tag: 6), button("Add", tag: 101)],
                [button("1", tag: 1), button("2", tag: 2), button("3", tag: 3), button("Equals", tag: 102)],
                [button("0", tag: 0), button("Clear", tag: 103), NSView(), NSView()],
            ])
            grid.rowSpacing = 10
            grid.columnSpacing = 10
            stack.addArrangedSubview(grid)
        }
        stack.addArrangedSubview(label("Temporary test window. No personal data.", size: 12))
        window.contentView = root
    }

    @objc func tap(_ sender: NSButton) {
        if kind == "choices" {
            selection = sender.tag
            completed = true
        } else if kind == "calculator" {
            switch sender.tag {
            case 0...9:
                if operation == nil { left += "\(sender.tag)" }
                else { right += "\(sender.tag)" }
                result = nil
            case 100: operation = "*"
            case 101: operation = "+"
            case 102:
                if let a = Double(left), let b = Double(right), let operation {
                    result = operation == "*" ? a * b : a + b
                    completed = true
                }
            case 103:
                left = ""; right = ""; operation = nil; result = nil; completed = false
            default: break
            }
        } else if sender.tag == -1 {
            cancelled = true
        } else if kind == "form" {
            if stage == 0 {
                name = nameField?.stringValue ?? ""
                stage = 1
            } else {
                email = emailField?.stringValue ?? ""
                completed = true
            }
        } else {
            stage += 1
            completed = stage >= steps
        }
        render()
        writeState()
    }

    func writeState() {
        var state: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier, "window_id": window.windowNumber,
            "kind": kind, "stage": stage, "completed": completed, "cancelled": cancelled,
            "name": name, "email": email, "left": left, "right": right,
        ]
        if let result { state["result"] = result }
        if let selection { state["selection"] = selection }
        do {
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                .write(to: output, options: .atomic)
        } catch {
            fputs("fixture state write failed\n", stderr)
            NSApp.terminate(nil)
        }
    }
}

@main
struct FixtureMain {
    @MainActor static func main() {
        func option(_ name: String, fallback: String) -> String {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
                return fallback
            }
            return args[index + 1]
        }
        let path = option("--state", fallback: "")
        guard !path.isEmpty, !FileManager.default.fileExists(atPath: path) else {
            fputs("--state must name a new file in an owned directory\n", stderr)
            return
        }
        let kind = option("--kind", fallback: "setup")
        guard ["setup", "form", "calculator", "choices"].contains(kind) else {
            fputs("unknown fixture kind\n", stderr)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = WorkflowFixture(
            kind: kind,
            output: URL(fileURLWithPath: path),
            steps: Int(option("--steps", fallback: "7")) ?? 7)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
