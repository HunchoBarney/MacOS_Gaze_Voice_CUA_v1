# End-to-end flows

Flows that run the signed Jarvis the way a person uses it, through
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
| `hardened-runtime` | #548: launch, the wake word (libvosk loads), the eye tracker's API and a Cua action under the hardened runtime | Jarvis's camera grant (`tracker` target) | the runtime flag in the signature, a live Jarvis, `/health` on the tracker port, no library-validation lines in `tracker.log`, one Calculator, no permission prompt in the system log |
| `daemon-host-only` | #560 items 25–28: open Calculator and "type 2 plus 2"; a new Safari tab on apple.com, a bigger window, File > New Window; another process refused at the daemon socket | microphone, Realtime, network | Calculator's process, the field fixture's record, Safari's window sizes, count and page URL through Accessibility, the daemon closing a handshake from the test process on Jarvis's socket without an answer |
| `agent-handoff` | #562 item 24: "have an agent open a new blank document in TextEdit" goes through Jarvis's agent socket | **paid**: one Codex turn and a Jev call; TextEdit closed beforehand | an Untitled TextEdit window, through Accessibility |
| `sleep-wake` | #560 item 29: voice still works after the Mac sleeps and wakes | **the owner** closes and opens the lid | the kernel's wake time changes, then one Calculator |
| `stop-controls` | #583: a held Fn opens nothing; Stop shows in the menu-bar menu only while a task runs and stops it; a posted Escape doesn't stop a task; a keyboard Escape does | **the owner** presses Escape for the last check | Calculator's process, Jarvis's menu-bar menu through Accessibility, the list fixture's scroll record |
| `writing` | L7 (#595): "type this: meet Dana at 5:45" lands verbatim in the focused field; "come up with a reply for this" puts a draft in Reply and doesn't send it | `voice.live` (`live` target); Jarvis's Speech Recognition grant for typing at once; the reply is **paid** | the field fixture's record, and the message fixture's record of Reply and of any Send press |

The flows for #548, #560, #562 and #583 need a build that contains those
pull requests; on main without them they fail, which is what they're for.
Flows marked paid run only with `JARVIS_E2E_PAID=1`, and owner steps only with
`JARVIS_E2E_OWNER=1`: the run prints `>>> e2e needs you:` with the one thing to do.

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
| `JARVIS_E2E_PAID` | off | `1` adds the agent turn and the reply draft |
| `JARVIS_E2E_OWNER` | off | `1` adds the steps that need the owner: Escape and sleep |

## What the first run has to prove

- The engine reads Jarvis's windows (it lists an accessory app's windows).
- "Hey Jarvis" said by `say` wakes Standby the way a person's voice does.
- `say` through the built-in speakers is heard through the built-in
  microphone past voice processing. If it isn't, install BlackHole 2ch
  (GPL-3.0, admin) and use `JARVIS_E2E_AUDIO=blackhole`.

## Permissions

The app that starts `make e2e` (Terminal, or Capy) needs Accessibility, to
read and press Jarvis's windows and other apps' controls and to post the Fn
and Escape keys, and Screen Recording, for the failure screenshots.
`scripts/run.sh` only checks these and stops with what to grant; it never
asks. Jarvis needs its own Microphone, Accessibility and Screen Recording,
Camera for `hardened-runtime`, and Speech Recognition for `writing` to type
at once instead of asking "Type this?" first. Every prompt a flow sees for
Jarvis in the system log fails the flows that check for one.

## The engine pin

`@e2e-dev/desktop` is e2e-inc/e2e#1953, open and unreleased.
`scripts/install.sh` builds it from the commit in `engine.pin` against the
published `@e2e-dev/core` 0.24.0, and the engine downloads agent-desktop
1.3.1 on its first run, checked against its SHA-256. When a release ships the
engine, depend on that version in `package.json` and delete `engine.pin`.
