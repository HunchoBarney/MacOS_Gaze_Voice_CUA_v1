import AppKit
import ApplicationServices

/// Something the person did while a guide step waited: a click (with what
/// was under it), or keyboard progress the accessibility tree reported.
struct UserAction: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case click(CGPoint)
        case focusChanged
        case valueChanged
        case windowCreated
        case menuOpened
        case menuClosed
        case appActivated
    }
    var kind: Kind
    /// The process the action landed in, when known.
    var pid: Int?
    /// What was clicked, focused or changed, when the tree said.
    var element: GuideElement?
    /// On the guide clock.
    var at: TimeInterval
}

/// The injectable seam: tests feed synthetic actions; the app wires
/// `UserActionObserver`.
@MainActor
protocol UserActionSource: AnyObject {
    func start(watching pid: Int, emit: @escaping @Sendable (UserAction) -> Void)
    func stop()
}

/// Watches what the person does, listen-only, with the Accessibility
/// permission Jarvis already holds. A global mouse-down monitor plus
/// `AXUIElementCopyElementAtPosition` names what they clicked; AXObserver
/// notifications on the app (focus, new window, menu open and close, value
/// change) count keyboard progress. Nothing is consumed and no field's value is
/// read: the judge needs only role, label and frame. Synthetic clicks (the
/// driver's own, when Jarvis does a step) are ignored.
@MainActor
final class UserActionObserver: UserActionSource {
    /// Every AX read gets a short messaging timeout (#540): an unresponsive
    /// app must not hold the main actor for the AX default of about 6 s.
    nonisolated static let messagingTimeout: Float = 0.25
    nonisolated static let notifications: [(String, UserAction.Kind)] = [
        (kAXFocusedUIElementChangedNotification, .focusChanged),
        (kAXWindowCreatedNotification, .windowCreated),
        (kAXMenuOpenedNotification, .menuOpened),
        (kAXMenuClosedNotification, .menuClosed),
        (kAXValueChangedNotification, .valueChanged),
    ]

    private let now: @Sendable () -> TimeInterval
    private var monitors: [Any] = []
    private var activation: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var watchedPID: pid_t = 0
    private var emit: (@Sendable (UserAction) -> Void)?

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func start(watching pid: Int, emit: @escaping @Sendable (UserAction) -> Void) {
        stop()
        self.emit = emit
        let now = self.now
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            guard InteractionLabels.isHardwareEvent(
                sourcePID: event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)) else { return }
            let point = ScreenGeometry.appKitToTopLeft(NSEvent.mouseLocation)
            let at = now()
            Task.detached(priority: .userInitiated) {
                let hit = Self.hitTest(point)
                emit(UserAction(kind: .click(point), pid: hit?.pid, element: hit?.element, at: at))
            }
        }) {
            monitors.append(clicks)
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let pid = app.processIdentifier
            emit(UserAction(kind: .appActivated, pid: Int(pid), element: nil, at: now()))
            MainActor.assumeIsolated { self?.watch(pid) }
        }
        watch(pid_t(pid))
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        unwatch()
        emit = nil
    }

    private func watch(_ pid: pid_t) {
        guard pid > 0, pid != watchedPID else { return }
        unwatch()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let observer = Unmanaged<UserActionObserver>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { observer.received(element, notification as String) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for (name, _) in Self.notifications {
            _ = AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        axObserver = created
        watchedPID = pid
    }

    private func unwatch() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        watchedPID = 0
    }

    private func received(_ element: AXUIElement, _ notification: String) {
        guard let emit, let kind = Self.notifications.first(where: { $0.0 == notification })?.1 else { return }
        let pid = Int(watchedPID), at = now()
        nonisolated(unsafe) let element = element
        Task.detached(priority: .userInitiated) {
            emit(UserAction(kind: kind, pid: pid, element: Self.describe(element), at: at))
        }
    }

    /// The app whose window is under the point, then the deepest element
    /// there. The timeout goes on the app element, never the system-wide
    /// one, which would set it for the whole process.
    nonisolated static func hitTest(_ point: CGPoint) -> (pid: Int, element: GuideElement?)? {
        guard let pid = windowOwner(at: point) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return (Int(pid), nil) }
        return (Int(pid), describe(hit))
    }

    nonisolated static func windowOwner(at point: CGPoint) -> pid_t? {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let own = ProcessInfo.processInfo.processIdentifier
        for row in rows where (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
            guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != own,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            return pid
        }
        return nil
    }

    nonisolated static func describe(_ element: AXUIElement) -> GuideElement? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        func string(_ attribute: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
            return ref as? String
        }
        guard let role = string(kAXRoleAttribute) else { return nil }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .lazy.compactMap { string($0) }.first { !$0.isEmpty } ?? ""
        var frame: CGRect?
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let positionRef, let sizeRef,
           CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            var position = CGPoint.zero, size = CGSize.zero
            if AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
               AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: position, size: size)
            }
        }
        return GuideElement(role: role, label: label, frame: frame)
    }
}
