# FluidVoice-style UI and Fn push-to-talk specification

Status: existing specification updated in place on 2026-09-18. The UI is delivered; continuous execution and corrections are planned, not implemented. Evidence is tracked in PLAN.md.

This document defines the product behavior. [PLAN.md](PLAN.md) defines delivery and validation. [EXECUTION.md](EXECUTION.md) is the entry point for an implementing agent. Later explicit user instructions supersede this specification; record material changes rather than silently changing the acceptance criteria.

This is an incremental change to the working app. C1–C5 specify the new behavior; R1–R6 describe behavior to preserve and the integration adjustments already called out. Existing UI, input, capture, settings, permissions, credentials, and command implementations are reused. Their presence in this specification does not require reimplementation or a new test duplicating existing coverage.

## Continuous control and reversible corrections

C1–C5 define the new behavior; R1–R6 preserve and integrate the existing product requirements. The reference is [Andy Gao's demonstration](https://x.com/instantricecook/status/2100814590300889426): a persistent transcript overlay, chained instructions, app launch followed by in-app work, and continued listening while actions execute. The clip establishes visible behavior, not the implementation, exact model latency, or the recording trigger.

### C1 — Listen and act during the same Fn hold

Hold Fn to start one voice session. Recognize and execute sufficiently complete supported commands while continuing to listen. Release Fn to finalize only the uncommitted remainder. Keep one capture session and one serial desktop-action queue; do not run competing focus-changing actions in parallel. No extra Run for ordinary commands when auto-execute is enabled. With auto-execute disabled, no early side effects: retain the existing explicit review flow.

Use a bounded command-boundary decision, considering the whole available utterance, not punctuation or transcript age alone. Missing targets/arguments, unresolved conditions, and incomplete search/dictation payloads cannot dispatch. Revise pending commands when recognition changes. Associate dispatched actions with stable session/action identities; the same partial, a revised prefix, final text, or a network retry cannot replay them. Repeated intentional commands remain possible: two separate requests to scroll are two actions, not one because their strings match. Filler such as praise or transition words alone produces no action.

Preserve existing literal dictation: once an explicit type/write/dictate command begins its payload, the remainder is content through Fn release. Words such as “stop” or “quit Spotify” in that payload are not control commands. In-session chaining before dictation is required; leaving dictation mid-hold through an inferred boundary is not required. Escape remains available throughout. This prevents the extension from breaking literal text to make the reference sequence appear faster.

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
