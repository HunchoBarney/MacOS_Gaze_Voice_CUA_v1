import ApplicationServices
import Carbon
import Foundation
import os

@MainActor
final class CommittedGazeHit {
    struct Hit<Node: Equatable & Sendable>: Equatable, Sendable {
        let element: Node
        let window: Node
        let ancestors: [Node]
        let pid: pid_t
        let windowID: Int
        let windowTitle: String
        let role: String
        let name: String
        let detail: String
        let frame: CGRect
        let light: WindowControls.Kind?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.element == rhs.element && lhs.window == rhs.window && lhs.ancestors == rhs.ancestors
                && lhs.pid == rhs.pid && lhs.windowID == rhs.windowID && lhs.frame == rhs.frame
                && lhs.role == rhs.role && lhs.light == rhs.light
                && lhs.windowTitle.utf8.elementsEqual(rhs.windowTitle.utf8)
                && lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.detail.utf8.elementsEqual(rhs.detail.utf8)
        }

        func describes(_ candidate: IntentCandidate, at point: CGPoint) -> Bool {
            guard pid > 0, windowID > 0, point.x.isFinite, point.y.isFinite, frame.contains(point),
                  candidate.frame == frame, candidate.motorRect == frame,
                  pid == candidate.pid, windowID == candidate.windowID,
                  candidate.role == role, candidate.windowTitle.map({ $0.utf8.elementsEqual(windowTitle.utf8) }) == true
            else { return false }
            if let light {
                return role == "AXButton" && candidate.kind == .trafficLight
                    && candidate.id == "traffic:\(pid):\(windowID):\(light.rawValue)"
                    && candidate.label == light.spokenName
            }
            guard candidate.kind == .axElement, ["AXButton", "AXLink", "AXCheckBox"].contains(role),
                  !name.isEmpty, candidate.label.utf8.elementsEqual(name.utf8) else { return false }
            let prefix = "ax:\(pid):\(windowID):s"
            guard candidate.id.hasPrefix(prefix) else { return false }
            let parts = candidate.id.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].utf8.count == 8,
                  parts[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let index = UInt(parts[1]), String(index) == parts[1] else { return false }
            return true
        }
    }

    private let descriptor: (IntentCandidate, CGPoint) -> Bool
    private let baseline: Any
    private let sameAs: (Any) -> Bool
    private let reread: (CGPoint) -> Bool
    private let backgroundRead: (CGPoint) async -> Bool
    private let prepare: () -> Bool
    private let post: () -> Bool
    private var authorizedPoint: CGPoint?
    private var retired = false

    private init<Node: Equatable & Sendable>(_ initial: Hit<Node>, read: @escaping (CGPoint) -> Hit<Node>?,
                                  asyncRead: @escaping (CGPoint) async -> Hit<Node>?,
                                  prepare: @escaping (Node) -> Bool,
                                  press: @escaping (Node) -> Bool) {
        descriptor = { initial.describes($0, at: $1) }
        baseline = initial
        sameAs = { ($0 as? Hit<Node>) == initial }
        reread = { read($0) == initial }
        backgroundRead = { await asyncRead($0) == initial }
        self.prepare = { prepare(initial.element) }
        post = { press(initial.element) }
    }

    static func capture(at point: CGPoint) async -> CommittedGazeHit? {
        await capture(at: point, enumerating: { NativeCommittedHit.read($0) }, prepare: NativeCommittedHit.prepare,
                      press: NativeCommittedHit.press)
    }

    static func capture<Node: Equatable & Sendable>(at point: CGPoint,
                            enumerating read: @escaping @Sendable (CGPoint) -> Hit<Node>?,
                            prepare: @escaping (Node) -> Bool = { _ in true },
                            press: @escaping (Node) -> Bool) async -> CommittedGazeHit? {
        let background: (CGPoint) async -> Hit<Node>? = { p in
            let task = Task.detached(priority: .utility) { Task.isCancelled ? nil : read(p) }
            return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        }
        guard !Task.isCancelled, point.x.isFinite, point.y.isFinite,
              let hit = await background(point), !Task.isCancelled, hit.frame.contains(point) else { return nil }
        return CommittedGazeHit(hit, read: read, asyncRead: background, prepare: prepare, press: press)
    }

    static func capture<Node: Equatable & Sendable>(at point: CGPoint, read: @escaping (CGPoint) -> Hit<Node>?,
                                         prepare: @escaping (Node) -> Bool = { _ in true },
                                         press: @escaping (Node) -> Bool) -> CommittedGazeHit? {
        guard !Task.isCancelled, point.x.isFinite, point.y.isFinite,
              let hit = read(point), hit.frame.contains(point) else { return nil }
        return CommittedGazeHit(hit, read: read, asyncRead: { read($0) }, prepare: prepare, press: press)
    }

    func describes(_ candidate: IntentCandidate, at point: CGPoint) -> Bool {
        !retired && descriptor(candidate, point)
    }

    func representsSameElement(as other: CommittedGazeHit) -> Bool {
        !retired && !other.retired && sameAs(other.baseline)
    }

    func corroborates(_ candidate: IntentCandidate, at point: CGPoint) async -> Bool {
        guard !retired, !Task.isCancelled, descriptor(candidate, point) else { return false }
        let matched = await backgroundRead(point)
        guard !retired, !Task.isCancelled else { return false }
        if !matched { retired = true; authorizedPoint = nil }
        return matched
    }

    func matches(_ candidate: IntentCandidate, at point: CGPoint) -> Bool {
        authorizedPoint = nil
        guard !retired, !Task.isCancelled, descriptor(candidate, point) else { return false }
        guard reread(point), !Task.isCancelled else { retired = true; return false }
        authorizedPoint = point
        return true
    }

    func press(ifCurrent: @MainActor () -> Bool) -> Bool {
        guard !retired, let point = authorizedPoint else { return false }
        retired = true
        authorizedPoint = nil
        guard !Task.isCancelled, reread(point), prepare(), !Task.isCancelled, ifCurrent() else { return false }
        return post()
    }

    nonisolated static func confirmsVisibility<Node: Equatable>(of hit: Node, at point: CGPoint,
                             pid: pid_t, id: UInt32, rows: [[String: Any]], rehit: () -> Node?) -> Bool {
        for row in rows.prefix(128) {
            guard let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  let layer = row[kCGWindowLayer as String] as? NSNumber else { break }
            guard bounds.contains(point), layer.intValue == 0 else { continue }
            guard (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id,
                  (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return false }
            return rehit() == hit
        }
        return false
    }
}

private enum NativeCommittedHit {
    struct Node: Equatable, @unchecked Sendable {
        let ax: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.ax, rhs.ax) }
    }
    typealias Hit = CommittedGazeHit.Hit<Node>
    private static let slot = DispatchSemaphore(value: 1)

    static func read(_ point: CGPoint) -> Hit? {
        guard slot.wait(timeout: .now()) == .success else { return nil }
        let deadline = DispatchTime.now() + .milliseconds(100)
        let result = OSAllocatedUnfairLock(initialState: Optional<Hit>.none)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { slot.signal(); done.signal() }
            let hit = observe(point, deadline: deadline)
            result.withLock { $0 = hit }
        }
        guard done.wait(timeout: deadline) == .success, DispatchTime.now() < deadline else { return nil }
        return result.withLock { $0 }
    }

    static func prepare(_ node: Node) -> Bool {
        !IsSecureEventInputEnabled() && AXUIElementSetMessagingTimeout(node.ax, 0.1) == .success
    }

    static func press(_ node: Node) -> Bool {
        AXUIElementPerformAction(node.ax, kAXPressAction as CFString) == .success
    }

    private static func observe(_ point: CGPoint, deadline: DispatchTime) -> Hit? {
        func ready(_ node: AXUIElement) -> Bool {
            let time = DispatchTime.now()
            guard time < deadline else { return false }
            let seconds = Float(deadline.uptimeNanoseconds - time.uptimeNanoseconds) / 1e9
            return AXUIElementSetMessagingTimeout(node, min(seconds, 0.05)) == .success
        }
        func attribute(_ n: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ready(n) else { return nil }
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(n, key as CFString, &v) == .success else { return nil }
            return v
        }
        func text(_ n: AXUIElement, _ key: String) -> String? {
            guard ready(n) else { return nil }
            var v: CFTypeRef?
            switch AXUIElementCopyAttributeValue(n, key as CFString, &v) {
            case .attributeUnsupported, .noValue: return ""
            case .success: return v as? String
            default: return nil
            }
        }
        func node(_ n: AXUIElement, _ key: String) -> AXUIElement? {
            guard let v = attribute(n, key), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
        func flag(_ n: AXUIElement, _ key: String) -> Bool? {
            guard let v = attribute(n, key), CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
            return (v as? NSNumber)?.boolValue
        }
        func owner(_ n: AXUIElement) -> pid_t? {
            var pid: pid_t = 0
            guard ready(n), AXUIElementGetPid(n, &pid) == .success, pid > 0 else { return nil }
            return pid
        }
        guard DispatchTime.now() < deadline, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        var at: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &at) == .success,
              let hit = at, let pid = owner(hit), pid != ProcessInfo.processInfo.processIdentifier,
              let window = node(hit, kAXWindowAttribute), owner(window) == pid,
              let top = node(hit, kAXTopLevelUIElementAttribute), CFEqual(top, window),
              text(window, kAXRoleAttribute) == "AXWindow", text(window, kAXSubroleAttribute) == "AXStandardWindow",
              flag(window, kAXModalAttribute) == false, flag(window, kAXMinimizedAttribute) == false,
              ready(window), let wid = FocusedTextBinding.windowNumber(window), wid > 0,
              let title = text(window, kAXTitleAttribute),
              let role = text(hit, kAXRoleAttribute), ["AXButton", "AXLink", "AXCheckBox"].contains(role),
              let subrole = text(hit, kAXSubroleAttribute), flag(hit, kAXEnabledAttribute) == true,
              let label = text(hit, kAXTitleAttribute), let detail = text(hit, kAXDescriptionAttribute),
              let p = attribute(hit, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(hit, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size),
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let frame = CGRect(origin: origin, size: size)
        var actions: CFArray?
        guard frame.contains(point), ready(hit),
              AXUIElementCopyActionNames(hit, &actions) == .success,
              (actions as? [String])?.contains(kAXPressAction) == true else { return nil }

        let light: WindowControls.Kind?
        switch subrole {
        case kAXCloseButtonAttribute: light = .close
        case kAXMinimizeButtonAttribute: light = .minimize
        case kAXZoomButtonAttribute: light = .zoom
        case kAXFullScreenButtonAttribute: light = .fullscreen
        case "": light = nil
        default: return nil
        }
        let name = label.isEmpty ? detail : label
        if light != nil {
            guard role == "AXButton", let button = node(window, subrole), CFEqual(button, hit) else { return nil }
        } else {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  VoiceTaskCoordinator.deniedReason(in: [label, detail, title].joined(separator: " ")) == nil else { return nil }
        }
        var chain = [Node]()
        var cursor = hit
        for _ in 0..<8 {
            guard let parent = node(cursor, kAXParentAttribute), owner(parent) == pid else { return nil }
            if CFEqual(parent, window) { break }
            let n = Node(ax: parent)
            guard !chain.contains(n), let r = text(parent, kAXRoleAttribute),
                  ["AXGroup", "AXToolbar", "AXSplitGroup", "AXScrollArea", "AXTabGroup"].contains(r),
                  text(parent, kAXSubroleAttribute) == "" else { return nil }
            chain.append(n)
            cursor = parent
        }
        guard let parent = node(cursor, kAXParentAttribute), CFEqual(parent, window), DispatchTime.now() < deadline,
              let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let visible = CommittedGazeHit.confirmsVisibility(of: Node(ax: hit), at: point, pid: pid, id: wid, rows: rows) {
            var finalHit: AXUIElement?
            guard DispatchTime.now() < deadline,
                  AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &finalHit) == .success,
                  let finalHit, CFEqual(finalHit, hit), owner(finalHit) == pid,
                  let finalWindow = node(finalHit, kAXWindowAttribute), CFEqual(finalWindow, window),
                  let finalTop = node(finalHit, kAXTopLevelUIElementAttribute), CFEqual(finalTop, window),
                  owner(finalWindow) == pid, ready(finalWindow), FocusedTextBinding.windowNumber(finalWindow) == wid
            else { return nil }
            var ancestor = finalHit
            for expected in chain + [Node(ax: window)] {
                guard let next = node(ancestor, kAXParentAttribute), CFEqual(next, expected.ax), owner(next) == pid else { return nil }
                ancestor = next
            }
            return Node(ax: finalHit)
        }
        guard visible, DispatchTime.now() < deadline else { return nil }
        return Hit(element: Node(ax: hit), window: Node(ax: window), ancestors: chain, pid: pid, windowID: Int(wid),
                   windowTitle: title, role: role, name: name, detail: detail, frame: frame, light: light)
    }
}
