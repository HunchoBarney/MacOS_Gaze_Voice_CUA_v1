# Jarvis: Cua + Jev + continuous voice specification

Status: approved revision recorded on 2026-09-19. Existing migration work is partially implemented; full acceptance remains outstanding. This documentation update does not implement or validate runtime changes. Preserve verified current UI, speech and integration work.

[EXECUTION.md](EXECUTION.md) is the implementing agent's entry point. [PLAN.md](PLAN.md) owns progress and evidence. **S1–S9 below are the active contract.** Earlier specifications retained at the end are historical only, including their incompatible macOS 13, no-Cua, serial-only, and legacy-parser constraints. Later explicit user instructions take precedence subject to system/developer constraints.

## S1 — Product and scope

Keep our existing native UI, Fn push-to-talk, microphone selection, waveform, settings, Activity, and explicit expansion. Complete the migration to Cua Driver and Jev, retaining the already implemented Apple SpeechAnalyzer/SpeechTranscriber path and removing superseded production paths after replacement proof. Astra is the development agent, not a product runtime dependency. The migration targets macOS 26+; verify speech availability, language and hardware on the actual machine rather than assuming the OS version proves readiness.

Deliver continuous natural voice control: complete actionable requests start while Fn remains held; the user can continue with dependent work, another task, a correction, or dictation. Preserve existing useful command outcomes while removing the old implementation. Generalize across installed apps and varied language; do not encode a whitelist of demonstration phrases or silently reduce in-app work to launching apps.

Use Cua's existing execution/session/observation/visualization capabilities and official Jev integration wherever applicable. Cua Driver alone is not an autonomous agent: a small integration must maintain goals, ask Jev bounded questions, invoke supported tools, and inspect outcomes. Prove which upstream capabilities cover each need before adding custom equivalents. The configurable provider supplies generated text and optional advisory reasoning; Jev retains grounded action selection and Cua executes it. Avoid an additional reasoning round trip when the existing Jev/Cua path suffices.

Retain all applicable macOS Driver capabilities rather than a small action whitelist. Capability coverage includes execution, observation, session/cursor controls and relevant setup/diagnostics; it does not require importing every Cua cloud/fleet product. A missing host adapter is unfinished integration, not an upstream platform limitation.

First release excludes gaze, wake words, always-on listening, TTS, automatic window arrangement, VMs/cloud workers, a new UI design, and replacing Jev with another execution model. Shared-desktop agents are included. Do not pull in FluidVoice services or Handy to replace the approved speech choice.

## S2 — Preserved input, UI, and configuration

- Preserve physical Fn down/up behavior, combination pass-through, Escape, microphone selection by stable UID, real metering, interruption cleanup, and no recording while idle. One capture hold at a time; tasks may continue after release and across later holds.
- Fn combinations cancel that capture attempt and prevent incomplete new submissions; already-running independent tasks keep their explicit task lifecycle. Release before asynchronous startup completes must not start a recording later.
- Secure input, tap failure, sleep/lock, microphone loss, or format interruption stop capture and invalidate uncommitted speech. Recovery never resumes capture automatically. Report existing task outcomes separately; do not replay anything on recovery.
- Preserve System Default and explicit-device routing without changing the system input. An unavailable explicit device is visibly unavailable, not silently substituted. Microphone tests use the same capture path without task execution.
- Keep the compact nonactivating pill, transcript, waveform, restrained animation, pointer-display placement/clamping, and explicit Expand/Collapse. Settings and Activity stay hidden until requested. Overlay interaction must not redirect dictation or steal target focus. Respect accessibility labels, Reduce Motion/Transparency, Spaces/fullscreen behavior and existing geometry handling.
- Show listening and task progress simultaneously. Expanded UI lists task/session identity, target, status, cancel/retry controls, and relevant evidence. Keep Stop All visible and distinguish it from the selected-task Stop control. Cua draws its own cursors/badges/animations; pass stable session labels and display the same identities in our UI, without a second cursor renderer. Assign a simple unique label if upstream does not supply one.
- Keep ordinary auto-execution enabled by default and preserve optional manual review. No confidence-based Run prompt for ordinary valid actions. In manual mode, no effects, including streamed insertion, before approval; one approval cannot replay twice. Deletion/purchase operations require confirmation of the exact operation in the pill; unsupported destructive actions remain explicitly unsupported.
- Preserve current Keychain identifiers, API key fallback behavior, preferences, bundle ID `com.chriswozniczek.jevvoice`, clipboard ownership protection, and installed location `~/Library/Caches/JevVoice/build/Jev Voice.app`. Never export credentials into backups/logs. Keep current in-memory Activity behavior; no persistent raw audio/transcript history by default.

## S3 — Speech and incremental intent

Prepare supported on-device speech assets before reporting ready. Settings exposes missing assets, unsupported language, and actionable failures. Keep one persistent SpeechAnalyzer/Transcriber pipeline per Fn hold; carry audio ranges, revisions and finality rather than only replacing a transcript string. Finalization drains accepted audio without losing trailing words. Reuse bounded startup/finalization/interruption cleanup; the current two-second finalization timeout and 50/55-second warning/limit are starting defaults, not SpeechAnalyzer guarantees. Adjust only with recorded evidence and preserved behavior.

Reuse tested voice turn/lifecycle mechanisms where they fit, including inference triggers distinct from semantic completion and invalidation of superseded speculative work. They must support multiple completed requests within one Fn hold, not wait for the entire conversation turn. Apple remains the STT source; importing another complete voice stack is not a requirement.

Use focused Jev judgments for semantic completeness, commands versus content, task relationship, routing, and correction. Include relevant speech and task/app state. Batch independent judgments when supported, coalesce unchanged input, cancel superseded requests, and discard stale results. Do not call a model for every audio buffer or use pauses/punctuation alone as proof of completeness. Missing arguments, negation, conditions, and incomplete searches must not dispatch.

Keep consumed speech/action history separate from pending revisions. Give captures, tasks and actions stable identities, and tie decisions to their speech revision and observed target. Releasing Fn finalizes only remaining input; it never repeats completed actions. Repeated intentional requests remain possible. A later hold may add or modify a task while prior tasks run. Noise, silence and conversational filler alone have no effect.

A natural transition can add a task without cancelling earlier work: for example, a weather search followed by a request to draft a message. “Actually” is contextual, not an unconditional cancel token. Ambiguous target/recipient/task references ask a concise question in the pill; varied polite wording does not require special syntax.

## S4 — Dictation and corrections

Infer text entry where context supports it, without interpreting every occurrence of “type” as a permanent mode switch. Explicit “dictate” makes the rest of that hold literal content, including agent names and words such as “stop.” For natural mixed speech, resolve ambiguous content/control boundaries before side effects. Exercise punctuation, self-correction, app names inside content, and switching back to commands in tests.

Stream text through Cua only where addressed replacement and readback allow reconciling the insertion owned by this hold. Verify target, selection, and surrounding content before replacing a revision. User edits, target loss, or ownership mismatch halt insertion instead of overwriting unrelated text. Final text updates the owned insertion once. Otherwise show “inserts on release” and insert once after finalization. Live TextEdit dictation is required. Inspect upstream range/readback mechanisms and, where needed, add a minimal generic addressed-range contract in Cua with ownership validation. A single-line commit API is not proof of multiline revision support. A remaining technical blocker stays open; release fallback does not pass TextEdit acceptance and the legacy executor must not be revived.

Spoken “stop <agent>” cancels that task's pending work; “stop all” cancels all tasks. Unqualified stop refers to the selected/unambiguous task, with clarification if needed. Escape ends the current voice interaction and cancels its selected task; a separate Stop All remains available. Literal spans take precedence over spoken control words. Cancellation is checked before dispatch and after awaits; late results cannot restart work. Already-dispatched effects may finish and must be reported honestly.

Corrections revise pending work and may compensate eligible app launches. Track pre-launch state and process/target ownership; reobserve before reversal. Normally quit only an app launched by this task with observed evidence that no subsequent edits/user work make reversal unsafe. A missing or false edited flag alone is insufficient, including for autosaving documents. Never force quit, discard content, dismiss save dialogs, or close an already-running user's app to simulate undo. Restore prior visibility/focus only where supported and still appropriate. No general rollback promise for every GUI action.

## S5 — Cua execution and multiple agents

Maintain persistent Driver connections/sessions through the upstream supported transport. Default to three active tasks and queue additional independent tasks; keep this limit configurable internally and justify changes with measurements. Each task has context, action history and cancellation. Dependent steps await observed prerequisites. Independent observations/model work may overlap; coordinate conflicting mutations and multi-step sequences by their actual resources. Prefer independently addressable window/tab/document ownership; application-global menus, clipboard and focus-sensitive sequences may require broader coordination. Do not serialize all tasks for an entire app unnecessarily or assume separate windows isolate global state.

Use dynamic app/window/control observations and the selected upstream action contracts, including relevant keyboard, pointer, drag, scroll, menu, custom AX, browser and text/value capabilities. Expand incomplete observations before declaring targets absent. Keep stable target identity and relevant preconditions; unrelated animation or page changes must not invalidate an otherwise valid target. Distinguish duplicate dispatch IDs from intentional repeated actions, such as scrolling again. Reobserve after significant changes and verify external outcomes where observable. Success means the intended effect, not merely an accepted tool call. Distinguish success, failure, cancellation, and uncertain outcome. Never automatically retry an uncertain mutation after a timeout, connection loss, or helper restart. An explicit retry must inspect state first.

Provide local native OCR and icon/visual detection alongside semantic AX/DOM observations. Prefer the Cua native perception source implementation identified in PLAN.md, including unmerged code when needed. Build and validate its actual contracts; draft status alone is not a blocker. Visual choices need meaningful descriptions and verified capture/window/display coordinate provenance. Stale or mismatched perception cannot authorize a click. An alternate backend requires a recorded technical reason and the same outcome checks.

Preserve Cua background targeting and visual feedback. Cua's process-level input serialization is not transaction isolation or a guarantee that every app supports background work. Protect user-active edits; conflicting actions wait with visible status. An explicit open/show request authorizes bringing its requested target forward. A background operation that requires foreground participation waits visibly instead of silently taking over. Test multiple displays using actual window identity and documented coordinate contracts; do not equate multiple cursors with independent OS focus. No automatic window placement in this release.

## S6 — Optional reasoning and text generation

Preserve the configured Groq provider and selected model (last recorded: `qwen/qwen3.8-27b`); verify availability and supported parameters against the actual provider rather than silently switching models. It may supply prose, task decomposition or recovery guidance; Jev selects grounded actions and Cua executes them. Generated plans are advisory data, never executable scripts or authority to bypass action/target checks. No provider credential is required for ordinary Jev/Cua actions.

Provide endpoint/model/key configuration and connection testing for an OpenAI-compatible chat-completions provider, with presets for Groq, Cerebras, Gemini's compatible endpoint, and local/custom endpoints where verified. Store secrets separately from Jev credentials. No additional model is required for ordinary navigation/execution. A missing or failed text provider blocks only generation and produces an actionable explanation; never silently upload to another provider.

Jev selects when to request generated text, the relevant observed context, and the destination/action. For generation requests the provider returns prose; optional reasoning returns advisory data subject to the same grounded Jev/Cua checks. Page summarization appears in expanded UI; replying composes a draft by default. An explicit request to send (including “send it” for an unambiguous draft) authorizes that operation without another generic Run gate once recipient/content are resolved. Never infer authorization to send from a request to draft. Implementation verification uses disposable local fixtures, not messages to real contacts without separate explicit authorization.

Cancel/revise invalidates pending generation and any dependent insertion/send. Do not apply late output to a new task or changed recipient. Include only context necessary for the requested generation; keep private content and keys out of evidence logs.

## S7 — Migration and implementation boundaries

Retain UI/input/configuration behavior; remove replaced native execution, hard-coded phrase/slot planning, old speech capture, obsolete probes and unused dependencies only after replacement checks pass. Preserve reusable types/tests when they still express the contract; do not retain two competing production executors or a hidden legacy fallback. Update tests whose behavior is explicitly superseded, with a reason; do not delete regressions merely because their original implementation is removed.

Preserve the existing Swift UI/audio and private-stdio Swift MCP integration unless a simpler verified alternative warrants a recorded change. Do not add the previously proposed Python helper solely to match old planning. Pin the selected Driver base, perception assets, adopted PR heads/dependencies and local repairs; record build and rollback procedures. Use an isolated upstream checkout. Current stable code is a baseline to evaluate, not a ban on building required unmerged features. Check ancestry and overlapping patches, then validate the combined build rather than adding every candidate blindly. Preserve MCP structured and image results and verify schema compatibility. No launch-time dependency installation or hidden developer-shell assumption.

## S8 — Acceptance and performance

Every required family in PLAN.md must pass or remain explicitly blocked. Combined workflows and varied phrasings supplement unit tests. An aggregate pass rate cannot excuse broken cancellation, duplicate effects, unintended sends, lost user text, or focus takeover. Keep simulated checks, observed macOS outcomes, and user-reported physical tests separate.

Retain targets of feedback within 100 ms and warm complete-command-to-action-start p95 within two seconds for simple supported commands, with the action beginning before Fn release. Measure from the spoken command's completion as well as from transcript availability so recognition delay is visible. Record sample count, environment, cold/warm state, failures and median/p95; small samples are preliminary observations. Accuracy target: at least 90% across at least 30 varied valid requests, while every mandatory scenario family passes and critical invariants have zero observed violations. These are release targets, not current measurements or universal guarantees.

Measure microphone readiness, first/revised/final transcript, Jev latency, queue wait, Cua dispatch, verified result, cancellation acknowledgement and cessation separately. Record perception cold/warm latency, memory and misses, and distinguish queueing, provider/credential access and Driver settling from model inference. Collect at least 30 warm simple-action samples for preliminary latency estimates in addition to the varied-request accuracy sample. Never use the X clip's timestamps as a runtime benchmark. Correctness takes priority over speculative early actions.

## S9 — Delivery

Deliver a tested, reviewed, running package at the preserved path, with bundled helper dependencies, validated Cua installation/connection, visible setup instructions, measured timings, known limitations and a verified rollback location. A dependency on the selected signed Cua Driver and perception worker/assets must be explicit and validated; a stock auto-update must not silently replace required source patches; do not silently assume a development environment on another Mac. Preserve signing identity where available. Ad-hoc signing may still require user-controlled permission regrants; never reset TCC or invent credentials.

Completion requires all required acceptance evidence. A physical-input or external prerequisite blocker is a blocker, not a pass. Continue independent work and report exact remaining validation without claiming completion.

## Source basis

These sources inform mechanisms and planning; they do not prove our future implementation. Inspect the actual pinned APIs/source during implementation before relying on a capability.

- [Cua Jev integration](https://cua.ai/docs/how-to-guides/driver/jev-use): starting integration, not proof of a universal voice agent.
- [Cua process model](https://cua.ai/docs/reference/cua-driver/process-model), [background contract](https://cua.ai/docs/concepts/the-no-foreground-contract), [cursor personalization](https://cua.ai/docs/how-to-guides/driver/personalize-cursor), [coordinate contracts](https://cua.ai/docs/reference/cua-driver/contracts).
- [TypeSafe documentation index](https://docs.typesafe.ai/llms.txt): current SDK, typed questions, state and Jev contracts; read the relevant linked pages.
- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber).
- Candidate Cua PRs and voice-coordination source mechanisms are linked in PLAN.md; upstream author results are not product acceptance.
- Astra execution/planning sources are recorded in EXECUTION.md. The X demo is an interaction reference, not implementation evidence.

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
