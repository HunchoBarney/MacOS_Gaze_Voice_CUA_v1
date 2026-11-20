import AppKit
import Carbon
import Synchronization

/// Event decisions are independent of the global tap so release/cancellation races are testable.
struct FnInputState: Sendable {
    enum Kind { case flagsChanged, keyDown, keyUp }
    enum Action { case none, begin, finish, cancel, cancelCapture }
    struct Result: Sendable {
        var action: Action = .none
        var consume = false
        /// Fn+Ctrl chord: on `.begin` the hold is dictation; on `.none` a live
        /// hold converts to dictation.
        var dictation = false
        /// Short Fn tap with latch mode on: release latches instead of finishing.
        var latch = false
    }
    /// Off until the coordinator binds the dictation seams — an armed chord
    /// with no consumer must fail closed, never start a planner capture.
    var dictationEnabled = false
    var latchMode = false
    var latchThreshold: TimeInterval = 0.4
    private(set) var held = false
    private(set) var latched = false
    private(set) var armed = false
    private var dictating = false
    private var escapeConsumed = false
    private var pressedKeys: Set<UInt16> = []
    private var pressedAt: TimeInterval?

    mutating func reconcilePressedKeys(_ keys: Set<UInt16>) { pressedKeys = keys }

    /// `held` deliberately survives: an interruption while the key is still
    /// down must not let the same physical hold re-arm a capture. The health
    /// check synthesizes the release when the tap misses it.
    mutating func interrupt() { armed = false; dictating = false; latched = false }

    mutating func handle(_ kind: Kind, key: UInt16, fn: Bool, otherModifiers: Bool = false,
                         dictationChord: Bool = false, now: TimeInterval? = nil,
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
                dictating = false
                latched = false
                escapeConsumed = true
                return Result(action: .cancel, consume: true)
            }
        }
        if kind == .flagsChanged, key == 63 {
            guard fn != held else { return Result(consume: true) }
            held = fn
            if fn {
                if latched {
                    // The second latch tap stops capture at Fn down.
                    latched = false
                    armed = false
                    dictating = false
                    return Result(action: .finish, consume: true)
                }
                pressedAt = now
                if dictationEnabled, dictationChord {
                    armed = canBegin && pressedKeys.isEmpty
                    dictating = armed
                    return Result(action: armed ? .begin : .none, consume: true, dictation: armed)
                }
                armed = canBegin && !otherModifiers && pressedKeys.isEmpty
                return Result(action: armed ? .begin : .none, consume: !otherModifiers)
            }
            let finish = armed
            let wasDictating = dictating
            armed = false
            dictating = false
            let down = pressedAt
            pressedAt = nil
            if finish, latchMode, !wasDictating,
               let down, let now, now - down < latchThreshold {
                latched = true
                return Result(action: .finish, consume: true, latch: true)
            }
            return Result(action: finish ? .finish : .none, consume: true)
        }
        if held, armed, !dictating, dictationEnabled, dictationChord,
           kind == .flagsChanged, key == 59 || key == 62 {
            // Ctrl joined an armed Fn hold — the capture becomes dictation.
            dictating = true
            return Result(consume: true, dictation: true)
        }
        if held, armed, !dictating, kind == .keyDown || (kind == .flagsChanged && otherModifiers) {
            armed = false
            return Result(action: .cancelCapture)
        }
        return Result()
    }
}

/// The tap's half of the monitor: it owns the state machine and runs on the
/// tap's own thread, so a stalled main thread never delays a keystroke.
/// Only Fn presses and Escape read main-actor gates, and those wait at most
/// `gateWait` for them before using the last published values.
final class FnTapCore: @unchecked Sendable {
    struct Gates: Sendable { var canBegin = false, active = false }
    struct Decision: Sendable {
        var interrupted = false
        var fnKey = false
        var fnFlag = false
        var heldWithPhysicalFn = false
        var result = FnInputState.Result()
        var beginHandlingMs: Double = 0
    }

    static let gateWait: DispatchTimeInterval = .milliseconds(100)
    let state: Mutex<FnInputState>
    let gates = Mutex(Gates())
    let tap = Mutex<CFMachPort?>(nil)
    let runLoop = Mutex<CFRunLoop?>(nil)
    nonisolated(unsafe) weak var monitor: FnInputMonitor?

    init(state: FnInputState) { self.state = Mutex(state) }

    func onTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let decision = decide(type, event) { needsGates in
            guard needsGates else { return gates.withLock { $0 } }
            let refreshed = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.monitor?.publishGates() }
                refreshed.signal()
            }
            _ = refreshed.wait(timeout: .now() + Self.gateWait)
            return gates.withLock { $0 }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.monitor?.apply(decision) }
        }
        return decision.result.consume ? nil : Unmanaged.passUnretained(event)
    }

    func decide(_ type: CGEventType, _ event: CGEvent, gates: (Bool) -> Gates) -> Decision {
        let handlingStarted = ProcessInfo.processInfo.systemUptime
        var decision = Decision()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.withLock { if let tap = $0 { CGEvent.tapEnable(tap: tap, enable: true) } }
            decision.interrupted = true
            return decision
        }
        let kind: FnInputState.Kind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return decision
        }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        decision.fnKey = kind == .flagsChanged && key == 63
        decision.fnFlag = event.flags.contains(.maskSecondaryFn)
        let current = gates((decision.fnKey && decision.fnFlag) || (kind == .keyDown && key == 53))
        let other: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let nonControl: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift]
        let pressed: Set<UInt16>? = decision.fnKey ? Self.pressedNonModifierKeys() : nil
        let (result, held) = state.withLock { state in
            // Reconcile after missed events/tap interruptions, including keys held before launch.
            if let pressed { state.reconcilePressedKeys(pressed) }
            let result = state.handle(kind, key: key, fn: decision.fnFlag,
                                      otherModifiers: !event.flags.intersection(other).isEmpty,
                                      dictationChord: event.flags.contains(.maskControl)
                                          && event.flags.intersection(nonControl).isEmpty,
                                      now: handlingStarted,
                                      canBegin: current.canBegin, active: current.active)
            return (result, state.held)
        }
        if decision.fnKey { decision.heldWithPhysicalFn = held && Self.physicalFnDown }
        decision.result = result
        if result.action == .begin {
            decision.beginHandlingMs = (ProcessInfo.processInfo.systemUptime - handlingStarted) * 1000
        }
        return decision
    }

    static var physicalFnDown: Bool {
        CGEventSource.keyState(.hidSystemState, key: 63)
            || CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
    }

    private static func pressedNonModifierKeys() -> Set<UInt16> {
        let modifiers: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return Set((UInt16(0)...127).filter {
            !modifiers.contains($0) && CGEventSource.keyState(.hidSystemState, key: $0)
        })
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
    var onReleaseRecovery: (TimeInterval, TimeInterval, Bool) -> Void = { _, _, _ in }
    var onPhysicalFnChanged: (Bool) -> Void = { _ in }
    private var reportedPhysicalFn: Bool?
    /// Fn+Ctrl seams — the coordinator binds these to dictation capture.
    var onDictationBegin: () -> Void = {}
    var onDictationConvert: () -> Void = {}
    /// Latch seam — fires on a tap-short release before `.finish` arrives.
    var onLatch: () -> Void = {}
    var dictationChordEnabled: Bool {
        get { core.state.withLock { $0.dictationEnabled } }
        set { core.state.withLock { $0.dictationEnabled = newValue } }
    }
    var latchMode: Bool {
        get { core.state.withLock { $0.latchMode } }
        set { core.state.withLock { $0.latchMode = newValue } }
    }
    let core: FnTapCore
    private var source: CFRunLoopSource?
    private var healthTimer: Timer?
    private var observedPhysicalHold = false
    private var releaseCandidate: TimeInterval?
    private(set) var beginHandlingMs: Double = 0

    init(state: FnInputState = FnInputState()) {
        core = FnTapCore(state: state)
        core.monitor = self
    }

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
        if let tap = core.tap.withLock({ $0 }), CGEvent.tapIsEnabled(tap: tap) {
            ready = !IsSecureEventInputEnabled()
            message = ready ? "Hold Fn to speak, release to finish" : "Fn is unavailable while secure keyboard input is active"
            publishGates()
            return
        }
        teardown()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<FnTapCore>.fromOpaque(context).takeUnretainedValue().onTap(type, event)
        }, userInfo: Unmanaged.passUnretained(core).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            teardown()
            message = "Could not register Fn. Check Accessibility and relaunch."
            return
        }
        core.tap.withLock { $0 = tap }
        self.source = source
        runOnOwnThread(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        ready = CGEvent.tapIsEnabled(tap: tap) && !IsSecureEventInputEnabled()
        message = ready ? "Hold Fn to speak, release to finish" : "Fn is temporarily unavailable"
        publishGates()
    }

    /// Services the tap on a dedicated thread's run loop, attached before
    /// this returns.
    private func runOnOwnThread(_ source: CFRunLoopSource) {
        let attached = DispatchSemaphore(value: 0)
        let thread = Thread { [core] in
            core.runLoop.withLock { $0 = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            attached.signal()
            CFRunLoopRun()
        }
        thread.name = "com.karanvirkang.jarvis.fn-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        attached.wait()
    }

    /// Main-actor entry for a delivered event: decides with the live gates and
    /// applies the outcome immediately. The tap thread uses `FnTapCore.onTap`.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let live = currentGates()
        let decision = core.decide(type, event) { _ in live }
        apply(decision)
        return decision.result.consume ? nil : Unmanaged.passUnretained(event)
    }

    func publishGates() {
        let live = currentGates()
        core.gates.withLock { $0 = live }
    }

    private func currentGates() -> FnTapCore.Gates {
        FnTapCore.Gates(canBegin: ready && canBegin(), active: operationActive())
    }

    func apply(_ decision: FnTapCore.Decision) {
        if decision.interrupted {
            interrupt("Keyboard monitoring was interrupted. Hold Fn again to retry.")
            return
        }
        if decision.fnKey {
            releaseCandidate = nil
            reportPhysicalFn(decision.fnFlag)
            observedPhysicalHold = decision.heldWithPhysicalFn
        }
        if decision.result.action == .begin {
            guard core.state.withLock({ $0.armed }), canBegin() else {
                core.state.withLock { $0.interrupt() }
                publishGates()
                return
            }
            beginHandlingMs = decision.beginHandlingMs
        }
        dispatch(decision.result)
        publishGates()
    }

    /// Feature seams fire before the base action so their handlers are
    /// already in place when begin/finish reaches the controller. A dictation
    /// result never reaches `onAction`: an unwired or disabled seam leaves the
    /// event consumed as `.none` rather than starting a planner capture.
    func dispatch(_ result: FnInputState.Result) {
        if result.dictation {
            if result.action == .begin { onDictationBegin() } else { onDictationConvert() }
            return
        }
        if result.latch { onLatch() }
        if result.action != .none { onAction(result.action) }
    }

    private func checkHealth() {
        if IsSecureEventInputEnabled() {
            interrupt("Secure keyboard input interrupted recording.")
            ready = false
            message = "Fn is unavailable while secure keyboard input is active"
            publishGates()
            return
        }
        guard AXIsProcessTrusted() else { refresh(); return }
        guard let tap = core.tap.withLock({ $0 }), CGEvent.tapIsEnabled(tap: tap) else {
            interrupt("Keyboard monitoring was interrupted. Hold Fn again to retry.")
            refresh()
            return
        }
        guard ready else { refresh(); return }
        publishGates()
        reconcilePhysicalFn(isDown: FnTapCore.physicalFnDown, now: ProcessInfo.processInfo.systemUptime)
    }

    func reconcilePhysicalFn(isDown: Bool, now: TimeInterval) {
        if isDown { reportPhysicalFn(true) }
        guard core.state.withLock({ $0.held }) else {
            if !isDown, reportedPhysicalFn == true, releaseCandidate == nil {
                releaseCandidate = now
                return
            }
            if !isDown, reportedPhysicalFn == true { reportPhysicalFn(false) }
            releaseCandidate = nil
            observedPhysicalHold = false
            return
        }
        if isDown {
            observedPhysicalHold = true
            releaseCandidate = nil
            return
        }
        guard observedPhysicalHold else { return }
        guard let firstUp = releaseCandidate else { releaseCandidate = now; return }
        releaseCandidate = nil
        observedPhysicalHold = false
        let active = operationActive()
        let result = core.state.withLock {
            $0.handle(.flagsChanged, key: 63, fn: false, now: firstUp, canBegin: false, active: active)
        }
        reportPhysicalFn(false)
        if result.action == .finish { onReleaseRecovery(firstUp, now, result.latch) }
        dispatch(result)
    }

    private func reportPhysicalFn(_ down: Bool) {
        guard reportedPhysicalFn != down else { return }
        reportedPhysicalFn = down
        onPhysicalFnChanged(down)
    }

    private func interrupt(_ reason: String) {
        releaseCandidate = nil
        observedPhysicalHold = false
        // A latched capture depends on the tap as much as a held one does.
        let captureHeld = core.state.withLock { state in
            defer { state.interrupt() }
            return state.held || state.latched
        }
        // Only capture depends on keyboard health. App execution may itself enter secure input.
        if captureHeld { onInterruption(reason) }
    }

    private func teardown() {
        ready = false
        core.gates.withLock { $0 = FnTapCore.Gates() }
        if let tap = core.tap.withLock({ tap in defer { tap = nil }; return tap }) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop = core.runLoop.withLock({ loop in defer { loop = nil }; return loop }) {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        source = nil
    }
}
