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

**Status:** C1 R10 implements OpenAI Realtime voice, direct native insertion
and the shared action loop. The signed candidate passed source and artifact
review. Physical hands-free and Fn/pill checks, latency/accuracy qualification
and C1 acceptance remain open. The signed candidate is separate from the
daily app; source and signature checks don't prove live operation.

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
with `xcode-select`. The Swift package pins FluidAudio 0.17.5 for explicit
local speech diagnostics; local speech models aren't required for normal
voice startup. Consult `Package.swift` before changing that dependency.

```sh
make setup       # check the local toolchain; no credentials or downloads
make tracker-deps # prepare tracker dependencies and assets; do not launch
scripts/verification-lane.sh eyes  # tracker typecheck and tests
scripts/verification-lane.sh all   # default serialized source checks

# App staging and installation are separate from checkout setup:
make local       # daily driver: build → sign → install to ~/jarvis-local,
                 # relaunch, then wait for the tracker API's /ready
make run         # alias for `make local`
make app         # sign build/Jev Voice.app in place; not for synced checkouts
make bundle-tracker  # stage the tracker payload into the app (strict)
make install-tracker # write the tracker to app-support as real files
make check-tracker   # report which tracker path a staged app resolves
make dist        # package the bundle as a zip
```

`make tracker-deps` requires Node 22.12+ and Corepack for the pinned pnpm
version in `EyeTracking/package.json`. It installs missing packages from
the frozen lockfile and runs the installed package's official Electron
42.4.1 installer, even when
`node_modules` already exists: the package can be present without its
native binary. It then uses the existing camera-permission patch helper.
`make local` runs this same setup; `SKIP_TRACKER_DEPS=1` skips it when
the tracker isn't wanted.

Fresh Make packages omit the local Silero conversation segmenter; normal voice
uses Realtime turn detection. For a local diagnostic package, use
`make stage JEV_SPEECH_PACKAGE=diagnostic STAGE_APP="/path/to/fresh/Jev Voice.app"`.
This checks or provisions the pinned model, license and model card without
changing the speech provider. `JEV_CONVERSATION_VAD_SOURCE` can point to a
local copy of the pinned resource. Use a separate destination for each
profile: Realtime staging refuses an existing ConversationVAD rather than
deleting it. Historical direct bundling/signing keeps its original behavior.

Computer control requires the exact pinned Cua runtime and compatible
SDK/source contracts; an arbitrary installed driver is not interchangeable.
The retired perception extension is not a setup prerequisite. Development
staging may omit the tracker; release qualification requires the strict
complete bundle. See [Cua integration](ThirdParty/Cua/README.md).

Eye tracking resolves in order: `JARVIS_EYE_TRACKER_DIR`, an `EyeTracking/`
sibling of the bundle, `~/Library/Application Support/JevVoice/EyeTracking`
(`make local` symlinks this repo there; `make install-tracker` writes real
files instead — the no-checkout path), or a payload bundled at
`Contents/Resources/EyeTracker` (probed via its `EyeTracking` alias).
`make stage` bundles the tracker when the checkout can produce a complete
payload (built `dist/` + `node_modules`), warns and skips otherwise
(`SKIP_TRACKER_BUNDLE=1` bypasses);
`make bundle-tracker` is the strict verified path and `make check-tracker`
reports which resolution a staged app would use. Boot output lands in
`~/Library/Application Support/JevVoice/tracker.log`.

### Keep source and signed bundles separate

Source, checkout-local build inputs and private archives can live in this
folder. A signed `.app` needs a non-synced staging path: Finder/file-provider
metadata in synced Documents can make strict macOS signature verification fail
on an unpacked copy. When this checkout has the ignored R10 archive, verify
the extracted app outside Documents without re-signing or installing it:

```sh
stage="$(mktemp -d /tmp/jev-r10.XXXXXX)" &&
ditto -x -k .context/c1-local/Jev-Voice-C1-R10-signed.zip "$stage" &&
  codesign --verify --deep --strict "$stage/Jev Voice.app"
```

Keep the archive private. App Support, macOS permissions and Keychain are
per-user runtime state, not source assets or part of the archive setup.

### Optional verification inputs

`scripts/verification-lane.sh p3-current-replay` uses a private recordings
index and audio under the checkout's ignored `.context/c1-local/p3-audio`.
A fresh clone doesn't include them. If you have authorized local recordings
elsewhere, use `python3 scripts/verify-p3.py replay --recordings-root PATH`.
Replay also requires the matching release build and its recorded source
binding (`.agent/results/P3/build.json`). It tests the local speech adapter,
not live Realtime or physical input; keep input and replay output private.
Other opt-in Swift diagnostics
and the holdout recorder still use the ignored `.agent/results/P3/audio`
path; replay setup doesn't populate or write there.

The experimental `p4-vision-driver-045-*` modes need a separate Cua source
checkout inside the ignored `.context/p4-vision/cua-upstream-0.45.4`.
They block before building unless Git HEAD is
`d96e1bc359b2cc638c7a406aad01a7276b1b416f` and the Cargo workspace is
version 0.45.4.
This is not a normal setup dependency. The older prototype-only
`p4-vision-driver-{capture,contract,macos,build}` modes are blocked
because their exact patched source isn't available here. Neither suite
can substitute the vendored snapshot for the shipped Cua 0.38 runtime.

## Use the app

Open the waveform menu-bar menu → Settings. Voice needs an **OpenAI API key**
(`sk-…`, or `OPENAI_API_KEY` in the environment) — ChatGPT sign-in cannot start
realtime sessions. Configure the Jev (TypeSafe) key in Commands, choose the
microphone in Voice, and follow the macOS permission prompts (microphone,
camera for eye tracking, screen recording, accessibility). Saved keys remain
in Keychain; do not put them in repository files.

Hands-free listening is on by default; pause or off preferences persist.
Normal readiness needs a healthy microphone and a confirmed Realtime
connection. Startup can wait on a macOS Keychain or permission prompt;
a running process alone doesn't mean voice is ready. Realtime detects
hands-free turns; hold and release Fn/Globe for an optional manual turn.
The matching committed input's final transcript controls admission, not
partials. Escape cancels the voice interaction;
task Stop and Stop All controls handle task cancellation. Expand the capsule for
Activity and diagnostics. Set the macOS Globe-key action to Do Nothing if it
opens emoji or system Dictation instead.

Realtime receives microphone audio on the normal voice path and supplies
the transcript of record and, when enabled, spoken replies. Admission
and dispatch checks still run locally; a visual decision may request a
task-scoped capture, but Fn doesn't automatically send a screenshot.
Eye inference remains on-device. Configured remote capabilities can
receive admitted task content and application context, so even explicit
local speech diagnostics don't make the complete product offline.

## Find your way

- [.agent/PROGRAM.md](.agent/PROGRAM.md): the v1 program — hero jobs, phase DAG, release bars (source of truth for "done").
- [.agent/SHIP-PLAN.md](.agent/SHIP-PLAN.md): current candidate order, remaining phases, evidence and rollback.
- [.agent/REUSE.md](.agent/REUSE.md): open-source-first policy, license/version research and component decisions.
- [Agent rules](AGENTS.md): harness entry point — commands, gates, pinned Driver, workspace and live-test rules.
- [Cua integration](ThirdParty/Cua/README.md): the pinned Driver contract.
- [Eye tracking trial](EyeTracking/README.md): standalone gaze overlay and its local macOS workflow.

This project originated from [jev-voice-control](https://github.com/chris-wozniczek/jev-voice-control).
FluidVoice attribution is in [ThirdParty/FluidVoice](ThirdParty/FluidVoice/NOTICE.md).
The retained Homebrew cask and release workflow describe the upstream distribution;
they are not the installation path for this local Cua integration. Publishing or
retargeting that distribution is outside this cleanup.
