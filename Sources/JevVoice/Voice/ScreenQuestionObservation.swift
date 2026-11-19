import AppKit
import ApplicationServices
import Carbon

final class ScreenQuestionObservation {
    enum Control: String, CaseIterable, Sendable {
        case close = "Close"
        case minimize = "Minimize"

        var spokenAnswer: String {
            switch self {
            case .close: return "Close normally closes the current window."
            case .minimize: return "Minimize normally moves the current window to the Dock."
            }
        }

        fileprivate var attribute: String {
            switch self {
            case .close: return kAXCloseButtonAttribute
            case .minimize: return kAXMinimizeButtonAttribute
            }
        }
    }

    struct Window: Equatable, Sendable {
        let bundleID: String
        let pid: pid_t
        let windowID: UInt32

        static func captured(_ context: VoiceAdmissionContext) -> Self? {
            guard let app = context.targetAppID, !app.isEmpty, let target = context.targetID,
                  let number = context.windowID, let id = UInt32(exactly: number), id > 0 else { return nil }
            let fields = target.split(separator: ":")
            guard fields.count == 3, let pid = pid_t(fields[1]), pid > 0,
                  target == "window:\(pid):\(id)" else { return nil }
            return Self(bundleID: app, pid: pid, windowID: id)
        }
    }

    static let unknown = "I can’t identify that button. Ask about Close or Minimize in this window."

    static func isScreenInquiry(_ text: String, context: VoiceAdmissionContext = .init()) -> Bool {
        guard text.utf8.count <= 4_000 else { return false }
        if requestedControl(in: text) != nil { return true }
        let normalized = VoiceAdmissionPolicy.normalized(text)
        if normalized.range(of: #"^(?:click|tap|select|open|press|choose|hit) (?:what|the (?:button|control|item)) i (?:am|m) (?:looking|pointing) at$"#, options: .regularExpression) != nil {
            return false
        }
        let target = #"\b(?:(?:this|that|the current|my|on the) (?:page|window|button|screen|display)|the (?:screen|display)|(?:close|minimize) button|(?:looking|pointing) at|on screen)\b"#
        guard normalized.range(of: target, options: .regularExpression) != nil else { return false }
        if FastAction.retiredTargetRequest(text) != nil { return false }
        if text.contains("?") { return true }
        let inquiry = #"\b(?:what|which|where|why|how|describe|explain|summari[sz]e|identify|overview|tell me about|read|translate)\b"#
        let auxiliary = #"^(?:(?:hey )?(?:jev|jarvis) |please )*(?:is|are|was|were|do|does|did|can|could|will|would|has|have|should)\b"#
        if normalized.range(of: inquiry, options: .regularExpression) != nil
            || normalized.range(of: auxiliary, options: .regularExpression) != nil { return true }
        if let prefix = ["i want ", "i would like ", "let me have "].first(where: normalized.hasPrefix),
           let suffix = [" on my screen", " on screen"].first(where: normalized.hasSuffix),
           normalized.count > prefix.count + suffix.count {
            let object = String(normalized.dropFirst(prefix.count).dropLast(suffix.count))
            let role = ["my default email application": "mailto", "my default browser": "https"][object]
            let matches = context.entities.filter {
                VoiceAdmissionPolicy.normalized($0.name) == object || role.flatMap { context.appRoles[$0] } == $0.id
            }
            let ids = Set(matches.map(\.id))
            if ids.count == 1, let id = ids.first, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        if FastAction.parse(text) != nil { return false }
        return normalized.range(of: #"^(?:click|tap|press|select|open|choose|hit) (?:this|that) (?:one|button|link|control|item)$"#,
                                options: .regularExpression) == nil
    }

    static func requestedControl(in final: String) -> Control? {
        guard final.utf8.count <= 160 else { return nil }
        var text = final.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.last == "?" || text.last == "." { text.removeLast() }
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return Control.allCases.first { control in
            ["this window", "the current window"].contains { scope in
                words == "what does the \(control.rawValue.lowercased()) button in \(scope) do"
            }
        }
    }

    struct Target<Node: Equatable & Sendable>: Equatable, Sendable {
        let window: Node
        let button: Node
        let focus: Node
    }

    private let control: Control
    private let expires: TimeInterval
    private let clock: @MainActor () -> TimeInterval
    private let isCurrent: @MainActor () -> Bool
    private let matches: @Sendable () async -> Bool
    @MainActor private var retired = false

    private init(control: Control, expires: TimeInterval, clock: @escaping @MainActor () -> TimeInterval,
                 isCurrent: @escaping @MainActor () -> Bool, matches: @escaping @Sendable () async -> Bool) {
        self.control = control
        self.expires = expires
        self.clock = clock
        self.isCurrent = isCurrent
        self.matches = matches
    }

    @MainActor
    static func bind(final: String, window: Window, isCurrent: @escaping @MainActor () -> Bool) async -> Self? {
        await bind(final: final, window: window, isCurrent: isCurrent,
                   clock: { ProcessInfo.processInfo.systemUptime }, read: NativeScreenQuestionAX.read)
    }

    @MainActor
    static func bind<Node: Equatable & Sendable>(
        final: String, window: Window, isCurrent: @escaping @MainActor () -> Bool,
        clock: @escaping @MainActor () -> TimeInterval,
        read: @escaping @Sendable (Window, Control) async -> Target<Node>?
    ) async -> Self? {
        guard let control = requestedControl(in: final), !window.bundleID.isEmpty,
              window.pid > 0, window.windowID > 0, !Task.isCancelled, isCurrent() else { return nil }
        let expires = clock() + 8
        guard let initial = await read(window, control),
              !Task.isCancelled, isCurrent(), clock() < expires else { return nil }
        return Self(control: control, expires: expires, clock: clock, isCurrent: isCurrent,
                    matches: { await read(window, control) == initial })
    }

    @MainActor
    var isFresh: Bool { !retired && !Task.isCancelled && clock() < expires && isCurrent() }

    @MainActor
    func verifiedControl() async -> Control? {
        guard isFresh, await matches(), isFresh else {
            retired = true
            return nil
        }
        return control
    }
}

protocol ScreenQuestionAXSource {
    associatedtype Node: Equatable & Sendable
    func activeApplication(_ window: ScreenQuestionObservation.Window) -> Node?
    func node(_ parent: Node, _ attribute: String) -> Node?
    func name(_ node: Node, _ attribute: String) -> String?
    func flag(_ node: Node, _ attribute: String) -> Bool?
    func owned(_ node: Node, by pid: pid_t) -> Bool
    func windowNumber(_ node: Node) -> UInt32?
}

extension ScreenQuestionAXSource {
    func target(in scope: ScreenQuestionObservation.Window, control: ScreenQuestionObservation.Control)
        -> ScreenQuestionObservation.Target<Node>? {
        guard let app = activeApplication(scope), let window = node(app, kAXFocusedWindowAttribute),
              owned(window, by: scope.pid), windowNumber(window) == scope.windowID,
              name(window, kAXRoleAttribute) == kAXWindowRole,
              name(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              flag(window, kAXModalAttribute) == false, flag(window, kAXMinimizedAttribute) == false,
              let focusedElement = node(app, kAXFocusedUIElementAttribute) else { return nil }
        var focus = focusedElement
        let safeRoles = ["AXButton", "AXToolbar", "AXGroup", "AXSplitGroup", "AXScrollArea", "AXList",
                         "AXOutline", "AXTable", "AXRow", "AXCell", "AXTabGroup"]
        for _ in 0..<8 {
            if focus == window { break }
            guard owned(focus, by: scope.pid), let role = name(focus, kAXRoleAttribute),
                  safeRoles.contains(role), let parent = node(focus, kAXParentAttribute),
                  parent != focus else { return nil }
            focus = parent
        }
        guard focus == window, let button = node(window, control.attribute),
              owned(button, by: scope.pid), node(button, kAXWindowAttribute) == window,
              node(button, kAXTopLevelUIElementAttribute) == window,
              name(button, kAXRoleAttribute) == kAXButtonRole,
              name(button, kAXSubroleAttribute) == control.attribute,
              flag(button, kAXEnabledAttribute) == true,
              activeApplication(scope) == app, node(app, kAXFocusedWindowAttribute) == window,
              node(app, kAXFocusedUIElementAttribute) == focusedElement else { return nil }
        return .init(window: window, button: button, focus: focusedElement)
    }
}

private struct NativeScreenQuestionAX: ScreenQuestionAXSource {
    struct Node: @unchecked Sendable, Equatable {
        let value: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.value, rhs.value) }
    }

    private let deadline = ProcessInfo.processInfo.systemUptime + 0.30

    static func read(_ scope: ScreenQuestionObservation.Window, _ control: ScreenQuestionObservation.Control)
        async -> ScreenQuestionObservation.Target<Node>? {
        let work = Task.detached(priority: .userInitiated) {
            let source = Self()
            let witness = source.target(in: scope, control: control)
            return !Task.isCancelled && ProcessInfo.processInfo.systemUptime < source.deadline ? witness : nil
        }
        return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    func activeApplication(_ window: ScreenQuestionObservation.Window) -> Node? {
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
              AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == window.pid, front.bundleIdentifier == window.bundleID else { return nil }
        return Node(value: AXUIElementCreateApplication(window.pid))
    }

    private func ready(_ node: Node) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        return !Task.isCancelled && remaining > 0
            && AXUIElementSetMessagingTimeout(node.value, Float(min(remaining, 0.1))) == .success
    }

    private func attribute(_ node: Node, _ name: String) -> CFTypeRef? {
        guard ready(node) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node.value, name as CFString, &result) == .success else { return nil }
        return result
    }

    func node(_ parent: Node, _ name: String) -> Node? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return Node(value: value as! AXUIElement)
    }

    func name(_ node: Node, _ key: String) -> String? { attribute(node, key) as? String }

    func flag(_ node: Node, _ key: String) -> Bool? {
        guard let value = attribute(node, key), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    func owned(_ node: Node, by pid: pid_t) -> Bool {
        var owner: pid_t = 0
        return ready(node) && AXUIElementGetPid(node.value, &owner) == .success && owner == pid
    }

    func windowNumber(_ node: Node) -> UInt32? {
        ready(node) ? FocusedTextBinding.windowNumber(node.value) : nil
    }
}
