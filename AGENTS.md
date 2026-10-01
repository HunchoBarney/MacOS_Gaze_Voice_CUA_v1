# Working in Jarvis

Verify before you claim. Every claim ties to evidence the user can check — a
test run, a file:line, command output — proportional to the size of the claim.
Assume you're wrong until the evidence says otherwise. You may search the web
and papers for current truth; installed versions beat remembered ones.

## Commands

- `make setup` / `make test` / `make app` (release → `build/Jev Voice.app`)
- `swift test --filter <Suite>` for focused checks

## Tripwires — each exists because it caused real damage

- `development/` is gitignored but holds unique evidence and models — never
  treat as a disposable cache. Only `development/JevVoice/cua-source/` is
  tracked.
- `development/JevVoice/reference/` and the `~/Library/Caches/JevVoice` link
  are read-only shared inputs. Copy before modifying.
- The Cua Driver is pinned and hash-verified against
  `ThirdParty/Cua/source-manifest.json`. Upgrading is welcome — verify the new
  version's contracts against `ThirdParty/Cua/README.md` and rerun the checks;
  a silent swap breaks the app.
- Credentials live in Keychain; secrets never enter repo files. Bundle id:
  `com.chriswozniczek.jevvoice`.
- Live/desktop tests sit behind `JARVIS_*` flags and mutate macOS — run them
  through `scripts/with-desktop-lock.py`, one owner at a time. Simulated tests
  never prove physical Fn/microphone or packaged-app behavior.
- `codesign --verify --deep --strict` fails spuriously in this synced
  Documents checkout — verify on a copy outside it.
- Other agents share this folder: never stash/reset/clean; commit or push
  only when asked.
- Parallel work: `git worktree add`, then
  `python3 scripts/setup-workspace-development.py --source <main>/development/JevVoice`.
