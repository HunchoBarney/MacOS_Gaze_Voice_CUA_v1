# Jarvis: Cua + Jev + continuous voice specification

Status: approved revision recorded on 2026-09-19. Existing migration work is partially implemented; full acceptance remains outstanding. This documentation update does not implement or validate runtime changes. Preserve verified current UI, speech and integration work.

[EXECUTION.md](EXECUTION.md) is the implementing agent's entry point. [PLAN.md](PLAN.md) owns current progress; [EVIDENCE.md](EVIDENCE.md) owns recorded build evidence. **S1–S9 below are the active contract.** Earlier specifications retained in HISTORY.md are historical only, including their incompatible macOS 13, no-Cua, serial-only, and legacy-parser constraints. Later explicit user instructions take precedence subject to system/developer constraints.

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

## Historical reference

Superseded UI/native-executor requirements are preserved in [HISTORY.md](HISTORY.md#historical-specification--inactive-reference-only). S1–S9 above remain the active contract.
