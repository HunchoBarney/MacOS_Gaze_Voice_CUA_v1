import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import JevVoiceCore
import OSLog

@MainActor
struct SpokenLiteralTarget {
    enum Outcome { case notSent, unverified, verified }
    typealias Write = (String, String, NSRange, () -> Bool) throws -> FocusedTextBinding.Insertion?
    private let digest: SHA256.Digest
    private let expiresAt = ContinuousClock.now.advanced(by: .seconds(30))
    private let selection: NSRange
    private let state: () -> (String, NSRange)?
    private let write: Write

    init?(eligible: @escaping () -> Bool = { true }, state: @escaping () -> (String, NSRange)?, write: @escaping Write) {
        let checkedState = { eligible() ? state() : nil }
        guard let (value, range) = checkedState(), value.utf8.count <= 65536,
              range.location >= 0, range.location <= value.utf16.count, range.length >= 0,
              range.length <= value.utf16.count - range.location, Range(range, in: value) != nil else { return nil }
        digest = SHA256.hash(data: Data(value.utf8))
        selection = range
        self.state = checkedState
        self.write = write
    }

    func insert(_ text: String, permitted: () -> Bool) -> Outcome {
        func current() -> Bool { ContinuousClock.now < expiresAt && permitted() }
        guard current(), CuaPolicy.deniedInTypedPayload(text) == nil,
              let (value, range) = state(), value.utf8.count <= 65536, range == selection,
              SHA256.hash(data: Data(value.utf8)) == digest, let replacement = Range(range, in: value) else { return .notSent }
        let expected = value.replacingCharacters(in: replacement, with: text)
        guard !expected.utf8.elementsEqual(value.utf8), current() else { return .notSent }
        do {
            guard let receipt = try write(text, value, range, current) else { return .notSent }
            guard current(), let (after, _) = state(), after.utf8.elementsEqual(expected.utf8),
                  receipt.succeeded else { return .unverified }
            return .verified
        } catch {
            return .notSent
        }
    }

    static func capture(app: String, window: Int) -> Self? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == app,
              !BrowserSupport.isBrowser(bundleID: app) else { return nil }
        return NativeFocusedTextTarget.literal(pid: Int(front.processIdentifier), windowID: window, app: front.localizedName ?? app)
    }

    static func nonsecureSubrole(_ status: AXError, _ value: String?) -> Bool {
        status == .attributeUnsupported || (status == .success && value != nil && value != kAXSecureTextFieldSubrole)
    }

    static func nativeTree<Node>(from field: Node, isWindow: (Node) -> Bool,
                                 safeNode: (Node) -> Bool, parent: (Node) -> Node?) -> Bool {
        var node: Node? = field
        for _ in 0..<32 {
            guard let current = node, safeNode(current) else { return false }
            if isWindow(current) { return true }
            node = parent(current)
        }
        return false
    }
}

/// A retained native target, not a guess from a snapshot row or its geometry.
struct FocusedTextBinding: Sendable {
    struct WindowSnapshot: Sendable {
        let pid: Int
        let windowID: Int
        let title: String
        let isOnScreen: Bool
    }
    enum Capture: Sendable {
        case unavailable
        case bound(FocusedTextBinding)
    }
    struct Insertion: Sendable, Equatable {
        let succeeded: Bool
        let issuedAt: Double
        let returnedAt: Double
    }
    typealias NativeInsert = @Sendable (String, String, NSRange) async throws -> Insertion?

    let label: String
    let isCurrent: @Sendable () async -> Bool
    let value: @Sendable () async -> String?
    var selection: (@Sendable () async -> NSRange?)? = nil
    var insertSelectedText: NativeInsert? = nil
    var windowSnapshot: (@Sendable () async -> WindowSnapshot?)? = nil

    static func accepts(role: String?, subrole: String?, enabled: Bool?, readOnly: Bool?) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role ?? "")
            && subrole != "AXSecureTextField" && enabled != false && readOnly != true
    }

    static func capture(pid: Int, windowID: Int) async -> Self? {
        await NativeFocusedTextTarget.capture(pid: pid, windowID: windowID)
    }

    static func focusedWindowID(pid: Int) async -> Int? {
        await NativeFocusedTextTarget.focusedWindowID(pid: pid)
    }

    static func windowNumber(_ element: AXUIElement) -> UInt32? {
        NativeFocusedTextTarget.windowNumber(element)
    }

    @MainActor
    static func capturedWindowID(pid: Int) -> Int? {
        guard let process = pid_t(exactly: pid), process > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == process else { return nil }
        return NativeFocusedTextTarget.focusedWindowID(pid: pid, allowsMainWindow: false)
    }
}

@MainActor
private final class NativeFocusedTextTarget {
    private static let diagnosticLog = Logger(subsystem: "com.chriswozniczek.jevvoice.voice",
                                               category: "native-focus")
    private let pid: pid_t
    private let windowID: UInt32
    private let window: AXUIElement
    private let field: AXUIElement

    private init(pid: pid_t, windowID: UInt32, window: AXUIElement, field: AXUIElement) {
        self.pid = pid; self.windowID = windowID; self.window = window; self.field = field
    }

    static func focusedWindowID(pid: Int, allowsMainWindow: Bool = true) -> Int? {
        guard let process = pid_t(exactly: pid), process > 0 else { return nil }
        let app = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let focused = element(app, kAXFocusedWindowAttribute)
        guard let window = focused ?? (allowsMainWindow ? element(app, kAXMainWindowAttribute) : nil),
              let number = windowNumber(window) else { return nil }
        return Int(number)
    }

    private static func focused(pid: Int, windowID: Int) -> NativeFocusedTextTarget? {
        guard let process = pid_t(exactly: pid), let number = UInt32(exactly: windowID),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == process else { return nil }
        let app = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window = element(app, kAXFocusedWindowAttribute),
              windowNumber(window) == number,
              let field = element(app, kAXFocusedUIElementAttribute),
              let owner = element(field, kAXWindowAttribute), CFEqual(owner, window),
              accepts(field)
        else { return nil }
        let target = NativeFocusedTextTarget(pid: process, windowID: number, window: window, field: field)
        AXUIElementSetMessagingTimeout(field, 0.3)
        AXUIElementSetMessagingTimeout(window, 0.3)
        return target
    }

    static func literal(pid: Int, windowID: Int, app: String) -> SpokenLiteralTarget? {
        guard let target = focused(pid: pid, windowID: windowID) else { return nil }
        func eligible() -> Bool {
            guard target.isCurrent(), target.supportsSelectedTextInsertion(strictSubroles: true),
                  let title = attribute(target.window, kAXTitleAttribute) as? String,
                  let fieldTitle = target.optionalFieldAttribute(kAXTitleAttribute, unsupported: ""),
                  let description = target.optionalFieldAttribute(kAXDescriptionAttribute, unsupported: ""),
                  target.optionalFieldAttribute(kAXEnabledAttribute, unsupported: true) == true,
                  target.optionalFieldAttribute("AXReadOnly", unsupported: false) == false else { return false }
            return CuaPolicy.deniedPhrase(in: [app, title, fieldTitle, description]) == nil
        }
        return SpokenLiteralTarget(eligible: eligible, state: {
            guard let before = target.boundedValue(), let selection = target.readSelection() else { return nil }
            return (before, selection)
        }, write: { text, value, selection, permitted in
            guard eligible(), target.observedWindow() != nil else { return nil }
            return try target.insertSelectedText(text, before: value, selection: selection,
                constrainedRead: { eligible() ? target.boundedValue() : nil }, permitted: permitted)
        })
    }

    static func capture(pid: Int, windowID: Int) -> FocusedTextBinding? {
        guard let target = focused(pid: pid, windowID: windowID) else { return nil }
        let field = target.field
        guard let role = attribute(field, kAXRoleAttribute) as? String else { return nil }
        let label = [attribute(field, kAXTitleAttribute) as? String,
                     attribute(field, kAXDescriptionAttribute) as? String]
            .compactMap { $0 }.first(where: { !$0.isEmpty }) ?? role
        return FocusedTextBinding(label: label,
                                  isCurrent: { await target.isCurrent() },
                                  value: { await target.readValue() },
                                  selection: { await target.readSelection() },
                                  insertSelectedText: { text, before, selection in
                                      try await target.insertSelectedText(text, before: before, selection: selection)
                                  },
                                  windowSnapshot: { await target.observedWindow() })
    }

    private func observedWindow() -> FocusedTextBinding.WindowSnapshot? {
#if JEV_C1_VOICE_BADGE_ONLY
        let options = CGWindowListOption.optionIncludingWindow
        let reference = windowID
#else
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let reference = kCGNullWindowID
#endif
        guard isCurrent(), supportsSelectedTextInsertion(),
              let title = Self.attribute(window, kAXTitleAttribute) as? String,
              let rows = CGWindowListCopyWindowInfo(options, reference) as? [[String: Any]],
              rows.contains(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == Int(pid)
                      && ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == Int(windowID)
                      && ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
              }) else { return nil }
        return .init(pid: Int(pid), windowID: Int(windowID), title: title, isOnScreen: true)
    }

    private func supportsSelectedTextInsertion(strictSubroles: Bool = false) -> Bool {
        guard let role = Self.attribute(field, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole].contains(role), Self.accepts(field) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return SpokenLiteralTarget.nativeTree(from: field, isWindow: { CFEqual($0, window) }, safeNode: { current in
            guard let role = Self.attribute(current, kAXRoleAttribute) as? String,
                  role != "AXWebArea", role != "AXSecureTextField" else { return false }
            guard strictSubroles else { return true }
            var subrole: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(current, kAXSubroleAttribute as CFString, &subrole)
            return SpokenLiteralTarget.nonsecureSubrole(status, subrole as? String)
        }, parent: { Self.element($0, kAXParentAttribute) })
    }

    private func insertSelectedText(_ text: String, before: String,
                                    selection: NSRange, constrainedRead: (() -> String?)? = nil,
                                    permitted: () -> Bool = { true }) throws -> FocusedTextBinding.Insertion? {
        try Task.checkCancellation()
        guard supportsSelectedTextInsertion() else { return nil }
        try Task.checkCancellation()
        let actual: String? = if !isCurrent() { nil } else if let constrainedRead { constrainedRead() } else { Self.attribute(field, kAXValueAttribute) as? String }
        guard let actual, constrainedRead == nil ? actual == before : actual.utf8.elementsEqual(before.utf8),
              readSelection() == selection else {
            throw DriverConnectionError.refused("The captured field or insertion point changed. No text was sent.")
        }
        try Task.checkCancellation()
        guard permitted() else { return nil }
        let issued = ProcessInfo.processInfo.systemUptime
        let result = AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString)
        return .init(succeeded: result == .success, issuedAt: issued,
                     returnedAt: ProcessInfo.processInfo.systemUptime)
    }

    private func isCurrent() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return reject("frontmost") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let currentWindow = Self.element(app, kAXFocusedWindowAttribute) else { return reject("window_missing") }
        guard CFEqual(currentWindow, window) else { return reject("window_equal") }
        guard Self.windowNumber(currentWindow) == windowID else { return reject("window_number") }
        guard let currentField = Self.element(app, kAXFocusedUIElementAttribute) else { return reject("field_missing") }
        guard CFEqual(currentField, field) else { return reject("field_equal") }
        guard Self.accepts(currentField) else { return reject("editable") }
        guard let owner = Self.element(currentField, kAXWindowAttribute) else { return reject("owner_missing") }
        guard CFEqual(owner, window) else { return reject("owner_equal") }
        return true
    }

    private func reject(_ reason: String) -> Bool {
#if !JEV_C1_VOICE_BADGE_ONLY
        let env = ProcessInfo.processInfo.environment
        if env["JARVIS_P3_GUI_AUDIT_TYPING_REPAIR"] == "1" || !(env["JARVIS_VOICE_EVIDENCE_DIR"] ?? "").isEmpty {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            Self.diagnosticLog.notice("native_focus_rejected reason=\(reason, privacy: .public) expected_pid=\(self.pid) front_pid=\(front) expected_window=\(self.windowID)")
        }
#endif
        return false
    }

    private func readValue() -> String? {
        guard isCurrent() else { return nil }
        return Self.attribute(field, kAXValueAttribute) as? String
    }

    private func boundedValue() -> String? {
        guard let length = Self.attribute(field, kAXNumberOfCharactersAttribute) as? NSNumber,
              let count = Int(exactly: length), (0...65536).contains(count) else { return nil }
        if count == 0 { return "" }
        var range = CFRange(location: 0, length: count)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
            parameter, &result) == .success, let text = result as? String, text.utf16.count == count,
              Self.attribute(field, kAXNumberOfCharactersAttribute) as? NSNumber == length else { return nil }
        return text
    }

    private func optionalFieldAttribute<T>(_ name: String, unsupported: T) -> T? {
        var raw: CFTypeRef?
        switch AXUIElementCopyAttributeValue(field, name as CFString, &raw) {
        case .success: return raw as? T
        case .attributeUnsupported: return unsupported
        default: return nil
        }
    }

    private func readSelection() -> NSRange? {
        guard isCurrent(), let raw = Self.attribute(field, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange,
              AXValueGetValue(value, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func accepts(_ element: AXUIElement) -> Bool {
        FocusedTextBinding.accepts(role: attribute(element, kAXRoleAttribute) as? String,
                                  subrole: attribute(element, kAXSubroleAttribute) as? String,
                                  enabled: attribute(element, kAXEnabledAttribute) as? Bool,
                                  readOnly: attribute(element, "AXReadOnly") as? Bool)
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The same system identity operation used by the pinned driver's exact
    /// target guard. A missing symbol or failed query never becomes a frame guess.
    nonisolated fileprivate static func windowNumber(_ element: AXUIElement) -> UInt32? {
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        let getWindow = unsafeBitCast(symbol, to: GetWindow.self)
        var number: UInt32 = 0
        guard getWindow(element, &number) == 0, number != 0 else { return nil }
        return number
    }
}
