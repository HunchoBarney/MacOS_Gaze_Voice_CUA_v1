# Direct Apple Transcript to CUA/Jev Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task by task.

**Goal:** Send Apple SpeechAnalyzer transcripts directly to the existing CUA/Jev task-execution workflow and remove the separate Jev speech-meaning pass.

**Architecture:** SpeechAnalyzer remains the speech-to-text source. The Swift voice path transports transcript revisions, capture identity, ranges, finality, and cancellation state to the CUA task executor; Jev makes the first meaning/action decision there and may make further calls as CUA observations arrive. CUA grounds targets and effects, while Swift performs capture, transport, and explicit task-control mechanics without interpreting speech or independently validating actions.

**Tech Stack:** Existing SwiftPM macOS app, Apple SpeechAnalyzer/SpeechTranscriber, existing Jev client, CUA Driver MCP transport, XCTest.

**Spec:** [docs/voice-ui/SPEC.md](../../voice-ui/SPEC.md), especially S1–S5 and S8.

## Global Constraints

- “The migration targets macOS 26+.”
- “complete actionable requests start while Fn remains held” and support “multiple completed requests within one Fn hold.”
- “Apple remains the STT source; importing another complete voice stack is not a requirement.”
- “Use Cua's existing execution/session/observation/visualization capabilities and official Jev integration wherever applicable.”
- “The configurable provider supplies generated text and optional advisory reasoning; Jev retains grounded action selection and Cua executes it.”
- Preserve capture/revision/finality, provenance, cancellation, no-replay behavior, task identity, task-scoped stop, correction safety, manual approval, and exact dictated text.
- Do not add a local model, a second voice framework, a separate semantic interpreter, or a model/framework comparison phase.
- Preserve credentials, Keychain identifiers, app identity, preferences, dependency pins, and all unrelated work. Do not upgrade the pinned runtime or treat `development/` as disposable.
- Do not run opt-in desktop or physical microphone checks without the documented desktop lock and appropriate live-test authorization. Never claim physical Fn/microphone acceptance from simulated tests.

## Review Focus

- **Raw transcript changes while Jev is deciding:** newer revisions invalidate stale decisions and cannot cause duplicate effects. Pin in `ContinuousIntentTests` and the production-path cases in `CuaVoiceControllerTests`.
- **Several completed requests in one Fn hold:** completed spans reach execution before release; later speech does not replay prior spans. Pin in `ContinuousIntentTests` and `CuaVoiceControllerTests`.
- **Incomplete, negated, or conditional speech:** no action starts until the executor has enough evidence. Pin using injected Jev decisions in `CuaVoiceControllerTests` and action-count assertions.
- **Literal dictation containing control-like words:** inserted content comes exactly from the original transcript and does not become a stop/command. Pin in `CuaTaskAgentTests`, preserving any existing meaningful exact-payload coverage.
- **Stop, stop-all, and correction with prior tasks:** Jev selects the task/control outcome in the executor flow; cancellation and any eligible launch reversal remain bound to task ownership. Pin in `CuaVoiceControllerTests` and existing launch-receipt tests.

## Current Source Map

- `Sources/JevVoice/Voice/ContinuousIntentCoordinator.swift` currently calls an interpretation closure, consumes semantic `SpeechIntent` spans, and protects revision/capture generations. Retain lifecycle safety; remove speech-meaning decisions from this layer.
- `Sources/JevVoice/ComputerControl/CuaVoiceRuntime.swift` currently calls `JevSpeechIntent.understand`, then may make separate Jev calls for task routing and text extraction before creating `CuaTaskAgent`. It also owns task records, queueing, cancellation, and launch receipts.
- `Sources/JevVoice/ComputerControl/CuaTaskAgent.swift` already receives a goal string, selects an app using Jev and CUA app inventory, observes the target, and asks Jev for grounded actions in a bounded loop.
- `Sources/JevVoiceCore/Models/JevSpeechIntent.swift` defines the interpreter, `SpeechIntent`, and text extraction. Remove production dependencies first; retain only shared span/provenance utilities that still have real callers.
- `Tests/JevVoiceAppTests/Voice/ContinuousIntentTests.swift`, `Tests/JevVoiceAppTests/ComputerControl/CuaVoiceControllerTests.swift`, and `Tests/JevVoiceAppTests/ComputerControl/CuaTaskAgentTests.swift` are the main automated behavior suites. `VoiceUnderstandingEvaluationTests.swift`, `BaselineSpeechIntent.swift`, and `JevSpeechIntentTests.swift` contain interpreter-specific or comparison coverage; inspect every caller and replace/remove only the tests made obsolete by the approved architecture.

## Interface Contract

- Keep transcript text verbatim. Carry the existing ranged transcript, capture ID, revision/finality, received time, and task context into the execution workflow. Do not reconstruct an altered request from semantic labels.
- The first Jev decision for an execution request receives the transcript and relevant active-task context alongside the existing CUA app/action context. It decides whether to wait/clarify, start or continue work, select a task-control operation, or provide a literal source span for CUA text entry.
- Jev calls made after CUA observations are part of that same executor workflow. There must not be a Jev call that classifies voice followed by another call that starts a separately constructed executor request.
- Swift may carry task IDs and mechanically invoke an explicitly selected cancellation or eligible correction operation. It must not infer commands from keywords, decide transcript completeness, extract dictation semantically, choose a target independently, or duplicate CUA action validation.
- CUA action selection remains grounded in its current observations and supported tools. Keep existing action approvals, destructive-operation confirmation, safe launch-reversal rules, uncertain-outcome handling, and no-automatic-replay behavior.
- A Jev-selected literal span must copy its text from the original transcript. Do not ask a second model call to paraphrase or reconstruct text that was spoken.
- Preserve before-release execution and multiple requests per hold. If the current executor API cannot accept a newer stable span while earlier work is running, adapt the existing work/task flow so each Jev-selected span enters the same executor workflow with capture and span identity; do not fall back to a Swift phrase splitter or release-only whole-transcript submission.

## Files to Change

| File | Responsibility in this change |
| --- | --- |
| `Sources/JevVoice/Voice/ContinuousIntentCoordinator.swift` | Retain event/revision/capture cancellation and consumed-span bookkeeping; emit transcript handoff data without calling a speech interpreter. |
| `Sources/JevVoice/ComputerControl/CuaVoiceRuntime.swift` | Feed transcript data to the execution workflow; remove pre-execution semantic routing and text-extraction calls; keep task lifecycle mechanics. |
| `Sources/JevVoice/ComputerControl/CuaTaskAgent.swift` | Fold speech completeness/task relationship/control/literal-span decisions into the executor's first Jev decision and continue using CUA observations for actions. |
| `Sources/JevVoiceCore/Models/JevSpeechIntent.swift` | Remove the interpreter after production/test references are intentionally migrated; retain a utility only if independent production call sites still need it. |
| `Tests/JevVoiceAppTests/Voice/ContinuousIntentTests.swift` | Test transport lifecycle, revision invalidation, consumed spans, and no replay without semantic classification expectations. |
| `Tests/JevVoiceAppTests/ComputerControl/CuaVoiceControllerTests.swift` | Test the full injected voice-to-executor path and task controls. |
| `Tests/JevVoiceAppTests/ComputerControl/CuaTaskAgentTests.swift` | Test executor decisions using transcript/task context and CUA observations, including literal spans. |
| `Tests/JevVoiceAppTests/Voice/VoiceUnderstandingEvaluationTests.swift`, `Tests/JevVoiceAppTests/Voice/BaselineSpeechIntent.swift`, `Tests/JevVoiceTests/SettingsAndModels/JevSpeechIntentTests.swift` | Retire or reshape interpreter-only tests after checking all references; do not add a classifier/executor comparison harness. |
| `docs/voice-ui/SPEC.md`, `docs/voice-ui/PLAN.md`, `docs/ARCHITECTURE.md`, `docs/voice-ui/EVIDENCE.md` | Keep active requirements, source flow, gates, and build-specific evidence accurate after implementation. |

Do not change `ThirdParty/Cua`, dependency pins, provider configuration, app identity, or unrelated subsystems for this voice handoff.

## Implementation Tasks

### Task 1: Pin the direct transcript execution contract

**Files:**
- Modify: `Tests/JevVoiceAppTests/Voice/ContinuousIntentTests.swift`
- Modify: `Tests/JevVoiceAppTests/ComputerControl/CuaVoiceControllerTests.swift`

- [ ] Add an injected-judge production-path test that records Jev inputs and asserts the first executor decision receives the original transcript exactly, with relevant task context. Assert there is no preceding interpreter request using `pending_speech`/`boundary` classification inputs.
- [ ] Add a revision test where a newer transcript supersedes an in-flight decision. Assert the old result creates no task/effect and the latest accepted stable span is submitted once.
- [ ] Add a finalization test showing an already handed-off span is not submitted again when the same transcript becomes final.
- [ ] Run `swift test --filter ContinuousIntentTests` and `swift test --filter CuaVoiceControllerTests`; confirm the new contract tests fail against the current interpreter path for the intended reason.

### Task 2: Make the voice coordinator a transcript/lifecycle transport

**Files:**
- Modify: `Sources/JevVoice/Voice/ContinuousIntentCoordinator.swift`
- Modify: `Tests/JevVoiceAppTests/Voice/ContinuousIntentTests.swift`

- [ ] Replace the `Interpret`/`Decide` semantic callback and `SpeechIntent` submission boundary with a transcript handoff that retains text, capture identity, revision/audio ranges, finality, and received time.
- [ ] Preserve generation cancellation, stale callback rejection, capture reset, finalization, consumed-span/no-replay ownership, and `waitForPending()` behavior. The coordinator may schedule/coalesce transcript updates but must not decide command/content, completeness, stop/correction, or literal mode.
- [ ] Keep the existing ranged-finality rule and early handoff behavior where supported. Let Jev choose semantic span boundaries; copy any selected literal words from source transcript ranges.
- [ ] Replace classification-oriented coordinator tests with lifecycle and handoff tests. Run `swift test --filter ContinuousIntentTests` and confirm they pass.

### Task 3: Put the first voice decision inside the CUA task executor

**Files:**
- Modify: `Sources/JevVoice/ComputerControl/CuaTaskAgent.swift`
- Modify: `Tests/JevVoiceAppTests/ComputerControl/CuaTaskAgentTests.swift`

- [ ] Extend the executor's existing initial Jev decision input to include the verbatim transcript, current task identities/status/context, and the existing installed-app/action candidates. That decision owns completeness, task relationship, command/content and selected executor operation; subsequent Jev calls remain in the same bounded observe/choose/act loop.
- [ ] Represent wait/clarification, new or continuing work, task-scoped stop/stop-all/correction, and literal-span outcomes through the executor's structured decision contract. Do not classify those cases in `ContinuousIntentCoordinator` or `CuaVoiceRuntime`.
- [ ] Keep action targets grounded in the actual CUA inventory and fresh observations. Preserve existing risk approval and action-outcome rules; do not introduce a Swift-side target selector or parallel validator.
- [ ] For text entry, use the Jev-selected source span copied exactly from the original transcript; remove the need for `JevSpeechIntent.extractText`/`textPayload` in this execution path.
- [ ] Add injected-judge CUA-agent tests for incomplete/clarification, context-dependent follow-up, exact literal text including “stop” or app names, and action choice after fresh CUA observation. Run `swift test --filter CuaTaskAgentTests`.

### Task 4: Route task lifecycle mechanically and remove the prepass

**Files:**
- Modify: `Sources/JevVoice/ComputerControl/CuaVoiceRuntime.swift`
- Modify: `Tests/JevVoiceAppTests/ComputerControl/CuaVoiceControllerTests.swift`
- Modify: relevant existing launch-receipt/control tests only if behavior needs new coverage

- [ ] Replace `enqueue(_ intent: SpeechIntent)` with the transcript/executor outcome boundary. The runtime creates task records from executor-selected operations and remains responsible only for queueing, task IDs, cancellation mechanics, approval continuations, and eligible launch-receipt reversal.
- [ ] Remove the runtime call to `JevSpeechIntent.understand`, standalone Jev routing call, and separate Jev literal extraction/text-payload calls. No model request may interpret speech before the executor's first decision.
- [ ] Preserve stop-all, selected-task stop, corrections, independent new tasks, capture provenance, task selection, and late-result cancellation. Apply only the task/control outcome chosen by the executor; do not add keyword rules in Swift.
- [ ] Update end-to-end fixture tests so a raw transcript reaches the executor, CUA actions are then selected from observations, task cancellation applies to the Jev-selected task, and a late/final callback cannot replay an effect. Run `swift test --filter CuaVoiceControllerTests` and `swift test --filter CuaLaunchReceiptTests`.

### Task 5: Retire the speech interpreter and synchronize migration docs

**Files:**
- Modify/remove only after reference audit: `Sources/JevVoiceCore/Models/JevSpeechIntent.swift`
- Modify/remove only after reference audit: `Tests/JevVoiceAppTests/Voice/VoiceUnderstandingEvaluationTests.swift`
- Modify/remove only after reference audit: `Tests/JevVoiceAppTests/Voice/BaselineSpeechIntent.swift`
- Modify/remove only after reference audit: `Tests/JevVoiceTests/SettingsAndModels/JevSpeechIntentTests.swift`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/voice-ui/PLAN.md`
- Modify: `docs/voice-ui/EVIDENCE.md`

- [ ] Use `rg` across `Sources` and `Tests` to enumerate every `JevSpeechIntent`, `SpeechIntent`, baseline parser, extraction, and payload-helper call site. Remove the interpreter from production; retain or relocate only a utility with a proven independent caller.
- [ ] Replace or remove tests that only assert old classifier categories. Keep meaningful tests for exact source spans, capture/provenance, cancellation, and CUA executor outcomes. Do not create a model-versus-model or interpreter-versus-executor comparison.
- [ ] Update the architecture source flow to show SpeechAnalyzer transcript → capture/revision transport → CUA task executor/one Jev decision workflow → CUA tools/observations. State clearly that multiple Jev calls after observations are part of that same workflow.
- [ ] Update PLAN checkboxes only for evidence actually produced. Append EVIDENCE entries with exact commit/build context, tests, outcomes, limitations, and whether they were simulated, live automated, observed app behavior, or user-reported physical checks.

### Task 6: Verify the completed change without claiming unrun live acceptance

**Files:** affected voice and executor source/tests/docs only.

- [ ] Run focused suites from Tasks 1–4, then run `make test` from the checkout root.
- [ ] Run `make app` and verify the workspace-built bundle with the repository's documented signing check if the build/signing path completes safely. Do not install, replace the installed app, or launch it as part of automated verification.
- [ ] Review the full diff, run `git diff --check`, search for production references to `JevSpeechIntent`, inspect the final worktree, and confirm no credentials, user preferences, app identities, pinned runtimes, or unrelated files changed.
- [ ] Run an opt-in desktop test only if the test is fully automated, uses a disposable fixture, its source confirms its effects, and it can be run under `scripts/with-desktop-lock.py` with one desktop owner. Do not perform physical Fn/microphone testing or assert user-facing app acceptance when the user is absent.
- [ ] Report completed code paths, exact automated checks, any existing failures, and remaining live/physical acceptance gates. Do not mark P2 or the full migration complete unless its existing SPEC/PLAN gates have evidence.

## Copy/Paste Execution Prompt

Use the prompt below to implement this plan in a later session without relying on this chat:

```text
Implement the user-approved direct Apple transcript-to-CUA/Jev voice architecture in this repository. The user has authorized implementation of the plan in docs/superpowers/plans/2026-09-22-direct-transcript-to-cua.md; do not stop for further clarification. Read README.md, docs/ARCHITECTURE.md, docs/DEVELOPMENT.md, docs/voice-ui/SPEC.md, docs/voice-ui/PLAN.md, and docs/voice-ui/EXECUTION.md before changing source. Follow EXECUTION.md for this authorized migration task, keeping implementation scope to the approved voice architecture. Use the superpowers:executing-plans skill and execute every task in the linked plan to completion.

The required design is fixed: Apple SpeechAnalyzer remains the STT source. Send its original transcript, capture/revision/range/finality identity, and relevant task context into the existing CUA task-execution workflow. Jev makes the first semantic and action decision there; additional Jev calls after CUA observations remain in that same execution workflow. Remove the separate Jev speech-interpreter pass and its pre-execution routing/text-extraction calls. Swift handles capture lifecycle, provenance, transport, task IDs, and mechanical execution of the executor-selected operation; it must not infer speech meaning or independently validate CUA targets/actions. CUA observations and supported tools ground the effects. Multiple Jev calls inside the executor are allowed.

Preserve the active SPEC behavior: complete commands can start while Fn is still held; multiple completed requests can occur in one hold; revisions cancel stale work without replay; incomplete, negated, or conditional speech does not dispatch; dictation inserts the exact original transcript span even when it contains command-like words; stop, stop-all, follow-up, correction, task ownership, launch-reversal safeguards, manual approval, and uncertain-outcome handling remain correct. Do not silently reduce this to one whole transcript on release.

Do not add a local model, alternate voice framework, model/framework comparison study, hidden fallback executor, or Swift phrase/intent parser. Do not update dependencies or runtime pins. Preserve credentials, preferences, Keychain identifiers, app identity, ignored development assets, and unrelated user changes. Inspect the worktree first and preserve any existing dirty changes; do not reset, clean, or overwrite them. Do not commit unless separately asked.

Use focused tests first, then `make test`, and `make app` plus the documented signature verification where safe. Use meaningful behavior tests, not tests that merely mirror code. Do not launch/install/replace the user's app or run physical Fn/microphone checks. Any opt-in live desktop test must be inspected first, use a disposable fixture, use the documented shared desktop lock, and avoid real messages, purchases, or personal-content deletion. Record actual tests and failures separately from live/physical acceptance; update SPEC/PLAN/ARCHITECTURE/EVIDENCE only to describe behavior and evidence actually implemented. Continue through implementation and verification without asking for more input unless a real external blocker prevents progress; then complete independent work and report that blocker precisely.

At completion, report the modified files, the new transcript-to-executor flow, how dictation/task controls/revision safety are handled, commands run and their results, existing failures separately from regressions, and any physical/live acceptance still outstanding. Never claim full migration acceptance unless all existing SPEC/PLAN gates have evidence.
```
