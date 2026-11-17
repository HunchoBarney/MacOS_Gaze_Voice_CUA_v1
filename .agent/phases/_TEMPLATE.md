# P<n> — <slug> ExecPlan

> Status: draft | contracted | in-progress | judged | done
> Track: main | agent+voice | eyes · Depends on: <phases> · Branch: `ship/v1-p<n>`
> Acceptance: `.agent/acceptance/P<n>.json` · Contracts touched: <ids or none>

## Purpose

<What changes for the user when this lands — 1–2 sentences.>

## Context

Self-contained brief. Everything the implementer needs is here or in a
named file — never in chat history.

- Relevant code today: `<path>:<what it does>` …
- Contracts this phase must satisfy: `.agent/CONTRACTS.md` §<n>
- Related phases / handoffs to read: `.agent/phases/P<m>-*.md` → Handoff
- Research: <links or `development/JevVoice/research-notes.md` §…>

## Reuse decision

Read `.agent/REUSE.md` before writing a new subsystem. Name the existing
code/platform API and maintained FOSS candidates; record version/license,
adoption or exact rejection reason, and minimum custom glue. G2 must
resolve this decision before implementation. Installed versions do not
change merely because upstream has a newer release.

## Owned paths

Files this phase may create or modify — the complete list:

```text
<repo-relative path or glob>
```

Writing outside this list is a violation. If a needed change lives
elsewhere, report it — do not do it.

## Non-goals

<Explicit exclusions so the judge doesn't inflate scope.>

## Milestones

Each milestone ends with the tree working and committable. Order so the
riskiest seam is proven early.

### M1 — <name>
**Change:** <what, by file>
**Check:** `<command>` → expected: <output>
**Evidence:** <what gets recorded in the phase's acceptance file>

### M2 — <name>
…

## Acceptance mapping

| acceptance/P<n>.json id | Milestone | Check layer (§7 PLANS) |
|---|---|---|
| P<n>-1 | M1 | unit |
| P<n>-2 | M2 | contract |

## Gates

- G1 approved by user on <date> · G2 contract accepted <date>
- Until those decisions exist, state pending; plan-writing authorization
  and self-checks are not implementation approval or independent review.
- G5 budgets this phase must hit: <LatencyLedger spans / RSS / CPU>
- Report applicable PROGRAM speed-goal IDs separately from measured
  achievement and existing release bars.
- G6 human checklist (UX phases): <steps>

## Progress

- [ ] M1 …

## Surprises & Discoveries

<Anything that contradicted the plan while working — with evidence.>

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|

## Outcomes & Retrospective

<Filled at G7: what shipped, what the acceptance file says, what the
next phase must know.>

## Handoff

<State a fresh agent needs to continue or to consume this phase's
output: flags, file locations, known debt.>
