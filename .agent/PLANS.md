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
- **Reuse before building.** New/reopened plans name the existing code,
  platform facility and maintained FOSS candidates. G2 records the adopted
  version/license and minimum glue, or the specific gap requiring custom
  implementation. Follow `.agent/REUSE.md`; don't build another framework
  where an appropriate package already exists.

Mandatory sections (from `_TEMPLATE.md`): Purpose · Context · Owned
paths · Non-goals · Milestones · Acceptance mapping · Progress ·
Surprises & Discoveries · Decision Log · Outcomes & Retrospective ·
Handoff. Progress/Surprises/Decision Log/Outcomes are updated as work
happens — they are the handoff, not paperwork after the fact.
New/reopened plans also carry a Reuse decision and explicit G1/G2 status.
Documentation authorization is not source implementation authorization.

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

G4 can establish source readiness for a milestone while G5/G6 remains
open; it is not whole-phase PASS. The final judge consumes hash-bound
live/human evidence before the remaining criteria can pass. Reuse the
unchanged source review rather than rerunning it for a report-only edit.
Never self-award a fresh-context verdict.

## 4. Roles

| Role | Profile | Model | Tools | Job |
|---|---|---|---|---|
| Planner | orchestrating agent in plan mode | — | read-only | Writes ExecPlans + acceptance.json; user approves at G1 |
| Implementer | `jarvis-implementer` | `opus` | full, scoped to owned files | One writer per phase; contract first; reports evidence |
| Judge | `jarvis-judge` | `gpt` | read-only + read-only exec | Contract review at G2; PASS/FAIL at G4 with file:line evidence |
| Research/explore | `subagent_explore` | `swe` | read-only + web | Spike support, reference-codebase analysis |
| Verification lane | one serialized runner | — | exec | `scripts/verification-lane.sh` owns builds/tests; writers never build a half-frozen tree |
| User | — | — | — | G1 approvals, G6 hands-on, merges, release |

These are roles, not automatic permission to launch helper agents.
Use subagents only when the user explicitly asks; otherwise perform
authorized work directly and keep independent-review gates pending until
an authorized reviewer is available. Do not substitute self-review.

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
- Existing inherited dirt is preserved and named in the baseline. An
  empty staged set passing `check-owned-paths.py` does not prove that the
  unstaged phase delta is owned. Compare the actual phase delta to its
  owned list; use `--all` only with the documented clean-baseline scope.
  Never clear inherited user files to manufacture a clean G7.

## Shipping cadence and bounded verification

`.agent/SHIP-PLAN.md` groups delivery into C1/C2/C3 and records the
implementation-readiness handoff rule. Every new consumer lists the
upstream contract/source hash, reviewed seam and still-open upstream
criteria before coding. All final dependency gates remain mandatory.

`.agent/COMPETITIVE.md` defines the mandatory Wispr quality comparison
and per-category correctness/p50/p95 scorecard. Use its frozen populations,
clocks and uncertainty/claim rules; the older minimum release bars alone
cannot establish leadership. Keep comparison work bounded and staged so
it does not delay C1 for a broad replacement-model search.
The user selected Jev primary, Cua/native execution and Terra API recovery;
that provider choice is settled, while implementation/run contracts remain
subject to the applicable gates.

- Start each investigation with a falsifiable case, at most three
  hypotheses, and a time/command budget. Reproduce before fixing.
- Use existing fixtures/harness/LatencyLedger. First make the probe able
  to fail; do not spend weeks building a second measurement system.
- Run the affected checks through the serialized lane during development.
  Full required checks, independent review and signing occur at coherent
  milestone/candidate boundaries, not after every small edit.
- After three unsuccessful focused attempts, review the cause or route.
  Do not keep increasing retries, deadlines or prompt special cases.
- Reuse valid evidence. Repeat/broaden only for a changed dependency,
  concrete risk, statistical shortfall or mandatory gate.
- Prepare the required physical Fn/pill/gaze population once for the final
  candidate. Record a population amendment before collecting results.
- Freeze task membership before model/performance comparisons. Preserve
  failed rows and separate source, synthetic, packaged, physical and
  provider evidence.
- Report both PROGRAM release bars and new speed goals. No cold/warm
  relabeling, partial-text substitution, signed/unsigned substitution or
  confidence-as-permission shortcut.
- A new verification-lane mode or bench injector is a phase deliverable,
  not a command presumed to exist. Until implemented, reviewed and shown
  to select a nonempty intended population, its criterion stays false.

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
