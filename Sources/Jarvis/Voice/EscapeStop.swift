import AppKit

/// Escape is the keyboard emergency stop. While Jarvis is busy, a global
/// and a local keyDown monitor watch for Escape and call the universal
/// cancel. They only observe: the key still reaches the frontmost app, and
/// no monitor is installed while Jarvis is idle.
@MainActor
final class EscapeStop {
    static let escapeKeyCode: UInt16 = 53

    private let isActive: () -> Bool
    private let stop: () -> Void
    private var monitors: [Any] = []

    init(isActive: @escaping () -> Bool, stop: @escaping () -> Void) {
        self.isActive = isActive
        self.stop = stop
    }

    /// Installs the monitors while Jarvis is busy and removes them when it rests.
    func refresh() {
        let active = isActive()
        if active, monitors.isEmpty {
            monitors = [
                NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let keyCode = event.keyCode
                    MainActor.assumeIsolated { _ = self?.handle(keyCode: keyCode) }
                },
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let keyCode = event.keyCode
                    MainActor.assumeIsolated { _ = self?.handle(keyCode: keyCode) }
                    return event
                },
            ].compactMap { $0 }
        } else if !active, !monitors.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        }
    }

    /// True when the key was Escape and Jarvis was busy, so the stop ran.
    @discardableResult
    func handle(keyCode: UInt16) -> Bool {
        guard keyCode == Self.escapeKeyCode, isActive() else { return false }
        stop()
        return true
    }
}
