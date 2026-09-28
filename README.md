# Jarvis / Jev Voice

A macOS menu-bar computer-control app with a floating voice capsule, Fn/Globe
hold-to-talk, Apple SpeechAnalyzer, Cua Driver, Jev decisions, and optional text
generation. The application bundle is still named **Jev Voice.app**.

**Status:** the Cua migration is incomplete. The current production path uses
SpeechAnalyzer and Cua; passing logic tests does not establish reliable continuous
speech, live dictation, or concurrent control across all apps. See the
[current gates](docs/voice-ui/PLAN.md) and [recorded evidence](docs/voice-ui/EVIDENCE.md).

## Start developing

Requires macOS 26+, Xcode with the macOS 26 SDK, and command-line tools selected
with `xcode-select`. The Swift package has no external package dependencies.

```sh
make setup       # check the local toolchain; no credentials or downloads
make test        # default suite; live checks are normally skipped
make app         # release build → build/Jev Voice.app, ad-hoc signed
make run         # build and open that bundle (quit other Jev Voice copies first)
make dist        # package the bundle as a zip
```

Building the app does **not** install its runtime dependencies. Computer control
requires the exact pinned Cua Driver Local and configured perception extension;
stock Cua is not an interchangeable replacement. See [Cua integration](ThirdParty/Cua/README.md).

## Use the app

Open the waveform menu-bar menu → Settings. Configure the Jev key in Commands,
choose the microphone in Voice, and follow macOS permission prompts. Optional
text generation has a separate provider/key configuration. Saved keys remain in
Keychain; do not put them in repository files.

Hold Fn/Globe, wait for Listening, speak, and release to finalize. The controller
can dispatch completed commands during a hold; reliable behavior across the full
acceptance matrix remains unfinished. Escape cancels the voice interaction;
task Stop and Stop All controls handle task cancellation. Expand the capsule for
Activity and diagnostics. Set the macOS Globe-key action to Do Nothing if it
opens emoji or system Dictation instead.

Speech processing is on-device. Jev and an enabled text provider receive context
selected by their integrations, which can include speech and observed application
content. Do not assume only app names leave the device. See the current model
boundaries in [architecture](docs/ARCHITECTURE.md).

## Find your way

- [Collaborator handoff](docs/HANDOFF.md): the current source and downloadable runtime/model packages.

- [Architecture and source map](docs/ARCHITECTURE.md): responsibilities and ownership.
- [Development and verification](docs/DEVELOPMENT.md): Conductor, tests, packaging, runtime prerequisites.
- [Eye tracking trial](EyeTracking/README.md): standalone gaze overlay and its local macOS workflow.
- [Behavior specification](docs/voice-ui/SPEC.md): active S1–S9 requirements.
- [Migration plan](docs/voice-ui/PLAN.md): active P0–P5 gates and A1–A13 acceptance matrix.
- [Migration execution instructions](docs/voice-ui/EXECUTION.md): use only when implementing that migration.
- [Local storage](docs/LOCAL-DEVELOPMENT-STORAGE.md): ignored supporting files and compatibility paths.
- [Cleanup record](docs/CLEANUP.md): changes, verification and recovery.

This project originated from [jev-voice-control](https://github.com/chris-wozniczek/jev-voice-control).
FluidVoice attribution is in [ThirdParty/FluidVoice](ThirdParty/FluidVoice/NOTICE.md).
The retained Homebrew cask and release workflow describe the upstream distribution;
they are not the installation path for this local Cua integration. Publishing or
retargeting that distribution is outside this cleanup.
