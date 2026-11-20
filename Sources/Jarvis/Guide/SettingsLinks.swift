import Foundation

/// One System Settings deep link: an `x-apple.systempreferences:` URL
/// naming a settings extension (the pane) and, optionally, one of its
/// anchors, so a recipe can skip the sidebar.
struct SettingsLink: Sendable, Hashable {
    /// The settings extension's `CFBundleIdentifier`, which is its pane id.
    var pane: String
    /// A key of the pane's `.searchTerms` file, or nil for the pane's top.
    var anchor: String? = nil
    /// Where the link lands, in the words the menu steps use.
    var place: String

    var url: URL {
        URL(string: "\(SettingsLinks.scheme):\(pane)" + (anchor.map { "?\($0)" } ?? ""))!
    }
}

/// The deep links the recipes use, and a read-only check that a link
/// resolves on this Mac without opening System Settings.
///
/// Each settings extension under `/System/Library/ExtensionKit/Extensions`
/// declares in its Info.plist, under
/// `EXAppExtensionAttributes.SettingsExtensionAttributes`, whether it
/// accepts the URL scheme (`allowsXAppleSystemPreferencesURLScheme`) and
/// the name of its search terms file (`searchTermsFileName`). That file's
/// top-level keys are the pane's anchors, the same names AppleScript's
/// `reveal anchor` takes. Opening a link is an action, so it rides the
/// drive loop's consented `launch_app`; nothing here opens anything.
enum SettingsLinks {
    static let scheme = "x-apple.systempreferences"
    static let appBundle = "com.apple.systempreferences"
    static let extensionsDirectory = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")

    static let accessibility = "com.apple.Accessibility-Settings.extension"
    static let textSize = SettingsLink(pane: accessibility, anchor: "AX_FONT_SIZE",
                                       place: "Accessibility, Display, Text size")
    static let pointerSize = SettingsLink(pane: accessibility, anchor: "AX_CURSOR_SIZE",
                                          place: "Accessibility, Display, Pointer size")
    static let wifi = SettingsLink(pane: "com.apple.wifi-settings-extension", place: "Wi-Fi")
    static let softwareUpdate = SettingsLink(pane: "com.apple.Software-Update-Settings.extension",
                                             place: "General, Software Update")
    static let all = [textSize, pointerSize, wifi, softwareUpdate]

    /// One settings extension as read from its bundle.
    struct Pane: Sendable, Equatable {
        var bundle: URL
        var allowsScheme: Bool
        var searchTerms: URL?
    }

    /// Every settings extension in `directory`, by pane id.
    static func panes(in directory: URL) -> [String: Pane] {
        let bundles = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var panes: [String: Pane] = [:]
        for bundle in bundles where bundle.pathExtension == "appex" {
            let contents = bundle.appendingPathComponent("Contents")
            guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = info["CFBundleIdentifier"] as? String,
                  let attributes = (info["EXAppExtensionAttributes"] as? [String: Any])?["SettingsExtensionAttributes"]
                      as? [String: Any] else { continue }
            let resources = contents.appendingPathComponent("Resources")
            let terms = (attributes["searchTermsFileName"] as? String).flatMap { name in
                ["en.lproj", "Base.lproj", ""].map {
                    resources.appendingPathComponent($0).appendingPathComponent("\(name).searchTerms")
                }.first { FileManager.default.fileExists(atPath: $0.path) }
            }
            let allows = attributes["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true
            panes[id] = Pane(bundle: bundle, allowsScheme: allows, searchTerms: terms)
        }
        return panes
    }

    static let installed = panes(in: extensionsDirectory)

    /// Nil when the link resolves; otherwise what is missing and where
    /// it was looked for.
    static func problem(with link: SettingsLink, panes: [String: Pane] = installed) -> String? {
        guard let pane = panes[link.pane] else {
            return "no settings extension has the id \(link.pane)"
        }
        guard pane.allowsScheme else {
            return "\(pane.bundle.lastPathComponent) doesn't accept \(scheme): links"
        }
        guard let anchor = link.anchor else { return nil }
        guard let terms = pane.searchTerms, let data = try? Data(contentsOf: terms),
              let anchors = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return "\(pane.bundle.lastPathComponent) has no readable search terms file"
        }
        return anchors[anchor] == nil ? "anchor \(anchor) isn't a key of \(terms.path)" : nil
    }
}
