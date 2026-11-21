import CoreGraphics
import Foundation

/// One element as guide mode sees it: what it is, what it says and where
/// it sits, in global top-left points (the accessibility tree's space).
/// A secure field's value is never carried.
struct GuideElement: Sendable, Equatable {
    var role: String
    var label: String
    var value: String? = nil
    var frame: CGRect? = nil
}

/// A recipe's hint for one step (piece 10 feeds these). Every field is
/// optional: a hint steers Jev and the words, it never replaces the live
/// tree.
struct GuideHint: Sendable, Equatable {
    /// The control Jev should prefer, folded into its context.
    var control: String? = nil
    /// How to name the control: "the paperclip".
    var describe: String? = nil
    /// The more detailed repeat: "It's grey, with a paperclip picture, next to the smiley face."
    var detail: String? = nil
    /// What a consequential press does, after "This one": "sends it to Linda".
    /// A recipe names it for presses the consequence words miss, such as
    /// Update Now or Print.
    var effect: String? = nil
    /// What the step should change.
    var expect: GuideExpectation? = nil
    /// What to call the window: "your message".
    var windowNoun: String? = nil
}

/// The effect a step should have once the person acts.
enum GuideExpectation: Sendable, Equatable {
    /// The window changed (a sheet opened, a value moved, a row selected).
    case anyChange
    /// This text is visible afterwards: a sheet's title, a typed value.
    case appears(String)
}

/// What Jev chose for this step, in the shape guide mode can point at.
enum GuideAction: Sendable, Equatable {
    case element(GuideElement, typing: String? = nil)
    case key(String)
    case menu([String])
    case scroll(String)
}

/// One guide step: the model the callout renders (piece 9) and the words
/// Jarvis speaks. `total` is nil while Jev picks steps live; a recipe
/// knows it.
struct GuideStep: Sendable, Equatable {
    var number: Int
    var total: Int? = nil
    var action: GuideAction
    var target: GuideElement?
    var windowFrame: CGRect?
    /// The control's name in plain words: "the Send button".
    var name: String
    /// "Click the Send button, at the bottom of the window, on the right."
    var instruction: String
    /// The 10-second repeat with more detail.
    var detail: String
    /// The same instruction in short, slow sentences.
    var slow: String
    /// "This one sends it. Click the Send button when you're ready."
    var consequenceLine: String?
    var consequence: Consequence?
    var expect: GuideExpectation
}

/// Plain words with a location, built from the element's role, label and
/// frame relative to its window. No model call: the words must say
/// exactly what is glowing.
enum StepPhrasing {
    static func role(_ raw: String) -> String {
        var r = raw.lowercased()
        if r.hasPrefix("ax") { r.removeFirst(2) }
        return r
    }

    private static func isTextEntry(_ role: String) -> Bool {
        ["textfield", "textarea", "searchfield", "combobox", "securetextfield"].contains(role)
    }

    static func isTextEntry(_ element: GuideElement) -> Bool { isTextEntry(role(element.role)) }

    /// What a person would call this kind of control.
    static func noun(_ raw: String) -> String {
        let r = role(raw)
        if isTextEntry(r) { return "box" }
        switch r {
        case "button", "menubutton": return "button"
        case "checkbox": return "box"
        case "menuitem": return "item"
        case "menubaritem", "popupbutton": return "menu"
        case "link": return "link"
        case "tab", "radiobutton": return "tab"
        case "image": return "picture"
        case "slider": return "slider"
        case "row", "cell", "outlinerow": return "row"
        default: return "spot"
        }
    }

    /// "the Send button", "the To box", "the File menu", "New Message".
    static func name(of element: GuideElement, hint: GuideHint? = nil) -> String {
        if let described = hint?.describe, !described.isEmpty { return described }
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = role(element.role)
        let kind = noun(r)
        guard !label.isEmpty else { return "this \(kind)" }
        switch r {
        case "menuitem", "row", "cell", "outlinerow", "statictext": return label
        default:
            return label.lowercased().hasSuffix(kind) ? "the \(label)" : "the \(label) \(kind)"
        }
    }

    static func verb(for element: GuideElement) -> String {
        let r = role(element.role)
        if isTextEntry(r) { return "Click in" }
        if r == "slider" { return "Drag" }
        return "Click"
    }

    /// Where the element sits: "at the top of the window, on the right".
    /// Nil when there is no frame to place.
    static func location(of element: GuideElement, in window: CGRect?,
                         windowNoun: String = "the window") -> String? {
        let r = role(element.role)
        if r == "menubaritem" { return "at the top of the screen" }
        if r == "menuitem" { return "in the menu" }
        guard let frame = element.frame, frame.width > 0, frame.height > 0,
              let window, window.width > 0, window.height > 0,
              window.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.midX, y: frame.midY))
        else { return nil }
        let x = (frame.midX - window.minX) / window.width
        let y = (frame.midY - window.minY) / window.height
        let side: String? = x < 1.0 / 3 ? "left" : x > 2.0 / 3 ? "right" : nil
        let edge = y < 1.0 / 3 ? "top" : y > 2.0 / 3 ? "bottom" : "middle"
        switch (edge, side) {
        case ("middle", nil): return "in the middle of \(windowNoun)"
        case ("middle", let side?): return "on the \(side) side of \(windowNoun)"
        case (let edge, nil): return "at the \(edge) of \(windowNoun)"
        case (let edge, let side?): return "at the \(edge) of \(windowNoun), on the \(side)"
        }
    }

    /// The nearest other labelled control on the same row, else the
    /// nearest within reach: "the Format button".
    static func neighbor(of element: GuideElement, in scene: [GuideElement]) -> String? {
        guard let frame = element.frame else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let others = scene.compactMap { other -> (element: GuideElement, distance: CGFloat, sameRow: Bool)? in
            guard other != element, let f = other.frame, f.width > 0, f.height > 0,
                  !other.label.trimmingCharacters(in: .whitespaces).isEmpty,
                  other.label != element.label, noun(other.role) != "spot" else { return nil }
            let d = hypot(f.midX - center.x, f.midY - center.y)
            guard d <= 200 else { return nil }
            return (other, d, abs(f.midY - center.y) <= max(frame.height, 12))
        }
        let pick = others.filter(\.sameRow).min { $0.distance < $1.distance }
            ?? others.min { $0.distance < $1.distance }
        return pick.map { name(of: $0.element) }
    }

    static func consequenceEffect(_ consequence: Consequence) -> String? {
        switch consequence {
        case .send: return "sends it"
        case .pay: return "spends money"
        case .delete: return "deletes it"
        case .call: return "starts a call"
        case .account: return "changes your account"
        case .permission: return "gives an app new access to your Mac"
        case .restart: return "restarts or shuts down your Mac"
        case .unnamed: return nil
        }
    }

    /// "the Escape key, …", "Return", "hold Command and press Z".
    static func keyName(_ combo: String) -> String {
        let names = ["cmd": "Command", "command": "Command", "shift": "Shift", "alt": "Option",
                     "option": "Option", "opt": "Option", "ctrl": "Control", "control": "Control",
                     "escape": "Escape", "esc": "Escape", "return": "Return", "enter": "Return",
                     "tab": "Tab", "space": "the space bar", "delete": "Delete", "backspace": "Delete",
                     "up": "the up arrow", "down": "the down arrow", "left": "the left arrow",
                     "right": "the right arrow"]
        let parts = combo.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }).map(String.init)
        let spoken = parts.map { names[$0] ?? $0.uppercased() }
        guard let key = spoken.last else { return combo }
        if spoken.count == 1 { return key == "Escape" ? "the Escape key, at the top left of your keyboard" : key }
        return "hold " + spoken.dropLast().joined(separator: " and ") + " and press " + key
    }

    /// The step's words and its model. `scene` is the window's other
    /// elements, for "next to …"; `window` is its frame.
    static func step(number: Int, total: Int? = nil, action: GuideAction,
                     window: CGRect?, scene: [GuideElement], hint: GuideHint?) -> GuideStep {
        let windowNoun = hint?.windowNoun ?? "the window"
        switch action {
        case .element(let element, let typing):
            let name = name(of: element, hint: hint)
            let verb = verb(for: element)
            let place = location(of: element, in: window, windowNoun: windowNoun)
            let at = place.map { ", \($0)" } ?? ""
            let typed = typing.map { ", and type \u{201C}\($0)\u{201D}" } ?? ""
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = neighbor(of: element, in: scene).map { ", next to \($0)" } ?? ""
            let detail = hint?.detail ?? (label.isEmpty
                ? "It's the \(noun(element.role)) with the glow around it\(at)\(next)."
                : "Look for the \(noun(element.role)) that says \(label)\(at)\(next).")
            let slow = "Take your time. "
                + (place.map { "Look \($0). " } ?? "Look where it's glowing. ")
                + "Find \(name). Then \(verb.lowercased()) it, just once."
                + (typing.map { " Then type \u{201C}\($0)\u{201D}." } ?? "")
            let consequence = Consequence.of(control: label)
            let effect = hint?.effect ?? consequence.flatMap(consequenceEffect)
            let line = effect.map { "This one \($0). \(verb) \(name) when you're ready." }
            return GuideStep(number: number, total: total, action: action, target: element,
                             windowFrame: window, name: name,
                             instruction: "\(verb) \(name)\(at)\(typed).",
                             detail: detail, slow: slow, consequenceLine: line,
                             consequence: consequence,
                             expect: hint?.expect ?? typing.map { .appears($0) } ?? .anyChange)
        case .key(let combo):
            let key = keyName(combo)
            let instruction = key.hasPrefix("hold ")
                ? key.prefix(1).uppercased() + key.dropFirst() + "." : "Press \(key)."
            return GuideStep(number: number, total: total, action: action, target: nil,
                             windowFrame: window, name: key, instruction: instruction,
                             detail: hint?.detail ?? instruction, slow: "Take your time. " + instruction,
                             consequenceLine: nil, consequence: nil, expect: hint?.expect ?? .anyChange)
        case .menu(let path):
            let first = path.first ?? "the menu"
            let instruction = (["Click \(first), at the top of the screen"]
                + path.dropFirst().map { "click \($0)" }).joined(separator: ", then ") + "."
            let slow = "Take your time. Look at the top of the screen. Click \(first)."
                + path.dropFirst().map { " Then click \($0)." }.joined()
            let consequence = path.last.flatMap { Consequence.of(control: $0) }
            let effect = hint?.effect ?? consequence.flatMap(consequenceEffect)
            return GuideStep(number: number, total: total, action: action, target: nil,
                             windowFrame: window, name: path.last ?? first, instruction: instruction,
                             detail: hint?.detail ?? instruction, slow: slow,
                             consequenceLine: effect.map { "This one \($0). \(instruction.dropLast()) when you're ready." },
                             consequence: consequence, expect: hint?.expect ?? .anyChange)
        case .scroll(let direction):
            let instruction = "Scroll \(direction) a little."
            return GuideStep(number: number, total: total, action: action, target: nil,
                             windowFrame: window, name: "scroll", instruction: instruction,
                             detail: hint?.detail
                                ?? "Use two fingers on the trackpad, or the mouse wheel, to scroll \(direction).",
                             slow: "Take your time. " + instruction, consequenceLine: nil,
                             consequence: nil, expect: hint?.expect ?? .anyChange)
        }
    }

    static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    /// The first line of a step. A consequential one names its effect first.
    static func opening(_ step: GuideStep, slow: Bool) -> String {
        if let line = step.consequenceLine { return line }
        if slow { return step.slow }
        let glow = step.target?.frame != nil ? " It's glowing." : ""
        if step.number == 1 {
            return "Okay, one step at a time. First, \(lowercasedFirst(step.instruction))\(glow)"
        }
        return "Now \(lowercasedFirst(step.instruction))"
    }
}
