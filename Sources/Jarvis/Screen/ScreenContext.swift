import AppKit
import ApplicationServices

/// One accessibility element as the screen reader sees it. The live read
/// builds this tree from AX; tests build it by hand.
struct ScreenNode: Sendable {
    var role: String
    var subrole: String? = nil
    var title: String? = nil
    var description: String? = nil
    var value: String? = nil
    var url: String? = nil
    var frame: CGRect? = nil
    var children: [ScreenNode] = []
}

/// The words in one window, ready to answer a question about the screen.
/// Each readable element gets a short ref (e1, e2, …) so an answer can
/// point at it; frames stay on the Mac. `redactions` holds every secure or
/// secret-labelled field's frame, to be blacked out before any picture of
/// the window is encoded. A picture is allowed only when
/// `redactionsComplete` is true, because a partial read may have missed one.
struct ScreenDigest: Sendable, Equatable {
    enum Withheld: String, Sendable { case vault }

    struct Item: Sendable, Equatable {
        var ref: String
        var kind: String
        var text: String
        var url: String? = nil
        var frame: CGRect? = nil
    }

    var app: String
    var bundleID: String? = nil
    var windowTitle: String
    var pageURL: String? = nil
    var items: [Item] = []
    var redactions: [CGRect] = []
    var withheld: Withheld? = nil
    var truncated = false
    var redactionsComplete = true

    func frame(ref: String) -> CGRect? {
        items.first { $0.ref == ref }?.frame
    }

    /// The text a model sees. Frames, bundle ids and secret values never
    /// appear here.
    var rendered: String {
        var lines = ["App: \(app)"]
        if withheld == .vault {
            lines.append("This is a password manager, so its contents are not read.")
            return lines.joined(separator: "\n")
        }
        if !windowTitle.isEmpty { lines.append("Window: \(windowTitle)") }
        if let pageURL { lines.append("Page: \(pageURL)") }
        for item in items {
            var line = "[\(item.ref)] \(item.kind)"
            if !item.text.isEmpty { line += " \"\(item.text)\"" }
            if let url = item.url { line += " -> \(url)" }
            lines.append(line)
        }
        if truncated { lines.append("(More in this window was not read.)") }
        return lines.joined(separator: "\n")
    }
}

enum ScreenContext {
    struct Limits: Sendable {
        var maxItems = 220
        var maxCharacters = 6_000
        var maxItemCharacters = 300
        var maxNodes = 1_500
        var maxDepth = 40
        var deadline: Duration = .milliseconds(400)
        static let standard = Limits()
    }

    private static let controlKinds: [String: String] = [
        "AXButton": "button", "AXMenuButton": "button", "AXPopUpButton": "pop-up button",
        "AXLink": "link", "AXCheckBox": "checkbox", "AXRadioButton": "option",
        "AXMenuItem": "menu item", "AXDisclosureTriangle": "disclosure", "AXSlider": "slider",
    ]
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func digest(app: String, bundleID: String?, windowTitle: String, root: ScreenNode,
                       complete: Bool = true, limits: Limits = .standard) -> ScreenDigest {
        var digest = ScreenDigest(app: app, bundleID: bundleID, windowTitle: clean(windowTitle, limits))
        if SensitiveContent.isVault(bundleID: bundleID, appName: app) {
            digest.withheld = .vault
            return digest
        }
        var characters = 0
        var full = false

        func add(_ kind: String, _ text: String, url: String? = nil, frame: CGRect?) {
            guard !full else { digest.truncated = true; return }
            let cost = kind.count + text.count + (url?.count ?? 0) + 8
            guard digest.items.count < limits.maxItems, characters + cost <= limits.maxCharacters else {
                full = true
                digest.truncated = true
                return
            }
            characters += cost
            digest.items.append(.init(ref: "e\(digest.items.count + 1)", kind: kind, text: text, url: url, frame: frame))
        }

        func visit(_ node: ScreenNode) {
            if SensitiveContent.isSecure(role: node.role, subrole: node.subrole) {
                if let frame = node.frame { digest.redactions.append(frame) } else { digest.redactionsComplete = false }
                add("password field", clean(label(node) ?? "", limits), frame: node.frame)
                return
            }
            if fieldRoles.contains(node.role) {
                let name = clean(label(node) ?? "", limits)
                if SensitiveContent.isSensitiveLabel(name) {
                    if let frame = node.frame { digest.redactions.append(frame) } else { digest.redactionsComplete = false }
                    add("field", name.isEmpty ? "(hidden)" : "\(name) (hidden)", frame: node.frame)
                } else {
                    let value = clean(node.value ?? "", limits)
                    add("field", [name, value].filter { !$0.isEmpty }.joined(separator: ": "), frame: node.frame)
                }
                node.children.forEach(visitSecretsOnly)
                return
            }
            if node.role == "AXWebArea", digest.pageURL == nil, let url = node.url, !url.isEmpty {
                digest.pageURL = clean(url, limits)
            }
            if let kind = controlKinds[node.role] {
                var text = label(node) ?? descendantText(node)
                if node.role == "AXCheckBox", let value = node.value { text += value == "1" ? " (on)" : " (off)" }
                add(kind, clean(text, limits), url: node.url.map { clean($0, limits) }, frame: node.frame)
                node.children.forEach(visitSecretsOnly)
                return
            }
            switch node.role {
            case "AXStaticText":
                let text = clean(node.value ?? node.title ?? "", limits)
                if !text.isEmpty { add("text", text, frame: node.frame) }
            case "AXHeading":
                if let title = label(node) { add("heading", clean(title, limits), frame: node.frame) }
            case "AXImage":
                if let title = label(node) { add("image", clean(title, limits), frame: node.frame) }
            default:
                break
            }
            node.children.forEach(visit)
        }

        func visitSecretsOnly(_ node: ScreenNode) {
            if SensitiveContent.isSecure(role: node.role, subrole: node.subrole)
                || (fieldRoles.contains(node.role) && SensitiveContent.isSensitiveLabel(label(node) ?? "")) {
                if let frame = node.frame { digest.redactions.append(frame) } else { digest.redactionsComplete = false }
                return
            }
            node.children.forEach(visitSecretsOnly)
        }

        root.children.forEach(visit)
        if !complete {
            digest.truncated = true
            digest.redactionsComplete = false
        }
        return digest
    }

    private static func label(_ node: ScreenNode) -> String? {
        [node.title, node.description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func descendantText(_ node: ScreenNode) -> String {
        var parts: [String] = []
        var pending = node.children
        while !pending.isEmpty, parts.count < 8 {
            let next = pending.removeFirst()
            if SensitiveContent.isSecure(role: next.role, subrole: next.subrole) { continue }
            if next.role == "AXStaticText", let text = next.value ?? next.title, !text.isEmpty { parts.append(text) }
            pending.append(contentsOf: next.children)
        }
        return parts.joined(separator: " ")
    }

    private static func clean(_ text: String, _ limits: Limits) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let masked = SensitiveContent.maskCardNumbers(collapsed)
        guard masked.count > limits.maxItemCharacters else { return masked }
        return String(masked.prefix(limits.maxItemCharacters - 1)) + "…"
    }

    // MARK: - Live read

    /// The frontmost app's focused window.
    @MainActor
    static func readFocused(limits: Limits = .standard) async -> ScreenDigest? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let windowID = await FocusedTextBinding.focusedWindowID(pid: Int(app.processIdentifier)) else { return nil }
        return await read(WindowRef(pid: Int(app.processIdentifier), windowID: windowID), limits: limits)
    }

    static func read(_ window: WindowRef, limits: Limits = .standard) async -> ScreenDigest? {
        let work = Task.detached(priority: .userInitiated) { collect(window, limits: limits) }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private static func collect(_ window: WindowRef, limits: Limits) -> ScreenDigest? {
        guard let pid = pid_t(exactly: window.pid), pid > 0,
              let windowID = UInt32(exactly: window.windowID), windowID > 0,
              let running = NSRunningApplication(processIdentifier: pid) else { return nil }
        let appName = running.localizedName ?? ""
        let bundleID = running.bundleIdentifier
        if SensitiveContent.isVault(bundleID: bundleID, appName: appName) {
            return digest(app: appName, bundleID: bundleID, windowTitle: "", root: ScreenNode(role: "AXWindow"))
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              let root = windows.first(where: { FocusedTextBinding.windowNumber($0) == windowID }) else { return nil }
        let deadline = ContinuousClock.now + limits.deadline
        var budget = limits.maxNodes
        var complete = true
        let tree = node(root, depth: 0, limits: limits, deadline: deadline, budget: &budget, complete: &complete)
        return digest(app: appName, bundleID: bundleID, windowTitle: tree.title ?? "", root: tree,
                      complete: complete, limits: limits)
    }

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXURLAttribute,
    ] as CFArray

    private static func node(_ element: AXUIElement, depth: Int, limits: Limits, deadline: ContinuousClock.Instant,
                             budget: inout Int, complete: inout Bool) -> ScreenNode {
        budget -= 1
        AXUIElementSetMessagingTimeout(element, 0.2)
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [Any], values.count == 8, let role = values[0] as? String else {
            complete = false
            return ScreenNode(role: "AXUnknown")
        }
        var result = ScreenNode(role: role, subrole: values[1] as? String, title: values[2] as? String,
                                description: values[3] as? String,
                                url: (values[7] as? URL)?.absoluteString ?? (values[7] as? String),
                                frame: frame(position: values[5], size: values[6]))
        let secure = SensitiveContent.isSecure(role: role, subrole: result.subrole)
        let secret = fieldRoles.contains(role)
            && SensitiveContent.isSensitiveLabel(label(result) ?? "")
        if !secure, !secret, ["AXStaticText", "AXCheckBox"].contains(role) || fieldRoles.contains(role) {
            var current: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &current) == .success {
                result.value = (current as? String) ?? (current as? NSNumber)?.stringValue
            }
        }
        guard !secure, let children = values[4] as? [AXUIElement], !children.isEmpty else { return result }
        guard depth < limits.maxDepth else { complete = false; return result }
        for child in children {
            guard budget > 0, ContinuousClock.now < deadline, !Task.isCancelled else { complete = false; break }
            result.children.append(node(child, depth: depth + 1, limits: limits, deadline: deadline,
                                        budget: &budget, complete: &complete))
        }
        return result
    }

    private static func frame(position: Any, size: Any) -> CGRect? {
        guard CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
