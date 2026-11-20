# Jarvis

A macOS menu-bar app you talk to. Hold Fn (or turn on hands-free), say what
you want, and Jarvis types, clicks and runs tasks on your Mac. Eye tracking
picks the target you are looking at; voice or a click does the selecting.
The app bundle is currently named **Jarvis.app**.

## Build and run

Requires macOS 26 with the macOS 26 SDK, Xcode command-line tools, and Node
(pnpm comes through Corepack).

```sh
make test      # swift test, tracker typecheck and Vitest
make release   # one signed build from source → build/Jarvis.app + zip
make install   # release, then copy to ~/jarvis-local (does not launch)
make local     # install, then relaunch the app
```

The first `make release` mints a self-signed "Jarvis Local Dev" identity
in your login keychain, so macOS permission grants survive rebuilds.

## Use it

Open the menu-bar icon → Settings. Voice needs an OpenAI API key; Jev
decisions need a TypeSafe key. Both are stored in Keychain. Grant the
microphone, camera (eye tracking), screen recording and accessibility
prompts once. If Fn opens emoji or system Dictation, set the Globe-key action
to Do Nothing.

Eye tracking runs on-device. Speech goes to OpenAI Realtime, and task
content and app context can go to the configured model providers.

If something breaks, use **Export Logs…** in the menu and attach the file.
Crash and hang reports from MetricKit are kept in
`~/Library/Application Support/Jarvis/Diagnostics`.

## Find your way

- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit.
- [DECISIONS.md](DECISIONS.md) — what is settled and why.
- [RELEASE.md](RELEASE.md) — building, signing and the public-release hold.
- [AGENTS.md](AGENTS.md) — rules for coding agents in this repo.
- [ThirdParty/Cua](ThirdParty/Cua/README.md) — the pinned Cua driver contract.
- [EyeTracking](EyeTracking/README.md) — the gaze tracker.

This project started from
[jev-voice-control](https://github.com/chris-wozniczek/jev-voice-control).
