# Working in Jarvis

Jarvis is a macOS menu-bar app and a hands-free personal agent: say its
wake phrase (heard on the Mac by Vosk) and talk. OpenAI voice converses
(gpt-realtime-2.1 today; gpt-live-1.1 behind `voice.live` next), and every
action runs on the Mac through FastLane, Jev and the embedded Cua driver,
under consent. Fn and push-to-talk are being removed; don't build on
them. Eye tracking is optional, off by default, and runs locally in a
bundled Electron tracker. Read [ARCHITECTURE.md](ARCHITECTURE.md) for the
map, [DECISIONS.md](DECISIONS.md) for what is settled, and
[RELEASE.md](RELEASE.md) before shipping a build.

## Commands

- `make test` — `swift test --parallel`, then the tracker typecheck and
  Vitest. This is what CI runs.
- `swift test --filter <Suite>` — a focused Swift check.
- `scripts/lane-test.sh [command]` — run `make test`, or any command, in the
  crew's shared warm build checkout. See [TESTING.md](TESTING.md).
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
  one owner at a time. Simulated tests never prove physical microphone,
  wake-word, full-duplex or packaged-app behaviour; name those as owner
  physical checks ([TESTING.md](TESTING.md)).
- Unit tests never reach the real microphone: under XCTest it reads as
  refused and never opens, whatever the launching app was granted. A live
  test that needs it also sets `JARVIS_LIVE_MIC=1`.
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
