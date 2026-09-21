import AppKit
import Carbon

/// Event decisions are independent of the global tap so release/cancellation races are testable.
struct FnInputState {
    enum Kind { case flagsChanged, keyDown, keyUp }
    enum Action { case none, begin, finish, cancel, cancelCapture }
    struct Result { var action: Action = .none; var consume = false }
    private(set) var held = false
    private var armed = false
    private var escapeConsumed = false
    private var pressedKeys: Set<UInt16> = []

    mutating func reconcilePressedKeys(_ keys: Set<UInt16>) { pressedKeys = keys }

    mutating func interrupt() { armed = false }

    mutating func handle(_ kind: Kind, key: UInt16, fn: Bool, otherModifiers: Bool = false,
                         canBegin: Bool, active: Bool) -> Result {
        if kind == .keyDown { pressedKeys.insert(key) }
        if kind == .keyUp { pressedKeys.remove(key) }
        if key == 53 {
            if kind == .keyDown, escapeConsumed { return Result(consume: true) }
            if kind == .keyUp {
                let consume = escapeConsumed
                escapeConsumed = false
                return Result(consume: consume)
            }
            if kind == .keyDown, active {
                armed = false
                escapeConsumed = true
                return Result(action: .cancel, consume: true)
            }
        }
        if kind == .flagsChanged, key == 63 {
            guard fn != held else { return Result(consume: true) }
            held = fn
            if fn {
                armed = canBegin && !otherModifiers && pressedKeys.isEmpty
                return Result(action: armed ? .begin : .none, consume: !otherModifiers)
            }
            let finish = armed
            armed = false
            return Result(action: finish ? .finish : .none, consume: true)
        }
        if held, armed, kind == .keyDown || (kind == .flagsChanged && otherModifiers) {
            armed = false
            return Result(action: .cancelCapture)
        }
        return Result()
    }
}

@MainActor
final class FnInputMonitor: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var message = "Checking Fn shortcut…"
    var canBegin: () -> Bool = { false }
    var operationActive: () -> Bool = { false }
    var onAction: (FnInputState.Action) -> Void = { _ in }
    var onInterruption: (String) -> Void = { _ in }
    private var state = FnInputState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var healthTimer: Timer?
    private var observedPhysicalHold = false
    private(set) var beginHandlingMs: Double = 0

    func start() {
        refresh()
        guard healthTimer == nil else { return }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        RunLoop.main.add(healthTimer!, forMode: .common)
    }

    func stop() {
        healthTimer?.invalidate(); healthTimer = nil
        teardown()
    }

    func refresh() {
        guard AXIsProcessTrusted() else {
            interrupt("Enable Accessibility to use Fn hold-to-talk.")
            teardown()
            message = "Accessibility access needed for Fn"
            return
        }
        if let tap, CGEvent.tapIsEnabled(tap: tap) {
            ready = !IsSecureEventInputEnabled()
            message = ready ? "Hold Fn to speak, release to finish" : "Fn is unavailable while secure keyboard input is active"
            return
        }
        teardown()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<FnInputMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            teardown()
            message = "Could not register Fn. Check Accessibility and relaunch."
            return
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ready = CGEvent.tapIsEnabled(tap: tap) && !IsSecureEventInputEnabled()
        message = ready ? "Hold Fn to speak, release to finish" : "Fn is temporarily unavailable"
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let handlingStarted = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interrupt("Keyboard monitoring was interrupted. Hold Fn again to retry.")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kind: FnInputState.Kind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return Unmanaged.passUnretained(event)
        }
        if kind == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == 63 {
            // Reconcile after missed events/tap interruptions, including keys held before launch.
            let modifiers: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            state.reconcilePressedKeys(Set((UInt16(0)...127).filter {
                !modifiers.contains($0) && CGEventSource.keyState(.hidSystemState, key: $0)
            }))
        }
        let other: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let result = state.handle(kind, key: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                                  fn: event.flags.contains(.maskSecondaryFn),
                                  otherModifiers: !event.flags.intersection(other).isEmpty,
                                  canBegin: ready && canBegin(), active: operationActive())
        if kind == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == 63 {
            observedPhysicalHold = state.held && physicalFnDown
        }
        if result.action == .begin { beginHandlingMs = (ProcessInfo.processInfo.systemUptime - handlingStarted) * 1000 }
        if result.action != .none { onAction(result.action) }
        return result.consume ? nil : Unmanaged.passUnretained(event)
    }

    private func checkHealth() {
        if IsSecureEventInputEnabled() {
            interrupt("Secure keyboard input interrupted recording.")
            ready = false
            message = "Fn is unavailable while secure keyboard input is active"
            return
        }
        if state.held && physicalFnDown { observedPhysicalHold = true }
        if state.held && observedPhysicalHold && !physicalFnDown {
            interrupt("The Fn release was missed. Hold Fn again to retry.")
            _ = state.handle(.flagsChanged, key: 63, fn: false, canBegin: false, active: false)
        }
        if !AXIsProcessTrusted() || tap == nil || !CGEvent.tapIsEnabled(tap: tap!) || !ready { refresh() }
    }

    private var physicalFnDown: Bool {
        CGEventSource.keyState(.hidSystemState, key: 63)
            || CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
    }

    private func interrupt(_ reason: String) {
        state.interrupt()
        // Only capture depends on keyboard health. App execution may itself enter secure input.
        if state.held { onInterruption(reason) }
    }

    private func teardown() {
        ready = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
}
