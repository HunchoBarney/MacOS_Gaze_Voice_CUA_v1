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
commands. It intentionally does not copy `development/`, dependency environments
or build caches. Each workspace owns its `.build` and `build` directories. Setup
checks prerequisites; packaging does not launch or install anything.

Verify the branch/revision and any uncommitted work before using a new workspace.
Git worktrees do not automatically contain another checkout's uncommitted files.
See [Conductor scripts](https://www.conductor.build/docs/reference/scripts).
No global settings changes or external-SSD moves are needed for these commands.

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
It cannot prevent an independently launched app or human from using the desktop.
Use one desktop owner, disposable fixtures, and avoid concurrent installed-app
replacement. Never send real messages, purchase, or delete personal content as tests.
Credentials belong in the app or an explicitly configured environment, not commands
saved in the repository. Physical microphone/Fn checks require the user's input.

## Prerequisites versus proof

Default tests do not require a live Driver, microphone or model key. Full control
requires [the pinned Driver and perception setup](../ThirdParty/Cua/README.md),
user-controlled macOS grants, and valid provider configuration. A successful build
or accepted tool call is not proof that an application outcome occurred.

For cleanup/refactors: compare baseline and affected tests, review resource paths,
validate `make app` and its signature, and check a clean disposable checkout. Preserve
existing acceptance failures. Full migration acceptance is tracked separately in
[PLAN.md](voice-ui/PLAN.md), with observations in [EVIDENCE.md](voice-ui/EVIDENCE.md).

## Distribution

`.github/workflows/ci.yml` builds/tests on macOS 26. The inherited release workflow
and `Casks/jev-voice.rb` still describe upstream distribution; do not tag/publish
this customized build without separately reviewing those destinations and runtime
packaging. `make dist` only creates a local archive.
