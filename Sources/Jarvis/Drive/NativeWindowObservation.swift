import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import OSLog

struct NativeFieldIdentity: @unchecked Sendable, Equatable {
    fileprivate let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
}

struct NativeReadOnlyValue: Sendable, Equatable {
    let window: WindowRef
    let document: NativeDocumentSubject?
    let identity: NativeFieldIdentity
    let readGeneration: UUID
    let role: String
    let label: String
    let value: String
    let frame: CGRect?
    let ancestorRoles: [String]

    fileprivate init?(node: AXUIElement, root: AXUIElement, ownerValue: Any,
                      rawValue: CFTypeRef, window: WindowRef, document: NativeDocumentSubject?,
                      role: String, label: String, frame: CGRect?, ancestorRoles: [String],
                      readGeneration: UUID) {
        var pid: pid_t = 0
        guard CFGetTypeID(rawValue) == CFStringGetTypeID(), let value = rawValue as? String,
              CFGetTypeID(ownerValue as CFTypeRef) == AXUIElementGetTypeID(),
              CFEqual(ownerValue as! AXUIElement, root),
              AXUIElementGetPid(node, &pid) == .success, Int(pid) == window.pid,
              !DriveCandidates.editableRoles.contains(
                role.lowercased().replacingOccurrences(of: "ax", with: "")),
              !DriveCandidates.isSecure(role: role, label: label),
              NativeWindowObservation.validatedAncestors(ancestorRoles) != nil,
              document == nil || document?.window == window else { return nil }
        self.window = window
        self.document = document
        identity = NativeFieldIdentity(node)
        self.readGeneration = readGeneration
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.ancestorRoles = ancestorRoles
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.window == rhs.window && lhs.document == rhs.document
            && lhs.identity == rhs.identity && lhs.readGeneration == rhs.readGeneration
            && lhs.role == rhs.role && Data(lhs.label.utf8) == Data(rhs.label.utf8)
            && Data(lhs.value.utf8) == Data(rhs.value.utf8) && lhs.frame == rhs.frame
            && lhs.ancestorRoles == rhs.ancestorRoles
    }

    func represents(_ element: AXElement, window: WindowRef,
                    document: NativeDocumentSubject?) -> Bool {
        self.window == window && self.document == document
            && element.index < 0 && element.token == nil && element.actions.isEmpty
            && role == element.role && Data(label.utf8) == Data(element.label.utf8)
            && element.value.map { Data($0.utf8) == Data(value.utf8) } == true
            && frame == element.frame && ancestorRoles == element.nativeAncestorRoles
            && !DriveCandidates.isSecure(role: element.role, label: element.label)
    }
}

enum NativeWindowObservation {
    private static let diagnostics = Logger(subsystem: "com.karanvirkang.jarvis",
                                            category: "native-observation")
    struct ReadDiagnostic {
        enum Phase: String {
            case validation, windows, windowIdentity, ownership, document, traversal, continuity, returned, awaited
        }
        var phase: Phase
        var elapsedMs: Double = 0
        var complete: Bool? = nil
        var cancelled: Bool = false

        var message: String {
            let status = complete.map { $0 ? "complete" : "incomplete" } ?? "unavailable"
            return "Native read phase=\(phase.rawValue) totalMs=\(elapsedMs) status=\(status) cancelled=\(cancelled)"
        }
    }

    struct Display: Sendable {
        var elements: [AXElement]
        var complete: Bool
        var window: WindowRef? = nil
        var fieldValues: [FieldValue] = []
        var nativeDocument: NativeDocumentSubject? = nil
    }

    struct FieldValue: Sendable {
        var role: String
        var label: String
        var value: String?
        var frame: CGRect?
        var verifiedWindow: WindowRef? = nil
        var identity: NativeFieldIdentity? = nil
        var nativeAncestorRoles: [String]? = nil
    }

    typealias Read = @Sendable (WindowRef, AXDepth) async -> Display?
    static let live: Read = { window, depth in await read(window, depth: depth) }

    struct ScrollViewport: Sendable {
        enum Metric: Sendable, Equatable { case verticalBar, horizontalBar, visibleText }
        var window: WindowRef
        var root: NativeFieldIdentity
        var region: NativeFieldIdentity
        var meter: NativeFieldIdentity
        var content: NativeFieldIdentity?
        var document: NativeDocumentSubject?
        var title: Data
        var frame: CGRect
        var windowFrame: CGRect
        var contentSize: CGSize?
        var contentDigest: Data?
        var point: CGPoint
        var metric: Metric
        var position: Double
        var minimum: Double?
        var maximum: Double?
        var capturedAt: TimeInterval
        var readGeneration = UUID()
        var tokenCenterMatches = false

        func sameTarget(as other: Self) -> Bool {
            window == other.window && root == other.root && region == other.region
                && meter == other.meter && content == other.content && document == other.document
                && title == other.title && frame == other.frame && windowFrame == other.windowFrame
                && contentSize == other.contentSize && contentDigest == other.contentDigest
                && point == other.point && metric == other.metric
                && minimum == other.minimum && maximum == other.maximum
        }

        func supports(_ direction: String) -> Bool {
            metric == .horizontalBar ? ["left", "right"].contains(direction)
                : ["up", "down"].contains(direction)
        }

        func moved(from before: Self, direction: String, dispatchedAt: TimeInterval) -> Bool {
            guard sameTarget(as: before), supports(direction),
                  readGeneration != before.readGeneration,
                  [capturedAt, before.capturedAt, dispatchedAt, position, before.position].allSatisfy(\.isFinite),
                  before.capturedAt <= dispatchedAt, dispatchedAt - before.capturedAt <= 1,
                  capturedAt >= dispatchedAt, capturedAt - dispatchedAt <= 1 else { return false }
            return ["down", "right"].contains(direction) ? position > before.position : position < before.position
        }

        func atEdge(direction: String) -> Bool {
            guard supports(direction), let minimum, let maximum,
                  [minimum, maximum, position].allSatisfy(\.isFinite), maximum > minimum else { return false }
            return ["down", "right"].contains(direction) ? position == maximum : position == minimum
        }
    }

    struct VerifiedScroll: Sendable {
        let viewport: ScrollViewport
        let application: String
        let direction: String
        let lines: Int
    }

    typealias ScrollRead = @Sendable (WindowRef, CGPoint?, String, ScrollViewport?) async -> ScrollViewport?
    enum ScrollDispatch: Sendable, Equatable {
        case unavailable, sent, uncertain
    }
    typealias ScrollControl = @Sendable (ScrollViewport, String, Int) async throws -> ScrollDispatch

    static let liveScrollControl: ScrollControl = { viewport, direction, lines in
        try Task.checkCancellation()
        let operation = Task.detached(priority: .userInitiated) {
            try controlScroll(viewport, direction: direction, lines: lines)
        }
        return try await withTaskCancellationHandler {
            let outcome = try await operation.value
            try Task.checkCancellation()
            return outcome
        } onCancel: { operation.cancel() }
    }

    private static func controlScroll(_ viewport: ScrollViewport, direction: String,
                                      lines: Int) throws -> ScrollDispatch {
        guard [WindowScrollRequest.smallLines, WindowScrollRequest.normalLines].contains(lines),
              viewport.supports(direction), viewport.metric != .visibleText,
              viewport.capturedAt.isFinite,
              (0...1).contains(ProcessInfo.processInfo.systemUptime - viewport.capturedAt) else {
            return .unavailable
        }
        var sent = false
        for _ in 0..<lines {
            try Task.checkCancellation()
            guard let current = collectScroll(viewport.window, point: viewport.point,
                                              direction: direction, previous: viewport),
                  current.sameTarget(as: viewport), sent || current.position == viewport.position else {
                return sent ? .uncertain : .unavailable
            }
            if sent, current.atEdge(direction: direction) { return .sent }
            guard let action = scrollAction(current, direction: direction) else {
                return sent ? .uncertain : .unavailable
            }
            try Task.checkCancellation()
            guard AXUIElementPerformAction(action.element, action.name as CFString) == .success else {
                return .uncertain
            }
            sent = true
        }
        return .sent
    }

    private static func scrollAction(_ viewport: ScrollViewport, direction: String)
        -> (element: AXUIElement, name: String)? {
        let bar = viewport.meter.element
        guard let pid = pid_t(exactly: viewport.window.pid),
              attribute(bar, kAXRoleAttribute) as? String == kAXScrollBarRole,
              belongs(bar, to: viewport.root.element, pid: pid) else { return nil }
        let barAttribute = viewport.metric == .horizontalBar
            ? kAXHorizontalScrollBarAttribute : kAXVerticalScrollBarAttribute
        guard let observed = elementAttribute(viewport.region.element, barAttribute),
              CFEqual(observed, bar) else { return nil }
        let increment = ["down", "right"].contains(direction)
        let action = increment ? kAXIncrementAction : kAXDecrementAction
        if supportsAction(bar, action) { return (bar, action) }
        let subrole = increment ? kAXIncrementArrowSubrole : kAXDecrementArrowSubrole
        if let button = elementAttribute(bar, increment ? kAXIncrementButtonAttribute : kAXDecrementButtonAttribute),
           (attribute(button, kAXSubroleAttribute) as? String).map({ $0 == subrole }) != false,
           validScrollButton(button, bar: bar, viewport: viewport, pid: pid) {
            return (button, kAXPressAction)
        }
        let children = attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let matches = children.filter {
            attribute($0, kAXSubroleAttribute) as? String == subrole
                && validScrollButton($0, bar: bar, viewport: viewport, pid: pid)
        }
        guard matches.count == 1, let button = matches.first else { return nil }
        return (button, kAXPressAction)
    }

    private static func validScrollButton(_ button: AXUIElement, bar: AXUIElement,
                                          viewport: ScrollViewport, pid: pid_t) -> Bool {
        guard attribute(button, kAXRoleAttribute) as? String == kAXButtonRole,
              belongs(button, to: viewport.root.element, pid: pid),
              supportsAction(button, kAXPressAction) else { return false }
        var cursor: AXUIElement? = button
        var seen: Set<AXUIElement> = []
        while let node = cursor, seen.count < 64, seen.insert(node).inserted {
            if CFEqual(node, bar) { return true }
            cursor = elementAttribute(node, kAXParentAttribute)
        }
        return false
    }

    private static func supportsAction(_ element: AXUIElement, _ action: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }
        return actions.contains(action)
    }

    static let liveScroll: ScrollRead = { window, point, direction, previous in
        guard !Task.isCancelled else { return nil }
        let read = Task.detached(priority: .userInitiated) {
            collectScroll(window, point: point, direction: direction, previous: previous)
        }
        return await withTaskCancellationHandler {
            let value = await read.value
            return Task.isCancelled ? nil : value
        } onCancel: { read.cancel() }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              let rect = frame(position: position, size: size), !rect.isEmpty else { return nil }
        return rect
    }

    private static func numericAttribute(_ element: AXUIElement, _ name: String) -> Double? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) != CFBooleanGetTypeID(),
              let number = raw as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func scrollAncestor(_ start: AXUIElement?, root: AXUIElement, pid: pid_t) -> AXUIElement? {
        var cursor = start
        var seen: Set<AXUIElement> = []
        while let node = cursor, seen.count < 64, seen.insert(node).inserted,
              belongs(node, to: root, pid: pid) {
            if attribute(node, kAXRoleAttribute) as? String == kAXScrollAreaRole { return node }
            cursor = elementAttribute(node, kAXParentAttribute)
        }
        return nil
    }

    private static func collectScroll(_ window: WindowRef, point: CGPoint?, direction: String,
                                      previous: ScrollViewport?) -> ScrollViewport? {
        guard ["up", "down", "left", "right"].contains(direction),
              previous == nil || previous?.window == window,
              let pid = pid_t(exactly: window.pid), pid > 0,
              let windowID = UInt32(exactly: window.windowID), windowID > 0,
              NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let matching = windows.filter { FocusedTextBinding.windowNumber($0) == windowID }
        guard matching.count == 1, let root = matching.first,
              let windowFrame = elementFrame(root) else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(root, &owner) == .success, owner == pid else { return nil }
        if let point, !windowFrame.contains(point) { return nil }
        let documentID = documentIdentifier(root)
        let title = Data(((attribute(root, kAXTitleAttribute) as? String) ?? "").utf8)
        let region: AXUIElement
        if let previous {
            guard previous.root == NativeFieldIdentity(root) else { return nil }
            region = previous.region.element
        } else {
            var start: AXUIElement?
            if let point {
                AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &start)
            } else {
                start = elementAttribute(app, kAXFocusedUIElementAttribute)
            }
            var found = scrollAncestor(start, root: root, pid: pid)
            if found == nil, point == nil {
                var pending = [root], visited: Set<AXUIElement> = [], regions: [AXUIElement] = []
                let deadline = ContinuousClock.now + .milliseconds(400)
                while let node = pending.popLast() {
                    guard !Task.isCancelled, ContinuousClock.now < deadline, visited.count < 600 else { return nil }
                    guard visited.insert(node).inserted else { continue }
                    if attribute(node, kAXRoleAttribute) as? String == kAXScrollAreaRole,
                       let rect = elementFrame(node), rect.intersects(windowFrame),
                       belongs(node, to: root, pid: pid) { regions.append(node) }
                    pending += (attribute(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []
                }
                if regions.count == 1 { found = regions.first }
            }
            guard let found else { return nil }
            region = found
        }
        guard belongs(region, to: root, pid: pid),
              attribute(region, kAXRoleAttribute) as? String == kAXScrollAreaRole,
              let regionFrame = elementFrame(region) else { return nil }
        let visible = regionFrame.intersection(windowFrame)
        guard !visible.isEmpty else { return nil }
        func hitsRegion(_ point: CGPoint) -> Bool {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
                  let hitRegion = scrollAncestor(hit, root: root, pid: pid) else { return false }
            return CFEqual(hitRegion, region)
        }
        let center = CGPoint(x: regionFrame.midX, y: regionFrame.midY)
        let candidates = [
            CGPoint(x: visible.midX, y: visible.midY),
            CGPoint(x: visible.minX + visible.width * 0.1, y: visible.midY),
            CGPoint(x: visible.maxX - visible.width * 0.1, y: visible.midY),
            CGPoint(x: visible.midX, y: visible.minY + visible.height * 0.1),
            CGPoint(x: visible.midX, y: visible.maxY - visible.height * 0.1),
        ]
        guard let targetPoint = previous?.point ?? point ?? candidates.first(where: hitsRegion),
              hitsRegion(targetPoint) else { return nil }
        guard visible.contains(targetPoint) else { return nil }
        let children = ((attribute(region, "AXContents") as? [AXUIElement])
            ?? (attribute(region, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter {
                attribute($0, kAXRoleAttribute) as? String != kAXScrollBarRole
            }
        let content = children.count == 1 ? children.first : nil
        let contentRole = content.flatMap { attribute($0, kAXRoleAttribute) as? String } ?? ""
        guard !DriveCandidates.isSecure(role: contentRole, label: "") else { return nil }
        let value = content.flatMap { attribute($0, kAXValueAttribute) as? String }
        let vertical = ["up", "down"].contains(direction)
        let bar = elementAttribute(region, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute)
        let metric: ScrollViewport.Metric
        let meter: AXUIElement
        let position: Double
        var minimum: Double?, maximum: Double?
        if let bar, belongs(bar, to: root, pid: pid),
           let offset = numericAttribute(bar, kAXValueAttribute) {
            metric = vertical ? .verticalBar : .horizontalBar
            meter = bar
            position = offset
            minimum = numericAttribute(bar, kAXMinValueAttribute)
            maximum = numericAttribute(bar, kAXMaxValueAttribute)
        } else {
            guard vertical, let content, let value,
                  let raw = attribute(content, kAXVisibleCharacterRangeAttribute),
                  CFGetTypeID(raw) == AXValueGetTypeID(),
                  AXValueGetType(raw as! AXValue) == .cfRange else { return nil }
            var range = CFRange()
            guard AXValueGetValue(raw as! AXValue, .cfRange, &range),
                  range.location >= 0, range.length > 0,
                  range.location <= value.utf16.count,
                  range.length <= value.utf16.count - range.location else { return nil }
            metric = .visibleText
            meter = content
            position = Double(range.location)
        }
        let contentSize = content.flatMap(elementFrame)?.size
        guard !Task.isCancelled, belongs(region, to: root, pid: pid),
              elementFrame(root) == windowFrame, elementFrame(region) == regionFrame,
              documentIdentifier(root).map({ Data($0.utf8) }) == documentID.map({ Data($0.utf8) }),
              FocusedTextBinding.windowNumber(root) == windowID else { return nil }
        var result = ScrollViewport(window: window, root: NativeFieldIdentity(root),
            region: NativeFieldIdentity(region), meter: NativeFieldIdentity(meter),
            content: content.map(NativeFieldIdentity.init),
            document: documentSubject(window: window, identifier: documentID),
            title: title, frame: regionFrame, windowFrame: windowFrame, contentSize: contentSize,
            contentDigest: value.map { Data(SHA256.hash(data: Data($0.utf8))) },
            point: targetPoint, metric: metric, position: position, minimum: minimum, maximum: maximum,
            capturedAt: ProcessInfo.processInfo.systemUptime)
        result.tokenCenterMatches = windowFrame.contains(regionFrame) && hitsRegion(center)
        return result
    }

    static func applying(_ display: Display?, to snapshot: AXSnapshot,
                         window: WindowRef) -> AXSnapshot {
        var result = snapshot
        result.nativeDocument = nil
        let publicFields = snapshot.elements.indices.filter {
            editable(snapshot.elements[$0].role)
                && !DriveCandidates.isSecure(role: snapshot.elements[$0].role,
                                             label: snapshot.elements[$0].label)
        }
        defer {
            let restored = publicFields.filter { result.elements[$0].value != nil }.count
            let nativeFields = display?.fieldValues ?? []
            let framePairs = publicFields.reduce(0) { count, index in
                count + nativeFields.filter {
                    roundedFrame(snapshot.elements[index].frame) != nil
                        && roundedFrame(snapshot.elements[index].frame) == roundedFrame($0.frame)
                }.count
            }
            let labelPairs = publicFields.reduce(0) { count, index in
                count + nativeFields.filter { snapshot.elements[index].label == $0.label }.count
            }
            let attested = result.elements.filter { $0.nativeValue != nil }.count
            diagnostics.notice("Merge driverFields=\(publicFields.count, privacy: .public) nativeFields=\(nativeFields.count, privacy: .public) restored=\(restored, privacy: .public) framePairs=\(framePairs, privacy: .public) labelPairs=\(labelPairs, privacy: .public) nativeComplete=\(display?.complete ?? false, privacy: .public) finalComplete=\(result.goalContextComplete, privacy: .public) attestedFields=\(attested, privacy: .public) documentKnown=\(result.nativeDocument != nil, privacy: .public)")
        }
        for index in snapshot.elements.indices {
            let element = snapshot.elements[index]
            result.elements[index].nativeValue = nil
            result.elements[index].nativeIdentity = nil
            result.elements[index].nativeAncestorRoles = nil
            result.elements[index].nativeReadOnlyValue = nil
            if editable(element.role) || DriveCandidates.isSecure(role: element.role, label: element.label) {
                result.elements[index].value = nil
            }
        }
        if !publicFields.isEmpty || snapshot.elements.contains(where: { editable($0.role) }) {
            result.treeMarkdown = ""
        }
        guard let display else {
            result.goalContextComplete = false
            return result
        }
        let valid = display.elements.allSatisfy {
            $0.index < 0 && $0.token == nil && $0.actions.isEmpty && !editable($0.role)
        } && Set(display.elements.map(\.index)).count == display.elements.count
        let scoped = display.window == window || (display.window == nil && display.fieldValues.isEmpty)
        if valid && scoped {
            result.elements += display.elements.map {
                var element = $0
                element.nativeValue = nil
                element.nativeIdentity = nil
                element.nativeReadOnlyValue = nil
                element.nativeAncestorRoles = display.complete && display.window == window
                    && !DriveCandidates.isSecure(role: element.role, label: element.label)
                    ? validatedAncestors(element.nativeAncestorRoles) : nil
                return element
            }
        }
        result.goalContextComplete = result.goalContextComplete && display.complete && valid && scoped
        guard valid, display.complete, display.window == window else {
            if !publicFields.isEmpty || !display.fieldValues.isEmpty { result.goalContextComplete = false }
            return result
        }
        if let subject = display.nativeDocument,
           subject.window != window || subject.fingerprint.count != 32 {
            result.goalContextComplete = false
            return result
        }
        let fields = display.fieldValues.filter {
            editable($0.role) && !DriveCandidates.isSecure(role: $0.role, label: $0.label)
        }
        let matches = publicFields.map { index in
            fields.indices.filter { matchesField(snapshot.elements[index], fields[$0]) }
        }
        var used: Set<Int> = []
        for (position, index) in publicFields.enumerated() {
            guard matches[position].count == 1, let fieldIndex = matches[position].first,
                  matches.filter({ $0.contains(fieldIndex) }).count == 1,
                  let value = fields[fieldIndex].value else {
                result.goalContextComplete = false
                continue
            }
            result.elements[index].value = value
            used.insert(fieldIndex)
        }
        if used.count != fields.count { result.goalContextComplete = false }
        guard result.goalContextComplete else { return result }
        result.nativeDocument = display.nativeDocument
        for (position, index) in publicFields.enumerated() {
            guard let fieldIndex = matches[position].first,
                  fields[fieldIndex].verifiedWindow == window,
                  let frame = roundedFrame(snapshot.elements[index].frame),
                  frame == roundedFrame(fields[fieldIndex].frame) else { continue }
            result.elements[index].nativeValue = NativeFieldProvenance(
                window: window, document: display.nativeDocument)
            result.elements[index].nativeIdentity = fields[fieldIndex].identity
            result.elements[index].nativeAncestorRoles = fields[fieldIndex].identity != nil
                ? validatedAncestors(fields[fieldIndex].nativeAncestorRoles) : nil
        }
        for (offset, native) in display.elements.enumerated() {
            let index = snapshot.elements.count + offset
            if let record = native.nativeReadOnlyValue,
               record.represents(result.elements[index], window: window, document: display.nativeDocument) {
                result.elements[index].nativeReadOnlyValue = record
            }
        }
        return result
    }

    static func documentSubject(window: WindowRef, identifier: String?) -> NativeDocumentSubject? {
        guard window.pid > 0, window.windowID > 0, let identifier, !identifier.isEmpty,
              let url = URL(string: identifier), url.scheme != nil,
              identifier.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return NativeDocumentSubject(window: window,
            fingerprint: Data(SHA256.hash(data: Data(identifier.utf8))))
    }

    /// Non-document subject identity: the window's attested static
    /// structure as a sorted multiset — title plus every element's
    /// role/label, with editable roles contributing identity only
    /// (the task's own text edits legitimately change their values).
    /// A read-only label that merely mirrors the element's live value
    /// (a display readout, a clock) is likewise state, not structure,
    /// and contributes role identity only. Pressable controls contribute
    /// role identity only for the same reason — their labels legitimately
    /// mutate on activation (Play↔Pause, Clear↔All Clear). Continuity
    /// is subset, not
    /// equality: parts may grow as the task adds elements. Requires a
    /// goal-complete snapshot carrying at least one natively
    /// provenanced element — an editable field or a native read-only
    /// record — so driver-reported text alone cannot establish it.
    /// Web windows are excluded: their content can swap under an
    /// unchanged title and chrome.
    static func windowSubject(_ snapshot: AXSnapshot, window: WindowRef) -> NativeWindowSubject? {
        guard snapshot.goalContextComplete, window.pid > 0, window.windowID > 0,
              snapshot.elements.contains(where: {
                  $0.nativeValue != nil || $0.nativeIdentity != nil
                      || $0.nativeReadOnlyValue != nil
              }),
              !snapshot.elements.contains(where: {
                  let role = $0.role.lowercased().replacingOccurrences(of: " ", with: "")
                  return role == "axbrowser" || role == "axwebarea"
              }) else { return nil }
        var parts = [snapshot.windowTitle ?? ""]
        parts += snapshot.elements.map { element in
            if editable(element.role) { return "edit|\(element.role.lowercased())" }
            if let value = element.value, !value.isEmpty, element.label == value {
                return "ro|\(element.role.lowercased())"
            }
            // Pressable controls carry task-mutable labels — activation
            // legitimately relabels them (Play↔Pause, Clear↔All Clear,
            // Show↔Hide), so like editable values and read-only displays
            // they contribute role identity only, not label text.
            if element.actions.contains("AXPress") {
                return "press|\(element.role.lowercased())"
            }
            return "\(element.role)|\(element.label)"
        }
        return NativeWindowSubject(window: window, parts: parts.sorted())
    }

    private static func documentIdentifier(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func belongs(_ field: AXUIElement, to window: AXUIElement, pid: pid_t) -> Bool {
        var owner: pid_t = 0
        var value: CFTypeRef?
        guard AXUIElementGetPid(field, &owner) == .success, owner == pid,
              AXUIElementCopyAttributeValue(field, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return CFEqual(value, window)
    }

    private static func normalizedRole(_ role: String) -> String {
        role.lowercased().replacingOccurrences(of: "ax", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    fileprivate static func validatedAncestors(_ roles: [String]?) -> [String]? {
        guard let roles, let root = roles.first, ["AXWindow", "AXSheet"].contains(root),
              roles.allSatisfy({ role in
                  role.hasPrefix("AX") && !role.lowercased().contains("secure")
                      && !role.hasPrefix("AXMenu") && role.unicodeScalars.allSatisfy {
                          (65...90).contains($0.value) || (97...122).contains($0.value)
                              || (48...57).contains($0.value)
                      }
              }) else { return nil }
        return roles
    }

    private static func editable(_ role: String) -> Bool {
        DriveCandidates.editableRoles.contains { normalizedRole($0) == normalizedRole(role) }
    }

    private static func roundedFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame, frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width >= 1, frame.height >= 1 else { return nil }
        return CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(),
                      width: frame.width.rounded(), height: frame.height.rounded())
    }

    private static func matchesField(_ element: AXElement, _ field: FieldValue) -> Bool {
        guard normalizedRole(element.role) == normalizedRole(field.role) else { return false }
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeLabel = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty && !nativeLabel.isEmpty && label != nativeLabel { return false }
        if let frame = roundedFrame(element.frame), let nativeFrame = roundedFrame(field.frame) {
            return frame == nativeFrame
        }
        return !label.isEmpty && label == nativeLabel
    }

    static func read(_ window: WindowRef, depth: AXDepth) async -> Display? {
        guard !Task.isCancelled else { return nil }
        let started = ContinuousClock.now
        let work = Task.detached(priority: .userInitiated) {
            collect(window, depth: depth)
        }
        return await withTaskCancellationHandler {
            let result = await work.value
            let trace = ReadDiagnostic(phase: .awaited, elapsedMs: elapsedMilliseconds(since: started),
                                       complete: result?.complete, cancelled: Task.isCancelled)
            diagnostics.notice("\(trace.message, privacy: .public)")
            return Task.isCancelled ? nil : result
        } onCancel: {
            work.cancel()
        }
    }

    private static func elapsedMilliseconds(since started: ContinuousClock.Instant) -> Double {
        let elapsed = started.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func collect(_ window: WindowRef, depth: AXDepth) -> Display? {
        let readStarted = ContinuousClock.now
        var trace = ReadDiagnostic(phase: .validation)
        defer {
            trace.elapsedMs = elapsedMilliseconds(since: readStarted)
            trace.cancelled = Task.isCancelled
            diagnostics.notice("\(trace.message, privacy: .public)")
        }
        guard let pid = pid_t(exactly: window.pid), pid > 0,
              let windowID = UInt32(exactly: window.windowID), windowID > 0,
              NSRunningApplication(processIdentifier: pid) != nil else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        trace.phase = .windows
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        trace.phase = .windowIdentity
        let matching = windows.filter { FocusedTextBinding.windowNumber($0) == windowID }
        guard matching.count == 1, let root = matching.first else { return nil }
        var owner: pid_t = 0
        trace.phase = .ownership
        guard AXUIElementGetPid(root, &owner) == .success, owner == pid else { return nil }
        AXUIElementSetMessagingTimeout(root, 0.2)
        trace.phase = .document
        let initialDocument = documentIdentifier(root)
        let attributes = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
            kAXChildrenAttribute, kAXPositionAttribute, kAXSizeAttribute,
            kAXWindowAttribute,
        ] as CFArray
        let readGeneration = UUID()
        let started = ContinuousClock.now
        let deadline = started + .milliseconds(500)
        trace.phase = .traversal
        var pending = [(root, 0, [String]())]
        var visited: Set<AXUIElement> = []
        var elements: [AXElement] = []
        var fieldValues: [FieldValue] = []
        var complete = true
        var readFailures = 0
        var roleFailures = 0
        var actionFailures = 0
        var bounded = false
        var depthTruncated = false
        while let (node, level, ancestors) = pending.popLast() {
            if Task.isCancelled { return nil }
            guard visited.count < depth.maxElements, ContinuousClock.now < deadline else {
                complete = false
                bounded = true
                break
            }
            guard visited.insert(node).inserted else { continue }
            AXUIElementSetMessagingTimeout(node, 0.2)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(
                node, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [Any], values.count == 8 else {
                complete = false
                readFailures += 1
                continue
            }
            guard let rawRole = values[0] as? String else {
                complete = false
                roleFailures += 1
                continue
            }
            let subrole = values[1] as? String
            let role = subrole == "AXSecureTextField" ? "AXSecureTextField" : rawRole
            let labels = [values[2] as? String, values[3] as? String].compactMap { $0 }
            let fieldLabel = labels.first(where: { !$0.isEmpty }) ?? ""
            let editable = editable(role)
            if role.lowercased().contains("secure")
                || (editable && DriveCandidates.isSecure(role: role, label: labels.joined(separator: " "))) { continue }
            if let children = values[4] as? [AXUIElement], !children.isEmpty {
                if level < depth.maxDepth {
                    let childAncestors = ancestors + [rawRole]
                    pending += children.reversed().map { ($0, level + 1, childAncestors) }
                } else {
                    complete = false
                    depthTruncated = true
                }
            }
            guard level > 0 else { continue }
            if editable {
                var rawValue: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &rawValue)
                let current = rawValue.flatMap { $0 as? String }
                if status != .success || current == nil {
                    complete = false
                    readFailures += 1
                }
                let owned = belongs(node, to: root, pid: pid)
                fieldValues.append(FieldValue(role: role, label: fieldLabel,
                    value: status == .success ? current : nil,
                    frame: frame(position: values[5], size: values[6]),
                    verifiedWindow: owned ? window : nil,
                    identity: owned ? NativeFieldIdentity(node) : nil,
                    nativeAncestorRoles: ancestors))
                continue
            }
            var actions: CFArray?
            var settable = DarwinBoolean(false)
            let valueStatus = AXUIElementIsAttributeSettable(
                node, kAXValueAttribute as CFString, &settable)
            guard AXUIElementCopyActionNames(node, &actions) == .success,
                  valueStatus == .success || valueStatus == .attributeUnsupported else {
                complete = false
                actionFailures += 1
                continue
            }
            guard (actions as? [String] ?? []).isEmpty, !settable.boolValue else { continue }
            var rawValue: CFTypeRef?
            let readStatus = AXUIElementCopyAttributeValue(node, kAXValueAttribute as CFString, &rawValue)
            let current = readStatus == .success ? rawValue.flatMap(text) : nil
            let label = [values[2] as? String, values[3] as? String, current]
                .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
            guard !label.isEmpty || current != nil else { continue }
            let secure = DriveCandidates.isSecure(role: role, label: label)
            let rect = frame(position: values[5], size: values[6])
            let readonly = !secure && valueStatus == .success && readStatus == .success ? rawValue.flatMap {
                NativeReadOnlyValue(node: node, root: root, ownerValue: values[7],
                    rawValue: $0, window: window,
                    document: documentSubject(window: window, identifier: initialDocument),
                    role: role, label: label, frame: rect,
                    ancestorRoles: ancestors, readGeneration: readGeneration)
            } : nil
            elements.append(AXElement(
                index: -(elements.count + 1), token: nil, role: role,
                label: secure ? "[secure]" : label, value: secure ? nil : current,
                frame: rect, actions: [], nativeAncestorRoles: ancestors,
                nativeReadOnlyValue: readonly))
        }
        trace.phase = .continuity
        value = nil
        guard !Task.isCancelled,
              AXUIElementGetPid(root, &owner) == .success, owner == pid,
              AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let current = value as? [AXUIElement] else { return nil }
        let remaining = current.filter { FocusedTextBinding.windowNumber($0) == windowID }
        guard remaining.count == 1, let remainingRoot = remaining.first, CFEqual(remainingRoot, root),
              documentIdentifier(root) == initialDocument else { return nil }
        let elapsed = started.duration(to: .now).components
        let elapsedMs = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        diagnostics.notice("Native complete=\(complete, privacy: .public) visited=\(visited.count, privacy: .public) rows=\(elements.count, privacy: .public) bounded=\(bounded, privacy: .public) depthTruncated=\(depthTruncated, privacy: .public) readFailures=\(readFailures, privacy: .public) roleFailures=\(roleFailures, privacy: .public) actionFailures=\(actionFailures, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
        trace.phase = .returned
        trace.complete = complete
        return Display(elements: elements, complete: complete, window: window, fieldValues: fieldValues,
            nativeDocument: documentSubject(window: window, identifier: initialDocument))
    }

    private static func text(_ value: Any) -> String? {
        if let string = value as? String { return string }
        return (value as? NSNumber)?.stringValue
    }

    private static func frame(position: Any, size: Any) -> CGRect? {
        guard CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let position = position as! AXValue, size = size as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite,
              dimensions.width.isFinite, dimensions.height.isFinite else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
