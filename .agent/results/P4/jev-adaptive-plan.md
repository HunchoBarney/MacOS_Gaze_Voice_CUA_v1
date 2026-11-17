# Jev adaptive follow-up, 2026-11-08

## Purpose

Give Jev a fair test as a contextual next-action model, not just a literal
button matcher. Improve useful verified progress with focused follow-up
judgments when necessary. Do not manufacture 10/10 by rejecting every
multi-step request or guessing on negatives.

User approved unlimited additional Jev calls, then explicitly corrected
the earlier overly narrow model role: the harness should let Jev handle
many tasks, including familiar short action sequences. Preserve the
existing exhausted 30-request grant and all its evidence.

## Context

Current installed release was verified in jev-integration-report.md.
Production sources have NOT changed for this follow-up yet.
Current JevChooser applicability explicitly rejects requests needing a
sequence and Choice asks for a direct whole-instruction match. This is a
harness restriction, not evidence of model incapacity.
JevDecider sets current_instruction = task.goal and supplies recent_steps.
DriveLoop/TaskLoop default to four rounds; do not silently lift that lock.

Live TypeSafe docs were refreshed: llms index, fan-out, skill suggestion,
SDE cascade, confidence. Skill suggestion uses a second request to read
top candidates in more detail and can reject them all. Atomic judgments
may be contextual bounded action selections, not only literal matches.
Questions within one request cannot consume each other's answers.

Typesafe-ai skill loaded. Enliven loaded/read in full; its Chromium/CDP
instrumentation does not apply to the native Swift loop, but same-harness
before/after, latency/request counts, and a generated honest HTML report
do apply. No helper agents dispatched.

## Owned Paths

Existing P4 owned paths plus:
- Tests/JevVoiceAppTests/JevAdaptiveTests.swift
- Tests/JevVoiceAppTests/JevAdaptiveLiveTests.swift
- Tests/JevVoiceAppTests/JevAdaptiveFixtures.swift
- Tests/JevVoiceAppTests/JevAdaptiveWorkflowTests.swift
- .agent/results/P4/jev-adaptive-*

Only one writer in jarvis-v1-agent. Do not touch EyeTracking, P3 voice/ASR,
the driver pin, tools, consent or snapshot authority. No commit/push.

## Non-Goals

No reasoning-provider installation, model-generated text or scripts,
Calculator-only benchmark shortcut, weakened completion proof, or claim
of universal 10/10. Additional approval covers synthetic API experiments,
not private screenshots/app content or irreversible desktop actions.
A further install replaces the installed bundle and requires explicit
approval for that operation; the prior install approval was already used.

## Milestones

1. Freeze broader fixtures and scoring before changing production.
   Include single actions, short sequences with goal/history/values,
   numeric/text controls, large candidate sets, absent/ambiguous controls,
   misleading observed text, and already/done vs incomplete evidence.
   Compare actual decisions and verified outcomes, not model self-score.
2. Run current production chooser/decider as baseline via serialized lane.
   Add regression tests using the existing Infer seam before implementation.
   Preserve raw state/questions/answers/model/latency and source hashes.
3. Remove blanket multi-step veto. Ask for the next supported action
   toward the goal using fresh state/history, not for a full generated plan.
   Add at most one focused second request when ambiguity can be resolved
   by detailed candidate evidence; no blind repeats/votes or confidence
   averaging. Keep first-stage no-match, explicit postcondition bypass,
   and final policy/consent/verification authority in code.
4. Same-harness after and held-out tests, plus real production TaskLoop
   with controlled synthetic observation/actuation and real Jev. Record
   accuracy, false actions/claims, abstentions, requests and p50/p95.
   Report this as model-plus-loop evidence, not physical desktop proof.
5. Run affected regression suite and full serialized lane once frozen.
   Generate JSON-backed HTML report including regressions, limits, and
   cases that still fail. Do not change P4 acceptance flags.

## Acceptance Mapping

P4 safety/contracts remain binding. No false action/completion increase;
known postconditions still verify without a model call. Short multi-step
goals get a fair next-action test. Promote adaptive calls only when paired
accuracy improves without safety regression; otherwise fix named input/
evidence defects or discard the additional calls. Four-round lock remains
unless explicitly revised through the contract process.
Passing a synthetic slice does not close P4-5/P4-6.

## Progress

- Initial audit, test-first regressions, paired real-API measurements,
  production repair, full verification, independent repair review and
  approved installation are complete. See the JSON-backed HTML report.
- Use a NEW auditable synthetic grant journal, initially bound each
  diagnostic batch to 512 requests for accounting. This is a local batch
  limit, not the user's cap; unlimited authorization permits a justified
  subsequent batch without resetting old journals.
- Credentials remain in Keychain and ephemeral child environments only.
  No automatic unbounded retries; preserve service errors as failures.
- All builds/tests through scripts/verification-lane.sh.

## Surprises & Discoveries

We previously encoded "needs a sequence" as automatic non-applicability.
The user correctly challenged that. Do not preserve the old negative
label for a sequence simply to keep tests green.

## Decision Log

Additional calls must change the judgment or evidence. Preserve goal,
state, action identity and history; selected controls are not proof of
workflow completion. Sol/Terra remain for genuinely unfamiliar/long plans,
not automatically every two-click workflow.

## Outcomes & Retrospective

Current frozen repair: 45/48 observation checks versus 30/48 baseline;
four of four synthetic workflows finish through the production loop
versus zero before. No wrong actions or unsupported completion claims
in the final slice. Three safe abstentions remain. This is not 10/10
or proof of general/physical desktop reliability.

Latency regresses: observation p50 80.112 ms versus 75.364 ms and p95
160.755 ms versus 110.544 ms. Both regressions and the first revision's
six wrong focus actions are visible in `jev-adaptive-report.html`.

Full lane: 1,131 Swift tests, 17 skipped, no failures; tracker typecheck
and 234 tests pass. Same explicitly approved read-only reviewer PASS
for source and evidence; not a phase G4 verdict.

New grant spent 243, including 12 boundary/context diagnostic requests.
The probe supports preserving uncertainty rather than lowering 0.9.
Do not tune further on the now-inspected held-out slice or reclassify
its failures as successes.

Approved new app installed and process/strict signature verified.
All 39 file-backed Mach-O sections match the release artifact; measured
source hashes match current source. The installer exits 2 on its existing
90-second tracker wait; tracker subsequently returns HTTP 200. The
independent install proof passes and records BOTH facts without changing
the install log into a green run.

## Handoff

Read this plan plus the latest PROGRESS entry and existing P4 plan.
Existing 30-call experiment/replay is historical and must not be rewritten.
Current installed app is this adaptive repair. Receipt:
`jev-adaptive-install-receipt.json`. Report: `jev-adaptive-report.html`.
P4-5/P4-6 remain false. The four-round lock and pre-existing one-question
per task limit remain. Any future revision needs a fresh fair experiment,
explicit budget decision where required, and consumer review.
