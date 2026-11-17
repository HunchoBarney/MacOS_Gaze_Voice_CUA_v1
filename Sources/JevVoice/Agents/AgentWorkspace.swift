import Foundation

/// Filesystem scaffold for one CompanionAgent — Clicky parity:
/// ~/Library/Application Support/JevVoice/Agents/<slug>/
///   output/     deliverables only
///   tmp/        scratch
///   codex-home/ isolated CODEX_HOME (threads, auth, config.toml)
///   AGENTS.md   persona + Standing preferences + Notes
public enum AgentWorkspace {
    public static func root(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JevVoice/Agents", isDirectory: true)
    }

    public static func workspaceURL(slug: String, root: URL) -> URL {
        root.appendingPathComponent(slug, isDirectory: true)
    }

    /// Isolated CODEX_HOME lives under the workspace so a Clicky folder is
    /// self-contained — move or delete the folder and the agent goes with it.
    public static func codexHomeURL(workspace: URL) -> URL {
        workspace.appendingPathComponent("codex-home", isDirectory: true)
    }

    /// Creates the folder layout and a first AGENTS.md. Idempotent: existing
    /// AGENTS.md (with the agent's own curated Notes) is never overwritten.
    @discardableResult
    public static func prepare(slug: String, name: String, role: String,
                               description: String,
                               root: URL = AgentWorkspace.root(),
                               fileManager: FileManager = .default) throws -> URL {
        let workspace = workspaceURL(slug: slug, root: root)
        for directory in [workspace,
                          workspace.appendingPathComponent("output", isDirectory: true),
                          workspace.appendingPathComponent("tmp", isDirectory: true),
                          codexHomeURL(workspace: workspace)] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let agentsMD = workspace.appendingPathComponent("AGENTS.md")
        if !fileManager.fileExists(atPath: agentsMD.path) {
            try template(name: name, role: role, description: description)
                .write(to: agentsMD, atomically: true, encoding: .utf8)
        }
        return workspace
    }

    /// Persona header + the two maintenance sections, mirroring the template
    /// embedded in the Clicky binary (mirror/07-clickys.md).
    public static func template(name: String, role: String, description: String) -> String {
        """
        # \(name)

        You are \(name), the user's \(role). \(description)
        Speak in a consistent voice, first person. Your folder is your home:
        `output/` is for finished deliverables only and `tmp/` is scratch.
        Write files directly and report what you did — the user's request is
        the approval. Confirm only before deletes, archives, overwrites,
        sending email (always draft first), or spending money. Never store
        secrets, passwords, or tokens in this folder.
        To control the Mac, use the `jev-drive` MCP tools — `drive_until`
        runs the task and reports an honest outcome, `suggest_action`
        previews the next step without acting. Never `open`, AppleScript,
        or osascript. If a drive call says it needs the computer-use
        grant, tell the user to enable it in Jev Voice settings.

        ## Standing preferences
        (Durable instructions the user has given you. Keep each to one line.)

        ## Notes
        (Your working memory. After any turn where you learn something durable
        about this job — accounts, structures, the user's taste, decisions
        made, ongoing threads of work — update this section: add the fact,
        dated, and prune anything stale or superseded. Keep it curated and
        short; this file is read before every turn. Never store secrets,
        passwords, or tokens here.)
        """
    }

    /// "Inbox Desk!" → "inbox-desk". Falls back to "agent-<suffix>" so a
    /// workspace slug is always filesystem-safe and non-empty.
    public static func slugify(_ name: String) -> String {
        var slug = ""
        var lastWasDash = true
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 48 { slug = String(slug.prefix(48)) }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "agent" }
        return slug
    }
}
