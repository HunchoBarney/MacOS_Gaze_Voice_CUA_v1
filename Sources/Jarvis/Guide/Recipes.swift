import Foundation

/// A short hand-reviewed script for one of the top guide tasks (§2's Guide
/// rows). Its steps are hints to Jev, not a track: Jev still chooses each
/// step from the live window, a hint applies only when its control is the
/// one Jev chose, and a missing control falls back to plain guide mode.
struct Recipe: Sendable, Equatable {
    var id: String
    /// The note's title: "How to attach a photo to an email".
    var title: String
    /// Ways to ask for it. Every group in one pattern must hit the goal;
    /// a group lists alternatives as "a|b|c", each a word or phrase.
    var patterns: [[String]]
    /// Words or phrases that rule this recipe out.
    var excludes: [String] = []
    /// The app the walkthrough binds when the request named none.
    var app: String? = nil
    /// A System Settings page that skips the menu steps.
    var link: SettingsLink? = nil
    /// The steps that reach `link`'s page without it.
    var menuSteps: [GuideHint] = []
    var steps: [GuideHint]
    /// The written steps for "write the steps in a note".
    var note: [String]

    /// Every hint, menu steps first, so a link that didn't land is
    /// covered by the same walkthrough.
    var hints: [GuideHint] { menuSteps + steps }

    /// What Jev hears beside the step hints.
    var context: String {
        "Recipe: \(title)."
            + (link.map { " System Settings was asked to open \($0.place); if that page is showing, skip the steps that get there." } ?? "")
    }

    /// Lowercased words without punctuation: "Wi-Fi isn't" → "wi fi isnt".
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func has(_ phrase: String, in padded: String) -> Bool {
        let words = normalize(phrase)
        return !words.isEmpty && padded.contains(" \(words) ")
    }

    func matches(_ goal: String) -> Bool {
        let padded = " \(Self.normalize(goal)) "
        guard !excludes.contains(where: { Self.has($0, in: padded) }) else { return false }
        return patterns.contains { groups in
            groups.allSatisfy { group in
                group.split(separator: "|").contains { Self.has(String($0), in: padded) }
            }
        }
    }

    /// The one recipe this goal asks for, or nil when none or several
    /// match: an unmatched goal runs plain guide mode.
    static func match(_ goal: String) -> Recipe? {
        let hits = all.filter { $0.matches(goal) }
        return hits.count == 1 ? hits[0] : nil
    }
}

extension GuideHint {
    /// How well this hint's control names the step Jev chose: 2 for the
    /// same words, 1 when the label contains them, 0 for no match.
    func score(_ action: GuideAction) -> Int {
        guard let control else { return 0 }
        let want = Recipe.normalize(control)
        guard !want.isEmpty else { return 0 }
        func compare(_ label: String) -> Int {
            let have = Recipe.normalize(label)
            if have == want { return 2 }
            return " \(have) ".contains(" \(want) ") ? 1 : 0
        }
        switch action {
        case .element(let element, _):
            return compare(element.label)
        case .key(let combo):
            return Self.keys(combo) == Self.keys(control) ? 2 : 0
        case .menu(let path):
            return Recipe.normalize(path.joined(separator: " ")) == want ? 2 : compare(path.last ?? "")
        case .scroll:
            return 0
        }
    }

    private static func keys(_ combo: String) -> Set<String> {
        let aliases = ["command": "cmd", "option": "alt", "opt": "alt", "control": "ctrl",
                       "esc": "escape", "return": "enter"]
        return Set(combo.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " })
            .map { aliases[String($0)] ?? String($0) })
    }
}

extension GuideNote {
    /// The recipe's own hand-reviewed wording, not the live instructions.
    init(recipe: Recipe) {
        title = recipe.title
        steps = recipe.note
    }
}

extension Recipe {
    private static let photo = "photo|photos|picture|pictures|pic|pics|image|images"
    private static let settings = "System Settings"
    private static let openSettings = "Click the Apple menu at the top left of the screen, then System Settings."
    private static let toDisplay = [
        GuideHint(control: "Accessibility", windowNoun: settings),
        GuideHint(control: "Display", detail: "It's under Vision, with a picture of a screen.", windowNoun: settings),
    ]

    static let attachPhoto = Recipe(
        id: "attach-photo", title: "How to attach a photo to an email",
        patterns: [["attach|attaching", photo], ["email|mail|e mail", photo, "add|put|send|sending|insert|include"]],
        excludes: ["save", "download", "import", "keep"],
        steps: [
            GuideHint(control: "Attach", describe: "the paperclip",
                      detail: "It's the paperclip picture at the top of your message, near the right.",
                      windowNoun: "your message"),
            GuideHint(control: "Photos", detail: "Look in the list on the left of the panel, under Media.",
                      windowNoun: "the panel"),
            GuideHint(control: "Choose File", describe: "the Choose File button",
                      detail: "It's the blue button at the bottom right of the panel.", windowNoun: "the panel"),
        ],
        note: ["Open your new message in Mail.",
               "Click the paperclip at the top of the message.",
               "On the left of the panel that opens, click Photos.",
               "Click the photo you want.",
               "Click Choose File. The photo appears in your message."])

    static let saveMailPhotos = Recipe(
        id: "save-mail-photos", title: "How to save photos from an email",
        patterns: [["save|saving|keep|download|downloading", "attachment|attachments"],
                   ["save|saving|keep|download", photo, "email|mail|e mail|emailed|message"]],
        excludes: ["to photos", "into photos", "in photos", "to my photos", "photos app", "photo library",
                   "photos library", "attach"],
        steps: [
            GuideHint(control: "Save Attachments", detail: "Click File at the top of the screen, then Save Attachments."),
            GuideHint(control: "Save", describe: "the Save button",
                      detail: "It's the blue button at the bottom right of the panel.", windowNoun: "the panel"),
        ],
        note: ["Open the email with the photos in Mail.",
               "Click File at the top of the screen, then Save Attachments.",
               "Choose where to keep them, for example Pictures.",
               "Click Save."])

    static let importToPhotos = Recipe(
        id: "import-to-photos", title: "How to put photos into the Photos app",
        patterns: [["save|saving|keep|add|adding|put|import|importing",
                    "to photos|into photos|in photos|to my photos|into my photos|photos app|photo library|photos library"]],
        excludes: ["email", "mail", "e mail", "attachment", "attachments"],
        app: "com.apple.Photos",
        steps: [
            GuideHint(control: "Import", detail: "Click File at the top of the screen, then Import."),
            GuideHint(control: "Review for Import", describe: "the Review for Import button",
                      detail: "It's at the bottom right of the panel, after you've clicked the photos.",
                      windowNoun: "the panel"),
            GuideHint(control: "Import All New Items", describe: "the Import All New Items button",
                      detail: "It's at the top right of the window.", windowNoun: "Photos"),
        ],
        note: ["Open Photos.",
               "Click File at the top of the screen, then Import.",
               "Find the photos, for example in Downloads, and click them.",
               "Click Review for Import, then click Import All New Items."])

    static let joinCall = Recipe(
        id: "join-call", title: "How to join a video call from a link",
        patterns: [["join|joining|get on|get into|hop on", "call|meeting|zoom|facetime|video|appointment|link"]],
        steps: [
            GuideHint(control: "Join with Computer Audio", describe: "Join with Computer Audio",
                      detail: "It's the blue button in the middle of the call window. It lets them hear you."),
            GuideHint(control: "Join", describe: "the Join button",
                      detail: "It's the green or blue button that says Join.",
                      effect: "joins the call, so they can see and hear you"),
        ],
        note: ["Open the email or message with the call link.",
               "Click the link.",
               "When the call opens, click Join.",
               "If it asks about sound, click Join with Computer Audio.",
               "If your Mac asks to use the camera or microphone, click Allow."])

    static let printing = Recipe(
        id: "print", title: "How to print",
        patterns: [["print|printing"]],
        excludes: ["printer", "printers", "scan", "scanner", "ink", "jam", "jammed", "broken", "not working",
                   "isnt working", "wont", "doesnt", "screen", "screenshot"],
        steps: [
            GuideHint(control: "cmd+p",
                      detail: "Hold down the Command key, the one with \u{2318} on it next to the space bar. Then press P once."),
            GuideHint(control: "Print", describe: "the Print button",
                      detail: "It's the blue button at the bottom right of the print panel.",
                      effect: "prints it, which uses paper and ink", windowNoun: "the print panel"),
        ],
        note: ["Open what you want to print.",
               "Hold Command and press P.",
               "Check the printer and the number of pages.",
               "Click Print."])

    static let textSize = Recipe(
        id: "text-size", title: "How to make the text bigger on your Mac",
        patterns: [["text|writing|words|font|fonts|letters",
                    "bigger|larger|smaller|size|big|large|increase|easier to read|hard to read|cant read|too small|tiny"]],
        excludes: ["pointer", "cursor", "mouse", "print", "page", "website", "site", "web", "safari", "chrome",
                   "email", "send", "sending", "message", "messages", "photo", "photos", "picture", "pictures"],
        app: SettingsLinks.appBundle, link: SettingsLinks.textSize, menuSteps: toDisplay,
        steps: [GuideHint(control: "Text size", detail: "It's under Text, with a small arrow on its right.",
                          windowNoun: settings)],
        note: [openSettings,
               "Click Accessibility on the left, then Display.",
               "Click Text size.",
               "Drag the slider to the right to make text bigger."])

    static let pointerSize = Recipe(
        id: "pointer-size", title: "How to make the pointer bigger",
        patterns: [["pointer|cursor|mouse|arrow",
                    "bigger|larger|size|big|find|see|lost|hard to see|too small|increase"]],
        excludes: ["text", "writing", "font", "battery", "bluetooth", "connect", "connected", "connection", "keys"],
        app: SettingsLinks.appBundle, link: SettingsLinks.pointerSize, menuSteps: toDisplay,
        steps: [GuideHint(control: "Pointer size", describe: "the Pointer size slider",
                          detail: "It's under Pointer. Drag the dot to the right to make the pointer bigger.",
                          windowNoun: settings)],
        note: [openSettings,
               "Click Accessibility on the left, then Display.",
               "Find Pointer size and drag its slider to the right.",
               "To find the pointer any time, shake the mouse or move your finger quickly on the trackpad."])

    static let wifi = Recipe(
        id: "wifi", title: "How to turn Wi-Fi off and on again",
        patterns: [["wifi|wi fi"],
                   ["internet|network", "working|connected|connect|down|fix|broken|not|isnt|wont|cant"]],
        excludes: ["forget", "password", "share", "printer", "drive", "bluetooth"],
        app: SettingsLinks.appBundle, link: SettingsLinks.wifi,
        steps: [GuideHint(control: "Wi-Fi",
                          detail: "It's near the top. On the Wi-Fi page it's a switch: click it once to turn Wi-Fi off, wait a moment, then click it again.",
                          windowNoun: settings)],
        note: [openSettings,
               "Click Wi-Fi on the left.",
               "Click the Wi-Fi switch to turn it off. Wait a few seconds.",
               "Click it again to turn it on.",
               "If your network isn't joined, click its name and type its password."])

    static let updates = Recipe(
        id: "updates", title: "How to update your Mac",
        patterns: [["update|updates|updating|upgrade|upgrading",
                    "mac|macos|software|system|computer|install|installing|keeps asking"]],
        excludes: ["app", "apps", "app store", "contact", "contacts", "address", "calendar", "font", "password"],
        app: SettingsLinks.appBundle, link: SettingsLinks.softwareUpdate,
        menuSteps: [GuideHint(control: "General", windowNoun: settings),
                    GuideHint(control: "Software Update", windowNoun: settings)],
        steps: [
            GuideHint(control: "Update Now", describe: "the Update Now button",
                      detail: "It's on the right, under the update's name.",
                      effect: "installs the update and restarts your Mac", windowNoun: settings),
            GuideHint(control: "Restart Now", describe: "the Restart Now button",
                      effect: "restarts your Mac", windowNoun: settings),
        ],
        note: [openSettings,
               "Click General on the left, then Software Update.",
               "When you're ready, click Update Now. Your Mac restarts by itself to finish."])

    static let exitFullScreen = Recipe(
        id: "exit-full-screen", title: "How to leave full screen",
        patterns: [["full screen|fullscreen", "exit|leave|leaving|out|stop|stuck|close|escape|off|undo|normal|back"],
                   ["menu bar", "gone|missing|disappeared|hidden|back"]],
        excludes: ["make it full screen", "enter full screen", "go full screen", "into full screen",
                   "to full screen"],
        steps: [
            GuideHint(control: "Exit Full Screen",
                      detail: "Move the pointer to the very top of the screen so the menu bar shows. Then click View, then Exit Full Screen."),
            GuideHint(control: "ctrl+cmd+f",
                      detail: "Hold down Control and Command, the two keys left of the space bar, and press F once."),
        ],
        note: ["Move the pointer to the very top of the screen until the menu bar appears.",
               "Click View, then Exit Full Screen.",
               "Or hold Control and Command and press F."])

    static let findDownload = Recipe(
        id: "find-download", title: "How to find something you downloaded",
        patterns: [["find|where|open|see|locate|lost|get to|look", "download|downloads|downloaded"]],
        excludes: ["update", "updates", "install"],
        steps: [
            GuideHint(control: "Downloads",
                      detail: "In the Finder it's in the list on the left, with a down arrow. Or click Go at the top of the screen, then Downloads."),
            GuideHint(control: "Date Added",
                      detail: "Click View at the top of the screen, then Sort By, then Date Added, so the newest file is first."),
        ],
        note: ["Click the Finder in the Dock. It's the blue smiling face.",
               "Click Go at the top of the screen, then Downloads.",
               "Click View, then Sort By, then Date Added, so the newest is on top.",
               "Double-click the file to open it."])

    static let all = [attachPhoto, saveMailPhotos, importToPhotos, joinCall, printing, textSize, pointerSize,
                      wifi, updates, exitFullScreen, findDownload]
}
