# FluidVoice-style UI and Fn push-to-talk specification

Status: approved in chat on 2026-09-18; implementation not started.

This document defines the product behavior. [PLAN.md](PLAN.md) defines delivery and validation. [EXECUTION.md](EXECUTION.md) is the entry point for an implementing agent. Later explicit user instructions supersede this specification; record material changes rather than silently changing the acceptance criteria.

## Goal and boundaries

Deliver a working Jev Voice demo with Fn/Globe hold-to-talk, a compact floating capsule, live transcription and microphone levels, FluidVoice-style settings, and an in-app microphone picker. Preserve existing command capabilities, interpretation, planning, confidence-based confirmation, credentials, preferences, and clipboard protection.

Keep Swift, SwiftUI/AppKit, Apple on-device speech recognition, and the existing Jev integration. Preserve the macOS 13 deployment target. Astra is the implementation agent, not a new runtime model in the product.

Gaze, always-on listening, wake words, TTS, Cua/VMs, new reasoning models, notch integration, model management, analytics, and an updater are outside this change. Do not import FluidVoice's application services to obtain its appearance. Default to no new package dependencies.

## R1 — Recording controls and input readiness

- Fn down starts one recording; Fn up finishes it. Replace Option-Space and the Talk toggle in the finished interface. Menu-bar access provides Settings, Activity, and Quit.
- Identify the physical Fn transition, not merely a function modifier on unrelated events. Ignore key repeats. Other keys/modifiers combined with Fn cancel the voice attempt and preserve the ordinary keyboard combination.
- Escape cancels an active voice operation and otherwise passes through normally. Swallow matching Escape press/release consistently when consumed. A cancelled or ignored hold cannot become a new recording until Fn is released and pressed again.
- Accept new holds from idle, completed, or error states after cleanup. While starting, finishing, interpreting, confirming, executing, or stopping, do not queue or overlap commands.
- Capture the original external-app context before presenting UI. Releasing Fn before startup/authorization completes invalidates the pending start; granting permission afterward cannot begin recording.
- Missing permissions show an actionable setup state. Already-granted permissions must not trigger repeat prompts. Refresh actual permission and input readiness when settings opens and the app becomes active.
- Loss of the event tap, secure input, sleep, session lock, microphone loss, or unrecoverable capture changes stop capture without submitting. Check input health while recording so a missing release cannot leave it running indefinitely. Recovery never resumes an interrupted recording automatically.
- An event-tap creation failure is a distinct input-readiness failure, not automatically proof of a particular missing permission. Follow the supported APIs and observed OS behavior. Do not demand unrelated permissions or silently change system keyboard preferences.
- If Globe-key behavior conflicts with the shortcut, provide instructions and a link to Keyboard settings. Verify actual Fn combinations on the user's keyboard; source inspection and synthetic events are insufficient.

## R2 — Speech and session lifecycle

- One controller owns the current session and operation task. Expose explicit begin, finish, cancel, and confirm operations. Every asynchronous callback/result must be associated with its originating session.
- Remove silence-based submission while Fn is held. Show a starting state immediately; show Listening only once capture starts. Normal idle state performs no microphone capture.
- On release, stop capture and finish accepted audio using the recognition request/task finalization APIs. Do not immediately cancel recognition. Deliver at most one submitted transcript per session.
- Silence produces no Jev call and no action. Ignore late callbacks, old deadlines, and stale model responses after cancellation, session replacement, or completion.
- Finalization has an initial two-second deadline after release. This is a tunable product default, not an Apple guarantee. Final text arriving within it follows existing interpretation and confirmation rules.
- On a finalization timeout, retain available partial text for explicit review; do not execute it automatically. Offer Review transcript and Cancel. Review opens the normal window; Continue interprets that text and forces whole-plan action confirmation even when auto-execute is enabled. Late recognition cannot replace a transcript already accepted for review.
- An unexpected early final result while Fn is held stops capture and enters the same review path after release. A recognition failure never automatically executes partial text. Empty or unusable text shows a retryable error. Escape/cancellation discards the pending attempt rather than opening review.
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

- Preserve local literal-dictation handling, Jev typed questions, context resolution, plan validation, merged browser/search navigation, explicit separate-tab intent, supported-site restrictions, and existing confidence semantics.
- UI rendering and settings changes never call Jev. A submitted transcript uses the existing interpretation path, including local handling when applicable.
- Keep one execution task and one confirmation for the entire plan. Double-clicking Run cannot repeat actions. Fn while busy cannot queue a second command.
- Capture target-app context once per command and retain it when Settings/Activity/Review opens. UI focus must not become an implicit dictation destination.
- Move blocking subprocess execution/output collection off the main thread. Keep AppKit operations on the correct thread. Do not wrap blocking code in a task that still inherits the main actor and call that a fix.
- Cancel stops interpretation and prevents subsequent actions. Check cancellation/session identity after awaits and immediately before dispatching each action. Cancellation-related network errors are cancellation, not user-facing transport failures.
- An already-dispatched action may finish. Display Stopping until required cleanup completes; do not promise undo or instant termination of external effects. Preserve the existing bounded clipboard handoff and conditional clipboard restoration, including normal Quit during paste.
- Do not add automatic retries of actions. Show accurate outcomes: No action taken for an empty plan; distinguish a dispatched request from an independently verified external result.

## R5 — Presentation and settings

Adapt FluidVoice at commit `0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b`: capsule appearance, waveform styling, restrained animation, nonactivating panel pattern, settings cards, typography, and spacing. Preserve applicable source/license notices. FluidVoice currently targets macOS 15+, so adapt newer APIs rather than raising this app's deployment target silently.

Use a dark translucent, compact capsule with system typography and a live transcript above it. Choose the display containing the pointer at session start, center the capsule near the bottom of its usable area, and keep its bottom anchor stable as content changes. Clamp/reposition after display disconnection; account for Dock placement, Spaces, and fullscreen. Bound transcript height and provide full text in Review/Activity.

| State | Presentation and behavior |
| --- | --- |
| Idle | Hidden; menu-bar access remains |
| Starting | Immediate Starting microphone feedback |
| Listening | Real waveform, actual input name available, live transcript |
| Finishing | Finishing status and Cancel |
| Interpreting | Understanding status and Cancel |
| Needs transcript review | Persistent explanation, Review transcript, Cancel |
| Needs action confirmation | Complete action summary, one Run/Cancel pair |
| Executing | Current action and Stop |
| Stopping | Cleanup status; no new recording |
| Completed | Accurate result for 1.5 seconds, then hide |
| Error | Persistent explanation and recovery action; a new Fn hold may retry recording |

The capsule must not activate our app or steal keyboard focus, including when its controls are clicked. Use tight window/hit-test bounds so transparent padding does not block underlying apps. Settings or Review may activate only when explicitly opened. Provide accessible labels and keyboard-accessible review/confirmation in the normal window. Respect Reduce Motion and Reduce Transparency. Animations cannot delay capture, interpretation, or execution; old hide timers cannot dismiss a newer session.

One settings window has three sections:

- **Voice:** microphone picker/test, Fn instructions, permission and input readiness.
- **Commands:** existing API-key Save/delete behavior, confidence threshold, auto-execute toggle.
- **Activity:** current operation, existing recent decisions, optional model/confidence/latency diagnostics, and full text/review access. Keep existing in-memory retention; this change adds no disk transcript/audio history.

Keep existing preference keys and defaults (70% threshold, auto-execute enabled) and Keychain service/account identifiers. Add only the microphone preference needed by this feature. Preserve environment-key fallback and migration semantics. Never put keys or raw audio into diagnostics. The production README must reflect new controls only after implementation passes acceptance.

## R6 — Compatibility, performance, and delivery

Preserve bundle ID `com.chriswozniczek.jevvoice` and the intended local bundle location: `~/Library/Caches/JevVoice/build/Jev Voice.app`. Preserve the pre-change working bundle and all existing tracked/untracked changes. A worktree from HEAD alone does not contain the current working baseline.

Measure key-event-to-visible-feedback, microphone readiness, release-to-final-transcript, interpretation, and action dispatch separately using monotonic time. Aim for visible feedback within 100 ms on this Mac; distinguish initial startup from subsequent recordings and report observations rather than a universal guarantee. Evaluate latency changes against the baseline, without sacrificing final-word accuracy or changing the speech model to meet a cosmetic target.

Current builds are ad-hoc signed and no valid signing identity was present during the audit. Bundle ID and path preservation cannot guarantee grants survive binary replacement. Verify the packaged build and report any required permission regrant. Do not reset TCC, change Keychain trust, or invent signing credentials as part of this feature.

Completion requires a running packaged app, demonstrated flows, passing regression checks, reviewed/simplified code, measured timings, and explicit remaining limitations. Tests or screenshots alone are not end-to-end proof. Hardware and OS versions not exercised must be marked unverified.

## Evidence and design defaults

Sources support the mechanisms; they do not establish that our future implementation works. The two-second deadline, 50/55-second warning/limit, 1.5-second dismissal, and 100-ms feedback target are proposed defaults approved with the plan. Timing adjustments are allowed with measured evidence and a decision note; do not weaken the no-automatic-partial-execution requirement.

- [FluidVoice pinned README](https://github.com/altic-dev/FluidVoice/blob/0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b/README.md): platform requirements and project context.
- [FluidVoice overlay](https://github.com/altic-dev/FluidVoice/blob/0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b/Sources/Fluid/Views/BottomOverlayView.swift), [settings](https://github.com/altic-dev/FluidVoice/blob/0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b/Sources/Fluid/UI/SettingsView.swift), and [hotkeys](https://github.com/altic-dev/FluidVoice/blob/0039d645aa6bec8c7c6f571785bf4b5b7fa2a29b/Sources/Fluid/Services/GlobalHotkeyManager.swift): extraction references, not wholesale dependencies.
- Apple [finish](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/finish%28%29), [endAudio](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest/endaudio%28%29), and [recognizer guidance](https://developer.apple.com/documentation/speech/sfspeechrecognizer?changes=_9): finalization and conservative duration handling. Duration guidance does not prove an identical on-device cutoff on every OS.
- Apple [device selection](https://developer.apple.com/documentation/audiotoolbox/auaudiounit/setdeviceid%28_%3A%29) and [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services): available mechanisms requiring real integration validation.
- Apple [Secure Event Input](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) and [Keyboard settings](https://support.apple.com/guide/mac-help/keyboard-settings-kbdm162/mac): input limitations and system configuration.
