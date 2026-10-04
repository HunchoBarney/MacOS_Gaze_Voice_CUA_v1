# Comprehensive repo audit — Jarvis / Jev Voice

Date: 2026-10-03. Scope: whole repo — voice pipeline, execution layer, UI,
Jev setup, Qwen 3.8 usage, Cua usage, overbuiltness, accessibility for
limited-movement users (stated first customer), vs Clicky.

Method: full read of `Sources/` (9,780 LOC), `ThirdParty/Cua` contract +
vendored driver docs, `Makefile`, tests, `Casks/`, `EyeTracking/`; live
verification through the packaged app's Activity input earlier the same
session; Clicky source (`farzaa/clicky`, 25 Swift files ~314 KB);
models.dev for Qwen 3.8 provider ids; Cua `contract/README.md` + upstream
fix notes.

## Verdicts up front

- **Cua usage: correct.** Persistent MCP session, snapshot-token discipline,
  re-observe after each effect, read-only retries only, mutations never
  retried, `delivery_mode` for typing, `bring_to_front` semantics, pinned +
  hash-verified driver. Matches `contract/README.md` and Cua's own SKILL.md.
- **Jev usage: correct.** `choice` questions in one System One request,
  strict `JevSelection.read` validation, `jev-latest`. One model call per
  user turn + one per loop step is minimal for a model-in-loop agent.
- **Qwen 3.8: correct and appropriately optional.** Groq `qwen/qwen3.8-27b`
  and Cerebras `qwen-3.8-27b` are real model ids (models.dev). Used only for
  the optional text-generation provider; Jev stays the action selector.
  `reasoning_effort: none` keeps latency sane.
- **Overbuilt: partially fixed, still real.** The thin loop is genuinely
  thin (620 LOC). The weight moved into `CuaTaskAgent` (1,950), the
  19-question decide battery, `CuaDialogueState` (513), and
  `CuaVoiceRuntime` (1,266). Some is justified; several specific parts are not.
- **The bigger problem for the stated customer is not architecture — it is
  missing customer-facing capability.** Clicky spends its ~9k LOC on things
  the user feels (spoken answers, screenshot understanding, companion UX).
  Jev spends its ~9k on correctness machinery the user cannot see. Jev is
  already better at *doing*; it cannot *talk, show, or help*.

## Proven defects

1. **`cmd+q` / `cmd+w` hotkey lanes bypass the risk gate.**
   `CuaAgentLoop.lanesFor` offers "Press cmd+q"/"Press cmd+w" to any app
   (lines ~155–165). `CuaTaskAgent.riskDescription` gates only on keyword
   match (delete, purchase, overwrite, …) — "Press cmd+q" contains none.
   One model pick can quit an app or close a window with no approval.
   Live evidence this week showed the gate catching "Press delete" — the
   keyword worked there by luck of vocabulary. Fix: gate window-input
   lanes whose effect quits/closes, or drop those chords from
   `hotkeyChords` (app quit already has a safer `appControl` path).

2. **Fast-lane text verification reads `value` only — TextEdit exposes
   document text via `label`.** `CuaTaskAgent.dispatchFastType`
   (~line 1731) checks `element["value"]`; the loop's `reads(_:)` checks
   value+label (fixed this week after live failure). Same false
   "delivered, not independently readable" outcome remains in the fast
   path — and a bare "type hello" into single-field TextEdit hits exactly
   this path.

3. **`JevClient.request` has no timeout.** Default `URLRequest` timeout is
   60 s; a stalled System One call hangs every decide for up to a minute
   (vs `TextGenerationClient` which sets 45 s). Add
   `request.timeoutInterval` (~15–20 s) plus a typed timeout error.

4. **`CuaSetup` hardcodes a 9-second sleep for the old fork's 8 s launch
   watchdog.** Upstream 0.32.0 (our pin) added launch-before-snapshot
   waiting — the driver now handles this. The `Task.sleep(9s)` before
   `get_window_state` is stale cargo making setup take ~10 s regardless.
   Verify against upstream and delete or reduce.

5. **`browser_page` raw JSON goes into loop state unfiltered.**
   `mergedState` passes the whole `get_browser_state` result; lanes cap
   refs at 20 but the model-visible `browser_page` can carry hundreds of
   DOM refs → state bloat, per-step latency and token cost. Compact it
   like `compactElement` does for AX elements.

6. **`markGrantUnconfirmed()` has no callers.** If the browser-profile
   grant is lost (daemon restarted without `--grant existing-profile`),
   nothing clears the `configured` flag — the app never reconciles again.
   Either dead code or a missing call on `browser_prepare` refusal.

7. **Dead code: `confidenceThreshold`** (persisted, surfaced nowhere,
   `JevSelection.read` ignores confidence value), **`CuaStateVerification`**
   (`verify_state` adapter used only by its own tests — production never
   calls it), **`clipboard_read`** in readOnlyTools with no caller.

8. **Approvals cannot be answered by voice.** Risk-gated actions present
   Confirm/Cancel buttons only. For the stated customer (limited
   movement), a fully voice-driven user literally cannot approve. The
   next utterance routes as a *new* command through `decide()`, not as a
   yes/no answer to the pending approval.

9. **Stale naming/docs.** Root README still says "requires the exact
   pinned **Cua Driver Local** and configured perception extension; stock
   Cua is not interchangeable" — false since the 0.32.0 pin moved to the
   stock CuaDriver.app. `CuaDependency` error messages say "Cua Driver
   Local". Work labels say "Jarvis N" while the product is "Jev Voice".
   `TextProviderCard` suggests `gemini-3.8-flash` — likely not a real
   model id (card admits presets are unverified).

10. **Voice finalization deadline (2 s) is tight.** `VoiceTimings
    .finalization = 2`. SpeechAnalyzer finalize after Fn-release races it;
    cold load or long utterances produce "Speech didn't finish in time"
    and a click-required review — bad for hands-free users. Earlier live
    sessions hit this. Consider adaptive sizing (utterance length) or a
    bigger bound before review.

## High-confidence risks

- **`CuaDaemonControl` stops a running daemon of unknown grant
  provenance** to relaunch with `--grant existing-profile`. On a machine
  where the user runs other Cua clients this kills their in-flight work.
  Once per process, still worth a status check for active sessions first.
- **`receive()` double-decides on inventory change** (cached decide +
  re-decide) — second Jev call in the same turn. Rare, fine, but noted.
- **`typeIntoElement` omits `delivery_mode`** while the fast lane sends
  `background`. Driver defaults apply; behavior differs by app focus
  state. Pin it explicitly.
- **Speech locale locked to `Locale.current`** — no multilingual
  selection. For a worldwide accessibility market this is a product gap.
- **`elements.prefix(80)` to the model vs `prefix(40)` offered lanes** —
  model sees elements it cannot act on; mostly harmless (scroll exists).
- **`compactElement` truncates text at 80 chars** — the model's done-gate
  cannot see long insertions; mitigated by `verified_facts` but still
  limits model-side verification of long dictation.

## Overbuilt — concrete deletions/merges

1. **`CuaLaunchReceipt.reverse`** (~85 LOC + call sites + decide
   questions): fingerprints the app's AX tree element-identity, then
   model-selects a Quit menu item, then reverses if unchanged. This
   duplicates `appControl(.quitApp)` which already exists and is safer.
   The compensation can be "tell the user what was opened" — delete the
   receipt machinery.
2. **`CuaSetup`** (236 LOC): the disposable-TextEdit write proof with a
   model call + 9 s sleep is a nice demo but a permissions + `list_apps`
   + driver-status check answers "does control work" in ~1 s.
3. **Grouped-choice machinery** for >252-word utterances
   (`groupChoices`, `offsetChoices`, `choiceGroupSize`): supports
   mega-utterances nobody produces. Bounding the pending span at the
   ledger would delete a subsystem.
4. **`CuaStateVerification`, `confidenceThreshold`, unused
   `readOnlyTools` entries** — dead now.
5. **`EyeTracking/`** — 312 MB vendored Electron+Python app (PINTO0309
   screen-eye-tracking trial), unrelated to the shipping target. It is
   why every repo audit feels bloated. Move to a sibling repo.
6. **`CuaDialogueState` prerequisite/correction chains** — the
   intent/answer/retry core earns its keep; the verified-fact discharge +
   prerequisite machinery is the most complex part and serves the
   rarest flows. Keep intents + answers + retry; consider trimming
   prerequisite graphs to "reference latest result" only.

## Missing vs Clicky — the actual product gap for disabled users

Clicky (farzaa/clicky) architecture: hold Ctrl+Option → STT → screenshot
+ transcript → Claude (streaming) → ElevenLabs TTS → cursor overlay +
companion panel. ~9 k LOC, of which most is user-facing.

What Jev lacks that this audience needs first:

1. **Spoken feedback (TTS).** AVSpeechSynthesizer is ~50 LOC. "Done —
   opened Notes" / "Which window — Untitled 21 or 22?" spoken aloud is
   the single biggest unlock for someone who cannot easily look.
   Clarifications *must* be speakable.
2. **Latch mode.** Hold-Fn requires sustained finger dexterity. Tap-Fn to
   start / tap or Escape to stop is a small `FnInputState` change with
   huge accessibility value. Wake word ("Hey Jarvis") later.
3. **Voice-answerable approvals and clarifications** — yes/no bindings,
   option selection by number ("one", "two"), all through the existing
   answer path.
4. **Help/Q&A mode.** "What does this dialog mean?" — screenshot →
   text provider → spoken answer. This is Clicky's entire core loop and
   the "helps if you need help" half of the goal. The `op` vocabulary
   needs an `answer`/`explain` operation; the text provider already
   exists.
5. **`invoke_menu` lane.** Native apps expose their whole capability via
   menus — Save As, Export, Print, app-specific commands. The tool is
   there; `menuFocus` grants exist. Biggest action-surface unlock.
6. **Agent cursor ON by default.** Watching where the driver will act is
   essential feedback; the setting exists and is wired, just defaults off.
7. **Onboarding.** First-run checklist: mic + AX permission, driver
   presence, one test command. Today setup is a manual "Test Cua + Jev"
   button buried in Commands settings.
8. Smaller lane gaps: `set_window_frame` ("resize/move window"),
   `clipboard_read/write` ("copy that"), `drag`, `browser_dialog` (JS
   dialogs/permission prompts), pixel/`parse_visual_regions` fallback for
   AX-poor apps (Electron: VS Code, Discord, Slack).
9. **No `answer`-class op** — every utterance must become
   action/wait/clarify; "what's on my screen?" can't be a question.

## What is genuinely good — do not regress

- `CuaAgentLoop`: thin, observed-state-driven, honest outcomes, lane
  retirement on capability refusals, verified_facts feeding done-gate.
- `CuaConnection`: generation tokens, stale-response rejection, no
  mutation retries, uncertainty preserved on cancel-after-dispatch.
- `ContinuousIntentCoordinator` + `SpeechConsumption`: multi-command
  transcripts and committed-prefix immutability — tested (306 tests).
- Interaction-scoped cancel: Escape cancels this capture's work only.
- Non-activating overlay panel (FluidVoice pattern), on-screen-with-mouse
  placement.
- Content-minimized diagnostics (utterance lengths, never text).
- Keychain per-endpoint provider keys; no secrets in repo/logs.
- Standing grants: approve-once capabilities, resettable.
- Fn tap health: secure-input detection, missed-release reconciliation,
  physical key state polling.
- Driver pin + SHA-256 verify + `verify-cua-source.py`.

## Tests

306 XCTest tests pass (`make test`). Logic-level coverage is good —
coordinator races, dialogue invariants, answer binding, fast-lane
parsing, error mapping all have tests. Gaps: no packaged-app UI test
(XCUITest), live path behind `JARVIS_*` flags (correct), no test that
`gemini-3.8-flash`-style presets resolve, nothing covering the
wake-stall path end-to-end (can't be unit-tested honestly).

## Recommended order

Fixes first (cheap, correctness): risk-gate hotkey quit/close lanes;
label-readback in fast-type verify; `JevClient` timeout; drop 9 s setup
sleep; compact browser_page; wire or delete `markGrantUnconfirmed`;
delete dead code; fix stale README/driver strings; verify Gemini preset.

Then the customer-facing layer that makes it "Clicky but more": TTS
feedback + spoken clarifications, latch mode, voice approvals, menu lane,
onboarding, agent-cursor default. Then the larger capability lanes
(window frame, clipboard, dialogs, visual fallback) and help/Q&A mode.
