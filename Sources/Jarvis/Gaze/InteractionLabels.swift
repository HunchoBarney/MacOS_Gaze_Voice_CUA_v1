import AppKit
import ApplicationServices

/// Invisible calibration's everyday label sources on the host side: the
/// user's own left clicks and the text caret while they type. Each one is
/// a moment the eyes were very likely on a known point (Huang et al. 2014,
/// PACE CHI 2016). Listen-only global monitors — nothing is consumed or
/// altered, and no typed text is read: only the caret's on-screen rect.
@MainActor
final class InteractionLabels {
    /// Posts one label — the service routes it through its ImplicitLabeler.
    private let emit: (CGPoint, ImplicitLabelKind) -> Void
    private var monitors: [Any] = []
    private var lastCaretAt: TimeInterval = -.greatestFiniteMagnitude
    private var caretLookup: Task<Void, Never>?

    /// Typing streams keys; one caret label per this many seconds is
    /// plenty and keeps the AX reads off the typing path.
    static let caretInterval: TimeInterval = 1.5
    /// Taller than a text line isn't a caret (a whole field's bounds).
    static let maxCaretHeight: CGFloat = 80

    init(emit: @escaping (CGPoint, ImplicitLabelKind) -> Void) {
        self.emit = emit
    }

    func start() {
        guard monitors.isEmpty else { return }
        if let click = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            // Synthetic clicks (Cua, dwell actuation, any automation)
            // were chosen by software, often from gaze itself — only a
            // hand on the trackpad is ground truth.
            guard Self.isHardwareEvent(sourcePID: event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)) else { return }
            let point = ScreenGeometry.appKitToTopLeft(NSEvent.mouseLocation)
            MainActor.assumeIsolated { self?.emit(point, .click) }
        }) {
            monitors.append(click)
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard Self.isHardwareEvent(sourcePID: event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)) else { return }
            MainActor.assumeIsolated { self?.typed() }
        }) {
            monitors.append(keys)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        caretLookup?.cancel()
        caretLookup = nil
    }

    /// Hardware input carries no posting process; anything a process
    /// posted with CGEventPost names it.
    nonisolated static func isHardwareEvent(sourcePID: Int64?) -> Bool {
        sourcePID == 0
    }

    private func typed() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaretAt >= Self.caretInterval, caretLookup == nil else { return }
        lastCaretAt = now
        caretLookup = Task.detached(priority: .utility) { [weak self] in
            let caret = Self.caretRect()
            await MainActor.run {
                guard let self else { return }
                self.caretLookup = nil
                if let caret { self.emit(CGPoint(x: caret.midX, y: caret.midY), .caret) }
            }
        }
    }

    /// The focused text field's caret in global top-left points (AX's own
    /// space), or nil when there's no plain text caret to read. Secure
    /// fields are skipped outright.
    nonisolated static func caretRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let field = focused as! AXUIElement
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole) == .success,
           subrole as? String == kAXSecureTextFieldSubrole as String { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        // An empty range has no bounds in many apps — measure the character
        // just before the caret (or the selection's last one) instead.
        let end = range.location + range.length
        guard end > 0 else { return nil }
        var probe = CFRange(location: end - 1, length: 1)
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         probeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
              rect.height > 0, rect.height <= maxCaretHeight
        else { return nil }
        return rect
    }
}
