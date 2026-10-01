# Working in Jarvis

Jarvis ("Jev Voice") is a macOS menu-bar computer-control app: Fn/Globe
hold-to-talk → Apple SpeechAnalyzer → `ContinuousIntentCoordinator` → Jev
semantic decision → `CuaVoiceRuntime` → `CuaTaskAgent` → pinned Cua Driver over
stdio MCP. `CuaDialogueState` is the bounded in-memory coordination layer
(intents, attempts, pending questions, verified facts). `EMPRYO.md` is the
Empryo-native project guide alongside this file.

## Commands

- `make setup` — toolchain check (no credentials/downloads)
- `make test` — full suite: `swift test` plus `python3 -B -m unittest discover -s Tests/Tooling`
- `swift test --filter <Suite>` — focused suites
- `make app` — release build → `build/Jev Voice.app`, ad-hoc signed

SwiftPM discovers the grouped source/test directories; keep module boundaries.

## Rules that matter

- **Pinned Driver.** Computer control requires the exact pinned Cua Driver
  Local — see `ThirdParty/Cua/README.md` before changing or rebuilding it.
  Never auto-upgrade the pinned runtime. Stock Cua is not interchangeable.
- **Credentials and identity.** Jev key lives in Keychain; bundle id is
  `com.chriswozniczek.jevvoice`. Don't touch credentials, preferences, app
  identity or dependency pins. Never put secrets in repo files.
- **Ad-hoc signing caveat.** `codesign --verify --deep --strict` fails
  spuriously inside this synced Documents checkout (the file provider restores
  FinderInfo on generated bundles). Verify signatures on a copy outside the
  synced directory.
- **Live tests are opt-in and can mutate macOS.** They're behind `JARVIS_*`
  env flags; run them through `scripts/with-desktop-lock.py`, one desktop owner
  at a time. Never claim physical Fn/microphone or packaged-app acceptance from
  simulated tests.
- **Development assets.** `development/JevVoice/cua-source/` is the only
  tracked part; the rest of `development/` is ignored but holds unique
  evidence/models — not a disposable cache. `development/JevVoice/reference/`
  is read-only shared input; never write through its links or the legacy
  `~/Library/Caches/JevVoice` path. Worktrees run
  `scripts/setup-workspace-development.py` (Conductor does it automatically;
  manual worktrees pass `--source`).

## Working style

- Reproduce bugs before fixing; prove the same user-facing behavior before and
  after where safely checkable.
- Ground diagnoses in code, logs, or observed behavior — label hypotheses until
  supported. Verify API behavior against the installed version.
- Small, responsibility-focused changes; follow existing conventions; no new
  frameworks/abstractions without current need. Fix shared causes, not
  app-specific workarounds.
- Other agents share this folder. Never stash/reset/clean; add files by name.
  Commit or publish only when the owner asks.
- Report what changed, what was actually verified, and what remains unverified.
