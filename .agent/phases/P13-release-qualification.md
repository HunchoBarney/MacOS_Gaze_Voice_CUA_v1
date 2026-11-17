# P13 — release-qualification ExecPlan

> Status: draft; documentation authorized, source G1/G2 pending
> Track: main · Depends on: P12 and all remaining P3/P4 gates
> Branch: `ship/v1-p13` · Acceptance: `.agent/acceptance/P13.json`
> Contracts: §7 bench, §8 ledger, PROGRAM release/interaction requirements

## Purpose

Prove one complete signed candidate through the actual product front doors,
with honest speed/reliability/resource results and matched competitor
comparisons. Deliver the concrete artifact and evidence for a ship decision.

## Context

Read SHIP-PLAN qualification, PROGRAM release bars/goals, all phase
handoffs and the original report. P3 0/8 and P4 4/6 are still open at
planning time. Historical synthetic Safari success, raw replay and
accepted spikes cannot replace final signed/physical qualification.
Reuse the existing benchmark, retained audio, native witnesses and
resource/first-run evidence when subject and dependency coverage match.
Also read COMPETITIVE and the Jev-first competitive audit. Wispr Flow
quality/insertion comparison and the complete category scorecard are
required evaluation work. Existing minimum bars alone do not prove
leadership. Jev-only and Terra-recovered outcomes must remain distinct.

## Reuse decision

Use P1 bench/Wilson/reporting, P3 normal voice harness, P4 real-app oracles,
P8/P11 tracker smoke, P12 package/install receipts and LatencyLedger.
Use installed licensed Codex CU and Browser Use for declared comparable
tasks. Playwright/CDP is optional for a demonstrated browser/Electron
measurement gap, not a substitute for native Fn/microphone proof.
No new general benchmark or orchestration framework.

## Owned paths

```text
bench/run.py
bench/report.py
bench/selftest.py
bench/lib/results.py
bench/lib/verifiers.py
bench/tasks/p13-*.json
bench/reset/p13-*
scripts/verification-lane.sh
TESTER-GUIDE.md
README.md
.agent/phases/P13-release-qualification.md
.agent/acceptance/P13.json
.agent/results/P13/**
.agent/PROGRAM.md
.agent/COMPETITIVE.md
.agent/PROGRESS.md
```

Production fixes belong to their owning phase and invalidate the affected
evidence. P13 does not silently widen its source ownership to patch the RC.

## Non-goals

No new feature scope, post-hoc task selection, model/driver swap during a
comparison, benchmark timeout relaxation, removed failures, unsigned
substitution, destructive personal-data tests or unsupported fastest claim.

## Milestones

### M1 — freeze subject and coverage

**Change:** freeze signed candidate/source/runtime/model/config/OS/hardware,
task IDs, attempt counts, setup state, input clocks, budgets, competitor
versions and independent result oracles. Revalidate affected dependencies;
reuse demonstrably applicable prior evidence. List source, synthetic,
packaged, physical and remote proof separately.

**Check:** `scripts/verification-lane.sh all` plus validation of every
P0–P12 acceptance file with `python3 scripts/check-acceptance.py --green`
on each named file. Expected: all required files green with applicable
evidence and no scope/subject mismatch. Do not include P13 in this
prerequisite check, which would make its own acceptance circular.

**Evidence:** `.agent/results/P13/rc-manifest.json`, `coverage.md`,
`contract-review.md` and the authorized run/cost budget. Frozen corpus
includes applicable strict historical failure cases.

### M2 — real front doors, resources and comparisons

**Change:** run the declared native/browser/hero/replay/complex population,
including Calculator, TextEdit, one labeled Notes fixture, menus/chords/
drag, Chrome/Google/Safari and local-only Spotify where verified.
Use owned documents/tabs and separate test accounts. Add p13 tags to
the existing harness only where needed; preserve original task membership.

**Check:** SHIP-PLAN desktop-lock command with tag `p13`, plus the existing
normal physical voice and real-camera qualification checklists on the
same artifact. Reuse all 35 recordings; retain the failed signed history.
Any physical population amendment precedes new data. No repeated user
qualification after internal patches except affected final evidence.

Record all original PROGRAM success/p50/Wilson bars and stricter goals
S-FEEDBACK/S-DICTATION/S-NATIVE/S-VISUAL/S-WORKFLOW. Include meaningful
p95 samples, speech-end timing, cold/warm readiness, costs, requests and
all failed/blocked/timed-out rows. Zero false Done/double dispatch/
deny-list violations or automatic safety approvals.

Measure >=15fps active gaze, >=80% first calibration success, <=5s wake,
RSS <=2.5GB and idle CPU <=10% on M1/8GB with the complete normal runtime.
Report supplemental footprint/memory-after-use without changing the RSS
metric. Confirm clean install/three moments <=3min and demo 10/10.

Compare Codex CU on the frozen shared subset: faster on >=70% with
equal-or-better strict success. Browser subset <=1.2x Browser Use or
faster. Competitor and Jev runs use the same declared task/input/start
conditions. The matched Wispr comparison below is additional required
work and does not substitute for these existing gates.

Use COMPETITIVE's frozen paired dictation method: 24-clip diagnostic pilot,
then a separate >=120-clip qualification with declared speakers, modes,
references and scoring. Report raw WER/CER, critical-content accuracy,
exact insertion/readback, necessary edit burden/correction time and
speech-end/Fn-release latency. Keep neutral and personalized tracks
separate. Use existing scoring or licensed jiwer/AMEND components without
their unapproved default model providers. Human/literal checks remain
primary and an adapted evaluator is not the official Voice Arena score.

Publish all COMPETITIVE category rows, with `lead/parity/behind/
inconclusive/not measured`, eligible comparators, actual sample/intervals,
cold/warm and verified-result clocks. Do not use faster refusal, selected
successful cases, cropped populations or an off-clock verifier to claim
leadership. Resource/setup/privacy and missing-comparator limits remain
visible. New-goal gaps require the explicit ship decision in M3.

**Evidence:** `.agent/results/P13/qualification.json`, raw results,
physical/G6 attestations, resource series and head-to-head report with
all misses and confidence/sample limitations.

### M3 — independent final verdict and handoff

**Change:** authorized fresh-context review checks evidence and actual
artifact/implementation. Fix findings through their owning phase and
rerun only invalidated evidence plus required gates. All acceptance
criteria remain false until the review establishes them.

**Check:** final acceptance validation after the judge's actual decisions;
an unmet new speed goal has an explicit recorded user ship decision or
remains an unresolved release item. No silent downgrade to old targets.
Do not label a self-check or "pass with minor issue" independent PASS.

**Evidence:** `.agent/results/P13/judge-verdict.md`, `ship-decision.md`,
final artifact/signature/rollback references, known limitations, tester
guide and named-file milestone commit proposal. Commit/merge/install/
distribution requires the user's actual authorization.

## Acceptance mapping

| Criterion | Milestone | Evidence |
|---|---|---|
| P13-1 | M1 | complete upstream criteria and frozen subject |
| P13-2 | M2 | task success/latency/statistics and speed-goal scorecard |
| P13-3 | M2 | zero critical safety/result violations |
| P13-4 | M2 | signed physical Fn/pill/gaze and real-app breadth |
| P13-5 | M2 | mandatory matched competitor results |
| P13-6 | M2 | resource, setup and demo bars |
| P13-7 | M3 | independent verdict and explicit ship/rollback handoff |
| P13-8 | M2 | matched Wispr dictation quality and insertion evidence |
| P13-9 | M2/M3 | complete competitive scorecard and explicit gaps/claim limits |

## Gates

G1/G2 pending. The run plan fixes local/physical/provider scopes and
bounded cost before execution. G3 is serialized; G4 review is independent;
G5 uses the real artifact and oracles; G6 is actual human use.
G7 preserves inherited dirty work and prepares scoped commit/release
actions without performing unauthorized external writes.

## Progress

- [x] Draft/default-fail criteria prepared.
- [ ] M1 candidate/population freeze.
- [ ] M2 required qualification.
- [ ] M3 independent verdict and ship handoff.

## Surprises & Discoveries

Three Safari repetitions do not establish broad reliability or p95.
Timing native.drive excludes physical voice and some startup/evidence
work; it cannot be relabeled Fn-to-effect. Production runtime contention
can invalidate isolated eye/speech performance assumptions.

## Decision Log

| Date | Decision | Reason |
|---|---|---|
| 2026-11-15 | One final subject, explicit clocks and matched evidence | Stop repeated partial qualification and unsupported fastest/completion claims |
| 2026-11-15 | User requested Wispr-level dictation and leadership across categories; added P13-8/P13-9 | The former minimum competitor gates cannot establish those claims |

## Outcomes & Retrospective

No RC measurement or release claimed. Nine criteria remain false.
Product completion is not estimated from the percentage of green checks.

## Handoff

Next: consume the completed phase handoffs and prepare the exact RC run
contract. If a release bar fails, identify its owning phase and specific
cause; keep the old app and failed evidence. Do not restart unrelated
research or broaden the test campaign without a concrete unresolved risk.
