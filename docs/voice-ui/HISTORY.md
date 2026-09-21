# Historical migration plans

Reference only. Current requirements: [SPEC.md](SPEC.md).

## Historical plan and evidence — inactive reference only

Everything below is retained verbatim from the pre-migration plan, including its old active headings/statuses. It is not a current backlog, authority to preserve the old executor, or evidence for P0–P5. Consult only for regression/rollback context.

<details>
<summary>Earlier continuous-control plan and delivery records</summary>

# Continuous voice control implementation plan

Status: early command execution repaired and physically confirmed by the user (TextEdit launch and new-document before Fn release). The user's subsequent request for live dictation is implemented, passes 154 tests, and is packaged. **Live TextEdit insertion is not yet accepted:** the new ad-hoc binary reports missing macOS permissions, so a user-controlled regrant and physical test are pending. Keep A1–A10 open where native evidence is absent. Preserve all tracked and untracked work; historical evidence is reference-only.

**Goal:** keep the existing pill and Fn experience while executing complete commands during speech, supporting dependent in-app actions and reliable launch corrections.

**Architecture:** extend the existing controller with independent capture/progress state, a small incremental command coordinator, and one serial executor. Reuse local routing and Jev typed interpretation; record action identity, prerequisites, actual outcomes, and enough pre-action state for bounded compensation. Do not build a general multi-agent orchestration framework.

**Tech Stack:** existing Swift/SwiftUI/AppKit, Apple Speech, native automation/accessibility, and Jev. No runtime model replacement.

**Spec:** [SPEC.md — continuous control C1–C5 and preserved behavior R1–R6](SPEC.md). Start with [EXECUTION.md](EXECUTION.md).

## Incremental scope — build only what is missing

| Existing capability to reuse | Necessary change |
| --- | --- |
| Fn event handling, Apple speech capture, microphone selection, permissions | Feed existing partial events into incremental decisions; adjust lifecycle assumptions only where capture and execution now overlap |
| Pill, waveform, transcript, settings, Activity, Expand/Collapse | Bind concurrent listening/action/correction feedback; no UI redesign or FluidVoice re-import |
| Local app matching, Jev client and typed interpretation, command planning | Add command boundaries, revision reconciliation, context progression, and action identity; do not replace the backend |
| Native app launch/switch/minimize, URL/search, literal dictation, clipboard cleanup | Reuse these actions in the serial flow; add receipts and bounded launch reversal, plus only the missing document/scroll/back capabilities |
| Existing tests, preferences, Keychain, package/signing workflow | Add coverage for changed behavior, run relevant regressions, and validate the final package; no migration or signing overhaul |

This table describes the inspected baseline, not an instruction to reconstruct it. If a later checkout already implements part of a milestone, verify it and continue with the remaining gap. Preserve functionality even where its implementation differs from a proposed filename or component split.

## Active progress

**Current addition requested during physical testing:** live dictation, implemented and packaged with the existing pill/Fn and owned text-range updates; native acceptance pending permissions and physical test. The user confirmed app launch/new-document before release, then reported that text still waited for release. Implement partial insertion plus bounded revisions, final deduplication, target/cursor/edit interruption, literal command-word protection and manual/fallback preservation. Validate in the actual TextEdit document before calling live typing delivered. This supersedes release-only literal timing; other active acceptance remains unchanged.

| Task | Status | Evidence required |
| --- | --- | --- |
| T0 — Baseline and app probes | Baseline verified; native probes ongoing | Recoverable current snapshot; fresh regression result; app-interface observations |
| T1 — Incremental command decisions | Implemented; app-spacing/revision regression repaired | Revision/boundary/intent fixtures with no external effects |
| T2 — Listen and execute together | Repaired; user confirms launch + new-document before Fn release; full continuation/release validation ongoing | Session tests plus first physical action before Fn release |
| T3 — Stop and launch corrections | Implemented; race/policy tests pass; OS validation pending | Race tests and actual reversible launch/focus outcomes |
| T4 — Installed-app workflows | Implemented; packaged OS acceptance pending | Disposable TextEdit, Chrome, and Spotify flows verified externally |
| T5 — Review and delivery | Independent review repaired; package/live validation ongoing | Packaged regression, live checks, timing report, rollback |

## Working approach for Astra

Follow EXECUTION.md for autonomy and proportionate verification. The required outcomes and acceptance matrix are fixed; private types, file splits, scheduling, and timing heuristics are implementation choices. Inspect relevant code, choose the simplest reliable approach, and record material departures with evidence. Checkpoints are brief progress reports, not automatic approval stops. Load a specialized skill only when its workflow helps the current task; do not impose a mandatory stack of skills, per-step commits, or repeated full-suite runs.

This structure applies the official [Astra prompting guidance](https://developers.openai.com/api/docs/guides/latest-model#prompting-best-practices) and [guidance on reducing over-prescriptive skills and prompts](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra), rechecked on 2026-09-18. Those sources guide the implementation agent; they do not establish our product architecture or performance.

## Global constraints

- Preserve the current working UI, command functionality, uncommitted work, Keychain credentials, preferences, clipboard behavior, bundle ID, installed path, and macOS 13 target.
- No new package dependencies by default; no gaze, wake word, always-on capture, TTS, additional reasoning model, or Cua/VM integration in this extension.
- Ordinary validated commands run automatically when the existing preference is enabled. Manual mode prevents all early effects. Deletion/purchasing remain unsupported.
- Only one Fn session and one serial desktop-action queue; capture can continue during execution.
- Plans may adapt to evidence; product scope and acceptance cannot be silently weakened. Record decisions and evidence here. No application changes are part of this documentation-only update.

## Review focus

1. Partial recognition rewrites already-dispatched words: no duplicate effect, but intentional repeated commands still work (T1/T2).
2. Correction arrives during a launch or after an app was already open: compensate only the owned effect, with no force quit or document loss (T3).
3. User moves focus or an app opens a different window: text/shortcuts never land in an unrelated target (T4).
4. “Stop,” app names, and conjunctions occur inside dictated content: preserve literal text while retaining Escape cancellation (T1/T2).
5. Capture fails or final text arrives after some successful actions: report partial completion and review only remaining work (T2/T5).

## Evidence and design decisions — 2026-09-18

- The reference clip was inspected through browser frames, captions, and its live transcript. Notes opens around 5 s; a new note is visible around 8.5 s; its title is populated by 12 s. Arc/search and X navigation follow; Photo Booth opens and a shutter countdown/photo follow. These are recording positions, not measured runtime latency. The relevant behavior is incremental instruction execution with context, in-app actions, and a small overlay. Internal model calls and automation mechanisms are unknown.
- Read-only source inspection: `VoiceController.receive` currently displays partial text and submits final text after release; its single `Status` makes capture and execution exclusive. `SpeechEvent` already carries partial/final events. `Executor.execute` returns a string and does not capture pre-action state. `Action` has launches, URLs/searches, dictation, and system commands, but no create-document or browser-scroll/back capability. These facts justify T1–T4; streaming is not already implemented.
- Filesystem inventory confirms Google Chrome, Spotify, Discord, TextEdit, and Calculator are installed. This proves availability, not login, permissions, accessibility quality, or automation support. Probe those interfaces during T0/T4 before choosing execution mechanisms. Use Chrome, TextEdit, Spotify, and Calculator in required workflows; Discord is available for a variation in app navigation, not for sending messages.
- User correction: if an app opens before “actually, don't,” undo the launch. Implement that useful behavior directly with the bounded ownership rules in C3, rather than delaying every app launch until release.
- Keep literal content ownership through release; do not infer command boundaries inside arbitrary content. The later user request below adds live text updates within that literal payload. New in-app actions use reusable capabilities with varied arguments rather than copying the exact Notes/Photo Booth demo.
- Existing evidence (116 tests and earlier physical checks) belongs to the prior package. It is not evidence that this extension works.

## T0 — Preserve the working baseline and probe capabilities

**Entry points:** begin with `Sources/JevVoice/VoiceController.swift`, `Sources/JevVoiceCore/CommandInterpreter.swift`, and their existing tests. Follow relevant calls into speech, input, executor, planner, presentation, or packaging only as needed. Update evidence in this file; do not perform a fresh whole-repository audit.

- [x] Snapshot the current source, including untracked files, and the current installed app to a new dated rollback directory. Do not reuse the pre-UI archive as the only recovery point or export secrets.
- [x] Run `swift test` and `swift build -c release`; record failures, durations, and the exact source state. Inventory current permissions without resetting them.
- [x] Identify existing coverage relevant to the changed path, including conditional composition, literal dictation, merged navigation, and session cancellation. Reuse it. Change only assertions superseded by the new behavior; add tests for uncovered risks instead of recreating the original suite.
- [ ] Probe TextEdit new-document and addressed insertion, Chrome target/tab identity, scrolling and back navigation, and Spotify activation/minimize/restore using disposable state. Record interface support, required permissions, and observable success signals. Do not assume scripting support or invent keyboard shortcuts. No messages, purchases, or personal documents in probes.

**Checkpoint:** current app still works, recovery verified, proposed execution mechanisms grounded in this machine. A failed required capability is repaired or explicitly reported; do not silently replace its acceptance test with app launch.

## T1 — Decide when a command is complete

**Files:** add `Sources/JevVoiceCore/IncrementalCommandCoordinator.swift` and `Tests/JevVoiceTests/IncrementalCommandCoordinatorTests.swift`; modify the existing interpreter/planner/splitter only where needed. These filenames are proposed boundaries, not a requirement to create redundant layers.

**Contract:** consumes session ID, monotonic time, ordered transcript revisions, finalization/cancellation signals, execution receipts, and external target context. Produces identified pending/ready/cancel/correction decisions. It owns no microphone, UI, or OS effects. Each command has an ID independent of raw transcript text, prerequisites, revision provenance, and pending/dispatched/completed/failed/cancelled/compensated status. Reconcile final text with that history rather than slicing blindly at old character offsets.

- [ ] Add failing behavioral fixtures for the cases below before implementing boundary/identity logic. Use an injected clock and fake interpretation; no real model or desktop in unit tests.
- [ ] Reuse deterministic whole-clause app routing and existing typed Jev decisions. For streaming, consider available full context so a local phrase does not discard conditions. Coalesce superseded pending interpretation; keep at most one active incremental interpretation and the latest waiting revision. Cancellation/stop detection must not wait behind a slow model response.
- [ ] Combine semantic completeness with observed stability/boundary signals. Choose and measure any stability window against actual partial-recognition behavior; elapsed time alone is not evidence that a command is complete. Missing slots/ambiguous target/condition hold the command; never issue Jev for every audio buffer or identical partial.
- [ ] Track literal-content mode and filler/no-action outcomes. Preserve existing full-transcript regression behavior. Keep the coordinator small; do not add a second language parser or general workflow engine.
- [ ] Run `swift test --filter IncrementalCommandCoordinatorTests` and relevant interpreter/planner regressions. Record the chosen boundary policy and failed alternatives only when they explain the decision.

| Input fixture | Required result |
| --- | --- |
| `open` → `open Google` → `open Google Chrome` | No ambiguous launch; once eligible, Chrome at most once |
| Complete open-app clause → continuation → repeated partial → matching final | One launch, continuation preserved, final never replays |
| `if …` / `don't open …` / `can you …` / filler | Conditions and negation respected; natural command wording supported; filler no-op |
| `search for red` → `search for red pandas` without a completed boundary | No premature truncated search; one correct final query |
| Two separately completed `scroll down` requests | Two intentional actions, without duplicating either on transcript replay |
| `type hello and quit Spotify` / `type stop` | Entire suffix literal content; no quit/stop effect |
| Old interpretation completes after replacement/cancel | Discarded, never dispatched |

**Checkpoint:** show fixture evidence for readiness and deduplication; this checkpoint alone does not establish microphone latency or physical usability.

## T2 — Capture and serial execution in one session

**Files:** `Sources/JevVoice/VoiceController.swift`, `SpeechRecognizer.swift` only if event metadata is needed, `FnInput.swift` if readiness assumptions need adjustment, `VoiceWindows.swift`, `ContentView.swift`, and `Tests/JevVoiceAppTests/VoiceSessionTests.swift`.

**Contract:** retain `SpeechCapturing` begin/finish/cancel semantics and session-tagged callbacks. Separate capture state from execution progress in the controller, without duplicating ownership in views. Dispatch identified ready actions through one queue and feed receipts back to T1. A new Fn hold cannot overlap cleanup of the previous hold.

- [x] Add failing session tests: execution while partial events continue, release while an action runs, final deduplication, stale callbacks, manual mode with zero early effects, old hide timer during capture, and a second hold during cleanup.
- [x] Wire partial events into T1 while waveform/transcript continue updating. Finalize only uncommitted work. An action finishing while Fn is held must not stop capture or hide the pill.
- [ ] Preserve local app resolution, typed Jev, key/config handling, off-main-thread process waits, and conditional clipboard restoration. At every await/dispatch boundary recheck action/session validity.
- [ ] On timeout/early-final/error/55-second limit, stop pending automatic effects, keep completed receipts, and review only the remainder. Add tests where one action already completed before each failure. Empty remainder must never cause a replay.
- [ ] Show listening plus current action/correction in the existing pill; reuse expanded Activity for detail. Run `swift test --filter VoiceSessionTests` and `swift test --filter FnInputTests`.
- [ ] With the packaged app and physical user input, hold Fn, request Calculator, continue talking after it opens, and release. Verify Calculator appears before release, the final word survives, and release does not reopen it. Ask only for physical input/OS grants the agent cannot supply.

**Checkpoint:** first genuine early effect while capture stays active. Continue independent work while optional user feedback is pending; label physical evidence separately.

## T3 — Stop and compensate recent launches

**Files:** `VoiceController.swift`, `Executor.swift`, T1 coordinator, new `Tests/JevVoiceAppTests/LaunchCorrectionTests.swift`, and existing executor tests. Add a small action-receipt type near the executor if needed.

**Contract:** execution returns action ID, dispatch/outcome status, resolved app identity/process instance, prior running/hidden/frontmost state, and any created target identity. A reversal checks that receipt and current state; it does not infer ownership from the app name or blindly call the existing substring-based app lookup. Report quit-requested separately from observed termination.

- [ ] Write controlled tests for correction before dispatch, during delayed launch, after launch, after dependent editing, after external focus change, already-running target, refused termination/save dialog, and replacement command arriving before compensation completes.
- [ ] Implement spoken stop outside literal content as queue/model cancellation while capture continues. Keep Escape/pill Stop as whole-operation cancellation. Test `stop … open Calculator` in one hold, with no resumption of the cancelled queue.
- [ ] Implement normal quit for an eligible newly launched app, and prior visibility/focus restoration for an already-running one. Never force terminate or discard work. Observe termination/restore with a bounded timeout and honest failure text; do not interpret an accepted quit request as completed undo.
- [ ] Serialize launch completion, correction, and replacement so a late launch cannot escape reversal or overtake the replacement. Guard compensation against double execution and reused PIDs/app instances.
- [ ] Run `swift test --filter LaunchCorrectionTests` and existing executor/session tests, then demonstrate both initially-closed and already-running Calculator cases. Use an unsaved disposable TextEdit document to verify that refusal/save UI is retained rather than automatically dismissed.

**Checkpoint:** say a launch and immediately retract/replace it; verify before-dispatch cancellation and after-dispatch reversal. Existing user work remains intact without an approval dialog for routine correction.

## T4 — In-app workflows on this Mac

**Files:** `Sources/JevVoiceCore/{Command,CommandInterpreter,CommandPlanner,SlotExtractor}.swift`, `Sources/JevVoice/Executor.swift`; extract `NativeAppActions.swift` if the executor becomes unwieldy. Extend core tests and add `Tests/JevVoiceAppTests/NativeAppActionsTests.swift` for target/readiness/error boundaries.

**Contract:** typed create-document, bounded-scroll, and browser-back capabilities carry explicit resolved target identity and prerequisites. T0 chooses the working native mechanism. Executor returns created document/window or navigation outcome where observable. Keep model output as typed choices/arguments, never arbitrary shell or generated script execution.

- [ ] Add failing tests for new-document context propagation, failed prerequisite, browser identity, unknown scroll target, readiness timeout, and external focus changes. Validate both command interpretation and executor routing, not only fabricated actions.
- [ ] Implement TextEdit create-document plus targeted insertion. Wait for that new editable document to be ready; never overwrite the previously open document. Show partial insertion in supported native editable fields, reconcile only the owned insertion, and finalize without replay; preserve final-paste/clipboard behavior for unsupported fields and manual mode.
- [ ] Implement bounded Chrome scrolling and browser back, targeting the intended browser window/tab. Preserve the merged one-search-tab behavior and explicit separate-tab requests. A focus mismatch or unavailable AX target fails clearly instead of falling back to global keystrokes.
- [ ] Verify existing Spotify minimize/restore paths using its observed window state, fixing regressions needed for the matrix. Playback/login/account integration is not required for this extension.
- [ ] Execute the installed-app matrix below using disposable material; inspect actual external state. Use live Jev calls only for representative model-routed commands, and label fixtures as simulated.

**Checkpoint:** complete actual workflows, not just launches. Show the user a short successful sequence with our current pill; retain test variations and failures in evidence.

## Installed-app acceptance matrix

Every row starts unverified. Example words define outcomes, not an exact-phrase whitelist. Run each principal flow with at least two paraphrases and different disposable content; verify cold launch and already-running state where applicable. Record concrete observations rather than checking boxes from screenshots of the pill alone.

| ID | Workflow | Required external evidence |
| --- | --- | --- |
| A1 | Hold Fn: open TextEdit, create a new document, then type `The blue notebook is on my desk`; release | App/document preparation and visible partial dictation occur before release; final text reconciled once into the new document with no duplicate insertion; existing document unchanged |
| A2 | Open Google Chrome and search Google for `red panda habitat`; release after query | Correct query in Chrome, one new results tab for the compound search, no extra blank/homepage tab; already-open tabs intact |
| A3 | In that controlled browser context, open a harmless public page with enough content, then request a small downward scroll, then go back | Target viewport changes; back returns to known prior page; no other app receives scrolling/shortcuts. A single finite scroll, not a new continuous-scroll mode |
| A4 | Open Spotify, minimize its window, then bring it back, all in one hold | Ordered visible transitions, final Spotify window restored; no account/login/playback assumption; capture stays active |
| A5 | Initially closed Calculator: open it, then immediately say `actually, don't`; repeat after deliberately allowing launch | First test cancels pending launch or safely reverses a race; second observes normal quit, with no duplicate action on release |
| A6 | Already-running Calculator: switch to it, then retract; repeat with `actually, open Chrome instead` | Calculator session survives retraction; prior focus restored when appropriate; replacement ends in Chrome |
| A7 | Queue a delayed action, say `stop`, then request another app without releasing Fn | Cancelled work never resumes; listening continues; new command works once. Fake latency plus benign actual-app check distinguished |
| A8 | In new TextEdit document, `type hello and quit Spotify`, then separately `type stop` | Payloads inserted literally; no unintended quit or cancellation |
| A9 | Praise/filler, pause, partial correction, release on last word; repeat a supported command intentionally | No filler action, no clipped payload, no replay on release, intentional repeats preserved |
| A10 | Manual auto-execute disabled; timeout/network failure/mic interruption after one committed action | No early side effects in manual mode; failure accurately reports completed vs pending work; transcript review never replays. Restore original preference |

## T5 — Review, timings, packaging, and honest delivery

**Files:** review the complete diff; update this progress/evidence log and `README.md` only after working behavior exists. Preserve the existing build/signing path in `Makefile`.

- [ ] Review for duplicate/revised actions, dropped conditionals, literal-content splitting, focus theft, racey compensation, main-thread blocking, unbounded model calls, permission churn, and accidental preference resets. Simplify unnecessary abstractions and repair findings.
- [ ] Measure with monotonic timestamps: Fn-to-overlay, microphone ready, first relevant partial, command eligible, interpretation, queue wait, dispatch, external readiness, release-to-final, and correction-to-observed-reversal. State what was directly observed versus inferred. Capture no raw audio or private text in diagnostics.
- [ ] Compare the unchanged baseline and new package on the same simple-launch and compound-search workloads, identifying fresh launches versus already-running apps. Collect at least five warm trials per representative flow plus an initial startup trial; report counts, median, range, errors, duplicates, and corrections. No percentile claims from these small samples.
- [ ] Keep the existing 100 ms overlay target. Use an initial engineering target of at most 500 ms from eligible complete local launch command to dispatch in warm runs; model-mediated commands are measured separately. Boundary waiting and STT delay must be reported separately so that eligibility timing cannot conceal perceived lag. This target is a proposed tuning goal, not a measured claim or evidence from the X video. Correctness and visible pre-release progress are hard acceptance requirements; document any target miss instead of guessing early.
- [ ] Run `swift test`, `swift build -c release`, and `git diff --check` after fixes. Re-run only checks justified by subsequent changes/failures. Package once ready using `make app APP="$HOME/Library/Caches/JevVoice/build/Jev Voice.app"`, verify with `codesign --verify --deep --strict --verbose=2 "$HOME/Library/Caches/JevVoice/build/Jev Voice.app"`, and launch that exact bundle.
- [ ] Validate the installed package through A1–A10, distinguishing unit simulations, agent-observed app state, and user physical keyboard/microphone evidence. Required unverified/failed flows remain open; do not call launch-only success a complete delivery.
- [ ] Record source/binary identity, test results, timing samples, real-model coverage, remaining hardware/OS limits, rollback location, and source restore instructions that preserve unrelated work. Final handoff gives app location, how to use/stop/correct it, measured results, and known limits.

**Scope/coverage audit:** C1 → T1/T2/A1/A2/A7–A10; C2 → T4/A1–A4/A8; C3 → T3/A5–A7; C4 → T2/T5/A9/A10; C5 → T0/T4/T5. Active tasks are all planned; no new tests, app interactions, or runtime improvements are claimed by this documentation update.

## Current implementation evidence — 2026-09-18

### Repair after failed physical continuous-control test

- Subsequent physical test: user reports the full TextEdit workflow inserted text but only after release. That is a real expectation gap: the earlier plan explicitly deferred literal text. User now requests live dictation. SPEC C1 updated to allow bounded native edits with no replay, preserving literal semantics and final-paste fallback where addressed revisions are unavailable.
- Preserved the physically working early-command release and source in `/Users/karanvirkang/Library/Caches/JevVoice/rollback/before-live-dictation-20260918/` before live-dictation changes.
- Native mechanism: Apple's `kAXSelectedTextAttribute` and `kAXSelectedTextRangeAttribute` provide addressed text/selection controls, checked for actual writability. An owned-insertion tracker verifies complete surrounding text plus UTF-16 caret offset before changing only that insertion. No global backspace sequence, clipboard overwrite, full-document replacement, or extra model call is used for live edits. Native verification remains required; API documentation alone does not establish app support.
- Live-dictation tests: **154 total passed, 10.15 s** (`jev-live-final-tests.log`). New tests cover owned insertion/revision/removal, preservation of prefix/suffix, UTF-16 emoji offsets, external edits/caret changes, partial updates, no final paste, manual mode, unsupported-field fallback, in-flight finalization, changed dictation intent, and failure recovery without replay. The emoji-boundary test initially failed and was repaired before packaging.
- Live-dictation release: build **18.82 s**, strict/deep signature verification and diff whitespace check passed; normal package excludes the probe. Binary SHA-256 `f146652a14ed9ebc33ac36473a71300f6140d116a024a399124d3eb7457c6866`. Follow-up Fn tests **8 passed** after changing only the “release to finish” help text. Same canonical installed app path and preserved preferences/Keychain.
- Native UI of this new binary shows all three permissions unavailable, including Accessibility; unchanged relaunch did not resolve it. Asked the user to grant the current rebuilt app and test visible partial insertion in a blank TextEdit document, a mid-sentence pause and no final duplicate. This is an external macOS gate, not passed native validation. Do not claim live typing delivered until actual text is observed.

- Real Apple Speech replay with simulated native text updates: first payload update at **10.456 s**, then `the blue`, `the blue note` → `the blue notebook`, `... is on`; synthetic release at **11.629 s**, final suffix at **11.699 s**. This establishes pre-release controller updates and recognition-revision handling, not successful TextEdit writes. No cloud/model invocation or live microphone capture in this diagnostic.


Durable repair evidence: `/Users/karanvirkang/Library/Caches/JevVoice/verification/speech-repair-20260918/`. Logs contain only synthetic test utterances; no microphone recording or credentials were exported.

- User reported that “open TextEdit” did not execute while Fn was held and later speech replaced that command. Treat A1/T2 as failed, not accepted. The user need not distinguish “TextEdit” from “text edit.”
- Recovery before this repair: `/Users/karanvirkang/Library/Caches/JevVoice/rollback/speech-repair-20260918-224148/` holds the complete source snapshot including prior uncommitted continuous-control work and the previous installed app. No credentials/preferences exported or changed.
- Actual local Apple Speech audio-buffer recognition on macOS 26.2, using generated disposable audio in real time, emitted `Open text edit`, then timed `Open TextEdit`, then replaced its entire hypothesis with `Create…`, and later `Type…`. Interim segments had zero timing; timed non-final phrase results appeared before each reset. This is observed behavior on this Mac, not a documented universal Speech API guarantee. Raw synthetic trace: `jev-speech-fixture-baseline.jsonl` in the repair evidence directory.
- Repairs: whole installed-app names match across spoken word spacing while ambiguous collisions remain rejected; a small transcript accumulator preserves confirmed phrases and literal payloads; committed-prefix matching tolerates spacing revisions; phrase boundaries feed the existing splitter. A stable command's 300 ms timer no longer restarts when only later speech changes. No added model or dependency.
- Regression tests first reproduced the spacing and timer failures. Full updated suite: **146 tests passed, 9.55 s**, including replay of the observed phrase sequence through the real interpreter/controller with simulated execution. Manual mode, cancellation, stale responses, payload isolation and final deduplication remain covered. These tests do not establish physical keyboard/microphone or native outcome acceptance.
- Real-ASR dry runs with 3-second and 0.5-second inter-command pauses each dispatched TextEdit launch and new-document before synthetic release, then exactly one dictation after finalization; no launch replay. The short-pause run misrecognized “a silver” as “for silver”; that STT accuracy limitation remains, rather than silently correcting the user's payload.
- Six repeated synthetic `Open text edit` recognizer launches each produced exactly one action and completed. First trial: full partial to simulated dispatch **323 ms**. Subsequent five: median **317 ms**, range **313–326 ms**; recording start to dispatch **1.788–1.839 s**. These are real recognition plus simulated dispatch, with warm system recognition resources across fresh probe processes. They exclude microphone startup, physical Fn, native app readiness, and network inference. No claim of matching the reference demo's latency. See `jev-launch-trial-0` through `-5.jsonl`.
- Developer-only `SPEECH_FIXTURE_PROBE` build feeds generated PCM through the production speech-result adapter/controller and real interpreter. Dry runs use a non-network client and simulated executor; a separate visible Run button initiates native execution. It uses an isolated preferences suite, loads no Keychain credential, captures no microphone, and is excluded from normal builds.
- Native fixture attempted the normal executor: launch completed, then creating a document failed with **Accessibility permission is needed for this action**. Probe reported `AXIsProcessTrusted=false`. Do not mark TextEdit insertion, browser control, or launch reversal accepted. Removed an unnecessary 2-second AX-readiness wait when Accessibility is absent; ordinary launch does not need that permission, dependent controls still fail clearly.
- Final normal release built in **20.60 s**, packaged at `/Users/karanvirkang/Library/Caches/JevVoice/build/Jev Voice.app`, and passed strict/deep codesign verification and `git diff --check`. Binary SHA-256: `86e9aad842202288d3406412e66f4159556e1abeb9d0b81acc646824876eff31`. Symbol/string inspection confirms the developer fixture entry points are absent from this package.
- First launch of this package ran an AppKit loop but exposed no settings through CUA. Relaunching the identical binary resolved it; native UI inspection then showed Voice settings, **System Default — MacBook Pro Microphone**, and all three permission indicators granted. No permission reset/change was performed. The earlier diagnostic build's denied Accessibility is not the final release's current permission state. Physical Fn/new-document acceptance is pending; no success inferred from the indicators.
- Physical retest on the final repaired package: user reports **both TextEdit launch and new-document happened before Fn release**. CUA independently observed `Untitled 2`, with its blank editable text view focused. This establishes the reported T2 preparation behavior; it does not yet establish A1 dictation/no-replay or A2–A10. Asked for the full TextEdit hold plus final dictation and visible Activity so actual decisions/timings can be inspected.
- Previous main-process sample now showed normal AppKit event-loop activity, not a Keychain wait. No signing identity is installed; the unchanged ad-hoc signing workflow can require user permission reconciliation after rebuild. No TCC reset/security changes performed.


- Recovery: `/Users/karanvirkang/Library/Caches/JevVoice/rollback/continuous-20260918-213046/` contains a verified 54-file source archive, baseline patch/manifest, and copied installed app. No credentials exported. Checkout was clean on `codex/voice-ui-push-to-talk` at this run's start.
- Fresh baseline: 116 tests passed in 5.50 s (`/tmp/jev-continuous-baseline-tests.log`); release build passed (`/tmp/jev-continuous-baseline-build.log`).
- Native probe: TextEdit exposes New Document, File > New, a settable text area, and window controls. Chrome exposes target window/tab, Back button, and web content. Probes used the native UI; they are evidence of available controls, not proof of the new executor.
- Added coordinator fixtures first; initial compile reported the absent coordinator. Implemented prefix ownership, pending revision handling, literal protection, and controls; 7 fixtures pass. A changed dispatched prefix stops rather than guessing or replaying. This conservative recovery is intentional.
- Session test first observed zero early actions; after controller integration, early action while listening and final deduplication pass. Native-chain test initially attempted a network call; local finite-action routing now preserves TextEdit/Spotify context offline.
- 21 focused interpreter/session/correction tests pass, including delayed-launch reversal and stop overtaking an uncooperative delayed interpretation (`/tmp/jev-correction-tests.log`). These are simulated dependencies, not physical Fn/voice or native quit proof.
- Ruling: keep capture represented by Listening while a serial worker publishes action progress in the existing detail field. This reuses the pill without a second UI state machine. Literal dictation and unbounded trailing queries wait for finalization; finite commands can run after a tunable 300 ms stability interval. Semantic completeness still gates eligibility.
- Live TypeSafe API/Choice docs fetched with curl after the web tool failed. Existing endpoint/model and parallel typed-question structure remain unchanged; added native capabilities are bounded choices, never generated scripts.

- Independent final review found a release/finalization race, premature recovery while native work remained active, literal/search control parsing bugs, explicit/default-browser context errors, and missing browser-tab validation. Reproduced the release and payload failures before repairing them. Gated session tests now cover release during execution and early-final recovery before a new hold; parser fixtures preserve polite literal commands, search words, and punctuation. Full suite after the first fixes: **133 passed, 8.29 s** (`/tmp/jev-continuous-review-all.log`). Additional context/deadline focused run: **39 passed, 4.73 s** (`/tmp/jev-review-context.log`). These are simulated evidence.
- Chrome native observation exposes window URL, selected tab, Back, and web content. Native targeting now preserves window/tab identity and rejects intervening external keyboard/mouse input. Back waits for observed URL change. Default-browser navigation resolves the actual registered browser instead of assuming the old foreground app; follow-up targeting is unavailable until readiness is observed. Restore retains the known minimized window.
- Packaged build and strict/deep signature validation passed. Launch reached the existing Keychain read, where a process sample shows `SecItemCopyMatching` waiting for macOS authorization; the settings UI has not opened. Asked the user to handle that prompt and then perform the first real Fn/TextEdit check. No trust settings, permissions, keys, or microphone preferences changed.
- Existing Activity measurements extended with first partial, eligibility, queue delay, eligible-to-dispatch, and correction-to-reversal durations. They are monotonic session measurements, not yet physical timing samples. Settings copy now describes early execution; no layout redesign.
- Ruling: a committed normalized-word prefix plus serial session ownership replaces the proposed general action-record framework. Revised committed words fail clearly instead of guessing or replaying; native launch receipts retain process/window ownership for compensation. Cost: corrections to already-dispatched recognition require a new hold, and this is not a general undo engine.
- Open validation: A1–A10 remain unaccepted for this package. Native control availability is observed; actual executor outcomes, physical Fn/audio, live Jev calls, repeated warm timings, and OS regrant behavior are not established by unit tests. Preserve this distinction at delivery.

### Current handoff checkpoint — live acceptance blocked

- Final reviewed source: baseline commit `75c2434d5eb51cd484804451de2fb1efa6f74486` plus the current uncommitted feature diff and new files. Source manifest SHA-256 `c8a05a27849f14d929aa75d227975314c5ce70e31e052686ce91e0c382f72bd4`. Packaged executable SHA-256 `3d747b2cdf83d1ab68d5c9c4a6f89891c387189f3360faf26c8b03236e911084`.
- Final verification: **139 tests passed, 0 failures, 9.03 s**. Release/package build **18.39 s**. Strict/deep codesign validation and `git diff --check` passed. Final logs, regression reproductions, source manifest, and binary identity are in `/Users/karanvirkang/Library/Caches/JevVoice/verification/continuous-20260918/`.
- Additional review repairs: a newer stop during compensation cancels the older replacement (observed RED→GREEN); automatic-execution policy is frozen per hold so changing the preference cannot replay committed work (RED→GREEN); a native failure during recognition recovery is reported rather than becoming Done (RED→GREEN). Reused the existing app inventory instead of maintaining two caches; removed an unreachable automatic branch from the manual path.
- The **final** package at `~/Library/Caches/JevVoice/build/Jev Voice.app` was launched with `--settings`. A fresh one-second process sample still shows startup waiting in `SecItemCopyMatching` for access to the existing key. User response to that macOS prompt is required; do not request their password or export the key. No physical test response was received for this implementation run. Native UI automation also disconnected during the last app inspection, so its availability must be rechecked before further agent-operated OS checks.
- No A1–A10 packaged acceptance row is marked passed. Real speech/OS timings, five-trial comparisons, actual launch reversal, new-document insertion, Chrome scroll/back, Spotify restoration, and representative live Jev calls remain unverified. The 300 ms stability interval is a configured default, **not a measured end-to-end latency**. The source README remains unchanged until acceptance, as required by SPEC.md.
- Intended usage to validate: hold Fn; give a complete app command, pause briefly for the visible action, continue with dependent commands, and release to finalize text/query payloads. Say “actually, don't” or “actually, open Chrome instead” for the latest eligible launch; say “stop” to clear pending work while continuing the hold. Escape/pill Stop cancels the whole operation. Literal type/write content owns the remainder through release. Changed committed recognition fails clearly rather than replaying.
- Rollback: quit Jev Voice; move the new installed bundle aside; copy `Jev Voice.app` from `/Users/karanvirkang/Library/Caches/JevVoice/rollback/continuous-20260918-213046/` to the same installed path. Extract that directory's `source.tar.gz` into a separate folder and compare before restoring source, preserving subsequent edits. Credentials/preferences were not changed; macOS may request authorization for a restored ad-hoc binary.

## Reference-only historical evidence

Consult only to investigate a specific regression, compare a measurement, or locate rollback material. Earlier completed milestones are not implementation tasks, and earlier passing tests do not establish that new behavior works.

<details>
<summary>Prior UI delivery, verification limits, and rollback records</summary>

### Prior milestone status

| Milestone | Status | Evidence |
| --- | --- | --- |
| 0 — Baseline | Source/build baseline verified; physical command baseline not repeated | Fresh 84/84 pass; release build passes. Recovery details below. |
| 1 — Input/capture | Implemented; basic physical path passed | Fn/session/device tests pass. Actual MacBook microphone meter works; user reports successful Calculator command after HID watchdog repair. Paused phrase, trailing word and Fn-arrow check confirmed by user. |
| 2 — Execution | Implemented and demonstrated | Session/cancellation/process tests pass. Calculator, merged Google search and literal TextEdit dictation demonstrated. Physical clipboard/quit timing remains unverified. |
| 3 — Presentation | Implemented; native UI exercised | Settings, real mic meter, permission readiness, Activity and target-preserving TextEdit dictation observed. Fullscreen/multiple displays and direct capsule-click focus measurement remain unverified. |
| 4 — Delivery | Delivered; extended coverage limits recorded | 110 tests pass; warning-free release; signature valid. Independent review found no remaining actionable defects. |

Initial decision, 2026-09-18: preserve the current backend and platform target; extract bounded FluidVoice presentation; prove input/capture and execution before polish. Keep this table and a concise dated decision/evidence log here during implementation. Record the reason and affected requirement when changing an approach; do not manufacture completed evidence or duplicate the specification.

### Implementation log — 2026-09-18

- Verified recovery archive: `/Users/karanvirkang/Library/Caches/JevVoice/rollback/20260918-195635/source.tar.gz` (43 source files, including untracked work), `baseline.patch`, manifest, and copied `Jev Voice.app`. Existing credentials remain in Keychain; no credential export.
- Baseline: `swift test --quiet` → 84/84 pass (`/tmp/jev-ui-baseline-tests.log`); `swift build -c release` → pass (`/tmp/jev-ui-baseline-build.log`). One built-in 2560×1600 display and MacBook Pro microphone (48 kHz) available; no AirPods/external display connected.
- Ruling: implement in the requested checkout on a new branch, with the verified snapshot, rather than a HEAD-only worktree that omits the working baseline. Use this plan as the sole progress record, following the approved execution brief.
- Fn event logic: tests first exposed missing implementation; six now pass covering duplicate events, busy holds, combinations, Escape pairs, and interruption. Physical key behavior is not yet verified.

- Session/capture/execution: deterministic tests cover release-before-start, early final, timeout, late callbacks, stale model response, duplicate Run, forced confirmation, cancel between actions, silence, maximum duration, and old dismissal timers. Microphone resolution tests cover stable UID and unavailable selection. Overlay geometry tests cover negative display coordinates, growth anchoring and bounds. `swift test` passed 109 tests (`/tmp/jev-ui-final-tests.log`, 6.361 seconds suite wall time); these are simulated boundaries, not physical microphone/keyboard evidence.
- Independent read-only review found Escape repeats leaking after cancellation, reverse-order Fn combinations arming, and interrupted empty transcripts silently dismissing. Added failing regressions, repaired all three, then reviewer verified fixes. Core Audio SDK confirms caller-owned UID/name CFStrings; switched to `Unmanaged.takeRetainedValue()` to remove the compiler warning and honor ownership. No new package dependencies.
- Real packaged microphone test initially failed because setup generated a configuration-change notification. Skip redundant device assignment; validate live engine/device/format before treating a queued notification as loss. Retest showed **Listening to MacBook Pro Microphone** with a **23%** real meter reading. Test captures audio locally only; no transcript/model call. This is not spoken-command accuracy evidence.
- Native settings and Activity inspected through macOS accessibility/screenshot tools. Permission rows refresh to actual granted state. Ad-hoc rebuilds still require macOS permission reconciliation; no TCC reset, trust modification, or credential changes performed.
- First physical Fn attempt reported failure. Activity showed **The Fn release was missed** before any transcript. Corrected watchdog to hardware (`hidSystemState`) rather than consumed session-event state, and require an observed hardware hold before inferring a missing release. Basis: Apple's [event state documentation](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid). Physical retest required; do not count mocked transitions as proof.
- Packaged app includes bounded FluidVoice adaptation notices/license in Resources. Release build and `codesign --verify --deep --strict` pass. Real UI inspection runs against the intended installed path; initial and subsequent speech latency remain unmeasured until successful physical capture.


### Final package and demonstrated evidence

- Source review: independent reviewer rechecked the three original fixes, notification filtering, CF ownership, hardware watchdog, and cleanup error retention. No remaining actionable findings in those reviews. Removed unused controller/window methods; no general-purpose framework or added dependencies.
- Final automated suite: **110 tests, 0 failures**, 7.388 seconds (`/tmp/jev-ui-final-tests.log`). Original 84 regression tests remain green. Release compile: **21.39 seconds**, no warnings (`/tmp/jev-ui-final-build.log`). Final package log: `/tmp/jev-ui-final-package.log`; strict/deep signature verification passes. `git diff --check` passes.
- Final binary SHA-256: `793834e68937a4623640ef50c155623c4a81c9d3dc5cff80af245f88183e75c8`. App: `/Users/karanvirkang/Library/Caches/JevVoice/build/Jev Voice.app`. Launched successfully; final settings screenshot shows visible Voice heading, cards, picker, test meter, and permission controls. Existing API key was never edited/exported; command preferences remain unchanged.
- Physical retest after HID repair: user reports Calculator command worked. Activity independently showed complete transcript **Open calculator**, decision **Open Calculator**, Jev **1.13.0**, 93% confidence, and successful dispatch timing. Calculator's app contents were not independently inspected after the user's test.
- Monotonic timings for that single successful run (first demonstrated run after relaunch; no measured pre-change timing baseline): overlay presentation **43 ms**, microphone ready **449 ms**, release-to-final **185 ms**, interpretation **420 ms**, action dispatch **330 ms**. Overlay timing measures the app's presentation call, not a high-speed camera's first visible pixel. One sample does not establish a distribution or universal latency. Recording onset still requires waiting for Listening.
- Startup interruption now retains its error after asynchronous cleanup instead of returning to a misleading Ready state; regression passes. Settings navigation returns to the visible heading. Final configuration observer accesses engine only on main actor; no Sendable warnings.

### Verification limits and remaining physical checks

- Final packaged pause/trailing-word, merged navigation, and Fn-arrow checks passed by user report. Physical dictation into the originally targeted TextEdit document passed; the agent did not directly observe the user’s confirmation click or measure focus during that click. Physical clipboard cleanup, physical Escape, secure-input/tap-disable/sleep recovery, fullscreen/Spaces, Reduce Motion/Transparency, device disconnect/format switch remain unverified in this run. Automated tests cover their applicable logic boundaries, not these OS interactions.
- One built-in display and MacBook microphone exercised. AirPods, external monitors, and macOS 13 runtime unavailable; no pass claimed. Build retains macOS 13 deployment target.
- Hardware polling can detect a missed release only after the HID state reports the physical Fn hold. Keyboards that never report it still have the 55-second capture bound, but missed-release detection on those keyboards is not verified.
- Ad-hoc signing may require a macOS permission regrant after binary replacement. No stable signing identity exists on this machine; no trust/security settings were changed automatically.
- Do not mark the entire acceptance matrix complete from the basic Calculator test. Browser/search and literal-dictation/core regressions pass automated tests, but that does not independently establish every listed live app flow.

### Rollback

Quit Jev Voice normally first. Move the current installed app aside, then copy `Jev Voice.app` from `/Users/karanvirkang/Library/Caches/JevVoice/rollback/20260918-195635/` back to the installed location. The rollback source archive includes the user's pre-feature uncommitted work; extract it into a separate folder for inspection/restoration rather than resetting this checkout or deleting later changes. Keychain credentials were not changed. The new microphone UID preference is additive; System Default remains selected. macOS may require reconciling Accessibility for the restored ad-hoc binary.

- Final packaged physical follow-up: user confirmed the paused “open Google … and search for the weather in Yuba City” utterance waited for release, produced one search tab, and Fn-arrow cancelled voice while retaining the combination. Activity independently showed the complete phrase and a single Google-search decision. This establishes the named basic physical path on this keyboard, not every Fn/OS combination.
- Subsequent actual run after the search: overlay **33 ms**, microphone ready **142 ms**, transcript finalized **122 ms**, interpretation **219 ms**, dispatch **104 ms**. Two measured successful samples total across different commands/build stages; no percentile claims. The second sample is from the final packaged binary.
- Final native Commands surface inspected: secure API field masked, Save present, auto-execute enabled and confidence **70%**, matching preserved defaults. Temporarily disabled auto-execute for a controlled live TextEdit/capsule-focus check; restored and visibly verified enabled after the test.

- Live dictation check: created a blank disposable TextEdit document with automatic execution temporarily off. User chose **type hello and quit Google**. Activity showed exactly one dictation action targeting TextEdit; direct native accessibility inspection independently verified the document contained **hello and quit Google**. The agent did not click Run itself (the user completed the action), so no claim that the agent directly measured focus during the capsule click. Original auto-execute **enabled**, threshold **70%**, and **System Default — MacBook Pro Microphone** were visibly verified at handoff. All three permission indicators were granted, shortcut ready, microphone meter idle at 0%.
- Final live behavior demonstrated: physical Fn recording/release, complete spoken phrase, combined single-tab search, ordinary Fn-arrow cancellation, literal dictation into the captured external target, accurate Activity decisions, and live microphone test. No additional code changes after the final tested/signed package.
- Durable build/test/review-regression logs copied to `/Users/karanvirkang/Library/Caches/JevVoice/verification/20260918/`. Recovery archive remains separate and intact. No API keys, recordings, or clipboard contents are included.


### User-directed hands-free refinement — 2026-09-18

**New requirement:** ordinary commands, including “open Messages,” must run without confidence-based permission prompts. Confirmation is appropriate for deletion/purchasing if supported later. The pill is the normal interface; the full window opens only on expansion/menu access. This explicit direction supersedes the original confidence and forced-action-confirmation acceptance criteria; it does not authorize automatic execution of an incomplete transcript.

- Root cause: controller required each decision to exceed the saved threshold; planner also lowered decisions by model context confidence even for straightforward app names. The observed Messages decision was 31% against a 70% threshold.
- Ordinary validated plans now execute when auto-execute is enabled, regardless of model confidence. The existing manual-review preference remains opt-in; stored threshold is preserved but no longer used or presented as an execution gate. Transcript review still requires accepting the captured text; Continue submits it without a second action-permission gate in automatic mode.
- Explicit whole-clause open/launch/start/run/switch/focus/activate requests resolve locally against installed full names or unique name suffixes. No substring/prefix guess, ambiguous alias, pronoun or extra instruction qualifies. Named website routing keeps priority. Compound context and literal dictation still go through the existing planner. No model call is required for “open Messages.”
- Pill has a persistent Expand control while visible. Expanded settings has Collapse. Normal startup uses a nonactivating setup hint when needed; it no longer forces the settings window open. Explicit menu/settings launch remains available.
- Regression tests first demonstrated missing local navigation and unwanted confirmation. Added offline navigation, ambiguous/extra-argument rejection, compound literal-text context, low-confidence automatic execution, and explicit manual-review/double-Run coverage. API-choice tests use model-bound wording so they still prove real request payload construction.
- Before package replacement, preserved the prior UI app at `/Users/karanvirkang/Library/Caches/JevVoice/rollback/20260918-handsfree/Jev Voice.app`. Verification in progress; do not claim physical tests for the new build yet.

- Review found that isolated local clauses could discard whole-request conditions. Shortcut eligibility now requires the entire composition to consist of explicit app navigation and/or literal dictation. Tests also exposed an older fallback that rewrote a model no-action answer into an app action; it now respects no-action. Conditional multi-clause regression passes. Reviewer verified local composition restriction; full suite verifies the additional fallback repair.
- Final refinement suite: **116 tests, 0 failures**, 5.247 seconds (`/tmp/jev-handsfree-final-tests.log`). Release/package passes without warnings (`/tmp/jev-handsfree-package.log`); strict/deep signature verification passes. Launched normal app without `--settings`. Physical no-Run/Expand/Collapse check requested; native automation cannot currently attach when only the nonactivating panel is present, so do not label that UI check passed from source inspection.
- Demo target reaffirmed by user: [Andy Gao's X post](https://x.com/instantricecook/status/2100814590300889426) describes opening an app before the utterance finishes. Web fetch returned 403, but the in-app browser loaded the post and video; author text and the running Notes demonstration were observed. No claim of a measured comparison or knowledge of the demo's internals. This delivered refinement still executes after speech finalization on Fn release. Matching the mid-sentence behavior requires incremental clause dispatch with revised-transcript handling and at-most-once effects; it is **not implemented** by the local-navigation optimization.

</details>

</details>

## Historical specification — inactive reference only

The following is preserved verbatim for regression investigation. It has no active requirements; S1–S9 above supersede it. Do not implement its old exclusions or treat its status as current.

<details>
<summary>Pre-migration UI and native-executor specification</summary>

# FluidVoice-style UI and Fn push-to-talk specification

Status: existing specification updated in place on 2026-09-18. The UI is delivered; continuous execution and corrections are planned, not implemented. Evidence is tracked in PLAN.md.

This document defines the product behavior. [PLAN.md](PLAN.md) defines delivery and validation. [EXECUTION.md](EXECUTION.md) is the entry point for an implementing agent. Later explicit user instructions supersede this specification; record material changes rather than silently changing the acceptance criteria.

This is an incremental change to the working app. C1–C5 specify the new behavior; R1–R6 describe behavior to preserve and the integration adjustments already called out. Existing UI, input, capture, settings, permissions, credentials, and command implementations are reused. Their presence in this specification does not require reimplementation or a new test duplicating existing coverage.

## Continuous control and reversible corrections

C1–C5 define the new behavior; R1–R6 preserve and integrate the existing product requirements. The reference is [Andy Gao's demonstration](https://x.com/instantricecook/status/2100814590300889426): a persistent transcript overlay, chained instructions, app launch followed by in-app work, and continued listening while actions execute. The clip establishes visible behavior, not the implementation, exact model latency, or the recording trigger.

### C1 — Listen and act during the same Fn hold

Hold Fn to start one voice session. Recognize and execute sufficiently complete supported commands while continuing to listen. Release Fn to finalize only the uncommitted remainder. Keep one capture session and one serial desktop-action queue; do not run competing focus-changing actions in parallel. No extra Run for ordinary commands when auto-execute is enabled. With auto-execute disabled, no early side effects: retain the existing explicit review flow.

Use a bounded command-boundary decision, considering the whole available utterance, not punctuation or transcript age alone. Missing targets/arguments, unresolved conditions, and incomplete search payloads cannot dispatch. Explicit literal dictation follows the bounded live-edit contract below. Revise pending commands when recognition changes. Associate dispatched actions with stable session/action identities; the same partial, a revised prefix, final text, or a network retry cannot replay them. Repeated intentional commands remain possible: two separate requests to scroll are two actions, not one because their strings match. Filler such as praise or transition words alone produces no action.

User update, 2026-09-18 after the repaired early-command test: dictation must also appear while Fn remains held. Once an explicit type/write/dictate command begins its payload, the remainder is content through Fn release. Words such as “stop” or “quit Spotify” in that payload are not control commands. In-session chaining before dictation is required; leaving dictation mid-hold through an inferred boundary is not required. Escape remains available throughout. This prevents the extension from breaking literal text to make the reference sequence appear faster. In editable fields that expose addressed text and selection control, insert partial payloads immediately and reconcile recognition revisions only within the insertion owned by this hold. Verify the original surrounding content and caret before each edit; cursor/focus/user edits stop further changes rather than redirecting them. Final recognition updates the same insertion once, never pastes it again. Escape, early-final/error/timeout preserve already-inserted text and do not offer a replayable transcript. Unsupported fields and nonempty preexisting selections retain final-paste behavior, explicitly indicated in the pill; manual mode never streams. TextEdit live typing is a required acceptance case. This supersedes the earlier implementation decision to defer every literal payload until release.

### C2 — Progress follows actual application state

Maintain the initial external target and update command context only from successful relevant actions. Use app identity plus window/document identity where available, rather than app name alone. A newly created disposable document becomes the next dictation target. A browser request retains the explicitly selected browser. The pill and expanded settings never become accidental targets. User focus changes cannot silently redirect content insertion.

Add the minimum reusable in-app capabilities needed for the installed-app matrix in PLAN.md: creating a TextEdit document, addressing that document for text insertion, bounded browser scrolling, and browser back navigation. Preserve existing app/window control, URL/search planning, supported sites, and explicit separate-tab intent. Choose supported native automation/accessibility/shortcuts after probing their behavior; do not assume that an installed app exposes a working interface. Do not hard-code the test utterances, screen coordinates, or sample content. Unsupported actions produce a concise explanation rather than guessed keystrokes.

### C3 — Correction and stopping

- “Actually, don't” cancels the immediately preceding unambiguous command and its not-yet-dispatched dependents. If dispatch has not happened, remove it. If an app launch is in flight, reconcile its eventual outcome before compensating.
- If Jarvis launched a previously non-running app, and no dependent content edits or intervening user work make reversal unsafe, request a normal quit and restore the previous external focus when it still makes sense. Never force quit, dismiss a save dialog, or discard content to manufacture a successful undo. If the app remains running or asks to save, report that result in the pill.
- If the app was already running, reverse Jarvis's activation/unhide where supported instead of quitting the user's existing session. Preserve its documents/tabs; do not steal focus back after an unrelated user focus change.
- “Actually, open Calculator instead” cancels pending superseded work, reverses an eligible recent launch, then performs the replacement. Corrections refer to the most recent relevant action in the same hold; ambiguous references ask a short clarification in the pill. There is no general rollback promise for every application action.
- Spoken “stop” outside literal content clears pending work and cancels in-flight interpretation while leaving capture active until Fn release, so a new explicit request can follow in the same hold. It does not undo completed actions. Stop in the pill, Escape, Fn combinations, and OS interruption end the operation using the existing cleanup rules; they do not implicitly quit every app opened during the hold.
- Corrections, cancellation, and delayed model/launch completions must be serialized against dispatch. A late result cannot resurrect cancelled work. An uncertain dispatch is never retried automatically. Report an unsuccessful reversal honestly.

### C4 — Existing UI, concurrent feedback, and recovery

Retain the current pill styling and placement, Fn controls, waveform, settings, and explicit expansion. While acting during capture, show listening/transcription and concise current-action or correction feedback together; an action completing must not dismiss the pill while Fn is held. The full window stays hidden unless expanded. No ordinary-action confirmation is added.

Retain capture duration limits, permission handling, session identities, clipboard protection, and cleanup. On early finalization, microphone loss, timeout, or recognition failure, stop new dispatch and preserve an honest record of effects already made. Review only the uncommitted remainder. Never submit the entire transcript again through the old planner. Ordinary silence during a hold does not stop capture; it may contribute evidence of a command boundary. Recognition recovery cannot auto-resume a stopped capture.

### C5 — Acceptance and scope

Demonstrate early command effects during physical speech, successful dependent in-app actions, corrections both before and after launch, and no duplicate effects on release. Use the installed-app matrix in PLAN.md rather than requiring Notes/Arc/Photo Booth parity by name. Generalize wording and content within supported capabilities. Keep Swift, macOS 13 target, Apple on-device STT, existing Jev, no new package dependency by default, and no additional runtime model, gaze, wake word, always-on capture, TTS, or Cua/VM integration in this extension.

Measure recognition arrival, boundary decision, interpretation, queue wait, native dispatch, and observed external readiness separately. Include first-action-before-release evidence and correctness alongside timing; do not infer millisecond latency from video captions. Avoid optimizing by guessing incomplete payloads. Numeric performance targets and evidence are in the active plan.

## Goal and boundaries

Deliver continuous Jev Voice control during Fn/Globe hold-to-talk using the existing compact capsule, live transcription and microphone levels, FluidVoice-style settings, and microphone picker. Preserve existing command capabilities, interpretation, planning, automatic command execution with optional manual review, credentials, preferences, and clipboard protection.

Keep Swift, SwiftUI/AppKit, Apple on-device speech recognition, and the existing Jev integration. Preserve the macOS 13 deployment target. Astra is the implementation agent, not a new runtime model in the product.

Gaze, always-on listening, wake words, TTS, Cua/VMs, new reasoning models, notch integration, model management, analytics, and an updater are outside this change. Do not import FluidVoice's application services to obtain its appearance. Default to no new package dependencies.

## R1 — Recording controls and input readiness

- Fn down starts one recording; Fn up finishes it. Replace Option-Space and the Talk toggle in the finished interface. Menu-bar access provides Settings, Activity, and Quit.
- Identify the physical Fn transition, not merely a function modifier on unrelated events. Ignore key repeats. Other keys/modifiers combined with Fn cancel the voice attempt and preserve the ordinary keyboard combination.
- Escape cancels an active voice operation and otherwise passes through normally. Swallow matching Escape press/release consistently when consumed. A cancelled or ignored hold cannot become a new recording until Fn is released and pressed again.
- Accept new holds from idle, completed, or error states after cleanup. Do not queue or overlap separate holds. Within the current hold, capture continues while eligible commands execute serially.
- Capture the original external-app context before presenting UI. Releasing Fn before startup/authorization completes invalidates the pending start; granting permission afterward cannot begin recording.
- Missing permissions show an actionable setup state. Already-granted permissions must not trigger repeat prompts. Refresh actual permission and input readiness when settings opens and the app becomes active.
- Loss of the event tap, secure input, sleep, session lock, microphone loss, or unrecoverable capture changes stop capture without submitting. Check input health while recording so a missing release cannot leave it running indefinitely. Recovery never resumes an interrupted recording automatically.
- An event-tap creation failure is a distinct input-readiness failure, not automatically proof of a particular missing permission. Follow the supported APIs and observed OS behavior. Do not demand unrelated permissions or silently change system keyboard preferences.
- If Globe-key behavior conflicts with the shortcut, provide instructions and a link to Keyboard settings. Verify actual Fn combinations on the user's keyboard; source inspection and synthetic events are insufficient.

## R2 — Speech and session lifecycle

- One controller owns session capture and serial action execution with independent progress state. Expose begin, finish, cancel, confirm, and correction behavior. Every asynchronous callback/result belongs to its originating session and action where applicable.
- Silence must not end or submit the entire held session. A pause may help identify a complete command under C1. Show a starting state immediately; show Listening only once capture starts. Normal idle state performs no microphone capture.
- On release, stop capture and finish accepted audio using the recognition request/task finalization APIs. Do not immediately cancel recognition. Finalize once and submit only uncommitted work; never replay commands already dispatched during speech.
- Silence produces no Jev call and no action. Ignore late callbacks, old deadlines, and stale model responses after cancellation, session replacement, or completion.
- Finalization has an initial two-second deadline after release. This is a tunable product default, not an Apple guarantee. Final text arriving within it follows existing interpretation and confirmation rules.
- On a finalization timeout, retain only uncommitted text for explicit review; do not execute that remainder automatically. Offer Review transcript and Cancel. Review opens the normal window; Continue explicitly accepts that text and submits it using the normal automatic/manual execution preference. Late recognition cannot replace a transcript already accepted for review.
- An unexpected early final result while Fn is held stops capture and enters the same remainder-only review path after release. A recognition failure stops pending dispatch; earlier completed actions remain recorded and are not replayed. Empty or unusable text shows a retryable error. Escape/cancellation discards the pending attempt rather than opening review.
- Limit a recording to 55 seconds; warn at 50 seconds. Reaching the limit stops capture and requires review after release. No automatic multi-session transcription is included. Persistent early endings during ordinary short commands fail the usability gate and must be investigated before delivery.
- Release audio resources on every terminal path. Audio callback work must be bounded; no UI work, logging, or unbounded task creation per audio buffer. A session's capture callback must not access a mutable request belonging to a newer session.

## R3 — Microphones

- Offer System Default and available input devices. Preserve System Default as the initial preference. Persist an explicit choice by stable UID, resolving its current device ID for each recording.
- Select the input for this app's engine without changing the system default. Show the actual resolved input name, not just the preference label.
- Freeze the resolved device for a session; preference changes apply next time. An unavailable explicit device remains visibly unavailable until the user selects another or it returns. Do not silently substitute an input.
- Handle disconnection and audio-format changes by ending the attempt cleanly without executing incomplete speech. Observe devices outside SwiftUI body evaluation and remove listeners during teardown.
- Derive waveform levels from the existing capture stream and throttle publication. Do not start a second recording engine for visualization.
- A settings microphone test uses the same capture path without interpretation or execution. It ends when stopped, its window closes, or a real command starts. Microphone access is needed for the test; speech permission is needed for command transcription.

## R4 — Command behavior, responsiveness, and cancellation

- Preserve local literal-dictation handling, Jev typed questions, context resolution, plan validation, merged browser/search navigation, explicit separate-tab intent, supported-site restrictions, and confidence diagnostics.
- UI rendering and settings changes never call Jev. Eligible command candidates use the existing interpretation path where applicable, with coalescing, revision checks, and local routing as specified in C1.
- Ordinary validated commands execute automatically regardless of model confidence. Explicit app navigation may resolve locally against installed apps. Deletion and purchasing are not supported; if added, they require explicit action confirmation in the pill.
- Preserve optional manual review when the user disables automatic execution; no early side effects in that mode. Keep one serial execution queue and at most one confirmation for its reviewed plan. Double-clicking Run cannot repeat actions. A new Fn hold while busy cannot queue another session.
- Capture initial external context and advance it only from relevant successful actions. Retain each action's resolved target across Settings/Activity/Review and unrelated focus changes; UI focus cannot become an implicit dictation destination.
- Move blocking subprocess execution/output collection off the main thread. Keep AppKit operations on the correct thread. Do not wrap blocking code in a task that still inherits the main actor and call that a fix.
- Cancel stops interpretation and prevents subsequent actions. Check cancellation/session identity after awaits and immediately before dispatching each action. Cancellation-related network errors are cancellation, not user-facing transport failures.
- An already-dispatched action may finish. Display Stopping until required cleanup completes. Explicit correction may compensate an eligible launch under C3; ordinary cancellation does not promise general undo or instant termination. Preserve the existing bounded clipboard handoff and conditional clipboard restoration, including normal Quit during paste.
- Do not add automatic retries of actions. Show accurate outcomes: No action taken for an empty plan; distinguish a dispatched request from an independently verified external result.

## R5 — Presentation and settings

Adapt FluidVoice at commit `0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b`: capsule appearance, waveform styling, restrained animation, nonactivating panel pattern, settings cards, typography, and spacing. Preserve applicable source/license notices. FluidVoice currently targets macOS 15+, so adapt newer APIs rather than raising this app's deployment target silently.

Use a dark translucent, compact capsule with system typography and a live transcript above it. Choose the display containing the pointer at session start, center the capsule near the bottom of its usable area, and keep its bottom anchor stable as content changes. Clamp/reposition after display disconnection; account for Dock placement, Spaces, and fullscreen. Bound transcript height and provide full text in Review/Activity.

| State | Presentation and behavior |
| --- | --- |
| Idle | Hidden; menu-bar access remains |
| Starting | Immediate Starting microphone feedback |
| Listening | Real waveform, input name available, live transcript, and concurrent action/correction progress |
| Finishing | Finishing status and Cancel |
| Interpreting | Understanding status and Cancel |
| Needs transcript review | Persistent explanation, Review transcript, Cancel |
| Needs action confirmation | Complete action summary, one Run/Cancel pair |
| Executing | Current action and Stop |
| Stopping | Cleanup status; no new recording |
| Completed | After capture ends and queue cleanup completes: accurate result for 1.5 seconds, then hide |
| Error | Persistent explanation and recovery action; a new Fn hold may retry recording |

The capsule must not activate our app or steal keyboard focus, including when its controls are clicked. Use tight window/hit-test bounds so transparent padding does not block underlying apps. Settings or Review may activate only when explicitly expanded from the pill or opened from the menu. Normal startup never opens the full window automatically; setup problems appear in the pill. The full window has a Collapse control. Provide accessible labels and keyboard-accessible review/confirmation in the normal window. Respect Reduce Motion and Reduce Transparency. Animations cannot delay capture, interpretation, or execution; old hide timers cannot dismiss a newer session.

One settings window has three sections:

- **Voice:** microphone picker/test, Fn instructions, permission and input readiness.
- **Commands:** existing API-key Save/delete behavior and auto-execute toggle. Model confidence remains diagnostic and does not gate execution.
- **Activity:** current operation, existing recent decisions, optional model/confidence/latency diagnostics, and full text/review access. Keep existing in-memory retention; this change adds no disk transcript/audio history.

Keep existing preference keys and defaults (auto-execute enabled); retain the legacy confidence threshold value in storage without using it as an execution gate and Keychain service/account identifiers. Add only the microphone preference needed by this feature. Preserve environment-key fallback and migration semantics. Never put keys or raw audio into diagnostics. The production README must reflect new controls only after implementation passes acceptance.

## R6 — Compatibility, performance, and delivery

Preserve bundle ID `com.chriswozniczek.jevvoice` and the intended local bundle location: `~/Library/Caches/JevVoice/build/Jev Voice.app`. Preserve the pre-change working bundle and all existing tracked/untracked changes. A worktree from HEAD alone does not contain the current working baseline.

Measure key-event-to-visible-feedback, microphone readiness, release-to-final-transcript, interpretation, and action dispatch separately using monotonic time. Aim for visible feedback within 100 ms on this Mac; distinguish initial startup from subsequent recordings and report observations rather than a universal guarantee. Evaluate latency changes against the baseline, without sacrificing final-word accuracy or changing the speech model to meet a cosmetic target.

Current builds are ad-hoc signed and no valid signing identity was present during the audit. Bundle ID and path preservation cannot guarantee grants survive binary replacement. Verify the packaged build and report any required permission regrant. Do not reset TCC, change Keychain trust, or invent signing credentials as part of this feature.

Completion requires a running packaged app, demonstrated flows, passing regression checks, reviewed/simplified code, measured timings, and explicit remaining limitations. Tests or screenshots alone are not end-to-end proof. Hardware and OS versions not exercised must be marked unverified.

## Evidence and design defaults

Sources support the mechanisms; they do not establish that our future implementation works. The two-second deadline, 50/55-second warning/limit, 1.5-second dismissal, and 100-ms feedback target are proposed defaults approved with the plan. Timing adjustments are allowed with measured evidence and a decision note; preserve the command-completeness, correction, and at-most-once requirements in C1–C4.

- [FluidVoice pinned README](https://github.com/altic-dev/FluidVoice/blob/0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b/README.md): platform requirements and project context.
- [FluidVoice overlay](https://github.com/altic-dev/FluidVoice/blob/0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b/Sources/Fluid/Views/BottomOverlayView.swift), [settings](https://github.com/altic-dev/FluidVoice/blob/0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b/Sources/Fluid/UI/SettingsView.swift), and [hotkeys](https://github.com/altic-dev/FluidVoice/blob/0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b/Sources/Fluid/Services/GlobalHotkeyManager.swift): extraction references, not wholesale dependencies.
- Apple [finish](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/finish%28%29), [endAudio](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest/endaudio%28%29), and [recognizer guidance](https://developer.apple.com/documentation/speech/sfspeechrecognizer?changes=_9): finalization and conservative duration handling. Duration guidance does not prove an identical on-device cutoff on every OS.
- Apple [device selection](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/setdeviceid%28_%3A%29) and [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services): available mechanisms requiring real integration validation.
- Apple [Secure Event Input](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) and [Keyboard settings](https://support.apple.com/guide/mac-help/keyboard-settings-kbdm162/mac): input limitations and system configuration.

## Decision record — 2026-09-18

The user removed confidence-based permission prompts for ordinary commands and requested a pill-first interface. The subsequent continuous-control request permits completed commands during a hold, with launch corrections and installed-app testing. This replaces release-only execution, while preserving manual review, literal dictation, credentials, and existing command capabilities. Deletion/purchase actions remain unsupported; future support must confirm those actions in the pill. The optional “Run commands automatically” preference remains available and enabled.

</details>
