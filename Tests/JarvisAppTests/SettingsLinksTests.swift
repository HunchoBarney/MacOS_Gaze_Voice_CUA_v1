import Foundation
import XCTest
@testable import Jarvis

/// Every System Settings deep link the recipes use resolves on this Mac,
/// read from disk without opening System Settings. The source is each
/// settings extension's bundle under /System/Library/ExtensionKit/Extensions:
/// its Info.plist names the pane id (`CFBundleIdentifier`), whether the
/// pane takes `x-apple.systempreferences:` links
/// (`EXAppExtensionAttributes.SettingsExtensionAttributes.allowsXAppleSystemPreferencesURLScheme`)
/// and its search terms file (`searchTermsFileName`), whose top-level keys
/// are the pane's anchors. A missing pane, a pane that refuses the scheme
/// or an anchor that isn't a key fails with the file it read.
final class SettingsLinksTests: XCTestCase {
    func testTableShape() {
        XCTAssertEqual(SettingsLinks.all.map(\.url.absoluteString), [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_FONT_SIZE",
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AX_CURSOR_SIZE",
            "x-apple.systempreferences:com.apple.wifi-settings-extension",
            "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
        ])
        for link in SettingsLinks.all {
            XCTAssertEqual(link.url.scheme, SettingsLinks.scheme)
            XCTAssertFalse(link.place.isEmpty)
            if let anchor = link.anchor {
                XCTAssertNil(anchor.rangeOfCharacter(from: CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "_.-")).inverted), anchor)
            }
        }
    }

    func testEveryLinkResolvesOnThisMac() throws {
        let directory = SettingsLinks.extensionsDirectory
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
              FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("no macOS 26 settings extensions at \(directory.path)")
        }
        let panes = SettingsLinks.panes(in: directory)
        XCTAssertFalse(panes.isEmpty, "no settings extensions read from \(directory.path)")
        for link in SettingsLinks.all {
            let problem = SettingsLinks.problem(with: link, panes: panes)
            XCTAssertNil(problem, "\(link.url.absoluteString): \(problem ?? "")")
        }
    }

    func testMissingAnchorFailsWithTheFileItRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-links-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func appex(_ name: String, id: String, allows: Bool, anchors: [String]) throws {
            let contents = root.appendingPathComponent("\(name).appex/Contents")
            let lproj = contents.appendingPathComponent("Resources/en.lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": id,
                "EXAppExtensionAttributes": ["SettingsExtensionAttributes": [
                    "allowsXAppleSystemPreferencesURLScheme": allows, "searchTermsFileName": name]],
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let terms = Dictionary(uniqueKeysWithValues: anchors.map { ($0, ["localizableStrings": []]) })
            try PropertyListSerialization.data(fromPropertyList: terms, format: .xml, options: 0)
                .write(to: lproj.appendingPathComponent("\(name).searchTerms"))
        }
        try appex("Fixture", id: "com.example.Fixture-Settings.extension", allows: true, anchors: ["Present"])
        try appex("Closed", id: "com.example.Closed-Settings.extension", allows: false, anchors: [])
        let panes = SettingsLinks.panes(in: root)
        XCTAssertEqual(Set(panes.keys), ["com.example.Fixture-Settings.extension", "com.example.Closed-Settings.extension"])

        let present = SettingsLink(pane: "com.example.Fixture-Settings.extension", anchor: "Present", place: "Fixture")
        XCTAssertNil(SettingsLinks.problem(with: present, panes: panes))
        var missing = present
        missing.anchor = "Gone"
        let problem = SettingsLinks.problem(with: missing, panes: panes)
        XCTAssertEqual(problem?.hasPrefix("anchor Gone isn't a key of "), true, problem ?? "")
        XCTAssertEqual(problem?.hasSuffix("Fixture.appex/Contents/Resources/en.lproj/Fixture.searchTerms"), true,
                       problem ?? "")
        XCTAssertEqual(SettingsLinks.problem(with: SettingsLink(pane: "com.example.Nowhere", place: "x"), panes: panes),
                       "no settings extension has the id com.example.Nowhere")
        XCTAssertEqual(SettingsLinks.problem(with: SettingsLink(pane: "com.example.Closed-Settings.extension",
                                                                place: "x"), panes: panes),
                       "Closed.appex doesn't accept x-apple.systempreferences: links")
    }
}
