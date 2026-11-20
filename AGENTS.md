# Working in Jarvis

Jarvis is a macOS menu-bar app: hold Fn (or speak hands-free), OpenAI
Realtime hears you, and Jev plus the embedded Cua driver act on the desktop.
Eye tracking runs locally in a bundled Electron tracker. Read
[ARCHITECTURE.md](ARCHITECTURE.md) for the map, [DECISIONS.md](DECISIONS.md)
for what is settled, and [RELEASE.md](RELEASE.md) before shipping a build.

## Commands

- `make test` — `swift test --parallel`, then the tracker typecheck and
  Vitest. This is what CI runs.
- `swift test --filter <Suite>` — a focused Swift check.
- `make release` — one signed build from source: `build/Jarvis.app`, a
  zip and its SHA-256. It is the default goal.
- `make install` — release, then copy to `~/jarvis-local/Jarvis.app`
  and verify the signature. It does not launch the app.
- `make local` — install, then quit any running copy and open the new one.
- `SIGN_IDENTITY=- make release` — ad-hoc signing, for CI or a machine
  without the local identity.

Prerequisites: macOS 26 with the macOS 26 SDK, Node, and pnpm through
Corepack. Run EyeTracking tests from `EyeTracking/`, where
`package.json` and `vite.config.ts` live.

## Rules

- Secrets live in Keychain only. Never put a key in a repository file, a log
  or a test fixture. Bundle id: `com.karanvirkang.jarvis`.
- The Cua driver and Codex runtime are pinned and hash-verified against
  `ThirdParty/Cua/source-manifest.json`. Upgrading is welcome: verify the
  new version against `ThirdParty/Cua/README.md` and rerun `make test`. A
  silent swap breaks the app.
- Live and desktop tests sit behind `JARVIS_LIVE_*` / `JARVIS_P4_REAL_APPS`
  flags and mutate macOS. Run them through `scripts/with-desktop-lock.py`,
  one owner at a time. Simulated tests never prove physical Fn, microphone
  or packaged-app behaviour.
- `codesign --verify --deep --strict` fails spuriously inside a synced
  `~/Documents` checkout (com.apple.provenance). Verify a copy outside it.
- `make test` runs each XCTest case in its own process, one per CPU core, and
  other worktrees test on the same Mac. Keep test state private: inject a
  `UserDefaults(suiteName:)` suite, temporary directory or port 0 rather
  than writing `UserDefaults.standard` or a fixed path.
- `development/` is local-only: `cua-source/` and the text layer
  (`*.json`/`*.md`/`*.txt`/`*.log`) are tracked; the rest is regenerable.
- Other agents may share this folder: never stash, reset or clean someone
  else's work, and stage commits by file name.
- Reuse existing code, platform APIs and maintained open source before
  writing a subsystem from scratch.

The old `.agent/` phase harness (PROGRAM, phases, acceptance, results) is
preserved in the `harness-archive-2026-11-19` tag.
