# PROGRESS — append-only session log

One entry per working session, newest at the bottom. Format:

```
## <date> — <phase/session id> — <author agent>
**Did:** what changed, named by repo-relative path.
**Evidence:** commands run and what they printed; links to runs.
**State:** which gate the phase is at; acceptance counts.
**Next:** the literal next action for whoever resumes.
**Surprises:** anything that contradicted the plan (also copy into the
phase's Surprises & Discoveries).
```

A fresh agent should resume cold from this file plus the active
ExecPlan. Never edit old entries — corrections are new entries.

---

## 2026-10-18 — P0 — devin-local (SWE-2)

**Did:** Created the harness skeleton: `.agent/PROGRAM.md`,
`.agent/PLANS.md`, `.agent/CONTRACTS.md`, `.agent/PROGRESS.md`,
`.agent/phases/_TEMPLATE.md`, `.agent/phases/P0-harness.md`,
`.agent/acceptance/P0.json`, `.agent/acceptance/schema.json`. Follow-up
entries in this session cover scripts, hooks, agents, AGENTS.md, and doc
normalization as they land.

**Evidence:** this file exists.

**State:** P0 in progress; acceptance criteria all `passes: false`.

**Next:** verification scripts → `.devin/` updates → `AGENTS.md` → doc
normalization → dry-run gates → commit on `ship/v1-p0`.

**Surprises:** none yet.

## 2026-10-18 — P0 (cont.) — devin-local (SWE-2)

**Did:** Scripts + config landed: `scripts/check-acceptance.py`,
`scripts/check-owned-paths.py`, `scripts/verification-lane.sh`,
`scripts/hooks/phase-handoff-check.py`, `scripts/hooks/session-context.py`,
`.devin/hooks.v1.json` (SessionStart + Stop), `.devin/agents/*` now pin
`opus`/`gpt`. `AGENTS.md` rewritten as thin entry point; `README.md`
points at `.agent/`. Doc normalization: 11 files deleted per megaplan
§3.1, still-valid research folded into
`development/JevVoice/research-notes.md`, drift headers on
`EyeTracking/README.md`; all `~/.devin/plans/*.md` carry banners.

**Evidence:** `py_compile` all four hook/check scripts — clean;
`bash -n verification-lane.sh` — clean; `hooks.v1.json` parses;
`check-acceptance.py P0.json` → `0/13` schema-valid; doctored
`passes:true/evidence:null` copy → rejected exit 1;
`check-owned-paths.py P0` staged → OK; `--all` correctly flags the
user's pre-existing dirty paths; Stop hook in `/tmp/hooktest` scratch
repo → blocks (exit 2 + reason) when phases dirty/PROGRESS clean,
passes when both dirty or all committed.

**State:** artifacts M1–M3 done; awaiting G4 judge dry-run (M4).

**Next:** `jarvis-judge` fresh-context verdict vs `acceptance/P0.json` →
apply flips with evidence → commit `ship/v1-p0`.

**Surprises:** none new.

## 2026-10-18 — P0 done — devin-local (SWE-2)

**Did:** G4 dry-run + G7. `jarvis-judge` (gpt, fresh context) reviewed
all 13 criteria → **VERDICT: PASS**; fixed its 2 actionable findings
(PROGRAM index missing D1/D2; Stop hook missed untracked/rename paths →
`-uall` + ` -> ` split, re-verified in scratch repo). Recorded verdict
into `acceptance/P0.json` → `--green` **13/13**. Staged 24 owned files
by name → `check-owned-paths.py P0` OK → milestone commit **`2e62f29`**
on `ship/v1-p0`, plus the handoff commit closing this entry.

**Evidence:** judge report (per-criterion file:line);
`check-acceptance.py --green` → 13/13; `check-owned-paths.py` →
24 files OK; `git log` → `2e62f29`.

**State:** P0 complete. Harness is live: SessionStart injects the
`.agent/` pointer, Stop hook requires PROGRESS hygiene on phase work.

**Next:** P1 — bench test user + harness + baseline. Write
`.agent/phases/P1-bench.md` from `_TEMPLATE.md`, get G1 user approval,
then contract → implement → judge.

**Surprises:** `git add`/`git rm` refuse deleted-path pathspecs when a
file is already gone from the tree — use `git rm` for tracked
deletions, and confirm tracking status first (`development/AGENTS.md`
was gitignored, nothing to stage). The staged-vs-`--all` distinction in
check-owned-paths exists because this tree is shared-dirty.

## 2026-10-19 — P1 done — devin-local (SWE-2) + jarvis-implementer + jarvis-judge

**Did:** Bench harness shipped under `bench/` (16-task corpus, MCP
stdio client, 5-kind verifiers, classifier covering the full
`describe()` vocabulary, runner/report/suite/env-snapshot,
`scripts/bench/create-test-user.sh`) + CONTRACTS §7 amendment (D3/D4)
+ PROGRAM index. Live slice ran for real: 35 `drive_until` rows on the
installed app → `bench/results/results-live-20261019.jsonl` +
`baseline.json`/`baseline-report.md`. Judge: G1 FAIL→fixes→PASS;
implementation FAIL (UnboundLocalError + stale wall_ms rows)→fixes→
**VERDICT: PASS**.

**Evidence:** `bench/selftest.py` → 18 tests OK (×3, incl. post-fix);
`check-acceptance.py P1.json` → 10/11 (P1-11 completes with this
commit); baseline: calc.quit 5/5 @p50 1.3s, finder.frontmost 5/5 @1.3s,
calc.open 3/5 @5.4s (2 false_done), compute/safari/chrome/textedit 0/5
verbatim; T0/T3 bars missed — measured, not guessed.

**State:** P1 complete pending the milestone commit on `ship/v1-p1`.

**Next:** P2 spikes. IMPORTANT carry-forward bug: reused `--agent`
slug on `--mcp-stdio` children permanently wedges drive_until
(tombstoned session label binds dead transport; ~1.2s `.closed` every
call). Bench mitigates with unique slugs; fix belongs in drive/session
layer — see P1-bench.md Handoff for repro + files.

**Surprises:** the wedge bug itself (headline); mcp-stdio children
never touch LatencyLedger (bench owns wall-clock timing until P4/P5
emit spans); `make local` reports tracker-not-ready while the app runs
fine for drive_until — tracker readiness is not a bench prerequisite.
