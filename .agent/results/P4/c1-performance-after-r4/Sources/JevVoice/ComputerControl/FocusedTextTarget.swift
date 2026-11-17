import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import JevVoiceCore
import OSLog

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

    static func capture(pid: Int, windowID: Int) -> FocusedTextBinding? {
        guard let process = pid_t(exactly: pid), let number = UInt32(exactly: windowID),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == process else { return nil }
        let app = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window = element(app, kAXFocusedWindowAttribute),
              windowNumber(window) == number,
              let field = element(app, kAXFocusedUIElementAttribute),
              let owner = element(field, kAXWindowAttribute), CFEqual(owner, window),
              let role = attribute(field, kAXRoleAttribute) as? String, accepts(field)
        else { return nil }
        let target = NativeFocusedTextTarget(pid: process, windowID: number, window: window, field: field)
        AXUIElementSetMessagingTimeout(field, 0.3)
        AXUIElementSetMessagingTimeout(window, 0.3)
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

    private func observedWindow() async -> FocusedTextBinding.WindowSnapshot? {
        guard isCurrent(), supportsSelectedTextInsertion(),
              let title = Self.attribute(window, kAXTitleAttribute) as? String else { return nil }
        let capturedPID = Int(pid), capturedWindow = windowID
        let visible = await Task.detached(priority: .userInitiated) {
            guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, capturedWindow)
                as? [[String: Any]] else { return false }
            return rows.count == 1 && rows.contains(where: {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == capturedPID
                    && ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == Int(capturedWindow)
                    && ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            })
        }.value
        guard visible, !Task.isCancelled, isCurrent() else { return nil }
        return .init(pid: capturedPID, windowID: Int(capturedWindow), title: title, isOnScreen: true)
    }

    private func supportsSelectedTextInsertion() -> Bool {
        guard let role = Self.attribute(field, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole].contains(role), Self.accepts(field) else { return false }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var node: AXUIElement? = field
        var seen: [AXUIElement] = []
        for _ in 0..<32 {
            guard let current = node, !seen.contains(where: { CFEqual($0, current) }),
                  let role = Self.attribute(current, kAXRoleAttribute) as? String,
                  role != "AXWebArea", role != "AXSecureTextField" else { return false }
            if CFEqual(current, window) { return true }
            seen.append(current)
            node = Self.element(current, kAXParentAttribute)
        }
        return false
    }

    private func insertSelectedText(_ text: String, before: String,
                                    selection: NSRange) throws -> FocusedTextBinding.Insertion? {
        try Task.checkCancellation()
        guard supportsSelectedTextInsertion() else { return nil }
        try Task.checkCancellation()
        guard isCurrent(), Self.attribute(field, kAXValueAttribute) as? String == before,
              readSelection() == selection else {
            throw DriverConnectionError.refused("The captured field or insertion point changed. No text was sent.")
        }
        try Task.checkCancellation()
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
        let env = ProcessInfo.processInfo.environment
        if env["JARVIS_P3_GUI_AUDIT_TYPING_REPAIR"] == "1" || !(env["JARVIS_VOICE_EVIDENCE_DIR"] ?? "").isEmpty {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            Self.diagnosticLog.notice("native_focus_rejected reason=\(reason, privacy: .public) expected_pid=\(self.pid) front_pid=\(front) expected_window=\(self.windowID)")
        }
        return false
    }

    private func readValue() -> String? {
        guard isCurrent() else { return nil }
        return Self.attribute(field, kAXValueAttribute) as? String
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
