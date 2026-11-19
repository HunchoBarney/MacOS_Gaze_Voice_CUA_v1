import Foundation

/// The typed-payload deny corpus — the second half of the audit fix.
///
/// `deniedPhrase(in:)` reads element *labels*; `deniedInTypedPayload`
/// reads what a `type_text`/`set_value` dispatch would actually type.
/// Before this existed, `type 'rm -rf ~/'` + `press return` ran under
/// the standing grant with no scan at all.
///
/// The shape is a command line, not a phrase: the payload is split into
/// shell segments at `; | &` newlines, backticks and parens, and the
/// dangerous tokens only count in COMMAND POSITION — the first token of
/// a segment, or right after a separator. That position rule is what
/// keeps "never run rm -rf casually" a confirm while `rm -rf ~/` typed
/// into a terminal refuses: prose about a command can't execute, a
/// payload that IS the command can. Anything whose spelling can't be
/// prose (`:(){`, `| sh`, `> ~/…`, `/dev/tcp`) denies wherever it lands.
extension CuaPolicy {

    /// A human-readable reason for the refusal message, or nil when the
    /// payload carries no command-shaped danger. Callers: `decide` runs
    /// this over every string arg; explicit-consent lanes (fast-lane
    /// `type`, gaze typing, browser fill) should call it on the payload
    /// itself before dispatching — the element corpus can't see it.
    static func deniedInTypedPayload(_ text: String) -> String? {
        let raw = text.lowercased()
        if let hit = deniedRawShape(in: raw) { return hit }
        if pipesIntoShell(raw) { return "a pipe into a shell or interpreter" }
        if redirectsToSensitivePath(raw) { return "a redirect into a sensitive path" }
        for tokens in commandSegments(of: raw) {
            if let hit = deniedCommand(tokens) { return hit }
        }
        return nil
    }

    // MARK: Raw shapes — separators and paths, where normalization can't help

    /// Substrings that are dangerous wherever they appear — their shapes
    /// are never prose.
    private static let deniedRawNeedles: [(needle: String, reason: String)] = [
        (":(){", "a fork bomb"),
        ("/dev/tcp", "a reverse shell device"),
        ("administrator privileges", "an administrator-privilege script"),
        ("id_rsa", "SSH private-key material"),
        ("id_ed25519", "SSH private-key material"),
        ("id_ecdsa", "private-key material"),
        ("id_dsa", "private-key material"),
        (".aws/credentials", "cloud credentials"),
        (".kube/config", "cluster credentials"),
        // Dot-targeted git discards — the "." vanishes under tokenization,
        // so the raw spelling is what the check holds.
        ("checkout .", "git checkout ."),
        ("checkout --", "git checkout --force"),
        ("restore .", "git restore ."),
        ("restore --", "git restore --force"),
        ("history -c", "a shell-history wipe"),
        // curl/wget output flags aimed at sensitive roots.
        ("-o ~", "a download into a home file"),
        ("-o /etc", "a download into /etc"),
        ("-o /usr", "a download into /usr"),
        ("-o /bin", "a download into /bin"),
        ("--output ~", "a download into a home file"),
        ("--output /etc", "a download into /etc"),
        ("-d @~", "a home-file upload"),
        ("--data @~", "a home-file upload"),
    ]

    /// Pairs that must co-occur — either alone is ordinary text.
    private static let deniedRawPairs: [(String, String, reason: String)] = [
        ("system events", "keystroke", "GUI-scripting keystroke injection"),
        ("keychain", "dump", "a keychain dump"),
        ("keychain", "export", "a keychain export"),
    ]

    private static func deniedRawShape(in raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("javascript:") || trimmed.hasPrefix("vbscript:")
            || trimmed.hasPrefix("data:text/") {
            return "an executable URL scheme"
        }
        for (needle, reason) in deniedRawNeedles where raw.contains(needle) {
            return reason
        }
        for (a, b, reason) in deniedRawPairs
        where raw.contains(a) && raw.contains(b) {
            return reason
        }
        // `$(curl …)` / `` `curl` `` — a fetch inside command substitution.
        for fetcher in ["curl", "wget", "python", "osascript"] {
            if raw.contains("$(\(fetcher)") || raw.contains("`\(fetcher)") {
                return "a fetch inside command substitution"
            }
        }
        return nil
    }

    /// `… | sh`, `… | sudo bash`, `…|python3` — the sink side of a pipe.
    /// `||` is logical-or, not a pipe, and skips cleanly.
    private static let pipeShellSinks: Set<String> = [
        "sh", "bash", "zsh", "dash", "ash", "ksh", "fish",
        "python", "python3", "perl", "ruby", "node", "php", "osascript",
    ]

    private static func pipesIntoShell(_ raw: String) -> Bool {
        var i = raw.startIndex
        while let found = raw[i...].firstIndex(of: "|") {
            var j = raw.index(after: found)
            if j < raw.endIndex, raw[j] == "|" { i = raw.index(after: j); continue }
            while j < raw.endIndex, raw[j] == " " || raw[j] == "\t" { j = raw.index(after: j) }
            var rest = Substring(raw[j...])
            if rest.hasPrefix("sudo ") { rest = rest.dropFirst(5) }
            let token = rest.prefix(while: { $0.isLetter || $0.isNumber })
            if pipeShellSinks.contains(String(token)) { return true }
            i = raw.index(after: found)
        }
        return false
    }

    /// `> ~/…`, `>> /etc/hosts`, `> $HOME/x` — a redirect whose target is
    /// a sensitive root. Arrows (`->`, `=>`, `<>`) are not redirects.
    private static let sensitiveRedirectRoots = [
        "~", "$home", "/etc", "/system", "/usr", "/bin/", "/sbin",
        "/var/", "/dev/", "/private", ".ssh",
    ]

    private static func redirectsToSensitivePath(_ raw: String) -> Bool {
        var i = raw.startIndex
        while let found = raw[i...].firstIndex(of: ">") {
            if found > raw.startIndex {
                let prev = raw[raw.index(before: found)]
                if prev == "-" || prev == "=" || prev == "<" {
                    i = raw.index(after: found); continue
                }
            }
            var j = raw.index(after: found)
            while j < raw.endIndex, raw[j] == ">" { j = raw.index(after: j) }
            while j < raw.endIndex, raw[j] == " " || raw[j] == "\t" { j = raw.index(after: j) }
            if j < raw.endIndex, raw[j] == "=" { i = j; continue }  // ">=" is a compare
            let target = raw[j...]
            if sensitiveRedirectRoots.contains(where: { target.hasPrefix($0) }) {
                return true
            }
            i = j > found ? j : raw.index(after: found)
        }
        return false
    }

    // MARK: Command segments — position is what makes a token a command

    /// The payload split at shell separators into token lists; a token is
    /// a command when it leads one of these segments.
    private static let shellSeparators = CharacterSet(charactersIn: ";|&\n\r`()<>{}")

    private static func commandSegments(of raw: String) -> [[String]] {
        raw.components(separatedBy: shellSeparators)
            .map { seg in
                normalize(seg).split(separator: " ").map(String.init)
            }
            .filter { !$0.isEmpty }
    }

    /// Command heads that refuse outright: privilege escalation, raw
    /// interpreters (a typed `python3 -c …` launders the denied
    /// `execute_script` tool through the keyboard), permanent delete,
    /// power and disk commands, persistence mechanisms, remote sessions,
    /// and environment dumps (env vars hold credentials).
    private static let deniedCommandHeads: Set<String> = [
        "sudo", "doas", "su", "passwd",
        "sh", "bash", "zsh", "dash", "ash", "ksh", "fish",
        "python", "python3", "perl", "ruby", "node", "php", "irb",
        "osascript", "eval", "ssh",
        "rm", "srm", "killall", "pkill",
        "shutdown", "reboot", "halt", "poweroff",
        "mkfs", "mke2fs", "newfs", "newfs_hfs", "fdisk",
        "installer", "profiles", "crontab",
        "env", "printenv",
    ]

    /// Heads that wrap another command — `xargs rm`, `nohup sudo …` —
    /// denying when the rest of the segment still names one.
    private static let commandWrappers: Set<String> = [
        "nohup", "nice", "ionice", "timeout", "xargs", "command",
        "exec", "builtin", "stdbuf", "caffeinate",
    ]

    /// Verbs that exfiltrate when their argument is a credential path:
    /// `cat ~/.ssh/id_rsa`, `tar czf - ~/.gnupg`, `scp ~/.aws/…`.
    private static let credentialReadVerbs: Set<String> = [
        "cat", "cp", "scp", "rsync", "tar", "zip", "base64", "openssl",
        "gpg", "less", "more", "head", "tail", "xxd", "strings", "dd",
    ]
    private static let credentialTargets: Set<String> = [
        "ssh", "gnupg", "keychain", "kubeconfig", "netrc",
    ]

    /// Recursive-flag spellings after normalization: `-R`, `-Rf`, `-fr`,
    /// `--recursive`.
    private static let recursiveFlags: Set<String> = ["r", "rf", "fr", "recursive"]

    /// One token list, first token in command position. Returns the
    /// refusal's reason.
    private static func deniedCommand(_ tokens: [String]) -> String? {
        guard let head = tokens.first else { return nil }
        let rest = Set(tokens.dropFirst())

        if deniedCommandHeads.contains(head) { return "'\(head)'" }
        if commandWrappers.contains(head),
           rest.contains(where: { deniedCommandHeads.contains($0) || argumentSensitiveHeads.contains($0) }) {
            return "'\(head)' wrapping a denied command"
        }
        if let hit = deniedArgs(head: head, rest: rest) { return hit }

        // A read/copy verb aimed at credential material.
        if credentialReadVerbs.contains(head) {
            if rest.contains(where: credentialTargets.contains) {
                return "a credential-file read"
            }
            if rest.contains("aws") && (rest.contains("credentials") || rest.contains("config")) {
                return "cloud credentials"
            }
            if rest.contains("kube") && rest.contains("config") {
                return "cluster credentials"
            }
            if rest.contains("docker") && rest.contains("config") {
                return "registry credentials"
            }
            if rest.contains("npm") && rest.contains("token") {
                return "an npm token"
            }
        }
        return nil
    }

    /// Heads whose danger is in their arguments, keyed for the wrapper
    /// check — keep in sync with `deniedArgs(head:rest:)`'s cases.
    private static let argumentSensitiveHeads: Set<String> = [
        "dd", "chmod", "chown", "kill", "git", "gh", "security",
        "diskutil", "find", "xattr", "spctl", "fdesetup", "tccutil",
        "dscl", "tmutil", "defaults", "launchctl", "nc", "ncat",
        "netcat", "socat", "tee", "sqlite3", "ifconfig", "pfctl",
        "socketfilterfw",
    ]

    /// Pair rules: the head is benign alone, the arguments decide.
    /// Post-normalization a `-flag` is a bare token, so `-f` and
    /// `--force` both land as the same check.
    private static func deniedArgs(head: String, rest: Set<String>) -> String? {
        switch head {
        case "dd":
            // `dd of=` — a bare `dd` does nothing; writing a device does.
            return rest.contains("of") ? "a dd device write" : nil
        case "chmod", "chown":
            return rest.contains(where: recursiveFlags.contains)
                ? "a recursive \(head)" : nil
        case "kill":
            return rest.contains("9") || rest.contains("kill") ? "kill -9" : nil
        case "git":
            return deniedGit(rest)
        case "gh":
            return rest.contains("delete") || rest.contains("remove")
                ? "a gh delete" : nil
        case "security":
            // The keychain CLI: find-*-password, dump-keychain, export.
            if rest.contains("dump") || rest.contains("export")
                || rest.contains("delete") || rest.contains("unlock")
                || (rest.contains("find") && rest.contains("password")) {
                return "a keychain access"
            }
            return nil
        case "diskutil":
            return rest.contains(where: {
                $0.hasPrefix("erase") || $0.hasPrefix("delete")
                    || $0.hasPrefix("partition") || $0.hasPrefix("unformat")
                    || $0 == "reformat" || $0 == "secureerase" || $0 == "restore"
            }) ? "a disk erase" : nil
        case "find":
            // `find … -delete` — the recursive-delete footgun.
            return rest.contains("delete") ? "a find -delete" : nil
        case "xattr":
            // `xattr -d com.apple.quarantine` — the Gatekeeper bypass.
            return rest.contains("quarantine") ? "a quarantine strip" : nil
        case "spctl":
            return rest.contains("disable") || rest.contains("master")
                ? "a Gatekeeper change" : nil
        case "fdesetup":
            return rest.contains("disable") ? "a FileVault disable" : nil
        case "tccutil":
            return rest.contains("reset") ? "a privacy-database reset" : nil
        case "dscl":
            return rest.contains("delete") || rest.contains("passwd")
                || rest.contains("create") ? "a directory-service write" : nil
        case "tmutil":
            return rest.contains("delete") || rest.contains("thinlocalsnapshots")
                ? "a backup delete" : nil
        case "defaults":
            return rest.contains("delete") ? "a defaults delete" : nil
        case "launchctl":
            return rest.contains(where: {
                ["unload", "bootout", "remove", "disable"].contains($0)
            }) ? "a service unload" : nil
        case "nc", "ncat", "netcat", "socat":
            return rest.contains(where: {
                ["l", "e", "c", "exec", "listen"].contains($0)
            }) ? "a netcat listener" : nil
        case "tee":
            return rest.contains(where: {
                ["etc", "sudoers", "ssh", "hosts", "crontab"].contains($0)
            }) ? "a tee into a system path" : nil
        case "sqlite3":
            return rest.contains("tcc") ? "the TCC permissions database" : nil
        case "ifconfig":
            return rest.contains("down") || rest.contains("delete")
                ? "an interface change" : nil
        case "pfctl":
            return rest.contains("d") || rest.contains("disable")
                ? "a firewall disable" : nil
        case "socketfilterfw":
            return rest.contains("off") || rest.contains("disable")
                ? "a firewall disable" : nil
        default:
            return nil
        }
    }

    /// git gets its own rule — the dangerous forms are verb+flag pairs:
    /// `push --force`, `reset --hard`, `clean -fdx`, `stash drop`.
    private static func deniedGit(_ rest: Set<String>) -> String? {
        if rest.contains("push") {
            if rest.contains("force") || rest.contains("f") {
                return "a git force push"
            }
            if rest.contains("delete") || rest.contains("d") {
                return "a git push --delete"
            }
        }
        if rest.contains("reset") && rest.contains("hard") {
            return "git reset --hard"
        }
        if rest.contains("clean"),
           rest.contains(where: { ["f", "d", "x", "fd", "fdx", "ff", "ffd"].contains($0) }) {
            return "git clean"
        }
        if rest.contains("checkout") || rest.contains("restore"),
           rest.contains("f") || rest.contains("force") {
            return "a git checkout --force"
        }
        if rest.contains("stash"),
           rest.contains("drop") || rest.contains("clear") {
            return "a git stash drop"
        }
        if rest.contains("branch") && rest.contains("d") {
            return "a git branch delete"
        }
        if rest.contains("reflog") && rest.contains("expire") {
            return "a git reflog expire"
        }
        if rest.contains("gc") && rest.contains("prune") {
            return "a git gc --prune"
        }
        if rest.contains("worktree") && rest.contains("remove") {
            return "a git worktree remove"
        }
        if rest.contains("tag") && rest.contains("d") {
            return "a git tag delete"
        }
        return nil
    }
}
