import ApplicationServices
import CryptoKit
import Darwin
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func fingerprint(_ value: String?) -> Any {
    guard let value else { return NSNull() }
    return ["count": value.count, "utf8_count": value.utf8.count,
            "sha256": SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()] as [String: Any]
}

func number(_ element: AXUIElement) -> UInt32? {
    typealias Read = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
    var result: UInt32 = 0
    return unsafeBitCast(symbol, to: Read.self)(element, &result) == 0 ? result : nil
}

let arguments = CommandLine.arguments
guard arguments.count == 4, let pid = pid_t(arguments[1]), pid > 0,
      let target = UInt32(arguments[2]), target > 0, arguments[3].count >= 10 else { exit(2) }
let application = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(application, 0.2)
func scopeFailure(_ reason: String) -> Never {
    FileHandle.standardError.write(Data((reason + "\n").utf8))
    exit(3)
}
var rawWindows: CFTypeRef?
let windowsStatus = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows)
guard windowsStatus == .success, let windows = rawWindows as? [AXUIElement] else {
    scopeFailure("native_probe_windows_unavailable:\(windowsStatus.rawValue)")
}
guard let root = windows.first(where: { number($0) == target }) else {
    scopeFailure("native_probe_window_identity_unavailable")
}
guard let title = attribute(root, kAXTitleAttribute) as? String else {
    scopeFailure("native_probe_title_unavailable")
}
if arguments[3].hasPrefix("sha256:") {
    let expected = String(arguments[3].dropFirst(7))
    let actual = SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
    guard expected.count == 64, actual == expected else { scopeFailure("native_probe_title_mismatch") }
} else {
    guard title.contains(arguments[3]) else { scopeFailure("native_probe_title_mismatch") }
}
var rawDocument: CFTypeRef?
let documentError = AXUIElementCopyAttributeValue(root, kAXDocumentAttribute as CFString, &rawDocument)
var documentStatus = "unreadable"
var documentPath: String?
if documentError == .noValue {
    documentStatus = "no_value"
} else if documentError == .success {
    if let string = rawDocument as? String, string.isEmpty {
        documentStatus = "no_value"
    } else if let url = (rawDocument as? URL) ?? (rawDocument as? String).flatMap(URL.init(string:)) {
        documentStatus = url.isFileURL ? "file" : "nonfile"
        if url.isFileURL { documentPath = url.standardizedFileURL.resolvingSymlinksInPath().path }
    }
}
var rawEdited = attribute(root, kAXEditedAttribute)
var editedSource = rawEdited == nil ? "unavailable" : "window"
if rawEdited == nil, let close = attribute(root, kAXCloseButtonAttribute),
   CFGetTypeID(close) == AXUIElementGetTypeID() {
    rawEdited = attribute(close as! AXUIElement, kAXEditedAttribute)
    if rawEdited != nil { editedSource = "close_button" }
}
let edited: Any = rawEdited.flatMap {
    CFGetTypeID($0) == CFBooleanGetTypeID() ? ($0 as? Bool).map { $0 as Any } : nil
} ?? NSNull()
var pending = [root]
var seen: Set<AXUIElement> = []
var fields: [[String: Any]] = []
var controls: [[String: Any]] = []
var modalSheets = 0
var ownedSheetWindowIDs: Set<UInt32> = []
var roleReadFailures = 0
var childrenReadFailures = 0
while let element = pending.popLast(), seen.count < 2000 {
    guard seen.insert(element).inserted else { continue }
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    if role.isEmpty { roleReadFailures += 1 }
    if role == "AXSheet" {
        modalSheets += 1
        if let id = number(element), id > 0 { ownedSheetWindowIDs.insert(id) }
    }
    let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
    guard !role.lowercased().contains("secure"), !subrole.lowercased().contains("secure"),
          !role.lowercased().contains("menu") else { continue }
    var rawChildren: CFTypeRef?
    let childrenStatus = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren)
    if childrenStatus == .success {
        if let children = rawChildren as? [AXUIElement] { pending += children }
        else { childrenReadFailures += 1 }
    } else if childrenStatus != .noValue && childrenStatus != .attributeUnsupported {
        childrenReadFailures += 1
    }
    guard ["AXTextArea", "AXTextField", "AXComboBox", "AXButton"].contains(role) else { continue }
    let title = attribute(element, kAXTitleAttribute) as? String
    let description = attribute(element, kAXDescriptionAttribute) as? String
    let labels = [title, description].compactMap { $0 }.joined(separator: " ").lowercased()
    guard !labels.contains("password"), !labels.contains("secure") else { continue }
    var row: [String: Any] = [
        "role": role, "title": fingerprint(title), "description": fingerprint(description),
        "value": fingerprint(attribute(element, kAXValueAttribute) as? String),
    ]
    if let position = attribute(element, kAXPositionAttribute),
       let size = attribute(element, kAXSizeAttribute),
       CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        if AXValueGetValue(position as! AXValue, .cgPoint, &point),
           AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
            row["frame"] = ["x": point.x, "y": point.y,
                            "width": dimensions.width, "height": dimensions.height]
        }
    }
    if role == "AXButton" { controls.append(row) }
    else { fields.append(row) }
}
let result: [String: Any] = ["ax_trusted": AXIsProcessTrusted(), "visited": seen.count,
                             "pid": pid, "window_id": target, "window_title": fingerprint(title),
                             "document": ["status": documentStatus, "path": fingerprint(documentPath)],
                             "edited": edited, "edited_source": editedSource,
                             "budget_exhausted": !pending.isEmpty,
                             "modal_sheets": modalSheets, "role_read_failures": roleReadFailures,
                             "owned_sheet_window_ids": ownedSheetWindowIDs.sorted(),
                             "children_read_failures": childrenReadFailures,
                             "target_found": true, "fields": fields, "controls": controls]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
FileHandle.standardOutput.write(Data("\n".utf8))
