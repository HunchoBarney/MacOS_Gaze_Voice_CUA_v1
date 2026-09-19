# Jev Voice

The approved next update is documented in the [voice UI implementation brief](docs/voice-ui/EXECUTION.md), with a separate specification and milestone plan. It covers FluidVoice-style presentation, Fn hold-to-talk, and microphone selection. These features are planned; the usage instructions below describe the current app.

A macOS menu-bar app that turns spoken commands into actions using
[TypeSafe AI's Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
— a System One model that returns *typed decisions with probabilities* instead of
generated text.

Press **⌥Space**, say something, and Jev decides what to do:

- "open chrome and go to google.com"
- "quit spotify"
- "type hello world"
- "set volume to 30"
- "search for swift concurrency"

Speech is transcribed **on-device** (SFSpeechRecognizer). Recording is unavailable
if the current recognizer cannot process audio locally. Jev receives the transcript
and app context described below.

## How it works

```
microphone ──> SFSpeechRecognizer (on-device) ──> transcript
                                                      │
                                          ClauseSplitter (multi-verb clauses)
                                                      │
                              POST /v1/systemone  ──> Jev (typed answers)
                                per clause: action?   target_app?
                                            system_action? target_context?
                                            search_site?
                                                      │
                                 Typed decisions + validated command plan
                                                      │
                              Executor (NSWorkspace / CGEvent / osascript / pmset)
```

Explicit `type`, `write`, `dictate`, and `say` clauses are handled locally as literal
dictation. Everything after that prefix stays text, including phrases such as
“and quit Safari.” Say a new command in a separate recording after dictation.
Commands before dictation still work: “open Notes and type hello and quit Safari”
opens Notes and types “hello and quit Safari.”
Polite forms such as “please type…” and “I want you to type…” also work. If Jev
interprets other wording as dictation without a safe text boundary, the app asks
you to start with one of the explicit dictation prefixes.

Jev never produces free text — each other clause is one `systemOne` call with a state
payload (`clause`, ordered `clauses`, `clause_index`, `full_transcript`,
`frontmost_app`, `installed_apps`) and five
questions:

| question | type | shape |
|---|---|---|
| `action` | choice | one of `openApp`, `closeApp`, `openURL`, `webSearch`, `dictate`, `system`, `none` |
| `target_app` | choice | installed app names (≤254) + `none` |
| `system_action` | choice | `volumeSet`, `mute`, `lockScreen`, `screenshot`, … |
| `target_context` | choice | independent target, continuation, explicitly separate continuation, or original frontmost app |
| `search_site` | choice | explicitly named supported search website, unsupported destination, or none |

Clause requests run in parallel. Each sees the ordered request, and the planner
resolves references after all results arrive, before executing anything:

- "open Google and search for the weather in Yuba City" becomes one search navigation.
- "open Safari and go to example.com" navigates directly in Safari, launching it if needed.
- "open YouTube and search for cats" searches YouTube; DuckDuckGo is also supported.
- "open Notes and minimize it" targets Notes, not the app that was active when recording began.
- "open Notes and type hello" retains both steps and focuses Notes before pasting.

The planner preserves an explicit request for separate tabs. It combines an
opening step only when the destination action already performs that opening.
Missing arguments and unsupported in-app searches stop the plan before any steps
run. These relationships currently apply within a single recorded utterance;
the app does not inspect arbitrary UI controls or track browser-page context
between recordings. Search URLs are declared capabilities, not model-generated URLs.

Arguments (URLs, queries, dictation text, percentages) can't come from Jev —
it's decision-only — so they're extracted deterministically by `SlotExtractor`
heuristics.

Low-confidence decisions (< threshold, default 70%) require clicking **Run** in
the popover before anything executes.

## Install with Homebrew

This repository doubles as a Homebrew tap (see `Casks/jev-voice.rb`):

```sh
brew tap chris-wozniczek/jev-voice https://github.com/chris-wozniczek/jev-voice-control
brew install --cask jev-voice
```

Homebrew 7+ refuses untrusted third-party taps; if prompted, run
`brew trust chris-wozniczek/jev-voice` first.

Releases are produced by `.github/workflows/release.yml`: bump
`CFBundleShortVersionString` in `Info.plist`, push a matching `vX.Y.Z` tag, and
the workflow builds `Jev-Voice-X.Y.Z.zip`, publishes a GitHub release, and
commits the new version/sha256 into the cask.

## Build from source

```sh
make app    # builds build/Jev Voice.app (ad-hoc signed)
make run    # launches it
make test   # logic and app-boundary tests; no live microphone/model/desktop actions
make dist   # zips the app into build/Jev-Voice-<version>.zip and prints its sha256
```

If a synced checkout adds Finder metadata that prevents code signing, build the
app outside that folder:

```sh
make app APP="$HOME/Library/Caches/JevVoice/build/Jev Voice.app"
```

Then enter your API key in the popover's Settings (gear icon) and click **Save**.
It is stored in the macOS Keychain. Existing keys in app preferences migrate to
Keychain, and the old preference is removed only after storage succeeds. Settings
shows any storage or migration error. Clearing the field and saving deletes the
stored key.

You can also supply `TYPESAFE_API_KEY` in the app's launch environment. This fallback
is not saved automatically. Removing a saved key does not remove an environment
variable configured outside the app.

### Permissions

- **Microphone** — hear commands
- **Speech Recognition** — transcribe on-device; unsupported recognition fails closed
- **Accessibility** — required for the Cmd+V paste used by dictation
- **Automation** — required for `osascript` volume/brightness/lock actions

## Limitations

- Jev is text-only and never generates strings, so URLs/queries/dictation come
  from heuristics over the transcript, not from the model.
- System actions are AppleScript/`pmset` based; brightness key codes may vary
  on some hardware.
- Lock requests macOS's [Control–Command–Q shortcut](https://support.apple.com/en-my/102650), rather than sleeping the
  display. The request can fail if Automation/Accessibility access is unavailable;
  it does not independently verify that macOS has locked the session.
- Dictation uses the clipboard and waits 0.5 seconds for the target to handle paste
  before restoring it. This does not verify insertion in every app. Overlapping
  paste requests are rejected; user clipboard changes are preserved.
- Searching inside native apps such as Notes is not implemented. Such a plan
  reports that limitation instead of sending the query to a web search engine.
- App launching scans `/Applications`, `/System/Applications`, Utilities, and
  `~/Applications`.

## Privacy

- Speech recognition requires on-device support and sets `requiresOnDeviceRecognition`.
- Only the transcript, frontmost app name, and installed app list are sent to
  `api.typesafe.ai`. A mixed command includes the full transcript, including any
  dictated text, in the context sent for its non-dictation clauses.
- Saved API keys live in macOS Keychain. If migration fails, the existing preference
  remains available for retry and Settings displays an error; new saves never fall
  back to plaintext preferences.
