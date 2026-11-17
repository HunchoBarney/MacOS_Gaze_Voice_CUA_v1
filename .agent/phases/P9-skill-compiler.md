# P9 — skill-compiler ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: agent+voice · Depends on: P5, P7 · Branch: `ship/v1-p9`
> Acceptance: `.agent/acceptance/P9.json` · Contracts: §1, §3, §6, §7, §8

## Purpose

Make repeated work execute through validated reusable operations with
fresh targets and independent completion, rather than reasoning from
scratch on every request.

## Context

Read CONTRACTS §6 SkillProgram, SHIP-PLAN C2 and P5/P7 handoffs.
`Agents/RoutineScheduler.swift` repeats agent requests; it is not a
validated replay compiler. Reuse existing Cua recordings, typed operations,
TaskLoop verification and consent. Do not treat a previously successful
trace as permanent authority over a changed account, page or document.

## Reuse decision

Use Cua recording/replay primitives and existing AX/DOM locators; inspect
licensed Browser Use/reference recording techniques listed in REUSE.
Use Foundation Codable, atomic file operations and existing task types.
The product-specific compiler, validation policy and retirement are the
minimal gap; no new scripting language, general workflow engine or database
is justified without a demonstrated need and G2 decision.

## Owned paths

```text
Sources/JevVoice/Skills/**
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/Drive/TaskLoop.swift
Sources/JevVoice/Contracts/JevContracts.swift
Tests/JevVoiceAppTests/SkillProgramTests.swift
Tests/JevVoiceAppTests/SkillReplayTests.swift
Tests/JevVoiceAppTests/VoiceTaskCoordinatorLaneTests.swift
Tests/JevVoiceAppTests/PolicyTypedPayloadTests.swift
scripts/verification-lane.sh
bench/run.py
bench/lib/mcp_stdio.py
bench/lib/results.py
bench/lib/verifiers.py
bench/selftest.py
bench/tasks/p9-*.json
bench/reset/p9-*
.agent/phases/P9-skill-compiler.md
.agent/acceptance/P9.json
.agent/results/P9/**
.agent/CONTRACTS.md
.agent/PROGRESS.md
```

## Non-goals

No arbitrary code generation, extra background scheduling, replayed
consent, cached-coordinate actuation, secret capture or general control
dependent on a preinstalled skill.

## Milestones

### M1 — versioned program/store and admission

**Change:** validate the §6 schema and code-owned actions, parameters,
target/account context, preconditions, result predicate and provenance.
Compile only independently verified traces. Version programs and use
atomic private storage; exclude credentials and unnecessary private data.
Add a `p9` lane mode for named program/replay/policy tests.

**Check:** `scripts/verification-lane.sh p9` → nonempty suites reject
unknown actions/version, malformed parameters, injected script, wrong
account, unverified source trace and an unsupported postcondition.

**Evidence:** `.agent/results/P9/contract-review.md`, `source-review.md`,
valid/invalid fixture programs and storage/recovery behavior.

### M2 — current-state replay and retirement

**Change:** match intent/context, bind fresh semantic locators, execute
through TaskLoop and verify each transition/final effect. Preserve
read-back and cancel. A historical point is only a hint for current
validated grounding. On an invalid precondition, fall back before input.
On an uncertain mutation, verify/hand back without replaying it.
Initial retirement policy: two consecutive verified replay failures
disable automatic selection until fresh validation; persist the reason.

**Check:** `scripts/verification-lane.sh p9` → changed layout/page/account,
ambiguous locator, canceled approval, interrupted write/replay and
uncertain partial completion cannot cause wrong/duplicate action or Done.
Retired skills are not selected, and safe general fallback still works.

**Evidence:** `.agent/results/P9/integration.json` with trace provenance,
rebindings, execution receipts, failure counts and retirement.

### M3 — repeat-work qualification

**Change:** add frozen paired first-run/repeat tasks to the existing
normal-product benchmark. Review a §7 injector extension if required;
never use a private replay call as evidence for the user route.

**Check:** SHIP-PLAN desktop-lock command with tag `p9` → repeat slice
>=95% strict success, p50 <=3s with PROGRAM Wilson bar; report internal
<=2s replay budget and S-WORKFLOW separately. Preserve all failures;
zero false Done, duplicate mutation and consent bypass.

**Evidence:** `.agent/results/P9/qualification.json`, raw paired timings,
task/model/skill/source identities, invalidation cases and candidate
manifest. Required integrated lane and independent review pass.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P9-1 | M1 | schema/store/provenance and reuse |
| P9-2 | M1/M2 | parameters/locator/current-scope validation |
| P9-3 | M2 | consent, cancel and independent result |
| P9-4 | M2 | retirement and safe fallback |
| P9-5 | M3 | repeat success/latency and resource/spend rows |
| P9-6 | M3 | independent review/handoff |

## Gates

G1/G2 pending. Existing schemas are not silently amended. G3 is serialized;
G5 uses only approved controlled tasks. G6 demonstrates a repeat through
normal voice in the final session. User permissions remain live decisions,
never part of a compiled skill.

## Progress

- [x] Draft/default-fail criteria prepared.
- [ ] M1 schema/store.
- [ ] M2 replay/retirement.
- [ ] M3 qualification.

## Surprises & Discoveries

The current contract includes a point fallback; it cannot mean permission
to reuse stale coordinates. Review the distinction before implementation.
Scheduling an agent repeatedly is not evidence of fast validated replay.

## Decision Log

| Date | Decision | Reason |
|---|---|---|
| 2026-11-15 | Reuse recordings/executors; retire after two consecutive failures | Reduce repeated reasoning without persisting stale authority |

## Outcomes & Retrospective

No skill store/compiler shipped; all six criteria remain false.

## Handoff

Next: freeze P5/P7 action/ref/result contracts and the replay failure cases.
Keep invalid/retired records for diagnosis and disable their selection;
retain safe general execution. Do not mutate user data to manufacture a
successful training trace.
