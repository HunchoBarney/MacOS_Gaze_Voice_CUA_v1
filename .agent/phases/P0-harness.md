# P0 — Harness setup ExecPlan

> Status: in-progress
> Track: main · Depends on: — · Branch: `ship/v1-p0`
> Acceptance: `.agent/acceptance/P0.json` · Contracts touched: all (v0 authored here)

## Purpose

Stand up the `.agent/` execution harness that every later phase runs
through: durable program/plans/contracts/progress files, a default-FAIL
acceptance schema, verification + handoff scripts, Devin subagent
profiles and hooks, the worktree recipe, and an `AGENTS.md` that points
here — then prove the whole loop works by running P0 through it
(dry-run gate loop).

## Context

- Plan of record: `~/.devin/plans/plan-dd7484c27c0b1db0.md` §3 (execution
  harness), §7 (P0 row). `.agent/PROGRAM.md` now supersedes it as source
  of truth.
- Devin mechanics: `.devin/agents/<name>.md` frontmatter (`name`,
  `description`, `model`, `allowed-tools`) — model pins `opus`/`gpt`;
  `.devin/hooks.v1.json` — `Stop` and `SessionStart` events; hook stdin
  carries `tool_name`/`tool_input`/`session_id` but **no subagent
  identity** (drives decision D0).
- Existing scripts: `scripts/setup-workspace-development.py`,
  `scripts/with-desktop-lock.py`, `scripts/verify-cua-source.py`,
  `scripts/bundle-tracker.sh`, `scripts/sign-app.sh`,
  `scripts/check-tracker.sh`.
- Existing span names frozen: `Sources/JevVoice/Support/LatencyLedger.swift`
  `spanKeys` (contract §8).
- Shared checkout: uncommitted user work exists tree-wide; P0 stages
  files **by name only**.

## Owned paths

```text
.agent/**
AGENTS.md
EMPRYO.md
README.md
.devin/agents/jarvis-implementer.md
.devin/agents/jarvis-judge.md
.devin/hooks.v1.json
scripts/check-acceptance.py
scripts/check-owned-paths.py
scripts/verification-lane.sh
scripts/hooks/phase-handoff-check.py
scripts/hooks/session-context.py
development/AGENTS.md
development/JevVoice/TASKS.md
development/JevVoice/comprehensive-audit-2026-10-03.md
development/JevVoice/clicky-decompile-comparison-2026-10-03.md
development/JevVoice/live-test-diagnosis-2026-10-01.md
development/JevVoice/overbuilt-audit-2026-10-01.md
development/JevVoice/full-audit-2026-10-05.md
development/JevVoice/research-notes.md
development/agently-decompile-notes.md
development/eyetracking-facelandmarker-eval.md
development/eyetracking-robustness-research.md
EyeTracking/README.md
```

Also touched (outside the repo, recorded not staged):
`~/.devin/plans/*.md` superseded banners.

## Non-goals

- Writing any phase ExecPlan other than P0's own + the template.
- Changing product code (`Sources/`, `EyeTracking/web`, `Tests/`).
- Committing the user's pre-existing uncommitted changes.
- Merging or pushing `ship/v1-p0` — the user merges.

## Milestones

### M1 — Core artifacts
**Change:** `.agent/PROGRAM.md`, `PLANS.md`, `CONTRACTS.md`,
`PROGRESS.md`, `phases/_TEMPLATE.md`, `phases/P0-harness.md`,
`acceptance/P0.json`, `acceptance/schema.json`.
**Check:** `python3 scripts/check-acceptance.py .agent/acceptance/P0.json`
→ `0/<n> criteria pass` (all default-fail, schema valid).

### M2 — Scripts + hooks + agents
**Change:** `scripts/check-acceptance.py`, `check-owned-paths.py`,
`verification-lane.sh`, `scripts/hooks/*`, `.devin/hooks.v1.json`,
updated `.devin/agents/*.md`.
**Check:** `python3 -m py_compile scripts/check-acceptance.py
scripts/check-owned-paths.py scripts/hooks/phase-handoff-check.py
scripts/hooks/session-context.py && bash -n
scripts/verification-lane.sh` → silent exit 0;
`python3 -c "import json;json.load(open('.devin/hooks.v1.json'))"` →
exit 0.

### M3 — Entry points + doc normalization
**Change:** `AGENTS.md` rewrite; `README.md` pointer; `EMPRYO.md`
removed; `development/JevVoice/research-notes.md` folded from the three
research docs; audit/TASKS/AGENTS dev docs deleted;
`EyeTracking/README.md` drift header; `~/.devin/plans/*.md` banners.
**Check:** `python3 scripts/check-owned-paths.py P0` (staged) → `OK`
once the milestone set is staged by name; `--all` is expected to flag
only the user's pre-existing dirty paths on this shared tree.

### M4 — Dry-run gate loop
**Change:** none — exercise the machinery. `check-acceptance.py` (G3
shape), `jarvis-judge` fresh-context verdict vs `acceptance/P0.json`
(G4), apply judge's flips with evidence, PROGRESS update, milestone
commit (G7).
**Check:** judge returns `VERDICT: PASS`; `python3
scripts/check-acceptance.py .agent/acceptance/P0.json` → all pass with
evidence.

## Acceptance mapping

| acceptance/P0.json id | Milestone | Check layer |
|---|---|---|
| P0-1..P0-4 | M1 | contract (script check) |
| P0-5..P0-8 | M2 | contract |
| P0-9..P0-12 | M3 | contract |
| P0-13 | M4 | judge review |

## Gates

- G1: user approved P0 by directing implementation of this phase from
  the approved megaplan (2026-10-18).
- G2: this document is the contract; judge review of artifacts stands in
  for contract negotiation (no code exists to negotiate).
- G5/G6: not applicable — no live product surface changes.

## Progress

- [x] M1 artifacts written — check: `check-acceptance.py` → `0/13` schema-valid
- [x] M2 scripts/hooks/agents — checks: py_compile clean, bash -n clean, hooks JSON parses, hook block/pass states verified in scratch repo
- [x] M3 AGENTS.md + doc normalization — 11 deletions, research-notes.md folded, drift headers, plan banners
- [ ] M4 dry-run gates + commit

## Surprises & Discoveries

- Hook payloads carry no subagent identity, so a PreToolUse hook cannot
  scope write permissions to a specific spawned implementer → moved
  owned-paths enforcement to `scripts/check-owned-paths.py` run at
  G4/G7 (Decision D0).
- `development/` deletion set mixes tracked-modified and untracked
  files; untracked deletions can't appear in the commit — noted so the
  judge doesn't flag their absence from the diff.

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|
| D0 | 2026-10-18 | Owned-paths enforced by script at gates, not a PreToolUse hook | Hook stdin has no agent/subagent identity field; a path hook would bind the parent agent too |
| D1 | 2026-10-18 | P0 runs in the primary checkout on `ship/v1-p0`, not a worktree | Doc normalization must edit files with uncommitted user changes; a worktree from HEAD can't see them |
| D2 | 2026-10-18 | `research-notes.md` is the single kept dev doc; audits deleted | Audits are point-in-time snapshots whose findings are already encoded in PROGRAM.md "verified problems" |

## Outcomes & Retrospective

<Filled at G7.>

## Handoff

Next phase is P1 (bench test user + harness + baseline). It consumes:
`acceptance/schema.json`, `bench task JSON` contract §7,
`scripts/verification-lane.sh` for its serialized runner, and the
worktree recipe in `PLANS.md` §5.
