import AppKit
import ApplicationServices
import Foundation

/// A live Accessibility element — the identity the spine acts on for the
/// selection, focus and pointer fallbacks. Equal when CFEqual says so.
struct AXElementHandle: @unchecked Sendable, Equatable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
}

/// The element a deictic word ("this", "that", "here", "it") named. It is
/// an identity, never a point: gaze referents carry the feed's candidate id
/// ("ax:<pid>:<windowID>:<element token>", "dom:…"), the Accessibility
/// fallbacks carry the live element itself.
struct DeicticReferent: Sendable, Equatable {
    enum Source: String, Sendable {
        case gaze, selection, focus, pointer
    }

    var id: String
    var source: Source
    var role: String
    var label: String
    var appName: String?
    var windowTitle: String?
    var pid: Int32?
    var windowID: Int?
    /// The gaze fixation's softmax share; nil for the fallbacks.
    var confidence: Double?
    /// The live element for the fallbacks; nil for gaze, whose id holds
    /// the driver's element token.
    var element: AXElementHandle?

    /// One short line for the conversation (session.thinking.append) —
    /// what "this" is, with no coordinates and no field contents.
    var contextLine: String {
        var parts = ["\(source.rawValue): \(role) \"\(label)\""]
        if let appName, !appName.isEmpty { parts.append("in \(appName)") }
        if let windowTitle, !windowTitle.isEmpty { parts.append("window \"\(windowTitle)\"") }
        return parts.joined(separator: ", ")
    }
}

enum DeicticResolution: Sendable, Equatable {
    case resolved(DeicticReferent)
    /// Nothing to point at — ask "which one?".
    case whichOne
}

/// Resolves "this" at the moment it was said. The fixation the eyes held
/// at word time wins; with gaze off, stale or unsure, the text selection,
/// then the focused element, then the element under the pointer; otherwise
/// the caller asks "which one?". A resolution flashes a small ring on the
/// element (D6). Gaze never acts here: the caller owns every action.
@MainActor
final class DeicticResolver {
    /// What a source found: the referent plus the frame the ring flashes
    /// on. The frame stays inside the resolver.
    struct Hit: Sendable {
        var referent: DeicticReferent
        var frame: CGRect?
    }

    static let shared = DeicticResolver()

    /// Below this share a fixation is a guess, not "this" (plan §5).
    static let gazeConfidenceFloor = 0.4

    // MARK: Seams — production reads gaze and Accessibility; tests stub.

    var fixation: (TimeInterval) -> GazeFixation? = { GazeService.shared.fixation(at: $0) }
    var selection: () async -> Hit? = { await Task.detached { DeicticAXProbe.selection() }.value }
    var focus: () async -> Hit? = { await Task.detached { DeicticAXProbe.focus() }.value }
    var pointer: () async -> Hit? = {
        let point = ScreenGeometry.appKitToTopLeft(NSEvent.mouseLocation)
        return await Task.detached { DeicticAXProbe.pointer(at: point) }.value
    }
    var flash: (CGRect) -> Void = { DeicticFlash.shared.flash(frame: $0) }

    /// `wordTime` is when the deictic word was spoken, in
    /// `ProcessInfo.processInfo.systemUptime` seconds — the clock
    /// `GazeService` stamps fixations with.
    func resolve(wordTime: TimeInterval) async -> DeicticResolution {
        guard let hit = await firstHit(wordTime: wordTime) else { return .whichOne }
        if let frame = hit.frame { flash(frame) }
        return .resolved(hit.referent)
    }

    private func firstHit(wordTime: TimeInterval) async -> Hit? {
        if let gaze = fixation(wordTime), gaze.confidence >= Self.gazeConfidenceFloor {
            return Self.gazeHit(gaze)
        }
        if let hit = await selection() { return hit }
        if let hit = await focus() { return hit }
        return await pointer()
    }

    nonisolated static func gazeHit(_ fixation: GazeFixation) -> Hit {
        let c = fixation.candidate
        return Hit(referent: DeicticReferent(
            id: c.id, source: .gaze, role: c.role, label: c.label,
            appName: c.appName, windowTitle: c.windowTitle, pid: c.pid,
            windowID: c.windowID, confidence: fixation.confidence, element: nil),
            frame: c.motorRect)
    }
}

/// The Accessibility fallbacks. Each call is synchronous AX IPC with a
/// short messaging timeout, so the resolver runs them off the main actor.
enum DeicticAXProbe {
    static let messagingTimeout: Float = 0.2

    /// The focused element when it holds a text selection, or a single
    /// selected row or item (a file in Finder, a message in Mail).
    static func selection() -> DeicticResolver.Hit? {
        guard let focused = focusedElement() else { return nil }
        if let range = attribute(focused, kAXSelectedTextRangeAttribute),
           CFGetTypeID(range) == AXValueGetTypeID() {
            var selected = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &selected), selected.length > 0 {
                return hit(focused, source: .selection)
            }
        }
        for name in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] {
            if let items = attribute(focused, name) as? [AXUIElement], items.count == 1 {
                return hit(items[0], source: .selection)
            }
        }
        return nil
    }

    static func focus() -> DeicticResolver.Hit? {
        focusedElement().flatMap { hit($0, source: .focus) }
    }

    /// `point` is the pointer in global top-left points.
    static func pointer(at point: CGPoint) -> DeicticResolver.Hit? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        return hit(element, source: .pointer)
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        return elementAttribute(system, kAXFocusedUIElementAttribute)
    }

    /// Jarvis's own windows and the bare application element are never "this".
    private static func hit(_ element: AXUIElement, source: DeicticReferent.Source) -> DeicticResolver.Hit? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        guard !role.isEmpty, role != kAXApplicationRole else { return nil }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .lazy.compactMap { attribute(element, $0) as? String }
            .first { !$0.isEmpty } ?? ""
        let window = role == kAXWindowRole ? element : elementAttribute(element, kAXWindowAttribute)
        let windowID = window.flatMap(FocusedTextBinding.windowNumber).map(Int.init)
        let referent = DeicticReferent(
            id: "axref:\(pid):\(windowID ?? 0):\(CFHash(element))",
            source: source, role: role, label: label,
            appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            windowTitle: window.flatMap { attribute($0, kAXTitleAttribute) as? String },
            pid: pid, windowID: windowID, confidence: nil,
            element: AXElementHandle(element))
        return DeicticResolver.Hit(referent: referent, frame: frame(element))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
