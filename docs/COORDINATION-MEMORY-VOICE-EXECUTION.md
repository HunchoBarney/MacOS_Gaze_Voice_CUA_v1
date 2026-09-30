# Coordination repair — Devin execution driver

Companion to `COORDINATION-MEMORY-VOICE-PLAN.md` (authoritative requirements and the
2026-09-29 amendment). This file is the execution recipe: which agent owns which step,
what each subagent prompt contains, and the gates between steps. The orchestrator session
drives the plan end-to-end without user prompts; if the session is interrupted, a fresh
Devin session resumes from the State log below plus `git status`/`git diff`.

## Roles

- **Orchestrator** (the main Devin session): owns all `swift build`/`swift test`/`make`
  invocations (the single verification lane), reads every diff, launches subagents,
  collects judge verdicts, applies repair rounds, advances steps, updates the State log.
  Never delegates verification and never asks the user for step-by-step approval.
- **`jarvis-implementer`** (`.devin/agents/jarvis-implementer.md`): write-capable SWE-2
  worker. Edits only assigned files.
- **`jarvis-judge`** (`.devin/agents/jarvis-judge.md`): read-only SWE-2 reviewer. One
  consolidated finding list plus a terminal PASS/FAIL.

If a custom profile is unavailable, fall back to `subagent_general` (inherits the
orchestrator's model) for implementers and `subagent_explore` for judges, with the
profile's rules pasted into the task prompt.

## Permissions

Background subagents inherit permissions already granted this session and cannot prompt.
Run the **first** implementer in the foreground (or approve edit/exec once) so later
background workers inherit write+exec access. `read`/`grep`/`glob` are auto-approved.

## Loop per phase

1. Spawn the phase's implementer(s) with a prompt per the template below. Parallel only
   when file ownership is disjoint.
2. Wait for all writers in the phase to finish (writes-frozen barrier).
3. Orchestrator runs `swift build`, then the step's focused `swift test --filter`, then
   full `swift test` whenever production files changed. Record counts in the State log.
4. Spawn the step's judge(s) — read-only, against the frozen tree.
5. Judge FAIL → resume the same implementer agent ID with the finding list (it keeps
   its context). Max **two** repair rounds per step; exhaustion is terminal FAIL — stop,
   report findings, do not restart the step through a new agent.
6. Judge PASS → update State log, proceed to the next phase.

User interruption mid-phase redirects but does not kill running subagents; resume the
loop after folding in the correction.

## Implementer prompt template

Every implementer prompt must contain (subagents see none of this session's context):

```
Task: <step ID and title, verbatim requirement text from COORDINATION-MEMORY-VOICE-PLAN.md,
including the 2026-09-29 amendment bullets that apply>.

Repo: /Users/karanvirkang/Documents/code/JarvisMacOSv1-empryo-staging-20260928 (SwiftPM,
macOS 26). Read AGENTS.md and the amendment section of the plan doc first.

You own these files (read/write): <list>
Do not modify any other file.

Context: <what already exists — partial edits, accepted contracts, current state of the
files, relevant report findings>.

<Build/test permission: "Do not run swift build/test — the orchestrator verifies after
you finish." for parallel phases | "You may run swift test --filter '<suite>' once at the
end" for serial phases.>

Return: files changed, design decisions, requirements not satisfied, unproven areas.
```

## Phase map

| Phase | Plan step | Agent(s) | Mode | Gate to advance |
| --- | --- | --- | --- | --- |
| 0 | baseline | orchestrator | — | tree compiles; focused-suite status recorded |
| A | step-1 contract revision + step-2 + step-3 | 3 implementers, disjoint files | parallel background | build clean + `CuaDialogueStateTests` + `CuaTaskAgentTests` + `ContinuousIntentTests`/`SpeechConsumptionTests` + judges PASS |
| B | step-4 | 1 implementer | foreground/serial | `CuaVoiceControllerTests`+`ContinuousIntentTests`+`CuaTaskAgentTests` + live-test compile with flags off + judge PASS |
| C | step-5 | 1 implementer | serial | focused agent/controller suites + judge PASS |
| D | step-6 | 1 implementer | serial | `VoiceSessionTests`+`CuaVoiceControllerTests` + judge PASS |
| E | step-7 | 1 implementer (tests only) | serial | full `swift test` + `python3 -B -m unittest discover -s Tests/Tooling -v` + judge PASS |
| F | step-8 | 2 judges (safety/identity, dialogue/voice) | parallel read-only | both PASS; ≤2 repair rounds via a fix implementer |
| G | step-9 | orchestrator | — | `make app`; `codesign --verify --deep --strict` on a copy **outside** the synced Documents dir; docs updated; final whole-plan judge PASS |

No commits, pushes, installed-app changes, Driver changes, or live-test flags at any
phase. `JARVIS_*` live tests stay off everywhere.

## Judge prompt template

```
Review the implementation of plan step <ID> in this repo against the step's acceptance
requirements (quote them) and the 2026-09-29 amendment. The diff under review is the
uncommitted working tree (git diff / git status). Judge only this step's scope. Verify
production callers actually exercise the new code — tests alone are not integration.
Return VERDICT: PASS|FAIL plus one consolidated finding list with file:line citations
and a requirement checklist.
```

## State log

| Date | Phase | Agent(s) | Result | Evidence |
| --- | --- | --- | --- | --- |
| 2026-09-29 | plan amendment | orchestrator | 4 contract corrections + 3 step-4 obligations landed; `.empryo/plans/plan.md` synced | `docs/COORDINATION-MEMORY-VOICE-PLAN.md` |
| 2026-09-29 | phase 0 | orchestrator | baseline does NOT compile: `ContinuousIntentCoordinator.swift:401` references undefined `SemanticContext.tracksFreshness` (only error); repair lands in phase A step-3 | `swift build` |
| 2026-09-29 | phase A implement | bcf910bd (step-1), 2863337e (step-2), 1dd04710 (step-3) | all three writers done; jarvis-implementer profile didn't register mid-session so subagent_general used (inherits SWE-2 High) | agent reports |
| 2026-09-29 | phase A verify | orchestrator | build green; focused suites 100/100 PASS; full `swift test` 303/0 failures, 37 opt-in skipped. Orchestrator fix: CuaDialogueStateTests `resolvedHistoryLimit: 0` trimmed cancelled entries — test needed default limit | `swift build`, `swift test` |
| 2026-09-29 | phase A repair-1 | 2863337e (resumed) | new `relationship`/`pendingQuestion` decide questions broke strict `default: throw` mocks — fixed CuaVoiceControllerTests ×2 + VoiceSessionTests; unguarded `cuaTasks[1]` predicate crash guarded; strictness preserved | `swift test --filter CuaVoiceControllerTests` 31/0 |
| 2026-09-29 | phase A judge | 37361708 (steps 1-2), 97a6714b (step 3) | PASS both. Step-4 obligations carried forward: (a) `validateSource` calls `refreshRelevantContextIfNeeded` — not a pure preview, step-4 must not call it as one; (b) `refreshOrClarifyActiveHandoff` mutates before stale-ticket check (unreachable today) — reorder during boundary rewiring; (c) `CuaTaskExecutionOutcome` has no VerifiedFact channel — step-4 owns fact construction from Driver evidence; (d) `revise` can resurrect `.cancelled` intents — step-4/5 routing must not retry cancelled work; (e) context must publish pending questions with IDs | agent reports |
| 2026-09-29 | phase B implement | dc392688 | step-4 done: dialogue authoritative in CuaVoiceRuntime, Work=attempt, derived status strings, atomic acceptIntent boundary, no window inheritance, postcondition-bound verified facts, +7 controller tests; focused 118/0, full 310/0 | `swift test` |
| 2026-09-29 | phase B judge | 025ff90b | FAIL → repair-1: drain covered `.blocked` only, now `.uncertain`/`.partial` too; `applyRouting` catch no longer cancels resume referents; +2 capacity tests. Re-judge PASS | agent reports |
| 2026-09-29 | phase C implement | step-5 implementer (cancelled mid-repair) | +11 tests incl. question→answer, stale answer, destination change, uncertain retry, literal stop words, approval binding, Stop All; reported focused 128/0, full 323/0. Judge FAIL: (1) resume narrowed scope → fabricated verifiedFact; (2) decide-time clarify dropped literal payload | agent reports |
| 2026-09-29 | phase C repair-1 | orchestrator (repair applied directly after interrupt) | `intentPayloads` records scope/visibility/literal/contentMode per intent; clarify carries parsed contract; resumed attempt re-executes stored contract; release gate reverted to `decision.contentMode` (resumed payloads are already-final text); testFailedIntentRetries asserts honest re-failure not fabricated success; +1 clarified-literal regression test. Focused 149/0, full 325/0 | `swift test` |
| 2026-09-29 | phase C re-judge | ec668880 | FAIL round-2: `applyCorrection` only cancelled active targets — an inactive awaiting-answer target kept its pending question live and the correction falsely claimed cancellation → `.verified`. Repair: unconditional `cancel` + withdraw any unresolved inactive intent; +1 regression test (`testCorrectionWithdrawsPendingQuestionSoAnswerCannotResumeIt`). Re-judge PASS | focused 150/0, full 326/0 |
| 2026-09-29 | phase D implement | step-6 implementer (session interrupted mid-review) | IN FLIGHT — substantial edits already landed: `VoiceController.Status.awaitingAnswer`, `pendingQuestions` projection, `.awaitingAnswer` presentation mapping, ContentView/VoiceStyle/VoiceSessionTests/CuaVoiceControllerTests updated; new tests incl. `testAmbiguousStopKeepsSpecificClarificationVisible`, `testRetryOfWithdrawnQuestionIntentIsRejected`, `testAnswerBindsNamedQuestionWhileOtherPendingQuestionSurvives`. Build green; step-6 gate `swift test --filter 'VoiceSessionTests|CuaVoiceControllerTests'` = 67/0. Judge NOT yet run; step-6 not declared PASS | `swift build --build-tests`, focused 67/0 |
| 2026-09-29 | phase D judge + repair | 9028fb03, orchestrator repair | Judge FAIL on coverage only (implementation satisfied all 8 requirements): no tests for stale-failure non-contamination, Escape-vs-unrelated-task, controller `stopAll` composition, selection≠authority, retryTask/taskDiagnostics. Orchestrator added 4 fixture-driven tests; app-lease serialization diagnosed (approval-pending work holds lease for whole run). Re-judge PASS | focused 71/0, full 330/0, 37 skipped |
| 2026-09-30 | phase E implement + judge + repair | c5b50c36, 5f137574, orchestrator F1 repair | Implementer mapped all 18 required sequences, added 7 tests (+1 gated live). Judge FAIL: coverage complete BUT surfaced routed production defect F1 — answer text prepended to context never reached re-asked execution questions (window judge + action observation excluded context → unbounded clarify loop); Question.options/target never populated; F2 live test too weak. Orchestrator repair: `previous_context` added to window judge (:883) + action observation (:1009); `agent.pendingQuestionOptions` side-channel (mirrors observedPostconditions) feeds Question.options; Question.target bound at both ask sites; new discriminating test proves answer reaches re-asked state + candidates retained; live test tightened. Re-judge PASS | focused 60+117/0, full 338/0, 38 skipped; tooling 12/12 |
| 2026-09-30 | phase F dual review + repair | 921370a1 (safety), ff9028f4 (dialogue) | Safety/identity reviewer: PASS, all 6 items hold, 5 non-blocking hardening observations (notably: settle's try? finish could wedge .executing if it ever threw — currently unreachable). Dialogue/voice: one minor defect — `cancel(_:)` re-cancelled resolved intents in the post-settle/finishSession teardown window (rewrite to .cancelled + revision bump invalidating bound facts + "Cancelled" mislabel). Orchestrator repair: `dialogue.cancel` now refuses isResolved (terminal outcomes immutable); runtime `cancel` early-returns on resolved intents; regression test uses sessionEndDelayMs window. Re-review PASS — fix also closes latent bug where cancelling finishSession's detached await could skip queue.release + work.active=false (app-lease leak) | full 339/0, 38 skipped |
| 2026-09-30 | phase G package + docs + final review | orchestrator, e22aae8b (final judge) | `make app` → `build/Jev Voice.app` v0.1.5 arm64 ad-hoc `com.chriswozniczek.jevvoice`, exe SHA-256 80b1ecc…526d0a; codesign --verify --deep --strict PASS on /tmp copy (synced-checkout FinderInfo caveat per CLEANUP.md); ARCHITECTURE.md updated to dialogue-authority description. Final judge FAIL on step-9 doc deliverables only (A–H code verified closed, scope/immutability confirmed): EVIDENCE.md entry missing, PLAN.md:138 stale status, SPEC.md missing S5 semantics paragraph, missing phase-G row — all four repaired by orchestrator. Git checks confirmed: report file untouched, ThirdParty/ clean, no commits. Re-judge: **PASS — plan complete** | `make app`, codesign, EVIDENCE.md entry |
