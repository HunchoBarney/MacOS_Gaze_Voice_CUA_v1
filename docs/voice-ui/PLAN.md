# FluidVoice-style UI and Fn push-to-talk implementation plan

Status: approved; documentation prepared; implementation not started.

**Goal:** deliver the behavior and acceptance criteria in [SPEC.md](SPEC.md).

**Architecture:** retain JevVoiceCore's interpretation/planning and the native executor. Add a small Fn input boundary and microphone-device service; strengthen the existing controller/recognizer lifecycle; bind a native overlay and settings window to that state. Avoid a second application state machine in the views.

**Stack:** Swift, SwiftUI/AppKit, Speech, AVFoundation, Core Audio, Quartz events; macOS 13 minimum; no new package dependencies by default.

**Execution:** read [EXECUTION.md](EXECUTION.md) once, then work milestone by milestone. This plan specifies behavioral contracts and evidence, not speculative implementation code. Choose private symbols and exact file decomposition to fit the code encountered. Record evidence-backed changes to the approach while preserving the spec.

## Baseline and ownership

At the documentation audit, HEAD was `77d460d189877e5c13ff0668bcaab61dd6f73663`, with substantial modified and untracked source/tests from earlier work. Do not reset, discard, or bypass them. The earlier run of `swift test` reported 84 passing tests; that is historical evidence, not verification of this feature.

| Responsibility | Existing entry points / intended change |
| --- | --- |
| Session ownership and cancellation | `Sources/JevVoice/VoiceController.swift`; explicit operations and session-scoped callbacks/tasks |
| Audio/recognition | `Sources/JevVoice/SpeechRecognizer.swift`; separate finish/cancel and per-session capture ownership |
| Native input and microphone discovery | Small new components under `Sources/JevVoice`; expose events and device snapshots, no model/UI ownership |
| Presentation and app lifecycle | `main.swift`, `ContentView.swift`, `SettingsView.swift` under `Sources/JevVoice`; thin window controllers and reusable visual components |
| Persistence and permissions | Existing `Config.swift`, `APIKeyStore.swift`, `Permissions.swift`; preserve identifiers/semantics |
| Action responsiveness | `Sources/JevVoice/Executor.swift`; isolate blocking processes, preserve native action and paste contracts |
| Command logic | `Sources/JevVoiceCore`; retain behavior; touch only when a proven boundary defect requires it |
| Tests | Existing `Tests/JevVoiceAppTests` and `Tests/JevVoiceTests`; add focused session/input/device tests |

Interfaces must communicate session identity, readiness, partial/final recognition, normalized audio level, interruption/failure, and current action. Begin/finish/cancel/confirm are controller operations; views do not launch model or executor tasks directly. Use small injectable boundaries for speech, input, interpretation, execution, and deadlines where they enable deterministic tests. Do not create a general service framework.

## Milestone 0 — Recoverable baseline

Covers R4/R6 and establishes the comparison for every later milestone.

- [ ] Inspect current changes and preserve a recoverable source snapshot including untracked files, plus the working app bundle. Verify both snapshots are usable. Do not include credentials or personal recordings.
- [ ] Run `swift test` and `swift build -c release`; distinguish pre-existing failures from regressions.
- [ ] Record current settings behavior and named command outcomes in the regression matrix below. Use disposable content and reversible actions.
- [ ] Record available keyboard, microphone devices, displays, OS version, permission status, and baseline timing observations. Do not imply access to hardware that is absent.

Exit evidence: source/bundle recovery locations, test/build outcomes, observed baseline behaviors and limitations. No implementation milestone is complete yet.

## Milestone 1 — Reliable Fn, capture, and microphone selection

Covers R1/R2/R3. Use minimal presentation first; polished UI depends on this working.

- [ ] Implement the session boundary and Fn transitions, including release-before-start, key combinations, ignored holds while busy, Escape, and event-tap teardown/recovery.
- [ ] Separate speech finish from cancellation, remove silence submission during a hold, and implement timeout/early-final/maximum-duration review outcomes. Enforce at-most-once transcript submission and stale-callback rejection.
- [ ] Add stable-UID input selection and a shared microphone-test/capture path. Manage device and format changes, listeners, and resource teardown.
- [ ] Add focused tests for races/interruption paths before relying on live integration. Use controlled events/deadlines; do not sleep for 55 seconds in unit tests.
- [ ] Verify the actual MacBook Fn key and microphones. Test pauses within a held command and release immediately after the last word. Preserve normal Fn combinations.

Validation: `swift test --filter JevVoiceAppTests`, `swift build -c release`, and the recording/device rows of the matrix below. If real Fn or speech behavior violates the contract, fix this path before polishing the overlay. Do not claim a synthetic event test proves physical-key behavior.

Checkpoint A for the user: hold Fn, say a phrase with a pause, release; select the MacBook microphone; repeat. The agent first verifies everything it can and asks only for physical input/permission actions it cannot reproduce faithfully.

## Milestone 2 — Responsive execution and accurate cancellation

Covers R4 and the command-facing parts of R2/R5.

- [ ] Give the controller ownership of interpretation/execution and confirmation. Carry session identity and original target context through all asynchronous work.
- [ ] Prevent duplicate confirmation, overlapping commands, and cancelled results reaching execution. Ensure forced confirmation survives transcript-review flow independently of confidence settings.
- [ ] Move subprocess waiting/output draining off the main actor. Keep UI/input callbacks short and native AppKit work on its required thread. Ensure a blocked child process cannot freeze Stop or the waveform.
- [ ] Preserve clipboard handoff/conditional restoration, including normal Quit. Hold Stopping until cleanup finishes. Never retry dispatched effects automatically.
- [ ] Use actual execution outcomes for progress/results, distinguishing cancellation, no action, partial sequence completion, dispatch success, and errors without promising unsupported external verification.
- [ ] Run deterministic tests with delayed model/executor responses and subprocess fixtures, then exercise benign real commands.

Validation: `swift test`, `swift build -c release`, plus cancellation, targeting, and command matrix rows. Verify no later action dispatch occurs after cancellation and no result from an old session changes a new UI session.

Checkpoint B: demonstrate a combined search, literal dictation into a disposable document, and cancellation of a delayed multi-action operation with clipboard cleanup intact.

## Milestone 3 — Capsule and settings adaptation

Covers R5 and settings persistence/readiness in R1/R3/R6.

- [ ] Extract only necessary visual code from the pinned FluidVoice commit; retain notices and adapt macOS 15+ APIs to the current deployment target. Compare against upstream visual references before calling the styling faithful.
- [ ] Implement the nonactivating capsule and a single normal settings/activity/review window. Bind both to controller state; remove the old toggle shortcut and Talk UI when the replacement is verified.
- [ ] Implement all specified states, complete plan-level confirmation, bounded transcript, full review text, recovery actions, session-scoped hide timers, and accurate current-action feedback.
- [ ] Verify capsule placement/hit testing, focus preservation, explicit normal-window activation, Spaces/fullscreen behavior, display changes, and accessibility settings.
- [ ] Preserve API-key Save/delete/paste, Keychain migration, environment fallback, command preferences, and existing activity retention. Test them through the new settings surface.

Validation: targeted app tests, release build, deterministic state previews without network/microphone side effects, and the actual window/focus/settings matrix. A build targeting macOS 13 does not prove runtime behavior on macOS 13; report older-OS runtime coverage honestly.

Checkpoint C: provide a running demonstration of the capsule and settings, then execute the same commands used for the baseline.

## Milestone 4 — Review, measurement, and packaged acceptance

Covers R6 and the complete specification.

- [ ] Review the whole change for session races, main-thread blocking, permission loops, target-app changes, duplicate dispatch, audio/device listener leaks, clipboard cleanup, and accidental imports of FluidVoice services. Simplify unnecessary state/abstractions.
- [ ] Finish the matrix and compare timing against the baseline. Record monotonic timings for visible feedback, microphone readiness, transcript finalization, interpretation, and dispatch; separate cold and subsequent runs and state sample counts.
- [ ] Run the full regression suite after final fixes and build the release. Repeat checks only when changes or unresolved failures justify it.
- [ ] Update user-facing README instructions to the delivered behavior, including Fn setup, microphone selection, transcript review, and known limitations.
- [ ] Package to the intended location, retaining rollback material. Verify the installed app's signature and real flows; report a required OS permission regrant without resetting TCC or changing signing trust.
- [ ] Report what passed, what failed or was not exercised, observed timings, the working bundle location, and recovery instructions. Do not mark hardware-dependent acceptance complete when only mocks were tested.

Packaging commands, run from the repository root during implementation:

```sh
swift test
swift build -c release
make app APP="$HOME/Library/Caches/JevVoice/build/Jev Voice.app"
codesign --verify --deep --strict --verbose=2 "$HOME/Library/Caches/JevVoice/build/Jev Voice.app"
open "$HOME/Library/Caches/JevVoice/build/Jev Voice.app"
```

These commands do not replace real interaction checks. Package only after preserving the prior bundle. Avoid repeated installed-bundle replacement during intermediate testing; ad-hoc rebuilds can require permission regrants.

## Regression and acceptance matrix

Record concrete observations and evidence below during implementation, not assumed passes. Fake tests must use isolated preferences/pasteboards and controlled dependencies; no live model calls or desktop actions in the normal test suite.

| Coverage / owner | Cases and required outcome | Evidence method |
| --- | --- | --- |
| R1/R2 — M1 | Fn release before startup/authorization, repeated down/up, held-key cancel, new press before cleanup: no delayed recording, duplicate transcript, or queued command | Controlled input/speech tests + real keyboard |
| R1 — M1 | Fn-arrow/function-key/other-modifier combinations; Escape down/up; secure input; tap disable/recovery; sleep/lock; missing release: ordinary combinations preserved, capture cancelled, fresh press required | Unit transitions + real OS checks; never disable another app's secure input |
| R2 — M1 | Pause while held; trailing word at release; silence; final and error callback races; timeout; early final; duration limit; old callbacks: one complete submission or explicit review/error, never automatic partial execution | Speech fixtures + physical microphone test |
| R3 — M1 | Built-in mic vs AirPods when available, explicit unavailable UID, disconnect/reconnect, format change, changed system default, test-to-command transition: accurate device, no silent substitution or overlapping engines | Device fakes + actual available devices |
| R2/R4 — M2 | Cancel delayed interpretation, wrapped network cancellation, double Run, busy Fn press, review with auto-execute enabled: no stale/duplicate dispatch, review forces confirmation | Controller tests with delayed dependencies |
| R4 — M2 | Cancel between actions, during blocked subprocess, during clipboard handoff, normal Quit during paste: UI remains responsive, later actions do not dispatch, cleanup completes | Controlled process/executor tests + disposable live document |
| R4 — M0/M2/M4 | Open Calculator; Google weather in Yuba City; Safari URL; YouTube and DuckDuckGo searches: expected destination and existing merged navigation behavior | Core tests + observed app/browser outcome |
| R4 — M0/M2/M4 | Explicit separate tabs; open Notes then minimize it; open Notes and type `hello and quit Safari`: context/tab intent preserved, suffix stays literal text | Core tests + reversible live checks |
| R4 — M2/M4 | Unsupported native-app search, missing arguments, all-no-action plan, invalid key, network failure: no unintended partial plan, clear accurate outcome | Fakes/core tests; benign live error checks where useful |
| R4/R5 — M3 | Focus external editable field; show capsule; click Run; open review/settings; switch apps mid-command: UI never silently changes captured target, text goes to intended app | Actual native focus + disposable text |
| R5 — M3 | All visual states; long text; old hide timer; transparent padding; Dock positions; fullscreen/Spaces; unplug display; Reduce Motion/Transparency; keyboard review: usable and no focus/window regression | State previews + actual UI; absent hardware marked unverified |
| R1/R3/R5 — M3 | Key Save/delete/paste, storage failure, migrated key, environment fallback, preferences relaunch, return from permissions settings: existing data preserved, readiness reflects actual build | Isolated persistence tests + UI; no secret logging |
| R6 — M4 | Intended packaged bundle launches, settings persist, Fn/mic/command/confirmation work; release signature verifies | Installed-bundle smoke test; not just a development executable |

## Progress and decisions

| Milestone | Status | Evidence |
| --- | --- | --- |
| 0 — Baseline | Not started | Historical 84-test pass only; fresh baseline required |
| 1 — Input/capture | Not started | No feature implementation verified |
| 2 — Execution | Not started | No feature implementation verified |
| 3 — Presentation | Not started | No feature implementation verified |
| 4 — Delivery | Not started | No packaged feature build verified |

Initial decision, 2026-09-18: preserve the current backend and platform target; extract bounded FluidVoice presentation; prove input/capture and execution before polish. Keep this table and a concise dated decision/evidence log here during implementation. Record the reason and affected requirement when changing an approach; do not manufacture completed evidence or duplicate the specification.
