# End-to-end flows

Five flows that run the signed Jarvis the way a person uses it, through
[e2e](https://github.com/e2e-inc/e2e) and its macOS engine
(`@e2e-dev/desktop`, built on
[agent-desktop](https://github.com/vercel-labs/agent-desktop)). They cover only
what the Swift seam tests in `make test` can't reach: the packaged app, its
windows, sound through a real microphone, the wake word, and an effect on
another app. Everything else stays in `make test`.

They launch Jarvis, speak out loud, open Calculator and spend a few Realtime
turns on the owner's key, so they run **only when the owner says go**
(handoffs/e2e-go.md in the Captain's drive), one desktop-lock owner at a time.

| Flow | Proves | Needs | Checked by |
| --- | --- | --- | --- |
| `first-run` | Set up Jarvis: pick the wake word, granted permissions step past, Try it, Skip | Jarvis's own grants | the window, then saved `firstRunCompleted` and `listeningMode` |
| `show-names-click` | "Hey Jarvis, show names", then "Hey Jarvis, click Banana" on the fixture board | microphone, Realtime | Activity says the names showed; the board records exactly one Banana press |
| `screen-question` | "Hey Jarvis, what is the code word in this window?" | microphone, Realtime | Activity shows an answer with "pelican", read from the board |
| `wake-word` | Standby ignores "open Calculator", then runs "Hey Jarvis, open Calculator" | microphone, Realtime | no Calculator after the first line, one after the second |
| `stop-scroll` | "Hey Jarvis, scroll down", "keep scrolling", then "stop" mid-scroll on the fixture list; all three are decided on the Mac, with no model call | microphone, Realtime transcription | the list's own record of its scroll offset: it moves on its own, stops after "stop" short of the end, and stays put for 5 s |

The checks read the Mac (processes, the board's own record, saved settings)
or Jarvis's ordinary windows (Set up Jarvis, Settings → Activity), never the
listening panel or the name chips, which agent-desktop may not list.

## Running

```sh
make e2e-install                       # once: e2e 0.24.0 and the pinned engine, into e2e/
JARVIS_E2E_APP=/path/to/Jarvis.app make e2e
make e2e-uninstall                     # removes everything the two put on the Mac
```

`make e2e` holds `scripts/with-desktop-lock.py` and runs `scripts/run.sh`,
which takes about 5–6 minutes:

1. Checks the build's signature, the audio route and the install. Nothing
   changes until these pass.
2. Saves Jarvis's settings domain, which Keychain entries exist, the output
   volume and whether Jarvis or Calculator is running; quits them.
3. Builds `tools/MacHelper.swift` (counts and quits apps through
   `NSRunningApplication`) and the fixture board into a temporary folder.
4. Runs the flows, one `e2e run` per target in `e2e.config.ts`. Every
   setting reaches Jarvis as a launch argument, so none is saved; the eye
   tracker, spoken replies and cue tones stay off.
5. Always, even after a failure or Ctrl-C: Jarvis, the board and
   Calculator quit, settings and Keychain entries back as they were, volume
   back, the owner's Jarvis and Calculator reopened if they were open, the
   temporary folder deleted. The report stays in `e2e/.e2e`.

| Variable | Default | |
| --- | --- | --- |
| `JARVIS_E2E_APP` | `~/jarvis-local/Jarvis.app` | the signed build to test |
| `JARVIS_E2E_AUDIO` | `speakers` | `blackhole` sends the lines through BlackHole 2ch, silently |
| `JARVIS_E2E_ONLY` | all | one flow by name |

## What the first run has to prove

- The engine reads Jarvis's windows (it lists an accessory app's windows).
- "Hey Jarvis" said by `say` wakes Standby the way a person's voice does.
- `say` through the built-in speakers is heard through the built-in
  microphone past voice processing. If it isn't, install BlackHole 2ch
  (GPL-3.0, admin) and use `JARVIS_E2E_AUDIO=blackhole`.

## Permissions

The app that starts `make e2e` (Terminal, or Capy) needs Accessibility, to
read and press Jarvis's windows, and Screen Recording, for the
failure screenshots. Jarvis needs its usual Microphone and Accessibility.

## The engine pin

`@e2e-dev/desktop` is e2e-inc/e2e#1953, open and unreleased.
`scripts/install.sh` builds it from the commit in `engine.pin` against the
published `@e2e-dev/core` 0.24.0, and the engine downloads agent-desktop
1.3.1 on its first run, checked against its SHA-256. When a release ships the
engine, depend on that version in `package.json` and delete `engine.pin`.
