# Jarvis / Jev Voice

A macOS menu-bar computer-control app with a floating voice capsule, Fn/Globe
hold-to-talk, an OpenAI Realtime voice lane, Cua Driver, Jev decisions, and
persistent delegatable agents. The application bundle is still named
**Jev Voice.app**.

Architecture in one breath: one embedded Cua daemon serves every consumer;
voice tasks and agents use the shared `TaskLoop` through `DriveLoop`,
gated by one consent choke point (`CuaPolicy` — standing
grant plus a code deny list the grant never bypasses). Agents reach the
loop through `JevVoice --mcp-stdio --agent <slug>`, an MCP server mode of
the same binary.

**Status:** this source tree contains local-first, turn-owned speech,
direct native insertion and the shared action loop. Full current-artifact
Fn/pill qualification and the later general/browser/script/replay/eyes/
packaging work remain open. The installed daily app may be a different
candidate; source checks do not establish packaged or physical success.

The current shipping sequence and next candidate are in
[SHIP-PLAN](.agent/SHIP-PLAN.md). Development is
[open-source-first](.agent/REUSE.md); use existing code, platform APIs and
maintained FOSS before implementing a subsystem from scratch.

The planned model policy retains Jev for semantic decisions and Cua/native
execution, with GPT-6.1 Terra API recovery when needed. Direct operations
and ordinary dictation avoid an extra model call. The
[competitive protocol](.agent/COMPETITIVE.md) targets Wispr Flow dictation
quality and category-level speed/correctness leadership; those comparisons
and performance goals are not yet measured product claims.

## Start developing

Requires macOS 26+, Xcode with the macOS 26 SDK, and command-line tools selected
with `xcode-select`. The Swift package pins FluidAudio 0.17.5 for local
speech/TTS; consult `Package.swift` before changing that dependency.

```sh
make setup       # check the local toolchain; no credentials or downloads
make test        # CI lane: Swift + P3 evidence, tracker typecheck/Vitest, tooling
make local       # daily driver: build → sign → install to ~/jarvis-local,
                 # relaunch, then wait for the tracker API's /ready
make run         # alias for `make local`
make app         # release build → build/Jev Voice.app, signed
make bundle-tracker  # stage the tracker payload into the app (strict)
make install-tracker # write the tracker to app-support as real files
make check-tracker   # report which tracker path a staged app resolves
make dist        # package the bundle as a zip
```

`make test` and `make local` use Node (CI: 24.11.0) and Corepack to
install the tracker dependencies pinned by the pnpm lockfile. Source tests
don't download models or qualify a signed app. `SKIP_TRACKER_DEPS=1`
skips tracker preparation only: `make local` still launches the app and
requires HTTP 200 from the tracker's `/ready` endpoint.

Computer control requires the exact pinned Cua runtime and compatible
SDK/source contracts; an arbitrary installed driver is not interchangeable.
The retired perception extension is not a setup prerequisite. Development
staging may omit the tracker; release qualification requires the strict
complete bundle. See [Cua integration](ThirdParty/Cua/README.md).

The host prefers the launcher in `Contents/Resources/EyeTracker`. Without
it, the host tries `JARVIS_EYE_TRACKER_DIR`, a sibling `EyeTracking/`
checkout, then `~/Library/Application Support/JevVoice/EyeTracking`
(`make local` links the checkout there; `make install-tracker` writes
real files). Release validation accepts only the bundled payload.
`make stage` bundles the tracker when the checkout can produce a complete
payload (built `dist/` + `node_modules`), warns and skips otherwise
(`SKIP_TRACKER_BUNDLE=1` bypasses);
`make bundle-tracker` is the strict verified path and `make check-tracker`
reports which resolution a staged app would use. Boot output lands in
`~/Library/Application Support/JevVoice/tracker.log`.

For P3 replay, restore the private index and audio under the ignored
`.context/c1-local/p3-audio/`, or point `JARVIS_P3_RECORDINGS_ROOT` at
an authorized external directory. The wrapper also accepts
`--recordings-root PATH`. Replay requires the matching recorded release
build; it's not a physical mic check. The interactive recorder still writes
to its ignored phase-owned directory. Keep recordings and replay reports private.

For signed candidate and rollback identities, see the
[retention inventory](.agent/RETENTION.md).

## Use the app

Open the waveform menu-bar menu → Settings. Voice needs an **OpenAI API key**
(`sk-…`, or `OPENAI_API_KEY` in the environment) — ChatGPT sign-in cannot start
realtime sessions. Configure the Jev (TypeSafe) key in Commands, choose the
microphone in Voice, and follow the macOS permission prompts (microphone,
camera for eye tracking, screen recording, accessibility). Saved keys remain
in Keychain; do not put them in repository files.

When Voice settings reports Ready, the microphone is already running. Idle audio is
discarded; the macOS microphone indicator stays active. Hold Fn/Globe, speak, and
release to finalize. A fresh realtime session receives only audio admitted
during the hold. Cold startup or recovery can still require preparation; check
readiness. Local partials are displayed in the pill; final admission owns
the dispatch decision. Reliable behavior across the full acceptance matrix
remains unfinished. Escape cancels the voice interaction;
task Stop and Stop All controls handle task cancellation. Expand the capsule for
Activity and diagnostics. Set the macOS Globe-key action to Do Nothing if it
opens emoji or system Dictation instead.

Local speech produces the transcript of record. Realtime response creation
is gated by local admission/miss handling, and automatic per-Fn screenshots
to the realtime lane have been removed. Visual deciders can request
task-scoped captures when required. Eye inference remains on-device.
Configured remote capabilities can receive admitted task content and
application context; local transcription does not make the complete product
offline. Keys stay in Keychain. Do not assume only app names leave the device.

## Find your way

- [.agent/PROGRAM.md](.agent/PROGRAM.md): the v1 program — hero jobs, phase DAG, release bars (source of truth for "done").
- [.agent/SHIP-PLAN.md](.agent/SHIP-PLAN.md): current candidate order, remaining phases, evidence and rollback.
- [.agent/REUSE.md](.agent/REUSE.md): open-source-first policy, license/version research and component decisions.
- [Agent rules](AGENTS.md): harness entry point — commands, gates, pinned Driver, workspace and live-test rules.
- [Cua integration](ThirdParty/Cua/README.md): the pinned Driver contract.
- [Eye tracking trial](EyeTracking/README.md): standalone gaze overlay and its local macOS workflow.

This project originated from [jev-voice-control](https://github.com/chris-wozniczek/jev-voice-control).
FluidVoice attribution is in [ThirdParty/FluidVoice](ThirdParty/FluidVoice/NOTICE.md).
The retained Homebrew cask points at the upstream distribution until this
repository publishes a tagged release. That workflow updates the cask URL
and checksum to the archive it published. Use `make local` for development.
