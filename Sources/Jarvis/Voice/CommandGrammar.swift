import Foundation

/// Ordinary ways of saying the commands Jarvis already parses — "get
/// Safari open", "hop over to desktop 2", "label everything" — read as one
/// small grammar: an optional lead-in ("I want to", "let's", "help me"),
/// a verb class, an object, and an optional particle. Each family rewrites
/// to the canonical command the fast lane already knows, and a rewrite is
/// used only when that canonical command parses to the family's action, so
/// the grammar can only add phrasings, never change what an existing
/// command does. Anything it can't read stays with Jev and the model.
enum CommandGrammar {
    /// The canonical command for `text`, or nil when no frame fits.
    /// `isApp` says whether a spoken name is an app on this Mac.
    static func canonical(_ text: String, isApp: (String) -> Bool) -> String? {
        if let parsed = FastAction.parse(text) {
            switch parsed.action.body {
            case .clickNamed, .showNamed: break
            default:
                // A trailing "on screen" read as an app that isn't one is a
                // misreading the grammar may correct; anything else stands.
                guard let qualifier = parsed.appQualifier, !isApp(qualifier) else { return nil }
            }
        }
        if let open = FastAction.parseOpen(text), isApp(open.query) { return nil }
        let original = words(text)
        guard let first = original.first, !interrogatives.contains(first),
              !original.contains(where: negations.contains),
              !(original.starts(with: ["do", "not"])) else { return nil }
        let core = strip(original)
        guard !core.isEmpty else { return nil }
        if let command = desktop(core) ?? names(core) ?? find(core, isApp: isApp)
            ?? click(core) ?? open(core, isApp: isApp) {
            return command == original.joined(separator: " ") ? nil : command
        }
        guard core != original else { return nil }
        let bare = core.joined(separator: " ")
        if let open = FastAction.parseOpen(bare), isApp(open.query) { return bare }
        return FastAction.parse(bare) == nil ? nil : bare
    }

    /// A question about what is on the screen, the page or the window in
    /// front of the person — answered from the screen, never acted on.
    static func asksAboutScreen(_ text: String) -> Bool {
        let core = strip(words(text))
        guard let first = core.first, !screenActions.contains(first) else { return false }
        let phrase = " " + core.joined(separator: " ") + " "
        guard screenNouns.contains(where: { phrase.contains(" \($0) ") }) else { return false }
        return screenAsks.contains { phrase.contains(" \($0) ") }
    }

    // MARK: - Families

    /// "hop over to desktop 2", "put me on desktop 2", "send me to the
    /// third space": a motion verb, an optional "me", "over" and
    /// preposition, then a desktop the desktop parser can name.
    private static func desktop(_ w: [String]) -> String? {
        guard let verb = w.first, motionVerbs.contains(verb) else { return nil }
        var rest = Array(w.dropFirst())
        if let next = rest.first, ["me", "us"].contains(next) { rest.removeFirst() }
        if let next = rest.first, ["over", "back", "across"].contains(next) { rest.removeFirst() }
        guard let preposition = rest.first, ["to", "onto", "on", "into"].contains(preposition) else { return nil }
        let command = "go to " + rest.dropFirst().joined(separator: " ")
        guard case .desktop(.go)? = FastAction.parse(command)?.action.body else { return nil }
        return command
    }

    /// "label everything", "put the numbers up", "show me what I can
    /// click", "turn the labels off": the numbered-names overlay.
    private static func names(_ w: [String]) -> String? {
        if w.starts(with: ["what", "can", "i"]), w.count > 3, clickVerbs.union(roleOnlyClickVerbs).contains(w[3]),
           w.dropFirst(4).allSatisfy({ ["on", "here"].contains($0) }) {
            return "show names"
        }
        var rest = w
        var show: Bool?
        var verbSaid = false
        for (verb, shows) in nameVerbs where rest.starts(with: verb) {
            rest.removeFirst(verb.count)
            show = shows
            verbSaid = true
            break
        }
        if !verbSaid, let verb = rest.first, ["label", "number", "tag", "mark"].contains(verb) {
            let object = rest.dropFirst().joined(separator: " ")
            return markObjects.contains(object) ? "show names" : nil
        }
        rest.removeAll { ["me", "the", "all", "my"].contains($0) }
        if show == true, clickableObjects.contains(rest.joined(separator: " ")) { return "show names" }
        guard let noun = rest.first, nameNouns.contains(noun) else { return nil }
        let tail = rest.dropFirst().joined(separator: " ")
        switch (show, tail) {
        case (nil, "on"): show = true
        case (nil, "off"): show = false
        case (true, "on"), (true, "up"): break
        case (false, "off"), (false, "down"): break
        case (_?, let tail) where nameTails.contains(tail): break
        default: return nil
        }
        guard let show else { return nil }
        return show ? "show names" : "hide names"
    }

    /// "I can't find Notes", "locate Calculator", "what happened to Mail",
    /// "where'd Safari go": where a window or app went.
    private static func find(_ w: [String], isApp: (String) -> Bool) -> String? {
        var object: [String]?
        for frame in findFrames where w.starts(with: frame) { object = Array(w.dropFirst(frame.count)); break }
        if object == nil, w.first == "whered", w.last == "go", w.count > 2 { object = Array(w.dropFirst().dropLast()) }
        guard let object, !object.isEmpty else { return nil }
        let name = object.filter { !["my", "the", "window", "windows", "app"].contains($0) }.joined(separator: " ")
        guard !name.isEmpty, isApp(name) else { return nil }
        let command = "where is " + object.joined(separator: " ")
        guard case .locate? = FastAction.parse(command)?.action.body else { return nil }
        return command
    }

    /// "hit Save", "press the button labeled Send", "select the OK button":
    /// a click on a named control. "Click", "press" and "tap" already parse
    /// with a plain name, so only the label frames rewrite them. "Select",
    /// "choose" and "pick" need the control's role said out loud, so
    /// "select all" keeps its own meaning.
    private static func click(_ w: [String]) -> String? {
        guard let verb = w.first, clickVerbs.contains(verb) || roleOnlyClickVerbs.contains(verb) else { return nil }
        var rest = Array(w.dropFirst())
        if rest.first == "on" { rest.removeFirst() }
        if let first = rest.first, ["the", "a", "an"].contains(first) { rest.removeFirst() }
        var name: [String]?
        if let role = rest.first, controlRoles.contains(role) {
            for frame in labelFrames where rest.dropFirst().starts(with: frame) {
                name = Array(rest.dropFirst(1 + frame.count))
                break
            }
        }
        if name == nil, roleOnlyClickVerbs.contains(verb), rest.count > 1, let role = rest.last,
           controlRoles.contains(role) {
            name = Array(rest.dropLast())
        }
        if name == nil, ["hit", "push"].contains(verb) { name = rest }
        guard let name, !name.isEmpty else { return nil }
        let command = "click " + name.joined(separator: " ")
        guard case .clickNamed? = FastAction.parse(command)?.action.body else { return nil }
        return command
    }

    /// "get Safari open", "fire up Safari", "boot Calculator up", "I need
    /// Safari": a request to have an app open.
    private static func open(_ w: [String], isApp: (String) -> Bool) -> String? {
        var object: [String]?
        for verb in openVerbs where w.starts(with: verb) { object = Array(w.dropFirst(verb.count)); break }
        if object == nil, let verb = w.first, particleOpenVerbs.contains(verb), w.last == "up", w.count > 2 {
            object = Array(w.dropFirst().dropLast())
        }
        if object == nil, w.first == "get" {
            for state in openStates where w.count > state.count + 1 && Array(w.suffix(state.count)) == state {
                object = Array(w.dropFirst().dropLast(state.count))
                break
            }
        }
        guard let object, !object.isEmpty else { return nil }
        let name = object.joined(separator: " ")
        return isApp(name) ? "open " + name : nil
    }

    // MARK: - Words

    private static func words(_ text: String) -> [String] {
        var s = text.lowercased()
        s = s.replacingOccurrences(of: #"['’‘]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[.,!?;:"“”]+"#, with: " ", options: .regularExpression)
        return s.split(separator: " ").map(String.init)
    }

    /// Drops lead-ins and politeness that carry no command: "go ahead
    /// and", "I want to", "let's", "please", "for me".
    private static func strip(_ words: [String]) -> [String] {
        var w = words
        var changed = true
        while changed {
            changed = false
            for lead in leadIns where w.count > lead.count && w.starts(with: lead) {
                w.removeFirst(lead.count); changed = true; break
            }
            for tail in tails where w.count > tail.count && Array(w.suffix(tail.count)) == tail {
                w.removeLast(tail.count); changed = true; break
            }
        }
        return w
    }

    private static let leadIns: [[String]] = [
        "go ahead and", "i want you to", "i want to", "i wanna", "i would like to", "id like to",
        "i need you to", "i need to", "lets", "let us", "can we", "could we", "can you", "could you",
        "would you", "will you", "help me", "please", "just", "quickly", "hey jarvis", "jarvis", "now",
    ].map(split)
    private static let tails: [[String]] = [
        "for me", "please", "now", "right now", "real quick", "thanks", "thank you",
    ].map(split)
    private static let interrogatives: Set<String> = [
        "is", "are", "was", "were", "did", "does", "do", "should", "has", "have", "why", "how", "when", "who",
    ]
    private static let negations: Set<String> = [
        "dont", "never", "not", "wont", "didnt", "doesnt", "shouldnt", "cancel",
    ]

    private static let motionVerbs: Set<String> = [
        "go", "switch", "move", "jump", "hop", "head", "flip", "change", "get", "take", "bring", "send", "put",
    ]

    /// Verbs that show (true) or hide (false) the names; nil lets a
    /// trailing "on" or "off" decide ("turn the labels off").
    private static let nameVerbs: [([String], Bool?)] = {
        let verbs: [(String, Bool?)] = [
            ("show", true), ("display", true), ("turn on", true), ("switch on", true), ("put up", true),
            ("bring up", true), ("give me", true), ("put", true), ("turn", nil), ("switch", nil), ("enable", true),
            ("hide", false), ("clear", false), ("remove", false), ("turn off", false), ("switch off", false),
            ("take away", false), ("take down", false), ("get rid of", false), ("disable", false),
        ]
        return verbs.map { (split($0.0), $0.1) }.sorted { $0.0.count > $1.0.count }
    }()
    private static let nameNouns: Set<String> = ["names", "labels", "numbers", "hints", "tags"]
    private static let nameTails: Set<String> = [
        "", "on screen", "on the screen", "on everything", "for everything", "everywhere", "back",
    ]
    private static let markObjects: Set<String> = [
        "everything", "the buttons", "all the buttons", "the screen", "what i can click", "things",
    ]
    private static let clickableObjects: Set<String> = [
        "what i can click", "what i can click on", "whats clickable", "what is clickable",
        "everything i can click", "everything clickable", "clickable things", "clickable stuff",
    ]

    private static let findFrames: [[String]] = [
        "i cant find", "i cannot find", "i can not find", "find", "locate", "what happened to",
    ].map(split)

    private static let clickVerbs: Set<String> = ["click", "press", "tap", "hit", "push"]
    private static let roleOnlyClickVerbs: Set<String> = ["select", "choose", "pick"]
    private static let controlRoles: Set<String> = ["button", "link", "option", "checkbox", "tab", "icon"]
    private static let labelFrames: [[String]] = [
        "that says", "which says", "saying", "labeled", "labelled", "called", "named",
    ].map(split)

    private static let openVerbs: [[String]] = [
        "open up", "start up", "load up", "boot up", "fire up", "spin up", "pull up", "bring up",
        "launch", "start", "run", "load", "use", "get me", "i need", "i want", "id like", "i would like",
    ].map(split)
    private static let particleOpenVerbs: Set<String> = ["fire", "boot", "pull", "bring", "load", "spin", "start", "open"]
    private static let openStates: [[String]] = [
        "up and running", "started up", "open", "opened", "up", "going", "running", "started", "launched", "loaded",
    ].map(split)

    private static let screenNouns = [
        "screen", "display", "monitor", "this page", "the page", "this window", "the window", "this tab",
        "this button", "in front of me",
    ]
    private static let screenAsks = [
        "what", "whats", "who", "why", "how", "when", "where", "describe", "read", "summarize",
        "summarise", "summary", "explain", "tell me", "see", "look at", "check", "translate",
    ]
    private static let screenActions: Set<String> = [
        "lock", "record", "share", "turn", "take", "capture", "clear", "close", "mirror", "dim", "brighten",
        "make", "open", "switch", "go", "move", "click", "press", "type", "scroll", "hide",
    ]

    private static func split(_ phrase: String) -> [String] {
        phrase.split(separator: " ").map(String.init)
    }
}
