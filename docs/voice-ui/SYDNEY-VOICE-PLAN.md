# Sydney Voice Reliability and Natural Understanding — Execution Plan

**Status:** Implementation authorized and started on 2026-09-21, including scoped live checks and real-Jev evaluation. Physical trials require user participation. Acceptance remains open.

**Workspace:** `/Users/karanvirkang/conductor/workspaces/JarvisMacOSv1/sydney`

**Target branch:** `origin/main`. Do not rename the workspace branch.

**Goal:** Make ordinary spoken requests reliably captured, correctly understood, and promptly handed to the existing execution path, including pauses, revisions, negation, supplied text, and corrections.

**Architecture:** Retain the native Swift capture pipeline and Jev interpretation. Improve the existing voice components and their integration. Preserve the `JevVoice` and `JevVoiceCore` module boundaries. Astra is the development agent executing this plan; Apple SpeechAnalyzer and Jev remain the app's voice stack.

## 1. Authority and execution instructions

This document contains the complete work plan for voice development in the Sydney worktree.

[`SPEC.md`](SPEC.md) remains the active product specification. This work implements its voice requirements from S2, S3, the understanding portions of S4, and applicable S8 measurements. The broader [`PLAN.md`](PLAN.md) continues to own migration-wide gates. Completing this document does not complete that migration.

The user has explicitly assigned context delivery, gaze integration, Cua work, and live dictation to other worktrees. Those assignments narrow this worktree's scope. This document is the execution entry point for the scoped voice work; do not interpret it as authorization to execute the broader migration in `EXECUTION.md`.

Once the user authorizes implementation:

- Execute the milestones without requesting approval after each one.
- Make routine implementation decisions within the stated behavior and ownership boundaries.
- Read the relevant repository instructions and source on entry; reread when changes or a specific uncertainty warrant it.
- Fix regressions caused by this work before dependent milestones proceed.
- Continue independent work when another milestone requires physical testing or an external dependency.
- Record decisions that change the approach, including the evidence and affected acceptance criteria.
- Finish when the defined gates pass. Do not add unrelated cleanup or another verification cycle without a concrete reason.

Physical microphone/Fn trials and opt-in live checks follow [`DEVELOPMENT.md`](../DEVELOPMENT.md). Reuse authorization already granted for a specific check. If human participation is still required, identify the exact trial needed. Use the shared desktop lock for live checks and one desktop owner at a time.

Approval to save this plan is separate from an instruction to execute it.

## 2. Scope

This worktree owns:

- Fn-to-capture lifecycle and truthful microphone readiness.
- Audio delivery, recognition completion, and trailing-word preservation.
- Transcript revisions, source spans, recognition finality, and capture identity.
- Natural command understanding.
- Distinguishing instructions from supplied or quoted content.
- Recognizing negation, incompleteness, self-repair, and spoken cancellation.
- Voice-side interpretation scheduling and stale-result rejection.
- Voice feedback and error handling.
- Voice-specific evaluation and latency measurement.

It does not implement:

- Context collection, projection, delivery, or a new context schema.
- Gaze tracking, gaze timing integration, or reference resolution.
- Cua capabilities, desktop actions, task scheduling, or rollback.
- Live insertion, text-range ownership, selection replacement, or dictation reconciliation.
- Wake words, always-on listening, TTS, or a voice-stack replacement.
- A new generation provider or an Astra runtime dependency.

The existing context input remains available to interpretation without being redesigned here. The voice layer may recognize an unresolved reference such as “that”; resolving the referenced object remains downstream.

## 3. Required user-visible behavior

The completed voice work must support the following:

| Situation | Required behavior |
| --- | --- |
| Speak a short request and release immediately after the final word | Preserve the request without requiring an extra hold. |
| Release before asynchronous startup finishes | Cancel the attempt; recording must not begin afterward. |
| Pause while holding Fn | Continue listening. |
| Give a complete command while holding Fn | Make it eligible for early handoff when recognition stability and meaning support it. |
| Say an unfinished request | Wait for more speech; after release, identify the missing information. |
| Use polite, indirect, or casual wording | Understand the request without a demonstration-phrase whitelist. |
| Negate a request | Do not turn it into its positive counterpart. |
| Correct an unsubmitted sentence | Revise the pending interpretation. |
| Correct an earlier submitted request | Recognize a correction and use the existing downstream handling. |
| Include “stop,” application names, or instructions inside supplied text | Preserve them as content. |
| Repeat the same request intentionally | Preserve both requests. |
| Receive duplicate transcript callbacks or release after an early handoff | Do not repeat a submission. |
| Encounter recognition or model failure | Report the actual failure and preserve recoverable speech without automatic replay. |

Preserve existing manual review behavior and explicit Escape/Stop semantics. An ordinary valid command must not acquire a generic confidence-based Run prompt.

## 4. Starting evidence and source map

The existing implementation already provides microphone selection, prewarming, bounded audio delivery, converter draining, ranged transcripts, cancellation generations, and several no-replay protections. Preserve working behavior rather than reimplementing it.

The current investigation establishes:

- Physical quick-release failures are recorded in [`EVIDENCE.md`](EVIDENCE.md); their root cause remains unresolved.
- Recorded short audio has succeeded where the physical path failed.
- Recognition finality can change without text changing, while the current partial-text path can skip fresh interpretation.
- A provisional command can be submitted before subsequent recognition revises it.
- Revisions to consumed wording currently fail closed.
- Interpretation uses an overloaded wait outcome and independent boundary/type judgments.
- The current interpretation and extraction helpers reject inputs beyond 128 words.
- Many tests inject model answers, and some voice tests exercise retained legacy paths.

These findings describe the inspected planning baseline. Recheck affected code at implementation entry; do not assume another worktree's changes are present here.

Primary source ownership (paths are relative to the repository root):

| Area | Files |
| --- | --- |
| Capture | `Sources/JevVoice/Voice/SpeechAnalyzerCapture.swift`, `Sources/JevVoice/Voice/SpeechCapturing.swift` |
| Input/device behavior | `Sources/JevVoice/Voice/FnInput.swift`, `Sources/JevVoice/Voice/MicrophoneCatalog.swift` |
| Interpretation coordination | `Sources/JevVoice/Voice/ContinuousIntentCoordinator.swift` |
| Voice integration and feedback | `Sources/JevVoice/Voice/VoiceController.swift` |
| Transcript identity and consumption | `Sources/JevVoiceCore/Speech/SpeechRevision.swift`, `Sources/JevVoiceCore/Speech/SpeechConsumption.swift` |
| Semantic judgments and source extraction | `Sources/JevVoiceCore/Models/JevSpeechIntent.swift` |

Use existing tests in `Tests/JevVoiceAppTests/Voice` and `Tests/JevVoiceTests/Voice`, plus `Tests/JevVoiceTests/SettingsAndModels/JevSpeechIntentTests.swift`.

`Tests/JevVoiceAppTests/ComputerControl/CuaVoiceControllerTests.swift` contains production-wiring fixtures. It may be used to verify voice integration without expanding into Cua implementation.

Add focused files only when a responsibility warrants them. Do not create a generic workflow engine or broad coordinator abstraction.

## 5. Voice boundary and invariants

Preserve the existing capture and execution-facing contracts wherever practical:

- Capture starts with a session identity and selected microphone.
- Recognition reports text, audio ranges, revisions, finality, and timing.
- The coordinator hands off `SpeechIntent` values through the existing submission boundary.
- Supplied text retains its source provenance.
- Existing context passes through without a new delivery mechanism.

Richer interpretation states belong inside the voice layer. They must distinguish:

- A ready request.
- Speech that is still incomplete.
- An utterance needing clarification.
- Speech containing no request.
- A recognition or model failure.
- Explicit cancellation.

There are three independent completion signals:

1. **Recognition finality:** Apple has finalized a segment's transcription.
2. **Semantic completeness:** the request contains enough meaning to proceed.
3. **Capture completion:** Fn was released and accepted audio has been finalized.

An implementation must not equate these signals.

Maintain separate pending and handed-off speech. A candidate result is not a submission. A successful handoff is not proof that a desktop action completed.

No source span may become replayable merely because submission returned an uncertain error.

## 6. Milestone V0 — Establish the baseline

**Deliverable:** A reproducible starting point and a voice evaluation manifest.

At workspace entry:

- Inspect the current branch, revision, and local changes.
- Read `README.md`, relevant `docs/ARCHITECTURE.md` sections, and `docs/DEVELOPMENT.md`.
- Compare this plan's source assumptions against the actual checkout.
- Record existing failures separately from new regressions.
- Preserve credentials, preferences, dependency pins, app identities, and unrelated work.

Run the relevant existing checks from the workspace root:

```sh
make setup
swift test --filter 'FnInputTests|MicrophoneTests|AnalyzerAudioFeedTests|RangedTranscriptTests|SpeechConsumptionTests|ContinuousIntentTests|JevSpeechIntentTests|VoiceSessionTests|CuaVoiceControllerTests'
```

These commands are for implementation time. Passing simulated tests does not close physical acceptance.

Define evaluation records containing the case ID, expected behavior, transcript/revision sequence, capture completion, observed interpretation, timing, and failure classification.

**Gate:** The baseline identifies what currently passes, what fails, and what remains untested. No historical pass is represented as a new result.

## 7. Milestone V1 — Build the voice evaluation path

**Deliverable:** Repeatable evaluation through the real voice components with a non-executing submission sink.

Extend the existing injection seams so tests can:

- Deliver timed speech revisions and finalization events.
- Delay or fail interpretation.
- Observe submitted intents without desktop actions.
- Record the difference between a candidate, a handoff, and a discarded result.
- Evaluate real Jev judgments separately from injected answers.

Proposed additions:

- `Tests/JevVoiceAppTests/Voice/VoiceUnderstandingEvaluationTests.swift`
- `Tests/Fixtures/Voice/understanding.json`

The fixture manifest should contain separate development and held-out cases. Audio fixtures must identify their origin and whether they are synthetic or human-recorded.

Real-model evaluation must be explicitly gated. The default suite must not read a real credential or contact a paid service merely because the test file exists.

Use the existing configured Jev integration. Record the configured model and returned model identifier where available. Document the exact opt-in invocation when the evaluation harness is implemented; an explicitly requested evaluation with missing prerequisites must be reported as unmet, not counted as a pass.

**Gate:** A deliberately wrong interpretation fails evaluation; a stale response cannot be counted as a successful handoff; semantic results and simulated lifecycle results are reported separately.

## 8. Milestone V2 — Resolve capture and immediate-release failures

**Deliverable:** Reliable capture completion backed by physical evidence.

Investigate:

`Fn down → startup → first audio → audio callbacks → Fn release → drain → analyzer finalization → result delivery`

Use existing instrumentation first. Add missing content-free measurements only where needed to distinguish causes.

Compare:

- Physical immediate release.
- Physical release after a pause.
- Short recorded audio with immediate end of input.
- Cold and warm capture.
- Selected microphone and available alternative devices.

Check whether audio was captured, converted, accepted by the analyzer, finalized, and delivered to the result stream.

Implement the smallest fix supported by the reproduction. Do not assume a timeout increase, extra silence, or another converter drain solves the reported failure.

Preserve:

- No recording while idle.
- No delayed startup after release.
- Bounded buffering and explicit overflow failure.
- Correct teardown on cancellation and device interruption.
- No automatic microphone substitution.
- Available transcript recovery after failure.
- Existing recording limits unless evidence justifies a change.

Validate with:

```sh
swift test --filter 'AnalyzerAudioFeedTests|MicrophoneTests|FnInputTests|VoiceSessionTests'
```

Use the existing opt-in `SpeechAnalyzerIntegrationTests` for recorded audio. Physical checks require the actual Fn/microphone path.

**Gate:** The identified failure has supporting before/after evidence, and immediate-release physical trials no longer reproduce it. If physical reproduction is unavailable, keep this gate open and continue independent milestones.

## 9. Milestone V3 — Make interpretation revision-aware

**Deliverable:** Correct interpretation over changing speech without losing early-handoff behavior.

Update the capture/controller/coordinator path so meaningful metadata changes reach interpretation, including unchanged-text finalization.

Preserve original spacing, paragraphs, Unicode, and the relationship between selected text and its recognition revision. Do not fabricate word-level timing where only segment timing exists.

Establish an explicit policy for early eligibility:

- Semantic completeness is required.
- Recognition stability contributes evidence.
- Missing arguments or an attached unfinished condition prevent handoff.
- A pause or punctuation mark alone is insufficient.
- New speech that changes the candidate invalidates or rechecks the candidate.
- Complete requests can become eligible before Fn release.

Preserve the consumed-speech ledger's no-replay protection. Do not “fix” committed revisions by making previously submitted text pending again.

Required timeline cases include:

- Same text, volatile → finalized.
- A changed application name before handoff.
- A search query extended while interpretation is running.
- Duplicate recognition events.
- Repeated identical spoken requests.
- Release while a judgment is pending.
- Cancellation followed by a late response.
- A new capture receiving an old capture's callback.

Validate with:

```sh
swift test --filter 'RangedTranscriptTests|SpeechConsumptionTests|ContinuousIntentTests|CuaVoiceControllerTests'
```

**Gate:** All timeline invariants pass, including production voice wiring. The change retains eligible before-release handoff.

## 10. Milestone V4 — Improve semantic understanding

**Deliverable:** Accurate command/content decisions and useful non-action outcomes.

Improve `JevSpeechIntent` judgments around:

- Indirect requests and casual phrasing.
- Filler and false starts.
- Negation and conditions.
- Incomplete arguments.
- Connected requests versus independent requests.
- Text-entry instructions and literal content.
- Self-repair and correction.
- Ordinary speech that contains command vocabulary.

Boundary and type judgments must refer to the same candidate span. Batch independent judgments; use dependent refinement when necessary. Evaluate the latency and correctness of that choice.

Preserve source text rather than introducing a generative transcript-cleanup pass.

Required examples include:

| Input and situation | Expected interpretation |
| --- | --- |
| “Could you bring up Calculator?” | Command. |
| “Open Safari and search for hiking boots.” | Preserve the connected request and full query. |
| “Search for…” while held | Await more speech. |
| “Search for…” after release | Missing query identified. |
| “Don't open Safari,” with no earlier request to correct | No positive open request. |
| “Open Notes—no, Maps,” before handoff | One effective request for Maps. |
| “Actually, also open Calendar.” | Additional request when the wording supports it. |
| “Type the words stop all.” | Literal content, not cancellation. |
| Explicit dictate mode followed by application names | Literal content. |
| “I was talking about opening Safari.” | Mentioning an action does not automatically request it. |

An explicit dictate request retains the specified literal meaning for the rest of that hold. This milestone does not implement insertion or alter live-dictation timing.

**Gate:** Held-out real-model evaluations meet the quality criteria below. A mocked choice alone cannot satisfy this milestone.

## 11. Milestone V5 — Correct repair, cancellation, and failure behavior

**Deliverable:** Voice failures and corrections affect only the intended voice state and requests.

Treat these separately:

- ASR changed its transcription.
- The user repaired an unsubmitted sentence.
- The user corrected an earlier submitted request.
- The user explicitly requested cancellation.
- Recognition or the model failed.

A repair within pending speech must not accidentally cancel an unrelated earlier task.

Before handoff, supersede the pending interpretation. After handoff, use the existing correction/cancellation interface; desktop compensation remains outside this worktree.

Remove the voice-controller coupling that turns an ordinary interpretation error into an unintended selected-task cancellation. Preserve explicitly requested cancellation behavior.

Feedback must distinguish missing speech, incomplete meaning, recognition failure, and service failure. Do not label a network failure as a bad user command.

Required checks:

- An incomplete released utterance does not cancel another request.
- Model failure does not replay previously submitted speech.
- Literal “stop” does not trigger cancellation.
- Explicit cancellation invalidates pending interpretations.
- A late result cannot revive cancelled work.
- A subsequent hold starts with fresh capture state.
- Manual mode retains its existing approval boundary.

**Gate:** Focused coordinator/controller tests pass through the current production wiring, with no new task-execution behavior.

## 12. Milestone V6 — Improve bounded processing and speed

**Deliverable:** Measured latency improvement without a correctness regression.

Optimize the stages identified by the baseline:

- Reuse supported speech preparation.
- Coalesce redundant updates.
- Cancel superseded work.
- Avoid model requests for every audio buffer.
- Reduce duplicated prefix text in boundary-selection input.
- Keep source text available independently of compact model representations.

Replace the accidental 128-word failure behavior with bounded processing that preserves the utterance. Test below, at, and above the existing boundary.

A long request must not be silently truncated, split into invented commands, or discarded through a generic error. When an indivisible request cannot be confidently interpreted within limits, retain it and report that limitation.

Compare `fastResults` configurations on the same audio before changing the existing choice.

Performance targets:

- Feedback within **100 ms**.
- Warm transcript-to-ready-interpretation **p95 ≤1 second** for self-contained simple requests: the voice-stage engineering target introduced by this plan, not an existing measurement.
- Report spoken-completion-to-interpretation separately.
- Preserve the broader **two-second spoken-completion-to-action-start** integration target without claiming voice-only tests prove it.

The one-second target is a measurement goal, not a cancellation deadline. Slower valid requests must not be discarded to improve the reported number.

**Gate:** Matched-workload results show improvement without worse premature handoffs, content/control confusion, or missed requests. Missed targets remain visible.

## 13. Milestone V7 — Complete verification and delivery

**Deliverable:** A tested voice implementation, reproducible evidence, and an accurate handoff.

Run relevant focused checks as changes are made. At final integration:

```sh
make test
make app
codesign --verify --deep --strict "build/Jev Voice.app"
git diff --check
git diff origin/main...
```

Review the complete affected voice path, including production wiring. Include uncommitted and untracked work in the review: the three-dot branch comparison alone does not show it. Preserve useful legacy regression coverage; this plan does not authorize broad legacy removal.

Do not replace an installed bundle merely to complete packaging. Physical acceptance uses an identified build and the shared-desktop procedure.

Record concise build-specific voice results in [`EVIDENCE.md`](EVIDENCE.md). Keep detailed non-sensitive artifacts under `.context/voice/`, with paths and reproduction commands referenced from this document. Do not introduce persistent raw audio/transcript history by default or include credentials in artifacts.

**Gate:** All owned acceptance criteria are supported, relevant checks pass, and material review findings are resolved. Outstanding physical or external requirements remain explicitly open.

## 14. Evaluation and acceptance criteria

Use a development set and a separate **minimum 60-case held-out set**:

- 30 varied valid requests.
- 15 negative, quoted, or non-command cases.
- 15 incomplete, ambiguous, or correction scenarios.

Split by related phrase/workflow family so near-identical paraphrases do not leak across development and evaluation.

If held-out failures are used for tuning, mark those cases as development cases and replenish the held-out set.

Measure:

- Correct full interpretation, including boundaries and supplied arguments.
- False command handoffs.
- Premature handoffs.
- Missed valid requests.
- Unnecessary clarification.
- Correct handling of incomplete and ambiguous speech.
- Recognition errors that change command meaning.
- Revision stability.
- Latency and model-call count.

Required acceptance:

- At least **90% full-interpretation accuracy** across the valid held-out requests.
- Every required voice scenario family represented and passing its mandatory cases.
- Zero observed critical violations in the evaluation suite: duplicate handoff, stale-result revival, positive execution intent from known negation, or literal control words becoming cancellation.
- At least **30 warm latency samples**, with cold samples, failures, and timeouts reported separately.
- Repeated physical immediate-release trials on the actual microphone path.
- Passing relevant regressions and final build verification.

A p95 from 30 samples is preliminary evidence. Zero observed critical failures is a result for that suite, not a universal guarantee.

Classify evidence explicitly as:

1. Deterministic logic/injected-decision tests.
2. Recorded-audio recognition.
3. Real-model semantic evaluation.
4. User-reported physical Fn/microphone trials.
5. Observed behavior of the identified app build.

## 15. Decision boundaries and recovery

Astra may choose internal helper structure, scheduling details, and tested prompt formulations within this scope. Record material choices and their evidence.

Reconsider the plan when evidence shows a chosen mechanism cannot meet its gate. Do not repeatedly retry the same failed approach without a new hypothesis.

Preserve existing context and execution-facing interfaces where possible. If a shared integration point has changed in another worktree, inspect the new contract and adapt the voice side. Do not build a competing context or execution system.

For recovery:

- Preserve the initial dirty state and unrelated files.
- Revert only this worktree's identified changes when necessary.
- Never hard-reset over other work.
- Preserve installed app identities, preferences, Keychain entries, and pinned dependencies.
- Do not delete `development/` as cleanup.
- Keep retries from automatically replaying uncertain submissions.

If a milestone requires something outside scope, record the exact dependency and continue independent work. Do not silently weaken its acceptance criteria.

## 16. Progress, decisions, and resumption

Maintain these records as execution proceeds:

- **Progress:** each milestone's actual status and remaining work.
- **Discoveries:** observations with source, test, or log evidence.
- **Decisions:** choice, rationale, evidence, and affected milestones.
- **Verification:** build identity, commands, results, skips, and evidence category.
- **Next action:** one concrete step a fresh session can perform.
- **Outcome:** what works, what remains, and which gates are still open.

### Progress

- [x] User approved the plan and requested this worktree-specific document.
- [x] Save the approved plan. This is documentation work only.
- [x] V0 — Establish the baseline.
- [x] V1 — Build the voice evaluation path.
- [ ] V2 — Resolve capture and immediate-release failures, including physical evidence.
- [x] V3 — Make interpretation revision-aware.
- [x] V4 — Improve semantic understanding.
- [x] V5 — Correct repair, cancellation, and failure behavior.
- [ ] V6 — Improve bounded processing and speed.
- [ ] V7 — Complete verification and delivery.

V0 passed: make setup and 69 focused tests, zero failures. V1 manifest/scorer and non-executing real-Jev harness implemented; default tests skip before credential access. Baseline HEAD `d756cf37931d12a85d2e35aef45d9ff3dd7664b8`, branch `chore/review-voice-commands`; only initial local change was this untracked plan. See `.context/voice/baseline.md` and `baseline-tests.log`.

### Discoveries

- Baseline findings confirmed: metadata filtering, volatile early handoff, selected-task cancellation on interpretation error, 128-word limit, and independently classified spans.
- Initial stricter recognition-finality gating passed simulated tests but user physical feedback showed requests waiting until release. Replaced with semantic completeness plus unchanged-revision stability (350ms), while finalized spans are immediately eligible. Physical confirmation remains open.
- User physical feedback on initial executable `53e862ec…42995dd`: UI flicker, intermittent Calculator failures, and delayed handoff until release. Not a pass.
- Activity inspection showed multiple captured requests failing in downstream Cua with “pinned target window closed” and “prerequisite task did not complete.” These are execution dependencies outside Sydney voice ownership.
- Synthetic 0.988s recorded audio preserved the last word; immediate-EOF finalization 196ms. Matched fastResults on/off runs all preserved content (58–74ms finalization); retain current fastResults setting.
- TypeSafe API Choice limit is 255. Grouped source selection uses <=205 options and retains up to 2048 words; larger indivisible input remains recoverable with explicit limitation.

### Decision log

- **2026-09-21 — Scope:** Own voice capture and understanding only. Context delivery, gaze, Cua, and live dictation remain assigned elsewhere, following the user's explicit scope reductions.
- **2026-09-21 — Stack:** Retain Apple SpeechAnalyzer and Jev. Astra executes development work and is not a product runtime dependency.
- **2026-09-21 — Execution style:** Use outcome-based milestones, explicit acceptance, proportionate verification, and durable progress records so Astra can continue without repeated routine approval requests.
- **2026-09-21 — Performance:** Treat the one-second interpretation target as an engineering goal, not a timeout or a claimed result.
- **2026-09-21 — Authorization:** User authorized full V0–V7 implementation, existing-configuration real-Jev evaluation, and scoped live checks. Preserve all acceptance requirements; request participation for physical trials.

### Verification record

Implementation and automated verification are recorded in EVIDENCE.md under Sydney execution 2026-09-21. Fresh held-out round 2: 28/30 valid (93.3%), all 30 negative/scenario cases correct, zero critical; first failed held-out set retired into development before tuning. Six real-model delayed-response timelines passed. Thirty warm matched simple-command samples: revised median154ms/p95237ms versus baseline132ms/217ms. Interpretation target met, baseline improvement not established. Recorded synthetic immediate-EOF audio retained its final word; physical acceptance remains failed/unverified. V3–V5 checks mark owned implementation/semantic gates only, not physical or downstream execution acceptance.

### Next action

Final build6ce651ba…32d5646 was physically tested; user confirmed done. See EVIDENCE.md and .context/voice/physical-trials.md. Investigate capture25179426 (recognition updates but no terminal event/task) and post-handoff recognition revision to “Open calculatorcul”. Preserve no-replay behavior; do not suppress legitimate corrections to mask the issue. Four immediate-release transcripts retained their last word; both longer holds submitted before release, but end-to-end acceptance failed (three of six tasks completed, three downstream failures). No further physical participation request until these findings are addressed. V6 baseline speed improvement and V2/V7 physical/UI/integrated gates remain open. Shared desktop lock released after inspection.

### Outcome

Voice implementation, regression coverage, recorded-audio checks, held-out semantic evaluation and warm measurements are delivered. Overall execution is NOT COMPLETE: physical capture/early handoff/flicker and integrated action acceptance remain open, and matched baseline speed improvement is unproven.

### Resumption protocol

On resumption, read this document's current state, inspect changes since its recorded revision, and continue from the first unfinished unblocked milestone. Do not restart the investigation merely because the chat context is gone.

The final implementation report must state what changed, what was actually verified, measured quality and latency, and any remaining requirements. It must not claim that context delivery, gaze, live dictation, Cua, or the broader migration was completed by this voice work.

## Research references

These references support the chosen approach; the required execution instructions and acceptance criteria are contained above. Revisit a source when a concrete implementation question warrants it rather than rereading every reference at each milestone.

- [OpenAI Astra prompting guidance](https://developers.openai.com/api/docs/guides/latest-model): explicit completion, appropriate autonomy, and proportionate testing.
- [Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra): focused instructions, contextual reading, and avoiding excessive procedural constraints.
- [Using PLANS.md for multi-hour problem solving](https://developers.openai.com/cookbook/articles/codex_exec_plans): resumable plans with observable outcomes, decision records, and evidence.
- [Apple SpeechAnalyzer guidance](https://developer.apple.com/videos/play/wwdc2025/277/): volatile/finalized results, audio ranges, and transcription lifecycle.
- [Handy recording shutdown change](https://github.com/cjpais/Handy/commit/d86e3df): a reference for investigating audio at the stop boundary, not proof of the same defect in Jarvis.
- [Pipecat deferred completion strategy](https://github.com/pipecat-ai/pipecat/blob/06cc27c0754561530f1e3c73d01768f74c1ea206/src/pipecat/turns/user_stop/deferred_user_turn_stop_strategy.py): distinguish inference triggers from completion.
- [LiveKit turn-taking tuning](https://docs.livekit.io/agents/logic/turns/tuning/): separate endpointing, interruption, and speculative work.
- [Incremental speech evaluation research](https://aclanthology.org/2020.coling-main.312/): evaluate accuracy, latency, and revision stability together.

## Document revision record

- **2026-09-21:** Saved the full chat-approved Sydney voice plan. Updated status to approved/saved with implementation unstarted, expanded abbreviated source paths, and initialized execution records. Added supporting references and clarified that final review includes uncommitted/untracked work. No product scope expansion or implementation change.
