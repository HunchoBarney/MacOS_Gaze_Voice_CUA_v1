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
  check the baseline-to-candidate delta as described in §5.
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

## 3. Choose the proof before starting

**A bounded bug in an approved milestone** needs one owner, a reproducible
failure (or falsifiable counterexample), a narrow repair, affected checks
on the actual delta and a fresh read-only review. Repeat the same case
and record what is still unverified. It does not need a new phase or a
human sign-off per edit. For documentation, check the changed instructions,
links and diff rather than building the product.

**A phase or release** follows G1–G7 below. Do not route a change to a
frozen interface, execution authority, provider, permissions, signing or
release population through the bug shortcut. Return to its owning decision,
review the affected consumers and run the applicable candidate/release gates.
If a criterion no longer describes the shipped path, propose a versioned
amendment mapping the surviving guarantees; never erase a receipt, silently
flip an old failure or change a population after seeing results.

| Gate | Owner | What happens |
|---|---|---|
| G1 Plan approval | planner → user | Judge checks the ExecPlan is self-contained and every criterion testable; **user approves** before code |
| G2 Contract | implementer ⇄ judge | Implementer proposes milestone test plan + evidence forms; judge accepts **before** any code |
| G3 Build + tests | verification lane | Serialized runner green; new checks must fail before / pass after |
| G4 Judge | fresh-context read-only reviewer | Reviews the phase vs acceptance.json with file:line evidence; PASS or findings → loop back to implementer. Never fixes anything |
| G5 Live + budgets | verification lane | Phase's bench slice in the test user; `LatencyLedger` spans vs budgets; RSS/CPU check |
| G6 Human try | user | UX phases only — short checklist from the ExecPlan |
| G7 Handoff | integration owner | Update Progress/Decision Log/Retrospective, account for inherited dirt and hand off the reviewed delta. Record milestone commits on `ship/v1-<phase>` when authorized; a pending commit or merge stays pending |

A gate is not a courtesy: skipping one is how green tests shipped a
broken product twice.

G4 can establish source readiness for a milestone while G5/G6 remains
open; it is not whole-phase PASS. The final judge consumes hash-bound
live/human evidence before the remaining criteria can pass. Reuse the
unchanged source review rather than rerunning it for a report-only edit.
Never self-award a fresh-context verdict.

## 4. Delegate outcomes within scope

The Captain owns the user outcome and stop decision. Give each independent
outcome one issue owner and a durable crew thread for diagnosis through
handoff. Inside a thread, use short-lived read-only subagents for bounded
questions or independent review; they report to the assigning agent. No
separate permission per helper within approved work. Start with two to four
readers only when their answers can change the decision. Do not fan out
recursively by default. Widen only for a named independent question with
a time/cost budget; stop when the next fact requires one person or device.

Assign roles by permissions and independence, not model name: the planner
prepares the phase contract, the implementer edits assigned paths, and a
fresh-context reviewer examines the actual diff and evidence, without
writing fixes or awarding their own work a verdict. Devin profiles under
`.devin/agents/` retain their own tool/model settings; they do not configure
Capy. In Capy the Captain's Drive AGENTS.md governs the Captain, CREW.md
guides its threads, and this repository's AGENTS.md points here.

Delegation never expands a grant. Ask before changing scope or using data,
money or a device outside the approved brief: no reading private speech,
sharing raw logs, transcripts, screen content or secrets, paid provider
runs, new capture, mic/camera use, TCC changes, desktop mutation, signing,
installation/replacement or deployment by implication. Keep private inputs
local; use synthetic or authorized content-free extracts for shared/cloud
review. A pause stops the work and its descendants; a policy edit does not
resume the product. Leave changes unstaged. Stage, commit, push, publish
or merge only with explicit authority for that action; the user controls
merge and release. Stage authorized milestone files by name, never wholesale.

## 5. Own the delta and the shared Mac

1. **Choose the checkout by what it contains.** Record the revision and
   status locally before writing. Save content diffs only for paths and
   data the brief permits. For unrelated changes use status and permitted
   local hashes, not copies; do not open private files to establish a baseline.
   A shared reader sees the exact dirty tree; a fresh upstream checkout
   does not. Verify base and inputs in each isolated worktree. If required
   local changes lack an authorized common baseline, keep one writer in
   the existing tree and parallelize reads. Never copy a dirty tree, stash,
   reset, clean or publish someone's work to make a baseline.
2. **Assign change sets, not directories for life.** Pilot at most two
   concurrent writers, one per isolated worktree, with disjoint named paths
   on the same frozen base. Track labels in phase plans describe subsystems,
   not permanent owners. Sequence dependencies and overlaps (including
   metadata, shared controllers and contracts) under one integration owner.
   Raise the pilot limit only after usable shared baselines, conflict-free
   integration and scope-aware checks are demonstrated; it is a Jarvis
   resource decision, not a Capy ceiling. If a new worktree needs local
   development assets, review `scripts/setup-workspace-development.py`
   against its permitted inputs before running it.
3. **Check ownership at handoff.** Compare baseline to candidate, including
   unstaged hunks, deletions and new files, against the declared paths.
   `scripts/check-owned-paths.py P<n>` checks only the index; an empty
   index can pass. `--all` includes inherited dirt and attributes nothing.
   Keep unrelated edits intact, including pre-existing hunks in owned files.
4. **Schedule one build token.** One integrator schedules resource-conflicting
   Mac builds, tests and signing on a coherent source freeze. Use
   `scripts/verification-lane.sh <scope>`: it sequences commands *within*
   one invocation, not across processes or worktrees. Record the revision
   or artifact hash, scope, selected suites/counts, skips and failures.
   The same green banner can follow a filtered run or `all`. Checked-in
   macOS CI runs Swift build and `make test` (tooling/Python and Swift), not
   the EyeTracking typecheck/Vitest. Neither a banner nor a workflow file
   proves branch protection or a release pass.
5. **Reserve one physical operator.** On an authorized session the operator
   uses `scripts/with-desktop-lock.py`; its exclusive file lock coordinates
   callers using the same lock file, not every Mac process. Before inviting
   the person, put one current “what to try” record on the issue: signed
   candidate hash and predecessor, who may launch it, harmless action,
   visible pass condition and privacy-safe signal distinguishing likely
   failures. Report source/checks, packaged readiness and observed physical
   result separately. Fixtures/cloud cannot qualify AppKit/TCC, actual
   Fn/microphone/gaze or user-visible effect. If the desktop does not
   switch, opening Mission Control or delivering a press is not success.
   Stop at the first failure and retest the same action after the repair.

Judge the pilot by attempts per resolved failure, time to observed outcome,
failures attributed, unnecessary approval interruptions, writer conflicts,
build-token wait and cost. Shrink it if it adds rework or human retests.

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

## 6. Task brief (every delegation)

```
Assignment:  <result + user-visible behavior>
Context:     <issue, exact baseline/checkout, relevant plan and contracts>
Scope:       <read-only or named writable paths; permitted data and actions>
Constraints: <forbidden actions, hardware/vendor limits, time/cost budget>
Boundaries:  free inside owned files; contract changes, new deps, scope
             changes → report back, do not improvise
Done:        <success test, evidence to return to assigning agent, when to stop>
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
reality, and `acceptance/P<n>.json` is current. The Devin Stop hook
(`scripts/hooks/phase-handoff-check.py`) checks for dirty phase/acceptance
files without a dirty progress file. It does not prove this session wrote
a handoff, and it is not a Capy hook.
