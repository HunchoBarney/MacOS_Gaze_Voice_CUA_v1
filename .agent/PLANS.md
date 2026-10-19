# PLANS — ExecPlan rules for the Jarvis harness

Adapted from the OpenAI ExecPlan convention plus Anthropic's long-running
harness patterns (default-FAIL feature lists, fresh-context evaluators,
sprint contracts). Every phase lives in `.agent/phases/P<n>-<slug>.md`
and obeys these rules. `_TEMPLATE.md` in the same directory is the
skeleton — copy it verbatim.

## 1. What an ExecPlan is

A **self-contained** document: a competent agent with zero conversation
history can execute it start to finish using only the file, the repo,
and the cited contracts. If a fact matters, it is in the file or in a
file it names — never in "the discussion we had".

Required properties:

- **Purpose first.** What changes for the user when this lands, in one
  or two sentences. A plan without a user-visible purpose is scope creep
  waiting to happen.
- **Repo-relative file names, always.** `Sources/JevVoice/...`, never
  "the coordinator file" or absolute paths.
- **Owned paths are explicit.** A fenced list of every file the phase
  may create or modify. Writing outside the list is a violation;
  `scripts/check-owned-paths.py` enforces it at gates.
- **Commands with expected output.** Every check is a copy-pastable
  command plus what success looks like (`swift test --filter X` →
  "12 passed, 0 failed"). An agent verifies; it does not believe.
- **Independently verifiable milestones.** Each milestone leaves the
  tree working and is committable on its own. Order milestones so the
  riskiest seam is proven early, not last.
- **Spikes declare promote/discard criteria up front** — the numbers
  that keep or kill the idea, and the documented fallback.
- **Done is defined by `acceptance/P<n>.json`**, not by vibes. Every
  criterion maps to at least one milestone check.

Mandatory sections (from `_TEMPLATE.md`): Purpose · Context · Owned
paths · Non-goals · Milestones · Acceptance mapping · Progress ·
Surprises & Discoveries · Decision Log · Outcomes & Retrospective ·
Handoff. Progress/Surprises/Decision Log/Outcomes are updated as work
happens — they are the handoff, not paperwork after the fact.

## 2. Acceptance files — default FAIL

`.agent/acceptance/P<n>.json`:

```json
{
  "phase": "P0",
  "criteria": [
    {
      "id": "P0-1",
      "behavior": "what must be true, user- or system-observable",
      "check": "exact command or inspection the judge runs",
      "expected": "what success looks like",
      "passes": false,
      "evidence": null
    }
  ]
}
```

Rules:

- Every criterion starts `"passes": false`, `"evidence": null`. **The
  implementer may not flip `passes`.** Only the judge's verdict —
  relayed by the orchestrating agent — sets `passes: true` with an
  `evidence` string citing output, file:line, or a run.
- A criterion the judge cannot check is a defect in the plan: fix the
  criterion or the artifact, then re-review.
- `scripts/check-acceptance.py <file>` validates schema and reports
  pass counts; a phase is green only when every criterion passes with
  evidence.

## 3. The gate loop (every phase)

| Gate | Owner | What happens |
|---|---|---|
| G1 Plan approval | planner → user | Judge checks the ExecPlan is self-contained and every criterion testable; **user approves** before code |
| G2 Contract | implementer ⇄ judge | Implementer proposes milestone test plan + evidence forms; judge accepts **before** any code |
| G3 Build + tests | verification lane | Serialized runner green; new checks must fail before / pass after |
| G4 Judge | fresh-context `jarvis-judge` | Reviews the phase vs acceptance.json with file:line evidence; PASS or findings → loop back to implementer. Never fixes anything |
| G5 Live + budgets | verification lane | Phase's bench slice in the test user; `LatencyLedger` spans vs budgets; RSS/CPU check |
| G6 Human try | user | UX phases only — short checklist from the ExecPlan |
| G7 Handoff | orchestrating agent | Progress/Decision Log/Retrospective updated; `git status` clean; milestone commits exist on `ship/v1-<phase>` |

A gate is not a courtesy: skipping one is how green tests shipped a
broken product twice.

## 4. Roles

| Role | Profile | Model | Tools | Job |
|---|---|---|---|---|
| Planner | orchestrating agent in plan mode | — | read-only | Writes ExecPlans + acceptance.json; user approves at G1 |
| Implementer | `jarvis-implementer` | `opus` | full, scoped to owned files | One writer per phase; contract first; reports evidence |
| Judge | `jarvis-judge` | `gpt` | read-only + read-only exec | Contract review at G2; PASS/FAIL at G4 with file:line evidence |
| Research/explore | `subagent_explore` | `swe` | read-only + web | Spike support, reference-codebase analysis |
| Verification lane | one serialized runner | — | exec | `scripts/verification-lane.sh` owns builds/tests; writers never build a half-frozen tree |
| User | — | — | — | G1 approvals, G6 hands-on, merges, release |

Model pins live in `.devin/agents/*.md` (`model:` frontmatter). Short
names resolve to the latest family release via the Devin router.

## 5. Worktree recipe and parallelism

- Track **agent+voice**: `git worktree add ../jarvis-v1-agent ship/v1-<phase>`
  then `python3 scripts/setup-workspace-development.py` inside it.
  Owns `Sources/**`, `Tests/**`, `development/**`.
- Track **eyes**: `../jarvis-v1-eyes` on its own `ship/v1-p8`-style
  branch; owns `EyeTracking/**`.
- **Never two writers in one tree.** Read-only agents run anywhere,
  any time. A second concurrent writer = another worktree.
- Owned paths are disjoint by construction; merges are sequential with
  the full suite after each. Phases on track `main` (P0, P1, P12, P13)
  run in the primary checkout on their `ship/v1-<phase>` branch.
- Commits are per milestone, staged by name (never `git add -A` on a
  shared tree). User merges; agents never push or force anything.

## 6. Task brief template (every implementer spawn)

```
Assignment:  <result + user-visible behavior>
Context:     <ExecPlan path> §<milestone>, contracts in .agent/CONTRACTS.md,
             owned files: <named list — not "read everything">
Constraints: <banned actions, hardware/vendor limits, no commits unless told>
Boundaries:  free inside owned files; contract changes, new deps, scope
             changes → report back, do not improvise
Done:        implement → run assigned checks → inspect → fix → report with
             evidence (commands run, output, file:line)
```

## 7. Verification layers (cheapest first)

1. Unit tests at the changed code.
2. Contract tests at seams — realtime tool schema, `Decider`,
   script argv, skill JSON, bench JSON (see `CONTRACTS.md`).
3. Recorded fixtures — audio, AX trees, DOM snapshots.
4. Live gated — `JARVIS_*` flags behind `scripts/with-desktop-lock.py`,
   one owner at a time.
5. Bench slice — test user, unattended.
6. Budgets — `LatencyLedger` spans, RSS, CPU.
7. Human try.

Each phase's ExecPlan names which layers each milestone must reach.

## 8. Handoff

Before a phase session ends, `PROGRESS.md` gets an append-only entry
(what / evidence / next), the phase ExecPlan's Progress section reflects
reality, and `acceptance/P<n>.json` is current. The Stop hook
(`scripts/hooks/phase-handoff-check.py`) blocks ending a session that
leaves phase artifacts dirty without a `PROGRESS.md` update.
