# Development and verification

## Toolchain and commands

Use macOS 26+ and Xcode with the macOS 26 SDK. `make setup` checks the toolchain;
it does not install models, change permissions or read credentials. Build commands
run from the checkout root (`make -C /path/to/checkout ...` also works).

| Command | Effect |
| --- | --- |
| `make test` | Default Swift tests; gated live checks skip unless explicitly enabled |
| `swift test --filter ClassName` | Focused test class |
| `make app` | Build release and sign `build/Jev Voice.app` |
| `make run` | Build and open the app; quit another copy first |
| `make dist` | Create the versioned zip under `build/` |
| `make clean` | Delete only this checkout's `.build` and `build` outputs |

`APP=/absolute/path/Jev\ Voice.app` overrides packaging destination when needed
(quote the complete make argument). Prefer checkout-local output. Never point it
at an installed bundle without preserving that bundle and coordinating desktop use.
If a file provider adds Finder metadata after signing, package into a unique
non-synced directory using the `APP` override and verify with
`codesign --verify --deep --strict "/path/to/Jev Voice.app"`. Do not remove security
attributes globally. A successful signing command alone is insufficient.

App IDs, preferences, Keychain items and installed Driver are shared across worktrees.
Ad-hoc rebuilding can prompt macOS to recheck permissions or Keychain access.

## Conductor

The checked-in `.conductor/settings.toml` exposes local setup, test and package
commands. Local setup seeds isolated supporting source and shared reference links
using `scripts/setup-workspace-development.py`; it never links the whole
`development/` folder or copies dependency environments or build caches.
See [local storage](LOCAL-DEVELOPMENT-STORAGE.md) for the isolation rules.
Spotlight testing is disabled so commands run in their own workspaces. Each
workspace owns its `.build` and `build` directories. Setup checks prerequisites; packaging does not launch or install anything.

Verify the branch/revision and any uncommitted work before using a new workspace.
Git worktrees do not automatically contain another checkout's uncommitted files.
See [Conductor scripts](https://www.conductor.build/docs/reference/scripts).
No global settings changes or external-SSD moves are needed for these commands.

## Eye tracking trial

`EyeTracking/` is a separate Electron/Python project. Its package and model
versions remain pinned in its own lockfiles. This workspace contains local copies
of the ONNX models and web runtime assets under `EyeTracking/public/`; Git ignores
those binaries, the calibration files, dependencies, and build output. They are
unique workspace inputs, not disposable caches. For local Conductor workspaces,
the repository's `.worktreeinclude` copies model files that exist in the main
checkout into each new workspace. Seed the main checkout from the
[trial's documented release](../EyeTracking/README.md#setup) before creating a
workspace; non-Conductor worktrees still need their own model copies.

From this workspace root, prepare and check the web runtime with:

```sh
cd EyeTracking
corepack pnpm install --frozen-lockfile
corepack pnpm typecheck
corepack pnpm test
corepack pnpm build
scripts/package-macos-trial.sh
```

The packager creates `build/Screen Eye Tracking Trial.app` under this workspace
and refuses to overwrite an existing bundle. It retains the trial's bundle ID
and ad-hoc signing; packaging does not launch the camera. For a live trial, use
the Conductor **Eye tracking setup** action for a new workspace, then use
**Eye tracking** or **Eye tracking calibrate** to run it. The live actions take
the shared desktop lock and use this workspace's assigned port. From a terminal,
the equivalent calibration command is:

```sh
python3 scripts/with-desktop-lock.py EyeTracking/scripts/run-macos-trial.sh --calibrate
```

The copied calibration files remain local. Older calibrations made from clipped
raw gaze are preserved but ignored by the current trial, so calibration is needed
before assessing the marker. Automated tests do not establish live camera or
gaze accuracy on this Mac.

## Live checks and shared desktop

Tests with names ending in `LiveTests`, plus some integration tests, gate themselves
using environment variables documented in the test source. Read the selected test
before enabling its flag: it may launch apps, interact with a browser, read Keychain
or call a paid model. Do not blanket-enable all `JARVIS_*` variables.

Use the shared desktop lock for a selected live check, for example:

```sh
JARVIS_CUA_TEST=1 python3 scripts/with-desktop-lock.py swift test --filter CuaConnectionTests
```

The lock serializes cooperating commands across worktrees for the current user.
`JARVIS_DESKTOP_LOCK_DIRECTORY` is only needed for isolated wrapper tests; keep the
default shared directory for actual desktop checks.
It cannot prevent an independently launched app or human from using the desktop.
Use one desktop owner, disposable fixtures, and avoid concurrent installed-app
replacement. Never send real messages, purchase, or delete personal content as tests.
Credentials belong in the app or an explicitly configured environment, not commands
saved in the repository. Physical microphone/Fn checks require the user's input.

The ready-input timing check is scoped to real microphone capture with programmatic
hold admission; it does not call Jev/Cua or prove physical Fn behavior:

```sh
python3 scripts/with-desktop-lock.py env JARVIS_READY_MIC_TEST=1 swift test --filter ReadyMicrophoneLiveTests
```

It requires microphone permission for the test process (separate from the app),
reports cold preparation and 30 warm holds, then checks suspend/recovery. No raw
recording or transcript is saved. `JARVIS_TEST_MIC_UID` optionally selects a device.
Physical acceptance still requires at least five immediate-release and two longer
holds on the identified app build, with recognition and desktop outcomes separated.

The existing short recorded-audio check accepts `JARVIS_SHORT_SPEECH_SAMPLES=31`
(one first-use sample plus 30 warm repeats) together with
`JARVIS_SHORT_SPEECH_TEST_FILE`. It reports input-start to first result, input-end
to last result, and input-end to finalized timings separately. These are synthetic/
recorded input boundaries, not physical speech completion or desktop-action latency.

## Prerequisites versus proof

Default tests do not require a live Driver, microphone or model key. Full control
requires [the pinned Driver and perception setup](../ThirdParty/Cua/README.md),
user-controlled macOS grants, and valid provider configuration. A successful build
or accepted tool call is not proof that an application outcome occurred.

For cleanup/refactors: compare baseline and affected tests, review resource paths,
validate `make app` and its signature, and check a clean disposable checkout. Preserve
existing acceptance failures. Full migration acceptance is tracked separately in
[PLAN.md](voice-ui/PLAN.md), with observations in [EVIDENCE.md](voice-ui/EVIDENCE.md).

For the approved [execution simplification](EXECUTION-SIMPLIFICATION-PLAN.md), use
its scoped replacement proofs and workflow checks. Compare task success, latency,
model calls and Driver calls against a preserved baseline; exercise the changed
production path rather than relying only on injected callbacks. Record results in
the evidence ledger with the simplification step and tested build identified.
Passing these checks does not close unrelated migration gates. Live checks remain
opt-in and use the shared desktop lock; documentation alignment alone needs
content/diff review, not app tests.

## Distribution

`.github/workflows/ci.yml` builds/tests on macOS 26. The inherited release workflow
and `Casks/jev-voice.rb` still describe upstream distribution; do not tag/publish
this customized build without separately reviewing those destinations and runtime
packaging. `make dist` only creates a local archive.
