# Jarvis / Jev Voice — Empryo instructions

These are the project rules Empryo loads each turn. `AGENTS.md` is the cross-agent entry point with the commands and rules that matter. Use the Genome to locate code, read the implementation before editing, and use `navigate`/`genome_impact` for affected callers. Prefer the smallest change that fixes the demonstrated cause. Do not turn unrelated maintenance into migration work.

## Finish and prove the work

- Reproduce a reported defect before changing code. Run the same focused check before and after; record what changed and what remains unproven. Do not call a passing test proof of a physical microphone, Fn key, or desktop outcome.
- Use Empryo's `project` tool for available build and test commands; `make test` is the default regression suite and `make app` builds the signed local bundle. For a focused Swift class, use `swift test --filter ClassName`. Documentation-only edits need content/diff review, not a desktop test.
- Check the real user-facing path when the task warrants it, within the permissions and live-test constraints below. If the environment cannot exercise it, report the coverage gap instead of claiming success.
- Review the diff and report observed results. Commit, push, publish, or change installed software only when asked. Keep unrelated work and user changes intact.
- Use memory for user preferences, decisions and traps that the code cannot show; do not copy code structure into memory.

## Product boundaries

- `Sources/JevVoice` owns the macOS app, speech capture, UI and computer control; `Sources/JevVoiceCore` holds shared speech and model contracts. `EyeTracking/` is a separate trial. Respect existing module boundaries unless evidence calls for changing them.
- Live desktop, physical Fn/microphone and packaged-app acceptance remain unverified at release level; simulated tests never close those gates.
- Preserve Keychain credentials, preferences, app identities and the pinned Cua Driver. Read `ThirdParty/Cua/README.md` before changing its source or runtime. Do not auto-upgrade or replace the installed Driver.
- `development/JevVoice/cua-source/` is tracked; other `development/` assets are ignored but may be unique. Keep worktree-local source and generated files isolated. Treat `development/JevVoice/reference/` and the legacy `~/Library/Caches/JevVoice` link as read-only.

## Live checks

- Default tests must not silently turn on live hardware or model calls. Before enabling an opt-in `JARVIS_*` flag, read its test first; some tests launch apps, use paid services or interact with the desktop.
- Run live desktop checks under `python3 scripts/with-desktop-lock.py`, one desktop owner at a time, with disposable fixtures. Do not send messages, buy anything or delete personal content as a test. Physical microphone/Fn acceptance needs the user's participation.
- Keep recorded-audio, programmatic admission, simulated desktop and observed physical outcomes distinct in any evidence.

## Sources

- [Empryo project instructions](https://empryo.com/docs/context/prompt-system#project-instructions)
- [Empryo skill scopes](https://empryo.com/docs/tools/skills#scopes)
