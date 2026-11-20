# Jarvis

A macOS menu-bar app you talk to. Say "Hey Jarvis" (or the name you give
it) and ask in plain words; Jarvis talks back, types, clicks and runs
whole tasks on your Mac. Eye tracking is optional and off by default:
turn it on and "click this" means what you're looking at. The app bundle
is currently named **Jarvis.app**. The hands-free design settled on
2026-11-20 is being built; see [DECISIONS.md](DECISIONS.md).

## Build and run

Requires macOS 26 with the macOS 26 SDK, Xcode command-line tools, and Node
(pnpm comes through Corepack).

```sh
make test      # swift test --parallel, tracker typecheck and Vitest
make release   # one signed build from source → build/Jarvis.app + zip
make install   # release, then copy to ~/jarvis-local (does not launch)
make local     # install, then relaunch the app
```

The first `make release` mints a self-signed "Jarvis Local Dev" identity
in your login keychain, so macOS permission grants survive rebuilds.

GitHub Actions is off, so CI runs on the owner's Mac. `make local-ci-install`
loads a launchd agent that every 5 minutes runs `make test` on the open PR
head or main commit without a result that it first saw longest ago, one at a
time, queued ahead of normal jobs in the crew's build lane, then posts a
`local-ci` commit status through the Mac's `gh` login.
`scripts/local-ci.sh <pr|sha>` queues one head, even one that already has a
result: it posts `pending` and returns, and the agent tests it in turn.
Checkout and logs live in `~/.capy/work/local-ci`. Stop it with
`make local-ci-pause` / `local-ci-resume` / `local-ci-uninstall`.

## Use it

Open the menu-bar icon → Settings. Until the app uses the hosted
credentials Worker (KAR-38, `CredentialService/`), voice needs an OpenAI
API key and Jev decisions need a TypeSafe key, both stored in Keychain;
after that you won't handle keys. Grant the microphone, screen recording
and accessibility prompts once, and the camera if you turn on eye
tracking. **Pause Listening** in the menu stops all listening.

While Jarvis is asleep only the on-device wake word listens, and nothing
leaves your Mac until you say the wake phrase. During a conversation your
speech goes to OpenAI, and task content and app context can go to the
configured model providers. Eye tracking runs on-device.

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

All rights reserved, no licence granted: see [LICENSE](LICENSE). ThirdParty/ keeps its own licences.
